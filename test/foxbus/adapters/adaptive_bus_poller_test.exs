defmodule Foxbus.Adapters.Schedulers.AdaptiveBusPollerTest do
  use ExUnit.Case, async: true
  alias Foxbus.Adapters.Schedulers.AdaptiveBusPoller
  alias Foxbus.Domain.Arrival

  defp arrival(eta),
    do: %Arrival{line: "105", destination: "Chesham", eta_minutes: eta, status: :live}

  test "polls every minute normally" do
    assert AdaptiveBusPoller.next_delay({:ok, [arrival(6)]}) == 60_000
  end

  test "tightens to 30 s when the next bus is 5 minutes away or less" do
    assert AdaptiveBusPoller.next_delay({:ok, [arrival(5), arrival(20)]}) == 30_000
  end

  test "backs off to 30 minutes when there are no buses" do
    assert AdaptiveBusPoller.next_delay({:ok, []}) == 30 * 60_000
  end

  test "retries after a minute on errors" do
    assert AdaptiveBusPoller.next_delay({:error, :timeout}) == 60_000
  end
end
