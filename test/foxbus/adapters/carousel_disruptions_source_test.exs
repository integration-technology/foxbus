defmodule Foxbus.Adapters.Sources.CarouselDisruptionsSourceTest do
  use ExUnit.Case, async: true
  alias Foxbus.Adapters.Sources.CarouselDisruptionsSource

  @stop "040000001207"

  # Mirrors Carousel's real markup: one .disruption-item per notice, with the
  # affected routes tagged via data-name on a nested anchor, and an optional
  # "Affected stops" list (by ATCO code in the link's query string) — a
  # notice with no such list is treated as applying network-wide.
  defp page(notices) do
    items =
      Enum.map_join(notices, "\n", fn {names, stop_ids} ->
        links =
          Enum.map_join(names, "\n", fn name ->
            ~s(<a data-name="#{name}" data-type="line">#{name}</a>)
          end)

        stops =
          Enum.map_join(stop_ids, "\n", fn id ->
            ~s(<li><a class="stop-block" href="/explore?type=stop&id=#{id}&marker=x">Some Stop</a></li>)
          end)

        stops_block =
          if stop_ids == [],
            do: "",
            else:
              ~s(<ul class="c-disruption__affected-entities"><li>Affected stops:</li>#{stops}</ul>)

        ~s(<div class="disruption-item disruption-item--line">
             <h3 class="disruption-item__title">Some disruption</h3>
             <ul class="c-disruption__affected-entities"><li>#{links}</li></ul>
             #{stops_block}
           </div>)
      end)

    "<html><body><div class=\"disruptions-listing\">#{items}</div></body></html>"
  end

  test "true when a notice with no stop list tags one of the lines" do
    html = page([{["Flightline 102"], []}, {["105", "1A"], []}])
    assert CarouselDisruptionsSource.parse_html(html, ["105"], @stop)
  end

  test "true when a notice tags any line in a multi-line watch list" do
    html = page([{["32", "32A", "33"], []}])
    assert CarouselDisruptionsSource.parse_html(html, ["104", "105", "32A"], @stop)
  end

  test "false when no notice tags any watched line" do
    html = page([{["Flightline 102"], []}, {["32", "32A", "33"], []}])
    refute CarouselDisruptionsSource.parse_html(html, ["105"], @stop)
  end

  test "false with no notices at all" do
    refute CarouselDisruptionsSource.parse_html("<html><body></body></html>", ["105"], @stop)
  end

  test "false on unexpected markup, not a crash" do
    refute CarouselDisruptionsSource.parse_html(
             "<html><body>Site under maintenance</body></html>",
             ["105"],
             @stop
           )
  end

  test "an exact match only, not a substring" do
    html = page([{["1052"], []}, {["1A"], []}])
    refute CarouselDisruptionsSource.parse_html(html, ["105"], @stop)
  end

  test "false when the notice names affected stops and this stop isn't one of them" do
    html = page([{["105"], ["040000002201", "040000002202"]}])
    refute CarouselDisruptionsSource.parse_html(html, ["105"], @stop)
  end

  test "true when the notice names affected stops and this stop is one of them" do
    html = page([{["105"], [@stop, "040000002202"]}])
    assert CarouselDisruptionsSource.parse_html(html, ["105"], @stop)
  end

  test "falls through to a later matching notice that does apply to this stop" do
    html =
      page([
        {["105"], ["040000002201"]},
        {["105"], [@stop]}
      ])

    assert CarouselDisruptionsSource.parse_html(html, ["105"], @stop)
  end
end
