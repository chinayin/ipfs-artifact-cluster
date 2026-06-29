# Kubo(IPFS) HTML 托管 POC 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 Docker Compose 跑通一个单节点离线 Kubo，让 Agent 直连 API 上传 HTML 并能在浏览器渲染，配一套一键 e2e 脚本与文档。

**Architecture:** 单个 `ipfs/kubo` 容器以 `--offline` 运行；`/container-init.d` 脚本在 daemon 启动前配置监听地址、CORS、离线路由；Agent 经 `/api/v0/add` 上传，浏览器经网关 `/ipfs/<CID>` 访问。

**Tech Stack:** Docker Compose、Kubo `v0.42.0`、bash + curl（e2e）。

## Global Constraints

- 镜像锁定 `ipfs/kubo:v0.42.0`（verbatim，保证可复现）。
- 离线单节点：`daemon --offline` + `Routing.Type=none` + 清空 bootstrap。
- API `5001` / Gateway `8080` 均绑 `0.0.0.0`（局域网可达，POC 裸奔）；不映射 `4001`。
- 持久化卷 `./data/ipfs:/data/ipfs`；`data/` 与 `e2e/fixtures/` 进 `.gitignore`（已存在）。
- e2e 仅用 bash + curl，不依赖 jq；JSON 用 grep/sed 解析。
- 上传统一带 `cid-version=1&pin=true`。
- 安全红线：`5001` 绝不暴露公网（文档需醒目标注）。

---

### Task 1: 部署编排与离线配置

**Files:**
- Create: `docker-compose.yml`
- Create: `init.d/001-config.sh`

**Interfaces:**
- Produces: 运行中的 Kubo —— API `http://localhost:5001`、Gateway `http://localhost:8080`，离线、CORS 全开。后续任务依赖这两个端点。

- [ ] **Step 1: 写 docker-compose.yml**

```yaml
services:
  ipfs:
    image: ipfs/kubo:v0.42.0
    container_name: kubo-poc
    command: ["daemon", "--migrate=true", "--offline", "--agent-version-suffix=docker"]
    ports:
      - "5001:5001"   # API：给 Agent 上传（POC 局域网裸奔，勿暴露公网）
      - "8080:8080"   # Gateway：给用户/浏览器访问
    volumes:
      - ./data/ipfs:/data/ipfs
      - ./init.d:/container-init.d:ro
    restart: unless-stopped
```

- [ ] **Step 2: 写 init.d/001-config.sh**

```sh
#!/bin/sh
set -ex

# 监听所有接口（配合 docker 端口映射对局域网暴露）
ipfs config Addresses.API     /ip4/0.0.0.0/tcp/5001
ipfs config Addresses.Gateway /ip4/0.0.0.0/tcp/8080

# CORS：允许 Agent 从任意来源调用 API（POC 放开）
ipfs config --json API.HTTPHeaders.Access-Control-Allow-Origin  '["*"]'
ipfs config --json API.HTTPHeaders.Access-Control-Allow-Methods '["PUT","POST","GET"]'

# 离线单节点：关闭路由、清空 bootstrap（与 --offline 双保险，并持久化到配置）
ipfs config Routing.Type none
ipfs bootstrap rm --all

# 保证网关返回可渲染内容
ipfs config --json Gateway.DeserializedResponses true
```

- [ ] **Step 3: 赋可执行权限并启动**

Run:
```bash
chmod +x init.d/001-config.sh
docker compose up -d
```
Expected: 容器 `kubo-poc` 创建并 `Started`。

- [ ] **Step 4: 验证 daemon 就绪且离线**

