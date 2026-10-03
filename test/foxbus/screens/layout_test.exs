defmodule Foxbus.Screens.LayoutTest do
  use ExUnit.Case, async: true
  alias Foxbus.Screens.Layout
  alias Foxbus.Domain.Arrival

  @orange "#A2551B"
  @green "#206F37"
  @minute 60_000

  defp arrival(line, eta, status \\ :live, time \\ nil),
    do: %Arrival{
      line: line,
      destination: "x",
      eta_minutes: eta,
      status: status,
      scheduled_time: time
    }

  defp texts(ops), do: for({:text, _x, _y, text, _opts} <- ops, do: text)

  defp background([{:background, bg} | _]), do: bg

  describe "navigate/3" do
    test "clockwise moves forward and wraps" do
      assert Layout.navigate(0, 3, 1) == 1
      assert Layout.navigate(2, 3, 1) == 0
    end

    test "anticlockwise moves back and wraps" do
      assert Layout.navigate(0, 3, -1) == 2
    end

    test "several queued steps at once" do
      assert Layout.navigate(0, 3, 4) == 1
      assert Layout.navigate(1, 3, -5) == 2
    end
  end

  test "splash shows the temperature to one decimal place" do
    assert texts(Layout.splash(21.66)) == ["21.7°C"]
  end

  test "splash shows a placeholder before the first climate reading" do
    assert texts(Layout.splash(nil)) == ["--°C"]
  end

  describe "list (next bus more than 10 minutes away)" do
    test "shows the title and buses with their clock times" do
      ops =
        Layout.stop("To Chesham", [
          arrival("105", 14, :live, ~T[15:07:00]),
          arrival("1", 40, :scheduled, ~T[15:33:00])
        ])

      assert texts(ops) == ["To Chesham", "105  at 15:07", "1  at 15:33"]
      assert background(ops) == "#1C1C1E"
    end

    test "shows at most four buses" do
      buses = for m <- 11..16, do: arrival("105", m)
      assert length(texts(Layout.stop("To Chesham", buses))) == 1 + 4
    end

    test "live buses are white, scheduled ones dimmer" do
      ops = Layout.stop("To Chesham", [arrival("105", 14, :live), arrival("1", 40, :scheduled)])
      [_title, live, scheduled] = for {:text, _, _, _, opts} <- ops, do: opts[:color]
      assert live == "#FFFFFF"
      assert scheduled != live
    end

    test "before the first fetch it says it is checking" do
      assert texts(Layout.stop("To Chesham", nil)) == ["To Chesham", "Checking times"]
    end

    test "once today's buses are done it says so, with the title still shown" do
      ops = Layout.stop("To Chesham", [])
      assert background(ops) == "#1C1C1E"
      assert texts(ops) == ["To Chesham", "No more buses today"]
    end
  end

  describe "list row selection" do
    defp buses, do: [arrival("105", 14), arrival("1", 22), arrival("104", 38)]

    test "a selected row is marked with a prefix" do
      ops = Layout.stop("To Chesham", buses(), 0, :none, nil, false, %{index: 1, armed: []})
      assert "› 1  22 min" in texts(ops)
      assert "105  14 min" in texts(ops)
      refute "› 105  14 min" in texts(ops)
    end

    test "the selected row is brightened even if its bus is scheduled, not live" do
      scheduled = [arrival("105", 14, :scheduled)]
      ops = Layout.stop("To Chesham", scheduled, 0, :none, nil, false, %{index: 0, armed: []})
      [_title, row] = for {:text, _, _, _, opts} <- ops, do: opts[:color]
      assert row == "#FFFFFF"
    end

    test "an armed row shows a bell glyph, an unarmed one doesn't" do
      selection = %{index: 0, armed: [Layout.bus_key(Enum.at(buses(), 1))]}
      ops = Layout.stop("To Chesham", buses(), 0, :none, nil, false, selection)
      icons = for {:text, _, _, t, opts} <- ops, opts[:font] == :icons, do: t
      assert icons == ["\u{E7F7}"]
    end

    test "no selection, no highlight or bells" do
      ops = Layout.stop("To Chesham", buses())
      refute Enum.any?(texts(ops), &String.starts_with?(&1, "› "))
      refute Enum.any?(ops, &match?({:text, _, _, _, [font: :icons] ++ _}, &1))
    end

    test "list_row_count/1 matches what the list look actually renders" do
      assert Layout.list_row_count(nil) == 0
      assert Layout.list_row_count([]) == 0
      assert Layout.list_row_count(buses()) == 3
      assert Layout.list_row_count(for(m <- 1..10, do: arrival("105", m + 10))) == 4

      multi_dest = for m <- 1..10, do: arrival_to("105", m + 10, "Dest #{m}")
      assert Layout.list_row_count(multi_dest) == 3
    end
  end

  describe "a shared stop with more than one destination" do
    defp arrival_to(line, eta, destination),
      do: %Arrival{line: line, destination: destination, eta_minutes: eta, status: :live}

    test "shows each bus's own destination instead of the stop's single title" do
      ops =
        Layout.stop("To Uxbridge", [
          arrival_to("104", 11, "Uxbridge"),
          arrival_to("105", 18, "High Wycombe")
        ])

      # The title is dropped, not just supplemented: "To Uxbridge" would
      # contradict the second row, which goes to High Wycombe.
      assert texts(ops) == [
               "104  11 min",
               "Uxbridge",
               "105  18 min",
               "High Wycombe"
             ]
    end

    test "unaffected when every bus shares one destination" do
      ops =
        Layout.stop("To Chesham", [
          arrival_to("105", 14, "Chesham"),
          arrival_to("1", 40, "Chesham")
        ])

      assert texts(ops) == ["To Chesham", "105  14 min", "1  40 min"]
    end

    test "shows at most three buses, each with two lines, and no contradicting title" do
      buses = for m <- 11..16, do: arrival_to("104", m, "Dest #{m}")
      assert length(texts(Layout.stop("To Uxbridge", buses))) == 3 * 2
    end
  end

  describe "mode/2 and the countdown" do
    test "list beyond 10 minutes, orange at 10 or less, green at 5 or less" do
      assert Layout.mode([arrival("105", 11)], 0) == :list
      assert Layout.mode([arrival("105", 10)], 0) == {:soon, 10}
      assert Layout.mode([arrival("105", 6)], 0) == {:soon, 6}
      assert Layout.mode([arrival("105", 5)], 0) == {:arriving, 5}
      assert Layout.mode([], 0) == :list
      assert Layout.mode(nil, 0) == :list
    end

    test "counts down from the last fetch" do
      assert Layout.minutes_left(12, 0) == 12
      assert Layout.minutes_left(12, 59_999) == 12
      assert Layout.minutes_left(12, 3 * @minute) == 9
      assert Layout.minutes_left(2, 10 * @minute) == 0
      assert Layout.mode([arrival("105", 12)], 3 * @minute) == {:soon, 9}
    end

    test "the orange screen shows the minutes large" do
      ops = Layout.stop("To Chesham", [arrival("105", 8)])
      assert background(ops) == @orange
      assert texts(ops) == ["To Chesham", "105", "8", "min"]
      assert Enum.any?(ops, &match?({:text, _, _, "8", [size: 96] ++ _}, &1))
    end

    test "the green screen at 5 minutes or less" do
      assert background(Layout.stop("To Chesham", [arrival("105", 3)])) == @green
    end

    test "a due bus shows a plain minutes number by default" do
      ops = Layout.stop("To Chesham", [arrival("105", 0)])
      assert "0" in texts(ops)
      refute "0?" in texts(ops)
    end

    test "uncertain? marks a due bus with a dimmer, question-marked minutes" do
      ops = Layout.stop("To Chesham", [arrival("105", 0)], 0, :none, nil, true)
      assert "0?" in texts(ops)

      {:text, _, _, "0?", opts} = Enum.find(ops, &match?({:text, _, _, "0?", _}, &1))
      assert opts[:color] != "#FFFFFF"
    end

    test "uncertain? has no effect outside the arriving (green) look" do
      ops = Layout.stop("To Chesham", [arrival("105", 8)], 0, :none, nil, true)
      assert "8" in texts(ops)
      refute "8?" in texts(ops)
    end
  end

  describe "the bell" do
    test "a press arms it, another disarms it" do
      assert Layout.press(:none, false) == :armed
      assert Layout.press(:armed, false) == :none
    end

    test "a press while chirping silences it, and a silenced bell can be re-armed" do
      assert Layout.press(:armed, true) == :silenced
      assert Layout.press(:silenced, true) == :armed
    end

    test "only an armed bus that is arriving chirps" do
      assert Layout.chirping?({:arriving, 3}, :armed)
      refute Layout.chirping?({:arriving, 3}, :silenced)
      refute Layout.chirping?({:arriving, 3}, :none)
      refute Layout.chirping?({:soon, 8}, :armed)
      refute Layout.chirping?(:list, :armed)
    end

    test "the countdown shows a ringing bell when armed and a crossed-out one when silenced" do
      icons = fn bell ->
        for {:text, _, _, t, opts} <- Layout.stop("To Chesham", [arrival("105", 3)], 0, bell),
            opts[:font] == :icons,
            do: t
      end

      assert icons.(:armed) == ["\u{E7F7}"]
      assert icons.(:silenced) == ["\u{E7F6}"]
      assert icons.(:none) == []
    end

    test "a bell belongs to a bus by line and destination" do
      assert Layout.bus_key(arrival("105", 3)) == {"105", "x"}
    end
  end

  describe "the disruption warning line" do
    defp arrivals_by_mode,
      do: [[], nil, [arrival("105", 14)], [arrival("105", 8)], [arrival("105", 3)]]

    test "absent by default, in every mode" do
      for arrivals <- arrivals_by_mode() do
        ops = Layout.stop("To Chesham", arrivals)
        refute "105 Disruption" in texts(ops)
      end
    end

    test "shows the notice's own title as one extra line, in every mode" do
      for arrivals <- arrivals_by_mode() do
        without = Layout.stop("To Chesham", arrivals)
        with_it = Layout.stop("To Chesham", arrivals, 0, :none, "105 Disruption")

        assert length(texts(with_it)) == length(texts(without)) + 1
        assert List.last(texts(with_it)) == "105 Disruption"
      end
    end

    test "a long title is truncated to fit the one line available" do
      long = "Roycroft Stops, Clewer Hill Road Windsor Suspended 24HRS"
      ops = Layout.stop("To Chesham", [arrival("105", 3)], 0, :none, long)
      assert List.last(texts(ops)) == "Roycroft Stops,…"
    end

    test "does not replace the bell icon on the countdown screen" do
      ops = Layout.stop("To Chesham", [arrival("105", 3)], 0, :armed, "105 Disruption")
      bell_icons = for {:text, _, _, t, opts} <- ops, opts[:font] == :icons, do: t
      assert bell_icons == ["\u{E7F7}"]
      assert List.last(texts(ops)) == "105 Disruption"
    end
  end

  describe "truncate/2" do
    test "leaves short text alone" do
      assert Layout.truncate("No buses today.", 20) == "No buses today."
    end

    test "cuts longer text with an ellipsis" do
      assert Layout.truncate("Service 105 Disruption", 10) == "Service 1…"
    end

    test "exactly at the limit is left alone" do
      assert Layout.truncate("1234567890", 10) == "1234567890"
    end
  end

  describe "with_clock/2" do
    @now ~N[2026-10-25 09:05:42]

    defp clock(ops), do: List.last(Layout.with_clock(ops, @now))

    test "adds the time small at the top centre, on the screen's background" do
      assert {:text, 160, 20, "09:05", opts} =
               clock(Layout.stop("To Chesham", [arrival("105", 8)]))

      assert opts[:size] == 20
      assert opts[:background] == @orange
    end

    test "much bigger on the splash, readable from across the room" do
      assert {:text, _, _, "09:05", opts} = clock(Layout.splash(20.5))
      assert opts[:background] == "#435FA6"
      assert opts[:size] == 48
    end

    test "small at the top on a stop screen, including the blank one" do
      assert {:text, _, _, "09:05", opts} = clock(Layout.stop("To Chesham", []))
      assert opts[:background] == "#1C1C1E"
      assert opts[:size] == 20
    end
  end

  describe "closed/2 (stop closure)" do
    test "red, with the direction and the explanation, no countdown" do
      ops = Layout.closed("To Chesham", "No buses today.")
      assert background(ops) == "#C62828"
      assert texts(ops) == ["To Chesham", "No buses today."]
    end

    test "a long explanation wraps onto several lines" do
      ops =
        Layout.closed(
          "To Chesham",
          "Due to emergency Village Road closure we are unable to serve Coleshill. " <>
            "We apologise for any inconvenience caused."
        )

      [_title | lines] = texts(ops)
      assert length(lines) > 1
      assert Enum.all?(lines, &(String.length(&1) <= 22))
    end

    test "an extremely long explanation is truncated, not drawn past six lines" do
      explanation = Enum.map_join(1..50, " ", fn i -> "word#{i}" end)
      ops = Layout.closed("To Chesham", explanation)
      [_title | lines] = texts(ops)
      assert length(lines) == 6
    end
  end

  describe "wrap/2" do
    test "keeps a short line as one line" do
      assert Layout.wrap("No buses today.", 22) == ["No buses today."]
    end

    test "breaks at word boundaries once the budget is exceeded" do
      assert Layout.wrap("one two three four five", 11) == ["one two", "three four", "five"]
    end

    test "never splits a single word" do
      assert Layout.wrap("supercalifragilisticexpialidocious", 5) ==
               ["supercalifragilisticexpialidocious"]
    end
  end
end
