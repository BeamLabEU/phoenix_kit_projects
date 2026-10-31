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

  test "work under a task put on hold shows On hold too", ctx do
    walls = task!(ctx.project, "Walls", "in_progress")

    {:ok, _} =
      PhoenixKitProjects.Outline.move(Projects.get_assignment(walls.uuid), ctx.model.uuid, :last)

    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")
    html = render_click(view, "reopen", %{"uuid" => ctx.measure.uuid})

    # The model waits on the measurement; the walls, under the model, too.
    assert length(String.split(html, "On hold — waiting for")) - 1 == 2
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

  # The boss's second list, item 15: a line says what changed, from what
  # to what, and names the file; one visit's saves read as one line.
  test "an edit says what changed, from what to what; saves of one visit are one line", ctx do
    log = fn changes ->
      PhoenixKitProjects.Activity.log("projects.assignment_updated",
        actor_uuid: ctx.user_uuid,
        resource_type: "assignment",
        resource_uuid: ctx.model.uuid,
        tell: false,
        metadata: %{"changes" => changes}
      )
    end

    log.([
      %{"field" => "deadline", "from" => "2026-11-03T09:00:00Z", "to" => "2026-11-04T09:00:00Z"}
    ])

    log.([
      %{"field" => "deadline", "from" => "2026-11-04T09:00:00Z", "to" => "2026-11-05T09:00:00Z"},
      %{"field" => "priority", "from" => "normal", "to" => "urgent"}
    ])

    PhoenixKitProjects.Activity.log("projects.task_file_added",
      actor_uuid: ctx.user_uuid,
      resource_type: "assignment",
      resource_uuid: ctx.model.uuid,
      tell: false,
      metadata: %{"file_uuid" => Ecto.UUID.generate(), "file_name" => "measurements.pdf"}
    )

    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/history")
    html = view |> find_live_child("project-history-live-#{ctx.project.uuid}") |> render()

    assert html =~ "Deadline:"
    assert html =~ "Priority:"
    assert html =~ "Urgent"
    # One line for the two saves: the deadline from where it started.
    assert length(Regex.scan(~r/Deadline:/, html)) == 1
    assert html =~ "measurements.pdf"
  end

  test "Changes compares a task before and after a save" do
    was = %PhoenixKitProjects.Schemas.Assignment{
      priority: "normal",
      estimated_duration: 2,
      estimated_duration_unit: "hours"
    }

    now = %{was | priority: "high", estimated_duration: 3, deadline: ~U[2026-11-05 09:00:00Z]}

    changes =
      PhoenixKitProjects.Changes.assignment(was, now, title: {"Measure", "Measure the room"})

    fields = Map.new(changes, &{&1["field"], {&1["from"], &1["to"]}})

    assert fields["title"] == {"Measure", "Measure the room"}
    assert fields["priority"] == {"normal", "high"}
    assert fields["estimate"] == {"2 hours", "3 hours"}
    assert fields["deadline"] == {nil, "2026-11-05T09:00:00Z"}

    merged =
      PhoenixKitProjects.Changes.merge([
        [%{"field" => "priority", "from" => "normal", "to" => "high"}],
        [%{"field" => "priority", "from" => "high", "to" => "normal"}]
      ])

    assert merged == []
  end

  test "/history opens the tab", ctx do
    {:ok, view, html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/history")
    assert html =~ ~s(phx-value-tab="history")
    assert find_live_child(view, "project-history-live-#{ctx.project.uuid}")
  end
end
