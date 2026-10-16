defmodule Foxbus.DisruptionsTest do
  # Swaps the configured sink, so not async.
  use ExUnit.Case, async: false

  defmodule TestProvider do
    @behaviour Foxbus.Ports.Provider
    @impl true
    def id, do: :test
    @impl true
    def label, do: "Test"
    @impl true
    def disruptions?, do: true
    @impl true
    def closures?, do: false
    @impl true
    def fetch_arrivals(_stop_id), do: {:ok, []}

    def disrupted?(["fail"], _stop_id), do: {:error, :timeout}
    def disrupted?(lines, _stop_id), do: {:ok, "105" in lines}
  end

  defmodule TestSink do
    @behaviour Foxbus.Ports.DisruptionsSink
    @impl true
    def publish_disruption(stop, disrupted?) do
      send(self(), {:published, stop, disrupted?})
      :ok
    end
  end

  setup do
    old = Application.get_env(:foxbus, :disruptions_sink)
    Application.put_env(:foxbus, :disruptions_sink, TestSink)

    on_exit(fn ->
      Application.put_env(:foxbus, :disruptions_sink, old)
    end)
  end

  test "checks and publishes" do
    assert {:ok, true} =
             Foxbus.Disruptions.check_and_publish(
               TestProvider,
               :towards_somewhere,
               ["105"],
               "atco"
             )

    assert_received {:published, :towards_somewhere, true}
  end

  test "true if any of several lines matches" do
    assert {:ok, true} =
             Foxbus.Disruptions.check_and_publish(
               TestProvider,
               :towards_somewhere,
               ["1", "105"],
               "atco"
             )

    assert_received {:published, :towards_somewhere, true}
  end

  test "false is published too" do
    assert {:ok, false} =
             Foxbus.Disruptions.check_and_publish(TestProvider, :towards_somewhere, ["1"], "atco")

    assert_received {:published, :towards_somewhere, false}
  end

  test "errors are returned and nothing is published" do
    assert {:error, :timeout} =
             Foxbus.Disruptions.check_and_publish(
               TestProvider,
               :towards_somewhere,
               ["fail"],
               "atco"
             )

    refute_received {:published, _, _}
  end
end
