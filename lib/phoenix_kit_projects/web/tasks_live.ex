defmodule PhoenixKitProjects.Web.TasksLive do
  @moduledoc "List reusable task templates."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{Activity, L10n, Paths, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Task, as: TaskSchema
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  require Logger

  @valid_views ~w(list groups)

  # Default wrapper class for the standalone admin page. Embedders can
  # override via `live_render(... session: %{"wrapper_class" => "..."})`.
  @default_wrapper_class "flex flex-col w-full px-4 py-6 gap-4"

  # See projects_live for the same load-more pagination semantics.
  @per_batch 50
  @default_pagination "load_more"

  @impl true
  def mount(_params, session, socket) do
    WebHelpers.maybe_put_locale(session)

    if connected?(socket), do: ProjectsPubSub.subscribe(ProjectsPubSub.topic_tasks())

    wrapper_class = Map.get(session, "wrapper_class", @default_wrapper_class)

    # `view` is UI state, not a URL param — the standalone admin page
    # toggles between list and groups via a `phx-click` button. Embedders
    # can preselect by passing `session["view"]` (defaults to "list").
    initial_view =
      case Map.get(session, "view") do
        v when v in @valid_views -> v
        _ -> "list"
      end

    pagination = Map.get(session, "pagination", @default_pagination)

    socket =
      socket
      |> assign(
        page_title: gettext("Task Library"),
        wrapper_class: wrapper_class,
        view: initial_view,
        pagination: pagination,
        sort_by: :position,
        sort_dir: :asc,
        loaded_count: @per_batch,
        total_count: 0,
        tasks: [],
        deps_by_task: %{},
        groups: [],
        standalone: [],
        bulk_enabled?: true,
        captured_uuids: [],
        show_reorder_modal: false
      )
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.attach_open_embed_hook()

    # Load on both disconnected + connected mount so the first paint has
    # real content. `handle_params/3` is intentionally absent — see
    # dev_docs/embedding_audit.md.
    {:ok, load_tasks(socket)}
  end

  # Loads only what the current view actually renders, so flipping
  # between modes doesn't pay for the unused query each time.
  defp load_tasks(socket) do
    case socket.assigns[:view] || "list" do
      "groups" ->
        %{trees: trees, standalone: standalone} = Projects.list_task_groups()
        # Flatten each tree to a peer-list, root-LAST (execution order:
        # prerequisites first, the rooted task at the bottom). The
        # rest of the list is alphabetised inside the tree so within
        # one card the order stays stable across renders even when
        # the tree shape changes.
        groups =
          Enum.map(trees, fn tree ->
            [root | rest] = flatten_tree(tree)
            %{root: root, peers: Enum.sort_by(rest, & &1.title) ++ [root]}
          end)

        assign(socket,
          groups: groups,
          standalone: standalone,
          tasks: [],
          deps_by_task: %{}
        )

      _ ->
        base_opts = [
          sort_by: socket.assigns.sort_by,
          sort_dir: socket.assigns.sort_dir
        ]

        list_opts =
          case socket.assigns.pagination do
            "load_more" -> Keyword.put(base_opts, :limit, socket.assigns.loaded_count)
            _ -> base_opts
          end

        %{tasks: tasks, deps_by_task: deps_by_task} = Projects.list_tasks_with_deps(list_opts)

        assign(socket,
          tasks: tasks,
          deps_by_task: deps_by_task,
          groups: [],
          standalone: [],
          total_count: Projects.count_tasks()
        )
    end
  end

  @sort_fields ~w(position title inserted_at estimated_duration)a
  @sort_field_strs Enum.map(@sort_fields, &Atom.to_string/1)

  defp sort_options do
    [
      {:position, gettext("Manual")},
      {:title, gettext("Title")},
      {:inserted_at, gettext("Date created")},
      {:estimated_duration, gettext("Duration")}
    ]
  end

  @impl true
  def handle_info({:projects, _event, _payload}, socket) do
    {:noreply, load_tasks(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[TasksLive] unexpected handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_view", %{"view" => view}, socket) when view in @valid_views do
    # Switching view re-renders the table; the BulkSelectScope hook
    # re-derives selection from the (fresh) DOM checkboxes — no
    # server-side bookkeeping required.
    {:noreply, socket |> assign(view: view) |> load_tasks()}
  end

  def handle_event("set_view", _params, socket), do: {:noreply, socket}

  # See projects_live for the rationale on collapsing <2 uuids to :all.
  def handle_event("open_reorder_modal", params, socket) do
    uuids =
      case sanitize_uuids(params) do
        list when length(list) < 2 -> []
        list -> list
      end

    {:noreply, assign(socket, show_reorder_modal: true, captured_uuids: uuids)}
  end

  def handle_event("close_reorder_modal", _params, socket) do
    {:noreply, assign(socket, show_reorder_modal: false, captured_uuids: [])}
  end

  # Sort selector — see projects_live for the same pattern.
  def handle_event("sort_form", params, socket) do
    field_str = params["sort_by"] || Atom.to_string(socket.assigns.sort_by)
    dir_str = params["sort_dir"] || Atom.to_string(socket.assigns.sort_dir)

    field =
      if field_str in @sort_field_strs,
        do: String.to_existing_atom(field_str),
        else: socket.assigns.sort_by

    dir =
      case dir_str do
        "desc" -> :desc
        _ -> :asc
      end

    {:noreply, apply_sort(socket, field, dir)}
  end

  def handle_event("toggle_sort", %{"by" => field_str}, socket)
      when field_str in @sort_field_strs do
    field = String.to_existing_atom(field_str)

    dir =
      if field == socket.assigns.sort_by do
        if socket.assigns.sort_dir == :asc, do: :desc, else: :asc
      else
        :asc
      end

    {:noreply, apply_sort(socket, field, dir)}
  end

  def handle_event("toggle_sort", _params, socket), do: {:noreply, socket}

  # Sort change resets the load-more cap — see projects_live.
  defp apply_sort(socket, field, dir) do
    socket
    |> assign(sort_by: field, sort_dir: dir, loaded_count: @per_batch)
    |> load_tasks()
  end

  def handle_event("load_more", _params, socket) do
    {:noreply,
     socket
     |> assign(loaded_count: socket.assigns.loaded_count + @per_batch)
     |> load_tasks()}
  end

  # Map gates atom coercion — see projects_live for the same shape.
  @reorder_strategies %{
    "name_asc" => :name_asc,
    "name_desc" => :name_desc,
    "created_asc" => :created_asc,
    "created_desc" => :created_desc,
    "reverse" => :reverse
  }

  def handle_event("apply_reorder", %{"strategy" => strategy_str}, socket)
      when is_map_key(@reorder_strategies, strategy_str) do
    strategy = Map.fetch!(@reorder_strategies, strategy_str)

    scope =
      case socket.assigns.captured_uuids do
        [] -> :all
        uuids -> uuids
      end

    case Projects.reorder_tasks_by(strategy, scope, actor_uuid: Activity.actor_uuid(socket)) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Tasks reordered."))
         |> assign(show_reorder_modal: false, captured_uuids: [])
         |> load_tasks()}

      {:error, :duplicate_positions} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Selected rows share positions. Apply \"Reorder all\" first to normalise."
           )
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not reorder tasks."))}
    end
  end

  def handle_event("apply_reorder", _params, socket) do
    {:noreply,
     put_flash(socket, :error, gettext("Pick a strategy before applying."))}
  end

  def handle_event("reorder_tasks", %{"ordered_ids" => ordered_ids} = params, socket)
      when is_list(ordered_ids) do
    moved_id = params["moved_id"]
    actor_uuid = Activity.actor_uuid(socket)

    case Projects.reorder_tasks(ordered_ids, actor_uuid: actor_uuid) do
      :ok ->
        {:noreply,
         socket
         |> push_event("sortable:flash", %{uuid: moved_id, status: "ok"})
         |> load_tasks()}

      {:error, :too_many_uuids} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Too many tasks to reorder at once."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_tasks()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not reorder tasks."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_tasks()}
    end
  end

  def handle_event("delete", %{"uuid" => uuid}, socket) do
    case Projects.get_task(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Task not found."))}

      task ->
        case Projects.delete_task(task) do
          {:ok, _} ->
            Activity.log("projects.task_deleted",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "task",
              resource_uuid: task.uuid,
              metadata: %{"title" => task.title}
            )

            {:noreply,
             socket
             |> WebHelpers.notify_deleted(:task, task.uuid)
             |> put_flash(:info, gettext("Task deleted."))
             |> load_tasks()}

          {:error, _} ->
            Activity.log_failed("projects.task_deleted",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "task",
              resource_uuid: task.uuid,
              metadata: %{"title" => task.title}
            )

            {:noreply, put_flash(socket, :error, gettext("Could not delete task."))}
        end
    end
  end

  defp sanitize_uuids(%{"uuids" => uuids}) when is_list(uuids) do
    Enum.filter(uuids, &is_binary/1)
  end

  defp sanitize_uuids(_), do: []

  defp format_duration(task) do
    PhoenixKitProjects.Schemas.Task.format_duration(
      task.estimated_duration,
      task.estimated_duration_unit
    )
  end

  # Flattens a closure tree to a unique-by-uuid task list. The root is
  # always first; everything else is in DFS order. The groups view
  # renders the result as a flat list of peer tasks (they are full
  # task templates, not subtasks) — the dep direction is shown by
  # each row's `→ X` badges, not by indentation.
  defp flatten_tree(tree), do: tree |> do_flatten_tree(MapSet.new()) |> elem(0)

  defp do_flatten_tree(%{cycle?: true}, seen), do: {[], seen}

  defp do_flatten_tree(%{task: task, children: children}, seen) do
    if MapSet.member?(seen, task.uuid) do
      {[], seen}
    else
      seen = MapSet.put(seen, task.uuid)

      {kids, seen} =
        Enum.reduce(children, {[], seen}, fn child, {acc, s} ->
          {child_tasks, s2} = do_flatten_tree(child, s)
          {acc ++ child_tasks, s2}
        end)

      {[task | kids], seen}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <.page_header
        title={gettext("Task Library")}
        description={gettext("Reusable task templates.")}
      >
        <:actions>
          <.smart_link
            navigate={Paths.new_task()}
            emit={{PhoenixKitProjects.Web.TaskFormLive, %{"live_action" => "new"}}}
            embed_mode={@embed_mode}
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New task")}
          </.smart_link>
        </:actions>
      </.page_header>

      <%!-- View toggle. UI state (not URL-driven) so the LV stays
           embeddable via `live_render`. The "list" view is the source
           of truth — flat, alphabetical, with per-row dep badges. The
           "groups" view re-renders the same tasks as rooted dep trees;
           tasks shared across multiple roots show in EACH group
           (intentional duplication, not a bug — that's how the view
           answers "where is this task reused?"). --%>
      <div role="tablist" class="tabs tabs-boxed self-start">
        <button
          type="button"
          phx-click="set_view"
          phx-value-view="list"
          role="tab"
          class={["tab gap-2", @view == "list" && "tab-active"]}
        >
          <.icon name="hero-list-bullet" class="w-4 h-4" /> {gettext("List")}
        </button>
        <button
          type="button"
          phx-click="set_view"
          phx-value-view="groups"
          role="tab"
          class={["tab gap-2", @view == "groups" && "tab-active"]}
        >
          <.icon name="hero-rectangle-group" class="w-4 h-4" /> {gettext("Groups")}
        </button>
      </div>

      <%= if @view == "groups" do %>
        <% lang = L10n.current_content_lang() %>

        <%= if @groups == [] and @standalone == [] do %>
          <.empty_state icon="hero-rectangle-stack" title={gettext("No tasks yet.")}>
            <:cta>
              <.smart_link
                navigate={Paths.new_task()}
                emit={{PhoenixKitProjects.Web.TaskFormLive, %{"live_action" => "new"}}}
                embed_mode={@embed_mode}
                class="link link-primary text-sm"
              >
                {gettext("Create your first")}
              </.smart_link>
            </:cta>
          </.empty_state>
        <% else %>
          <p class="text-xs text-base-content/60">
            {gettext("Each group is rooted at a task that nothing else depends on. Tasks reused across multiple groups appear in every one that pulls them in — they're independent task templates, the relationship is just a dependency.")}
          </p>

          <div class="flex flex-col gap-4">
            <%= for group <- @groups do %>
              <div class="card bg-base-100 shadow">
                <div class="card-body">
                  <%!-- Flat peer list — no nesting. Tasks are full
                       templates, not subtasks. Order is execution
                       order (prerequisites first, the rooted task
                       last); `→ X` dep badges are intentionally
                       omitted — those targets are right there in the
                       same list, so the badges would be redundant. --%>
                  <ul class="divide-y divide-base-200">
                    <%= for task <- group.peers do %>
                      <li class="flex items-center gap-2 py-2 first:pt-0 last:pb-0">
                        <.smart_link
                          navigate={Paths.edit_task(task.uuid)}
                          emit={{PhoenixKitProjects.Web.TaskFormLive, %{"live_action" => "edit", "id" => task.uuid}}}
                          embed_mode={@embed_mode}
                          class="text-sm font-medium link link-hover flex-1 min-w-0 truncate"
                        >
                          {TaskSchema.localized_title(task, lang)}
                        </.smart_link>
                        <span class="badge badge-ghost badge-xs shrink-0">
                          {format_duration(task)}
                        </span>
                      </li>
                    <% end %>
                  </ul>
                </div>
              </div>
            <% end %>
          </div>

          <%= if @standalone != [] do %>
            <div class="card bg-base-100 shadow">
              <div class="card-body">
                <h2 class="card-title text-base flex items-center gap-2">
                  <.icon name="hero-rectangle-stack" class="w-4 h-4 text-base-content/60" />
                  {gettext("Standalone")}
                </h2>
                <p class="text-xs text-base-content/60 -mt-1">
                  {gettext("Tasks with no dependency relationships yet.")}
                </p>
                <ul class="mt-2 space-y-1">
                  <li :for={task <- @standalone} class="flex items-center gap-2">
                    <.smart_link
                      navigate={Paths.edit_task(task.uuid)}
                      emit={{PhoenixKitProjects.Web.TaskFormLive, %{"live_action" => "edit", "id" => task.uuid}}}
                      embed_mode={@embed_mode}
                      class="text-sm link link-hover flex-1 min-w-0 truncate"
                    >
                      {TaskSchema.localized_title(task, lang)}
                    </.smart_link>
                    <span class="badge badge-ghost badge-xs shrink-0">
                      {format_duration(task)}
                    </span>
                  </li>
                </ul>
              </div>
            </div>
          <% end %>
        <% end %>
      <% else %>
        <%!-- Default flat list view. --%>
        <% lang = L10n.current_content_lang() %>

        <%= if @tasks == [] do %>
          <.empty_state icon="hero-rectangle-stack" title={gettext("No tasks yet.")}>
            <:cta>
              <.smart_link
                navigate={Paths.new_task()}
                emit={{PhoenixKitProjects.Web.TaskFormLive, %{"live_action" => "new"}}}
                embed_mode={@embed_mode}
                class="link link-primary text-sm"
              >
                {gettext("Create your first")}
              </.smart_link>
            </:cta>
          </.empty_state>
        <% else %>
          <.bulk_select_scope
            :if={@bulk_enabled?}
            id="tasks-bulk-scope"
            total_count={length(@tasks)}
            class="flex flex-col gap-2"
          >
            <.bulk_actions_toolbar
              on_open_reorder="open_reorder_modal"
              reorder_dialog_id="reorder-modal"
              noun_singular={gettext("task")}
              noun_plural={gettext("tasks")}
              allow_delete={false}
              reorder_gate={if @sort_by == :position, do: :always, else: :multi}
            >
              <:leading>
                <.sort_selector
                  sort_by={@sort_by}
                  sort_dir={@sort_dir}
                  options={sort_options()}
                  manual_field={:position}
                />
              </:leading>
            </.bulk_actions_toolbar>

            {render_tasks_table(assigns, lang)}
          </.bulk_select_scope>

          <%= if not @bulk_enabled? do %>
            <.sort_selector
              sort_by={@sort_by}
              sort_dir={@sort_dir}
              options={sort_options()}
              manual_field={:position}
            />
            {render_tasks_table(assigns, lang)}
          <% end %>
        <% end %>
      <% end %>

      <.reorder_modal
        show={@show_reorder_modal}
        on_close="close_reorder_modal"
        on_apply="apply_reorder"
        selected_count={length(@captured_uuids)}
        total_count={@total_count}
        strategies={[
          {"name_asc", gettext("A → Z by title")},
          {"name_desc", gettext("Z → A by title")},
          {"created_desc", gettext("Newest first")},
          {"created_asc", gettext("Oldest first")},
          {"reverse", gettext("Reverse current order")}
        ]}
        noun_singular={gettext("task")}
        noun_plural={gettext("tasks")}
      />
    </div>
    """
  end

  defp render_tasks_table(assigns, lang) do
    draggable? = assigns.sort_by == :position
    assigns = assign(assigns, lang: lang, draggable?: draggable?)

    ~H"""
    <%!-- DnD reorder is gated on `sort_by=:position` (the "manual"
         sort mode). When the list is sorted by title/date/duration
         the rendered order doesn't reflect the position field, so
         dragging would be lossy — the handle column is hidden too. --%>
    <.table_default id="tasks-list" size="sm">
      <.table_default_header>
        <.table_default_row>
          <.drag_handle_header_cell :if={@draggable?} />
          <.bulk_select_header_cell
            :if={@bulk_enabled?}
            id="tasks-select-all"
            aria_label={gettext("Select all tasks")}
          />
          <.sort_header_cell field={:title} sort={%{by: @sort_by, dir: @sort_dir}}>
            {gettext("Title")}
          </.sort_header_cell>
          <.sort_header_cell field={:estimated_duration} sort={%{by: @sort_by, dir: @sort_dir}}>
            {gettext("Duration")}
          </.sort_header_cell>
          <.table_default_header_cell class="text-right whitespace-nowrap">{gettext("Actions")}</.table_default_header_cell>
        </.table_default_row>
      </.table_default_header>
      <.sortable_tbody
        id="tasks-list-body"
        enabled={@draggable?}
        event="reorder_tasks"
      >
        <.sortable_row :for={task <- @tasks} item_id={task.uuid}>
          <.drag_handle_cell :if={@draggable?} />
          <.bulk_select_cell :if={@bulk_enabled?} value={task.uuid} />
          <.table_default_cell class="font-medium">
            {TaskSchema.localized_title(task, @lang)}
            <% desc = TaskSchema.localized_description(task, @lang) %>
            <div :if={desc} class="text-xs text-base-content/60 truncate max-w-md font-normal">{desc}</div>
            <% deps = Map.get(@deps_by_task, task.uuid, []) %>
            <div :if={deps != []} class="flex flex-wrap gap-1 mt-1.5">
              <span :for={dep <- deps} class="badge badge-outline badge-xs gap-1 font-normal">
                <.icon name="hero-arrow-right-circle" class="w-3 h-3" />
                {TaskSchema.localized_title(dep, @lang)}
              </span>
            </div>
          </.table_default_cell>
          <.table_default_cell>{format_duration(task)}</.table_default_cell>
          <.table_default_cell class="text-right whitespace-nowrap">
            <.table_row_menu id={"task-menu-#{task.uuid}"}>
              <.smart_menu_link
                navigate={Paths.edit_task(task.uuid)}
                emit={{PhoenixKitProjects.Web.TaskFormLive, %{"live_action" => "edit", "id" => task.uuid}}}
                embed_mode={@embed_mode}
                icon="hero-pencil"
                label={gettext("Edit")}
              />
              <.table_row_menu_divider />
              <.table_row_menu_button
                phx-click="delete"
                phx-value-uuid={task.uuid}
                phx-disable-with={gettext("Deleting…")}
                data-confirm={gettext("Delete task \"%{title}\"? Assignments using it will also be removed.", title: TaskSchema.localized_title(task, @lang))}
                icon="hero-trash"
                label={gettext("Delete")}
                variant="error"
              />
            </.table_row_menu>
          </.table_default_cell>
        </.sortable_row>
      </.sortable_tbody>
    </.table_default>

    <.load_more
      :if={@pagination == "load_more"}
      loaded={length(@tasks)}
      total={@total_count}
      noun_plural={gettext("tasks")}
    />
    """
  end
end
