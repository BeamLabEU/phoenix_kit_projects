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

## Keys live on the project, and act for a person

`phoenix_kit_project_api_keys` (chain V17, `user_uuid` in V18). One key = one
project. A key has a **name** (what the agent is called), a stored **role** —
`manager`, `member` or `viewer`, never owner — and **scopes** (`tasks:read`,
`tasks:write`, `time:write`, `usage:write`, `project:write`, plus what extension
providers declare; a metering-only key carries just time and usage). A key is one
of two kinds (`ApiKey.kind/1`):

- **personal** — `user_uuid` names the member it acts for. The role it acts
  with is that person's CURRENT membership (`Authz.effective_role/2`), capped by
  the stored role and never above manager (`ApiKeys.effective_role/2`; the auth
  plug calls `resolve/2` on every request). Demotion applies on the next call;
  once the person is off the project the key answers `403 membership_ended`,
  and `Members.remove_member/3` revokes their keys outright so an old secret
  cannot wake up when they are re-added. Every member mints, rotates and revokes
  their own personal keys on the project's **Your API key** page
  (`/projects/:id/api`, from the header ⋮ menu; `Web.ProjectApiLive`): one
  click, named "<Name>'s AI", cap at their role, every scope, no expiry. Nobody
  sees anyone else's keys there.