Run:
```bash
# 等就绪
for i in $(seq 1 60); do curl -fsS -X POST http://localhost:5001/api/v0/version && break; sleep 1; done
echo
# 离线确认：bootstrap 为空 / 路由为 none
docker exec kubo-poc ipfs config Routing.Type
docker exec kubo-poc ipfs bootstrap list
```
Expected: version 返回 JSON（含 `"Version":"0.42.0"`）；`Routing.Type` 输出 `none`；`bootstrap list` 输出为空。

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml init.d/001-config.sh
git commit -m "feat: 新增 Kubo 离线单节点 docker compose 编排与配置"
```

---

### Task 2: 一键 e2e 测试脚本（上传 + 渲染 + 局域网）

**Files:**
- Create: `e2e/run.sh`

**Interfaces:**
- Consumes: Task 1 的 API `:5001` 与 Gateway `:8080`。
- Produces: `e2e/run.sh`，退出码 0 = 全部 PASS。运行时在 `e2e/fixtures/` 生成测试 HTML（已 gitignore）。

- [ ] **Step 1: 写 e2e/run.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

API=${API:-http://localhost:5001}
GW=${GW:-http://localhost:8080}
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

ROOT="$(cd "$(dirname "$0")" && pwd)"
FIX="$ROOT/fixtures"
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
ng(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

cleanup(){ [ "$KEEP" -eq 1 ] || (cd "$ROOT/.." && docker compose down >/dev/null 2>&1 || true); }
trap cleanup EXIT

# 取 /api/v0/add 返回里最后一行的 Hash（目录上传时最后一行是目录 CID）
last_hash(){ grep -o '"Hash":"[^"]*"' | tail -1 | sed 's/.*:"//;s/"//'; }
# 取响应头里的 Content-Type
ctype(){ curl -fsSI "$1" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print $2}'; }

echo "==> 1. 启动 Kubo"
(cd "$ROOT/.." && docker compose up -d)

echo "==> 2. 等待就绪"
for i in $(seq 1 60); do
  curl -fsS -X POST "$API/api/v0/version" >/dev/null 2>&1 && break
  sleep 1
  [ "$i" -eq 60 ] && { echo "Kubo 未就绪"; exit 1; }
done

echo "==> 3. 准备 fixtures"
mkdir -p "$FIX/site"
cat > "$FIX/standalone.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><title>standalone</title>
<style>body{color:#06c}</style></head>
<body><h1 id="marker">HELLO_STANDALONE_E2E</h1></body></html>
HTML
cat > "$FIX/site/index.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="./style.css"></head>
<body><h1 id="marker">HELLO_SITE_E2E</h1></body></html>
HTML
cat > "$FIX/site/style.css" <<'CSS'
#marker{color:green}
CSS

echo "==> Case 1: 自包含 HTML 渲染"
CID1=$(curl -fsS -F "file=@$FIX/standalone.html" "$API/api/v0/add?cid-version=1&pin=true" | last_hash)
echo "  CID=$CID1"
CT=$(ctype "$GW/ipfs/$CID1")
echo "$CT" | grep -qi 'text/html' && ok "Case1 Content-Type=$CT" || ng "Case1 Content-Type=$CT"
curl -fsS "$GW/ipfs/$CID1" | grep -q 'HELLO_STANDALONE_E2E' && ok "Case1 正文可读" || ng "Case1 正文"

echo "==> Case 2: 目录 + 相对资源"
DIR=$(curl -fsS \
  -F "file=@$FIX/site/index.html;filename=index.html" \
  -F "file=@$FIX/site/style.css;filename=style.css" \
  "$API/api/v0/add?wrap-with-directory=true&cid-version=1&pin=true" | last_hash)
echo "  DIR_CID=$DIR"
CT=$(ctype "$GW/ipfs/$DIR/index.html")
echo "$CT" | grep -qi 'text/html' && ok "Case2 index Content-Type=$CT" || ng "Case2 index=$CT"
CTC=$(ctype "$GW/ipfs/$DIR/style.css")
echo "$CTC" | grep -qi 'text/css' && ok "Case2 css Content-Type=$CTC" || ng "Case2 css=$CTC"
curl -fsS "$GW/ipfs/$DIR/index.html" | grep -q 'HELLO_SITE_E2E' && ok "Case2 index 正文可读" || ng "Case2 index 正文"

echo "==> Case 3: 局域网 IP 访问"
LANIP=$(ipconfig getifaddr en0 2>/dev/null || true)
if [ -n "$LANIP" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://$LANIP:8080/ipfs/$CID1")
  [ "$code" = "200" ] && ok "Case3 LAN($LANIP) 200" || ng "Case3 LAN($LANIP) code=$code"
else
  echo "  SKIP: 未探测到 LAN IP（en0）"
fi

echo "==> 汇总: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: 赋可执行权限**

Run: `chmod +x e2e/run.sh`
Expected: 无输出。

- [ ] **Step 3: 运行 e2e，验证全部 PASS**

Run: `./e2e/run.sh --keep`
Expected: 末尾输出 `汇总: PASS=6 FAIL=0`（无 LAN IP 则 `PASS=5` 且 Case3 显示 SKIP），脚本退出码 0。

> 排错提示：若 Case1 Content-Type 不是 `text/html`，确认 `Gateway.DeserializedResponses=true`；若 Case2 css 失败，确认上传用了 `wrap-with-directory=true` 且 `filename=` 无路径前缀。

- [ ] **Step 4: Commit**

```bash
git add e2e/run.sh
git commit -m "test: 新增 HTML 上传/渲染/局域网访问 e2e 脚本"
```

---

### Task 3: 文档（部署 / Agent 接入 / e2e）

**Files:**
- Create: `docs/01-部署.md`
- Create: `docs/02-Agent接入.md`
- Create: `docs/03-e2e测试.md`

**Interfaces:**
- Consumes: Task 1、Task 2 的最终文件与命令。

- [ ] **Step 1: 写 docs/01-部署.md**

内容必须包含（用实际命令，非占位）：
- 前置：Docker / Docker Compose。
- 启动：`docker compose up -d`；停止：`docker compose down`；查看日志：`docker compose logs -f`。
- 配置说明：逐条解释 `init.d/001-config.sh`（监听地址、CORS、离线、DeserializedResponses）。
- 数据持久化：`./data/ipfs` 卷，删除即清空。
- **安全红线（醒目）**：`5001` API 无鉴权，仅限可信局域网，**绝不可暴露公网**。

- [ ] **Step 2: 写 docs/02-Agent接入.md**

内容必须包含：
- 上传契约：`POST http://<host>:5001/api/v0/add?cid-version=1&pin=true`，返回字段 `Hash`/`Name`。
- 方式一（自包含单文件）完整 curl 示例 + 拿到的访问链接 `http://<host>:8080/ipfs/<CID>`。
- 方式二（目录+相对资源）完整 curl 示例（`wrap-with-directory=true`、多 `-F file=...;filename=...`），访问 `http://<host>:8080/ipfs/<DIR_CID>/index.html`。
- 何时用哪种：内联资源 → 方式一；外链相对资源 → 方式二。
- 渲染说明：网关嗅探 Content-Type，HTML 直接渲染；相对路径需目录方式。

