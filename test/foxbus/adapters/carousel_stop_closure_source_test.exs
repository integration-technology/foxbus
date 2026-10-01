defmodule Foxbus.Adapters.Sources.CarouselStopClosureSourceTest do
  use ExUnit.Case, async: true
  alias Foxbus.Adapters.Sources.CarouselStopClosureSource

  # Mirrors Carousel's real markup: affected stops are a separate <ul> from
  # affected routes, with the ATCO code only in the stop link's query string.
  defp page(notices) do
    items =
      Enum.map_join(notices, "\n", fn {stop_ids, explanation} ->
        stops =
          Enum.map_join(stop_ids, "\n", fn id ->
            ~s(<li><a class="stop-block" href="/explore?type=stop&id=#{id}&marker=x">Some Stop</a></li>)
          end)

        ~s(<div class="disruption-item disruption-item--line">
             <h3 class="disruption-item__title">Some disruption</h3>
             <p class="disruption-item__meta">Today 12:00 - 1st Jan 2027</p>
             <ul class="c-disruption__affected-entities"><li>Affected stops:</li>#{stops}</ul>
             <p>#{explanation}</p>
           </div>)
      end)

    "<html><body><div class=\"disruptions-listing\">#{items}</div></body></html>"
  end

  test "returns the explanation when the stop is in the affected list" do
    html = page([{["040000002201", "040000002202"], "No service due to a road closure."}])

    assert CarouselStopClosureSource.parse_html(html, "040000002201") ==
             "No service due to a road closure."
  end

  test "nil when the stop isn't in any notice" do
    html = page([{["040000002204"], "Diversion in place."}])
    assert CarouselStopClosureSource.parse_html(html, "040000002201") == nil
  end

  test "nil with no notices at all" do
    assert CarouselStopClosureSource.parse_html("<html><body></body></html>", "040000002201") ==
             nil
  end

  test "nil on unexpected markup, not a crash" do
    assert CarouselStopClosureSource.parse_html(
             "<html><body>Site under maintenance</body></html>",
             "040000002201"
           ) == nil
  end

  test "an exact match only, not a substring" do
    html = page([{["040000002201X"], "Diversion in place."}])
    assert CarouselStopClosureSource.parse_html(html, "040000002201") == nil
  end

  test "the first matching notice wins when a stop appears in more than one" do
    html =
      page([
        {["040000002201"], "First notice."},
        {["040000002201"], "Second notice."}
      ])

    assert CarouselStopClosureSource.parse_html(html, "040000002201") == "First notice."
  end
end
