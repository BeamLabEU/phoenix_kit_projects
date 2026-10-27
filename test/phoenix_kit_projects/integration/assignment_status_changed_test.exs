defmodule PhoenixKitProjects.Integration.AssignmentStatusChangedTest do
  @moduledoc """
  `{:projects, :assignment_status_changed, %{uuid, project_uuid, from, to}}`
  fires from every path that changes an assignment's status — and only then.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.{Outline, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub

  defp project, do: fixture_project(%{"name" => "Status #{System.unique_integer([:positive])}"})

  defp task(project, title, parent_uuid \\ nil) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        %{}
      )

    if parent_uuid do
      {:ok, moved} = Outline.move(a, parent_uuid)
      Projects.get_assignment(moved.uuid)
    else
      a
    end
  end

  defp subscribe(p), do: ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(p.uuid))

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  describe "update_assignment_status/2" do
    test "fires with from and to, on both topics" do
      p = project()
      a = task(p, "One")
      ProjectsPubSub.subscribe(ProjectsPubSub.topic_all())
      subscribe(p)
      flush()

      {:ok, _} = Projects.update_assignment_status(a, %{status: "in_progress"})

      expected = %{uuid: a.uuid, project_uuid: p.uuid, from: "waiting", to: "in_progress"}
      assert_receive {:projects, :assignment_status_changed, ^expected}, 500
      assert_receive {:projects, :assignment_status_changed, ^expected}, 500
      assert_receive {:projects, :assignment_updated, %{uuid: uuid}}, 500
      assert uuid == a.uuid
    end

    test "does not fire when the status stays" do
      p = project()
      a = task(p, "One")
      subscribe(p)
      flush()

      {:ok, _} = Projects.update_assignment_status(a, %{progress_pct: 30})

      assert_receive {:projects, :assignment_updated, _}, 500
      refute_receive {:projects, :assignment_status_changed, _}, 100
    end
  end

  describe "update_assignment_form/3" do
    test "fires when the form changes the status" do
      p = project()
      a = task(p, "One")
      subscribe(p)
      flush()

      {:ok, _} = Projects.update_assignment_form(a, %{"status" => "in_progress"})

      expected = %{uuid: a.uuid, project_uuid: p.uuid, from: "waiting", to: "in_progress"}
      assert_receive {:projects, :assignment_status_changed, ^expected}, 500
    end

    test "does not fire when the form leaves the status alone" do
      p = project()
      a = task(p, "One")
      subscribe(p)
      flush()

      {:ok, _} = Projects.update_assignment_form(a, %{"description" => "words"})

      refute_receive {:projects, :assignment_status_changed, _}, 100
    end
  end

  describe "Outline.settle cascade" do
    test "ticking a parent announces every child it ticks" do
      p = project()
      parent = task(p, "Parent")
      c1 = task(p, "Child 1", parent.uuid)
      c2 = task(p, "Child 2", parent.uuid)
      subscribe(p)
      flush()

      {:ok, _} = Projects.update_assignment_status(parent, %{status: "done"})

      parent_uuid = parent.uuid

      assert_receive {:projects, :assignment_status_changed,
                      %{uuid: ^parent_uuid, from: "waiting", to: "done"}},
                     500

      got =
        for _ <- 1..2 do
          assert_receive {:projects, :assignment_status_changed,
                          %{uuid: u, from: "waiting", to: "done", project_uuid: pu}},
                         500

          assert pu == p.uuid
          u
        end

      assert Enum.sort(got) == Enum.sort([c1.uuid, c2.uuid])
    end

    test "the last subtask ticked announces its parent" do
      p = project()
      parent = task(p, "Parent")
      c1 = task(p, "Child 1", parent.uuid)
      c2 = task(p, "Child 2", parent.uuid)
      {:ok, _} = Projects.update_assignment_status(c1, %{status: "done"})
      subscribe(p)
      flush()

      {:ok, _} =
        Projects.update_assignment_status(Projects.get_assignment(c2.uuid), %{status: "done"})

      parent_uuid = parent.uuid

      assert_receive {:projects, :assignment_status_changed,
                      %{uuid: ^parent_uuid, from: "waiting", to: "done"}},
                     500
    end

    test "reopening a child reopens the done parent, with the old status" do
      p = project()
      parent = task(p, "Parent")
      c1 = task(p, "Child 1", parent.uuid)
      {:ok, _} = Projects.update_assignment_status(parent, %{status: "done"})
      done_child = Projects.get_assignment(c1.uuid)
      assert done_child.status == "done"
      subscribe(p)
      flush()

      {:ok, _} = Projects.update_assignment_status(done_child, %{status: "in_progress"})

      parent_uuid = parent.uuid

      assert_receive {:projects, :assignment_status_changed,
                      %{uuid: ^parent_uuid, from: "done", to: "in_progress"}},
                     500
    end
  end

  describe "other paths" do
    test "a template clone announces nothing (rows are born todo)" do
      template = fixture_template()

      {:ok, _} =
        Projects.create_assignment(%{
          "project_uuid" => template.uuid,
          "task_uuid" => fixture_task().uuid
        })

      ProjectsPubSub.subscribe(ProjectsPubSub.topic_all())
      flush()

      {:ok, _} =
        Projects.create_project_from_template(template.uuid, %{
          "name" => "Clone #{System.unique_integer([:positive])}"
        })

      refute_receive {:projects, :assignment_status_changed, _}, 100
    end

    test "a sub-project's rollup status change is announced on the parent" do
      parent = project()

      {:ok, %{child_project: child, assignment: link}} =
        Projects.create_subproject(parent.uuid, %{"name" => "Kid"})

      t = fixture_task()

      {:ok, a} =
        Projects.create_assignment(%{"project_uuid" => child.uuid, "task_uuid" => t.uuid})

      subscribe(parent)
      flush()

      {:ok, _} = Projects.update_assignment_status(a, %{status: "in_progress"})
      Projects.recompute_project_completion(child.uuid)

      link_uuid = link.uuid
      parent_uuid = parent.uuid

      assert_receive {:projects, :assignment_status_changed,
                      %{uuid: ^link_uuid, project_uuid: ^parent_uuid, to: "in_progress"}},
                     500
    end
  end

  describe "the buffer and the lock" do
    alias PhoenixKitProjects.Schemas.Assignment
    alias PhoenixKitProjects.Test.Repo

    @key :projects_outline_status_events

    # A done parent over an open child: the shape `settle_tree/2` repairs by
    # reopening the parent.
    defp done_over_open(p) do
      parent = task(p, "Parent")
      child = task(p, "Child", parent.uuid)
      import Ecto.Query
      Repo.update_all(from(x in Assignment, where: x.uuid == ^parent.uuid), set: [status: "done"])
      {parent, child}
    end

    test "a rolled-back lock announces nothing and leaves no key" do
      p = project()
      {parent, _child} = done_over_open(p)
      subscribe(p)
      flush()

      assert {:error, :boom} =
               Outline.with_project_lock(p.uuid, fn _ ->
                 assert [_] = Outline.settle_tree(p.uuid)
                 Repo.rollback(:boom)
               end)

      refute_receive {:projects, :assignment_status_changed, _}, 100
      assert Process.get(@key) == nil
      assert Projects.get_assignment(parent.uuid).status == "done"
    end

    test "an exception inside the lock announces nothing and leaves no key" do
      p = project()
      done_over_open(p)
      subscribe(p)
      flush()

      assert_raise RuntimeError, "kaboom", fn ->
        Outline.with_project_lock(p.uuid, fn _ ->
          Outline.settle_tree(p.uuid)
          raise "kaboom"
        end)
      end

      refute_receive {:projects, :assignment_status_changed, _}, 100
      assert Process.get(@key) == nil
    end

    test "a nested lock announces once, after the outer one commits" do
      p = project()
      {parent, _child} = done_over_open(p)
      subscribe(p)
      flush()

      assert {:ok, _} =
               Outline.with_project_lock(p.uuid, fn _ ->
                 {:ok, _} =
                   Outline.with_project_lock(p.uuid, fn _ -> Outline.settle_tree(p.uuid) end)

                 refute_received {:projects, :assignment_status_changed, _}
               end)

      parent_uuid = parent.uuid

      assert_receive {:projects, :assignment_status_changed,
                      %{uuid: ^parent_uuid, from: "done", to: "in_progress"}},
                     500

      refute_receive {:projects, :assignment_status_changed, _}, 100
      assert Process.get(@key) == nil
    end

    test "settle_tree outside a lock announces at once and cannot mute a later lock" do
      p = project()
      {parent, _child} = done_over_open(p)
      subscribe(p)
      flush()

      assert [_] = Outline.settle_tree(p.uuid)
      assert Process.get(@key) == nil
      parent_uuid = parent.uuid
      assert_receive {:projects, :assignment_status_changed, %{uuid: ^parent_uuid}}, 500

      q = project()
      top = task(q, "Top")
      kid = task(q, "Kid", top.uuid)
      subscribe(q)
      flush()

      {:ok, _} = Projects.update_assignment_status(top, %{status: "done"})
      kid_uuid = kid.uuid
      assert_receive {:projects, :assignment_status_changed, %{uuid: ^kid_uuid, to: "done"}}, 500
    end

    test "Outline.move into a done parent reopens it, and says so" do
      p = project()
      parent = task(p, "Parent")
      import Ecto.Query
      Repo.update_all(from(x in Assignment, where: x.uuid == ^parent.uuid), set: [status: "done"])
      mover = task(p, "Mover")
      subscribe(p)
      flush()

      assert {:ok, _} = Outline.move(mover, parent.uuid)

      parent_uuid = parent.uuid

      assert_receive {:projects, :assignment_status_changed,
                      %{uuid: ^parent_uuid, from: "done", to: "in_progress"}},
                     500
    end

    test "broadcast: false silences the form row's own events, not the cascade rows" do
      p = project()
      parent = task(p, "Parent")
      child = task(p, "Child", parent.uuid)
      subscribe(p)
      flush()

      {:ok, _} = Projects.update_assignment_form(parent, %{"status" => "done"}, broadcast: false)

      child_uuid = child.uuid
      parent_uuid = parent.uuid

      assert_receive {:projects, :assignment_status_changed, %{uuid: ^child_uuid, to: "done"}},
                     500

      refute_receive {:projects, :assignment_status_changed, %{uuid: ^parent_uuid}}, 100
      refute_receive {:projects, :assignment_updated, _}, 100
    end

    test "a stale struct does not make up a transition" do
      p = project()
      a = task(p, "One")
      import Ecto.Query

      Repo.update_all(from(x in Assignment, where: x.uuid == ^a.uuid),
        set: [status: "in_progress"]
      )

      subscribe(p)
      flush()

      # `a` still says "todo"; the row is already in progress.
      {:ok, _} = Projects.update_assignment_status(a, %{status: "in_progress"})
      refute_receive {:projects, :assignment_status_changed, _}, 100

      {:ok, _} = Projects.update_assignment_form(a, %{"status" => "done"})
      a_uuid = a.uuid

      assert_receive {:projects, :assignment_status_changed,
                      %{uuid: ^a_uuid, from: "in_progress", to: "done"}},
                     500
    end
  end
end
