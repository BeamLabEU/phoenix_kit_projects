defmodule PhoenixKitProjects.Web.Api.Docs do
  @moduledoc """
  The API described for the agents that will drive it: one table of
  endpoints (`endpoints/0`) rendered two ways — `llms_txt/0`, a short
  Markdown contract an LLM can read whole (auth, every call with a curl
  line, units, errors, what to retry), and `openapi/0`, the exhaustive
  OpenAPI 3.1 document for tooling. Both are served without a key.
  """

  alias PhoenixKitProjects.Web.Api.RateLimit

  @version "v1"
  @base_path "/api/projects/#{@version}"

  @doc "The API's base path, with the kit's URL prefix."
  @spec base_path() :: String.t()
  def base_path do
    prefix =
      case PhoenixKit.Config.get_url_prefix() do
        "/" -> ""
        p -> String.trim_trailing(p, "/")
      end

    prefix <> @base_path
  rescue
    _ -> @base_path
  end

  @doc "`base_path/0` plus `suffix`."
  @spec url(String.t()) :: String.t()
  def url(suffix), do: base_path() <> suffix

  @type endpoint :: %{
          id: String.t(),
          method: String.t(),
          path: String.t(),
          summary: String.t(),
          auth: boolean(),
          scope: String.t() | nil,
          action: String.t() | nil,
          feature: String.t() | nil,
          idempotency: :required | :optional | nil,
          params: [
            %{
              name: String.t(),
              in: :path | :query | :body,
              type: String.t(),
              required: boolean(),
              doc: String.t()
            }
          ],
          example: String.t() | nil
        }

  @doc "Every endpoint, in the order the docs list them."
  @spec endpoints() :: [endpoint()]
  def endpoints do
    [
      %{
        id: "getMe",
        method: "GET",
        path: "/me",
        summary:
          "Who this key is: its name, role and scopes, the project, which features are on, the actions the role allows, and where these docs are. Read this first.",
        auth: true,
        scope: nil,
        action: nil,
        feature: nil,
        idempotency: nil,
        params: [],
        example: nil
      },
      %{
        id: "getProject",
        method: "GET",
        path: "/project",
        summary:
          "The key's project: name, dates, the current workflow status and the statuses available to it.",
        auth: true,
        scope: "tasks:read",
        action: "view",
        feature: nil,
        idempotency: nil,
        params: [],
        example: nil
      },
      %{
        id: "setProjectStatus",
        method: "POST",
        path: "/project/status",
        summary:
          "Set the project's workflow status to one of `available_workflow_statuses` (from /project or /me). Workflow statuses belong to the project; tasks have only todo / in_progress / done.",
        auth: true,
        scope: "project:write",
        action: "update_status",
        feature: "statuses",
        idempotency: :optional,
        params: [
          %{
            name: "status",
            in: :body,
            type: "string",
            required: true,
            doc: "a slug from available_workflow_statuses"
          }
        ],
        example: ~s({"status": "in_review"})
      },
      %{
        id: "listTasks",
        method: "GET",
        path: "/tasks",
        summary:
          "Every task of the project the key may see, in plan order. No pagination: the whole list comes back. The key sees every task its role allows — there is no notion of \"my\" tasks for a key.",
        auth: true,
        scope: "tasks:read",
        action: "view",
        feature: "tasks",
        idempotency: nil,
        params: [
          %{
            name: "status",
            in: :query,
            type: "string",
            required: false,
            doc: "todo | in_progress | done | open (= not done)"
          }
        ],
        example: nil
      },
      %{
        id: "createTask",
        method: "POST",
        path: "/tasks",
        summary:
          "Create a task at the bottom of the plan. It starts as todo, unassigned, and is NOT started — call /tasks/{id}/start to begin it.",
        auth: true,
        scope: "tasks:write",
        action: "create_tasks",
        feature: "tasks",
        idempotency: :optional,
        params: [
          %{name: "title", in: :body, type: "string", required: true, doc: "up to a short line"},
          %{name: "description", in: :body, type: "string", required: false, doc: ""},
          %{
            name: "priority",
            in: :body,
            type: "string",
            required: false,
            doc: "urgent | high | normal | low (default normal)"
          },
          %{
            name: "estimated_duration",
            in: :body,
            type: "integer",
            required: false,
            doc: "a positive whole number of estimated_duration_unit"
          },
          %{
            name: "estimated_duration_unit",
            in: :body,
            type: "string",
            required: false,
            doc: "minutes | hours | days | weeks | fortnights | months | years"
          }
        ],
        example:
          ~s({"title": "Write the migration", "description": "V17: api keys", "priority": "high", "estimated_duration": 2, "estimated_duration_unit": "hours"})
      },
      %{
        id: "getTask",
        method: "GET",
        path: "/tasks/{id}",
        summary:
          "One task, with `allowed_transitions` — the statuses it may move to from where it is.",
        auth: true,
        scope: "tasks:read",
        action: "view",
        feature: "tasks",
        idempotency: nil,
        params: [%{name: "id", in: :path, type: "uuid", required: true, doc: "the task's uuid"}],
        example: nil
      },
      %{
        id: "updateTask",
        method: "PATCH",
        path: "/tasks/{id}",
        summary:
          "Edit a task's content and plan fields. Never changes status — use the transition calls. Title and description can be edited only on a task created in this project (`library_task: false`); a shared library task answers 409 library_task.",
        auth: true,
        scope: "tasks:write",
        action: "edit_tasks",
        feature: "tasks",
        idempotency: :optional,
        params: [
          %{name: "id", in: :path, type: "uuid", required: true, doc: ""},
          %{name: "title", in: :body, type: "string", required: false, doc: ""},
          %{name: "description", in: :body, type: "string", required: false, doc: ""},
          %{
            name: "priority",
            in: :body,
            type: "string",
            required: false,
            doc: "urgent | high | normal | low"
          },
          %{name: "progress_pct", in: :body, type: "integer", required: false, doc: "0 to 100"},
          %{
            name: "estimated_duration",
            in: :body,
            type: "integer",
            required: false,
            doc: "positive whole number"
          },
          %{
            name: "estimated_duration_unit",
            in: :body,
            type: "string",
            required: false,
            doc: "minutes | hours | days | weeks | fortnights | months | years"
          }
        ],
        example: ~s({"progress_pct": 60, "priority": "urgent"})
      },
      %{
        id: "transitionTask",
        method: "POST",
        path: "/tasks/{id}/transition",
        summary:
          "Move a task through its lifecycle: todo → in_progress or done; in_progress → done or todo; done → todo. Any other move answers 409 invalid_transition with `allowed_transitions` — reload the task and pick one of those. Completing a task may complete the project; reopening one may reopen it.",
        auth: true,
        scope: "tasks:write",
        action: "update_status",
        feature: "tasks",
        idempotency: :optional,
        params: [
          %{name: "id", in: :path, type: "uuid", required: true, doc: ""},
          %{
            name: "status",
            in: :body,
            type: "string",
            required: true,
            doc: "todo | in_progress | done"
          }
        ],
        example: ~s({"status": "in_progress"})
      },
      %{
        id: "startTask",
        method: "POST",
        path: "/tasks/{id}/start",
        summary: "Alias of transition to in_progress.",
        auth: true,
        scope: "tasks:write",
        action: "update_status",
        feature: "tasks",
        idempotency: :optional,
        params: [%{name: "id", in: :path, type: "uuid", required: true, doc: ""}],
        example: nil
      },
      %{
        id: "completeTask",
        method: "POST",
        path: "/tasks/{id}/complete",
        summary: "Alias of transition to done.",
        auth: true,
        scope: "tasks:write",
        action: "update_status",
        feature: "tasks",
        idempotency: :optional,
        params: [%{name: "id", in: :path, type: "uuid", required: true, doc: ""}],
        example: nil
      },
      %{
        id: "reopenTask",
        method: "POST",
        path: "/tasks/{id}/reopen",
        summary: "Alias of transition to todo.",
        auth: true,
        scope: "tasks:write",
        action: "update_status",
        feature: "tasks",
        idempotency: :optional,
        params: [%{name: "id", in: :path, type: "uuid", required: true, doc: ""}],
        example: nil
      },
      %{
        id: "logTaskTime",
        method: "POST",
        path: "/tasks/{id}/time",
        summary:
          "Record minutes you spent on a task. Whole minutes, never billable, recorded as AI time (apart from people's time). Append-only: an entry cannot be edited or deleted, so send an Idempotency-Key and retry with the same one.",
        auth: true,
        scope: "time:write",
        action: "log_time",
        feature: "ledger",
        idempotency: :required,
        params: [
          %{name: "id", in: :path, type: "uuid", required: true, doc: ""},
          %{
            name: "minutes",
            in: :body,
            type: "integer",
            required: true,
            doc: "positive whole minutes"
          },
          %{
            name: "note",
            in: :body,
            type: "string",
            required: false,
            doc: "what the time went on"
          },
          occurred_at_param()
        ],
        example: ~s({"minutes": 12, "note": "wrote and ran the tests"})
      },
      %{
        id: "logProjectTime",
        method: "POST",
        path: "/time",
        summary:
          "Record minutes spent on the project as a whole (not on one task). Same rules as /tasks/{id}/time.",
        auth: true,
        scope: "time:write",
        action: "log_time",
        feature: "ledger",
        idempotency: :required,
        params: [
          %{
            name: "minutes",
            in: :body,
            type: "integer",
            required: true,
            doc: "positive whole minutes"
          },
          %{name: "note", in: :body, type: "string", required: false, doc: ""},
          occurred_at_param()
        ],
        example: ~s({"minutes": 5, "note": "planning"})
      },
      %{
        id: "recordTaskUsage",
        method: "POST",
        path: "/tasks/{id}/usage",
        summary:
          "Record tokens and/or cost for a task. `tokens` is a whole count; `cost_cents` is a whole number of cents (send 5 for $0.05 — never fractional dollars). Writes one ledger entry per non-zero figure. Append-only: send an Idempotency-Key.",
        auth: true,
        scope: "usage:write",
        action: "log_time",
        feature: "ledger",
        idempotency: :required,
        params: [
          %{name: "id", in: :path, type: "uuid", required: true, doc: ""},
          %{
            name: "tokens",
            in: :body,
            type: "integer",
            required: false,
            doc: "total tokens, >= 0"
          },
          %{
            name: "cost_cents",
            in: :body,
            type: "integer",
            required: false,
            doc: "whole cents, >= 0"
          },
          %{
            name: "model",
            in: :body,
            type: "string",
            required: false,
            doc: "the model used, for the record"
          },
          occurred_at_param()
        ],
        example: ~s({"tokens": 18422, "cost_cents": 7, "model": "claude-sonnet-5-5"})
      },
      %{
        id: "recordProjectUsage",
        method: "POST",
        path: "/usage",
        summary:
          "Record tokens and/or cost against the project as a whole. Same rules as /tasks/{id}/usage.",
        auth: true,
        scope: "usage:write",
        action: "log_time",
        feature: "ledger",
        idempotency: :required,
        params: [
          %{name: "tokens", in: :body, type: "integer", required: false, doc: ""},
          %{name: "cost_cents", in: :body, type: "integer", required: false, doc: ""},
          %{name: "model", in: :body, type: "string", required: false, doc: ""},
          occurred_at_param()
        ],
        example:
          ~s({"tokens": 900, "model": "claude-haiku-4-5", "occurred_at": "2026-10-05T14:30:00Z"})
      },
      %{
        id: "listTaskNotes",
        method: "GET",
        path: "/tasks/{id}/notes",
        summary:
          "The task's notes thread (the long record, apart from the human discussion), oldest first, plus what to read FIRST: `direction` (the latest redirect a person wrote — follow it; older notes are context), `latest_agent_note` and `latest_human_note`.",
        auth: true,
        scope: "tasks:read",
        action: "view",
        feature: "tasks",
        idempotency: nil,
        params: [%{name: "id", in: :path, type: "uuid", required: true, doc: ""}],
        example: nil
      },
      %{
        id: "createTaskNote",
        method: "POST",
        path: "/tasks/{id}/notes",
        summary:
          "Write a note on the task — your reasoning, what you changed, what came out — with the usage it cost, in one call. `summary` is required: one line (≤ 240 chars) the next worker reads first. Put the long record in `content` (the site's comment length cap applies). `usage` is written to the ledger in the same transaction and counts toward the task's totals. Append-only: send an Idempotency-Key.",
        auth: true,
        scope: "tasks:write",
        action: "edit_tasks",
        feature: "tasks",
        idempotency: :required,
        params: [
          %{name: "id", in: :path, type: "uuid", required: true, doc: ""},
          %{
            name: "summary",
            in: :body,
            type: "string",
            required: true,
            doc: "one line, at most 240 characters — the TLDR of this note"
          },
          %{
            name: "content",
            in: :body,
            type: "string",
            required: false,
            doc:
              "the long record: reasoning, changes, results. Markdown and # / @ mentions render."
          },
          %{
            name: "outcome",
            in: :body,
            type: "string",
            required: false,
            doc:
              "your claim about THIS attempt: done | partial | blocked | failed | needs_review. A later redirect supersedes it; it never sets the task's status."
          },
          %{
            name: "next_steps",
            in: :body,
            type: "string",
            required: false,
            doc: "where you stopped and what you would do next, at most 2000 characters"
          },
          %{
            name: "refs",
            in: :body,
            type: "array",
            required: false,
            doc:
              "the artifacts of this attempt, at most 20: objects {type, id, url?, label?}. type is a slug (recommended: commit, branch, pr, issue, run, deploy, file, url, ticket), id ≤ 256 chars, url http(s) ≤ 2048 chars without credentials (never fetched), label ≤ 120 chars"
          },
          %{
            name: "usage",
            in: :body,
            type: "object",
            required: false,
            doc:
              "{tokens, cost_cents, minutes, model, occurred_at}: whole non-negative figures (cents, not dollars; whole minutes); needs the usage:write scope, the ledger feature and the log_time floor"
          }
        ],
        example:
          ~s({"summary": "Moved the import to the batch API; tests green", "outcome": "done", "content": "## What I tried\\n…", "next_steps": "Deploy to dev and watch the queue", "refs": [{"type": "commit", "id": "a1b2c3d", "url": "https://github.com/acme/app/commit/a1b2c3d"}, {"type": "pr", "id": "42", "label": "Batch import"}], "usage": {"tokens": 18422, "cost_cents": 7, "minutes": 12, "model": "claude-sonnet-5-5"}})
      },
      %{
        id: "llmsTxt",
        method: "GET",
        path: "/llms.txt",
        summary: "This document, as Markdown. No key needed.",
        auth: false,
        scope: nil,
        action: nil,
        feature: nil,
        idempotency: nil,
        params: [],
        example: nil
      },
      %{
        id: "openapi",
        method: "GET",
        path: "/openapi.json",
        summary: "The OpenAPI 3.1 description of this API. No key needed.",
        auth: false,
        scope: nil,
        action: nil,
        feature: nil,
        idempotency: nil,
        params: [],
        example: nil
      }
    ]
  end

  defp occurred_at_param do
    %{
      name: "occurred_at",
      in: :body,
      type: "string",
      required: false,
      doc:
        "ISO 8601 datetime of when the work happened, for reporting in batches after the fact; default: now (the receipt time). Not in the future."
    }
  end

  @errors [
    {401, "unauthorized",
     "The key is missing, malformed, unknown, revoked or expired. Do not retry; tell your operator."},
    {403, "forbidden",
     "The key's role may not perform this action on this project. Do not retry."},
    {403, "scope_missing", "The key does not carry the scope this call needs. Do not retry."},
    {403, "feature_disabled",
     "The project has this feature turned off (see `features` on /me). Do not retry."},
    {404, "not_found", "No such task in this project. Reload /tasks."},
    {409, "invalid_transition",
     "The task cannot move from its current status to the one asked; `details.allowed_transitions` lists what it can do. Reload the task, then pick one of those."},
    {409, "library_task",
     "Title and description of a shared library task are edited in the library, not here."},
    {422, "validation_failed",
     "A field is missing or has the wrong shape; `details` names the fields and, for closed sets, the allowed values. Fix the request; do not retry it unchanged."},
    {422, "idempotency_key_required", "This POST needs an Idempotency-Key header."},
    {429, "rate_limited",
     "The key has used its calls for the current window. Wait the `Retry-After` seconds, then retry the same request (same Idempotency-Key). Nothing was done."},
    {500, "(any)",
     "Retry with backoff and the SAME Idempotency-Key; the response will be replayed if the first attempt did land."}
  ]

  @doc "The Markdown contract, whole: what an agent needs to drive the API unaided."
  @spec llms_txt() :: String.t()
  def llms_txt do
    base = base_path()

    endpoint_lines =
      Enum.map(endpoints(), fn e ->
        gates =
          [
            e.scope && "scope `#{e.scope}`",
            e.action && "action `#{e.action}`",
            e.feature && "feature `#{e.feature}`",
            e.idempotency == :required && "**Idempotency-Key required**",
            e.idempotency == :optional && "Idempotency-Key honoured"
          ]
          |> Enum.filter(& &1)
          |> Enum.join(", ")

        params =
          e.params
          |> Enum.reject(&(&1.in == :path))
          |> Enum.map(fn p ->
            "  - `#{p.name}` (#{p.type}#{if p.required, do: ", required", else: ""})#{if p.doc != "", do: " — " <> p.doc, else: ""}"
          end)

        curl = curl_for(base, e)

        [
          "### #{e.method} #{e.path}",
          "",
          e.summary,
          gates != "" && "Needs: #{gates}.",
          params != [] && "Fields:",
          params != [] && Enum.join(params, "\n"),
          "",
          "```",
          curl,
          "```",
          ""
        ]
        |> Enum.filter(& &1)
        |> Enum.join("\n")
      end)

    error_lines =
      Enum.map(@errors, fn {status, code, what} -> "- **#{status} `#{code}`** — #{what}" end)

    """
    # Projects API #{@version}

    > The JSON API an agent drives one project with: read and create tasks, move them through
    > their lifecycle, and report the minutes, tokens and cost of the work. One key = one project.

    Base URL: `#{base}` (relative to this site). Every path below is under it.
    Send and accept JSON (`Content-Type: application/json`). Ids are UUIDs.

    ## Authentication

    `Authorization: Bearer pkp_…` on every call except `/llms.txt` and `/openapi.json`.
    A project manager mints the key on the project's Modules & Features page and hands you the
    token once; keep it out of URLs, logs and tickets (use an environment variable, e.g. `$PKP_TOKEN`).
    A 401 means the key is gone or wrong — stop and tell your operator; never retry it.

    ## Start here

    `GET /me` tells you the project, which features are on (`features`), what your role may do
    (`allowed_actions`), the scopes your key carries, and the project's workflow statuses.
    The live set of calls that will work for you follows from that; read it before anything else.

    ## Rules that trip agents up

    - **Units:** `minutes` are whole minutes (not hours, not decimals); `tokens` whole counts;
      `cost_cents` whole cents (5 means $0.05 — never send dollars); `progress_pct` 0–100.
    - **No pagination:** `/tasks` returns the whole list. There is no `page` parameter.
    - **No "my" tasks:** a key sees every task its role allows. Filter by `status` (`open` = not done).
    - **Status moves are explicit:** `PATCH /tasks/{id}` never changes status. Use `/transition`
      (or `/start`, `/complete`, `/reopen`) and obey `allowed_transitions` on the task.
    - **Appends are forever:** time and usage entries cannot be edited or deleted. Every such POST
      must carry an `Idempotency-Key` (any unique string per attempt — a UUID is fine); retry a
      timeout with the SAME key and you get the original response back, never a second row.
      `POST /tasks` and the transitions honour the header too.
    - **Workflow statuses belong to the project**, not to tasks: `POST /project/status`, with a slug
      from `available_workflow_statuses`. Tasks have only todo / in_progress / done.
    - **Who did it:** your time and usage are recorded as this key (AI time, apart from people's;
      never billable). Task changes are logged under the person who minted the key, with the key named.
    - **When it happened:** time and usage carry the receipt time unless you send `occurred_at`
      (ISO 8601, not in the future) — do so when you report in a batch after the work.
    - **Notes, not essays, in the description:** the task's `description` is the short human text.
      Everything long — reasoning, what you changed, what came out — goes to `POST /tasks/{id}/notes`
      with a one-line `summary`, your `outcome` for the attempt, `refs` (commits, branches, PRs) and
      the `usage` it cost, all in one call. Before you work on a task, `GET /tasks/{id}`: if
      `direction` is set, a person changed the direction after an earlier attempt — follow it, the
      older notes are context; `last_outcome` and `latest_agent_note` say where the last worker stopped.
    - **Rate limit:** #{RateLimit.describe()} per key, counted on every call. Every response carries `X-RateLimit-Limit` and
      `X-RateLimit-Remaining`; a 429 carries `Retry-After` in seconds. Poll `/tasks` no more than
      once a minute.
    - **Stability:** within `#{@version}`, changes are additive. Program against error `code`s, not messages.

    ## Errors

    Every error is `{"error": {"code": "...", "message": "...", "details": {...}}}`:

    #{Enum.join(error_lines, "\n")}

    Retry only 429 (after `Retry-After`) and 5xx (with backoff), both with the same Idempotency-Key.
    Never retry 401, 403, 404 or 422 unchanged.

    ## Endpoints

    #{Enum.join(endpoint_lines, "\n")}
    ## Task shape

    `uuid`, `kind` (`task` | `subproject`), `title`, `description`, `status`, `allowed_transitions`,
    `priority`, `progress_pct`, `estimated_duration`, `estimated_duration_unit`, `position`,
    `task_uuid`, `child_project_uuid`, `library_task`, `completed_at`, `inserted_at`, `updated_at`,
    `totals` (`minutes`, `tokens`, `cost_cents` logged on the task — sums over the ledger).
    `GET /tasks/{id}` adds `direction` (the latest redirect, or null), `last_outcome`,
    `latest_agent_note`, `display_summary` (`text` + `source`: description | redirect | agent) and
    `notes_url`. A `subproject` row is a nested project; its lifecycle is its own and it cannot be
    edited here.

    Machine-readable description: `GET #{base}/openapi.json`.
    """
  end

  defp curl_for(base, e) do
    path = String.replace(e.path, "{id}", "$TASK")
    auth = if e.auth, do: ~s| -H "Authorization: Bearer $PKP_TOKEN"|, else: ""
    idem = if e.idempotency, do: ~s| -H "Idempotency-Key: $(uuidgen)"|, else: ""

    case {e.method, e.example} do
      {"GET", _} ->
        "curl#{auth} #{base}#{path}"

      {method, nil} ->
        "curl -X #{method}#{auth}#{idem} #{base}#{path}"

      {method, example} ->
        ~s|curl -X #{method}#{auth}#{idem} -H "Content-Type: application/json" -d '#{example}' #{base}#{path}|
    end
  end

  @doc "The OpenAPI 3.1 document."
  @spec openapi() :: map()
  def openapi do
    base = base_path()

    paths =
      endpoints()
      |> Enum.group_by(& &1.path)
      |> Map.new(fn {path, eps} ->
        {path,
         Map.new(eps, fn e ->
           {String.downcase(e.method), operation(e)}
         end)}
      end)

    %{
      openapi: "3.1.0",
      info: %{
        title: "Projects API",
        version: @version,
        description:
          "The JSON API an agent drives one project with. Read #{base}/llms.txt first: it carries the rules (units, idempotency, what to retry) in prose."
      },
      servers: [%{url: base}],
      components: %{
        securitySchemes: %{
          projectKey: %{
            type: "http",
            scheme: "bearer",
            description:
              "A project API key, `pkp_…`, minted on the project's Modules & Features page."
          }
        },
        schemas: %{
          Error: %{
            type: "object",
            required: ["error"],
            properties: %{
              error: %{
                type: "object",
                required: ["code", "message"],
                properties: %{
                  code: %{type: "string", enum: Enum.map(@errors, &elem(&1, 1)) |> Enum.uniq()},
                  message: %{type: "string"},
                  details: %{type: "object"}
                }
              }
            }
          },
          Task: %{
            type: "object",
            properties: %{
              uuid: %{type: "string", format: "uuid"},
              kind: %{type: "string", enum: ["task", "subproject"]},
              title: %{type: "string"},
              description: %{type: ["string", "null"]},
              status: %{type: "string", enum: ["todo", "in_progress", "done"]},
              allowed_transitions: %{
                type: "array",
                items: %{type: "string", enum: ["todo", "in_progress", "done"]}
              },
              priority: %{type: "string", enum: ["urgent", "high", "normal", "low"]},
              progress_pct: %{type: "integer", minimum: 0, maximum: 100},
              estimated_duration: %{type: ["integer", "null"], minimum: 1},
              estimated_duration_unit: %{
                type: ["string", "null"],
                enum: ["minutes", "hours", "days", "weeks", "fortnights", "months", "years", nil]
              },
              position: %{type: "integer"},
              task_uuid: %{type: ["string", "null"], format: "uuid"},
              child_project_uuid: %{type: ["string", "null"], format: "uuid"},
              library_task: %{type: "boolean"},
              completed_at: %{type: ["string", "null"], format: "date-time"},
              inserted_at: %{type: "string", format: "date-time"},
              updated_at: %{type: "string", format: "date-time"}
            }
          },
          Project: %{
            type: "object",
            properties: %{
              uuid: %{type: "string", format: "uuid"},
              name: %{type: "string"},
              description: %{type: ["string", "null"]},
              start_mode: %{type: "string"},
              started_at: %{type: ["string", "null"], format: "date-time"},
              completed_at: %{type: ["string", "null"], format: "date-time"},
              archived_at: %{type: ["string", "null"], format: "date-time"},
              workflow_status: %{type: ["string", "null"]},
              available_workflow_statuses: %{
                type: "array",
                items: %{
                  type: "object",
                  properties: %{slug: %{type: "string"}, name: %{type: ["string", "null"]}}
                }
              }
            }
          }
        }
      },
      paths: paths
    }
  end

  defp operation(e) do
    body_params = Enum.filter(e.params, &(&1.in == :body))
    path_params = Enum.filter(e.params, &(&1.in == :path))
    query_params = Enum.filter(e.params, &(&1.in == :query))

    parameters =
      Enum.map(path_params ++ query_params, fn p ->
        %{
          name: p.name,
          in: Atom.to_string(p.in),
          required: p.required,
          description: p.doc,
          schema: %{type: schema_type(p.type)}
        }
      end) ++
        case e.idempotency do
          nil ->
            []

          mode ->
            [
              %{
                name: "Idempotency-Key",
                in: "header",
                required: mode == :required,
                description:
                  "A unique string per attempt; a retry with the same key replays the first response.",
                schema: %{type: "string", maxLength: 128}
              }
            ]
        end

    op = %{
      operationId: e.id,
      summary: e.summary,
      description:
        [
          e.scope && "Needs scope `#{e.scope}`.",
          e.action && "Needs the key's role to allow `#{e.action}` on the project.",
          e.feature && "Needs the project's `#{e.feature}` feature on."
        ]
        |> Enum.filter(& &1)
        |> Enum.join(" "),
      parameters: parameters,
      responses: %{
        "200" => %{description: "OK"},
        "401" => %{
          description: "Unauthorized",
          content: %{"application/json" => %{schema: %{"$ref" => "#/components/schemas/Error"}}}
        },
        "403" => %{
          description: "Forbidden",
          content: %{"application/json" => %{schema: %{"$ref" => "#/components/schemas/Error"}}}
        },
        "404" => %{
          description: "Not found",
          content: %{"application/json" => %{schema: %{"$ref" => "#/components/schemas/Error"}}}
        },
        "409" => %{
          description: "Conflict",
          content: %{"application/json" => %{schema: %{"$ref" => "#/components/schemas/Error"}}}
        },
        "422" => %{
          description: "Validation failed",
          content: %{"application/json" => %{schema: %{"$ref" => "#/components/schemas/Error"}}}
        },
        "429" => %{
          description: "Rate limited: wait Retry-After seconds, then retry the same request",
          headers: %{
            "Retry-After" => %{schema: %{type: "integer"}, description: "seconds to wait"}
          },
          content: %{"application/json" => %{schema: %{"$ref" => "#/components/schemas/Error"}}}
        }
      },
      security: if(e.auth, do: [%{projectKey: []}], else: [])
    }

    if body_params == [] do
      op
    else
      Map.put(op, :requestBody, %{
        required: Enum.any?(body_params, & &1.required),
        content: %{
          "application/json" => %{
            schema: %{
              type: "object",
              required: body_params |> Enum.filter(& &1.required) |> Enum.map(& &1.name),
              properties:
                Map.new(body_params, fn p ->
                  {p.name, %{type: schema_type(p.type), description: p.doc}}
                end)
            },
            example: e.example && Jason.decode!(e.example)
          }
        }
      })
    end
  end

  defp schema_type("uuid"), do: "string"
  defp schema_type(t), do: t
end
