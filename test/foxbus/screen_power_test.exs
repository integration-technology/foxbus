defmodule Foxbus.ScreenPowerTest do
  # Swaps the configured Storage dir and the old screen_power_path, so not
  # async — same pattern as Foxbus.ConfigTest.
  use ExUnit.Case, async: false

  alias Foxbus.ScreenPower

  @tmp_dir System.tmp_dir!()

  setup do
    storage_dir =
      Path.join(
        @tmp_dir,
        "foxbus_screen_power_test_storage_#{System.unique_integer([:positive])}"
      )

    old_path = Application.get_env(:foxbus, :screen_power_path)
    old_storage_dir = Application.get_env(:nest_gen2, :storage_dir)
    Application.put_env(:nest_gen2, :storage_dir, storage_dir)

    on_exit(fn ->
      File.rm_rf(storage_dir)
      # restore/2, not put_env/3: see Foxbus.ConfigTest for why a stray
      # explicit nil here (vs. the key being absent) would break every
      # later test's Storage.dir/1 default.
      restore(:foxbus, :screen_power_path, old_path)
      restore(:nest_gen2, :storage_dir, old_storage_dir)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp old_file_path,
    do:
      Path.join(
        @tmp_dir,
        "foxbus_screen_power_migrate_test_#{System.unique_integer([:positive])}.exs"
      )

  describe "load/0" do
    test "the SDK's own defaults when Storage has nothing yet" do
      assert ScreenPower.load() == %{idle_timeout_ms: 30_000, wake_on_approach?: true}
    end

    test "the saved choice when Storage has one" do
      ScreenPower.save(%{idle_timeout_ms: 300_000, wake_on_approach?: false})

      assert ScreenPower.load() == %{idle_timeout_ms: 300_000, wake_on_approach?: false}
    end

    test "always on round-trips as :infinity" do
      ScreenPower.save(%{idle_timeout_ms: :infinity, wake_on_approach?: true})

      assert ScreenPower.load() == %{idle_timeout_ms: :infinity, wake_on_approach?: true}
    end
  end

  describe "save/1" do
    test "writes the choice so a later load/0 reads it back" do
      # Not apply/1 — that also calls NestGen2.Power, not running under
      # `mix test --no-start`.
      ScreenPower.save(%{idle_timeout_ms: 60_000, wake_on_approach?: false})

      assert ScreenPower.load() == %{idle_timeout_ms: 60_000, wake_on_approach?: false}
    end
  end

  describe "migrate_from_file/0" do
    test "carries an old screen_power.exs's choice into Storage" do
      path = old_file_path()
      Application.put_env(:foxbus, :screen_power_path, path)
      File.write!(path, "[idle_timeout_ms: 300_000, wake_on_approach?: false]")

      ScreenPower.migrate_from_file()

      assert ScreenPower.load() == %{idle_timeout_ms: 300_000, wake_on_approach?: false}

      File.rm(path)
    end

    test "a key the old file doesn't set falls back to the default" do
      path = old_file_path()
      Application.put_env(:foxbus, :screen_power_path, path)
      File.write!(path, "[wake_on_approach?: false]")

      ScreenPower.migrate_from_file()

      assert ScreenPower.load() == %{idle_timeout_ms: 30_000, wake_on_approach?: false}

      File.rm(path)
    end

    test "never overwrites a choice Storage already has" do
      path = old_file_path()
      Application.put_env(:foxbus, :screen_power_path, path)
      ScreenPower.save(%{idle_timeout_ms: 60_000, wake_on_approach?: false})

      File.write!(path, "[idle_timeout_ms: 300_000, wake_on_approach?: true]")
      ScreenPower.migrate_from_file()

      assert ScreenPower.load() == %{idle_timeout_ms: 60_000, wake_on_approach?: false}

      File.rm(path)
    end

    test "a missing old file is a no-op" do
      Application.put_env(:foxbus, :screen_power_path, old_file_path())
      assert ScreenPower.migrate_from_file() == :ok
      assert ScreenPower.load() == %{idle_timeout_ms: 30_000, wake_on_approach?: true}
    end

    test "a syntax error in the old file doesn't crash the migration" do
      path = old_file_path()
      Application.put_env(:foxbus, :screen_power_path, path)
      File.write!(path, "this is not valid elixir [[[")

      assert ScreenPower.migrate_from_file() == :ok
      assert ScreenPower.load() == %{idle_timeout_ms: 30_000, wake_on_approach?: true}

      File.rm(path)
    end

    test "a file that doesn't evaluate to a keyword list is ignored" do
      path = old_file_path()
      Application.put_env(:foxbus, :screen_power_path, path)
      File.write!(path, "\"just a string\"")

      assert ScreenPower.migrate_from_file() == :ok
      assert ScreenPower.load() == %{idle_timeout_ms: 30_000, wake_on_approach?: true}

      File.rm(path)
    end
  end
end
