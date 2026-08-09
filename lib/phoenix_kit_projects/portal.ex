defmodule PhoenixKitProjects.Portal do
  @moduledoc """
  The public portal (Phase J): anonymous issue submission + a read-only
  public issue list + a status summary for one project, behind a random
  capability slug. Security model per the 2026-08-06 design doc + the
  external security panel's findings, folded in:

    * **The slug is the grant** — CSPRNG, ~22 chars, regenerable
      (`rotate_slug/2`); rotation broadcasts so LIVE portal sessions
      downgrade immediately (panel #7).
    * **One whitelisting doorway** — every public read goes through
      `public_view/1`, which returns plain DTO maps (never structs, so
      an LV can't over-assign internal fields — panel #5) and scopes
      every query from the portal row + `public == true` (panel #6).
    * **Uniform failure** — unknown slug, disabled extension, disabled
      capability all collapse to `:error` (panel #11).
    * **Rate limiting lives in the submit path itself** (panel #2), keyed
      on the PEER address (never XFF — panel #3), IPv6 bucketed at /64
      and a per-project global ceiling on top (panel #8). A limiter
      failure DENIES (fail-closed).
    * **No submitter email in v1** — the notify-submitter feature needs
      double-opt-in (panel #1); collecting nothing eliminates the
      mail-bomb + header-injection surface. Submissions notify project
      MEMBERS through the Phase H fan-out instead.
    * `ip_hash` is a truncated peppered HMAC (panel #12) — abuse
      telemetry only.

  ## Host requirement for per-IP limits

  The peer address comes from LiveView's `get_connect_info(socket,
  :peer_data)`, which is only populated when the HOST endpoint's socket
  declares it — `socket "/live", ..., websocket: [connect_info:
  [:peer_data, session: ...]]`. Without it every submitter shares one
  bucket (still fail-closed — stricter, not weaker — and the per-project
  ceiling is IP-independent). Hosts behind a proxy additionally need
  RemoteIp (or equivalent) terminating XFF BEFORE Phoenix; this module
  never parses forwarded headers itself.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ImageProcessor
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.Extensions
  alias PhoenixKitProjects.Features
  alias PhoenixKitProjects.Members
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Assignment
  alias PhoenixKitProjects.Schemas.Portal, as: PortalRow
  alias PhoenixKitProjects.Schemas.PortalSubmission
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Components.AssignmentStatusBadge

  @ext_key "portal"
  @title_max 200
  @description_max 5000
  # Draft limits from the design doc (panel saw and did not object to the
  # numbers, only to WHERE they run): 5/min + 30/day per peer bucket,
  # plus a project-wide 100/day ceiling independent of IP (panel #8).
  @per_ip_minute {60_000, 5}
  @per_ip_day {86_400_000, 30}
  @per_project_day {86_400_000, 100}
  # Submissions arriving faster than this after mount are bots (the
  # min-fill-time check; the form carries the mount monotonic time).
  # Overridable so the test env doesn't sleep through it.
  @min_fill_ms 3_000
  # Three images, 5 MB each after re-encoding. A bug report needs a
  # screenshot or three; the rest is someone else's storage bill.
  @attachment_max_count 3
  @attachment_max_bytes 5_000_000
  defp min_fill_ms,
    do: Application.get_env(:phoenix_kit_projects, :portal_min_fill_ms, @min_fill_ms)

  # ── Enablement / slug lifecycle ─────────────────────────────────

  @doc "The portal row for a project, or nil."
  @spec get_portal(binary()) :: PortalRow.t() | nil
  def get_portal(project_uuid) when is_binary(project_uuid) do
    RepoHelper.repo().get_by(PortalRow, project_uuid: project_uuid)
  rescue
    _ -> nil
  end

  @doc """
  Ensures the project has a portal row (fresh slug on first enable).
  The extension's `on_enable` callback — idempotent, keeps the existing
  slug on re-enable (the link keeps working across toggles; rotation is
  the explicit revoke).
  """
  @spec ensure_portal(binary(), map()) :: :ok
  def ensure_portal(project_uuid, _config \\ %{}) do
    case get_portal(project_uuid) do
      %PortalRow{} ->
        :ok

      nil ->
        %PortalRow{}
        |> PortalRow.changeset(%{
          project_uuid: project_uuid,
          slug: PortalRow.generate_slug()
        })
        |> RepoHelper.repo().insert()
        |> case do
          {:ok, _} -> :ok
          {:error, _} -> :ok
        end
    end
  rescue
    _ -> :ok
  end

  @doc """
  Regenerates the slug — the revoke: the old link 404s and every LIVE
  portal session on the old slug downgrades (the `:portal_rotated`
  broadcast, panel #7).
  """
  @spec rotate_slug(binary(), keyword()) :: {:ok, PortalRow.t()} | {:error, term()}
  def rotate_slug(project_uuid, opts \\ []) do
    case get_portal(project_uuid) do
      nil ->
        {:error, :no_portal}

      portal ->
        portal
        |> Ecto.Changeset.change(slug: PortalRow.generate_slug())
        |> RepoHelper.repo().update()
        |> case do
          {:ok, updated} ->
            Activity.log("projects.portal_link_rotated",
              actor_uuid: Keyword.get(opts, :actor_uuid),
              resource_type: "project",
              resource_uuid: project_uuid
            )

            ProjectsPubSub.broadcast_project(:portal_rotated, %{uuid: project_uuid})
            {:ok, updated}

          error ->
            error
        end
    end
  end

  # ── The public doorway ──────────────────────────────────────────

  @doc """
  Resolves a slug to `{:ok, portal, project}` iff the portal extension is
  enabled for that project. EVERY failure mode is the same `:error`
  (panel #11 — errors must not enumerate portals or capabilities).
  """
  @spec resolve(term()) :: {:ok, PortalRow.t(), map()} | :error
  def resolve(slug, viewer \\ nil)

  def resolve(slug, viewer) when is_binary(slug) and byte_size(slug) in 3..64 do
    with {:ok, portal, project} <- resolvable_row(slug),
         true <- mode_admits?(portal, viewer) do
      {:ok, portal, project}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def resolve(_, _), do: :error

  # Everything that makes a slug real, EXCEPT who the mode lets in. Shared
  # so the header/oracle path can ask "is this a live portal?" without
  # answering "may this particular visitor enter?".
  defp resolvable_row(slug) when is_binary(slug) and byte_size(slug) in 3..64 do
    with %PortalRow{} = portal <- RepoHelper.repo().get_by(PortalRow, slug: slug),
         %{} = project <- Projects.get_project(portal.project_uuid),
         true <- project.is_template == false,
         true <- Extensions.enabled?(project, @ext_key) do
      {:ok, portal, project}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp resolvable_row(_), do: :error

  # Who the mode lets through the door. `link` asks nothing beyond holding
  # the slug — that IS the grant. `members` asks for any signed-in site
  # account (not a project role: project people have the admin app and
  # don't need the portal to read the board). `public` asks nothing.
  #
  # A failure here is indistinguishable from an unknown slug by design: the
  # uniform `:error` is what stops the portal being an oracle for which
  # projects exist.
  defp mode_admits?(%PortalRow{access_mode: "members"}, viewer), do: signed_in?(viewer)
  defp mode_admits?(_portal, _viewer), do: true

  defp signed_in?(%{user: %{uuid: uuid}}) when is_binary(uuid), do: true
  defp signed_in?(%{uuid: uuid}) when is_binary(uuid), do: true
  defp signed_in?(_), do: false

  @doc """
  The access mode behind a slug, for decisions that must be made BEFORE the
  page renders — the response headers, chiefly.

  Returns `"link"` for anything it cannot confirm: an unknown slug, a
  database error, a portal whose extension is off. The restrictive answer
  is the safe one, so it is also the default.
  """
  @spec access_mode_of(String.t()) :: String.t()
  def access_mode_of(slug) when is_binary(slug) do
    # Through the same checks `resolve/2` makes, minus the mode admission
    # itself. A bare row lookup would answer "members" for a portal whose
    # extension is switched off, and the sign-in page that answer produces
    # would confirm the slug exists — breaking the uniform-failure rule the
    # portal's whole error story rests on.
    case resolvable_row(slug) do
      {:ok, %PortalRow{access_mode: mode}, _project} when mode in ["link", "members", "public"] ->
        mode

      _ ->
        "link"
    end
  rescue
    _ -> "link"
  catch
    :exit, _ -> "link"
  end

  def access_mode_of(_), do: "link"

  @doc """
  The portal and project behind a slug, but ONLY when it is a public board.

  For the response-header and social-preview decisions, which are made
  before the page renders and must be conservative: anything this cannot
  confirm is a portal to be treated as secret.
  """
  @spec get_public_board(String.t()) :: {:ok, PortalRow.t(), map()} | :none
  def get_public_board(slug) when is_binary(slug) do
    case resolve(slug, nil) do
      {:ok, %PortalRow{access_mode: "public"} = portal, project} -> {:ok, portal, project}
      _ -> :none
    end
  end

  def get_public_board(_), do: :none

  @doc "Whether a portal capability flag is on for the project."
  @spec capability?(map(), :submit | :list | :status) :: boolean()
  def capability?(project, cap) when cap in [:submit, :list, :status] do
    Features.on?(project, "portal_#{cap}")
  rescue
    _ -> false
  end

  @doc """
  The whole public read surface as ONE plain-map DTO — the whitelist
  (panel #5/#6). Returns `{:ok, view}` or the uniform `:error`.

  The DTO contains exactly: `project_name`, `project_status`,
  `started_at`, `completed_at`, `capabilities`, `issue_counts`, and
  `issues` (each: `title`, `status`, `status_label`, `inserted_at`,
  `updated_at`). Nothing else — no assignees, estimates, money, AI
  figures, or internal notes, ever.
  """
  @spec public_view(term()) :: {:ok, map()} | :error
  def public_view(slug, viewer \\ nil) do
    with {:ok, portal, project} <- resolve(slug, viewer) do
      issues = if capability?(project, :list), do: public_issues(portal, project), else: []

      {:ok,
       %{
         project_name: project.name,
         project_status: Project.derived_status(project),
         started_at: project.started_at,
         completed_at: project.completed_at,
         access_mode: portal.access_mode,
         capabilities: %{
           submit: capability?(project, :submit),
           list: capability?(project, :list),
           status: capability?(project, :status)
         },
         # What THIS viewer may do, resolved once here rather than
         # recomputed in the template — the page must never offer a control
         # the server would refuse.
         may_submit: may_submit?(portal, project, viewer),
         may_comment: may_comment?(portal, project, viewer),
         issue_counts: Enum.frequencies_by(issues, & &1.status),
         issues: issues
       }}
    end
  end

  # Scoped FROM the portal row (panel #6): project filter + public flag in
  # one query; titles resolve through the same label path the admin uses.
  # Status labels come from the ASSIGNMENT status vocabulary
  # (todo/in_progress/done — AssignmentStatusBadge), not the project's
  # lifecycle status set.
  # `public == true` has meant "visible to whoever holds the secret link"
  # since the portal shipped, and staff flagged tasks under exactly that
  # understanding. A PUBLIC board is a different audience — the open web
  # and its crawlers — so it requires a second, deliberate act:
  # `board_published_at`. Without this split, flipping a project to
  # `public` would retroactively publish years of tasks that were flagged
  # for an audience of one client.
  #
  # `link` and `members` keep the original rule exactly, so nothing about
  # an existing portal changes.
  defp public_issues(%PortalRow{} = portal, _project) do
    portal
    |> issues_query()
    |> RepoHelper.repo().all()
    |> decorate_issues()
  rescue
    _ -> []
  end

  defp issues_query(%PortalRow{project_uuid: project_uuid, access_mode: "public"}) do
    from(a in Assignment,
      where:
        a.project_uuid == ^project_uuid and a.public == true and
          not is_nil(a.board_published_at),
      order_by: [desc: a.inserted_at],
      limit: 200,
      preload: [:task, :child_project]
    )
  end

  defp issues_query(%PortalRow{project_uuid: project_uuid}) do
    from(a in Assignment,
      where: a.project_uuid == ^project_uuid and a.public == true,
      order_by: [desc: a.inserted_at],
      limit: 200,
      preload: [:task, :child_project]
    )
  end

  # One shaping function for every mode. The DTO does NOT widen for a
  # public board: if a field is too hot to show a link-holder it is far too
  # hot to show a crawler, and per-mode field lists are how that discipline
  # rots.
  defp decorate_issues(rows) do
    lang = PhoenixKitProjects.L10n.current_content_lang()

    Enum.map(rows, fn a ->
      %{
        # The uuid is an ADDRESS here, not a leak: it links to a page whose
        # entire contents are already visible to whoever can see this list,
        # and without it the discussion page is unreachable from the board.
        # Per-board numbers would read better and are what a mature tracker
        # does; they need a column, a backfill and a uniqueness story, so
        # they are a later nicety rather than a blocker.
        uuid: a.uuid,
        title: Assignment.label(a, lang) || "Issue",
        status: a.status,
        status_label: AssignmentStatusBadge.label(a.status),
        inserted_at: a.inserted_at,
        updated_at: a.updated_at
      }
    end)
  end

  @doc """
  The comments namespace a PUBLIC board discussion lives in.

  Deliberately NOT the `"assignment"` type the admin hub uses for staff
  discussion on the same task. They are two conversations about one piece
  of work: one internal, one with the outside world. If these two strings
  ever converge, every internal note staff have written lands on a public
  page — so the value is named here rather than typed into a template.
  """
  @spec discussion_resource_type() :: String.t()
  def discussion_resource_type, do: "project_assignment"

  @doc """
  How many images one report may carry, and how large each may be.

  Small on purpose. A bug report needs a screenshot or three, and every
  megabyte past that is storage someone else is paying for on a page that
  accepts writes from strangers.
  """
  @spec attachment_limits() :: %{count: pos_integer(), bytes: pos_integer()}
  def attachment_limits, do: %{count: @attachment_max_count, bytes: @attachment_max_bytes}

  @doc """
  Turns uploaded temp files into storage uuids, or refuses.

  Every file is RE-ENCODED before it is stored — what ends up on disk is
  our encoder's output, not the uploader's bytes — so a polyglot, an EXIF
  payload or a trailing archive does not survive the trip. Anything that
  cannot be decoded as an image is refused whatever it was called.

  All-or-nothing: if one file can't be processed the whole report is
  refused, because a report that silently loses the screenshot it refers
  to is worse than one that says so.
  """
  @spec store_attachments([%{path: String.t(), name: String.t()}], binary() | nil) ::
          {:ok, [String.t()]} | {:error, :invalid}
  def store_attachments(files, project_uuid \\ nil)

  def store_attachments([], _project_uuid), do: {:ok, []}

  def store_attachments(files, project_uuid) when is_list(files) do
    # Core requires every file to have an owner (or to be a chunk of one),
    # and that invariant is what keeps orphans from accumulating — so
    # rather than weaken it, the file is attributed to the project's owner.
    # That is also who it genuinely belongs to: it arrived on their portal,
    # into their project, and their retention and quota should carry it.
    # `metadata.source` records that a stranger produced it.
    owner = project_owner_uuid(project_uuid)

    cond do
      length(files) > @attachment_max_count ->
        {:error, :invalid}

      is_nil(owner) ->
        # No owner to hold it: refuse rather than invent one.
        {:error, :invalid}

      true ->
        try do
          Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
            case store_one_attachment(file, owner) do
              {:ok, uuid} ->
                {:cont, {:ok, acc ++ [uuid]}}

              :error ->
                # All-or-nothing has to mean it. Dropping `acc` on the floor
                # leaves the files that already landed stored and referenced
                # by nothing — an orphan per failed attempt, from a caller
                # who needs no account to retry.
                discard_stored(acc)
                {:halt, {:error, :invalid}}
            end
          end)
        after
          # We copied these out of LiveView's ownership to win the race in
          # `take_screenshots`, so nobody else will clean them up.
          Enum.each(files, fn
            %{path: path} -> File.rm(path)
            _ -> :ok
          end)
        end
    end
  end

  def store_attachments(_files, _project_uuid), do: {:error, :invalid}

  defp discard_stored(uuids) do
    Enum.each(uuids, fn uuid ->
      try do
        Storage.delete_file(uuid)
      rescue
        _ -> :ok
      end
    end)
  end

  defp project_owner_uuid(nil), do: nil

  defp project_owner_uuid(project_uuid) do
    from(m in PhoenixKitProjects.Schemas.ProjectMember,
      where: m.project_uuid == ^project_uuid and m.role == "owner",
      order_by: [asc: m.inserted_at],
      limit: 1,
      select: m.user_uuid
    )
    |> RepoHelper.repo().one()
  rescue
    _ -> nil
  end

  defp store_one_attachment(%{path: path, name: name}, owner_uuid) do
    sanitized =
      Path.join(System.tmp_dir!(), "pk-portal-#{System.unique_integer([:positive])}.jpg")

    try do
      do_store_attachment(path, name, owner_uuid, sanitized)
    after
      # The re-encoded copy is scratch space — storage takes its own — so
      # leaving it behind fills /tmp one report at a time. `after` because
      # the failure paths need cleaning up just as much as the happy one.
      File.rm(sanitized)
    end
  end

  defp store_one_attachment(_file, _owner), do: :error

  defp do_store_attachment(path, name, owner_uuid, sanitized) do
    with {:ok, _} <- ImageProcessor.sanitize(path, sanitized, max_edge: 2000),
         %{size: size} when size > 0 and size <= @attachment_max_bytes <- File.stat!(sanitized),
         {:ok, %{uuid: uuid}} <-
           Storage.store_file(sanitized,
             filename: safe_filename(name),
             # The type we PRODUCED, never the one that was claimed.
             content_type: "image/jpeg",
             size_bytes: size,
             user_uuid: owner_uuid,
             metadata: %{"source" => "portal_submission"}
           ) do
      {:ok, uuid}
    else
      _ -> :error
    end
  end

  # The uploader named this file. It reaches a Content-Disposition header
  # and a filesystem, so it gets flattened to something boring.
  defp safe_filename(name) do
    base =
      name
      |> Kernel.to_string()
      |> Path.basename()
      |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
      |> String.slice(0, 60)

    if base in ["", ".", ".."], do: "screenshot.jpg", else: base
  end

  @doc """
  Deletes the images attached to an issue's submission.

  Call before deleting the issue itself. The submission row cascades with
  the assignment, but the storage rows do not — nothing points at them
  once the submission is gone, so without this every rejected report
  leaves its screenshots behind forever, owned by the project owner and
  invisible to everyone.

  Never blocks the delete: losing the issue matters more than reclaiming
  a file, and an orphaned file is recoverable where a blocked delete is a
  stuck queue.
  """
  @spec delete_attachments_for(binary()) :: :ok
  def delete_attachments_for(assignment_uuid) when is_binary(assignment_uuid) do
    from(sub in PortalSubmission, where: sub.assignment_uuid == ^assignment_uuid)
    |> RepoHelper.repo().all()
    |> Enum.flat_map(&(&1.file_uuids || []))
    |> Enum.each(fn uuid ->
      case Storage.get_file(uuid) do
        %{} = file -> Storage.delete_file(file)
        _ -> :ok
      end
    end)

    :ok
  rescue
    e ->
      Logger.warning("[Portal] could not clean up attachments: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  def delete_attachments_for(_), do: :ok

  # ── Participation ───────────────────────────────────────────────

  @doc """
  May this viewer SUBMIT an issue through the portal?

  Two gates, both of which must pass: the project's `portal_submit`
  capability (does the portal offer submission at all) and the portal's
  `submit_access` policy (who specifically). Fail-closed on anything
  unexpected.
  """
  @spec may_submit?(PortalRow.t(), map(), term()) :: boolean()
  def may_submit?(%PortalRow{} = portal, project, viewer) do
    capability?(project, :submit) and allows?(portal.submit_access, viewer)
  end

  @doc """
  May this viewer COMMENT on a board issue?

  Separate from submitting on purpose: a submission is invisible until
  staff act on it, while a comment is live the moment it lands. Defaults to
  `nobody`, so discussion is something a project turns on rather than
  something it discovers it had.

  `anyone` is deliberately NOT honoured yet — see `comment_access_note/0`.
  """
  @spec may_comment?(PortalRow.t(), map(), term()) :: boolean()
  def may_comment?(%PortalRow{} = portal, _project, viewer) do
    case portal.comment_access do
      "members" -> signed_in?(viewer)
      # Anonymous commenting needs an identity model that does not exist:
      # without one, "Alice from Acme" is a text field anyone can type. The
      # policy value is accepted and stored so the setting survives, but it
      # resolves to signed-in until guest identity ships.
      "anyone" -> signed_in?(viewer)
      _ -> false
    end
  end

  @doc """
  Why `anyone` currently behaves as `members` for commenting — shown in the
  admin UI so the setting doesn't lie about what it does.
  """
  @spec comment_access_note() :: String.t()
  def comment_access_note do
    "Anonymous commenting needs a guest identity model (a verified name and " <>
      "a way to moderate) that isn't built yet. Until then this behaves as " <>
      "\"signed-in users\"."
  end

  defp allows?("anyone", _viewer), do: true
  defp allows?("members", viewer), do: signed_in?(viewer)
  defp allows?(_, _viewer), do: false

  # ── Access mode ─────────────────────────────────────────────────

  @doc """
  Tasks already flagged `public` that a switch to `public` mode would
  expose — the number an admin has to see BEFORE flipping.

  They were flagged for an audience of "whoever holds the link". Publishing
  them to the open web is a different decision, and this is what makes it
  one someone takes rather than one that happens to them.
  """
  @spec board_exposure_count(binary()) :: non_neg_integer()
  def board_exposure_count(project_uuid) when is_binary(project_uuid) do
    from(a in Assignment,
      where: a.project_uuid == ^project_uuid and a.public == true,
      select: count(a.uuid)
    )
    |> RepoHelper.repo().one()
    |> Kernel.||(0)
  rescue
    _ -> 0
  end

  @doc """
  Switches a portal's access mode.

  Changing mode MINTS A NEW SLUG in both directions, and that is the point:

    * going to `public`, the old slug is a 22-char CSPRNG secret that has
      been passed around as one. Promoting it to a permanent public URL
      would publish the secret and give the board an unreadable address.
    * leaving `public`, the old slug is a name that has been indexed,
      linked and cached. Keeping it as a capability would mean the
      "secret" is written down in a search engine.

  `:publish_existing` decides what happens to tasks already flagged
  `public` when moving TO a public board: `true` puts them on it, `false`
  (the default) leaves the board empty until staff publish each one. There
  is no third option, because "do nothing and hope" is how the surprising
  version of this feature would ship.
  """
  @spec set_access_mode(binary(), String.t(), keyword()) ::
          {:ok, PortalRow.t()} | {:error, term()}
  def set_access_mode(project_uuid, mode, opts \\ []) when is_binary(project_uuid) do
    with %PortalRow{} = portal <- get_portal(project_uuid),
         true <- mode in PortalRow.access_modes() || {:error, :invalid_mode} do
      do_set_access_mode(portal, mode, opts)
    else
      nil -> {:error, :no_portal}
      {:error, _} = error -> error
      _ -> {:error, :invalid}
    end
  end

  # Same mode, no slug asked for: nothing to mint, nothing to expose.
  defp do_set_access_mode(%PortalRow{access_mode: mode} = portal, mode, opts) do
    case Keyword.get(opts, :slug) do
      nil ->
        {:ok, portal}

      _slug when portal.access_mode != "public" ->
        # Renaming is a public-board affordance. A capability slug is 16
        # CSPRNG bytes by mandate, and letting a caller hand-set one is how
        # "aaaaaaaaaaaaaaaa" becomes a project's access grant — the UI does
        # not offer it, but the context API is one forged event away.
        {:error, :slug_not_settable}

      slug ->
        # A RENAME, not a mode change. It still goes through the changeset,
        # because an early "nothing changed" return here is how an invalid
        # or reserved slug would sail past validation — and how a public
        # board would become impossible to rename at all.
        rename(portal, slug, opts)
    end
  end

  # The portal row is updated FIRST, then the board contents. Both failure
  # directions are safe that way: a failed publish leaves a public board
  # that is empty, and a failed switch leaves board flags that only the
  # public query reads. The reverse order could leave tasks exposed on a
  # board whose mode never changed.
  defp do_set_access_mode(portal, mode, opts) do
    slug = slug_for_mode(portal, mode, opts)

    portal
    |> PortalRow.changeset(%{access_mode: mode, slug: slug})
    |> RepoHelper.repo().update()
    |> case do
      {:ok, updated} ->
        maybe_publish_existing(updated, mode, opts)
        maybe_clear_board(portal, mode)

        Activity.log("projects.portal_access_mode_changed",
          actor_uuid: Keyword.get(opts, :actor_uuid),
          resource_type: "project",
          resource_uuid: portal.project_uuid,
          metadata: %{"from" => portal.access_mode, "to" => mode}
        )

        # Live sessions on the old slug lose it immediately — the same
        # broadcast a rotation uses, for the same reason.
        ProjectsPubSub.broadcast_project(:portal_rotated, %{uuid: portal.project_uuid})
        {:ok, updated}

      error ->
        error
    end
  end

  defp rename(portal, slug, opts) do
    portal
    |> PortalRow.changeset(%{slug: slug})
    |> RepoHelper.repo().update()
    |> case do
      {:ok, updated} ->
        Activity.log("projects.portal_slug_changed",
          actor_uuid: Keyword.get(opts, :actor_uuid),
          resource_type: "project",
          resource_uuid: portal.project_uuid,
          metadata: %{"from" => portal.slug, "to" => updated.slug}
        )

        # The old address stops working immediately, so live readers on it
        # are moved off rather than left on a page that no longer exists.
        ProjectsPubSub.broadcast_project(:portal_rotated, %{uuid: portal.project_uuid})
        {:ok, updated}

      error ->
        error
    end
  end

  defp slug_for_mode(portal, "public", opts) do
    # NOT generate_slug/0: that is url-base64 (mixed case, underscores) and
    # the public-slug validator rejects it, so the documented
    # "public without an explicit slug" path failed every time.
    Keyword.get(opts, :slug) || suggested_public_slug(portal)
  end

  defp slug_for_mode(_portal, _mode, _opts), do: PortalRow.generate_slug()

  defp suggested_public_slug(%PortalRow{project_uuid: project_uuid}) do
    case Projects.get_project(project_uuid) do
      %{name: name} -> PortalRow.suggest_public_slug(name)
      _ -> "board-#{System.unique_integer([:positive])}"
    end
  end

  defp maybe_publish_existing(portal, "public", opts) do
    if Keyword.get(opts, :publish_existing, false) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      from(a in Assignment,
        where: a.project_uuid == ^portal.project_uuid and a.public == true
      )
      |> RepoHelper.repo().update_all(set: [board_published_at: now])
    end

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_publish_existing(_portal, _mode, _opts), do: :ok

  # LEAVING public resets what was published to the board.
  #
  # Without this, public -> link -> public silently re-exposes everything
  # from the first public period: the second switch would look like the
  # careful, publishes-nothing default and quietly restore twenty issues.
  # Going private is usually a reaction to a problem, so coming back has to
  # be a fresh decision — the same rule as everywhere else here, that
  # exposure is something someone does rather than something that happens.
  defp maybe_clear_board(%PortalRow{access_mode: "public"} = portal, mode)
       when mode != "public" do
    from(a in Assignment,
      where: a.project_uuid == ^portal.project_uuid and not is_nil(a.board_published_at)
    )
    |> RepoHelper.repo().update_all(set: [board_published_at: nil])

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_clear_board(_portal, _mode), do: :ok

  @doc """
  Puts one task on the public board, or takes it off.

  Independent of `public` — a task can be visible to link-holders without
  being on the open-web board, and taking it off the board leaves the
  link-holder view untouched.
  """
  @spec set_board_published(binary(), boolean()) :: {:ok, integer()} | {:error, term()}
  def set_board_published(assignment_uuid, published?) when is_binary(assignment_uuid) do
    value =
      if published?, do: DateTime.utc_now() |> DateTime.truncate(:second), else: nil

    # Publishing to the board implies `public`: the board query requires
    # both, so setting one without the other is silently inert, and an
    # invariant that only holds by luck is one a later query will break.
    sets =
      if published?,
        do: [board_published_at: value, public: true],
        else: [board_published_at: nil]

    {count, _} =
      from(a in Assignment, where: a.uuid == ^assignment_uuid)
      |> RepoHelper.repo().update_all(set: sets)

    {:ok, count}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Sets the two participation policies. Values outside the vocabulary are
  refused by the changeset rather than silently coerced.
  """
  @spec set_participation(binary(), map(), keyword()) ::
          {:ok, PortalRow.t()} | {:error, term()}
  def set_participation(project_uuid, attrs, opts \\ []) when is_binary(project_uuid) do
    case get_portal(project_uuid) do
      nil ->
        {:error, :no_portal}

      portal ->
        portal
        |> PortalRow.changeset(Map.take(attrs, ["submit_access", "comment_access"]))
        |> RepoHelper.repo().update()
        |> case do
          {:ok, updated} ->
            Activity.log("projects.portal_participation_changed",
              actor_uuid: Keyword.get(opts, :actor_uuid),
              resource_type: "project",
              resource_uuid: project_uuid,
              metadata: %{
                "submit_access" => updated.submit_access,
                "comment_access" => updated.comment_access
              }
            )

            {:ok, updated}

          error ->
            error
        end
    end
  end

  @doc """
  ONE public issue, or `:error`.

  Goes through the same doorway as the list: resolve the slug, check the
  list capability, and scope from the portal row. An issue that isn't
  published to this board is indistinguishable from one that doesn't
  exist — the uniform failure that stops the page being an oracle.

  Returns the issue DTO plus its `uuid`, which the LIST deliberately omits:
  here it is the thing being addressed, and the reader already has it in
  their URL bar.
  """
  @spec public_issue(String.t(), String.t(), term()) :: {:ok, map()} | :error
  def public_issue(slug, issue_uuid, viewer \\ nil) do
    with {:ok, portal, project} <- resolve(slug, viewer),
         true <- capability?(project, :list),
         %Assignment{} = assignment <- find_public_issue(portal, issue_uuid) do
      _ = portal
      lang = PhoenixKitProjects.L10n.current_content_lang()

      {:ok,
       %{
         uuid: assignment.uuid,
         title: Assignment.label(assignment, lang) || "Issue",
         # ONLY on a public board. The portal has never shown a task's
         # description in any mode, and staff wrote them for an audience of
         # themselves; adding them to every existing link portal on deploy
         # would be exactly the retroactive exposure this design exists to
         # prevent, arriving through a side door. Putting a task on a
         # PUBLIC board is the deliberate act that also publishes its text.
         description: board_description(portal, assignment, lang),
         # Only on a public board, for the same reason the description is:
         # a screenshot attached to a report is content, and publishing a
         # task to the open web is the act that publishes its content.
         images: board_images(portal, assignment),
         status: assignment.status,
         status_label: AssignmentStatusBadge.label(assignment.status),
         inserted_at: assignment.inserted_at,
         updated_at: assignment.updated_at
       }}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # Signed URLs for the sanitised images, or none. Resolved through the
  # storage module so a file deleted by retention simply drops out rather
  # than rendering a broken image.
  defp board_images(%PortalRow{access_mode: "public"}, assignment) do
    from(sub in PortalSubmission, where: sub.assignment_uuid == ^assignment.uuid, limit: 1)
    |> RepoHelper.repo().one()
    |> case do
      %PortalSubmission{file_uuids: uuids} when is_list(uuids) -> resolve_images(uuids)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp board_images(_portal, _assignment), do: []

  @doc """
  The images a stranger attached to this issue, for the STAFF review of it.

  Deliberately not `board_images/2`: that one is gated on the board already
  being public, which is exactly backwards for triage. The person deciding
  whether to publish has to see the files *before* they are published, and
  until this existed nobody ever saw them at all — the text went through a
  human and the images went straight from an anonymous stranger onto an
  indexable page. "A person approves it" was the entire argument for
  accepting anonymous uploads, so it has to be true of the part that can
  actually carry something harmful.

  Caller must have already checked the viewer may read the assignment.
  """
  @spec review_images(binary()) :: [map()]
  def review_images(assignment_uuid) when is_binary(assignment_uuid) do
    from(sub in PortalSubmission, where: sub.assignment_uuid == ^assignment_uuid, limit: 1)
    |> RepoHelper.repo().one()
    |> case do
      %PortalSubmission{file_uuids: uuids} when is_list(uuids) -> resolve_images(uuids)
      _ -> []
    end
  rescue
    _ -> []
  end

  def review_images(_), do: []

  defp resolve_images(uuids) do
    Enum.flat_map(uuids, fn uuid ->
      case Storage.get_file(uuid) do
        %{uuid: _} -> [%{uuid: uuid, url: URLSigner.signed_url(uuid, "original")}]
        _ -> []
      end
    end)
  rescue
    _ -> []
  end

  defp board_description(%PortalRow{access_mode: "public"}, assignment, lang),
    do: Assignment.localized_description(assignment, lang)

  defp board_description(_portal, _assignment, _lang), do: nil

  # The same mode split the list uses: a public board shows only what was
  # published TO it, everything else keeps the original `public` rule.
  defp find_public_issue(%PortalRow{} = portal, issue_uuid) do
    portal
    |> issues_query()
    |> where([a], a.uuid == ^issue_uuid)
    |> exclude(:limit)
    |> RepoHelper.repo().one()
  end

  # ── Submission ──────────────────────────────────────────────────

  @doc """
  Anonymous issue submission — the full guard chain, in order: resolve →
  capability → honeypot → min-fill-time → rate limits (peer bucket +
  project ceiling; limiter failure DENIES) → size caps → create. The
  created issue lands in the project's FIRST status with
  `source: "portal"`, `public: false` (nothing self-publishes), and the
  activity entry fans out to every project member (the Phase H
  pipeline).

  `meta` carries `:peer_ip` (a `:inet.ip_address()` tuple or nil),
  `:honeypot` (the hidden field value) and `:mounted_ms` (monotonic ms at
  form mount). Returns `{:ok, :submitted}`, `{:error, :rate_limited}`,
  `{:error, :invalid}` (caps/blank), or the uniform `:error`.
  """
  @spec submit(term(), map(), map()) ::
          {:ok, :submitted} | {:error, :rate_limited} | {:error, :invalid} | :error
  def submit(slug, attrs, meta) when is_map(attrs) and is_map(meta) do
    viewer = Map.get(meta, :viewer)

    with {:ok, portal, project} <- resolve(slug, viewer),
         # BOTH gates, here in the write path. `may_submit?` is also what
         # the page uses to decide whether to draw the form, but a hidden
         # form is a courtesy — this is the control. Without it, setting
         # submission to "signed-in users" changed the UI and nothing else.
         true <- may_submit?(portal, project, viewer) || :error,
         :ok <- check_honeypot(meta),
         :ok <- check_fill_time(meta),
         :ok <- check_rate(project.uuid, meta[:peer_ip]),
         {:ok, title, description} <- validate_input(attrs),
         # LAST, and deliberately so: taking the uploads is the only step
         # here that costs CPU and disk, so it happens after the honeypot,
         # the fill-time check and the rate limiter have all had their say.
         # Consuming first meant a caller who was about to be rate-limited
         # still got three images re-encoded and stored — and stored with
         # no submission row to find them by.
         {:ok, file_uuids} <- take_attachments(meta, project) do
      create_submission(portal, project, title, description, meta, file_uuids)
    else
      {:error, :rate_limited} -> {:error, :rate_limited}
      {:error, :invalid} -> {:error, :invalid}
      _ -> :error
    end
  end

  def submit(_slug, _attrs, _meta), do: :error

  # Bots fill every field; a non-empty honeypot is a silent-looking
  # reject (the caller shows the same generic failure as :invalid).
  defp check_honeypot(meta) do
    case Map.get(meta, :honeypot) do
      value when value in [nil, ""] -> :ok
      _ -> {:error, :invalid}
    end
  end

  defp check_fill_time(meta) do
    case Map.get(meta, :mounted_ms) do
      ms when is_integer(ms) ->
        if System.monotonic_time(:millisecond) - ms >= min_fill_ms(),
          do: :ok,
          else: {:error, :invalid}

      _ ->
        # No mount timestamp = not our form (or a replay) — reject.
        {:error, :invalid}
    end
  end

  # Peer-bucketed (IPv6 at /64) + a project-wide ceiling. Hammer's ETS
  # backend; any limiter failure is a DENY — abuse controls fail closed.
  defp check_rate(project_uuid, peer_ip) do
    bucket = ip_bucket(peer_ip)

    checks = [
      {"pkp_portal:m:#{project_uuid}:#{bucket}", @per_ip_minute},
      {"pkp_portal:d:#{project_uuid}:#{bucket}", @per_ip_day},
      {"pkp_portal:p:#{project_uuid}", @per_project_day}
    ]

    Enum.reduce_while(checks, :ok, fn {key, {window, limit}}, :ok ->
      case RateLimiter.Backend.hit(key, window, limit) do
        {:allow, _} -> {:cont, :ok}
        _ -> {:halt, {:error, :rate_limited}}
      end
    end)
  rescue
    _ -> {:error, :rate_limited}
  catch
    :exit, _ -> {:error, :rate_limited}
  end

  # IPv4 → the address; IPv6 → the /64 prefix (a /64 is one subscriber —
  # per-address buckets there are free address space, panel #8).
  defp ip_bucket({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp ip_bucket({a, b, c, d, _e, _f, _g, _h}),
    do:
      "v6:#{Integer.to_string(a, 16)}:#{Integer.to_string(b, 16)}:" <>
        "#{Integer.to_string(c, 16)}:#{Integer.to_string(d, 16)}"

  defp ip_bucket(_), do: "unknown"

  defp validate_input(attrs) do
    title = attrs |> field_value("title") |> String.trim()
    description = attrs |> field_value("description") |> String.trim()

    if title != "" and String.length(title) <= @title_max and
         String.length(description) <= @description_max do
      {:ok, title, description}
    else
      {:error, :invalid}
    end
  end

  defp field_value(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  # ONE transaction for all four writes (final panel find: the unchecked
  # chain could orphan a task or silently drop the provenance row).
  # Broadcast + activity + fan-out happen AFTER commit.
  # The uploads arrive as a THUNK, not as files: the LiveView owns the
  # temp files and can only hand them over from inside its own event
  # callback, so this is what lets the cost be paid last.
  defp take_attachments(meta, project) do
    case Map.get(meta, :attachments) do
      fun when is_function(fun, 0) -> fun.() |> store_attachments(project.uuid)
      _ -> {:ok, []}
    end
  rescue
    _ -> {:error, :invalid}
  end

  defp create_submission(portal, project, title, description, meta, file_uuids) do
    result =
      RepoHelper.repo().transaction(fn ->
        with {:ok, task} <-
               Projects.create_task(%{"title" => title, "description" => description}),
             {:ok, assignment} <-
               Projects.create_assignment(
                 %{
                   "project_uuid" => project.uuid,
                   "task_uuid" => task.uuid,
                   # The ASSIGNMENT status vocabulary (not the
                   # project-lifecycle status set): new portal issues are
                   # plain open tasks — `source: "portal"` is the triage
                   # marker.
                   "status" => "todo"
                 },
                 broadcast: false
               ),
             {:ok, assignment} <-
               assignment
               |> Ecto.Changeset.change(source: "portal")
               |> RepoHelper.repo().update(),
             {:ok, _submission} <-
               %PortalSubmission{}
               |> PortalSubmission.changeset(%{
                 assignment_uuid: assignment.uuid,
                 ip_hash: ip_hash(portal, meta[:peer_ip]),
                 file_uuids: file_uuids
               })
               |> RepoHelper.repo().insert() do
          assignment
        else
          _ -> RepoHelper.repo().rollback(:submission_failed)
        end
      end)

    case result do
      {:ok, assignment} ->
        ProjectsPubSub.broadcast_assignment(:assignment_created, %{
          uuid: assignment.uuid,
          project_uuid: assignment.project_uuid
        })

        log_result =
          Activity.log("projects.portal_issue_submitted",
            resource_type: "assignment",
            resource_uuid: assignment.uuid,
            metadata: %{
              "project_uuid" => project.uuid,
              "title" => title,
              "source" => "portal",
              "ip_hash" => ip_hash(portal, meta[:peer_ip])
            }
          )

        notify_members(log_result, project.uuid)
        {:ok, :submitted}

      _ ->
        :error
    end
  end

  # Truncated peppered HMAC (pepper = the portal row's uuid): enough to
  # correlate an abuse burst, deliberately not enough to identify.
  defp ip_hash(_portal, nil), do: nil

  defp ip_hash(portal, ip) do
    :hmac
    |> :crypto.mac(:sha256, portal.uuid, ip_bucket(ip))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # The Phase H fan-out: one committed activity entry re-routed to every
  # member's notification rules. Release-gated like project_events.
  defp notify_members({:ok, entry}, project_uuid) do
    if function_exported?(PhoenixKit.Notifications, :fan_out_from_activity, 2) do
      recipients = project_uuid |> Members.list_members() |> Enum.map(& &1.user_uuid)

      if recipients != [] do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(PhoenixKit.Notifications, :fan_out_from_activity, [entry, recipients])
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp notify_members(_log_result, _project_uuid), do: :ok

  # ── Admin-side helpers ──────────────────────────────────────────

  @doc """
  Flips an assignment's public flag — the ONLY write path for it
  (server-set, never cast from params). Caller gates `:edit_tasks`.
  """
  @spec set_public(Assignment.t(), boolean(), keyword()) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t()}
  def set_public(%Assignment{} = assignment, public?, opts \\ []) do
    public? = public? == true

    # Unpublishing takes it off the public board too. The reverse is NOT
    # symmetric: making a task visible to link-holders must never put it on
    # the open web by itself — that is the second, deliberate act
    # `set_board_published/2` exists for.
    changes =
      if public?,
        do: [public: true],
        else: [public: false, board_published_at: nil]

    assignment
    |> Ecto.Changeset.change(changes)
    |> RepoHelper.repo().update()
    |> case do
      {:ok, updated} ->
        Activity.log(
          if(updated.public,
            do: "projects.issue_published",
            else: "projects.issue_unpublished"
          ),
          actor_uuid: Keyword.get(opts, :actor_uuid),
          resource_type: "assignment",
          resource_uuid: updated.uuid,
          metadata: %{"project_uuid" => updated.project_uuid}
        )

        ProjectsPubSub.broadcast_assignment(:assignment_updated, %{
          uuid: updated.uuid,
          project_uuid: updated.project_uuid
        })

        {:ok, updated}

      error ->
        error
    end
  end
end
