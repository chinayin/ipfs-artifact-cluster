# 设计：生产可用的 publish-artifact 发布技能

日期：2026-07-01
状态：已评审通过，待写实现计划

## 目标

把现有 `skills/publish-artifact/` 优化为**生产可用、可独立分发**的技能：全英文、完全自包含、缺配置时引导、并补齐生产级功能。既作为 Claude Code 技能被自动调用，也能当普通 CLI（纯 bash+curl）使用。

## 决策记录（brainstorming 结论）

| # | 决策 | 取舍 |
|---|------|------|
| Q1 | 配置 = **仅 3 个环境变量**（不落配置文件、无 `configure` 子命令）| 最简；缺配置时**友好引导**而非裸报错 |
| Q2 | 生产范围 = 精简基线 **+ 额外功能** | 不止"能跑"，要 UX 完整 |
| Q3 | 额外功能全要：`--json`、上传失败重试、`--version`、`--dry-run` | 面向 Agent/脚本消费 + 鲁棒 |
| 硬约束 | **零 Python、零 jq**（纯 bash+curl）；SKILL/脚本**全英文**；**完全自包含**（无 `docs/`、`../` 外部引用）| 可移植、可分发、无隐藏依赖 |

## 交付物（全英文）

- `skills/publish-artifact/publish.sh` — 重写。
- `skills/publish-artifact/SKILL.md` — 英文、自包含。
- `skills/publish-artifact/test.sh` — 英文、自包含冒烟。

## 配置与引导（核心）

配置 = 3 个环境变量：`IPFS_PUBLISH_ENDPOINT`、`IPFS_PUBLISH_TOKEN`、`IPFS_BASE_URL`。

- 运行发布类命令时若**缺任一变量**：不裸报错，打印英文**引导块**——每个变量的含义、示例（占位域名 `pages.example.com` / `pages-publish.example.com`）、本会话 `export` 写法、持久化到 `~/.zshrc`/`~/.bashrc` 的提示、token 向集群运维索取——退出码 **2**。
- `--help` / `--version` **不触发**配置检查（无需配置即可查看）。
- **SKILL.md 指示 Claude**：被调用时若 `publish.sh` 以码 2 报"未配置"，**不要直接失败**——向用户询问这 3 个值、`export` 到当前会话（并提示可写进 shell profile 持久化），然后重试发布。

## CLI 接口

```
publish.sh [options] <file.html | dir/>

  --json            输出 JSON 对象（默认仅输出一行链接到 stdout）
  --expire-in DUR   自定义过期（默认 168h）
  --permanent       永久（省略 expire-in）
  --verify          发布后 GET 链接并把状态打到 stderr
  --dry-run         仅校验配置+目标、打印将发送的端点/参数，不上传
  --version         打印版本号
  -h, --help        用法
```

- 默认 **stdout 只有一行链接**；`--json` 时 stdout 是一个 JSON 对象；所有诊断走 **stderr**。
- 参数与目标：`<file|dir>` 为待发布对象；未给或不存在按错误码处理（见下）。

## 数据流

1. 解析参数（`--help`/`--version` 直接输出并退出，不查配置）。
2. **依赖检查**：`bash`（检测 `$BASH_VERSION`，被 `sh` 跑则报错）、`curl`（缺失退出码 5）。
3. **配置检查**：3 个 env 齐全否，缺则引导（退出码 2）。
4. **目标检查**：`<file|dir>` 存在否（退出码 4）。
5. 组 query：`cid-version=1`；非 `--permanent` 追加 `expire-in=<DUR>`。
6. 上传（带重试，见下）：
   - **单文件**：`-F "file=@<f>;filename=<basename>"` → 响应取 `cid` → `link = <BASE>/artifact/<cid>`。
   - **目录**：`find -type f -print0` 遍历，每个文件 `-F "file=@<f>;filename=<相对站点根路径>"` + `wrap-with-directory=true` → 取 `"name":""` 行的 `cid`（站点根）→ `link = <BASE>/artifact/<cid>/`。
