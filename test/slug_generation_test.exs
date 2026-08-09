defmodule PhoenixKitProjects.SlugGenerationTest do
  @moduledoc """
  Slug generation goes through core (and therefore `locale_slug`), not a local
  ASCII-only pipeline.

  The pipeline this replaced deleted every non-ASCII character, so a Cyrillic or
  Greek status name produced an EMPTY slug — and an empty slug is worse than a wrong
  one, because callers read it as "no slug yet" and regenerate on every save.

  These are the assertions that would fail if the change were reverted.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Schemas.ProjectStatus

  test "a Cyrillic status name yields a real slug" do
    # Statuses are looked up BY slug and "" is treated as nil, so an empty slug
    # made the status silently vanish.
    assert ProjectStatus.slugify("Видеопродакшн") == "videoprodakshn"
    assert ProjectStatus.slugify("Καλημέρα") == "kalimera"
  end

  test "plain ASCII is unchanged" do
    assert ProjectStatus.slugify("In Progress") == "in-progress"
  end
end
