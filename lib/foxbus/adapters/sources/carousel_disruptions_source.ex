defmodule Foxbus.Adapters.Sources.CarouselDisruptionsSource do
  @moduledoc """
  The title of the first active notice on Carousel's network-wide board that
  tags any of a list of lines AND applies to a given stop, e.g.
  https://www.carouselbuses.co.uk/service-updates — or nil if none do.

  Each notice tags the routes it affects with an anchor like:

      <div class="disruption-item ...">
        <h3 class="disruption-item__title">Service 105 Disruption</h3>
        ...
        <a data-name="105" data-type="line">...</a>
        <ul class="c-disruption__affected-entities">
          <li>Affected stops:</li>
          <li><a class="stop-block" href="/explore?type=stop&id=040000002201&...">
            Coleshill, Chalk Hill, N-bound
          </a></li>
        </ul>
      </div>

  A notice naming specific affected stops (as `CarouselStopClosureSource`
  also reads) only applies to a stop whose ATCO code is in that list —
  otherwise it's for a different part of the line and shouldn't show here. A
  notice with no "Affected stops" list at all is treated as applying
  network-wide, so it still shows on every stop on the line.

  Caveats of scraping: some notices are long-running ("15th Jul 2025 onwards")
  rather than tied to today, so this answers "is there a listed notice for
  any of these lines, at this stop", not strictly "is one active at this
  exact moment". A page redesign makes the parse return nil, which reads the
  same as "all clear".
  """
  @behaviour Foxbus.Ports.DisruptionsSource

  alias Foxbus.Adapters.Sources.CarouselHttp

  @url "https://www.carouselbuses.co.uk/service-updates"

  @impl true
  def disrupted?(lines, atco_code) do
    with {:ok, {_headers, body}} <- CarouselHttp.get(@url) do
      {:ok, parse_html(body, lines, atco_code)}
    end
  end

  @doc false
  @spec parse_html(String.t(), [String.t()], String.t()) :: String.t() | nil
  def parse_html(html, lines, atco_code) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        document
        |> Floki.find(".disruption-item")
        |> Enum.find_value(fn item ->
          names = item |> Floki.find("[data-name]") |> Floki.attribute("data-name")
          if Enum.any?(names, &(&1 in lines)) and applies_to?(item, atco_code), do: title(item)
        end)

      _ ->
        nil
    end
  end

  defp applies_to?(item, atco_code) do
    case stop_ids(item) do
      [] -> true
      ids -> atco_code in ids
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

  defp title(item) do
    item
    |> Floki.find(".disruption-item__title")
    |> Floki.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
