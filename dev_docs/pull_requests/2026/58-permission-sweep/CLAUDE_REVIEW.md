# PR #58 — permission sweep: review record

**Author:** Max Don (with Claude)
**Reviewers:** codex (both rounds); findings checked against the code by Claude before fixing
**Verdict:** every confirmed finding fixed in this PR, each with a test that fails when the fix is reverted.

The sweep's rules: a sub-key `<base>.<sub>` is checked with `Scope.can?/2` in `mount/3` and every write
event against the live scope; new sub-keys are backfilled once to current base-key holders, with the
flag set only after every grant succeeded. Round 1 reviewed the whole change, round 2 only the fixes.

## Findings

- BUG-HIGH — a `manage_library` holder could delete or promote a private project's one-off from TasksLive → fixed: the project's own rule on every project using it.
- BUG-HIGH (round 2) — the same through the task form (`ad_hoc: false` promotes) → fixed: `:edit_tasks` on open and save; every other task-by-uuid path checked.
- BUG-MEDIUM — outline rename trusted a cached right; the one-off lens scope was computed at mount; library writes worked with the module off → fixed.
- BUG-MEDIUM — every backfill (the older `admin_all` / API-key ones too) could set its flag after a failed lookup or grant → one fail-closed `backfill_sub_keys/3`.
- NITPICK — a fixture test asserted over its own fake scope → replaced.
- BUG-HIGH (found while gating the AI-translate modal) — `TemplateFormLive :edit` loaded and saved any project id, so a base `projects` holder could edit a real project's settings → it opens and saves templates only, and checks the module key itself on mount.
- BUG-MEDIUM — the assignment and project forms checked their right only at mount → `Web.WriteGate` re-checks the mount right against the live scope (record re-read) on every write event, including the autosave timer and `confirm_action_ok`'s replay. Anonymous embeds of these forms can no longer write.
- BUG-MEDIUM — `AITranslate.Embed` dispatches its six modal events with no permission check → `Web.AITranslateGate` on the task, assignment, template and project forms, using each form's own write right.
