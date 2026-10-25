defmodule PhoenixKitProjects.Integration.AfterCommitTest do
  @moduledoc """
  `PubSub.after_commit/1`: a write made of several steps is one
  transaction, its broadcasts go out once it commits and never for a
  rollback; `Handoffs.discard/0` drops the people a rolled-back change
  would have told.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.{Handoffs, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub

  setup do
    project = fixture_project(%{"start_mode" => "immediate"})
    ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(project.uuid))
    %{project: project}
  end

  defp task!(project, title) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        %{}
      )

    flush()
    Projects.get_assignment(a.uuid)
  end

  defp flush do
    receive do
      {:projects, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  test "the broadcasts wait for the commit", ctx do
    a = task!(ctx.project, "Doors")

    {:ok, :done} =
      ProjectsPubSub.after_commit(fn ->
        {:ok, _} = Projects.update_assignment_form(a, %{"description" => "Oak"})
        refute_received {:projects, :assignment_updated, _}
        {:ok, :done}
      end)

    assert_received {:projects, :assignment_updated, %{uuid: uuid}}
    assert uuid == a.uuid
  end

  test "a rollback writes nothing and announces nothing", ctx do
    a = task!(ctx.project, "Doors")

    assert {:error, :later_step_failed} =
             ProjectsPubSub.after_commit(fn ->
               {:ok, _} = Projects.update_assignment_form(a, %{"description" => "Oak"})
               {:error, :later_step_failed}
             end)

    assert Projects.get_assignment(a.uuid).description in [nil, ""]
    refute_received {:projects, :assignment_updated, _}
  end

  test "an exception rolls back, drops the held broadcasts and leaves no buffer behind", ctx do
    a = task!(ctx.project, "Doors")

    assert_raise RuntimeError, fn ->
      ProjectsPubSub.after_commit(fn ->
        {:ok, _} = Projects.update_assignment_form(a, %{"description" => "Oak"})
        raise "boom"
      end)
    end

    refute_received {:projects, :assignment_updated, _}

    # Broadcasting works normally afterwards.
    {:ok, _} =
      Projects.update_assignment_form(Projects.get_assignment(a.uuid), %{"description" => "Ash"})

    assert_received {:projects, :assignment_updated, _}
  end

  test "a nested block joins the outer one", ctx do
    a = task!(ctx.project, "Doors")

    {:ok, _} =
      ProjectsPubSub.after_commit(fn ->
        {:ok, _} =
          ProjectsPubSub.after_commit(fn ->
            Projects.update_assignment_form(a, %{"description" => "Oak"})
          end)

        refute_received {:projects, :assignment_updated, _}
        {:ok, :outer}
      end)

    assert_received {:projects, :assignment_updated, _}
  end

  test "a discarded batch tells nobody", ctx do
    measure = task!(ctx.project, "Measure")
    model = task!(ctx.project, "Model")
    {:ok, _} = Projects.add_dependency(model.uuid, measure.uuid)

    Handoffs.batch(fn ->
      {:ok, _} =
        Projects.update_assignment_status(measure, %{status: "done", progress_pct: 100})

      Handoffs.discard()
    end)

    refute_received {:projects, :history_changed, _}
  end
end
