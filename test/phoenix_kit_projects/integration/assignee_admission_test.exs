defmodule PhoenixKitProjects.Integration.AssigneeAdmissionTest do
  @moduledoc """
  The boss's fourth list (2026-11-18), the notices track:

    * item 10 — whoever a task is given to can open its project
      (`Members.admit_assignees/3`), and `Members.assignee_reach/2` tells a
      screen who will be told;
    * item 13 — the notification types say what they are, with examples;
    * item 14 — the dialog's comment and the reopen reason travel as the
      notice's quote, not a cut-off excerpt;
    * item 21 — the people a task's comment box offers first after `@`,
      and its warning for someone who cannot open the project.

  Driven through the context functions every path (form, popup, API) uses.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{AssigneeSet, CommentMentions, Members, Notices, Projects}
  alias PhoenixKitStaff.Schemas.Person

  # The first account a database gets is its Owner, who opens everything:
  # made here so the people below are ordinary accounts.
  setup do
    {:ok, _owner} =
      Auth.register_user(%{
        "email" => "site-owner-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    :ok
  end

  defp person!(name) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{name}-#{n}@example.com",
        "password" => "ValidPassword123!",
        "first_name" => name
      })

    {:ok, person} =
      Repo.insert(%Person{user_uuid: user.uuid, status: "active", name: "#{name} #{n}"})

    %{user: user.uuid, person: person.uuid}
  end

  defp member_added(project_uuid, user_uuid) do
    Repo.all(
      from(e in Entry,
        where:
          e.action == "projects.member_added" and e.resource_uuid == ^project_uuid and
            e.target_uuid == ^user_uuid
      )
    )
  end

  defp new_task(project, attrs \\ %{}) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Fit the doors", "ad_hoc" => true},
        attrs
      )

    a
  end

  describe "item 10 — an assignee can open the project" do
    setup do
      %{project: fixture_project(%{"start_mode" => "immediate"})}
    end

    test "a new task given to someone off the project makes them a member, told so", ctx do
      anna = person!("Anna")
      refute Notices.may_view?(anna.user, ctx.project)

      new_task(ctx.project, %{"assigned_person_uuid" => anna.person})

      assert Members.role_of(ctx.project, anna.user) == :member
      assert Notices.may_view?(anna.user, ctx.project)

      assert [entry] = member_added(ctx.project.uuid, anna.user)
      assert entry.metadata["via"] == "assignment"
      assert entry.metadata["task"] == "Fit the doors"
      assert entry.metadata["notification_text"] =~ "Fit the doors"
    end

    test "editing a task's assignees admits only the ones added; existing members stay as they are",
         ctx do
      owner = person!("Olga")
      {:ok, _} = Members.add_member(ctx.project, owner.user, role: "owner")
      bert = person!("Bert")
      task = new_task(ctx.project, %{"assigned_person_uuid" => owner.person})

      {:ok, _} =
        Projects.update_assignment_form(task, %{
          "assignees" => [{"person", owner.person}, {"person", bert.person}]
        })

      assert Members.role_of(ctx.project, owner.user) == :owner
      assert Members.role_of(ctx.project, bert.user) == :member

      refute Enum.any?(
               member_added(ctx.project.uuid, owner.user),
               &(&1.metadata["via"] == "assignment")
             )
    end

    test "a team's people are admitted with it", ctx do
      [a, b] = [person!("Tia"), person!("Tom")]
      n = System.unique_integer([:positive])
      {:ok, dept} = Repo.insert(%PhoenixKitStaff.Schemas.Department{name: "Works #{n}"})

      {:ok, team} =
        Repo.insert(%PhoenixKitStaff.Schemas.Team{
          name: "Kitchen #{n}",
          department_uuid: dept.uuid
        })

      for p <- [a, b] do
        Repo.insert!(%PhoenixKitStaff.Schemas.TeamMembership{
          team_uuid: team.uuid,
          staff_person_uuid: p.person
        })
      end

      new_task(ctx.project, %{"assigned_team_uuid" => team.uuid})

      assert Members.role_of(ctx.project, a.user) == :member
      assert Members.role_of(ctx.project, b.user) == :member
    end

    test "the reach says, person by person, who can be told", ctx do
      inside = person!("Ivo")
      {:ok, _} = Members.add_member(ctx.project, inside.user, role: "member")
      ann = person!("Ann")

      reach =
        Members.assignee_reach([{"person", inside.person}, {"person", ann.person}], ctx.project)

      assert [%{uuid: i, status: :ok}, %{uuid: n, status: :cannot_open}] = reach
      assert i == inside.person and n == ann.person

      # Assigning Ann is what lets her be told.
      task = new_task(ctx.project, %{"assigned_person_uuid" => ann.person})
      assert AssigneeSet.keys(task) == [{"person", ann.person}]

      assert [%{status: :ok}] = Members.assignee_reach([{"person", ann.person}], ctx.project)
    end

    test "a template's tasks admit nobody", _ctx do
      template = fixture_template(%{})
      anna = person!("Anna")

      {:ok, %{assignment: _}} =
        Projects.create_task_with_assignment(
          template.uuid,
          %{"title" => "Measure", "ad_hoc" => true},
          %{"assigned_person_uuid" => anna.person}
        )

      assert Members.role_of(template, anna.user) == nil
    end

    test "a deactivated account is not admitted", ctx do
      gone = person!("Gone")

      Repo.update_all(from(u in PhoenixKit.Users.Auth.User, where: u.uuid == ^gone.user),
        set: [is_active: false]
      )

      new_task(ctx.project, %{"assigned_person_uuid" => gone.person})
      assert Members.role_of(ctx.project, gone.user) == nil
    end
  end

  describe "item 13 — the notification types" do
    test "each line is named after what the reader sees, with an example; the keys stay" do
      [projects] = PhoenixKitProjects.notification_types()
      subs = Map.new(projects.sub_types, &{&1.key, &1})

      assert Map.keys(subs) |> Enum.sort() ==
               ~w(comments events handoffs health membership tasks)

      assert subs["handoffs"].label == "A task of yours can be started"
      assert subs["tasks"].label == "Changes to your tasks"
      assert subs["membership"].label == "Added to or removed from a project"
      assert subs["events"].label == "Meetings and milestones"

      for {key, sub} <- subs do
        assert is_binary(sub[:example]) and sub.example != "", "#{key} has no example"
      end
    end
  end

  describe "item 14 — the comment travels as the notice's quote" do
    test "the dialog's comment and the reopen reason become the quote when core draws one" do
      long = String.duplicate("Wall A is 3240, not 3420. ", 20)

      ready = Notices.with_quote("projects.assignment_ready", %{"note" => long}, "actor", nil)

      reopened =
        Notices.with_quote(
          "projects.assignment_reopened",
          %{"reason" => "Measure again"},
          nil,
          nil
        )

      other = Notices.with_quote("projects.comment_added", %{"note" => "x"}, "actor", nil)

      if Notices.quotes?() do
        assert ready["quote"] == %{"text" => String.trim(long), "author_uuid" => "actor"}
        assert reopened["quote"] == %{"text" => "Measure again"}
      else
        refute Map.has_key?(ready, "quote")
        refute Map.has_key?(reopened, "quote")
      end

      # A comment notice's "note" is a different thing (a task note), never a quote.
      refute Map.has_key?(other, "quote")
      # An explicit quote (a comment that mentions someone) for any action.
      explicit = Notices.with_quote("projects.comment_added", %{}, "a", "  Hello  ")
      if Notices.quotes?(), do: assert(explicit["quote"]["text"] == "Hello")
    end

    test "with a quote the line is a one-line summary; without one the excerpt stays in it" do
      project = fixture_project(%{"start_mode" => "immediate"})
      task = new_task(project)
      task = Projects.get_assignment(task.uuid)

      plain = Notices.line("projects.assignment_ready", task, "Max", %{"note" => "Measured"})

      quoted =
        Notices.line("projects.assignment_ready", task, "Max", %{
          "note" => "Measured",
          "quote" => %{"text" => "Measured"}
        })

      assert plain =~ "Measured"
      refute quoted =~ "Measured"
      assert quoted =~ "can be started"

      reopened =
        Notices.line("projects.assignment_reopened", task, "Max", %{
          "reason" => "Wrong wall",
          "quote" => %{"text" => "Wrong wall"}
        })

      refute reopened =~ "Wrong wall"
    end
  end

  describe "item 21 — mentions in a task's comments" do
    setup do
      %{project: fixture_project(%{"start_mode" => "immediate"})}
    end

    test "the task's people come first, then the project's members, each once", ctx do
      member = person!("Mia")
      {:ok, _} = Members.add_member(ctx.project, member.user, role: "member")
      worker = person!("Walt")
      task = new_task(ctx.project, %{"assigned_person_uuid" => worker.person})

      people = CommentMentions.people(ctx.project, Projects.get_assignment(task.uuid))
      uuids = Enum.map(people, & &1.uuid)

      # Walt is on the task (and a member by now, item 10): first, once.
      assert hd(uuids) == worker.user
      assert member.user in uuids
      assert length(uuids) == length(Enum.uniq(uuids))
      assert hd(people).subtitle == "On this task"
    end

    test "the warning names someone who cannot open the project, and nobody else", ctx do
      inside = person!("Ida")
      {:ok, _} = Members.add_member(ctx.project, inside.user, role: "member")
      outside = person!("Otto")

      check = CommentMentions.warning(ctx.project)

      assert check.(inside.user) == nil
      assert check.(outside.user) =~ "can't open this project"
    end
  end
end
