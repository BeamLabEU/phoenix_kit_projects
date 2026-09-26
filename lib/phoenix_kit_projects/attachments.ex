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

  ## Parent folder

  A host can nest a project's folder under one of its own — e.g. a project
  linked to a sub-order keeps its files inside that sub-order's folder —
  via two config hooks, both `nil`/unset by default (today's root-only
  behaviour, unchanged):

    * `:attachments_parent_folder` — `{mod, fun}` where `fun(kind, actor_uuid,
      subject)` (preferred) or `fun(kind, actor_uuid)` returns `{:ok,
      parent_folder_uuid}` or anything else for "no parent". `subject` is
      the bare `%Project{}` for read-only lookups (`folder_uuid/2`,
      render-safe: never creates a parent) and `{:ensure, %Project{}}` for
      `ensure_folder/2`, which may create the parent chain. Both forms must
      name the same parent once it exists: reads only ever look under the
      bare form's answer, so a folder created under a different one is
      invisible to the Files page. A hook with no clause for the tuple form
      is read as answering nothing for it, and creation then uses the bare
      form's parent.
    * `:attachments_folder_name` — `{mod, fun}` where `fun(resource,
      actor_uuid)` returns `{:ok, name}` or anything else to fall back to
      the deterministic `project-<uuid>` name.

  A folder is found by its `{parent, name}` pair — core records no owning
  resource on a folder — so the pair a host's hooks answer must be unique
  per project. Two projects that resolve to the same parent AND the same
  host name share one folder, and each Files page lists the other's files.
  A per-project parent (a sub-order's own folder) with a fixed name is
  fine; a shared container needs a name carrying something project-unique.

  Resolution order (read-only, no writes; live folders only):
  host-name-under-parent → deterministic-name-under-parent →
  deterministic-name-at-root → deterministic-name-anywhere — so a legacy
  root `project-<uuid>` folder, or one left under a since-unlinked parent,
  is found and reused rather than twinned once a parent hook is
  configured. The convention is core's
  `PhoenixKit.Modules.Storage.ResourceFolders`.
  """

  require Logger

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage

  alias PhoenixKit.Modules.Storage.{
    File,
    FileInstance,
    Folder,
    Manager,
    ResourceFolders,
    URLSigner
  }

  alias PhoenixKit.Utils.Format

  alias PhoenixKitProjects.Schemas.Project

  @list_limit 200

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Deterministic root folder name for a project's files."
  @spec folder_name(binary()) :: binary()
  def folder_name(project_uuid), do: "project-#{project_uuid}"

  @doc false
  # Host-configured parent folder; `nil` = storage root (default). Contract:
  # `fun(kind, actor_uuid, subject)` (preferred) or `fun(kind, actor_uuid)`;
  # a failing hook or a non-uuid answer falls back to the root, logged
  # (`ResourceFolders.parent_uuid/4`).
  @spec parent_folder_uuid(Project.t() | {:ensure, Project.t()}, binary() | nil) :: binary() | nil
  def parent_folder_uuid(resource, actor_uuid),
    do:
      ResourceFolders.parent_uuid(
        :phoenix_kit_projects,
        resource_kind(resource),
        actor_uuid,
        resource
      )

  defp resource_kind(%Project{}), do: :project
  defp resource_kind({:ensure, %Project{}}), do: :project
  defp resource_kind(_), do: :unknown

  defp deterministic_name(%Project{uuid: uuid}), do: folder_name(uuid)

  # Callers that only have a uuid: load the record once. A deleted project must not raise
  # (the portal calls ensure_folder from a public endpoint).
  defp load_project(%Project{} = p), do: p
  defp load_project(uuid) when is_binary(uuid), do: repo().get(Project, uuid)

  @doc false
  # Folder name: the host's (`:attachments_folder_name`, `fun(resource, actor) :: {:ok, name} | nil`)
  # or the deterministic `project-<uuid>` name. A failing hook falls back like a declining
  # one — without it one host bug blanked the Files page.
  @spec folder_name(Project.t(), binary() | nil) :: binary()
  def folder_name(%Project{} = resource, actor_uuid) do
    ResourceFolders.host_name(:phoenix_kit_projects, resource, actor_uuid) ||
      deterministic_name(resource)
  end

  @doc false
  # host name under parent → deterministic name under parent → at root → ANYWHERE (a
  # project unlinked from its sub-order keeps a folder under the old sub-order; it must
  # still be found so the host can move it). Live folders only. Read-only: the host
  # answers the bare struct without creating anything.
  @spec find_resource_folder(Project.t() | {:ensure, Project.t()}, binary() | nil) ::
          struct() | nil
  def find_resource_folder({:ensure, %Project{} = project}, actor_uuid),
    do: find_resource_folder(project, actor_uuid)

  def find_resource_folder(%Project{} = project, actor_uuid),
    do: find_under_parent(project, parent_folder_uuid(project, actor_uuid), actor_uuid)

  defp find_under_parent(project, parent_uuid, actor_uuid) do
    ResourceFolders.resolve(
      parent: parent_uuid,
      host_name: folder_name(project, actor_uuid),
      name: deterministic_name(project),
      anywhere: true
    )
  end

  @doc "Resolves the project folder uuid WITHOUT creating it (render-safe)."
  @spec folder_uuid(binary() | Project.t(), binary() | nil) :: binary() | nil
  def folder_uuid(project_or_uuid, actor_uuid \\ nil) do
    with %Project{} = project <- load_project(project_or_uuid),
         %Folder{uuid: uuid} <- find_resource_folder(project, actor_uuid) do
      uuid
    else
      _ -> nil
    end
  rescue
    error ->
      Logger.warning("[Projects.Attachments] folder_uuid failed: #{Exception.message(error)}")
      nil
  catch
    :exit, reason ->
      Logger.warning(
        "[Projects.Attachments] folder_uuid failed: " <>
          ResourceFolders.describe_failure({:exit, reason})
      )

      nil
  end

  @doc """
  Find-or-create the project folder. Race-safe: a lost create re-resolves
  the winner via the unique index. The host-configured parent (via
  `:attachments_parent_folder`, subject `{:ensure, project}`) may build the
  parent chain; a legacy root `project-<uuid>` folder is found and reused
  rather than twinned. When the host's name is taken under that parent by a
  folder this project's lookup does not reach, the folder gets the
  deterministic `project-<uuid>` name instead.
  """
  @spec ensure_folder(binary() | Project.t(), binary() | nil) ::
          {:ok, binary()} | {:error, term()}
  def ensure_folder(project_or_uuid, actor_uuid \\ nil) do
    case load_project(project_or_uuid) do
      nil -> {:error, :not_found}
      project -> do_ensure_folder(project, actor_uuid)
    end
  rescue
    e ->
      Logger.warning("[Projects.Attachments] ensure_folder failed: #{Exception.message(e)}")
      {:error, e}
  end

  defp do_ensure_folder(project, actor_uuid) do
    case find_resource_folder(project, actor_uuid) do
      %Folder{uuid: uuid} ->
        {:ok, uuid}

      nil ->
        # Creation may build the parent chain: the host gets `{:ensure, project}`.
        # Its folder is looked for under that parent too, so a host answering
        # the two forms differently gets no second folder on the next upload.
        # A hook that answers only the bare form (a clause on `%Project{}`
        # raises on the tuple, which core reads as no answer) still places
        # the folder under the parent it names for reads, where the Files
        # page looks for it — not at the root, where reads would miss a
        # host-named folder.
        create_parent =
          parent_folder_uuid({:ensure, project}, actor_uuid) ||
            parent_folder_uuid(project, actor_uuid)

        lookup = fn ->
          find_resource_folder(project, actor_uuid) ||
            find_under_parent(project, create_parent, actor_uuid)
        end

        project
        |> folder_name(actor_uuid)
        |> ResourceFolders.ensure(create_parent, actor_uuid,
          lookup: lookup,
          fallback_name: deterministic_name(project)
        )
        |> case do
          {:ok, %Folder{uuid: uuid}} -> {:ok, uuid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Live files in the project folder (home or linked; not trashed, not
  system-managed), newest first, capped.
  """
  @spec list_files(binary() | Project.t(), binary() | nil) :: [File.t()]
  def list_files(project_or_uuid, actor_uuid \\ nil) do
    case folder_uuid(project_or_uuid, actor_uuid) do
      nil -> []
      folder_uuid -> ResourceFolders.list_files(folder_uuid, limit: @list_limit)
    end
  rescue
    e ->
      Logger.warning("[Projects.Attachments] list_files failed: #{Exception.message(e)}")
      []
  end

  @doc """
  Links picked/uploaded files into the project folder by core's rule: a
  homeless file gets this folder as home; a file homed elsewhere gains a
  `FolderLink` (idempotent per file). Always `:ok`; a failure is logged.
  """
  @spec attach_files(binary() | Project.t(), [binary()], binary() | nil) :: :ok
  def attach_files(project_or_uuid, file_uuids, actor_uuid \\ nil) when is_list(file_uuids) do
    case ensure_folder(project_or_uuid, actor_uuid) do
      {:ok, folder_uuid} -> Enum.each(file_uuids, &attach(&1, folder_uuid))
      {:error, _} -> :ok
    end

    :ok
  end

  defp attach(file_uuid, folder_uuid) do
    case ResourceFolders.attach(file_uuid, folder_uuid) do
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Projects.Attachments] attach #{file_uuid} failed: " <>
            ResourceFolders.describe_failure(reason)
        )
    end
  end

  @doc """
  Removes a file from the project folder by core's rule: linked-only here →
  drop the link; home here + linked into another live folder → move it
  there; home here and nothing else holds it → soft-trash (recoverable in the
  media trash). A file that is not here is left alone.
  """
  @spec remove_file(binary() | Project.t(), binary(), binary() | nil) :: :ok | {:error, term()}
  def remove_file(project_or_uuid, file_uuid, actor_uuid \\ nil) do
    # The actor matters: an actor-dependent parent hook resolves a different
    # folder without it, and a miss here is a silent `:ok`.
    case folder_uuid(project_or_uuid, actor_uuid) do
      nil ->
        :ok

      folder_uuid ->
        case ResourceFolders.detach(file_uuid, folder_uuid) do
          {:ok, _outcome} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Heroicon name for a file's Storage type / mime (`Format.file_icon/1`)."
  @spec file_icon(map()) :: String.t()
  defdelegate file_icon(file), to: Format

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
end
