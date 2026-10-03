defmodule Foxbus.Adapters.Schedulers.AdaptiveBusPoller do
  @moduledoc """
  Driving adapter, one per watched stop: polls `Foxbus.Arrivals` on an interval
  set by how urgent the board is.

    * every 60 s normally
    * every 30 s once the next bus is 5 minutes away or less
    * every 30 minutes when a fetch returns no buses at all (end of service,
      which also covers Sundays without any day-of-week logic)

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

  def start_link({stop, stop_id}),
    do: GenServer.start_link(__MODULE__, {stop, stop_id}, name: :"#{__MODULE__}.#{stop}")

  @impl true
  def init({stop, stop_id}) do
    send(self(), :poll)
    {:ok, %{stop: stop, stop_id: stop_id, logged_first_success?: false}}
  end

  @impl true
  def handle_info(:poll, state) do
    result = Foxbus.Arrivals.fetch_and_publish(state.stop, state.stop_id)

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

    Process.send_after(self(), :poll, next_delay(result))
    {:noreply, state}
  end

  @doc "How long to wait before the next poll, given the last result."
  @spec next_delay({:ok, [Arrival.t()]} | {:error, term}) :: pos_integer
  def next_delay({:ok, []}), do: @no_service_retry_ms

  def next_delay({:ok, [%Arrival{eta_minutes: eta} | _]}) when eta <= @tight_threshold_minutes,
    do: @tight_interval_ms

  def next_delay({:ok, _}), do: @base_interval_ms
  def next_delay({:error, _}), do: @base_interval_ms
end
