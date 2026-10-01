# Follow-up Items for PR #46

Triage of `CLAUDE_REVIEW.md` against the current code on `main`
(2026-10-01). The review raised three nitpicks; one was fixed post-merge, the
other two were left by the reviewer and are still live.

## Fixed (pre-existing)

- ~~**NITPICK — Doc comment stranded above the wrong function**~~ — the
  "Which assignee `<select>` is active…" comment sits directly above
  `assignee_kind/1` again (`web/assignment_form_live.ex:519-524`), below the
  crumb helpers. Commit `93f0809`.

## Files touched

None — documentation only.

## Verification

- Read `web/assignment_form_live.ex` around `child_crumbs/2` and
  `assignee_kind/1`.
- Read `attachments.ex` `ensure_folder/2` and `folder_uuid/2`.
- `git log --grep "#46"` for the fix commit.

## Open

All awaiting Max's decision.

- **NITPICK — Sub-project edit crumb is not `Authz`-filtered.**
  `web/assignment_form_live.ex:505-506` — `child_crumbs/2` links the linked
  child project unconditionally, while `Crumbs.project/3` drops ancestors the
  viewer cannot `:view`. The review judged it not a new exposure (the name was
  already the page title, and the form edits the child's fields).
- **NITPICK — `ensure_folder/2` rescues but does not catch `:exit`.**
  `attachments.ex:180-184` — `folder_uuid/2` catches `:exit`
  (`attachments.ex:154-161`), `ensure_folder/2` only rescues. Same as before
  the PR; core's `ResourceFolders.ensure/4` guards its own DB work.
