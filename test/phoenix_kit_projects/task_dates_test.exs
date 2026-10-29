defmodule PhoenixKitProjects.TaskDatesTest do
  @moduledoc """
  A task's own dates (V21): two optional calendar days, either alone, the
  end never before the start; where a dated task sits in the schedule, on
  its row, in the form and over the API.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, CalendarDisplay, Projects, ScheduleLayout}
  alias PhoenixKitProjects.Schemas.{Assignment, Project}

  @base "/api/projects/v1"

  defp task(project, title, attrs \\ %{}) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        attrs
      )

    a
  end

  describe "the schema" do
    test "either date may stand alone; the end is never before the start" do
      project = fixture_project()

      a = task(project, "Only a start", %{"start_date" => "2026-10-12"})
      assert a.start_date == ~D[2026-10-12] and is_nil(a.end_date)

      b = task(project, "Only an end", %{"end_date" => "2026-10-14"})
      assert b.end_date == ~D[2026-10-14] and is_nil(b.start_date)

      cs = Assignment.changeset(a, %{"end_date" => "2026-10-11"})
      refute cs.valid?
      assert {_, _} = cs.errors[:end_date]

      assert {:ok, same_day} = Projects.update_assignment_form(a, %{"end_date" => "2026-10-12"})
      assert same_day.end_date == ~D[2026-10-12]
    end

    test "overdue: the deadline has passed and the task is not done; planned days never" do
      a = %Assignment{deadline: ~U[2026-10-05 15:00:00Z], status: "todo"}
      assert Assignment.overdue?(a, ~U[2026-10-05 15:01:00Z])
      refute Assignment.overdue?(a, ~U[2026-10-05 14:59:00Z])
      refute Assignment.overdue?(%{a | status: "done"}, ~U[2026-10-06 00:00:00Z])
      refute Assignment.overdue?(%Assignment{status: "todo"}, ~U[2026-10-06 00:00:00Z])

      planned_only = %Assignment{end_date: ~D[2026-10-01], status: "todo"}
      refute Assignment.overdue?(planned_only, ~U[2026-10-06 00:00:00Z])

      assert Assignment.deadline_state(a, ~U[2026-10-05 13:30:00Z]) == :soon
      assert Assignment.deadline_state(a, ~U[2026-10-05 10:00:00Z]) == :set
      assert Assignment.deadline_state(a, ~U[2026-10-05 16:00:00Z]) == :overdue
    end

    test "a planned day may carry a time; the same day's end is not before its start" do
      cs =
        Assignment.changeset(%Assignment{project_uuid: Ecto.UUID.generate(), status: "todo"}, %{
          "start_date" => "2026-10-12",
          "end_date" => "2026-10-12",
          "start_time" => "14:00",
          "end_time" => "09:00"
        })

      assert {_, _} = cs.errors[:end_date]
    end

    test "the real start is stamped on the way into in progress, and kept" do
      cs = Assignment.changeset(%Assignment{status: "todo"}, %{"status" => "in_progress"})
      assert %DateTime{} = Ecto.Changeset.get_change(cs, :started_at)

      earlier = ~U[2026-10-01 08:00:00Z]

      cs =
        Assignment.changeset(%Assignment{status: "todo", started_at: earlier}, %{
          "status" => "in_progress"
        })

      refute Ecto.Changeset.get_change(cs, :started_at)
    end

    test "a real time the status depends on can be moved, not removed" do
      done = %Assignment{
        status: "done",
        started_at: ~U[2026-10-05 08:00:00Z],
        completed_at: ~U[2026-10-05 09:00:00Z]
      }

      refute Assignment.times_changeset(done, %{completed_at: nil}).valid?
      refute Assignment.times_changeset(done, %{started_at: nil}).valid?

      waiting = %Assignment{status: "todo", started_at: ~U[2026-10-05 08:00:00Z]}
      assert Assignment.times_changeset(waiting, %{started_at: nil}).valid?
    end

    test "clearing a project's link leaves it empty, without a crash" do
      project = %Project{
        name: "P",
        start_mode: "immediate",
        external_url: "/admin/x"
      }

      cs = Project.changeset(project, %{"external_url" => ""})
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :external_url) == nil
    end

    test "the real times can be corrected, not into the future nor reversed" do
      a = %Assignment{status: "done"}
      later = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)

      assert Assignment.times_changeset(a, %{completed_at: ~U[2026-10-05 09:00:00Z]}).valid?
      refute Assignment.times_changeset(a, %{completed_at: later}).valid?

      refute Assignment.times_changeset(a, %{
               started_at: ~U[2026-10-05 10:00:00Z],
               completed_at: ~U[2026-10-05 09:00:00Z]
             }).valid?
    end
  end

  describe "the schedule" do
    test "a dated task sits on its days; the others are still placed by the walk" do
      project = fixture_project()

      plain =
        task(project, "Plain", %{"estimated_duration" => 2, "estimated_duration_unit" => "hours"})

      both = task(project, "Both", %{"start_date" => "2027-03-01", "end_date" => "2027-03-03"})
      due = task(project, "Due", %{"end_date" => "2027-03-10"})

      from =
        task(project, "From", %{
          "start_date" => "2027-04-01",
          "estimated_duration" => 3,
          "estimated_duration_unit" => "days"
        })

      {_items, layout} = ScheduleLayout.tree(Projects.get_project!(project.uuid))

      refute Map.has_key?(layout[plain.uuid], :pinned)

      assert %{start: ~N[2027-03-01 00:00:00], end: ~N[2027-03-04 00:00:00], pinned: pinned} =
               layout[both.uuid]

      assert pinned == {~D[2027-03-01], ~D[2027-03-03]}
      assert layout[due.uuid].pinned == {~D[2027-03-10], ~D[2027-03-10]}

      # only a start: its own length from that day, one day at least
      {from_day, to_day} = layout[from.uuid].pinned
      assert from_day == ~D[2027-04-01]
      assert Date.compare(to_day, from_day) != :lt
    end

    test "the calendar shows a dated task on its days in any viewer's timezone" do
      project = fixture_project()
      a = task(project, "Both", %{"start_date" => "2027-03-01", "end_date" => "2027-03-03"})

      {items, layout} = ScheduleLayout.tree(Projects.get_project!(project.uuid))
      pairs = Enum.map(items, &{&1, Map.fetch!(layout, &1.uuid)})

      for offset <- ["0", "+3", "-8", "+13"] do
        {[event], _meta} = CalendarDisplay.task_events(pairs, "en", offset)
        assert event.id == a.uuid
        assert event.start == ~D[2027-03-01]
        # exclusive end: the day after the last one
        assert event.end == ~D[2027-03-04]
      end
    end

    test "a sub-project's span covers a dated task inside it" do
      parent = fixture_project()

      {:ok, %{child_project: child}} =
        Projects.create_subproject(parent.uuid, %{"name" => "Inner"})

      _ = task(child, "Far away", %{"start_date" => "2031-01-05", "end_date" => "2031-01-06"})

      {items, layout} = ScheduleLayout.tree(Projects.get_project!(parent.uuid))
      row = Enum.find(items, &Assignment.subproject?(&1.assignment))

      assert NaiveDateTime.compare(layout[row.uuid].end, ~N[2031-01-07 00:00:00]) != :lt
      refute Map.has_key?(layout[row.uuid], :pinned)
    end
  end

  describe "the form and the row" do
    setup %{conn: conn} do
      {:ok, conn: put_test_scope(conn, fake_scope())}
    end

    test "the add-task form saves both dates; the row shows them", %{conn: conn} do
      project = fixture_project()
      a = task(project, "Dated")

      {:ok, view, html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/#{a.uuid}/edit")

      assert html =~ ~s(name="assignment[start_date]")
      assert html =~ ~s(name="assignment[end_date]")

      view
      |> form("#assignment-form",
        assignment: %{"start_date" => "2027-03-01", "end_date" => "2027-03-03"}
      )
      |> render_submit()

      saved = Projects.get_assignment(a.uuid)
      assert saved.start_date == ~D[2027-03-01]
      assert saved.end_date == ~D[2027-03-03]

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")
      assert html =~ "hero-calendar-days"
      refute html =~ "Past its end date"
    end

    test "an end before the start is refused in the form", %{conn: conn} do
      project = fixture_project()
      a = task(project, "Dated", %{"start_date" => "2027-03-05"})

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/#{a.uuid}/edit")

      html =
        view
        |> form("#assignment-form", assignment: %{"end_date" => "2027-03-01"})
        |> render_submit()

      assert html =~ "must not be before the start date"
      assert is_nil(Projects.get_assignment(a.uuid).end_date)
    end

    test "a task past its deadline reads as overdue on its row; a past planned day does not",
         %{conn: conn} do
      project = fixture_project()
      _ = task(project, "Late", %{"deadline" => "2020-01-01T10:00:00Z"})
      _ = task(project, "Planned", %{"end_date" => "2020-01-01"})

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")
      assert html =~ "Past its deadline"
      assert length(Regex.scan(~r/badge-error/, html)) == 1
    end
  end

  describe "over the API" do
    setup %{conn: conn} do
      project = fixture_project()

      {:ok, user} =
        Auth.register_user(%{
          email: "dates-#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      {:ok, _key, token} =
        ApiKeys.create(project, %{"name" => "Agent", "role" => "manager"}, actor_uuid: user.uuid)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")

      {:ok, conn: conn, project: project}
    end

    defp create(conn, body) do
      conn
      |> put_req_header("idempotency-key", Ecto.UUID.generate())
      |> post("#{@base}/tasks", Jason.encode!(body))
    end

    test "create with dates, read them back, change and clear them", %{conn: conn} do
      resp =
        create(conn, %{title: "Quote", start_date: "2027-03-01", end_date: "2027-03-03"})

      assert %{"task" => %{"uuid" => uuid} = t} = json_response(resp, 201)
      assert t["start_date"] == "2027-03-01"
      assert t["end_date"] == "2027-03-03"
      assert t["overdue"] == false

      resp = patch(conn, "#{@base}/tasks/#{uuid}", Jason.encode!(%{end_date: "2027-03-09"}))
      assert json_response(resp, 200)["task"]["end_date"] == "2027-03-09"

      resp =
        patch(conn, "#{@base}/tasks/#{uuid}", Jason.encode!(%{start_date: nil, end_date: ""}))

      assert %{"start_date" => nil, "end_date" => nil} = json_response(resp, 200)["task"]
    end

    test "a value that is not a day, or an end before the start, is a 422 and writes nothing",
         %{conn: conn, project: project} do
      assert %{"error" => %{"code" => "validation_failed"}} =
               conn |> create(%{title: "X", end_date: "next Thursday"}) |> json_response(422)

      assert %{"error" => %{"code" => "validation_failed"}} =
               conn
               |> create(%{title: "X", start_date: "2027-03-05", end_date: "2027-03-01"})
               |> json_response(422)

      assert Projects.list_assignments(project.uuid) == []

      a = task(project, "Dated", %{"start_date" => "2027-03-05"})

      resp =
        patch(
          conn,
          "#{@base}/tasks/#{a.uuid}",
          Jason.encode!(%{waiting_on: "the client", end_date: "2027-03-01"})
        )

      assert json_response(resp, 422)
      assert is_nil(Projects.get_assignment(a.uuid).waiting_on)
    end

    test "due_before lists what is owed by a day; overdue is counted in the briefing", %{
      conn: conn,
      project: project
    } do
      late =
        task(project, "Late", %{"end_date" => "2020-01-01", "deadline" => "2020-01-01T10:00:00Z"})

      _soon = task(project, "Soon", %{"end_date" => "2099-01-01"})
      _none = task(project, "No date")

      body = conn |> get("#{@base}/tasks?due_before=2020-06-01&status=open") |> json_response(200)
      assert [%{"uuid" => uuid, "overdue" => true}] = body["tasks"]
      assert uuid == late.uuid

      assert conn |> get("#{@base}/tasks?due_before=soon") |> json_response(422)

      brief = conn |> get("#{@base}/briefing") |> json_response(200)
      assert brief["counts"]["overdue"] == 1
      assert Enum.find(brief["tasks"], &(&1["uuid"] == late.uuid))["end_date"] == "2020-01-01"
    end
  end
end
