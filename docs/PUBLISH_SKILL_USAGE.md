# 发布技能使用手册（pages）

给使用方 / Agent 看：如何**安装、配置、使用** `pages` 技能，把 HTML（单文件或带资源的目录）发布到私有 IPFS Cluster，拿到不可变的可分享链接（类似 Claude Artifacts，但每次发布是一个新的不可变链接）。安装后技能名叫 **`pages`**——对 Agent 说"发布到 pages / 用 pages 技能上传"即可触发。

> 占位域名 `pages.example.com`（读）/ `pages-publish.example.com`（写）换成你们的真实域名；`IPFS_PUBLISH_TOKEN` 向集群运维索取。

## 1. 安装

技能本体在仓库 `skills/pages/`（`publish.sh` + `SKILL.md` + `test.sh`）。取其一即可：

- **skills CLI（推荐）**：`npx skills add -g <owner>/<repo> --skill pages`（`-g` 装到全局 `~/.claude/skills/`，去掉则装到当前项目 `.claude/skills/`）。私有仓库需 `gh auth` 或仓库公开。
- **Claude Code 用户（手动）**：把 `pages/` 整个目录放进 `~/.claude/skills/` 或你项目的 `.claude/skills/`。Claude 会按 `SKILL.md` 的 description 在"发布/分享 HTML / 发布到 pages"场景自动调用。
- **当普通 CLI**：只需 `publish.sh` 一个文件，`chmod +x publish.sh`，直接运行。
- **依赖**：只用 `bash` + `curl`，无其它运行时。

## 2. 配置（3 个环境变量）

```bash
export IPFS_BASE_URL=https://pages.example.com          # 读/分享域名（拼返回链接）
export IPFS_PUBLISH_TOKEN=<向运维索取>                   # 写入口 Bearer token（= 集群 .env 的 IPFS_PUBLISH_TOKEN）
export IPFS_PUBLISH_ENDPOINT=<按下表选>                  # 写入口地址
```

| 你的位置 | `IPFS_PUBLISH_ENDPOINT` | 说明 |
|---------|-------------------------|------|
| **外部 / 公网 Agent** | `https://pages-publish.example.com` | 经 Cloudflare 写 hostname，**HTTPS + token**，token 不裸奔；零公网端口 |
| **集群同机 / 内网** | `http://127.0.0.1:9097` | 直连回环写入口，最低延迟，不绕 CF |

> ⚠️ 外部发布**务必走 HTTPS 的写 hostname**，不要用 `http://<服务器IP>:9097`——那是明文，token 会在公网裸奔（且该端口已收紧为仅回环）。

建议把这 3 个变量放进 shell profile / `.env` / 密钥管理，配一次长期用。

## 3. 使用

```bash
# 单文件
./publish.sh page.html
# → https://pages.example.com/artifact/<cid>

# 目录站点（含 index.html 与相对资源 css/js/img）
./publish.sh ./site
# → https://pages.example.com/artifact/<dirCID>/

# 临时草稿：自定义过期（默认 168h = 1 周）
./publish.sh --expire-in 24h page.html

# 永久（特殊情况才用，避免长期堆积）
./publish.sh --permanent page.html

# 发布后顺带校验链接可访问
./publish.sh --verify page.html
```

`publish.sh` 的 **stdout 只打印一行链接**（便于脚本捕获）；诊断信息走 stderr。

## 4. 行为与约束

- **不可变快照**：每次发布一个新 CID / 新链接；内容改了就是新链接，旧版本永久可达（天然版本历史）。不做原地更新。
- **默认 1 周过期**：到期集群自动 unpin；`--permanent` 才永久（少用）。
- **目录**：用 `wrap-with-directory`，文件名取相对站点根路径；根需有 `index.html`（否则链接是目录列表）。
- **无删除**：技能不提供取消发布（无 owner 鉴权）；清理靠过期 + 管理员 `ipfs-cluster-ctl`。
- **CIDv1**：强制 `cid-version=1`。

## 5. 常见问题

| 现象 | 原因 / 处理 |
|------|-----------|
| `401 Unauthorized` | token 缺失/错误 → 检查 `IPFS_PUBLISH_TOKEN` |
| 端点连不上 / 超时 | 外部要用 `https://pages-publish.example.com`，别用 `http://IP:9097`（已收紧为回环）|
| 目录链接 404 / 显示列表 | 目录根缺 `index.html` |
| 刚发布打开 504 | 副本异步复制中，几秒后即 200——用 `--verify` 或稍等重试（内容寻址，最终一致）|
| 缺环境变量报错退出 | 3 个 env 必须齐全（技能会明确提示缺哪个）|

## 6. 安全

- `IPFS_PUBLISH_TOKEN` 等同发布权，妥善保管、可定期轮换；分发给被授权方即可发布。
- 外部发布走 HTTPS 写 hostname（token 加密在途）；不要走明文 `IP:9097`。
- **读域名默认无鉴权**——拿到链接即可查看。若内容敏感，请给读域名加 [Cloudflare Access](./CLOUDFLARE_ACCESS.md)（SSO/邮箱/IP）。

## 7. 自测

```bash
# 需先 export 上面 3 个 env，且部署可达
./test.sh   # 冒烟：单文件 + 目录发布，均检查经网关渲染
```

相关：[发布技能 SKILL.md](../skills/pages/SKILL.md) · [Cloudflare Tunnel 接入](./CLOUDFLARE_TUNNEL_DEPLOYMENT.md) · [Cloudflare Access](./CLOUDFLARE_ACCESS.md) · [Agent 接入](./AGENT_INTEGRATION_GUIDE.md)
