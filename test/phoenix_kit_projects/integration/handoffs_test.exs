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
  alias PhoenixKitProjects.{Actor, Handoffs, History, Outline, Projects}
  alias PhoenixKitProjects.Web.Components.HistoryFeed
  alias PhoenixKitStaff.Schemas.Person

  setup do
    Actor.put(nil)
    on_exit(fn -> Actor.put(nil) end)

    # History shows comments only while discussions are on.
    :ok = with_comments_module()

    people = Map.new(~w(alice bob carl dave)a, &{&1, person!(&1)})
    project = fixture_project(%{"start_mode" => "immediate"})

    for {_, p} <- people,
        do: {:ok, _} = PhoenixKitProjects.Members.add_member(project, p.user, role: "member")

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

    test "the line is written in the reader's language, not the sender's", ctx do
      %{alice: alice, bob: bob} = ctx.people

      Repo.update_all(
        from(u in PhoenixKit.Users.Auth.User, where: u.uuid == ^bob.user),
        set: [custom_fields: %{"preferred_locale" => "et"}]
      )

      measure = task!(ctx.project, "Measure the room", alice)
      model = task!(ctx.project, "3D model", bob)
      {:ok, _} = Projects.add_dependency(model.uuid, measure.uuid)

      Gettext.with_locale("en", fn -> set_status!(measure, "done", alice.user) end)

      assert [notice] = notices("projects.assignment_ready", bob.user)
      assert notice.metadata["notification_text"] =~ "Sinu kord"
      # The sender's own process keeps its language.
      assert Gettext.get_locale() == "en"
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

    test "a container and its subtasks woken for one person are one notice", ctx do
      %{alice: alice, bob: bob} = ctx.people
      drawings = task!(ctx.project, "Drawings", alice)
      order = task!(ctx.project, "Order materials", bob)
      task!(ctx.project, "Boards", bob, under: order)
      task!(ctx.project, "Hinges", bob, under: order)
      {:ok, _} = Projects.add_dependency(order.uuid, drawings.uuid)

      set_status!(drawings, "done", alice.user)

      assert [n] = notices("projects.assignment_ready", bob.user)
      assert n.resource_uuid == order.uuid
      assert n.metadata["more"] == 2
      assert n.metadata["notification_text"] =~ "2 more tasks"
    end

    test "starting a project tells each person once about what is ready", ctx do
      %{alice: alice, bob: bob} = ctx.people

      project =
        fixture_project(%{
          "start_mode" => "scheduled",
          "scheduled_start_date" => DateTime.add(DateTime.utc_now(), 7, :day)
        })

      for p <- [alice, bob],
          do: {:ok, _} = PhoenixKitProjects.Members.add_member(project, p.user, role: "member")

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

  describe "next up (would_ready/2)" do
    test "names what completing a task would make ready, before anything is written", ctx do
      %{alice: alice, bob: bob, carl: carl} = ctx.people
      consult = task!(ctx.project, "Consultation", alice)
      measure = task!(ctx.project, "Measurement", bob)
      render = task!(ctx.project, "3D render", carl)
      other = task!(ctx.project, "Other prerequisite", carl)
      install = task!(ctx.project, "Installation", bob)
      {:ok, _} = Projects.add_dependency(measure.uuid, consult.uuid)
      {:ok, _} = Projects.add_dependency(render.uuid, consult.uuid)
      {:ok, _} = Projects.add_dependency(install.uuid, consult.uuid)
      {:ok, _} = Projects.add_dependency(install.uuid, other.uuid)

      assert ctx.project.uuid
             |> Handoffs.would_ready(consult.uuid)
             |> Enum.map(& &1.uuid) == [measure.uuid, render.uuid]

      # A preview: nothing changed, nobody told.
      assert Projects.get_assignment(consult.uuid).status == "todo"
      assert notices("projects.assignment_ready", bob.user) == []
    end

    test "a task already under way is not offered", ctx do
      %{alice: alice, bob: bob} = ctx.people
      consult = task!(ctx.project, "Consultation", alice)
      measure = task!(ctx.project, "Measurement", bob, status: "in_progress")
      {:ok, _} = Projects.add_dependency(measure.uuid, consult.uuid)

      assert Handoffs.would_ready(ctx.project.uuid, consult.uuid) == []
    end

    test "a waiting task is offered too, and stays silent until released", ctx do
      %{alice: alice, bob: bob} = ctx.people
      consult = task!(ctx.project, "Consultation", alice)
      measure = task!(ctx.project, "Measurement", bob, status: "waiting")
      {:ok, _} = Projects.add_dependency(measure.uuid, consult.uuid)

      assert [%{uuid: uuid}] = Handoffs.would_ready(ctx.project.uuid, consult.uuid)
      assert uuid == measure.uuid

      # Done: the waiting task is idle, so nobody is told yet.
      set_status!(consult, "done", alice.user)
      assert notices("projects.assignment_ready", bob.user) == []

      # Released: now it is their turn, named after what it waited on.
      Actor.put(alice.user)

      {:ok, _} =
        Projects.update_assignment_status(Projects.get_assignment(measure.uuid), %{status: "todo"})

      assert [notice] = notices("projects.assignment_ready", bob.user)
      assert notice.resource_uuid == measure.uuid
      assert notice.metadata["after"] == "Consultation"
    end

    test "a task released with nothing before it can start at once", ctx do
      %{alice: alice, bob: bob} = ctx.people
      first = task!(ctx.project, "Talk to the client", bob, status: "waiting")
      Actor.put(alice.user)

      {:ok, _} = Projects.update_assignment_status(first, %{status: "todo"})

      assert [notice] = notices("projects.assignment_ready", bob.user)
      assert notice.metadata["notification_text"] =~ "can start"
    end

    test "putting a released task back to idle tells nobody", ctx do
      %{alice: alice, bob: bob} = ctx.people
      a = task!(ctx.project, "Measurement", bob)
      Actor.put(alice.user)

      {:ok, _} = Projects.update_assignment_status(a, %{status: "waiting"})

      assert notices("projects.assignment_ready", bob.user) == []
    end

    test "closing a parent's last subtask counts the parent done", ctx do
      %{alice: alice, bob: bob} = ctx.people
      prep = task!(ctx.project, "Preparation", alice)
      sub = task!(ctx.project, "Last step", alice, under: prep)
      next = task!(ctx.project, "After preparation", bob)
      {:ok, _} = Projects.add_dependency(next.uuid, prep.uuid)

      assert [%{uuid: uuid}] = Handoffs.would_ready(ctx.project.uuid, sub.uuid)
      assert uuid == next.uuid
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

  describe "who may be told" do
    test "a team member who cannot open the project is not told", ctx do
      %{alice: alice, bob: bob} = ctx.people
      outsider = person!(:olga)

      {:ok, dept} =
        Repo.insert(%PhoenixKitStaff.Schemas.Department{
          name: "Dept #{System.unique_integer([:positive])}"
        })

      {:ok, team} =
        Repo.insert(%PhoenixKitStaff.Schemas.Team{name: "Team", department_uuid: dept.uuid})

      for p <- [bob, outsider],
          do:
            Repo.insert!(%PhoenixKitStaff.Schemas.TeamMembership{
              team_uuid: team.uuid,
              staff_person_uuid: p.person
            })

      first = task!(ctx.project, "First", alice)

      {:ok, %{assignment: second}} =
        Projects.create_task_with_assignment(
          ctx.project.uuid,
          %{"title" => "Second", "ad_hoc" => true},
          %{
            "assigned_team_uuid" => team.uuid,
            "status" => "todo"
          }
        )

      {:ok, _} = Projects.add_dependency(second.uuid, first.uuid)
      set_status!(first, "done", alice.user)

      assert [_] = notices("projects.assignment_ready", bob.user)
      assert notices("projects.assignment_ready", outsider.user) == []
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

    test "a task comment tells the assignee, earlier commenters and the mentioned, never the author",
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
      # Core's mention ping runs only from the comments box; this comment did
      # not come through it, so the mention is told by the comment's notice.
      assert [_] = notices("projects.comment_added", dave.user)
      assert notices("projects.comment_added", carl.user) == []

      # History hangs the people told on the comment's own line.
      %{entries: entries} = History.list(Projects.get_project(ctx.project.uuid))
      first = Enum.find(entries, &(&1.kind == :comment and &1.quote == "Wall A does not add up."))
      assert Enum.map(first.told, & &1.uuid) == [bob.user]
      refute Enum.any?(entries, &(&1[:action] == "projects.comment_added"))
    end

    test "someone who commented and has since left the project is not told", ctx do
      %{alice: alice, bob: bob, carl: carl} = ctx.people
      model = task!(ctx.project, "Model", bob)

      {:ok, _} =
        PhoenixKitComments.create_comment("assignment", model.uuid, carl.user, %{
          content: "First."
        })

      {:ok, _} = PhoenixKitProjects.Members.remove_member(ctx.project.uuid, carl.user)

      {:ok, _} =
        PhoenixKitComments.create_comment("assignment", model.uuid, alice.user, %{
          content: "Second."
        })

      assert notices("projects.comment_added", carl.user) == []
      assert [_ | _] = notices("projects.comment_added", bob.user)
    end

    test "a comment waiting for moderation tells nobody", ctx do
      %{alice: alice, bob: bob} = ctx.people
      model = task!(ctx.project, "Model", bob)

      {:ok, _} =
        PhoenixKitComments.create_comment("assignment", model.uuid, alice.user, %{
          content: "Not approved yet.",
          status: "pending"
        })

      assert notices("projects.comment_added", bob.user) == []
    end

    test "a team-assigned task's reopen reason is not a second notice (the reopen tells the team)",
         ctx do
      %{alice: alice, bob: bob} = ctx.people

      {:ok, dept} =
        Repo.insert(%PhoenixKitStaff.Schemas.Department{
          name: "D #{System.unique_integer([:positive])}"
        })

      {:ok, team} =
        Repo.insert(%PhoenixKitStaff.Schemas.Team{name: "Sales", department_uuid: dept.uuid})

      Repo.insert!(%PhoenixKitStaff.Schemas.TeamMembership{
        team_uuid: team.uuid,
        staff_person_uuid: bob.person
      })

      {:ok, %{assignment: t}} =
        Projects.create_task_with_assignment(
          ctx.project.uuid,
          %{"title" => "Quote", "ad_hoc" => true},
          %{
            "assigned_team_uuid" => team.uuid,
            "status" => "todo"
          }
        )

      {:ok, _} =
        PhoenixKitComments.create_comment("assignment", t.uuid, alice.user, %{
          content: "Measure wall A again.",
          metadata: %{"reopen_reason" => true}
        })

      assert notices("projects.comment_added", bob.user) == []
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
    test "a foreign task with activity, comments, notes and time has no history here", ctx do
      %{alice: alice} = ctx.people
      foreign = fixture_project(%{"start_mode" => "immediate"})
      task = task!(foreign, "Private task", alice)

      for project <- [ctx.project, foreign],
          do: {:ok, _} = PhoenixKitProjects.Features.set_flags(project, %{"ledger" => true})

      {:ok, _} =
        PhoenixKitProjects.Activity.log("projects.assignment_updated",
          resource_type: "assignment",
          resource_uuid: task.uuid,
          actor_uuid: alice.user,
          tell: false
        )

      for type <- ["assignment", "project_task_notes"] do
        {:ok, _} =
          PhoenixKitComments.create_comment(type, task.uuid, alice.user, %{
            content: "Private words"
          })
      end

      {:ok, time} =
        PhoenixKitProjects.Ledger.log_time(foreign.uuid, 60,
          assignment_uuid: task.uuid,
          actor_uuid: alice.user
        )

      {:ok, _} = PhoenixKitProjects.Ledger.update_time(time, 30, actor_uuid: alice.user)

      for kind <- [:activity, :comment, :note, :time] do
        assert %{entries: [_ | _]} =
                 History.list(Projects.get_project(foreign.uuid), task: task.uuid, kinds: [kind])

        assert %{entries: [], total: 0, truncated: false} =
                 History.list(Projects.get_project(ctx.project.uuid),
                   task: task.uuid,
                   kinds: [kind]
                 )
      end
    end

    test "rapid edits keep each event's recipients on its own history line", ctx do
      %{alice: alice, bob: bob} = ctx.people
      task = task!(ctx.project, "Quote", bob)

      entries =
        for revision <- [1, 2] do
          {:ok, entry} =
            PhoenixKitProjects.Activity.log("projects.assignment_updated",
              actor_uuid: alice.user,
              resource_type: "assignment",
              resource_uuid: task.uuid,
              metadata: %{"revision" => revision}
            )

          entry
        end

      # Keep the two writes close even on a slow test runner.
      at = DateTime.utc_now()

      for {entry, offset} <- Enum.with_index(entries) do
        Repo.update_all(from(e in Entry, where: e.uuid == ^entry.uuid),
          set: [inserted_at: DateTime.add(at, offset, :millisecond)]
        )
      end

      %{entries: history} = History.list(Projects.get_project(ctx.project.uuid))
      edits = Enum.filter(history, &(&1.action == "projects.assignment_updated"))
      assert length(edits) == 2

      for edit <- edits do
        assert [%{uuid: recipient}] = edit.told
        assert recipient == bob.user
      end
    end

    test "slow notice delivery still folds into the event it announces", ctx do
      %{alice: alice, bob: bob} = ctx.people
      task = task!(ctx.project, "Quote", bob)

      {:ok, entry} =
        PhoenixKitProjects.Activity.log("projects.assignment_updated",
          actor_uuid: alice.user,
          resource_type: "assignment",
          resource_uuid: task.uuid
        )

      assert [notice] = notices("projects.assignment_updated", bob.user)

      Repo.update_all(from(e in Entry, where: e.uuid == ^notice.uuid),
        set: [inserted_at: DateTime.add(entry.inserted_at, 10, :second)]
      )

      %{entries: history} = History.list(Projects.get_project(ctx.project.uuid))
      assert [edit] = Enum.filter(history, &(&1.action == "projects.assignment_updated"))
      assert edit.id == "a-" <> entry.uuid
      assert [%{uuid: recipient}] = edit.told
      assert recipient == bob.user
    end

    test "rapid handovers keep both sets of notices on their own event", ctx do
      %{alice: alice, bob: bob, carl: carl} = ctx.people
      task = task!(ctx.project, "Quote", bob)

      for person <- [carl, bob] do
        was = Projects.get_assignment(task.uuid)

        {:ok, now} =
          Projects.update_assignment_form(was, %{"assigned_person_uuid" => person.person})

        assert PhoenixKitProjects.Notices.reassigned(was, now, alice.user)
      end

      %{entries: history} = History.list(Projects.get_project(ctx.project.uuid))
      handovers = Enum.filter(history, &(&1.action == "projects.assignment_reassigned"))
      assert length(handovers) == 2

      for handover <- handovers do
        assert Enum.sort(Enum.map(handover.told, & &1.uuid)) == Enum.sort([bob.user, carl.user])
      end
    end

    test "legacy notices are never folded into a different actor's event", ctx do
      %{alice: alice, bob: bob, carl: carl} = ctx.people
      task = task!(ctx.project, "Quote", bob)

      for actor <- [alice, carl] do
        {:ok, _} =
          PhoenixKitProjects.Activity.log("projects.assignment_updated",
            actor_uuid: actor.user,
            resource_type: "assignment",
            resource_uuid: task.uuid,
            tell: false
          )
      end

      # A pre-correlation notice: it has no source_activity_uuid.
      :ok =
        PhoenixKitProjects.Notices.notify(
          "projects.assignment_updated",
          Projects.get_assignment(task.uuid),
          actor_uuid: alice.user,
          recipients: [bob.user]
        )

      %{entries: history} = History.list(Projects.get_project(ctx.project.uuid))
      edits = Enum.filter(history, &(&1.action == "projects.assignment_updated"))
      assert length(edits) == 2
      assert Enum.find(edits, &(&1.actor_uuid == carl.user)).told == []
      assert [%{uuid: recipient}] = Enum.find(edits, &(&1.actor_uuid == alice.user)).told
      assert recipient == bob.user
    end

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

      # A task that is not this project's has no lines here, whatever its own rows say.
      assert %{entries: [], total: 0} =
               History.list(Projects.get_project(ctx.project.uuid), task: Ecto.UUID.generate())

      # A deleted task's rows stay, by the project they name, without a link.
      {:ok, _} = Projects.delete_assignment(Projects.get_assignment(measure.uuid))
      %{entries: after_delete} = History.list(Projects.get_project(ctx.project.uuid))
      gone = Enum.filter(after_delete, &(&1.task && &1.task.uuid == measure.uuid))
      assert gone != []
      assert Enum.all?(gone, &(&1.task[:gone] == true and &1.task.label == "Measure"))
      assert Enum.all?(only_model, &(&1.task == nil or &1.task.uuid == model.uuid))
    end
  end

  describe "the module's own registration" do
    test "task comments are handled by CommentNotices, which is no `#` search handler" do
      links = PhoenixKitProjects.resource_links()
      assert links["assignment"] == PhoenixKitProjects.CommentNotices
      refute function_exported?(PhoenixKitProjects.CommentNotices, :search_resources, 2)
      Code.ensure_loaded!(PhoenixKitProjects.CommentNotices)
      assert function_exported?(PhoenixKitProjects.CommentNotices, :visible_resource_uuids, 2)
    end
  end

  describe "with the module's real comment handlers" do
    setup do
      previous = Application.get_env(:phoenix_kit, :comment_resource_handlers)

      Application.put_env(
        :phoenix_kit,
        :comment_resource_handlers,
        PhoenixKitProjects.resource_links()
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit, :comment_resource_handlers, previous),
          else: Application.delete_env(:phoenix_kit, :comment_resource_handlers)
      end)
    end

    test "a project comment tells the managers, never the author; the notice is permanent", ctx do
      %{alice: alice, bob: bob, carl: carl} = ctx.people
      {:ok, _} = PhoenixKitProjects.Members.add_member(ctx.project, bob.user, role: "manager")

      PhoenixKitProjects.PubSub.subscribe(
        PhoenixKitProjects.PubSub.topic_project(ctx.project.uuid)
      )

      {:ok, comment} =
        PhoenixKitComments.create_comment("project", ctx.project.uuid, alice.user, %{
          content: "Kitchen handed over."
        })

      assert [n] = notices("projects.comment_added", bob.user)
      assert n.permanent
      assert n.metadata["project_uuid"] == ctx.project.uuid
      assert notices("projects.comment_added", carl.user) == []
      assert_receive {:projects, :comment_added, %{project_uuid: _}}

      # Deleting the comment takes its words out of the notice.
      {:ok, _} = PhoenixKitComments.delete_comment(comment)
      [scrubbed] = notices("projects.comment_added", bob.user)
      refute Map.has_key?(scrubbed.metadata, "excerpt")
      refute scrubbed.metadata["notification_text"] =~ "Kitchen handed over"
      assert scrubbed.metadata["notification_text"] =~ "deleted"
    end
  end

  describe "rows and gates" do
    test "a department assignee's people are told", ctx do
      %{alice: alice, bob: bob} = ctx.people

      {:ok, dept} =
        Repo.insert(%PhoenixKitStaff.Schemas.Department{
          name: "Install #{System.unique_integer([:positive])}"
        })

      Repo.update_all(from(p in PhoenixKitStaff.Schemas.Person, where: p.uuid == ^bob.person),
        set: [primary_department_uuid: dept.uuid]
      )

      first = task!(ctx.project, "First", alice)

      {:ok, %{assignment: second}} =
        Projects.create_task_with_assignment(
          ctx.project.uuid,
          %{"title" => "Second", "ad_hoc" => true},
          %{
            "assigned_department_uuid" => dept.uuid,
            "status" => "todo"
          }
        )

      {:ok, _} = Projects.add_dependency(second.uuid, first.uuid)
      set_status!(first, "done", alice.user)

      assert [_] = notices("projects.assignment_ready", bob.user)
    end

    test "a task's row names its project even when the caller did not", ctx do
      %{alice: alice} = ctx.people
      t = task!(ctx.project, "Stamped", alice)

      {:ok, entry} =
        PhoenixKitProjects.Activity.log("projects.assignment_updated",
          actor_uuid: alice.user,
          resource_type: "assignment",
          resource_uuid: t.uuid,
          metadata: %{"task" => "Stamped"}
        )

      assert entry.metadata["project_uuid"] == ctx.project.uuid
      assert entry.permanent
    end

    test "a change tells the project's History to reload after its notices exist", ctx do
      %{alice: alice, bob: bob} = ctx.people
      a = task!(ctx.project, "A", alice)
      b = task!(ctx.project, "B", bob)
      {:ok, _} = Projects.add_dependency(b.uuid, a.uuid)

      PhoenixKitProjects.PubSub.subscribe(
        PhoenixKitProjects.PubSub.topic_project(ctx.project.uuid)
      )

      set_status!(a, "done", alice.user)

      assert_receive {:projects, :history_changed, %{project_uuid: _}}
      assert [_] = notices("projects.assignment_ready", bob.user)
    end

    test "a corrected or removed time entry is a line of its own, on the project and on the task",
         ctx do
      %{alice: alice} = ctx.people
      t = task!(ctx.project, "Carcass", alice)
      project = Projects.get_project(ctx.project.uuid)
      {:ok, _} = PhoenixKitProjects.Features.set_flags(project, %{"ledger" => true})

      {:ok, entry} =
        PhoenixKitProjects.Ledger.log_time(ctx.project.uuid, 60,
          assignment_uuid: t.uuid,
          actor_uuid: alice.user
        )

      {:ok, _} = PhoenixKitProjects.Ledger.update_time(entry, 30, actor_uuid: alice.user)
      {:ok, _} = PhoenixKitProjects.Ledger.delete_entry(entry.uuid, actor_uuid: alice.user)

      project = Projects.get_project(ctx.project.uuid)

      for entries <- [History.list(project).entries, History.list(project, task: t.uuid).entries] do
        assert [amended] = Enum.filter(entries, &(&1[:action] == "projects.work_amended"))
        assert amended.task.uuid == t.uuid
        assert amended.meta["amount_was"] == "60"
        assert [_removed] = Enum.filter(entries, &(&1[:action] == "projects.work_removed"))
      end

      # Corrections are part of the order's story: never pruned.
      assert Repo.all(
               from(e in Entry,
                 where: e.action in ["projects.work_amended", "projects.work_removed"],
                 select: e.permanent
               )
             ) == [true, true]

      require Phoenix.LiveViewTest

      html =
        Phoenix.LiveViewTest.render_component(
          &HistoryFeed.history_feed/1,
          id: "h",
          entries: History.list(project).entries,
          project: project,
          links: false
        )

      assert html =~ "1 h"
      assert html =~ "30 min"
    end

    test "History leaves out what the project switched off", ctx do
      %{alice: alice} = ctx.people
      t = task!(ctx.project, "T", alice)

      {:ok, _} =
        PhoenixKitProjects.Ledger.log_time(ctx.project.uuid, 30,
          assignment_uuid: t.uuid,
          actor_uuid: alice.user
        )

      project = Projects.get_project(ctx.project.uuid)
      {:ok, _} = PhoenixKitProjects.Features.set_flags(project, %{"ledger" => true})

      assert Enum.any?(
               History.list(Projects.get_project(project.uuid)).entries,
               &(&1.kind == :time)
             )

      {:ok, _} = PhoenixKitProjects.Features.set_flags(project, %{"ledger" => false})

      refute Enum.any?(
               History.list(Projects.get_project(project.uuid)).entries,
               &(&1.kind == :time)
             )
    end
  end

  describe "the panel's last sweep" do
    defp team!(name, members, dept \\ nil) do
      dept =
        dept ||
          Repo.insert!(%PhoenixKitStaff.Schemas.Department{
            name: "#{name} dept #{System.unique_integer([:positive])}"
          })

      team = Repo.insert!(%PhoenixKitStaff.Schemas.Team{name: name, department_uuid: dept.uuid})

      for p <- members,
          do:
            Repo.insert!(%PhoenixKitStaff.Schemas.TeamMembership{
              team_uuid: team.uuid,
              staff_person_uuid: p.person
            })

      {team, dept}
    end

    defp group_task!(project, title, field, uuid) do
      {:ok, %{assignment: a}} =
        Projects.create_task_with_assignment(
          project.uuid,
          %{"title" => title, "ad_hoc" => true},
          # Released ("can be started"): a waiting task is idle and is
          # told nothing when what it waits on is done.
          %{field => uuid, "status" => "todo"}
        )

      a
    end

    test "a tick that also closes the parent tells the task after both once", ctx do
      %{alice: alice, bob: bob} = ctx.people
      production = task!(ctx.project, "Production", alice)
      pack = task!(ctx.project, "Pack", alice, under: production)
      install = task!(ctx.project, "Install", bob)
      {:ok, _} = Projects.add_dependency(install.uuid, production.uuid)
      {:ok, _} = Projects.add_dependency(install.uuid, pack.uuid)

      set_status!(pack, "done", alice.user)

      assert Projects.get_assignment(production.uuid).status == "done"
      assert [_one] = notices("projects.assignment_ready", bob.user)
    end

    test "starting a project twice tells everyone once" do
      %{user: alice_user} = alice = person!(:alice)
      %{user: bob_user} = bob = person!(:bob)

      project =
        fixture_project(%{
          "start_mode" => "scheduled",
          "scheduled_start_date" => DateTime.add(DateTime.utc_now(), 7, :day)
        })

      for p <- [alice, bob],
          do: {:ok, _} = PhoenixKitProjects.Members.add_member(project, p.user, role: "member")

      task!(project, "Measure", bob)
      Actor.put(alice_user)

      {:ok, _} = Projects.start_project(project)
      {:ok, _} = Projects.start_project(project)

      assert [_one] = notices("projects.assignment_ready", bob_user)
    end

    test "a task's line is not written for someone who may not open the project", ctx do
      %{alice: alice} = ctx.people
      outsider = person!(:olga)
      t = task!(ctx.project, "Secret kitchen", alice)

      {:ok, entry} =
        PhoenixKitProjects.Activity.log("projects.assignment_reopened",
          actor_uuid: alice.user,
          resource_type: "assignment",
          resource_uuid: t.uuid,
          target_uuid: outsider.user,
          metadata: %{"task" => "Secret kitchen", "reason" => "The client's address is wrong"}
        )

      refute Map.has_key?(entry.metadata, "notification_text")

      {:ok, member_row} =
        PhoenixKitProjects.Activity.log("projects.assignment_reopened",
          actor_uuid: alice.user,
          resource_type: "assignment",
          resource_uuid: t.uuid,
          target_uuid: ctx.people.bob.user,
          metadata: %{"task" => "Secret kitchen"}
        )

      assert member_row.metadata["notification_text"] =~ "Secret kitchen"
    end

    test "reopening a team's task tells its people, quoting the reason; History names them on the reopen's line",
         ctx do
      %{alice: alice, bob: bob, carl: carl} = ctx.people
      {team, _} = team!("Workshop", [bob, carl])
      quote_task = group_task!(ctx.project, "Quote", "assigned_team_uuid", team.uuid)
      set_status!(quote_task, "done", alice.user)

      Actor.put(alice.user)
      set_status!(quote_task, "todo", alice.user)

      # The page's own row: a team's task names no recipient, so the row
      # tells the team's people itself.
      {:ok, _} =
        PhoenixKitProjects.Activity.log("projects.assignment_reopened",
          actor_uuid: alice.user,
          resource_type: "assignment",
          resource_uuid: quote_task.uuid,
          target_uuid: PhoenixKitProjects.Activity.assignee_target_uuid(quote_task),
          metadata: %{"task" => "Quote", "reason" => "Wrong board thickness."}
        )

      for p <- [bob, carl] do
        assert [n] = notices("projects.assignment_reopened", p.user)
        assert n.metadata["notification_text"] =~ "Wrong board thickness."
      end

      assert notices("projects.assignment_reopened", alice.user) == []

      entries = History.list(Projects.get_project(ctx.project.uuid)).entries

      assert [line] =
               Enum.filter(
                 entries,
                 &(&1.action == "projects.assignment_reopened" and not &1.auto)
               )

      assert line.quote == "Wrong board thickness." or
               line.meta["reason"] == "Wrong board thickness."

      assert line.told |> Enum.map(& &1.uuid) |> Enum.sort() == Enum.sort([bob.user, carl.user])
    end

    test "a person assignee is told once — by the row's own notice", ctx do
      %{alice: alice, bob: bob} = ctx.people
      t = task!(ctx.project, "Mine", bob)

      {:ok, _} =
        PhoenixKitProjects.Activity.log("projects.assignment_reopened",
          actor_uuid: alice.user,
          resource_type: "assignment",
          resource_uuid: t.uuid,
          target_uuid:
            PhoenixKitProjects.Activity.assignee_target_uuid(Projects.get_assignment(t.uuid)),
          metadata: %{"task" => "Mine"}
        )

      assert [_one] = notices("projects.assignment_reopened", bob.user)
    end

    test "a department's people include its teams' members", ctx do
      %{alice: alice, bob: bob} = ctx.people
      {_team, dept} = team!("Production crew", [bob])
      first = task!(ctx.project, "First", alice)
      second = group_task!(ctx.project, "Second", "assigned_department_uuid", dept.uuid)
      {:ok, _} = Projects.add_dependency(second.uuid, first.uuid)

      set_status!(first, "done", alice.user)

      assert [_] = notices("projects.assignment_ready", bob.user)
    end

    test "work that can go on and work that can start are two notices, each naming its own",
         ctx do
      %{alice: alice, bob: bob} = ctx.people
      drawings = task!(ctx.project, "Drawings", alice)
      order = task!(ctx.project, "Order materials", bob)
      boards = task!(ctx.project, "Boards", bob)
      hinges = task!(ctx.project, "Hinges", bob)

      for t <- [order, boards, hinges],
          do: {:ok, _} = Projects.add_dependency(t.uuid, drawings.uuid)

      set_status!(order, "in_progress", bob.user)
      set_status!(drawings, "done", alice.user)

      ready = notices("projects.assignment_ready", bob.user)
      assert [go_on] = Enum.filter(ready, &(&1.metadata["resume"] == true))
      assert go_on.metadata["notification_text"] =~ "Order materials"
      assert [start] = Enum.reject(ready, &(&1.metadata["resume"] == true))
      assert start.metadata["notification_text"] =~ "Boards"
      assert start.metadata["more"] == 1
    end

    test "the prerequisite is named in the reader's language" do
      ctx = %{project: fixture_project(%{"start_mode" => "immediate"})}
      alice = person!(:alice)
      bob = person!(:bob)

      for p <- [alice, bob],
          do:
            {:ok, _} = PhoenixKitProjects.Members.add_member(ctx.project, p.user, role: "member")

      measure = task!(ctx.project, "Measure", alice)
      model = task!(ctx.project, "Model", bob)
      {:ok, _} = Projects.add_dependency(model.uuid, measure.uuid)

      measure_task = Projects.get_assignment(measure.uuid).task

      {:ok, _} =
        measure_task
        |> Ecto.Changeset.change(translations: %{"et" => %{"title" => "Mõõtmine"}})
        |> Repo.update()

      Repo.update_all(from(u in PhoenixKit.Users.Auth.User, where: u.uuid == ^bob.user),
        set: [custom_fields: %{"preferred_locale" => "et"}]
      )

      set_status!(measure, "done", alice.user)
      assert [n] = notices("projects.assignment_ready", bob.user)
      # the row keeps the primary name; the line is the reader's
      assert n.metadata["after"] == "Measure"
      assert n.metadata["after_uuid"] == measure.uuid
      assert n.metadata["notification_text"] =~ "Mõõtmine"
    end

    test "a change that failed is not part of the story", ctx do
      %{alice: alice} = ctx.people
      t = task!(ctx.project, "Failing", alice)

      {:ok, _} =
        PhoenixKitProjects.Activity.log_failed("projects.assignment_reopened",
          actor_uuid: alice.user,
          resource_type: "assignment",
          resource_uuid: t.uuid,
          metadata: %{"task" => "Failing"}
        )

      refute Enum.any?(
               History.list(Projects.get_project(ctx.project.uuid)).entries,
               &(&1[:action] == "projects.assignment_reopened")
             )
    end
  end
end
