defmodule PhoenixKitProjects.Web.Api.TasksController do
  @moduledoc """
  The tasks of the key's project: list, read, create, edit content, and move
  through the lifecycle (`todo` → `in_progress` → `done` → `todo`).

  Every write goes through the same context functions the admin pages use
  (`Projects.create_task_with_assignment/3`, `update_assignment_form/3`,
  `update_assignment_status/2`, `complete_assignment/2`, `reopen_assignment/1`)
  and logs the same activity actions, with the key named in the metadata;
  the activity's actor is the person who minted the key. After a lifecycle
  move the project's own completion is recomputed, as the project page does.

  Content edits to a task that is a LIBRARY task (shared across projects)
  are refused: an agent renaming a shared task would rename it everywhere.
  """

  use Phoenix.Controller, formats: [:json]

  alias PhoenixKit.Mentions
  alias PhoenixKitProjects.{Activity, Features, Labels, Ledger, Projects}
  alias PhoenixKitProjects.Schemas.{ApiKey, Assignment, Project}
  alias PhoenixKitProjects.Web.Api.Json

  @priorities ~w(urgent high normal low)
  @units ~w(minutes hours days weeks fortnights months years)

  @status_filters ~w(todo in_progress done open)

  def index(conn, params) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:read"),
         {:ok, conn} <- Json.scope_project(conn, params),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :view),
         {:ok, conn} <- known_status(conn, params["status"]) do
      tasks =
        conn.assigns.pk_project.uuid
        |> Projects.list_assignments()
        |> filter_status(params["status"])
        |> filter_since(params["updated_since"])

      uuids = Enum.map(tasks, & &1.uuid)
      totals = Ledger.totals_for_assignments(uuids)
      labels = Labels.labels_for_assignments(uuids)

      json(conn, %{
        tasks: Enum.map(tasks, &Json.task(&1, totals[&1.uuid], labels[&1.uuid] || [])),
        count: length(tasks),
        now: DateTime.utc_now()
      })
    else
      {:halt, conn} -> conn
    end
  end

  # `updated_since`: only the rows touched after that moment (strictly),
  # for a poll that remembers the `now` of its last answer. An unreadable
  # value is ignored rather than refused — a poll must not stall on it.
  defp filter_since(tasks, since) when is_binary(since) do
    case DateTime.from_iso8601(since) do
      {:ok, dt, _} -> Enum.filter(tasks, &(DateTime.compare(&1.updated_at, dt) == :gt))
      _ -> tasks
    end
  end

  defp filter_since(tasks, _), do: tasks

  # A filter nobody recognises used to answer the whole list, which an
  # agent read as "no tasks match" or "every task matches" at random.
  defp known_status(conn, status) when is_nil(status) or status in @status_filters,
    do: {:ok, conn}

  defp known_status(conn, status) do
    {:halt,
     Json.error(conn, :unprocessable_entity, "validation_failed", "Unknown status filter.", %{
       status: status,
       allowed: @status_filters
     })}
  end

  defp filter_status(tasks, status) when status in ["todo", "in_progress", "done"],
    do: Enum.filter(tasks, &(&1.status == status))

  defp filter_status(tasks, "open"), do: Enum.reject(tasks, &(&1.status == "done"))
  defp filter_status(tasks, _), do: tasks

  def show(conn, %{"id" => id}) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:read"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :view),
         {:ok, conn, a} <- fetch(conn, id) do
      json(conn, %{task: Map.merge(Json.task(a), Json.task_detail(a))})
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> not_found(conn)
    end
  end

  def create(conn, params) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
         {:ok, conn} <- Json.scope_project(conn, params),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :create_tasks) do
      Json.idempotent(conn, [], fn -> do_create(conn, params) end)
    else
      {:halt, conn} -> conn
    end
  end

  defp do_create(conn, params) do
    %{pk_api_key: key, pk_project: project} = conn.assigns
    params = Map.merge(params, position_attrs(project, params["position"]))

    with {:ok, title} <- required_string(params, "title"),
         {:ok, assignment_attrs} <- assignment_attrs(params) do
      task_attrs =
        %{"title" => title, "ad_hoc" => true}
        |> maybe_put("description", params["description"])

      case Projects.create_task_with_assignment(project.uuid, task_attrs, assignment_attrs) do
        {:ok, %{assignment: a}} ->
          Activity.log("projects.assignment_created",
            actor_uuid: ApiKey.accountable_uuid(key),
            resource_type: "assignment",
            resource_uuid: a.uuid,
            metadata: api_metadata(key, %{"task" => title})
          )

          sync_mentions(a.uuid, task_attrs["description"], key)

          {:ok, _} =
            Projects.stamp_assignment(a, %{
              created_by_uuid: ApiKey.accountable_uuid(key),
              created_by_key_uuid: key.uuid
            })

          apply_labels(project, a, params["labels"])

          {201, %{task: Json.task(Projects.get_assignment(a.uuid))}}

        {:error, _step, %Ecto.Changeset{} = cs} ->
          Json.changeset_error(cs)

        {:error, :project, :not_found} ->
          Json.error_body(404, "not_found", "The key's project is gone.")
      end
    else
      {:error, {422, _} = pair} -> pair
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :edit_tasks),
         {:ok, conn, a} <- fetch(conn, id) do
      Json.idempotent(conn, [], fn -> do_update(conn, a, params) end)
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp do_update(conn, %Assignment{} = a, params) do
    %{pk_api_key: key, pk_project: project} = conn.assigns
    content = Map.take(params, ["title", "description"])

    with :ok <- content_editable(a, content),
         :ok <- text_policy(key, a, project, content),
         {:ok, assignment_attrs} <- assignment_attrs(params),
         {:ok, _} <- update_content(a, content),
         {:ok, _} <- update_fields(a, assignment_attrs),
         :ok <- apply_labels(project, a, params["labels"]) do
      Activity.log("projects.assignment_updated",
        actor_uuid: ApiKey.accountable_uuid(key),
        resource_type: "assignment",
        resource_uuid: a.uuid,
        metadata: api_metadata(key, %{"fields" => Map.keys(Map.merge(content, assignment_attrs))})
      )

      if Map.has_key?(content, "description"),
        do: sync_mentions(a.uuid, content["description"], key)

      {200, %{task: Json.task(Projects.get_assignment(a.uuid))}}
    else
      {:error, {status, _} = pair} when is_integer(status) -> pair
      {:error, %Ecto.Changeset{} = cs} -> Json.changeset_error(cs)
    end
  end

  # Indexes the `#` links in a saved description, so a task that says
  # "from this meeting" is listed on the meeting (core keeps the reverse
  # index). Never fails the save: a mention that does not index is a
  # missing backlink, not lost work.
  defp sync_mentions(assignment_uuid, description, key) when is_binary(description) do
    Mentions.sync("project_task", assignment_uuid, description,
      field: "description",
      actor_uuid: ApiKey.accountable_uuid(key)
    )
  rescue
    _ -> :ok
  end

  defp sync_mentions(_uuid, _description, _key), do: :ok

  # The project's `edit_foreign_text` policy: a task's words belong to
  # whoever wrote them; an agent rewords only what it created unless the
  # project says otherwise.
  defp text_policy(_key, _a, _project, content) when map_size(content) == 0, do: :ok

  defp text_policy(key, a, project, _content) do
    if Json.may_edit_text?(key, a, project),
      do: :ok,
      else:
        {:error,
         Json.error_body(
           403,
           "foreign_text",
           "This task's title and description were written by someone else; the project does not let an agent reword them.",
           %{policy: "edit_foreign_text"}
         )}
  end

  # Labels by name, when the project has labels on; a nil means "leave them".
  defp apply_labels(_project, _a, nil), do: :ok

  defp apply_labels(project, a, names) when is_list(names) do
    if Features.on?(project, "labels") do
      Labels.set_assignment_labels(a, Labels.ensure_by_names(project, names))
    end

    :ok
  end

  defp apply_labels(_project, _a, _), do: :ok

  # `position: "top"` puts the new task above every other row; anything
  # else (or nothing) appends, as a form does.
  defp position_attrs(project, "top"),
    do: %{"position" => Projects.top_assignment_position(project.uuid)}

  defp position_attrs(_project, _), do: %{}

  defp content_editable(_a, content) when map_size(content) == 0, do: :ok

  defp content_editable(%Assignment{task: %{ad_hoc: true}}, _content), do: :ok

  defp content_editable(_a, _content),
    do:
      {:error,
       Json.error_body(
         409,
         "library_task",
         "This task comes from the shared library; its title and description are edited there, not per project."
       )}

  defp update_content(_a, content) when map_size(content) == 0, do: {:ok, nil}
  defp update_content(%Assignment{task: task}, content), do: Projects.update_task(task, content)

  defp update_fields(_a, attrs) when map_size(attrs) == 0, do: {:ok, nil}
  defp update_fields(a, attrs), do: Projects.update_assignment_form(a, attrs)

  def transition(conn, %{"id" => id} = params) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :update_status),
         {:ok, conn, a} <- fetch(conn, id) do
      Json.idempotent(conn, [], fn -> do_transition(conn, a, params["status"]) end)
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> not_found(conn)
    end
  end

  def start(conn, params), do: transition(conn, Map.put(params, "status", "in_progress"))

  def delete(conn, %{"id" => id}) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :delete_tasks),
         {:ok, conn, a} <- fetch(conn, id) do
      %{pk_api_key: key, pk_project: project} = conn.assigns

      cond do
        not is_nil(a.child_project_uuid) ->
          Json.error(conn, :conflict, "subproject", "A sub-project is not deleted here.")

        not Json.may_delete?(key, a, project) ->
          Json.error(
            conn,
            :forbidden,
            "delete_not_allowed",
            "The project does not let an agent delete this task (policy delete_tasks: #{Project.agent_policy(project)["delete_tasks"]}).",
            %{policy: "delete_tasks"}
          )

        true ->
          case Projects.delete_assignment(a) do
            {:ok, _} ->
              Activity.log("projects.assignment_removed",
                actor_uuid: ApiKey.accountable_uuid(key),
                resource_type: "assignment",
                resource_uuid: a.uuid,
                metadata: api_metadata(key, %{"task" => Assignment.label(a)})
              )

              sync_project_completion(conn)
              json(conn, %{deleted: a.uuid})

            {:error, _} ->
              Json.error(conn, :conflict, "conflict", "The task could not be deleted.")
          end
      end
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> not_found(conn)
    end
  end

  # One checklist item, ticked or unticked, without rewriting the list:
  # two sessions may tick different items at once.
  def checklist_item(conn, %{"id" => id, "item" => item_id} = params) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :edit_tasks),
         {:ok, conn, a} <- fetch(conn, id) do
      Json.idempotent(conn, [], fn -> do_checklist_item(conn, a, item_id, params) end)
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp do_checklist_item(conn, a, item_id, params) do
    key = conn.assigns.pk_api_key
    items = a.checklist || []

    if Enum.any?(items, &(&1["id"] == item_id)) do
      done = params["done"] in [true, "true"]

      updated =
        Enum.map(items, fn
          %{"id" => ^item_id} = item -> item |> Map.put("done", done) |> Map.delete("done_at")
          item -> item
        end)

      case Projects.update_assignment_form(a, %{checklist: updated}) do
        {:ok, saved} ->
          Activity.log("projects.assignment_updated",
            actor_uuid: ApiKey.accountable_uuid(key),
            resource_type: "assignment",
            resource_uuid: a.uuid,
            metadata: api_metadata(key, %{"fields" => ["checklist"]})
          )

          {200, %{task: Json.task(Projects.get_assignment(saved.uuid) || saved)}}

        {:error, %Ecto.Changeset{} = cs} ->
          Json.changeset_error(cs)
      end
    else
      Json.error_body(404, "not_found", "No such checklist item on this task.")
    end
  end

  def complete(conn, params), do: transition(conn, Map.put(params, "status", "done"))
  def reopen(conn, params), do: transition(conn, Map.put(params, "status", "todo"))

  defp do_transition(conn, %Assignment{} = a, to) do
    %{pk_api_key: key, pk_project: project} = conn.assigns
    allowed = Map.get(Json.transitions(), a.status, [])

    cond do
      to == "in_progress" and not Json.may_take?(key, a, project) ->
        Json.error_body(
          409,
          "already_started",
          "Someone else started this task; the project does not let an agent take it over (policy take_started_task).",
          %{
            started_by: %{person: a.started_by_uuid, key: a.started_by_key_uuid},
            policy: "take_started_task"
          }
        )

      to not in Json.lifecycle() ->
        Json.error_body(
          422,
          "validation_failed",
          "status must be one of todo, in_progress, done.",
          %{
            status: Json.lifecycle()
          }
        )

      to not in allowed ->
        Json.error_body(
          409,
          "invalid_transition",
          "The task is #{a.status}; from there it can only go to #{Enum.join(allowed, " or ")}.",
          %{from: a.status, allowed_transitions: allowed}
        )

      true ->
        {action, result} = apply_transition(a, to, key)

        case result do
          {:ok, _} ->
            Activity.log(action,
              actor_uuid: ApiKey.accountable_uuid(key),
              resource_type: "assignment",
              resource_uuid: a.uuid,
              target_uuid: Activity.assignee_target_uuid(a),
              metadata: api_metadata(key, %{"task" => Assignment.label(a)})
            )

            sync_project_completion(conn)
            {200, %{task: Json.task(Projects.get_assignment(a.uuid))}}

          {:error, %Ecto.Changeset{} = cs} ->
            Json.changeset_error(cs)
        end
    end
  end

  # The same moves the project page makes, with the same side effects: a
  # start keeps the progress unless the task had been finished, a completion
  # stamps who and when (the key's minter), a reopen clears both.
  defp apply_transition(a, "in_progress", key) do
    pct = if a.progress_pct == 100, do: 0, else: a.progress_pct

    {"projects.assignment_started",
     Projects.update_assignment_status(a, %{
       status: "in_progress",
       progress_pct: pct,
       started_by_uuid: ApiKey.accountable_uuid(key),
       started_by_key_uuid: key.uuid
     })}
  end

  defp apply_transition(a, "done", key),
    do:
      {"projects.assignment_completed",
       Projects.complete_assignment(a, ApiKey.accountable_uuid(key))}

  defp apply_transition(a, "todo", _key),
    do: {"projects.assignment_reopened", Projects.reopen_assignment(a)}

  defp sync_project_completion(conn) do
    %{pk_api_key: key, pk_project: project} = conn.assigns

    case Projects.recompute_project_completion(project.uuid) do
      {:completed, p} ->
        Activity.log("projects.project_completed",
          actor_uuid: ApiKey.accountable_uuid(key),
          resource_type: "project",
          resource_uuid: p.uuid,
          metadata: api_metadata(key, %{"name" => p.name})
        )

      {:reopened, p} ->
        Activity.log("projects.project_reopened",
          actor_uuid: ApiKey.accountable_uuid(key),
          resource_type: "project",
          resource_uuid: p.uuid,
          metadata: api_metadata(key, %{"name" => p.name})
        )

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # ── Shared ──────────────────────────────────────────────────────

  @doc """
  The task `id` names, when its project is within the key's reach — the
  key's own project or a sub-project under it — with the request pointed
  at that project (`Json.rescope/2`), whose `tasks` gate must be on.
  """
  @spec fetch(Plug.Conn.t(), String.t()) ::
          {:ok, Plug.Conn.t(), Assignment.t()} | {:halt, Plug.Conn.t()} | {:error, :not_found}
  def fetch(conn, id) do
    %{pk_api_key: key, pk_project: project} = conn.assigns

    case Projects.get_assignment(id) do
      %Assignment{project_uuid: pid} = a when pid == project.uuid ->
        {:ok, conn, a}

      %Assignment{project_uuid: pid} = a ->
        with true <- Json.within_reach?(key, pid),
             %{} = child <- Projects.get_project(pid),
             conn = Json.rescope(conn, child),
             {:ok, conn} <- Json.require_feature(conn, :tasks) do
          {:ok, conn, a}
        else
          {:halt, conn} -> {:halt, conn}
          _ -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  @doc false
  def not_found(conn),
    do:
      Json.error(
        conn,
        :not_found,
        "not_found",
        "No such task in this project or the sub-projects under it."
      )

  @doc false
  def api_metadata(key, extra),
    do: Map.merge(%{"via" => "api", "api_key" => key.uuid, "api_key_name" => key.name}, extra)

  defp required_string(params, field) do
    case params[field] do
      v when is_binary(v) ->
        if String.trim(v) == "",
          do:
            {:error,
             Json.error_body(422, "validation_failed", "#{field} can't be blank.", %{
               field => ["can't be blank"]
             })},
          else: {:ok, String.trim(v)}

      _ ->
        {:error,
         Json.error_body(422, "validation_failed", "#{field} is required.", %{
           field => ["is required"]
         })}
    end
  end

  # The assignment-level fields an agent may set, validated to the same
  # closed sets the schema enforces, so a bad value is a 422 with the list
  # rather than a changeset error worded for a form.
  defp assignment_attrs(params) do
    attrs =
      %{}
      |> maybe_put("priority", params["priority"])
      |> maybe_put("progress_pct", params["progress_pct"])
      |> maybe_put("estimated_duration", params["estimated_duration"])
      |> maybe_put("estimated_duration_unit", params["estimated_duration_unit"])
      |> maybe_put_text("waiting_on", params)
      |> maybe_put_text("origin", params)
      |> maybe_put_list("checklist", params["checklist"])
      |> maybe_put("position", params["position"] |> then(&if(is_integer(&1), do: &1)))

    cond do
      Map.has_key?(attrs, "priority") and attrs["priority"] not in @priorities ->
        {:error,
         Json.error_body(
           422,
           "validation_failed",
           "priority must be one of #{Enum.join(@priorities, ", ")}.",
           %{
             priority: @priorities
           }
         )}

      Map.has_key?(attrs, "estimated_duration_unit") and
          attrs["estimated_duration_unit"] not in @units ->
        {:error,
         Json.error_body(
           422,
           "validation_failed",
           "estimated_duration_unit must be one of #{Enum.join(@units, ", ")}.",
           %{
             estimated_duration_unit: @units
           }
         )}

      Map.has_key?(attrs, "progress_pct") and not integer_in?(attrs["progress_pct"], 0, 100) ->
        {:error,
         Json.error_body(
           422,
           "validation_failed",
           "progress_pct must be an integer from 0 to 100.",
           %{
             progress_pct: ["must be an integer from 0 to 100"]
           }
         )}

      Map.has_key?(attrs, "estimated_duration") and
          not integer_in?(attrs["estimated_duration"], 1, nil) ->
        {:error,
         Json.error_body(
           422,
           "validation_failed",
           "estimated_duration must be a positive integer.",
           %{
             estimated_duration: ["must be a positive integer"]
           }
         )}

      true ->
        {:ok, attrs}
    end
  end

  defp integer_in?(v, min, max) when is_integer(v),
    do: v >= min and (is_nil(max) or v <= max)

  defp integer_in?(_, _, _), do: false

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  # A text field an agent may clear: present and blank or null → nil.
  defp maybe_put_text(map, k, params) do
    case Map.fetch(params, k) do
      {:ok, v} when is_binary(v) -> Map.put(map, k, if(String.trim(v) == "", do: nil, else: v))
      {:ok, nil} -> Map.put(map, k, nil)
      _ -> map
    end
  end

  defp maybe_put_list(map, k, v) when is_list(v), do: Map.put(map, k, v)
  defp maybe_put_list(map, _k, _v), do: map
end
