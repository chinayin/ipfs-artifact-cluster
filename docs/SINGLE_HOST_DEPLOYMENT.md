# 单机集群部署（本机试验）

用 [IPFS Cluster](https://ipfscluster.io/) 在**单宿主机三容器**上跑起 3 节点集群，实现内容多副本与故障容忍（解决单节点零冗余问题，见 [能力边界与运维](./CAPABILITIES_AND_OPERATIONS.md) §3）。本文用于本地试验/演示。

> 要部署到**多台 ECS/EC2（生产/跨云）**，见 [多机部署](./MULTI_HOST_DEPLOYMENT.md)；单节点生产也在那里（跑 1 份 node compose）。两者共用同一 `scripts/init-cluster.d` 脚本。

- 编排文件：`docker-compose.cluster.yml`
- consensus：**CRDT**（轻量、无 leader、节点可随时增减）
- 隔离：共享 `swarm.key` 私有网络，**不接触公网 IPFS**
- 节点发现：种子节点（ipfs0）bootstrap + 私有 DHT（**不用 mDNS**，见 §1 说明）
- 副本因子：`-1`（每个节点都 pin，3 份全冗余）

---

## 1. 架构

```
                         ┌──── 节点0 ────┐  ┌──── 节点1 ────┐  ┌──── 节点2 ────┐
  Agent ─上传→ :9095 ───▶│ cluster0      │  │ cluster1      │  │ cluster2      │
  (IPFS 代理,契约同        │   ↕(CRDT:9096) │←→│   ↕           │←→│   ↕           │  集群层:pinset 同步
   /api/v0/add)          │ ipfs0(kubo)   │  │ ipfs1(kubo)   │  │ ipfs2(kubo)   │
  用户 ─读取→ :8080 ─────▶│   ↕(私有swarm) │←→│   ↕           │←→│   ↕           │  数据层:block 交换
                         └───────────────┘  └───────────────┘  └───────────────┘
```

- **集群层**（ipfs-cluster）：通过 CRDT 在三节点间同步「哪些 CID 该被 pin」（私有网络由 `CLUSTER_SECRET` 隔离）。
- **数据层**（kubo）：三节点组成 `swarm.key` 私有 mesh 交换 block；公网 bootstrap 清空、4001 不映射宿主 → 不连公网。
- **每个 CID 在三节点各存一份**：任意一个节点的网关都能独立提供完整内容，挂掉 1～2 个节点不影响读取。

> **为什么不用 mDNS 发现**：官方 compose 示例的 kubo 连**公网 IPFS**，靠公网 DHT 互相发现来复制副本；`CLUSTER_SECRET` 只隔离集群层（9096），**不隔离 kubo 的 swarm**。我们做了 kubo 层私有网（`swarm.key`）满足「数据不外泄」，就失去了公网 DHT 这条发现路径——而 kubo 节点必须互联副本才能复制。私有网下若用 mDNS 发现，Docker 默认 bridge 网络通常不转发组播、并不可靠。故改用**确定性方案**：指定 `ipfs0` 为种子节点，`ipfs1/ipfs2` 启动时（`scripts/init-cluster.d/001-config.sh`）拉取种子 PeerID 并注册为 `bootstrap`，三节点经种子组成私有 DHT mesh。`docker-compose.cluster.yml` 中 `ipfs1/ipfs2` 用 `depends_on: ipfs0` 保证种子先起。

> **上传路径单点（试验期可接受）**：IPFS 代理 `:9095` 在 cluster0/ipfs0 上，故种子节点宕机时**上传**不可用（存储与读取不受影响，因 rf=-1 其余节点各有全量副本）。生产应在多个 cluster peer 上开代理并前置 LB。

---

## 2. 端口

| 端口 | 服务 | 用途 |
|------|------|------|
| `9095` | cluster0 IPFS 代理 | **Agent 上传**（接口同 kubo `/api/v0/add`，但 pin 会全集群生效）|
| `8088` | Caddy 反代 | **用户读取（推荐）**：`/artifact/<CID>` 友好路径 + 三网关轮询 LB |
| `8080` | ipfs0 网关 | 原生网关 `/ipfs/<CID>`（单节点直读，无 LB）|
| `9094` | cluster0 REST API | 管理（`ipfs-cluster-ctl`）|
| `9097` | Caddy 上传写入口 | **Agent 发布**：token 鉴权，仅放行 `POST /add` → cluster REST `:9094` |
| `4001` / `9096` | kubo swarm / cluster swarm | 仅 compose 内网，不映射宿主 |

---

## 3. 首次启动

### 3.1 生成机密（仅一次，二者均不入库）

```bash
# 集群密钥 CLUSTER_SECRET（32 字节 hex），写入 .env
echo "CLUSTER_SECRET=$(od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')" > .env

# 私有网络 swarm.key（三节点共用同一份）
mkdir -p runtime/private
printf '/key/swarm/psk/1.0.0/\n/base16/\n%s\n' \
  "$(od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')" > runtime/private/swarm.key
```

> `.env` 与 `runtime/`（含 `private/`、`cluster/` 等运行时数据）已在 `.gitignore` 中，不会提交。

### 3.2 启动

```bash
docker compose -f docker-compose.cluster.yml up -d
```

### 3.3 验证集群成形

```bash
# 应列出 3 个 peer
docker exec cl-cluster0 ipfs-cluster-ctl peers ls
```

---

## 4. Agent 接入

Agent 经 cluster 代理 `:9095` 上传（接口同 kubo `/api/v0/add`，pin 会全集群生效）：

```bash
curl -fsS -F "file=@page.html" \
  "http://<host>:9095/api/v0/add?cid-version=1&pin=true"
# 返回：{"Name":...,"Hash":"bafy...","Size":...}
```

**访问（两种等价）**：
- 推荐：`http://<host>:8088/artifact/<CID>`（经 Caddy，友好前缀 + 三网关 LB）
- 原生：`http://<host>:8080/ipfs/<CID>`（单节点直读）

> `/artifact/` 由 Caddy 重写为 `/ipfs/`（见 `caddy/Caddyfile`）。Kubo 网关本身的路径命名空间固定为 `/ipfs`、不可改名，友好前缀靠这层反代实现。

完整上传方式（单文件 / 目录 / Python）见 [Agent接入](./AGENT_INTEGRATION_GUIDE.md)。

> 注意：必须走 `:9095`；直连某个 kubo 的 `:5001` 上传的内容**不会**被 cluster 复制。

### 查看某 CID 的副本分布

```bash
docker exec cl-cluster0 ipfs-cluster-ctl status <CID>
# 期望三节点均为 PINNED
```

---

## 5. 运维

### 副本因子调整
默认 `-1`（每节点都 pin）。扩到更多节点后若不想全量复制，改 `docker-compose.cluster.yml` 中：

```yaml
CLUSTER_REPLICATIONFACTORMIN: 2
CLUSTER_REPLICATIONFACTORMAX: 3
```

改后重启集群层即可；存量 pin 可用 `ipfs-cluster-ctl pin update` 重新分配。

### 节点增减
- **加节点**：复制一组 `ipfsN`/`clusterN` 服务（改 `CLUSTER_PEERNAME`、`IPFS_SELF`、卷路径、`NODEMULTIADDRESS`），`up -d` 即自动加入（CRDT + `TRUSTEDPEERS:'*'`，新 kubo 经 `IPFS_SEED=ipfs0` 自动 bootstrap）。
- **减节点**：`docker compose -f docker-compose.cluster.yml stop clusterN`，再 `ipfs-cluster-ctl peers rm <peerID>`。

### ⚠️ 单机试验 → 多机生产的发现机制差异
本 compose 是**单宿主机**三容器，集群层（9096）沿用官方的 mDNS 自动发现（同一 docker 网段组播可用）。**真要容灾必须跨机器部署**，届时 mDNS 不跨主机失效，两层都要改用显式地址：
- **kubo 层**：已是显式种子 bootstrap（跨机时把 `IPFS_SEED` 指向种子机的可达地址 / `Addresses.Announce` 配好对外 IP）。
- **集群层**：给非种子 cluster peer 加 `CLUSTER_PEERADDRESSES=/dns4/<种子机>/tcp/9096/p2p/<cluster0-peerID>` 显式指向种子，替代 mDNS。

### 备份
多副本降低了**硬件故障**风险，但**不防误删/逻辑错误**（删 pin 会全集群同步删除）。仍建议定期备份至少一个节点的 `./runtime/cluster/ipfsN` 卷。详见 [能力边界与运维](./CAPABILITIES_AND_OPERATIONS.md) §3。

### WebUI / 管理面
集群管理统一用 `ipfs-cluster-ctl`（或 REST `:9094`），不为每个 kubo 做 WebUI 联网引导。如确需某个 kubo 的 WebUI，可临时映射其 `5001` 并联网 pin 住 WebUI 资源 CID，非必需。

---

## 6. e2e 测试

```bash
# 前置：已执行 §3.1 生成 .env 与 runtime/private/swarm.key
./e2e/run-cluster.sh           # 跑完自动 down
./e2e/run-cluster.sh --keep    # 保留集群便于排查
```

覆盖用例：①三 peer 成形 → ②经 `:9095` 上传 → ③副本数=3 → ④网关渲染 → ⑤`/artifact` 友好路径（Caddy）→ ⑥停掉一个节点后仍可读。

跑完生成自包含 HTML 报告 `runtime/e2e/<时间戳>/report.html`（单文件，可直接分享）。

---

## 7. 安全

[能力边界与运维 §4.2 安全清单](./CAPABILITIES_AND_OPERATIONS.md#42-生产化安全清单按优先级)全部适用，外加 Cluster 特有项：

- 🔴 **`9094`（REST）和 `9095`（代理）等同管理/写入权**，与 `5001` 同级红线，**绝不可暴露公网**，仅 Agent 网段可达。
- `CLUSTER_SECRET` 与 `swarm.key` 是集群信任根，泄露 = 可加入集群/读取私有网络流量，按密钥严格保管。

> K8s（StatefulSet）形态见 [多机部署](./MULTI_HOST_DEPLOYMENT.md) §8。
