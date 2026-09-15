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
  entirely untouched: `plan/2`'s move-planning half runs, and the hooks
  are called, only when the env is set — never a single move or report
  for a legacy folder sitting somewhere other than root (see "Move
  planning"). The orphan scan is independent of the hook and always runs
  (root-only when no parent is resolved); it is a `:report`, so it is
  produced with or without a configured hook (E1 — a source with no hook
  still emits report-only housekeeping, never a `:move`/`:trash`).

  ## Move planning

  For each live project (D4 — **archived is live**; only a hard-deleted
  project, i.e. no matching row at all, makes an orphan):

  1. A project is a *candidate* when it has a live folder anywhere named
     after its legacy deterministic name (`project-<uuid>`, resolved
     without calling any hook — one batched query for the whole plan). A
     project with nothing named after it is left alone: nothing exists to
     move, and the host's hooks are never called for it. Candidate rows
     are light-selected (R9) — only the columns the plan and the hooks
     need, never the whole jsonb-bearing row.
  2. Only for candidates, the parent hook runs once, called directly
     (guarded against raising/exiting/returning anything but `{:ok, uuid}`
     or an explicit `nil` — R2): a hook FAILURE skips the project (no move
     planned for it, never treated as "root") and is counted into one
     `kind: :hook_error` report for the whole plan; only an explicit `nil`
     means root. The name hook (`Attachments.folder_name/2`) runs once
     too — it already falls back to the deterministic name on its own
     failure, so it needs no separate failure report. When the parent hook
     resolves `nil` the host name is **not** used as the desired name
     either: `find_resource_folder/2` only ever looks for a host name
     *under a parent*, so without one the desired name stays the
     deterministic `project-<uuid>` name — a project whose parent hook
     answers `nil` this run (while the name hook still answers a host
     name) must not have its root folder renamed to that host name, or
     `find_resource_folder/2` can no longer find it there on the next
     read.
  3. The candidate's *current* folder is looked up, in the module's own
     order, only at the resolved parent (host name, then deterministic
     name) and at root (deterministic name) — never the unrestricted
     "anywhere" scan `find_resource_folder/2` falls back to for a live
     upload. A legacy folder that exists live only somewhere else (the
     owner moved it, or it is still parked under a parent the project was
     since unlinked from) is reported as `kind: :relocated`, never moved —
     the parent hook can be actor-dependent, so the reason notes that a
     different actor's hook may still resolve it (E6).
  4. A live match at more than one of these tiers (host-named-under-parent,
     deterministic-named-under-parent, deterministic-named-at-root) is
     unresolvable — reported as `kind: :duplicate`, nothing moved, naming
     every folder found. Two (or more) projects whose current folder
     resolves to the very same live folder (e.g. two projects sharing a
     parent and a colliding host name) are likewise reported as
     `kind: :duplicate`, no move for either.
  5. Two (or more) projects whose *desired* destination coincides (the
     same resolved parent and the same desired name) even though their
     *current* folders differ are reported `kind: :duplicate` instead of
     both being planned as moves — the second move would collide with the
     first at apply time (R7).
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage.{Folder, FolderLink}
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
    {resource_actions, resolved_parents, claimed_uuids} = resource_plan(actor_uuid)

    resource_actions ++ orphan_actions(resolved_parents, claimed_uuids)
  end

  # ── Projects ─────────────────────────────────────────────────────

  defp resource_plan(actor_uuid) do
    if hook_configured?() do
      build_resource_plan(light_projects(), actor_uuid)
    else
      {[], [], claimed_folder_uuids([], [], [], [])}
    end
  end

  defp hook_configured? do
    case Application.get_env(:phoenix_kit_projects, :attachments_parent_folder) do
      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        Code.ensure_loaded?(mod) and
          (function_exported?(mod, fun, 3) or function_exported?(mod, fun, 2))

      _ ->
        false
    end
  end

  # Candidate detection needs no hook call: a live folder anywhere named
  # after the project's legacy name (one batched query for the whole
  # plan). Only candidates go on to have the host's parent/name hooks
  # resolved — a project with nothing pointing at it never triggers a
  # (possibly writing) host hook. See moduledoc "Move planning".
  defp build_resource_plan(projects, actor_uuid) do
    candidate_uuids = candidate_project_uuids()
    candidates = Enum.filter(projects, &MapSet.member?(candidate_uuids, &1.uuid))

    {mod, fun} = Application.get_env(:phoenix_kit_projects, :attachments_parent_folder)

    {desired, hook_error_count} = resolve_desired(candidates, mod, fun, actor_uuid)

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
    {converging, solo} = split_converging(unique)

    # A project whose current folder WAS resolved (unique or shared) can
    # still leave a SEPARATE legacy-named folder live somewhere else
    # entirely (an old container, or a duplicate from before parent hooks
    # existed) — that stray twin is neither this project's current folder
    # nor an orphan (the project is alive), so it gets its own
    # `:relocated` report alongside whatever action the project itself
    # gets. Mirrors catalogue's `stray_legacy` handling.
    stray_actions =
      entries
      |> Enum.filter(& &1.stray_legacy)
      |> Enum.map(&build_relocated_action(%{&1 | relocated: &1.stray_legacy}))

    move_actions = solo |> Enum.map(&build_move_action/1) |> Enum.reject(&is_nil/1)
    relocated_actions = Enum.map(relocated, &build_relocated_action/1)
    dup_actions = Enum.map(ambiguous, &build_ambiguous_duplicate_action/1)
    shared_actions = Enum.map(shared, &build_shared_duplicate_action/1)
    converging_actions = Enum.map(converging, &build_converging_duplicate_action/1)
    hook_error_actions = hook_error_action(hook_error_count)

    actions =
      finalize_counts(move_actions ++ relocated_actions ++ stray_actions) ++
        dup_actions ++ shared_actions ++ converging_actions ++ hook_error_actions

    claimed_uuids = claimed_folder_uuids(unique, ambiguous, shared, converging)

    {actions, resolved_parents, claimed_uuids}
  end

  # R2: resolves each candidate's parent via the host's own hook, called
  # directly (never through `Attachments.parent_folder_uuid/2`, which
  # swallows a raise/bad-return into `nil` and would make a hook FAILURE
  # indistinguishable from an explicit "root"). A failure skips the
  # project entirely (no move planned) and is tallied into one
  # `hook_error_count` for the whole plan instead.
  defp resolve_desired(candidates, mod, fun, actor_uuid) do
    {desired, errors} =
      Enum.reduce(candidates, {[], 0}, fn project, {acc, errs} ->
        case resolve_parent(mod, fun, :project, actor_uuid, project) do
          {:ok, parent_uuid} ->
            deterministic_name = Attachments.folder_name(project.uuid)
            host_name = Attachments.folder_name(project, actor_uuid)
            name = if parent_uuid, do: host_name, else: deterministic_name

            entry = %{
              project: project,
              parent_uuid: parent_uuid,
              name: name,
              deterministic_name: deterministic_name
            }

            {[entry | acc], errs}

          :error ->
            {acc, errs + 1}
        end
      end)

    {Enum.reverse(desired), errors}
  end

  defp resolve_parent(mod, fun, kind, actor_uuid, resource) do
    cond do
      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 3) ->
        guarded_hook_call(fn -> apply(mod, fun, [kind, actor_uuid, resource]) end)

      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 2) ->
        guarded_hook_call(fn -> apply(mod, fun, [kind, actor_uuid]) end)

      true ->
        :error
    end
  end

  defp guarded_hook_call(fun) do
    case fun.() do
      {:ok, uuid} when is_binary(uuid) -> {:ok, uuid}
      {:ok, nil} -> {:ok, nil}
      nil -> {:ok, nil}
      _other -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp hook_error_action(0), do: []

  defp hook_error_action(count) do
    [
      %{
        source: "projects",
        kind: :hook_error,
        op: :report,
        label: "attachments parent hook",
        counts: nil,
        reason:
          "#{count} record(s) skipped: the configured parent hook raised, exited, or " <>
            "returned neither {:ok, uuid} nor nil"
      }
    ]
  end

  # One batched query for the whole plan: every live folder named after
  # the legacy `project-<uuid>` pattern, anywhere. Only a project whose
  # uuid appears in this set is a candidate — see `build_resource_plan/2`.
  defp candidate_project_uuids do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], like(f.name, ^"#{@legacy_prefix}%"))
    |> select([f], f.name)
    |> repo().all()
    |> Enum.map(&legacy_uuid/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # host-name-under-parent → deterministic-name-under-parent →
  # deterministic-name-at-root — the module's own order, restricted to
  # root and the resolved parent (X9 — unlike
  # `Attachments.find_resource_folder/2`, this never treats an
  # unrestricted "anywhere" hit as the current folder to move; it is only
  # used below to tell a genuinely absent candidate apart from one that is
  # live but relocated). A live match at more than one of these tiers is
  # ambiguous.
  #
  # `by_anywhere` (every live folder anywhere named after the
  # project's legacy name) also surfaces a STRAY twin: when a single
  # restricted match IS found, any other live folder sharing the legacy
  # name elsewhere (a third parent, neither root nor the resolved
  # parent) is a separate leftover — never this project's current
  # folder, never an orphan (the project is alive) — so it is kept as
  # `stray_legacy` and reported `:relocated` alongside whatever action
  # the project itself gets (see `build_resource_plan/2`).
  defp resolve_entry(d, by_parent_host, by_parent_deterministic, by_root, by_anywhere) do
    host_match = d.parent_uuid && Map.get(by_parent_host, {d.name, d.parent_uuid})

    det_parent_match =
      d.parent_uuid && Map.get(by_parent_deterministic, {d.deterministic_name, d.parent_uuid})

    root_match = Map.get(by_root, d.deterministic_name)

    matches =
      [host_match, det_parent_match, root_match]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.uuid)

    anywhere = Map.get(by_anywhere, d.deterministic_name, [])

    case matches do
      [] ->
        Map.merge(d, %{
          folder: nil,
          ambiguous: nil,
          relocated: List.first(anywhere),
          stray_legacy: nil
        })

      [folder] ->
        stray = Enum.find(anywhere, &(&1.uuid != folder.uuid))
        Map.merge(d, %{folder: folder, ambiguous: nil, relocated: nil, stray_legacy: stray})

      matches ->
        Map.merge(d, %{folder: nil, ambiguous: matches, relocated: nil, stray_legacy: nil})
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

  # R7/E3: two (or more) `unique` entries whose *desired* target (resolved
  # parent + desired name) coincide, even though their current folders
  # differ — the second move would collide with the first at apply time.
  # Order-preserving (a plain `group_by` would scramble R10's enumeration
  # order).
  defp split_converging(entries) do
    freq = Enum.frequencies_by(entries, &convergence_key/1)

    {converging_entries, solo} =
      Enum.split_with(entries, &(Map.get(freq, convergence_key(&1)) > 1))

    converging_groups = converging_entries |> Enum.group_by(&convergence_key/1) |> Map.values()
    {converging_groups, solo}
  end

  defp convergence_key(entry), do: {entry.parent_uuid, entry.name}

  # R4/§9: every folder this batch has already resolved as a live project's
  # current folder — a unique move/no-op target, every folder listed in an
  # ambiguous match, and every folder claimed by a shared or converging
  # group — must never also be reported `:orphan` below, even when its
  # literal name embeds a different (deleted) project's uuid (e.g. a naive
  # host-name hook that happens to return that stray name). Mirrors
  # catalogue's `claimed_folder_uuids/4`.
  defp claimed_folder_uuids(unique, ambiguous, shared_groups, converging_groups) do
    unique_uuids = Enum.map(unique, & &1.folder.uuid)

    ambiguous_uuids =
      Enum.flat_map(ambiguous, fn %{ambiguous: folders} -> Enum.map(folders, & &1.uuid) end)

    shared_uuids = Enum.flat_map(shared_groups, fn [%{folder: f} | _] -> [f.uuid] end)

    converging_uuids =
      Enum.flat_map(converging_groups, fn group -> Enum.map(group, & &1.folder.uuid) end)

    MapSet.new(unique_uuids ++ ambiguous_uuids ++ shared_uuids ++ converging_uuids)
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
    Regex.match?(~r/\A#{Regex.escape(name)} \(\d+\)\z/, folder_name)
  end

  # E6: the parent hook can be actor-dependent (`fun(kind, actor_uuid,
  # resource)`), so a folder this run's actor can't place is not
  # necessarily unreachable for every actor — the reason says so rather
  # than implying the folder is permanently stuck.
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
          "parent — left alone (the parent hook may resolve it for other actors); move it manually"
    }
  end

  defp build_ambiguous_duplicate_action(%{project: project, ambiguous: folders}) do
    places = Enum.map_join(folders, ", ", & &1.uuid)

    %{
      source: "projects",
      kind: :duplicate,
      label: project.name,
      op: :report,
      counts: nil,
      reason:
        "legacy folder found live in #{length(folders)} places (#{places}) — pick one and " <>
          "remove the rest"
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

  defp build_converging_duplicate_action([entry | _] = group) do
    labels = group |> Enum.map(& &1.project.name) |> Enum.uniq() |> Enum.join(", ")
    parent_label = entry.parent_uuid || "root"

    %{
      source: "projects",
      kind: :duplicate,
      label: labels,
      op: :report,
      counts: nil,
      reason:
        "multiple projects would move to the same destination (parent #{parent_label}, " <>
          "name #{entry.name}): #{labels}"
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
  # regardless of parent, grouped by name (oldest first per group,
  # mirroring `Attachments.find_folder_anywhere/1`'s
  # `order_by: [asc: :inserted_at]`) — batched instead of one query per
  # name. Used to detect a relocated candidate when no restricted match
  # exists at all (X9 — the first/oldest of the group), and to detect a
  # stray legacy-named twin when a restricted match WAS found (any other
  # live folder in the group, `resolve_entry/5`) — never as a match a
  # `:move` is planned for.
  defp preload_by_anywhere_name(names) do
    case names |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.trashed_at))
        |> order_by([f], asc: f.inserted_at)
        |> repo().all()
        |> Enum.group_by(& &1.name)
    end
  end

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`project-<uuid>`) at the media root or under a
  # parent this batch's hooks resolved to, whose uuid no longer names any
  # project row (D4 — a hard delete is the only way a project stops
  # existing; archived projects are live) is reported so a host can
  # collect it. Never `:move`d or `:trash`ed here — this module owns no
  # "orphans" container; a legacy folder claimed by a live project (its
  # current folder, a duplicate, or a converging-target group) is excluded
  # (R4 — one folder gets at most one action).
  defp orphan_actions(resolved_parents, claimed_uuids) do
    case legacy_candidate_folders(resolved_parents, claimed_uuids) do
      [] ->
        []

      candidates ->
        existing_uuids = load_candidate_records(candidates)
        counts = counts_by_folder(Enum.map(candidates, fn {folder, _uuid} -> folder.uuid end))

        candidates
        |> Enum.map(&orphan_action(&1, existing_uuids, counts))
        |> Enum.reject(&is_nil/1)
    end
  end

  # One SQL-filtered query (X6 — prefix filter in SQL, not loaded then
  # filtered in Elixir) for every live folder at root or under a resolved
  # parent whose name starts with the legacy prefix, minus every folder
  # already claimed by a live project (R4 — see `claimed_folder_uuids/4`).
  defp legacy_candidate_folders(parent_uuids, claimed_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> where([f], like(f.name, ^"#{@legacy_prefix}%"))
    |> repo().all()
    |> Enum.reject(&MapSet.member?(claimed_uuids, &1.uuid))
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
  # R9: only the uuid column — an orphan report needs nothing else off the
  # record (existence alone decides it).
  defp load_candidate_records(candidates) do
    uuids = candidates |> Enum.map(fn {_folder, uuid} -> uuid end) |> Enum.uniq()

    Project
    |> where([p], p.uuid in ^uuids)
    |> select([p], p.uuid)
    |> repo().all()
    |> MapSet.new()
  end

  defp orphan_action({folder, uuid}, existing_uuids, counts) do
    if MapSet.member?(existing_uuids, uuid) do
      nil
    else
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
          PhoenixKit.Modules.Storage.File
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

  # R9/R10: only the columns the plan and the host's hooks need — never
  # the whole row (`description`/`translations`/`settings` are unbounded
  # text/jsonb this module never reads) — ordered by `inserted_at`/`uuid`
  # for a deterministic report order.
  defp light_projects do
    Project
    |> order_by([p], asc: p.inserted_at, asc: p.uuid)
    |> select(
      [p],
      struct(p, [
        :uuid,
        :name,
        :is_template,
        :archived_at,
        :status_entity_uuid,
        :current_status_slug,
        :external_id,
        :assigned_team_uuid,
        :assigned_department_uuid,
        :assigned_person_uuid,
        :inserted_at
      ])
    )
    |> repo().all()
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
