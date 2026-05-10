defmodule PhoenixKitProjects.Web.OverviewLive do
  @moduledoc "Projects module dashboard."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

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

  defp reload(socket) do
    user_uuid = socket.assigns[:user_uuid]
    active_projects = Projects.list_active_projects()
    completed_projects = Projects.list_recently_completed_projects()
    upcoming_projects = Projects.list_upcoming_projects()
    setup_projects = Projects.list_setup_projects()

    any_projects? =
      active_projects != [] or completed_projects != [] or upcoming_projects != [] or
        setup_projects != []

    assign(socket,
      page_title: gettext("Projects"),
      task_count: Projects.count_tasks(),
      project_count: Projects.count_projects(),
      template_count: Projects.count_templates(),
      active_count: length(active_projects),
      active_summaries: Projects.project_summaries(active_projects),
      completed_projects: completed_projects,
      upcoming_projects: upcoming_projects,
      setup_projects: setup_projects,
      any_projects?: any_projects?,
      my_assignments: if(user_uuid, do: Projects.list_assignments_for_user(user_uuid), else: []),
      status_counts: Projects.assignment_status_counts()
    )
  end

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
      <div class="flex items-start justify-between gap-4">
        <div>
          <h1 class="text-2xl font-bold">{gettext("Projects")}</h1>
          <p class="text-base-content/60 text-sm mt-1">
            {gettext("Overview of active work, upcoming projects, and your assignments.")}
          </p>
        </div>
        <div class="flex flex-wrap gap-2">
          <.link navigate={Paths.new_project()} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New project")}
          </.link>
          <.link navigate={Paths.new_task()} class="btn btn-ghost btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New task")}
          </.link>
        </div>
      </div>

      <%!-- Stats row --%>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <div class="card bg-base-100 shadow-sm border border-base-200">
          <div class="card-body p-3">
            <div class="text-xs text-base-content/60">{gettext("Running")}</div>
            <div class="text-2xl font-bold">{@active_count}</div>
          </div>
        </div>
        <div class="card bg-base-100 shadow-sm border border-base-200">
          <div class="card-body p-3">
            <div class="text-xs text-base-content/60">{gettext("Tasks in progress")}</div>
            <div class="text-2xl font-bold text-warning">{Map.get(@status_counts, "in_progress", 0)}</div>
          </div>
        </div>
        <div class="card bg-base-100 shadow-sm border border-base-200">
          <div class="card-body p-3">
            <div class="text-xs text-base-content/60">{gettext("Tasks todo")}</div>
            <div class="text-2xl font-bold">{Map.get(@status_counts, "todo", 0)}</div>
          </div>
        </div>
        <div class="card bg-base-100 shadow-sm border border-base-200">
          <div class="card-body p-3">
            <div class="text-xs text-base-content/60">{gettext("Tasks done")}</div>
            <div class="text-2xl font-bold text-success">{Map.get(@status_counts, "done", 0)}</div>
          </div>
        </div>
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
              <.link navigate={Paths.projects()} class="link link-hover text-sm shrink-0 mt-1">{gettext("View all →")}</.link>
            </div>

            <%= if @active_summaries == [] do %>
              <div class="text-center py-10 text-base-content/60">
                <.icon name="hero-clipboard-document-list" class="w-10 h-10 mx-auto mb-2 opacity-40" />
                <%= if @any_projects? do %>
                  <p class="text-sm">{gettext("Nothing running right now.")}</p>
                  <p class="text-xs text-base-content/50 mt-1">
                    {gettext("Open a project and click Start to begin.")}
                  </p>
                  <.link navigate={Paths.projects()} class="btn btn-ghost btn-xs mt-3">
                    <.icon name="hero-clipboard-document-list" class="w-3.5 h-3.5" /> {gettext("View projects")}
                  </.link>
                <% else %>
                  <p class="text-sm">{gettext("No projects yet.")}</p>
                  <p class="text-xs text-base-content/50 mt-1">
                    {gettext("Create one to get started.")}
                  </p>
                  <.link navigate={Paths.new_project()} class="btn btn-primary btn-xs mt-3">
                    <.icon name="hero-plus" class="w-3.5 h-3.5" /> {gettext("New project")}
                  </.link>
                <% end %>
              </div>
            <% else %>
              <div class="flex flex-col gap-2 mt-2">
                <.link
                  :for={s <- @active_summaries}
                  navigate={Paths.project(s.project.uuid)}
                  class="flex items-center gap-3 p-3 rounded hover:bg-base-200 transition"
                >
                  <div class="flex-1 min-w-0">
                    <div class="font-medium truncate">{Project.localized_name(s.project, L10n.current_content_lang())}</div>
                    <div class="flex items-center gap-2 text-xs text-base-content/60 mt-1">
                      <span>{gettext("Started %{when}", when: relative_day(Date.diff(DateTime.to_date(s.project.started_at), Date.utc_today())))}</span>
                      <span>·</span>
                      <span>{gettext("%{done}/%{total} tasks", done: s.done, total: s.total)}</span>
                      <%= if s.in_progress > 0 do %>
                        <span>·</span>
                        <span class="text-warning">{gettext("%{count} in progress", count: s.in_progress)}</span>
                      <% end %>
                    </div>
                    <div class="w-full bg-base-300 rounded-full h-1.5 mt-2">
                      <div
                        class="bg-success h-1.5 rounded-full transition-all"
                        style={"width: #{s.progress_pct}%"}
                      >
                      </div>
                    </div>
                  </div>
                  <div class="text-right shrink-0">
                    <div class="text-lg font-bold">{s.progress_pct}%</div>
                  </div>
                </.link>
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
