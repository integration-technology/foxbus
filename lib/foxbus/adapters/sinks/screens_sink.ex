defmodule Foxbus.Adapters.Sinks.ScreensSink do
  @moduledoc """
  Sends a stop's arrivals, its disruption status, or its closure
  explanation, to the Nest's screens.
  """
  @behaviour Foxbus.Ports.ArrivalsSink
  @behaviour Foxbus.Ports.DisruptionsSink
  @behaviour Foxbus.Ports.StopClosureSink

  @impl Foxbus.Ports.ArrivalsSink
  def publish(stop, arrivals), do: Foxbus.Screens.show_arrivals(stop, arrivals)

  @impl Foxbus.Ports.DisruptionsSink
  def publish_disruption(stop, explanation), do: Foxbus.Screens.show_disruption(stop, explanation)

  @impl Foxbus.Ports.StopClosureSink
  def publish_closure(stop, explanation), do: Foxbus.Screens.show_closure(stop, explanation)
end
