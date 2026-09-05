defmodule PhoenixKitProjects.Attachments do
  @moduledoc """
  Folder-scoped file attachments for a project, backed by core
  `PhoenixKit.Modules.Storage` — the workspace's per-resource-folder
  convention (`phoenix_kit_staff.Attachments` is the reference this
  mirrors): no module-owned table, no migration.

  Each project owns a deterministic root folder `project-<uuid>`, resolved
  **by name** on every read (never cached on the project row, so renames or
  deletions in /admin/media can't strand a dangling uuid) and created lazily
  on first use. Core's `[:name, :parent_uuid]` unique index makes
  find-or-create race-safe. Files live in core `phoenix_kit_files` — a file
  is IN the folder either as its home (`file.folder_uuid`) or via a
  `FolderLink`. Removal follows core's non-destructive convention:
  soft-trash a sole-home file, promote a link on a shared one, drop the
  link on a linked-only one — never hard-delete a possibly-shared asset.
  """

  require Logger

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, FileInstance, Folder, FolderLink, Manager, URLSigner}

  @list_limit 200

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Deterministic root folder name for a project's files."
  @spec folder_name(binary()) :: binary()
  def folder_name(project_uuid), do: "project-#{project_uuid}"

  @doc "Resolves the project folder uuid WITHOUT creating it (render-safe)."
  @spec folder_uuid(binary()) :: binary() | nil
  def folder_uuid(project_uuid) do
    case get_folder(folder_name(project_uuid)) do
      %Folder{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  @doc """
  Find-or-create the project folder. Race-safe: a lost create re-resolves
  the winner via the unique index.
  """
  @spec ensure_folder(binary()) :: {:ok, binary()} | {:error, term()}
  def ensure_folder(project_uuid) do
    case get_folder(folder_name(project_uuid)) do
      %Folder{uuid: uuid} ->
        {:ok, uuid}

      nil ->
        case Storage.create_folder(%{name: folder_name(project_uuid)}) do
          {:ok, %Folder{uuid: uuid}} ->
            {:ok, uuid}

          {:error, %Ecto.Changeset{} = cs} ->
            case get_folder(folder_name(project_uuid)) do
              %Folder{uuid: uuid} -> {:ok, uuid}
              _ -> {:error, cs}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  rescue
    e ->
      Logger.warning("[Projects.Attachments] ensure_folder failed: #{Exception.message(e)}")
      {:error, e}
  end

  @doc "Active files in the project folder (home or linked), newest first, capped."
  @spec list_files(binary()) :: [File.t()]
  def list_files(project_uuid) do
    case folder_uuid(project_uuid) do
      nil ->
        []

      folder_uuid ->
        linked =
          from(fl in FolderLink, where: fl.folder_uuid == ^folder_uuid, select: fl.file_uuid)

        repo().all(
          from(f in File,
            where:
              (f.folder_uuid == ^folder_uuid or f.uuid in subquery(linked)) and
                f.status != "trashed",
            order_by: [desc: f.inserted_at],
            limit: @list_limit
          )
        )
    end
  rescue
    e ->
      Logger.warning("[Projects.Attachments] list_files failed: #{Exception.message(e)}")
      []
  end

  @doc """
  Links picked/uploaded files into the project folder: a homeless file gets
  this folder as home; a file homed elsewhere gains a `FolderLink`
  (idempotent per file).
  """
  @spec attach_files(binary(), [binary()]) :: :ok
  def attach_files(project_uuid, file_uuids) when is_list(file_uuids) do
    case ensure_folder(project_uuid) do
      {:ok, folder_uuid} -> Enum.each(file_uuids, &attach(&1, folder_uuid))
      {:error, _} -> :ok
    end

    :ok
  end

  defp attach(file_uuid, folder_uuid) do
    case Storage.get_file(file_uuid) do
      nil ->
        :ok

      %File{folder_uuid: ^folder_uuid} ->
        :ok

      %File{folder_uuid: nil} = file ->
        file |> Ecto.Changeset.change(%{folder_uuid: folder_uuid}) |> repo().update()
        :ok

      %File{} ->
        %FolderLink{}
        |> FolderLink.changeset(%{folder_uuid: folder_uuid, file_uuid: file_uuid})
        |> repo().insert(on_conflict: :nothing, conflict_target: [:folder_uuid, :file_uuid])

        :ok
    end
  rescue
    e ->
      Logger.warning("[Projects.Attachments] attach #{file_uuid} failed: #{inspect(e)}")
      :ok
  end

  @doc """
  Removes a file from the project folder. Home here + not linked elsewhere →
  soft-trash (recoverable in the media trash); home here + linked elsewhere →
  promote a link to home; linked-only here → drop the link.
  """
  @spec remove_file(binary(), binary()) :: :ok | {:error, term()}
  def remove_file(project_uuid, file_uuid) do
    case folder_uuid(project_uuid) do
      nil -> :ok
      folder_uuid -> detach(file_uuid, folder_uuid)
    end
  end

  defp detach(file_uuid, folder_uuid) do
    case Storage.get_file(file_uuid) do
      nil -> :ok
      %File{folder_uuid: ^folder_uuid} = file -> detach_home(file)
      %File{} -> detach_link(file_uuid, folder_uuid)
    end
  rescue
    e ->
      Logger.warning("[Projects.Attachments] remove #{file_uuid} failed: #{inspect(e)}")
      {:error, e}
  end

  defp detach_home(file) do
    case repo().all(from(fl in FolderLink, where: fl.file_uuid == ^file.uuid)) do
      [] ->
        file
        |> Ecto.Changeset.change(%{
          status: "trashed",
          trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> repo().update()
        |> case do
          {:ok, _} -> :ok
          err -> err
        end

      [%FolderLink{} = link | _] ->
        repo().transaction(fn ->
          file |> Ecto.Changeset.change(%{folder_uuid: link.folder_uuid}) |> repo().update!()
          repo().delete!(link)
        end)
        |> case do
          {:ok, _} -> :ok
          err -> err
        end
    end
  end

  defp detach_link(file_uuid, folder_uuid) do
    from(fl in FolderLink, where: fl.file_uuid == ^file_uuid and fl.folder_uuid == ^folder_uuid)
    |> repo().delete_all()

    :ok
  end

  @doc "Heroicon name for a file's type (template helper)."
  @spec file_icon(map()) :: String.t()
  def file_icon(%{file_type: "image"}), do: "hero-photo"
  def file_icon(%{file_type: "video"}), do: "hero-film"
  def file_icon(%{file_type: "audio"}), do: "hero-musical-note"
  def file_icon(%{file_type: "archive"}), do: "hero-archive-box"
  def file_icon(%{mime_type: "application/pdf"}), do: "hero-document-text"
  def file_icon(_), do: "hero-document"

  @doc "Public download URL, nil-safe."
  @spec download_url(File.t()) :: String.t() | nil
  def download_url(%File{} = file) do
    Storage.get_public_url(file)
  rescue
    _ -> nil
  end

  @doc """
  `download_url/1` for a list of files in ONE file-instance read —
  `%{file_uuid => url}`, a file with no original instance absent. The
  Files page asked per row, twice (guard + href), on every render (the
  2026-09-05 N+1 audit). Same URL rule as core's `get_public_url/1`: the
  storage manager's public URL when it has one, else a signed URL.
  """
  @spec download_urls([File.t()]) :: %{binary() => String.t()}
  def download_urls([]), do: %{}

  def download_urls(files) when is_list(files) do
    uuids = Enum.map(files, & &1.uuid)

    from(fi in FileInstance,
      where: fi.file_uuid in ^uuids and fi.variant_name == "original",
      select: {fi.file_uuid, fi.file_name}
    )
    |> repo().all()
    |> Enum.reduce(%{}, fn {file_uuid, path}, acc ->
      case row_url(file_uuid, path) do
        nil -> acc
        url -> Map.put_new(acc, file_uuid, url)
      end
    end)
  rescue
    _ -> %{}
  end

  # The same rule as core's `get_public_url/1`, one row at a time so a
  # file the manager cannot address loses its link alone.
  defp row_url(file_uuid, path) do
    Manager.public_url(path) || URLSigner.signed_url(file_uuid, "original", locale: :none)
  rescue
    _ -> nil
  end

  defp get_folder(name) do
    repo().one(from(f in Folder, where: f.name == ^name and is_nil(f.parent_uuid)))
  rescue
    _ -> nil
  end
end
