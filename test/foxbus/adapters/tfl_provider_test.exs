defmodule Foxbus.Adapters.Sources.TflProviderTest do
  use ExUnit.Case, async: true
  alias Foxbus.Adapters.Sources.TflProvider

  # Shaped like a real TfL Line Timetable response (confirmed live against
  # api.tfl.gov.uk for Amersham/Metropolitan) — trimmed to what
  # parse_timetable/1 actually reads: two destinations (interval "0" runs
  # all the way to Aldgate; interval "1" terminates sooner, at Baker
  # Street), one Monday-Thursday journey with TfL's own "next calendar
  # day" hour (24) to prove it's dropped, and a separate Sunday schedule to
  # prove day-types don't bleed into each other.
  defp timetable_json do
    %{
      "stations" => [
        %{"id" => "940GZZLUAMS", "name" => "Amersham Underground Station"},
        %{"id" => "940GZZLUBST", "name" => "Baker Street Underground Station"},
        %{"id" => "940GZZLUALD", "name" => "Aldgate Underground Station"}
      ],
      "timetable" => %{
        "departureStopId" => "940GZZLUAMS",
        "routes" => [
          %{
            "stationIntervals" => [
              %{
                "id" => "0",
                "intervals" => [
                  %{"stopId" => "940GZZLUBST", "timeToArrival" => 53.0},
                  %{"stopId" => "940GZZLUALD", "timeToArrival" => 69.0}
                ]
              },
              %{
                "id" => "1",
                "intervals" => [
                  %{"stopId" => "940GZZLUBST", "timeToArrival" => 53.0}
                ]
              }
            ],
            "schedules" => [
              %{
                "name" => "Monday - Thursday",
                "knownJourneys" => [
                  %{"hour" => "5", "minute" => "22", "intervalId" => 0},
                  %{"hour" => "6", "minute" => "4", "intervalId" => 1},
                  %{"hour" => "24", "minute" => "50", "intervalId" => 0}
                ]
              },
              %{
                "name" => "Sunday",
                "knownJourneys" => [
                  %{"hour" => "6", "minute" => "59", "intervalId" => 0}
                ]
              }
            ]
          }
        ]
      }
    }
  end

  describe "parse_timetable/1" do
    test "resolves each journey's destination from its own stationInterval" do
      schedules = TflProvider.parse_timetable(timetable_json())

      assert schedules["Monday - Thursday"] == [
               {5, 22, "Aldgate Underground Station"},
               {6, 4, "Baker Street Underground Station"}
             ]
    end

    test "drops journeys with hour 24+ instead of getting day-rollover wrong" do
      schedules = TflProvider.parse_timetable(timetable_json())
      refute Enum.any?(schedules["Monday - Thursday"], fn {h, _m, _d} -> h >= 24 end)
    end

    test "keeps every day-type's schedule separate" do
      schedules = TflProvider.parse_timetable(timetable_json())
      assert schedules["Sunday"] == [{6, 59, "Aldgate Underground Station"}]
    end

    test "an empty timetable parses to empty schedules, not a crash" do
      empty = %{"stations" => [], "timetable" => %{"routes" => []}}
      assert TflProvider.parse_timetable(empty) == %{}
    end
  end

  describe "next_departures/2" do
    test "keeps only departures at or after now, soonest first" do
      departures = [{5, 22, "A"}, {6, 4, "B"}, {9, 0, "C"}]
      assert TflProvider.next_departures(departures, 6 * 60) == [{6, 4, "B"}, {9, 0, "C"}]
    end

    test "a departure at exactly now still counts" do
      departures = [{6, 4, "B"}]
      assert TflProvider.next_departures(departures, 6 * 60 + 4) == [{6, 4, "B"}]
    end

    test "keeps at most 3" do
      departures = [{5, 0, "A"}, {6, 0, "B"}, {7, 0, "C"}, {8, 0, "D"}]
      assert length(TflProvider.next_departures(departures, 0)) == 3
    end

    test "none left today is an empty list" do
      assert TflProvider.next_departures([{5, 0, "A"}], 23 * 60) == []
    end
  end

  describe "day_type/1" do
    test "Monday through Thursday" do
      for date <- [~D[2026-10-12], ~D[2026-10-13], ~D[2026-10-14], ~D[2026-10-15]] do
        assert TflProvider.day_type(date) == "Monday - Thursday"
      end
    end

    test "Friday" do
      assert TflProvider.day_type(~D[2026-10-16]) == "Friday"
    end

    test "Saturday" do
      assert TflProvider.day_type(~D[2026-10-17]) == "Saturdays and Public Holidays"
    end

    test "Sunday" do
      assert TflProvider.day_type(~D[2026-10-18]) == "Sunday"
    end
  end

  describe "parse_status/1" do
    defp line_status_json(status), do: [%{"lineStatuses" => [status]}]

    test "nil on Good Service" do
      assert TflProvider.parse_status(
               line_status_json(%{"statusSeverityDescription" => "Good Service"})
             ) ==
               nil
    end

    test "the reason text when disrupted" do
      status = %{
        "statusSeverityDescription" => "Minor Delays",
        "reason" => "Metropolitan Line: Minor delays due to train cancellations."
      }

      assert TflProvider.parse_status(line_status_json(status)) ==
               "Metropolitan Line: Minor delays due to train cancellations."
    end

    test "falls back to the severity description when there's no reason text" do
      status = %{"statusSeverityDescription" => "Severe Delays", "reason" => ""}
      assert TflProvider.parse_status(line_status_json(status)) == "Severe Delays"
    end

    test "the first disrupted status wins when a line has several" do
      json = [
        %{
          "lineStatuses" => [
            %{"statusSeverityDescription" => "Good Service"},
            %{"statusSeverityDescription" => "Part Closure", "reason" => "Planned closure."}
          ]
        }
      ]

      assert TflProvider.parse_status(json) == "Planned closure."
    end

    test "no statuses at all is nil, not a crash" do
      assert TflProvider.parse_status([]) == nil
    end
  end

  describe "line_id/1" do
    test "a plain single-word line name just lowercases" do
      assert TflProvider.line_id("Metropolitan") == "metropolitan"
      assert TflProvider.line_id("Victoria") == "victoria"
    end

    test "an ampersand becomes a hyphen, matching TfL's real line ids" do
      assert TflProvider.line_id("Hammersmith & City") == "hammersmith-city"
      assert TflProvider.line_id("Waterloo & City") == "waterloo-city"
    end
  end

  describe "disruptions?/0 and closures?/0" do
    test "has line disruptions but no stop-closure concept" do
      assert TflProvider.disruptions?()
      refute TflProvider.closures?()
    end
  end

  describe "id/0 and label/0" do
    test "names itself" do
      assert TflProvider.id() == :tfl
      assert TflProvider.label() == "TfL"
    end
  end
end
