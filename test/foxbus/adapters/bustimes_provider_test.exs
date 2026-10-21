defmodule Foxbus.Adapters.Sources.BustimesProviderTest do
  use ExUnit.Case, async: true
  alias Foxbus.Adapters.Sources.BustimesProvider

  @now ~N[2026-10-21 15:42:00]

  # Shaped like the real /stops/<id>/departures fragment (confirmed live
  # against bustimes.org for Murthly, at Primary School) — one three-cell
  # row per departure: the service number (linked), the destination, and
  # the scheduled time (linked to the trip page).
  defp row(line, destination, time) do
    ~s(<tr>
         <td class="nowrap"><a href="/services/x">#{line}</a></td>
         <td>
         #{destination}
         </td>
         <td><a href="/trips/1">
         #{time}
         </a>
         </td>
       </tr>)
  end

  # Shaped like the real 4-column fragment (confirmed live, 21 Oct): once
  # any vehicle on the page is tracked, every row gets a fourth cell for
  # "Expected" — filled for the tracked row, empty for the rest — and the
  # tracked row's destination cell nests a vehicle div alongside the
  # destination text.
  defp live_row(line, destination, scheduled, expected, vehicle \\ nil) do
    vehicle_html =
      if vehicle,
        do: ~s(<div class="vehicle"><a href="/vehicles/x">#{vehicle}</a></div>),
        else: ""

    ~s(<tr>
         <td class="nowrap"><a href="/services/x">#{line}</a></td>
         <td>
         #{destination}
         #{vehicle_html}
         </td>
         <td><a href="/journeys/1">
         #{scheduled}
         </a>
         </td>
         <td>#{if expected, do: ~s(<a href="/journeys/1">\n#{expected}\n</a>), else: ""}</td>
       </tr>)
  end

  defp page(rows), do: "<table><tbody>#{Enum.join(rows)}</tbody></table>"

  test "a scheduled departure later today" do
    html = page([row("34", "Spittalfield", "16:25")])
    assert [a] = BustimesProvider.parse_html(html, @now)

    assert {a.line, a.destination, a.eta_minutes, a.status} ==
             {"34", "Spittalfield", 43, :scheduled}

    assert a.scheduled_time == ~T[16:25:00]
    assert a.day == :today
  end

  test "several rows, soonest not necessarily first — order is left to the caller" do
    html = page([row("34", "Dunkeld", "19:04"), row("34A", "Spittalfield", "19:32")])
    assert [a1, a2] = BustimesProvider.parse_html(html, @now)
    assert {a1.line, a1.destination} == {"34", "Dunkeld"}
    assert {a2.line, a2.destination} == {"34A", "Spittalfield"}
  end

  test "an early-morning time late in the evening is tomorrow" do
    html = page([row("34", "Perth", "06:10")])
    assert [a] = BustimesProvider.parse_html(html, ~N[2026-10-21 23:30:00])
    assert a.day == :tomorrow
    assert a.eta_minutes == 400
  end

  describe "a tracked vehicle adds a fourth 'Expected' column" do
    test "a four-cell table with no tracked rows still parses (confirmed live: Perth-bound " <>
           "Murthly stop at the same moment had a 3-cell table)" do
      html =
        page([
          live_row("34", "Spittalfield", "16:25", nil),
          live_row("34", "Dunkeld", "19:04", nil)
        ])

      assert [a1, a2] = BustimesProvider.parse_html(html, @now)
      assert {a1.status, a1.eta_minutes} == {:scheduled, 43}
      assert {a2.status, a2.destination} == {:scheduled, "Dunkeld"}
    end

    test "a tracked row's expected time wins over scheduled, and counts as live" do
      html = page([live_row("34", "Spittalfield", "16:25", "16:31", "26118 - YY18 TFJ")])
      assert [a] = BustimesProvider.parse_html(html, @now)
      assert {a.status, a.eta_minutes} == {:live, 49}
      assert a.scheduled_time == ~T[16:31:00]
    end

    test "the nested vehicle div doesn't leak into the destination" do
      html = page([live_row("34", "Spittalfield", "16:25", "16:31", "26118 - YY18 TFJ")])
      assert [a] = BustimesProvider.parse_html(html, @now)
      assert a.destination == "Spittalfield"
    end

    test "an untracked row in the same table (empty Expected cell) stays scheduled" do
      html =
        page([
          live_row("34", "Spittalfield", "16:25", "16:31", "26118 - YY18 TFJ"),
          live_row("34", "Spittalfield", "17:35", nil)
        ])

      assert [_tracked, untracked] = BustimesProvider.parse_html(html, @now)
      assert {untracked.status, untracked.eta_minutes} == {:scheduled, 113}
    end

    test "the real captured 5-row page (one tracked, 21 Oct 16:18) parses all five" do
      html = """
      <table>
      <thead><tr><th></th><th scope="col">To</th><th scope="col">Scheduled</th><th scope="col">Expected</th></tr></thead>
      <tbody>
      <tr>
      <td class="nowrap"><a href="/services/34-perth-spittalfield-or-blairgowrie">34</a></td>
      <td>
      Spittalfield
      <div class="vehicle"><a href="/vehicles/scfi-26118">26118 - YY18 TFJ</a></div>
      </td>
      <td><a href="/journeys/952414756">
      16:25
      </a>
      </td>
      <td>
      <a href="/journeys/952414756">
      16:31
      </a>
      </td>
      </tr>
      <tr>
      <td class="nowrap"><a href="/services/34-perth-spittalfield-or-blairgowrie">34</a></td>
      <td>
      Spittalfield
      </td>
      <td><a href="/trips/654968467">
      17:35
      </a>
      </td>
      <td></td>
      </tr>
      <tr>
      <td class="nowrap"><a href="/services/34-perth-dunkeld-or-aberfeldy">34</a></td>
      <td>
      Dunkeld
      </td>
      <td><a href="/trips/654359558">
      19:04
      </a>
      </td>
      <td></td>
      </tr>
      <tr>
      <td class="nowrap"><a href="/services/34a-perth-spittalfield-or-blairgowrie">34A</a></td>
      <td>
      Spittalfield
      </td>
      <td><a href="/trips/654968404">
      19:32
      </a>
      </td>
      <td></td>
      </tr>
      <tr>
      <td class="nowrap"><a href="/services/34a-perth-spittalfield-or-blairgowrie">34A</a></td>
      <td>
      Spittalfield
      </td>
      <td><a href="/trips/654968405">
      20:54
      </a>
      </td>
      <td></td>
      </tr>
      </tbody>
      </table>
      """

      assert [a1, a2, a3, a4, a5] = BustimesProvider.parse_html(html, @now)

      assert {a1.status, a1.destination, a1.scheduled_time} ==
               {:live, "Spittalfield", ~T[16:31:00]}

      assert {a2.status, a2.destination} == {:scheduled, "Spittalfield"}
      assert {a3.status, a3.destination} == {:scheduled, "Dunkeld"}
      assert {a4.status, a4.destination} == {:scheduled, "Spittalfield"}
      assert {a5.status, a5.destination} == {:scheduled, "Spittalfield"}
    end
  end

  test "a malformed row is skipped rather than crashing" do
    html = "<table><tbody><tr><td>only one cell</td></tr></tbody></table>"
    assert BustimesProvider.parse_html(html, @now) == []
  end

  test "no rows at all parses to an empty list" do
    assert BustimesProvider.parse_html("<table><tbody></tbody></table>", @now) == []
  end

  describe "disruptions?/0 and closures?/0" do
    test "neither concept exists yet for this source" do
      refute BustimesProvider.disruptions?()
      refute BustimesProvider.closures?()
    end
  end

  describe "id/0 and label/0" do
    test "names itself" do
      assert BustimesProvider.id() == :bustimes
      assert BustimesProvider.label() == "Bustimes"
    end
  end
end
