#!/usr/bin/env bash
# List (and with --delete, remove) local branches whose content is already in
# main. Squash merges make `git branch -d` refuse every merged branch, so the
# check is by content: a branch is prunable when none of the lines it adds on
# the files it touched are missing from main. Branches with content main does
# not have are listed as KEEP with the number of such lines, never deleted.
#
# Usage: scripts/prune_merged_branches.sh [--delete]
#   without --delete: dry run, prints PRUNE / KEEP per branch
#   --delete: deletes the PRUNE branches (git branch -D) after fetch --prune
#
# Run it from main after `git pull --ff-only`; it never touches main, the
# current branch, or remote branches (the remote deletes a head branch on
# merge by itself).
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

delete=0
[[ "${1:-}" == "--delete" ]] && delete=1

git fetch --prune --quiet origin
current="$(git branch --show-current)"

prune=()
while IFS= read -r branch; do
    [[ -z "$branch" || "$branch" == "main" || "$branch" == "$current" ]] && continue
    base="$(git merge-base main "$branch")"
    files="$(git diff --name-only "$base" "$branch")"
    if [[ -z "$files" ]]; then
        extra=0
    else
        # shellcheck disable=SC2086
        extra="$(git diff main "$branch" -- $files | grep -c '^+[^+]' || true)"
    fi
    if [[ "$extra" == "0" ]]; then
        echo "PRUNE  $branch  ($(git rev-parse --short "$branch"), content is in main)"
        prune+=("$branch")
    else
        echo "KEEP   $branch  ($(git rev-parse --short "$branch"), $extra line(s) not in main)"
    fi
done < <(git for-each-ref --format='%(refname:short)' refs/heads/)

if (( delete == 1 && ${#prune[@]} > 0 )); then
    git branch -D "${prune[@]}"
elif (( delete == 0 && ${#prune[@]} > 0 )); then
    echo "dry run: rerun with --delete to remove the PRUNE branches"
fi
