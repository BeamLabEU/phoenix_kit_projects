defmodule PhoenixKitProjects.Web.AssignmentFormTabsTest do
  @moduledoc """
  The task form as rebuilt after the boss's pass (2026-10-29): a header
  that names the task as it is typed, the form in tabs, the status as a
  row of coloured choices, one picker for people, teams and departments,
  the deadline, and the real start and finish corrected afterwards. The
  "Waiting on" / "Requested by" fields and the History, Discussion and AI
  notes sections are gone from it (the task's view has the threads).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitStaff.Schemas.{Department, Person, Team}

  setup %{conn: conn} do
    me = embed_user_uuid!()
    conn = put_test_scope(conn, fake_scope(user_uuid: me))
    project = fixture_project(%{"start_mode" => "immediate"})

    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Measure the kitchen", "ad_hoc" => true},
        %{}
      )

    {:ok, conn: conn, me: me, project: project, a: a}
  end

  defp edit(conn, project, a),
    do: live(conn, "/en/admin/projects/#{project.uuid}/assignments/#{a.uuid}/edit")

  defp person!(name, user_uuid \\ nil) do
    user_uuid =
      user_uuid ||
        elem(
          Auth.register_user(%{
            "email" =>
              "#{String.downcase(name)}-#{System.unique_integer([:positive])}@example.com",
            "password" => "ValidPassword123!",
            "first_name" => name
          }),
          1
        ).uuid

    Repo.insert!(%Person{user_uuid: user_uuid, status: "active", name: name})
  end

  # The edit form saves on a timer; this runs it now.
  defp autosave(view) do
    send(view.pid, :autosave)
    render(view)
  end

  describe "header" do
    test "the title at the top follows the Title field as it is typed", ctx do
      {:ok, view, _} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/new")

      assert view |> element("#assignment-form-title") |> render() =~ "New task"

      view
      |> form("#assignment-form", assignment: %{status: "todo"}, task: %{title: "Order the oak"})
      |> render_change()

      assert view |> element("#assignment-form-title") |> render() =~ "Order the oak"
    end

    test "editing: the header names the task, follows a rename, and the rename is saved", ctx do
      {:ok, view, html} = edit(ctx.conn, ctx.project, ctx.a)
      assert html =~ "Editing"
      assert view |> element("#assignment-form-title") |> render() =~ "Measure the kitchen"

      view
      |> form("#assignment-form", task: %{title: "Measure the kitchen twice"})
      |> render_change()

      assert view |> element("#assignment-form-title") |> render() =~ "Measure the kitchen twice"

      autosave(view)
      assert Projects.get_task(ctx.a.task_uuid).title == "Measure the kitchen twice"
    end
  end

  describe "tabs" do
    test "the form is in tabs and every tab's fields stay in the one form", ctx do
      {:ok, view, html} = edit(ctx.conn, ctx.project, ctx.a)

      assert html =~ ~s(id="assignment-tab-task")
      assert html =~ ~s(id="assignment-tab-planning")
      # The planning fields are rendered (hidden), so a save posts them.
      assert has_element?(view, "#assignment-pane-planning.hidden")
      assert has_element?(view, "input[name='assignment[start_date]']")

      view |> element("#assignment-tab-planning") |> render_click()
      refute has_element?(view, "#assignment-pane-planning.hidden")
      assert has_element?(view, "#assignment-pane-task.hidden")
    end

    test "a failed save opens the tab holding the error and marks it", ctx do
      {:ok, view, _} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/new")

      view
      |> form("#assignment-form",
        assignment: %{status: "todo", start_date: "2026-11-10", end_date: "2026-11-01"},
        task: %{title: "Backwards"}
      )
      |> render_submit()

      refute has_element?(view, "#assignment-pane-planning.hidden")
      assert has_element?(view, "[data-pane-error='planning']")
    end
  end

  describe "status" do
    test "the status is a row of choices that posts with the form", ctx do
      {:ok, view, _} = edit(ctx.conn, ctx.project, ctx.a)

      assert has_element?(view, "input[type='radio'][name='assignment[status]'][value='waiting']")
      assert has_element?(view, "input[type='radio'][name='assignment[status]'][value='done']")
      refute has_element?(view, "select[name='assignment[status]']")

      view |> form("#assignment-form", assignment: %{status: "done"}) |> render_submit()

      assert Projects.get_assignment(ctx.a.uuid).status == "done"
    end
  end

  describe "assignee" do
    test "the picker finds teams, and picking one sets only the team", ctx do
      bob = person!("Bob")

      {:ok, a} =
        Projects.update_assignment_form(ctx.a, %{"assigned_person_uuid" => bob.uuid})

      dept = Repo.insert!(%Department{name: "Joinery #{System.unique_integer([:positive])}"})

      team =
        Repo.insert!(%Team{
          name: "Crew #{System.unique_integer([:positive])}",
          department_uuid: dept.uuid
        })

      {:ok, view, html} = edit(ctx.conn, ctx.project, a)
      refute html =~ ~s(name="assign_type" value="team")
      assert has_element?(view, "#assignment-assignee-chosen", "Bob")

      render_click(view, "assignee_search", %{"q" => "Crew"})
      assert_push_event(view, "assignee_results", %{results: rows})
      assert Enum.any?(rows, &(&1.kind == "team" and &1.uuid == team.uuid))

      render_click(view, "assignee_pick", %{
        "kind" => "team",
        "uuid" => team.uuid,
        "label" => team.name
      })

      assert has_element?(view, "#assignment-assignee-chosen", team.name)

      autosave(view)
      saved = Projects.get_assignment(a.uuid)
      assert saved.assigned_team_uuid == team.uuid
      assert saved.assigned_person_uuid == nil
      assert saved.assigned_department_uuid == nil
    end

    test "a forged pick of something that does not exist assigns nobody", ctx do
      {:ok, view, _} = edit(ctx.conn, ctx.project, ctx.a)

      render_click(view, "assignee_pick", %{"kind" => "team", "uuid" => Ecto.UUID.generate()})
      autosave(view)

      assert Projects.get_assignment(ctx.a.uuid).assigned_team_uuid == nil
    end

    test "Assign to me gives the task to the viewer's own staff person", ctx do
      me = person!("Me", ctx.me)

      {:ok, view, _} = edit(ctx.conn, ctx.project, ctx.a)
      view |> element("#assignment-assign-me") |> render_click()
      autosave(view)

      assert Projects.get_assignment(ctx.a.uuid).assigned_person_uuid == me.uuid
      # Theirs now: the button goes.
      refute has_element?(view, "#assignment-assign-me")
    end

    test "Recent offers whom this project's tasks went to, one click each", ctx do
      carl = person!("Carl")

      {:ok, %{assignment: _}} =
        Projects.create_task_with_assignment(
          ctx.project.uuid,
          %{"title" => "Cut the boards", "ad_hoc" => true},
          %{"assigned_person_uuid" => carl.uuid}
        )

      {:ok, view, _} = edit(ctx.conn, ctx.project, ctx.a)
      assert has_element?(view, "#assignment-assignee-recent", "Carl")

      view
      |> element("#assignment-assignee-recent button[phx-value-uuid='#{carl.uuid}']")
      |> render_click()

      autosave(view)
      assert Projects.get_assignment(ctx.a.uuid).assigned_person_uuid == carl.uuid
    end

    test "the old kind-first selects are gone", ctx do
      {:ok, _view, html} = edit(ctx.conn, ctx.project, ctx.a)
      refute html =~ ~s(<select name="assign_type")
      refute html =~ "Select department"
    end
  end

  describe "times" do
    test "the deadline is read in the viewer's zone", %{project: project, a: a} = ctx do
      conn =
        put_test_scope(
          ctx.conn,
          fake_scope(user_uuid: ctx.me, user_timezone: "Europe/Tallinn")
        )

      {:ok, view, _} = edit(conn, project, a)

      view
      |> form("#assignment-form", assignment: %{deadline: "2027-07-01T10:00"})
      |> render_submit()

      assert Projects.get_assignment(a.uuid).deadline == ~U[2027-07-01 07:00:00Z]
    end

    test "a finished time is corrected, and one in the future is refused", ctx do
      {:ok, done} = Projects.complete_assignment(ctx.a, ctx.me)
      assert %DateTime{} = done.completed_at

      {:ok, view, _} = edit(ctx.conn, ctx.project, done)
      assert has_element?(view, "input[name='times[completed_at]']")

      view
      |> form("#assignment-form", times: %{completed_at: "2026-10-01T15:30"})
      |> render_submit()

      assert Projects.get_assignment(ctx.a.uuid).completed_at == ~U[2026-10-01 15:30:00Z]

      html =
        view
        |> form("#assignment-form", times: %{completed_at: "2099-01-01T09:00"})
        |> render_submit()

      assert html =~ "cannot be in the future"
      assert Projects.get_assignment(ctx.a.uuid).completed_at == ~U[2026-10-01 15:30:00Z]
      # The error is on the More tab, which is opened.
      refute has_element?(view, "#assignment-pane-more.hidden")
    end
  end

  describe "what left the form" do
    test "no Waiting on or Requested by, and no History, Discussion or AI notes", ctx do
      {:ok, _view, html} = edit(ctx.conn, ctx.project, ctx.a)

      refute html =~ ~s(name="assignment[waiting_on]")
      refute html =~ ~s(name="assignment[origin]")
      refute html =~ "Requested by"
      refute html =~ ~s(id="assignment-threads")
      refute html =~ "assignment-history-"
      refute html =~ ~s(id="assignment-discussion")
      refute html =~ ~s(id="assignment-ai-notes")
    end
  end

  describe "a refused rename" do
    test "autosave: the bar says Not saved, the typed title stays, the Task tab is marked",
         ctx do
      {:ok, view, _} = edit(ctx.conn, ctx.project, ctx.a)
      long = String.duplicate("x", 501)

      view |> form("#assignment-form", task: %{title: long}) |> render_change()
      autosave(view)

      assert Projects.get_task(ctx.a.task_uuid).title == "Measure the kitchen"
      assert view |> element("#assignment-save-state") |> render() =~ "Not saved"
      refute view |> element("#assignment-save-state") |> render() =~ "Saved<"
      assert has_element?(view, "input[name='task[title]'][value='#{long}']")
      assert has_element?(view, "[data-pane-error='task']")
    end

    test "submit: the form stays open on the error", ctx do
      {:ok, view, _} = edit(ctx.conn, ctx.project, ctx.a)
      long = String.duplicate("y", 501)

      html = view |> form("#assignment-form", task: %{title: long}) |> render_submit()

      assert is_binary(html)
      assert Projects.get_task(ctx.a.task_uuid).title == "Measure the kitchen"
      assert has_element?(view, "input[name='task[title]'][value='#{long}']")
      assert has_element?(view, "[data-pane-error='task']")
    end
  end

  describe "the right to assign" do
    test "is asked again at save: a manager made a member since the form opened", ctx do
      {:ok, _} =
        PhoenixKitProjects.Authz.set_overrides(ctx.project, %{"assign_tasks" => "managers"})

      bob = person!("Bob")
      user = embed_user_uuid!()
      {:ok, _} = PhoenixKitProjects.Members.add_member(ctx.project, user, role: "manager")
      conn = put_test_scope(ctx.conn, fake_scope(user_uuid: user, permissions: ["projects"]))

      {:ok, view, _} = edit(conn, ctx.project, ctx.a)
      {:ok, _} = PhoenixKitProjects.Members.change_role(ctx.project, user, "member")

      render_click(view, "assignee_pick", %{"kind" => "person", "uuid" => bob.uuid})
      autosave(view)

      assert Projects.get_assignment(ctx.a.uuid).assigned_person_uuid == nil
    end
  end
end
