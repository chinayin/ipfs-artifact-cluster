---
name: publish-artifact
description: Publish an HTML file or a directory (multi-asset site) to a private IPFS Cluster and get back an immutable, shareable link. Use when the user/agent says things like "publish this page / publish to pages / 发布到 pages / give me a share link / host this HTML / host this artifact". Each publish is a new immutable snapshot (new CID/link); default auto-expires after 1 week. Requires 3 env vars pointing at a deployed cluster; guide the user to set them on first use.
---

# Publish Artifact to a private IPFS Cluster

Publish agent-generated HTML as a content-addressed, immutable snapshot and return a shareable link. Similar to Claude Artifacts, but every publish is a new immutable link (edit = new link; old versions stay reachable).

Pure `bash` + `curl` — no python, no jq. Ships as three files: `publish.sh`, `test.sh`, `SKILL.md`.

## First run / configuration

The tool needs 3 environment variables:

- `IPFS_PUBLISH_ENDPOINT` — token write ingress, e.g. `https://pages-publish.example.com` (internal/same host: `http://127.0.0.1:9097`)
- `IPFS_PUBLISH_TOKEN` — Bearer token for the write ingress (ask the cluster operator)
- `IPFS_BASE_URL` — read/share base, e.g. `https://pages.example.com`

**If `publish.sh` exits with code 2 ("not configured"), do NOT just fail.** Ask the user for these three values, then set them for the session:

```bash
export IPFS_PUBLISH_ENDPOINT="…"
export IPFS_PUBLISH_TOKEN="…"
export IPFS_BASE_URL="…"
```

Tell the user they can persist these by adding the exports to `~/.zshrc` or `~/.bashrc`. Then retry the publish.

## Usage

```bash
./publish.sh page.html            # single file -> https://pages.example.com/artifact/<cid>
./publish.sh ./site               # directory (index.html + relative assets) -> …/artifact/<dirCID>/
./publish.sh --json page.html     # JSON: {"cid","link","kind","expires_in"}
./publish.sh --expire-in 24h x.html
./publish.sh --permanent x.html   # no expiry (use sparingly)
./publish.sh --verify x.html      # GET the link after publishing (status to stderr)
./publish.sh --dry-run ./site     # validate + preview the request, no upload
./publish.sh --help
```

Default stdout is a single link line (easy to capture); `--json` prints one JSON object; diagnostics go to stderr.

## Behavior & constraints

- **Immutable snapshots**: each publish is a new CID/link; no in-place update.
- **Default 1-week expiry**: auto-unpinned after `--expire-in` (default 168h); `--permanent` keeps it forever (use sparingly).
- **Directory**: files are added with paths relative to the directory root + `wrap-with-directory`; the root should contain `index.html` (else the link shows a listing).
- **No delete**: the tool does not unpublish (no ownership model); cleanup is via expiry or an operator using `ipfs-cluster-ctl`.
- **CIDv1** enforced.

## Edge cases

- Requires **bash** (not `sh`) and **curl**; exits 5 if missing.
- Symlinked files inside a directory are skipped (`find -type f`).
- Very large directories (thousands of files) may hit the OS argument-length limit.
- For external publishing use the HTTPS write ingress (token stays encrypted in transit); avoid plain `http://<ip>:9097` over the public internet.

## Self-test

```bash
# needs the 3 env vars set + a reachable deployment
./test.sh
```

## Install / distribute

Copy this `publish-artifact/` directory into the user's `~/.claude/skills/` or a project's `skills/` (Claude Code auto-discovers it); or use `publish.sh` as a plain CLI (`chmod +x`, only needs bash + curl).
