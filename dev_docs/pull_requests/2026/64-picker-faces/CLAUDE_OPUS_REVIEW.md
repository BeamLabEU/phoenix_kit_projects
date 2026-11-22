# PR #64 — follow-ups to the fourth list: review

**Author:** Max Don
**Reviewer:** Claude (Opus 5.5), 2026-11-22. Reviewed on the PR head (`5ce84bf`) merged locally into `main`,
against core 3.7.0 from Hex (it carries #1051's `can_remove`).

`CLAUDE_REVIEW.md` in this folder is the author's own record and stays as it is.

## Verdict

Sound. Each item does what the description says, and the risky ones hold up when checked against the code they
lean on. Two small things fixed, three left on record.

## Findings

### NITPICK — a bare `pkp_url_discard` closed a dirty frame without asking (fixed)

`PopupHostLive` had a direct `handle_event("pkp_url_discard", …)` beside the `confirm_action_ok` branch that the
"Close without saving?" dialog actually uses. Nothing in the UI sends the bare event, so its only effect was to let
a crafted one skip the question this PR adds. It only affects the viewer's own unsaved state, so this is not a
security issue, but "Back asks first" should hold every time. Removed: the catch-all `handle_event/3` ignores it.
`task_in_url_test.exs` now sends it bare while the frame is dirty and asserts that nothing closes.

### NITPICK — a test kept checking an event that no longer exists (fixed)

`review48_lv_test.exs` "the comments drawer opens only on this project or one of its tasks" still sent
`open_comments` and refuted `aria-label="Comments"`. With the popup gone, every assertion passed whatever the page
did. It is rewritten as "the removed comments popup's event opens nothing": the crafted event, for another
project's thread and for a foreign task, draws neither that uuid nor a `comments-drawer-` component.

### NITPICK — the picker's faces cost one more read per chip, and load whole accounts (left)

`PeopleSource.describe/2` now adds a `users_by_*` query to every described key. Core's picker describes each
selected key one at a time (`describe_selected/1`), so a picker that mounts with N chips makes about 2N reads
instead of N. It also loads whole `%User{}` rows. They stay server-side in the component's assigns, so nothing
leaks, but they are wider than `user_avatar` needs. Left as it is: a task has a handful of assignees, the rows are
cached in the picker, and the real fix is a batched `describe` in core's `Source` behaviour.

### NITPICK — a pasted quick add is recorded like the outline's paste (left)

`quick_add_lines/3` logs one `projects.task_list_edited` row (`created: N`) instead of one
`projects.assignment_created` per task, so these tasks have no "created" line in their own History. The outline's
own paste (`paste_lines/5`) already works this way, and this PR set out to match it. The reply's `last` is the raw
title, not the whitespace-collapsed one `Outline.sync` stores, which only matters for the note under the field.

### Checked, nothing to change

- **Back over unsaved changes, in the browser.** I suspected a double history entry: the hook's `updated` and the
  `pkp_url_restore` handler could both `pushState`. They can't. LiveView 1.2.15 calls a hook's `updated` only when
  `!fromEl.isEqualNode(toEl)` (`view.ts` `triggerBeforeUpdateHook`), and the hook element is unchanged while the
  question is up (`data-task` still names the frame). So only the restore pushes. "Discard" then empties
  `data-task`, and `updated` goes back over the restored entry (`state.pkpTask`), just as a clean Back does.
- **The quick add through `Outline.sync`** cannot reopen, remove or reparent anything:
  - the existing lines carry no `"done"` (it is read for new lines only);
  - `known` is `[]`, so no row counts as removed;
  - `socket.assigns.assignments` is the whole accepted list, not the lens (`visible_assignments` is separate), so
    `Outline.walk/1` gives every row its real depth;
  - an expanded sub-project's children live in `subproject_child_tasks`, so their ids never reach the lines.

  `@max_lines` is 2,000.
- **The notify list.** `handle_info({PeoplePicker, id, {:changed, keys}}, …)` asks `may_assign_now?/2` only when
  `keys -- defaults` is not empty, so a removal never needs the right to assign.
- **Ids in the task form.** Nothing matches a picker by its id: `AssigneeField.handle_info/3` and the form's clause
  take `_id` and answer with the same id. `waits-on-*` has no reader in the JS.
- **Admission opts.** In `update_assignment_form/3` and `create_task_with_assignment/4`, `opts` reaches only
  `Members.admit_assignees/3` (plus `:admit` / `:broadcast`). So the new `actor_uuid` and `source: "api"` change the
  `member_added` row and nothing else. No other caller passes `source:` there.
- **The side panel.** `side_panel_wide` accepts only a boolean. After a reconnect the new process starts narrow, and
  the hook's `reconnected` sends again. An embed whose host does not load `PhoenixKitProjectsHooks` would leave the
  panel empty, but the outline has the same dependency, and `js_sources/0` wires the bundle.

## Gate

See `FOLLOW_UP.md`.
