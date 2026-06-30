# Agent 发布技能 + 集群上传入口 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Agent 把一段 HTML（单文件或带资源目录）一句话发布到私有 IPFS Cluster，拿到不可变的可分享链接——通过一个可移植技能 + 集群侧 token 写入口实现。

**Architecture:** (a) 对外技能 `skills/publish-artifact/`（`publish.sh` curl 助手 + `test.sh` + `SKILL.md`），靠 3 个环境变量指向已部署集群；(b) 现有 Caddy 上新增 token 鉴权写入口 `:9097`，只放行 `POST /add` 反代 cluster0 REST `:9094`；(c) 仓库结构调整：内部 e2e 技能移入 `.claude/skills/` 并选择性纳入版本、删掉 Makefile 软链目标。

**Tech Stack:** bash + curl（技能，零额外语言依赖）、Caddy 2（写入口）、docker compose、IPFS Cluster v1.1.6 REST API。

## Global Constraints

- 镜像锁版本：`ipfs/kubo:v0.42.0`、`ipfs/ipfs-cluster:v1.1.6`、`caddy:2-alpine`。
- 上传强制 `cid-version=1`。
- 默认过期 `expire-in=168h`（1 周）；`--permanent` 时**省略**该参数 = 永久。
- 副本因子继承集群默认（rf=-1），技能侧不覆盖。
- 技能只认 3 个 env：`IPFS_PUBLISH_ENDPOINT`、`IPFS_PUBLISH_TOKEN`、`IPFS_BASE_URL`；缺失必须明确报错，不静默。
- **写入口只放行 `POST /add`**；不向 Agent 暴露任何管理/删除能力。
- Shell 脚本（`publish.sh`/`test.sh`）注释用**英文**（与 `e2e/run-cluster.sh`、`scripts/init-cluster.d` 一致）；`SKILL.md` 与文档用**中文**。
- git 提交信息用中文（约定式前缀保留英文）；**不带** `Claude-Session:` trailer（本仓库已开源）。
- 机密（`.env` 含 `CLUSTER_SECRET`/`IPFS_PUBLISH_TOKEN`）与 `runtime/` 不入库。

## 已验证的事实（实现时可直接依赖）

- `POST :9094/add?cid-version=1&expire-in=<dur>` 单次调用 = 添加 + 全集群 pin（3 副本）+ 设 `expire_at`。返回**每个条目一行 JSON**：`{"name":...,"cid":...,"size":...,"allocations":[...]}`。
- **单文件**：不带 wrap，响应单行，`.cid` 即文件 CID；分享链接 `<BASE>/artifact/<cid>`。
- **目录**：每个文件作为一个 `file` part，`filename` 用**相对站点根**的路径（`index.html`、`css/app.css`，不含目录名本身），query 加 `wrap-with-directory=true`；响应中 `"name":""` 那行的 `cid` 是站点根；分享链接 `<BASE>/artifact/<root>/`，`/ipfs/<root>/`、`index.html`、`css/app.css` 均 200。
- Caddy `:80` 现有 artifact 站点与 `:8088` 读网关已工作，勿动其行为。

## 文件结构

- 新建 `skills/publish-artifact/SKILL.md` — 技能说明 + 中文 runbook（含 3 个 env 配置）。
- 新建 `skills/publish-artifact/publish.sh` — 发布助手（单文件 + 目录），英文注释。
- 新建 `skills/publish-artifact/test.sh` — 技能自测（单文件 + 目录发布 → 渲染 200）。
- 修改 `caddy/Caddyfile` — 追加 `:9097` token 写入口 route。
- 修改 `docker-compose.cluster.yml` — caddy 服务加 `9097` 端口与 `IPFS_PUBLISH_TOKEN` 环境变量。
- 修改 `Makefile` — `secrets` 目标增生成 `IPFS_PUBLISH_TOKEN`；删除 `claude-skills` 目标及其 `.PHONY`；新增 `publish-test` 目标。
- 修改 `.gitignore` — 选择性纳入 `.claude/skills/kubo-cluster-e2e`。
- 移动 `skills/kubo-cluster-e2e/` → `.claude/skills/kubo-cluster-e2e/`。
- 修改 `README.md` / `docs/SINGLE_HOST_DEPLOYMENT.md` — 文档化写入口端口与发布技能。

