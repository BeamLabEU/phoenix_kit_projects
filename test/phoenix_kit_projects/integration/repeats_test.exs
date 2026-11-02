defmodule PhoenixKitProjects.Integration.RepeatsTest do
  @moduledoc """
  Item 34: a repeating task, once done, stays done and ONE next task is
  made for the next date (`Repeats`, chain V28).
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Actor, Outline, Projects, Repeats}
  alias PhoenixKitProjects.Schemas.Assignment

  setup do
    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(project)
    %{project: project}
  end

  defp task!(project, title, assignment_attrs \\ %{}, opts \\ []) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        Map.merge(%{"status" => "todo"}, assignment_attrs)
      )

    case opts[:under] do
      nil -> Projects.get_assignment(a.uuid)
      parent -> elem(Outline.move(Projects.get_assignment(a.uuid), parent.uuid, :last), 1)
    end
  end

  defp done!(a) do
    {:ok, _} =
      Projects.update_assignment_status(Projects.get_assignment(a.uuid), %{
        status: "done",
        progress_pct: 100,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
  end

  test "the rule is read and written in one shape" do
    assert Repeats.normalize(%{"every" => "2", "unit" => "week"}) == %{
             "every" => 2,
             "unit" => "week"
           }

    assert Repeats.normalize(%{"every" => 0, "unit" => "week"}) == nil
    assert Repeats.normalize(%{"every" => 1, "unit" => "year"}) == nil

    assert Repeats.from_params(%{"repeat" => "2weeks", "x" => 1}) ==
             %{"repeat_rule" => %{"every" => 2, "unit" => "week"}, "x" => 1}

    assert Repeats.from_params(%{
             "repeat" => "custom",
             "repeat_every" => "10",
             "repeat_unit" => "day"
           })[
             "repeat_rule"
           ] == %{"every" => 10, "unit" => "day"}

    assert Repeats.from_params(%{"repeat" => "none"})["repeat_rule"] == nil
    assert Repeats.label(%{"every" => 2, "unit" => "week"}) == "Every 2 weeks"

    assert Repeats.shift(~U[2026-01-31 09:00:00Z], %{"every" => 1, "unit" => "month"}) ==
             ~U[2026-02-28 09:00:00Z]
  end

  test "done, it stays done and one next task comes for the next date", %{project: p} do
    deadline = ~U[2026-11-02 10:00:00Z]

    check =
      task!(p, "Check in with the client", %{
        "deadline" => deadline,
        "description" => "Call them",
        "estimated_duration" => 30,
        "estimated_duration_unit" => "minutes",
        "repeat_rule" => %{"every" => 1, "unit" => "week"}
      })

    sub = task!(p, "Ask about the doors", %{}, under: check)
    done!(sub)
    done!(check)

    old = Projects.get_assignment(check.uuid)
    assert old.status == "done"
    assert old.repeat_rule == nil

    [next] =
      Projects.list_assignments(p.uuid)
      |> Enum.filter(&(&1.repeat_rule != nil))

    assert next.uuid != check.uuid
    assert next.status == "todo"
    assert Assignment.label(next) == "Check in with the client"
    assert next.task_uuid != check.task_uuid
    assert next.description == "Call them"
    assert next.estimated_duration == 30
    assert next.deadline == ~U[2026-11-09 10:00:00Z]
    assert next.repeat_rule == %{"every" => 1, "unit" => "week"}

    # Its subtask again, not done.
    [again] = Enum.filter(Projects.list_assignments(p.uuid), &(&1.parent_uuid == next.uuid))
    assert Assignment.label(again) == "Ask about the doors"
    assert again.status == "todo"

    # Reopened and done again: no second next task.
    {:ok, _} =
      Projects.update_assignment_status(Projects.get_assignment(check.uuid), %{
        status: "todo",
        completed_at: nil
      })

    done!(check)
    assert Enum.count(Projects.list_assignments(p.uuid), &(&1.repeat_rule != nil)) == 1
  end

  test "a task that does not repeat makes nothing", %{project: p} do
    one = task!(p, "Once")
    done!(one)
    assert length(Projects.list_assignments(p.uuid)) == 1
  end

  # The control's shapes × what becomes of the rule: a choice it can read is
  # the rule, "Every…" just picked is what it shows (1 week), and a number
  # or unit it cannot read is kept so the changeset refuses it — never read
  # as "does not repeat", which silently ended the repeat.
  for {params, expected} <- [
        {%{"repeat" => "custom"}, {:rule, %{"every" => 1, "unit" => "week"}}},
        {%{"repeat" => "custom", "repeat_every" => "3", "repeat_unit" => "month"},
         {:rule, %{"every" => 3, "unit" => "month"}}},
        {%{"repeat" => "custom", "repeat_every" => "0", "repeat_unit" => "week"}, :refused},
        {%{"repeat" => "custom", "repeat_every" => "400", "repeat_unit" => "day"}, :refused},
        {%{"repeat" => "custom", "repeat_every" => "", "repeat_unit" => "week"}, :refused},
        {%{"repeat" => "custom", "repeat_every" => "2", "repeat_unit" => "year"}, :refused},
        {%{"repeat" => "none"}, {:rule, nil}}
      ] do
    test "the repeat control #{inspect(params)} -> #{inspect(expected)}" do
      attrs = Repeats.from_params(unquote(Macro.escape(params)))
      cs = Assignment.changeset(%Assignment{}, Map.take(attrs, ["repeat_rule"]))

      case unquote(Macro.escape(expected)) do
        {:rule, rule} ->
          assert Ecto.Changeset.get_field(cs, :repeat_rule) == rule
          refute Keyword.has_key?(cs.errors, :repeat_rule)

        :refused ->
          assert Keyword.has_key?(cs.errors, :repeat_rule)
      end
    end
  end

  test "the next occurrence is recorded: who finished it, and where it came from",
       %{project: p} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "repeat-#{System.unique_integer([:positive])}@example.com",
        "password" => "RepeatPass123!"
      })

    weekly = task!(p, "Weekly call", %{"repeat_rule" => %{"every" => 1, "unit" => "week"}})
    Actor.put(user.uuid)

    try do
      done!(weekly)
    after
      Actor.put(nil)
    end

    [next] = Enum.filter(Projects.list_assignments(p.uuid), &(&1.repeat_rule != nil))
    assert next.created_by_uuid == user.uuid

    assert_activity_logged("projects.assignment_created",
      resource_uuid: next.uuid,
      actor_uuid: user.uuid,
      metadata_has: %{"repeat_of" => weekly.uuid, "task" => "Weekly call"}
    )
  end

  describe "a month rule keeps its day" do
    test "31 Jan -> 28 Feb -> 31 Mar, not 28 Mar", %{project: p} do
      monthly =
        task!(p, "Invoice", %{
          "deadline" => ~U[2027-01-31 09:00:00Z],
          "repeat_rule" => %{"every" => 1, "unit" => "month"}
        })

      done!(monthly)
      [feb] = Enum.filter(Projects.list_assignments(p.uuid), &(&1.repeat_rule != nil))
      assert feb.deadline == ~U[2027-02-28 09:00:00Z]
      assert feb.repeat_rule["day"] == 31

      done!(feb)
      [mar] = Enum.filter(Projects.list_assignments(p.uuid), &(&1.repeat_rule != nil))
      assert mar.deadline == ~U[2027-03-31 09:00:00Z]

      done!(mar)
      [apr] = Enum.filter(Projects.list_assignments(p.uuid), &(&1.repeat_rule != nil))
      assert apr.deadline == ~U[2027-04-30 09:00:00Z]
    end

    test "a form saving the same rule without the day keeps it" do
      stored = %Assignment{repeat_rule: %{"every" => 1, "unit" => "month", "day" => 31}}
      cs = Assignment.changeset(stored, %{"repeat_rule" => %{"every" => 1, "unit" => "month"}})
      assert Ecto.Changeset.get_field(cs, :repeat_rule)["day"] == 31

      # a different rule is a new start
      cs = Assignment.changeset(stored, %{"repeat_rule" => %{"every" => 2, "unit" => "month"}})
      refute Map.has_key?(Ecto.Changeset.get_field(cs, :repeat_rule), "day")
    end

    test "a day only a month rule can carry, and only a real one" do
      assert Repeats.normalize(%{"every" => 1, "unit" => "week", "day" => 3}) ==
               %{"every" => 1, "unit" => "week"}

      assert Repeats.normalize(%{"every" => 1, "unit" => "month", "day" => 40}) ==
               %{"every" => 1, "unit" => "month"}

      assert Repeats.label(%{"every" => 1, "unit" => "month", "day" => 31}) == "Every month"
      assert Repeats.choice(%{"every" => 1, "unit" => "month", "day" => 31}) == "month"
    end
  end

  describe "a repeating subtask" do
    test "whose finish closed its parent comes back beside the parent, not inside it",
         %{project: p} do
      parent = task!(p, "Kitchen")

      weekly =
        task!(p, "Wipe the worktop", %{"repeat_rule" => %{"every" => 1, "unit" => "week"}},
          under: parent
        )

      later = task!(p, "Later")

      done!(weekly)

      # the auto-tick closed the parent, and the next occurrence leaves it closed
      assert Projects.get_assignment(parent.uuid).status == "done"

      [next] = Enum.filter(Projects.list_assignments(p.uuid), &(&1.repeat_rule != nil))
      assert next.status == "todo"
      assert next.parent_uuid == nil

      order =
        Projects.list_assignments(p.uuid)
        |> Enum.filter(&is_nil(&1.parent_uuid))
        |> Enum.sort_by(& &1.position)
        |> Enum.map(& &1.uuid)

      assert order == [parent.uuid, next.uuid, later.uuid]
    end

    test "under a parent still open stays under it", %{project: p} do
      parent = task!(p, "Kitchen")

      weekly =
        task!(p, "Wipe the worktop", %{"repeat_rule" => %{"every" => 1, "unit" => "week"}},
          under: parent
        )

      _open = task!(p, "Fit the doors", %{}, under: parent)

      done!(weekly)

      assert Projects.get_assignment(parent.uuid).status != "done"
      [next] = Enum.filter(Projects.list_assignments(p.uuid), &(&1.repeat_rule != nil))
      assert next.parent_uuid == parent.uuid
    end

    test "under two done levels goes under the first open one, after the done branch",
         %{project: p} do
      top = task!(p, "House")
      mid = task!(p, "Kitchen", %{}, under: top)
      _other = task!(p, "Hall", %{}, under: top)
      weekly = task!(p, "Wipe", %{"repeat_rule" => %{"every" => 1, "unit" => "week"}}, under: mid)

      done!(weekly)

      assert Projects.get_assignment(mid.uuid).status == "done"
      [next] = Enum.filter(Projects.list_assignments(p.uuid), &(&1.repeat_rule != nil))
      assert next.parent_uuid == top.uuid

      under_top =
        Projects.list_assignments(p.uuid)
        |> Enum.filter(&(&1.parent_uuid == top.uuid))
        |> Enum.sort_by(& &1.position)
        |> Enum.map(& &1.uuid)

      assert hd(under_top) == mid.uuid
      assert Enum.at(under_top, 1) == next.uuid
    end

    test "is announced once, after it exists — no reorder broadcast ahead of it",
         %{project: p} do
      parent = task!(p, "Kitchen")
      _open = task!(p, "Fit the doors", %{}, under: parent)

      weekly =
        task!(p, "Wipe", %{"repeat_rule" => %{"every" => 1, "unit" => "week"}}, under: parent)

      PhoenixKitProjects.PubSub.subscribe(PhoenixKitProjects.PubSub.topic_project(p.uuid))
      flush_projects_messages()

      done!(weekly)

      [next] = Enum.filter(Projects.list_assignments(p.uuid), &(&1.repeat_rule != nil))

      events =
        projects_events()
        |> Enum.filter(&(&1 in [:assignment_created, :assignment_reordered]))

      # The occurrence's own move inside its transaction used to broadcast a
      # reorder before the transaction (and the create) was through.
      assert events == [:assignment_created, :assignment_reordered]
      assert next.parent_uuid == parent.uuid
    end
  end

  defp flush_projects_messages do
    receive do
      {:projects, _, _} -> flush_projects_messages()
    after
      0 -> :ok
    end
  end

  defp projects_events do
    receive do
      {:projects, event, _} -> [event | projects_events()]
    after
      0 -> []
    end
  end
end
