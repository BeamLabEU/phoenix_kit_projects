defmodule PhoenixKitProjects.Web.OverviewWidgetsTest do
  @moduledoc """
  The Overview dashboard's pieces as `phoenix_kit_dashboards` widgets:
  `projects.running` (the Running list in `RunningTiers` order) and
  `projects.upcoming` (setup + scheduled / recently completed).
  """

  use PhoenixKitProjects.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKitProjects.{Projects, RunningTiers}
  alias PhoenixKitProjects.Web.Widgets.{CalendarWidget, RunningWidget, UpcomingWidget}

  setup do
    PhoenixKit.Settings.update_setting("projects_enabled", "true")

    admin =
      PhoenixKitProjects.LiveCase.fake_scope(permissions: ["projects", "projects.admin_all"])

    {:ok, admin: admin}
  end

  defp started!(name, started_at) do
    {:ok, p} =
      Projects.create_project(%{
        "name" => name,
        "start_mode" => "immediate",
        "started_at" => DateTime.truncate(started_at, :second)
      })

    p
  end

  # One-day tasks: a project's planned end is started_at + the sum of its
  # durations, so hour-long tasks would put every project past its plan
  # (= late) within the hour it was started.
  defp with_task!(project, title, status) do
    t =
      fixture_task(%{
        "title" => title,
        "estimated_duration" => 1,
        "estimated_duration_unit" => "days"
      })

    {:ok, a} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => t.uuid,
        "status" => status
      })

    a
  end

  describe "RunningTiers" do
    test "orders late, near done, on track, empty — and caps" do
      now = DateTime.utc_now()
      today = DateTime.to_date(now)

      late = started!("Late", DateTime.add(now, -30, :day))
      with_task!(late, "L1", "todo")
      near = started!("Near", DateTime.add(now, -1, :day))
      with_task!(near, "N1", "done")
      with_task!(near, "N2", "done")
      with_task!(near, "N3", "done")
      with_task!(near, "N4", "todo")
      fresh = started!("Fresh", now)
      with_task!(fresh, "F1", "todo")
      empty = started!("Empty", DateTime.add(now, -60, :day))

      tagged =
        [empty, fresh, near, late]
        |> Enum.map(&Projects.project_tree_summary/1)
        |> Enum.map(&RunningTiers.tag(&1, now))

      assert Enum.map(tagged, & &1.tier) == [:empty, :on_track, :near_done, :late]

      {rows, total} = RunningTiers.prioritize(tagged, today, now, 3)
      assert total == 4
      assert Enum.map(rows, & &1.project.name) == ["Late", "Near", "Fresh"]
      assert hd(rows).late
    end
  end

  describe "projects.running" do
    test "renders the Overview's running order with tier and progress", %{admin: admin} do
      now = DateTime.utc_now()
      late = started!("Widget late", DateTime.add(now, -30, :day))
      with_task!(late, "WL", "todo")
      fresh = started!("Widget fresh", now)
      with_task!(fresh, "WF", "todo")

      html = render_component(RunningWidget, id: "w-run", view: "compact", scope: admin)
      assert html =~ "Running projects"
      # Late first.
      assert String.length(html) > 0
      {li, _} = :binary.match(html, "Widget late")
      {fi, _} = :binary.match(html, "Widget fresh")
      assert li < fi
      assert html =~ "0% · 0/1"

      # The late-only setting narrows to the late tier and retitles.
      html =
        render_component(RunningWidget,
          id: "w-late",
          view: "compact",
          scope: admin,
          settings: %{"late_only" => "true"}
        )

      assert html =~ "Late projects"
      assert html =~ "Widget late"
      refute html =~ "Widget fresh"

      # Cards view renders the running_card outline.
      html = render_component(RunningWidget, id: "w-cards", view: "cards", scope: admin)
      assert html =~ "Widget late"
    end

    test "empty and unscoped states never raise" do
      html = render_component(RunningWidget, id: "w-empty", view: "compact", scope: nil)
      assert html =~ "Nothing running right now."
    end
  end

  describe "projects.calendar" do
    test "tasks mode puts each scheduled task on the month grid; projects mode one line per project",
         %{admin: admin} do
      now = DateTime.utc_now()
      p = started!("Cal project", now)
      with_task!(p, "Pour the slab", "todo")

      html = render_component(CalendarWidget, id: "w-cal", view: "month", scope: admin)
      assert html =~ "Tasks calendar"
      assert html =~ "Pour the slab"

      html =
        render_component(CalendarWidget,
          id: "w-cal-p",
          view: "month",
          scope: admin,
          settings: %{"mode" => "projects"}
        )

      assert html =~ "Projects calendar"
      assert html =~ "Cal project"

      # Agenda view renders the same events as a list.
      html = render_component(CalendarWidget, id: "w-cal-a", view: "agenda", scope: admin)
      assert html =~ "Pour the slab"

      # "Only mine" with no resolvable viewer shows nothing rather than everything.
      html =
        render_component(CalendarWidget,
          id: "w-cal-m",
          view: "month",
          scope: admin,
          settings: %{"only_mine" => "true"}
        )

      refute html =~ "Pour the slab"
    end
  end

  describe "projects.upcoming" do
    test "upcoming lists setup then scheduled, completed lists newest first", %{admin: admin} do
      {:ok, _setup} =
        Projects.create_project(%{"name" => "In setup", "start_mode" => "immediate"})

      {:ok, _sched} =
        Projects.create_project(%{
          "name" => "Scheduled soon",
          "start_mode" => "scheduled",
          "scheduled_start_date" =>
            DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)
        })

      done = started!("Finished one", DateTime.add(DateTime.utc_now(), -5, :day))
      a = with_task!(done, "D1", "todo")
      {:ok, _} = Projects.update_assignment_status(a, %{"status" => "done"})
      {:completed, _} = Projects.recompute_project_completion(done.uuid)

      html = render_component(UpcomingWidget, id: "w-up", view: "upcoming", scope: admin)
      assert html =~ "Upcoming projects"
      assert html =~ "In setup" and html =~ "not started"
      assert html =~ "Scheduled soon" and html =~ "in 3 days"
      refute html =~ "Finished one"

      html = render_component(UpcomingWidget, id: "w-done", view: "completed", scope: admin)
      assert html =~ "Recently completed"
      assert html =~ "Finished one" and html =~ "today"
      refute html =~ "In setup"
    end
  end
end
