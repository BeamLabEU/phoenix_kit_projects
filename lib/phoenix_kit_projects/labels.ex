defmodule PhoenixKitProjects.Labels do
  @moduledoc """
  Per-project labels (Phase C): registry CRUD (managed in the project's
  Modules panel) + assignment tagging through the V7 join table. Rides
  the `labels` feature flag at the CALLER layer, like every context here.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.PubSub
  alias PhoenixKitProjects.Schemas.Label

  @join_table "phoenix_kit_project_assignment_labels"

  # Schemaless queries do NOT inherit @schema_prefix (that's a schema
  # attribute) — resolve the SAME prefix source PhoenixKit.SchemaPrefix
  # compiles into every schema, or a prefixed install would hit an
  # unprefixed join table while the Label registry lives under the
  # prefix (panel round, Grok — the house --prefix bug family).
  @prefix Application.compile_env(:phoenix_kit, :prefix)

  @doc "A project's labels, position-then-name ordered."
  @spec list_for_project(binary()) :: [Label.t()]
  def list_for_project(project_uuid) do
    RepoHelper.repo().all(
      from(l in Label,
        where: l.project_uuid == ^project_uuid,
        order_by: [asc: l.position, asc: l.name]
      )
    )
  rescue
    _ -> []
  end

  @doc "Creates a label in a project."
  @spec create(map(), map(), keyword()) :: {:ok, Label.t()} | {:error, Ecto.Changeset.t()}
  def create(project, attrs, opts \\ []) do
    %Label{}
    |> Label.changeset(Map.put(attrs, :project_uuid, project.uuid))
    |> RepoHelper.repo().insert()
    |> tap_label("projects.label_created", project.uuid, opts)
  end

  @doc "Deletes a label (join rows cascade)."
  @spec delete(Label.t(), keyword()) :: :ok | {:error, term()}
  def delete(%Label{} = label, opts \\ []) do
    case RepoHelper.repo().delete(label) do
      {:ok, deleted} ->
        {:ok, _} = tap_label({:ok, deleted}, "projects.label_deleted", label.project_uuid, opts)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Replaces an assignment's labels with `label_uuids` — whitelisted to the
  ASSIGNMENT'S OWN project's registry (a cross-project label uuid is
  silently dropped, not an error: stale panel state must not block a save).
  """
  @spec set_assignment_labels(map(), [binary()]) :: :ok
  def set_assignment_labels(assignment, label_uuids) when is_list(label_uuids) do
    repo = RepoHelper.repo()

    valid_uuids =
      repo.all(
        from(l in Label,
          where: l.project_uuid == ^assignment.project_uuid and l.uuid in ^label_uuids,
          select: l.uuid
        )
      )

    repo.transaction(fn ->
      repo.delete_all(
        from(j in @join_table,
          where: j.assignment_uuid == type(^assignment.uuid, Ecto.UUID)
        )
        |> with_prefix()
      )

      rows =
        Enum.map(valid_uuids, fn label_uuid ->
          %{
            assignment_uuid: Ecto.UUID.dump!(assignment.uuid),
            label_uuid: Ecto.UUID.dump!(label_uuid)
          }
        end)

      if rows != [], do: repo.insert_all(@join_table, rows, prefix: @prefix)
      :ok
    end)

    :ok
  rescue
    _ -> :ok
  end

  @doc "Label lists per assignment uuid for a displayed set (one query)."
  @spec labels_for_assignments([binary()]) :: %{binary() => [Label.t()]}
  def labels_for_assignments([]), do: %{}

  def labels_for_assignments(uuids) when is_list(uuids) do
    # Schemaless join-table reads: the uuid params must be TYPED and the
    # selected raw key LOADED back to a string uuid, or the map keys would
    # be 16-byte binaries that never match the LV's string uuids.
    RepoHelper.repo().all(
      from(j in @join_table,
        join: l in Label,
        on: l.uuid == j.label_uuid,
        where: j.assignment_uuid in type(^uuids, {:array, Ecto.UUID}),
        order_by: [asc: l.position, asc: l.name],
        select: {type(j.assignment_uuid, Ecto.UUID), l}
      )
      |> with_prefix()
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  rescue
    _ -> %{}
  end

  defp with_prefix(query) do
    if is_binary(@prefix), do: Ecto.Query.put_query_prefix(query, @prefix), else: query
  end

  defp tap_label({:ok, label} = result, action, project_uuid, opts) do
    Activity.log(action,
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "project",
      resource_uuid: project_uuid,
      metadata: %{"name" => label.name, "label_uuid" => label.uuid}
    )

    PubSub.broadcast_project(:project_labels_changed, %{uuid: project_uuid})
    result
  end

  defp tap_label({:error, _} = error, _action, _project_uuid, _opts), do: error
end
