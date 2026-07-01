# Cloudflare Access：给 artifact 加"谁能访问"鉴权

本项目的 IPFS 网关本身**无鉴权**——拿到 CID 链接的人就能看。当 artifact 含内部/敏感内容时，需要在**不改后端**的前提下加一层访问控制。如果你已用 [Cloudflare Tunnel](./CLOUDFLARE_TUNNEL_DEPLOYMENT.md) 接入，那么 **Cloudflare Access** 是最顺手的方案：它在 Cloudflare 边缘做"身份感知代理"，请求**先过鉴权再进隧道**，未授权者根本到不了你的后端。

> 前置：已按 [Cloudflare Tunnel 接入](./CLOUDFLARE_TUNNEL_DEPLOYMENT.md) 把 `pages.example.com` 经隧道指向内网 Caddy。Access 叠加在其上，不需要改 compose / Caddy。

## 1. 它是什么、解决什么

- **Cloudflare Access（Zero Trust）**：在边缘对某个主机名/路径强制身份校验，通过后才放行到源站。支持邮箱 OTP、Google/GitHub/企业 SSO（SAML/OIDC）、IP 段、设备态势、**service token**（机器用）等策略。
- **它在缓存之前执行**：匿名/未授权请求在 Access 这一层就被挡，**拿不到任何缓存内容**；只有通过鉴权的会话才会命中边缘缓存。所以"边缘加速"和"访问控制"不冲突——加速只对授权用户生效。
- **纵深防御**：Access 管"谁能进"，不替代后端的 token 写入口闸门；两者叠加。

## 2. 两类保护对象

| 对象 | 谁来访问 | 用什么策略 |
|------|---------|-----------|
| **读入口**（看 artifact）| 人（浏览器）| 邮箱 OTP / SSO / IP 段 |
| **写入口**（发布 artifact）| 机器 / Agent | **service token**（机器凭据，非交互）|

---

## 3. 读入口：保护"谁能看"

> Cloudflare 控制台 → **Zero Trust → Access → Applications → Add an application → Self-hosted**

1. **Application 配置**
   - Application name：`ipfs-artifacts`
   - Session duration：按需（如 24h）
   - **Public hostname**：`pages.example.com`（可加路径，如只保护 `/artifact/`；留空=整站）
2. **Policy（放行规则）**，按需选其一或组合：
   - *Emails*：`Include → Emails ending in → @example.com`（公司邮箱可登）
   - *Identity provider*：接好 Google/企业 SSO 后 `Include → Login Methods`
   - *IP ranges*：`Include → IP ranges → 10.0.0.0/8`（办公网直接放行、免登录）
3. 保存。此后访问 `https://pages.example.com/artifact/<CID>` 会先跳转 Cloudflare 登录/校验，通过才显示内容。

> 想"内网免登录、外网要登录"：建两条 Include 策略——IP 段（内网）+ 邮箱/SSO（其余），满足任一即放行。

---

## 4. 写入口：service token（**可选**加固；默认仅用原 token）

> **默认方案不需要本节**：远程发布走 CF 写 hostname `pages-publish.example.com → caddy:9097`，仅用原 `IPFS_PUBLISH_TOKEN`（经 CF 走 HTTPS，token 不裸奔）。见 [Tunnel 文档 §2](./CLOUDFLARE_TUNNEL_DEPLOYMENT.md)。本节是**想在 token 之外再加一层机器身份闸**时才做。

CF 模式下写入口 `:9097` 只绑回环、不暴露公网。若要给写 hostname 再叠加 Access service token（纵深防御）：

1. 写 hostname 已在 Tunnel 里配好：`pages-publish.example.com` → `http://caddy:9097`。
2. **建 service token**：Zero Trust → Access → **Service Auth → Service Tokens → Create**，记下 `Client ID` 与 `Client Secret`。
3. **建 Access Application 保护 `pages-publish.example.com`**，Policy：`Include → Service Token → <刚建的 token>`（**只允许带该 token 的机器**，挡掉其它流量）。
4. **Agent 侧**：发布请求带两个头即可通过 Access：
   ```
   CF-Access-Client-Id: <Client ID>
   CF-Access-Client-Secret: <Client Secret>
   ```
   并仍带原有的写入口 token（双层）：
   ```bash
   curl -sS -X POST \
     -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
     -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
     -H "Authorization: Bearer $IPFS_PUBLISH_TOKEN" \
     -F "file=@page.html;filename=page.html" \
     "https://pages-publish.example.com/add?cid-version=1&expire-in=168h"
   ```

> 这样：读入口（人，SSO）与写入口（机器，service token）各用各的身份；后端 `:9097` 不开公网；CF Access service token 是第一道闸、写入口 Bearer token 是第二道。

> `publish.sh` 暂未内置这两个 Access 头；远程经 Access 写入时，用上面的 curl 形态，或给 `publish.sh` 包一层（后续可加 `--access` 选项）。本机/内网直连 `127.0.0.1:9097` 时不需要 Access。

---

## 5. 与缓存、后端 token 的关系

- **缓存**：Access 在缓存前执行——匿名请求被挡、拿不到缓存；授权会话正常命中边缘缓存。读入口加 Access **不影响**授权用户的加速。
- **后端写入口 token**：默认仅 `IPFS_PUBLISH_TOKEN` 一道（经 CF HTTPS 传输）。**若额外启用** Access service token，则它管"哪台机器能到达写入口"、token 管"到达后能否写"，两层叠加（纵深防御，可选）。
- **不是替代品**：Access 只对**经 Cloudflare**的流量生效；任何能直连后端端口的路径都绕过它——所以后端原生端口（`:5001/:9094/:9095`）必须始终不暴露公网，`:9097` 也默认不公网。

## 6. 注意

- service token 的 secret 等同密码，**只放 Agent 的 `.env`/密钥管理**，定期轮换；勿写进提交的文件。
- Access 策略改动即时生效；调试时可在 Application 里看 Logs（谁、何时、是否放行）。
- 占位域名 `pages.example.com`（读）/ `pages-publish.example.com`（写）仅示例；真实域名只在你的 Cloudflare 后台与 `.env`。

相关：[Cloudflare Tunnel 接入](./CLOUDFLARE_TUNNEL_DEPLOYMENT.md) · [单机部署](./SINGLE_HOST_DEPLOYMENT.md) · [能力边界与运维](./CAPABILITIES_AND_OPERATIONS.md)
