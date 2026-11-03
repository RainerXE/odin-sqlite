/*
	odin-sqlite3 — a minimal SQLite3 binding for Odin.

	Raw declarations for the part of the SQLite C API this package uses, plus
	the named `foreign import` that links the static library built by build.sh.
	Symbols keep their sqlite3_ names; the ergonomic layer lives in db.odin.

	The declarations were originally adapted from saenai255/odin-sqlite3
	(MIT). See THIRD_PARTY_NOTICES.md.
*/
package sqlite3

import "core:c"

// Opaque handle types — never dereference.
Connection :: distinct rawptr
Statement :: distinct rawptr

// SQLITE_TRANSIENT: tell SQLite to copy the data immediately (cast of -1).
TRANSIENT :: rawptr(~uintptr(0))
// SQLITE_STATIC: caller guarantees the data outlives the statement.
STATIC :: rawptr(uintptr(0))

Result :: enum c.int {
	Ok         = 0,
	Error      = 1,
	Internal   = 2,
	Perm       = 3,
	Abort      = 4,
	Busy       = 5,
	Locked     = 6,
	NoMem      = 7,
	ReadOnly   = 8,
	Interrupt  = 9,
	IoErr      = 10,
	Corrupt    = 11,
	NotFound   = 12,
	Full       = 13,
	CantOpen   = 14,
	Protocol   = 15,
	Schema     = 17,
	TooBig     = 18,
	Constraint = 19,
	Mismatch   = 20,
	Misuse     = 21,
	NoLfs      = 22,
	Auth       = 23,
	Format     = 24,
	Range      = 25,
	NotA_Db    = 26,
	Row        = 100,
	Done       = 101,
}

// Column_Type mirrors SQLite's dynamic column typing (SQLITE_INTEGER etc.),
// returned by sqlite3_column_type for the value currently in a result column.
Column_Type :: enum c.int {
	Integer = 1,
	Float   = 2,
	Text    = 3,
	Blob    = 4,
	Null    = 5,
}

// Odin resolves foreign-import paths relative to THIS file, so the default
// points at this package's own build output: the binding is self-contained and
// build.sh must run before a consumer links. Override with
// -define:SQLITE_LIB=<file-relative path> to link a different library.
//
// The default is platform-aware: MSVC produces a COFF .lib, not an ar archive,
// so hardcoding libsqlite3.a would break Windows consumers that use the
// documented build.ps1 output.
when ODIN_OS == .Windows {
	SQLITE_LIB :: #config(SQLITE_LIB, "artifacts/sqlite3.lib")
} else {
	SQLITE_LIB :: #config(SQLITE_LIB, "artifacts/libsqlite3.a")
}
foreign import sqlite {SQLITE_LIB}

// Raw SQLite3 C API.
@(default_calling_convention = "c")
foreign sqlite {
	sqlite3_open                 :: proc(filename: cstring, db: ^^Connection) -> Result ---
	sqlite3_close_v2             :: proc(db: ^Connection) -> Result ---
	sqlite3_exec                 :: proc(db: ^Connection, sql: cstring, cb: rawptr, arg: rawptr, errmsg: ^cstring) -> Result ---
	sqlite3_prepare_v2           :: proc(db: ^Connection, sql: cstring, nbyte: c.int, stmt: ^^Statement, tail: ^cstring) -> Result ---
	sqlite3_step                 :: proc(stmt: ^Statement) -> Result ---
	sqlite3_finalize             :: proc(stmt: ^Statement) -> Result ---
	sqlite3_reset                :: proc(stmt: ^Statement) -> Result ---
	sqlite3_bind_text            :: proc(stmt: ^Statement, col: c.int, val: cstring, n: c.int, dtor: rawptr) -> Result ---
	sqlite3_bind_int             :: proc(stmt: ^Statement, col: c.int, val: c.int) -> Result ---
	sqlite3_bind_int64           :: proc(stmt: ^Statement, col: c.int, val: c.int64_t) -> Result ---
	sqlite3_bind_double          :: proc(stmt: ^Statement, col: c.int, val: c.double) -> Result ---
	sqlite3_bind_blob            :: proc(stmt: ^Statement, col: c.int, val: rawptr, n: c.int, dtor: rawptr) -> Result ---
	sqlite3_bind_zeroblob        :: proc(stmt: ^Statement, col: c.int, n: c.int) -> Result ---
	sqlite3_bind_null            :: proc(stmt: ^Statement, col: c.int) -> Result ---
	sqlite3_bind_parameter_index :: proc(stmt: ^Statement, name: cstring) -> c.int ---
	sqlite3_column_int           :: proc(stmt: ^Statement, col: c.int) -> c.int ---
	sqlite3_column_int64         :: proc(stmt: ^Statement, col: c.int) -> c.int64_t ---
	sqlite3_column_double        :: proc(stmt: ^Statement, col: c.int) -> c.double ---
	sqlite3_column_blob          :: proc(stmt: ^Statement, col: c.int) -> rawptr ---
	sqlite3_column_bytes         :: proc(stmt: ^Statement, col: c.int) -> c.int ---
	sqlite3_column_text          :: proc(stmt: ^Statement, col: c.int) -> cstring ---
	sqlite3_column_count         :: proc(stmt: ^Statement) -> c.int ---
	sqlite3_column_name          :: proc(stmt: ^Statement, col: c.int) -> cstring ---
	sqlite3_column_type          :: proc(stmt: ^Statement, col: c.int) -> Column_Type ---
	sqlite3_errmsg               :: proc(db: ^Connection) -> cstring ---
	sqlite3_errcode              :: proc(db: ^Connection) -> Result ---
	sqlite3_last_insert_rowid    :: proc(db: ^Connection) -> c.int64_t ---
	sqlite3_changes              :: proc(db: ^Connection) -> c.int ---
	sqlite3_libversion           :: proc() -> cstring ---
	sqlite3_free                 :: proc(ptr: rawptr) ---
	sqlite3_busy_timeout         :: proc(db: ^Connection, ms: c.int) -> Result ---
}
