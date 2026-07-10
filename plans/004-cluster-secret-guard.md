# Plan 004: 补齐 CLUSTER_SECRET 的生成与启动守卫，杜绝"部分 .env 静默空值起栈"

> **执行者须知**：逐步执行本计划。每一步先跑验证命令、确认符合预期再进入下一步。
> 出现"STOP 条件"中的任何情况立即停止并汇报——不要即兴发挥。完成后更新
> `plans/README.md` 中本计划的状态行（除非派发你的 reviewer 声明由其维护索引）。
>
> **漂移检查（最先执行）**：
> `git diff --stat 7863c38..HEAD -- Makefile docker-compose.cluster.yml docker-compose.node.yml`
> 若任一在册文件在计划编写后有改动，先比对下文"现状"代码摘录与真实代码；不一致视为 STOP 条件。

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 建议在 Plan 001 之后执行（两者都改 `docker-compose.cluster.yml`，避免合并冲突）
- **Category**: 健壮性 / security
- **Planned at**: commit `7863c38`, 2026-07-10

## 为什么要做

`CLUSTER_SECRET` 是集群层的信任根（文档称"泄露 = 可加入集群"；缺失/为空 = 集群层不设防或组网失败）。
当前有两个缺口：

1. `make secrets` 只在 **`.env` 文件不存在**时才写入 `CLUSTER_SECRET`（`Makefile:12` 用
   `[ -f .env ] ||` 判断）。用户若先手工创建了 `.env`（比如只写了 `SITE_DOMAIN`，这是
   `docs/SINGLE_HOST_DEPLOYMENT.md` §8 引导的正常操作顺序），`make secrets` 会跳过生成——
   而同文件里 `IPFS_PUBLISH_TOKEN` 用的是 `grep -q '^KEY=' || echo >> ` 的逐键追加模式，两者不一致。
2. `docker-compose.cluster.yml` 对 `CLUSTER_SECRET` 没有 `:?` 守卫（对比同文件
   `IPFS_PUBLISH_TOKEN: ${IPFS_PUBLISH_TOKEN:?run \`make secrets\` first}` 有守卫），
   `docker-compose.node.yml` 同样没有。空值会被静默注入，集群以空 secret 起栈。

结果：一个常见的操作顺序会得到"能起但不安全/组不成网"的集群，且无任何报错。
本计划把 `CLUSTER_SECRET` 改成与 `IPFS_PUBLISH_TOKEN` 相同的逐键追加 + 启动守卫模式。

## 现状

相关文件：

- `Makefile` — `secrets` 目标（第 11–18 行）与 `down` 目标（第 44–45 行）。
- `docker-compose.cluster.yml` — `x-cluster-env` 锚注入 `CLUSTER_SECRET`（第 10–11 行）；
  caddy 服务展示了本仓库 `:?` 守卫的既有写法（第 103 行）。
- `docker-compose.node.yml` — `cluster` 服务注入 `CLUSTER_SECRET`（第 30 行）。

`Makefile:11-18` 现状：

```makefile
secrets: ## 幂等生成 .env(CLUSTER_SECRET/IPFS_PUBLISH_TOKEN) 与 runtime/private/swarm.key(已存在则跳过)
	@[ -f .env ] || echo "CLUSTER_SECRET=$$(od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')" > .env
	@grep -q '^IPFS_PUBLISH_TOKEN=' .env 2>/dev/null || \
		echo "IPFS_PUBLISH_TOKEN=$$(od -vN 24 -An -tx1 /dev/urandom | tr -d ' \n')" >> .env
	@mkdir -p runtime/private
	@[ -f runtime/private/swarm.key ] || printf '/key/swarm/psk/1.0.0/\n/base16/\n%s\n' \
		"$$(od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')" > runtime/private/swarm.key
	@echo "secrets ready (.env + runtime/private/swarm.key)"
```

`Makefile:44-45` 现状（`down` 给带 `:?` 守卫的变量填哑值，新增守卫必须同步补齐，否则
`.env` 缺失时 `make down` 会因插值失败而报错）：

```makefile
down: ## 停集群(两种模式都清；保留 runtime/ 数据)
	@CF_TUNNEL_TOKEN=$${CF_TUNNEL_TOKEN:-x} IPFS_PUBLISH_TOKEN=$${IPFS_PUBLISH_TOKEN:-x} $(COMPOSE_CF) down
```

