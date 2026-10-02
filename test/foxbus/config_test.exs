defmodule Foxbus.ConfigTest do
  # Swaps the configured file path, so not async.
  use ExUnit.Case, async: false

  @tmp_dir System.tmp_dir!()

  setup do
    path = Path.join(@tmp_dir, "foxbus_config_test_#{System.unique_integer([:positive])}.exs")
    old_path = Application.get_env(:foxbus, :config_path)
    old_stops = Application.get_env(:foxbus, :stops)
    old_line = Application.get_env(:foxbus, :disruptions_line)

    Application.put_env(:foxbus, :config_path, path)

    on_exit(fn ->
      File.rm(path)
      Application.put_env(:foxbus, :config_path, old_path)
      Application.put_env(:foxbus, :stops, old_stops)
      Application.put_env(:foxbus, :disruptions_line, old_line)
    end)

    %{path: path}
  end

  test "falls back to mix.exs' env when no file exists" do
    Application.put_env(:foxbus, :stops, [{:a, "1", "A"}])
    Application.put_env(:foxbus, :disruptions_line, "105")

    assert Foxbus.Config.stops() == [{:a, "1", "A"}]
    assert Foxbus.Config.disruptions_line() == "105"
    assert Foxbus.Config.default_screen() == :splash
  end

  test "overrides from the file when present", %{path: path} do
    File.write!(path, """
    [
      disruptions_line: "104",
      default_screen: :towards_a,
      stops: [{:towards_a, "1", "To A"}, {:towards_b, "2", "To B"}]
    ]
    """)

    assert Foxbus.Config.disruptions_line() == "104"
    assert Foxbus.Config.default_screen() == :towards_a
    assert Foxbus.Config.stops() == [{:towards_a, "1", "To A"}, {:towards_b, "2", "To B"}]
  end

  test "a key the file doesn't set still falls back to mix.exs' env", %{path: path} do
    Application.put_env(:foxbus, :disruptions_line, "105")
    File.write!(path, "[stops: [{:a, \"1\", \"A\"}]]")

    assert Foxbus.Config.stops() == [{:a, "1", "A"}]
    assert Foxbus.Config.disruptions_line() == "105"
  end

  test "a syntax error in the file doesn't crash config lookups", %{path: path} do
    Application.put_env(:foxbus, :stops, [{:a, "1", "A"}])
    File.write!(path, "this is not valid elixir [[[")

    assert Foxbus.Config.stops() == [{:a, "1", "A"}]
  end

  test "a file that doesn't evaluate to a keyword list is ignored", %{path: path} do
    Application.put_env(:foxbus, :stops, [{:a, "1", "A"}])
    File.write!(path, "\"just a string\"")

    assert Foxbus.Config.stops() == [{:a, "1", "A"}]
  end
end
