defmodule PhoenixKitProjects.Web.ProjectPopupFilesTest do
  @moduledoc """
  The project popup holds the project's files (item 47, the boss,
  2026-11-03: "in the project edit pop-up, I'm not seeing an image or file
  attachment … We should have that"): the Files tab's files with
  thumbnails, a drop zone, ✕ asked first; and the description's picture
  button on the toolbar's row, not in its ⋯ menu — in the task popup too.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.{Attachments, Extensions, Projects}
  alias PhoenixKitProjects.Web.Components.DescriptionEditor

  setup %{conn: conn} do
    me = embed_user_uuid!()
    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: me)), me: me, project: project}
  end

  defp tmp(bytes) do
    path = Path.join(System.tmp_dir!(), "pkp-test-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp names(project, me),
    do: project |> Attachments.list_files(me) |> Enum.map(& &1.original_file_name)

  test "the popup lists the project's files, offers the drop zone, and removes one asked first",
       ctx do
    for name <- ~w(brief.txt plan.txt) do
      {:ok, _} =
        Attachments.store_project_file(
          ctx.project,
          tmp("#{name} #{System.unique_integer()}"),
          [filename: name, content_type: "text/plain", size_bytes: 8],
          ctx.me
        )
    end

    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/edit")

    assert has_element?(view, "#project-pane-project #project-files", "brief.txt")
    assert has_element?(view, "#project-files", "plan.txt")

    # the drop zone's input, owned by a form of its own (not the project's)
    assert has_element?(
             view,
             "#project-files input[type=file][name=project_files][form=project-files-form]"
           )

    assert has_element?(view, "form#project-files-form")

    [plan] =
      Enum.filter(
        Attachments.list_files(ctx.project, ctx.me),
        &(&1.original_file_name == "plan.txt")
      )

    view
    |> element("#project-file-list-#{plan.uuid} button[aria-label='Remove file']")
    |> render_click()

    # asked first: nothing gone yet
    assert "plan.txt" in names(ctx.project, ctx.me)

    render_click(view, "confirm_action_ok", %{})
    refute "plan.txt" in names(ctx.project, ctx.me)
    assert "brief.txt" in names(ctx.project, ctx.me)
    refute has_element?(view, "#project-files", "plan.txt")
  end

  test "no Files area while the project's Files are turned off", ctx do
    {:ok, _} = Extensions.disable(ctx.project, "files")
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/edit")
    refute has_element?(view, "#project-files")
  end

  test "the picture button sits on the toolbar's row and opens the chooser", ctx do
    {:ok, view, html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/edit")

    assert html =~ ~s(data-host-action="#{DescriptionEditor.image_action()}")
    assert html =~ "data-toolbar-extra-pinned"

    [id] =
      Regex.run(~r/data-description-editor="(project-description--[^"]+)"/, html,
        capture: :all_but_first
      )

    send(view.pid, {:leaf_toolbar_action, %{editor_id: id, id: DescriptionEditor.image_action()}})
    assert_push_event(view, "pkp:pick-file", %{id: _})
  end

  test "the task popup's picture button is on the row too", ctx do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        ctx.project.uuid,
        %{"title" => "Measure the window", "ad_hoc" => true},
        %{}
      )

    {:ok, view, html} =
      live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{a.uuid}/edit")

    assert html =~ ~s(data-host-action="#{DescriptionEditor.image_action()}")

    [id] =
      Regex.run(~r/data-description-editor="(assignment-description--[^"]+)"/, html,
        capture: :all_but_first
      )

    send(view.pid, {:leaf_toolbar_action, %{editor_id: id, id: DescriptionEditor.image_action()}})
    assert_push_event(view, "pkp:pick-file", %{id: _})
  end
end
