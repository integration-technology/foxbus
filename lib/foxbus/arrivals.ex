defmodule Foxbus.Arrivals do
  @moduledoc """
  Application service: fetches a stop's arrivals from the configured source and
  hands them to the configured sink. Nothing else knows which adapters are wired
  in.
  """
  alias Foxbus.Domain.Arrival

  @spec fetch(String.t()) :: {:ok, [Arrival.t()]} | {:error, term}
  def fetch(stop_id) do
    with {:ok, arrivals} <- source().fetch_arrivals(stop_id) do
      {:ok, Arrival.sort_by_eta(arrivals)}
    end
  end

  @doc "Fetches and publishes; returns what was fetched so the poller can pace itself."
  @spec fetch_and_publish(atom, String.t()) :: {:ok, [Arrival.t()]} | {:error, term}
  def fetch_and_publish(stop, stop_id) do
    with {:ok, arrivals} <- fetch(stop_id),
         :ok <- sink().publish(stop, arrivals) do
      {:ok, arrivals}
    end
  end

  defp source, do: Application.fetch_env!(:foxbus, :arrivals_source)
  defp sink, do: Application.fetch_env!(:foxbus, :arrivals_sink)
end
