# 多机部署指南（ECS/EC2 docker-compose）

本文档说明如何用 docker-compose 把 IPFS Cluster 部署到**多台 ECS/EC2 虚拟机**（同 VPC、跨 VPC 或跨云），组成跨主机的多副本集群；**单节点生产**也用同一套（见 §3.4）。

- 编排文件：`docker-compose.node.yml`（**每台机器跑一份**：一个 kubo + 一个 cluster）
- 环境模板：`.env.node.example`
- 与 [单机集群部署](./SINGLE_HOST_DEPLOYMENT.md) 的关系：后者是**单宿主机三容器**的本地试验；本文是**多机生产形态**。两者共用 `scripts/init-cluster.d/001-config.sh`（脚本按环境变量自适应）。
- K8s（StatefulSet）形态见 §8。

---

## 1. 模型：每台一份，靠真实地址组网

```
   ECS-A（种子）            ECS-B                  ECS-C
 ┌──────────────┐       ┌──────────────┐       ┌──────────────┐
 │ kubo + cluster│◀─────▶│ kubo + cluster│◀─────▶│ kubo + cluster│
 │ 数据盘挂载    │  4001 │ 数据盘挂载    │  4001 │ 数据盘挂载    │
 └──────────────┘  9096 └──────────────┘  9096 └──────────────┘
        ▲ 用户经 8080 网关读取（前置 LB 指向三台）
        ▲ Agent 经 9095 代理上传（限 Agent 网段）
```

每台机器是一个独立 compose 单元；**ipfs-cluster 不关心节点怎么启动**，只要满足：
1. 各节点 **4001（kubo swarm）/ 9096（cluster swarm）互相可达**；
2. 各节点**宣告正确的对外地址**（`ANNOUNCE_IP`）；
3. 全集群共享同一 `swarm.key` + `CLUSTER_SECRET`；
4. 各节点身份**持久化在数据盘**（PeerID 稳定）。

> 因此本方案天然支持**混合部署**（部分节点 compose、部分节点其它方式）和**多云**——差别只在 `ANNOUNCE_IP` 填私网还是公网 IP、以及网络如何打通。

---

## 2. 网络与端口（安全组）

| 端口 | 跨主机开放？ | 对谁开放 |
|------|------------|---------|
| `4001` TCP+UDP | ✅ 必须 | **仅集群各节点 IP 互相** |
| `9096` TCP | ✅ 必须 | **仅集群各节点 IP 互相** |
| `8080` 网关 | ✅ | 用户 / LB |
| `9095` 代理（Agent 上传）| 视部署 | **仅 Agent 网段**（默认绑 127.0.0.1）|
| `9094` REST 管理 | ❌ | 仅本机 / 管理网段 |
| `5001` kubo API | ❌ **红线** | 仅本机 |

- **同 VPC**：用私网 IP，安全组放行节点间 4001/9096 即可。
- **跨 VPC / 跨云**：需公网 IP 或 VPN/对等连接打通；`ANNOUNCE_IP` 填对外 IP；`swarm.key` 是接入信任边界，但仍务必用安全组把 4001/9096 限制到已知 peer IP。

---

## 3. 上线步骤（两阶段：先种子，后其余）

多机无法像单机那样自动发现种子 PeerID，需**先启动种子、取到它的两个 PeerID，再填给其余节点**。

### 3.0 各机器通用准备

```bash
# 每台机器都放置同一份机密：
#  - .env（CLUSTER_SECRET 等，见 .env.node.example）
#  - runtime/private/swarm.key（三台完全相同的一份）

# 生成一次，然后分发到每台机器：
echo "CLUSTER_SECRET=$(od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')"   # 写入各机 .env
mkdir -p runtime/private
printf '/key/swarm/psk/1.0.0/\n/base16/\n%s\n' \
  "$(od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')" > runtime/private/swarm.key   # 拷到各机同路径
```

### 3.1 阶段一：启动种子机（ECS-A）

`.env`（关键项）：
```ini
NODE_NAME=node-a
ANNOUNCE_IP=10.0.0.11        # 本机私网/公网 IP
IS_SEED=true                 # 标记为种子
DATA_DIR=/data/ipfs-cluster  # 数据盘
CLUSTER_SECRET=<同集群一致>
```
```bash
docker compose -f docker-compose.node.yml --env-file .env up -d
```

取种子的两个 PeerID（填给其余节点）：
```bash
# kubo PeerID
docker exec ipfs ipfs id -f='<id>\n'
# cluster PeerID
docker exec cluster ipfs-cluster-ctl id | head -1
```

组装成两个 multiaddr（`10.0.0.11` 换成种子的 `ANNOUNCE_IP`）：
```
IPFS_SEED_ADDR        = /ip4/10.0.0.11/tcp/4001/p2p/<种子 kubo PeerID>
CLUSTER_PEERADDRESSES = /ip4/10.0.0.11/tcp/9096/p2p/<种子 cluster PeerID>
```

### 3.2 阶段二：启动其余节点（ECS-B / ECS-C）

