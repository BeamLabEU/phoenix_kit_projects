defmodule PhoenixKitProjects.Web.Api.CommentsController do
  @moduledoc """
  A task's discussion over the API (V24's `comments` area): `GET
  /tasks/:id/comments` reads it, `POST /tasks/:id/comments` adds to it — the
  same thread people read and write under the task in its form. Apart from
  the agent's notes (`NotesController`), which are the agent's own record.

  Reading needs `comments:read` and `:view`; posting `comments:write` and
  the project's `:comment` floor. A comment is written as the person the
  key acts for (else the one who minted it), labelled with the key's name.
  """

  use Phoenix.Controller, formats: [:json]

  alias PhoenixKitProjects.{Activity, RefText}
  alias PhoenixKitProjects.Schemas.ApiKey
  alias PhoenixKitProjects.Web.Api.{Json, TasksController}

  @resource_type "assignment"
  @content_max 10_000

  def index(conn, %{"id" => id}) do
    with {:ok, conn, a} <- TasksController.fetch(conn, id),
         {:ok, conn} <- Json.require_scope(conn, "comments:read"),
         {:ok, conn} <- require_comments(conn),
         {:ok, conn} <- Json.require_action(conn, :view) do
      comments =
        @resource_type
        |> PhoenixKitComments.list_comments(a.uuid, status: "published", preload: [:user])
        |> Enum.map(&to_json/1)

      json(conn, %{task_uuid: a.uuid, comments: comments, count: length(comments)})
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> TasksController.not_found(conn)
    end
  end

  def create(conn, %{"id" => id} = params) do
    with {:ok, conn, a} <- TasksController.fetch(conn, id),
         {:ok, conn} <- Json.require_scope(conn, "comments:write"),
         {:ok, conn} <- require_comments(conn),
         {:ok, conn} <- Json.require_action(conn, :comment) do
      Json.idempotent(conn, [required: true], fn -> do_create(conn, a, params) end)
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> TasksController.not_found(conn)
    end
  end

  defp do_create(conn, a, params) do
    key = conn.assigns.pk_api_key
    content = params["content"]

    with {:ok, content} <- validate_content(content),
         uuid when is_binary(uuid) <- ApiKey.accountable_uuid(key) || :no_person,
         {:ok, comment} <-
           PhoenixKitComments.create_comment(@resource_type, a.uuid, uuid, %{
             # `#ANDI-42` becomes the link it names, within the key's reach.
             content: RefText.expand(content),
             parent_uuid: params["parent"],
             status: "published",
             attribution: %{mode: "personal", label: key.name}
           }) do
      Activity.log("projects.comment_added",
        actor_uuid: uuid,
        resource_type: "assignment",
        resource_uuid: a.uuid,
        metadata: %{"api_key" => key.uuid, "comment" => comment.uuid, "via" => "api"}
      )

      {201, %{comment: to_json(comment)}}
    else
      {:error, {status, code, message, details}} ->
        Json.error_body(status, code, message, details)

      :no_person ->
        Json.error_body(
          403,
          "forbidden",
          "This key has no accountable person behind it, so it cannot write comments."
        )

      {:error, %Ecto.Changeset{} = cs} ->
        Json.changeset_error(cs)

      {:error, reason} ->
        Json.error_body(422, "validation_failed", "The comment could not be saved.", %{
          reason: inspect(reason)
        })
    end
  end

  defp validate_content(content) when is_binary(content) do
    case String.trim(content) do
      "" ->
        {:error,
         {422, "validation_failed", "content must not be empty.", %{content: ["can't be blank"]}}}

      c when byte_size(c) > @content_max ->
        {:error,
         {422, "validation_failed", "content is too long.",
          %{content: ["at most #{@content_max} bytes"]}}}

      c ->
        {:ok, c}
    end
  end

  defp validate_content(_),
    do:
      {:error, {422, "validation_failed", "content is required.", %{content: ["can't be blank"]}}}

  # The discussion lives in the comments module: absent or switched off,
  # there is none to read or write.
  defp require_comments(conn) do
    if Code.ensure_loaded?(PhoenixKitComments) and PhoenixKitComments.enabled?(),
      do: {:ok, conn},
      else:
        {:halt,
         Json.error(
           conn,
           :forbidden,
           "feature_disabled",
           "Comments need the comments module switched on for this site.",
           %{feature: "comments"}
         )}
  rescue
    _ -> {:halt, Json.error(conn, :forbidden, "feature_disabled", "Comments are not available.")}
  end

  defp to_json(c) do
    %{
      uuid: c.uuid,
      parent: c.parent_uuid,
      author: author(c),
      content: RefText.collapse(c.content || ""),
      inserted_at: c.inserted_at
    }
  end

  defp author(%{attributed_label: label}) when is_binary(label) and label != "", do: label
  defp author(%{author_display_name: name}) when is_binary(name) and name != "", do: name
  defp author(%{user: %{email: email}}) when is_binary(email), do: email
  defp author(_), do: nil
end
