defmodule PhoenixKitProjects.Web.AssignmentFormLive do
  @moduledoc """
  Add a task to a project or edit an existing assignment.
  Supports picking from library or creating new. Manages assignment
  dependencies (which tasks in this project must finish first).
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components
  # The typeahead's server half + the access-request events. Injected
  # rather than hand-written so this form can't drift from every other
  # surface that offers mentions.
  use PhoenixKit.Mentions.Live
  use PhoenixKitAI.Components.AITranslate.Embed

  import PhoenixKitWeb.Components.MultilangForm

  require Logger

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Mentions
  alias PhoenixKitAI.Components.AITranslate.FormGlue
  alias PhoenixKitProjects.{Activity, Features, L10n, Labels, Paths, Projects, Statuses}
  alias PhoenixKitProjects.Schemas.{Assignment, Project, Task}
  alias PhoenixKitProjects.Web.Components.WorkflowStatusFields, as: WSF
  alias PhoenixKitProjects.Web.Crumbs
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

    # `apply_action/3` fetches project / assignment / task list /
    # closure tree. Runs at the tail of `mount/3` (not
    # `handle_params/3`) so the LV stays embeddable via `live_render`.
    # See dev_docs/embedding_audit.md.
    socket =
      socket
      |> mount_multilang()
      |> assign(
        wrapper_class: wrapper_class,
        embed_redirect_to: redirect_to,
        live_action: live_action
      )
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)
      |> WebHelpers.attach_open_embed_hook()
      # `form_seq` re-keys the title's wrapper after "Add & next" so a fresh
      # element mounts and `phx-mounted` refocuses it; `add_next?` is the
      # submit's intent (the "then=next" submitter), read at save time.
      |> assign(form_seq: 0, add_next?: false)
      |> apply_action(live_action, resolved_params)
      |> assign_fx()
      |> assign_ai_translate()
      # Unsaved edits? Flipped by the first change event; the host's
      # dialog (emit mode) stops closing on Esc/backdrop while true and
      # Cancel asks first. See `mark_dirty/1`.
      |> assign(dirty?: false)
      |> WebHelpers.keep_host_title()

    {:ok, socket}
  end

  # The Create-new title is a real `Task` changeset so it goes through the
  # same `<.translatable_field>` as every other translatable column —
  # `task[title]` on the primary tab, `task[translations][<lang>][title]`
  # on the others. Nothing is inserted until Save.
  defp new_task_form(attrs), do: to_form(Projects.change_task(%Task{}, attrs), as: :task)

  defp prefill_title(params) do
    case Map.get(params, "title") do
      title when is_binary(title) -> title |> String.trim() |> String.slice(0, 255)
      _ -> ""
    end
  end

  # The hub gate map for this form's project. Placeholder projects (the
  # not-found render window) fall back to catalog defaults.
  defp assign_fx(socket) do
    case socket.assigns[:project] do
      %Project{uuid: uuid} = project when is_binary(uuid) ->
        assign(socket, fx: Features.gates(project))

      _ ->
        assign(socket, fx: Features.default_gates())
    end
  end

  # Wires the AI-translate modal/buttons for the assignment's `description`.
  # Only the task-assignment case is translatable here (sub-project links edit
  # the child project elsewhere), so the resource is the assignment only when
  # editing a task row. Events are handled by `use ...AITranslate.Embed`.
  defp assign_ai_translate(socket) do
    resource =
      if socket.assigns[:live_action] == :edit and socket.assigns[:kind] == "task",
        do: socket.assigns[:assignment],
        else: nil

    FormGlue.assign_ai_translation(
      socket,
      "assignment",
      resource,
      PhoenixKitProjects.AITranslateBinding
    )
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
  attr(:node, :map, required: true)
  attr(:excluded_uuids, :any, required: true)
  attr(:is_root, :boolean, default: false)
  attr(:ancestor_excluded?, :boolean, default: false)
  attr(:lang, :string, default: nil)

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

  # Minimal assigns required so the render path can paint a flash + empty
  # frame after `close_or_navigate/2` emits :closed in emit mode (where
  # the LV stays mounted until the host pulls it down). In navigate mode
  # `push_navigate` replaces the LV before render so these are harmless.
  defp assign_not_found_placeholders(socket) do
    placeholder_project = %{uuid: "", name: ""}
    # `task: nil` so the render template's `@assignment.task && ...`
    # short-circuits cleanly. The default `%Assignment{}` would have
    # `task: %Ecto.Association.NotLoaded{}` which is truthy and would
    # crash `Task.localized_title/2`.
    placeholder_assignment = %Assignment{task: nil}

    socket
    |> assign(
      page_title: "",
      kind: "task",
      sp_form: to_form(Projects.change_project(%Project{}), as: :subproject),
      sp_mode: "new",
      link_options: [],
      project: placeholder_project,
      assignment: placeholder_assignment,
      live_action: :new,
      task_mode: "new",
      assign_type: "",
      selected_task_uuid: nil,
      new_task_title: "",
      task_form: new_task_form(%{}),
      add_to_library: false,
      assignment_deps: [],
      available_assignment_deps: [],
      pending_dep_uuids: [],
      pending_dep_options: [],
      closure_tree: nil,
      excluded_closure_uuids: MapSet.new()
    )
    |> assign_options()
    |> assign_form(Projects.change_assignment(placeholder_assignment))
    |> assign_status_init(%Project{})
  end

  # The write gate this form never had.
  #
  # `ProjectShowLive` gates :view and `ProjectFormLive(:edit)` gates
  # :edit_settings, both because the module permission stopped meaning
  # "administer every project" — but this form, the one that actually
  # CREATES and EDITS a project's tasks, kept riding the route alone. So
  # anyone who could reach the module could open
  # `/admin/projects/<any-uuid>/assignments/new` and write into a
  # private project they belong to nothing of, with the project's own
  # create/edit floors never consulted.
  #
  # Templates are exempt for the same reason `template_or_viewable?/2`
  # exempts them: library objects have no membership rows for a per-project
  # resolution to work against.
  #
  # A refusal returns nil so the caller's existing not-found branch handles
  # it — the refusal has to be shaped exactly like "no such project",
  # because existence is itself information.
  defp permitted_project(socket, project_id, action) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    case Projects.get_project(project_id) do
      %Project{is_template: true} = template ->
        if PhoenixKitProjects.Authz.can_use_templates?(scope), do: template

      %Project{} = project ->
        # The task list is a per-project extension now (a project can be
        # only its whiteboards, 2026-09-05): with it off, the project has
        # no tasks to add to or edit, however the page was reached — the
        # show page hides every way in; this closes the URL.
        if PhoenixKitProjects.Authz.can?(scope, project, action) and
             PhoenixKitProjects.Extensions.enabled?(project, "tasks"),
           do: project

      other ->
        other
    end
  end

  defp apply_action(socket, :new, %{"project_id" => project_id} = params) do
    case permitted_project(socket, project_id, :create_tasks) do
      nil ->
        # In navigate mode, `close_or_navigate` push-navigates and the LV is
        # replaced before render. In emit mode it broadcasts `:closed` but
        # the LV stays mounted until the host pulls down the modal — so
        # we need safe placeholders for the render path between emit and
        # host-side teardown.
        socket
        |> assign_not_found_placeholders()
        |> put_flash(:error, gettext("Project not found."))
        |> WebHelpers.close_or_navigate(Paths.projects())

      project ->
        # `kind: "subproject"` (V127) routes the same add page into
        # sub-project mode — feature-gated per project: with the
        # `subprojects` flag off, a crafted `?kind=subproject` URL falls
        # back to the plain task form (Step 4 enforcement).
        kind =
          if Map.get(params, "kind") == "subproject" and Features.on?(project, "subprojects"),
            do: "subproject",
            else: "task"

        assignment = %Assignment{project_uuid: project.uuid}
        existing_assignments = Projects.list_assignments(project.uuid)

        # Trail: Admin Panel / Projects / <parents…> / <project> / Add task —
        # the project is the linked crumb, so the leaf no longer repeats
        # its name ("Add task to Test" was the boss's example of a trail
        # that had lost its way; see `Web.Crumbs`). "Add" because the task
        # is attached to the project; the library's form says "New".
        title =
          if kind == "subproject",
            do: gettext("Add sub-project"),
            else: gettext("Add task")

        socket
        |> assign(Crumbs.under_project(project))
        |> assign(
          page_title: title,
          kind: kind,
          sp_form: to_form(Projects.change_project(%Project{}), as: :subproject),
          # Sub-project add modes (V127): "new" creates a fresh child, "existing"
          # nests an existing standalone project. `link_options` is the eligible
          # set (cycle-safe, same kind).
          sp_mode: "new",
          link_options:
            if(kind == "subproject", do: Projects.available_projects_to_link(project), else: []),
          project: project,
          assignment: assignment,
          portal_review_images: [],
          live_action: :new,
          # A `title` param (the quick-add composer's "More options", or an
          # emit-session `"title"`) lands the form in "new task" mode with
          # the typed title carried over — nothing is created until Save.
          # Create new is the default (most tasks are one-offs — the
          # composer's semantics); From library is the deliberate second
          # choice. A `title` param (the quick-add composer's "More
          # options", or an emit-session `"title"`) prefills the new task's
          # title — nothing is created until Save.
          task_mode: "new",
          assign_type: "",
          selected_task_uuid: nil,
          new_task_title: prefill_title(params),
          task_form: new_task_form(%{"title" => prefill_title(params)}),
          add_to_library: false,
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
        |> assign_status_init(%Project{})
    end
  end

  defp apply_action(socket, :edit, %{"project_id" => project_id, "id" => id}) do
    project = permitted_project(socket, project_id, :edit_tasks)
    assignment = Projects.get_assignment(id)

    # The assignment is re-scoped to the project named in the params. These
    # were fetched independently and never compared, so pairing any
    # project_id with any assignment uuid loaded a FOREIGN task into the
    # edit form — the project gate said yes about one project while the
    # form edited another's row.
    assignment =
      if assignment && project && assignment.project_uuid == project.uuid,
        do: assignment,
        else: nil

    case {project, assignment} do
      {nil, _} ->
        socket
        |> assign_not_found_placeholders()
        |> put_flash(:error, gettext("Project not found."))
        |> WebHelpers.close_or_navigate(Paths.projects())

      {_, nil} ->
        socket
        |> assign_not_found_placeholders()
        |> put_flash(:error, gettext("Assignment not found."))
        |> WebHelpers.close_or_navigate(Paths.project(project_id))

      {project, %Assignment{child_project_uuid: child_uuid} = assignment}
      when is_binary(child_uuid) ->
        # Sub-project linking row (V127): edit the CHILD project's name +
        # assignee, plus this row's dependencies. The assignee lives on the
        # child, so `assign_type` + `sp_form` come from it.
        child = Projects.get_project_with_assignee(child_uuid) || %Project{}

        socket
        |> assign(Crumbs.under_project(project))
        |> assign(
          page_title:
            gettext("Edit %{name}",
              name: Project.localized_name(child, L10n.current_content_lang())
            ),
          kind: "subproject",
          sp_form: to_form(Projects.change_project(child), as: :subproject),
          sp_mode: "new",
          link_options: [],
          project: project,
          assignment: assignment,
          portal_review_images: PhoenixKitProjects.Portal.review_images(assignment.uuid),
          live_action: :edit,
          assign_type: assignee_kind(child),
          assignment_deps: Projects.list_dependencies(assignment.uuid),
          available_assignment_deps:
            Projects.available_dependencies(project.uuid, assignment.uuid),
          pending_dep_uuids: [],
          pending_dep_options: [],
          task_mode: "new",
          selected_task_uuid: nil,
          new_task_title: "",
          task_form: new_task_form(%{}),
          add_to_library: false,
          closure_tree: nil,
          excluded_closure_uuids: MapSet.new()
        )
        |> assign_options()
        |> assign_form(Projects.change_assignment(assignment))
        |> assign_status_init(child)

      {project, assignment} ->
        task_name =
          assignment.task && Task.localized_title(assignment.task, L10n.current_content_lang())

        socket
        |> assign(Crumbs.under_project(project))
        |> assign(
          # "Edit <task>" under the project crumb — the leaf names its object.
          page_title:
            if(task_name,
              do: gettext("Edit %{name}", name: task_name),
              else: gettext("Edit assignment")
            ),
          kind: "task",
          sp_form: to_form(Projects.change_project(%Project{}), as: :subproject),
          sp_mode: "new",
          link_options: [],
          project: project,
          assignment: assignment,
          portal_review_images: PhoenixKitProjects.Portal.review_images(assignment.uuid),
          live_action: :edit,
          task_mode: "new",
          assign_type: assignee_kind(assignment),
          selected_task_uuid: assignment.task_uuid,
          new_task_title: "",
          task_form: new_task_form(%{}),
          add_to_library: false,
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
        |> assign_status_init(%Project{})
    end
  end

  # Fail-closed catch-all. Triggers when the host emits `{:projects,
  # :opened, %{lv: AssignmentFormLive, session: %{}}}` without the
  # required `project_id` (or `id` for :edit). Without this clause the
  # apply_action/3 dispatch raises `FunctionClauseError` before mount
  # completes. Per the embedding contract we render placeholders + flash,
  # then `close_or_navigate/2` emits `:closed` so the host can pop the
  # modal.
  defp apply_action(socket, action, _params) when action in [:new, :edit] do
    socket
    |> assign_not_found_placeholders()
    |> put_flash(:error, gettext("Project not found."))
    |> WebHelpers.close_or_navigate(Paths.projects())
  end

  # Which assignee `<select>` is active for a record carrying the polymorphic
  # assignee fields (an Assignment or a Project).
  defp assignee_kind(%{assigned_person_uuid: u}) when not is_nil(u), do: "person"
  defp assignee_kind(%{assigned_team_uuid: u}) when not is_nil(u), do: "team"
  defp assignee_kind(%{assigned_department_uuid: u}) when not is_nil(u), do: "department"
  defp assignee_kind(_), do: ""

  # Workflow-status assigns for sub-project mode (V125) — a sub-project is a
  # project, so it gets the same status-source picker. Delegates to the shared
  # `WorkflowStatusFields` logic. Harmless in task mode (the section isn't
  # rendered there).
  defp assign_status_init(socket, record) do
    available = WSF.available?()

    socket
    |> assign(
      statuses_available: available,
      status_entities: if(available, do: WSF.entity_options(), else: []),
      status_translation_mode: WSF.mode_string(record),
      status_preview: []
    )
    |> refresh_status_preview()
  end

  defp refresh_status_preview(%{assigns: %{statuses_available: true, sp_form: sp_form}} = socket) do
    selected = WSF.selected_entity_uuid(sp_form[:status_entity_uuid])
    assign(socket, status_preview: WSF.preview_for(selected))
  end

  defp refresh_status_preview(socket), do: socket

  defp assign_options(socket) do
    lang = L10n.current_content_lang()

    assign(socket,
      task_options: Projects.list_tasks() |> Enum.map(&{Task.localized_title(&1, lang), &1.uuid}),
      team_options: load_teams(),
      department_options: load_departments(),
      person_options: load_people(),
      project_labels: load_project_labels(socket),
      selected_labels: current_label_uuids(socket)
    )
  end

  defp load_project_labels(socket) do
    case socket.assigns[:project] do
      %{uuid: uuid} -> Labels.list_for_project(uuid)
      _ -> []
    end
  end

  defp current_label_uuids(socket) do
    case socket.assigns[:assignment] do
      %{uuid: uuid} ->
        [uuid]
        |> Labels.labels_for_assignments()
        |> Map.get(uuid, [])
        |> Enum.map(& &1.uuid)

      _ ->
        []
    end
  end

  defp load_teams do
    PhoenixKitProjects.People.list_teams()
    |> Enum.map(&{"#{&1.name} (#{&1.department.name})", &1.uuid})
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Projects] load_teams failed: #{Exception.message(e)}")
      []
  end

  defp load_departments do
    PhoenixKitProjects.People.list_departments() |> Enum.map(&{&1.name, &1.uuid})
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Projects] load_departments failed: #{Exception.message(e)}")
      []
  end

  defp load_people do
    PhoenixKitProjects.People.list_people()
    |> Enum.map(&{(&1.user && &1.user.email) || "—", &1.uuid})
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Projects] load_people failed: #{Exception.message(e)}")
      []
  end

  defp assign_form(socket, cs), do: assign(socket, form: to_form(cs))

  # ── Validate ────────────────────────────────────────────────────

  @impl true
  def handle_event("cancel", _params, socket) do
    fallback =
      case socket.assigns[:project] do
        %{uuid: uuid} -> Paths.project(uuid)
        _ -> Paths.projects()
      end

    {:noreply, WebHelpers.close_or_navigate(socket, fallback)}
  end

  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  # Tab strip for "From library" vs "Create new" task source. Sets the
  # `task_mode` assign so the conditional template branches re-render;
  # the hidden form input picks up the new value on the next
  # `phx-change` so `validate`/`save` see it via params (no separate
  # socket-assign read path needed).
  def handle_event("set_task_mode", %{"tab" => mode}, socket)
      when mode in ~w(existing new) do
    # The library tab only exists while the project's library flag is on;
    # a stale or forged switch to it is ignored.
    if mode == "existing" and not socket.assigns.fx.library do
      {:noreply, socket}
    else
      {:noreply, assign(socket, task_mode: mode)}
    end
  end

  # Pending-dep buffer for `:new` mode. The Dependency row can only be
  # created post-insert (it FK-references the new assignment's uuid),
  # so track the user's selections in socket state and flush them in
  # `save_new` / `create_assignment_for_new_task` after the assignment
  # row exists. Uses a list (not a MapSet) so the rendered order
  # mirrors the user's add order; the `if dep_uuid in current` guard
  # below skips dupes when the same uuid is added twice.
  # Pending deps are flushed into REAL dependency rows on save — they get
  # the same dependencies gate as the live add/remove pair, or a forged
  # pending-add on a dependencies-off project persists rows (panel R3-3).
  def handle_event("add_pending_dep", %{"depends_on_uuid" => dep_uuid}, socket)
      when dep_uuid != "" do
    if socket.assigns.fx.dependencies do
      {:noreply,
       socket
       |> update(:pending_dep_uuids, fn current ->
         if dep_uuid in current, do: current, else: current ++ [dep_uuid]
       end)
       |> WebHelpers.mark_dirty()}
    else
      {:noreply,
       put_flash(socket, :error, gettext("This feature is turned off for this project."))}
    end
  end

  def handle_event("add_pending_dep", _params, socket), do: {:noreply, socket}

  def handle_event("remove_pending_dep", %{"uuid" => dep_uuid}, socket) do
    {:noreply,
     socket |> update(:pending_dep_uuids, &List.delete(&1, dep_uuid)) |> WebHelpers.mark_dirty()}
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
         socket
         |> update(:excluded_closure_uuids, fn excluded ->
           if MapSet.member?(excluded, task_uuid),
             do: MapSet.delete(excluded, task_uuid),
             else: MapSet.put(excluded, task_uuid)
         end)
         |> WebHelpers.mark_dirty()}
    end
  end

  def handle_event("validate", %{"assignment" => attrs} = params, socket) do
    assign_type = Map.get(params, "assign_type", socket.assigns.assign_type)
    task_mode = Map.get(params, "task_mode", socket.assigns.task_mode)

    add_to_library =
      case Map.get(params, "add_to_library") do
        nil -> socket.assigns.add_to_library
        value -> value == "true"
      end

    # The new task's title (+ translations) rides in `params["task"]`;
    # absent when the library tab is showing (its inputs are not rendered).
    task_form =
      case Map.get(params, "task") do
        %{} = task_params -> new_task_form(merge_task_attrs(task_params, socket))
        _ -> socket.assigns.task_form
      end

    new_task_title = Ecto.Changeset.get_field(task_form.source, :title) || ""

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
     socket
     |> assign(
       assign_type: assign_type,
       task_mode: task_mode,
       new_task_title: new_task_title,
       task_form: task_form,
       add_to_library: add_to_library
     )
     |> WebHelpers.mark_dirty()}
  end

  # ── Dependency management (edit mode) ───────────────────────────

  def handle_event("add_assignment_dep", %{"depends_on_uuid" => dep_uuid}, socket)
      when dep_uuid != "" do
    if socket.assigns.fx.dependencies do
      do_add_assignment_dep(dep_uuid, socket)
    else
      {:noreply,
       put_flash(socket, :error, gettext("This feature is turned off for this project."))}
    end
  end

  def handle_event("add_assignment_dep", _params, socket), do: {:noreply, socket}

  def handle_event("remove_assignment_dep", %{"uuid" => dep_uuid}, socket) do
    if socket.assigns.fx.dependencies do
      do_remove_assignment_dep(dep_uuid, socket)
    else
      {:noreply,
       put_flash(socket, :error, gettext("This feature is turned off for this project."))}
    end
  end

  # ── Save ────────────────────────────────────────────────────────

  def handle_event("save", %{"assignment" => attrs} = params, socket) do
    assign_type = Map.get(params, "assign_type", "")

    # Save-time gate re-resolution (panel R3-4): the submit binds to the
    # CURRENT flags, not the mount-time snapshot a mid-edit toggle staled.
    fx = Features.gates(socket.assigns.project)
    # "Add & next" (Shift+Enter, or the button — the submitter carries
    # `then=next`): after a successful create the form resets for the next
    # task instead of closing. Only a create can chain.
    socket =
      assign(socket,
        fx: fx,
        add_next?: socket.assigns.live_action == :new and Map.get(params, "then") == "next"
      )

    # With the library off for this project, a submit can neither pick
    # from it nor feed it — whatever the (stale or forged) params say.
    task_mode =
      if fx.library, do: Map.get(params, "task_mode", socket.assigns.task_mode), else: "new"

    socket =
      case {fx.library, Map.get(params, "add_to_library")} do
        {false, _} -> assign(socket, add_to_library: false)
        {true, nil} -> socket
        {true, value} -> assign(socket, add_to_library: value == "true")
      end

    # Labels ride a separate param (checkbox list) — captured only when
    # the flag is on at SAVE time, applied after the record write.
    socket =
      assign(
        socket,
        :pending_labels,
        if(fx.labels, do: Enum.uniq(List.wrap(params["labels"] || [])))
      )

    attrs =
      attrs
      |> clear_other_assignees(assign_type)
      |> strip_gated_attrs(fx)
      |> merge_attrs(socket)

    case {socket.assigns.live_action, task_mode} do
      {:new, "new"} -> save_with_new_task(socket, attrs, params)
      {:new, _} -> save_new(socket, attrs)
      {:edit, _} -> save_edit(socket, attrs)
    end
  end

  # Portal visibility flip — immediate write, never a form param. Gated
  # explicitly on :edit_tasks (a PUBLIC-exposure change gets the strict
  # shape even though this LV otherwise trusts its mount gate).
  def handle_event("toggle_board_published", _params, socket) do
    assignment = socket.assigns[:assignment]
    project = socket.assigns[:project]
    actor = socket.assigns[:phoenix_kit_current_scope] || Activity.actor_uuid(socket)
    publish? = is_map(assignment) and is_nil(assignment.board_published_at)

    # Same guard chain as the link-holder toggle beside it: publishing to
    # the OPEN WEB cannot be an easier action than publishing to the link.
    with %Assignment{uuid: uuid} when is_binary(uuid) <- assignment,
         true <- public_board?(project),
         true <- actor != nil and PhoenixKitProjects.Authz.can?(actor, project, :edit_tasks),
         {:ok, _} <- PhoenixKitProjects.Portal.set_board_published(uuid, publish?) do
      Activity.log(
        if(publish?,
          do: "projects.issue_board_published",
          else: "projects.issue_board_unpublished"
        ),
        actor_uuid: Activity.actor_uuid(socket),
        resource_type: "assignment",
        resource_uuid: assignment.uuid,
        metadata: %{"project_uuid" => assignment.project_uuid}
      )

      {:noreply,
       socket
       |> assign(assignment: Projects.get_assignment(assignment.uuid))
       |> put_flash(
         :info,
         if(publish?,
           do: gettext("Published to the public board."),
           else: gettext("Removed from the public board.")
         )
       )}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not change that."))}
    end
  end

  def handle_event("toggle_portal_public", _params, socket) do
    assignment = socket.assigns[:assignment]
    project = socket.assigns[:project]

    actor =
      socket.assigns[:phoenix_kit_current_scope] || Activity.actor_uuid(socket)

    with %Assignment{uuid: uuid} when is_binary(uuid) <- assignment,
         true <- portal_enabled?(project),
         true <- actor != nil and PhoenixKitProjects.Authz.can?(actor, project, :edit_tasks),
         {:ok, updated} <-
           PhoenixKitProjects.Portal.set_public(assignment, assignment.public != true,
             actor_uuid: Activity.actor_uuid(socket)
           ) do
      {:noreply, assign(socket, assignment: updated)}
    else
      _ -> {:noreply, socket}
    end
  end

  # ── Sub-project mode (V127) ──────────────────────────────────────
  # Same add/edit page as a task, but the form is the child project
  # (name + assignee) and the dependency section uses the same handlers.

  # Toggle between "create new child" and "nest existing project" (V127).
  # Feature-gated: sub-project mode is unreachable when the flag is off
  # (kind resolution already forces "task"), but a stale client could still
  # emit the event — refuse it the same way.
  def handle_event("set_sp_mode", %{"tab" => mode}, socket)
      when mode in ~w(new existing) do
    if socket.assigns.fx.subprojects do
      do_set_sp_mode(mode, socket)
    else
      {:noreply,
       put_flash(socket, :error, gettext("This feature is turned off for this project."))}
    end
  end

  def handle_event("validate_subproject", %{"subproject" => attrs} = params, socket) do
    assign_type = Map.get(params, "assign_type", socket.assigns.assign_type)
    mode = Map.get(params, "status_translation_mode", socket.assigns.status_translation_mode)
    attrs = clear_other_assignees(attrs, assign_type)
    cs = Projects.change_project(sp_source(socket), attrs)

    {:noreply,
     socket
     |> assign(
       sp_form: to_form(cs, as: :subproject),
       assign_type: assign_type,
       status_translation_mode: mode
     )
     |> refresh_status_preview()
     |> WebHelpers.mark_dirty()}
  end

  # "Link existing" mode renders no `subproject[...]` inputs, so the form's
  # `phx-change` arrives without a "subproject" key — nothing to validate.
  def handle_event("validate_subproject", _params, socket), do: {:noreply, socket}

  # A sub-project is a project, so it gets the same "Generate default" action
  # ProjectFormLive has (V125). Operates on `@sp_form`. Feature-gated on
  # `statuses` (panel R3-5): with the flag off this provisions nothing.
  def handle_event("generate_default_statuses", _params, socket) do
    if Features.gates(socket.assigns.project).statuses do
      do_generate_default_statuses(socket)
    else
      {:noreply,
       put_flash(socket, :error, gettext("This feature is turned off for this project."))}
    end
  end

  # "Link existing" mode: no `subproject[...]` inputs, just the picked child.
  # The whole sub-project branch is feature-gated (panel R3-2): kind
  # resolution already forces the task form when the flag is off, but a
  # forged save_subproject would still create/link a child — refuse it, and
  # strip gated attrs the same way the task save does.
  def handle_event("save_subproject", %{"link_child_uuid" => child_uuid}, socket) do
    fx = Features.gates(socket.assigns.project)

    if fx.subprojects do
      link_existing_subproject(socket, child_uuid)
    else
      {:noreply,
       put_flash(socket, :error, gettext("This feature is turned off for this project."))}
    end
  end

  def handle_event("save_subproject", %{"subproject" => attrs} = params, socket) do
    # Re-resolve at save time (panel R3-4): a mid-edit toggle in another
    # session must bind the SUBMIT, not the stale mount-time map.
    fx = Features.gates(socket.assigns.project)

    if fx.subprojects do
      assign_type = Map.get(params, "assign_type", "")

      attrs =
        attrs
        |> clear_other_assignees(assign_type)
        |> strip_gated_attrs(fx)
        |> then(fn a ->
          if fx.statuses, do: a, else: Map.drop(a, ~w(status_entity_uuid))
        end)
        |> WSF.apply_mode(params, sp_source(socket))

      case socket.assigns.live_action do
        :new -> save_new_subproject(socket, attrs)
        :edit -> save_edit_subproject(socket, attrs)
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("This feature is turned off for this project."))}
    end
  end

  defp link_existing_subproject(socket, child_uuid)
       when child_uuid in [nil, ""] do
    {:noreply, put_flash(socket, :error, gettext("Pick a project to nest."))}
  end

  defp link_existing_subproject(socket, child_uuid) do
    parent = socket.assigns.project

    case Projects.link_subproject(parent.uuid, child_uuid) do
      {:ok, %{child_project: child, assignment: link}} ->
        Activity.log("projects.subproject_linked",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: link.uuid,
          metadata: %{"name" => child.name, "child_project_uuid" => child.uuid}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Existing project nested as a sub-project."))
         |> WebHelpers.navigate_after_save(Paths.project(parent.uuid),
           kind: :assignment,
           record: link,
           action: :create
         )}

      {:error, reason} ->
        Activity.log_failed("projects.subproject_linked",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: child_uuid,
          metadata: %{"parent_project_uuid" => parent.uuid, "reason" => to_string(reason)}
        )

        {:noreply, put_flash(socket, :error, link_error_message(reason))}
    end
  end

  defp link_error_message(:self_link), do: gettext("A project can't be its own sub-project.")

  defp link_error_message(:would_create_cycle),
    do: gettext("That project is an ancestor — nesting it here would create a cycle.")

  defp link_error_message(:already_subproject),
    do: gettext("That project is already a sub-project of another parent.")

  defp link_error_message(:kind_mismatch),
    do: gettext("Templates and projects can't be nested into each other.")

  defp link_error_message(:not_found), do: gettext("That project no longer exists.")
  defp link_error_message(_), do: gettext("Could not nest that project.")

  # The base struct the sub-project form edits (a fresh `%Project{}` on :new,
  # the embedded child on :edit). Read off the form's changeset data.
  defp sp_source(socket), do: socket.assigns.sp_form.source.data

  defp save_new_subproject(socket, attrs) do
    case Projects.create_subproject(socket.assigns.project.uuid, attrs) do
      {:ok, %{child_project: child, assignment: link}} ->
        Activity.log("projects.subproject_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: link.uuid,
          metadata: %{"name" => child.name, "child_project_uuid" => child.uuid}
        )

        flush_pending_deps(socket, link)
        sync_mentions(socket, child)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Sub-project added."))
         |> WebHelpers.navigate_after_save(Paths.project(socket.assigns.project.uuid),
           kind: :assignment,
           record: link,
           action: :create
         )}

      {:error, %Ecto.Changeset{} = cs} ->
        log_subproject_save_failed(socket, "projects.subproject_created")
        {:noreply, assign(socket, sp_form: to_form(cs, as: :subproject))}

      {:error, _other} ->
        log_subproject_save_failed(socket, "projects.subproject_created")
        {:noreply, put_flash(socket, :error, gettext("Could not add sub-project."))}
    end
  end

  # Indexes the @ and # mentions in a saved description and delivers the
  # pings. Deliberately on the DURABLE save rather than on change: `sync`
  # returns only what is new, and notifying from a debounce would ping on
  # every pause in typing.
  #
  # Never allowed to fail the save. A mention that doesn't index is a
  # missing backlink; a save that rolls back because of one is lost work.
  defp sync_mentions(socket, %{uuid: uuid, description: description}) do
    case Mentions.sync("project", uuid, description,
           field: "description",
           actor_uuid: Activity.actor_uuid(socket)
         ) do
      {:ok, new} ->
        Mentions.notify(new,
          source_type: "project",
          source_uuid: uuid,
          preview: description
        )

      _ ->
        :ok
    end
  end

  # Error-branch audit row for the sub-project save paths — the module
  # convention is that even a validation failure leaves a trace of the
  # attempted action (see project_form_live's save handlers).
  defp log_subproject_save_failed(socket, action) do
    Activity.log_failed(action,
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "project",
      metadata: %{"parent_project_uuid" => socket.assigns.project.uuid}
    )
  end

  defp save_edit_subproject(socket, attrs) do
    # A sub-project is a project: a started one's status source is frozen, so
    # strip it from the attrs (the picker is also locked in the form).
    attrs = Statuses.lock_status_source(attrs, sp_source(socket))

    case Projects.update_project(sp_source(socket), attrs) do
      {:ok, updated} ->
        Activity.log("projects.project_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: updated.uuid,
          metadata: %{"name" => updated.name}
        )

        # Re-sync the linking row's denormalized rollup; climbs to this project.
        Projects.recompute_project_completion(updated.uuid)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Sub-project updated."))
         |> WebHelpers.navigate_after_save(Paths.project(socket.assigns.project.uuid),
           kind: :assignment,
           record: socket.assigns.assignment,
           action: :update
         )}

      {:error, %Ecto.Changeset{} = cs} ->
        log_subproject_save_failed(socket, "projects.project_updated")
        {:noreply, assign(socket, sp_form: to_form(cs, as: :subproject))}
    end
  end

  # A task was created. Plain Add hands over to the host / navigates;
  # "Add & next" tells the host the record exists (`close: false` — the
  # frame stays and the page behind refreshes its list) and resets this
  # form for the next task, clean and focused.
  defp after_create(socket, record) do
    project = socket.assigns.project

    if socket.assigns.add_next? do
      socket
      |> then(fn s ->
        if s.assigns.embed_mode == :emit do
          WebHelpers.navigate_after_save(s, Paths.project(project.uuid),
            kind: :assignment,
            record: record,
            action: :create,
            close: false
          )
        else
          s
        end
      end)
      |> reset_for_next()
    else
      WebHelpers.navigate_after_save(socket, Paths.project(project.uuid),
        kind: :assignment,
        record: record,
        action: :create
      )
    end
  end

  # The same mount as a fresh :new page, keeping what the user chose for
  # the run (library tab or Create new, the "add to library" box), then
  # clean again: the host may close on Esc, and the re-keyed title
  # wrapper mounts and refocuses.
  defp reset_for_next(socket) do
    %{project: project, kind: kind, task_mode: task_mode, add_to_library: to_library} =
      socket.assigns

    socket
    |> apply_action(:new, %{"project_id" => project.uuid, "kind" => kind})
    |> assign_fx()
    |> assign_ai_translate()
    |> assign(
      task_mode: task_mode,
      add_to_library: to_library,
      dirty?: false,
      form_seq: socket.assigns.form_seq + 1
    )
    |> WebHelpers.notify_dirty(false)
    |> WebHelpers.keep_host_title()
  end

  defp merge_attrs(attrs, socket) do
    in_flight = WebHelpers.in_flight_record(socket, :form, :assignment)
    WebHelpers.merge_translations_attrs(attrs, in_flight, Assignment.translatable_fields())
  end

  # `@task_form` is always a changeset-backed form (mounted with one), so
  # the in-flight record is the applied changeset — no fallback needed.
  defp merge_task_attrs(attrs, socket) do
    in_flight = Ecto.Changeset.apply_changes(socket.assigns.task_form.source)
    WebHelpers.merge_translations_attrs(attrs, in_flight, Task.translatable_fields())
  end

  defp save_with_new_task(socket, attrs, params) do
    task_form =
      case Map.get(params, "task") do
        %{} = task_params -> new_task_form(merge_task_attrs(task_params, socket))
        _ -> socket.assigns.task_form
      end

    socket = assign(socket, task_form: task_form)
    task = Ecto.Changeset.apply_changes(task_form.source)

    case String.trim(task.title || "") do
      "" -> {:noreply, put_flash(socket, :error, gettext("Task title is required."))}
      title -> create_task_and_assign(socket, attrs, title, task.translations || %{})
    end
  end

  # Library task + assignment in ONE transaction
  # (`Projects.create_task_with_assignment/3`) — the same write the
  # quick-add composer uses, here with the form's full attrs and a
  # reusable (not one-off) task. Nothing is broadcast or logged before
  # the commit; on failure neither row exists.
  defp create_task_and_assign(socket, attrs, title, title_translations) do
    project = socket.assigns.project

    # "Add to the task library" (off by default — a one-off task, `ad_hoc`,
    # V15, exactly what the quick-add composer creates; ticked = reusable
    # from the library). The task's translations combine the title's own
    # (typed under the language tabs) with the description's, which the
    # assignment form collected under `assignment[translations]`.
    task_attrs =
      %{
        "title" => title,
        "description" => attrs["description"],
        "translations" => task_translations(title_translations, attrs["translations"]),
        "estimated_duration" => attrs["estimated_duration"],
        "estimated_duration_unit" => attrs["estimated_duration_unit"],
        "ad_hoc" => not socket.assigns.add_to_library
      }
      |> maybe_add_default_assignee(attrs)

    case Projects.create_task_with_assignment(project.uuid, task_attrs, attrs) do
      {:ok, %{assignment: assignment}} ->
        apply_pending_labels(socket, assignment)

        {flash_kind, flash_msg} =
          flash_for_template_deps(
            assignment,
            gettext("Task created and added to project.")
          )

        Activity.log("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: assignment.uuid,
          target_uuid: Activity.assignee_target_uuid(assignment),
          metadata: %{"project" => project.name, "new_task" => title}
        )

        flush_pending_deps(socket, assignment)

        {:noreply, socket |> put_flash(flash_kind, flash_msg) |> after_create(assignment)}

      {:error, :task, _cs} ->
        Activity.log_failed("projects.task_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          metadata: %{"project_uuid" => project.uuid}
        )

        {:noreply, put_flash(socket, :error, gettext("Could not create task."))}

      {:error, :assignment, cs} ->
        {:noreply, on_save_error(socket, cs)}

      {:error, :project, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Project not found."))
         |> WebHelpers.close_or_navigate(Paths.projects())}
    end
  end

  # `%{lang => %{"title" => …}}` from the title form merged with the
  # description translations `%{lang => %{"description" => …}}`; empty
  # languages dropped so the JSONB holds only real overrides.
  defp task_translations(title_tr, description_tr) do
    title_tr = if is_map(title_tr), do: title_tr, else: %{}
    description_tr = if is_map(description_tr), do: description_tr, else: %{}

    Map.merge(
      Map.new(title_tr, fn {lang, fields} -> {lang, Map.take(fields || %{}, ["title"])} end),
      Map.new(description_tr, fn {lang, fields} ->
        {lang, Map.take(fields || %{}, ["description"])}
      end),
      fn _lang, a, b -> Map.merge(a, b) end
    )
    |> Enum.reject(fn {_lang, fields} -> fields == %{} end)
    |> Map.new()
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

  defp do_expand_excluded(
         %{task: task, children: children},
         user_excluded,
         ancestor_excluded?,
         acc
       ) do
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
        apply_pending_labels(socket, root)

        Activity.log("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: root.uuid,
          target_uuid: Activity.assignee_target_uuid(root),
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

        {:noreply, socket |> put_flash(:info, msg) |> after_create(root)}

      {:error, %Ecto.Changeset{} = cs} ->
        Activity.log_failed("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          metadata: %{
            "project" => socket.assigns.project.name,
            "project_uuid" => socket.assigns.project.uuid,
            "via_closure_of" => task_uuid
          }
        )

        {:noreply, on_save_error(socket, cs)}

      {:error, reason} ->
        Logger.warning(
          "[Projects] closure-create rolled back for task #{task_uuid}: #{inspect(reason)}"
        )

        Activity.log_failed("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          metadata: %{
            "project" => socket.assigns.project.name,
            "project_uuid" => socket.assigns.project.uuid,
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
        apply_pending_labels(socket, assignment)

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

        {:noreply, socket |> put_flash(flash_kind, flash_msg) |> after_create(assignment)}

      {:error, cs} ->
        Activity.log_failed("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          metadata: %{
            "project" => socket.assigns.project.name,
            "project_uuid" => socket.assigns.project.uuid
          }
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
            metadata: %{"source" => "assignment_form_pending", "depends_on_uuid" => dep_uuid}
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
            metadata: %{"source" => "assignment_form_pending", "depends_on_uuid" => dep_uuid}
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
        apply_pending_labels(socket, updated)

        Activity.log("projects.assignment_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: updated.uuid,
          target_uuid: Activity.assignee_target_uuid(updated),
          metadata: %{"project" => socket.assigns.project.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Assignment updated."))
         |> WebHelpers.navigate_after_save(Paths.project(socket.assigns.project.uuid),
           kind: :assignment,
           record: updated,
           action: :update
         )}

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

  defp do_generate_default_statuses(socket) do
    case Statuses.create_default_status_entity(actor_uuid: Activity.actor_uuid(socket)) do
      {:ok, entity} ->
        Activity.log("projects.status_entity_provisioned",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "entity",
          resource_uuid: entity.uuid,
          metadata: %{"scope" => "subproject"}
        )

        cs =
          socket.assigns.sp_form.source
          |> Ecto.Changeset.put_change(:status_entity_uuid, entity.uuid)

        {:noreply,
         socket
         |> assign(status_entities: WSF.entity_options(), sp_form: to_form(cs, as: :subproject))
         |> refresh_status_preview()
         |> put_flash(:info, gettext("Default statuses entity created."))}

      {:error, _reason} ->
        Activity.log_failed("projects.status_entity_provisioned",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "entity",
          metadata: %{"scope" => "subproject"}
        )

        {:noreply,
         put_flash(socket, :error, gettext("Could not create the default statuses entity."))}
    end
  end

  defp do_add_assignment_dep(dep_uuid, socket) do
    case Projects.add_dependency(socket.assigns.assignment.uuid, dep_uuid) do
      {:ok, _} ->
        Activity.log("projects.dependency_added",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: socket.assigns.assignment.uuid,
          metadata: %{"depends_on_uuid" => dep_uuid}
        )

        reload_deps(socket)

      {:error, _} ->
        Activity.log_failed("projects.dependency_added",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: socket.assigns.assignment.uuid,
          metadata: %{"depends_on_uuid" => dep_uuid}
        )

        {:noreply, put_flash(socket, :error, gettext("Could not add dependency."))}
    end
  end

  defp do_remove_assignment_dep(dep_uuid, socket) do
    case Projects.remove_dependency(socket.assigns.assignment.uuid, dep_uuid) do
      {:ok, _} ->
        Activity.log("projects.dependency_removed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: socket.assigns.assignment.uuid,
          metadata: %{"depends_on_uuid" => dep_uuid}
        )

        reload_deps(socket)

      {:error, _} ->
        Activity.log_failed("projects.dependency_removed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: socket.assigns.assignment.uuid,
          metadata: %{"depends_on_uuid" => dep_uuid}
        )

        {:noreply, put_flash(socket, :error, gettext("Could not remove dependency."))}
    end
  end

  defp do_set_sp_mode(mode, socket) do
    {:noreply, assign(socket, sp_mode: mode)}
  end

  # Server-side mate of the render gates (Step 4): a submit crafted past a
  # hidden section can't smuggle gated fields in. Assignee attrs drop when
  # `assignees` is off; duration attrs when `estimates` is off;
  # counts_weekends when `scheduling` is off.
  defp strip_gated_attrs(attrs, fx) do
    attrs
    |> then(fn a ->
      if fx.assignees,
        do: a,
        else: Map.drop(a, ~w(assigned_team_uuid assigned_department_uuid assigned_person_uuid))
    end)
    |> then(fn a ->
      if fx.estimates, do: a, else: Map.drop(a, ~w(estimated_duration estimated_duration_unit))
    end)
    |> then(fn a -> if fx.scheduling, do: a, else: Map.drop(a, ~w(counts_weekends)) end)
    |> then(fn a -> if fx.priorities, do: a, else: Map.drop(a, ~w(priority)) end)
  end

  # To do / In progress / Done — the middle one only with the in-progress
  # step on, or for a row already there (it must stay selectable).
  defp status_options(fx, assignment) do
    middle? = fx.in_progress or match?(%{status: "in_progress"}, assignment)

    [{gettext("To do"), "todo"}] ++
      if(middle?, do: [{gettext("In progress"), "in_progress"}], else: []) ++
      [{gettext("Done"), "done"}]
  end

  defp priority_options do
    [
      {gettext("Urgent"), "urgent"},
      {gettext("High"), "high"},
      {gettext("Normal"), "normal"},
      {gettext("Low"), "low"}
    ]
  end

  # Replace the saved assignment's labels with the submit's checkbox set
  # (nil = the flag was off at save time — leave the joins untouched).
  defp apply_pending_labels(socket, assignment) do
    case socket.assigns[:pending_labels] do
      nil -> :ok
      uuids -> Labels.set_assignment_labels(assignment, uuids)
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
    <div class={@wrapper_class}>
      <.page_header title={@heading}>
        <:back_link>
          <%!-- A page goes back to the project; inside a host's frame or the
               page's drawer "back" is the way out of the sheet (a frame must
               never push the project page as another frame). --%>
          <.link
            :if={@embed_mode == :navigate}
            navigate={Paths.project(@project.uuid)}
            class="link link-hover text-sm"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {@project.name}
          </.link>
          <button
            :if={@embed_mode != :navigate}
            type="button"
            phx-click="cancel"
            data-confirm={@dirty? && gettext("Discard your changes?")}
            class="link link-hover text-sm"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {@project.name}
          </button>
        </:back_link>
      </.page_header>

      <%= if @kind == "subproject" do %>
        <% sp_lang = L10n.current_content_lang() %>
        <.form
          for={@sp_form}
          id="subproject-form"
          phx-change="validate_subproject"
          phx-submit="save_subproject"
          phx-debounce="300"
          class="flex flex-col gap-4"
        >
          <%!-- On :new a sub-project can either be created fresh or an existing
               standalone project can be nested in place (V127). On :edit only
               the create-new fields exist (you're editing the child itself). --%>
          <%!-- Was a module-local TabsStrip duplicating core's <.nav_tabs>.
               Its payload key was `value`, which needed a native value=
               attribute to work around LiveView's extractMeta overwriting
               meta.value with a button's own empty .value — the component
               standardises on `tab` and the hack goes away with it. --%>
          <.nav_tabs
            :if={@live_action == :new}
            on_change="set_sp_mode"
            active_tab={@sp_mode}
            tabs={[
              %{id: "new", label: gettext("Create new"), icon: "hero-plus"},
              %{id: "existing", label: gettext("Nest existing"), icon: "hero-rectangle-stack"}
            ]}
          />

          <%= if @sp_mode == "existing" do %>
            <div class="card bg-base-100 shadow">
              <div class="card-body flex flex-col gap-3">
                <p class="text-sm text-base-content/60">
                  {gettext("Nest a standalone project under this one. It keeps its own tasks and sub-projects; its progress rolls up here.")}
                </p>
                <%= if @link_options == [] do %>
                  <p class="text-sm text-base-content/50">
                    {gettext("No eligible standalone projects to nest.")}
                  </p>
                <% else %>
                  <.select
                    name="link_child_uuid"
                    label={gettext("Project to nest")}
                    value=""
                    options={Enum.map(@link_options, &{&1.name, &1.uuid})}
                    prompt={gettext("Select a project")}
                    required
                  />
                <% end %>
              </div>
            </div>
          <% else %>
          <div class="card bg-base-100 shadow">
            <div class="card-body flex flex-col gap-3">
              <.input field={@sp_form[:name]} label={gettext("Sub-project name")} required />
              <.textarea
                field={@sp_form[:description]}
                label={gettext("Description (optional)")}
                rows="2"
                mentions
              />

              <div class="divider text-xs text-base-content/50 my-1">{gettext("Assignment (optional)")}</div>
              <.select
                name="assign_type"
                label={gettext("Assign to")}
                value={@assign_type}
                options={[
                  {gettext("Nobody"), ""},
                  {gettext("Department"), "department"},
                  {gettext("Team"), "team"},
                  {gettext("Person"), "person"}
                ]}
              />
              <.select :if={@assign_type == "department"} field={@sp_form[:assigned_department_uuid]} label={gettext("Department")} options={@department_options} prompt={gettext("Select department")} />
              <.select :if={@assign_type == "team"} field={@sp_form[:assigned_team_uuid]} label={gettext("Team")} options={@team_options} prompt={gettext("Select team")} />
              <.select :if={@assign_type == "person"} field={@sp_form[:assigned_person_uuid]} label={gettext("Person")} options={@person_options} prompt={gettext("Select person")} />
            </div>
          </div>

          <%!-- Dependencies — identical to a task's (this sub-project is a row in
               the parent's timeline). Edit mode adds/removes live; new mode
               collects pending selections applied on save. --%>
          <div :if={@fx.dependencies} class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-lg">{gettext("Dependencies")}</h2>
              <p class="text-xs text-base-content/60">
                {gettext("Items in this project that must finish before this sub-project can start.")}
              </p>

              <%= if @live_action == :edit do %>
                <div :if={@assignment_deps != []} class="flex flex-wrap gap-2 mt-2">
                  <%= for dep <- @assignment_deps do %>
                    <span class="badge badge-outline gap-1">
                      <.icon name="hero-arrow-right-circle" class="w-3 h-3" />
                      {Assignment.label(dep.depends_on, sp_lang)}
                      <button type="button" phx-click="remove_assignment_dep" phx-value-uuid={dep.depends_on_uuid} phx-disable-with={gettext("Removing…")} class="hover:text-error">
                        <.icon name="hero-x-mark" class="w-3 h-3" />
                      </button>
                    </span>
                  <% end %>
                </div>
                <.select
                  :if={@available_assignment_deps != []}
                  name="depends_on_uuid"
                  label={gettext("Add dependency")}
                  value=""
                  options={Enum.map(@available_assignment_deps, &{Assignment.label(&1, sp_lang), &1.uuid})}
                  prompt={gettext("Select")}
                  phx-change="add_assignment_dep"
                />
                <p :if={@assignment_deps == [] and @available_assignment_deps == []} class="text-sm text-base-content/50 mt-2">
                  {gettext("No other items in this project to depend on.")}
                </p>
              <% else %>
                <div :if={@pending_dep_uuids != []} class="flex flex-wrap gap-2 mt-2">
                  <% by_uuid = Map.new(@pending_dep_options, &{&1.uuid, &1}) %>
                  <%= for dep_uuid <- @pending_dep_uuids, a = Map.get(by_uuid, dep_uuid), a do %>
                    <span class="badge badge-outline gap-1">
                      <.icon name="hero-arrow-right-circle" class="w-3 h-3" />
                      {Assignment.label(a, sp_lang)}
                      <button type="button" phx-click="remove_pending_dep" phx-value-uuid={dep_uuid} class="hover:text-error">
                        <.icon name="hero-x-mark" class="w-3 h-3" />
                      </button>
                    </span>
                  <% end %>
                </div>
                <% remaining = Enum.reject(@pending_dep_options, fn a -> a.uuid in @pending_dep_uuids end) %>
                <.select
                  :if={remaining != []}
                  name="depends_on_uuid"
                  label={gettext("Add dependency")}
                  value=""
                  options={Enum.map(remaining, &{Assignment.label(&1, sp_lang), &1.uuid})}
                  prompt={gettext("Select")}
                  phx-change="add_pending_dep"
                />
                <p :if={@pending_dep_options == []} class="text-sm text-base-content/50 mt-2">
                  {gettext("No other items in this project to depend on.")}
                </p>
              <% end %>
            </div>
          </div>

          <%!-- Workflow status — a sub-project is a project, so it gets the same
               status-source picker (V125). --%>
          <div :if={@statuses_available} class="card bg-base-100 shadow">
            <div class="card-body">
              <.workflow_status_fields
                statuses_available={@statuses_available}
                field={@sp_form[:status_entity_uuid]}
                status_entities={@status_entities}
                status_preview={@status_preview}
                status_translation_mode={@status_translation_mode}
                locked={Statuses.started?(@sp_form.source.data)}
              />
            </div>
          </div>
          <% end %>

          <div class="flex gap-2">
            <%!-- The same `cancel` as the task form: in a drawer it closes
                 the frame, on the page it navigates back. (It used to be a
                 link that, in emit mode, opened the project as a NEW frame.) --%>
            <button
              type="button"
              phx-click="cancel"
              data-confirm={@dirty? && gettext("Discard your changes?")}
              class="btn btn-ghost"
            >
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              phx-disable-with={gettext("Saving…")}
              class="btn btn-primary"
              disabled={@sp_mode == "existing" and @link_options == []}
            >
              {cond do
                @live_action == :edit -> gettext("Save")
                @sp_mode == "existing" -> gettext("Nest sub-project")
                true -> gettext("Add sub-project")
              end}
            </button>
          </div>
        </.form>
      <% else %>
      <.form for={@form} id="assignment-form" phx-change="validate" phx-submit="save" phx-debounce="300" class="flex flex-col gap-4">
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
              <%!-- Create new first and default; the library is the deliberate
                   second choice — and no choice at all while it is empty
                   (a new install sees one clean form, not a dead tab). --%>
              <.nav_tabs
                :if={@fx.library and @task_options != []}
                on_change="set_task_mode"
                active_tab={@task_mode}
                tabs={[
                  %{id: "new", label: gettext("Create new"), icon: "hero-plus"},
                  %{id: "existing", label: gettext("From library"), icon: "hero-rectangle-stack"}
                ]}
              />

              <%= if @task_mode == "existing" do %>
                <.select
                  field={@form[:task_uuid]}
                  label={gettext("Task")}
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
                <%!-- Separates the library pick from the details below; the
                     Create-new title lives with the details (it is
                     translatable like the description), so no divider there. --%>
                <div class="divider text-xs text-base-content/50 my-1">{gettext("Details")}</div>
              <% end %>
            <% end %>

            <%!-- The translatable fields — the new task's title (Create new)
                 and the description — sit under the language tabs and INSIDE
                 the wrapper so a language switch shows the skeleton + cleanly
                 re-mounts. The non-translatable fields below stay outside the
                 wrapper (and keep their values). --%>
            <%!-- Bundled tabs + AI row. Both without their own card padding:
              this call already sits inside a padded card-body, so the strip
              spans the fields' full width instead of an inset box of its own. --%>
            <.ai_multilang_tabs
              :if={@multilang_enabled}
              multilang_enabled={@multilang_enabled}
              language_tabs={@language_tabs}
              current_lang={@current_lang}
              class="pb-0"
              ai_row_class="flex items-center gap-3 -mt-3"
              ai_translate={FormGlue.ai_translate_config(assigns)}
            />

            <.multilang_fields_wrapper
              multilang_enabled={@multilang_enabled}
              current_lang={@current_lang}
              skeleton_class="space-y-2"
              fields_class=""
            >
              <:skeleton>
                <%!-- Mirrors the fields the wrapper holds: the Create-new
                     title (input height) above the description (textarea). --%>
                <div :if={@live_action == :new and @task_mode == "new"} class="space-y-2 mb-3">
                  <div class="bg-base-content/15 rounded h-4 w-20 animate-pulse"></div>
                  <div class="bg-base-content/15 rounded h-10 w-full animate-pulse"></div>
                </div>
                <div class="space-y-2">
                  <div class="bg-base-content/15 rounded h-4 w-24 animate-pulse"></div>
                  <div class="bg-base-content/15 rounded h-16 w-full animate-pulse"></div>
                </div>
              </:skeleton>

              <%!-- Re-keyed by `form_seq` so "Add & next" mounts a fresh
                   wrapper and the cursor lands back in the title; the same
                   mount focuses it when the sheet opens. Shift+Enter in the
                   title presses "Add & next" (core's PkShiftEnter); plain
                   Enter is the browser's own submit → "Add". --%>
              <div
                :if={@live_action == :new and @task_mode == "new"}
                id={"new-task-title-#{@form_seq}"}
                phx-mounted={JS.focus(to: "#task_title")}
              >
                <.translatable_field
                  field_name="title"
                  form_prefix="task"
                  changeset={@task_form.source}
                  schema_field={:title}
                  multilang_enabled={@multilang_enabled}
                  current_lang={@current_lang}
                  primary_language={@primary_language}
                  lang_data={WebHelpers.lang_data(@task_form, @current_lang)}
                  secondary_name={"task[translations][#{@current_lang}][title]"}
                  lang_data_key="title"
                  label={gettext("Task title")}
                  required
                  phx-hook="PkShiftEnter"
                  data-shift-enter-click="#assignment-add-next"
                />
              </div>

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
                disabled={@current_lang in @ai_in_flight}
                mentions
              />
            </.multilang_fields_wrapper>

            <%!-- Bigger gap separating the translatable Description (governed by
                 the language tabs) from the non-translatable fields below. --%>
            <div :if={@fx.estimates} class="flex gap-2 mt-4">
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
              options={status_options(@fx, @assignment)}
            />

            <div :if={@fx.priorities} class="w-48">
              <.select
                field={@form[:priority]}
                label={gettext("Priority")}
                options={priority_options()}
              />
            </div>

            <%!-- Labels: plain checkboxes over the PROJECT's registry (managed
                 in the Modules panel); selection replaces the join rows on
                 save. Renders only when the flag is on AND labels exist. --%>
            <div :if={@fx.labels and @project_labels != []} class="fieldset">
              <span class="fieldset-legend text-sm font-medium mb-1">{gettext("Labels")}</span>
              <div class="flex flex-wrap gap-2">
                <label
                  :for={label <- @project_labels}
                  class="flex items-center gap-1.5 cursor-pointer rounded-lg border border-base-200 px-2 py-1"
                >
                  <input
                    type="checkbox"
                    name="labels[]"
                    value={label.uuid}
                    checked={label.uuid in @selected_labels}
                    class="checkbox checkbox-xs"
                  />
                  <span class={["badge badge-sm", label.color]}>{label.name}</span>
                </label>
              </div>
            </div>

            <%!-- NOT migrated to `<.checkbox>`: unlike Project/Template,
                 `Assignment.counts_weekends` has no schema default — `nil`
                 is a load-bearing third state meaning "inherit the parent
                 project's counts_weekends" (see `Projects.node_hours/2` and
                 `batched_planned_hours/2`, both `if is_nil(a.counts_weekends),
                 do: project.counts_weekends, else: a.counts_weekends`). The
                 hidden fallback below deliberately submits `""`, which Ecto's
                 `cast/4` (empty_values) turns back into the schema default
                 (`nil`) — preserving "inherit" on every unchecked save.
                 `<.checkbox>` hardcodes its hidden fallback to `value="false"`
                 (not configurable), so swapping it in would silently turn
                 every unchecked submit into an explicit "never count
                 weekends" override and permanently lose the inherit-from-
                 project state through this form. --%>
            <label :if={@fx.scheduling} class="flex items-center gap-2 cursor-pointer">
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

            <%= if @fx.assignees do %>
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
            <% end %>

            <%= if @live_action == :new and @task_mode == "new" and @fx.library do %>
              <div class="divider my-1"></div>
              <.checkbox
                name="add_to_library"
                checked={@add_to_library}
                label={gettext("Add to the task library")}
                class="checkbox-sm"
              />
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
        <div :if={@fx.dependencies} class="card bg-base-100 shadow">
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
                      {Assignment.label(dep.depends_on, lang)}
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
                  options={Enum.map(@available_assignment_deps, &{Assignment.label(&1, lang), &1.uuid})}
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
                      {Assignment.label(a, lang)}
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
                    options={Enum.map(remaining, &{Assignment.label(&1, lang), &1.uuid})}
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

        <%!-- Portal visibility. Inside the form so the page reads in
             order — fields, then who can see this, then Save. It used to
             sit after the closing tag, which put two switches BELOW the
             Save button and made the page look like it had ended and
             then carried on.

             Still immediate writes, not form params: each input carries
             `phx-click` and deliberately NO `name`, so nothing here is
             ever cast from the submitted params. `public` and
             `board_published_at` are server-set only — do not name them. --%>
        <div
          :if={@live_action == :edit and portal_enabled?(@project)}
          class="card bg-base-100 shadow"
        >
          <div class="card-body flex-row items-center justify-between gap-3 py-4">
            <div class="min-w-0">
              <h3 class="text-sm font-semibold">{gettext("Public portal")}</h3>
              <p class="text-xs opacity-60">
              {gettext("Show this issue (title and status only) on the project's public page.")}
              </p>
            </div>
            <input
              type="checkbox"
              class="toggle toggle-primary"
              checked={@assignment.public == true}
              phx-click="toggle_portal_public"
              aria-label={gettext("Show on the public portal")}
            />
          </div>

          <%!-- What the stranger actually attached. This sits ABOVE the two
               publish switches on purpose: the whole justification for
               letting anonymous people upload files is that a person looks
               at them first, and that was not true until this panel existed
               — the text was reviewed here while the images went from an
               unknown submitter straight onto an indexable page, seen by
               nobody. Server-side re-encoding strips the payloads it can;
               it cannot tell you what the picture is OF. --%>
          <div
            :if={@portal_review_images != []}
            class="card-body border-t border-base-200 py-4"
          >
            <h3 class="text-sm font-semibold">{gettext("Attached by the submitter")}</h3>
            <p class="text-xs opacity-60">
              {gettext(
                "Sent by an anonymous visitor and re-encoded on arrival. Look at them before publishing — publishing puts them on the open internet."
              )}
            </p>
            <div class="mt-2 flex flex-wrap gap-3">
              <a
                :for={image <- @portal_review_images}
                href={image.url}
                target="_blank"
                rel="noopener noreferrer nofollow"
                class="block"
              >
                <img
                  src={image.url}
                  alt={gettext("Submitted attachment")}
                  loading="lazy"
                  class="h-28 w-28 rounded-lg border border-base-300 object-cover"
                />
              </a>
            </div>
          </div>

        <%!-- The second, deliberate act. Only offered on a board that is
             actually public and for an issue already visible to
             link-holders: "on the open web" is a bigger decision than "on
             the private link", and the design's whole blast-radius guard
             depends on it being taken one issue at a time. Without this
             control the guard has no product path and a public board stays
             empty forever. --%>
          <div
            :if={@assignment.public == true and public_board?(@project)}
            class="card-body flex-row items-center justify-between gap-3 border-t border-base-200 py-4"
          >
            <div class="min-w-0">
              <h3 class="text-sm font-semibold">{gettext("Publish to the public board")}</h3>
              <p class="text-xs opacity-60">
              {gettext("This board is on the open internet and can be indexed by search engines. The issue's description is shown too.")}
              </p>
            </div>
            <input
              type="checkbox"
              class="toggle toggle-warning"
              checked={@assignment.board_published_at != nil}
              phx-click="toggle_board_published"
              aria-label={gettext("Publish to the public board")}
            />
          </div>
        </div>

        <%!-- DOM order matters: the browser's implicit submission (Enter in
             an input) presses the FIRST submit button, so "Add" comes before
             "Add & next" in the markup and CSS `order` puts it last on
             screen. "Add & next" carries `then=next`, which LiveView sends
             as the submitter — Shift+Enter presses it through PkShiftEnter. --%>
        <div class="flex flex-wrap items-center justify-end gap-2 mt-2">
          <button
            type="button"
            phx-click="cancel"
            data-confirm={@dirty? && gettext("Discard your changes?")}
            class="btn btn-ghost btn-sm order-1"
          >
            {gettext("Cancel")}
          </button>
          <button
            type="submit"
            phx-disable-with={gettext("Saving…")}
            class="btn btn-primary btn-sm order-3"
          >
            <%= if @live_action == :new, do: gettext("Add"), else: gettext("Save") %>
          </button>
          <button
            :if={@live_action == :new}
            type="submit"
            id="assignment-add-next"
            name="then"
            value="next"
            phx-disable-with={gettext("Saving…")}
            title={gettext("Shift+Enter")}
            class="btn btn-outline btn-sm order-2"
          >
            {gettext("Add & next")}
          </button>
        </div>
        <p :if={@live_action == :new} class="text-xs text-base-content/50 text-right">
          <%= if @embed_mode == :navigate do %>
            {gettext("Enter adds · Shift+Enter adds and starts the next")}
          <% else %>
            {gettext("Enter adds · Shift+Enter adds and starts the next · Esc closes")}
          <% end %>
        </p>

        <.ai_translate_modal ai_translate={FormGlue.ai_translate_config(assigns)} />
      </.form>
      <% end %>
    </div>
    """
  end

  defp public_board?(project) do
    case PhoenixKitProjects.Portal.get_portal(project.uuid) do
      %{access_mode: "public"} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp portal_enabled?(project) do
    PhoenixKitProjects.Extensions.enabled?(project, "portal")
  rescue
    _ -> false
  end
end
