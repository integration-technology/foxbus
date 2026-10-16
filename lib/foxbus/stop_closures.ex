defmodule Foxbus.StopClosures do
  @moduledoc """
  Application service: checks whether a specific stop is currently
  unservable via its configured provider, and hands the result to the
  configured sink. Nothing else knows which adapters are wired in. Only
  called for a stop whose provider actually has this capability — see
  `Foxbus.Ports.Provider.closures?/0`.
  """

  @spec check(module, String.t()) :: {:ok, String.t() | nil} | {:error, term}
  def check(provider, stop_id), do: provider.closure(stop_id)

  @doc "Checks and publishes; returns what was found so the poller can log it."
  @spec check_and_publish(module, atom, String.t()) :: {:ok, String.t() | nil} | {:error, term}
  def check_and_publish(provider, stop, stop_id) do
    with {:ok, explanation} <- check(provider, stop_id),
         :ok <- sink().publish_closure(stop, explanation) do
      {:ok, explanation}
    end
  end

  defp sink, do: Application.fetch_env!(:foxbus, :stop_closure_sink)
end
