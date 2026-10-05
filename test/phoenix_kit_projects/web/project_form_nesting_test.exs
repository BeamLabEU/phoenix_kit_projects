defmodule PhoenixKitProjects.Web.ProjectFormNestingTest do
  @moduledoc """
  The embedded Modules & Features panel must render OUTSIDE the project
  edit form: a form inside a form is flattened by the browser, and its
  submit buttons post the outer one — "Create key" navigated away with
  nothing created (Max, 2026-10-05).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Extensions.Registry

  setup %{conn: conn} do
    Registry.refresh()
    {:ok, conn: put_test_scope(conn, fake_scope()), project: fixture_project()}
  end

  test "the modules panel and its forms sit after the project form and its Save row", %{
    conn: conn,
    project: project
  } do
    {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/edit")

    form_open = :binary.match(html, ~s(id="project-form")) |> elem(0)

    {form_close, _} =
      :binary.match(html, "</form>", scope: {form_open, byte_size(html) - form_open})

    {panel, _} = :binary.match(html, ~s(id="edit-modules-#{project.uuid}"))

    assert panel > form_close
    # no form of the panel's is nested in the project form
    inside = binary_part(html, form_open, form_close - form_open)
    refute inside =~ "<form"
    # Save belongs to the fields: inside the form, before the panel; nothing after it
    {save, _} = :binary.match(inside, "Saving…")
    assert save > 0
    refute binary_part(html, panel, byte_size(html) - panel) =~ "Saving…"
  end

  test "embedded in the form, the panel says its changes apply at once", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _} =
      live_isolated(conn, PhoenixKitProjects.Web.ProjectModulesLive,
        session: %{
          "id" => project.uuid,
          "embedded_in_form" => true,
          "current_user_uuid" => embed_user_uuid!()
        }
      )

    html = render(view)
    assert html =~ "Changes here apply at once"
    refute html =~ "Saving…"
  end
end
