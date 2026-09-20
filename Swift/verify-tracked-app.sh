#!/bin/bash
# Does the Postit.app committed at the repo root still match the source here?
#
# The repo ships a built app so Code -> Download ZIP gives a double-clickable
# Postit. Plain ./build.sh deliberately leaves that copy alone, which means the
# tracked binary can fall behind Swift/main.swift with nothing to say so. This
# script is the thing that says so. `cd Swift && ./build.sh --ship` refreshes
# the app and rewrites SHIPPED.json together, which is what makes them agree.
#
# Exit 0 = the tracked app matches. Exit 1 = it is stale or unverifiable.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

FAIL=0
say() { printf '%s\n' "$*"; }
bad() { printf '  STALE: %s\n' "$*"; FAIL=1; }

[ -f SHIPPED.json ] || {
    say "No SHIPPED.json. The tracked app has no recorded provenance."
    say "Run: cd Swift && ./build.sh --ship"
    exit 1
}
[ -d Postit.app ] || { say "No Postit.app at the repo root."; exit 1; }

field() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" SHIPPED.json; }
COMMIT="$(field source_commit)"
RECORDED="$(field binary_sha256)"
VERSION="$(field version)"
DIRTY="$(sed -n 's/.*"worktree_dirty": *\([a-z]*\).*/\1/p' SHIPPED.json)"

say "Tracked Postit.app claims: $VERSION @ ${COMMIT:0:7}"

# 1. The bytes on disk must be the bytes that were recorded.
ACTUAL="$(shasum -a 256 Postit.app/Contents/MacOS/Postit | cut -d' ' -f1)"
[ "$ACTUAL" = "$RECORDED" ] || bad "binary digest differs from SHIPPED.json
         recorded ${RECORDED:0:16}...
         on disk  ${ACTUAL:0:16}..."

# 2. The source must not have moved on since that build.
if [ "$COMMIT" = unknown ] || ! git rev-parse --quiet --verify "$COMMIT^{commit}" >/dev/null 2>&1; then
    bad "source_commit $COMMIT is not a commit in this repo"
else
    BEHIND="$(git rev-list --count "$COMMIT..HEAD" -- Swift/main.swift)"
    [ "$BEHIND" -eq 0 ] || bad "Swift/main.swift has $BEHIND commit(s) since the app was built
         $(git diff --shortstat "$COMMIT..HEAD" -- Swift/main.swift)"
fi

# 3. Uncommitted source edits mean the app cannot match what a clone would get.
[ -z "$(git status --porcelain -- Swift/main.swift VERSION)" ] \
    || bad "Swift/main.swift or VERSION has uncommitted changes"

# 4. A build made from a dirty tree was never reproducible to begin with.
[ "$DIRTY" = true ] && bad "the app was built from a dirty worktree"

if [ "$FAIL" -eq 0 ]; then
    say "OK: the committed app matches this source."
else
    say ""
    say "Fix: cd Swift && ./build.sh --ship   (then commit Postit.app and SHIPPED.json)"
fi
exit "$FAIL"
