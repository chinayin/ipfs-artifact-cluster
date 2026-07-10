# Plan 003: 启用 kubo GC，让"过期 unpin"真正走到"不可读 + 磁盘回收"，并修正文档口径

> **执行者须知**：逐步执行本计划。每一步先跑验证命令、确认符合预期再进入下一步。
> 出现"STOP 条件"中的任何情况立即停止并汇报——不要即兴发挥。完成后更新
> `plans/README.md` 中本计划的状态行（除非派发你的 reviewer 声明由其维护索引）。
>
> **漂移检查（最先执行）**：
> `git diff --stat 7863c38..HEAD -- docker-compose.cluster.yml docker-compose.node.yml e2e/run-cluster.sh docs/CAPABILITIES_AND_OPERATIONS.md docs/PUBLISH_SKILL_USAGE.md`
> 若任一在册文件在计划编写后有改动，先比对下文"现状"代码摘录与真实代码；不一致视为 STOP 条件。

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED（GC 是会删数据的机制，靠"pin 的内容 GC 不删"这一前提保安全；本计划用 e2e 断言锁住该前提）
- **Depends on**: 建议在 Plan 002 之后执行（两者都改 `e2e/run-cluster.sh`，避免合并冲突）
- **Category**: bug / 数据生命周期
- **Planned at**: commit `7863c38`, 2026-07-10

## 为什么要做

产品口径是"发布默认 1 周过期"（README、`skills/publish-artifact/SKILL.md`、
`docs/PUBLISH_SKILL_USAGE.md`）。实际链路：`publish.sh` 带 `expire-in` 参数 → IPFS Cluster
到期自动 **unpin**。但 unpin 只是解除保留标记，block 仍留在各节点 kubo 仓库里：

1. **过期内容仍然可读**——网关照常按 CID 返回内容，"过期"对读者不生效；
2. **磁盘只增不减**——kubo 的 GC 需要 daemon 以 `--enable-gc` 启动才会运行（`StorageMax`
   90% 水位触发同样依赖该开关），而 `ipfs/kubo` 官方镜像默认 CMD 是
   `daemon --migrate=true --agent-version-suffix=docker`，**不含** `--enable-gc`，
   本仓库两份编排也都没有覆盖 command。

同时 `docs/CAPABILITIES_AND_OPERATIONS.md` §2 写"未 pin 的内容……执行 `ipfs repo gc`、或仓库到达
`StorageMax` 触发 GC 时会被清掉"——这句话隐含了一个当前部署里不存在的前提（GC 已启用）。
本计划给 kubo 启用 GC（两份编排），补一条"GC 不删被 pin 内容"的 e2e 安全断言，并把文档口径改准确。

## 现状

相关文件：

- `docker-compose.cluster.yml` — 单机 3 节点编排；kubo 公共锚 `x-kubo`（第 2–4 行），三个 ipfs 服务都引用它，改锚即三节点全生效。
- `docker-compose.node.yml` — 多机每台一份的编排；`ipfs` 服务（第 4–21 行）需同样处理。
- `e2e/run-cluster.sh` — 部署 e2e；Case 3（第 78–81 行）验证网关渲染，安全断言插在其后。
- `docs/CAPABILITIES_AND_OPERATIONS.md` — §2"数据模型：pin、临时文件与 GC"（第 37–44 行）。
- `docs/PUBLISH_SKILL_USAGE.md` — §4 行为与约束里"默认 1 周过期"一条（第 58 行）。

`docker-compose.cluster.yml:2-4` 现状：

```yaml
x-kubo: &kubo
  image: ipfs/kubo:v0.42.0
  restart: unless-stopped
```

`docker-compose.node.yml:4-7` 现状（节选）：

```yaml
  ipfs:
    image: ipfs/kubo:v0.42.0
    container_name: ipfs
    restart: unless-stopped
```

`e2e/run-cluster.sh:78-81` 现状（Case 3，新断言插在此后）：

```bash
echo "==> Case 3: gateway renders"
CT=$(ctype "$GW/ipfs/$CID")
echo "$CT" | grep -qi 'text/html' && ok "Content-Type=$CT" || ng "Content-Type=$CT"
curl -fsS "$GW/ipfs/$CID" | grep -q 'HELLO_CLUSTER_E2E' && ok "body readable" || ng "body"
```

`docs/CAPABILITIES_AND_OPERATIONS.md:41-44` 现状（需要修正口径的段落）：

```markdown
- **被 pin 的内容**：永久保留，垃圾回收（GC）**不会**删除。经 cluster 上传（`pin=true`）的内容由 cluster 在各节点 pin 住。
- **未 pin 的内容（临时）**：例如读取/缓存产生的块。执行 `ipfs repo gc`、或仓库到达 `StorageMax` 触发 GC 时**会被清掉**。这就是 IPFS 里的"临时文件"概念 = 未 pin 的缓存块。

**结论**：Agent 经 cluster 代理上传，内容被全集群 pin，属持久内容，不会被 GC 误删。
```

