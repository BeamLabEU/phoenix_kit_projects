defmodule PhoenixKitProjects.Web.ProjectShowLive do
  @moduledoc """
  Show a project with a vertical timeline of assignments.
  Supports inline status changes, duration editing, dependency
  management, and tracks who completed each task.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitProjects.{Activity, L10n, Paths, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Task, as: TaskSchema

  require Logger

  @impl true
  def mount(%{"id" => id}, _session, socket) do
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

        {:ok,
         socket
         |> assign(
           page_title: project.name,
           project: project,
           is_template: is_template,
           editing_duration_uuid: nil,
           duration_form:
             to_form(%{"estimated_duration" => "", "estimated_duration_unit" => "hours"})
         )
         |> load_assignments()}
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
          "#{k}: #{translate_validator_error({msg, opts})}"
        end)
    end
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

      a ->
        {:noreply,
         assign(socket,
           editing_duration_uuid: uuid,
           duration_form:
             to_form(%{
               "estimated_duration" =>
                 (a.estimated_duration && to_string(a.estimated_duration)) || "",
               "estimated_duration_unit" => a.estimated_duration_unit || "hours"
             })
         )}
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
    with %{} <- scoped_assignment(socket, a_uuid),
         %{} <- scoped_assignment(socket, d_uuid),
         {:ok, _} <- Projects.remove_dependency(a_uuid, d_uuid) do
      Activity.log("projects.dependency_removed",
        actor_uuid: Activity.actor_uuid(socket),
        resource_type: "assignment",
        resource_uuid: a_uuid,
        target_uuid: d_uuid,
        metadata: %{}
      )

      {:noreply, load_assignments(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("start_project", _params, socket) do
    case Projects.start_project(socket.assigns.project) do
      {:ok, project} ->
        Activity.log("projects.project_started",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        {:noreply,
         assign(socket, project: project) |> put_flash(:info, gettext("Project started!"))}

      {:error, _} ->
        Activity.log_failed("projects.project_started",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: socket.assigns.project.uuid,
          metadata: %{"name" => socket.assigns.project.name}
        )

        {:noreply, put_flash(socket, :error, gettext("Could not start project."))}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

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

    # Planned-elapsed = work hours under the project's schedule rules.
    # Velocity-elapsed uses calendar time when weekend work has pulled us ahead.
    planned_elapsed_hours =
      if project.counts_weekends,
        do: calendar_hours,
        else: work_hours_elapsed(project.started_at, now)

    velocity_elapsed_hours =
      if effective_done > 0 and calendar_hours > planned_elapsed_hours,
        do: calendar_hours,
        else: planned_elapsed_hours

    expected_pct = min(planned_elapsed_hours / total_hours * 100, 100)
    actual_pct = effective_done / total_hours * 100
    delta_pct = actual_pct - expected_pct

    {delta_value, delta_unit} = humanize_hours(abs(delta_pct / 100 * total_hours))

    planned_end = DateTime.add(project.started_at, round(total_hours * 3600), :second)
    remaining_hours = max(total_hours - effective_done, 0)

    %{
      total_hours: total_hours,
      done_hours: effective_done,
      elapsed_hours: planned_elapsed_hours,
      expected_pct: round(expected_pct),
      actual_pct: round(actual_pct),
      delta_pct: round(delta_pct),
      ahead?: delta_pct >= 0,
      delta_label: "#{delta_value} #{delta_unit}",
      planned_end: planned_end,
      projected_end:
        projected_end(
          project,
          planned_end,
          remaining_hours,
          effective_done,
          velocity_elapsed_hours
        )
    }
  end

  defp projected_end(%{completed_at: %DateTime{} = at}, _, _, _, _), do: at
  defp projected_end(_, _, 0, _, _), do: DateTime.utc_now()
  defp projected_end(_, planned_end, _remaining, done, _) when done <= 0, do: planned_end

  defp projected_end(
         _project,
         _planned_end,
         remaining_hours,
         effective_done,
         velocity_elapsed_hours
       ) do
    safe_elapsed = max(velocity_elapsed_hours, 1)
    velocity = effective_done / safe_elapsed
    extra_seconds = round(remaining_hours / velocity * 3600)
    DateTime.add(DateTime.utc_now(), extra_seconds, :second)
  end

  defp work_hours_elapsed(from, to) do
    total_hours = DateTime.diff(to, from, :second) / 3600
    total_days = total_hours / 24
    full_weeks = trunc(total_days / 7)
    remaining_days = total_days - full_weeks * 7

    start_dow = Date.day_of_week(DateTime.to_date(from))

    weekend_days_in_remainder =
      Enum.count(0..trunc(remaining_days), fn d ->
        dow = rem(start_dow + d - 1, 7) + 1
        dow >= 6
      end)

    work_days = full_weeks * 5 + (remaining_days - weekend_days_in_remainder)
    max(work_days * 8, 0)
  end

  defp delta_days(later, earlier) do
    days = DateTime.diff(later, earlier, :second) / 86_400

    cond do
      days < 1 -> gettext("< 1 day")
      days < 2 -> gettext("1 day")
      days < 14 -> ngettext("%{count} day", "%{count} days", round(days))
      days < 60 -> gettext("%{n} weeks", n: Float.round(days / 7, 1))
      true -> gettext("%{n} months", n: Float.round(days / 30, 1))
    end
  end

  defp humanize_hours(h) when h < 1, do: {gettext("< 1"), gettext("hour")}
  defp humanize_hours(h) when h < 8, do: {round(h), gettext("hours")}
  defp humanize_hours(h) when h < 40, do: {Float.round(h / 8, 1), gettext("days")}
  defp humanize_hours(h) when h < 160, do: {Float.round(h / 40, 1), gettext("weeks")}
  defp humanize_hours(h), do: {Float.round(h / 160, 1), gettext("months")}

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
    <div class="flex flex-col mx-auto max-w-4xl px-4 py-6 gap-4">
      <%!-- Header --%>
      <div>
        <.link navigate={if @is_template, do: Paths.templates(), else: Paths.projects()} class="link link-hover text-sm">
          <.icon name="hero-arrow-left" class="w-4 h-4 inline" />
          {if @is_template, do: gettext("Templates"), else: gettext("Projects")}
        </.link>
        <div class="flex items-center justify-between mt-1">
          <div class="flex items-center gap-2">
            <h1 class="text-2xl font-bold">{@project.name}</h1>
            <%= if @is_template do %>
              <span class="badge badge-info badge-sm">{gettext("Template")}</span>
            <% end %>
            <%= if @project.completed_at do %>
              <span class="badge badge-success gap-1">
                <.icon name="hero-check-circle" class="w-3.5 h-3.5" /> {gettext("Completed")}
              </span>
            <% end %>
          </div>
          <div class="flex gap-2">
            <.link navigate={Paths.new_assignment(@project.uuid)} class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add task")}
            </.link>
            <.link
              navigate={if @is_template, do: Paths.edit_template(@project.uuid), else: Paths.edit_project(@project.uuid)}
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-pencil" class="w-4 h-4" /> {gettext("Edit")}
            </.link>
          </div>
        </div>
        <div :if={@project.description} class="text-sm text-base-content/60 mt-1">
          {@project.description}
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
              <%= if @schedule.ahead? do %>
                <span class="badge badge-success badge-sm gap-1">
                  <.icon name="hero-arrow-trending-up" class="w-3 h-3" />
                  {gettext("%{delta} ahead", delta: @schedule.delta_label)}
                </span>
              <% else %>
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
              {gettext("Scheduled for %{date}", date: L10n.format_date(@project.scheduled_start_date))}
            </span>
            <button
              type="button"
              phx-click="start_project"
              phx-disable-with={gettext("Starting…")}
              class="btn btn-success btn-xs ml-auto"
            >
              {gettext("Start now")}
            </button>
          <% true -> %>
            <.icon name="hero-clock" class="w-5 h-5 text-warning" />
            <span class="text-sm">{gettext("Not started — set up tasks, then start")}</span>
            <button
              type="button"
              phx-click="start_project"
              phx-disable-with={gettext("Starting…")}
              data-confirm={gettext("Start this project now?")}
              class="btn btn-success btn-xs ml-auto"
            >
              <.icon name="hero-play" class="w-4 h-4" /> {gettext("Start project")}
            </button>
        <% end %>
      </div>

      <%= if @project.started_at != nil and @schedule do %>
        <% same_day = Date.compare(DateTime.to_date(@schedule.planned_end), DateTime.to_date(@schedule.projected_end)) == :eq %>
        <div class="flex flex-wrap items-center gap-4 bg-base-200/50 rounded-lg px-4 py-2 text-xs">
          <div class="flex items-center gap-2">
            <.icon name="hero-flag" class="w-4 h-4 text-base-content/60" />
            <span class="text-base-content/60">{gettext("Planned:")}</span>
            <span class="font-medium">{L10n.format_date(@schedule.planned_end)}</span>
          </div>
          <div class="flex items-center gap-2">
            <.icon name="hero-arrow-trending-up" class={"w-4 h-4 #{if @schedule.ahead?, do: "text-success", else: "text-error"}"} />
            <span class="text-base-content/60">
              <%= if @project.completed_at, do: gettext("Finished:"), else: gettext("Projected:") %>
            </span>
            <span class={[
              "font-medium",
              not same_day && @schedule.ahead? && "text-success",
              not same_day && not @schedule.ahead? && "text-error"
            ]}>
              {L10n.format_date(@schedule.projected_end)}
            </span>
            <%= cond do %>
              <% same_day -> %>
                <span class="text-base-content/40">{gettext("(on track)")}</span>
              <% @schedule.ahead? -> %>
                <span class="text-success">{gettext("(%{delta} earlier)", delta: delta_days(@schedule.planned_end, @schedule.projected_end))}</span>
              <% true -> %>
                <span class="text-error">{gettext("(%{delta} later)", delta: delta_days(@schedule.projected_end, @schedule.planned_end))}</span>
            <% end %>
          </div>
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
        <div class="text-center py-16 text-base-content/60">
          <.icon name="hero-rectangle-stack" class="w-12 h-12 mx-auto mb-2 opacity-40" />
          <p>{gettext("No tasks in this project yet.")}</p>
          <.link navigate={Paths.new_assignment(@project.uuid)} class="link link-primary text-sm">
            {gettext("Add one from the task library")}
          </.link>
        </div>
      <% else %>
        <div class="relative">
          <%!-- Vertical connector line --%>
          <div class="absolute left-5 top-0 bottom-0 w-0.5 bg-base-300"></div>

          <div class="flex flex-col gap-0">
            <%= for {a, idx} <- Enum.with_index(@assignments) do %>
              <div class="relative flex gap-4 py-3">
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
                        <span :if={not @is_template} class={"badge badge-sm #{status_badge_class(a.status)}"}>{status_label(a.status)}</span>
                        <span class="font-medium truncate">{a.task.title}</span>
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

                        <.link navigate={Paths.edit_assignment(@project.uuid, a.uuid)} class="btn btn-ghost btn-xs">
                          <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                        </.link>
                        <button
                          phx-click="remove_assignment"
                          phx-value-uuid={a.uuid}
                          phx-disable-with={gettext("Removing…")}
                          data-confirm={gettext("Remove \"%{title}\"?", title: a.task.title)}
                          class="btn btn-ghost btn-xs text-error"
                        >
                          <.icon name="hero-trash" class="w-3.5 h-3.5" />
                        </button>
                      </div>
                    </div>

                    <%!-- Description --%>
                    <div :if={a.description || a.task.description} class="text-xs text-base-content/60">
                      {a.description || a.task.description}
                    </div>

                    <%!-- Meta row: duration, assignee, completed by --%>
                    <div class="flex flex-wrap items-center gap-2 text-xs">
                      <%!-- Duration (clickable to edit) --%>
                      <%= if @editing_duration_uuid == a.uuid do %>
                        <.form for={@duration_form} phx-submit="save_duration" class="flex items-center gap-1">
                          <input
                            type="number"
                            name="estimated_duration"
                            value={@duration_form[:estimated_duration].value}
                            class="input input-xs w-16"
                            min="1"
                          />
                          <.select
                            name="estimated_duration_unit"
                            value={@duration_form[:estimated_duration_unit].value}
                            options={duration_unit_options()}
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
                        </.form>
                      <% else %>
                        <% dur = format_duration(a) %>
                        <%= if dur != "—" do %>
                          <button
                            phx-click="edit_duration"
                            phx-value-uuid={a.uuid}
                            class="badge badge-outline badge-sm gap-1 cursor-pointer hover:badge-primary"
                          >
                            <.icon name="hero-clock" class="w-3 h-3" />
                            {dur}
                          </button>
                        <% else %>
                          <button
                            phx-click="edit_duration"
                            phx-value-uuid={a.uuid}
                            class="badge badge-ghost badge-sm gap-1 cursor-pointer"
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
                            {gettext("depends on:")} {dep.depends_on.task.title}
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
    </div>
    """
  end
end
