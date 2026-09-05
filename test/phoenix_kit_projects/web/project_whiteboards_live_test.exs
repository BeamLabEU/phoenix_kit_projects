defmodule PhoenixKitProjects.Web.ProjectWhiteboardsLiveTest do
  @moduledoc """
  The whiteboards extension TAB: mounted the way the hub mounts it —
  off-router with the extension-tab session contract (`live_isolated`) —
  plus the show-page integration (tab appears only when the extension is
  enabled).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Extensions, Whiteboards}
  alias PhoenixKitProjects.Web.ProjectWhiteboardsLive

  setup %{conn: conn} do
    PhoenixKitProjects.Extensions.Registry.refresh()

    {:ok, user} =
      Auth.register_user(%{
        email: "wb-lv-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))
    {:ok, conn: conn, project: fixture_project(), user: user}
  end

  defp mount_tab(conn, project, user) do
    live_isolated(conn, ProjectWhiteboardsLive,
      session: %{
        "project_uuid" => project.uuid,
        "ext_key" => "whiteboards",
        "instance_key" => "default",
        "config" => %{},
        "current_user_uuid" => user && user.uuid,
        "can_write" => true,
        "locale" => "en"
      }
    )
  end

  defp mount_tab_readonly(conn, project, user) do
    live_isolated(conn, ProjectWhiteboardsLive,
      session: %{
        "project_uuid" => project.uuid,
        "ext_key" => "whiteboards",
        "instance_key" => "default",
        "config" => %{},
        "current_user_uuid" => user && user.uuid,
        "can_write" => false,
        "locale" => "en"
      }
    )
  end

  defp fixture_file(user) do
    {:ok, file} =
      %Storage.File{}
      |> Ecto.Changeset.change(%{
        user_uuid: user.uuid,
        original_file_name: "board.png",
        file_name: "board.png",
        file_path: "/tmp/board.png",
        ext: ".png",
        file_type: "image",
        mime_type: "image/png",
        file_checksum: "wblv-#{System.unique_integer([:positive])}",
        user_file_checksum: "wblv-u-#{System.unique_integer([:positive])}",
        size: 99,
        width: 1920,
        height: 1080,
        status: "active"
      })
      |> PhoenixKit.RepoHelper.repo().insert()

    file
  end

  describe "show-page integration" do
    test "the tab appears only when the whiteboards extension is enabled",
         %{conn: conn, project: project} do
      path = "/en/admin/projects/#{project.uuid}"

      {:ok, _view, html} = live(conn, path)
      refute html =~ "Whiteboards"

      {:ok, _} = Extensions.enable(project, "whiteboards")
      {:ok, _view, html} = live(conn, path)
      assert html =~ "Whiteboards"
    end
  end

  describe "the tab LV" do
    test "renders the empty state and the create modal", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, view, html} = mount_tab(conn, project, user)

      assert html =~ "No whiteboards yet."

      html = render_click(view, "open_new_board", %{})
      assert html =~ "New whiteboard"
      assert html =~ "1920 × 1080"
    end

    test "boards list renders and opens into the canvas branch",
         %{conn: conn, project: project, user: user} do
      file = fixture_file(user)

      {:ok, _instance} =
        Storage.create_file_instance(%{
          variant_name: "original",
          file_name: file.file_name,
          mime_type: "image/png",
          ext: ".png",
          checksum: "chk",
          size: 99,
          processing_status: "completed",
          file_uuid: file.uuid
        })

      {:ok, board} =
        Whiteboards.create_board_for_file(project, file.uuid, %{
          name: "Sprint sketches",
          width: 1920,
          height: 1080
        })

      {:ok, view, html} = mount_tab(conn, project, user)
      assert html =~ "Sprint sketches"
      assert html =~ "1920 × 1080"

      html = render_click(view, "open_board", %{"uuid" => board.uuid})
      assert html =~ "All whiteboards"
      # The MediaCanvasViewer component mounted over the background file.
      assert html =~ "project-whiteboard-canvas-#{file.uuid}"
    end

    test "create through the modal creates the board and opens its canvas",
         %{conn: conn, project: project, user: user} do
      {:ok, view, _} = mount_tab(conn, project, user)

      render_click(view, "open_new_board", %{})

      html =
        render_submit(view, "create_board", %{"name" => "Fresh board", "size" => "1920x1080"})

      assert [board] = Whiteboards.list_for_project(project.uuid)
      assert board.name == "Fresh board"
      # Auto-selected into the canvas branch with the LC mounted.
      assert html =~ "All whiteboards"
      assert html =~ "project-whiteboard-canvas-#{board.file_uuid}"
    end

    test "create without a session user is refused", %{conn: conn, project: project} do
      {:ok, view, _} = mount_tab(conn, project, nil)

      html = render_submit(view, "create_board", %{"name" => "Board", "size" => "1920x1080"})
      assert html =~ "Sign in to create a whiteboard."
      assert Whiteboards.list_for_project(project.uuid) == []
    end

    test "can_write false hides the buttons and refuses forged writes",
         %{conn: conn, project: project, user: user} do
      file = fixture_file(user)
      {:ok, board} = Whiteboards.create_board_for_file(project, file.uuid, %{name: "Kept"})

      {:ok, view, html} = mount_tab_readonly(conn, project, user)

      refute html =~ "New whiteboard"
      refute html =~ "delete_board"

      html = render_submit(view, "create_board", %{"name" => "Forged", "size" => "1920x1080"})
      assert html =~ "permission to change whiteboards"

      render_click(view, "delete_board", %{"uuid" => board.uuid})
      assert length(Whiteboards.list_for_project(project.uuid)) == 1
    end

    test "delete removes the board row", %{conn: conn, project: project, user: user} do
      file = fixture_file(user)
      {:ok, board} = Whiteboards.create_board_for_file(project, file.uuid, %{name: "Gone"})

      {:ok, view, _} = mount_tab(conn, project, user)
      html = render_click(view, "delete_board", %{"uuid" => board.uuid})

      assert html =~ "Whiteboard removed."
      assert Whiteboards.list_for_project(project.uuid) == []
    end
  end
end
