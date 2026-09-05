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

  describe "create/3 (file-less, core V183)" do
    test "requires an actor", %{project: project} do
      assert {:error, :actor_required} = Whiteboards.create(project, "Board")
    end

    test "creates just the row — no file, no Storage, no folder entry",
         %{project: project, user: user} do
      before_count = user_file_count(user)

      assert {:ok, board} =
               Whiteboards.create(project, "Island layout",
                 actor_uuid: user.uuid,
                 width: 640,
                 height: 480
               )

      assert board.file_uuid == nil
      assert {board.width, board.height} == {640, 480}
      assert user_file_count(user) == before_count
      assert Attachments.list_files(project.uuid) == []
      assert_activity_logged("projects.whiteboard_created", resource_uuid: project.uuid)
    end

    test "hands the viewer a board target, and a file-backed board a file", %{
      project: project,
      user: user
    } do
      {:ok, board} = Whiteboards.create(project, "Sketch", actor_uuid: user.uuid)

      assert Whiteboards.viewer_board(board) == %{
               target_type: "projects_whiteboard",
               target_uuid: board.uuid,
               width: 1920,
               height: 1080,
               background: nil
             }

      file = fixture_file(user)
      {:ok, over_image} = Whiteboards.create_board_for_file(project, file.uuid, %{name: "Photo"})
      assert Whiteboards.viewer_board(over_image) == nil
    end

    test "a bad name is refused", %{project: project, user: user} do
      assert {:error, _} = Whiteboards.create(project, "   ", actor_uuid: user.uuid)

      assert {:error, _} =
               Whiteboards.create(project, String.duplicate("x", 200), actor_uuid: user.uuid)

      assert Whiteboards.list_for_project(project.uuid) == []
    end

    test "deleting a file-less board takes its shapes with it", %{project: project, user: user} do
      {:ok, board} = Whiteboards.create(project, "Doomed", actor_uuid: user.uuid)

      {:ok, _} =
        PhoenixKit.Annotations.create(%{
          target_type: Whiteboards.target_type(),
          target_uuid: board.uuid,
          kind: "line",
          geometry: %{"path" => [[0, 0], [1, 1]]}
        })

      assert :ok = Whiteboards.delete(board, actor_uuid: user.uuid)
      assert PhoenixKit.Annotations.list_for_target(Whiteboards.target_type(), board.uuid) == []
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

    test "nil'ing the name errors instead of crashing (same trim trap)",
         %{project: project, user: user} do
      file = fixture_file(user)
      {:ok, board} = Whiteboards.create_board_for_file(project, file.uuid, %{name: "Solid"})

      assert {:error, changeset} = Whiteboards.rename(board, nil)
      assert %{name: _} = errors_on(changeset)
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

  defp user_file_count(user) do
    import Ecto.Query

    PhoenixKit.RepoHelper.repo().one(
      from(f in Storage.File, where: f.user_uuid == ^user.uuid, select: count())
    )
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
