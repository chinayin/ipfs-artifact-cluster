# gen-ssh-key skill 设计

> 状态:设计定稿(brainstorming 通过)
> 日期:2026-07-13

## 背景与目标

团队现有一份 SSH 密钥生成文档(`use-rsa-key.mdx`),以 puttygen + RSA 2048 为主。
现在要把"生成 SSH 密钥"沉淀成一个可复用的 **skill**,把团队规则用代码强制执行,供 agent 一条命令产出符合规范的密钥。未来放入内部团队 skills 使用。

当前**没有**密钥管控平台:生成的密钥存本地,公钥后续用途由 agent/用户自行决定,不在 skill 内固化导入流程。

## 团队规则(固化进 skill)

| 维度 | 规则 |
|------|------|
| 密钥类型 | 默认 **Ed25519**;`--rsa` 时降级 RSA 4096;**禁用 RSA 2048** |
| 生成工具 | 优先 **puttygen**(产 `.ppk/.pem/.pub`);未安装则降级 **ssh-keygen**(产私钥 + `.pub`,无 `.ppk`) |
| 文件名 | 服务名/用途作前缀:`<name>.ppk / .pem / .pub` |
| 备注 `-C` | 服务名/用途(默认 = `<name>`) |
| 口令 | 推荐加口令,允许无口令;非交互默认**无口令 + 强提醒** |
| 覆盖 | 同名密钥已存在时**拒绝并报错**,需 `--force` |
| 存储位置 | 默认目录由 skill 内 `.env`(`SSH_KEY_OUTPUT_DIR`)配置;未配置则存**当前目录** |
| 后续用途 | 不固化(无管控平台),公钥交给 agent/用户处理 |

## 方案

采用**脚本化 skill**(仿本仓 `skills/publish-artifact/` 风格):规则用 bash 代码强制执行,不会漂移;agent 一条命令拿到密钥。

已否决方案:
- 纯指南式 SKILL.md(无脚本)——规则靠自觉,易走样。
- 脚本 + 轮换/多环境等高级配置——当前用不上,YAGNI。

## 交付物

```
skills/gen-ssh-key/
├── SKILL.md          # 触发描述 + 用法 + 团队规则说明
├── gen-ssh-key.sh    # 纯 bash,核心逻辑
├── .env.example      # 配置样例(SSH_KEY_OUTPUT_DIR)
└── test.sh           # 自测
```

`.env`(实际配置)加入 `.gitignore`,只提交 `.env.example`。纯 `bash`,不依赖 python/jq。

## 命令接口

```sh
./gen-ssh-key.sh <name> [options]
```

| 参数 | 说明 |
|------|------|
| `<name>` (必填) | 服务名/用途,作文件名前缀 + 默认 `-C` 备注 |
| `--rsa` | 用 RSA 4096(默认 Ed25519);永不产 RSA 2048 |
| `--comment "..."` | 覆盖 `-C` 备注(默认 = `<name>`) |
| `--passphrase-file <f>` | 从文件读口令加密私钥(默认无口令) |
| `--out-dir <dir>` | 覆盖输出目录 |
| `--tool puttygen\|ssh-keygen` | 强制工具(默认:有 puttygen 用它,否则降级 ssh-keygen) |
| `--force` | 覆盖同名密钥(默认拒绝) |
| `--json` | 机器可读输出 |
| `--dry-run` | 校验 + 预览,不生成 |
| `--version` | 打印版本 |
| `-h` / `--help` | 帮助 |

## 执行流程

1. 读取脚本同目录 `.env` → `SSH_KEY_OUTPUT_DIR`;`--out-dir` 优先;都没有则用当前目录。
2. `mkdir -p` 输出目录并 `chmod 700`。
3. 目标路径 `<dir>/<name>.{ppk,pem,pub}`。**任一已存在且无 `--force` → 报错退出**(防覆盖丢密钥)。
4. 工具分支:
   - **puttygen**:`-t ed25519`(或 `-t rsa -b 4096`)生成 `.ppk` → 导出 `.pem`(`-O private-openssh`)→ 导出 `.pub`(`-L`)。三件齐全。
     - 有口令时:生成用 `--new-passphrase <f>`;导出 `.pem` 用 `--old-passphrase <f> --new-passphrase <f>`。
   - **ssh-keygen 降级**:`ssh-keygen -t ed25519 -C <comment> -f <name>.pem -N <口令或空>`,重命名 `<name>.pem.pub`→`<name>.pub`。**无 `.ppk`**(输出里明确说明)。RSA 时 `-t rsa -b 4096`。
5. `chmod 600` 私钥文件。
6. 汇总输出:生成的文件清单、指纹(`ssh-keygen -lf` / `puttygen -l`)、**公钥内容(直接可复制)**、无口令时的警告、"后续用途由 agent/用户决定"提示。`--json` 时输出结构化字段(files/fingerprint/pubkey/type/passphrase_protected)。

## 安全规则

- 默认无口令 + 强提醒;`--passphrase-file` 则加密私钥。
- 私钥 `chmod 600`、输出目录 `chmod 700`。
- 拒绝覆盖已有私钥(需显式 `--force`)。
- `.env` 不入库。

## 退出码

- `0` 成功
- `1` 参数错误 / 目标已存在(无 --force) / 生成失败
- `2` 无可用生成工具(puttygen 和 ssh-keygen 都不存在)——打印安装引导

## 自测 `test.sh`

临时目录里验证:
1. Ed25519 三件产出(puttygen 环境下)
2. 私钥权限 600
3. 公钥可被 `ssh-keygen -lf` 解析
4. 拒绝覆盖生效(第二次同名报错,退出码非 0)
5. `--rsa` 产 4096
6. `--passphrase-file` 生效(私钥被加密)
7. 强制 `--tool ssh-keygen` 降级路径可用(产私钥 + `.pub`,无 `.ppk`)

跑完清理临时目录。

## 与现有文档的关系

`use-rsa-key.mdx` 已更新为 Ed25519 优先。本 skill 是其"可执行版",两者规则保持一致(Ed25519 默认、RSA 4096 兜底、服务名前缀、chmod 600)。
