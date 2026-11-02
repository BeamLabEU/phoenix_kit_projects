defmodule PhoenixKitProjects.Web.ProjectsLive do
  @moduledoc "List projects."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  # Declared up here because the `use UrlState` below evaluates its options in
  # the module body, so the whitelist has to exist by then.
  # Every sort the list accepts: the four the database orders, and one per
  # sortable column (`Web.ProjectListColumns`), which the list orders itself.
  @sort_fields PhoenixKitProjects.Web.ProjectListColumns.sort_fields()
  @sort_field_strs Enum.map(@sort_fields, &Atom.to_string/1)
  @state_filters ["" | PhoenixKitProjects.Web.ProjectListColumns.states()]

  # Search, status filter and sort live in the query string, so a filtered list
  # is a real URL: shareable, reload-proof, and Back returns to the previous
  # query instead of leaving the page.
  #
  # `mode: :history` rather than the default — this LiveView is embeddable via
  # live_render/3 (dev_docs/embedding_audit.md, pinned by the tests in
  # test/.../embedding_test.exs), and :patch would export handle_params/3,
  # which is exactly what makes a LiveView un-embeddable. The browser owns the
  # URL here instead; `<.url_state_sync mode={:history} />` in the template
  # carries the hook that does it.
  #
  # `status_filter` carries no `in:` on purpose: the slugs come from the shared
  # entities catalog and are open-ended, so a fixed whitelist would reject the
  # very options the dropdown offers.
  use PhoenixKitWeb.Live.UrlState,
    mode: :history,
    params: [
      search: [default: "", url_key: "q"],
      status_filter: [default: nil, url_key: "status"],
      sort_by: [default: :updated_at, cast: :atom, in: @sort_fields, url_key: "sort"],
      sort_dir: [default: :desc, cast: :atom, in: [:asc, :desc], url_key: "dir"],
      # Which extension column `sort=ext` means. An id is open-ended (the
      # catalog's), so it is checked against the loaded columns when used.
      sort_ext: [default: "", url_key: "sortx"],
      # The filters panel (`Web.ProjectListColumns`' filters). `who` is
      # "mine" or a user uuid; the extension pair names one column and one
      # of its values — both open-ended, both only ever compared.
      f_state: [default: "", url_key: "state", in: @state_filters],
      f_who: [default: "", url_key: "who"],
      f_overdue: [default: false, cast: :boolean, url_key: "overdue"],
      f_archived: [default: "no", url_key: "archived", in: ~w(no all only)],
      f_subs: [default: false, cast: :boolean, url_key: "subs"],
      f_ext_col: [default: "", url_key: "xcol"],
      f_ext_val: [default: "", url_key: "xval"]
    ]

  import PhoenixKitProjects.Web.Components.PersonDisplay, only: [person: 1]

  alias PhoenixKitProjects.{
    Activity,
    Authz,
    Health,
    L10n,
    ListMetrics,
    MoveLock,
    Paths,
    Projects,
    Statuses
  }

  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Components.{ConfirmAction, MoveProject}
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers
  alias PhoenixKitProjects.Web.ListUi
  alias PhoenixKitProjects.Web.ProjectListColumns, as: Columns
  alias PhoenixKitWeb.TableColumns

  require Logger

  # Default wrapper class for the standalone admin page. Embedders can
  # override via `live_render(... session: %{"wrapper_class" => "..."})`.
  # Tight vertical rhythm for short client screens (matches OverviewLive).
  @default_wrapper_class "flex flex-col w-full px-4 pt-2 pb-4 gap-4"

  # How many rows the list loads at first, and how many more "Load more"
  # appends per click. Hardcoded for now (matches Activity Feed's 50);
  # bump or make session-configurable when a real consumer pushes back.
  @per_batch 50

  # Pagination mode for this LV. `"load_more"` (default) caps the
  # loaded set at @per_batch and shows a footer that bumps the cap
  # on click. Embedders can override via
  # `live_render(... session: %{"pagination" => "off"})` to load
  # every matching row (the original behavior, for hosts that want
  # a one-shot render).
  @default_pagination "load_more"

  # At or below this many projects the WHOLE (status-filtered) list is
  # loaded and the TableLocalSearch hook narrows rows client-side; the
  # SQL search only engages past the threshold. See TemplatesLive.
  @local_search_threshold 100

  # Optional table columns (Name and Actions always render), each viewer's
  # own choice through core's column picker (`ListUi` moduledoc). The roster
  # and the defaults live in `Web.ProjectListColumns`; the extensions' own
  # columns (the CRM's Client, say) join both.
  # How long the list waits after a reload before it reloads again for
  # changes that arrived meanwhile (`handle_info/2`).
  @reload_pause_ms 400

  @columns_key "projects.list"
  @column_events ~w(add_column remove_column reorder_columns reset_columns)

  @impl true
  def mount(_params, session, socket) do
    WebHelpers.maybe_put_locale(session)

    if connected?(socket), do: ProjectsPubSub.subscribe(ProjectsPubSub.topic_all())

    wrapper_class = Map.get(session, "wrapper_class", @default_wrapper_class)
    pagination = Map.get(session, "pagination", @default_pagination)

    socket =
      socket
      |> assign(
        page_title: gettext("Projects"),
        # No header "+": the create button is the list toolbar's last
        # control (`new_project_button/1`), like every admin list.
        wrapper_class: wrapper_class,
        pagination: pagination,
        # Recency default — most recently edited projects first; manual
        # position order (and DnD) is one selector switch away.
        # Load-more pagination state. `loaded_count` is the current
        # cap on visible rows, bumped by @per_batch on each "Load
        # more" click. `total_count` is the DB total matching the
        # current filter, refreshed on every load. Reset to @per_batch
        # on sort change (NOT on DnD reorder — that would snap the
        # user away from what they just dragged). Both ignored when
        # `pagination == "off"`.
        loaded_count: @per_batch,
        # `total_count` = ALL non-archived projects (reorder modal's
        # honest "Reorder all N" + the local-search threshold);
        # `filtered_count` = status+search-aware total for load-more.
        total_count: 0,
        filtered_count: 0,
        local_search?: true,
        # What the columns, the sort and the filters read for the listed
        # projects (`ListMetrics`).
        metrics: %{},
        any_projects?: false,
        filters_open: false,
        people_options: [],
        ext_filter_options: %{},
        projects: [],
        move_locks: %{},
        bulk_enabled?: true,
        # `captured_uuids` is the snapshot taken from the DOM at the
        # moment the user clicks an action button (Reorder, etc.). The
        # live selection lives client-side in the BulkSelectScope hook.
        captured_uuids: [],
        show_reorder_modal: false,
        show_column_modal: false,
        # Workflow-status filter. Options come from the shared catalog
        # (without provisioning it); `nil` = no filter. Hidden when
        # entities is unavailable or the shared list has no statuses yet.
        statuses_available: Statuses.available?(),
        status_options: status_filter_options()
      )
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)
      |> WebHelpers.attach_open_embed_hook()

    # The extensions' columns the viewer may see (the columns alone — their
    # values are read with the list), then the viewer's own choice, read
    # once the embed user is known.
    ext_columns =
      ListMetrics.load([], [:ext], scope: socket.assigns[:phoenix_kit_current_scope]).ext

    socket = assign(socket, ext_columns: ext_columns)

    socket =
      assign(socket, visible_columns: ListUi.load_columns(socket, columns_spec(ext_columns)))

    # Load on both disconnected + connected mount so the first paint has
    # real content. `handle_params/3` is intentionally absent — see
    # dev_docs/embedding_audit.md.
    {:ok, load_projects(socket)}
  end

  # Called by UrlState whenever the query string moves — a search, a status
  # filter, a sort, or the browser's Back button. The load-more cap resets with
  # it: otherwise switching sort would still show only the first batch of the
  # new order, which reads as missing rows.
  #
  # Deliberately NOT the first load — :history mode has no handle_params to
  # hang that on, so mount/3 still does it (see the module's docs).
  @impl PhoenixKitWeb.Live.UrlState
  def handle_url_state(_state, socket) do
    socket |> assign(loaded_count: @per_batch) |> load_projects()
  end

  @impl true
  # Announced beside `:assignment_updated`, which reloads; a cascade of N
  # rows is N more messages and must not be N more reloads.
  def handle_info({:projects, :assignment_status_changed, _payload}, socket),
    do: {:noreply, socket}

  # Any change anywhere in the module arrives here, and one act is often
  # several messages (a task done: the task, its project's rollup, the
  # parent's). The first one reloads at once; the rest of a burst wait for
  # the pause that follows and share one reload.
  def handle_info({:projects, _event, _payload}, socket) do
    case socket.assigns[:reload] do
      nil ->
        Process.send_after(self(), :reload_settled, @reload_pause_ms)
        {:noreply, socket |> assign(:reload, :fresh) |> load_projects()}

      _busy ->
        {:noreply, assign(socket, :reload, :stale)}
    end
  end

  def handle_info(:reload_settled, socket) do
    case socket.assigns[:reload] do
      :stale ->
        Process.send_after(self(), :reload_settled, @reload_pause_ms)
        {:noreply, socket |> assign(:reload, :fresh) |> load_projects()}

      _ ->
        {:noreply, assign(socket, :reload, nil)}
    end
  end

  def handle_info(msg, socket) do
    Logger.debug("[ProjectsLive] unexpected handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  # One load, two shapes.
  #
  # PLAIN: a database-ordered sort and no panel filter. At or below
  # @local_search_threshold projects the whole set is rendered and the
  # client hook narrows it; above it, the database searches and pages
  # (load-more), exactly as before the columns grew.
  #
  # COMPUTED: a sort or a filter over a value that is read for the listed
  # projects (progress, hours, the client…), which the database query does
  # not carry. The list then loads the WHOLE visible set (searched in SQL
  # past the threshold), reads only the families the sort and the filters
  # need for it, filters and sorts in memory, and slices to the load-more
  # cap. Sites hold tens to hundreds of projects, and each family is a
  # fixed number of statements however many there are.
  #
  # Either way the families behind the VISIBLE columns are read for the
  # rows that are drawn, never per row.
  defp load_projects(socket) do
    a = socket.assigns
    scope = a[:phoenix_kit_current_scope]
    filters = filters(a)

    total = Projects.count_projects_for(scope, archived: false)
    listing = listing_opts(a)
    listed_total = if default_listing?(a), do: total, else: count_listed(scope, listing)
    local_search? = listed_total <= @local_search_threshold
    computed? = computed?(a, filters, local_search?)

    # Scoped to the viewer IN THE QUERY, before any sort or filter here: a
    # non-admin's list is the projects they hold, so nothing below can
    # widen it. Admins with projects.admin_all still see everything.
    listed = Projects.list_projects_for(scope, list_opts(a, listing, local_search?, computed?))

    pre = pre_families(a, filters, computed?)
    metrics = ListMetrics.load(listed, pre, scope: scope)

    rows =
      if computed? do
        listed
        |> Columns.filter(filters, metrics, viewer_uuid(socket))
        |> sort_rows(a, metrics)
      else
        listed
      end

    page =
      if computed? and not local_search? and a.pagination == "load_more",
        do: Enum.take(rows, a.loaded_count),
        else: rows

    visible = Columns.families_for(a.visible_columns) ++ if(a.f_subs, do: [:parents], else: [])
    metrics = Map.merge(metrics, ListMetrics.load(page, visible -- pre, scope: scope))

    assign(socket,
      projects: page,
      move_locks: MoveLock.reasons(page),
      metrics: metrics,
      total_count: total,
      # Sub-projects count: someone who belongs only to a sub-project has
      # nothing at the top level, and must still get the toolbar whose
      # "include sub-projects" filter is how they find it.
      any_projects?:
        total > 0 or count_listed(scope, archived: :all, include_subprojects: true) > 0,
      local_search?: local_search?,
      filtered_count: filtered_count(a, scope, listing, rows, local_search?, computed?),
      # The filter panel's own options come from the set BEFORE the panel's
      # filters narrowed it — otherwise picking a client would leave that
      # client as the only one to pick.
      people_options: if(a.filters_open, do: Columns.people_options(metrics), else: []),
      ext_filter_options: ext_filter_options(a, metrics),
      # Per-row current status for the list badge, batched to avoid N+1.
      workflow_status_by_project:
        if(a.statuses_available and "status" in a.visible_columns,
          do: Statuses.statuses_for_projects(page),
          else: %{}
        )
    )
  end

  defp filters(a) do
    %{
      state: a.f_state,
      who: a.f_who,
      overdue: a.f_overdue,
      ext_col: a.f_ext_col,
      ext_val: a.f_ext_val
    }
  end

  # What the database narrows by whichever shape the load takes.
  defp listing_opts(a) do
    [
      archived: archived_opt(a.f_archived),
      include_subprojects: a.f_subs,
      current_status_slug: a[:status_filter] || :all
    ]
  end

  defp archived_opt("all"), do: :all
  defp archived_opt("only"), do: true
  defp archived_opt(_), do: false

  defp default_listing?(a),
    do: a.f_archived == "no" and not a.f_subs and is_nil(a[:status_filter])

  defp count_listed(scope, opts),
    do: Projects.count_projects_for(scope, Keyword.take(opts, [:archived, :include_subprojects]))

  # An open filter panel counts too, past the threshold: its options are
  # the people and the clients of the whole set, not of one page.
  defp computed?(a, filters, local_search?) do
    not Columns.sql_sort?(a.sort_by) or Columns.active_count(filters) > 0 or
      (a.filters_open and not local_search?)
  end

  defp list_opts(a, listing, local_search?, computed?) do
    sort_by = if Columns.sql_sort?(a.sort_by), do: a.sort_by, else: :position
    opts = listing ++ [sort_by: sort_by, sort_dir: a.sort_dir]

    cond do
      # Local mode: the full set stays rendered and the client hook does
      # the search narrowing — no SQL search, no limit.
      local_search? -> opts
      computed? -> Keyword.put(opts, :search, a.search)
      a.pagination == "load_more" -> opts ++ [search: a.search, limit: a.loaded_count]
      true -> Keyword.put(opts, :search, a.search)
    end
  end

  defp pre_families(a, filters, computed?) do
    sort = if computed?, do: [Columns.sort_family(a.sort_by)], else: []
    panel = if a.filters_open, do: [:members, :ext], else: []

    (sort ++ Columns.filter_families(filters) ++ panel)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp sort_rows(rows, a, metrics) do
    if Columns.sql_sort?(a.sort_by),
      do: rows,
      else: Columns.sort(rows, a.sort_by, a.sort_dir, metrics, a.sort_ext)
  end

  defp filtered_count(_a, _scope, _listing, rows, _local?, true), do: length(rows)
  defp filtered_count(_a, _scope, _listing, rows, true, _computed?), do: length(rows)

  defp filtered_count(a, scope, listing, _rows, _local?, _computed?),
    do: Projects.count_projects_for(scope, Keyword.put(listing, :search, a.search))

  defp viewer_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> PhoenixKitWeb.Actor.uuid(socket)
    end
  end

  # `%{column_id => [value]}` for the extension columns the panel filters by.
  defp ext_filter_options(%{filters_open: false}, _metrics), do: %{}

  defp ext_filter_options(_a, metrics) do
    metrics |> Map.get(:ext, []) |> Map.new(&{&1.id, Columns.ext_options(&1)})
  end

  # Shared-catalog statuses as `{label, slug}` for the filter select.
  # Reads only — never provisions the shared entity.
  defp status_filter_options do
    Statuses.shared_catalog_statuses() |> Enum.map(&{&1.label, &1.slug})
  end

  # The workflow-status filter dropdown, shown in the toolbar. Hidden when
  # the entities module is unavailable or the shared list has no statuses
  # yet. A self-contained form so its phx-change doesn't entangle with the
  # sort selector's form.
  defp status_filter_control(assigns) do
    ~H"""
    <form id="projects-status-filter"
      :if={@statuses_available and @status_options != []}
      phx-change="filter_status"
      class="flex items-center"
    >
      <.select
        name="status_slug"
        value={@status_filter}
        options={@status_options}
        prompt={gettext("All statuses")}
        class="select-sm"
      />
    </form>
    """
  end

  # The filters panel's toggle, beside the search box: says how many
  # filters are set, so a narrowed list never looks like the whole one.
  defp filters_button(assigns) do
    assigns =
      assign(assigns, :active, Columns.active_count(filters(assigns)) + listing_filters(assigns))

    ~H"""
    <button
      type="button"
      id="projects-filters-toggle"
      class={["btn btn-sm gap-1", @filters_open && "btn-active"]}
      phx-click="toggle_filters"
      aria-expanded={to_string(@filters_open)}
    >
      <.icon name="hero-funnel" class="w-4 h-4" />
      <span class="hidden sm:inline">{gettext("Filters")}</span>
      <span :if={@active > 0} class="badge badge-primary badge-sm">{@active}</span>
    </button>
    """
  end

  # Archived and sub-projects change WHICH projects are listed rather than
  # narrow them, but they are choices the reader made all the same.
  defp listing_filters(assigns) do
    Enum.count([assigns.f_archived != "no", assigns.f_subs], & &1)
  end

  # One row under the toolbar, only while open: every choice is a select
  # or a tick in a single form, so one `phx-change` carries the whole
  # panel and the URL takes it from there.
  defp filters_panel(assigns) do
    ~H"""
    <form
      :if={@filters_open}
      id="projects-filters"
      phx-change="filter"
      class="flex flex-wrap items-center gap-2 rounded-box border border-base-300 bg-base-100 px-3 py-2"
    >
      <.select
        name="state"
        value={@f_state}
        options={Enum.map(Columns.states(), &{Columns.state_label(&1), &1})}
        prompt={gettext("Any state")}
        class="select-sm"
        aria-label={gettext("State")}
      />
      <.select
        name="who"
        value={@f_who}
        options={[{gettext("My projects"), "mine"} | @people_options]}
        prompt={gettext("Anyone")}
        class="select-sm"
        aria-label={gettext("Member")}
      />
      <.select
        :for={col <- @ext_columns}
        name={"ext[#{col.id}]"}
        value={if(@f_ext_col == col.id, do: @f_ext_val, else: "")}
        options={Enum.map(Map.get(@ext_filter_options, col.id, []), &{&1, &1})}
        prompt={gettext("Any %{column}", column: String.downcase(col.label))}
        class="select-sm"
        aria-label={col.label}
      />
      <.select
        name="archived"
        value={@f_archived}
        options={[
          {gettext("Not archived"), "no"},
          {gettext("With archived"), "all"},
          {gettext("Archived only"), "only"}
        ]}
        class="select-sm"
        aria-label={gettext("Archived")}
      />
      <label class="label cursor-pointer gap-2 text-sm">
        <input type="hidden" name="overdue" value="false" />
        <input type="checkbox" name="overdue" value="true" checked={@f_overdue} class="checkbox checkbox-sm" />
        {gettext("Has overdue tasks")}
      </label>
      <label class="label cursor-pointer gap-2 text-sm">
        <input type="hidden" name="subs" value="false" />
        <input type="checkbox" name="subs" value="true" checked={@f_subs} class="checkbox checkbox-sm" />
        {gettext("Include sub-projects")}
      </label>
      <button
        :if={filters_set?(assigns)}
        type="button"
        id="projects-filters-clear"
        class="btn btn-ghost btn-sm gap-1 ml-auto"
        phx-click="clear_filters"
      >
        <.icon name="hero-x-mark" class="w-4 h-4" /> {gettext("Clear filters")}
      </button>
    </form>
    """
  end

  defp filters_set?(assigns) do
    Columns.active_count(filters(assigns)) + listing_filters(assigns) > 0 or
      not is_nil(assigns[:status_filter])
  end

  @impl true

  # A destructive action asks first through core's confirm modal
  # (`Components.ConfirmAction`); only these events may be put behind it.
  def handle_event("request_confirm", params, socket),
    do: {:noreply, ConfirmAction.request(socket, params, ~w(delete))}

  def handle_event("confirm_action_cancel", _params, socket),
    do: {:noreply, ConfirmAction.clear(socket)}

  def handle_event("confirm_action_ok", _params, socket) do
    case ConfirmAction.take(socket) do
      {nil, socket} -> {:noreply, socket}
      {%{event: event, params: params}, socket} -> handle_event(event, params, socket)
    end
  end

  # The "Move…" dialog: nest a project under another (it then leaves this
  # list, which the reload shows).
  def handle_event(event, params, socket)
      when event in ~w(move_project_open move_project_change move_project_submit move_project_close),
      do:
        MoveProject.handle_event(event, params, socket, fn socket, _ -> load_projects(socket) end)

  # Sort selector fires `sort_form` for both field changes (via the
  # form's phx-change) and direction toggles (via the button's
  # phx-click). One event, two shapes — derive the missing half from
  # current state.
  def handle_event("sort_form", params, socket) do
    dir_str = params["sort_dir"] || Atom.to_string(socket.assigns.sort_dir)

    dir =
      case dir_str do
        "desc" -> :desc
        _ -> :asc
      end

    {field, ext} = sort_target(params["sort_by"], socket)
    {:noreply, apply_sort(socket, field, dir, ext)}
  end

  # The filters panel: closed by default so the toolbar stays one line.
  # Opening it reloads — its selects list the people and the extension
  # values of the listed projects, which a closed panel never reads.
  def handle_event("toggle_filters", _params, socket) do
    {:noreply, socket |> assign(filters_open: not socket.assigns.filters_open) |> load_projects()}
  end

  # One change event for the whole panel. Every value is re-validated by
  # UrlState's spec on the way in (`in:` lists, boolean casts), so a forged
  # value can only land on a default; `who` and the extension pair are
  # open-ended and only ever compared against what is loaded.
  def handle_event("filter", params, socket) do
    {ext_col, ext_val} = ext_filter_param(params["ext"], socket)

    {:noreply,
     push_url_state(socket,
       f_state: string_param(params["state"]),
       f_who: string_param(params["who"]),
       f_overdue: params["overdue"] == "true",
       f_archived: if(params["archived"] in ~w(all only), do: params["archived"], else: "no"),
       f_subs: params["subs"] == "true",
       f_ext_col: ext_col,
       f_ext_val: ext_val
     )}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     push_url_state(socket,
       status_filter: nil,
       f_state: "",
       f_who: "",
       f_overdue: false,
       f_archived: "no",
       f_subs: false,
       f_ext_col: "",
       f_ext_val: ""
     )}
  end

  # Workflow-status filter. Empty value clears it. Reset `loaded_count`
  # (same reasoning as a sort change) so the filtered view starts at the
  # first batch rather than keeping a stale deep page.
  def handle_event("filter_status", %{"status_slug" => slug}, socket) do
    slug = if slug in [nil, ""], do: nil, else: slug
    {:noreply, push_url_state(socket, status_filter: slug)}
  end

  # Header-click sort: clicking the active column flips direction,
  # clicking a different column switches to it with :asc.
  def handle_event("toggle_sort", %{"by" => field_str}, socket) when is_binary(field_str) do
    a = socket.assigns
    {field, ext} = sort_target(field_str, socket)
    same? = field == a.sort_by and (field != :ext or ext == a.sort_ext)

    dir =
      cond do
        not same? -> :asc
        a.sort_dir == :asc -> :desc
        true -> :asc
      end

    {:noreply, apply_sort(socket, field, dir, ext)}
  end

  def handle_event("toggle_sort", _params, socket), do: {:noreply, socket}

  def handle_event("load_more", _params, socket) do
    {:noreply,
     socket
     |> assign(loaded_count: socket.assigns.loaded_count + @per_batch)
     |> load_projects()}
  end

  # The search box (core `<.search_toolbar>`, 300ms debounce). A new
  # query resets the load-more cap; ListUi.coerce_search guards forged
  # map-shaped payloads.
  def handle_event("search", params, socket) do
    {:noreply, push_url_state(socket, [search: ListUi.coerce_search(params)], replace: true)}
  end

  def handle_event("open_column_modal", _params, socket),
    do: {:noreply, assign(socket, show_column_modal: true)}

  def handle_event("hide_column_modal", _params, socket),
    do: {:noreply, assign(socket, show_column_modal: false)}

  # Core's live column picker: every edit applies at once and is saved for
  # the viewer. Reload so a newly-shown tasks / created_by column gets its
  # batched lookup map (hidden columns skip those queries).
  def handle_event(event, params, socket) when event in @column_events do
    socket =
      TableColumns.handle_event(
        event,
        params,
        socket,
        columns_spec(socket.assigns.ext_columns),
        :visible_columns
      )

    {:noreply, load_projects(socket)}
  end

  # The bulk toolbar's Reorder button pushes this event with the
  # currently-selected UUIDs (gathered from the DOM by the
  # BulkSelectScope hook). Empty (or single-row) selection collapses
  # to :all — the button label is "Reorder all" in those states, and
  # a single-row permute is a no-op, so treating it as :all matches
  # both the visible UI promise and the only sensible action.
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

  # Map gates atom coercion: a crafted payload can't smuggle in an
  # unknown atom (which would crash `String.to_existing_atom` on a
  # garbage string and otherwise leak a fresh atom slot).
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

    case Projects.reorder_projects_by(strategy, scope, actor_uuid: Activity.actor_uuid(socket)) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Projects reordered."))
         |> assign(show_reorder_modal: false, captured_uuids: [])
         |> load_projects()}

      {:error, :wrong_scope} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Selection no longer valid; please reselect."))
         |> assign(show_reorder_modal: false, captured_uuids: [])
         |> load_projects()}

      {:error, :duplicate_positions} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Selected rows share positions. Apply \"Reorder all\" first to normalise.")
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not reorder projects."))}
    end
  end

  # Empty submit (no radio chosen) or a forged strategy string. The
  # form has `required` on the radios so this is the fallback for
  # defense in depth.
  def handle_event("apply_reorder", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Pick a strategy before applying."))}
  end

  def handle_event("reorder_projects", %{"ordered_ids" => ordered_ids} = params, socket)
      when is_list(ordered_ids) do
    moved_id = params["moved_id"]

    case Projects.reorder_projects(ordered_ids, actor_uuid: Activity.actor_uuid(socket)) do
      :ok ->
        {:noreply,
         socket
         |> push_event("sortable:flash", %{uuid: moved_id, status: "ok"})
         |> load_projects()}

      {:error, :too_many_uuids} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Too many projects to reorder at once."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_projects()}

      {:error, :wrong_scope} ->
        # The user dropped a row from a list that isn't a regular
        # project bucket — usually a stale view racing a flag flip.
        # Reload to snap back to truth.
        {:noreply,
         socket
         |> put_flash(:error, gettext("Project list changed; please try again."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_projects()}
    end
  end

  def handle_event("delete", %{"uuid" => uuid}, socket) do
    # Existence was the only check here: a client event naming any project
    # uuid deleted it, whatever the sender's relationship to it. The list is
    # scoped now, but a handler must never trust that the row came from the
    # rendered page.
    case Projects.get_project(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Project not found."))}

      project ->
        delete_if_permitted(socket, project)
    end
  end

  defp delete_if_permitted(socket, project) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if Authz.can?(scope, project, :delete_project) do
      do_delete(socket, project)
    else
      # Same shape as not-found: whether the project exists is not something
      # a caller without access should be able to probe.
      {:noreply, put_flash(socket, :error, gettext("Project not found."))}
    end
  end

  defp do_delete(socket, project) do
    case Projects.delete_project(project) do
      {:ok, _} ->
        log_and_flash_deleted(socket, project)

      {:error, _} ->
        Activity.log_failed("projects.project_deleted",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        {:noreply, put_flash(socket, :error, gettext("Could not delete project."))}
    end
  end

  # Sort change resets the load-more cap (otherwise a switch from
  # Name back to Manual would still show only the first @per_batch
  # rows of the new sort, leaving the user confused).
  defp apply_sort(socket, field, dir, ext) do
    push_url_state(socket, sort_by: field, sort_dir: dir, sort_ext: ext)
  end

  # `{sort atom, extension column id}` for a sort the client named: a
  # whitelisted field (never an atom minted from the param), or one of the
  # extension columns this viewer was offered. Anything else keeps the
  # current sort.
  defp sort_target("ext:" <> _ = id, socket) do
    if Enum.any?(socket.assigns.ext_columns, &(&1.id == id)),
      do: {:ext, id},
      else: {socket.assigns.sort_by, socket.assigns.sort_ext}
  end

  defp sort_target(field_str, _socket) when field_str in @sort_field_strs and field_str != "ext",
    do: {String.to_existing_atom(field_str), ""}

  defp sort_target(_other, socket), do: {socket.assigns.sort_by, socket.assigns.sort_ext}

  defp string_param(value) when is_binary(value), do: value
  defp string_param(_), do: ""

  # The panel posts one select per extension column (`ext[<id>]`); the
  # first one with a value is the filter (the list filters by one extension
  # value at a time). Only a column this viewer was offered counts.
  defp ext_filter_param(%{} = by_column, socket) do
    offered = Enum.map(socket.assigns.ext_columns, & &1.id)
    current = socket.assigns.f_ext_col

    by_column
    |> Enum.filter(fn {id, value} -> id in offered and is_binary(value) and value != "" end)
    # A second column's select changing wins over the one already set.
    |> Enum.sort_by(fn {id, _} -> id == current end)
    |> case do
      [{id, value} | _] -> {id, value}
      [] -> {"", ""}
    end
  end

  defp ext_filter_param(_other, _socket), do: {"", ""}

  defp sanitize_uuids(%{"uuids" => uuids}) when is_list(uuids) do
    Enum.filter(uuids, &is_binary/1)
  end

  defp sanitize_uuids(_), do: []

  defp log_and_flash_deleted(socket, project) do
    # Activity log captures the primary-language name (audit trail is
    # locale-agnostic; primary is the canonical identifier for the row).
    Activity.log("projects.project_deleted",
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "project",
      resource_uuid: project.uuid,
      metadata: %{"name" => project.name}
    )

    {:noreply,
     socket
     |> WebHelpers.notify_deleted(:project, project.uuid)
     |> put_flash(:info, gettext("Project deleted."))
     |> load_projects()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <%!-- Carries the hook that keeps the address bar in step with the list.
           Needed because this LiveView is embeddable and therefore cannot use
           push_patch — see the `use UrlState` note at the top. --%>
      <.url_state_sync mode={:history} id="projects-list-url-state" />
      <%!-- True-empty install only — a no-match SEARCH/FILTER must keep
           the toolbar on screen so the query can be cleared. --%>
      <%= if not @any_projects? do %>
        <.empty_state icon="hero-clipboard-document-list" title={gettext("No projects yet.")}>
          <:cta>
            <.new_project_button
              embed_mode={@embed_mode}
              label={gettext("Create your first project")}
            />
          </:cta>
        </.empty_state>
      <% else %>
        <%!-- DnD applies only in "manual" sort (sort_by=:position).
             Sorting by name / date is a *view* — it doesn't rewrite
             positions, so dragging would be lossy and the handle is
             hidden. Switching back to manual restores the drag handle
             and the position-driven order. --%>
        <%!-- Manual sort only, AND no active status filter: a filtered
             view is a sparse subset, and the DnD handler renumbers the
             dropped list to 1..N absolute positions — colliding with
             the hidden rows' slots (same gate as TemplatesLive's
             search). Same hazard applies to a load-more-truncated page:
             with @loaded_count < @total_count the visible rows are also
             a sparse subset, so DnD stays off until the full set is
             loaded (local-search mode always loads the full set). --%>
        <% lang = L10n.current_content_lang() %>
        <%!-- Any panel filter, the archived view and the flat sub-project
             view are sparse or foreign subsets too (a sub-project's position
             is its place in its PARENT's plan), so they switch DnD off the
             same way. --%>
        <% draggable? =
          @sort_by == :position and is_nil(@status_filter) and String.trim(@search) == "" and
            not filters_set?(assigns) and
            (@local_search? or @loaded_count >= @total_count) %>

        <.bulk_select_scope
          :if={@bulk_enabled?}
          id="projects-bulk-scope"
          total_count={length(@projects)}
        >
          <div
            id="projects-local-search"
            phx-hook="TableLocalSearch"
            data-local-search-enabled={to_string(@local_search?)}
            class="flex flex-col gap-2"
          >
          <%!-- Sort selector lives in the toolbar's leading slot so
               the two read as one control row. Reorder-button gating:
               manual sort → always shown ("Reorder all" / "Reorder N
               selected"); other sorts → only when more than one row
               is selected (a one-row reorder is a no-op, and the
               view's order doesn't reflect positions anyway). --%>
          <.bulk_actions_toolbar
            on_open_reorder="open_reorder_modal"
            reorder_dialog_id="reorder-modal"
            noun_singular={gettext("project")}
            noun_plural={gettext("projects")}
            allow_delete={false}
            reorder_gate={if @sort_by == :position, do: :always, else: :multi}
          >
            <%!-- Control order follows the kit's other lists (catalogue,
                 core's table toolbar): search + data filters on the LEFT,
                 the view tools (sort, Columns) on the RIGHT after the
                 selection actions. --%>
            <:leading>
              <.search_toolbar
                value={@search}
                on_submit="search"
                loading_indicator={not @local_search?}
                placeholder={gettext("Search projects...")}
                class="w-48"
              />
              {status_filter_control(assigns)}
              {filters_button(assigns)}
            </:leading>
            <:trailing>
              <.sort_selector
                sort_by={if(@sort_by == :ext, do: @sort_ext, else: @sort_by)}
                sort_dir={@sort_dir}
                options={Columns.sort_options(@ext_columns)}
                manual_field={:position}
              />
              <ListUi.columns_button />
            </:trailing>
            <:primary>
              <.new_project_button embed_mode={@embed_mode} />
            </:primary>
          </.bulk_actions_toolbar>

          {filters_panel(assigns)}

          {render_projects_table(assigns, draggable?, lang)}

          <%!-- Server-truth when the SERVER filter empties the list; the
               TableLocalSearch hook toggles the same node during the
               debounce gap. --%>
          <p
            data-local-search-empty
            class={[
              "text-sm text-base-content/50 text-center py-2",
              @projects != [] && "hidden"
            ]}
          >
            {gettext("No projects match.")}
          </p>
          </div>
        </.bulk_select_scope>

        <%!-- When bulk-select is disabled, render just the sort
             selector + table (no toolbar wrapper). --%>
        <%= if not @bulk_enabled? do %>
          <div class="flex items-center gap-2">
            <.sort_selector
              sort_by={if(@sort_by == :ext, do: @sort_ext, else: @sort_by)}
              sort_dir={@sort_dir}
              options={Columns.sort_options(@ext_columns)}
              manual_field={:position}
            />
            {status_filter_control(assigns)}
            {filters_button(assigns)}
          </div>
          {filters_panel(assigns)}
          {render_projects_table(assigns, draggable?, lang)}
        <% end %>
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
        noun_singular={gettext("project")}
        noun_plural={gettext("projects")}
      />

      <.column_settings_modal
        show={@show_column_modal}
        id="projects-column-settings"
        columns={columns_spec(@ext_columns).columns}
        selected={@visible_columns}
      />
      <.confirm_action_modal confirm={assigns[:confirm_action]} />
      <.move_project_modal move={assigns[:move_project]} />
    </div>
    """
  end

  # The picker's roster: the native columns (`Web.ProjectListColumns` —
  # add one there, plus its `column_cell/3` clause below), then whatever the
  # extensions contribute. A new viewer sees Status, the extensions' columns
  # (the client), then the rest of the defaults.
  defp columns_spec(ext_columns) do
    options =
      Enum.map(Columns.specs(), &{&1.id, &1.label}) ++ Enum.map(ext_columns, &{&1.id, &1.label})

    [first | rest] = Columns.default_columns()
    ListUi.columns_spec(@columns_key, options, [first | Enum.map(ext_columns, & &1.id)] ++ rest)
  end

  attr(:embed_mode, :atom, required: true)
  attr(:label, :string, default: nil)

  # The list's create button: the toolbar's last control, and the empty
  # state's call to action. `smart_link`, so an embedded list opens the
  # form in its drawer instead of navigating away.
  defp new_project_button(assigns) do
    ~H"""
    <.smart_link
      navigate={Paths.new_project()}
      emit={{PhoenixKitProjects.Web.ProjectFormLive, %{"live_action" => "new"}}}
      embed_mode={@embed_mode}
      class="btn btn-primary btn-sm"
      aria-label={@label || gettext("New project")}
    >
      <.icon name="hero-plus" class="w-4 h-4" />
      <span class={!@label && "hidden sm:inline"}>{@label || gettext("New project")}</span>
    </.smart_link>
    """
  end

  # Extracted because the table is rendered both inside the
  # bulk-select scope and (when bulk is disabled) bare.
  #
  # Columns follow the catalogue's shape: Name is the lead column and takes
  # the slack; every optional column is sized to its content and packed
  # against the right edge, in the viewer's own order (`ListUi` moduledoc).
  defp render_projects_table(assigns, draggable?, lang) do
    assigns = assign(assigns, draggable?: draggable?, lang: lang)

    ~H"""
    <.table_default id="projects-list" size="sm" fit>
      <.table_default_header>
        <.table_default_row>
          <.drag_handle_header_cell :if={@draggable?} />
          <.bulk_select_header_cell
            :if={@bulk_enabled?}
            id="projects-select-all"
            aria_label={gettext("Select all projects")}
          />
          <.sort_header_cell field={:name} sort={%{by: @sort_by, dir: @sort_dir}} lead>
            {gettext("Name")}
          </.sort_header_cell>
          <%= for col <- @visible_columns do %>
            {column_header(assigns, col)}
          <% end %>
          <ListUi.actions_header_cell />
        </.table_default_row>
      </.table_default_header>
      <.sortable_tbody
        id="projects-list-body"
        enabled={@draggable?}
        event="reorder_projects"
      >
        <.sortable_row
          :for={p <- @projects}
          item_id={p.uuid}
          data-search={ListUi.search_haystack(p, ["name", "description"]) <> " " <> String.downcase(p.key || "")}
        >
          <.drag_handle_cell :if={@draggable?} />
          <.bulk_select_cell :if={@bulk_enabled?} value={p.uuid} />
          <.table_default_cell class="font-medium" lead>
            <%!-- A sub-project listed flat says where it lives: its parent,
                 muted, before its own name. --%>
            <% parent = Columns.get(@metrics, :parents, p) %>
            <span :if={parent} class="font-normal text-base-content/50">
              {Project.localized_name(parent, @lang)} /
            </span>
            <.smart_link
              navigate={Paths.project(p)}
              emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => p.uuid}}}
              embed_mode={@embed_mode}
              class="link link-hover"
            >
              {Project.localized_name(p, @lang)}
            </.smart_link>
            <%!-- Ongoing work says so beside its name, as on its page. --%>
            <span
              :if={Project.ongoing?(p) and not p.is_template}
              class="badge badge-xs badge-outline badge-info gap-0.5 ml-1 align-middle whitespace-nowrap"
              title={gettext("Ongoing — this project ends only when someone ends it")}
            >
              <span aria-hidden="true">∞</span> {gettext("Ongoing")}
            </span>
            <% desc = Project.localized_description(p, @lang) %>
            <div :if={desc} class="text-xs text-base-content/60 truncate max-w-md" title={desc}>{desc}</div>
          </.table_default_cell>
          <%= for col <- @visible_columns do %>
            {column_cell(assigns, col, p)}
          <% end %>
          <.table_default_cell class="text-right whitespace-nowrap">
            <.table_row_menu id={"project-menu-#{p.uuid}"}>
              <.smart_menu_link
                navigate={Paths.edit_project(p.uuid)}
                emit={{PhoenixKitProjects.Web.ProjectFormLive, %{"live_action" => "edit", "id" => p.uuid}}}
                embed_mode={@embed_mode}
                icon="hero-pencil"
                label={gettext("Edit")}
              />
              <MoveProject.locked_menu_item
                :if={@move_locks[p.uuid]}
                reason={@move_locks[p.uuid]}
                label={gettext("Move…")}
              />
              <.table_row_menu_button
                :if={!@move_locks[p.uuid]}
                phx-click="move_project_open"
                phx-value-uuid={p.uuid}
                icon="hero-arrows-right-left"
                label={gettext("Move…")}
              />
              <.table_row_menu_divider />
              <.table_row_menu_button
                {ConfirmAction.ask("delete",
                  uuid: p.uuid,
                  title: gettext("Delete project “%{name}”?", name: Project.localized_name(p, @lang)),
                  message: gettext("Its tasks are deleted too."),
                  confirm: gettext("Delete")
                )}
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
      loaded={length(@projects)}
      total={@filtered_count}
      noun_plural={gettext("projects")}
    />
    """
  end

  # One optional column's header cell, by id: an extension's column sorts
  # by its text; a native one keeps core's sortable header when its spec
  # names a sort. Every one carries its fit class and drop priority.
  defp column_header(assigns, "ext:" <> _ = id) do
    assigns =
      assign(assigns,
        id: id,
        label: Enum.find_value(assigns.ext_columns, id, &(&1.id == id && &1.label)),
        active: assigns.sort_by == :ext and assigns.sort_ext == id
      )

    ~H"""
    <.table_default_header_cell {ListUi.column_attrs(@id)}>
      <button
        type="button"
        phx-click="toggle_sort"
        phx-value-by={@id}
        class="group inline-flex items-center gap-1 cursor-pointer select-none hover:opacity-80"
      >
        {@label}
        <.icon :if={@active and @sort_dir == :asc} name="hero-chevron-up-mini" class="w-4 h-4" />
        <.icon :if={@active and @sort_dir == :desc} name="hero-chevron-down-mini" class="w-4 h-4" />
        <.icon
          :if={not @active}
          name="hero-chevron-up-down-mini"
          class="w-4 h-4 opacity-30 group-hover:opacity-70"
        />
      </button>
    </.table_default_header_cell>
    """
  end

  defp column_header(assigns, id) do
    assigns = assign(assigns, id: id, spec: Columns.spec(id))

    ~H"""
    <%= case @spec do %>
      <% nil -> %>
        <.table_default_header_cell {ListUi.column_attrs(@id)}></.table_default_header_cell>
      <% %{sort: nil} = spec -> %>
        <.table_default_header_cell
          title={spec.label}
          {ListUi.column_attrs(@id, spec.align == :right && "text-right")}
        >
          {Columns.header(spec)}
        </.table_default_header_cell>
      <% spec -> %>
        <.sort_header_cell
          field={spec.sort}
          sort={%{by: @sort_by, dir: @sort_dir}}
          align={spec.align}
          title={spec.label}
          {ListUi.column_attrs(@id)}
        >
          {Columns.header(spec)}
        </.sort_header_cell>
    <% end %>
    """
  end

  # One optional column's body cell for project `p`, by id — the same
  # order as the header, which is what `fit` hides columns by. A new native
  # column is one clause here (and its entry in `Web.ProjectListColumns`).
  defp column_cell(assigns, "status", p) do
    assigns = assign(assigns, p: p)

    ~H"""
    <.table_default_cell>
      <%!-- Two different things, one under the other: where the project
           stands (the system's), then the status its people gave it. --%>
      <div class="flex flex-col items-start gap-1">
        <.project_status_badge project={@p} />
        <.workflow_status_badge
          :if={@statuses_available}
          status={Map.get(@workflow_status_by_project, @p.uuid)}
        />
      </div>
    </.table_default_cell>
    """
  end

  defp column_cell(assigns, "progress", p) do
    assigns = assign(assigns, t: Columns.get(assigns.metrics, :tasks, p), p: p)

    ~H"""
    <.table_default_cell class="whitespace-nowrap">
      <%!-- Ongoing work has no finish to be a share of: what is open. --%>
      <%= if Project.ongoing?(@p) and @t && @t.has_work do %>
        <span class="tabular-nums text-xs text-base-content/70">
          {ngettext("%{count} open", "%{count} open", @t.open || 0)}
        </span>
      <% else %>
      <%= if @t && @t.has_work do %>
        <div class="flex items-center gap-2">
          <progress class="progress progress-primary w-16" value={@t.progress_pct} max="100"></progress>
          <span class="tabular-nums text-xs text-base-content/70">{@t.progress_pct}%</span>
        </div>
      <% else %>
        <span class="text-base-content/40">—</span>
      <% end %>
      <% end %>
    </.table_default_cell>
    """
  end

  defp column_cell(assigns, "tasks", p) do
    assigns = assign(assigns, t: Columns.get(assigns.metrics, :tasks, p))

    ~H"""
    <.table_default_cell
      class="text-right tabular-nums text-base-content/70"
      title={@t && gettext("%{done} of %{total} done", done: @t.done, total: @t.total)}
    >
      {if(@t && @t.total > 0, do: "#{@t.done}/#{@t.total}", else: "0")}
    </.table_default_cell>
    """
  end

  defp column_cell(assigns, "open_tasks", p),
    do: number_cell(assigns, Columns.field(assigns.metrics, :tasks, p, :open))

  defp column_cell(assigns, "subprojects", p),
    do: number_cell(assigns, Columns.field(assigns.metrics, :tasks, p, :subprojects))

  defp column_cell(assigns, "overdue", p) do
    assigns = assign(assigns, n: Columns.field(assigns.metrics, :due, p, :overdue) || 0)

    ~H"""
    <.table_default_cell class={["text-right tabular-nums", if(@n > 0, do: "text-error font-medium", else: "text-base-content/40")]}>
      {@n}
    </.table_default_cell>
    """
  end

  defp column_cell(assigns, "next_due", p),
    do: date_cell(assigns, Columns.field(assigns.metrics, :due, p, :next_due))

  defp column_cell(assigns, "next_event", p),
    do: date_cell(assigns, Columns.get(assigns.metrics, :events, p))

  defp column_cell(assigns, "members", p) do
    assigns = assign(assigns, m: Columns.get(assigns.metrics, :members, p))

    ~H"""
    <.table_default_cell
      class="text-right tabular-nums text-base-content/70"
      title={@m && Enum.map_join(@m.people, ", ", & &1.name)}
    >
      {(@m && @m.count) || 0}
    </.table_default_cell>
    """
  end

  defp column_cell(assigns, "owner", p),
    do: people_cell(assigns, Columns.owners(p, assigns.metrics))

  defp column_cell(assigns, "assignee", p) do
    assigns = assign(assigns, a: Columns.get(assigns.metrics, :assignee, p))

    ~H"""
    <.table_default_cell class="whitespace-nowrap text-base-content/70">
      <%= if @a do %>
        <span class="inline-flex items-center gap-1 max-w-[12rem]" title={@a.label}>
          <.icon name={assignee_kind_icon(@a.kind)} class="w-3.5 h-3.5 shrink-0" />
          <span class="truncate">{@a.label}</span>
        </span>
      <% else %>
        <span class="text-base-content/40">—</span>
      <% end %>
    </.table_default_cell>
    """
  end

  defp column_cell(assigns, "started", p), do: date_cell(assigns, p.started_at)
  defp column_cell(assigns, "completed", p), do: date_cell(assigns, p.completed_at)

  # A finished project has an end already; its planned one is history.
  defp column_cell(assigns, "eta", p) do
    eta =
      if p.completed_at, do: nil, else: Columns.field(assigns.metrics, :tasks, p, :planned_end)

    late? = match?(%DateTime{}, eta) and DateTime.compare(eta, DateTime.utc_now()) == :lt
    assigns = assign(assigns, eta: eta, late?: late?)

    ~H"""
    <.table_default_cell class={["whitespace-nowrap", if(@late?, do: "text-error", else: "text-base-content/70")]}>
      {L10n.format_date(@eta) || "—"}
    </.table_default_cell>
    """
  end

  defp column_cell(assigns, "hours", p),
    do: minutes_cell(assigns, Columns.field(assigns.metrics, :ledger, p, :minutes))

  defp column_cell(assigns, "ai_hours", p),
    do: minutes_cell(assigns, Columns.field(assigns.metrics, :ledger, p, :ai_minutes))

  defp column_cell(assigns, "total_hours", p),
    do: minutes_cell(assigns, Columns.total_minutes(assigns.metrics, p))

  defp column_cell(assigns, "billable_hours", p),
    do: minutes_cell(assigns, Columns.field(assigns.metrics, :ledger, p, :billable_minutes))

  defp column_cell(assigns, "tokens", p) do
    tokens = Columns.field(assigns.metrics, :ledger, p, :tokens) || 0

    text_cell(
      assigns,
      if(tokens > 0, do: ListUi.format_tokens(tokens)),
      "text-right tabular-nums"
    )
  end

  defp column_cell(assigns, "cost", p) do
    cents = Columns.field(assigns.metrics, :ledger, p, :cost_cents) || 0
    text_cell(assigns, if(cents > 0, do: ListUi.format_cents(cents)), "text-right tabular-nums")
  end

  defp column_cell(assigns, "last_activity", p),
    do: date_cell(assigns, Columns.get(assigns.metrics, :activity, p) || p.updated_at)

  defp column_cell(assigns, "health", p) do
    assigns = assign(assigns, health: Health.get(p))

    ~H"""
    <.table_default_cell class="whitespace-nowrap">
      <%= if @health do %>
        <span class={["badge badge-sm", health_badge(@health["status"])]} title={@health["note"]}>
          {health_label(@health["status"])}
        </span>
      <% else %>
        <span class="text-base-content/40">—</span>
      <% end %>
    </.table_default_cell>
    """
  end

  defp column_cell(assigns, "created", p), do: date_cell(assigns, p.inserted_at)
  defp column_cell(assigns, "updated", p), do: date_cell(assigns, p.updated_at)

  defp column_cell(assigns, "created_by", p),
    do: people_cell(assigns, List.wrap(Columns.get(assigns.metrics, :creators, p)))

  defp column_cell(assigns, "key", p), do: text_cell(assigns, p.key, "font-mono text-xs")

  defp column_cell(assigns, "external_id", p),
    do: text_cell(assigns, p.external_id, "font-mono text-xs")

  # An extension's column: its text, linked when it gave a place to go.
  defp column_cell(assigns, "ext:" <> _ = id, p) do
    assigns = assign(assigns, v: Columns.ext_value(assigns.metrics, id, p))

    ~H"""
    <.table_default_cell class="whitespace-nowrap text-base-content/70">
      <%= cond do %>
        <% @v && @v.url -> %>
          <.link navigate={@v.url} class="link link-hover inline-block max-w-[14rem] truncate align-bottom" title={@v.text}>
            {@v.text}
          </.link>
        <% @v -> %>
          <span class="inline-block max-w-[14rem] truncate align-bottom" title={@v.text}>{@v.text}</span>
        <% true -> %>
          <span class="text-base-content/40">—</span>
      <% end %>
    </.table_default_cell>
    """
  end

  defp column_cell(assigns, _unknown, _p) do
    ~H"""
    <.table_default_cell></.table_default_cell>
    """
  end

  defp number_cell(assigns, n) do
    assigns = assign(assigns, n: n || 0)

    ~H"""
    <.table_default_cell class="text-right tabular-nums text-base-content/70">{@n}</.table_default_cell>
    """
  end

  defp date_cell(assigns, value) do
    assigns = assign(assigns, value: value)

    ~H"""
    <.table_default_cell class="whitespace-nowrap text-base-content/70">
      {L10n.format_date(@value) || "—"}
    </.table_default_cell>
    """
  end

  defp minutes_cell(assigns, minutes) do
    assigns = assign(assigns, minutes: minutes || 0)

    ~H"""
    <.table_default_cell class="text-right tabular-nums whitespace-nowrap text-base-content/70">
      {if(@minutes > 0, do: ListUi.format_minutes(@minutes), else: "—")}
    </.table_default_cell>
    """
  end

  defp text_cell(assigns, text, class) do
    assigns = assign(assigns, text: if(text in [nil, ""], do: nil, else: text), class: class)

    ~H"""
    <.table_default_cell class={["whitespace-nowrap text-base-content/70", @class]}>
      <span :if={@text} class="inline-block max-w-[14rem] truncate align-bottom" title={@text}>{@text}</span>
      <span :if={!@text} class="text-base-content/40">—</span>
    </.table_default_cell>
    """
  end

  # People in a cell: a face and a name each, as everywhere in the module.
  defp people_cell(assigns, names) do
    assigns = assign(assigns, names: Enum.reject(names, &(&1 in [nil, ""])))

    ~H"""
    <.table_default_cell class="whitespace-nowrap text-base-content/70">
      <span :if={@names != []} class="inline-flex flex-wrap items-center gap-x-2 gap-y-1 max-w-[16rem]">
        <.person :for={name <- @names} name={name} class="max-w-[14rem]" />
      </span>
      <span :if={@names == []} class="text-base-content/40">—</span>
    </.table_default_cell>
    """
  end

  defp assignee_kind_icon(:team), do: "hero-users"
  defp assignee_kind_icon(:department), do: "hero-building-office"
  defp assignee_kind_icon(_person), do: "hero-user"

  defp health_label("on_track"), do: gettext("On track")
  defp health_label("some_risk"), do: gettext("Some risk")
  defp health_label("concerned"), do: gettext("Concerned")
  defp health_label(other), do: other

  defp health_badge("on_track"), do: "badge-success"
  defp health_badge("some_risk"), do: "badge-warning"
  defp health_badge("concerned"), do: "badge-error"
  defp health_badge(_), do: "badge-ghost"
end
