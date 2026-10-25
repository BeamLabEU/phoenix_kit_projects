defmodule PhoenixKitProjects.Web.ProjectHistoryLiveTest do
  @moduledoc """
  The project page's History tab and the Reopen dialog, driven through the
  page: Reopen asks why, the reason lands on the reopen's row, the task that
  waits on it shows On hold, and History tells it as a sentence.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Activity.Entry
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Test.Repo

  setup %{conn: conn} do
    user_uuid = embed_user_uuid!()
    conn = put_test_scope(conn, fake_scope(user_uuid: user_uuid))
    project = fixture_project(%{"start_mode" => "immediate"})

    measure = task!(project, "Measure the room", "done")
    model = task!(project, "3D model", "in_progress")
    {:ok, _} = Projects.add_dependency(model.uuid, measure.uuid)

    {:ok, conn: conn, project: project, measure: measure, model: model, user_uuid: user_uuid}
  end

  defp task!(project, title, status) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        %{"status" => status}
      )

    a
  end

  test "Reopen asks why; the reason is on the row and the task after it is on hold", ctx do
    {:ok, view, html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")
    refute html =~ "On hold"

    html = render_click(view, "ask_reopen", %{"uuid" => ctx.measure.uuid})
    assert html =~ "What is wrong or missing?"

    html =
      view
      |> form("#reopen-form-#{ctx.project.uuid}", %{"reason" => "Wall B has no socket heights."})
      |> render_submit()

    assert html =~ "On hold — waiting for"
    refute html =~ "What is wrong or missing?"

    measure_uuid = ctx.measure.uuid

    assert [row] =
             Repo.all(
               from(e in Entry,
                 where:
                   e.action == "projects.assignment_reopened" and
                     e.resource_uuid == ^measure_uuid
               )
             )

    assert row.metadata["reason"] == "Wall B has no socket heights."
    assert row.actor_uuid == ctx.user_uuid
    assert row.permanent
  end

  test "a reopen without a reason still works (the typed list's tick)", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")
    render_click(view, "reopen", %{"uuid" => ctx.measure.uuid})
    assert Projects.get_assignment(ctx.measure.uuid).status == "todo"
  end

  test "reopening a task that is already to do changes and announces nothing", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")
    render_click(view, "reopen", %{"uuid" => ctx.measure.uuid})
    render_click(view, "reopen", %{"uuid" => ctx.measure.uuid, "reason" => "again"})

    measure_uuid = ctx.measure.uuid

    assert [_one] =
             Repo.all(
               from(e in Entry,
                 where:
                   e.action == "projects.assignment_reopened" and
                     e.resource_uuid == ^measure_uuid
               )
             )
  end

  test "a crafted reason that is not text is no reason", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")
    render_click(view, "reopen", %{"uuid" => ctx.measure.uuid, "reason" => %{"x" => "y"}})
    assert Projects.get_assignment(ctx.measure.uuid).status == "todo"
  end

  test "the History tab tells the project as sentences", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

    render_click(view, "ask_reopen", %{"uuid" => ctx.measure.uuid})

    view
    |> form("#reopen-form-#{ctx.project.uuid}", %{"reason" => "Measure wall A again."})
    |> render_submit()

    render_click(view, "switch_tab", %{"tab" => "history"})
    history = find_live_child(view, "project-history-live-#{ctx.project.uuid}")
    assert history

    html = render(history)
    assert html =~ "reopened"
    assert html =~ "Measure the room"
    assert html =~ "Measure wall A again."
  end

  test "/history opens the tab", ctx do
    {:ok, view, html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/history")
    assert html =~ ~s(phx-value-tab="history")
    assert find_live_child(view, "project-history-live-#{ctx.project.uuid}")
  end
end
