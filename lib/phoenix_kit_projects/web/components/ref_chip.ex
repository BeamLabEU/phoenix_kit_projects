defmodule PhoenixKitProjects.Web.Components.RefChip do
  @moduledoc """
  A project's key or a task's ref (`ACME`, `ACME-42` —
  `PhoenixKitProjects.Refs`) as a small monospace pill — the same pill
  wherever a ref shows, rows and popups included (the boss, 2026-10-31): the name to say
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
        "badge badge-ghost font-mono select-all whitespace-nowrap shrink-0 text-base-content/70",
        @size == "sm" && "badge-sm",
        @class
      ]}
    >{@ref}</span>
    """
  end
end
