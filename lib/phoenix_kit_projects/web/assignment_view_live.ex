defmodule PhoenixKitProjects.Web.AssignmentViewLive do
  @moduledoc """
  A task's view: what it is, where it stands, what it waits on and what
  it unlocks, its subtasks, and its conversation — for reading and the
  common next step. `AssignmentFormLive` stays the full edit form; "Edit"
  here swaps the drawer's frame to it, and its "Back to task" swaps back
  (`PopupHostLive`'s `:swap`). Anyone who may see the project may open a
  task's view; editing, the next step and commenting each follow their
  own permission.

  The next step ("Ready to start", "Start", "Done", "Reopen") belongs to
  the project page under the drawer — its dialogs ask who to notify and
  what to hand on — so the view asks the page for it
  (`WebHelpers.emit_intent/3`) and the page runs it as its own event.

  Mount only, no `handle_params/3`: it is embedded as a drawer frame.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components
  use PhoenixKit.Mentions.Live
  use PhoenixKitComments.Embed

  require Logger

  alias PhoenixKitProjects.{
    Assignees,
    Authz,
    Extensions,
    Features,
    L10n,
    Labels,
    Paths,
    Projects,
    Refs
  }

  alias PhoenixKitProjects.Hours.Format
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.{Assignment, Project, Task}
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  import PhoenixKitProjects.Web.Helpers, only: [assignee_label: 1]
  import PhoenixKitProjects.Web.Components.TaskTimes, only: [deadline_chip: 1, planned_label: 1]

  @default_wrapper_class "@container flex flex-col w-full mx-auto max-w-5xl px-4 py-6 gap-5"

  # The steps the project page runs for the view (`ProjectShowLive`'s
  # `:intent` handler accepts exactly these).
  @steps ~w(ask_ready start_task complete ask_reopen)

  @impl true
  def mount(params, session, socket) do
    WebHelpers.maybe_put_locale(session)
    resolved = WebHelpers.resolve_action_params(params, session)

    socket =
      socket
      |> assign(
        wrapper_class: Map.get(session, "wrapper_class", @default_wrapper_class),
        embed_redirect_to: Map.get(session, "redirect_to"),
        back_to: Map.get(session, "back_to"),
        activity_tab: nil,
        desc_open?: false
      )
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)
      |> load(resolved["project_id"], resolved["id"])

    {:ok, socket}
  end

  # ── Loading ─────────────────────────────────────────────────────────

  defp load(socket, project_id, id) when is_binary(project_id) and is_binary(id) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    project = Projects.get_project_with_assignee(project_id)
    assignment = Projects.get_assignment(id)

    # The task is re-scoped to the project named — never a foreign task
    # under this project's permission — and refusals look like not-found.
    ok? =
      match?(%Project{}, project) and match?(%Assignment{}, assignment) and
        assignment.project_uuid == project.uuid and
        WebHelpers.template_or_viewable?(project, scope) and
        Extensions.enabled?(project, "tasks")

    if ok? do
      if connected?(socket) and is_nil(socket.assigns[:subscribed]) do
        ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(project.uuid))
      end

      socket
      |> assign(subscribed: true, project: project, assignment: assignment, not_found?: false)
      |> assign_view(scope)
      |> assign(page_title: Assignment.label(assignment, L10n.current_content_lang()))
    else
      not_found(socket)
    end
  end

  defp load(socket, _project_id, _id), do: not_found(socket)

  defp not_found(socket) do
    socket
    |> assign(not_found?: true, project: nil, assignment: nil, page_title: gettext("Task"))
    |> put_flash(:error, gettext("Task not found."))
    |> WebHelpers.close_or_navigate(Paths.projects())
  end

  defp reload(
         %{assigns: %{project: %Project{uuid: p}, assignment: %Assignment{uuid: a}}} = socket
       ),
       do: load(socket, p, a)

  defp reload(socket), do: socket

  defp assign_view(socket, scope) do
    %{project: project, assignment: a} = socket.assigns
    fx = Features.gates(project)
    rows = Projects.list_assignments(project.uuid)
    by_uuid = Map.new(rows, &{&1.uuid, &1})
    {waits_on, unlocks} = connections(fx, project, a, by_uuid)
    threads = threads(project, a)

    assign(socket,
      fx: fx,
      ref: Refs.task_ref(project.key, a.number),
      parent: a.parent_uuid && by_uuid[a.parent_uuid],
      back_task: socket.assigns[:back_to] && by_uuid[socket.assigns.back_to],
      waits_on: waits_on,
      unlocks: unlocks,
      subtasks: rows |> Enum.filter(&(&1.parent_uuid == a.uuid)) |> Enum.sort_by(& &1.position),
      labels: labels(fx, a),
      faces: if(fx.assignees, do: Assignees.faces([a])[a.uuid]),
      logged: if(fx.ledger, do: logged(project, a)),
      threads: threads,
      history: history(project, a),
      activity_tab: socket.assigns[:activity_tab] || if(threads, do: "comments", else: "history"),
      can_edit?: Authz.can?(scope, project, :edit_tasks) and not project.is_template,
      can_step?: may_step?(fx, project, scope, a)
    )
  end

  # What it waits on (open ones first) and what it unlocks, as the task
  # rows of this project.
  defp connections(%{dependencies: true}, project, a, by_uuid) do
    deps = Projects.list_all_dependencies([project.uuid])
    waits_on = for d <- deps, d.assignment_uuid == a.uuid, r = by_uuid[d.depends_on_uuid], do: r
    unlocks = for d <- deps, d.depends_on_uuid == a.uuid, r = by_uuid[d.assignment_uuid], do: r
    {Enum.sort_by(waits_on, &open_first/1), Enum.sort_by(unlocks, & &1.position)}
  end

  defp connections(_fx, _project, _a, _by_uuid), do: {[], []}

  defp labels(%{labels: true}, a),
    do: Map.get(Labels.labels_for_assignments([a.uuid]), a.uuid, [])

  defp labels(_fx, _a), do: []

  defp may_step?(fx, project, scope, a),
    do: fx.tasks and not project.is_template and Authz.can?(scope, project, :update_status, a)

  # Open prerequisites first: they are what holds the task up.
  defp open_first(%Assignment{status: "done", position: p}), do: {1, p}
  defp open_first(%Assignment{position: p}), do: {0, p}

  defp logged(project, a) do
    totals =
      PhoenixKitProjects.Hours.summary(
        PhoenixKitProjects.Hours.filters(project_uuids: [project.uuid], assignment_uuid: a.uuid)
      ).totals

    if (totals.minutes || 0) + (totals.ai_minutes || 0) > 0, do: totals
  rescue
    _ -> nil
  end

  # The task's discussion and the agent's notes: the comments module and
  # the project's Discussions both on, as in the form.
  defp threads(%Project{is_template: false} = project, a) do
    if Code.ensure_loaded?(PhoenixKitComments) and PhoenixKitComments.enabled?() and
         Extensions.enabled?(project, "discussions") do
      %{
        comments: PhoenixKitComments.count_comments("assignment", a.uuid, status: "published"),
        notes:
          PhoenixKitComments.count_comments(PhoenixKitProjects.TaskNotes.resource_type(), a.uuid,
            status: "published"
          )
      }
    end
  rescue
    _ -> nil
  end

  defp threads(_project, _a), do: nil

  defp history(%Project{is_template: false} = project, a) do
    PhoenixKitProjects.History.list(project, task: a.uuid).entries
  rescue
    e ->
      Logger.warning("[Projects] task view history failed: #{inspect(e.__struct__)}")
      []
  end

  defp history(_project, _a), do: []

  # ── Events ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("close", _params, socket) do
    {:noreply, WebHelpers.close_or_navigate(socket, project_path(socket))}
  end

  # The full form: in the same drawer (and back here after), or its page.
  def handle_event("edit", _params, %{assigns: %{can_edit?: true}} = socket) do
    %{project: project, assignment: a} = socket.assigns

    if socket.assigns.embed_mode == :emit do
      WebHelpers.emit_swap(socket, PhoenixKitProjects.Web.AssignmentFormLive, %{
        "live_action" => "edit",
        "project_id" => project.uuid,
        "id" => a.uuid,
        "from_view" => "1"
      })

      {:noreply, socket}
    else
      {:noreply, push_navigate(socket, to: Paths.edit_assignment(project.uuid, a.uuid))}
    end
  end

  # Another task of this project (a connection, a subtask, the parent):
  # its view in the same drawer, with a way back to this one.
  def handle_event("open_task", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    %{project: project, assignment: a} = socket.assigns

    case Projects.get_assignment(uuid) do
      %Assignment{project_uuid: p} when p == project.uuid ->
        if socket.assigns.embed_mode == :emit do
          WebHelpers.emit_swap(socket, __MODULE__, %{
            "project_id" => project.uuid,
            "id" => uuid,
            "back_to" => a.uuid
          })

          {:noreply, socket}
        else
          {:noreply, push_navigate(socket, to: Paths.view_assignment(project.uuid, uuid))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # The next step, run by the page under the drawer. Its dialogs take over,
  # so the view steps aside — except for Start, which has no dialog: the
  # view stays and shows the new status.
  def handle_event("step", %{"step" => step}, %{assigns: %{can_step?: true}} = socket)
      when step in @steps do
    WebHelpers.emit_intent(socket, step, socket.assigns.assignment.uuid)

    if step == "start_task",
      do: {:noreply, socket},
      else: {:noreply, WebHelpers.close_or_navigate(socket, project_path(socket))}
  end

  def handle_event("activity_tab", %{"tab" => tab}, socket)
      when tab in ~w(comments history notes) do
    {:noreply, assign(socket, activity_tab: tab)}
  end

  def handle_event("toggle_desc", _params, socket),
    do: {:noreply, assign(socket, desc_open?: not socket.assigns.desc_open?)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Live updates ────────────────────────────────────────────────────

  @impl true
  def handle_info({:projects, :assignment_deleted, %{uuid: uuid}}, socket) do
    if match?(%Assignment{uuid: ^uuid}, socket.assigns[:assignment]),
      do: {:noreply, WebHelpers.close_or_navigate(socket, project_path(socket))},
      else: {:noreply, reload(socket)}
  end

  def handle_info({:projects, event, _payload}, socket)
      when event in [
             :assignment_created,
             :assignment_updated,
             :assignment_deleted,
             :assignment_status_changed,
             :assignment_reordered,
             :dependency_added,
             :dependency_removed,
             :task_updated,
             :project_updated,
             :project_labels_changed,
             :work_logged
           ] do
    {:noreply, reload(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp project_path(%{assigns: %{project: %Project{uuid: uuid}}}), do: Paths.project(uuid)
  defp project_path(_socket), do: Paths.projects()

  # ── Render ──────────────────────────────────────────────────────────

  @impl true
  def render(%{not_found?: true} = assigns) do
    ~H"""
    <div class={@wrapper_class}></div>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, :lang, L10n.current_content_lang())

    ~H"""
    <div class={@wrapper_class} id={"task-view-#{@assignment.uuid}"}>
      <%!-- Header: where it sits, what it is, where it stands, what next. --%>
      <header class="flex flex-col gap-2">
        <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm min-w-0">
          <button
            :if={@back_task}
            type="button"
            phx-click="open_task"
            phx-value-uuid={@back_task.uuid}
            class="link link-hover text-base-content/70 inline-flex items-center gap-1"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
            {gettext("Back to “%{task}”", task: Assignment.label(@back_task, @lang))}
          </button>
          <.ref_chip :if={@ref} ref={@ref} />
          <span :if={@parent} class="text-base-content/60 min-w-0 truncate">
            {gettext("Part of")}
            <button
              type="button"
              phx-click="open_task"
              phx-value-uuid={@parent.uuid}
              class="link link-hover"
            >
              {Assignment.label(@parent, @lang)}
            </button>
          </span>
          <div class="ml-auto flex items-center gap-1">
            <button :if={@can_edit?} type="button" phx-click="edit" class="btn btn-ghost btn-sm gap-1">
              <.icon name="hero-pencil-square" class="w-4 h-4" /> {gettext("Edit")}
            </button>
            <%!-- In a drawer the drawer has its ✕; one more here made two.
                 On its own page this is the way back to the project. --%>
            <button
              :if={@embed_mode != :emit}
              type="button"
              phx-click="close"
              class="btn btn-ghost btn-sm btn-square"
              aria-label={gettext("Close")}
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </div>
        </div>

        <h2 class="text-xl font-semibold leading-snug text-balance">
          {Assignment.label(@assignment, @lang)}
        </h2>

        <div :if={not @project.is_template} class="flex flex-wrap items-center gap-2">
          <.assignment_status_badge status={@assignment.status} size="md" />
          <span
            :if={@assignment.status == "in_progress" and Enum.any?(@waits_on, &(&1.status != "done"))}
            class="badge badge-warning gap-1"
          >
            <.icon name="hero-pause-circle" class="w-3.5 h-3.5" /> {gettext("On hold")}
          </span>
          <.next_step :if={@can_step?} assignment={@assignment} fx={@fx} embed_mode={@embed_mode} project={@project} />
        </div>
      </header>

      <div class="grid gap-6 @2xl:grid-cols-[minmax(0,1fr)_15rem]">
        <%!-- Details: beside the main column when the drawer is wide,
             above it when it is narrow. Blank optional fields are left
             out, never "None". --%>
        <aside class="@2xl:col-start-2 @2xl:row-start-1">
          <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-2 text-sm rounded-box border border-base-200 p-3 @2xl:border-0 @2xl:p-0">
            <dt :if={@fx.assignees} class="text-base-content/60">{gettext("Assignee")}</dt>
            <dd :if={@fx.assignees} class="min-w-0 truncate">
              <%= if assignee_kind(@assignment) do %>
                <span class="inline-flex items-center gap-1.5 max-w-full">
                  <.assignee_faces faces={@faces} size="xs" />
                  <.icon :if={is_nil(@faces)} name={assignee_icon(@assignment)} class="w-3.5 h-3.5 shrink-0 opacity-60" />
                  <span class="truncate">{assignee_label(@assignment)}</span>
                </span>
              <% else %>
                <span class="text-base-content/60">{gettext("Unassigned")}</span>
              <% end %>
            </dd>

            <dt :if={@fx.priorities} class="text-base-content/60">{gettext("Priority")}</dt>
            <dd :if={@fx.priorities}>{priority_label(@assignment.priority)}</dd>

            <%!-- The deadline is the promise (red once missed); the
                 planned days are a plan, never red; then when the work
                 really began and ended. --%>
            <%= if @fx[:dates] != false do %>
              <dt :if={@assignment.deadline} class="text-base-content/60">{gettext("Deadline")}</dt>
              <dd :if={@assignment.deadline}><.deadline_chip a={@assignment} /></dd>

              <% planned = planned_label(@assignment) %>
              <dt :if={planned} class="text-base-content/60">{gettext("Planned")}</dt>
              <dd :if={planned}>{planned}</dd>
            <% end %>

            <dt :if={@assignment.started_at} class="text-base-content/60">{gettext("Started")}</dt>
            <dd :if={@assignment.started_at}>{L10n.format_datetime(@assignment.started_at)}</dd>

            <dt :if={@assignment.completed_at} class="text-base-content/60">{gettext("Finished")}</dt>
            <dd :if={@assignment.completed_at}>{L10n.format_datetime(@assignment.completed_at)}</dd>

            <% estimate = estimate_label(@assignment) %>
            <dt :if={@fx.estimates and estimate} class="text-base-content/60">{gettext("Estimate")}</dt>
            <dd :if={@fx.estimates and estimate}>{estimate}</dd>

            <dt :if={@logged} class="text-base-content/60">{gettext("Logged")}</dt>
            <dd :if={@logged}>
              {Format.duration(@logged.minutes || 0)}
              <span :if={(@logged.ai_minutes || 0) > 0} class="text-base-content/60">
                · {gettext("AI %{time}", time: Format.duration(@logged.ai_minutes))}
              </span>
            </dd>

            <dt :if={@labels != []} class="text-base-content/60">{gettext("Labels")}</dt>
            <dd :if={@labels != []} class="flex flex-wrap gap-1">
              <span :for={label <- @labels} class={["badge badge-sm", label.color]}>{label.name}</span>
            </dd>

            <dt :if={@assignment.track_progress} class="text-base-content/60">{gettext("Progress")}</dt>
            <dd :if={@assignment.track_progress}>{@assignment.progress_pct}%</dd>
          </dl>
        </aside>

        <main class="flex flex-col gap-6 min-w-0 @2xl:col-start-1 @2xl:row-start-1">
          <%!-- Description, folded to a few lines until asked for. --%>
          <% desc = Assignment.localized_description(@assignment, @lang) || task_description(@assignment, @lang) %>
          <section :if={present?(desc)} class="flex flex-col gap-1">
            <div class={["text-sm whitespace-pre-line", not @desc_open? && "line-clamp-6"]}>
              <.mention_text text={desc} scope={@phoenix_kit_current_scope} />
            </div>
            <button
              :if={String.length(desc) > 400 or length(String.split(desc, "\n")) > 6}
              type="button"
              phx-click="toggle_desc"
              class="link link-hover text-xs text-base-content/60 self-start"
            >
              {if @desc_open?, do: gettext("Show less"), else: gettext("Show more")}
            </button>
          </section>
          <button
            :if={not present?(desc) and @can_edit?}
            type="button"
            phx-click="edit"
            class="text-sm text-base-content/50 hover:text-base-content self-start"
          >
            {gettext("Add a description")}
          </button>

          <%!-- Connections, in words: the cards no longer carry them. --%>
          <section :if={@waits_on != [] or @unlocks != []} class="flex flex-col gap-3">
            <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              {gettext("Connections")}
            </h3>
            <.task_rows :if={@waits_on != []} title={gettext("Waits on")} rows={@waits_on} lang={@lang} project={@project} />
            <.task_rows :if={@unlocks != []} title={gettext("Unlocks")} rows={@unlocks} lang={@lang} project={@project} />
          </section>

          <%!-- Subtasks with how far they are. --%>
          <section :if={@subtasks != []} class="flex flex-col gap-2">
            <% done = Enum.count(@subtasks, &(&1.status == "done")) %>
            <div class="flex items-center gap-3">
              <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                {gettext("Subtasks")}
              </h3>
              <span class="text-xs text-base-content/60 tabular-nums">{done}/{length(@subtasks)}</span>
              <progress class="progress progress-success w-24 h-1.5" value={done} max={length(@subtasks)}></progress>
            </div>
            <.task_rows rows={@subtasks} lang={@lang} project={@project} />
          </section>

          <%!-- Activity: one place, three tabs. --%>
          <section :if={@threads || @history != []} class="flex flex-col gap-3">
            <div role="tablist" class="tabs tabs-border">
              <button
                :if={@threads}
                type="button"
                role="tab"
                phx-click="activity_tab"
                phx-value-tab="comments"
                class={["tab gap-1", @activity_tab == "comments" && "tab-active"]}
                aria-selected={to_string(@activity_tab == "comments")}
              >
                {gettext("Comments")}
                <span :if={@threads.comments > 0} class="text-xs opacity-60">{@threads.comments}</span>
              </button>
              <button
                :if={@history != []}
                type="button"
                role="tab"
                phx-click="activity_tab"
                phx-value-tab="history"
                class={["tab", @activity_tab == "history" && "tab-active"]}
                aria-selected={to_string(@activity_tab == "history")}
              >
                {gettext("History")}
              </button>
              <button
                :if={@threads && @threads.notes > 0}
                type="button"
                role="tab"
                phx-click="activity_tab"
                phx-value-tab="notes"
                class={["tab gap-1", @activity_tab == "notes" && "tab-active"]}
                aria-selected={to_string(@activity_tab == "notes")}
              >
                {gettext("AI notes")}
                <span class="text-xs opacity-60">{@threads.notes}</span>
              </button>
            </div>

            <.live_component
              :if={@threads && @activity_tab == "comments"}
              module={PhoenixKitComments.Web.CommentsComponent}
              id={"task-view-comments-#{@assignment.uuid}"}
              resource_type="assignment"
              resource_uuid={@assignment.uuid}
              current_user={assigns[:phoenix_kit_current_user]}
              title=""
              show_likes={true}
            />
            <PhoenixKitProjects.Web.Components.HistoryFeed.history_feed
              :if={@activity_tab == "history" and @history != []}
              id={"task-view-history-#{@assignment.uuid}"}
              entries={@history}
              project={@project}
              compact={true}
            />
            <.live_component
              :if={@threads && @activity_tab == "notes"}
              module={PhoenixKitComments.Web.CommentsComponent}
              id={"task-view-notes-#{@assignment.uuid}"}
              resource_type={PhoenixKitProjects.TaskNotes.resource_type()}
              resource_uuid={@assignment.uuid}
              current_user={assigns[:phoenix_kit_current_user]}
              title=""
              show_likes={false}
              decoration_keys={PhoenixKitProjects.TaskNotes.decoration_keys()}
              comment_decorations={PhoenixKitProjects.TaskNotes.decorations(PhoenixKitProjects.TaskNotes.list(@assignment.uuid))}
            />
          </section>
        </main>
      </div>
    </div>
    """
  end

  # The one next step for the task's status, as the list's row offers it.
  attr(:assignment, :map, required: true)
  attr(:fx, :map, required: true)
  attr(:embed_mode, :atom, required: true)
  attr(:project, :map, required: true)

  defp next_step(assigns) do
    assigns = assign(assigns, :step, step_for(assigns.assignment, assigns.fx))

    ~H"""
    <%= if @step do %>
      <% {event, label, class, icon} = @step %>
      <%!-- On its own page there is no project page under it to run the
           step's dialog: the button takes you there, to this task. --%>
      <.link
        :if={@embed_mode == :navigate}
        navigate={Paths.task(@project, @assignment)}
        class={["btn btn-sm gap-1 ml-auto", class]}
      >
        <.icon name={icon} class="w-4 h-4" /> {label}
      </.link>
      <button
        :if={@embed_mode != :navigate}
        type="button"
        phx-click="step"
        phx-value-step={event}
        phx-disable-with={gettext("Saving…")}
        class={["btn btn-sm gap-1 ml-auto", class]}
      >
        <.icon name={icon} class="w-4 h-4" /> {label}
      </button>
    <% end %>
    """
  end

  defp step_for(%Assignment{child_project_uuid: child}, _fx) when is_binary(child), do: nil

  defp step_for(%Assignment{status: "waiting"}, _fx),
    do: {"ask_ready", gettext("Ready to start"), "btn-info", "hero-play-circle"}

  defp step_for(%Assignment{status: "todo"}, %{in_progress: true}),
    do: {"start_task", gettext("Start"), "btn-warning", "hero-play"}

  defp step_for(%Assignment{status: status}, _fx) when status in ["todo", "in_progress"],
    do: {"complete", gettext("Done"), "btn-success", "hero-check"}

  defp step_for(%Assignment{status: "done"}, _fx),
    do: {"ask_reopen", gettext("Reopen"), "btn-ghost", "hero-arrow-uturn-left"}

  defp step_for(_assignment, _fx), do: nil

  # Rows of other tasks — a connection, a subtask — each opening its view.
  attr(:title, :string, default: nil)
  attr(:rows, :list, required: true)
  attr(:lang, :string, required: true)
  attr(:project, :map, required: true)

  defp task_rows(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <span :if={@title} class="text-sm text-base-content/70">{@title}</span>
      <ul class="flex flex-col divide-y divide-base-200 rounded-box border border-base-200">
        <li :for={row <- @rows}>
          <button
            type="button"
            phx-click="open_task"
            phx-value-uuid={row.uuid}
            class="w-full flex items-center gap-2 px-3 py-2 text-sm text-left hover:bg-base-200/60"
          >
            <.assignment_status_badge status={row.status} size="xs" class="shrink-0" />
            <span :if={Refs.task_ref(@project.key, row.number)} class="font-mono text-xs text-base-content/60 shrink-0">
              {Refs.task_ref(@project.key, row.number)}
            </span>
            <span class={["min-w-0 truncate", row.status == "done" && "text-base-content/60"]}>
              {Assignment.label(row, @lang)}
            </span>
            <span :if={assignee_kind(row)} class="ml-auto text-xs text-base-content/60 truncate shrink-0 max-w-[40%]">
              {assignee_label(row)}
            </span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  # ── Small helpers ───────────────────────────────────────────────────

  defp present?(text), do: is_binary(text) and String.trim(text) != ""

  defp task_description(%Assignment{task: %Task{} = task}, lang),
    do: Task.localized_description(task, lang)

  defp task_description(_assignment, _lang), do: nil

  defp assignee_kind(%{assigned_person_uuid: p}) when is_binary(p), do: :person
  defp assignee_kind(%{assigned_team_uuid: t}) when is_binary(t), do: :team
  defp assignee_kind(%{assigned_department_uuid: d}) when is_binary(d), do: :department
  defp assignee_kind(_), do: nil

  defp assignee_icon(a) do
    case assignee_kind(a) do
      :team -> "hero-users"
      :department -> "hero-building-office"
      _ -> "hero-user"
    end
  end

  defp priority_label("urgent"), do: gettext("Urgent")
  defp priority_label("high"), do: gettext("High")
  defp priority_label("low"), do: gettext("Low")
  defp priority_label(_), do: gettext("Normal")

  defp estimate_label(%Assignment{estimated_duration: n, estimated_duration_unit: unit})
       when is_integer(n) and n > 0,
       do: Task.format_duration(n, unit)

  defp estimate_label(_), do: nil
end
