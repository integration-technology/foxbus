defmodule Foxbus.ArrivalsTest do
  # Swaps the configured adapters, so not async.
  use ExUnit.Case, async: false
  alias Foxbus.Domain.Arrival

  defmodule TestSource do
    @behaviour Foxbus.Ports.ArrivalsSource
    @impl true
    def fetch_arrivals("fail"), do: {:error, :timeout}

    def fetch_arrivals("mixed") do
      {:ok,
       for {line, eta} <- [{"105", 30}, {"1", 3}, {"105", 12}, {"32A", 7}] do
         %Arrival{line: line, destination: "Chesham", eta_minutes: eta, status: :live}
       end}
    end

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
       Application.get_env(:foxbus, :arrivals_sink), Application.get_env(:foxbus, :lines)}

    Application.put_env(:foxbus, :arrivals_source, TestSource)
    Application.put_env(:foxbus, :arrivals_sink, TestSink)

    on_exit(fn ->
      Application.put_env(:foxbus, :arrivals_source, elem(old, 0))
      Application.put_env(:foxbus, :arrivals_sink, elem(old, 1))
      Application.put_env(:foxbus, :lines, elem(old, 2))
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

  test "filters out lines not in the configured list" do
    Application.put_env(:foxbus, :lines, ["105"])
    assert {:ok, arrivals} = Foxbus.Arrivals.fetch("mixed")
    assert Enum.map(arrivals, & &1.line) == ["105", "105"]
  end

  test "a shared stop's several watched lines are shown together, interleaved by time" do
    Application.put_env(:foxbus, :lines, ["1", "105"])
    assert {:ok, arrivals} = Foxbus.Arrivals.fetch("mixed")
    assert Enum.map(arrivals, &{&1.line, &1.eta_minutes}) == [{"1", 3}, {"105", 12}, {"105", 30}]
  end

  test "an empty configured list means no filtering at all" do
    Application.put_env(:foxbus, :lines, [])
    assert {:ok, arrivals} = Foxbus.Arrivals.fetch("mixed")
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
