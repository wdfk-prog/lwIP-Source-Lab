#!/usr/bin/env sh
set -eu

missing=0

for tool in git cmake ninja gdb pkg-config; do
    if command -v "$tool" >/dev/null 2>&1; then
        printf '[OK]   %-12s %s\n' "$tool" "$(command -v "$tool")"
    else
        printf '[MISS] %-12s\n' "$tool"
        missing=1
    fi
done

compiler=${CC:-cc}
if command -v "$compiler" >/dev/null 2>&1; then
    printf '[OK]   %-12s %s\n' 'C compiler' "$(command -v "$compiler")"
else
    printf '[MISS] %-12s %s\n' 'C compiler' "$compiler"
    missing=1
fi

if command -v pkg-config >/dev/null 2>&1; then
    if pkg-config --exists check 2>/dev/null; then
        printf '[OK]   %-12s %s\n' 'libcheck' \
            "$(pkg-config --modversion check 2>/dev/null || printf installed)"
    else
        printf '[MISS] %-12s %s\n' 'libcheck' '(pkg-config cannot find check)'
        missing=1
    fi
fi

if [ "$missing" -ne 0 ]; then
    cat >&2 <<'MSG'

Ubuntu example installation:
  sudo apt update
  sudo apt install build-essential cmake ninja-build gdb check git pkg-config
MSG
    exit 1
fi

printf '%s\n' 'Common Host tools are ready.'
