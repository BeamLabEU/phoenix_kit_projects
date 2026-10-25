defmodule PhoenixKitProjects.Integration.NotificationCoverageTest do
  @moduledoc """
  Every event that concerns a task's people tells them, whatever path made
  it and whoever the task belongs to — a person, a team, a department —
  and tells them once: given a task, a task changed, started, done or
  reopened by someone else, handed on (the new and the old owner), removed,
  a note or a new direction written on it. Templates tell nobody.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Mentions.Token
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Activity, Actor, History, Notices, Projects, TaskNotes}
  alias PhoenixKitStaff.Schemas.{Department, Person, Team, TeamMembership}

  setup do
    Actor.put(nil)
    on_exit(fn -> Actor.put(nil) end)
    :ok = with_comments_module()

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

    people = Map.new(~w(alice bob carl dave)a, &{&1, person!(&1)})
    project = fixture_project(%{"start_mode" => "immediate"})

    for {_, p} <- people,
        do: {:ok, _} = PhoenixKitProjects.Members.add_member(project, p.user, role: "member")

    %{people: people, project: project}
  end

  defp person!(name) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{name}-#{System.unique_integer([:positive])}@example.com",
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

  defp task!(project, title, assignee) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        assignee
      )

    Projects.get_assignment(a.uuid)
  end

  defp team!(members) do
    dept = Repo.insert!(%Department{name: "Workshop #{System.unique_integer([:positive])}"})
    team = Repo.insert!(%Team{name: "Joiners", department_uuid: dept.uuid})

    for p <- members,
        do: Repo.insert!(%TeamMembership{team_uuid: team.uuid, staff_person_uuid: p.person})

    team
  end

  defp notices(action, target) do
    Repo.all(
      from(e in Entry,
        where: e.action == ^action and e.target_uuid == ^target,
        order_by: [asc: e.inserted_at]
      )
    )
  end

  # An entry as the paths that do not name the assignee write it (the
  # API, quick-add, the typed list).
  defp log!(action, a, actor, opts \\ []) do
    {:ok, _} =
      Activity.log(
        action,
        [
          actor_uuid: actor,
          resource_type: "assignment",
          resource_uuid: a.uuid,
          metadata: %{"task" => "x"}
        ] ++ opts
      )
  end

  test "a task given by a path that names nobody tells its person", ctx do
    %{alice: alice, bob: bob} = ctx.people
    a = task!(ctx.project, "Measure", %{"assigned_person_uuid" => bob.person})

    log!("projects.assignment_created", a, alice.user)

    assert [n] = notices("projects.assignment_created", bob.user)
    assert n.metadata["notification_text"] =~ "gave you a task"
    assert n.metadata["notification_text"] =~ "Measure"
    assert notices("projects.assignment_created", alice.user) == []
  end

  test "a team's task started, finished, reopened and changed by someone tells each of its people, never the one who did it",
       ctx do
    %{alice: alice, bob: bob, carl: carl} = ctx.people
    team = team!([bob, carl, alice])
    a = task!(ctx.project, "Carcasses", %{"assigned_team_uuid" => team.uuid})

    for action <-
          ~w(projects.assignment_started projects.assignment_completed projects.assignment_reopened projects.assignment_updated) do
      log!(action, a, alice.user)
      assert [_] = notices(action, bob.user), action
      assert [_] = notices(action, carl.user), action
      assert notices(action, alice.user) == [], action
    end
  end

  test "a person's own row is the only notice they get", ctx do
    %{alice: alice, bob: bob} = ctx.people
    a = task!(ctx.project, "Measure", %{"assigned_person_uuid" => bob.person})

    log!("projects.assignment_completed", a, alice.user,
      target_uuid: Activity.assignee_target_uuid(a)
    )

    assert [_one] = notices("projects.assignment_completed", bob.user)
  end

  test "tell: false and the tick rules' own rows tell nobody", ctx do
    %{alice: alice, bob: bob} = ctx.people
    a = task!(ctx.project, "Measure", %{"assigned_person_uuid" => bob.person})

    log!("projects.assignment_updated", a, alice.user, tell: false)

    {:ok, _} =
      Activity.log("projects.assignment_completed",
        actor_uuid: alice.user,
        resource_type: "assignment",
        resource_uuid: a.uuid,
        metadata: %{"auto" => true}
      )

    assert notices("projects.assignment_updated", bob.user) == []
    assert notices("projects.assignment_completed", bob.user) == []
  end

  test "handing a task on tells the new owner it is theirs and the old one who has it; History says so",
       ctx do
    %{alice: alice, bob: bob, carl: carl} = ctx.people
    a = task!(ctx.project, "3D model", %{"assigned_person_uuid" => bob.person})

    {:ok, moved} =
      Projects.update_assignment_form(a, %{
        "assigned_person_uuid" => carl.person
      })

    assert Notices.reassigned(a, moved, alice.user)

    assert [new] = notices("projects.assignment_reassigned", carl.user)
    assert new.metadata["notification_text"] =~ "gave you a task"
    assert [old] = notices("projects.assignment_reassigned", bob.user)
    assert old.metadata["notification_text"] =~ "handed"
    assert old.metadata["notification_text"] =~ "Carl"

    entries = History.list(Projects.get_project(ctx.project.uuid)).entries
    assert [line] = Enum.filter(entries, &(&1[:action] == "projects.assignment_reassigned"))
    assert line.meta["to"] == "Carl"
    assert line.told |> Enum.map(& &1.uuid) |> Enum.sort() == Enum.sort([bob.user, carl.user])

    refute Notices.reassigned(moved, moved, alice.user)
  end

  test "a removed task tells its people, linking to the project", ctx do
    %{alice: alice, bob: bob} = ctx.people
    a = task!(ctx.project, "Skirting", %{"assigned_person_uuid" => bob.person})
    {:ok, _} = Projects.delete_assignment(a)

    :ok = Notices.removed(a, alice.user)

    assert [n] = notices("projects.assignment_removed", bob.user)
    assert n.metadata["notification_text"] =~ "removed your task"
    assert n.metadata["notification_text"] =~ "Skirting"
    refute n.metadata["notification_link"] =~ "task="
  end

  test "a person's note and a new direction tell the task's people; an agent's note does not",
       ctx do
    %{alice: alice, bob: bob} = ctx.people
    a = task!(ctx.project, "Drawings", %{"assigned_person_uuid" => bob.person})

    {:ok, fields} = TaskNotes.validate(%{"summary" => "Use the 18 mm board"}, "redirect")
    {:ok, _} = TaskNotes.create(a, fields, user_uuid: alice.user, kind: "redirect")

    assert [n] = notices("projects.comment_added", bob.user)
    assert n.metadata["notification_text"] =~ "changed the direction"
    assert n.metadata["notification_text"] =~ "18 mm"

    {:ok, agent} = TaskNotes.validate(%{"summary" => "Exported the DXF"}, "agent_note")
    {:ok, _} = TaskNotes.create(a, agent, user_uuid: alice.user)
    assert [_still_one] = notices("projects.comment_added", bob.user)

    entries = History.list(Projects.get_project(ctx.project.uuid)).entries

    assert Enum.any?(
             entries,
             &(&1.kind == :note and Enum.map(&1.told, fn t -> t.uuid end) == [bob.user])
           )
  end

  test "a person mentioned from the comments box is told once — by the comment's notice", ctx do
    %{alice: alice, bob: bob, carl: carl} = ctx.people
    {:ok, _} = PhoenixKit.Settings.update_setting("mentions_enabled", "true")
    on_exit(fn -> PhoenixKit.Settings.update_setting("mentions_enabled", "false") end)
    a = task!(ctx.project, "Worktop", %{"assigned_person_uuid" => bob.person})
    {:ok, token} = Token.to_string(:user, "user", carl.user, "Carl")
    content = "Check this " <> token

    {:ok, comment} =
      PhoenixKitComments.create_comment("assignment", a.uuid, alice.user, %{content: content})

    # What the comments box does after the create: index and ping.
    {:ok, new} =
      PhoenixKit.Mentions.sync("comment", comment.uuid, content,
        field: "content",
        actor_uuid: alice.user
      )

    PhoenixKit.Mentions.notify(new, source_type: "assignment", source_uuid: a.uuid)

    assert [_] = notices("projects.comment_added", carl.user)

    assert Repo.all(
             from(e in Entry,
               where: e.action == "mention.created" and e.target_uuid == ^carl.user
             )
           ) == []
  end

  test "a comment held for moderation tells nobody until it is approved, then tells its people",
       ctx do
    %{alice: alice, bob: bob} = ctx.people
    a = task!(ctx.project, "Hinges", %{"assigned_person_uuid" => bob.person})

    {:ok, comment} =
      PhoenixKitComments.create_comment("assignment", a.uuid, alice.user, %{
        content: "Blum or Hettich?",
        status: "pending"
      })

    assert notices("projects.comment_added", bob.user) == []

    # What the comments module calls when a moderator approves it.
    approved = %{comment | status: "published"}
    PhoenixKitProjects.CommentNotices.on_comment_published("assignment", a.uuid, approved)

    assert [n] = notices("projects.comment_added", bob.user)
    assert n.metadata["notification_text"] =~ "Blum or Hettich?"
  end

  test "a deleted note's words leave the notices that quoted it", ctx do
    %{alice: alice, bob: bob} = ctx.people
    a = task!(ctx.project, "Drawings", %{"assigned_person_uuid" => bob.person})
    {:ok, fields} = TaskNotes.validate(%{"summary" => "Use the secret supplier"}, "redirect")
    {:ok, %{note: note}} = TaskNotes.create(a, fields, user_uuid: alice.user, kind: "redirect")

    {:ok, _} = PhoenixKitComments.delete_comment(note)

    assert [n] = notices("projects.comment_added", bob.user)
    refute n.metadata["notification_text"] =~ "secret supplier"
    refute Map.has_key?(n.metadata, "excerpt")
  end

  test "removing a task tells the people of every task it takes with it", ctx do
    %{alice: alice, bob: bob, carl: carl} = ctx.people
    parent = task!(ctx.project, "Kitchen", %{"assigned_person_uuid" => bob.person})
    child = task!(ctx.project, "Worktop", %{"assigned_person_uuid" => carl.person})
    {:ok, _} = PhoenixKitProjects.Outline.move(child, parent.uuid, :last)

    {:ok, _} =
      Notices.removing(Projects.get_assignment(parent.uuid), alice.user, fn ->
        Projects.delete_assignment(Projects.get_assignment(parent.uuid))
      end)

    assert [_] = notices("projects.assignment_removed", bob.user)
    assert [n] = notices("projects.assignment_removed", carl.user)
    assert n.metadata["notification_text"] =~ "Worktop"

    # A refused delete tells nobody.
    other = task!(ctx.project, "Plinth", %{"assigned_person_uuid" => bob.person})
    {:error, :nope} = Notices.removing(other, alice.user, fn -> {:error, :nope} end)
    assert [_only_the_first] = notices("projects.assignment_removed", bob.user)
  end

  test "a template's tasks tell nobody", ctx do
    %{alice: alice, bob: bob} = ctx.people
    template = fixture_template()
    a = task!(template, "Measure", %{"assigned_person_uuid" => bob.person})

    log!("projects.assignment_created", a, alice.user)
    assert notices("projects.assignment_created", bob.user) == []
  end
end