7. `--dry-run` 在第 6 步前短路：打印 endpoint/method/query/kind/文件数，退出 0，不上传。
8. 输出：默认打印 `link`；`--json` 打印 `{cid, link, kind, expires_in}`。
9. `--verify`：对 `link` 轮询 GET，把状态打到 stderr（内容异步复制，容忍短暂 404/504）。

## 重试

- 触发：curl 退出非 0、或 HTTP `5xx`、或 `000`（连接失败）。
- 策略：最多 3 次，退避 `1s / 2s / 4s`。
- **不重试**：`401` 及其它 `4xx`（永久错误，token/请求问题）。
- 最终失败：打印服务器响应到 stderr，退出码 1。

## 错误与退出码

| 码 | 含义 |
|----|------|
| 0 | 成功 |
| 1 | 发布失败（重试后仍失败，附服务器响应）|
| 2 | 未配置（打印引导块）|
| 3 | 参数/用法错误 |
| 4 | 目标文件/目录不存在 |
| 5 | 缺依赖（curl）或非 bash 运行 |

## `--json` 形态

```json
{"cid":"bafy…","link":"https://…/artifact/bafy…","kind":"file","expires_in":"168h"}
```
- `kind`：`file` 或 `dir`（`dir` 时 `link` 带尾 `/`）。
- `expires_in`：过期时长字符串；`--permanent` 时为 `null`。
- **不含** `size` / 文件数——避免依赖 `stat`（GNU/BSD 不一致），保持可移植。
- 值均为安全字符串（CID、URL 路径、固定枚举、时长），手工拼接 JSON 安全，无需 jq。

## Portability & edge cases（可移植与边界）

- **零 Python / 零 jq**：纯 bash+curl。`python`/`python3` 差异与本技能无关。
- **bash 3.2 兼容**（macOS 自带）：只用数组、`${var#prefix}`、`read -r -d ''`；不用 `mapfile`/`readarray`/`${var,,}`。开头检测 `$BASH_VERSION`，缺失（被 `sh` 执行）报错提示用 bash。
- **可移植工具子集**：`find … -print0`、基础 `sed 's#a#b#'`（不用 `sed -i`）、`grep -oE`；**不用** `date`/`stat`。
- **集群 JSON 解析用空白容忍正则**：`"cid":[[:space:]]*"[^"]*"`、`"name":[[:space:]]*""`——兼容紧凑/美化及潜在版本差异；取不到 cid 即报错附响应，不静默成功。
- **文件名含空格/特殊字符**：`-print0` + `read -r -d ''` + 全程引号。
- **符号链接文件**：`-type f` 不含符号链接，会被跳过——SKILL.md 注明。
- **超大目录**：逐文件 `-F` 可能触碰 `ARG_MAX`"参数过长"——SKILL.md 注明限制（典型 artifact 无碍）。
- **`set -euo pipefail` + `grep` 无匹配返回非零**：计数/解析处 `|| true` 兜底。
- **尾斜杠归一**：`${VAR%/}` 处理 endpoint/base；目录链接补 `/`。

## 测试（test.sh，英文，自包含）

需先 export 3 个 env、部署可达。断言：
1. 单文件发布 → 链接经网关渲染（轮询到 200，容忍异步复制）。
2. 目录站点（相对资源）→ index + css 渲染。
3. `--json` 输出含 `"cid"` 与 `"link"`（无 jq，`grep` 校验）。
4. `--dry-run` 退出 0 且**不产生**新发布（不联网上传）。
5. 缺配置（临时 unset 一个 env）→ 显示引导且退出码 2。

## 不做（YAGNI）

- 不做配置文件 / `configure` 子命令（Q1=B）。
- 不引入 jq / python / 其它运行时。
- `--json` 不含 size/文件数（避免 stat）。
- 不做取消发布 / 列清单（无 owner 概念，维持无状态）。
- 不做跨集群版本的完全通用解析（以空白容忍正则尽力兼容，取不到即明确报错）。
