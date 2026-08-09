defmodule PhoenixKitProjects.Schemas.PortalSubmission do
  @moduledoc """
  Provenance row for one anonymous portal submission (chain V10) — PII
  lives HERE and only here, so deleting it erases everything the portal
  learned about the submitter. v1 collects NO email (the panel's
  mail-bombing find — the notify-submitter feature waits for a
  double-opt-in design); the column exists for that v2. `ip_hash` is a
  truncated peppered HMAC — abuse telemetry, deliberately not an
  identifier.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  alias PhoenixKitProjects.Schemas.Assignment

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "phoenix_kit_project_portal_submissions" do
    field(:email, :string)
    field(:ip_hash, :string)
    # Storage uuids for the images that came with the report. Sanitised
    # before they got here — see PhoenixKit.Modules.Storage.ImageProcessor.
    field(:file_uuids, {:array, :string}, default: [])

    belongs_to(:assignment, Assignment, foreign_key: :assignment_uuid, references: :uuid)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(submission, attrs) do
    submission
    |> cast(attrs, [:assignment_uuid, :email, :ip_hash, :file_uuids])
    |> validate_required([:assignment_uuid])
    |> validate_length(:email, max: 160)
    |> foreign_key_constraint(:assignment_uuid)
  end
end
