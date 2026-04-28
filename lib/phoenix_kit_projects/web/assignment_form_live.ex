defmodule PhoenixKitProjects.Web.AssignmentFormLive do
  @moduledoc """
  Add a task to a project or edit an existing assignment.
  Supports picking from library or creating new. Manages assignment
  dependencies (which tasks in this project must finish first).
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKitProjects.{Activity, Paths, Projects}
  alias PhoenixKitProjects.Schemas.Assignment

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, %{"project_id" => project_id}) do
    case Projects.get_project(project_id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Project not found."))
        |> push_navigate(to: Paths.projects())

      project ->
        assignment = %Assignment{project_uuid: project.uuid}

        socket
        |> assign(
          page_title: gettext("Add task to %{name}", name: project.name),
          project: project,
          assignment: assignment,
          live_action: :new,
          task_mode: "existing",
          assign_type: "",
          selected_task_uuid: nil,
          new_task_title: "",
          save_as_template: true,
          assignment_deps: [],
          available_assignment_deps: []
        )
        |> assign_options()
        |> assign_form(Projects.change_assignment(assignment))
    end
  end

  defp apply_action(socket, :edit, %{"project_id" => project_id, "id" => id}) do
    project = Projects.get_project(project_id)
    assignment = Projects.get_assignment(id)

    case {project, assignment} do
      {nil, _} ->
        socket
        |> put_flash(:error, gettext("Project not found."))
        |> push_navigate(to: Paths.projects())

      {_, nil} ->
        socket
        |> put_flash(:error, gettext("Assignment not found."))
        |> push_navigate(to: Paths.project(project_id))

      {project, assignment} ->
        assign_type =
          cond do
            assignment.assigned_person_uuid -> "person"
            assignment.assigned_team_uuid -> "team"
            assignment.assigned_department_uuid -> "department"
            true -> ""
          end

        socket
        |> assign(
          page_title: gettext("Edit assignment"),
          project: project,
          assignment: assignment,
          live_action: :edit,
          task_mode: "existing",
          assign_type: assign_type,
          selected_task_uuid: assignment.task_uuid,
          new_task_title: "",
          save_as_template: true,
          assignment_deps: Projects.list_dependencies(assignment.uuid),
          available_assignment_deps:
            Projects.available_dependencies(project.uuid, assignment.uuid)
        )
        |> assign_options()
        |> assign_form(Projects.change_assignment(assignment))
    end
  end

  defp assign_options(socket) do
    assign(socket,
      task_options: Projects.list_tasks() |> Enum.map(&{&1.title, &1.uuid}),
      team_options: load_teams(),
      department_options: load_departments(),
      person_options: load_people()
    )
  end

  defp load_teams do
    PhoenixKitStaff.Teams.list() |> Enum.map(&{"#{&1.name} (#{&1.department.name})", &1.uuid})
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Projects] load_teams failed: #{Exception.message(e)}")
      []
  end

  defp load_departments do
    PhoenixKitStaff.Departments.list() |> Enum.map(&{&1.name, &1.uuid})
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Projects] load_departments failed: #{Exception.message(e)}")
      []
  end

  defp load_people do
    PhoenixKitStaff.Staff.list_people()
    |> Enum.map(&{(&1.user && &1.user.email) || "—", &1.uuid})
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Projects] load_people failed: #{Exception.message(e)}")
      []
  end

  defp assign_form(socket, cs), do: assign(socket, form: to_form(cs))

  # ── Validate ────────────────────────────────────────────────────

  @impl true
  def handle_event("validate", %{"assignment" => attrs} = params, socket) do
    assign_type = Map.get(params, "assign_type", socket.assigns.assign_type)
    task_mode = Map.get(params, "task_mode", socket.assigns.task_mode)
    new_task_title = Map.get(params, "new_task_title", socket.assigns.new_task_title)
    save_as_template = Map.get(params, "save_as_template", "true") == "true"

    socket =
      if task_mode == "existing" && socket.assigns.live_action == :new do
        task_uuid = attrs["task_uuid"]

        if task_uuid != "" && task_uuid != socket.assigns.selected_task_uuid do
          prefill_from_template(socket, task_uuid, attrs)
        else
          cs =
            socket.assigns.assignment
            |> Projects.change_assignment(attrs)
            |> Map.put(:action, :validate)

          assign_form(socket, cs) |> assign(selected_task_uuid: task_uuid)
        end
      else
        cs =
          socket.assigns.assignment
          |> Projects.change_assignment(attrs)
          |> Map.put(:action, :validate)

        assign_form(socket, cs)
      end

    {:noreply,
     assign(socket,
       assign_type: assign_type,
       task_mode: task_mode,
       new_task_title: new_task_title,
       save_as_template: save_as_template
     )}
  end

  # ── Dependency management (edit mode) ───────────────────────────

  def handle_event("add_assignment_dep", %{"depends_on_uuid" => dep_uuid}, socket)
      when dep_uuid != "" do
    case Projects.add_dependency(socket.assigns.assignment.uuid, dep_uuid) do
      {:ok, _} ->
        Activity.log("projects.dependency_added",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: socket.assigns.assignment.uuid,
          target_uuid: dep_uuid,
          metadata: %{}
        )

        reload_deps(socket)

      {:error, _} ->
        Activity.log_failed("projects.dependency_added",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: socket.assigns.assignment.uuid,
          target_uuid: dep_uuid,
          metadata: %{}
        )

        {:noreply, put_flash(socket, :error, gettext("Could not add dependency."))}
    end
  end

  def handle_event("add_assignment_dep", _params, socket), do: {:noreply, socket}

  def handle_event("remove_assignment_dep", %{"uuid" => dep_uuid}, socket) do
    case Projects.remove_dependency(socket.assigns.assignment.uuid, dep_uuid) do
      {:ok, _} ->
        Activity.log("projects.dependency_removed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: socket.assigns.assignment.uuid,
          target_uuid: dep_uuid,
          metadata: %{}
        )

        reload_deps(socket)

      {:error, _} ->
        Activity.log_failed("projects.dependency_removed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: socket.assigns.assignment.uuid,
          target_uuid: dep_uuid,
          metadata: %{}
        )

        {:noreply, put_flash(socket, :error, gettext("Could not remove dependency."))}
    end
  end

  # ── Save ────────────────────────────────────────────────────────

  def handle_event("save", %{"assignment" => attrs} = params, socket) do
    assign_type = Map.get(params, "assign_type", "")
    task_mode = Map.get(params, "task_mode", "existing")
    attrs = clear_other_assignees(attrs, assign_type)

    case {socket.assigns.live_action, task_mode} do
      {:new, "new"} -> save_with_new_task(socket, attrs, params)
      {:new, _} -> save_new(socket, attrs)
      {:edit, _} -> save_edit(socket, attrs)
    end
  end

  defp save_with_new_task(socket, attrs, params) do
    case params |> Map.get("new_task_title", "") |> String.trim() do
      "" -> {:noreply, put_flash(socket, :error, gettext("Task title is required."))}
      title -> create_task_and_assign(socket, attrs, title)
    end
  end

  defp create_task_and_assign(socket, attrs, title) do
    task_attrs =
      %{
        "title" => title,
        "description" => attrs["description"],
        "estimated_duration" => attrs["estimated_duration"],
        "estimated_duration_unit" => attrs["estimated_duration_unit"]
      }
      |> maybe_add_default_assignee(attrs)

    case Projects.create_task(task_attrs) do
      {:ok, task} ->
        create_assignment_for_new_task(socket, attrs, task, title)

      {:error, _cs} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not create task. Title may already exist."))}
    end
  end

  defp create_assignment_for_new_task(socket, attrs, task, title) do
    assignment_attrs =
      attrs
      |> Map.put("task_uuid", task.uuid)
      |> Map.put("project_uuid", socket.assigns.project.uuid)

    case Projects.create_assignment(assignment_attrs) do
      {:ok, assignment} ->
        {flash_kind, flash_msg} =
          flash_for_template_deps(
            assignment,
            gettext("Task created and added to project.")
          )

        Activity.log("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: assignment.uuid,
          metadata: %{"project" => socket.assigns.project.name, "new_task" => title}
        )

        {:noreply,
         socket
         |> put_flash(flash_kind, flash_msg)
         |> push_navigate(to: Paths.project(socket.assigns.project.uuid))}

      {:error, cs} ->
        {:noreply, assign_form(socket, cs)}
    end
  end

  defp maybe_add_default_assignee(task_attrs, attrs) do
    cond do
      attrs["assigned_team_uuid"] && attrs["assigned_team_uuid"] != "" ->
        Map.put(task_attrs, "default_assigned_team_uuid", attrs["assigned_team_uuid"])

      attrs["assigned_department_uuid"] && attrs["assigned_department_uuid"] != "" ->
        Map.put(task_attrs, "default_assigned_department_uuid", attrs["assigned_department_uuid"])

      attrs["assigned_person_uuid"] && attrs["assigned_person_uuid"] != "" ->
        Map.put(task_attrs, "default_assigned_person_uuid", attrs["assigned_person_uuid"])

      true ->
        task_attrs
    end
  end

  defp save_new(socket, attrs) do
    attrs = Map.put(attrs, "project_uuid", socket.assigns.project.uuid)

    case Projects.create_assignment(attrs) do
      {:ok, assignment} ->
        {flash_kind, flash_msg} =
          flash_for_template_deps(
            assignment,
            gettext("Task added to project.")
          )

        Activity.log("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: assignment.uuid,
          metadata: %{"project" => socket.assigns.project.name}
        )

        {:noreply,
         socket
         |> put_flash(flash_kind, flash_msg)
         |> push_navigate(to: Paths.project(socket.assigns.project.uuid))}

      {:error, cs} ->
        {:noreply, assign_form(socket, cs)}
    end
  end

  # Apply template-level default dependencies and return a flash tuple
  # describing what to show the user. A rollback in
  # `Projects.apply_template_dependencies/1` is *not* fatal — the
  # assignment itself was created successfully — but the user expected
  # default deps to land, so we surface a warning instead of the
  # success message.
  defp flash_for_template_deps(assignment, success_msg) do
    case Projects.apply_template_dependencies(assignment) do
      :ok ->
        {:info, success_msg}

      {:ok, _} ->
        {:info, success_msg}

      {:error, reason} ->
        Logger.warning(
          "[Projects] apply_template_dependencies/1 rolled back for assignment " <>
            "#{assignment.uuid}: #{inspect(reason)}"
        )

        {:warning,
         gettext(
           "Task added to project, but applying default dependencies from the template failed."
         )}
    end
  end

  defp save_edit(socket, attrs) do
    case Projects.update_assignment_form(socket.assigns.assignment, attrs) do
      {:ok, updated} ->
        Activity.log("projects.assignment_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: updated.uuid,
          metadata: %{"project" => socket.assigns.project.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Assignment updated."))
         |> push_navigate(to: Paths.project(socket.assigns.project.uuid))}

      {:error, cs} ->
        {:noreply, assign_form(socket, cs)}
    end
  end

  defp clear_other_assignees(attrs, "team") do
    Map.merge(attrs, %{"assigned_department_uuid" => nil, "assigned_person_uuid" => nil})
  end

  defp clear_other_assignees(attrs, "department") do
    Map.merge(attrs, %{"assigned_team_uuid" => nil, "assigned_person_uuid" => nil})
  end

  defp clear_other_assignees(attrs, "person") do
    Map.merge(attrs, %{"assigned_team_uuid" => nil, "assigned_department_uuid" => nil})
  end

  defp clear_other_assignees(attrs, _) do
    Map.merge(attrs, %{
      "assigned_team_uuid" => nil,
      "assigned_department_uuid" => nil,
      "assigned_person_uuid" => nil
    })
  end

  defp prefill_from_template(socket, task_uuid, attrs) do
    case Projects.get_task(task_uuid) do
      nil ->
        cs =
          socket.assigns.assignment
          |> Projects.change_assignment(attrs)
          |> Map.put(:action, :validate)

        assign_form(socket, cs)

      task ->
        prefilled = %{
          "task_uuid" => task.uuid,
          "project_uuid" => socket.assigns.project.uuid,
          "description" => task.description,
          "estimated_duration" => task.estimated_duration && to_string(task.estimated_duration),
          "estimated_duration_unit" => task.estimated_duration_unit,
          "assigned_team_uuid" => task.default_assigned_team_uuid,
          "assigned_department_uuid" => task.default_assigned_department_uuid,
          "assigned_person_uuid" => task.default_assigned_person_uuid,
          "status" => attrs["status"] || "todo"
        }

        assign_type =
          cond do
            task.default_assigned_person_uuid -> "person"
            task.default_assigned_team_uuid -> "team"
            task.default_assigned_department_uuid -> "department"
            true -> socket.assigns.assign_type
          end

        cs = %Assignment{} |> Projects.change_assignment(prefilled) |> Map.put(:action, :validate)

        socket
        |> assign(assign_type: assign_type, selected_task_uuid: task_uuid)
        |> assign_form(cs)
    end
  end

  defp reload_deps(socket) do
    {:noreply,
     assign(socket,
       assignment_deps: Projects.list_dependencies(socket.assigns.assignment.uuid),
       available_assignment_deps:
         Projects.available_dependencies(
           socket.assigns.project.uuid,
           socket.assigns.assignment.uuid
         )
     )}
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-xl px-4 py-6 gap-4">
      <div>
        <.link navigate={Paths.project(@project.uuid)} class="link link-hover text-sm">
          <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {@project.name}
        </.link>
        <h1 class="text-2xl font-bold mt-1">{@page_title}</h1>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <.form for={@form} id="assignment-form" phx-change="validate" phx-submit="save" phx-debounce="300" class="flex flex-col gap-3">
            <%= if @live_action == :new do %>
              <.select
                name="task_mode"
                label={gettext("Task source")}
                value={@task_mode}
                options={[{gettext("Pick from library"), "existing"}, {gettext("Create new task"), "new"}]}
              />

              <%= if @task_mode == "existing" do %>
                <.select
                  field={@form[:task_uuid]}
                  label={gettext("Task template")}
                  options={@task_options}
                  prompt={gettext("Select task")}
                  required
                />
              <% else %>
                <.input name="new_task_title" label={gettext("Task title")} value={@new_task_title} required />
              <% end %>
            <% else %>
              <div class="text-sm text-base-content/60">
                {gettext("Task:")} <span class="font-medium">{@assignment.task && @assignment.task.title}</span>
              </div>
            <% end %>

            <div class="divider text-xs text-base-content/50 my-1">{gettext("Details")}</div>

            <.textarea field={@form[:description]} label={gettext("Description")} />

            <div class="flex gap-2">
              <div class="flex-1">
                <.input field={@form[:estimated_duration]} label={gettext("Duration")} type="number" />
              </div>
              <div class="w-40">
                <.select
                  field={@form[:estimated_duration_unit]}
                  label={gettext("Unit")}
                  options={duration_unit_options()}
                  prompt={gettext("—")}
                />
              </div>
            </div>

            <.select
              field={@form[:status]}
              label={gettext("Status")}
              options={[{gettext("To do"), "todo"}, {gettext("In progress"), "in_progress"}, {gettext("Done"), "done"}]}
            />

            <label class="flex items-center gap-2 cursor-pointer">
              <input type="hidden" name={@form[:counts_weekends].name} value="" />
              <input
                type="checkbox"
                name={@form[:counts_weekends].name}
                value="true"
                checked={@form[:counts_weekends].value == true or @form[:counts_weekends].value == "true"}
                class="checkbox checkbox-sm"
              />
              <span class="text-sm">{gettext("Counts weekends (e.g. deliveries, external processes)")}</span>
            </label>

            <div class="divider text-xs text-base-content/50 my-1">{gettext("Assignment (optional)")}</div>

            <.select
              name="assign_type"
              label={gettext("Assign to")}
              value={@assign_type}
              options={[{gettext("Nobody"), ""}, {gettext("Department"), "department"}, {gettext("Team"), "team"}, {gettext("Person"), "person"}]}
            />

            <%= if @assign_type == "department" do %>
              <.select field={@form[:assigned_department_uuid]} label={gettext("Department")} options={@department_options} prompt={gettext("Select department")} />
            <% end %>
            <%= if @assign_type == "team" do %>
              <.select field={@form[:assigned_team_uuid]} label={gettext("Team")} options={@team_options} prompt={gettext("Select team")} />
            <% end %>
            <%= if @assign_type == "person" do %>
              <.select field={@form[:assigned_person_uuid]} label={gettext("Person")} options={@person_options} prompt={gettext("Select person")} />
            <% end %>

            <%= if @live_action == :new and @task_mode == "new" do %>
              <div class="divider my-1"></div>
              <label class="flex items-center gap-2 cursor-pointer">
                <input type="checkbox" name="save_as_template" value="true" checked={@save_as_template} class="checkbox checkbox-sm" />
                <span class="text-sm">{gettext("Save as reusable template in the task library")}</span>
              </label>
            <% end %>

            <div class="flex justify-end gap-2 mt-2">
              <.link navigate={Paths.project(@project.uuid)} class="btn btn-ghost btn-sm">{gettext("Cancel")}</.link>
              <button type="submit" phx-disable-with={gettext("Saving…")} class="btn btn-primary btn-sm">
                <%= if @live_action == :new, do: gettext("Add"), else: gettext("Save") %>
              </button>
            </div>
          </.form>
        </div>
      </div>

      <%!-- Dependencies (edit mode only — assignment must exist first) --%>
      <%= if @live_action == :edit do %>
        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title text-lg">{gettext("Dependencies")}</h2>
            <p class="text-xs text-base-content/60">
              {gettext("Tasks in this project that must finish before this one can start.")}
            </p>

            <%= if @assignment_deps != [] do %>
              <div class="flex flex-wrap gap-2 mt-2">
                <%= for dep <- @assignment_deps do %>
                  <span class="badge badge-outline gap-1">
                    <.icon name="hero-arrow-right-circle" class="w-3 h-3" />
                    {dep.depends_on.task.title}
                    <button
                      type="button"
                      phx-click="remove_assignment_dep"
                      phx-value-uuid={dep.depends_on_uuid}
                      phx-disable-with={gettext("Removing…")}
                      class="hover:text-error"
                    >
                      <.icon name="hero-x-mark" class="w-3 h-3" />
                    </button>
                  </span>
                <% end %>
              </div>
            <% end %>

            <%= if @available_assignment_deps != [] do %>
              <.form for={%{}} phx-submit="add_assignment_dep" class="flex gap-2 items-end mt-2">
                <.select
                  name="depends_on_uuid"
                  label={gettext("Add dependency")}
                  value=""
                  options={Enum.map(@available_assignment_deps, &{&1.task.title, &1.uuid})}
                  prompt={gettext("Select task")}
                />
                <button type="submit" phx-disable-with={gettext("Adding…")} class="btn btn-ghost btn-sm">
                  <.icon name="hero-plus" class="w-4 h-4" />
                </button>
              </.form>
            <% end %>

            <%= if @assignment_deps == [] and @available_assignment_deps == [] do %>
              <p class="text-sm text-base-content/50 mt-2">{gettext("No other tasks in this project to depend on.")}</p>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
