defmodule Foxbus.Adapters.Schedulers.DisruptionPoller do
  @moduledoc """
  Driving adapter, one per watched stop: polls `Foxbus.Disruptions` for the
  configured lines at that stop every 5 minutes — the same cadence as
  `StopClosurePoller`, since a disruption notice changes about as rarely as a
  stop closure one. Per stop (not once for the whole app) so a notice naming
  specific affected stops only shows on the stops it actually names.

  Every failure is logged at warning; the first success is also logged,
  once, at info — so a boot stuck without disruption data leaves a trace
  (see `AdaptiveBusPoller`, `StopClosurePoller`).
  """
  use GenServer
  require Logger

  @interval_ms 5 * 60_000

  def start_link({stop, atco_code, lines}),
    do: GenServer.start_link(__MODULE__, {stop, atco_code, lines}, name: :"#{__MODULE__}.#{stop}")

  @impl true
  def init({stop, atco_code, lines}) do
    send(self(), :poll)
    {:ok, %{stop: stop, atco_code: atco_code, lines: lines, logged_first_success?: false}}
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      case Foxbus.Disruptions.check_and_publish(state.stop, state.lines, state.atco_code) do
        {:error, reason} ->
          Logger.warning("foxbus: disruption check failed for #{state.stop}: #{inspect(reason)}")
          state

        _ ->
          unless state.logged_first_success?,
            do: Logger.info("foxbus: disruption check first succeeded for #{state.stop}")

          %{state | logged_first_success?: true}
      end

    Process.send_after(self(), :poll, @interval_ms)
    {:noreply, state}
  end
end
