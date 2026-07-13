---
name: deploy-server
description: 把本地仓库里的**运行相关改动增量部署到已在跑的生产 IPFS Cluster 服务器**——一条 deploy.sh 完成 diff → 备份 → 同步 → 重建(make up-cloudflare) → 条件 reload(Caddy) → 验证。默认 --dry-run 只读预览，人工确认后 --apply。当你已经在本地改好了 docker-compose / caddy/Caddyfile / Makefile / scripts / publish-artifact / e2e 等运行相关文件，要把这些改动安全滚到那台一直在线的生产服务器（默认远端目录 /data/ipfs）时使用。这是 **local→remote 的发布/运维 runbook**，不是本地测试：集群本身是否健康的**一次性本地测试栈**见 kubo-deploy-e2e；把 HTML/附件**发布成分享链接**（内容发布，不动基础设施）见 publish-artifact。本技能只做增量更新，**不做**首次 bring-up、不碰远端 .env / runtime 数据、不做多机批量部署。
---

# deploy-server 增量部署 runbook

把本地仓库的运行相关改动**可控地滚到已在跑的生产服务器**：`.claude/skills/deploy-server/deploy.sh` 一条命令走完 **diff → 备份 → 同步 → 重建 → 条件 reload → 验证**。默认先 `--dry-run` 只读预览，人工确认后再 `--apply`。全程真实断言（容器状态 / `peers ls` / 域名渲染），不靠"应该能上"。

> 这是**发布/运维**技能，动的是**线上运行栈**，绝不清数据。
> - 集群设计对不对（一次性本地测试栈，用完即弃）→ **kubo-deploy-e2e**。
> - 发布链路对不对（token 写入口 + publish.sh 的 e2e）→ **kubo-publish-e2e**。
> - 把 HTML/附件发布成分享链接（发内容，不动基础设施）→ **publish-artifact**。

> 生产服务器的真实形态：远端目录**不是 git 仓库**，是手工拷过去的运行文件子集。容器名固定为 `cl-caddy`、`cl-ipfs0/1/2`、`cl-cluster0/1/2`、`cl-cloudflared`。本技能只做**增量更新已在跑的服务器**，不做首次 bring-up（bring-up 见 `docs/SINGLE_HOST_DEPLOYMENT.md`）。

## 0. 前置：填技能自己的 .env

技能**自包含**，配置放技能目录自己的 `.env`，**不碰**项目根 `.env`。

```bash
cd .claude/skills/deploy-server
cp .env.example .env      # 首次
$EDITOR .env              # 填服务器地址与凭据
```

配置解析顺序：**进程环境变量为主 → 技能 `.env` 兜底**（CI 里可只用环境变量，本地免每次导出）。但 `.env` **必须存在**，否则脚本停下并提示 `cp .env.example .env`。

| 键 | 含义 | 默认 |
|---|---|---|
| `DEPLOY_SSH_HOST` | 服务器 IP/域名 | 必填 |
| `DEPLOY_SSH_USER` | 登录用户 | `root` |
| `DEPLOY_SSH_PORT` | SSH 端口 | `22` |
| `DEPLOY_REMOTE_DIR` | 远端部署目录 | `/data/ipfs` |
| `DEPLOY_SSH_KEY` | 私钥路径（可选，优先） | 空 |
| `DEPLOY_SSH_PASSWORD` | 密码（可选，兜底；用 key 就留空） | 空 |
| `IPFS_BASE_URL` | 对外读域名，供只读渲染验证 | 空则跳过域名验证 |

> 凭据**永不进 git**：`.claude/skills/**/.env` 已被 gitignore 兜底挡下。只提交 `SKILL.md` / `deploy.sh` / `.env.example`。

## 连接方式（自动识别）

脚本每次运行开头打印本次用的连接方式，识别顺序：

1. 显式 `DEPLOY_SSH_KEY` → 用该私钥（`-i <key> -o IdentitiesOnly=yes`）。
2. 否则 `BatchMode=yes` 探测默认 key / ssh-agent 能否免密 → 通过就走它。
3. 否则有 `DEPLOY_SSH_PASSWORD` → `sshpass -e`（密码经 `$SSHPASS` 环境变量传，不进命令行/日志）。缺 `sshpass` 会提示 `brew install sshpass` 或改用 key。
4. 全都没有 → 报错退出。

所有 ssh/scp 都带 `-o StrictHostKeyChecking=accept-new`（首连自动信任 host key）。

## 1. dry-run（默认，只读，绝不改动）

```bash
.claude/skills/deploy-server/deploy.sh              # 等价 --dry-run
.claude/skills/deploy-server/deploy.sh --dry-run
```

逐文件本地↔远端 `sha256` 比对，打印：

- 将覆盖/新增哪些文件（`~` 改动 / `+` 新增，附 local/remote sha 缩略）。
- compose 文件是否变 → `make up-cloudflare` 是否会按需重建服务。
- `caddy/Caddyfile` 是否变 → apply 时是否需 `caddy validate + reload`。
- 本次连接方式，以及 apply 后会做哪些验证断言。

## 2. apply（人工确认后执行）

看完 dry-run 无误，再执行：

```bash
.claude/skills/deploy-server/deploy.sh --apply
```

按顺序做，**任一步失败即停**：

