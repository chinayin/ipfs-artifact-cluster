---
name: kubo-cluster-e2e
description: 起栈并端到端测试/演示私有 IPFS Cluster（Kubo）HTML 托管——单机 3 节点 docker-compose。生成机密 → 起集群（含 Caddy 反代）→ 校验三 peer 成形 → 经 cluster 代理(:9095)上传 HTML → 断言三节点副本 PINNED → 网关(:8080)渲染 → /artifact(:8088)友好路径 → 停一个节点仍可读 → 收摊。提供一键脚本与手动逐步两条路径，并附实测踩坑。当需要手动测试或演示本项目的 IPFS 集群全链路（上传→多副本→网关渲染→故障容忍）时使用。
---

# Kubo IPFS Cluster 端到端测试 / 演示 runbook

私有化 HTML 托管全链路实测：**起栈(3 节点集群 + Caddy)→ 经 cluster 代理上传 → 三节点自动多副本 → 网关渲染 → /artifact 友好路径 → 停节点仍可读 → 收摊**。全部用真实 `curl` / `ipfs-cluster-ctl` 断言，不靠"应该能跑"。

> 本项目已无 v1 单节点，统一到 Cluster；"单节点"= 跑 1 节点的集群（见 `docs/MULTI_HOST_DEPLOYMENT.md` §3.4）。本 runbook 针对**单宿主机三容器**试验形态（`docker-compose.cluster.yml`）。

## 约定与前置

```bash
REPO=$(git rev-parse --show-toplevel)
COMPOSE="docker compose -f docker-compose.cluster.yml"   # 单机 3 节点 + Caddy
PROXY=http://localhost:9095     # cluster IPFS 代理 —— Agent 上传打这里
GW=http://localhost:8080        # ipfs0 原生网关 —— /ipfs/<CID>
ART=http://localhost:8088       # Caddy 反代 —— /artifact/<CID>（重写到 /ipfs）
CTL="docker exec cl-cluster0 ipfs-cluster-ctl"           # 集群管理
```

- 镜像锁版本：`kubo v0.42.0` / `ipfs-cluster v1.1.6` / `caddy:2-alpine`。
- 机密：`.env`(CLUSTER_SECRET) 与 `runtime/private/swarm.key`（私有网络），均 gitignored。缺失会被脚本拦下。
- 运行时数据在 `runtime/`（整体 gitignored），重启不丢；`down -v` 才清。
- 文档：部署见 `docs/SINGLE_HOST_DEPLOYMENT.md`，接入见 `docs/AGENT_INTEGRATION_GUIDE.md`，边界/运维见 `docs/CAPABILITIES_AND_OPERATIONS.md`。

## 0. 起栈

> **⚠️ 起栈前必查端口占用**：`8080/9094/9095/8088` 若被本机其它容器占用（例如以前的单节点 `kubo-poc`、或别的服务），`up` 会报 `port is already allocated`。先 `docker ps` 看一眼，冲突的先停。

```bash
cd "$REPO"
make secrets          # 幂等生成 .env + swarm.key（已存在则跳过）
$COMPOSE up -d        # 起 3×(kubo+cluster) + caddy

# 等 cluster 代理就绪（最多 ~150s；首次要拉镜像会更久）
for i in $(seq 1 150); do curl -fsS -X POST "$PROXY/api/v0/version" >/dev/null 2>&1 && { echo "proxy ready"; break; }; sleep 1; done

# 等三 peer 成形（应为 3）
for i in $(seq 1 60); do n=$($CTL --enc=json peers ls 2>/dev/null | grep -o '"peername"' | wc -l | tr -d ' '); [ "${n:-0}" -ge 3 ] && break; sleep 2; done
$CTL peers ls         # 直观确认 cluster0/1/2 都在
```

## 1. 一键 e2e（推荐）

覆盖：①三 peer 成形 ②经 :9095 上传 ③副本=3 ④网关渲染 ⑤/artifact 路径 ⑥停一个节点仍可读。

```bash
make e2e          # = ./e2e/run-cluster.sh（跑完自动 down）
make e2e-keep     # = ./e2e/run-cluster.sh --keep（保留集群继续手测）
```

退出码非 0 即失败；末尾打印 `PASS=N FAIL=M`，并生成自包含 HTML 报告 `runtime/e2e/<时间戳>/report.html`（可直接发人/归档）。失败时不要清栈，照 §3 的排查命令看日志。

## 2. 手动逐步（演示 / 排查用）

