defmodule PhoenixKitProjects.Web.ApiExtTest do
  @moduledoc """
  `/ext/:resource`: an extension's record on the API through a provider
  (`Extensions.ApiProvider`) — here a fake one registered for the test,
  so the checks (scope, the extension on the project, the role floor) and
  the dispatch are proven without the CRM.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, Authz, Extensions}
  alias PhoenixKitProjects.Extensions.Registry
  alias PhoenixKitProjects.Schemas.ApiKey
  alias PhoenixKitProjects.Web.Api.Docs

  @base "/api/projects/v1"

  defmodule Widgets do
    @moduledoc false
    def resource, do: "widgets"
    def scopes, do: %{read: "widgets:read", write: "widgets:write"}
    def action, do: :paint_widget

    def list(%{project: p}, _params), do: {:ok, %{widgets: [], project: p.uuid}}
    def get(_ctx, "missing"), do: {:error, {404, "not_found", "No such widget.", nil}}
    def get(_ctx, id), do: {:ok, %{widget: %{uuid: id}}}

    def create(ctx, attrs),
      do: {:ok, %{widget: attrs, by: ctx.actor.kind, person: ctx.user_uuid}, 201}

    def update(_ctx, id, attrs), do: {:ok, %{widget: Map.put(attrs, "uuid", id)}}

    def docs,
      do: [
        %{
          id: "listWidgets",
          method: "GET",
          path: "/ext/widgets",
          summary: "Widgets.",
          auth: true,
          scope: "widgets:read",
          action: "view",
          feature: "widgets",
          idempotency: nil,
          params: [],
          example: nil
        }
      ]
  end

  defmodule Provider do
    @moduledoc false
    def phoenix_kit_project_extensions do
      [
        %{
          key: "widgets",
          name: "Widgets",
          description: "A test extension with an API resource",
          permission_actions: [:view, :paint_widget],
          api: PhoenixKitProjects.Web.ApiExtTest.Widgets
        }
      ]
    end
  end

  setup %{conn: conn} do
    previous = Application.get_env(:phoenix_kit_projects, :extension_providers, [])
    Application.put_env(:phoenix_kit_projects, :extension_providers, [Provider | previous])
    Registry.refresh()

    on_exit(fn ->
      Application.put_env(:phoenix_kit_projects, :extension_providers, previous)
      Registry.refresh()
    end)

    project = fixture_project()

    {:ok, user} =
      Auth.register_user(%{
        email: "ext-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, _key, token} =
      ApiKeys.create(project, %{"name" => "Painter", "role" => "member"}, actor_uuid: user.uuid)

    {:ok, conn: conn, project: project, token: token, user: user}
  end

  defp api(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  test "the provider's scopes are offered on keys and its rows are in the docs" do
    assert "widgets:read" in ApiKey.scopes()
    assert "widgets:write" in ApiKey.scopes()
    assert %{module: Widgets} = Extensions.api_provider("widgets")
    assert Enum.any?(Docs.endpoints(), &(&1.id == "listWidgets"))
  end

  test "an unknown resource is 404; the extension off is 403 feature_disabled", %{
    conn: conn,
    token: token
  } do
    assert %{"error" => %{"code" => "not_found"}} =
             conn |> api(token) |> get("#{@base}/ext/gizmos") |> json_response(404)

    assert %{"error" => %{"code" => "feature_disabled", "details" => %{"feature" => "widgets"}}} =
             conn |> api(token) |> get("#{@base}/ext/widgets") |> json_response(403)
  end

  test "with the extension on, the four calls reach the provider with the key's context",
       %{conn: conn, token: token, project: project, user: user} do
    {:ok, _} = Extensions.enable(project, "widgets")
    c = api(conn, token)

    assert %{"widgets" => [], "project" => pu} =
             c |> get("#{@base}/ext/widgets") |> json_response(200)

    assert pu == project.uuid

    assert %{"widget" => %{"uuid" => "w1"}} =
             c |> get("#{@base}/ext/widgets/w1") |> json_response(200)

    assert %{"error" => %{"code" => "not_found"}} =
             c |> get("#{@base}/ext/widgets/missing") |> json_response(404)

    # A write: the extension-declared action floors at member, the ctx names the agent and the person.
    assert Authz.can_role?(project, "member", :paint_widget)
    refute Authz.can_role?(project, "member", :not_declared_anywhere)

    assert %{"widget" => %{"colour" => "red"}, "by" => "ai_agent", "person" => person} =
             c
             |> post("#{@base}/ext/widgets", Jason.encode!(%{colour: "red"}))
             |> json_response(201)

    assert person == user.uuid

    assert %{"widget" => %{"uuid" => "w1", "colour" => "blue"}} =
             c
             |> patch("#{@base}/ext/widgets/w1", Jason.encode!(%{colour: "blue"}))
             |> json_response(200)

    # A key without the provider's scope is refused by name.
    {:ok, _, narrow} =
      ApiKeys.create(project, %{"name" => "Narrow", "scopes" => ["tasks:read"]},
        actor_uuid: user.uuid
      )

    assert %{"error" => %{"code" => "scope_missing", "details" => %{"scope" => "widgets:read"}}} =
             conn |> api(narrow) |> get("#{@base}/ext/widgets") |> json_response(403)
  end
end
