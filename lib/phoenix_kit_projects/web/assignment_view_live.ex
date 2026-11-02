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
  Only a host that said it runs them (session `"step_intents" => "1"`,
  which `ProjectShowLive` passes when it opens the view) gets the intent;
  anywhere else — the Time page, a host's own drawer, the routed page —
  nobody would answer it, so the button is a link to the task on its
  project page, where the step and its dialogs are.

  Mount only, no `handle_params/3`: it is embedded as a drawer frame.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components
  use PhoenixKit.Mentions.Live
  use PhoenixKitComments.Embed

  require Logger

  alias PhoenixKitProjects.Web.Components.AssignmentStatusBadge

  alias PhoenixKitProjects.{
    Assignees,
    Attachments,
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
  alias PhoenixKitProjects.Web.Crumbs
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  import PhoenixKitProjects.Web.Components.TaskTimes, only: [deadline_chip: 1, planned_label: 1]
  import PhoenixKitProjects.Web.Components.RichText, only: [rich_text: 1]
  import PhoenixKitProjects.Web.Components.TaskFiles, only: [task_files: 1]

  @default_wrapper_class "@container flex flex-col w-full mx-auto max-w-5xl px-4 py-6 gap-5"

  # The steps the project page runs for the view (`ProjectShowLive`'s
  # `:intent` handler accepts exactly these).
  @steps ~w(ask_ready start_task complete ask_reopen reopen make_idle)

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
      |> then(&assign(&1, step_intents?: step_intents?(&1, session)))
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
        # A library task's rename goes to the task topics only.
        ProjectsPubSub.subscribe(ProjectsPubSub.topic_tasks())
      end

      socket
      |> assign(subscribed: true, project: project, assignment: assignment, not_found?: false)
      |> assign_view(scope)
      |> assign_title(project, assignment, scope)
    else
      not_found(socket)
    end
  end

  defp load(socket, _project_id, _id), do: not_found(socket)

  # Whether the page under the drawer runs the next step for the view. Only
  # in a drawer: the routed page has no page under it.
  defp step_intents?(socket, session) do
    socket.assigns[:embed_mode] == :emit and Map.get(session, "step_intents") in ["1", true]
  end

  # Carried along when the drawer swaps to another frame of the same host.
  defp with_step_intents(session, %{assigns: %{step_intents?: true}}),
    do: Map.put(session, "step_intents", "1")

  defp with_step_intents(session, _socket), do: session

  # Routed, the page has the admin header's trail and its own title. In a
  # drawer the host page keeps both: a frame never renames the browser tab.
  defp assign_title(socket, project, assignment, scope) do
    socket = assign(socket, page_title: Assignment.label(assignment, L10n.current_content_lang()))

    if socket.assigns[:embed_mode] == :navigate,
      do: assign(socket, Crumbs.under_project(project, scope)),
      else: WebHelpers.keep_host_title(socket)
  end

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

    files =
      if project.is_template, do: [], else: Attachments.list_task_files(a.uuid, inline: false)

    assign(socket,
      files: files,
      file_urls: Attachments.download_urls(Enum.map(files, & &1.file)),
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
      WebHelpers.emit_swap(
        socket,
        PhoenixKitProjects.Web.AssignmentFormLive,
        with_step_intents(
          %{
            "live_action" => "edit",
            "project_id" => project.uuid,
            "id" => a.uuid,
            "from_view" => "1"
          },
          socket
        )
      )

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
          WebHelpers.emit_swap(
            socket,
            __MODULE__,
            with_step_intents(
              %{"project_id" => project.uuid, "id" => uuid, "back_to" => a.uuid},
              socket
            )
          )

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
  # view stays and shows the new status. Only where a page runs it: anywhere
  # else the button is a link and this event is never sent.
  def handle_event(
        "step",
        %{"step" => step},
        %{assigns: %{can_step?: true, step_intents?: true}} = socket
      )
      when step in @steps do
    WebHelpers.emit_intent(socket, step, socket.assigns.assignment.uuid)

    if step in ~w(start_task reopen make_idle),
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

  # Announced beside `:assignment_updated` (and, for the rows a completion
  # rule ticks, beside `:assignment_reordered`), which reload already —
  # reloading on it too ran every read twice per change.
  def handle_info({:projects, :assignment_status_changed, _payload}, socket),
    do: {:noreply, socket}

  # The library task this one is made from was renamed or edited.
  def handle_info({:projects, :task_updated, %{uuid: uuid}}, socket) do
    if match?(%Assignment{task_uuid: ^uuid}, socket.assigns[:assignment]),
      do: {:noreply, reload(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:projects, event, _payload}, socket)
      when event in [
             :assignment_created,
             :assignment_updated,
             :assignment_deleted,
             :assignment_reordered,
             :dependency_added,
             :dependency_removed,
             :project_updated,
             :project_labels_changed,
             :work_logged
           ] do
    {:noreply, reload(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[AssignmentViewLive] unexpected handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

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
      <header class="flex flex-col gap-1.5">
        <%!-- One row, as every popup's: back, the ref pill, the name and the
             close (the boss, 2026-11-02: the status and Edit belong with the
             details below, not beside the name). --%>
        <div class={["flex items-center gap-2 min-w-0", @embed_mode == :emit && "pr-8"]}>
          <button
            :if={@back_task}
            type="button"
            phx-click="open_task"
            phx-value-uuid={@back_task.uuid}
            class="btn btn-ghost btn-sm btn-square shrink-0"
            title={gettext("Back to “%{task}”", task: Assignment.label(@back_task, @lang))}
            aria-label={gettext("Back to “%{task}”", task: Assignment.label(@back_task, @lang))}
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </button>
          <.ref_chip :if={@ref} ref={@ref} />
          <h2 class="flex-1 min-w-0 text-lg font-semibold leading-tight break-words">
            {Assignment.label(@assignment, @lang)}
          </h2>
          <%!-- In a drawer the drawer has its ✕; one more here made two.
               On its own page this is the way back to the project. --%>
          <button
            :if={@embed_mode != :emit}
            type="button"
            phx-click="close"
            class="btn btn-ghost btn-sm btn-square shrink-0"
            aria-label={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>

        <div :if={@parent} class="flex flex-wrap items-center gap-2 text-sm">
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
        </div>
      </header>

      <div class="grid gap-6 @2xl:grid-cols-[minmax(0,1fr)_15rem]">
        <%!-- Details: beside the main column when the drawer is wide,
             above it when it is narrow. Blank optional fields are left
             out, never "None". --%>
        <aside class="relative @2xl:col-start-2 @2xl:row-start-1">
          <%!-- Edit, at the corner of the facts it edits (the boss,
               2026-11-02: not beside the name, not a row of its own). --%>
          <button
            :if={@can_edit?}
            type="button"
            phx-click="edit"
            class="btn btn-ghost btn-xs gap-1 absolute top-2 right-2 @2xl:top-0 @2xl:right-0"
          >
            <.icon name="hero-pencil-square" class="w-3.5 h-3.5" /> {gettext("Edit")}
          </button>
          <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-2 text-sm rounded-box border border-base-200 p-3 @2xl:border-0 @2xl:p-0">
            <%!-- The status as a row of the details, a press away from the
                 others (the boss, 2026-11-02); no "Mark done" button. --%>
            <dt :if={not @project.is_template} class="text-base-content/60">{gettext("Status")}</dt>
            <dd :if={not @project.is_template} class="flex flex-wrap items-center gap-2 min-w-0 pr-16">
              <.view_status
                assignment={@assignment}
                fx={@fx}
                can_step?={@can_step? and @step_intents?}
              />
              <span
                :if={@assignment.status == "in_progress" and Enum.any?(@waits_on, &(&1.status != "done"))}
                class="badge badge-warning badge-sm gap-1"
              >
                <.icon name="hero-pause-circle" class="w-3.5 h-3.5" />
                {AssignmentStatusBadge.on_hold_label(Assignment.subproject?(@assignment))}
              </span>
            </dd>

            <dt :if={@fx.assignees} class="text-base-content/60">{gettext("Assignee")}</dt>
            <dd :if={@fx.assignees} class="min-w-0 truncate">
              <%= if assignee_kind(@assignment) do %>
                <.assignee_shown a={@assignment} faces={@faces} class="max-w-full" />
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

            <dt :if={@assignment.completed_at} class="text-base-content/60">{if Assignment.subproject?(@assignment), do: pgettext("sub-project", "Finished"), else: pgettext("task", "Finished")}</dt>
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
          <%!-- Description, folded to a few lines until asked for. Drawn
               as the Leaf editor wrote it (bold, lists, images), its
               mentions resolved for the viewer; plain text from before
               the editor reads as it did. --%>
          <% desc = Assignment.localized_description(@assignment, @lang) || task_description(@assignment, @lang) %>
          <section :if={present?(desc)} class="flex flex-col gap-1">
            <.rich_text
              text={desc}
              scope={@phoenix_kit_current_scope}
              class={["text-sm", not @desc_open? && "line-clamp-6"]}
            />
            <button
              :if={String.length(desc) > 400 or length(String.split(desc, "\n")) > 6}
              type="button"
              phx-click="toggle_desc"
              class="link link-hover text-xs text-base-content/60 self-start"
            >
              {if @desc_open?, do: gettext("Show less"), else: gettext("Show more")}
            </button>
          </section>

          <%!-- The files added to the task, to look at or download. Only
               the ones added as files: the images pasted into the
               description already show in it. Removing one is the edit
               popup's job. --%>
          <section :if={@files != []} class="flex flex-col gap-2">
            <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              {gettext("Files")}
            </h3>
            <.task_files id={"task-view-files-#{@assignment.uuid}"} files={@files} urls={@file_urls} />
          </section>

          <%!-- Connections, in words: the cards no longer carry them. No
               "Connections" heading on a line of its own: "Waits on" and
               "Unlocks" already say what each list is. --%>
          <section :if={@waits_on != [] or @unlocks != []} class="flex flex-col gap-3">
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
            <%!-- The tabs' edge on the details box's, their words and what
                 they open on one line further in (the boss, 2026-11-02). --%>
            <div role="tablist" class="tabs tabs-border [&>.tab]:px-3">
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

            <div class="px-3">
            <.live_component
              :if={@threads && @activity_tab == "comments"}
              module={PhoenixKitComments.Web.CommentsComponent}
              id={"task-view-comments-#{@assignment.uuid}"}
              resource_type="assignment"
              resource_uuid={@assignment.uuid}
              current_user={assigns[:phoenix_kit_current_user]}
              title=""
              show_likes={false}
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
            </div>
          </section>
        </main>
      </div>
    </div>
    """
  end

  attr(:assignment, :map, required: true)
  attr(:fx, :map, required: true)
  attr(:can_step?, :boolean, default: false)

  # The status; where the page under the drawer runs steps, a press opens
  # the statuses, each run as that step there (its dialogs included).
  # A menu only when there is another status to choose: a sub-project
  # that follows its tasks offers none once it has started (panel review).
  defp view_status(%{can_step?: true, assignment: a, fx: fx} = assigns)
       when is_map(a) and is_map(fx) do
    if Enum.any?(AssignmentStatusBadge.choices(a, fx), &(&1 != a.status)),
      do: view_status_menu(assigns),
      else: view_status(Map.put(assigns, :can_step?, false))
  end

  defp view_status(assigns) do
    ~H"""
    <.assignment_status_badge status={@assignment.status} subproject={Assignment.subproject?(@assignment)} />
    """
  end

  defp view_status_menu(assigns) do
    ~H"""
    <details class="dropdown" id={"view-status-pop-#{@assignment.uuid}"}>
      <summary
        class="list-none cursor-pointer [&::-webkit-details-marker]:hidden"
        title={pgettext("task action", "Change status")}
      >
        <.assignment_status_badge status={@assignment.status} subproject={Assignment.subproject?(@assignment)} />
      </summary>
      <ul class="dropdown-content z-30 mt-1 min-w-[11rem] rounded-box bg-base-100 border border-base-200 shadow-xl p-1">
        <li :for={status <- AssignmentStatusBadge.choices(@assignment, @fx)} role="none">
          <button
            type="button"
            id={"view-status-#{@assignment.uuid}-#{status}"}
            role="menuitemradio"
            aria-checked={to_string(status == @assignment.status)}
            disabled={status == @assignment.status}
            phx-click="step"
            phx-value-step={status_step(@assignment, status)}
            class="flex items-center gap-2 px-3 py-2 rounded-lg text-sm w-full text-left hover:bg-base-200 disabled:cursor-default disabled:hover:bg-transparent"
          >
            <span class={["inline-block w-2.5 h-2.5 rounded-full shrink-0", AssignmentStatusBadge.color(status)]}></span>
            <span class="flex-1">{AssignmentStatusBadge.label(status, Assignment.subproject?(@assignment))}</span>
          </button>
        </li>
      </ul>
    </details>
    """
  end

  # The project page's mapping from the status chosen to the step that
  # makes it so (`ProjectShowLive`'s `set_status`).
  defp status_step(%Assignment{status: same}, same), do: nil
  defp status_step(_a, "done"), do: "complete"
  defp status_step(%Assignment{status: "waiting"}, "todo"), do: "ask_ready"
  defp status_step(%Assignment{status: "done"}, "todo"), do: "ask_reopen"
  defp status_step(_a, "todo"), do: "reopen"
  defp status_step(_a, "in_progress"), do: "start_task"
  defp status_step(_a, "waiting"), do: "make_idle"

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
            <.ref_chip ref={Refs.task_ref(@project.key, row.number)} />
            <span class={["min-w-0 truncate", row.status == "done" && "text-base-content/60"]}>
              {Assignment.label(row, @lang)}
            </span>
            <.assignee_shown
              :if={assignee_kind(row)}
              a={row}
              class="ml-auto text-xs text-base-content/60 shrink-0 max-w-[40%]"
            />
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

  # Whether anyone is on it, and as what (V29: several show as people).
  defp assignee_kind(a) do
    case PhoenixKitProjects.People.assignee_keys(a) do
      [] -> nil
      [{kind, _}] -> String.to_existing_atom(kind)
      _several -> :team
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
