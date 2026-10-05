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
end
