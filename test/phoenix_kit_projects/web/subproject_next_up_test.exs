defmodule PhoenixKitProjects.Web.SubprojectNextUpTest do
  @moduledoc """
  Item 26 (Max, 2026-10-31: "go with b"): a sub-project that finishes by
  itself releases nothing on its own. The person whose Done finished it
  gets the usual "next up" dialog for the rows it unlocks, on the page
  that handled that Done; nothing is written before the confirm.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "sub-next-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(project)
    project = Projects.get_project!(project.uuid)

    {:ok, %{child_project: child, assignment: link}} =
      Projects.create_subproject(project.uuid, %{"name" => "Kitchen"})

    fit = assignment!(project, "Fit the worktop")
    {:ok, _} = Projects.add_dependency(fit.uuid, link.uuid)
    cut = assignment!(child, "Cut the boards", "todo")

    {:ok,
     conn: put_test_scope(conn, fake_scope(user_uuid: user.uuid)),
     project: project,
     child: child,
     link: link,
     fit: fit,
     cut: cut}
  end

  defp assignment!(project, title, status \\ nil) do
    task = fixture_task(%{"title" => title})

    attrs =
      %{"project_uuid" => project.uuid, "task_uuid" => task.uuid}
      |> then(&if(status, do: Map.put(&1, "status", status), else: &1))

    {:ok, a} = Projects.create_assignment(attrs)
    a
  end

  defp status(a), do: Projects.get_assignment(a.uuid).status
  defp dialog(project), do: "#project-next-up-#{project.uuid}"

  test "the sub-project's last Done, on its own page, asks about what it unlocks", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.child.uuid}")

    render_click(view, "complete", %{"uuid" => ctx.cut.uuid})

    assert status(ctx.cut) == "done"
    assert status(ctx.link) == "done"
    # Asked, not released.
    assert status(ctx.fit) == "waiting"
    assert has_element?(view, dialog(ctx.child), "Kitchen")
    assert has_element?(view, dialog(ctx.child), "Fit the worktop")

    render_submit(view, "next_up_confirm", %{"uuid" => ctx.link.uuid})
    refute has_element?(view, dialog(ctx.child))
    assert status(ctx.fit) == "todo"
    assert_activity_logged("projects.assignment_made_ready", resource_uuid: ctx.fit.uuid)
  end

  test "Cancel leaves what it unlocks waiting", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.child.uuid}")

    render_click(view, "complete", %{"uuid" => ctx.cut.uuid})
    assert has_element?(view, dialog(ctx.child))

    render_click(view, "next_up_close", %{})
    refute has_element?(view, dialog(ctx.child))
    assert status(ctx.link) == "done"
    assert status(ctx.fit) == "waiting"
  end

  test "Keep idle on an offered row keeps it out of the release", ctx do
    other = assignment!(ctx.project, "Order the handles")
    {:ok, _} = Projects.add_dependency(other.uuid, ctx.link.uuid)

    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.child.uuid}")
    render_click(view, "complete", %{"uuid" => ctx.cut.uuid})
    render_click(view, "next_up_toggle_idle", %{"uuid" => other.uuid})
    render_submit(view, "next_up_confirm", %{"uuid" => ctx.link.uuid})

    assert status(ctx.fit) == "todo"
    assert status(other) == "waiting"
  end

  test "a Done that finishes nothing opens no dialog", ctx do
    second = assignment!(ctx.child, "Sand the edges", "todo")
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.child.uuid}")

    render_click(view, "complete", %{"uuid" => ctx.cut.uuid})
    refute has_element?(view, dialog(ctx.child))
    assert status(second) == "todo"
    assert status(ctx.fit) == "waiting"
  end

  test "the same Done through the API releases nothing", ctx do
    {:ok, _} =
      Projects.update_assignment_status(Projects.get_assignment(ctx.cut.uuid), %{status: "done"})

    Projects.recompute_project_completion(ctx.child.uuid)

    assert status(ctx.link) == "done"
    assert status(ctx.fit) == "waiting"
  end
end
