defmodule PhoenixKitProjects.Web.RefTextLiveTest do
  @moduledoc """
  Short refs in the task form: the edit box shows `#KEY-1` for a stored
  token, a `#` pick inserts the short ref, and a save stores the token.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Schemas.Assignment
  alias PhoenixKitProjects.Web.Mentions

  setup %{conn: conn} do
    # Fixtures are written by trusted code (`RefText`, "Who is writing").
    PhoenixKitProjects.RefText.put_writer(:all)
    project = fixture_project()

    task = fn attrs ->
      {:ok, a} =
        Projects.create_assignment(
          Map.merge(%{"project_uuid" => project.uuid, "task_uuid" => fixture_task().uuid}, attrs)
        )

      Projects.get_assignment(a.uuid)
    end

    target = task.(%{})
    ref = Assignment.ref(target)
    editing = task.(%{"description" => "Blocked by ##{ref}."})

    conn = put_test_scope(conn, fake_scope())
    {:ok, conn: conn, project: project, target: target, ref: ref, editing: editing}
  end

  test "the edit box shows the short ref, and a save keeps the link", ctx do
    token = "#[project_task:#{ctx.target.uuid}|#{ctx.ref}]"
    assert ctx.editing.description == "Blocked by #{token}."

    {:ok, view, html} =
      live(
        ctx.conn,
        "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.editing.uuid}/edit"
      )

    assert html =~ "Blocked by ##{ctx.ref}."
    refute html =~ "project_task:#{ctx.target.uuid}"

    # Typing does not turn the ref into a token under the cursor.
    html =
      view
      |> form("#assignment-form", assignment: %{})
      |> render_change(%{"assignment" => %{"description" => "Now after ##{ctx.ref}!"}})

    assert html =~ "Now after ##{ctx.ref}!"
    refute html =~ "project_task:#{ctx.target.uuid}"

    view
    |> form("#assignment-form", assignment: %{})
    |> render_submit(%{"assignment" => %{"description" => "Now after ##{ctx.ref}!"}})

    assert Projects.get_assignment(ctx.editing.uuid).description == "Now after #{token}!"
  end

  test "picking a task or a project from the # list inserts its short ref", ctx do
    # The rows as core's search reply carries them (`Mentions.Live.search_reply/2`).
    row = fn kind, type, uuid ->
      %{kind: kind, type: type, uuid: uuid, title: "T", subtitle: nil, token: "long"}
    end

    person = row.("user", "user", Ecto.UUID.generate())
    meeting = row.("resource", "crm_interaction", Ecto.UUID.generate())
    gone = row.("resource", "project_task", Ecto.UUID.generate())

    assert [task, project, ^person, ^meeting, ^gone] =
             Mentions.shorten_results([
               row.("resource", "project_task", ctx.target.uuid),
               row.("resource", "project", ctx.project.uuid),
               person,
               meeting,
               gone
             ])

    assert task.token == "##{ctx.ref}"
    assert project.token == "##{ctx.project.key}"
  end

  test "a one-off task's own description shows in the edit box and is saved back to the task",
       ctx do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        ctx.project.uuid,
        %{"title" => "One-off", "description" => "See ##{ctx.ref} first.", "ad_hoc" => true},
        %{}
      )

    token = "#[project_task:#{ctx.target.uuid}|#{ctx.ref}]"
    a = Projects.get_assignment(a.uuid)
    assert a.description == nil
    assert a.task.description == "See #{token} first."

    path = "/en/admin/projects/#{ctx.project.uuid}/assignments/#{a.uuid}/edit"
    {:ok, view, html} = live(ctx.conn, path)
    assert html =~ "See ##{ctx.ref} first."

    # Untouched, a save changes neither row.
    view |> form("#assignment-form", assignment: %{}) |> render_submit()
    a = Projects.get_assignment(a.uuid)
    assert a.description == nil
    assert a.task.description == "See #{token} first."

    # A box left untouched does not put its text over a newer one.
    {:ok, view, _html} = live(ctx.conn, path)
    {:ok, _} = Projects.update_task(a.task, %{"description" => "Reworded over the API."})
    view |> form("#assignment-form", assignment: %{priority: "high"}) |> render_submit()
    assert Projects.get_assignment(a.uuid).task.description == "Reworded over the API."

    {:ok, view, _html} = live(ctx.conn, path)

    view
    |> form("#assignment-form", assignment: %{})
    |> render_submit(%{"assignment" => %{"description" => "After ##{ctx.ref}."}})

    a = Projects.get_assignment(a.uuid)
    assert a.description == nil
    assert a.task.description == "After #{token}."
  end
end
