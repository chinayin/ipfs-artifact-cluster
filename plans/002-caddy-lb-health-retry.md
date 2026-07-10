# Plan 002: 给 Caddy 读 LB 加被动健康检查与重试，让"挂节点仍可读"在 /artifact 入口真正成立

> **执行者须知**：逐步执行本计划。每一步先跑验证命令、确认符合预期再进入下一步。
> 出现"STOP 条件"中的任何情况立即停止并汇报——不要即兴发挥。完成后更新
> `plans/README.md` 中本计划的状态行（除非派发你的 reviewer 声明由其维护索引）。
>
> **漂移检查（最先执行）**：
> `git diff --stat 7863c38..HEAD -- caddy/Caddyfile e2e/run-cluster.sh`
> 若任一在册文件在计划编写后有改动，先比对下文"现状"代码摘录与真实代码；不一致视为 STOP 条件。

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none（但与 Plan 003 都改 `e2e/run-cluster.sh`，需顺序执行，见 plans/README.md）
- **Category**: bug
- **Planned at**: commit `7863c38`, 2026-07-10

## 为什么要做

项目核心卖点是"多副本、挂掉部分节点不影响读取"（README 特性第 2 条），推荐读取入口是 Caddy 的
`/artifact/<CID>`（三网关轮询 LB）。但 `caddy/Caddyfile` 的 `reverse_proxy` 只配置了
`lb_policy round_robin`——Caddy 默认**不启用**被动健康摘除（`fail_duration` 默认 0，失败的上游
不会被标记为不可用）也**不重试**（`lb_try_duration` 默认 0）。因此停掉任一 ipfs 节点后，轮询仍会把
约 1/3 的请求打到死上游，直接对用户返回 502——故障容忍在推荐入口上不成立。
现有部署 e2e 的 Case 5 恰好是经 `:8080`（ipfs0 原生网关，绕过 Caddy）验证的，所以测不出这个缺口。
本计划给 LB 加时间窗重试 + 被动摘除，并把 e2e 补成"停节点后经 /artifact 连续多次请求全 200"。

## 现状

相关文件：

- `caddy/Caddyfile` — 读取站点 + 写入口配置；问题在读取站点的 `reverse_proxy` 块（第 11–13 行）。
- `e2e/run-cluster.sh` — 部署 e2e；Case 5（第 89–93 行）只经 `$GW`（ipfs0 直连网关）验证容错。
- `docs/SINGLE_HOST_DEPLOYMENT.md:193` — 已记录：Caddyfile 是 bind mount，改完需
  `docker exec cl-caddy caddy reload --config /etc/caddy/Caddyfile` 或重建容器（e2e 每次全新起栈，不受影响）。

`caddy/Caddyfile:6-14` 现状：

```caddyfile
{$SITE_DOMAIN} {
	# /artifact/<CID>[/...] → /ipfs/<CID>[/...]
	@art path /artifact/*
	uri @art replace /artifact/ /ipfs/

	reverse_proxy ipfs0:8080 ipfs1:8080 ipfs2:8080 {
		lb_policy round_robin
	}
}
```

`e2e/run-cluster.sh:89-93` 现状（Case 5）：

```bash
echo "==> Case 5: fault tolerance -- stop ipfs1, still readable via ipfs0 gateway"
docker stop cl-ipfs1 >/dev/null
code=$(curl -s -o /dev/null -w '%{http_code}' "$GW/ipfs/$CID")
[ "$code" = "200" ] && ok "gateway still 200 after stopping 1 node" || ng "code=$code after stopping 1 node"
docker start cl-ipfs1 >/dev/null
```

e2e 脚本内可用的既有工具函数（直接复用，不要重造）：`ok "<标题>"`、`ng "<标题>"` 记录断言结果；
`$ART` 是 Caddy 入口（默认 `http://localhost:8088`）；`$CID` 在 Case 1 已赋值。
仓库惯例：Caddyfile 用 tab 缩进 + 中文注释；e2e 断言标题是给 HTML 报告看的短句。

## 需要用到的命令

| 用途 | 命令 | 成功预期 |
|------|------|---------|
| 校验 Caddyfile 语法 | `docker run --rm -e SITE_DOMAIN=':80' -e IPFS_PUBLISH_TOKEN=x -v "$PWD/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile` | 输出 `Valid configuration`，exit 0 |
| bash 语法检查 | `bash -n e2e/run-cluster.sh` | exit 0 |
| 部署 e2e | `make e2e` | 末尾 `PASS=N FAIL=0`，退出码 0 |

前置：本机 Docker daemon 运行中。

## 范围

**In scope**（只允许改这些文件）：

- `caddy/Caddyfile`（仅读取站点的 `reverse_proxy` 块）
- `e2e/run-cluster.sh`（仅 Case 5 段落）

**Out of scope**（看着相关也不要动）：

- `caddy/Caddyfile` 的 `:9097` 写入口块——与读路径容错无关。
- `docker-compose.cluster.yml` / overlay——不需要改编排。
- `e2e/run-publish.sh`、`skills/`——发布链路不在本计划。
- 不要引入主动健康检查（`health_uri`）：kubo 网关没有廉价的健康端点，被动摘除 + 重试已满足需求，主动探测属过度设计。

