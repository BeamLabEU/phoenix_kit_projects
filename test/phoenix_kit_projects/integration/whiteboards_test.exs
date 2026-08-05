defmodule PhoenixKitProjects.Integration.WhiteboardsTest do
  @moduledoc """
  Step 11 whiteboards: the V5 board rows + the blank-background bridge,
  end-to-end — the V1 baseline ships a default local storage bucket, so
  `create/3`'s full storage leg (blank PNG → store_file → dimension
  stamp → folder filing) runs for real here. Variant generation logs
  errors without ImageMagick; that's non-critical (the canvas renders
  from the original).
  """

  use PhoenixKitProjects.DataCase, async: false

  import PhoenixKitProjects.ActivityLogAssertions

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Attachments, Whiteboards}

  setup do
    {:ok, user} =
      Auth.register_user(%{
        email: "wb-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, project: fixture_project(), user: user}
  end

  defp fixture_file(user, attrs \\ %{}) do
    {:ok, file} =
      %Storage.File{}
      |> Ecto.Changeset.change(
        Map.merge(
          %{
            user_uuid: user.uuid,
            original_file_name: "board.png",
            file_name: "board.png",
            file_path: "/tmp/board.png",
            ext: ".png",
            file_type: "image",
            mime_type: "image/png",
            file_checksum: "wb-checksum-#{System.unique_integer([:positive])}",
            user_file_checksum: "wb-user-#{System.unique_integer([:positive])}",
            size: 1234,
            width: 1920,
            height: 1080,
            status: "active"
          },
          attrs
        )
      )
      |> PhoenixKit.RepoHelper.repo().insert()

    file
  end

  describe "blank_png/3" do
    test "produces a valid solid PNG with the requested dimensions" do
      png = Whiteboards.blank_png(320, 200, "salt-a")

      # PNG signature + IHDR dimensions.
      assert <<137, 80, 78, 71, 13, 10, 26, 10, _len::32, "IHDR", w::32, h::32, _::binary>> = png
      assert {w, h} == {320, 200}
    end

    test "distinct salts produce distinct bytes (the Storage dedup trap)" do
      a = Whiteboards.blank_png(320, 200, "salt-a")
      b = Whiteboards.blank_png(320, 200, "salt-b")

      assert byte_size(a) == byte_size(b)
      refute a == b
    end
  end

  describe "create_board_for_file/3" do
    test "board row + project-folder filing + activity", %{project: project, user: user} do
      file = fixture_file(user)

      assert {:ok, board} =
               Whiteboards.create_board_for_file(project, file.uuid, %{
                 name: "Sprint sketches",
                 width: 1920,
                 height: 1080,
                 created_by_uuid: user.uuid
               })

      assert board.name == "Sprint sketches"
      assert board.position == 0

      # The background file lands in the project folder (Files page).
      assert Enum.any?(Attachments.list_files(project.uuid), &(&1.uuid == file.uuid))

      assert_activity_logged("projects.whiteboard_created",
        resource_uuid: project.uuid,
        metadata_has: %{"name" => "Sprint sketches"}
      )

      # Positions increment.
      file2 = fixture_file(user)

      assert {:ok, board2} =
               Whiteboards.create_board_for_file(project, file2.uuid, %{name: "Second"})

      assert board2.position == 1

      assert Enum.map(Whiteboards.list_for_project(project.uuid), & &1.uuid) ==
               [board.uuid, board2.uuid]
    end

    test "one board per file (unique constraint)", %{project: project, user: user} do
      file = fixture_file(user)
      assert {:ok, _} = Whiteboards.create_board_for_file(project, file.uuid, %{name: "One"})

      assert {:error, changeset} =
               Whiteboards.create_board_for_file(project, file.uuid, %{name: "Two"})

      assert %{file_uuid: _} = errors_on(changeset)
    end

    test "blank names are refused", %{project: project, user: user} do
      file = fixture_file(user)

      assert {:error, changeset} =
               Whiteboards.create_board_for_file(project, file.uuid, %{name: "   "})

      assert %{name: _} = errors_on(changeset)
    end
  end

  describe "create/3 (full bridge)" do
    test "requires an actor", %{project: project} do
      assert {:error, :actor_required} = Whiteboards.create(project, "Board")
    end

    test "creates the background file + board end-to-end",
         %{project: project, user: user} do
      assert {:ok, board} =
               Whiteboards.create(project, "Full bridge",
                 actor_uuid: user.uuid,
                 width: 640,
                 height: 480
               )

      file = Storage.get_file(board.file_uuid)
      assert file.mime_type == "image/png"
      # Dimensions are stamped explicitly (store_file never sets them) —
      # without this the canvas silently falls back to 1000×1000.
      assert {file.width, file.height} == {640, 480}
      assert Enum.any?(Attachments.list_files(project.uuid), &(&1.uuid == file.uuid))
      assert Whiteboards.viewer_file(file.uuid).urls["original"]
    end

    test "two same-size boards get DISTINCT background files (salt beats dedup)",
         %{project: project, user: user} do
      # Storage dedups per-user by content checksum: identical unsalted
      # blanks would collide onto ONE file row sharing one annotation set.
      {:ok, a} = Whiteboards.create(project, "Board A", actor_uuid: user.uuid)
      {:ok, b} = Whiteboards.create(project, "Board B", actor_uuid: user.uuid)

      refute a.file_uuid == b.file_uuid
      assert length(Whiteboards.list_for_project(project.uuid)) == 2
    end
  end

  describe "rename/3 and delete/2" do
    test "rename logs and updates", %{project: project, user: user} do
      file = fixture_file(user)
      {:ok, board} = Whiteboards.create_board_for_file(project, file.uuid, %{name: "Old"})

      assert {:ok, renamed} = Whiteboards.rename(board, "New name", actor_uuid: user.uuid)
      assert renamed.name == "New name"
      assert_activity_logged("projects.whiteboard_renamed", resource_uuid: project.uuid)
    end

    test "delete removes the ROW and keeps the file", %{project: project, user: user} do
      file = fixture_file(user)
      {:ok, board} = Whiteboards.create_board_for_file(project, file.uuid, %{name: "Gone"})

      assert :ok = Whiteboards.delete(board, actor_uuid: user.uuid)
      assert Whiteboards.list_for_project(project.uuid) == []
      # The drawing (file + its annotations) survives in the project folder.
      assert Storage.get_file(file.uuid)
      assert Enum.any?(Attachments.list_files(project.uuid), &(&1.uuid == file.uuid))
      assert_activity_logged("projects.whiteboard_deleted", resource_uuid: project.uuid)
    end
  end

  test "viewer_file/1 builds the MediaCanvasViewer contract map", %{user: user} do
    file = fixture_file(user)

    {:ok, _instance} =
      Storage.create_file_instance(%{
        variant_name: "original",
        file_name: file.file_name,
        mime_type: "image/png",
        ext: ".png",
        checksum: "chk",
        size: 1234,
        processing_status: "completed",
        file_uuid: file.uuid
      })

    map = Whiteboards.viewer_file(file.uuid)

    assert map.file_uuid == file.uuid
    assert map.mime_type == "image/png"
    assert {1920, 1080} == {map.width, map.height}
    assert is_binary(map.urls["original"])

    assert Whiteboards.viewer_file(Ecto.UUID.generate()) == nil
  end
end
