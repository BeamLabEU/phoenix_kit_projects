defmodule PhoenixKitProjects.Web.TaskConversionLiveTest do
  @moduledoc """
  Item 9 on the project page: ⋮ "Make it a sub-project" / "Make it a
  task", one confirm naming what moves, the history line, and the
  permission (editing tasks and adding sub-projects).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Authz, Members, Outline, Projects}
  alias PhoenixKitProjects.Schemas.{Assignment, Dependency, Project}
  alias PhoenixKitProjects.Test.Repo

  import Ecto.Query

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "convert-#{System.unique_integer([:positive])}@example.com",
        "password" => "ConvertPass123!"
      })

    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(project)

    {:ok,
     conn: put_test_scope(conn, fake_scope(user_uuid: user.uuid)),
     project: Projects.get_project!(project.uuid),
     user: user}
  end

  defp task!(project, title, opts \\ []) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(project.uuid, %{"title" => title, "ad_hoc" => true}, %{
        "status" => "todo"
      })

    case Keyword.get(opts, :under) do
      nil -> Projects.get_assignment(a.uuid)
      parent -> elem(Outline.move(Projects.get_assignment(a.uuid), parent.uuid, :last), 1)
    end
  end

  test "a task made a sub-project and back from ⋮, connections kept, nothing deleted", ctx do
    first = task!(ctx.project, "Measure")
    fit = task!(ctx.project, "Fit the worktop")
    cut = task!(ctx.project, "Cut", under: fit)
    {:ok, _} = Projects.add_dependency(fit.uuid, first.uuid)

    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

    html =
      view
      |> element(~s(#assignment-menu-#{fit.uuid} [phx-value-event="make_subproject"]))
      |> render_click()

    assert html =~ "Make “Fit the worktop” a sub-project?"
    assert html =~ "Its subtask becomes the sub-project&#39;s task."

    html = render_click(view, "confirm_action_ok", %{})
    assert html =~ "is a sub-project now"

    link = Projects.get_assignment(fit.uuid)
    assert %Project{} = child = Repo.get(Project, link.child_project_uuid)
    assert Projects.get_assignment(cut.uuid).project_uuid == child.uuid

    assert Repo.exists?(
             from(d in Dependency,
               where: d.assignment_uuid == ^fit.uuid and d.depends_on_uuid == ^first.uuid
             )
           )

    assert Repo.exists?(
             from(e in PhoenixKit.Activity.Entry,
               where:
                 e.action == "projects.assignment_made_subproject" and
                   e.resource_uuid == ^fit.uuid
             )
           )

    # And back.
    html =
      view
      |> element(~s([phx-value-event="make_task"][phx-value-uuid="#{fit.uuid}"]))
      |> render_click()

    assert html =~ "Make “Fit the worktop” a task?"
    html = render_click(view, "confirm_action_ok", %{})
    assert html =~ "is a task now"

    row = Projects.get_assignment(fit.uuid)
    assert is_nil(row.child_project_uuid)
    assert Projects.get_assignment(cut.uuid).parent_uuid == fit.uuid
    assert Repo.get(Project, child.uuid).archived_at
    assert Repo.exists?(from(a in Assignment, where: a.uuid == ^cut.uuid))
  end

  test "a subtask offers no sub-project", ctx do
    fit = task!(ctx.project, "Fit")
    cut = task!(ctx.project, "Cut", under: fit)
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

    assert has_element?(
             view,
             ~s(#assignment-menu-#{fit.uuid} [phx-value-event="make_subproject"])
           )

    refute has_element?(
             view,
             ~s(#assignment-menu-#{cut.uuid} [phx-value-event="make_subproject"])
           )
  end

  for {floor, what} <- [{"edit_tasks", "edit tasks"}, {"create_tasks", "add sub-projects"}] do
    test "someone who may not #{what} cannot make one, even with a forged event", ctx do
      fit = task!(ctx.project, "Fit")

      {:ok, viewer} =
        Auth.register_user(%{
          "email" => "viewer-#{System.unique_integer([:positive])}@example.com",
          "password" => "ViewerPass123!"
        })

      {:ok, _} = Members.add_member(ctx.project, viewer.uuid, role: "viewer")
      {:ok, project} = Authz.set_overrides(ctx.project, %{unquote(floor) => "managers"})

      conn =
        put_test_scope(
          build_conn(),
          fake_scope(user_uuid: viewer.uuid, permissions: ["projects"])
        )

      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      render_click(view, "make_subproject", %{"uuid" => fit.uuid})
      assert is_nil(Projects.get_assignment(fit.uuid).child_project_uuid)
    end
  end

  # Back to a task archives the sub-project and moves its tasks into this
  # list: it takes the right to edit tasks in BOTH projects (Max,
  # 2026-10-31: "Go with B"), not the owner-level archive right.
  describe "a sub-project made a task again" do
    setup ctx do
      {:ok, %{child_project: child, assignment: link}} =
        Projects.create_subproject(ctx.project.uuid, %{"name" => "Doors"})

      {:ok, manager} =
        Auth.register_user(%{
          "email" => "manager-#{System.unique_integer([:positive])}@example.com",
          "password" => "ManagerPass123!"
        })

      {:ok, _} = Members.add_member(ctx.project, manager.uuid, role: "manager")

      scope = fake_scope(user_uuid: manager.uuid, permissions: ["projects"])
      conn = put_test_scope(build_conn(), scope)

      {:ok, child: child, link: link, manager: manager, manager_conn: conn, manager_scope: scope}
    end

    test "a parent manager who may edit tasks in the sub-project folds it (and archives it)",
         ctx do
      {:ok, _} = Members.add_member(ctx.child, ctx.manager.uuid, role: "member")
      # Not an owner there: the archive right alone would have refused it.
      refute Authz.can?(ctx.manager_scope, ctx.child, :archive_project)

      {:ok, view, _html} = live(ctx.manager_conn, "/en/admin/projects/#{ctx.project.uuid}")

      assert render_click(view, "make_task", %{"uuid" => ctx.link.uuid}) =~ "is a task now"
      assert is_nil(Projects.get_assignment(ctx.link.uuid).child_project_uuid)
      assert Repo.get(Project, ctx.child.uuid).archived_at
    end

    test "a parent manager with no role in the sub-project cannot, even with a forged event",
         ctx do
      {:ok, view, _html} = live(ctx.manager_conn, "/en/admin/projects/#{ctx.project.uuid}")

      assert render_click(view, "make_task", %{"uuid" => ctx.link.uuid}) =~
               "You do not have permission to do that."

      assert Projects.get_assignment(ctx.link.uuid).child_project_uuid == ctx.child.uuid
      assert is_nil(Repo.get(Project, ctx.child.uuid).archived_at)
    end

    test "edit rights in the sub-project alone are not enough", ctx do
      {:ok, outsider} =
        Auth.register_user(%{
          "email" => "outsider-#{System.unique_integer([:positive])}@example.com",
          "password" => "OutsiderPass123!"
        })

      {:ok, _} = Members.add_member(ctx.project, outsider.uuid, role: "viewer")
      # Here only managers edit tasks; a viewer may not.
      {:ok, _} = Authz.set_overrides(ctx.project, %{"edit_tasks" => "managers"})
      {:ok, _} = Members.add_member(ctx.child, outsider.uuid, role: "manager")

      conn =
        put_test_scope(
          build_conn(),
          fake_scope(user_uuid: outsider.uuid, permissions: ["projects"])
        )

      {:ok, view, _html} = live(conn, "/en/admin/projects/#{ctx.project.uuid}")
      render_click(view, "make_task", %{"uuid" => ctx.link.uuid})
      assert Projects.get_assignment(ctx.link.uuid).child_project_uuid == ctx.child.uuid
    end
  end
end
