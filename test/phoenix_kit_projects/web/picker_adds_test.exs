defmodule PhoenixKitProjects.Web.PickerAddsTest do
  @moduledoc """
  The assignee picker adds, never replaces (the boss, 2026-11-03: "it
  shouldn't be switching out the currently assigned one. It should be
  adding"), in the project popup and the library task form as in the task
  popup; ✕ removes. The whole list is saved with Save (V30).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{AssigneeSet, Projects}
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitStaff.Schemas.Person

  defp person!(name) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{String.downcase(name)}-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    Repo.insert!(%Person{user_uuid: user.uuid, status: "active", name: name})
  end

  setup %{conn: conn} do
    conn = put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!()))
    {:ok, conn: conn, ann: person!("Ann"), bob: person!("Bob")}
  end

  test "the project popup adds a second assignee and saves both", ctx do
    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{project.uuid}/edit")

    render_click(view, "assignee_toggle", %{"kind" => "person", "uuid" => ctx.ann.uuid})
    html = render_click(view, "assignee_toggle", %{"kind" => "person", "uuid" => ctx.bob.uuid})

    assert html =~ ~s(value="person:#{ctx.ann.uuid}")
    assert html =~ ~s(value="person:#{ctx.bob.uuid}")

    view
    |> element("form[id^=project-form]")
    |> render_submit(%{"project" => %{"name" => project.name}})

    assert AssigneeSet.keys(Projects.get_project(project.uuid)) == [
             {"person", ctx.ann.uuid},
             {"person", ctx.bob.uuid}
           ]
  end

  test "✕ removes one and leaves the other", ctx do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "Hall #{System.unique_integer([:positive])}",
        "start_mode" => "immediate",
        "assignees" => [{"person", ctx.ann.uuid}, {"person", ctx.bob.uuid}]
      })

    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{project.uuid}/edit")
    html = render_click(view, "assignee_remove", %{"kind" => "person", "uuid" => ctx.ann.uuid})

    refute html =~ ~s(value="person:#{ctx.ann.uuid}")
    assert html =~ ~s(value="person:#{ctx.bob.uuid}")
  end

  test "the library task form adds defaults too", ctx do
    task = fixture_task()
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/tasks/#{task.uuid}/edit")

    render_click(view, "assignee_toggle", %{"kind" => "person", "uuid" => ctx.ann.uuid})
    html = render_click(view, "assignee_toggle", %{"kind" => "person", "uuid" => ctx.bob.uuid})

    assert html =~ ~s(value="person:#{ctx.ann.uuid}")
    assert html =~ ~s(value="person:#{ctx.bob.uuid}")
  end
end
