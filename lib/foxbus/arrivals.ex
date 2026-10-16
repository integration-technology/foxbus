defmodule Foxbus.Arrivals do
  @moduledoc """
  Application service: fetches a stop's arrivals from its configured
  provider, filters them down to that stop's own watched lines (a shared
  stop's board can carry other routes we don't want shown), and hands the
  rest to the configured sink. Nothing else knows which adapters are wired
  in, or which provider a given stop uses.
  """
  alias Foxbus.Domain.Arrival

  @spec fetch(module, String.t(), [String.t()]) :: {:ok, [Arrival.t()]} | {:error, term}
  def fetch(provider, stop_id, lines) do
    with {:ok, arrivals} <- provider.fetch_arrivals(stop_id, lines) do
      {:ok, arrivals |> filter_lines(lines) |> Arrival.sort_by_eta()}
    end
  end

  @doc false
  @spec filter_lines([Arrival.t()], [String.t()]) :: [Arrival.t()]
  def filter_lines(arrivals, []), do: arrivals
  def filter_lines(arrivals, lines), do: Enum.filter(arrivals, &(&1.line in lines))

  @doc "Fetches and publishes; returns what was fetched so the poller can pace itself."
  @spec fetch_and_publish(module, atom, String.t(), [String.t()]) ::
          {:ok, [Arrival.t()]} | {:error, term}
  def fetch_and_publish(provider, stop, stop_id, lines) do
    with {:ok, arrivals} <- fetch(provider, stop_id, lines),
         :ok <- sink().publish(stop, arrivals) do
      {:ok, arrivals}
    end
  end

  defp sink, do: Application.fetch_env!(:foxbus, :arrivals_sink)
end
