defmodule PhoenixKitProjects.TaskAssigneeApiTest do
  @moduledoc """
  Who a task is for, over the API: `assignee` on create and PATCH (`me`, a
  person, a team, a department, null), on every row and in the briefing,
  the `assignee` filter and `GET /people`. And the page a link to a task
  opens: the row ringed, the lens widened, the task in the drawer.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, Members, Projects, ResourceLinks}
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitStaff.{Departments, Staff, Teams}

  @base "/api/projects/v1"

  defp uniq, do: System.unique_integer([:positive])

  defp person(name) do
    {:ok, user} =
      Auth.register_user(%{
        email: "assignee-#{uniq()}@example.com",
        password: "ValidPassword123!"
      })

    # A personal key works only while its person holds Projects.
    user = PhoenixKitProjects.Test.Access.grant_projects!(user)

    {:ok, dept} = Departments.create(%{"name" => "Dept-#{uniq()}"})

    {:ok, person} =
      Staff.create_person(%{
        "user_uuid" => user.uuid,
        "name" => name,
        "employment_type" => "full_time",
        "primary_department_uuid" => dept.uuid
      })

    %{user: user, person: person, dept: dept}
  end

  defp authed(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  defp create(conn, body) do
    conn
    |> put_req_header("idempotency-key", Ecto.UUID.generate())
    |> post("#{@base}/tasks", Jason.encode!(body))
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

  describe "a personal key" do
    setup %{conn: conn} do
      project = fixture_project()
      me = person("Max Me")
      colleague = person("Cora Colleague")
      {:ok, _} = Members.add_member(project, me.user.uuid, role: "owner")

      {:ok, _key, token} =
        ApiKeys.create(project, %{"name" => "Max's AI", "user_uuid" => me.user.uuid},
          actor_uuid: me.user.uuid
        )

      {:ok, conn: authed(conn, token), project: project, me: me, colleague: colleague}
    end

    test "/me names the staff person `me` resolves to", %{conn: conn, me: me} do
      body = conn |> get("#{@base}/me") |> json_response(200)
      assert body["acting_for"]["person_uuid"] == me.person.uuid
      assert "assign_tasks" in body["allowed_actions"]
    end

    test "create assigned to me, hand it to a colleague, clear it", %{
      conn: conn,
      me: me,
      colleague: colleague
    } do
      resp = create(conn, %{title: "Mine", assignee: "me"})
      assert %{"task" => %{"uuid" => uuid, "assignee" => assignee}} = json_response(resp, 201)
      assert assignee == %{"kind" => "person", "uuid" => me.person.uuid, "name" => "Max Me"}

      resp =
        patch(conn, "#{@base}/tasks/#{uuid}", Jason.encode!(%{assignee: colleague.person.uuid}))

      assert json_response(resp, 200)["task"]["assignee"]["name"] == "Cora Colleague"

      resp = patch(conn, "#{@base}/tasks/#{uuid}", Jason.encode!(%{assignee: nil}))
      assert json_response(resp, 200)["task"]["assignee"] == nil

      # a PATCH that does not mention it leaves it alone
      _ = patch(conn, "#{@base}/tasks/#{uuid}", Jason.encode!(%{assignee: "me"}))
      resp = patch(conn, "#{@base}/tasks/#{uuid}", Jason.encode!(%{waiting_on: "the client"}))
      assert json_response(resp, 200)["task"]["assignee"]["uuid"] == me.person.uuid
    end

    test "a team or a department, one at a time", %{conn: conn, me: me} do
      {:ok, team} = Teams.create(%{"name" => "Team-#{uniq()}", "department_uuid" => me.dept.uuid})

      resp = create(conn, %{title: "For the team", assignee: %{team: team.uuid}})
      assert %{"uuid" => uuid, "assignee" => a} = json_response(resp, 201)["task"]
      assert a["kind"] == "team" and a["uuid"] == team.uuid

      resp =
        patch(
          conn,
          "#{@base}/tasks/#{uuid}",
          Jason.encode!(%{assignee: %{department: me.dept.uuid}})
        )

      assert json_response(resp, 200)["task"]["assignee"]["kind"] == "department"

      row = Projects.get_assignment(uuid)
      assert is_nil(row.assigned_team_uuid) and is_nil(row.assigned_person_uuid)
    end

    test "nobody by that uuid, or a shape nobody asked for, is a 422 and writes nothing", %{
      conn: conn,
      project: project
    } do
      for bad <- [Ecto.UUID.generate(), "Cora", 7, %{crew: Ecto.UUID.generate()}] do
        assert %{"error" => %{"code" => "validation_failed"}} =
                 conn |> create(%{title: "X", assignee: bad}) |> json_response(422)
      end

      assert Projects.list_assignments(project.uuid) == []
    end

    test "with the assignees feature off the field is refused, and a task without it still saves",
         %{conn: conn, project: project} do
      {:ok, _} =
        Projects.update_project(project, %{"settings" => %{"features" => %{"assignees" => false}}})

      assert %{"error" => %{"code" => "feature_disabled"}} =
               conn |> create(%{title: "X", assignee: "me"}) |> json_response(403)

      assert conn |> create(%{title: "Plain"}) |> json_response(201)
    end

    test "the filter and the briefing know whose a task is", %{
      conn: conn,
      project: project,
      me: me,
      colleague: colleague
    } do
      mine = task(project, "Mine", %{"assigned_person_uuid" => me.person.uuid})
      theirs = task(project, "Theirs", %{"assigned_person_uuid" => colleague.person.uuid})
      loose = task(project, "Nobody's")

      uuids = fn query ->
        conn
        |> get("#{@base}/tasks?assignee=#{query}")
        |> json_response(200)
        |> Map.fetch!("tasks")
        |> Enum.map(& &1["uuid"])
      end

      assert uuids.("me") == [mine.uuid]
      assert uuids.("none") == [loose.uuid]
      assert uuids.(colleague.person.uuid) == [theirs.uuid]
      assert conn |> get("#{@base}/tasks?assignee=cora") |> json_response(422)

      brief = conn |> get("#{@base}/briefing") |> json_response(200)
      assert brief["counts"]["assigned_to_me"] == 1
      row = Enum.find(brief["tasks"], &(&1["uuid"] == mine.uuid))
      assert row["assigned_to_me"] and row["assignee"]["name"] == "Max Me"
      refute Enum.find(brief["tasks"], &(&1["uuid"] == theirs.uuid))["assigned_to_me"]
    end

    test "GET /people lists who a task can be for, by name, without emails", %{
      conn: conn,
      me: me,
      colleague: colleague
    } do
      body = conn |> get("#{@base}/people") |> json_response(200)
      assert %{"me" => true} = Enum.find(body["people"], &(&1["uuid"] == me.person.uuid))
      assert Enum.any?(body["departments"], &(&1["uuid"] == me.dept.uuid))
      refute inspect(body) =~ "@example.com"

      body = conn |> get("#{@base}/people?q=cora") |> json_response(200)
      assert [%{"uuid" => uuid, "name" => "Cora Colleague", "me" => false}] = body["people"]
      assert uuid == colleague.person.uuid
    end
  end

  describe "a shared agent" do
    test "`me` names no one; a person's uuid still works", %{conn: conn} do
      project = fixture_project()
      someone = person("Sam Someone")

      {:ok, user} =
        Auth.register_user(%{email: "admin-#{uniq()}@example.com", password: "ValidPassword123!"})

      {:ok, _key, token} =
        ApiKeys.create(project, %{"name" => "Agent", "role" => "manager"}, actor_uuid: user.uuid)

      conn = authed(conn, token)

      assert %{"error" => %{"code" => "validation_failed"}} =
               conn |> create(%{title: "X", assignee: "me"}) |> json_response(422)

      resp = create(conn, %{title: "For Sam", assignee: someone.person.uuid})
      assert json_response(resp, 201)["task"]["assignee"]["name"] == "Sam Someone"

      assert conn |> get("#{@base}/tasks?assignee=me") |> json_response(200) |> Map.get("tasks") ==
               []
    end
  end

  # the host opens the frame from its own mailbox, a moment after mount
  defp opened?(host, tries \\ 50) do
    cond do
      render(host) =~ "<dialog" -> true
      tries == 0 -> false
      true -> Process.sleep(20) && opened?(host, tries - 1)
    end
  end

  describe "a link to a task" do
    test "names the task on the project's Tasks tab", %{conn: _conn} do
      project = fixture_project()
      a = task(project, "Linked")

      assert %{path: path} = ResourceLinks.resolve_comment_resources([a.uuid])[a.uuid]
      # spelled with the project's key and the task's ref (chain V22); the
      # fragment is the row's DOM id, always the uuid
      assert path == "/admin/projects/#{project.key}/tasks?task=#{project.key}-1#task-#{a.uuid}"
    end

    test "the page rings the row, shows it through the lens and opens it", %{conn: conn} do
      # a real user: the drawer's form rebuilds identity from the uuid
      conn = put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!()))
      project = fixture_project()
      done = task(project, "Finished one")
      {:ok, _} = Projects.update_assignment_status(done, %{"status" => "done"})
      for n <- 1..12, do: task(project, "Open #{n}")

      {:ok, view, html} =
        live(conn, "/en/admin/projects/#{project.uuid}?task=#{done.uuid}")

      assert html =~ ~s(id="task-#{done.uuid}")
      assert html =~ "ring-2 ring-primary"

      # the drawer host opens the task's form once it is up
      host = find_live_child(view, "project-popup-#{project.uuid}")
      assert opened?(host)

      # a uuid that is not a row here changes nothing
      {:ok, _view, html} =
        live(conn, "/en/admin/projects/#{project.uuid}?task=#{Ecto.UUID.generate()}")

      refute html =~ "ring-2 ring-primary"
    end
  end

  describe "an ongoing project's page" do
    test "has no start bar: no Ongoing tag, no setup line, nothing to start", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      project = fixture_project()

      {:ok, project} =
        Projects.update_project(project, %{"settings" => %{"completion" => "manual"}})

      _ = task(project, "One")

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")
      refute html =~ "Ongoing"
      refute html =~ "Start project"
      refute html =~ "set up tasks, then start"

      # Under way without being started: among the active, not in setup.
      assert Project.derived_status(project) == :ongoing
      assert Enum.any?(Projects.list_active_projects(), &(&1.uuid == project.uuid))
      refute Enum.any?(Projects.list_setup_projects(), &(&1.uuid == project.uuid))

      {:ok, _view, html} = live(conn, "/en/admin/projects?state=ongoing")
      assert html =~ project.name

      # Its key is in the header of its sub-pages too, not only its own page.
      for sub <- ~w(edit members files activity modules) do
        {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/#{sub}")
        assert html =~ "data-page-toolbar", sub
        assert html =~ project.key, sub
      end

      # Nobody presses Start on it, so becoming ongoing started it (and
      # froze its statuses); one made ongoing is started as it is made.
      assert %DateTime{} = project.started_at
      ongoing = %{"completion" => "manual"}

      made = fixture_project(%{"settings" => ongoing})
      assert %DateTime{} = Projects.get_project(made.uuid).started_at

      {:ok, %{child_project: child}} =
        Projects.create_subproject(made.uuid, %{
          "name" => "Upkeep #{System.unique_integer([:positive])}"
        })

      assert %DateTime{} = child.started_at

      # Not one that waits for a scheduled start, and not a template.
      later = DateTime.add(DateTime.utc_now(), 86_400, :second)

      waiting =
        fixture_project(%{
          "settings" => ongoing,
          "start_mode" => "scheduled",
          "scheduled_start_date" => later
        })

      assert waiting.started_at == nil
      assert Project.derived_status(waiting) == :scheduled
      assert fixture_project(%{"settings" => ongoing, "is_template" => true}).started_at == nil

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{fixture_project().uuid}")
      assert html =~ "set up tasks, then start"
    end
  end
end
