#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
PROJECT_ROOT=$(CDPATH= cd -P "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)
LWIP_DIR="$PROJECT_ROOT/upstream/lwip"
LWIP_UPSTREAM_URL=${LWIP_UPSTREAM_URL:-https://github.com/lwip-tcpip/lwip.git}

command -v git >/dev/null 2>&1 || {
    printf '%s\n' 'git is required.' >&2
    exit 127
}

if ! git -C "$PROJECT_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$PROJECT_ROOT" init -b main
fi

repo_root=$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel)
if [ "$repo_root" != "$PROJECT_ROOT" ]; then
    printf 'Expected repository root: %s\n' "$PROJECT_ROOT" >&2
    printf 'Detected repository root: %s\n' "$repo_root" >&2
    exit 2
fi

if git -C "$PROJECT_ROOT" ls-files --stage -- upstream/lwip |
    grep -q '^160000 '; then

    # Parent repository already records upstream/lwip as a submodule.
    git -C "$PROJECT_ROOT" submodule update --init -- upstream/lwip
else
    submodule_url=$LWIP_UPSTREAM_URL
    reuse_existing_clone=0

    # upstream/lwip may already contain a Git checkout. In that case, reuse it
    # instead of deleting/recloning it.
    if [ -d "$LWIP_DIR" ] &&
        [ -n "$(find "$LWIP_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then

        if git -C "$LWIP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            # Never hide or overwrite tracked local changes.
            if [ -n "$(git -C "$LWIP_DIR" status --porcelain --untracked-files=no)" ]; then
                printf '%s\n' \
                    'Tracked changes exist in the existing lwIP clone; refusing submodule migration.' >&2
                exit 3
            fi

            # Preserve the existing origin transport, e.g. HTTPS/SSH/mirror.
            submodule_url=$(git -C "$LWIP_DIR" remote get-url origin)
            reuse_existing_clone=1

            printf 'Adopting existing lwIP clone as submodule: %s\n' \
                "$submodule_url"
        else
            printf 'Refusing to replace non-empty non-Git path: %s\n' \
                "$LWIP_DIR" >&2
            exit 3
        fi
    else
        rmdir "$LWIP_DIR" 2>/dev/null || true
    fi

    if [ "$reuse_existing_clone" -eq 1 ]; then
        git -C "$PROJECT_ROOT" submodule add --force -b master \
            "$submodule_url" upstream/lwip
    else
        git -C "$PROJECT_ROOT" submodule add -b master \
            "$submodule_url" upstream/lwip
    fi
fi

git -C "$PROJECT_ROOT" config -f .gitmodules \
    submodule.upstream/lwip.branch master

git -C "$PROJECT_ROOT" submodule absorbgitdirs -- upstream/lwip

"$SCRIPT_DIR/sync-upstream.sh"

git -C "$PROJECT_ROOT" add .gitmodules upstream/lwip

printf '%s\n' 'lwIP submodule initialized.'
printf 'HEAD: %s\n' "$(git -C "$LWIP_DIR" rev-parse HEAD)"