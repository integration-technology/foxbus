defmodule Foxbus.StopClosuresTest do
  # Swaps the configured sink, so not async.
  use ExUnit.Case, async: false

  defmodule TestProvider do
    @behaviour Foxbus.Ports.Provider
    @impl true
    def id, do: :test
    @impl true
    def label, do: "Test"
    @impl true
    def disruptions?, do: false
    @impl true
    def closures?, do: true
    @impl true
    def fetch_arrivals(_stop_id), do: {:ok, []}

    def closure("fail"), do: {:error, :timeout}
    def closure("000000000003"), do: {:ok, "No buses today."}
    def closure(_stop_id), do: {:ok, nil}
  end

  defmodule TestSink do
    @behaviour Foxbus.Ports.StopClosureSink
    @impl true
    def publish_closure(stop, explanation) do
      send(self(), {:published, stop, explanation})
      :ok
    end
  end

  setup do
    old = Application.get_env(:foxbus, :stop_closure_sink)
    Application.put_env(:foxbus, :stop_closure_sink, TestSink)

    on_exit(fn ->
      Application.put_env(:foxbus, :stop_closure_sink, old)
    end)
  end

  test "checks and publishes an explanation" do
    assert {:ok, "No buses today."} =
             Foxbus.StopClosures.check_and_publish(TestProvider, :mapleton, "000000000003")

    assert_received {:published, :mapleton, "No buses today."}
  end

  test "nil is published too, when the stop is fine" do
    assert {:ok, nil} =
             Foxbus.StopClosures.check_and_publish(TestProvider, :mapleton, "000000000004")

    assert_received {:published, :mapleton, nil}
  end

  test "errors are returned and nothing is published" do
    assert {:error, :timeout} =
             Foxbus.StopClosures.check_and_publish(TestProvider, :mapleton, "fail")

    refute_received {:published, _, _}
  end
end
