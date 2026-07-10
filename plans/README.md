# Implementation Plans（顾问审计产出）

由 improve 技能于 2026-07-10 生成（审计基线 commit `7863c38`）。按下表顺序执行，除非依赖说明另有要求。
每个执行者：开工前通读所属计划全文，遵守其 STOP 条件，完成后回来更新自己那一行的状态。

审计只做静态审查（未起栈实测），完整发现清单（含未入计划的中低优先级项）见当次会话报告；
本目录只收录已批准转化为计划的 4 项。

## 执行顺序与状态

| Plan | 标题 | 优先级 | 工作量 | 依赖 | 状态 |
|------|------|--------|--------|------|------|
| 001 | 写入口 9097 默认仅绑回环（消除文档与实现矛盾） | P1 | S | — | DONE（2026-07-10，worktree 分支 `advisor/001-bind-9097-loopback`，commit `747a983`，reviewer 复核 e2e PASS=8 FAIL=0，已合并入 main（合并态集成验证：部署 e2e 9/9、发布 e2e 8/8）） |
| 002 | Caddy 读 LB 加被动健康检查与重试（修"挂节点仍可读"） | P1 | S | — | DONE（2026-07-10，分支 `advisor/002-caddy-lb-health-retry`，commit `5170e5b`，执行者复现修复前 502、reviewer 复核 e2e PASS=8 FAIL=0，已合并入 main（合并态集成验证：部署 e2e 9/9、发布 e2e 8/8）） |
| 003 | 启用 kubo GC（过期 unpin → 真正不可读 + 磁盘回收）+ 文档口径 | P1 | M | 在 002 之后 | DONE（2026-07-10，分支 `advisor/003-enable-kubo-gc`，commit `9117ec9`，reviewer 复核 e2e PASS=8 FAIL=0 含 Case 3b、容器 Args 含 --enable-gc，已合并入 main（合并态集成验证：部署 e2e 9/9、发布 e2e 8/8）。备注：完成标准 grep -c=3 在 compose v5 下实测为 4（锚回显），实质达标） |
| 004 | CLUSTER_SECRET 生成与启动守卫 | P2 | S | 在 001 之后 | DONE（2026-07-10，分支 `advisor/004-cluster-secret-guard`，commit `374f0f8`。执行者曾报 e2e Case 4 失败并误判为预存环境问题——真因是其 Step 2 残留的 `SITE_DOMAIN` 留在 `.env` 切换了 Caddy 站点模式；reviewer 清残留后复核 e2e PASS=7 FAIL=0、守卫/幂等/down 哑值全过，已合并入 main（合并态集成验证：部署 e2e 9/9、发布 e2e 8/8）） |

状态取值：TODO | IN PROGRESS | DONE | BLOCKED（附一行原因）| REJECTED（附一行理由）

## 依赖说明

- **003 排在 002 之后**：两者都修改 `e2e/run-cluster.sh`（002 改 Case 5，003 在 Case 3 后插入 Case 3b），顺序执行避免合并冲突；无逻辑依赖。
- **004 排在 001 之后**：两者都修改 `docker-compose.cluster.yml`（001 改 caddy ports，004 改 `x-cluster-env`），顺序执行避免合并冲突；无逻辑依赖。
- 001 与 002 互相独立，可并行（不同文件）。
- 每个计划各自跑 `make e2e` / `make publish-e2e` 回归，同一时刻只允许一个计划占用本机 Docker 栈（e2e 会 up/down 同名容器）。

## 已评估但未入计划的发现（防止重复审计）

以下来自同一轮审计，**不是被否决**，而是本轮未获选转化为计划；后续 run 可直接从这里取材，不必重新发现：

- 写入口 9097 无请求体大小限制/配额（审计 #4，MED）——建议 Caddyfile `:9097` 加 `request_body max_size`。
- 多机部署形态缺 Agent 发布链路（#6，MED）——`node.yml` 无 Caddy/9097/token 入口，发布技能在多机生产无落点。
- 直连 SSL 模式无 HTTPS 写入口（#7，MED）——`:9097` 站点块永远明文，可加 `{$PUBLISH_DOMAIN}` 自动 TLS 站点块。
- 无 CI（#8，MED）——shellcheck / `docker compose config` / `caddy validate` / 技能冒烟。
- `publish.sh --expire-in` 未校验，拼入 query 与 JSON（#9，LOW-MED）。
- 目录发布文件名含 `;` `"` `,` 破坏 `curl -F`（#10，LOW）。
- 文档小错：`ACME_EMAIL` 无消费方（#11）；`uri replace` 全量替换边角（#12）；`caddy:2-alpine` 未锁 patch（#13）。
- 方向性（供产品权衡）：artifact 共享 origin 的 XSS 隔离（subdomain 网关或 CSP sandbox）、单一共享 token 的审计/吊销治理、Prometheus 监控告警、短链/映射薄服务。

## 真正否决的发现

- Caddy 写入口 token 比较非常数时间（时序侧信道）：威胁模型内不成立（需网络侧高精度计时 + 该入口本就限内网/CF 之后），不值得做。
