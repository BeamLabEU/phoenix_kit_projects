defmodule PhoenixKitProjects.Web.Components.WorkflowStatusBadgeTest do
  @moduledoc """
  Rendering contract for `<.workflow_status_badge>` — the entities-backed
  workflow-status badge (distinct from the computed `derived_status` badge).

  No DB needed: the component takes a normalized status map (or nil) and
  renders pure markup. The nil-safety pinned here is what underpins the
  whole graceful-hide contract — a project with no status set, or an
  unavailable entities module, renders nothing.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import PhoenixKitProjects.Web.Components.DerivedStatusBadge

  defp badge(status), do: render_component(&workflow_status_badge/1, status: status)

  test "renders nothing for nil status" do
    html = badge(nil)
    refute html =~ "badge"
    assert String.trim(html) == ""
  end

  test "renders the label and inline colour for a status with a colour" do
    html =
      badge(%{uuid: "u", label: "In Review", slug: "in-review", color: "#a78bfa", position: 5})

    assert html =~ "In Review"
    assert html =~ "background-color: #a78bfa"
    assert html =~ "badge"
  end

  test "falls back to badge-neutral when no colour is set" do
    html = badge(%{uuid: "u", label: "Backlog", slug: "backlog", color: nil, position: 1})

    assert html =~ "Backlog"
    assert html =~ "badge-neutral"
    refute html =~ "background-color:"
  end

  test "treats an empty-string colour as no colour" do
    html = badge(%{uuid: "u", label: "Done", slug: "done", color: "", position: 6})

    assert html =~ "Done"
    assert html =~ "badge-neutral"
    refute html =~ "background-color:"
  end

  test "accepts shorthand and 8-digit hex colours" do
    assert badge(%{label: "A", color: "#abc"}) =~ "background-color: #abc"
    assert badge(%{label: "B", color: "#abcdef80"}) =~ "background-color: #abcdef80"
  end

  test "drops a non-hex colour string (CSS-injection guard)" do
    # An attacker-controlled `data["color"]` must never reach the style attr.
    payload = "red; background: url(javascript:alert(1)); --x: }"
    html = badge(%{uuid: "u", label: "Evil", slug: "evil", color: payload, position: 1})

    assert html =~ "Evil"
    assert html =~ "badge-neutral"
    refute html =~ "background-color:"
    refute html =~ "url("
    refute html =~ "javascript"
  end

  test "drops a CSS-keyword colour that is not bare hex" do
    # Even benign-looking non-hex values are rejected (hex-only allowlist).
    html = badge(%{label: "Named", color: "rebeccapurple"})

    assert html =~ "badge-neutral"
    refute html =~ "background-color:"
  end
end
