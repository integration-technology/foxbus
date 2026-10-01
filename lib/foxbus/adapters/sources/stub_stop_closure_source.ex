defmodule Foxbus.Adapters.Sources.StubStopClosureSource do
  @moduledoc "Always reports the stop is open, for developing without the network."
  @behaviour Foxbus.Ports.StopClosureSource

  @impl true
  def closure(_atco_code), do: {:ok, nil}
end
