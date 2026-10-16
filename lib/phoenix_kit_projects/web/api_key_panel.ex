defmodule PhoenixKitProjects.Web.ApiKeyPanel do
  @moduledoc """
  The pure parts of the API key pages: names (`user_name/1`, `kind_label/2`,
  `display_id/1`), what a member's own key starts as (`personal_attrs/2`),
  the expiry choices, and the setup prompt a person hands their AI — the
  base URL, the agent guide, the key's HOME project, how to reach its other
  projects, and the token when it is in hand.

  A key's access is set per project and per area since V24
  (`PhoenixKitProjects.ApiAccess`); the old one-word presets that lived
  here are gone with the one-project key.
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitProjects.Members
  alias PhoenixKitProjects.Schemas.ApiKey
  alias PhoenixKitProjects.Web.Api.Docs

  @expiry_options ~w(never 30 90 365)

  @doc "The expiry choices, in order: never, then days."
  @spec expiry_options() :: [{String.t(), String.t()}]
  def expiry_options do
    Enum.map(@expiry_options, fn
      "never" -> {gettext("Never"), "never"}
      days -> {gettext("In %{days} days", days: days), days}
    end)
  end

  @doc "The `expires_at` a choice means, from `now`; nil for never or anything unknown."
  @spec expires_at(String.t() | nil, DateTime.t()) :: DateTime.t() | nil
  def expires_at(choice, now \\ DateTime.utc_now())

  def expires_at(choice, now) when choice in @expiry_options and choice != "never" do
    now |> DateTime.add(String.to_integer(choice) * 86_400) |> DateTime.truncate(:second)
  end

  def expires_at(_, _), do: nil

  @doc "A person's name for the key pages: first and last name, else the email, else a dash."
  @spec user_name(map() | String.t() | nil) :: String.t()
  def user_name(uuid) when is_binary(uuid), do: user_name(Auth.get_user(uuid))

  def user_name(%{} = user) do
    [Map.get(user, :first_name), Map.get(user, :last_name)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> Map.get(user, :email) || "—"
      full -> full
    end
  end

  def user_name(_), do: "—"

  @doc "The project's members as `{user_uuid, name}`, owners first — the \"For\" choices and the rows' names."
  @spec people(String.t()) :: [{String.t(), String.t()}]
  def people(project_uuid) do
    project_uuid
    |> Members.list_members()
    |> Enum.map(&{&1.user_uuid, user_name(&1.user || %{uuid: &1.user_uuid})})
  end

  @doc ~S|"Personal · acts for Max Don" or "Shared agent" — the row's kind line.|
  @spec kind_label(ApiKey.t(), map()) :: String.t()
  def kind_label(%ApiKey{user_uuid: uuid}, names) when is_binary(uuid) do
    gettext("Personal · acts for %{name}", name: Map.get(names, uuid) || user_name(uuid))
  end

  def kind_label(_key, _names), do: gettext("Shared agent")

  @doc """
  What "Create my key" mints for `user` on a project where their role is
  `role` (an atom from `Authz.effective_role/2`): named after them, the cap
  at their own role (manager at most — the effective role is derived at
  each call anyway), every scope, no expiry.
  """
  @spec personal_attrs(map(), atom() | nil) :: map()
  def personal_attrs(user, role) do
    %{
      "name" => gettext("%{name}'s AI", name: user_name(user)),
      "role" => personal_cap(role),
      "scopes" => ApiKey.scopes(),
      "user_uuid" => Map.get(user, :uuid)
    }
  end

  defp personal_cap(role) when role in [:owner, :manager], do: "manager"
  defp personal_cap(:viewer), do: "viewer"
  defp personal_cap(_), do: "member"

  @doc "The site's absolute URL for a docs suffix (`/llms.txt`, `/me`, …)."
  @spec absolute(String.t()) :: String.t()
  def absolute(suffix), do: Routes.base_url() <> Docs.url(suffix)

  @doc """
  The prompt a person pastes to their AI. `home_name` is the key's HOME
  project — where a call without `project` acts; `GET /me` lists the rest.
  With `token` in hand (creation, rotation) the prompt is complete; without
  one it names the key and says where the token went, so the paste still
  tells the agent everything else.
  """
  @spec setup_prompt(String.t(), ApiKey.t(), String.t() | nil) :: String.t()
  def setup_prompt(home_name, %ApiKey{} = key, token) do
    acting_line =
      case key.user_uuid do
        uuid when is_binary(uuid) ->
          gettext(
            "You act for %{name} — their AI, with their role in each project (never above manager). Say so when it matters.",
            name: user_name(uuid)
          )

        _ ->
          gettext("This key is a shared agent, not a person's.")
      end

    token_line =
      case token do
        t when is_binary(t) and t != "" ->
          gettext("API token: %{token}", token: t)

        _ ->
          gettext(
            "API token: <paste the token saved when the key \"%{name}\" (ID %{key_id}) was created or rotated — it is not stored>",
            name: key.name,
            key_id: display_id(key)
          )
      end

    [
      gettext("Use this site's projects API."),
      gettext("Home project: %{name}", name: home_name),
      gettext("Base URL: %{url}", url: absolute("")),
      gettext("Agent guide (read it first): %{url}", url: absolute("/llms.txt")),
      gettext("OpenAPI: %{url}", url: absolute("/openapi.json")),
      token_line,
      acting_line,
      "",
      gettext(
        "Send the token as an Authorization: Bearer header on every call and keep it out of chat, logs and output. Start with GET /me: it lists every project this key reaches and what it may do in each (per area: none, read or write). A call without a project parameter acts on the home project; for any other project pass project=<its key>, e.g. GET /briefing?project=ANDI. A task ref like ANDI-42 selects its own project. Never assume one project's access from another's."
      ),
      gettext(
        "Log your time, tokens and cost as you work. On a 401 stop and tell me — the key may have been rotated or revoked. Ask me before destructive or bulk actions."
      )
    ]
    |> Enum.join("\n")
  end

  @doc """
  The public part of the token — `pkp_<key_id>` — without the trailing
  ellipsis the row used to show: an ellipsis reads as "truncated, copy me".
  """
  @spec display_id(ApiKey.t()) :: String.t()
  def display_id(%ApiKey{key_id: key_id}), do: "pkp_#{key_id}"
end
