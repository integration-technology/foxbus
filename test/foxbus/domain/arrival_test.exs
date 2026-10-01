defmodule Foxbus.Domain.ArrivalTest do
  use ExUnit.Case, async: true
  alias Foxbus.Domain.Arrival

  defp arrival(eta, scheduled \\ nil),
    do: %Arrival{
      line: "105",
      destination: "Chesham",
      eta_minutes: eta,
      status: :live,
      scheduled_time: scheduled
    }

  describe "eta_text/1" do
    test "counts down at 10 minutes or less" do
      assert Arrival.eta_text(arrival(0, ~T[10:00:00])) == "0 min"
      assert Arrival.eta_text(arrival(10, ~T[10:10:00])) == "10 min"
    end

    test "shows the clock time beyond 10 minutes" do
      assert Arrival.eta_text(arrival(11, ~T[15:22:00])) == "at 15:22"
      assert Arrival.eta_text(arrival(90, ~T[09:05:00])) == "at 09:05"
    end

    test "falls back to minutes when there is no clock time" do
      assert Arrival.eta_text(arrival(25)) == "25 min"
    end
  end

  test "sort_by_eta puts the soonest first" do
    assert [5, 12, 40] =
             [arrival(40), arrival(5), arrival(12)]
             |> Arrival.sort_by_eta()
             |> Enum.map(& &1.eta_minutes)
  end
end
