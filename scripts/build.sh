#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
PROJECT_ROOT=$(CDPATH= cd -P "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)
EXAMPLE_BUILD_DIR="$PROJECT_ROOT/build/example"
UNIT_BUILD_DIR="$PROJECT_ROOT/build/unit-tests"
TARGET=${1:-all}

case "$TARGET" in
    example|unit|all)
        ;;
    *)
        printf 'Usage: %s [example|unit|all]\n' "$0" >&2
        exit 2
        ;;
esac

command -v cmake >/dev/null 2>&1 || { printf '%s\n' 'cmake is required.' >&2; exit 127; }

require_cache()
{
    cache=$1
    label=$2
    if [ ! -f "$cache" ]; then
        printf '%s build tree is not configured.\n' "$label" >&2
        printf '%s\n' 'Run scripts/configure-debug.sh first, then reapply any stage-specific lwipcfg.h override before building.' >&2
        exit 2
    fi
}

case "$TARGET" in
    example)
        require_cache "$EXAMPLE_BUILD_DIR/CMakeCache.txt" 'example'
        ;;
    unit)
        require_cache "$UNIT_BUILD_DIR/CMakeCache.txt" 'unit-test'
        ;;
    all)
        require_cache "$EXAMPLE_BUILD_DIR/CMakeCache.txt" 'example'
        require_cache "$UNIT_BUILD_DIR/CMakeCache.txt" 'unit-test'
        ;;
esac

build_example()
{
    cmake --build "$EXAMPLE_BUILD_DIR" --target example_app --parallel
}

build_unit()
{
    cmake --build "$UNIT_BUILD_DIR" --target lwip_unittests --parallel
}

case "$TARGET" in
    example)
        build_example
        ;;
    unit)
        build_unit
        ;;
    all)
        build_example
        build_unit
        ;;
esac
