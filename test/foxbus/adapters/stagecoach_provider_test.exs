defmodule Foxbus.Adapters.Sources.StagecoachProviderTest do
  use ExUnit.Case, async: true
  alias Foxbus.Adapters.Sources.StagecoachProvider

  # A December date, not the real 21 Oct capture date, so UTC == UK local
  # (GMT, not BST) and the fixture times below don't need a BST offset
  # worked into them by hand.
  @now ~N[2026-12-21 18:32:00]

  # Shaped like the real stop-monitor response (confirmed live against
  # api.stagecoachbus.com for Murthly, Primary School, 21 Oct) — a live
  # call carries both aimed and expected times and no status flag beyond
  # cancelled; status: :live is inferred from the presence of an expected
  # time, not a separate field.
  defp call(overrides) do
    Map.merge(
      %{
        "operatorRef" => "SCFI",
        "lineRef" => "34A",
        "stopPointName" => "Primary School",
        "destinationDisplay" => "Spittalfield",
        "timingPoint" => false,
        "direction" => "OUTBOUND",
        "cancelled" => false,
        "aimedDepartureTime" => "2026-12-21T18:32:00Z"
      },
      overrides
    )
  end

  defp monitor(calls),
    do: %{
      "stopMonitors" => %{"stopMonitor" => [%{"monitoredCalls" => %{"monitoredCall" => calls}}]}
    }

  test "a live call prefers the expected time over aimed, and counts as live" do
    json = monitor([call(%{"expectedDepartureTime" => "2026-12-21T18:35:42Z"})])
    assert [a] = StagecoachProvider.parse_stop_monitor(json, @now)
    assert {a.line, a.destination, a.status, a.eta_minutes} == {"34A", "Spittalfield", :live, 3}
    assert a.scheduled_time == ~T[18:35:42]
  end

  test "no expected time falls back to aimed, and counts as scheduled" do
    json = monitor([call(%{})])
    assert [a] = StagecoachProvider.parse_stop_monitor(json, @now)
    assert {a.status, a.eta_minutes} == {:scheduled, 0}
    assert a.scheduled_time == ~T[18:32:00]
  end

  test "a cancelled call is dropped" do
    json =
      monitor([call(%{"cancelled" => true, "expectedDepartureTime" => "2026-12-21T18:35:00Z"})])

    assert StagecoachProvider.parse_stop_monitor(json, @now) == []
  end

  test "several calls across several lines" do
    json =
      monitor([
        call(%{"lineRef" => "34", "destinationDisplay" => "Dunkeld"}),
        call(%{"lineRef" => "34A", "destinationDisplay" => "Spittalfield"})
      ])

    assert [a1, a2] = StagecoachProvider.parse_stop_monitor(json, @now)
    assert {a1.line, a1.destination} == {"34", "Dunkeld"}
    assert {a2.line, a2.destination} == {"34A", "Spittalfield"}
  end

  test "a departure after midnight rolls over to tomorrow" do
    json = monitor([call(%{"aimedDepartureTime" => "2026-12-22T05:30:00Z"})])
    assert [a] = StagecoachProvider.parse_stop_monitor(json, @now)
    assert a.day == :tomorrow
  end

  test "no stop monitors at all parses to an empty list" do
    assert StagecoachProvider.parse_stop_monitor(%{"stopMonitors" => %{}}, @now) == []
  end

  test "no monitored calls at all (nothing due) parses to an empty list" do
    json = %{"stopMonitors" => %{"stopMonitor" => [%{"stopPointLabel" => "64803547"}]}}
    assert StagecoachProvider.parse_stop_monitor(json, @now) == []
  end

  test "the real captured response (Murthly Primary School, 21 Oct 18:3x BST) parses" do
    # Pasted verbatim from a live curl against api.stagecoachbus.com, so
    # the timestamps are genuinely BST (UTC+1) — a live BST eta needs the
    # same UK-local 'now' @now itself is in, see Foxbus.LondonTime.
    json = %{
      "stopMonitors" => %{
        "stopMonitor" => [
          %{
            "stopPointLabel" => "64803547",
            "monitoredCalls" => %{
              "monitoredCall" => [
                %{
                  "operatorRef" => "SCFI",
                  "datedVehicleJourneyRef" => "647",
                  "visitNumber" => 33,
                  "lineRef" => "34A",
                  "stopPointLabel" => "64803547",
                  "stopPointName" => "Primary School",
                  "destinationDisplay" => "Spittalfield",
                  "timingPoint" => false,
                  "direction" => "OUTBOUND",
                  "vehicleRef" => "SCFI-74025",
                  "cancelled" => false,
                  "expectedArrivalTime" => "2026-10-21T18:35:40Z",
                  "expectedDepartureTime" => "2026-10-21T18:35:42Z",
                  "aimedArrivalTime" => "2026-10-21T18:32:00Z",
                  "aimedDepartureTime" => "2026-10-21T18:32:00Z"
                }
              ]
            }
          }
        ]
      }
    }

    # "now" is 19:32 UK local (BST, +1h on the response's UTC timestamps)
    # — just before the real expectedDepartureTime below, BST-converted.
    assert [a] = StagecoachProvider.parse_stop_monitor(json, ~N[2026-10-21 19:32:00])
    assert {a.line, a.destination, a.status, a.eta_minutes} == {"34A", "Spittalfield", :live, 3}
    # The response's 18:35:42Z is UTC; confirms LondonTime.to_local/1
    # applies the BST offset to a real captured timestamp (not just a
    # hand-built one), landing on 19:35:42 UK local.
    assert a.scheduled_time == ~T[19:35:42]
  end

  describe "disruptions?/0 and closures?/0" do
    test "neither concept exists yet for this source" do
      refute StagecoachProvider.disruptions?()
      refute StagecoachProvider.closures?()
    end
  end

  describe "id/0 and label/0" do
    test "names itself" do
      assert StagecoachProvider.id() == :stagecoach
      assert StagecoachProvider.label() == "Stagecoach"
    end
  end
end
