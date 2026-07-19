#!/usr/bin/env bash
#
# validate-docs.sh — check every Markdown link in the repo resolves to a real
# file. Markdown committed to docs/ is the source of truth, so a broken link is
# a real defect. Runs in CI (no network) and locally.
#
# What it checks:
#   - Every [text](target) link in .md/.mdx files (excluding generated/build
#     dirs and node_modules).
#   - Internal relative links (./, ../, /, and bare paths) and repo-root-
#     relative links (docs/...). Resolves with .md / .mdx fallback and
#     directory-index fallback.
#   - Anchor-only links (#section) are skipped (anchors aren't statically
#     verifiable without rendering).
#
# What it does NOT check:
#   - External URLs (http/https/mailto/pace://) — no network in CI.
#   - Plain text mentions of paths (e.g. `docs/foo.md` outside a link) —
#     those are prose, not navigable links.
#
# Exit code: 0 if all internal links resolve, 1 otherwise.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$REPO_ROOT" << 'PYEOF'
import os, re, sys

ROOT = sys.argv[1]
LINK_RE = re.compile(r'\[([^\]]*)\]\(([^)]+)\)')

# Dirs whose contents are generated, vendored, or out of scope for doc links.
EXCLUDE_DIRS = {
    ".git", "node_modules", ".blume", ".blume-verify", "dist", "build",
    "releases", ".astro", ".wrangler", ".claude",
}

# Known out-of-repo targets (fleet workspace siblings) that are valid relative
# references even though they don't live inside this repo. Match by basename.
ALLOW_OUT_OF_REPO = {"LANDING_STANDARD.md"}

def find_md_files():
    out = []
    for dp, dn, fn in os.walk(ROOT):
        parts = set(dp.split(os.sep))
        if parts & EXCLUDE_DIRS:
            continue
        for f in fn:
            if f.endswith((".md", ".mdx")):
                out.append(os.path.join(dp, f))
    return out

def resolve(ref_file, target):
    t = target.split("#")[0].split("?")[0]
    if t == "":
        return "ok"  # anchor-only
    if t.startswith(("http://", "https://", "mailto:", "pace://")):
        return "ok"  # external — not checked (no network in CI)
    if t.startswith("/"):
        cand = os.path.join(ROOT, t.lstrip("/"))
    else:
        cand = os.path.normpath(os.path.join(os.path.dirname(ref_file), t))
    for c in (cand, cand + ".md", cand + ".mdx"):
        if os.path.exists(c):
            return "ok"
    # directory index (e.g. docs/product/prds/ -> docs/product/prds/README.md)
    idx = os.path.join(cand, "README.md")
    if os.path.exists(idx):
        return "ok"
    # allow known out-of-repo fleet references by basename
    if os.path.basename(t) in ALLOW_OUT_OF_REPO:
        return "ok"
    return "BROKEN"

broken = []
for md in find_md_files():
    rel = os.path.relpath(md, ROOT)
    try:
        with open(md, encoding="utf-8") as fh:
            for i, line in enumerate(fh, 1):
                for m in LINK_RE.finditer(line):
                    status = resolve(md, m.group(2))
                    if status == "BROKEN":
                        broken.append((rel, i, m.group(2), line.strip()[:140]))
    except Exception as e:
        print(f"ERR reading {md}: {e}", file=sys.stderr)

if broken:
    print(f"\n  {len(broken)} broken internal link(s):\n", file=sys.stderr)
    for rel, i, target, line in broken:
        print(f"  {rel}:{i}  ->  {target}", file=sys.stderr)
        print(f"    {line}", file=sys.stderr)
    sys.exit(1)

print("  all internal markdown links resolve")
sys.exit(0)
PYEOF
