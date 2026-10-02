defmodule Foxbus.Adapters.Sources.FakeWifiSource do
  @moduledoc """
  Simulated Wi-Fi, for developing and testing the settings screens before
  nest_gen2 0.2.0 (`NestGen2.Wifi`) exists.

  Deterministic and stateless — `connect/2` doesn't actually change what
  `status/0` later reports, since nothing here persists between calls. Good
  enough to exercise `Foxbus.Screens.Settings`' screen flow and
  `Foxbus.Screens.SettingsLayout`'s rendering; not a real network simulation.

  Password `"wrong"` always fails with `:wrong_password`; any other password
  (including `nil`, for an open or already-saved network) succeeds.
  """
  @behaviour Foxbus.Ports.WifiSource

  @networks [
    %{ssid: "HomeWifi", signal_dbm: -52, secured: true, saved: true},
    %{ssid: "Neighbour5G", signal_dbm: -68, secured: true, saved: false},
    %{ssid: "CoffeeShop", signal_dbm: -74, secured: false, saved: false}
  ]

  @impl true
  def status, do: %{state: :connected, ssid: "HomeWifi", ip: "192.168.1.42", signal_dbm: -52}

  @impl true
  def scan, do: {:ok, @networks}

  @impl true
  def connect(_ssid, "wrong"), do: {:error, :wrong_password}
  def connect(ssid, _password), do: {:ok, %{ssid: ssid, ip: "192.168.1.99"}}

  @impl true
  def saved_networks, do: for(%{saved: true, ssid: ssid} <- @networks, do: ssid)

  @impl true
  def forget(ssid) do
    if ssid in saved_networks(), do: :ok, else: {:error, :not_found}
  end
end
