defmodule PhoenixKitProjects.Web.DeltaReviewLiveTest do
  @moduledoc """
  What the review of the notice work found, driven through the pages:
  History stops showing a project to someone taken off it while the tab is
  open; a template's task is nobody's notice; handing a task on and starting
  it in one save is one notice; a later edit in the same visit is still news.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Activity, Members, Projects}
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitProjects.Web.{AssignmentFormLive, ProjectHistoryLive}
  alias PhoenixKitStaff.Schemas.Person

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

  defp actions(target) do
    Repo.all(
      from(e in Entry,
        where: e.target_uuid == ^target and like(e.action, "projects.assignment_%"),
        order_by: [asc: e.inserted_at],
        select: e.action
      )
    )
  end

  defp task!(project, title, attrs) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        attrs
      )

    a
  end

  test "History is empty for a viewer taken off the project while it is open", %{conn: conn} do
    # The first account on a site is its Owner, who sees every project.
    _owner = embed_user_uuid!()
    viewer = person!("Vera")
    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Members.add_member(project, viewer.user, role: "member")
    task = task!(project, "Secret task", %{})

    {:ok, _} =
      Activity.log("projects.assignment_created",
        resource_type: "assignment",
        resource_uuid: task.uuid,
        tell: false,
        metadata: %{"task" => "Secret task"}
      )

    scope = fake_scope(user_uuid: viewer.user, permissions: ["projects"], roles: [])

    {:ok, view, html} =
      live_isolated(put_test_scope(conn, scope), ProjectHistoryLive,
        session: %{"id" => project.uuid, "current_user_uuid" => viewer.user}
      )

    assert html =~ "Secret task"

    {:ok, _} = Members.remove_member(project.uuid, viewer.user)

    {:ok, _} =
      Activity.log("projects.assignment_updated",
        resource_type: "assignment",
        resource_uuid: task.uuid,
        tell: false,
        metadata: %{"task" => "Secret task, renamed"}
      )

    send(view.pid, :reload)
    refute render(view) =~ "Secret task"
  end

  test "a template's task given to someone is no notice of any kind" do
    bob = person!("Bob")
    template = fixture_template()
    a = task!(template, "Measure", %{"assigned_person_uuid" => bob.person})

    {:ok, _} =
      Activity.log("projects.assignment_created",
        actor_uuid: embed_user_uuid!(),
        resource_type: "assignment",
        resource_uuid: a.uuid,
        target_uuid: Activity.assignee_target_uuid(Projects.get_assignment(a.uuid)),
        metadata: %{"task" => "Measure"}
      )

    assert actions(bob.user) == []
  end

  describe "the form" do
    setup %{conn: conn} do
      me = embed_user_uuid!()
      project = fixture_project(%{"start_mode" => "immediate"})
      bob = person!("Bob")
      carl = person!("Carl")

      for p <- [bob, carl], do: {:ok, _} = Members.add_member(project, p.user, role: "member")

      a = task!(project, "Doors", %{"assigned_person_uuid" => bob.person})

      {:ok, view, _} =
        live_isolated(put_test_scope(conn, fake_scope(user_uuid: me)), AssignmentFormLive,
          session: %{
            "id" => a.uuid,
            "project_id" => project.uuid,
            "live_action" => "edit",
            "current_user_uuid" => me
          }
        )

      %{view: view, a: a, bob: bob, carl: carl}
    end

    defp submit(view, attrs) do
      view
      |> element("#assignment-form")
      |> render_submit(%{"assign_type" => "person", "assignment" => attrs})
    end

    test "handed on and started in one save: the new owner hears only that it is theirs", ctx do
      submit(ctx.view, %{"assigned_person_uuid" => ctx.carl.person, "status" => "in_progress"})

      assert actions(ctx.carl.user) == ["projects.assignment_reassigned"]
      assert actions(ctx.bob.user) == ["projects.assignment_reassigned"]
    end

    test "a change after a status change in the same visit still tells the owner", ctx do
      submit(ctx.view, %{"assigned_person_uuid" => ctx.bob.person, "status" => "in_progress"})

      submit(ctx.view, %{
        "assigned_person_uuid" => ctx.bob.person,
        "status" => "in_progress",
        "description" => "Oak, not ash"
      })

      assert actions(ctx.bob.user) == [
               "projects.assignment_started",
               "projects.assignment_updated"
             ]

      # …and only once per visit.
      submit(ctx.view, %{
        "assigned_person_uuid" => ctx.bob.person,
        "status" => "in_progress",
        "description" => "Ash after all"
      })

      assert actions(ctx.bob.user) == [
               "projects.assignment_started",
               "projects.assignment_updated"
             ]
    end
  end
end
