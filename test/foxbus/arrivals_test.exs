defmodule Foxbus.ArrivalsTest do
  # Swaps the configured adapters, so not async.
  use ExUnit.Case, async: false
  alias Foxbus.Domain.Arrival

  defmodule TestSource do
    @behaviour Foxbus.Ports.ArrivalsSource
    @impl true
    def fetch_arrivals("fail"), do: {:error, :timeout}

    def fetch_arrivals(_id) do
      {:ok,
       for eta <- [30, 3, 12] do
         %Arrival{line: "105", destination: "Chesham", eta_minutes: eta, status: :live}
       end}
    end
  end

  defmodule TestSink do
    @behaviour Foxbus.Ports.ArrivalsSink
    @impl true
    def publish(stop, arrivals) do
      send(self(), {:published, stop, arrivals})
      :ok
    end
  end

  setup do
    old =
      {Application.get_env(:foxbus, :arrivals_source),
       Application.get_env(:foxbus, :arrivals_sink)}

    Application.put_env(:foxbus, :arrivals_source, TestSource)
    Application.put_env(:foxbus, :arrivals_sink, TestSink)

    on_exit(fn ->
      Application.put_env(:foxbus, :arrivals_source, elem(old, 0))
      Application.put_env(:foxbus, :arrivals_sink, elem(old, 1))
    end)
  end

  test "fetches soonest first and publishes to the sink" do
    assert {:ok, arrivals} = Foxbus.Arrivals.fetch_and_publish(:chesham, "040000002201")
    assert Enum.map(arrivals, & &1.eta_minutes) == [3, 12, 30]
    assert_received {:published, :chesham, ^arrivals}
  end

  test "errors are returned and nothing is published" do
    assert {:error, :timeout} = Foxbus.Arrivals.fetch_and_publish(:chesham, "fail")
    refute_received {:published, _, _}
  end
end
