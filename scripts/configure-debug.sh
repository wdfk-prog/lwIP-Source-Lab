#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
PROJECT_ROOT=$(CDPATH= cd -P "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)
LWIP_DIR="$PROJECT_ROOT/upstream/lwip"
BUILD_ROOT="$PROJECT_ROOT/build"
EXAMPLE_BUILD_DIR="$BUILD_ROOT/example"
UNIT_BUILD_DIR="$BUILD_ROOT/unit-tests"
CONFIG="$LWIP_DIR/contrib/examples/example_app/lwipcfg.h"
TEMPLATE="$LWIP_DIR/contrib/examples/example_app/lwipcfg.h.example"

for tool in cmake ninja; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'Required command not found: %s\n' "$tool" >&2; exit 127; }
done

if ! git -C "$LWIP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s\n' 'lwIP submodule is not initialized. Run scripts/bootstrap-repository.sh first.' >&2
    exit 2
fi

if [ ! -f "$TEMPLATE" ]; then
    printf 'Missing upstream example config template: %s\n' "$TEMPLATE" >&2
    exit 2
fi

# A configure always re-establishes the current upstream master baseline.
# Stage-specific tutorials apply their temporary overrides after this step and
# build directly without re-running configure in between.
cp "$TEMPLATE" "$CONFIG"
printf 'Refreshed example config from current upstream template: %s\n' "$CONFIG"

mkdir -p "$BUILD_ROOT"

cmake \
    -S "$LWIP_DIR" \
    -B "$EXAMPLE_BUILD_DIR" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

unit_cflags=${CFLAGS:-}
compiler=${CC:-cc}
command -v "$compiler" >/dev/null 2>&1 || { printf 'Compiler not found: %s\n' "$compiler" >&2; exit 127; }

# Current upstream Unit Tests can hit two Host-toolchain compatibility cases:
# GCC stack-check vs distro stack-clash defaults, and libcheck's deprecated
# fail_unless() macro becoming fatal under upstream -Werror. Probe the Host and
# add only the workaround that is actually required.
if ! "$compiler" --version 2>/dev/null | sed -n '1p' | grep -qi clang; then
    if ! printf '%s\n' 'int main(void) { return 0; }' | \
        "$compiler" -x c - -c -o /dev/null -Werror -fstack-check >/dev/null 2>&1; then
        if printf '%s\n' 'int main(void) { return 0; }' | \
            "$compiler" -x c - -c -o /dev/null -Werror \
            -fno-stack-clash-protection -fstack-check >/dev/null 2>&1; then
            unit_cflags="${unit_cflags:+$unit_cflags }-fno-stack-clash-protection"
        else
            printf '%s\n' 'Unable to find a compatible GCC stack-check flag set.' >&2
            exit 2
        fi
    fi
fi

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists check 2>/dev/null; then
    check_cflags=$(pkg-config --cflags check 2>/dev/null || true)
    # shellcheck disable=SC2086
    if ! printf '%s\n' '#include <check.h>' 'void probe(int v) { fail_unless(v, "v=%d", v); }' | \
        "$compiler" -x c - -c -o /dev/null $check_cflags \
        -Wformat -Werror=format-extra-args >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        if printf '%s\n' '#include <check.h>' 'void probe(int v) { fail_unless(v, "v=%d", v); }' | \
            "$compiler" -x c - -c -o /dev/null $check_cflags \
            -Wformat -Werror -Wno-error=format-extra-args >/dev/null 2>&1; then
            unit_cflags="${unit_cflags:+$unit_cflags }-Wno-error=format-extra-args"
        else
            printf '%s\n' 'Unable to compile a libcheck fail_unless() compatibility probe.' >&2
            exit 2
        fi
    fi
fi

cmake \
    -S "$LWIP_DIR/contrib/ports/unix/check" \
    -B "$UNIT_BUILD_DIR" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_C_FLAGS="$unit_cflags"

printf 'Example build:    %s\n' "$EXAMPLE_BUILD_DIR"
printf 'Unit-test build:  %s\n' "$UNIT_BUILD_DIR"
