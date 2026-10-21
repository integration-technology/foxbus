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
               {5, 22, "Aldgate"},
               {6, 4, "Baker Street"}
             ]
    end

    test "drops TfL's own 'Underground Station' suffix from a destination name" do
      schedules = TflProvider.parse_timetable(timetable_json())
      refute Enum.any?(schedules["Monday - Thursday"], fn {_h, _m, d} -> d =~ "Underground" end)
    end

    test "drops journeys with hour 24+ instead of getting day-rollover wrong" do
      schedules = TflProvider.parse_timetable(timetable_json())
      refute Enum.any?(schedules["Monday - Thursday"], fn {h, _m, _d} -> h >= 24 end)
    end

    test "keeps every day-type's schedule separate" do
      schedules = TflProvider.parse_timetable(timetable_json())
      assert schedules["Sunday"] == [{6, 59, "Aldgate"}]
    end

    test "an empty timetable parses to empty schedules, not a crash" do
      empty = %{"stations" => [], "timetable" => %{"routes" => []}}
      assert TflProvider.parse_timetable(empty) == %{}
    end
  end

  describe "weekdays_covered/1" do
    test "a range covers every weekday from the first to the second, inclusive" do
      assert TflProvider.weekdays_covered("Monday - Thursday") == MapSet.new([1, 2, 3, 4])
      assert TflProvider.weekdays_covered("Monday - Friday") == MapSet.new([1, 2, 3, 4, 5])
    end

    test "a single plural weekday covers just that day" do
      assert TflProvider.weekdays_covered("Tuesdays") == MapSet.new([2])
      assert TflProvider.weekdays_covered("Wednesdays") == MapSet.new([3])
      assert TflProvider.weekdays_covered("Thursdays") == MapSet.new([4])
    end

    test "a day plus trailing text still covers just that day" do
      assert TflProvider.weekdays_covered("Saturdays and Public Holidays") == MapSet.new([6])
    end

    test "a bare singular day covers just that day" do
      assert TflProvider.weekdays_covered("Sunday") == MapSet.new([7])
    end

    test "nothing recognisable covers no weekday, rather than guessing" do
      assert TflProvider.weekdays_covered("Half Term") == MapSet.new()
    end
  end

  describe "covers_weekday?/2" do
    test "true when some schedule covers the weekday" do
      schedules = %{"Tuesdays" => [], "Wednesdays" => [], "Thursdays" => []}
      assert TflProvider.covers_weekday?(schedules, 2)
      refute TflProvider.covers_weekday?(schedules, 1)
    end

    test "false on a partial response that misses today (confirmed live: TfL sometimes " <>
           "returns only Sunday, unauthenticated)" do
      refute TflProvider.covers_weekday?(%{"Sunday" => [{6, 59, "Aldgate"}]}, 1)
      assert TflProvider.covers_weekday?(%{"Sunday" => [{6, 59, "Aldgate"}]}, 7)
    end

    test "false when empty" do
      refute TflProvider.covers_weekday?(%{}, 1)
    end
  end

  describe "expand_by_weekday/1" do
    test "a ranged schedule appears under each weekday it covers" do
      schedules = %{"Monday - Thursday" => [{5, 22, "Aldgate"}]}
      by_weekday = TflProvider.expand_by_weekday(schedules)

      for weekday <- 1..4 do
        assert by_weekday[weekday] == [{5, 22, "Aldgate"}]
      end

      refute Map.has_key?(by_weekday, 5)
    end

    test "confirmed live: an engineering-work week names each weekday separately" do
      schedules = %{
        "Tuesdays" => [{5, 30, "Spittalfield"}],
        "Wednesdays" => [{5, 35, "Spittalfield"}],
        "Thursdays" => [{5, 40, "Spittalfield"}]
      }

      by_weekday = TflProvider.expand_by_weekday(schedules)
      assert by_weekday[2] == [{5, 30, "Spittalfield"}]
      assert by_weekday[3] == [{5, 35, "Spittalfield"}]
      assert by_weekday[4] == [{5, 40, "Spittalfield"}]
      refute Map.has_key?(by_weekday, 1)
    end

    test "two schedules covering the same weekday merge, sorted, rather than one winning" do
      schedules = %{"Mondays" => [{7, 0, "A"}], "Monday - Tuesday" => [{6, 0, "B"}]}
      assert TflProvider.expand_by_weekday(schedules)[1] == [{6, 0, "B"}, {7, 0, "A"}]
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

  describe "fresh_cache/2 and stale_cache/1 — the pre-5ca5a2c cache shape" do
    # The literal shape NestGen2.Storage held before this change: keyed by
    # TfL's own schedule name, not by weekday — confirmed live, this is
    # what's still on the Nest's own Storage (fetched 19 Oct) until its
    # next successful refetch overwrites it.
    @old_shape_cache %{
      fetched_on: ~D[2026-10-19],
      schedules: %{"Monday - Thursday" => [{5, 22, "Aldgate Underground Station"}]}
    }

    test "the old shape is never fresh, even dated today — it just misses, not crashes" do
      assert TflProvider.fresh_cache(@old_shape_cache, ~D[2026-10-19]) == :miss
      assert TflProvider.fresh_cache(@old_shape_cache, ~D[2026-10-21]) == :miss
    end

    test "the old shape is never usable as a stale fallback either — also just misses" do
      assert TflProvider.stale_cache(@old_shape_cache) == :none
    end

    test "no cache at all also just misses, same as the old shape" do
      assert TflProvider.fresh_cache(nil, ~D[2026-10-21]) == :miss
      assert TflProvider.stale_cache(nil) == :none
    end

    test "the new shape is fresh only when fetched today" do
      cache = %{fetched_on: ~D[2026-10-21], by_weekday: %{2 => [{5, 30, "Spittalfield"}]}}

      assert TflProvider.fresh_cache(cache, ~D[2026-10-21]) ==
               {:ok, %{2 => [{5, 30, "Spittalfield"}]}}

      assert TflProvider.fresh_cache(cache, ~D[2026-10-22]) == :miss
    end

    test "the new shape is always usable as a stale fallback, regardless of its date" do
      cache = %{fetched_on: ~D[2026-10-19], by_weekday: %{2 => [{5, 30, "Spittalfield"}]}}
      assert TflProvider.stale_cache(cache) == {:ok, %{2 => [{5, 30, "Spittalfield"}]}}
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
