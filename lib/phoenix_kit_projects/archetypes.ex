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

  The card copy is catalog DATA, translated at render time with the
  runtime `Gettext.gettext/2` — which the extractor cannot see, so every
  literal here is wrapped in `gettext_noop/1` (registers the msgid,
  returns it unchanged). Without that the cards existed in no
  catalogue and rendered English in every locale (found 2026-09-05).
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

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
  # "Full tracker" density card folded into Customize) — plus, since the
  # project page became top-level tabs (2026-09-05), a fifth for a
  # project with no task list at all. Each carries two
  # plain-language OUTCOME lines replacing the internal-vocabulary
  # chips. `requires_extensions: true` hides a card entirely when none
  # of its extension seeds is installed (Codex's rule — a Client card
  # that can't link a client is a lie).
  @archetypes [
    %{
      key: "quick_todo",
      name: gettext_noop("Simple checklist"),
      description: gettext_noop("A shared checklist — no assignees, dates, or tracking."),
      outcomes: [gettext_noop("Check off shared tasks"), gettext_noop("No scheduling overhead")],
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
      name: gettext_noop("Team project"),
      description:
        gettext_noop("Day-to-day team work with assignees, due dates, board and timeline views."),
      outcomes: [
        gettext_noop("Assignees & due dates"),
        gettext_noop("Board, list & timeline views")
      ],
      icon: "hero-view-columns",
      preset: "standard",
      extensions: [],
      extensions_off: [],
      requires_extensions: false
    },
    %{
      key: "client_hub",
      name: gettext_noop("Client project"),
      description:
        gettext_noop("Work you deliver to a client — linked client, billable time, invoicing."),
      outcomes: [gettext_noop("Linked client record"), gettext_noop("Billable time & invoicing")],
      icon: "hero-briefcase",
      preset: "full",
      extensions: ~w(crm_client billing_customer),
      extensions_off: [],
      requires_extensions: true
    },
    %{
      key: "public_intake",
      name: gettext_noop("Public intake"),
      description:
        gettext_noop("Let outsiders submit requests through a private link; work stays internal."),
      outcomes: [gettext_noop("Public submission form"), gettext_noop("Internal triage board")],
      icon: "hero-inbox-arrow-down",
      preset: "standard",
      extensions: ~w(portal),
      extensions_off: [],
      requires_extensions: true
    },
    %{
      key: "space",
      name: gettext_noop("Just a space"),
      description:
        gettext_noop("No task list — a home for whiteboards, events, sites or documents."),
      outcomes: [
        gettext_noop("Only the tabs you pick"),
        gettext_noop("Nothing to start or finish")
      ],
      icon: "hero-squares-2x2",
      # The flag bundle is moot with tasks off; `simple` so a space that
      # later turns tasks on (Modules page) starts as a lean checklist.
      preset: "simple",
      extensions: [],
      # The boss's "each thing stands alone" (2026-09-05): a class leader
      # who only uses whiteboards gets a project that IS the whiteboards —
      # no Tasks tab, no Comments tab unless asked for. The user picks the
      # tabs below; anything default-on that is not a tab (Files) stays.
      extensions_off: ~w(tasks discussions),
      requires_extensions: false
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
