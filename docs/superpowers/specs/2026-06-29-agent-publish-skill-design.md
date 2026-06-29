# 设计：Agent 发布技能 + 集群上传入口

日期：2026-06-29
状态：已评审通过，待写实现计划

## 目标与体验

用私有 IPFS Cluster 复刻 Claude Artifacts 的核心动作：**Agent 生成 HTML（单文件，或带资源的目录）→ 一句话发布 → 拿到一个稳定、不可变、可分享的链接**。

语义是**快照**：每次发布产生一个新 CID / 新链接，旧版本永久可达（天然版本历史）。**不做**原地更新，**不做**可变命名层（IPNS / DNSLink / slug 映射表）——这与 IPFS 内容寻址的本质一致，且保持系统无状态。

## 决策记录（brainstorming 结论）

| # | 决策 | 取舍 |
|---|------|------|
| Q1 | **不可变快照**链接，无命名层 | 最贴合 IPFS、无状态、天然版本历史；放弃"同链接原地更新" |
| Q2 | 技能是**可移植包**，env 注入配置，"用前配一次" | 装到任意 Agent 环境，指向已部署集群 |
| Q3 | 分享链接**路径式**（同源） | 简单、一张证书；放弃子域式 origin 隔离（见下方升级路径）|
| Q4 | 技能是**无状态发布器**：发布(单文件+目录) + 默认 1 周过期 + 永久为特殊选项；**不提供取消发布** | 无 owner 概念，判断不了权限就不给删除动作；清理靠过期 + 管理员 ctl |
| Q5 | `skills/` = 对外分发面；`.claude/skills/` = 本仓库开发面 | e2e 技能移入 `.claude/skills/` 并选择性纳入版本 |
| Q6 | 写操作走 **token 鉴权上传入口** | 技能装在别处时，写入口很可能不在控制面网络内，给写一个凭据闸门 |

## 交付物

### (a) 对外技能 `skills/publish-artifact/`
- `SKILL.md`：frontmatter（name + description 触发"发布/分享 HTML"场景）+ 中文 runbook。
- `publish.sh`：curl 助手，零额外语言依赖。

### (b) 集群上传入口（Caddy 新增 token 写口）
- 在现有 `cl-caddy` 上新增一个**站点/端口 `:9097`**，**token 鉴权**，反代到 cluster0 的 **REST API `:9094`**。
- **只放行 `POST /add`**，其余 REST 管理路由（`/pins/*` 的 DELETE、`/peers/*` 等）一律拒绝 → Agent 在路由层就拿不到 unpin / peers rm，落实 Q4。
- 读路径沿用现有 `:8088 /artifact/<CID>`，不变。

### (c) 仓库结构调整
- `skills/kubo-cluster-e2e/` → `.claude/skills/kubo-cluster-e2e/`。
- `.gitignore`：在忽略 `.claude/` / `.claude/skills/` 的基础上，加 `!` 例外把 `.claude/skills/kubo-cluster-e2e/` 纳入版本。
- 删除 Makefile 的 `claude-skills` 软链目标（e2e 现在原生位于 `.claude/skills/`，Claude Code 在本仓库自动加载）。

## 发布数据流

```
Agent ──(Authorization: token)──▶ 写入口(Caddy :9097, 仅 POST /add) ──▶ cluster0 REST :9094 /add
   │   multipart: file=@<HTML 文件 或 目录>
   │   query:     cid-version=1 & expire-in=168h（默认；permanent 时省略）
   ◀── { "cid": "bafy…", "name": "…", "allocations": [...] }
   └─▶ 拼分享链接：<IPFS_BASE_URL>/artifact/<cid>[/index.html]
```

- **单文件**：`add` 返回文件 CID，链接 `<IPFS_BASE_URL>/artifact/<cid>`。
- **目录（多资源站点）**：递归 `add` + `wrap-with-directory=true`，返回**目录 CID**，链接 `<IPFS_BASE_URL>/artifact/<dirCID>/`；目录内相对资源（`./style.css` 等）经网关按相对路径自动解析。要求目录含 `index.html`。
- **CIDv1**：强制 `cid-version=1`（现代网关 / 未来子域式都需要）。
- **过期**：默认 `expire-in=168h`（1 周），到期集群自动 unpin、块随后被 GC；`--permanent` 省略该参数 = 永久（仅特殊情况）。
- **副本因子**：继承集群默认（rf=-1，全节点 pin），不在技能侧覆盖。

> 已验证（v1.1.6）：`POST :9094/add?expire-in=5m` 单次调用即完成 添加 + 全集群 pin（3 副本）+ 设置 `expire_at`。

## 配置与安全模型

技能只认 **3 个环境变量**：

| env | 含义 | 示例 |
|-----|------|------|
| `IPFS_PUBLISH_ENDPOINT` | token 写入口地址 | `https://art.example.com/publish` 或 `https://<host>:9097` |
| `IPFS_PUBLISH_TOKEN` | 上传凭据（Bearer/Basic）| `<token>` |
| `IPFS_BASE_URL` | 拼分享链接的读 base | `https://art.example.com`（可回退 `http://<host>:8088`）|

安全红线（硬约束）：
- **读写分离**：读口 `:8088` 可较广可达（只读）；**写口 `:9097` 必须带 token**；原生端口 `:9094 / :9095 / :5001` 仍**绝不暴露公网**。
- 写口**只放行 `/add`**，从路由层堵死管理动作，落实"Agent 不能取消发布"。
- **无 owner 概念**：内容清理只靠**过期自动回收** + 管理员 `ipfs-cluster-ctl`；技能不提供删除。
- **分享形态**：当前路径式（所有 artifact 同源）。**升级路径**（未来需要 origin 隔离时）：改用子域式 `https://<cidv1>.ipfs.<域名>`，需泛域名 DNS `*.ipfs.<域名>` + 泛域名证书，并调整 kubo `Gateway.PublicGateways` 与 Caddy 站点。

## 错误处理与边界

- 缺 env / token 401 / 端点不可达 → 技能**明确报错**并提示缺哪个配置项，绝不静默成功。
- 目录无 `index.html` → 告警（链接仍可作目录列表访问）。
- 上传返回即视为成功（pin 为异步）；提供可选 `--verify`，发布后调用一次 cluster `status <cid>` 确认副本落地。
- 体积上限 / 超时由写入口（Caddy）兜底，技能透传其错误码与信息。

## 测试

- **技能侧** `publish.sh` e2e：单文件 与 目录 两条路径——发布 → 取回链接 → `GET` 渲染 200 → 确认该 pin 已带 `expire_at`（默认 1 周）。
- **写入口闸门**断言：无 token → 401；有 token → 200；非 `/add` 的管理路由（如 DELETE `/pins/<cid>`）→ 被拒。
- 复用本仓库已验证的单机 3 节点集群。

## 不做（YAGNI）

- 不做可变链接 / IPNS / DNSLink / slug 映射。
- 不做 Agent 侧的取消发布、列清单、多租户账本（需要状态层）。
- 不做子域式 origin 隔离（仅留升级路径）。
- 不做 WebUI（已确认无用，本轮移除）。
