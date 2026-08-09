defmodule PhoenixKitProjects.Extensions.ConfigOptions do
  @moduledoc """
  Option resolution for extension `config_schema` `:select` fields —
  shared by the Modules & Features panel and the creation form (extracted
  from the panel LV when the form grew inline extension config).

  The descriptor may carry a literal option list or a lazy
  `{module, fun}` (0-arity; providers with data-driven options — the
  dashboards picker). Entries normalize to `%{value:, label:}`; a
  provider failure degrades to `[]`. The STORED value always appears
  (even when the provider no longer offers it) so a stale link is
  visible instead of silently blanked.
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

  @type option :: %{value: String.t(), label: String.t()}

  @spec resolve(map(), String.t() | nil) :: [option()]
  def resolve(field, current) do
    options =
      case field[:options] do
        {m, f} when is_atom(m) and is_atom(f) -> safe_options(m, f)
        list when is_list(list) -> list
        _ -> []
      end
      |> Enum.flat_map(&normalize_option/1)

    if is_binary(current) and current != "" and
         not Enum.any?(options, &(&1.value == current)) do
      options ++ [%{value: current, label: gettext("Current value (unavailable)")}]
    else
      options
    end
  end

  defp safe_options(m, f) do
    if Code.ensure_loaded?(m) and function_exported?(m, f, 0) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(m, f, []) do
        list when is_list(list) -> list
        _ -> []
      end
    else
      []
    end
  rescue
    _ -> []
  catch
    # kind+reason: a THROWING provider fun must not crash the caller.
    _, _ -> []
  end

  defp normalize_option(%{value: v, label: l}), do: [%{value: to_string(v), label: to_string(l)}]

  defp normalize_option(%{"value" => v, "label" => l}),
    do: [%{value: to_string(v), label: to_string(l)}]

  defp normalize_option({l, v}), do: [%{value: to_string(v), label: to_string(l)}]
  defp normalize_option(v) when is_binary(v), do: [%{value: v, label: v}]
  defp normalize_option(_), do: []
end
