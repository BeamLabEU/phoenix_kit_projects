defmodule PhoenixKitProjects.Web.TaskRowBoardTest do
  @moduledoc """
  The task list's row, the board and the task view after the boss's
  feedback of 2026-10-29: the deadline as the one red chip and the planned
  days neutral; who has a task as faces; no "Waiting on" / "Requested by"
  on these screens; one ✕ on the view in a drawer; the whole board column
  a drop target, and a drop that says what really happened; the project's
  link out in its header.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{L10n, Projects}
  alias PhoenixKitProjects.Schemas.Assignment
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitProjects.Web.AssignmentViewLive
  alias PhoenixKitProjects.Web.Components.TaskTimes
  alias PhoenixKitStaff.{Departments, Staff, Teams}

  defp uniq, do: System.unique_integer([:positive])

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "row-board-#{uniq()}@example.com",
        "password" => "ActorPass123!"
      })

    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: user.uuid)), user: user}
  end

  defp task(project, title, attrs \\ %{}) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        attrs
      )

    a
  end

  defp in_hours(h),
    do: DateTime.utc_now() |> DateTime.add(h * 3600) |> DateTime.truncate(:second)

  defp show(conn, project), do: live(conn, "/en/admin/projects/#{project.uuid}")

  describe "the deadline and the planned days" do
    test "the row's deadline chip: red when missed, amber when close, an outline otherwise",
         %{conn: conn} do
      project = fixture_project()
      _ = task(project, "Missed", %{"deadline" => DateTime.to_iso8601(in_hours(-3))})
      _ = task(project, "Close", %{"deadline" => DateTime.to_iso8601(in_hours(1))})
      _ = task(project, "Far", %{"deadline" => DateTime.to_iso8601(in_hours(24 * 40))})

      {:ok, view, _html} = show(conn, project)

      assert has_element?(
               view,
               ~s([data-pkp-card] [data-deadline="overdue"].badge-error[title="Past its deadline"])
             )

      assert has_element?(view, ~s([data-pkp-card] [data-deadline="soon"].badge-warning))
      assert has_element?(view, ~s([data-pkp-card] [data-deadline="set"].badge-outline))
      # The board's cards carry it too, calmer: the colour in the outline.
      assert has_element?(view, ~s([id^="board-card-"] [data-deadline="overdue"].text-error))
    end

    test "a done task's passed deadline is not red", %{conn: conn} do
      project = fixture_project()

      _ =
        task(project, "Shipped late", %{
          "deadline" => DateTime.to_iso8601(in_hours(-3)),
          "status" => "done"
        })

      {:ok, _view, html} = show(conn, project)
      refute html =~ "Past its deadline"
    end

    test "the planned days are neutral and say their times" do
      year = Date.utc_today().year

      a = %Assignment{
        start_date: Date.new!(year, 10, 12),
        end_date: Date.new!(year, 10, 14),
        start_time: ~T[14:00:00],
        end_time: ~T[17:00:00]
      }

      assert TaskTimes.planned_label(a) == "Oct 12 14:00 – Oct 14 17:00"
      assert TaskTimes.planned_label(%{a | end_date: a.start_date}) == "Oct 12 14:00 – 17:00"
      assert TaskTimes.planned_label(%{a | end_date: nil}) == "from Oct 12 14:00"
      assert TaskTimes.planned_label(%Assignment{start_date: nil, end_date: nil}) == nil

      html = render_component(&TaskTimes.planned_chip/1, a: %{a | end_date: ~D[2020-01-01]})
      assert html =~ ~s(title="Planned")
      refute html =~ "badge-error"
    end

    test "a deadline reads Today / Tomorrow / a day, on the viewer's clock" do
      L10n.reset_viewer_zone()
      now = ~U[2026-10-29 10:00:00Z]

      assert TaskTimes.deadline_label(~U[2026-10-29 15:00:00Z], now) == "Today 15:00"
      assert TaskTimes.deadline_label(~U[2026-10-30 09:00:00Z], now) == "Tomorrow 09:00"
      assert TaskTimes.deadline_label(~U[2026-10-31 15:00:00Z], now) == "Oct 31 15:00"
      assert TaskTimes.deadline_label(~U[2027-01-02 08:30:00Z], now) =~ "2027"
    end
  end

  describe "who has a task, as faces" do
    defp person!(name) do
      {:ok, user} =
        Auth.register_user(%{
          "email" => "face-#{uniq()}@example.com",
          "password" => "FacePass123!"
        })

      {:ok, person} =
        Staff.create_person(%{
          "user_uuid" => user.uuid,
          "name" => name,
          "employment_type" => "full_time"
        })

      person
    end

    test "a person's task and a team's task show their faces on the row and the card",
         %{conn: conn} do
      anna = person!("Anna Face-#{uniq()}")
      bob = person!("Bob Face-#{uniq()}")
      {:ok, dept} = Departments.create(%{"name" => "Workshop-#{uniq()}"})

      {:ok, team} =
        Teams.create(%{"name" => "Fitters-#{uniq()}", "department_uuid" => dept.uuid})

      {:ok, _} = Staff.add_team_person(team.uuid, anna.uuid)
      {:ok, _} = Staff.add_team_person(team.uuid, bob.uuid)

      project = fixture_project()
      mine = task(project, "Measure", %{"assigned_person_uuid" => anna.uuid})
      theirs = task(project, "Fit", %{"assigned_team_uuid" => team.uuid})
      nobody = task(project, "Someday")

      {:ok, view, _html} = show(conn, project)

      assert has_element?(view, ~s([data-pkp-card="#{mine.uuid}"] span[title="#{anna.name}"]))
      assert has_element?(view, ~s(#board-card-#{mine.uuid} span[title="#{anna.name}"]))

      # A team is a stack of its people.
      team_title = Enum.join(Enum.sort([anna.name, bob.name]), ", ")
      assert has_element?(view, ~s([data-pkp-card="#{theirs.uuid}"] span[title="#{team_title}"]))
      assert has_element?(view, ~s(#board-card-#{theirs.uuid} span[title="#{team_title}"]))

      # Unassigned stays words, no faces.
      assert view |> element("#board-card-#{nobody.uuid}") |> render() =~ "Unassigned"
      refute has_element?(view, ~s(#board-card-#{nobody.uuid} .ring-base-100))
    end

    test "the task view shows the assignee's face", %{conn: conn} do
      anna = person!("Anna View-#{uniq()}")
      project = fixture_project()
      a = task(project, "Measure", %{"assigned_person_uuid" => anna.uuid})

      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}/assignments/#{a.uuid}")
      assert has_element?(view, ~s(dd span[title="#{anna.name}"]))
    end
  end

  describe "no waiting-on or requested-by on these screens" do
    test "the row, its menu and the view say neither; the data stays", %{conn: conn} do
      project = fixture_project()

      a =
        task(project, "Quote", %{"waiting_on" => "the client's answer", "origin" => "an email"})

      {:ok, _view, html} = show(conn, project)
      refute html =~ "the client&#39;s answer"
      refute html =~ "Waiting on"
      refute html =~ "Mark as waiting on"
      refute html =~ "from an email"

      {:ok, _view, html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/#{a.uuid}")

      refute html =~ "Waiting for"
      refute html =~ "Requested by"
      refute html =~ "an email"

      assert %{waiting_on: "the client's answer", origin: "an email"} =
               Projects.get_assignment(a.uuid)
    end

    test "the row menu's Done step reads Mark done", %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate"})
      a = task(project, "Ready one", %{"status" => "todo"})

      {:ok, view, _html} = show(conn, project)
      menu = view |> element("#assignment-menu-#{a.uuid}") |> render()
      assert menu =~ "Mark done"
      assert menu =~ "phx-disable-with"
    end
  end

  describe "the task view's close button" do
    test "in a drawer it draws none (the drawer has its ✕); on its own page it has one",
         %{conn: conn, user: user} do
      project = fixture_project()
      a = task(project, "Measure")
      {:ok, _} = PhoenixKitProjects.Members.add_member(project, user.uuid, role: "member")

      {:ok, view, _html} =
        live_isolated(conn, AssignmentViewLive,
          session: %{
            "project_id" => project.uuid,
            "id" => a.uuid,
            "current_user_uuid" => user.uuid,
            "mode" => "emit",
            "pubsub_topic" => "row-board-#{uniq()}",
            "frame_ref" => 1
          }
        )

      refute has_element?(view, ~s(button[phx-click="close"]))

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/#{a.uuid}")

      assert has_element?(view, ~s(button[phx-click="close"][aria-label="Close"]))
    end
  end

  describe "the board" do
    test "every column, empty or not, is a drop target that fills the column", %{conn: conn} do
      project = fixture_project()
      a = task(project, "Only one", %{"status" => "waiting"})

      {:ok, view, html} = show(conn, project)

      for status <- ~w(waiting todo done) do
        assert has_element?(
                 view,
                 ~s(#board-column-#{status}.flex-1[phx-hook="PkpBoard"][data-board-status="#{status}"][data-board-event="board_move"])
               )
      end

      # The empty column's note sits inside the drop zone, not above it.
      assert has_element?(view, "#board-column-done > .pkp-board-empty")
      refute has_element?(view, "#board-column-waiting > .pkp-board-empty")
      # The whole card is what is dragged: an id of its own, no handle.
      assert has_element?(view, ~s(#board-column-waiting > #board-card-#{a.uuid}.sortable-item))
      refute has_element?(view, "[id^=board-column-][data-sortable-handle]")
      refute html =~ ~r/grid[^"]*items-start[^"]*md:grid-cols/
    end

    test "a drop that lands says so", %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate"})
      a = task(project, "Finish", %{"status" => "todo"})

      {:ok, view, _html} = show(conn, project)

      render_hook(view, "board_move", %{
        "moved_id" => a.uuid,
        "status" => "done",
        "ordered_ids" => [a.uuid]
      })

      assert_push_event(view, "sortable:flash", %{status: "ok"})
      assert Projects.get_assignment(a.uuid).status == "done"
    end

    test "a waiting card dropped into In progress is released through its dialog, not started",
         %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate"})
      a = task(project, "Held", %{"status" => "waiting"})

      {:ok, view, _html} = show(conn, project)

      render_hook(view, "board_move", %{
        "moved_id" => a.uuid,
        "status" => "in_progress",
        "ordered_ids" => [a.uuid]
      })

      assert Projects.get_assignment(a.uuid).status == "waiting"
      # The card waits for the answer, marked, in its own column.
      assert has_element?(
               view,
               ~s(#board-column-waiting > #board-card-#{a.uuid}.ring-info[title="Waiting for your answer"])
             )
    end

    test "a drop the step refuses goes back, said in red", %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, %{assignment: row}} = Projects.create_subproject(project.uuid, %{"name" => "Inner"})
      row = row |> Ecto.Changeset.change(status: "waiting") |> Repo.update!()

      {:ok, view, _html} = show(conn, project)

      html =
        render_hook(view, "board_move", %{
          "moved_id" => row.uuid,
          "status" => "todo",
          "ordered_ids" => [row.uuid]
        })

      assert_push_event(view, "sortable:flash", %{status: "error"})
      assert html =~ "This task cannot move there."
      assert Projects.get_assignment(row.uuid).status == "waiting"
    end
  end

  describe "the project's link out" do
    test "a web address opens in a new tab, without a way back", %{conn: conn} do
      project = fixture_project()

      {:ok, project} =
        Projects.update_project(project, %{
          "external_url" => "https://shop.example.com/orders/1042",
          "external_label" => "Order #1042"
        })

      {:ok, view, _html} = show(conn, project)

      assert has_element?(
               view,
               ~s(a[data-project-link][href="https://shop.example.com/orders/1042"][target="_blank"][rel="noopener noreferrer"]),
               "Order #1042"
             )
    end

    test "a path on this site opens in the same tab, as stored; no label says Open link",
         %{conn: conn} do
      project = fixture_project()
      path = "/admin/andi/sub-orders/#{Ecto.UUID.generate()}"
      {:ok, project} = Projects.update_project(project, %{"external_url" => path})

      {:ok, view, _html} = show(conn, project)
      assert has_element?(view, ~s(a[data-project-link][href="#{path}"]), "Open link")
      refute has_element?(view, ~s(a[data-project-link][target]))
    end

    test "no address, no button", %{conn: conn} do
      project = fixture_project()
      {:ok, view, _html} = show(conn, project)
      refute has_element?(view, "a[data-project-link]")
    end

    test "the form saves a link and refuses a javascript: one", %{conn: conn} do
      project = fixture_project()
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}/edit")

      html =
        view
        |> form("#project-form", project: %{"external_url" => "javascript:alert(1)"})
        |> render_submit()

      assert html =~ "must be a web address (https://…) or a path on this site (/…)"
      assert is_nil(Projects.get_project(project.uuid).external_url)

      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}/edit")

      view
      |> form("#project-form",
        project: %{"external_url" => "https://example.com/o/7", "external_label" => "Order #7"}
      )
      |> render_submit()

      saved = Projects.get_project(project.uuid)
      assert saved.external_url == "https://example.com/o/7"
      assert saved.external_label == "Order #7"
    end
  end
end
