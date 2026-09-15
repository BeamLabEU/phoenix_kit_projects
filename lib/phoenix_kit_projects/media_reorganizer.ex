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
  (`PhoenixKitProjects.Attachments`). Three things this module does NOT
  cover, deliberately:

    * **No pointer to back-fill.** Unlike catalogue, a project carries no
      cached folder uuid (no `data`/JSONB column for it) — its folder is
      always resolved by name, on every read
      (`Attachments.find_resource_folder/2`). So a `:move` action here
      never carries an `after_move`, and a taken destination name is
      `:report`ed rather than `:suffix`ed — renaming the winner would
      strand this module's own lookup, which never searches for a
      suffixed name.
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

  A host that has not configured `:attachments_parent_folder` is left
  entirely untouched: `plan/2`'s move-planning half runs, and both hooks
  are called, only when the env is set — never a single move or report for
  a legacy folder sitting somewhere other than root (see "Move planning").
  The orphan scan is independent of the hook and always runs (root-only
  when no parent is resolved).

  ## Move planning

  For each live project (D4 — **archived is live**; only a hard-deleted
  project, i.e. no matching row at all, makes an orphan):

  1. Both hooks run once (`Attachments.parent_folder_uuid/2`,
     `Attachments.folder_name/2`) — exactly the functions a fresh upload
     would call. When the parent hook resolves `nil` the host name is
     **not** used as the desired name either: `find_resource_folder/2`
     only ever looks for a host name *under a parent*, so without one the
     desired name stays the deterministic `project-<uuid>` name — a
     project whose parent hook answers `nil` this run (while the name
     hook still answers a host name) must not have its root folder
     renamed to that host name, or `find_resource_folder/2` can no longer
     find it there on the next read.
  2. The project's *current* folder is looked up, in the module's own
     order, only at the resolved parent (host name, then deterministic
     name) and at root (deterministic name) — never the unrestricted
     "anywhere" scan `find_resource_folder/2` falls back to for a live
     upload. A legacy folder that exists live only somewhere else (the
     owner moved it, or it is still parked under a parent the project was
     since unlinked from) is reported as `kind: :relocated`, never moved.
  3. A live match at **both** the resolved parent and root is
     unresolvable — reported as `kind: :duplicate`, nothing moved. Two (or
     more) projects whose current folder resolves to the very same live
     folder (e.g. two projects sharing a parent and a colliding host name)
     are likewise reported as `kind: :duplicate`, no move for either.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage.{File, Folder, FolderLink}
  alias PhoenixKitProjects.Attachments
  alias PhoenixKitProjects.Schemas.Project

  @legacy_prefix "project-"

  @uuid_regex ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @doc """
  Builds the projects' reorganizer plan: one `:move` action per project
  whose current folder does not already match its hooks, `:report`
  actions (`kind: :duplicate` / `kind: :relocated`) for folders that
  cannot be unambiguously resolved or moved, and a `:report`
  (`kind: :orphan`) per legacy `project-<uuid>` folder whose project no
  longer exists.

  `opts` is accepted for interface parity with other Sources (e.g. the
  shared `pending_days` convention) but unused — this module has no
  pending-folder rule.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, _opts \\ []) do
    {resource_actions, resolved_parents} = resource_plan(actor_uuid)

    resource_actions ++ orphan_actions(resolved_parents)
  end

  # ── Projects ─────────────────────────────────────────────────────

  defp resource_plan(actor_uuid) do
    if hook_configured?() do
      build_resource_plan(live_projects(), actor_uuid)
    else
      {[], []}
    end
  end

  defp hook_configured? do
    match?(
      {mod, fun} when is_atom(mod) and is_atom(fun),
      Application.get_env(:phoenix_kit_projects, :attachments_parent_folder)
    )
  end

  # Runs both hooks exactly once per project. The desired name is the
  # host name only when a parent was resolved — see moduledoc point 1
  # (the blocker this guards against).
  defp build_resource_plan(projects, actor_uuid) do
    desired =
      Enum.map(projects, fn project ->
        parent_uuid = Attachments.parent_folder_uuid(project, actor_uuid)
        deterministic_name = Attachments.folder_name(project.uuid)
        host_name = Attachments.folder_name(project, actor_uuid)
        name = if parent_uuid, do: host_name, else: deterministic_name

        %{
          project: project,
          parent_uuid: parent_uuid,
          name: name,
          deterministic_name: deterministic_name
        }
      end)

    by_parent_host = preload_pairs(desired, & &1.name)
    by_parent_deterministic = preload_pairs(desired, & &1.deterministic_name)
    by_root = preload_by_root_name(Enum.map(desired, & &1.deterministic_name))
    by_anywhere = preload_by_anywhere_name(Enum.map(desired, & &1.deterministic_name))

    entries =
      Enum.map(
        desired,
        &resolve_entry(&1, by_parent_host, by_parent_deterministic, by_root, by_anywhere)
      )

    resolved_parents =
      desired |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    {unique, ambiguous, shared, relocated} = classify_entries(entries)

    move_actions = unique |> Enum.map(&build_move_action/1) |> Enum.reject(&is_nil/1)
    relocated_actions = Enum.map(relocated, &build_relocated_action/1)
    dup_actions = Enum.map(ambiguous, &build_ambiguous_duplicate_action/1)
    shared_actions = Enum.map(shared, &build_shared_duplicate_action/1)

    actions = finalize_counts(move_actions ++ relocated_actions) ++ dup_actions ++ shared_actions

    {actions, resolved_parents}
  end

  # host-name-under-parent → deterministic-name-under-parent →
  # deterministic-name-at-root — the module's own order, restricted to
  # root and the resolved parent (X9 — unlike
  # `Attachments.find_resource_folder/2`, this never treats an
  # unrestricted "anywhere" hit as the current folder to move; it is only
  # used below to tell a genuinely absent candidate apart from one that is
  # live but relocated). A live match at more than one of these tiers is
  # ambiguous.
  defp resolve_entry(d, by_parent_host, by_parent_deterministic, by_root, by_anywhere) do
    host_match = d.parent_uuid && Map.get(by_parent_host, {d.name, d.parent_uuid})

    det_parent_match =
      d.parent_uuid && Map.get(by_parent_deterministic, {d.deterministic_name, d.parent_uuid})

    root_match = Map.get(by_root, d.deterministic_name)

    matches =
      [host_match, det_parent_match, root_match]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.uuid)

    case matches do
      [] ->
        Map.merge(d, %{
          folder: nil,
          ambiguous: nil,
          relocated: Map.get(by_anywhere, d.deterministic_name)
        })

      [folder] ->
        Map.merge(d, %{folder: folder, ambiguous: nil, relocated: nil})

      [f1, f2 | _] ->
        Map.merge(d, %{folder: nil, ambiguous: {f1, f2}, relocated: nil})
    end
  end

  # Splits resolved entries into: `unique` (one project ↔ one folder, safe
  # to plan a move for — further split into `shared` when more than one
  # project resolves to the very same folder, X5), `ambiguous` (one
  # project, legacy/host name live at both root and under the resolved
  # parent, X11), and `relocated` (no live folder at root or under the
  # resolved parent, but a live legacy-named folder exists elsewhere, X9).
  # A project with no folder anywhere (`relocated` also nil) has nothing
  # to plan and is dropped.
  defp classify_entries(entries) do
    {ambiguous, normal} = Enum.split_with(entries, & &1.ambiguous)
    {with_folder, without_folder} = Enum.split_with(normal, & &1.folder)
    relocated = Enum.filter(without_folder, & &1.relocated)

    grouped = Enum.group_by(with_folder, & &1.folder.uuid)

    {shared, unique} =
      Enum.reduce(grouped, {[], []}, fn {_uuid, group}, {shared_acc, unique_acc} ->
        if length(group) > 1 do
          {[group | shared_acc], unique_acc}
        else
          {shared_acc, group ++ unique_acc}
        end
      end)

    {unique, ambiguous, shared, relocated}
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` (or
  # an accepted `"name (N)"` suffix variant) is a no-op — filtered here
  # since this Source has no core `Action.noop?/1` to lean on, and (unlike
  # catalogue) never has an `after_move` to keep the action alive for.
  # D3: pointer-less — a taken destination is `:report`ed, never
  # `:suffix`ed (this module's own lookup never searches for a suffixed
  # name, so a renamed winner would be orphaned from its project).
  defp build_move_action(%{
         project: project,
         folder: folder,
         parent_uuid: parent_uuid,
         name: name
       }) do
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
        counts: nil,
        on_conflict: :report,
        after_move: nil
      }
    end
  end

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: folder_name}, parent_uuid, name) do
    suffixed_variant?(folder_name, name)
  end

  defp noop_move?(_folder, _parent_uuid, _name), do: false

  defp suffixed_variant?(folder_name, name) do
    Regex.match?(~r/^#{Regex.escape(name)} \(\d+\)$/, folder_name)
  end

  defp build_relocated_action(%{project: project, relocated: folder}) do
    %{
      source: "projects",
      kind: :relocated,
      label: project.name,
      op: :report,
      folder: folder,
      counts: nil,
      reason:
        "legacy folder #{folder.name} (#{folder.uuid}) is live away from root and the resolved " <>
          "parent — move it manually"
    }
  end

  defp build_ambiguous_duplicate_action(%{project: project, ambiguous: {f1, f2}}) do
    %{
      source: "projects",
      kind: :duplicate,
      label: project.name,
      op: :report,
      counts: nil,
      reason:
        "legacy folder found live in two places (#{f1.uuid} and #{f2.uuid}) — pick one and " <>
          "remove the other"
    }
  end

  defp build_shared_duplicate_action([%{folder: folder} | _] = group) do
    labels = group |> Enum.map(& &1.project.name) |> Enum.uniq() |> Enum.join(", ")

    %{
      source: "projects",
      kind: :duplicate,
      label: folder.name,
      op: :report,
      counts: nil,
      reason: "folder #{folder.uuid} is claimed by more than one project: #{labels}"
    }
  end

  # One query for every distinct {name, parent_uuid} pair the batch needs —
  # not a query per project. `name_fun` selects `desired.name` (host-name
  # tier) or `desired.deterministic_name` (legacy-name tier); both share
  # this shape. Live folders only (X2 — the unique index is partial, a
  # trashed twin must not hide the live folder).
  defp preload_pairs(desired, name_fun) do
    pairs =
      desired
      |> Enum.map(&{name_fun.(&1), &1.parent_uuid})
      |> Enum.reject(fn {_name, parent_uuid} -> is_nil(parent_uuid) end)
      |> Enum.uniq()

    names = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    parents = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    if names == [] or parents == [] do
      %{}
    else
      Folder
      |> where([f], f.name in ^names and f.parent_uuid in ^parents and is_nil(f.trashed_at))
      |> repo().all()
      |> Map.new(&{{&1.name, &1.parent_uuid}, &1})
    end
  end

  # One query for every distinct deterministic name in the batch, at root.
  # Live only (X2).
  defp preload_by_root_name(names) do
    case names |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.parent_uuid) and is_nil(f.trashed_at))
        |> repo().all()
        |> Map.new(&{&1.name, &1})
    end
  end

  # One query for every distinct deterministic name in the batch, live,
  # regardless of parent — oldest wins per name, mirroring
  # `Attachments.find_folder_anywhere/1`'s `order_by: [asc: :inserted_at],
  # limit: 1`, batched instead of one query per name. Used only to detect a
  # relocated candidate (X9) — never as a match a `:move` is planned for.
  defp preload_by_anywhere_name(names) do
    case names |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.trashed_at))
        |> order_by([f], asc: f.inserted_at)
        |> repo().all()
        |> Enum.reduce(%{}, &Map.put_new(&2, &1.name, &1))
    end
  end

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`project-<uuid>`) at the media root or under a
  # parent this batch's hooks resolved to, whose uuid no longer names any
  # project row (D4 — a hard delete is the only way a project stops
  # existing; archived projects are live) is reported so a host can
  # collect it. Never `:move`d or `:trash`ed here — a legacy folder that
  # IS a live project's current folder is left to `build_move_action/1`
  # above.
  defp orphan_actions(resolved_parents) do
    case legacy_candidate_folders(resolved_parents) do
      [] ->
        []

      candidates ->
        records_by_uuid = load_candidate_records(candidates)
        counts = counts_by_folder(Enum.map(candidates, fn {folder, _uuid} -> folder.uuid end))

        candidates
        |> Enum.map(&orphan_action(&1, records_by_uuid, counts))
        |> Enum.reject(&is_nil/1)
    end
  end

  # One SQL-filtered query (X6 — prefix filter in SQL, not loaded then
  # filtered in Elixir) for every live folder at root or under a resolved
  # parent whose name starts with the legacy prefix.
  defp legacy_candidate_folders(parent_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> where([f], like(f.name, ^"#{@legacy_prefix}%"))
    |> repo().all()
    |> Enum.map(&{&1, legacy_uuid(&1.name)})
    |> Enum.filter(fn {_folder, uuid} -> uuid end)
  end

  # X7: a strict UUID regex on the suffix (36-char canonical form) — not
  # `Ecto.UUID.cast/1`, which also accepts a raw 16-byte binary and, kept
  # verbatim rather than the cast's normalised value, an uppercase suffix
  # that would never match the (lowercase) record uuid it belongs to.
  defp legacy_uuid(name) do
    suffix = String.replace_prefix(name, @legacy_prefix, "")

    if Regex.match?(@uuid_regex, suffix) do
      String.downcase(suffix)
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

  defp orphan_action({folder, uuid}, records_by_uuid, counts) do
    case Map.get(records_by_uuid, uuid) do
      nil ->
        folder_counts = folder_counts(counts, folder.uuid)

        %{
          source: "projects",
          kind: :orphan,
          op: :report,
          label: folder.name,
          folder: folder,
          counts: folder_counts,
          reason: "record missing, #{elem(folder_counts, 0)} file(s)"
        }

      %Project{} ->
        nil
    end
  end

  # ── Shared helpers ───────────────────────────────────────────────

  # X1: two grouped queries (files by folder_uuid, links by folder_uuid)
  # per call — never a query per action. Counts ALL rows regardless of
  # status (including trashed files) — the core engine re-measures the
  # same way at apply time (any row with this `folder_uuid`) and aborts
  # the action on a mismatch, so a plan-time count that excluded trashed
  # files would fail every folder holding one.
  defp counts_by_folder(folder_uuids) do
    case Enum.uniq(folder_uuids) do
      [] ->
        {%{}, %{}}

      uuids ->
        files =
          File
          |> where([f], f.folder_uuid in ^uuids)
          |> group_by([f], f.folder_uuid)
          |> select([f], {f.folder_uuid, count(f.uuid)})
          |> repo().all()
          |> Map.new()

        links =
          FolderLink
          |> where([l], l.folder_uuid in ^uuids)
          |> group_by([l], l.folder_uuid)
          |> select([l], {l.folder_uuid, count(l.uuid)})
          |> repo().all()
          |> Map.new()

        {files, links}
    end
  end

  defp folder_counts({files, links}, folder_uuid) do
    {Map.get(files, folder_uuid, 0), Map.get(links, folder_uuid, 0)}
  end

  # Fills `counts: nil` placeholders left by `build_move_action/1` and
  # `build_relocated_action/1` with a single batched lookup across every
  # folder-bearing action — the whole resource-plan's counts come from one
  # pair of grouped queries (X1), not one pair per action.
  defp finalize_counts(actions) do
    counts =
      actions
      |> Enum.map(fn
        %{folder: %Folder{uuid: uuid}} -> uuid
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> counts_by_folder()

    Enum.map(actions, fn
      %{folder: %Folder{uuid: uuid}} = action -> %{action | counts: folder_counts(counts, uuid)}
      action -> action
    end)
  end

  defp live_projects do
    repo().all(Project)
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
