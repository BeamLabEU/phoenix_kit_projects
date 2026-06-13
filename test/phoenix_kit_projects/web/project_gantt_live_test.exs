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

    {:ok, _view, html} = live(conn, Paths.project_gantt(project.uuid))

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

    {:ok, view, html} = live(conn, Paths.project_gantt(project.uuid))

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

    {:ok, view, html} = live(conn, Paths.project_gantt(project.uuid))

    assert html =~ ~s(phx-click="gantt_open")
    assert html =~ ~s(phx-value-child="#{child.uuid}")

    render_click(view, "gantt_open", %{"child" => child.uuid})
    assert_redirect(view, Paths.project(child.uuid))
  end

  test "maps a dependency to a connector path", %{conn: conn, actor_uuid: actor} do
    {project, a1, a2} = started_project_with_tasks(actor)
    {:ok, _} = Projects.add_dependency(a2.uuid, a1.uuid)

    {:ok, _view, html} = live(conn, Paths.project_gantt(project.uuid))

    # The SVG connector overlay renders when there's at least one edge.
    assert html =~ "lg-connectors"
    assert html =~ "lg-connector"
    assert html =~ ~s(data-from-id="#{a1.uuid}")
    assert html =~ ~s(data-to-id="#{a2.uuid}")
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

    {:ok, view, _html} = live(conn, Paths.project_gantt(project.uuid))
    # Expand so both child tasks are visible; the intra-sub-project arrow draws.
    html = render_click(view, "toggle_subproject", %{"event-id" => link.uuid})

    assert html =~ "lg-connector"
    assert html =~ ~s(data-from-id="#{c1.uuid}")
    assert html =~ ~s(data-to-id="#{c2.uuid}")
  end

  test "zoom switcher updates the chart", %{conn: conn, actor_uuid: actor} do
    {project, _a1, _a2} = started_project_with_tasks(actor)

    {:ok, view, _html} = live(conn, Paths.project_gantt(project.uuid))

    html = render_click(view, "set_zoom", %{"zoom" => "day"})
    # Day zoom renders per-day column headers (numeric day labels).
    assert html =~ "lg-col-header"
    # A bogus zoom is ignored, not crashed.
    assert render_click(view, "set_zoom", %{"zoom" => "decade"}) =~ "lg-wrap"
  end

  test "initial zoom auto-fits the project span", %{conn: conn, actor_uuid: actor} do
    # ~5-day span (2d + 3d tasks) → should open at :day, not the old fixed :week.
    {project, _a1, _a2} = started_project_with_tasks(actor)

    {:ok, _view, html} = live(conn, Paths.project_gantt(project.uuid))

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

    {:ok, view, _html} = live(conn, Paths.project_gantt(project.uuid))
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

    {:ok, view, html} = live(conn, Paths.project_gantt(project.uuid))

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

    {:ok, view, _html} = live(conn, Paths.project_gantt(project.uuid))
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

    {:ok, _view, html} = live(conn, Paths.project_gantt(project.uuid))

    refute html =~ "lg-wrap"
    assert html =~ "No tasks to chart yet."
  end
end
