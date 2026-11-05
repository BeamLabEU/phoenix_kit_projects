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
    ImageEditing,
    Libraries,
    ResourceFolders,
    URLSigner
  }

  alias PhoenixKit.Utils.Format

  alias PhoenixKitProjects.Schemas.{Assignment, AssignmentFile, Project, Task}

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

  # ── Pictures in a project's or a library task's description ─────────
  #
  # The boss, 2026-10-31: "can't add image to project or paste into
  # description. Check consistency" — a project's (and a sub-project's,
  # template's) description takes pictures as a task's does, kept in the
  # project's folder; a library task's in one "task library" folder, since
  # it belongs to no project. The text keeps each by its file
  # (`InlineImages`), so a viewer gets an address they may open.

  @description_image_max_mb 10
  @task_library_folder "projects-task-library"

  @doc "The largest picture a description takes, in MB."
  def description_image_max_mb, do: @description_image_max_mb

  @doc """
  Stores the picture at `path` for `holder`'s description (a `%Project{}`
  or a library `%Task{}`): `{:ok, %File{}}` or `{:error, reason}`.
  """
  @spec store_description_image(Project.t() | Task.t(), Path.t(), keyword(), binary() | nil) ::
          {:ok, File.t()} | {:error, term()}
  def store_description_image(holder, path, opts, actor_uuid) do
    store_opts =
      opts
      |> Keyword.take([:filename, :content_type, :size_bytes])
      |> Keyword.put(:user_uuid, actor_uuid)

    with {:ok, folder_uuid} <- description_folder(holder, actor_uuid),
         {:ok, %File{} = file} <- Storage.store_file(path, store_opts) do
      place_in(file, folder_uuid)
    end
  rescue
    e ->
      Logger.warning(
        "[Projects.Attachments] store_description_image failed: #{Exception.message(e)}"
      )

      {:error, :store_failed}
  end

  @doc """
  A picture pasted into an editor (a `data:` URL) stored for `holder`'s
  description. Only an image, at most `description_image_max_mb/0`.
  """
  @spec store_pasted_image(Project.t() | Task.t(), String.t(), String.t() | nil, binary() | nil) ::
          {:ok, File.t()} | {:error, term()}
  def store_pasted_image(holder, "data:" <> rest, name, actor_uuid) do
    with [meta, b64] <- String.split(rest, ",", parts: 2),
         [mime | _] <- String.split(meta, ";"),
         true <- String.starts_with?(mime, "image/") and String.ends_with?(meta, ";base64"),
         true <- byte_size(b64) <= div(@description_image_max_mb * 1_048_576 * 4, 3) + 4,
         {:ok, bytes} <- Base.decode64(b64, ignore: :whitespace) do
      path = Path.join(System.tmp_dir!(), "pkp-paste-#{System.unique_integer([:positive])}")
      Elixir.File.write!(path, bytes)

      try do
        store_description_image(
          holder,
          path,
          [filename: name || "pasted-image", content_type: mime, size_bytes: byte_size(bytes)],
          actor_uuid
        )
      after
        Elixir.File.rm(path)
      end
    else
      _ -> {:error, :not_an_image}
    end
  end

  def store_pasted_image(_holder, _data, _name, _actor_uuid), do: {:error, :not_an_image}

  defp description_folder(%Project{uuid: uuid} = project, actor_uuid) when is_binary(uuid),
    do: ensure_folder(project, actor_uuid)

  defp description_folder(%Task{}, actor_uuid) do
    case ResourceFolders.ensure(@task_library_folder, nil, actor_uuid) do
      {:ok, %Folder{uuid: uuid}} -> {:ok, uuid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp description_folder(_holder, _actor_uuid), do: {:error, :not_saved}

  @doc """
  The task library's picture folder, if one was made yet (a read; never
  makes it).
  """
  @spec task_library_folder_uuid() :: binary() | nil
  def task_library_folder_uuid do
    case ResourceFolders.find_under(@task_library_folder, nil) do
      %Folder{uuid: uuid} -> uuid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  A file uploaded to the project's Files (the project popup, item 47):
  stored and placed in the project's folder, where the Files tab lists it.
  """
  @spec store_project_file(Project.t(), Path.t(), keyword(), binary() | nil) ::
          {:ok, File.t()} | {:error, term()}
  def store_project_file(%Project{} = project, path, opts, actor_uuid),
    do: store_description_image(project, path, opts, actor_uuid)

  # ── A task's own files (V27) ────────────────────────────────────────
  #
  # The boss, 2026-10-30: "tasks should be able to hold their own images as
  # well, and files", and a picture pasted into the description stored the
  # same way. The bytes go into a folder per task (`task-<uuid>`) inside the
  # project's folder — so they are found in Media where the project's are —
  # and a `phoenix_kit_project_assignment_files` row says the task holds
  # the file, so listing them reads no folders and a file moved in Media
  # stays the task's. Removing one takes the row and the folder's hold on
  # it, by core's non-destructive rule (`ResourceFolders.detach/2`).

  @task_list_limit 200

  @doc "The task's folder name inside its project's folder."
  @spec task_folder_name(binary()) :: binary()
  def task_folder_name(assignment_uuid), do: "task-#{assignment_uuid}"

  @doc """
  Find-or-create the task's folder under its project's (both created on
  first use, race-safe).
  """
  @spec ensure_task_folder(Assignment.t(), binary() | nil) :: {:ok, binary()} | {:error, term()}
  def ensure_task_folder(%Assignment{uuid: uuid, project_uuid: project_uuid}, actor_uuid)
      when is_binary(uuid) do
    with {:ok, parent} <- ensure_folder(project_uuid, actor_uuid),
         name = task_folder_name(uuid),
         {:ok, %Folder{uuid: folder_uuid}} <-
           ResourceFolders.ensure(name, parent, actor_uuid,
             lookup: fn -> ResourceFolders.find_under(name, parent) end
           ) do
      {:ok, folder_uuid}
    end
  end

  @doc """
  Stores an uploaded file for a task: into core Storage (`store_file/2`
  options: `:filename`, `:content_type`, `:size_bytes`), placed in the
  task's folder, and recorded as the task's — `inline: true` for an image
  placed in its description. `{:ok, %File{}}` or `{:error, reason}`; a file
  the same person stored before is the one reused.
  """
  @spec store_task_file(Assignment.t(), Path.t(), keyword(), binary() | nil) ::
          {:ok, File.t()} | {:error, term()}
  def store_task_file(%Assignment{} = assignment, path, opts, actor_uuid) do
    inline? = Keyword.get(opts, :inline, false)

    store_opts =
      opts
      |> Keyword.take([:filename, :content_type, :size_bytes])
      |> Keyword.put(:user_uuid, actor_uuid)

    with {:ok, folder_uuid} <- ensure_task_folder(assignment, actor_uuid),
         {:ok, %File{} = file} <- Storage.store_file(path, store_opts),
         {:ok, file} <- place_in(file, folder_uuid),
         :ok <- hold(assignment.uuid, file.uuid, inline?, actor_uuid) do
      files_changed(assignment)
      {:ok, file}
    end
  rescue
    e ->
      Logger.warning("[Projects.Attachments] store_task_file failed: #{Exception.message(e)}")
      {:error, :store_failed}
  end

  # A duplicate the uploader had trashed comes back into this folder.
  defp place_in(%File{status: "trashed"} = file, folder_uuid),
    do: placed(ResourceFolders.place_stored({:ok, file, :duplicate}, folder_uuid), file)

  defp place_in(%File{} = file, folder_uuid),
    do: placed(ResourceFolders.place_stored({:ok, file}, folder_uuid), file)

  defp placed({:ok, %File{} = file}, _), do: {:ok, file}
  defp placed({:already_attached, %File{} = file}, _), do: {:ok, file}
  defp placed({:error, reason}, _), do: {:error, reason}

  # The row saying the task holds the file; a second hold is the first one
  # (an inline image added as a file too stays one row).
  defp hold(assignment_uuid, file_uuid, inline?, actor_uuid) do
    %AssignmentFile{}
    |> Ecto.Changeset.change(
      assignment_uuid: assignment_uuid,
      file_uuid: file_uuid,
      inline: inline?,
      added_by_uuid: actor_uuid
    )
    |> repo().insert(on_conflict: :nothing, conflict_target: [:assignment_uuid, :file_uuid])
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # An open view of the task (`AssignmentViewLive`) lists its files: it
  # reloads on the task's update, as for any other change to it.
  defp files_changed(%Assignment{uuid: uuid, project_uuid: project_uuid}) do
    PhoenixKitProjects.PubSub.broadcast_assignment(:assignment_updated, %{
      uuid: uuid,
      project_uuid: project_uuid
    })
  end

  @doc """
  The files a task holds, oldest first, live ones only (not trashed, not
  system-managed), each as `%{file: %File{}, inline: boolean}`. `inline:
  false` alone gives the files added to the task, not the images in its
  description.
  """
  @spec list_task_files(binary() | nil, keyword()) :: [%{file: File.t(), inline: boolean()}]
  def list_task_files(assignment_uuid, opts \\ [])

  def list_task_files(assignment_uuid, opts) when is_binary(assignment_uuid) do
    from(af in AssignmentFile,
      join: f in File,
      on: f.uuid == af.file_uuid,
      where: af.assignment_uuid == ^assignment_uuid,
      where: f.status != "trashed" and not coalesce(f.system_managed, false),
      order_by: [asc: af.inserted_at, asc: af.uuid],
      limit: @task_list_limit,
      select: %{file: f, inline: af.inline}
    )
    |> then(fn q ->
      case Keyword.fetch(opts, :inline) do
        {:ok, inline?} -> where(q, [af], af.inline == ^inline?)
        :error -> q
      end
    end)
    |> repo().all()
  rescue
    e ->
      Logger.warning("[Projects.Attachments] list_task_files failed: #{Exception.message(e)}")
      []
  end

  def list_task_files(_assignment_uuid, _opts), do: []

  @doc """
  Lets go of one of a task's files: the row goes, and the task folder's hold
  on the file by core's rule (a file homed only there is soft-trashed,
  recoverable in the media trash). A file the task does not hold is left
  alone (`{:error, :not_found}`).
  """
  @spec remove_task_file(Assignment.t(), binary(), binary() | nil) :: :ok | {:error, term()}
  def remove_task_file(%Assignment{uuid: uuid, project_uuid: project_uuid}, file_uuid, actor_uuid)
      when is_binary(file_uuid) do
    with {:ok, file_uuid} <- Ecto.UUID.cast(file_uuid),
         {1, _} <-
           repo().delete_all(
             from(af in AssignmentFile,
               where: af.assignment_uuid == ^uuid and af.file_uuid == ^file_uuid
             )
           ) do
      with parent when is_binary(parent) <- folder_uuid(project_uuid, actor_uuid),
           %Folder{uuid: folder} <- ResourceFolders.find_under(task_folder_name(uuid), parent) do
        _ = ResourceFolders.detach(file_uuid, folder)
      end

      files_changed(%Assignment{uuid: uuid, project_uuid: project_uuid})
      :ok
    else
      _ -> {:error, :not_found}
    end
  rescue
    e ->
      Logger.warning("[Projects.Attachments] remove_task_file failed: #{Exception.message(e)}")
      {:error, :remove_failed}
  end

  @doc "Heroicon name for a file's Storage type / mime (`Format.file_icon/1`)."
  @spec file_icon(map()) :: String.t()
  defdelegate file_icon(file), to: Format

  @doc """
  Download URL, nil-safe. A file in a private library gets a time-window
  token (the file route refuses its permanent one), as `download_urls/1`
  gives it.
  """
  @spec download_url(File.t()) :: String.t() | nil
  def download_url(%File{system_managed: true}), do: nil

  def download_url(%File{} = file) do
    if Libraries.private_file?(file),
      do: URLSigner.signed_url(to_string(file.uuid), "original", locale: :none, private: true),
      else: Storage.get_public_url(file)
  rescue
    _ -> nil
  end

  @doc """
  `download_url/1` for a list of files in two reads — the original file
  instances, and which of the files' libraries are private —
  `%{file_uuid => url}`, a file with no original instance (or one core
  hands no URL for: a system-managed file) absent. The Files page asked per
  row, twice (guard + href), on every render (the 2026-09-05 N+1 audit).

  The bucket's object URLs come from core's `Storage.direct_urls/1` (a
  fixed number of reads, no bucket request); what it leaves out — a private
  library, an edit in progress, a type not shown inline, a local or signed
  bucket — is served by the app through a signed URL, as `download_url/1`
  serves it. `batched_reads_test.exs` pins the count.
  """
  @spec download_urls([File.t()]) :: %{binary() => String.t()}
  def download_urls([]), do: %{}

  def download_urls(files) when is_list(files) do
    by_uuid = Map.new(files, &{&1.uuid, &1})
    private = Libraries.private_among(Enum.map(files, & &1.library_uuid))
    direct = Storage.direct_urls(Enum.map(files, &{to_string(&1.uuid), "original"}))
    batched_urls(by_uuid, private, direct)
  rescue
    _ -> %{}
  end

  defp batched_urls(by_uuid, private_libraries, direct) do
    uuids = Map.keys(by_uuid)

    from(fi in FileInstance, where: fi.file_uuid in ^uuids and fi.variant_name == "original")
    |> repo().all()
    |> Enum.reduce(%{}, fn instance, acc ->
      with %File{} = file <- Map.get(by_uuid, instance.file_uuid),
           url when is_binary(url) <- row_url(file, instance, private_libraries, direct) do
        Map.put_new(acc, file.uuid, url)
      else
        _ -> acc
      end
    end)
  end

  # One row at a time so a file the manager cannot address loses its link
  # alone.
  defp row_url(%File{system_managed: true}, _instance, _private, _direct), do: nil

  # A private library's file gets a time-window token (`private: true`):
  # the file route refuses its permanent one, so a link without it is dead.
  defp row_url(%File{} = file, instance, private_libraries, direct) do
    private? = to_string(file.library_uuid) in private_libraries

    cond do
      ImageEditing.edit_in_progress?(file) ->
        signed_url(file, nil, private?)

      private? ->
        signed_url(file, instance, true)

      true ->
        Map.get(direct, {to_string(file.uuid), "original"}) || signed_url(file, instance, false)
    end
  rescue
    _ -> nil
  end

  defp signed_url(file, instance, private?),
    do:
      URLSigner.signed_url(to_string(file.uuid), "original",
        locale: :none,
        version: instance,
        private: private?
      )
end
