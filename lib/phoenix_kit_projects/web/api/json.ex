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
    Extensions,
    Features,
    Labels,
    Ledger,
    Projects,
    Statuses,
    TaskNotes
  }

  alias PhoenixKitProjects.Outline.Api, as: OutlineApi
  alias PhoenixKitProjects.Schemas.{ApiKey, Assignment, Project, Task}
  alias PhoenixKitProjects.Web.Api.{Assignee, Docs}

  # `waiting` (the default) is idle; `todo` ("can be started") is released.
  @lifecycle ~w(waiting todo in_progress done)
  @transitions %{
    "waiting" => ~w(todo in_progress done),
    "todo" => ~w(waiting in_progress done),
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
    # Remembered: a request that moves to another project afterwards
    # (`rescope/2`) is checked again against THAT project's access.
    conn = assign(conn, :pk_required, Enum.uniq([scope | conn.assigns[:pk_required] || []]))

    cond do
      ApiKey.scope?(conn.assigns.pk_api_key, scope) ->
        {:ok, conn}

      reason = conn.assigns[:pk_home_refused] ->
        {:halt, home_refused(conn, reason)}

      true ->
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
  end

  # A request that stays at a home the key can no longer use (`Auth`).
  defp home_refused(conn, :membership_ended),
    do:
      error(
        conn,
        :forbidden,
        "membership_ended",
        "This key acts for a person who is no longer a member of its home project. Name another project with project=<key>, or change the home on the API keys page."
      )

  defp home_refused(conn, _no_access),
    do:
      error(
        conn,
        :forbidden,
        "no_access",
        "This key has no access to its home project. Name another project with project=<key>, or set its access on the API keys page (Projects → API keys)."
      )

  @doc """
  Whether the key reaches a project at all: the nearest grant up the
  project's tree gives it some access there (`ApiKeys.access_for/2`, V24).
  """
  @spec within_reach?(ApiKey.t(), String.t()) :: boolean()
  def within_reach?(%ApiKey{} = key, project_uuid) when is_binary(project_uuid),
    do: match?({:ok, _}, ApiKeys.access_for(key, project_uuid))

  def within_reach?(_key, _), do: false

  @doc """
  Points the request at `params["project"]` (a key or uuid) when the key
  reaches that project (else 404 `not_found`), re-resolving the key's
  rights for it and re-checking every scope already required; without the
  param the request stays on the key's home project. Project-level calls take it;
  task-level calls find their project through the task (`rescope/2`).
  """
  @spec scope_project(Plug.Conn.t(), map()) :: {:ok, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
  def scope_project(conn, params) do
    case Map.get(params, "project") do
      ref when is_binary(ref) and ref != "" ->
        # A uuid or a key (`ACME`): resolved first, then held to the key's
        # reach, so a key that names somebody else's project answers the
        # same 404 as one that names nothing.
        case Projects.get_project(ref) do
          %Project{uuid: uuid} when uuid == conn.assigns.pk_project.uuid ->
            {:ok, conn}

          %Project{uuid: uuid} = project ->
            if within_reach?(conn.assigns.pk_api_key, uuid),
              do: conn |> rescope(project) |> still_allowed(),
              else: {:halt, no_such_project(conn)}

          _ ->
            {:halt, no_such_project(conn)}
        end

      nil ->
        {:ok, conn}

      "" ->
        {:ok, conn}

      # Anything else (a number, a map) names no project: refused rather
      # than quietly acting at home.
      _ ->
        {:halt, no_such_project(conn)}
    end
  end

  @doc "The request now acts on `project`: the key's role and scopes become that project's grant's, and its feature gates apply."
  @spec rescope(Plug.Conn.t(), Project.t()) :: Plug.Conn.t()
  def rescope(conn, %Project{} = project) do
    key = conn.assigns.pk_api_key

    # The key as it acts HERE (V24): its role and scopes are this
    # project's grant's, never the home project's.
    view =
      case ApiKeys.view(key, project) do
        {:ok, view} -> view
        _ -> %{key | role: nil, scopes: []}
      end

    conn
    |> assign(:pk_api_key, view)
    |> assign(:pk_home_refused, nil)
    |> assign(:pk_project, project)
    |> assign(:pk_fx, Features.gates(project))
  end

  @doc """
  After a move to another project (`rescope/2`): every scope the request
  already required must hold there too, else 403 `scope_missing`.
  """
  @spec still_allowed(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
  def still_allowed(conn) do
    key = conn.assigns.pk_api_key

    case Enum.reject(conn.assigns[:pk_required] || [], &ApiKey.scope?(key, &1)) do
      [] ->
        put_view(key)
        {:ok, conn}

      [scope | _] ->
        {:halt,
         error(
           conn,
           :forbidden,
           "scope_missing",
           "This key does not carry the #{scope} scope in project #{conn.assigns.pk_project.key || conn.assigns.pk_project.uuid}.",
           %{scope: scope, project: conn.assigns.pk_project.key}
         )}
    end
  end

  defp no_such_project(conn) do
    error(
      conn,
      :not_found,
      "not_found",
      "No such project within this key's reach. GET /me lists every project the key reaches."
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
      # The same header on another project is another request (V24: one
      # key, many projects) — never a replay of the first one's answer.
      case ApiKeys.idempotent(key, scoped_header(header, conn), fun) do
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

  defp scoped_header(nil, _conn), do: nil

  defp scoped_header(header, conn) do
    case conn.assigns[:pk_project] do
      %{uuid: uuid} -> idempotency_scope(header, uuid)
      _ -> header
    end
  end

  @doc """
  What an `Idempotency-Key` header is stored under for a project: the same
  header on another project is another request (V24).
  """
  @spec idempotency_scope(String.t(), String.t()) :: String.t()
  def idempotency_scope(header, project_uuid),
    do: :crypto.hash(:sha256, project_uuid <> ":" <> header) |> Base.encode16(case: :lower)

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [v] when byte_size(v) in 1..128 -> v
      _ -> nil
    end
  end

  @doc """
  The key as the request acts with it, for the serializers below: set by
  `Auth` and again whenever the request settles in another project
  (`still_allowed/1`). A field from an area the key cannot read there is
  left empty (`may?/1`) — a task read with `tasks:read` alone carries no
  time, usage, notes or interactions. Side lookups that only `rescope/2`
  (a link checked on a parent) do not move it.
  """
  @spec put_view(ApiKey.t()) :: :ok
  def put_view(%ApiKey{} = key) do
    Process.put(:pk_api_view, key)
    :ok
  end

  @doc "Whether the request's key may read or write `scope` where it acts (true outside the API)."
  @spec may?(String.t()) :: boolean()
  def may?(scope) do
    case Process.get(:pk_api_view) do
      %ApiKey{} = key -> ApiKey.scope?(key, scope)
      _ -> true
    end
  end

  @doc """
  Whether the request's key may read client interactions where it acts:
  the provider's read scope. With no provider there is no scope to hold,
  so nothing about interactions is shown.
  """
  @spec may_read_interactions?() :: boolean()
  def may_read_interactions? do
    case Extensions.api_provider("interactions") do
      %{module: provider} -> may?(provider.scopes().read)
      _ -> false
    end
  end

  @doc "A note as JSON (`TaskNotes.to_json/1`); its `usage` only with `usage:read`."
  @spec note(map()) :: map()
  def note(n) do
    json = TaskNotes.to_json(n)
    if may?("usage:read"), do: json, else: %{json | usage: nil}
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
  nothing for one task. `outline` is the project's shape
  (`Outline.Api.info/1`), read once for a list; one task reads its own.
  """
  @spec task(Assignment.t(), map() | nil, [map()] | nil, [String.t()] | nil, map() | nil) ::
          map()
  def task(%Assignment{} = a, totals \\ nil, labels \\ nil, interactions \\ nil, outline \\ nil) do
    totals =
      (totals || Map.get(Ledger.totals_for_assignments([a.uuid]), a.uuid))
      |> whole_totals()
      |> visible_totals()

    labels = labels || Map.get(Labels.labels_for_assignments([a.uuid]), a.uuid, [])
    place = OutlineApi.place(outline || OutlineApi.info(a.project_uuid), a)

    %{
      totals: totals,
      uuid: a.uuid,
      # the short name: `ACME-42` for a task; for a sub-project row the
      # CHILD's key (work goes to the child — `parent_ref` is the row's
      # own place in this list). Accepted wherever a task uuid is.
      ref: Assignment.ref(a),
      number: a.number,
      parent_ref: if(a.child_project_uuid, do: Assignment.row_ref(a)),
      # the task this one sits under (`ACME-40`), null at the top level;
      # how deep it sits; and, for a task with tasks under it, how many of
      # the ones at the bottom of its branch are done
      parent_task: place.parent_task,
      depth: place.depth,
      subtasks: place.subtasks,
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
      start_date: a.start_date,
      end_date: a.end_date,
      start_time: a.start_time,
      end_time: a.end_time,
      deadline: a.deadline,
      overdue: Assignment.overdue?(a),
      labels: Enum.map(labels, & &1.name),
      # who it is FOR (a person, a team or a department), apart from who
      # made it and who started it
      assignee: Assignee.to_json(a),
      created_by: %{person: a.created_by_uuid, key: a.created_by_key_uuid},
      started_by: %{person: a.started_by_uuid, key: a.started_by_key_uuid},
      words_by: if(a.words_by_key_uuid, do: %{key: a.words_by_key_uuid}, else: %{person: true}),
      interactions:
        if(may_read_interactions?(), do: interactions || interaction_uuids(a), else: []),
      library_task: library_task?(a),
      started_at: a.started_at,
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
  as such), where the whole notes thread is, and the tasks directly under
  it (`subtask_refs`, in order).
  """
  @spec task_detail(Assignment.t()) :: map()
  def task_detail(%Assignment{} = a) do
    latest =
      if may?("notes:read"), do: TaskNotes.latest(a.uuid), else: %{redirect: nil, agent: nil}

    display = TaskNotes.display_summary(description(a), latest)

    %{
      subtask_refs: OutlineApi.subtask_refs(OutlineApi.info(a.project_uuid), a.uuid),
      direction: latest.redirect && note(latest.redirect),
      last_outcome: latest.agent && latest.agent.metadata["outcome"],
      latest_agent_note: latest.agent && note(latest.agent),
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
      billable: e.billable == true,
      note: e.note,
      note_uuid: m["note_uuid"],
      model: m["model"],
      estimated: m["estimated"] == true,
      occurred_at: e.ended_at,
      recorded_at: e.inserted_at
    }
  end

  @doc "The interactions a task is linked to (the join table, V20), oldest link first."
  @spec interaction_uuids(Assignment.t()) :: [String.t()]
  def interaction_uuids(%Assignment{} = a), do: Projects.interactions_of(a)

  @doc "A ledger amount as JSON: whole numbers stay integers (`12`, not `12.0`); a fraction stays a float."
  @spec number(Decimal.t() | number() | nil) :: number() | nil
  def number(nil), do: nil
  def number(%Decimal{} = d), do: d |> Decimal.to_float() |> number()
  def number(f) when is_float(f), do: if(f == Float.round(f), do: trunc(f), else: f)
  def number(n), do: n

  # Minutes are the time area's, tokens and cost the usage area's.
  defp visible_totals(nil), do: nil

  defp visible_totals(totals) do
    hidden =
      if(may?("time:read"), do: [], else: [:minutes]) ++
        if may?("usage:read"), do: [], else: [:tokens, :cost_cents]

    drop_totals(totals, hidden)
  end

  defp drop_totals(totals, []), do: totals

  defp drop_totals(%{} = totals, hidden) do
    totals
    |> Map.drop(hidden)
    |> Map.new(fn
      {k, %{} = own} -> {k, drop_totals(own, hidden)}
      pair -> pair
    end)
  end

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
      key: p.key,
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
      caught_up_since: Projects.caught_up_since(p),
      agent_policy: Project.agent_policy(p),
      parent_uuid: parent_uuid(p),
      subprojects:
        p.uuid
        |> Projects.child_projects()
        |> Enum.filter(&reachable?/1)
        |> Enum.map(&subproject/1)
    }
  rescue
    _ -> %{uuid: p.uuid, key: p.key, name: p.name}
  end

  defp parent_uuid(%Project{uuid: uuid}) do
    case Projects.parent_chain(uuid) do
      [] -> nil
      chain -> List.last(chain).uuid
    end
  end

  @doc """
  Whether a row of a task list may be shown to the request's key: every
  task, and a sub-project's row only when the key reaches that sub-project
  (a grant can stop there — its name and progress are then not shown).
  """
  @spec visible_row?(Assignment.t()) :: boolean()
  def visible_row?(%Assignment{child_project_uuid: nil}), do: true

  def visible_row?(%Assignment{child_project_uuid: uuid}) do
    case Process.get(:pk_api_view) do
      %ApiKey{} = key -> within_reach?(key, uuid)
      _ -> true
    end
  end

  # A child the request's key reaches (a grant can stop at its project).
  defp reachable?(%Project{uuid: uuid}) do
    case Process.get(:pk_api_view) do
      %ApiKey{} = key -> within_reach?(key, uuid)
      _ -> true
    end
  end

  # A nested project as its parent lists it: enough to pick one and pass
  # it as `project`; `GET /project?project=<uuid>` has the rest.
  defp subproject(%Project{} = p) do
    %{
      uuid: p.uuid,
      key: p.key,
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
          caught_up_since: Projects.caught_up_since(child),
          completed_at: child.completed_at
        }
    end
  end

  @doc "Whether the key may change this task's words: they are its own (it wrote them last), or the project allows it."
  def may_edit_text?(%ApiKey{uuid: key_uuid}, %Assignment{} = a, project) do
    a.words_by_key_uuid == key_uuid or
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
