defmodule PhoenixKitProjects.Test.Repo.Migrations.SetupPhoenixKit do
  @moduledoc """
  Test-only schema setup for `phoenix_kit_projects`.

  Mirrors the workspace pattern (locations, hello_world, staff): every
  feature module ships a self-contained migration under
  `test/support/postgres/migrations/` so `mix test` doesn't depend on
  what the host's DB happens to have applied.

  Three stages, because Projects has a hard dep on Staff and Staff
  schemas FK to `phoenix_kit_users`:

  1. `PhoenixKit.Migrations.up()` — V01..VNN of the resolved
     `phoenix_kit` package. Yields `phoenix_kit_users`,
     `phoenix_kit_settings`, `phoenix_kit_activities`, the role tables,
     etc. Hex `1.7.95` reaches V96 today.

  2. **V100 staff DDL** — inlined verbatim from
     `phoenix_kit/lib/phoenix_kit/migrations/postgres/v100.ex`, since
     Hex 1.7.95 predates V100. Wrapped in `IF NOT EXISTS` so the day
     core publishes a release containing V100, this block becomes a
     no-op.

  3. **V101 projects DDL** — inlined verbatim from
     `phoenix_kit/lib/phoenix_kit/migrations/postgres/v101.ex`, same
     `IF NOT EXISTS` pattern.

  4. **V105 partial-index conversion for `phoenix_kit_projects.name`** —
     inlined to keep tests in sync with the post-V105 production
     schema (templates and real projects can share a name freely).
     Idempotent against any future Hex release containing V105 thanks
     to `DROP INDEX IF EXISTS` + `CREATE UNIQUE INDEX IF NOT EXISTS`.

  If V100, V101, or V105 ever change column shape upstream, this
  migration must follow.
  """

  use Ecto.Migration

  def up do
    # Stage 1 — core tables (V01..V96 under Hex 1.7.95).
    PhoenixKit.Migrations.up()

    # Stage 2 — V100 staff tables.
    execute("""
    CREATE TABLE IF NOT EXISTS phoenix_kit_staff_departments (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      description TEXT,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_departments_name_index
    ON phoenix_kit_staff_departments (lower(name))
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS phoenix_kit_staff_teams (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      department_uuid UUID NOT NULL REFERENCES phoenix_kit_staff_departments(uuid) ON DELETE CASCADE,
      name VARCHAR(255) NOT NULL,
      description TEXT,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_teams_department_name_index
    ON phoenix_kit_staff_teams (department_uuid, lower(name))
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_staff_teams_department_index
    ON phoenix_kit_staff_teams (department_uuid)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS phoenix_kit_staff_people (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      user_uuid UUID NOT NULL REFERENCES phoenix_kit_users(uuid) ON DELETE CASCADE,
      primary_department_uuid UUID REFERENCES phoenix_kit_staff_departments(uuid) ON DELETE SET NULL,
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      job_title VARCHAR(255),
      employment_type VARCHAR(20),
      employment_start_date DATE,
      employment_end_date DATE,
      work_location VARCHAR(255),
      work_phone VARCHAR(50),
      personal_phone VARCHAR(50),
      bio TEXT,
      skills TEXT,
      notes TEXT,
      date_of_birth DATE,
      personal_email VARCHAR(255),
      emergency_contact_name VARCHAR(255),
      emergency_contact_phone VARCHAR(50),
      emergency_contact_relationship VARCHAR(100),
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_people_user_index
    ON phoenix_kit_staff_people (user_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_staff_people_primary_department_index
    ON phoenix_kit_staff_people (primary_department_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_staff_people_status_index
    ON phoenix_kit_staff_people (status)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS phoenix_kit_staff_team_memberships (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      team_uuid UUID NOT NULL REFERENCES phoenix_kit_staff_teams(uuid) ON DELETE CASCADE,
      staff_person_uuid UUID NOT NULL REFERENCES phoenix_kit_staff_people(uuid) ON DELETE CASCADE,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_team_memberships_team_person_index
    ON phoenix_kit_staff_team_memberships (team_uuid, staff_person_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_staff_team_memberships_person_index
    ON phoenix_kit_staff_team_memberships (staff_person_uuid)
    """)

    # Stage 3 — V101 projects tables.
    execute("""
    CREATE TABLE IF NOT EXISTS phoenix_kit_project_tasks (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      title VARCHAR(255) NOT NULL,
      description TEXT,
      estimated_duration INTEGER,
      estimated_duration_unit VARCHAR(20) DEFAULT 'hours',
      default_assigned_team_uuid UUID REFERENCES phoenix_kit_staff_teams(uuid) ON DELETE SET NULL,
      default_assigned_department_uuid UUID REFERENCES phoenix_kit_staff_departments(uuid) ON DELETE SET NULL,
      default_assigned_person_uuid UUID REFERENCES phoenix_kit_staff_people(uuid) ON DELETE SET NULL,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT phoenix_kit_project_tasks_single_default_assignee
        CHECK (num_nonnulls(default_assigned_team_uuid, default_assigned_department_uuid, default_assigned_person_uuid) <= 1)
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_tasks_title_index
    ON phoenix_kit_project_tasks (lower(title))
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS phoenix_kit_projects (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      description TEXT,
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      is_template BOOLEAN NOT NULL DEFAULT false,
      counts_weekends BOOLEAN NOT NULL DEFAULT false,
      start_mode VARCHAR(20) NOT NULL DEFAULT 'immediate',
      scheduled_start_date DATE,
      started_at TIMESTAMPTZ,
      completed_at TIMESTAMPTZ,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_projects_name_index
    ON phoenix_kit_projects (lower(name))
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_projects_status_index
    ON phoenix_kit_projects (status)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS phoenix_kit_project_assignments (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      project_uuid UUID NOT NULL REFERENCES phoenix_kit_projects(uuid) ON DELETE CASCADE,
      task_uuid UUID NOT NULL REFERENCES phoenix_kit_project_tasks(uuid) ON DELETE CASCADE,
      status VARCHAR(20) NOT NULL DEFAULT 'todo',
      position INTEGER NOT NULL DEFAULT 0,
      description TEXT,
      estimated_duration INTEGER,
      estimated_duration_unit VARCHAR(20),
      assigned_team_uuid UUID REFERENCES phoenix_kit_staff_teams(uuid) ON DELETE SET NULL,
      assigned_department_uuid UUID REFERENCES phoenix_kit_staff_departments(uuid) ON DELETE SET NULL,
      assigned_person_uuid UUID REFERENCES phoenix_kit_staff_people(uuid) ON DELETE SET NULL,
      counts_weekends BOOLEAN,
      progress_pct INTEGER NOT NULL DEFAULT 0,
      track_progress BOOLEAN NOT NULL DEFAULT false,
      completed_by_uuid UUID REFERENCES phoenix_kit_users(uuid) ON DELETE SET NULL,
      completed_at TIMESTAMPTZ,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT phoenix_kit_project_assignments_single_assignee
        CHECK (num_nonnulls(assigned_team_uuid, assigned_department_uuid, assigned_person_uuid) <= 1)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_project_index
    ON phoenix_kit_project_assignments (project_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_status_index
    ON phoenix_kit_project_assignments (status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_task_index
    ON phoenix_kit_project_assignments (task_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_team_index
    ON phoenix_kit_project_assignments (assigned_team_uuid)
    WHERE assigned_team_uuid IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_department_index
    ON phoenix_kit_project_assignments (assigned_department_uuid)
    WHERE assigned_department_uuid IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_person_index
    ON phoenix_kit_project_assignments (assigned_person_uuid)
    WHERE assigned_person_uuid IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_completed_by_index
    ON phoenix_kit_project_assignments (completed_by_uuid)
    WHERE completed_by_uuid IS NOT NULL
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS phoenix_kit_project_dependencies (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      assignment_uuid UUID NOT NULL REFERENCES phoenix_kit_project_assignments(uuid) ON DELETE CASCADE,
      depends_on_uuid UUID NOT NULL REFERENCES phoenix_kit_project_assignments(uuid) ON DELETE CASCADE,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_dependencies_pair_index
    ON phoenix_kit_project_dependencies (assignment_uuid, depends_on_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_dependencies_depends_on_index
    ON phoenix_kit_project_dependencies (depends_on_uuid)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS phoenix_kit_project_task_dependencies (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      task_uuid UUID NOT NULL REFERENCES phoenix_kit_project_tasks(uuid) ON DELETE CASCADE,
      depends_on_task_uuid UUID NOT NULL REFERENCES phoenix_kit_project_tasks(uuid) ON DELETE CASCADE,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_task_deps_pair_index
    ON phoenix_kit_project_task_dependencies (task_uuid, depends_on_task_uuid)
    """)

    # Stage 4 — V105: split the single global `phoenix_kit_projects.name`
    # index into per-template-type partial indexes.
    execute("DROP INDEX IF EXISTS phoenix_kit_projects_name_index")

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_projects_name_template_index
    ON phoenix_kit_projects (lower(name))
    WHERE is_template = true
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_projects_name_project_index
    ON phoenix_kit_projects (lower(name))
    WHERE is_template = false
    """)
  end

  def down do
    # Drop in reverse order: V105 indexes → V101 projects → V100 staff → core.
    execute("DROP INDEX IF EXISTS phoenix_kit_projects_name_project_index")
    execute("DROP INDEX IF EXISTS phoenix_kit_projects_name_template_index")

    execute("DROP TABLE IF EXISTS phoenix_kit_project_task_dependencies")
    execute("DROP TABLE IF EXISTS phoenix_kit_project_dependencies")
    execute("DROP TABLE IF EXISTS phoenix_kit_project_assignments")
    execute("DROP TABLE IF EXISTS phoenix_kit_projects")
    execute("DROP TABLE IF EXISTS phoenix_kit_project_tasks")

    execute("DROP TABLE IF EXISTS phoenix_kit_staff_team_memberships")
    execute("DROP TABLE IF EXISTS phoenix_kit_staff_people")
    execute("DROP TABLE IF EXISTS phoenix_kit_staff_teams")
    execute("DROP TABLE IF EXISTS phoenix_kit_staff_departments")

    PhoenixKit.Migrations.down()
  end
end
