defmodule Foxbus.Adapters.Sources.StagecoachProvider do
  @moduledoc """
  Stagecoach's own `tis/v3/stop-event-query` (the full day's schedule)
  blended with `adc/stop-monitor` (live delay and cancellation, for
  whichever of those scheduled departures are currently being tracked).
  Both are unofficial — see `Foxbus.Adapters.Sources.StagecoachHttp`'s
  moduledoc for the full reasoning, unchanged here.

  **Why two endpoints, not one.** The first version of this module used
  `stop-monitor` alone and found it only ever returns the *next* call per
  line — fine for "is my bus coming", no good for a departure board that
  should show the rest of today and the first one tomorrow, the way
  Stagecoach's own app and `/maps` page do. Rebuilt on `stop-event-query`
  for that, which fixed the coverage but lost the live delay/cancellation
  data `stop-monitor` had (`stop-event-query` is schedule-only). Owain
  wanted both, so `fetch_arrivals/2` now calls both and merges them: a
  scheduled event's own `aimedDepartureTime` and a `stop-monitor` call's
  `aimedDepartureTime` should name the exact same instant for the same
  physical departure (both come from the same underlying schedule), so
  `{line, aimed instant}` is the join key — confirmed live that TripId
  (`stop-event-query`) and `datedVehicleJourneyRef` (`stop-monitor`) use
  unrelated numbering, so those can't be matched directly. A scheduled
  event with no matching live call just stays `:scheduled`, unenriched
  — `stop-monitor` only ever covers the near-term few, same as before.
  If the live fetch itself fails, the scheduled list is still returned
  rather than failing the whole poll — losing the live overlay for one
  poll is a much smaller problem than losing the board.

  **`stop_id` is `"<latitude>,<longitude>,<stopLabel>"`**, not just a
  `stopLabel` — confirmed live that `stop-event-query` takes a geocode
  and a walk distance (`NearbyPlaces`/`Walking`), not a stop id, and
  rejects a `stopLabel`-only request body outright (a clean `400`, not a
  quiet ignore). That's because it's built for "what's near this point",
  not "what's at this stop" — it genuinely returns events for *every*
  stop within `MaxWalkDistance`, e.g. both of Murthly's opposite-direction
  stops at once, 11 m apart, from either one's own coordinates. So
  `fetch_arrivals/2` requests a small radius (`@walk_distance_metres`)
  around the given point and keeps only the events whose own `StopLabel`
  matches the third part of `stop_id` — same opaque-string convention
  every other provider's `stop_id` already uses (an ATCO code for
  Carousel, a TfL StopPoint for TfL, a bustimes.org numeric id for
  `:bustimes`), just carrying more than one value here because the API
  itself needs more than one value to answer "what's at this exact stop".
  `stop-monitor`, unlike `stop-event-query`, *does* take a plain
  `stopLabel`, so it's queried with just the third part.

  `lines` is accepted but unused in both requests — neither endpoint has
  a working per-service filter that returns anything beyond the exact
  services given (confirmed live for `stop-event-query`; `stop-monitor`
  does accept `servicesFilters`, which is why the previous version used
  it, but Owain asked to drop the route filter entirely, and an empty
  filter list was confirmed live to return everything rather than
  nothing) — `Foxbus.Arrivals`' own central line filtering narrows the
  result down afterwards instead, same as `:carousel`/`:bustimes`.

  A cancelled call is kept, not dropped — shown with
  `cancelled?: true`, which `Foxbus.Domain.Arrival.eta_text/1` renders as
  "Cancelled" in place of a time, and which `Foxbus.Screens.Layout.mode/2`
  skips when deciding whether to show the big countdown screen, so a
  cancelled soonest bus doesn't tick down as if it were still coming.

  No disruption or stop-closure concept implemented here yet — a first
  cut, same minimal pattern as `Foxbus.Adapters.Sources.BustimesProvider`.
  No caching: both responses are small, so it's cheap to refetch every
  poll.
  """

  @behaviour Foxbus.Ports.Provider

  alias Foxbus.Adapters.Sources.StagecoachHttp
  alias Foxbus.Domain.Arrival
  alias Foxbus.LondonTime

  # Covers the rest of today plus some of tomorrow, matching what
  # Stagecoach's own app shows for a stop (confirmed live: it listed
  # several more today and one early departure the next day).
  @schedule_look_ahead_minutes 1440
  @max_later_events 40
  # Murthly's two stops are 11 m apart (confirmed live); this just needs
  # to comfortably clear that without reaching into an unrelated stop
  # further down the road.
  @walk_distance_metres 50
  # stop-monitor only ever covers the near term anyway (see moduledoc),
  # so this just needs to be wide enough to catch everything it would
  # ever return, not to match the schedule's own much wider window.
  @monitor_look_ahead_minutes 180

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
         {:ok, event_json} <-
           StagecoachHttp.post("/tis/v3/stop-event-query", stop_event_request(lat, lon)) do
      events = parse_events(event_json, stop_label)
      live_calls = fetch_live_calls(stop_label)
      now = LondonTime.now()

      arrivals =
        events
        |> merge_live(live_calls)
        |> Enum.map(&to_arrival(&1, now))

      {:ok, arrivals}
    end
  end

  # Best-effort: a failed live fetch means no delay/cancellation overlay
  # this poll, not a failed board — see moduledoc.
  defp fetch_live_calls(stop_label) do
    case StagecoachHttp.post("/adc/stop-monitor", stop_monitor_request(stop_label)) do
      {:ok, json} -> parse_live_calls(json)
      {:error, _reason} -> []
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
        "LatestDepartureLeeway" => "PT#{@schedule_look_ahead_minutes}M"
      },
      "ResponseCharacteristics" => %{
        "MaxLaterEvents" => %{"value" => @max_later_events},
        "StopCoordinates" => false,
        "GenerateKML" => false
      },
      "RequestId" => "foxbus"
    }
  end

  defp stop_monitor_request(stop_label) do
    %{
      "StopMonitorRequest" => %{
        "header" => %{"retailOperation" => "", "channel" => "", "ipAddress" => ""},
        "lookAheadMinutes" => @monitor_look_ahead_minutes,
        "stopMonitorQueries" => %{
          "stopMonitorQuery" => [
            %{"stopPointLabel" => stop_label, "servicesFilters" => %{"servicesFilter" => []}}
          ]
        }
      }
    }
  end

  @doc false
  @spec parse_events(map, String.t()) :: [map]
  def parse_events(json, stop_label) do
    json
    |> get_in(["Events", "Event"])
    |> List.wrap()
    |> Enum.filter(&(Map.get(&1, "StopLabel") == stop_label))
    |> Enum.flat_map(&parse_event/1)
  end

  defp parse_event(event) do
    with iso when is_binary(iso) <- get_in(event, ["ScheduledDepartureTime", "value"]),
         {:ok, utc, _offset} <- DateTime.from_iso8601(iso),
         line when is_binary(line) <- get_in(event, ["Trip", "Service", "ServiceNumber"]),
         destination when is_binary(destination) <- get_in(event, ["Trip", "DestinationBoard"]) do
      [%{line: line, destination: destination, scheduled_utc: utc}]
    else
      _ -> []
    end
  end

  @doc false
  @spec parse_live_calls(map) :: [map]
  def parse_live_calls(json) do
    json
    |> get_in(["stopMonitors", "stopMonitor"])
    |> List.wrap()
    |> Enum.flat_map(fn monitor -> get_in(monitor, ["monitoredCalls", "monitoredCall"]) || [] end)
    |> Enum.flat_map(&parse_live_call/1)
  end

  defp parse_live_call(call) do
    with line when is_binary(line) <- Map.get(call, "lineRef"),
         aimed when is_binary(aimed) <- Map.get(call, "aimedDepartureTime"),
         {:ok, aimed_utc, _offset} <- DateTime.from_iso8601(aimed) do
      [
        %{
          line: line,
          aimed_utc: aimed_utc,
          expected_utc: parse_iso(Map.get(call, "expectedDepartureTime")),
          cancelled: Map.get(call, "cancelled", false)
        }
      ]
    else
      _ -> []
    end
  end

  defp parse_iso(nil), do: nil

  defp parse_iso(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  @doc false
  # Enriches each scheduled event with :status/:delay_minutes/:cancelled?/
  # :display_utc from the matching live call, if any — see moduledoc for
  # the {line, aimed instant} join key.
  @spec merge_live([map], [map]) :: [map]
  def merge_live(events, live_calls) do
    live_by_key = Map.new(live_calls, &{live_key(&1.line, &1.aimed_utc), &1})

    Enum.map(events, fn event ->
      case Map.get(live_by_key, live_key(event.line, event.scheduled_utc)) do
        nil ->
          scheduled(event)

        %{cancelled: true} ->
          event |> scheduled() |> Map.put(:cancelled?, true)

        %{expected_utc: nil} ->
          Map.merge(event, %{
            status: :live,
            delay_minutes: 0,
            cancelled?: false,
            display_utc: event.scheduled_utc
          })

        %{expected_utc: expected, aimed_utc: aimed} ->
          delay = div(DateTime.diff(expected, aimed, :second), 60)

          Map.merge(event, %{
            status: :live,
            delay_minutes: delay,
            cancelled?: false,
            display_utc: expected
          })
      end
    end)
  end

  defp scheduled(event),
    do:
      Map.merge(event, %{
        status: :scheduled,
        delay_minutes: nil,
        cancelled?: false,
        display_utc: event.scheduled_utc
      })

  defp live_key(line, utc), do: {line, DateTime.truncate(utc, :second)}

  @doc false
  # `now` is UK local time; passed in so parsing is testable.
  @spec to_arrival(map, NaiveDateTime.t()) :: Arrival.t()
  def to_arrival(event, now) do
    local = LondonTime.to_local(event.display_utc)
    eta = max(div(NaiveDateTime.diff(local, now, :second), 60), 0)

    day =
      if Date.compare(NaiveDateTime.to_date(local), NaiveDateTime.to_date(now)) == :gt,
        do: :tomorrow,
        else: :today

    %Arrival{
      line: event.line,
      destination: event.destination,
      eta_minutes: eta,
      # Truncated: the API's own fractional-second precision (e.g.
      # "16:25:00.000") would otherwise leak into a Time struct that
      # compares unequal to a plain ~T[16:25:00] despite meaning the
      # same instant.
      scheduled_time: local |> NaiveDateTime.to_time() |> Time.truncate(:second),
      day: day,
      status: event.status,
      delay_minutes: event.delay_minutes,
      cancelled?: event.cancelled?
    }
  end
end
