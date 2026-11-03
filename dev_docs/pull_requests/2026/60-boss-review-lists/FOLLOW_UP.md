# Follow-up — PR #60

2026-11-03: how Claude's findings (`CLAUDE_REVIEW.md`) were resolved. Each entry there says "Fixed" with
its test, or "not fixed / recorded" with the reason. In short:

- **Fixed, with a test that fails when the fix is reverted:**
  - CRITICAL: the editor's stored XSS.
  - HIGH: the sub-project short editor; the cover's stale settings; pictures invisible to members.
  - MEDIUM:
    - the API's shared-key file URLs;
    - the overlay markup;
    - pictures and the cover past the write gate;
    - a repeat completing its project;
    - the sub-project row's notice;
    - the next-up dialog's disclosure;
    - repeats in UTC;
    - the Unicode-digit crash;
    - the direct staff call;
    - trashed and forged assignees;
    - the site defaults on the new-project form.
  - IMPROVEMENT: the batched row pictures.
  - Older bugs: the task form's unfiltered keys (HIGH), its status right (MEDIUM), cross-project
    dependencies (MEDIUM).
- **Fixed, no test:**
  - the project Calendar's zone: the fixtures cannot set a viewer zone;
  - the assignee-set lock: a two-transaction race.
- **Left, with the reason on record:**
  - task→sub-project reopening a started task: needs a decision;
  - Back dropping drawer edits and the subtask links leaving: JS work that needs a browser to verify;
  - the improvements and nitpicks marked "recorded".

## Validation

- `mix test` against an isolated PostgreSQL 18 (no tests excluded): **2725 tests, 0 failures** (baseline at
  `5a58c7f`: 2694 tests, 0 failures).
- `mix precommit`: green, with the same seven Dialyzer entries the ignore file skips at baseline.
- `WITHOUT_STAFF=1 mix compile --warnings-as-errors` (isolated build path, `mix.lock` restored): green. Before
  the staff-link fix, `ProjectShowLive` called `PhoenixKitStaff.Paths` directly.
- Every new test was run against the code with its fix reverted, and failed.
- Gettext: one new msgid ("must be a task of the same project"), translated in all seven locales. A full
  `gettext.extract` + `merge` would also prune about a dozen msgids the code no longer uses, and rewrite most
  reference lines that were already stale. That cleanup is left out of this commit to keep it reviewable.
- Environment note: core's `PostgresPreflight` calls `Postgrex.Protocol.connect/1` directly, so it ignores
  `PGPORT`. A test database on a non-default port has to be reached on 5432 at another loopback address.
