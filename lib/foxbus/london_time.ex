defmodule Foxbus.LondonTime do
  @moduledoc """
  UK local time without a time-zone database.

  Carousel's board shows local "HH:MM" times, so converting them needs to know
  whether the UK is on GMT or BST. The rule is fixed: BST (UTC+1) runs from
  01:00 UTC on the last Sunday of March to 01:00 UTC on the last Sunday of
  October. That is all this app needs, so it avoids shipping tzdata and its
  update machinery on a 58 MB device.
  """

  @doc "The current UK wall-clock time."
  @spec now() :: NaiveDateTime.t()
  def now, do: to_local(DateTime.utc_now())

  @doc "Converts a UTC instant to UK wall-clock time."
  @spec to_local(DateTime.t()) :: NaiveDateTime.t()
  def to_local(%DateTime{} = utc) do
    utc |> DateTime.to_naive() |> NaiveDateTime.add(offset_seconds(utc), :second)
  end

  @doc "UTC offset in seconds at a UTC instant: 3600 during BST, otherwise 0."
  @spec offset_seconds(DateTime.t()) :: 0 | 3600
  def offset_seconds(%DateTime{year: year} = utc) do
    starts = transition(year, 3)
    ends = transition(year, 10)

    if DateTime.compare(utc, starts) != :lt and DateTime.compare(utc, ends) == :lt,
      do: 3600,
      else: 0
  end

  # 01:00 UTC on the last Sunday of the month.
  defp transition(year, month) do
    last_day = Date.new!(year, month, 1) |> Date.end_of_month()
    sunday = Date.add(last_day, -rem(Date.day_of_week(last_day), 7))
    DateTime.new!(sunday, ~T[01:00:00], "Etc/UTC")
  end
end
