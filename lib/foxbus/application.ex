defmodule Foxbus.Application do
  @moduledoc false
  use Application
  alias Foxbus.Adapters.Schedulers.{AdaptiveBusPoller, DisruptionPoller, StopClosurePoller}

  @impl true
  def start(_type, _args) do
    # One-time carry-over from the pre-0.3.0 config.exs/screen_power.exs
    # files into NestGen2.Storage, for an existing install — no-ops once
    # Storage already has the values. See Foxbus.Config and
    # Foxbus.ScreenPower's moduledocs.
    Foxbus.Config.migrate_from_file()
    Foxbus.Config.migrate_legacy_stops()
    Foxbus.ScreenPower.migrate_from_file()

    # NestGen2.Power always starts from its own defaults — put back whatever
    # was last saved from the settings UI, if anything (see Foxbus.ScreenPower).
    Foxbus.ScreenPower.apply_saved()

    stops =
      for stop <- Foxbus.Config.stops() do
        {stop, Foxbus.Ports.Provider.resolve(stop.provider)}
      end

    bus_pollers =
      for {stop, provider} <- stops do
        Supervisor.child_spec(
          {AdaptiveBusPoller, {provider, stop.key, stop.stop_id, stop.lines}},
          id: {:bus_poller, stop.key}
        )
      end

    closure_pollers =
      for {stop, provider} <- stops, provider.closures?() do
        Supervisor.child_spec({StopClosurePoller, {provider, stop.key, stop.stop_id}},
          id: {:closure_poller, stop.key}
        )
      end

    disruption_pollers =
      for {stop, provider} <- stops, provider.disruptions?() do
        Supervisor.child_spec(
          {DisruptionPoller, {provider, stop.key, stop.stop_id, stop.lines}},
          id: {:disruption_poller, stop.key}
        )
      end

    children =
      [Foxbus.Screens] ++ bus_pollers ++ closure_pollers ++ disruption_pollers

    Supervisor.start_link(children, strategy: :one_for_one, name: Foxbus.Supervisor)
  end
end
