defmodule Foxbus.Adapters.Sources.CarouselProviderTest do
  use ExUnit.Case, async: true
  alias Foxbus.Adapters.Sources.CarouselProvider

  # fetch_arrivals/1, disrupted?/2 and closure/1 are one-line delegations to
  # CarouselScrapeSource/CarouselDisruptionsSource/CarouselStopClosureSource,
  # each of which makes a real HTTP call — not exercised here, same as those
  # modules' own tests, which only cover their pure parse_html/2 functions.

  test "id/0 and label/0" do
    assert CarouselProvider.id() == :carousel
    assert CarouselProvider.label() == "Carousel Buses"
  end

  test "declares both optional capabilities" do
    assert CarouselProvider.disruptions?()
    assert CarouselProvider.closures?()
  end
end
