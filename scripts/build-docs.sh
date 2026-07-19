#!/usr/bin/env bash
#
# build-docs.sh — render the docs site with Blume (the presentation layer).
#
# The committed Markdown under docs/ is the source of truth; Blume only renders
# and searches it. This script is OPTIONAL — docs are valid without a Blume
# build. Use it to preview the published docs site locally or to verify a
# production render before deploy.
#
# Requires Node.js 22.12+. First run will `npm install` the pinned Blume version
# (see package.json). Generated output lands in dist/ (gitignored).
#
# Usage:
#   bash scripts/build-docs.sh          # install (if needed) + build -> dist/
#   bash scripts/build-docs.sh --check  # also run `blume check` (typecheck)
#   bash scripts/build-docs.sh --validate  # also run `blume validate` (links)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [ ! -d node_modules/blume ]; then
  echo ">> installing Blume (pinned in package.json)…"
  npm install
fi

EXTRA=()
for arg in "$@"; do
  case "$arg" in
    --check)    EXTRA+=(check) ;;
    --validate) EXTRA+=(validate) ;;
  esac
done

echo ">> blume build"
npx blume build

for step in "${EXTRA[@]:-}"; do
  echo ">> blume $step"
  npx blume "$step"
done

echo ">> docs site built -> dist/"
