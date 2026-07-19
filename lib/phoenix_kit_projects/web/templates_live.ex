defmodule PhoenixKitProjects.Web.TemplatesLive do
  @moduledoc "List project templates."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{Activity, L10n, Paths, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

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
  @optional_columns ~w(weekends created updated)
  @default_columns ~w(weekends)
  @columns_key "projects_templates_columns"
  @settings_module "projects"

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
        wrapper_class: wrapper_class,
        pagination: pagination,
        sort_by: :position,
        sort_dir: :asc,
        # Load-more pagination state (same shape as ProjectsLive):
        # `loaded_count` caps visible rows, `total_count` is the DB
        # total. Reset to @per_batch on sort change, NOT on DnD drop.
        loaded_count: @per_batch,
        total_count: 0,
        templates: [],
        # Snapshot of the client-side bulk selection, captured when an
        # action button is clicked (BulkSelectScope hook).
        captured_uuids: [],
        show_reorder_modal: false,
        visible_columns: read_visible_columns()
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
    base_opts = [sort_by: socket.assigns.sort_by, sort_dir: socket.assigns.sort_dir]

    list_opts =
      case socket.assigns.pagination do
        "load_more" -> Keyword.put(base_opts, :limit, socket.assigns.loaded_count)
        _ -> base_opts
      end

    assign(socket,
      templates: Projects.list_templates(list_opts),
      total_count: Projects.count_templates()
    )
  end

  # Stored as a comma-joined list so one settings row carries the whole
  # set. `nil` (never saved) falls back to the defaults; an empty string
  # is a deliberate "all optional columns hidden". Unknown names are
  # dropped and order is normalized to @optional_columns.
  defp read_visible_columns do
    case PhoenixKit.Settings.get_settings_direct([@columns_key])[@columns_key] do
      nil ->
        @default_columns

      stored when is_binary(stored) ->
        chosen = stored |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
        Enum.filter(@optional_columns, &(&1 in chosen))
    end
  end

  defp sort_options do
    [
      {:position, gettext("Manual")},
      {:name, gettext("Name")},
      {:inserted_at, gettext("Date created")},
      {:updated_at, gettext("Last updated")}
    ]
  end

  defp column_options do
    [
      {"weekends", gettext("Weekends")},
      {"created", gettext("Created")},
      {"updated", gettext("Updated")}
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

  def handle_event("toggle_column", %{"col" => col}, socket) when col in @optional_columns do
    visible = socket.assigns.visible_columns

    new_visible =
      if col in visible,
        do: List.delete(visible, col),
        else: Enum.filter(@optional_columns, &(&1 in [col | visible]))

    PhoenixKit.Settings.update_setting_with_module(
      @columns_key,
      Enum.join(new_visible, ","),
      @settings_module
    )

    {:noreply, assign(socket, visible_columns: new_visible)}
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
      <.page_header compact title={gettext("Project Templates")}>
        <:actions>
          <.smart_link
            navigate={Paths.new_template()}
            emit={{PhoenixKitProjects.Web.TemplateFormLive, %{"live_action" => "new"}}}
            embed_mode={@embed_mode}
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New template")}
          </.smart_link>
        </:actions>
      </.page_header>

      <%= if @templates == [] do %>
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
        <%!-- DnD applies only in "manual" sort (sort_by=:position) —
             sorting by name / date is a *view*, dragging in it would be
             lossy, so the handle is hidden (same as ProjectsLive). --%>
        <% lang = L10n.current_content_lang() %>
        <% draggable? = @sort_by == :position %>

        <.bulk_select_scope
          id="templates-bulk-scope"
          total_count={length(@templates)}
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
              {columns_control(assigns)}
            </:leading>
          </.bulk_actions_toolbar>

          {render_templates_table(assigns, draggable?, lang)}
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

  # The Columns dropdown: focus-based daisyUI dropdown (closes when
  # focus leaves) with one checkbox per optional column. Kept open
  # while toggling — the checkbox retains focus through the patch.
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
            {gettext("Updated")}
          </.sort_header_cell>
          <.table_default_header_cell class="text-right whitespace-nowrap">
            {gettext("Actions")}
          </.table_default_header_cell>
        </.table_default_row>
      </.table_default_header>
      <.sortable_tbody id="templates-list-body" enabled={@draggable?} event="reorder_templates">
        <.sortable_row :for={t <- @templates} item_id={t.uuid}>
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

    <.load_more
      :if={@pagination == "load_more"}
      loaded={length(@templates)}
      total={@total_count}
      noun_plural={gettext("templates")}
    />
    """
  end
end
