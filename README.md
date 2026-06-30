# 私有化 IPFS Cluster · HTML 托管

用 [Kubo](https://github.com/ipfs/kubo) + [IPFS Cluster](https://ipfscluster.io/) 在内网 / VPC 私有化部署一套**内容寻址的 HTML 托管**：Agent 上传 HTML，拿到 CID，浏览器经网关直接渲染。多节点自动多副本、故障容忍，数据不外泄公网 IPFS。

适合"公司内部私有化的 Claude Artifact 类需求"——AI 生成的 HTML 附件，托管起来并通过链接远程访问。

## 特性

- **内容寻址托管**：上传即得 CID，网关按 CID 渲染 HTML（含目录 + 相对资源）。
- **多副本 / 故障容忍**：IPFS Cluster（CRDT）把内容 pin 到多个节点，挂掉部分节点不影响读取。
- **私有网络隔离**：`swarm.key` 私有网 + 清空公网 bootstrap，**不接触公网 IPFS**，数据不外泄。
- **友好路径**：Caddy 反代提供 `/artifact/<CID>`（重写到 `/ipfs/`）+ 多网关负载均衡。
- **一套配置 1→N**：单节点起步，加机器即扩为多副本；单机试验与多机 ECS/EC2 部署共用同一套脚本。

## 架构

```
 Agent ─上传→ :9095 ─▶ Cluster 代理 ─┐
                                     ├─ 3×(kubo + ipfs-cluster) 私有 mesh，CRDT 同步 pinset
 用户 ─读取→ :8088/artifact ─▶ Caddy ┘   每个 CID 多节点各存一份
                   └─或 :8080/ipfs/<CID> 原生网关
```

## 快速开始（单机试验）

前置：Docker + Docker Compose v2。

```bash
make up           # 生成机密 + 起 3 节点集群（含 Caddy）
make e2e          # 部署 e2e：集群成形/多副本/网关/容错（出 HTML 报告）
make publish-e2e  # 发布 e2e：token 写入口/单文件/目录/过期（出 HTML 报告）
make down         # 收摊
make help         # 看所有命令
```

上传与访问：

```bash
echo '<h1>hello</h1>' > page.html
CID=$(curl -fsS -F "file=@page.html" "http://localhost:9095/api/v0/add?cid-version=1&pin=true" \
      | grep -o '"Hash":"[^"]*"' | sed 's/.*:"//;s/"//')
open "http://localhost:8088/artifact/$CID"
```

## 文档

| 文档 | 内容 |
|------|------|
| [CAPABILITIES_AND_OPERATIONS](docs/CAPABILITIES_AND_OPERATIONS.md) | 能力边界、pin/GC 数据模型、冗余与备份、安全清单 |
| [AGENT_INTEGRATION_GUIDE](docs/AGENT_INTEGRATION_GUIDE.md) | Agent 接入：上传契约、单文件 / 目录 / Python |
| [SINGLE_HOST_DEPLOYMENT](docs/SINGLE_HOST_DEPLOYMENT.md) | 单机三容器集群部署（本地试验） |
| [MULTI_HOST_DEPLOYMENT](docs/MULTI_HOST_DEPLOYMENT.md) | 多机 ECS/EC2 部署（含单节点模式、K8s 关系） |
| [CLUSTER_CTL_REFERENCE](docs/CLUSTER_CTL_REFERENCE.md) | `ipfs-cluster-ctl` 管理命令手册（速查 + 运维场景） |
| [CLOUDFLARE_TUNNEL_DEPLOYMENT](docs/CLOUDFLARE_TUNNEL_DEPLOYMENT.md) | 经 Cloudflare Tunnel 提供域名+HTTPS（零公网端口）：架构图 + 配置方法 |

## 目录结构

```
docker-compose.cluster.yml   单机 3 节点集群（+ Caddy）
docker-compose.node.yml      多机/单节点部署（每台一份）
.env.node.example            多机部署环境模板
scripts/init-cluster.d/      kubo 容器启动配置脚本
caddy/Caddyfile              /artifact 重写 + 网关 LB
e2e/                         部署 e2e(run-cluster.sh) + 发布 e2e(run-publish.sh)，均出 HTML 报告
skills/publish-artifact/     对外可安装技能：Agent 发布 HTML→不可变分享链接
.claude/skills/              本仓库内部开发技能（kubo-deploy-e2e / kubo-publish-e2e 两个 runbook）
docs/                        文档
```

## 安全提醒

控制面端口（`5001` kubo API / `9094` cluster REST / `9095` 代理）**绝不可暴露公网**；`8080` 网关无鉴权，生产需反代 + 鉴权 + TLS。详见 [CAPABILITIES_AND_OPERATIONS](docs/CAPABILITIES_AND_OPERATIONS.md) §4。

## 许可证

见 [LICENSE](LICENSE)。
