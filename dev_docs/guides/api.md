# The projects API (`/api/projects/v1`)

The JSON API an outside agent drives ONE project with: read and create tasks,
move them through their lifecycle, set the project's workflow status, and
report the minutes, tokens and cost of its work into the work ledger. Built
2026-10-05 for the boss's case — "I run an AI model elsewhere, it does a task,
it must reach in and submit its token usage and time, and control the tasks."
Designed with a panel round (grok, zai, codex); the decisions below are theirs
where marked.

The agent-facing contract is **generated from one table of endpoints**
(`Web.Api.Docs.endpoints/0`) and served without a key as
`GET /api/projects/v1/llms.txt` (Markdown an LLM reads whole) and
`GET /api/projects/v1/openapi.json`. Change the table, and both documents
follow; never write an endpoint the table does not list.

## Keys live on the project

`phoenix_kit_project_api_keys` (chain V17), managed on the project's Modules &
Features page by anyone who may `manage_modules`. One key = one project. A key
has a **name** (what the agent is called), a **role** of its own — `manager`,
`member` or `viewer`, never owner — and **scopes** (`tasks:read`, `tasks:write`,
`time:write`, `usage:write`, `project:write`; a metering-only key carries just
the last two). `created_by_uuid` is provenance, not an FK: the key does not
depend on that person staying a member (panel: a key that silently died with its
sponsor's role was the trap of the "creator capped by role" model).

The token is `pkp_<key_id>_<secret>`. `key_id` is public (unique index, the
lookup), the secret is 32 random bytes and only its SHA-256 is stored; the
token is shown once, at creation and at **rotation**, which replaces the secret
on the same row so the key's ledger history stays one agent. **Revoke** ends it.
`last_used_at` is touched at most once a minute. `expires_at` is optional.

## The key is its own principal

- **Authorisation:** `Authz.can_role?(project, key.role, action)` — the role
  floors the project configures (its "who can do what" overrides included),
  nothing else: no membership lookup, no admin override, no relationship grant.
  Plus the scope, plus the project's feature gates (`Features.gates/1`): tasks
  calls need `tasks`, ledger calls need `ledger`, the workflow status needs
  `statuses`.
- **Attribution:** ledger entries the key reports are `actor_kind: "ai_agent"`,
  `actor_uuid: key.uuid`, `source: "ai"`. Activity entries for task changes
  carry `actor_uuid: key.created_by_uuid` — the accountable person — with
  `metadata.via = "api"`, `metadata.api_key` and `metadata.api_key_name`, so
  the feed can tell the agent from the person. (Core's activity actor renders
  as a user; a key uuid there would read "User 1a2b…".)
- **Agent time** is `kind: "time"` by an `ai_agent` actor, never billable
  (`billable` from the agent is ignored) — `Ledger.totals_for_project/1` splits
  it out as `ai_minutes`, and invoicing already bills human actors only. Panel
  2:1 for one kind split by actor over a new kind.

## The calls

`GET /me` is the entry point (key, project, features on, `allowed_actions`,
docs URLs). Tasks: `GET /tasks[?status=]`, `POST /tasks` (a one-off task at the
bottom of the plan, `ad_hoc: true`), `GET /tasks/:id`, `PATCH /tasks/:id`
(content and plan fields, never status; title/description only on an ad-hoc
task — a shared library task answers 409 `library_task`),
`POST /tasks/:id/transition {status}` with `start` / `complete` / `reopen` as
aliases through the same path (panel: one state machine, aliases must not
drift). Ledger: `POST /tasks/:id/time`, `POST /time` (minutes), `POST
/tasks/:id/usage`, `POST /usage` (tokens, cost_cents, model). Project:
`GET /project`, `POST /project/status {slug}` — workflow statuses belong to the
project, not to tasks, which have only todo / in_progress / done.

Every error is `{"error": {"code", "message", "details"?}}` with a stable code;
messages are English and locale-free on purpose (a machine contract).

## Idempotency

`phoenix_kit_project_api_idempotency` stores `{status, body}` under
(key, `Idempotency-Key` header); a replay answers the stored response with an
`Idempotent-Replayed: true` header. **Required** on the ledger POSTs (appends
nobody can undo), honoured on task create and transitions. Panel: the one
thing to block v1 on.

## Task notes

`TaskNotes` (see AGENTS.md "Task notes"): `POST /tasks/:id/notes` takes
`summary` (required, ≤ 240), `content`, `outcome`, `next_steps`, `refs`
(≤ 20 of `{type, id, url?, label?}`), `usage` (`tokens`, `cost_cents`,
`minutes`, `model`, `occurred_at`; needs `usage:write`, the ledger gate and
the `log_time` floor) — `Idempotency-Key` required. The note is a comment
on `project_task_notes`; its usage is ledger rows in the same transaction,
linked both ways. `GET /tasks/:id/notes` lists them oldest first with
`direction` / `latest_agent_note` / `latest_human_note` first; `GET
/tasks/:id` carries `direction`, `last_outcome`, `latest_agent_note`,
`display_summary` and `totals`. A key cannot write a `redirect`; a person
does, from the notes drawer. Notes need the comments module switched on
(`403 feature_disabled`, feature `notes`); a key minted with nobody behind
it (no `created_by_uuid`) cannot write notes (`403 forbidden`).

## Rate limit

`Web.Api.RateLimit`: a fixed window per key on core's Hammer ETS backend (the
one the portal's limiter shares), applied in `Web.Api.Auth` right after the
key is known — before any controller, so a refused call is never stored as an
idempotent reply. Default 300 calls per 60 s;
`config :phoenix_kit_projects, :api_rate_limit, limit: 300, window_ms: 60_000`,
`limit: nil` switches it off. Every authenticated response carries
`X-RateLimit-Limit` / `X-RateLimit-Remaining`; over the limit is 429
`rate_limited` with `Retry-After` (seconds) and the same figure in `details`.
A limiter failure denies, as the house rule for abuse controls says. The
docs print the live figure, so an agent reads what applies on this site.

## When the work happened

The four ledger POSTs take an optional `occurred_at` (ISO 8601, any offset,
truncated to the second, at most 5 minutes ahead of the server's clock). It is
stored as the entry's `ended_at` and echoed as `occurred_at`; `inserted_at`
stays the receipt time (`recorded_at`). Nothing groups entries by it yet —
totals are lifetime — but a batch reported the morning after keeps its real
date on the row for when a period report exists.

## Not in v1

- **Webhooks** on task events (the module already broadcasts them on PubSub) —
  so an agent can be handed a task instead of polling. Logged as an idea in
  AGENTS.md on 2026-10-05; Max: skip for now.
- **A running timer** for people.
- **Agent as a member kind** (assignable, mentionable) if agents must outlive
  people as first-class participants — the key principal is the step before it.

## Testing

`test/phoenix_kit_projects/web/api_test.exs` drives the controllers through
the test router (which mirrors `Web.Routes.generate/1`'s API scope) with
`Phoenix.ConnTest`; `test/phoenix_kit_projects/api_keys_test.exs` covers the
credential lifecycle. Both run against the test database like every
integration test here.
