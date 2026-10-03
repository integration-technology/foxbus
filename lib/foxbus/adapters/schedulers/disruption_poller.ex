defmodule Foxbus.Adapters.Schedulers.DisruptionPoller do
  @moduledoc """
  Driving adapter, one per watched stop: polls `Foxbus.Disruptions` for the
  configured lines at that stop every 5 minutes — the same cadence as
  `StopClosurePoller`, since a disruption notice changes about as rarely as a
  stop closure one. Per stop (not once for the whole app) so a notice naming
  specific affected stops only shows on the stops it actually names.
  """
  use GenServer
  require Logger

  @interval_ms 5 * 60_000

  def start_link({stop, atco_code, lines}),
    do: GenServer.start_link(__MODULE__, {stop, atco_code, lines}, name: :"#{__MODULE__}.#{stop}")

  @impl true
  def init({stop, atco_code, lines}) do
    send(self(), :poll)
    {:ok, %{stop: stop, atco_code: atco_code, lines: lines}}
  end

  @impl true
  def handle_info(:poll, state) do
    case Foxbus.Disruptions.check_and_publish(state.stop, state.lines, state.atco_code) do
      {:error, reason} ->
        Logger.warning("foxbus: disruption check failed for #{state.stop}: #{inspect(reason)}")

      _ ->
        :ok
    end

    Process.send_after(self(), :poll, @interval_ms)
    {:noreply, state}
  end
end
