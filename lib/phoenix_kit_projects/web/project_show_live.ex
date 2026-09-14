defmodule PhoenixKitProjects.Web.ProjectShowLive do
  @moduledoc """
  Show a project with a vertical timeline of assignments.
  Supports inline status changes, duration editing, dependency
  management, and tracks who completed each task.

  ## List / Timeline / Calendar tabs

  The page has three views — the vertical task list, the embedded
  `ProjectGanttLive` Timeline, and the embedded `ProjectCalendarLive` month
  calendar — toggled by tabs under the shared header. Switching is instant (an
  assign flip) and each nested LV is lazily mounted on first open, then kept
  (so the gantt's zoom/expand and the calendar's month navigation survive
  switching back). **The tabs render in every mount context, embedded
  `live_render` renders included** (only templates stay list-only). Note this
  means the Timeline/Calendar tabs are nested `live_render`s, which are
  themselves nested LVs when the show page is embedded — deliberate,
  server-rendered, so both views show even before any JS loads.

  The page is a set of TOP-LEVEL tabs — Tasks (List / Board / Timeline /
  Calendar behind its own, subordinate strip), one per enabled extension
  that contributes a tab (Events, Whiteboards, …) and Comments (the
  project's own thread, switched by the Discussions extension). Each stands
  alone in an otherwise empty project, so a project can be *only* a
  whiteboard or *only* a discussion. The header stays: it is the project,
  not a tab. Templates keep the Tasks tab alone, without the strip.

  Keeping the URL in sync (`/tasks/board`, `/whiteboards`, `/comments`) is
  **optional and off by default**: it's only on when `@tab_url_sync?` is true,
  which the router-mounted standalone admin page sets (so its deep-linking
  keeps working) and an embed can opt into via `session["tab_url_sync"]`. When
  on, the strip carries the active tab's canonical address in `data-url` and
  core's `PkUrlMirror` hook REPLACES the browser's URL with it on every
  render — deep links / copy / reload land on the right tab, while
  back/forward return to the previous page. Deliberately no per-tab history
  entries: they'd need this LV to export `handle_params/3` (which would block
  `live_render` embedding), and LiveView's popstate handler treats foreign
  pushState entries as live navigation — remounting and crashing on the
  missing callback. With sync off the tabs still switch fully — they just
  never touch the host page's URL.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components
  # A redacted mention on this page is a button; this is what makes it do
  # something. Without it the chip still explains itself, it just can't ask.
  use PhoenixKit.Mentions.Live

  # Forwards the comment composer's {:leaf_changed, …} process message into
  # CommentsComponent.forward_leaf_event/2 via a :handle_info lifecycle hook
  # (halts only :leaf_changed, passes everything else through); without it
  # "Post Comment" silently submits empty content. comments is a hard dep here.
  use PhoenixKitComments.Embed

  alias PhoenixKitProjects.{
    Activity,
    Authz,
    Extensions,
    Features,
    Health,
    Invoicing,
    L10n,
    Labels,
    Ledger,
    ListControls,
    Paths,
    Portal,
    Projects,
    Statuses
  }

  alias PhoenixKitProjects.Web.Crumbs

  alias PhoenixKitProjects.Extensions.Registry, as: ExtRegistry
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.{Assignment, Project}
  alias PhoenixKitProjects.Schemas.Task, as: TaskSchema
  alias PhoenixKitProjects.Web.Components.AssignmentStatusBadge
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  # Schedule/assignee helpers shared with ProjectGanttLive — imported so the
  # template's bare calls resolve. See PhoenixKitProjects.Web.Helpers.
  import PhoenixKitProjects.Web.Helpers,
    only: [assignee_label: 1, task_counts_weekends?: 2, assignment_hours: 2]

  import PhoenixKitWeb.Components.Core.TimeDisplay, only: [time_ago: 1]

  require Logger

  # Default wrapper class for the standalone admin page. Embedders can
  # override via `live_render(... session: %{"wrapper_class" => "..."})`
  # to drop `mx-auto max-w-4xl` and fill a wider host layout.
  # Tight vertical rhythm for short client screens (matches the list pages).
  @default_wrapper_class "flex flex-col w-full px-4 pt-2 pb-4 gap-4"

  # A router-mounted page hosts its OWN drawer for forms: `:popup` embed
  # mode keeps page semantics everywhere (save/cancel navigate, the URL is
  # ours) but routes "open a form" to `PopupHostLive` rendered at the foot
  # of this page (see `render/1`), which shows it as a right-hand sheet
  # over the plan. The topic is per LiveView instance, so two tabs of the
  # same project never cross. An embed (`live_render`) never gets here —
  # its clause restores the session's own mode right after.
  defp assign_popup_mode(%{assigns: %{embed_mode: :navigate}} = socket) do
    assign(socket,
      embed_mode: :popup,
      embed_pubsub_topic: ProjectsPubSub.topic_popup(socket.id),
      embed_frame_ref: nil
    )
  end

  defp assign_popup_mode(socket), do: socket

  # Embedded entry: when nested via `live_render`, params arrives as
  # `:not_mounted_at_router` and `session` carries the project id (plus
  # any `wrapper_class` override). Delegate to the router clause so the
  # mount logic stays single-sourced.
  @impl true
  def mount(:not_mounted_at_router, %{"id" => id} = session, socket) do
    WebHelpers.maybe_put_locale(session)
    # Reuse the router mount, then adjust for the embed context. The List/Timeline
    # tabs DO render in embeds now (the gantt is a nested `live_render`, which is
    # fine — it's server-rendered). Two things differ from the router mount:
    #   * `router_mounted?: false` — purely informational now (a few comments key
    #     off it); the tab bar no longer gates on it.
    #   * `tab_url_sync?` — OFF by default in an embed (an embed must not rewrite
    #     the host's URL); a host can opt back in with `session["tab_url_sync"]`.
    # `live_action` is nil here, so `active_tab` already defaults to `:list`.
    {:ok, socket} = mount(%{"id" => id}, session, socket)

    {:ok,
     socket
     # The router clause switched to `:popup` mode (its own drawer); an
     # embed follows its session instead — `navigate` or the host's `emit`.
     |> WebHelpers.assign_embed_state(session)
     |> assign(
       router_mounted?: false,
       gantt_mounted?: false,
       calendar_mounted?: false,
       # Strict `== true` so only a real boolean opt-in turns it on (a stray
       # string would otherwise read as truthy and re-enable URL rewriting).
       tab_url_sync?: Map.get(session, "tab_url_sync", false) == true
     )}
  end

  # Fail-closed: emit-session lacking `"id"` lands here. Without this
  # clause the mount/3 dispatch raises `FunctionClauseError`. Render
  # placeholders + flash + close so the host pops the modal.
  #
  # `maybe_put_locale/1` first so the "Project not found." flash
  # renders in the host's locale — matches every other LV's mount/3
  # contract and avoids an English flash on a misrouted modal.
  def mount(:not_mounted_at_router, session, socket) do
    WebHelpers.maybe_put_locale(session)

    socket =
      socket
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)

    # The same placeholder set as the router clause's not-found branch,
    # with the two assigns an embed resolves differently: it must not
    # rewrite the host's URL, and its wrapper comes from the session.
    # Kept as an override list rather than a second copy — the two were
    # 49 identical keys that had to be edited in lockstep.
    {:ok,
     socket
     |> assign(
       Keyword.merge(not_found_assigns(),
         tab_url_sync?: false,
         wrapper_class: Map.get(session, "wrapper_class", @default_wrapper_class)
       )
     )
     |> put_flash(:error, gettext("Project not found."))
     |> WebHelpers.close_or_navigate(Paths.projects())}
  end

  def mount(%{"id" => id} = params, session, socket) do
    # Locale first so any error flashes / placeholders render in the
    # right language. Embed state second so the not-found path can
    # honor emit mode (broadcasting `:closed` instead of push_navigate).
    # Embed user third: when this LV is rendered via `live_render` the
    # `:phoenix_kit_ensure_admin` on_mount hook never runs, so the host
    # supplies the current user via `session["current_user_uuid"]`. On the
    # router path the hook already set the scope and this is a no-op.
    WebHelpers.maybe_put_locale(session)

    socket =
      socket
      |> WebHelpers.assign_embed_state(session)
      |> assign_popup_mode()
      |> WebHelpers.assign_embed_user(session)

    # `get_project/1` stays in mount/3 because the not-found path
    # has to redirect before render, and the per-project PubSub
    # topic needs the project.uuid to subscribe to. The heavier
    # assignment/comment loads sit at the tail of mount/3 (not
    # `handle_params/3`) because Phoenix LiveView refuses to mount a
    # LV that exports `handle_params/3` outside a router live route,
    # which would block embedding via `live_render`.
    case Projects.get_project_with_assignee(id) do
      nil ->
        {:ok,
         socket
         |> assign(not_found_assigns())
         |> put_flash(:error, gettext("Project not found."))
         |> WebHelpers.close_or_navigate(Paths.projects())}

      project ->
        # The :view gate. It was missing: this page relied on the admin
        # ROUTE being unreachable without the projects permission, which
        # held only while that permission also meant "administer every
        # project". Now a role can reach the module while belonging to
        # nothing, and group grants can let someone in, so the page has
        # to answer the question itself. It is also the root LV of every
        # embed, where core's admin on_mount never runs at all.
        #
        # Templates are exempt: they are library objects with no
        # membership rows, so gating them on :view would lock everyone
        # out. They stay behind the route's module permission as before.
        #
        # A refusal is deliberately shaped exactly like "not found" —
        # existence is itself information.
        if WebHelpers.template_or_viewable?(project, socket.assigns[:phoenix_kit_current_scope]) do
          if connected?(socket) do
            # Per-project topic covers assignment/dependency events for this
            # project; the tasks topic covers library-level task renames so
            # the visible assignment rows don't go stale.
            ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(project.uuid))
            ProjectsPubSub.subscribe(ProjectsPubSub.topic_tasks())
          end

          is_template = project.is_template

          lang = L10n.current_content_lang()

          wrapper_class = Map.get(session, "wrapper_class", @default_wrapper_class)

          # Which tab the page opens on, straight from the route's live_action
          # (`/:id/gantt` → `:gantt`, everything else → `:list`). Server-side
          # so a direct/bookmarked `/gantt` load renders the gantt before any JS.
          # Templates have no tabs/gantt (both are `not @is_template`), so a template
          # uuid reached via the `/:id/gantt` route falls back to the list —
          # otherwise both the list and the gantt would render hidden (blank page).
          # The hub gate map (@fx): tasks extension + per-project feature
          # flags, one resolved lookup for every render/event guard below.
          # Rebuilt on :project_features_changed / :project_modules_changed.
          # @fx_files is the second built-in extension's gate (its surface is
          # its own page — only the menu link renders here).
          fx = Features.gates(project)
          fx_files = Extensions.enabled?(project, "files")

          # Contributed extension tabs (the hub contract's `tabs`): rendered
          # as first-class view tabs via live_render with the embed-session
          # contract. Resolved once; recomputed on :project_modules_changed.
          ext_tabs =
            ext_tabs_for(project, is_template, socket.assigns[:phoenix_kit_current_scope])

          # Templates keep the Tasks pane alone — no Comments tab, whatever
          # the Discussions extension says.
          comments? =
            not is_template and comments_available?() and
              Extensions.enabled?(project, "discussions")

          active_tab =
            socket.assigns[:live_action]
            |> tab_for_action(Map.get(params, "tab"), is_template, ext_tabs)
            |> gate_tab(fx)
            |> gate_comments_tab(comments?)
            |> resolve_landing_tab(fx, ext_tabs, comments?)

          # Resolve the workflow-status list once (read-only — nothing is
          # provisioned or seeded here; an unset shared default simply yields
          # an empty list). `current_status` is derived from the same list so
          # we don't resolve twice.
          statuses_available = Statuses.available?()
          status_options = if statuses_available, do: Statuses.statuses_for(project), else: []

          current_status =
            Enum.find(status_options, &(&1.slug == project.current_status_slug))

          socket =
            socket
            |> assign(
              page_title: Project.localized_name(project, lang),
              # Trail: "Admin Panel / Projects / <parents…> / <name>" (a
              # template: "… / Projects / Templates / <name>") — the
              # in-content back-link + h1 row is gone; the site header
              # carries both the name and the way back. The List/Board/
              # Timeline/Calendar tabs are views of this one place and never
              # appear in it (see `Web.Crumbs`).
              page_section: gettext("Projects"),
              page_section_path: Paths.projects(),
              page_crumbs:
                Keyword.fetch!(
                  Crumbs.above_project(project, socket.assigns[:phoenix_kit_current_scope]),
                  :page_crumbs
                ),
              # The status picker + ⋮ sit in that header too, beside the name.
              page_toolbar: {__MODULE__, :header_toolbar},
              statuses_available: statuses_available,
              status_options: status_options,
              current_status: current_status,
              project: project,
              fx: fx,
              fx_files: fx_files,
              ext_tabs: ext_tabs,
              ext_mounted: ext_initial_mounted(active_tab),
              health: Health.get(project),
              health_modal_open: false,
              is_template: is_template,
              wrapper_class: wrapper_class,
              # Tab state. The tab bar renders in every context now (only
              # templates stay list-only); `router_mounted?` is kept as an
              # informational flag a few comments key off. URL sync is ON here —
              # this is the standalone admin page, which owns a real `/gantt` URL
              # to deep-link; embeds default it off (see the embed mount clause).
              # The gantt/calendar are lazy-mounted: each only `live_render`s once
              # its tab is first opened, then stays mounted so its own state
              # (zoom/expand, month navigation) survives switching back.
              router_mounted?: true,
              tab_url_sync?: true,
              active_tab: active_tab,
              gantt_mounted?: active_tab == :gantt,
              calendar_mounted?: active_tab == :calendar,
              editing_duration_uuid: nil,
              start_modal_open: false,
              start_form: to_form(%{"start_at" => default_start_at_local()}),
              # Comments drawer state. `comments_resource` is `nil` when
              # closed; a `%{type, uuid, title}` map when open. The
              # `CommentsComponent` is keyed on `{type, uuid}` so opening
              # different resources doesn't reuse stale state.
              comments_resource: nil,
              # Availability ∧ the per-project "discussions" bridge toggle.
              comments_enabled: comments?,
              # The task view the Tasks top tab reopens (the last one shown).
              task_view: (top_tab_of(active_tab) == :tasks && active_tab) || :list,
              project_comment_count: 0,
              assignment_comment_counts: %{},
              # Skeleton defaults overwritten by the load_* helpers below;
              # they keep the assigns coherent if either helper short-circuits.
              assignments: [],
              deps_by_assignment: %{},
              total_tasks: 0,
              done_tasks: 0,
              progress_pct: 0,
              schedule: nil,
              # Sub-project UI state (V127). `expanded_subprojects` holds the
              # linking-assignment uuids whose child task list is revealed;
              # `subproject_*` maps are keyed by linking-assignment uuid and
              # filled lazily (summaries in load_assignments, child tasks on
              # first expand).
              expanded_subprojects: MapSet.new(),
              list_status: "active",
              list_sort: :position,
              list_controls: ListControls.read(),
              list_controls?: false,
              pending_reviews: [],
              review_details: %{},
              review_open?: false,
              review_selected: nil,
              subproject_summaries: %{},
              subproject_child_tasks: %{},
              # Work-ledger state (Step 10): totals strip + per-task logged
              # chips, filled by load_ledger/1 below (nil/empty when the
              # `ledger` flag is off). `log_time_uuid` scopes the modal to a
              # task; nil logs against the project overall.
              ledger_totals: nil,
              ledger_minutes: %{},
              log_time_open: false,
              log_time_uuid: nil,
              assignment_labels: %{},
              invoice_ready?: false
            )
            |> WebHelpers.attach_open_embed_hook()

          {:ok,
           socket |> load_assignments() |> load_comment_counts() |> load_ledger() |> load_labels()}
        else
          {:ok,
           socket
           |> assign(not_found_assigns())
           |> put_flash(:error, gettext("Project not found."))
           |> WebHelpers.close_or_navigate(Paths.projects())}
        end
    end
  end

  # The assigns a mount needs to render nothing and redirect. Shared by the
  # missing-project branch and the refused-:view branch so the two stay
  # byte-identical — a refusal that renders differently from a 404 tells
  # the caller the project exists.
  defp not_found_assigns do
    [
      page_title: "",
      project: %Project{},
      fx: Features.default_gates(),
      fx_files: true,
      ext_tabs: [],
      ext_mounted: MapSet.new(),
      health: nil,
      health_modal_open: false,
      # The not-found branch still renders the page shell, so every assign
      # the template reads has to exist here too.
      pending_reviews: [],
      review_details: %{},
      review_open?: false,
      review_selected: nil,
      list_status: "active",
      list_sort: :position,
      list_controls: ListControls.read(),
      list_controls?: false,
      is_template: false,
      wrapper_class: @default_wrapper_class,
      router_mounted?: false,
      # Must be assigned: the tab bar now renders on `not @is_template`
      # (true here), so the render reads `@tab_url_sync?`. Router-mount
      # context → true (matches the success branch); the embedded wrapper
      # overrides it to the session value when this path is reached via an
      # off-router mount with an unknown id.
      tab_url_sync?: true,
      active_tab: :list,
      gantt_mounted?: false,
      calendar_mounted?: false,
      assignments: [],
      deps_by_assignment: %{},
      total_tasks: 0,
      done_tasks: 0,
      progress_pct: 0,
      schedule: nil,
      editing_duration_uuid: nil,
      start_modal_open: false,
      start_form: to_form(%{"start_at" => default_start_at_local()}),
      comments_resource: nil,
      comments_enabled: false,
      task_view: :list,
      project_comment_count: 0,
      assignment_comment_counts: %{},
      statuses_available: false,
      current_status: nil,
      status_options: [],
      expanded_subprojects: MapSet.new(),
      subproject_summaries: %{},
      subproject_child_tasks: %{},
      ledger_totals: nil,
      ledger_minutes: %{},
      log_time_open: false,
      log_time_uuid: nil,
      assignment_labels: %{},
      invoice_ready?: false
    ]
  end

  # ── PubSub reactivity ─────────────────────────────────────────
  # Catch-all handle_info avoids crashes on unexpected messages.

  @impl true
  def handle_info({:projects, event, _payload}, socket)
      when event in [
             :assignment_created,
             :assignment_updated,
             :assignment_deleted,
             :assignment_reordered,
             :dependency_added,
             :dependency_removed,
             # Task-library renames change displayed assignment titles.
             :task_updated,
             :task_deleted
           ] do
    {:noreply, socket |> load_assignments() |> load_labels()}
  end

  def handle_info({:projects, event, _payload}, socket)
      when event in [
             :project_updated,
             :project_completed,
             :project_reopened,
             :project_started,
             :project_status_changed,
             :project_archived,
             :project_unarchived
           ] do
    # Must re-preload the assignee: the render derefs @project.assigned_person.user
    # (assignee_label/1), so a plain get_project/1 here leaves it NotLoaded and the
    # re-render crashes when the project has an assignee.
    case Projects.get_project_with_assignee(socket.assigns.project.uuid) do
      nil ->
        {:noreply, socket}

      p ->
        {:noreply,
         socket
         |> assign(project: p, health: Health.get(p))
         |> refresh_status_state()
         |> load_assignments()}
    end
  end

  def handle_info({:projects, event, _payload}, socket)
      when event in [:project_features_changed, :project_modules_changed] do
    # The Modules & Features panel (this session or any other) changed the
    # hub configuration — rebuild the gate map and re-gate the active tab
    # (a live view_timeline/view_calendar turn-off must not leave the user
    # parked on a tab that no longer exists).
    # RELOAD the project first: flags live in settings["features"], and
    # resolving them from the in-memory struct reads the PRE-toggle map —
    # the dispatcher would keep accepting gated mutations on every open
    # page forever (panel R3-1, Grok). Extension enablement re-queries by
    # uuid either way; the flags need the fresh row.
    project =
      Projects.get_project_with_assignee(socket.assigns.project.uuid) ||
        socket.assigns.project

    fx = Features.gates(project)

    ext_tabs =
      ext_tabs_for(
        project,
        socket.assigns.is_template,
        socket.assigns[:phoenix_kit_current_scope]
      )

    # Re-gate the active tab: a gated-off view, an extension tab whose
    # extension was just disabled or a Comments tab that just lost
    # Discussions all fall to the landing tab — which, with tasks off, is
    # the first thing still on (never a pane the project no longer has).
    comments? =
      not socket.assigns.is_template and comments_available?() and
        Extensions.enabled?(project, "discussions")

    active =
      case gate_tab(socket.assigns.active_tab, fx) do
        "ext:" <> _ = id -> if Enum.any?(ext_tabs, &(&1.id == id)), do: id, else: :list
        :comments -> if comments?, do: :comments, else: :list
        tab -> tab
      end
      |> resolve_landing_tab(fx, ext_tabs, comments?)

    socket =
      socket
      |> assign(
        project: project,
        fx: fx,
        fx_files: Extensions.enabled?(project, "files"),
        ext_tabs: ext_tabs,
        comments_enabled: comments?
      )
      |> activate_tab(active)

    # Ledger visibility follows the flag: flipping it on mid-session must
    # populate the totals; flipping it off clears them.
    {:noreply, load_ledger(socket)}
  end

  def handle_info({:projects, :project_deleted, _payload}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("This project was deleted."))
     |> WebHelpers.close_or_navigate(Paths.projects())}
  end

  # `CommentsComponent` notifies its parent LV after every create /
  # delete so the button badges can refresh without an extra round
  # trip. We reload the full count map regardless of which resource
  # changed — both project and assignment counts cost a single
  # query each, and the message carries an `action` (`:created |
  # :deleted`) that we don't need to discriminate on here.
  def handle_info({:comments_updated, _payload}, socket) do
    {:noreply, load_comment_counts(socket)}
  end

  # Ledger writes — this session's or anyone's (the AI attribution seam
  # records through the same context) — refresh the effort totals.
  def handle_info({:projects, :work_logged, _payload}, socket) do
    {:noreply, load_ledger(socket)}
  end

  def handle_info({:projects, :project_labels_changed, _payload}, socket) do
    {:noreply, load_labels(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[ProjectShowLive] unexpected handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  # The FULL set stays on the socket: kanban, gantt and calendar all read
  # `@assignments` and every one of them needs the whole project. The list
  # tab reads `@visible_assignments`, which is this set through the current
  # lens — so filtering the list can never quietly shrink the other three.
  defp load_assignments(socket) do
    project_uuid = socket.assigns.project.uuid
    assignments = Projects.list_assignments(project_uuid)

    expanded = socket.assigns[:expanded_subprojects] || MapSet.new()

    expanded_subs =
      Enum.filter(
        assignments,
        &(Assignment.subproject?(&1) and MapSet.member?(expanded, &1.uuid))
      )

    # Parent deps PLUS deps for every expanded child project — the inset child
    # tasks render through the same `<.task_body>`, which reads
    # `deps_by_assignment` keyed by the (globally-unique) assignment uuid. Load
    # parent-only and a child task's dependency badges never render.
    deps_by_assignment =
      [project_uuid | Enum.map(expanded_subs, & &1.child_project_uuid)]
      |> Projects.list_all_dependencies()
      |> Enum.group_by(& &1.assignment_uuid)

    total = length(assignments)
    done = Enum.count(assignments, &(&1.status == "done"))
    # Rollup is the average of all assignments' `progress_pct` values
    # — a half-finished task contributes 50%, not 0%. Auto-completion
    # (`recompute_project_completion/1`) stays binary: a project only
    # auto-flags as completed when every assignment is `status: "done"`,
    # not when the rollup happens to hit 100% by other means.
    progress_sum = Enum.reduce(assignments, 0, &(&1.progress_pct + &2))
    schedule = calculate_schedule(socket.assigns.project, assignments)

    # Sub-project rollup display data (V127): one batched summary query over
    # all embedded child projects, keyed by the linking-assignment uuid so the
    # row can show the child's task count + progress. Expanded rows also get a
    # refreshed child task list so a change in the child reflects immediately.
    subproject_summaries = load_subproject_summaries(assignments)

    # One grouped read for every expanded child (it was one per child, on
    # every refresh) — the child's own descendants come along, unused here.
    child_assignments =
      Projects.assignments_by_project(Enum.map(expanded_subs, & &1.child_project_uuid))

    subproject_child_tasks =
      Map.new(expanded_subs, fn a ->
        {a.uuid, Map.get(child_assignments, a.child_project_uuid, [])}
      end)

    # Mirror `Projects.project_summaries/1`: an EMPTY sub-project (its child has
    # no assignments of its own yet) is neutral in the progress average — keep
    # it in `total` for the task-count display but drop it from the progress
    # denominator so it doesn't drag the project's % down before it holds any
    # work. Without this the header % here and the dashboard card disagree.
    empty_subs =
      Enum.count(assignments, fn a ->
        Assignment.subproject?(a) and empty_subproject?(Map.get(subproject_summaries, a.uuid))
      end)

    progress_total = max(total - empty_subs, 0)

    socket
    |> assign(
      assignments: assignments,
      deps_by_assignment: deps_by_assignment,
      total_tasks: total,
      done_tasks: done,
      progress_pct: if(progress_total > 0, do: round(progress_sum / progress_total), else: 0),
      schedule: schedule,
      subproject_summaries: subproject_summaries,
      subproject_child_tasks: subproject_child_tasks
    )
    |> assign_pending_reviews(project_uuid)
    |> apply_list_lens()
  end

  # ── The list lens ───────────────────────────────────────────────────
  #
  # Counts come from the FULL set and are always rendered, whatever the
  # lens hides. Hiding rows is not dishonest; hiding the number is. A dev
  # who opens a mature project and sees 47 active tasks beside a chip
  # reading "Done 900" understands the shape of it — which is precisely
  # what scrolling past 900 finished cards never told them.
  defp apply_list_lens(socket) do
    all = socket.assigns[:assignments] || []
    counts = assignment_counts(all)

    # The controls earn their row only when they can change what is on
    # screen (`ListControls`). Without them the list is the whole
    # project in manual order — the one arrangement drag-reordering
    # needs — whatever lens or sort a wider day may have left behind.
    controls? = ListControls.show?(socket.assigns[:list_controls] || ListControls.read(), counts)
    status = if controls?, do: socket.assigns[:list_status] || "active", else: "all"
    sort = if controls?, do: socket.assigns[:list_sort] || :position, else: :position

    visible =
      all
      |> Enum.filter(&matches_status?(&1, status))
      |> sort_list(sort)

    assign(socket,
      visible_assignments: visible,
      assignment_counts: counts,
      list_controls?: controls?,
      # Numbered against the WHOLE project, in its manual order — never
      # against the rows on screen. A counter over the visible set renumbers
      # the same task every time the lens moves, so "task 3" means one thing
      # under Active and another under All, which makes the number useless
      # for referring to anything. Under a filter the sequence shows gaps
      # (3, 7, 12) and that is the honest reading: you are looking at part
      # of a longer plan.
      assignment_numbers: assignment_numbers(all),
      # Dragging needs the MANUAL order on screen — under "Newest first" a
      # drop would mean nothing — but not the whole project: a drop made
      # under a lens is merged back into the full plan by
      # `merge_visible_order/2` (the visible rows take their new order in
      # the slots they already held; hidden rows keep theirs), so a
      # filtered list reorders like any list app's. The sequence rail is
      # the stricter one: it draws the schedule walk, and a slice of the
      # plan is not the walk — `list_whole?` keeps it to the All lens.
      list_manual?: sort == :position,
      list_whole?: status == "all"
    )
  end

  # A drop under a lens: the rows the user could see, in their new order,
  # folded back into the whole project's order. The visible rows keep the
  # SET of slots they occupied and take the new order within them; every
  # hidden row stays exactly where it was. A visible id the full order
  # does not know (a concurrent change) is dropped; the context's scope
  # check rejects anything that is not this project's anyway.
  defp merge_visible_order(full_ids, visible_new_order) do
    known = MapSet.new(full_ids)
    visible_new_order = Enum.filter(visible_new_order, &MapSet.member?(known, &1))
    visible_set = MapSet.new(visible_new_order)

    {merged, _rest} =
      Enum.map_reduce(full_ids, visible_new_order, fn id, queue ->
        if MapSet.member?(visible_set, id) do
          [next | rest] = queue
          {next, rest}
        else
          {id, queue}
        end
      end)

    merged
  end

  # `list_assignments/1` already returns position order, so the index here
  # IS the position rank — resolved once per load rather than per row.
  defp assignment_numbers(all) do
    all
    |> Enum.with_index(1)
    |> Map.new(fn {a, idx} -> {a.uuid, idx} end)
  end

  defp assign_pending_reviews(socket, project_uuid) do
    pending = Projects.list_pending_reviews(project_uuid)

    assign(socket,
      pending_reviews: pending,
      review_details: Portal.review_details_for(Enum.map(pending, & &1.uuid))
    )
  end

  defp review_detail(details, uuid),
    do: Map.get(details, uuid, %{images: [], submitted_by: nil})

  # Cards the board cannot place. `status` is validated on write, so these
  # are legacy or hand-edited rows — but filtering three known values meant
  # they appeared in NO column and vanished without a word.
  defp board_orphans(assignments),
    do: Enum.count(assignments, &(&1.status not in ["todo", "in_progress", "done"]))

  # From the FIELDS, never from `assignee_type/1` — that returns a
  # translated label ("Person"/"Team"/"Dept"), so matching on it would pick
  # the right icon in English and the fallback in every other language.
  # The board's columns. With the in-progress step off the middle column
  # goes — unless a row still sits there (legacy or flipped mid-flight),
  # so nothing ever disappears from the board.
  defp board_columns(fx, assignments) do
    middle? = fx.in_progress or Enum.any?(assignments, &(&1.status == "in_progress"))

    [{"todo", gettext("To do"), "border-t-warning"}] ++
      if(middle?, do: [{"in_progress", gettext("In progress"), "border-t-info"}], else: []) ++
      [{"done", gettext("Done"), "border-t-success"}]
  end

  @doc """
  The page's identity controls — the workflow-status picker and the ⋮ menu
  (Edit, Members, Files, Activity, Set health, Archive). On the standalone
  admin page core renders this in the site header next to the project's
  name (`page_toolbar: {__MODULE__, :header_toolbar}`, the LiveView's own
  assigns, events land here as usual); an embed has no site header, so its
  body renders the same component under its h1. Never both — the form id
  is unique either way.
  """
  def header_toolbar(assigns) do
    ~H"""
        <%!-- Inline workflow-status picker (the current value). The
             status-list *source* is chosen on the new/edit form (and the
             global default in Settings), not here. Hidden when no
             statuses exist for the project's list. --%>
        <form
          :if={@fx.statuses and @statuses_available and @status_options != []}
          id={"project-status-#{@project.uuid}"}
          phx-change="change_workflow_status"
          class="flex items-center"
        >
          <.select
            name="status_slug"
            value={@project.current_status_slug}
            options={Enum.map(@status_options, &{&1.label, &1.slug})}
            prompt={gettext("No status")}
            class="select-sm"
          />
        </form>
        <%!-- Edit + (Un)archive go into a kebab dropdown to match the
             per-row action pattern used elsewhere in the module. --%>
        <.table_row_menu id={"project-header-menu-#{@project.uuid}"}>
          <.smart_menu_link
            navigate={if @is_template, do: Paths.edit_template(@project.uuid), else: Paths.edit_project(@project.uuid)}
            emit={
              if @is_template,
                do:
                  {PhoenixKitProjects.Web.TemplateFormLive,
                   %{"live_action" => "edit", "id" => @project.uuid}},
                else:
                  {PhoenixKitProjects.Web.ProjectFormLive,
                   %{"live_action" => "edit", "id" => @project.uuid}}
            }
            embed_mode={@embed_mode}
            icon="hero-pencil"
            label={gettext("Edit")}
          />
          <.smart_menu_link
            :if={not @is_template}
            navigate={Paths.members(@project.uuid)}
            emit={{PhoenixKitProjects.Web.ProjectMembersLive, %{"id" => @project.uuid}}}
            embed_mode={@embed_mode}
            popup={false}
            icon="hero-users"
            label={gettext("Members")}
          />
          <.smart_menu_link
            :if={not @is_template and @fx_files}
            navigate={Paths.files(@project.uuid)}
            emit={{PhoenixKitProjects.Web.ProjectFilesLive, %{"id" => @project.uuid}}}
            embed_mode={@embed_mode}
            popup={false}
            icon="hero-paper-clip"
            label={gettext("Files")}
          />
          <.smart_menu_link
            :if={not @is_template}
            navigate={Paths.activity(@project.uuid)}
            emit={{PhoenixKitProjects.Web.ProjectActivityLive, %{"id" => @project.uuid}}}
            embed_mode={@embed_mode}
            popup={false}
            icon="hero-clock"
            label={gettext("Activity")}
          />
          <%!-- Health is a judgment about whether the project is on
               track to FINISH. A checklist has no finish, so the
               question has no meaning — same reason its start bar is
               gone. --%>
          <.table_row_menu_button
            :if={not @is_template and @fx.lifecycle}
            phx-click="open_health_modal"
            icon="hero-heart"
            label={gettext("Set health")}
          />
          <%= if not @is_template do %>
            <.table_row_menu_divider />
            <%= if @project.archived_at do %>
              <.table_row_menu_button
                phx-click="unarchive_project"
                phx-disable-with={gettext("Unarchiving…")}
                icon="hero-arrow-uturn-left"
                label={gettext("Unarchive")}
              />
            <% else %>
              <.table_row_menu_button
                phx-click="archive_project"
                phx-disable-with={gettext("Archiving…")}
                data-confirm={gettext("Archive this project? It will be hidden from the main lists but kept in the database.")}
                icon="hero-archive-box"
                label={gettext("Archive")}
              />
            <% end %>
          <% end %>
        </.table_row_menu>
    """
  end

  defp assignee_icon(%{assigned_team_uuid: uuid}) when is_binary(uuid), do: "hero-users"

  defp assignee_icon(%{assigned_department_uuid: uuid}) when is_binary(uuid),
    do: "hero-building-office"

  defp assignee_icon(_assignment), do: "hero-user"

  defp clamp_pct(pct) when is_integer(pct), do: pct |> max(0) |> min(100)
  defp clamp_pct(_pct), do: 0

  defp matches_status?(_a, "all"), do: true
  # "Not finished", NOT "one of the two statuses I happened to think of".
  # A task carrying an out-of-band status — and this codebase deliberately
  # renders a fallback badge for exactly that — fell through every bucket
  # and disappeared from the default view entirely. A lens that hides rows
  # has to fail toward showing too many.
  defp matches_status?(a, "active"), do: a.status != "done"
  defp matches_status?(a, "done"), do: a.status == "done"
  defp matches_status?(_a, _status), do: true

  defp sort_list(assignments, :position), do: assignments

  defp sort_list(assignments, :newest),
    do: Enum.sort_by(assignments, & &1.inserted_at, {:desc, DateTime})

  defp sort_list(assignments, :recent),
    do: Enum.sort_by(assignments, & &1.updated_at, {:desc, DateTime})

  defp sort_list(assignments, _), do: assignments

  defp assignment_counts(all) do
    %{
      total: length(all),
      active: Enum.count(all, &(&1.status != "done")),
      done: Enum.count(all, &(&1.status == "done"))
    }
  end

  # `%{linking_assignment_uuid => child_summary}` for every sub-project row.
  defp load_subproject_summaries(assignments) do
    subs = Enum.filter(assignments, &Assignment.subproject?/1)

    children = Enum.map(subs, & &1.child_project) |> Enum.reject(&is_nil/1)

    summaries_by_child =
      children
      |> Projects.project_summaries()
      |> Map.new(fn s -> {s.project.uuid, s} end)

    Map.new(subs, fn a -> {a.uuid, Map.get(summaries_by_child, a.child_project_uuid)} end)
  end

  # A sub-project whose child has no assignments of its own — `total == 0` in
  # the child's summary (matches `project_summaries/1`'s "empty" definition). A
  # missing summary (nil) is treated as empty too: no child rows to summarize.
  defp empty_subproject?(%{total: 0}), do: true
  defp empty_subproject?(nil), do: true
  defp empty_subproject?(_), do: false

  # Recomputes the workflow-status list + current selection from the
  # (possibly just-reloaded) project. Re-resolves against the live catalog
  # pre-start and the cemented local rows post-start, so a `:project_started`
  # broadcast naturally flips the source. No-op when entities is unavailable.
  defp refresh_status_state(socket) do
    if socket.assigns.statuses_available do
      project = socket.assigns.project
      options = Statuses.statuses_for(project)
      current = Enum.find(options, &(&1.slug == project.current_status_slug))
      assign(socket, status_options: options, current_status: current)
    else
      socket
    end
  end

  # Updates the assignment, logs the activity on success, and returns a tuple
  # `{:ok, socket}` for the maybe_sync_and_reload pipeline.
  # The `complete`/`start_task`/`reopen`/`update_progress` handlers go
  # through the server-trusted `update_assignment_status/2` because their
  # attrs include `completed_by_uuid` / `completed_at`, which the
  # form-safe `update_assignment_form/2` intentionally drops.
  defp update_assignment_with_activity(socket, a, attrs, action_name, opts) do
    case Projects.update_assignment_status(a, attrs) do
      {:ok, _} ->
        Activity.log(action_name,
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: a.uuid,
          # The assignee is the affected user — with it, core's bridge
          # delivers "your task was completed/reopened/…" (Step 7).
          target_uuid: Activity.assignee_target_uuid(a),
          metadata: Keyword.get(opts, :metadata, %{})
        )

        recompute_owning_subproject(socket, a)
        {:ok, socket}

      {:error, cs} ->
        Activity.log_failed(action_name,
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: a.uuid,
          metadata: Keyword.get(opts, :metadata, %{})
        )

        {:error, socket, error_summary(cs, gettext("Could not update task."))}
    end
  end

  defp maybe_sync_and_reload({:ok, socket}) do
    {:noreply, socket |> sync_project_completion() |> load_assignments()}
  end

  defp maybe_sync_and_reload({:error, socket, msg}) do
    {:noreply, put_flash(socket, :error, msg)}
  end

  # Translates Ecto validator messages through the gettext "errors"
  # domain — Ecto emits English literals like `"is invalid"` /
  # `"must be greater than 0"` from `validate_*` plus interpolation
  # bindings; `Gettext.dngettext/6` is the canonical translator for
  # those (matches the Phoenix scaffolding pattern). Without this,
  # the inline error summary (e.g. on a failed `complete` from a
  # validation-rejected status transition) renders English regardless
  # of the user's locale — Phase 1 PR #1 review item #15, deferred
  # then to Phase 2 C3 + closed in this re-validation batch.
  #
  # Named `translate_validator_error/1` (not `translate_error/1`) to
  # avoid shadowing `PhoenixKitWeb.Components.Core.Input.translate_error/1`
  # which is auto-imported by `use PhoenixKitWeb, :live_view`.
  defp error_summary(%Ecto.Changeset{errors: errors}, fallback) do
    case errors do
      [] ->
        fallback

      errs ->
        Enum.map_join(errs, ", ", fn {k, {msg, opts}} ->
          "#{humanize_field(k)}: #{translate_validator_error({msg, opts})}"
        end)
    end
  end

  # Renders an Ecto field name like `:estimated_duration` as
  # `"Estimated duration"` for the cross-field flash summary. The
  # per-field input component already humanizes its own label, so this
  # only matters for the multi-error fallback.
  defp humanize_field(field) do
    field
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp translate_validator_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(PhoenixKitWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(PhoenixKitWeb.Gettext, "errors", msg, opts)
    end
  end

  # When a mutated assignment belongs to an embedded sub-project (its row is
  # rendered inset in the expand panel, V127), recompute that child's project so
  # the rollup climbs to the shown project's linking row. A no-op for normal
  # tasks (`sync_project_completion/1` already recomputes the shown project).
  defp recompute_owning_subproject(socket, %{project_uuid: pid}) do
    if pid != socket.assigns.project.uuid do
      Projects.recompute_project_completion(pid)
    end

    :ok
  end

  defp sync_project_completion(socket) do
    case Projects.recompute_project_completion(socket.assigns.project.uuid) do
      {:completed, project} ->
        Activity.log("projects.project_completed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        socket
        |> assign(project: project)
        |> put_flash(:info, gettext("🎉 All tasks done — project completed!"))

      {:reopened, project} ->
        Activity.log("projects.project_reopened",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        assign(socket, project: project)

      {:unchanged, _} ->
        socket

      _ ->
        socket
    end
  end

  # Looks up an assignment and verifies it belongs to the project the
  # user is currently viewing. Prevents an admin on project A from
  # mutating assignments in project B by crafting event params.
  # The single task-card row, shared by the main timeline and the inset
  # sub-project task lists (V127) — "no reason to make them different".
  # `@draggable` gates the sortable wiring + drag handle (off for inset child
  # tasks, which reorder on their own page). Child-task events work because
  # `scoped_assignment/2` accepts any displayed assignment and
  # `update_assignment_with_activity/5` recomputes the assignment's own project.
  attr(:a, :map, required: true)
  # The viewer, for resolving @/# mentions in a task's description. Optional
  # so a caller that forgets it degrades to "sees nothing private" rather
  # than crashing.
  attr(:scope, :any, default: nil)
  attr(:draggable, :boolean, default: true)
  attr(:is_template, :boolean, required: true)
  attr(:project, :map, required: true)
  # The hub gate map (@fx) — chips inside the card are feature-gated.
  attr(:fx, :map, required: true)
  attr(:embed_mode, :atom, required: true)
  attr(:editing_duration_uuid, :string, default: nil)
  attr(:comments_enabled, :boolean, default: false)
  attr(:assignment_comment_counts, :map, default: %{})
  attr(:deps_by_assignment, :map, default: %{})
  attr(:ledger_minutes, :map, default: %{})
  attr(:assignment_labels, :map, default: %{})

  defp task_body(assigns) do
    ~H"""
    <div class="card-body py-3 px-4 gap-2">
      <%!-- Title row --%>
          <div class="flex items-center justify-between gap-2">
            <div class="flex items-center gap-2 min-w-0">
              <span
                :if={@draggable}
                class="pk-drag-handle cursor-grab text-base-content/40 hover:text-base-content shrink-0"
                title={gettext("Drag to reorder")}
              >
                <.icon name="hero-bars-3" class="w-4 h-4" />
              </span>
              <.assignment_status_badge :if={not @is_template} status={@a.status} />
              <%!-- Title links to the same edit form as the row menu's
                   Edit — clicking a name anywhere should go somewhere. --%>
              <.smart_link
                navigate={Paths.edit_assignment(@a.project_uuid, @a.uuid)}
                emit={
                  {PhoenixKitProjects.Web.AssignmentFormLive,
                   %{"live_action" => "edit", "project_id" => @a.project_uuid, "id" => @a.uuid}}
                }
                embed_mode={@embed_mode}
                class="font-medium truncate min-w-0 link link-hover"
              >
                {TaskSchema.localized_title(@a.task, L10n.current_content_lang())}
              </.smart_link>
            </div>

            <div class="flex items-center gap-1 shrink-0">
              <%= if not @is_template do %>
                <%= cond do %>
                  <% @a.status == "todo" and @fx.in_progress -> %>
                    <button phx-click="start_task" phx-value-uuid={@a.uuid} phx-disable-with={gettext("Starting…")} class="btn btn-warning btn-xs">
                      {gettext("Start")}
                    </button>
                  <% @a.status in ["todo", "in_progress"] -> %>
                    <button phx-click="complete" phx-value-uuid={@a.uuid} phx-disable-with={gettext("Saving…")} class="btn btn-success btn-xs">
                      <.icon name="hero-check" class="w-3.5 h-3.5" /> {gettext("Done")}
                    </button>
                  <% @a.status == "done" -> %>
                    <button phx-click="reopen" phx-value-uuid={@a.uuid} phx-disable-with={gettext("Reopening…")} class="btn btn-ghost btn-xs">
                      {gettext("Reopen")}
                    </button>
                  <% true -> %>
                    <%!-- A status outside the vocabulary. The changeset
                         refuses to write one, so this is legacy or
                         hand-edited data — and until now it raised
                         CondClauseError and took the whole project page
                         down rather than the one row. The status badge
                         already has a fallback; the actions need one too,
                         and there is no honest action to offer for a state
                         we do not model. --%>
                <% end %>
              <% end %>

              <% a_comment_count = Map.get(@assignment_comment_counts, @a.uuid, 0) %>
              <button
                :if={@comments_enabled and not @is_template}
                type="button"
                phx-click="open_comments"
                phx-value-type="assignment"
                phx-value-uuid={@a.uuid}
                phx-value-title={TaskSchema.localized_title(@a.task, L10n.current_content_lang())}
                class="btn btn-ghost btn-xs gap-1"
                title={gettext("Open comments")}
              >
                <.icon name="hero-chat-bubble-left" class="w-3.5 h-3.5" />
                <span :if={a_comment_count > 0} class="badge badge-xs badge-primary">{a_comment_count}</span>
              </button>
              <.table_row_menu id={"assignment-menu-#{@a.uuid}"}>
                <.smart_menu_link
                  navigate={Paths.edit_assignment(@a.project_uuid, @a.uuid)}
                  emit={{PhoenixKitProjects.Web.AssignmentFormLive, %{"live_action" => "edit", "project_id" => @a.project_uuid, "id" => @a.uuid}}}
                  embed_mode={@embed_mode}
                  icon="hero-pencil"
                  label={gettext("Edit")}
                />
                <.table_row_menu_divider />
                <.table_row_menu_button
                  phx-click="remove_assignment"
                  phx-value-uuid={@a.uuid}
                  phx-disable-with={gettext("Removing…")}
                  data-confirm={gettext("Remove \"%{title}\"?", title: TaskSchema.localized_title(@a.task, L10n.current_content_lang()))}
                  icon="hero-trash"
                  label={gettext("Remove")}
                  variant="error"
                />
              </.table_row_menu>
            </div>
          </div>

          <%!-- Description --%>
          <% lang = L10n.current_content_lang() %>
          <% shown_desc = Assignment.localized_description(@a, lang) || TaskSchema.localized_description(@a.task, lang) %>
          <div :if={shown_desc} class="text-xs text-base-content/60">
            <.mention_text text={shown_desc} scope={@scope} />
          </div>

          <%!-- Meta row: duration, assignee, completed by. Each chip is
               feature-gated via @fx (Step 4 enforcement threading). --%>
          <div class="flex flex-wrap items-center gap-2 text-xs">
            <%= if @fx.estimates and @editing_duration_uuid == @a.uuid do %>
              <% prefill_dur = @a.estimated_duration || @a.task.estimated_duration %>
              <% prefill_unit = @a.estimated_duration_unit || @a.task.estimated_duration_unit || "hours" %>
              <form phx-submit="save_duration" class="flex items-center gap-1">
                <input type="hidden" name="uuid" value={@a.uuid} />
                <input type="number" name="estimated_duration" value={prefill_dur} class="input input-xs w-16" min="1" />
                <.select name="estimated_duration_unit" value={prefill_unit} options={duration_unit_options()} class="select-xs w-auto" />
                <button type="submit" phx-disable-with={gettext("Saving…")} class="btn btn-success btn-xs">
                  <.icon name="hero-check" class="w-3 h-3" />
                </button>
                <button type="button" phx-click="cancel_edit_duration" class="btn btn-ghost btn-xs">
                  <.icon name="hero-x-mark" class="w-3 h-3" />
                </button>
              </form>
            <% else %>
              <% dur = format_duration(@a) %>
              <button
                :if={@fx.estimates}
                phx-click="edit_duration"
                phx-value-uuid={@a.uuid}
                class={[
                  "badge badge-sm gap-1 cursor-pointer transition-colors",
                  dur != "—" && "badge-outline hover:bg-primary hover:text-primary-content hover:border-primary",
                  dur == "—" && "badge-ghost hover:bg-base-300"
                ]}
              >
                <.icon name="hero-clock" class="w-3 h-3" />
                {if dur != "—", do: dur, else: gettext("Set duration")}
              </button>
            <% end %>

            <% logged = Map.get(@ledger_minutes, @a.uuid, 0) %>
            <button
              :if={@fx.ledger and not @is_template}
              phx-click="open_log_time"
              phx-value-uuid={@a.uuid}
              title={gettext("Log time on this task")}
              class={[
                "badge badge-sm gap-1 cursor-pointer transition-colors",
                logged > 0 &&
                  "badge-outline hover:bg-primary hover:text-primary-content hover:border-primary",
                logged == 0 && "badge-ghost hover:bg-base-300"
              ]}
            >
              <.icon name="hero-play-circle" class="w-3 h-3" />
              {if logged > 0, do: format_minutes(logged), else: gettext("Log time")}
            </button>

            <% atype = assignee_type(@a) %>
            <span :if={@fx.assignees and atype} class="badge badge-outline badge-sm gap-1">
              <.icon name="hero-user" class="w-3 h-3" /> {atype}: {assignee_label(@a)}
            </span>

            <%!-- Priority: only non-normal wears a badge (calm cards). --%>
            <span
              :if={@fx.priorities and @a.priority != "normal"}
              class={["badge badge-sm gap-1", priority_class(@a.priority)]}
            >
              <.icon name="hero-flag" class="w-3 h-3" /> {priority_label(@a.priority)}
            </span>

            <span
              :for={label <- Map.get(@assignment_labels, @a.uuid, [])}
              :if={@fx.labels}
              class={["badge badge-sm", label.color]}
            >
              {label.name}
            </span>

            <% weekends? = task_counts_weekends?(@a, @project) %>
            <span
              :if={@fx.scheduling}
              class={"badge badge-sm gap-1 #{if weekends?, do: "badge-info badge-outline", else: "badge-ghost"}"}
            >
              <%= if weekends? do %>
                <.icon name="hero-calendar" class="w-3 h-3" /> {gettext("incl. weekends")}
              <% else %>
                {gettext("weekdays only")}
              <% end %>
            </span>

            <%= if @fx.progress and not @is_template do %>
              <%= if @a.track_progress do %>
                <.form for={%{}} phx-change="update_progress" class="flex items-center gap-1">
                  <input type="hidden" name="uuid" value={@a.uuid} />
                  <input type="range" name="progress_pct" value={@a.progress_pct} min="0" max="100" step="5" phx-debounce="300" class="range range-xs range-primary w-20" />
                  <span class="text-xs text-base-content/60 w-8">{@a.progress_pct}%</span>
                  <button type="button" phx-click="toggle_tracking" phx-value-uuid={@a.uuid} phx-disable-with={gettext("Saving…")} title={gettext("Disable percentage tracking")} class="btn btn-ghost btn-xs btn-circle">
                    <.icon name="hero-x-mark" class="w-3 h-3" />
                  </button>
                </.form>
              <% else %>
                <button type="button" phx-click="toggle_tracking" phx-value-uuid={@a.uuid} phx-disable-with={gettext("Saving…")} class="badge badge-ghost badge-sm gap-1 cursor-pointer hover:badge-primary" title={gettext("Track progress as a percentage")}>
                  <.icon name="hero-chart-bar" class="w-3 h-3" /> {gettext("Track %")}
                </button>
              <% end %>
            <% end %>

            <span :if={@a.completed_by} class="badge badge-success badge-sm gap-1">
              <.icon name="hero-check-circle" class="w-3 h-3" />
              {@a.completed_by.email}<%= if @a.completed_at do %>
                · {L10n.format_month_day_time(@a.completed_at)}
              <% end %>
            </span>
          </div>

          <%!-- Dependencies --%>
          <% deps = Map.get(@deps_by_assignment, @a.uuid, []) %>
          <div :if={@fx.dependencies and deps != []} class="flex flex-wrap gap-1 mt-1">
            <%= for dep <- deps do %>
              <span class="badge badge-outline badge-xs gap-1">
                <.icon name="hero-arrow-right-circle" class="w-3 h-3" />
                {gettext("depends on:")} {Assignment.label(dep.depends_on, L10n.current_content_lang())}
                <button phx-click="remove_dependency" phx-value-assignment={@a.uuid} phx-value-depends_on={dep.depends_on_uuid} phx-disable-with={gettext("Removing…")} class="hover:text-error">
                  <.icon name="hero-x-mark" class="w-3 h-3" />
                </button>
              </span>
            <% end %>
          </div>
        </div>
    """
  end

  # Accepts any assignment currently displayed on the page: one belonging to the
  # shown project, or a task inside an expanded sub-project (V127). Child-task
  # rows render the same `task_card` and their events flow through here.
  defp scoped_assignment(socket, uuid) do
    case Projects.get_assignment(uuid) do
      %{project_uuid: pid} = a when pid == socket.assigns.project.uuid ->
        a

      %{uuid: id} = a ->
        if displayed_child_task?(socket, id), do: a, else: nil

      _ ->
        nil
    end
  end

  defp displayed_child_task?(socket, uuid) do
    socket.assigns
    |> Map.get(:subproject_child_tasks, %{})
    |> Map.values()
    |> Enum.any?(fn tasks -> Enum.any?(tasks, &(&1.uuid == uuid)) end)
  end

  # ── Events ──────────────────────────────────────────────────────

  # Switch a tab — top-level or task view. Instant (an assign flip, no
  # navigation) and the nested LVs stay mounted, so the gantt's zoom/expand
  # and the calendar's month navigation survive. Each nested LV is
  # lazy-mounted the first time its tab opens and never unmounted. The URL
  # follows on its own through the strip's `data-url` + PkUrlMirror (router
  # mounts only) — no server push, nothing an embed can be steered into.
  # The target is VALIDATED against the feature map / the contributed tab
  # list, so a forged event can't open a tab the project doesn't have.
  #
  # ── Hub feature gating (Step 4 enforcement threading) ─────────────
  #
  # Every mutating event that belongs to a per-project-toggleable feature
  # routes through ONE fail-closed interceptor: event → owning gate in
  # @gated_events, checked against the resolved @fx map, refused with a
  # flash when off. The real handlers are `gated_handle_event/3` — a
  # forged client event can't reach them around the gate. UI hiding is
  # the courtesy; THIS is the enforcement.
  @gated_events %{
    "complete" => :tasks,
    # Owned by the in-progress flag (which itself needs the tasks
    # extension): with the step off, Start is neither shown nor accepted.
    "start_task" => :in_progress,
    "reopen" => :tasks,
    "remove_assignment" => :tasks,
    "reorder_assignments" => :tasks,
    "review_submission" => :tasks,
    "board_move" => :view_board,
    "open_review" => :tasks,
    "close_review" => :tasks,
    "edit_duration" => :estimates,
    "save_duration" => :estimates,
    "update_progress" => :progress,
    "toggle_tracking" => :progress,
    "remove_dependency" => :dependencies,
    "change_workflow_status" => :statuses,
    "detach_subproject" => :subprojects,
    "open_health_modal" => :lifecycle,
    "close_health_modal" => :lifecycle,
    "save_health" => :lifecycle,
    "open_start_modal" => :lifecycle,
    "close_start_modal" => :lifecycle,
    "confirm_start_project" => :lifecycle,
    "open_log_time" => :ledger,
    "close_log_time" => :ledger,
    "save_work_entry" => :ledger,
    "generate_invoice" => :ledger
  }

  # ── Hub permission gating ────────────────────────────────────────
  #
  # @gated_events above answers "is this feature ON for this project".
  # It says nothing about "may THIS person do it" — every mutation below
  # used to run for anyone who could open the page, which made the
  # project's own "who can do what" floors a UI-only decoration and left
  # archiving, an owner-only action, with no check whatsoever.
  #
  # Same shape as the feature gate deliberately: one table, one
  # interceptor, fail-closed. A handler that forgets to check is the
  # failure mode being designed out, so the check cannot live in the
  # handlers.
  #
  # Events NOT listed here are reads, UI state (tabs, modals, filters)
  # or already guard themselves with a record — see :log_time below.
  @event_actions %{
    "complete" => :update_status,
    "start_task" => :update_status,
    "reopen" => :update_status,
    "change_workflow_status" => :update_status,
    "update_progress" => :update_status,
    "toggle_tracking" => :update_status,
    "remove_assignment" => :delete_tasks,
    "reorder_assignments" => :edit_tasks,
    # Adding a task through the composer is the same act as the full
    # add-task page — same floor.
    # Placing a task in the plan is the same class of decision as
    # reordering one — it changes where the work sits, not what it is.
    "review_submission" => :edit_tasks,
    # Dragging a card between columns IS a status change, so it answers to
    # the same authorization as the buttons that do it — including the rule
    # that an assignee may move their own task.
    "board_move" => :update_status,
    "save_duration" => :edit_tasks,
    "remove_dependency" => :edit_tasks,
    "detach_subproject" => :edit_tasks,
    "archive_project" => :archive_project,
    "unarchive_project" => :archive_project,
    # Starting is a container-level act, not work: it stamps `started_at`,
    # cements the status catalog into local rows and switches the project's
    # derived state for everyone. It sat in @gated_events with no entry here,
    # so the lifecycle FLAG was the only thing between a viewer and starting
    # somebody else's project. Same floor as archiving — the other
    # irreversible thing that happens to the container rather than to a task.
    "confirm_start_project" => :edit_settings
  }

  # Task-scoped events carry the task's uuid, and the task is what makes
  # a relationship grant work: the person a task is assigned to may move
  # their own task even when the floor is higher. Resolving the record
  # here (rather than passing nil) is what keeps "assignees can update
  # their own status" true through the interceptor.
  @record_param_events ~w(complete start_task reopen change_workflow_status
                          update_progress toggle_tracking remove_assignment save_duration)

  @impl true
  def handle_event(event, params, socket) do
    case Map.get(@gated_events, event) do
      nil ->
        authorized_handle_event(event, params, socket)

      gate ->
        if socket.assigns.fx[gate] do
          authorized_handle_event(event, params, socket)
        else
          {:noreply,
           put_flash(socket, :error, gettext("This feature is turned off for this project."))}
        end
    end
  end

  defp authorized_handle_event(event, params, socket) do
    case Map.get(@event_actions, event) do
      nil ->
        gated_handle_event(event, params, socket)

      action ->
        if Authz.can?(
             socket.assigns[:phoenix_kit_current_scope],
             socket.assigns.project,
             action,
             authz_record(event, params, socket)
           ) do
          gated_handle_event(event, params, socket)
        else
          {:noreply,
           put_flash(socket, :error, gettext("You don't have permission to do that here."))}
        end
    end
  end

  defp authz_record(event, %{"uuid" => uuid}, socket) when is_binary(uuid) do
    if event in @record_param_events do
      Enum.find(socket.assigns[:assignments] || [], &(&1.uuid == uuid))
    end
  end

  defp authz_record("board_move", %{"moved_id" => uuid}, socket) when is_binary(uuid) do
    Enum.find(socket.assigns[:assignments] || [], &(&1.uuid == uuid))
  end

  defp authz_record(_event, _params, _socket), do: nil

  # Honour the drop position without ever renumbering from what the client
  # could see.
  #
  # The column's `ordered_ids` is a PARTIAL list, so writing it as positions
  # would shove every card in the other columns to the end of the plan. Only
  # ONE thing is taken from it — which card the moved one now sits before —
  # and the new order is then rebuilt from the server's complete list. Every
  # card the client never saw keeps its relative place; exactly one moves.
  defp reposition_from_drop(socket, uuid, ordered_ids) when is_list(ordered_ids) do
    project_uuid = socket.assigns.project.uuid
    all = Enum.map(socket.assigns[:assignments] || [], & &1.uuid)

    with idx when is_integer(idx) <- Enum.find_index(ordered_ids, &(&1 == uuid)),
         rest <- Enum.reject(all, &(&1 == uuid)),
         true <- uuid in all do
      # The card it was dropped ABOVE. Looked up in the server's own list,
      # so a uuid the client invented simply is not found and the move
      # falls through to "leave the order alone".
      anchor = ordered_ids |> Enum.drop(idx + 1) |> Enum.find(&(&1 in rest))

      reordered =
        case anchor && Enum.find_index(rest, &(&1 == anchor)) do
          nil -> rest ++ [uuid]
          at -> List.insert_at(rest, at, uuid)
        end

      Projects.reorder_assignments(project_uuid, reordered,
        actor_uuid: Activity.actor_uuid(socket),
        broadcast: false
      )
    else
      _ -> :ok
    end
  end

  defp reposition_from_drop(_socket, _uuid, _ordered_ids), do: :ok

  defp delegate_board_move(socket, "todo", uuid),
    do: gated_handle_event("reopen", %{"uuid" => uuid}, socket)

  defp delegate_board_move(socket, "in_progress", uuid),
    do: gated_handle_event("start_task", %{"uuid" => uuid}, socket)

  defp delegate_board_move(socket, "done", uuid),
    do: gated_handle_event("complete", %{"uuid" => uuid}, socket)

  # Lens changes are READS — they narrow what is drawn and write nothing —
  # so they are deliberately absent from @gated_events and @event_actions.
  # Whoever may see the list may narrow it.
  #
  # Every value is whitelisted in the guard rather than trusted: these
  # reach a comparison and an atom, and `String.to_existing_atom/1` on
  # unfiltered input is how a client picks the atom table apart.
  # A card dropped into another column. Only the STATUS is written.
  #
  # `ordered_ids` arrives with it and is ignored: a column holds a partial
  # view of the project, and renumbering `position` from it would shove
  # every card the client could not see to the end of the plan. Ignoring it
  # makes that corruption structurally impossible here rather than
  # something a future filter could re-enable.
  #
  # `fromStatus` is ignored too — it is the client's account of where the
  # card came from, and the server already knows.
  defp gated_handle_event(
         "board_move",
         %{"moved_id" => uuid, "status" => status} = params,
         socket
       )
       when status in ["todo", "in_progress", "done"] do
    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      assignment ->
        # Status first, through the very handlers the buttons use rather
        # than a naked `status` write: completing also sets progress to
        # 100, the actor and the timestamp; reopening clears all three.
        {:noreply, socket} =
          if assignment.status == status do
            {:noreply, socket}
          else
            delegate_board_move(socket, status, uuid)
          end

        # Then WHERE it was dropped. The card landing somewhere other than
        # where it was let go reads as a bug, whatever the data model says.
        reposition_from_drop(socket, uuid, params["ordered_ids"])

        {:noreply,
         socket
         |> push_event("sortable:flash", %{uuid: uuid, status: "ok"})
         |> load_assignments()}
    end
  end

  # An out-of-vocabulary destination, or a payload missing its pieces. The
  # columns can only emit the three, so this is a forged event: reload so
  # the optimistic DOM move is undone.
  defp gated_handle_event("board_move", _params, socket) do
    {:noreply, load_assignments(socket)}
  end

  defp gated_handle_event("open_review", _params, socket) do
    # Opens on the first one already expanded. With a single submission
    # waiting — the common case — that removes a click that told nobody
    # anything.
    first = socket.assigns[:pending_reviews] |> List.first() |> then(&(&1 && &1.uuid))
    {:noreply, assign(socket, review_open?: true, review_selected: first)}
  end

  defp gated_handle_event("select_review", %{"uuid" => uuid}, socket) do
    # Toggle: clicking the open one closes it, so the dialog can be read
    # back down to a list without reaching for the chevron again.
    selected = if socket.assigns[:review_selected] == uuid, do: nil, else: uuid
    {:noreply, assign(socket, review_selected: selected)}
  end

  defp gated_handle_event("close_review", _params, socket) do
    {:noreply, assign(socket, review_open?: false)}
  end

  defp gated_handle_event("review_submission", %{"uuid" => uuid, "decision" => decision}, socket)
       when decision in ["accepted", "rejected"] do
    # Scoped to THIS project's queue rather than looked up by uuid alone:
    # the uuid arrives from the client, and `list_assignments/1` no longer
    # contains pending rows, so `scoped_assignment/2` cannot vouch for it.
    pending = socket.assigns[:pending_reviews] || []

    if Enum.any?(pending, &(&1.uuid == uuid)) do
      Projects.review_assignment(uuid, String.to_existing_atom(decision),
        actor_uuid: Activity.actor_uuid(socket)
      )

      socket = load_assignments(socket)

      # Close on the last one rather than leaving an empty dialog open.
      {:noreply, assign(socket, review_open?: socket.assigns.pending_reviews != [])}
    else
      {:noreply, socket}
    end
  end

  defp gated_handle_event("list_filter_status", %{"tab" => status}, socket)
       when status in ["active", "done", "all"] do
    {:noreply, socket |> assign(list_status: status) |> apply_list_lens()}
  end

  defp gated_handle_event("list_sort", %{"sort" => sort}, socket)
       when sort in ["position", "newest", "recent"] do
    {:noreply,
     socket
     |> assign(list_sort: String.to_existing_atom(sort))
     |> apply_list_lens()}
  end

  defp gated_handle_event("switch_tab", %{"tab" => tab}, socket) do
    # The URL follows on its own: the page carries the canonical address
    # of the active tab in `data-url` and core's PkUrlMirror hook replaces
    # the browser's (router mounts only — `@tab_url_sync?`).
    {:noreply, activate_tab(socket, resolve_switch_target(tab, socket))}
  end

  defp gated_handle_event("complete", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      a ->
        attrs = %{
          status: "done",
          progress_pct: 100,
          completed_by_uuid: Activity.actor_uuid(socket),
          completed_at: DateTime.utc_now()
        }

        socket
        |> update_assignment_with_activity(a, attrs, "projects.assignment_completed",
          metadata: %{"task" => Assignment.label(a), "project" => socket.assigns.project.name}
        )
        |> maybe_sync_and_reload()
    end
  end

  defp gated_handle_event("start_task", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      a ->
        new_pct = if a.progress_pct == 100, do: 0, else: a.progress_pct
        attrs = %{status: "in_progress", progress_pct: new_pct}

        socket
        |> update_assignment_with_activity(a, attrs, "projects.assignment_started",
          metadata: %{"task" => Assignment.label(a)}
        )
        |> maybe_sync_and_reload()
    end
  end

  defp gated_handle_event("reopen", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      a ->
        attrs = %{
          status: "todo",
          progress_pct: 0,
          completed_by_uuid: nil,
          completed_at: nil
        }

        socket
        |> update_assignment_with_activity(a, attrs, "projects.assignment_reopened",
          metadata: %{"task" => Assignment.label(a)}
        )
        |> maybe_sync_and_reload()
    end
  end

  defp gated_handle_event("edit_duration", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      _a ->
        # Just flip the assign — the template sources the prefilled
        # values directly from the assignment row via the `:for=` loop
        # variable, so there's nothing to stage into a form here.
        {:noreply, assign(socket, editing_duration_uuid: uuid)}
    end
  end

  defp gated_handle_event("cancel_edit_duration", _params, socket) do
    {:noreply, assign(socket, editing_duration_uuid: nil)}
  end

  defp gated_handle_event(
         "save_duration",
         %{"estimated_duration" => dur, "estimated_duration_unit" => unit},
         socket
       ) do
    uuid = socket.assigns.editing_duration_uuid

    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      a ->
        old_dur = "#{a.estimated_duration} #{a.estimated_duration_unit}"
        attrs = %{estimated_duration: dur, estimated_duration_unit: unit}

        case Projects.update_assignment_form(a, attrs) do
          {:ok, _} ->
            Activity.log("projects.assignment_duration_changed",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "assignment",
              resource_uuid: uuid,
              metadata: %{
                "task" => Assignment.label(a),
                "from" => old_dur,
                "to" => "#{dur} #{unit}"
              }
            )

            recompute_owning_subproject(socket, a)

            {:noreply,
             socket
             |> assign(editing_duration_uuid: nil)
             |> load_assignments()}

          {:error, cs} ->
            Activity.log_failed("projects.assignment_duration_changed",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "assignment",
              resource_uuid: uuid,
              metadata: %{
                "task" => Assignment.label(a),
                "from" => old_dur,
                "to" => "#{dur} #{unit}"
              }
            )

            {:noreply,
             socket
             |> assign(editing_duration_uuid: nil)
             |> put_flash(:error, error_summary(cs, gettext("Could not update duration.")))}
        end
    end
  end

  defp gated_handle_event("remove_assignment", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      a ->
        case Projects.delete_assignment(a) do
          {:ok, _} ->
            Activity.log("projects.assignment_removed",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "assignment",
              resource_uuid: uuid,
              metadata: %{"task" => Assignment.label(a)}
            )

            recompute_owning_subproject(socket, a)

            {:noreply,
             socket
             |> WebHelpers.notify_deleted(:assignment, uuid)
             |> put_flash(:info, gettext("Task removed."))
             |> sync_project_completion()
             |> load_assignments()}

          {:error, _} ->
            Activity.log_failed("projects.assignment_removed",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "assignment",
              resource_uuid: uuid,
              metadata: %{"task" => Assignment.label(a)}
            )

            {:noreply, put_flash(socket, :error, gettext("Could not remove task."))}
        end
    end
  end

  # ── Sub-projects (V127) ──────────────────────────────────────────

  defp gated_handle_event("toggle_subproject", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      %Assignment{child_project_uuid: child_uuid} when is_binary(child_uuid) ->
        expanded = socket.assigns.expanded_subprojects

        if MapSet.member?(expanded, uuid) do
          {:noreply, assign(socket, expanded_subprojects: MapSet.delete(expanded, uuid))}
        else
          child_tasks = Projects.list_assignments(child_uuid)

          # Merge the child's dependencies so the inset child tasks' badges
          # render (they read `@deps_by_assignment`, keyed by assignment uuid).
          child_deps =
            child_uuid |> Projects.list_all_dependencies() |> Enum.group_by(& &1.assignment_uuid)

          # load_ledger last: the newly revealed child tasks' logged-time
          # chips read `@ledger_minutes`, which keys off the displayed set.
          {:noreply,
           socket
           |> assign(
             expanded_subprojects: MapSet.put(expanded, uuid),
             subproject_child_tasks:
               Map.put(socket.assigns.subproject_child_tasks, uuid, child_tasks),
             deps_by_assignment: Map.merge(socket.assigns.deps_by_assignment, child_deps)
           )
           |> load_ledger()}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp gated_handle_event("detach_subproject", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      %Assignment{child_project_uuid: child_uuid} = a when is_binary(child_uuid) ->
        case Projects.detach_subproject(a) do
          {:ok, _} ->
            Activity.log("projects.subproject_detached",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "project",
              resource_uuid: child_uuid,
              metadata: %{"parent_project_uuid" => socket.assigns.project.uuid}
            )

            {:noreply,
             socket
             |> put_flash(:info, gettext("Sub-project is now a standalone project."))
             |> sync_project_completion()
             |> load_assignments()}

          {:error, _} ->
            Activity.log_failed("projects.subproject_detached",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "project",
              resource_uuid: child_uuid,
              metadata: %{"parent_project_uuid" => socket.assigns.project.uuid}
            )

            {:noreply, put_flash(socket, :error, gettext("Could not detach the sub-project."))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp gated_handle_event("update_progress", %{"uuid" => uuid, "progress_pct" => pct_str}, socket) do
    case scoped_assignment(socket, uuid) do
      nil -> {:noreply, socket}
      a -> do_update_progress(socket, a, parse_pct(pct_str))
    end
  end

  defp gated_handle_event("toggle_tracking", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      a ->
        new_value = not a.track_progress

        case Projects.update_assignment_form(a, %{track_progress: new_value}) do
          {:ok, _} ->
            Activity.log("projects.assignment_tracking_toggled",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "assignment",
              resource_uuid: uuid,
              metadata: %{"task" => Assignment.label(a), "track_progress" => new_value}
            )

            recompute_owning_subproject(socket, a)
            {:noreply, load_assignments(socket)}

          {:error, _} ->
            Activity.log_failed("projects.assignment_tracking_toggled",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "assignment",
              resource_uuid: uuid,
              metadata: %{"task" => Assignment.label(a), "track_progress" => new_value}
            )

            {:noreply, put_flash(socket, :error, gettext("Could not toggle tracking."))}
        end
    end
  end

  defp gated_handle_event(
         "remove_dependency",
         %{"assignment" => a_uuid, "depends_on" => d_uuid},
         socket
       ) do
    # Both assignments must belong to the currently-viewed project —
    # prevents an admin on project A from unlinking deps in project B.
    # Cross-project mismatches are silent noops (UI never offers them).
    # An actual `remove_dependency/2` failure is rare but logged via
    # `log_failed` so a Postgres outage doesn't erase the click.
    # Both endpoints are scope-checked in a single query (distinct uuids →
    # exactly two rows when both live in this project); a missing or
    # cross-project endpoint yields <2 rows and is a silent no-op.
    case Projects.scoped_assignments([a_uuid, d_uuid], socket.assigns.project.uuid) do
      [_, _] ->
        case Projects.remove_dependency(a_uuid, d_uuid) do
          {:ok, _} ->
            Activity.log("projects.dependency_removed",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "assignment",
              resource_uuid: a_uuid,
              metadata: %{"depends_on_uuid" => d_uuid}
            )

            {:noreply, load_assignments(socket)}

          {:error, _} ->
            Activity.log_failed("projects.dependency_removed",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "assignment",
              resource_uuid: a_uuid,
              metadata: %{"depends_on_uuid" => d_uuid}
            )

            {:noreply, put_flash(socket, :error, gettext("Could not remove dependency."))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # Opens the start-project modal pre-filled with today's date. The
  # actual DB write happens in `confirm_start_project` so users can
  # backdate (project was already running before the system was set up)
  # or future-date (preparing the project but actual start is later).
  # Falls through to a no-op for projects already started — defensive
  # against double-clicks racing the LV's render of the now-hidden
  # button.
  # ── Health (P2b — the hub's manual "Needle") ─────────────────────

  defp gated_handle_event("open_health_modal", _params, socket) do
    {:noreply, assign(socket, health_modal_open: true)}
  end

  defp gated_handle_event("close_health_modal", _params, socket) do
    {:noreply, assign(socket, health_modal_open: false)}
  end

  defp gated_handle_event("save_health", %{"status" => status} = params, socket) do
    if Authz.can?(socket.assigns[:phoenix_kit_current_scope], socket.assigns.project, :set_health) do
      case Health.set(socket.assigns.project, status, Map.get(params, "note"),
             actor_uuid: Activity.actor_uuid(socket)
           ) do
        {:ok, project} ->
          {:noreply,
           assign(socket,
             project: project,
             health: Health.get(project),
             health_modal_open: false
           )}

        {:error, :invalid_status} ->
          {:noreply, put_flash(socket, :error, gettext("Pick a health status."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update the health."))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You don't have permission to set the health."))}
    end
  end

  # ── Work ledger (Step 10) ────────────────────────────────────────
  #
  # Modal open/close is flag-gated (@gated_events); the WRITE also runs
  # the authz resolver — `:log_time` floors at manager, with the
  # assignee relationship grant when the entry targets a task.

  defp gated_handle_event("open_log_time", params, socket) do
    {:noreply, assign(socket, log_time_open: true, log_time_uuid: Map.get(params, "uuid"))}
  end

  defp gated_handle_event("close_log_time", _params, socket) do
    {:noreply, assign(socket, log_time_open: false, log_time_uuid: nil)}
  end

  defp gated_handle_event("save_work_entry", params, socket) do
    record =
      case socket.assigns.log_time_uuid do
        nil -> nil
        uuid -> scoped_assignment(socket, uuid)
      end

    cond do
      socket.assigns.log_time_uuid != nil and is_nil(record) ->
        {:noreply,
         socket
         |> assign(log_time_open: false, log_time_uuid: nil)
         |> put_flash(:error, gettext("That task is no longer in this project."))}

      not Authz.can?(
        socket.assigns[:phoenix_kit_current_scope],
        socket.assigns.project,
        :log_time,
        record
      ) ->
        {:noreply,
         put_flash(socket, :error, gettext("You don't have permission to log time here."))}

      true ->
        do_save_work_entry(socket, params, record)
    end
  end

  # The ledger→invoice bridge (Phase E): owner-level money action; the
  # heavy lifting + all guards live in Invoicing.
  defp gated_handle_event("generate_invoice", _params, socket) do
    authorized? =
      Authz.can?(
        socket.assigns[:phoenix_kit_current_scope],
        socket.assigns.project,
        :edit_settings
      )

    if authorized? do
      case Invoicing.generate_draft(socket.assigns.project,
             actor_uuid: Activity.actor_uuid(socket)
           ) do
        {:ok, %{line_count: count, total_cents: cents}} ->
          {:noreply,
           put_flash(
             socket,
             :info,
             gettext("Draft invoice created: %{count} line(s), %{total}. Review it in Billing.",
               count: count,
               total: format_cents(cents)
             )
           )}

        {:error, :refs_failed, _invoice_uuid} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext(
               "The draft was created but marking the entries failed — reconcile in Billing before regenerating."
             )
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, invoice_error(reason))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You don't have permission to invoice this project."))}
    end
  end

  defp gated_handle_event("open_start_modal", _params, socket) do
    if socket.assigns.project.started_at do
      {:noreply, socket}
    else
      {:noreply,
       assign(socket,
         start_modal_open: true,
         start_form: to_form(%{"start_at" => default_start_at_local()})
       )}
    end
  end

  defp gated_handle_event("close_start_modal", _params, socket) do
    {:noreply, assign(socket, start_modal_open: false)}
  end

  defp gated_handle_event("confirm_start_project", %{"start_at" => datetime_str}, socket) do
    case parse_start_at(datetime_str) do
      {:ok, started_at} ->
        do_start_project(socket, started_at)

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  defp gated_handle_event("change_workflow_status", %{"status_slug" => slug}, socket) do
    slug = if slug in [nil, ""], do: nil, else: slug
    project = socket.assigns.project
    previous = project.current_status_slug

    case Statuses.set_current_status(project, slug, actor_uuid: Activity.actor_uuid(socket)) do
      {:ok, updated} ->
        Activity.log("projects.project_status_changed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: updated.uuid,
          metadata: %{
            "name" => updated.name,
            "status_slug" => slug,
            "previous_status_slug" => previous
          }
        )

        {:noreply, socket |> assign(project: updated) |> refresh_status_state()}

      {:error, _reason} ->
        Activity.log_failed("projects.project_status_changed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"status_slug" => slug}
        )

        {:noreply, put_flash(socket, :error, gettext("Could not change the status."))}
    end
  end

  defp gated_handle_event("archive_project", _params, socket) do
    case Projects.archive_project(socket.assigns.project) do
      {:ok, project} ->
        Activity.log("projects.project_archived",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        {:noreply,
         assign(socket, project: project) |> put_flash(:info, gettext("Project archived."))}

      {:error, _} ->
        Activity.log_failed("projects.project_archived",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: socket.assigns.project.uuid,
          metadata: %{"name" => socket.assigns.project.name}
        )

        {:noreply, put_flash(socket, :error, gettext("Could not archive project."))}
    end
  end

  # Comments drawer. Opening sets `comments_resource` to the
  # `(type, uuid, title)` triple of the target so the drawer header
  # can show context and the embedded `CommentsComponent` is keyed
  # uniquely per resource. Closing clears the assign — the
  # component unmounts and any in-flight reply state is dropped
  # (intended: drawer-close is a "step away" affordance).
  defp gated_handle_event("open_comments", %{"type" => type, "uuid" => uuid} = params, socket)
       when type in ["project", "assignment"] do
    title = Map.get(params, "title", "")

    {:noreply, assign(socket, comments_resource: %{type: type, uuid: uuid, title: title})}
  end

  defp gated_handle_event("close_comments", _params, socket) do
    {:noreply, assign(socket, comments_resource: nil)}
  end

  # SortableGrid drop handler. Validates the new order against the
  # project's assignments, applies positions atomically, and pushes a
  # `sortable:flash` back so the dragged card flashes green/red. This
  # session reloads explicitly (immediate feedback); OTHER open views
  # (and gantt charts) reload off the `:assignment_reordered` broadcast.
  # Refused unless the manual order is on screen: under "Newest first" a
  # drop describes nothing. The drag handles are already hidden then, but
  # hiding a control has never been the control. (A drop under a STATUS
  # lens is fine — `merge_visible_order/2` folds it into the whole plan.)
  defp gated_handle_event(
         "reorder_assignments",
         _params,
         %{assigns: %{list_manual?: false}} = socket
       ) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("Switch the sort back to Manual order before reordering tasks.")
     )}
  end

  defp gated_handle_event("reorder_assignments", %{"ordered_ids" => ordered_ids} = params, socket)
       when is_list(ordered_ids) do
    moved_id = params["moved_id"]
    project_uuid = socket.assigns.project.uuid

    # The hook sends the rows on screen; the write wants the whole plan.
    full_order = merge_visible_order(Enum.map(socket.assigns.assignments, & &1.uuid), ordered_ids)

    case Projects.reorder_assignments(project_uuid, full_order,
           actor_uuid: Activity.actor_uuid(socket)
         ) do
      :ok ->
        {:noreply,
         socket
         |> push_event("sortable:flash", %{uuid: moved_id, status: "ok"})
         |> load_assignments()}

      {:error, :too_many_uuids} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Too many tasks to reorder at once."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_assignments()}

      {:error, :not_in_project} ->
        # Stale view — a concurrent change moved an assignment out of
        # this project. Snap back to the persisted state.
        {:noreply,
         socket
         |> put_flash(:error, gettext("Tasks have changed; please try again."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_assignments()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not reorder tasks."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_assignments()}
    end
  end

  defp gated_handle_event("unarchive_project", _params, socket) do
    case Projects.unarchive_project(socket.assigns.project) do
      {:ok, project} ->
        Activity.log("projects.project_unarchived",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        {:noreply,
         assign(socket, project: project) |> put_flash(:info, gettext("Project unarchived."))}

      {:error, _} ->
        Activity.log_failed("projects.project_unarchived",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: socket.assigns.project.uuid,
          metadata: %{"name" => socket.assigns.project.name}
        )

        {:noreply, put_flash(socket, :error, gettext("Could not unarchive project."))}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  # `<input type="datetime-local">` posts `YYYY-MM-DDTHH:mm` (no
  # seconds, no timezone). Treat as UTC — what the user typed is what
  # gets stored. Pad seconds when missing so `NaiveDateTime` accepts it.
  defp parse_start_at(value) when is_binary(value) do
    with_seconds = if String.length(value) == 16, do: value <> ":00", else: value

    case NaiveDateTime.from_iso8601(with_seconds) do
      {:ok, ndt} ->
        {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}

      {:error, _} ->
        {:error, gettext("Invalid date — please pick a valid date and time.")}
    end
  end

  defp parse_start_at(_),
    do: {:error, gettext("Invalid date — please pick a valid date and time.")}

  # True only when the `phoenix_kit_comments` module is loaded AND
  # admin-enabled. Off-by-default `enabled?/0` rescues any error
  # (missing tables, sandbox-down) and returns false, so this stays
  # safe in early-install or test environments.
  defp comments_available? do
    Code.ensure_loaded?(PhoenixKitComments) and PhoenixKitComments.enabled?()
  end

  # Refreshes both the project-level and per-assignment comment
  # counts. Called from mount + after `:comments_updated` so the
  # button badges stay in sync with reality. Cheap: project count is
  # one query, assignment counts are one batched query keyed by
  # uuid — no N+1 even with long timelines.
  defp load_comment_counts(socket) do
    if socket.assigns[:comments_enabled] do
      project_uuid = socket.assigns.project.uuid

      # Rescue narrowed to the shapes we actually expect: comments are
      # optional (UndefinedFunctionError when the module is absent
      # mid-install / mid-Hex-bump) and DB transients shouldn't break
      # the badge. Anything else surfaces and gets fixed.
      project_count =
        try do
          PhoenixKitComments.count_comments("project", project_uuid, status: "published")
        rescue
          UndefinedFunctionError -> 0
          Postgrex.Error -> 0
          DBConnection.OwnershipError -> 0
        catch
          :exit, _reason -> 0
        end

      assignment_uuids = Enum.map(socket.assigns.assignments, & &1.uuid)
      assignment_counts = Projects.comment_counts_for_assignments(assignment_uuids)

      assign(socket,
        project_comment_count: project_count,
        assignment_comment_counts: assignment_counts
      )
    else
      socket
    end
  end

  # Label chips per displayed assignment (Phase C). Loaded only when the
  # labels flag resolves on; keyed by assignment uuid over the displayed
  # set (parent rows + expanded children), like the ledger chips.
  defp load_labels(socket) do
    %{project: project, is_template: is_template, fx: fx} = socket.assigns

    if (not is_template and fx[:labels]) && project.uuid do
      displayed =
        Enum.map(socket.assigns.assignments, & &1.uuid) ++
          (socket.assigns.subproject_child_tasks
           |> Map.values()
           |> List.flatten()
           |> Enum.map(& &1.uuid))

      assign(socket, assignment_labels: Labels.labels_for_assignments(displayed))
    else
      assign(socket, assignment_labels: %{})
    end
  end

  # Effort totals + per-task logged-time map (Step 10). Loaded only when
  # the `ledger` flag resolves on for a real project — nil/empty otherwise
  # so the render gates have one thing to check.
  defp load_ledger(socket) do
    %{project: project, is_template: is_template, fx: fx} = socket.assigns

    if (not is_template and fx[:ledger]) && project.uuid do
      # Chips key off the DISPLAYED assignment set (parent rows + expanded
      # child tasks) rather than the project, because child-task entries
      # attribute to the CHILD project. The strip totals stay strictly
      # this project's own effort.
      displayed =
        Enum.map(socket.assigns.assignments, & &1.uuid) ++
          (socket.assigns.subproject_child_tasks
           |> Map.values()
           |> List.flatten()
           |> Enum.map(& &1.uuid))

      assign(socket,
        ledger_totals: Ledger.totals_for_project(project.uuid),
        ledger_minutes: Ledger.time_for_assignments(displayed),
        # Cheap availability probe for the Invoice-effort button — the
        # click re-runs the FULL guard chain (authz + profile + rate).
        invoice_ready?:
          Extensions.enabled?(project, "billing_customer") and
            Authz.can?(socket.assigns[:phoenix_kit_current_scope], project, :edit_settings)
      )
    else
      assign(socket, ledger_totals: nil, ledger_minutes: %{}, invoice_ready?: false)
    end
  end

  # Default value for `<input type="datetime-local">`: today at the
  # current hour:minute, formatted `YYYY-MM-DDTHH:mm` (the format the
  # browser expects). Built from UTC so the prefilled value matches
  # what'll be persisted when the user clicks Start without changing
  # anything.
  defp default_start_at_local do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601()
    |> String.slice(0, 16)
  end

  # The active tab, derived from the route's live_action. `:gantt` is the gantt
  # tab, `:calendar` the calendar tab; `:show`, `:show_template`, and the
  # embedded (nil live_action) mount all default to the list. Templates never
  # expose the alternate views, so they pin to `:list` even on the `/gantt` /
  # `/calendar` routes (the tab bar + both nested LVs are `not @is_template`).
  # Health labels through gettext (Health.label/1 returns the msgid — the
  # translation happens at the caller under this module's backend).
  defp health_label("on_track"), do: gettext("On track")
  defp health_label("some_risk"), do: gettext("Some risk")
  defp health_label("concerned"), do: gettext("Concerned")
  defp health_label(other), do: other

  # A tab whose view flag is off resolves to :list — applied to the mount's
  # route-derived tab (a bookmarked /gantt URL on a timeline-off project) and
  # on live gate changes.
  defp gate_tab(:board, fx), do: if(fx.view_board, do: :board, else: :list)
  defp gate_tab(:gantt, fx), do: if(fx.view_timeline, do: :gantt, else: :list)
  defp gate_tab(:calendar, fx), do: if(fx.view_calendar, do: :calendar, else: :list)
  defp gate_tab(tab, _fx), do: tab

  # A `/comments` deep link on a project whose Discussions extension is off
  # (or without the comments package) lands like the bare page.
  defp gate_comments_tab(:comments, false), do: :list
  defp gate_comments_tab(tab, _comments?), do: tab

  # With tasks OFF the :list landing has no task surface — land on the first
  # contributed extension tab instead, or on Comments when that is the only
  # thing on (the empty state shows only when there is truly nothing).
  defp resolve_landing_tab(:list, %{tasks: false}, [%{id: first} | _], _comments?), do: first
  defp resolve_landing_tab(:list, %{tasks: false}, [], true), do: :comments
  defp resolve_landing_tab(tab, _fx, _ext_tabs, _comments?), do: tab

  # Contributed tabs from every effectively-enabled extension, flattened to
  # renderable entries. String ids are namespaced ("ext:<ext>:<tab>") so
  # they can never collide with the :list/:gantt/:calendar atoms.
  defp ext_tabs_for(_project, true, _scope), do: []

  defp ext_tabs_for(project, _is_template, scope) do
    project.uuid
    |> Extensions.enabled_for_project()
    |> Enum.filter(fn {ext, _row} ->
      # Sibling-module tabs require that module's permission on the
      # viewer (final panel, Grok — the Registry gate existed unwired).
      # A nil scope is an EMBED mount: the host authorized the surface
      # (the documented embed trust model), so keep current behavior
      # there rather than blanking every tab.
      is_nil(scope) or ExtRegistry.visible_for_scope?(ext, scope)
    end)
    |> Enum.flat_map(fn {ext, row} ->
      Enum.map(ext.tabs, fn tab ->
        %{
          id: "ext:#{ext.key}:#{tab.key}",
          # The URL segment of the tab (`/projects/:id/whiteboards`).
          slug: to_string(tab.key),
          label: tab.label,
          icon: tab.icon || ext.icon,
          lv: tab.lv,
          ext_key: ext.key,
          config: (row && row.config) || %{},
          write_action: write_action(ext)
        }
      end)
    end)
  rescue
    e ->
      Logger.warning("[Projects] ext_tabs_for failed: #{Exception.message(e)}")
      []
  end

  # The extension's declared mutating action (its first non-:view
  # permission_action) — resolved by the HOST into the tab session's
  # "can_write" (the host has the scope; the tab doesn't). nil = the
  # extension declares no writes; its tab gets can_write false.
  defp write_action(ext) do
    Enum.find(ext.permission_actions, &(&1 not in [:view, "view"]))
  end

  # Host-side write authorization for a contributed tab: the HOST holds
  # the scope, so it resolves the extension's declared write action and
  # hands the tab a boolean — mutating tabs (whiteboards, events) honor
  # it. A nil scope is an embed mount: host-authorized, per the
  # documented trust model. No declared write action = no writes.
  # A nil scope used to mean "can write" — the embed case, where no on_mount
  # runs, was handed write access to every contributed tab. Fail CLOSED: an
  # unidentified viewer gets read-only. (The mount gate now refuses an
  # unidentified embed outright, so this is the second line rather than the
  # first, but a fail-open authz branch should not exist at all.)
  defp ext_tab_can_write(assigns, tab) do
    case {assigns[:phoenix_kit_current_scope], tab.write_action} do
      {_, nil} -> false
      {nil, _} -> false
      {scope, action} -> Authz.can?(scope, assigns.project, action)
    end
  end

  defp ext_initial_mounted(active_tab) when is_binary(active_tab), do: MapSet.new([active_tab])
  defp ext_initial_mounted(_), do: MapSet.new()

  defp valid_ext_tab?(socket, id), do: Enum.any?(socket.assigns.ext_tabs, &(&1.id == id))

  # The view tabs are feature-gated: a client event naming a gated-off tab
  # (stale DOM, forged payload) falls back to the list. Extension tab ids
  # are validated against the CURRENT ext_tabs set — an id for a
  # since-disabled extension falls back too.
  # Make a (validated) tab the active one. Every nested surface is
  # lazy-mounted the first time its tab opens and never unmounted — the
  # extension LV, the gantt and the calendar each keep their state across
  # switches. Shared by the switch event and the live re-gate, which used
  # to skip the mount marks and land on an extension tab with no pane
  # (codex, 2026-09-05).
  defp activate_tab(socket, active) do
    ext_mounted =
      if is_binary(active),
        do: MapSet.put(socket.assigns.ext_mounted, active),
        else: socket.assigns.ext_mounted

    socket
    |> assign(active_tab: active, ext_mounted: ext_mounted)
    |> remember_task_view(active)
    |> assign(gantt_mounted?: socket.assigns.gantt_mounted? or active == :gantt)
    |> assign(calendar_mounted?: socket.assigns.calendar_mounted? or active == :calendar)
  end

  defp resolve_switch_target(tab, socket) do
    %{fx: fx, ext_tabs: ext_tabs, comments_enabled: comments?} = socket.assigns

    target =
      case tab do
        "tasks" -> gate_tab(socket.assigns.task_view, fx)
        "board" when :erlang.map_get(:view_board, fx) -> :board
        "gantt" when :erlang.map_get(:view_timeline, fx) -> :gantt
        "calendar" when :erlang.map_get(:view_calendar, fx) -> :calendar
        "comments" when comments? -> :comments
        "ext:" <> _ -> if valid_ext_tab?(socket, tab), do: tab, else: :list
        _ -> :list
      end

    # The same landing rule as mount (codex, 2026-09-05): with tasks off a
    # forged "tasks" / unknown tab must land on the first thing that IS on,
    # never on a :list whose pane the project does not render.
    resolve_landing_tab(target, fx, ext_tabs, comments?)
  end

  # The task view that the Tasks top tab reopens: the last one shown.
  defp remember_task_view(socket, tab) when tab in [:list, :board, :gantt, :calendar],
    do: assign(socket, task_view: tab)

  defp remember_task_view(socket, _tab), do: socket

  @doc """
  The TOP-LEVEL tab a view belongs to: the four task views (`:list`,
  `:board`, `:gantt`, `:calendar`) are `:tasks`; everything else — a
  contributed extension tab (`"ext:<ext>:<tab>"`), `:comments` — is itself.
  """
  @spec top_tab_of(atom() | String.t()) :: atom() | String.t()
  def top_tab_of(tab) when tab in [:list, :board, :gantt, :calendar], do: :tasks
  def top_tab_of(tab), do: tab

  # The tab a route names: `live_action` + the `:tab` segment of the
  # extension-tab catch-all. Templates never leave the list.
  defp tab_for_action(_action, _slug, true, _ext_tabs), do: :list

  defp tab_for_action(action, slug, _is_template, ext_tabs) do
    case action do
      :board -> :board
      :gantt -> :gantt
      :calendar -> :calendar
      :comments -> :comments
      # `/projects/:id/<tab>` — a contributed extension tab by its key;
      # an unknown segment lands on the first tab like the bare page.
      :ext_tab -> ext_tab_for_slug(ext_tabs, slug) || :list
      _ -> :list
    end
  end

  defp ext_tab_for_slug(ext_tabs, slug) when is_binary(slug) do
    case Enum.find(ext_tabs, &(&1.slug == slug)) do
      %{id: id} -> id
      nil -> nil
    end
  end

  defp ext_tab_for_slug(_ext_tabs, _slug), do: nil

  @doc """
  The canonical address of a tab — what the page hands core's `PkUrlMirror`
  so the browser's URL follows a switch (router mounts only). The task
  views live under `/tasks` (`/tasks/board|timeline|calendar`), Comments at
  `/comments`, a contributed extension tab at `/<its key>`; an unknown tab
  (unreachable after resolution) falls back to the bare project page.
  """
  @spec tab_url(atom() | String.t(), map(), [map()]) :: String.t()
  def tab_url(:list, project, _ext_tabs), do: Paths.project_tasks(project.uuid)
  def tab_url(:board, project, _ext_tabs), do: Paths.project_board(project.uuid)
  def tab_url(:gantt, project, _ext_tabs), do: Paths.project_gantt(project.uuid)
  def tab_url(:calendar, project, _ext_tabs), do: Paths.project_calendar(project.uuid)
  def tab_url(:comments, project, _ext_tabs), do: Paths.project_comments(project.uuid)

  def tab_url("ext:" <> _ = id, project, ext_tabs) do
    case Enum.find(ext_tabs, &(&1.id == id)) do
      %{slug: slug} -> Paths.project_ext_tab(project.uuid, slug)
      nil -> Paths.project(project.uuid)
    end
  end

  def tab_url(_tab, project, _ext_tabs), do: Paths.project(project.uuid)

  defp do_start_project(socket, started_at) do
    case Projects.start_project(socket.assigns.project, started_at) do
      {:ok, project} ->
        Activity.log("projects.project_started",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{
            "name" => project.name,
            "started_at" => DateTime.to_iso8601(started_at)
          }
        )

        {:noreply,
         socket
         |> assign(project: project, start_modal_open: false)
         |> put_flash(:info, gettext("Project started!"))}

      {:error, _} ->
        Activity.log_failed("projects.project_started",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: socket.assigns.project.uuid,
          metadata: %{
            "name" => socket.assigns.project.name,
            "started_at" => DateTime.to_iso8601(started_at)
          }
        )

        {:noreply, put_flash(socket, :error, gettext("Could not start project."))}
    end
  end

  defp parse_pct(pct_str) do
    case Integer.parse(pct_str) do
      {n, _} -> max(0, min(n, 100))
      :error -> 0
    end
  end

  defp progress_attrs(100, socket),
    do: %{
      progress_pct: 100,
      status: "done",
      completed_by_uuid: Activity.actor_uuid(socket),
      completed_at: DateTime.utc_now()
    }

  defp progress_attrs(0, _socket),
    do: %{progress_pct: 0, status: "todo", completed_by_uuid: nil, completed_at: nil}

  defp progress_attrs(pct, _socket),
    do: %{progress_pct: pct, status: "in_progress", completed_by_uuid: nil, completed_at: nil}

  defp progress_action(100, prev_status) when prev_status != "done",
    do: "projects.assignment_completed"

  defp progress_action(pct, "todo") when pct > 0, do: "projects.assignment_started"

  defp progress_action(0, prev_status) when prev_status != "todo",
    do: "projects.assignment_reopened"

  defp progress_action(_pct, _prev_status), do: "projects.assignment_progress_updated"

  defp do_update_progress(socket, a, pct) do
    attrs = progress_attrs(pct, socket)

    # Uses the server-trusted path because `progress_attrs/2` sets
    # `completed_by_uuid` / `completed_at` on the 100% and 0% branches.
    case Projects.update_assignment_status(a, attrs) do
      {:ok, _} ->
        Activity.log(progress_action(pct, a.status),
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: a.uuid,
          metadata: %{"task" => Assignment.label(a), "progress_pct" => pct}
        )

        recompute_owning_subproject(socket, a)

        socket =
          if attrs.status != a.status, do: sync_project_completion(socket), else: socket

        {:noreply, load_assignments(socket)}

      {:error, cs} ->
        Activity.log_failed(progress_action(pct, a.status),
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: a.uuid,
          metadata: %{"task" => Assignment.label(a), "progress_pct" => pct}
        )

        {:noreply,
         put_flash(socket, :error, error_summary(cs, gettext("Could not update progress.")))}
    end
  end

  defp assignee_type(a) do
    cond do
      a.assigned_person_uuid -> gettext("Person")
      a.assigned_team_uuid -> gettext("Team")
      a.assigned_department_uuid -> gettext("Department")
      true -> nil
    end
  end

  # The action row's workflow-status select renders under exactly these
  # conditions; the header badge yields to it (one status, not two).
  defp workflow_select?(assigns) do
    assigns.fx.statuses and assigns.statuses_available and assigns.status_options != []
  end

  # Does the standalone page's header have anything to show? Badges
  # (Completed / Archived / the read-only status fallback) or a
  # description. Without any, the header renders nothing at all rather
  # than an empty box above the tabs.
  defp header_face?(assigns, desc) do
    not is_nil(desc) or not is_nil(assigns.project.completed_at) or
      not is_nil(assigns.project.archived_at) or
      (assigns.statuses_available and not workflow_select?(assigns))
  end

  # ── Schedule calculation ─────────────────────────────────────────

  defp calculate_schedule(%{started_at: nil}, _), do: nil
  defp calculate_schedule(_project, []), do: nil

  defp calculate_schedule(project, assignments) do
    {total_hours, effective_done} = sum_hours(project, assignments)

    if total_hours == 0 do
      nil
    else
      build_schedule(project, total_hours, effective_done)
    end
  end

  defp sum_hours(project, assignments) do
    {total, done, progress} =
      Enum.reduce(assignments, {0, 0, 0}, fn a, {total, done, progress} ->
        accumulate_hours(a, project, total, done, progress)
      end)

    {total, done + progress}
  end

  defp accumulate_hours(%{status: "done"} = a, project, total, done, progress) do
    hours = assignment_hours(a, project)
    {total + hours, done + hours, progress}
  end

  defp accumulate_hours(
         %{track_progress: true, progress_pct: pct} = a,
         project,
         total,
         done,
         progress
       )
       when pct > 0 do
    hours = assignment_hours(a, project)
    {total + hours, done, progress + hours * pct / 100}
  end

  defp accumulate_hours(a, project, total, done, progress) do
    {total + assignment_hours(a, project), done, progress}
  end

  defp build_schedule(project, total_hours, effective_done) do
    now = DateTime.utc_now()
    calendar_hours = DateTime.diff(now, project.started_at, :second) / 3600
    # `planned_end_for/2` honors `counts_weekends`: for weekday-only
    # projects weekend days don't consume the work budget. We keep it
    # internal (drives the overdue/expected math) — it isn't displayed
    # to the user; the started-at date + the per-row durations + the
    # ETA below already tell the same story.
    planned_end = Project.planned_end_for(project, total_hours)
    remaining_hours = max(total_hours - effective_done, 0)
    past_planned_end? = DateTime.compare(now, planned_end) == :gt
    done? = remaining_hours <= 0

    # Planned-elapsed = work hours under the project's schedule rules.
    planned_elapsed_hours =
      if project.counts_weekends,
        do: calendar_hours,
        else: work_hours_elapsed(project.started_at, now)

    # Cap expected at 100% once calendar time has blown past the
    # planned end. Otherwise a project with all weekends elapsed and a
    # short total can report "0% expected" — which then makes a 0%-done
    # project look "on time" instead of overdue.
    raw_expected_pct = planned_elapsed_hours / total_hours * 100

    expected_pct =
      if past_planned_end? and not done? do
        100.0
      else
        min(raw_expected_pct, 100)
      end

    # Cap defensively: nothing rendered should exceed 100% even if
    # `effective_done` somehow drifts past `total_hours` (e.g. task
    # durations edited downward after work was logged).
    actual_pct = min(effective_done / total_hours * 100, 100)
    delta_pct = actual_pct - expected_pct
    overdue? = past_planned_end? and not done?

    # When overdue, report calendar lateness ("1 day overdue") rather
    # than work-hours-equivalent — for a 52-minute task that's 2 days
    # late, "< 1 hour behind" reads as nearly-on-time, which is wrong.
    delta_label =
      if overdue? do
        delta_days(now, planned_end)
      else
        {v, u} = humanize_hours(abs(delta_pct / 100 * total_hours))
        "#{v} #{u}"
      end

    %{
      total_hours: total_hours,
      done_hours: effective_done,
      remaining_hours: remaining_hours,
      elapsed_hours: planned_elapsed_hours,
      expected_pct: round(expected_pct),
      actual_pct: round(actual_pct),
      delta_pct: round(delta_pct),
      ahead?: delta_pct >= 0 and not overdue?,
      overdue?: overdue?,
      delta_label: delta_label,
      projected_end: projected_end(project, now, remaining_hours)
    }
  end

  # ETA = "if work continues at the original pace from now, this is
  # when you'll finish". For completed projects, return the actual
  # completion time. For unfinished projects, anchor on `now` and walk
  # `remaining_hours` forward through the project's weekday/weekend
  # rules — same machinery `planned_end_for/2` uses, just with a
  # different start anchor (see `Project.eta_from/3`).
  defp projected_end(%{completed_at: %DateTime{} = at}, _now, _remaining), do: at
  defp projected_end(_project, now, remaining) when remaining <= 0, do: now
  defp projected_end(project, now, remaining), do: Project.eta_from(project, now, remaining)

  # Mirrors `Project.planned_end_for/2`'s weekday-only model: each
  # weekday's calendar time contributes work hours at the 3:1 ratio
  # (24 calendar hours = 8 work hours); weekend days contribute zero.
  # Walks the calendar day-by-day clipping the start/end days.
  defp work_hours_elapsed(%DateTime{} = from, %DateTime{} = to) do
    if DateTime.compare(from, to) != :lt do
      0
    else
      sum_weekday_calendar_hours(from, to) / 3.0
    end
  end

  defp sum_weekday_calendar_hours(from, to) do
    from_date = DateTime.to_date(from)
    to_date = DateTime.to_date(to)

    Date.range(from_date, to_date)
    |> Enum.reduce(0.0, fn date, acc ->
      if Date.day_of_week(date) <= 5 do
        acc + weekday_calendar_hours_on(date, from, to)
      else
        acc
      end
    end)
  end

  defp weekday_calendar_hours_on(date, from, to) do
    sod = DateTime.new!(date, ~T[00:00:00.000], from.time_zone)
    eod = DateTime.new!(date, ~T[23:59:59.999], from.time_zone)

    window_start = if DateTime.compare(from, sod) == :gt, do: from, else: sod
    window_end = if DateTime.compare(to, eod) == :lt, do: to, else: eod

    if DateTime.compare(window_start, window_end) == :lt do
      DateTime.diff(window_end, window_start, :second) / 3600
    else
      0
    end
  end

  defp delta_days(later, earlier) do
    seconds = DateTime.diff(later, earlier, :second)
    hours = seconds / 3600
    days = hours / 24

    cond do
      hours < 1 -> gettext("< 1 hour")
      days < 1 -> ngettext("%{count} hour", "%{count} hours", round(hours))
      days < 2 -> gettext("1 day")
      days < 14 -> ngettext("%{count} day", "%{count} days", round(days))
      days < 60 -> gettext("%{n} weeks", n: Float.round(days / 7, 1))
      true -> gettext("%{n} months", n: Float.round(days / 30, 1))
    end
  end

  # Calendar-scale boundaries (1h, 24h, 7d, 30d) so unit transitions
  # land at intuitive points. Previously transitioned at 8h/40h which
  # came from "1 workday = 8h" and produced jarring jumps like
  # 7.9h → "8 hours", 8h → "1.0 days".
  defp humanize_hours(h) when h < 1, do: {gettext("< 1"), gettext("hour")}
  defp humanize_hours(h) when h < 24, do: {round(h), gettext("hours")}
  defp humanize_hours(h) when h < 24 * 7, do: {Float.round(h / 24, 1), gettext("days")}
  defp humanize_hours(h) when h < 24 * 30, do: {Float.round(h / (24 * 7), 1), gettext("weeks")}
  defp humanize_hours(h), do: {Float.round(h / (24 * 30), 1), gettext("months")}

  # ── Priority display (Phase C) ───────────────────────────────────

  defp priority_class("urgent"), do: "badge-error"
  defp priority_class("high"), do: "badge-warning"
  defp priority_class("low"), do: "badge-ghost"
  defp priority_class(_), do: "badge-ghost"

  defp priority_label("urgent"), do: gettext("Urgent")
  defp priority_label("high"), do: gettext("High")
  defp priority_label("low"), do: gettext("Low")
  defp priority_label(other), do: other

  defp invoice_error(:billing_unavailable),
    do: gettext("The Billing module isn't available on this site.")

  defp invoice_error(:extension_disabled),
    do: gettext("Enable the Customer billing extension for this project first.")

  defp invoice_error(:no_rate),
    do: gettext("Set the hourly rate in the Customer billing extension's settings.")

  defp invoice_error(:no_profile),
    do: gettext("Link a billing profile in the Customer billing extension's settings.")

  defp invoice_error(:profile_not_found),
    do: gettext("The linked billing profile no longer exists.")

  defp invoice_error(:nothing_to_bill),
    do: gettext("No uninvoiced billable time to bill.")

  defp invoice_error(_), do: gettext("Could not create the draft invoice.")

  # ── Work-ledger helpers (Step 10) ────────────────────────────────

  defp do_save_work_entry(socket, params, record) do
    # Attribute to the project that OWNS the assignment: an expanded
    # sub-project child task belongs to the CHILD project, not the parent
    # page it was logged from (panel round, Grok). No record = the viewed
    # project itself.
    target_project_uuid = if record, do: record.project_uuid, else: socket.assigns.project.uuid

    case parse_total_minutes(params) do
      {:ok, minutes} ->
        target_project_uuid
        |> Ledger.log_time(minutes,
          assignment_uuid: record && record.uuid,
          note: blank_to_nil(params["note"]),
          billable: params["billable"] in ["true", "on"],
          actor_uuid: Activity.actor_uuid(socket)
        )
        |> case do
          {:ok, _entry} ->
            {:noreply,
             socket
             |> assign(log_time_open: false, log_time_uuid: nil)
             |> load_ledger()
             |> put_flash(:info, gettext("Time logged."))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not log the time."))}
        end

      :error ->
        {:noreply, put_flash(socket, :error, gettext("Enter a positive amount of time."))}
    end
  end

  # Hours + minutes inputs -> total minutes; whole non-negatives only,
  # and the total must be positive.
  defp parse_total_minutes(params) do
    h = parse_whole(params["hours"])
    m = parse_whole(params["minutes"])

    cond do
      is_nil(h) or is_nil(m) -> :error
      h * 60 + m <= 0 -> :error
      true -> {:ok, h * 60 + m}
    end
  end

  defp parse_whole(nil), do: 0
  defp parse_whole(""), do: 0

  defp parse_whole(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_whole(_), do: nil

  defp blank_to_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  # "45m" / "2h" / "2h 05m" — totals stay scannable at any size.
  defp format_minutes(m) do
    m = round(m)
    h = div(m, 60)
    rest = rem(m, 60)

    cond do
      h == 0 -> gettext("%{m}m", m: rest)
      rest == 0 -> gettext("%{h}h", h: h)
      true -> gettext("%{h}h %{m}m", h: h, m: rest)
    end
  end

  defp format_tokens(t) when t >= 1_000_000,
    do: gettext("%{n}M tokens", n: Float.round(t / 1_000_000, 1))

  defp format_tokens(t) when t >= 1_000, do: gettext("%{n}k tokens", n: Float.round(t / 1_000, 1))
  defp format_tokens(t), do: gettext("%{n} tokens", n: round(t))

  # Cents -> a dollar string. The ledger stores cents unit-agnostically;
  # the display currency is a deliberate v1 simplification (morning list).
  defp format_cents(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  # Modal subtitle: the targeted task's title, or nil for a project-level
  # entry. Searches the same displayed set `scoped_assignment/2` accepts.
  defp log_time_task_label(assigns) do
    case assigns.log_time_uuid do
      nil ->
        nil

      uuid ->
        (assigns.assignments ++
           (assigns.subproject_child_tasks |> Map.values() |> List.flatten()))
        |> Enum.find(&(&1.uuid == uuid))
        |> case do
          nil -> nil
          a -> TaskSchema.localized_title(a.task, L10n.current_content_lang())
        end
    end
  end

  defp format_duration(a) do
    dur = a.estimated_duration
    unit = a.estimated_duration_unit

    if dur && unit do
      TaskSchema.format_duration(dur, unit)
    else
      TaskSchema.format_duration(a.task.estimated_duration, a.task.estimated_duration_unit)
    end
  end

  defp duration_unit_options do
    [
      {gettext("Minutes"), "minutes"},
      {gettext("Hours"), "hours"},
      {gettext("Days"), "days"},
      {gettext("Weeks"), "weeks"},
      {gettext("Fortnights"), "fortnights"},
      {gettext("Months"), "months"},
      {gettext("Years"), "years"}
    ]
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <%!-- Header. The standalone admin page drops the back-link + h1 row —
           the site breadcrumb carries "Templates|Projects / <name>" (and the
           way back) and, beside it, the status picker + ⋮ (`page_toolbar`).
           What is left here is the project's face: the lifecycle badges and
           the description — and when it has neither, nothing: the tabs start
           right under the site header. Embedded mounts have no admin
           breadcrumb, so they keep the full original header. --%>
      <% desc = Project.localized_description(@project, L10n.current_content_lang()) %>
      <div :if={not @router_mounted? or header_face?(assigns, desc)}>
        <.smart_link
          :if={not @router_mounted?}
          navigate={if @is_template, do: Paths.templates(), else: Paths.projects()}
          emit={
            if @is_template,
              do: {PhoenixKitProjects.Web.TemplatesLive, %{}},
              else: {PhoenixKitProjects.Web.ProjectsLive, %{}}
          }
          embed_mode={@embed_mode}
          class="link link-hover text-sm"
        >
          <.icon name="hero-arrow-left" class="w-4 h-4 inline" />
          {if @is_template, do: gettext("Templates"), else: gettext("Projects")}
        </.smart_link>
        <div class={["flex flex-col gap-2", not @router_mounted? && "mt-1"]}>
          <%!-- Title (embeds only) + lifecycle/status badges. Min-width: 0
               lets the h1 truncate instead of pushing siblings around. --%>
          <div class="flex flex-wrap items-center gap-2 min-w-0">
            <%= if not @router_mounted? do %>
              <h1 class="text-2xl font-bold break-words">
                {Project.localized_name(@project, L10n.current_content_lang())}
              </h1>
              <span :if={@is_template} class="badge badge-info badge-sm">{gettext("Template")}</span>
            <% end %>
            <%= if @project.completed_at do %>
              <span class="badge badge-success gap-1">
                <.icon name="hero-check-circle" class="w-3.5 h-3.5" /> {gettext("Completed")}
              </span>
            <% end %>
            <%= if @project.archived_at do %>
              <span class="badge badge-ghost gap-1">
                <.icon name="hero-archive-box" class="w-3.5 h-3.5" /> {gettext("Archived")}
              </span>
            <% end %>
            <%!-- User-defined workflow status (entities-backed), alongside
                 the computed lifecycle badges above — but ONLY when the
                 action row's status select is not there to show it: the
                 same "In Progress" twice, as a badge and as the select's
                 value, was the header's one visible defect (Max,
                 2026-09-05). The select is the control; the badge is the
                 read-only fallback (no list, or the statuses flag off). --%>
            <.workflow_status_badge
              :if={@statuses_available and not workflow_select?(assigns)}
              status={@current_status}
            />
          </div>
          <%!-- Description sits directly under the title (embeds) or the
               badges — the project's subtitle. --%>
          <p :if={desc} class="text-sm text-base-content/60">
            <.mention_text text={desc} scope={@phoenix_kit_current_scope} />
          </p>
          <%!-- The status picker + ⋮ live in the site header on the
               standalone page (`page_toolbar`); an embed has no site header,
               so it keeps them here under its own h1. --%>
          <div :if={not @router_mounted?} class="flex flex-wrap gap-2">
            {header_toolbar(assigns)}
          </div>
        </div>
      </div>



      <%!-- Access-request dialog: opened by a redacted mention anywhere on
           this page. Renders nothing until one is clicked. --%>
      <.access_request_dialog request={assigns[:pk_access_request]} />

      <%!-- Review queue. A stranger's submission is a request, not work —
           so the decision happens here, in one place, with the text and the
           images the person actually sent. Accepting is what turns it into
           a task; until then it is in no list, no board and no count. --%>
      <%= if @review_open? and @pending_reviews != [] do %>
        <dialog open class="modal modal-open" phx-window-keydown="close_review" phx-key="Escape">
          <div class="modal-box max-w-2xl">
            <h3 class="font-bold text-lg">{gettext("Submissions to review")}</h3>
            <p class="text-sm text-base-content/70 mt-1">
              {gettext("Sent from the public board. Accepting adds it to the project; rejecting keeps a record and shows nobody.")}
            </p>

            <div class="flex flex-col gap-2 mt-4 max-h-[60vh] overflow-y-auto">
              <div
                :for={a <- @pending_reviews}
                class={[
                  "rounded-box border transition-colors",
                  if(@review_selected == a.uuid,
                    do: "border-info bg-base-200",
                    else: "border-base-200"
                  )
                ]}
              >
                <%!-- The whole header is the toggle. A submission is mostly
                     unreadable at a glance — the title is a stranger's one
                     line and the substance is underneath it — so opening one
                     has to be the cheapest thing on this dialog. --%>
                <div class="flex items-start justify-between gap-3 p-3">
                  <button
                    type="button"
                    phx-click="select_review"
                    phx-value-uuid={a.uuid}
                    class="flex items-start gap-2 min-w-0 text-left flex-1 cursor-pointer"
                    aria-expanded={to_string(@review_selected == a.uuid)}
                  >
                    <.icon
                      name={
                        if(@review_selected == a.uuid,
                          do: "hero-chevron-down",
                          else: "hero-chevron-right"
                        )
                      }
                      class="w-4 h-4 mt-0.5 shrink-0 opacity-60"
                    />
                    <span class="min-w-0">
                      <span class="font-medium break-words block">
                        {TaskSchema.localized_title(a.task, L10n.current_content_lang())}
                      </span>
                      <span class="text-xs opacity-60 flex items-center gap-2">
                        <.time_ago datetime={a.inserted_at} />
                        <span :if={review_detail(@review_details, a.uuid).images != []} class="flex items-center gap-1">
                          <.icon name="hero-photo" class="w-3 h-3" />
                          {length(review_detail(@review_details, a.uuid).images)}
                        </span>
                      </span>
                    </span>
                  </button>

                  <div class="flex items-center gap-2 shrink-0">
                    <button
                      type="button"
                      phx-click="review_submission"
                      phx-value-uuid={a.uuid}
                      phx-value-decision="accepted"
                      phx-disable-with={gettext("Accepting…")}
                      class="btn btn-success btn-xs"
                    >
                      <.icon name="hero-check" class="w-3.5 h-3.5" /> {gettext("Accept")}
                    </button>
                    <button
                      type="button"
                      phx-click="review_submission"
                      phx-value-uuid={a.uuid}
                      phx-value-decision="rejected"
                      phx-disable-with={gettext("Rejecting…")}
                      data-confirm={gettext("Reject this submission?")}
                      class="btn btn-ghost btn-xs"
                    >
                      {gettext("Reject")}
                    </button>
                  </div>
                </div>

                <%!-- Everything the person actually sent. Rendered only for
                     the open one: the images are signed URLs, and drawing
                     every submission's attachments to decide on one of them
                     is bandwidth nobody asked for. --%>
                <div :if={@review_selected == a.uuid} class="px-3 pb-3 flex flex-col gap-3">
                  <p
                    :if={a.description not in [nil, ""]}
                    class="text-sm whitespace-pre-wrap break-words opacity-80"
                  >
                    {a.description}
                  </p>
                  <p :if={a.description in [nil, ""]} class="text-sm italic opacity-50">
                    {gettext("No description was given.")}
                  </p>

                  <div :if={review_detail(@review_details, a.uuid).images != []} class="flex flex-wrap gap-2">
                    <a
                      :for={image <- review_detail(@review_details, a.uuid).images}
                      href={image.url}
                      target="_blank"
                      rel="noopener noreferrer nofollow"
                      title={gettext("Open full size")}
                    >
                      <img
                        src={image.url}
                        alt={gettext("Submitted attachment")}
                        loading="lazy"
                        class="h-32 w-32 rounded-lg border border-base-300 object-cover hover:opacity-90"
                      />
                    </a>
                  </div>

                  <%!-- Only say "anonymous" when it is true. The portal
                       takes submissions from signed-in people too, and
                       telling a reviewer that a colleague's report came
                       from nobody is worse than saying nothing. --%>
                  <p class="text-xs opacity-50">
                    <%= case review_detail(@review_details, a.uuid).submitted_by do %>
                      <% nil -> %>
                        {gettext("Sent anonymously from the public board. Images are re-encoded on arrival.")}
                      <% name -> %>
                        {gettext("Sent from the public board by %{name}. Images are re-encoded on arrival.",
                          name: name
                        )}
                    <% end %>
                  </p>
                </div>
              </div>
            </div>

            <div class="modal-action">
              <button type="button" phx-click="close_review" class="btn btn-ghost btn-sm">
                {gettext("Close")}
              </button>
            </div>
          </div>
          <form method="dialog" class="modal-backdrop">
            <button type="button" phx-click="close_review">close</button>
          </form>
        </dialog>
      <% end %>

      <%!-- Health modal --%>
      <%= if @health_modal_open do %>
        <dialog open class="modal modal-open" phx-window-keydown="close_health_modal" phx-key="Escape">
          <div class="modal-box max-w-md">
            <h3 class="font-bold text-lg">{gettext("Project health")}</h3>
            <p class="text-sm text-base-content/70 mt-1">
              {gettext("Your judgment, not a computed number — how does this project feel right now?")}
            </p>
            <form phx-submit="save_health" class="flex flex-col gap-3 mt-4">
              <div class="flex flex-col gap-2">
                <label
                  :for={status <- Health.statuses()}
                  class="flex items-center gap-3 cursor-pointer rounded-lg border border-base-200 px-3 py-2 hover:bg-base-200"
                >
                  <input
                    type="radio"
                    name="status"
                    value={status}
                    checked={@health && @health["status"] == status}
                    class="radio radio-sm"
                    required
                  />
                  <span class="text-sm font-medium">{health_label(status)}</span>
                </label>
              </div>
              <label class="fieldset">
                <span class="fieldset-legend text-xs opacity-70 mb-1">{gettext("Note (optional)")}</span>
                <textarea
                  name="note"
                  rows="2"
                  class="textarea textarea-sm"
                  placeholder={gettext("What's behind this call?")}
                >{@health && @health["note"]}</textarea>
              </label>
              <div class="modal-action">
                <button type="button" phx-click="close_health_modal" class="btn btn-ghost btn-sm">
                  {gettext("Cancel")}
                </button>
                <button type="submit" phx-disable-with={gettext("Saving…")} class="btn btn-primary btn-sm">
                  {gettext("Save")}
                </button>
              </div>
            </form>
          </div>
          <button type="button" phx-click="close_health_modal" class="modal-backdrop" aria-label={gettext("Close")}>
          </button>
        </dialog>
      <% end %>

      <%!-- Log-time modal (Step 10). Render-gated on the same flag the
           events check; @log_time_uuid scopes the entry to a task. --%>
      <%= if @log_time_open and @fx.ledger do %>
        <dialog open class="modal modal-open" phx-window-keydown="close_log_time" phx-key="Escape">
          <div class="modal-box max-w-sm">
            <h3 class="font-bold text-lg">{gettext("Log time")}</h3>
            <p class="text-sm text-base-content/70 mt-1">
              <%= if label = log_time_task_label(assigns) do %>
                {gettext("On task: %{task}", task: label)}
              <% else %>
                {gettext("On the project overall")}
              <% end %>
            </p>
            <form phx-submit="save_work_entry" class="flex flex-col gap-3 mt-4">
              <div class="flex items-center gap-2">
                <label class="fieldset flex-1">
                  <span class="fieldset-legend text-xs opacity-70 mb-1">{gettext("Hours")}</span>
                  <input
                    type="number"
                    name="hours"
                    min="0"
                    step="1"
                    value="0"
                    class="input input-sm"
                  />
                </label>
                <label class="fieldset flex-1">
                  <span class="fieldset-legend text-xs opacity-70 mb-1">{gettext("Minutes")}</span>
                  <input
                    type="number"
                    name="minutes"
                    min="0"
                    max="59"
                    step="1"
                    value="30"
                    class="input input-sm"
                  />
                </label>
              </div>
              <label class="fieldset">
                <span class="fieldset-legend text-xs opacity-70 mb-1">{gettext("Note (optional)")}</span>
                <input
                  type="text"
                  name="note"
                  class="input input-sm"
                  placeholder={gettext("What was the time spent on?")}
                />
              </label>
              <label class="flex items-center gap-2 cursor-pointer">
                <input type="checkbox" name="billable" value="true" class="checkbox checkbox-sm" />
                <span class="text-sm">{gettext("Billable")}</span>
              </label>
              <div class="modal-action">
                <button type="button" phx-click="close_log_time" class="btn btn-ghost btn-sm">
                  {gettext("Cancel")}
                </button>
                <button
                  type="submit"
                  phx-disable-with={gettext("Logging…")}
                  class="btn btn-primary btn-sm"
                >
                  {gettext("Log time")}
                </button>
              </div>
            </form>
          </div>
          <button
            type="button"
            phx-click="close_log_time"
            class="modal-backdrop"
            aria-label={gettext("Close")}
          >
          </button>
        </dialog>
      <% end %>


      <%!-- ── The top-level tabs (the boss, 2026-09-05) ──
           Tasks holds everything about tasks; every enabled extension and
           Comments are its peers, so each can stand alone in an otherwise
           empty project (a class leader who only uses whiteboards). Files,
           Members, Activity, Modules stay in the ⋮ menu: project chrome,
           not places you live in. Templates get no strip (Tasks only).
           A hidden element carries the active tab's canonical address in
           `data-url` (present whether or not a strip shows — a lone Tasks
           tab still has /tasks/board); core's PkUrlMirror hook replaces
           the browser's URL with it on router mounts (`@tab_url_sync?`) so
           copy / reload / deep links land on the tab — an embed never
           touches its host's URL. --%>
      <% top_tab = top_tab_of(@active_tab) %>
      <% top_tabs =
        if(@fx.tasks, do: [%{id: "tasks", label: gettext("Tasks"), icon: "hero-clipboard-document-list"}], else: []) ++
          Enum.map(@ext_tabs, &%{id: &1.id, label: &1.label, icon: &1.icon}) ++
          if(@comments_enabled,
            do: [
              %{
                id: "comments",
                label: gettext("Comments"),
                icon: "hero-chat-bubble-left-right",
                badge: if(@project_comment_count > 0, do: @project_comment_count)
              }
            ],
            else: []
          ) %>
      <div
        :if={@tab_url_sync? and not @is_template}
        id={"project-url-#{@project.uuid}"}
        phx-hook="PkUrlMirror"
        data-url={tab_url(@active_tab, @project, @ext_tabs)}
        class="hidden"
      >
      </div>
      <div :if={not @is_template and length(top_tabs) > 1} id={"project-tabs-#{@project.uuid}"}>
        <.nav_tabs active_tab={to_string(top_tab)} on_change="switch_tab" tabs={top_tabs} />
      </div>

      <%!-- Nothing turned on at all: the one state where the page has no
           tab to show. Data is preserved — flipping anything on restores
           its tab. --%>
      <%= if top_tabs == [] do %>
        <.empty_state icon="hero-squares-plus" title={gettext("Nothing is turned on for this project yet.")}>
          <:cta>
            <.smart_link
              navigate={Paths.modules(@project.uuid)}
              emit={{PhoenixKitProjects.Web.ProjectModulesLive, %{"id" => @project.uuid}}}
              embed_mode={@embed_mode}
              popup={false}
              class="link link-primary text-sm"
            >
              {gettext("Manage this project's modules & features")}
            </.smart_link>
          </:cta>
        </.empty_state>
      <% end %>

      <%!-- ── The Tasks tab ──
           Everything task-derived lives here: the add actions, the lifecycle
           bar, health, the schedule / progress / effort card, and the task
           views behind their own, subordinate strip. A tasks-off project
           has no Tasks tab and none of this. --%>
      <div :if={@fx.tasks} class={["flex flex-col gap-4", top_tab != :tasks && "hidden"]}>
        <div :if={not @is_template} class="flex flex-wrap gap-2">
            <.smart_link
              navigate={Paths.new_assignment(@project.uuid)}
              emit={{PhoenixKitProjects.Web.AssignmentFormLive, %{"live_action" => "new", "project_id" => @project.uuid}}}
              embed_mode={@embed_mode}
              class="btn btn-primary btn-sm"
            >
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add task")}
            </.smart_link>
            <%!-- Add a sub-project via the same add page tasks use
                 (`AssignmentFormLive` in sub-project mode, V127) — name +
                 assignee + dependencies. Template sub-projects deep-clone on
                 instantiation. --%>
            <.smart_link
              :if={@fx.subprojects}
              navigate={Paths.new_assignment(@project.uuid) <> "?kind=subproject"}
              emit={{PhoenixKitProjects.Web.AssignmentFormLive, %{"live_action" => "new", "project_id" => @project.uuid, "kind" => "subproject"}}}
              embed_mode={@embed_mode}
              class="btn btn-outline btn-sm gap-1"
            >
              <.icon name="hero-folder-plus" class="w-4 h-4" /> {gettext("Add sub-project")}
            </.smart_link>
        </div>

      <%!-- Start mode / template bar. Hidden entirely when the project has
           no lifecycle: a checklist has no beginning to announce, and the
           bar's whole job is announcing one. Templates keep it — their
           branch is about how to USE the template, not about starting. --%>
      <div
        :if={@is_template or @fx.lifecycle}
        class="flex flex-wrap items-center gap-3 bg-base-200 rounded-lg px-4 py-3"
      >
        <%= cond do %>
          <% @is_template -> %>
            <.icon name="hero-document-duplicate" class="w-5 h-5 text-info" />
            <span class="text-sm">{gettext("This is a template — set up tasks, then create projects from it.")}</span>
            <.smart_link
              navigate={Paths.new_project() <> "?template=#{@project.uuid}"}
              emit={{PhoenixKitProjects.Web.ProjectFormLive, %{"live_action" => "new", "template" => @project.uuid}}}
              embed_mode={@embed_mode}
              class="btn btn-primary btn-xs ml-auto"
            >
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Create project from this template")}
            </.smart_link>
          <% @project.completed_at -> %>
            <.icon name="hero-trophy" class="w-5 h-5 text-success" />
            <span class="text-sm font-medium">
              {gettext("Completed %{when}", when: L10n.format_datetime(@project.completed_at))}
            </span>
            <%= if @project.started_at do %>
              <span class="text-base-content/40 mx-1">·</span>
              <span class="text-sm text-base-content/60">
                {gettext("took %{duration}", duration: delta_days(@project.completed_at, @project.started_at))}
              </span>
            <% end %>
          <% @project.started_at -> %>
            <.icon name="hero-play" class="w-5 h-5 text-success" />
            <span class="text-sm">
              {gettext("Started %{when}", when: L10n.format_datetime(@project.started_at))}
            </span>
            <%= if @schedule do %>
              <span class="text-base-content/40 mx-1">·</span>
              <%= cond do %>
                <% @schedule.overdue? -> %>
                  <span class="badge badge-error badge-sm gap-1">
                    <.icon name="hero-exclamation-triangle" class="w-3 h-3" />
                    {gettext("%{delta} overdue", delta: @schedule.delta_label)}
                  </span>
                <% @schedule.ahead? -> %>
                  <span class="badge badge-success badge-sm gap-1">
                    <.icon name="hero-arrow-trending-up" class="w-3 h-3" />
                    {gettext("%{delta} ahead", delta: @schedule.delta_label)}
                  </span>
                <% true -> %>
                  <span class="badge badge-error badge-sm gap-1">
                    <.icon name="hero-arrow-trending-down" class="w-3 h-3" />
                    {gettext("%{delta} behind", delta: @schedule.delta_label)}
                  </span>
              <% end %>
              <span class="text-xs text-base-content/50 ml-1">
                {gettext("(%{actual}% done vs %{expected}% expected)", actual: @schedule.actual_pct, expected: @schedule.expected_pct)}
              </span>
            <% end %>
          <% @project.start_mode == "scheduled" -> %>
            <.icon name="hero-calendar" class="w-5 h-5 text-info" />
            <span class="text-sm">
              {gettext("Scheduled for %{when}", when: L10n.format_datetime(@project.scheduled_start_date))}
            </span>
            <button
              type="button"
              phx-click="open_start_modal"
              class="btn btn-success btn-xs ml-auto"
            >
              {gettext("Start now")}
            </button>
          <% true -> %>
            <.icon name="hero-clock" class="w-5 h-5 text-warning" />
            <span class="text-sm">{gettext("Not started — set up tasks, then start")}</span>
            <button
              type="button"
              phx-click="open_start_modal"
              class="btn btn-success btn-xs ml-auto"
            >
              <.icon name="hero-play" class="w-4 h-4" /> {gettext("Start project")}
            </button>
        <% end %>
      </div>

      <%!-- Health strip — the hub's manual "Needle" (P2b): a human judgment
           with a note, never auto-computed. Click-through opens the modal. --%>
      <div
        :if={not @is_template and @health && @fx.lifecycle}
        class={["alert py-2 px-4", Health.color_class(@health["status"])]}
      >
        <.icon name="hero-heart" class="w-4 h-4" />
        <div class="flex flex-wrap items-baseline gap-2 min-w-0">
          <span class="font-medium text-sm">{health_label(@health["status"])}</span>
          <span :if={@health["note"]} class="text-sm opacity-80 truncate">{@health["note"]}</span>
        </div>
        <button type="button" class="btn btn-ghost btn-xs ml-auto" phx-click="open_health_modal">
          {gettext("Update")}
        </button>
      </div>

      <%!-- Schedule summary + progress as ONE card: the progress bar is the
           card's bottom edge (a thin flush strip), so the two read as a unit. --%>
      <% show_schedule = @fx.scheduling and @project.started_at != nil and @schedule != nil %>
      <% show_progress = @fx.tasks and @total_tasks > 0 and not @is_template %>
      <% show_effort = @fx.ledger and @ledger_totals != nil %>
      <%= if show_schedule or show_progress or show_effort do %>
        <div class="bg-base-200/50 rounded-t-lg overflow-hidden">
          <%= if show_schedule do %>
            <% {rem_v, rem_u} = humanize_hours(@schedule.remaining_hours) %>
            <div class="flex flex-wrap items-center gap-3 px-4 py-2 text-xs">
              <%= if @project.completed_at do %>
                <div class="flex items-center gap-2">
                  <.icon name="hero-check-circle" class="w-4 h-4 text-success" />
                  <span class="text-base-content/60">{gettext("Finished:")}</span>
                  <span class="font-medium">{L10n.format_datetime(@schedule.projected_end)}</span>
                </div>
              <% else %>
                <div class="flex items-center gap-2">
                  <.icon name="hero-clock" class="w-4 h-4 text-base-content/60" />
                  <span class="text-base-content/60">{gettext("Remaining:")}</span>
                  <span class="font-medium">{rem_v} {rem_u}</span>
                </div>
                <span class="text-base-content/40">·</span>
                <div class="flex items-center gap-2">
                  <.icon name="hero-arrow-trending-up" class={"w-4 h-4 #{if @schedule.ahead?, do: "text-success", else: "text-error"}"} />
                  <span class="text-base-content/60">{gettext("ETA:")}</span>
                  <span class={[
                    "font-medium",
                    @schedule.ahead? && "text-success",
                    not @schedule.ahead? && "text-error"
                  ]}>
                    {L10n.format_datetime(@schedule.projected_end)}
                  </span>
                  <span class="text-base-content/40">{gettext("at planned pace")}</span>
                </div>
              <% end %>
            </div>
          <% end %>
          <%!-- Effort row (Step 10 work ledger): human time + AI usage
               totals, and the project-level Log-time entry point. --%>
          <%= if show_effort do %>
            <div class={[
              "flex flex-wrap items-center gap-3 px-4 py-2 text-xs",
              show_schedule && "border-t border-base-300/50"
            ]}>
              <div class="flex items-center gap-2">
                <.icon name="hero-play-circle" class="w-4 h-4 text-base-content/60" />
                <span class="text-base-content/60">{gettext("Logged:")}</span>
                <span class="font-medium">{format_minutes(@ledger_totals.time_minutes)}</span>
                <span :if={@ledger_totals.billable_minutes > 0} class="text-base-content/50">
                  {gettext("(%{amount} billable)",
                    amount: format_minutes(@ledger_totals.billable_minutes)
                  )}
                </span>
              </div>
              <%= if @ledger_totals.tokens > 0 or @ledger_totals.cost_cents > 0 do %>
                <span class="text-base-content/40">·</span>
                <div class="flex items-center gap-2">
                  <.icon name="hero-cpu-chip" class="w-4 h-4 text-base-content/60" />
                  <span class="text-base-content/60">{gettext("AI:")}</span>
                  <span class="font-medium">{format_tokens(@ledger_totals.tokens)}</span>
                  <span :if={@ledger_totals.cost_cents > 0} class="text-base-content/50">
                    ({format_cents(@ledger_totals.cost_cents)})
                  </span>
                </div>
              <% end %>
              <div class="flex items-center gap-1 ml-auto">
                <button
                  :if={@invoice_ready?}
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="generate_invoice"
                  data-confirm={gettext("Create a draft invoice from all uninvoiced billable time?")}
                >
                  <.icon name="hero-banknotes" class="w-3 h-3" /> {gettext("Invoice effort")}
                </button>
                <button type="button" class="btn btn-ghost btn-xs" phx-click="open_log_time">
                  <.icon name="hero-plus" class="w-3 h-3" /> {gettext("Log time")}
                </button>
              </div>
            </div>
          <% end %>
          <%!-- Progress bar — the card's bottom border (not for templates). --%>
          <div :if={show_progress} class="w-full bg-base-300 h-1.5" title={gettext("%{done}/%{total} done", done: @done_tasks, total: @total_tasks)}>
            <div class="bg-success h-1.5 transition-all duration-300" style={"width: #{@progress_pct}%"}>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- The task views: List / Board / Timeline / Calendar, each behind
           its feature flag. A single view needs no strip. --%>
      <% task_tabs =
        [%{id: "list", label: gettext("List"), icon: "hero-list-bullet"}] ++
          if(@fx.view_board,
            do: [%{id: "board", label: gettext("Board"), icon: "hero-view-columns"}],
            else: []
          ) ++
          if(@fx.view_timeline,
            do: [%{id: "gantt", label: gettext("Timeline"), icon: "hero-chart-bar-square"}],
            else: []
          ) ++
          if(@fx.view_calendar,
            do: [%{id: "calendar", label: gettext("Calendar"), icon: "hero-calendar-days"}],
            else: []
          ) %>
      <div :if={not @is_template and length(task_tabs) > 1} id={"project-task-views-#{@project.uuid}"}>
        <.nav_tabs
          active_tab={to_string(@active_tab)}
          on_change="switch_tab"
          tabs={task_tabs}
          variant={:border}
        />
      </div>

      <%!-- List tab --%>
      <div class={if(@active_tab != :list, do: "hidden")}>
      <%!-- Timeline --%>
      <%!-- The lens bar. Every count is drawn from the FULL set and every
           one of them is a link into its own slice: filtering the list is
           fine, but a project that quietly looks like 47 tasks when it
           holds 947 is not. The number is the honesty; the rows are just
           what you happen to be reading. --%>
      <div
        :if={@assignments != [] and (@list_controls? or @pending_reviews != [])}
        class="flex flex-wrap items-center gap-2 mb-4"
      >
        <%!-- Active and Done partition the project exactly — Active means
             "not done", so nothing is in both and nothing is in neither,
             including a row carrying a status we do not model. The earlier
             strip listed Active AND To do AND In progress side by side,
             which looked like slices of one pie whose numbers then refused
             to add up, because Active contained the other two. --%>
        <%!-- One frame for the lens AND the sort (core's `:trailing` slot):
             two controls over the same list read as one bar, not two
             unrelated boxes sharing a row (Max, 2026-09-05). --%>
        <.nav_tabs
          :if={@list_controls?}
          active_tab={@list_status}
          on_change="list_filter_status"
          tabs={[
            %{id: "active", label: gettext("Active"), badge: @assignment_counts.active},
            %{id: "done", label: gettext("Done"), badge: @assignment_counts.done},
            %{id: "all", label: gettext("All"), badge: @assignment_counts.total}
          ]}
        >
          <:trailing>
            <%!-- A form, not a bare select: LiveView refuses a phx-change
                 on an input outside a form ("form events require the
                 input to be inside a form"), so the bare version changed
                 the control and never the list. The sweep, 2026-09-05. --%>
            <form id={"project-list-sort-#{@project.uuid}"} phx-change="list_sort">
              <select class="select select-sm" name="sort" aria-label={gettext("Sort tasks")}>
                <option value="position" selected={@list_sort == :position}>
                  {gettext("Manual order")}
                </option>
                <option value="newest" selected={@list_sort == :newest}>
                  {gettext("Newest first")}
                </option>
                <option value="recent" selected={@list_sort == :recent}>
                  {gettext("Recently updated")}
                </option>
              </select>
            </form>

            <%!-- Says why the handles vanished. A control that disappears
                 without explanation reads as a bug. --%>
            <span
              :if={not @list_manual?}
              class="text-xs opacity-60"
              title={gettext("Dragging rearranges the manual order — switch the sort back to Manual order to reorder.")}
            >
              {gettext("Reordering off")}
            </span>
          </:trailing>
        </.nav_tabs>

        <%!-- Not a filter. Public submissions are not in the list at all —
             they are requests nobody has agreed to yet, and mixing them
             into the plan meant every count, filter and drag treated a
             stranger's message as work. This opens the decision instead. --%>
        <button
          :if={@pending_reviews != []}
          type="button"
          phx-click="open_review"
          class="btn btn-sm btn-info gap-1"
        >
          <.icon name="hero-inbox-arrow-down" class="w-4 h-4" />
          {gettext("Review submissions")}
          <span class="badge badge-sm">{length(@pending_reviews)}</span>
        </button>

      </div>

      <%= if @assignments != [] and @visible_assignments == [] do %>
        <.empty_state icon="hero-funnel" title={gettext("Nothing matches this filter.")}>
          <:cta>
            <button
              type="button"
              phx-click="list_filter_status"
              phx-value-tab="all"
              class="link link-primary text-sm"
            >
              {gettext("Show all %{count} tasks", count: @assignment_counts.total)}
            </button>
          </:cta>
        </.empty_state>
      <% end %>

      <%= if @assignments == [] do %>
        <.empty_state icon="hero-rectangle-stack" title={gettext("No tasks in this project yet.")}>
          <:cta>
            <.smart_link
              navigate={Paths.new_assignment(@project.uuid)}
              emit={{PhoenixKitProjects.Web.AssignmentFormLive, %{"live_action" => "new", "project_id" => @project.uuid}}}
              embed_mode={@embed_mode}
              class="link link-primary text-sm"
            >
              {gettext("Add the first task")}
            </.smart_link>
          </:cta>
        </.empty_state>
      <% else %>
        <div :if={@visible_assignments != []} class="relative">
          <%!-- The connector rail claims "these run one after another" —
               the schedule is a sequential walk in drag order, and the line
               is that walk drawn down the list. Two ways for the claim to
               be false: under a lens the rows are a slice, not the plan;
               and with scheduling OFF (a checklist) there is no walk at all,
               only a list whose order is yours to arrange. So it renders
               only when both hold. Dragging shares the first condition,
               not the second — a checklist is still reorderable. --%>
          <div
            :if={@list_manual? and @list_whole? and @fx.scheduling}
            class="absolute left-5 top-0 bottom-0 w-0.5 bg-base-300"
          >
          </div>

          <%!-- SortableGrid hook lives on the inner flex container —
               the absolute-positioned vertical line is a sibling
               outside it so it doesn't get included in the sortable
               item set. The drag handle on each card's title row is
               the only initiator (`.pk-drag-handle`), so clicks
               anywhere else on the card still trigger the existing
               status / duration / dep handlers. --%>
          <div
            id="project-show-timeline"
            class="flex flex-col gap-0"
            phx-hook={if @list_manual?, do: "SortableGrid"}
            data-sortable={to_string(@list_manual?)}
            data-sortable-event="reorder_assignments"
            data-sortable-items=".sortable-item"
            data-sortable-handle=".pk-drag-handle"
          >
            <%= for a <- @visible_assignments do %>
              <div class="relative flex gap-4 py-3 sortable-item" data-id={a.uuid}>
                <%!-- Status dot on the timeline --%>
                <div class="relative z-10 shrink-0 flex flex-col items-center">
                  <div class={"w-10 h-10 rounded-full flex items-center justify-center text-xs font-bold #{AssignmentStatusBadge.color(a.status)} #{AssignmentStatusBadge.text_color(a.status)} #{AssignmentStatusBadge.ring(a.status)}"}>
                    <%= if a.status == "done" do %>
                      <.icon name="hero-check" class="w-5 h-5" />
                    <% else %>
                      {Map.get(@assignment_numbers, a.uuid)}
                    <% end %>
                  </div>
                </div>

                <%!-- Card --%>
                <div class={"flex-1 card bg-base-100 shadow-sm border #{if not @is_template and a.status == "done", do: "border-success/30 opacity-75", else: "border-base-200"}"}>
                  <%= if Assignment.subproject?(a) do %>
                    <div class="card-body py-3 px-4 gap-2">
                      <% sp_lang = L10n.current_content_lang() %>
                      <% child = a.child_project %>
                      <% sp_summary = Map.get(@subproject_summaries, a.uuid) %>
                      <% sp_expanded? = MapSet.member?(@expanded_subprojects, a.uuid) %>

                      <%!-- Sub-project title row --%>
                      <div class="flex items-center justify-between gap-2">
                        <div class="flex items-center gap-2 min-w-0">
                          <span class="pk-drag-handle cursor-grab text-base-content/40 hover:text-base-content shrink-0" title={gettext("Drag to reorder")}>
                            <.icon name="hero-bars-3" class="w-4 h-4" />
                          </span>
                          <button
                            type="button"
                            phx-click="toggle_subproject"
                            phx-value-uuid={a.uuid}
                            class="btn btn-ghost btn-xs btn-circle"
                            title={gettext("Show sub-project tasks")}
                          >
                            <.icon name={if sp_expanded?, do: "hero-chevron-down", else: "hero-chevron-right"} class="w-4 h-4" />
                          </button>
                          <span class="badge badge-secondary badge-sm gap-1 shrink-0">
                            <.icon name="hero-folder" class="w-3 h-3" /> {gettext("Sub-project")}
                          </span>
                          <.assignment_status_badge :if={not @is_template} status={a.status} />
                          <%!-- Name opens the child project, same as the
                               row's Open action. --%>
                          <.smart_link
                            navigate={Paths.project(child.uuid)}
                            emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => child.uuid}}}
                            embed_mode={@embed_mode}
                            popup={false}
                            class="font-medium truncate min-w-0 link link-hover"
                          >
                            {Project.localized_name(child, sp_lang)}
                          </.smart_link>
                        </div>

                        <div class="flex items-center gap-1 shrink-0">
                          <.smart_link
                            navigate={Paths.project(child.uuid)}
                            emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => child.uuid}}}
                            embed_mode={@embed_mode}
                            popup={false}
                            class="btn btn-ghost btn-xs gap-1"
                          >
                            <.icon name="hero-arrow-top-right-on-square" class="w-3.5 h-3.5" /> {gettext("Open")}
                          </.smart_link>
                          <.table_row_menu id={"assignment-menu-#{a.uuid}"}>
                            <.smart_menu_link
                              navigate={Paths.project(child.uuid)}
                              emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => child.uuid}}}
                              embed_mode={@embed_mode}
                              popup={false}
                              icon="hero-arrow-top-right-on-square"
                              label={gettext("Open sub-project")}
                            />
                            <%!-- Edit name/assignee/dependencies on the same form
                                 tasks use (V127), not a special inline control. --%>
                            <.smart_menu_link
                              navigate={Paths.edit_assignment(@project.uuid, a.uuid)}
                              emit={{PhoenixKitProjects.Web.AssignmentFormLive, %{"live_action" => "edit", "project_id" => @project.uuid, "id" => a.uuid}}}
                              embed_mode={@embed_mode}
                              icon="hero-pencil"
                              label={gettext("Edit")}
                            />
                            <%!-- Pop the sub-project back out as a standalone
                                 project — keeps it + its tasks (V127). --%>
                            <.table_row_menu_button
                              :if={@fx.subprojects}
                              phx-click="detach_subproject"
                              phx-value-uuid={a.uuid}
                              phx-disable-with={gettext("Detaching…")}
                              data-confirm={gettext("Make \"%{name}\" a standalone project? It keeps all its tasks — it just won't be a sub-project anymore.", name: Project.localized_name(child, sp_lang))}
                              icon="hero-arrow-up-on-square"
                              label={gettext("Make standalone")}
                            />
                            <.table_row_menu_divider />
                            <.table_row_menu_button
                              phx-click="remove_assignment"
                              phx-value-uuid={a.uuid}
                              phx-disable-with={gettext("Removing…")}
                              data-confirm={gettext("Remove sub-project \"%{name}\" and everything inside it?", name: Project.localized_name(child, sp_lang))}
                              icon="hero-trash"
                              label={gettext("Remove")}
                              variant="error"
                            />
                          </.table_row_menu>
                        </div>
                      </div>

                      <%!-- Sub-project description --%>
                      <% sp_desc = Project.localized_description(child, sp_lang) %>
                      <%!-- Through mention_text, so an @ or # written here
                           resolves for THIS reader: a link if they may open
                           it, the author's words if it's gone, a locked chip
                           if it isn't theirs to see. --%>
                      <div :if={sp_desc} class="text-xs text-base-content/60">
                        <.mention_text text={sp_desc} scope={@phoenix_kit_current_scope} />
                      </div>

                      <%!-- Rolled-up meta (read-only — driven by the child) --%>
                      <div :if={sp_summary} class="flex flex-wrap items-center gap-2 text-xs">
                        <span class="badge badge-outline badge-sm gap-1">
                          <.icon name="hero-rectangle-stack" class="w-3 h-3" />
                          {gettext("%{done}/%{total} tasks", done: sp_summary.done, total: sp_summary.total)}
                        </span>
                        <% {sp_hv, sp_hu} = humanize_hours(sp_summary.total_hours) %>
                        <span :if={sp_summary.total_hours > 0} class="badge badge-ghost badge-sm gap-1">
                          <.icon name="hero-clock" class="w-3 h-3" /> {sp_hv} {sp_hu}
                        </span>
                        <div class="flex items-center gap-1">
                          <progress class="progress progress-primary w-20" value={a.progress_pct} max="100"></progress>
                          <span class="text-base-content/60 w-8">{a.progress_pct}%</span>
                        </div>
                        <span :if={assignee_type(child)} class="badge badge-outline badge-sm gap-1">
                          <.icon name="hero-user" class="w-3 h-3" />
                          {assignee_type(child)}: {assignee_label(child)}
                        </span>
                      </div>

                      <%!-- This sub-project's own dependencies (on siblings) --%>
                      <% sp_deps = Map.get(@deps_by_assignment, a.uuid, []) %>
                      <div :if={sp_deps != []} class="flex flex-wrap gap-1 mt-1">
                        <%= for dep <- sp_deps do %>
                          <span class="badge badge-outline badge-xs gap-1">
                            <.icon name="hero-arrow-right-circle" class="w-3 h-3" />
                            {gettext("depends on:")} {Assignment.label(dep.depends_on, sp_lang)}
                            <button
                              phx-click="remove_dependency"
                              phx-value-assignment={a.uuid}
                              phx-value-depends_on={dep.depends_on_uuid}
                              phx-disable-with={gettext("Removing…")}
                              class="hover:text-error"
                            >
                              <.icon name="hero-x-mark" class="w-3 h-3" />
                            </button>
                          </span>
                        <% end %>
                      </div>

                      <%!-- Expanded: the child's own task list + add-dependency --%>
                      <div :if={sp_expanded?} class="mt-2 rounded-lg bg-base-200/60 p-3 flex flex-col gap-2">
                        <% child_tasks = Map.get(@subproject_child_tasks, a.uuid, []) %>
                        <%= if child_tasks == [] do %>
                          <p class="text-xs text-base-content/50">
                            {gettext("No tasks in this sub-project yet.")}
                            <.smart_link
                              navigate={Paths.new_assignment(child.uuid)}
                              emit={{PhoenixKitProjects.Web.AssignmentFormLive, %{"live_action" => "new", "project_id" => child.uuid}}}
                              embed_mode={@embed_mode}
                              class="link link-primary"
                            >
                              {gettext("Add one")}
                            </.smart_link>
                          </p>
                        <% else %>
                          <div class="flex flex-col gap-2">
                            <%= for {ct, ci} <- Enum.with_index(child_tasks) do %>
                              <%= if Assignment.subproject?(ct) do %>
                                <%!-- A nested sub-project: a compact link (open it to drill in). --%>
                                <div class="flex items-center gap-2 text-xs">
                                  <.assignment_status_badge status={ct.status} />
                                  <span class="badge badge-secondary badge-xs shrink-0">{gettext("Sub-project")}</span>
                                  <.smart_link
                                    navigate={Paths.project(ct.child_project.uuid)}
                                    emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => ct.child_project.uuid}}}
                                    embed_mode={@embed_mode}
                                    popup={false}
                                    class="truncate flex-1 hover:underline"
                                  >
                                    {Project.localized_name(ct.child_project, sp_lang)}
                                  </.smart_link>
                                  <span class="text-base-content/50">{ct.progress_pct}%</span>
                                </div>
                              <% else %>
                                <%!-- Same task card as the top-level timeline, just inset. --%>
                                <div class="relative flex gap-3">
                                  <div class="relative z-10 shrink-0 flex flex-col items-center">
                                    <div class={"w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold #{AssignmentStatusBadge.color(ct.status)} #{AssignmentStatusBadge.text_color(ct.status)} #{AssignmentStatusBadge.ring(ct.status)}"}>
                                      <%= if ct.status == "done" do %>
                                        <.icon name="hero-check" class="w-4 h-4" />
                                      <% else %>
                                        {ci + 1}
                                      <% end %>
                                    </div>
                                  </div>
                                  <div class={"flex-1 card bg-base-100 shadow-sm border #{if ct.status == "done", do: "border-success/30 opacity-75", else: "border-base-200"}"}>
                                    <.task_body
                                      a={ct}
                                      scope={@phoenix_kit_current_scope}
                                      draggable={false}
                                      is_template={@is_template}
                                      project={child}
                                      fx={@fx}
                                      embed_mode={@embed_mode}
                                      editing_duration_uuid={@editing_duration_uuid}
                                      comments_enabled={@comments_enabled}
                                      assignment_comment_counts={@assignment_comment_counts}
                                      ledger_minutes={@ledger_minutes}
                                      assignment_labels={@assignment_labels}
                                      deps_by_assignment={@deps_by_assignment}
                                    />
                                  </div>
                                </div>
                              <% end %>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  <% else %>
                    <.task_body
                      a={a}
                      scope={@phoenix_kit_current_scope}
                      draggable={@list_manual?}
                      is_template={@is_template}
                      project={@project}
                      fx={@fx}
                      embed_mode={@embed_mode}
                      editing_duration_uuid={@editing_duration_uuid}
                      comments_enabled={@comments_enabled}
                      assignment_comment_counts={@assignment_comment_counts}
                      ledger_minutes={@ledger_minutes}
                      assignment_labels={@assignment_labels}
                      deps_by_assignment={@deps_by_assignment}
                    />
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <%!-- The "Add a task" row at the foot of the list opens the same
           sheet as the button at the top, cursor in the title; Shift+Enter
           in there adds and starts the next (see `AssignmentFormLive`).
           Real projects only — a template's tasks are library tasks by
           design. Feature-gated on render like the "Add task" button. --%>
      <.quick_add_composer
        :if={@fx.tasks and not @is_template}
        project_uuid={@project.uuid}
        embed_mode={@embed_mode}
      />
      </div>

      <%!-- Gantt tab — rendered in every context (templates excepted),
      <%!-- Board tab — the kanban-lite view (Step 9): the SAME assignments
           grouped by task status. v1 moves cards with the existing
           server-trusted status buttons (drag lands with a dedicated hook
           later); every action goes through the same gated dispatcher as
           the list view. --%>
      <div :if={not @is_template and @fx.view_board} class={if(@active_tab != :board, do: "hidden")}>
        <%!-- A card whose status is outside the vocabulary belongs in no
             column, so the board simply dropped it — silently, which is the
             worst way to lose a task. Named here and left to the list,
             which renders it properly; dragging one in would coerce a value
             we never wrote and cannot get back. --%>
        <p :if={board_orphans(@assignments) > 0} class="text-xs opacity-60 mb-2">
          {gettext("%{count} task(s) have a status this board does not show — open the List tab.",
            count: board_orphans(@assignments)
          )}
        </p>

        <% board_columns = board_columns(@fx, @assignments) %>
        <div class={[
          "grid grid-cols-1 gap-4 items-start",
          if(length(board_columns) == 3, do: "md:grid-cols-3", else: "md:grid-cols-2")
        ]}>
          <div
            :for={{status, title, tint} <- board_columns}
            class={["bg-base-200/50 rounded-lg border-t-4 p-3 flex flex-col gap-2 min-h-24", tint]}
          >
            <% column = Enum.filter(@assignments, &(&1.status == status)) %>
            <div class="flex items-center justify-between px-1">
              <span class="text-sm font-semibold">{title}</span>
              <span class="badge badge-ghost badge-sm">{length(column)}</span>
            </div>
            <p :if={column == []} class="text-xs opacity-40 px-1 py-2">{gettext("Nothing here.")}</p>

            <%!-- One group across all three columns, so a card can be
                 dragged between them. The DESTINATION's event and scope are
                 what the hook sends, so every column names the same event
                 and its own status, and the handler reads the status it
                 landed in.

                 `ordered_ids` arrives and is deliberately ignored: a
                 column is a PARTIAL view of the project, and writing its
                 order to `position` would renumber the whole plan from the
                 few cards one column happened to hold. The board reads
                 `position`; the list owns it. --%>
            <div
              id={"board-column-#{status}"}
              class="flex flex-col gap-2"
              phx-hook="SortableGrid"
              data-sortable="true"
              data-sortable-group={"board-#{@project.uuid}"}
              data-sortable-event="board_move"
              data-sortable-items=".sortable-item"
              data-sortable-handle=".pk-drag-handle"
              data-sortable-scope-status={status}
            >
              <div
                :for={a <- column}
                class="card bg-base-100 border border-base-200 shadow-sm overflow-hidden sortable-item"
                data-id={a.uuid}
              >
                <div class="card-body p-3 gap-2">
                  <div class="flex items-start gap-2">
                    <span
                      class="pk-drag-handle cursor-grab text-base-content/30 hover:text-base-content shrink-0 mt-0.5"
                      title={gettext("Drag to another column")}
                    >
                      <.icon name="hero-bars-2" class="w-3.5 h-3.5" />
                    </span>
                    <.smart_link
                      navigate={Paths.edit_assignment(a.project_uuid, a.uuid)}
                      emit={
                        {PhoenixKitProjects.Web.AssignmentFormLive,
                         %{"live_action" => "edit", "project_id" => a.project_uuid, "id" => a.uuid}}
                      }
                      embed_mode={@embed_mode}
                      class="text-sm font-medium link link-hover leading-snug min-w-0"
                    >
                      {Assignment.label(a, L10n.current_content_lang())}
                    </.smart_link>
                  </div>

                  <div class="flex flex-wrap items-center gap-1">
                    <span
                      :if={@fx.priorities and a.priority != "normal"}
                      class={["badge badge-xs gap-1", priority_class(a.priority)]}
                    >
                      <.icon name="hero-flag" class="w-3 h-3" /> {priority_label(a.priority)}
                    </span>
                    <span
                      :for={label <- Enum.take(Map.get(@assignment_labels, a.uuid, []), 2)}
                      :if={@fx.labels}
                      class={["badge badge-xs", label.color]}
                    >
                      {label.name}
                    </span>
                    <span
                      :if={@fx.labels and length(Map.get(@assignment_labels, a.uuid, [])) > 2}
                      class="badge badge-ghost badge-xs"
                    >
                      +{length(Map.get(@assignment_labels, a.uuid, [])) - 2}
                    </span>
                  </div>

                  <%!-- Ownership gets its own anchored row rather than a
                       fifth badge in the pile: the eye learns one place to
                       look. "Unassigned" is shown, not hidden — on a board
                       that is the most actionable thing a card can say. --%>
                  <div class="flex items-center justify-between gap-2">
                    <% b_atype = assignee_type(a) %>
                    <span
                      :if={@fx.assignees and b_atype}
                      class="inline-flex items-center gap-1 text-xs min-w-0 opacity-80"
                    >
                      <.icon name={assignee_icon(a)} class="w-3.5 h-3.5 shrink-0" />
                      <span class="truncate">{assignee_label(a)}</span>
                    </span>
                    <span
                      :if={@fx.assignees and is_nil(b_atype)}
                      class="inline-flex items-center gap-1 text-xs text-warning/80"
                    >
                      <.icon name="hero-user-circle" class="w-3.5 h-3.5 shrink-0" />
                      {gettext("Unassigned")}
                    </span>

                    <div class="ml-auto shrink-0">
                      <%= cond do %>
                        <% a.status == "todo" and @fx.in_progress -> %>
                          <button phx-click="start_task" phx-value-uuid={a.uuid} phx-disable-with="…" class="btn btn-warning btn-xs">
                            {gettext("Start")}
                          </button>
                        <% a.status in ["todo", "in_progress"] -> %>
                          <button phx-click="complete" phx-value-uuid={a.uuid} phx-disable-with="…" class="btn btn-success btn-xs">
                            <.icon name="hero-check" class="w-3.5 h-3.5" />
                          </button>
                        <% a.status == "done" -> %>
                          <button phx-click="reopen" phx-value-uuid={a.uuid} phx-disable-with="…" class="btn btn-ghost btn-xs">
                            {gettext("Reopen")}
                          </button>
                        <% true -> %>
                      <% end %>
                    </div>
                  </div>
                </div>

                <%!-- Reads as the bottom border filling up, without being a
                     border — `border-color` carries theme and radius
                     meaning, a fill strip is data.

                     Rendered only when this task is actually tracked: an
                     empty track says "0%" when the truth is "nobody is
                     measuring", and a row of empty tracks teaches people to
                     stop seeing them. A full bar outside the Done column is
                     left looking finished on purpose — that contradiction
                     is worth seeing, not smoothing over. --%>
                <div :if={@fx.progress and a.track_progress} class="h-1 bg-base-300">
                  <div
                    class={[
                      "h-full transition-all",
                      if(a.status == "done", do: "bg-success", else: "bg-primary")
                    ]}
                    style={"width: #{clamp_pct(a.progress_pct)}%"}
                  >
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

           <%!-- Timeline tab wrapper (below): the gantt is
           lazy-mounted on first activation and then kept (so its own zoom/expand
           survive switching back). It's a nested LiveView with its own
           PubSub/state — when the show page is itself embedded this is a
           nested-within-nested `live_render`, which is fine (server-rendered
           SVG; only the popover/auto-scroll need the gantt JS hooks in the
           host). `headless` drops its back-link since the tabs replace it. --%>
      <div :if={not @is_template} class={if(@active_tab != :gantt, do: "hidden")}>
        <%= if @gantt_mounted? do %>
          {live_render(@socket, PhoenixKitProjects.Web.ProjectGanttLive,
            id: "project-gantt-live-#{@project.uuid}",
            session: %{
              "id" => @project.uuid,
              "headless" => true,
              # No wrapper padding — the show page already pads this content area;
              # the gantt's own `px-4 py-6` would double it and push the chart down.
              "wrapper_class" => "",
              "locale" => L10n.current_content_lang(),
              # Forward the viewer so the nested gantt reconstructs the same
              # user/scope across this second `live_render` hop (see
              # `WebHelpers.assign_embed_user/2`). Bracket access (not `@`) so
              # an off-router mount missing the assign degrades to nil rather
              # than raising — matches the module's no-bang-form convention.
              "current_user_uuid" =>
                assigns[:phoenix_kit_current_user] && assigns[:phoenix_kit_current_user].uuid,
              # Forward the emit contract too: when the show page is itself
              # emit-embedded, its tabs must emit to the same host popup, not
              # fall back to top-level push_navigate (which would yank the
              # host page).
              "mode" => @embed_mode,
              "pubsub_topic" => @embed_pubsub_topic,
              "frame_ref" => @embed_frame_ref
            })}
        <% end %>
      </div>

      <%!-- Calendar tab — same lazy-mount/keep pattern as the gantt tab (its
           month navigation survives switching back). A nested LiveView with its
           own PubSub/state, server-rendered month grid — no JS required. --%>
      <div :if={not @is_template} class={if(@active_tab != :calendar, do: "hidden")}>
        <%= if @calendar_mounted? do %>
          {live_render(@socket, PhoenixKitProjects.Web.ProjectCalendarLive,
            id: "project-calendar-live-#{@project.uuid}",
            session: %{
              "id" => @project.uuid,
              "headless" => true,
              # No wrapper padding — the show page already pads this content area.
              "wrapper_class" => "",
              "locale" => L10n.current_content_lang(),
              # Forward the viewer so the nested calendar reconstructs the same
              # user/scope across this second `live_render` hop.
              "current_user_uuid" =>
                assigns[:phoenix_kit_current_user] && assigns[:phoenix_kit_current_user].uuid,
              # Forward the emit contract too (see the gantt tab above).
              "mode" => @embed_mode,
              "pubsub_topic" => @embed_pubsub_topic,
              "frame_ref" => @embed_frame_ref
            })}
        <% end %>
      </div>
      </div>

      <%!-- Contributed extension tab panes — live_render with the hub's
           embed-session contract, lazy-mounted on first open and kept
           mounted (the gantt/calendar pattern) so tab state survives
           switching. Rendered OUTSIDE the tasks gate: a tasks-off project
           still shows its Client/Sites/… tabs. --%>
      <%= for tab <- @ext_tabs do %>
        <div :if={MapSet.member?(@ext_mounted, tab.id)} class={if(@active_tab != tab.id, do: "hidden")}>
          {live_render(@socket, tab.lv,
            id: "ext-tab-#{tab.id}-#{@project.uuid}",
            session: %{
              "project_uuid" => @project.uuid,
              "ext_key" => tab.ext_key,
              "instance_key" => "default",
              "config" => tab.config,
              "can_write" => ext_tab_can_write(assigns, tab),
              "locale" => L10n.current_content_lang(),
              "wrapper_class" => "",
              "current_user_uuid" =>
                assigns[:phoenix_kit_current_user] && assigns[:phoenix_kit_current_user].uuid,
              "mode" => @embed_mode,
              "pubsub_topic" => @embed_pubsub_topic,
              "frame_ref" => @embed_frame_ref
            })}
        </div>
      <% end %>

      <%!-- ── The Comments tab ── the project's own thread, inline (task
           threads keep the drawer the row icons open). Switched by the
           project's Discussions extension. --%>
      <div :if={@comments_enabled} class={[top_tab != :comments && "hidden"]}>
        <%= if @comments_enabled and top_tab == :comments and comments_available?() do %>
          <.live_component
            module={PhoenixKitComments.Web.CommentsComponent}
            id={"comments-tab-project-#{@project.uuid}"}
            resource_type="project"
            resource_uuid={@project.uuid}
            current_user={assigns[:phoenix_kit_current_user]}
            show_title={false}
            show_likes={true}
          />
        <% end %>
      </div>

      <%!-- Start-project modal — date editable so the user can backdate
           an already-running project or queue a future start. The
           form's `phx-change="noop"` prevents the LV from rebuilding
           the changeset on each keystroke (no live validation needed
           for a single date input); submit goes via `phx-submit`. --%>
      <%= if @start_modal_open do %>
        <dialog open class="modal modal-open" phx-window-keydown="close_start_modal" phx-key="Escape">
          <div class="modal-box max-w-md">
            <h3 class="font-bold text-lg">{gettext("Start project")}</h3>
            <p class="text-sm text-base-content/70 mt-1">
              {gettext("Pick the date and time this project starts. Defaults to right now; backdate it if work began earlier, or pick a future moment if you're queueing it up.")}
            </p>

            <.form for={@start_form} phx-submit="confirm_start_project" class="flex flex-col gap-3 mt-4">
              <.input field={@start_form[:start_at]} type="datetime-local" label={gettext("Start date and time")} required />

              <div class="modal-action">
                <button
                  type="button"
                  phx-click="close_start_modal"
                  class="btn btn-ghost btn-sm"
                >
                  {gettext("Cancel")}
                </button>
                <button
                  type="submit"
                  phx-disable-with={gettext("Starting…")}
                  class="btn btn-success btn-sm"
                >
                  <.icon name="hero-play" class="w-4 h-4" /> {gettext("Start project")}
                </button>
              </div>
            </.form>
          </div>
          <button type="button" phx-click="close_start_modal" class="modal-backdrop" aria-label={gettext("Close")}></button>
        </dialog>
      <% end %>

      <%!-- Slide-in comments drawer. Right-side fixed panel that
           hosts `PhoenixKitComments.Web.CommentsComponent` for either
           the project or one of its assignments. The component is
           keyed on `{type, uuid}` so opening a different resource
           re-mounts with its own state instead of leaking the
           previous resource's reply-in-progress / pagination.

           Esc + backdrop click both fire `close_comments`. The
           component's "comments_updated" message is unhandled here
           (we don't need to react to project-level comment counts
           in the timeline yet) — the catch-all `handle_info` clause
           logs it at debug and moves on. --%>
      <%!-- z-[60] / z-[70] so we paint over the admin header
           (`fixed top-0 z-50` in the layout wrapper). At z-40 the
           backdrop sat behind the header and looked broken. --%>
      <%= if @comments_resource do %>
        <div
          class="fixed inset-0 z-[60] bg-black/40"
          phx-click="close_comments"
          phx-window-keydown="close_comments"
          phx-key="Escape"
          aria-hidden="true"
        ></div>

        <aside
          class="fixed top-0 right-0 z-[70] h-screen w-full max-w-md bg-base-100 shadow-2xl flex flex-col"
          role="dialog"
          aria-modal="true"
          aria-label={gettext("Comments")}
        >
          <header class="flex items-start gap-2 p-4 border-b border-base-200 shrink-0">
            <div class="flex-1 min-w-0">
              <div class="text-xs uppercase tracking-wide text-base-content/60">
                <%= if @comments_resource.type == "project" do %>
                  {gettext("Project")}
                <% else %>
                  {gettext("Task")}
                <% end %>
              </div>
              <h2 class="font-bold text-lg truncate">{@comments_resource.title}</h2>
            </div>
            <button
              type="button"
              phx-click="close_comments"
              class="btn btn-ghost btn-sm btn-square"
              aria-label={gettext("Close")}
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </header>

          <div class="flex-1 min-h-0 overflow-y-auto p-4">
            <.live_component
              module={PhoenixKitComments.Web.CommentsComponent}
              id={"comments-drawer-#{@comments_resource.type}-#{@comments_resource.uuid}"}
              resource_type={@comments_resource.type}
              resource_uuid={@comments_resource.uuid}
              current_user={assigns[:phoenix_kit_current_user]}
              title=""
              show_likes={true}
            />
          </div>
        </aside>
      <% end %>

      <%!-- The page's own drawer host (`:popup` mode — a router mount; an
           embed emits to its host's popup instead). Every "Add task" /
           "Edit" / "More options" on this page opens the form here as a
           right-hand sheet over the plan; saves close it and the list
           reloads through the content broadcast it already listens to. --%>
      <%= if @embed_mode == :popup and is_binary(@project.uuid) do %>
        {live_render(@socket, PhoenixKitProjects.Web.PopupHostLive,
          id: "project-popup-#{@project.uuid}",
          session: %{
            "pubsub_topic" => @embed_pubsub_topic,
            "placement" => "end",
            "wrapper_class" => "contents",
            "locale" => L10n.current_content_lang(),
            "current_user_uuid" =>
              assigns[:phoenix_kit_current_user] && assigns[:phoenix_kit_current_user].uuid
          })}
      <% end %>
    </div>
    """
  end
end
