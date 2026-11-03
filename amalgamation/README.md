# Vendored SQLite amalgamation

- Version: SQLite 3.53.4
- Source: https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip
- SHA3-256 (as published on https://www.sqlite.org/download.html): `628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e`

Only `sqlite3.c` and `sqlite3.h` are kept; the zip's `shell.c` and
`sqlite3ext.h` aren't needed by this binding.

## Updating

1. Get the current amalgamation filename/version from
   https://www.sqlite.org/download.html.
2. Download it and verify the SHA3-256 against the value published on that
   page — note it's **SHA3-256**, not SHA256/SHA1; `shasum`/`openssl dgst`
   default to SHA2 algorithms and will report a false mismatch unless you
   pass the right digest name (e.g. `openssl dgst -sha3-256`).
3. Replace `sqlite3.c` and `sqlite3.h` here, update the version/hash above,
   and run `../build.sh` to rebuild `artifacts/libsqlite3.a`.
