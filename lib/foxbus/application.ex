defmodule Foxbus.Application do
  @moduledoc false
  use Application
  alias Foxbus.Adapters.Schedulers.{AdaptiveBusPoller, DisruptionPoller, StopClosurePoller}

  @impl true
  def start(_type, _args) do
    # NestGen2.Power always starts from its own defaults — put back whatever
    # was last saved from the settings UI, if anything (see Foxbus.ScreenPower).
    Foxbus.ScreenPower.apply_saved()

    stops = Foxbus.Config.stops()

    bus_pollers =
      for {stop, stop_id, _title} <- stops do
        Supervisor.child_spec({AdaptiveBusPoller, {stop, stop_id}}, id: {:bus_poller, stop})
      end

    closure_pollers =
      for {stop, stop_id, _title} <- stops do
        Supervisor.child_spec({StopClosurePoller, {stop, stop_id}}, id: {:closure_poller, stop})
      end

    lines = Foxbus.Config.lines()

    disruption_pollers =
      for {stop, stop_id, _title} <- stops do
        Supervisor.child_spec({DisruptionPoller, {stop, stop_id, lines}},
          id: {:disruption_poller, stop}
        )
      end

    children =
      [Foxbus.Screens] ++ bus_pollers ++ closure_pollers ++ disruption_pollers

    Supervisor.start_link(children, strategy: :one_for_one, name: Foxbus.Supervisor)
  end
end
