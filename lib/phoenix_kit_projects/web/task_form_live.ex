defmodule PhoenixKitProjects.Web.TaskFormLive do
  @moduledoc "Create or edit a reusable task template, including default dependencies."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  import PhoenixKitWeb.Components.MultilangForm

  require Logger

  alias PhoenixKitProjects.{Activity, L10n, Paths, Projects}
  alias PhoenixKitProjects.Schemas.Task
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  # Default wrapper class for the standalone admin page. Embedders can
  # override via `live_render(... session: %{"wrapper_class" => "..."})`.
  @default_wrapper_class "flex flex-col mx-auto max-w-xl px-4 py-6 gap-4"

  @impl true
  def mount(params, session, socket) do
    WebHelpers.maybe_put_locale(session)

    wrapper_class = Map.get(session, "wrapper_class", @default_wrapper_class)
    redirect_to = Map.get(session, "redirect_to")
    live_action = WebHelpers.resolve_live_action(socket, session)
    resolved_params = WebHelpers.resolve_action_params(params, session)

    # `apply_action/3` loads the task on `:edit`; runs at the tail of
    # `mount/3` (not `handle_params/3`) so the LV stays embeddable via
    # `live_render`. See dev_docs/embedding_audit.md.
    socket =
      socket
      |> mount_multilang()
      |> assign(
        wrapper_class: wrapper_class,
        embed_redirect_to: redirect_to,
        live_action: live_action
      )
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.attach_open_embed_hook()
      |> apply_action(live_action, resolved_params)

    {:ok, socket}
  end

  defp apply_action(socket, :new, _params) do
    task = %Task{}

    socket
    |> assign(
      page_title: gettext("New task"),
      task: task,
      live_action: :new,
      assign_type: "",
      task_deps: [],
      available_deps: []
    )
    |> assign_staff_options()
    |> assign_form(Projects.change_task(task))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Projects.get_task(id) do
      nil ->
        # In navigate mode, `close_or_navigate` push-navigates and the LV
        # is replaced before render. In emit mode it broadcasts `:closed`
        # but the LV stays mounted until the host pulls down the modal —
        # so we need render-safe placeholders for the brief window between
        # emit and host-side teardown.
        socket
        |> assign(
          page_title: "",
          task: %Task{},
          live_action: :edit,
          assign_type: "",
          task_deps: [],
          available_deps: []
        )
        |> assign_staff_options()
        |> assign_form(Projects.change_task(%Task{}))
        |> put_flash(:error, gettext("Task not found."))
        |> WebHelpers.close_or_navigate(Paths.tasks())

      task ->
        assign_type =
          cond do
            task.default_assigned_person_uuid -> "person"
            task.default_assigned_team_uuid -> "team"
            task.default_assigned_department_uuid -> "department"
            true -> ""
          end

        socket
        |> assign(
          page_title:
            gettext("Edit %{title}",
              title: Task.localized_title(task, L10n.current_content_lang())
            ),
          task: task,
          live_action: :edit,
          assign_type: assign_type,
          task_deps: Projects.list_task_dependencies(task.uuid),
          available_deps: Projects.available_task_dependencies(task.uuid)
        )
        |> assign_staff_options()
        |> assign_form(Projects.change_task(task))
    end
  end

  # Fail-closed catch-all: emit-session lacking `"id"` for :edit lands
  # here. Render placeholders + flash, then close.
  defp apply_action(socket, :edit, _params) do
    socket
    |> assign(
      page_title: "",
      task: %Task{},
      live_action: :edit,
      assign_type: "",
      task_deps: [],
      available_deps: []
    )
    |> assign_staff_options()
    |> assign_form(Projects.change_task(%Task{}))
    |> put_flash(:error, gettext("Task not found."))
    |> WebHelpers.close_or_navigate(Paths.tasks())
  end

  defp assign_staff_options(socket) do
    assign(socket,
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

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  # Same `:action`-not-stamped pattern as `ProjectFormLive.validate` —
  # surfacing errors only after a failed submit so live editing never
  # red-borders untouched fields.
  def handle_event("validate", %{"task" => attrs} = params, socket) do
    assign_type = Map.get(params, "default_assign_type", socket.assigns.assign_type)
    attrs = merge_attrs(attrs, socket)
    cs = Projects.change_task(socket.assigns.task, attrs)
    {:noreply, socket |> assign(assign_type: assign_type) |> assign_form(cs)}
  end

  def handle_event("save", %{"task" => attrs} = params, socket) do
    assign_type = Map.get(params, "default_assign_type", "")

    attrs =
      attrs
      |> clear_other_default_assignees(assign_type)
      |> then(&merge_attrs(&1, socket))

    save(socket, socket.assigns.live_action, attrs)
  end

  def handle_event("add_dep", %{"depends_on_task_uuid" => dep_uuid}, socket)
      when dep_uuid != "" do
    case Projects.add_task_dependency(socket.assigns.task.uuid, dep_uuid) do
      {:ok, _} ->
        Activity.log("projects.task_dependency_added",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: socket.assigns.task.uuid,
          target_uuid: dep_uuid,
          metadata: %{"task" => socket.assigns.task.title}
        )

      _ ->
        Activity.log_failed("projects.task_dependency_added",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: socket.assigns.task.uuid,
          target_uuid: dep_uuid,
          metadata: %{"task" => socket.assigns.task.title}
        )
    end

    {:noreply, reload_task_deps(socket)}
  end

  def handle_event("add_dep", _params, socket), do: {:noreply, socket}

  def handle_event("cancel", _params, socket) do
    {:noreply, WebHelpers.close_or_navigate(socket, Paths.tasks())}
  end

  def handle_event("remove_dep", %{"uuid" => dep_task_uuid}, socket) do
    case Projects.remove_task_dependency(socket.assigns.task.uuid, dep_task_uuid) do
      {:ok, _} ->
        Activity.log("projects.task_dependency_removed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: socket.assigns.task.uuid,
          target_uuid: dep_task_uuid,
          metadata: %{"task" => socket.assigns.task.title}
        )

      _ ->
        Activity.log_failed("projects.task_dependency_removed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: socket.assigns.task.uuid,
          target_uuid: dep_task_uuid,
          metadata: %{"task" => socket.assigns.task.title}
        )
    end

    {:noreply, reload_task_deps(socket)}
  end

  defp merge_attrs(attrs, socket) do
    in_flight = WebHelpers.in_flight_record(socket, :form, :task)
    WebHelpers.merge_translations_attrs(attrs, in_flight, Task.translatable_fields())
  end

  defp reload_task_deps(socket) do
    assign(socket,
      task_deps: Projects.list_task_dependencies(socket.assigns.task.uuid),
      available_deps: Projects.available_task_dependencies(socket.assigns.task.uuid)
    )
  end

  defp clear_other_default_assignees(attrs, "team") do
    attrs
    |> Map.put("default_assigned_department_uuid", nil)
    |> Map.put("default_assigned_person_uuid", nil)
  end

  defp clear_other_default_assignees(attrs, "department") do
    attrs
    |> Map.put("default_assigned_team_uuid", nil)
    |> Map.put("default_assigned_person_uuid", nil)
  end

  defp clear_other_default_assignees(attrs, "person") do
    attrs
    |> Map.put("default_assigned_team_uuid", nil)
    |> Map.put("default_assigned_department_uuid", nil)
  end

  defp clear_other_default_assignees(attrs, _) do
    attrs
    |> Map.put("default_assigned_team_uuid", nil)
    |> Map.put("default_assigned_department_uuid", nil)
    |> Map.put("default_assigned_person_uuid", nil)
  end

  defp save(socket, :new, attrs) do
    case Projects.create_task(attrs) do
      {:ok, task} ->
        Activity.log("projects.task_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: task.uuid,
          metadata: %{"title" => task.title}
        )

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Task created. You can now add default dependencies by editing it.")
         )
         |> WebHelpers.navigate_after_save(Paths.edit_task(task.uuid),
           kind: :task,
           record: task,
           action: :create,
           # Emit-mode equivalent of the navigate-mode "go to /edit so
           # the user can add dependencies": tell the host to pop the
           # current frame and open the edit form on top.
           next:
             {PhoenixKitProjects.Web.TaskFormLive, %{"live_action" => "edit", "id" => task.uuid}}
         )}

      {:error, cs} ->
        Activity.log_failed("projects.task_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          metadata: %{"title" => Map.get(attrs, "title") || Ecto.Changeset.get_field(cs, :title)}
        )

        {:noreply, on_save_error(socket, cs)}
    end
  end

  defp save(socket, :edit, attrs) do
    case Projects.update_task(socket.assigns.task, attrs) do
      {:ok, task} ->
        Activity.log("projects.task_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: task.uuid,
          metadata: %{"title" => task.title}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Task updated."))
         |> WebHelpers.navigate_after_save(Paths.tasks(),
           kind: :task,
           record: task,
           action: :update
         )}

      {:error, cs} ->
        Activity.log_failed("projects.task_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: socket.assigns.task.uuid,
          metadata: %{"title" => socket.assigns.task.title}
        )

        {:noreply, on_save_error(socket, cs)}
    end
  end

  # Same shape as ProjectFormLive — flips back to the primary tab when
  # the save error sits on a translatable primary field, otherwise the
  # secondary-tab user wouldn't see anything change.
  defp on_save_error(socket, %Ecto.Changeset{} = cs) do
    socket
    |> assign_form(cs)
    |> WebHelpers.maybe_switch_to_primary_on_error(cs, [:title, :description])
    |> put_flash(:error, first_error_message(cs))
  end

  defp first_error_message(%Ecto.Changeset{errors: [{field, {msg, _opts}} | _]}) do
    gettext("%{field}: %{message}", field: humanize(field), message: msg)
  end

  defp first_error_message(_), do: gettext("Could not save the task.")

  defp humanize(field) do
    field |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
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
    <div class={@wrapper_class}>
      <.page_header title={@page_title}>
        <:back_link>
          <.smart_link
            navigate={Paths.tasks()}
            emit={{PhoenixKitProjects.Web.TasksLive, %{}}}
            embed_mode={@embed_mode}
            class="link link-hover text-sm"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {gettext("Task Library")}
          </.smart_link>
        </:back_link>
      </.page_header>

      <.form for={@form} id="task-form" phx-change="validate" phx-submit="save" phx-debounce="300" class="flex flex-col gap-4">
        <%!-- Translatable card: title + description with language tabs. --%>
        <div class="card bg-base-100 shadow">
          <.multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
          />

          <.multilang_fields_wrapper
            multilang_enabled={@multilang_enabled}
            current_lang={@current_lang}
            skeleton_class="card-body pt-4 space-y-4"
            fields_class="card-body pt-4 space-y-4"
          >
            <:skeleton>
              <div class="space-y-2">
                <div class="skeleton h-4 w-24"></div>
                <div class="skeleton h-12 w-full"></div>
              </div>
              <div class="space-y-2">
                <div class="skeleton h-4 w-24"></div>
                <div class="skeleton h-24 w-full"></div>
              </div>
            </:skeleton>

            <.translatable_field
              field_name="title"
              form_prefix="task"
              changeset={@form.source}
              schema_field={:title}
              multilang_enabled={@multilang_enabled}
              current_lang={@current_lang}
              primary_language={@primary_language}
              lang_data={WebHelpers.lang_data(@form, @current_lang)}
              secondary_name={"task[translations][#{@current_lang}][title]"}
              lang_data_key="title"
              label={gettext("Title")}
              required
            />

            <.translatable_field
              field_name="description"
              form_prefix="task"
              changeset={@form.source}
              schema_field={:description}
              multilang_enabled={@multilang_enabled}
              current_lang={@current_lang}
              primary_language={@primary_language}
              lang_data={WebHelpers.lang_data(@form, @current_lang)}
              secondary_name={"task[translations][#{@current_lang}][description]"}
              lang_data_key="description"
              label={gettext("Description")}
              type="textarea"
              rows={4}
            />
          </.multilang_fields_wrapper>
        </div>

        <%!-- Non-translatable settings (duration, default assignee). --%>
        <div class="card bg-base-100 shadow">
          <div class="card-body flex flex-col gap-3">
            <div class="flex gap-2">
              <div class="flex-1">
                <.input field={@form[:estimated_duration]} label={gettext("Estimated duration")} type="number" />
              </div>
              <div class="w-40">
                <.select
                  field={@form[:estimated_duration_unit]}
                  label={gettext("Unit")}
                  options={duration_unit_options()}
                />
              </div>
            </div>

            <div class="divider text-xs text-base-content/50 my-1">{gettext("Default assignment (optional)")}</div>

            <.select
              name="default_assign_type"
              label={gettext("Default assign to")}
              value={@assign_type}
              options={[{gettext("Nobody"), ""}, {gettext("Department"), "department"}, {gettext("Team"), "team"}, {gettext("Person"), "person"}]}
            />

            <%= if @assign_type == "department" do %>
              <.select field={@form[:default_assigned_department_uuid]} label={gettext("Department")} options={@department_options} prompt={gettext("Select department")} />
            <% end %>
            <%= if @assign_type == "team" do %>
              <.select field={@form[:default_assigned_team_uuid]} label={gettext("Team")} options={@team_options} prompt={gettext("Select team")} />
            <% end %>
            <%= if @assign_type == "person" do %>
              <.select field={@form[:default_assigned_person_uuid]} label={gettext("Person")} options={@person_options} prompt={gettext("Select person")} />
            <% end %>
          </div>
        </div>

        <%!-- Default dependencies (edit mode only — task must exist
             first since deps FK-reference its uuid). Lives INSIDE
             the form so it sits above the action row, matching the
             same convention used in `AssignmentFormLive`. The picker
             uses `phx-change` on the `<.select>` instead of a nested
             `<.form>` to avoid nested-form HTML invalidity. --%>
        <%= if @live_action == :edit do %>
          <% lang = L10n.current_content_lang() %>
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-lg">{gettext("Default dependencies")}</h2>
              <p class="text-xs text-base-content/60">
                {gettext("When this task is added to a project, dependencies will be auto-created for any of these tasks already in the same project.")}
              </p>

              <%= if @task_deps != [] do %>
                <div class="flex flex-wrap gap-2 mt-2">
                  <%= for dep <- @task_deps do %>
                    <span class="badge badge-outline gap-1">
                      {Task.localized_title(dep.depends_on_task, lang)}
                      <button
                        type="button"
                        phx-click="remove_dep"
                        phx-value-uuid={dep.depends_on_task_uuid}
                        phx-disable-with={gettext("Removing…")}
                        class="hover:text-error"
                      >
                        <.icon name="hero-x-mark" class="w-3 h-3" />
                      </button>
                    </span>
                  <% end %>
                </div>
              <% end %>

              <%= if @available_deps != [] do %>
                <.select
                  name="depends_on_task_uuid"
                  label={gettext("Add dependency")}
                  value=""
                  options={Enum.map(@available_deps, &{Task.localized_title(&1, lang), &1.uuid})}
                  prompt={gettext("Select task")}
                  phx-change="add_dep"
                />
              <% end %>

              <%= if @task_deps == [] and @available_deps == [] do %>
                <p class="text-sm text-base-content/50 mt-2">{gettext("No other tasks in the library to depend on.")}</p>
              <% end %>
            </div>
          </div>
        <% end %>

        <div class="flex justify-end gap-2 mt-2">
          <button type="button" phx-click="cancel" class="btn btn-ghost btn-sm">
            {gettext("Cancel")}
          </button>
          <button type="submit" phx-disable-with={gettext("Saving…")} class="btn btn-primary btn-sm">
            <%= if @live_action == :new, do: gettext("Create"), else: gettext("Save") %>
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
