defmodule Foxbus.Adapters.Sources.TflProvider do
  @moduledoc """
  Live Underground arrivals and line status from TfL's own Unified API
  (https://api.tfl.gov.uk), no scraping — a stop's `stop_id` is its TfL
  StopPoint id (a NaPTAN code, e.g. "910GAMERSHM" for Amersham — look one up
  with `https://api.tfl.gov.uk/StopPoint/Search/<name>`).

  `lines` (here and in `Foxbus.Config`) are TfL's own line *names*, as shown
  on screen and returned by the Arrivals endpoint (`"Metropolitan"`, not the
  lowercase slug `"metropolitan"` the Status endpoint actually takes in its
  URL) — `line_id/1` derives the slug from the name for that one internal
  use. This only needs to handle the names TfL's own lines actually have;
  every London Underground line name maps cleanly (lowercase, "&" becomes a
  hyphen, e.g. "Hammersmith & City" -> "hammersmith-city", matching TfL's
  real line ids).

  No stop-closure concept here (`closures?/0` is false) — TfL has line
  status, not a per-station "this stop is closed" notice.

  Needs a free TfL `app_key` (register at https://api-portal.tfl.gov.uk) —
  the API works unauthenticated too, just at a much lower rate limit (a few
  hundred requests a day, vs. hundreds a minute with a key). Read from
  `NestGen2.Storage` (`storage.sh foxbus put tfl_app_key '"<key>"'`), never
  mix.exs — a key is a secret, and mix.exs is committed to a public repo.
  No value set means unauthenticated.
  """

  @behaviour Foxbus.Ports.Provider

  alias Foxbus.Adapters.Sources.TflHttp
  alias Foxbus.Domain.Arrival
  alias NestGen2.Storage

  @base_url "https://api.tfl.gov.uk"

  @impl true
  def id, do: :tfl

  @impl true
  def label, do: "TfL"

  @impl true
  def disruptions?, do: true

  @impl true
  def closures?, do: false

  @impl true
  def fetch_arrivals(stop_id) do
    with {:ok, predictions} <- TflHttp.get(url("/StopPoint/#{stop_id}/Arrivals")) do
      {:ok, parse_arrivals(predictions)}
    end
  end

  @doc false
  @spec parse_arrivals([map]) :: [Arrival.t()]
  def parse_arrivals(predictions) do
    Enum.map(predictions, fn p ->
      %Arrival{
        line: Map.fetch!(p, "lineName"),
        destination: destination(p),
        eta_minutes: div(Map.fetch!(p, "timeToStation"), 60),
        status: :live
      }
    end)
  end

  # destinationName is often "" — a train terminating here, or one TfL
  # hasn't mapped a name for — towards (e.g. "Amersham") is the usable
  # fallback in that case.
  defp destination(%{"destinationName" => name}) when name not in [nil, ""], do: name
  defp destination(%{"towards" => towards}) when towards not in [nil, ""], do: towards
  defp destination(_prediction), do: "Unknown"

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
    case Storage.get(:tfl_app_key, nil, app: :foxbus) do
      nil -> ""
      key -> "?app_key=#{URI.encode_www_form(key)}"
    end
  end
end
