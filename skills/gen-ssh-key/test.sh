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
