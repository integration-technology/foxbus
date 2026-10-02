defmodule Foxbus.Arrivals do
  @moduledoc """
  Application service: fetches a stop's arrivals from the configured source,
  filters them down to the configured lines (see `Foxbus.Config.lines/0`) —
  a shared stop's board can carry other routes we don't want shown — and
  hands the rest to the configured sink. Nothing else knows which adapters
  are wired in.
  """
  alias Foxbus.Domain.Arrival

  @spec fetch(String.t()) :: {:ok, [Arrival.t()]} | {:error, term}
  def fetch(stop_id) do
    with {:ok, arrivals} <- source().fetch_arrivals(stop_id) do
      {:ok, arrivals |> filter_lines(Foxbus.Config.lines()) |> Arrival.sort_by_eta()}
    end
  end

  @doc false
  @spec filter_lines([Arrival.t()], [String.t()]) :: [Arrival.t()]
  def filter_lines(arrivals, []), do: arrivals
  def filter_lines(arrivals, lines), do: Enum.filter(arrivals, &(&1.line in lines))

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
