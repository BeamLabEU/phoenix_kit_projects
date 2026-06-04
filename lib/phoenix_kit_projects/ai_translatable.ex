defmodule PhoenixKitProjects.AITranslatable do
  @moduledoc """
  `PhoenixKit.Modules.AI.Translatable` adapter for projects resources —
  the small per-module hook into core's generic AI-translation pipeline.

  Serves four resource types — `"project"`, `"template"` (a `Project` with
  `is_template: true`), `"task"`, and `"assignment"` — each translating the
  fields its schema declares via `translatable_fields/0` (project/template:
  `name` + `description`; task: `title` + `description`; assignment:
  `description`).

  ## Storage

  Translations live in each schema's `translations` JSONB column, shaped
  `%{lang => %{field => value}}` with **plain** field keys (no underscore
  prefix — unlike catalogue's multilang `data`). Source text comes from
  `translations[source_lang][field]` when present, else the resource's
  primary column (`name`/`title`/`description`). Because the per-language
  map stores values verbatim, an AI result identical to the source (a code,
  text already in the target language) is still persisted — the field fills
  in and the language stops reading as "missing", with no extra handling.

  Registered from `PhoenixKitProjects.ai_translatables/0`. The enqueue, the
  AI call, the per-resource PubSub broadcasts, the retry policy, and the
  audit log all live in core — this module only reads source fields and
  merges results back atomically.
  """

  @behaviour PhoenixKit.Modules.AI.Translatable

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Schemas.{Assignment, Project, Task}

  @impl true
  # Project + template share the Project schema; the `is_template` flag is the
  # discriminator. Validate it on fetch so a "project" job can't translate a
  # template (or vice versa) and broadcast on the wrong per-resource topic.
  def fetch("project", uuid), do: wrap_project(Projects.get_project(uuid), :project)
  def fetch("template", uuid), do: wrap_project(Projects.get_project(uuid), :template)
  def fetch("task", uuid), do: wrap(Projects.get_task(uuid))
  def fetch("assignment", uuid), do: wrap(Projects.get_assignment(uuid))
  def fetch(other, _uuid), do: {:error, {:unknown_resource_type, other}}

  defp wrap(nil), do: {:error, :resource_not_found}
  defp wrap(%_{} = resource), do: {:ok, resource}

  defp wrap_project(nil, _kind), do: {:error, :resource_not_found}
  defp wrap_project(%Project{is_template: true} = p, :template), do: {:ok, p}
  defp wrap_project(%Project{is_template: true}, :project), do: {:error, :resource_type_mismatch}
  # `is_template` is false (the schema default) or nil → a regular project.
  defp wrap_project(%Project{}, :template), do: {:error, :resource_type_mismatch}
  defp wrap_project(%Project{} = p, :project), do: {:ok, p}

  @impl true
  def source_fields(resource, source_lang) do
    lang_map = Map.get(resource.translations || %{}, source_lang, %{})

    for field <- fields_for(resource),
        value = source_value(resource, field, lang_map),
        present?(value),
        into: %{},
        do: {field, value}
  end

  # A secondary source language reads its own subtree; fall back to the
  # primary column (rows only have columns until translated). A blank or
  # non-string override is treated as absent, so we never feed an empty
  # string to the translator when the column still has real content.
  defp source_value(resource, field, lang_map) do
    override = Map.get(lang_map, field)
    if present?(override), do: override, else: column_value(resource, field)
  end

  defp column_value(resource, field) do
    Map.get(resource, String.to_existing_atom(field))
  rescue
    # `field` always comes from a schema's `translatable_fields/0`, so the
    # atom exists and this can't fire today. Kept as a guard against a field
    # being listed in `translatable_fields/0` without a matching column: skip
    # it (nil) rather than crash the translation job into an infinite retry.
    ArgumentError -> nil
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  @impl true
  def put_translation(resource, target_lang, fields, _opts) do
    repo = RepoHelper.repo()
    {schema, update_fn} = persist_target(resource)
    uuid = resource.uuid

    # Re-read the row FOR UPDATE so concurrent per-language jobs
    # (enqueue_all_missing) serialize on the row lock and each merges against
    # the latest committed `translations` — otherwise a job merging into its
    # stale pre-AI snapshot would drop sibling languages.
    repo.transaction(fn ->
      query = schema |> where([r], r.uuid == ^uuid) |> lock("FOR UPDATE")

      case repo.one(query) do
        nil ->
          repo.rollback(:resource_not_found)

        fresh ->
          merged = merge_translation(fresh, target_lang, fields)

          # `broadcast: false` — the write happens inside this FOR UPDATE
          # transaction, so suppress the updater's own `:*_updated` event (it
          # would fire pre-commit / look like a user edit). Translation
          # completion is signalled by core's `:translation_completed`.
          case update_fn.(fresh, %{"translations" => merged}, broadcast: false) do
            {:ok, updated} -> updated
            {:error, reason} -> repo.rollback(reason)
          end
      end
    end)
  end

  defp merge_translation(resource, target_lang, fields) do
    existing = resource.translations || %{}
    target_map = Map.get(existing, target_lang, %{})
    Map.put(existing, target_lang, Map.merge(target_map, fields))
  end

  # Project + template share the Project schema/fields/updater.
  defp fields_for(%Task{}), do: Task.translatable_fields()
  defp fields_for(%Assignment{}), do: Assignment.translatable_fields()
  defp fields_for(%Project{}), do: Project.translatable_fields()

  defp persist_target(%Task{}), do: {Task, &Projects.update_task/3}
  defp persist_target(%Assignment{}), do: {Assignment, &Projects.update_assignment_form/3}
  defp persist_target(%Project{}), do: {Project, &Projects.update_project/3}
end