1. 远端取时间戳 `date +%Y%m%d-%H%M%S`，把**将被覆盖**的文件备份到 `<REMOTE_DIR>/.backup/<ts>/`（保留目录结构，`cp -p`）。纯新增文件无需备份。
2. `scp` 同步差异文件（先建远端目录）。
3. 同步后**再 sha256 复核**本地↔远端逐个一致，不一致即停。
4. `cd <REMOTE_DIR> && make up-cloudflare`（= `docker compose -f docker-compose.cluster.yml -f docker-compose.cloudflare.yml up -d`，幂等，只重建 command/config 变了的服务）。
5. **仅当 `caddy/Caddyfile` 变**才处理 Caddy。关键：**在覆盖挂载文件之前先校验新配置**——把新 `Caddyfile` `docker cp` 进 `cl-caddy` 的临时路径 `caddy validate`，**不过就中止、连挂载文件都不覆盖**（否则坏配置一旦落盘，之后任何 caddy 重启/重建都会加载它 → 读链路宕机）。校验通过、文件同步到位后，因 `Caddyfile` 是挂载文件（容器内 `/etc/caddy/Caddyfile`）、`up -d` 不会因它内容变化重建 `cl-caddy`，再单独 reload：

   ```bash
   # 覆盖前：在容器内校验尚未落盘的新配置
   docker cp <新Caddyfile> cl-caddy:/tmp/Caddyfile.new
   docker exec cl-caddy caddy validate --config /tmp/Caddyfile.new --adapter caddyfile
   # 通过并同步落盘后：热重载（reload 自身也会校验，坏配置会保留旧配置不生效）
   docker exec cl-caddy caddy reload  --config /etc/caddy/Caddyfile --adapter caddyfile
   ```
6. 验证（见 §3）。

### 同步白名单（只碰生产主机**运行必需**的文件）

```
docker-compose.cluster.yml  docker-compose.cloudflare.yml  Makefile  caddy/**  scripts/**
```

判据：被 compose 挂载/读取（`caddy/Caddyfile`、`scripts/init-cluster.d`）或起停栈必需（compose 文件、Makefile）。**不含**测试工具与多机模板：`e2e/`、`skills/publish-artifact/` 只被 `make e2e/publish-e2e/skill-smoke` 用，`docker-compose.node.yml` 是多机模板、单机 cloudflare 栈不加载——生产主机跑集群都用不到，故不部署。若要在生产机上跑这些测试，另行手动拷贝或临时加进 `WHITELIST`。

用**白名单**而非黑名单：最安全，且优先用 `git ls-files` 枚举（天然排除 `.env`/`runtime/`/fixtures）。新增**运行必需**文件时，手动加进 `deploy.sh` 的 `WHITELIST`。

**永不触碰远端**：`.env`、`runtime/`、`.backup/`、`docs/`、`plans/`、`.git`。

## 3. 验证（真实断言；只读）

apply 末尾自动跑；也是判断线上是否健康的手动三步：

```bash
# ① 容器状态：cl-* 应全部 Up/healthy
docker ps -a --filter name=cl- --format '{{.Names}} {{.Status}}'

# ② 集群成形：peers 数 = 集群节点数（脚本从本地 compose 推导期望值）
docker exec cl-cluster0 ipfs-cluster-ctl peers ls

# ③ 域名只读渲染（配了 IPFS_BASE_URL 才做）：取一个真实已 pin CID，走对外域名应得 200 text/html
CID=$(docker exec cl-cluster0 ipfs-cluster-ctl pin ls | awk '{print $1}' | head -1)
curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' "https://<IPFS_BASE_URL 的 host>/artifact/$CID/"
```

集群暂无已 pin CID、或本机无 `curl`、或未配 `IPFS_BASE_URL` → 域名验证跳过（不算失败）。

## 4. 失败处理与手动回滚

- 任一步失败即停，不继续往下。脚本**始终打印备份目录路径** `<REMOTE_DIR>/.backup/<ts>/`。
- **手动回滚**（一期不做 `--rollback` 子命令）：按打印的 `.backup/<ts>/` 路径，把白名单文件还原到 `<REMOTE_DIR>` 对应位置，再在远端 `cd <REMOTE_DIR> && make up-cloudflare`；若还原的是 `Caddyfile`，同 §2 步骤 5 手动 `validate + reload`。
- Caddyfile 校验不过时脚本不会 reload，远端内存里仍是旧配置，安全。

## 不做（YAGNI）

- 不做 `--rollback` 子命令（一期只保证备份存在 + 打印路径，回滚手动）。
- 不碰远端 `.env` / `runtime/` 数据，不做数据备份（数据备份见 `docs/CAPABILITIES_AND_OPERATIONS.md`）。
- 不做首次 bring-up（本技能针对**已在跑**的服务器做增量更新；bring-up 见 `docs/SINGLE_HOST_DEPLOYMENT.md`）。
- 不做多机批量部署（多机走 `docs/MULTI_HOST_DEPLOYMENT.md`）。

## 最小使用示例

```bash
# 0) 首次填配置
cd .claude/skills/deploy-server && cp .env.example .env && $EDITOR .env

# 1) dry-run 看清将改什么、会不会 reload Caddy
./deploy.sh --dry-run
# 输出示例：
#   将覆盖/新增的文件（local / remote sha 缩略）:
#     ~ caddy/Caddyfile        local:9f2a...  remote:1c04...
#   Caddyfile: 有变更 → apply 时将 caddy validate + caddy reload（校验不过则中止）
#   确认无误后执行: ./deploy.sh --apply

# 2) 人工确认无误后 apply（备份 → 同步 → 复核 → make up-cloudflare → Caddy reload → 验证）
./deploy.sh --apply
# 末尾打印：部署完成。备份路径: /data/ipfs/.backup/20260710-142530
```

相关：**kubo-deploy-e2e**（本地一次性测试栈）· **kubo-publish-e2e**（发布链路 e2e）· **publish-artifact**（发内容拿分享链接）· `docs/SINGLE_HOST_DEPLOYMENT.md` · `docs/MULTI_HOST_DEPLOYMENT.md` · `docs/CAPABILITIES_AND_OPERATIONS.md`
