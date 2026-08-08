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
    with %PortalRow{} = portal <- RepoHelper.repo().get_by(PortalRow, slug: slug),
         %{} = project <- Projects.get_project(portal.project_uuid),
         true <- project.is_template == false,
         true <- Extensions.enabled?(project, @ext_key),
         true <- mode_admits?(portal, viewer) do
      {:ok, portal, project}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def resolve(_, _), do: :error

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
    case RepoHelper.repo().get_by(PortalRow, slug: slug) do
      %PortalRow{access_mode: mode} when mode in ["link", "members", "public"] -> mode
      _ -> "link"
    end
  rescue
    _ -> "link"
  catch
    :exit, _ -> "link"
  end

  def access_mode_of(_), do: "link"

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
        # No uuid. It was here for a per-issue discussion page that isn't
        # built yet, and an internal identifier is not something to publish
        # speculatively — when issues get public addresses they should get
        # per-board numbers, the way every issue tracker does, not the
        # database's primary keys.
        title: Assignment.label(a, lang) || "Issue",
        status: a.status,
        status_label: AssignmentStatusBadge.label(a.status),
        inserted_at: a.inserted_at,
        updated_at: a.updated_at
      }
    end)
  end

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

      slug ->
        # A RENAME, not a mode change. It still goes through the changeset,
        # because an early "nothing changed" return here is how an invalid
        # or reserved slug would sail past validation — and how a public
        # board would become impossible to rename at all.
        rename(portal, slug, opts)
    end
  end

  defp do_set_access_mode(portal, mode, opts) do
    slug = slug_for_mode(portal, mode, opts)

    portal
    |> PortalRow.changeset(%{access_mode: mode, slug: slug})
    |> RepoHelper.repo().update()
    |> case do
      {:ok, updated} ->
        maybe_publish_existing(updated, mode, opts)

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

  defp slug_for_mode(_portal, "public", opts) do
    Keyword.get(opts, :slug) || PortalRow.generate_slug()
  end

  defp slug_for_mode(_portal, _mode, _opts), do: PortalRow.generate_slug()

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

    {count, _} =
      from(a in Assignment, where: a.uuid == ^assignment_uuid)
      |> RepoHelper.repo().update_all(set: [board_published_at: value])

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
    with {:ok, portal, project} <- resolve(slug),
         true <- capability?(project, :submit) || :error,
         :ok <- check_honeypot(meta),
         :ok <- check_fill_time(meta),
         :ok <- check_rate(project.uuid, meta[:peer_ip]),
         {:ok, title, description} <- validate_input(attrs) do
      create_submission(portal, project, title, description, meta)
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
  defp create_submission(portal, project, title, description, meta) do
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
                 ip_hash: ip_hash(portal, meta[:peer_ip])
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
