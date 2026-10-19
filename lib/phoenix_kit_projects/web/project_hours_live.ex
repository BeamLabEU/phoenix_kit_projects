defmodule PhoenixKitProjects.Web.ProjectHoursLive do
  @moduledoc """
  **Hours** — who worked, on what, when and for how long.

  One LiveView, two places:

    * a project's **Hours tab**, contributed by the Tasks extension and
      shown while the project's `ledger` flag is on; the hub mounts it with
      `live_render` and the extension-tab session (`project_uuid`,
      `current_user_uuid`, …), like Events and Whiteboards;
    * the site-wide **Hours** page (`/admin/projects/hours`), over every
      project the viewer may see, with a project filter and a breakdown by
      project.

  Everything it shows is read by `PhoenixKitProjects.Hours`; entries are
  written, amended and removed by `PhoenixKitProjects.Ledger` only.

  The filters live in the query string on the site-wide page (core's
  `UrlState` in `:history` mode — this LiveView is embedded, so it cannot
  export `handle_params/3`); on the tab they live in the page's state, the
  project page owning its own address.

  Who may do what: seeing needs `:view` on the project (the tab's host has
  already checked it), logging one's own time `:log_time`, and logging for
  somebody else or changing another person's entry `:edit_tasks`. An entry
  that is already on an invoice is shown and never changed here.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  import PhoenixKitWeb.Components.Core.Chart, only: [bar_chart: 1]
  import PhoenixKitWeb.Components.Core.DateNav, only: [date_nav: 1]
  import PhoenixKitWeb.Components.Core.SearchPicker, only: [search_picker: 1]

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: KitDate

  alias PhoenixKitProjects.{
    Activity,
    Authz,
    Features,
    Hours,
    Invoicing,
    L10n,
    Ledger,
    Members,
    Paths,
    People,
    Projects
  }

  alias PhoenixKitProjects.Hours.{Format, Period, Report}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.{Project, WorkEntry}
  alias PhoenixKitProjects.Web.Components.ConfirmAction
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers
  alias PhoenixKitWeb.Components.Core.FormFieldLabel

  require Logger

  @sort_fields Hours.sort_fields()
  @sort_field_strs Enum.map(@sort_fields, &Atom.to_string/1)
  @groups ~w(none day person task project)
  @billable ~w(all yes no)
  @who ~w(all people ai)

  use PhoenixKitWeb.Live.UrlState,
    mode: :history,
    params: [
      period: [default: "month", in: Period.presets()],
      from: [default: ""],
      to: [default: ""],
      worker: [default: ""],
      task: [default: ""],
      project_filter: [default: "", url_key: "project"],
      billable: [default: "all", in: @billable],
      who: [default: "all", in: @who],
      subprojects: [default: true, cast: :boolean, url_key: "sub"],
      group: [default: "none", in: @groups],
      sort_by: [default: :at, cast: :atom, in: @sort_fields, url_key: "sort"],
      sort_dir: [default: :desc, cast: :atom, in: [:asc, :desc], url_key: "dir"]
    ]

  @default_wrapper_class "flex flex-col w-full px-4 pt-2 pb-4 gap-4"
  @per_batch 50
  # The most entries a report lists (and its CSV holds); more than this and
  # the report says it is cut.
  @report_cap 1000
  # A chart draws every day of a period up to this long; a longer one (or
  # "all time") draws the days that have something, the latest this many.
  @chart_days 62
  # People with a colour of their own in the chart; the rest are "Others".
  @chart_series 7

  # ── Mount ───────────────────────────────────────────────────────

  @impl true
  def mount(params, session, socket) do
    WebHelpers.maybe_put_locale(session)

    socket =
      socket
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)
      |> WebHelpers.attach_open_embed_hook()
      |> assign(
        wrapper_class: Map.get(session, "wrapper_class", @default_wrapper_class),
        routed?: params != :not_mounted_at_router,
        loaded_count: @per_batch,
        show_all_tasks: false,
        log_form: nil,
        log_projects: [],
        edit_entry: nil,
        edit_error: nil,
        report: nil,
        csv_url: nil,
        sheet_week: nil
      )

    socket =
      case session["project_uuid"] do
        uuid when is_binary(uuid) -> mount_project(socket, Projects.get_project(uuid))
        _ -> mount_all(socket)
      end

    if connected?(socket), do: ProjectsPubSub.subscribe(ProjectsPubSub.topic_all())

    {:ok, load(socket)}
  end

  # The tab. The host page has decided the viewer may open the project; the
  # tab asks again all the same — a session is not an authorization.
  defp mount_project(socket, %Project{is_template: false} = project) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if Authz.can?(scope, project, :view) do
      assign(socket,
        mode: :project,
        project: project,
        dom: "hours-#{project.uuid}",
        enabled?: Features.on?(project, "ledger"),
        project_options: [],
        page_title: gettext("Hours")
      )
    else
      mount_nothing(socket)
    end
  end

  defp mount_project(socket, _missing_or_template), do: mount_nothing(socket)

  defp mount_nothing(socket) do
    assign(socket,
      mode: :project,
      project: nil,
      dom: "hours-none",
      enabled?: false,
      project_options: [],
      page_title: gettext("Hours")
    )
  end

  defp mount_all(socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    lang = L10n.current_content_lang()

    options =
      scope
      |> Projects.list_projects_for(archived: false, sort_by: :name)
      |> Enum.map(&{Project.localized_name(&1, lang), &1.uuid})

    assign(socket,
      mode: :all,
      project: nil,
      dom: "hours-all",
      enabled?: true,
      project_options: options,
      page_title: gettext("Hours"),
      page_section: gettext("Projects"),
      page_section_path: Paths.projects()
    )
  end

  # ── URL state ───────────────────────────────────────────────────

  @impl PhoenixKitWeb.Live.UrlState
  def handle_url_state(_state, socket) do
    socket |> assign(loaded_count: @per_batch, sheet_week: nil, show_all_tasks: false) |> load()
  end

  # ── PubSub ──────────────────────────────────────────────────────

  @impl true
  def handle_info({:projects, :work_logged, %{uuid: uuid}}, socket) do
    if covers?(socket.assigns[:filters], uuid),
      do: {:noreply, load(socket)},
      else: {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp covers?(%{project_uuids: :all}, _uuid), do: true
  defp covers?(%{project_uuids: uuids}, uuid), do: uuid in uuids
  defp covers?(_, _), do: false

  # ── Loading ─────────────────────────────────────────────────────

  defp load(%{assigns: %{enabled?: false}} = socket) do
    assign(socket,
      filters: nil,
      period_info: nil,
      summary: Hours.empty_summary(),
      rows: [],
      total: 0,
      invoiced: [],
      worker_options: [],
      picked: %{},
      perms: %{},
      chart: nil,
      sheet: nil,
      offset: "0"
    )
  end

  # A tab left open is asked again on every reload: somebody taken off the
  # project stops seeing its hours with the next filter change or entry,
  # not with the next visit.
  defp load(%{assigns: %{mode: :project, project: %Project{} = project}} = socket) do
    if Authz.can?(socket.assigns[:phoenix_kit_current_scope], project, :view),
      do: do_load(socket),
      else: mount_nothing(socket)
  end

  defp load(socket), do: do_load(socket)

  defp do_load(socket) do
    a = socket.assigns
    offset = resolve_offset(socket)
    lang = L10n.current_content_lang()
    period = Period.resolve(a.period, a.from, a.to, Period.today(offset), offset)
    project_uuids = project_uuids(socket)

    filters =
      Hours.filters(
        project_uuids: project_uuids,
        from: period.from,
        until: period.until,
        workers: if(a.worker == "", do: [], else: [a.worker]),
        assignment_uuid: if(a.mode == :project and a.task != "", do: a.task),
        billable: billable_filter(a.billable),
        who: who_filter(a.who),
        offset_seconds: Period.offset_seconds(offset)
      )

    summary = Hours.summary(filters, lang: lang)
    worker_options = Hours.workers(Hours.filters(project_uuids: project_uuids))

    page =
      Hours.list(filters,
        sort_by: a.sort_by,
        sort_dir: a.sort_dir,
        limit: a.loaded_count,
        lang: lang
      )

    sheet_week = a.sheet_week || default_sheet_week(period, offset)

    socket
    |> assign(
      offset: offset,
      filters: filters,
      period_info: period,
      summary: summary,
      rows: page.entries,
      total: page.total,
      invoiced: page.entries |> Enum.map(& &1.entry.uuid) |> Invoicing.invoiced_entry_uuids(),
      worker_options: worker_options,
      # What the three pickers show as chosen. Nothing is listed whole:
      # each searches as it is typed in (`pick_search`).
      picked: %{
        "worker" =>
          if(a.worker != "",
            do: Enum.find_value(worker_options, a.worker, &(&1.key == a.worker && &1.name))
          ),
        "task" => if(a.mode == :project and a.task != "", do: picked_task(a.task, lang)),
        "project" =>
          if(a.project_filter != "",
            do:
              Enum.find_value(a[:project_options] || [], a.project_filter, fn {name, uuid} ->
                uuid == a.project_filter && name
              end)
          )
      },
      perms: perms(socket, page.entries),
      chart: chart(summary, period, offset),
      sheet_week: sheet_week
    )
    |> load_sheet()
  end

  defp load_sheet(socket) do
    %{filters: filters, sheet_week: monday, offset: offset} = socket.assigns

    week = %{
      filters
      | from: Period.day_start(monday, offset),
        until: Period.day_start(Date.add(monday, 7), offset)
    }

    assign(socket,
      sheet: Map.put(Hours.timesheet(week), :days, Enum.map(0..6, &Date.add(monday, &1)))
    )
  end

  # The week the timesheet opens on: the one holding the period's last day,
  # never one that has not started.
  defp default_sheet_week(period, offset) do
    today = Period.today(offset)

    last =
      case period.to_date do
        %Date{} = to -> if Date.compare(to, today) == :gt, do: today, else: to
        nil -> today
      end

    Period.week_start(last)
  end

  defp listable(:all), do: []
  defp listable(uuids), do: uuids

  # The projects this read covers. On the site-wide page a chosen project
  # must be one the viewer can see; anything else reads as "all of mine".
  defp project_uuids(%{assigns: %{mode: :project, project: nil}}), do: []

  defp project_uuids(%{assigns: %{mode: :project, project: project, subprojects: sub?}}),
    do: Hours.project_uuids(project.uuid, sub?)

  defp project_uuids(%{assigns: %{mode: :all} = a} = socket) do
    visible = Hours.visible_project_uuids(socket.assigns[:phoenix_kit_current_scope])
    chosen = a.project_filter

    if chosen != "" and (visible == :all or chosen in visible) and
         Enum.any?(a.project_options, fn {_name, uuid} -> uuid == chosen end) do
      Hours.project_uuids(chosen, a.subprojects)
    else
      visible
    end
  end

  defp who_filter("people"), do: :people
  defp who_filter("ai"), do: :ai
  defp who_filter(_), do: :all

  defp picked_task(uuid, lang) do
    case Hours.task_option(uuid, lang) do
      %{} = task -> task_label(task)
      nil -> gettext("A removed task")
    end
  end

  defp billable_filter("yes"), do: true
  defp billable_filter("no"), do: false
  defp billable_filter(_), do: nil

  # What the viewer may do on each project in sight — one answer per
  # project, never one per row. Asked with the project STRUCT: the resolver
  # reads a project's own tightened floors off it.
  defp perms(socket, rows) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    uuids =
      case socket.assigns do
        %{mode: :project, project: %Project{uuid: uuid}} -> [uuid]
        %{project_options: options} -> Enum.map(options, &elem(&1, 1))
      end

    (uuids ++ Enum.map(rows, & &1.project.uuid))
    |> Hours.projects_by_uuid()
    |> Map.new(fn {uuid, project} ->
      {uuid,
       %{
         # Logging needs the project's work ledger ON as well as the
         # right to log: the site-wide page shows many projects, and one
         # whose ledger is off takes no entries here either (the project
         # page and the API refuse the same).
         log: Authz.can?(scope, project, :log_time) and Features.on?(project, "ledger"),
         manage: Authz.can?(scope, project, :edit_tasks),
         # Entering time for somebody else is its own row in the project's
         # "who can" panel.
         for_others: Authz.can?(scope, project, :log_time_for_others)
       }}
    end)
  end

  defp resolve_offset(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{user_timezone: _} = user -> KitDate.get_user_timezone(user)
      _ -> PhoenixKit.Settings.get_setting("time_zone", "0")
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.debug("[ProjectHoursLive] timezone read failed: #{Exception.message(e)}")
      "0"
  end

  # ── The chart's data ────────────────────────────────────────────

  # `%{days: [%{date, minutes, parts: [{series, minutes}]}], series: [%{key,
  # name, slot, minutes}], max: minutes}` — nil when there is nothing to
  # draw. A series keeps its slot whatever the filters leave on screen: the
  # order is by name, not by rank.
  defp chart(%{by_day: []}, _period, _offset), do: nil

  defp chart(summary, period, offset) do
    {named, others} = Enum.split(summary.by_worker, @chart_series)

    series =
      named
      |> Enum.sort_by(&String.downcase(&1.worker.name))
      |> Enum.with_index(1)
      |> Enum.map(fn {row, slot} ->
        %{
          key: row.worker.key,
          name: row.worker.name,
          slot: slot,
          minutes: row.minutes,
          ai: row.worker.kind == "ai_agent"
        }
      end)

    series =
      if others == [],
        do: series,
        else:
          series ++
            [
              %{
                key: :others,
                name: gettext("Others"),
                slot: 0,
                minutes: others |> Enum.map(& &1.minutes) |> Enum.sum(),
                ai: false
              }
            ]

    slots = Map.new(series, &{&1.key, &1})
    by_date = Map.new(summary.by_day, &{&1.date, &1})

    days =
      summary.by_day
      |> chart_dates(period, offset)
      |> Enum.map(fn date ->
        day = Map.get(by_date, date, %{minutes: 0.0, by_worker: %{}})
        %{date: date, minutes: day.minutes, parts: parts(day.by_worker, slots)}
      end)

    max = days |> Enum.map(& &1.minutes) |> Enum.max(fn -> 0.0 end)
    %{days: days, series: series, max: max, top: axis_top(max)}
  end

  # The axis ends on a round figure with a round half (2h / 1h, 8h / 4h),
  # not on the busiest day's own "6h 40m": the smallest step that covers
  # the busiest day in four or fewer.
  @axis_steps [15, 30, 60, 120, 240, 480, 720, 1440]
  defp axis_top(max) when max <= 0, do: 60.0

  defp axis_top(max) do
    step = Enum.find(@axis_steps, 1440, &(max / &1 <= 4))
    steps = max(Float.ceil(max / step), 1.0)
    # An even number of steps, so the middle line is a whole one too.
    steps = if rem(trunc(steps), 2) == 1 and steps > 1, do: steps + 1, else: steps
    steps * step
  end

  defp chart_dates(by_day, %{from_date: %Date{} = from, to_date: %Date{} = to}, offset) do
    last = Enum.min([to, Period.today(offset)], Date)
    last = if Date.compare(last, from) == :lt, do: to, else: last

    if Date.diff(last, from) < @chart_days,
      do: Enum.to_list(Date.range(from, last)),
      else: latest_days(by_day)
  end

  defp chart_dates(by_day, _open_period, _offset), do: latest_days(by_day)

  defp latest_days(by_day), do: by_day |> Enum.map(& &1.date) |> Enum.take(-@chart_days)

  # A day's minutes per series, in slot order (the stack's order), the
  # people past the named ones summed into "Others".
  defp parts(by_worker, slots) do
    by_worker
    |> Enum.group_by(
      fn {key, _m} -> Map.get(slots, key) || Map.fetch!(slots, :others) end,
      &elem(&1, 1)
    )
    |> Enum.map(fn {series, minutes} -> {series, Enum.sum(minutes)} end)
    |> Enum.sort_by(fn {series, _m} -> if series.slot == 0, do: 99, else: series.slot end)
  end

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("request_confirm", params, socket),
    do: {:noreply, ConfirmAction.request(socket, params, ~w(delete_entry))}

  def handle_event("confirm_action_cancel", _params, socket),
    do: {:noreply, ConfirmAction.clear(socket)}

  def handle_event("confirm_action_ok", _params, socket) do
    case ConfirmAction.take(socket) do
      {nil, socket} -> {:noreply, socket}
      {%{event: event, params: params}, socket} -> handle_event(event, params, socket)
    end
  end

  def handle_event("filter", params, socket) do
    changes =
      [
        period: params["period"],
        from: params["from"],
        to: params["to"],
        worker: params["worker"],
        task: params["task"],
        project_filter: params["project"],
        billable: params["billable"],
        who: params["who"],
        group: params["group"]
      ]
      |> Enum.filter(fn {_k, v} -> is_binary(v) end)
      |> put_subprojects(params)
      |> custom_when_dated(params)

    {:noreply, push_url_state(socket, changes)}
  end

  # ── The pickers (core's `<.search_picker>`) ──
  #
  # Person, Task and Project are searched as they are typed in, never
  # listed whole: a project with a hundred thousand tasks answers the same
  # twenty rows as one with five. One search event and one pick event for
  # all of them; the input's id says which (`…-pick-<field>`), and is
  # echoed back so each picker keeps to its own answers.

  def handle_event("pick_search", %{"q" => q} = params, socket) do
    id = to_string(params["id"])
    limit = pick_limit(params["limit"])
    {rows, more?} = pick_rows(pick_field_of(id), to_string(q), limit, socket)

    {:noreply,
     push_event(socket, "picker_results", %{q: q, results: rows, has_more: more?, id: id})}
  end

  def handle_event("pick_pick", %{"uuid" => value} = params, socket) when is_binary(value) do
    id = to_string(params["id"])
    socket = push_event(socket, "picker_staged", %{id: id})

    case pick_field_of(id) do
      "worker" -> {:noreply, push_url_state(socket, worker: value)}
      "task" -> {:noreply, push_url_state(socket, task: value)}
      "project" -> {:noreply, push_url_state(socket, project_filter: value)}
      "logtask" -> {:noreply, put_log_value(socket, "task", value)}
      _ -> {:noreply, socket}
    end
  end

  # The × on a chosen value (core's picker sends its own id).
  def handle_event("unpick", %{"id" => id}, socket) do
    case pick_field_of(to_string(id)) do
      "worker" -> {:noreply, push_url_state(socket, worker: "")}
      "task" -> {:noreply, push_url_state(socket, task: "")}
      "project" -> {:noreply, push_url_state(socket, project_filter: "")}
      "logtask" -> {:noreply, put_log_value(socket, "task", "")}
      _ -> {:noreply, socket}
    end
  end

  # How the entries table is grouped: its own control, on the table's
  # heading — it changes nothing else on the page.
  def handle_event("group", %{"group" => group}, socket) when is_binary(group),
    do: {:noreply, push_url_state(socket, group: group)}

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     push_url_state(socket,
       period: "month",
       from: "",
       to: "",
       worker: "",
       task: "",
       project_filter: "",
       billable: "all",
       who: "all",
       subprojects: true,
       group: "none"
     )}
  end

  def handle_event("toggle_sort", %{"by" => field}, socket) when field in @sort_field_strs do
    field = String.to_existing_atom(field)

    dir =
      cond do
        field != socket.assigns.sort_by -> if field == :at, do: :desc, else: :asc
        socket.assigns.sort_dir == :asc -> :desc
        true -> :asc
      end

    {:noreply, push_url_state(socket, sort_by: field, sort_dir: dir)}
  end

  def handle_event("toggle_sort", _params, socket), do: {:noreply, socket}

  def handle_event("load_more", _params, socket) do
    {:noreply, socket |> assign(loaded_count: socket.assigns.loaded_count + @per_batch) |> load()}
  end

  def handle_event("toggle_all_tasks", _params, socket),
    do: {:noreply, assign(socket, show_all_tasks: not socket.assigns.show_all_tasks)}

  # Core's `<.date_nav>` names the day to go to; whatever day arrives, the
  # sheet shows the week it is in.
  def handle_event("sheet_week", %{"date" => value}, socket) do
    monday =
      case Date.from_iso8601(to_string(value)) do
        {:ok, date} -> Period.week_start(date)
        _ -> Period.week_start(Period.today(socket.assigns.offset))
      end

    {:noreply, socket |> assign(sheet_week: monday) |> load_sheet()}
  end

  def handle_event("sheet_week", _params, socket), do: {:noreply, socket}

  # ── Logging time ──

  def handle_event("open_log", _params, socket) do
    case loggable_projects(socket.assigns) do
      [] ->
        {:noreply,
         put_flash(socket, :error, gettext("You don't have permission to log time here."))}

      [{_name, first} | _] = projects ->
        project_uuid = socket.assigns[:project] && socket.assigns.project.uuid

        # The projects on offer first: the form reads tasks and people only
        # for one of them (`log_form/2`).
        socket = assign(socket, log_projects: projects)

        {:noreply,
         assign(socket,
           log_form:
             log_form(socket, %{
               "project" => project_uuid || first,
               "date" => Date.to_iso8601(Period.today(socket.assigns.offset)),
               "person" => "me",
               "task" => if(socket.assigns.task != "", do: socket.assigns.task, else: "")
             })
         )}
    end
  end

  def handle_event("close_log", _params, socket), do: {:noreply, assign(socket, log_form: nil)}

  # Keeps what was typed and, on the site-wide page, re-reads the tasks and
  # people of the project just chosen.
  def handle_event("log_change", params, socket) do
    if socket.assigns.log_form,
      do: {:noreply, assign(socket, log_form: log_form(socket, params))},
      else: {:noreply, socket}
  end

  def handle_event("save_log", params, socket) do
    with %{} <- socket.assigns.log_form || :closed,
         {:ok, project_uuid} <- log_project(socket, params),
         {:ok, minutes} <- minutes(params["duration"]),
         {:ok, actor} <- log_actor(socket, project_uuid, params["person"]),
         {:ok, task_uuid} <- log_task(project_uuid, params["task"]),
         {:ok, times} <- log_times(params, minutes, socket.assigns.offset),
         {:ok, _entry} <-
           Ledger.log_time(
             project_uuid,
             minutes,
             [
               assignment_uuid: task_uuid,
               note: blank_to_nil(params["note"]),
               billable: params["billable"] in ["true", "on"]
             ] ++ actor ++ times
           ) do
      {:noreply,
       socket
       |> assign(log_form: nil)
       |> put_flash(:info, gettext("Time logged."))
       |> load()}
    else
      :closed -> {:noreply, socket}
      {:error, message} when is_binary(message) -> {:noreply, log_error(socket, params, message)}
      {:error, _} -> {:noreply, log_error(socket, params, gettext("Could not log the time."))}
    end
  end

  # ── Amending and removing ──

  def handle_event("edit_entry", %{"uuid" => uuid}, socket) do
    case amendable(socket, uuid) do
      {:ok, entry} -> {:noreply, assign(socket, edit_entry: entry, edit_error: nil)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("close_edit", _params, socket), do: {:noreply, assign(socket, edit_entry: nil)}

  def handle_event("save_edit", params, socket) do
    with %WorkEntry{uuid: uuid} <- socket.assigns.edit_entry || :closed,
         {:ok, entry} <- amendable(socket, uuid),
         {:ok, minutes} <- minutes(params["duration"]),
         {:ok, _} <-
           Ledger.update_time(entry, minutes,
             billable: params["billable"] in ["true", "on"],
             actor_uuid: Activity.actor_uuid(socket)
           ) do
      {:noreply,
       socket
       |> assign(edit_entry: nil)
       |> put_flash(:info, gettext("Entry updated."))
       |> load()}
    else
      :closed ->
        {:noreply, socket}

      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, edit_error: message)}

      {:error, _} ->
        {:noreply, assign(socket, edit_error: gettext("Could not update the entry."))}
    end
  end

  def handle_event("delete_entry", %{"uuid" => uuid}, socket) do
    with {:ok, entry} <- amendable(socket, uuid),
         {:ok, _} <- Ledger.delete_entry(entry, actor_uuid: Activity.actor_uuid(socket)) do
      {:noreply, socket |> put_flash(:info, gettext("Entry removed.")) |> load()}
    else
      {:error, message} when is_binary(message) -> {:noreply, put_flash(socket, :error, message)}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Could not remove the entry."))}
    end
  end

  # ── The report ──

  def handle_event("open_report", _params, socket),
    do: {:noreply, assign(socket, report: build_report(socket), csv_url: nil)}

  def handle_event("close_report", _params, socket),
    do: {:noreply, assign(socket, report: nil, csv_url: nil)}

  def handle_event("prepare_csv", _params, socket) do
    case socket.assigns.report do
      nil -> {:noreply, socket}
      report -> {:noreply, assign(socket, csv_url: Report.csv_data_url(report))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Typing a day into either date field IS choosing a custom period; the
  # select follows, so the two cannot disagree.
  # The tick is in one of the bar's two forms: only that form says whether
  # it is set.
  defp put_subprojects(changes, %{"subprojects" => value}),
    do: Keyword.put(changes, :subprojects, value in ["true", "on"])

  defp put_subprojects(changes, _params), do: changes

  defp pick_field_of(id), do: id |> String.split("-pick-") |> List.last()

  defp pick_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(50)

  defp pick_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, _} -> pick_limit(n)
      :error -> 20
    end
  end

  defp pick_limit(_), do: 20

  # `{rows, more?}` for one picker, each row as the hook draws it.
  defp pick_rows("task", q, limit, socket) do
    {tasks, more?} =
      Hours.search_tasks(
        listable(project_uuids(socket)),
        q,
        limit,
        L10n.current_content_lang()
      )

    {Enum.map(tasks, &task_row/1), more?}
  end

  defp pick_rows("logtask", q, limit, socket) do
    with %{values: %{"project" => project}} when is_binary(project) and project != "" <-
           socket.assigns[:log_form],
         {:ok, project_uuid} <- log_project(socket, %{"project" => project}) do
      {tasks, more?} =
        Hours.search_tasks([project_uuid], q, limit, L10n.current_content_lang())

      {Enum.map(tasks, &task_row/1), more?}
    else
      _ -> {[], false}
    end
  end

  defp pick_rows("worker", q, limit, socket) do
    socket.assigns[:worker_options]
    |> List.wrap()
    |> Enum.filter(&name_matches?(&1.name, q))
    |> page_of(limit, fn w ->
      %{
        kind: "worker",
        uuid: w.key,
        label: w.name,
        sublabel: if(w.kind == "ai_agent", do: gettext("AI")),
        icon: if(w.kind == "ai_agent", do: "hero-cpu-chip", else: "hero-user")
      }
    end)
  end

  defp pick_rows("project", q, limit, socket) do
    socket.assigns[:project_options]
    |> List.wrap()
    |> Enum.filter(fn {name, _uuid} -> name_matches?(name, q) end)
    |> page_of(limit, fn {name, uuid} ->
      %{kind: "project", uuid: uuid, label: name, icon: "hero-clipboard-document-list"}
    end)
  end

  defp pick_rows(_field, _q, _limit, _socket), do: {[], false}

  defp task_row(task) do
    %{
      kind: "task",
      uuid: task.uuid,
      label: task.title,
      sublabel: task.ref,
      icon: "hero-check-circle"
    }
  end

  defp name_matches?(_name, ""), do: true

  defp name_matches?(name, q),
    do: String.contains?(String.downcase(to_string(name)), String.downcase(String.trim(q)))

  defp page_of(list, limit, fun),
    do: {list |> Enum.take(limit) |> Enum.map(fun), length(list) > limit}

  # One value of the open Log time form changed from outside its inputs (a
  # task picked or cleared): the form is rebuilt from what it holds.
  defp put_log_value(%{assigns: %{log_form: %{values: values}}} = socket, key, value) do
    params =
      values
      |> Map.put(key, value)
      |> Map.update("billable", "false", &to_string(&1 == true))

    assign(socket, log_form: log_form(socket, params))
  end

  defp put_log_value(socket, _key, _value), do: socket

  defp custom_when_dated(changes, %{"_target" => [field]}) when field in ~w(from to),
    do: Keyword.put(changes, :period, "custom")

  defp custom_when_dated(changes, _params), do: changes

  # ── Log-time helpers ────────────────────────────────────────────

  # The projects the viewer may log time on, as `{name, uuid}`: the tab's
  # own project, or on the site-wide page every listed project that allows
  # it.
  defp loggable_projects(%{mode: :project, project: nil}), do: []

  defp loggable_projects(%{mode: :project, project: project} = assigns) do
    if may?(assigns, project.uuid, :log),
      do: [{Project.localized_name(project, L10n.current_content_lang()), project.uuid}],
      else: []
  end

  defp loggable_projects(%{project_options: options} = assigns),
    do: Enum.filter(options, fn {_name, uuid} -> may?(assigns, uuid, :log) end)

  defp may?(%{perms: perms}, project_uuid, what), do: get_in(perms, [project_uuid, what]) == true

  # The form's values plus the choices that depend on the project picked.
  defp log_form(socket, params) do
    # Only a project the viewer may log on is read for its tasks and
    # people: the param is the client's, and a forged uuid would otherwise
    # list another project's task titles in the picker.
    project_uuid =
      case log_project(socket, params) do
        {:ok, uuid} -> uuid
        _ -> nil
      end

    lang = L10n.current_content_lang()

    %{
      values: %{
        "project" => project_uuid,
        "date" => params["date"] || "",
        "time" => params["time"] || "",
        "person" => params["person"] || "me",
        "task" => blank_to_nil(params["task"]) || "",
        "duration" => params["duration"] || "",
        "note" => params["note"] || "",
        "billable" => params["billable"] in ["true", "on"]
      },
      # The task picked, as its chip says it (nil = the project itself).
      task_label:
        case Hours.task_option(params["task"], lang) do
          %{project_uuid: ^project_uuid} = task -> task_label(task)
          _ -> nil
        end,
      people: person_options(socket, project_uuid),
      error: nil
    }
  end

  defp log_error(socket, params, message),
    do: assign(socket, log_form: %{log_form(socket, params) | error: message})

  # "Me", and — for someone who runs the project's plan — its members and
  # the staff people who have no account of their own on the list.
  defp person_options(socket, project_uuid) do
    me = [{gettext("Me"), "me"}]

    if is_binary(project_uuid) and may?(socket.assigns, project_uuid, :for_others) do
      my_uuid = Activity.actor_uuid(socket)

      members =
        project_uuid
        |> Members.list_members()
        |> Enum.reject(&(&1.user_uuid == my_uuid))
        |> Enum.map(&{member_name(&1), Hours.actor_key("user", &1.user_uuid)})

      listed =
        MapSet.new([
          my_uuid | Enum.map(members, fn {_n, key} -> String.replace_prefix(key, "user:", "") end)
        ])

      staff =
        People.list_people()
        |> Enum.reject(&MapSet.member?(listed, &1.user_uuid))
        |> Enum.map(&{People.display_name(&1), Hours.actor_key("staff_person", &1.uuid)})

      me ++ members ++ staff
    else
      me
    end
  end

  defp member_name(%{user: %{} = user}) do
    case User.full_name(user) do
      name when is_binary(name) and name != "" -> name
      _ -> user.email
    end
  end

  defp member_name(_), do: gettext("Someone")

  defp log_project(socket, params) do
    uuid = params["project"]

    if Enum.any?(socket.assigns[:log_projects] || [], fn {_name, u} -> u == uuid end) and
         may?(socket.assigns, uuid, :log),
       do: {:ok, uuid},
       else: {:error, gettext("You don't have permission to log time here.")}
  end

  defp minutes(text) do
    case Format.parse_duration(text) do
      {:ok, minutes} -> {:ok, minutes}
      :error -> {:error, gettext("Enter how long, like 1h 30m, 1:30, 90 or 1.5h.")}
    end
  end

  # Who the time is for. Anyone but "me" needs the plan-level permission,
  # and must be one of the choices the form offered.
  defp log_actor(socket, project_uuid, person) do
    my_uuid = Activity.actor_uuid(socket)

    cond do
      person in [nil, "", "me"] and is_binary(my_uuid) ->
        {:ok, [actor_kind: "user", actor_uuid: my_uuid]}

      person in [nil, "", "me"] ->
        {:error, gettext("Sign in to log time.")}

      Enum.any?(person_options(socket, project_uuid), fn {_name, key} -> key == person end) ->
        [kind, uuid] = String.split(person, ":", parts: 2)
        {:ok, [actor_kind: kind, actor_uuid: uuid]}

      true ->
        {:error, gettext("Pick a person from the list.")}
    end
  end

  defp log_task(_project_uuid, blank) when blank in [nil, ""], do: {:ok, nil}

  defp log_task(project_uuid, task_uuid) do
    # The one task is looked up, not the project's whole list.
    case Hours.task_option(task_uuid) do
      %{project_uuid: ^project_uuid} -> {:ok, task_uuid}
      _ -> {:error, gettext("Pick a task of this project.")}
    end
  end

  # With a start time the entry runs from it for its length; with a day
  # only, it is stamped at that day's noon, so it lands on the day meant in
  # every timezone near the viewer's.
  defp log_times(params, minutes, offset) do
    with {:ok, date} <- Date.from_iso8601(params["date"] || ""),
         {:ok, start} <- start_time(date, params["time"], offset) do
      cond do
        DateTime.compare(start, DateTime.add(DateTime.utc_now(), 86_400)) == :gt ->
          {:error, gettext("The day cannot be in the future.")}

        params["time"] in [nil, ""] ->
          {:ok, [ended_at: start]}

        true ->
          {:ok, [started_at: start, ended_at: DateTime.add(start, minutes * 60)]}
      end
    else
      _ -> {:error, gettext("Pick the day the work was done.")}
    end
  end

  defp start_time(date, time, offset) do
    clock = if time in [nil, ""], do: "12:00", else: time

    case KitDate.parse_datetime_local("#{Date.to_iso8601(date)}T#{clock}", offset) do
      {:ok, utc} -> {:ok, DateTime.truncate(utc, :second)}
      _ -> :error
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  # ── Amend helpers ───────────────────────────────────────────────

  # The entry, when it is in sight, a time entry, not invoiced, and the
  # viewer's to change: their own with `:log_time`, anyone's with
  # `:edit_tasks`. Never trusts that the uuid came from a rendered row.
  defp amendable(socket, uuid) do
    with %WorkEntry{kind: "time"} = entry <- Ledger.get_entry(uuid) || :not_found,
         true <- covers?(socket.assigns.filters, entry.project_uuid) || :not_found,
         true <- may_amend?(socket, entry) || :forbidden,
         false <- entry.uuid in Invoicing.invoiced_entry_uuids([entry.uuid]) do
      {:ok, entry}
    else
      true -> {:error, gettext("This entry is on an invoice and cannot be changed here.")}
      :forbidden -> {:error, gettext("You don't have permission to change this entry.")}
      _ -> {:error, gettext("Entry not found.")}
    end
  end

  defp may_amend?(socket, %WorkEntry{} = entry) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    project = Projects.get_project(entry.project_uuid)

    Authz.can?(scope, project, :edit_tasks) or
      (Authz.can?(scope, project, :log_time) and mine?(socket, entry))
  end

  # Whether a row is the viewer's own, for the menu: the same rule as
  # `may_amend?/2`, answered from what the page already read.
  defp row_mine?(assigns, row) do
    me = assigns[:phoenix_kit_current_user]
    is_map(me) and row.worker.key == Hours.actor_key("user", me.uuid)
  end

  defp mine?(socket, %WorkEntry{actor_kind: "user", actor_uuid: uuid}),
    do: is_binary(uuid) and uuid == Activity.actor_uuid(socket)

  defp mine?(socket, %WorkEntry{actor_kind: "staff_person", actor_uuid: uuid}) do
    me = Activity.actor_uuid(socket)

    is_binary(me) and is_binary(uuid) and
      match?(%{uuid: ^uuid}, People.get_person_by_user_uuid(me))
  end

  defp mine?(_socket, _entry), do: false

  # ── Report helpers ──────────────────────────────────────────────

  defp build_report(socket) do
    a = socket.assigns
    lang = L10n.current_content_lang()

    page =
      Hours.list(a.filters, sort_by: :at, sort_dir: :asc, limit: @report_cap, lang: lang)

    Report.build(
      title: report_title(a, lang),
      period: a.period_info.label,
      filters: filter_words(a),
      totals: a.summary.totals,
      by_worker: a.summary.by_worker,
      # The report lists what was logged on each task itself.
      by_task: Enum.filter(a.summary.by_task, &(&1.entries > 0)),
      by_project: a.summary.by_project,
      entries: page.entries,
      total_entries: page.total,
      offset: a.offset
    )
  end

  defp report_title(%{mode: :project, project: %Project{} = project}, lang),
    do: gettext("Hours — %{project}", project: Project.localized_name(project, lang))

  defp report_title(a, _lang) do
    case Enum.find(a.project_options, fn {_name, uuid} -> uuid == a.project_filter end) do
      {name, _uuid} -> gettext("Hours — %{project}", project: name)
      nil -> gettext("Hours — all projects")
    end
  end

  # The narrowing in words, for the report's head.
  defp filter_words(a) do
    picked = a[:picked] || %{}

    [
      picked["worker"] && {gettext("Person"), picked["worker"]},
      picked["task"] && {gettext("Task"), picked["task"]},
      a.who == "people" && {gettext("Whose time"), gettext("People only")},
      a.who == "ai" && {gettext("Whose time"), gettext("AI only")},
      a.billable == "yes" && {gettext("Billable"), gettext("billable only")},
      a.billable == "no" && {gettext("Billable"), gettext("not billable only")}
    ]
    |> Enum.filter(& &1)
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class} id={@dom}>
      <.url_state_sync :if={@mode == :all and @routed?} mode={:history} id={"#{@dom}-url-state"} />
      <.viz_palette />
      <.viz_style />
      <%!-- Inline flash on the tab: a nested live_render LV gets no app
           layout, so put_flash would otherwise be invisible. --%>
      <div
        :if={not @routed? and Phoenix.Flash.get(@flash, :error)}
        class="alert alert-error text-sm cursor-pointer"
        phx-click="lv:clear-flash"
        phx-value-key="error"
        role="alert"
      >
        {Phoenix.Flash.get(@flash, :error)}
      </div>
      <div
        :if={not @routed? and Phoenix.Flash.get(@flash, :info)}
        class="alert alert-success text-sm cursor-pointer"
        phx-click="lv:clear-flash"
        phx-value-key="info"
        role="status"
      >
        {Phoenix.Flash.get(@flash, :info)}
      </div>

      <%= cond do %>
        <% @mode == :project and is_nil(@project) -> %>
          <.empty_state icon="hero-clock" title={gettext("Project not found.")} />
        <% not @enabled? -> %>
          <.empty_state
            icon="hero-clock"
            title={gettext("Hours are turned off for this project.")}
            description={gettext("Turn on the work ledger in the project's modules & features to track time here.")}
          />
        <% @report -> %>
          <.report_view report={@report} csv_url={@csv_url} dom={@dom} offset={@offset} />
        <% true -> %>
          <div class="flex flex-wrap items-start justify-between gap-2">
            <div>
              <h2 :if={@mode == :all} class="text-xl font-semibold">{gettext("Hours")}</h2>
              <%!-- The period is what every figure below is for; the zone is
                   what every clock time below is in. --%>
              <p class="text-sm">
                <span class="font-medium">{@period_info.label}</span>
                <span class="text-base-content/50">· {tz_label(@offset)}</span>
              </p>
            </div>
            <div class="flex items-center gap-2">
              <button type="button" class="btn btn-ghost btn-sm" phx-click="open_report" id={"#{@dom}-report"}>
                <.icon name="hero-document-text" class="w-4 h-4" /> {gettext("Report")}
              </button>
              <button
                :if={loggable_projects(assigns) != []}
                type="button"
                class="btn btn-primary btn-sm"
                phx-click="open_log"
                id={"#{@dom}-log"}
              >
                <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Log time")}
              </button>
            </div>
          </div>

          <.filter_bar {assigns} />
          <.totals_row totals={@summary.totals} total={@total} />

          <%= if @summary.totals.entries == 0 and @summary.totals.ai_minutes == 0 do %>
            <.empty_state
              icon="hero-clock"
              title={gettext("No time logged in this period.")}
              description={gettext("Try a longer period, or clear the filters.")}
            />
          <% else %>
            <.day_chart :if={@chart} chart={@chart} dom={@dom} />

            <%!-- `items-start`: a card is as tall as its rows, not as its
                 neighbour. --%>
            <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 items-start">
              <.breakdown
                title={gettext("By person")}
                rows={Enum.map(@summary.by_worker, &%{label: &1.worker.name, minutes: &1.minutes, billable: &1.billable_minutes, hint: entries_hint(&1.entries), ai: &1.worker.kind == "ai_agent"})}
                id={"#{@dom}-by-person"}
              />
              <.breakdown
                title={gettext("By task")}
                rows={task_breakdown(@summary.by_task, @show_all_tasks, length(@summary.by_project) > 1)}
                more={length(@summary.by_task) > 8}
                show_all={@show_all_tasks}
                id={"#{@dom}-by-task"}
              />
              <.breakdown
                :if={length(@summary.by_project) > 1}
                title={gettext("By project")}
                rows={Enum.map(@summary.by_project, &%{label: &1.project.name || "—", minutes: &1.minutes, billable: &1.billable_minutes, hint: entries_hint(&1.entries), ai: false})}
                id={"#{@dom}-by-project"}
              />
            </div>

            <.timesheet
              sheet={@sheet}
              week={@sheet_week}
              this_week={Period.week_start(Period.today(@offset))}
              dom={@dom}
            />
            <.entries_table {assigns} />
          <% end %>
      <% end %>

      <.log_modal :if={@log_form} form={@log_form} projects={@log_projects} mode={@mode} dom={@dom} />
      <.edit_modal :if={@edit_entry} entry={@edit_entry} error={@edit_error} dom={@dom} />
      <.confirm_action_modal confirm={assigns[:confirm_action]} />
    </div>
    """
  end

  # The chart's colours are `viz_palette/1` (shared with the API keys
  # page); this is the report's print rules.
  defp viz_style(assigns) do
    ~H"""
    <style>
      @media print{
        body *{visibility:hidden !important}
        .pk-hours-report,.pk-hours-report *{visibility:visible !important}
        .pk-hours-report{position:absolute;left:0;top:0;width:100%;padding:0;margin:0;background:#fff;color:#000}
        .pk-hours-noprint,.pk-hours-noprint *{display:none !important}
      }
    </style>
    """
  end

  # ── Filter bar ──

  defp filter_bar(assigns) do
    ~H"""
    <%!-- Core's `<.select>` and `<.input>` with their own labels, and core's
         label over the pickers. The wrapper only sets the row's tier: the
         labels small, and one display for all of them (core gives a
         select's label `block` and an input's not, which is what set the
         date fields lower than the selects beside them).
         Two forms share `phx-change="filter"` (each sends what it holds);
         between them sit the pickers, outside any form, so typing in one
         is a search and not a filter change. --%>
    <div
      class="flex flex-wrap items-end gap-x-2 gap-y-3 [&_label.label]:flex [&_label.label]:mb-1 [&_label.label>span]:text-xs [&_label.label>span]:font-medium"
      id={"#{@dom}-filterbar"}
    >
      <form id={"#{@dom}-filters"} phx-change="filter" class="contents" novalidate>
        <.select
          id={"#{@dom}-period"}
          name="period"
          label={gettext("Period")}
          value={@period}
          options={Enum.map(Period.presets(), &{Period.preset_label(&1), &1})}
          class="select-sm h-8 min-h-8"
        />
        <.input
          id={"#{@dom}-from"}
          type="date"
          name="from"
          label={gettext("From")}
          value={date_value(@period_info.from_date)}
          class="input-sm h-8 min-h-8 w-36"
        />
        <.input
          id={"#{@dom}-to"}
          type="date"
          name="to"
          label={gettext("To")}
          value={date_value(@period_info.to_date)}
          class="input-sm h-8 min-h-8 w-36"
        />
      </form>

      <.pick_field
        :if={@mode == :all}
        label={gettext("Project")}
        id={"#{@dom}-pick-project"}
        chosen={@picked["project"]}
        placeholder={gettext("All projects")}
      />
      <.pick_field
        label={gettext("Person")}
        id={"#{@dom}-pick-worker"}
        chosen={@picked["worker"]}
        placeholder={gettext("Everyone")}
      />
      <.pick_field
        :if={@mode == :project}
        label={gettext("Task")}
        id={"#{@dom}-pick-task"}
        chosen={@picked["task"]}
        placeholder={gettext("All tasks")}
        class="w-64"
      />

      <form id={"#{@dom}-filters-more"} phx-change="filter" class="contents" novalidate>
        <.select
          id={"#{@dom}-who"}
          name="who"
          label={gettext("Whose time")}
          value={@who}
          options={[
            {gettext("People and AI"), "all"},
            {gettext("People only"), "people"},
            {gettext("AI only"), "ai"}
          ]}
          class="select-sm h-8 min-h-8"
        />
        <.select
          id={"#{@dom}-billable"}
          name="billable"
          label={gettext("Billable")}
          value={@billable}
          options={[{gettext("All"), "all"}, {gettext("Billable only"), "yes"}, {gettext("Not billable"), "no"}]}
          class="select-sm h-8 min-h-8"
        />
        <.field label={gettext("Sub-projects")} for={"#{@dom}-subprojects"}>
          <label class="flex items-center gap-2 h-8 cursor-pointer">
            <input type="hidden" name="subprojects" value="false" />
            <input
              type="checkbox"
              name="subprojects"
              value="true"
              checked={@subprojects}
              class="checkbox checkbox-sm"
              id={"#{@dom}-subprojects"}
            />
            <span class="text-sm">{gettext("Include")}</span>
          </label>
        </.field>
      </form>

      <button
        :if={filtered?(assigns)}
        type="button"
        class="btn btn-ghost btn-sm h-8 min-h-8"
        phx-click="clear_filters"
        id={"#{@dom}-clear"}
      >
        <.icon name="hero-x-mark" class="w-4 h-4" /> {gettext("Clear")}
      </button>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:for, :string, default: nil)
  slot(:inner_block, required: true)

  # A control core has no labelled component for (a picker, the tick),
  # under core's own label — the one `<.select>` and `<.input>` draw.
  defp field(assigns) do
    ~H"""
    <div class="min-w-0">
      <FormFieldLabel.label for={@for}>{@label}</FormFieldLabel.label>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:id, :string, required: true)
  attr(:chosen, :string, default: nil)
  attr(:placeholder, :string, required: true)
  attr(:class, :string, default: "w-44")

  # A filter picked by searching: core's `<.search_picker>`, which is the
  # box while nothing is picked (click it for the first page, type to
  # narrow) and the choice with its own × once something is (`chosen`).
  defp pick_field(assigns) do
    ~H"""
    <.field label={@label} for={@id}>
      <div class={@class}>
        <.search_picker
          id={@id}
          dropdown_id={"#{@id}-list"}
          search_event="pick_search"
          pick_event="pick_pick"
          chosen={@chosen}
          clear_event="unpick"
          clear_label={gettext("Clear %{label}", label: @label)}
          search_on_focus
          close_on_pick
          row_layout="stacked"
          placeholder={@placeholder}
          class="input input-sm h-8 min-h-8 w-full"
          searching_label={gettext("Searching…")}
          more_label={gettext("Load more")}
          loading_more_label={gettext("Loading…")}
          no_matches_label={gettext("No matches")}
        />
      </div>
    </.field>
    """
  end

  defp group_options(mode) do
    [
      {gettext("Nothing"), "none"},
      {gettext("Day"), "day"},
      {gettext("Person"), "person"},
      {gettext("Task"), "task"}
    ] ++ if(mode == :all, do: [{gettext("Project"), "project"}], else: [])
  end

  defp filtered?(a) do
    a.period != "month" or a.worker != "" or a.task != "" or a.project_filter != "" or
      a.billable != "all" or a.who != "all" or a.group != "none" or not a.subprojects
  end

  defp date_value(%Date{} = date), do: Date.to_iso8601(date)
  defp date_value(_), do: ""

  defp tz_label(offset) when offset in [nil, "", "0"], do: gettext("times in UTC")
  defp tz_label(offset), do: gettext("times in %{zone}", zone: zone_name(offset))

  defp zone_name(offset) do
    case Float.parse(offset) do
      {hours, ""} when hours >= 0 -> "UTC+#{trim_zero(hours)}"
      {hours, ""} -> "UTC#{trim_zero(hours)}"
      _ -> offset
    end
  end

  defp trim_zero(hours), do: if(hours == trunc(hours), do: trunc(hours), else: hours)

  # ── Totals ──

  attr(:totals, :map, required: true)
  attr(:total, :integer, default: 0)

  # People's time and an agent's are two sets of figures, each under its
  # own name: an agent's hours are not people's (the ledger keeps them
  # apart), and a tile that said "Total 0m" over a page full of an agent's
  # work read as a broken page. A zero stays, quiet.
  defp totals_row(assigns) do
    assigns = assign(assigns, ai_entries: max(assigns.total - assigns.totals.entries, 0))

    ~H"""
    <div class="flex flex-col gap-3 mt-2">
      <div>
        <p class="mb-1 text-xs font-medium uppercase tracking-wide text-base-content/50">{gettext("People")}</p>
        <div class="grid grid-cols-2 gap-3 md:grid-cols-none md:grid-flow-col md:auto-cols-fr">
          <.stat_tile label={gettext("Human time")} value={Format.duration(@totals.minutes)} value_class={quiet(@totals.minutes)} />
          <.stat_tile label={gettext("Billable")} value={Format.duration(@totals.billable_minutes)} value_class={quiet(@totals.billable_minutes)} />
          <.stat_tile label={gettext("People")} value={@totals.people} value_class={quiet(@totals.people)} />
          <.stat_tile label={gettext("Entries")} value={@totals.entries} value_class={quiet(@totals.entries)} />
        </div>
      </div>
      <div :if={@totals.ai_minutes > 0 or @totals.tokens > 0 or @totals.cost_cents > 0}>
        <p class="mb-1 text-xs font-medium uppercase tracking-wide text-base-content/50">{gettext("AI agents")}</p>
        <div class="grid grid-cols-2 gap-3 md:grid-cols-none md:grid-flow-col md:auto-cols-fr">
          <.stat_tile label={gettext("AI time")} value={Format.duration(@totals.ai_minutes)} value_class={quiet(@totals.ai_minutes)} />
          <.stat_tile label={gettext("Entries")} value={@ai_entries} value_class={quiet(@ai_entries)} />
          <.stat_tile :if={@totals.tokens > 0} label={gettext("AI tokens")} value={Format.tokens(@totals.tokens)} />
          <.stat_tile :if={@totals.cost_cents > 0} label={gettext("AI cost")} value={Format.cost(@totals.cost_cents)} />
        </div>
      </div>
    </div>
    """
  end

  defp quiet(n) when n in [0, 0.0], do: "opacity-40"
  defp quiet(_n), do: nil

  # ── The chart ──
  #
  # Hours per day, one column a day, stacked by person. Server-rendered
  # boxes: a column's height is its share of the busiest day, a segment's
  # its share of the column. Each column carries its own figures (a hover
  # card, and a `title` for a pointer that does not hover), the legend names
  # every colour, and the "By person" list beside it is the table view.

  attr(:chart, :map, required: true)
  attr(:dom, :string, required: true)

  defp day_chart(assigns) do
    ~H"""
    <section class="card bg-base-100 border border-base-200 shadow-sm pk-hours-viz" id={"#{@dom}-chart"}>
      <div class="card-body p-4 gap-3">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h3 class="text-sm font-semibold">{gettext("Hours per day")}</h3>
          <ul class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-base-content/70">
            <li :for={s <- @chart.series} class="flex items-center gap-1">
              <span class="inline-block w-2.5 h-2.5 rounded-sm" style={"background: var(--pkh-#{s.slot})"}></span>
              {s.name}
              <span :if={s.ai} class="badge badge-ghost badge-xs">{gettext("AI")}</span>
            </li>
          </ul>
        </div>
        <div class="flex gap-2">
          <div class="flex flex-col justify-between text-[10px] text-base-content/50 tabular-nums h-40 text-right">
            <span>{Format.duration(@chart.top)}</span>
            <span>{Format.duration(@chart.top / 2)}</span>
            <span>0</span>
          </div>
          <div class="flex-1 min-w-0">
            <%!-- Core's bar chart, one stacked bar a day: a part per person,
                 in that person's colour; hovering a bar lists its parts. The
                 two lines behind it are this page's axis (top and half). --%>
            <div class="relative h-40 border-b border-base-300">
              <div class="absolute inset-x-0 top-0 border-t border-base-content/10 pointer-events-none"></div>
              <div class="absolute inset-x-0 top-1/2 border-t border-base-content/10 pointer-events-none"></div>
              <.bar_chart
                id={"#{@dom}-chart-bars"}
                data={chart_bars(@chart)}
                y_max={@chart.top}
                height={160}
                value_format={&Format.duration/1}
                aria_label={gettext("Hours per day")}
                class="relative"
              />
            </div>
            <div class="flex justify-between text-[10px] text-base-content/50 mt-1">
              <span>{short_day(List.first(@chart.days).date)}</span>
              <span :if={length(@chart.days) > 2}>{short_day(Enum.at(@chart.days, div(length(@chart.days), 2)).date)}</span>
              <span :if={length(@chart.days) > 1}>{short_day(List.last(@chart.days).date)}</span>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # The chart's days as core's `bar_chart` takes them: a stacked bar per
  # day, its parts in the stack's order.
  defp chart_bars(chart) do
    Enum.map(chart.days, fn day ->
      %{
        label: L10n.format_date(day.date),
        parts:
          Enum.map(day.parts, fn {series, minutes} ->
            %{label: series.name, value: minutes, class: viz_slot_class(series.slot)}
          end)
      }
    end)
  end

  defp pct(_part, whole) when whole <= 0, do: 0
  defp pct(part, whole), do: Float.round(part / whole * 100, 2)

  defp short_day(%Date{} = d), do: "#{L10n.short_month(d.month)} #{d.day}"

  # ── Breakdowns ──

  attr(:title, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:id, :string, required: true)
  attr(:more, :boolean, default: false)
  attr(:show_all, :boolean, default: false)

  defp breakdown(assigns) do
    assigns =
      assign(assigns, max: assigns.rows |> Enum.map(& &1.minutes) |> Enum.max(fn -> 0.0 end))

    ~H"""
    <section class="card bg-base-100 border border-base-200 shadow-sm" id={@id}>
      <div class="card-body p-4 gap-2">
        <h3 class="text-sm font-semibold">{@title}</h3>
        <p :if={@rows == []} class="text-sm text-base-content/50">{gettext("Nothing here.")}</p>
        <ul class="flex flex-col gap-2">
          <li :for={row <- @rows} class="flex flex-col gap-0.5">
            <div class="flex items-baseline justify-between gap-2 text-sm">
              <span class="truncate min-w-0">
                {row.label}
                <span :if={row.ai} class="badge badge-ghost badge-xs ml-1">{gettext("AI")}</span>
              </span>
              <span class="shrink-0 tabular-nums font-medium">
                {Format.duration(row.minutes)}
                <span :if={row.billable > 0} class="font-normal text-base-content/50">
                  · {gettext("%{amount} billable", amount: Format.duration(row.billable))}
                </span>
              </span>
            </div>
            <div class="h-1.5 rounded-full bg-base-200 overflow-hidden" title={row.hint}>
              <div class="h-full rounded-full bg-primary/70" style={"width: #{pct(row.minutes, @max)}%"}></div>
            </div>
          </li>
        </ul>
        <button :if={@more} type="button" class="btn btn-ghost btn-xs self-start" phx-click="toggle_all_tasks">
          {if @show_all, do: gettext("Show fewer"), else: gettext("Show all")}
        </button>
      </div>
    </section>
    """
  end

  defp entries_hint(count),
    do: ngettext("%{count} entry", "%{count} entries", count, count: count)

  defp branch_hint(row, below) when below > 0 do
    gettext("%{own} on the task itself, %{below} on its subtasks",
      own: Format.duration(row.minutes),
      below: Format.duration(below)
    )
  end

  defp branch_hint(row, _below), do: entries_hint(row.entries)

  defp task_breakdown(rows, show_all?, multi_project?) do
    rows = if show_all?, do: rows, else: Enum.take(rows, 8)

    Enum.map(rows, fn row ->
      below = Map.get(row, :below_minutes, 0.0)

      %{
        label: task_label(row.task) <> if(multi_project?, do: " · #{row.project.name}", else: ""),
        # A task with subtasks reads its own time plus what is under it.
        minutes: row.minutes + below,
        billable: row.billable_minutes + Map.get(row, :below_billable_minutes, 0.0),
        hint: branch_hint(row, below),
        ai: false
      }
    end)
  end

  defp task_label(nil), do: gettext("The project itself")
  defp task_label(%{title: nil}), do: gettext("A removed task")
  defp task_label(%{title: title, ref: ref}) when is_binary(ref), do: "#{ref} · #{title}"
  defp task_label(%{title: title}), do: title

  # ── The timesheet ──

  attr(:sheet, :map, required: true)
  attr(:week, Date, required: true)
  attr(:this_week, Date, required: true)
  attr(:dom, :string, required: true)

  defp timesheet(assigns) do
    workers =
      assigns.sheet.workers
      |> Map.values()
      |> Enum.filter(&Map.has_key?(assigns.sheet.matrix, &1.key))
      |> Enum.sort_by(&String.downcase(&1.name))

    assigns = assign(assigns, workers: workers)

    ~H"""
    <section class="card bg-base-100 border border-base-200 shadow-sm" id={"#{@dom}-sheet"}>
      <div class="card-body p-4 gap-2">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h3 class="text-sm font-semibold">{gettext("Timesheet")}</h3>
          <%!-- Core's date control, a week a press; the tab has no URL of
               its own, so it sends an event. --%>
          <.date_nav
            id={"#{@dom}-sheet-week"}
            date={@week}
            today={@this_week}
            step={7}
            label={"#{short_day(@week)} – #{short_day(Date.add(@week, 6))}"}
            today_label={gettext("This week")}
            event="sheet_week"
          />
        </div>
        <p :if={@workers == []} class="text-sm text-base-content/50">
          {gettext("Nothing logged for %{from} – %{to}.", from: short_day(@week), to: short_day(Date.add(@week, 6)))}
        </p>
        <.table_default
          :if={@workers != []}
          id={"#{@dom}-sheet-table"}
          size="sm"
          wrapper_class="overflow-x-auto"
        >
          <.table_default_header>
            <.table_default_row>
              <.table_default_header_cell>{gettext("Person")}</.table_default_header_cell>
              <.table_default_header_cell :for={day <- @sheet.days} class="text-right whitespace-nowrap">
                {weekday(day)} <span class="font-normal text-base-content/50">{day.day}</span>
              </.table_default_header_cell>
              <.table_default_header_cell class="text-right">{gettext("Week")}</.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>
          <.table_default_body>
            <.table_default_row :for={w <- @workers}>
              <.table_default_cell class="whitespace-nowrap">{w.name}</.table_default_cell>
              <.table_default_cell :for={day <- @sheet.days} class="text-right tabular-nums">
                {sheet_cell(@sheet.matrix[w.key][day])}
              </.table_default_cell>
              <.table_default_cell class="text-right tabular-nums font-medium">
                {Format.duration(@sheet.matrix[w.key] |> Map.values() |> Enum.sum())}
              </.table_default_cell>
            </.table_default_row>
          </.table_default_body>
          <.table_default_footer :if={length(@workers) > 1}>
            <.table_default_row>
              <.table_default_header_cell>{gettext("Total")}</.table_default_header_cell>
              <.table_default_header_cell :for={day <- @sheet.days} class="text-right tabular-nums">
                {sheet_cell(day_total(@sheet.matrix, day))}
              </.table_default_header_cell>
              <.table_default_header_cell class="text-right tabular-nums">
                {Format.duration(@sheet.matrix |> Map.values() |> Enum.flat_map(&Map.values/1) |> Enum.sum())}
              </.table_default_header_cell>
            </.table_default_row>
          </.table_default_footer>
        </.table_default>
      </div>
    </section>
    """
  end

  defp sheet_cell(nil), do: "—"
  defp sheet_cell(minutes) when minutes <= 0, do: "—"
  defp sheet_cell(minutes), do: Format.duration(minutes)

  defp day_total(matrix, day),
    do: matrix |> Map.values() |> Enum.map(&Map.get(&1, day, 0.0)) |> Enum.sum()

  defp weekday(%Date{} = date) do
    case Date.day_of_week(date) do
      1 -> gettext("Mon")
      2 -> gettext("Tue")
      3 -> gettext("Wed")
      4 -> gettext("Thu")
      5 -> gettext("Fri")
      6 -> gettext("Sat")
      7 -> gettext("Sun")
    end
  end

  # ── The entries ──

  defp entries_table(assigns) do
    assigns =
      assign(assigns,
        groups: grouped(assigns.rows, assigns.group, assigns.offset),
        multi?: assigns.mode == :all or length(assigns.summary.by_project) > 1,
        sort: %{by: assigns.sort_by, dir: assigns.sort_dir},
        # A Note column with nothing in it is a blank stripe: it shows once
        # a row on screen has a note.
        notes?: Enum.any?(assigns.rows, &(&1.entry.note not in [nil, ""]))
      )

    ~H"""
    <section class="flex flex-col gap-2" id={"#{@dom}-entries"}>
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h3 class="text-sm font-semibold">
          {gettext("Entries")} <span class="font-normal text-base-content/60">· {@total}</span>
        </h3>
        <form id={"#{@dom}-group-form"} phx-change="group" class="flex items-center gap-2">
          <label for={"#{@dom}-group"} class="text-xs font-medium text-base-content/60">{gettext("Group by")}</label>
          <.select
            id={"#{@dom}-group"}
            name="group"
            value={@group}
            options={group_options(@mode)}
            class="select-xs"
          />
        </form>
      </div>
      <.table_default id={"#{@dom}-entries-table"} size="sm">
        <.table_default_header>
          <.table_default_row>
            <.sort_header_cell field={:at} sort={@sort}>{gettext("When")}</.sort_header_cell>
            <.sort_header_cell field={:worker} sort={@sort}>{gettext("Who")}</.sort_header_cell>
            <.table_default_header_cell :if={@multi?}>{gettext("Project")}</.table_default_header_cell>
            <.sort_header_cell field={:task} sort={@sort}>{gettext("Task")}</.sort_header_cell>
            <.sort_header_cell field={:amount} sort={@sort} align={:right}>{gettext("Time")}</.sort_header_cell>
            <.table_default_header_cell :if={@notes?}>{gettext("Note")}</.table_default_header_cell>
            <.table_default_header_cell class="w-px"><span class="sr-only">{gettext("Actions")}</span></.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <%= for {label, minutes, rows} <- @groups do %>
            <tr :if={label} class="bg-base-200/50">
              <td colspan={if @multi?, do: 4, else: 3} class="font-semibold">{label}</td>
              <td class="text-right tabular-nums font-semibold">{Format.duration(minutes)}</td>
              <td colspan={if @notes?, do: 2, else: 1}></td>
            </tr>
            <.table_default_row :for={row <- rows} id={"#{@dom}-entry-#{row.entry.uuid}"}>
              <.table_default_cell class="whitespace-nowrap">
                <% {day, time} = when_parts(row.at, @offset) %>
                {day} <span class="text-base-content/50 tabular-nums">{time}</span>
              </.table_default_cell>
              <.table_default_cell class="whitespace-nowrap">
                {row.worker.name}
                <span :if={row.worker.kind == "ai_agent"} class="badge badge-ghost badge-xs ml-1">{gettext("AI")}</span>
              </.table_default_cell>
              <.table_default_cell :if={@multi?} class="whitespace-nowrap">
                <.smart_link
                  navigate={Paths.project(row.project.uuid)}
                  emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => row.project.uuid}}}
                  embed_mode={@embed_mode}
                  class="link link-hover"
                >
                  {row.project.name || "—"}
                </.smart_link>
              </.table_default_cell>
              <.table_default_cell>
                <%= if row.task && row.task.title do %>
                  <.smart_link
                    navigate={Paths.project_tasks(row.project.uuid) <> "?task=#{row.task.uuid}"}
                    emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => row.project.uuid, "task" => row.task.uuid}}}
                    embed_mode={@embed_mode}
                    class="link link-hover text-left"
                  >
                    <.ref_chip ref={row.task[:ref]} /> {row.task.title}
                  </.smart_link>
                <% else %>
                  <span class="text-base-content/50">{task_label(row.task)}</span>
                <% end %>
              </.table_default_cell>
              <.table_default_cell class="text-right whitespace-nowrap tabular-nums">
                {Format.duration(Decimal.to_float(row.entry.amount))}
                <span :if={row.entry.billable} class="badge badge-primary badge-outline badge-xs ml-1">{gettext("billable")}</span>
                <span :if={row.entry.uuid in @invoiced} class="badge badge-ghost badge-xs ml-1">{gettext("invoiced")}</span>
              </.table_default_cell>
              <.table_default_cell :if={@notes?} class="text-base-content/70 max-w-md">
                <span class="line-clamp-2">{row.entry.note}</span>
              </.table_default_cell>
              <.table_default_cell class="text-right whitespace-nowrap">
                <.table_row_menu
                  :if={row_amendable?(assigns, row)}
                  id={"#{@dom}-entry-menu-#{row.entry.uuid}"}
                >
                  <.table_row_menu_button
                    phx-click="edit_entry"
                    phx-value-uuid={row.entry.uuid}
                    icon="hero-pencil"
                    label={gettext("Edit")}
                  />
                  <.table_row_menu_divider />
                  <.table_row_menu_button
                    {ConfirmAction.ask("delete_entry",
                      uuid: row.entry.uuid,
                      title: gettext("Remove entry"),
                      message: gettext("Remove %{amount} logged by %{name}? The project's activity keeps a record of it.", amount: Format.duration(Decimal.to_float(row.entry.amount)), name: row.worker.name),
                      confirm: gettext("Remove")
                    )}
                    icon="hero-trash"
                    label={gettext("Remove")}
                    variant="error"
                  />
                </.table_row_menu>
              </.table_default_cell>
            </.table_default_row>
          <% end %>
        </.table_default_body>
      </.table_default>
      <.load_more
        :if={length(@rows) < @total}
        loaded={length(@rows)}
        total={@total}
        noun_plural={gettext("entries")}
      />
    </section>
    """
  end

  # An entry's moment as the page says dates everywhere else ("Oct 8,
  # 2026") with the clock time beside it, in the viewer's zone.
  defp when_parts(at, offset) do
    case String.split(Report.stamp(at, offset), " ", parts: 2) do
      [day, time] ->
        case Date.from_iso8601(day) do
          {:ok, date} -> {L10n.format_date(date), time}
          _ -> {day, time}
        end

      [other] ->
        {other, ""}
    end
  end

  # The menu shows where the write would be allowed: a time entry, not on
  # an invoice, the viewer's own (with `:log_time`) or anyone's (with
  # `:edit_tasks`). `amendable/2` decides again when the event arrives.
  defp row_amendable?(assigns, row) do
    perms = Map.get(assigns.perms, row.project.uuid, %{})

    row.entry.kind == "time" and row.entry.uuid not in assigns.invoiced and
      (perms[:manage] == true or (perms[:log] == true and row_mine?(assigns, row)))
  end

  # The loaded rows under their group's heading, in the order they came:
  # `[{label | nil, minutes, rows}]`. A group's figure is the sum of the
  # rows on screen.
  defp grouped(rows, "none", _offset), do: [{nil, 0, rows}]

  defp grouped(rows, group, offset) do
    rows
    |> Enum.chunk_by(&group_key(&1, group, offset))
    |> Enum.reduce([], fn chunk, acc ->
      key = group_key(hd(chunk), group, offset)

      case Enum.find_index(acc, fn {k, _rows} -> k == key end) do
        nil -> acc ++ [{key, chunk}]
        i -> List.update_at(acc, i, fn {k, rows} -> {k, rows ++ chunk} end)
      end
    end)
    |> Enum.map(fn {key, rows} ->
      minutes = rows |> Enum.map(&Decimal.to_float(&1.entry.amount)) |> Enum.sum()
      {group_label(key, group), minutes, rows}
    end)
  end

  defp group_key(row, "day", offset),
    do: row.at |> KitDate.shift_to_offset(offset) |> DateTime.to_date()

  defp group_key(row, "person", _offset), do: {row.worker.key, row.worker.name}
  defp group_key(row, "task", _offset), do: row.task
  defp group_key(row, "project", _offset), do: row.project

  defp group_label(%Date{} = date, "day"), do: "#{weekday(date)}, #{L10n.format_date(date)}"
  defp group_label({_key, name}, "person"), do: name
  defp group_label(task, "task"), do: task_label(task)
  defp group_label(project, "project"), do: project.name || "—"

  # ── Log-time modal ──

  attr(:form, :map, required: true)
  attr(:projects, :list, required: true)
  attr(:mode, :atom, required: true)
  attr(:dom, :string, required: true)

  defp log_modal(assigns) do
    ~H"""
    <.modal show on_close="close_log" id={"#{@dom}-log-modal"} max_width="md" close_guard={:input}>
      <:title>{gettext("Log time")}</:title>
      <form id={"#{@dom}-log-form"} phx-change="log_change" phx-submit="save_log" class="flex flex-col gap-3 mt-2" novalidate>
        <p :if={@form.error} class="alert alert-error text-sm py-2" role="alert">{@form.error}</p>
        <%= if @mode == :all do %>
          <.select
            id={"#{@dom}-log-project"}
            name="project"
            label={gettext("Project")}
            value={@form.values["project"]}
            options={@projects}
            class="select-sm"
          />
        <% else %>
          <input type="hidden" name="project" value={@form.values["project"]} />
        <% end %>
        <div class="flex items-start gap-2">
          <.input
            id={"#{@dom}-log-date"}
            type="date"
            name="date"
            label={gettext("Day")}
            value={@form.values["date"]}
            class="input-sm"
            wrapper_class="flex-1"
          />
          <.input
            id={"#{@dom}-log-time"}
            type="time"
            name="time"
            label={gettext("Started at (optional)")}
            value={@form.values["time"]}
            class="input-sm"
            wrapper_class="flex-1"
          />
        </div>
        <.input
          id={"#{@dom}-log-duration"}
          name="duration"
          label={gettext("How long")}
          value={@form.values["duration"]}
          placeholder={gettext("1h 30m, 1:30, 90 or 1.5h")}
          class="input-sm"
          autocomplete="off"
        />
        <.select
          :if={length(@form.people) > 1}
          id={"#{@dom}-log-person"}
          name="person"
          label={gettext("Who")}
          value={@form.values["person"]}
          options={@form.people}
          class="select-sm"
        />
        <%!-- Searched, not listed: a project can hold any number of
             tasks. Empty means the project itself. --%>
        <div>
          <span class="label mb-2 block"><span class="font-semibold">{gettext("Task")}</span></span>
          <input type="hidden" name="task" value={@form.values["task"]} />
          <.search_picker
            id={"#{@dom}-pick-logtask"}
            dropdown_id={"#{@dom}-pick-logtask-list"}
            search_event="pick_search"
            pick_event="pick_pick"
            chosen={@form.task_label}
            clear_event="unpick"
            clear_label={gettext("Clear %{label}", label: gettext("Task"))}
            search_on_focus
            close_on_pick
            row_layout="stacked"
            placeholder={gettext("The project itself — or search a task")}
            class="input input-sm w-full"
            searching_label={gettext("Searching…")}
            more_label={gettext("Load more")}
            loading_more_label={gettext("Loading…")}
            no_matches_label={gettext("No matches")}
          />
        </div>
        <.input
          id={"#{@dom}-log-note"}
          name="note"
          label={gettext("Note (optional)")}
          value={@form.values["note"]}
          placeholder={gettext("What was the time spent on?")}
          class="input-sm"
        />
        <label class="label cursor-pointer justify-start gap-2">
          <input type="hidden" name="billable" value="false" />
          <input
            type="checkbox"
            name="billable"
            value="true"
            checked={@form.values["billable"]}
            class="checkbox checkbox-primary checkbox-sm"
            id={"#{@dom}-log-billable"}
          />
          <span class="label-text">{gettext("Billable")}</span>
        </label>
        <div class="modal-action">
          <button type="button" phx-click="close_log" class="btn btn-ghost btn-sm">{gettext("Cancel")}</button>
          <button type="submit" class="btn btn-primary btn-sm" phx-disable-with={gettext("Saving…")}>
            {gettext("Log time")}
          </button>
        </div>
      </form>
    </.modal>
    """
  end

  # ── Edit modal ──

  attr(:entry, :map, required: true)
  attr(:error, :string, default: nil)
  attr(:dom, :string, required: true)

  defp edit_modal(assigns) do
    ~H"""
    <.modal show on_close="close_edit" id={"#{@dom}-edit-modal"} max_width="sm" close_guard={:input}>
      <:title>{gettext("Edit entry")}</:title>
      <form id={"#{@dom}-edit-form"} phx-submit="save_edit" class="flex flex-col gap-3 mt-2" novalidate>
        <p :if={@error} class="alert alert-error text-sm py-2" role="alert">{@error}</p>
        <.input
          id={"#{@dom}-edit-duration"}
          name="duration"
          label={gettext("How long")}
          value={Format.duration(Decimal.to_float(@entry.amount))}
          class="input-sm"
          autocomplete="off"
        />
        <label class="label cursor-pointer justify-start gap-2">
          <input type="hidden" name="billable" value="false" />
          <input
            type="checkbox"
            name="billable"
            value="true"
            checked={@entry.billable}
            class="checkbox checkbox-primary checkbox-sm"
            id={"#{@dom}-edit-billable"}
          />
          <span class="label-text">{gettext("Billable")}</span>
        </label>
        <p class="text-xs text-base-content/60">
          {gettext("The project's activity keeps the figure before and after.")}
        </p>
        <div class="modal-action">
          <button type="button" phx-click="close_edit" class="btn btn-ghost btn-sm">{gettext("Cancel")}</button>
          <button type="submit" class="btn btn-primary btn-sm" phx-disable-with={gettext("Saving…")}>
            {gettext("Save")}
          </button>
        </div>
      </form>
    </.modal>
    """
  end

  # ── The report ──
  #
  # The page's content is replaced by the report: a sheet to read, print
  # (the browser's print gives the PDF — everything but the sheet is hidden
  # on paper), copy as text, or download as CSV. Not a dialog on purpose:
  # a dialog prints as the box it is shown in.

  attr(:report, :map, required: true)
  attr(:csv_url, :string, default: nil)
  attr(:dom, :string, required: true)
  attr(:offset, :string, required: true)

  defp report_view(assigns) do
    ~H"""
    <div class="flex flex-col gap-4" id={"#{@dom}-report-view"}>
      <div class="pk-hours-noprint flex flex-wrap items-center gap-2">
        <button type="button" class="btn btn-ghost btn-sm" phx-click="close_report">
          <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("Back to hours")}
        </button>
        <span class="flex-1"></span>
        <button type="button" class="btn btn-sm" onclick="window.print()" id={"#{@dom}-report-print"}>
          <.icon name="hero-printer" class="w-4 h-4" /> {gettext("Print or save as PDF")}
        </button>
        <button
          type="button"
          class="btn btn-sm"
          id={"#{@dom}-report-copy"}
          phx-hook="CopyToClipboard"
          data-copy-target={"##{@dom}-report-text"}
        >
          <span data-copy-idle>{gettext("Copy as text")}</span>
          <span data-copy-feedback class="hidden">{gettext("Copied!")}</span>
        </button>
        <%= if @csv_url do %>
          <a class="btn btn-sm btn-primary" href={@csv_url} download={Report.filename(@report)} id={"#{@dom}-report-csv"}>
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> {gettext("Download CSV")}
          </a>
        <% else %>
          <button type="button" class="btn btn-sm" phx-click="prepare_csv" id={"#{@dom}-report-csv-prepare"}>
            <.icon name="hero-table-cells" class="w-4 h-4" /> {gettext("CSV")}
          </button>
        <% end %>
      </div>
      <p class="pk-hours-noprint text-xs text-base-content/60">
        {gettext("To print, use the button or your browser's Print (Ctrl+P or ⌘P) and choose \"Save as PDF\" for a file.")}
      </p>

      <article class="pk-hours-report card bg-base-100 border border-base-200 p-6 flex flex-col gap-4" id={"#{@dom}-report-sheet"}>
        <header>
          <h1 class="text-xl font-bold">{@report.title}</h1>
          <p class="text-sm">{gettext("Period")}: {@report.period}</p>
          <p :for={{label, value} <- @report.filters} class="text-sm">{label}: {value}</p>
          <p class="text-xs opacity-60">
            {gettext("Generated %{at}", at: Report.stamp(@report.generated_at, @offset))} · {tz_label(@offset)}
          </p>
        </header>

        <dl class="grid grid-cols-2 sm:grid-cols-4 gap-3 text-sm">
          <div>
            <dt class="opacity-60">{gettext("Human time")}</dt>
            <dd class="font-semibold">
              {Format.duration(@report.totals.minutes)} ({Format.decimal_hours(@report.totals.minutes)} h)
            </dd>
          </div>
          <div>
            <dt class="opacity-60">{gettext("Billable")}</dt>
            <dd class="font-semibold">
              {Format.duration(@report.totals.billable_minutes)} ({Format.decimal_hours(@report.totals.billable_minutes)} h)
            </dd>
          </div>
          <div :if={@report.totals.ai_minutes > 0}>
            <dt class="opacity-60">{gettext("AI time")}</dt>
            <dd class="font-semibold">{Format.duration(@report.totals.ai_minutes)}</dd>
          </div>
          <div :if={@report.totals.tokens > 0}>
            <dt class="opacity-60">{gettext("AI tokens")}</dt>
            <dd class="font-semibold">{Format.tokens(@report.totals.tokens)}</dd>
          </div>
          <div :if={@report.totals.cost_cents > 0}>
            <dt class="opacity-60">{gettext("AI cost")}</dt>
            <dd class="font-semibold">{Format.cost(@report.totals.cost_cents)}</dd>
          </div>
        </dl>

        <.report_table
          :if={@report.by_worker != []}
          title={gettext("By person")}
          head={gettext("Person")}
          rows={Enum.map(@report.by_worker, &{report_worker(&1.worker), &1})}
        />
        <.report_table
          :if={length(@report.by_project) > 1}
          title={gettext("By project")}
          head={gettext("Project")}
          rows={Enum.map(@report.by_project, &{&1.project.name || "—", &1})}
        />
        <.report_table
          :if={@report.by_task != []}
          title={gettext("By task")}
          head={gettext("Task")}
          rows={Enum.map(@report.by_task, &{task_label(&1.task), &1})}
        />

        <section :if={@report.entries != []}>
          <h2 class="text-sm font-semibold mb-1">{gettext("Entries")}</h2>
          <.table_default size="xs" wrapper_class="overflow-x-auto">
            <.table_default_header>
              <.table_default_row>
                <.table_default_header_cell>{gettext("When")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("Who")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("Task")}</.table_default_header_cell>
                <.table_default_header_cell class="text-right">{gettext("Time")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("Note")}</.table_default_header_cell>
              </.table_default_row>
            </.table_default_header>
            <.table_default_body>
              <.table_default_row :for={row <- @report.entries}>
                <.table_default_cell class="whitespace-nowrap">{Report.stamp(row.at, @offset)}</.table_default_cell>
                <.table_default_cell class="whitespace-nowrap">{report_worker(row.worker)}</.table_default_cell>
                <.table_default_cell>{task_label(row.task)}</.table_default_cell>
                <.table_default_cell class="text-right whitespace-nowrap tabular-nums">
                  {Format.duration(Decimal.to_float(row.entry.amount))}{if row.entry.billable, do: " *"}
                </.table_default_cell>
                <.table_default_cell>{row.entry.note}</.table_default_cell>
              </.table_default_row>
            </.table_default_body>
          </.table_default>
          <p class="text-xs opacity-60 mt-1">* {gettext("billable")}</p>
          <p :if={Report.truncated?(@report)} class="text-xs opacity-60">
            {gettext("The first %{shown} of %{total} entries.", shown: length(@report.entries), total: @report.total_entries)}
          </p>
        </section>
      </article>

      <textarea id={"#{@dom}-report-text"} readonly rows="8" class="pk-hours-noprint textarea textarea-bordered textarea-sm font-mono text-xs w-full leading-snug" aria-label={gettext("The report as text")}>{Report.text(@report)}</textarea>
    </div>
    """
  end

  # On paper there is no badge: an agent's row says so in words.
  defp report_worker(%{kind: "ai_agent", name: name}), do: "#{name} (#{gettext("AI")})"
  defp report_worker(%{name: name}), do: name

  attr(:title, :string, required: true)
  attr(:head, :string, required: true)
  attr(:rows, :list, required: true)

  defp report_table(assigns) do
    ~H"""
    <section>
      <h2 class="text-sm font-semibold mb-1">{@title}</h2>
      <.table_default size="xs" wrapper_class="overflow-x-auto">
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>{@head}</.table_default_header_cell>
            <.table_default_header_cell class="text-right">{gettext("Time")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right">{gettext("Hours")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right">{gettext("Billable")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right">{gettext("Entries")}</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={{label, row} <- @rows}>
            <.table_default_cell>{label}</.table_default_cell>
            <.table_default_cell class="text-right tabular-nums whitespace-nowrap">{Format.duration(row.minutes)}</.table_default_cell>
            <.table_default_cell class="text-right tabular-nums whitespace-nowrap">{Format.decimal_hours(row.minutes)}</.table_default_cell>
            <.table_default_cell class="text-right tabular-nums whitespace-nowrap">{Format.duration(row.billable_minutes)}</.table_default_cell>
            <.table_default_cell class="text-right tabular-nums whitespace-nowrap">{row.entries}</.table_default_cell>
          </.table_default_row>
        </.table_default_body>
      </.table_default>
    </section>
    """
  end
end
