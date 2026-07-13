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

echo ""; echo "结果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