`docs/PUBLISH_SKILL_USAGE.md:58` 现状：

```markdown
- **默认 1 周过期**：到期集群自动 unpin；`--permanent` 才永久（少用）。
```

关键背景知识（执行时不要重新求证，直接采信并按 Step 1 验证前提）：
kubo 的 GC 触发有两条路径——手动 `ipfs repo gc`，或 daemon 带 `--enable-gc` 时按
`Datastore.GCPeriod`（默认 1h）周期性运行、且在仓库达到 `StorageMax`（默认 10GB）的
90% 水位时触发。被 pin 的 block（cluster 会在每个节点的 kubo 上 pin）永不被 GC 删除。

## 需要用到的命令

| 用途 | 命令 | 成功预期 |
|------|------|---------|
| 确认镜像默认 CMD（保留原有 flag 的依据） | `docker inspect ipfs/kubo:v0.42.0 --format '{{.Config.Cmd}}'`（镜像不在本地则先 `docker pull ipfs/kubo:v0.42.0`） | `[daemon --migrate=true --agent-version-suffix=docker]` |
| 校验 compose | `docker compose -f docker-compose.cluster.yml config -q` | exit 0 |
| bash 语法检查 | `bash -n e2e/run-cluster.sh` | exit 0 |
| 部署 e2e | `make e2e` | `PASS=N FAIL=0`，退出码 0 |
| 查运行容器实际参数 | `docker inspect cl-ipfs0 --format '{{.Args}}'`（需栈在跑，可用 `make e2e-keep`） | 包含 `--enable-gc` |

## 范围

**In scope**（只允许改这些文件）：

- `docker-compose.cluster.yml`（仅 `x-kubo` 锚）
- `docker-compose.node.yml`（仅 `ipfs` 服务）
- `e2e/run-cluster.sh`（仅新增一条断言）
- `docs/CAPABILITIES_AND_OPERATIONS.md`（仅 §2）
- `docs/PUBLISH_SKILL_USAGE.md`（仅 §4 过期一条）

**Out of scope**（看着相关也不要动）：

- `scripts/init-cluster.d/001-config.sh` — 不在本计划配置 `StorageMax`/`GCPeriod`（默认值够用；容量规划另议，见维护提示）。
- `skills/publish-artifact/` — 发布脚本行为不变。
- cluster 侧过期机制（`expire-in` → 自动 unpin）— 已工作正常，不动。

## Git 工作流

- 分支：`advisor/003-enable-kubo-gc`
- 提交信息：中文 + 约定式英文前缀，如 `fix: kubo 启用 --enable-gc(过期 unpin 后可回收磁盘)；文档修正 GC 前提`
- 不要 push、不要开 PR，除非操作者明确指示。

## 步骤

### Step 1: 固定前提——确认镜像默认 CMD

**验证**：`docker inspect ipfs/kubo:v0.42.0 --format '{{.Config.Cmd}}'`
→ 恰为 `[daemon --migrate=true --agent-version-suffix=docker]`。
若输出不同：这是 STOP 条件（下文 command 覆盖会丢失未知 flag）。

### Step 2: 两份编排给 kubo 启用 GC

`docker-compose.cluster.yml` 的 `x-kubo` 锚改为：

```yaml
x-kubo: &kubo
  image: ipfs/kubo:v0.42.0
  restart: unless-stopped
  # 启用 GC：unpin/过期的块按 GCPeriod(默认 1h)与 StorageMax 水位回收；
  # 被 pin 内容不受影响（e2e 有断言）。其余 flag 保持镜像默认 CMD 不变。
  command: ["daemon", "--migrate=true", "--enable-gc", "--agent-version-suffix=docker"]
```

`docker-compose.node.yml` 的 `ipfs` 服务加同一行 `command:`（含同样的中文注释）。

**验证**：`docker compose -f docker-compose.cluster.yml config | grep -c 'enable-gc'` → `3`（三个 ipfs 服务都继承）；
`docker compose -f docker-compose.node.yml config 2>/dev/null | grep -c 'enable-gc'` → `1`
（node.yml 插值缺 env 报错的话，用 `NODE_NAME=x ANNOUNCE_IP=x CLUSTER_SECRET=x docker compose -f docker-compose.node.yml config | grep -c 'enable-gc'`）。

### Step 3: e2e 增加"GC 不删被 pin 内容"安全断言

在 `e2e/run-cluster.sh` Case 3 之后、Case 4 之前插入：

