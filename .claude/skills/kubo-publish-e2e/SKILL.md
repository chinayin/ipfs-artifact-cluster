---
name: kubo-publish-e2e
description: 端到端测试/演示 Agent **发布链路**——经 token 写入口(:9097, 仅 POST /add)用 skills/publish-artifact/publish.sh 把 HTML（单文件或带资源目录）发布到私有 IPFS Cluster，拿到不可变分享链接。校验：写入口鉴权闸门(401/403) → 单文件发布渲染 → 目录站点(相对资源)渲染 → 默认 1 周过期已设 → --permanent 无过期。一键脚本 e2e/run-publish.sh 自起栈、出 HTML 报告。当需要测试或演示"Agent 发布 → 分享链接"这条产品链路时使用。集群本身（成形/多副本/容错）的部署 e2e 见 kubo-deploy-e2e 技能。
---

# Kubo 发布链路 e2e / 演示 runbook

验"**Agent 发布链路**对不对"：**token 写入口闸门 → publish.sh 单文件/目录发布 → 分享链接渲染 → 默认过期/永久**。全部真实 `curl` / `publish.sh` / `ipfs-cluster-ctl` 断言。

> 这是**发布 e2e**。集群**基础设施**（3 peer 成形、多副本、网关、停节点容错）的 e2e 见 **kubo-deploy-e2e** 技能 / `make e2e`。

## 约定与前置

```bash
REPO=$(git rev-parse --show-toplevel)
ENDPOINT=http://localhost:9097   # token 写入口（仅 POST /add）—— Agent 发布打这里
BASE=http://localhost:8088       # 读网关 base —— /artifact/<CID>
PUBLISH="$REPO/skills/publish-artifact/publish.sh"
TOKEN=$(grep '^IPFS_PUBLISH_TOKEN=' "$REPO/.env" | cut -d= -f2)
```

- 镜像锁版本：`kubo v0.42.0` / `ipfs-cluster v1.1.6` / `caddy:2-alpine`。
- 机密：`.env`(CLUSTER_SECRET + **IPFS_PUBLISH_TOKEN**) 与 `runtime/private/swarm.key`，均 gitignored。`make secrets` 幂等生成。
- 发布技能契约：3 个 env `IPFS_PUBLISH_ENDPOINT` / `IPFS_PUBLISH_TOKEN` / `IPFS_BASE_URL`。
- 文档：写入口与发布见 `docs/SINGLE_HOST_DEPLOYMENT.md` §5、`docs/AGENT_INTEGRATION_GUIDE.md`。

## 1. 一键 e2e（推荐）

覆盖：①写入口闸门(无 token→401、token+GET /add→403、token+DELETE /pins→403) ②单文件发布渲染 ③目录站点渲染(index+css) ④默认 1 周过期已设 ⑤--permanent 无过期。

```bash
make publish-e2e        # = ./e2e/run-publish.sh（自起栈，跑完自动 down）
make publish-e2e-keep   # = ./e2e/run-publish.sh --keep（保留集群继续手测）
```

退出码非 0 即失败；末尾打印 `PASS=N FAIL=M`，并生成自包含 HTML 报告 `runtime/e2e/<时间戳>-publish/report.html`。失败时不要清栈，照 §3 排查。

## 2. 手动逐步（演示 / 排查用）

```bash
cd "$REPO"
export IPFS_PUBLISH_ENDPOINT="$ENDPOINT" IPFS_PUBLISH_TOKEN="$TOKEN" IPFS_BASE_URL="$BASE"

# ① 写入口闸门
curl -s -o /dev/null -w 'no-token: %{http_code}\n' -X POST "$ENDPOINT/add"                                   # 401
curl -s -o /dev/null -w 'GET /add: %{http_code}\n' -H "Authorization: Bearer $TOKEN" "$ENDPOINT/add"          # 403
curl -s -o /dev/null -w 'DELETE pins: %{http_code}\n' -H "Authorization: Bearer $TOKEN" -X DELETE "$ENDPOINT/pins/x"  # 403

# ② 单文件发布 → 链接渲染
echo '<!doctype html><meta charset=utf-8><h1>HELLO_PUBLISH</h1>' > /tmp/p.html
link=$("$PUBLISH" /tmp/p.html); echo "link=$link"
curl -fsS "$link"                                    # 应见正文

# ③ 目录站点（相对资源）
mkdir -p /tmp/site/css
echo '<!doctype html><meta charset=utf-8><link rel=stylesheet href="./css/app.css"><h1>DIR</h1>' > /tmp/site/index.html
echo 'h1{color:green}' > /tmp/site/css/app.css
dlink=$("$PUBLISH" /tmp/site); echo "dlink=$dlink"
curl -fsSI "${dlink}index.html" | grep -i 'HTTP/'    # 200
curl -fsSI "${dlink}css/app.css" | grep -i 'HTTP/'   # 200

# ④ 默认 1 周过期：pin 应有 expire_at
cid=$(printf '%s' "$link" | sed "s#$BASE/artifact/##; s#/\$##")
docker exec cl-cluster0 ipfs-cluster-ctl --enc=json pin ls "$cid" | grep expire_at

# ⑤ 永久发布：无 expire_at
plink=$("$PUBLISH" --permanent /tmp/p.html)          # 注意 --permanent 应少量使用
```

> 浏览器演示：直接打开 `$link`（单文件）或 `$dlink`（目录站点）。

## 3. 排查

```bash
docker compose -f docker-compose.cluster.yml ps              # 容器状态
docker exec cl-caddy caddy validate --config /etc/caddy/Caddyfile
docker logs cl-caddy 2>&1 | tail -30                         # 写入口/反代日志
# 改了 caddy/Caddyfile 后 bind-mount 不会自动热更：
docker exec cl-caddy caddy reload --config /etc/caddy/Caddyfile
docker exec cl-cluster0 ipfs-cluster-ctl pin ls <CID>        # 看 pin 期望态/过期
```

## 踩过的坑（务必知道）

- **写入口只放行 POST /add**：`caddy/Caddyfile` 的 `:9097` 先校验 Bearer token（否则 401），再要求 `method POST` + `path /add`（否则 403）。GET /add、DELETE /pins 等都 403——Agent 拿不到 unpin/peers 等管理能力。
- **必须走 :9097 + token，不是直连 :9095/:9094**：原生端口不暴露宿主；发布只经带鉴权的写入口。
- **默认 1 周过期**：`publish.sh` 默认 `expire-in=168h`；到期集群自动 unpin。`--permanent` 才永久（少用，防堆积）。无 owner 概念，技能不提供取消发布，清理靠过期 + 管理员 `ipfs-cluster-ctl`。
- **单 CID `pin ls <cid>` 是美化 JSON**（`"expire_at": "..."` 冒号后有空格），而全量 `pin ls` 是 compact——写断言 grep 要容忍空格；permanent pin **无** expire_at 字段。
- **目录链接带尾斜杠**：单文件 `…/artifact/<cid>`，目录 `…/artifact/<root>/`；目录上传文件名取相对站点根路径 + `wrap-with-directory=true`，根的 CID 是响应里 `"name":""` 那行。
- **改 Caddyfile 后需 reload**：`docker compose up -d` 不会因 bind-mount 的 Caddyfile 变化重建容器，需 `docker exec cl-caddy caddy reload`。

相关：**kubo-deploy-e2e**（部署 e2e）· `skills/publish-artifact/`（发布技能本体）· `docs/SINGLE_HOST_DEPLOYMENT.md` §5 · `docs/CLUSTER_CTL_REFERENCE.md`
