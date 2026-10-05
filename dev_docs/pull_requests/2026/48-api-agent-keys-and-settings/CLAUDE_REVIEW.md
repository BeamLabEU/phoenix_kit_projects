# Claude review — quality-sweep triage (2026-10-05)

Three read-only triage agents (the playbook's C12 prompts, verbatim) over
the day's commits on this branch and the matching CRM branch, before the PR
was opened. Each finding was verified against the code by the agent before
it was reported. Resolution of every item is in `FOLLOW_UP.md`.

## Agent 1 — security + error handling + async UX

- **BUG - HIGH: CRM `tasks` links any task on the site, in any project.** `link_tasks/3` → `ProjectsLink.link_task/3` looked the task up by uuid alone; nothing compared `a.project_uuid` with `ctx.project` or the key's reach. A key with `interactions:write` on project A could link (and rewrite the description of) a task in project B, and the interaction's `tasks` then showed B's task title.
- **BUG - MEDIUM: an interaction link needs no `interactions:*` scope, extension or role check.** `interaction_label/2` called the CRM provider's `get` directly, without `ApiKey.scope?`, `Extensions.enabled?` or the `:view` floor (the briefing's `client_lines/2` made those checks).
- **BUG - MEDIUM: ledger amend/delete checks gates on the wrong project.** `checks/3` (the `:ledger` feature and the role floor) ran on the key's root project; only afterwards did `own_entry/2` rescope to the entry's sub-project.
- **IMPROVEMENT - MEDIUM: the agent policy is editable by anyone who can edit the project.** Keys are gated on `:manage_modules`; `apply_project_type` and the fieldset had no gate.
- **IMPROVEMENT - MEDIUM: interaction and task writes are not atomic.** CRM: the interaction was committed first, then `link_tasks` could return 404/422. Projects: `insert_all` of the join row then the token update, outside a transaction.
- **NITPICK:** hard `{:ok, _} = Projects.stamp_assignment(...)` matches after the main write.
- Checked, clean: secrets, SQL injection (`escape_like`, typed uuids), SSRF (no HTTP clients), URL path injection, log leaks (no token in any log, flash or activity metadata), mass assignment (provenance is `@server_only`; the checklist is normalised; the `agents` map is re-validated on read), validate `:action`, `phx-disable-with`. Broad rescues added with no comment: `link_interaction`, `unlink_interaction`, `interactions_of`, `tasks_for_interaction`, `caught_up_since`, `within_reach?`, `keep_interaction_tokens`, `interaction_label`, the briefing's three best-effort sections, the CRM's `ProjectsLink` soft calls.

## Agent 2 — translations + activity + tests

- Translations: gettext wrapping, label maps, `String.capitalize/1` — checked, clean. Code-vs-catalogue (literals in `lib/` against `default.pot`): clean for this range; the only runtime-form call (`web/helpers.ex` `translate_catalog/1`) predates it and registers its literals with `gettext_noop`. **NITPICK:** the fallback token label `"interaction"` is English in a field people read.
- **BUG - MEDIUM:** `POST`/`DELETE /tasks/:id/interactions/:uuid` logged nothing; neither did the CRM's `tasks:` link.
- **IMPROVEMENT - MEDIUM:** a PATCH that changed only `labels` or `interaction` logged `fields: []`; `Labels.ensure_by_names` was called without an actor, so `projects.label_created` had `actor_uuid: nil`.
- **BUG - HIGH** (the same cross-project link as agent 1). **BUG - MEDIUM:** `tasks: [123]` hit the `is_binary` guard → 500; an unknown task answered 404 after the interaction was saved, so a retry duplicated it.
- **BUG - MEDIUM:** `PATCH /tasks/{id}` wrote the text before `link_interaction` ran — a bad `interaction` returned 404 with the text change saved.
- **BUG - MEDIUM:** `do_checklist_item` checked the item against the stale `a.checklist` before the lock; an item removed in between gave a `CaseClauseError`. A missing or misspelled `done` quietly unticked the item.
- **BUG - MEDIUM:** `fold_checklist/3` looked existing ids up by text — two lines with the same text got the same id. **BUG - MEDIUM:** `ensure_by_names` dropped a name over 60 characters without a word (the PATCH still 200).
- **IMPROVEMENT - MEDIUM:** a `checklist` or `labels` that is not a list was ignored (200). `completion: "bogus"` on `POST /subprojects` silently ignored.
- Tests: mostly happy paths; the dimensions (shapes × rules) tested only at the margins. Most plausible to break: a label name over 60 characters.
- Activity metadata PII: clean (`"task" => title` and `"name" => child.name` follow the existing convention of naming the task).

## Agent 3 — PubSub + cleanliness + public API

- **BUG - HIGH: the idempotency wrapper could run the work twice.** `ApiKeys.idempotent/3` read the stored key, ran `fun`, then inserted with `on_conflict: :nothing`: two concurrent retries both ran it, and the `rescue` ran `fun` again if the store raised after the first run.
- **BUG - MEDIUM:** `update_checklist_item/3` called `update_assignment_form/2` inside the transaction, which broadcasts before the commit.
- **BUG - MEDIUM:** `task_notes.ex`'s ledger rows broadcast inside the outer note transaction (pre-existing; now also reached through `create_for_project/3`).
- **BUG - MEDIUM:** `labels.ex` find-or-create by name outside a transaction: the loser of a race hit the unique index and was dropped from the result.
- **BUG - MEDIUM:** `link_interaction/4`: `insert_all` and the description rewrite as two steps, no lock — two concurrent links lost a token; a token-write failure left a join row.
- **BUG - MEDIUM:** the same stale checklist pre-check (CaseClauseError). **BUG - HIGH** (the cross-project link, again) and **BUG - MEDIUM** (the CRM writes the interaction before checking the tasks).
- **BUG - MEDIUM:** the create path ignored `link_interaction`'s result, contradicting "never a 201 with no link".
- **IMPROVEMENT - HIGH: N+1 in the list endpoints.** `Json.task/3` ran `interactions_of` and `subproject_state` per row; the CRM's `to_json` ran `tasks_for_interaction` per row (up to 200).
- IMPROVEMENT - MEDIUM: the seven-fold `require_scope → fetch → require_feature → require_action` chain; `check_interaction` / `link_interaction` duplication (the provider lookup ran twice on create); `delete_entry`'s own copy of the amendment metadata without `actor_uuid`; cross-controller helpers that belong in `Json`; ISO-8601 parsing copied four times; `{:ok, conn, a}` vs `{:ok, conn}` return shapes; `{:halt, conn}` and `{:error, {status, body}}` mixed in one `with`.
- Stale words: AGENTS.md named `Projects.link_assignment_to/5` and said `interaction_uuids/1` "parses the tokens"; the CRM's comments still described the token-only link; `ledger_controller.ex` said PATCH amends only minutes. Missing `@spec` on a handful of new public functions.
- **NITPICK:** `project_modules_live.ex`'s `handle_info/2` catch-all drops without a log; the CRM's `since` filters on the user-supplied `occurred_at` while `now` is server time (a backdated interaction logged after a poll is never returned to a poller).
- Checked, clean: topic helpers, subscribe-before-read, payloads, `Task.start`, `IO.inspect`, markers, commented-out code, `@type t`, `@deprecated`, `recompute_project_completion` with the ongoing branch, `revoke_for_user/3`, unused aliases.

Verdicts (all three): not ready until the cross-project link, the idempotency double run and the gate bypasses were fixed.
