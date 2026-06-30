#!/usr/bin/env bash
# Self-contained smoke test for the publish-artifact skill.
# Independent by design: needs only publish.sh (next to this file) + the 3 env vars
# + a reachable deployment. No repo modules, no docker/cluster introspection.
# Publishes a single file and a directory, then checks both render over the gateway.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PUB="$HERE/publish.sh"

: "${IPFS_PUBLISH_ENDPOINT:?set IPFS_PUBLISH_ENDPOINT}"
: "${IPFS_PUBLISH_TOKEN:?set IPFS_PUBLISH_TOKEN}"
: "${IPFS_BASE_URL:?set IPFS_BASE_URL}"

PASS=0; FAIL=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; echo "PASS=$PASS FAIL=$FAIL"' EXIT
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
ng(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }
# Poll a URL until it serves 200 (replication across gateways is asynchronous).
get200(){ for _ in $(seq 1 20); do [ "$(curl -s -o /dev/null -w '%{http_code}' "$1")" = "200" ] && return 0; sleep 1; done; return 1; }

# single file -> link renders with its marker
printf '<!doctype html><meta charset=utf-8><h1>SMOKE_OK</h1>\n' > "$tmp/page.html"
link=$("$PUB" "$tmp/page.html")
echo "single: $link"
{ get200 "$link" && curl -fsS "$link" 2>/dev/null | grep -q 'SMOKE_OK'; } && ok "single-file renders" || ng "single-file renders"

# directory (relative asset) -> index + css render
mkdir -p "$tmp/site/css"
printf '<!doctype html><meta charset=utf-8><link rel=stylesheet href="./css/app.css"><h1>SMOKE_DIR</h1>\n' > "$tmp/site/index.html"
printf 'h1{color:green}\n' > "$tmp/site/css/app.css"
dlink=$("$PUB" "$tmp/site")
echo "dir: $dlink"
get200 "${dlink}index.html" && ok "dir index 200" || ng "dir index"
get200 "${dlink}css/app.css" && ok "dir css 200" || ng "dir css"

[ "$FAIL" -eq 0 ]
