# PR 65 follow-up

The merge includes the fixes recorded in the Codex review. Regression tests cover inherited views and listings at a template boundary, restoration of host-issued frames, form isolation between hosts, stale task conversion, recipient-language project titles, and drawers with more members than visible avatars.

## Verification

`mix precommit` passed with the locked Hex dependencies. The full suite ran against a freshly migrated PostgreSQL database with seed 101 and passed all 2,958 tests, including the JavaScript hook suite. A separate build with `WITHOUT_STAFF=1` compiled with warnings treated as errors.
