defmodule PhoenixKitProjects.Archetypes do
  @moduledoc """
  Creation **starting points** — the outcome-oriented cards on the New
  project page (the 2026-08-06 five-AI brainstorm's strongest consensus:
  one transparent choice that BUNDLES a feature preset + extension seeds,
  replacing the bare preset select as the page's primary control).

  An archetype is a RECIPE applied once at creation, not a stored mode:

    * `preset` — the `Features` preset key it seeds (the flag bundle).
    * `extensions` — extension keys enabled on create, LISTED ONLY when
      their registry entry is available (an uninstalled CRM never shows
      on the card face).
    * The user's explicit customizations always win over the recipe
      (the union rule: recipes seed, users override, nothing is
      silently dropped).

  The card list is fixed and small by design; per-site tuning happens
  through the site default preset (which picks the preselected card)
  and the post-create Modules & Features panel.
  """

  alias PhoenixKitProjects.Extensions
  alias PhoenixKitProjects.Extensions.Registry

  @type t :: %{
          key: String.t(),
          name: String.t(),
          description: String.t(),
          icon: String.t(),
          preset: String.t(),
          extensions: [String.t()]
        }

  @archetypes [
    %{
      key: "quick_todo",
      name: "Quick to-do",
      description: "Just a shared checklist — no assignees, dates, or tracking.",
      icon: "hero-check-circle",
      preset: "simple",
      extensions: []
    },
    %{
      key: "standard",
      name: "Standard project",
      description: "Tasks with assignees, scheduling, board and timeline views.",
      icon: "hero-clipboard-document-list",
      preset: "standard",
      extensions: []
    },
    %{
      key: "client_hub",
      name: "Client delivery",
      description: "A client-facing project: CRM link, billable time, invoicing.",
      icon: "hero-briefcase",
      preset: "full",
      extensions: ~w(crm_client billing_customer)
    },
    %{
      key: "public_intake",
      name: "Public intake",
      description: "Collect issues from the outside world behind a private link.",
      icon: "hero-globe-alt",
      preset: "standard",
      extensions: ~w(portal)
    },
    %{
      key: "full",
      name: "Full tracker",
      description: "Everything on: estimates, dependencies, ledger, all views.",
      icon: "hero-squares-plus",
      preset: "full",
      extensions: []
    }
  ]

  @doc """
  The card list with each archetype's `extensions` filtered to the
  AVAILABLE catalog (uninstalled/disabled providers drop off the face —
  a Client delivery card without CRM installed seeds only what exists).
  """
  @spec list() :: [t()]
  def list do
    available =
      Extensions.list_types()
      |> Enum.filter(&Registry.available?/1)
      |> MapSet.new(& &1.key)

    Enum.map(@archetypes, fn a ->
      %{a | extensions: Enum.filter(a.extensions, &MapSet.member?(available, &1))}
    end)
  rescue
    _ -> Enum.map(@archetypes, &%{&1 | extensions: []})
  end

  @doc "One archetype by key, from the availability-filtered list."
  @spec get(String.t() | nil) :: t() | nil
  def get(key) when is_binary(key), do: Enum.find(list(), &(&1.key == key))
  def get(_), do: nil

  @doc """
  The card preselected on page load: the one whose preset matches the
  site-wide default preset setting (falling back to Standard).
  """
  @spec default_key() :: String.t()
  def default_key do
    preset = PhoenixKitProjects.Features.default_preset_key()

    case Enum.find(@archetypes, &(&1.preset == preset and &1.extensions == [])) do
      %{key: key} -> key
      _ -> "standard"
    end
  end
end
