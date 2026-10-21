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
  right now at this stop, and if so what does the notice say?" Takes a list
  of lines (not one) so an adapter backed by a single page fetch (like
  Carousel's) can answer for every watched line from one request, rather
  than being called once per line. Takes one stop's own id — an ATCO code
  for Carousel, but opaque and provider-specific in general (a NaPTAN id, a
  CRS code, ...) — since a notice naming specific affected stops shouldn't
  show on a stop it doesn't name — see
  `Foxbus.Adapters.Sources.CarouselDisruptionsSource`.
  """

  @callback disrupted?(lines :: [String.t()], stop_id :: String.t()) ::
              {:ok, String.t() | nil} | {:error, term}
end

defmodule Foxbus.Ports.DisruptionsSink do
  @moduledoc """
  Outbound port: anything that shows a stop's disruption status (or clears
  it) — the Nest's screens here. Named publish_disruption/2, not publish/2,
  so it doesn't collide with ArrivalsSink's publish/2 in a module
  implementing both.
  """

  @callback publish_disruption(stop :: atom, explanation :: String.t() | nil) ::
              :ok | {:error, term}
end

defmodule Foxbus.Ports.StopClosureSource do
  @moduledoc """
  Inbound port: anything that can answer "is this specific stop unservable
  right now, and if so why?" — distinct from DisruptionsSource, which only
  answers for a line as a whole. Optional: not every provider has a concept
  of a single stop being closed (TfL has line status, not this) — see
  `Foxbus.Ports.Provider`.
  """

  @callback closure(stop_id :: String.t()) :: {:ok, String.t() | nil} | {:error, term}
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
  Inbound port: Wi-Fi status, scanning, connecting, and saving a network for
  later. Backed by `NestGen2.Wifi` (nest_gen2 >= 0.2.0; `save/2` needs
  >= 0.3.0) in production, or a fake for developing and testing the
  settings screens without it.

  `scan/0` and `connect/2` are expected to block for several seconds to tens
  of seconds — callers (see `Foxbus.Screens.Settings`) must run them in a
  `Task`, never directly from `Foxbus.Screens`' `handle_*`, or the whole
  display freezes until they return. `save/2` is quick (no join attempt, no
  DHCP wait) and is called directly, no `Task`.
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
  @callback save(ssid :: String.t(), password :: String.t() | nil) ::
              :ok | {:error, :bad_password_length | :unavailable | term}
end

defmodule Foxbus.Ports.Provider do
  @moduledoc """
  A data-provider adapter bundles everything a screen needs: fetching
  arrivals is mandatory (`fetch_arrivals/2` — takes the stop's own watched
  `lines` too, not just its id, since a per-line source like TfL's
  timetable genuinely needs to know which line it's being asked for;
  Carousel's board-scrape ignores it and returns everything, same as
  before). Disruption and stop-closure reporting are optional capabilities
  a provider may have no concept of —
  TfL has line status but nothing shaped like "this stop is closed";
  National Rail has cancellations, not a per-station closure notice either.
  Every provider must still declare `disruptions?/0`/`closures?/0`
  (mandatory, unlike the rest of this paragraph) — these say whether the
  provider also defines `disrupted?/2` (`Foxbus.Ports.DisruptionsSource`) /
  `closure/1` (`Foxbus.Ports.StopClosureSource`) as plain functions (not
  `@callback`s here, since not every provider has them); a provider that
  doesn't is simply never asked, rather than having to fake an answer for a
  port it has no real concept for. `Foxbus.Application` checks
  `disruptions?/0`/`closures?/0` before starting the matching poller at
  all, so `disrupted?/2`/`closure/1` are only ever called on a provider
  that actually defines them.

  `all/0` is the fixed, compiled-in set of providers foxbus knows about —
  adding a new one is a code change (a new module implementing this
  behaviour, added to the list here), not something loaded at runtime: this
  device has no process isolation between a "plugin" and the rest of the
  app, and no signing/trust story for code reaching it from anywhere else.
  """

  alias Foxbus.Domain.Arrival

  @callback id() :: atom
  @callback label() :: String.t()
  @callback fetch_arrivals(stop_id :: String.t(), lines :: [String.t()]) ::
              {:ok, [Arrival.t()]} | {:error, term}
  @callback disruptions?() :: boolean
  @callback closures?() :: boolean

  @doc "Every provider foxbus knows about, compiled in."
  @spec all() :: [module]
  def all,
    do: [
      Foxbus.Adapters.Sources.CarouselProvider,
      Foxbus.Adapters.Sources.TflProvider,
      Foxbus.Adapters.Sources.BustimesProvider,
      Foxbus.Adapters.Sources.StagecoachProvider
    ]

  @doc "The provider module for a stored provider id, e.g. :carousel."
  @spec resolve(atom) :: module
  def resolve(id) do
    Enum.find(all(), &(&1.id() == id)) ||
      raise ArgumentError, "unknown foxbus provider: #{inspect(id)}"
  end
end
