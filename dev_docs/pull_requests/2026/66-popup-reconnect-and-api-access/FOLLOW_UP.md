# PR 66 follow-up

Regression tests exercise a member's ledger visibility on the project tab and on the site-wide Hours page with and without a selected project. The reconnect test remounts the same task twice to check that its version is stable, then renames the linked task and verifies that the version changes. API tests cover alternate UUID casing and compare the query counts for one and eight inheriting grants, each with a child project.

The full suite passed all 2,998 tests on a freshly migrated PostgreSQL database with seed 101. All 32 JavaScript hook tests passed. The repository's precommit gate and the separate compile with staff excluded both passed.
