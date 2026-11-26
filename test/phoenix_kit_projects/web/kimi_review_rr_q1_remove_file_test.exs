defmodule PhoenixKitProjects.Web.KimiReviewRrQ1RemoveFileTest do
  @moduledoc """
  Re-review probe (night 2026-11-26, Q1): a crafted `remove_task_file` in
  `:new` mode — the one `remove_task_file` branch that still writes at once
  outside `:edit` — must not write and must not crash the form.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Members

  test "remove_task_file in :new mode writes nothing and the form lives", %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "q1-file-#{System.unique_integer([:positive])}@example.com",
        "password" => "Q1Pass123!"
      })

    scope = fake_scope(user_uuid: user.uuid, permissions: ["projects"])
    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Members.add_member(project, user.uuid, role: "member")

    conn = put_test_scope(conn, scope)
    {:ok, lv, _html} = live(conn, "/en/admin/projects/#{project.uuid}/assignments/new")

    # Crafted: no file list renders in :new, so any uuid is foreign here.
    html = render_click(lv, "remove_task_file", %{"uuid" => Ecto.UUID.generate()})
    assert html =~ "Could not remove the file."

    # The form is still alive and usable.
    assert render(lv) =~ "assignment-form"
  end
end
