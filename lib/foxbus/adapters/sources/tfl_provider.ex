defmodule Foxbus.Adapters.Sources.TflProvider do
  @moduledoc """
  Scheduled Underground departures and line status from TfL's own Unified
  API (https://api.tfl.gov.uk), no scraping — a stop's `stop_id` is its TfL
  StopPoint id for the *Underground* platform specifically, not a rail
  station id — they can differ even at a joint station: Amersham's
  Underground StopPoint is `"940GZZLUAMS"`, not its National Rail id. Look
  one up at `https://api.tfl.gov.uk/StopPoint/Search/<name>`, then check
  `modes` includes `"tube"` on the result. `lines` (here and in
  `Foxbus.Config`) are TfL's own line *names* (`"Metropolitan"`, not the
  lowercase slug `"metropolitan"` the Timetable/Status endpoints actually
  take in their URL) — `line_id/1` derives the slug from the name for that
  internal use; every London Underground line name maps cleanly this way,
  including the "&" ones (`"Hammersmith & City"` -> `"hammersmith-city"`).

  **Why the scheduled timetable, not the live Arrivals feed**: checked live
  against a real terminus (Amersham) before building this — the Arrivals
  feed only ever lists trains *arriving* to terminate there (every
  prediction pointed north, into the station, not south towards London),
  each one duplicated once per platform it could use. There is no live feed
  of a terminus's own outbound departures; TfL's own suggestion for this is
  the scheduled timetable (`/Line/{line}/Timetable/{stop}`), matched against
  the time of day — which is what `fetch_arrivals/2` does, with
  `status: :scheduled` throughout. A live "that scheduled train is now N
  minutes out" overlay, blended in from the Arrivals feed, is a reasonable
  future enhancement but isn't built here.

  **Caching**: the timetable response is large (~130 KB — the whole day's
  journeys across every day-type) and this is a memory-constrained device,
  so it is never re-fetched on every poll. `fetch_arrivals/2` parses it down
  to a few dozen small `{hour, minute, destination}` tuples per weekday and
  caches that in `NestGen2.Storage`, refetching only once a calendar day
  (UK local date). Known simplification: a weekday public holiday still
  gets its ordinary weekday schedule, not a holiday one, since there's no
  holiday calendar here to check against.

  **Schedule names vary and can't be trusted as a fixed set of four**:
  confirmed live that `/Line/{line}/Timetable/{stop}` doesn't always use
  the obvious `"Monday - Thursday"` / `"Friday"` /
  `"Saturdays and Public Holidays"` / `"Sunday"` four-name shape — on one
  occasion it returned only `"Sunday"` (a TfL backend cache
  inconsistency), and on another, during what looks like a temporary
  engineering-work timetable, exactly `["Thursdays", "Tuesdays",
  "Wednesdays"]` with no `"Monday - Thursday"` at all. So instead of
  requiring a fixed set of names, `weekdays_covered/1` parses whatever
  name TfL sends (a range like `"Monday - Thursday"`, a single plural day
  like `"Tuesdays"`, `"Saturdays and Public Holidays"`, a bare `"Sunday"`,
  ...) into the set of weekdays it actually covers, and a response is only
  accepted and cached when some schedule in it covers *today's* specific
  weekday — not all seven, just today, since that's all a response is
  ever used for before the next day's refetch. The cache itself is keyed
  by weekday number (`Date.day_of_week/1`, 1 Monday .. 7 Sunday), not by
  TfL's schedule name, so a lookup never has to re-guess which of TfL's
  possibly-inconsistent names today falls under. A response that doesn't
  cover today is treated as a fetch error, and the previous day's stale
  cache (if any) is kept and reused rather than overwriting it with
  something worse — though if that stale cache doesn't have today's
  weekday either (a stale Friday cache on a Monday, say), it shows as no
  departures today rather than claiming to know.

  No stop-closure concept here (`closures?/0` is false) — TfL has line
  status, not a per-station "this stop is closed" notice.

  Needs a free TfL `app_key` (register at https://api-portal.tfl.gov.uk) —
  the API works unauthenticated too, just at a much lower rate limit (a few
  hundred requests a day, vs. hundreds a minute with a key). Read from the
  `TFL_APP_KEY` environment variable first (handy for a host run — see
  nest_gen2_sdk's host mode docs — so the key doesn't have to be copied
  into host Storage by hand; an empty value, not just unset, counts as "no
  key", since a dotfile that shells out to a password manager exports ""
  when it's logged out), then from `NestGen2.Storage`
  (`storage.sh foxbus put tfl_app_key '"<key>"'`). Never mix.exs — a key
  is a secret, and mix.exs is committed to a public repo. Neither set
  means unauthenticated.
  """

  @behaviour Foxbus.Ports.Provider

  alias Foxbus.Adapters.Sources.TflHttp
  alias Foxbus.Domain.Arrival
  alias NestGen2.Storage

  @base_url "https://api.tfl.gov.uk"
  @upcoming_count 3
  @weekday_names ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  @impl true
  def id, do: :tfl

  @impl true
  def label, do: "TfL"

  @impl true
  def disruptions?, do: true

  @impl true
  def closures?, do: false

  @impl true
  def fetch_arrivals(stop_id, lines) do
    lines
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case upcoming_departures(stop_id, line) do
        {:ok, arrivals} -> {:cont, {:ok, acc ++ arrivals}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp upcoming_departures(stop_id, line) do
    now = Foxbus.LondonTime.now()

    with {:ok, by_weekday} <- cached_schedules(stop_id, line) do
      weekday = Date.day_of_week(NaiveDateTime.to_date(now))
      now_minutes = now.hour * 60 + now.minute

      departures =
        by_weekday
        |> Map.get(weekday, [])
        |> next_departures(now_minutes)
        |> Enum.map(fn {hour, minute, destination} ->
          to_arrival(line, hour, minute, destination, now_minutes)
        end)

      {:ok, departures}
    end
  end

  @doc "Keeps only the next `@upcoming_count` departures at or after `now_minutes`."
  @spec next_departures([{non_neg_integer, non_neg_integer, String.t()}], non_neg_integer) ::
          [{non_neg_integer, non_neg_integer, String.t()}]
  def next_departures(departures, now_minutes) do
    departures
    |> Enum.filter(fn {hour, minute, _destination} -> hour * 60 + minute >= now_minutes end)
    |> Enum.take(@upcoming_count)
  end

  defp to_arrival(line, hour, minute, destination, now_minutes) do
    %Arrival{
      line: line,
      destination: destination,
      eta_minutes: max(hour * 60 + minute - now_minutes, 0),
      status: :scheduled,
      scheduled_time: Time.new!(hour, minute, 0)
    }
  end

  defp cached_schedules(stop_id, line) do
    key = cache_key(stop_id, line)
    today = NaiveDateTime.to_date(Foxbus.LondonTime.now())
    weekday = Date.day_of_week(today)
    cached = Storage.get(key, nil, app: :foxbus)

    case cached do
      %{fetched_on: ^today, by_weekday: by_weekday} ->
        {:ok, by_weekday}

      _stale_or_missing ->
        case fetch_and_parse_timetable(stop_id, line, weekday) do
          {:ok, by_weekday} ->
            Storage.put(key, %{fetched_on: today, by_weekday: by_weekday}, app: :foxbus)
            {:ok, by_weekday}

          {:error, _reason} = error ->
            case cached do
              %{by_weekday: by_weekday} -> {:ok, by_weekday}
              _no_previous_cache -> error
            end
        end
    end
  end

  # Storage keys are lowercase letters/digits/underscore only — stop_id is
  # already alnum, but line_id/1 can contain hyphens ("hammersmith-city").
  defp cache_key(stop_id, line) do
    slug = line |> line_id() |> String.replace("-", "_")
    "tfl_tt_" <> String.downcase(stop_id) <> "_" <> slug
  end

  defp fetch_and_parse_timetable(stop_id, line, weekday) do
    with {:ok, json} <- TflHttp.get(url("/Line/#{line_id(line)}/Timetable/#{stop_id}")) do
      schedules = parse_timetable(json)

      if covers_weekday?(schedules, weekday) do
        {:ok, expand_by_weekday(schedules)}
      else
        {:error, :incomplete_timetable}
      end
    end
  end

  @doc "True when some schedule in the response covers this weekday (1 Monday .. 7 Sunday)."
  @spec covers_weekday?(%{String.t() => list}, 1..7) :: boolean
  def covers_weekday?(schedules, weekday) do
    Enum.any?(schedules, fn {name, _departures} -> weekday in weekdays_covered(name) end)
  end

  @doc """
  `parse_timetable/1`'s result, re-keyed by weekday number (1 Monday .. 7
  Sunday) instead of TfL's own schedule name — see `weekdays_covered/1`.
  A schedule covering several weekdays (`"Monday - Thursday"`) appears
  under each of them; two schedules covering the same weekday (not seen
  live, but not impossible) have their departures merged and re-sorted
  rather than one silently winning.
  """
  @spec expand_by_weekday(%{String.t() => [{non_neg_integer, non_neg_integer, String.t()}]}) ::
          %{(1..7) => [{non_neg_integer, non_neg_integer, String.t()}]}
  def expand_by_weekday(schedules) do
    for {name, departures} <- schedules,
        weekday <- weekdays_covered(name),
        reduce: %{} do
      acc -> Map.update(acc, weekday, departures, &Enum.sort(&1 ++ departures))
    end
  end

  @doc """
  Which weekdays (1 Monday .. 7 Sunday) a TfL schedule name covers.
  Confirmed live that TfL doesn't use a fixed set of four names — seen so
  far: a range (`"Monday - Thursday"`), a single plural day
  (`"Tuesdays"`), a day plus trailing text (`"Saturdays and Public
  Holidays"`), and a bare singular (`"Sunday"`). A range is `"<day> -
  <day>"` inclusive of both ends; anything else is read as covering
  every weekday name found anywhere in it (substring match, so a plural
  like "Tuesdays" still matches "Tuesday") — a name matching no weekday
  at all (seen as impossible so far) covers none, rather than guessing.
  """
  @spec weekdays_covered(String.t()) :: MapSet.t(1..7)
  def weekdays_covered(name) do
    case String.split(name, " - ", parts: 2) do
      [left, right] ->
        with from when not is_nil(from) <- weekday_in_text(left),
             to when not is_nil(to) <- weekday_in_text(right),
             true <- from <= to do
          MapSet.new(from..to)
        else
          _ -> weekdays_in_text(name)
        end

      _ ->
        weekdays_in_text(name)
    end
  end

  defp weekday_in_text(text) do
    @weekday_names
    |> Enum.with_index(1)
    |> Enum.find_value(fn {day, n} -> if String.contains?(text, day), do: n end)
  end

  defp weekdays_in_text(text) do
    @weekday_names
    |> Enum.with_index(1)
    |> Enum.filter(fn {day, _n} -> String.contains?(text, day) end)
    |> Enum.map(fn {_day, n} -> n end)
    |> MapSet.new()
  end

  @doc """
  The timetable response's `schedules` (one per day-type, e.g.
  `"Monday - Thursday"`), each turned into a sorted list of
  `{hour, minute, destination}` — the destination resolved from that
  journey's own `stationIntervals` entry (the last, longest leg is where it
  terminates). Journeys TfL marks with an hour of 24 or more (the small
  hours of the *next* calendar day, still filed under this schedule) are
  dropped rather than handled with day-rollover logic — they're late-night
  trips, not normal viewing hours.
  """
  @spec parse_timetable(map) :: %{String.t() => [{non_neg_integer, non_neg_integer, String.t()}]}
  def parse_timetable(json) do
    names = station_names(json)
    destinations = route_destinations(json, names)

    json
    |> get_in(["timetable", "routes"])
    |> List.wrap()
    |> List.first(%{})
    |> Map.get("schedules", [])
    |> Map.new(fn schedule ->
      departures =
        schedule
        |> Map.get("knownJourneys", [])
        |> Enum.flat_map(&journey_departure(&1, destinations))
        |> Enum.sort()

      {Map.fetch!(schedule, "name"), departures}
    end)
  end

  defp station_names(json) do
    json
    |> Map.get("stations", [])
    |> Map.new(fn s -> {Map.fetch!(s, "id"), Map.fetch!(s, "name")} end)
  end

  defp route_destinations(json, names) do
    json
    |> get_in(["timetable", "routes"])
    |> List.wrap()
    |> List.first(%{})
    |> Map.get("stationIntervals", [])
    |> Map.new(fn interval ->
      destination =
        interval
        |> Map.get("intervals", [])
        |> Enum.max_by(&Map.get(&1, "timeToArrival", 0), fn -> nil end)
        |> case do
          nil -> "Unknown"
          %{"stopId" => stop_id} -> Map.get(names, stop_id, "Unknown")
        end

      {Map.fetch!(interval, "id"), destination}
    end)
  end

  defp journey_departure(journey, destinations) do
    hour = journey |> Map.fetch!("hour") |> String.to_integer()
    minute = journey |> Map.fetch!("minute") |> String.to_integer()

    if hour in 0..23 do
      interval_id = journey |> Map.fetch!("intervalId") |> Integer.to_string()
      [{hour, minute, Map.get(destinations, interval_id, "Unknown")}]
    else
      []
    end
  end

  @doc "See `Foxbus.Ports.DisruptionsSource` — present because disruptions?/0 is true."
  @spec disrupted?([String.t()], String.t()) :: {:ok, String.t() | nil} | {:error, term}
  def disrupted?(lines, _stop_id) do
    lines
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, nil}, fn line, _acc ->
      case line_status(line) do
        {:ok, nil} -> {:cont, {:ok, nil}}
        {:ok, reason} -> {:halt, {:ok, reason}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp line_status(line) do
    with {:ok, lines_json} <- TflHttp.get(url("/Line/#{line_id(line)}/Status")) do
      {:ok, parse_status(lines_json)}
    end
  end

  @doc false
  @spec parse_status([map]) :: String.t() | nil
  def parse_status(lines_json) do
    lines_json
    |> Enum.flat_map(&Map.get(&1, "lineStatuses", []))
    |> Enum.find_value(fn status ->
      if Map.get(status, "statusSeverityDescription") != "Good Service" do
        Map.get(status, "reason", "")
        |> case do
          "" -> Map.fetch!(status, "statusSeverityDescription")
          reason -> reason
        end
      end
    end)
  end

  @doc false
  @spec line_id(String.t()) :: String.t()
  def line_id(name) do
    name
    |> String.downcase()
    |> String.replace(" & ", "-")
    |> String.replace(~r/[^a-z0-9-]+/, "-")
  end

  defp url(path) do
    @base_url <> path <> app_key_query()
  end

  defp app_key_query do
    case app_key() do
      nil -> ""
      key -> "?app_key=#{URI.encode_www_form(key)}"
    end
  end

  @doc false
  # TFL_APP_KEY first (set, non-empty) — lets a host run pick up a key from
  # the environment (e.g. a password-manager export) without copying it
  # into host Storage — then Storage, same as always. Nothing sets the env
  # var on the Nest, so it always falls through to Storage there. Checked
  # empty, not just unset: a dotfile that shells out to a password manager
  # (`export TFL_APP_KEY="$(lpass show --password ...)"`) exports "" when
  # that's logged out, which should mean "no key", not "key is literally
  # the empty string".
  @spec app_key() :: String.t() | nil
  def app_key do
    case System.get_env("TFL_APP_KEY") do
      key when is_binary(key) and key != "" -> key
      _ -> Storage.get(:tfl_app_key, nil, app: :foxbus)
    end
  end
end
