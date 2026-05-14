defmodule PhoenixKitProjects.Web.TasksLive do
  @moduledoc "List reusable task templates."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{Activity, L10n, Paths, Projects}
  alias PhoenixKitProjects.Web.Helpers
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Task, as: TaskSchema
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  require Logger

  @valid_views ~w(list groups)

  # Default wrapper class for the standalone admin page. Embedders can
  # override via `live_render(... session: %{"wrapper_class" => "..."})`.
  @default_wrapper_class "flex flex-col mx-auto max-w-5xl px-4 py-6 gap-4"

  @impl true
  def mount(_params, session, socket) do
    Helpers.maybe_put_locale(session)

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

    socket =
      socket
      |> assign(
        page_title: gettext("Task Library"),
        wrapper_class: wrapper_class,
        view: initial_view,
        tasks: [],
        deps_by_task: %{},
        groups: [],
        standalone: []
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
        %{tasks: tasks, deps_by_task: deps_by_task} = Projects.list_tasks_with_deps()
        assign(socket, tasks: tasks, deps_by_task: deps_by_task, groups: [], standalone: [])
    end
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
    {:noreply, socket |> assign(view: view) |> load_tasks()}
  end

  def handle_event("set_view", _params, socket), do: {:noreply, socket}

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
          <%!-- DnD reorder is wired only on the list view (groups are
               derived from the dep graph and don't have a stable
               manual order). Per-row body uses the sortable_table
               component's :col slots; SortableJS knockout-of-table-
               layout is handled by `align-middle` cells inside the
               component. --%>
          <.sortable_table
            id="tasks-list-body"
            rows={@tasks}
            row_id={& &1.uuid}
            event="reorder_tasks"
          >
            <:col :let={task} label={gettext("Title")}>
              <div class="font-medium">{TaskSchema.localized_title(task, lang)}</div>
              <% desc = TaskSchema.localized_description(task, lang) %>
              <div :if={desc} class="text-xs text-base-content/60 truncate max-w-md">{desc}</div>
              <% deps = Map.get(@deps_by_task, task.uuid, []) %>
              <div :if={deps != []} class="flex flex-wrap gap-1 mt-1.5">
                <span :for={dep <- deps} class="badge badge-outline badge-xs gap-1">
                  <.icon name="hero-arrow-right-circle" class="w-3 h-3" />
                  {TaskSchema.localized_title(dep, lang)}
                </span>
              </div>
            </:col>
            <:col :let={task} label={gettext("Duration")}>{format_duration(task)}</:col>
            <:col :let={task} label={gettext("Actions")} class="text-right">
              <div class="flex items-center justify-end gap-1">
                <.smart_link
                  navigate={Paths.edit_task(task.uuid)}
                  emit={{PhoenixKitProjects.Web.TaskFormLive, %{"live_action" => "edit", "id" => task.uuid}}}
                  embed_mode={@embed_mode}
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                </.smart_link>
                <button
                  type="button"
                  phx-click="delete"
                  phx-value-uuid={task.uuid}
                  phx-disable-with={gettext("Deleting…")}
                  data-confirm={gettext("Delete task \"%{title}\"? Assignments using it will also be removed.", title: TaskSchema.localized_title(task, lang))}
                  class="btn btn-ghost btn-xs text-error"
                >
                  <.icon name="hero-trash" class="w-3.5 h-3.5" />
                </button>
              </div>
            </:col>
          </.sortable_table>
        <% end %>
      <% end %>
    </div>
    """
  end
end
