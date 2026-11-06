defmodule PhoenixKitProjects.MultilangReadsTest do
  @moduledoc """
  Which language a read asks for, and which entry of a `translations` map it
  gets. Core registers `et` but `es-ES`, so a form stores under one kind of
  code and a page may ask with the other.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Languages
  alias PhoenixKitProjects.L10n
  alias PhoenixKitProjects.People
  alias PhoenixKitProjects.People.Team
  alias PhoenixKitProjects.Schemas.{Assignment, Project, ProjectStatus, Task}

  describe "current_content_lang/0" do
    test "is the dialect the request resolved to, not the downgraded Gettext locale" do
      Gettext.put_locale(PhoenixKitWeb.Gettext, "es")
      Languages.put_request_locale("es-ES")

      assert L10n.current_content_lang() == "es-ES"
    end

    test "is the Gettext locale where no request set one (a job, the API)" do
      Gettext.put_locale(PhoenixKitWeb.Gettext, "et")

      assert L10n.current_content_lang() == "et"
    end
  end

  describe "language_entry/2" do
    test "prefers the exact code" do
      assert L10n.language_entry(%{"es-ES" => :exact, "es" => :base}, "es-ES") == :exact
    end

    test "falls back to the base code" do
      assert L10n.language_entry(%{"et" => :base}, "et-EE") == :base
    end

    test "finds a same-base dialect for a base code" do
      assert L10n.language_entry(%{"es-ES" => :dialect}, "es") == :dialect
    end

    test "picks the same sibling every time" do
      assert L10n.language_entry(%{"es-MX" => :mx, "es-AR" => :ar}, "es-CL") == :ar
    end

    test "is nil for another language, an unset one and an unset map" do
      assert L10n.language_entry(%{"fr-FR" => :fr}, "es-ES") == nil
      assert L10n.language_entry(%{"es-ES" => :es}, nil) == nil
      assert L10n.language_entry(nil, "es-ES") == nil
    end
  end

  describe "the localized readers" do
    test "Project" do
      project = %Project{name: "P", translations: %{"es-ES" => %{"name" => "Proyecto"}}}

      assert Project.localized_name(project, "es-ES") == "Proyecto"
      assert Project.localized_name(project, "es") == "Proyecto"
      assert Project.localized_name(project, "fr-FR") == "P"
    end

    test "Task" do
      task = %Task{title: "T", translations: %{"es-ES" => %{"title" => "Tarea"}}}

      assert Task.localized_title(task, "es") == "Tarea"
      assert Task.localized_title(task, "fr-FR") == "T"
    end

    test "Assignment" do
      assignment = %Assignment{
        description: "D",
        translations: %{"es-ES" => %{"description" => "Palabras"}}
      }

      assert Assignment.localized_description(assignment, "es") == "Palabras"
      assert Assignment.localized_description(assignment, "fr-FR") == "D"
    end

    test "ProjectStatus" do
      status = %ProjectStatus{label: "L", translations: %{"es-ES" => %{"label" => "Estado"}}}

      assert ProjectStatus.localized_label(status, "es") == "Estado"
      assert ProjectStatus.localized_label(status, "fr-FR") == "L"
    end

    test "People.localized_name/2" do
      team = %Team{name: "N", translations: %{"es-ES" => %{"name" => "Equipo"}}}

      assert People.localized_name(team, "es") == "Equipo"
      assert People.localized_name(team, "fr-FR") == "N"
    end

    test "a blank override reads as the primary text" do
      project = %Project{name: "P", translations: %{"es-ES" => %{"name" => ""}}}
      team = %Team{name: "N", translations: %{"es-ES" => %{"name" => ""}}}

      assert Project.localized_name(project, "es-ES") == "P"
      assert People.localized_name(team, "es-ES") == "N"
    end
  end
end
