I've now read all the relevant code. One note on method: this session has no Bash/Write tool available, so I could not execute a scratch `.exs` — the `remove_rows` case below is instead a line-by-line hand trace of deterministic list logic, with every line quoted so it can be checked mechanically.

---

# Review: phoenix_kit_projects — subtasks/outline (V23) + Part B

## 1. `Outline.sync/4` and `write_order/2`

### 1-A. CRITICAL — deleting a parent's line cascade-deletes a child the user kept

`do_sync` runs the deletions **before** the re-nesting that is supposed to move kept children out from under a deleted parent:

`outline.ex:613` → `outline.ex:622-623`:
```elixir
    {removed, held} = remove_rows(gone, rows, listed)
...
    order = lines |> nest() |> weave(unlisted, rows)
    write_order(project.uuid, order)
```

`remove_rows` hard-deletes with a bare `delete_all` — `outline.ex:806`:
```elixir
      from(a in Assignment, where: a.uuid in ^delete) |> repo().delete_all()
```

…under a column declared `ON DELETE CASCADE` — `migrations/schema.ex:1134-1135`:
```elixir
    ALTER TABLE #{p}phoenix_kit_project_assignments
      ADD COLUMN IF NOT EXISTS parent_uuid UUID
        REFERENCES #{p}phoenix_kit_project_assignments(uuid) ON DELETE CASCADE
```

The decision logic explicitly does **not** pin a parent whose child stays listed — `outline.ex:776-784`:
```elixir
        # A child that stays listed is moved out from under it by the
        # nesting; one that is held, or was held before, pins it.
        pinned? =
          Enum.any?(children, fn child ->
            MapSet.member?(hold, child.uuid) or
              (child.review_status == "removed" and not MapSet.member?(listed, child.uuid)) or
              (not MapSet.member?(gone_uuids, child.uuid) and
                 not MapSet.member?(listed, child.uuid) and
                 child.review_status == "accepted")
          end)
```
A listed child fails all three clauses (it is listed), so it doesn't pin; and `protected?/2` (`outline.ex:830-837`) is only evaluated for the **parent**, and `carrying/1` is only computed for the **gone** uuids (`outline.ex:764`) — nothing about the child protects it.

**Failing scenario (hand trace of `remove_rows`, code quoted verbatim above):**
1. In the text list, type `Parent`, Enter, Tab, `Child` (both become ad_hoc, todo, no owner — the default for typed lines). Assign Child to a person in its form; log 2h on Child.
2. Delete only the `Parent` line (select its text, Delete). The debounced `outline_sync` sends `lines = [C]`, `known = [P, C]`.
3. `gone = [P]` (accepted, non-sub-project, in `known`, not listed). `remove_rows`: `children(P) = [C]`; `pinned? = false` (C is listed); `protected?(P) = false` → `delete = [P]`.
4. `repo().delete_all` removes P → the FK **CASCADE deletes C**, whose line the user kept. C's work entries hit `migrations/schema.ex:612` `assignment_uuid UUID REFERENCES ... ON DELETE SET NULL` — **2h of logged time silently detached from any task**; its comments orphan; its ad_hoc `Task` row is never cleaned (only `gone` rows' tasks are, `outline.ex:803-815`).
5. `write_order` then re-reads `current` — C is already gone, so re-nesting it "out from under" P never happens. The reply reports `removed: [P]`; the next server push drops C's line. If the user keeps typing, the next sync sees C's id absent from `by_uuid` and **creates a new task with C's text** (new uuid, new number) — identity lost.

What should happen: `remove_rows` must reparent-or-judge every row under a deleted parent *before* the `delete_all` (or delete children explicitly through the same decision, or set `parent_uuid = NULL` on listed children first). The comment at `outline.ex:776-777` describes an ordering the code does not have.

