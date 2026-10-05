defmodule PhoenixKitProjects.LedgerListTest do
  @moduledoc """
  `Ledger.list_entries/2` with a `:metadata` match — how an extension finds
  the time it logged against one of its own records (the CRM's meetings).
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.Ledger

  test "metadata: keeps only the entries whose metadata contains the pairs" do
    project = fixture_project()
    meeting = Ecto.UUID.generate()
    other = Ecto.UUID.generate()

    {:ok, mine} =
      Ledger.log_time(project.uuid, 30,
        metadata: %{"interaction_uuid" => meeting, "via" => "crm"}
      )

    {:ok, _theirs} = Ledger.log_time(project.uuid, 45, metadata: %{"interaction_uuid" => other})
    {:ok, _bare} = Ledger.log_time(project.uuid, 10)

    assert [found] = Ledger.list_entries(project.uuid, metadata: %{"interaction_uuid" => meeting})
    assert found.uuid == mine.uuid

    # an empty match is no filter
    assert length(Ledger.list_entries(project.uuid, metadata: %{})) == 3
    assert Ledger.list_entries(project.uuid, metadata: %{"interaction_uuid" => "nope"}) == []
  end

  test "update_time amends the minutes, keeps ended_at in step, and leaves a trace" do
    project = fixture_project()
    started = ~U[2026-10-05 09:50:00Z]

    {:ok, entry} =
      Ledger.log_time(project.uuid, 30,
        started_at: started,
        ended_at: DateTime.add(started, 1800)
      )

    {:ok, amended} = Ledger.update_time(entry, 45, billable: true)
    assert Decimal.equal?(amended.amount, Decimal.new(45))
    assert amended.ended_at == DateTime.add(started, 45 * 60)
    assert amended.billable

    assert {:error, :not_found} = Ledger.update_time(Ecto.UUID.generate(), 10)
    assert {:error, _} = Ledger.update_time(entry, 0)

    [trace | _] =
      PhoenixKit.Activity.list(
        resource_type: "project",
        resource_uuid: project.uuid,
        per_page: 1
      )
      |> entries()

    assert trace.action == "projects.work_amended"
    assert trace.metadata["amount_was"] == "30"
    assert trace.metadata["amount"] == "45"
  end

  test "delete_entry removes the entry and leaves a trace" do
    project = fixture_project()
    {:ok, entry} = Ledger.log_time(project.uuid, 30)

    assert {:ok, _} = Ledger.delete_entry(entry.uuid)
    assert Ledger.get_entry(entry.uuid) == nil
    assert {:error, :not_found} = Ledger.delete_entry(entry.uuid)

    [trace | _] =
      PhoenixKit.Activity.list(
        resource_type: "project",
        resource_uuid: project.uuid,
        per_page: 1
      )
      |> entries()

    assert trace.action == "projects.work_removed"
    assert trace.metadata["amount"] == "30"
  end

  # `Activity.list/1` answers a page struct in some core versions and a list in others.
  defp entries(%{entries: entries}), do: entries
  defp entries(list) when is_list(list), do: list
end
