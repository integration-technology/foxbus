defmodule Foxbus.ConfigTest do
  # Swaps the configured Storage dir and the old config_path, so not async.
  use ExUnit.Case, async: false

  @tmp_dir System.tmp_dir!()

  setup do
    storage_dir =
      Path.join(@tmp_dir, "foxbus_config_test_storage_#{System.unique_integer([:positive])}")

    old_config_path = Application.get_env(:foxbus, :config_path)
    old_storage_dir = Application.get_env(:nest_gen2, :storage_dir)
    old_stops = Application.get_env(:foxbus, :stops)
    old_lines = Application.get_env(:foxbus, :lines)

    Application.put_env(:nest_gen2, :storage_dir, storage_dir)

    on_exit(fn ->
      File.rm_rf(storage_dir)
      # restore/2, not put_env/3: these were unset before most tests here
      # (only mix.exs' real deploy sets config_path/storage_dir), and
      # put_env(key, nil) would leave them explicitly nil rather than
      # absent — Storage.dir/1's own default only applies when the key is
      # missing entirely, so a stray nil here breaks every later test.
      restore(:foxbus, :config_path, old_config_path)
      restore(:nest_gen2, :storage_dir, old_storage_dir)
      restore(:foxbus, :stops, old_stops)
      restore(:foxbus, :lines, old_lines)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp old_file_path,
    do: Path.join(@tmp_dir, "foxbus_config_test_#{System.unique_integer([:positive])}.exs")

  defp stop(key, title, stop_id, lines \\ []),
    do: %{key: key, provider: :carousel, stop_id: stop_id, title: title, lines: lines}

  test "falls back to mix.exs' env when Storage has nothing" do
    Application.put_env(:foxbus, :stops, [stop(:a, "A", "1")])

    assert Foxbus.Config.stops() == [stop(:a, "A", "1")]
    assert Foxbus.Config.default_screen() == :splash
  end

  test "reads back whatever's in Storage" do
    NestGen2.Storage.put(:stops, [stop(:towards_a, "To A", "1"), stop(:towards_b, "To B", "2")],
      app: :foxbus
    )

    NestGen2.Storage.put(:default_screen, :towards_a, app: :foxbus)

    assert Foxbus.Config.default_screen() == :towards_a
    assert Foxbus.Config.stops() == [stop(:towards_a, "To A", "1"), stop(:towards_b, "To B", "2")]
  end

  test "a key Storage doesn't have still falls back to mix.exs' env" do
    Application.put_env(:foxbus, :stops, [stop(:a, "A", "1")])
    assert Foxbus.Config.stops() == [stop(:a, "A", "1")]
  end

  describe "migrate_from_file/0" do
    test "carries an old config.exs's values into Storage" do
      path = old_file_path()
      Application.put_env(:foxbus, :config_path, path)

      File.write!(path, """
      [
        lines: ["104", "105"],
        default_screen: :towards_a,
        stops: [{:towards_a, "1", "To A"}, {:towards_b, "2", "To B"}]
      ]
      """)

      Foxbus.Config.migrate_from_file()

      assert Foxbus.Config.lines() == ["104", "105"]
      assert Foxbus.Config.default_screen() == :towards_a
      assert Foxbus.Config.stops() == [{:towards_a, "1", "To A"}, {:towards_b, "2", "To B"}]

      File.rm(path)
    end

    test "never overwrites a value Storage already has" do
      path = old_file_path()
      Application.put_env(:foxbus, :config_path, path)
      NestGen2.Storage.put(:lines, ["1"], app: :foxbus)

      File.write!(path, "[lines: [\"104\", \"105\"]]")
      Foxbus.Config.migrate_from_file()

      assert Foxbus.Config.lines() == ["1"]

      File.rm(path)
    end

    test "a missing old file is a no-op" do
      Application.put_env(:foxbus, :config_path, old_file_path())
      assert Foxbus.Config.migrate_from_file() == :ok
    end

    test "a syntax error in the old file doesn't crash the migration" do
      path = old_file_path()
      Application.put_env(:foxbus, :config_path, path)
      File.write!(path, "this is not valid elixir [[[")

      assert Foxbus.Config.migrate_from_file() == :ok

      File.rm(path)
    end

    test "a file that doesn't evaluate to a keyword list is ignored" do
      path = old_file_path()
      Application.put_env(:foxbus, :config_path, path)
      File.write!(path, "\"just a string\"")

      assert Foxbus.Config.migrate_from_file() == :ok
      assert Foxbus.Config.stops() == Application.fetch_env!(:foxbus, :stops)

      File.rm(path)
    end
  end

  describe "migrate_legacy_stops/0" do
    test "turns old {key, stop_id, title} tuples into the new per-stop map shape" do
      NestGen2.Storage.put(
        :stops,
        [{:towards_a, "1", "To A"}, {:towards_b, "2", "To B"}],
        app: :foxbus
      )

      NestGen2.Storage.put(:lines, ["104", "105"], app: :foxbus)

      Foxbus.Config.migrate_legacy_stops()

      assert Foxbus.Config.stops() == [
               stop(:towards_a, "To A", "1", ["104", "105"]),
               stop(:towards_b, "To B", "2", ["104", "105"])
             ]
    end

    test "every migrated stop defaults to the carousel provider" do
      NestGen2.Storage.put(:stops, [{:a, "1", "A"}], app: :foxbus)
      Foxbus.Config.migrate_legacy_stops()

      assert [%{provider: :carousel}] = Foxbus.Config.stops()
    end

    test "a missing old global lines value migrates as an empty filter" do
      NestGen2.Storage.put(:stops, [{:a, "1", "A"}], app: :foxbus)
      Foxbus.Config.migrate_legacy_stops()

      assert [%{lines: []}] = Foxbus.Config.stops()
    end

    test "a no-op once stops is already the new map shape" do
      NestGen2.Storage.put(:stops, [stop(:a, "A", "1", ["999"])], app: :foxbus)
      Foxbus.Config.migrate_legacy_stops()

      assert Foxbus.Config.stops() == [stop(:a, "A", "1", ["999"])]
    end

    test "a no-op with nothing in Storage yet" do
      assert Foxbus.Config.migrate_legacy_stops() == :ok
    end
  end
end
