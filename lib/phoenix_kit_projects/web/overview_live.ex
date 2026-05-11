defmodule PhoenixKitProjects.Web.OverviewLive do
  @moduledoc "Projects module dashboard."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{L10n, Paths, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.{Project, Task}

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: ProjectsPubSub.subscribe(ProjectsPubSub.topic_all())

    user_uuid =
      case socket.assigns[:phoenix_kit_current_user] do
        %{uuid: uuid} -> uuid
        _ -> nil
      end

    {:ok, assign(socket, user_uuid: user_uuid) |> reload()}
  end

  # How many "Running" projects to show on the dashboard. The count
  # badge on "View all →" reveals when the total exceeds this cap.
  @running_display_limit 10
  # Fallback "late" threshold (days since `started_at`) when a project
  # has no estimated durations — without sum-of-durations we can't
  # compute a real planned_end. Projects with durations use planned_end
  # directly (started_at + total estimated hours), per the same logic
  # the project show page uses.
  @late_fallback_days 14
  # Progress percentage (>=) for the "near done" tier on the dashboard.
  @near_done_threshold_pct 75

  defp reload(socket) do
    user_uuid = socket.assigns[:user_uuid]
    active_projects = Projects.list_active_projects()
    completed_projects = Projects.list_recently_completed_projects()
    upcoming_projects = Projects.list_upcoming_projects()
    setup_projects = Projects.list_setup_projects()

    any_projects? =
      active_projects != [] or completed_projects != [] or upcoming_projects != [] or
        setup_projects != []

    {top_summaries, total_active} =
      active_projects
      |> Projects.project_summaries()
      |> prioritize_running()

    assign(socket,
      page_title: gettext("Projects"),
      task_count: Projects.count_tasks(),
      project_count: Projects.count_projects(),
      template_count: Projects.count_templates(),
      active_count: total_active,
      active_summaries: top_summaries,
      running_display_limit: @running_display_limit,
      completed_projects: completed_projects,
      upcoming_projects: upcoming_projects,
      setup_projects: setup_projects,
      any_projects?: any_projects?,
      my_assignments: if(user_uuid, do: Projects.list_assignments_for_user(user_uuid), else: []),
      status_counts: Projects.assignment_status_counts()
    )
  end

  # Sorts running-project summaries into four importance tiers and
  # caps to @running_display_limit. Returns {capped_list, total_count}.
  #
  # Tier 0 ("late"):    started ≥ @late_threshold_days ago AND progress < 100.
  #                     Within tier, oldest-started first (most stalled).
  # Tier 1 ("near done"): progress ≥ @near_done_threshold_pct, not Tier 0.
  #                     Within tier, highest progress first.
  # Tier 2 ("rest"):    has tasks, not late, not near-done. Most-recently-started first.
  # Tier 3 ("empty"):   total == 0 tasks. Sinks to the bottom regardless of age —
  #                     these projects can't show meaningful progress and would
  #                     otherwise outrank real work via the recency sort.
  defp prioritize_running(summaries) do
    today = Date.utc_today()

    sorted =
      summaries
      |> Enum.map(&{running_sort_key(&1, today), &1})
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map(fn {_, s} -> s end)

    {Enum.take(sorted, @running_display_limit), length(summaries)}
  end

  # Template-facing tier label for a summary row. Late = past
  # `planned_end` (sum of estimated durations from started_at) with
  # progress < 100. When a project has no durations we fall back to
  # the 14-day age heuristic since there's no real budget to compare
  # against.
  defp running_tier(summary) do
    %{project: project, progress_pct: pct, total: total, planned_end: planned_end} = summary
    now = DateTime.utc_now()

    cond do
      total == 0 ->
        :empty

      late?(planned_end, project, now, pct) ->
        :late

      pct >= @near_done_threshold_pct ->
        :near_done

      true ->
        :on_track
    end
  end

  defp late?(_planned_end, _project, _now, pct) when pct >= 100, do: false

  defp late?(%DateTime{} = planned_end, _project, now, _pct),
    do: DateTime.compare(now, planned_end) == :gt

  defp late?(nil, %{started_at: %DateTime{} = started_at}, now, _pct),
    do: DateTime.diff(now, started_at, :second) / 86_400 >= @late_fallback_days

  defp late?(_, _, _, _), do: false

  defp running_sort_key(summary, today) do
    %{project: project, progress_pct: pct, total: total} = summary
    tier = running_tier(summary)

    days_running =
      case project.started_at do
        %DateTime{} = dt -> Date.diff(today, DateTime.to_date(dt))
        _ -> 0
      end

    case tier do
      :late ->
        # Tier 0: most overdue first. Use seconds-past-planned_end when
        # available, else fall back to age. Negated for ascending sort.
        overdue_seconds = overdue_seconds(summary)
        {0, -overdue_seconds, project.uuid}

      :near_done ->
        # Tier 1: highest progress first.
        {1, -pct, project.uuid}

      :on_track ->
        # Tier 2: most-recently-started first.
        {2, days_running, project.uuid}

      :empty ->
        # Tier 3: empty projects sink to the bottom.
        _ = total
        {3, days_running, project.uuid}
    end
  end

  defp overdue_seconds(%{planned_end: %DateTime{} = planned_end}) do
    DateTime.diff(DateTime.utc_now(), planned_end, :second)
  end

  defp overdue_seconds(%{project: %{started_at: %DateTime{} = started_at}}) do
    DateTime.diff(DateTime.utc_now(), started_at, :second)
  end

  defp overdue_seconds(_), do: 0

  @impl true
  def handle_info({:projects, _event, _payload}, socket) do
    {:noreply, reload(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[OverviewLive] unexpected handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp status_badge_class("todo"), do: "badge-ghost"
  defp status_badge_class("in_progress"), do: "badge-warning"
  defp status_badge_class("done"), do: "badge-success"
  defp status_badge_class(_), do: "badge-ghost"

  defp status_label("todo"), do: gettext("todo")
  defp status_label("in_progress"), do: gettext("in progress")
  defp status_label("done"), do: gettext("done")
  defp status_label(other), do: other

  # Accepts either a `Date` or a `DateTime` — `scheduled_start_date`
  # was retyped to `:utc_datetime` in V112; this helper preserves the
  # daily-cadence comparison by collapsing datetimes to their date
  # portion.
  defp days_until(%DateTime{} = dt), do: days_until(DateTime.to_date(dt))
  defp days_until(%Date{} = date), do: Date.diff(date, Date.utc_today())

  defp relative_day(days) do
    cond do
      days == 0 -> gettext("today")
      days == 1 -> gettext("tomorrow")
      days == -1 -> gettext("yesterday")
      days > 1 and days < 14 -> ngettext("in %{count} day", "in %{count} days", days)
      days > 1 -> gettext("in %{n} weeks", n: Float.round(days / 7, 1))
      days < 0 and days > -14 -> ngettext("%{count} day ago", "%{count} days ago", abs(days))
      true -> gettext("%{n} weeks ago", n: Float.round(abs(days) / 7, 1))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-6xl px-4 py-6 gap-6">
      <.page_header
        title={gettext("Projects")}
        description={gettext("Overview of active work, upcoming projects, and your assignments.")}
      >
        <:actions>
          <.link navigate={Paths.new_project()} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New project")}
          </.link>
          <.link navigate={Paths.new_task()} class="btn btn-ghost btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New task")}
          </.link>
        </:actions>
      </.page_header>

      <%!-- Stats row --%>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <.stat_tile label={gettext("Running")} value={@active_count} />
        <.stat_tile
          label={gettext("Tasks in progress")}
          value={Map.get(@status_counts, "in_progress", 0)}
          value_class="text-warning"
        />
        <.stat_tile label={gettext("Tasks todo")} value={Map.get(@status_counts, "todo", 0)} />
        <.stat_tile
          label={gettext("Tasks done")}
          value={Map.get(@status_counts, "done", 0)}
          value_class="text-success"
        />
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <%!-- Left: Active projects (span 2) --%>
        <div class="lg:col-span-2 card bg-base-100 shadow">
          <div class="card-body">
            <div class="flex items-start justify-between gap-3">
              <div>
                <h2 class="card-title text-lg">
                  <.icon name="hero-play" class="w-5 h-5 text-success" /> {gettext("Running")}
                </h2>
                <p class="text-xs text-base-content/50 mt-0.5">
                  {gettext("Started and not yet completed.")}
                </p>
              </div>
              <.link navigate={Paths.projects()} class="link link-hover text-sm shrink-0 mt-1">
                <%= if @active_count > @running_display_limit do %>
                  {gettext("View all (%{count}) →", count: @active_count)}
                <% else %>
                  {gettext("View all →")}
                <% end %>
              </.link>
            </div>

            <%= if @active_summaries == [] do %>
              <%= if @any_projects? do %>
                <.empty_state
                  icon="hero-clipboard-document-list"
                  title={gettext("Nothing running right now.")}
                  description={gettext("Open a project and click Start to begin.")}
                  class="py-10"
                >
                  <:cta>
                    <.link navigate={Paths.projects()} class="btn btn-ghost btn-xs">
                      <.icon name="hero-clipboard-document-list" class="w-3.5 h-3.5" /> {gettext("View projects")}
                    </.link>
                  </:cta>
                </.empty_state>
              <% else %>
                <.empty_state
                  icon="hero-clipboard-document-list"
                  title={gettext("No projects yet.")}
                  description={gettext("Create one to get started.")}
                  class="py-10"
                >
                  <:cta>
                    <.link navigate={Paths.new_project()} class="btn btn-primary btn-xs">
                      <.icon name="hero-plus" class="w-3.5 h-3.5" /> {gettext("New project")}
                    </.link>
                  </:cta>
                </.empty_state>
              <% end %>
            <% else %>
              <div class="flex flex-col gap-2 mt-2">
                <.running_card
                  :for={s <- @active_summaries}
                  summary={s}
                  tier={running_tier(s)}
                  navigate={Paths.project(s.project.uuid)}
                  lang={L10n.current_content_lang()}
                />
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Right: My tasks + upcoming + recently completed --%>
        <div class="flex flex-col gap-4">
          <%!-- My assignments --%>
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-lg">
                <.icon name="hero-user" class="w-5 h-5" /> {gettext("My tasks")}
              </h2>

              <%= if @my_assignments == [] do %>
                <p class="text-sm text-base-content/50 py-2">
                  {gettext("Nothing assigned to you right now.")}
                </p>
              <% else %>
                <div class="flex flex-col gap-2 mt-2">
                  <.link
                    :for={a <- Enum.take(@my_assignments, 6)}
                    navigate={Paths.project(a.project.uuid)}
                    class="flex items-start gap-2 p-2 rounded hover:bg-base-200 transition"
                  >
                    <span class={"badge badge-xs mt-1 #{status_badge_class(a.status)}"}>{status_label(a.status)}</span>
                    <div class="flex-1 min-w-0">
                      <div class="text-sm font-medium truncate">{Task.localized_title(a.task, L10n.current_content_lang())}</div>
                      <div class="text-xs text-base-content/60 truncate">{Project.localized_name(a.project, L10n.current_content_lang())}</div>
                    </div>
                  </.link>

                  <%= if length(@my_assignments) > 6 do %>
                    <div class="text-xs text-base-content/50 text-center pt-1">
                      {gettext("+%{count} more", count: length(@my_assignments) - 6)}
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Recently completed --%>
          <%= if @completed_projects != [] do %>
            <div class="card bg-base-100 shadow">
              <div class="card-body">
                <h2 class="card-title text-lg">
                  <.icon name="hero-trophy" class="w-5 h-5 text-success" /> {gettext("Recently completed")}
                </h2>
                <div class="flex flex-col gap-1 mt-2">
                  <.link
                    :for={p <- @completed_projects}
                    navigate={Paths.project(p.uuid)}
                    class="flex items-center gap-2 p-2 rounded hover:bg-base-200 transition"
                  >
                    <.icon name="hero-check-circle" class="w-4 h-4 text-success shrink-0" />
                    <div class="flex-1 min-w-0">
                      <div class="text-sm font-medium truncate">{Project.localized_name(p, L10n.current_content_lang())}</div>
                      <div class="text-xs text-base-content/60">
                        {relative_day(Date.diff(DateTime.to_date(p.completed_at), Date.utc_today()))}
                      </div>
                    </div>
                  </.link>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Upcoming & Setup --%>
          <%= if @upcoming_projects != [] or @setup_projects != [] do %>
            <div class="card bg-base-100 shadow">
              <div class="card-body">
                <h2 class="card-title text-lg">
                  <.icon name="hero-calendar" class="w-5 h-5 text-info" /> {gettext("Upcoming")}
                </h2>

                <%= if @setup_projects != [] do %>
                  <div class="text-xs text-base-content/50 uppercase tracking-wide mt-2">{gettext("In setup")}</div>
                  <.link
                    :for={p <- @setup_projects}
                    navigate={Paths.project(p.uuid)}
                    class="flex items-center gap-2 p-2 rounded hover:bg-base-200 transition"
                  >
                    <.icon name="hero-clock" class="w-4 h-4 text-warning shrink-0" />
                    <span class="text-sm font-medium truncate flex-1">{Project.localized_name(p, L10n.current_content_lang())}</span>
                  </.link>
                <% end %>

                <%= if @upcoming_projects != [] do %>
                  <div class="text-xs text-base-content/50 uppercase tracking-wide mt-2">{gettext("Scheduled")}</div>
                  <.link
                    :for={p <- @upcoming_projects}
                    navigate={Paths.project(p.uuid)}
                    class="flex items-center gap-2 p-2 rounded hover:bg-base-200 transition"
                  >
                    <.icon name="hero-calendar" class="w-4 h-4 text-info shrink-0" />
                    <div class="flex-1 min-w-0">
                      <div class="text-sm font-medium truncate">{Project.localized_name(p, L10n.current_content_lang())}</div>
                      <div class="text-xs text-base-content/60">
                        {L10n.format_datetime(p.scheduled_start_date)}
                        · {relative_day(days_until(p.scheduled_start_date))}
                      </div>
                    </div>
                  </.link>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Bottom navigation row --%>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <.link navigate={Paths.projects()} class="card bg-base-100 shadow-sm hover:shadow-md transition border border-base-200">
          <div class="card-body p-4">
            <div class="flex items-center gap-2 text-base-content/70">
              <.icon name="hero-clipboard-document-list" class="w-5 h-5" />
              <span class="text-sm font-medium">{gettext("Projects")}</span>
            </div>
            <div class="text-xl font-bold">{@project_count}</div>
          </div>
        </.link>
        <.link navigate={Paths.tasks()} class="card bg-base-100 shadow-sm hover:shadow-md transition border border-base-200">
          <div class="card-body p-4">
            <div class="flex items-center gap-2 text-base-content/70">
              <.icon name="hero-rectangle-stack" class="w-5 h-5" />
              <span class="text-sm font-medium">{gettext("Task Library")}</span>
            </div>
            <div class="text-xl font-bold">{@task_count}</div>
          </div>
        </.link>
        <.link navigate={Paths.templates()} class="card bg-base-100 shadow-sm hover:shadow-md transition border border-base-200">
          <div class="card-body p-4">
            <div class="flex items-center gap-2 text-base-content/70">
              <.icon name="hero-document-duplicate" class="w-5 h-5" />
              <span class="text-sm font-medium">{gettext("Templates")}</span>
            </div>
            <div class="text-xl font-bold">{@template_count}</div>
          </div>
        </.link>
        <.link navigate={Paths.new_template()} class="card bg-base-100 shadow-sm hover:shadow-md transition border border-base-200">
          <div class="card-body p-4">
            <div class="flex items-center gap-2 text-base-content/70">
              <.icon name="hero-plus" class="w-5 h-5" />
              <span class="text-sm font-medium">{gettext("New template")}</span>
            </div>
            <div class="text-xs text-base-content/50">{gettext("Blueprint from scratch")}</div>
          </div>
        </.link>
      </div>
    </div>
    """
  end
end
