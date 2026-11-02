defmodule PhoenixKitProjects.Web.FormsOwnDialogTest do
  @moduledoc """
  The library task and template forms close through the module's own
  dialog once something is unsaved — never the browser's box (the boss,
  2026-11-02).
  """

  use PhoenixKitProjects.LiveCase, async: false

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!()))}
  end

  test "the library task form asks in its own dialog, then closes", %{conn: conn} do
    task = fixture_task()
    {:ok, view, _html} = live(conn, "/en/admin/projects/tasks/#{task.uuid}/edit")

    html =
      view
      |> element("#task-form")
      |> render_change(%{"task" => %{"title" => "Changed"}})

    refute html =~ "data-confirm"
    assert html =~ ~s(phx-value-event="cancel")

    html =
      render_click(view, "request_confirm", %{
        "event" => "cancel",
        "title" => "Discard your changes?"
      })

    assert html =~ "Discard your changes?"
  end

  test "the template form asks in its own dialog", %{conn: conn} do
    template = fixture_project(%{"is_template" => true})
    {:ok, view, _html} = live(conn, "/en/admin/projects/templates/#{template.uuid}/edit")

    html =
      view
      |> element("#template-form")
      |> render_change(%{"project" => %{"name" => "Changed"}})

    refute html =~ "data-confirm"
    assert html =~ ~s(phx-value-event="cancel")
  end
end
