/*
	odin-sqlite3 — a minimal SQLite3 binding for Odin.

	Thin procedural helpers over the raw C API in sqlite3.odin.
	No reflection, no generics — callers work with prepared statements directly.

	Ownership rules, in one place:
	  - Every proc returning `string` returns memory the caller owns and must
	    delete(), except db_errmsg, which returns a view owned by SQLite.
	  - Every successful db_prepare must be paired with stmt_finalize.
*/
package sqlite3

import "core:c"
import "core:mem"
import "core:strings"

// BUSY_TIMEOUT_MS bounds how long sqlite3_step will block-and-retry on
// SQLITE_BUSY/SQLITE_LOCKED (WAL writer contention) before giving up. Without
// this, any concurrent writer gets an immediate Busy/Locked error instead of a
// short internal retry, which is the wrong default for a multi-writer process.
BUSY_TIMEOUT_MS :: #config(SQLITE_BUSY_TIMEOUT_MS, 5000)

// db_open opens (or creates) a SQLite database at path.
// Returns nil + false on failure; use db_open_err if the reason matters.
db_open :: proc(path: string) -> (db: ^Connection, ok: bool) {
	d, err, o := db_open_err(path)
	delete(err)
	return d, o
}

// db_open_err is db_open plus the SQLite error message on failure. The message
// is owned by the caller and must be delete()d. It is "" on success.
db_open_err :: proc(path: string) -> (db: ^Connection, err: string, ok: bool) {
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)

	rc := sqlite3_open(cpath, &db)
	if rc != .Ok {
		// sqlite3_open allocates a handle even when it fails; closing it is
		// the documented way to avoid leaking the connection object.
		if db != nil {
			errmsg := sqlite3_errmsg(db)
			if errmsg != nil {
				err = strings.clone_from(errmsg)
			}
			sqlite3_close_v2(db)
		}
		return nil, err, false
	}

	// WAL mode: better concurrent read/write performance.
	sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
	sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
	sqlite3_busy_timeout(db, c.int(BUSY_TIMEOUT_MS))
	return db, "", true
}

// db_close closes the database connection. Pending statements are finalized by
// SQLite; explicit stmt_finalize calls are still preferred.
db_close :: proc(db: ^Connection) {
	if db != nil {
		sqlite3_close_v2(db)
	}
}

// db_exec runs a single SQL statement with no parameters and discards results.
// Returns true on success.
db_exec :: proc(db: ^Connection, sql: string) -> bool {
	csql := strings.clone_to_cstring(sql)
	defer delete(csql)
	return sqlite3_exec(db, csql, nil, nil, nil) == .Ok
}

// db_exec_script runs multiple semicolon-separated SQL statements.
// On failure, err is an owned string describing the first statement that
// failed (caller must delete() it); on success err is "".
db_exec_script :: proc(db: ^Connection, script: string) -> (ok: bool, err: string) {
	csql := strings.clone_to_cstring(script)
	defer delete(csql)

	errmsg: cstring
	rc := sqlite3_exec(db, csql, nil, nil, &errmsg)
	if rc == .Ok {
		return true, ""
	}
	if errmsg != nil {
		defer sqlite3_free(rawptr(errmsg))
		return false, strings.clone_from(errmsg)
	}
	return false, strings.clone(db_errmsg(db))
}

// Stmt is a prepared statement ready for binding and stepping.
Stmt :: struct {
	handle: ^Statement,
	db:     ^Connection,
}

// db_prepare compiles the first SQL statement in sql.
// Must call stmt_finalize when done. If sql contains more than one statement,
// ok is false and the extra statement(s) are never compiled — use
// db_exec_script for scripts. Empty or comment-only SQL is also reported as a
// failure: it yields no executable statement, and stepping a nil statement
// would be undefined behaviour.
db_prepare :: proc(db: ^Connection, sql: string) -> (s: Stmt, ok: bool) {
	s.db = db
	csql := strings.clone_to_cstring(sql)
	defer delete(csql)

	tail: cstring
	rc := sqlite3_prepare_v2(db, csql, c.int(len(sql)), &s.handle, &tail)
	if rc != .Ok {
		s.handle = nil
		return s, false
	}
	if s.handle == nil {
		// Nothing to execute: empty input, or only whitespace/comments.
		return s, false
	}

	// Ask SQLite itself whether the tail holds a real second statement — it
	// skips whitespace/comments internally and reports .Ok with a nil stmt if
	// nothing remains, so this cannot misfire on a trailing "-- ...".
	if tail != nil && len(strings.trim_space(string(tail))) > 0 {
		tail_stmt: ^Statement
		rc2 := sqlite3_prepare_v2(db, tail, -1, &tail_stmt, nil)
		if tail_stmt != nil {
			sqlite3_finalize(tail_stmt)
		}
		if rc2 != .Ok || tail_stmt != nil {
			sqlite3_finalize(s.handle)
			s.handle = nil
			return s, false
		}
	}
	return s, true
}

