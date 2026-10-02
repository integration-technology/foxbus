defmodule Foxbus.Adapters.Sources.NestGen2WifiSource do
  @moduledoc """
  Wi-Fi status, scanning and connecting via `NestGen2.Wifi` (nest_gen2 >= 0.2.0).

  A thin pass-through: there is no parsing or logic here to unit test, unlike
  the Carousel adapters, so this is exercised by `Foxbus.Screens.Settings`'
  tests via `Foxbus.Adapters.Sources.FakeWifiSource` instead, and by hand on
  the device once nest_gen2 0.2.0 is available.
  """
  @behaviour Foxbus.Ports.WifiSource

  @impl true
  def status, do: NestGen2.Wifi.status()

  @impl true
  def scan, do: NestGen2.Wifi.scan()

  @impl true
  def connect(ssid, password), do: NestGen2.Wifi.connect(ssid, password)

  @impl true
  def saved_networks, do: NestGen2.Wifi.saved_networks()

  @impl true
  def forget(ssid), do: NestGen2.Wifi.forget(ssid)
end