---

### Task 1: 集群侧 token 写入口（Caddy :9097 → REST :9094 仅 /add）

**Files:**
- Modify: `caddy/Caddyfile`（追加 `:9097` route）
- Modify: `docker-compose.cluster.yml:93-103`（caddy 服务加端口与 env）
- Modify: `Makefile`（`secrets` 目标生成 token）
- Test: 手动 curl 断言（见步骤）

**Interfaces:**
- Produces: 写入口 `http://<host>:9097/add`，需 `Authorization: Bearer $IPFS_PUBLISH_TOKEN`；非 `/add` 路径返回 403；无效 token 返回 401。Caddy 容器从环境变量 `IPFS_PUBLISH_TOKEN` 读取期望 token。

- [ ] **Step 1: secrets 目标生成 IPFS_PUBLISH_TOKEN**

修改 `Makefile` 的 `secrets` 目标，在生成 `CLUSTER_SECRET` 之后追加（幂等，已存在不重复写）：

```makefile
secrets: ## 幂等生成 .env(CLUSTER_SECRET/IPFS_PUBLISH_TOKEN) 与 runtime/private/swarm.key(已存在则跳过)
	@[ -f .env ] || echo "CLUSTER_SECRET=$$(od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')" > .env
	@grep -q '^IPFS_PUBLISH_TOKEN=' .env 2>/dev/null || \
		echo "IPFS_PUBLISH_TOKEN=$$(od -vN 24 -An -tx1 /dev/urandom | tr -d ' \n')" >> .env
	@mkdir -p runtime/private
	@[ -f runtime/private/swarm.key ] || printf '/key/swarm/psk/1.0.0/\n/base16/\n%s\n' \
		"$$(od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')" > runtime/private/swarm.key
	@echo "secrets ready (.env + runtime/private/swarm.key)"
```

- [ ] **Step 2: Caddyfile 追加 token 写入口**

在 `caddy/Caddyfile` 末尾追加（保留已有 `:80` 站点不动）：

```caddyfile
# 上传写入口：token 鉴权，只放行 POST /add，反代到 cluster0 REST :9094。
# 供 Agent 发布技能调用；:9094/:9095/:5001 原生端口仍不暴露。详见 docs/SINGLE_HOST_DEPLOYMENT.md。
:9097 {
	route {
		# 1) 校验 Bearer token（值由 compose 注入的 IPFS_PUBLISH_TOKEN 提供）
		@unauth not header Authorization "Bearer {$IPFS_PUBLISH_TOKEN}"
		respond @unauth "Unauthorized" 401

		# 2) 只放行 /add，堵死其余 REST 管理路由（unpin / peers 等）
		@notadd not path /add
		respond @notadd "Forbidden" 403

		reverse_proxy cluster0:9094
	}
}
```

- [ ] **Step 3: compose 给 caddy 加端口与 env**

修改 `docker-compose.cluster.yml` 的 `caddy` 服务（在 `ports` 与新增 `environment` 块）：

```yaml
  caddy:
    image: caddy:2-alpine     # 可锁具体 patch（如 caddy:2.10-alpine）
    container_name: cl-caddy
    restart: unless-stopped
    depends_on: [ipfs0, ipfs1, ipfs2]
    environment:
      IPFS_PUBLISH_TOKEN: ${IPFS_PUBLISH_TOKEN:?run `make secrets` first}
    ports:
      - "8088:80"             # 对外：http://<host>:8088/artifact/<CID>
      - "9097:9097"           # 上传写入口（token 鉴权，仅 POST /add）
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
```

- [ ] **Step 4: 起栈并校验 Caddyfile**

Run:
```bash
make secrets && docker compose -f docker-compose.cluster.yml up -d
docker exec cl-caddy caddy validate --config /etc/caddy/Caddyfile
```
Expected: `Valid configuration`；caddy 容器 running。

- [ ] **Step 5: 断言鉴权与路径限制（这是本任务的测试）**