// stmt_finalize releases the prepared statement. Safe on a zero Stmt.
stmt_finalize :: proc(s: ^Stmt) {
	if s.handle != nil {
		sqlite3_finalize(s.handle)
		s.handle = nil
	}
}

// stmt_reset resets the statement for re-use with new bindings.
stmt_reset :: proc(s: ^Stmt) {
	sqlite3_reset(s.handle)
}

// stmt_param_index resolves a named parameter (":name", "@name", or "$name",
// matching the marker used in the SQL text) to its 1-based bind column.
// Returns 0 (ok=false) if no such parameter exists in the prepared statement.
stmt_param_index :: proc(s: ^Stmt, name: string) -> (col: int, ok: bool) {
	cname := strings.clone_to_cstring(name)
	defer delete(cname)
	idx := sqlite3_bind_parameter_index(s.handle, cname)
	return int(idx), idx != 0
}

// Bind helpers — columns are 1-indexed (SQLite convention).

// stmt_bind_text binds a string as TEXT. The full byte range is bound, so
// embedded NUL bytes survive; SQLite copies it immediately (TRANSIENT).
stmt_bind_text :: proc(s: ^Stmt, col: int, val: string) -> bool {
	if len(val) == 0 {
		// raw_data("") is a nil pointer, which would bind SQL NULL instead of
		// an empty string, so bind a pointer to a real NUL byte instead.
		return sqlite3_bind_text(s.handle, c.int(col), "", 0, TRANSIENT) == .Ok
	}
	return sqlite3_bind_text(s.handle, c.int(col), cstring(raw_data(val)), c.int(len(val)), TRANSIENT) == .Ok
}

stmt_bind_int :: proc(s: ^Stmt, col: int, val: int) -> bool {
	return sqlite3_bind_int64(s.handle, c.int(col), c.int64_t(val)) == .Ok
}

stmt_bind_i64 :: proc(s: ^Stmt, col: int, val: i64) -> bool {
	return sqlite3_bind_int64(s.handle, c.int(col), c.int64_t(val)) == .Ok
}

stmt_bind_f64 :: proc(s: ^Stmt, col: int, val: f64) -> bool {
	return sqlite3_bind_double(s.handle, c.int(col), c.double(val)) == .Ok
}

// stmt_bind_blob binds data as a BLOB. A nil slice binds SQL NULL; a non-nil
// but zero-length slice binds an actual empty blob (x'') — these are distinct
// in SQL, so callers that need NULL must pass a nil slice rather than data[:0].
stmt_bind_blob :: proc(s: ^Stmt, col: int, data: []u8) -> bool {
	if data == nil {
		return sqlite3_bind_null(s.handle, c.int(col)) == .Ok
	}
	if len(data) == 0 {
		// A NULL pointer binds SQL NULL regardless of the length. A non-NULL
		// pointer with n=0 is what produces a real zero-length blob value.
		dummy: u8
		return sqlite3_bind_blob(s.handle, c.int(col), &dummy, 0, TRANSIENT) == .Ok
	}
	return sqlite3_bind_blob(s.handle, c.int(col), rawptr(&data[0]), c.int(len(data)), TRANSIENT) == .Ok
}

stmt_bind_null :: proc(s: ^Stmt, col: int) -> bool {
	return sqlite3_bind_null(s.handle, c.int(col)) == .Ok
}

// stmt_step advances to the next row. Returns true while rows remain.
stmt_step :: proc(s: ^Stmt) -> bool {
	return sqlite3_step(s.handle) == .Row
}

// stmt_exec runs a non-SELECT statement (INSERT / UPDATE / DELETE).
// Returns true on success (.Done).
stmt_exec :: proc(s: ^Stmt) -> bool {
	return sqlite3_step(s.handle) == .Done
}

