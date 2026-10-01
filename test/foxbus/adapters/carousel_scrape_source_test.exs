defmodule Foxbus.Adapters.Sources.CarouselScrapeSourceTest do
  use ExUnit.Case, async: true
  alias Foxbus.Adapters.Sources.CarouselScrapeSource

  @now ~N[2026-09-30 14:50:00]

  # Mirrors Carousel's real markup: a hidden sr-only paragraph inside each
  # departure's link, alongside the visual divs.
  defp page(entries) do
    items =
      Enum.map_join(entries, "\n", fn text ->
        ~s(<li class="departure-board__item"><a href="/journey/123">
             <p class="sr-only">#{text}</p>
             <div class="single-visit__name">ignored</div>
           </a></li>)
      end)

    "<html><body><ol>#{items}</ol></body></html>"
  end

  test "a live departure in minutes gets a clock time from now" do
    html =
      page([
        "Service - 105. Destination - Chesham + Chartridg. Departure time - 26 mins. " <>
          "Departure 1 of 7. Live. Follow the link for a list of stops this journey stops at."
      ])

    assert [a] = CarouselScrapeSource.parse_html(html, @now)

    assert {a.line, a.destination, a.eta_minutes, a.status} ==
             {"105", "Chesham + Chartridg", 26, :live}

    assert a.scheduled_time == ~T[15:16:00]
  end

  test "a scheduled clock time gets minutes until it" do
    html =
      page([
        "Service - 1. Destination - High Wycombe. Departure time - 15:22. Departure 4 of 7. Scheduled."
      ])

    assert [a] = CarouselScrapeSource.parse_html(html, @now)
    assert {a.eta_minutes, a.scheduled_time, a.status} == {32, ~T[15:22:00], :scheduled}
  end

  test "an early-morning time late in the evening is tomorrow" do
    html =
      page([
        "Service - 105. Destination - Chesham. Departure time - 06:10. Departure 1 of 1. Scheduled."
      ])

    assert [a] = CarouselScrapeSource.parse_html(html, ~N[2026-09-30 23:30:00])
    assert a.eta_minutes == 400
  end

  test "keeps document order" do
    html =
      page([
        "Service - 105. Destination - Chesham. Departure time - 5 mins. Departure 1 of 2. Live.",
        "Service - 105. Destination - Chesham Broadway. Departure time - 40 mins. Departure 2 of 2. Scheduled."
      ])

    assert [5, 40] =
             @now
             |> then(&CarouselScrapeSource.parse_html(html, &1))
             |> Enum.map(& &1.eta_minutes)
  end

  test "no departures is an empty list (end of service)" do
    assert [] = CarouselScrapeSource.parse_html("<html><body><ol></ol></body></html>", @now)
  end

  test "unexpected markup is an empty list, not a crash" do
    assert [] =
             CarouselScrapeSource.parse_html(
               "<html><body>Site under maintenance</body></html>",
               @now
             )
  end

  describe "server_time/1 (Date header as a clock check)" do
    test "reads the RFC 1123 date as UTC" do
      headers = [{~c"date", ~c"Sun, 25 Oct 2026 01:00:05 GMT"}]
      assert CarouselScrapeSource.server_time(headers) == ~U[2026-10-25 01:00:05Z]
    end

    test "adds Age when a cache served the page" do
      headers = [{~c"Date", ~c"Thu, 01 Oct 2026 07:00:00 GMT"}, {~c"age", ~c"42"}]
      assert CarouselScrapeSource.server_time(headers) == ~U[2026-10-01 07:00:42Z]
    end

    test "nil when missing or unreadable" do
      assert CarouselScrapeSource.server_time([]) == nil
      assert CarouselScrapeSource.server_time([{~c"date", ~c"yesterday"}]) == nil

      assert CarouselScrapeSource.server_time([{~c"date", ~c"Thu, 31 Feb 2026 07:00:00 GMT"}]) ==
               nil
    end
  end
end
