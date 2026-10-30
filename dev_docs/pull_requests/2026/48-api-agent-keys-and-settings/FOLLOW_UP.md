# Follow-up — PR #48 (2026-10-05)

How each finding in this folder's reviews was resolved. Reviews:
`CLAUDE_REVIEW.md` (the quality-sweep triage, three agents),
`CODEX_REVIEW.md` (codex on the repo, ten numbered questions, after the
first agent round), `GROK_REVIEW.md` and `ZAI_REVIEW.md` (the same sweep's
design critique of the API surface). The two earlier design panels
(the API's shape, keys acting for a person, what an agent needs) are
summarised in `dev_docs/guides/api.md` and AGENTS.md rather than kept
here: they shaped the work rather than reviewed it.

## Fixed (Batch 1 — 2026-10-05, before the PR)

Codex (the repo review) and grok/zai (the surface), taken in the
"panel's sweep" commit and the two after it:

- ~~Wording ownership tracks creation, so a person's rewording could be overwritten by the creating key~~ — `words_by_key_uuid` (V20): the last writer owns the words; the form's save clears it, the API's text edits stamp it; `Json.may_edit_text?/3`.
- ~~A link kept only as a mention token in the description vanished with any rewrite~~ — the task ↔ interaction table (V20), `Projects.link_interaction/4` & co.; the token follows the join, on the one-off task's own description.
- ~~Every task-level action evaluated its feature and role gates against the key's project before `fetch/2` rescoped to the task's~~ — reordered in tasks, ledger and notes.
- ~~`may_take?` guarded only the move into `in_progress`~~ — a claim holds for every move out of it by another actor.
- ~~The checklist tick was read-modify-write with no lock~~ — `Projects.update_checklist_item/3` under `FOR UPDATE`.
- ~~`visible_resource_uuids/2` climbed one hop~~ — it climbs the parent chain.
- ~~`/entries` truncated silently; task entries filtered the newest 500 project-wide~~ — `limit`/`truncated`, task entries by `assignment_uuid`.
- ~~An amendment's trace lacked the key~~ — `:metadata` on `update_time`/`update_amount`/`delete_entry`.
- ~~A billable ledger row could be erased over the API~~ — 403 `billable_entry`.
- ~~`updated_since` lost a same-second change~~ — inclusive, and `now` floored to seconds.
- ~~The briefing ordered by priority then position, with no resume pointer and no done-today tail~~ — mine → ready → waiting, `counts`, `resume`, `done_today`, `caught_up_since`; children summarised in one pass.
- ~~The interaction lookup for a task in a sub-project asked only the task's own project; a bad uuid gave a 201 with no link~~ — the lookup walks up within reach; `POST /tasks` checks first.

## Fixed (Batch 2 — 2026-10-05, the triage, `a858907`)

- ~~BUG - HIGH: the idempotency wrapper could run the work twice (concurrent retries; the rescue's rerun)~~ — `ApiKeys.idempotent/3` reserves the key first (a pending row, `insert_all` counted), a retry in flight answers 409 `in_progress`, the work never runs twice; a 5xx or a raise frees the reservation. Test: a held key answers 409 and creates nothing.
- ~~BUG - HIGH: the CRM's `tasks: [uuid]` linked any task on the site~~ — fixed on the CRM side (PR #42, `d370885`): the list is checked before anything is written, each uuid a task of the project or a sub-project under it (`ProjectsLink.task_project/1` against `subtree_uuids/1`), a non-uuid a 422.
- ~~BUG - MEDIUM: the interaction lookup needed no scope, extension or floor~~ — `interaction_label/2` requires the provider's read scope and, per project tried, the extension on and the `:view` floor.
- ~~BUG - MEDIUM: ledger amend/delete gated on the root before the rescope~~ — `update_entry`/`delete_entry` re-run the `:ledger` feature and the `:log_time` floor after `own_entry/2`.
- ~~IMPROVEMENT - MEDIUM: the agent policy and the Ends select editable by any project editor~~ — both only render for, and fold only for, `can_manage_modules`.
- ~~IMPROVEMENT - MEDIUM: an interaction link in two steps, no lock~~ — `link_interaction/4` runs in one transaction with the task row locked; a token that cannot be written leaves no join row.
- ~~BUG - MEDIUM: the checklist tick broadcast inside the transaction~~ — `broadcast: false` inside, one broadcast after the commit.
- ~~BUG - MEDIUM: a stale checklist pre-check → CaseClauseError; a misspelled `done` unticked~~ — no pre-check, `{:error, :not_found}` → 404, `done` must be true/false (422).
- ~~BUG - MEDIUM: `fold_checklist/3` gave two same-text lines one id~~ — each existing item lends its id to the first line with its text.
- ~~BUG - MEDIUM: a label over 60 characters dropped silently; a non-list `labels`/`checklist` ignored~~ — 422s (`check_labels/1`, `check_checklist/1`), on create and update.
- ~~BUG - MEDIUM: PATCH wrote the text before checking `interaction`~~ — `check_interaction` and the shape checks run before any write.
- ~~BUG - MEDIUM: the labels find-or-create race dropped the loser's label~~ — the loser re-reads the row.
- ~~BUG - MEDIUM: `completion: "bogus"` on `POST /subprojects` ignored~~ — 422.
- ~~BUG - MEDIUM: the create path ignored `link_interaction`'s result~~ — the interaction is checked before the task exists; a failure after is logged.
- ~~BUG - MEDIUM: link/unlink logged nothing; a PATCH of only labels/interaction logged `fields: []`; labels made on the fly had no actor~~ — `log_link/4`; `fields` includes `labels`/`interaction`; `label_opts/1` passes the actor and the API metadata.
- ~~IMPROVEMENT - HIGH: `Json.task` ran `interactions_of` per row~~ — `Projects.interactions_for_assignments/1`, one query for the list.
- ~~NITPICK: hard `{:ok, _} = stamp_assignment` matches~~ — tolerated (`_ =`).
- ~~Stale words (AGENTS.md's `link_assignment_to/5`, "parses the tokens"; the ledger comment)~~ — corrected. `@spec` added on `event_json/1`, `parse_since/1`.

## Skipped (with rationale)

- **`task_notes.ex`'s ledger rows broadcast inside the outer note transaction** — pre-existing (PR #3bd5d1b's design); the nested ledger calls publish after THEIR commit; a failure in `link_entries/2` after them is a rollback the broadcast outlives. Worth a `Repo.transaction` callback (`after_commit`) when the project adopts one; noted in AGENTS.md TODOs.
- **`subproject_state` per nested row and the CRM's `tasks_for_interaction` per interaction row** — nested rows are few per list; the CRM list is capped at 200 and the briefing trims it to five. A batch is easy later (`Projects.project_summaries/1` exists).
- **The seven-fold gate chain, the duplicated ISO-8601 parsing, `{:ok, conn, a}` vs `{:ok, conn}`, `{:halt, conn}` vs `{:error, {status, body}}`** — shape, not behaviour; left for a refactor commit that does only that, so this PR's diff stays about what it does.
- **Broad rescues on the soft cross-app calls and the best-effort briefing sections** — deliberate (a provider from another application, a read that must never 500); each now carries a comment where it was missing one in the diff.
- **The fallback token label `"interaction"`** — only reached when the provider cannot answer, which the lookup now refuses before linking.
- **The CRM's `since` on `occurred_at` vs a server `now`** — documented on the endpoint; a backdated interaction is found through the list without `since`.
- **`project_modules_live.ex`'s silent `handle_info` catch-all** — pre-existing, outside this PR's diff.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_projects/api_keys.ex` | reserve the idempotency key first; never run the work twice |
| `lib/phoenix_kit_projects/projects.ex` | link in one transaction under a row lock; checklist broadcast after commit; `interactions_for_assignments/1` |
| `lib/phoenix_kit_projects/labels.ex` | the race loser re-reads |
| `lib/phoenix_kit_projects/web/api/tasks_controller.ex` | lookup gates; checks before writes; checklist 404/422; link/unlink logged; labels validated with an actor; batched links |
| `lib/phoenix_kit_projects/web/api/ledger_controller.ex` | gates after the rescope |
| `lib/phoenix_kit_projects/web/api/project_controller.ex` | `completion` validated |
| `lib/phoenix_kit_projects/web/api/json.ex` | `task/4` takes the batched links |
| `lib/phoenix_kit_projects/web/project_form_live.ex` | the policy and Ends only for `manage_modules` |
| `lib/phoenix_kit_projects/web/assignment_form_live.ex` | distinct ids for same-text lines; tolerant stamps |
| `test/phoenix_kit_projects/web/api_agent_test.exs` | the refusals, the held key |
| `AGENTS.md` | stale names |

## Verification

`mix precommit` 0 (format, compile --warnings-as-errors, deps.unlock --check-unused, hex.audit, credo --strict, dialyzer); `mix test` 1695 tests, 0 failures. CRM: `mix precommit` 0, 832 tests, 0 failures.

## Fixed (pre-existing) — SONNET review (triaged 2026-10-29)

`SONNET_REVIEW.md` was written after the batches above (post-merge, in
`ca85176`, the commit — not the release-audit folder) and extended in
`bbfd330`. Each finding re-checked against current code; paths under
`lib/phoenix_kit_projects/`.

- ~~BUG - HIGH: the Templates list deletes any project~~ — `web/templates_live.ex:407` matches `%Project{is_template: true}` only. `ca85176`.
- ~~BUG - MEDIUM: `save_redirect` / `adopt_summary` had no authorization row~~ — both `:edit_tasks` in `@event_actions` (`web/project_show_live.ex:2275-2276`); the redirect takes only `summary`/`content` (`:3277`). `ca85176`.
- ~~BUG - MEDIUM: `open_comments` named any record~~ — `comments_target?/3` gate, `web/project_show_live.ex:3255-3268`. `ca85176`.
- ~~BUG - MEDIUM: a crafted `project[settings]` bypassed the manage-modules rule~~ — `web/project_form_live.ex:903-915` drops `settings`; `apply_project_type/4` folds from the project as stored (`:1320-1335`). `ca85176`.
- ~~BUG - MEDIUM: an amendment erased `occurred_at`~~ — `maybe_put_ended_at/3` moves `ended_at` only when the entry has a start (`ledger.ex:299-331`). `ca85176`.
- ~~BUG - MEDIUM: figures past the column were a 500~~ — `WorkEntry` `@max_amount`/`@max_minutes` and the changeset bound (`schemas/work_entry.ex:50-70`); `@max_int`, `@max_task_minutes` 422s (`web/api/tasks_controller.ex:53-55`, `:1470`). `ca85176`, `3621023`.
- ~~BUG - MEDIUM: a note's `refs` of the wrong JSON type crashed~~ — `type_error/1` / `id_error/1` catch-alls, integer id read as text (`task_notes.ex:301-317`). `ca85176`.
- ~~BUG - MEDIUM: sub-project rows could be moved and edited like tasks~~ — `not_subproject_row/1` and the transition guard (`web/api/tasks_controller.ex:362`, `:726-733`, `:1076`). `ca85176`.
- ~~BUG - MEDIUM: `PATCH description` silently lost on a form-made one-off~~ — `description_for_assignment/2` (`web/api/tasks_controller.ex:754-770`). `ca85176`.
- ~~BUG - MEDIUM: `PATCH /tasks/:id` could half-apply~~ — `precheck/3` builds both changesets before any write (`web/api/tasks_controller.ex:371`, `:753`); writes since in one transaction. `ca85176`, `3621023`.
- ~~IMPROVEMENT - MEDIUM: a pending portal submission was reachable by uuid~~ — `fetch/2` 404s a row not `accepted` (`web/api/tasks_controller.ex:1279`). `ca85176`.
- ~~IMPROVEMENT - MEDIUM: ledger corrections ignored the row's scope~~ — `entry_scope/1` (`web/api/ledger_controller.ex:220-239`). `ca85176`.
- ~~IMPROVEMENT - MEDIUM: the `/ext` provider's exception text went to the caller~~ — logged, fixed answer (`web/api/ext_controller.ex:142-150`). `ca85176`.
- ~~BUG - MEDIUM: an abandoned idempotency reservation answered 409 for ever~~ — the age-based takeover the review first added was retracted (`3621023`); closed properly by the session advisory lock (`api_keys.ex:729-761`). `bbfd330`.
- ~~BUG - MEDIUM: a personal key outlived its person's account~~ — `account_live/1` in `resolve/2` (`api_keys.ex:394-420`); `Members.handle_user_deletion/1` revokes (`members.ex:445-448`). `ca85176`.
- ~~NITPICK: `AGENTS.md` said V16, omitted `task_interactions` and the reservation semantics~~ — `AGENTS.md:445-451`, `:655` (now V25). `ca85176`.
- ~~IMPROVEMENT - MEDIUM: the `#` typeahead dropped a root member's sub-projects~~ — `narrow_to_context/2` (`resource_links.ex:367-385`). `ca85176`.
- ~~The four codex-audit findings ("After the codex audit")~~ — takeover removed, PATCH prechecked, rollup clamped, docs name both scopes; triaged in `../ca85176-release-audit/FOLLOW_UP.md`. `3621023`, `bbfd330`.
- ~~NITPICK: client-chosen checklist item ids and `done_at` trusted~~ — N/A: the API's checklists were replaced by subtasks (`e9c85cc`).
- ~~NITPICK: `TasksLive.reorder_tasks` rewrites the global position for a module-only user~~ — now a library write gated on `Authz.manage_library?/1` (`web/tasks_live.ex:297-312`). `13b6a01`. (The `ProjectsLive` half is still live, below.)
- ~~NITPICK: the `Ledger` / `WorkEntry` moduledocs say "append-only"~~ — `WorkEntry` no longer says it; `ledger.ex:284` says "append-only in spirit, so an amendment leaves its trace", which matches the code.
- Partially fixed — **IMPROVEMENT - MEDIUM: every human form save clears `words_by_key_uuid`**: the autosave path clears it only when the words changed (`web/assignment_form_live.ex:2918-2925`, `words_changed?`, `7398e67`); `save_edit/2` still clears it unconditionally — see Open.
- Partially fixed — **NITPICK: a personal key can be minted for any member by a `manage_modules` holder**: since `5ce8e98` only whoever manages every key may pick another person (`web/api_keys_live.ex:696-700`); for that admin the attribution question remains — see Open.
- N/A — the review's three "Not taken" points (stale claim blocking `start`, amending an invoiced billable row, labels over 60 characters) are the reviewer's own rejections; unchanged and consistent with the code.

## Open

Still live — awaiting Max's decision (from `SONNET_REVIEW.md` "Open", re-verified 2026-10-29):

- **IMPROVEMENT - MEDIUM — an `Idempotency-Key` carries no request fingerprint.** `web/api/json.ex:297-301` reads the header; `api_keys.ex:731` stores and replays by (key, header) only — the same header on another path or body replays the first answer, a stored 4xx replays for ever, `phoenix_kit_project_api_idempotency` has no retention, and a header over 128 bytes is silently treated as absent (`json.ex:299`). Fix: store method + path + body hash, 422 `idempotency_key_reused` on mismatch; prune by `inserted_at`; 422 an over-long header.
- **IMPROVEMENT - MEDIUM — the API claim check is read-then-write.** `web/api/tasks_controller.ex:1079` asks `Json.may_take?/3` on the row read before the write at `:1202-1211`; two keys starting one `todo` task both pass. Fix: a conditional update (`WHERE status = 'todo'` or `started_by_key_uuid` unchanged) or re-check under the `FOR NO KEY UPDATE` that `update_tracking_status/2` already takes (`projects.ex:4244-4260`).
- **IMPROVEMENT - MEDIUM — link/unlink bypass `edit_foreign_text`.** `web/api/tasks_controller.ex:560-590` checks scope, feature and `:edit_tasks` but not `Json.may_edit_text?/3` (used at `:479`) nor the words stamp. Fix: gate it, or document that appending a link is allowed.
- **IMPROVEMENT - MEDIUM — N+1 on API read endpoints.** `subproject_state/1` per nested row (`web/api/json.ex:614-626`), `Projects.caught_up?/1` per project/child (`json.ex:554`, `:608`, `web/api/briefing_controller.ex:100`), `Projects.interactions_of/1` per task in the briefing (`briefing_controller.ex:298`) and in `tasks_controller.ex:532`. Fix: batch via `Projects.interactions_for_assignments/1` / `project_summaries/1`.
- **IMPROVEMENT - MEDIUM — the sub-project "Ends" select and its fold have no `manage_modules` gate.** `web/assignment_form_live.ex:3655-3660` renders it for anyone on the form; `fold_completion/3` (`:1821-1826`, `:2157-2162`) folds it, from the mount-time `sp_source/1` (`:2166`). Fix: render and fold only for `can_manage_modules`, folding from the child as stored.
- **IMPROVEMENT - MEDIUM — the explicit Save still clears `words_by_key_uuid`.** `web/assignment_form_live.ex:3124` (`save_edit/2`) stamps `nil` even when only the priority changed. Fix: reuse `words_changed?/3` as the autosave path does.
- **IMPROVEMENT - MEDIUM — `ProjectShowLive` re-queries task notes on every render of an open notes drawer.** `web/project_show_live.ex:6215` (`<% notes? = … %>`) and `:6270` (`TaskNotes.decorations(TaskNotes.list(...))` in the template). Fix: compute into an assign in `open_comments` / `comments_updated`.
- **NITPICK — `ApiTokenModal` static DOM ids.** `web/components/api_token_modal.ex:54`, `:62`, `:80`, `:88`. Fix: derive from an `id` attr.
- **NITPICK — `ApiKeyPanel` calls `Auth.get_user/1` per personal key whose person is not in `people`.** `web/api_key_panel.ex:44`, `:69`, `:92`. Fix: one batched user read.
- **NITPICK — `ProjectsLive.reorder_projects` rewrites the global `position`** for any module user (`web/projects_live.ex:747`). Fix: gate like `TasksLive`, or scope the order per viewer.
- **NITPICK — `Ledger.list_entries/2` rescues to `[]`**, so a DB error is an empty 200 on `GET /entries` (`ledger.ex:466-469`). Fix: let it raise to a 500, or return `{:error, _}`.
- **NITPICK — an admin can mint a personal key for another person** (`web/api_keys_live.ex:696-700`), attributing the agent's activity to them without their say; the creator is recorded in the key's metadata. Decide whether that needs the person's consent or a visible notice.
- **Known — `TaskNotes` ledger broadcasts inside the note transaction.** `task_notes.ex:426` is a plain `repo.transaction`, not `PubSub.after_commit/1` (`pub_sub.ex:74`), so a rollback after `record_usage` is outlived by the ledger broadcast (also listed under "Skipped" above). Fix: wrap in `PubSub.after_commit/1`.