- **shared** — no person: a CI runner, "ANDI agent". Its stored role is the
  authority. Only the owner's **API access** section on Modules & Features
  (`manage_modules`) mints these, and that section is the project's whole list,
  both kinds, with an **Acts for** choice on the form (a member, or "Nobody — a
  shared agent") and a kind line on each row.

`created_by_uuid` (the minter) and `user_uuid` are provenance, not FKs: the row
is audit history once the person is gone. (Panel, 2026-10-05, three seats
converged: a separate acts-for field; the role derived from membership for a
person's key, stored for a shared one; self-service for every role; a page off
the ⋮ menu rather than a tab or a card under the task list.)

The token is `pkp_<key_id>_<secret>`. `key_id` is public (unique index, the
lookup), the secret is 32 random bytes and only its SHA-256 is stored; the
token is shown once, at creation and at **rotation**, which replaces the secret
on the same row so the key's ledger history stays one agent. **Revoke** ends it.
`last_used_at` is touched at most once a minute. `expires_at` is optional.

The page shows each key as a row — name and role, the public ID
(`pkp_<key_id>`, never the token), an **access** preset read back from the
scopes (Full access / Read-only / Metering / Custom · N scopes), last use and
expiry — with Rotate, Revoke and **Copy setup prompt** in its menu. A new key
is minted behind "New key": name, role, expiry (never / 30 / 90 / 365 days)
and a preset, with the seven scopes shown only under Custom. Creation and
rotation open a modal with the token, a **setup prompt** for the agent (base
URL, the agent guide, "start with GET /me", the token) and the reference
links; the same prompt without the token is behind every row's menu. The
"For your AI" strip under the section title links `/llms.txt` and
`/openapi.json` at all times. (`Web.ApiKeyPanel` holds the pure parts; the
shape came from a three-seat UX panel on 2026-10-05.)

## The key is its own principal

- **Authorisation:** `Authz.can_role?(project, key.role, action)` — the role
  floors the project configures (its "who can do what" overrides included),
  nothing else: no membership lookup, no admin override, no relationship grant.
  Plus the scope, plus the project's feature gates (`Features.gates/1`): tasks
  calls need `tasks`, ledger calls need `ledger`, the workflow status needs
  `statuses`.
- **Attribution:** ledger entries the key reports are `actor_kind: "ai_agent"`,
  `actor_uuid: key.uuid`, `source: "ai"`. Activity entries for task changes
  carry `actor_uuid: ApiKey.accountable_uuid(key)` — the person the key acts
  for, else its minter — with `metadata.via = "api"`, `metadata.api_key` and
  `metadata.api_key_name`, so the feed can tell the agent from the person.
  `/me` returns `acting_for` (`{uuid, name}`, null for a shared agent), the
  key's `kind`, and the role it acts with right now; the setup prompt tells the
  agent whom it acts for. (Core's activity actor renders
  as a user; a key uuid there would read "User 1a2b…".)
- **Agent time** is `kind: "time"` by an `ai_agent` actor, never billable
  (`billable` from the agent is ignored) — `Ledger.totals_for_project/1` splits
  it out as `ai_minutes`, and invoicing already bills human actors only. Panel
  2:1 for one kind split by actor over a new kind.

## Reach: the project and everything nested under it

A key is minted on one project and reaches that project **and every
sub-project nested under it** (Max, 2026-10-05: *"ideally the api would be able
to control everything in its project and everything in the children projects as
well"*), with the same resolved role and scopes throughout. `Json.within_reach?/2`
walks the target's `Projects.parent_chain/1` up to the key's project (eight
hops at most). Project-level calls take a `project` param (`Json.scope_project/2`
re-points `pk_project` and `pk_fx` at a sub-project within reach, 404
otherwise): `GET /project`, `POST /project/status`, `GET`/`POST /tasks`,
`POST /time`, `POST /usage`, `POST /subprojects` and the `/ext/…` lists and
creates. Task-level calls need nothing: `TasksController.fetch/2` finds a task
anywhere within reach and rescopes the request to its project (whose `tasks`
gate must be on), so features and role floors are the child's. `GET /project`
carries `parent_uuid` and `subprojects` (direct children); `POST /subprojects`
creates one through `Projects.create_subproject/2` (feature `subprojects`,
action `create_tasks`, activity `projects.subproject_created` with the API
metadata), at most seven levels down so what the API creates stays within what
it can reach. A key minted on a child does not reach its parent. The agent guide
has a "Sub-projects" section teaching the pattern: one sub-project per piece of
work, tasks created with `project` set to it.

## What a project's settings decide for an agent

Two keys in the project's `settings` JSONB (the form's edit card, chain V19 for
the task columns): **`completion`** — `auto` (the default: the last open row
done completes the project and the completion climbs) or `manual` (ongoing
work: never completes on its own, every task done is `caught_up`, an ongoing
child never completes its parent; copied to new sub-projects) — and
**`agents`** — `take_started_task`, `edit_foreign_text`, `delete_tasks`
(`none` | `own` | `any`), `amend_own_ledger`, read back as `agent_policy` on
`/me` and `/project`. Tasks carry who created and who started them (a person
and/or a key), `waiting_on`, `origin`, labels by name and a checklist;
`GET /briefing` is the recovery read, `POST`/`GET /notes` the project's own
notes, `updated_since` the poll. AGENTS.md ("What the first agent on the API
asked for") has the map from each ask to its code.

Records link by **mention token** (`#[type:uuid|label]` in a task's
description — the forms' own way): `interaction:` on a task, `tasks:` on an
interaction, read back as `interactions` / `tasks`. The ledger is readable
(`GET /entries`, `GET /tasks/{id}/entries`), events too (`GET /events`), and
the briefing carries the client's latest interactions and the next events.

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
thing to block v1 on. A retry that arrives while the first request with that key
is still running answers 409 `in_progress` and runs nothing; the key is never
handed to a second run by the clock, because a slow call is indistinguishable
from a dead one. If it never clears, look at what the first attempt did and
send the next attempt with a new `Idempotency-Key`.

## Records an extension puts on the API

`/ext/<resource>`: an extension declares `api: Module` on its extension map
and implements `PhoenixKitProjects.Extensions.ApiProvider`; this module
serves list / get / create / update under its own checks (the provider's
scopes, the extension on the project, the provider's action at the member
floor) and the provider's `docs/0` rows join the generated docs. The CRM's
`/ext/interactions` (a project's meetings, calls, messages: type, subject,
body, when, duration, parties, the planned event they are the record of) is
the first.

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
(`403 feature_disabled`, feature `notes`); a key with nobody behind it (no
person acted for and no minter) cannot write notes (`403 forbidden`).

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
