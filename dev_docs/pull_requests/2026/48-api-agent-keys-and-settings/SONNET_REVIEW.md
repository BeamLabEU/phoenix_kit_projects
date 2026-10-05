# Sonnet 5.5 review — PR #48, after the merge (2026-10-05)

Independent post-merge review of `f75d62b` (the JSON API, agent keys, the
agent policy). The pre-merge folder already holds the quality-sweep triage,
codex, grok and zai; this one does not repeat those and was read against
`FOLLOW_UP.md`'s "fixed" and "skipped" lists. Method: the key lifecycle
(`ApiKeys`, `Web.Api.Auth`, `RateLimit`, the V17–V20 chain, the routes and the
docs table) read directly; three read-only agents over the controllers, the
ledger and notes, and the LiveViews. **Every finding below was checked against
the code by me before it was accepted**; the ones I could not confirm, or that
turned out to be the intended design, are listed under "Not taken".

Fixes are in the working tree with tests; nothing is released.

## Fixed

- **BUG - HIGH: the Templates list deletes any project.** `TemplatesLive`
  `delete` fetched the uuid and deleted it with no `is_template` check — the
  exact hole `ProjectsLive.delete` was hardened against. A module-reacher who
  is not a member of a private project could delete it (and its sub-projects)
  by naming its uuid. Now only a `%Project{is_template: true}`; anything else
  answers "Template not found." (`templates_live.ex`).
- **BUG - MEDIUM: `save_redirect` / `adopt_summary` had no authorization row**
  in `ProjectShowLive`'s `@event_actions`, so a project's own "who may edit"
  override never applied to them. Both are `:edit_tasks` now. (The default
  floors are open, so this matters once a project restricts editing — which is
  the point of the override.) The redirect also takes only `summary` and
  `content` from the event instead of the raw params; the reviewing agent said
  a crafted `usage` there wrote ledger rows, **I could not reproduce that** (a
  redirect with a posted `usage` writes the note and no ledger row, with or
  without the narrowing), so that part is hardening, not a fix, and the test
  for it pins the behaviour rather than a bug.
- **BUG - MEDIUM: `open_comments` named any record.** The drawer renders and
  posts to the thread of whatever uuid it is given, with only a type
  whitelist: a member of project A could open B's task discussion or agent
  notes. The uuid must be this project or one of its tasks.
- **BUG - MEDIUM: a crafted `project[settings]` bypassed the manage-modules
  rule.** `apply_project_type(…, false)` returned the attrs untouched, so a
  posted `settings` map (agent policy, `completion`, `authz`, `visibility`)
  reached `Project.sanitize_settings`, which whitelists all of them. No field
  of the form posts `settings`; it is dropped, and the folds now start from the
  project as it is at save time rather than the mount-time copy (the Modules
  panel writes the same JSONB from another page, and the first Save after it
  used to write the stale map back — `agents` is a new key, so the first Save
  always counted as a settings change).
- **BUG - MEDIUM: an amendment erased `occurred_at`.** `Ledger.update_time`
  wrote `ended_at: nil` for an entry without `started_at` — every API entry,
  whose `ended_at` *is* the reported `occurred_at`. `PATCH /entries/:id
  {"minutes": …}` nulled the date of a batch-reported entry.
- **BUG - MEDIUM: figures past the column were a 500.** `work_entries.amount`
  is `NUMERIC(14,4)` and `tasks.estimated_duration` / `position` are int4;
  nothing capped them, so `{"tokens": 100000000000}`, a note's `usage`, an
  amendment, `estimated_duration: 9999999999` or `position: 3000000000` raised
  from Postgrex (and on a POST the reservation was released, so a retry raised
  again). Now a 422 with the bound (`WorkEntry.max_amount/0` = 9 999 999 999,
  `max_minutes/0` = 1 000 000; `@max_int` 1e9 on the task fields), and the
  `WorkEntry` changeset enforces the amount bound as the backstop. An amendment
  to `0` is a 422 too (it used to be a 409 from the DB check).
