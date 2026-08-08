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
          outcomes: [String.t()],
          icon: String.t(),
          preset: String.t(),
          extensions: [String.t()],
          extensions_off: [String.t()],
          requires_extensions: boolean()
        }

  # The 2026-08-07 five-AI quorum spec: FOUR intent-named cards (the
  # "Full tracker" density card folded into Customize), each with two
  # plain-language OUTCOME lines replacing the internal-vocabulary
  # chips. `requires_extensions: true` hides a card entirely when none
  # of its extension seeds is installed (Codex's rule — a Client card
  # that can't link a client is a lie).
  @archetypes [
    %{
      key: "quick_todo",
      name: "Simple checklist",
      description: "A shared checklist — no assignees, dates, or tracking.",
      outcomes: ["Check off shared tasks", "No scheduling overhead"],
      icon: "hero-check-circle",
      preset: "simple",
      extensions: [],
      # Files and Discussions default ON, so the leanest archetype was
      # arriving with a Files page and a Comments button — the two menu
      # entries a shared checklist least needs. `extensions` can only ADD,
      # so suppressing a default takes its own list.
      extensions_off: ~w(files discussions),
      requires_extensions: false
    },
    %{
      key: "standard",
      name: "Team project",
      description: "Day-to-day team work with assignees, due dates, board and timeline views.",
      outcomes: ["Assignees & due dates", "Board, list & timeline views"],
      icon: "hero-view-columns",
      preset: "standard",
      extensions: [],
      extensions_off: [],
      requires_extensions: false
    },
    %{
      key: "client_hub",
      name: "Client project",
      description: "Work you deliver to a client — linked client, billable time, invoicing.",
      outcomes: ["Linked client record", "Billable time & invoicing"],
      icon: "hero-briefcase",
      preset: "full",
      extensions: ~w(crm_client billing_customer),
      extensions_off: [],
      requires_extensions: true
    },
    %{
      key: "public_intake",
      name: "Public intake",
      description: "Let outsiders submit requests through a private link; work stays internal.",
      outcomes: ["Public submission form", "Internal triage board"],
      icon: "hero-inbox-arrow-down",
      preset: "standard",
      extensions: ~w(portal),
      extensions_off: [],
      requires_extensions: true
    }
  ]

  @doc """
  The card list with each archetype's `extensions` filtered to the
  AVAILABLE catalog. A `requires_extensions` card whose seeds are ALL
  unavailable is dropped entirely (its promise can't be kept).
  """
  @spec list() :: [t()]
  def list do
    available =
      Extensions.list_types()
      |> Enum.filter(&Registry.available?/1)
      |> MapSet.new(& &1.key)

    @archetypes
    |> Enum.map(fn a ->
      %{a | extensions: Enum.filter(a.extensions, &MapSet.member?(available, &1))}
    end)
    |> Enum.reject(&(&1.requires_extensions and &1.extensions == []))
  rescue
    _ ->
      @archetypes
      |> Enum.reject(& &1.requires_extensions)
      |> Enum.map(&%{&1 | extensions: []})
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
