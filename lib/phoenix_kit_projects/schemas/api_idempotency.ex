defmodule PhoenixKitProjects.Schemas.ApiIdempotency do
  @moduledoc """
  A stored API response (`phoenix_kit_project_api_idempotency`, chain V17):
  what a POST carrying an `Idempotency-Key` answered, kept under
  (key, header) so a retry of the same request — a timeout the agent could
  not tell from a loss — answers with the same response instead of a
  second ledger row or a second task. Rows cascade with their key.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  schema "phoenix_kit_project_api_idempotency" do
    field(:api_key_uuid, UUIDv7, primary_key: true)
    field(:idempotency_key, :string, primary_key: true)
    field(:status, :integer)
    field(:body, :map, default: %{})

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:api_key_uuid, :idempotency_key, :status, :body])
    |> validate_required([:api_key_uuid, :idempotency_key, :status])
    |> validate_length(:idempotency_key, min: 1, max: 128)
  end
end
