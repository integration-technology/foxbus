defmodule Foxbus.Adapters.Sources.StubDisruptionsSource do
  @moduledoc "Always reports all clear, for developing without the network."
  @behaviour Foxbus.Ports.DisruptionsSource

  @impl true
  def disrupted?(_lines), do: {:ok, nil}
end
