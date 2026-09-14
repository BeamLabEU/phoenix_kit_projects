defmodule PhoenixKitProjects.Web.ListUi do
  @moduledoc """
  Shared plumbing for the admin list pages (Projects / Tasks /
  Templates): column-visibility persistence, search-param coercion, the
  client-search haystack builder, and the Columns dropdown component.

  Each list page keeps its own column roster and settings key; these
  helpers only own the mechanics so the three pages can't drift apart.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  # Same settings custody as the calendar/gantt display config.
  @settings_module "projects"

  @doc """
  Reads a page's visible-column set from settings. `nil` (never saved)
  falls back to `defaults`; an empty string is a deliberate "all
  optional columns hidden". Unknown names are dropped and order is
  normalized to the `optional` roster.
  """
  @spec read_visible_columns(String.t(), [String.t()], [String.t()]) :: [String.t()]
  def read_visible_columns(key, optional, defaults) do
    case PhoenixKit.Settings.get_settings_direct([key])[key] do
      nil ->
        defaults

      stored when is_binary(stored) ->
        chosen = stored |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
        Enum.filter(optional, &(&1 in chosen))
    end
  end

  @doc """
  Toggles one column in the visible set and persists the result
  (comma-joined, one settings row per page). Returns the new set.
  """
  @spec toggle_visible_column(String.t(), [String.t()], [String.t()], String.t()) :: [String.t()]
  def toggle_visible_column(key, optional, visible, col) do
    new_visible =
      if col in visible,
        do: List.delete(visible, col),
        else: Enum.filter(optional, &(&1 in [col | visible]))

    PhoenixKit.Settings.update_setting_with_module(
      key,
      Enum.join(new_visible, ","),
      @settings_module
    )

    new_visible
  end

  @doc """
  Coerces the search event payload to a binary. A forged `search[x]=y`
  body arrives as a map — the query side would shrug it off, but
  rendering a map back into the input's `value` would crash the LV.
  """
  @spec coerce_search(map()) :: String.t()
  def coerce_search(params) do
    case params["search"] do
      s when is_binary(s) -> s
      _ -> ""
    end
  end

  @doc """
  Lowercased match target for the TableLocalSearch hook: the record's
  primary `fields` plus every language's translated values for the same
  fields — the same coverage as the server-side ilike search, so the
  instant client filter and the authoritative server result agree.

  `fields` are the translation-map keys (strings); each must also name
  a schema field (e.g. `["name", "description"]`, `["title", "description"]`).
  """
  @spec search_haystack(struct(), [String.t()]) :: String.t()
  def search_haystack(record, fields) do
    translated =
      for {_lang, tr_fields} <- record.translations || %{},
          is_map(tr_fields),
          key <- fields,
          val = tr_fields[key],
          is_binary(val),
          do: val

    primary = Enum.map(fields, &Map.get(record, String.to_existing_atom(&1)))

    (primary ++ translated)
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  @doc """
  The Columns dropdown: a focus-based daisyUI dropdown (closes when
  focus leaves) with one checkbox per optional column, each pushing
  `toggle_column` with its column key. `options` is the page's
  `{key, translated_label}` roster; `visible` its current visible set.
  """
  attr(:options, :list, required: true)
  attr(:visible, :list, required: true)

  def columns_control(assigns) do
    ~H"""
    <div class="dropdown">
      <div tabindex="0" role="button" class="btn btn-sm">
        <.icon name="hero-view-columns" class="w-4 h-4" /> {gettext("Columns")}
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-100 rounded-box z-20 w-44 p-2 shadow-md border border-base-200"
      >
        <li :for={{col, label} <- @options}>
          <label class="flex items-center gap-2 cursor-pointer">
            <input
              type="checkbox"
              class="checkbox checkbox-sm"
              checked={col in @visible}
              phx-click="toggle_column"
              phx-value-col={col}
            />
            {label}
          </label>
        </li>
      </ul>
    </div>
    """
  end
end
