defmodule Foxbus.Adapters.Sources.CarouselScrapeSource do
  @moduledoc """
  Live bus times scraped from Carousel's departure board,
  e.g. https://www.carouselbuses.co.uk/stops/040000002201 (stops use ATCO codes).

  Each departure carries a screen-reader paragraph with everything in one string:

      Service - 105. Destination - Chesham + Chartridg. Departure time - 18 mins.
      Departure 1 of 7. Live.

  The time is either "N mins" (imminent, live) or a local "HH:MM".

  Caveats of scraping: there is no delay figure, and a page redesign makes the
  parse return an empty list, which reads the same as "no more buses today".
  """
  @behaviour Foxbus.Ports.ArrivalsSource

  alias Foxbus.Adapters.Sources.CarouselHttp
  alias Foxbus.Domain.Arrival
  alias Foxbus.LondonTime

  @base_url "https://www.carouselbuses.co.uk/stops"
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @pattern ~r/
    Service\s*-\s*(?<line>[^.]+)\.\s*
    Destination\s*-\s*(?<destination>[^.]+)\.\s*
    Departure\ time\s*-\s*(?<time>[^.]+)\.\s*
    Departure\s+\d+\s+of\s+\d+\.\s*
    (?<status>Live|Scheduled)\.
  /x

  @impl true
  def fetch_arrivals(stop_id) do
    with {:ok, {headers, body}} <- CarouselHttp.get("#{@base_url}/#{stop_id}") do
      check_clock(headers)
      {:ok, parse_html(body, LondonTime.now())}
    end
  end

  @doc false
  # `now` is UK local time; passed in so parsing is testable.
  @spec parse_html(String.t(), NaiveDateTime.t()) :: [Arrival.t()]
  def parse_html(html, now) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        document |> Floki.find("ol li a") |> Enum.flat_map(&to_arrival(&1, now))

      _ ->
        []
    end
  end

  defp to_arrival(link, now) do
    text = link |> Floki.find("p.sr-only") |> Floki.text() |> String.replace(~r/\s+/, " ")

    case Regex.named_captures(@pattern, String.trim(text)) do
      %{"line" => line, "destination" => destination, "time" => time, "status" => status} ->
        {eta, scheduled} = parse_time(String.trim(time), now)

        [
          %Arrival{
            line: String.trim(line),
            destination: String.trim(destination),
            eta_minutes: eta,
            scheduled_time: scheduled,
            status: if(status == "Live", do: :live, else: :scheduled)
          }
        ]

      _ ->
        []
    end
  end

  defp parse_time(time, now) do
    cond do
      match = Regex.run(~r/^(\d+)\s*mins?$/, time, capture: :all_but_first) ->
        minutes = match |> hd() |> String.to_integer()
        due = NaiveDateTime.add(now, minutes * 60, :second)
        {minutes, Time.new!(due.hour, due.minute, 0)}

      match = Regex.run(~r/^(\d{1,2}):(\d{2})$/, time, capture: :all_but_first) ->
        [h, m] = Enum.map(match, &String.to_integer/1)
        scheduled = Time.new!(h, m, 0)
        {minutes_until(scheduled, NaiveDateTime.to_time(now)), scheduled}

      true ->
        {0, nil}
    end
  end

  # Times earlier than now by more than an hour are taken to be tomorrow.
  defp minutes_until(target, now) do
    diff = Time.diff(target, now, :minute)
    if diff < -60, do: diff + 24 * 60, else: max(diff, 0)
  end

  # Carousel's Date header is a second opinion on UTC; NestGen2.Clock uses it
  # only if NTP has been failing.
  defp check_clock(headers) do
    case server_time(headers) do
      %DateTime{} = utc -> NestGen2.Clock.observe(utc, :carousel)
      nil -> :ok
    end
  end

  @doc false
  # UTC from an HTTP response's Date header (RFC 1123), plus Age if a cache
  # served it; nil when absent or unreadable.
  @spec server_time([{charlist, charlist}]) :: DateTime.t() | nil
  def server_time(headers) do
    headers = Map.new(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

    with date when is_binary(date) <- headers["date"],
         [d, mon, y, h, m, s] <-
           Regex.run(~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/, date,
             capture: :all_but_first
           ),
         month when month != nil <- Enum.find_index(@months, &(&1 == mon)),
         {:ok, naive} <-
           NaiveDateTime.new(
             String.to_integer(y),
             month + 1,
             String.to_integer(d),
             String.to_integer(h),
             String.to_integer(m),
             String.to_integer(s)
           ) do
      age =
        case Integer.parse(headers["age"] || "") do
          {n, ""} -> n
          _ -> 0
        end

      naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(age, :second)
    else
      _ -> nil
    end
  end
end
