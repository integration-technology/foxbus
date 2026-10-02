defmodule Foxbus.Screens.SettingsLayout do
  @moduledoc """
  Pure rendering for the settings screens (`Foxbus.Screens.Settings`), same
  conventions as `Foxbus.Screens.Layout`: a list of `{:background, ...}`,
  `{:text, x, y, text, opts}` and `{:rect, x, y, w, h, color}` ops (the last
  one new here, for the signal bars — `Foxbus.Screens` needs a `fill_rect/5`
  case added to its `draw/2`), everything meant to stay inside the 145 px
  safe circle around (160, 160).

  `menu/1` and `networks/1` were verified on the real device and both had
  bugs fixed from that capture (the network row's SSID was drawn in the icon
  font by mistake; the signal bars overlapped the IP text). `password/1`,
  `connecting/0` and `result/1` are still a first guess, untested — like every
  other screen in this app, expect to move things after seeing a photo.

  Known simplifications:
    * no animated spinner on the connecting screen (just static text) — a
      smooth one would need a faster timer than the 10 s tick Screens
      already has, not built here;
    * the password screen always shows the last typed character unmasked,
      rather than "for a second" — same reason, no extra timer added.
  """

  alias Foxbus.Screens.{Layout, Settings}

  @dark "#1C1C1E"
  @white "#FFFFFF"
  @dim "#9A9AA0"
  @green "#206F37"
  @red "#C62828"

  # Classic Material Icons codepoints (same font as the bell/warning glyphs).
  @lock "\u{E897}"
  @check "\u{E5CA}"

  @visible_networks 4

  @doc "Renders whichever settings screen is current."
  @spec render(Settings.t()) :: list
  def render(%Settings{screen: :menu} = s), do: menu(s)
  def render(%Settings{screen: :scanning}), do: scanning()
  def render(%Settings{screen: :networks} = s), do: networks(s)
  def render(%Settings{screen: :password} = s), do: password(s)
  def render(%Settings{screen: :connecting}), do: connecting()
  def render(%Settings{screen: :result} = s), do: result(s)

  defp menu(s) do
    ssid_line = s.wifi_status.ssid || "Not connected"
    ip_line = s.wifi_status.ip || "—"

    [
      {:background, @dark},
      {:text, 160, 50, "Settings", text_opts(22, @white)},
      {:text, 160, 82, ssid_line, text_opts(18, @dim)},
      {:text, 160, 112, ip_line, text_opts(26, @white)}
    ] ++
      signal_bars(s.wifi_status.signal_dbm) ++
      [
        {:text, 160, 182, versions_text(s.versions), text_opts(13, @dim)},
        menu_item("Change Wi-Fi", 205, s.highlight == 0),
        menu_item("Back", 235, s.highlight == 1)
      ]
  end

  defp menu_item(label, y, true), do: {:text, 160, y, "› " <> label, text_opts(20, @white)}
  defp menu_item(label, y, false), do: {:text, 160, y, label, text_opts(20, @dim)}

  defp versions_text(%{foxbus: foxbus, sdk: sdk}), do: "foxbus #{foxbus} · SDK #{sdk}"

  # 4 bars, bottom-aligned, increasing height; "lit" bars white, the rest a
  # dim outline colour. signal_dbm buckets are a rough guess (-55 excellent
  # down to below -85 unusable) — not measured against this hardware's radio.
  #
  # A device capture showed these (base_y 150) overlapping the bottom of the
  # IP text (y=112, size 26, so bottom ~138) — base_y is now 172, clearing
  # it with an ~8 px gap.
  defp signal_bars(nil), do: []

  defp signal_bars(dbm) do
    lit = signal_bar_count(dbm)
    bar_w = 10
    gap = 6
    heights = [8, 14, 20, 26]
    base_y = 172
    start_x = 160 - (4 * bar_w + 3 * gap) / 2

    heights
    |> Enum.with_index()
    |> Enum.map(fn {h, i} ->
      color = if i < lit, do: @white, else: @dim
      x = round(start_x + i * (bar_w + gap))
      {:rect, x, base_y - h, bar_w, h, color}
    end)
  end

  defp signal_bar_count(dbm) when dbm >= -55, do: 4
  defp signal_bar_count(dbm) when dbm >= -65, do: 3
  defp signal_bar_count(dbm) when dbm >= -75, do: 2
  defp signal_bar_count(dbm) when dbm >= -85, do: 1
  defp signal_bar_count(_dbm), do: 0

  defp scanning do
    [
      {:background, @dark},
      {:text, 160, 50, "Settings", text_opts(22, @white)},
      {:text, 160, 150, "Scanning…", text_opts(22, @dim)}
    ]
  end

  defp networks(s) do
    total = length(s.networks)
    window_start = network_window_start(s.highlight, total)
    visible = s.networks |> Enum.slice(window_start, @visible_networks) |> Enum.with_index()

    rows =
      Enum.flat_map(visible, fn {network, i} ->
        index = window_start + i
        network_row(network, 90 + i * 34, s.highlight == index)
      end)

    back_highlighted? = s.highlight == total

    [{:background, @dark}, {:text, 160, 50, "Choose a network", text_opts(20, @white)}] ++
      rows ++ [menu_item("Back", 230, back_highlighted?)]
  end

  # Keeps the highlighted row inside a window of @visible_networks rows,
  # except when "Back" (index == total) is highlighted, which shows the
  # final page so the list's tail is visible just above it.
  defp network_window_start(highlight, total) when highlight == total,
    do: max(total - @visible_networks, 0)

  defp network_window_start(highlight, total) do
    max_start = max(total - @visible_networks, 0)
    highlight |> Kernel.-(1) |> max(0) |> min(max_start)
  end

  # A device capture showed the whole row (SSID + lock/tick) drawn as one
  # string with font: :icons: the SSID came out blank with tofu boxes for its
  # underscores, since those characters aren't in the icon font at all. The
  # SSID and the glyphs need to be separate ops — left/right-aligned within
  # x=[40,280], the tightest row's safe width (the row closest to the title,
  # ~70 px from centre vertically, has only ~254 px to work with; deeper rows
  # have more room, but this fits all of them).
  defp network_row(network, y, highlighted?) do
    color = if highlighted?, do: @white, else: @dim
    prefix = if highlighted?, do: "› ", else: ""
    label = Layout.truncate(prefix <> network.ssid, 20)
    ssid_op = {:text, 40, y, label, text_opts(18, color, @dark, :left)}

    glyphs = [if(network.secured, do: @lock), if(network.saved, do: @check)] |> Enum.filter(& &1)

    case glyphs do
      [] ->
        [ssid_op]

      glyphs ->
        # No space between them: a device capture showed a tofu box there —
        # the icon font has no space glyph. The glyphs' own padding gives
        # enough visual separation without one.
        icon_op =
          {:text, 280, y, Enum.join(glyphs),
           [font: :icons] ++ text_opts(18, color, @dark, :right)}

        [ssid_op, icon_op]
    end
  end

  defp password(s) do
    entries = Settings.wheel_entries(s.wheel_group)
    count = length(entries)
    prev = Enum.at(entries, Integer.mod(s.wheel_index - 1, count))
    current = Enum.at(entries, s.wheel_index)
    next = Enum.at(entries, Integer.mod(s.wheel_index + 1, count))

    [
      {:background, @dark},
      {:text, 160, 50, masked_password(s.password), text_opts(20, @white)},
      {:text, 90, 160, Settings.wheel_label(prev), text_opts(20, @dim)},
      {:text, 160, 160, Settings.wheel_label(current), wheel_center_opts(current)},
      {:text, 230, 160, Settings.wheel_label(next), text_opts(20, @dim)}
    ]
  end

  defp wheel_center_opts({:char, _}), do: text_opts(44, @white)
  defp wheel_center_opts(_control), do: [font: :icons] ++ text_opts(36, @white)

  defp masked_password(""), do: " "

  defp masked_password(password) do
    length = String.length(password)
    String.duplicate("•", length - 1) <> String.slice(password, -1, 1)
  end

  defp connecting do
    [
      {:background, @dark},
      {:text, 160, 50, "Settings", text_opts(22, @white)},
      {:text, 160, 150, "Connecting…", text_opts(22, @dim)}
    ]
  end

  defp result(%{connect_result: {:ok, %{ssid: ssid, ip: ip}}}) do
    [
      {:background, @green},
      {:text, 160, 110, "Connected to", text_opts(20, @white, @green)},
      {:text, 160, 140, ssid, text_opts(24, @white, @green)},
      {:text, 160, 180, "IP #{ip}", text_opts(20, @white, @green)}
    ]
  end

  defp result(%{connect_result: {:error, reason}} = s) do
    [
      {:background, @red},
      {:text, 160, 90, failure_text(reason, s), text_opts(20, @white, @red)},
      result_item("Retry", 220, s.highlight == 0),
      result_item("Back", 250, s.highlight == 1)
    ]
  end

  defp result_item(label, y, true),
    do: {:text, 160, y, "› " <> label, text_opts(20, @white, @red)}

  defp result_item(label, y, false), do: {:text, 160, y, label, text_opts(20, @dim, @red)}

  defp failure_text(:wrong_password, _s), do: "Wrong password"

  defp failure_text(_reason, s) do
    ssid = s.wifi_status.ssid || "the previous network"
    "Couldn't join; back on #{ssid}"
  end

  defp text_opts(size, color, background \\ @dark, align \\ :center),
    do: [size: size, color: color, background: background, align: align]
end
