defmodule PhoenixKitProjects.Web.ApiKeyPanelTest do
  @moduledoc "The pure parts of the key pages: names, expiry, the setup prompt."

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.Schemas.ApiKey
  alias PhoenixKitProjects.Web.ApiKeyPanel

  test "a personal key's label names its person, and the prompt says so" do
    uuid = Ecto.UUID.generate()
    names = %{uuid => "Max Don"}

    assert ApiKeyPanel.kind_label(%ApiKey{user_uuid: uuid}, names) ==
             "Personal · acts for Max Don"

    assert ApiKeyPanel.kind_label(%ApiKey{}, names) == "Shared agent"

    prompt =
      ApiKeyPanel.setup_prompt("ANDI", %ApiKey{name: "x", key_id: "k", user_uuid: uuid}, nil)

    assert prompt =~ "API token: <paste"
    # the name is looked up; an unknown uuid reads as a dash rather than crashing
    assert prompt =~ "You act for —"

    shared = ApiKeyPanel.setup_prompt("ANDI", %ApiKey{name: "x", key_id: "k"}, "tok")
    assert shared =~ "shared agent, not a person's"
  end

  test "expiry choices become a date from now, never is nil" do
    now = ~U[2026-10-05 12:00:00Z]
    assert ApiKeyPanel.expires_at("never", now) == nil
    assert ApiKeyPanel.expires_at("30", now) == ~U[2026-11-04 12:00:00Z]
    assert ApiKeyPanel.expires_at("bogus", now) == nil
  end

  test "the setup prompt carries the links, the first call, and the token or its place" do
    key = %ApiKey{name: "ANDI agent", key_id: "80ejrvvuf5k7sdo", scopes: ApiKey.scopes()}

    with_token = ApiKeyPanel.setup_prompt("ANDI Manager", key, "pkp_80ejrvvuf5k7sdo_secret")
    assert with_token =~ "Home project: ANDI Manager"
    assert with_token =~ "/api/projects/v1/llms.txt"
    assert with_token =~ "/api/projects/v1/openapi.json"
    assert with_token =~ "API token: pkp_80ejrvvuf5k7sdo_secret"
    assert with_token =~ "GET /me"
    assert with_token =~ "project="
    assert with_token =~ "ANDI-42"

    without = ApiKeyPanel.setup_prompt("ANDI Manager", key, nil)
    refute without =~ "secret"
    assert without =~ "ID pkp_80ejrvvuf5k7sdo"
    assert without =~ "not stored"
    assert ApiKeyPanel.display_id(key) == "pkp_80ejrvvuf5k7sdo"
  end
end
