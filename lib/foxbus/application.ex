defmodule Foxbus.Application do
  @moduledoc false
  use Application
  alias Foxbus.Adapters.Schedulers.{AdaptiveBusPoller, DisruptionPoller, StopClosurePoller}

  @impl true
  def start(_type, _args) do
    stops = Application.fetch_env!(:foxbus, :stops)

    bus_pollers =
      for {stop, stop_id, _title} <- stops do
        Supervisor.child_spec({AdaptiveBusPoller, {stop, stop_id}}, id: {:bus_poller, stop})
      end

    closure_pollers =
      for {stop, stop_id, _title} <- stops do
        Supervisor.child_spec({StopClosurePoller, {stop, stop_id}}, id: {:closure_poller, stop})
      end

    line = Application.fetch_env!(:foxbus, :disruptions_line)

    children =
      [Foxbus.Screens] ++ bus_pollers ++ closure_pollers ++ [{DisruptionPoller, line}]

    Supervisor.start_link(children, strategy: :one_for_one, name: Foxbus.Supervisor)
  end
end