```bash
# ② 上传一个 HTML（务必走 :9095 cluster 代理，pin 才会全集群生效）
echo '<!doctype html><meta charset=utf-8><h1>HELLO_CLUSTER</h1>' > /tmp/demo.html
CID=$(curl -fsS -F "file=@/tmp/demo.html" "$PROXY/api/v0/add?cid-version=1&pin=true" \
      | grep -o '"Hash":"[^"]*"' | sed 's/.*:"//;s/"//')
echo "CID=$CID"

# ③ 副本分布：应三节点 PINNED
$CTL status "$CID"

# ④ 原生网关渲染：200 + text/html + 正文
curl -fsSI "$GW/ipfs/$CID" | grep -iE 'HTTP/|content-type'
curl -fsS  "$GW/ipfs/$CID"

# ⑤ /artifact 友好路径（经 Caddy）：等价但前缀友好
curl -fsSI "$ART/artifact/$CID" | grep -iE 'HTTP/|content-type'
curl -fsS  "$ART/artifact/$CID"

# ⑥ 故障容忍：停一个 kubo，仍能从其余节点读
docker stop cl-ipfs1
curl -s -o /dev/null -w 'after stop: %{http_code}\n' "$GW/ipfs/$CID"   # 仍 200
docker start cl-ipfs1
```

> 浏览器演示：直接打开 `http://localhost:8088/artifact/<CID>`。
> 目录站点（相对资源）：用 `wrap-with-directory=true` 上传，访问 `/artifact/<dirCID>/index.html`，相对资源一并解析。详见 `docs/AGENT_INTEGRATION_GUIDE.md`。

## 3. 排查

```bash
$COMPOSE ps                         # 容器状态（kubo 应 healthy）
docker logs cl-ipfs0 2>&1 | tail -30
docker logs cl-cluster0 2>&1 | tail -30
docker exec cl-ipfs0 ipfs swarm peers          # kubo 私有 mesh 互联数（应 >=2）
$CTL peers ls
docker exec cl-caddy caddy validate --config /etc/caddy/Caddyfile
```

## 4. 收摊

```bash
$COMPOSE down            # 停容器，数据保留在 runtime/
# $COMPOSE down -v       # 连卷一起清（runtime/ 是 bind mount，需另删目录）
# rm -rf runtime/cluster # 彻底重置集群身份/数据（下次全新起）
```

## 踩过的坑（务必知道）

- **私有网必须关 AutoConf**：Kubo v0.42 一旦检测到 `swarm.key`，会拒绝用默认 mainnet autoconf URL，daemon **启动即崩溃重启**。`scripts/init-cluster.d/001-config.sh` 里已 `ipfs config --json AutoConf.Enabled false`。
- **cluster 代理 502 = `ipfsproxy` 的 node 地址没配对**：`ipfsproxy` 组件有**独立于** `ipfshttp` 的 `node_multiaddress`，只配 `CLUSTER_IPFSHTTP_NODEMULTIADDRESS` 不够，代理仍拨默认 `127.0.0.1:5001` → 502。两个都要指向本地 kubo（compose 里 `CLUSTER_IPFSPROXY_NODEMULTIADDRESS` 已配）。
- **私有网下别靠 mDNS 发现**：官方示例的 kubo 连公网靠公网 DHT 互相发现；我们 `swarm.key` 私有网断了这条路，而 mDNS 在 Docker bridge 网络组播不可靠。本项目改用**确定性方案**：种子节点 `ipfs0` + 其余节点 bootstrap 到它的 PeerID（`scripts/init-cluster.d` 自动完成）。kubo 节点必须互联副本才复制得动。
- **上传必须走 :9095，不是某个 kubo 的 :5001**：直连 5001 上传的内容 cluster **不感知、不复制**。
- **端口占用**：本项目早期的单节点 `kubo-poc` 占 `8080/5001`；起集群前若它或别的容器在跑，会 `port is already allocated`。先 `docker ps` 排查停掉。
- **e2e 脚本 `set -euo pipefail` + `grep`**：`grep` 无匹配返回非零会连带退出脚本——计数类管道要 `|| true` 兜底。
- **bash 变量后紧跟中文全角字符**：`"$pinned（…"` 会把多字节首字节并进变量名触发 `set -u` "unbound variable"；变量名要加花括号 `"${pinned}（…"`。
- **`/ipfs` 命名空间不可改名**：Kubo 网关固定 `/ipfs`、`/ipns`，没有配置项改成 `/artifact`。友好前缀靠 Caddy 反代 `uri replace /artifact/ /ipfs/` 实现（`caddy/Caddyfile`），这层将来也承载 LB/TLS/鉴权/短链。
- **副本恢复 vs 备份**：多副本只防硬件故障；删 pin 会全集群同步删，**不防误删**——仍要备份 `runtime/`。

相关：`docs/SINGLE_HOST_DEPLOYMENT.md` · `docs/MULTI_HOST_DEPLOYMENT.md` · `docs/CAPABILITIES_AND_OPERATIONS.md` · `docs/AGENT_INTEGRATION_GUIDE.md`
