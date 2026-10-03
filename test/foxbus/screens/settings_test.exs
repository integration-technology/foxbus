defmodule Foxbus.Screens.SettingsTest do
  use ExUnit.Case, async: true
  alias Foxbus.Screens.Settings

  @status %{state: :connected, ssid: "HomeWifi", ip: "192.168.1.42", signal_dbm: -52}
  @versions %{foxbus: "0.1.1", sdk: "0.2.0"}
  @screen_power %{idle_timeout_ms: 30_000, wake_on_approach?: true}

  defp open, do: Settings.open(@status, @versions, @screen_power)

  defp network(ssid, opts \\ []) do
    %{
      ssid: ssid,
      signal_dbm: Keyword.get(opts, :signal_dbm, -60),
      secured: Keyword.get(opts, :secured, true),
      saved: Keyword.get(opts, :saved, false)
    }
  end

  describe "open/2" do
    test "starts on the menu, carrying the status and versions" do
      s = open()
      assert s.screen == :menu
      assert s.wifi_status == @status
      assert s.versions == @versions
      assert s.highlight == 0
    end
  end

  describe "wifi_updated/2" do
    test "refreshes the shown status without changing screen" do
      s = open() |> Settings.wifi_updated(%{@status | ip: "192.168.1.50"})
      assert s.wifi_status.ip == "192.168.1.50"
      assert s.screen == :menu
    end
  end

  describe "menu navigation and selection" do
    test "turning wraps between the three items" do
      s = open()
      assert s.highlight == 0
      s = Settings.navigate(s, :cw)
      assert s.highlight == 1
      s = Settings.navigate(s, :cw)
      assert s.highlight == 2
      s = Settings.navigate(s, :cw)
      assert s.highlight == 0
      s = Settings.navigate(s, :ccw)
      assert s.highlight == 2
    end

    test "selecting Change Wi-Fi (highlight 0) moves to scanning and asks the caller to scan" do
      assert {%{screen: :scanning}, :scan} = Settings.select(open())
    end

    test "selecting Screen (highlight 1) moves to the screen-power screen" do
      s = open() |> Settings.navigate(:cw)
      assert {%{screen: :screen_power, highlight: 0}, nil} = Settings.select(s)
    end

    test "selecting Back (highlight 2) asks the caller to exit to the splash" do
      s = open() |> Settings.navigate(:cw) |> Settings.navigate(:cw)
      assert {_s, :exit_to_splash} = Settings.select(s)
    end
  end

  describe "screen-power screen" do
    defp at_screen_power do
      open() |> Map.put(:screen, :screen_power)
    end

    test "opens carrying the current idle timeout and wake-on-approach choice" do
      screen_power = %{idle_timeout_ms: 300_000, wake_on_approach?: false}
      s = Settings.open(@status, @versions, screen_power)
      assert s.idle_timeout_ms == 300_000
      assert s.wake_on_approach? == false
    end

    test "turning moves between the three rows and wraps" do
      s = at_screen_power()
      assert s.highlight == 0
      s = Settings.navigate(s, :cw)
      assert s.highlight == 1
      s = Settings.navigate(s, :cw)
      assert s.highlight == 2
      s = Settings.navigate(s, :cw)
      assert s.highlight == 0
      s = Settings.navigate(s, :ccw)
      assert s.highlight == 2
    end

    test "selecting the Screen row cycles 30 s -> 1 min -> 5 min -> Always on -> 30 s" do
      s = at_screen_power()
      assert s.idle_timeout_ms == 30_000

      {s, {:screen_power, choice}} = Settings.select(s)
      assert s.idle_timeout_ms == 60_000
      assert choice == %{idle_timeout_ms: 60_000, wake_on_approach?: true}

      {s, {:screen_power, _}} = Settings.select(s)
      assert s.idle_timeout_ms == 300_000

      {s, {:screen_power, _}} = Settings.select(s)
      assert s.idle_timeout_ms == :infinity

      {s, {:screen_power, _}} = Settings.select(s)
      assert s.idle_timeout_ms == 30_000
    end

    test "selecting the Wake on approach row (highlight 1) toggles it" do
      s = %{at_screen_power() | highlight: 1}
      assert s.wake_on_approach? == true

      {s, {:screen_power, choice}} = Settings.select(s)
      assert s.wake_on_approach? == false
      assert choice == %{idle_timeout_ms: 30_000, wake_on_approach?: false}

      {s, {:screen_power, choice}} = Settings.select(s)
      assert s.wake_on_approach? == true
      assert choice == %{idle_timeout_ms: 30_000, wake_on_approach?: true}
    end

    test "selecting Back (highlight 2) returns to the menu, no effect" do
      s = %{at_screen_power() | highlight: 2}
      assert {%{screen: :menu, highlight: 1}, nil} = Settings.select(s)
    end

    test "idle_timeout_label/1 shows seconds, minutes, or Always on" do
      assert Settings.idle_timeout_label(30_000) == "30 s"
      assert Settings.idle_timeout_label(60_000) == "1 min"
      assert Settings.idle_timeout_label(300_000) == "5 min"
      assert Settings.idle_timeout_label(:infinity) == "Always on"
    end
  end

  describe "scan_result/2" do
    test "success moves to the networks screen with the results" do
      s = open() |> Settings.select() |> elem(0)
      networks = [network("A"), network("B")]
      s = Settings.scan_result(s, {:ok, networks})
      assert s.screen == :networks
      assert s.networks == networks
      assert s.highlight == 0
    end

    test "failure still moves to the networks screen, with an empty list" do
      s = %{open() | screen: :scanning} |> Settings.scan_result({:error, :timeout})
      assert s.screen == :networks
      assert s.networks == []
    end
  end

  describe "networks screen" do
    defp at_networks(networks) do
      open()
      |> Map.put(:screen, :networks)
      |> Map.put(:networks, networks)
    end

    test "turning moves through networks and wraps past Back" do
      s = at_networks([network("A"), network("B")])
      assert s.highlight == 0
      s = Settings.navigate(s, :cw)
      assert s.highlight == 1
      # highlight 2 == "Back" (length(networks))
      s = Settings.navigate(s, :cw)
      assert s.highlight == 2
      s = Settings.navigate(s, :cw)
      assert s.highlight == 0
    end

    test "selecting Back returns to the menu" do
      s = at_networks([network("A")]) |> Map.put(:highlight, 1)
      assert {%{screen: :menu, highlight: 0}, nil} = Settings.select(s)
    end

    test "selecting an open network connects directly, no password screen" do
      s = at_networks([network("CoffeeShop", secured: false)])
      assert {%{screen: :connecting}, {:connect, "CoffeeShop", nil}} = Settings.select(s)
    end

    test "selecting an already-saved secured network connects directly" do
      s = at_networks([network("HomeWifi", secured: true, saved: true)])
      assert {%{screen: :connecting}, {:connect, "HomeWifi", nil}} = Settings.select(s)
    end

    test "selecting a secured, unsaved network goes to the password screen" do
      s = at_networks([network("Neighbour5G", secured: true, saved: false)])

      assert {%{screen: :password, password: "", wheel_group: :upper} = new_s, nil} =
               Settings.select(s)

      assert new_s.selected_network.ssid == "Neighbour5G"
    end
  end

  describe "the password wheel" do
    defp at_password do
      open()
      |> Map.put(:screen, :password)
      |> Map.put(:selected_network, network("Neighbour5G"))
    end

    test "wheel_entries/1 lists the group's characters, other groups, then controls" do
      entries = Settings.wheel_entries(:upper)
      assert {:char, "A"} in entries
      assert {:switch, :lower} in entries
      assert {:switch, :digits} in entries
      assert {:switch, :symbols} in entries
      refute {:switch, :upper} in entries
      assert List.last(entries) == :cancel
      assert Enum.at(entries, -2) == :done
      assert Enum.at(entries, -3) == :delete
    end

    test "wheel_label/1 shows the character, or a label/glyph for controls" do
      assert Settings.wheel_label({:char, "A"}) == "A"
      assert Settings.wheel_label({:switch, :lower}) == "abc"
      assert Settings.wheel_label({:switch, :digits}) == "123"
      assert Settings.wheel_label({:switch, :symbols}) == "#+="
      assert Settings.wheel_label(:delete) == "⌫"
      assert Settings.wheel_label(:done) == "✓"
      assert Settings.wheel_label(:cancel) == "✗"
    end

    test "turning moves the wheel index and wraps" do
      s = at_password()
      count = length(Settings.wheel_entries(:upper))
      s = Settings.navigate(s, :ccw)
      assert s.wheel_index == count - 1
      s = Settings.navigate(s, :cw)
      assert s.wheel_index == 0
    end

    test "selecting a character appends it to the typed password" do
      s = at_password()
      {s, nil} = Settings.select(s)
      assert s.password == "A"
    end

    test "selecting a group switch changes group and resets the wheel index" do
      s = %{at_password() | wheel_index: 5}
      switch_index = Enum.find_index(Settings.wheel_entries(:upper), &(&1 == {:switch, :lower}))
      s = %{s | wheel_index: switch_index}
      {s, nil} = Settings.select(s)
      assert s.wheel_group == :lower
      assert s.wheel_index == 0
    end

    test "delete removes the last typed character, and does nothing on empty" do
      s = %{at_password() | password: "Ab"}
      delete_index = Enum.find_index(Settings.wheel_entries(:upper), &(&1 == :delete))
      s = %{s | wheel_index: delete_index}
      {s, nil} = Settings.select(s)
      assert s.password == "A"
      {s, nil} = Settings.select(s)
      assert s.password == ""
      {s, nil} = Settings.select(s)
      assert s.password == ""
    end

    test "done asks the caller to connect with the typed password" do
      done_index = Enum.find_index(Settings.wheel_entries(:upper), &(&1 == :done))
      s = %{at_password() | password: "letmein", wheel_index: done_index}
      assert {%{screen: :connecting}, {:connect, "Neighbour5G", "letmein"}} = Settings.select(s)
    end

    test "cancel returns to the networks screen" do
      cancel_index = Enum.find_index(Settings.wheel_entries(:upper), &(&1 == :cancel))
      s = %{at_password() | wheel_index: cancel_index}
      assert {%{screen: :networks, highlight: 0}, nil} = Settings.select(s)
    end
  end

  describe "scanning screen" do
    test "button presses are ignored while scanning" do
      s = %{open() | screen: :scanning}
      assert {^s, nil} = Settings.select(s)
    end
  end

  describe "connecting screen" do
    test "button presses are ignored while connecting" do
      s = %{open() | screen: :connecting}
      assert {^s, nil} = Settings.select(s)
    end
  end

  describe "connect_result/2 and the result screen" do
    test "success moves to the result screen" do
      s =
        %{open() | screen: :connecting}
        |> Settings.connect_result({:ok, %{ssid: "A", ip: "1.2.3.4"}})

      assert s.screen == :result
      assert s.connect_result == {:ok, %{ssid: "A", ip: "1.2.3.4"}}
    end

    test "selecting on a success result returns straight to the menu" do
      s =
        %{open() | screen: :connecting}
        |> Settings.connect_result({:ok, %{ssid: "A", ip: "1.2.3.4"}})

      assert {%{screen: :menu}, nil} = Settings.select(s)
    end

    test "a failure result offers Retry and Back, turning between them" do
      s =
        %{open() | screen: :connecting}
        |> Settings.connect_result({:error, :wrong_password})

      assert s.highlight == 0
      s = Settings.navigate(s, :cw)
      assert s.highlight == 1
      s = Settings.navigate(s, :cw)
      assert s.highlight == 0
    end

    test "Back on a failure returns to the networks screen" do
      s =
        %{open() | screen: :connecting, selected_network: network("Neighbour5G")}
        |> Settings.connect_result({:error, :wrong_password})
        |> Map.put(:highlight, 1)

      assert {%{screen: :networks, highlight: 0}, nil} = Settings.select(s)
    end

    test "Retry on a failed secured, unsaved network goes back to the password screen" do
      s =
        %{
          open()
          | screen: :connecting,
            selected_network: network("Neighbour5G", secured: true, saved: false)
        }
        |> Settings.connect_result({:error, :wrong_password})

      assert {%{screen: :password, password: ""}, nil} = Settings.select(s)
    end

    test "Retry on a failed open network connects directly again" do
      s =
        %{
          open()
          | screen: :connecting,
            selected_network: network("CoffeeShop", secured: false)
        }
        |> Settings.connect_result({:error, :timeout})

      assert {%{screen: :connecting}, {:connect, "CoffeeShop", nil}} = Settings.select(s)
    end
  end
end
