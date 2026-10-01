defmodule Foxbus.Adapters.Sinks.ScreensSink do
  @moduledoc "Sends a stop's arrivals, or the line's disruption status, to the Nest's screens."
  @behaviour Foxbus.Ports.ArrivalsSink
  @behaviour Foxbus.Ports.DisruptionsSink

  @impl Foxbus.Ports.ArrivalsSink
  def publish(stop, arrivals), do: Foxbus.Screens.show_arrivals(stop, arrivals)

  @impl Foxbus.Ports.DisruptionsSink
  def publish(disrupted?), do: Foxbus.Screens.show_disruption(disrupted?)
end
