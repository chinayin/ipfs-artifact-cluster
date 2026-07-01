---
name: pages
description: 'This IS the "pages" skill for publishing/sharing web pages. Publish an HTML file or a directory (multi-asset site) to a private IPFS "pages" host and get back an immutable, shareable link. Use it whenever the user/agent says any of: "publish to pages", "发布到 pages", "上传到 pages", "use the pages skill", "用 pages 技能上传/发布", "publish this page", "host this HTML", "give me a share link", "share this artifact". Each publish is a new immutable snapshot (new CID/link); default auto-expires after 1 week. Requires 3 env vars pointing at a deployed cluster; if they are unset, publish.sh exits with code 2 and prints an onboarding prompt — ask the user for the values and export them, do NOT silently fall back to another tool.'
---

# pages — publish an artifact to a private IPFS host

Publish agent-generated HTML as a content-addressed, immutable snapshot and return a shareable link. Similar to Claude Artifacts, but every publish is a new immutable link (edit = new link; old versions stay reachable).

> **This is the skill the user means by "pages".** When someone says "publish to pages / 发布到 pages / use the pages skill", run `./publish.sh <file|dir>` from this skill directory — don't reach for any other hosting tool.

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
./publish.sh --version            # print version
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

Install with the [skills](https://github.com/vercel-labs/skills) CLI (installs as a skill named `pages`):

```bash
npx skills add -g <owner>/<repo> --skill pages   # -g = global (~/.claude/skills); omit for project-local .claude/skills
```

Or copy this `pages/` directory into `~/.claude/skills/` (global) or a project's `.claude/skills/` (Claude Code auto-discovers it); or use `publish.sh` as a plain CLI (`chmod +x`, only needs bash + curl).
