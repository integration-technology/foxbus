defmodule Foxbus.Adapters.Sources.CarouselProvider do
  @moduledoc """
  Bundles the three existing Carousel adapters (arrivals scrape, line
  disruptions, stop closure — each its own module, each independently
  tested) behind one `Foxbus.Ports.Provider`. Carousel is the one provider
  that stays hand-written/compiled rather than config-driven: an HTML
  scrape needs real parsing, not just field paths.
  """

  @behaviour Foxbus.Ports.Provider

  alias Foxbus.Adapters.Sources.{
    CarouselDisruptionsSource,
    CarouselScrapeSource,
    CarouselStopClosureSource
  }

  @impl true
  def id, do: :carousel

  @impl true
  def label, do: "Carousel Buses"

  # `lines` is unused — Carousel's board scrape returns every line at the
  # stop in one page fetch; filtering down to the watched ones happens
  # afterward, in Foxbus.Arrivals.
  @impl true
  def fetch_arrivals(stop_id, _lines), do: CarouselScrapeSource.fetch_arrivals(stop_id)

  @impl true
  def disruptions?, do: true

  @impl true
  def closures?, do: true

  @doc "See `Foxbus.Ports.DisruptionsSource` — present because disruptions?/0 is true."
  @spec disrupted?([String.t()], String.t()) :: {:ok, String.t() | nil} | {:error, term}
  def disrupted?(lines, stop_id), do: CarouselDisruptionsSource.disrupted?(lines, stop_id)

  @doc "See `Foxbus.Ports.StopClosureSource` — present because closures?/0 is true."
  @spec closure(String.t()) :: {:ok, String.t() | nil} | {:error, term}
  def closure(stop_id), do: CarouselStopClosureSource.closure(stop_id)
end
