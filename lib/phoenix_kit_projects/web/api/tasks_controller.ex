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

  Tasks sit under tasks (`PhoenixKitProjects.Outline`): `parent` on create
  and update, `POST /tasks/:id/move`, `POST /tasks/batch` for many lines at
  once, `parent=` on the list, and a delete that refuses a task with tasks
  under it unless `cascade=true`.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias PhoenixKit.Mentions

  alias PhoenixKitProjects.{
    Activity,
    ApiKeys,
    Authz,
    Extensions,
    Features,
    Labels,
    Ledger,
    Notices,
    Outline,
    Projects,
    RefText
  }

  alias PhoenixKitProjects.Outline.Api, as: OutlineApi

  alias PhoenixKitProjects.Schemas.{ApiKey, Assignment, Project}
  alias PhoenixKitProjects.Schemas.Task, as: TaskSchema
  alias PhoenixKitProjects.Web.Api.Assignee
  alias PhoenixKitProjects.Web.Api.ExtController
  alias PhoenixKitProjects.Web.Api.Json

  @priorities ~w(urgent high normal low)
  # The INTEGER columns (`estimated_duration`, `position`) hold int4; a
  # bound well inside it keeps a wild figure a 422 instead of an encode error.
  @max_int 1_000_000_000
  # About eleven years of one task, in minutes.
  @max_task_minutes 6_000_000
  @units ~w(minutes hours days weeks fortnights months years)

  @status_filters ~w(waiting todo in_progress done open)

  def index(conn, params) do
    with {:ok, conn} <- Json.scope_project(conn, params),
         {:ok, conn} <- Json.require_scope(conn, "tasks:read"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :view),
         {:ok, conn} <- known_status(conn, params["status"]),
         {:ok, due} <- due_before(conn, params["due_before"]),
         {:ok, under} <- under(conn, params),
         {:ok, tasks} <- assigned_to(conn, params["assignee"]) do
      outline = OutlineApi.info(conn.assigns.pk_project.uuid)

      tasks =
        tasks
        |> Enum.filter(&Json.visible_row?/1)
        |> filter_under(under, outline)
        |> filter_status(params["status"])
        |> filter_since(params["updated_since"])
        |> filter_due(due)

      uuids = Enum.map(tasks, & &1.uuid)
      totals = Ledger.totals_for_assignments(uuids)
      labels = Labels.labels_for_assignments(uuids)
      links = Projects.interactions_for_assignments(uuids)

      json(conn, %{
        tasks:
          Enum.map(
            tasks,
            &Json.task(&1, totals[&1.uuid], labels[&1.uuid] || [], links[&1.uuid] || [], outline)
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

  # `assignee`: `me`, `none` or a person's uuid (see `Assignee.filter/3`).
  defp assigned_to(conn, value) do
    tasks = Projects.list_assignments(conn.assigns.pk_project.uuid)

    case Assignee.filter(tasks, conn.assigns.pk_api_key, value) do
      {:ok, tasks} -> {:ok, tasks}
      {:error, {status, body}} -> {:halt, conn |> put_status(status) |> json(body)}
    end
  end

  # `parent`: `none` for the top level only, or a task (ref or uuid) for
  # the tasks directly under it. Absent: every row, in outline order.
  defp under(_conn, params) when not is_map_key(params, "parent"), do: {:ok, :all}
  defp under(_conn, %{"parent" => "none"}), do: {:ok, :top}

  defp under(conn, %{"parent" => ref}) do
    case parent_of(conn.assigns.pk_project, ref) do
      {:ok, %Assignment{uuid: uuid}} -> {:ok, uuid}
      {:error, {status, body}} -> {:halt, conn |> put_status(status) |> json(body)}
    end
  end

  defp filter_under(tasks, :all, _outline), do: tasks

  defp filter_under(tasks, :top, outline),
    do: Enum.filter(tasks, &(Map.get(outline.depths, &1.uuid, 0) == 0))

  defp filter_under(tasks, uuid, _outline), do: Enum.filter(tasks, &(&1.parent_uuid == uuid))

  # The task a `parent` names: an accepted task of THIS project (never a
  # sub-project row — what sits under that is the child project's own).
  defp parent_of(project, ref) when is_binary(ref) do
    case Projects.get_assignment(ref) do
      %Assignment{project_uuid: pid, review_status: "accepted", child_project_uuid: nil} = parent
      when pid == project.uuid ->
        {:ok, parent}

      %Assignment{project_uuid: pid, review_status: "accepted"} when pid == project.uuid ->
        {:error,
         Json.error_body(
           409,
           "subproject",
           "A sub-project row cannot have tasks under it here; add them to the sub-project."
         )}

      _ ->
        {:error,
         Json.error_body(404, "not_found", "No such parent task in this project.", %{parent: ref})}
    end
  rescue
    _ ->
      {:error,
       Json.error_body(404, "not_found", "No such parent task in this project.", %{parent: ref})}
  end

  defp parent_of(_project, _ref),
    do:
      {:error,
       Json.error_body(422, "validation_failed", "parent must be a task ref or uuid, or null.", %{
         parent: ["must be a task ref or uuid, or null"]
       })}

  # `parent` as create and update take it: absent → `:keep`; null → the top
  # level; a ref → that task.
  defp parent_change(_project, params) when not is_map_key(params, "parent"), do: {:ok, :keep}
  defp parent_change(_project, %{"parent" => nil}), do: {:ok, nil}

  defp parent_change(project, %{"parent" => ref}) do
    with {:ok, %Assignment{uuid: uuid}} <- parent_of(project, ref), do: {:ok, uuid}
  end

  defp move_error(:cycle),
    do: Json.error_body(409, "cycle", "A task cannot sit under itself or under a task below it.")

  defp move_error(_),
    do:
      Json.error_body(
        404,
        "not_found",
        "The parent or the sibling is not a task of this project."
      )

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

  # `due_before`: the tasks whose end date is on or before that day, done
  # ones included (filter with `status=open` for what is still owed). A
  # value that is not a date is refused - unlike a poll's `updated_since`,
  # a wrong answer here reads as "nothing is due".
  defp due_before(_conn, nil), do: {:ok, nil}

  defp due_before(conn, value) do
    case parse_date(value) do
      {:ok, %Date{} = d} ->
        {:ok, d}

      _ ->
        {:halt,
         Json.error(
           conn,
           :unprocessable_entity,
           "validation_failed",
           "due_before must be a date, YYYY-MM-DD.",
           %{due_before: ["must be a date, YYYY-MM-DD"]}
         )}
    end
  end

  defp filter_due(tasks, nil), do: tasks

  defp filter_due(tasks, %Date{} = d),
    do: Enum.filter(tasks, &(&1.end_date && Date.compare(&1.end_date, d) != :gt))

  # A calendar day as an agent sends it: `YYYY-MM-DD`; null or blank clears.
  defp parse_date(nil), do: {:ok, nil}

  defp parse_date(v) when is_binary(v) do
    case String.trim(v) do
      "" -> {:ok, nil}
      s -> with {:error, _} <- Date.from_iso8601(s), do: :error
    end
  end

  defp parse_date(_), do: :error

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

  defp filter_status(tasks, status) when status in ["waiting", "todo", "in_progress", "done"],
    do: Enum.filter(tasks, &(&1.status == status))

  defp filter_status(tasks, "open"), do: Enum.reject(tasks, &(&1.status == "done"))
  defp filter_status(tasks, _), do: tasks

  def show(conn, %{"id" => id}) do
    with {:ok, conn, a} <- fetch(conn, id),
         {:ok, conn} <- Json.require_scope(conn, "tasks:read"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :view) do
      json(conn, %{task: Map.merge(Json.task(a), Json.task_detail(a))})
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> not_found(conn)
    end
  end

  def create(conn, params) do
    with {:ok, conn} <- Json.scope_project(conn, params),
         {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
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
         {:ok, parent} <- parent_change(project, params) do
      do_create_checked(conn, key, project, Map.put(params, "parent", parent))
    else
      {:error, pair} -> pair
    end
  end

  defp do_create_checked(conn, key, project, params) do
    with {:ok, title} <- required_string(params, "title"),
         {:ok, assignment_attrs} <- assignment_attrs(params),
         {:ok, assignee} <- Assignee.attrs(conn, params) do
      assignment_attrs = Map.merge(assignment_attrs, assignee)

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

          # last under its parent (checked above); the top level needs no move
          if is_binary(params["parent"]), do: Outline.move(a, params["parent"], :last)

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
      {:error, {status, _} = pair} when is_integer(status) -> pair
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, conn, a} <- fetch(conn, id),
         {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
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
         {:ok, assignee} <- Assignee.attrs(conn, params),
         assignment_attrs = Map.merge(assignment_attrs, assignee),
         :ok <- check_interaction(conn, params["interaction"]),
         :ok <- check_labels(params["labels"]),
         {:ok, parent} <- parent_change(project, params),
         :ok <- precheck(a, content, assignment_attrs),
         {:ok, _} <-
           write_update(fn ->
             with :ok <- reparent(a, parent),
                  {:ok, _} <- update_content(a, content),
                  {:ok, _} <- update_fields(a, assignment_attrs),
                  :ok <- stamp_words(a, key, content),
                  :ok <- keep_interaction_tokens(conn, a),
                  :ok <- apply_labels(project, a, params["labels"]),
                  :ok <- link_interaction(conn, a, params["interaction"]) do
               {:ok, :written}
             end
           end) do
      changed =
        Map.keys(Map.merge(content, assignment_attrs)) ++
          Enum.filter(["labels", "interaction", "parent"], &Map.has_key?(params, &1))

      reassigned? =
        Notices.reassigned(
          a,
          Projects.get_assignment(a.uuid),
          ApiKey.accountable_uuid(key),
          api_metadata(key, %{})
        )

      # A handed-over task was told so already; a move or a meeting link is
      # the list's bookkeeping. Otherwise its people hear the task changed.
      Activity.log("projects.assignment_updated",
        actor_uuid: ApiKey.accountable_uuid(key),
        resource_type: "assignment",
        resource_uuid: a.uuid,
        tell: not reassigned? and changed -- ~w(parent position interaction) != [],
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

  # The PATCH's writes are one transaction: a refusal half-way (a database
  # constraint, a failed link) leaves nothing written. The pages hear of it
  # once it has committed (`PubSub.after_commit/1`), and the people the
  # change concerns only then (the hand-off batch, dropped on a rollback).
  defp write_update(fun) do
    PhoenixKitProjects.Handoffs.batch(fn ->
      case PhoenixKitProjects.PubSub.after_commit(fun) do
        {:ok, _} = ok ->
          ok

        {:error, _} = error ->
          PhoenixKitProjects.Handoffs.discard()
          error
      end
    end)
  end

  # A changed `parent` moves the task, with everything under it, to the
  # end of its new parent's tasks.
  defp reparent(_a, :keep), do: :ok
  defp reparent(%Assignment{parent_uuid: same}, same), do: :ok

  defp reparent(a, parent_uuid) do
    case Outline.move(a, parent_uuid, :last) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, move_error(reason)}
    end
  end

  # Indexes the `#` links in a saved description, so a task that says
  # "from this meeting" is listed on the meeting (core keeps the reverse
  # index). Never fails the save: a mention that does not index is a
  # missing backlink, not lost work.
  defp sync_mentions(assignment_uuid, description, key) when is_binary(description) do
    # As it was stored: a `#ACME-42` in the submitted text is a token there.
    Mentions.sync("project_task", assignment_uuid, RefText.expand(description),
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
    with {:ok, conn, a} <- fetch(conn, id),
         {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
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
    with {:ok, conn, a} <- fetch(conn, id),
         {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
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

    # A link to a meeting is bookkeeping, not news for the task's people.
    Activity.log("projects.assignment_updated",
      actor_uuid: ApiKey.accountable_uuid(key),
      resource_type: "assignment",
      resource_uuid: a.uuid,
      tell: false,
      metadata:
        api_metadata(key, %{"fields" => ["interactions"], "interaction" => uuid, "change" => what})
    )
  end

  defp interaction_label(conn, uuid) do
    %{pk_api_key: key, pk_project: project} = conn.assigns

    with %{ext: ext, module: provider} <- Extensions.api_provider("interactions"),
         # Read access is checked per project below: the interaction may
         # sit on a parent the key reads while this project grants none.
         true <- function_exported?(provider, :get, 2) do
      candidates =
        [project | Enum.reverse(Projects.parent_chain(project.uuid))]
        |> Enum.filter(fn p ->
          with true <- ApiKeys.allows?(key, p.uuid, provider.scopes().read),
               true <- Extensions.enabled?(p, ext.key),
               {:ok, view} <- ApiKeys.view(key, p) do
            Authz.can_role?(p, view.role, :view)
          else
            _ -> false
          end
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
  # a rule only a changeset knows (a title over its length, an end date
  # before the start) is a 422 with nothing changed — not a new title beside a 422.
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
    with {:ok, conn, a} <- fetch(conn, id),
         {:ok, conn} <- Json.require_scope(conn, "status:write"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :update_status) do
      Json.idempotent(conn, [], fn -> do_transition(conn, a, params["status"]) end)
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> not_found(conn)
    end
  end

  def start(conn, params), do: transition(conn, Map.put(params, "status", "in_progress"))

  def delete(conn, %{"id" => id} = params) do
    with {:ok, conn, a} <- fetch(conn, id),
         {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :delete_tasks) do
      %{pk_api_key: key, pk_project: project} = conn.assigns
      below = below(a)

      cond do
        not is_nil(a.child_project_uuid) ->
          Json.error(conn, :conflict, "subproject", "A sub-project is not deleted here.")

        not Json.may_delete?(key, a, project) ->
          delete_refused(conn, project)

        below != [] and params["cascade"] not in [true, "true"] ->
          Json.error(
            conn,
            :conflict,
            "has_subtasks",
            "This task has #{length(below)} task(s) under it; pass cascade=true to delete them with it.",
            %{subtasks: length(below)}
          )

        Enum.any?(below, &(not is_nil(&1.child_project_uuid))) ->
          Json.error(
            conn,
            :conflict,
            "subproject",
            "A sub-project sits under this task; it is not deleted here."
          )

        not Enum.all?(below, &Json.may_delete?(key, &1, project)) ->
          delete_refused(conn, project)

        true ->
          delete_branch(conn, a, below, key)
      end
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp delete_branch(conn, a, below, key) do
    delete = fn -> Projects.delete_assignment(a) end

    case Notices.removing(a, ApiKey.accountable_uuid(key), api_metadata(key, %{}), delete) do
      {:ok, _} ->
        Activity.log("projects.assignment_removed",
          actor_uuid: ApiKey.accountable_uuid(key),
          resource_type: "assignment",
          resource_uuid: a.uuid,
          metadata:
            api_metadata(key, %{"task" => Assignment.label(a), "subtasks" => length(below)})
        )

        sync_project_completion(conn)
        json(conn, %{deleted: a.uuid, also_deleted: Enum.map(below, & &1.uuid)})

      {:error, _} ->
        Json.error(conn, :conflict, "conflict", "The task could not be deleted.")
    end
  end

  defp delete_refused(conn, project) do
    Json.error(
      conn,
      :forbidden,
      "delete_not_allowed",
      "The project does not let an agent delete this task (policy delete_tasks: #{Project.agent_policy(project)["delete_tasks"]}).",
      %{policy: "delete_tasks"}
    )
  end

  # Every accepted row under a task, any depth — what a delete takes with it.
  # Everything the delete would take: held subtasks too, since the
  # database cascade takes them whether or not a list shows them.
  defp below(%Assignment{} = a), do: Outline.rows_below(a)

  # ── Subtasks: move, and many lines at once ──────────────────────

  @doc """
  `POST /tasks/:id/move` — puts a task, with everything under it, somewhere
  else in its project's outline. `parent`: a task (ref or uuid), null for
  the top level, absent to stay under the same parent. `after`: a sibling
  under that parent to go after, null to go first, absent to go last.
  """
  def move(conn, %{"id" => id} = params) do
    with {:ok, conn, a} <- fetch(conn, id),
         {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :edit_tasks) do
      Json.idempotent(conn, [], fn -> do_move(conn, a, params) end)
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp do_move(conn, %Assignment{} = a, params) do
    %{pk_api_key: key, pk_project: project} = conn.assigns

    with {:ok, parent} <- parent_change(project, params),
         parent_uuid = if(parent == :keep, do: a.parent_uuid, else: parent),
         {:ok, place} <- after_of(project, params),
         {:ok, _} <- move_result(Outline.move(a, parent_uuid, place)) do
      # A place in the list is the list's business, not news for its people.
      Activity.log("projects.assignment_updated",
        actor_uuid: ApiKey.accountable_uuid(key),
        resource_type: "assignment",
        resource_uuid: a.uuid,
        tell: false,
        metadata: api_metadata(key, %{"fields" => ["parent", "position"]})
      )

      sync_project_completion(conn)
      {200, %{task: Json.task(Projects.get_assignment(a.uuid))}}
    else
      {:error, {status, _} = pair} when is_integer(status) -> pair
    end
  end

  defp move_result({:ok, _} = ok), do: ok
  defp move_result({:error, reason}), do: {:error, move_error(reason)}

  defp after_of(_project, params) when not is_map_key(params, "after"), do: {:ok, :last}
  defp after_of(_project, %{"after" => nil}), do: {:ok, nil}

  defp after_of(project, %{"after" => ref}) when is_binary(ref) do
    case Projects.get_assignment(ref) do
      %Assignment{project_uuid: pid, uuid: uuid} when pid == project.uuid ->
        {:ok, uuid}

      _ ->
        {:error,
         Json.error_body(404, "not_found", "No such sibling task in this project.", %{after: ref})}
    end
  rescue
    _ ->
      {:error,
       Json.error_body(404, "not_found", "No such sibling task in this project.", %{after: ref})}
  end

  defp after_of(_project, _),
    do:
      {:error,
       Json.error_body(422, "validation_failed", "after must be a task ref or uuid, or null.", %{
         after: ["must be a task ref or uuid, or null"]
       })}

  @doc """
  `POST /tasks/batch` — one one-off task per line, in one transaction:
  `lines` is a list of strings or `{text, depth?, done?}`; `depth` nests a
  line under the nearest line above that is one level shallower; `parent`
  puts the whole batch under a task (depth 0 sits directly under it).
  """
  def batch(conn, params) do
    with {:ok, conn} <- Json.scope_project(conn, params),
         {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :create_tasks) do
      Json.idempotent(conn, [], fn -> do_batch(conn, params) end)
    else
      {:halt, conn} -> conn
    end
  end

  defp do_batch(conn, params) do
    %{pk_api_key: key, pk_project: project} = conn.assigns

    with {:ok, lines} <- batch_lines(params["lines"]),
         {:ok, parent} <- parent_change(project, params),
         parent_uuid = if(parent == :keep, do: nil, else: parent),
         {:ok, uuids} <-
           batch_result(
             OutlineApi.batch_create(project.uuid, lines, parent_uuid,
               actor_uuid: ApiKey.accountable_uuid(key),
               key_uuid: key.uuid
             )
           ) do
      Enum.zip(uuids, lines)
      |> Enum.each(fn {uuid, line} ->
        # A batch's lines are born unassigned: nobody to tell, and no reason
        # to read 500 tasks back to find that out.
        Activity.log("projects.assignment_created",
          actor_uuid: ApiKey.accountable_uuid(key),
          resource_type: "assignment",
          resource_uuid: uuid,
          tell: false,
          metadata: api_metadata(key, %{"task" => line.text, "batch" => length(uuids)})
        )
      end)

      sync_project_completion(conn)

      wanted = MapSet.new(uuids)
      by_uuid = project.uuid |> Projects.list_assignments() |> Map.new(&{&1.uuid, &1})
      outline = OutlineApi.info(project.uuid)
      totals = Ledger.totals_for_assignments(uuids)

      tasks =
        for uuid <- uuids, MapSet.member?(wanted, uuid), a = by_uuid[uuid], not is_nil(a) do
          Json.task(a, totals[uuid], [], [], outline)
        end

      {201, %{tasks: tasks, count: length(tasks)}}
    else
      {:error, {status, _} = pair} when is_integer(status) -> pair
    end
  end

  defp batch_lines(lines) do
    case OutlineApi.read_lines(lines) do
      {:ok, lines} ->
        {:ok, lines}

      {:error, :too_many} ->
        {:error,
         Json.error_body(
           422,
           "validation_failed",
           "lines holds at most #{OutlineApi.max_lines()} lines per call.",
           %{lines: ["at most #{OutlineApi.max_lines()}"]}
         )}

      {:error, {:bad_line, index}} ->
        {:error,
         Json.error_body(
           422,
           "validation_failed",
           "Line #{index} is not a string or {text, depth?, done?} (text up to 500 characters, depth 0 to 100, done true or false).",
           %{lines: %{index => ["is invalid"]}}
         )}

      {:error, :empty} ->
        {:error,
         Json.error_body(422, "validation_failed", "lines has no line with text.", %{
           lines: ["can't be blank"]
         })}

      {:error, _} ->
        {:error,
         Json.error_body(422, "validation_failed", "lines must be a list.", %{
           lines: ["must be a list"]
         })}
    end
  end

  defp batch_result({:ok, _} = ok), do: ok

  defp batch_result({:error, {:line, _index, %Ecto.Changeset{} = cs}}),
    do: {:error, Json.changeset_error(cs)}

  defp batch_result({:error, _}),
    do: {:error, Json.error_body(404, "not_found", "The project or the parent task is gone.")}

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
          "status must be one of waiting, todo, in_progress, done.",
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
        before = OutlineApi.statuses(a.project_uuid)
        {action, result} = apply_transition(a, to, key)

        case result do
          {:ok, _} ->
            log_transition(conn, action, a, to, key)
            sync_project_completion(conn)

            # the rows the move took with it: the tasks under a completed
            # one, a parent whose last task this was, the parents a reopen
            # reopened
            also = OutlineApi.changed_besides(before, OutlineApi.statuses(a.project_uuid), a.uuid)
            {200, %{task: Json.task(Projects.get_assignment(a.uuid)), also_changed: also}}

          {:error, %Ecto.Changeset{} = cs} ->
            Json.changeset_error(cs)
        end
    end
  end

  defp log_transition(conn, action, a, to, key) do
    reason = if action == "projects.assignment_reopened", do: reopen_reason(conn, to, a, key)

    # Releasing or idling names no target: the hand-off is the notice
    # (`Handoffs`), and idle tells nobody.
    readiness? = action in ["projects.assignment_made_ready", "projects.assignment_made_idle"]

    Activity.log(action,
      actor_uuid: ApiKey.accountable_uuid(key),
      resource_type: "assignment",
      resource_uuid: a.uuid,
      target_uuid: if(readiness?, do: nil, else: Activity.assignee_target_uuid(a)),
      tell: not readiness?,
      metadata:
        api_metadata(
          key,
          if(reason,
            do: %{"task" => Assignment.label(a), "reason" => reason},
            else: %{"task" => Assignment.label(a)}
          )
        )
    )
  end

  # A reopen's `reason`, as on the project page: posted to the task's
  # discussion (as the key's person, labelled with the key) when the project
  # has discussions on, and quoted by the reopen's notice either way.
  defp reopen_reason(conn, "todo", a, key) do
    case conn.params["reason"] do
      reason when is_binary(reason) ->
        case reason |> String.trim() |> String.slice(0, 2_000) do
          "" ->
            nil

          reason ->
            # Only a key that may also comment posts it as a comment; the
            # notice quotes it either way.
            # The same gates as POST /tasks/{id}/comments: the scope and the
            # project's :comment floor for this key's role.
            if ApiKey.scope?(key, "comments:write") and
                 Authz.can_role?(conn.assigns.pk_project, key.role, :comment),
               do: post_reason(a, key, reason)

            reason
        end

      _ ->
        nil
    end
  end

  defp reopen_reason(_conn, _to, _a, _key), do: nil

  defp post_reason(a, key, reason) do
    person = ApiKey.accountable_uuid(key)

    if is_binary(person) and PhoenixKitProjects.Extensions.enabled?(a.project_uuid, "discussions") and
         Code.ensure_loaded?(PhoenixKitComments) and PhoenixKitComments.enabled?() do
      PhoenixKitComments.create_comment("assignment", a.uuid, person, %{
        content: reason,
        metadata: %{"reopen_reason" => true},
        attribution: %{mode: "personal", label: key.name}
      })
    end
  rescue
    e ->
      Logger.warning("[Projects API] reopen reason comment failed: #{inspect(e.__struct__)}")
      :ok
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

  # Released from waiting ("can be started" — the hand-off tells its
  # people) or put back to idle; from started or done work, a reopen.
  defp apply_transition(%Assignment{status: "waiting"} = a, "todo", _key),
    do:
      {"projects.assignment_made_ready", Projects.update_assignment_status(a, %{status: "todo"})}

  defp apply_transition(a, "todo", _key),
    do: {"projects.assignment_reopened", Projects.reopen_assignment(a)}

  defp apply_transition(%Assignment{status: "todo"} = a, "waiting", _key),
    do:
      {"projects.assignment_made_idle",
       Projects.update_assignment_status(a, %{status: "waiting"})}

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
        if Json.visible_row?(a), do: {:ok, conn, a}, else: {:error, :not_found}

      %Assignment{project_uuid: pid} = a ->
        with true <- Json.within_reach?(key, pid),
             %{} = child <- Projects.get_project(pid),
             conn = Json.rescope(conn, child),
             {:ok, conn} <- Json.still_allowed(conn),
             {:ok, conn} <- Json.require_feature(conn, :tasks),
             true <- Json.visible_row?(a) do
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
      |> maybe_put("position", params["position"] |> then(&if(is_integer(&1), do: &1)))

    with {:ok, attrs} <- put_date(attrs, "start_date", params),
         {:ok, attrs} <- put_date(attrs, "end_date", params),
         {:ok, attrs} <- put_deadline(attrs, params) do
      checked_attrs(attrs)
    end
  end

  # By when it has to be done (V26): an ISO 8601 moment with its offset
  # (`2026-10-29T15:00:00+02:00`), or null to clear. A bare day or a time
  # without an offset is refused: an agent's clock is not the reader's.
  defp put_deadline(attrs, params) do
    case Map.fetch(params, "deadline") do
      :error ->
        {:ok, attrs}

      {:ok, nil} ->
        {:ok, Map.put(attrs, "deadline", nil)}

      {:ok, value} when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, at, _offset} -> {:ok, Map.put(attrs, "deadline", DateTime.truncate(at, :second))}
          _ -> deadline_error()
        end

      {:ok, _} ->
        deadline_error()
    end
  end

  defp deadline_error do
    {:error,
     Json.error_body(
       422,
       "validation_failed",
       "deadline must be an ISO 8601 date and time with an offset, e.g. 2026-10-29T15:00:00+02:00.",
       %{deadline: ["must be a date and time with an offset"]}
     )}
  end

  # A date an agent may set or clear; anything that is not a day is a 422.
  defp put_date(attrs, field, params) do
    case Map.fetch(params, field) do
      :error ->
        {:ok, attrs}

      {:ok, value} ->
        case parse_date(value) do
          {:ok, date} ->
            {:ok, Map.put(attrs, field, date)}

          :error ->
            {:error,
             Json.error_body(422, "validation_failed", "#{field} must be a date, YYYY-MM-DD.", %{
               field => ["must be a date, YYYY-MM-DD"]
             })}
        end
    end
  end

  defp checked_attrs(attrs) do
    cond do
      match?(%Date{}, attrs["start_date"]) and match?(%Date{}, attrs["end_date"]) and
          Date.compare(attrs["end_date"], attrs["start_date"]) == :lt ->
        {:error,
         Json.error_body(
           422,
           "validation_failed",
           "end_date must not be before start_date.",
           %{end_date: ["must not be before the start date"]}
         )}

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
end
