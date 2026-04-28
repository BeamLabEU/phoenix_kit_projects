defmodule PhoenixKitProjects.ActivityLogFailedTest do
  @moduledoc """
  Pins the `Activity.log_failed/2` shape and the `db_pending: true`
  metadata invariant. Per the post-Apr 2026 pipeline standard
  (publishing-Batch-3 / catalogue-Batch-4 precedent): a Drive/DB
  outage must NOT erase admin clicks from the activity feed; the
  failure path writes an audit row tagged `db_pending: true` so
  consumers can distinguish attempted-but-failed actions from
  completed ones.
  """

  use PhoenixKitProjects.DataCase, async: true

  alias PhoenixKit.Users.Auth

  describe "Activity.log_failed/2" do
    test "writes an activity row tagged metadata.db_pending = true" do
      actor_uuid = real_user_uuid!()
      resource_uuid = Ecto.UUID.generate()

      _ =
        PhoenixKitProjects.Activity.log_failed("projects.test_action",
          actor_uuid: actor_uuid,
          resource_type: "project",
          resource_uuid: resource_uuid,
          metadata: %{"name" => "X"}
        )

      assert_activity_logged("projects.test_action",
        actor_uuid: actor_uuid,
        resource_uuid: resource_uuid,
        metadata_has: %{"db_pending" => true, "name" => "X"}
      )
    end

    test "preserves caller-supplied metadata fields alongside db_pending" do
      actor_uuid = real_user_uuid!()
      resource_uuid = Ecto.UUID.generate()

      _ =
        PhoenixKitProjects.Activity.log_failed("projects.other_action",
          actor_uuid: actor_uuid,
          resource_type: "project",
          resource_uuid: resource_uuid,
          metadata: %{"name" => "Edge", "title" => "T"}
        )

      assert_activity_logged("projects.other_action",
        actor_uuid: actor_uuid,
        resource_uuid: resource_uuid,
        metadata_has: %{"db_pending" => true, "name" => "Edge", "title" => "T"}
      )
    end
  end

  defp real_user_uuid! do
    {:ok, user} =
      Auth.register_user(%{
        email: "log-failed-#{System.unique_integer([:positive])}@example.com",
        password: "supersecure-12345"
      })

    user.uuid
  end
end