`docker-compose.cluster.yml:10-11` 现状：

```yaml
x-cluster-env: &cluster-env
  CLUSTER_SECRET: ${CLUSTER_SECRET}
```

本仓库 `:?` 守卫的既有范例，`docker-compose.cluster.yml:103`：

```yaml
      IPFS_PUBLISH_TOKEN: ${IPFS_PUBLISH_TOKEN:?run `make secrets` first}
```

`docker-compose.node.yml:30` 现状：

```yaml
      CLUSTER_SECRET: ${CLUSTER_SECRET}
```

注意：`.env` 与 `runtime/` 已 gitignore，全新 worktree 里没有它们——下面的验证步骤正是
利用这一点在干净环境测试，不会碰到用户真实机密。**任何情况下不要打印 `.env` 内容到日志/汇报里。**

## 需要用到的命令

| 用途 | 命令 | 成功预期 |
|------|------|---------|
| 生成机密 | `make secrets` | 输出 `secrets ready (...)`，exit 0 |
| 校验 compose 插值 | `docker compose -f docker-compose.cluster.yml config -q` | 见各步骤（有无守卫报错） |
| Makefile 语法 | `make -n secrets` | 打印将执行的命令，exit 0 |

前置：Docker daemon 运行中（`config` 与 `down` 需要 docker CLI；`config` 不需要起容器）。

## 范围

**In scope**（只允许改这些文件）：

- `Makefile`（`secrets` 目标第 12 行、`down` 目标第 45 行）
- `docker-compose.cluster.yml`（仅 `x-cluster-env` 的 `CLUSTER_SECRET` 一行）
- `docker-compose.node.yml`（仅 `cluster` 服务的 `CLUSTER_SECRET` 一行）

**Out of scope**（看着相关也不要动）：

- `swarm.key` 的生成逻辑——`[ -f ... ]` 对独立文件是正确的守卫，没有本缺口。
- `.env.node.example` — 模板已注明 CLUSTER_SECRET 必填，不需要改。
- `IPFS_PUBLISH_TOKEN` / `CF_TUNNEL_TOKEN` 的既有守卫——保持原样。
- 不要给 `SITE_DOMAIN`、`HTTP_PORT` 等可选变量加守卫。

## Git 工作流

- 分支：`advisor/004-cluster-secret-guard`
- 提交信息：中文 + 约定式英文前缀，如 `fix: CLUSTER_SECRET 逐键追加生成+compose 启动守卫(防部分 .env 静默空值起栈)`
- 不要 push、不要开 PR，除非操作者明确指示。

## 步骤

### Step 1: `make secrets` 的 CLUSTER_SECRET 改为逐键追加

把 `Makefile:12` 的：

```makefile
	@[ -f .env ] || echo "CLUSTER_SECRET=$$(od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')" > .env
```

改为（与下一行 `IPFS_PUBLISH_TOKEN` 的模式一致；`>>` 在文件不存在时会自动创建）：

```makefile
	@grep -q '^CLUSTER_SECRET=' .env 2>/dev/null || \
		echo "CLUSTER_SECRET=$$(od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')" >> .env
```

**验证**（在无 `.env` 的目录状态下，如全新 worktree；若本地已有 `.env` 先 `mv .env .env.advisor-bak`，验证后还原）：

```bash
make secrets && grep -c '^CLUSTER_SECRET=' .env && grep -c '^IPFS_PUBLISH_TOKEN=' .env
```
→ 两个计数均为 `1`。

### Step 2: 验证"部分 .env"场景被修复 + 幂等

```bash
rm .env && printf 'SITE_DOMAIN=pages.example.com\n' > .env
make secrets
grep -c '^CLUSTER_SECRET=' .env && grep -c '^SITE_DOMAIN=' .env
cp .env /tmp/adv-004-env-a && make secrets && cmp .env /tmp/adv-004-env-a && echo IDEMPOTENT
```
→ 两个 grep 计数均为 `1`（既补了缺的键、又保留了用户已写的键）；末行输出 `IDEMPOTENT`（重复执行不改文件）。
（此验证只跑在刚生成的临时 `.env` 上；如 Step 1 备份过用户的 `.env`，此步结束后 `mv .env.advisor-bak .env` 还原。）

### Step 3: 两份编排加 `:?` 守卫

