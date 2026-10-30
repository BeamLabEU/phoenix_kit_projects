# PR #58 — Codex review

Reviewed 2026-10-30 against `5ea8d52`, after merge `2a10448` and PR #59.
Author: Max Don. Scope: the permission sub-keys, backfills, moderation,
library writes, and the forms' write/translation hooks. Existing Claude
findings and their follow-ups were checked alongside the current callers.

## Findings

### BUG - HIGH — Parent changes bypassed the current project permission

`AssignmentFormLive` changes an edited task's parent immediately from
`validate` through `maybe_move/2`. That event is outside `WriteGate`'s write
list, and its local `may?/2` check used the project settings loaded at mount.
After an owner tightened `edit_tasks` to managers, an existing member's form
could still move the task and its branch, even though its autosave was refused.

Fixed: this immediate write asks `WriteGate.allowed?/1`, which reads the
current project and scope, before moving anything. A LiveView regression
tightens the project's floor after mounting and verifies that the crafted
parent change is refused and the stored parent remains unchanged.

### BUG - MEDIUM — Revoked permission trapped an open translation dialog

`AITranslateGate` checked `ai_toggle_modal` in both directions. Revoking the
form's write permission while its translation dialog was open therefore
refused Cancel, Escape and backdrop clicks as well as opening it.

Fixed: an already-open dialog may always close. Opening it and translation
writes still require permission. A LiveView regression opens the dialog,
revokes access, closes it, and verifies that reopening remains refused.

## Validation

Validation results are recorded in `FOLLOW_UP.md`. No release changes.
