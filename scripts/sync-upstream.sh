#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
PROJECT_ROOT=$(CDPATH= cd -P "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)
LWIP_DIR="$PROJECT_ROOT/upstream/lwip"

command -v git >/dev/null 2>&1 || { printf '%s\n' 'git is required.' >&2; exit 127; }

if ! repo_root=$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null); then
    printf '%s\n' 'Parent Git repository is not initialized. Run scripts/bootstrap-repository.sh first.' >&2
    exit 2
fi
if [ "$repo_root" != "$PROJECT_ROOT" ]; then
    printf 'Expected repository root: %s\n' "$PROJECT_ROOT" >&2
    printf 'Detected repository root: %s\n' "$repo_root" >&2
    exit 2
fi

if ! git -C "$LWIP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$PROJECT_ROOT" submodule update --init -- upstream/lwip
fi

if [ -n "$(git -C "$LWIP_DIR" status --porcelain --untracked-files=no)" ]; then
    printf '%s\n' 'Tracked changes exist in upstream/lwip; refusing to update.' >&2
    git -C "$LWIP_DIR" status --short >&2
    exit 3
fi

git -C "$LWIP_DIR" fetch origin master

branch=$(git -C "$LWIP_DIR" branch --show-current)
if [ -z "$branch" ]; then
    if git -C "$LWIP_DIR" show-ref --verify --quiet refs/heads/master; then
        git -C "$LWIP_DIR" switch master
    else
        git -C "$LWIP_DIR" switch -c master --track origin/master
    fi
elif [ "$branch" != master ]; then
    printf 'Submodule is on branch %s, expected master.\n' "$branch" >&2
    exit 3
fi

local_sha=$(git -C "$LWIP_DIR" rev-parse HEAD)
remote_sha=$(git -C "$LWIP_DIR" rev-parse origin/master)
if [ "$local_sha" != "$remote_sha" ]; then
    if ! git -C "$LWIP_DIR" merge-base --is-ancestor "$local_sha" "$remote_sha"; then
        printf '%s\n' 'Local master is ahead of or diverged from origin/master; refusing to rewrite it.' >&2
        exit 3
    fi
    git -C "$LWIP_DIR" merge --ff-only origin/master
fi

printf 'Branch: %s\n' "$(git -C "$LWIP_DIR" branch --show-current)"
printf 'HEAD:   %s\n' "$(git -C "$LWIP_DIR" rev-parse HEAD)"
printf '%s\n' 'Parent repository now records the submodule as a local change until you commit it.'
git -C "$PROJECT_ROOT" status --short -- upstream/lwip .gitmodules
