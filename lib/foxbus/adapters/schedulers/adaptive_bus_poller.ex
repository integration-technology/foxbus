defmodule Foxbus.Adapters.Schedulers.AdaptiveBusPoller do
  @moduledoc """
  Driving adapter, one per watched stop: polls `Foxbus.Arrivals` on an interval
  set by how urgent the board is.

    * every 60 s normally
    * every 30 s once the next bus is 5 minutes away or less
    * every 30 minutes when a fetch returns no buses at all (end of service,
      which also covers Sundays without any day-of-week logic)
    * every 10 s after a failure, until the very first fetch has ever
      succeeded — a slow Wi-Fi reconnect (e.g. just after waking from deep
      sleep) or start-up contention with other pollers (see
      `Foxbus.Application`'s staggered start) shouldn't mean waiting a full
      minute-plus for the next try

  Every failure is logged at warning; the first success is also logged, once,
  at info — so a stop stuck "Checking times" after boot (see
  `Foxbus.Screens`) leaves a trace of whether fetching ever worked at all,
  not just silence.
  """
  use GenServer
  require Logger
  alias Foxbus.Domain.Arrival

  @base_interval_ms 60_000
  @tight_interval_ms 30_000
  @tight_threshold_minutes 5
  @no_service_retry_ms 30 * 60_000
  @first_retry_ms 10_000

  def start_link({provider, stop, stop_id, lines, delay_ms}),
    do:
      GenServer.start_link(__MODULE__, {provider, stop, stop_id, lines, delay_ms},
        name: :"#{__MODULE__}.#{stop}"
      )

  @doc """
  Forces an immediate poll, bypassing the scheduled delay — for
  `Foxbus.Screens` to call right after the device wakes from deep sleep
  (nest_gen2's `:power` `:awake` event), since the last fetch could be
  minutes stale after a sleep of up to 270 s: a poller's own timer only
  counts awake time, so it wouldn't otherwise refetch until however much of
  its normal interval was still left when the device went to sleep. Doesn't
  cancel the timer already pending from the last scheduled poll, so one
  redundant fetch can follow shortly after — cheap and harmless, not worth
  tracking a timer ref to avoid.
  """
  @spec poll_now(atom) :: :ok
  def poll_now(stop), do: GenServer.cast(:"#{__MODULE__}.#{stop}", :poll_now)

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
  def handle_info(:poll, state), do: do_poll(state)

  @impl true
  def handle_cast(:poll_now, state), do: do_poll(state)

  defp do_poll(state) do
    result =
      Foxbus.Arrivals.fetch_and_publish(state.provider, state.stop, state.stop_id, state.lines)

    state =
      case result do
        {:error, reason} ->
          Logger.warning("foxbus: poll failed for #{state.stop}: #{inspect(reason)}")
          state

        {:ok, _} ->
          unless state.logged_first_success?,
            do: Logger.info("foxbus: poll first succeeded for #{state.stop}")

          %{state | logged_first_success?: true}
      end

    Process.send_after(self(), :poll, next_delay(result, state.logged_first_success?))
    {:noreply, state}
  end

  @doc """
  How long to wait before the next poll, given the last result and whether
  this stop has ever had a successful fetch yet.
  """
  @spec next_delay({:ok, [Arrival.t()]} | {:error, term}, boolean) :: pos_integer
  def next_delay({:error, _}, false), do: @first_retry_ms
  def next_delay({:ok, []}, _succeeded_before?), do: @no_service_retry_ms

  def next_delay({:ok, [%Arrival{eta_minutes: eta} | _]}, _succeeded_before?)
      when eta <= @tight_threshold_minutes,
      do: @tight_interval_ms

  def next_delay({:ok, _}, _succeeded_before?), do: @base_interval_ms
  def next_delay({:error, _}, true), do: @base_interval_ms
end
