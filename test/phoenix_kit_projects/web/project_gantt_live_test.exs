defmodule PhoenixKitProjects.Web.ProjectGanttLiveTest do
  @moduledoc """
  Smoke tests for `ProjectGanttLive` — the Gantt/waterfall view that
  reuses `ProjectShowLive`'s data through the `PhoenixLiveGantt` component.
  Verifies the assignment→bar mapping, dependency→connector mapping,
  the date-range computation, zoom switching, and the empty state.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Paths, Projects}
  alias PhoenixKitProjects.Web.ProjectGanttLive

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "gantt-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    scope = fake_scope(user_uuid: user.uuid)
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: user.uuid}
  end

  defp started_project_with_tasks(_actor_uuid) do
    project = fixture_project(%{"start_mode" => "immediate", "counts_weekends" => false})
    {:ok, _} = Projects.start_project(project)
    project = Projects.get_project!(project.uuid)

    t1 = fixture_task(%{"estimated_duration" => 2, "estimated_duration_unit" => "days"})
    t2 = fixture_task(%{"estimated_duration" => 3, "estimated_duration_unit" => "days"})

    {:ok, a1} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => t1.uuid,
        "status" => "done"
      })

    {:ok, a2} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => t2.uuid,
        "status" => "in_progress"
      })

    {project, a1, a2}
  end

  test "renders one bar per assignment with titles", %{conn: conn, actor_uuid: actor} do
    {project, _a1, _a2} = started_project_with_tasks(actor)

    {:ok, view, _html} = live_isolated(conn, ProjectGanttLive, session: %{"id" => project.uuid})
    html = render(view)

    # The chart wrapper + a bar per assignment (lg-bar marker class).
    assert html =~ "lg-wrap"
    assert html =~ "lg-bar"
    # Two bars → two lg-bar occurrences at minimum (bars + popovers reuse ids).
    bar_count =
      html |> String.split(~s(class="lg-bar )) |> length() |> Kernel.-(1)

    assert bar_count >= 2
  end

  test "task bars carry an Edit popover action that navigates to the edit form",
       %{conn: conn, actor_uuid: actor} do
    {project, a1, _a2} = started_project_with_tasks(actor)

    {:ok, view, _html} = live_isolated(conn, ProjectGanttLive, session: %{"id" => project.uuid})
    html = render(view)

    # The popover action is wired (the bar's own phx-value-event-id carries the
    # assignment uuid; the action adds phx-value-project).
    assert html =~ ~s(phx-click="gantt_edit")
    assert html =~ ~s(phx-value-project="#{project.uuid}")

    render_click(view, "gantt_edit", %{"event-id" => a1.uuid, "project" => project.uuid})
    assert_redirect(view, Paths.edit_assignment(project.uuid, a1.uuid))
  end

  test "sub-project bars carry an Open action that drills into the child",
       %{conn: conn} do
    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(project)
    project = Projects.get_project!(project.uuid)

    {:ok, %{child_project: child}} =
      Projects.create_subproject(project.uuid, %{"name" => "Phase"})

    {:ok, view, _html} = live_isolated(conn, ProjectGanttLive, session: %{"id" => project.uuid})
    html = render(view)

    assert html =~ ~s(phx-click="gantt_open")
    assert html =~ ~s(phx-value-child="#{child.uuid}")

    render_click(view, "gantt_open", %{"child" => child.uuid})
    assert_redirect(view, Paths.project(child.uuid))
  end

  test "maps a dependency to a connector path", %{conn: conn, actor_uuid: actor} do
    {project, a1, a2} = started_project_with_tasks(actor)
    {:ok, _} = Projects.add_dependency(a2.uuid, a1.uuid)

    {:ok, view, _html} = live_isolated(conn, ProjectGanttLive, session: %{"id" => project.uuid})
    html = render(view)

    # The SVG connector overlay renders when there's at least one edge.
    assert html =~ "lg-connectors"
    assert html =~ "lg-connector"
    assert html =~ ~s(data-from-id="#{a1.uuid}")
    assert html =~ ~s(data-to-id="#{a2.uuid}")
  end

  test "keeps the user's drag order instead of reordering by dependency",
       %{conn: conn, actor_uuid: actor} do
    # a1 (created first → position 0) DEPENDS ON a2 (position 1) — the manual
    # order places the dependent BEFORE its prerequisite. We no longer silently
    # reorder to dependency order: the chart keeps the order the user gave. The
    # gantt's connector router draws the resulting backward dependency followably
    # and flags it honestly, rather than hiding it behind a reorder.
    {project, a1, a2} = started_project_with_tasks(actor)
    {:ok, _} = Projects.add_dependency(a1.uuid, a2.uuid)

    {:ok, view, _html} = live_isolated(conn, ProjectGanttLive, session: %{"id" => project.uuid})
    html = render(view)

    assert row_index(html, a1.uuid) < row_index(html, a2.uuid),
           "the given order (a1 then a2) must be preserved, not reordered by dependency"

    # ...and the backward dependency is still drawn (the connector router lays it
    # out followably rather than the chart dropping or reordering it). a1 depends
    # on a2, so the edge runs from the prerequisite a2 to the dependent a1.
    assert html =~ "lg-connector"
    assert html =~ ~s(data-from-id="#{a2.uuid}")
    assert html =~ ~s(data-to-id="#{a1.uuid}")
  end

  test "a reorder reflects on an open chart (the :assignment_reordered broadcast)",
       %{conn: conn, actor_uuid: actor} do
    # The chart lays tasks out in `position` order; a reorder in one session must
    # reach another open chart via the broadcast `reorder_assignments` now fires.
    {project, a1, a2} = started_project_with_tasks(actor)

    {:ok, view, _html} = live_isolated(conn, ProjectGanttLive, session: %{"id" => project.uuid})
    assert row_index(render(view), a1.uuid) < row_index(render(view), a2.uuid)

    # Flip the order in the DB (suppress the broadcast so we drive handle_info
    # deterministically), then deliver the event reorder_assignments broadcasts.
    :ok = Projects.reorder_assignments(project.uuid, [a2.uuid, a1.uuid], broadcast: false)
    send(view.pid, {:projects, :assignment_reordered, %{project_uuid: project.uuid}})

    html = render(view)

    assert row_index(html, a2.uuid) < row_index(html, a1.uuid),
           "the chart must reload into the new order when :assignment_reordered arrives"
  end

  test "a project-lifecycle broadcast reloads the chart", %{conn: conn, actor_uuid: actor} do
    # :project_archived / :project_unarchived / :project_status_changed are handled
    # alongside :project_completed/:reopened/:started — a handled event reloads;
    # the catch-all would silently ignore it. Pin that one of the added events
    # actually triggers a reload (a new assignment, added without its own
    # broadcast, only appears if the lifecycle event pulled in fresh data).
    {project, _a1, _a2} = started_project_with_tasks(actor)
    {:ok, view, _html} = live_isolated(conn, ProjectGanttLive, session: %{"id" => project.uuid})

    t3 = fixture_task(%{"estimated_duration" => 1, "estimated_duration_unit" => "days"})

    {:ok, a3} =
      Projects.create_assignment(
        %{"project_uuid" => project.uuid, "task_uuid" => t3.uuid, "status" => "todo"},
        broadcast: false
      )

    refute render(view) =~ a3.uuid
    send(view.pid, {:projects, :project_archived, %{uuid: project.uuid}})

    assert render(view) =~ a3.uuid,
           "a handled project-lifecycle event must reload the chart"
  end

  test "maps a dependency BETWEEN sub-project tasks to a connector (tree-wide)",
       %{conn: conn} do
    # A dependency between two tasks INSIDE a sub-project is stored on the CHILD
    # project, not the parent. The gantt must gather dependencies across the
    # whole rendered tree — the old parent-only query returned nothing, so a
    # project built entirely from sub-project tasks showed NO arrows at all.
    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(project)
    project = Projects.get_project!(project.uuid)

    {:ok, %{child_project: child, assignment: link}} =
      Projects.create_subproject(project.uuid, %{"name" => "Phase 1"})

    t1 = fixture_task(%{"estimated_duration" => 2, "estimated_duration_unit" => "days"})
    t2 = fixture_task(%{"estimated_duration" => 2, "estimated_duration_unit" => "days"})

    {:ok, c1} =
      Projects.create_assignment(%{"project_uuid" => child.uuid, "task_uuid" => t1.uuid})

    {:ok, c2} =
      Projects.create_assignment(%{"project_uuid" => child.uuid, "task_uuid" => t2.uuid})

    {:ok, _} = Projects.add_dependency(c2.uuid, c1.uuid)

    {:ok, view, _html} = live_isolated(conn, ProjectGanttLive, session: %{"id" => project.uuid})
    # Expand so both child tasks are visible; the intra-sub-project arrow draws.
    html = render_click(view, "toggle_subproject", %{"event-id" => link.uuid})

    assert html =~ "lg-connector"
    assert html =~ ~s(data-from-id="#{c1.uuid}")
    assert html =~ ~s(data-to-id="#{c2.uuid}")
  end

  test "expanding a sub-project keeps it in place (stable row order)", %{conn: conn} do
    # Sub-projects carry `extra.order` so the chart keeps the flattened tree
    # order. Without it the library auto-places rows by dependency/date, and
    # expanding a sub-project re-sorts its rolled-up bar below its siblings.
    # The reorder only surfaces once connectors exist (they drive the auto-sort),
    # so Phase A gets an intra-phase dependency.
    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(project)
    project = Projects.get_project!(project.uuid)

    {:ok, %{child_project: pa, assignment: la}} =
      Projects.create_subproject(project.uuid, %{"name" => "Phase A"})

    {:ok, %{child_project: pb, assignment: lb}} =
      Projects.create_subproject(project.uuid, %{"name" => "Phase B"})

    t1 = fixture_task(%{"estimated_duration" => 2, "estimated_duration_unit" => "days"})
    t2 = fixture_task(%{"estimated_duration" => 2, "estimated_duration_unit" => "days"})
    {:ok, a1} = Projects.create_assignment(%{"project_uuid" => pa.uuid, "task_uuid" => t1.uuid})
    {:ok, a2} = Projects.create_assignment(%{"project_uuid" => pa.uuid, "task_uuid" => t2.uuid})
    {:ok, _} = Projects.add_dependency(a2.uuid, a1.uuid)

    tb = fixture_task(%{"estimated_duration" => 2, "estimated_duration_unit" => "days"})
    {:ok, _} = Projects.create_assignment(%{"project_uuid" => pb.uuid, "task_uuid" => tb.uuid})

    {:ok, view, _html} = live_isolated(conn, ProjectGanttLive, session: %{"id" => project.uuid})
    html = render_click(view, "toggle_subproject", %{"event-id" => la.uuid})

    # Rows render in order; the FIRST occurrence of each id (its label row) gives
    # the row order. Phase A stays before Phase B, with A's children between them.
    a_pos = row_index(html, la.uuid)
    a1_pos = row_index(html, a1.uuid)
    b_pos = row_index(html, lb.uuid)

    assert a_pos >= 0 and a1_pos >= 0 and b_pos >= 0
    assert a_pos < a1_pos, "Phase A must stay above its own child"
    assert a1_pos < b_pos, "Phase A's child must stay above Phase B (no reorder)"
  end

  defp row_index(html, uuid) do
    case :binary.match(html, "data-event-id=\"#{uuid}\"") do
      {pos, _} -> pos
      :nomatch -> -1
    end
  end

  test "live-updates the chart when a sub-project task changes (PubSub)", %{conn: conn} do
    # "Open it on a monitor and it stays current." A sub-project's task
    # broadcasts on the CHILD project's topic; the gantt subscribes to the whole
    # tree, so a status change inside a sub-project must refresh the chart with
    # no client interaction. (Subscribing to only the root project missed this.)
    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(project)
    project = Projects.get_project!(project.uuid)

    {:ok, %{child_project: child, assignment: link}} =
      Projects.create_subproject(project.uuid, %{"name" => "Phase"})

    t = fixture_task(%{"estimated_duration" => 2, "estimated_duration_unit" => "days"})

    {:ok, child_a} =
      Projects.create_assignment(%{
        "project_uuid" => child.uuid,
        "task_uuid" => t.uuid,
        "status" => "todo"
      })

    {:ok, view, _html} = live_isolated(conn, ProjectGanttLive, session: %{"id" => project.uuid})
    render_click(view, "toggle_subproject", %{"event-id" => link.uuid})
    refute render(view) =~ "bg-success"

    # Change the sub-project task's status "from outside" — the context
    # broadcasts on the child topic; the LiveView never receives a client event.
    {:ok, _} = Projects.update_assignment_status(child_a, %{"status" => "done"})

    # The gantt got the broadcast and re-rendered the bar in the "done" color.
    assert render(view) =~ "bg-success"
  end

  test "zoom switcher updates the chart", %{conn: conn, actor_uuid: actor} do
    {project, _a1, _a2} = started_project_with_tasks(actor)

    {:ok, view, _html} = live_isolated(conn, ProjectGanttLive, session: %{"id" => project.uuid})

    html = render_click(view, "set_zoom", %{"zoom" => "day"})
    # Day zoom renders per-day column headers (numeric day labels).
    assert html =~ "lg-col-header"
    # A bogus zoom is ignored, not crashed.
    assert render_click(view, "set_zoom", %{"zoom" => "decade"}) =~ "lg-wrap"
  end

  test "initial zoom auto-fits the project span", %{conn: conn, actor_uuid: actor} do
    # ~5-day span (2d + 3d tasks) → should open at :day, not the old fixed :week.
    {project, _a1, _a2} = started_project_with_tasks(actor)

    {:ok, view, _html} = live_isolated(conn, ProjectGanttLive, session: %{"id" => project.uuid})
    html = render(view)

    # The :day zoom button is the active one (aria-pressed="true").
    assert html =~
             ~r/phx-value-zoom="day"[^>]*aria-pressed="true"|aria-pressed="true"[^>]*phx-value-zoom="day"/
  end

  test "hour zoom lays tasks out at sub-day precision (widths differ by duration)",
       %{conn: conn} do
    project = fixture_project(%{"start_mode" => "immediate", "counts_weekends" => true})
    {:ok, _} = Projects.start_project(project)
    project = Projects.get_project!(project.uuid)

    t_short = fixture_task(%{"estimated_duration" => 2, "estimated_duration_unit" => "hours"})
    t_long = fixture_task(%{"estimated_duration" => 6, "estimated_duration_unit" => "hours"})

    {:ok, a_short} =
      Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => t_short.uuid})

    {:ok, a_long} =
      Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => t_long.uuid})

    {:ok, view, _html} = live_isolated(conn, ProjectGanttLive, session: %{"id" => project.uuid})
    html = render_click(view, "set_zoom", %{"zoom" => "hour"})

    short_w = bar_width_px(html, a_short.uuid)
    long_w = bar_width_px(html, a_long.uuid)

    # At hour zoom (30px/hour): 2h ≈ 60px, 6h ≈ 180px — day-quantized layout
    # would make both equal. Assert the longer task is meaningfully wider.
    assert long_w > short_w
    assert long_w >= 120
  end

  test "sub-project children are emitted with parent_id and a chevron", %{conn: conn} do
    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(project)
    project = Projects.get_project!(project.uuid)

    {:ok, %{child_project: child, assignment: link}} =
      Projects.create_subproject(project.uuid, %{"name" => "Phase 1"})

    child_task = fixture_task(%{"estimated_duration" => 1, "estimated_duration_unit" => "days"})

    {:ok, child_assignment} =
      Projects.create_assignment(%{
        "project_uuid" => child.uuid,
        "task_uuid" => child_task.uuid
      })

    {:ok, view, _html} = live_isolated(conn, ProjectGanttLive, session: %{"id" => project.uuid})
    html = render(view)

    # Collapsed: the expand chevron renders (the library detected a
    # sub-project because the child is in the event list), but the child's
    # own bar is hidden until expanded.
    assert html =~ "lg-subproject-chevron"
    refute html =~ child_assignment.uuid

    # Expanding reveals the child task's bar.
    expanded = render_click(view, "toggle_subproject", %{"event-id" => link.uuid})
    assert expanded =~ child_assignment.uuid
  end

  test "sub-project bar spans its children, not just its rolled-up hours", %{conn: conn} do
    project = fixture_project(%{"start_mode" => "immediate", "counts_weekends" => true})
    {:ok, _} = Projects.start_project(project)
    project = Projects.get_project!(project.uuid)

    {:ok, %{child_project: child, assignment: link}} =
      Projects.create_subproject(project.uuid, %{"name" => "Phase 1"})

    # Two SHORT child tasks: rolled-up work hours are < 1 day, but laid out
    # sequentially each is padded to a ≥1-day bar → the sub-project must span
    # ~2 days. The old bug sized the bar from rolled-up hours (~1 day), leaving
    # the second child spilling outside the bar/frame.
    for _ <- 1..2 do
      t = fixture_task(%{"estimated_duration" => 2, "estimated_duration_unit" => "hours"})

      {:ok, _} =
        Projects.create_assignment(%{"project_uuid" => child.uuid, "task_uuid" => t.uuid})
    end

    {:ok, view, _html} = live_isolated(conn, ProjectGanttLive, session: %{"id" => project.uuid})
    html = render_click(view, "toggle_subproject", %{"event-id" => link.uuid})

    # Parse the sub-project bar's pixel width from its rendered style. At week
    # zoom (24px/day) a 2-day span is 48px; a 1-day stub would be 24px.
    width = bar_width_px(html, link.uuid)

    assert width >= 40,
           "sub-project bar (#{width}px) should span its 2 children (~48px), not stub"
  end

  # The bar's width renders as a PERCENTAGE of the content width (responsive
  # layout); reconstruct pixels via `% × content_width` (the timeline's
  # `min-width`) so the px-based assertions still hold.
  defp bar_width_px(html, event_id) do
    pct =
      case Regex.run(
             ~r/style="[^"]*?width:\s*([\d.]+)%[^"]*?"[^>]*?data-event-id="#{event_id}"/,
             html
           ) ||
             Regex.run(~r/data-event-id="#{event_id}"[^>]*?style="[^"]*?width:\s*([\d.]+)%/, html) do
        [_, p] -> elem(Float.parse(p), 0)
        _ -> 0.0
      end

    content_width =
      case Regex.run(~r/min-width:\s*(\d+)px/, html) do
        [_, w] -> String.to_integer(w)
        _ -> 0
      end

    round(pct / 100 * content_width)
  end

  test "empty project shows the empty state, no chart", %{conn: conn} do
    project = fixture_project(%{"start_mode" => "immediate"})

    {:ok, view, _html} = live_isolated(conn, ProjectGanttLive, session: %{"id" => project.uuid})
    html = render(view)

    refute html =~ "lg-wrap"
    assert html =~ "No tasks to chart yet."
  end
end
