# PR #62 — the projects chain on a fresh core 3.x database: review record

**Author:** Max Don
**Reviewer:** Claude (Opus 5.5), 2026-11-05, reviewed and merged over `3466c40` (`main` with #61's fixes)
**Method:** read the staff, entities and document_creator chains the PR calls or copies, audited this chain's
foreign keys and cross-table reads, then replayed the chain on empty databases, old code against new.
**Verdict:** the fix is right. One MEDIUM bug fixed, and the headline fix given the test it lacked.

## The merge

Both PRs appended to the same place. `up/1` runs `v30_holder_assignees/2`, then `document_creator_project_fk/2`.
The test file keeps both PRs' aliases, with #61's `import` moved above them. One interaction exists only after
the merge: V30's backfill leaves deferred foreign-key events pending when the key's `ALTER TABLE` runs in the same
transaction. Tried with real rows through a throwaway test: it passes, because those events sit on the assignee
tables and the `ALTER` touches neither.

## Findings

- **BUG - MEDIUM: a full `down/1` failed once the key was there.** `up/1` adds a key pointing at
  `phoenix_kit_projects` and `down/1` drops that table without `CASCADE`: "cannot drop table phoenix_kit_projects
  because other objects depend on it". → **Fixed** (`9f1ab46`): `down/1` takes the key off first and leaves
  document_creator's table and column. Test: `migrations_schema_test.exs`, "a full down takes document_creator's
  key off, and keeps the documents".
- **IMPROVEMENT - MEDIUM: the headline fix had no test.** `test_helper.exs` builds staff's and entities' tables
  itself, so neither the boot nor the PR's two tests depend on `run_dependency_chain/2`: with both calls removed,
  the migration tests still pass. → **Fixed:** "the chain builds staff's and entities' tables when they are
  missing" drops two of them in the sandbox and asks the chain. It is the one test there that fails with the calls
  taken out.
- **NITPICK: `test_helper.exs` runs entities' chain twice,** in the list and again in a guarded block. Older than
  this PR, harmless. Left.
- **NITPICK: `AGENTS.md`'s dependency line is stale,** older than this PR but at odds with its premise: it says
  `phoenix_kit >= 2.64.0 and < 3.0.0`, `ai ~> 0.18`, `comments ~> 0.3`, `staff ~> 0.8`, `entities ~> 0.3`, where
  `mix.exs` has `>= 2.65.0 and < 4.0.0`, `~> 0.27`, `~> 0.5`, `~> 0.11`, `~> 0.7`. Left for the maintainer.

## The PR's claims, checked

- **A fresh database failed, and now builds:** an empty database, core's chain, then this chain alone. Before the PR
  it fails and builds nothing; after it, the 9 staff and entities tables appear and all three markers are stamped
  (`pkp_schema:30`, `pkstf_schema:1`, `pkn_schema:1`).
- **The foreign-key list is complete:** every target outside this chain is staff's, entities', or core's
  `phoenix_kit_users` / `phoenix_kit_files`, and core 3.3.0 still creates those two. Neither chain points back here.
- **document_creator's "exact definition":** matches its chain, name and `ON DELETE SET NULL`.
- **`WITHOUT_STAFF=1`:** compiles with warnings as errors, the staff dep absent.
- **"4 failures on upstream main":** not reproduced. With the compile fixed, `main` ran 2756 tests, 0 failures.
- **`mix precommit` stopping at `hex.audit`:** not reproduced. After the `libs` lock bump it passes.

## Open

**`BeamLabEU/phoenix_kit_staff#24` was merged but not released at this merge.** This review first said it was still
open, which was wrong: that came from a check at 13:44 UTC, it merged at 13:46, and #62 merged at 14:24. The PR asks
for it to be released first. It did not matter yet, since the pinned staff 0.11.0 is at V1, but a host's older staff
file running after this chain could lower staff's marker once staff ships a V2. Staff 0.11.1 carries the guard, and
`mix.exs` now requires it.
