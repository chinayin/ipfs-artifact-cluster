#!/usr/bin/env bash
# deploy-server: 把本地仓库的运行相关改动可控地增量滚到已在跑的生产服务器。
# 流程：diff → 备份 → 同步 → 重建(make up-cloudflare) → 条件 reload(Caddy) → 验证。
# 默认 --dry-run(只读、绝不改动)；确认后 --apply 才执行。
#
# 纯 bash + ssh/scp/sshpass；配置解析：进程环境变量为主 → 技能 .env 兜底。
set -euo pipefail

VERSION="1.0.0"

# ── 路径与常量 ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"

# 仓库根：优先 git toplevel，否则按技能目录相对回退(.claude/skills/deploy-server → 上三级)
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
if command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
fi

# 同步白名单（只碰运行相关文件；目录项递归展开）。永不触碰：.env/runtime/.backup/docs/plans/.git
WHITELIST=(
  docker-compose.cluster.yml
  docker-compose.cloudflare.yml
  docker-compose.node.yml
  Makefile
  caddy
  scripts
  skills/publish-artifact
  e2e
)

TMPD=""
TS=""
BACKUP_DIR_REMOTE=""

# ── 输出与错误处理 ────────────────────────────────────────────────────────
info() { echo "$*"; }
ok()   { echo "  [OK] $*"; }
warn() { echo "  [!]  $*" >&2; }

die() {
  echo "错误: $1" >&2
  if [ -n "$BACKUP_DIR_REMOTE" ]; then
    echo "已完成部分步骤；被覆盖文件的备份在远端: $BACKUP_DIR_REMOTE" >&2
    echo "回滚：按该路径把白名单文件还原后，在 $DEPLOY_REMOTE_DIR 重跑 make up-cloudflare。" >&2
  fi
  exit "${2:-1}"
}

cleanup() { [ -n "$TMPD" ] && rm -rf "$TMPD" 2>/dev/null || true; }
trap cleanup EXIT

usage() {
  cat >&2 <<'EOF'
deploy-server - 把本地运行相关改动增量滚到已在跑的生产服务器。

用法: deploy.sh [--dry-run | --apply] [-h|--help] [--version]

  --dry-run   (默认) 只读预览：逐文件本地↔远端 sha256 比对，打印将覆盖哪些文件、
              哪些服务会被 make up-cloudflare 重建、Caddyfile 是否变(是否需 reload)、
              本次连接方式。绝不改动远端。
  --apply     执行：远端备份将覆盖的文件 → scp 差异文件 → 同步后 sha256 复核一致
              → make up-cloudflare → 仅当 Caddyfile 变才 caddy validate+reload → 验证。
  -h, --help  显示本帮助并退出。
  --version   打印版本并退出。

配置：进程环境变量为主，缺失则读 .claude/skills/deploy-server/.env 兜底。
  DEPLOY_SSH_HOST(必填) DEPLOY_SSH_USER(root) DEPLOY_SSH_PORT(22)
  DEPLOY_REMOTE_DIR(/data/ipfs) DEPLOY_SSH_KEY DEPLOY_SSH_PASSWORD IPFS_BASE_URL
首次使用: cp .env.example .env 填好再跑。
EOF
}

# ── 参数解析（--help/--version 无需配置）────────────────────────────────────
MODE="dryrun"
case "${1:-}" in
  ""|--dry-run) MODE="dryrun" ;;
  --apply)      MODE="apply" ;;
  -h|--help)    usage; exit 0 ;;
  --version)    echo "$VERSION"; exit 0 ;;
  *)            echo "未知参数: $1" >&2; usage; exit 3 ;;
