defmodule Foxbus.Adapters.Sources.TflProviderAppKeyTest do
  # Swaps TFL_APP_KEY and the Storage dir, both global, so not async — same
  # reasoning as Foxbus.ConfigTest.
  use ExUnit.Case, async: false
  alias Foxbus.Adapters.Sources.TflProvider

  @tmp_dir System.tmp_dir!()

  setup do
    storage_dir =
      Path.join(@tmp_dir, "tfl_app_key_test_storage_#{System.unique_integer([:positive])}")

    old_storage_dir = Application.get_env(:nest_gen2, :storage_dir)
    old_env = System.get_env("TFL_APP_KEY")

    Application.put_env(:nest_gen2, :storage_dir, storage_dir)

    on_exit(fn ->
      File.rm_rf(storage_dir)
      if old_storage_dir, do: Application.put_env(:nest_gen2, :storage_dir, old_storage_dir)

      if is_nil(old_env),
        do: System.delete_env("TFL_APP_KEY"),
        else: System.put_env("TFL_APP_KEY", old_env)
    end)

    :ok
  end

  test "TFL_APP_KEY wins when set and non-empty" do
    System.put_env("TFL_APP_KEY", "env-key")
    NestGen2.Storage.put(:tfl_app_key, "storage-key", app: :foxbus)

    assert TflProvider.app_key() == "env-key"
  end

  test "an empty TFL_APP_KEY counts as unset, falling back to Storage" do
    System.put_env("TFL_APP_KEY", "")
    NestGen2.Storage.put(:tfl_app_key, "storage-key", app: :foxbus)

    assert TflProvider.app_key() == "storage-key"
  end

  test "an unset TFL_APP_KEY falls back to Storage" do
    System.delete_env("TFL_APP_KEY")
    NestGen2.Storage.put(:tfl_app_key, "storage-key", app: :foxbus)

    assert TflProvider.app_key() == "storage-key"
  end

  test "neither set is nil (unauthenticated)" do
    System.delete_env("TFL_APP_KEY")
    assert TflProvider.app_key() == nil
  end
end