```bash
echo "==> Case 3b: manual GC does not remove pinned content"
docker exec cl-ipfs0 ipfs repo gc >/dev/null 2>&1 || true
code=$(curl -s -o /dev/null -w '%{http_code}' "$GW/ipfs/$CID")
[ "$code" = "200" ] && ok "pinned content survives ipfs repo gc" || ng "pinned content gone after gc (code=$code)"
```

**验证**：`bash -n e2e/run-cluster.sh` → exit 0。

### Step 4: 修正 CAPABILITIES §2 的 GC 口径

把"现状"摘录中的第二个列表项与结论改为（保留第一项不动）：

```markdown
- **未 pin 的内容（临时）**：例如读取/缓存产生的块，以及**过期被 cluster 自动 unpin 的内容**。本部署的 kubo 以 `--enable-gc` 启动：按 `Datastore.GCPeriod`（默认 1h）周期回收，仓库达 `StorageMax`（默认 10GB）九成水位也会触发；也可手动 `docker exec <kubo容器> ipfs repo gc`。

**结论**：Agent 经 cluster 代理上传，内容被全集群 pin，不会被 GC 误删；到期 unpin 后，块在各节点下一轮 GC 时回收——**"过期"与"链接实际不可读"之间最多相差一个 GC 周期（默认 ≤1h）**。
```

**验证**：`grep -n 'enable-gc' docs/CAPABILITIES_AND_OPERATIONS.md` → §2 内恰 1 处命中。

### Step 5: 修正发布手册的过期表述

把 `docs/PUBLISH_SKILL_USAGE.md:58` 改为：

```markdown
- **默认 1 周过期**：到期集群自动 unpin，块在各节点下一轮 GC（默认 ≤1h）后回收，期间链接可能短暂仍可读；`--permanent` 才永久（少用）。
```

**验证**：`grep -n 'unpin' docs/PUBLISH_SKILL_USAGE.md` → 该行体现新表述。

### Step 6: 全链路回归

**验证**：`make e2e` → `PASS=N FAIL=0`、退出码 0，输出含
`PASS: pinned content survives ipfs repo gc`；随后 `make publish-e2e` → 同样全绿
（发布链路依赖 pin 语义，双 e2e 都过才算安全落地）。
另起栈期间（或用 `make e2e-keep`）跑 `docker inspect cl-ipfs0 --format '{{.Args}}'` → 包含 `--enable-gc`。

## 测试计划

- 新断言（Step 3）：手动触发 GC 后，已 pin 的 CID 经网关仍 200——锁住"GC 不删 pin"这一安全前提；若未来有人误删 pin 语义（如上传去掉 `pin=true`），此断言会失败。
- 不断言"过期后内容消失"：默认过期 168h、GC 周期 1h，e2e 时间窗内不可验证，属有意取舍（见维护提示）。
- 结构参照既有 Case 3 的 `ok`/`ng` 用法。
- 验证命令：`make e2e && make publish-e2e` → 全 PASS。

## 完成标准（全部满足，机器可查）

- [ ] `docker compose -f docker-compose.cluster.yml config | grep -c 'enable-gc'` = 3
- [ ] node.yml 的 config 输出含 `enable-gc`（带占位 env 跑，见 Step 2）
- [ ] `make e2e` 与 `make publish-e2e` 退出码均 0、`FAIL=0`
- [ ] 运行中的 `cl-ipfs0` 容器 Args 含 `--enable-gc`
- [ ] `grep -n 'enable-gc' docs/CAPABILITIES_AND_OPERATIONS.md` 命中 §2
- [ ] `git status` 显示改动仅限 in-scope 五个文件
- [ ] `plans/README.md` 状态行已更新

## STOP 条件

出现以下情况停止并汇报，不要即兴处理：

- Step 1 镜像默认 CMD 与预期不符（command 覆盖会丢 flag，需人工核对 kubo 镜像文档）。
- Step 3 的断言失败（`ipfs repo gc` 删掉了应被 pin 的内容）——这推翻"cluster 在各节点 kubo 上 pin"的前提，**绝不能带着失败的该断言合并 GC 开关**。
- kubo 容器因新增 flag 无法启动（`docker logs cl-ipfs0` 显示 flag 解析错误）。
- 需要改动 out-of-scope 文件才能通过验证。

## 维护提示

- **容量规划后续**：`StorageMax` 默认 10GB，rf=-1 时每节点存全量；生产应按盘容量在
  `scripts/init-cluster.d/001-config.sh` 显式设置 `Datastore.StorageMax`（本计划有意不做，避免范围膨胀）。
- **升级 kubo 镜像版本时**：需重新核对镜像默认 CMD（Step 1 的值），同步更新两份编排的 command 行。
- Review 重点：command 覆盖是否原样保留 `--migrate=true` 与 `--agent-version-suffix=docker`；文档只改了口径、没顺手改行为描述之外的内容。
- 有意不做：验证"过期→不可读"的长时 e2e（需要小时级等待，可作为独立的慢测试另议）。
