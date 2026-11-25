defmodule PhoenixKitProjects.Web.ReviewSweep1124Test do
  @moduledoc """
  The review sweep of 2026-11-24 (codex, zai, vibe, grok; Max's manual
  test): what a member may see on the project page, a forged event that
  crashed it, the controls and the list sharing one centred column, and
  the deletes that left rows, files and positions behind.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Authz, Members, Outline, Portal, Projects}
  alias PhoenixKitProjects.Schemas.{Assignment, PortalSubmission, Task}
  alias PhoenixKitProjects.Test.Repo

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "sweep-#{System.unique_integer([:positive])}@example.com",
        "password" => "SweepPass123!"
      })

    user
  end

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: user!().uuid))}
  end

  defp member_conn(conn, user),
    do:
      put_test_scope(conn, fake_scope(user_uuid: user.uuid, roles: [], permissions: ["projects"]))

  defp task_in(project, title, attrs \\ %{}) do
    {:ok, task} = Projects.create_task(Map.merge(%{"title" => title}, attrs))

    {:ok, assignment} =
      Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => task.uuid})

    assignment
  end

  defp path(project), do: "/en/admin/projects/#{project.uuid}"

  describe "what a member sees" do
    test "public submissions are shown only to those who may decide on them", %{conn: conn} do
      viewer = user!()
      # Open floors let a viewer decide; a project that keeps editing to
      # its managers keeps the queue to them too.
      {:ok, project} = Authz.set_overrides(fixture_project(), %{"edit_tasks" => "managers"})
      {:ok, _} = Members.add_member(project, viewer.uuid, role: "viewer")

      {:ok, _} =
        project
        |> task_in("Please fix the door")
        |> Ecto.Changeset.change(review_status: "pending", source: "portal")
        |> Repo.update()

      {:ok, as_viewer, _} = live(member_conn(conn, viewer), path(project))
      assert :sys.get_state(as_viewer.pid).socket.assigns.pending_reviews == []

      {:ok, as_admin, _} = live(conn, path(project))
      assert [_] = :sys.get_state(as_admin.pid).socket.assigns.pending_reviews
    end
  end

  test "a numeric progress value from a crafted event does not crash the page", %{conn: conn} do
    project = fixture_project()
    a = task_in(project, "Progress #{System.unique_integer([:positive])}")
    {:ok, view, _html} = live(conn, path(project))

    render_hook(view, "update_progress", %{"uuid" => a.uuid, "progress_pct" => 25})
    assert Process.alive?(view.pid)
    render_hook(view, "update_progress", %{"uuid" => a.uuid, "progress_pct" => %{"x" => 1}})
    assert Process.alive?(view.pid)
  end

  test "the controls above the list sit in the list's centred column", %{conn: conn} do
    project = fixture_project()
    {:ok, _view, html} = live(conn, path(project))

    [chrome] = Regex.run(~r/<div[^>]*id="project-task-chrome-#{project.uuid}"[^>]*>/, html)
    assert chrome =~ "mx-auto"
    assert chrome =~ "max-w-6xl"
    assert html =~ ~s(id="project-task-chrome-col-#{project.uuid}")
  end

  describe "deletes" do
    test "a task with many subtasks goes in one write, with its one-off tasks" do
      project = fixture_project()
      top = task_in(project, "Top", %{"ad_hoc" => true})

      subs =
        for i <- 1..12 do
          sub = task_in(project, "Sub #{i}", %{"ad_hoc" => true})
          {:ok, _} = Outline.move(sub, top.uuid)
          sub
        end

      assert {:ok, _} = Projects.delete_assignment(Repo.get!(Assignment, top.uuid))

      for a <- [top | subs] do
        refute Repo.get(Assignment, a.uuid)
        refute Repo.get(Task, a.task_uuid)
      end
    end

    test "deleting one task removes its one-off task and keeps a library task" do
      project = fixture_project()
      one_off = task_in(project, "Once", %{"ad_hoc" => true})
      library = task_in(project, "Shared")

      {:ok, _} = Projects.delete_assignment(one_off)
      {:ok, _} = Projects.delete_assignment(library)

      refute Repo.get(Task, one_off.task_uuid)
      assert Repo.get(Task, library.task_uuid)
    end

    test "a project's submission files are found before the project goes" do
      project = fixture_project()
      a = task_in(project, "From the portal")
      file = Ecto.UUID.generate()

      %PortalSubmission{}
      |> PortalSubmission.changeset(%{assignment_uuid: a.uuid, file_uuids: [file]})
      |> Repo.insert!()

      assert Portal.attachment_files_for_projects([project.uuid]) == [file]
      assert Portal.attachment_files_for_assignments([a.uuid]) == [file]
      assert {:ok, _} = Projects.delete_project(project)
      assert Portal.attachment_files_for_projects([project.uuid]) == []
    end
  end

  test "the typed list's order is written in one statement and holds" do
    project = fixture_project()
    rows = for i <- 1..5, do: task_in(project, "Line #{i}")
    order = rows |> Enum.reverse() |> Enum.map(&{&1.uuid, nil})

    {:ok, :ok} =
      Outline.with_project_lock(project.uuid, fn _ -> Outline.write_order(project.uuid, order) end)

    positions =
      for a <- rows, into: %{}, do: {a.uuid, Repo.get!(Assignment, a.uuid).position}

    assert Enum.map(Enum.reverse(rows), &positions[&1.uuid]) == [1, 2, 3, 4, 5]
  end
end
