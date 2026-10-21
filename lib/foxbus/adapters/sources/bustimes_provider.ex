defmodule Foxbus.Adapters.Sources.BustimesProvider do
  @moduledoc """
  Scheduled departures scraped from bustimes.org
  (https://bustimes.org/stops/<stop_id>/departures, `stop_id` the numeric id
  in a stop's own bustimes.org URL — found from the stop's page or its
  service's own stop list, e.g.
  https://bustimes.org/services/34-perth-spittalfield-or-blairgowrie).

  Named for the actual data source, not an operator: bustimes.org is a
  community-run aggregator covering every operator serving a stop (first
  built to watch Stagecoach East Scotland's 34/34A at Murthly, but a stop
  can just as well be served by several operators under the same route
  number — confirmed live: Murthly's own stop lists both Stagecoach's and
  Dochertys Midland Coaches' separate "34" services, indistinguishably in
  the departures table, which is exactly how a physical stop works: a
  rider waiting for "the 34" doesn't care which company's bus turns up).

  **Scheduled only, like `TflProvider`'s Timetable approach** — confirmed
  live that the stop page's "Scheduled" column shows no live/real-time
  indicator for any service here, so there's no live data to prefer. No
  caching, unlike `TflProvider`: the `/departures` fragment is small (a
  handful of rows, not TfL's whole-day timetable), so it's cheap to
  refetch on every poll, same as `CarouselScrapeSource`.

  **Scope, and why the fetch path avoids `?date=`**: bustimes.org's own
  robots.txt disallows `/stops/*?date=*` (crawling every date a stop ever
  has) but not a plain `/stops/<id>/departures` request, which is what
  `fetch_arrivals/2` always sends — just "now onward", never a specific
  date, so this stays inside what the site allows automated requests to
  do.

  No disruption or stop-closure concept here yet — bustimes.org has
  service pages and a (separately scraped, not attempted here) alerts
  feed, but nothing this simple HTML fragment surfaces; a first cut ships
  without `disrupted?/2`/`closure/1`, same as `Foxbus.Ports.Provider`
  allows for any provider lacking the concept.
  """

  @behaviour Foxbus.Ports.Provider

  alias Foxbus.Adapters.Sources.BustimesHttp
  alias Foxbus.Domain.Arrival
  alias Foxbus.LondonTime

  @base_url "https://bustimes.org/stops"

  @impl true
  def id, do: :bustimes

  @impl true
  def label, do: "Bustimes"

  @impl true
  def disruptions?, do: false

  @impl true
  def closures?, do: false

  @impl true
  def fetch_arrivals(stop_id, _lines) do
    with {:ok, body} <- BustimesHttp.get("#{@base_url}/#{stop_id}/departures") do
      {:ok, parse_html(body, LondonTime.now())}
    end
  end

  @doc false
  # `now` is UK local time; passed in so parsing is testable.
  @spec parse_html(String.t(), NaiveDateTime.t()) :: [Arrival.t()]
  def parse_html(html, now) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        document |> Floki.find("table tbody tr") |> Enum.flat_map(&to_arrival(&1, now))

      _ ->
        []
    end
  end

  defp to_arrival(row, now) do
    with [line_cell, destination_cell, time_cell] <- Floki.find(row, "td"),
         line when line != "" <- line_cell |> Floki.text() |> String.trim(),
         destination when destination != "" <-
           destination_cell |> Floki.text() |> String.trim(),
         [h, m] when h != nil <- parse_time(time_cell |> Floki.text() |> String.trim()) do
      {eta, day} = minutes_until(Time.new!(h, m, 0), NaiveDateTime.to_time(now))

      [
        %Arrival{
          line: line,
          destination: destination,
          eta_minutes: eta,
          scheduled_time: Time.new!(h, m, 0),
          day: day,
          status: :scheduled
        }
      ]
    else
      _ -> []
    end
  end

  defp parse_time(text) do
    case Regex.run(~r/^(\d{1,2}):(\d{2})$/, text, capture: :all_but_first) do
      [h, m] -> Enum.map([h, m], &String.to_integer/1)
      nil -> [nil, nil]
    end
  end

  # Times earlier than now by more than an hour are taken to be tomorrow —
  # same rule, and same reasoning, as CarouselScrapeSource.minutes_until/2.
  defp minutes_until(target, now) do
    diff = Time.diff(target, now, :minute)
    if diff < -60, do: {diff + 24 * 60, :tomorrow}, else: {max(diff, 0), :today}
  end
end
