# Cloudflare Tunnel 接入（域名 + HTTPS + 零公网端口）

把对外读取入口放到 Cloudflare 之后：由 Cloudflare 边缘提供域名 + TLS，通过 **Cloudflare Tunnel** 反向连到内网的 Caddy，**主机不开任何入站端口、不需要公网 IP**。适合内网 / VPC / NAT 后 / 甚至笔记本演示。

> 另一种形态是 **Caddy 直连公网自动 TLS**（见 [单机部署 §8](./SINGLE_HOST_DEPLOYMENT.md)）：需要公网 IP + 开放 80/443。两者择一，由 `.env` 开关切换（见下文「与直连模式的开关」）。

## 1. 架构

```
                  ┌──────────────────── Cloudflare 边缘 ─────────────────────┐
  读 用户 ────────▶│  https://pages.example.com          (读，可缓存)          │
  写 Agent ───────▶│  https://pages-publish.example.com  (写，HTTPS + token)   │
                  │   ├─ TLS 在此终止（Cloudflare 证书，自动）                 │
                  │   ├─ 读：边缘缓存（不可变 CID → 可永久缓存，回源极少）      │
                  │   └─ 可选 Cloudflare Access（控"谁能看/谁能发"）           │
                  └───────────────────────────┬─────────────────────────────┘
                                              │  加密隧道（cloudflared 出站发起，无入站端口）
              ┌───────────────────────────────▼──────────────────────────────┐
              │  你的主机 / VPC（零公网端口、无公网 IP 亦可）                     │
              │                                                                │
              │   cloudflared ─┬─(docker 内网)─▶ Caddy:80    读：/artifact→/ipfs + LB
              │                └─(docker 内网)─▶ Caddy:9097  写：token 闸门 → cluster REST
              │                      ┌────────────┬────────────┐               │
              │                      ▼            ▼            ▼               │
              │                 ipfs0:8080   ipfs1:8080   ipfs2:8080  (kubo 网关) │
              │                                                                │
              │   内网/同机 Agent 也可直连 127.0.0.1:9097（不经 CF）             │
              └────────────────────────────────────────────────────────────────┘
```

要点：
- **读写分离，两条 hostname**：读 `pages.example.com → caddy:80`；写 `pages-publish.example.com → caddy:9097`。都经隧道、都 HTTPS、宿主零公网端口。
- **写只靠 token（默认不加 Access）**：caddy `:9097` 校验 `Authorization: Bearer <IPFS_PUBLISH_TOKEN>`；经 CF 走 HTTPS，token 加密在途——比直连 `http://IP:9097`（明文 token）安全得多。想再加一层可选 Access（见 [Cloudflare Access](./CLOUDFLARE_ACCESS.md)）。
- 控制面 `:5001 / :9094 / :9095` 一律不暴露、不进隧道，红线不变。
- 内网/同机 Agent 可直连 `127.0.0.1:9097`，不必绕 CF。
- Caddy 仍负责 `/artifact→/ipfs` 重写与多网关 LB；Cloudflare 只做边缘（域名 + TLS + 缓存 + 可选鉴权）。

## 2. 配置方法（token 模式，最简）

### 2.1 Cloudflare 侧（在你的账号一次性配）
1. **Zero Trust → Networks → Tunnels → Create a tunnel**，类型选 *Cloudflared*，命名（如 `ipfs-artifact`），创建后**复制 Tunnel Token**。
2. 配 **两个 Public Hostname**（同一 Tunnel 下）：
   - **读**：`pages.example.com` → Service `http://caddy:80`
   - **写**：`pages-publish.example.com` → Service `http://caddy:9097`
   - 保存后 Cloudflare **自动建好 DNS**（CNAME 指向隧道），无需手动加 A 记录。
   - 写入口靠 caddy 的 `Authorization: Bearer` token 闸门鉴权，经 CF 走 HTTPS → **只用原 token、不必加 Access**。
