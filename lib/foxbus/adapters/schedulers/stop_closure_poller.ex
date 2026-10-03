defmodule Foxbus.Adapters.Schedulers.StopClosurePoller do
  @moduledoc """
  Driving adapter, one per watched stop: polls `Foxbus.StopClosures` for that
  stop every 5 minutes — the same cadence as `DisruptionPoller`, since a stop
  closure notice changes about as rarely as a line-wide one.

  Until the first check lands, a stop screen shows "Checking times" rather
  than risk a scheduled bus time ahead of knowing whether the stop is
  closed (see `Foxbus.Screens`) — so a run of failures here leaves the
  display stuck, not just this process quiet. The first success is logged
  (once, at info) alongside every failure (at warning, every time) so a
  stuck boot is visible in the log without having to guess.
  """
  use GenServer
  require Logger

  @interval_ms 5 * 60_000

  def start_link({stop, atco_code}),
    do: GenServer.start_link(__MODULE__, {stop, atco_code}, name: :"#{__MODULE__}.#{stop}")

  @impl true
  def init({stop, atco_code}) do
    send(self(), :poll)
    {:ok, %{stop: stop, atco_code: atco_code, logged_first_success?: false}}
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      case Foxbus.StopClosures.check_and_publish(state.stop, state.atco_code) do
        {:error, reason} ->
          Logger.warning(
            "foxbus: stop closure check failed for #{state.stop}: #{inspect(reason)}"
          )

          state

        _ ->
          unless state.logged_first_success?,
            do: Logger.info("foxbus: stop closure check first succeeded for #{state.stop}")

          %{state | logged_first_success?: true}
      end

    Process.send_after(self(), :poll, @interval_ms)
    {:noreply, state}
  end
end
