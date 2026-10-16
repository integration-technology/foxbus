defmodule Foxbus.Adapters.Sources.TflProviderTest do
  use ExUnit.Case, async: true
  alias Foxbus.Adapters.Sources.TflProvider

  # Shaped like a real TfL StopPoint Arrivals prediction (confirmed live
  # against api.tfl.gov.uk) — only the fields parse_arrivals/1 actually
  # reads are included.
  defp prediction(attrs) do
    Map.merge(
      %{
        "lineName" => "Metropolitan",
        "destinationName" => "Amersham Underground Station",
        "towards" => "Amersham",
        "timeToStation" => 234
      },
      attrs
    )
  end

  describe "parse_arrivals/1" do
    test "maps line, destination, and seconds to minutes" do
      assert [a] = TflProvider.parse_arrivals([prediction(%{})])

      assert {a.line, a.destination, a.eta_minutes, a.status} ==
               {"Metropolitan", "Amersham Underground Station", 3, :live}
    end

    test "rounds down to the minute" do
      assert [a] = TflProvider.parse_arrivals([prediction(%{"timeToStation" => 299})])
      assert a.eta_minutes == 4
    end

    test "falls back to towards when destinationName is blank" do
      assert [a] = TflProvider.parse_arrivals([prediction(%{"destinationName" => ""})])
      assert a.destination == "Amersham"
    end

    test "falls back to towards when destinationName is missing entirely, not just blank" do
      # A real prediction at a branch terminus (Amersham, Metropolitan line)
      # — TfL omits destinationName altogether here, not just leaves it "".
      real = %{
        "lineName" => "Metropolitan",
        "towards" => "Check Front of Train",
        "timeToStation" => 289
      }

      assert [a] = TflProvider.parse_arrivals([real])
      assert a.destination == "Check Front of Train"
    end

    test "falls back to a placeholder when both are blank" do
      assert [a] =
               TflProvider.parse_arrivals([
                 prediction(%{"destinationName" => "", "towards" => ""})
               ])

      assert a.destination == "Unknown"
    end

    test "no predictions is an empty list" do
      assert TflProvider.parse_arrivals([]) == []
    end

    test "several predictions all parse" do
      predictions = [prediction(%{"timeToStation" => 60}), prediction(%{"timeToStation" => 420})]
      assert [a, b] = TflProvider.parse_arrivals(predictions)
      assert {a.eta_minutes, b.eta_minutes} == {1, 7}
    end
  end

  describe "parse_status/1" do
    # Shaped like a real TfL Line Status response.
    defp line_status_json(status) do
      [%{"lineStatuses" => [status]}]
    end

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