- **BUG - MEDIUM: a note's `refs` of the wrong JSON type crashed.**
  `to_string(%{})` in `type_error/1` / `id_error/1` raised
  `Protocol.UndefinedError` inside the idempotent fun. Now the field's own 422
  message; a whole-number `id` is read as its text.
- **BUG - MEDIUM: sub-project rows could be moved and edited like tasks.**
  `delete` guarded `child_project_uuid`; `transition` and `update` did not, so
  `POST /tasks/<row>/complete` marked the parent's rollup row done and let a
  parent complete over unfinished children. 409 `subproject`.
- **BUG - MEDIUM: `PATCH description` was silently lost** on a one-off made in
  the form, which keeps the text on the task *and* the assignment while every
  read prefers the assignment's copy: 200, old text still shown. The reword now
  reaches both.
- **BUG - MEDIUM: `PATCH /tasks/:id` could half-apply.** The task row committed
  before `waiting_on` (> 200), `origin` (> 40) were validated by the changeset,
  leaving the new title with `words_by_key_uuid` unstamped. Those bounds are
  checked before any write.
- **IMPROVEMENT - MEDIUM: a pending portal submission was reachable by uuid**
  through `/tasks/:id` (start, complete, patch, delete) — every list leaves it
  out; `fetch/2` now answers 404 for a row not `accepted`.
- **IMPROVEMENT - MEDIUM: ledger corrections ignored the row's scope.**
  Amend/delete always demanded `time:write`, so a `time:write` key could alter
  token/cost rows it could not create and a metering (`usage:write`) key could
  not correct its own. The scope follows the row's kind; the pre-lookup check
  asks only for either, so a key with neither learns nothing about which
  entries exist.
- **IMPROVEMENT - MEDIUM: the `/ext` provider's exception text went to the
  caller** (SQL, table and constraint names) and nothing to the log. Logged;
  the answer is a fixed sentence.
- **BUG - MEDIUM: an abandoned idempotency reservation answered 409 for ever.**
  A `status: 0` row is released only by `rescue`; a killed node or handler
  left it, and every retry got `in_progress`. A pending row older than two
  minutes is taken over atomically (one `UPDATE … WHERE status = 0 AND
  inserted_at < cutoff`, so of two racing retries one wins).
- **BUG - MEDIUM: a personal key outlived its person's account.**
  `resolve/2` consulted only the membership; a deactivated user's key kept
  working, and on an "everyone" project a bare uuid still resolves to a viewer
  seat, so a *deleted* user's key kept read access. `resolve/2` now refuses a
  personal key whose account is not live (the one 401), and
  `Members.handle_user_deletion/1` revokes the user's personal keys on every
  project (the membership rows cascade away without passing `delete_member`).
- **NITPICK:** `AGENTS.md` said the chain was at V16 (it is V20) and omitted
  the `task_interactions` join table and the reservation semantics.
- **IMPROVEMENT - MEDIUM: the `#` typeahead dropped a root member's
  sub-projects.** `narrow_to_context` intersected the subtree with
  `list_projects_for/1`, which lists top-level projects only, so a member of R
  searching inside R saw only R while an admin saw the whole subtree. A member
  of the field's own project now reaches its subtree (the climb
  `visible_resource_uuids/2` already makes).

Tests: `api_keys_test.exs` (reservation takeover, account liveness, deletion
revoke), `web/api_review48_test.exs`, `web/review48_lv_test.exs`.

## Open (not fixed here — each is a decision or a larger change)

- **IMPROVEMENT - MEDIUM: an `Idempotency-Key` carries no request fingerprint.**
  The same header on another endpoint or payload silently replays the first
  response, and a stored 4xx replays for ever, so an agent that fixes its
  payload but keeps the key never succeeds. Store method + path + body hash and
  answer 422 `idempotency_key_reused` on a mismatch; decide whether a 4xx
  should be stored at all. Also: the table has no retention (`inserted_at` is
  there; a periodic delete is needed) and a header over 128 bytes is treated as
  absent.
- **IMPROVEMENT - MEDIUM: the claim check is read-then-write.** Two keys
  starting one `todo` task at once both pass `may_take?`; the last write wins
  `started_by_key_uuid`. A `FOR UPDATE` or a conditional `update_all`.
