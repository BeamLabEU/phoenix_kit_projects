defmodule PhoenixKitProjects.ListControls do
  @moduledoc """
  When the project page's task list shows its controls — the
  Active / Done / All lens and the sort dropdown.

  Max, 2026-09-05: "by default we don't need to show them if there
  aren't multiple statuses, and with fewer than ten tasks there is no
  reason to show them either — but we should be able to control all of
  this via the settings." So:

    * `:auto` (default) — the controls appear only when they can change
      what is on screen: the project has tasks on BOTH sides of the lens
      (some active, some done) AND at least `threshold` tasks. Under the
      rule the list shows every task in manual order, which is also what
      lets drag-reordering work on a small project without a detour
      through the All lens.
    * `:always` — the controls are always there.
    * `:never` — never.

  Site-wide `PhoenixKit.Settings` keys, configured on
  `/admin/settings/projects`; validated on the way in so a malformed
  value resolves to the default.
  """

  @module "projects"
  @mode_key "projects_list_controls_mode"
  @threshold_key "projects_list_controls_threshold"

  @modes ~w(auto always never)
  @default_mode "auto"
  @default_threshold 10
  @threshold_min 2
  @threshold_max 200

  @type mode :: :auto | :always | :never
  @type settings :: %{mode: mode(), threshold: pos_integer()}

  @doc "Allowed mode strings, for the settings form."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc "Bounds for the task threshold, for the settings form."
  @spec threshold_range() :: {pos_integer(), pos_integer()}
  def threshold_range, do: {@threshold_min, @threshold_max}

  @doc "The current settings (validated; defaults when unset or malformed)."
  @spec read() :: settings()
  def read do
    values = PhoenixKit.Settings.get_settings_direct([@mode_key, @threshold_key])
    mode = Map.get(values, @mode_key, @default_mode)
    mode = if mode in @modes, do: mode, else: @default_mode

    threshold =
      case Integer.parse(Map.get(values, @threshold_key) || to_string(@default_threshold)) do
        {n, _} -> n |> max(@threshold_min) |> min(@threshold_max)
        :error -> @default_threshold
      end

    %{mode: String.to_atom(mode), threshold: threshold}
  end

  @doc """
  Whether the controls show for a list with `counts` (`%{active, done,
  total}`, the full project's numbers — never the visible slice).
  """
  @spec show?(settings(), %{
          active: non_neg_integer(),
          done: non_neg_integer(),
          total: non_neg_integer()
        }) ::
          boolean()
  def show?(%{mode: :always}, _counts), do: true
  def show?(%{mode: :never}, _counts), do: false

  def show?(%{mode: :auto, threshold: threshold}, %{active: active, done: done, total: total}) do
    active > 0 and done > 0 and total >= threshold
  end

  @doc "Persist the mode (one of `modes/0`); anything else is ignored."
  @spec put_mode(String.t()) :: term()
  def put_mode(mode) when mode in @modes,
    do: PhoenixKit.Settings.update_setting_with_module(@mode_key, mode, @module)

  def put_mode(_), do: :ignore

  @doc "Persist the task threshold, clamped to `threshold_range/0`; non-numbers are ignored."
  @spec put_threshold(term()) :: term()
  def put_threshold(value) do
    case Integer.parse(to_string(value)) do
      {n, _} ->
        clamped = n |> max(@threshold_min) |> min(@threshold_max)

        PhoenixKit.Settings.update_setting_with_module(
          @threshold_key,
          to_string(clamped),
          @module
        )

      :error ->
        :ignore
    end
  end

  @doc "Restore both settings to their defaults."
  @spec reset() :: :ok
  def reset do
    put_mode(@default_mode)
    put_threshold(@default_threshold)
    :ok
  end
end
