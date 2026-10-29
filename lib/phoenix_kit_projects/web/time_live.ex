defmodule PhoenixKitProjects.Web.TimeLive do
  @moduledoc """
  **Time** — the managers' page: each person down the side, the day's hours
  across, and every task they had a reason to touch that day as its own line
  inside their row, showing where it was **planned** (a dashed ghost), when it
  was **actually** done (a solid bar, live while in progress), its
  **deadline** (a pin) and time **logged** on it.

  A day (work hours 08:00–17:00 by default, widened to cover anything that
  happened outside them, or the full 24 h) or a week (seven day columns, each
  a mini 08–17 strip). Tasks for a team or a department keep their plan on the
  team's row; the work sits on the person who did it. Tasks assigned but on
  no clock at all are counted in the "Unscheduled" strip.

  The data is `PhoenixKitProjects.TimeBoard`'s; every project the viewer may
  see (the Hours page's rule). A line opens the task; "Set deadline" changes a
  task's deadline under the task form's own permission.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitProjects.{L10n, Paths, TimeBoard}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.{Assignment, Project}
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  @default_wrapper_class "flex flex-col w-full px-4 pt-2 pb-4 gap-4"
  # Lines shown per row before "+N more".
  @visible_lines 6
  @tick_ms 60_000

  @impl true
  def mount(_params, session, socket) do
    WebHelpers.maybe_put_locale(session)

    socket =
      socket
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)
      |> WebHelpers.attach_open_embed_hook()

    scope = socket.assigns[:phoenix_kit_current_scope]

    if Scope.has_module_access?(scope, PhoenixKitProjects.module_key()) do
      if connected?(socket) do
        ProjectsPubSub.subscribe(ProjectsPubSub.topic_all())
        :timer.send_interval(@tick_ms, self(), :tick)
      end

      today = L10n.local_date(DateTime.utc_now())

      {:ok,
       socket
       |> assign(
         page_title: gettext("Time"),
         page_section: gettext("Projects"),
         page_section_path: Paths.projects(),
         wrapper_class: Map.get(session, "wrapper_class", @default_wrapper_class),
         view: :day,
         date: today,
         full_day?: false,
         project_filter: nil,
         expanded: MapSet.new(),
         deadline_edit: nil,
         deadline_error: nil,
         project_options: TimeBoard.project_options(scope, L10n.current_content_lang())
       )
       |> load()}
    else
      {:ok,
       socket
       |> assign(page_title: gettext("Time"))
       |> put_flash(:error, gettext("You don't have access to this page."))
       |> redirect(to: Routes.path("/admin"))}
    end
  end

  # ── Data ────────────────────────────────────────────────────────

  defp load(socket) do
    %{view: view, date: date} = socket.assigns
    scope = socket.assigns[:phoenix_kit_current_scope]
    {from, to} = range(view, date)
    now = DateTime.utc_now()
    lang = L10n.current_content_lang()

    board =
      TimeBoard.load(scope, from, to,
        now: now,
        lang: lang,
        project_uuid: socket.assigns.project_filter
      )

    projects =
      (board.people ++ board.groups)
      |> Enum.flat_map(& &1.lines)
      |> Enum.map(& &1.project)
      |> Enum.reject(&is_nil/1)

    now_local = now |> L10n.local() |> DateTime.to_naive()

    assign(socket,
      board: board,
      from: from,
      to: to,
      today: NaiveDateTime.to_date(now_local),
      now_local: now_local,
      editable: TimeBoard.editable_projects(scope, projects),
      lanes: lanes(view, from, to, socket.assigns.full_day?, board, now_local)
    )
  end

  defp range(:day, date), do: {date, date}

  defp range(:week, date) do
    monday = Date.add(date, 1 - Date.day_of_week(date))
    {monday, Date.add(monday, 6)}
  end

  # The board's columns: one lane per day, each with its visible minutes.
  # A day's work-hours axis widens to the whole hours anything on it covers.
  defp lanes(view, from, to, full?, board, now_local) do
    {ws, we} = TimeBoard.work_hours()
    base = if full?, do: {0, 1440}, else: {minute_of(ws), minute_of(we)}

    Enum.map(Date.range(from, to), fn date ->
      {s, e} =
        if view == :day and not full?,
          do: widen(base, date, board, now_local),
          else: base

      %{date: date, start: s, end: e}
    end)
  end

  defp widen({s, e}, date, board, now_local) do
    day_start = NaiveDateTime.new!(date, ~T[00:00:00])
    day_end = NaiveDateTime.add(day_start, 86_400)

    minutes =
      (board.people ++ board.groups)
      |> Enum.flat_map(& &1.lines)
      |> Enum.flat_map(&line_instants/1)
      |> Enum.flat_map(fn
        {f, t} ->
          f = max_n(f, day_start)
          t = min_n(t, day_end)

          if NaiveDateTime.compare(f, t) == :lt,
            do: [
              NaiveDateTime.diff(f, day_start, :second) / 60,
              NaiveDateTime.diff(t, day_start, :second) / 60
            ],
            else: []

        t ->
          if NaiveDateTime.compare(t, day_start) != :lt and
               NaiveDateTime.compare(t, day_end) == :lt,
             do: [NaiveDateTime.diff(t, day_start, :second) / 60],
             else: []
      end)

    minutes =
      if NaiveDateTime.to_date(now_local) == date,
        do: [NaiveDateTime.diff(now_local, day_start, :second) / 60 | minutes],
        else: minutes

    case minutes do
      [] ->
        {s, e}

      _ ->
        lo = minutes |> Enum.min() |> floor_hour()
        hi = minutes |> Enum.max() |> ceil_hour()
        {min(s, lo), max(e, hi)}
    end
  end

  defp line_instants(line) do
    spans = Enum.flat_map(line.logged, &List.wrap(&1.span))

    line.planned ++
      List.wrap(line.actual) ++
      spans ++ Enum.reject([line.deadline, line.done_at], &is_nil/1)
  end

  defp floor_hour(m), do: m |> Kernel./(60) |> Float.floor() |> trunc() |> Kernel.*(60)
  defp ceil_hour(m), do: min(1440, m |> Kernel./(60) |> Float.ceil() |> trunc() |> Kernel.*(60))
  defp minute_of(%Time{hour: h, minute: m}), do: h * 60 + m

  defp max_n(a, b), do: if(NaiveDateTime.compare(a, b) == :lt, do: b, else: a)
  defp min_n(a, b), do: if(NaiveDateTime.compare(a, b) == :gt, do: b, else: a)

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("set_view", %{"view" => v}, socket) when v in ["day", "week"] do
    {:noreply, socket |> assign(view: String.to_existing_atom(v)) |> reset_ui() |> load()}
  end

  def handle_event("step", %{"dir" => dir}, socket) when dir in ["prev", "next"] do
    days = if socket.assigns.view == :week, do: 7, else: 1
    days = if dir == "prev", do: -days, else: days

    {:noreply,
     socket |> assign(date: Date.add(socket.assigns.date, days)) |> reset_ui() |> load()}
  end

  def handle_event("today", _params, socket) do
    {:noreply,
     socket
     |> assign(date: L10n.local_date(DateTime.utc_now()))
     |> reset_ui()
     |> load()}
  end

  def handle_event("pick_date", %{"date" => value}, socket) do
    case Date.from_iso8601(value || "") do
      {:ok, date} -> {:noreply, socket |> assign(date: date) |> reset_ui() |> load()}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_full_day", _params, socket) do
    {:noreply, socket |> assign(full_day?: not socket.assigns.full_day?) |> load()}
  end

  def handle_event("filter_project", %{"project" => uuid}, socket) do
    filter =
      if Enum.any?(socket.assigns.project_options, fn {_n, u} -> u == uuid end), do: uuid

    {:noreply, socket |> assign(project_filter: filter) |> reset_ui() |> load()}
  end

  def handle_event("expand_row", %{"row" => row}, socket) do
    {:noreply, assign(socket, expanded: MapSet.put(socket.assigns.expanded, row))}
  end

  def handle_event("edit_deadline", %{"line" => line}, socket) do
    {:noreply, assign(socket, deadline_edit: line, deadline_error: nil)}
  end

  def handle_event("cancel_deadline", _params, socket) do
    {:noreply, assign(socket, deadline_edit: nil, deadline_error: nil)}
  end

  def handle_event("save_deadline", %{"uuid" => uuid} = params, socket) when is_binary(uuid) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    case TimeBoard.set_deadline(scope, uuid, params["deadline"],
           actor_uuid: PhoenixKitProjects.Activity.actor_uuid(socket)
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(deadline_edit: nil, deadline_error: nil)
         |> put_flash(:info, gettext("Deadline saved."))
         |> load()}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, gettext("You don't have permission to change this task."))}

      {:error, :not_found} ->
        {:noreply,
         socket |> assign(deadline_edit: nil) |> put_flash(:error, gettext("Task not found."))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, deadline_error: gettext("That deadline could not be saved."))}
    end
  end

  defp reset_ui(socket), do: assign(socket, expanded: MapSet.new(), deadline_edit: nil)

  # ── PubSub / clock ──────────────────────────────────────────────

  @impl true
  def handle_info(:tick, socket) do
    if Date.compare(socket.assigns.from, socket.assigns.today) != :gt and
         Date.compare(socket.assigns.to, socket.assigns.today) != :lt,
       do: {:noreply, load(socket)},
       else: {:noreply, socket}
  end

  # Announced beside `:assignment_updated` (which reloads).
  def handle_info({:projects, :assignment_status_changed, _payload}, socket),
    do: {:noreply, socket}

  def handle_info({:projects, _event, _payload}, socket), do: {:noreply, load(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        rows: assigns.board.people,
        unscheduled_total:
          assigns.board.unscheduled |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
      )

    ~H"""
    <div class={@wrapper_class}>
      <div class="card bg-base-100 shadow">
        <div class="card-body p-3 gap-3">
          <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
            <h2 class="card-title text-lg shrink-0">
              <.icon name="hero-calendar-days" class="w-5 h-5 text-primary" /> {gettext("Time")}
            </h2>
            <div role="tablist" class="join">
              <button
                :for={{v, label} <- [{"day", gettext("Day")}, {"week", gettext("Week")}]}
                type="button"
                role="tab"
                aria-selected={to_string(Atom.to_string(@view) == v)}
                phx-click="set_view"
                phx-value-view={v}
                class={["btn btn-sm join-item", Atom.to_string(@view) == v && "btn-active"]}
              >
                {label}
              </button>
            </div>
            <div class="join">
              <button
                type="button"
                class="btn btn-sm join-item"
                phx-click="step"
                phx-value-dir="prev"
                aria-label={gettext("Previous")}
              >
                <.icon name="hero-chevron-left" class="w-4 h-4" />
              </button>
              <button type="button" class="btn btn-sm join-item" phx-click="today">
                {gettext("Today")}
              </button>
              <button
                type="button"
                class="btn btn-sm join-item"
                phx-click="step"
                phx-value-dir="next"
                aria-label={gettext("Next")}
              >
                <.icon name="hero-chevron-right" class="w-4 h-4" />
              </button>
            </div>
            <form id="time-date-form" phx-change="pick_date">
              <input
                type="date"
                name="date"
                value={Date.to_iso8601(@date)}
                class="input input-sm"
                aria-label={gettext("Date")}
              />
            </form>
            <span class="font-semibold">{range_label(@view, @from, @to)}</span>
            <div class="flex flex-wrap items-center gap-3 ml-auto">
              <label :if={@view == :day} class="label cursor-pointer gap-2 text-sm">
                <input
                  type="checkbox"
                  class="toggle toggle-sm"
                  checked={@full_day?}
                  phx-click="toggle_full_day"
                />
                {gettext("Full 24 h")}
              </label>
              <form :if={@project_options != []} id="time-project-form" phx-change="filter_project">
                <select name="project" class="select select-sm" aria-label={gettext("Project")}>
                  <option value="">{gettext("All projects")}</option>
                  <option :for={{name, uuid} <- @project_options} value={uuid} selected={uuid == @project_filter}>
                    {name}
                  </option>
                </select>
              </form>
            </div>
          </div>
          <.legend />
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body p-0 overflow-x-auto">
          <div id="time-board" class={if(@view == :week, do: "min-w-[1100px]", else: "min-w-[900px]")}>
            <.axis_header lanes={@lanes} view={@view} today={@today} />

            <%= if @rows == [] and @board.groups == [] do %>
              <div class="p-6 text-center text-base-content/60">
                {gettext("Nothing to show for this range.")}
              </div>
            <% end %>

            <.board_row
              :for={row <- @rows}
              row={row}
              lanes={@lanes}
              view={@view}
              now_local={@now_local}
              expanded={@expanded}
              editable={@editable}
              deadline_edit={@deadline_edit}
              deadline_error={@deadline_error}
              embed_mode={@embed_mode}
              unscheduled={Map.get(@board.unscheduled, row.key, [])}
            />

            <%= if @board.groups != [] do %>
              <div class="px-3 py-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60 bg-base-200 border-y border-base-300">
                {gettext("Teams & departments")}
              </div>
              <.board_row
                :for={row <- @board.groups}
                row={row}
                lanes={@lanes}
                view={@view}
                now_local={@now_local}
                expanded={@expanded}
                editable={@editable}
                deadline_edit={@deadline_edit}
                deadline_error={@deadline_error}
                embed_mode={@embed_mode}
                unscheduled={Map.get(@board.unscheduled, row.key, [])}
              />
            <% end %>
          </div>
        </div>
      </div>

      <div :if={@unscheduled_total > 0} class="card bg-base-100 shadow">
        <div class="card-body p-3 gap-2">
          <h3 class="font-semibold flex items-center gap-2">
            <.icon name="hero-inbox-stack" class="w-4 h-4" />
            {gettext("Assigned, no clock")}
            <span class="badge badge-sm">{@unscheduled_total}</span>
          </h3>
          <p class="text-xs text-base-content/60">
            {gettext("Open tasks with someone on them but no deadline, no planned dates and no start yet.")}
          </p>
          <details
            :for={row <- @rows ++ @board.groups}
            :if={Map.get(@board.unscheduled, row.key, []) != []}
            id={"time-unscheduled-#{row_dom(row.key)}"}
            class="collapse collapse-arrow bg-base-200"
          >
            <summary class="collapse-title text-sm font-medium min-h-0 py-2">
              {row.name}
              <span class="badge badge-sm ml-2">{length(Map.get(@board.unscheduled, row.key))}</span>
            </summary>
            <ul class="collapse-content text-sm flex flex-col gap-1">
              <li :for={a <- Map.get(@board.unscheduled, row.key)}>
                <.smart_link
                  navigate={Paths.view_assignment(a.project_uuid, a.uuid)}
                  emit={{PhoenixKitProjects.Web.AssignmentViewLive, %{"project_id" => a.project_uuid, "id" => a.uuid}}}
                  embed_mode={@embed_mode}
                  class="link link-hover"
                >
                  {TimeBoard.title(a, L10n.current_content_lang())}
                </.smart_link>
                <span class="text-base-content/50">· {project_name(a)}</span>
              </li>
            </ul>
          </details>
        </div>
      </div>
    </div>
    """
  end

  defp legend(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-base-content/70">
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-block w-6 h-2 rounded-sm border border-dashed border-primary/70 bg-primary/10"></span>
        {gettext("Planned")}
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-block w-6 h-2.5 rounded-sm bg-info"></span>
        {gettext("Actually worked")}
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-block w-6 h-2.5 rounded-sm bg-success"></span>
        {gettext("Done")}
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-block w-6 h-2.5 rounded-sm bg-error"></span>
        {gettext("After the deadline")}
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-block w-0.5 h-3 bg-warning"></span>
        {gettext("Deadline")}
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-block w-6 h-1 rounded-sm bg-secondary"></span>
        {gettext("Logged time")}
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-block w-0.5 h-3 bg-error"></span>
        {gettext("Now")}
      </span>
    </div>
    """
  end

  attr(:lanes, :list, required: true)
  attr(:view, :atom, required: true)
  attr(:today, :any, required: true)

  defp axis_header(assigns) do
    ~H"""
    <div class="flex border-b border-base-300 bg-base-200/60 text-xs text-base-content/60 sticky top-0 z-10">
      <div class="w-64 shrink-0 px-3 py-1.5 sticky left-0 bg-base-200 z-20 font-semibold">
        {gettext("Person")}
      </div>
      <div class="flex-1 flex">
        <div
          :for={lane <- @lanes}
          class={["flex-1 relative h-7 border-l border-base-300", lane.date == @today && "bg-primary/5"]}
        >
          <%= if @view == :week do %>
            <div class="absolute inset-0 flex items-center justify-center gap-1 font-medium">
              <span>{weekday(lane.date)}</span>
              <span class="text-base-content/50">{lane.date.day}</span>
            </div>
          <% else %>
            <span
              :for={{h, pct} <- hour_ticks(lane)}
              class="absolute top-1.5 -translate-x-1/2 tabular-nums"
              style={"left: #{pct}%"}
            >
              {h}
            </span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr(:row, :map, required: true)
  attr(:lanes, :list, required: true)
  attr(:view, :atom, required: true)
  attr(:now_local, :any, required: true)
  attr(:expanded, :any, required: true)
  attr(:editable, :map, required: true)
  attr(:deadline_edit, :any, required: true)
  attr(:deadline_error, :any, required: true)
  attr(:embed_mode, :atom, required: true)
  attr(:unscheduled, :list, required: true)

  defp board_row(assigns) do
    row_id = row_dom(assigns.row.key)
    expanded? = MapSet.member?(assigns.expanded, row_id)
    lines = assigns.row.lines
    shown = if expanded?, do: lines, else: Enum.take(lines, @visible_lines)

    assigns =
      assign(assigns,
        row_id: row_id,
        shown: shown,
        hidden_count: length(lines) - length(shown),
        idle?: lines == []
      )

    ~H"""
    <div id={"time-row-#{@row_id}"} class={["border-b border-base-300", @idle? && "opacity-60"]}>
      <div class="flex bg-base-100">
        <div class="w-64 shrink-0 px-3 py-1.5 sticky left-0 bg-base-100 z-10 flex items-center gap-2 min-w-0">
          <%= if @row.person do %>
            <.assignee_faces faces={%{faces: [%{name: @row.name, user: @row.person.user}], extra: 0}} size="xs" />
          <% else %>
            <.icon
              name={if @row.kind == :team, do: "hero-user-group", else: "hero-building-office-2"}
              class="w-5 h-5 text-base-content/60 shrink-0"
            />
          <% end %>
          <span class="font-semibold truncate" title={@row.name}>{@row.name}</span>
          <span :if={not @idle?} class="badge badge-ghost badge-xs shrink-0">{length(@row.lines)}</span>
          <span
            :if={@unscheduled != []}
            class="badge badge-outline badge-xs shrink-0"
            title={gettext("Assigned, no clock")}
          >
            {ngettext("%{count} unscheduled", "%{count} unscheduled", length(@unscheduled))}
          </span>
        </div>
        <div class="flex-1 flex">
          <div :for={lane <- @lanes} class="flex-1 relative min-h-7 border-l border-base-300" style={grid_style(lane)}>
            <span :if={@idle? and lane == hd(@lanes)} class="absolute left-2 top-1.5 text-xs text-base-content/50">
              {if @view == :week, do: gettext("Nothing this week"), else: gettext("Nothing on this day")}
            </span>
            <.now_line lane={lane} now_local={@now_local} />
          </div>
        </div>
      </div>

      <.task_line
        :for={line <- @shown}
        line={line}
        row_id={@row_id}
        lanes={@lanes}
        now_local={@now_local}
        editable={Map.get(@editable, line.assignment.project_uuid, false) and line.role != :worker}
        editing?={@deadline_edit == line_dom(@row_id, line)}
        deadline_error={@deadline_error}
        embed_mode={@embed_mode}
      />

      <div :if={@hidden_count > 0} class="flex">
        <div class="w-64 shrink-0 px-3 py-1 sticky left-0 bg-base-100">
          <button
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="expand_row"
            phx-value-row={@row_id}
          >
            {ngettext("+%{count} more", "+%{count} more", @hidden_count)}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr(:line, :map, required: true)
  attr(:row_id, :string, required: true)
  attr(:lanes, :list, required: true)
  attr(:now_local, :any, required: true)
  attr(:editable, :boolean, required: true)
  attr(:editing?, :boolean, required: true)
  attr(:deadline_error, :any, required: true)
  attr(:embed_mode, :atom, required: true)

  defp task_line(assigns) do
    a = assigns.line.assignment
    assigns = assign(assigns, a: a, dom: line_dom(assigns.row_id, assigns.line))

    ~H"""
    <div
      id={"time-line-#{@dom}"}
      class={["flex text-xs", @line.overdue? && "bg-error/5"]}
      data-status={@line.status}
    >
      <div class={[
        "w-64 shrink-0 pl-9 pr-2 py-1 sticky left-0 z-10 flex flex-col min-w-0",
        if(@line.overdue?, do: "bg-error/5", else: "bg-base-100")
      ]}>
        <div class="flex items-center gap-1 min-w-0">
          <span class={["inline-block w-2 h-2 rounded-full shrink-0", line_dot(@line)]}></span>
          <.smart_link
            navigate={Paths.view_assignment(@a.project_uuid, @a.uuid)}
            emit={{PhoenixKitProjects.Web.AssignmentViewLive, %{"project_id" => @a.project_uuid, "id" => @a.uuid}}}
            embed_mode={@embed_mode}
            class="link link-hover truncate font-medium"
            title={@line.title}
          >
            {@line.title}
          </.smart_link>
          <button
            :if={@editable}
            type="button"
            class="btn btn-ghost btn-xs px-1 ml-auto shrink-0"
            phx-click="edit_deadline"
            phx-value-line={@dom}
            title={gettext("Set deadline")}
            aria-label={gettext("Set deadline")}
          >
            <.icon name="hero-flag" class="w-3.5 h-3.5" />
          </button>
        </div>
        <div class="flex flex-wrap items-center gap-x-1.5 text-base-content/60 min-w-0">
          <span class="truncate">{@line.project_name}</span>
          <span :if={plan_label(@line)}>· {plan_label(@line)}</span>
          <span :if={@line.via} class="truncate">· {gettext("via %{group}", group: @line.via)}</span>
          <span :if={@line.worked_by != []} class="truncate">
            · {gettext("worked by %{names}", names: Enum.join(@line.worked_by, ", "))}
          </span>
          <span :if={@line.overdue?} class="text-error font-medium">· {gettext("overdue")}</span>
          <span :if={logged_minutes(@line) > 0} class="badge badge-secondary badge-xs">
            {gettext("%{hours} h logged", hours: format_hours(logged_minutes(@line)))}
          </span>
        </div>
        <form
          :if={@editing?}
          id={"time-deadline-#{@dom}"}
          phx-submit="save_deadline"
          class="flex flex-wrap items-center gap-1 mt-1"
        >
          <input type="hidden" name="uuid" value={@a.uuid} />
          <input
            type="datetime-local"
            name="deadline"
            value={deadline_value(@line)}
            class="input input-xs"
            aria-label={gettext("Deadline")}
          />
          <button type="submit" class="btn btn-primary btn-xs">{gettext("Save")}</button>
          <button type="button" class="btn btn-ghost btn-xs" phx-click="cancel_deadline">
            {gettext("Cancel")}
          </button>
          <span :if={@deadline_error} class="text-error w-full">{@deadline_error}</span>
        </form>
      </div>
      <div class="flex-1 flex">
        <div :for={lane <- @lanes} class="flex-1 relative h-8 border-l border-base-300" style={grid_style(lane)}>
          <.smart_link
            navigate={Paths.view_assignment(@a.project_uuid, @a.uuid)}
            emit={{PhoenixKitProjects.Web.AssignmentViewLive, %{"project_id" => @a.project_uuid, "id" => @a.uuid}}}
            embed_mode={@embed_mode}
            class="absolute inset-0 block"
            aria-label={@line.title}
          >
            <span
              :for={bar <- bars(@line, lane)}
              class={["absolute", bar.class]}
              style={bar.style}
              title={bar.title}
            >
            </span>
          </.smart_link>
          <.now_line lane={lane} now_local={@now_local} />
        </div>
      </div>
    </div>
    """
  end

  attr(:lane, :map, required: true)
  attr(:now_local, :any, required: true)

  defp now_line(assigns) do
    assigns = assign(assigns, pct: point(assigns.lane, assigns.now_local))

    ~H"""
    <span
      :if={@pct}
      class="time-now absolute top-0 bottom-0 w-px bg-error pointer-events-none z-[1]"
      style={"left: #{@pct}%"}
    >
    </span>
    """
  end

  # ── Geometry ────────────────────────────────────────────────────

  defp lane_bounds(%{date: date, start: s, end: e}) do
    day = NaiveDateTime.new!(date, ~T[00:00:00])
    {NaiveDateTime.add(day, s * 60), NaiveDateTime.add(day, e * 60)}
  end

  @doc false
  # `{left%, width%}` of a segment inside a lane, or nil when it misses it.
  def place(lane, {f, t}) do
    {ls, le} = lane_bounds(lane)
    span = NaiveDateTime.diff(le, ls)
    cf = max_n(f, ls)
    ct = min_n(t, le)

    if NaiveDateTime.compare(ct, cf) == :gt and span > 0 do
      left = NaiveDateTime.diff(cf, ls) / span * 100
      width = NaiveDateTime.diff(ct, cf) / span * 100

      %{
        left: Float.round(left, 3),
        width: Float.round(max(width, 0.6), 3),
        cut_l?: NaiveDateTime.compare(f, ls) == :lt,
        cut_r?: NaiveDateTime.compare(t, le) == :gt
      }
    end
  end

  @doc false
  def point(lane, t) do
    {ls, le} = lane_bounds(lane)
    span = NaiveDateTime.diff(le, ls)

    if span > 0 and NaiveDateTime.compare(t, ls) != :lt and NaiveDateTime.compare(t, le) != :gt,
      do: Float.round(NaiveDateTime.diff(t, ls) / span * 100, 3)
  end

  defp pos_style(%{left: l, width: w}), do: "left: #{l}%; width: #{w}%"

  # Hour grid lines drawn as a repeating background — no per-hour elements.
  defp grid_style(%{start: s, end: e}) do
    hours = max(div(e - s, 60), 1)

    "background-image: linear-gradient(to right, color-mix(in oklab, var(--color-base-content) 8%, transparent) 1px, transparent 1px); background-size: calc(100% / #{hours}) 100%"
  end

  # The whole hours labelled on a day's axis (every other one past 12 h).
  defp hour_ticks(%{start: s, end: e}) do
    span = e - s
    step = if span > 12 * 60, do: 120, else: 60
    first = (div(s, 60) + 1) * 60

    if first < e do
      for m <- first..(e - 1)//step do
        {:io_lib.format("~2..0B", [div(m, 60)]) |> IO.iodata_to_binary(),
         Float.round((m - s) / span * 100, 3)}
      end
    else
      []
    end
  end

  @doc false
  # Every mark of a line inside one lane, ready to draw: the planned ghost(s),
  # logged clock spans, the actual bar (+ its live edge), the late part, the
  # finish dot and the deadline pin — bottom to top in paint order.
  def bars(line, lane) do
    plan =
      for seg <- line.planned, pos = place(lane, seg) do
        %{
          class:
            "time-plan top-1 h-2.5 rounded-sm border border-dashed border-primary/70 bg-primary/10",
          style: pos_style(pos),
          title: span_title(plan_title(line), seg)
        }
      end

    logged =
      for %{span: {_, _} = span} <- line.logged, pos = place(lane, span) do
        %{
          class: "time-logged top-[15px] h-1 rounded-sm bg-secondary",
          style: pos_style(pos),
          title: span_title(gettext("Logged"), span)
        }
      end

    actual =
      with {_, _} = seg <- line.actual, %{} = pos <- place(lane, seg) do
        bar = %{
          class: "time-actual bottom-1 h-2.5 rounded-sm " <> actual_class(line),
          style: pos_style(pos),
          title: span_title(actual_title(line), seg)
        }

        edge =
          if line.live? and not pos.cut_r?,
            do: [
              %{
                class: "time-live bottom-1 h-2.5 w-1 rounded-sm bg-info animate-pulse",
                style: "left: calc(#{pos.left + pos.width}% - 2px)",
                title: span_title(actual_title(line), seg)
              }
            ],
            else: []

        [bar | edge]
      else
        _ -> []
      end

    late =
      with {_, _} = seg <- line.late, %{} = pos <- place(lane, seg) do
        [
          %{
            class: "time-late bottom-1 h-2.5 rounded-sm bg-error",
            style: pos_style(pos),
            title: span_title(gettext("After the deadline"), seg)
          }
        ]
      else
        _ -> []
      end

    done =
      with %NaiveDateTime{} = t <- line.done_at, pct when is_number(pct) <- point(lane, t) do
        [
          %{
            class: "time-done bottom-1 h-2.5 w-2.5 -translate-x-1/2 rounded-full bg-success",
            style: "left: #{pct}%",
            title: gettext("Done at %{time}", time: hhmm(t))
          }
        ]
      else
        _ -> []
      end

    pin =
      with %NaiveDateTime{} = t <- line.deadline, pct when is_number(pct) <- point(lane, t) do
        [
          %{
            class:
              "time-pin top-0 bottom-0 w-0.5 -translate-x-1/2 " <>
                if(line.overdue?, do: "bg-error", else: "bg-warning"),
            style: "left: #{pct}%",
            title: gettext("Deadline %{time}", time: hhmm(t))
          }
        ]
      else
        _ -> []
      end

    plan ++ logged ++ actual ++ late ++ done ++ pin
  end

  # ── Labels ──────────────────────────────────────────────────────

  defp plan_label(%{plan_source: :explicit}), do: gettext("planned")

  defp plan_label(%{plan_source: :deadline, estimate_hours: h}),
    do: gettext("from deadline · %{hours} h", hours: format_hours(h * 60))

  defp plan_label(%{deadline: %NaiveDateTime{}, role: r}) when r != :worker,
    do: gettext("deadline only")

  defp plan_label(_), do: nil

  defp plan_title(line), do: gettext("Planned") <> " (" <> (plan_label(line) || "") <> ")"

  defp actual_title(%{live?: true}), do: gettext("In progress since")
  defp actual_title(_), do: gettext("Worked")

  defp span_title(label, {f, t}), do: "#{label}: #{hhmm(f)}–#{hhmm(t)}"

  defp actual_class(%{status: "done"}), do: "bg-success"
  defp actual_class(%{live?: true}), do: "bg-info"
  defp actual_class(_), do: "bg-neutral/50"

  defp line_dot(%{overdue?: true}), do: "bg-error"
  defp line_dot(%{status: "done"}), do: "bg-success"
  defp line_dot(%{status: "in_progress"}), do: "bg-info"
  defp line_dot(%{status: "waiting"}), do: "bg-base-300"
  defp line_dot(_), do: "bg-base-content/40"

  defp logged_minutes(line), do: line.logged |> Enum.map(& &1.minutes) |> Enum.sum()

  defp format_hours(minutes) do
    h = minutes / 60

    if h == Float.round(h * 1.0, 0),
      do: Integer.to_string(trunc(h)),
      else: :erlang.float_to_binary(h * 1.0, decimals: 1)
  end

  defp hhmm(%NaiveDateTime{hour: h, minute: m}),
    do: :io_lib.format("~2..0B:~2..0B", [h, m]) |> IO.iodata_to_binary()

  defp deadline_value(%{deadline: %NaiveDateTime{} = d}),
    do: d |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)

  defp deadline_value(_), do: nil

  defp project_name(%Assignment{project: %{} = p}),
    do: Project.localized_name(p, L10n.current_content_lang())

  defp project_name(_), do: nil

  defp row_dom({kind, uuid}), do: "#{kind}-#{uuid}"
  defp line_dom(row_id, line), do: "#{row_id}-#{line.id}"

  defp range_label(:day, date, _to), do: "#{weekday(date)}, #{L10n.format_date(date)}"

  defp range_label(:week, from, to),
    do: "#{L10n.format_date(from)} – #{L10n.format_date(to)}"

  defp weekday(date) do
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
end
