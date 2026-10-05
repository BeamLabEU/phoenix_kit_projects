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

## Not in v1, planned

- **Webhooks** on task events (the module already broadcasts them on PubSub) —
  so an agent can be handed a task instead of polling.
- **Rate limiting** per key (core's `RateLimiter` is per-feature; a key limit
  belongs beside it).
- **A running timer** for people; `occurred_at` on usage posts for batch
  reporting (server receipt time is used today).
- **Agent as a member kind** (assignable, mentionable) if agents must outlive
  people as first-class participants — the key principal is the step before it.

## Testing

`test/phoenix_kit_projects/web/api_test.exs` drives the controllers through
the test router (which mirrors `Web.Routes.generate/1`'s API scope) with
`Phoenix.ConnTest`; `test/phoenix_kit_projects/api_keys_test.exs` covers the
credential lifecycle. Both run against the test database like every
integration test here.
