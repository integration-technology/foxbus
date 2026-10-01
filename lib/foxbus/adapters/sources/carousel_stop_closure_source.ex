defmodule Foxbus.Adapters.Sources.CarouselStopClosureSource do
  @moduledoc """
  Whether a specific stop has an active "Affected stops" entry on Carousel's
  network-wide board, e.g. https://www.carouselbuses.co.uk/service-updates,
  and if so, the notice's explanation text.

  Unlike the line-level entities DisruptionsSource reads, a notice optionally
  lists the physical stops it affects, by ATCO code in the link's query
  string, as:

      <ul class="c-disruption__affected-entities">
        <li>Affected stops:</li>
        <li><a class="stop-block" href="/explore?type=stop&id=040000002201&...">
          Coleshill, Chalk Hill, N-bound
        </a></li>
        ...
      </ul>

  A stop can appear in more than one current notice; this returns the first
  match's explanation (the last paragraph in that notice's block — the one
  after both the "Affected routes" and "Affected stops" lists). Caveats of
  scraping: a page redesign makes the parse return nil, which reads the same
  as "stop is fine, nothing to say."
  """
  @behaviour Foxbus.Ports.StopClosureSource

  alias Foxbus.Adapters.Sources.CarouselHttp

  @url "https://www.carouselbuses.co.uk/service-updates"

  @impl true
  def closure(atco_code) do
    with {:ok, {_headers, body}} <- CarouselHttp.get(@url) do
      {:ok, parse_html(body, atco_code)}
    end
  end

  @doc false
  @spec parse_html(String.t(), String.t()) :: String.t() | nil
  def parse_html(html, atco_code) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        document
        |> Floki.find(".disruption-item")
        |> Enum.find_value(fn item ->
          if atco_code in stop_ids(item), do: description(item)
        end)

      _ ->
        nil
    end
  end

  defp stop_ids(item) do
    item
    |> Floki.find("a.stop-block")
    |> Floki.attribute("href")
    |> Enum.flat_map(fn href ->
      case Regex.run(~r/[?&]id=([^&]+)/, href) do
        [_, id] -> [id]
        _ -> []
      end
    end)
  end

  defp description(item) do
    case item |> Floki.find("p") |> List.last() do
      nil -> ""
      p -> p |> List.wrap() |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.trim()
    end
  end
end
