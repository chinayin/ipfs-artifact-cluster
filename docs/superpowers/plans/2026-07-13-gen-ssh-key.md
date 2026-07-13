# gen-ssh-key Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个脚本化 skill `skills/gen-ssh-key/`,按团队规则一条命令生成符合规范的 SSH 密钥(Ed25519 默认、RSA 4096 兜底、优先 puttygen、降级 ssh-keygen)。

**Architecture:** 纯 bash 单脚本 `gen-ssh-key.sh` 完成参数解析、配置解析、工具探测、密钥生成与输出;`test.sh` 用临时目录做端到端断言;`SKILL.md` 提供触发描述与用法;`.env.example` 提供默认输出目录配置样例。仿本仓 `skills/publish-artifact/` 风格。

**Tech Stack:** bash + puttygen + ssh-keygen(无 python/jq 依赖)。

## Global Constraints

- 密钥类型:默认 **Ed25519**;`--rsa` 时用 **RSA 4096**;**永不生成 RSA 2048**。
- 生成工具:默认 `auto` —— 有 `puttygen` 优先用,否则降级 `ssh-keygen`;两者都无 → 退出码 2 + 安装引导。
- 文件名:`<name>.ppk`(仅 puttygen)/ `<name>.pem`(私钥)/ `<name>.pub`(公钥)。
- 备注 `-C`:默认等于 `<name>`,`--comment` 可覆盖。
- 口令:默认无口令 + 强提醒;`--passphrase-file <f>` 加密私钥。
- 覆盖:目标文件已存在且无 `--force` → 报错退出(码 1),不覆盖。
- 输出目录优先级:`--out-dir` > `.env` 的 `SSH_KEY_OUTPUT_DIR` > 当前目录。
- 权限:私钥 `chmod 600`;仅对**脚本新建的**输出目录 `chmod 700`(不改动已存在目录如 `.` / `~/.ssh`)。
- 退出码:`0` 成功;`1` 参数错误/目标已存在/生成失败;`2` 无可用工具。
- `.env` 不入库,只提交 `.env.example`。

---

## File Structure

- Create: `skills/gen-ssh-key/gen-ssh-key.sh` —— 核心脚本(唯一逻辑载体)
- Create: `skills/gen-ssh-key/test.sh` —— 端到端自测
- Create: `skills/gen-ssh-key/SKILL.md` —— 触发描述 + 用法 + 规则说明
- Create: `skills/gen-ssh-key/.env.example` —— 配置样例
- Modify: `.gitignore` —— 忽略 `skills/gen-ssh-key/.env`

---

## Task 1: 脚本骨架 —— 参数解析、配置解析、工具探测、dry-run

**Files:**
- Create: `skills/gen-ssh-key/gen-ssh-key.sh`
- Create: `skills/gen-ssh-key/test.sh`

**Interfaces:**
- Produces(CLI 契约,后续任务复用):
  - `gen-ssh-key.sh <name> [--rsa] [--comment C] [--passphrase-file F] [--out-dir D] [--tool puttygen|ssh-keygen] [--force] [--json] [--dry-run] [--version] [-h|--help]`
  - `--version` → 打印 `VERSION`(初值 `0.1.0`),退出 0
  - `-h/--help` → 打印用法,退出 0
  - 缺 `<name>` → 退出码非 0,stderr 含 "缺少必填参数"
  - `--dry-run` → 打印 `tool=`, `type=`, `outdir=`, `pem=`, `pub=`, `ppk=` 各一行,不生成文件,退出 0
  - 内部变量:`KEY_TYPE`(ed25519|rsa)、`TOOL`、`OUT_DIR`、`PEM`/`PUB`/`PPK`、`RESOLVED_TOOL`

- [ ] **Step 1: 写失败测试(建立 test.sh 骨架 + 前 4 个断言)**

Create `skills/gen-ssh-key/test.sh`:

```bash
#!/usr/bin/env bash
# gen-ssh-key skill 自测。所有产物写入临时目录,跑完清理。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/gen-ssh-key.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
assert_contains() { # <haystack> <needle> <msg>
  case "$1" in *"$2"*) ok "$3";; *) bad "$3 (期望包含: $2)";; esac; }
assert_file() { [ -f "$1" ] && ok "$2" || bad "$2 (文件不存在: $1)"; }
assert_no_file() { [ ! -e "$1" ] && ok "$2" || bad "$2 (文件不应存在: $1)"; }
assert_code() { # <actual> <expected> <msg>
  [ "$1" = "$2" ] && ok "$3" || bad "$3 (退出码 $1,期望 $2)"; }

echo "== Task1: CLI 骨架 =="

# 1. --version
out="$("$SCRIPT" --version)"; assert_contains "$out" "0.1.0" "--version 打印版本号"

# 2. --help
out="$("$SCRIPT" --help)"; assert_contains "$out" "用法" "--help 打印用法"

# 3. 缺 name 报错
set +e; "$SCRIPT" >/dev/null 2>"$TMP/err"; code=$?; set -e
assert_code "$code" "1" "缺 name 退出码 1"
assert_contains "$(cat "$TMP/err")" "缺少必填参数" "缺 name 提示"

# 4. dry-run 打印计划不生成文件
out="$("$SCRIPT" demo --out-dir "$TMP/d1" --dry-run)"
assert_contains "$out" "type=ed25519" "dry-run 显示默认 ed25519"
assert_contains "$out" "$TMP/d1/demo.pem" "dry-run 显示 pem 路径"
assert_no_file "$TMP/d1/demo.pem" "dry-run 不生成文件"

echo ""; echo "结果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: 运行测试确认失败**

Run: `chmod +x skills/gen-ssh-key/test.sh && bash skills/gen-ssh-key/test.sh`
Expected: FAIL —— `gen-ssh-key.sh` 不存在,大量 ❌。

- [ ] **Step 3: 写脚本骨架**

Create `skills/gen-ssh-key/gen-ssh-key.sh`:

```bash
#!/usr/bin/env bash
# gen-ssh-key —— 按团队规则生成 SSH 密钥(Ed25519 默认 / RSA 4096 兜底;puttygen 优先,ssh-keygen 降级)
set -euo pipefail

VERSION="0.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die()  { echo "错误: $*" >&2; exit 1; }
warn() { echo "⚠️  $*" >&2; }

usage() {
  cat <<'EOF'
用法: gen-ssh-key.sh <name> [选项]

  <name>                  服务名/用途,作文件名前缀 + 默认备注
  --rsa                   用 RSA 4096(默认 Ed25519;永不产 RSA 2048)
  --comment "..."         覆盖 -C 备注(默认 = <name>)
  --passphrase-file <f>   从文件读口令加密私钥(默认无口令)
  --out-dir <dir>         输出目录(默认 .env 的 SSH_KEY_OUTPUT_DIR,再默认当前目录)
  --tool puttygen|ssh-keygen  强制工具(默认 auto)
  --force                 覆盖同名密钥(默认拒绝)
  --json                  机器可读输出
  --dry-run               仅打印计划,不生成
  --version               打印版本
  -h, --help              帮助
EOF
}

KEY_TYPE="ed25519"; COMMENT=""; PASSPHRASE_FILE=""; OUT_DIR=""
TOOL="auto"; FORCE=0; JSON=0; DRY_RUN=0; NAME=""

while [ $# -gt 0 ]; do
  case "$1" in
    --rsa) KEY_TYPE="rsa"; shift ;;
    --comment) COMMENT="${2:-}"; shift 2 ;;
    --passphrase-file) PASSPHRASE_FILE="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --tool) TOOL="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --json) JSON=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --version) echo "$VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "未知选项: $1" ;;
    *) if [ -z "$NAME" ]; then NAME="$1"; else die "多余参数: $1"; fi; shift ;;
  esac
done

