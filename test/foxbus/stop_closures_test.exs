defmodule Foxbus.StopClosuresTest do
  # Swaps the configured adapters, so not async.
  use ExUnit.Case, async: false

  defmodule TestSource do
    @behaviour Foxbus.Ports.StopClosureSource
    @impl true
    def closure("fail"), do: {:error, :timeout}
    def closure("040000002201"), do: {:ok, "No buses today."}
    def closure(_atco_code), do: {:ok, nil}
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
    old =
      {Application.get_env(:foxbus, :stop_closure_source),
       Application.get_env(:foxbus, :stop_closure_sink)}

    Application.put_env(:foxbus, :stop_closure_source, TestSource)
    Application.put_env(:foxbus, :stop_closure_sink, TestSink)

    on_exit(fn ->
      Application.put_env(:foxbus, :stop_closure_source, elem(old, 0))
      Application.put_env(:foxbus, :stop_closure_sink, elem(old, 1))
    end)
  end

  test "checks and publishes an explanation" do
    assert {:ok, "No buses today."} =
             Foxbus.StopClosures.check_and_publish(:chesham, "040000002201")

    assert_received {:published, :chesham, "No buses today."}
  end

  test "nil is published too, when the stop is fine" do
    assert {:ok, nil} = Foxbus.StopClosures.check_and_publish(:chesham, "040000002202")
    assert_received {:published, :chesham, nil}
  end

  test "errors are returned and nothing is published" do
    assert {:error, :timeout} = Foxbus.StopClosures.check_and_publish(:chesham, "fail")
    refute_received {:published, _, _}
  end
end
