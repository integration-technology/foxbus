defmodule Foxbus.Adapters.Sources.ChilternRailHttp do
  @moduledoc """
  GET for National Rail's OpenLDBWS live departure-board REST API
  (realtime.nationalrail.co.uk/LDBWS/api/20220120), returning the decoded
  JSON body.

  **This replaces this module's first cut**, which built a SOAP 1.1
  envelope against the old (2021-11-01 WSDL) OpenLDBWS schema. Checked
  against the live OpenAPI spec itself
  (realtime.nationalrail.co.uk/LDBWS/static/ldbws.json,
  linked from .../LDBWS/docs/documentation.html): the current service is
  plain REST returning JSON, not SOAP — there is no envelope, no XML, and
  no SOAP `AccessToken` header. Confirmed from the spec's own operation
  list and schema; **still unverified against an actual response** — no
  token existed yet to test against. Confirm the field names below
  (`parse_board`/`parse_service` in
  `Foxbus.Adapters.Sources.ChilternRailProvider`) once there's one.

  Auth is HTTP Basic (`Authorization: Basic base64(username:password)`),
  per .../LDBWS/docs/documentation.html: "All licensed users will be
  issued with a token/password to access public web services." The
  username isn't documented there; most likely the registered account's
  own identifier/email, with the issued token as the password — confirm
  once real credentials exist. Two secrets, not one: `CHILTERN_RAIL_USERNAME`
  / `CHILTERN_RAIL_TOKEN` env vars first (a host run — same reasoning as
  `Foxbus.Adapters.Sources.TflProvider`'s `TFL_APP_KEY`), then
  `NestGen2.Storage` (`storage.sh foxbus put chiltern_rail_username '"<...>"'`,
  `... put chiltern_rail_token '"<...>"'`). Never in mix.exs. No
  unauthenticated fallback — OpenLDBWS always requires credentials.
  """

  alias NestGen2.Storage

  @base_url "https://realtime.nationalrail.co.uk/LDBWS/api/20220120"

  @spec get_departure_board(String.t(), String.t(), non_neg_integer) ::
          {:ok, map} | {:error, term}
  def get_departure_board(crs, filter_crs, num_rows \\ 10) do
    with {:ok, {username, token}} <- fetch_credentials() do
      url =
        "#{@base_url}/GetDepartureBoard/#{crs}?numRows=#{num_rows}&filterCrs=#{filter_crs}&filterType=to"

      auth = "Basic " <> Base.encode64("#{username}:#{token}")
      headers = [{~c"authorization", String.to_charlist(auth)}]
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
    with {:ok, username} <- fetch_secret("CHILTERN_RAIL_USERNAME", :chiltern_rail_username),
         {:ok, token} <- fetch_secret("CHILTERN_RAIL_TOKEN", :chiltern_rail_token) do
      {:ok, {username, token}}
    end
  end

  defp fetch_secret(env_var, storage_key) do
    case System.get_env(env_var) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        case Storage.get(storage_key, nil, app: :foxbus) do
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