[ -n "$NAME" ] || { usage >&2; die "缺少必填参数 <name>"; }
case "$NAME" in */*|*' '*) die "name 不能含 / 或空格: $NAME" ;; esac
[ -n "$COMMENT" ] || COMMENT="$NAME"

# 加载脚本同目录 .env(仅取 SSH_KEY_OUTPUT_DIR)
if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$SCRIPT_DIR/.env"; set +a
fi
if [ -z "$OUT_DIR" ]; then OUT_DIR="${SSH_KEY_OUTPUT_DIR:-.}"; fi
OUT_DIR="${OUT_DIR/#\~/$HOME}"

PPK="$OUT_DIR/$NAME.ppk"
PEM="$OUT_DIR/$NAME.pem"
PUB="$OUT_DIR/$NAME.pub"

resolve_tool() {
  case "$TOOL" in
    puttygen)   command -v puttygen  >/dev/null 2>&1 || die "指定 puttygen 但未安装"; echo puttygen ;;
    ssh-keygen) command -v ssh-keygen >/dev/null 2>&1 || die "指定 ssh-keygen 但未安装"; echo ssh-keygen ;;
    auto)
      if   command -v puttygen  >/dev/null 2>&1; then echo puttygen
      elif command -v ssh-keygen >/dev/null 2>&1; then echo ssh-keygen
      else echo ""; fi ;;
    *) die "未知工具: $TOOL(可选 puttygen|ssh-keygen)" ;;
  esac
}
RESOLVED_TOOL="$(resolve_tool)"
if [ -z "$RESOLVED_TOOL" ]; then
  echo "错误: 未找到 puttygen 或 ssh-keygen。" >&2
  echo "安装: brew install putty  (或使用系统自带 ssh-keygen)" >&2
  exit 2
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "tool=$RESOLVED_TOOL"
  echo "type=$KEY_TYPE"
  echo "comment=$COMMENT"
  echo "outdir=$OUT_DIR"
  echo "pem=$PEM"
  echo "pub=$PUB"
  [ "$RESOLVED_TOOL" = "puttygen" ] && echo "ppk=$PPK"
  exit 0
fi

# 生成逻辑在后续任务实现
die "生成逻辑未实现(占位)"
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash skills/gen-ssh-key/test.sh`
Expected: `== Task1 ==` 段全部 ✅,`FAIL=0`。

- [ ] **Step 5: 提交**

```bash
chmod +x skills/gen-ssh-key/gen-ssh-key.sh skills/gen-ssh-key/test.sh
git add skills/gen-ssh-key/gen-ssh-key.sh skills/gen-ssh-key/test.sh
git commit -m "feat(gen-ssh-key): 脚本骨架(参数解析/配置/工具探测/dry-run)"
```

---

## Task 2: ssh-keygen 生成路径 + 覆盖守卫 + 权限 + 文本/JSON 输出

**Files:**
- Modify: `skills/gen-ssh-key/gen-ssh-key.sh`(替换 Task 1 末尾的占位 `die`)
- Modify: `skills/gen-ssh-key/test.sh`(追加断言)

**Interfaces:**
- Consumes(来自 Task 1):`KEY_TYPE`、`COMMENT`、`PASSPHRASE_FILE`、`OUT_DIR`、`PEM`/`PUB`/`PPK`、`RESOLVED_TOOL`、`FORCE`、`JSON`、`die`/`warn`
- Produces:
  - 文件 `<name>.pem`(chmod 600)、`<name>.pub`
  - 文本输出含 `公钥:` 行 + 完整公钥;无口令时 stderr 有 `⚠️` 警告
  - `--json` 输出单行 JSON,字段:`tool`,`type`,`passphrase_protected`(true/false),`files`(数组),`fingerprint`,`pubkey`
  - 函数 `prepare_outdir`、`guard_overwrite`、`emit_output`(供 Task 3 复用)

- [ ] **Step 1: 写失败测试**

在 test.sh 的 `echo ""; echo "结果:..."` 之前插入:

```bash
echo "== Task2: ssh-keygen 路径 =="
D2="$TMP/d2"

# ed25519 默认(强制 ssh-keygen)
out="$("$SCRIPT" svc-a --tool ssh-keygen --out-dir "$D2" 2>"$TMP/e2")"
assert_file "$D2/svc-a.pem" "ed25519 生成私钥 .pem"
assert_file "$D2/svc-a.pub" "ed25519 生成公钥 .pub"
assert_no_file "$D2/svc-a.ppk" "ssh-keygen 不产 .ppk"
perm="$(stat -f '%Lp' "$D2/svc-a.pem" 2>/dev/null || stat -c '%a' "$D2/svc-a.pem")"
assert_code "$perm" "600" "私钥权限 600"
assert_contains "$(ssh-keygen -lf "$D2/svc-a.pub")" "ED25519" "公钥指纹为 ED25519"
assert_contains "$(cat "$TMP/e2")" "⚠️" "无口令时有警告"

# 覆盖守卫:同名再来一次应报错
set +e; "$SCRIPT" svc-a --tool ssh-keygen --out-dir "$D2" >/dev/null 2>"$TMP/e2b"; code=$?; set -e
assert_code "$code" "1" "同名已存在退出码 1"
assert_contains "$(cat "$TMP/e2b")" "已存在" "同名提示已存在"

# --force 覆盖成功
"$SCRIPT" svc-a --tool ssh-keygen --out-dir "$D2" --force >/dev/null 2>&1
ok "--force 覆盖不报错"

# --rsa 4096
"$SCRIPT" svc-r --tool ssh-keygen --out-dir "$D2" --rsa >/dev/null 2>&1
assert_contains "$(ssh-keygen -lf "$D2/svc-r.pub")" "RSA" "--rsa 公钥指纹为 RSA"
bits="$(ssh-keygen -lf "$D2/svc-r.pub" | awk '{print $1}')"
assert_code "$bits" "4096" "RSA 为 4096 位"

# --passphrase-file 加密私钥
echo "s3cret-pass" > "$TMP/pp"
"$SCRIPT" svc-p --tool ssh-keygen --out-dir "$D2" --passphrase-file "$TMP/pp" >/dev/null 2>&1
assert_contains "$(head -3 "$D2/svc-p.pem")" "OPENSSH" "加密私钥仍为 OpenSSH 格式"
set +e; ssh-keygen -y -P "" -f "$D2/svc-p.pem" >/dev/null 2>&1; nopass=$?; set -e
[ "$nopass" -ne 0 ] && ok "空口令无法读取(说明已加密)" || bad "私钥未被加密"

# --json 输出
out="$("$SCRIPT" svc-j --tool ssh-keygen --out-dir "$D2" --json 2>/dev/null)"
assert_contains "$out" "\"type\":\"ed25519\"" "json 含 type"
assert_contains "$out" "\"passphrase_protected\":false" "json 含 passphrase_protected"
assert_contains "$out" "\"tool\":\"ssh-keygen\"" "json 含 tool"
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash skills/gen-ssh-key/test.sh`
Expected: Task2 段大量 ❌(当前仍是占位 `die`)。

- [ ] **Step 3: 实现生成逻辑**

把 `gen-ssh-key.sh` 末尾这两行:

```bash
# 生成逻辑在后续任务实现
die "生成逻辑未实现(占位)"
```

替换为:

```bash
prepare_outdir() {
  local pre=1
  [ -d "$OUT_DIR" ] || pre=0
  mkdir -p "$OUT_DIR"
  [ "$pre" -eq 0 ] && chmod 700 "$OUT_DIR" || true
}

guard_overwrite() {
  local targets="$PEM $PUB"
  [ "$RESOLVED_TOOL" = "puttygen" ] && targets="$PPK $targets"
  for f in $targets; do
    if [ -e "$f" ]; then
      [ "$FORCE" -eq 1 ] || die "目标已存在: $f(用 --force 覆盖)"
    fi
  done
  [ "$FORCE" -eq 1 ] && rm -f $targets || true
}

read_passphrase() { # 回显口令内容(可能为空)
  if [ -n "$PASSPHRASE_FILE" ]; then
    [ -f "$PASSPHRASE_FILE" ] || die "口令文件不存在: $PASSPHRASE_FILE"
    cat "$PASSPHRASE_FILE"
  fi
}

gen_sshkeygen() {
  local pass; pass="$(read_passphrase)"
  local args=(-t "$KEY_TYPE" -C "$COMMENT" -f "$PEM" -N "$pass" -q)
  [ "$KEY_TYPE" = "rsa" ] && args=(-t rsa -b 4096 -C "$COMMENT" -f "$PEM" -N "$pass" -q)
  ssh-keygen "${args[@]}"
  mv -f "$PEM.pub" "$PUB"
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

emit_output() {
  chmod 600 "$PEM"
  local fpr pubkey protected="false"
  [ -n "$PASSPHRASE_FILE" ] && protected="true"
  fpr="$(ssh-keygen -lf "$PUB" 2>/dev/null || echo 'n/a')"
  pubkey="$(cat "$PUB")"

  if [ "$protected" = "false" ]; then
    warn "私钥未设口令。请妥善保管 $PEM(已 chmod 600),勿提交到仓库。"
  fi

  if [ "$JSON" -eq 1 ]; then
    local files="\"$PEM\",\"$PUB\""
    [ "$RESOLVED_TOOL" = "puttygen" ] && files="\"$PPK\",$files"
    printf '{"tool":"%s","type":"%s","passphrase_protected":%s,"files":[%s],"fingerprint":"%s","pubkey":"%s"}\n' \
      "$RESOLVED_TOOL" "$KEY_TYPE" "$protected" "$files" "$(json_escape "$fpr")" "$(json_escape "$pubkey")"
  else
    echo "✅ 已生成 $KEY_TYPE 密钥($RESOLVED_TOOL):"
    [ "$RESOLVED_TOOL" = "puttygen" ] && echo "  PPK : $PPK"
    echo "  私钥: $PEM (chmod 600)"
    echo "  公钥: $PUB"
    echo "  指纹: $fpr"
    echo ""
    echo "公钥:"
    echo "$pubkey"
    echo ""
    echo "提示: 后续用途(导入平台 / 追加 authorized_keys)由使用者决定。"
  fi
}

prepare_outdir
guard_overwrite
case "$RESOLVED_TOOL" in
  ssh-keygen) gen_sshkeygen ;;
  puttygen)   die "puttygen 路径未实现(Task 3)" ;;
esac
emit_output
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash skills/gen-ssh-key/test.sh`
Expected: Task1 + Task2 段全部 ✅,`FAIL=0`。

- [ ] **Step 5: 提交**

```bash
git add skills/gen-ssh-key/gen-ssh-key.sh skills/gen-ssh-key/test.sh
git commit -m "feat(gen-ssh-key): ssh-keygen 生成路径(覆盖守卫/权限/JSON)"
```

---

## Task 3: puttygen 生成路径 + auto 默认探测

**Files:**
- Modify: `skills/gen-ssh-key/gen-ssh-key.sh`(补 `gen_puttygen`,替换 Task 2 的占位 `die`)
- Modify: `skills/gen-ssh-key/test.sh`(追加 puttygen 断言,按 puttygen 是否存在跳过)

**Interfaces:**
- Consumes:`KEY_TYPE`、`COMMENT`、`PASSPHRASE_FILE`、`PPK`/`PEM`/`PUB`、`read_passphrase`、`emit_output`
- Produces:三件产物 `.ppk`/`.pem`/`.pub`;auto 模式下 puttygen 存在时默认选用 puttygen

- [ ] **Step 1: 写失败测试**

在 test.sh 的 `echo ""; echo "结果:..."` 之前插入:

```bash
echo "== Task3: puttygen 路径 =="
if command -v puttygen >/dev/null 2>&1; then
  D3="$TMP/d3"
  "$SCRIPT" svc-pg --tool puttygen --out-dir "$D3" >/dev/null 2>&1
  assert_file "$D3/svc-pg.ppk" "puttygen 产 .ppk"
  assert_file "$D3/svc-pg.pem" "puttygen 产 .pem"
  assert_file "$D3/svc-pg.pub" "puttygen 产 .pub"
  assert_contains "$(ssh-keygen -lf "$D3/svc-pg.pub")" "ED25519" "puttygen 公钥为 ED25519"
  perm="$(stat -f '%Lp' "$D3/svc-pg.pem" 2>/dev/null || stat -c '%a' "$D3/svc-pg.pem")"
  assert_code "$perm" "600" "puttygen 私钥权限 600"

  # auto 默认应选 puttygen
  out="$("$SCRIPT" svc-auto --out-dir "$D3" --dry-run)"
  assert_contains "$out" "tool=puttygen" "auto 默认选 puttygen"
else
  ok "puttygen 未安装,跳过 Task3(降级路径已由 Task2 覆盖)"
fi
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash skills/gen-ssh-key/test.sh`
Expected: 若装了 puttygen → Task3 段 ❌(命中占位 `die`);若未装 → 显示跳过(此情况下按 Step 3 实现后仍为跳过,属预期)。

- [ ] **Step 3: 实现 puttygen 路径**

在 `gen_sshkeygen` 函数**之后**新增:

```bash
gen_puttygen() {
  local genargs=(-t "$KEY_TYPE")
  [ "$KEY_TYPE" = "rsa" ] && genargs+=(-b 4096)
  genargs+=(-C "$COMMENT" -o "$PPK")
  if [ -n "$PASSPHRASE_FILE" ]; then
    [ -f "$PASSPHRASE_FILE" ] || die "口令文件不存在: $PASSPHRASE_FILE"
    genargs+=(--new-passphrase "$PASSPHRASE_FILE")
  fi
  puttygen "${genargs[@]}"

  local exargs=("$PPK" -O private-openssh -o "$PEM")
  [ -n "$PASSPHRASE_FILE" ] && exargs+=(--old-passphrase "$PASSPHRASE_FILE" --new-passphrase "$PASSPHRASE_FILE")
  puttygen "${exargs[@]}"

  # 公钥部分未加密,-L 无需口令
  puttygen "$PPK" -L -o "$PUB"
}
```

把 `case` 里的:

```bash
  puttygen)   die "puttygen 路径未实现(Task 3)" ;;
```

替换为:

```bash
  puttygen)   gen_puttygen ;;
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash skills/gen-ssh-key/test.sh`
Expected: 全部段 ✅,`FAIL=0`(在装了 puttygen 的机器上 Task3 实测通过)。

- [ ] **Step 5: 提交**

```bash
git add skills/gen-ssh-key/gen-ssh-key.sh skills/gen-ssh-key/test.sh
git commit -m "feat(gen-ssh-key): puttygen 生成路径 + auto 默认探测"
```

---

## Task 4: 文档与配置 —— SKILL.md / .env.example / .gitignore

**Files:**
- Create: `skills/gen-ssh-key/SKILL.md`
- Create: `skills/gen-ssh-key/.env.example`
- Modify: `.gitignore`

**Interfaces:**
- Consumes:Task 1-3 完成的 `gen-ssh-key.sh` CLI 契约
- Produces:可被 agent 触发的 skill 描述 + 配置样例

- [ ] **Step 1: 写 `.env.example`**

Create `skills/gen-ssh-key/.env.example`:

```sh
# gen-ssh-key 配置样例。复制为同目录 .env 后生效(.env 不入库)。
# 默认输出目录:未配置时密钥生成到当前目录。
# 建议指向一个集中、权限受控的目录(脚本会对新建目录 chmod 700)。
SSH_KEY_OUTPUT_DIR=~/.ssh/uhomes-keys
```

- [ ] **Step 2: 追加 `.gitignore` 规则**

在 `.gitignore` 末尾追加:

```
# gen-ssh-key 本地配置(含输出目录路径,非项目内容)
skills/gen-ssh-key/.env
```

- [ ] **Step 3: 写 `SKILL.md`**

Create `skills/gen-ssh-key/SKILL.md`:

```markdown
---
name: gen-ssh-key
description: '按团队规范生成 SSH 密钥并返回公钥。Ed25519 默认、RSA 4096 兜底(禁用 RSA 2048),优先 puttygen(产 .ppk/.pem/.pub),未安装则降级 ssh-keygen(产私钥 + .pub)。文件名用服务名/用途作前缀,私钥 chmod 600。用于:"生成 ssh key"、"生成 ssh 公钥/私钥"、"新建一对密钥"、"generate ssh key"、"create ssh keypair"、"给 xxx 服务生成登录密钥"。生成的密钥默认存当前目录(或 .env 配置的目录),后续用途(导入平台 / 追加 authorized_keys)由使用者决定。'
---

# 生成 SSH 密钥(团队规范)

一条命令按团队规则产出符合规范的 SSH 密钥。纯 bash,依赖 puttygen 或 ssh-keygen。

## 团队规则(已固化进脚本)

- 密钥类型:默认 **Ed25519**;`--rsa` 用 **RSA 4096**;**永不生成 RSA 2048**。
- 生成工具:优先 **puttygen**(产 `.ppk/.pem/.pub`),未安装降级 **ssh-keygen**(产私钥 + `.pub`,无 `.ppk`)。
- 文件名:`<name>.ppk / .pem / .pub`,`<name>` = 服务名/用途。
- 备注 `-C`:默认 = `<name>`。
- 口令:默认无口令 + 强提醒;`--passphrase-file` 可加密。
- 覆盖:同名密钥默认拒绝,需 `--force`。
- 权限:私钥 `chmod 600`。

## 配置

输出目录优先级:`--out-dir` > 同目录 `.env` 的 `SSH_KEY_OUTPUT_DIR` > 当前目录。
首次可 `cp .env.example .env` 并改成集中目录(如 `~/.ssh/uhomes-keys`)。

## 用法

\`\`\`bash
./gen-ssh-key.sh jumpserver                       # Ed25519 → jumpserver.{ppk,pem,pub}
./gen-ssh-key.sh jumpserver --rsa                 # RSA 4096
./gen-ssh-key.sh jumpserver --comment "lei.tian@uhomes.com"
./gen-ssh-key.sh jumpserver --passphrase-file ./pp.txt   # 加密私钥
./gen-ssh-key.sh jumpserver --out-dir ~/.ssh/uhomes-keys
./gen-ssh-key.sh jumpserver --force               # 覆盖同名
./gen-ssh-key.sh jumpserver --json                # 机器可读
./gen-ssh-key.sh jumpserver --dry-run             # 只看计划
./gen-ssh-key.sh --tool ssh-keygen jumpserver     # 强制不用 puttygen
\`\`\`

## 产物

| 文件 | 用途 |
|------|------|
| `<name>.ppk` | PuTTY 原生密钥(仅 puttygen 路径) |
| `<name>.pem` | OpenSSH 私钥(chmod 600,勿外泄) |
| `<name>.pub` | OpenSSH 公钥(可复制导入 / 追加 authorized_keys) |

## 退出码

`0` 成功 · `1` 参数错误/目标已存在/生成失败 · `2` 无可用工具(puttygen 和 ssh-keygen 都没有)。

## 自测

\`\`\`bash
bash test.sh
\`\`\`
```

- [ ] **Step 4: 验证 skill 描述与脚本行为一致 + 跑全量自测**

Run:
```bash
bash skills/gen-ssh-key/test.sh
skills/gen-ssh-key/gen-ssh-key.sh demo-doc --dry-run --out-dir /tmp/gk-doc
```
Expected: `test.sh` 全绿;dry-run 输出与 SKILL.md 描述一致(type=ed25519,puttygen 存在时 tool=puttygen)。

- [ ] **Step 5: 提交**

```bash
git add skills/gen-ssh-key/SKILL.md skills/gen-ssh-key/.env.example .gitignore
git commit -m "docs(gen-ssh-key): SKILL.md + .env.example + gitignore"
```

---

## 完成标准

- `bash skills/gen-ssh-key/test.sh` 在有/无 puttygen 的环境下均全绿。
- `gen-ssh-key.sh <name>` 默认产 Ed25519、私钥 600、拒绝覆盖。
- SKILL.md 描述准确触发,规则与脚本一致。
- `.env` 不入库,`.env.example` 已提交。
