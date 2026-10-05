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

  @doc "Every endpoint, in the order the docs list them: this module's, then the extension providers' (`/ext/…`)."
  @spec endpoints() :: [endpoint()]
  def endpoints do
    static_endpoints() ++ provider_endpoints()
  end

  # Rows an extension's API provider documents itself with; a provider
  # that fails to answer costs only its own rows.
  defp provider_endpoints do
    PhoenixKitProjects.Extensions.api_providers()
    |> Enum.flat_map(fn %{module: mod} ->
      if function_exported?(mod, :docs, 0), do: List.wrap(mod.docs()), else: []
    end)
  rescue
    _ -> []
  end

  defp static_endpoints do
    [
      %{
        id: "getMe",
        method: "GET",
        path: "/me",
        summary:
          "Who this key is: its name, the person it acts for (`acting_for`, null for a shared agent), the role it acts with right now, its scopes, the project, which features are on, the actions the role allows, and where these docs are. Read this first.",
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
        params: [
          %{
            name: "project",
            in: :query,
            type: "string",
            required: false,
            doc:
              "a sub-project's uuid (from `subprojects` on /project) to act on it instead of the key's own project"
          }
        ],
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
            name: "project",
            in: :body,
            type: "string",
            required: false,
            doc:
              "a sub-project's uuid (from `subprojects` on /project) to act on it instead of the key's own project"
          },
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
        id: "createSubproject",
        method: "POST",
        path: "/subprojects",
        summary:
          "Create a sub-project: a new project nested in this one, appearing on its task list as a row of kind `subproject`. Group a piece of work (a feature, a deliverable) under one, then create its tasks with `project` set to the new uuid. Answers with the new project and the row that links it.",
        auth: true,
        scope: "tasks:write",
        action: "create_tasks",
        feature: "subprojects",
        idempotency: :optional,
        params: [
          %{
            name: "completion",
            in: :body,
            type: "string",
            required: false,
            doc:
              "`auto` (ends when its last task is done) or `manual` (ongoing); left out, it copies the parent's"
          },
          %{
            name: "name",
            in: :body,
            type: "string",
            required: true,
            doc: "the sub-project's name"
          },
          %{
            name: "description",
            in: :body,
            type: "string",
            required: false,
            doc: "what it is for, short"
          },
          %{
            name: "project",
            in: :body,
            type: "string",
            required: false,
            doc:
              "nest it under a sub-project within reach instead of the key's own project (at most 7 levels down)"
          }
        ],
        example:
          ~s({"name": "3D editor", "description": "The furniture editor and everything it needs."})
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
            name: "updated_since",
            in: :query,
            type: "string",
            required: false,
            doc:
              "ISO 8601; only the tasks changed after that moment - remember the `now` of your last answer"
          },
          %{
            name: "project",
            in: :query,
            type: "string",
            required: false,
            doc:
              "a sub-project's uuid (from `subprojects` on /project) to act on it instead of the key's own project"
          },
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
          %{
            name: "interaction",
            in: :body,
            type: "string",
            required: false,
            doc:
              "a client interaction's uuid this task came out of (the interaction then lists it); the link is a mention token in the description"
          },
          %{
            name: "position",
            in: :body,
            type: "string",
            required: false,
            doc: "`top` to put it above every row; otherwise it is appended"
          },
          %{
            name: "origin",
            in: :body,
            type: "string",
            required: false,
            doc: "where it came from - `client`, `boss` (40 characters at most)"
          },
          %{
            name: "waiting_on",
            in: :body,
            type: "string",
            required: false,
            doc: "whom it waits on; a badge beside the status, not a status"
          },
          %{
            name: "labels",
            in: :body,
            type: "array",
            required: false,
            doc:
              "label names; existing ones are reused, new ones created (needs the project's labels feature)"
          },
          %{
            name: "checklist",
            in: :body,
            type: "array",
            required: false,
            doc: "sub-items: [{text, done?}] - ticked one by one, never driving progress_pct"
          },
          %{
            name: "project",
            in: :body,
            type: "string",
            required: false,
            doc:
              "a sub-project's uuid (from `subprojects` on /project) to act on it instead of the key's own project"
          },
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
          %{
            name: "interaction",
            in: :body,
            type: "string",
            required: false,
            doc: "link the task to a client interaction (added, never removed here)"
          },
          %{
            name: "origin",
            in: :body,
            type: "string",
            required: false,
            doc: "where it came from; empty or null clears it"
          },
          %{
            name: "waiting_on",
            in: :body,
            type: "string",
            required: false,
            doc: "whom it waits on; empty or null clears it (the task resumes)"
          },
          %{
            name: "labels",
            in: :body,
            type: "array",
            required: false,
            doc: "the full list of label names to set (a replace, not a merge)"
          },
          %{
            name: "checklist",
            in: :body,
            type: "array",
            required: false,
            doc:
              "the full checklist [{id?, text, done?}] - keep the ids to keep the items; or tick one item with PATCH /tasks/{id}/checklist/{item}"
          },
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
        id: "deleteTask",
        method: "DELETE",
        path: "/tasks/{id}",
        summary:
          "Delete a task, when the project's agent policy allows it (`agent_policy.delete_tasks`: none | own | any - `own` means a task this key created). A sub-project row is not deleted here.",
        auth: true,
        scope: "tasks:write",
        action: "delete_tasks",
        feature: "tasks",
        idempotency: nil,
        params: [%{name: "id", in: :path, type: "uuid", required: true, doc: ""}],
        example: nil
      },
      %{
        id: "tickChecklistItem",
        method: "PATCH",
        path: "/tasks/{id}/checklist/{item}",
        summary:
          "Tick or untick one checklist item by its id, without rewriting the list (safe when two sessions tick different items).",
        auth: true,
        scope: "tasks:write",
        action: "edit_tasks",
        feature: "tasks",
        idempotency: :optional,
        params: [
          %{name: "id", in: :path, type: "uuid", required: true, doc: ""},
          %{
            name: "item",
            in: :path,
            type: "string",
            required: true,
            doc: "the item's id from checklist_items"
          },
          %{name: "done", in: :body, type: "boolean", required: true, doc: ""}
        ],
        example: ~s({"done": true})
      },
      %{
        id: "linkInteraction",
        method: "POST",
        path: "/tasks/{id}/interactions/{interaction}",
        summary:
          "Link a task to a client interaction it came out of. A row of its own, so a rewrite of the description never unlinks; the description also carries the mention token so the forms show it. Idempotent.",
        auth: true,
        scope: "tasks:write",
        action: "edit_tasks",
        feature: "tasks",
        idempotency: nil,
        params: [
          %{name: "id", in: :path, type: "uuid", required: true, doc: ""},
          %{
            name: "interaction",
            in: :path,
            type: "uuid",
            required: true,
            doc: "an interaction of this project"
          }
        ],
        example: nil
      },
      %{
        id: "unlinkInteraction",
        method: "DELETE",
        path: "/tasks/{id}/interactions/{interaction}",
        summary: "Remove the link (the token in the text stays as history).",
        auth: true,
        scope: "tasks:write",
        action: "edit_tasks",
        feature: "tasks",
        idempotency: nil,
        params: [
          %{name: "id", in: :path, type: "uuid", required: true, doc: ""},
          %{name: "interaction", in: :path, type: "uuid", required: true, doc: ""}
        ],
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
            name: "project",
            in: :body,
            type: "string",
            required: false,
            doc:
              "a sub-project's uuid (from `subprojects` on /project) to act on it instead of the key's own project"
          },
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
          %{
            name: "estimated",
            in: :body,
            type: "boolean",
            required: false,
            doc: "true when tokens and cost are your estimate, not a count — kept on the entry"
          },
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
          %{
            name: "estimated",
            in: :body,
            type: "boolean",
            required: false,
            doc: "true when tokens and cost are your estimate, not a count — kept on the entry"
          },
          %{
            name: "project",
            in: :body,
            type: "string",
            required: false,
            doc:
              "a sub-project's uuid (from `subprojects` on /project) to act on it instead of the key's own project"
          },
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
        id: "listProjectNotes",
        method: "GET",
        path: "/notes",
        summary:
          "The project's own notes - decisions, research, the block you were in before a reset - oldest first; `since` keeps only the newer ones. Task notes stay under /tasks/{id}/notes.",
        auth: true,
        scope: "tasks:read",
        action: "view",
        feature: nil,
        idempotency: nil,
        params: [
          %{
            name: "since",
            in: :query,
            type: "string",
            required: false,
            doc: "ISO 8601; only notes after that moment"
          },
          %{
            name: "project",
            in: :query,
            type: "string",
            required: false,
            doc: "a sub-project's uuid"
          }
        ],
        example: nil
      },
      %{
        id: "createProjectNote",
        method: "POST",
        path: "/notes",
        summary:
          "A note on the project itself, the same shape as a task note (summary, outcome, next_steps, refs, usage); its usage lands in the ledger with no task. Use it for what is not about one task.",
        auth: true,
        scope: "tasks:write",
        action: "comment",
        feature: nil,
        idempotency: :required,
        params: [
          %{
            name: "summary",
            in: :body,
            type: "string",
            required: true,
            doc: "one line, 240 characters at most"
          },
          %{name: "content", in: :body, type: "string", required: false, doc: "the long text"},
          %{
            name: "outcome",
            in: :body,
            type: "string",
            required: false,
            doc: "done | partial | blocked | failed | needs_review"
          },
          %{
            name: "next_steps",
            in: :body,
            type: "string",
            required: false,
            doc: "2000 characters at most"
          },
          %{name: "refs", in: :body, type: "array", required: false, doc: "as on a task note"},
          %{
            name: "usage",
            in: :body,
            type: "object",
            required: false,
            doc: "{tokens, cost_cents, minutes, model, occurred_at} - needs usage:write"
          },
          %{
            name: "project",
            in: :body,
            type: "string",
            required: false,
            doc: "a sub-project's uuid"
          }
        ],
        example:
          ~s({"summary": "Rooms dropdown: the client wants the list, not a search", "outcome": "done"})
      },
      %{
        id: "briefing",
        method: "GET",
        path: "/briefing",
        summary:
          "Everything to pick the project up in one read: the project (completion mode, caught up?, what an agent may do), the open tasks with direction, last outcome, latest note summary and next steps, who started them, what they wait on, their checklist counts; the sub-projects one line each; the project's notes since a moment. Capped at 50 tasks by priority then position (`truncated` says so). Read this first after a context reset.",
        auth: true,
        scope: "tasks:read",
        action: "view",
        feature: "tasks",
        idempotency: nil,
        params: [
          %{
            name: "since",
            in: :query,
            type: "string",
            required: false,
            doc: "ISO 8601; project notes after that moment"
          },
          %{
            name: "limit",
            in: :query,
            type: "integer",
            required: false,
            doc: "open tasks to return, 50 at most"
          },
          %{
            name: "project",
            in: :query,
            type: "string",
            required: false,
            doc: "a sub-project's uuid"
          }
        ],
        example: nil
      },
      %{
        id: "listEntries",
        method: "GET",
        path: "/entries",
        summary:
          "The project's ledger entries, newest first (200 at most): time, tokens and cost, who recorded each, the task and the note it belongs to, whether it was an estimate. The read behind a correction: find the uuid, then PATCH or DELETE /entries/{id}.",
        auth: true,
        scope: "tasks:read",
        action: "view",
        feature: "ledger",
        idempotency: nil,
        params: [
          %{
            name: "limit",
            in: :query,
            type: "integer",
            required: false,
            doc: "200 by default, 1000 at most; `truncated` says when older rows exist beyond it"
          },
          %{
            name: "project",
            in: :query,
            type: "string",
            required: false,
            doc: "a sub-project's uuid"
          }
        ],
        example: nil
      },
      %{
        id: "listTaskEntries",
        method: "GET",
        path: "/tasks/{id}/entries",
        summary: "The ledger entries on one task, newest first.",
        auth: true,
        scope: "tasks:read",
        action: "view",
        feature: "ledger",
        idempotency: nil,
        params: [%{name: "id", in: :path, type: "uuid", required: true, doc: ""}],
        example: nil
      },
      %{
        id: "listEvents",
        method: "GET",
        path: "/events",
        summary:
          "The project's planned events - meetings, milestones, reviews - in time order: the plan an interaction's event_uuid points at. Needs the events extension on the project.",
        auth: true,
        scope: "tasks:read",
        action: "view",
        feature: "events",
        idempotency: nil,
        params: [
          %{
            name: "from",
            in: :query,
            type: "string",
            required: false,
            doc: "ISO 8601; events starting at or after"
          },
          %{
            name: "until",
            in: :query,
            type: "string",
            required: false,
            doc: "ISO 8601; events starting before"
          },
          %{
            name: "project",
            in: :query,
            type: "string",
            required: false,
            doc: "a sub-project's uuid"
          }
        ],
        example: nil
      },
      %{
        id: "getEvent",
        method: "GET",
        path: "/events/{id}",
        summary: "One planned event of this project.",
        auth: true,
        scope: "tasks:read",
        action: "view",
        feature: "events",
        idempotency: nil,
        params: [%{name: "id", in: :path, type: "uuid", required: true, doc: ""}],
        example: nil
      },
      %{
        id: "amendEntry",
        method: "PATCH",
        path: "/entries/{id}",
        summary:
          "Correct an entry: `minutes` on a time entry, `amount` on a tokens or cost entry (a corrected estimate beats a second row). Your own entries when the project's agent policy allows (`agent_policy.amend_own_ledger`); a manager key corrects anyone's. The amendment is traced in the activity feed with your key named.",
        auth: true,
        scope: "time:write",
        action: "log_time",
        feature: "ledger",
        idempotency: nil,
        params: [
          %{
            name: "id",
            in: :path,
            type: "uuid",
            required: true,
            doc: "the entry's uuid from the post that made it"
          },
          %{
            name: "minutes",
            in: :body,
            type: "integer",
            required: false,
            doc: "for a time entry: the corrected whole minutes"
          },
          %{
            name: "amount",
            in: :body,
            type: "integer",
            required: false,
            doc: "for a tokens or cost entry: the corrected whole figure"
          }
        ],
        example: ~s({"minutes": 25})
      },
      %{
        id: "removeEntry",
        method: "DELETE",
        path: "/entries/{id}",
        summary:
          "Remove an entry (time, tokens or cost) you recorded by mistake - your own under `amend_own_ledger`, anyone's with a manager key, never a billable one (403 `billable_entry`: amend it instead). What it held stays in the activity feed.",
        auth: true,
        scope: "time:write",
        action: "log_time",
        feature: "ledger",
        idempotency: nil,
        params: [%{name: "id", in: :path, type: "uuid", required: true, doc: ""}],
        example: nil
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
     "The project has this feature turned off (see `features` and `extensions` on /me). Do not retry."},
    {403, "membership_ended",
     "This key acts for a person who is no longer a member of the project. Do not retry; tell your operator."},
    {404, "not_found",
     "No such task, or no such project within this key's reach (its own project and the sub-projects under it). Reload /tasks or /project."},
    {403, "foreign_text",
     "The task's title or description were written by someone else and the project does not let an agent reword them (agent_policy.edit_foreign_text). Leave the words; add a note."},
    {403, "delete_not_allowed",
     "The project's agent policy does not let this key delete that task (agent_policy.delete_tasks)."},
    {403, "billable_entry",
     "A billable time entry is never removed over the API; amend it, or ask a person."},
    {403, "amend_not_allowed",
     "The entry is not this key's, or the project does not let an agent correct its own (agent_policy.amend_own_ledger)."},
    {409, "already_started",
     "Someone else started this task and the project does not let an agent take it over (agent_policy.take_started_task): you may not start, finish or reopen it; `details.started_by` says who. Pick another task."},
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
    > their lifecycle, and report the minutes, tokens and cost of the work. One key = one project
    > and every sub-project nested under it.

    Base URL: `#{base}` (relative to this site). Every path below is under it.
    Send and accept JSON (`Content-Type: application/json`). Ids are UUIDs.

    ## Authentication

    `Authorization: Bearer pkp_…` on every call except `/llms.txt` and `/openapi.json`.
    A project manager mints the key on the project's Modules & Features page and hands you the
    token once; keep it out of URLs, logs and tickets (use an environment variable, e.g. `$PKP_TOKEN`).
    A 401 means the key is gone or wrong — stop and tell your operator; never retry it.

    ## Start here

    `GET /me` tells you the project, whom you act for (`acting_for`), which features are on
    (`features` for the task calls, `extensions` for the `/ext/…` records), what your role may do
    (`allowed_actions`), the scopes your key carries, and the project's workflow statuses.
    The live set of calls that will work for you follows from that; read it before anything else.

    ## Sub-projects: grouping work, and how far your key reaches

    A project can nest projects. On the parent's task list a nested one is a row of kind
    `subproject`; the nested project has its own tasks, workflow status, time and usage, and
    rolls its progress up into that row. Use one sub-project per piece of work that has many
    tasks (a feature, a deliverable, a test campaign) so the parent's list stays readable and
    the group's totals are one row.

    Your key reaches its own project **and everything nested under it**, with the same role
    and scopes everywhere. To work in a sub-project:

    - `GET /project` lists `subprojects` (uuid, name, status); `parent_uuid` says where you are.
    - Project-level calls take `project` — `GET /project?project=…`, `GET /tasks?project=…`,
      and `project` in the body of `POST /tasks`, `POST /time`, `POST /usage`,
      `POST /project/status`, `POST /subprojects` (and the `/ext/…` lists and creates).
      Without it they act on the key's own project.
    - Task-level calls (`/tasks/{id}…`) need nothing extra: a task is found anywhere within
      reach, and the call acts in that task's project (its features and role floors apply).
    - `POST /subprojects` creates one (`name`, optional `description`); nest deeper by passing
      `project`. A project outside your reach — a sibling, a parent — is a 404.

    Typical start: `GET /project` → no sub-project for the work yet → `POST /subprojects`
    `{"name": "…"}` → `POST /tasks` `{"title": "…", "project": "<its uuid>"}` for each task → work
    through them with `/tasks/{id}/start`, notes, time and `/complete` as usual.

    ## Settings that shape what you may do

    `features` on /me is every gate of the task tracker (`labels`, `dependencies`, `subprojects`,
    …); `extensions` says which records exist beyond tasks (`crm_client` for the client's
    interactions and company, `events` for the planned events).

    `/me` and `/project` carry `agent_policy`, the project's own answers to four questions:
    `take_started_task` (may you move a task someone else started - start, finish or reopen it -
    else 409 `already_started`; a task nobody started, or that you started, is yours to move),
    `edit_foreign_text` (may you reword a task whose words are not yours - else 403 `foreign_text`;
    a task's title and description belong to whoever wrote them LAST: words you wrote are yours
    until a person rewords them in the form, and then they are the person's - `words_by` on the
    task says which), `delete_tasks` (`none` | `own` | `any` - own means created by your key), and
    `amend_own_ledger` (may you correct or remove your own time and usage entries; a manager key
    corrects anyone's). Every task says who created it and who started it (`created_by`,
    `started_by`: a person and/or a key - compare the key with yours from /me). Read the policy
    once; do not probe for 403s.

    `completion` on a project is how it ends: `auto` completes it when its last open row is done;
    `manual` is ongoing work - every task done is `caught_up: true`, never completed, and the
    client's next idea is just the next task. An ongoing sub-project never completes its parent.
    New sub-projects copy the parent's mode unless you pass `completion`.

    ## On a task: waiting, origin, labels, a checklist

    - `waiting_on` - whom the task waits on ("the client", "the boss"). A badge beside the status,
      not a status: a waiting task is still todo or in_progress. Clear it when the wait is over.
    - `origin` - where a relayed item came from ("client", "boss"); 40 characters.
    - `labels` - the project's labels by name (needs the labels feature); on create or update, the
      full list to set. New names are created for you.
    - `checklist` - sub-items ticked one by one: four questions relayed from a client are one
      task with four items, not four tasks and not a sub-project. Create with `checklist:
      [{text}]`, tick with `PATCH /tasks/{id}/checklist/{item}`; the task shows `checklist:
      {done, total}` on the list and `checklist_items` on the detail. Ticking never moves the
      task's status or `progress_pct` - finish the task with `/complete` as usual.
    - `position: "top"` on create puts the task above every row.

    ## Links between records: the mention token

    A task's link to a client interaction is a row of its own: the interaction may belong to the
    project above the task's sub-project (the client sits on the parent) - the lookup walks up
    within your reach, and an unknown one is a 404 before any task is created. `interaction: <uuid>` on
    `POST`/`PATCH /tasks`, or `POST /tasks/{id}/interactions/{uuid}` (and `DELETE` to unlink), or
    `tasks: [<uuid>]` on an interaction create or update. A task answers `interactions: [<uuid>]`;
    an interaction answers `tasks`. Rewriting a description never unlinks. The description also
    carries the **mention token** the forms use, `#[crm_interaction:<uuid>|<label>]` (other types:
    `project`, `project_task`), so people see the link in the text; you never write the token
    yourself. For a note, a ref `{type: "interaction", id: <uuid>}` is the convention; it is not
    resolved.

    ## Picking up after a reset, and polling

    `GET /briefing` is the one read that restores your state. Read `resume` first: your own
    latest note (its task, summary and next steps) - where you left off. Then `tasks`, in the
    order to work them: what your key already has in progress, then what is ready (priority,
    then position), then what waits on someone; `counts` says how many of each, `open_total` and
    `truncated` whether the list was cut. `done_today` is a tail of what was finished in the
    last day (for the daily story). Then the project and its policy, the sub-projects one line
    each, the project's notes since a moment, the client's latest interactions
    (`client.interactions` — from the nearest project above that holds the client, when you
    work in a sub-project; `client.project_uuid` says which) and the next planned events
    (`events`). Every task row carries its `interactions`. Then poll `GET /tasks?updated_since=<the now of your last answer>` no more than
    once a minute; it answers what changed at or after that moment (inclusive, so a change in
    the same second is never lost - dedupe by uuid) and `now` for the next round.

    What is not about one task - a decision, research the client asked for, the state you were
    in before a context reset - goes to `POST /notes`, the project's own notes, same shape as a
    task note; `GET /notes?since=` reads them back. Keep the daily story there, keep task notes
    on their tasks.

    ## Rules that trip agents up

    - **Units:** `minutes` are whole minutes (not hours, not decimals); `tokens` whole counts;
      `cost_cents` whole cents (5 means $0.05 — never send dollars); `progress_pct` 0–100.
    - **No pagination:** `/tasks` returns the whole list. There is no `page` parameter.
    - **No "my" tasks:** a key sees every task its role allows. Filter by `status` (`open` = not done).
    - **Status moves are explicit:** `PATCH /tasks/{id}` never changes status. Use `/transition`
      (or `/start`, `/complete`, `/reopen`) and obey `allowed_transitions` on the task.
    - **Appends are forever:** time and usage entries cannot be edited or deleted. Every such POST
      must carry an `Idempotency-Key`; retry a timeout with the SAME key and you get the original
      response back, never a second row (the replay carries the header `Idempotent-Replayed: true`,
      with the same status as the first answer). Derive the key from the CONTENT — task, kind,
      what you are reporting, the turn it belongs to — not from a random draw, so a turn replayed
      after a restart or a context reset posts once. `POST /tasks`, `POST /subprojects` and the
      transitions honour the header too.
    - **Completing the last open task completes the project** (its `completed_at` is set) — and
      when that project is a sub-project whose row was the parent's last open one, the parent
      completes too; reopening the task reopens them. Mean it: a throwaway task you complete can
      close a real project.
    - **Tokens and cost you cannot see:** send `estimated: true` on a usage post (or in a note's
      `usage`) when the figures are your estimate rather than a count; every entry answers with
      `estimated`, `model`, who recorded it and the note it came with.
    - **Workflow statuses belong to the project**, not to tasks: `POST /project/status`, with a slug
      from `available_workflow_statuses`. Tasks have only todo / in_progress / done.
    - **Who did it:** your time and usage are recorded as this key (AI time, apart from people's;
      never billable). Task changes are logged under the person this key acts for (`acting_for`
      in /me; for a shared agent, the person who minted it), with the key named — you are their
      AI, say so when it matters. A personal key acts with that person's current project role,
      never above manager; once they leave the project every call answers 403 `membership_ended`.
    - **When it happened:** time and usage carry the receipt time unless you send `occurred_at`
      (ISO 8601, not in the future) — do so when you report in a batch after the work.
    - **Notes, not essays, in the description:** the task's `description` is the short human text.
      Everything long — reasoning, what you changed, what came out — goes to `POST /tasks/{id}/notes`
      with a one-line `summary` (240 characters at most), your `outcome` for the attempt,
      `next_steps` (2000 at most), `refs` (commits, branches, PRs; 20 at most) and the `usage`
      it cost, all in one call; `content` is the long text and has no fixed cap, but a human
      reads it, so keep it to what the next worker needs. Before you work on a task, `GET /tasks/{id}`: if
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
    Plus `waiting_on`, `origin`, `labels` (names), `checklist` (`{done, total}`), `created_by` and
    `started_by` (`{person, key}` uuids - null for a person's own doing), `words_by` (`{key}` when
    an API key wrote the title and description last, `{person: true}` otherwise), `interactions`
    (the client interactions it links), `updated_at`; on a `subproject` row, `subproject`
    (`{completion, caught_up, caught_up_since, completed_at}` of the nested project - an ongoing
    child reads in_progress at 100% when caught up, this says so).
    `GET /tasks/{id}` adds `checklist_items` (`[{id, text, done, done_at}]`), `direction` (the latest redirect, or null), `last_outcome`,
    `latest_agent_note`, `display_summary` (`text` + `source`: description | redirect | agent) and
    `notes_url`. A `subproject` row is a nested project: its lifecycle is its own, the row's status
    and progress roll up from it, and its tasks are reached with `project=<child_project_uuid>`
    (see Sub-projects above).

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
              "A project API key, `pkp_…`: a member's own key from the project's \"Your API key\" page, or a shared agent's from Modules & Features."
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
