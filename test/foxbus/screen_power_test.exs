defmodule Foxbus.ScreenPowerTest do
  # Swaps the configured file path, so not async — same pattern as
  # Foxbus.ConfigTest.
  use ExUnit.Case, async: false

  alias Foxbus.ScreenPower

  @tmp_dir System.tmp_dir!()

  setup do
    path =
      Path.join(@tmp_dir, "foxbus_screen_power_test_#{System.unique_integer([:positive])}.exs")

    old_path = Application.get_env(:foxbus, :screen_power_path)
    Application.put_env(:foxbus, :screen_power_path, path)

    on_exit(fn ->
      File.rm(path)
      Application.put_env(:foxbus, :screen_power_path, old_path)
    end)

    %{path: path}
  end

  describe "load/0" do
    test "the SDK's own defaults when no file exists yet" do
      assert ScreenPower.load() == %{idle_timeout_ms: 30_000, wake_on_approach?: true}
    end

    test "the saved choice when the file is present", %{path: path} do
      File.write!(path, "[idle_timeout_ms: 300_000, wake_on_approach?: false]")

      assert ScreenPower.load() == %{idle_timeout_ms: 300_000, wake_on_approach?: false}
    end

    test "always on is saved as :infinity", %{path: path} do
      File.write!(path, "[idle_timeout_ms: :infinity, wake_on_approach?: true]")

      assert ScreenPower.load() == %{idle_timeout_ms: :infinity, wake_on_approach?: true}
    end

    test "a key the file doesn't set falls back to the default", %{path: path} do
      File.write!(path, "[wake_on_approach?: false]")

      assert ScreenPower.load() == %{idle_timeout_ms: 30_000, wake_on_approach?: false}
    end

    test "a syntax error in the file doesn't crash the lookup", %{path: path} do
      File.write!(path, "this is not valid elixir [[[")

      assert ScreenPower.load() == %{idle_timeout_ms: 30_000, wake_on_approach?: true}
    end

    test "a file that doesn't evaluate to a keyword list is ignored", %{path: path} do
      File.write!(path, "\"just a string\"")

      assert ScreenPower.load() == %{idle_timeout_ms: 30_000, wake_on_approach?: true}
    end
  end

  describe "save/1" do
    test "writes the choice so a later load/0 reads it back", %{path: path} do
      # Not apply/1 — that also calls NestGen2.Power, not running under
      # `mix test --no-start`.
      ScreenPower.save(%{idle_timeout_ms: 60_000, wake_on_approach?: false})

      assert File.exists?(path)
      assert ScreenPower.load() == %{idle_timeout_ms: 60_000, wake_on_approach?: false}
    end
  end
end
