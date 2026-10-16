defmodule Foxbus.Adapters.Schedulers.DisruptionPoller do
  @moduledoc """
  Driving adapter, one per watched stop whose provider has this capability
  (see `Foxbus.Ports.Provider.disruptions?/0` — `Foxbus.Application` only
  starts this for such a stop): polls `Foxbus.Disruptions` for the
  configured lines at that stop every 5 minutes — the same cadence as
  `StopClosurePoller`, since a disruption notice changes about as rarely as a
  stop closure one — or every 10 s after a failure, until the very first
  fetch has ever succeeded (see `AdaptiveBusPoller`'s moduledoc for why).
  Per stop (not once for the whole app) so a notice naming specific affected
  stops only shows on the stops it actually names.

  Every failure is logged at warning; the first success is also logged,
  once, at info — so a boot stuck without disruption data leaves a trace
  (see `AdaptiveBusPoller`, `StopClosurePoller`).
  """
  use GenServer
  require Logger

  @interval_ms 5 * 60_000
  @first_retry_ms 10_000

  def start_link({provider, stop, stop_id, lines, delay_ms}),
    do:
      GenServer.start_link(__MODULE__, {provider, stop, stop_id, lines, delay_ms},
        name: :"#{__MODULE__}.#{stop}"
      )

  @impl true
  def init({provider, stop, stop_id, lines, delay_ms}) do
    Process.send_after(self(), :poll, delay_ms)

    {:ok,
     %{
       provider: provider,
       stop: stop,
       stop_id: stop_id,
       lines: lines,
       logged_first_success?: false
     }}
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      case Foxbus.Disruptions.check_and_publish(
             state.provider,
             state.stop,
             state.lines,
             state.stop_id
           ) do
        {:error, reason} ->
          Logger.warning("foxbus: disruption check failed for #{state.stop}: #{inspect(reason)}")
          state

        _ ->
          unless state.logged_first_success?,
            do: Logger.info("foxbus: disruption check first succeeded for #{state.stop}")

          %{state | logged_first_success?: true}
      end

    delay = if state.logged_first_success?, do: @interval_ms, else: @first_retry_ms
    Process.send_after(self(), :poll, delay)
    {:noreply, state}
  end
end
