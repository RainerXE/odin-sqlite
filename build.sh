#!/usr/bin/env bash
# Build the static SQLite library that sqlite3.odin's named foreign import links.
#
#   POSIX: ./build.sh            -> artifacts/libsqlite3.a
#   Windows: ./build.ps1 (MSVC)  -> artifacts/sqlite3.lib
#
# The amalgamation is vendored, so this needs no network access. Override the
# compiler with $CC (default: clang, falling back to cc).
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ART="$PKG_DIR/artifacts"
LIB="$ART/libsqlite3.a"
SRC="$PKG_DIR/amalgamation/sqlite3.c"

if [[ ! -f "$SRC" ]]; then
    echo "error: amalgamation/sqlite3.c not found." >&2
    echo "  this file is checked into the repo; see amalgamation/README.md" >&2
    exit 1
fi

CC_BIN="${CC:-}"
if [[ -z "$CC_BIN" ]]; then
    CC_BIN="$(command -v clang || command -v cc || true)"
fi
if [[ -z "$CC_BIN" ]]; then
    echo "error: no C compiler found; set CC to a clang/gcc-compatible compiler." >&2
    exit 1
fi

mkdir -p "$ART"

# The library is built as a static archive so that consumers do not need SQLite
# installed, and with -fPIC so it can also be linked into a shared object.
"$CC_BIN" -c "$SRC" -o "$ART/sqlite3.o" \
    -O2 -fPIC \
    -DSQLITE_THREADSAFE=1 \
    -DSQLITE_ENABLE_FTS5 \
    -DSQLITE_ENABLE_RTREE

rm -f "$LIB"
ar rcs "$LIB" "$ART/sqlite3.o"
echo "Built $LIB"
