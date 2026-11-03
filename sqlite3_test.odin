package sqlite3

import "core:testing"

// Standalone test suite: builds against the package's own static library, with
// no host -lsqlite3. Build it first with ./build.sh, then:
//   odin test . -define:ODIN_TEST_THREADS=1

@(test)
test_roundtrip_in_memory :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok, "open in-memory database")
	defer db_close(db)

	testing.expect(t, db_exec(db, "CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT, score REAL)"), "create table")

	ins, ins_ok := db_prepare(db, "INSERT INTO items(name, score) VALUES (?, ?)")
	testing.expect(t, ins_ok, "prepare insert")
	testing.expect(t, stmt_bind_text(&ins, 1, "alpha"), "bind name")
	testing.expect(t, stmt_bind_f64(&ins, 2, 1.5), "bind score")
	testing.expect(t, stmt_exec(&ins), "execute insert")
	stmt_finalize(&ins)

	testing.expect_value(t, db_last_id(db), i64(1))
	testing.expect_value(t, db_changes(db), 1)

	sel, sel_ok := db_prepare(db, "SELECT name, score FROM items WHERE id = 1")
	testing.expect(t, sel_ok, "prepare select")
	defer stmt_finalize(&sel)

	testing.expect(t, stmt_step(&sel), "row should be available")
	name := stmt_col_text(&sel, 0)
	defer delete(name)
	testing.expect_value(t, name, "alpha")
	testing.expect_value(t, stmt_col_f64(&sel, 1), 1.5)
	testing.expect(t, !stmt_step(&sel), "only one row expected")
}

@(test)
test_prepare_rejects_second_statement :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok, "open in-memory database")
	defer db_close(db)

	// Two real statements: must be rejected, not silently truncated to the first.
	_, bad_ok := db_prepare(db, "SELECT 1; SELECT 2;")
	testing.expect(t, !bad_ok, "two statements should be rejected by db_prepare")

	// A single statement followed by a trailing line comment must still work.
	s, ok2 := db_prepare(db, "SELECT 1;\n-- trailing comment, not a statement\n")
	defer stmt_finalize(&s)
	testing.expect(t, ok2, "trailing comment after the statement should not be rejected")

	// A single statement with no trailing tail at all.
	s2, ok3 := db_prepare(db, "SELECT 1")
	defer stmt_finalize(&s2)
	testing.expect(t, ok3, "single statement with no tail should prepare")
}

@(test)
test_prepare_rejects_empty_sql :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok, "open in-memory database")
	defer db_close(db)

	// Both prepare successfully in SQLite but yield no statement handle;
	// reporting them as success would hand the caller a nil statement.
	for sql in ([]string{"", "   ", "-- only a comment", ";"}) {
		s, prepared := db_prepare(db, sql)
		testing.expectf(t, !prepared, "SQL %q should not prepare a statement", sql)
		testing.expect(t, s.handle == nil, "failed prepare must not expose a handle")
		stmt_finalize(&s) // must be safe on a zero statement
	}
}

@(test)
test_exec_script_multi_statement :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok, "open in-memory database")
	defer db_close(db)

	ok2, err := db_exec_script(db, "CREATE TABLE a(x INT); CREATE TABLE b(y INT);")
	defer delete(err)
	testing.expect(t, ok2, "multi-statement script should succeed")
	testing.expect_value(t, err, "")

	testing.expect(t, db_exec(db, "INSERT INTO a(x) VALUES (1)"), "insert into first table")
	testing.expect(t, db_exec(db, "INSERT INTO b(y) VALUES (2)"), "insert into second table")
}

@(test)
test_exec_script_reports_error :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok, "open in-memory database")
	defer db_close(db)

	ok2, err := db_exec_script(db, "CREATE TABLE t(x INT); INSERT INTO nonexistent(x) VALUES (1);")
	defer delete(err)
	testing.expect(t, !ok2, "script referencing a missing table should fail")
	testing.expect(t, len(err) > 0, "failure should carry a non-empty error message")
}

