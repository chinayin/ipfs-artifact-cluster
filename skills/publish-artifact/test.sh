#!/usr/bin/env bash
# Self-test for the publish-artifact skill.
# Inside the cluster repo, delegate to the centralized publish e2e (e2e/run-publish.sh),
# which also brings the stack up and writes an HTML report. When the skill is installed
# standalone (no repo), fall back to a minimal smoke against an already-running deployment.
# Standalone smoke requires the 3 env vars and an up endpoint.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FULL="$HERE/../../e2e/run-publish.sh"
if [ -x "$FULL" ]; then
  exec "$FULL" "$@"
fi

# --- standalone minimal smoke (skill installed outside the cluster repo) ---
: "${IPFS_PUBLISH_ENDPOINT:?set IPFS_PUBLISH_ENDPOINT}"
: "${IPFS_PUBLISH_TOKEN:?set IPFS_PUBLISH_TOKEN}"
: "${IPFS_BASE_URL:?set IPFS_BASE_URL}"
PUB="$HERE/publish.sh"
PASS=0; FAIL=0
trap 'echo "PASS=$PASS FAIL=$FAIL"' EXIT
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
ng(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

tmp=$(mktemp -d)
printf '<!doctype html><meta charset=utf-8><h1>SMOKE_OK</h1>\n' > "$tmp/page.html"
link=$("$PUB" "$tmp/page.html")
echo "single link: $link"
body=$(curl -fsS "$link" || true)
case "$body" in *SMOKE_OK*) ok "single-file renders";; *) ng "single-file renders (got: $body)";; esac

mkdir -p "$tmp/site/css"
printf '<!doctype html><meta charset=utf-8><link rel=stylesheet href="./css/app.css"><h1>SMOKE_DIR</h1>\n' > "$tmp/site/index.html"
printf 'h1{color:green}\n' > "$tmp/site/css/app.css"
dlink=$("$PUB" "$tmp/site")
echo "dir link: $dlink"
ix=$(curl -fsS -o /dev/null -w '%{http_code}' "${dlink}index.html")
[ "$ix" = 200 ] && ok "dir index 200" || ng "dir index ($ix)"

rm -rf "$tmp"
[ "$FAIL" -eq 0 ]
