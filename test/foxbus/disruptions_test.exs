defmodule Foxbus.DisruptionsTest do
  # Swaps the configured adapters, so not async.
  use ExUnit.Case, async: false

  defmodule TestSource do
    @behaviour Foxbus.Ports.DisruptionsSource
    @impl true
    def disrupted?(["fail"]), do: {:error, :timeout}
    def disrupted?(lines), do: {:ok, "105" in lines}
  end

  defmodule TestSink do
    @behaviour Foxbus.Ports.DisruptionsSink
    @impl true
    def publish(disrupted?) do
      send(self(), {:published, disrupted?})
      :ok
    end
  end

  setup do
    old =
      {Application.get_env(:foxbus, :disruptions_source),
       Application.get_env(:foxbus, :disruptions_sink)}

    Application.put_env(:foxbus, :disruptions_source, TestSource)
    Application.put_env(:foxbus, :disruptions_sink, TestSink)

    on_exit(fn ->
      Application.put_env(:foxbus, :disruptions_source, elem(old, 0))
      Application.put_env(:foxbus, :disruptions_sink, elem(old, 1))
    end)
  end

  test "checks and publishes" do
    assert {:ok, true} = Foxbus.Disruptions.check_and_publish(["105"])
    assert_received {:published, true}
  end

  test "true if any of several lines matches" do
    assert {:ok, true} = Foxbus.Disruptions.check_and_publish(["1", "105"])
    assert_received {:published, true}
  end

  test "false is published too" do
    assert {:ok, false} = Foxbus.Disruptions.check_and_publish(["1"])
    assert_received {:published, false}
  end

  test "errors are returned and nothing is published" do
    assert {:error, :timeout} = Foxbus.Disruptions.check_and_publish(["fail"])
    refute_received {:published, _}
  end
end