esac
[ $# -gt 1 ] && { echo "参数过多" >&2; usage; exit 3; }

# ── 配置解析：进程环境为主 → .env 兜底 ──────────────────────────────────────
KEYS="DEPLOY_SSH_HOST DEPLOY_SSH_USER DEPLOY_SSH_PORT DEPLOY_REMOTE_DIR DEPLOY_SSH_KEY DEPLOY_SSH_PASSWORD IPFS_BASE_URL"

# .env 必须存在（即便进程环境已够，也按前置检查要求存在）
if [ ! -f "$ENV_FILE" ]; then
  echo "错误: 未找到配置文件 $ENV_FILE" >&2
  echo "请先执行: cp \"$ENV_EXAMPLE\" \"$ENV_FILE\"  然后填好再跑。" >&2
  exit 2
fi

# 快照进程已提供的值 → source .env(只作兜底默认) → 用进程值覆盖回来(进程优先)
for k in $KEYS; do eval "__PENV_$k=\"\${$k:-}\""; done
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
for k in $KEYS; do
  eval "__pv=\"\${__PENV_$k}\""
  [ -n "$__pv" ] && eval "$k=\"\$__pv\""
done

# 默认值
DEPLOY_SSH_USER="${DEPLOY_SSH_USER:-root}"
DEPLOY_SSH_PORT="${DEPLOY_SSH_PORT:-22}"
DEPLOY_REMOTE_DIR="${DEPLOY_REMOTE_DIR:-/data/ipfs}"
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-}"
DEPLOY_SSH_PASSWORD="${DEPLOY_SSH_PASSWORD:-}"
IPFS_BASE_URL="${IPFS_BASE_URL:-}"
DEPLOY_SSH_HOST="${DEPLOY_SSH_HOST:-}"

[ -n "$DEPLOY_SSH_HOST" ] || die "缺少 DEPLOY_SSH_HOST（在 .env 填服务器 IP/域名，或 export 该环境变量）" 2

# ── 本地依赖 ──────────────────────────────────────────────────────────────
command -v ssh >/dev/null 2>&1 || die "本机缺少 ssh" 5
command -v scp >/dev/null 2>&1 || die "本机缺少 scp" 5
if command -v sha256sum >/dev/null 2>&1; then
  SHACMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHACMD="shasum -a 256"
else
  die "本机缺少 sha256sum / shasum，无法做 sha256 比对" 5
fi
sha_local() {
  [ -f "$1" ] || die "本地文件缺失: $1（可能已删除但仍被 git 跟踪；请提交删除或恢复文件）"
  $SHACMD "$1" | awk '{print $1}'
}

# ── 连接策略（自动识别，封装成函数复用）──────────────────────────────────
SSH_OPTS=( -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 )
SSH_PORT_OPT=( -p "$DEPLOY_SSH_PORT" )
SCP_PORT_OPT=( -P "$DEPLOY_SSH_PORT" )
SSH_PREFIX=()   # sshpass -e（密码兜底时）；否则为空
KEY_OPT=()      # -i <key>（显式 key 时）；否则为空
CONN_METHOD=""

detect_conn() {
  if [ -n "$DEPLOY_SSH_KEY" ]; then
    [ -f "$DEPLOY_SSH_KEY" ] || die "DEPLOY_SSH_KEY 指定的私钥不存在: $DEPLOY_SSH_KEY"
    KEY_OPT=( -i "$DEPLOY_SSH_KEY" -o IdentitiesOnly=yes )
    CONN_METHOD="key（显式私钥: ${DEPLOY_SSH_KEY}）"
    return
  fi
  # 探测默认 key / ssh-agent 是否可免密（BatchMode 禁交互）
  if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${SSH_PORT_OPT[@]}" \
       "$DEPLOY_SSH_USER@$DEPLOY_SSH_HOST" true >/dev/null 2>&1; then
    CONN_METHOD="默认 key / ssh-agent（免密，BatchMode 探测通过）"
    return
  fi
  if [ -n "$DEPLOY_SSH_PASSWORD" ]; then
    command -v sshpass >/dev/null 2>&1 || \
      die "需要密码登录但未安装 sshpass；请 brew install sshpass，或改用 DEPLOY_SSH_KEY" 5
    export SSHPASS="$DEPLOY_SSH_PASSWORD"   # sshpass -e 读环境变量，避免密码进命令行/日志
    SSH_PREFIX=( sshpass -e )
    CONN_METHOD="密码（sshpass，已脱敏不打印）"
    return
  fi
  die "无可用连接方式：未设 DEPLOY_SSH_KEY、默认 key/agent 免密探测失败、且未设 DEPLOY_SSH_PASSWORD" 2
}

