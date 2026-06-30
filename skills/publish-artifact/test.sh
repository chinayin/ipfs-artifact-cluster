#!/usr/bin/env bash
# e2e for publish.sh: single file and directory publishing render over the gateway.
# Requires a running cluster + write ingress (Task 1) and the 3 env vars set.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PUB="$HERE/publish.sh"
PASS=0; FAIL=0
trap 'echo "PASS=$PASS FAIL=$FAIL"' EXIT
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
ng(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# --- single file ---
tmp=$(mktemp -d)
printf '<!doctype html><meta charset=utf-8><h1>SINGLE_OK</h1>\n' > "$tmp/page.html"
link=$($PUB "$tmp/page.html")
echo "single link: $link"
body=$(curl -fsS "$link" || true)
case "$body" in *SINGLE_OK*) ok "single-file renders";; *) ng "single-file renders (got: $body)";; esac

# --- directory with relative asset ---
mkdir -p "$tmp/site/css"
printf '<!doctype html><meta charset=utf-8><link rel=stylesheet href="./css/app.css"><h1>DIR_OK</h1>\n' > "$tmp/site/index.html"
printf 'h1{color:green}\n' > "$tmp/site/css/app.css"
dlink=$($PUB "$tmp/site")
echo "dir link: $dlink"
ix=$(curl -fsS -o /dev/null -w '%{http_code}' "${dlink}index.html")
cssc=$(curl -fsS -o /dev/null -w '%{http_code}' "${dlink}css/app.css")
[ "$ix" = 200 ] && ok "dir index 200" || ng "dir index ($ix)"
[ "$cssc" = 200 ] && ok "dir css 200" || ng "dir css ($cssc)"

rm -rf "$tmp"
[ "$FAIL" -eq 0 ]
