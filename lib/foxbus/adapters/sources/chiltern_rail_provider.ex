defmodule Foxbus.Adapters.Sources.ChilternRailProvider do
  @moduledoc """
  Live Chiltern Railways departures from National Rail's own Darwin feed
  (OpenLDBWS, via `Foxbus.Adapters.Sources.ChilternRailHttp`) — the genuine
  live board (estimated/actual times, cancellations), not a static
  timetable, unlike `Foxbus.Adapters.Sources.TflProvider`.

  **`stop_id` is `"<origin CRS>,<destination CRS>"`**, e.g. `"AMR,MYB"` for
  Amersham towards Marylebone — not just an origin station, because
  OpenLDBWS' `GetDepartureBoardRequest` needs a destination to filter by
  (`filterCrs`/`filterType: "to"`) to get only the services actually
  heading that way, the same reason `Foxbus.Adapters.Sources.StagecoachProvider`'s
  `stop_id` carries more than one value. CRS codes are National Rail's own
  three-letter station codes (Amersham `AMR`, Marylebone `MYB`) — look one
  up at https://www.nationalrail.co.uk/stations/ or in the OpenLDBWS docs.

  `lines` is accepted but unused — Amersham's main line has exactly one
  operator (Chiltern Railways), so there is nothing to filter by; every
  row's `line` is instead the response's own `operatorCode` ("CH").

  A cancelled service is kept, not dropped, same as
  `StagecoachProvider` — `cancelled?: true`, scheduled time preserved. An
  `etd` of a specific revised time is read as live with the computed delay;
  "On time" is live with zero delay; a generic "Delayed" (no specific
  revised time given) and anything unrecognised stay `:scheduled` against
  the original time instead of guessing a delay that isn't in the response.

  No disruption or stop-closure concept here yet (`disruptions?/0`/
  `closures?/0` both false) — a first cut, same minimal pattern every other
  provider here started from. No caching: OpenLDBWS responses are small,
  cheap to refetch every poll, same as `StagecoachProvider`.

  **Unverified against live data** — see
  `Foxbus.Adapters.Sources.ChilternRailHttp`'s moduledoc: built from the
  published OpenLDBWS schema, not checked against a real response yet
  (there was no Rail Data Marketplace token to test with). Confirm the
  parsing here against a real captured response once there is one, the
  same way every other provider in this codebase was checked live before
  being trusted.
  """

  @behaviour Foxbus.Ports.Provider

  alias Foxbus.Adapters.Sources.ChilternRailHttp
  alias Foxbus.Domain.Arrival

  @num_rows 10

  @impl true
  def id, do: :chiltern_rail

  @impl true
  def label, do: "Chiltern Railways"

  @impl true
  def disruptions?, do: false

  @impl true
  def closures?, do: false

  @impl true
  def fetch_arrivals(stop_id, _lines) do
    with {:ok, {origin, destination}} <- parse_stop_id(stop_id),
         {:ok, xml} <- ChilternRailHttp.post(request_xml(origin, destination)) do
      now = Foxbus.LondonTime.now()
      {:ok, xml |> parse_board() |> Enum.map(&to_arrival(&1, now))}
    end
  end

  @doc false
  @spec parse_stop_id(String.t()) :: {:ok, {String.t(), String.t()}} | {:error, :invalid_stop_id}
  def parse_stop_id(stop_id) do
    case String.split(stop_id, ",", parts: 2) do
      [origin, destination] when origin != "" and destination != "" ->
        {:ok, {origin, destination}}

      _ ->
        {:error, :invalid_stop_id}
    end
  end

  defp request_xml(origin, destination) do
    """
    <GetDepartureBoardRequest xmlns="http://thalesgroup.com/RTTI/2021-11-01/ldb/">
      <numRows>#{@num_rows}</numRows>
      <crs>#{origin}</crs>
      <filterCrs>#{destination}</filterCrs>
      <filterType>to</filterType>
    </GetDepartureBoardRequest>
    """
  end

  @doc false
  # Each <service>...</service> block parsed to its std/etd/destination/
  # operatorCode — a block missing std or a destination name is skipped
  # rather than crashing the whole board.
  @spec parse_board(String.t()) :: [map]
  def parse_board(xml) do
    ~r/<(?:[\w]+:)?service>(.*?)<\/(?:[\w]+:)?service>/s
    |> Regex.scan(xml)
    |> Enum.map(fn [_, block] -> parse_service(block) end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_service(block) do
    with std when not is_nil(std) <- tag(block, "std"),
         {:ok, std_hm} <- parse_hhmm(std),
         destination when not is_nil(destination) <- destination_name(block) do
      %{
        std: std_hm,
        etd: tag(block, "etd") || "On time",
        destination: destination,
        operator_code: tag(block, "operatorCode") || "CH"
      }
    else
      _ -> nil
    end
  end

  defp destination_name(block) do
    case Regex.run(~r/<(?:[\w]+:)?destination>(.*?)<\/(?:[\w]+:)?destination>/s, block) do
      [_, dest_block] -> tag(dest_block, "locationName")
      nil -> nil
    end
  end

  defp tag(xml, name) do
    case Regex.run(~r/<(?:[\w]+:)?#{name}>([^<]*)<\/(?:[\w]+:)?#{name}>/, xml) do
      [_, value] -> value
      nil -> nil
    end
  end

  @doc false
  # `now` is UK local time; passed in so parsing is testable.
  @spec to_arrival(map, NaiveDateTime.t()) :: Arrival.t()
  def to_arrival(
        %{std: {std_hour, std_minute}, etd: etd, destination: destination, operator_code: line},
        now
      ) do
    now_minutes = now.hour * 60 + now.minute
    std_total = std_hour * 60 + std_minute

    {status, delay_minutes, cancelled?, display_total} = enrich(etd, std_total)

    %Arrival{
      line: line,
      destination: destination,
      eta_minutes: max(display_total - now_minutes, 0),
      status: status,
      delay_minutes: delay_minutes,
      scheduled_time: Time.new!(std_hour, std_minute, 0),
      cancelled?: cancelled?
    }
  end

  defp enrich("On time", std_total), do: {:live, 0, false, std_total}
  defp enrich("Cancelled", std_total), do: {:scheduled, nil, true, std_total}

  defp enrich(etd, std_total) do
    case parse_hhmm(etd) do
      {:ok, {hour, minute}} ->
        total = hour * 60 + minute
        {:live, total - std_total, false, total}

      :error ->
        {:scheduled, nil, false, std_total}
    end
  end

  defp parse_hhmm(hhmm) do
    case Regex.run(~r/^(\d{2}):(\d{2})$/, hhmm) do
      [_, hour, minute] -> {:ok, {String.to_integer(hour), String.to_integer(minute)}}
      nil -> :error
    end
  end
end
