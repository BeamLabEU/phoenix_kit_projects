defmodule PhoenixKitProjects.Web.Api.RateLimit do
  @moduledoc """
  The API's per-key rate limit: a fixed window of `limit` calls per
  `window_ms`, one bucket per key, on core's Hammer ETS backend (the one
  the portal's limiter shares — `PhoenixKit.Supervisor` starts it).

      config :phoenix_kit_projects, :api_rate_limit, limit: 300, window_ms: 60_000

  `limit: nil` (or `false`) switches it off. The default is 300 calls a
  minute, enough for an agent that polls and reports and far below what
  a runaway retry loop produces. A limiter failure DENIES, as the house
  rule for abuse controls says (`Portal.check_rate/2`): a 429 tells the
  agent to wait and retry, which is the right behaviour for a transient
  server fault too.
  """

  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKitProjects.Schemas.ApiKey

  @default_limit 300
  @default_window_ms 60_000

  @doc "The effective `%{limit, window_ms}`, or `nil` when the limit is off."
  @spec config() :: %{limit: pos_integer(), window_ms: pos_integer()} | nil
  def config do
    opts = Application.get_env(:phoenix_kit_projects, :api_rate_limit, [])

    case Keyword.get(opts, :limit, @default_limit) do
      limit when is_integer(limit) and limit > 0 ->
        %{limit: limit, window_ms: Keyword.get(opts, :window_ms, @default_window_ms)}

      _ ->
        nil
    end
  end

  @doc "The limit in words for messages and the docs: `300 calls per 60 seconds`."
  @spec describe() :: String.t()
  def describe do
    case config() do
      %{limit: limit, window_ms: window} -> "#{limit} calls per #{div(window, 1000)} seconds"
      nil -> "no rate limit"
    end
  end

  @doc """
  Takes one slot of the key's bucket: `{:allow, remaining}` or
  `{:deny, retry_after_ms}`. `:off` when no limit is configured.
  """
  @spec hit(ApiKey.t()) :: {:allow, non_neg_integer()} | {:deny, pos_integer()} | :off
  def hit(%ApiKey{uuid: key_uuid}) do
    case config() do
      nil ->
        :off

      %{limit: limit, window_ms: window} ->
        case RateLimiter.Backend.hit("pkp_api:#{key_uuid}", window, limit) do
          {:allow, count} -> {:allow, max(limit - count, 0)}
          {:deny, retry_after_ms} -> {:deny, max(retry_after_ms, 1)}
        end
    end
  rescue
    _ -> {:deny, @default_window_ms}
  catch
    :exit, _ -> {:deny, @default_window_ms}
  end
end
