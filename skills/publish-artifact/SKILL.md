---
name: publish-artifact
description: 把一段 HTML（单文件或带资源的目录站点）发布到私有 IPFS Cluster，拿到不可变的可分享链接。当用户/Agent 说"把这个页面发出来 / 发布到 pages / 发到 pages / 给我个分享链接 / 发布这个 HTML / host 这个 artifact"时使用。每次发布是一个新快照（新 CID/新链接），默认 1 周后自动失效。需先配置 3 个环境变量指向已部署的集群。
---

# 发布 Artifact 到私有 IPFS Cluster

把 Agent 生成的 HTML 发布成内容寻址的不可变快照，返回可分享链接。语义类似 Claude Artifacts，但每次发布得到一个新的不可变链接（内容改了就是新链接，旧版本永久可达）。

## 前置：配置（用前一次）

技能靠 3 个环境变量指向你们已部署的集群：

```bash
# 写入口：外部 Agent 用 CF 写 hostname（HTTPS + token）；内网/同机用回环
export IPFS_PUBLISH_ENDPOINT=https://pages-publish.example.com   # 外部；内网则 http://127.0.0.1:9097
export IPFS_PUBLISH_TOKEN=<从集群 .env 的 IPFS_PUBLISH_TOKEN 取>
export IPFS_BASE_URL=https://pages.example.com                   # 读/分享域名
```

> - `IPFS_PUBLISH_ENDPOINT`：**外部** Agent 走 Cloudflare 写 hostname（经 HTTPS，token 不裸奔，见 `docs/CLOUDFLARE_TUNNEL_DEPLOYMENT.md`）；**内网/同机** Agent 直接 `http://127.0.0.1:9097` 更快。
> - token 由集群运维在集群侧 `make secrets` 生成（写入集群 `.env`），分发给被授权的 Agent。
> - 占位 `pages.example.com` / `pages-publish.example.com` 换成你们的真实域名。

## 用法

```bash
# 单文件
./publish.sh page.html
# → https://pages.example.com/artifact/<cid>

# 目录站点（含 index.html 与相对资源 css/js/img）
./publish.sh ./site
# → https://pages.example.com/artifact/<dirCID>/

# 临时草稿：自定义过期（默认 168h=1周）
./publish.sh --expire-in 24h page.html

# 永久（特殊情况才用，避免长期堆积）
./publish.sh --permanent page.html

# 发布后顺带校验链接可访问
./publish.sh --verify page.html
```

stdout 只打印一行链接，便于脚本捕获。

## 行为与约束

- **不可变快照**：每次发布一个新 CID/链接；不做原地更新。
- **默认 1 周过期**：到期集群自动 unpin；`--permanent` 才永久。
- **目录**：用 `wrap-with-directory`，文件名取相对站点根路径；要求根有 `index.html`（否则链接是目录列表）。
- **无删除**：技能不提供取消发布（无 owner 鉴权，删除是管理员用 `ipfs-cluster-ctl` 的事）；清理靠过期。
- **CIDv1**：强制 `cid-version=1`。

## 自测

```bash
# 需先 export 上面 3 个 env，且集群与写入口在跑
./test.sh   # 断言单文件与目录发布均可经网关渲染
```

## 安装与分发

把 `publish-artifact/` 放进使用方的 `~/.claude/skills/` 或项目 `skills/`（Claude Code 自动识别）；或当普通 CLI 只取 `publish.sh`（`chmod +x` 后直接跑，仅依赖 bash + curl）。
