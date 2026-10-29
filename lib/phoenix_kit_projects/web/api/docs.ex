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
          "Who this key is: its name, the person it acts for (`acting_for`, null for a shared agent; its `person_uuid` is what `assignee: me` resolves to), its home project (`home_project`; `project` is the same, kept for older agents) with the role, scopes, features and allowed actions there, and EVERY project it reaches (`projects`: key, uuid, name, role, `access` per area, `source`). Read this first; pass `project=<key>` to work anywhere but home.",
        auth: true,
        scope: nil,
        action: nil,
        feature: nil,
        idempotency: nil,
        params: [],
        example: nil
      },
      %{
        id: "listPeople",
        method: "GET",
        path: "/people",
        summary:
          "Who a task can be for: the staff people (`me: true` on the one this key acts for), teams and departments, by uuid and name. Use it to assign a task to a colleague you were given by name.",
        auth: true,
        scope: "people:read",
        action: "view",
        feature: "assignees",
        idempotency: nil,
        params: [
          %{
            name: "q",
            in: :query,
            type: "string",
            required: false,
            doc: "part of a name; narrows all three lists"
          }
        ],
        example: nil
      },
      %{
        id: "getProject",
        method: "GET",
        path: "/project",
        summary:
          "The key's project: name, dates, the current workflow status and the statuses available to it.",
        auth: true,
        scope: "project:read",
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
              "another project's key or uuid (from `projects` on /me, or `subprojects` on /project) to act there instead of the key's home project"
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
              "another project's key or uuid (from `projects` on /me, or `subprojects` on /project) to act there instead of the key's home project"
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
              "nest it under another project the key reaches instead of the home project (at most 7 levels down)"
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
          "Every task of the project the key may see, in plan order — depth first, so a task is followed by the tasks under it (`parent_task` and `depth` on each say where it sits). No pagination: the whole list comes back. The key sees every task its role allows — there is no notion of \"my\" tasks for a key.",
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
            name: "assignee",
            in: :query,
            type: "string",
            required: false,
            doc:
              "`me`, `none` (unassigned) or a person's uuid; only the tasks assigned to that person"
          },
          %{
            name: "due_before",
            in: :query,
            type: "string",
            required: false,
            doc:
              "`YYYY-MM-DD`; only the tasks whose `end_date` is on or before that day - with `status=open`, what is still owed by then"
          },
          %{
            name: "project",
            in: :query,
            type: "string",
            required: false,
            doc:
              "another project's key or uuid (from `projects` on /me, or `subprojects` on /project) to act there instead of the key's home project"
          },
          %{
            name: "status",
            in: :query,
            type: "string",
            required: false,
            doc: "waiting | todo | in_progress | done | open (= not done)"
          },
          %{
            name: "parent",
            in: :query,
            type: "string",
            required: false,
            doc:
              "`none` for the top-level tasks only, or a task's ref or uuid for the tasks directly under it; leave it out for every task at any depth"
          }
        ],
        example: nil
      },
      %{
        id: "createTask",
        method: "POST",
        path: "/tasks",
        summary:
          "Create a task at the bottom of the plan, or last under `parent`. It starts as waiting (idle — nobody is asked yet) and is NOT started: transition it to todo (“can be started”, which tells its people) or call /tasks/{id}/start to begin it. It is unassigned unless you pass `assignee`. For several tasks at once (a list relayed from a client) use POST /tasks/batch.",
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
            name: "assignee",
            in: :body,
            type: "string",
            required: false,
            doc:
              "who the task is for: `me` (the person this key acts for), a person's uuid from GET /people, or `{\"team\": uuid}` / `{\"department\": uuid}`; one assignee at a time. Needs the assignees feature and the assign_tasks action"
          },
          %{
            name: "start_date",
            in: :body,
            type: "string",
            required: false,
            doc: "the day work on it starts, `YYYY-MM-DD`; optional, and may stand alone"
          },
          %{
            name: "end_date",
            in: :body,
            type: "string",
            required: false,
            doc: "the day it is due, `YYYY-MM-DD`; never before `start_date`"
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
            name: "parent",
            in: :body,
            type: "string",
            required: false,
            doc:
              "a task's ref or uuid in this project: the new task sits under it, after the tasks already there (a subtask is a whole task - its own number, owner, dates and hours)"
          },
          %{
            name: "project",
            in: :body,
            type: "string",
            required: false,
            doc:
              "another project's key or uuid (from `projects` on /me, or `subprojects` on /project) to act there instead of the key's home project"
          },
          %{name: "title", in: :body, type: "string", required: true, doc: "up to a short line"},
          %{
            name: "description",
            in: :body,
            type: "string",
            required: false,
            doc:
              "a `#ACME-42` or `#ACME` in the text that names a task or project within the key's reach is stored as a link to it (read back as `#[project_task:uuid|ACME-42]`)"
          },
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
            name: "assignee",
            in: :body,
            type: "string",
            required: false,
            doc: "as on create; null clears it, leaving it out keeps it"
          },
          %{
            name: "start_date",
            in: :body,
            type: "string",
            required: false,
            doc: "`YYYY-MM-DD`; empty or null clears it"
          },
          %{
            name: "end_date",
            in: :body,
            type: "string",
            required: false,
            doc: "`YYYY-MM-DD`, never before `start_date`; empty or null clears it"
          },
          %{
            name: "deadline",
            in: :body,
            type: "string",
            required: false,
            doc:
              "by when it has to be done, ISO 8601 with an offset (`2026-10-29T15:00:00+02:00`); null clears it"
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
            name: "parent",
            in: :body,
            type: "string",
            required: false,
            doc:
              "move the task, with everything under it, to the end of this task's subtasks; null moves it to the top level; leaving it out keeps it where it is (POST /tasks/{id}/move places it exactly)"
          },
          %{name: "id", in: :path, type: "uuid", required: true, doc: ""},
          %{name: "title", in: :body, type: "string", required: false, doc: ""},
          %{
            name: "description",
            in: :body,
            type: "string",
            required: false,
            doc:
              "a `#ACME-42` or `#ACME` in the text that names a task or project within the key's reach is stored as a link to it (read back as `#[project_task:uuid|ACME-42]`)"
          },
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
          "Move a task through its lifecycle: waiting → todo, in_progress or done; todo → waiting, in_progress or done; in_progress → done or todo; done → todo. `waiting` is idle (the default for a new task); `todo` is released — shown as \"can be started\" — and moving a waiting task there tells its people it is their turn. Any other move answers 409 invalid_transition with `allowed_transitions` — reload the task and pick one of those. Completing a task completes every open task under it; when the last task under a parent is done, the parent completes too (unless the project turned that off); reopening a task reopens the done tasks above it; reopening a parent leaves the tasks under it as they are. `also_changed` says how many other tasks moved. Completing a task may complete the project; reopening one may reopen it.",
        auth: true,
        scope: "status:write",
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
            doc: "waiting | todo | in_progress | done"
          },
          %{
            name: "reason",
            in: :body,
            type: "string",
            required: false,
            doc:
              "when reopening: what is wrong or missing - posted to the task's discussion and quoted in the notice the assignee gets"
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
        scope: "status:write",
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
        scope: "status:write",
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
        scope: "status:write",
        action: "update_status",
        feature: "tasks",
        idempotency: :optional,
        params: [
          %{name: "id", in: :path, type: "uuid", required: true, doc: ""},
          %{
            name: "reason",
            in: :body,
            type: "string",
            required: false,
            doc:
              "when reopening: what is wrong or missing - posted to the task's discussion and quoted in the notice the assignee gets"
          }
        ],
        example: ~s({"reason": "The cutting list has the wrong board thickness."})
      },
      %{
        id: "deleteTask",
        method: "DELETE",
        path: "/tasks/{id}",
        summary:
          "Delete a task, when the project's agent policy allows it (`agent_policy.delete_tasks`: none | own | any - `own` means a task this key created). A task with tasks under it answers 409 has_subtasks with their count unless `cascade=true`, which deletes them too (each must be one the policy lets you delete; the answer lists them in `also_deleted`). A sub-project row is not deleted here.",
        auth: true,
        scope: "tasks:write",
        action: "delete_tasks",
        feature: "tasks",
        idempotency: nil,
        params: [
          %{name: "id", in: :path, type: "uuid", required: true, doc: ""},
          %{
            name: "cascade",
            in: :query,
            type: "boolean",
            required: false,
            doc: "`true` to delete the tasks under it as well"
          }
        ],
        example: nil
      },
      %{
        id: "moveTask",
        method: "POST",
        path: "/tasks/{id}/move",
        summary:
          "Put a task, with everything under it, somewhere else in the project's outline. A task cannot go under itself or under a task below it (409 cycle). An open task moved under a done one reopens it.",
        auth: true,
        scope: "tasks:write",
        action: "edit_tasks",
        feature: "tasks",
        idempotency: :optional,
        params: [
          %{name: "id", in: :path, type: "uuid", required: true, doc: ""},
          %{
            name: "parent",
            in: :body,
            type: "string",
            required: false,
            doc:
              "the task to sit under (ref or uuid); null for the top level; leave it out to stay under the same parent"
          },
          %{
            name: "after",
            in: :body,
            type: "string",
            required: false,
            doc:
              "a task under that parent to go right after; null to go first; leave it out to go last"
          }
        ],
        example: ~s({"parent": "ACME-40", "after": "ACME-41"})
      },
      %{
        id: "batchCreateTasks",
        method: "POST",
        path: "/tasks/batch",
        summary:
          "Create many one-off tasks at once, in one transaction - a list relayed from a client, pasted notes. One task per line, in order, nested by `depth`; blank lines are skipped. Answers 201 with the tasks in line order.",
        auth: true,
        scope: "tasks:write",
        action: "create_tasks",
        feature: "tasks",
        idempotency: :optional,
        params: [
          %{
            name: "lines",
            in: :body,
            type: "array",
            required: true,
            doc:
              "at most 500; each a string (the title) or `{text, depth?, done?}` - `depth` 0 sits under `parent` (or at the top level), 1 under the line above it, and so on; `done: true` creates it done"
          },
          %{
            name: "parent",
            in: :body,
            type: "string",
            required: false,
            doc: "a task's ref or uuid: the lines go under it, after the tasks already there"
          },
          %{
            name: "project",
            in: :body,
            type: "string",
            required: false,
            doc:
              "another project's key or uuid (from `projects` on /me, or `subprojects` on /project) to act there instead of the key's home project"
          }
        ],
        example:
          ~s({"parent": "ACME-40", "lines": ["Which rooms?", "Matte or gloss?", {"text": "Delivery date", "depth": 0}, {"text": "Ask about Saturdays", "depth": 1}]})
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
              "another project's key or uuid (from `projects` on /me, or `subprojects` on /project) to act there instead of the key's home project"
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
              "another project's key or uuid (from `projects` on /me, or `subprojects` on /project) to act there instead of the key's home project"
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
        scope: "notes:read",
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
        scope: "notes:write",
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
        id: "listTaskComments",
        method: "GET",
        path: "/tasks/{id}/comments",
        summary:
          "The task's discussion — the thread people read and write under the task — oldest first: `{uuid, parent, author, content, inserted_at}`, `parent` set on a reply. Apart from your notes (/tasks/{id}/notes), which are your own record. Needs the comments module switched on for the site.",
        auth: true,
        scope: "comments:read",
        action: "view",
        feature: nil,
        idempotency: nil,
        params: [%{name: "id", in: :path, type: "uuid", required: true, doc: ""}],
        example: nil
      },
      %{
        id: "createTaskComment",
        method: "POST",
        path: "/tasks/{id}/comments",
        summary:
          "Add to the task's discussion, as the person the key acts for (a shared agent: the person who made it), labelled with the key's name. For talking to people; your working record goes in a note. Append-only: send an Idempotency-Key.",
        auth: true,
        scope: "comments:write",
        action: "comment",
        feature: nil,
        idempotency: :required,
        params: [
          %{name: "id", in: :path, type: "uuid", required: true, doc: ""},
          %{
            name: "content",
            in: :body,
            type: "string",
            required: true,
            doc: "the comment, at most 10000 bytes; #ACME-42 refs become links"
          },
          %{
            name: "parent",
            in: :body,
            type: "uuid",
            required: false,
            doc: "the comment this one replies to"
          }
        ],
        example: ~s({"content": "Done on dev — can someone check the import on staging?"})
      },
      %{
        id: "listProjectNotes",
        method: "GET",
        path: "/notes",
        summary:
          "The project's own notes - decisions, research, the block you were in before a reset - oldest first; `since` keeps only the newer ones. Task notes stay under /tasks/{id}/notes.",
        auth: true,
        scope: "notes:read",
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
        scope: "notes:write",
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
          "Everything to pick the project up in one read: the project (completion mode, caught up?, what an agent may do), the open top-level tasks with direction, last outcome, latest note summary and next steps, who started them, what they wait on, how many of the tasks under them are done (`subtasks`) - plus any task your key has in hand, wherever it sits; the sub-projects one line each; the project's notes since a moment. Capped at 50 tasks by priority then position (`truncated` says so). Read this first after a context reset.",
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
        id: "getHours",
        method: "GET",
        path: "/hours",
        summary:
          "Logged time summed for a period: `totals` (people's minutes, billable minutes, an agent's `ai_minutes`, tokens, cost, entries, people) and one grouping in `groups` — by person (default), by task or by day. Reads the project and, unless `include_subprojects=false`, everything nested under it. A period is cut on when the work was done (`occurred_at`, else when it was recorded); days are UTC days. The same figures as the Hours tab.",
        auth: true,
        scope: "time:read",
        action: "view",
        feature: "ledger",
        idempotency: nil,
        params: [
          %{
            name: "from",
            in: :query,
            type: "string",
            required: false,
            doc: "a day (`2026-10-01`, UTC) or an ISO 8601 datetime; absent = from the beginning"
          },
          %{
            name: "to",
            in: :query,
            type: "string",
            required: false,
            doc: "a day, INCLUDED, or an ISO 8601 datetime, excluded; absent = until now"
          },
          %{
            name: "group_by",
            in: :query,
            type: "string",
            required: false,
            doc: "`person` (default), `task` or `day`"
          },
          %{
            name: "worker",
            in: :query,
            type: "string",
            required: false,
            doc:
              "a `worker.key` from a `group_by=person` answer (`user:<uuid>`, `staff_person:<uuid>`, `ai_agent:<uuid>`), several comma-separated"
          },
          %{
            name: "billable",
            in: :query,
            type: "boolean",
            required: false,
            doc: "`true` = billable entries only, `false` = the rest"
          },
          %{
            name: "include_subprojects",
            in: :query,
            type: "boolean",
            required: false,
            doc: "`true` by default"
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
        scope: "time:read",
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
        scope: "time:read",
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
          "The project's own calendar events - milestones, reviews, internal dates - in time order. A meeting planned with the client is NOT here: it is an interaction with status planned (GET /ext/interactions?status=planned). Needs the events extension on the project.",
        auth: true,
        scope: "events:read",
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
        scope: "events:read",
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
        scope: "time:write for a time entry, usage:write for a tokens or cost entry",
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
        scope: "time:write for a time entry, usage:write for a tokens or cost entry",
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
    {403, "scope_missing",
     "The key's access in this project does not cover this call (the area is none, or read where it needs write). Access is set per project: check `projects` on /me. Do not retry."},
    {403, "feature_disabled",
     "The project has this feature turned off (see `features` and `extensions` on /me). Do not retry."},
    {403, "membership_ended",
     "This key acts for a person who is no longer a member of the project (or of the project its access there comes from). Do not retry there; other projects on /me may still work — tell your operator."},
    {403, "no_access",
     "The call stayed in the key's home project and the key has no access there any more (`home_refused` on /me). Name another project with `project`, or tell your operator."},
    {404, "not_found",
     "No such task, or no such project within this key's reach (the projects listed under `projects` on /me). Reload /me, /tasks or /project."},
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

    > The JSON API an agent drives projects with: read and create tasks, move them through
    > their lifecycle, talk in their discussions, and report the minutes, tokens and cost of the
    > work. One key can reach several projects, with its own access in each; `GET /me` lists them.

    Base URL: `#{base}` (relative to this site). Every path below is under it.
    Send and accept JSON (`Content-Type: application/json`). Ids are UUIDs; a project and a
    task also have a short name (see "Short names").

    ## Authentication

    `Authorization: Bearer pkp_…` on every call except `/llms.txt` and `/openapi.json`.
    A person makes the key on the site's Projects → API keys page, gives it access to one or
    more projects, and hands you the token once; keep it out of URLs, logs and tickets (use an environment variable, e.g. `$PKP_TOKEN`).
    A 401 means the key is gone or wrong — stop and tell your operator; never retry it.

    ## Start here

    `GET /me` tells you your home project (`home_project`), EVERY project the key reaches
    (`projects`, each with its `access` per area), whom you act for (`acting_for`), which features
    are on at home (`features` for the task calls, `extensions` for the `/ext/…` records), what
    your role may do there (`allowed_actions`), and the home project's workflow statuses.
    The live set of calls that will work for you follows from that; read it before anything else.

    First steps, in this order:

    1. `GET /me`. Note `home_project` and the `projects` list.
    2. To work in any project other than home, pass `project=<its key>` on project-level calls
       (`GET /briefing?project=3DE`, `GET /ext/interactions?project=ACME&of=client`). A task ref
       picks its own project: `GET /tasks/ACME-42` needs no `project`.
    3. Read each project's `access` before working there. Never assume one project's access from
       another's: a key may write tasks in one project and only read them, or nothing, in the next.

    ## Projects and access

    A key is not tied to one project. For each project it reaches it has a **grant**: one level
    per area — `none`, `read` or `write` (write includes read) — and a role cap. `projects` on
    /me answers, per project: `key`, `uuid`, `name`, `role` (the role you act with there),
    `access` (area → level), `scopes`, and `source` (`direct`, or `{inherited_from: <uuid>}` when
    the grant sits on a project above it).

    | Area | read | write |
    |---|---|---|
    | `project` | `GET /project` | `POST /project/status` |
    | `tasks` | `GET /tasks`, `GET /tasks/{id}`, `GET /briefing` | create, `PATCH`, move, batch, delete, `POST /subprojects`, task ↔ interaction links |
    | `status` | — | `start`, `complete`, `reopen`, `transition` |
    | `notes` | `GET /tasks/{id}/notes`, `GET /notes`; a task's `direction` / `latest_agent_note`, the briefing's `project_notes` | `POST /tasks/{id}/notes`, `POST /notes` |
    | `comments` | `GET /tasks/{id}/comments` | `POST /tasks/{id}/comments` |
    | `time` | `GET /entries`, `GET /tasks/{id}/entries`, `GET /hours`; `minutes` in a task's `totals` | `POST /time`, `POST /tasks/{id}/time`, correcting time entries |
    | `usage` | `tokens` and `cost_cents` in a task's `totals` and in `GET /hours` | `POST /usage`, `POST /tasks/{id}/usage`, `usage` on a note, correcting usage entries |
    | `events` | `GET /events`, `GET /events/{id}`; the briefing's `events` | — |
    | `people` | `GET /people` | — |

    Modules add their own areas — the CRM's client interactions are `interactions` read/write for
    `/ext/interactions`, and a task's `interactions` list. The scope a call needs is on each
    endpoint below; a call outside your access is 403 `scope_missing`, which no retry fixes. A
    field that belongs to an area you cannot read comes back empty (missing from `totals`, `null`,
    or `[]`) rather than refusing the whole call — empty there means "not yours to see", not
    "nothing logged".

    - **The nearest grant up the tree wins.** A sub-project with no grant of its own uses its
      parent's (when that grant covers sub-projects); a grant of its own — even one set to no
      access at all — overrides the parent's for it and everything below.
    - **Your role is capped.** A personal key acts with the weakest of the grant's role cap, the
      person's own role on the project the grant is on, and manager. A shared agent acts with the
      grant's role. The role decides what `allowed_actions` lets you do, exactly as for a person.
    - **Home project.** A call without `project` acts on the key's home project. Everything else
      needs `project=<its key>` (or its uuid). If the key can no longer use its home (its access
      there was removed, or its person left), /me says so in `home_refused` (`no_access` /
      `membership_ended`) with `home_project: null`, calls that stay home answer that 403, and
      calls naming another project still work.

    ## Short names: a project's key, a task's ref

    Every project has a `key` (`ACME`) and every task a `ref` — the key and the task's number
    in that project (`ACME-42`). They are what people say and what belongs in a commit message,
    a branch name or a note: `ACME-42: fix the hinge offset`.

    - Wherever a task's uuid goes in a path, its ref works too: `GET /tasks/ACME-42`,
      `POST /tasks/ACME-42/start`. Wherever `project` takes a uuid, the key works: `?project=3DE`.
      Case does not matter. A ref outside your reach is the same 404 as one that does not exist.
    - A task answers `ref`, `number` and `uuid`; a project `key` and `uuid`. A sub-project has
      its OWN key and numbers its tasks from 1; its row on the parent's list answers the child's
      key as `ref` (log work against the child's tasks, not the row) and its own place in the
      parent's list as `parent_ref`.
    - The uuid is the identity and never changes. A ref is a name: a project's key can be
      renamed (the old one keeps resolving, and is never given to another project), so STORE
      uuids and SHOW refs. A number is never reused; a deleted task leaves a gap.

    ## Sub-projects: grouping work, and how far your key reaches

    A project can nest projects. On the parent's task list a nested one is a row of kind
    `subproject`; the nested project has its own tasks, workflow status, time and usage, and
    rolls its progress up into that row. Use one sub-project per piece of work that has many
    tasks (a feature, a deliverable, a test campaign) so the parent's list stays readable and
    the group's totals are one row.

    A grant on a project normally covers everything nested under it (see "Projects and
    access" — a sub-project's own grant overrides it). To work in a sub-project:

    - `GET /project` lists `subprojects` (uuid, name, status); `parent_uuid` says where you are.
    - Project-level calls take `project` — `GET /project?project=…`, `GET /tasks?project=…`,
      and `project` in the body of `POST /tasks`, `POST /time`, `POST /usage`,
      `POST /project/status`, `POST /subprojects` (and the `/ext/…` lists and creates).
      Without it they act on the key's home project.
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

    ## Tasks under tasks

    A task can sit under another task of the same project, to any depth. A subtask is a whole
    task - its own number, owner, dates, hours and notes; there are no lighter "items". Four
    questions relayed from a client are four subtasks of one task, added in one call:

        POST /tasks/batch  {"parent": "ACME-40", "lines": ["Which rooms?", "Matte or gloss?",
                            "Delivery date?", "Saturday installs?"]}

    (or create the parent in the same batch: its line at depth 0, the questions at depth 1).
    `parent` on create and PATCH puts a task under another (null: back to the top level);
    `POST /tasks/{id}/move` places it exactly. Every task says `parent_task` (the ref above it, or
    null), `depth`, and `subtasks: {done, total}` - counted over the tasks at the bottom of its
    branch, the ones with nothing under them. `GET /tasks?parent=ACME-40` lists what is directly
    under one; `parent=none` the top level only.

    The tick rules, the same in the admin and here:
    - completing a task completes every open task under it (a sub-project row is left alone);
    - when the last task under a parent is done, the parent completes too - unless the project
      turned that off (a parent can carry work of its own);
    - reopening a task reopens the done tasks above it;
    - reopening a parent leaves the tasks under it as they are.
    A transition answers `also_changed`: how many other tasks it moved. Deleting a task with
    tasks under it needs `cascade=true`. A task somebody took out of the list in the admin while
    it carried work (hours, notes, an owner) is held, not deleted: it is in no list and no count
    until a person restores it.

    ## On a task: waiting, origin, labels

    - `waiting_on` - whom the task waits on ("the client", "the boss"). A badge beside the status,
      not a status: a task waiting on someone is still in whatever status it has. Clear it when the wait is over.
    - `origin` - where a relayed item came from ("client", "boss"); 40 characters.
    - `assignee` - who the task is FOR, apart from who made it (`created_by`) and who started it
      (`started_by`). On every row: `{kind, uuid, name}` (kind is person, team or department) or
      null. To set it on create or PATCH: `"me"` (the person this key acts for - `/me` gives their
      `acting_for.person_uuid`), a person's uuid from `GET /people`, `{"team": uuid}` or
      `{"department": uuid}`; null clears it; leaving the field out changes nothing. A task has one
      assignee. A task you create is unassigned unless you say so: when the work is the person's
      you act for, pass `assignee: "me"`; when they relay a task for a colleague, look the
      colleague up in `GET /people?q=<name>`. `GET /tasks?assignee=me` is that person's list, and
      the briefing marks those rows `assigned_to_me` and counts them. Needs the assignees feature
      and the `assign_tasks` action.
    - `start_date`, `end_date` - the task's own days, `YYYY-MM-DD`, both optional and either may
      stand alone; the end is never before the start. A day, not a moment: no time and no zone.
      A dated task sits on those days in the calendar and the timeline; an undated one is still
      placed by its duration and its place in the order. `GET /tasks?due_before=<day>&status=open`
      is what is planned to end by then.
    - `deadline` - by when it has to be done: an ISO 8601 date and time with its offset
      (`2026-10-29T15:00:00+02:00`), or null to clear. Independent of the planned days; `overdue`
      is true once the deadline has passed and the task is not done. Read-only beside it:
      `started_at` (when work really began, set on the way into in progress) and `completed_at`.
    - `labels` - the project's labels by name (needs the labels feature); on create or update, the
      full list to set. New names are created for you.
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
    work in a sub-project; `client.project_uuid` says which), what is planned with the client
    (`client.planned`, soonest first; `overdue: true` on one whose time has passed with no
    outcome said) and the project's next calendar events (`events`).

    **Planning with the client.** A plan is an interaction, not a calendar event:
    `POST /ext/interactions {status: "planned", occurred_at: <a future start>, …}` with who is
    coming in `parties` (they are notified) and `location`. It is the same record from then on —
    move it with a new `occurred_at`, and once it has happened `PATCH` it to
    `status: "happened"` with the real start, the length and what was discussed, or to
    `status: "cancelled"` saying why in `body` (a length is still welcome: the drive there
    cost time). Nothing turns a plan into a record by itself; one past its time waits with
    `overdue: true`. `GET /ext/interactions` without `status` is the record (happened and
    cancelled); `?status=planned` is the plan. Poll with `updated_since`, since a plan changes
    after you first see it. Every task row carries its `interactions`. Then poll `GET /tasks?updated_since=<the now of your last answer>` no more than
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
      from `available_workflow_statuses`. Tasks have only waiting / todo / in_progress / done.
    - **Who did it:** your time and usage are recorded as this key (AI time, apart from people's;
      never billable). Task changes are logged under the person this key acts for (`acting_for`
      in /me; for a shared agent, the person who minted it), with the key named — you are their
      AI, say so when it matters. A personal key acts with that person's current project role,
      never above manager; once they leave a project, calls there answer 403 `membership_ended`.
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
    Plus `waiting_on`, `origin`, `start_date`, `end_date`, `overdue`, `labels` (names), `parent_task` (the ref of the task it sits under, or null), `depth` (0 at the top level), `subtasks` (`{done, total}` over the tasks at the bottom of its branch; zeros when nothing is under it), `created_by` and
    `started_by` (`{person, key}` uuids - null for a person's own doing), `words_by` (`{key}` when
    an API key wrote the title and description last, `{person: true}` otherwise), `interactions`
    (the client interactions it links), `updated_at`; on a `subproject` row, `subproject`
    (`{completion, caught_up, caught_up_since, completed_at}` of the nested project - an ongoing
    child reads in_progress at 100% when caught up, this says so).
    `GET /tasks/{id}` adds `subtask_refs` (the tasks directly under it, in order), `direction` (the latest redirect, or null), `last_outcome`,
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
          "The JSON API an agent drives projects with. One key can reach several projects, with its own access in each (GET /me lists them). Read #{base}/llms.txt first: it carries the rules (units, idempotency, what to retry) in prose."
      },
      servers: [%{url: base}],
      components: %{
        securitySchemes: %{
          projectKey: %{
            type: "http",
            scheme: "bearer",
            description:
              "A projects API key, `pkp_…`, made on Projects → API keys: a person's own key, or a shared agent's. Its access is set per project; GET /me lists it."
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
              status: %{type: "string", enum: ["waiting", "todo", "in_progress", "done"]},
              allowed_transitions: %{
                type: "array",
                items: %{type: "string", enum: ["waiting", "todo", "in_progress", "done"]}
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
