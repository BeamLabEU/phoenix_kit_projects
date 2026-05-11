defmodule PhoenixKitProjects.Web.AssignmentFormLive do
  @moduledoc """
  Add a task to a project or edit an existing assignment.
  Supports picking from library or creating new. Manages assignment
  dependencies (which tasks in this project must finish first).
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext
  use PhoenixKitProjects.Web.Components

  import PhoenixKitWeb.Components.MultilangForm

  require Logger

  alias PhoenixKitProjects.{Activity, L10n, Paths, Projects}
  alias PhoenixKitProjects.Schemas.{Assignment, Task}
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  @impl true
  def mount(params, _session, socket) do
    socket = mount_multilang(socket)
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  # Recursive function component for the closure-pull tree. Renders
  # one node + its children indented underneath. The root has the
  # checkbox disabled (the user picks the root via the task dropdown,
  # not by un-ticking it here); already-in-project nodes render as
  # static "already there" markers. Cycle nodes terminate with a
  # warning glyph instead of recursing.
  #
  # `:ancestor_excluded?` cascades down the tree: when an ancestor is
  # in `excluded_uuids`, every descendant gets locked out (checkbox
  # disabled, label greyed, struck through). The user can still
  # re-tick the ancestor to bring the whole subtree back — only
  # explicit per-node clicks live in `excluded_uuids`.
  attr :node, :map, required: true
  attr :excluded_uuids, :any, required: true
  attr :is_root, :boolean, default: false
  attr :ancestor_excluded?, :boolean, default: false
  attr :lang, :string, default: nil

  defp closure_node(assigns) do
    self_excluded? = MapSet.member?(assigns.excluded_uuids, assigns.node.task.uuid)

    assigns =
      assigns
      |> assign(:self_excluded?, self_excluded?)
      |> assign(:effective_excluded?, assigns.ancestor_excluded? or self_excluded?)

    ~H"""
    <li class="flex flex-col">
      <div class="flex items-start gap-2 py-0.5">
        <%= cond do %>
          <% @node.cycle? -> %>
            <span class="text-warning text-sm" title={gettext("Cycle detected — traversal stopped here")}>↻</span>
            <span class="text-sm text-base-content/60 italic">
              {Task.localized_title(@node.task, @lang)}
            </span>
          <% @node.already_in_project? -> %>
            <.icon name="hero-check-circle" class="w-4 h-4 text-success shrink-0 mt-0.5" />
            <span class="text-sm">
              {Task.localized_title(@node.task, @lang)}
              <span class="text-xs text-base-content/50">{gettext("(already in project)")}</span>
            </span>
          <% true -> %>
            <input
              type="checkbox"
              phx-click="toggle_closure_task"
              phx-value-uuid={@node.task.uuid}
              checked={not @effective_excluded?}
              disabled={@is_root or @ancestor_excluded?}
              class="checkbox checkbox-sm shrink-0 mt-0.5"
            />
            <span class={["text-sm", @effective_excluded? && "line-through text-base-content/40"]}>
              {Task.localized_title(@node.task, @lang)}
              <%= cond do %>
                <% @is_root -> %>
                  <span class="text-xs text-base-content/50">{gettext("(this task)")}</span>
                <% @ancestor_excluded? -> %>
                  <span class="text-xs text-base-content/50">{gettext("(parent unchecked)")}</span>
                <% true -> %>
              <% end %>
            </span>
        <% end %>
      </div>

      <%= if @node.children != [] do %>
        <ul class="ml-6 border-l border-base-300 pl-3 space-y-1 mt-0.5">
          <.closure_node
            :for={child <- @node.children}
            node={child}
            excluded_uuids={@excluded_uuids}
            is_root={false}
            ancestor_excluded?={@effective_excluded?}
            lang={@lang}
          />
        </ul>
      <% end %>
    </li>
    """
  end

  defp apply_action(socket, :new, %{"project_id" => project_id}) do
    case Projects.get_project(project_id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Project not found."))
        |> push_navigate(to: Paths.projects())

      project ->
        assignment = %Assignment{project_uuid: project.uuid}
        existing_assignments = Projects.list_assignments(project.uuid)

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
          available_assignment_deps: [],
          # `:new` mode can't create real Dependency rows yet (no
          # assignment uuid). Track the user's selections in
          # `pending_dep_uuids` and create them post-insert in `save_new`
          # / `create_assignment_for_new_task`. `pending_dep_options`
          # is the candidate list (every other assignment in this
          # project — none are this one since it doesn't exist yet).
          pending_dep_uuids: [],
          pending_dep_options: existing_assignments,
          # Closure-pull tree (template task → its transitive
          # dependencies). Loaded on task selection in
          # `prefill_from_template/3`. `excluded_closure_uuids` is the
          # set of tasks the user unticked in the prune UI; a task in
          # this set is dropped from the save-time closure-create
          # batch (its template-edge wiring is also skipped). The
          # root is always kept (the user's explicit pick) — they
          # delete the assignment afterward if they change their mind.
          closure_tree: nil,
          excluded_closure_uuids: MapSet.new()
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
            Projects.available_dependencies(project.uuid, assignment.uuid),
          pending_dep_uuids: [],
          pending_dep_options: [],
          # Edit mode doesn't render the closure UI (closure-pull is
          # a creation-time concept); keep the assigns present so the
          # template's pattern-matching doesn't crash.
          closure_tree: nil,
          excluded_closure_uuids: MapSet.new()
        )
        |> assign_options()
        |> assign_form(Projects.change_assignment(assignment))
    end
  end

  defp assign_options(socket) do
    lang = L10n.current_content_lang()

    assign(socket,
      task_options: Projects.list_tasks() |> Enum.map(&{Task.localized_title(&1, lang), &1.uuid}),
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
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  # Tab strip for "From library" vs "Create new" task source. Sets the
  # `task_mode` assign so the conditional template branches re-render;
  # the hidden form input picks up the new value on the next
  # `phx-change` so `validate`/`save` see it via params (no separate
  # socket-assign read path needed).
  def handle_event("set_task_mode", %{"mode" => mode}, socket)
      when mode in ~w(existing new) do
    {:noreply, assign(socket, task_mode: mode)}
  end

  # Pending-dep buffer for `:new` mode. The Dependency row can only be
  # created post-insert (it FK-references the new assignment's uuid),
  # so track the user's selections in socket state and flush them in
  # `save_new` / `create_assignment_for_new_task` after the assignment
  # row exists. Uses a list (not a MapSet) so the rendered order
  # mirrors the user's add order, and `--` strips dupes if the same
  # uuid is added twice.
  def handle_event("add_pending_dep", %{"depends_on_uuid" => dep_uuid}, socket)
      when dep_uuid != "" do
    {:noreply,
     update(socket, :pending_dep_uuids, fn current ->
       if dep_uuid in current, do: current, else: current ++ [dep_uuid]
     end)}
  end

  def handle_event("add_pending_dep", _params, socket), do: {:noreply, socket}

  def handle_event("remove_pending_dep", %{"uuid" => dep_uuid}, socket) do
    {:noreply, update(socket, :pending_dep_uuids, &List.delete(&1, dep_uuid))}
  end

  # Closure-pull tree node toggle. The root task can't be excluded — it's
  # the user's explicit pick, and excluding it via this UI would leave a
  # logically-empty form. Already-in-project nodes also can't be toggled
  # (they're displayed as static "✓ already there" markers and their
  # state has no effect on save: the project already has the assignment).
  def handle_event("toggle_closure_task", %{"uuid" => task_uuid}, socket) do
    cond do
      is_nil(socket.assigns.closure_tree) ->
        {:noreply, socket}

      task_uuid == socket.assigns.closure_tree.task.uuid ->
        # Root: silently ignored; the task picker is the way to "untick" the root.
        {:noreply, socket}

      true ->
        {:noreply,
         update(socket, :excluded_closure_uuids, fn excluded ->
           if MapSet.member?(excluded, task_uuid),
             do: MapSet.delete(excluded, task_uuid),
             else: MapSet.put(excluded, task_uuid)
         end)}
    end
  end

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
            |> Projects.change_assignment(merge_attrs(attrs, socket))

          assign_form(socket, cs) |> assign(selected_task_uuid: task_uuid)
        end
      else
        cs = Projects.change_assignment(socket.assigns.assignment, merge_attrs(attrs, socket))
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

  defp merge_attrs(attrs, socket) do
    in_flight = WebHelpers.in_flight_record(socket, :form, :assignment)
    WebHelpers.merge_translations_attrs(attrs, in_flight, Assignment.translatable_fields())
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

    attrs =
      attrs
      |> clear_other_assignees(assign_type)
      |> merge_attrs(socket)

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

        flush_pending_deps(socket, assignment)

        {:noreply,
         socket
         |> put_flash(flash_kind, flash_msg)
         |> push_navigate(to: Paths.project(socket.assigns.project.uuid))}

      {:error, cs} ->
        {:noreply, on_save_error(socket, cs)}
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

    # Route through the closure-aware path when the picked task has at
    # least one ticked, not-already-in-project descendant. Otherwise the
    # closure path adds zero-value transactional overhead — fall back to
    # the simple `create_assignment/1` write.
    if closure_pull_needed?(socket) do
      save_new_with_closure(socket, attrs)
    else
      save_new_simple(socket, attrs)
    end
  end

  defp closure_pull_needed?(socket) do
    case socket.assigns.closure_tree do
      nil ->
        false

      tree ->
        # Use the cascade-expanded set so unticking a parent (which
        # also disables descendants) correctly drops the closure-pull
        # path back to the simple-insert one when nothing's left.
        effective_excluded =
          expand_excluded_closure(tree, socket.assigns.excluded_closure_uuids)

        Enum.any?(tree.children, fn child ->
          closure_branch_yields_inserts?(child, effective_excluded)
        end)
    end
  end

  defp closure_branch_yields_inserts?(node, excluded) do
    cond do
      MapSet.member?(excluded, node.task.uuid) ->
        # Self excluded — skip self. Children are also excluded by the
        # cascade so nothing in this subtree yields an insert.
        false

      not node.already_in_project? ->
        true

      true ->
        Enum.any?(node.children, &closure_branch_yields_inserts?(&1, excluded))
    end
  end

  # Expands the user's per-node clicks into the full effective set:
  # every descendant of an excluded ancestor is also excluded. The
  # user-only set lives in socket state so re-ticking an ancestor
  # un-cascades; this helper is the projection used at render + save.
  defp expand_excluded_closure(tree, user_excluded) do
    do_expand_excluded(tree, user_excluded, false, MapSet.new())
  end

  defp do_expand_excluded(%{cycle?: true}, _user_excluded, _ancestor_excluded?, acc), do: acc

  defp do_expand_excluded(%{task: task, children: children}, user_excluded, ancestor_excluded?, acc) do
    self_excluded? = MapSet.member?(user_excluded, task.uuid)
    effective_excluded? = ancestor_excluded? or self_excluded?
    acc = if effective_excluded?, do: MapSet.put(acc, task.uuid), else: acc

    Enum.reduce(children, acc, fn child, a ->
      do_expand_excluded(child, user_excluded, effective_excluded?, a)
    end)
  end

  defp save_new_with_closure(socket, attrs) do
    task_uuid = socket.assigns.closure_tree.task.uuid

    # Expand the user's explicit clicks into the full effective set:
    # every descendant of an unticked ancestor is also excluded. The
    # `excluded_closure_uuids` socket assign stays minimal (only
    # user-clicked uuids) so re-ticking an ancestor can un-cascade.
    effective_excluded =
      expand_excluded_closure(socket.assigns.closure_tree, socket.assigns.excluded_closure_uuids)

    case Projects.create_assignments_with_closure(
           task_uuid,
           socket.assigns.project.uuid,
           attrs,
           excluded_task_uuids: effective_excluded
         ) do
      {:ok, %{root: root, extras: extras}} ->
        Activity.log("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: root.uuid,
          metadata: %{
            "project" => socket.assigns.project.name,
            "closure_extras" => length(extras)
          }
        )

        Enum.each(extras, fn extra ->
          Activity.log("projects.assignment_created",
            actor_uuid: Activity.actor_uuid(socket),
            resource_type: "assignment",
            resource_uuid: extra.uuid,
            metadata: %{
              "project" => socket.assigns.project.name,
              "via_closure_of" => task_uuid
            }
          )
        end)

        flush_pending_deps(socket, root)

        msg =
          case length(extras) do
            0 -> gettext("Task added to project.")
            n -> gettext("Task added with %{count} dependent task(s).", count: n)
          end

        {:noreply,
         socket
         |> put_flash(:info, msg)
         |> push_navigate(to: Paths.project(socket.assigns.project.uuid))}

      {:error, %Ecto.Changeset{} = cs} ->
        Activity.log_failed("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          target_uuid: socket.assigns.project.uuid,
          metadata: %{"project" => socket.assigns.project.name, "via_closure_of" => task_uuid}
        )

        {:noreply, on_save_error(socket, cs)}

      {:error, reason} ->
        Logger.warning(
          "[Projects] closure-create rolled back for task #{task_uuid}: #{inspect(reason)}"
        )

        Activity.log_failed("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          target_uuid: socket.assigns.project.uuid,
          metadata: %{
            "project" => socket.assigns.project.name,
            "via_closure_of" => task_uuid,
            "reason" => inspect(reason)
          }
        )

        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not create the task and its dependencies. Please try again.")
         )}
    end
  end

  defp save_new_simple(socket, attrs) do
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

        flush_pending_deps(socket, assignment)

        {:noreply,
         socket
         |> put_flash(flash_kind, flash_msg)
         |> push_navigate(to: Paths.project(socket.assigns.project.uuid))}

      {:error, cs} ->
        Activity.log_failed("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          target_uuid: socket.assigns.project.uuid,
          metadata: %{"project" => socket.assigns.project.name}
        )

        {:noreply, on_save_error(socket, cs)}
    end
  end

  # Flushes the user's pending-dep selections to real Dependency rows
  # now that the new assignment has a uuid. Called from `save_new` and
  # `create_assignment_for_new_task`. Per-dep failures are logged and
  # audited but do not block the navigate-to-project — the assignment
  # is the load-bearing record; deps are reattachable from the
  # project-show page if any failed (and we'd notice the audit-log
  # `_failed` row).
  defp flush_pending_deps(socket, %Assignment{} = assignment) do
    Enum.each(socket.assigns.pending_dep_uuids, fn dep_uuid ->
      case Projects.add_dependency(assignment.uuid, dep_uuid) do
        {:ok, _} ->
          Activity.log("projects.dependency_added",
            actor_uuid: Activity.actor_uuid(socket),
            resource_type: "assignment",
            resource_uuid: assignment.uuid,
            target_uuid: dep_uuid,
            metadata: %{"source" => "assignment_form_pending"}
          )

        {:error, reason} ->
          Logger.warning(
            "[Projects] pending dep flush failed for assignment #{assignment.uuid} → #{dep_uuid}: " <>
              inspect(reason)
          )

          Activity.log_failed("projects.dependency_added",
            actor_uuid: Activity.actor_uuid(socket),
            resource_type: "assignment",
            resource_uuid: assignment.uuid,
            target_uuid: dep_uuid,
            metadata: %{"source" => "assignment_form_pending"}
          )
      end
    end)
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
        Activity.log_failed("projects.assignment_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: socket.assigns.assignment.uuid,
          metadata: %{"project" => socket.assigns.project.name}
        )

        {:noreply, on_save_error(socket, cs)}
    end
  end

  # Same shape as ProjectFormLive — flips back to the primary tab when
  # the save error sits on a translatable primary field. Assignment
  # only translates `:description`, but listing the field for symmetry
  # with the other forms keeps the helper's API uniform.
  defp on_save_error(socket, %Ecto.Changeset{} = cs) do
    socket
    |> assign_form(cs)
    |> WebHelpers.maybe_switch_to_primary_on_error(cs, [:description])
    |> put_flash(:error, first_error_message(cs))
  end

  defp first_error_message(%Ecto.Changeset{errors: [{field, {msg, _opts}} | _]}) do
    gettext("%{field}: %{message}", field: humanize(field), message: msg)
  end

  defp first_error_message(_), do: gettext("Could not save the assignment.")

  defp humanize(field) do
    field |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
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

        # Build the template-dep closure tree so the form can render
        # the prune UI. Only the root + first level are kept by
        # default (everything ticked); the user can untick branches.
        closure_tree = Projects.task_closure(task_uuid, socket.assigns.project.uuid)

        socket
        |> assign(
          assign_type: assign_type,
          selected_task_uuid: task_uuid,
          closure_tree: closure_tree,
          excluded_closure_uuids: MapSet.new()
        )
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
      <.page_header title={@page_title}>
        <:back_link>
          <.link navigate={Paths.project(@project.uuid)} class="link link-hover text-sm">
            <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {@project.name}
          </.link>
        </:back_link>
      </.page_header>

      <.form for={@form} id="assignment-form" phx-change="validate" phx-submit="save" phx-debounce="300" class="flex flex-col gap-4">
        <%!-- Language tabs render only when multilang is on AND >1 language enabled.
             Single-field translation (description-only): no `<.multilang_fields_wrapper>`
             needed — the rest of the form keeps its primary-language values across
             tab switches because their inputs aren't translatable. --%>
        <%= if @multilang_enabled do %>
          <div class="card bg-base-100 shadow">
            <.multilang_tabs
              multilang_enabled={@multilang_enabled}
              language_tabs={@language_tabs}
              current_lang={@current_lang}
              show_info={false}
            />
          </div>
        <% end %>

        <div class="card bg-base-100 shadow">
          <div class="card-body flex flex-col gap-3">
            <%= if @live_action == :new do %>
              <%!-- Task-source tabs. Replaces the old "Pick from library /
                   Create new" dropdown — a tab strip makes the two
                   alternatives visually parallel instead of buried
                   inside a select. The active tab is held in
                   `@task_mode`; a hidden input keeps the value in form
                   data so existing `validate`/`save` handlers don't
                   need to special-case socket reads. --%>
              <input type="hidden" name="task_mode" value={@task_mode} />
              <.tabs_strip
                event="set_task_mode"
                value_attr="mode"
                active={@task_mode}
                tabs={[
                  {"existing", gettext("From library"), "hero-rectangle-stack"},
                  {"new", gettext("Create new"), "hero-plus"}
                ]}
              />

              <%= if @task_mode == "existing" do %>
                <.select
                  field={@form[:task_uuid]}
                  label={gettext("Task template")}
                  options={@task_options}
                  prompt={gettext("Select task")}
                  required
                />

                <%!-- Closure pull-in tree. Renders only when the
                     selected task has at least one descendant in the
                     `TaskDependency` graph. The user can untick any
                     branch to drop it from the auto-create batch.
                     Already-in-project tasks render as static "✓"
                     markers (no-op on save). --%>
                <%= if @closure_tree && @closure_tree.children != [] do %>
                  <div class="bg-base-200/50 rounded-lg p-3 mt-1">
                    <div class="flex items-center gap-2">
                      <.icon name="hero-arrow-down-tray" class="w-4 h-4 text-base-content/70" />
                      <h3 class="text-sm font-semibold">
                        {gettext("This task pulls in other tasks")}
                      </h3>
                    </div>
                    <p class="text-xs text-base-content/60 mt-1">
                      {gettext("Untick any you don't want for this project. Tasks already in this project (✓) won't be re-added.")}
                    </p>

                    <ul class="mt-3 space-y-1">
                      <.closure_node
                        node={@closure_tree}
                        excluded_uuids={@excluded_closure_uuids}
                        is_root={true}
                        lang={L10n.current_content_lang()}
                      />
                    </ul>
                  </div>
                <% end %>
              <% else %>
                <.input name="new_task_title" label={gettext("Task title")} value={@new_task_title} required />
              <% end %>
            <% else %>
              <div class="text-sm text-base-content/60">
                {gettext("Task:")} <span class="font-medium">{@assignment.task && Task.localized_title(@assignment.task, L10n.current_content_lang())}</span>
              </div>
            <% end %>

            <div class="divider text-xs text-base-content/50 my-1">{gettext("Details")}</div>

            <.translatable_field
              field_name="description"
              form_prefix="assignment"
              changeset={@form.source}
              schema_field={:description}
              multilang_enabled={@multilang_enabled}
              current_lang={@current_lang}
              primary_language={@primary_language}
              lang_data={WebHelpers.lang_data(@form, @current_lang)}
              secondary_name={"assignment[translations][#{@current_lang}][description]"}
              lang_data_key="description"
              label={gettext("Description")}
              type="textarea"
              rows={3}
            />

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
          </div>
        </div>

        <%!-- Dependencies card. Lives INSIDE the form so it sits above
             the action row (the boss's reading-order rule). The deps
             picker uses `phx-change` on the `<.select>` directly
             rather than a nested `<.form>` — nesting forms is invalid
             HTML and the inner submit would otherwise hijack the
             outer form's submit. The select's `phx-change` overrides
             the parent form's `phx-change="validate"` for its own
             change events.

             - `:edit` mode: writes real Dependency rows immediately
               (`add_assignment_dep` / `remove_assignment_dep`).
             - `:new` mode: the assignment doesn't exist yet, so deps
               can't be DB rows. Track selections in `pending_dep_uuids`
               and flush them in `save_new` /
               `create_assignment_for_new_task` after insert.
             --%>
        <% lang = L10n.current_content_lang() %>
        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title text-lg">{gettext("Dependencies")}</h2>
            <p class="text-xs text-base-content/60">
              {gettext("Tasks in this project that must finish before this one can start.")}
              <%= if @live_action == :new do %>
                <br />
                <span class="text-base-content/50">
                  {gettext("Selections will be applied when you save this task.")}
                </span>
              <% end %>
            </p>

            <%= if @live_action == :edit do %>
              <%= if @assignment_deps != [] do %>
                <div class="flex flex-wrap gap-2 mt-2">
                  <%= for dep <- @assignment_deps do %>
                    <span class="badge badge-outline gap-1">
                      <.icon name="hero-arrow-right-circle" class="w-3 h-3" />
                      {Task.localized_title(dep.depends_on.task, lang)}
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
                <.select
                  name="depends_on_uuid"
                  label={gettext("Add dependency")}
                  value=""
                  options={Enum.map(@available_assignment_deps, &{Task.localized_title(&1.task, lang), &1.uuid})}
                  prompt={gettext("Select task")}
                  phx-change="add_assignment_dep"
                />
              <% end %>

              <%= if @assignment_deps == [] and @available_assignment_deps == [] do %>
                <p class="text-sm text-base-content/50 mt-2">{gettext("No other tasks in this project to depend on.")}</p>
              <% end %>
            <% else %>
              <%!-- :new mode --%>
              <%= if @pending_dep_uuids != [] do %>
                <div class="flex flex-wrap gap-2 mt-2">
                  <% by_uuid = Map.new(@pending_dep_options, &{&1.uuid, &1}) %>
                  <%= for dep_uuid <- @pending_dep_uuids, a = Map.get(by_uuid, dep_uuid), a do %>
                    <span class="badge badge-outline gap-1">
                      <.icon name="hero-arrow-right-circle" class="w-3 h-3" />
                      {Task.localized_title(a.task, lang)}
                      <button
                        type="button"
                        phx-click="remove_pending_dep"
                        phx-value-uuid={dep_uuid}
                        class="hover:text-error"
                      >
                        <.icon name="hero-x-mark" class="w-3 h-3" />
                      </button>
                    </span>
                  <% end %>
                </div>
              <% end %>

              <%= if @pending_dep_options != [] do %>
                <% remaining =
                  Enum.reject(@pending_dep_options, fn a -> a.uuid in @pending_dep_uuids end) %>
                <%= if remaining != [] do %>
                  <.select
                    name="depends_on_uuid"
                    label={gettext("Add dependency")}
                    value=""
                    options={Enum.map(remaining, &{Task.localized_title(&1.task, lang), &1.uuid})}
                    prompt={gettext("Select task")}
                    phx-change="add_pending_dep"
                  />
                <% end %>
              <% else %>
                <p class="text-sm text-base-content/50 mt-2">{gettext("No other tasks in this project to depend on.")}</p>
              <% end %>
            <% end %>
          </div>
        </div>

        <div class="flex justify-end gap-2 mt-2">
          <.link navigate={Paths.project(@project.uuid)} class="btn btn-ghost btn-sm">{gettext("Cancel")}</.link>
          <button type="submit" phx-disable-with={gettext("Saving…")} class="btn btn-primary btn-sm">
            <%= if @live_action == :new, do: gettext("Add"), else: gettext("Save") %>
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
