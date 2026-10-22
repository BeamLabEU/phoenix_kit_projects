defmodule PhoenixKitProjects.RefsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Refs

  describe "suggest_key/2" do
    test "names people actually give projects" do
      for {name, key} <- [
            {"ACME Manager", "ACME"},
            {"3D editor", "3DE"},
            {"PhoenixKit", "PK"},
            {"Phoenix Kit", "PK"},
            {"phoenix_kit_projects", "PKP"},
            {"Kitchen", "KIT"},
            {"Shop", "SHOP"},
            {"Köök", "KOOK"},
            {"Õie äri analüüs", "OAA"},
            {"Редактор", "RED"},
            {"Новый сайт клиента", "NSK"},
            {"CRM", "CRM"},
            {"2026", "P2026"},
            {"x", "XX"},
            {"", "PRJ"},
            {"!!!", "PRJ"},
            {nil, "PRJ"},
            {"A very long name with a great many words in it", "AVLNW"}
          ] do
        assert Refs.suggest_key(name) == key, "#{inspect(name)} → #{Refs.suggest_key(name)}"
        assert Refs.valid_key?(Refs.suggest_key(name))
      end
    end

    test "a taken or reserved key gets the lowest free number" do
      taken = MapSet.new(~w(KIT KIT2))
      assert Refs.suggest_key("Kitchen", &MapSet.member?(taken, &1)) == "KIT3"
      assert Refs.suggest_key("New") == "NEW2"
      assert Refs.suggest_key("Tasks") == "TAS"
      assert Refs.suggest_key("API") == "API2"
    end

    test "ten thousand taken forms still give a valid key" do
      key = Refs.suggest_key("Kitchen", &String.starts_with?(&1, "KIT"))
      assert Refs.valid_key?(key)
      refute String.starts_with?(key, "KIT")
      refute Refs.reserved?(42)
    end

    test "the number fits inside the length cap" do
      long = "ABCDEFGHIJ"
      assert Refs.suggest_key("ab cd ef gh ij", &(&1 == "ACEGI")) == "ACEGI2"
      assert String.length(Refs.suggest_key("Abcdefghij klm", &(&1 == long))) <= 10
    end
  end

  describe "parse/1" do
    test "a uuid, a key, a task ref — and nothing looser" do
      uuid = Ecto.UUID.generate()
      assert Refs.parse(uuid) == {:uuid, uuid}
      assert Refs.parse(" acme ") == {:project, "ACME"}
      assert Refs.parse("3de") == {:project, "3DE"}
      assert Refs.parse("acme-42") == {:task, "ACME", 42}
      assert Refs.parse("3DE-7") == {:task, "3DE", 7}

      for bad <- [
            "",
            "42",
            "A",
            "ACME-",
            "ACME-0",
            "ACME-x",
            "AN DI",
            "ACME-1-2",
            "12-3",
            "ABCDEFGHIJK",
            nil,
            42
          ] do
        assert Refs.parse(bad) == :error, inspect(bad)
      end

      # not what was typed once upcased, and not 16 raw bytes as a uuid
      for loose <- ["ß", "ﬁ", "ıı", "ABCDEFGHIJKLMNOP"], do: assert(Refs.parse(loose) == :error)
      assert Refs.suggest_key(<<255, 254>>) == "PRJ"

      # A uuid's first group is key-shaped: it is looked up as a KEY (and
      # finds nothing), never matched as a prefix of a uuid.
      assert Refs.parse("a3d6a459") == {:project, "A3D6A459"}
    end
  end

  test "valid_key?/1 and task_ref/2" do
    assert Refs.valid_key?("ACME")
    assert Refs.valid_key?("3D")
    refute Refs.valid_key?("acme")
    refute Refs.valid_key?("A")
    refute Refs.valid_key?("123")
    refute Refs.valid_key?("NEW")
    refute Refs.valid_key?("AN-DI")
    assert Refs.task_ref("ACME", 42) == "ACME-42"
    assert Refs.task_ref(nil, 42) == nil
    assert Refs.normalize_key(" acme ") == "ACME"
    assert Refs.normalize_key("  ") == nil
  end
end
