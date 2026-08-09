defmodule PhoenixKitProjects.Integration.InvoicingTest do
  @moduledoc """
  Phase E's projects side: the V8 invoiced-entry refs + the guard chain.
  The billing WRITE itself can't run here (phoenix_kit_billing is not a
  dependency of this package — the bridge is guarded apply/3, verified
  integrated in the parent); what this suite pins is the authority
  logic: uninvoiced derivation, entry-level idempotency, and setup's
  tagged failure modes.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.{Extensions, Invoicing, Ledger}

  setup do
    PhoenixKitProjects.Extensions.Registry.refresh()
    {:ok, project: fixture_project()}
  end

  defp insert_refs(project_uuid, entries, invoice_uuid) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    RepoHelper.repo().insert_all(
      "phoenix_kit_project_invoiced_entries",
      Enum.map(entries, fn e ->
        %{
          entry_uuid: Ecto.UUID.dump!(e.uuid),
          project_uuid: Ecto.UUID.dump!(project_uuid),
          invoice_uuid: Ecto.UUID.dump!(invoice_uuid),
          inserted_at: now
        }
      end)
    )
  end

  test "uninvoiced derivation: billable human time only, refs excluded", %{project: project} do
    {:ok, billable} = Ledger.log_time(project, 60, billable: true)
    {:ok, _free} = Ledger.log_time(project, 30, billable: false)
    {:ok, _ai} = Ledger.record_ai(project, %{tokens: 100, cost_cents: 5})

    assert [%{uuid: uuid}] = Invoicing.uninvoiced_entries(project.uuid)
    assert uuid == billable.uuid

    # Marking it invoiced removes it from the pool (billed-ness DERIVES
    # from the refs; the ledger row is untouched).
    insert_refs(project.uuid, [billable], Ecto.UUID.generate())
    assert Invoicing.uninvoiced_entries(project.uuid) == []
    assert Ledger.totals_for_project(project.uuid).time_minutes == 90.0
  end

  test "entry-level idempotency: an entry can be on exactly one invoice", %{project: project} do
    {:ok, entry} = Ledger.log_time(project, 45, billable: true)
    insert_refs(project.uuid, [entry], Ecto.UUID.generate())

    # insert_all surfaces the PK violation as the raw driver error.
    assert_raise Postgrex.Error, fn ->
      insert_refs(project.uuid, [entry], Ecto.UUID.generate())
    end
  end

  test "setup's tagged failure modes", %{project: project} do
    # Billing package absent in this suite → unavailable, always first.
    assert {:error, :billing_unavailable} = Invoicing.setup(project)
    assert {:error, :billing_unavailable} = Invoicing.generate_draft(project)

    # The billing package is absent here, so its provider is also
    # undiscovered — the extension can't even be enabled, which is the
    # correct composed behavior of the two guards.
    assert {:error, :unknown_extension} = Extensions.enable(project, "billing_customer")
  end
end
