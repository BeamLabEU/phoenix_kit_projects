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

  alias PhoenixKit.Users.Auth.User, as: AuthUser
  alias PhoenixKit.Utils.Routes

  alias PhoenixKitProjects.{
    Activity,
    Assignees,
    Authz,
    Extensions,
    Features,
    Handoffs,
    Health,
    Invoicing,
    L10n,
    Labels,
    Ledger,
    ListControls,
    MoveLock,
    Paths,
    Portal,
    Projects,
    Statuses
  }

  alias PhoenixKitProjects.Web.Components.{ConfirmAction, MoveProject}
  alias PhoenixKitProjects.Web.Crumbs

  alias PhoenixKitProjects.Extensions.Registry, as: ExtRegistry
  alias PhoenixKitProjects.Outline
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Refs
  alias PhoenixKitProjects.Schemas.{Assignment, Project}
  alias PhoenixKitProjects.Schemas.Task, as: TaskSchema
  alias PhoenixKitProjects.TaskNotes
  alias PhoenixKitProjects.Web.Components.AssignmentStatusBadge
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers
  alias PhoenixKitProjects.Web.OutlineList

  # Schedule/assignee helpers shared with ProjectGanttLive — imported so the
  # template's bare calls resolve. See PhoenixKitProjects.Web.Helpers.
  import PhoenixKitProjects.Web.Helpers,
    only: [assignee_label: 1, task_counts_weekends?: 2, assignment_hours: 2]

  import PhoenixKitWeb.Components.Core.TimeDisplay, only: [time_ago: 1]
  import PhoenixKitProjects.Web.Components.TaskTimes, only: [deadline_chip: 1, planned_chip: 1]
  import Ecto.Query, only: [from: 2]

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

  # The task view in this page's drawer (`AssignmentViewLive`) asks the page
  # for the steps the page owns — the "Ready to start" and "Done" dialogs,
  # a reopen's "why" — on the drawer's topic (`WebHelpers.emit_intent/3`).
  # The router page's topic is its own; an embed's is the host's.
  # An embed mounts through the router clause first, so this runs twice
  # with the same topic: subscribe once, or every step would run twice.
  defp subscribe_intents(socket) do
    case socket.assigns[:embed_pubsub_topic] do
      topic when is_binary(topic) and topic != "" ->
        if connected?(socket) and socket.assigns[:intent_topic] != topic do
          ProjectsPubSub.subscribe(topic)
        end

        assign(socket, :intent_topic, topic)

      _ ->
        socket
    end
  end

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
     |> subscribe_intents()
     |> assign(
       router_mounted?: false,
       gantt_mounted?: false,
       calendar_mounted?: false,
       history_mounted?: false,
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
      |> subscribe_intents()
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
              history_mounted?: active_tab == :history,
              editing_duration_uuid: nil,
              start_modal_open: false,
              start_form: to_form(%{"start_at" => default_start_at_local()}),
              # Comments drawer state. `comments_resource` is `nil` when
              # closed; a `%{type, uuid, title}` map when open. The
              # `CommentsComponent` is keyed on `{type, uuid}` so opening
              # different resources doesn't reuse stale state.
              comments_resource: nil,
              notes_summary_preview: nil,
              # Availability ∧ the per-project "discussions" bridge toggle.
              comments_enabled: comments?,
              # The task view the Tasks top tab reopens (the last one shown).
              task_view: (top_tab_of(active_tab) == :tasks && active_tab) || :list,
              project_comment_count: 0,
              assignment_comment_counts: %{},
              assignment_note_counts: %{},
              # Skeleton defaults overwritten by the load_* helpers below;
              # they keep the assigns coherent if either helper short-circuits.
              assignments: [],
              deps_by_assignment: %{},
              link_pairs: [],
              linked_uuids: MapSet.new(),
              held_by: %{},
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
              move_locks: %{},
              # Work-ledger state (Step 10): totals strip + per-task logged
              # chips, filled by load_ledger/1 below (nil/empty when the
              # `ledger` flag is off). `log_time_uuid` scopes the modal to a
              # task; nil logs against the project overall.
              ledger_totals: nil,
              ledger_minutes: %{},
              ledger_tokens: %{},
              log_time_open: false,
              log_time_uuid: nil,
              reopen_uuid: nil,
              reopen_task: nil,
              next_up: nil,
              assignment_labels: %{},
              invoice_ready?: false
            )
            |> WebHelpers.attach_open_embed_hook()

          {:ok,
           socket
           |> load_assignments()
           |> load_comment_counts()
           |> load_ledger()
           |> load_labels()
           |> focus_task(Map.get(params, "task"))}
        else
          {:ok,
           socket
           |> assign(not_found_assigns())
           |> put_flash(:error, gettext("Project not found."))
           |> WebHelpers.close_or_navigate(Paths.projects())}
        end
    end
  end

  # `?task=<uuid or ACME-42>` (what a link to a task carries, see `Paths.task/2`):
  # the row is ringed, the lens widens if it was hiding the row, the URL's
  # `#task-<uuid>` scrolls to it, and the page's drawer opens the task
  # (`popup_open/1`). A uuid that is not a row of this project is ignored.
  defp focus_task(socket, ref) when is_binary(ref) do
    case find_task(socket.assigns.assignments, ref, socket.assigns.project) do
      nil ->
        socket

      a ->
        socket = assign(socket, focus_task: a.uuid)

        if Enum.any?(socket.assigns.visible_assignments, &(&1.uuid == a.uuid)),
          do: socket,
          else: socket |> assign(list_status: "all") |> apply_list_lens()
    end
  end

  defp focus_task(socket, _uuid), do: socket

  # By uuid, or by ref (`ACME-42`) when the key is this project's — its
  # current one or one it was renamed from.
  defp find_task(assignments, ref, project) do
    case Refs.parse(ref) do
      {:uuid, uuid} ->
        Enum.find(assignments, &(&1.uuid == uuid))

      {:task, key, number} ->
        if key == project.key or key in Projects.former_keys(project),
          do: Enum.find(assignments, &(&1.number == number))

      _ ->
        nil
    end
  end

  # What the drawer opens with when the page was reached through a link to
  # a task: the task's view, as the row's title opens it.
  defp popup_open(%{focus_task: uuid, project: project}) when is_binary(uuid) do
    %{
      "lv" => Atom.to_string(PhoenixKitProjects.Web.AssignmentViewLive),
      "session" => %{"project_id" => project.uuid, "id" => uuid}
    }
  end

  defp popup_open(_assigns), do: nil

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
      outline_style: :cards,
      outline_depths: %{},
      outline_counts: %{},
      outline_parents: MapSet.new(),
      outline_held: [],
      outline_lines: [],
      outline_can: %{edit: false, delete: false, tick: false, nest: false},
      outline_fx: nil,
      outline_dom_id: "pkp-outline",
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
      history_mounted?: false,
      assignments: [],
      deps_by_assignment: %{},
      link_pairs: [],
      linked_uuids: MapSet.new(),
      held_by: %{},
      total_tasks: 0,
      done_tasks: 0,
      progress_pct: 0,
      schedule: nil,
      editing_duration_uuid: nil,
      start_modal_open: false,
      start_form: to_form(%{"start_at" => default_start_at_local()}),
      comments_resource: nil,
      notes_summary_preview: nil,
      comments_enabled: false,
      task_view: :list,
      project_comment_count: 0,
      assignment_comment_counts: %{},
      assignment_note_counts: %{},
      statuses_available: false,
      current_status: nil,
      status_options: [],
      expanded_subprojects: MapSet.new(),
      subproject_summaries: %{},
      subproject_child_tasks: %{},
      move_locks: %{},
      ledger_totals: nil,
      ledger_minutes: %{},
      ledger_tokens: %{},
      log_time_open: false,
      log_time_uuid: nil,
      reopen_uuid: nil,
      reopen_task: nil,
      next_up: nil,
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

  # Announced for consumers outside the page; its own reloads follow
  # `:assignment_updated` / `:assignment_reordered`.
  def handle_info({:projects, :assignment_status_changed, _payload}, socket),
    do: {:noreply, socket}

  # A step asked for by the task view in the drawer: run as this page's own
  # event, through the same feature gate and permission check as a click.
  def handle_info({:projects, :intent, %{event: event, uuid: uuid}}, socket)
      when event in ~w(ask_ready complete start_task ask_reopen) and is_binary(uuid) do
    case handle_event(event, %{"uuid" => uuid}, socket) do
      {:noreply, socket} -> {:noreply, socket}
      {:reply, _reply, socket} -> {:noreply, socket}
    end
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

    # A task with subtasks is the sum of them, so the project counts the
    # rows with nothing under them (`Outline.leaves/1`).
    leaves = Outline.leaves(assignments)
    total = length(leaves)
    done = Enum.count(leaves, &(&1.status == "done"))
    # Rollup is the average of all assignments' `progress_pct` values
    # — a half-finished task contributes 50%, not 0%. Auto-completion
    # (`recompute_project_completion/1`) stays binary: a project only
    # auto-flags as completed when every assignment is `status: "done"`,
    # not when the rollup happens to hit 100% by other means.
    progress_sum = Enum.reduce(leaves, 0, &(&1.progress_pct + &2))
    schedule = calculate_schedule(socket.assigns.project, assignments)

    # Sub-project rollup display data (V127): one batched summary query over
    # all embedded child projects, keyed by the linking-assignment uuid so the
    # row can show the child's task count + progress. Expanded rows also get a
    # refreshed child task list so a change in the child reflects immediately.
    subproject_summaries = load_subproject_summaries(assignments)

    # One read for every expanded child's own rows (it was one per child,
    # on every refresh); what is nested under them is not shown here.
    child_assignments =
      Projects.assignments_by_project(Enum.map(expanded_subs, & &1.child_project_uuid),
        depth: 1
      )

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
      Enum.count(leaves, fn a ->
        Assignment.subproject?(a) and empty_subproject?(Map.get(subproject_summaries, a.uuid))
      end)

    progress_total = max(total - empty_subs, 0)

    socket
    |> assign(
      assignments: assignments,
      deps_by_assignment: deps_by_assignment,
      # The connections the list's hover / trace hook draws (`PkpLinks`):
      # every [before, after] pair on the page, and the tasks that have one.
      link_pairs: link_pairs(deps_by_assignment),
      linked_uuids: linked_uuids(deps_by_assignment),
      held_by:
        held_by(
          assignments ++ Enum.flat_map(Map.values(subproject_child_tasks), & &1),
          deps_by_assignment
        ),
      total_tasks: total,
      done_tasks: done,
      progress_pct: if(progress_total > 0, do: round(progress_sum / progress_total), else: 0),
      schedule: schedule,
      subproject_summaries: subproject_summaries,
      subproject_child_tasks: subproject_child_tasks,
      # Who has each task, as faces (the boss, 2026-10-29) — one batched
      # read for the rows and the expanded children's, refreshed with them.
      assignee_faces:
        Assignees.faces(assignments ++ Enum.flat_map(Map.values(subproject_child_tasks), & &1)),
      move_locks: load_move_locks(socket.assigns.project, assignments)
    )
    |> assign_pending_reviews(project_uuid)
    |> apply_list_lens()
    |> OutlineList.assign_outline()
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
    # The typed list IS the whole project in its own order: there is nothing
    # for a lens or a sort to act on.
    text? = OutlineList.style(socket.assigns.project, socket.assigns.fx, all) == :text

    controls? =
      not text? and
        ListControls.show?(socket.assigns[:list_controls] || ListControls.read(), counts)

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

  # A drag moves a row among its siblings and takes its subtasks along: the
  # dropped order sets each row's place among its own siblings, and the
  # outline is then written depth first from that (a subtask dropped above
  # its parent stays under it — nesting is Tab's job, not a drag's).
  defp keep_outline(order, assignments) do
    rank = order |> Enum.with_index() |> Map.new()

    assignments
    |> Enum.sort_by(&Map.get(rank, &1.uuid, 0))
    |> Outline.walk()
    |> Enum.map(fn {a, _depth} -> a.uuid end)
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
    do: Enum.count(assignments, &(&1.status not in ["waiting", "todo", "in_progress", "done"]))

  # From the FIELDS, never from `assignee_type/1` — that returns a
  # translated label ("Person"/"Team"/"Dept"), so matching on it would pick
  # the right icon in English and the fallback in every other language.
  # The board's columns. With the in-progress step off the middle column
  # goes — unless a row still sits there (legacy or flipped mid-flight),
  # so nothing ever disappears from the board.
  defp board_columns(fx, assignments) do
    middle? = fx.in_progress or Enum.any?(assignments, &(&1.status == "in_progress"))

    [
      {"waiting", gettext("Waiting"), "border-t-base-300"},
      {"todo", gettext("Can be started"), "border-t-info"}
    ] ++
      if(middle?, do: [{"in_progress", gettext("In progress"), "border-t-warning"}], else: []) ++
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
        <%!-- The project's key, beside its name (the breadcrumb on the
             standalone page, the h1 in an embed). --%>
        <.ref_chip :if={not @is_template} ref={@project.key} size="md" />
        <%!-- Where the project belongs elsewhere (V26): the order a host
             app made it for, a client folder. A path is the host's own
             page — same tab, written as stored, since it is not one of the
             kit's routes; a web address is someone else's site — a new
             tab, with no way back into this one. --%>
        <.project_link project={@project} />
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
            :if={not @is_template}
            navigate={Paths.api(@project.uuid)}
            emit={{PhoenixKitProjects.Web.ProjectApiLive, %{"id" => @project.uuid}}}
            embed_mode={@embed_mode}
            popup={false}
            icon="hero-key"
            label={gettext("Your API key")}
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
          <%!-- Out of its parent, or under another project — with what it
               takes along (`Components.MoveProject`). --%>
          <MoveProject.locked_menu_item
            :if={is_nil(@project.archived_at) and @move_locks[@project.uuid]}
            reason={@move_locks[@project.uuid]}
            label={gettext("Move…")}
          />
          <.table_row_menu_button
            :if={is_nil(@project.archived_at) and !@move_locks[@project.uuid]}
            phx-click="move_project_open"
            phx-value-uuid={@project.uuid}
            icon="hero-arrows-right-left"
            label={gettext("Move…")}
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
                {ConfirmAction.ask("archive_project",
                  title: gettext("Archive project"),
                  message: gettext("Archive this project? It will be hidden from the main lists but kept in the database."),
                  confirm: gettext("Archive")
                )}
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

  # The host's move lock for the project and its sub-project rows, asked
  # once per load (`MoveLock.reasons/1` is one call for the whole list).
  defp load_move_locks(project, assignments) do
    children =
      for a <- assignments, Assignment.subproject?(a), child = a.child_project, do: child

    MoveLock.reasons([project | children])
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

  # Ticking a task ticks everything under it. When some of that is another
  # person's work, the list asks first and names the count.
  defp complete_or_ask(socket, a, params) do
    below = Outline.open_below(a, current_person_uuid(socket))

    if below.others > 0 and params["force"] != "1" do
      {:noreply,
       ConfirmAction.request(
         socket,
         %{
           "event" => "complete",
           "uuid" => a.uuid,
           "force" => "1",
           "title" => gettext("Tick the subtasks too?"),
           "message" =>
             ngettext(
               "This also ticks 1 open subtask, assigned to someone else.",
               "This also ticks %{count} open subtasks, %{others} of them assigned to someone else.",
               below.count,
               others: below.others
             ),
           "confirm" => gettext("Tick all")
         },
         ["complete"]
       )}
    else
      # Asked first when the completion would hand work on: nothing is
      # written — and nobody told — until "next up" is confirmed.
      case a.status != "done" and next_up_for(socket, a, params) do
        %{} = next_up -> {:noreply, assign(socket, next_up: next_up)}
        _ -> socket |> complete_assignment(a, below) |> maybe_sync_and_reload()
      end
    end
  end

  defp complete_assignment(socket, a, below) do
    attrs = %{
      status: "done",
      progress_pct: 100,
      completed_by_uuid: Activity.actor_uuid(socket),
      completed_at: DateTime.utc_now()
    }

    update_assignment_with_activity(socket, a, attrs, "projects.assignment_completed",
      metadata: %{
        "task" => Assignment.label(a),
        "project" => socket.assigns.project.name,
        "subtasks_ticked" => below.count
      }
    )
  end

  # ── Next up ─────────────────────────────────────────────────────────
  #
  # One dialog, two ways in. Completing a task that other tasks wait on
  # asks first (`:complete`): it lists the not-started tasks nothing would
  # hold up once it is done (`Handoffs.would_ready/2`), each released
  # ("can be started", its people told) unless it is kept idle. A waiting
  # task's "Ready to start" opens it for that one task (`:release`).
  # Either way each task shows who it is assigned to and who would be
  # notified — each person ticked by default, untick someone (away this
  # week) and they are not told — and a comment for whoever does it, which
  # rides along in the notice. Nothing is written until it is confirmed: a
  # slip of the finger must not tell ten people to start.
  defp next_up_for(socket, %Assignment{} = a, params) do
    shown = Map.new(socket.assigns[:assignments] || [], &{&1.uuid, &1})

    # Only what this page draws: a task inside an expanded sub-project is
    # its own project's business.
    rows =
      a.project_uuid
      |> Handoffs.would_ready(a.uuid)
      |> Enum.flat_map(&List.wrap(Map.get(shown, &1.uuid)))

    if rows != [], do: build_next_up(socket, :complete, a, rows, params["force"] == "1")
  end

  defp build_next_up(socket, mode, %Assignment{} = a, rows, force?) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    project = socket.assigns.project

    %{
      mode: mode,
      task_uuid: a.uuid,
      force: force?,
      after: Assignment.label(a, L10n.current_content_lang()),
      uuids: Enum.map(rows, & &1.uuid),
      can:
        Map.new(rows, fn row ->
          {row.uuid,
           %{
             release: may_release_next_up?(scope, project, row),
             comment: may_comment_next_up?(socket, scope, project, row)
           }}
        end),
      recipients: next_up_recipients(socket, rows),
      muted: %{},
      idle: []
    }
  end

  defp may_release_next_up?(scope, project, row),
    do: is_nil(row.child_project_uuid) and Authz.can?(scope, project, :update_status, row)

  defp may_comment_next_up?(socket, scope, project, row),
    do: socket.assigns.comments_enabled and Authz.can?(scope, project, :comment, row)

  # Who each task's notice would reach: its person, or its team's or
  # department's people (`People.assignee_user_uuids/1`, the hand-off's own
  # list), less the viewer (nobody hears of their own act) and anyone who
  # may not open the project (`Notices.notify/3` would skip them anyway).
  # Names read in one go, sorted.
  defp next_up_recipients(socket, rows) do
    actor = Activity.actor_uuid(socket)
    project = socket.assigns.project

    by_row =
      Map.new(rows, fn row ->
        {row.uuid, PhoenixKitProjects.People.assignee_user_uuids(row) -- [actor]}
      end)

    visible =
      by_row
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.filter(&PhoenixKitProjects.Notices.may_view?(&1, project))

    names = user_names(visible)

    Map.new(by_row, fn {uuid, users} ->
      people =
        for user <- users, user in visible do
          %{uuid: user, name: Map.get(names, user) || gettext("Someone")}
        end

      {uuid, Enum.sort_by(people, &String.downcase(&1.name))}
    end)
  end

  defp user_names([]), do: %{}

  defp user_names(uuids) do
    from(u in AuthUser, where: u.uuid in ^uuids)
    |> PhoenixKit.RepoHelper.repo().all()
    |> Map.new(&{&1.uuid, AuthUser.display_name(&1)})
  rescue
    _ -> %{}
  end

  # The offered rows still on the page and still not started, in order.
  defp next_up_rows(nil, _assignments), do: []

  defp next_up_rows(%{uuids: uuids}, assignments),
    do: Enum.filter(assignments, &(&1.uuid in uuids and &1.status in ["waiting", "todo"]))

  # Whether the dialog will release `row` on confirm: not kept idle, and
  # the viewer may change its status.
  defp next_up_release?(%{idle: idle, can: can}, row),
    do: row.uuid not in idle and get_in(can, [row.uuid, :release]) == true

  defp next_up_muted?(%{muted: muted}, row_uuid, user_uuid),
    do: user_uuid in Map.get(muted, row_uuid, [])

  # What each released task's notice carries: only the ticked people, and
  # the comment typed for it.
  defp next_up_overrides(next_up, notes) do
    notes = if is_map(notes), do: notes, else: %{}

    Map.new(next_up.uuids, fn uuid ->
      ticked =
        next_up.recipients
        |> Map.get(uuid, [])
        |> Enum.map(& &1.uuid)
        |> Kernel.--(Map.get(next_up.muted, uuid, []))

      {uuid, %{only: ticked, note: next_up_note(notes[uuid])}}
    end)
  end

  defp next_up_note(text) when is_binary(text),
    do: text |> String.trim() |> String.slice(0, 2_000)

  defp next_up_note(_), do: ""

  # Confirm. `:complete` — the rows kept idle go back to waiting first (a
  # released one is never told), then the completion, then the releases;
  # `:release` — the one task. One hand-off pass (`Handoffs.batch/1`), so
  # each person is told once, naming the task just done; only the ticked
  # people, with the comment (`Handoffs.with_overrides/2`). Every right is
  # checked again now: one seen when the dialog opened is not trusted.
  defp confirm_next_up(socket, %Assignment{} = a, next_up, notes) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    project = socket.assigns.project
    rows = next_up_rows_from(socket, next_up.uuids)
    may? = &may_release_next_up?(scope, project, &1)

    Handoffs.with_overrides(next_up_overrides(next_up, notes), fn ->
      Handoffs.batch(fn ->
        case next_up.mode do
          :release ->
            {:ok, socket, release_next_up(socket, rows, next_up, may?)}

          :complete ->
            complete_and_release(socket, a, rows, next_up, may?)
        end
      end)
    end)
  end

  defp complete_and_release(socket, a, rows, next_up, may?) do
    for row <- rows,
        row.uuid in next_up.idle,
        row.status == "todo",
        may?.(row),
        do: set_readiness(socket, row, "waiting")

    below = Outline.open_below(a, current_person_uuid(socket))

    with {:ok, socket} <- complete_assignment(socket, a, below) do
      {:ok, socket, release_next_up(socket, rows, next_up, may?)}
    end
  end

  defp release_next_up(socket, rows, next_up, may?) do
    rows
    |> Enum.filter(&(&1.uuid not in next_up.idle and &1.status == "waiting" and may?.(&1)))
    |> Enum.count(&(set_readiness(socket, &1, "todo") == :ok))
  end

  # Releases a waiting task ("can be started" — `Handoffs` tells its people)
  # or puts one back to idle (nobody told). The row is the history; the
  # notice is the hand-off's, so this entry names no target.
  defp set_readiness(socket, %Assignment{} = a, to) when to in ["waiting", "todo"] do
    action =
      if to == "todo", do: "projects.assignment_made_ready", else: "projects.assignment_made_idle"

    case Projects.update_assignment_status(a, %{status: to}) do
      {:ok, _} ->
        Activity.log(action,
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: a.uuid,
          metadata: %{"task" => Assignment.label(a), "from" => a.status, "to" => to},
          tell: false
        )

        :ok

      {:error, _} ->
        Activity.log_failed(action,
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: a.uuid,
          metadata: %{"task" => Assignment.label(a)}
        )

        :error
    end
  end

  # Each comment is kept on its task's thread too, when the project has
  # discussions — flagged as a hand-off note, so the thread does not tell
  # the task's people a second time (the notice already quoted it to the
  # ticked ones; the unticked are told nothing).
  defp post_next_up_comments(socket, %{uuids: uuids}, notes) when is_map(notes) do
    actor = Activity.actor_uuid(socket)
    scope = socket.assigns[:phoenix_kit_current_scope]
    project = socket.assigns.project
    rows = Map.new(next_up_rows_from(socket, uuids), &{&1.uuid, &1})

    posted =
      for {uuid, text} <- notes,
          %Assignment{} = row <- [Map.get(rows, uuid)],
          text = next_up_note(text),
          text != "",
          is_binary(actor),
          may_comment_next_up?(socket, scope, project, row),
          match?(
            {:ok, _},
            PhoenixKitComments.create_comment("assignment", uuid, actor, %{
              content: text,
              metadata: %{"handoff_note" => true}
            })
          ),
          do: uuid

    socket = if posted == [], do: socket, else: load_comment_counts(socket)
    {socket, length(posted)}
  end

  defp post_next_up_comments(socket, _next_up, _notes), do: {socket, 0}

  # Removes one task with its notices and history line; the caller
  # reloads.
  defp remove_task(socket, %Assignment{uuid: uuid} = a) do
    case PhoenixKitProjects.Notices.removing(a, Activity.actor_uuid(socket), fn ->
           Projects.delete_assignment(a)
         end) do
      {:ok, _} ->
        # The task is gone now: the row names its project itself, so the
        # project's History still finds it.
        Activity.log("projects.assignment_removed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: uuid,
          metadata: %{"task" => Assignment.label(a), "project_uuid" => a.project_uuid}
        )

        recompute_owning_subproject(socket, a)
        {:ok, WebHelpers.notify_deleted(socket, :assignment, uuid)}

      {:error, _} ->
        Activity.log_failed("projects.assignment_removed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: uuid,
          metadata: %{"task" => Assignment.label(a)}
        )

        {:error, socket}
    end
  end

  defp next_up_rows_from(socket, uuids),
    do: Enum.filter(socket.assigns[:assignments] || [], &(&1.uuid in uuids))

  defp next_up_flash(socket, 0, 0), do: socket

  defp next_up_flash(socket, released, sent) do
    message =
      [
        released > 0 &&
          ngettext(
            "1 task can be started now.",
            "%{count} tasks can be started now.",
            released
          ),
        sent > 0 && ngettext("1 comment sent.", "%{count} comments sent.", sent)
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" ")

    put_flash(socket, :info, message)
  end

  defp current_person_uuid(socket) do
    case Activity.actor_uuid(socket) do
      nil ->
        nil

      user_uuid ->
        case PhoenixKitProjects.People.get_person_by_user_uuid(user_uuid, preload: []) do
          %{uuid: uuid} -> uuid
          _ -> nil
        end
    end
  rescue
    _ -> nil
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
  # Core's `PhoenixKitWeb.Components.Core.Input.translate_error/1` (imported
  # by `use PhoenixKitWeb, :live_view`) does the translating, in the
  # "errors" domain of core's catalogue, which owns Ecto's messages.
  defp error_summary(%Ecto.Changeset{errors: errors}, fallback) do
    case errors do
      [] ->
        fallback

      errs ->
        Enum.map_join(errs, ", ", fn {k, {msg, opts}} ->
          "#{humanize_field(k)}: #{translate_error({msg, opts})}"
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

  # "AI notes", with how many and the tokens reported when there are any.
  defp ai_notes_label(0, 0), do: gettext("AI notes")

  defp ai_notes_label(count, tokens) do
    [gettext("AI notes"), count > 0 && to_string(count), tokens > 0 && format_tokens(tokens)]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
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
  attr(:held_by, :map, default: %{})
  # Tasks with a connection: only they get the trace button (`PkpLinks`).
  attr(:linked, :any, default: MapSet.new())
  attr(:ledger_minutes, :map, default: %{})
  attr(:ledger_ai_minutes, :map, default: %{})
  attr(:ledger_tokens, :map, default: %{})
  attr(:assignment_note_counts, :map, default: %{})
  attr(:assignment_labels, :map, default: %{})
  # Who has each task, as faces (`Assignees.faces/2`), keyed by uuid.
  attr(:faces, :map, default: %{})
  # The outline bits of a row (`OutlineList`): permissions, the "3 of 7" of
  # a task with subtasks, folded or not, and whether its title takes the
  # cursor (a row just added). Nil on rows drawn outside the list.
  attr(:ol, :map, default: nil)

  defp task_body(assigns) do
    ~H"""
    <div class="card-body relative py-3 px-4 gap-2 rounded-[inherit]" data-pkp-card={@a.uuid}>
      <%!-- Filled by `PkpLinks` while a connected task is hovered or traced
           ("Waits on", "Unlocks", "Earlier", "Later"): a tab on the card's
           top-left edge, out of the row's flow, so nothing in the row moves
           when it comes and goes. --%>
      <span data-pkp-rel={@a.uuid}></span>
      <%!-- Title row --%>
          <div class="flex items-center justify-between gap-2">
            <div class="flex items-center gap-2 min-w-0 flex-1">
              <span
                :if={@draggable}
                class="pk-drag-handle cursor-grab text-base-content/40 hover:text-base-content shrink-0"
                title={gettext("Drag to reorder")}
              >
                <.icon name="hero-bars-3" class="w-4 h-4" />
              </span>
              <button
                :if={@ol && @ol.count}
                type="button"
                phx-click="outline_fold"
                phx-value-uuid={@a.uuid}
                class="btn btn-ghost btn-xs btn-circle shrink-0"
                title={if @ol.folded, do: gettext("Show subtasks"), else: gettext("Hide subtasks")}
              >
                <.icon name={if @ol.folded, do: "hero-chevron-right", else: "hero-chevron-down"} class="w-4 h-4" />
              </button>
              <.assignment_status_badge :if={not @is_template} status={@a.status} />
              <%!-- The ID opens the task's view, like its title. --%>
              <.smart_link
                :if={not @is_template and Refs.task_ref(@project.key, @a.number)}
                navigate={Paths.view_assignment(@a.project_uuid, @a.uuid)}
                emit={{PhoenixKitProjects.Web.AssignmentViewLive, %{"project_id" => @a.project_uuid, "id" => @a.uuid}}}
                embed_mode={@embed_mode}
                class="shrink-0 hover:underline"
                title={gettext("View the task")}
              >
                <.ref_chip ref={Refs.task_ref(@project.key, @a.number)} />
              </.smart_link>
              <%!-- The title is typed into where it stands (Enter adds the
                   next task, Tab makes it a subtask); the arrow opens the
                   form. Read-only rows keep the title as the link. --%>
              <%= if @ol != nil and @ol.can.edit and not @is_template and @a.task != nil do %>
                <OutlineList.title_input a={@a} can={@ol.can} focus={@ol.focus} fresh={@ol.fresh} />
                <span
                  :if={@ol.count}
                  class="badge badge-sm badge-outline shrink-0"
                  title={gettext("Subtasks done")}
                >
                  {@ol.count.done}/{@ol.count.total}
                </span>
                <.smart_link
                  navigate={Paths.view_assignment(@a.project_uuid, @a.uuid)}
                  emit={
                    {PhoenixKitProjects.Web.AssignmentViewLive,
                     %{"project_id" => @a.project_uuid, "id" => @a.uuid}}
                  }
                  embed_mode={@embed_mode}
                  class="btn btn-ghost btn-xs btn-circle shrink-0"
                  title={gettext("View the task")}
                >
                  <.icon name="hero-eye" class="w-3.5 h-3.5" />
                </.smart_link>
              <% else %>
              <span :if={@ol && @ol.count} class="badge badge-sm badge-outline shrink-0">
                {@ol.count.done}/{@ol.count.total}
              </span>
              <%!-- The title opens the task's view (reading, the next step,
                   the conversation); the row menu's Edit opens the form. --%>
              <.smart_link
                navigate={Paths.view_assignment(@a.project_uuid, @a.uuid)}
                emit={
                  {PhoenixKitProjects.Web.AssignmentViewLive,
                   %{"project_id" => @a.project_uuid, "id" => @a.uuid}}
                }
                embed_mode={@embed_mode}
                class="font-medium truncate min-w-0 link link-hover"
              >
                {TaskSchema.localized_title(@a.task, L10n.current_content_lang())}
              </.smart_link>
              <% end %>
            </div>

            <div class="flex items-center gap-1 shrink-0">
              <%= if not @is_template do %>
                <%!-- Connections are never written on the card: hovering
                     hints at the direct ones, this traces the whole chain
                     (`PkpLinks`, in the browser — no round-trip). --%>
                <button
                  :if={@fx.dependencies and MapSet.member?(@linked, @a.uuid)}
                  type="button"
                  data-pkp-trace={@a.uuid}
                  aria-pressed="false"
                  class="btn btn-ghost btn-xs btn-square text-base-content/50"
                  aria-label={gettext("Trace the chain of “%{task}”", task: Assignment.label(@a, L10n.current_content_lang()))}
                  title={gettext("Trace everything before and after it")}
                >
                  <.icon name="hero-share" class="w-4 h-4" />
                </button>
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
              <% a_note_count = Map.get(@assignment_note_counts, @a.uuid, 0) %>
              <% a_tokens = Map.get(@ledger_tokens, @a.uuid, 0) %>
              <%!-- The row stays simple (the boss, 2026-10-29): the next step
                   and the agent's notes are in the ⋮ menu; the status badge
                   on the left says where the task is. A waiting task is
                   released first — "Ready to start" asks who to tell and
                   takes a comment; a released one is started or done. A
                   status outside the vocabulary (legacy or hand-edited data)
                   gets no step. --%>
              <.table_row_menu id={"assignment-menu-#{@a.uuid}"}>
                <%= if not @is_template do %>
                  <%= cond do %>
                    <% @a.status == "waiting" and @a.child_project_uuid == nil -> %>
                      <.table_row_menu_button
                        phx-click="ask_ready"
                        phx-value-uuid={@a.uuid}
                        icon="hero-play-circle"
                        label={gettext("Ready to start")}
                        title={gettext("Release it: its people are told they can start")}
                      />
                    <% @a.status == "todo" and @fx.in_progress -> %>
                      <.table_row_menu_button
                        phx-click="start_task"
                        phx-value-uuid={@a.uuid}
                        phx-disable-with={gettext("Starting…")}
                        icon="hero-play"
                        label={gettext("Start")}
                      />
                      <.table_row_menu_button
                        phx-click="complete"
                        phx-value-uuid={@a.uuid}
                        phx-disable-with={gettext("Saving…")}
                        icon="hero-check"
                        label={gettext("Mark done")}
                      />
                    <% @a.status in ["todo", "in_progress"] or (@a.status == "waiting" and @a.child_project_uuid != nil) -> %>
                      <.table_row_menu_button
                        phx-click="complete"
                        phx-value-uuid={@a.uuid}
                        phx-disable-with={gettext("Saving…")}
                        icon="hero-check"
                        label={gettext("Mark done")}
                      />
                    <% @a.status == "done" -> %>
                      <.table_row_menu_button
                        phx-click="ask_reopen"
                        phx-value-uuid={@a.uuid}
                        icon="hero-arrow-uturn-left"
                        label={gettext("Reopen")}
                      />
                    <% true -> %>
                  <% end %>
                  <.table_row_menu_divider :if={@a.status in ~w(waiting todo in_progress done)} />
                <% end %>
                <.smart_menu_link
                  navigate={Paths.edit_assignment(@a.project_uuid, @a.uuid)}
                  emit={{PhoenixKitProjects.Web.AssignmentFormLive, %{"live_action" => "edit", "project_id" => @a.project_uuid, "id" => @a.uuid}}}
                  embed_mode={@embed_mode}
                  icon="hero-pencil"
                  label={gettext("Edit")}
                />
                <.table_row_menu_button
                  :if={@fx.ledger and not @is_template}
                  phx-click="open_log_time"
                  phx-value-uuid={@a.uuid}
                  icon="hero-play-circle"
                  label={gettext("Log time")}
                />
                <%!-- The notes thread (`TaskNotes`): what an agent wrote while
                     working, apart from the discussion, with the tokens it
                     reported. Same drawer as the comments, its own anchor. --%>
                <.table_row_menu_button
                  :if={@comments_enabled and not @is_template}
                  phx-click="open_comments"
                  phx-value-type="notes"
                  phx-value-uuid={@a.uuid}
                  phx-value-title={TaskSchema.localized_title(@a.task, L10n.current_content_lang())}
                  icon="hero-cpu-chip"
                  label={ai_notes_label(a_note_count, a_tokens)}
                />
                <.table_row_menu_divider />
                <.table_row_menu_button
                  {ConfirmAction.ask("remove_assignment",
                    uuid: @a.uuid,
                    title: gettext("Remove task"),
                    message: gettext("Remove \"%{title}\"?", title: TaskSchema.localized_title(@a.task, L10n.current_content_lang())),
                    confirm: gettext("Remove")
                  )}
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
            <%!-- The deadline is the promise and the one thing that turns a
                 row red; the planned days are a plan and stay neutral
                 (the boss, 2026-10-29). "Waiting on" and "from …" are no
                 longer said on the row: the status says where it is. --%>
            <%= if @fx[:dates] != false do %>
              <.deadline_chip a={@a} />
              <.planned_chip a={@a} />
            <% end %>
            <%= if @fx.estimates and @editing_duration_uuid == @a.uuid do %>
              <% prefill_dur = @a.estimated_duration || @a.task.estimated_duration %>
              <% prefill_unit = @a.estimated_duration_unit || @a.task.estimated_duration_unit || "hours" %>
              <form id={"duration-#{@a.uuid}"} phx-submit="save_duration" class="flex items-center gap-1">
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
              <%!-- A duration shows once it is set (and stays a click to
                   change); an unset one is set in the task's form, not by
                   a button on every row (Max, 2026-10-14). --%>
              <% dur = format_duration(@a) %>
              <button
                :if={@fx.estimates and dur != "—"}
                phx-click="edit_duration"
                phx-value-uuid={@a.uuid}
                class="badge badge-sm gap-1 cursor-pointer transition-colors badge-outline hover:bg-primary hover:text-primary-content hover:border-primary"
              >
                <.icon name="hero-clock" class="w-3 h-3" /> {dur}
              </button>
            <% end %>

            <%!-- Time shows once some is logged; logging it is in the task's
                 form and its ⋮ menu. --%>
            <%!-- People's time and an agent's are two chips: the first opens
                 the log dialog, the second the agent's notes, where that
                 time was reported. --%>
            <% ai_logged = Map.get(@ledger_ai_minutes, @a.uuid, 0) %>
            <% logged = max(Map.get(@ledger_minutes, @a.uuid, 0) - ai_logged, 0) %>
            <button
              :if={@fx.ledger and not @is_template and logged > 0}
              phx-click="open_log_time"
              phx-value-uuid={@a.uuid}
              title={gettext("Time people logged — click to log more")}
              class="badge badge-sm gap-1 cursor-pointer transition-colors badge-outline hover:bg-primary hover:text-primary-content hover:border-primary"
            >
              <.icon name="hero-user" class="w-3 h-3" /> {format_minutes(logged)}
            </button>
            <button
              :if={@fx.ledger and not @is_template and ai_logged > 0}
              type="button"
              phx-click={if(@comments_enabled, do: "open_comments")}
              phx-value-type="notes"
              phx-value-uuid={@a.uuid}
              phx-value-title={TaskSchema.localized_title(@a.task, L10n.current_content_lang())}
              title={gettext("Time the AI reported — click for its notes")}
              class="badge badge-sm gap-1 cursor-pointer transition-colors badge-outline hover:bg-primary hover:text-primary-content hover:border-primary"
            >
              <.icon name="hero-cpu-chip" class="w-3 h-3" /> {gettext("AI %{amount}", amount: format_minutes(ai_logged))}
            </button>

            <% atype = assignee_type(@a) %>
            <span :if={@fx.assignees and atype} class="inline-flex items-center gap-1">
              <.assignee_faces faces={@faces[@a.uuid]} size="xs" />
              <span class="badge badge-outline badge-sm gap-1">
                <.icon name="hero-user" class="w-3 h-3" /> {atype}: {assignee_label(@a)}
              </span>
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

            <%!-- Only the exception is said: weekdays only is the usual case. --%>
            <span
              :if={@fx.scheduling and task_counts_weekends?(@a, @project)}
              class="badge badge-sm gap-1 badge-info badge-outline"
            >
              <.icon name="hero-calendar" class="w-3 h-3" /> {gettext("incl. weekends")}
            </span>

            <%= if @fx.progress and not @is_template do %>
              <%= if @a.track_progress do %>
                <.form for={%{}} id={"progress-#{@a.uuid}"} phx-change="update_progress" class="flex items-center gap-1">
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
              {PhoenixKit.Users.Auth.User.display_name(@a.completed_by)}<%= if @a.completed_at do %>
                · {L10n.format_month_day_time(@a.completed_at)}
              <% end %>
            </span>
          </div>

          <%!-- Work that started and then had something before it reopened
               is ON HOLD — derived, never stored: it clears itself when what
               it waits on is done again. The tasks it waits for are named in
               the tooltip; connections are never written out on the card
               (hover / trace shows them, `PkpLinks`). --%>
          <% open_deps = Map.get(@held_by, @a.uuid, []) %>
          <div
            :if={@fx.dependencies and @a.status == "in_progress" and open_deps != []}
            class="mt-1"
          >
            <span
              class="badge badge-warning badge-sm gap-1"
              title={
                gettext("On hold — waiting for %{tasks}",
                  tasks:
                    Enum.map_join(
                      open_deps,
                      ", ",
                      &gettext("“%{task}”",
                        task: Assignment.label(&1.depends_on, L10n.current_content_lang())
                      )
                    )
                )
              }
            >
              <.icon name="hero-pause-circle" class="w-3.5 h-3.5" />
              {gettext("On hold")}
            </span>
          </div>
          <%!-- What it depends on, one chip each (× removes the link);
               hovering / tracing shows the rest of the chain (`PkpLinks`). --%>
          <% deps = Map.get(@deps_by_assignment, @a.uuid, []) %>
          <div :if={@fx.dependencies and deps != []} class="flex flex-wrap gap-1 mt-1">
            <%= for dep <- deps do %>
              <span class={[
                "badge badge-outline badge-xs gap-1",
                match?(%{depends_on: %{status: "done"}}, dep) && "opacity-60"
              ]}>
                <.icon
                  name={if(match?(%{depends_on: %{status: "done"}}, dep), do: "hero-check-circle", else: "hero-arrow-right-circle")}
                  class="w-3 h-3"
                />
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
  # The open tasks each row waits on: its own dependencies and those of
  # every task above it (`Handoffs.ready?/2`'s rule) — a subtask of a task
  # put on hold is on hold too.
  defp held_by(rows, deps_by_assignment) do
    parents = Map.new(rows, &{&1.uuid, &1.parent_uuid})

    Map.new(rows, fn row ->
      {row.uuid,
       row.uuid
       |> open_deps_up(parents, deps_by_assignment, 0)
       |> Enum.uniq_by(& &1.depends_on_uuid)}
    end)
  end

  defp link_pairs(deps_by_assignment) do
    for {uuid, deps} <- deps_by_assignment, dep <- deps, do: [dep.depends_on_uuid, uuid]
  end

  defp linked_uuids(deps_by_assignment) do
    deps_by_assignment
    |> link_pairs()
    |> List.flatten()
    |> MapSet.new()
  end

  defp open_deps_up(nil, _parents, _deps, _depth), do: []
  defp open_deps_up(_uuid, _parents, _deps, depth) when depth > 100, do: []

  defp open_deps_up(uuid, parents, deps, depth) do
    own =
      deps
      |> Map.get(uuid, [])
      |> Enum.reject(&match?(%{depends_on: %{status: "done"}}, &1))

    own ++ open_deps_up(Map.get(parents, uuid), parents, deps, depth + 1)
  end

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
  # Closing a dialog is never gated: it changes nothing, and a feature
  # switched off (in another session) while its dialog is open would
  # otherwise refuse every Cancel, Escape and backdrop click.
  @gated_events %{
    "complete" => :tasks,
    "next_up_confirm" => :tasks,
    "make_ready" => :tasks,
    "ask_ready" => :tasks,
    "make_idle" => :tasks,
    # Owned by the in-progress flag (which itself needs the tasks
    # extension): with the step off, Start is neither shown nor accepted.
    "start_task" => :in_progress,
    "reopen" => :tasks,
    # The dialog that asks why opens under the same gates as the reopen.
    "ask_reopen" => :tasks,
    "remove_assignment" => :tasks,
    "reorder_assignments" => :tasks,
    "review_submission" => :tasks,
    "board_move" => :view_board,
    "open_review" => :tasks,
    "edit_duration" => :estimates,
    "save_duration" => :estimates,
    "update_progress" => :progress,
    "toggle_tracking" => :progress,
    "remove_dependency" => :dependencies,
    "change_workflow_status" => :statuses,
    "detach_subproject" => :subprojects,
    "open_health_modal" => :lifecycle,
    "save_health" => :lifecycle,
    "open_start_modal" => :lifecycle,
    "confirm_start_project" => :lifecycle,
    "open_log_time" => :ledger,
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
    "next_up_confirm" => :update_status,
    "make_ready" => :update_status,
    "ask_ready" => :update_status,
    "make_idle" => :update_status,
    "start_task" => :update_status,
    "reopen" => :update_status,
    "ask_reopen" => :update_status,
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
    "confirm_start_project" => :edit_settings,
    # A redirect sets where the work goes next (an agent reads it first) and
    # adopting a summary rewrites the description: both are edits to the task.
    "save_redirect" => :edit_tasks,
    "adopt_summary" => :edit_tasks
  }

  # Task-scoped events carry the task's uuid, and the task is what makes
  # a relationship grant work: the person a task is assigned to may move
  # their own task even when the floor is higher. Resolving the record
  # here (rather than passing nil) is what keeps "assignees can update
  # their own status" true through the interceptor.
  @record_param_events ~w(complete next_up_confirm make_ready ask_ready make_idle start_task reopen ask_reopen change_workflow_status
                          update_progress toggle_tracking remove_assignment save_duration)

  @impl true
  # A destructive action asks first through core's confirm modal
  # (`Components.ConfirmAction`); only these events may be put behind it.
  def handle_event("request_confirm", params, socket),
    do:
      {:noreply,
       ConfirmAction.request(
         socket,
         params,
         ~w(archive_project remove_assignment review_submission detach_subproject complete)
       )}

  def handle_event("confirm_action_cancel", _params, socket),
    do: {:noreply, ConfirmAction.clear(socket)}

  def handle_event("confirm_action_ok", _params, socket) do
    case ConfirmAction.take(socket) do
      {nil, socket} -> {:noreply, socket}
      {%{event: event, params: params}, socket} -> handle_event(event, params, socket)
    end
  end

  # The "Move…" dialog — this project (its ⋮ menu) or one of its
  # sub-projects (the row's). `ProjectMove.run/4` checks the mover.
  def handle_event(event, params, socket)
      when event in ~w(move_project_open move_project_change move_project_submit move_project_close),
      do: MoveProject.handle_event(event, params, socket, &after_project_move/2)

  # The typed list's tick: the same act as the row's Done / Reopen buttons,
  # so it goes through them (their feature gate, their permission, their
  # history line). The reply tells the list whether a question was put
  # first — it then takes its tick back until that is answered.
  def handle_event("outline_tick", %{"id" => uuid} = params, socket) when is_binary(uuid) do
    event = if params["done"] == true, do: "complete", else: "reopen"

    params =
      if params["force"] == true, do: %{"uuid" => uuid, "force" => "1"}, else: %{"uuid" => uuid}

    # A question left open by an earlier tick is not this one's.
    {:noreply, socket} = handle_event(event, params, ConfirmAction.clear(socket))
    asked = socket.assigns[:confirm_action] != nil or socket.assigns[:next_up] != nil
    {:reply, %{asked: asked}, socket}
  end

  def handle_event("outline_" <> _ = event, params, socket) do
    if socket.assigns.fx[:tasks] do
      OutlineList.handle_event(event, params, socket, fn socket ->
        socket |> sync_project_completion() |> load_assignments()
      end)
    else
      {:noreply, socket}
    end
  end

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

      Projects.reorder_assignments(
        project_uuid,
        keep_outline(reordered, socket.assigns.assignments),
        actor_uuid: Activity.actor_uuid(socket),
        broadcast: false
      )
    else
      _ -> :ok
    end
  end

  defp reposition_from_drop(_socket, _uuid, _ordered_ids), do: :ok

  # Which step a drop into a column is. Into "can be started": a waiting
  # card is released, a started or done one reopened. Into "waiting": put
  # back to idle. A waiting card dropped into "in progress" is released
  # too, not started — "Ready to start" is where its people are told, and
  # a drag must not be the way round that.
  defp board_step(%Assignment{status: "waiting"}, to) when to in ["todo", "in_progress"],
    do: "ask_ready"

  defp board_step(_assignment, "todo"), do: "reopen"
  defp board_step(_assignment, "waiting"), do: "make_idle"
  defp board_step(_assignment, "in_progress"), do: "start_task"
  defp board_step(_assignment, "done"), do: "complete"

  # Through `handle_event/3`, not straight to the handler: the step's own
  # feature gate and permission apply to a drag as to its button — with
  # the in-progress step off, a drop into that column starts nothing.
  defp delegate_board_move(socket, assignment, to) do
    case handle_event(board_step(assignment, to), %{"uuid" => assignment.uuid}, socket) do
      {:noreply, socket} -> socket
      {:reply, _reply, socket} -> socket
    end
  end

  # How a drop ended, read back rather than assumed: the card is where it
  # was dropped, or a dialog asks about it first (the release, next up, the
  # subtasks question), or the step refused or did nothing — a waiting
  # sub-project row has no "reopen" — and the card goes back.
  defp board_outcome(socket, uuid, to) do
    cond do
      board_pending_uuid(socket.assigns) == uuid -> :pending
      match?(%Assignment{status: ^to}, scoped_assignment(socket, uuid)) -> :ok
      true -> :error
    end
  end

  # The task a dialog of this page is asking about, if any: its card on
  # the board is marked as waiting for the answer.
  defp board_pending_uuid(assigns) do
    case assigns do
      %{next_up: %{task_uuid: uuid}} -> uuid
      %{confirm_action: %{params: %{"uuid" => uuid}}} -> uuid
      %{reopen_uuid: uuid} when is_binary(uuid) -> uuid
      _ -> nil
    end
  end

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
       when status in ["waiting", "todo", "in_progress", "done"] do
    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, load_assignments(socket)}

      assignment ->
        # Status first, through the very handlers the buttons use rather
        # than a naked `status` write: completing also sets progress to
        # 100, the actor and the timestamp; reopening clears all three.
        socket =
          if assignment.status == status,
            do: socket,
            else: delegate_board_move(socket, assignment, status)

        case board_outcome(socket, uuid, status) do
          :ok ->
            # Then WHERE it was dropped. The card landing somewhere other
            # than where it was let go reads as a bug, whatever the data
            # model says. The order is the plan, though, and this event's
            # gate is only `:update_status`: who may move a card but not
            # edit the plan (reorder_assignments' `:edit_tasks`) changes
            # its status and nothing else.
            if Authz.can?(
                 socket.assigns[:phoenix_kit_current_scope],
                 socket.assigns.project,
                 :edit_tasks
               ),
               do: reposition_from_drop(socket, uuid, params["ordered_ids"])

            {:noreply,
             socket
             |> push_event("sortable:flash", %{uuid: uuid, status: "ok"})
             |> load_assignments()}

          # A dialog asks first; the card waits in its old column, marked.
          :pending ->
            {:noreply, load_assignments(socket)}

          # Said, not flashed green: nothing was written. A gate's own
          # refusal (feature off, no permission) is the better message.
          :error ->
            socket =
              if Phoenix.Flash.get(socket.assigns.flash, :error),
                do: socket,
                else: put_flash(socket, :error, gettext("This task cannot move there."))

            {:noreply,
             socket
             |> push_event("sortable:flash", %{uuid: uuid, status: "error"})
             |> load_assignments()}
        end
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

  defp gated_handle_event("complete", %{"uuid" => uuid} = params, socket) do
    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      a ->
        complete_or_ask(socket, a, params)
    end
  end

  defp gated_handle_event("start_task", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      a ->
        new_pct = if a.progress_pct == 100, do: 0, else: a.progress_pct

        attrs = %{
          status: "in_progress",
          progress_pct: new_pct,
          started_by_uuid: Activity.actor_uuid(socket),
          started_by_key_uuid: nil
        }

        socket
        |> update_assignment_with_activity(a, attrs, "projects.assignment_started",
          metadata: %{"task" => Assignment.label(a)}
        )
        |> maybe_sync_and_reload()
    end
  end

  # Reopen asks why (the panel, 2026-10-25): the dialog's reason is posted
  # to the task's thread and quoted by the reopen's notice and history line,
  # so the person whose work came back reads ONE message that says what is
  # wrong. The typed list's tick and a board drag reopen without asking.
  defp gated_handle_event("ask_reopen", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      nil -> {:noreply, socket}
      # Kept whole: a task inside an expanded sub-project is not in
      # `@assignments`, and the dialog must open for it too.
      a -> {:noreply, assign(socket, reopen_uuid: uuid, reopen_task: a)}
    end
  end

  defp gated_handle_event("close_reopen", _params, socket),
    do: {:noreply, assign(socket, reopen_uuid: nil)}

  # Cancel: nothing was written, so there is nothing to undo.
  defp gated_handle_event("next_up_close", _params, socket),
    do: {:noreply, assign(socket, next_up: nil)}

  # "Keep idle" only marks the task in the dialog; nothing is written
  # until it is confirmed.
  defp gated_handle_event("next_up_toggle_idle", %{"uuid" => uuid}, socket) do
    case socket.assigns.next_up do
      %{mode: :complete, uuids: uuids, idle: idle} = next_up when is_binary(uuid) ->
        cond do
          uuid in idle -> {:noreply, assign(socket, next_up: %{next_up | idle: idle -- [uuid]})}
          uuid in uuids -> {:noreply, assign(socket, next_up: %{next_up | idle: [uuid | idle]})}
          true -> {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # A person's "notify" tick — UI state until the confirm.
  defp gated_handle_event("next_up_toggle_person", %{"uuid" => uuid, "user" => user}, socket) do
    with %{recipients: recipients, muted: muted} = next_up <- socket.assigns.next_up,
         people when is_list(people) <- Map.get(recipients, uuid),
         true <- Enum.any?(people, &(&1.uuid == user)) do
      mine = Map.get(muted, uuid, [])
      mine = if user in mine, do: mine -- [user], else: [user | mine]
      {:noreply, assign(socket, next_up: %{next_up | muted: Map.put(muted, uuid, mine)})}
    else
      _ -> {:noreply, socket}
    end
  end

  defp gated_handle_event("next_up_confirm", %{"uuid" => uuid} = params, socket) do
    with %{task_uuid: ^uuid} = next_up <- socket.assigns.next_up,
         %Assignment{status: status} = a when status != "done" <- scoped_assignment(socket, uuid) do
      socket = assign(socket, next_up: nil)

      case confirm_next_up(socket, a, next_up, params["notes"]) do
        {:ok, socket, released} ->
          {socket, sent} = post_next_up_comments(socket, next_up, params["notes"])
          maybe_sync_and_reload({:ok, next_up_flash(socket, released, sent)})

        error ->
          maybe_sync_and_reload(error)
      end
    else
      _ -> {:noreply, socket |> assign(next_up: nil) |> load_assignments()}
    end
  end

  # "Ready to start" on a waiting task: the dialog for that one task — who
  # is told, a comment — and nothing written until it is confirmed.
  defp gated_handle_event("ask_ready", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      %Assignment{status: "waiting", child_project_uuid: nil} = a ->
        {:noreply, assign(socket, next_up: build_next_up(socket, :release, a, [a], false))}

      _ ->
        {:noreply, socket}
    end
  end

  # Released without the dialog (kept for callers that do not ask; the
  # page's own button opens "Ready to start"): its people are told.
  defp gated_handle_event("make_ready", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      %Assignment{status: "waiting", child_project_uuid: nil} = a ->
        _ = set_readiness(socket, a, "todo")
        {:noreply, load_assignments(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  # Back to idle — from "can be started", or (a board drag) from started or
  # done work, which reopens it as waiting.
  defp gated_handle_event("make_idle", %{"uuid" => uuid}, socket) do
    case scoped_assignment(socket, uuid) do
      %Assignment{status: "todo"} = a ->
        _ = set_readiness(socket, a, "waiting")
        {:noreply, load_assignments(socket)}

      %Assignment{status: status, child_project_uuid: nil} = a
      when status in ["in_progress", "done"] ->
        attrs = %{status: "waiting", progress_pct: 0, completed_by_uuid: nil, completed_at: nil}

        socket
        |> update_assignment_with_activity(a, attrs, "projects.assignment_reopened",
          metadata: %{"task" => Assignment.label(a)}
        )
        |> maybe_sync_and_reload()

      _ ->
        {:noreply, socket}
    end
  end

  defp gated_handle_event("reopen", %{"uuid" => uuid} = params, socket) do
    case scoped_assignment(socket, uuid) do
      nil ->
        {:noreply, socket}

      # Not started (a stale tab, a second click): nothing to reopen, and
      # nobody to tell that it was.
      %Assignment{status: status} when status in ["waiting", "todo"] ->
        {:noreply, assign(socket, reopen_uuid: nil)}

      a ->
        reason = reopen_reason(params["reason"])

        attrs = %{
          status: "todo",
          progress_pct: 0,
          completed_by_uuid: nil,
          completed_at: nil
        }

        meta =
          if reason == "",
            do: %{"task" => Assignment.label(a)},
            else: %{"task" => Assignment.label(a), "reason" => reason}

        # The reopen first, the reason's comment only once it happened: a
        # refused reopen must not leave a reason under a task still done.
        socket
        |> assign(reopen_uuid: nil)
        |> update_assignment_with_activity(a, attrs, "projects.assignment_reopened",
          metadata: meta
        )
        |> then(fn
          {:ok, socket} -> {:ok, post_reopen_reason(socket, a, reason)}
          other -> other
        end)
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
        case remove_task(socket, a) do
          {:ok, socket} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Task removed."))
             |> sync_project_completion()
             |> load_assignments()}

          {:error, socket} ->
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

          deps_by_assignment = Map.merge(socket.assigns.deps_by_assignment, child_deps)

          # load_ledger last: the newly revealed child tasks' logged-time
          # chips read `@ledger_minutes`, which keys off the displayed set.
          {:noreply,
           socket
           |> assign(
             expanded_subprojects: MapSet.put(expanded, uuid),
             subproject_child_tasks:
               Map.put(socket.assigns.subproject_child_tasks, uuid, child_tasks),
             deps_by_assignment: deps_by_assignment,
             link_pairs: link_pairs(deps_by_assignment),
             linked_uuids: linked_uuids(deps_by_assignment),
             held_by:
               Map.merge(
                 socket.assigns[:held_by] || %{},
                 held_by(child_tasks, Map.merge(socket.assigns.deps_by_assignment, child_deps))
               )
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
        # Taking a sub-project out of its parent moves it: the host's move
        # lock holds it here like the Move… dialog does.
        locked = child_uuid |> Projects.get_project() |> locked_reason()

        if locked,
          do: {:noreply, put_flash(socket, :error, locked)},
          else: detach_subproject(socket, a, child_uuid)

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
       when type in ["project", "assignment", "notes"] do
    title = Map.get(params, "title", "")

    # The drawer shows (and posts to) whatever record the uuid names, so the
    # uuid must be THIS project or one of ITS tasks — never another project's.
    if comments_target?(socket, type, uuid) do
      {:noreply,
       assign(socket,
         comments_resource: %{type: type, uuid: uuid, title: title},
         notes_summary_preview: if(type == "notes", do: notes_summary_preview(socket, uuid))
       )}
    else
      {:noreply, socket}
    end
  end

  # A person's "no, that's wrong — do X": a redirect note, written as the
  # viewer, one line required. The thread is the comments component's; it
  # reloads off the comments broadcast.
  defp gated_handle_event("save_redirect", %{"uuid" => uuid} = params, socket) do
    with %Assignment{} = a <- find_displayed_assignment(socket, uuid),
         {:ok, fields} <- TaskNotes.validate(Map.take(params, ~w(summary content)), "redirect"),
         {:ok, _} <-
           TaskNotes.create(a, fields,
             user_uuid: Activity.actor_uuid(socket),
             kind: "redirect",
             metadata: %{"via" => "web"}
           ) do
      Activity.log("projects.assignment_redirected",
        actor_uuid: Activity.actor_uuid(socket),
        resource_type: "assignment",
        resource_uuid: a.uuid,
        metadata: %{"summary" => fields.summary}
      )

      {:noreply,
       socket
       |> assign(notes_summary_preview: notes_summary_preview(socket, uuid))
       |> put_flash(:info, gettext("Direction set."))}
    else
      {:error, %{"summary" => _}} ->
        {:noreply, put_flash(socket, :error, gettext("Write one line for the new direction."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not set the direction."))}
    end
  end

  # The latest summary (a redirect's, else an agent's) becomes the task's
  # description — a person's act, logged as machine-made text adopted.
  defp gated_handle_event("adopt_summary", %{"uuid" => uuid}, socket) do
    with %Assignment{} = a <- find_displayed_assignment(socket, uuid),
         %{text: text, source: source} when is_binary(text) <-
           TaskNotes.display_summary(nil, TaskNotes.latest(uuid)),
         {:ok, _} <- Projects.update_assignment_form(a, %{"description" => text}) do
      Activity.log("projects.assignment_updated",
        actor_uuid: Activity.actor_uuid(socket),
        resource_type: "assignment",
        resource_uuid: a.uuid,
        metadata: %{"description_from" => to_string(source), "machine_made" => source == :agent}
      )

      {:noreply,
       socket
       |> assign(notes_summary_preview: nil)
       |> put_flash(:info, gettext("Description set from the latest summary."))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Nothing to adopt."))}
    end
  end

  defp gated_handle_event("close_comments", _params, socket) do
    {:noreply, assign(socket, comments_resource: nil, notes_summary_preview: nil)}
  end

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
    full_order =
      socket.assigns.assignments
      |> Enum.map(& &1.uuid)
      |> merge_visible_order(ordered_ids)
      |> keep_outline(socket.assigns.assignments)

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
  # seconds, no timezone): the wall clock where the viewer is, read in their
  # zone (`L10n.from_wall/1`) — the page shows every time in that zone too.
  # Pad seconds when missing so `NaiveDateTime` accepts it.
  defp parse_start_at(value) when is_binary(value) do
    with_seconds = if String.length(value) == 16, do: value <> ":00", else: value

    with {:ok, ndt} <- NaiveDateTime.from_iso8601(with_seconds),
         %DateTime{} = at <- L10n.from_wall(ndt) do
      {:ok, at}
    else
      _ -> {:error, gettext("Invalid date — please pick a valid date and time.")}
    end
  end

  defp parse_start_at(_),
    do: {:error, gettext("Invalid date — please pick a valid date and time.")}

  # True only when the `phoenix_kit_comments` module is loaded AND
  # admin-enabled. Off-by-default `enabled?/0` rescues any error
  # (missing tables, sandbox-down) and returns false, so this stays
  # safe in early-install or test environments.
  defp comments_target?(socket, "project", uuid), do: uuid == socket.assigns.project.uuid

  defp comments_target?(socket, _task_type, uuid),
    do: find_displayed_assignment(socket, uuid) != nil

  # A task on this page, by uuid — the displayed set first (no query),
  # else the store, and only if it belongs to this project.
  defp find_displayed_assignment(socket, uuid) do
    displayed =
      socket.assigns.assignments
      |> Enum.find(&(&1.uuid == uuid))

    case displayed || Projects.get_assignment(uuid) do
      %Assignment{project_uuid: project_uuid} = a
      when project_uuid == socket.assigns.project.uuid ->
        a

      _ ->
        nil
    end
  end

  # The "Use as description" offer: only when the task has no description
  # of its own and a note has a summary to give it.
  defp notes_summary_preview(socket, uuid) do
    case find_displayed_assignment(socket, uuid) do
      %Assignment{} = a ->
        description = a.description || (a.task && a.task.description)

        case TaskNotes.display_summary(description, TaskNotes.latest(uuid)) do
          %{source: source, text: text} when source in [:redirect, :agent] -> text
          _ -> nil
        end

      _ ->
        nil
    end
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

  @reason_max 2_000

  # What a reopen's reason may be: text, trimmed, at most @reason_max
  # characters (anything else — a crafted map, a number — is no reason).
  defp reopen_reason(reason) when is_binary(reason),
    do: reason |> String.trim() |> String.slice(0, @reason_max)

  defp reopen_reason(_), do: ""

  # The reason, as a comment on the task — only where the project has its
  # discussions on and the person may comment there; the reopen's own row
  # carries it either way, so the notice quotes it regardless.
  defp post_reopen_reason(socket, _a, ""), do: socket

  defp post_reopen_reason(socket, a, reason) do
    actor = Activity.actor_uuid(socket)

    if socket.assigns.comments_enabled and is_binary(actor) and
         Authz.can?(
           socket.assigns[:phoenix_kit_current_scope],
           socket.assigns.project,
           :comment,
           a
         ) do
      case PhoenixKitComments.create_comment("assignment", a.uuid, actor, %{
             content: reason,
             metadata: %{"reopen_reason" => true}
           }) do
        {:ok, _} -> load_comment_counts(socket)
        _ -> socket
      end
    else
      socket
    end
  end

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
        assignment_comment_counts: assignment_counts,
        assignment_note_counts: TaskNotes.count_for_assignments(assignment_uuids)
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

      per_task = Ledger.totals_for_assignments(displayed)

      assign(socket,
        ledger_totals: Ledger.totals_for_project(project.uuid),
        ledger_minutes: Map.new(per_task, fn {uuid, t} -> {uuid, t.minutes} end),
        # An agent's share of those minutes: the row says the two apart.
        ledger_ai_minutes: Ledger.ai_minutes_for_assignments(displayed),
        ledger_tokens: Map.new(per_task, fn {uuid, t} -> {uuid, t.tokens} end),
        # Cheap availability probe for the Invoice-effort button — the
        # click re-runs the FULL guard chain (authz + profile + rate).
        invoice_ready?:
          Extensions.enabled?(project, "billing_customer") and
            Authz.can?(socket.assigns[:phoenix_kit_current_scope], project, :edit_settings)
      )
    else
      assign(socket,
        ledger_totals: nil,
        ledger_minutes: %{},
        ledger_ai_minutes: %{},
        ledger_tokens: %{},
        invoice_ready?: false
      )
    end
  end

  # Default value for `<input type="datetime-local">`: now on the viewer's
  # wall clock, formatted `YYYY-MM-DDTHH:mm` (the format the browser
  # expects) — `parse_start_at/1` reads it back in the same zone.
  defp default_start_at_local do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> L10n.local()
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
  # History tells the work: a project with no tasks (only a discussion, only
  # whiteboards) keeps its one-tab page and its ⋮ → Activity log.
  defp gate_tab(:history, fx), do: if(fx.tasks, do: :history, else: :list)
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
      ext.tabs
      # A tab that names a feature flag is offered only while the flag
      # resolves on (the Tasks extension's Hours tab and the work ledger).
      |> Enum.filter(&tab_flag_on?(&1, project))
      |> Enum.map(fn tab ->
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

  defp tab_flag_on?(%{requires_flag: flag}, project) when is_binary(flag),
    do: Features.on?(project, flag)

  defp tab_flag_on?(_tab, _project), do: true

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
    |> assign(history_mounted?: socket.assigns.history_mounted? or active == :history)
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
        "history" when not socket.assigns.is_template and :erlang.map_get(:tasks, fx) -> :history
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
      :history -> :history
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
  def tab_url(:list, project, _ext_tabs), do: Paths.project_tasks(project)
  def tab_url(:board, project, _ext_tabs), do: Paths.project_board(project)
  def tab_url(:gantt, project, _ext_tabs), do: Paths.project_gantt(project)
  def tab_url(:calendar, project, _ext_tabs), do: Paths.project_calendar(project)
  def tab_url(:comments, project, _ext_tabs), do: Paths.project_comments(project)
  def tab_url(:history, project, _ext_tabs), do: Paths.project_history(project)

  def tab_url("ext:" <> _ = id, project, ext_tabs) do
    case Enum.find(ext_tabs, &(&1.id == id)) do
      %{slug: slug} -> Paths.project_ext_tab(project, slug)
      nil -> Paths.project(project)
    end
  end

  def tab_url(_tab, project, _ext_tabs), do: Paths.project(project)

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

  defp progress_action(pct, prev_status) when pct > 0 and prev_status in ["waiting", "todo"],
    do: "projects.assignment_started"

  defp progress_action(0, prev_status) when prev_status not in ["waiting", "todo"],
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

  attr(:project, :map, required: true)

  defp project_link(%{project: %{external_url: url}} = assigns)
       when is_binary(url) and url != "" do
    # Read again, not trusted from the row: only a path on this site or a
    # web address is ever an href (a row written before the changeset
    # checked, or by hand, renders no button).
    assigns =
      assign(assigns,
        url: url,
        local?: Routes.local_path?(url),
        web?:
          match?(
            %URI{scheme: s, host: h} when s in ["http", "https"] and h not in [nil, ""],
            URI.parse(url)
          ),
        label: present_or(assigns.project.external_label, gettext("Open link"))
      )

    ~H"""
    <a
      :if={@local?}
      href={@url}
      class="btn btn-sm btn-ghost gap-1"
      data-project-link
    >
      <.icon name="hero-link" class="w-4 h-4" /> {@label}
    </a>
    <a
      :if={@web? and not @local?}
      href={@url}
      target="_blank"
      rel="noopener noreferrer"
      class="btn btn-sm btn-ghost gap-1"
      data-project-link
    >
      {@label} <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
    </a>
    """
  end

  defp project_link(assigns), do: ~H""

  defp present_or(text, fallback) do
    case is_binary(text) && String.trim(text) do
      t when is_binary(t) and t != "" -> t
      _ -> fallback
    end
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

  # This project moved: its trail and its place changed, so the page is
  # opened afresh (an embed just reloads its plan). A sub-project moved
  # out of this one: its row is gone.
  defp after_project_move(socket, %{project: %{uuid: uuid}}) do
    if uuid == socket.assigns.project.uuid and socket.assigns[:embed_mode] != :emit do
      push_navigate(socket, to: Paths.project(uuid))
    else
      socket |> sync_project_completion() |> load_assignments()
    end
  end

  defp locked_reason(nil), do: nil
  defp locked_reason(%Project{} = project), do: MoveLock.reason(project)

  defp detach_subproject(socket, a, child_uuid) do
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
  end

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
            <%!-- Ongoing work never completes on its own: every task done
                 is "all caught up", said here. That it IS ongoing is not
                 said on the page at all — it is the project's status on
                 the list, and nothing here depends on it (Max, 2026-10-13:
                 "no reason for Ongoing to take up a whole row"). --%>
            <span
              :if={Project.ongoing?(@project) and is_nil(@project.completed_at) and @total_tasks > 0 and @done_tasks == @total_tasks}
              class="badge badge-success badge-outline gap-1"
            >
              <.icon name="hero-check" class="w-3.5 h-3.5" /> {gettext("All caught up")}
            </span>
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
      <.modal :if={@review_open? and @pending_reviews != []} show on_close="close_review" id={"project-review-#{@project.uuid}"} max_width="2xl">
        <:title>{gettext("Submissions to review")}</:title>
            <p class="text-sm text-base-content/70 mt-1">
              {gettext("Sent from the public board. Accepting adds it to the project; rejecting keeps a record and shows nobody.")}
            </p>

            <div class="flex flex-col gap-2 mt-4">
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
                      {ConfirmAction.ask("review_submission",
                        uuid: a.uuid,
                        decision: "rejected",
                        title: gettext("Reject submission"),
                        message: gettext("Reject this submission?"),
                        confirm: gettext("Reject")
                      )}
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
      </.modal>

      <%!-- Health modal --%>
      <.modal :if={@health_modal_open} show on_close="close_health_modal" id={"project-health-#{@project.uuid}"} max_width="md" close_guard={:input}>
        <:title>{gettext("Project health")}</:title>
            <p class="text-sm text-base-content/70 mt-1">
              {gettext("Your judgment, not a computed number — how does this project feel right now?")}
            </p>
            <form id={"health-form-#{@project.uuid}"} phx-submit="save_health" class="flex flex-col gap-3 mt-4">
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
                    class="radio radio-primary radio-sm"
                    required
                  />
                  <span class="text-sm font-medium">{health_label(status)}</span>
                </label>
              </div>
              <.textarea
                id={"health-note-#{@project.uuid}"}
                name="note"
                value={@health && @health["note"]}
                label={gettext("Note (optional)")}
                rows="2"
                class="textarea-sm"
                placeholder={gettext("What's behind this call?")}
              />
              <div class="modal-action">
                <button type="button" phx-click="close_health_modal" class="btn btn-ghost btn-sm">
                  {gettext("Cancel")}
                </button>
                <button type="submit" phx-disable-with={gettext("Saving…")} class="btn btn-primary btn-sm">
                  {gettext("Save")}
                </button>
              </div>
            </form>
      </.modal>

      <%!-- Log-time modal (Step 10). Render-gated on the same flag the
           events check; @log_time_uuid scopes the entry to a task. --%>
      <.modal :if={@log_time_open and @fx.ledger} show on_close="close_log_time" id={"project-log-time-#{@project.uuid}"} max_width="sm" close_guard={:input}>
        <:title>{gettext("Log time")}</:title>
            <p class="text-sm text-base-content/70 mt-1">
              <%= if label = log_time_task_label(assigns) do %>
                {gettext("On task: %{task}", task: label)}
              <% else %>
                {gettext("On the project overall")}
              <% end %>
            </p>
            <form id={"work-entry-form-#{@project.uuid}"} phx-submit="save_work_entry" class="flex flex-col gap-3 mt-4">
              <div class="flex items-start gap-2">
                <.input
                  id={"log-time-hours-#{@project.uuid}"}
                  type="number"
                  name="hours"
                  label={gettext("Hours")}
                  min="0"
                  step="1"
                  value="0"
                  class="input-sm"
                  wrapper_class="flex-1"
                />
                <.input
                  id={"log-time-minutes-#{@project.uuid}"}
                  type="number"
                  name="minutes"
                  label={gettext("Minutes")}
                  min="0"
                  max="59"
                  step="1"
                  value="30"
                  class="input-sm"
                  wrapper_class="flex-1"
                />
              </div>
              <.input
                id={"log-time-note-#{@project.uuid}"}
                name="note"
                value=""
                label={gettext("Note (optional)")}
                class="input-sm"
                placeholder={gettext("What was the time spent on?")}
              />
              <.checkbox
                id={"log-time-billable-#{@project.uuid}"}
                name="billable"
                label={gettext("Billable")}
                class="checkbox-primary checkbox-sm"
                wrapper_class="gap-2"
              />
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
      </.modal>


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
          ) ++
          if(@is_template or not @fx.tasks,
            do: [],
            else: [%{id: "history", label: gettext("History"), icon: "hero-clock"}]
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
              data-id="add-task-sheet"
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
           branch is about how to USE the template, not about starting.
           Ongoing work has nothing to announce either (no setup, no start
           to press, no end to reach), so it has no bar — unless it still
           waits for a scheduled start, which the bar is how you bring
           forward. --%>
      <% ongoing_open? = not @is_template and Project.ongoing?(@project) and is_nil(@project.completed_at) %>
      <% waiting? = is_nil(@project.started_at) and @project.start_mode == "scheduled" %>
      <div
        :if={(@is_template or @fx.lifecycle) and not (ongoing_open? and not waiting?)}
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
      <%!-- Ongoing work has no finish line, so no bar towards one (Max,
           2026-10-05); the start bar's badges say Ongoing / All caught up. --%>
      <% show_progress = @fx.tasks and @total_tasks > 0 and not @is_template and not Project.ongoing?(@project) %>
      <% show_effort = @fx.ledger and @ledger_totals != nil %>
      <%!-- Every block around the list carries an id: a block that appears
           (this one, with the first task) must be inserted, not matched
           against the next block by position — that rebuilt the typed list
           under the cursor and lost the line just begun. --%>
      <%= if show_schedule or show_progress or show_effort do %>
        <div id={"project-summary-#{@project.uuid}"} class="bg-base-200/50 rounded-t-lg overflow-hidden">
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
              <%!-- AI effort, apart from people's: tokens and cost as before, and
                   the minutes an agent reported over the API (never billable). --%>
              <%= if @ledger_totals.tokens > 0 or @ledger_totals.cost_cents > 0 or @ledger_totals.ai_minutes > 0 do %>
                <span class="text-base-content/40">·</span>
                <div class="flex items-center gap-2">
                  <.icon name="hero-cpu-chip" class="w-4 h-4 text-base-content/60" />
                  <span class="text-base-content/60">{gettext("AI:")}</span>
                  <span :if={@ledger_totals.ai_minutes > 0} class="font-medium">
                    {format_minutes(@ledger_totals.ai_minutes)}
                  </span>
                  <span :if={@ledger_totals.tokens > 0} class="font-medium">
                    {format_tokens(@ledger_totals.tokens)}
                  </span>
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
                  phx-disable-with={gettext("Generating…")}
                  data-confirm={gettext("Create a draft invoice from all uninvoiced billable time?")}
                >
                  <.icon name="hero-banknotes" class="w-3 h-3" /> {gettext("Invoice effort")}
                </button>
                <%!-- The whole picture — who, which task, which day — is the
                     Hours tab (offered while the ledger is on). --%>
                <button
                  :if={Enum.any?(@ext_tabs, &(&1.id == "ext:tasks:hours"))}
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="switch_tab"
                  phx-value-tab="ext:tasks:hours"
                  id={"project-hours-link-#{@project.uuid}"}
                >
                  <.icon name="hero-clock" class="w-3 h-3" /> {gettext("Hours")}
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
      <div id={"project-list-tab-#{@project.uuid}"} class={if(@active_tab != :list, do: "hidden")}>
      <%!-- Timeline --%>
      <%!-- The lens bar. Every count is drawn from the FULL set and every
           one of them is a link into its own slice: filtering the list is
           fine, but a project that quietly looks like 47 tasks when it
           holds 947 is not. The number is the honesty; the rows are just
           what you happen to be reading. --%>
      <div
        :if={@assignments != [] and (@list_controls? or @pending_reviews != [])}
        id={"project-list-lens-#{@project.uuid}"}
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
              <.select
                id={"project-list-sort-select-#{@project.uuid}"}
                name="sort"
                value={to_string(@list_sort)}
                class="select-sm"
                aria-label={gettext("Sort tasks")}
                options={[
                  {gettext("Manual order"), "position"},
                  {gettext("Newest first"), "newest"},
                  {gettext("Recently updated"), "recent"}
                ]}
              />
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

      <%!-- The typed list (`OutlineList.text_list/1`): the whole project as
           one text field — one line a task, an indent a subtask. Drawn when
           nothing the project has switched on needs a row of its own, or
           when the project chose it (settings → "How the list looks"). --%>
      <%= if @outline_style == :text and not @is_template do %>
        <OutlineList.text_list
          id={@outline_dom_id}
          lines={@outline_lines}
          can={@outline_can}
          project={@project}
        />
      <% else %>
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
        <%!-- `PkpLinks`: hover a connected task for a light hint of what
             it waits on and unlocks; its trace button marks the whole chain
             and stays while scrolling (the button again, Escape or a click
             outside the list ends it). All in the browser, from the pairs
             below. No rail down the side: a line through every row claimed
             "these run one after another", which a project's dependencies
             rarely are. The arrows come only with the hover / trace, in the
             left gutter (kept only when there are connections), and the
             tasks outside it fade. --%>
        <div
          :if={@visible_assignments != []}
          id={"project-task-links-#{@project.uuid}"}
          class={["relative", @fx.dependencies and @link_pairs != [] && "pl-8"]}
          phx-hook={if @fx.dependencies, do: "PkpLinks"}
          data-links={Jason.encode!(@link_pairs)}
          data-labels={
            Jason.encode!(%{
              before: gettext("Waits on"),
              after: gettext("Unlocks"),
              earlier: gettext("Earlier"),
              later: gettext("Later"),
              trace: gettext("Trace everything before and after it"),
              stop: gettext("Stop tracing")
            })
          }
        >
          <svg
            :if={@fx.dependencies}
            id={"project-task-arrows-#{@project.uuid}"}
            data-pkp-arrows
            phx-update="ignore"
            class="absolute inset-0 w-full h-full pointer-events-none z-[2] overflow-visible"
            aria-hidden="true"
          >
          </svg>
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
            <% ol_folded = assigns[:outline_folded] || MapSet.new() %>
            <% ol_depths = if @list_manual?, do: Outline.depths(@visible_assignments), else: %{} %>
            <%= for a <- OutlineList.unfolded(@visible_assignments, ol_folded) do %>
              <%!-- The row a link named (`focus_task/2`) takes focus as the
                   page mounts, which is what scrolls it into view: the
                   URL's fragment is gone by then (the tab sync rewrites
                   the address) and LiveView has no scroll command. --%>
              <div
                id={"task-#{a.uuid}"}
                class="relative flex gap-4 py-3 scroll-mt-24 focus:outline-none sortable-item"
                style={"margin-left: #{Map.get(ol_depths, a.uuid, 0) * 2}rem"}
                data-id={a.uuid}
                tabindex={assigns[:focus_task] == a.uuid && "-1"}
                phx-mounted={assigns[:focus_task] == a.uuid && Phoenix.LiveView.JS.focus()}
              >
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
                <%!-- `min-w-0`: a flex child is as wide as its content unless told
                     otherwise, and one long line inside (an expanded
                     sub-project's task) pushed the page sideways. --%>
                <div class={[
                  "flex-1 min-w-0 card bg-base-100 shadow-sm border",
                  if(not @is_template and a.status == "done", do: "border-success/30 opacity-75", else: "border-base-200"),
                  assigns[:focus_task] == a.uuid && "ring-2 ring-primary"
                ]}>
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
                          <%!-- A sub-project is known by its OWN key, not by
                               the number its row has in this list. --%>
                          <.ref_chip :if={not @is_template} ref={child.key} />
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
                            <.icon name="hero-arrow-right-circle" class="w-3.5 h-3.5" /> {gettext("Open")}
                          </.smart_link>
                          <.table_row_menu id={"assignment-menu-#{a.uuid}"}>
                            <.smart_menu_link
                              navigate={Paths.project(child.uuid)}
                              emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => child.uuid}}}
                              embed_mode={@embed_mode}
                              popup={false}
                              icon="hero-arrow-right-circle"
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
                            <%!-- Out as its own project, or under another one —
                                 keeps it + its tasks, and offers what it takes
                                 along (`Components.MoveProject`). --%>
                            <MoveProject.locked_menu_item
                              :if={@fx.subprojects and @move_locks[child.uuid]}
                              reason={@move_locks[child.uuid]}
                              label={gettext("Move out…")}
                            />
                            <.table_row_menu_button
                              :if={@fx.subprojects and !@move_locks[child.uuid]}
                              phx-click="move_project_open"
                              phx-value-uuid={child.uuid}
                              icon="hero-arrows-right-left"
                              label={gettext("Move out…")}
                            />
                            <.table_row_menu_divider />
                            <.table_row_menu_button
                              {ConfirmAction.ask("remove_assignment",
                                uuid: a.uuid,
                                title: gettext("Remove sub-project"),
                                message: gettext("Remove sub-project \"%{name}\" and everything inside it?", name: Project.localized_name(child, sp_lang)),
                                confirm: gettext("Remove")
                              )}
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
                        <%!-- An ongoing child never completes: its row stays open,
                             and when every task is done it says so. --%>
                        <span :if={Project.ongoing?(child)} class="badge badge-ghost badge-sm gap-1" title={gettext("Ongoing — this project ends only when someone ends it")}>
                          <.icon name="hero-arrow-path" class="w-3 h-3" /> {gettext("Ongoing")}
                        </span>
                        <span :if={Project.ongoing?(child) and sp_summary.total > 0 and sp_summary.done == sp_summary.total} class="badge badge-success badge-outline badge-sm gap-1">
                          <.icon name="hero-check" class="w-3 h-3" /> {gettext("All caught up")}
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
                      <div :if={sp_expanded?} class="mt-2 rounded-lg bg-base-200/60 p-3 flex flex-col gap-2 min-w-0">
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
                                <div class="relative flex gap-3 min-w-0">
                                  <div class="relative z-10 shrink-0 flex flex-col items-center">
                                    <div class={"w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold #{AssignmentStatusBadge.color(ct.status)} #{AssignmentStatusBadge.text_color(ct.status)} #{AssignmentStatusBadge.ring(ct.status)}"}>
                                      <%= if ct.status == "done" do %>
                                        <.icon name="hero-check" class="w-4 h-4" />
                                      <% else %>
                                        {ci + 1}
                                      <% end %>
                                    </div>
                                  </div>
                                  <div class={"flex-1 min-w-0 card bg-base-100 shadow-sm border #{if ct.status == "done", do: "border-success/30 opacity-75", else: "border-base-200"}"}>
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
                                      ledger_ai_minutes={assigns[:ledger_ai_minutes] || %{}}
                                      ledger_tokens={@ledger_tokens}
                                      assignment_note_counts={@assignment_note_counts}
                                      assignment_labels={@assignment_labels}
                                      faces={assigns[:assignee_faces] || %{}}
                                      deps_by_assignment={@deps_by_assignment}
                                      held_by={@held_by}
                                      linked={@linked_uuids}
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
                      ol={
                        %{
                          can: @outline_can,
                          count: Map.get(@outline_counts, a.uuid),
                          folded: MapSet.member?(ol_folded, a.uuid),
                          focus: assigns[:outline_focus] == a.uuid,
                          fresh: assigns[:outline_fresh] == a.uuid
                        }
                      }
                      scope={@phoenix_kit_current_scope}
                      draggable={@list_manual?}
                      is_template={@is_template}
                      project={@project}
                      fx={assigns[:outline_fx] || @fx}
                      embed_mode={@embed_mode}
                      editing_duration_uuid={@editing_duration_uuid}
                      comments_enabled={@comments_enabled and (assigns[:outline_fx] || %{})[:comments_row] != false}
                      assignment_comment_counts={@assignment_comment_counts}
                      ledger_minutes={@ledger_minutes}
                      ledger_ai_minutes={assigns[:ledger_ai_minutes] || %{}}
                      ledger_tokens={@ledger_tokens}
                      assignment_note_counts={@assignment_note_counts}
                      assignment_labels={@assignment_labels}
                      faces={assigns[:assignee_faces] || %{}}
                      deps_by_assignment={@deps_by_assignment}
                      held_by={@held_by}
                      linked={@linked_uuids}
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
      <%!-- Cards: a task is added right here and typed into its row. The
           sheet ("Add task" at the top) stays for one with details. --%>
      <button
        :if={@fx.tasks and not @is_template and @outline_can.edit}
        type="button"
        phx-click="outline_add_first"
        phx-disable-with={gettext("Adding…")}
        class="btn btn-ghost btn-sm justify-start gap-2 mt-2 w-full text-base-content/60"
      >
        <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add a task")}
      </button>
      <.quick_add_composer
        :if={@fx.tasks and not @is_template and not @outline_can.edit}
        project_uuid={@project.uuid}
        embed_mode={@embed_mode}
      />
      <% end %>

      <OutlineList.held_tray
        :if={not @is_template}
        held={@outline_held}
        can={@outline_can}
        project={@project}
      />
      </div>

      <%!-- Gantt tab — rendered in every context (templates excepted),
      <%!-- Board tab — the kanban-lite view (Step 9): the SAME assignments
           grouped by task status. A card moves by dragging it or by its
           step button; every move goes through the same gated dispatcher
           as the list view. --%>
      <div :if={not @is_template and @fx.view_board} class={if(@active_tab != :board, do: "hidden")}>
        <%!-- A card whose status is outside the vocabulary belongs in no
             column, so the board simply dropped it — silently, which is the
             worst way to lose a task. Named here and left to the list,
             which renders it properly; dragging one in would coerce a value
             we never wrote and cannot get back. --%>
        <p :if={board_orphans(@assignments) > 0} class="text-xs opacity-60 mb-2">
          {gettext("%{count} task(s) have a status this board does not show.",
            count: board_orphans(@assignments)
          )}
          <button type="button" phx-click="switch_tab" phx-value-tab="list" class="link link-hover">
            {gettext("Open the list")}
          </button>
        </p>

        <% board_columns = board_columns(@fx, @assignments) %>
        <% pending_uuid = board_pending_uuid(assigns) %>
        <% faces = assigns[:assignee_faces] || %{} %>
        <%!-- Columns stretch to the tallest (no `items-start`), and each
             one's card list fills it: the whole column is where a card
             drops, not the strip its cards happen to cover — the boss had
             to find the one spot that took it (2026-10-29). On a phone
             the columns sit side by side and snap, one screen each,
             rather than one long stack. --%>
        <div class={[
          "flex gap-4 overflow-x-auto snap-x snap-mandatory pb-2 xl:grid xl:overflow-visible xl:pb-0",
          if(length(board_columns) == 4, do: "xl:grid-cols-4", else: "xl:grid-cols-3")
        ]}>
          <div
            :for={{status, title, tint} <- board_columns}
            class={[
              "bg-base-200/50 rounded-lg border-t-4 flex flex-col min-w-[80vw] sm:min-w-64 snap-start xl:min-w-0",
              tint
            ]}
          >
            <%!-- Top-level tasks are the cards; a task's subtasks show as
                 its "2/5" and are worked in the task (grok's rule, the
                 panel of 2026-10-14). --%>
            <% column = @assignments |> Outline.roots() |> Enum.filter(&(&1.status == status)) %>
            <div class="sticky top-0 z-10 flex items-center justify-between px-4 pt-3 pb-2 rounded-t-lg bg-base-200/90 backdrop-blur-sm">
              <span class="text-sm font-semibold">{title}</span>
              <span class="badge badge-ghost badge-sm">{length(column)}</span>
            </div>

            <%!-- One group across the columns, so a card can be dragged
                 between them (`PkpBoard`, in phoenix_kit_projects.js: the
                 whole card picks up, after a short hold on a touch screen
                 so the board still scrolls; the column under the card
                 lights up and a dashed gap shows where it lands). The
                 DESTINATION's status is what the hook sends, and the
                 handler reads the status it landed in.

                 `ordered_ids` arrives too and only says which card the
                 moved one now sits before: a column is a PARTIAL view of
                 the project, and writing its order to `position` would
                 renumber the whole plan from the few cards one column
                 happened to hold. --%>
            <div
              id={"board-column-#{status}"}
              class="pkp-board-list flex-1 flex flex-col gap-2 px-3 pb-3 min-h-32 rounded-b-lg"
              phx-hook="PkpBoard"
              data-board-group={"board-#{@project.uuid}"}
              data-board-event="board_move"
              data-board-status={status}
            >
              <p :if={column == []} class="pkp-board-empty text-xs opacity-40 px-1 py-2">
                {gettext("Nothing here.")}
              </p>
              <div
                :for={a <- column}
                id={"board-card-#{a.uuid}"}
                class={[
                  "card bg-base-100 border border-base-200 shadow-sm overflow-hidden sortable-item pkp-board-card cursor-grab",
                  pending_uuid == a.uuid && "ring-2 ring-info opacity-60"
                ]}
                data-id={a.uuid}
                title={pending_uuid == a.uuid && gettext("Waiting for your answer")}
              >
                <div class="card-body p-3 gap-2">
                  <div class="flex items-start gap-2">
                    <.icon name="hero-bars-2" class="w-3.5 h-3.5 shrink-0 mt-0.5 text-base-content/30" />
                    <.smart_link
                      navigate={Paths.view_assignment(a.project_uuid, a.uuid)}
                      emit={
                        {PhoenixKitProjects.Web.AssignmentViewLive,
                         %{"project_id" => a.project_uuid, "id" => a.uuid}}
                      }
                      embed_mode={@embed_mode}
                      class="text-sm font-medium link link-hover leading-snug min-w-0 text-left"
                    >
                      {Assignment.label(a, L10n.current_content_lang())}
                    </.smart_link>
                  </div>

                  <div class="flex flex-wrap items-center gap-1">
                    <.smart_link
                      :if={Assignment.ref(a)}
                      navigate={Paths.view_assignment(a.project_uuid, a.uuid)}
                      emit={{PhoenixKitProjects.Web.AssignmentViewLive, %{"project_id" => a.project_uuid, "id" => a.uuid}}}
                      embed_mode={@embed_mode}
                      class="shrink-0 hover:underline"
                      title={gettext("View the task")}
                    >
                      <.ref_chip ref={Assignment.ref(a)} />
                    </.smart_link>
                    <.deadline_chip :if={@fx[:dates] != false} a={a} size="xs" tone="outline" />
                    <% sub = Map.get(@outline_counts, a.uuid) %>
                    <span :if={sub} class="badge badge-xs badge-outline gap-1" title={gettext("Subtasks done")}>
                      <.icon name="hero-list-bullet" class="w-3 h-3" /> {sub.done}/{sub.total}
                    </span>
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
                       look — the faces first. "Unassigned" is shown, not
                       hidden — on a board that is the most actionable thing
                       a card can say. --%>
                  <div class="flex flex-wrap items-center justify-between gap-2">
                    <% b_atype = assignee_type(a) %>
                    <span
                      :if={@fx.assignees and b_atype}
                      class="inline-flex items-center gap-1.5 text-xs min-w-0 opacity-80"
                    >
                      <.assignee_faces faces={faces[a.uuid]} size="xs" />
                      <.icon :if={faces[a.uuid] == nil} name={assignee_icon(a)} class="w-3.5 h-3.5 shrink-0" />
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
                        <% a.status == "waiting" and a.child_project_uuid == nil -> %>
                          <button
                            phx-click="ask_ready"
                            phx-value-uuid={a.uuid}
                            class="btn btn-info btn-xs"
                            title={gettext("Release it: its people are told they can start")}
                          >
                            {gettext("Ready to start")}
                          </button>
                        <% a.status == "todo" and @fx.in_progress -> %>
                          <button phx-click="start_task" phx-value-uuid={a.uuid} phx-disable-with="…" class="btn btn-warning btn-xs">
                            {gettext("Start")}
                          </button>
                        <% a.status in ["todo", "in_progress"] or (a.status == "waiting" and a.child_project_uuid != nil) -> %>
                          <button
                            phx-click="complete"
                            phx-value-uuid={a.uuid}
                            phx-disable-with="…"
                            class="btn btn-success btn-xs"
                            title={gettext("Mark done")}
                            aria-label={gettext("Mark done")}
                          >
                            <.icon name="hero-check" class="w-3.5 h-3.5" />
                          </button>
                        <% a.status == "done" -> %>
                          <button phx-click="ask_reopen" phx-value-uuid={a.uuid} class="btn btn-ghost btn-xs">
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
              "frame_ref" => @embed_frame_ref,
              # Where the host's own pages are, for a tab that wants to send
              # someone there (the CRM's "add a task from this meeting")
              # without naming this module's routes itself.
              "host_paths" => %{"new_task" => Paths.new_assignment(@project.uuid)}
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

      <%!-- ── The History tab ── the project told as it happened
           (`ProjectHistoryLive`, lazily mounted and then kept, like the
           Timeline). The raw audit log stays on ⋮ → Activity. --%>
      <div :if={not @is_template and @fx.tasks} class={[top_tab != :history && "hidden"]}>
        <%= if @history_mounted? do %>
          {live_render(@socket, PhoenixKitProjects.Web.ProjectHistoryLive,
            id: "project-history-live-#{@project.uuid}",
            session: %{
              "id" => @project.uuid,
              "locale" => L10n.current_content_lang(),
              "current_user_uuid" =>
                assigns[:phoenix_kit_current_user] && assigns[:phoenix_kit_current_user].uuid,
              # The emit contract, as for the Timeline: an emit-embedded page
              # must not have its History links navigate the host away.
              "mode" => @embed_mode,
              "pubsub_topic" => @embed_pubsub_topic,
              "frame_ref" => @embed_frame_ref
            })}
        <% end %>
      </div>

      <%!-- Reopen asks why. --%>
      <% reopening = @reopen_uuid && @reopen_task %>
      <.modal :if={reopening} show on_close="close_reopen" id={"project-reopen-#{@project.uuid}"} max_width="md" close_guard={:input}>
        <:title>{gettext("Reopen “%{task}”", task: Assignment.label(reopening))}</:title>
        <.form for={%{}} id={"reopen-form-#{@project.uuid}"} phx-submit="reopen" class="flex flex-col gap-3">
          <input type="hidden" name="uuid" value={reopening.uuid} />
          <p class="text-sm text-base-content/70">
            {gettext("What is wrong or missing? Optional — whoever works on it is told, with your words.")}
          </p>
          <%!-- Optional: a reopen without a reason is still a reopen. --%>
          <textarea
            name="reason"
            rows="4"
            class="textarea textarea-bordered w-full"
            placeholder={gettext("e.g. Wall A says 3420 but the plan says 3240 — please measure it again.")}
          ></textarea>
          <div class="modal-action">
            <button type="button" phx-click="close_reopen" class="btn btn-ghost btn-sm">
              {gettext("Cancel")}
            </button>
            <button type="submit" phx-disable-with={gettext("Reopening…")} class="btn btn-warning btn-sm">
              <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> {gettext("Reopen")}
            </button>
          </div>
        </.form>
      </.modal>

      <%!-- Next up: asked before a completion that hands work on
           (`next_up_for/3`). Nothing is written until Confirm. --%>
      <.modal
        :if={@next_up}
        show
        on_close="next_up_close"
        id={"project-next-up-#{@project.uuid}"}
        max_width="lg"
        close_guard={:input}
      >
        <:title>
          <%= if @next_up.mode == :release do %>
            {gettext("“%{task}” — ready to start?", task: @next_up.after)}
          <% else %>
            {gettext("Mark “%{task}” done?", task: @next_up.after)}
          <% end %>
        </:title>
        <% next_rows = next_up_rows(@next_up, @assignments) %>
        <.form for={%{}} id={"next-up-form-#{@project.uuid}"} phx-submit="next_up_confirm" class="flex flex-col gap-3">
          <input type="hidden" name="uuid" value={@next_up.task_uuid} />
          <p class="text-sm text-base-content/70">
            <%= if @next_up.mode == :release do %>
              {gettext("The people ticked below are told it is their turn when you confirm — untick anyone who should not be notified. A comment goes along with the notification.")}
            <% else %>
              {gettext("Once it is done, these tasks can start: the people ticked below are told when you confirm, with your comment. Press “Keep idle” on a task that should wait.")}
            <% end %>
          </p>
          <div :for={a <- next_rows} class="rounded-box border border-base-200 p-3 flex flex-col gap-2">
            <% can = Map.get(@next_up.can, a.uuid, %{release: false, comment: false}) %>
            <% release? = next_up_release?(@next_up, a) %>
            <% people = Map.get(@next_up.recipients, a.uuid, []) %>
            <div class="flex flex-wrap items-center gap-2">
              <span class={["font-medium flex-1 min-w-0 truncate", not release? && "line-through opacity-50"]}>
                {Assignment.label(a, L10n.current_content_lang())}
              </span>
              <%!-- One button: pressed, the task stays waiting and the row
                   greys out; pressed again, it is released with the rest. --%>
              <button
                :if={@next_up.mode == :complete and can.release}
                type="button"
                phx-click="next_up_toggle_idle"
                phx-value-uuid={a.uuid}
                aria-pressed={to_string(not release?)}
                class={["btn btn-xs gap-1", if(release?, do: "btn-ghost", else: "btn-neutral")]}
              >
                <.icon name={if(release?, do: "hero-pause", else: "hero-arrow-uturn-left")} class="w-3.5 h-3.5" />
                {if release?, do: gettext("Keep idle"), else: gettext("Undo")}
              </button>
            </div>

            <%!-- Who it is assigned to, and who the notice reaches. --%>
            <div class={["flex items-center gap-1.5 text-xs text-base-content/70", not release? && "opacity-50"]}>
              <.icon name={assignee_icon(a)} class="w-3.5 h-3.5 shrink-0" />
              <%= if assignee_type(a) do %>
                <span>{assignee_type(a)}:</span>
                <span class="font-medium text-base-content">{assignee_label(a)}</span>
              <% else %>
                <span>{gettext("Nobody is assigned")}</span>
              <% end %>
            </div>

            <%= cond do %>
              <% not release? -> %>
                <p class="text-xs text-base-content/50 flex items-center gap-1">
                  <.icon name="hero-bell-slash" class="w-3.5 h-3.5" />
                  {gettext("Kept idle — nobody is notified.")}
                </p>
              <% people == [] -> %>
                <p class="text-xs text-warning flex items-center gap-1">
                  <.icon name="hero-bell-slash" class="w-3.5 h-3.5" />
                  {gettext("Nobody to notify — no one who can open this project is on it.")}
                </p>
              <% true -> %>
                <fieldset class="flex flex-col gap-1">
                  <legend class="text-xs font-semibold text-base-content/70 mb-1">
                    {gettext("Send a notification to")}
                  </legend>
                  <label
                    :for={person <- people}
                    class="flex items-center gap-2 text-sm cursor-pointer w-fit"
                  >
                    <% on? = not next_up_muted?(@next_up, a.uuid, person.uuid) %>
                    <input
                      type="checkbox"
                      class="checkbox checkbox-sm checkbox-info"
                      checked={on?}
                      phx-click="next_up_toggle_person"
                      phx-value-uuid={a.uuid}
                      phx-value-user={person.uuid}
                    />
                    <.icon
                      name={if(on?, do: "hero-bell-alert", else: "hero-bell-slash")}
                      class={if(on?, do: "w-4 h-4 text-info", else: "w-4 h-4 text-base-content/40")}
                    />
                    <span class={[not on? && "line-through text-base-content/50"]}>{person.name}</span>
                  </label>
                </fieldset>
            <% end %>

            <textarea
              :if={release? or can.comment}
              name={"notes[#{a.uuid}]"}
              rows="2"
              class="textarea textarea-bordered textarea-sm w-full"
              placeholder={gettext("Comment for whoever does it (optional)")}
            ></textarea>
          </div>
          <p :if={next_rows != [] and not @comments_enabled} class="text-xs text-base-content/60">
            {gettext("Discussions are off for this project, so a comment goes out with the notification only and is not kept on the task.")}
          </p>
          <div class="modal-action">
            <button type="button" phx-click="next_up_close" class="btn btn-ghost btn-sm">
              {gettext("Cancel")}
            </button>
            <button
              :if={@next_up.mode == :release}
              type="submit"
              phx-disable-with={gettext("Saving…")}
              class="btn btn-info btn-sm"
            >
              <.icon name="hero-play-circle" class="w-4 h-4" /> {gettext("Ready to start")}
            </button>
            <button
              :if={@next_up.mode == :complete}
              type="submit"
              phx-disable-with={gettext("Saving…")}
              class="btn btn-success btn-sm"
            >
              <.icon name="hero-check" class="w-4 h-4" /> {gettext("Confirm — mark done")}
            </button>
          </div>
        </.form>
      </.modal>

      <%!-- Start-project modal — date editable so the user can backdate
           an already-running project or queue a future start. The
           form's `phx-change="noop"` prevents the LV from rebuilding
           the changeset on each keystroke (no live validation needed
           for a single date input); submit goes via `phx-submit`. --%>
      <.modal :if={@start_modal_open} show on_close="close_start_modal" id={"project-start-#{@project.uuid}"} max_width="md">
        <:title>{gettext("Start project")}</:title>
            <p class="text-sm text-base-content/70 mt-1">
              {gettext("Pick the date and time this project starts. Defaults to right now; backdate it if work began earlier, or pick a future moment if you're queueing it up.")}
            </p>

            <.form id={"start-project-form-#{@project.uuid}"} for={@start_form} phx-submit="confirm_start_project" class="flex flex-col gap-3 mt-4">
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
      </.modal>

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
      <%!-- A core drawer (`placement={:end}`): the dialog's top layer paints
           over the admin header without z-index tricks, and PkDialog owns
           Esc, the backdrop and focus. --%>
      <.modal
        :if={@comments_resource}
        show
        on_close="close_comments"
        id={"project-comments-#{@project.uuid}"}
        aria-label={gettext("Comments")}
        placement={:end}
        max_width="md"
      >
        <:title>
          <span class="flex flex-col min-w-0">
            <span class="text-xs font-normal uppercase tracking-wide text-base-content/60">
              <%= case @comments_resource.type do %>
                <% "project" -> %>
                  {gettext("Project")}
                <% "notes" -> %>
                  {gettext("Agent notes")}
                <% _ -> %>
                  {gettext("Task")}
              <% end %>
            </span>
            <span class="truncate">{@comments_resource.title}</span>
          </span>
        </:title>
        <%!-- The notes thread is the same component on its own anchor
             (`TaskNotes.resource_type/0`): a person may add to it from
             here, but the agent's keys (kind, usage, the key) are
             decorations — server-set, never claimable from the form. The
             usage line above each note is rendered through the component's
             decoration registry. --%>
        <% notes? = @comments_resource.type == "notes" %>
        <%!-- A person changing the direction after an attempt ("no, that's
             wrong — do X"): a `redirect` note, which the API hands an agent
             FIRST on the next read. Only people write these; the summary
             line is what the agent follows. --%>
        <form
          :if={notes?}
          id={"redirect-#{@comments_resource.uuid}"}
          phx-submit="save_redirect"
          class="flex flex-col gap-2 rounded-box border border-warning/40 bg-warning/5 p-3 mb-3"
        >
          <input type="hidden" name="uuid" value={@comments_resource.uuid} />
          <.input
            id={"redirect-summary-#{@comments_resource.uuid}"}
            name="summary"
            value=""
            label={gettext("Change the direction")}
            maxlength={TaskNotes.summary_max()}
            class="input-sm"
            placeholder={gettext("One line the next worker follows, e.g. \"Keep the old parser, fix the encoder\"")}
          />
          <.textarea
            id={"redirect-content-#{@comments_resource.uuid}"}
            name="content"
            value=""
            label={gettext("Why (optional)")}
            rows={2}
            class="textarea-sm"
          />
          <div class="flex items-center justify-between gap-2">
            <button
              :if={@notes_summary_preview}
              type="button"
              phx-click="adopt_summary"
              phx-value-uuid={@comments_resource.uuid}
              class="btn btn-ghost btn-xs"
              title={gettext("Copy the latest summary into the task's description")}
            >
              <.icon name="hero-document-arrow-down" class="w-3.5 h-3.5" /> {gettext("Use as description")}
            </button>
            <span :if={is_nil(@notes_summary_preview)}></span>
            <button type="submit" phx-disable-with={gettext("Saving…")} class="btn btn-warning btn-xs">
              {gettext("Set direction")}
            </button>
          </div>
        </form>
        <.live_component
          module={PhoenixKitComments.Web.CommentsComponent}
          id={"comments-drawer-#{@comments_resource.type}-#{@comments_resource.uuid}"}
          resource_type={if notes?, do: TaskNotes.resource_type(), else: @comments_resource.type}
          resource_uuid={@comments_resource.uuid}
          current_user={assigns[:phoenix_kit_current_user]}
          title=""
          show_likes={not notes?}
          decoration_keys={if notes?, do: TaskNotes.decoration_keys(), else: []}
          comment_decorations={if notes?, do: TaskNotes.decorations(TaskNotes.list(@comments_resource.uuid)), else: %{}}
        />
      </.modal>

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
            "open" => popup_open(assigns),
            "wrapper_class" => "contents",
            "locale" => L10n.current_content_lang(),
            "current_user_uuid" =>
              assigns[:phoenix_kit_current_user] && assigns[:phoenix_kit_current_user].uuid
          })}
      <% end %>
      <.confirm_action_modal confirm={assigns[:confirm_action]} />
      <.move_project_modal move={assigns[:move_project]} />
    </div>
    """
  end
end
