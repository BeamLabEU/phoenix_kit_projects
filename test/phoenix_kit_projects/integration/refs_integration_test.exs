defmodule PhoenixKitProjects.Integration.RefsIntegrationTest do
  @moduledoc """
  Keys and task numbers against the database (chain V22): how a project
  gets its key, what a rename leaves behind, how tasks are numbered, and
  the lookups by ref — in the context, on the pages and on the API.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, Paths, Projects, ResourceLinks}
  alias PhoenixKitProjects.Schemas.Assignment

  defp project!(name, extra \\ %{}) do
    {:ok, project} =
      Projects.create_project(
        Map.merge(%{"name" => name, "start_mode" => "immediate", "is_template" => "false"}, extra)
      )

    project
  end

  defp task!(project, title \\ nil) do
    task = fixture_task(if title, do: %{"title" => title}, else: %{})

    {:ok, a} =
      Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => task.uuid})

    Projects.get_assignment(a.uuid)
  end

  describe "a project's key" do
    test "comes from its name, and the next one with that name gets a number" do
      assert project!("Kitchen Ref").key == "KR"
      assert project!("Kitchen Ref").key == "KR2"
      assert project!("ANDI Manager").key == "ANDI"
      assert project!("3D editor").key == "3DE"
    end

    test "a template gets a placeholder and squats nothing" do
      template = fixture_template(%{"name" => "Zebra Yard"})
      assert template.key =~ ~r/^TPL\d+$/
      assert project!("Zebra Yard").key == "ZY"
    end

    test "a given key is kept upper-cased; a bad or taken one is refused" do
      assert project!("Anything", %{"key" => " shop "}).key == "SHOP"

      for bad <- ["A", "new", "12", "A-B", "ABCDEFGHIJKL"] do
        assert {:error, cs} =
                 Projects.create_project(%{
                   "name" => "Bad key",
                   "start_mode" => "immediate",
                   "key" => bad
                 })

        assert %{key: [_]} = errors_on(cs), bad
      end

      assert {:error, cs} =
               Projects.create_project(%{
                 "name" => "Other shop",
                 "start_mode" => "immediate",
                 "key" => "shop"
               })

      assert %{key: [message]} = errors_on(cs)
      assert message =~ "another project"
    end

    test "a rename keeps the old key resolving and never frees it" do
      project = project!("Rename Me")
      assert project.key == "RM"

      assert {:ok, renamed} = Projects.update_project(project, %{"key" => "moved"})
      assert renamed.key == "MOVED"
      assert Projects.get_project("moved").uuid == project.uuid
      assert Projects.get_project("RM").uuid == project.uuid
      assert Projects.former_keys(renamed) == ["RM"]

      # nobody else can take the old one, by hand or by suggestion
      other = project!("Rename Me")
      assert other.key == "RM2"
      assert {:error, cs} = Projects.update_project(other, %{"key" => "RM"})
      assert %{key: [_]} = errors_on(cs)

      # the project itself may go back to it
      assert {:ok, back} = Projects.update_project(renamed, %{"key" => "RM"})
      assert back.key == "RM"
      assert Projects.former_keys(back) == ["MOVED"]
    end

    test "an emptied key field does not rename a keyed project" do
      project = project!("Keep Key")
      assert {:ok, same} = Projects.update_project(project, %{"key" => "  ", "name" => "Kept"})
      assert same.key == "KK"
    end

    test "a deleted project's key is retired, not handed on" do
      project = project!("Gone Soon")
      assert project.key == "GS"
      assert {:ok, _} = Projects.delete_project(project)

      assert Projects.get_project("GS") == nil
      assert project!("Gone Soon").key == "GS2"
    end

    test "get_project answers nil for anything that is neither a uuid nor a key" do
      for junk <- ["", "no such key!", "ZZZZ", "42", nil, Ecto.UUID.generate()] do
        assert Projects.get_project(junk) == nil
      end
    end
  end

  describe "a task's number" do
    test "counts up per project and is never reused" do
      a = project!("Number One")
      b = project!("Number Two")

      assert [1, 2, 3] == for(_ <- 1..3, do: task!(a).number)
      assert task!(b).number == 1

      second = Projects.get_assignment("#{a.key}-2")
      assert second.number == 2
      assert {:ok, _} = Projects.delete_assignment(second)
      assert Projects.get_assignment("#{a.key}-2") == nil
      assert task!(a).number == 4
    end

    test "a ref resolves through the current key, a former key and any case" do
      project = project!("Ref Lookup")
      task = task!(project, "Hang the door")
      {:ok, _} = Projects.update_project(project, %{"key" => "DOOR"})

      for ref <- ["DOOR-1", "door-1", "RL-1", task.uuid] do
        assert Projects.get_assignment(ref).uuid == task.uuid, ref
      end

      assert Projects.get_assignment("DOOR-2") == nil
      assert Projects.get_assignment("NOPE-1") == nil
      assert Assignment.ref(Projects.get_assignment(task.uuid)) == "DOOR-1"
    end

    test "a sub-project has its own key; its row is called by the child's key" do
      parent = project!("Parent Tree")
      _first = task!(parent)

      {:ok, %{child_project: child, assignment: link}} =
        Projects.create_subproject(parent.uuid, %{"name" => "Leaf Work"})

      assert child.key == "LW"
      row = Projects.get_assignment(link.uuid)
      assert row.number == 2
      assert Assignment.ref(row) == "LW"
      assert Assignment.row_ref(row) == "PT-2"
      assert task!(child).number == 1

      # moved out, its refs are what they were
      {:ok, _} = Projects.move_project(child.uuid, :top)
      assert Assignment.ref(Projects.get_assignment("LW-1")) == "LW-1"
    end

    test "a project cloned from a template numbers its tasks from 1" do
      template = fixture_template()

      for _ <- 1..3 do
        task = fixture_task()

        {:ok, _} =
          Projects.create_assignment(%{"project_uuid" => template.uuid, "task_uuid" => task.uuid})
      end

      {:ok, project} =
        Projects.create_project_from_template(template.uuid, %{
          "name" => "Cloned Refs",
          "start_mode" => "immediate"
        })

      assert project.key == "CR"

      assert project.uuid |> Projects.list_assignments() |> Enum.map(& &1.number) |> Enum.sort() ==
               [1, 2, 3]
    end
  end

  describe "links and search" do
    test "a task link is spelled with the key and the ref" do
      project = project!("Link Spell")
      task = task!(project, "Paint")

      assert Paths.project(project) =~ "/admin/projects/LS"
      assert Paths.task(project, task) =~ "/admin/projects/LS/tasks?task=LS-1#task-#{task.uuid}"

      resolved = ResourceLinks.resolve_comment_resources([task.uuid, project.uuid])
      assert resolved[task.uuid].path == "/admin/projects/LS/tasks?task=LS-1#task-#{task.uuid}"
      assert resolved[task.uuid].full_title =~ "LS-1"
      assert resolved[project.uuid].path == "/admin/projects/LS"
    end

    test "the # search finds a task by its ref and a project by its key" do
      project = project!("Search Refs")
      task = task!(project, "Completely unrelated words")
      scope = fake_scope()

      results = ResourceLinks.search_resources("sr-1", scope: scope)
      assert Enum.any?(results, &(&1.uuid == task.uuid and &1.subtitle =~ "SR-1"))

      results = ResourceLinks.search_resources("sr", scope: scope)
      assert Enum.any?(results, &(&1.uuid == project.uuid))
    end
  end

  describe "pages" do
    setup %{conn: conn} do
      {:ok, user} =
        Auth.register_user(%{
          "email" => "refs-#{System.unique_integer([:positive])}@example.com",
          "password" => "ActorPass123!"
        })

      {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: user.uuid))}
    end

    test "the project opens by its key, shows it, and names its tasks", %{conn: conn} do
      project = project!("Page Refs")
      task = task!(project, "Shown task")

      {:ok, _view, html} = live(conn, "/en/admin/projects/PR")
      assert html =~ ~s(data-ref="PR")
      assert html =~ ~s(data-ref="PR-1")
      assert html =~ "Shown task"
      # the address the page mirrors into the bar is the friendly one
      assert html =~ ~s(data-url="/en/admin/projects/PR/tasks")
      refute html =~ ~s(data-url="/en/admin/projects/#{project.uuid})
      assert task.number == 1
    end

    test "?task=KEY-n rings and opens that task; another project's ref does not", %{conn: conn} do
      project = project!("Focus Refs")
      _one = task!(project)
      two = task!(project, "The second")
      other = project!("Other Focus")
      _ = task!(other)

      {:ok, view, _html} = live(conn, "/en/admin/projects/FR/tasks?task=fr-2")
      assert :sys.get_state(view.pid).socket.assigns.focus_task == two.uuid

      {:ok, view, _html} = live(conn, "/en/admin/projects/FR/tasks?task=OF-1")
      assert :sys.get_state(view.pid).socket.assigns[:focus_task] == nil
    end

    test "an unknown key lands on the list with the not-found flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/en/admin/projects/NOKEY")
      assert to =~ "/admin/projects"
    end

    test "the new-project form suggests a key and saves the one typed", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/projects/new")
      assert html =~ ~s(name="project[key]")

      html =
        view
        |> form("#project-form", %{"project" => %{"name" => "Form Keyed"}})
        |> render_change()

      assert html =~ "FK-1"

      view
      |> form("#project-form", %{"project" => %{"name" => "Form Keyed", "key" => "typed"}})
      |> render_submit()

      assert %{name: "Form Keyed"} = Projects.get_project("TYPED")
    end

    test "the edit form renames the key and says what it used to be", %{conn: conn} do
      project = project!("Edit Keyed")

      {:ok, view, _html} = live(conn, "/en/admin/projects/EK/edit")

      view
      |> form("#project-form", %{"project" => %{"key" => "newk"}})
      |> render_submit()

      assert Projects.get_project(project.uuid).key == "NEWK"

      {:ok, _view, html} = live(conn, "/en/admin/projects/NEWK/edit")
      assert html =~ "Also answers to: EK."
    end
  end

  describe "the API" do
    @base "/api/projects/v1"

    setup do
      project = project!("Api Refs")
      task = task!(project, "Wire it")
      {:ok, _key, token} = ApiKeys.create(project, %{"name" => "agent", "role" => "member"})
      {:ok, project: project, task: task, token: token}
    end

    defp api(conn, token) do
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
    end

    test "a task answers to its ref and says it", ctx do
      c = api(ctx.conn, ctx.token)

      %{"task" => task} = c |> get("#{@base}/tasks/AR-1") |> json_response(200)
      assert task["uuid"] == ctx.task.uuid
      assert task["ref"] == "AR-1"
      assert task["number"] == 1
      assert task["parent_ref"] == nil

      %{"tasks" => [listed]} = c |> get("#{@base}/tasks") |> json_response(200)
      assert listed["ref"] == "AR-1"

      assert c |> get("#{@base}/tasks/AR-99") |> json_response(404)
      assert c |> get("#{@base}/tasks/nonsense!") |> json_response(404)

      %{"project" => project} = c |> get("#{@base}/project") |> json_response(200)
      assert project["key"] == "AR"
    end

    test "another project's ref is the same 404 as no ref at all", ctx do
      foreign = project!("Foreign Refs")
      _ = task!(foreign)

      c = api(ctx.conn, ctx.token)
      assert c |> get("#{@base}/tasks/FR-1") |> json_response(404)
      assert c |> get("#{@base}/tasks?project=FR") |> json_response(404)
    end

    test "a sub-project is named by key in `project`, and its row carries both refs", ctx do
      {:ok, %{child_project: child}} =
        Projects.create_subproject(ctx.project.uuid, %{"name" => "Child Api"})

      _ = task!(child, "Inside")
      c = api(ctx.conn, ctx.token)

      %{"tasks" => tasks} = c |> get("#{@base}/tasks?project=ca") |> json_response(200)
      assert [%{"ref" => "CA-1"}] = tasks

      %{"tasks" => rows} = c |> get("#{@base}/tasks") |> json_response(200)
      row = Enum.find(rows, &(&1["kind"] == "subproject"))
      assert row["ref"] == "CA"
      assert row["parent_ref"] == "AR-2"

      %{"task" => inside} = c |> get("#{@base}/tasks/CA-1") |> json_response(200)
      assert inside["title"] == "Inside"
    end
  end
end
