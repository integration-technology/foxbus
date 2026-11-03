defmodule Foxbus.Adapters.Sources.CarouselCache do
  @moduledoc """
  A short-lived cache for `Foxbus.Adapters.Sources.CarouselHttp.get/1`, keyed
  by URL. Carousel's `/service-updates` page is fetched independently by
  every stop's own disruption and stop-closure poller (see
  `Foxbus.Application`) even though they all read the exact same page — with
  two Carousel stops that's the same ~130 KB page downloaded and Floki-parsed
  up to four times every 5 minutes, for no reason, competing with the two
  stops' own bus-board fetches for the Nest's single core. Confirmed live
  (2026-11-03): with six stops the Nest ran out of memory and Carousel
  requests started timing out under that load.

  `@ttl_ms` (90 s) sits comfortably under every Carousel poller's own 5-minute
  interval (`StopClosurePoller`, `DisruptionPoller`), so even pollers whose
  staggered start times have drifted apart usually still land within one
  window of each other at some point in their cycle — the cost is service
  notices being up to `@ttl_ms` more stale, which barely matters for text
  that's normally posted hours or days ahead of the disruption it describes.
  Only a successful fetch is cached — a timeout or error is never stored, so
  one failing request doesn't poison every stop for the TTL.
  """
  use GenServer

  @ttl_ms 90_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Runs `fun` for `url`, unless a fetch for it already succeeded within the last #{@ttl_ms}ms."
  @spec fetch(String.t(), (-> {:ok, term} | {:error, term})) :: {:ok, term} | {:error, term}
  def fetch(url, fun) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(__MODULE__, url) do
      [{^url, result, at}] when now - at < @ttl_ms -> result
      _ -> refresh(url, fun, now)
    end
  end

  defp refresh(url, fun, now) do
    case fun.() do
      {:ok, _} = result ->
        :ets.insert(__MODULE__, {url, result, now})
        result

      error ->
        error
    end
  end

  @impl true
  def init(nil) do
    :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