// Column readers — 0-indexed (SQLite convention for column_*).

stmt_col_int :: proc(s: ^Stmt, col: int) -> int {
	return int(sqlite3_column_int64(s.handle, c.int(col)))
}

stmt_col_i64 :: proc(s: ^Stmt, col: int) -> i64 {
	return i64(sqlite3_column_int64(s.handle, c.int(col)))
}

stmt_col_f64 :: proc(s: ^Stmt, col: int) -> f64 {
	return f64(sqlite3_column_double(s.handle, c.int(col)))
}

// stmt_col_blob returns an owned copy of the column value, or nil for SQL NULL.
// A real empty blob also comes back as a zero-length (nil-backed) slice, so use
// stmt_col_type when the difference between NULL and x'' matters.
stmt_col_blob :: proc(s: ^Stmt, col: int) -> []u8 {
	ptr := sqlite3_column_blob(s.handle, c.int(col))
	n := int(sqlite3_column_bytes(s.handle, c.int(col)))
	if ptr == nil || n == 0 {
		return nil
	}
	out := make([]u8, n)
	mem.copy(rawptr(&out[0]), ptr, n)
	return out
}

// stmt_col_text returns an owned heap-allocated copy of the column value.
// Returns an owned empty string (not a literal) for SQL NULL, so callers can
// safely call delete() on every return value without crashing.
stmt_col_text :: proc(s: ^Stmt, col: int) -> string {
	cs := sqlite3_column_text(s.handle, c.int(col))
	if cs == nil {
		return strings.clone("")
	}
	// Text columns are length-delimited, not NUL-terminated: SQLite allows
	// embedded NULs, which a cstring conversion would truncate.
	n := int(sqlite3_column_bytes(s.handle, c.int(col)))
	return strings.clone(string(mem.slice_ptr((^u8)(rawptr(cs)), n)))
}

// stmt_col_text_raw exposes SQLite's internal string for the current row. The
// pointer is owned by SQLite and stays valid only until the next step/reset.
stmt_col_text_raw :: proc(s: ^Stmt, col: int) -> cstring {
	return sqlite3_column_text(s.handle, c.int(col))
}

// stmt_col_type reports the storage class SQLite assigned the current row's
// value in col (sqlite3's columns are dynamically typed per-row, not per
// declared schema type) — use this to distinguish a real SQL NULL from a
// zero/empty value when a column is nullable.
stmt_col_type :: proc(s: ^Stmt, col: int) -> Column_Type {
	return sqlite3_column_type(s.handle, c.int(col))
}

// db_last_id returns the rowid of the most recent INSERT.
db_last_id :: proc(db: ^Connection) -> i64 {
	return i64(sqlite3_last_insert_rowid(db))
}

// db_changes returns the number of rows changed by the most recent statement.
db_changes :: proc(db: ^Connection) -> int {
	return int(sqlite3_changes(db))
}

// db_errmsg returns the last error message for diagnostics. The returned view
// is owned by SQLite: do not delete it, and do not use it after the next call
// on this connection.
db_errmsg :: proc(db: ^Connection) -> string {
	cs := sqlite3_errmsg(db)
	if cs == nil {
		return ""
	}
	return string(cs)
}

// db_errcode returns the last primary result code for db, for callers that
// need to branch on the failure kind (e.g. retry on .Busy) rather than just
// log db_errmsg.
db_errcode :: proc(db: ^Connection) -> Result {
	return sqlite3_errcode(db)
}

// db_lib_version returns the version of the linked SQLite library, which is
// useful in diagnostics because it can differ from the vendored amalgamation.
db_lib_version :: proc() -> string {
	cs := sqlite3_libversion()
	if cs == nil {
		return ""
	}
	return string(cs)
}

// db_begin/db_commit/db_rollback wrap a plain (non-nested) transaction.
// SQLite does not support nested BEGIN — use SAVEPOINT via db_exec for that.
db_begin :: proc(db: ^Connection) -> bool {
	return db_exec(db, "BEGIN;")
}

db_commit :: proc(db: ^Connection) -> bool {
	return db_exec(db, "COMMIT;")
}

db_rollback :: proc(db: ^Connection) -> bool {
	return db_exec(db, "ROLLBACK;")
}
