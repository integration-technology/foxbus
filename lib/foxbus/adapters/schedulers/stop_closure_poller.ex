defmodule Foxbus.Adapters.Schedulers.StopClosurePoller do
  @moduledoc """
  Driving adapter, one per watched stop: polls `Foxbus.StopClosures` for that
  stop every 5 minutes — the same cadence as `DisruptionPoller`, since a stop
  closure notice changes about as rarely as a line-wide one.
  """
  use GenServer
  require Logger

  @interval_ms 5 * 60_000

  def start_link({stop, atco_code}),
    do: GenServer.start_link(__MODULE__, {stop, atco_code}, name: :"#{__MODULE__}.#{stop}")

  @impl true
  def init({stop, atco_code}) do
    send(self(), :poll)
    {:ok, %{stop: stop, atco_code: atco_code}}
  end

  @impl true
  def handle_info(:poll, state) do
    case Foxbus.StopClosures.check_and_publish(state.stop, state.atco_code) do
      {:error, reason} ->
        Logger.warning("foxbus: stop closure check failed for #{state.stop}: #{inspect(reason)}")

      _ ->
        :ok
    end

    Process.send_after(self(), :poll, @interval_ms)
    {:noreply, state}
  end
end
