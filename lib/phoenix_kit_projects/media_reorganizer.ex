defmodule PhoenixKitProjects.MediaReorganizer do
  @moduledoc """
  Projects' media-reorganizer plan source.

  Not compiled against a core `PhoenixKit.Modules.Storage.Reorganizer.Source`
  behaviour — today's hex core (2.23.x) does not ship the engine yet. This
  module declares no `@behaviour` and returns plain maps; see
  `PhoenixKitProjects.media_reorganizer/0` for the registration comment.
  Once core ships the engine, `plan/2`'s contract (`plan(actor_uuid, opts)
  :: [map()]`) already matches `Source.plan/2` — the only follow-up is
  adding `@behaviour`/`@impl`.

  Covers `Project` only — its legacy `project-<uuid>` folder and the
  `:attachments_parent_folder` / `:attachments_folder_name` hooks
  (`PhoenixKitProjects.Attachments`). Two things this module does NOT
  cover, deliberately:

    * **No pointer to back-fill.** Unlike catalogue, a project carries no
      cached folder uuid (no `data`/JSONB column for it) — its folder is
      always resolved by name, on every read
      (`Attachments.find_resource_folder/2`). So a `:move` action here
      never carries an `after_move`; there is nothing to write back.
    * **No pending-upload-folder prefix.** `Attachments` never stages an
      upload before the project exists (unlike catalogue's
      `catalogue-attachment-pending-*`), so `plan/2` never emits a
      `:pending` action.
    * **`Portal`/`PortalSubmission` are not a separate resource.** A
      submission's stored attachment is placed under
      `<project folder>/Portal submissions/`
      (`Portal.store_attachments/2` → `Attachments.ensure_folder/2` for
      the *project*), never in a folder of its own — moving the project's
      folder carries that nested subfolder with it for free. Neither
      `Portal` nor `PortalSubmission` ever creates a top-level legacy
      folder, so they get no `plan/2` entries of their own.

  Current folder resolution uses `Attachments.find_resource_folder/2`
  directly (the same function `Attachments.folder_uuid/2` uses) rather
  than re-implementing its four-level order
  (host-name-under-parent → deterministic-name-under-parent →
  deterministic-name-at-root → deterministic-name-anywhere) with
  batched preload queries the way `PhoenixKitCatalogue.MediaReorganizer`
  does for its much larger catalogue/category/item scan — the module
  is orders of magnitude smaller (one project row per project, not one
  per item), so a per-record call is the simpler, obviously-correct
  choice.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage.{File, Folder, FolderLink}
  alias PhoenixKitProjects.Attachments
  alias PhoenixKitProjects.Schemas.Project

  @legacy_prefix "project-"

  @doc """
  Builds the projects' reorganizer plan: one `:move` action per project
  whose current folder does not already match its hooks, plus a `:report`
  (`kind: :orphan`) per legacy `project-<uuid>` folder whose project is
  gone or archived.

  `opts` is accepted for interface parity with other Sources (e.g. the
  shared `pending_days` convention) but unused — this module has no
  pending-folder rule.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, _opts \\ []) do
    desired = resolve_desired(live_projects(), actor_uuid)

    resource_actions(desired, actor_uuid) ++ orphan_actions(desired)
  end

  # ── Projects ─────────────────────────────────────────────────────

  defp resolve_desired(projects, actor_uuid) do
    Enum.map(projects, fn project ->
      %{
        project: project,
        parent_uuid: Attachments.parent_folder_uuid(project, actor_uuid),
        name: Attachments.folder_name(project, actor_uuid)
      }
    end)
  end

  defp resource_actions(desired, actor_uuid) do
    desired
    |> Enum.map(&resource_action(&1, actor_uuid))
    |> Enum.reject(&is_nil/1)
  end

  defp resource_action(%{project: project, parent_uuid: parent_uuid, name: name}, actor_uuid) do
    case Attachments.find_resource_folder(project, actor_uuid) do
      nil ->
        nil

      %Folder{} = folder ->
        if noop_move?(folder, parent_uuid, name) do
          nil
        else
          %{
            source: "projects",
            kind: :project,
            label: project.name,
            op: :move,
            folder: folder,
            parent_uuid: parent_uuid,
            name: name,
            counts: counts(folder.uuid),
            on_conflict: :suffix,
            after_move: nil
          }
        end
    end
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` (or an
  # accepted `"name (N)"` suffix variant) is a no-op — filtered here since
  # this Source has no core `Action.noop?/1` to lean on, and (unlike
  # catalogue) never has an `after_move` to keep the action alive for.
  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: folder_name}, parent_uuid, name) do
    suffixed_variant?(folder_name, name)
  end

  defp noop_move?(_folder, _parent_uuid, _name), do: false

  defp suffixed_variant?(folder_name, name) do
    Regex.match?(~r/^#{Regex.escape(name)} \(\d+\)$/, folder_name)
  end

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`project-<uuid>`) at the media root or under a
  # parent this batch's hooks resolved to, whose uuid no longer names a
  # live project (missing, or archived — same rule `live_projects/0` uses
  # to drop it from the plan) is reported so a host can collect it. Never
  # `:move`d or `:trash`ed here — a legacy folder that IS a live project's
  # current folder is left to `resource_action/2` above.
  defp orphan_actions(desired) do
    resolved_parents =
      desired |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case legacy_candidate_folders(resolved_parents) do
      [] ->
        []

      candidates ->
        records_by_uuid = load_candidate_records(candidates)

        candidates
        |> Enum.map(&orphan_action(&1, records_by_uuid))
        |> Enum.reject(&is_nil/1)
    end
  end

  # One query for every legacy-named folder at root or under a resolved
  # parent — not a query per folder.
  defp legacy_candidate_folders(parent_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> repo().all()
    |> Enum.map(&{&1, legacy_uuid(&1.name)})
    |> Enum.filter(fn {_folder, uuid} -> uuid end)
  end

  defp legacy_uuid(name) do
    with true <- String.starts_with?(name, @legacy_prefix),
         uuid <- String.replace_prefix(name, @legacy_prefix, ""),
         {:ok, _} <- Ecto.UUID.cast(uuid) do
      uuid
    else
      _ -> nil
    end
  end

  # One query for every candidate uuid in the batch — not per folder. Always
  # called with a non-empty list (the caller branches on `[]` already).
  defp load_candidate_records(candidates) do
    uuids = candidates |> Enum.map(fn {_folder, uuid} -> uuid end) |> Enum.uniq()

    Project
    |> where([p], p.uuid in ^uuids)
    |> repo().all()
    |> Map.new(&{&1.uuid, &1})
  end

  defp orphan_action({folder, uuid}, records_by_uuid) do
    case Map.get(records_by_uuid, uuid) do
      %Project{archived_at: nil} ->
        nil

      project_or_nil ->
        counts = counts(folder.uuid)

        %{
          source: "projects",
          kind: :orphan,
          op: :report,
          label: folder.name,
          folder: folder,
          counts: counts,
          reason: orphan_reason(project_or_nil, counts)
        }
    end
  end

  defp orphan_reason(nil, {files, _links}), do: "record missing, #{files} file(s)"

  defp orphan_reason(%Project{}, {files, _links}),
    do: "project archived, #{files} file(s)"

  # ── Shared helpers ───────────────────────────────────────────────

  # Counts ALL rows regardless of status (including trashed files) — the
  # core engine re-measures the same way at apply time (any row with this
  # `folder_uuid`) and aborts the action on a mismatch, so a plan-time
  # count that excluded trashed files would fail every folder holding one.
  defp counts(folder_uuid) do
    files =
      File
      |> where([f], f.folder_uuid == ^folder_uuid)
      |> repo().aggregate(:count)

    links =
      FolderLink
      |> where([l], l.folder_uuid == ^folder_uuid)
      |> repo().aggregate(:count)

    {files, links}
  end

  defp live_projects do
    Project |> where([p], is_nil(p.archived_at)) |> repo().all()
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
