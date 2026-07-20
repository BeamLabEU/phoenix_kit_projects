defmodule PhoenixKitProjects.Web.TemplatesLive do
  @moduledoc "List project templates."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{Activity, L10n, Paths, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers
  alias PhoenixKitProjects.Web.ListUi

  require Logger

  # Default wrapper class for the standalone admin page. Embedders can
  # override via `live_render(... session: %{"wrapper_class" => "..."})`.
  # Tight vertical rhythm for short client screens (matches OverviewLive).
  @default_wrapper_class "flex flex-col w-full px-4 pt-2 pb-4 gap-4"

  # Load-more batch size and default pagination mode (mirrors
  # ProjectsLive / TasksLive; embedders can override pagination via
  # `session: %{"pagination" => "off"}`).
  @per_batch 50
  @default_pagination "load_more"

  # At or below this many templates the WHOLE list is loaded and the
  # TableLocalSearch hook narrows rows client-side (instant, no
  # round-trip wait) while the debounced server search stays the
  # authority. Above it, pagination + pure server search take over —
  # client narrowing over a partial row set would falsely report
  # "no matches" for rows beyond the loaded page.
  @local_search_threshold 100

  @sort_fields ~w(position name inserted_at updated_at)a
  @sort_field_strs Enum.map(@sort_fields, &Atom.to_string/1)

  # Map gates atom coercion: a crafted payload can't smuggle in an
  # unknown atom (same rationale as ProjectsLive).
  @reorder_strategies %{
    "name_asc" => :name_asc,
    "name_desc" => :name_desc,
    "created_asc" => :created_asc,
    "created_desc" => :created_desc,
    "reverse" => :reverse
  }

  # Optional table columns, toggleable from the Columns dropdown (Name
  # and Actions always render). Visibility persists site-wide in
  # settings — same custody as the calendar/gantt display config.
  # `tasks` and `created_by` need batched lookup maps; load_templates
  # only runs those queries while the column is visible.
  @optional_columns ~w(weekends tasks uses last_used created updated created_by external_id)
  @default_columns ~w(weekends)
  @columns_key "projects_templates_columns"

  @impl true
  def mount(_params, session, socket) do
    WebHelpers.maybe_put_locale(session)

    if connected?(socket), do: ProjectsPubSub.subscribe(ProjectsPubSub.topic_templates())

    wrapper_class = Map.get(session, "wrapper_class", @default_wrapper_class)
    pagination = Map.get(session, "pagination", @default_pagination)

    socket =
      socket
      |> assign(
        page_title: gettext("Project Templates"),
        # The primary create action lives in the admin header's
        # breadcrumb row (core `page_action`) + a dashed add-row under
        # the list — no in-content header row at all (short screens).
        # Ignored in embed mode (no admin layout); the add-row covers it.
        page_action: %{
          icon: "hero-plus",
          label: gettext("New template"),
          navigate: Paths.new_template()
        },
        wrapper_class: wrapper_class,
        pagination: pagination,
        # Default to recency ("Last edited", newest first) so the most
        # relevant templates surface at the top. Manual position order
        # (and with it drag-reorder) is one selector switch away.
        sort_by: :updated_at,
        sort_dir: :desc,
        # Load-more pagination state (same shape as ProjectsLive):
        # `loaded_count` caps visible rows, `total_count` is the DB
        # total. Reset to @per_batch on sort change, NOT on DnD drop.
        loaded_count: @per_batch,
        # `total_count` = ALL templates (drives the reorder modal's
        # honest "Reorder all N" — strategies apply to the full set,
        # search or not). `filtered_count` = search-aware total for
        # the load-more footer.
        total_count: 0,
        filtered_count: 0,
        local_search?: true,
        search: "",
        templates: [],
        # Snapshot of the client-side bulk selection, captured when an
        # action button is clicked (BulkSelectScope hook).
        captured_uuids: [],
        show_reorder_modal: false,
        visible_columns:
          ListUi.read_visible_columns(@columns_key, @optional_columns, @default_columns),
        # Batched per-row lookup maps for the tasks / uses / created_by
        # columns — filled by load_templates only while visible.
        task_counts: %{},
        usage: %{},
        creators: %{}
      )
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)
      |> WebHelpers.attach_open_embed_hook()

    # Load on both disconnected + connected mount so the first paint has
    # real content. `handle_params/3` is intentionally absent — see
    # dev_docs/embedding_audit.md.
    {:ok, load_templates(socket)}
  end

  defp load_templates(socket) do
    search = socket.assigns.search
    total = Projects.count_templates()
    local_search? = total <= @local_search_threshold

    base_opts = [
      sort_by: socket.assigns.sort_by,
      sort_dir: socket.assigns.sort_dir
    ]

    # Local mode keeps the ENTIRE (<= threshold) set rendered — the SQL
    # search is deliberately NOT applied, so the client hook can re-show
    # any in-memory row the moment the query changes, with no server
    # round-trip. Past the threshold, search + pagination are all SQL.
    list_opts =
      if local_search?,
        do: base_opts,
        else:
          base_opts
          |> Keyword.put(:search, search)
          |> then(fn opts ->
            if socket.assigns.pagination == "load_more",
              do: Keyword.put(opts, :limit, socket.assigns.loaded_count),
              else: opts
          end)

    templates = Projects.list_templates(list_opts)
    uuids = Enum.map(templates, & &1.uuid)
    visible = socket.assigns.visible_columns

    assign(socket,
      templates: templates,
      total_count: total,
      local_search?: local_search?,
      # Only meaningful in server mode (drives the load-more footer);
      # local mode shows the full set, so the count is just the total.
      filtered_count:
        if(local_search?, do: total, else: Projects.count_templates(search: search)),
      task_counts:
        if("tasks" in visible, do: Projects.assignment_counts_for_projects(uuids), else: %{}),
      usage:
        if("uses" in visible or "last_used" in visible,
          do: Projects.template_usage(uuids),
          else: %{}
        ),
      creators: if("created_by" in visible, do: Projects.template_creators(uuids), else: %{})
    )
  end

  defp sort_options do
    [
      {:position, gettext("Manual")},
      {:name, gettext("Name")},
      {:inserted_at, gettext("Date created")},
      {:updated_at, gettext("Last edited")}
    ]
  end

  defp column_options do
    [
      {"weekends", gettext("Weekends")},
      {"tasks", gettext("Tasks")},
      {"uses", gettext("Uses")},
      {"last_used", gettext("Last used")},
      {"created", gettext("Created")},
      {"updated", gettext("Last edited")},
      {"created_by", gettext("Created by")},
      {"external_id", gettext("External ID")}
    ]
  end

  @impl true
  def handle_info({:projects, _event, _payload}, socket) do
    {:noreply, load_templates(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[TemplatesLive] unexpected handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true

  # Sort selector fires `sort_form` for both field changes (form
  # phx-change) and direction toggles (button phx-click). One event,
  # two shapes — derive the missing half from current state.
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

  # Header-click sort: clicking the active column flips direction,
  # clicking a different column switches to it with :asc.
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
     |> load_templates()}
  end

  # The search box (core `<.search_toolbar>`, 300ms debounce). A new
  # query resets the load-more cap so results start at the first batch.
  # Non-binary payloads (a forged `search[x]=y` arrives as a map) are
  # coerced to "" — the query side would shrug them off, but rendering
  # a map back into the input's `value` would crash the LV.
  def handle_event("search", params, socket) do
    {:noreply,
     socket
     |> assign(search: ListUi.coerce_search(params), loaded_count: @per_batch)
     |> load_templates()}
  end

  def handle_event("toggle_column", %{"col" => col}, socket) when col in @optional_columns do
    new_visible =
      ListUi.toggle_visible_column(
        @columns_key,
        @optional_columns,
        socket.assigns.visible_columns,
        col
      )

    # Reload so a newly-shown tasks / created_by column gets its
    # batched lookup map (hidden columns skip those queries).
    {:noreply, socket |> assign(visible_columns: new_visible) |> load_templates()}
  end

  def handle_event("toggle_column", _params, socket), do: {:noreply, socket}

  # Empty (or single-row) selection collapses to :all — the button
  # label reads "Reorder all" in those states and a single-row permute
  # is a no-op (same contract as ProjectsLive).
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

  def handle_event("apply_reorder", %{"strategy" => strategy_str}, socket)
      when is_map_key(@reorder_strategies, strategy_str) do
    strategy = Map.fetch!(@reorder_strategies, strategy_str)

    scope =
      case socket.assigns.captured_uuids do
        [] -> :all
        uuids -> uuids
      end

    case Projects.reorder_templates_by(strategy, scope, actor_uuid: Activity.actor_uuid(socket)) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Templates reordered."))
         |> assign(show_reorder_modal: false, captured_uuids: [])
         |> load_templates()}

      {:error, :wrong_scope} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Selection no longer valid; please reselect."))
         |> assign(show_reorder_modal: false, captured_uuids: [])
         |> load_templates()}

      {:error, :duplicate_positions} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Selected rows share positions. Apply \"Reorder all\" first to normalise.")
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not reorder templates."))}
    end
  end

  # Empty submit (no radio chosen) or a forged strategy string.
  def handle_event("apply_reorder", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Pick a strategy before applying."))}
  end

  def handle_event("reorder_templates", %{"ordered_ids" => ordered_ids} = params, socket)
      when is_list(ordered_ids) do
    moved_id = params["moved_id"]

    case Projects.reorder_templates(ordered_ids, actor_uuid: Activity.actor_uuid(socket)) do
      :ok ->
        {:noreply,
         socket
         |> push_event("sortable:flash", %{uuid: moved_id, status: "ok"})
         |> load_templates()}

      {:error, :too_many_uuids} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Too many templates to reorder at once."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_templates()}

      {:error, :wrong_scope} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Template list changed; please try again."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_templates()}
    end
  end

  def handle_event("delete", %{"uuid" => uuid}, socket) do
    case Projects.get_project(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Template not found."))}

      template ->
        case Projects.delete_project(template) do
          {:ok, _} ->
            Activity.log("projects.template_deleted",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "project_template",
              resource_uuid: template.uuid,
              metadata: %{"name" => template.name}
            )

            {:noreply,
             socket
             |> WebHelpers.notify_deleted(:template, template.uuid)
             |> put_flash(:info, gettext("Template deleted."))
             |> load_templates()}

          {:error, _} ->
            Activity.log_failed("projects.template_deleted",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "project_template",
              resource_uuid: template.uuid,
              metadata: %{"name" => template.name}
            )

            {:noreply, put_flash(socket, :error, gettext("Could not delete template."))}
        end
    end
  end

  # Sort change resets the load-more cap so the new order starts at
  # its first batch rather than keeping a stale deep page.
  defp apply_sort(socket, field, dir) do
    socket
    |> assign(sort_by: field, sort_dir: dir, loaded_count: @per_batch)
    |> load_templates()
  end

  defp sanitize_uuids(%{"uuids" => uuids}) when is_list(uuids) do
    Enum.filter(uuids, &is_binary/1)
  end

  defp sanitize_uuids(_), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <%!-- True-empty install only — a no-match SEARCH must keep the
           toolbar on screen or the user can't clear their query. --%>
      <%= if @total_count == 0 do %>
        <.empty_state icon="hero-document-duplicate" title={gettext("No templates yet.")}>
          <:cta>
            <.smart_link
              navigate={Paths.new_template()}
              emit={{PhoenixKitProjects.Web.TemplateFormLive, %{"live_action" => "new"}}}
              embed_mode={@embed_mode}
              class="link link-primary text-sm"
            >
              {gettext("Create your first")}
            </.smart_link>
          </:cta>
        </.empty_state>
      <% else %>
        <%!-- DnD applies only in "manual" sort (sort_by=:position) AND
             with no active search: sorting by name / date is a *view*
             (dragging would be lossy), and a search shows a sparse
             subset — the DnD handler renumbers the dropped list to
             1..N absolute positions, which would collide with the
             hidden rows' slots and scramble the global manual order.
             Same hazard for a load-more-truncated page, so DnD also
             waits for the full set to be loaded (local-search mode
             always loads it all). --%>
        <% lang = L10n.current_content_lang() %>
        <% draggable? =
          @sort_by == :position and String.trim(@search) == "" and
            (@local_search? or @loaded_count >= @total_count) %>

        <.bulk_select_scope id="templates-bulk-scope" total_count={length(@templates)}>
          <div
            id="templates-local-search"
            phx-hook="TableLocalSearch"
            data-local-search-enabled={to_string(@local_search?)}
            class="flex flex-col gap-2"
          >
          <.bulk_actions_toolbar
            on_open_reorder="open_reorder_modal"
            reorder_dialog_id="reorder-modal"
            noun_singular={gettext("template")}
            noun_plural={gettext("templates")}
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
              <ListUi.columns_control options={column_options()} visible={@visible_columns} />
              <%!-- on_submit is required, not optional: it selects the
                   component's <form> branch. The formless branch's
                   phx-change dies in LV's pushInput ("form events
                   require the input to be inside a form"). Enter just
                   re-fires the same debounced search event. --%>
              <.search_toolbar
                value={@search}
                on_submit="search"
                loading_indicator={not @local_search?}
                placeholder={gettext("Search templates...")}
                class="w-48"
              />
            </:leading>
          </.bulk_actions_toolbar>

            {render_templates_table(assigns, draggable?, lang)}

            <%!-- Server-truth when the SERVER filter empties the list;
                 the TableLocalSearch hook toggles the same node during
                 the debounce gap. --%>
            <p
              data-local-search-empty
              class={[
                "text-sm text-base-content/50 text-center py-2",
                @templates != [] && "hidden"
              ]}
            >
              {gettext("No templates match.")}
            </p>

            <%!-- The create action, at the foot of the list (the header
                 row is gone — its "+" lives in the admin breadcrumb). --%>
            <.smart_link
              navigate={Paths.new_template()}
              emit={{PhoenixKitProjects.Web.TemplateFormLive, %{"live_action" => "new"}}}
              embed_mode={@embed_mode}
              class="btn btn-ghost btn-sm w-full justify-start border border-dashed border-base-300 text-base-content/60 hover:text-base-content hover:border-base-content/40"
            >
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New template")}
            </.smart_link>
          </div>
        </.bulk_select_scope>
      <% end %>

      <.reorder_modal
        show={@show_reorder_modal}
        on_close="close_reorder_modal"
        on_apply="apply_reorder"
        selected_count={length(@captured_uuids)}
        total_count={@total_count}
        strategies={[
          {"name_asc", gettext("A → Z by name")},
          {"name_desc", gettext("Z → A by name")},
          {"created_desc", gettext("Newest first")},
          {"created_asc", gettext("Oldest first")},
          {"reverse", gettext("Reverse current order")}
        ]}
        noun_singular={gettext("template")}
        noun_plural={gettext("templates")}
      />
    </div>
    """
  end

  # Extracted so a future bulk-disabled branch can reuse it (same
  # shape as ProjectsLive's render_projects_table).
  defp render_templates_table(assigns, draggable?, lang) do
    assigns = assign(assigns, draggable?: draggable?, lang: lang)

    ~H"""
    <.table_default id="templates-list" size="sm">
      <.table_default_header>
        <.table_default_row>
          <.drag_handle_header_cell :if={@draggable?} />
          <.bulk_select_header_cell
            id="templates-select-all"
            aria_label={gettext("Select all templates")}
          />
          <.sort_header_cell field={:name} sort={%{by: @sort_by, dir: @sort_dir}}>
            {gettext("Name")}
          </.sort_header_cell>
          <.table_default_header_cell :if={"weekends" in @visible_columns}>
            {gettext("Weekends")}
          </.table_default_header_cell>
          <.table_default_header_cell :if={"tasks" in @visible_columns} class="text-right">
            {gettext("Tasks")}
          </.table_default_header_cell>
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
          <.table_default_header_cell :if={"external_id" in @visible_columns}>
            {gettext("External ID")}
          </.table_default_header_cell>
          <.table_default_header_cell class="text-right whitespace-nowrap">
            {gettext("Actions")}
          </.table_default_header_cell>
        </.table_default_row>
      </.table_default_header>
      <.sortable_tbody id="templates-list-body" enabled={@draggable?} event="reorder_templates">
        <.sortable_row :for={t <- @templates} item_id={t.uuid} data-search={ListUi.search_haystack(t, ["name", "description"])}>
          <.drag_handle_cell :if={@draggable?} />
          <.bulk_select_cell value={t.uuid} />
          <.table_default_cell class="font-medium">
            <.smart_link
              navigate={Paths.template(t.uuid)}
              emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => t.uuid}}}
              embed_mode={@embed_mode}
              class="link link-hover"
            >
              {Project.localized_name(t, @lang)}
            </.smart_link>
            <% desc = Project.localized_description(t, @lang) %>
            <div :if={desc} class="text-xs text-base-content/60 truncate max-w-md">{desc}</div>
          </.table_default_cell>
          <.table_default_cell :if={"weekends" in @visible_columns}>
            <span class={"badge badge-xs #{if t.counts_weekends, do: "badge-info", else: "badge-ghost"}"}>
              {if t.counts_weekends, do: gettext("yes"), else: gettext("no")}
            </span>
          </.table_default_cell>
          <.table_default_cell
            :if={"tasks" in @visible_columns}
            class="text-right tabular-nums text-base-content/70"
          >
            {Map.get(@task_counts, t.uuid, 0)}
          </.table_default_cell>
          <.table_default_cell
            :if={"uses" in @visible_columns}
            class="text-right tabular-nums text-base-content/70"
          >
            {get_in(@usage, [t.uuid, :count]) || 0}
          </.table_default_cell>
          <.table_default_cell
            :if={"last_used" in @visible_columns}
            class="whitespace-nowrap text-base-content/70"
          >
            {case get_in(@usage, [t.uuid, :last_used]) do
              nil -> "—"
              at -> L10n.format_date(at)
            end}
          </.table_default_cell>
          <.table_default_cell
            :if={"created" in @visible_columns}
            class="whitespace-nowrap text-base-content/70"
          >
            {L10n.format_date(t.inserted_at)}
          </.table_default_cell>
          <.table_default_cell
            :if={"updated" in @visible_columns}
            class="whitespace-nowrap text-base-content/70"
          >
            {L10n.format_date(t.updated_at)}
          </.table_default_cell>
          <.table_default_cell
            :if={"created_by" in @visible_columns}
            class="whitespace-nowrap text-base-content/70"
          >
            {Map.get(@creators, t.uuid) || "—"}
          </.table_default_cell>
          <.table_default_cell
            :if={"external_id" in @visible_columns}
            class="font-mono text-xs text-base-content/70"
          >
            {t.external_id || "—"}
          </.table_default_cell>
          <.table_default_cell class="text-right whitespace-nowrap">
            <.table_row_menu id={"template-menu-#{t.uuid}"}>
              <.smart_menu_link
                navigate={Paths.edit_template(t.uuid)}
                emit={{PhoenixKitProjects.Web.TemplateFormLive, %{"live_action" => "edit", "id" => t.uuid}}}
                embed_mode={@embed_mode}
                icon="hero-pencil"
                label={gettext("Edit")}
              />
              <.table_row_menu_divider />
              <.table_row_menu_button
                phx-click="delete"
                phx-value-uuid={t.uuid}
                phx-disable-with={gettext("Deleting…")}
                data-confirm={gettext("Delete template \"%{name}\"?", name: Project.localized_name(t, @lang))}
                icon="hero-trash"
                label={gettext("Delete")}
                variant="error"
              />
            </.table_row_menu>
          </.table_default_cell>
        </.sortable_row>
      </.sortable_tbody>
    </.table_default>

    <%!-- Hidden in local mode: everything is on screen, and a
         "Showing N of N" line would contradict a client-filtered view. --%>
    <.load_more
      :if={@pagination == "load_more" and not @local_search?}
      loaded={length(@templates)}
      total={@filtered_count}
      noun_plural={gettext("templates")}
    />
    """
  end
end
