defmodule Foxbus.Adapters.Sources.StagecoachHttp do
  @moduledoc """
  Shared HTTPS POST for Stagecoach's own real-time API
  (api.stagecoachbus.com/adc/...), decoding the JSON body.

  Unlike Carousel/TfL/bustimes.org, this is not a documented or
  developer-issued API — the `X-SC-apiKey` sent here is one found in
  stagecoachbus.com's own public website JavaScript (confirmed live, 21
  Oct, via a browser network capture — see `Foxbus.Adapters.Sources.StagecoachProvider`'s
  moduledoc for how), used by every visitor's browser, not something
  issued to this project. No developer registration or docs exist for it
  as far as we could find (checked the usual `/swagger`, `/api-docs`,
  `/openapi.json` paths — all 404), so there is no SLA and no promise it
  keeps working. Owain's own call, made with that understood (confirmed
  live: a different, guessed key got a 401, so the key genuinely is
  checked, this one just happens to still work) — build on it and see how
  long it lasts, the same spirit as a screen-scrape but with a credential
  attached that isn't ours.

  **The `servicesFilters` field is required**, not optional — confirmed
  live: every request that omitted it returned a `500 retail-fault`
  ("Retail internal service error"), while the identical request with it
  present returned a clean `200`, empty or not, every time. `post/2`
  always includes it, even as an empty list, rather than ever omitting it.

  The key is read from `STAGECOACH_API_KEY` first (for a host run — same
  reasoning as `Foxbus.Adapters.Sources.TflProvider`'s `TFL_APP_KEY`: lets
  a host run pick it up from the environment without copying it into host
  Storage by hand, and an empty value counts as unset), then from
  `NestGen2.Storage` (`storage.sh foxbus put stagecoach_api_key '"<key>"'`).
  Never in mix.exs — a key is a secret even an unofficial one. Unlike TfL,
  there's no unauthenticated fallback: a missing key is a fetch error,
  since Stagecoach's API has no documented reduced-rate anonymous tier the
  way TfL's does (and Owain's own test showed a wrong/missing key is
  simply rejected).
  """

  alias NestGen2.Storage

  @base_url "https://api.stagecoachbus.com"

  @spec post(String.t(), map) :: {:ok, term} | {:error, term}
  def post(path, body) do
    with {:ok, key} <- fetch_key() do
      http_opts = [ssl: ssl_opts(), timeout: 15_000, connect_timeout: 10_000]

      headers = [
        {~c"accept", ~c"application/json"},
        {~c"x-sc-securitymethod", ~c"API"},
        {~c"x-sc-apikey", String.to_charlist(key)},
        {~c"origin", ~c"https://www.stagecoachbus.com"},
        {~c"referer", ~c"https://www.stagecoachbus.com/"}
      ]

      request =
        {String.to_charlist(@base_url <> path), headers, ~c"application/json",
         Jason.encode!(body)}

      with {:ok, {{_, 200, _}, _resp_headers, resp_body}} <-
             :httpc.request(:post, request, http_opts, body_format: :binary),
           {:ok, decoded} <- Jason.decode(resp_body) do
        {:ok, decoded}
      else
        {:ok, {{_, status, _}, _headers, _body}} -> {:error, {:unexpected_status, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_key do
    case System.get_env("STAGECOACH_API_KEY") do
      key when is_binary(key) and key != "" ->
        {:ok, key}

      _ ->
        case Storage.get(:stagecoach_api_key, nil, app: :foxbus) do
          nil -> {:error, :no_api_key}
          key -> {:ok, key}
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
