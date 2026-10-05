defmodule PhoenixKitProjects.Web.Api.Json do
  @moduledoc """
  What every API controller shares: the error envelope, the checks a call
  passes before it does anything (scope, role floor, feature gate), the
  idempotency wrapper, and the JSON shapes of a task and a project.

  Errors are one shape, `{"error": {"code", "message", "details"?}}`, with
  a stable machine code and an English message (the API is locale-free; the
  codes are the contract, the messages are display text).
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias PhoenixKitProjects.{
    ApiKeys,
    Authz,
    Features,
    Labels,
    Ledger,
    Projects,
    Statuses,
    TaskNotes
  }

  alias PhoenixKitProjects.Schemas.{ApiKey, Assignment, Project, Task}
  alias PhoenixKitProjects.Web.Api.Docs

  @lifecycle ~w(todo in_progress done)
  @transitions %{
    "todo" => ~w(in_progress done),
    "in_progress" => ~w(done todo),
    "done" => ~w(todo)
  }

  @doc "The lifecycle states a task can be in, and the moves allowed from each."
  @spec lifecycle() :: [String.t()]
  def lifecycle, do: @lifecycle

  @spec transitions() :: %{String.t() => [String.t()]}
  def transitions, do: @transitions

  @doc "Sends the error envelope with `status` and halts nothing — the caller returns the conn."
  @spec error(Plug.Conn.t(), atom() | integer(), String.t(), String.t(), map() | nil) ::
          Plug.Conn.t()
  def error(conn, status, code, message, details \\ nil) do
    body = %{code: code, message: message}
    body = if details, do: Map.put(body, :details, details), else: body

    conn
    |> put_status(status)
    |> json(%{error: body})
  end

  @doc "The key must carry `scope`, else 403 `scope_missing`."
  @spec require_scope(Plug.Conn.t(), String.t()) :: {:ok, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
  def require_scope(conn, scope) do
    if ApiKey.scope?(conn.assigns.pk_api_key, scope),
      do: {:ok, conn},
      else:
        {:halt,
         error(
           conn,
           :forbidden,
           "scope_missing",
           "This key does not carry the #{scope} scope.",
           %{
             scope: scope
           }
         )}
  end

  @doc """
  A key reaches its own project and every sub-project nested under it.
  `project_uuid` is within reach when it is the key's project or one of
  its descendants (the parent chain walked up to the key's project).
  """
  @spec within_reach?(ApiKey.t(), String.t()) :: boolean()
  def within_reach?(%ApiKey{project_uuid: root}, root), do: true

  def within_reach?(%ApiKey{project_uuid: root}, project_uuid) when is_binary(project_uuid) do
    project_uuid |> Projects.parent_chain() |> Enum.any?(&(&1.uuid == root))
  rescue
    _ -> false
  end

  def within_reach?(_key, _), do: false

  @doc """
  Points the request at `params["project"]` when it names a sub-project
  within the key's reach (else 404 `not_found`); without the param the
  request stays on the key's own project. Project-level calls take it;
  task-level calls find their project through the task (`rescope/2`).
  """
  @spec scope_project(Plug.Conn.t(), map()) :: {:ok, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
  def scope_project(conn, params) do
    case Map.get(params, "project") do
      uuid when is_binary(uuid) and uuid != "" ->
        if uuid == conn.assigns.pk_project.uuid do
          {:ok, conn}
        else
          case within_reach?(conn.assigns.pk_api_key, uuid) && Projects.get_project(uuid) do
            %Project{} = project -> {:ok, rescope(conn, project)}
            _ -> {:halt, no_such_project(conn)}
          end
        end

      _ ->
        {:ok, conn}
    end
  end

  @doc "The request now acts on `project` (a sub-project within reach): its feature gates and role floors apply."
  @spec rescope(Plug.Conn.t(), Project.t()) :: Plug.Conn.t()
  def rescope(conn, %Project{} = project) do
    conn
    |> assign(:pk_project, project)
    |> assign(:pk_fx, Features.gates(project))
  end

  defp no_such_project(conn) do
    error(
      conn,
      :not_found,
      "not_found",
      "No such project within this key's reach: the key's own project or a sub-project nested under it."
    )
  end

  @doc "The key's role must meet `action`'s floor on this project, else 403 `forbidden`."
  @spec require_action(Plug.Conn.t(), atom()) :: {:ok, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
  def require_action(conn, action) do
    %{pk_api_key: key, pk_project: project} = conn.assigns

    if Authz.can_role?(project, key.role, action),
      do: {:ok, conn},
      else:
        {:halt,
         error(
           conn,
           :forbidden,
           "forbidden",
           "A #{key.role} key may not #{action} on this project.",
           %{
             action: action,
             role: key.role
           }
         )}
  end

  @doc "The project's `feature` (a gate of `Features.gates/1`) must be on, else 403 `feature_disabled`."
  @spec require_feature(Plug.Conn.t(), atom()) :: {:ok, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
  def require_feature(conn, feature) do
    if Map.get(conn.assigns.pk_fx, feature, false),
      do: {:ok, conn},
      else:
        {:halt,
         error(
           conn,
           :forbidden,
           "feature_disabled",
           "The #{feature} feature is turned off for this project.",
           %{feature: feature}
         )}
  end

  @doc """
  Runs `fun` (returning `{status, body}`) once per `Idempotency-Key`
  header; a replay answers the stored response. `required: true` refuses a
  POST without the header (422 `idempotency_key_required`).
  """
  @spec idempotent(Plug.Conn.t(), keyword(), (-> {integer(), map()})) :: Plug.Conn.t()
  def idempotent(conn, opts, fun) do
    key = conn.assigns.pk_api_key
    header = idempotency_key(conn)

    if is_nil(header) and Keyword.get(opts, :required, false) do
      error(
        conn,
        :unprocessable_entity,
        "idempotency_key_required",
        "Send an Idempotency-Key header (any unique string per attempt), so a retry cannot record this twice."
      )
    else
      case ApiKeys.idempotent(key, header, fun) do
        {:ok, status, body} ->
          conn |> put_status(status) |> json(body)

        {:replay, status, body} ->
          conn
          |> put_resp_header("idempotent-replayed", "true")
          |> put_status(status)
          |> json(body)
      end
    end
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [v] when byte_size(v) in 1..128 -> v
      _ -> nil
    end
  end

  @doc "The error envelope for a changeset, as a `{422, body}` pair for `idempotent/3`."
  @spec changeset_error(Ecto.Changeset.t()) :: {422, map()}
  def changeset_error(%Ecto.Changeset{} = cs) do
    details =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(v))
        end)
      end)

    {422,
     %{error: %{code: "validation_failed", message: "Some fields are invalid.", details: details}}}
  end

  @doc "A `{status, body}` error pair for `idempotent/3`."
  @spec error_body(integer(), String.t(), String.t(), map() | nil) :: {integer(), map()}
  def error_body(status, code, message, details \\ nil) do
    body = %{code: code, message: message}
    body = if details, do: Map.put(body, :details, details), else: body
    {status, %{error: body}}
  end

  @doc """
  The JSON shape of a task (an assignment with its task or sub-project
  preloaded). `totals` — minutes, tokens and cents logged on it — comes
  from `Ledger.totals_for_assignments/1`: pass the batch for a list, or
  nothing for one task.
  """
  @spec task(Assignment.t(), map() | nil) :: map()
  def task(%Assignment{} = a, totals \\ nil, labels \\ nil) do
    totals =
      (totals || Map.get(Ledger.totals_for_assignments([a.uuid]), a.uuid))
      |> whole_totals()

    labels = labels || Map.get(Labels.labels_for_assignments([a.uuid]), a.uuid, [])
    checklist = Assignment.checklist_counts(a)

    %{
      totals: totals,
      uuid: a.uuid,
      kind: if(a.child_project_uuid, do: "subproject", else: "task"),
      # a nested project's own answers — a caught-up ongoing child reads
      # as in_progress at 100% on its row, this says why
      subproject: subproject_state(a),
      title: Assignment.label(a),
      description: description(a),
      status: a.status,
      allowed_transitions: Map.get(@transitions, a.status, []),
      priority: a.priority,
      progress_pct: a.progress_pct,
      estimated_duration: a.estimated_duration,
      estimated_duration_unit: a.estimated_duration_unit,
      position: a.position,
      task_uuid: a.task_uuid,
      child_project_uuid: a.child_project_uuid,
      waiting_on: a.waiting_on,
      origin: a.origin,
      labels: Enum.map(labels, & &1.name),
      checklist: checklist,
      created_by: %{person: a.created_by_uuid, key: a.created_by_key_uuid},
      started_by: %{person: a.started_by_uuid, key: a.started_by_key_uuid},
      interactions: interaction_uuids(a),
      library_task: library_task?(a),
      completed_at: a.completed_at,
      inserted_at: a.inserted_at,
      updated_at: a.updated_at
    }
  end

  @doc """
  What `GET /tasks/:id` adds for the worker picking the task up: the
  direction now (the latest `redirect` a person wrote), the last agent
  note's outcome, the one line to read (`display_summary`: the person's
  description, else the direction, else the latest agent summary marked
  as such), and where the whole notes thread is.
  """
  @spec task_detail(Assignment.t()) :: map()
  def task_detail(%Assignment{} = a) do
    latest = TaskNotes.latest(a.uuid)
    display = TaskNotes.display_summary(description(a), latest)

    %{
      checklist_items: a.checklist || [],
      direction: latest.redirect && TaskNotes.to_json(latest.redirect),
      last_outcome: latest.agent && latest.agent.metadata["outcome"],
      latest_agent_note: latest.agent && TaskNotes.to_json(latest.agent),
      display_summary: display,
      notes_url: Docs.url("/tasks/#{a.uuid}/notes")
    }
  end

  defp description(%Assignment{description: d}) when is_binary(d) and d != "", do: d
  defp description(%Assignment{task: %Task{description: d}}), do: d
  defp description(_), do: nil

  defp library_task?(%Assignment{task: %Task{ad_hoc: ad_hoc}}), do: not ad_hoc
  defp library_task?(_), do: false

  @doc """
  A ledger entry as JSON: what it holds, who recorded it, the task it is on,
  the note it came with, and whether the figure was an estimate.
  """
  @spec entry(map()) :: map()
  def entry(e) do
    m = e.metadata || %{}

    %{
      uuid: e.uuid,
      kind: e.kind,
      amount: number(e.amount),
      task_uuid: e.assignment_uuid,
      actor: %{kind: e.actor_kind, uuid: e.actor_uuid},
      note: e.note,
      note_uuid: m["note_uuid"],
      model: m["model"],
      estimated: m["estimated"] == true,
      occurred_at: e.ended_at,
      recorded_at: e.inserted_at
    }
  end

  @doc "The interactions a task's description links with `#[crm_interaction:…]` tokens."
  @spec interaction_uuids(Assignment.t()) :: [String.t()]
  def interaction_uuids(%Assignment{} = a) do
    [description(a), a.description]
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&PhoenixKit.Mentions.Token.parse/1)
    |> Enum.filter(&(&1.type == "crm_interaction"))
    |> Enum.map(& &1.uuid)
    |> Enum.uniq()
  rescue
    _ -> []
  end

  @doc "A ledger amount as JSON: whole numbers stay integers (`12`, not `12.0`); a fraction stays a float."
  @spec number(Decimal.t() | number() | nil) :: number() | nil
  def number(nil), do: nil
  def number(%Decimal{} = d), do: d |> Decimal.to_float() |> number()
  def number(f) when is_float(f), do: if(f == Float.round(f), do: trunc(f), else: f)
  def number(n), do: n

  defp whole_totals(nil), do: nil
  defp whole_totals(totals), do: Map.new(totals, fn {k, v} -> {k, number(v)} end)

  @doc "The JSON shape of the key's project."
  @spec project(Project.t()) :: map()
  def project(%Project{} = p) do
    statuses =
      p
      |> Statuses.statuses_for()
      |> Enum.map(&%{slug: &1.slug, name: Map.get(&1, :name) || Map.get(&1, :title)})

    %{
      uuid: p.uuid,
      name: p.name,
      description: p.description,
      start_mode: p.start_mode,
      started_at: p.started_at,
      completed_at: p.completed_at,
      archived_at: p.archived_at,
      workflow_status: p.current_status_slug,
      available_workflow_statuses: statuses,
      completion: Project.completion(p),
      caught_up: Projects.caught_up?(p),
      agent_policy: Project.agent_policy(p),
      parent_uuid: parent_uuid(p),
      subprojects: Enum.map(Projects.child_projects(p.uuid), &subproject/1)
    }
  rescue
    _ -> %{uuid: p.uuid, name: p.name}
  end

  defp parent_uuid(%Project{uuid: uuid}) do
    case Projects.parent_chain(uuid) do
      [] -> nil
      chain -> List.last(chain).uuid
    end
  end

  # A nested project as its parent lists it: enough to pick one and pass
  # it as `project`; `GET /project?project=<uuid>` has the rest.
  defp subproject(%Project{} = p) do
    %{
      uuid: p.uuid,
      name: p.name,
      description: p.description,
      workflow_status: p.current_status_slug,
      completion: Project.completion(p),
      caught_up: Projects.caught_up?(p),
      completed_at: p.completed_at,
      archived_at: p.archived_at
    }
  end

  defp subproject_state(%Assignment{child_project_uuid: nil}), do: nil

  defp subproject_state(%Assignment{child_project_uuid: uuid}) do
    case Projects.get_project(uuid) do
      nil ->
        nil

      child ->
        %{
          completion: Project.completion(child),
          caught_up: Projects.caught_up?(child),
          completed_at: child.completed_at
        }
    end
  end

  @doc "Whether the key may change this task's words: it created the task, or the project allows it."
  @spec may_edit_text?(ApiKey.t(), Assignment.t(), map()) :: boolean()
  def may_edit_text?(%ApiKey{uuid: key_uuid}, %Assignment{} = a, project) do
    a.created_by_key_uuid == key_uuid or
      Project.agent_policy(project)["edit_foreign_text"] == true
  end

  @doc "Whether the key may delete this task under the project's `delete_tasks` policy."
  @spec may_delete?(ApiKey.t(), Assignment.t(), map()) :: boolean()
  def may_delete?(%ApiKey{uuid: key_uuid}, %Assignment{} = a, project) do
    case Project.agent_policy(project)["delete_tasks"] do
      "any" -> true
      "own" -> a.created_by_key_uuid == key_uuid
      _ -> false
    end
  end

  @doc "Whether the key may start a task someone else has started (a claim)."
  @spec may_take?(ApiKey.t(), Assignment.t(), map()) :: boolean()
  def may_take?(%ApiKey{uuid: key_uuid}, %Assignment{} = a, project) do
    (is_nil(a.started_by_uuid) and is_nil(a.started_by_key_uuid)) or
      a.started_by_key_uuid == key_uuid or
      Project.agent_policy(project)["take_started_task"] == true
  end
end
