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

  @current_version 8
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

  # ---------------------------------------------------------------------------

  defp normalize_prefix(opts) when is_list(opts), do: Keyword.get(opts, :prefix) || "public"
  defp normalize_prefix(%{prefix: prefix}) when is_binary(prefix), do: prefix
  defp normalize_prefix(_), do: "public"

  defp prefix_str(prefix), do: "#{prefix}."
end
