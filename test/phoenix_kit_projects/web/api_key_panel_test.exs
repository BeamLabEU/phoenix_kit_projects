defmodule PhoenixKitProjects.Web.ApiKeyPanelTest do
  @moduledoc "The pure parts of the API access section: presets, expiry, the setup prompt."

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.Schemas.ApiKey
  alias PhoenixKitProjects.Web.ApiKeyPanel

  test "presets map to scope sets and back" do
    assert ApiKeyPanel.scopes_for("full", []) == ApiKey.scopes()

    assert ApiKeyPanel.scopes_for("read", []) ==
             Enum.filter(ApiKey.scopes(), &String.ends_with?(&1, ":read"))

    assert ApiKeyPanel.scopes_for("metering", []) == ["time:write", "usage:write"]
    assert ApiKeyPanel.scopes_for("custom", ["tasks:read", "nope"]) == ["tasks:read"]

    assert ApiKeyPanel.preset_for(ApiKey.scopes()) == "full"
    assert ApiKeyPanel.preset_for(["usage:write", "time:write"]) == "metering"
    assert ApiKeyPanel.preset_for(["tasks:read", "time:write"]) == "custom"
    assert ApiKeyPanel.access_label(["tasks:read", "time:write"]) == "Custom · 2 scopes"
    assert ApiKeyPanel.access_label(["time:write"]) == "Custom · 1 scope"
  end

  test "expiry choices become a date from now, never is nil" do
    now = ~U[2026-10-05 12:00:00Z]
    assert ApiKeyPanel.expires_at("never", now) == nil
    assert ApiKeyPanel.expires_at("30", now) == ~U[2026-11-04 12:00:00Z]
    assert ApiKeyPanel.expires_at("bogus", now) == nil
  end

  test "the form carries typed fields, takes custom ticks only when shown, and tames a viewer" do
    form = ApiKeyPanel.new_form()
    assert form["preset"] == "full"
    assert ApiKeyPanel.ticked_scopes(form) == ApiKey.scopes()

    # the custom row off screen: nothing posts for scope, ticks stay
    form = ApiKeyPanel.form_from(%{"name" => "Runner", "preset" => "read"}, form)
    assert form["name"] == "Runner"
    assert form["preset"] == "read"
    assert ApiKeyPanel.ticked_scopes(form) == ApiKey.scopes()

    # custom on screen: the absent boxes are off
    form =
      ApiKeyPanel.form_from(%{"preset" => "custom", "scope" => %{"tasks:read" => "true"}}, form)

    assert ApiKeyPanel.ticked_scopes(form) == ["tasks:read"]

    # a viewer cannot write: Full access turns into Read-only once
    form =
      ApiKeyPanel.form_from(%{"role" => "viewer", "preset" => "full"}, ApiKeyPanel.new_form())

    assert form["preset"] == "read"
    form = ApiKeyPanel.form_from(%{"role" => "viewer", "preset" => "full"}, form)
    assert form["preset"] == "full"
  end

  test "the setup prompt carries the links, the first call, and the token or its place" do
    key = %ApiKey{name: "ANDI agent", key_id: "80ejrvvuf5k7sdo", scopes: ApiKey.scopes()}

    with_token = ApiKeyPanel.setup_prompt("ANDI Manager", key, "pkp_80ejrvvuf5k7sdo_secret")
    assert with_token =~ "Project: ANDI Manager"
    assert with_token =~ "/api/projects/v1/llms.txt"
    assert with_token =~ "/api/projects/v1/openapi.json"
    assert with_token =~ "API token: pkp_80ejrvvuf5k7sdo_secret"
    assert with_token =~ "GET /me"

    without = ApiKeyPanel.setup_prompt("ANDI Manager", key, nil)
    refute without =~ "secret"
    assert without =~ "ID pkp_80ejrvvuf5k7sdo"
    assert without =~ "not stored"
    assert ApiKeyPanel.display_id(key) == "pkp_80ejrvvuf5k7sdo"
  end
end
