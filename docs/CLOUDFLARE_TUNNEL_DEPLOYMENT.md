# Cloudflare Tunnel 接入（域名 + HTTPS + 零公网端口）

把对外读取入口放到 Cloudflare 之后：由 Cloudflare 边缘提供域名 + TLS，通过 **Cloudflare Tunnel** 反向连到内网的 Caddy，**主机不开任何入站端口、不需要公网 IP**。适合内网 / VPC / NAT 后 / 甚至笔记本演示。

> 另一种形态是 **Caddy 直连公网自动 TLS**（见 [单机部署 §8](./SINGLE_HOST_DEPLOYMENT.md)）：需要公网 IP + 开放 80/443。两者择一，由 `.env` 开关切换（见下文「与直连模式的开关」）。

## 1. 架构

```
                  ┌──────────────────── Cloudflare 边缘 ─────────────────────┐
  用户(浏览器) ───▶│  https://pages.example.com                               │
                  │   ├─ TLS 在此终止（Cloudflare 证书，自动）                 │
                  │   ├─ 边缘缓存（不可变 CID → 可永久缓存，回源极少）          │
                  │   └─ 可选 Cloudflare Access（SSO/邮箱/IP 控"谁能看"）      │
                  └───────────────────────────┬─────────────────────────────┘
                                              │  加密隧道（cloudflared 出站发起，无入站端口）
              ┌───────────────────────────────▼──────────────────────────────┐
              │  你的主机 / VPC（零公网端口、无公网 IP 亦可）                     │
              │                                                                │
              │   cloudflared ──(docker 内网)──▶ Caddy:80                       │
              │                                   │  /artifact/<CID> → /ipfs/<CID>
              │                                   │  + 三网关轮询 LB              │
              │                      ┌────────────┼────────────┐               │
              │                      ▼            ▼            ▼               │
              │                 ipfs0:8080   ipfs1:8080   ipfs2:8080  (kubo 网关) │
              │                                                                │
              │   Agent 发布(写) ─▶ :9097 (token, 仅内网/VPC, 不进隧道)          │
              └────────────────────────────────────────────────────────────────┘
```

要点：
- **读写分离**：读路径经隧道公开（可加 Access）；**写入口 `:9097` 不进隧道**，留在可信内网/VPC（发布是写权限红线）。
- 控制面 `:5001 / :9094 / :9095` 一律不暴露、不进隧道，红线不变。
- Caddy 仍负责 `/artifact→/ipfs` 重写与多网关 LB；Cloudflare 只做边缘（域名 + TLS + 缓存 + 可选鉴权）。

## 2. 配置方法（token 模式，最简）

### 2.1 Cloudflare 侧（在你的账号一次性配）
1. **Zero Trust → Networks → Tunnels → Create a tunnel**，类型选 *Cloudflared*，命名（如 `ipfs-artifact`），创建后**复制 Tunnel Token**。
2. 同页配 **Public Hostname**：
   - Subdomain `pages`、Domain 选你的域名 → 组成 `pages.example.com`；
   - **Service** 填 `http://caddy:80`（隧道连到 docker 网络里的 Caddy 服务）。
   - 保存后 Cloudflare **自动建好 DNS**（CNAME 指向隧道），无需手动加 A 记录。
3. （可选，强烈建议）**Zero Trust → Access → Applications**：为 `pages.example.com` 建策略（邮箱域 / SSO / IP），控制"谁能查看 artifact"。

### 2.2 部署侧（`.env`，不入库）
```bash
CF_TUNNEL_TOKEN=<上一步复制的 token>
IPFS_BASE_URL=https://pages.example.com   # 你的公开域名（分享链接用；TLS 由 Cloudflare 边缘出）
```
然后用 **cloudflare 模式**起栈：
```bash
make up-cloudflare
```
该命令叠加 `docker-compose.cloudflare.yml` overlay：把 **Caddy 固定为 `:80` 明文**、读端口绑回环（无公网）、并起 `cloudflared`；cloudflared 连上 Cloudflare 后，访问 `https://pages.example.com/artifact/<CID>` 即通——全程未开任何公网端口。收摊用 `make down`（两种模式都清）。

