#!/usr/bin/env bash
set -euo pipefail
# v2 cluster e2e: upload via cluster proxy -> 3-node replication -> any gateway reads
# -> kill one node, still readable. Prereq: .env(CLUSTER_SECRET) and
# runtime/private/swarm.key generated (see docs/SINGLE_HOST_DEPLOYMENT.md).

PROXY=${PROXY:-http://localhost:9095}   # cluster IPFS proxy (Agent upload endpoint), see docs/SINGLE_HOST_DEPLOYMENT.md
GW=${GW:-http://localhost:8080}         # ipfs0 gateway (user read endpoint)
ART=${ART:-http://localhost:8088}       # Caddy friendly path /artifact/<CID>
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

ROOT="$(cd "$(dirname "$0")" && pwd)"
FIX="$ROOT/fixtures"
COMPOSE="docker compose -f docker-compose.cluster.yml"
PASS=0; FAIL=0

# Report: record each result into a manifest, rendered to HTML at the end.
RUN="$ROOT/../runtime/e2e/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN"; MANIFEST="$RUN/manifest.jsonl"
jesc(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
rec(){ printf '{"status":"%s","title":"%s"}\n' "$1" "$(jesc "$2")" >> "$MANIFEST"; }
ok(){   echo "  PASS: $1"; PASS=$((PASS+1)); rec pass "$1"; }
ng(){   echo "  FAIL: $1"; FAIL=$((FAIL+1)); rec fail "$1"; }
info(){ echo "  INFO: $1"; rec info "$1"; }

cleanup(){ [ "$KEEP" -eq 1 ] || (cd "$ROOT/.." && $COMPOSE down >/dev/null 2>&1 || true); }
trap cleanup EXIT

last_hash(){ grep -o '"Hash":"[^"]*"' | tail -1 | sed 's/.*:"//;s/"//'; }
ctype(){ curl -fsSI "$1" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print $2}'; }

cd "$ROOT/.."

echo "==> 0. prereq check"
[ -f .env ] && grep -q CLUSTER_SECRET .env || { echo "missing .env(CLUSTER_SECRET), see docs/SINGLE_HOST_DEPLOYMENT.md"; exit 1; }
[ -f runtime/private/swarm.key ] || { echo "missing runtime/private/swarm.key, see docs/SINGLE_HOST_DEPLOYMENT.md"; exit 1; }

echo "==> 1. start 3-node cluster"
$COMPOSE up -d

echo "==> 2. wait for cluster proxy"
for i in $(seq 1 150); do
  curl -fsS -X POST "$PROXY/api/v0/version" >/dev/null 2>&1 && break
  sleep 1
  [ "$i" -eq 150 ] && { echo "cluster proxy not ready"; exit 1; }
done

echo "==> 3. wait for all 3 peers to join"
for i in $(seq 1 60); do
  n=$(docker exec cl-cluster0 ipfs-cluster-ctl --enc=json peers ls 2>/dev/null | grep -o '"peername"' | wc -l | tr -d ' ' || true)
  [ "${n:-0}" -ge 3 ] && break
  sleep 1
  [ "$i" -eq 60 ] && { echo "fewer than 3 peers (got ${n:-0})"; docker exec cl-cluster0 ipfs-cluster-ctl peers ls || true; exit 1; }
done
ok "cluster peers = $n"

echo "==> 4. prepare fixture"
mkdir -p "$FIX"
cat > "$FIX/standalone.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><title>cluster</title>
<style>body{color:#06c}</style></head>
<body><h1 id="marker">HELLO_CLUSTER_E2E</h1></body></html>
HTML

echo "==> Case 1: upload via cluster proxy (should auto-replicate)"
CID=$(curl -fsS -F "file=@$FIX/standalone.html" "$PROXY/api/v0/add?cid-version=1&pin=true" | last_hash)
info "上传成功 CID=$CID"

echo "==> Case 2: replicas = 3 (PINNED on all nodes)"
for i in $(seq 1 60); do
  pinned=$(docker exec cl-cluster0 ipfs-cluster-ctl status "$CID" 2>/dev/null | grep -c PINNED || true)
  [ "${pinned:-0}" -ge 3 ] && break
  sleep 1
done
[ "${pinned:-0}" -ge 3 ] && ok "replicas=${pinned} (=3)" || ng "replicas=${pinned:-0} (want 3)"

echo "==> Case 3: gateway renders"
CT=$(ctype "$GW/ipfs/$CID")
echo "$CT" | grep -qi 'text/html' && ok "Content-Type=$CT" || ng "Content-Type=$CT"
curl -fsS "$GW/ipfs/$CID" | grep -q 'HELLO_CLUSTER_E2E' && ok "body readable" || ng "body"

echo "==> Case 3b: manual GC does not remove pinned content"
docker exec cl-ipfs0 ipfs repo gc >/dev/null 2>&1 || true
code=$(curl -s -o /dev/null -w '%{http_code}' "$GW/ipfs/$CID")
[ "$code" = "200" ] && ok "pinned content survives ipfs repo gc" || ng "pinned content gone after gc (code=$code)"

echo "==> Case 4: /artifact path rewrite via Caddy (:8088)"
for i in $(seq 1 30); do curl -fsS "$ART/artifact/$CID" >/dev/null 2>&1 && break; sleep 1; done
CTA=$(ctype "$ART/artifact/$CID")
echo "$CTA" | grep -qi 'text/html' && ok "artifact Content-Type=$CTA" || ng "artifact Content-Type=$CTA"
curl -fsS "$ART/artifact/$CID" | grep -q 'HELLO_CLUSTER_E2E' && ok "artifact body readable" || ng "artifact body"

echo "==> Case 5: fault tolerance -- stop ipfs1, still readable via ipfs0 gateway"
docker stop cl-ipfs1 >/dev/null
code=$(curl -s -o /dev/null -w '%{http_code}' "$GW/ipfs/$CID")
[ "$code" = "200" ] && ok "gateway still 200 after stopping 1 node" || ng "code=$code after stopping 1 node"
# 经 Caddy /artifact 连续读全 200：验证 LB 被动摘除+重试确实生效（6 次覆盖 3 上游轮询两圈）
artok=1
for _ in $(seq 1 6); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$ART/artifact/$CID")
  [ "$code" = "200" ] || { artok=0; break; }
done
[ "$artok" = 1 ] && ok "/artifact still 200 x6 via Caddy after stopping 1 node" \
                 || ng "/artifact returned $code via Caddy after stopping 1 node"
docker start cl-ipfs1 >/dev/null

echo "==> summary: PASS=$PASS FAIL=$FAIL"
python3 "$ROOT/report.py" "$RUN" 2>/dev/null && echo "==> report: $RUN/report.html" || echo "==> report skipped (python3 unavailable)"
[ "$FAIL" -eq 0 ]
