defmodule PhoenixKitProjects.Web.NextUpDoneTest do
  @moduledoc """
  The boss's list of 2026-11-18, the Done dialog:

    * 17 — Done always asks: a comment, who to tell (the task's creator to
      start with), and what it lets start — from the menu, a list tick, a
      status change;
    * 18 — the people picker is the list of who is told; someone added is
      assigned to the task and told;
    * 14 — the comment is kept on the task and quoted in the notice;
    * 11 — Cancel closes the dialog on the first press, even after the page
      reloaded under it.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{AssigneeSet, People, Projects}
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitProjects.Web.ProjectShowLive
  alias PhoenixKitStaff.Schemas.Person
  alias PhoenixKitWeb.Components.PeoplePicker

  setup %{conn: conn} do
    actor = user!("actor")
    conn = put_test_scope(conn, fake_scope(user_uuid: actor.uuid))

    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(project)
    project = Projects.get_project!(project.uuid)

    creator = user!("creator")
    Repo.insert!(%Person{user_uuid: creator.uuid, status: "active", name: "Cora Creator"})
    {:ok, _} = PhoenixKitProjects.Members.add_member(project, creator.uuid, role: "member")

    {:ok, %{assignment: task}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Paint the hall", "ad_hoc" => true},
        %{"status" => "todo"}
      )

    Projects.stamp_assignment(task, %{created_by_uuid: creator.uuid})
    task = Projects.get_assignment(task.uuid)

    {:ok, conn: conn, project: project, task: task, actor: actor, creator: creator}
  end

  defp user!(name) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{name}-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp show(ctx), do: live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")
  defp dialog(ctx), do: "#project-next-up-#{ctx.project.uuid}"
  defp status(a), do: Projects.get_assignment(a.uuid).status
  defp done_picker(ctx), do: ProjectShowLive.done_picker_id(ctx.task.uuid)

  defp notices(action, user_uuid) do
    Repo.all(
      from(e in PhoenixKit.Activity.Entry,
        where: e.action == ^action and e.target_uuid == ^user_uuid
      )
    )
  end

  test "Done asks even when nothing waits on the task; the creator is there to tell", ctx do
    {:ok, view, _html} = show(ctx)

    render_click(view, "complete", %{"uuid" => ctx.task.uuid})

    assert has_element?(view, dialog(ctx), "done?")
    assert has_element?(view, dialog(ctx), "Cora Creator")
    assert render(view) =~ "Created this task"
    assert status(ctx.task) == "todo"
  end

  test "confirm completes, keeps the comment and tells the creator with it quoted", ctx do
    :ok = PhoenixKitProjects.DataCase.with_comments_module()
    {:ok, view, _html} = show(ctx)

    render_click(view, "complete", %{"uuid" => ctx.task.uuid})

    render_submit(view, "next_up_confirm", %{
      "uuid" => ctx.task.uuid,
      "done_note" => "Two coats, the hall is dry by Friday."
    })

    assert status(ctx.task) == "done"
    assert [comment] = PhoenixKitComments.list_comments("assignment", ctx.task.uuid)
    assert comment.content == "Two coats, the hall is dry by Friday."

    assert [notice] = notices("projects.assignment_completed", ctx.creator.uuid)

    assert notice.metadata["quote"]["text"] == "Two coats, the hall is dry by Friday." or
             notice.metadata["notification_text"] =~ "Two coats"
  end

  test "someone added to who is told is assigned to the task and told", ctx do
    helper = user!("helper")
    person = Repo.insert!(%Person{user_uuid: helper.uuid, status: "active", name: "Hal Helper"})
    creator_key = {"person", People.get_person_by_user_uuid(ctx.creator.uuid).uuid}

    {:ok, view, _html} = show(ctx)
    render_click(view, "complete", %{"uuid" => ctx.task.uuid})

    send(
      view.pid,
      {PeoplePicker, done_picker(ctx), {:changed, [creator_key, {"person", person.uuid}]}}
    )

    assert render(view) =~ "Added here"

    render_submit(view, "next_up_confirm", %{"uuid" => ctx.task.uuid})

    assert status(ctx.task) == "done"
    assert {"person", person.uuid} in AssigneeSet.keys(Projects.get_assignment(ctx.task.uuid))
    # not on the project before: made a member, so the notice reaches him
    assert PhoenixKitProjects.Members.get_member(ctx.project.uuid, helper.uuid)
    assert [_] = notices("projects.assignment_completed", helper.uuid)
  end

  test "an account with no staff record, added, becomes a person and is assigned", ctx do
    newcomer = user!("newcomer")
    creator_key = {"person", People.get_person_by_user_uuid(ctx.creator.uuid).uuid}

    {:ok, view, _html} = show(ctx)
    render_click(view, "complete", %{"uuid" => ctx.task.uuid})

    send(
      view.pid,
      {PeoplePicker, done_picker(ctx), {:changed, [creator_key, {"user", newcomer.uuid}]}}
    )

    _ = render(view)
    person = People.get_person_by_user_uuid(newcomer.uuid)
    assert person

    render_submit(view, "next_up_confirm", %{"uuid" => ctx.task.uuid})

    assert status(ctx.task) == "done"
    assert {"person", person.uuid} in AssigneeSet.keys(Projects.get_assignment(ctx.task.uuid))
    assert [_] = notices("projects.assignment_completed", newcomer.uuid)
  end

  test "a creator taken off the list is not told", ctx do
    {:ok, view, _html} = show(ctx)
    render_click(view, "complete", %{"uuid" => ctx.task.uuid})

    send(view.pid, {PeoplePicker, done_picker(ctx), {:changed, []}})
    _ = render(view)

    render_submit(view, "next_up_confirm", %{"uuid" => ctx.task.uuid})
    assert status(ctx.task) == "done"
    assert notices("projects.assignment_completed", ctx.creator.uuid) == []
  end

  test "a list tick and a status change open the dialog instead of finishing", ctx do
    {:ok, view, _html} = show(ctx)

    render_hook(view, "outline_tick", %{"id" => ctx.task.uuid, "done" => true})
    assert_reply(view, %{asked: true})

    assert has_element?(view, dialog(ctx))
    assert status(ctx.task) == "todo"

    render_click(view, "next_up_close", %{})
    refute has_element?(view, dialog(ctx))

    render_click(view, "set_status", %{
      "uuid" => ctx.task.uuid,
      "status" => "done",
      "from" => "todo"
    })

    assert has_element?(view, dialog(ctx))
    assert status(ctx.task) == "todo"
  end

  test "Cancel closes the dialog on the first press, even after a reload under it", ctx do
    {:ok, view, _html} = show(ctx)
    render_click(view, "complete", %{"uuid" => ctx.task.uuid})
    assert has_element?(view, dialog(ctx))

    # The page reloads on every broadcast while the dialog is open.
    send(
      view.pid,
      {:projects, :assignment_updated, %{uuid: ctx.task.uuid, project_uuid: ctx.project.uuid}}
    )

    _ = render(view)
    assert has_element?(view, dialog(ctx))

    render_click(view, "next_up_close", %{})
    refute has_element?(view, dialog(ctx))

    # …and stays closed through the next reload.
    send(
      view.pid,
      {:projects, :assignment_updated, %{uuid: ctx.task.uuid, project_uuid: ctx.project.uuid}}
    )

    refute has_element?(view, dialog(ctx))
    assert status(ctx.task) == "todo"
  end
end
