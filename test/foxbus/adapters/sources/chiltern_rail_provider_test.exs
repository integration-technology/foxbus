defmodule Foxbus.Adapters.Sources.ChilternRailProviderTest do
  use ExUnit.Case, async: true
  alias Foxbus.Adapters.Sources.ChilternRailProvider

  @now ~N[2026-10-30 10:00:00]

  defp service(fields) do
    %{
      "std" => fields[:std] || "10:05",
      "etd" => fields[:etd] || "On time",
      "operatorCode" => fields[:operator_code] || "CH",
      "isCancelled" => Keyword.get(fields, :is_cancelled, false),
      "destination" => [
        %{"locationName" => fields[:destination] || "London Marylebone", "crs" => "MYB"}
      ]
    }
  end

  defp board(services) do
    %{
      "locationName" => "Amersham",
      "crs" => "AMR",
      "trainServices" => services
    }
  end

  describe "parse_board/1 against a real captured response" do
    # Captured live 2026-11-02 from GetDepartureBoard/AMR?filterCrs=MYB —
    # trimmed to the fields parse_board/1 reads, extra real-world fields
    # (futureCancellation, origin, assocIsCancelled, ...) left in to prove
    # they're harmlessly ignored.
    @real_response %{
      "trainServices" => [
        %{
          "futureCancellation" => false,
          "futureDelay" => false,
          "origin" => [
            %{"locationName" => "Aylesbury", "crs" => "AYS", "assocIsCancelled" => false}
          ],
          "destination" => [
            %{"locationName" => "London Marylebone", "crs" => "MYB", "assocIsCancelled" => false}
          ],
          "std" => "16:08",
          "etd" => "On time",
          "operator" => "Chiltern Railways",
          "operatorCode" => "CH",
          "isCircularRoute" => false,
          "isCancelled" => false,
          "filterLocationCancelled" => false,
          "serviceType" => "train",
          "length" => 2,
          "detachFront" => false,
          "isReverseFormation" => false,
          "serviceID" => "10297629AMERSHM_"
        }
      ],
      "generatedAt" => "2026-11-02T16:07:54.7725479+00:00",
      "locationName" => "Amersham",
      "crs" => "AMR",
      "filterLocationName" => "London Marylebone",
      "filtercrs" => "MYB",
      "filterType" => "to",
      "platformAvailable" => false,
      "areServicesAvailable" => true,
      "Xmlns" => %{"Count" => 8}
    }

    test "parses the real shape" do
      assert [service] = ChilternRailProvider.parse_board(@real_response)

      assert service == %{
               std: {16, 8},
               etd: "On time",
               destination: "London Marylebone",
               line: "dep",
               cancelled?: false
             }
    end
  end

  describe "parse_stop_id/1" do
    test "splits the origin and destination CRS codes, defaulting to one direction" do
      assert ChilternRailProvider.parse_stop_id("AMR,MYB") == {:ok, {"AMR", "MYB", :one_way}}
    end

    test "a trailing \"both\" segment asks for both directions" do
      assert ChilternRailProvider.parse_stop_id("AMR,MYB,both") ==
               {:ok, {"AMR", "MYB", :both_ways}}
    end

    test "a malformed stop_id is an error, not a crash" do
      assert ChilternRailProvider.parse_stop_id("AMR") == {:error, :invalid_stop_id}
      assert ChilternRailProvider.parse_stop_id(",MYB") == {:error, :invalid_stop_id}
      assert ChilternRailProvider.parse_stop_id("AMR,") == {:error, :invalid_stop_id}
      assert ChilternRailProvider.parse_stop_id("AMR,MYB,sideways") == {:error, :invalid_stop_id}
    end
  end

  describe "parse_board/1" do
    test "reads std, etd, destination, and cancelled from each service, labelling it \"dep\"" do
      body = board([service(std: "10:05", etd: "On time", destination: "London Marylebone")])

      assert [s] = ChilternRailProvider.parse_board(body)

      assert s == %{
               std: {10, 5},
               etd: "On time",
               destination: "London Marylebone",
               line: "dep",
               cancelled?: false
             }
    end

    test "several services parse in document order" do
      body = board([service(std: "10:05"), service(std: "10:35"), service(std: "11:05")])
      assert [a, b, c] = ChilternRailProvider.parse_board(body)
      assert {a.std, b.std, c.std} == {{10, 5}, {10, 35}, {11, 5}}
    end

    test "a service with a malformed std is skipped, not a crash" do
      body = board([service(std: "not-a-time"), service(std: "10:35")])
      assert [s] = ChilternRailProvider.parse_board(body)
      assert s.std == {10, 35}
    end

    test "no train services at all parses to an empty list" do
      assert ChilternRailProvider.parse_board(board([])) == []
    end

    test "a response missing trainServices entirely parses to an empty list" do
      assert ChilternRailProvider.parse_board(%{"locationName" => "Amersham"}) == []
    end
  end

  describe "parse_board/2" do
    test "labels every row with whatever line string it's given" do
      body = board([service(std: "10:05")])
      assert [s] = ChilternRailProvider.parse_board(body, "arr")
      assert s.line == "arr"
    end

    test "a service missing its destination is skipped, not a crash" do
      body = %{
        "trainServices" => [
          %{"std" => "10:05", "etd" => "On time", "isCancelled" => false, "destination" => []}
        ]
      }

      assert ChilternRailProvider.parse_board(body, "dep") == []
    end
  end

  describe "to_arrival/2" do
    test "etd \"On time\" is live with zero delay, using std" do
      event = %{
        std: {10, 35},
        etd: "On time",
        destination: "London Marylebone",
        line: "dep",
        cancelled?: false
      }

      a = ChilternRailProvider.to_arrival(event, @now)

      assert {a.line, a.destination, a.status, a.delay_minutes, a.cancelled?} ==
               {"dep", "London Marylebone", :live, 0, false}

      assert {a.scheduled_time, a.eta_minutes} == {~T[10:35:00], 35}
    end

    test "a revised etd is live with the computed delay, and the displayed ETA follows it" do
      event = %{
        std: {10, 35},
        etd: "10:42",
        destination: "London Marylebone",
        line: "dep",
        cancelled?: false
      }

      a = ChilternRailProvider.to_arrival(event, @now)
      assert {a.status, a.delay_minutes, a.eta_minutes} == {:live, 7, 42}
    end

    test "isCancelled stays scheduled against std, marked cancelled, regardless of etd text" do
      event = %{
        std: {11, 5},
        etd: "Cancelled",
        destination: "London Marylebone",
        line: "dep",
        cancelled?: true
      }

      a = ChilternRailProvider.to_arrival(event, @now)

      assert {a.status, a.cancelled?, a.delay_minutes, a.eta_minutes} ==
               {:scheduled, true, nil, 65}
    end

    test "a generic \"Delayed\" with no specific revised time stays scheduled against std" do
      event = %{
        std: {10, 35},
        etd: "Delayed",
        destination: "London Marylebone",
        line: "dep",
        cancelled?: false
      }

      a = ChilternRailProvider.to_arrival(event, @now)
      assert {a.status, a.cancelled?, a.delay_minutes} == {:scheduled, false, nil}
    end
  end

  describe "combine_legs/2" do
    defp leg_arrival(line, eta),
      do: %Foxbus.Domain.Arrival{line: line, destination: "MYB", eta_minutes: eta, status: :live}

    test "both legs succeeding merges and sorts by eta" do
      dep = {:ok, [leg_arrival("dep", 20)]}
      arr = {:ok, [leg_arrival("arr", 5)]}

      assert {:ok, [a, b]} = ChilternRailProvider.combine_legs(dep, arr)
      assert {a.line, b.line} == {"arr", "dep"}
    end

    test "the arrival leg failing still shows the departure leg" do
      dep = {:ok, [leg_arrival("dep", 20)]}
      assert ChilternRailProvider.combine_legs(dep, {:error, :boom}) == dep
    end

    test "the departure leg failing still shows the arrival leg" do
      arr = {:ok, [leg_arrival("arr", 5)]}
      assert ChilternRailProvider.combine_legs({:error, :boom}, arr) == arr
    end

    test "both legs failing is an error" do
      assert ChilternRailProvider.combine_legs({:error, :boom}, {:error, :other}) ==
               {:error, :boom}
    end
  end

  describe "disruptions?/0 and closures?/0" do
    test "neither concept exists yet for this source" do
      refute ChilternRailProvider.disruptions?()
      refute ChilternRailProvider.closures?()
    end
  end

  describe "id/0 and label/0" do
    test "names itself" do
      assert ChilternRailProvider.id() == :chiltern_rail
      assert ChilternRailProvider.label() == "Chiltern Railways"
    end
  end
end
