defmodule PhoenixKitProjects.Web.Components.DerivedStatusBadge do
  @moduledoc """
  Badge that renders a project's `Project.derived_status/1` value as
  a daisyUI badge with the canonical icon + color + gettext'd label.

  Used in `ProjectsLive` (list view) but ready for reuse anywhere a
  project's lifecycle state needs a one-glance indicator.

  ## Example

      <.derived_status_badge state={Project.derived_status(project)} />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon

  alias PhoenixKitProjects.Schemas.Project

  attr(:state, :atom,
    required: true,
    values: [:running, :completed, :overdue, :scheduled, :setup, :archived, :template]
  )

  def derived_status_badge(assigns) do
    ~H"""
    <span class={"badge badge-sm gap-1 #{badge_class(@state)}"}>
      <.icon name={icon_name(@state)} class="w-3 h-3" /> {label(@state)}
    </span>
    """
  end

  @doc "Convenience wrapper for the common pattern of badge'ing a project struct."
  attr(:project, Project, required: true)

  def project_status_badge(assigns) do
    assigns = assign(assigns, :state, Project.derived_status(assigns.project))

    ~H"""
    <.derived_status_badge state={@state} />
    """
  end

  @doc """
  Badge for a project's user-defined **workflow status** (the
  entities-backed status, distinct from the computed `derived_status`).

  Takes the normalized status map (`%{label, color}`) from
  `PhoenixKitProjects.Statuses` or `nil`. `nil` renders nothing — which
  is what makes a project with no status set (or an unavailable entities
  module) render cleanly empty. Uses the status's free-form `color`
  (a hex string) as an inline style, falling back to `badge-neutral`
  when no colour is set.
  """
  attr(:status, :map, default: nil)
  attr(:class, :string, default: nil)

  def workflow_status_badge(assigns) do
    ~H"""
    <span
      :if={@status}
      class={["badge badge-sm gap-1", @class, is_nil(workflow_color(@status)) && "badge-neutral"]}
      style={workflow_style(@status)}
    >
      {@status.label}
    </span>
    """
  end

  # Only surface a colour we can prove is a bare hex value (`#rgb`..`#rrggbbaa`).
  # `data["color"]` is free-form JSONB (future colour picker / custom entities),
  # and `~H` does NOT escape attribute values — so anything that isn't plain hex
  # is dropped to nil (badge falls back to `badge-neutral`). This keeps an
  # attacker-controlled string from ever reaching the inline `style` attribute.
  @hex_color ~r/^#[0-9a-fA-F]{3,8}$/
  defp workflow_color(%{color: c}) when is_binary(c) do
    if Regex.match?(@hex_color, c), do: c, else: nil
  end

  defp workflow_color(_), do: nil

  defp workflow_style(status) do
    case workflow_color(status) do
      nil -> nil
      color -> "background-color: #{color}; border-color: #{color}; color: #{text_color(color)};"
    end
  end

  # Pick black or white text for legibility over the (user-chosen) badge
  # colour, by the colour's perceptual luminance. White on a pale status
  # colour (e.g. light yellow) is unreadable, so this flips to dark text
  # above a luminance threshold.
  defp text_color(hex) do
    case parse_rgb(hex) do
      {r, g, b} ->
        luminance = (r * 0.299 + g * 0.587 + b * 0.114) / 255
        if luminance > 0.6, do: "#1f2937", else: "#fff"

      :error ->
        "#fff"
    end
  end

  # Parses a bare hex colour (already validated as `#` + 3/4/6/8 hex digits)
  # into an `{r, g, b}` 0–255 tuple. 3/4-digit forms expand each nibble
  # (`#abc` → `#aabbcc`); 5/7-digit oddities fall through to `:error`.
  defp parse_rgb("#" <> rest) do
    case String.length(rest) do
      n when n in [3, 4] ->
        <<r::binary-1, g::binary-1, b::binary-1, _rest::binary>> = rest
        decode_hex([r <> r, g <> g, b <> b])

      n when n in [6, 8] ->
        <<r::binary-2, g::binary-2, b::binary-2, _rest::binary>> = rest
        decode_hex([r, g, b])

      _ ->
        :error
    end
  end

  defp parse_rgb(_), do: :error

  defp decode_hex(pairs) do
    case Enum.map(pairs, &Integer.parse(&1, 16)) do
      [{r, ""}, {g, ""}, {b, ""}] -> {r, g, b}
      _ -> :error
    end
  end

  defp label(:running), do: gettext("running")
  defp label(:completed), do: gettext("completed")
  defp label(:overdue), do: gettext("overdue")
  defp label(:scheduled), do: gettext("scheduled")
  defp label(:setup), do: gettext("setup")
  defp label(:archived), do: gettext("archived")
  defp label(:template), do: gettext("template")

  defp badge_class(:running), do: "badge-success"
  defp badge_class(:completed), do: "badge-success badge-outline"
  defp badge_class(:overdue), do: "badge-error"
  defp badge_class(:scheduled), do: "badge-info"
  defp badge_class(:setup), do: "badge-warning"
  defp badge_class(:archived), do: "badge-ghost"
  defp badge_class(:template), do: "badge-info badge-outline"

  defp icon_name(:running), do: "hero-play"
  defp icon_name(:completed), do: "hero-check-circle"
  defp icon_name(:overdue), do: "hero-exclamation-triangle"
  defp icon_name(:scheduled), do: "hero-calendar"
  defp icon_name(:setup), do: "hero-clock"
  defp icon_name(:archived), do: "hero-archive-box"
  defp icon_name(:template), do: "hero-document-duplicate"
end
