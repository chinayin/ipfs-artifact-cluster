# 集群管理：ipfs-cluster-ctl 命令手册

`ipfs-cluster-ctl` 是 [IPFS Cluster](https://ipfscluster.io/) 的官方命令行管理工具，本项目的"管理面"就是它（官方镜像**不带 Web 界面**）。本文是面向日常运维的速查 + 场景手册，对应版本 **v1.1.6**。

---

## 0. 约定与前置

工具内置在每个 cluster 容器里，统一从 `cluster0` 执行（它默认连本机 REST API `:9094`）：

```bash
docker exec cl-cluster0 ipfs-cluster-ctl <命令>
```

嫌长可在 shell 里设别名：

```bash
alias ctl='docker exec cl-cluster0 ipfs-cluster-ctl'
ctl peers ls
```

常用全局选项：

| 选项 | 用途 |
|------|------|
| `--enc json` / `--enc text` | 输出格式；脚本/监控用 `json`（默认 `text`）|
| `--host <multiaddr>` | 连别的 peer，如 `/ip4/127.0.0.1/tcp/9094`；逗号分隔多个则故障转移 |
| `--timeout <秒>` | 请求超时 |

> 🔴 **安全红线**：REST API `:9094` 等同集群写入/管理权，与 kubo `:5001`、代理 `:9095` 同级，**绝不可暴露公网**，仅管理网段可达。详见 [能力边界与运维 §4](./CAPABILITIES_AND_OPERATIONS.md)。

---

## 1. 命令速查

| 命令 | 作用 |
|------|------|
| `peers ls` | 列出所有 peer 及互连情况（看集群是否成形）|
| `id` | 当前 peer 的 ID / 地址 / 版本 |
| `health metrics` | 各 peer 最新指标（freespace / ping / pinqueue）|
| `health alerts` | 失联 / 指标过期告警 |
| `health graph` | peer 互连的 graphviz 连通图 |
| `add [-r] <路径>` | 上传文件/目录并全集群 pin |
| `pin add <CID>` | pin 一个已存在的 CID（按副本因子分配）|
| `pin rm <CID>` | 全集群取消 pin（⚠️ 会同步删，不防误删）|
| `pin ls [<CID>]` | 列出**期望态** pinset（"该 pin 什么"）|
| `status [<CID>]` | 查**落地态**（每节点实际 PINNED/ERROR…）|
| `recover [<CID>]` | 重试处于 error 态的 pin（修副本）|
| `peers rm <peerID>` | 把某个 peer 踢出集群 |
| `ipfs gc` | 对所有节点的 kubo 跑垃圾回收 |
| `version` | 集群版本 |

> **核心心智模型**：`pin ls` 是**期望态**（CRDT 共识里"应该存什么"），`status` 是**落地态**（kubo 里"实际存没存"）。两者不一致（如 `PIN_ERROR`）就用 `recover` 修。

---

## 2. 拓扑与健康

```bash
# 集群成形了吗？应列出全部 peer，每行末尾 "Sees N other peers"
ctl peers ls

# 当前 peer 身份/地址/版本
ctl id

# 各节点最新指标：freespace(剩余空间)/ping(存活)/pinqueue(待 pin 队列)
ctl health metrics

# 失联/过期告警——节点掉了会在这冒出来
ctl health alerts

# 输出连通图（graphviz dot），可视化 peer 互连
ctl health graph
```

`peers ls` 的 `Sees N other peers` 表明该 peer 看到的其它成员数；三节点集群健康时应为 `Sees 2 other peers`。

---

## 3. 内容与 pin

```bash
# 上传文件/目录并全集群 pin（CLI 版，等价于走 :9095 代理上传）
ctl add page.html
ctl add -r ./site                       # 递归目录
ctl add --cid-version 1 page.html       # CIDv1

# 对已存在的 CID 触发集群 pin（按副本因子分配到各节点）
ctl pin add <CID>
ctl pin add -n "我的站点" <CID>          # 带名字，便于在 pin ls 里辨认

# 临时内容：到期自动 unpin（呼应"临时文件"诉求）
ctl pin add --expire-in 720h <CID>      # 30 天后自动取消 pin

# 给单个 pin 指定副本因子（覆盖全局默认）
ctl pin add --rmin 2 --rmax 3 <CID>

# 取消 pin（⚠️ 全集群同步删除，不防误删！）
ctl pin rm <CID>

# 期望态 pinset：集群"应该存什么"
ctl pin ls                              # 全部
ctl pin ls <CID>                        # 单个：副本因子、名字、分配到哪些 peer
```

`pin add` 常用选项：`-r/--rmin/--rmax`（副本因子）、`-n/--name`（名字）、`--allocations`（指定 pin 到哪些 peerID）、`--expire-in`（自动过期）、`--metadata key=value`（附元数据）、`-w/--wait`（等达到最小副本数再返回）。

---

## 4. 状态与排障

```bash
# 落地态：每个 CID 在每个节点的真实状态
ctl status                              # 全部
ctl status <CID>                        # 单个 CID 的各节点分布
ctl status --filter pin_error           # 只看出错的（排障常用）
ctl status --local                      # 只查当前联系的这个 peer
```

**状态值**含义（节选）：

| 状态 | 含义 |
|------|------|
| `pinned` | 已成功 pin（正常）|
| `pinning` / `queued` | 正在 pin / 排队中 |
| `pin_error` | pin 失败（需 `recover`）|
| `remote` | 按副本因子，该内容不分配到本 peer（正常）|
| `unpinned` | 未 pin |
| `unpin_error` | 取消 pin 失败 |

```bash
# 修复：重试所有 error 态的 pin（最常用的"自愈"命令）
ctl recover

# 只修某个 CID
ctl recover <CID>
```

> 节点宕机重启、磁盘短时不可用等导致副本掉到 `pin_error` 时，`recover` 会让集群按副本因子重新把内容 pin 回来。

---

## 5. 运维

```bash
# 对所有节点的 kubo 跑 GC，回收未 pin 的垃圾块（释放空间）
ctl ipfs gc

# 踢出一个 peer（先停掉对应 cluster 容器，再移除）
docker compose -f docker-compose.cluster.yml stop cluster2
ctl peers rm <peerID>                   # peerID 从 `ctl peers ls` 拿
```

**`ctl` 做不了的事**（属于配置层，需改 env/配置 + 重启，不归 ctl 管）：

- 改副本因子默认值 → `docker-compose.cluster.yml` 里的 `CLUSTER_REPLICATIONFACTORMIN/MAX`
- 改 `CLUSTER_SECRET` / `swarm.key`（集群信任根）
- 加/减节点的服务定义

副本因子与节点增减的具体步骤见 [单机部署 §5 运维](./SINGLE_HOST_DEPLOYMENT.md)。

---

## 6. 常见场景速查

| 我想… | 命令 |
|-------|------|
| 确认集群健康 | `ctl peers ls`（看 Sees）+ `ctl health alerts`（无告警）|
| 看某 CID 副本够不够 | `ctl status <CID>`（期望三节点 PINNED）|
| 某节点挂过、修副本 | `ctl recover`（或 `ctl status --filter pin_error` 先看）|
| 上传一个临时页面、30 天自动清 | `ctl pin add --expire-in 720h <CID>` |
| 看磁盘还剩多少 | `ctl health metrics`（看 freespace）|
| 释放空间 | `ctl ipfs gc` |
| 导出给监控/脚本 | 任意命令加 `--enc json` |

---

相关：[单机部署](./SINGLE_HOST_DEPLOYMENT.md) · [多机部署](./MULTI_HOST_DEPLOYMENT.md) · [能力边界与运维](./CAPABILITIES_AND_OPERATIONS.md) · [Agent 接入](./AGENT_INTEGRATION_GUIDE.md)
