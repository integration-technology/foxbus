defmodule Foxbus.ScreensTest do
  use ExUnit.Case, async: true
  alias Foxbus.Screens

  describe "pick_display/3" do
    test "stays on the current stop if it's the one ringing" do
      assert Screens.pick_display(:b, [:a, :b, :c], &(&1 == :b)) == :b
    end

    test "stays on the current stop even if another one is also ringing" do
      assert Screens.pick_display(:b, [:a, :b, :c], &(&1 in [:a, :b])) == :b
    end

    test "jumps to whichever other stop is ringing, if the current one isn't" do
      assert Screens.pick_display(:a, [:a, :b, :c], &(&1 == :c)) == :c
    end

    test "with two stops ringing and neither current, the first in screens order wins" do
      assert Screens.pick_display(:a, [:a, :b, :c], &(&1 in [:c, :b])) == :b
    end

    test "never considers the splash ringing, even if the check would say yes" do
      assert Screens.pick_display(:splash, [:splash, :a], fn _ -> true end) == :a
    end

    test "nothing ringing leaves current unchanged" do
      assert Screens.pick_display(:a, [:a, :b, :c], fn _ -> false end) == :a
    end
  end
end
