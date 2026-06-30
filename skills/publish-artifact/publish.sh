#!/usr/bin/env bash
# Publish an HTML file or a directory (multi-asset site) to a private IPFS Cluster
# and print one shareable, immutable link. Stateless: each publish is a new CID.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: publish.sh [--permanent] [--expire-in <dur>] [--verify] <file.html | dir/>
  --permanent      keep forever (omit the default 1-week expiry); use sparingly
  --expire-in DUR  override expiry (default 168h), e.g. 24h, 720h
  --verify         after publishing, GET the link and print its HTTP status
Env (required): IPFS_PUBLISH_ENDPOINT, IPFS_PUBLISH_TOKEN, IPFS_BASE_URL
EOF
  exit 2
}

EXPIRE="168h"; PERMANENT=0; VERIFY=0; TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --permanent) PERMANENT=1; shift ;;
    --expire-in) EXPIRE="${2:?--expire-in needs a value}"; shift 2 ;;
    --verify)    VERIFY=1; shift ;;
    -h|--help)   usage ;;
    -*)          echo "unknown option: $1" >&2; usage ;;
    *)           TARGET="$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || usage
[ -e "$TARGET" ] || { echo "error: not found: $TARGET" >&2; exit 1; }

# Required configuration (fail loudly, never silently succeed).
: "${IPFS_PUBLISH_ENDPOINT:?set IPFS_PUBLISH_ENDPOINT (token write ingress, e.g. https://host:9097)}"
: "${IPFS_PUBLISH_TOKEN:?set IPFS_PUBLISH_TOKEN (bearer token for the write ingress)}"
: "${IPFS_BASE_URL:?set IPFS_BASE_URL (read gateway base, e.g. https://host:8088)}"

Q="cid-version=1"
[ "$PERMANENT" -eq 1 ] || Q="$Q&expire-in=$EXPIRE"
ADD_URL="${IPFS_PUBLISH_ENDPOINT%/}/add"
AUTH="Authorization: Bearer $IPFS_PUBLISH_TOKEN"

if [ -d "$TARGET" ]; then
  # Directory: each file as a part whose filename is the path relative to the site root.
  Q="$Q&wrap-with-directory=true"
  [ -e "$TARGET/index.html" ] || echo "warn: no index.html at root; link will show a directory listing" >&2
  args=()
  while IFS= read -r -d '' f; do
    rel="${f#"$TARGET"/}"
    args+=(-F "file=@$f;filename=$rel")
  done < <(find "$TARGET" -type f -print0)
  resp=$(curl -fsS -H "$AUTH" -X POST "${args[@]}" "$ADD_URL?$Q")
  # The wrap root is the JSON line with an empty name.
  cid=$(printf '%s\n' "$resp" | grep '"name":""' | grep -o '"cid":"[^"]*"' | head -1 | sed 's/.*:"//;s/"//')
  link="${IPFS_BASE_URL%/}/artifact/$cid/"
else
  base=$(basename "$TARGET")
  resp=$(curl -fsS -H "$AUTH" -X POST -F "file=@$TARGET;filename=$base" "$ADD_URL?$Q")
  cid=$(printf '%s\n' "$resp" | grep -o '"cid":"[^"]*"' | head -1 | sed 's/.*:"//;s/"//')
  link="${IPFS_BASE_URL%/}/artifact/$cid"
fi

[ -n "$cid" ] || { echo "error: publish failed; response: $resp" >&2; exit 1; }

if [ "$VERIFY" -eq 1 ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' "$link")
  echo "verify: GET $link -> $code" >&2
fi

echo "$link"
