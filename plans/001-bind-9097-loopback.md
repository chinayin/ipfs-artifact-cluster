# Plan 001: 写入口 9097 默认仅绑回环，消除"文档说回环、实现绑 0.0.0.0"的矛盾

> **执行者须知**：逐步执行本计划。每一步先跑验证命令、确认符合预期再进入下一步。
> 出现"STOP 条件"中的任何情况立即停止并汇报——不要即兴发挥。完成后更新
> `plans/README.md` 中本计划的状态行（除非派发你的 reviewer 声明由其维护索引）。
>
> **漂移检查（最先执行）**：
> `git diff --stat 7863c38..HEAD -- docker-compose.cluster.yml docs/SINGLE_HOST_DEPLOYMENT.md`
> 若任一在册文件在计划编写后有改动，先比对下文"现状"代码摘录与真实代码；不一致视为 STOP 条件。

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `7863c38`, 2026-07-10

## 为什么要做

本项目的 Agent 发布链路依赖 Caddy 的 token 写入口 `:9097`（明文 HTTP，Bearer token 鉴权）。
仓库内至少四处文档声称该端口"仅回环 / 已收紧 / 不随域名暴露"（`README.md:45`、
`docs/PUBLISH_SKILL_USAGE.md:28`、`docs/SINGLE_HOST_DEPLOYMENT.md:194`、
`docs/CLOUDFLARE_ACCESS.md:74`），但基础编排 `docker-compose.cluster.yml` 实际把 9097 绑到
**所有网卡**（`"9097:9097"`）。历史提交 `bfc7433` 已把 8080/9094/9095 收回回环（称为"公网服务器红线"），
9097 是被漏掉的一个。后果：按 `docs/SINGLE_HOST_DEPLOYMENT.md` §8 的"直连域名模式"部署到公网
ECS 时，会出现一个**公网可达、明文 HTTP 传输 Bearer token** 的写入口，token 在途裸奔。
本计划把默认绑定改为回环（提供 env 覆盖以支持内网 Agent 网段场景），使实现与文档一致。

## 现状

相关文件：

- `docker-compose.cluster.yml` — 单机 3 节点集群编排；caddy 服务的 ports 段是问题所在（第 106–111 行）。
- `docker-compose.node.yml` — 多机每台一份的编排；其中 9095 的绑定写法是本仓库既有的"默认回环 + env 覆盖"惯例范例（第 44 行），本计划照抄该模式。
- `docker-compose.cloudflare.yml` — CF 隧道 overlay；已用 `!override` 把 9097 改成 `127.0.0.1:9097:9097`（第 14–15 行）。**不要动它**（改完 base 后它变成冗余但无害的显式声明，保留作纵深防御）。
- `docs/SINGLE_HOST_DEPLOYMENT.md` — §2 端口表有 9097 一行（第 45 行），需补默认回环与覆盖方式说明。

`docker-compose.cluster.yml:106-111` 现状（问题行是最后一行）：

```yaml
    ports:
      # 本地：HTTP_PORT 默认 8088 → http://localhost:8088/artifact/<CID>
      # 域名模式：在 .env 设 HTTP_PORT=80、HTTPS_PORT=443（Let's Encrypt 需 80/443 入站可达）
      - "${HTTP_PORT:-8088}:80"
      - "${HTTPS_PORT:-127.0.0.1:8443}:443"
      - "9097:9097"           # 上传写入口（token 鉴权，仅 POST /add）
```

要照抄的仓库既有惯例，`docker-compose.node.yml:44`：

```yaml
      - "${PROXY_BIND:-127.0.0.1}:9095:9095"   # 代理 Agent 上传（默认仅本机）
```

`docs/SINGLE_HOST_DEPLOYMENT.md:45`（§2 端口表中 9097 一行）现状：

```markdown
| `9097` | Caddy 上传写入口 | **Agent 发布**：token 鉴权，仅放行 `POST /add` → cluster REST `:9094` |
```

仓库惯例：注释与文档用中文；compose 内安全相关端口都带一行中文注释说明"为什么"。

## 需要用到的命令

| 用途 | 命令 | 成功预期 |
|------|------|---------|
| 校验 compose 语法与插值 | `docker compose -f docker-compose.cluster.yml config -q` | exit 0（需存在 `.env`，没有则先 `make secrets`） |
| 查看 9097 实际绑定 | `docker compose -f docker-compose.cluster.yml config \| grep -A3 '9097'` | 见各步骤 |
| 发布链路 e2e | `make publish-e2e` | 末尾 `PASS=N FAIL=0`，退出码 0 |

前置：本机 Docker daemon 运行中；`make secrets` 已生成 `.env` 与 `runtime/private/swarm.key`（e2e 的 Makefile 目标会自动做）。

## 范围

**In scope**（只允许改这些文件）：

- `docker-compose.cluster.yml`（仅 caddy 服务 ports 段的 9097 一行）
- `docs/SINGLE_HOST_DEPLOYMENT.md`（仅 §2 端口表 9097 一行）

**Out of scope**（看着相关也不要动）：

