#!/usr/bin/env bash
# Self-contained behavior test for the publish-artifact skill.
# Pure bash + curl (no python, no jq). NOTE: intentionally no `set -e`
# so that assertions on non-zero exits work.
# Requires: the 3 env vars set + a reachable deployment (for publish assertions).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PUB="$HERE/publish.sh"
PASS=0; FAIL=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; echo "PASS=$PASS FAIL=$FAIL"' EXIT
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
ng(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }
# Poll a URL until it serves 200 (replication across gateways is asynchronous).
get200(){ for _ in $(seq 1 20); do [ "$(curl -s -o /dev/null -w '%{http_code}' "$1")" = "200" ] && return 0; sleep 1; done; return 1; }

# 5) missing config -> exit 2 + onboarding (needs no cluster; run first)
out=$(env -u IPFS_PUBLISH_TOKEN "$PUB" "$tmp/none.html" 2>&1); rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'not configured'; then ok "missing config -> exit 2 + onboarding"; else ng "missing config (rc=$rc)"; fi

# remaining assertions need config + reachable deployment
: "${IPFS_PUBLISH_ENDPOINT:?set IPFS_PUBLISH_ENDPOINT}"
: "${IPFS_PUBLISH_TOKEN:?set IPFS_PUBLISH_TOKEN}"
: "${IPFS_BASE_URL:?set IPFS_BASE_URL}"

# 4) --dry-run exits 0 and does not upload
printf '<!doctype html><meta charset=utf-8><h1>DRY</h1>' > "$tmp/dry.html"
out=$("$PUB" --dry-run "$tmp/dry.html" 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'dry-run'; then ok "--dry-run exits 0, no upload"; else ng "--dry-run (rc=$rc)"; fi

# 1) single file publishes and renders
printf '<!doctype html><meta charset=utf-8><h1>SMOKE_OK</h1>' > "$tmp/page.html"
link=$("$PUB" "$tmp/page.html")
if get200 "$link" && curl -fsS "$link" 2>/dev/null | grep -q 'SMOKE_OK'; then ok "single-file renders"; else ng "single-file renders (link=$link)"; fi

# 3) --json contains cid + link
j=$("$PUB" --json "$tmp/page.html")
if printf '%s' "$j" | grep -q '"cid"' && printf '%s' "$j" | grep -q '"link"'; then ok "--json has cid+link"; else ng "--json ($j)"; fi

# 2) directory (relative asset) renders
mkdir -p "$tmp/site/css"
printf '<!doctype html><meta charset=utf-8><link rel=stylesheet href="./css/app.css"><h1>SMOKE_DIR</h1>' > "$tmp/site/index.html"
printf 'h1{color:green}' > "$tmp/site/css/app.css"
dlink=$("$PUB" "$tmp/site")
if get200 "${dlink}index.html" && get200 "${dlink}css/app.css"; then ok "dir index+css render"; else ng "dir render (dlink=$dlink)"; fi

[ "$FAIL" -eq 0 ]
