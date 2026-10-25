defmodule PhoenixKitProjects.Integration.HandoffsTest do
  @moduledoc """
  What a status change tells the people around it (`Handoffs`), what a
  comment tells (`CommentNotices`), the line each notice carries
  (`Notices`) and how `History` reads it all back — driven through the
  context functions every path uses, never through a LiveView.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Mentions.Token
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Actor, History, Outline, Projects}
  alias PhoenixKitStaff.Schemas.Person

  setup do
    Actor.put(nil)
    on_exit(fn -> Actor.put(nil) end)

    people = Map.new(~w(alice bob carl dave)a, &{&1, person!(&1)})
    project = fixture_project(%{"start_mode" => "immediate"})

    %{people: people, project: project}
  end

  defp person!(name) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{name}-#{n}@example.com",
        "password" => "ValidPassword123!",
        "first_name" => String.capitalize(to_string(name))
      })

    {:ok, person} =
      Repo.insert(%Person{
        user_uuid: user.uuid,
        status: "active",
        name: String.capitalize(to_string(name))
      })

    %{user: user.uuid, person: person.uuid}
  end

  defp task!(project, title, owner, opts \\ []) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        %{
          "assigned_person_uuid" => owner && owner.person,
          "status" => Keyword.get(opts, :status, "todo")
        }
      )

    case Keyword.get(opts, :under) do
      nil -> a
      parent -> elem(Outline.move(Projects.get_assignment(a.uuid), parent.uuid, :last), 1)
    end
  end

  defp set_status!(a, status, actor) do
    Actor.put(actor)

    attrs =
      case status do
        "done" ->
          %{
            status: "done",
            progress_pct: 100,
            completed_by_uuid: actor,
            completed_at: DateTime.utc_now()
          }

        "in_progress" ->
          %{status: "in_progress"}

        "todo" ->
          %{status: "todo", progress_pct: 0, completed_by_uuid: nil, completed_at: nil}
      end

    {:ok, updated} = Projects.update_assignment_status(Projects.get_assignment(a.uuid), attrs)
    updated
  end

  defp notices(action, target) do
    Repo.all(
      from(e in Entry,
        where: e.action == ^action and e.target_uuid == ^target,
        order_by: [asc: e.inserted_at]
      )
    )
  end

  describe "your turn" do
    test "the task waiting on a finished one tells its assignee, with a line and a link", ctx do
      %{alice: alice, bob: bob} = ctx.people
      measure = task!(ctx.project, "Measure the room", alice)
      model = task!(ctx.project, "3D model", bob)
      {:ok, _} = Projects.add_dependency(model.uuid, measure.uuid)

      set_status!(measure, "done", alice.user)

      assert [notice] = notices("projects.assignment_ready", bob.user)
      assert notice.actor_uuid == alice.user
      assert notice.resource_uuid == model.uuid
      assert notice.metadata["after"] == "Measure the room"
      assert notice.metadata["notification_text"] =~ "Your turn"
      assert notice.metadata["notification_text"] =~ "3D model"
      assert notice.metadata["notification_link"] =~ "task="
    end

    test "nobody is told about their own hand-off", ctx do
      %{alice: alice} = ctx.people
      first = task!(ctx.project, "First", alice)
      second = task!(ctx.project, "Second", alice)
      {:ok, _} = Projects.add_dependency(second.uuid, first.uuid)

      set_status!(first, "done", alice.user)

      assert notices("projects.assignment_ready", alice.user) == []
    end

    test "a task still waiting on something else is not ready", ctx do
      %{alice: alice, bob: bob, carl: carl} = ctx.people
      a = task!(ctx.project, "A", alice)
      b = task!(ctx.project, "B", carl)
      c = task!(ctx.project, "C", bob)
      {:ok, _} = Projects.add_dependency(c.uuid, a.uuid)
      {:ok, _} = Projects.add_dependency(c.uuid, b.uuid)

      set_status!(a, "done", alice.user)
      assert notices("projects.assignment_ready", bob.user) == []

      set_status!(b, "done", carl.user)
      assert [_] = notices("projects.assignment_ready", bob.user)
    end

    test "a container that becomes ready wakes its subtasks that wait on nothing", ctx do
      %{alice: alice, bob: bob, carl: carl, dave: dave} = ctx.people
      received = task!(ctx.project, "Materials received", alice)
      production = task!(ctx.project, "Production", bob)
      cnc = task!(ctx.project, "CNC cutting", carl, under: production)
      edging = task!(ctx.project, "Edge banding", dave, under: production)
      {:ok, _} = Projects.add_dependency(production.uuid, received.uuid)
      {:ok, _} = Projects.add_dependency(edging.uuid, cnc.uuid)

      set_status!(received, "done", alice.user)

      assert [_] = notices("projects.assignment_ready", bob.user)
      assert [n] = notices("projects.assignment_ready", carl.user)
      assert n.resource_uuid == cnc.uuid
      assert notices("projects.assignment_ready", dave.user) == []
    end

    test "starting a project tells each person once about what is ready", ctx do
      %{alice: alice, bob: bob} = ctx.people

      project =
        fixture_project(%{
          "start_mode" => "scheduled",
          "scheduled_start_date" => DateTime.add(DateTime.utc_now(), 7, :day)
        })

      task!(project, "One", bob)
      task!(project, "Two", bob)
      later = task!(project, "Later", alice)
      first = task!(project, "First", alice)
      {:ok, _} = Projects.add_dependency(later.uuid, first.uuid)

      Actor.put(nil)
      {:ok, _} = Projects.start_project(Projects.get_project(project.uuid))

      assert [n] = notices("projects.assignment_ready", bob.user)
      assert n.metadata["more"] == 1
      assert n.metadata["notification_text"] =~ "1 more"
      assert [a] = notices("projects.assignment_ready", alice.user)
      assert a.resource_uuid == first.uuid
    end
  end

  describe "on hold, and going on again" do
    test "reopening finished work puts the started work after it on hold, finishing it lets it go on",
         ctx do
      %{alice: alice, bob: bob, carl: carl} = ctx.people
      invoice = task!(ctx.project, "Final invoice", alice)
      install = task!(ctx.project, "Installation", bob)
      {:ok, _} = Projects.add_dependency(install.uuid, invoice.uuid)

      set_status!(invoice, "done", alice.user)
      set_status!(install, "in_progress", bob.user)
      set_status!(invoice, "todo", carl.user)

      assert [hold] = notices("projects.assignment_on_hold", bob.user)
      assert hold.metadata["after"] == "Final invoice"
      assert hold.metadata["notification_text"] =~ "On hold"

      set_status!(invoice, "done", alice.user)

      ready = notices("projects.assignment_ready", bob.user)
      assert Enum.any?(ready, &(&1.metadata["resume"] == true))
    end
  end

  describe "rows nobody logged" do
    test "a parent the tick rules complete gets an auto row naming whose change it was", ctx do
      %{alice: alice} = ctx.people
      parent = task!(ctx.project, "Order materials", alice)
      sub = task!(ctx.project, "Boards", alice, under: parent)

      set_status!(sub, "done", alice.user)

      assert [row] =
               Repo.all(
                 from(e in Entry,
                   where:
                     e.action == "projects.assignment_completed" and
                       e.resource_uuid == ^parent.uuid
                 )
               )

      assert row.metadata["auto"] == true
      assert row.actor_uuid == alice.user
      assert row.permanent
    end
  end

  describe "comments" do
    # The projects module is not registered in the test environment, so the
    # comments module finds this handler through its host override.
    setup do
      previous = Application.get_env(:phoenix_kit, :comment_resource_handlers)

      Application.put_env(:phoenix_kit, :comment_resource_handlers, %{
        "assignment" => PhoenixKitProjects.CommentNotices,
        "project" => PhoenixKitProjects.ResourceLinks
      })

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit, :comment_resource_handlers, previous),
          else: Application.delete_env(:phoenix_kit, :comment_resource_handlers)
      end)
    end

    test "a task comment tells the assignee and earlier commenters, never the author or the mentioned",
         ctx do
      %{alice: alice, bob: bob, carl: carl, dave: dave} = ctx.people
      model = task!(ctx.project, "3D model", bob)

      {:ok, _} =
        PhoenixKitComments.create_comment("assignment", model.uuid, alice.user, %{
          content: "Wall A does not add up."
        })

      assert [n] = notices("projects.comment_added", bob.user)
      assert n.metadata["notification_text"] =~ "Wall A does not add up."
      assert notices("projects.comment_added", alice.user) == []

      {:ok, mention} = Token.to_string(:user, "user", dave.user, "Dave")

      {:ok, _} =
        PhoenixKitComments.create_comment("assignment", model.uuid, carl.user, %{
          content: "Agreed, #{mention} please check."
        })

      assert length(notices("projects.comment_added", bob.user)) == 2
      assert [_] = notices("projects.comment_added", alice.user)
      assert notices("projects.comment_added", dave.user) == []
      assert notices("projects.comment_added", carl.user) == []
    end

    test "a reopen's reason does not tell the assignee twice", ctx do
      %{alice: alice, bob: bob} = ctx.people
      measure = task!(ctx.project, "Measure", bob)

      # Even when the assignee commented on the task before.
      {:ok, _} =
        PhoenixKitComments.create_comment("assignment", measure.uuid, bob.user, %{
          content: "Measured."
        })

      {:ok, _} =
        PhoenixKitComments.create_comment("assignment", measure.uuid, alice.user, %{
          content: "You forgot the radiator.",
          metadata: %{"reopen_reason" => true}
        })

      assert notices("projects.comment_added", bob.user) == []
    end
  end

  describe "History" do
    test "reads the story back: changes, the reason, comments, who was told", ctx do
      %{alice: alice, bob: bob} = ctx.people
      measure = task!(ctx.project, "Measure", alice)
      model = task!(ctx.project, "Model", bob)
      {:ok, _} = Projects.add_dependency(model.uuid, measure.uuid)

      set_status!(measure, "done", alice.user)

      PhoenixKitProjects.Activity.log("projects.assignment_completed",
        actor_uuid: alice.user,
        resource_type: "assignment",
        resource_uuid: measure.uuid,
        target_uuid: alice.user,
        metadata: %{"task" => "Measure"}
      )

      {:ok, _} =
        PhoenixKitComments.create_comment("assignment", model.uuid, bob.user, %{
          content: "Looking at it now."
        })

      {:ok, _} =
        PhoenixKitComments.create_comment("assignment", measure.uuid, bob.user, %{
          content: "This is the reason.",
          metadata: %{"reopen_reason" => true}
        })

      %{entries: entries} = History.list(Projects.get_project(ctx.project.uuid))

      ready = Enum.find(entries, &(&1[:action] == "projects.assignment_ready"))
      assert ready.task.label == "Model"
      assert [%{uuid: told}] = ready.told
      assert told == bob.user

      assert Enum.any?(entries, &(&1.kind == :comment and &1.quote == "Looking at it now."))
      refute Enum.any?(entries, &(&1.kind == :comment and &1.quote == "This is the reason."))
      # Comment notices are not lines of their own: the comment is.
      refute Enum.any?(entries, &(&1[:action] == "projects.comment_added"))

      only_model = History.list(Projects.get_project(ctx.project.uuid), task: model.uuid).entries
      assert Enum.all?(only_model, &(&1.task == nil or &1.task.uuid == model.uuid))
    end
  end
end
