#!/usr/bin/env bash

set -u

ROOT="${1:-$(pwd)}"

echo "Scanning Git repositories under:"
echo "  $ROOT"
echo

find "$ROOT" -mindepth 1 -maxdepth 2 -type d -name .git -print0 |
while IFS= read -r -d '' gitdir; do
    repo="$(dirname "$gitdir")"

    echo "============================================================"
    echo "Repository: $repo"
    echo "============================================================"

    cd "$repo" || {
        echo "SKIP: cannot enter repository"
        echo
        continue
    }

    # Do not touch repositories with uncommitted work.
    if ! git diff --quiet || \
       ! git diff --cached --quiet || \
       [ -n "$(git ls-files --others --exclude-standard)" ]; then
        echo "SKIP: working tree is not clean."
        git status --short
        echo
        continue
    fi

    # This project convention uses main.
    if ! git show-ref --verify --quiet refs/heads/main; then
        echo "SKIP: no local 'main' branch."
        echo
        continue
    fi

    current_branch="$(git branch --show-current)"

    if [ "$current_branch" != "main" ]; then
        echo "Switching: $current_branch -> main"

        if ! git switch main; then
            echo "SKIP: could not switch to main."
            echo
            continue
        fi
    fi

    echo "Pruning stale remote-tracking references..."
    git fetch --prune >/dev/null 2>&1 || \
        echo "WARNING: fetch --prune failed; continuing with local data."

    merged_branches="$(
        git for-each-ref \
            --format='%(refname:short)' \
            --merged=refs/heads/main \
            refs/heads/ |
        grep -vE '^(main|master)$' || true
    )"

    if [ -z "$merged_branches" ]; then
        echo "No merged local branches to delete."
        echo
        continue
    fi

    echo
    echo "Deleting merged local branches:"
    echo "$merged_branches" | sed 's/^/  - /'
    echo

    while IFS= read -r branch; do
        [ -z "$branch" ] && continue

        # Safe delete only. Git refuses if it considers the branch unmerged.
        if git branch -d "$branch"; then
            :
        else
            echo "WARNING: Git refused to delete '$branch'. Leaving it untouched."
        fi
    done <<< "$merged_branches"

    echo
    echo "Remaining local branches:"
    git --no-pager branch
    echo
done

echo "============================================================"
echo "Cleanup complete."
echo "Remote branches were NOT deleted."
echo "Unmerged branches were NOT deleted."
echo "Dirty repositories were NOT modified."
echo "============================================================"