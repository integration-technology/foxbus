defmodule Foxbus.Adapters.Schedulers.DisruptionPoller do
  @moduledoc """
  Driving adapter: polls `Foxbus.Disruptions` for the configured lines every
  5 minutes. Disruptions change far less often than arrivals, so this runs on
  its own schedule rather than alongside every `AdaptiveBusPoller` fetch.
  """
  use GenServer
  require Logger

  @interval_ms 5 * 60_000

  def start_link(lines), do: GenServer.start_link(__MODULE__, lines, name: __MODULE__)

  @impl true
  def init(lines) do
    send(self(), :poll)
    {:ok, lines}
  end

  @impl true
  def handle_info(:poll, lines) do
    case Foxbus.Disruptions.check_and_publish(lines) do
      {:error, reason} -> Logger.warning("foxbus: disruption check failed: #{inspect(reason)}")
      _ -> :ok
    end

    Process.send_after(self(), :poll, @interval_ms)
    {:noreply, lines}
  end
end
