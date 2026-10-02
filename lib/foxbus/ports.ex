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
  Inbound port: anything that can answer "is any of these lines disrupted
  right now?" Takes a list (not one line) so an adapter backed by a single
  page fetch (like Carousel's) can answer for every watched line from one
  request, rather than being called once per line.
  """

  @callback disrupted?(lines :: [String.t()]) :: {:ok, boolean} | {:error, term}
end

defmodule Foxbus.Ports.DisruptionsSink do
  @moduledoc """
  Outbound port: anything that shows a line's disruption status — the Nest's
  screens here.
  """

  @callback publish(disrupted? :: boolean) :: :ok | {:error, term}
end

defmodule Foxbus.Ports.StopClosureSource do
  @moduledoc """
  Inbound port: anything that can answer "is this specific stop unservable
  right now, and if so why?" — distinct from DisruptionsSource, which only
  answers for a line as a whole.
  """

  @callback closure(atco_code :: String.t()) :: {:ok, String.t() | nil} | {:error, term}
end

defmodule Foxbus.Ports.StopClosureSink do
  @moduledoc """
  Outbound port: anything that shows a stop's closure explanation (or clears
  it) — the Nest's screens here. Named publish_closure/2, not publish/2, so it
  doesn't collide with ArrivalsSink's publish/2 in a module implementing both.
  """

  @callback publish_closure(stop :: atom, explanation :: String.t() | nil) :: :ok | {:error, term}
end
