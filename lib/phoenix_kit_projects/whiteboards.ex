defmodule PhoenixKitProjects.Whiteboards do
  @moduledoc """
  Project whiteboards (Step 11): freeform drawing boards on core's
  Fresco/Etcher/annotations stack.

  Since core V183 an annotation can anchor to any `target_type` +
  `target_uuid`, and Fresco renders a scene with zero images, so a board
  is just its row: `create/3` inserts it and core's `MediaCanvasViewer`
  draws it in board mode (`target_type: "projects_whiteboard"`,
  `target_uuid: board.uuid`) on an empty, infinite canvas — no file, no
  Storage, no folder. The **blank-background bridge** this module used
  to run (a salted solid-white PNG per board, registered as a Storage
  file, drawn over as if it were a photo — Max, 2026-09-05: "the dev
  added support to the package so that hack wouldn't be needed") is
  gone from the create path. Boards made by it keep their file and keep
  working: a board WITH a `file_uuid` renders through the file viewer as
  before, a board without one through board mode. `create_board_for_file/3`
  (a board over a real image) still exists for the former shape.

  Deleting a board deletes the ROW; a board's shapes go with it (the
  annotations are keyed by its uuid), and a file-backed board's background
  file stays in the project folder — consistent with the hub's
  disable-hides-never-deletes philosophy.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.Attachments
  alias PhoenixKitProjects.PubSub
  alias PhoenixKitProjects.Schemas.Whiteboard

  @default_size {1920, 1080}

  @doc "Boards for a project, in position/creation order."
  @spec list_for_project(binary()) :: [Whiteboard.t()]
  def list_for_project(project_uuid) do
    RepoHelper.repo().all(
      from(w in Whiteboard,
        where: w.project_uuid == ^project_uuid,
        order_by: [asc: w.position, asc: w.inserted_at]
      )
    )
  rescue
    _ -> []
  end

  @doc "Fetches a board scoped to its project (nil on cross-project uuids)."
  @spec get(binary(), binary()) :: Whiteboard.t() | nil
  def get(project_uuid, board_uuid) do
    RepoHelper.repo().one(
      from(w in Whiteboard,
        where: w.uuid == ^board_uuid and w.project_uuid == ^project_uuid
      )
    )
  rescue
    _ -> nil
  end

  @doc """
  Creates a whiteboard end-to-end: blank background PNG → Storage file
  (owned by the creating user) → dimensions stamped → filed into the
  project folder → board row. `opts[:actor_uuid]` is REQUIRED — the
  files table needs an owning user for non-system files.

  Options: `:width`/`:height` (default 1920×1080, capped 8000).
  """
  @spec create(map(), String.t(), keyword()) ::
          {:ok, Whiteboard.t()} | {:error, term()}
  def create(project, name, opts \\ []) do
    {default_w, default_h} = @default_size
    width = normalize_dim(Keyword.get(opts, :width), default_w)
    height = normalize_dim(Keyword.get(opts, :height), default_h)

    case Keyword.get(opts, :actor_uuid) do
      nil ->
        {:error, :actor_required}

      actor_uuid ->
        with :ok <- validate_name(name) do
          insert_board(project, %{
            name: name,
            width: width,
            height: height,
            created_by_uuid: actor_uuid
          })
        end
    end
  end

  # The target every one of this board's shapes anchors to (core V183).
  @target_type "projects_whiteboard"

  @doc "The `target_type` this module's boards anchor annotations to."
  @spec target_type() :: String.t()
  def target_type, do: @target_type

  @doc """
  The `:board` assign core's `MediaCanvasViewer` takes for a file-less
  board: the target pair and the canvas extent. `nil` for a board that
  still has a file — render that one through the file path.
  """
  @spec viewer_board(Whiteboard.t()) :: map() | nil
  def viewer_board(%Whiteboard{file_uuid: nil} = board) do
    %{
      target_type: @target_type,
      target_uuid: board.uuid,
      width: board.width,
      height: board.height,
      background: nil
    }
  end

  def viewer_board(_board), do: nil

  defp validate_name(name) do
    trimmed = String.trim(to_string(name))

    if trimmed == "" or String.length(trimmed) > 160 do
      {:error, :invalid_name}
    else
      :ok
    end
  end

  @doc """
  The DB-side composition: board row for an EXISTING file + project-folder
  filing + activity/broadcast. Split from `create/3` so the row logic is
  exercisable without configured storage buckets (tests, and any future
  "board from an existing image" flow).
  """
  @spec create_board_for_file(map(), binary(), map()) ::
          {:ok, Whiteboard.t()} | {:error, term()}
  def create_board_for_file(project, file_uuid, attrs) do
    insert_board(project, Map.put(attrs, :file_uuid, file_uuid))
  end

  # The row (+ filing, activity, broadcast). A file-backed board also gets
  # its background filed in the project folder.
  defp insert_board(project, attrs) do
    position = next_position(project.uuid)
    file_uuid = Map.get(attrs, :file_uuid)

    %Whiteboard{}
    |> Whiteboard.changeset(
      attrs
      |> Map.put(:project_uuid, project.uuid)
      |> Map.put_new(:position, position)
    )
    |> RepoHelper.repo().insert()
    |> case do
      {:ok, board} ->
        # Best-effort: the board renders fine from the root folder too.
        if file_uuid, do: Attachments.attach_files(project.uuid, [file_uuid])

        Activity.log("projects.whiteboard_created",
          actor_uuid: board.created_by_uuid,
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => board.name, "board_uuid" => board.uuid}
        )

        PubSub.broadcast_project(:whiteboard_created, %{uuid: project.uuid})
        {:ok, board}

      {:error, _} = error ->
        error
    end
  end

  @doc "Renames a board."
  @spec rename(Whiteboard.t(), String.t(), keyword()) ::
          {:ok, Whiteboard.t()} | {:error, term()}
  def rename(%Whiteboard{} = board, name, opts \\ []) do
    board
    |> Whiteboard.changeset(%{name: name})
    |> RepoHelper.repo().update()
    |> case do
      {:ok, updated} ->
        Activity.log("projects.whiteboard_renamed",
          actor_uuid: Keyword.get(opts, :actor_uuid),
          resource_type: "project",
          resource_uuid: board.project_uuid,
          metadata: %{"name" => updated.name, "board_uuid" => board.uuid}
        )

        PubSub.broadcast_project(:whiteboard_updated, %{uuid: board.project_uuid})
        {:ok, updated}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Deletes the board ROW. The background file — and the drawings living in
  its annotation rows — stays in the project folder, still reachable from
  the Files page as an annotated image.
  """
  @spec delete(Whiteboard.t(), keyword()) :: :ok | {:error, term()}
  def delete(%Whiteboard{} = board, opts \\ []) do
    case RepoHelper.repo().delete(board) do
      {:ok, _} ->
        # A file-less board's shapes are keyed by its uuid — nothing else
        # holds them, so they go with it. A file-backed board's shapes
        # belong to the file and stay, like the file does.
        if is_nil(board.file_uuid),
          do: PhoenixKit.Annotations.delete_for_target(@target_type, board.uuid)

        Activity.log("projects.whiteboard_deleted",
          actor_uuid: Keyword.get(opts, :actor_uuid),
          resource_type: "project",
          resource_uuid: board.project_uuid,
          metadata: %{"name" => board.name, "board_uuid" => board.uuid}
        )

        PubSub.broadcast_project(:whiteboard_deleted, %{uuid: board.project_uuid})
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  The curated file map `MediaCanvasViewer` expects (same shape core's
  `MediaViewer.curate_file/1` builds — that one is private). Nil when the
  file is gone or Storage errors: the LV renders a fallback card instead
  of a canvas.
  """
  @spec viewer_file(binary()) :: map() | nil
  def viewer_file(file_uuid) do
    case Storage.get_file(file_uuid) do
      %{uuid: _} = file ->
        # signed_url/2 is spec'd to return a binary; the enclosing rescue
        # is the safety net for anything stranger.
        urls =
          file_uuid
          |> Storage.list_file_instances()
          |> Map.new(fn instance ->
            {instance.variant_name, URLSigner.signed_url(file_uuid, instance.variant_name)}
          end)

        %{
          file_uuid: file.uuid,
          filename: file.original_file_name || file.file_name || "Whiteboard",
          file_type: file.file_type,
          mime_type: file.mime_type,
          size: file.size || 0,
          inserted_at: file.inserted_at,
          width: file.width,
          height: file.height,
          urls: urls
        }

      _ ->
        nil
    end
  rescue
    e ->
      Logger.warning("[Projects.Whiteboards] viewer_file failed: #{Exception.message(e)}")
      nil
  end

  # ── Blank background generation ────────────────────────────────────

  defp normalize_dim(value, default) do
    case value do
      v when is_integer(v) and v > 0 -> min(v, 8000)
      v when is_binary(v) -> normalize_dim(parse_int(v), default)
      _ -> default
    end
  end

  defp parse_int(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp next_position(project_uuid) do
    RepoHelper.repo().one(
      from(w in Whiteboard,
        where: w.project_uuid == ^project_uuid,
        select: coalesce(max(w.position), -1)
      )
    )
    |> Kernel.+(1)
  rescue
    _ -> 0
  end
end
