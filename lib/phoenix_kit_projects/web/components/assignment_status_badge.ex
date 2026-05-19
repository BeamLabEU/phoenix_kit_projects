defmodule PhoenixKitProjects.Web.Components.AssignmentStatusBadge do
  @moduledoc """
  Status presentation for an `Assignment.status` value (`"todo"`,
  `"in_progress"`, `"done"`). Mirrors `DerivedStatusBadge` but for the
  assignment lifecycle instead of the project lifecycle.

  ## Helpers

  All three helpers accept an arbitrary string and fall back to the
  `"todo"` styling on unknown values so a half-broken DB row still
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
  def color("todo"), do: "bg-base-300"
  def color("in_progress"), do: "bg-warning"
  def color("done"), do: "bg-success"
  def color(_), do: "bg-base-300"

  @doc "daisyUI badge variant class for an assignment status."
  @spec badge_class(String.t() | nil) :: String.t()
  def badge_class("todo"), do: "badge-ghost"
  def badge_class("in_progress"), do: "badge-warning"
  def badge_class("done"), do: "badge-success"
  def badge_class(_), do: "badge-ghost"

  @doc "Localized human label for an assignment status."
  @spec label(String.t() | nil) :: String.t()
  def label("todo"), do: gettext("todo")
  def label("in_progress"), do: gettext("in progress")
  def label("done"), do: gettext("done")
  def label(other) when is_binary(other), do: other
  def label(_), do: gettext("todo")

  attr(:status, :string, required: true)
  attr(:size, :string, default: "sm", values: ~w(xs sm md lg))
  attr(:class, :string, default: nil)

  def assignment_status_badge(assigns) do
    ~H"""
    <span class={["badge", "badge-#{@size}", badge_class(@status), @class]}>
      {label(@status)}
    </span>
    """
  end
end