Run:
```bash
TOKEN=$(grep '^IPFS_PUBLISH_TOKEN=' .env | cut -d= -f2)
# a) 无 token → 401
curl -s -o /dev/null -w 'no-token /add  -> %{http_code}\n' -X POST http://127.0.0.1:9097/add
# b) 有 token、非 /add → 403
curl -s -o /dev/null -w 'token /pins/x  -> %{http_code}\n' -H "Authorization: Bearer $TOKEN" -X DELETE http://127.0.0.1:9097/pins/x
# c) 有 token、POST /add 小文件 → 200 且返回 cid
echo '<h1>ingress ok</h1>' > /tmp/ing.html
curl -s -w '\ntoken /add     -> %{http_code}\n' -H "Authorization: Bearer $TOKEN" \
  -F "file=@/tmp/ing.html;filename=ing.html" "http://127.0.0.1:9097/add?cid-version=1&expire-in=10m"
```
Expected: (a) `401`；(b) `403`；(c) `200` 且 JSON 含 `"cid":"bafy..."`。

- [ ] **Step 6: Commit**

```bash
git add Makefile caddy/Caddyfile docker-compose.cluster.yml
git commit -m "feat: 新增 token 鉴权上传写入口(:9097 仅放行 /add)"
```

---

### Task 2: 发布技能 skills/publish-artifact（publish.sh + test.sh + SKILL.md）

**Files:**
- Create: `skills/publish-artifact/publish.sh`
- Create: `skills/publish-artifact/test.sh`
- Create: `skills/publish-artifact/SKILL.md`
- Test: `skills/publish-artifact/test.sh`（对接 Task 1 的写入口）

**Interfaces:**
- Consumes: Task 1 的写入口（`$IPFS_PUBLISH_ENDPOINT/add` + Bearer token）。
- Produces: `publish.sh [--permanent] [--expire-in <dur>] [--verify] <file|dir>`，stdout 仅打印一行分享链接；非零退出码表示失败。

- [ ] **Step 1: 写失败测试 test.sh**

Create `skills/publish-artifact/test.sh`:

```bash
#!/usr/bin/env bash
# e2e for publish.sh: single file and directory publishing render over the gateway.
# Requires a running cluster + write ingress (Task 1) and the 3 env vars set.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PUB="$HERE/publish.sh"
PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
ng(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# --- single file ---
tmp=$(mktemp -d)
printf '<!doctype html><meta charset=utf-8><h1>SINGLE_OK</h1>\n' > "$tmp/page.html"
link=$($PUB "$tmp/page.html")
echo "single link: $link"
body=$(curl -fsS "$link" || true)
case "$body" in *SINGLE_OK*) ok "single-file renders";; *) ng "single-file renders (got: $body)";; esac

# --- directory with relative asset ---
mkdir -p "$tmp/site/css"
printf '<!doctype html><meta charset=utf-8><link rel=stylesheet href="./css/app.css"><h1>DIR_OK</h1>\n' > "$tmp/site/index.html"
printf 'h1{color:green}\n' > "$tmp/site/css/app.css"
dlink=$($PUB "$tmp/site")
echo "dir link: $dlink"
ix=$(curl -fsS -o /dev/null -w '%{http_code}' "${dlink}index.html")
cssc=$(curl -fsS -o /dev/null -w '%{http_code}' "${dlink}css/app.css")
[ "$ix" = 200 ] && ok "dir index 200" || ng "dir index ($ix)"
[ "$cssc" = 200 ] && ok "dir css 200" || ng "dir css ($cssc)"

rm -rf "$tmp"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
```

```bash
chmod +x skills/publish-artifact/test.sh
```

- [ ] **Step 2: 运行测试，确认失败**

Run:
```bash
export IPFS_PUBLISH_ENDPOINT=http://127.0.0.1:9097
export IPFS_PUBLISH_TOKEN=$(grep '^IPFS_PUBLISH_TOKEN=' .env | cut -d= -f2)
export IPFS_BASE_URL=http://127.0.0.1:8088
./skills/publish-artifact/test.sh
```
Expected: FAIL（`publish.sh` 不存在 / 不可执行）。