- [ ] **Step 3: 写 docs/03-e2e测试.md**

内容必须包含：
- 运行：`./e2e/run.sh`（默认跑完清理）/ `./e2e/run.sh --keep`（保留容器）。
- 三个 case 各自含义（自包含渲染 / 目录+相对资源 / 局域网 IP）。
- 期望输出 `PASS=6 FAIL=0`（或 5 + SKIP）。
- 常见失败与排查（Content-Type 不对、css 404、LAN 探测失败）。

- [ ] **Step 4: 校对文档与实际文件一致**

Run: `ls docker-compose.yml init.d/001-config.sh e2e/run.sh docs/`
Expected: 全部存在；逐一核对文档中的命令、端口、参数与仓库实际文件一致。

- [ ] **Step 5: Commit**

```bash
git add docs/01-部署.md docs/02-Agent接入.md docs/03-e2e测试.md
git commit -m "docs: 新增部署、Agent 接入与 e2e 测试文档"
```

---

## Self-Review

**Spec coverage（对照设计文档各节）：**
- §3/§4 架构与配置 → Task 1（compose + init.d）✓
- §5 上传契约（两种方式）→ Task 2 Case1/2 + Task 3 docs/02 ✓
- §6 HTML 渲染 → Task 2 Content-Type 断言 ✓
- §7 e2e 三 case → Task 2 ✓
- §8 安全说明 → Task 3 docs/01 红线 ✓
- §10 交付物目录 → Task 1/2/3 覆盖 compose、init.d、e2e、docs ✓
- §11 验收标准 → Task 2 全 PASS + Task 3 文档齐全 ✓

**Placeholder scan：** 无 TBD/TODO；文档任务以"必须包含"清单约束内容，所有命令/参数均为实值。

**Type/命名一致性：** API/Gateway 端口、`cid-version=1&pin=true`、`wrap-with-directory=true`、`Routing.Type=none`、镜像 `v0.42.0` 在各任务间一致。
