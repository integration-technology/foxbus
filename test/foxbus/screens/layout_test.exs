defmodule Foxbus.Screens.LayoutTest do
  use ExUnit.Case, async: true
  alias Foxbus.Screens.Layout
  alias Foxbus.Domain.Arrival

  @orange "#E87A1E"
  @green "#2E9E4F"
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
    assert Layout.splash(nil) == [{:background, :splash}]
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

    test "once today's buses are done the screen is blank" do
      assert Layout.stop("To Chesham", []) == [{:background, "#1C1C1E"}]
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

  describe "auto_arm/2" do
    test "arms itself the moment a bus becomes arriving" do
      assert Layout.auto_arm(:none, {:arriving, 5}) == :armed
      assert Layout.auto_arm(:none, {:arriving, 0}) == :armed
    end

    test "does not arm early, while only soon or in the list" do
      assert Layout.auto_arm(:none, {:soon, 8}) == :none
      assert Layout.auto_arm(:none, :list) == :none
    end

    test "leaves an already-armed bell alone" do
      assert Layout.auto_arm(:armed, {:arriving, 2}) == :armed
    end

    test "never re-arms a silenced bell for the same bus" do
      assert Layout.auto_arm(:silenced, {:arriving, 1}) == :silenced
    end
  end

  describe "the disruption warning icon" do
    defp warning_glyphs(ops),
      do: for({:text, _, _, t, opts} <- ops, opts[:font] == :icons, do: t)

    test "absent by default, in every mode" do
      assert warning_glyphs(Layout.stop("To Chesham", [])) == []
      assert warning_glyphs(Layout.stop("To Chesham", nil)) == []
      assert warning_glyphs(Layout.stop("To Chesham", [arrival("105", 14)])) == []
      assert warning_glyphs(Layout.stop("To Chesham", [arrival("105", 8)])) == []
      assert warning_glyphs(Layout.stop("To Chesham", [arrival("105", 3)])) == []
    end

    test "shown when disrupted, in every mode" do
      warning = fn arrivals ->
        warning_glyphs(Layout.stop("To Chesham", arrivals, 0, :none, true))
      end

      assert length(warning.([])) == 1
      assert length(warning.(nil)) == 1
      assert length(warning.([arrival("105", 14)])) == 1
      assert length(warning.([arrival("105", 8)])) == 1
      assert length(warning.([arrival("105", 3)])) == 1
    end

    test "does not replace the bell icon on the countdown screen" do
      ops = Layout.stop("To Chesham", [arrival("105", 3)], 0, :armed, true)
      assert length(warning_glyphs(ops)) == 2
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

    test "on the splash and on the blank screen too" do
      assert {:text, _, _, "09:05", opts} = clock(Layout.splash(20.5))
      assert opts[:background] == "#435FA6"
      assert {:text, _, _, "09:05", opts} = clock(Layout.stop("To Chesham", []))
      assert opts[:background] == "#1C1C1E"
    end
  end
end
