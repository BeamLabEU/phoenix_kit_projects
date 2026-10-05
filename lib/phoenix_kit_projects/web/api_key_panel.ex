defmodule PhoenixKitProjects.Web.ApiKeyPanel do
  @moduledoc """
  The pure parts of the "API access" section on a project's Modules &
  Features page: the access presets a key is minted with (and read back
  from a key's scopes), the expiry choices, and the setup prompt a person
  hands their AI — the base URL, the agent guide, the first call to make,
  and the token when it is in hand.

  Designed with a three-seat panel (grok, zai, codex, 2026-10-05), who
  agreed on: one preset word per key instead of seven stacked scopes, a
  key ID that cannot be mistaken for the token, and a prompt that boots
  an agent in one paste.
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitProjects.Members
  alias PhoenixKitProjects.Schemas.ApiKey
  alias PhoenixKitProjects.Web.Api.Docs

  @presets ~w(full read metering custom)
  @expiry_options ~w(never 30 90 365)

  @doc "The preset keys, in the order the form offers them."
  @spec presets() :: [String.t()]
  def presets, do: @presets

  @doc "A preset's label."
  @spec preset_label(String.t()) :: String.t()
  def preset_label("full"), do: gettext("Full access")
  def preset_label("read"), do: gettext("Read-only")
  def preset_label("metering"), do: gettext("Metering")
  def preset_label(_), do: gettext("Custom")

  @doc "A preset's one-line explanation for the form."
  @spec preset_hint(String.t()) :: String.t()
  def preset_hint("full"),
    do: gettext("Everything this key's role allows — the usual choice for an agent.")

  def preset_hint("read"),
    do: gettext("Reads only: tasks and the project's records, nothing written.")

  def preset_hint("metering"),
    do: gettext("Only reports time, tokens and cost — for a runner that does not touch tasks.")

  def preset_hint(_), do: gettext("Pick the scopes yourself.")

  @doc "The scopes a preset stands for; `custom` takes the chosen list."
  @spec scopes_for(String.t(), [String.t()]) :: [String.t()]
  def scopes_for("full", _chosen), do: ApiKey.scopes()

  def scopes_for("read", _chosen),
    do: Enum.filter(ApiKey.scopes(), &String.ends_with?(&1, ":read"))

  def scopes_for("metering", _chosen),
    do: Enum.filter(ApiKey.scopes(), &(&1 in ~w(time:write usage:write)))

  def scopes_for(_custom, chosen), do: Enum.filter(ApiKey.scopes(), &(&1 in chosen))

  @doc "The preset a key's scopes match exactly, else `custom`."
  @spec preset_for([String.t()]) :: String.t()
  def preset_for(scopes) do
    set = MapSet.new(scopes)

    Enum.find(~w(full read metering), "custom", fn preset ->
      MapSet.equal?(set, MapSet.new(scopes_for(preset, [])))
    end)
  end

  @doc ~S|"Full access · 7 scopes" — the Access cell.|
  @spec access_label([String.t()]) :: String.t()
  def access_label(scopes) do
    count = length(scopes)

    "#{preset_label(preset_for(scopes))} · " <>
      ngettext("%{count} scope", "%{count} scopes", count, count: count)
  end

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
  The prompt a person pastes to their AI. With `token` in hand (creation,
  rotation) it is complete; without one it names the key and says where
  the token went, so the paste still tells the agent everything else.
  """
  @spec setup_prompt(String.t(), ApiKey.t(), String.t() | nil) :: String.t()
  def setup_prompt(project_name, %ApiKey{} = key, token) do
    acting_line =
      case key.user_uuid do
        uuid when is_binary(uuid) ->
          gettext(
            "You act for %{name} on this project — their AI, with their role (never above manager). Say so when it matters.",
            name: user_name(uuid)
          )

        _ ->
          gettext("This key is a shared agent on the project, not a person's.")
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
      gettext("Use this project's API."),
      gettext("Project: %{name}", name: project_name),
      gettext("Base URL: %{url}", url: absolute("")),
      gettext("Agent guide (read it first): %{url}", url: absolute("/llms.txt")),
      gettext("OpenAPI: %{url}", url: absolute("/openapi.json")),
      token_line,
      acting_line,
      "",
      gettext(
        "Send the token as an Authorization: Bearer header on every call and keep it out of chat, logs and output. Start with GET /me to confirm the project and what this key may do, and stay within its scopes. Log your time, tokens and cost as you work. On a 401 stop and tell me — the key may have been rotated or revoked. Ask me before destructive or bulk actions."
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

  @doc "The new-key form's starting state."
  @spec new_form() :: map()
  def new_form do
    %{
      "name" => "",
      "user" => "",
      "role" => "member",
      "expires" => "never",
      "preset" => "full",
      "scope" => Map.new(ApiKey.scopes(), &{&1, "true"})
    }
  end

  @doc """
  The form after a change: the typed fields carried, the custom scope ticks
  taken from the params when the checkboxes were on screen, and a key made
  for a viewer switched from Full access to Read-only (the role would refuse
  the writes anyway).
  """
  @spec form_from(map(), map() | nil) :: map()
  def form_from(params, previous) do
    previous = previous || new_form()

    form =
      previous
      |> Map.put("name", Map.get(params, "name", previous["name"]))
      |> Map.put("user", Map.get(params, "user", previous["user"]))
      |> Map.put("role", Map.get(params, "role", previous["role"]))
      |> Map.put("expires", Map.get(params, "expires", previous["expires"]))
      |> Map.put("preset", Map.get(params, "preset", previous["preset"]))
      |> Map.put("scope", scope_ticks(params, previous))

    form =
      if form["role"] == "viewer" and previous["role"] != "viewer" and form["preset"] == "full",
        do: Map.put(form, "preset", "read"),
        else: form

    # Picking a person turns the role into a cap; "at most manager" is no cap.
    if form["user"] != "" and previous["user"] == "",
      do: Map.put(form, "role", "manager"),
      else: form
  end

  # Checkboxes post only when ticked, so with the custom row on screen the
  # absent ones are off; with it hidden nothing posts and the ticks stay.
  defp scope_ticks(%{"preset" => "custom"} = params, _previous) when is_map_key(params, "scope"),
    do:
      Map.new(
        ApiKey.scopes(),
        &{&1, if(get_in(params, ["scope", &1]) in ["true", "on"], do: "true", else: "false")}
      )

  defp scope_ticks(_params, previous), do: previous["scope"]

  @doc "The scopes the form's custom ticks name."
  @spec ticked_scopes(map()) :: [String.t()]
  def ticked_scopes(form) do
    Enum.filter(ApiKey.scopes(), &(Map.get(form["scope"] || %{}, &1) == "true"))
  end
end