3. （可选）**Zero Trust → Access → Applications**：想在 token 之外再加一层"谁能看/谁能发"，可给 `pages.example.com`（人：SSO/邮箱/IP）或 `pages-publish.example.com`（机器：service token）建策略。详见 [Cloudflare Access](./CLOUDFLARE_ACCESS.md)。**默认不需要**。

### 2.2 部署侧（`.env`，不入库）
```bash
CF_TUNNEL_TOKEN=<上一步复制的 token>
IPFS_BASE_URL=https://pages.example.com   # 你的公开域名（分享链接用；TLS 由 Cloudflare 边缘出）
```
然后用 **cloudflare 模式**起栈：
```bash
make up-cloudflare
```
该命令叠加 `docker-compose.cloudflare.yml` overlay：把 **Caddy 固定为 `:80` 明文**、用 Compose `!override` **清掉宿主读端口**（读路径全走隧道）、仅留 token 写入口 `9097`、并起 `cloudflared`；cloudflared 连上 Cloudflare 后，访问 `https://pages.example.com/artifact/<CID>` 即通——读路径零宿主端口。收摊用 `make down`（两种模式都清）。

> **要点**：Caddy 是否做 TLS **由模式决定**，不由"有没有设域名"决定。
> - 公开域名永远在 `IPFS_BASE_URL`（+ Cloudflare 侧 public hostname）——CF 模式下你**照样有域名**。
> - `SITE_DOMAIN` 只用于 **direct 模式**（Caddy 自动 LE 的站点域名）；CF 模式根本不用它。
> - 真实域名、`CF_TUNNEL_TOKEN` 只放 `.env`，勿写进提交的文件。

### 2.3 发布技能配置（读 base + 写 endpoint）
```bash
IPFS_BASE_URL=https://pages.example.com                 # 读：分享链接用边缘域名
IPFS_PUBLISH_ENDPOINT=https://pages-publish.example.com # 写：CF 写 hostname（HTTPS + 原 token）
IPFS_PUBLISH_TOKEN=<= 服务器 .env 的 IPFS_PUBLISH_TOKEN>  # 写入口 Bearer token
```
- **外部 Agent**：`IPFS_PUBLISH_ENDPOINT=https://pages-publish.example.com`（HTTPS，token 不裸奔）。
- **内网/同机 Agent**：`IPFS_PUBLISH_ENDPOINT=http://127.0.0.1:9097`（不经 CF，最低延迟）。
- `publish.sh` 无需改动，识别这三个 env 即可（见 `skills/publish-artifact/SKILL.md`）。

### 2.4 CF 模式下「不需要」的东西
- **不需要 TLS 证书**：TLS 在 Cloudflare 边缘终止，后端 Caddy 跑明文 `:80`；不签 Let's Encrypt，`caddy_data` 证书卷闲置（留着无害）。
- **不需要发布 443（甚至 80）**：cloudflared 出站连 Cloudflare，再经 docker 内网访问 `caddy:80`，不经宿主任何端口。`HTTPS_PORT/443` 在本模式纯属多余；`HTTP_PORT` 仅在想本机直连时保留（且应绑回环）。
- 明文那一跳只在主机 docker 内网（cloudflared→caddy），不走公网，**不是** Flexible-SSL 明文回源那种风险。

## 3. 加分项

### 3.1 不可变 CID = 边缘强缓存（强烈建议）

artifact 内容寻址、CID 永不变，是"可永久缓存"的完美对象。**源站无需改动**——kubo 网关对 CID 已自带
`Cache-Control: public, max-age=29030400, immutable` + `Etag`，Cloudflare 会原样透传。

但 **Cloudflare 默认不缓存无扩展名/HTML 内容**（`/artifact/<cid>` 正是这种），所以默认看到的是
`cf-cache-status: DYNAMIC`（不缓存）。需手动加**一条 Cache Rule** 把它标成可缓存：

> Cloudflare 控制台 → **Caching → Cache Rules → Create rule**

