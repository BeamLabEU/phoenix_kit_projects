defmodule PhoenixKitProjects.Whiteboards do
  @moduledoc """
  Project whiteboards (Step 11): freeform drawing boards on core's
  Fresco/Etcher/annotations stack via the **blank-background bridge** —
  core's annotation persistence anchors to a `phoenix_kit_files` row
  (hard FK), so each board generates a solid-white PNG, registers it as
  a Storage file in the project's folder, and lets core's
  `MediaCanvasViewer` do everything else (drawing, annotation CRUD,
  palettes). When core grows a file-less canvas the bridge shrinks to a
  data migration; the board row (name/order/dimensions) is ours either
  way.

  The blank PNG is generated in pure Elixir (no ImageMagick for the
  base file) and **salted** with a `tEXt` chunk carrying a fresh uuid:
  `Storage.store_file/2` dedups per-user by content checksum, so two
  identical unsalted blanks would silently collide onto ONE file row —
  and one shared annotation set.

  Deleting a board deletes the ROW; the background file (with any
  drawings baked into its annotations) stays in the project folder —
  consistent with the hub's disable-hides-never-deletes philosophy.
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
        # Validate the name BEFORE touching Storage: the background file
        # used to be created first, so a whitespace name returned an
        # error changeset AND left an orphaned file row + blob behind
        # (panel round, Gemini).
        with :ok <- validate_name(name),
             {:ok, file} <- create_background_file(name, width, height, actor_uuid) do
          # Dimensions drive the canvas extent; store_file/2 never
          # populates them (that's ProcessFileJob's job on the upload
          # path, which store_file doesn't enqueue).
          _ = Storage.update_file(file, %{width: width, height: height})

          project
          |> create_board_for_file(file.uuid, %{
            name: name,
            width: width,
            height: height,
            created_by_uuid: actor_uuid
          })
          |> case do
            {:ok, board} ->
              {:ok, board}

            {:error, _} = error ->
              # Residual failures (project deleted mid-flight, unique
              # race): don't leave the just-created background behind.
              cleanup_background_file(file)
              error
          end
        end
    end
  end

  defp validate_name(name) do
    trimmed = String.trim(to_string(name))

    if trimmed == "" or String.length(trimmed) > 160 do
      {:error, :invalid_name}
    else
      :ok
    end
  end

  defp cleanup_background_file(file) do
    Storage.delete_file(file)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
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
    position = next_position(project.uuid)

    %Whiteboard{}
    |> Whiteboard.changeset(
      attrs
      |> Map.put(:project_uuid, project.uuid)
      |> Map.put(:file_uuid, file_uuid)
      |> Map.put_new(:position, position)
    )
    |> RepoHelper.repo().insert()
    |> case do
      {:ok, board} ->
        # Best-effort: the board renders fine from the root folder too.
        Attachments.attach_files(project.uuid, [file_uuid])

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

  @doc """
  A solid-white truecolor PNG, salted with a `tEXt` chunk so every call
  produces DISTINCT bytes (Storage dedups per-user by content checksum —
  unsalted, every same-size board for one user would collide onto a
  single file row sharing one annotation set). Pure Elixir; no
  ImageMagick for the base file.
  """
  @spec blank_png(pos_integer(), pos_integer(), String.t()) :: binary()
  def blank_png(width, height, salt) do
    ihdr = <<width::32, height::32, 8, 2, 0, 0, 0>>
    row = <<0>> <> :binary.copy(<<255, 255, 255>>, width)
    idat = :zlib.compress(:binary.copy(row, height))
    text = "Software" <> <<0>> <> "phoenix_kit_projects whiteboard #{salt}"

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      png_chunk("IHDR", ihdr) <>
      png_chunk("tEXt", text) <>
      png_chunk("IDAT", idat) <>
      png_chunk("IEND", "")
  end

  defp png_chunk(type, data) do
    payload = type <> data
    <<byte_size(data)::32, payload::binary, :erlang.crc32(payload)::32>>
  end

  defp create_background_file(name, width, height, actor_uuid) do
    salt = Ecto.UUID.generate()
    png = blank_png(width, height, salt)
    filename = "whiteboard-#{slug(name)}-#{String.slice(salt, 0, 8)}.png"
    tmp_path = Path.join(System.tmp_dir!(), "pkp-#{salt}.png")

    try do
      File.write!(tmp_path, png)

      Storage.store_file(tmp_path,
        filename: filename,
        content_type: "image/png",
        size_bytes: byte_size(png),
        user_uuid: actor_uuid,
        metadata: %{"source" => "projects_whiteboard"}
      )
    rescue
      e -> {:error, Exception.message(e)}
    after
      File.rm(tmp_path)
    end
  end

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
    |> case do
      "" -> "board"
      s -> s
    end
  end

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
