defmodule PhoenixKitProjects.Web.FormOwnedFieldsTest do
  @moduledoc """
  The task form and the sub-project short editor write what they draw, and
  nothing else a crafted submit adds. `Assignment.changeset/2` and
  `Project.changeset/2` cast more for the context's own callers: the row's
  project, a sub-project link, progress, a status (the page's
  `:update_status` step), and on a project archiving, the template flag
  and the key — owner-level things the parent's `:edit_tasks` never
  reaches.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Authz, Members, Projects}
  alias PhoenixKitStaff.{Departments, Staff}

  setup %{conn: conn} do
    project = fixture_project(%{"start_mode" => "immediate"})
    other = fixture_project(%{"start_mode" => "immediate"})

    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Fit the hinges", "ad_hoc" => true},
        %{"status" => "todo"}
      )

    {:ok, user} =
      Auth.register_user(%{
        "email" => "viewer-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    {:ok, _} = Members.add_member(project, user.uuid, role: "viewer")
    viewer = fake_scope(user_uuid: user.uuid, permissions: ["projects"])

    {:ok, conn: conn, project: project, other: other, a: a, viewer: viewer}
  end

  defp edit_path(project, a), do: "/en/admin/projects/#{project.uuid}/assignments/#{a.uuid}/edit"

  test "a crafted save cannot move the task, link a project or set its progress", ctx do
    {:ok, view, _} =
      ctx.conn
      |> put_test_scope(fake_scope(user_uuid: embed_user_uuid!()))
      |> live(edit_path(ctx.project, ctx.a))

    render_submit(view, "save", %{
      "assignment" => %{
        "project_uuid" => ctx.other.uuid,
        "child_project_uuid" => ctx.other.uuid,
        "task_uuid" => "",
        "progress_pct" => "77"
      }
    })

    a = Projects.get_assignment(ctx.a.uuid)
    assert a.project_uuid == ctx.project.uuid
    assert a.task_uuid == ctx.a.task_uuid
    assert is_nil(a.child_project_uuid)
    assert a.progress_pct == ctx.a.progress_pct
  end

  test "a new task's library task is the picker's tick, never a posted uuid", ctx do
    {:ok, %{assignment: foreign}} =
      Projects.create_task_with_assignment(
        ctx.other.uuid,
        %{"title" => "Private one-off", "ad_hoc" => true},
        %{}
      )

    {:ok, view, _} =
      ctx.conn
      |> put_test_scope(fake_scope(user_uuid: embed_user_uuid!()))
      |> live("/en/admin/projects/#{ctx.project.uuid}/assignments/new")

    render_submit(view, "save", %{
      "task_mode" => "existing",
      "assignment" => %{"task_uuid" => foreign.task_uuid}
    })

    refute Enum.any?(
             Projects.list_assignments(ctx.project.uuid),
             &(&1.task_uuid == foreign.task_uuid)
           )
  end

  test "the form's status is the page's status step: :update_status", ctx do
    {:ok, project} = Authz.set_overrides(ctx.project, %{"update_status" => "managers"})

    {:ok, view, html} =
      ctx.conn |> put_test_scope(ctx.viewer) |> live(edit_path(project, ctx.a))

    refute html =~ ~s(id="assignment-status")

    render_submit(view, "save", %{"assignment" => %{"status" => "done"}})

    assert Projects.get_assignment(ctx.a.uuid).status == "todo",
           "a viewer the floor keeps from moving status finished the task through the form"
  end

  describe "the sub-project short editor" do
    setup ctx do
      {:ok, %{child_project: child, assignment: link}} =
        Projects.create_subproject(ctx.project.uuid, %{"name" => "Buildout"})

      {:ok, child: Projects.get_project(child.uuid), link: link}
    end

    test "writes the words, never archiving, the template flag or the key", ctx do
      {:ok, view, _} =
        ctx.conn |> put_test_scope(ctx.viewer) |> live(edit_path(ctx.project, ctx.link))

      render_submit(view, "save_subproject", %{
        "subproject" => %{
          "name" => "Buildout two",
          "archived_at" => "2026-01-01T00:00:00Z",
          "is_template" => "true",
          "key" => "HACKD",
          "preset" => "full"
        }
      })

      child = Projects.get_project(ctx.child.uuid)
      assert child.name == "Buildout two"
      assert is_nil(child.archived_at)
      refute child.is_template
      assert child.key == ctx.child.key
    end

    test "sets no assignee for someone the floor keeps from assigning", ctx do
      {:ok, _} = Authz.set_overrides(ctx.project, %{"assign_tasks" => "managers"})
      {:ok, dept} = Departments.create(%{"name" => "Dept-#{System.unique_integer([:positive])}"})

      {:ok, user} =
        Auth.register_user(%{
          "email" => "fitter-#{System.unique_integer([:positive])}@example.com",
          "password" => "ActorPass123!"
        })

      {:ok, person} =
        Staff.create_person(%{
          "user_uuid" => user.uuid,
          "name" => "Ann Fitter",
          "employment_type" => "full_time",
          "primary_department_uuid" => dept.uuid
        })

      {:ok, view, _} =
        ctx.conn |> put_test_scope(ctx.viewer) |> live(edit_path(ctx.project, ctx.link))

      render_submit(view, "save_subproject", %{
        "assign_type" => "person",
        "subproject" => %{"name" => "Buildout", "assigned_person_uuid" => person.uuid}
      })

      assert is_nil(Projects.get_project(ctx.child.uuid).assigned_person_uuid)
    end
  end
end
