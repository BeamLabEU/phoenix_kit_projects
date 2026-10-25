# Follow-up — release audit of ca85176

How each finding in `CODEX_REVIEW.md` stands against the current code.
`REPRO_TEST.exs` asserts the defects as they were, so its three tests are
expected to fail against the fixed code.

- **BUG - HIGH: reservation takeover can duplicate live work and overwrite its
  response** — **Fixed.** `3621023` removed the age-based takeover; `bbfd330`
  made liveness a database fact: `ApiKeys.idempotent/3`
  (`lib/phoenix_kit_projects/api_keys.ex:731-761`) holds a Postgres session
  advisory lock for the whole run on a checked-out connection, a second
  request that cannot take it answers 409 `in_progress`, and a pending row is
  taken over only when the lock is free (its owner's connection is gone).
  The one window left — a request dying after its work committed and before
  its answer was stored — is stated in the function's doc.
- **BUG - MEDIUM: a rejected checklist PATCH still persists text changes** —
  **Fixed** in `3621023`. `TasksController.do_update/3` runs `precheck/3`
  (`lib/phoenix_kit_projects/web/api/tasks_controller.ex:370`, `:717-728`),
  which builds the task and assignment changesets and refuses an invalid one
  before anything is written. Still true: the writes after it (`reparent`,
  `update_content`, `update_fields`, labels, interaction, `:371-377`) run one
  at a time outside a transaction, so a failure the changesets cannot see
  (a database constraint) leaves the earlier writes; wrapping them in one
  transaction, with activity and broadcasts after the commit, would close it.
- **BUG - MEDIUM: accepted durations can break the parent rollup silently** —
  **Fixed** in `3621023`. A task over `@max_task_minutes` (about eleven
  years, `tasks_controller.ex:54`) is a 422; `build_child_rollup/2` clamps
  the rollup to `@max_rollup_minutes`, the int4 ceiling
  (`lib/phoenix_kit_projects/projects.ex:2798`); `sync_project_completion/1`
  logs a failure instead of rescuing it silently (`tasks_controller.ex:1203-1208`).
- **BUG - MEDIUM: ledger correction docs advertise the wrong scopes** —
  **Fixed** in `3621023`. PATCH and DELETE `/entries/{id}` say
  "time:write for a time entry, usage:write for a tokens or cost entry"
  (`lib/phoenix_kit_projects/web/api/docs.ex:1268`, `:1304`), and
  `api_review48_test.exs` asserts it in the endpoint table and `llms.txt`.
- **Test gap: the new LiveView tests run as site admin** — **Fixed** in
  `3621023`. `review48_lv_test.exs`, "a member under restrictive floors",
  drives the redirect / adopt denial for a member (with a manager as the
  control) and a member's crafted settings on a new project. The modules
  panel is owner-only and refuses a manager at mount (`lifecycle_flag_test.exs`).
- **Carried from the PR #48 reviews** (request fingerprinting, idempotency
  retention, the claim race, the sub-project completion permission) — not
  findings of this audit; they are answered with that PR's reviews
  (`../48-api-agent-keys-and-settings/SONNET_REVIEW.md`, "Open").
