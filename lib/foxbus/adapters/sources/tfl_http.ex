defmodule Foxbus.Adapters.Sources.TflHttp do
  @moduledoc """
  Shared HTTPS GET for api.tfl.gov.uk, decoding the JSON body. The Nest has
  no general CA store (only one Nest certificate), so every request here is
  verified against the bundled Mozilla set (priv/cacerts.pem, from curl.se,
  MPL-2.0) instead — same approach as `Foxbus.Adapters.Sources.CarouselHttp`,
  kept as its own small module rather than shared, so each provider stays
  independently simple.
  """

  @spec get(String.t()) :: {:ok, term} | {:error, term}
  def get(url) do
    http_opts = [ssl: ssl_opts(), timeout: 15_000, connect_timeout: 10_000]
    request = {String.to_charlist(url), [{~c"user-agent", ~c"foxbus"}]}

    with {:ok, {{_, 200, _}, _headers, body}} <-
           :httpc.request(:get, request, http_opts, body_format: :binary),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      {:ok, {{_, status, _}, _headers, _body}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
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
