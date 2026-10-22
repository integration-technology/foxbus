defmodule Foxbus.Adapters.Sources.StagecoachProviderTest do
  use ExUnit.Case, async: true
  alias Foxbus.Adapters.Sources.StagecoachProvider

  # A December date, not the real 21-22 Oct capture dates, so UTC == UK
  # local (GMT, not BST) and these fixture times don't need a BST offset
  # worked in by hand. The real captured response below (a separate test)
  # keeps its genuine BST timestamps.
  @now ~N[2026-12-21 15:00:00]

  defp event(overrides) do
    Map.merge(
      %{
        "StopLabel" => "64803547",
        "ScheduledArrivalTime" => %{"value" => "2026-12-21T16:25:00.000+00:00"},
        "ScheduledDepartureTime" => %{"value" => "2026-12-21T16:25:00.000+00:00"},
        "Trip" => %{
          "TripId" => "79291",
          "Service" => %{
            "ServiceId" => "XHBO034.O",
            "Mode" => "bus",
            "Operator" => %{"OperatorCode" => "SPH", "PublicName" => "Stagecoach in Perth"},
            "ServiceNumber" => "34",
            "Description" => "Perth - Spittalfield or Dunkeld",
            "Direction" => "outbound"
          },
          "DestinationBoard" => "Spittalfield"
        }
      },
      overrides
    )
  end

  defp events(list), do: %{"Events" => %{"Event" => list}}

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

  describe "parse_stop_events/3" do
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

      assert [a] = StagecoachProvider.parse_stop_events(json, "64803547", @now)
      assert a.destination == "Spittalfield"
    end

    test "reads line, destination, and scheduled time" do
      json = events([event(%{})])
      assert [a] = StagecoachProvider.parse_stop_events(json, "64803547", @now)
      assert {a.line, a.destination, a.status} == {"34", "Spittalfield", :scheduled}
      assert a.scheduled_time == ~T[16:25:00]
      assert a.eta_minutes == 85
    end

    test "several departures, same stop" do
      json =
        events([
          event(%{"ScheduledDepartureTime" => %{"value" => "2026-12-21T16:25:00.000+00:00"}}),
          event(%{"ScheduledDepartureTime" => %{"value" => "2026-12-21T17:35:00.000+00:00"}})
        ])

      assert [a1, a2] = StagecoachProvider.parse_stop_events(json, "64803547", @now)
      assert a1.scheduled_time == ~T[16:25:00]
      assert a2.scheduled_time == ~T[17:35:00]
    end

    test "a departure after midnight rolls over to tomorrow" do
      json =
        events([
          event(%{"ScheduledDepartureTime" => %{"value" => "2026-12-22T05:30:00.000+00:00"}})
        ])

      assert [a] = StagecoachProvider.parse_stop_events(json, "64803547", @now)
      assert a.day == :tomorrow
    end

    test "an event missing a required field is skipped, not a crash" do
      json =
        events([
          %{
            "StopLabel" => "64803547",
            "ScheduledDepartureTime" => %{"value" => "2026-12-21T16:25:00.000+00:00"}
          }
        ])

      assert StagecoachProvider.parse_stop_events(json, "64803547", @now) == []
    end

    test "no events at all parses to an empty list" do
      assert StagecoachProvider.parse_stop_events(%{"Events" => %{}}, "64803547", @now) == []
    end
  end

  test "the real captured response (Murthly, 21 Oct, BST) parses both stops correctly" do
    # Pasted verbatim from a live stop-event-query capture — genuinely BST
    # timestamps (+01:00), confirming LondonTime.to_local/1 isn't needed
    # here since the offset is already explicit in the ISO string, but
    # the eta/day math downstream still needs a UK-local 'now' to compare
    # against.
    json = %{
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
            "StopLabel" => "64803548",
            "ScheduledDepartureTime" => %{"value" => "2026-10-22T16:44:00.000+01:00"},
            "Trip" => %{"Service" => %{"ServiceNumber" => "34"}, "DestinationBoard" => "Perth"}
          })
        ]
      }
    }

    now = ~N[2026-10-22 15:53:00]

    assert [spittalfield] = StagecoachProvider.parse_stop_events(json, "64803547", now)

    assert {spittalfield.destination, spittalfield.scheduled_time} ==
             {"Spittalfield", ~T[16:25:00]}

    assert [perth] = StagecoachProvider.parse_stop_events(json, "64803548", now)
    assert {perth.destination, perth.scheduled_time} == {"Perth", ~T[16:44:00]}
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
