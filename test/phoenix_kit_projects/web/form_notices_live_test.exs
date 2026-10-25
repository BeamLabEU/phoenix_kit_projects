defmodule PhoenixKitProjects.Web.FormNoticesLiveTest do
  @moduledoc """
  What the task form tells, driven through the form: handing a task to
  someone else tells the new owner and the old one (and not "changed your
  task" on top), and a status changed in the form is one notice, not two.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitProjects.Web.AssignmentFormLive
  alias PhoenixKitStaff.Schemas.Person

  setup %{conn: conn} do
    me = embed_user_uuid!()
    conn = put_test_scope(conn, fake_scope(user_uuid: me))
    project = fixture_project(%{"start_mode" => "immediate"})
    bob = person!("Bob")
    carl = person!("Carl")

    for p <- [bob, carl],
        do: {:ok, _} = PhoenixKitProjects.Members.add_member(project, p.user, role: "member")

    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "3D model", "ad_hoc" => true},
        %{"assigned_person_uuid" => bob.person}
      )

    {:ok, conn: conn, me: me, project: project, a: a, bob: bob, carl: carl}
  end

  defp person!(name) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{String.downcase(name)}-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!",
        "first_name" => name
      })

    {:ok, person} = Repo.insert(%Person{user_uuid: user.uuid, status: "active", name: name})
    %{user: user.uuid, person: person.uuid}
  end

  defp notices(target) do
    Repo.all(
      from(e in Entry,
        where: e.target_uuid == ^target and like(e.action, "projects.assignment_%"),
        select: e.action
      )
    )
  end

  defp edit_form(ctx) do
    {:ok, view, _html} =
      live_isolated(ctx.conn, AssignmentFormLive,
        session: %{
          "id" => ctx.a.uuid,
          "project_id" => ctx.project.uuid,
          "live_action" => "edit",
          "current_user_uuid" => ctx.me
        }
      )

    view
  end

  test "handing the task to Carl tells Carl it is his and Bob who has it, nothing more", ctx do
    view = edit_form(ctx)

    view
    |> element("#assignment-form")
    |> render_submit(%{
      "assign_type" => "person",
      "assignment" => %{"assigned_person_uuid" => ctx.carl.person}
    })

    assert Projects.get_assignment(ctx.a.uuid).assigned_person_uuid == ctx.carl.person
    assert notices(ctx.carl.user) == ["projects.assignment_reassigned"]
    assert notices(ctx.bob.user) == ["projects.assignment_reassigned"]
  end

  test "a status changed in the form is one notice for the task's person", ctx do
    view = edit_form(ctx)

    view
    |> element("#assignment-form")
    |> render_submit(%{
      "assign_type" => "person",
      "assignment" => %{"assigned_person_uuid" => ctx.bob.person, "status" => "in_progress"}
    })

    assert Projects.get_assignment(ctx.a.uuid).status == "in_progress"
    assert notices(ctx.bob.user) == ["projects.assignment_started"]
  end
end
