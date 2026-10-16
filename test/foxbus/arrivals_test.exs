defmodule Foxbus.ArrivalsTest do
  # Swaps the configured sink, so not async.
  use ExUnit.Case, async: false
  alias Foxbus.Domain.Arrival

  defmodule TestProvider do
    @behaviour Foxbus.Ports.Provider
    @impl true
    def id, do: :test
    @impl true
    def label, do: "Test"
    @impl true
    def disruptions?, do: false
    @impl true
    def closures?, do: false

    @impl true
    def fetch_arrivals("fail", _lines), do: {:error, :timeout}

    def fetch_arrivals("mixed", _lines) do
      {:ok,
       for {line, eta} <- [{"105", 30}, {"1", 3}, {"105", 12}, {"32A", 7}] do
         %Arrival{line: line, destination: "Mapleton", eta_minutes: eta, status: :live}
       end}
    end

    def fetch_arrivals(_id, _lines) do
      {:ok,
       for eta <- [30, 3, 12] do
         %Arrival{line: "105", destination: "Mapleton", eta_minutes: eta, status: :live}
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
    old = Application.get_env(:foxbus, :arrivals_sink)
    Application.put_env(:foxbus, :arrivals_sink, TestSink)

    on_exit(fn ->
      Application.put_env(:foxbus, :arrivals_sink, old)
    end)
  end

  test "fetches soonest first and publishes to the sink" do
    assert {:ok, arrivals} =
             Foxbus.Arrivals.fetch_and_publish(TestProvider, :mapleton, "000000000003", [])

    assert Enum.map(arrivals, & &1.eta_minutes) == [3, 12, 30]
    assert_received {:published, :mapleton, ^arrivals}
  end

  test "errors are returned and nothing is published" do
    assert {:error, :timeout} =
             Foxbus.Arrivals.fetch_and_publish(TestProvider, :mapleton, "fail", [])

    refute_received {:published, _, _}
  end

  test "filters out lines not in the given list" do
    assert {:ok, arrivals} = Foxbus.Arrivals.fetch(TestProvider, "mixed", ["105"])
    assert Enum.map(arrivals, & &1.line) == ["105", "105"]
  end

  test "a shared stop's several watched lines are shown together, interleaved by time" do
    assert {:ok, arrivals} = Foxbus.Arrivals.fetch(TestProvider, "mixed", ["1", "105"])
    assert Enum.map(arrivals, &{&1.line, &1.eta_minutes}) == [{"1", 3}, {"105", 12}, {"105", 30}]
  end

  test "an empty list of lines means no filtering at all" do
    assert {:ok, arrivals} = Foxbus.Arrivals.fetch(TestProvider, "mixed", [])
    assert length(arrivals) == 4
  end

  describe "filter_lines/2" do
    defp arrival(line), do: %Arrival{line: line, destination: "x", eta_minutes: 1, status: :live}

    test "keeps only arrivals on a watched line" do
      arrivals = [arrival("105"), arrival("1"), arrival("105")]

      assert Enum.map(Foxbus.Arrivals.filter_lines(arrivals, ["105"]), & &1.line) == [
               "105",
               "105"
             ]
    end

    test "an empty list of lines means show everything" do
      arrivals = [arrival("105"), arrival("1")]
      assert Foxbus.Arrivals.filter_lines(arrivals, []) == arrivals
    end
  end
end
