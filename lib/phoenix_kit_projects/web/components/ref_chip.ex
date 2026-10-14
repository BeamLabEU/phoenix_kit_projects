defmodule PhoenixKitProjects.Web.Components.RefChip do
  @moduledoc """
  A project's key or a task's ref (`ANDI`, `ANDI-42` —
  `PhoenixKitProjects.Refs`) as a small monospace chip: the name to say
  aloud, type into a search box or the address bar, or paste into a commit
  message. Selecting it takes the whole ref (`select-all`); nothing renders
  for a row that has none yet.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  attr(:ref, :string, default: nil)
  attr(:size, :string, default: "sm", values: ~w(sm md))
  attr(:class, :any, default: nil)

  def ref_chip(%{ref: ref} = assigns) when ref in [nil, ""], do: ~H""

  def ref_chip(assigns) do
    ~H"""
    <span
      data-ref={@ref}
      title={gettext("%{ref} — works in search, in the address bar and on the API", ref: @ref)}
      class={[
        "font-mono select-all whitespace-nowrap shrink-0 text-base-content/60",
        @size == "sm" && "text-xs",
        @size == "md" && "badge badge-ghost badge-sm",
        @class
      ]}
    >{@ref}</span>
    """
  end
end
