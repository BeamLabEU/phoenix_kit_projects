defmodule PhoenixKitProjects.Integration.ProjectEventsTest do
  @moduledoc """
  Step 12 project events: V6 CRUD, project scoping, range validation,
  and the activity trail.
  """

  use PhoenixKitProjects.DataCase, async: false

  import PhoenixKitProjects.ActivityLogAssertions

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.ProjectEvents

  setup do
    {:ok, project: fixture_project()}
  end

  defp dt(iso), do: elem(DateTime.from_iso8601(iso), 1)

  test "create / list / get / update / delete with activity", %{project: project} do
    actor = Ecto.UUID.generate()

    assert {:ok, event} =
             ProjectEvents.create(
               project,
               %{title: "Sprint review", starts_at: dt("2026-08-10T00:00:00Z")},
               actor_uuid: actor
             )

    assert event.all_day
    assert event.created_by_uuid == actor

    assert_activity_logged("projects.event_created",
      resource_uuid: project.uuid,
      metadata_has: %{"title" => "Sprint review"}
    )

    assert [%{uuid: listed}] = ProjectEvents.list_for_project(project.uuid)
    assert listed == event.uuid
    assert ProjectEvents.get(project.uuid, event.uuid)
    # Cross-project scoping: a different project can't see it.
    assert ProjectEvents.get(fixture_project().uuid, event.uuid) == nil

    assert {:ok, renamed} = ProjectEvents.update(event, %{title: "Sprint demo"})
    assert renamed.title == "Sprint demo"
    assert_activity_logged("projects.event_updated", resource_uuid: project.uuid)

    assert :ok = ProjectEvents.delete(renamed)
    assert ProjectEvents.list_for_project(project.uuid) == []
    assert_activity_logged("projects.event_deleted", resource_uuid: project.uuid)
  end

  test "creating an event notifies every member except the actor (Phase H)",
       %{project: project} do
    PhoenixKit.Settings.update_boolean_setting("notifications_enabled", true)

    actor = register_user()
    member = register_user()
    {:ok, _} = PhoenixKitProjects.Members.add_member(project, actor.uuid, role: "owner")
    {:ok, _} = PhoenixKitProjects.Members.add_member(project, member.uuid, role: "member")

    {:ok, _event} =
      ProjectEvents.create(
        project,
        %{title: "All hands", starts_at: dt("2026-08-20T00:00:00Z")},
        actor_uuid: actor.uuid
      )

    import Ecto.Query
    repo = PhoenixKit.RepoHelper.repo()

    # Scope to the EVENT action — add_member's own "you were added"
    # notifications are also in the table.
    notified =
      repo.all(
        from(n in PhoenixKit.Notifications.Notification,
          join: a in assoc(n, :activity),
          where: a.action == "projects.event_created",
          select: n.recipient_uuid
        )
      )

    # The member is notified through the fan-out; the actor self-skips.
    assert member.uuid in notified
    refute actor.uuid in notified
  end

  defp register_user do
    {:ok, user} =
      Auth.register_user(%{
        email: "ev-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  test "range and title validation", %{project: project} do
    assert {:error, changeset} =
             ProjectEvents.create(project, %{
               title: "Backwards",
               starts_at: dt("2026-08-10T10:00:00Z"),
               ends_at: dt("2026-08-10T09:00:00Z")
             })

    assert %{ends_at: _} = errors_on(changeset)

    assert {:error, changeset} =
             ProjectEvents.create(project, %{title: "   ", starts_at: dt("2026-08-10T00:00:00Z")})

    assert %{title: _} = errors_on(changeset)
  end

  # Panel round (Gemini): update_change(:title, &String.trim/1) raised a
  # FunctionClauseError when a caller nil'd the title — cast records the
  # nil change, then trim(nil) crashes instead of the required-validation
  # answering.
  test "nil'ing the title errors instead of crashing", %{project: project} do
    {:ok, event} =
      ProjectEvents.create(project, %{title: "Solid", starts_at: dt("2026-08-10T00:00:00Z")})

    assert {:error, changeset} = ProjectEvents.update(event, %{title: nil})
    assert %{title: _} = errors_on(changeset)
  end

  test "list bounds and ordering", %{project: project} do
    {:ok, _a} =
      ProjectEvents.create(project, %{title: "A", starts_at: dt("2026-08-01T00:00:00Z")})

    {:ok, b} = ProjectEvents.create(project, %{title: "B", starts_at: dt("2026-08-15T00:00:00Z")})
    {:ok, c} = ProjectEvents.create(project, %{title: "C", starts_at: dt("2026-09-01T00:00:00Z")})

    assert ["A", "B", "C"] =
             project.uuid |> ProjectEvents.list_for_project() |> Enum.map(& &1.title)

    bounded =
      ProjectEvents.list_for_project(project.uuid,
        from: dt("2026-08-10T00:00:00Z"),
        until: dt("2026-08-31T00:00:00Z")
      )

    assert Enum.map(bounded, & &1.uuid) == [b.uuid]

    assert [%{uuid: first}] = ProjectEvents.list_for_project(project.uuid, limit: 1)
    refute first == c.uuid
  end
end
