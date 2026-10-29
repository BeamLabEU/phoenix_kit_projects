defmodule PhoenixKitProjects.Migrations.Schema do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_projects`.

  Implements the versioned-migration protocol core's `mix phoenix_kit.update`
  discovers via `migration_module/0` (`current_version/0` +
  `migrated_version_runtime/1` + `up/1`). Reference implementations:
  `PhoenixKitBookings.Migrations.Schema`, `PhoenixKitStats.Migrations.Schema`.

  ## Relationship to core's migration chain

  The projects tables were historically created by core's chain
  (V101 / V112 / V125 / V127 / V128). Those sections remain in core and stay
  authoritative for installs migrating through them — **this chain requires
  core ≥ V128** and takes over from that composed shape:

  - **V1 is a baseline**: an idempotent (`IF NOT EXISTS`) restatement of the
    exact table shape core's chain produces today. On any core-migrated
    install every statement no-ops; the version marker is simply stamped.
    `migrated_version_runtime/1` treats a marker-less-but-present
    `phoenix_kit_projects` table as already at V1, so existing installs never
    regenerate a pointless migration.
  - **V2+** (future) hold the hub-rework tables (extension enablement,
    members, ledger, …) and never ship through core.

  ## Version marker

  `COMMENT ON TABLE <prefix>.phoenix_kit_projects IS 'pkp_schema:<N>'` —
  same mechanism as core's marker on `phoenix_kit`, namespaced (`pkp_schema:`)
  so the bare-integer core convention can never be confused with ours.

  ## Idempotency

  Every statement in every version guards itself (`CREATE TABLE IF NOT
  EXISTS`, `CREATE INDEX IF NOT EXISTS`), so `up/1` always runs the full
  chain start-to-finish and re-running is safe. `down/1` exists for protocol
  completeness; on installs whose tables were created by core's chain a
  module-level down is NOT a supported operation (core's marker still claims
  the tables) — it drops data and is meant for scratch schemas only.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @current_version 26
  @marker_prefix "pkp_schema:"

  @doc "Target schema version of the projects module chain."
  def current_version, do: @current_version

  @doc """
  Currently applied projects-chain version, read from the database.

  Returns `0` when `phoenix_kit_projects` does not exist, the integer from
  the `pkp_schema:<N>` table comment when present, and `1` when the table
  exists without our marker (a core-chain-built install that predates this
  module chain). `opts` accepts `:prefix` (keyword list or map).
  """
  def migrated_version_runtime(opts \\ []) do
    prefix = normalize_prefix(opts)

    # classoid anchors the description join to pg_class — without it a
    # comment-bearing object in another catalog sharing the OID number
    # yields two rows and neither pattern matches (ZAI panel find R1-4).
    query = """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = 'phoenix_kit_projects' AND c.relkind = 'r'
    """

    case PhoenixKit.RepoHelper.repo().query(query, [prefix]) do
      {:ok, %{rows: []}} -> 0
      {:ok, %{rows: [[@marker_prefix <> n]]}} -> parse_version(n)
      {:ok, %{rows: [[_other_or_nil]]}} -> 1
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp parse_version(n) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 1
    end
  end

  @doc """
  Applies the projects module chain (all versions, idempotent), then stamps
  the marker. Accepts `:prefix` as keyword list or map.
  """
  def up(opts \\ []) do
    prefix = validated_prefix(opts)
    p = prefix_str(prefix)

    v1_baseline(p, prefix)
    v2_extension_enablement(p, prefix)
    v3_members(p, prefix)
    v4_work_entries(p, prefix)
    v5_whiteboards(p, prefix)
    v6_events(p, prefix)
    v7_priorities_labels(p, prefix)
    v8_invoiced_entries(p)
    v9_backfill_creator_owners(p, prefix)
    v10_portal(p)
    v11_subject_grants(p, prefix)
    v12_public_board(p)
    v13_submission_attachments(p)
    v14_review_status(p)
    v15_ad_hoc_tasks(p)
    v16_fileless_whiteboards(p)
    v17_api_keys(p, prefix)
    v18_key_persons(p)
    v19_agent_work(p)
    v20_words_and_links(p)
    v21_task_dates(p)
    v22_refs(p, prefix)
    v23_subtasks(p, prefix)
    v24_key_grants(p, prefix)
    v25_key_usage(p)
    v26_deadlines_and_times(p)

    execute("COMMENT ON TABLE #{p}phoenix_kit_projects IS '#{@marker_prefix}#{@current_version}'")
  end

  @doc """
  Rolls back TO `:version` (the semantics `mix phoenix_kit.update`'s
  generated host migration passes): each chain version above the target
  drops ITS OWN tables and the marker restamps at the target. A missing/0
  target is the full teardown — scratch-schema use only.

  The version-aware shape is load-bearing (panel find R1-1): the generated
  host migration wires `down` to `Schema.down(prefix: …, version: N)`, so
  a plain `mix ecto.rollback` after an update must undo ONLY that update —
  the earlier unconditional full drop destroyed every projects table on
  the first rollback while core's own marker still claimed them.
  """
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    p = prefix_str(prefix)
    target = down_target(opts)

    # V9 is a DATA backfill — rolling it back would delete memberships
    # that may since have been legitimately edited; deliberately no
    # down-path (the projects convention for data migrations).

    down_task_columns(p, target)

    if target < 18, do: down_v18(p)

    if target < 17 do
      execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_api_idempotency")
      execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_api_keys")
    end

    if target < 16 do
      # Boards without a file have no home in the old shape.
      execute("DELETE FROM #{p}phoenix_kit_project_whiteboards WHERE file_uuid IS NULL")

      execute("""
      ALTER TABLE #{p}phoenix_kit_project_whiteboards
        ALTER COLUMN file_uuid SET NOT NULL
      """)
    end

    if target < 15 do
      execute("DROP INDEX IF EXISTS #{p}phoenix_kit_project_tasks_ad_hoc_idx")

      execute("""
      ALTER TABLE #{p}phoenix_kit_project_tasks
        DROP COLUMN IF EXISTS ad_hoc
      """)
    end

    if target < 14 do
      execute("DROP INDEX IF EXISTS #{p}phoenix_kit_project_assignments_pending_review_idx")
      execute("DROP INDEX IF EXISTS #{p}phoenix_kit_project_assignments_unsorted_idx")

      execute("""
      ALTER TABLE #{p}phoenix_kit_project_assignments
        DROP CONSTRAINT IF EXISTS phoenix_kit_project_assignments_review_status_check
      """)

      execute("""
      ALTER TABLE #{p}phoenix_kit_project_assignments
        DROP COLUMN IF EXISTS review_status
      """)

      # Also clears `sorted_at` from the superseded cut described above, so
      # a workspace that ran it lands on the same schema as one that did not.
      execute("""
      ALTER TABLE #{p}phoenix_kit_project_assignments
        DROP COLUMN IF EXISTS sorted_at
      """)

      execute("""
      ALTER TABLE #{p}phoenix_kit_project_portal_submissions
        DROP COLUMN IF EXISTS submitted_by_uuid
      """)
    end

    if target < 13 do
      execute("""
      ALTER TABLE #{p}phoenix_kit_project_portal_submissions
        DROP COLUMN IF EXISTS file_uuids
      """)
    end

    if target < 12 do
      # Dropping access_mode returns every portal to secret-link semantics,
      # which is the safe direction. board_published_at goes with it: on the
      # way back down a public board stops existing, so nothing should be
      # left flagged as published to one.
      execute("""
      ALTER TABLE #{p}phoenix_kit_project_portals
        DROP CONSTRAINT IF EXISTS phoenix_kit_project_portals_access_mode_check
      """)

      execute("DROP INDEX IF EXISTS #{p}phoenix_kit_project_assignments_board_published_index")

      execute("""
      ALTER TABLE #{p}phoenix_kit_project_portals
        DROP COLUMN IF EXISTS access_mode,
        DROP COLUMN IF EXISTS submit_access,
        DROP COLUMN IF EXISTS comment_access
      """)

      execute("""
      ALTER TABLE #{p}phoenix_kit_project_assignments
        DROP COLUMN IF EXISTS board_published_at
      """)
    end

    if target < 11 do
      execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_subject_grants")
    end

    if target < 10 do
      execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_portal_submissions")
      execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_portals")
      execute("ALTER TABLE #{p}phoenix_kit_project_assignments DROP COLUMN IF EXISTS public")
      execute("ALTER TABLE #{p}phoenix_kit_project_assignments DROP COLUMN IF EXISTS source")
    end

    down_early(p, target)
  end

  # V1..V8. Split from the newer half purely so neither function grows an
  # unreadable number of branches as the chain lengthens.
  defp down_early(p, target) do
    if target < 8 do
      execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_invoiced_entries")
    end

    if target < 7 do
      execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_assignment_labels")
      execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_labels")
      execute("ALTER TABLE #{p}phoenix_kit_project_assignments DROP COLUMN IF EXISTS priority")
    end

    if target < 6, do: execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_events")
    if target < 5, do: execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_whiteboards")
    if target < 4, do: execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_work_entries")
    if target < 3, do: execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_members")
    if target < 2, do: execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_modules")

    if target < 1 do
      execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_statuses")
      execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_task_dependencies")
      execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_dependencies")
      execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_assignments")
      execute("DROP TABLE IF EXISTS #{p}phoenix_kit_projects")
      execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_tasks")
    else
      execute("COMMENT ON TABLE #{p}phoenix_kit_projects IS '#{@marker_prefix}#{target}'")
    end
  end

  defp down_target(opts) when is_list(opts) do
    case Keyword.get(opts, :version, 0) do
      v when is_integer(v) and v >= 0 -> v
      _ -> 0
    end
  end

  defp down_target(%{version: v}) when is_integer(v) and v >= 0, do: v
  defp down_target(_), do: 0

  # Raw string interpolation into DDL demands a validated prefix (core's
  # prefix rules; panel find R1-3). The update task validates upstream —
  # this covers direct/console callers.
  defp validated_prefix(opts) do
    prefix = normalize_prefix(opts)
    Helpers.validate_prefix!(prefix)
    prefix
  end

  # ---------------------------------------------------------------------------
  # V1 — baseline: the composed shape core's V101/V112/V125/V127/V128 produce.
  # Authored from a pg_dump of a fully-migrated database (2026-08-05), NOT by
  # composing the core migration files — the dump is ground truth (it caught
  # V101's unique name/title indexes having been dropped and
  # scheduled_start_date's widening to a naive datetime).
  # ---------------------------------------------------------------------------

  defp v1_baseline(p, prefix) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_tasks (
      uuid UUID PRIMARY KEY DEFAULT #{prefix}.uuid_generate_v7(),
      title VARCHAR(255) NOT NULL,
      description TEXT,
      estimated_duration INTEGER,
      estimated_duration_unit VARCHAR(20) DEFAULT 'hours',
      default_assigned_team_uuid UUID REFERENCES #{p}phoenix_kit_staff_teams(uuid) ON DELETE SET NULL,
      default_assigned_department_uuid UUID REFERENCES #{p}phoenix_kit_staff_departments(uuid) ON DELETE SET NULL,
      default_assigned_person_uuid UUID REFERENCES #{p}phoenix_kit_staff_people(uuid) ON DELETE SET NULL,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      translations JSONB NOT NULL DEFAULT '{}'::jsonb,
      position INTEGER NOT NULL DEFAULT 0,
      CONSTRAINT phoenix_kit_project_tasks_single_default_assignee
        CHECK (num_nonnulls(default_assigned_team_uuid, default_assigned_department_uuid, default_assigned_person_uuid) <= 1)
    )
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_projects (
      uuid UUID PRIMARY KEY DEFAULT #{prefix}.uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      description TEXT,
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      is_template BOOLEAN NOT NULL DEFAULT false,
      counts_weekends BOOLEAN NOT NULL DEFAULT false,
      start_mode VARCHAR(20) NOT NULL DEFAULT 'immediate',
      scheduled_start_date TIMESTAMP(0),
      started_at TIMESTAMPTZ,
      completed_at TIMESTAMPTZ,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      archived_at TIMESTAMP(0),
      translations JSONB NOT NULL DEFAULT '{}'::jsonb,
      position INTEGER NOT NULL DEFAULT 0,
      status_entity_uuid UUID REFERENCES #{p}phoenix_kit_entities(uuid) ON DELETE SET NULL,
      current_status_slug VARCHAR(255),
      settings JSONB NOT NULL DEFAULT '{}'::jsonb,
      external_id VARCHAR(255),
      assigned_team_uuid UUID REFERENCES #{p}phoenix_kit_staff_teams(uuid) ON DELETE SET NULL,
      assigned_department_uuid UUID REFERENCES #{p}phoenix_kit_staff_departments(uuid) ON DELETE SET NULL,
      assigned_person_uuid UUID REFERENCES #{p}phoenix_kit_staff_people(uuid) ON DELETE SET NULL,
      CONSTRAINT phoenix_kit_projects_single_assignee
        CHECK (num_nonnulls(assigned_team_uuid, assigned_department_uuid, assigned_person_uuid) <= 1)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_projects_status_index
    ON #{p}phoenix_kit_projects (status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_projects_visible_idx
    ON #{p}phoenix_kit_projects (inserted_at DESC) WHERE (archived_at IS NULL)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_projects_external_id_idx
    ON #{p}phoenix_kit_projects (external_id) WHERE (external_id IS NOT NULL)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_projects_status_entity_idx
    ON #{p}phoenix_kit_projects (status_entity_uuid) WHERE (status_entity_uuid IS NOT NULL)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_projects_assigned_team_idx
    ON #{p}phoenix_kit_projects (assigned_team_uuid) WHERE (assigned_team_uuid IS NOT NULL)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_projects_assigned_department_idx
    ON #{p}phoenix_kit_projects (assigned_department_uuid) WHERE (assigned_department_uuid IS NOT NULL)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_projects_assigned_person_idx
    ON #{p}phoenix_kit_projects (assigned_person_uuid) WHERE (assigned_person_uuid IS NOT NULL)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_assignments (
      uuid UUID PRIMARY KEY DEFAULT #{prefix}.uuid_generate_v7(),
      project_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE,
      task_uuid UUID REFERENCES #{p}phoenix_kit_project_tasks(uuid) ON DELETE CASCADE,
      status VARCHAR(20) NOT NULL DEFAULT 'todo',
      position INTEGER NOT NULL DEFAULT 0,
      description TEXT,
      estimated_duration INTEGER,
      estimated_duration_unit VARCHAR(20),
      assigned_team_uuid UUID REFERENCES #{p}phoenix_kit_staff_teams(uuid) ON DELETE SET NULL,
      assigned_department_uuid UUID REFERENCES #{p}phoenix_kit_staff_departments(uuid) ON DELETE SET NULL,
      assigned_person_uuid UUID REFERENCES #{p}phoenix_kit_staff_people(uuid) ON DELETE SET NULL,
      counts_weekends BOOLEAN,
      progress_pct INTEGER NOT NULL DEFAULT 0,
      track_progress BOOLEAN NOT NULL DEFAULT false,
      completed_by_uuid UUID REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
      completed_at TIMESTAMPTZ,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      translations JSONB NOT NULL DEFAULT '{}'::jsonb,
      child_project_uuid UUID REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE RESTRICT,
      CONSTRAINT phoenix_kit_project_assignments_single_assignee
        CHECK (num_nonnulls(assigned_team_uuid, assigned_department_uuid, assigned_person_uuid) <= 1),
      CONSTRAINT phoenix_kit_project_assignments_task_xor_child
        CHECK ((task_uuid IS NOT NULL) <> (child_project_uuid IS NOT NULL))
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_assignments_child_project_unique
    ON #{p}phoenix_kit_project_assignments (child_project_uuid) WHERE (child_project_uuid IS NOT NULL)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_project_index
    ON #{p}phoenix_kit_project_assignments (project_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_status_index
    ON #{p}phoenix_kit_project_assignments (status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_task_index
    ON #{p}phoenix_kit_project_assignments (task_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_team_index
    ON #{p}phoenix_kit_project_assignments (assigned_team_uuid) WHERE (assigned_team_uuid IS NOT NULL)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_department_index
    ON #{p}phoenix_kit_project_assignments (assigned_department_uuid) WHERE (assigned_department_uuid IS NOT NULL)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_person_index
    ON #{p}phoenix_kit_project_assignments (assigned_person_uuid) WHERE (assigned_person_uuid IS NOT NULL)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_completed_by_index
    ON #{p}phoenix_kit_project_assignments (completed_by_uuid) WHERE (completed_by_uuid IS NOT NULL)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_dependencies (
      uuid UUID PRIMARY KEY DEFAULT #{prefix}.uuid_generate_v7(),
      assignment_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_project_assignments(uuid) ON DELETE CASCADE,
      depends_on_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_project_assignments(uuid) ON DELETE CASCADE,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_dependencies_pair_index
    ON #{p}phoenix_kit_project_dependencies (assignment_uuid, depends_on_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_dependencies_depends_on_index
    ON #{p}phoenix_kit_project_dependencies (depends_on_uuid)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_task_dependencies (
      uuid UUID PRIMARY KEY DEFAULT #{prefix}.uuid_generate_v7(),
      task_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_project_tasks(uuid) ON DELETE CASCADE,
      depends_on_task_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_project_tasks(uuid) ON DELETE CASCADE,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_task_deps_pair_index
    ON #{p}phoenix_kit_project_task_dependencies (task_uuid, depends_on_task_uuid)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_statuses (
      uuid UUID PRIMARY KEY DEFAULT #{prefix}.uuid_generate_v7(),
      project_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE,
      label VARCHAR(255) NOT NULL,
      slug VARCHAR(255) NOT NULL,
      position INTEGER NOT NULL DEFAULT 0,
      data JSONB NOT NULL DEFAULT '{}'::jsonb,
      translations JSONB NOT NULL DEFAULT '{}'::jsonb,
      source_entity_data_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_statuses_project_index
    ON #{p}phoenix_kit_project_statuses (project_uuid)
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_statuses_project_slug_index
    ON #{p}phoenix_kit_project_statuses (project_uuid, slug)
    """)
  end

  # ---------------------------------------------------------------------------
  # V2 — per-project extension enablement (the hub rework's first table).
  #
  # uuid-keyed rows with an `instance_key` (default "default") IN the unique
  # index + a per-row `config` JSONB — per the 2026-08-05 plan-review panel:
  # instance-readiness must be structural. v1 exposes toggle semantics (one
  # instance per extension per project); multi-instance later = relaxing the
  # UI, not migrating storage. `enabled` is a flag rather than row-existence
  # so disable preserves config (Redmine semantics: hide, never delete).
  # ---------------------------------------------------------------------------

  defp v2_extension_enablement(p, prefix) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_modules (
      uuid UUID PRIMARY KEY DEFAULT #{prefix}.uuid_generate_v7(),
      project_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE,
      ext_key VARCHAR(100) NOT NULL,
      instance_key VARCHAR(100) NOT NULL DEFAULT 'default',
      name VARCHAR(255),
      enabled BOOLEAN NOT NULL DEFAULT true,
      config JSONB NOT NULL DEFAULT '{}'::jsonb,
      enabled_by_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_modules_identity_index
    ON #{p}phoenix_kit_project_modules (project_uuid, ext_key, instance_key)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_modules_project_index
    ON #{p}phoenix_kit_project_modules (project_uuid)
    """)
  end

  # ---------------------------------------------------------------------------
  # V3 — per-project members (the hub's native people layer, P2a).
  #
  # Members are CORE USERS (user_uuid), not staff people — "natively only
  # core stuff"; staff/CRM enrich via seams. `role` is the frozen enum
  # owner/manager/member/viewer (PhoenixKitProjects.Authz.roles/0).
  # `invited_by_uuid` is FK-less best-effort provenance (the activity log
  # is the audit trail — same convention as project_modules.enabled_by).
  # ---------------------------------------------------------------------------

  defp v3_members(p, prefix) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_members (
      uuid UUID PRIMARY KEY DEFAULT #{prefix}.uuid_generate_v7(),
      project_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE,
      user_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
      role VARCHAR(20) NOT NULL DEFAULT 'member',
      invited_by_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT phoenix_kit_project_members_role_check
        CHECK (role IN ('owner', 'manager', 'member', 'viewer'))
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_members_identity_index
    ON #{p}phoenix_kit_project_members (project_uuid, user_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_members_project_index
    ON #{p}phoenix_kit_project_members (project_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_members_user_index
    ON #{p}phoenix_kit_project_members (user_uuid)
    """)
  end

  # ---------------------------------------------------------------------------
  # V4 — the work ledger (Step 10): unified effort per task/project where
  # the ACTOR can be a human or an AI agent and the QUANTITY minutes,
  # tokens, or cost — "assign a task to an AI agent and watch its token
  # spend next to your team's hours". Append-only; actor_uuid is FK-less
  # (ai agents aren't users; activity is the audit trail). Amount unit is
  # fixed per kind: time=minutes, tokens=count, cost=cents.
  # ---------------------------------------------------------------------------

  defp v4_work_entries(p, prefix) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_work_entries (
      uuid UUID PRIMARY KEY DEFAULT #{prefix}.uuid_generate_v7(),
      project_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE,
      assignment_uuid UUID REFERENCES #{p}phoenix_kit_project_assignments(uuid) ON DELETE SET NULL,
      actor_kind VARCHAR(20) NOT NULL DEFAULT 'user',
      actor_uuid UUID,
      kind VARCHAR(10) NOT NULL,
      amount NUMERIC(14,4) NOT NULL,
      started_at TIMESTAMPTZ,
      ended_at TIMESTAMPTZ,
      note TEXT,
      source VARCHAR(30) NOT NULL DEFAULT 'manual',
      billable BOOLEAN NOT NULL DEFAULT false,
      metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT phoenix_kit_project_work_entries_actor_kind_check
        CHECK (actor_kind IN ('user', 'staff_person', 'ai_agent')),
      CONSTRAINT phoenix_kit_project_work_entries_kind_check
        CHECK (kind IN ('time', 'tokens', 'cost')),
      CONSTRAINT phoenix_kit_project_work_entries_amount_check
        CHECK (amount > 0)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_work_entries_project_index
    ON #{p}phoenix_kit_project_work_entries (project_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_work_entries_assignment_index
    ON #{p}phoenix_kit_project_work_entries (assignment_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_work_entries_actor_index
    ON #{p}phoenix_kit_project_work_entries (actor_kind, actor_uuid)
    """)
  end

  # V5 — whiteboards (Step 11 of the hub rework): a named drawing board =
  # one core Storage file (the blank-background bridge) + core annotation
  # rows anchored to it. The board row is the projects-side name/order
  # wrapper; deleting the FILE cascades the board (and core cascades the
  # annotations), so nothing dangles.
  defp v5_whiteboards(p, prefix) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_whiteboards (
      uuid UUID PRIMARY KEY DEFAULT #{prefix}.uuid_generate_v7(),
      project_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE,
      file_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_files(uuid) ON DELETE CASCADE,
      name VARCHAR(160) NOT NULL,
      width INTEGER NOT NULL DEFAULT 1920,
      height INTEGER NOT NULL DEFAULT 1080,
      position INTEGER NOT NULL DEFAULT 0,
      created_by_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_whiteboards_project_index
    ON #{p}phoenix_kit_project_whiteboards (project_uuid)
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_whiteboards_file_index
    ON #{p}phoenix_kit_project_whiteboards (file_uuid)
    """)
  end

  # V6 — project events (Step 12 of the hub rework): dated happenings that
  # aren't tasks (meetings, milestones, reviews), rendered on their own
  # extension tab via phoenix_live_calendar. UTC storage; all_day events
  # ignore the time-of-day component.
  defp v6_events(p, prefix) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_events (
      uuid UUID PRIMARY KEY DEFAULT #{prefix}.uuid_generate_v7(),
      project_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE,
      title VARCHAR(200) NOT NULL,
      description TEXT,
      starts_at TIMESTAMPTZ NOT NULL,
      ends_at TIMESTAMPTZ,
      all_day BOOLEAN NOT NULL DEFAULT true,
      location VARCHAR(200),
      created_by_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT phoenix_kit_project_events_range_check
        CHECK (ends_at IS NULL OR ends_at >= starts_at)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_events_project_starts_index
    ON #{p}phoenix_kit_project_events (project_uuid, starts_at)
    """)
  end

  # V7 — priorities + labels (Phase C of the campaign): an assignment
  # priority (closed vocabulary, normal default so existing rows are
  # unchanged) and a per-project LABEL registry with a join table —
  # arrays of FKs aren't enforceable, a join table is.
  defp v7_priorities_labels(p, prefix) do
    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
    ADD COLUMN IF NOT EXISTS priority VARCHAR(10) NOT NULL DEFAULT 'normal'
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
    DROP CONSTRAINT IF EXISTS phoenix_kit_project_assignments_priority_check
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
    ADD CONSTRAINT phoenix_kit_project_assignments_priority_check
    CHECK (priority IN ('urgent', 'high', 'normal', 'low'))
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_labels (
      uuid UUID PRIMARY KEY DEFAULT #{prefix}.uuid_generate_v7(),
      project_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE,
      name VARCHAR(60) NOT NULL,
      color VARCHAR(30) NOT NULL DEFAULT 'badge-neutral',
      position INTEGER NOT NULL DEFAULT 0,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_labels_name_index
    ON #{p}phoenix_kit_project_labels (project_uuid, name)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_assignment_labels (
      assignment_uuid UUID NOT NULL
        REFERENCES #{p}phoenix_kit_project_assignments(uuid) ON DELETE CASCADE,
      label_uuid UUID NOT NULL
        REFERENCES #{p}phoenix_kit_project_labels(uuid) ON DELETE CASCADE,
      PRIMARY KEY (assignment_uuid, label_uuid)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignment_labels_label_index
    ON #{p}phoenix_kit_project_assignment_labels (label_uuid)
    """)
  end

  # V8 — invoiced-entry refs (Phase E, the ledger→invoice bridge): the
  # PROJECTS-side authority for "which ledger entries are billed"
  # (panel-settled boundary: billing stays project-agnostic; the
  # append-only ledger is never mutated — billed-ness derives from this
  # ref table). entry_uuid is the PK = idempotency: an entry can be on
  # exactly one invoice. invoice_uuid is deliberately FK-less (billing's
  # table is the other module's business).
  defp v8_invoiced_entries(p) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_invoiced_entries (
      entry_uuid UUID PRIMARY KEY
        REFERENCES #{p}phoenix_kit_project_work_entries(uuid) ON DELETE CASCADE,
      project_uuid UUID NOT NULL
        REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE,
      invoice_uuid UUID NOT NULL,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_invoiced_entries_project_index
    ON #{p}phoenix_kit_project_invoiced_entries (project_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_invoiced_entries_invoice_index
    ON #{p}phoenix_kit_project_invoiced_entries (invoice_uuid)
    """)
  end

  # V9 — creator→owner backfill (Phase I): pre-hub projects have NO
  # member rows, which is fine behind the admin override but LOCKS
  # everyone out the day the member-facing surface ships (the final
  # panel's Gemini #3). Derive each memberless non-template project's
  # creator from its earliest projects.project_created activity entry
  # (the template_creators/1 precedent) and seat them as owner. Projects
  # whose creation entry is pruned/actor-less stay memberless —
  # admin-recoverable, never guessed. Idempotent by construction (only
  # memberless projects qualify).
  defp v9_backfill_creator_owners(p, prefix) do
    execute("""
    INSERT INTO #{p}phoenix_kit_project_members
      (uuid, project_uuid, user_uuid, role, inserted_at, updated_at)
    SELECT #{prefix}.uuid_generate_v7(), pr.uuid, creator.actor_uuid, 'owner', NOW(), NOW()
    FROM #{p}phoenix_kit_projects pr
    JOIN LATERAL (
      SELECT e.actor_uuid
      FROM #{p}phoenix_kit_activities e
      WHERE e.resource_uuid = pr.uuid
        AND e.action IN ('projects.project_created', 'projects.project_created_from_template')
        AND e.actor_uuid IS NOT NULL
      ORDER BY e.inserted_at ASC
      LIMIT 1
    ) creator ON true
    WHERE pr.is_template = false
      AND EXISTS (
        SELECT 1 FROM #{p}phoenix_kit_users u WHERE u.uuid = creator.actor_uuid
      )
      AND NOT EXISTS (
        SELECT 1 FROM #{p}phoenix_kit_project_members m WHERE m.project_uuid = pr.uuid
      )
    """)
  end

  # V10 — the public portal (Phase J): one portal row per project (the
  # slug IS the access grant — random, regenerable), per-assignment
  # public/source columns, and submitter PII isolated on its own
  # deletable table (email lives ONLY here).
  defp v10_portal(p) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_portals (
      uuid UUID PRIMARY KEY,
      project_uuid UUID NOT NULL UNIQUE
        REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE,
      slug VARCHAR(64) NOT NULL UNIQUE,
      settings JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
    ADD COLUMN IF NOT EXISTS public BOOLEAN NOT NULL DEFAULT FALSE
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
    ADD COLUMN IF NOT EXISTS source VARCHAR(16) NOT NULL DEFAULT 'internal'
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_portal_submissions (
      uuid UUID PRIMARY KEY,
      assignment_uuid UUID NOT NULL
        REFERENCES #{p}phoenix_kit_project_assignments(uuid) ON DELETE CASCADE,
      email VARCHAR(160),
      ip_hash VARCHAR(64),
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_portal_submissions_assignment_index
    ON #{p}phoenix_kit_project_portal_submissions (assignment_uuid)
    """)
  end

  # ---------------------------------------------------------------------------
  # V11 — indirect access grants: a project role held by a TEAM, a
  # DEPARTMENT, or a site ROLE rather than by one person.
  #
  # Kept as its OWN table rather than making phoenix_kit_project_members
  # polymorphic (the 2026-08-07 four-AI quorum's advice): members stays the
  # authoritative direct-user table, keeps its real FK to phoenix_kit_users,
  # and keeps the last-owner guard and succession logic untouched.
  #
  # `subject_uuid` is deliberately FK-less — it points into three different
  # tables (staff teams, staff departments, core roles), two of which live
  # in a SIBLING package that may not be installed. Referential integrity is
  # enforced at the context layer, which resolves the subject before writing
  # and drops grants whose subject has vanished when reading.
  #
  # `role` excludes 'owner' at the DB level: ownership needs an accountable
  # person, and a team-owned project would break the last-owner guard the
  # moment the team emptied.
  # ---------------------------------------------------------------------------

  # V12: the portal stops assuming its own secrecy.
  #
  # `access_mode` is one enum rather than a pair of booleans because the
  # quadrants aren't orthogonal: "secret slug + indexable" and "human slug
  # + possession-is-authorization" are both nonsense, and booleans let an
  # admin construct them. An enum makes those states unrepresentable.
  #
  # `board_published_at` is the blast-radius guard, and it is the reason
  # this is safe to ship. `public == true` has meant "visible to whoever
  # holds the secret link" for as long as the portal has existed, and staff
  # flagged tasks under that understanding. Reusing it as "visible to the
  # open web" would retroactively publish every one of them the moment an
  # admin flipped a switch. A task reaches a PUBLIC board only by being
  # explicitly published to it — a second, deliberate act — so switching a
  # portal to `public` exposes nothing by itself.
  # V13: images attached to an anonymous submission.
  #
  # The uuids point at core storage rows. No foreign key: storage is
  # core's table and a portal submission has no business constraining it,
  # and a file deleted by a retention job must not take the submission
  # with it — the reference simply stops resolving, which is what the
  # render path already handles for every other resource.
  # Whether staff have ACCEPTED this into the project.
  #
  # Replaces V14's `sorted_at`, which asked the wrong question. A public
  # submission is not an internal task that happens to be in the wrong
  # place — it is a request from a stranger that nobody has agreed to yet,
  # and until somebody does it should not be sitting in the plan being
  # counted, filtered and dragged alongside real work.
  #
  # `accepted` is the default so every existing row and every task created
  # inside the admin keeps behaving exactly as before; only the portal
  # opens anything in `pending`. `rejected` rows are kept rather than
  # deleted: a stranger's submission and the decision taken on it are the
  # audit trail for a public intake.
  defp v14_review_status(p) do
    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
    ADD COLUMN IF NOT EXISTS review_status VARCHAR(16) NOT NULL DEFAULT 'accepted'
    """)

    # Anything from the portal that was never published to a board and
    # never started is, by definition, a request nobody acted on. Published
    # or in-progress rows were accepted by whoever did that, so they keep
    # the default and no project wakes up with a queue full of work it has
    # already been doing.
    execute("""
    UPDATE #{p}phoenix_kit_project_assignments
    SET review_status = 'pending'
    WHERE source = 'portal' AND public = false AND status = 'todo'
    """)

    # An earlier cut of this version added `sorted_at` and never left this
    # workspace. Dropped here rather than in a version of its own: the
    # question it asked ("has somebody placed this?") was the wrong one, and
    # two half-states are worse than one.
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_project_assignments_unsorted_idx")

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
    DROP COLUMN IF EXISTS sorted_at
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
    DROP CONSTRAINT IF EXISTS phoenix_kit_project_assignments_review_status_check
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
    ADD CONSTRAINT phoenix_kit_project_assignments_review_status_check
    CHECK (review_status IN ('pending', 'accepted', 'rejected'))
    """)

    # The review queue is a small slice read on every hub load.
    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_pending_review_idx
      ON #{p}phoenix_kit_project_assignments (project_uuid)
      WHERE review_status <> 'accepted'
    """)

    # Who sent it, when we know. The portal accepts submissions from
    # signed-in people as well as strangers, and it was throwing the
    # signed-in half away — so a reviewer was told every submission came
    # from nobody, including the ones from their own colleagues.
    #
    # NULL means genuinely anonymous. No FK: a deleted account should not
    # take the record of what they reported with it, and the whole point of
    # this table is to survive as the audit trail for a public intake.
    execute("""
    ALTER TABLE #{p}phoenix_kit_project_portal_submissions
    ADD COLUMN IF NOT EXISTS submitted_by_uuid UUID
    """)
  end

  # V17 — project API keys (the JSON API an outside agent drives a project
  # with, `PhoenixKitProjects.Web.Api`). A key is its own principal in the
  # project: a role of its own, scopes, and the identity the work ledger
  # names for the usage it reports. `key_id` is the public half of the
  # token (`pkp_<key_id>_<secret>`), unique and looked up on every call;
  # only the secret's SHA-256 is stored. `created_by_uuid` is provenance —
  # the person who minted it — and is not a foreign key on purpose: a key
  # outlives the account that made it until someone revokes it.
  #
  # The idempotency table makes the agent's appends safe to retry: a POST
  # that carries an `Idempotency-Key` stores its response under
  # (key, header) and a replay answers with the stored response instead of
  # a second ledger row or a second task. Rows cascade with their key.
  defp v17_api_keys(p, prefix) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_api_keys (
      uuid UUID PRIMARY KEY DEFAULT #{prefix}.uuid_generate_v7(),
      project_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE,
      name VARCHAR(80) NOT NULL,
      role VARCHAR(16) NOT NULL DEFAULT 'member',
      key_id VARCHAR(24) NOT NULL,
      secret_hash VARCHAR(64) NOT NULL,
      scopes TEXT[] NOT NULL DEFAULT '{}',
      created_by_uuid UUID,
      last_used_at TIMESTAMPTZ,
      expires_at TIMESTAMPTZ,
      revoked_at TIMESTAMPTZ,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_api_keys_key_id_index
    ON #{p}phoenix_kit_project_api_keys (key_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_api_keys_project_index
    ON #{p}phoenix_kit_project_api_keys (project_uuid)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_api_idempotency (
      api_key_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_project_api_keys(uuid) ON DELETE CASCADE,
      idempotency_key VARCHAR(128) NOT NULL,
      status INTEGER NOT NULL,
      body JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (api_key_uuid, idempotency_key)
    )
    """)
  end

  # V19–V21 each added columns to the assignments table (and V20 the link
  # table); newest first.
  defp down_task_columns(p, target) do
    if target < 26, do: down_v26(p)
    if target < 25, do: down_v25(p)
    if target < 24, do: down_v24(p)
    if target < 23, do: down_v23(p)
    if target < 22, do: down_v22(p)
    if target < 21, do: down_v21(p)
    if target < 20, do: down_v20(p)
    if target < 19, do: down_v19(p)
    :ok
  end

  defp down_v18(p) do
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_project_api_keys_person_index")

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_api_keys
      DROP COLUMN IF EXISTS user_uuid
    """)
  end

  defp down_v22(p) do
    execute("DROP TRIGGER IF EXISTS pkp_assignment_number ON #{p}phoenix_kit_project_assignments")
    execute("DROP TRIGGER IF EXISTS pkp_project_key_default ON #{p}phoenix_kit_projects")
    execute("DROP TRIGGER IF EXISTS pkp_project_key_register ON #{p}phoenix_kit_projects")
    execute("DROP FUNCTION IF EXISTS #{p}pkp_assignment_number()")
    execute("DROP FUNCTION IF EXISTS #{p}pkp_project_key_default()")
    execute("DROP FUNCTION IF EXISTS #{p}pkp_project_key_register()")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_project_assignments_number_index")
    execute("ALTER TABLE #{p}phoenix_kit_project_assignments DROP COLUMN IF EXISTS number")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_task_counters")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_keys")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_projects_key_index")
    execute("ALTER TABLE #{p}phoenix_kit_projects DROP COLUMN IF EXISTS key")
    execute("DROP SEQUENCE IF EXISTS #{p}phoenix_kit_project_key_seq")
  end

  defp down_v21(p) do
    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
      DROP CONSTRAINT IF EXISTS phoenix_kit_project_assignments_dates_check
    """)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_project_assignments_end_date_index")

    for col <- ~w(start_date end_date) do
      execute("ALTER TABLE #{p}phoenix_kit_project_assignments DROP COLUMN IF EXISTS #{col}")
    end
  end

  defp down_v20(p) do
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_task_interactions")

    execute(
      "ALTER TABLE #{p}phoenix_kit_project_assignments DROP COLUMN IF EXISTS words_by_key_uuid"
    )
  end

  defp down_v19(p) do
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_project_assignments_updated_index")

    for col <-
          ~w(created_by_uuid created_by_key_uuid started_by_uuid started_by_key_uuid waiting_on origin checklist) do
      execute("ALTER TABLE #{p}phoenix_kit_project_assignments DROP COLUMN IF EXISTS #{col}")
    end
  end

  # V26 — when a task is due, and when it really happened (the boss, via
  # Max, 2026-10-29). `deadline` is "by when it has to be done", a moment
  # (date and time: the client sets same-day ones, "call them back by
  # 15:00"), independent of the planned days; it alone makes a task
  # overdue. `started_at` is when work really began (Start), next to the
  # existing `completed_at` (Done); both can be corrected afterwards, so a
  # late tick can be moved back. `start_time` / `end_time` put an optional
  # wall-clock time on the planned days (zone-free like the dates). A
  # project gets a link out (`external_url`, `external_label`): the record
  # it belongs to elsewhere, e.g. the order a host app made it for.
  # Tasks already in progress or done before V26 keep `started_at` NULL:
  # when they really began was never recorded, and a guess (their last
  # update) would draw work that did not happen on the Time page.
  defp v26_deadlines_and_times(p) do
    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
      ADD COLUMN IF NOT EXISTS deadline TIMESTAMPTZ,
      ADD COLUMN IF NOT EXISTS started_at TIMESTAMPTZ,
      ADD COLUMN IF NOT EXISTS start_time TIME,
      ADD COLUMN IF NOT EXISTS end_time TIME
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_deadline_index
    ON #{p}phoenix_kit_project_assignments (project_uuid, deadline)
    WHERE deadline IS NOT NULL
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_projects
      ADD COLUMN IF NOT EXISTS external_url VARCHAR(2000),
      ADD COLUMN IF NOT EXISTS external_label VARCHAR(120)
    """)
  end

  defp down_v26(p) do
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_project_assignments_deadline_index")

    for col <- ~w(deadline started_at start_time end_time) do
      execute("ALTER TABLE #{p}phoenix_kit_project_assignments DROP COLUMN IF EXISTS #{col}")
    end

    for col <- ~w(external_url external_label) do
      execute("ALTER TABLE #{p}phoenix_kit_projects DROP COLUMN IF EXISTS #{col}")
    end
  end

  # V25 — how much each API key is used (Max, 2026-10-19: "some kind of
  # usage stats and graph"; "do 1, 2, and 3"). One row per key, project and
  # UTC day: the requests it made there, how many of them failed (4xx/5xx)
  # and how many of those were refused (403) — the one count an agent
  # cannot skip, unlike the time and usage it reports to the ledger. A row
  # is an upsert counter, never a log of requests.
  defp v25_key_usage(p) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_api_key_usage (
      api_key_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_project_api_keys(uuid) ON DELETE CASCADE,
      project_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE,
      day DATE NOT NULL,
      requests INTEGER NOT NULL DEFAULT 0,
      errors INTEGER NOT NULL DEFAULT 0,
      denied INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (api_key_uuid, project_uuid, day)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_api_key_usage_day_index
    ON #{p}phoenix_kit_project_api_key_usage (day)
    """)
  end

  defp down_v25(p) do
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_api_key_usage")
  end

  # V24 — API keys that reach several projects (Max, 2026-10-15: "make API
  # key stuff more global… set up permissions and what they can see and do
  # per project"; 2026-10-16: "every setting that we already have in the
  # project should also be for the api permissions").
  #
  #   * `phoenix_kit_project_api_key_grants`: one row per project a key
  #     reaches — its scopes there (per area: none / read / write,
  #     `PhoenixKitProjects.ApiAccess`), its role cap there, and whether it
  #     covers the project's sub-projects. The nearest grant up a project's
  #     tree decides (`ApiKeys.access_for/2`); an empty scope list is "no
  #     access" and stops a parent's grant at that project.
  #   * every existing key gets exactly the grant it had: its project, its
  #     role, its scopes in the new vocabulary — each old scope brings the
  #     reads it used to imply, nothing more — so every token works as
  #     before.
  #   * the key's `project_uuid` is now its HOME project (the one a call
  #     without `project` acts on), and deleting that project no longer
  #     deletes the key with every other grant it holds.
  defp v24_key_grants(p, prefix) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_api_key_grants (
      uuid UUID PRIMARY KEY DEFAULT #{prefix}.uuid_generate_v7(),
      api_key_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_project_api_keys(uuid) ON DELETE CASCADE,
      project_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE,
      scopes TEXT[] NOT NULL DEFAULT '{}',
      role VARCHAR(16) NOT NULL DEFAULT 'member',
      inherit BOOLEAN NOT NULL DEFAULT true,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_api_key_grants_key_project_index
    ON #{p}phoenix_kit_project_api_key_grants (api_key_uuid, project_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_api_key_grants_project_index
    ON #{p}phoenix_kit_project_api_key_grants (project_uuid)
    """)

    # A stored response is now found by its project and header together
    # (`Json.idempotency_scope/2`); one stored before is the key's only
    # project's, so it is renamed the same way — a retry across the
    # upgrade still replays instead of writing twice. Run before the
    # grants backfill and only for keys with no grant yet: that is "before
    # V24" exactly, so a replay of the chain renames nothing twice.
    execute("""
    UPDATE #{p}phoenix_kit_project_api_idempotency i
    SET idempotency_key =
          encode(sha256(convert_to(k.project_uuid::text || ':' || i.idempotency_key, 'UTF8')), 'hex')
    FROM #{p}phoenix_kit_project_api_keys k
    WHERE k.uuid = i.api_key_uuid
      AND k.project_uuid IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM #{p}phoenix_kit_project_api_key_grants g WHERE g.api_key_uuid = k.uuid
      )
    """)

    # One grant per key that has none yet (a replay adds nothing). What
    # `tasks:read` / `tasks:write` covered before V24 is split into the
    # areas it now names. And every write comes with its read — the grid
    # has "read" and "read and write", never write alone (status, which has
    # no read, aside) — so a `time:write`-only key may now list the entries
    # in its project, the one widening this backfill makes, on purpose.
    execute("""
    INSERT INTO #{p}phoenix_kit_project_api_key_grants (api_key_uuid, project_uuid, scopes, role)
    SELECT k.uuid, k.project_uuid,
           ARRAY(SELECT DISTINCT s FROM unnest(
             k.scopes
             || CASE WHEN 'tasks:read' = ANY(k.scopes)
                  THEN ARRAY['project:read','notes:read','time:read','usage:read','events:read','people:read']
                  ELSE ARRAY[]::text[] END
             || CASE WHEN 'tasks:write' = ANY(k.scopes)
                  THEN ARRAY['status:write','notes:write','notes:read'] ELSE ARRAY[]::text[] END
             || ARRAY(SELECT replace(w, ':write', ':read') FROM unnest(k.scopes) AS w
                      WHERE w LIKE '%:write' AND w <> 'status:write')
           ) AS s ORDER BY s),
           k.role
    FROM #{p}phoenix_kit_project_api_keys k
    WHERE k.project_uuid IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM #{p}phoenix_kit_project_api_key_grants g WHERE g.api_key_uuid = k.uuid
      )
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_api_keys
      ALTER COLUMN project_uuid DROP NOT NULL
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_api_keys
      DROP CONSTRAINT IF EXISTS phoenix_kit_project_api_keys_project_uuid_fkey
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_api_keys
      ADD CONSTRAINT phoenix_kit_project_api_keys_project_uuid_fkey
      FOREIGN KEY (project_uuid) REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE SET NULL
    """)
  end

  # Back to one project per key: each key keeps its home — or, its home
  # gone, its oldest grant that still opens something — with THAT grant's
  # role and the scopes V23 knows, so it has no more than it had there
  # (the key's own columns may still hold what it was minted with). A key
  # with nothing usable left goes. Then the grants go. Responses stored for
  # retries under V24 are keyed by a hash V23 cannot rebuild; a retry
  # across the rollback is not recognised (they are kept, not trusted).
  defp down_v24(p) do
    execute("""
    UPDATE #{p}phoenix_kit_project_api_keys k
    SET project_uuid = (
      SELECT g.project_uuid FROM #{p}phoenix_kit_project_api_key_grants g
      WHERE g.api_key_uuid = k.uuid AND g.scopes <> '{}'
      ORDER BY g.inserted_at LIMIT 1
    )
    WHERE k.project_uuid IS NULL
       OR NOT EXISTS (
         SELECT 1 FROM #{p}phoenix_kit_project_api_key_grants g
         WHERE g.api_key_uuid = k.uuid AND g.project_uuid = k.project_uuid AND g.scopes <> '{}'
       )
    """)

    execute("""
    UPDATE #{p}phoenix_kit_project_api_keys k
    SET role = g.role,
        scopes = ARRAY(
          SELECT unnest(g.scopes)
          INTERSECT
          SELECT unnest(ARRAY['tasks:write','time:write','usage:write','project:write',
                              'interactions:read','interactions:write'])
        )
        -- V23's tasks:read also read the project, notes, time, usage,
        -- events and people: only a grant that read all of them gets it back.
        || CASE WHEN g.scopes @> ARRAY['tasks:read','project:read','notes:read','time:read',
                                       'usage:read','events:read','people:read']
             THEN ARRAY['tasks:read'] ELSE ARRAY[]::text[] END
    FROM #{p}phoenix_kit_project_api_key_grants g
    WHERE g.api_key_uuid = k.uuid AND g.project_uuid = k.project_uuid
    """)

    execute("DELETE FROM #{p}phoenix_kit_project_api_keys WHERE project_uuid IS NULL")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_api_key_grants")

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_api_keys
      DROP CONSTRAINT IF EXISTS phoenix_kit_project_api_keys_project_uuid_fkey
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_api_keys
      ADD CONSTRAINT phoenix_kit_project_api_keys_project_uuid_fkey
      FOREIGN KEY (project_uuid) REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_api_keys
      ALTER COLUMN project_uuid SET NOT NULL
    """)
  end

  # V23 — tasks under tasks (Max, 2026-10-14: "let's make proper subtasks
  # because we want flexibility"). A task may have a PARENT task in the same
  # project, to any depth; a subtask is a whole task (its own number, owner,
  # dates, hours), not a line inside its parent.
  #
  #   * `parent_uuid` — the task this one sits under. A trigger keeps the
  #     two rules no insert path may skip: the parent is in the same project,
  #     and nothing is its own ancestor. Deleting a parent takes the rows
  #     under it (the context removes them first, so a sub-project row among
  #     them is torn down properly; the cascade is the net under that).
  #   * `position` stays ONE order for the whole project, written depth
  #     first: a parent is followed by everything under it. Every reader that
  #     sorted by position keeps a sensible order without knowing about
  #     parents.
  #   * `review_status` gains `removed`: a task taken out of the list that
  #     still carries something (hours, a discussion, subtasks) is held, out
  #     of every list and count like a pending request, until a person
  #     restores it or confirms the delete.
  #   * a task's title may be 500 characters (a checklist item could be).
  #   * the V19 `checklist` is gone: every item becomes a subtask of the
  #     task that carried it (same order, ticked ones done at the time they
  #     were ticked; who ticked an item was never recorded), and the column
  #     is dropped. Guarded on the column, so a re-run converts nothing.
  defp v23_subtasks(p, prefix) do
    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
      ADD COLUMN IF NOT EXISTS parent_uuid UUID
        REFERENCES #{p}phoenix_kit_project_assignments(uuid) ON DELETE CASCADE
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_parent_index
    ON #{p}phoenix_kit_project_assignments (parent_uuid) WHERE parent_uuid IS NOT NULL
    """)

    execute("""
    CREATE OR REPLACE FUNCTION #{p}pkp_assignment_parent_check() RETURNS trigger AS $$
    DECLARE
      cur UUID;
      up UUID;
      proj UUID;
      hops INTEGER := 0;
    BEGIN
      IF NEW.parent_uuid IS NULL THEN
        RETURN NEW;
      END IF;

      cur := NEW.parent_uuid;

      WHILE cur IS NOT NULL LOOP
        IF cur = NEW.uuid OR hops > 100 THEN
          RAISE EXCEPTION 'a task cannot sit under itself'
            USING ERRCODE = 'check_violation',
                  CONSTRAINT = 'phoenix_kit_project_assignments_parent_cycle',
                  TABLE = 'phoenix_kit_project_assignments';
        END IF;

        SELECT a.parent_uuid, a.project_uuid INTO up, proj
        FROM #{p}phoenix_kit_project_assignments a WHERE a.uuid = cur;

        IF hops = 0 AND proj IS DISTINCT FROM NEW.project_uuid THEN
          RAISE EXCEPTION 'the parent task is in another project'
            USING ERRCODE = 'check_violation',
                  CONSTRAINT = 'phoenix_kit_project_assignments_parent_project',
                  TABLE = 'phoenix_kit_project_assignments';
        END IF;

        cur := up;
        hops := hops + 1;
      END LOOP;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute(
      "DROP TRIGGER IF EXISTS pkp_assignment_parent_check ON #{p}phoenix_kit_project_assignments"
    )

    execute("""
    CREATE TRIGGER pkp_assignment_parent_check
    BEFORE INSERT OR UPDATE OF parent_uuid, project_uuid ON #{p}phoenix_kit_project_assignments
    FOR EACH ROW EXECUTE FUNCTION #{p}pkp_assignment_parent_check()
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
    DROP CONSTRAINT IF EXISTS phoenix_kit_project_assignments_review_status_check
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
    ADD CONSTRAINT phoenix_kit_project_assignments_review_status_check
    CHECK (review_status IN ('pending', 'accepted', 'rejected', 'removed'))
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_tasks
      ALTER COLUMN title TYPE VARCHAR(500)
    """)

    execute("""
    DO $$
    DECLARE
      r RECORD;
      item RECORD;
      new_task UUID;
      done BOOLEAN;
      done_at TIMESTAMPTZ;
      converted INTEGER := 0;
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{prefix}'
          AND table_name = 'phoenix_kit_project_assignments'
          AND column_name = 'checklist'
      ) THEN
        RETURN;
      END IF;

      FOR r IN
        SELECT a.uuid, a.project_uuid, a.checklist, a.review_status
        FROM #{p}phoenix_kit_project_assignments a
        WHERE jsonb_typeof(a.checklist) = 'array' AND jsonb_array_length(a.checklist) > 0
        ORDER BY a.project_uuid, a.position, a.inserted_at, a.uuid
      LOOP
        FOR item IN
          SELECT e.value AS v, e.ordinality AS n
          FROM jsonb_array_elements(r.checklist) WITH ORDINALITY AS e(value, ordinality)
          ORDER BY e.ordinality
        LOOP
          CONTINUE WHEN btrim(COALESCE(item.v->>'text', '')) = '';

          done := COALESCE(item.v->>'done', 'false') = 'true';
          done_at := NULL;

          IF done THEN
            BEGIN
              done_at := (item.v->>'done_at')::timestamptz;
            EXCEPTION WHEN OTHERS THEN
              done_at := NULL;
            END;
            done_at := COALESCE(done_at, now());
          END IF;

          INSERT INTO #{p}phoenix_kit_project_tasks (title, ad_hoc)
          VALUES (left(btrim(item.v->>'text'), 500), true)
          RETURNING uuid INTO new_task;

          INSERT INTO #{p}phoenix_kit_project_assignments
            (project_uuid, task_uuid, parent_uuid, position, status, progress_pct,
             completed_at, review_status)
          VALUES
            (r.project_uuid, new_task, r.uuid, item.n::integer,
             CASE WHEN done THEN 'done' ELSE 'todo' END,
             CASE WHEN done THEN 100 ELSE 0 END,
             done_at, r.review_status);

          converted := converted + 1;
        END LOOP;
      END LOOP;

      -- Nothing converted (a replay of the chain: v19 re-adds the column
      -- empty): leave every position as it is.
      IF converted = 0 THEN
        RETURN;
      END IF;

      -- One depth-first order per project that now has subtasks.
      WITH RECURSIVE walk AS (
        SELECT a.uuid, a.project_uuid,
               ARRAY[a.position::bigint, (extract(epoch FROM a.inserted_at) * 1000000)::bigint] AS path
        FROM #{p}phoenix_kit_project_assignments a
        WHERE a.parent_uuid IS NULL
          AND a.project_uuid IN (
            SELECT DISTINCT project_uuid FROM #{p}phoenix_kit_project_assignments
            WHERE parent_uuid IS NOT NULL
          )
        UNION ALL
        SELECT c.uuid, c.project_uuid,
               walk.path || ARRAY[c.position::bigint, (extract(epoch FROM c.inserted_at) * 1000000)::bigint]
        FROM #{p}phoenix_kit_project_assignments c
        JOIN walk ON c.parent_uuid = walk.uuid
      ),
      ordered AS (
        SELECT uuid, row_number() OVER (PARTITION BY project_uuid ORDER BY path, uuid) AS n
        FROM walk
      )
      UPDATE #{p}phoenix_kit_project_assignments a
      SET position = ordered.n
      FROM ordered
      WHERE a.uuid = ordered.uuid;
    END $$;
    """)

    execute("ALTER TABLE #{p}phoenix_kit_project_assignments DROP COLUMN IF EXISTS checklist")
  end

  # Subtasks become top-level tasks again (their rows are work, never
  # dropped); held rows are deleted, since the older shape cannot say
  # "removed". The checklist column returns empty.
  defp down_v23(p) do
    execute(
      "DROP TRIGGER IF EXISTS pkp_assignment_parent_check ON #{p}phoenix_kit_project_assignments"
    )

    execute("DROP FUNCTION IF EXISTS #{p}pkp_assignment_parent_check()")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_project_assignments_parent_index")
    execute("ALTER TABLE #{p}phoenix_kit_project_assignments DROP COLUMN IF EXISTS parent_uuid")

    execute("DELETE FROM #{p}phoenix_kit_project_assignments WHERE review_status = 'removed'")

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
    DROP CONSTRAINT IF EXISTS phoenix_kit_project_assignments_review_status_check
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
    ADD CONSTRAINT phoenix_kit_project_assignments_review_status_check
    CHECK (review_status IN ('pending', 'accepted', 'rejected'))
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
      ADD COLUMN IF NOT EXISTS checklist JSONB NOT NULL DEFAULT '[]'
    """)
  end

  # V21 — a task's own dates (Max, 2026-10-06: "build a start date and an
  # end date"). Until now a task's days were only ever computed from its
  # duration and its place in the order; an ongoing project has no anchor
  # to compute from, so nothing there could carry a date. Two optional
  # calendar dates (no time, no zone: "by Thursday" means Thursday
  # wherever the reader sits); either may stand alone; the end is never
  # before the start. A partial index serves "what is due".
  defp v21_task_dates(p) do
    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
      ADD COLUMN IF NOT EXISTS start_date DATE,
      ADD COLUMN IF NOT EXISTS end_date DATE
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_project_assignments_dates_check'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_project_assignments
          ADD CONSTRAINT phoenix_kit_project_assignments_dates_check
          CHECK (start_date IS NULL OR end_date IS NULL OR end_date >= start_date);
      END IF;
    END $$;
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_end_date_index
    ON #{p}phoenix_kit_project_assignments (project_uuid, end_date)
    WHERE end_date IS NOT NULL
    """)
  end

  # V22 — the names people use instead of a uuid (`PhoenixKitProjects.Refs`):
  # a project's KEY (`ACME`) and a task's NUMBER in its project (`ACME-42`).
  #
  # Both rules live in the database, so no insert path can skip them (a
  # clone inserts hundreds of rows; the next code path will not call the
  # context function):
  #
  #   * `phoenix_kit_project_keys` is every key any project has ever had —
  #     the current one and the ones it was renamed from. A trigger on the
  #     projects table registers a key when it is set and refuses one that
  #     is another project's (with the registry's primary-key name, so the
  #     changeset reports it like any unique violation). A row outlives its
  #     project (`ON DELETE SET NULL`): an old `KEY-12` in a commit message
  #     must never come to mean somebody else's task.
  #   * a project inserted with no key gets a placeholder from a sequence
  #     (`P7`, `TPL7` for a template — a template must not squat the key a
  #     real project would want). The context suggests a key from the name
  #     for real projects (`Projects.create_project/2`); the placeholder is
  #     what a path that bypasses it gets.
  #   * `phoenix_kit_project_task_counters` holds the last number handed out
  #     per project — its own table, so numbering a task never locks the
  #     project row a settings form is saving. A trigger numbers every new
  #     assignment that arrives without one. Numbers are never reused: a
  #     deleted task leaves a gap.
  #
  # Existing rows are backfilled: tasks numbered per project in the order
  # they were created; real projects keyed from their names (the Elixir
  # rule, run from here), templates from the sequence.
  defp v22_refs(p, prefix) do
    execute("""
    ALTER TABLE #{p}phoenix_kit_projects
      ADD COLUMN IF NOT EXISTS key VARCHAR(12)
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_projects_key_index
    ON #{p}phoenix_kit_projects (key) WHERE key IS NOT NULL
    """)

    execute("CREATE SEQUENCE IF NOT EXISTS #{p}phoenix_kit_project_key_seq")

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_keys (
      key VARCHAR(12) PRIMARY KEY,
      project_uuid UUID REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE SET NULL,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_keys_project_index
    ON #{p}phoenix_kit_project_keys (project_uuid)
    """)

    execute("""
    CREATE OR REPLACE FUNCTION #{p}pkp_project_key_default() RETURNS trigger AS $$
    BEGIN
      IF NEW.key IS NULL OR btrim(NEW.key) = '' THEN
        LOOP
          NEW.key := (CASE WHEN NEW.is_template THEN 'TPL' ELSE 'P' END)
            || nextval('#{p}phoenix_kit_project_key_seq');
          EXIT WHEN NOT EXISTS (
            SELECT 1 FROM #{p}phoenix_kit_project_keys k WHERE k.key = NEW.key
          );
        END LOOP;
      ELSE
        NEW.key := upper(btrim(NEW.key));
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE OR REPLACE FUNCTION #{p}pkp_project_key_register() RETURNS trigger AS $$
    DECLARE
      holder UUID;
      known BOOLEAN;
    BEGIN
      IF NEW.key IS NULL THEN
        RETURN NEW;
      END IF;

      INSERT INTO #{p}phoenix_kit_project_keys (key, project_uuid)
      VALUES (NEW.key, NEW.uuid)
      ON CONFLICT (key) DO NOTHING;

      SELECT k.project_uuid, true INTO holder, known
      FROM #{p}phoenix_kit_project_keys k WHERE k.key = NEW.key;

      IF holder IS DISTINCT FROM NEW.uuid THEN
        RAISE EXCEPTION 'project key % belongs to another project', NEW.key
          USING ERRCODE = 'unique_violation',
                CONSTRAINT = 'phoenix_kit_project_keys_pkey',
                TABLE = 'phoenix_kit_project_keys';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("DROP TRIGGER IF EXISTS pkp_project_key_default ON #{p}phoenix_kit_projects")

    execute("""
    CREATE TRIGGER pkp_project_key_default
    BEFORE INSERT OR UPDATE OF key ON #{p}phoenix_kit_projects
    FOR EACH ROW EXECUTE FUNCTION #{p}pkp_project_key_default()
    """)

    execute("DROP TRIGGER IF EXISTS pkp_project_key_register ON #{p}phoenix_kit_projects")

    execute("""
    CREATE TRIGGER pkp_project_key_register
    AFTER INSERT OR UPDATE OF key ON #{p}phoenix_kit_projects
    FOR EACH ROW EXECUTE FUNCTION #{p}pkp_project_key_register()
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
      ADD COLUMN IF NOT EXISTS number INTEGER
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_task_counters (
      project_uuid UUID PRIMARY KEY
        REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE,
      last_number INTEGER NOT NULL DEFAULT 0
    )
    """)

    # Rows from before this version, in the order they were made. Only the
    # unnumbered ones, on top of what the project already handed out, so a
    # re-run changes nothing.
    execute("""
    WITH numbered AS (
      SELECT a.uuid,
             COALESCE(c.last_number, 0) + row_number() OVER (
               PARTITION BY a.project_uuid ORDER BY a.inserted_at, a.uuid
             ) AS n
      FROM #{p}phoenix_kit_project_assignments a
      LEFT JOIN #{p}phoenix_kit_project_task_counters c ON c.project_uuid = a.project_uuid
      WHERE a.number IS NULL
    )
    UPDATE #{p}phoenix_kit_project_assignments a
    SET number = numbered.n
    FROM numbered
    WHERE a.uuid = numbered.uuid
    """)

    execute("""
    INSERT INTO #{p}phoenix_kit_project_task_counters (project_uuid, last_number)
    SELECT project_uuid, max(number)
    FROM #{p}phoenix_kit_project_assignments
    WHERE number IS NOT NULL
    GROUP BY project_uuid
    ON CONFLICT (project_uuid) DO UPDATE
      SET last_number = GREATEST(
        #{p}phoenix_kit_project_task_counters.last_number, EXCLUDED.last_number
      )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_assignments_number_index
    ON #{p}phoenix_kit_project_assignments (project_uuid, number)
    """)

    execute("""
    CREATE OR REPLACE FUNCTION #{p}pkp_assignment_number() RETURNS trigger AS $$
    BEGIN
      IF NEW.number IS NULL THEN
        INSERT INTO #{p}phoenix_kit_project_task_counters AS c (project_uuid, last_number)
        VALUES (NEW.project_uuid, 1)
        ON CONFLICT (project_uuid) DO UPDATE SET last_number = c.last_number + 1
        RETURNING c.last_number INTO NEW.number;
      ELSE
        INSERT INTO #{p}phoenix_kit_project_task_counters AS c (project_uuid, last_number)
        VALUES (NEW.project_uuid, NEW.number)
        ON CONFLICT (project_uuid) DO UPDATE
          SET last_number = GREATEST(c.last_number, EXCLUDED.last_number);
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("DROP TRIGGER IF EXISTS pkp_assignment_number ON #{p}phoenix_kit_project_assignments")

    execute("""
    CREATE TRIGGER pkp_assignment_number
    BEFORE INSERT ON #{p}phoenix_kit_project_assignments
    FOR EACH ROW EXECUTE FUNCTION #{p}pkp_assignment_number()
    """)

    execute("""
    UPDATE #{p}phoenix_kit_projects
    SET key = 'TPL' || nextval('#{p}phoenix_kit_project_key_seq')
    WHERE key IS NULL AND is_template
    """)

    execute(fn -> backfill_project_keys(repo(), prefix) end)
  end

  @doc false
  # Real projects get the key their name suggests, oldest first, so the
  # first "Kitchen" is `KIT` and the next `KIT2`. `Refs.suggest_key/2` is
  # the one place that rule is written; this only feeds it what is taken.
  # Public for its test: a fresh test database has no projects to backfill,
  # so the chain alone never runs this over a row.
  def backfill_project_keys(repo, prefix) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT uuid::text, name FROM #{prefix}.phoenix_kit_projects
        WHERE key IS NULL ORDER BY inserted_at, uuid
        """,
        []
      )

    %{rows: taken} = repo.query!("SELECT key FROM #{prefix}.phoenix_kit_project_keys", [])

    Enum.reduce(rows, MapSet.new(taken, fn [key] -> key end), fn [uuid, name], taken ->
      key = PhoenixKitProjects.Refs.suggest_key(name, &MapSet.member?(taken, &1))

      # The uuid travels as text both ways: a `$2::uuid` parameter wants the
      # 16 raw bytes, not the string the SELECT above returned.
      repo.query!(
        "UPDATE #{prefix}.phoenix_kit_projects SET key = $1 WHERE uuid::text = $2",
        [key, uuid]
      )

      MapSet.put(taken, key)
    end)
  end

  # V20 — two corrections from the panel's sweep of V19 (2026-10-05).
  # `words_by_key_uuid`: whose words a task's title and description are —
  # the API key that wrote them last, or nil for a person's; the wording
  # policy asks this, not who created the task (a person's rewording must
  # stick). The task ↔ interaction link gets a table of its own: a link
  # kept only as a mention token in the description vanished with any
  # rewrite of the description.
  defp v20_words_and_links(p) do
    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
      ADD COLUMN IF NOT EXISTS words_by_key_uuid UUID
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_task_interactions (
      assignment_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_project_assignments(uuid) ON DELETE CASCADE,
      interaction_uuid UUID NOT NULL,
      added_by_uuid UUID,
      added_by_key_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (assignment_uuid, interaction_uuid)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_task_interactions_interaction_index
    ON #{p}phoenix_kit_project_task_interactions (interaction_uuid)
    """)
  end

  # V19 — what an agent working a project over the API needs on a task
  # (the first agent's review, 2026-10-05): who created it and who started
  # it (a person and/or the key, for claims and for wording protection),
  # `waiting_on` (blocked on someone — a badge, not a fourth status),
  # `origin` (where a relayed item came from; `source` already means internal vs portal), a `checklist` (sub-items
  # ticked one by one, JSONB `[{id, text, done, done_at}]`), and an index
  # for `updated_since` polling. No foreign keys: provenance is history.
  defp v19_agent_work(p) do
    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
      ADD COLUMN IF NOT EXISTS created_by_uuid UUID,
      ADD COLUMN IF NOT EXISTS created_by_key_uuid UUID,
      ADD COLUMN IF NOT EXISTS started_by_uuid UUID,
      ADD COLUMN IF NOT EXISTS started_by_key_uuid UUID,
      ADD COLUMN IF NOT EXISTS waiting_on VARCHAR(200),
      ADD COLUMN IF NOT EXISTS origin VARCHAR(40),
      ADD COLUMN IF NOT EXISTS checklist JSONB NOT NULL DEFAULT '[]'
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_updated_index
    ON #{p}phoenix_kit_project_assignments (project_uuid, updated_at)
    """)
  end

  # V18 — a key acts for a person. `user_uuid` names the member whose
  # authority the key exercises: their current membership decides what the
  # key may do and the activity feed names them. Nullable: a key with no
  # person is a shared agent (a CI runner, a project-wide bot) that keeps
  # its own stored role. Not a foreign key, like `created_by_uuid` — the
  # row is audit history once the person is gone; the API refuses it.
  defp v18_key_persons(p) do
    execute("""
    ALTER TABLE #{p}phoenix_kit_project_api_keys
      ADD COLUMN IF NOT EXISTS user_uuid UUID
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_api_keys_person_index
    ON #{p}phoenix_kit_project_api_keys (project_uuid, user_uuid)
    """)
  end

  # V16 — whiteboards without a background file. Core V183 lets an
  # annotation anchor to any `target_type` + `target_uuid`, and Fresco
  # renders a scene with zero images, so a board no longer needs the
  # salted white PNG the bridge used to mint: `file_uuid` goes nullable
  # and a new board is drawn on an empty canvas. Boards created before
  # (and boards over a real image via `create_board_for_file/3`) keep
  # their file and keep working exactly as they did — the two shapes
  # coexist; the LV picks the viewer by whether a file is there.
  defp v16_fileless_whiteboards(p) do
    execute("""
    ALTER TABLE #{p}phoenix_kit_project_whiteboards
      ALTER COLUMN file_uuid DROP NOT NULL
    """)
  end

  # V15 — one-off tasks. An assignment has no title of its own: adding an
  # ad-hoc task to a project has always minted a library `Task` first, so a
  # quick-add composer (Todoist-style, 2026-09) would fill the reusable
  # library with "call the client" fifty times over. The flag keeps those
  # rows out of every library surface (list, pickers, counts) by default
  # while the assignment that points at them works exactly like any other.
  # Promotion is a checkbox on the task form; nothing is ever deleted.
  defp v15_ad_hoc_tasks(p) do
    execute("""
    ALTER TABLE #{p}phoenix_kit_project_tasks
    ADD COLUMN IF NOT EXISTS ad_hoc BOOLEAN NOT NULL DEFAULT false
    """)

    # The library list and pickers filter on it on every load; one-off
    # rows are expected to outnumber library rows on a busy install.
    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_tasks_ad_hoc_idx
      ON #{p}phoenix_kit_project_tasks (ad_hoc)
    """)
  end

  defp v13_submission_attachments(p) do
    execute("""
    ALTER TABLE #{p}phoenix_kit_project_portal_submissions
    ADD COLUMN IF NOT EXISTS file_uuids JSONB NOT NULL DEFAULT '[]'
    """)
  end

  defp v12_public_board(p) do
    execute("""
    ALTER TABLE #{p}phoenix_kit_project_portals
    ADD COLUMN IF NOT EXISTS access_mode VARCHAR(16) NOT NULL DEFAULT 'link'
    """)

    # What outsiders may DO, split from who may look. Submitting and
    # discussing are different risks: a submission is invisible until staff
    # act on it, a comment is live surface area the moment it lands.
    execute("""
    ALTER TABLE #{p}phoenix_kit_project_portals
    ADD COLUMN IF NOT EXISTS submit_access VARCHAR(16) NOT NULL DEFAULT 'anyone'
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_portals
    ADD COLUMN IF NOT EXISTS comment_access VARCHAR(16) NOT NULL DEFAULT 'nobody'
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.constraint_column_usage
        WHERE table_schema = current_schema()
          AND constraint_name = 'phoenix_kit_project_portals_access_mode_check'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_project_portals
          ADD CONSTRAINT phoenix_kit_project_portals_access_mode_check
          CHECK (access_mode IN ('link', 'members', 'public'));
      END IF;
    END $$;
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_project_assignments
    ADD COLUMN IF NOT EXISTS board_published_at TIMESTAMPTZ
    """)

    # The public board's read query filters on it, and a board with many
    # tasks behind it is the normal case.
    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_board_published_index
      ON #{p}phoenix_kit_project_assignments (project_uuid, board_published_at)
      WHERE (board_published_at IS NOT NULL)
    """)
  end

  defp v11_subject_grants(p, prefix) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_subject_grants (
      uuid UUID PRIMARY KEY DEFAULT #{prefix}.uuid_generate_v7(),
      project_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE,
      subject_type VARCHAR(16) NOT NULL,
      subject_uuid UUID NOT NULL,
      role VARCHAR(20) NOT NULL DEFAULT 'viewer',
      granted_by_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT phoenix_kit_project_subject_grants_type_check
        CHECK (subject_type IN ('team', 'department', 'role')),
      CONSTRAINT phoenix_kit_project_subject_grants_role_check
        CHECK (role IN ('manager', 'member', 'viewer'))
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_subject_grants_identity_index
    ON #{p}phoenix_kit_project_subject_grants (project_uuid, subject_type, subject_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_subject_grants_project_index
    ON #{p}phoenix_kit_project_subject_grants (project_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_subject_grants_subject_index
    ON #{p}phoenix_kit_project_subject_grants (subject_type, subject_uuid)
    """)
  end

  # ---------------------------------------------------------------------------

  defp normalize_prefix(opts) when is_list(opts), do: Keyword.get(opts, :prefix) || "public"
  defp normalize_prefix(%{prefix: prefix}) when is_binary(prefix), do: prefix
  defp normalize_prefix(_), do: "public"

  defp prefix_str(prefix), do: "#{prefix}."
end
