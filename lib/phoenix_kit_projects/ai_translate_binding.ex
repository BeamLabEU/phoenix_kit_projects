defmodule PhoenixKitProjects.AITranslateBinding do
  @moduledoc """
  `PhoenixKitAI.Components.AITranslate.FormBinding` for projects forms — the
  storage-specific half of the shared AI-translate glue.

  Projects store translations in a `translations` JSONB column shaped
  `%{lang => %{field => value}}` with plain field keys (the form binds them
  directly). The translatable fields differ per resource type — project/
  template (name + description), task (title + description), assignment
  (description) — read from each schema's `translatable_fields/0`.
  """

  @behaviour PhoenixKitAI.Components.AITranslate.FormBinding

  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.Schemas.{Assignment, Project, Task}

  @impl true
  def existing_translation_langs(resource_type, assigns) do
    translations = Ecto.Changeset.get_field(assigns.form.source, :translations) || %{}
    fields = fields_for(resource_type)

    translations
    |> Enum.filter(fn {lang, lang_map} ->
      is_binary(lang) and has_any_field?(lang_map, fields)
    end)
    |> Enum.map(fn {lang, _} -> lang end)
  end

  defp has_any_field?(lang_map, fields) when is_map(lang_map) do
    Enum.any?(fields, fn field -> present?(Map.get(lang_map, field)) end)
  end

  defp has_any_field?(_, _), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  @impl true
  def apply_translation(_resource_type, changeset, lang, fields) do
    current = Ecto.Changeset.get_field(changeset, :translations) || %{}
    lang_map = Map.get(current, lang, %{})
    updated = Map.put(current, lang, Map.merge(lang_map, fields))
    Ecto.Changeset.put_change(changeset, :translations, updated)
  end

  @impl true
  def actor_uuid(socket), do: Activity.actor_uuid(socket)

  defp fields_for("task"), do: Task.translatable_fields()
  defp fields_for("assignment"), do: Assignment.translatable_fields()
  # project + template share the Project schema.
  defp fields_for(_project_or_template), do: Project.translatable_fields()
end
