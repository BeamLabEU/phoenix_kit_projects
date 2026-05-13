defmodule PhoenixKitProjects.Web.ProjectShowLive do
  @moduledoc """
  Show a project with a vertical timeline of assignments.
  Supports inline status changes, duration editing, dependency
  management, and tracks who completed each task.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{Activity, L10n, Paths, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.{Assignment, Project}
  alias PhoenixKitProjects.Schemas.Task, as: TaskSchema

  require Logger

  # Default wrapper class for the standalone admin page. Embedders can
  # override via `live_render(... session: %{"wrapper_class" => "..."})`
  # to drop `mx-auto max-w-4xl` and fill a wider host layout.
  @default_wrapper_class "flex flex-col mx-auto max-w-4xl px-4 py-6 gap-4"

  # Embedded entry: when nested via `live_render`, params arrives as
  # `:not_mounted_at_router` and `session` carries the project id (plus
  # any `wrapper_class` override). Delegate to the router clause so the
  # mount logic stays single-sourced.
  @impl true
  def mount(:not_mounted_at_router, %{"id" => id} = session, socket) do
    mount(%{"id" => id}, session, socket)
  end

  def mount(%{"id" => id}, session, socket) do
    # `get_project/1` stays in mount/3 because the not-found path
    # has to redirect before render, and the per-project PubSub
    # topic needs the project.uuid to subscribe to. The heavier
    # assignment/comment loads sit at the tail of mount/3 (not
    # `handle_params/3`) because Phoenix LiveView refuses to mount a
    # LV that exports `handle_params/3` outside a router live route,
    # which would block embedding via `live_render`.
    case Projects.get_project(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Project not found."))
         |> push_navigate(to: Paths.projects())}

      project ->
        if connected?(socket) do
          # Per-project topic covers assignment/dependency events for this
          # project; the tasks topic covers library-level task renames so
          # the visible assignment rows don't go stale.
          ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(project.uuid))
          ProjectsPubSub.subscribe(ProjectsPubSub.topic_tasks())
        end

        is_template = project.is_template

        lang = L10n.current_content_lang()

        wrapper_class = Map.get(session, "wrapper_class", @default_wrapper_class)

        socket =
          assign(socket,
            page_title: Project.localized_name(project, lang),
            project: project,
            is_template: is_template,
            wrapper_class: wrapper_class,
            editing_duration_uuid: nil,
            start_modal_open: false,
            start_form: to_form(%{"start_at" => default_start_at_local()}),
            # Comments drawer state. `comments_resource` is `nil` when
            # closed; a `%{type, uuid, title}` map when open. The
            # `CommentsComponent` is keyed on `{type, uuid}` so opening
            # different resources doesn't reuse stale state.
            comments_resource: nil,
            comments_enabled: comments_available?(),
            project_comment_count: 0,
            assignment_comment_counts: %{},
            # Skeleton defaults overwritten by the load_* helpers below;
            # they keep the assigns coherent if either helper short-circuits.
            assignments: [],
            deps_by_assignment: %{},
            total_tasks: 0,
            done_tasks: 0,
            progress_pct: 0,
            schedule: nil
          )

        {:ok, socket |> load_assignments() |> load_comment_counts()}
    end
  end

  # ── PubSub reactivity ─────────────────────────────────────────
  # Catch-all handle_info avoids crashes on unexpected messages.

  @impl true
  def handle_info({:projects, event, _payload}, socket)
      when event in [
             :assignment_created,
             :assignment_updated,
             :assignment_deleted,
             :dependency_added,
             :dependency_removed,
             # Task-library renames change displayed assignment titles.
             :task_updated,
             :task_deleted
           ] do
    {:noreply, load_assignments(socket)}
  end

  def handle_info({:projects, event, _payload}, socket)
      when event in [:project_updated, :project_completed, :project_reopened, :project_started] do
    case Projects.get_project(socket.assigns.project.uuid) do
      nil -> {:noreply, socket}
      p -> {:noreply, socket |> assign(project: p) |> load_assignments()}
    end
  end

  def handle_info({:projects, :project_deleted, _payload}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("This project was deleted."))
     |> push_navigate(to: Paths.projects())}
  end

  # `CommentsComponent` notifies its parent LV after every create /
  # delete so the button badges can refresh without an extra round
  # trip. We reload the full count map regardless of which resource
  # changed — both project and assignment counts cost a single
  # query each, and the message carries an `action` (`:created |
  # :deleted`) that we don't need to discriminate on here.
  def handle_info({:comments_updated, _payload}, socket) do
    {:noreply, load_comment_counts(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[ProjectShowLive] unexpected handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp load_assignments(socket) do
    project_uuid = socket.assigns.project.uuid
    assignments = Projects.list_assignments(project_uuid)

    deps_by_assignment =
      Projects.list_all_dependencies(project_uuid)
      |> Enum.group_by(& &1.assignment_uuid)

    total = length(assignments)
    done = Enum.count(assignments, &(&1.status == "done"))
    schedule = calculate_schedule(socket.assigns.project, assignments)

    assign(socket,
      assignments: assignments,
      deps_by_assignment: deps_by_assignment,
      total_tasks: total,
      done_tasks: done,
      progress_pct: if(total > 0, do: round(done / total * 100), else: 0),
      schedule: schedule
    )
  end

  # Updates the assignment, logs the activity on success, and returns a tuple
  # `{:ok, socket}` for the maybe_sync_and_reload pipeline.
  # The `complete`/`start_task`/`reopen`/`update_progress` handlers go
  # through the server-trusted `update_assignment_status/2` because their
  # attrs include `completed_by_uuid` / `completed_at`, which the
  # form-safe `update_assignment_form/2` intentionally drops.
  defp update_assignment_with_activity(socket, a, attrs, action_name, opts) do
    case Projects.update_assignment_status(a, attrs) do
      {:ok, _} ->
        Activity.log(action_name,
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: a.uuid,
          metadata: Keyword.get(opts, :metadata, %{})
        )

        {:ok, socket}

      {:error, cs} ->
        Activity.log_failed(action_name,
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: a.uuid,
          metadata: Keyword.get(opts, :metadata, %{})
        )

        {:error, socket, error_summary(cs, gettext("Could not update task."))}
    end
  end

  defp maybe_sync_and_reload({:ok, socket}) do
    {:noreply, socket |> sync_project_completion() |> load_assignments()}
  end

  defp maybe_sync_and_reload({:error, socket, msg}) do
    {:noreply, put_flash(socket, :error, msg)}
  end

  # Translates Ecto validator messages through the gettext "errors"
  # domain — Ecto emits English literals like `"is invalid"` /
  # `"must be greater than 0"` from `validate_*` plus interpolation
  # bindings; `Gettext.dngettext/6` is the canonical translator for
  # those (matches the Phoenix scaffolding pattern). Without this,
  # the inline error summary (e.g. on a failed `complete` from a
  # validation-rejected status transition) renders English regardless
  # of the user's locale — Phase 1 PR #1 review item #15, deferred
  # then to Phase 2 C3 + closed in this re-validation batch.
  #
  # Named `translate_validator_error/1` (not `translate_error/1`) to
  # avoid shadowing `PhoenixKitWeb.Components.Core.Input.translate_error/1`
  # which is auto-imported by `use PhoenixKitWeb, :live_view`.
  defp error_summary(%Ecto.Changeset{errors: errors}, fallback) do
    case errors do
      [] ->
        fallback

      errs ->
        Enum.map_join(errs, ", ", fn {k, {msg, opts}} ->
          "#{humanize_field(k)}: #{translate_validator_error({msg, opts})}"
        end)
    end
  end

  # Renders an Ecto field name like `:estimated_duration` as
  # `"Estimated duration"` for the cross-field flash summary. The
  # per-field input component already humanizes its own label, so this
  # only matters for the multi-error fallback.
  defp humanize_field(field) do
    field
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp translate_validator_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(PhoenixKitWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(PhoenixKitWeb.Gettext, "errors", msg, opts)
    end
  end

  defp sync_project_completion(socket) do
    case Projects.recompute_project_completion(socket.assigns.project.uuid) do
      {:completed, project} ->
        Activity.log("projects.project_completed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        socket
        |> assign(project: project)
        |> put_flash(:info, gettext("🎉 All tasks done — project completed!"))

      {:reopened, project} ->
        Activity.log("projects.project_reopened",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        assign(socket, project: project)

      {:unchanged, _} ->
        socket

      _ ->
        socket
    end
  end

  # Looks up an assignment and verifies it belongs to the project the
  # user is currently viewing. Prevents an admin on project A from
  # mutating assignments in project B by crafting event params.
  defp scoped_assignment(socket, uuid) do
    case Projects.get_assignment(uuid) do
      %{project_uuid: pid} = a when pid == socket.assigns.project.uuid -> a
      _ -> nil
    end
  end

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("complete", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      a ->
        attrs = %{
          status: "done",
          progress_pct: 100,
          completed_by_uuid: Activity.actor_uuid(socket),
          completed_at: DateTime.utc_now()
        }

        socket
        |> update_assignment_with_activity(a, attrs, "projects.assignment_completed",
          metadata: %{"task" => a.task.title, "project" => socket.assigns.project.name}
        )
        |> maybe_sync_and_reload()
    end
  end

  def handle_event("start_task", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      a ->
        new_pct = if a.progress_pct == 100, do: 0, else: a.progress_pct
        attrs = %{status: "in_progress", progress_pct: new_pct}

        socket
        |> update_assignment_with_activity(a, attrs, "projects.assignment_started",
          metadata: %{"task" => a.task.title}
        )
        |> maybe_sync_and_reload()
    end
  end

  def handle_event("reopen", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      a ->
        attrs = %{
          status: "todo",
          progress_pct: 0,
          completed_by_uuid: nil,
          completed_at: nil
        }

        socket
        |> update_assignment_with_activity(a, attrs, "projects.assignment_reopened",
          metadata: %{"task" => a.task.title}
        )
        |> maybe_sync_and_reload()
    end
  end

  def handle_event("edit_duration", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      _a ->
        # Just flip the assign — the template sources the prefilled
        # values directly from the assignment row via the `:for=` loop
        # variable, so there's nothing to stage into a form here.
        {:noreply, assign(socket, editing_duration_uuid: uuid)}
    end
  end

  def handle_event("cancel_edit_duration", _params, socket) do
    {:noreply, assign(socket, editing_duration_uuid: nil)}
  end

  def handle_event(
        "save_duration",
        %{"estimated_duration" => dur, "estimated_duration_unit" => unit},
        socket
      ) do
    uuid = socket.assigns.editing_duration_uuid

    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      a ->
        old_dur = "#{a.estimated_duration} #{a.estimated_duration_unit}"
        attrs = %{estimated_duration: dur, estimated_duration_unit: unit}

        case Projects.update_assignment_form(a, attrs) do
          {:ok, _} ->
            Activity.log("projects.assignment_duration_changed",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "assignment",
              resource_uuid: uuid,
              metadata: %{
                "task" => a.task.title,
                "from" => old_dur,
                "to" => "#{dur} #{unit}"
              }
            )

            {:noreply,
             socket
             |> assign(editing_duration_uuid: nil)
             |> load_assignments()}

          {:error, cs} ->
            Activity.log_failed("projects.assignment_duration_changed",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "assignment",
              resource_uuid: uuid,
              metadata: %{
                "task" => a.task.title,
                "from" => old_dur,
                "to" => "#{dur} #{unit}"
              }
            )

            {:noreply,
             socket
             |> assign(editing_duration_uuid: nil)
             |> put_flash(:error, error_summary(cs, gettext("Could not update duration.")))}
        end
    end
  end

  def handle_event("remove_assignment", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      a ->
        case Projects.delete_assignment(a) do
          {:ok, _} ->
            Activity.log("projects.assignment_removed",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "assignment",
              resource_uuid: uuid,
              metadata: %{"task" => a.task.title}
            )

            {:noreply,
             socket
             |> put_flash(:info, gettext("Task removed."))
             |> sync_project_completion()
             |> load_assignments()}

          {:error, _} ->
            Activity.log_failed("projects.assignment_removed",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "assignment",
              resource_uuid: uuid,
              metadata: %{"task" => a.task.title}
            )

            {:noreply, put_flash(socket, :error, gettext("Could not remove task."))}
        end
    end
  end

  def handle_event("update_progress", %{"uuid" => uuid, "progress_pct" => pct_str}, socket) do
    case scoped_assignment(socket, uuid) do
      nil -> {:noreply, socket}
      a -> do_update_progress(socket, a, parse_pct(pct_str))
    end
  end

  def handle_event("toggle_tracking", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      a ->
        new_value = not a.track_progress

        case Projects.update_assignment_form(a, %{track_progress: new_value}) do
          {:ok, _} ->
            Activity.log("projects.assignment_tracking_toggled",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "assignment",
              resource_uuid: uuid,
              metadata: %{"task" => a.task.title, "track_progress" => new_value}
            )

            {:noreply, load_assignments(socket)}

          {:error, _} ->
            Activity.log_failed("projects.assignment_tracking_toggled",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "assignment",
              resource_uuid: uuid,
              metadata: %{"task" => a.task.title, "track_progress" => new_value}
            )

            {:noreply, put_flash(socket, :error, gettext("Could not toggle tracking."))}
        end
    end
  end

  def handle_event("remove_dependency", %{"assignment" => a_uuid, "depends_on" => d_uuid}, socket) do
    # Both assignments must belong to the currently-viewed project —
    # prevents an admin on project A from unlinking deps in project B.
    # Cross-project mismatches are silent noops (UI never offers them).
    # An actual `remove_dependency/2` failure is rare but logged via
    # `log_failed` so a Postgres outage doesn't erase the click.
    with %{} <- scoped_assignment(socket, a_uuid),
         %{} <- scoped_assignment(socket, d_uuid) do
      case Projects.remove_dependency(a_uuid, d_uuid) do
        {:ok, _} ->
          Activity.log("projects.dependency_removed",
            actor_uuid: Activity.actor_uuid(socket),
            resource_type: "assignment",
            resource_uuid: a_uuid,
            target_uuid: d_uuid,
            metadata: %{}
          )

          {:noreply, load_assignments(socket)}

        {:error, _} ->
          Activity.log_failed("projects.dependency_removed",
            actor_uuid: Activity.actor_uuid(socket),
            resource_type: "assignment",
            resource_uuid: a_uuid,
            target_uuid: d_uuid,
            metadata: %{}
          )

          {:noreply, put_flash(socket, :error, gettext("Could not remove dependency."))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # Opens the start-project modal pre-filled with today's date. The
  # actual DB write happens in `confirm_start_project` so users can
  # backdate (project was already running before the system was set up)
  # or future-date (preparing the project but actual start is later).
  # Falls through to a no-op for projects already started — defensive
  # against double-clicks racing the LV's render of the now-hidden
  # button.
  def handle_event("open_start_modal", _params, socket) do
    if socket.assigns.project.started_at do
      {:noreply, socket}
    else
      {:noreply,
       assign(socket,
         start_modal_open: true,
         start_form: to_form(%{"start_at" => default_start_at_local()})
       )}
    end
  end

  def handle_event("close_start_modal", _params, socket) do
    {:noreply, assign(socket, start_modal_open: false)}
  end

  def handle_event("confirm_start_project", %{"start_at" => datetime_str}, socket) do
    case parse_start_at(datetime_str) do
      {:ok, started_at} ->
        do_start_project(socket, started_at)

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("archive_project", _params, socket) do
    case Projects.archive_project(socket.assigns.project) do
      {:ok, project} ->
        Activity.log("projects.project_archived",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        {:noreply,
         assign(socket, project: project) |> put_flash(:info, gettext("Project archived."))}

      {:error, _} ->
        Activity.log_failed("projects.project_archived",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: socket.assigns.project.uuid,
          metadata: %{"name" => socket.assigns.project.name}
        )

        {:noreply, put_flash(socket, :error, gettext("Could not archive project."))}
    end
  end

  # Comments drawer. Opening sets `comments_resource` to the
  # `(type, uuid, title)` triple of the target so the drawer header
  # can show context and the embedded `CommentsComponent` is keyed
  # uniquely per resource. Closing clears the assign — the
  # component unmounts and any in-flight reply state is dropped
  # (intended: drawer-close is a "step away" affordance).
  def handle_event("open_comments", %{"type" => type, "uuid" => uuid} = params, socket)
      when type in ["project", "assignment"] do
    title = Map.get(params, "title", "")

    {:noreply, assign(socket, comments_resource: %{type: type, uuid: uuid, title: title})}
  end

  def handle_event("close_comments", _params, socket) do
    {:noreply, assign(socket, comments_resource: nil)}
  end

  # SortableGrid drop handler. Validates the new order against the
  # project's assignments, applies positions atomically, and pushes a
  # `sortable:flash` back so the dragged card flashes green/red. The
  # LV reload happens via the assignment_updated PubSub fan-out
  # triggered by the position writes — no explicit `load_assignments`
  # needed here.
  def handle_event("reorder_assignments", %{"ordered_ids" => ordered_ids} = params, socket)
      when is_list(ordered_ids) do
    moved_id = params["moved_id"]
    project_uuid = socket.assigns.project.uuid

    case Projects.reorder_assignments(project_uuid, ordered_ids,
           actor_uuid: Activity.actor_uuid(socket)
         ) do
      :ok ->
        {:noreply,
         socket
         |> push_event("sortable:flash", %{uuid: moved_id, status: "ok"})
         |> load_assignments()}

      {:error, :too_many_uuids} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Too many tasks to reorder at once."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_assignments()}

      {:error, :not_in_project} ->
        # Stale view — a concurrent change moved an assignment out of
        # this project. Snap back to the persisted state.
        {:noreply,
         socket
         |> put_flash(:error, gettext("Tasks have changed; please try again."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_assignments()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not reorder tasks."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_assignments()}
    end
  end

  def handle_event("unarchive_project", _params, socket) do
    case Projects.unarchive_project(socket.assigns.project) do
      {:ok, project} ->
        Activity.log("projects.project_unarchived",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        {:noreply,
         assign(socket, project: project) |> put_flash(:info, gettext("Project unarchived."))}

      {:error, _} ->
        Activity.log_failed("projects.project_unarchived",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: socket.assigns.project.uuid,
          metadata: %{"name" => socket.assigns.project.name}
        )

        {:noreply, put_flash(socket, :error, gettext("Could not unarchive project."))}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  # `<input type="datetime-local">` posts `YYYY-MM-DDTHH:mm` (no
  # seconds, no timezone). Treat as UTC — what the user typed is what
  # gets stored. Pad seconds when missing so `NaiveDateTime` accepts it.
  defp parse_start_at(value) when is_binary(value) do
    with_seconds = if String.length(value) == 16, do: value <> ":00", else: value

    case NaiveDateTime.from_iso8601(with_seconds) do
      {:ok, ndt} ->
        {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}

      {:error, _} ->
        {:error, gettext("Invalid date — please pick a valid date and time.")}
    end
  end

  defp parse_start_at(_),
    do: {:error, gettext("Invalid date — please pick a valid date and time.")}

  # True only when the `phoenix_kit_comments` module is loaded AND
  # admin-enabled. Off-by-default `enabled?/0` rescues any error
  # (missing tables, sandbox-down) and returns false, so this stays
  # safe in early-install or test environments.
  defp comments_available? do
    Code.ensure_loaded?(PhoenixKitComments) and PhoenixKitComments.enabled?()
  end

  # Refreshes both the project-level and per-assignment comment
  # counts. Called from mount + after `:comments_updated` so the
  # button badges stay in sync with reality. Cheap: project count is
  # one query, assignment counts are one batched query keyed by
  # uuid — no N+1 even with long timelines.
  defp load_comment_counts(socket) do
    if socket.assigns[:comments_enabled] do
      project_uuid = socket.assigns.project.uuid

      # Rescue narrowed to the shapes we actually expect: comments are
      # optional (UndefinedFunctionError when the module is absent
      # mid-install / mid-Hex-bump) and DB transients shouldn't break
      # the badge. Anything else surfaces and gets fixed.
      project_count =
        try do
          PhoenixKitComments.count_comments("project", project_uuid, status: "published")
        rescue
          UndefinedFunctionError -> 0
          Postgrex.Error -> 0
          DBConnection.OwnershipError -> 0
        catch
          :exit, _reason -> 0
        end

      assignment_uuids = Enum.map(socket.assigns.assignments, & &1.uuid)
      assignment_counts = Projects.comment_counts_for_assignments(assignment_uuids)

      assign(socket,
        project_comment_count: project_count,
        assignment_comment_counts: assignment_counts
      )
    else
      socket
    end
  end

  # Default value for `<input type="datetime-local">`: today at the
  # current hour:minute, formatted `YYYY-MM-DDTHH:mm` (the format the
  # browser expects). Built from UTC so the prefilled value matches
  # what'll be persisted when the user clicks Start without changing
  # anything.
  defp default_start_at_local do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601()
    |> String.slice(0, 16)
  end

  defp do_start_project(socket, started_at) do
    case Projects.start_project(socket.assigns.project, started_at) do
      {:ok, project} ->
        Activity.log("projects.project_started",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{
            "name" => project.name,
            "started_at" => DateTime.to_iso8601(started_at)
          }
        )

        {:noreply,
         socket
         |> assign(project: project, start_modal_open: false)
         |> put_flash(:info, gettext("Project started!"))}

      {:error, _} ->
        Activity.log_failed("projects.project_started",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: socket.assigns.project.uuid,
          metadata: %{
            "name" => socket.assigns.project.name,
            "started_at" => DateTime.to_iso8601(started_at)
          }
        )

        {:noreply, put_flash(socket, :error, gettext("Could not start project."))}
    end
  end

  defp parse_pct(pct_str) do
    case Integer.parse(pct_str) do
      {n, _} -> max(0, min(n, 100))
      :error -> 0
    end
  end

  defp progress_attrs(100, socket),
    do: %{
      progress_pct: 100,
      status: "done",
      completed_by_uuid: Activity.actor_uuid(socket),
      completed_at: DateTime.utc_now()
    }

  defp progress_attrs(0, _socket),
    do: %{progress_pct: 0, status: "todo", completed_by_uuid: nil, completed_at: nil}

  defp progress_attrs(pct, _socket),
    do: %{progress_pct: pct, status: "in_progress", completed_by_uuid: nil, completed_at: nil}

  defp progress_action(100, prev_status) when prev_status != "done",
    do: "projects.assignment_completed"

  defp progress_action(pct, "todo") when pct > 0, do: "projects.assignment_started"

  defp progress_action(0, prev_status) when prev_status != "todo",
    do: "projects.assignment_reopened"

  defp progress_action(_pct, _prev_status), do: "projects.assignment_progress_updated"

  defp do_update_progress(socket, a, pct) do
    attrs = progress_attrs(pct, socket)

    # Uses the server-trusted path because `progress_attrs/2` sets
    # `completed_by_uuid` / `completed_at` on the 100% and 0% branches.
    case Projects.update_assignment_status(a, attrs) do
      {:ok, _} ->
        Activity.log(progress_action(pct, a.status),
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: a.uuid,
          metadata: %{"task" => a.task.title, "progress_pct" => pct}
        )

        socket =
          if attrs.status != a.status, do: sync_project_completion(socket), else: socket

        {:noreply, load_assignments(socket)}

      {:error, cs} ->
        Activity.log_failed(progress_action(pct, a.status),
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: a.uuid,
          metadata: %{"task" => a.task.title, "progress_pct" => pct}
        )

        {:noreply,
         put_flash(socket, :error, error_summary(cs, gettext("Could not update progress.")))}
    end
  end

  defp assignee_label(a) do
    cond do
      a.assigned_person && a.assigned_person.user -> a.assigned_person.user.email
      a.assigned_team -> a.assigned_team.name
      a.assigned_department -> a.assigned_department.name
      true -> nil
    end
  end

  defp assignee_type(a) do
    cond do
      a.assigned_person_uuid -> gettext("Person")
      a.assigned_team_uuid -> gettext("Team")
      a.assigned_department_uuid -> gettext("Dept")
      true -> nil
    end
  end

  # ── Schedule calculation ─────────────────────────────────────────

  defp to_hours(n, unit, counts_weekends), do: TaskSchema.to_hours(n, unit, counts_weekends)

  defp task_counts_weekends?(a, project) do
    case a.counts_weekends do
      nil -> project.counts_weekends
      val -> val
    end
  end

  defp assignment_hours(a, project) do
    weekends? = task_counts_weekends?(a, project)

    if a.estimated_duration && a.estimated_duration_unit do
      to_hours(a.estimated_duration, a.estimated_duration_unit, weekends?)
    else
      to_hours(a.task.estimated_duration, a.task.estimated_duration_unit, weekends?)
    end
  end

  defp calculate_schedule(%{started_at: nil}, _), do: nil
  defp calculate_schedule(_project, []), do: nil

  defp calculate_schedule(project, assignments) do
    {total_hours, effective_done} = sum_hours(project, assignments)

    if total_hours == 0 do
      nil
    else
      build_schedule(project, total_hours, effective_done)
    end
  end

  defp sum_hours(project, assignments) do
    {total, done, progress} =
      Enum.reduce(assignments, {0, 0, 0}, fn a, {total, done, progress} ->
        accumulate_hours(a, project, total, done, progress)
      end)

    {total, done + progress}
  end

  defp accumulate_hours(%{status: "done"} = a, project, total, done, progress) do
    hours = assignment_hours(a, project)
    {total + hours, done + hours, progress}
  end

  defp accumulate_hours(
         %{track_progress: true, progress_pct: pct} = a,
         project,
         total,
         done,
         progress
       )
       when pct > 0 do
    hours = assignment_hours(a, project)
    {total + hours, done, progress + hours * pct / 100}
  end

  defp accumulate_hours(a, project, total, done, progress) do
    {total + assignment_hours(a, project), done, progress}
  end

  defp build_schedule(project, total_hours, effective_done) do
    now = DateTime.utc_now()
    calendar_hours = DateTime.diff(now, project.started_at, :second) / 3600
    # `planned_end_for/2` honors `counts_weekends`: for weekday-only
    # projects weekend days don't consume the work budget. We keep it
    # internal (drives the overdue/expected math) — it isn't displayed
    # to the user; the started-at date + the per-row durations + the
    # ETA below already tell the same story.
    planned_end = Project.planned_end_for(project, total_hours)
    remaining_hours = max(total_hours - effective_done, 0)
    past_planned_end? = DateTime.compare(now, planned_end) == :gt
    done? = remaining_hours <= 0

    # Planned-elapsed = work hours under the project's schedule rules.
    planned_elapsed_hours =
      if project.counts_weekends,
        do: calendar_hours,
        else: work_hours_elapsed(project.started_at, now)

    # Cap expected at 100% once calendar time has blown past the
    # planned end. Otherwise a project with all weekends elapsed and a
    # short total can report "0% expected" — which then makes a 0%-done
    # project look "on time" instead of overdue.
    raw_expected_pct = planned_elapsed_hours / total_hours * 100

    expected_pct =
      if past_planned_end? and not done? do
        100.0
      else
        min(raw_expected_pct, 100)
      end

    # Cap defensively: nothing rendered should exceed 100% even if
    # `effective_done` somehow drifts past `total_hours` (e.g. task
    # durations edited downward after work was logged).
    actual_pct = min(effective_done / total_hours * 100, 100)
    delta_pct = actual_pct - expected_pct
    overdue? = past_planned_end? and not done?

    # When overdue, report calendar lateness ("1 day overdue") rather
    # than work-hours-equivalent — for a 52-minute task that's 2 days
    # late, "< 1 hour behind" reads as nearly-on-time, which is wrong.
    delta_label =
      if overdue? do
        delta_days(now, planned_end)
      else
        {v, u} = humanize_hours(abs(delta_pct / 100 * total_hours))
        "#{v} #{u}"
      end

    %{
      total_hours: total_hours,
      done_hours: effective_done,
      remaining_hours: remaining_hours,
      elapsed_hours: planned_elapsed_hours,
      expected_pct: round(expected_pct),
      actual_pct: round(actual_pct),
      delta_pct: round(delta_pct),
      ahead?: delta_pct >= 0 and not overdue?,
      overdue?: overdue?,
      delta_label: delta_label,
      projected_end: projected_end(project, now, remaining_hours)
    }
  end

  # ETA = "if work continues at the original pace from now, this is
  # when you'll finish". For completed projects, return the actual
  # completion time. For unfinished projects, anchor on `now` and walk
  # `remaining_hours` forward through the project's weekday/weekend
  # rules — same machinery `planned_end_for/2` uses, just with a
  # different start anchor (see `Project.eta_from/3`).
  defp projected_end(%{completed_at: %DateTime{} = at}, _now, _remaining), do: at
  defp projected_end(_project, now, remaining) when remaining <= 0, do: now
  defp projected_end(project, now, remaining), do: Project.eta_from(project, now, remaining)

  # Mirrors `Project.planned_end_for/2`'s weekday-only model: each
  # weekday's calendar time contributes work hours at the 3:1 ratio
  # (24 calendar hours = 8 work hours); weekend days contribute zero.
  # Walks the calendar day-by-day clipping the start/end days.
  defp work_hours_elapsed(%DateTime{} = from, %DateTime{} = to) do
    if DateTime.compare(from, to) != :lt do
      0
    else
      sum_weekday_calendar_hours(from, to) / 3.0
    end
  end

  defp sum_weekday_calendar_hours(from, to) do
    from_date = DateTime.to_date(from)
    to_date = DateTime.to_date(to)

    Date.range(from_date, to_date)
    |> Enum.reduce(0.0, fn date, acc ->
      if Date.day_of_week(date) <= 5 do
        acc + weekday_calendar_hours_on(date, from, to)
      else
        acc
      end
    end)
  end

  defp weekday_calendar_hours_on(date, from, to) do
    sod = DateTime.new!(date, ~T[00:00:00.000], from.time_zone)
    eod = DateTime.new!(date, ~T[23:59:59.999], from.time_zone)

    window_start = if DateTime.compare(from, sod) == :gt, do: from, else: sod
    window_end = if DateTime.compare(to, eod) == :lt, do: to, else: eod

    if DateTime.compare(window_start, window_end) == :lt do
      DateTime.diff(window_end, window_start, :second) / 3600
    else
      0
    end
  end

  defp delta_days(later, earlier) do
    seconds = DateTime.diff(later, earlier, :second)
    hours = seconds / 3600
    days = hours / 24

    cond do
      hours < 1 -> gettext("< 1 hour")
      days < 1 -> ngettext("%{count} hour", "%{count} hours", round(hours))
      days < 2 -> gettext("1 day")
      days < 14 -> ngettext("%{count} day", "%{count} days", round(days))
      days < 60 -> gettext("%{n} weeks", n: Float.round(days / 7, 1))
      true -> gettext("%{n} months", n: Float.round(days / 30, 1))
    end
  end

  # Calendar-scale boundaries (1h, 24h, 7d, 30d) so unit transitions
  # land at intuitive points. Previously transitioned at 8h/40h which
  # came from "1 workday = 8h" and produced jarring jumps like
  # 7.9h → "8 hours", 8h → "1.0 days".
  defp humanize_hours(h) when h < 1, do: {gettext("< 1"), gettext("hour")}
  defp humanize_hours(h) when h < 24, do: {round(h), gettext("hours")}
  defp humanize_hours(h) when h < 24 * 7, do: {Float.round(h / 24, 1), gettext("days")}
  defp humanize_hours(h) when h < 24 * 30, do: {Float.round(h / (24 * 7), 1), gettext("weeks")}
  defp humanize_hours(h), do: {Float.round(h / (24 * 30), 1), gettext("months")}

  defp status_color("todo"), do: "bg-base-300"
  defp status_color("in_progress"), do: "bg-warning"
  defp status_color("done"), do: "bg-success"
  defp status_color(_), do: "bg-base-300"

  defp status_badge_class("todo"), do: "badge-ghost"
  defp status_badge_class("in_progress"), do: "badge-warning"
  defp status_badge_class("done"), do: "badge-success"
  defp status_badge_class(_), do: "badge-ghost"

  defp status_label("todo"), do: gettext("todo")
  defp status_label("in_progress"), do: gettext("in progress")
  defp status_label("done"), do: gettext("done")
  defp status_label(other), do: other

  defp format_duration(a) do
    dur = a.estimated_duration
    unit = a.estimated_duration_unit

    if dur && unit do
      TaskSchema.format_duration(dur, unit)
    else
      TaskSchema.format_duration(a.task.estimated_duration, a.task.estimated_duration_unit)
    end
  end

  defp duration_unit_options do
    [
      {gettext("Minutes"), "minutes"},
      {gettext("Hours"), "hours"},
      {gettext("Days"), "days"},
      {gettext("Weeks"), "weeks"},
      {gettext("Fortnights"), "fortnights"},
      {gettext("Months"), "months"},
      {gettext("Years"), "years"}
    ]
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <%!-- Header --%>
      <div>
        <.link navigate={if @is_template, do: Paths.templates(), else: Paths.projects()} class="link link-hover text-sm">
          <.icon name="hero-arrow-left" class="w-4 h-4 inline" />
          {if @is_template, do: gettext("Templates"), else: gettext("Projects")}
        </.link>
        <div class="flex items-center justify-between mt-1">
          <div class="flex items-center gap-2">
            <h1 class="text-2xl font-bold">{Project.localized_name(@project, L10n.current_content_lang())}</h1>
            <%= if @is_template do %>
              <span class="badge badge-info badge-sm">{gettext("Template")}</span>
            <% end %>
            <%= if @project.completed_at do %>
              <span class="badge badge-success gap-1">
                <.icon name="hero-check-circle" class="w-3.5 h-3.5" /> {gettext("Completed")}
              </span>
            <% end %>
            <%= if @project.archived_at do %>
              <span class="badge badge-ghost gap-1">
                <.icon name="hero-archive-box" class="w-3.5 h-3.5" /> {gettext("Archived")}
              </span>
            <% end %>
          </div>
          <div class="flex gap-2">
            <.link navigate={Paths.new_assignment(@project.uuid)} class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add task")}
            </.link>
            <button
              :if={@comments_enabled}
              type="button"
              phx-click="open_comments"
              phx-value-type="project"
              phx-value-uuid={@project.uuid}
              phx-value-title={Project.localized_name(@project, L10n.current_content_lang())}
              class="btn btn-ghost btn-sm gap-1"
              title={gettext("Open project comments")}
            >
              <.icon name="hero-chat-bubble-left-right" class="w-4 h-4" /> {gettext("Comments")}
              <span :if={@project_comment_count > 0} class="badge badge-sm badge-primary">
                {@project_comment_count}
              </span>
            </button>
            <.link
              navigate={if @is_template, do: Paths.edit_template(@project.uuid), else: Paths.edit_project(@project.uuid)}
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-pencil" class="w-4 h-4" /> {gettext("Edit")}
            </.link>
            <%= if not @is_template do %>
              <%= if @project.archived_at do %>
                <button
                  type="button"
                  phx-click="unarchive_project"
                  phx-disable-with={gettext("Unarchiving…")}
                  class="btn btn-ghost btn-sm"
                  title={gettext("Restore from archive")}
                >
                  <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> {gettext("Unarchive")}
                </button>
              <% else %>
                <button
                  type="button"
                  phx-click="archive_project"
                  phx-disable-with={gettext("Archiving…")}
                  data-confirm={gettext("Archive this project? It will be hidden from the main lists but kept in the database.")}
                  class="btn btn-ghost btn-sm"
                  title={gettext("Hide from main lists")}
                >
                  <.icon name="hero-archive-box" class="w-4 h-4" /> {gettext("Archive")}
                </button>
              <% end %>
            <% end %>
          </div>
        </div>
        <% desc = Project.localized_description(@project, L10n.current_content_lang()) %>
        <div :if={desc} class="text-sm text-base-content/60 mt-1">
          {desc}
        </div>
      </div>

      <%!-- Start mode / template bar --%>
      <div class="flex flex-wrap items-center gap-3 bg-base-200 rounded-lg px-4 py-3">
        <%= cond do %>
          <% @is_template -> %>
            <.icon name="hero-document-duplicate" class="w-5 h-5 text-info" />
            <span class="text-sm">{gettext("This is a template — set up tasks, then create projects from it.")}</span>
            <.link navigate={Paths.new_project() <> "?template=#{@project.uuid}"} class="btn btn-primary btn-xs ml-auto">
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Create project from this template")}
            </.link>
          <% @project.completed_at -> %>
            <.icon name="hero-trophy" class="w-5 h-5 text-success" />
            <span class="text-sm font-medium">
              {gettext("Completed %{when}", when: L10n.format_datetime(@project.completed_at))}
            </span>
            <%= if @project.started_at do %>
              <span class="text-base-content/40 mx-1">·</span>
              <span class="text-sm text-base-content/60">
                {gettext("took %{duration}", duration: delta_days(@project.completed_at, @project.started_at))}
              </span>
            <% end %>
          <% @project.started_at -> %>
            <.icon name="hero-play" class="w-5 h-5 text-success" />
            <span class="text-sm">
              {gettext("Started %{when}", when: L10n.format_datetime(@project.started_at))}
            </span>
            <%= if @schedule do %>
              <span class="text-base-content/40 mx-1">·</span>
              <%= cond do %>
                <% @schedule.overdue? -> %>
                  <span class="badge badge-error badge-sm gap-1">
                    <.icon name="hero-exclamation-triangle" class="w-3 h-3" />
                    {gettext("%{delta} overdue", delta: @schedule.delta_label)}
                  </span>
                <% @schedule.ahead? -> %>
                  <span class="badge badge-success badge-sm gap-1">
                    <.icon name="hero-arrow-trending-up" class="w-3 h-3" />
                    {gettext("%{delta} ahead", delta: @schedule.delta_label)}
                  </span>
                <% true -> %>
                  <span class="badge badge-error badge-sm gap-1">
                    <.icon name="hero-arrow-trending-down" class="w-3 h-3" />
                    {gettext("%{delta} behind", delta: @schedule.delta_label)}
                  </span>
              <% end %>
              <span class="text-xs text-base-content/50 ml-1">
                {gettext("(%{actual}% done vs %{expected}% expected)", actual: @schedule.actual_pct, expected: @schedule.expected_pct)}
              </span>
            <% end %>
          <% @project.start_mode == "scheduled" -> %>
            <.icon name="hero-calendar" class="w-5 h-5 text-info" />
            <span class="text-sm">
              {gettext("Scheduled for %{when}", when: L10n.format_datetime(@project.scheduled_start_date))}
            </span>
            <button
              type="button"
              phx-click="open_start_modal"
              class="btn btn-success btn-xs ml-auto"
            >
              {gettext("Start now")}
            </button>
          <% true -> %>
            <.icon name="hero-clock" class="w-5 h-5 text-warning" />
            <span class="text-sm">{gettext("Not started — set up tasks, then start")}</span>
            <button
              type="button"
              phx-click="open_start_modal"
              class="btn btn-success btn-xs ml-auto"
            >
              <.icon name="hero-play" class="w-4 h-4" /> {gettext("Start project")}
            </button>
        <% end %>
      </div>

      <%= if @project.started_at != nil and @schedule do %>
        <% {rem_v, rem_u} = humanize_hours(@schedule.remaining_hours) %>
        <div class="flex flex-wrap items-center gap-3 bg-base-200/50 rounded-lg px-4 py-2 text-xs">
          <%= if @project.completed_at do %>
            <div class="flex items-center gap-2">
              <.icon name="hero-check-circle" class="w-4 h-4 text-success" />
              <span class="text-base-content/60">{gettext("Finished:")}</span>
              <span class="font-medium">{L10n.format_datetime(@schedule.projected_end)}</span>
            </div>
          <% else %>
            <div class="flex items-center gap-2">
              <.icon name="hero-clock" class="w-4 h-4 text-base-content/60" />
              <span class="text-base-content/60">{gettext("Remaining:")}</span>
              <span class="font-medium">{rem_v} {rem_u}</span>
            </div>
            <span class="text-base-content/40">·</span>
            <div class="flex items-center gap-2">
              <.icon name="hero-arrow-trending-up" class={"w-4 h-4 #{if @schedule.ahead?, do: "text-success", else: "text-error"}"} />
              <span class="text-base-content/60">{gettext("ETA:")}</span>
              <span class={[
                "font-medium",
                @schedule.ahead? && "text-success",
                not @schedule.ahead? && "text-error"
              ]}>
                {L10n.format_datetime(@schedule.projected_end)}
              </span>
              <span class="text-base-content/40">{gettext("at planned pace")}</span>
            </div>
          <% end %>
        </div>
      <% end %>

      <%!-- Progress bar (not for templates) --%>
      <%= if @total_tasks > 0 and not @is_template do %>
        <div class="flex items-center gap-3">
          <div class="flex-1">
            <div class="w-full bg-base-300 rounded-full h-2">
              <div
                class="bg-success h-2 rounded-full transition-all duration-300"
                style={"width: #{@progress_pct}%"}
              >
              </div>
            </div>
          </div>
          <span class="text-sm text-base-content/60 shrink-0">
            {gettext("%{done}/%{total} done", done: @done_tasks, total: @total_tasks)}
          </span>
        </div>
      <% end %>

      <%!-- Timeline --%>
      <%= if @assignments == [] do %>
        <.empty_state icon="hero-rectangle-stack" title={gettext("No tasks in this project yet.")}>
          <:cta>
            <.link navigate={Paths.new_assignment(@project.uuid)} class="link link-primary text-sm">
              {gettext("Add one from the task library")}
            </.link>
          </:cta>
        </.empty_state>
      <% else %>
        <div class="relative">
          <%!-- Vertical connector line --%>
          <div class="absolute left-5 top-0 bottom-0 w-0.5 bg-base-300"></div>

          <%!-- SortableGrid hook lives on the inner flex container —
               the absolute-positioned vertical line is a sibling
               outside it so it doesn't get included in the sortable
               item set. The drag handle on each card's title row is
               the only initiator (`.pk-drag-handle`), so clicks
               anywhere else on the card still trigger the existing
               status / duration / dep handlers. --%>
          <div
            id="project-show-timeline"
            class="flex flex-col gap-0"
            phx-hook="SortableGrid"
            data-sortable="true"
            data-sortable-event="reorder_assignments"
            data-sortable-items=".sortable-item"
            data-sortable-handle=".pk-drag-handle"
          >
            <%= for {a, idx} <- Enum.with_index(@assignments) do %>
              <div class="relative flex gap-4 py-3 sortable-item" data-id={a.uuid}>
                <%!-- Status dot on the timeline --%>
                <div class="relative z-10 shrink-0 flex flex-col items-center">
                  <div class={"w-10 h-10 rounded-full flex items-center justify-center text-white text-xs font-bold #{status_color(a.status)}"}>
                    <%= if a.status == "done" do %>
                      <.icon name="hero-check" class="w-5 h-5" />
                    <% else %>
                      {idx + 1}
                    <% end %>
                  </div>
                </div>

                <%!-- Card --%>
                <div class={"flex-1 card bg-base-100 shadow-sm border #{if not @is_template and a.status == "done", do: "border-success/30 opacity-75", else: "border-base-200"}"}>
                  <div class="card-body py-3 px-4 gap-2">
                    <%!-- Title row --%>
                    <div class="flex items-center justify-between gap-2">
                      <div class="flex items-center gap-2 min-w-0">
                        <span class="pk-drag-handle cursor-grab text-base-content/40 hover:text-base-content shrink-0" title={gettext("Drag to reorder")}>
                          <.icon name="hero-bars-3" class="w-4 h-4" />
                        </span>
                        <span :if={not @is_template} class={"badge badge-sm #{status_badge_class(a.status)}"}>{status_label(a.status)}</span>
                        <span class="font-medium truncate">{TaskSchema.localized_title(a.task, L10n.current_content_lang())}</span>
                      </div>

                      <div class="flex items-center gap-1 shrink-0">
                        <%= if not @is_template do %>
                          <%= cond do %>
                            <% a.status == "todo" -> %>
                              <button
                                phx-click="start_task"
                                phx-value-uuid={a.uuid}
                                phx-disable-with={gettext("Starting…")}
                                class="btn btn-warning btn-xs"
                              >
                                {gettext("Start")}
                              </button>
                            <% a.status == "in_progress" -> %>
                              <button
                                phx-click="complete"
                                phx-value-uuid={a.uuid}
                                phx-disable-with={gettext("Saving…")}
                                class="btn btn-success btn-xs"
                              >
                                <.icon name="hero-check" class="w-3.5 h-3.5" /> {gettext("Done")}
                              </button>
                            <% a.status == "done" -> %>
                              <button
                                phx-click="reopen"
                                phx-value-uuid={a.uuid}
                                phx-disable-with={gettext("Reopening…")}
                                class="btn btn-ghost btn-xs"
                              >
                                {gettext("Reopen")}
                              </button>
                          <% end %>
                        <% end %>

                        <% a_comment_count = Map.get(@assignment_comment_counts, a.uuid, 0) %>
                        <button
                          :if={@comments_enabled and not @is_template}
                          type="button"
                          phx-click="open_comments"
                          phx-value-type="assignment"
                          phx-value-uuid={a.uuid}
                          phx-value-title={TaskSchema.localized_title(a.task, L10n.current_content_lang())}
                          class="btn btn-ghost btn-xs gap-1"
                          title={gettext("Open comments")}
                        >
                          <.icon name="hero-chat-bubble-left" class="w-3.5 h-3.5" />
                          <span :if={a_comment_count > 0} class="badge badge-xs badge-primary">
                            {a_comment_count}
                          </span>
                        </button>
                        <.link navigate={Paths.edit_assignment(@project.uuid, a.uuid)} class="btn btn-ghost btn-xs">
                          <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                        </.link>
                        <button
                          phx-click="remove_assignment"
                          phx-value-uuid={a.uuid}
                          phx-disable-with={gettext("Removing…")}
                          data-confirm={gettext("Remove \"%{title}\"?", title: TaskSchema.localized_title(a.task, L10n.current_content_lang()))}
                          class="btn btn-ghost btn-xs text-error"
                        >
                          <.icon name="hero-trash" class="w-3.5 h-3.5" />
                        </button>
                      </div>
                    </div>

                    <%!-- Description --%>
                    <% lang = L10n.current_content_lang() %>
                    <% a_desc = Assignment.localized_description(a, lang) %>
                    <% t_desc = TaskSchema.localized_description(a.task, lang) %>
                    <% shown_desc = a_desc || t_desc %>
                    <div :if={shown_desc} class="text-xs text-base-content/60">
                      {shown_desc}
                    </div>

                    <%!-- Meta row: duration, assignee, completed by --%>
                    <div class="flex flex-wrap items-center gap-2 text-xs">
                      <%!-- Duration (clickable to edit) --%>
                      <%= if @editing_duration_uuid == a.uuid do %>
                        <%!-- Inline editor. All three controls (input,
                             select, buttons) need matching `*-xs`
                             modifiers — without `select-xs` daisyUI's
                             default select-md renders ~2x taller and the
                             row visually staggers.

                             The badge above renders `format_duration(a)`
                             which already falls back from the assignment
                             to its task template when the assignment
                             doesn't override. Mirror the same fallback
                             on the edit inputs — otherwise the user
                             opens the editor and sees blank fields,
                             which the boss correctly flagged as
                             inconsistent with the badge they just
                             clicked. --%>
                        <% prefill_dur = a.estimated_duration || a.task.estimated_duration %>
                        <% prefill_unit = a.estimated_duration_unit || a.task.estimated_duration_unit || "hours" %>
                        <form phx-submit="save_duration" class="flex items-center gap-1">
                          <input
                            type="number"
                            name="estimated_duration"
                            value={prefill_dur}
                            class="input input-xs w-16"
                            min="1"
                          />
                          <.select
                            name="estimated_duration_unit"
                            value={prefill_unit}
                            options={duration_unit_options()}
                            class="select-xs w-auto"
                          />
                          <button
                            type="submit"
                            phx-disable-with={gettext("Saving…")}
                            class="btn btn-success btn-xs"
                          >
                            <.icon name="hero-check" class="w-3 h-3" />
                          </button>
                          <button type="button" phx-click="cancel_edit_duration" class="btn btn-ghost btn-xs">
                            <.icon name="hero-x-mark" class="w-3 h-3" />
                          </button>
                        </form>
                      <% else %>
                        <% dur = format_duration(a) %>
                        <%= if dur != "—" do %>
                          <%!-- Explicit Tailwind hover utilities instead
                               of `hover:badge-primary` — daisyUI's class
                               composition collapses text-color to the
                               outline color, which on some themes is
                               near-white once the bg flips to primary.
                               Forcing bg + text + border together keeps
                               contrast theme-independent. --%>
                          <button
                            phx-click="edit_duration"
                            phx-value-uuid={a.uuid}
                            class="badge badge-outline badge-sm gap-1 cursor-pointer hover:bg-primary hover:text-primary-content hover:border-primary transition-colors"
                          >
                            <.icon name="hero-clock" class="w-3 h-3" />
                            {dur}
                          </button>
                        <% else %>
                          <button
                            phx-click="edit_duration"
                            phx-value-uuid={a.uuid}
                            class="badge badge-ghost badge-sm gap-1 cursor-pointer hover:bg-base-300 transition-colors"
                          >
                            <.icon name="hero-clock" class="w-3 h-3" /> {gettext("Set duration")}
                          </button>
                        <% end %>
                      <% end %>

                      <%!-- Assignee --%>
                      <% atype = assignee_type(a) %>
                      <% alabel = assignee_label(a) %>
                      <%= if atype do %>
                        <span class="badge badge-outline badge-sm gap-1">
                          <.icon name="hero-user" class="w-3 h-3" />
                          {atype}: {alabel}
                        </span>
                      <% end %>

                      <%!-- Weekends indicator --%>
                      <% weekends? = task_counts_weekends?(a, @project) %>
                      <span class={"badge badge-sm gap-1 #{if weekends?, do: "badge-info badge-outline", else: "badge-ghost"}"}>
                        <%= if weekends? do %>
                          <.icon name="hero-calendar" class="w-3 h-3" /> {gettext("incl. weekends")}
                        <% else %>
                          {gettext("weekdays only")}
                        <% end %>
                      </span>

                      <%!-- Progress tracking (optional) --%>
                      <%= if not @is_template do %>
                        <%= if a.track_progress do %>
                          <.form
                            for={%{}}
                            phx-change="update_progress"
                            class="flex items-center gap-1"
                          >
                            <input type="hidden" name="uuid" value={a.uuid} />
                            <input
                              type="range"
                              name="progress_pct"
                              value={a.progress_pct}
                              min="0"
                              max="100"
                              step="5"
                              phx-debounce="300"
                              class="range range-xs range-primary w-20"
                            />
                            <span class="text-xs text-base-content/60 w-8">{a.progress_pct}%</span>
                            <button
                              type="button"
                              phx-click="toggle_tracking"
                              phx-value-uuid={a.uuid}
                              phx-disable-with={gettext("Saving…")}
                              title={gettext("Disable percentage tracking")}
                              class="btn btn-ghost btn-xs btn-circle"
                            >
                              <.icon name="hero-x-mark" class="w-3 h-3" />
                            </button>
                          </.form>
                        <% else %>
                          <button
                            type="button"
                            phx-click="toggle_tracking"
                            phx-value-uuid={a.uuid}
                            phx-disable-with={gettext("Saving…")}
                            class="badge badge-ghost badge-sm gap-1 cursor-pointer hover:badge-primary"
                            title={gettext("Track progress as a percentage")}
                          >
                            <.icon name="hero-chart-bar" class="w-3 h-3" /> {gettext("Track %")}
                          </button>
                        <% end %>
                      <% end %>

                      <%!-- Completed by --%>
                      <%= if a.completed_by do %>
                        <span class="badge badge-success badge-sm gap-1">
                          <.icon name="hero-check-circle" class="w-3 h-3" />
                          {a.completed_by.email}
                          <%= if a.completed_at do %>
                            · {L10n.format_month_day_time(a.completed_at)}
                          <% end %>
                        </span>
                      <% end %>
                    </div>

                    <%!-- Dependencies --%>
                    <% deps = Map.get(@deps_by_assignment, a.uuid, []) %>
                    <%= if deps != [] do %>
                      <div class="flex flex-wrap gap-1 mt-1">
                        <%= for dep <- deps do %>
                          <span class="badge badge-outline badge-xs gap-1">
                            <.icon name="hero-arrow-right-circle" class="w-3 h-3" />
                            {gettext("depends on:")} {TaskSchema.localized_title(dep.depends_on.task, L10n.current_content_lang())}
                            <button
                              phx-click="remove_dependency"
                              phx-value-assignment={a.uuid}
                              phx-value-depends_on={dep.depends_on_uuid}
                              phx-disable-with={gettext("Removing…")}
                              class="hover:text-error"
                            >
                              <.icon name="hero-x-mark" class="w-3 h-3" />
                            </button>
                          </span>
                        <% end %>
                      </div>
                    <% end %>

                  </div>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <%!-- Start-project modal — date editable so the user can backdate
           an already-running project or queue a future start. The
           form's `phx-change="noop"` prevents the LV from rebuilding
           the changeset on each keystroke (no live validation needed
           for a single date input); submit goes via `phx-submit`. --%>
      <%= if @start_modal_open do %>
        <dialog open class="modal modal-open" phx-window-keydown="close_start_modal" phx-key="Escape">
          <div class="modal-box max-w-md">
            <h3 class="font-bold text-lg">{gettext("Start project")}</h3>
            <p class="text-sm text-base-content/70 mt-1">
              {gettext("Pick the date and time this project starts. Defaults to right now; backdate it if work began earlier, or pick a future moment if you're queueing it up.")}
            </p>

            <.form for={@start_form} phx-submit="confirm_start_project" class="flex flex-col gap-3 mt-4">
              <.input field={@start_form[:start_at]} type="datetime-local" label={gettext("Start date and time")} required />

              <div class="modal-action">
                <button
                  type="button"
                  phx-click="close_start_modal"
                  class="btn btn-ghost btn-sm"
                >
                  {gettext("Cancel")}
                </button>
                <button
                  type="submit"
                  phx-disable-with={gettext("Starting…")}
                  class="btn btn-success btn-sm"
                >
                  <.icon name="hero-play" class="w-4 h-4" /> {gettext("Start project")}
                </button>
              </div>
            </.form>
          </div>
          <button type="button" phx-click="close_start_modal" class="modal-backdrop" aria-label={gettext("Close")}></button>
        </dialog>
      <% end %>

      <%!-- Slide-in comments drawer. Right-side fixed panel that
           hosts `PhoenixKitComments.Web.CommentsComponent` for either
           the project or one of its assignments. The component is
           keyed on `{type, uuid}` so opening a different resource
           re-mounts with its own state instead of leaking the
           previous resource's reply-in-progress / pagination.

           Esc + backdrop click both fire `close_comments`. The
           component's "comments_updated" message is unhandled here
           (we don't need to react to project-level comment counts
           in the timeline yet) — the catch-all `handle_info` clause
           logs it at debug and moves on. --%>
      <%!-- z-[60] / z-[70] so we paint over the admin header
           (`fixed top-0 z-50` in the layout wrapper). At z-40 the
           backdrop sat behind the header and looked broken. --%>
      <%= if @comments_resource do %>
        <div
          class="fixed inset-0 z-[60] bg-black/40"
          phx-click="close_comments"
          phx-window-keydown="close_comments"
          phx-key="Escape"
          aria-hidden="true"
        ></div>

        <aside
          class="fixed top-0 right-0 z-[70] h-screen w-full max-w-md bg-base-100 shadow-2xl flex flex-col"
          role="dialog"
          aria-modal="true"
          aria-label={gettext("Comments")}
        >
          <header class="flex items-start gap-2 p-4 border-b border-base-200 shrink-0">
            <div class="flex-1 min-w-0">
              <div class="text-xs uppercase tracking-wide text-base-content/60">
                <%= if @comments_resource.type == "project" do %>
                  {gettext("Project")}
                <% else %>
                  {gettext("Task")}
                <% end %>
              </div>
              <h2 class="font-bold text-lg truncate">{@comments_resource.title}</h2>
            </div>
            <button
              type="button"
              phx-click="close_comments"
              class="btn btn-ghost btn-sm btn-square"
              aria-label={gettext("Close")}
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </header>

          <div class="flex-1 min-h-0 overflow-y-auto p-4">
            <.live_component
              module={PhoenixKitComments.Web.CommentsComponent}
              id={"comments-drawer-#{@comments_resource.type}-#{@comments_resource.uuid}"}
              resource_type={@comments_resource.type}
              resource_uuid={@comments_resource.uuid}
              current_user={@phoenix_kit_current_scope && @phoenix_kit_current_scope.user}
              title=""
              show_likes={true}
            />
          </div>
        </aside>
      <% end %>
    </div>
    """
  end
end
