defmodule PhoenixKitProjects.ActivityLogRescueTest do
  @moduledoc """
  `Activity.log/2` never crashes the caller: it delegates to core's
  `PhoenixKit.Activity.log/3`, which returns a database error as
  `{:error, _}` instead of raising it into the LiveView event handler.
  (Core's own suite covers an exit and a throw.)

  Runs `async: false` because it DROPs `phoenix_kit_activities`
  inside the sandbox transaction — would deadlock against parallel
  tests touching the same table.
  """

  use PhoenixKitProjects.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias PhoenixKitProjects.Test.Repo, as: TestRepo

  describe "Activity.log/2 never crashes the caller" do
    test "a Postgrex.Error from a missing phoenix_kit_activities is returned, not raised" do
      # DROP inside the sandbox transaction. The sandbox rolls back at
      # test exit so the schema is restored automatically.
      SQL.query!(TestRepo, "DROP TABLE IF EXISTS phoenix_kit_activities CASCADE")

      log =
        capture_log(fn ->
          assert {:error, %Postgrex.Error{}} =
                   PhoenixKitProjects.Activity.log("projects.test", [])
        end)

      assert log =~ "Activity logging error"
    end
  end
end
