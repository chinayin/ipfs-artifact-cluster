#!/usr/bin/env bash
set -euo pipefail
# Publish e2e: token write ingress gate -> publish via publish.sh (single file & directory)
# -> shareable link renders -> default 1-week expiry is set / --permanent has none.
# Exercises the Agent publish path (:9097 ingress + skills/publish-artifact/publish.sh),
# complementing the deployment e2e (run-cluster.sh). Prereq: .env(CLUSTER_SECRET,
# IPFS_PUBLISH_TOKEN) and runtime/private/swarm.key (see docs/SINGLE_HOST_DEPLOYMENT.md).

ENDPOINT=${ENDPOINT:-http://localhost:9097}   # token write ingress (only POST /add)
BASE=${BASE:-http://localhost:8088}           # read gateway base (/artifact/<CID>)
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

ROOT="$(cd "$(dirname "$0")" && pwd)"
PUBLISH="$ROOT/../skills/publish-artifact/publish.sh"
COMPOSE="docker compose -f docker-compose.cluster.yml"
PASS=0; FAIL=0

# Report: record each result into a manifest, rendered to HTML at the end.
RUN="$ROOT/../runtime/e2e/$(date +%Y%m%d-%H%M%S)-publish"
mkdir -p "$RUN"; MANIFEST="$RUN/manifest.jsonl"
jesc(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
rec(){ printf '{"status":"%s","title":"%s"}\n' "$1" "$(jesc "$2")" >> "$MANIFEST"; }
ok(){   echo "  PASS: $1"; PASS=$((PASS+1)); rec pass "$1"; }
ng(){   echo "  FAIL: $1"; FAIL=$((FAIL+1)); rec fail "$1"; }
info(){ echo "  INFO: $1"; rec info "$1"; }

cleanup(){ [ "$KEEP" -eq 1 ] || (cd "$ROOT/.." && $COMPOSE down >/dev/null 2>&1 || true); }
trap cleanup EXIT

# Poll a URL until it serves 200 (replication across gateways is asynchronous).
get200(){ for _ in $(seq 1 20); do [ "$(curl -s -o /dev/null -w '%{http_code}' "$1")" = "200" ] && return 0; sleep 1; done; return 1; }
# Pull the share CID out of a link: $BASE/artifact/<cid>[/]
cid_of(){ printf '%s' "$1" | sed "s#^$BASE/artifact/##; s#/\$##"; }
# Does the cluster pinset show a real (future-dated) expire_at for this CID?
# Note: single-CID `pin ls <cid>` pretty-prints JSON (space after colon); permanent pins omit the field.
has_expiry(){ docker exec cl-cluster0 ipfs-cluster-ctl --enc=json pin ls "$1" 2>/dev/null | grep -Eq '"expire_at":[[:space:]]*"20[0-9][0-9]'; }

cd "$ROOT/.."

echo "==> 0. prereq check"
[ -f .env ] && grep -q CLUSTER_SECRET .env || { echo "missing .env(CLUSTER_SECRET), see docs/SINGLE_HOST_DEPLOYMENT.md"; exit 1; }
grep -q '^IPFS_PUBLISH_TOKEN=' .env || { echo "missing IPFS_PUBLISH_TOKEN in .env, run 'make secrets'"; exit 1; }
[ -f runtime/private/swarm.key ] || { echo "missing runtime/private/swarm.key, see docs/SINGLE_HOST_DEPLOYMENT.md"; exit 1; }
[ -x "$PUBLISH" ] || { echo "missing skills/publish-artifact/publish.sh"; exit 1; }
TOKEN=$(grep '^IPFS_PUBLISH_TOKEN=' .env | cut -d= -f2)

echo "==> 1. start cluster + ingress"
$COMPOSE up -d

echo "==> 2. wait for cluster proxy + all 3 peers (settle before publishing)"
for i in $(seq 1 150); do
  curl -fsS -X POST "http://localhost:9095/api/v0/version" >/dev/null 2>&1 && break
  sleep 1
  [ "$i" -eq 150 ] && { echo "cluster proxy not ready"; exit 1; }
done
for i in $(seq 1 60); do
  n=$(docker exec cl-cluster0 ipfs-cluster-ctl --enc=json peers ls 2>/dev/null | grep -o '"peername"' | wc -l | tr -d ' ' || true)
  [ "${n:-0}" -ge 3 ] && break
  sleep 1
  [ "$i" -eq 60 ] && { echo "fewer than 3 peers (got ${n:-0})"; exit 1; }
done

echo "==> 3. wait for write ingress (:9097) to be ready"
for i in $(seq 1 150); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
    -F "file=@/dev/null;filename=probe" "$ENDPOINT/add?cid-version=1&expire-in=1m" 2>/dev/null || true)
  [ "$code" = "200" ] && break
  sleep 1
  [ "$i" -eq 150 ] && { echo "write ingress not ready (last code=$code)"; exit 1; }
done

# Configure publish.sh via its 3 env vars (Agent contract).
export IPFS_PUBLISH_ENDPOINT="$ENDPOINT"
export IPFS_PUBLISH_TOKEN="$TOKEN"
export IPFS_BASE_URL="$BASE"

echo "==> Case 1: write-ingress gate"
c=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ENDPOINT/add")
[ "$c" = "401" ] && ok "no token -> 401" || ng "no token -> $c (want 401)"
c=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$ENDPOINT/add")
[ "$c" = "403" ] && ok "token + GET /add -> 403" || ng "token + GET /add -> $c (want 403)"
c=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" -X DELETE "$ENDPOINT/pins/x")
[ "$c" = "403" ] && ok "token + DELETE /pins/x -> 403" || ng "token + DELETE /pins/x -> $c (want 403)"

echo "==> Case 2: publish single file -> link renders"
tmp=$(mktemp -d)
printf '<!doctype html><meta charset=utf-8><h1 id=marker>PUBLISH_E2E_SINGLE</h1>\n' > "$tmp/page.html"
link=$("$PUBLISH" "$tmp/page.html")
info "single link=$link"
{ get200 "$link" && curl -fsS "$link" 2>/dev/null | grep -q 'PUBLISH_E2E_SINGLE'; } && ok "single-file renders" || ng "single-file body"

echo "==> Case 3: publish directory (relative assets) -> index + css render"
mkdir -p "$tmp/site/css"
printf '<!doctype html><meta charset=utf-8><link rel=stylesheet href="./css/app.css"><h1>PUBLISH_E2E_DIR</h1>\n' > "$tmp/site/index.html"
printf 'h1{color:green}\n' > "$tmp/site/css/app.css"
dlink=$("$PUBLISH" "$tmp/site")
info "dir link=$dlink"
get200 "${dlink}index.html" && ok "dir index 200" || ng "dir index"
get200 "${dlink}css/app.css" && ok "dir css 200" || ng "dir css"

echo "==> Case 4: default publish has a 1-week expiry"
dcid=$(cid_of "$link")
has_expiry "$dcid" && ok "default publish sets expire_at" || ng "default publish missing expire_at (cid=$dcid)"

echo "==> Case 5: --permanent has no expiry"
printf '<!doctype html><meta charset=utf-8><h1 id=marker>PUBLISH_E2E_PERMANENT</h1>\n' > "$tmp/perm.html"
plink=$("$PUBLISH" --permanent "$tmp/perm.html")
pcid=$(cid_of "$plink")
has_expiry "$pcid" && ng "--permanent unexpectedly has expire_at (cid=$pcid)" || ok "--permanent has no expire_at"

rm -rf "$tmp"

echo "==> summary: PASS=$PASS FAIL=$FAIL"
python3 "$ROOT/report.py" "$RUN" "IPFS 发布链路 e2e 报告" 2>/dev/null && echo "==> report: $RUN/report.html" || echo "==> report skipped (python3 unavailable)"
[ "$FAIL" -eq 0 ]
