defmodule PhoenixKitProjects.Extensions.ApiProvider do
  @moduledoc """
  The contract an extension implements to put one of ITS records on the
  projects JSON API — the way the CRM puts a project's meetings there
  without the projects module ever naming a CRM function.

  An extension declares the provider in its `phoenix_kit_project_extensions/0`
  map as `api: MyModule`; the API then serves

      GET    /api/projects/v1/ext/<resource>
      POST   /api/projects/v1/ext/<resource>
      GET    /api/projects/v1/ext/<resource>/:id
      PATCH  /api/projects/v1/ext/<resource>/:id

  through `Web.Api.ExtController`, which does what every other endpoint
  does first — the key's scope (`scopes/0`), the extension enabled on the
  project (else 403 `feature_disabled` naming the extension key), the key's
  role against `action/0` (an extension-declared action floors at member) —
  and only then calls the provider with a `ctx`:

      %{project: project, key: api_key, user_uuid: accountable person,
        actor: %{kind: "ai_agent", uuid: key uuid}}

  Every callback returns `{:ok, map}` (the JSON body, `{:ok, map, status}`
  for a 201) or `{:error, {status, code, message, details | nil}}` in the
  API's error vocabulary. `docs/0` returns endpoint rows in
  `Web.Api.Docs`'s shape, with paths under `/ext/<resource>`, so the
  record documents itself in `llms.txt` and `openapi.json`.

  Dispatch is by `function_exported?/3` through `apply/3`: the provider
  lives in another application. Adopt the behaviour so a misnamed callback
  is a compile warning rather than a silent 404.
  """

  @type ctx :: %{project: map(), key: map(), user_uuid: binary() | nil, actor: map()}
  @type error :: {:error, {pos_integer(), String.t(), String.t(), map() | nil}}

  @doc "The resource's path segment, a slug: `interactions`."
  @callback resource() :: String.t()

  @doc """
  The scopes the key needs, e.g.
  `%{read: "interactions:read", write: "interactions:write"}`.
  """
  @callback scopes() :: %{read: String.t(), write: String.t()}

  @doc "The project action the key's role must meet for writes (reads use `:view`)."
  @callback action() :: atom()

  @callback list(ctx(), params :: map()) :: {:ok, map()} | error()
  @callback get(ctx(), id :: String.t()) :: {:ok, map()} | error()
  @callback create(ctx(), attrs :: map()) :: {:ok, map()} | {:ok, map(), pos_integer()} | error()
  @callback update(ctx(), id :: String.t(), attrs :: map()) :: {:ok, map()} | error()

  @doc "Endpoint rows for the docs (see `PhoenixKitProjects.Web.Api.Docs.endpoint/0`)."
  @callback docs() :: [map()]
end
