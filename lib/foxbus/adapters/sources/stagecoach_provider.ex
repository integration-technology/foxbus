defmodule Foxbus.Adapters.Sources.StagecoachProvider do
  @moduledoc """
  Scheduled departures from Stagecoach's own `tis/v3/stop-event-query`
  endpoint — found (21-22 Oct) after an earlier version of this module,
  built on `adc/stop-monitor` (SIRI Stop Monitoring), turned out to only
  ever return the *next* call per line: fine for "is my bus coming", no
  good for a departure board that should show the rest of today and the
  first one tomorrow, the way Stagecoach's own app and `/maps` page do.
  Watching that page's own network traffic (the same technique used to
  find `adc/stop-monitor` in the first place — see
  `Foxbus.Adapters.Sources.StagecoachHttp`'s moduledoc for the full
  unofficial-API reasoning, unchanged here) showed it actually fires
  *two* requests: `stop-monitor` for a live top-of-list, and
  `stop-event-query` for the fuller schedule. This module only uses the
  second — blending in `stop-monitor`'s live/delay data for the nearest
  departure is a reasonable future enhancement, not built now.

  **`stop_id` is `"<latitude>,<longitude>,<stopLabel>"`**, not just a
  `stopLabel` — confirmed live that this endpoint takes a geocode and a
  walk distance (`NearbyPlaces`/`Walking`), not a stop id, and rejects a
  `stopLabel`-only request body outright (a clean `400`, not a quiet
  ignore). That's because it's built for "what's near this point", not
  "what's at this stop" — it genuinely returns events for *every* stop
  within `MaxWalkDistance`, e.g. both of Murthly's opposite-direction
  stops at once, 11 m apart, from either one's own coordinates. So
  `fetch_arrivals/2` requests a small radius (`@walk_distance_metres`)
  around the given point and then keeps only the events whose own
  `StopLabel` matches the third part of `stop_id` — same opaque-string
  convention every other provider's `stop_id` already uses (an ATCO code
  for Carousel, a TfL StopPoint for TfL, a bustimes.org numeric id for
  `:bustimes`), just carrying more than one value here because the API
  itself needs more than one value to answer "what's at this exact stop".
  The lat/lon for a configured stop comes straight from a real API
  response (`tis/v3/service-timetable-query`'s own `Stop.Geocode`, or
  this endpoint's own `Stops.Stop[].Geocode`), not guessed.

  `lines` is accepted but unused in the request — this endpoint has no
  per-service filter (confirmed live: it isn't part of the schema
  `stop-event-query` accepts), so every service calling at the resolved
  stop comes back and `Foxbus.Arrivals`' own central line filtering
  narrows it down afterwards, same as `:carousel`/`:bustimes` already do.

  No disruption or stop-closure concept implemented here yet — a first
  cut, same minimal pattern as `Foxbus.Adapters.Sources.BustimesProvider`.
  No caching: the response is small and the window is wide, so it's cheap
  to refetch every poll.
  """

  @behaviour Foxbus.Ports.Provider

  alias Foxbus.Adapters.Sources.StagecoachHttp
  alias Foxbus.Domain.Arrival
  alias Foxbus.LondonTime

  # Covers the rest of today plus some of tomorrow, matching what
  # Stagecoach's own app shows for a stop (confirmed live: it listed
  # several more today and one early departure the next day).
  @look_ahead_minutes 1440
  @max_later_events 40
  # Murthly's two stops are 11 m apart (confirmed live); this just needs
  # to comfortably clear that without reaching into an unrelated stop
  # further down the road.
  @walk_distance_metres 50

  @impl true
  def id, do: :stagecoach

  @impl true
  def label, do: "Stagecoach"

  @impl true
  def disruptions?, do: false

  @impl true
  def closures?, do: false

  @impl true
  def fetch_arrivals(stop_id, _lines) do
    with {:ok, {lat, lon, stop_label}} <- parse_stop_id(stop_id),
         {:ok, json} <-
           StagecoachHttp.post("/tis/v3/stop-event-query", stop_event_request(lat, lon)) do
      {:ok, parse_stop_events(json, stop_label, LondonTime.now())}
    end
  end

  @doc false
  @spec parse_stop_id(String.t()) ::
          {:ok, {float, float, String.t()}} | {:error, :invalid_stop_id}
  def parse_stop_id(stop_id) do
    with [lat_s, lon_s, stop_label] <- String.split(stop_id, ",", parts: 3),
         {lat, ""} <- Float.parse(lat_s),
         {lon, ""} <- Float.parse(lon_s) do
      {:ok, {lat, lon, stop_label}}
    else
      _ -> {:error, :invalid_stop_id}
    end
  end

  defp stop_event_request(lat, lon) do
    %{
      "NearbyPlaces" => %{
        "Place" => [
          %{
            "Geocode" => %{"Grid" => %{"value" => "WGS84"}, "Longitude" => lon, "Latitude" => lat}
          }
        ]
      },
      "Restrictions" => %{"SingleEventPerTrip" => true},
      "Walking" => %{"MaxWalkDistance" => @walk_distance_metres},
      "Departure" => %{
        "TargetDepartureTime" => %{"value" => DateTime.to_iso8601(DateTime.utc_now())},
        "EarliestDepartureLeeway" => "PT0M",
        "LatestDepartureLeeway" => "PT#{@look_ahead_minutes}M"
      },
      "ResponseCharacteristics" => %{
        "MaxLaterEvents" => %{"value" => @max_later_events},
        "StopCoordinates" => false,
        "GenerateKML" => false
      },
      "RequestId" => "foxbus"
    }
  end

  @doc false
  # `now` is UK local time; passed in so parsing is testable.
  @spec parse_stop_events(map, String.t(), NaiveDateTime.t()) :: [Arrival.t()]
  def parse_stop_events(json, stop_label, now) do
    json
    |> get_in(["Events", "Event"])
    |> List.wrap()
    |> Enum.filter(&(Map.get(&1, "StopLabel") == stop_label))
    |> Enum.flat_map(&to_arrival(&1, now))
  end

  defp to_arrival(event, now) do
    with iso when is_binary(iso) <- get_in(event, ["ScheduledDepartureTime", "value"]),
         {:ok, utc, _offset} <- DateTime.from_iso8601(iso),
         line when is_binary(line) <- get_in(event, ["Trip", "Service", "ServiceNumber"]),
         destination when is_binary(destination) <- get_in(event, ["Trip", "DestinationBoard"]) do
      local = LondonTime.to_local(utc)
      eta = max(div(NaiveDateTime.diff(local, now, :second), 60), 0)

      day =
        if Date.compare(NaiveDateTime.to_date(local), NaiveDateTime.to_date(now)) == :gt,
          do: :tomorrow,
          else: :today

      [
        %Arrival{
          line: line,
          destination: destination,
          eta_minutes: eta,
          # Truncated: the API's own fractional-second precision (e.g.
          # "16:25:00.000") would otherwise leak into a Time struct that
          # compares unequal to a plain ~T[16:25:00] despite meaning the
          # same instant.
          scheduled_time: local |> NaiveDateTime.to_time() |> Time.truncate(:second),
          day: day,
          status: :scheduled
        }
      ]
    else
      _ -> []
    end
  end
end
