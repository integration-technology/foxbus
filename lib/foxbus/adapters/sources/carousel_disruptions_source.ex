defmodule Foxbus.Adapters.Sources.CarouselDisruptionsSource do
  @moduledoc """
  Whether a line has an active notice on Carousel's network-wide board,
  e.g. https://www.carouselbuses.co.uk/service-updates.

  Each notice tags the routes it affects with an anchor like:

      <div class="disruption-item ...">
        ...
        <a data-name="105" data-type="line">...</a>
      </div>

  Caveats of scraping: some notices are long-running ("15th Jul 2025 onwards")
  rather than tied to today, so this answers "is there a listed notice for
  this line", not strictly "is one active at this exact moment". A page
  redesign makes the parse return false, which reads the same as "all clear".
  """
  @behaviour Foxbus.Ports.DisruptionsSource

  alias Foxbus.Adapters.Sources.CarouselHttp

  @url "https://www.carouselbuses.co.uk/service-updates"

  @impl true
  def disrupted?(line) do
    with {:ok, {_headers, body}} <- CarouselHttp.get(@url) do
      {:ok, parse_html(body, line)}
    end
  end

  @doc false
  @spec parse_html(String.t(), String.t()) :: boolean
  def parse_html(html, line) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        document
        |> Floki.find(".disruption-item [data-name]")
        |> Floki.attribute("data-name")
        |> Enum.member?(line)

      _ ->
        false
    end
  end
end
