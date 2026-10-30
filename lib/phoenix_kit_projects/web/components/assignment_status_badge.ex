defmodule PhoenixKitProjects.Web.Components.AssignmentStatusBadge do
  @moduledoc """
  Status presentation for an `Assignment.status` value (`"waiting"`,
  `"todo"` — shown as "can be started" — `"in_progress"`, `"done"`). Mirrors `DerivedStatusBadge` but for the
  assignment lifecycle instead of the project lifecycle.

  ## Helpers

  All three helpers accept an arbitrary string and fall back to the
  `"waiting"` styling on unknown values so a half-broken DB row still
  renders sensibly.

    * `color/1` — Tailwind `bg-*` class for filled circles/dots.
    * `badge_class/1` — daisyUI `badge-*` variant class.
    * `label/1` — gettext'd human label (falls back to the raw value).

  ## Component

      <.assignment_status_badge status={assignment.status} />
      <.assignment_status_badge status={assignment.status} size="sm" />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  @doc "Tailwind background-color class for an assignment status."
  @spec color(String.t() | nil) :: String.t()
  def color("waiting"), do: "bg-base-300"
  def color("todo"), do: "bg-info"
  def color("in_progress"), do: "bg-warning"
  def color("done"), do: "bg-success"
  def color(_), do: "bg-base-300"

  @doc """
  Foreground (text) class that pairs with `color/1` on a filled dot. The `todo`
  dot is light (`bg-base-300`), so its number needs dark text — plain `text-white`
  was invisible. Colored states use their daisyUI `*-content` foreground.
  """
  @spec text_color(String.t() | nil) :: String.t()
  def text_color("todo"), do: "text-info-content"
  def text_color("in_progress"), do: "text-warning-content"
  def text_color("done"), do: "text-success-content"
  def text_color(_), do: "text-base-content"

  @doc """
  Outline for a filled dot. The light `todo` dot (`bg-base-300`) is nearly
  invisible on a white page, so it needs a border to define the circle; the
  solid colored states stand on their own.
  """
  @spec ring(String.t() | nil) :: String.t()
  def ring("todo"), do: ""
  def ring("in_progress"), do: ""
  def ring("done"), do: ""
  def ring(_), do: "border border-base-content/25"

  @doc "daisyUI badge variant class for an assignment status."
  @spec badge_class(String.t() | nil) :: String.t()
  def badge_class("waiting"), do: "badge-ghost"
  def badge_class("todo"), do: "badge-info"
  def badge_class("in_progress"), do: "badge-warning"
  def badge_class("done"), do: "badge-success"
  def badge_class(_), do: "badge-ghost"

  @doc "Localized human label for an assignment status."
  @spec label(String.t() | nil) :: String.t()
  def label("waiting"), do: gettext("waiting")
  def label("todo"), do: gettext("can be started")
  def label("in_progress"), do: gettext("in progress")
  def label("done"), do: gettext("done")
  def label(other) when is_binary(other), do: other
  def label(_), do: gettext("waiting")

  attr(:status, :string, required: true)
  attr(:size, :string, default: "sm", values: ~w(xs sm md lg))
  attr(:class, :string, default: nil)

  def assignment_status_badge(assigns) do
    ~H"""
    <span class={["badge", size_class(@size), badge_class(@status), @class]}>
      {label(@status)}
    </span>
    """
  end

  # Literal per size — an interpolated "badge-#{size}" is invisible to the
  # Tailwind scanner, so the class only exists if some other file happens to
  # spell it out.
  defp size_class("xs"), do: "badge-xs"
  defp size_class("md"), do: "badge-md"
  defp size_class("lg"), do: "badge-lg"
  defp size_class(_), do: "badge-sm"
end
