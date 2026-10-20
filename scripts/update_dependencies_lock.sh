#!/bin/bash
set -euo pipefail

# Rewrites dependencies.lock from the sibling checkouts next to this repo:
# each sibling is pinned to its current HEAD (full commit SHA). CI and the
# release workflow check out exactly these commits.
#
# Usage:
#   ./scripts/update_dependencies_lock.sh
#
# Commit and push the siblings first: CI can only fetch pushed commits, and
# uncommitted changes are not part of the pin.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$APP_REPO/.." && pwd)"
LOCK_FILE="$APP_REPO/dependencies.lock"
SIBLINGS=(PrizmX-Foundation PrizmX-Kit SwiftTCP)

tmp="$(mktemp "$LOCK_FILE.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

{
  echo "# Sibling repositories pinned for CI and release builds."
  echo "# Format: <repo>=<full commit SHA>. Regenerate with"
  echo "# scripts/update_dependencies_lock.sh; do not edit by hand."
} >"$tmp"

for repo in "${SIBLINGS[@]}"; do
  dir="$WORKSPACE_ROOT/$repo"
  if ! sha="$(git -C "$dir" rev-parse --verify HEAD 2>/dev/null)"; then
    echo "❌ Not a git checkout: $dir"
    exit 1
  fi
  if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then
    echo "⚠️  $repo has uncommitted changes; pinning HEAD without them."
  fi
  if [ -z "$(git -C "$dir" branch -r --contains "$sha" 2>/dev/null)" ]; then
    echo "⚠️  $repo $sha is not on any remote-tracking branch; push it before CI."
  fi
  echo "$repo=$sha" >>"$tmp"
  echo "▶ $repo=$sha"
done

chmod 644 "$tmp"
mv "$tmp" "$LOCK_FILE"
trap - EXIT
echo "✅ Wrote $LOCK_FILE"
