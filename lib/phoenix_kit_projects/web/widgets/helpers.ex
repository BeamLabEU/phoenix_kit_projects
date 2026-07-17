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

  require Logger

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
    e ->
      Logger.warning("[Widgets.Helpers] resolve_project failed: #{Exception.message(e)}")
      nil
  end

  @doc """
  `Projects.list_projects/0` with the widget no-crash guard: a transient DB
  error (connection loss, mid-migration missing table) degrades to an empty
  list — a widget must never crash the host dashboard.
  """
  @spec safe_list_projects() :: [Project.t()]
  def safe_list_projects do
    Projects.list_projects()
  rescue
    e ->
      Logger.warning("[Widgets.Helpers] safe_list_projects failed: #{Exception.message(e)}")
      []
  end

  @doc """
  `Projects.project_summary/1` with the widget no-crash guard — `nil` on a DB
  error, which every consuming widget already renders as its empty state.
  """
  @spec safe_project_summary(Project.t()) :: map() | nil
  def safe_project_summary(%Project{} = project) do
    Projects.project_summary(project)
  rescue
    e ->
      Logger.warning("[Widgets.Helpers] safe_project_summary failed: #{Exception.message(e)}")
      nil
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
  else the first valid view. The user's choice is NEVER overridden by size —
  content self-fits via container-query type scaling instead.
  """
  @spec effective_view(String.t() | nil, [String.t()]) :: String.t()
  def effective_view(view, valid) when view in ["", nil], do: List.first(valid)
  def effective_view(view, valid), do: if(view in valid, do: view, else: List.first(valid))

  @doc """
  A scale-aware self-fit font-size style: the type grows with its cq slot but
  stays clamped to a consistent px range, so widgets look cohesive at any box
  size (no comically large list rows, no unreadable KPI labels). The
  `--pk-scale` var (set by the dashboards fit hook) keeps the clamp
  proportional when the board renders scaled down.
  """
  @spec fit_text(number(), String.t(), number()) :: String.t()
  def fit_text(min_px, cq, max_px) do
    "font-size: clamp(calc(#{min_px}px * var(--pk-scale, 1)), #{cq}, calc(#{max_px}px * var(--pk-scale, 1)))"
  end

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
  """
  attr(:title, :string, required: true)
  attr(:icon, :string, default: "hero-clipboard-document-list")
  attr(:href, :string, default: nil)
  slot(:inner_block, required: true)
  slot(:actions)

  def frame(assigns) do
    ~H"""
    <style>
      @container (max-height: 26px) {
        .pk-slot-meta {
          display: none !important;
        }
      }
    </style>
    <div class="card h-full overflow-hidden bg-base-100">
      <div class="flex h-full flex-col p-3">
        <div class="mb-2 flex items-center gap-2">
          <.icon name={@icon} class="h-4 w-4 shrink-0 text-base-content/50" />
          <h3 class="truncate text-sm font-semibold">
            {@title}
          </h3>
          <div class="ml-auto flex items-center gap-1">
            {render_slot(@actions)}
            <.link :if={@href} navigate={@href} class="text-base-content/40 hover:text-base-content">
              <.icon name="hero-arrow-top-right-on-square" class="h-3.5 w-3.5" />
            </.link>
          </div>
        </div>
        <%!-- Dashboards are one screenful — content CLIPS at the box, never
        scrolls (widgets budget their rows via the "limit" setting). --%>
        <div class="min-h-0 flex-1 overflow-hidden">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  @doc "A centered, iconed empty-state body (widgets must never look broken-empty)."
  attr(:icon, :string, default: "hero-clipboard-document-list")
  attr(:message, :string, required: true)

  def empty(assigns) do
    ~H"""
    <div class="flex h-full flex-col items-center justify-center gap-1 py-2 text-center text-base-content/40">
      <.icon name={@icon} class="h-6 w-6" />
      <p class="text-xs">{@message}</p>
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
