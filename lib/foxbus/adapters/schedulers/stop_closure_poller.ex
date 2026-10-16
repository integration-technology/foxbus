defmodule Foxbus.Adapters.Schedulers.StopClosurePoller do
  @moduledoc """
  Driving adapter, one per watched stop whose provider has this capability
  (see `Foxbus.Ports.Provider.closures?/0` — `Foxbus.Application` only
  starts this for such a stop): polls `Foxbus.StopClosures` for that stop
  every 5 minutes — the same cadence as `DisruptionPoller`, since a stop
  closure notice changes about as rarely as a line-wide one.

  Until the first check lands, a stop screen shows "Checking times" rather
  than risk a scheduled bus time ahead of knowing whether the stop is
  closed (see `Foxbus.Screens`) — so a run of failures here leaves the
  display stuck, not just this process quiet. The first success is logged
  (once, at info) alongside every failure (at warning, every time) so a
  stuck boot is visible in the log without having to guess. A stop whose
  provider has no closures capability never gets this poller at all —
  `Foxbus.Screens` pre-seeds its closure status as "open" at boot instead,
  so it never shows "Checking times" waiting for a check that will never
  come.
  """
  use GenServer
  require Logger

  @interval_ms 5 * 60_000

  def start_link({provider, stop, stop_id}),
    do:
      GenServer.start_link(__MODULE__, {provider, stop, stop_id}, name: :"#{__MODULE__}.#{stop}")

  @impl true
  def init({provider, stop, stop_id}) do
    send(self(), :poll)
    {:ok, %{provider: provider, stop: stop, stop_id: stop_id, logged_first_success?: false}}
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      case Foxbus.StopClosures.check_and_publish(state.provider, state.stop, state.stop_id) do
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
