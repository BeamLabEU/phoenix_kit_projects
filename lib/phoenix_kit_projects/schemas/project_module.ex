defmodule PhoenixKitProjects.Schemas.ProjectModule do
  @moduledoc """
  Per-project extension enablement row (`phoenix_kit_project_modules`).

  One row = one extension *instance* on one project. `instance_key` defaults
  to `"default"` and participates in the unique identity
  `(project_uuid, ext_key, instance_key)` — v1 exposes toggle semantics but
  the identity is instance-ready by design (2026-08-05 panel finding).

  `enabled` is a flag rather than row-existence so a disable preserves
  `config` (and the extension's own data — Redmine semantics: disabling
  hides, never deletes). `config` holds per-instance settings validated
  against the extension's declared `config_schema` — writes go through
  `PhoenixKitProjects.Extensions.update_config/4`, which whitelists keys;
  never cast raw params into it.

  `enabled_by_uuid` is best-effort provenance with NO foreign key — the
  same convention as activity `actor_uuid` throughout this module: a stale
  or unresolvable actor must never fail the admin's toggle (first caught
  by the panel LV test — a fake-scope actor FK-crashed the whole toggle).
  The activity log remains the authoritative audit trail.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  schema "phoenix_kit_project_modules" do
    field(:project_uuid, UUIDv7)
    field(:ext_key, :string)
    field(:instance_key, :string, default: "default")
    field(:name, :string)
    field(:enabled, :boolean, default: true)
    field(:config, :map, default: %{})
    field(:enabled_by_uuid, UUIDv7)

    timestamps(type: :utc_datetime)
  end

  @required ~w(project_uuid ext_key)a
  @optional ~w(instance_key name enabled config enabled_by_uuid)a

  def changeset(row, attrs) do
    row
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:ext_key, max: 100)
    |> validate_length(:instance_key, min: 1, max: 100)
    |> validate_length(:name, max: 255)
    |> unique_constraint([:project_uuid, :ext_key, :instance_key],
      name: :phoenix_kit_project_modules_identity_index
    )
    |> foreign_key_constraint(:project_uuid)
  end
end
