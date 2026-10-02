defmodule Foxbus.Screens.SettingsLayoutTest do
  use ExUnit.Case, async: true
  alias Foxbus.Screens.{Settings, SettingsLayout}

  @status %{state: :connected, ssid: "HomeWifi", ip: "192.168.1.42", signal_dbm: -52}
  @versions %{foxbus: "0.1.1", sdk: "0.2.0"}

  defp texts(ops), do: for({:text, _x, _y, text, _opts} <- ops, do: text)
  defp background([{:background, bg} | _]), do: bg

  defp network(ssid, opts \\ []) do
    %{
      ssid: ssid,
      signal_dbm: Keyword.get(opts, :signal_dbm, -60),
      secured: Keyword.get(opts, :secured, true),
      saved: Keyword.get(opts, :saved, false)
    }
  end

  describe "menu" do
    test "shows the SSID, IP, and both versions" do
      ops = SettingsLayout.render(Settings.open(@status, @versions))
      assert "HomeWifi" in texts(ops)
      assert "192.168.1.42" in texts(ops)
      assert Enum.any?(texts(ops), &(&1 =~ "0.1.1" and &1 =~ "0.2.0"))
      assert background(ops) == "#1C1C1E"
    end

    test "shows placeholders when not connected" do
      status = %{state: :disconnected, ssid: nil, ip: nil, signal_dbm: nil}
      ops = SettingsLayout.render(Settings.open(status, @versions))
      assert "Not connected" in texts(ops)
      assert "—" in texts(ops)
    end

    test "highlighted menu item is marked, the other isn't" do
      ops = SettingsLayout.render(Settings.open(@status, @versions))
      assert "› Change Wi-Fi" in texts(ops)
      assert "Back" in texts(ops)
      refute "› Back" in texts(ops)
    end

    test "renders four signal bars, all colours present" do
      ops = SettingsLayout.render(Settings.open(@status, @versions))
      bars = for {:rect, _x, _y, _w, _h, color} <- ops, do: color
      assert length(bars) == 4
    end

    test "no bars drawn when signal is unknown" do
      status = %{@status | signal_dbm: nil}
      ops = SettingsLayout.render(Settings.open(status, @versions))
      assert Enum.count(ops, &match?({:rect, _, _, _, _, _}, &1)) == 0
    end

    test "the signal bars don't overlap the IP text" do
      ops = SettingsLayout.render(Settings.open(@status, @versions))

      {:text, _x, ip_y, "192.168.1.42", ip_opts} =
        Enum.find(ops, &match?({:text, _, _, "192.168.1.42", _}, &1))

      ip_bottom = ip_y + ip_opts[:size]
      bar_tops = for {:rect, _x, y, _w, _h, _color} <- ops, do: y
      assert Enum.all?(bar_tops, &(&1 >= ip_bottom))
    end
  end

  describe "scanning" do
    test "shows a scanning message" do
      s = %{Settings.open(@status, @versions) | screen: :scanning}
      assert "Scanning…" in texts(SettingsLayout.render(s))
    end
  end

  describe "networks" do
    defp at_networks(networks, highlight \\ 0) do
      Settings.open(@status, @versions)
      |> Map.put(:screen, :networks)
      |> Map.put(:networks, networks)
      |> Map.put(:highlight, highlight)
    end

    test "shows each network's SSID" do
      ops = at_networks([network("A"), network("B")]) |> SettingsLayout.render()
      assert Enum.any?(texts(ops), &String.contains?(&1, "A"))
      assert Enum.any?(texts(ops), &String.contains?(&1, "B"))
    end

    test "Back is always shown" do
      ops = at_networks([network("A")]) |> SettingsLayout.render()
      assert Enum.any?(texts(ops), &String.contains?(&1, "Back"))
    end

    test "first page shows the first window of networks when highlight is near the top" do
      networks = for n <- 1..10, do: network("N#{n}")
      ops = at_networks(networks, 0) |> SettingsLayout.render()
      row_texts = texts(ops) |> Enum.filter(&String.contains?(&1, "N"))
      assert Enum.any?(row_texts, &String.contains?(&1, "N1"))
      refute Enum.any?(row_texts, &String.contains?(&1, "N10"))
    end

    test "selecting Back shows the final page of networks" do
      networks = for n <- 1..10, do: network("N#{n}")
      ops = at_networks(networks, 10) |> SettingsLayout.render()
      row_texts = texts(ops) |> Enum.filter(&String.contains?(&1, "N"))
      assert Enum.any?(row_texts, &String.contains?(&1, "N10"))
    end

    test "doesn't crash with an empty network list" do
      ops = at_networks([], 0) |> SettingsLayout.render()
      assert Enum.any?(texts(ops), &String.contains?(&1, "Back"))
    end

    test "the SSID is never drawn in the icon font (device bug: tofu boxes, blank name)" do
      networks = [network("Secured_Network", secured: true, saved: true)]
      ops = at_networks(networks) |> SettingsLayout.render()

      icon_texts =
        for {:text, _x, _y, text, opts} <- ops, opts[:font] == :icons, do: text

      refute Enum.any?(icon_texts, &String.contains?(&1, "Secured_Network"))
      assert Enum.any?(texts(ops), &String.contains?(&1, "Secured_Network"))
    end

    test "secured and saved both show as icon-font glyphs, separate from the SSID" do
      networks = [network("A", secured: true, saved: true)]
      ops = at_networks(networks) |> SettingsLayout.render()
      icon_ops = for {:text, _x, _y, text, opts} <- ops, opts[:font] == :icons, do: text
      assert length(icon_ops) == 1
      assert icon_ops == ["\u{E897} \u{E5CA}"]
    end

    test "an open, unsaved network shows no lock/tick glyphs at all" do
      networks = [network("Open", secured: false, saved: false)]
      ops = at_networks(networks) |> SettingsLayout.render()
      refute Enum.any?(ops, &match?({:text, _, _, _, [font: :icons] ++ _}, &1))
    end

    test "a long SSID is truncated rather than overflowing the row" do
      long_ssid = String.duplicate("A", 40)
      ops = at_networks([network(long_ssid)]) |> SettingsLayout.render()
      row_text = texts(ops) |> Enum.find(&String.contains?(&1, "AAA"))
      assert String.length(row_text) <= 20
    end
  end

  describe "password wheel" do
    defp at_password(wheel_index, wheel_group \\ :upper, password \\ "") do
      Settings.open(@status, @versions)
      |> Map.put(:screen, :password)
      |> Map.put(:selected_network, network("Neighbour5G"))
      |> Map.put(:wheel_index, wheel_index)
      |> Map.put(:wheel_group, wheel_group)
      |> Map.put(:password, password)
    end

    test "shows the current character centred, with neighbours either side" do
      ops = at_password(1) |> SettingsLayout.render()
      # wheel_index 1 in :upper is "B", with "A" and "C" either side.
      assert "A" in texts(ops)
      assert "B" in texts(ops)
      assert "C" in texts(ops)
    end

    test "wraps at the start of the wheel" do
      ops = at_password(0) |> SettingsLayout.render()
      entries = Settings.wheel_entries(:upper)
      last_label = entries |> List.last() |> Settings.wheel_label()
      assert last_label in texts(ops)
    end

    test "shows the typed password, masked except the last character" do
      ops = at_password(0, :upper, "Abc") |> SettingsLayout.render()
      assert "••c" in texts(ops)
    end

    test "an empty password doesn't crash the mask" do
      ops = at_password(0, :upper, "") |> SettingsLayout.render()
      refute Enum.any?(texts(ops), &(&1 =~ "•"))
    end
  end

  describe "connecting" do
    test "shows a connecting message" do
      s = %{Settings.open(@status, @versions) | screen: :connecting}
      assert "Connecting…" in texts(SettingsLayout.render(s))
    end
  end

  describe "result" do
    test "success shows the new SSID and IP, green background" do
      s =
        Settings.open(@status, @versions)
        |> Map.put(:screen, :result)
        |> Map.put(:connect_result, {:ok, %{ssid: "Neighbour5G", ip: "192.168.1.99"}})

      ops = SettingsLayout.render(s)
      assert "Neighbour5G" in texts(ops)
      assert Enum.any?(texts(ops), &String.contains?(&1, "192.168.1.99"))
      assert background(ops) == "#206F37"
    end

    test "wrong password failure names the specific reason" do
      s =
        Settings.open(@status, @versions)
        |> Map.put(:screen, :result)
        |> Map.put(:connect_result, {:error, :wrong_password})

      ops = SettingsLayout.render(s)
      assert "Wrong password" in texts(ops)
      assert background(ops) == "#C62828"
    end

    test "another failure names the previous network it fell back to" do
      s =
        Settings.open(@status, @versions)
        |> Map.put(:screen, :result)
        |> Map.put(:connect_result, {:error, :timeout})

      ops = SettingsLayout.render(s)
      assert Enum.any?(texts(ops), &String.contains?(&1, "HomeWifi"))
    end

    test "Retry and Back are both shown, one highlighted" do
      s =
        Settings.open(@status, @versions)
        |> Map.put(:screen, :result)
        |> Map.put(:connect_result, {:error, :timeout})

      ops = SettingsLayout.render(s)
      assert "› Retry" in texts(ops)
      assert "Back" in texts(ops)
    end
  end
end
