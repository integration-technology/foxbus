defmodule Foxbus.Adapters.Schedulers.AdaptiveBusPollerTest do
  use ExUnit.Case, async: true
  alias Foxbus.Adapters.Schedulers.AdaptiveBusPoller
  alias Foxbus.Domain.Arrival

  defp arrival(eta),
    do: %Arrival{line: "105", destination: "Mapleton", eta_minutes: eta, status: :live}

  test "polls every minute normally" do
    assert AdaptiveBusPoller.next_delay({:ok, [arrival(6)]}, 0) == 60_000
  end

  test "tightens to 30 s when the next bus is 5 minutes away or less" do
    assert AdaptiveBusPoller.next_delay({:ok, [arrival(5), arrival(20)]}, 0) == 30_000
  end

  test "backs off to 30 minutes when there are no buses" do
    assert AdaptiveBusPoller.next_delay({:ok, []}, 0) == 30 * 60_000
  end

  test "a success tightens the interval regardless of the failure count it reset" do
    assert AdaptiveBusPoller.next_delay({:ok, [arrival(6)]}, 0) == 60_000
  end

  describe "clock_set?/1" do
    test "a cold boot's unset 2000-01-01 clock isn't sane" do
      refute AdaptiveBusPoller.clock_set?(~U[2000-01-01 00:01:16Z])
    end

    test "today's date is sane" do
      assert AdaptiveBusPoller.clock_set?(~U[2026-10-28 12:00:00Z])
    end
  end

  describe "backoff on consecutive failures" do
    test "the first failure retries after 10 s" do
      assert AdaptiveBusPoller.next_delay({:error, :timeout}, 1) == 10_000
    end

    test "the second consecutive failure retries after 30 s" do
      assert AdaptiveBusPoller.next_delay({:error, :timeout}, 2) == 30_000
    end

    test "the third and later consecutive failures fall back to the normal 60 s cadence" do
      assert AdaptiveBusPoller.next_delay({:error, :timeout}, 3) == 60_000
      assert AdaptiveBusPoller.next_delay({:error, :timeout}, 50) == 60_000
    end
  end
end