- [ ] **Step 3: 实现 publish.sh**

Create `skills/publish-artifact/publish.sh`:

```bash
#!/usr/bin/env bash
# Publish an HTML file or a directory (multi-asset site) to a private IPFS Cluster
# and print one shareable, immutable link. Stateless: each publish is a new CID.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: publish.sh [--permanent] [--expire-in <dur>] [--verify] <file.html | dir/>
  --permanent      keep forever (omit the default 1-week expiry); use sparingly
  --expire-in DUR  override expiry (default 168h), e.g. 24h, 720h
  --verify         after publishing, GET the link and print its HTTP status
Env (required): IPFS_PUBLISH_ENDPOINT, IPFS_PUBLISH_TOKEN, IPFS_BASE_URL
EOF
  exit 2
}

EXPIRE="168h"; PERMANENT=0; VERIFY=0; TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --permanent) PERMANENT=1; shift ;;
    --expire-in) EXPIRE="${2:?--expire-in needs a value}"; shift 2 ;;
    --verify)    VERIFY=1; shift ;;
    -h|--help)   usage ;;
    -*)          echo "unknown option: $1" >&2; usage ;;
    *)           TARGET="$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || usage
[ -e "$TARGET" ] || { echo "error: not found: $TARGET" >&2; exit 1; }

# Required configuration (fail loudly, never silently succeed).
: "${IPFS_PUBLISH_ENDPOINT:?set IPFS_PUBLISH_ENDPOINT (token write ingress, e.g. https://host:9097)}"
: "${IPFS_PUBLISH_TOKEN:?set IPFS_PUBLISH_TOKEN (bearer token for the write ingress)}"
: "${IPFS_BASE_URL:?set IPFS_BASE_URL (read gateway base, e.g. https://host:8088)}"

Q="cid-version=1"
[ "$PERMANENT" -eq 1 ] || Q="$Q&expire-in=$EXPIRE"
ADD_URL="${IPFS_PUBLISH_ENDPOINT%/}/add"
AUTH="Authorization: Bearer $IPFS_PUBLISH_TOKEN"

if [ -d "$TARGET" ]; then
  # Directory: each file as a part whose filename is the path relative to the site root.
  Q="$Q&wrap-with-directory=true"
  [ -e "$TARGET/index.html" ] || echo "warn: no index.html at root; link will show a directory listing" >&2
  args=()
  while IFS= read -r -d '' f; do
    rel="${f#"$TARGET"/}"
    args+=(-F "file=@$f;filename=$rel")
  done < <(find "$TARGET" -type f -print0)
  resp=$(curl -fsS -H "$AUTH" -X POST "${args[@]}" "$ADD_URL?$Q")
  # The wrap root is the JSON line with an empty name.
  cid=$(printf '%s\n' "$resp" | grep '"name":""' | grep -o '"cid":"[^"]*"' | head -1 | sed 's/.*:"//;s/"//')
  link="${IPFS_BASE_URL%/}/artifact/$cid/"
else
  base=$(basename "$TARGET")
  resp=$(curl -fsS -H "$AUTH" -X POST -F "file=@$TARGET;filename=$base" "$ADD_URL?$Q")
  cid=$(printf '%s\n' "$resp" | grep -o '"cid":"[^"]*"' | head -1 | sed 's/.*:"//;s/"//')
  link="${IPFS_BASE_URL%/}/artifact/$cid"
fi

[ -n "$cid" ] || { echo "error: publish failed; response: $resp" >&2; exit 1; }

if [ "$VERIFY" -eq 1 ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' "$link")
  echo "verify: GET $link -> $code" >&2
fi

echo "$link"
```

```bash
chmod +x skills/publish-artifact/publish.sh
```

- [ ] **Step 4: 运行测试，确认通过**

Run:
```bash
./skills/publish-artifact/test.sh
```
Expected: PASS（`single-file renders` / `dir index 200` / `dir css 200`），末尾 `PASS=3 FAIL=0`，退出码 0。

- [ ] **Step 5: 写 SKILL.md**

Create `skills/publish-artifact/SKILL.md`:

```markdown
---
name: publish-artifact
description: 把一段 HTML（单文件或带资源的目录站点）发布到私有 IPFS Cluster，拿到不可变的可分享链接。当用户/Agent 说"把这个页面发出来 / 给我个分享链接 / 发布这个 HTML / host 这个 artifact"时使用。每次发布是一个新快照（新 CID/新链接），默认 1 周后自动失效。需先配置 3 个环境变量指向已部署的集群。
---

# 发布 Artifact 到私有 IPFS Cluster

把 Agent 生成的 HTML 发布成内容寻址的不可变快照，返回可分享链接。语义类似 Claude Artifacts，但每次发布得到一个新的不可变链接（内容改了就是新链接，旧版本永久可达）。

## 前置：配置（用前一次）

技能靠 3 个环境变量指向你们已部署的集群：

```bash
export IPFS_PUBLISH_ENDPOINT=https://<host>:9097   # token 写入口（仅 POST /add）
export IPFS_PUBLISH_TOKEN=<从集群 .env 的 IPFS_PUBLISH_TOKEN 取>
export IPFS_BASE_URL=https://<host>:8088           # 读网关 base
```

> token 由集群运维在集群侧 `make secrets` 生成（写入集群 `.env`），分发给被授权的 Agent。

## 用法

```bash
# 单文件
./publish.sh page.html
# → https://<host>:8088/artifact/<cid>

# 目录站点（含 index.html 与相对资源 css/js/img）
./publish.sh ./site
# → https://<host>:8088/artifact/<dirCID>/

# 临时草稿：自定义过期（默认 168h=1周）
./publish.sh --expire-in 24h page.html

# 永久（特殊情况才用，避免长期堆积）
./publish.sh --permanent page.html

# 发布后顺带校验链接可访问
./publish.sh --verify page.html
```

stdout 只打印一行链接，便于脚本捕获。

## 行为与约束

- **不可变快照**：每次发布一个新 CID/链接；不做原地更新。
- **默认 1 周过期**：到期集群自动 unpin；`--permanent` 才永久。
- **目录**：用 `wrap-with-directory`，文件名取相对站点根路径；要求根有 `index.html`（否则链接是目录列表）。
- **无删除**：技能不提供取消发布（无 owner 鉴权，删除是管理员用 `ipfs-cluster-ctl` 的事）；清理靠过期。
- **CIDv1**：强制 `cid-version=1`。

## 自测

```bash
# 需先 export 上面 3 个 env，且集群与写入口在跑
./test.sh   # 断言单文件与目录发布均可经网关渲染
```

相关（集群侧）：`docs/SINGLE_HOST_DEPLOYMENT.md`、`docs/CLUSTER_CTL_REFERENCE.md`。
```

- [ ] **Step 6: Commit**

```bash
git add skills/publish-artifact/
git commit -m "feat: 新增 Agent 发布技能 publish-artifact（单文件/目录→不可变分享链接）"
```

---

### Task 3: 仓库结构调整（e2e 技能移入 .claude/skills + gitignore + Makefile + 文档）

**Files:**
- Move: `skills/kubo-cluster-e2e/` → `.claude/skills/kubo-cluster-e2e/`
- Modify: `.gitignore`
- Modify: `Makefile`（删除 `claude-skills` 目标 + `.PHONY`；加 `publish-test`）
- Modify: `README.md`、`docs/SINGLE_HOST_DEPLOYMENT.md`

**Interfaces:**
- Consumes: Task 2 的 `skills/publish-artifact/test.sh`（被 `make publish-test` 调用）。
- Produces: `skills/` 目录仅含对外技能；`.claude/skills/kubo-cluster-e2e` 纳入版本且被 Claude Code 自动加载。

- [ ] **Step 1: gitignore 选择性纳入 .claude/skills/kubo-cluster-e2e**

把 `.gitignore` 中现有的 `.claude/skills/` 与 `.claude/` 两行替换为：

```gitignore
# .claude/ 默认忽略，但纳入随仓库分发的内部开发技能
.claude/*
!.claude/skills
.claude/skills/*
!.claude/skills/kubo-cluster-e2e
```

- [ ] **Step 2: 移动 e2e 技能**

