defmodule PhoenixKitProjects.Web.Api.ExtController do
  @moduledoc """
  `/ext/:resource` — records an EXTENSION puts on the API through
  `PhoenixKitProjects.Extensions.ApiProvider` (the CRM's meetings on a
  project, for one). The checks are this API's usual three, then the
  provider does the work; see the behaviour for the contract.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias PhoenixKitProjects.Extensions
  alias PhoenixKitProjects.Schemas.ApiKey
  alias PhoenixKitProjects.Web.Api.Json

  def index(conn, %{"resource" => resource} = params) do
    case prepare(conn, resource, :read, params) do
      {:ok, conn, provider} ->
        call(conn, provider, :list, [ctx(conn), Map.drop(params, ["resource"])])

      {:halt, conn} ->
        conn
    end
  end

  def show(conn, %{"resource" => resource, "id" => id}) do
    case prepare(conn, resource, :read) do
      {:ok, conn, provider} -> call(conn, provider, :get, [ctx(conn), id])
      {:halt, conn} -> conn
    end
  end

  def create(conn, %{"resource" => resource} = params) do
    case prepare(conn, resource, :write, params) do
      {:ok, conn, provider} ->
        attrs = Map.drop(params, ["resource"])

        Json.idempotent(conn, [], fn ->
          case safe_apply(provider, :create, [ctx(conn), attrs]) do
            {:ok, body, status} ->
              {status, body}

            {:ok, body} ->
              {201, body}

            {:error, {status, code, message, details}} ->
              Json.error_body(status, code, message, details)
          end
        end)

      {:halt, conn} ->
        conn
    end
  end

  def update(conn, %{"resource" => resource, "id" => id} = params) do
    case prepare(conn, resource, :write) do
      {:ok, conn, provider} ->
        call(conn, provider, :update, [ctx(conn), id, Map.drop(params, ["resource", "id"])])

      {:halt, conn} ->
        conn
    end
  end

  # The provider for `resource`, or 404; then the scope, the project
  # (`project` picks a sub-project within reach for list and create), the
  # extension on it, and the role floor — reads need `:view`, writes the
  # provider's own action.
  defp prepare(conn, resource, mode, params \\ %{}) do
    case Extensions.api_provider(resource) do
      nil ->
        {:halt,
         Json.error(conn, :not_found, "not_found", "No such resource on this API: #{resource}.")}

      %{ext: ext, module: provider} ->
        scopes = provider.scopes()
        scope = if mode == :read, do: scopes.read, else: scopes.write
        action = if mode == :read, do: :view, else: provider.action()

        with {:ok, conn} <- Json.require_scope(conn, scope),
             {:ok, conn} <- Json.scope_project(conn, params),
             {:ok, conn} <- require_extension(conn, ext.key),
             {:ok, conn} <- Json.require_action(conn, action) do
          {:ok, conn, provider}
        end
    end
  end

  defp require_extension(conn, ext_key) do
    if Extensions.enabled?(conn.assigns.pk_project, ext_key),
      do: {:ok, conn},
      else:
        {:halt,
         Json.error(
           conn,
           :forbidden,
           "feature_disabled",
           "The #{ext_key} extension is not enabled on this project.",
           %{feature: ext_key}
         )}
  end

  @doc false
  def ctx(conn) do
    key = conn.assigns.pk_api_key

    %{
      project: conn.assigns.pk_project,
      key: key,
      user_uuid: ApiKey.accountable_uuid(key),
      actor: %{kind: "ai_agent", uuid: key.uuid}
    }
  end

  defp call(conn, provider, fun, args) do
    case safe_apply(provider, fun, args) do
      {:ok, body} ->
        json(conn, body)

      {:ok, body, status} ->
        conn |> put_status(status) |> json(body)

      {:error, {status, code, message, details}} ->
        Json.error(conn, status, code, message, details)
    end
  end

  # The provider is another application's module, reached by name.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp safe_apply(provider, fun, args) do
    if function_exported?(provider, fun, length(args)) do
      apply(provider, fun, args)
    else
      {:error, {404, "not_found", "This resource does not support that call.", nil}}
    end
  rescue
    e ->
      # What went wrong stays in the log: a provider's exception can name
      # SQL, tables and constraints, none of which an API caller should read.
      Logger.error(
        "[Projects.Api] extension provider #{inspect(provider)}.#{fun} failed: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      {:error, {500, "provider_failed", "The extension failed to answer this call.", nil}}
  end
end
