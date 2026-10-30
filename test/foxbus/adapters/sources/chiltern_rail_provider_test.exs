defmodule Foxbus.Adapters.Sources.ChilternRailProviderTest do
  use ExUnit.Case, async: true
  alias Foxbus.Adapters.Sources.ChilternRailProvider

  @now ~N[2026-10-30 10:00:00]

  defp service(fields) do
    """
    <lt7:service>
      <lt4:std>#{fields[:std] || "10:05"}</lt4:std>
      <lt4:etd>#{fields[:etd] || "On time"}</lt4:etd>
      <lt4:operatorCode>#{fields[:operator_code] || "CH"}</lt4:operatorCode>
      <lt7:destination>
        <lt4:location>
          <lt4:locationName>#{fields[:destination] || "London Marylebone"}</lt4:locationName>
          <lt4:crs>MYB</lt4:crs>
        </lt4:location>
      </lt7:destination>
    </lt7:service>
    """
  end

  defp board(services) do
    """
    <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
      <soap:Body>
        <GetDepartureBoardResponse xmlns="http://thalesgroup.com/RTTI/2021-11-01/ldb/">
          <GetStationBoardResult>
            <lt4:locationName>Amersham</lt4:locationName>
            <lt4:crs>AMR</lt4:crs>
            <lt7:trainServices>
              #{Enum.join(services)}
            </lt7:trainServices>
          </GetStationBoardResult>
        </GetDepartureBoardResponse>
      </soap:Body>
    </soap:Envelope>
    """
  end

  describe "parse_stop_id/1" do
    test "splits the origin and destination CRS codes" do
      assert ChilternRailProvider.parse_stop_id("AMR,MYB") == {:ok, {"AMR", "MYB"}}
    end

    test "a malformed stop_id is an error, not a crash" do
      assert ChilternRailProvider.parse_stop_id("AMR") == {:error, :invalid_stop_id}
      assert ChilternRailProvider.parse_stop_id(",MYB") == {:error, :invalid_stop_id}
      assert ChilternRailProvider.parse_stop_id("AMR,") == {:error, :invalid_stop_id}
    end
  end

  describe "parse_board/1" do
    test "reads std, etd, destination, and operator code from each service" do
      xml = board([service(std: "10:05", etd: "On time", destination: "London Marylebone")])

      assert [s] = ChilternRailProvider.parse_board(xml)

      assert s == %{
               std: {10, 5},
               etd: "On time",
               destination: "London Marylebone",
               operator_code: "CH"
             }
    end

    test "several services parse in document order" do
      xml = board([service(std: "10:05"), service(std: "10:35"), service(std: "11:05")])
      assert [a, b, c] = ChilternRailProvider.parse_board(xml)
      assert {a.std, b.std, c.std} == {{10, 5}, {10, 35}, {11, 5}}
    end

    test "a service with a malformed std is skipped, not a crash" do
      xml = board([service(std: "not-a-time"), service(std: "10:35")])
      assert [s] = ChilternRailProvider.parse_board(xml)
      assert s.std == {10, 35}
    end

    test "no services at all parses to an empty list" do
      assert ChilternRailProvider.parse_board(board([])) == []
    end
  end

  describe "to_arrival/2" do
    test "etd \"On time\" is live with zero delay, using std" do
      event = %{
        std: {10, 35},
        etd: "On time",
        destination: "London Marylebone",
        operator_code: "CH"
      }

      a = ChilternRailProvider.to_arrival(event, @now)

      assert {a.line, a.destination, a.status, a.delay_minutes, a.cancelled?} ==
               {"CH", "London Marylebone", :live, 0, false}

      assert {a.scheduled_time, a.eta_minutes} == {~T[10:35:00], 35}
    end

    test "a revised etd is live with the computed delay, and the displayed ETA follows it" do
      event = %{
        std: {10, 35},
        etd: "10:42",
        destination: "London Marylebone",
        operator_code: "CH"
      }

      a = ChilternRailProvider.to_arrival(event, @now)
      assert {a.status, a.delay_minutes, a.eta_minutes} == {:live, 7, 42}
    end

    test "a cancelled service stays scheduled against std, marked cancelled" do
      event = %{
        std: {11, 5},
        etd: "Cancelled",
        destination: "London Marylebone",
        operator_code: "CH"
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
        operator_code: "CH"
      }

      a = ChilternRailProvider.to_arrival(event, @now)
      assert {a.status, a.cancelled?, a.delay_minutes} == {:scheduled, false, nil}
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
