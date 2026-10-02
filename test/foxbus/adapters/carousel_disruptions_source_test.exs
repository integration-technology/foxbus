defmodule Foxbus.Adapters.Sources.CarouselDisruptionsSourceTest do
  use ExUnit.Case, async: true
  alias Foxbus.Adapters.Sources.CarouselDisruptionsSource

  # Mirrors Carousel's real markup: one .disruption-item per notice, with the
  # affected routes tagged via data-name on a nested anchor.
  defp page(notices) do
    items =
      Enum.map_join(notices, "\n", fn names ->
        links =
          Enum.map_join(names, "\n", fn name ->
            ~s(<a data-name="#{name}" data-type="line">#{name}</a>)
          end)

        ~s(<div class="disruption-item disruption-item--line">
             <h3 class="disruption-item__title">Some disruption</h3>
             <ul class="c-disruption__affected-entities"><li>#{links}</li></ul>
           </div>)
      end)

    "<html><body><div class=\"disruptions-listing\">#{items}</div></body></html>"
  end

  test "true when a notice tags one of the lines" do
    html = page([["Flightline 102"], ["105", "1A"]])
    assert CarouselDisruptionsSource.parse_html(html, ["105"])
  end

  test "true when a notice tags any line in a multi-line watch list" do
    html = page([["32", "32A", "33"]])
    assert CarouselDisruptionsSource.parse_html(html, ["104", "105", "32A"])
  end

  test "false when no notice tags any watched line" do
    html = page([["Flightline 102"], ["32", "32A", "33"]])
    refute CarouselDisruptionsSource.parse_html(html, ["105"])
  end

  test "false with no notices at all" do
    refute CarouselDisruptionsSource.parse_html("<html><body></body></html>", ["105"])
  end

  test "false on unexpected markup, not a crash" do
    refute CarouselDisruptionsSource.parse_html(
             "<html><body>Site under maintenance</body></html>",
             ["105"]
           )
  end

  test "an exact match only, not a substring" do
    html = page([["1052"], ["1A"]])
    refute CarouselDisruptionsSource.parse_html(html, ["105"])
  end
end