# ssh_run "<远端命令字符串>"  —— 复用连接策略；stdin 透传给远端命令
ssh_run() {
  local -a cmd=()
  [ ${#SSH_PREFIX[@]} -gt 0 ] && cmd+=( "${SSH_PREFIX[@]}" )
  cmd+=( ssh "${SSH_OPTS[@]}" )
  [ ${#KEY_OPT[@]} -gt 0 ] && cmd+=( "${KEY_OPT[@]}" )
  cmd+=( "${SSH_PORT_OPT[@]}" "$DEPLOY_SSH_USER@$DEPLOY_SSH_HOST" "$@" )
  "${cmd[@]}"
}

# scp_file <本地路径> <远端绝对路径>
scp_file() {
  local -a cmd=()
  [ ${#SSH_PREFIX[@]} -gt 0 ] && cmd+=( "${SSH_PREFIX[@]}" )
  cmd+=( scp "${SSH_OPTS[@]}" )
  [ ${#KEY_OPT[@]} -gt 0 ] && cmd+=( "${KEY_OPT[@]}" )
  cmd+=( "${SCP_PORT_OPT[@]}" "$1" "$DEPLOY_SSH_USER@$DEPLOY_SSH_HOST:$2" )
  "${cmd[@]}"
}

# ── 枚举白名单文件（优先 git 跟踪文件，天然排除 .env/runtime/fixtures 等）──────
FILES=()
while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done < <(
  git -C "$REPO_ROOT" ls-files -- "${WHITELIST[@]}" 2>/dev/null || true
)
if [ ${#FILES[@]} -eq 0 ]; then
  # 回退：非 git 仓库时用 find 展开
  while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done < <(
    cd "$REPO_ROOT" && for p in "${WHITELIST[@]}"; do
      if [ -d "$p" ]; then find "$p" -type f; elif [ -f "$p" ]; then echo "$p"; fi
    done | grep -v '/\.DS_Store$' | sort -u
  )
fi
[ ${#FILES[@]} -gt 0 ] || die "白名单未匹配到任何本地文件（REPO_ROOT=${REPO_ROOT}）"

# 期望容器与集群节点数（从本地 compose 推导，随拓扑自适应）
# grep -c 在零匹配时输出 "0" 且退出码 1 —— 不能用 `|| echo 3` 兜底(会得到多行 "0\n3")。
EXPECTED_PEERS="$(grep -c 'container_name: cl-cluster' "$REPO_ROOT/docker-compose.cluster.yml" 2>/dev/null || true)"
case "$EXPECTED_PEERS" in ''|*[!0-9]*|0) EXPECTED_PEERS=3 ;; esac
EXPECTED_CONTAINERS="$(grep -h 'container_name:' \
  "$REPO_ROOT/docker-compose.cluster.yml" "$REPO_ROOT/docker-compose.cloudflare.yml" 2>/dev/null \
  | awk '{print $2}')"
[ -n "$EXPECTED_CONTAINERS" ] || die "无法从本地 compose 推导容器名（检查 docker-compose*.yml 是否存在/格式）"

# ── 计算 diff（供 dry-run 与 apply 共用）──────────────────────────────────
CHANGED=()          # 需同步的相对路径
CHANGED_EXISTING=() # 其中远端已存在（需备份）的
CADDY_CHANGED=0
COMPOSE_CHANGED=0

compute_diff() {
  TMPD="$(mktemp -d)"
  # 拉远端 sha256（一次 ssh，读白名单全量）
  printf '%s\n' "${FILES[@]}" | ssh_run \
    "cd \"$DEPLOY_REMOTE_DIR\" 2>/dev/null || { echo __NODIR__; exit 0; }; \
     while IFS= read -r f; do if [ -f \"\$f\" ]; then sha256sum \"\$f\"; else echo \"MISSING  \$f\"; fi; done" \
    > "$TMPD/remote" || die "无法读取远端文件校验和（检查连接与 DEPLOY_REMOTE_DIR）"
  grep -q '__NODIR__' "$TMPD/remote" && die "远端部署目录不存在: $DEPLOY_REMOTE_DIR"

  local f lsha rsha
  for f in "${FILES[@]}"; do
    lsha="$(sha_local "$REPO_ROOT/$f")"
    rsha="$(awk -v p="$f" '$2==p{print $1}' "$TMPD/remote")"
    [ -n "$rsha" ] || rsha="MISSING"
    if [ "$lsha" != "$rsha" ]; then
      CHANGED+=("$f")
      [ "$rsha" != "MISSING" ] && CHANGED_EXISTING+=("$f")
      [ "$f" = "caddy/Caddyfile" ] && CADDY_CHANGED=1
      case "$f" in docker-compose*.yml) COMPOSE_CHANGED=1 ;; esac
    fi
  done
}

print_diff_table() {
  local f lsha rsha
  if [ ${#CHANGED[@]} -eq 0 ]; then
    info "将覆盖的文件: 无（本地与远端一致）"
    return
  fi
  info "将覆盖/新增的文件（local / remote sha 缩略）:"
  for f in "${CHANGED[@]}"; do
    lsha="$(sha_local "$REPO_ROOT/$f")"
    rsha="$(awk -v p="$f" '$2==p{print $1}' "$TMPD/remote")"
    [ -n "$rsha" ] || rsha="MISSING"
    if [ "$rsha" = "MISSING" ]; then
      printf '  + %-42s local:%s remote:(新增)\n' "$f" "${lsha:0:12}"
    else
      printf '  ~ %-42s local:%s remote:%s\n' "$f" "${lsha:0:12}" "${rsha:0:12}"
    fi
  done
}

# ── 验证（真实断言；只读）──────────────────────────────────────────────────
verify() {
  info "== 验证 =="
  local ps name line vok=1
  ps="$(ssh_run "docker ps -a --filter name=cl- --format '{{.Names}} {{.Status}}'")" \
    || die "无法读取容器状态"
  for name in $EXPECTED_CONTAINERS; do
    line="$(printf '%s\n' "$ps" | awk -v n="$name" '$1==n{$1=""; sub(/^ /,""); print}')"
    if [ -z "$line" ]; then
      warn "容器缺失: $name"; vok=0; continue
    fi
    case "$line" in
      *Up*) ok "$name: $line" ;;
      *)    warn "$name 非运行状态: $line"; vok=0 ;;
    esac
  done
  [ "$vok" = 1 ] || die "容器状态检查未通过"

  local n
  n="$(ssh_run "docker exec cl-cluster0 ipfs-cluster-ctl --enc=json peers ls 2>/dev/null | grep -o '\"peername\"' | wc -l | tr -d ' '")" \
    || die "peers ls 执行失败"
  if [ "$n" = "$EXPECTED_PEERS" ]; then
    ok "cluster peers = ${n}（期望 ${EXPECTED_PEERS}）"
  else
    die "cluster peers = ${n:-0}，期望 $EXPECTED_PEERS"
  fi

  if [ -n "$IPFS_BASE_URL" ]; then
    if ! command -v curl >/dev/null 2>&1; then
      warn "本机无 curl，跳过域名渲染验证"
      return
    fi
    local cid out code ctype url
    cid="$(ssh_run "docker exec cl-cluster0 ipfs-cluster-ctl pin ls 2>/dev/null | awk '{print \$1}' | head -1")" || cid=""
    if [ -z "$cid" ]; then
      warn "集群暂无已 pin CID，跳过域名渲染验证"
      return
    fi
    url="${IPFS_BASE_URL%/}/artifact/$cid/"
    out="$(curl -sS -o /dev/null -w '%{http_code} %{content_type}' "$url" 2>/dev/null || echo '000 -')"
    code="${out%% *}"; ctype="${out#* }"
    # 只断言 HTTP 200（读链路通）；不强求 text/html —— 首个已 pin CID 可能是图片/PDF/附件等
    # 非 HTML 制品，content_type 仅作信息打印，否则会在部署已成功后误报失败。
    case "$code" in
      200) ok "域名读取 $url -> $code ${ctype}" ;;
      *)   die "域名读取验证未通过: $url -> ${out}（期望 HTTP 200）" ;;
    esac
  else
    info "  (未配置 IPFS_BASE_URL，跳过域名渲染验证)"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
info "deploy-server v$VERSION  仓库根: $REPO_ROOT"
info "目标: $DEPLOY_SSH_USER@$DEPLOY_SSH_HOST:$DEPLOY_SSH_PORT  远端目录: $DEPLOY_REMOTE_DIR"
detect_conn
info "本次连接方式: $CONN_METHOD"
info ""

compute_diff

if [ "$MODE" = "dryrun" ]; then
  info "===== DRY-RUN（只读预览，未改动任何远端文件）====="
  print_diff_table
  info ""
  if [ "$COMPOSE_CHANGED" = 1 ]; then
    info "服务重建: docker-compose*.yml 有变更 → make up-cloudflare 将按需重建配置变化的服务"
    info "          (可能涉及: $(echo $EXPECTED_CONTAINERS | tr '\n' ' '))"
  else
    info "服务重建: compose 文件无变更 → make up-cloudflare 幂等，通常无服务重建"
  fi
  if [ "$CADDY_CHANGED" = 1 ]; then
    info "Caddyfile: 有变更 → apply 时将 caddy validate + caddy reload（校验不过则中止）"
  else
    info "Caddyfile: 无变更 → 无需 reload"
  fi
  info ""
  info "连接方式: $CONN_METHOD"
  info "apply 后将验证: cl-* 容器 Up/healthy、peers ls = ${EXPECTED_PEERS}、"
  if [ -n "$IPFS_BASE_URL" ]; then
    info "               域名 ${IPFS_BASE_URL%/}/artifact/<真实CID>/ 得 200 text/html"
  else
    info "               （未配 IPFS_BASE_URL，跳过域名渲染验证）"
  fi
  info ""
  info "确认无误后执行: $0 --apply"
  exit 0
fi

# ── APPLY ──────────────────────────────────────────────────────────────────
info "===== APPLY ====="
if [ ${#CHANGED[@]} -eq 0 ]; then
  info "无差异文件需同步。仍执行 make up-cloudflare 以确保栈处于期望状态。"
else
  print_diff_table
fi
info ""

# 1) 远端时间戳 + 备份将被覆盖的文件
TS="$(ssh_run "date +%Y%m%d-%H%M%S")" || die "无法获取远端时间戳"
TS="$(printf '%s' "$TS" | tr -d '\r\n ')"
if [ ${#CHANGED_EXISTING[@]} -gt 0 ]; then
  info "备份将被覆盖的文件 → $DEPLOY_REMOTE_DIR/.backup/$TS/"
  # 任一文件 cp 失败即整体失败（远端 while 的退出码=最后一次命令，必须对每个 cp 显式 exit）；
  # 备份完再核对文件数与 CHANGED_EXISTING 一致，确保"覆盖前备份已真正完成"这一安全网不被击穿。
  printf '%s\n' "${CHANGED_EXISTING[@]}" | ssh_run \
    "set -e; cd \"$DEPLOY_REMOTE_DIR\"; mkdir -p \".backup/$TS\"; n=0; \
     while IFS= read -r f; do d=\$(dirname \"\$f\"); mkdir -p \".backup/$TS/\$d\" || exit 1; \
       cp -p \"\$f\" \".backup/$TS/\$f\" || exit 1; n=\$((n+1)); done; \
     echo \"__BACKED_UP__ \$n\"" \
    > "$TMPD/backup.out" 2>/dev/null || die "备份失败（部分文件可能未备份，已中止，未同步任何文件）"
  BACKUP_DIR_REMOTE="$DEPLOY_REMOTE_DIR/.backup/$TS"
  bcount="$(awk '/^__BACKED_UP__/{print $2}' "$TMPD/backup.out")"
  [ "${bcount:-0}" = "${#CHANGED_EXISTING[@]}" ] \
    || die "备份文件数($bcount)与应备份数(${#CHANGED_EXISTING[@]})不符，已中止，未同步任何文件"
  ok "已备份 ${#CHANGED_EXISTING[@]} 个文件到 $BACKUP_DIR_REMOTE"
else
  info "无已存在文件需备份（差异均为新增或无差异）。"
fi

# 1.5) Caddyfile 覆盖前预校验：把新 Caddyfile 送进 caddy 容器临时路径校验，通过后才允许
#      覆盖挂载文件。否则坏配置一旦落盘，之后任何 caddy 重启/重建都会加载它 → 读链路宕机。
if [ "$CADDY_CHANGED" = 1 ]; then
  info "预校验新 Caddyfile（覆盖挂载文件之前）..."
  ssh_run "mkdir -p \"$DEPLOY_REMOTE_DIR/.backup/$TS\"" || die "创建远端校验临时目录失败"
  scp_file "$REPO_ROOT/caddy/Caddyfile" "$DEPLOY_REMOTE_DIR/.backup/$TS/Caddyfile.new" \
    || die "上传待校验 Caddyfile 失败（未改动任何远端运行文件）"
  ssh_run "cd \"$DEPLOY_REMOTE_DIR\" && \
    docker cp \".backup/$TS/Caddyfile.new\" cl-caddy:/tmp/Caddyfile.deploy-validate && \
    docker exec cl-caddy caddy validate --config /tmp/Caddyfile.deploy-validate --adapter caddyfile; \
    rc=\$?; docker exec cl-caddy rm -f /tmp/Caddyfile.deploy-validate >/dev/null 2>&1 || true; exit \$rc" \
    || die "新 Caddyfile 校验未通过，已中止，未覆盖挂载文件（远端仍运行旧配置）"
  ok "新 Caddyfile 预校验通过"
fi

# 2) 同步差异文件（先建目录，再逐个 scp）
if [ ${#CHANGED[@]} -gt 0 ]; then
  DIRS="$(for f in "${CHANGED[@]}"; do d="$(dirname "$f")"; [ "$d" != "." ] && echo "$d"; done | sort -u | tr '\n' ' ')"
  if [ -n "$DIRS" ]; then
    ssh_run "cd \"$DEPLOY_REMOTE_DIR\" && mkdir -p $DIRS" || die "创建远端目录失败"
  fi
  info "同步差异文件 (${#CHANGED[@]} 个)..."
  for f in "${CHANGED[@]}"; do
    scp_file "$REPO_ROOT/$f" "$DEPLOY_REMOTE_DIR/$f" >/dev/null || die "scp 失败: $f"
    ok "同步 $f"
  done

  # 3) 同步后 sha256 复核一致
  info "复核远端 sha256..."
  printf '%s\n' "${CHANGED[@]}" | ssh_run \
    "cd \"$DEPLOY_REMOTE_DIR\" && while IFS= read -r f; do sha256sum \"\$f\"; done" \
    > "$TMPD/recheck" || die "复核 sha256 失败"
  for f in "${CHANGED[@]}"; do
    lsha="$(sha_local "$REPO_ROOT/$f")"
    rsha="$(awk -v p="$f" '$2==p{print $1}' "$TMPD/recheck")"
    [ "$lsha" = "$rsha" ] || die "同步后 sha256 不一致: $f (local ${lsha:0:12} != remote ${rsha:0:12})"
  done
  ok "全部差异文件 sha256 一致"
fi

# 4) make up-cloudflare（幂等 up -d，只重建变更服务）
info "执行 make up-cloudflare（幂等 up -d）..."
ssh_run "cd \"$DEPLOY_REMOTE_DIR\" && make up-cloudflare" || die "make up-cloudflare 失败"
ok "make up-cloudflare 完成"

# 5) 仅当 Caddyfile 变才 validate + reload（挂载文件，up -d 不会重建 caddy）
if [ "$CADDY_CHANGED" = 1 ]; then
  info "Caddyfile 有变更 → 校验..."
  ssh_run "docker exec cl-caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile" \
    || die "Caddyfile 校验未通过，已中止，未 reload（远端仍运行旧配置的内存态）"
  ok "caddy validate 通过"
  ssh_run "docker exec cl-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile" \
    || die "caddy reload 失败"
  ok "caddy reload 完成"
else
  info "Caddyfile 无变更 → 跳过 reload"
fi

# 6) 验证
info ""
verify

info ""
ok "部署完成。"
[ -n "$BACKUP_DIR_REMOTE" ] && info "备份路径: $BACKUP_DIR_REMOTE"
exit 0
