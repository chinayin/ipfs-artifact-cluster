#!/usr/bin/env bash
# publish-artifact: publish an HTML file or a directory (multi-asset site) to a
# private IPFS Cluster and print an immutable, shareable link.
# Pure bash + curl. No python, no jq. Config via 3 env vars (see --help).
set -euo pipefail

VERSION="1.0.0"
# exit codes: 0 ok | 1 publish failed | 2 not configured | 3 usage | 4 target missing | 5 dependency

usage() {
  cat >&2 <<'EOF'
publish-artifact - publish HTML to a private IPFS Cluster, get an immutable link.

Usage: publish.sh [options] <file.html | dir/>

Options:
  --json            print a JSON object instead of just the link
  --expire-in DUR   auto-unpin after DUR (default 168h); e.g. 24h, 720h
  --permanent       keep forever (omit expiry); use sparingly
  --verify          after publishing, GET the link and report status (stderr)
  --dry-run         validate config + target and print the planned request; no upload
  --version         print version and exit
  -h, --help        show this help and exit

Configuration (3 environment variables):
  IPFS_PUBLISH_ENDPOINT   token write ingress, e.g. https://pages-publish.example.com
                          (internal / same host: http://127.0.0.1:9097)
  IPFS_PUBLISH_TOKEN      Bearer token for the write ingress (ask your cluster operator)
  IPFS_BASE_URL           read/share base, e.g. https://pages.example.com
EOF
}

onboarding() {
  cat >&2 <<'EOF'
publish-artifact is not configured. Set these 3 environment variables:

  export IPFS_PUBLISH_ENDPOINT="https://pages-publish.example.com"  # token write ingress
  export IPFS_PUBLISH_TOKEN="<ask your cluster operator>"           # Bearer token
  export IPFS_BASE_URL="https://pages.example.com"                  # read/share base

  # internal / same-host agents may use the loopback ingress instead:
  # export IPFS_PUBLISH_ENDPOINT="http://127.0.0.1:9097"

To persist, add the exports to your shell profile (~/.zshrc or ~/.bashrc),
then open a new shell. Verify with:  publish.sh --help
EOF
}

die() { echo "error: $1" >&2; exit "${2:-1}"; }

# require bash (arrays, read -d)
[ -n "${BASH_VERSION:-}" ] || { echo "error: run with bash, not sh (bash arrays required)" >&2; exit 5; }

# parse args (--help/--version need no config)
JSON=0; PERMANENT=0; VERIFY=0; DRYRUN=0; EXPIRE="168h"; TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json)      JSON=1; shift ;;
    --permanent) PERMANENT=1; shift ;;
    --expire-in) { [ $# -ge 2 ] && [ -n "$2" ]; } || die "--expire-in needs a non-empty value" 3; EXPIRE="$2"; shift 2 ;;
    --verify)    VERIFY=1; shift ;;
    --dry-run)   DRYRUN=1; shift ;;
    --version)   echo "publish-artifact $VERSION"; exit 0 ;;
    -h|--help)   usage; exit 0 ;;
    --)          shift
                while [ $# -gt 0 ]; do
                  [ -z "$TARGET" ] || die "only one target allowed" 3
                  TARGET="$1"; shift
                done
                break ;;
    -*)          echo "error: unknown option: $1" >&2; usage; exit 3 ;;
    *)           [ -z "$TARGET" ] || die "only one target allowed" 3; TARGET="$1"; shift ;;
  esac
done

# dependency check
command -v curl >/dev/null 2>&1 || { echo "error: curl not found (required)" >&2; exit 5; }

# config check (friendly onboarding, not a bare error)
if [ -z "${IPFS_PUBLISH_ENDPOINT:-}" ] || [ -z "${IPFS_PUBLISH_TOKEN:-}" ] || [ -z "${IPFS_BASE_URL:-}" ]; then
  onboarding; exit 2
fi

# target check
[ -n "$TARGET" ] || { echo "error: no target given" >&2; usage; exit 3; }
[ -e "$TARGET" ] || die "target not found: $TARGET" 4
TARGET="${TARGET%/}"

ENDPOINT="${IPFS_PUBLISH_ENDPOINT%/}"
BASE="${IPFS_BASE_URL%/}"
ADD_URL="$ENDPOINT/add"
Q="cid-version=1"
[ "$PERMANENT" -eq 1 ] || Q="$Q&expire-in=$EXPIRE"

# build curl form args + determine kind
form=()
if [ -d "$TARGET" ]; then
  KIND=dir
  Q="$Q&wrap-with-directory=true"
  [ -e "$TARGET/index.html" ] || echo "warn: no index.html at directory root; link will show a listing" >&2
  nfiles=0
  while IFS= read -r -d '' f; do
    rel="${f#"$TARGET"/}"
    form+=(-F "file=@$f;filename=$rel")
    nfiles=$((nfiles+1))
  done < <(find "$TARGET" -type f -print0)
  [ "$nfiles" -gt 0 ] || die "directory has no files: $TARGET" 4
else
  KIND=file
  form+=(-F "file=@$TARGET;filename=$(basename "$TARGET")")
  nfiles=1
fi

# dry-run: validate + preview, no upload
if [ "$DRYRUN" -eq 1 ]; then
  {
    echo "dry-run (no upload):"
    echo "  request : POST $ADD_URL?$Q"
    echo "  kind    : $KIND"
    echo "  files   : $nfiles"
    echo "  expires : $([ "$PERMANENT" -eq 1 ] && echo permanent || echo "$EXPIRE")"
  } >&2
  exit 0
fi

# guard: form must be non-empty (should always hold after target checks above)
[ "${#form[@]}" -gt 0 ] || die "internal error: nothing to upload" 1

# upload with retry (transient failures only)
AUTH="Authorization: Bearer $IPFS_PUBLISH_TOKEN"
attempt=0
while :; do
  attempt=$((attempt+1))
  resp=$(curl -s -H "$AUTH" -X POST "${form[@]}" -w $'\n%{http_code}' "$ADD_URL?$Q" 2>/dev/null) && rc=0 || rc=$?
  http=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')
  if [ "$rc" -eq 0 ] && printf '%s' "$http" | grep -q '^2'; then break; fi
  if printf '%s' "$http" | grep -qE '^4'; then
    echo "error: publish rejected (HTTP $http): $body" >&2; exit 1
  fi
  if [ "$attempt" -ge 3 ]; then
    echo "error: publish failed after $attempt attempts (HTTP ${http:-none}, curl rc $rc): $body" >&2; exit 1
  fi
  sleep $((2 ** (attempt - 1)))
done

# parse cid (whitespace-tolerant); dir -> the wrap-root line (name == "")
if [ "$KIND" = dir ]; then
  cid=$(printf '%s' "$body" | grep -E '"name":[[:space:]]*""' | grep -oE '"cid":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  link="$BASE/artifact/$cid/"
else
  cid=$(printf '%s' "$body" | grep -oE '"cid":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  link="$BASE/artifact/$cid"
fi
[ -n "$cid" ] || die "could not parse CID from response: $body" 1

# optional verify
if [ "$VERIFY" -eq 1 ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' "$link" || true)
  echo "verify: GET $link -> $code" >&2
fi

# output
if [ "$JSON" -eq 1 ]; then
  if [ "$PERMANENT" -eq 1 ]; then exp=null; else exp=$(printf '"%s"' "$EXPIRE"); fi
  printf '{"cid":"%s","link":"%s","kind":"%s","expires_in":%s}\n' "$cid" "$link" "$KIND" "$exp"
else
  echo "$link"
fi
