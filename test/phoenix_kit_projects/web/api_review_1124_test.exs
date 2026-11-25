defmodule PhoenixKitProjects.Web.ApiReview1124Test do
  @moduledoc """
  The API findings of the 2026-11-24 review: `GET /events` bounds, taking a
  project away from a key, NUL bytes in a request, `GET /me` naming the
  person without an email, and the ledger docs.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiAccess, ApiKeys, Members, ProjectEvents, Projects}
  alias PhoenixKitProjects.Web.Api.Docs

  @base "/api/projects/v1"

  defp api(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  defp grid(preset) do
    {_k, _l, grid} = Enum.find(ApiAccess.presets(), fn {k, _l, _g} -> k == preset end)
    ApiAccess.scopes(grid)
  end

  defp fixture_user_uuid do
    {:ok, user} =
      Auth.register_user(%{
        email: "minter-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    PhoenixKitProjects.Test.Access.grant_projects!(user).uuid
  end

  setup do
    project = fixture_project(%{"name" => "Review #{System.unique_integer([:positive])}"})

    {:ok, key, token} =
      ApiKeys.create(project, %{"name" => "Agent", "role" => "manager"},
        actor_uuid: fixture_user_uuid()
      )

    {:ok, project: project, key: key, token: token}
  end

  describe "GET /events" do
    setup %{project: project} do
      {:ok, _} = PhoenixKitProjects.Extensions.enable(project, "events")

      for {title, at} <- [
            {"October", ~U[2026-10-31 23:00:00Z]},
            {"November", ~U[2026-11-15 10:00:00Z]},
            {"Edge", ~U[2026-12-01 00:00:00Z]}
          ] do
        {:ok, _} = ProjectEvents.create(project, %{title: title, starts_at: at, all_day: false})
      end

      :ok
    end

    defp titles(body), do: Enum.map(body["events"], & &1["title"])

    test "a day bound is honoured (it was dropped, answering the oldest events)", %{
      conn: conn,
      token: token
    } do
      body =
        conn
        |> api(token)
        |> get("#{@base}/events?from=2026-11-01&until=2026-12-01")
        |> json_response(200)

      # `until` is "starting before": an event at its very instant is out.
      assert titles(body) == ["November"]
      assert body["truncated"] == false
    end

    test "a datetime without an offset is read as UTC", %{conn: conn, token: token} do
      body =
        conn
        |> api(token)
        |> get("#{@base}/events?from=2026-11-01T00:00:00")
        |> json_response(200)

      assert titles(body) == ["November", "Edge"]
    end

    test "an unreadable bound is a 422, never ignored", %{conn: conn, token: token} do
      assert %{"error" => %{"code" => "validation_failed", "details" => %{"from" => [_]}}} =
               conn |> api(token) |> get("#{@base}/events?from=next+week") |> json_response(422)
    end
  end

  describe "taking a project away from a key" do
    test "leaves no access, even where a parent's grant covers sub-projects", %{
      project: project,
      key: key
    } do
      {:ok, %{child_project: child}} =
        Projects.create_subproject(project.uuid, %{"name" => "Child"})

      # The child narrowed to read-only, the parent at full with inherit.
      {:ok, _} = ApiKeys.put_grant(key, child.uuid, %{"scopes" => grid("read")})
      assert {:ok, %{scopes: scopes}} = ApiKeys.access_for(key, child.uuid)
      refute "tasks:write" in scopes

      # A bare delete handed the parent's full access back.
      assert {:ok, :blocked} = ApiKeys.take_away(key, child.uuid)
      assert {:error, :no_access} = ApiKeys.access_for(key, child.uuid)
      assert {:ok, _} = ApiKeys.access_for(key, project.uuid)
    end

    test "a project nothing above reaches is simply deleted", %{key: key} do
      other = fixture_project(%{"name" => "Other #{System.unique_integer([:positive])}"})
      {:ok, _} = ApiKeys.put_grant(key, other.uuid, %{"scopes" => grid("read")})

      assert {:ok, :deleted} = ApiKeys.take_away(key, other.uuid)
      refute Enum.any?(ApiKeys.grants(key), &(&1.project_uuid == other.uuid))
      assert {:error, :no_access} = ApiKeys.access_for(key, other.uuid)
    end
  end

  describe "NUL bytes" do
    test "a NUL in any field is a 422 naming it, never a 500", %{conn: conn, token: token} do
      assert %{"error" => %{"code" => "validation_failed", "details" => %{"title" => [_]}}} =
               conn
               |> api(token)
               |> post("#{@base}/tasks", Jason.encode!(%{"title" => "Pay\u0000roll"}))
               |> json_response(422)

      assert %{"error" => %{"details" => %{"labels.1" => [_]}}} =
               conn
               |> api(token)
               |> post(
                 "#{@base}/tasks",
                 Jason.encode!(%{"title" => "Fine", "labels" => ["ok", "b\u0000d"]})
               )
               |> json_response(422)
    end
  end

  describe "GET /me" do
    test "names the person a key acts for without ever giving their email", %{
      conn: conn,
      project: project
    } do
      {:ok, nameless} =
        Auth.register_user(%{
          email: "nameless-#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      nameless = PhoenixKitProjects.Test.Access.grant_projects!(nameless)
      {:ok, _} = Members.add_member(project, nameless.uuid, role: "owner")

      {:ok, _key, token} =
        ApiKeys.create(project, %{"name" => "Their AI", "user_uuid" => nameless.uuid},
          actor_uuid: nameless.uuid
        )

      me = conn |> api(token) |> get("#{@base}/me") |> json_response(200)
      name = me["acting_for"]["name"]
      refute is_binary(name) and String.contains?(name, "@")
      refute Jason.encode!(me) =~ nameless.email
    end
  end

  test "the ledger docs no longer say a time entry cannot be corrected" do
    log = Enum.find(Docs.endpoints(), &(&1.id == "logTaskTime"))
    refute log.summary =~ "cannot be edited"
    assert log.summary =~ "PATCH /entries/{id}"
  end
end
