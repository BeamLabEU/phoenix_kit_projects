defmodule PhoenixKitProjects.Web.Widgets.Helpers do
  @moduledoc """
  Shared helpers + frame for the dashboard widgets `phoenix_kit_projects`
  contributes to `phoenix_kit_dashboards` via `phoenix_kit_widgets/0`.

  Each widget is a `Phoenix.LiveComponent` the dashboards host renders with
  `settings` / `view` / `size` / `scope` assigns. These helpers centralize the
  enablement guard, the lenient project resolver (widgets pick a project by a
  free-text `"project"` setting, since a dashboard widget's settings schema is
  static), the shared card frame, and small formatters.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Schemas.Project

  @doc "True when the projects module is loaded and enabled."
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(PhoenixKitProjects) and PhoenixKitProjects.enabled?()
  rescue
    _ -> false
  end

  @doc """
  Resolve the `"project"` widget setting (a uuid, exact name, external id, or a
  name substring) to a `%Project{}`. Falls back to the first running project (or
  any project) when the setting is blank, so a freshly-added widget shows data.
  """
  @spec resolve_project(term()) :: Project.t() | nil
  def resolve_project(setting) do
    key = setting |> to_string() |> String.trim()

    cond do
      key == "" -> default_project()
      uuid?(key) -> Projects.get_project(key) || find_project(key)
      true -> find_project(key)
    end
  rescue
    _ -> nil
  end

  defp default_project do
    List.first(Projects.list_active_projects()) || List.first(Projects.list_projects())
  end

  defp uuid?(s), do: Regex.match?(~r/^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}$/, s)

  defp find_project(key) do
    down = String.downcase(key)
    projects = Projects.list_projects(include_templates: true)

    Enum.find(projects, fn p -> p.name == key or p.external_id == key end) ||
      Enum.find(projects, fn p -> String.contains?(String.downcase(p.name || ""), down) end)
  end

  @doc """
  Pick the effective view: honor the selected `view` if it's one of `valid`,
  else the first valid view. `small?` lets a widget force its most compact view.
  """
  @spec effective_view(String.t() | nil, [String.t()], boolean()) :: String.t()
  def effective_view(view, valid, small? \\ false)
  def effective_view(_view, valid, true), do: List.last(valid)
  def effective_view(view, valid, _small?) when view in ["", nil], do: List.first(valid)

  def effective_view(view, valid, _small?),
    do: if(view in valid, do: view, else: List.first(valid))

  @doc "A widget is small (force compact) when narrower than `w` or shorter than `h`."
  @spec small?(map() | nil, integer(), integer()) :: boolean()
  def small?(size, w, h) do
    match?(%{w: sw} when sw < w, size) or match?(%{h: sh} when sh < h, size)
  end

  @doc "A single-row instance renders dense (tighter frame, smaller title)."
  @spec compact?(map() | nil) :: boolean()
  def compact?(%{h: h}) when is_integer(h), do: h < 2
  def compact?(_size), do: false

  @doc "The current user's uuid out of the host-provided scope assign, or nil."
  @spec scope_user_uuid(term()) :: String.t() | nil
  def scope_user_uuid(%{user: %{uuid: uuid}}) when is_binary(uuid), do: uuid
  def scope_user_uuid(_scope), do: nil

  @doc "Format estimated hours compactly (e.g. `12h`, `1.5h`, `—`)."
  @spec hours(number() | nil) :: String.t()
  def hours(nil), do: "—"
  def hours(h) when h == 0, do: "0h"

  def hours(h) when is_number(h) do
    rounded = Float.round(h / 1, 1)
    if rounded == trunc(rounded), do: "#{trunc(rounded)}h", else: "#{rounded}h"
  end

  @doc "Format a datetime as `YYYY-MM-DD`, or `—`."
  @spec date(DateTime.t() | nil) :: String.t()
  def date(nil), do: "—"
  def date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  @doc """
  A shared widget card frame: header (icon + title + optional link) + body slot.
  `compact` (a single-row instance) tightens the paddings so the minimum box
  fits without a scrollbar.
  """
  attr(:title, :string, required: true)
  attr(:icon, :string, default: "hero-clipboard-document-list")
  attr(:href, :string, default: nil)
  attr(:compact, :boolean, default: false)
  slot(:inner_block, required: true)
  slot(:actions)

  def frame(assigns) do
    ~H"""
    <div class="card h-full overflow-hidden bg-base-100">
      <div class={["flex h-full flex-col", if(@compact, do: "p-2", else: "p-3")]}>
        <div class={["flex items-center gap-2", if(@compact, do: "mb-1", else: "mb-2")]}>
          <.icon name={@icon} class="h-4 w-4 shrink-0 text-base-content/50" />
          <h3 class={["truncate font-semibold", if(@compact, do: "text-xs", else: "text-sm")]}>
            {@title}
          </h3>
          <div class="ml-auto flex items-center gap-1">
            {render_slot(@actions)}
            <.link :if={@href} navigate={@href} class="text-base-content/40 hover:text-base-content">
              <.icon name="hero-arrow-top-right-on-square" class="h-3.5 w-3.5" />
            </.link>
          </div>
        </div>
        <div class="min-h-0 flex-1 overflow-auto">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  @doc "The 'projects module is off' placeholder body."
  def unavailable(assigns) do
    ~H"""
    <div class="flex h-full flex-col items-center justify-center gap-1 text-center text-base-content/50">
      <.icon name="hero-clipboard-document-list" class="h-8 w-8" />
      <p class="text-sm">{gettext("Projects module is disabled.")}</p>
    </div>
    """
  end
end
