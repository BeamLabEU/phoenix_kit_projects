defmodule PhoenixKitProjects.Schemas.ProjectMember do
  @moduledoc """
  Per-project membership row (`phoenix_kit_project_members`, chain V3).

  A member is a CORE USER (`user_uuid` → `phoenix_kit_users`) with a project
  role from the frozen `PhoenixKitProjects.Authz.roles/0` enum. Members are
  the hub's native people layer — staff people/teams/departments remain the
  optional *assignee* enrichment, a separate concern.

  `invited_by_uuid` is FK-less best-effort provenance (the activity log is
  the audit trail). Role changes go through `PhoenixKitProjects.Members`,
  which owns the last-owner guard — never update a row's role directly.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitProjects.Authz

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  schema "phoenix_kit_project_members" do
    field(:project_uuid, UUIDv7)
    field(:role, :string, default: "member")
    field(:invited_by_uuid, UUIDv7)

    belongs_to(:user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7)

    timestamps(type: :utc_datetime)
  end

  @required ~w(project_uuid user_uuid)a
  @optional ~w(role invited_by_uuid)a

  def changeset(row, attrs) do
    row
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:role, Enum.map(Authz.roles(), &to_string/1))
    |> unique_constraint([:project_uuid, :user_uuid],
      name: :phoenix_kit_project_members_identity_index
    )
    |> foreign_key_constraint(:project_uuid)
    |> foreign_key_constraint(:user_uuid)
  end
end
