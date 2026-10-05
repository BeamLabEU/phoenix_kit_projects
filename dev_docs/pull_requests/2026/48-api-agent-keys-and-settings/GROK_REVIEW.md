1. `created_by_key` is the right test for `delete_tasks: own` and for who opened the task. It is the wrong test for prose. The person's save is the wording that has to stick.

Stamp `text_edited_by_person_at` on title, description, and each checklist item's text when a person saves that field. An agent PATCH of a stamped field returns 403 `foreign_text`, including when this key created the task. The agent may rewrite only fields no person has saved. `edit_foreign_text: true` is the override, default false.

Notes are stricter. A note a person wrote is immutable to every agent key. An agent may PATCH only a note this key authored, and only until a person edits it. That is the daily-note rule.

2. A token in the description is not an acceptable link. That field is the one both sides rewrite most, and the index is rebuilt from it, so the link is whatever survived the last save.

What breaks: a description PATCH that omits the line returns 200 and the interaction's `tasks` list drops the row. A person saving the form does the same if the line is deleted or the editor strips it. The label in the token goes stale when the interaction is renamed. Deleting the interaction leaves a dead token and no foreign key. Two concurrent description saves: the older body wins and the token vanishes. The agent cannot attach a call without write access to the prose, and cannot rewrite the prose without risking the attachment. A mistyped uuid indexes nothing.

Cheapest fix: persist the `interactions: [uuid]` list you already accept on create as the join. Render `#[crm_interaction:uuid|label]` from that list on read. Ignore tokens in a written description. Add `POST` and `DELETE /tasks/{id}/interactions/{uuid}`. A description PATCH then cannot unlink.

3. With checklist counts and a latest-note excerpt capped near 240 characters, 50 tasks are about 40–70 KB. Uncapped notes push past 150 KB. Cap the excerpt.

Priority then position ranks a backlog. The next action is work already in this key's hands. Return four blocks, in order: `mine` (this key's `in_progress`), `ready` (open, no `waiting_on`, not started by someone else, priority then position), `waiting`, and `done_today` (about ten lines: id, title, done_at, outcome). Done-today belongs in the briefing and outside the 50 open slots, or the agent repeats this morning's work.

The missing field is one object at the top: `resume: { task_id, note_uuid, at, next_steps }` from the latest note this key wrote. The briefing's "latest note" is whoever spoke last.

4. `caught_up` derived from zero open tasks needs no stored timestamp; return `as_of` on the read. If a person can declare it while work remains, store `caught_up_at` and `caught_up_by`, and clear both when an open task appears.

The parent row should say `caught_up`, or `ongoing` with `open_count: 0`. `in_progress` at 100% reads as nearly complete and will roll up that way.

On an ongoing project, do not offer a complete action, a Start/End control, a percent bar, or an ETA that any completion rule reads. A review cadence is fine. A caught-up child leaves the parent ongoing. Copying `manual` onto new sub-projects is the right default.

5. An outside agent key should not change a person's billable minutes or delete their rows. The token sits in a model that also reads client text, so a note or an interaction can instruct the write. The before/after feed records it afterward.

With `amend_own_ledger`, an agent key may PATCH minutes, estimates, and token/cost only on rows this key created, and may soft-delete only those rows. Rows whose actor is a person stay read-only on this API. A manager correction is a separate capability and should append an adjustment that names `amended_by`, leaving the original minutes in place. Tokens and cost on the agent's own rows should be amendable; they are estimates.

6. The miss is permanent. Once-a-minute polling makes it uncommon for human edits and ordinary for the agent's own burst: it writes, then polls with a `now` in the same second, and strict `>` skips those rows. The next poll starts later, so nothing brings them back.

Cheapest fix: request `updated_since` one second behind the previous `now`, and drop uuids already applied at that `updated_at`. Duplicates are safe if apply is by uuid. Next time you touch the column, use a keyset `(updated_at, id)` at microsecond precision. Bump `updated_at` on checklist ticks and new ledger rows, or those changes never appear in the poll.

7. Do not ship amendment or deletion of another person's ledger rows on this API. Ship append of the agent's own usage, and leave timesheet corrections to a person.

The agent hits the resume gap on the first call after a reset. The briefing has no `resume.next_steps` for this key, so it takes the highest-priority task: one it cannot take (`409 already_started`) or one it already started.
