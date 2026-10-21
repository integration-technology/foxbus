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
