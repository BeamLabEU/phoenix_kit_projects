defmodule PhoenixKitProjects.Web.HelpersEmbedTest do
  @moduledoc """
  Unit tests for the pure-function embed-mode helpers in
  `PhoenixKitProjects.Web.Helpers`. Socket-dependent helpers
  (`assign_embed_state/2`, `navigate_or_open/2`, etc.) are covered by
  the per-LV emit-mode tests in `embedding_emit_test.exs` — they need a
  full LV mount path and would duplicate that surface here.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Web.Helpers

  describe "embeddable_lv?/1" do
    test "accepts every LV in the whitelist" do
      for lv <- Helpers.embeddable_lvs() do
        assert Helpers.embeddable_lv?(lv), "#{inspect(lv)} should be embeddable"
      end
    end

    test "rejects unlisted modules" do
      refute Helpers.embeddable_lv?(PhoenixKitProjects.Projects)
      refute Helpers.embeddable_lv?(String)
      refute Helpers.embeddable_lv?(:does_not_exist)
    end

    test "rejects non-atoms" do
      refute Helpers.embeddable_lv?("PhoenixKitProjects.Web.OverviewLive")
      refute Helpers.embeddable_lv?(nil)
      refute Helpers.embeddable_lv?(123)
    end
  end

  describe "decode_embeddable_lv/1" do
    test "decodes a stringified whitelist module" do
      assert {:ok, PhoenixKitProjects.Web.OverviewLive} =
               Helpers.decode_embeddable_lv("Elixir.PhoenixKitProjects.Web.OverviewLive")
    end

    test "decodes the unprefixed (human-friendly) form too (Codex R6-F1)" do
      # PopupHostLive's `root_view` example shows
      # "PhoenixKitProjects.Web.OverviewLive" (no Elixir. prefix). The
      # decoder must accept it — otherwise the documented zero-config
      # popup host silently renders no inline content.
      assert {:ok, PhoenixKitProjects.Web.OverviewLive} =
               Helpers.decode_embeddable_lv("PhoenixKitProjects.Web.OverviewLive")
    end

    test "rejects a stringified non-whitelist module" do
      assert :error = Helpers.decode_embeddable_lv("Elixir.PhoenixKitProjects.Projects")
    end

    test "rejects an unknown atom name (would otherwise mint atoms)" do
      assert :error =
               Helpers.decode_embeddable_lv("Elixir.PhoenixKitProjects.Web.TotallyMadeUpLive")
    end

    test "rejects non-binaries" do
      assert :error = Helpers.decode_embeddable_lv(nil)
      assert :error = Helpers.decode_embeddable_lv(:atom)
      assert :error = Helpers.decode_embeddable_lv(123)
    end
  end

  describe "C11 pinning: smart_menu_link renders the right shape per mode" do
    # smart_menu_link is the embed-mode aware adapter used inside
    # <.table_row_menu>. The per-LV kebab tests exercise it indirectly;
    # these tests pin the shape directly so a revert of the navigate↔emit
    # branching would fail loudly here.

    import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
    import Phoenix.Component, only: [sigil_H: 2]
    import PhoenixKitProjects.Web.Components.SmartMenuLink

    test "navigate mode renders <li><a href> (real anchor for new-tab UX)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.smart_menu_link
          navigate="/admin/projects/list/abc"
          emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => "abc"}}}
          embed_mode={:navigate}
          icon="hero-pencil"
          label="Edit"
        />
        """)

      assert html =~ ~s(<a)
      assert html =~ ~s(href="/admin/projects/list/abc")
      assert html =~ ~s(>Edit</span>)
      refute html =~ ~s(phx-click="open_embed")
    end

    test "emit mode renders <li><button phx-click=open_embed>" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.smart_menu_link
          navigate="/admin/projects/list/abc"
          emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => "abc"}}}
          embed_mode={:emit}
          icon="hero-pencil"
          label="Edit"
        />
        """)

      assert html =~ ~s(<button)
      assert html =~ ~s(phx-click="open_embed")
      assert html =~ ~s(phx-value-lv="Elixir.PhoenixKitProjects.Web.ProjectShowLive")
      assert html =~ ~s(phx-value-session=)
      assert html =~ ~s(>Edit</span>)
      refute html =~ ~s(href="/admin/projects/list/abc")
    end
  end

  describe "decode_session/1" do
    test "decodes a valid JSON object" do
      assert {:ok, %{"id" => "abc", "live_action" => "edit"}} =
               Helpers.decode_session(~s({"id":"abc","live_action":"edit"}))
    end

    test "returns empty map for nil and empty string" do
      assert {:ok, %{}} = Helpers.decode_session(nil)
      assert {:ok, %{}} = Helpers.decode_session("")
    end

    test "passes pre-decoded maps through unchanged" do
      assert {:ok, %{"id" => "abc"}} = Helpers.decode_session(%{"id" => "abc"})
    end

    test "errors on malformed JSON" do
      assert :error = Helpers.decode_session("{not json")
    end

    test "errors on JSON-encoded non-objects" do
      assert :error = Helpers.decode_session(~s(["array"]))
      assert :error = Helpers.decode_session(~s("just a string"))
    end
  end
end
