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
  right now, and if so what does the notice say?" Takes a list (not one
  line) so an adapter backed by a single page fetch (like Carousel's) can
  answer for every watched line from one request, rather than being called
  once per line.
  """

  @callback disrupted?(lines :: [String.t()]) :: {:ok, String.t() | nil} | {:error, term}
end

defmodule Foxbus.Ports.DisruptionsSink do
  @moduledoc """
  Outbound port: anything that shows a line's disruption status (or clears
  it) — the Nest's screens here.
  """

  @callback publish(explanation :: String.t() | nil) :: :ok | {:error, term}
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

defmodule Foxbus.Ports.WifiSource do
  @moduledoc """
  Inbound port: Wi-Fi status, scanning, and connecting. Backed by
  `NestGen2.Wifi` (nest_gen2 >= 0.2.0) in production, or a fake for
  developing and testing the settings screens without it.

  `scan/0` and `connect/2` are expected to block for several seconds to tens
  of seconds — callers (see `Foxbus.Screens.Settings`) must run them in a
  `Task`, never directly from `Foxbus.Screens`' `handle_*`, or the whole
  display freezes until they return.
  """

  @type status :: %{
          state: :connected | :connecting | :disconnected | :unavailable,
          ssid: String.t() | nil,
          ip: String.t() | nil,
          signal_dbm: integer | nil
        }

  @type network :: %{ssid: String.t(), signal_dbm: integer, secured: boolean, saved: boolean}

  @callback status() :: status
  @callback scan() :: {:ok, [network]} | {:error, term}
  @callback connect(ssid :: String.t(), password :: String.t() | nil) ::
              {:ok, %{ssid: String.t(), ip: String.t()}}
              | {:error, :wrong_password | :not_found | :no_ip | :timeout | term}
  @callback saved_networks() :: [String.t()]
  @callback forget(ssid :: String.t()) :: :ok | {:error, :not_found | :connected}
end