各自 `.env`（NODE_NAME / ANNOUNCE_IP 各不同；种子地址填上一步的值）：
```ini
NODE_NAME=node-b
ANNOUNCE_IP=10.0.0.12
DATA_DIR=/data/ipfs-cluster
CLUSTER_SECRET=<同集群一致>
IPFS_SEED_ADDR=/ip4/10.0.0.11/tcp/4001/p2p/<种子 kubo PeerID>
CLUSTER_PEERADDRESSES=/ip4/10.0.0.11/tcp/9096/p2p/<种子 cluster PeerID>
```
```bash
docker compose -f docker-compose.node.yml --env-file .env up -d
```

### 3.3 验证

```bash
# 任一机器上：应列出全部节点
docker exec cluster ipfs-cluster-ctl peers ls

# kubo 层互联确认（peer 数 >= 集群节点数-1）
docker exec ipfs ipfs swarm peers
```

### 3.4 单节点模式（只跑 1 台）

把 v1 单节点的需求并入此方案：只需**跑一台**——`.env` 设 `IS_SEED=true`、不填 `IPFS_SEED_ADDR`/`CLUSTER_PEERADDRESSES`，`RF_MIN=RF_MAX=-1`（单节点即 1 份），其余同 3.1：

```bash
docker compose -f docker-compose.node.yml --env-file .env up -d
```

特点：一套配置、将来加机器即扩为多副本（照 3.2 接入）。代价：单节点无冗余（必须备份，见 §5），且比纯单进程多一个 cluster 容器。

---

## 4. Agent 接入与用户访问

上传走 cluster 代理 `:9095`，完整方式见 [Agent接入](./AGENT_INTEGRATION_GUIDE.md)，多机仅地址不同：
- **上传**：`http://<开放9095的机器>:9095/api/v0/add?cid-version=1&pin=true`。生产建议在 ≥2 台开代理 + LB，避免上传单点。
- **读取**：`http://<LB>/ipfs/<CID>`，LB 后端指向各机 `8080`。友好路径 `/artifact/<CID>`（重写到 `/ipfs/`）放在 LB 层做即可——单机用的 Caddy（见 [单机集群部署](./SINGLE_HOST_DEPLOYMENT.md) `caddy/Caddyfile`）可直接搬到这台 LB，后端上游改为各机 `8080`。

---

## 5. 运维要点

- **数据盘**：`DATA_DIR` 指向 ECS 数据盘（非系统盘），`/data/ipfs` 与 `/data/ipfs-cluster` 在其下，节点身份与数据均落盘，重启/重建容器不丢、PeerID 不变。
- **副本因子**：`.env` 的 `RF_MIN`/`RF_MAX`，默认 `-1`（每节点全量）。节点增多想省空间改 `2`/`3`。
- **加节点**：新机器照 3.2 启动（填种子地址）即自动加入。
- **减节点**：`docker compose -f docker-compose.node.yml down` 后，在其它机器 `ipfs-cluster-ctl peers rm <peerID>`。
- **备份**：多副本防硬件故障，**不防误删**（删 pin 全集群同步删），仍需定期备份至少一台的 `DATA_DIR`。详见 [能力边界与运维 §3](./CAPABILITIES_AND_OPERATIONS.md)。

---

## 6. 安全红线（多机版）

- `5001 / 9094 / 9095` 属控制面，**绝不跨主机暴露公网**。
- `4001 / 9096` 必须开放但**用安全组限制到已知 peer IP**，不要对全网开放。
- `CLUSTER_SECRET` 与 `swarm.key` 是集群信任根，按密钥严格保管与分发（建议走云厂商密钥管理，不要明文散落）。
- 跨云走公网时，强烈建议叠加 VPN/专线或至少严格的安全组白名单。

---

## 7. 与单机试验的差异速查

| 项 | 单机试验（03 / `docker-compose.cluster.yml`）| 多机（本文 / `docker-compose.node.yml`）|
|---|---|---|
| 一份 compose | 3 对容器同机 | 1 对容器/机 ×N |
| 节点发现 | 种子 API 自动取 ID | 显式注入种子 multiaddr |
| cluster 互联 | mDNS | `CLUSTER_PEERADDRESSES` |
| announce | 无需 | `ANNOUNCE_IP` 必填 |
| 4001/9096 | 不出宿主 | 跨主机开放（限 peer）|
| 存储 | 本地卷 | ECS 数据盘 |

---

## 8. 与 K8s / Helm 的关系

VM/compose 阶段用本方案即可。若将来上 K8s 生产：

- 官方 [K8s 指南](https://ipfscluster.io/documentation/guides/k8s/) 无生产就绪方案——Operator 仍 alpha（官方明示勿用于生产）、Kustomize 范例陈旧、Helm 仅第三方（Monaparty）。
- 推荐自写 **StatefulSet**（每 peer 一 pod + 稳定网络标识 + PVC + ConfigMap 注入 secret），可参考 Monaparty chart 但需自审。
- 本方案用到的环境变量与端口（`CLUSTER_SECRET`/`CLUSTER_CRDT_*`/9094/9095/9096）可直接平移到 StatefulSet。
