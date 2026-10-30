defmodule Foxbus.Adapters.Sources.ChilternRailHttp do
  @moduledoc """
  SOAP POST for National Rail's OpenLDBWS live departure-board service
  (lite.realtime.nationalrail.co.uk), returning the raw XML body.

  Unlike Carousel/TfL/bustimes.org, OpenLDBWS has no JSON response — it's a
  SOAP 1.1 service, the Darwin live-data feed's own public interface.
  `post/1` wraps the given request-body XML fragment in the SOAP envelope,
  sets the access token in the SOAP header (not a URL query param, unlike
  every other provider's key here — that's how this API expects it), and
  returns the response body as a plain string for
  `Foxbus.Adapters.Sources.ChilternRailProvider` to parse with a regex, the
  same screen-scrape spirit as `Foxbus.Adapters.Sources.CarouselScrapeSource`
  rather than pulling in a full XML/SOAP library for one request shape.

  **Unverified against live data** — built from the published OpenLDBWS
  2021-11-01 WSDL schema, not a real captured response (no token existed
  yet to test against, unlike every other provider's reverse-engineered-or-
  registered build here). Confirm the envelope and `lt4:`/`lt7:` namespace
  prefixes against a real response once there's a token, the same as every
  other provider was checked live before being trusted.

  Needs a free Rail Data Marketplace token (register at
  https://raildata.org.uk, subscribe to "Live Departure Board — Staff
  Version" or "OpenLDBWS"). Read from `CHILTERN_RAIL_TOKEN` first (a host
  run — same reasoning as `Foxbus.Adapters.Sources.TflProvider`'s
  `TFL_APP_KEY`), then from `NestGen2.Storage`
  (`storage.sh foxbus put chiltern_rail_token '"<token>"'`). Never in
  mix.exs. No unauthenticated fallback — OpenLDBWS always requires a token.
  """

  alias NestGen2.Storage

  @base_url "https://lite.realtime.nationalrail.co.uk/OpenLDBWS/ldb11.asmx"
  @soap_action "http://thalesgroup.com/RTTI/2021-11-01/ldb/GetDepartureBoard"

  @spec post(String.t()) :: {:ok, String.t()} | {:error, term}
  def post(body_xml) do
    with {:ok, token} <- fetch_token() do
      http_opts = [ssl: ssl_opts(), timeout: 15_000, connect_timeout: 10_000]

      headers = [
        {~c"soapaction", String.to_charlist(@soap_action)}
      ]

      request =
        {String.to_charlist(@base_url), headers, ~c"text/xml; charset=utf-8",
         envelope(token, body_xml)}

      with {:ok, {{_, 200, _}, _resp_headers, resp_body}} <-
             :httpc.request(:post, request, http_opts, body_format: :binary) do
        {:ok, resp_body}
      else
        {:ok, {{_, status, _}, _headers, _body}} -> {:error, {:unexpected_status, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp envelope(token, body_xml) do
    """
    <?xml version="1.0" encoding="utf-8"?>
    <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:typ="http://thalesgroup.com/RTTI/2013-11-28/Token/types">
      <soap:Header>
        <typ:AccessToken>
          <typ:TokenValue>#{token}</typ:TokenValue>
        </typ:AccessToken>
      </soap:Header>
      <soap:Body>
        #{body_xml}
      </soap:Body>
    </soap:Envelope>
    """
  end

  defp fetch_token do
    case System.get_env("CHILTERN_RAIL_TOKEN") do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        case Storage.get(:chiltern_rail_token, nil, app: :foxbus) do
          nil -> {:error, :no_api_key}
          token -> {:ok, token}
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
