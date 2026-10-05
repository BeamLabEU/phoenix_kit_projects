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

  test "the modules panel and its forms sit after the project form; Save still names it", %{
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
    # the Save button outside the form still submits it
    assert html =~ ~s(form="project-form")
  end
end
