defmodule PhoenixKitProjects.Schemas.WorkEntry do
  @moduledoc """
  One ledger entry (`phoenix_kit_project_work_entries`, chain V4): effort
  spent on a project (optionally a specific assignment) by an ACTOR that
  can be a human (`user` / `staff_person`) or an **`ai_agent`** — the
  boss's unified work ledger. `kind` fixes the amount's unit:

    * `"time"`   — minutes
    * `"tokens"` — token count
    * `"cost"`   — cents

  Append-only by convention (corrections are new entries; there is no
  update path in `PhoenixKitProjects.Ledger`). `actor_uuid` is FK-less —
  AI agents aren't users, and the activity log is the audit trail.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  @actor_kinds ~w(user staff_person ai_agent)
  @kinds ~w(time tokens cost)
  @sources ~w(manual timer ai)

  schema "phoenix_kit_project_work_entries" do
    field(:project_uuid, UUIDv7)
    field(:assignment_uuid, UUIDv7)
    field(:actor_kind, :string, default: "user")
    field(:actor_uuid, UUIDv7)
    field(:kind, :string)
    field(:amount, :decimal)
    field(:started_at, :utc_datetime)
    field(:ended_at, :utc_datetime)
    field(:note, :string)
    field(:source, :string, default: "manual")
    field(:billable, :boolean, default: false)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @required ~w(project_uuid kind amount)a
  @optional ~w(assignment_uuid actor_kind actor_uuid started_at ended_at note source billable metadata)a

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:actor_kind, @actor_kinds)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:source, @sources)
    |> validate_number(:amount, greater_than: 0)
    |> foreign_key_constraint(:project_uuid)
    |> foreign_key_constraint(:assignment_uuid)
  end

  def actor_kinds, do: @actor_kinds
  def kinds, do: @kinds
end
