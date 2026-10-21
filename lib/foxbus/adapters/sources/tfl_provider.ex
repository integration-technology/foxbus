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
  to a few dozen small `{hour, minute, destination}` tuples per day-type and
  caches that in `NestGen2.Storage`, refetching only once a calendar day
  (UK local date). Known simplification: the day-type (`"Monday - Thursday"`
  / `"Friday"` / `"Saturdays and Public Holidays"` / `"Sunday"`) is chosen
  from the day of the week alone — a weekday public holiday still gets its
  ordinary weekday schedule, not the holiday one, since there's no holiday
  calendar here to check against.

  **Partial responses**: confirmed live that `/Line/{line}/Timetable/{stop}`
  sometimes comes back with only one day-type's schedule instead of all
  four (looks like a TfL backend cache inconsistency, not something this
  app's requests trigger). Caching that for the whole day would make a
  stop show nothing, or the wrong day's times, until the next fetch — so a
  response is only accepted and cached when it has all four day-types; an
  incomplete one is treated as a fetch error, and the previous day's stale
  cache (if any) is kept and reused rather than overwriting it with
  something worse.

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
  @day_types ["Monday - Thursday", "Friday", "Saturdays and Public Holidays", "Sunday"]

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

    with {:ok, schedules} <- cached_schedules(stop_id, line) do
      day = day_type(NaiveDateTime.to_date(now))
      now_minutes = now.hour * 60 + now.minute

      departures =
        schedules
        |> Map.get(day, [])
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

  @doc "Monday-Thursday/Friday/Saturday/Sunday, matching the Timetable endpoint's own schedule names."
  @spec day_type(Date.t()) :: String.t()
  def day_type(date) do
    case Date.day_of_week(date) do
      day when day in 1..4 -> "Monday - Thursday"
      5 -> "Friday"
      6 -> "Saturdays and Public Holidays"
      7 -> "Sunday"
    end
  end

  defp cached_schedules(stop_id, line) do
    key = cache_key(stop_id, line)
    today = NaiveDateTime.to_date(Foxbus.LondonTime.now())
    cached = Storage.get(key, nil, app: :foxbus)

    case cached do
      %{fetched_on: ^today, schedules: schedules} ->
        {:ok, schedules}

      _stale_or_missing ->
        case fetch_and_parse_timetable(stop_id, line) do
          {:ok, schedules} ->
            Storage.put(key, %{fetched_on: today, schedules: schedules}, app: :foxbus)
            {:ok, schedules}

          {:error, _reason} = error ->
            case cached do
              %{schedules: schedules} -> {:ok, schedules}
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

  defp fetch_and_parse_timetable(stop_id, line) do
    with {:ok, json} <- TflHttp.get(url("/Line/#{line_id(line)}/Timetable/#{stop_id}")) do
      schedules = parse_timetable(json)

      if complete_timetable?(schedules) do
        {:ok, schedules}
      else
        {:error, :incomplete_timetable}
      end
    end
  end

  @doc "True only when all four day-types are present — see the moduledoc on partial responses."
  @spec complete_timetable?(%{String.t() => list}) :: boolean
  def complete_timetable?(schedules), do: Enum.all?(@day_types, &Map.has_key?(schedules, &1))

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