> **要点**：Caddy 是否做 TLS **由模式决定**，不由"有没有设域名"决定。
> - 公开域名永远在 `IPFS_BASE_URL`（+ Cloudflare 侧 public hostname）——CF 模式下你**照样有域名**。
> - `SITE_DOMAIN` 只用于 **direct 模式**（Caddy 自动 LE 的站点域名）；CF 模式根本不用它。
> - 真实域名、`CF_TUNNEL_TOKEN` 只放 `.env`，勿写进提交的文件。

### 2.3 发布技能读 base
```bash
IPFS_BASE_URL=https://pages.example.com    # 分享链接用边缘域名
```

### 2.4 CF 模式下「不需要」的东西
- **不需要 TLS 证书**：TLS 在 Cloudflare 边缘终止，后端 Caddy 跑明文 `:80`；不签 Let's Encrypt，`caddy_data` 证书卷闲置（留着无害）。
- **不需要发布 443（甚至 80）**：cloudflared 出站连 Cloudflare，再经 docker 内网访问 `caddy:80`，不经宿主任何端口。`HTTPS_PORT/443` 在本模式纯属多余；`HTTP_PORT` 仅在想本机直连时保留（且应绑回环）。
- 明文那一跳只在主机 docker 内网（cloudflared→caddy），不走公网，**不是** Flexible-SSL 明文回源那种风险。

## 3. 加分项

- **不可变 CID = 边缘强缓存**：artifact 内容寻址、CID 永不变。在 Cloudflare 配 Cache Rule 对 `/artifact/*` 设 Eligible + 长 Edge TTL（或让 Caddy 对该路径下发 `Cache-Control: public, max-age=31536000, immutable`），全球边缘缓存、几乎不回源。
- **Cloudflare Access**：在不动后端的前提下给查看入口加 SSO/邮箱/IP 鉴权，比裸网关安全得多。
- **审计/限流/WAF**：均可在 Cloudflare 侧叠加。

## 4. 与直连模式的开关

同一套编排，用 `make` 开关切换（cloudflare 模式挂一个小 overlay）。**Caddy 是否做 TLS 由模式决定，不由域名决定**；公开域名两种模式都在 `IPFS_BASE_URL`。

| 模式 | 起栈命令 | `.env` 关键项 | Caddy | 公网端口 |
|------|---------|--------------|-------|---------|
| 直连 SSL（默认）| `make up` | `SITE_DOMAIN=pages.example.com`、`HTTP_PORT=80`、`HTTPS_PORT=443`、`IPFS_BASE_URL=https://pages.example.com` | 域名站点 + 自动 LE | 80/443 |
| Cloudflare Tunnel | `make up-cloudflare` | `CF_TUNNEL_TOKEN=…`、`IPFS_BASE_URL=https://pages.example.com` | `:80` 明文 | 零 |

## 5. 落地清单（已实现）

- `docker-compose.cloudflare.yml`：overlay——覆盖 Caddy 为 `:80` 明文、起 `cloudflared`（镜像锁 `2026.6.1`，token 模式）。
- `Makefile`：`make up-cloudflare`（叠加 overlay、读端口绑回环）；`make down` 两种模式通用。
- 你只需在 Cloudflare 侧建 Tunnel + public hostname、把 `CF_TUNNEL_TOKEN` 写进 `.env`，即可 `make up-cloudflare`。

## 6. 脱敏与机密

- 文档/编排文件一律用占位 `pages.example.com`；**真实域名、`CF_TUNNEL_TOKEN` 只放 `.env`（已 gitignore）**。
- 写入口 token、`CLUSTER_SECRET`、`swarm.key` 同样只在 `.env` / `runtime/`，不入库。

相关：[单机部署](./SINGLE_HOST_DEPLOYMENT.md)（含 §8 Caddy 直连公网自动 TLS） · [能力边界与运维](./CAPABILITIES_AND_OPERATIONS.md)
