defmodule Foxbus.Application do
  @moduledoc false
  use Application
  alias Foxbus.Adapters.Schedulers.{AdaptiveBusPoller, DisruptionPoller, StopClosurePoller}

  # Spread each poller's first fetch out, rather than every one firing its
  # own HTTPS request (TLS handshake, plus HTML/JSON parsing) in the same
  # instant at boot — on this single-core device that starved the Carousel
  # requests into timing out, competing with TfL's for the one scheduler,
  # once a third stop/provider was added (seen on the real device).
  @stagger_step_ms 300

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

    pollers =
      stops
      |> Enum.flat_map(fn {stop, provider} ->
        [{:bus, stop, provider}] ++
          if(provider.closures?(), do: [{:closure, stop, provider}], else: []) ++
          if(provider.disruptions?(), do: [{:disruption, stop, provider}], else: [])
      end)
      |> Enum.with_index()
      |> Enum.map(fn {spec, index} -> child_spec(spec, index * @stagger_step_ms) end)

    children = [Foxbus.Screens | pollers]

    Supervisor.start_link(children, strategy: :one_for_one, name: Foxbus.Supervisor)
  end

  defp child_spec({:bus, stop, provider}, delay_ms) do
    Supervisor.child_spec(
      {AdaptiveBusPoller, {provider, stop.key, stop.stop_id, stop.lines, delay_ms}},
      id: {:bus_poller, stop.key}
    )
  end

  defp child_spec({:closure, stop, provider}, delay_ms) do
    Supervisor.child_spec(
      {StopClosurePoller, {provider, stop.key, stop.stop_id, delay_ms}},
      id: {:closure_poller, stop.key}
    )
  end

  defp child_spec({:disruption, stop, provider}, delay_ms) do
    Supervisor.child_spec(
      {DisruptionPoller, {provider, stop.key, stop.stop_id, stop.lines, delay_ms}},
      id: {:disruption_poller, stop.key}
    )
  end
end
