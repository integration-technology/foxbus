defmodule Foxbus.Ports.ArrivalsSource do
  @moduledoc """
  Inbound port: anything that can answer "what's due at this stop?"
  """
  alias Foxbus.Domain.Arrival

  @callback fetch_arrivals(stop_id :: String.t()) :: {:ok, [Arrival.t()]} | {:error, term}
end

defmodule Foxbus.Ports.ArrivalsSink do
  @moduledoc """
  Outbound port: anything that shows or publishes a stop's arrivals — the Nest's
  screens here; a console, MQTT or a web page would fit the same port.
  """
  alias Foxbus.Domain.Arrival

  @callback publish(stop :: atom, arrivals :: [Arrival.t()]) :: :ok | {:error, term}
end

defmodule Foxbus.Ports.DisruptionsSource do
  @moduledoc """
  Inbound port: anything that can answer "is this line disrupted right now?"
  """

  @callback disrupted?(line :: String.t()) :: {:ok, boolean} | {:error, term}
end

defmodule Foxbus.Ports.DisruptionsSink do
  @moduledoc """
  Outbound port: anything that shows a line's disruption status — the Nest's
  screens here.
  """

  @callback publish(disrupted? :: boolean) :: :ok | {:error, term}
end
