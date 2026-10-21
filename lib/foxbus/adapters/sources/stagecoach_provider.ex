defmodule Foxbus.Adapters.Sources.StagecoachProvider do
  @moduledoc """
  Live departures from Stagecoach's own real-time API
  (`api.stagecoachbus.com/adc/stop-monitor`) — SIRI Stop Monitoring under
  the hood (`StopMonitorRequest`/`monitoredCall`), genuinely live: each
  call carries both an `aimed` and an `expected` time, so a real delay
  shows, not just a scheduled guess.

  **This is an unofficial source** — see
  `Foxbus.Adapters.Sources.StagecoachHttp`'s moduledoc for the full
  reasoning. In short: the `X-SC-apiKey` isn't issued to this project, it
  was found embedded in stagecoachbus.com's own public website JavaScript
  by patching `window.fetch`/`XMLHttpRequest` in a real browser session
  and watching what the live page itself sent, then confirmed by curl.
  No developer docs exist for this endpoint as far as we could find. Built
  anyway, on Owain's own explicit decision, to see how long it keeps
  working — if it breaks (the key is rotated, the shape changes, the
  endpoint starts requiring something this doesn't send), `fetch_arrivals/2`
  just returns `{:error, _}` like any other failed fetch and the poller's
  existing backoff (see `Foxbus.Adapters.Schedulers.AdaptiveBusPoller`)
  handles it the same as a TfL or Carousel outage — no special handling
  needed here for that.

  `stop_id` is Stagecoach's own `stopPointLabel` — confirmed live (21 Oct)
  that this is the *same* numeric id bustimes.org uses for the same stop
  (e.g. Murthly, Primary School is `"64803547"` on both), found this time
  by digging into the much larger `tis/v3/service-timetable-query`
  response rather than guessing.

  **`servicesFilters` is required** on every request (see `StagecoachHttp`)
  — `fetch_arrivals/2` always builds it from `lines`, as an empty list
  when `lines` is `[]`, rather than ever omitting the field.

  No disruption or stop-closure concept implemented here yet — a first
  cut, same minimal-first pattern as `Foxbus.Adapters.Sources.BustimesProvider`.
  A cancelled call (`"cancelled": true`) is dropped rather than shown,
  since `Foxbus.Domain.Arrival` has no way to mark one as cancelled yet.
  No caching, unlike `TflProvider`: each response is a handful of calls
  for one stop, not a whole-day timetable, so it's cheap to refetch every
  poll, same as Carousel/bustimes.org.
  """

  @behaviour Foxbus.Ports.Provider

  alias Foxbus.Adapters.Sources.StagecoachHttp
  alias Foxbus.Domain.Arrival
  alias Foxbus.LondonTime

  @look_ahead_minutes 120

  @impl true
  def id, do: :stagecoach

  @impl true
  def label, do: "Stagecoach"

  @impl true
  def disruptions?, do: false

  @impl true
  def closures?, do: false

  @impl true
  def fetch_arrivals(stop_id, lines) do
    with {:ok, json} <-
           StagecoachHttp.post("/adc/stop-monitor", stop_monitor_request(stop_id, lines)) do
      {:ok, parse_stop_monitor(json, LondonTime.now())}
    end
  end

  defp stop_monitor_request(stop_id, lines) do
    %{
      "StopMonitorRequest" => %{
        "header" => %{"retailOperation" => "", "channel" => "", "ipAddress" => ""},
        "lookAheadMinutes" => @look_ahead_minutes,
        "stopMonitorQueries" => %{
          "stopMonitorQuery" => [
            %{
              "stopPointLabel" => stop_id,
              "servicesFilters" => %{
                "servicesFilter" => Enum.map(lines, &%{"filter" => &1})
              }
            }
          ]
        }
      }
    }
  end

  @doc false
  # `now` is UK local time; passed in so parsing is testable.
  @spec parse_stop_monitor(map, NaiveDateTime.t()) :: [Arrival.t()]
  def parse_stop_monitor(json, now) do
    json
    |> get_in(["stopMonitors", "stopMonitor"])
    |> List.wrap()
    |> Enum.flat_map(fn monitor -> get_in(monitor, ["monitoredCalls", "monitoredCall"]) || [] end)
    |> Enum.flat_map(&to_arrival(&1, now))
  end

  defp to_arrival(%{"cancelled" => true}, _now), do: []

  defp to_arrival(call, now) do
    case departure_time(call) do
      nil ->
        []

      utc ->
        local = LondonTime.to_local(utc)
        eta = max(div(NaiveDateTime.diff(local, now, :second), 60), 0)

        day =
          if Date.compare(NaiveDateTime.to_date(local), NaiveDateTime.to_date(now)) == :gt,
            do: :tomorrow,
            else: :today

        [
          %Arrival{
            line: Map.fetch!(call, "lineRef"),
            destination: Map.fetch!(call, "destinationDisplay"),
            eta_minutes: eta,
            scheduled_time: NaiveDateTime.to_time(local),
            day: day,
            status: if(Map.has_key?(call, "expectedDepartureTime"), do: :live, else: :scheduled)
          }
        ]
    end
  end

  # Prefer the live "expected" time; fall back to the scheduled "aimed"
  # one when this call isn't being tracked live right now.
  defp departure_time(call) do
    (Map.get(call, "expectedDepartureTime") || Map.get(call, "aimedDepartureTime"))
    |> case do
      nil ->
        nil

      iso ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _offset} -> dt
          _ -> nil
        end
    end
  end
end
