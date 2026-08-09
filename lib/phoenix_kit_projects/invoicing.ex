defmodule PhoenixKitProjects.Invoicing do
  @moduledoc """
  The ledger→invoice bridge (Phase E, Option B of the panel-settled
  design): generate a DRAFT invoice in `phoenix_kit_billing` from this
  project's uninvoiced billable time.

  ## Boundary (non-negotiable, per the consult)

    * Billing never knows about projects: the write goes through
      `PhoenixKitBilling.create_invoice/2` (guarded `apply/3` — billing
      is not a dependency), with opaque `source_*` metadata for audit.
    * Projects owns "what's billed": the V8
      `phoenix_kit_project_invoiced_entries` ref table (entry_uuid PK =
      one invoice per entry, the idempotency rule). The append-only
      ledger is never mutated — billed-ness DERIVES from the refs.

  ## The honest v1

  Draft only — a human reviews and issues in Billing. Bills HUMAN
  billable time only (`kind == "time"`, `billable == true`,
  `actor_kind in user/staff_person`); AI cost needs a margin policy →
  v2. Minutes price via the `rate_cents_per_hour` config on the
  `billing_customer` extension (one money-settings home), snapshotted
  onto the line items at generation. Lines group by task.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.PubSub
  alias PhoenixKitProjects.Schemas.Assignment
  alias PhoenixKitProjects.Schemas.WorkEntry

  @refs_table "phoenix_kit_project_invoiced_entries"
  @prefix Application.compile_env(:phoenix_kit, :prefix)
  @human_actors ~w(user staff_person)

  @doc """
  Whether draft generation is POSSIBLE for a project: billing installed
  and enabled, the `billing_customer` extension enabled with a resolvable
  profile and a positive rate. Returns `{:ok, %{profile:, rate_cents:}}`
  or a tagged error the UI can phrase.
  """
  @spec setup(map()) :: {:ok, map()} | {:error, atom()}
  def setup(project) do
    config = billing_config(project)

    cond do
      not billing_available?() ->
        {:error, :billing_unavailable}

      config == nil ->
        {:error, :extension_disabled}

      true ->
        rate = parse_rate(config["rate_cents_per_hour"])
        profile_uuid = config["billing_profile_uuid"]

        cond do
          rate == nil -> {:error, :no_rate}
          not is_binary(profile_uuid) or profile_uuid == "" -> {:error, :no_profile}
          true -> resolve_profile(profile_uuid, rate)
        end
    end
  end

  @doc "Uninvoiced billable HUMAN time entries for a project, oldest first."
  @spec uninvoiced_entries(binary()) :: [WorkEntry.t()]
  def uninvoiced_entries(project_uuid) do
    invoiced =
      from(r in @refs_table,
        where: r.project_uuid == type(^project_uuid, Ecto.UUID),
        select: r.entry_uuid
      )
      |> with_prefix()

    from(e in WorkEntry,
      where:
        e.project_uuid == ^project_uuid and e.kind == "time" and e.billable == true and
          e.actor_kind in @human_actors and e.uuid not in subquery(invoiced),
      order_by: [asc: e.inserted_at]
    )
    |> RepoHelper.repo().all()
  rescue
    _ -> []
  end

  @doc """
  Generates the draft invoice: prices the uninvoiced entries, creates the
  billing draft, then records the refs. Idempotent at the entry level
  (the PK); a refs failure after the draft exists is surfaced as
  `{:error, :refs_failed, invoice_uuid}` — the draft is real, the
  entries stay re-billable, and the caller tells the human to reconcile
  (the consult's compensating-action note).
  """
  @spec generate_draft(map(), keyword()) ::
          {:ok, %{invoice_uuid: binary(), line_count: non_neg_integer(), total_cents: integer()}}
          | {:error, atom()}
          | {:error, :refs_failed, binary()}
  def generate_draft(project, opts \\ []) do
    with {:ok, %{profile: profile, rate_cents: rate_cents}} <- setup(project),
         entries when entries != [] <- uninvoiced_entries(project.uuid),
         {:ok, invoice} <- create_billing_draft(project, profile, rate_cents, entries) do
      case insert_refs(project.uuid, entries, invoice_uuid(invoice)) do
        :ok ->
          Activity.log("projects.invoice_generated",
            actor_uuid: Keyword.get(opts, :actor_uuid),
            resource_type: "project",
            resource_uuid: project.uuid,
            metadata: %{
              "invoice_uuid" => invoice_uuid(invoice),
              "entries" => length(entries),
              "total_cents" => total_cents(entries, rate_cents)
            }
          )

          PubSub.broadcast_project(:project_invoice_generated, %{uuid: project.uuid})

          {:ok,
           %{
             invoice_uuid: invoice_uuid(invoice),
             line_count: length(entries),
             total_cents: total_cents(entries, rate_cents)
           }}

        :error ->
          Logger.error(
            "[Projects.Invoicing] draft #{invoice_uuid(invoice)} created but refs failed — " <>
              "entries remain re-billable; reconcile manually"
          )

          {:error, :refs_failed, invoice_uuid(invoice)}
      end
    else
      [] -> {:error, :nothing_to_bill}
      {:error, _} = error -> error
    end
  end

  # ── Internals ───────────────────────────────────────────────────

  defp billing_available? do
    Code.ensure_loaded?(PhoenixKitBilling) and
      function_exported?(PhoenixKitBilling, :enabled?, 0) and
      function_exported?(PhoenixKitBilling, :create_invoice, 2) and
      billing_enabled?()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp billing_enabled?, do: apply(PhoenixKitBilling, :enabled?, [])

  defp billing_config(project) do
    project.uuid
    |> PhoenixKitProjects.Extensions.enabled_for_project()
    |> Enum.find_value(fn {ext, row} ->
      if ext.key == "billing_customer", do: (row && row.config) || %{}
    end)
  rescue
    _ -> nil
  end

  defp parse_rate(rate) when is_integer(rate) and rate > 0, do: rate

  defp parse_rate(rate) when is_binary(rate) do
    case Integer.parse(rate) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_rate(_), do: nil

  defp resolve_profile(profile_uuid, rate_cents) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(PhoenixKitBilling, :get_billing_profile, [profile_uuid]) do
      %{user_uuid: user_uuid} = profile when is_binary(user_uuid) ->
        {:ok, %{profile: profile, rate_cents: rate_cents}}

      _ ->
        {:error, :profile_not_found}
    end
  rescue
    _ -> {:error, :profile_not_found}
  end

  defp create_billing_draft(project, profile, rate_cents, entries) do
    line_items = build_line_items(project, rate_cents, entries)
    total = Decimal.div(Decimal.new(total_cents(entries, rate_cents)), 100)

    attrs = %{
      status: "draft",
      line_items: line_items,
      total: total,
      metadata: %{
        "source_type" => "phoenix_kit_projects",
        "source_uuid" => project.uuid,
        "source_kind" => "effort_draft"
      }
    }

    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(PhoenixKitBilling, :create_invoice, [profile.user_uuid, attrs]) do
      {:ok, invoice} -> {:ok, invoice}
      _ -> {:error, :billing_write_failed}
    end
  rescue
    _ -> {:error, :billing_write_failed}
  catch
    :exit, _ -> {:error, :billing_write_failed}
  end

  # One line per task (assignment), quantity in hours (2dp), the rate
  # snapshotted as the unit price. Project-level entries (no assignment)
  # group under the project's own name.
  defp build_line_items(project, rate_cents, entries) do
    labels = assignment_labels(project.uuid, entries)

    entries
    |> Enum.group_by(& &1.assignment_uuid)
    |> Enum.map(fn {assignment_uuid, group} ->
      minutes = group |> Enum.map(&Decimal.to_float(&1.amount)) |> Enum.sum()
      hours = Float.round(minutes / 60, 2)
      cents = round(minutes / 60 * rate_cents)

      %{
        "name" => Map.get(labels, assignment_uuid, project.name),
        "description" => "Logged effort (#{length(group)} entries)",
        "quantity" => hours,
        "unit_price" => format_cents(rate_cents),
        "total" => format_cents(cents)
      }
    end)
    |> Enum.sort_by(& &1["name"])
  end

  defp assignment_labels(project_uuid, entries) do
    uuids = entries |> Enum.map(& &1.assignment_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if uuids == [] do
      %{}
    else
      lang = PhoenixKitProjects.L10n.current_content_lang()

      from(a in Assignment, where: a.uuid in ^uuids and a.project_uuid == ^project_uuid)
      |> preload([:task, :child_project])
      |> RepoHelper.repo().all()
      |> Map.new(fn a -> {a.uuid, Assignment.label(a, lang) || "Task"} end)
    end
  rescue
    _ -> %{}
  end

  defp total_cents(entries, rate_cents) do
    minutes = entries |> Enum.map(&Decimal.to_float(&1.amount)) |> Enum.sum()
    round(minutes / 60 * rate_cents)
  end

  defp format_cents(cents) do
    :erlang.float_to_binary(cents / 100, decimals: 2)
  end

  defp insert_refs(project_uuid, entries, invoice_uuid) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(entries, fn entry ->
        %{
          entry_uuid: Ecto.UUID.dump!(entry.uuid),
          project_uuid: Ecto.UUID.dump!(project_uuid),
          invoice_uuid: Ecto.UUID.dump!(invoice_uuid),
          inserted_at: now
        }
      end)

    {count, _} = RepoHelper.repo().insert_all(@refs_table, rows, prefix: @prefix)
    if count == length(rows), do: :ok, else: :error
  rescue
    e ->
      Logger.error("[Projects.Invoicing] refs insert failed: #{Exception.message(e)}")
      :error
  end

  defp invoice_uuid(%{uuid: uuid}), do: uuid

  defp with_prefix(query) do
    if is_binary(@prefix), do: Ecto.Query.put_query_prefix(query, @prefix), else: query
  end
end
