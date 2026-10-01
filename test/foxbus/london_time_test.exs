defmodule Foxbus.LondonTimeTest do
  use ExUnit.Case, async: true
  alias Foxbus.LondonTime

  # 2026: BST from 01:00 UTC Sunday 29 March to 01:00 UTC Sunday 25 October.

  test "GMT in winter" do
    assert LondonTime.to_local(~U[2026-01-15 12:00:00Z]) == ~N[2026-01-15 12:00:00]
  end

  test "BST in summer" do
    assert LondonTime.to_local(~U[2026-07-01 12:00:00Z]) == ~N[2026-07-01 13:00:00]
  end

  test "clocks go forward at 01:00 UTC on the last Sunday of March" do
    assert LondonTime.offset_seconds(~U[2026-03-29 00:59:59Z]) == 0
    assert LondonTime.offset_seconds(~U[2026-03-29 01:00:00Z]) == 3600
  end

  test "clocks go back at 01:00 UTC on the last Sunday of October" do
    assert LondonTime.offset_seconds(~U[2026-10-25 00:59:59Z]) == 3600
    assert LondonTime.offset_seconds(~U[2026-10-25 01:00:00Z]) == 0
  end

  test "handles a year whose last March day is itself a Sunday" do
    # 31 March 2024 was a Sunday.
    assert LondonTime.offset_seconds(~U[2024-03-31 00:30:00Z]) == 0
    assert LondonTime.offset_seconds(~U[2024-03-31 01:30:00Z]) == 3600
  end
end