@(test)
test_bind_and_step_failure_modes :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok, "open in-memory database")
	defer db_close(db)

	testing.expect(t, db_exec(db, "CREATE TABLE t(x INT NOT NULL)"), "create table")

	ins, ins_ok := db_prepare(db, "INSERT INTO t(x) VALUES (?)")
	testing.expect(t, ins_ok, "prepare insert")
	defer stmt_finalize(&ins)

	// Binding NULL into a NOT NULL column: bind itself succeeds (SQLite defers
	// the constraint check to step), but stmt_exec must report the failure.
	testing.expect(t, stmt_bind_null(&ins, 1), "bind null")
	testing.expect(t, !stmt_exec(&ins), "insert violating NOT NULL should fail at step")
	testing.expect_value(t, db_errcode(db), Result.Constraint)
	testing.expect(t, len(db_errmsg(db)) > 0, "errmsg should be non-empty after a constraint failure")
}

@(test)
test_text_binary_safe :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok, "open in-memory database")
	defer db_close(db)

	testing.expect(t, db_exec(db, "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)"), "create table")

	ins, ins_ok := db_prepare(db, "INSERT INTO t(id, v) VALUES (?, ?)")
	testing.expect(t, ins_ok, "prepare insert")
	defer stmt_finalize(&ins)

	values := []string{"a\x00b", ""}
	for value, i in values {
		testing.expect(t, stmt_bind_int(&ins, 1, i + 1), "bind id")
		testing.expect(t, stmt_bind_text(&ins, 2, value), "bind text")
		testing.expect(t, stmt_exec(&ins), "insert text")
		stmt_reset(&ins)
	}

	sel, sel_ok := db_prepare(db, "SELECT v FROM t ORDER BY id")
	testing.expect(t, sel_ok, "prepare select")
	defer stmt_finalize(&sel)

	// The embedded NUL must survive as a real byte of the TEXT value.
	testing.expect(t, stmt_step(&sel), "row 1")
	got := stmt_col_text(&sel, 0)
	testing.expect_value(t, len(got), 3)
	testing.expect_value(t, got, values[0])
	delete(got)

	// The empty string must be empty TEXT, not SQL NULL.
	testing.expect(t, stmt_step(&sel), "row 2")
	testing.expect_value(t, stmt_col_type(&sel, 0), Column_Type.Text)
	empty := stmt_col_text(&sel, 0)
	testing.expect_value(t, len(empty), 0)
	delete(empty)
}

@(test)
test_blob_roundtrip_and_null_semantics :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok, "open in-memory database")
	defer db_close(db)

	testing.expect(t, db_exec(db, "CREATE TABLE t(id INTEGER PRIMARY KEY, b BLOB)"), "create table")

	ins, ins_ok := db_prepare(db, "INSERT INTO t(id, b) VALUES (?, ?)")
	testing.expect(t, ins_ok, "prepare insert")

	data := []u8{1, 2, 3, 4}
	testing.expect(t, stmt_bind_int(&ins, 1, 1), "bind id 1")
	testing.expect(t, stmt_bind_blob(&ins, 2, data), "bind non-empty blob")
	testing.expect(t, stmt_exec(&ins), "insert non-empty blob")
	stmt_reset(&ins)

	testing.expect(t, stmt_bind_int(&ins, 1, 2), "bind id 2")
	// []u8{} is nil in Odin (empty composite literals do not allocate a
	// backing array), so it would hit the NULL branch below — slicing a real
	// array to zero length is how you get a genuinely non-nil, zero-length
	// slice to exercise the empty-blob path.
	empty_backing := [1]u8{}
	empty_slice := empty_backing[0:0]
	testing.expect(t, empty_slice != nil, "sanity: slice must be non-nil to test the empty-blob path")
	testing.expect(t, stmt_bind_blob(&ins, 2, empty_slice), "bind empty-but-non-nil blob")
	testing.expect(t, stmt_exec(&ins), "insert empty blob")
	stmt_reset(&ins)

	testing.expect(t, stmt_bind_int(&ins, 1, 3), "bind id 3")
	testing.expect(t, stmt_bind_blob(&ins, 2, nil), "bind nil blob as NULL")
	testing.expect(t, stmt_exec(&ins), "insert null blob")
	stmt_finalize(&ins)

	sel, sel_ok := db_prepare(db, "SELECT b FROM t ORDER BY id")
	testing.expect(t, sel_ok, "prepare select")
	defer stmt_finalize(&sel)

	testing.expect(t, stmt_step(&sel), "row 1 (non-empty blob)")
	testing.expect_value(t, stmt_col_type(&sel, 0), Column_Type.Blob)
	got := stmt_col_blob(&sel, 0)
	defer delete(got)
	testing.expect_value(t, len(got), 4)

	testing.expect(t, stmt_step(&sel), "row 2 (empty blob)")
	testing.expect_value(t, stmt_col_type(&sel, 0), Column_Type.Blob)
	testing.expect_value(t, len(stmt_col_blob(&sel, 0)), 0)

	testing.expect(t, stmt_step(&sel), "row 3 (null blob)")
	testing.expect_value(t, stmt_col_type(&sel, 0), Column_Type.Null)

	testing.expect(t, !stmt_step(&sel), "only three rows expected")
}

