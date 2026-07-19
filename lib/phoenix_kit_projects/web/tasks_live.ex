defmodule PhoenixKitProjects.Web.TasksLive do
  @moduledoc "List reusable task templates."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{Activity, L10n, Paths, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Task, as: TaskSchema
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers
  alias PhoenixKitProjects.Web.ListUi

  require Logger

  @valid_views ~w(list groups)

  # Default wrapper class for the standalone admin page. Embedders can
  # override via `live_render(... session: %{"wrapper_class" => "..."})`.
  # Tight vertical rhythm for short client screens (matches OverviewLive).
  @default_wrapper_class "flex flex-col w-full px-4 pt-2 pb-4 gap-4"

  # See projects_live for the same load-more pagination semantics.
  @per_batch 50
  @default_pagination "load_more"

  # Local/server search split — see TemplatesLive.
  @local_search_threshold 100

  # Optional table columns (Title and Actions always render), toggleable
  # from the Columns dropdown; persisted site-wide via ListUi. `uses` /
  # `last_used` count the assignments referencing each library task.
  @optional_columns ~w(duration uses last_used created updated created_by)
  @default_columns ~w(duration)
  @columns_key "projects_tasks_columns"

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
        # The create action lives in the admin breadcrumb (+ the
        # add-row under the list) — no in-content header row.
        page_action: %{
          icon: "hero-plus",
          label: gettext("New task"),
          navigate: Paths.new_task()
        },
        wrapper_class: wrapper_class,
        view: initial_view,
        pagination: pagination,
        # Recency default — most recently edited tasks first; manual
        # position order (and DnD) is one selector switch away.
        sort_by: :updated_at,
        sort_dir: :desc,
        loaded_count: @per_batch,
        total_count: 0,
        filtered_count: 0,
        local_search?: true,
        search: "",
        visible_columns:
          ListUi.read_visible_columns(@columns_key, @optional_columns, @default_columns),
        usage: %{},
        creators: %{},
        tasks: [],
        deps_by_task: %{},
        groups: [],
        standalone: [],
        bulk_enabled?: true,
        captured_uuids: [],
        show_reorder_modal: false
      )
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)
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
        load_list_tasks(socket)
    end
  end

  defp load_list_tasks(socket) do
    search = socket.assigns.search
    total = Projects.count_tasks()
    local_search? = total <= @local_search_threshold

    base_opts = [
      sort_by: socket.assigns.sort_by,
      sort_dir: socket.assigns.sort_dir
    ]

    # Local mode: full set rendered, search narrowing is the client
    # hook's job. Server mode: SQL search + load-more pagination.
    # See TemplatesLive.
    list_opts =
      if local_search? do
        base_opts
      else
        base_opts
        |> Keyword.put(:search, search)
        |> then(fn opts ->
          if socket.assigns.pagination == "load_more",
            do: Keyword.put(opts, :limit, socket.assigns.loaded_count),
            else: opts
        end)
      end

    %{tasks: tasks, deps_by_task: deps_by_task} = Projects.list_tasks_with_deps(list_opts)
    uuids = Enum.map(tasks, & &1.uuid)
    visible = socket.assigns.visible_columns

    assign(socket,
      tasks: tasks,
      deps_by_task: deps_by_task,
      groups: [],
      standalone: [],
      total_count: total,
      local_search?: local_search?,
      filtered_count: if(local_search?, do: total, else: Projects.count_tasks(search: search)),
      usage:
        if("uses" in visible or "last_used" in visible,
          do: Projects.task_usage(uuids),
          else: %{}
        ),
      creators:
        if("created_by" in visible,
          do: Projects.creation_actors(uuids, ["projects.task_created"]),
          else: %{}
        )
    )
  end

  @sort_fields ~w(position title inserted_at updated_at estimated_duration)a
  @sort_field_strs Enum.map(@sort_fields, &Atom.to_string/1)

  defp sort_options do
    [
      {:position, gettext("Manual")},
      {:title, gettext("Title")},
      {:inserted_at, gettext("Date created")},
      {:updated_at, gettext("Last edited")},
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

  def handle_event("load_more", _params, socket) do
    {:noreply,
     socket
     |> assign(loaded_count: socket.assigns.loaded_count + @per_batch)
     |> load_tasks()}
  end

  # See TemplatesLive for the search / toggle_column contracts.
  def handle_event("search", params, socket) do
    {:noreply,
     socket
     |> assign(search: ListUi.coerce_search(params), loaded_count: @per_batch)
     |> load_tasks()}
  end

  def handle_event("toggle_column", %{"col" => col}, socket) when col in @optional_columns do
    new_visible =
      ListUi.toggle_visible_column(
        @columns_key,
        @optional_columns,
        socket.assigns.visible_columns,
        col
      )

    {:noreply, socket |> assign(visible_columns: new_visible) |> load_tasks()}
  end

  def handle_event("toggle_column", _params, socket), do: {:noreply, socket}

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
           gettext("Selected rows share positions. Apply \"Reorder all\" first to normalise.")
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not reorder tasks."))}
    end
  end

  def handle_event("apply_reorder", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Pick a strategy before applying."))}
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

  # Sort change resets the load-more cap — see projects_live.
  defp apply_sort(socket, field, dir) do
    socket
    |> assign(sort_by: field, sort_dir: dir, loaded_count: @per_batch)
    |> load_tasks()
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

  defp prereq_count_label(0), do: gettext("No prerequisites — just the root.")
  defp prereq_count_label(1), do: gettext("1 prerequisite, then the root.")

  defp prereq_count_label(n),
    do: gettext("%{count} prerequisites, then the root.", count: n)

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
                  <%!-- Card title is the root task's name — the thing
                       this group is rooted at. Without a title, several
                       group cards stack visually as one undifferentiated
                       blob of lists; with it, each group's identity is
                       obvious at a glance. --%>
                  <h2 class="card-title text-base flex items-center gap-2">
                    <.icon name="hero-flag" class="w-4 h-4 text-primary" />
                    {TaskSchema.localized_title(group.root, lang)}
                  </h2>
                  <p class="text-xs text-base-content/60 -mt-1">
                    {prereq_count_label(length(group.peers) - 1)}
                  </p>

                  <%!-- Flat peer list — no nesting. Tasks are full
                       templates, not subtasks. Order is execution
                       order (prerequisites first, the rooted task
                       last); `→ X` dep badges are intentionally
                       omitted — those targets are right there in the
                       same list, so the badges would be redundant.
                       The root task gets a "root" badge so it stands
                       out from its prerequisites in the list. --%>
                  <ul class="divide-y divide-base-200 mt-2">
                    <%= for task <- group.peers do %>
                      <li class="flex items-center gap-2 py-2 first:pt-0 last:pb-0">
                        <.smart_link
                          navigate={Paths.edit_task(task.uuid)}
                          emit={{PhoenixKitProjects.Web.TaskFormLive, %{"live_action" => "edit", "id" => task.uuid}}}
                          embed_mode={@embed_mode}
                          class={[
                            "text-sm link link-hover flex-1 min-w-0 truncate",
                            task.uuid == group.root.uuid && "font-semibold",
                            task.uuid != group.root.uuid && "font-medium"
                          ]}
                        >
                          {TaskSchema.localized_title(task, lang)}
                        </.smart_link>
                        <span
                          :if={task.uuid == group.root.uuid}
                          class="badge badge-primary badge-xs shrink-0"
                        >
                          {gettext("root")}
                        </span>
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

        <%!-- True-empty install only — a no-match SEARCH must keep the
             toolbar on screen so the query can be cleared. --%>
        <%= if @total_count == 0 do %>
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
          >
            <div
              id="tasks-local-search"
              phx-hook="TableLocalSearch"
              data-local-search-enabled={to_string(@local_search?)}
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
                  {columns_control(assigns)}
                  <.search_toolbar
                    value={@search}
                    on_submit="search"
                    loading_indicator={not @local_search?}
                    placeholder={gettext("Search tasks...")}
                    class="w-48"
                  />
                </:leading>
              </.bulk_actions_toolbar>

              {render_tasks_table(assigns, lang)}

              <%!-- Server-truth when the SERVER filter empties the list;
                   the hook toggles the same node during the debounce gap. --%>
              <p
                data-local-search-empty
                class={[
                  "text-sm text-base-content/50 text-center py-2",
                  @tasks != [] && "hidden"
                ]}
              >
                {gettext("No tasks match.")}
              </p>

              <%!-- The create action, at the foot of the list (the header
                   row is gone — its "+" lives in the admin breadcrumb). --%>
              <.smart_link
                navigate={Paths.new_task()}
                emit={{PhoenixKitProjects.Web.TaskFormLive, %{"live_action" => "new"}}}
                embed_mode={@embed_mode}
                class="btn btn-ghost btn-sm w-full justify-start border border-dashed border-base-300 text-base-content/60 hover:text-base-content hover:border-base-content/40"
              >
                <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New task")}
              </.smart_link>
            </div>
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

  defp column_options do
    [
      {"duration", gettext("Duration")},
      {"uses", gettext("Uses")},
      {"last_used", gettext("Last used")},
      {"created", gettext("Created")},
      {"updated", gettext("Last edited")},
      {"created_by", gettext("Created by")}
    ]
  end

  # The Columns dropdown — same focus-based pattern as TemplatesLive.
  defp columns_control(assigns) do
    ~H"""
    <div class="dropdown">
      <div tabindex="0" role="button" class="btn btn-sm">
        <.icon name="hero-view-columns" class="w-4 h-4" /> {gettext("Columns")}
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-100 rounded-box z-20 w-44 p-2 shadow-md border border-base-200"
      >
        <li :for={{col, label} <- column_options()}>
          <label class="flex items-center gap-2 cursor-pointer">
            <input
              type="checkbox"
              class="checkbox checkbox-sm"
              checked={col in @visible_columns}
              phx-click="toggle_column"
              phx-value-col={col}
            />
            {label}
          </label>
        </li>
      </ul>
    </div>
    """
  end

  defp render_tasks_table(assigns, lang) do
    draggable? = assigns.sort_by == :position and String.trim(assigns.search) == ""
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
          <.sort_header_cell
            :if={"duration" in @visible_columns}
            field={:estimated_duration}
            sort={%{by: @sort_by, dir: @sort_dir}}
          >
            {gettext("Duration")}
          </.sort_header_cell>
          <.table_default_header_cell :if={"uses" in @visible_columns} class="text-right">
            {gettext("Uses")}
          </.table_default_header_cell>
          <.table_default_header_cell :if={"last_used" in @visible_columns}>
            {gettext("Last used")}
          </.table_default_header_cell>
          <.sort_header_cell
            :if={"created" in @visible_columns}
            field={:inserted_at}
            sort={%{by: @sort_by, dir: @sort_dir}}
          >
            {gettext("Created")}
          </.sort_header_cell>
          <.sort_header_cell
            :if={"updated" in @visible_columns}
            field={:updated_at}
            sort={%{by: @sort_by, dir: @sort_dir}}
          >
            {gettext("Last edited")}
          </.sort_header_cell>
          <.table_default_header_cell :if={"created_by" in @visible_columns}>
            {gettext("Created by")}
          </.table_default_header_cell>
          <.table_default_header_cell class="text-right whitespace-nowrap">{gettext("Actions")}</.table_default_header_cell>
        </.table_default_row>
      </.table_default_header>
      <.sortable_tbody
        id="tasks-list-body"
        enabled={@draggable?}
        event="reorder_tasks"
      >
        <.sortable_row
          :for={task <- @tasks}
          item_id={task.uuid}
          data-search={ListUi.search_haystack(task, ["title", "description"])}
        >
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
          <.table_default_cell :if={"duration" in @visible_columns}>
            {format_duration(task)}
          </.table_default_cell>
          <.table_default_cell
            :if={"uses" in @visible_columns}
            class="text-right tabular-nums text-base-content/70"
          >
            {get_in(@usage, [task.uuid, :count]) || 0}
          </.table_default_cell>
          <.table_default_cell
            :if={"last_used" in @visible_columns}
            class="whitespace-nowrap text-base-content/70"
          >
            {case get_in(@usage, [task.uuid, :last_used]) do
              nil -> "—"
              at -> L10n.format_date(at)
            end}
          </.table_default_cell>
          <.table_default_cell
            :if={"created" in @visible_columns}
            class="whitespace-nowrap text-base-content/70"
          >
            {L10n.format_date(task.inserted_at)}
          </.table_default_cell>
          <.table_default_cell
            :if={"updated" in @visible_columns}
            class="whitespace-nowrap text-base-content/70"
          >
            {L10n.format_date(task.updated_at)}
          </.table_default_cell>
          <.table_default_cell
            :if={"created_by" in @visible_columns}
            class="whitespace-nowrap text-base-content/70"
          >
            {Map.get(@creators, task.uuid) || "—"}
          </.table_default_cell>
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

    <%!-- Hidden in local mode: everything is on screen. --%>
    <.load_more
      :if={@pagination == "load_more" and not @local_search?}
      loaded={length(@tasks)}
      total={@filtered_count}
      noun_plural={gettext("tasks")}
    />
    """
  end
end