### 1-B. Checked, sound — the other identity/scope attacks
- Repeated ids: the hook dedupes (`phoenix_kit_projects.js:259-271`) *and* the server re-dedupes — `outline.ex:647` `if is_binary(id) and Map.has_key?(by_uuid, id) and not MapSet.member?(seen, id), do: id` — a second occurrence becomes a fresh task, never a shared id.
- An id from another project / a pending / rejected id: not in `by_uuid` (rows are this project's accepted+removed, `outline.ex:577-580`) → normalized to nil → a new task; the foreign row is untouched.
- Sub-project link rows can never be `gone` (`outline.ex:609` `is_nil(row.child_project_uuid)`) and an emptied sub-project line is kept (`outline.ex:654`); a sub-project child pins its parent via the third `pinned?` clause.
- A held child (this sync or a previous one) pins the parent (`outline.ex:780-781`) — the cascade only bites listed children (1-A).
- Two concurrent syncs are serialized by `with_project_lock` (`outline.ex:422-429`, `SELECT ... FOR UPDATE`); the second sync re-reads rows inside the lock, and tasks it never knew are `unlisted` → woven back (`outline.ex:885-907`), not deleted, because `gone` requires `known` membership (`outline.ex:610`).
- No-delete-right browsers: `outline_list.ex:221` sends `known = []`, so nothing omitted is ever taken as removed.
- Cycles: `nest/1` parents are always earlier lines (`outline.ex:870-879`), `weave` keeps only pre-existing (acyclic) parents, and the DB trigger (`schema.ex:1157-1163`) backstops.

### 1-C. Minor — an unlisted middle child can lose positional contiguity
`weave/3` puts each unlisted row after "the row that preceded them" in **server** order (`outline.ex:1000-1002`), not after its parent. Server order `[P, C1, R]` with lines `[P, Q, C1]` (R unlisted, parent P): R is woven after C1 but P sits at index 0 with Q between — R's `parent_uuid` still names P while its `position` sits inside Q's branch. `walk/1` renders it correctly (structure is `parent_uuid`), but every position-only reader (gantt/schedule layout) shows it detached, contrary to the moduledoc's "a parent is followed by everything under it" (`outline.ex:7-9`). Edge case; no data loss.

## 2. The tick rules from every status path

### 2-A. HIGH — the form's Status select and its Subtasks box never recompute project completion

Every page/API path re-extracts `sync_project_completion` at the call site (`project_show_live.ex:1172-1174` `maybe_sync_and_reload`, `:3235` for the slider, `tasks_controller.ex:1068`), but the two **form** paths call the context and stop:

`assignment_form_live.ex:2405` (autosave of the status select — `Assignment.changeset` casts `:status`, `schemas/assignment.ex:161`):
```elixir
    case Projects.update_assignment_form(socket.assigns.assignment, attrs) do
```
…and `assignment_form_live.ex:1080-1082` (the Subtasks box tick):
```elixir
      if sub.status == "done",
        do: Projects.reopen_assignment(sub),
        else: Projects.complete_assignment(sub, Activity.actor_uuid(socket))
```
Neither `autosave_now` (2387-2446) nor `subtask_toggle` (1076-1089) calls `recompute_project_completion`, and `update_assignment_form`/`update_assignment_status` don't either (grep: the only form-path call is `assignment_form_live.ex:1800`, the *sub-project* save).

**Scenario:** a project ("ends when its last task is done") whose last open leaf is a subtask. Open that subtask's form, switch Status to *Done*, close. The row is done, `settle` runs, but the project's `completed_at` stays `nil` — no `:project_completed`, no activity row, and no rollup onto the parent project's linking row (`propagate_rollup_to_parent`) until some *other* status change happens anywhere in the tree. An open project page doesn't save it either: its `handle_info(:assignment_updated…)` only reloads assignments (`project_show_live.ex:530-543`), it doesn't recompute. Same miss via the form's subtask checkbox. (A parent auto-ticked by `climb` itself doesn't need a recompute — `decide_completion` counts leaves only, `projects.ex:2817` — so the callers' recompute is the only missing piece.)

### 2-B. MEDIUM — a reopen through the form's select leaves stale completion fields
`Assignment.changeset/2` casts `:status` but not `completed_at`/`completed_by_uuid` (`schemas/assignment.ex:161-170`, `@server_only`), and `update_assignment_form` doesn't clear them. **Scenario:** task is done (`completed_at` set, `completed_by` = Max, slider 100). In the form, switch Status to *To do* → autosave writes `status: "todo"` only. The row now reads To do with `progress_pct: 100` and a completion stamp; `caught_up_since` (`projects.ex:4344-4351`, `max(completed_at)`) and the row badges are wrong until someone re-ticks it. Every other reopen path (`project_show_live.ex:2079-2084`, `reopen_assignment`, the API) clears all three. Related: on this path `settle` is passed `updated.completed_by_uuid` = nil (`projects.ex:4393`), so a parent auto-ticked by the climb gets `completed_by_uuid: nil` — the "who" is lost.

### 2-C. LOW — two concurrent ticks can leave the parent unticked
`Outline.settle` reads `shape()` with no lock (`outline.ex:258-265`, `climb` at `269-291`), and `update_assignment_status` doesn't take `with_project_lock`. Two users tick the last two subtasks of the same parent at the same time: each reads its snapshot before the other commits, each sees one open sibling, `Enum.all?(& &1.status == "done")` is false for both — the parent never auto-completes, and nothing ever retries. (Ticking the parent later fixes it; but per 2-A no recompute runs to notice.)

### 2-D. Checked, sound — the rest
- Page `complete`/`reopen`/`start_task` (`project_show_live.ex:2040-2092`) → `maybe_sync_and_reload` → `sync_project_completion` ✓; the `outline_tick` handler delegates to exactly those events (`:1810-1819`) with the confirm-when-others' subquestions flow (`open_below`, `:1114-1136`) and reverts the box when asked (`js:831-840`).
- Board drag delegates to the same three handlers (`project_show_live.ex:1915-1922`).
- Slider at 100/0 goes through `update_assignment_status` with full completion attrs and recomputes when the status flipped (`:3194-3237`).
- API transitions use the same context functions and then `sync_project_completion` (`tasks_controller.ex:1054-1074, 1105-1134`), reporting `also_changed` from before/after status maps ✓.
- `reopen_above` sets `in_progress` even when the project's `in_progress` feature is off (`outline.ex:306-317`) — noted in the question; it renders fine (only the *Start* button is feature-gated) and `status_options` keeps the state selectable (`assignment_form_live.ex:2660-2665`), so I rate it semantics, not a bug.
- One caveat worth knowing: `settle_outline` rescues and swallows all errors (`projects.ex:4402-4405`) — the tick stands but the outline rules silently don't run; only a log line.
- Board drag of a top-level card that has subtasks: `reposition_from_drop` re-inserts only the card's uuid into the flat list (`project_show_live.ex:1898-1902`) — its subtasks keep their old positions, so position order is temporarily torn (structure intact). The list DnD doesn't have this (`keep_outline`, `:801-808`).

## 3. The V23 migration under chain replay

### 3-A. The re-run is safe *except* it re-runs the renumbering walk
Because `up/1` replays v19 first, `checklist` always exists again when v23's DO block runs, so the early `RETURN` never fires within a full-chain pass (`schema.ex:1219-1226` checks column existence; `schema.ex:1645` re-added it with `DEFAULT '[]'` ten steps earlier). The conversion loop selects nothing (all rows `'[]'`), but the `WITH RECURSIVE walk … UPDATE … SET position = ordered.n` (`schema.ex:1269-1291`) **executes again** and rewrites `position` for every project that has subtasks. It is rank-preserving **while** the depth-first invariant holds; it silently re-imposes depth-first order over an arrangement that violates it (a board-dragged parent whose branch was left behind positionally, per 2-D). So: a re-run *can* change data in that corner. Everything else in v23 is replay-safe (`ADD COLUMN IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION` + drop-trigger-then-create, drop-then-add constraint, idempotent `ALTER … TYPE VARCHAR(500)`), and the checklist guard does prevent double conversion of real data.

### 3-B. Trigger vs out-of-order multi-row INSERT — latent, misleading
`schema.ex:1165-1173`: the parent is looked up with a plain `SELECT`; a child row listed **before** its parent in one `INSERT … VALUES` statement fires the trigger while the parent doesn't exist yet → `proj` is NULL → `IF hops = 0 AND proj IS DISTINCT FROM NEW.project_uuid` raises **"the parent task is in another project"**. No current code path does multi-row assignment inserts with parents (sync and `batch_create` insert parentless and set parents via `UPDATE`), so this is a trap for future `insert_all` use, not a live bug — but the error name will point someone at the wrong cause.

### 3-C. Trigger vs cascade delete
The trigger is `BEFORE INSERT OR UPDATE` only (`schema.ex:1189-1191`), so it never interferes with `ON DELETE CASCADE` — correct for the migration's own conversion (children inserted under existing parents) and for `Projects.delete_assignment`, and it is exactly what makes finding 1-A possible. Cycle detection on `UPDATE` is sound for swaps because `write_order` clears-then-sets (`outline.ex:397-399`).

### 3-D. `down_v23` restores a usable V22 shape — with two caveats
Dropping `parent_uuid` promotes subtasks to top level (rows kept ✓); but (1) converted subtasks keep their checklist-ordinal positions (1,2,3…) which collide with the parent's own position — no renumber on the way down, so ordering degrades to the `inserted_at` tiebreak; (2) `DELETE … WHERE review_status = 'removed'` (`schema.ex:1310`) hard-deletes held rows — with their hours `SET NULL` — which is a data-losing down for rows that carry work (acknowledged in the comment; fine for scratch schemas, worth knowing otherwise). The checklist comes back **empty** — the conversion is one-way.

## 4. The API (tasks_controller, outline/api.ex, json.ex, briefing)

### 4-A. MEDIUM-HIGH — cascade delete bypasses the agent policy for held rows
The policy is checked over `below/1` — `tasks_controller.ex:837-840`:
```elixir
  defp below(%Assignment{uuid: uuid, project_uuid: project_uuid}) do
    under = project_uuid |> Outline.shape() |> Outline.descendants(uuid) |> MapSet.new(& &1.uuid)
    project_uuid |> Projects.list_assignments() |> Enum.filter(&MapSet.member?(under, &1.uuid))
  end
```
Both `Outline.shape` and `list_assignments` see **accepted** rows only. But `Projects.delete_assignment` deletes the subtree from *all* rows — `projects.ex:4531-4537`:
```elixir
    below =
      from(x in Assignment,
        where: x.project_uuid == ^a.project_uuid,
        select: %{uuid: x.uuid, parent_uuid: x.parent_uuid}
      )
```
**Scenario:** policy `delete_tasks: "own"`; under the target task sits a *held* subtask (`review_status: "removed"`, e.g. held earlier by a person's list edit) that this key did not create. `DELETE /tasks/{id}?cascade=true`: `below` omits it, so `Enum.all?(below, &Json.may_delete?…)` (`tasks_controller.ex:799`) passes, and `delete_assignment`'s subtree walk hard-deletes the held row — with its hours `SET NULL`. The guide's claim "each must be one the policy lets you delete" (`docs.ex:577`) is false for held rows, and `also_deleted` understates what went.

### 4-B. Checked, sound — scoping, caps, idempotency
- `parent` on create/PATCH resolves through `parent_of` which demands same-project + accepted + `child_project_uuid: nil` (`tasks_controller.ex:126-158`) — no cross-project parent, no sub-project-row parent; `move`/`batch` validate the same way, and `fetch/2` rescopes to the task's own project *before* feature/role gates (`:1145-1173`), so a key can only parent/move within a project it can write.
- Caps: batch ≤ 500 (`outline/api.ex:129`), sync's list is page-only, rate limit in the auth plug; `Json.idempotent` wraps create/update/move/batch (`:268, :348, :855, :922`).
- `batch_create` runs under the project lock in one transaction, nests by clamped depth, anchors after the parent's last descendant, reopens a done parent via `settle_placed` (`outline/api.ex:183-234`); a sub-project parent is refused by `parent_change` upstream.
- `briefing_controller` is read-scoped (`:view`) and its outline data comes from `Outline.Api.info` on the key's project only.

## 5. The PkpOutline hook

### 5-A. LOW — paste onto a locked line aborts *after* mutating the DOM
`phoenix_kit_projects.js:747-749`:
```javascript
      this.remember();
      var at = c.collapsed ? c.start : this.deleteRange(c);
      if (!at.line || this.locked(at.line)) return;
```
Select from a sub-project row (locked) across several task lines, paste: `deleteRange` has already removed the middle lines and trimmed the last (`js:404-411`), then the paste returns with no `changed()`, no sync, no message. The lines vanish from the screen and are neither saved nor restored until the next remote push/blur-flush of *other* changes (self-healing because the server never heard it). Should either bail before mutating or still call `changed()`.

### 5-B. LOW — an unsaved line jumps to the top when its neighbour disappears
`js:1011-1012`:
```javascript
        var after = local.after && local.after.isConnected ? local.after : null;
        self.root.insertBefore(local.el, after ? after.nextSibling : self.root.firstChild);
```
A local (unsynced, typed) line whose preceding line was removed by a remote update is re-inserted at `root.firstChild`; the next sync then genuinely creates/moves it there — the user's in-progress task teleports to the top. Anchor should fall back to the next surviving sibling, not the top.

### 5-C. LOW — `known` grows without bound
`applyRemote` adds every incoming id (`js:987`) and only `reply.gone` prunes (`js:947-952`); ids dropped by remote pushes (`byId` leftovers removed at `js:1001-1004`) are never pruned from `this.known`. A page left open for weeks carries every task it ever saw into every sync payload. Harmless to correctness (a hard-deleted row isn't in `rows`, so it can't be "deleted again"; a held row is excluded from `gone` by `review_status == "accepted"`), but it's unbounded and makes `known` semantically "everything ever seen", not "what the browser shows".

### 5-D. Noted — undo versus the server
`restore()` resends lines whose tasks the server has since deleted or renamed: a deleted task's id is unknown to `sync` → silently re-created as a **new** task with the same text (identity/number change, `outline.ex:646-647`); a task renamed remotely is renamed *back* to the snapshot text by `rename_lines`. Both are defensible "undo is local" semantics, but the re-create-one is silent and could surprise. `Cmd+Z` also does not snapshot ticks (`tick()` calls `changed()` without `remember()`), so undo can restore a line whose done flag stays flipped.

### 5-E. Checked, sound — the wrong-id / lost-text core
Every structural edit is intercepted and rebuilt on line elements (`beforeinput` for Enter/Backspace/Delete/undo/format, `keydown` for Tab/Alt-arrows/Cmd+Enter, dedicated `paste`/`cut`/`copy`, `drop` prevented — `js:474-567, 641-692, 696-790`); a browser-made split that duplicates an id is deduped twice (`normalize`, `js:259-271`, keeps the id on the first half; server `normalize_lines` re-dedupes); cut/paste round-trips ids only for rows whose id is absent from the list (`js:778-779`) and only when the custom MIME's plain text still matches (`js:743-744`), so a doctored clipboard becomes new text; two tasks are never fused (`deleteContentForward` at line end and `deleteContentBackward` at offset 0 on non-empty lines are prevented, `js:522-556`); `applyRemote` is blocked while `dirty`/`inflight`/`composing` (`js:963-968`), preserves the caret via `keep` when focused (`js:977, 1015`), keeps locally-typed text on the caret's line only when it differs from `orig` (`js:991-995`); a failed sync re-marks dirty and the flush on blur/visibility retries (`js:900-905`).

## 6. Part B

### 6-A. Checked, sound — autosave ordering and lifecycle
`pending_params` is always the newest validate payload and is cleared after each save (`assignment_form_live.ex:2367-2375, 2429`); `close_form` cancels the timer and saves synchronously, staying open on error (`:948-962`); a stale `:autosave` message after close no-ops (pending_params nil, `:2387`); `hold_saved` re-reads the row after every save so the next diff is against current DB state (`:2463-2470`); translations are merged against the in-flight record so other languages aren't clobbered (`:1871-1874`). Remaining (inherent to autosave): a full-form last-write-wins against a concurrent API edit of non-text fields (priority/assignee/status) — only the description/title are guarded by the changed?-checks. One new write on the *validate* path deserves a note: `maybe_move` performs `Outline.move` on a select change (`:1630-1652`) — it is behind the mount-time `:edit_tasks` gate (`:679-680` via `permitted_project`) and updates `parent_task` afterwards, so no repeated-move loop; fine, but it means a `phx-change` is now a structural write, which future editors should know.

### 6-B. Checked, sound — `words_by_key_uuid`
Cleared only when the words actually changed: `split_task_words` returns words only on a real description/translation diff (`:2275-2290`) and `words_changed?` gates the stamp on a title/description change (`:2450-2459`); a priority-only autosave leaves an agent's wording ownership intact (the stated intent). The explicit-save path (`save_edit`, `:2497`) stamps unconditionally, but that path no longer exists for task forms (save == autosave for `kind: "task"`, `:1170-1181`).

### 6-C. Checked, sound — log-time-for-others on every path
- Form: `log_people` is populated only under `:log_time_for_others` (`:241-268`), and `log_actor/1` accepts a picked person only if their key is among `log_people` (`:212-219`); a forged `log_person_pick` with a foreign key finds nothing and the entry lands on the viewer (`:1300-1313`).
- Hours page: `person_options` gates on `for_others` = `Authz.can?(scope, project, :log_time_for_others)` (`project_hours_live.ex:371-393, 936-961`) and `log_actor` validates the submitted person against exactly that list for the project the entry lands on (`:991-1007`); the project itself must be loggable (`log_project`, `:973-980`).
- Project-page dialog has no for-others path at all (always the viewer, `project_show_live.ex:3521`).
- API records as the key itself (`ledger_controller.ex:301-310`, `actor_kind: "ai_agent"`).

### 6-D. Checked, sound — `Hours.search_tasks/4`
LIKE metacharacters are escaped (`hours.ex:744` `String.replace(q, ~r/([\\%_])/, "\\\\\\1")` — backslash-escape is Postgres ILIKE's default), the query is scoped to `project_uuid in ^project_uuids` which the page derives from `visible_project_uuids`/memberships (`project_hours_live.ex:791-798, 336-351`), and a picked task is re-verified to belong to the entry's project on save (`log_task`, `:1012-1018`). One functional (not security) gap: for an `admin_all` viewer on the site-wide page with no project chosen, `project_uuids` is `:all` → `listable(:all)` = `[]` → the task picker answers nothing (`hours.ex:711-712`) — deliberate "never listed whole", but it means the task filter is unusable until a project is picked.

---

## Top 5 to fix first

1. **`Outline.sync` cascade-deletes kept children** (1-A, `outline.ex:613-623` + `:806` + `schema.ex:1134-1135`): removing a parent line hard-deletes a listed child task — with its hours `SET NULL`ed off it — because `remove_rows` runs before the re-nesting its own comment relies on. Silent data loss reachable by one keystroke in the default text list. Fix: reparent listed children (or judge them) before any `delete_all`.
2. **Form status changes never recompute project completion** (2-A, `assignment_form_live.ex:2405` and `:1080-1082`): completing the last leaf via the form's Status select or Subtasks box leaves the project open and the sub-project rollup stale until an unrelated change. Add the `sync_project_completion` call (or move it into the context).
3. **Agent delete policy bypassed for held rows on cascade** (4-A, `tasks_controller.ex:837-840` vs `projects.ex:4531-4537`): `below/1` filters to accepted rows while the delete walks all rows — a held subtask under the target is destroyed without `may_delete?`, contradicting the documented contract.
4. **Form-select reopen leaves `completed_at`/`completed_by`/`progress_pct` stale** (2-B, `schemas/assignment.ex:161-170` + `projects.ex:4090-4103`): a done→todo transition through `update_assignment_form` writes only `status`; every other reopen path clears all three, and the climb driven from this path stamps `completed_by_uuid: nil`.
5. **V23 replay re-runs the renumbering walk** (3-A, `schema.ex:1219-1291`): the checklist guard doesn't gate the walk, so every chain replay rewrites `position` for all subtask-bearing projects — rank-preserving only while the depth-first invariant holds, and board drags can break it (2-D). Guard the walk on the same condition as the conversion (only when the checklist column held data), and consider making `reposition_from_drop` move a dragged card's branch with it.
napshot, so two concurrent last-subtask ticks can leave a grandparent open with its whole branch done** (`outline.ex:260`, `275-278`). Re-read each level (or lock) before ticking upward.
5. **The autosaving form silently reverts concurrent writes** (`assignment_form_live.ex:2397-2405`): full-payload autosaves clobber API/other-tab edits of every field except the on-task description, and re-clear `words_by_key_uuid` as if the person had reworded the text. Generalize the untouched-field drop from `split_task_words` to the whole payload.

Honourable mentions, in order: `nest` parenting under sub-project rows (`1b`), the ignored `Outline.move` result on API create (`4b`), board-drag breaking the depth-first position invariant (`1c`), and the JS undo/`reply.gone` identity race plus unbounded `known` (`5b`, `5c`).
