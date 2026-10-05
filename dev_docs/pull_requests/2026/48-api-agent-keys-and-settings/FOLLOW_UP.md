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

## Open

None.
