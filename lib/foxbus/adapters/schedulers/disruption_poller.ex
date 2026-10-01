defmodule Foxbus.Adapters.Schedulers.DisruptionPoller do
  @moduledoc """
  Driving adapter: polls `Foxbus.Disruptions` for the configured line every
  5 minutes. Disruptions change far less often than arrivals, so this runs on
  its own schedule rather than alongside every `AdaptiveBusPoller` fetch.
  """
  use GenServer
  require Logger

  @interval_ms 5 * 60_000

  def start_link(line), do: GenServer.start_link(__MODULE__, line, name: __MODULE__)

  @impl true
  def init(line) do
    send(self(), :poll)
    {:ok, line}
  end

  @impl true
  def handle_info(:poll, line) do
    case Foxbus.Disruptions.check_and_publish(line) do
      {:error, reason} -> Logger.warning("foxbus: disruption check failed: #{inspect(reason)}")
      _ -> :ok
    end

    Process.send_after(self(), :poll, @interval_ms)
    {:noreply, line}
  end
end