## Git 工作流

- 分支：`advisor/002-caddy-lb-health-retry`
- 提交信息：中文 + 约定式英文前缀，如 `fix: Caddy 读 LB 加被动健康摘除与重试(修停节点后 /artifact 间歇 502)`
- 不要 push、不要开 PR，除非操作者明确指示。

## 步骤

### Step 1: reverse_proxy 加被动健康摘除与时间窗重试

把 `caddy/Caddyfile` 读取站点的 `reverse_proxy` 块改为：

```caddyfile
	reverse_proxy ipfs0:8080 ipfs1:8080 ipfs2:8080 {
		lb_policy round_robin
		# 故障容忍：上游失败后被动摘除 30s（max_fails 默认 1）；
		# 单个请求在 5s 窗口内换其它上游重试——否则停一个节点后
		# 轮询仍会把 ~1/3 请求打到死上游直接 502。
		lb_try_duration 5s
		lb_try_interval 250ms
		fail_duration 30s
	}
```

（保持 tab 缩进与中文注释的仓库惯例。）

**验证**：上表"校验 Caddyfile 语法"命令 → `Valid configuration`。

### Step 2: e2e Case 5 补"经 Caddy /artifact 连续读全 200"断言

在 `e2e/run-cluster.sh` Case 5 中、`docker stop cl-ipfs1` 之后且 `docker start cl-ipfs1` 之前，
在既有 `$GW` 断言后追加（复用既有 `ok`/`ng`；连续 6 次覆盖 3 上游轮询两圈）：

```bash
artok=1
for _ in $(seq 1 6); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$ART/artifact/$CID")
  [ "$code" = "200" ] || { artok=0; break; }
done
[ "$artok" = 1 ] && ok "/artifact still 200 x6 via Caddy after stopping 1 node" \
                 || ng "/artifact returned $code via Caddy after stopping 1 node"
```

**验证**：`bash -n e2e/run-cluster.sh` → exit 0。

### Step 3: 全链路回归（含新断言）

**验证**：`make e2e` → 末尾 `PASS=N FAIL=0`、退出码 0，输出中包含
`PASS: /artifact still 200 x6 via Caddy after stopping 1 node`。

### Step 4:（可选但建议）确认修复确实是必要的——回归复现

临时把 Step 1 的三行新增配置注释掉，重跑 `make e2e`：新断言应**失败**（间歇 502）。
确认后恢复配置，再跑一次 `make e2e` 全绿。该步骤证明断言有区分力，防"假绿"。

**验证**：注释掉时 `make e2e` 退出码非 0 且 FAIL 计数 ≥1；恢复后退出码 0。
（注意：轮询打到死上游有概率性，若注释掉后先跑出全绿，重跑一次即可复现失败。）

## 测试计划

- 新断言（Step 2）即回归测试：停 1 节点后经 Caddy 连续 6 次读取 `/artifact/<CID>` 全 200。
  修复前该断言以高概率失败（6 次轮询必然命中死上游 ≥2 次且无重试）；修复后必过。
- 结构参照既有 Case 5 的 `ok`/`ng` 用法（`e2e/run-cluster.sh:89-93`）。
- 验证命令：`make e2e` → 全 PASS。

## 完成标准（全部满足，机器可查）

- [ ] `caddy validate`（上表命令）输出 `Valid configuration`
- [ ] `grep -c 'fail_duration' caddy/Caddyfile` 返回 1
- [ ] `make e2e` 退出码 0、`FAIL=0`，报告含新断言的 PASS
- [ ] `git status` 显示改动仅限 in-scope 两个文件
- [ ] `plans/README.md` 状态行已更新

## STOP 条件

出现以下情况停止并汇报，不要即兴处理：

- `caddy validate` 报不认识 `lb_try_duration` / `fail_duration`（镜像解析到的 Caddy 版本异常陈旧）。
- Step 4 中恢复配置后新断言仍失败两次（说明失败根因不是 LB 重试，可能是副本未就绪等别的问题）。
- Caddyfile 或 run-cluster.sh 与"现状"摘录不一致（代码已漂移）。
- 修复似乎需要动 out-of-scope 文件（如编排文件）。

## 维护提示

- `fail_duration 30s` 意味着节点恢复后最长 30s 才会重新进入轮询——对本场景（静态内容、三副本全量）无感知，但若未来副本因子改为非全量（rf=2/3），单上游可能没有某 CID 的本地副本、需经 p2p 拉取变慢，届时可考虑加大 `lb_try_duration`。
- Review 重点：确认没有顺手加 `health_uri`（out of scope）；e2e 新断言在 `docker start cl-ipfs1` 之前执行（节点仍处于停止状态才有意义）。
- 已知未修（另行记录）：`uri replace /artifact/ /ipfs/` 是全量替换，路径中部再现 `/artifact/` 的边角会被误改写（审计发现 #12，LOW）。