- `docker-compose.cloudflare.yml` — 其 `!override` 已是回环，保留原样。
- `caddy/Caddyfile` — 鉴权逻辑本身没有问题。
- `README.md`、`docs/PUBLISH_SKILL_USAGE.md`、`docs/CLOUDFLARE_ACCESS.md` — 它们声称"仅回环"，本修复落地后这些描述**自动变为正确**，无需改动。
- `docker-compose.node.yml` — 多机形态本来就没有 9097。
- `Makefile`、`e2e/` — `skill-smoke` 与 `run-publish.sh` 用 `127.0.0.1`/`localhost` 访问 9097，回环绑定下不受影响。

## Git 工作流

- 分支：`advisor/001-bind-9097-loopback`
- 提交信息：中文 + 约定式英文前缀，参考仓库既有示例
  `fix(security): 控制面端口(8080/9094/9095)绑回环，绝不随 up 暴露公网(公网服务器红线)`
- 不要 push、不要开 PR，除非操作者明确指示。

## 步骤

### Step 1: 修改 9097 绑定为"默认回环 + PUBLISH_BIND 覆盖"

把 `docker-compose.cluster.yml` caddy 服务 ports 段的：

```yaml
      - "9097:9097"           # 上传写入口（token 鉴权，仅 POST /add）
```

改为（模式与 `docker-compose.node.yml:44` 的 `PROXY_BIND` 一致）：

```yaml
      # 上传写入口（token 鉴权，仅 POST /add）：默认仅回环；需要给内网 Agent 网段
      # 开放时在 .env 设 PUBLISH_BIND=<内网IP或0.0.0.0> 并用安全组限制来源。
      - "${PUBLISH_BIND:-127.0.0.1}:9097:9097"
```

**验证**：
`docker compose -f docker-compose.cluster.yml config | grep -B2 -A4 'target: 9097'`
→ 输出中该端口映射的 `host_ip` 为 `127.0.0.1`（若 compose 版本输出短格式，则确认包含 `127.0.0.1:9097`）。

### Step 2: 确认 env 覆盖生效

**验证**：
`PUBLISH_BIND=0.0.0.0 docker compose -f docker-compose.cluster.yml config | grep -A4 'target: 9097'`
→ `host_ip` 为 `0.0.0.0`（或短格式包含 `0.0.0.0:9097`）。

### Step 3: 更新单机部署文档端口表

把 `docs/SINGLE_HOST_DEPLOYMENT.md` §2 端口表中 9097 一行改为：

```markdown
| `9097` | Caddy 上传写入口 | **Agent 发布**：token 鉴权，仅放行 `POST /add` → cluster REST `:9094`。默认仅绑回环；内网 Agent 需直连时在 `.env` 设 `PUBLISH_BIND`（务必用安全组限制来源），外部发布走 Cloudflare 写 hostname（HTTPS）|
```

**验证**：`grep -n 'PUBLISH_BIND' docs/SINGLE_HOST_DEPLOYMENT.md` → 恰好 1 处命中，位于端口表内。

### Step 4: 全链路回归

**验证**：`make publish-e2e` → 末尾 `PASS=N FAIL=0` 且退出码 0
（该 e2e 覆盖：无 token→401、token+GET→403、单文件发布渲染、目录发布渲染、默认过期、`--permanent`）。

## 测试计划

- 不新增测试文件：既有 `e2e/run-publish.sh` 的 ENDPOINT 默认 `http://localhost:9097`，回环绑定下天然回归了"本机可用"；Step 1/2 的 `compose config` 断言覆盖了绑定本身。
- 验证命令：`make publish-e2e` → 全部 PASS。

## 完成标准（全部满足，机器可查）

- [ ] `docker compose -f docker-compose.cluster.yml config | grep -A4 'target: 9097'` 显示 host_ip `127.0.0.1`
- [ ] `PUBLISH_BIND=0.0.0.0` 前缀下同命令显示 `0.0.0.0`
- [ ] `make publish-e2e` 退出码 0、`FAIL=0`
- [ ] `git status` 显示改动仅限 in-scope 两个文件
- [ ] `plans/README.md` 状态行已更新

## STOP 条件

出现以下情况停止并汇报，不要即兴处理：

- `docker-compose.cluster.yml` caddy ports 段与上文摘录不一致（代码已漂移）。
- `docker compose config` 报 `!override`/插值相关错误（compose 版本差异），一次合理修复后仍失败。
- `make publish-e2e` 失败且失败用例与 9097 连通性无关（说明环境问题而非本改动，需人工判断）。
- 发现有其它脚本/文档以 `<非回环IP>:9097` 直连写入口（意味着有本计划未识别的使用方）。

## 维护提示

- 后续若做"直连 SSL 模式的 HTTPS 写入口"（审计发现 #7，本轮未入计划），会在 Caddyfile 新增一个域名站点块，届时 9097 的角色降级为纯内网口，本行注释需同步更新。
- Review 时重点看：`docker-compose.cloudflare.yml` 的 `!override` 是否仍保留（应保留）；文档是否只改了端口表一行。
- 明确不做（已另行记录）：9097 的请求体大小限制（审计发现 #4）、按 Agent 分 token（方向性建议）。