- **IMPROVEMENT - MEDIUM: the link/unlink endpoints bypass `edit_foreign_text`**
  — `POST /tasks/:id/interactions/:uuid` appends a token to the text without
  `may_edit_text?` or the words stamp. Gate it, or document that appending a
  link is allowed.
- **IMPROVEMENT - MEDIUM: N+1 on read endpoints.** `Json.subproject_state` per
  nested row on `GET /tasks`, `caught_up?` per child on `/me` and `/project`,
  `Projects.interactions_of/1` per shown task in the briefing (the batched
  `interactions_for_assignments/1` exists and `/tasks` uses it).
- **IMPROVEMENT - MEDIUM: the sub-project "Ends" select and its save fold have
  no `manage_modules` gate** in `AssignmentFormLive` (the project form's has),
  so anyone who may create/edit tasks on the parent can make a child ongoing.
  Gate the render and `fold_completion` the same way.
- **IMPROVEMENT - MEDIUM: every human form save clears `words_by_key_uuid`**
  (`assignment_form_live.ex` `stamp_assignment(…, %{words_by_key_uuid: nil})`),
  even when only the priority changed, so the agent then gets 403
  `foreign_text` on its own wording. Clear it only when title, description or
  translations changed. Related: the sub-project form's `fold_completion`
  still builds from the mount-time settings.
- **IMPROVEMENT - MEDIUM: `ProjectShowLive` re-queries the task notes on every
  render of an open notes drawer** (`<% notes? = … %>` taints change tracking
  around `TaskNotes.decorations/1`) — compute them in `open_comments` /
  `comments_updated` into an assign.
- **NITPICK:** client-chosen checklist item ids and `done_at` are trusted
  (duplicate ids tick several rows; an integer id never matches the path
  param); `ApiTokenModal` uses static DOM ids against the embeddable-LV id
  rule; `ApiKeyPanel` calls `Auth.get_user` once per personal key whose owner
  is not in `people`; `ProjectsLive` / `TasksLive` `reorder_*` rewrite the
  global `position` for a module-only user (cosmetic);
  `Ledger.list_entries` rescues to `[]`, so a DB error is an empty 200 on
  `GET /entries`; the `Ledger` and `WorkEntry` moduledocs still say
  "append-only"; a personal key can be minted for *any* member by a
  `manage_modules` holder, which attributes the agent's activity to that
  member without their say (an audit-trail question, the creator is recorded in
  the key's metadata).
- **Known, unchanged:** `task_notes.ex` ledger broadcasts inside the note
  transaction (already on the skipped list).

## Not taken

- *"A stale claim blocks `start` on a task that went back to todo."* This is
  the designed behaviour: `api_agent_test.exs` asserts "A puts it back; B still
  may not start it", and AGENTS.md names the current holder as the model.
  Reopening does not release a claim; the policy `take_started_task` does.
- *"An invoiced billable row can be amended over the API."* Amending a
  billable row is the documented path ("amend it instead", the feed keeps the
  before and after); only deletion is refused. Whether an invoiced row should
  be frozen is a billing decision, not an API bug.
- *"Labels over 60 characters are dropped silently."* True of
  `Labels.ensure_by_names/3` alone, but the controller's `check_labels/1`
  already answers 422 before it is reached (Batch 2 of `FOLLOW_UP.md`).

## Checked and clean

Token minting (CSPRNG, base32-hex halves that cannot contain the `_`
separator, only the SHA-256 stored, constant-time compare, one 401 for every
refusal), the rate limiter (denies on failure, runs before any controller, a
429 is never stored as an idempotent reply), the route table against
`Docs.endpoints/0` and against `test/support/test_router.ex` (no drift in
either direction; the `/ext/*` rows are documented per provider), the
pipelines (no session, no CSRF, the API sits outside the browser pipeline),
`ConfirmAction` (whitelisted events, replayed through each LiveView's own
authorizing handler), the token modal (the secret lives only in an assign — not
in flash, PubSub, activity metadata or the DOM after dismiss), migration V17–V20
(every statement guarded, `down/1` mirrors the order), mass assignment of the
server-owned columns.
