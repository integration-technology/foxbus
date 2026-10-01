defmodule Foxbus.StopClosures do
  @moduledoc """
  Application service: checks whether a specific stop is currently
  unservable via the configured source, and hands the result to the
  configured sink. Nothing else knows which adapters are wired in.
  """

  @spec check(String.t()) :: {:ok, String.t() | nil} | {:error, term}
  def check(atco_code), do: source().closure(atco_code)

  @doc "Checks and publishes; returns what was found so the poller can log it."
  @spec check_and_publish(atom, String.t()) :: {:ok, String.t() | nil} | {:error, term}
  def check_and_publish(stop, atco_code) do
    with {:ok, explanation} <- check(atco_code),
         :ok <- sink().publish_closure(stop, explanation) do
      {:ok, explanation}
    end
  end

  defp source, do: Application.fetch_env!(:foxbus, :stop_closure_source)
  defp sink, do: Application.fetch_env!(:foxbus, :stop_closure_sink)
end
