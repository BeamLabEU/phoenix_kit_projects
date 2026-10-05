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

  require Logger

  alias PhoenixKit.Mentions
  alias PhoenixKitProjects.{Activity, Authz, Extensions, Features, Labels, Ledger, Projects}
  alias PhoenixKitProjects.Schemas.{ApiKey, Assignment, Project}
  alias PhoenixKitProjects.Schemas.Task, as: TaskSchema
  alias PhoenixKitProjects.Web.Api.ExtController
  alias PhoenixKitProjects.Web.Api.Json

  @priorities ~w(urgent high normal low)
  # The INTEGER columns (`estimated_duration`, `position`) hold int4; a
  # bound well inside it keeps a wild figure a 422 instead of an encode error.
  @max_int 1_000_000_000
  # About eleven years of one task, in minutes.
  @max_task_minutes 6_000_000
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
      links = Projects.interactions_for_assignments(uuids)

      json(conn, %{
        tasks:
          Enum.map(
            tasks,
            &Json.task(&1, totals[&1.uuid], labels[&1.uuid] || [], links[&1.uuid] || [])
          ),
        count: length(tasks),
        # whole seconds, like `updated_at`: a `now` with microseconds skipped
        # a change made in the same second
        now: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    else
      {:halt, conn} -> conn
    end
  end

  # `updated_since`: the rows touched at or after that moment — inclusive,
  # so a change in the same second as the last answer's `now` is not lost;
  # the caller dedupes by uuid. An unreadable value is ignored rather than
  # refused — a poll must not stall on it.
  defp filter_since(tasks, since) when is_binary(since) do
    case DateTime.from_iso8601(since) do
      {:ok, dt, _} -> Enum.filter(tasks, &(DateTime.compare(&1.updated_at, dt) != :lt))
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
         {:ok, conn, a} <- fetch(conn, id),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :view) do
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

    with :ok <- check_interaction(conn, params["interaction"]),
         :ok <- check_labels(params["labels"]),
         :ok <- check_checklist(params["checklist"]) do
      do_create_checked(conn, key, project, params)
    else
      {:error, pair} -> pair
    end
  end

  defp do_create_checked(conn, key, project, params) do
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

          # provenance and links after the row exists; the interaction was
          # checked before, so a failure here is a store problem, logged
          _ =
            Projects.stamp_assignment(a, %{
              created_by_uuid: ApiKey.accountable_uuid(key),
              created_by_key_uuid: key.uuid,
              words_by_key_uuid: key.uuid
            })

          apply_labels(project, a, params["labels"])

          case link_interaction(conn, a, params["interaction"]) do
            :ok ->
              :ok

            {:error, {_status, body}} ->
              Logger.warning("[Projects.Api] link after create failed: #{inspect(body)}")
          end

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
         {:ok, conn, a} <- fetch(conn, id),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :edit_tasks) do
      Json.idempotent(conn, [], fn -> do_update(conn, a, params) end)
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp do_update(conn, %Assignment{} = a, params) do
    %{pk_api_key: key, pk_project: project} = conn.assigns
    content = Map.take(params, ["title", "description"])

    with :ok <- not_subproject_row(a),
         :ok <- content_editable(a, content),
         :ok <- text_policy(key, a, project, content),
         {:ok, assignment_attrs} <- assignment_attrs(params),
         :ok <- check_interaction(conn, params["interaction"]),
         :ok <- check_labels(params["labels"]),
         :ok <- check_checklist(params["checklist"]),
         :ok <- precheck(a, content, assignment_attrs),
         {:ok, _} <- update_content(a, content),
         {:ok, _} <- update_fields(a, assignment_attrs),
         :ok <- stamp_words(a, key, content),
         :ok <- keep_interaction_tokens(conn, a),
         :ok <- apply_labels(project, a, params["labels"]),
         :ok <- link_interaction(conn, a, params["interaction"]) do
      changed =
        Map.keys(Map.merge(content, assignment_attrs)) ++
          Enum.filter(["labels", "interaction"], &Map.has_key?(params, &1))

      Activity.log("projects.assignment_updated",
        actor_uuid: ApiKey.accountable_uuid(key),
        resource_type: "assignment",
        resource_uuid: a.uuid,
        metadata: api_metadata(key, %{"fields" => changed})
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

  # A key that rewrote the title or description now owns the words (a
  # person's later edit in the form clears this again).
  defp stamp_words(_a, _key, content) when map_size(content) == 0, do: :ok

  defp stamp_words(a, key, _content) do
    case Projects.stamp_assignment(a, %{words_by_key_uuid: key.uuid}) do
      {:ok, _} -> :ok
      _ -> :ok
    end
  end

  # The project's `edit_foreign_text` policy: a task's words belong to
  # whoever wrote them LAST — a person's rewording sticks even on a task the
  # agent created; the agent rewords only words that are its own, unless
  # the project says otherwise.
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

  # `interaction: <uuid>` links the task to a client interaction: a row in
  # the join table (V20) plus the mention token in the description, so the
  # forms and the backlink index agree. The uuid must be an interaction of
  # this project (the CRM provider answers for it); its subject labels the
  # token.
  defp link_interaction(_conn, _a, nil), do: :ok

  defp link_interaction(conn, a, uuid) when is_binary(uuid) do
    key = conn.assigns.pk_api_key

    case interaction_label(conn, uuid) do
      {:ok, label} ->
        case Projects.link_interaction(a, uuid, label,
               actor_uuid: ApiKey.accountable_uuid(key),
               key_uuid: key.uuid
             ) do
          {:ok, _} ->
            :ok

          {:error, _} ->
            {:error,
             Json.error_body(422, "validation_failed", "The interaction could not be linked.")}
        end

      :error ->
        {:error,
         Json.error_body(404, "not_found", "No such interaction on this project.", %{
           interaction: uuid
         })}
    end
  end

  defp link_interaction(_conn, _a, _),
    do: {:error, Json.error_body(422, "validation_failed", "interaction must be a uuid.")}

  # After the API rewrote a description, every linked interaction's token
  # is put back if the rewrite dropped it — the join is the truth.
  defp keep_interaction_tokens(conn, a) do
    key = conn.assigns.pk_api_key

    labels =
      Map.new(Projects.interactions_of(a), fn uuid -> {uuid, label_or_default(conn, uuid)} end)

    if labels == %{} do
      :ok
    else
      case Projects.get_assignment(a.uuid) do
        nil ->
          :ok

        fresh ->
          Projects.ensure_interaction_tokens(fresh, labels,
            actor_uuid: ApiKey.accountable_uuid(key)
          )
      end

      :ok
    end
  rescue
    _ -> :ok
  end

  defp label_or_default(conn, uuid) do
    case interaction_label(conn, uuid) do
      {:ok, label} -> label
      :error -> "interaction"
    end
  end

  def link(conn, %{"id" => id, "interaction" => uuid}) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
         {:ok, conn, a} <- fetch(conn, id),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :edit_tasks) do
      case link_interaction(conn, a, uuid) do
        :ok ->
          log_link(conn, a, uuid, "linked")
          json(conn, %{task: Json.task(Projects.get_assignment(a.uuid) || a)})

        {:error, {status, body}} ->
          conn |> put_status(status) |> json(body)
      end
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> not_found(conn)
    end
  end

  def unlink(conn, %{"id" => id, "interaction" => uuid}) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
         {:ok, conn, a} <- fetch(conn, id),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :edit_tasks) do
      :ok = Projects.unlink_interaction(a, uuid)
      log_link(conn, a, uuid, "unlinked")
      json(conn, %{task: Json.task(Projects.get_assignment(a.uuid) || a)})
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> not_found(conn)
    end
  end

  # An interaction belongs to the project that holds the client — often the
  # parent of the sub-project the task sits in — so the lookup tries the
  # task's project first, then each ancestor within the key's reach.
  defp log_link(conn, a, uuid, what) do
    key = conn.assigns.pk_api_key

    Activity.log("projects.assignment_updated",
      actor_uuid: ApiKey.accountable_uuid(key),
      resource_type: "assignment",
      resource_uuid: a.uuid,
      metadata:
        api_metadata(key, %{"fields" => ["interactions"], "interaction" => uuid, "change" => what})
    )
  end

  defp interaction_label(conn, uuid) do
    %{pk_api_key: key, pk_project: project} = conn.assigns

    with %{ext: ext, module: provider} <- Extensions.api_provider("interactions"),
         true <- function_exported?(provider, :get, 2),
         true <- ApiKey.scope?(key, provider.scopes().read) do
      candidates =
        [project | Enum.reverse(Projects.parent_chain(project.uuid))]
        |> Enum.filter(fn p ->
          Json.within_reach?(key, p.uuid) and Extensions.enabled?(p, ext.key) and
            Authz.can_role?(p, key.role, :view)
        end)

      Enum.find_value(candidates, :error, fn p ->
        ctx = ExtController.ctx(Json.rescope(conn, p))

        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        case apply(provider, :get, [ctx, uuid]) do
          {:ok, %{interaction: i}} -> {:ok, i[:subject] || i[:type] || "interaction"}
          _ -> nil
        end
      end)
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # A task created with an interaction that does not exist is refused
  # before the task exists — never a 201 with no link.
  defp check_interaction(_conn, nil), do: :ok

  defp check_interaction(conn, uuid) when is_binary(uuid) do
    case interaction_label(conn, uuid) do
      {:ok, _} ->
        :ok

      :error ->
        {:error,
         Json.error_body(
           404,
           "not_found",
           "No such interaction on this project or the projects above it.",
           %{interaction: uuid}
         )}
    end
  end

  defp check_interaction(_conn, _),
    do: {:error, Json.error_body(422, "validation_failed", "interaction must be a uuid.")}

  # Labels by name, when the project has labels on; a nil means "leave them".
  defp apply_labels(_project, _a, nil), do: :ok

  defp apply_labels(project, a, names) when is_list(names) do
    if Features.on?(project, "labels") do
      Labels.set_assignment_labels(a, Labels.ensure_by_names(project, names, label_opts(a)))
    end

    :ok
  end

  defp apply_labels(_project, _a, _), do: :ok

  # The key behind a label made on the fly, in its activity row.
  defp label_opts(a) do
    case Projects.get_assignment(a.uuid) do
      %Assignment{created_by_uuid: uuid, created_by_key_uuid: key_uuid} ->
        [actor_uuid: uuid, metadata: %{"via" => "api", "api_key" => key_uuid}]

      _ ->
        []
    end
  end

  # A checklist is a list of items, or absent — never a string.
  defp check_checklist(nil), do: :ok
  defp check_checklist(items) when is_list(items), do: :ok

  defp check_checklist(_),
    do:
      {:error,
       Json.error_body(422, "validation_failed", "checklist must be a list of items.", %{
         checklist: ["must be a list"]
       })}

  # Label names: a list of strings, each 1–60 characters (the registry's
  # cap); anything else is a 422 rather than a silent drop.
  defp check_labels(nil), do: :ok

  defp check_labels(names) when is_list(names) do
    bad = Enum.reject(names, &(is_binary(&1) and String.length(String.trim(&1)) in 1..60))

    if bad == [],
      do: :ok,
      else:
        {:error,
         Json.error_body(
           422,
           "validation_failed",
           "labels must be names of 1 to 60 characters.",
           %{
             labels: Enum.map(bad, &inspect/1)
           }
         )}
  end

  defp check_labels(_),
    do: {:error, Json.error_body(422, "validation_failed", "labels must be a list of names.")}

  # `position: "top"` puts the new task above every other row; anything
  # else (or nothing) appends, as a form does.
  defp position_attrs(project, "top"),
    do: %{"position" => Projects.top_assignment_position(project.uuid)}

  defp position_attrs(_project, _), do: %{}

  # A sub-project's linking row carries the child's rollup (status,
  # progress, duration); it is changed through the child project, never
  # edited or moved on its own.
  defp not_subproject_row(%Assignment{child_project_uuid: nil}), do: :ok
  defp not_subproject_row(_a), do: {:error, subproject_row_error()}

  defp subproject_row_error do
    Json.error_body(
      409,
      "subproject",
      "This row is a sub-project: its status and figures come from the child project, not from here."
    )
  end

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

  # Both rows' changesets are built and checked BEFORE either is written, so
  # a rule only a changeset knows (a checklist over 50 items, a title over its
  # length) is a 422 with nothing changed — not a new title beside a 422.
  defp precheck(%Assignment{task: task} = a, content, attrs) do
    fields = Map.merge(attrs, description_for_assignment(a, content))

    [
      map_size(content) > 0 && TaskSchema.changeset(task, content),
      map_size(fields) > 0 && Assignment.changeset(a, fields)
    ]
    |> Enum.find_value(:ok, fn
      %Ecto.Changeset{valid?: false} = cs -> {:error, cs}
      _ -> nil
    end)
  end

  defp description_for_assignment(%Assignment{description: d}, %{"description" => text})
       when is_binary(d) and d != "",
       do: %{"description" => text}

  defp description_for_assignment(_a, _content), do: %{}

  defp update_content(_a, content) when map_size(content) == 0, do: {:ok, nil}

  defp update_content(%Assignment{task: task} = a, content) do
    with {:ok, updated} <- Projects.update_task(task, content),
         :ok <- sync_assignment_description(a, content) do
      {:ok, updated}
    end
  end

  # A one-off made on the form carries its description on the assignment
  # too, and the reads prefer that copy — so a reword must reach both, or
  # the PATCH answers 200 and the old text keeps showing.
  defp sync_assignment_description(%Assignment{description: d} = a, %{"description" => text})
       when is_binary(d) and d != "" do
    case Projects.update_assignment_form(a, %{"description" => text}) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp sync_assignment_description(_a, _content), do: :ok

  defp update_fields(_a, attrs) when map_size(attrs) == 0, do: {:ok, nil}
  defp update_fields(a, attrs), do: Projects.update_assignment_form(a, attrs)

  def transition(conn, %{"id" => id} = params) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
         {:ok, conn, a} <- fetch(conn, id),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :update_status) do
      Json.idempotent(conn, [], fn -> do_transition(conn, a, params["status"]) end)
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> not_found(conn)
    end
  end

  def start(conn, params), do: transition(conn, Map.put(params, "status", "in_progress"))

  def delete(conn, %{"id" => id}) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
         {:ok, conn, a} <- fetch(conn, id),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :delete_tasks) do
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
         {:ok, conn, a} <- fetch(conn, id),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :edit_tasks) do
      Json.idempotent(conn, [], fn -> do_checklist_item(conn, a, item_id, params) end)
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp do_checklist_item(conn, a, item_id, params) do
    key = conn.assigns.pk_api_key

    case Map.get(params, "done") do
      done when done in [true, false, "true", "false"] ->
        case Projects.update_checklist_item(a, item_id, done in [true, "true"]) do
          {:ok, saved} ->
            Activity.log("projects.assignment_updated",
              actor_uuid: ApiKey.accountable_uuid(key),
              resource_type: "assignment",
              resource_uuid: a.uuid,
              metadata: api_metadata(key, %{"fields" => ["checklist"], "item" => item_id})
            )

            {200, %{task: Json.task(Projects.get_assignment(saved.uuid) || saved)}}

          {:error, :not_found} ->
            Json.error_body(404, "not_found", "No such checklist item on this task.")

          {:error, %Ecto.Changeset{} = cs} ->
            Json.changeset_error(cs)

          {:error, _} ->
            Json.error_body(409, "conflict", "The checklist could not be updated.")
        end

      _ ->
        Json.error_body(422, "validation_failed", "done must be true or false.", %{
          done: ["is required"]
        })
    end
  end

  def complete(conn, params), do: transition(conn, Map.put(params, "status", "done"))
  def reopen(conn, params), do: transition(conn, Map.put(params, "status", "todo"))

  defp do_transition(conn, %Assignment{} = a, to) do
    %{pk_api_key: key, pk_project: project} = conn.assigns
    allowed = Map.get(Json.transitions(), a.status, [])

    cond do
      not is_nil(a.child_project_uuid) ->
        subproject_row_error()

      (to == "in_progress" or a.status == "in_progress") and not Json.may_take?(key, a, project) ->
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
    e ->
      # The action itself succeeded; what failed is the project-level
      # follow-up (completion, the parent's rollup). Never invisible.
      Logger.warning("[Projects.Api] completion sync failed: #{Exception.message(e)}")
      :ok
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
      # A portal submission still in review is not work yet (every list
      # leaves it out); it is not reachable by its uuid either.
      %Assignment{review_status: status} when status not in [nil, "accepted"] ->
        {:error, :not_found}

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

      error = size_error(attrs) ->
        {:error, error}

      true ->
        {:ok, attrs}
    end
  end

  # The figures and lengths the columns bound: an int4 that overflows or a
  # string past its varchar is a 422 here, never a raise from the database.
  defp size_error(attrs) do
    cond do
      Map.has_key?(attrs, "estimated_duration") and
          not integer_in?(attrs["estimated_duration"], 1, @max_int) ->
        Json.error_body(
          422,
          "validation_failed",
          "estimated_duration must be a positive integer, at most #{@max_int}.",
          %{estimated_duration: ["must be a positive integer, at most #{@max_int}"]}
        )

      Map.has_key?(attrs, "position") and not integer_in?(attrs["position"], -@max_int, @max_int) ->
        Json.error_body(
          422,
          "validation_failed",
          "position must be an integer between #{-@max_int} and #{@max_int}.",
          %{position: ["must be an integer between #{-@max_int} and #{@max_int}"]}
        )

      Map.has_key?(attrs, "estimated_duration") and
          too_long_a_task?(attrs["estimated_duration"], attrs["estimated_duration_unit"]) ->
        Json.error_body(
          422,
          "validation_failed",
          "estimated_duration is longer than any task can be (about #{@max_task_minutes} minutes).",
          %{estimated_duration: ["must be at most about #{@max_task_minutes} minutes"]}
        )

      too_long?(attrs["waiting_on"], 200) ->
        Json.error_body(422, "validation_failed", "waiting_on must be at most 200 characters.", %{
          waiting_on: ["must be at most 200 characters"]
        })

      too_long?(attrs["origin"], 40) ->
        Json.error_body(422, "validation_failed", "origin must be at most 40 characters.", %{
          origin: ["must be at most 40 characters"]
        })

      true ->
        nil
    end
  end

  # The raw figure is bounded by the column; the figure in MINUTES is bounded
  # here, where the unit is known, because the parent's rollup sums minutes
  # into an int4.
  defp too_long_a_task?(n, unit) when is_integer(n) and unit in @units,
    do: TaskSchema.to_hours(n, unit, true) * 60 > @max_task_minutes

  defp too_long_a_task?(_n, _unit), do: false

  defp too_long?(v, max) when is_binary(v), do: String.length(v) > max
  defp too_long?(_, _max), do: false

  defp integer_in?(v, min, max) when is_integer(v),
    do: v >= min and v <= max

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
