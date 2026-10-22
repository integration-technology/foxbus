defmodule Foxbus.Adapters.Sources.StagecoachProviderTest do
  use ExUnit.Case, async: true
  alias Foxbus.Adapters.Sources.StagecoachProvider

  # A December date, not the real capture dates, so UTC == UK local (GMT,
  # not BST) and these fixture times don't need a BST offset worked in by
  # hand. The real captured response test below keeps its genuine BST
  # timestamps.
  @now ~N[2026-12-21 15:00:00]

  defp event(overrides) do
    Map.merge(
      %{
        "StopLabel" => "64803547",
        "ScheduledArrivalTime" => %{"value" => "2026-12-21T16:25:00.000+00:00"},
        "ScheduledDepartureTime" => %{"value" => "2026-12-21T16:25:00.000+00:00"},
        "Trip" => %{
          "TripId" => "79291",
          "Service" => %{"ServiceId" => "XHBO034.O", "ServiceNumber" => "34"},
          "DestinationBoard" => "Spittalfield"
        }
      },
      overrides
    )
  end

  defp events(list), do: %{"Events" => %{"Event" => list}}

  defp call(overrides) do
    Map.merge(
      %{
        "operatorRef" => "SCFI",
        "lineRef" => "34",
        "cancelled" => false,
        "aimedDepartureTime" => "2026-12-21T16:25:00Z"
      },
      overrides
    )
  end

  defp monitor(calls),
    do: %{
      "stopMonitors" => %{"stopMonitor" => [%{"monitoredCalls" => %{"monitoredCall" => calls}}]}
    }

  describe "parse_stop_id/1" do
    test "splits latitude, longitude, and the stop label" do
      assert StagecoachProvider.parse_stop_id("56.520319,-3.465884,64803548") ==
               {:ok, {56.520319, -3.465884, "64803548"}}
    end

    test "a malformed stop_id is an error, not a crash" do
      assert StagecoachProvider.parse_stop_id("64803548") == {:error, :invalid_stop_id}

      assert StagecoachProvider.parse_stop_id("not,numbers,64803548") ==
               {:error, :invalid_stop_id}
    end
  end

  describe "parse_events/2" do
    test "keeps only events at the matching stop label — the endpoint returns every nearby stop" do
      json =
        events([
          event(%{
            "StopLabel" => "64803547",
            "Trip" => %{
              "Service" => %{"ServiceNumber" => "34"},
              "DestinationBoard" => "Spittalfield"
            }
          }),
          event(%{
            "StopLabel" => "64803548",
            "Trip" => %{"Service" => %{"ServiceNumber" => "34"}, "DestinationBoard" => "Perth"}
          })
        ])

      assert [e] = StagecoachProvider.parse_events(json, "64803547")
      assert e.destination == "Spittalfield"
    end

    test "reads line, destination, and the scheduled UTC instant" do
      assert [e] = StagecoachProvider.parse_events(events([event(%{})]), "64803547")
      assert {e.line, e.destination} == {"34", "Spittalfield"}
      assert e.scheduled_utc == ~U[2026-12-21 16:25:00.000Z]
    end

    test "an event missing a required field is skipped, not a crash" do
      json =
        events([
          %{
            "StopLabel" => "64803547",
            "ScheduledDepartureTime" => %{"value" => "2026-12-21T16:25:00.000+00:00"}
          }
        ])

      assert StagecoachProvider.parse_events(json, "64803547") == []
    end

    test "no events at all parses to an empty list" do
      assert StagecoachProvider.parse_events(%{"Events" => %{}}, "64803547") == []
    end
  end

  describe "parse_live_calls/1" do
    test "reads line, aimed/expected instants, and cancelled" do
      json = monitor([call(%{"expectedDepartureTime" => "2026-12-21T16:28:00Z"})])
      assert [c] = StagecoachProvider.parse_live_calls(json)
      assert c.line == "34"
      assert c.aimed_utc == ~U[2026-12-21 16:25:00Z]
      assert c.expected_utc == ~U[2026-12-21 16:28:00Z]
      refute c.cancelled
    end

    test "no expected time is nil, not a crash" do
      assert [c] = StagecoachProvider.parse_live_calls(monitor([call(%{})]))
      assert c.expected_utc == nil
    end

    test "a call missing aimedDepartureTime is skipped" do
      json = monitor([%{"lineRef" => "34", "cancelled" => false}])
      assert StagecoachProvider.parse_live_calls(json) == []
    end

    test "no monitored calls at all parses to an empty list" do
      assert StagecoachProvider.parse_live_calls(%{"stopMonitors" => %{}}) == []
    end
  end

  describe "merge_live/2" do
    defp scheduled_event(overrides),
      do:
        Map.merge(
          %{line: "34", destination: "Spittalfield", scheduled_utc: ~U[2026-12-21 16:25:00Z]},
          overrides
        )

    test "no matching live call stays scheduled" do
      assert [e] = StagecoachProvider.merge_live([scheduled_event(%{})], [])

      assert {e.status, e.delay_minutes, e.cancelled?, e.display_utc} ==
               {:scheduled, nil, false, ~U[2026-12-21 16:25:00Z]}
    end

    test "a matching on-time live call (no expected time) is live with zero delay" do
      live = %{
        line: "34",
        aimed_utc: ~U[2026-12-21 16:25:00Z],
        expected_utc: nil,
        cancelled: false
      }

      assert [e] = StagecoachProvider.merge_live([scheduled_event(%{})], [live])
      assert {e.status, e.delay_minutes, e.cancelled?} == {:live, 0, false}
    end

    test "a matching delayed live call carries the expected time and the computed delay" do
      live = %{
        line: "34",
        aimed_utc: ~U[2026-12-21 16:25:00Z],
        expected_utc: ~U[2026-12-21 16:30:00Z],
        cancelled: false
      }

      assert [e] = StagecoachProvider.merge_live([scheduled_event(%{})], [live])
      assert {e.status, e.delay_minutes, e.display_utc} == {:live, 5, ~U[2026-12-21 16:30:00Z]}
    end

    test "a matching cancelled live call marks the event cancelled, keeping the scheduled time" do
      live = %{
        line: "34",
        aimed_utc: ~U[2026-12-21 16:25:00Z],
        expected_utc: nil,
        cancelled: true
      }

      assert [e] = StagecoachProvider.merge_live([scheduled_event(%{})], [live])

      assert {e.status, e.cancelled?, e.display_utc} ==
               {:scheduled, true, ~U[2026-12-21 16:25:00Z]}
    end

    test "a live call for a different line or time doesn't match" do
      live = %{
        line: "34A",
        aimed_utc: ~U[2026-12-21 16:25:00Z],
        expected_utc: nil,
        cancelled: false
      }

      assert [e] = StagecoachProvider.merge_live([scheduled_event(%{})], [live])
      assert e.status == :scheduled
    end
  end

  describe "to_arrival/2" do
    test "builds a scheduled Arrival" do
      event = %{
        line: "34",
        destination: "Spittalfield",
        scheduled_utc: ~U[2026-12-21 16:25:00Z],
        display_utc: ~U[2026-12-21 16:25:00Z],
        status: :scheduled,
        delay_minutes: nil,
        cancelled?: false
      }

      a = StagecoachProvider.to_arrival(event, @now)

      assert {a.line, a.destination, a.status, a.cancelled?} ==
               {"34", "Spittalfield", :scheduled, false}

      assert a.scheduled_time == ~T[16:25:00]
      assert a.eta_minutes == 85
    end

    test "builds a live, delayed Arrival using the expected (display) time" do
      event = %{
        line: "34",
        destination: "Spittalfield",
        scheduled_utc: ~U[2026-12-21 16:25:00Z],
        display_utc: ~U[2026-12-21 16:30:00Z],
        status: :live,
        delay_minutes: 5,
        cancelled?: false
      }

      a = StagecoachProvider.to_arrival(event, @now)
      assert {a.status, a.delay_minutes, a.scheduled_time} == {:live, 5, ~T[16:30:00]}
    end

    test "a cancelled Arrival still carries its scheduled time" do
      event = %{
        line: "34",
        destination: "Spittalfield",
        scheduled_utc: ~U[2026-12-21 16:25:00Z],
        display_utc: ~U[2026-12-21 16:25:00Z],
        status: :scheduled,
        delay_minutes: nil,
        cancelled?: true
      }

      a = StagecoachProvider.to_arrival(event, @now)
      assert a.cancelled?
      assert a.scheduled_time == ~T[16:25:00]
    end
  end

  test "the real captured responses (Murthly, 21-22 Oct) parse and merge end to end" do
    # stop-event-query, pasted verbatim from a live capture — genuine BST
    # timestamps.
    event_json = %{
      "Events" => %{
        "Event" => [
          event(%{
            "StopLabel" => "64803547",
            "ScheduledDepartureTime" => %{"value" => "2026-10-22T16:25:00.000+01:00"},
            "Trip" => %{
              "Service" => %{"ServiceNumber" => "34"},
              "DestinationBoard" => "Spittalfield"
            }
          }),
          event(%{
            "StopLabel" => "64803547",
            "ScheduledDepartureTime" => %{"value" => "2026-10-22T17:35:00.000+01:00"},
            "Trip" => %{
              "Service" => %{"ServiceNumber" => "34"},
              "DestinationBoard" => "Spittalfield"
            }
          })
        ]
      }
    }

    # stop-monitor, pasted verbatim from a live capture — the first
    # journey is live-tracked and running a few minutes late.
    monitor_json =
      monitor([
        call(%{
          "lineRef" => "34",
          "aimedDepartureTime" => "2026-10-22T15:25:00Z",
          "expectedDepartureTime" => "2026-10-22T15:28:42Z"
        })
      ])

    now = ~N[2026-10-22 15:53:00]

    events = StagecoachProvider.parse_events(event_json, "64803547")
    live = StagecoachProvider.parse_live_calls(monitor_json)

    arrivals =
      events
      |> StagecoachProvider.merge_live(live)
      |> Enum.map(&StagecoachProvider.to_arrival(&1, now))

    assert [tracked, untracked] = arrivals
    assert {tracked.status, tracked.scheduled_time} == {:live, ~T[16:28:42]}
    assert {untracked.status, untracked.scheduled_time} == {:scheduled, ~T[17:35:00]}
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
