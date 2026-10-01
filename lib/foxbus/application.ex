defmodule Foxbus.Application do
  @moduledoc false
  use Application
  alias Foxbus.Adapters.Schedulers.{AdaptiveBusPoller, DisruptionPoller}

  @impl true
  def start(_type, _args) do
    pollers =
      for {stop, stop_id, _title} <- Application.fetch_env!(:foxbus, :stops) do
        Supervisor.child_spec({AdaptiveBusPoller, {stop, stop_id}}, id: {:poller, stop})
      end

    line = Application.fetch_env!(:foxbus, :disruptions_line)

    Supervisor.start_link([Foxbus.Screens | pollers] ++ [{DisruptionPoller, line}],
      strategy: :one_for_one,
      name: Foxbus.Supervisor
    )
  end
end
