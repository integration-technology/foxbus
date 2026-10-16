defmodule Foxbus.Adapters.Schedulers.AdaptiveBusPollerTest do
  use ExUnit.Case, async: true
  alias Foxbus.Adapters.Schedulers.AdaptiveBusPoller
  alias Foxbus.Domain.Arrival

  defp arrival(eta),
    do: %Arrival{line: "105", destination: "Mapleton", eta_minutes: eta, status: :live}

  test "polls every minute normally" do
    assert AdaptiveBusPoller.next_delay({:ok, [arrival(6)]}, true) == 60_000
  end

  test "tightens to 30 s when the next bus is 5 minutes away or less" do
    assert AdaptiveBusPoller.next_delay({:ok, [arrival(5), arrival(20)]}, true) == 30_000
  end

  test "backs off to 30 minutes when there are no buses" do
    assert AdaptiveBusPoller.next_delay({:ok, []}, true) == 30 * 60_000
  end

  test "retries after a minute on errors, once it's succeeded before" do
    assert AdaptiveBusPoller.next_delay({:error, :timeout}, true) == 60_000
  end

  test "retries after 10 s on an error before the first ever success" do
    assert AdaptiveBusPoller.next_delay({:error, :timeout}, false) == 10_000
  end

  test "a success tightens the interval even before any prior success" do
    assert AdaptiveBusPoller.next_delay({:ok, [arrival(6)]}, false) == 60_000
  end
end
