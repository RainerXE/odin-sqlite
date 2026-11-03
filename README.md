# odin-sqlite

A self-contained SQLite3 binding for [Odin](https://odin-lang.org): a small raw
C binding plus a thin procedural layer, linked against a vendored SQLite
amalgamation that this repository builds itself. Consumers do **not** pass
`-lsqlite3` and do not depend on whichever SQLite the host happens to ship.

```odin
import sqlite3 "../odin-sqlite"

db, ok := sqlite3.db_open("app.db")
if !ok { return }
defer sqlite3.db_close(db)

if _, err := sqlite3.db_exec_script(db, "CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT);"); err != "" {
    delete(err)
    return
}
```

## Features

- **Self-contained** — the SQLite amalgamation is vendored and compiled into
  `artifacts/`, so builds are reproducible and offline.
- **No reflection** — prepared statements are values you bind and step yourself;
  every `db_*` / `stmt_*` call maps closely to one SQLite C call.
- **Practical defaults** — WAL journal mode, `foreign_keys=ON`, and a busy
  timeout on open, so multiple writers retry instead of failing immediately.
- **Real error reporting** — `db_errmsg`, `db_errcode`, and an owned error string
  from `db_exec_script`.
- **Correct text and blob handling** — text is length-delimited (embedded NUL
  bytes survive), and `NULL` is distinct from an empty string and an empty blob.
- **Portable** — Linux, macOS, and Windows (MSVC); the library selection is
  built in, so a plain `odin build` works on all three.

## Requirements

- Odin (any recent dev build)
- A C compiler to build the amalgamation: `clang` or `gcc` on POSIX, MSVC on
  Windows

## Layout

```
odin-sqlite/
  sqlite3.odin       raw C declarations + named foreign import
  db.odin            procedural helpers (open / exec / prepare / bind / step / column)
  sqlite3_test.odin  standalone test suite
  build.sh           builds artifacts/libsqlite3.a (clang/gcc)
  build.ps1          builds artifacts/sqlite3.lib (MSVC)
  amalgamation/      vendored SQLite C sources — see amalgamation/README.md
  artifacts/         build output (git-ignored)
```

## Building

POSIX:

```sh
./build.sh
```

Windows (PowerShell):

```powershell
.\build.ps1
```

Both scripts compile `amalgamation/sqlite3.c` into a static library under
`artifacts/`. That is the path `sqlite3.odin`'s `foreign import` resolves to, so
build the package before building anything that imports it.

## Using it

Add this directory to your project (git submodule, vendor copy, or a sibling
checkout), build it once, then import it by relative path:

```odin
import sqlite3 "../odin-sqlite"
```

`foreign import` paths in Odin are resolved relative to the declaring source
file, which is why the default needs no configuration. To link a different
SQLite build (system library, SQLCipher, a custom amalgamation), pass a
file-relative path:

```sh
odin build . -define:SQLITE_LIB=../path/to/libsqlite3.a
```

On Windows the default is `artifacts/sqlite3.lib`; pass
`-define:SQLITE_LIB=artifacts/sqlite3.lib` only if you build the library
somewhere else.

## Testing

```sh
./build.sh
odin test . -define:ODIN_TEST_THREADS=1
```

The suite covers the in-memory round trip, multi-statement rejection, script
errors, named parameters, transactions, text/blob `NULL` semantics, embedded
NUL bytes, and open failures.

## API overview

| Group | Procedures |
|---|---|
| Connection | `db_open`, `db_open_err`, `db_close`, `db_exec`, `db_exec_script`, `db_begin`, `db_commit`, `db_rollback` |
| Diagnostics | `db_errmsg`, `db_errcode`, `db_lib_version`, `db_last_id`, `db_changes` |
| Statements | `db_prepare`, `stmt_finalize`, `stmt_reset`, `stmt_step`, `stmt_exec`, `stmt_param_index` |
| Binding | `stmt_bind_text`, `stmt_bind_int`, `stmt_bind_i64`, `stmt_bind_f64`, `stmt_bind_blob`, `stmt_bind_null` |
| Reading | `stmt_col_int`, `stmt_col_i64`, `stmt_col_f64`, `stmt_col_text`, `stmt_col_text_raw`, `stmt_col_blob`, `stmt_col_type` |

Everything else from the SQLite C API is unbound; add the declaration you need
to `sqlite3.odin` (the [SQLite C reference](https://www.sqlite.org/c3ref/intro.html)
lists the exact signatures).

## Design notes

- **Ownership.** Procs returning `string` return memory the caller owns and must
  `delete()`. `db_errmsg` and `stmt_col_text_raw` return views owned by SQLite
  and must not be freed.
- **Concurrency.** `db_open` sets a busy timeout (5 s by default, override with
  `-define:SQLITE_BUSY_TIMEOUT_MS=<ms>`). The amalgamation is built with
  `SQLITE_THREADSAFE=1` (serialized), so a connection may be shared across
  threads, though one connection per thread reads better.
- **Transactions.** `db_begin` / `db_commit` / `db_rollback` wrap a plain,
  non-nested transaction. SQLite has no nested `BEGIN`; use `SAVEPOINT` through
  `db_exec` if you need one.
- **`db_prepare` is strict.** SQL containing a second statement is rejected
  rather than silently truncated; trailing whitespace and comments are fine.
  Empty or comment-only SQL also fails, because it yields no statement. Use
  `db_exec_script` for genuine scripts.
- **`NULL` handling.** `stmt_col_type` reports the per-row storage class, which
  is how you tell `NULL` from `0`, `''`, or `x''`. A `nil` slice binds SQL
  `NULL`; a non-nil zero-length slice binds an empty blob. Note that Odin's
  `[]u8{}` is `nil` — slice a real array (`arr[0:0]`) for a genuinely non-nil
  empty slice.

## License

Released under the zlib-style license in [LICENSE](LICENSE): free for any use,
including commercial, provided the origin is not misrepresented and altered
versions are marked as such.

This package vendors SQLite (public domain) and adapts declarations from
[saenai255/odin-sqlite3](https://github.com/saenai255/odin-sqlite3) (MIT). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for those notices.
