defmodule Foxbus.Adapters.Sources.ChilternRailHttp do
  @moduledoc """
  GET for National Rail's OpenLDBWS live departure-board REST API, served
  through the Rail Data Marketplace gateway
  (api1.raildata.org.uk/1010-live-departure-board-dep1_2/LDBWS/api/20220120),
  returning the decoded JSON body.

  **Verified against a real response** (2026-11-02, Amersham → Marylebone)
  — this is the third cut of this module. The first built a SOAP 1.1
  envelope against the old WSDL schema; the second guessed REST/JSON with
  HTTP Basic Auth straight against `realtime.nationalrail.co.uk`, reasoning
  from that domain's own docs page — both wrong. The actual base URL and
  auth scheme only showed up on the subscribed product's own
  "Specification" tab on raildata.org.uk (a known-flaky page — see that
  product's Community tab if it won't load): requests go through
  `api1.raildata.org.uk`, not `realtime.nationalrail.co.uk` directly, and
  auth is a single `x-apikey` header carrying the product's own "Consumer
  key" — not Basic Auth, and the "Consumer secret" shown alongside it
  isn't used for this call at all. The JSON field names
  (`trainServices`/`std`/`etd`/`destination`/`operatorCode`/`isCancelled`)
  did match the second cut's guess, confirmed live — no change needed in
  `Foxbus.Adapters.Sources.ChilternRailProvider`'s parsing.

  `CHILTERN_RAIL_TOKEN` holds the Consumer key as-is (not base64, not a
  username:password pair) — read from the environment first (a host run —
  same reasoning as `Foxbus.Adapters.Sources.TflProvider`'s `TFL_APP_KEY`),
  then `NestGen2.Storage` (`storage.sh foxbus put chiltern_rail_token
  '"<consumer key>"'`). Never in mix.exs. No unauthenticated fallback.
  """

  alias NestGen2.Storage

  @base_url "https://api1.raildata.org.uk/1010-live-departure-board-dep1_2/LDBWS/api/20220120"

  @spec get_departure_board(String.t(), String.t(), non_neg_integer) ::
          {:ok, map} | {:error, term}
  def get_departure_board(crs, filter_crs, num_rows \\ 10) do
    with {:ok, api_key} <- fetch_credentials() do
      url =
        "#{@base_url}/GetDepartureBoard/#{crs}?numRows=#{num_rows}&filterCrs=#{filter_crs}&filterType=to"

      headers = [{~c"x-apikey", String.to_charlist(api_key)}]
      http_opts = [ssl: ssl_opts(), timeout: 15_000, connect_timeout: 10_000]
      request = {String.to_charlist(url), headers}

      with {:ok, {{_, 200, _}, _resp_headers, resp_body}} <-
             :httpc.request(:get, request, http_opts, body_format: :binary) do
        Jason.decode(resp_body)
      else
        {:ok, {{_, status, _}, _headers, _body}} -> {:error, {:unexpected_status, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_credentials do
    case System.get_env("CHILTERN_RAIL_TOKEN") do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        case Storage.get(:chiltern_rail_token, nil, app: :foxbus) do
          nil -> {:error, :no_api_key}
          value -> {:ok, value}
        end
    end
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: cacerts(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  # Loaded once, then cached by public_key.
  defp cacerts do
    if :persistent_term.get({__MODULE__, :cacerts_loaded}, false) do
      :public_key.cacerts_get()
    else
      :ok = :public_key.cacerts_load(Application.app_dir(:foxbus, ["priv", "cacerts.pem"]))
      :persistent_term.put({__MODULE__, :cacerts_loaded}, true)
      :public_key.cacerts_get()
    end
  end
end