@(test)
test_named_parameters :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok, "open in-memory database")
	defer db_close(db)

	testing.expect(t, db_exec(db, "CREATE TABLE t(name TEXT)"), "create table")

	ins, ins_ok := db_prepare(db, "INSERT INTO t(name) VALUES (:name)")
	testing.expect(t, ins_ok, "prepare insert with named parameter")
	defer stmt_finalize(&ins)

	col, found := stmt_param_index(&ins, ":name")
	testing.expect(t, found, "named parameter :name should resolve")
	testing.expect_value(t, col, 1)

	_, missing := stmt_param_index(&ins, ":nope")
	testing.expect(t, !missing, "nonexistent named parameter should not resolve")

	testing.expect(t, stmt_bind_text(&ins, col, "beta"), "bind via resolved column index")
	testing.expect(t, stmt_exec(&ins), "execute insert")
}

@(test)
test_transactions :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok, "open in-memory database")
	defer db_close(db)

	testing.expect(t, db_exec(db, "CREATE TABLE t(x INT)"), "create table")

	testing.expect(t, db_begin(db), "begin transaction")
	testing.expect(t, db_exec(db, "INSERT INTO t(x) VALUES (1)"), "insert inside transaction")
	testing.expect(t, db_rollback(db), "rollback transaction")

	sel, sel_ok := db_prepare(db, "SELECT COUNT(*) FROM t")
	testing.expect(t, sel_ok, "prepare count")
	testing.expect(t, stmt_step(&sel), "row available")
	testing.expect_value(t, stmt_col_int(&sel, 0), 0)
	stmt_finalize(&sel)

	testing.expect(t, db_begin(db), "begin second transaction")
	testing.expect(t, db_exec(db, "INSERT INTO t(x) VALUES (2)"), "insert inside second transaction")
	testing.expect(t, db_commit(db), "commit transaction")

	sel2, sel2_ok := db_prepare(db, "SELECT COUNT(*) FROM t")
	testing.expect(t, sel2_ok, "prepare count again")
	defer stmt_finalize(&sel2)
	testing.expect(t, stmt_step(&sel2), "row available")
	testing.expect_value(t, stmt_col_int(&sel2, 0), 1)
}

@(test)
test_busy_timeout_does_not_break_normal_open :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok, "open should succeed with busy_timeout configured")
	defer db_close(db)
	testing.expect(t, db_exec(db, "CREATE TABLE t(x INT)"), "basic exec should still work")
}

@(test)
test_open_failure_is_reported :: proc(t: ^testing.T) {
	db, err, ok := db_open_err("/nonexistent-directory/odin-sqlite-test.db")
	defer delete(err)
	testing.expect(t, !ok, "open of an unusable path should fail")
	testing.expect(t, db == nil, "failed open must not return a connection")
	testing.expect(t, len(err) > 0, "failed open should describe the error")
}

@(test)
test_lib_version_available :: proc(t: ^testing.T) {
	testing.expect(t, len(db_lib_version()) > 0, "linked SQLite should report a version")
}
