defmodule PhoenixKitProjects.ApiAccess do
  @moduledoc """
  The areas an API key's access is set in, per project: each area is
  **none**, **read** or **write** (Max, 2026-10-16: "if I wanted I could
  allow read only access to comments or allow writing to them… basically
  every setting that we already have in the project should also be for the
  api permissions").

  An area is a pair of scopes (`"<area>:read"`, `"<area>:write"`); write
  includes read. The project module's own areas are below; a module that
  offers records over the API (the CRM's client interactions) adds its own
  through its API provider's `scopes/0` — read at call time, since the
  catalog is discovered at runtime.

  Presets (`presets/0`) are only a quick way to fill the grid; what a grant
  stores is its scope list.
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

  @core [
    %{key: "project", read: "project:read", write: "project:write"},
    %{key: "tasks", read: "tasks:read", write: "tasks:write"},
    %{key: "status", read: nil, write: "status:write"},
    %{key: "notes", read: "notes:read", write: "notes:write"},
    %{key: "comments", read: "comments:read", write: "comments:write"},
    %{key: "time", read: "time:read", write: "time:write"},
    %{key: "usage", read: "usage:read", write: "usage:write"},
    %{key: "events", read: "events:read", write: nil},
    %{key: "people", read: "people:read", write: nil}
  ]

  @levels ~w(none read write)

  @doc "The core scopes (every area's read and write)."
  @spec core_scopes() :: [String.t()]
  def core_scopes, do: @core |> Enum.flat_map(&[&1.read, &1.write]) |> Enum.reject(&is_nil/1)

  @doc """
  Every area, in order: `%{key, label, hint, read, write}` — `read` / `write`
  are the scopes (nil when the area has no such level). Modules' areas come
  after the project's own.
  """
  @spec areas() :: [map()]
  def areas, do: Enum.map(@core, &Map.merge(&1, describe(&1.key))) ++ provider_areas()

  defp describe("project"),
    do: %{
      label: gettext("Project"),
      hint: gettext("Its details and the briefing; status, settings")
    }

  defp describe("tasks"),
    do: %{
      label: gettext("Tasks"),
      hint: gettext("List and open tasks; create, edit, move and nest them")
    }

  defp describe("status"),
    do: %{label: gettext("Task status"), hint: gettext("Start, complete and reopen tasks")}

  defp describe("notes"),
    do: %{
      label: gettext("Agent notes"),
      hint: gettext("The notes an agent keeps on a task or the project")
    }

  defp describe("comments"),
    do: %{label: gettext("Comments"), hint: gettext("A task's discussion")}

  defp describe("time"),
    do: %{
      label: gettext("Time"),
      hint: gettext("Time entries and the Hours report; logging time")
    }

  defp describe("usage"),
    do: %{label: gettext("AI usage"), hint: gettext("Tokens and cost reported by agents")}

  defp describe("events"),
    do: %{label: gettext("Events"), hint: gettext("The project's calendar events")}

  defp describe("people"),
    do: %{label: gettext("People"), hint: gettext("Who is on the project, for assigning")}

  # A module's records over the API (`Extensions.api_providers/0`): its read
  # and write scopes are its area.
  defp provider_areas do
    PhoenixKitProjects.Extensions.api_providers()
    |> Enum.flat_map(fn %{module: mod} = provider ->
      case mod.scopes() do
        %{read: r, write: w} ->
          [
            %{
              key: r |> String.split(":") |> List.first(),
              read: r,
              write: w,
              label: provider_label(provider, r),
              hint: provider_hint(provider)
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.key)
  rescue
    _ -> []
  end

  defp provider_label(provider, read_scope) do
    case provider do
      %{label: label} when is_binary(label) -> label
      _ -> read_scope |> String.split(":") |> List.first() |> String.capitalize()
    end
  end

  defp provider_hint(%{ext: %{label: label}}) when is_binary(label),
    do: gettext("From %{module}", module: label)

  defp provider_hint(_), do: nil

  @doc "The levels an area may be set to."
  @spec levels() :: [String.t()]
  def levels, do: @levels

  @doc ~S|An area's level in a scope list: `"write"`, `"read"` or `"none"`.|
  @spec level(map(), [String.t()]) :: String.t()
  def level(%{write: w, read: r}, scopes) do
    cond do
      w && w in scopes -> "write"
      r && r in scopes -> "read"
      true -> "none"
    end
  end

  @doc "The grid of a scope list: `%{area_key => level}` for every area."
  @spec grid([String.t()]) :: %{String.t() => String.t()}
  def grid(scopes), do: Map.new(areas(), &{&1.key, level(&1, scopes)})

  @doc """
  The scope list a grid stands for. Write brings read along; a level the
  area does not have falls back to the one it has (read-only areas cannot
  be written).
  """
  @spec scopes(%{optional(String.t()) => String.t()}) :: [String.t()]
  def scopes(grid) when is_map(grid) do
    areas()
    |> Enum.flat_map(fn area ->
      case Map.get(grid, area.key, "none") do
        "write" -> [area.read, area.write]
        "read" -> [area.read]
        _ -> []
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  The presets a grant can start from: `{key, label, grid}`. They fill the
  grid; nothing about them is stored.
  """
  @spec presets() :: [{String.t(), String.t(), map()}]
  def presets do
    all = areas()

    [
      {"full", gettext("Full"), Map.new(all, &{&1.key, if(&1.write, do: "write", else: "read")})},
      {"read", gettext("Read only"),
       Map.new(all, &{&1.key, if(&1.read, do: "read", else: "none")})},
      {"none", gettext("No access"), Map.new(all, &{&1.key, "none"})}
    ] ++ provider_presets(all)
  end

  # "<module area>, read only" / "… read and write" for each module area —
  # Max's case: the CRM's interactions read from a project and nothing else.
  defp provider_presets(all) do
    core_keys = Enum.map(@core, & &1.key)

    all
    |> Enum.reject(&(&1.key in core_keys))
    |> Enum.flat_map(fn area ->
      none = Map.new(all, &{&1.key, "none"})

      [
        {"#{area.key}_read", gettext("%{area}, read only", area: area.label),
         Map.put(none, area.key, "read")},
        {"#{area.key}_write", gettext("%{area}, read and write", area: area.label),
         Map.put(none, area.key, "write")}
      ]
    end)
  end

  @doc "The preset a scope list matches exactly, or `\"custom\"`."
  @spec preset_of([String.t()]) :: String.t()
  def preset_of(scopes) do
    mine = Enum.sort(Enum.uniq(scopes))

    Enum.find_value(presets(), "custom", fn {key, _label, grid} ->
      if Enum.sort(scopes(grid)) == mine, do: key
    end)
  end
end
