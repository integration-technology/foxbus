defmodule Foxbus.Adapters.Sources.ChilternRailProvider do
  @moduledoc """
  Live Chiltern Railways departures from National Rail's own Darwin feed
  (OpenLDBWS, via `Foxbus.Adapters.Sources.ChilternRailHttp`) — the genuine
  live board (estimated/actual times, cancellations), not a static
  timetable, unlike `Foxbus.Adapters.Sources.TflProvider`.

  **This replaces this module's first cut**, which parsed a SOAP/XML
  response with regexes. The live OpenLDBWS is REST/JSON (see
  `ChilternRailHttp`'s moduledoc) — `parse_board/1`/`parse_service/1` now
  read the decoded JSON body's `trainServices` list directly, and a
  service's own `isCancelled` boolean is used instead of inferring
  cancellation from `etd` text.

  **`stop_id` is `"<origin CRS>,<destination CRS>"`**, e.g. `"AMR,MYB"` for
  Amersham towards Marylebone — not just an origin station, because
  `GetDepartureBoard`'s `filterCrs`/`filterType=to` needs a destination to
  filter by to get only the services actually heading that way, the same
  reason `Foxbus.Adapters.Sources.StagecoachProvider`'s `stop_id` carries
  more than one value. CRS codes are National Rail's own three-letter
  station codes (Amersham `AMR`, Marylebone `MYB`) — look one up at
  https://www.nationalrail.co.uk/stations/ or in the OpenLDBWS docs.

  `lines` is accepted but unused — Amersham's main line has exactly one
  operator (Chiltern Railways), so there is nothing to filter by; every
  row's `line` is instead the response's own `operatorCode` ("CH").

  A cancelled service is kept, not dropped, same as
  `StagecoachProvider` — `cancelled?: true` (from the response's own
  `isCancelled`), scheduled time preserved. A specific revised `etd` is
  read as live with the computed delay; "On time" is live with zero
  delay; anything else unrecognised (a generic "Delayed" with no revised
  time, say) stays `:scheduled` against the original time instead of
  guessing a delay that isn't in the response.

  No disruption or stop-closure concept here yet (`disruptions?/0`/
  `closures?/0` both false) — a first cut, same minimal pattern every other
  provider here started from. No caching: OpenLDBWS responses are small,
  cheap to refetch every poll, same as `StagecoachProvider`.

  **Verified against a real response** (2026-11-02, Amersham → Marylebone,
  via a real Rail Data Marketplace API key) — `parse_board/1` and
  `to_arrival/2` here match the live shape as-is; only
  `Foxbus.Adapters.Sources.ChilternRailHttp`'s request (base URL and auth)
  needed fixing, see its moduledoc.
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
         {:ok, body} <- ChilternRailHttp.get_departure_board(origin, destination, @num_rows) do
      now = Foxbus.LondonTime.now()
      {:ok, body |> parse_board() |> Enum.map(&to_arrival(&1, now))}
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

  @doc false
  # Each entry of the decoded body's `trainServices` parsed to its
  # std/etd/destination/operatorCode/isCancelled — an entry missing std or
  # a destination name is skipped rather than crashing the whole board.
  @spec parse_board(map) :: [map]
  def parse_board(%{"trainServices" => services}) when is_list(services) do
    services |> Enum.map(&parse_service/1) |> Enum.reject(&is_nil/1)
  end

  def parse_board(_), do: []

  defp parse_service(%{"std" => std} = service) when is_binary(std) do
    with {:ok, std_hm} <- parse_hhmm(std),
         destination when not is_nil(destination) <- destination_name(service) do
      %{
        std: std_hm,
        etd: service["etd"] || "On time",
        destination: destination,
        operator_code: service["operatorCode"] || "CH",
        cancelled?: service["isCancelled"] == true
      }
    else
      _ -> nil
    end
  end

  defp parse_service(_), do: nil

  defp destination_name(%{"destination" => [%{"locationName" => name} | _]}), do: name
  defp destination_name(_), do: nil

  @doc false
  # `now` is UK local time; passed in so parsing is testable.
  @spec to_arrival(map, NaiveDateTime.t()) :: Arrival.t()
  def to_arrival(
        %{
          std: {std_hour, std_minute},
          etd: etd,
          destination: destination,
          operator_code: line,
          cancelled?: cancelled?
        },
        now
      ) do
    now_minutes = now.hour * 60 + now.minute
    std_total = std_hour * 60 + std_minute

    {status, delay_minutes, display_total} = enrich(etd, std_total, cancelled?)

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

  defp enrich(_etd, std_total, true), do: {:scheduled, nil, std_total}
  defp enrich("On time", std_total, false), do: {:live, 0, std_total}

  defp enrich(etd, std_total, false) do
    case parse_hhmm(etd) do
      {:ok, {hour, minute}} ->
        total = hour * 60 + minute
        {:live, total - std_total, total}

      :error ->
        {:scheduled, nil, std_total}
    end
  end

  defp parse_hhmm(hhmm) do
    case Regex.run(~r/^(\d{2}):(\d{2})$/, hhmm) do
      [_, hour, minute] -> {:ok, {String.to_integer(hour), String.to_integer(minute)}}
      nil -> :error
    end
  end
end
