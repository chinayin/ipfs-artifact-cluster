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

prepare_outdir() {
  local pre=1
  [ -d "$OUT_DIR" ] || pre=0
  mkdir -p "$OUT_DIR"
  [ "$pre" -eq 0 ] && chmod 700 "$OUT_DIR" || true
}

guard_overwrite() {
  local targets=("$PEM" "$PUB")
  [ "$RESOLVED_TOOL" = "puttygen" ] && targets=("$PPK" "${targets[@]}")
  for f in "${targets[@]}"; do
    if [ -e "$f" ]; then
      [ "$FORCE" -eq 1 ] || die "目标已存在: $f(用 --force 覆盖)"
    fi
  done
  [ "$FORCE" -eq 1 ] && rm -f "${targets[@]}" || true
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
    local files="\"$(json_escape "$PEM")\",\"$(json_escape "$PUB")\""
    [ "$RESOLVED_TOOL" = "puttygen" ] && files="\"$(json_escape "$PPK")\",$files"
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
  puttygen)   gen_puttygen ;;
esac
emit_output
