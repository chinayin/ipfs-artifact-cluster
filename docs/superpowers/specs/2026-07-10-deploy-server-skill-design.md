# 设计：deploy-server 部署技能

日期：2026-07-10
状态：已评审通过，待写实现计划

## 目标与体验

把本地仓库的运行相关改动**可控地滚到已在跑的生产服务器**：`.claude/skills/deploy-server/deploy.sh` 一条命令完成 **diff → 备份 → 同步 → 重建 → 条件 reload → 验证**，默认先 `--dry-run` 只读预览，人工确认后再 `--apply`。

填补现有空白：项目已有"**起栈**"能力（`make up*` + 各部署文档，都假设你已在目标机器上）和"**本地测试**"能力（`kubo-deploy-e2e` 一次性栈），但**没有** local→remote 的增量更新流程。本技能就是这一环。

### 与 `kubo-deploy-e2e` 的区别（正交，不重叠）

| | kubo-deploy-e2e | deploy-server |
|---|---|---|
| 本质 | 测试/演示 runbook | 发布/运维 runbook |
| 在哪跑 | 本地，用完即弃的栈 | 从本地推到真实生产服务器 |
| 动什么 | 临时栈，跑完 `down` 清掉 | 线上运行栈，绝不清数据 |
| 回答 | "集群设计对不对" | "改动怎么安全上线到活着的服务器" |

## 决策记录（brainstorming 结论）

| # | 决策 | 取舍 |
|---|------|------|
| Q1 | 技能**自包含**：配置放技能目录自己的 `.env`（`.claude/skills/deploy-server/.env`），不碰项目根 `.env` / `.env.node.example` | 彻底解耦，技能可独立理解与迁移 |
| Q2 | 配置解析**进程环境变量为主 → 技能 `.env` 兜底** | 灵活、CI 友好；本地免每次导出 |
| Q3 | 连接方式**自动识别**：显式 `DEPLOY_SSH_KEY` → 探测 ssh-agent/默认 key → `sshpass` 密码兜底 → 全无则报错 | 尽量免密走 key，密码仅兜底 |
| Q4 | 凭据（尤其密码）**永不进 git**：`.claude/skills/**/.env` 全部 gitignored | 兜底防误提交任何技能的 `.env` |
| Q5 | 同步用**白名单**（只碰运行相关文件），非黑名单 | 最安全；`.env`/`runtime/` 天然不在内；新增运维文件需手动加白名单 |
| Q6 | 安全闸门：**`--dry-run`（默认）→ 人工确认 → `--apply`** | 动生产必须有人工拦截点 |
| Q7 | 备份到 `<远端>/.backup/<ts>/`；`--rollback` 一期不做（P2） | 一期保证可回退的备份存在 + 打印路径，回滚手动 |

## 交付物

### 目录结构（全在技能内）
```
.claude/skills/deploy-server/
├── SKILL.md            # runbook + 触发描述（提交）
├── deploy.sh           # 部署脚本（提交）
├── .env.example        # 配置模板，脱敏占位（提交）
└── .env                # 真实配置，gitignored（不提交）
```

### 配置键（`.env.example` 脱敏占位）
| 键 | 含义 | 默认 |
|---|---|---|
| `DEPLOY_SSH_HOST` | 服务器 IP/域名 | 必填 |
| `DEPLOY_SSH_USER` | 登录用户 | `root` |
| `DEPLOY_SSH_PORT` | SSH 端口 | `22` |
| `DEPLOY_REMOTE_DIR` | 远端部署目录 | `/data/ipfs` |
| `DEPLOY_SSH_KEY` | 私钥路径（可选，优先） | 空 |
| `DEPLOY_SSH_PASSWORD` | 密码（可选，兜底；用 key 就留空） | 空 |
| `IPFS_BASE_URL` | 对外读域名，供只读验证用 | 空则跳过域名验证 |

### `.gitignore` 改动
在既有 `.claude/skills` 白名单段追加：
```
!.claude/skills/deploy-server        # 放行新技能进 git
.claude/skills/**/.env               # 兜底：任何技能里的 .env 都不提交（放最后，最后匹配生效）
```
实现时用 `git check-ignore` 实测：`deploy-server/.env` 被挡、`SKILL.md`/`deploy.sh`/`.env.example` 可提交。

## 执行流程

### 前置检查
1. 技能目录无 `.env` → 停，提示 `cp .env.example .env` 填好再跑。
2. 解析连接方式并打印本次将用 key 还是密码。
3. 缺 `sshpass` 且需密码 → 提示安装或改用 key。

### `--dry-run`（默认，只读，绝不改动）
对白名单逐文件本地↔远端 `sha256` 比对，打印：
- 将覆盖哪些文件（local/remote sha 缩略）
- 哪些容器会因 compose command/config 变化被重建
- Caddyfile 是否变 → 是否需 `caddy reload`
- 本次连接方式

### `--apply`（需人工确认后）
1. 远端 `<REMOTE_DIR>/.backup/<ts>/` 备份将被覆盖的文件
2. `scp` 同步差异文件
3. 同步后**再 sha256 复核**本地↔远端一致
4. `make up-cloudflare`（幂等 `up -d`，只重建变更服务）
5. **仅当 Caddyfile 变**：`caddy validate` 通过后 `docker exec cl-caddy caddy reload`（不过校验即中止，不 reload 坏配置）
6. 验证

### 同步白名单
```
docker-compose.cluster.yml  docker-compose.cloudflare.yml  docker-compose.node.yml
caddy/**  Makefile  scripts/**  skills/publish-artifact/**  e2e/**
```
**永不触碰**：`.env`、`runtime/`、`.backup/`、`docs/`、`plans/`、`.git`。

### 验证（真实断言）
1. `cl-*` 容器 `healthy` / `Up`
2. `ipfs-cluster-ctl peers ls` = 集群节点数
3. 若配了 `IPFS_BASE_URL`：取一个真实已 pin CID，`GET https://<域名>/artifact/<CID>/` 得 `200 text/html`（只读，不改）

## 错误处理与回滚
- 任一步失败即停，不继续。
- 备份目录路径始终打印。
- Caddyfile 覆盖前 `caddy validate`，不过则中止。
- 回滚（一期手动）：按打印的 `.backup/<ts>/` 路径还原白名单文件并重跑重建。`--rollback` 子命令列 P2。

## 不做（YAGNI）
- 不做 `--rollback` 子命令（一期）。
- 不做多机批量部署（本技能针对单宿主机部署目录；多机沿用 `docs/MULTI_HOST_DEPLOYMENT.md`）。
- 不做首次 bring-up（本技能针对**已在跑**的服务器做增量更新）。
- 不碰 `.env` / `runtime/` 数据，不做数据备份（数据备份见 `docs/CAPABILITIES_AND_OPERATIONS.md`）。