`docker-compose.cluster.yml` 的 `x-cluster-env`：

```yaml
x-cluster-env: &cluster-env
  CLUSTER_SECRET: ${CLUSTER_SECRET:?run `make secrets` first}
```

`docker-compose.node.yml` 的 `cluster` 服务：

```yaml
      CLUSTER_SECRET: ${CLUSTER_SECRET:?set CLUSTER_SECRET in .env, see .env.node.example}
```

**验证**（守卫生效——在 `.env` 不含 CLUSTER_SECRET 时 config 必须失败并给出指引）：

```bash
mv .env /tmp/adv-004-env-b 2>/dev/null; printf 'IPFS_PUBLISH_TOKEN=x\n' > .env
docker compose -f docker-compose.cluster.yml config -q; echo "rc=$?"
mv /tmp/adv-004-env-b .env 2>/dev/null || rm .env
```
→ 报错信息包含 `run \`make secrets\` first`，`rc` 非 0。
随后在正常 `.env`（`make secrets` 产物）下 `docker compose -f docker-compose.cluster.yml config -q` → exit 0。

### Step 4: `make down` 补哑值，保持"无 .env 也能收摊"

把 `Makefile:45` 改为：

```makefile
	@CF_TUNNEL_TOKEN=$${CF_TUNNEL_TOKEN:-x} IPFS_PUBLISH_TOKEN=$${IPFS_PUBLISH_TOKEN:-x} CLUSTER_SECRET=$${CLUSTER_SECRET:-x} $(COMPOSE_CF) down
```

**验证**（无 `.env` 时 down 不因插值守卫而失败）：

```bash
mv .env /tmp/adv-004-env-c 2>/dev/null; make down; echo "rc=$?"; mv /tmp/adv-004-env-c .env 2>/dev/null
```
→ `rc=0`（没有在跑的栈时 down 也应正常空跑成功）。

### Step 5: 全链路回归

**验证**：`make e2e` → `PASS=N FAIL=0`、退出码 0（覆盖：secrets 生成 → 起栈 → 三 peer 成形 → 上传/渲染/容错）。

## 测试计划

- 本计划的"测试"就是 Step 1–4 内嵌的干净环境断言（无 .env / 部分 .env / 幂等 / 守卫报错 / down 哑值），
  全部是命令 + 预期退出码，无需新增测试文件。
- 回归：`make e2e` 全 PASS。

## 完成标准（全部满足，机器可查）

- [ ] 部分 `.env`（只有 SITE_DOMAIN）跑 `make secrets` 后，`grep -c '^CLUSTER_SECRET=' .env` = 1 且原有键保留
- [ ] 连续两次 `make secrets` 之间 `.env` 无变化（`cmp` 通过）
- [ ] `.env` 缺 CLUSTER_SECRET 时 `docker compose -f docker-compose.cluster.yml config -q` 非 0 且报错含指引
- [ ] 无 `.env` 时 `make down` 退出码 0
- [ ] `make e2e` 退出码 0、`FAIL=0`
- [ ] `git status` 显示改动仅限 in-scope 三个文件（`.env*` 备份挪动不落在仓库内）
- [ ] `plans/README.md` 状态行已更新

## STOP 条件

出现以下情况停止并汇报，不要即兴处理：

- Makefile / compose 现状与上文摘录不一致（代码已漂移）。
- `:?` 错误信息里的反引号导致 compose 解析异常（不同 compose 版本对 `:?` 消息的字符处理有差异）——改用不含反引号的消息重试一次，仍失败则 STOP。
- 你在任何操作中意外覆盖/删除了用户已有的 `.env` 且没有备份——立即停止并如实汇报，不要重新生成假装无事（重新生成的 CLUSTER_SECRET 会让既有 runtime 集群失联）。
- `make e2e` 失败且与本改动相关（如 secrets 生成的 `.env` 格式问题）。

## 维护提示

- 今后往 `.env` 增加新的必填机密时，遵循本计划确立的两件套：`make secrets` 逐键 `grep || >>` 追加 + compose `:?` 守卫 + `make down` 哑值，三处同步。
- Review 重点：Step 2 的幂等断言（防止重复执行重写 secret，导致既有集群 runtime 状态失联）；`down` 哑值是否补了 CLUSTER_SECRET。
- 有意不做：`.env` 文件权限收紧（chmod 600）——可作后续小改进，与本缺口独立。