| 项 | 设置 |
|----|------|
| 名称 | `cache-artifacts` |
| 匹配（When…match）| Field=`URI Path`，Operator=`starts with`，Value=`/artifact/`（表达式：`starts_with(http.request.uri.path, "/artifact/")`）|
| Cache eligibility | **Eligible for cache**（Cache Everything）|
| Edge TTL | **Use cache-control header if present, bypass cache if not**（尊重源站）|
| Browser TTL | Respect origin |

要点：
- Edge TTL 选"尊重源站头" → 只有带 immutable 头的**成功响应**被缓（≈336 天）；`404/504` 这类没缓存头的**不缓**，天然避开"缓住刚发布还没复制好的瞬时错误"。
- 每个 CID 是独立 URL、内容不可变 → 边缘缓存命中后**永久有效、无失效问题**。
- 验证：连续 curl 同一链接两次，`cf-cache-status` 应从 `MISS` 变 `HIT`，`age` 头随之增长。

### 3.2 其它
- **Cloudflare Access**：在不动后端的前提下给"谁能访问"加鉴权（读入口 SSO/邮箱/IP、写入口 service token）。详见 [Cloudflare Access](./CLOUDFLARE_ACCESS.md)。
- **审计/限流/WAF**：均可在 Cloudflare 侧叠加。

## 4. 与直连模式的开关

同一套编排，用 `make` 开关切换（cloudflare 模式挂一个小 overlay）。**Caddy 是否做 TLS 由模式决定，不由域名决定**；公开域名两种模式都在 `IPFS_BASE_URL`。

| 模式 | 起栈命令 | `.env` 关键项 | Caddy | 公网端口 |
|------|---------|--------------|-------|---------|
| 直连 SSL（默认）| `make up` | `SITE_DOMAIN=pages.example.com`、`HTTP_PORT=80`、`HTTPS_PORT=443`、`IPFS_BASE_URL=https://pages.example.com` | 域名站点 + 自动 LE | 80/443 |
| Cloudflare Tunnel | `make up-cloudflare` | `CF_TUNNEL_TOKEN=…`、`IPFS_BASE_URL=https://pages.example.com`、`IPFS_PUBLISH_ENDPOINT=https://pages-publish.example.com` | `:80` 明文 | 零 |

## 5. 落地清单（已实现，并已真机实测）

- `docker-compose.cloudflare.yml`：overlay——覆盖 Caddy 为 `:80` 明文、用 `!override` 清掉读端口；**写入口 `9097` 仅绑回环**（不公网），远程发布经 CF 写 hostname `pages-publish.example.com`（HTTPS + 原 token）到达 `caddy:9097`；起 `cloudflared`（镜像锁 `2026.6.1`，token 模式）。
- `Makefile`：`make up-cloudflare`（叠加 overlay，一行）；`make down` 两种模式通用。
- 你只需在 Cloudflare 侧建 Tunnel + 两个 public hostname（读 `→caddy:80`、写 `→caddy:9097`）、把 `CF_TUNNEL_TOKEN` 写进 `.env`，即可 `make up-cloudflare`。

> **已实测**（真机）：cloudflared 连通、`https://<读域名>/artifact/<CID>` 公网 200（单文件 + 目录站点）、CF 边缘真证书 + HTTP/2、宿主零公网读端口（`localhost:8088` 拒连、caddy 仅回环 9097）、边缘缓存 `cf-cache-status: HIT` 且 `age` 增长。写入口经 CF 写 hostname + 原 token（HTTPS）发布验证同样通过。

## 6. 脱敏与机密

- 文档/编排文件一律用占位 `pages.example.com`（读）、`pages-publish.example.com`（写）；**真实域名、`CF_TUNNEL_TOKEN` 只放 `.env` / Cloudflare 后台（已 gitignore）**。
- 写入口 token、`CLUSTER_SECRET`、`swarm.key` 同样只在 `.env` / `runtime/`，不入库。

相关：[单机部署](./SINGLE_HOST_DEPLOYMENT.md)（含 §8 Caddy 直连公网自动 TLS） · [能力边界与运维](./CAPABILITIES_AND_OPERATIONS.md)