Run:
```bash
mkdir -p .claude/skills
git mv skills/kubo-cluster-e2e .claude/skills/kubo-cluster-e2e
git status --short
git check-ignore -v .claude/skills/kubo-cluster-e2e/SKILL.md || echo "NOT ignored (correct)"
```
Expected: `SKILL.md` 等显示为待提交（renamed）；`git check-ignore` 输出 `NOT ignored (correct)`（即未被忽略）。

- [ ] **Step 3: Makefile 删 claude-skills、加 publish-test**

修改 `Makefile`：从 `.PHONY` 行移除 `claude-skills`、加入 `publish-test`；删除整个 `claude-skills:` 目标块；在末尾追加：

```makefile
publish-test: up ## 测试发布技能(需 .env 的 token；自动 export 3 个 env 后跑 skill 自测)
	@IPFS_PUBLISH_ENDPOINT=http://127.0.0.1:9097 \
	 IPFS_PUBLISH_TOKEN=$$(grep '^IPFS_PUBLISH_TOKEN=' .env | cut -d= -f2) \
	 IPFS_BASE_URL=http://127.0.0.1:8088 \
	 ./skills/publish-artifact/test.sh
```

`.PHONY` 行改为：

```makefile
.PHONY: help secrets up webui e2e e2e-keep down publish-test
```

> 注：若仓库当前 `.PHONY` 不含 `webui`（取决于历史），以实际现存目标为准，仅做"去掉 claude-skills、加 publish-test"两处增删。

- [ ] **Step 4: 验证 make 仍可用**

Run:
```bash
make help
grep -n 'claude-skills' Makefile || echo "claude-skills removed (correct)"
```
Expected: `help` 列出 `publish-test`，不再有 `claude-skills`；grep 输出 `claude-skills removed (correct)`。

- [ ] **Step 5: 文档化写入口与发布技能**

在 `docs/SINGLE_HOST_DEPLOYMENT.md` 的端口表（§2）追加一行：

```markdown
| `9097` | Caddy 上传写入口 | **Agent 发布**：token 鉴权，仅放行 `POST /add` → cluster REST `:9094` |
```

在 `README.md` 的"目录结构"块把 skills 两行更新为：

```markdown
skills/publish-artifact/     对外可安装技能：Agent 发布 HTML→不可变分享链接
.claude/skills/              本仓库内部开发技能（如 kubo-cluster-e2e 测试 runbook）
```

并在 README"快速开始"的命令块追加一行：

```markdown
make publish-test  # 可选：测试 Agent 发布技能（单文件/目录→分享链接）
```

- [ ] **Step 6: 跑一遍发布技能集成测试**

Run:
```bash
make publish-test
```
Expected: `PASS=3 FAIL=0`，退出码 0。

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: skills 目录分置(对外/内部)、补发布技能文档与 make publish-test"
```

---

## Self-Review

**1. Spec coverage:**
- 不可变快照 / 无命名层 → Task 2 `publish.sh`（每次新 CID，无 IPNS）。✓
- 可移植 + 3 env → Task 2（`: "${VAR:?}"` 强校验）。✓
- 路径式分享链接 → Task 2（`<BASE>/artifact/<cid>`）。✓
- 无状态发布器：单文件+目录、默认 1 周、permanent 特殊、无取消发布 → Task 2 全覆盖。✓
- token 写入口仅 /add → Task 1（route + 401/403）。✓
- skills 目录分置 + e2e 移入 .claude + 删软链 → Task 3。✓
- 测试（技能 e2e + 闸门断言）→ Task 1 Step 5 + Task 2 test.sh。✓

**2. Placeholder scan:** 无 TBD/TODO；所有脚本/配置为完整内容。`<host>`、`<cid>`、`<token>` 为运行时占位示例，非待补。✓

**3. Type/name consistency:** env 名 `IPFS_PUBLISH_ENDPOINT`/`IPFS_PUBLISH_TOKEN`/`IPFS_BASE_URL`、端口 `9097`、路径 `/add`、`publish.sh` 参数 `--permanent/--expire-in/--verify` 在 Task 1/2/3 与 SKILL.md 中一致。✓
