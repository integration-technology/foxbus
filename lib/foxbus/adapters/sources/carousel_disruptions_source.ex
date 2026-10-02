defmodule Foxbus.Adapters.Sources.CarouselDisruptionsSource do
  @moduledoc """
  The title of the first active notice on Carousel's network-wide board that
  tags any of a list of lines, e.g.
  https://www.carouselbuses.co.uk/service-updates — or nil if none do.

  Each notice tags the routes it affects with an anchor like:

      <div class="disruption-item ...">
        <h3 class="disruption-item__title">Service 105 Disruption</h3>
        ...
        <a data-name="105" data-type="line">...</a>
      </div>

  Caveats of scraping: some notices are long-running ("15th Jul 2025 onwards")
  rather than tied to today, so this answers "is there a listed notice for
  any of these lines", not strictly "is one active at this exact moment". A
  page redesign makes the parse return nil, which reads the same as
  "all clear".
  """
  @behaviour Foxbus.Ports.DisruptionsSource

  alias Foxbus.Adapters.Sources.CarouselHttp

  @url "https://www.carouselbuses.co.uk/service-updates"

  @impl true
  def disrupted?(lines) do
    with {:ok, {_headers, body}} <- CarouselHttp.get(@url) do
      {:ok, parse_html(body, lines)}
    end
  end

  @doc false
  @spec parse_html(String.t(), [String.t()]) :: String.t() | nil
  def parse_html(html, lines) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        document
        |> Floki.find(".disruption-item")
        |> Enum.find_value(fn item ->
          names = item |> Floki.find("[data-name]") |> Floki.attribute("data-name")
          if Enum.any?(names, &(&1 in lines)), do: title(item)
        end)

      _ ->
        nil
    end
  end

  defp title(item) do
    item
    |> Floki.find(".disruption-item__title")
    |> Floki.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
