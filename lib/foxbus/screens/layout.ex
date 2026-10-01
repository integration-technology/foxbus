defmodule Foxbus.Screens.Layout do
  @moduledoc """
  What each screen shows, as drawing instructions, plus the rules behind it:
  dial navigation, the countdown, and the arrival bell.

  Pure functions only, so all of it is testable off the device. Each screen starts with
  `{:background, :splash | hex}` (the fox image or a solid colour), followed by
  `{:text, x, y, text, opts}` with `x` the text's centre (`with_clock/2` adds
  the time at the top); `font: :icons` means the bundled Material Icons font. Everything stays
  inside the display's safe circle (radius 145 around 160,160).

  A stop screen has three looks, set by its next bus:

    * more than 10 minutes away — the list of buses on dark grey (blank when
      there are none left today)
    * 10 minutes or less (`:soon`) — orange, the minutes as a large countdown
    * 5 minutes or less (`:arriving`) — green; chirps if the bus's bell is armed

  Any of the three gets a small warning icon, top-left, when the line has an
  active disruption notice.
  """
  alias Foxbus.Domain.Arrival

  @blue "#435FA6"
  @orange "#E87A1E"
  @green "#2E9E4F"
  @white "#FFFFFF"
  @dark "#1C1C1E"
  @dim "#9A9AA0"
  @soon_minutes 10
  @arriving_minutes 5
  @max_rows 4
  @row_y 96
  @row_gap 40
  @clock_y 20
  @clock_size 20
  @bell_armed "\u{E7F7}"
  @bell_silenced "\u{E7F6}"
  @warning "\u{E002}"

  @type mode :: :list | {:soon, non_neg_integer} | {:arriving, non_neg_integer}
  @type bell :: :none | :armed | :silenced

  def blue, do: @blue

  @doc "Screen index after a net number of dial steps (positive clockwise), wrapping."
  @spec navigate(non_neg_integer, pos_integer, integer) :: non_neg_integer
  def navigate(index, count, steps), do: Integer.mod(index + steps, count)

  @doc "Minutes left for a bus, counting down from its ETA at the last fetch."
  @spec minutes_left(non_neg_integer, non_neg_integer) :: non_neg_integer
  def minutes_left(eta_minutes, elapsed_ms), do: max(eta_minutes - div(elapsed_ms, 60_000), 0)

  @doc "Which look a stop screen has, from its next bus."
  @spec mode([Arrival.t()] | nil, non_neg_integer) :: mode
  def mode([next | _], elapsed_ms) do
    case minutes_left(next.eta_minutes, elapsed_ms) do
      m when m <= @arriving_minutes -> {:arriving, m}
      m when m <= @soon_minutes -> {:soon, m}
      _ -> :list
    end
  end

  def mode(_arrivals, _elapsed_ms), do: :list

  @doc """
  The bell after a press of the dial: pressing arms it; pressing again disarms
  it, unless it is chirping, when the press silences it; pressing a silenced bell
  arms it again.
  """
  @spec press(bell, chirping? :: boolean) :: bell
  def press(:none, _chirping?), do: :armed
  def press(:armed, true), do: :silenced
  def press(:armed, false), do: :none
  def press(:silenced, _chirping?), do: :armed

  @doc "Whether a stop should be chirping."
  @spec chirping?(mode, bell) :: boolean
  def chirping?({:arriving, _}, :armed), do: true
  def chirping?(_mode, _bell), do: false

  @doc "Identifies a bus across fetches, so a bell follows the bus it was set for."
  @spec bus_key(Arrival.t()) :: {String.t(), String.t()}
  def bus_key(%Arrival{line: line, destination: destination}), do: {line, destination}

  @doc "The splash: fox (already in the background) and the temperature."
  @spec splash(float | nil) :: list
  def splash(nil), do: [{:background, :splash}]

  def splash(temperature_c) do
    text = :erlang.float_to_binary(temperature_c * 1.0, decimals: 1) <> "°C"
    [{:background, :splash}, {:text, 160, 240, text, text_opts(36, @white, @blue)}]
  end

  @doc """
  A stop screen. `arrivals` is nil until the first fetch has come back;
  `elapsed_ms` is the time since that fetch; `bell` is the next bus's bell;
  `disrupted?` shows a small warning icon, top-left, on top of any mode.
  """
  @spec stop(String.t(), [Arrival.t()] | nil, non_neg_integer, bell, boolean) :: list
  def stop(title, arrivals, elapsed_ms \\ 0, bell \\ :none, disrupted? \\ false) do
    case mode(arrivals, elapsed_ms) do
      :list when arrivals == [] ->
        [blank() | warning_icon(disrupted?, @dark)]

      :list ->
        [blank(), {:text, 160, 54, title, text_opts(24, @white, @dark)} | body(arrivals)] ++
          warning_icon(disrupted?, @dark)

      {:soon, m} ->
        countdown(title, hd(arrivals), m, @orange, bell) ++ warning_icon(disrupted?, @orange)

      {:arriving, m} ->
        countdown(title, hd(arrivals), m, @green, bell) ++ warning_icon(disrupted?, @green)
    end
  end

  defp countdown(title, bus, minutes, color, bell) do
    [
      {:background, color},
      {:text, 160, 48, title, text_opts(22, @white, color)},
      {:text, 160, 76, bus.line, text_opts(26, @white, color)},
      {:text, 160, 102, Integer.to_string(minutes), text_opts(96, @white, color)},
      {:text, 160, 200, "min", text_opts(26, @white, color)}
      | bell_icon(bell, color)
    ]
  end

  defp bell_icon(:none, _color), do: []

  defp bell_icon(bell, color) do
    glyph = if bell == :armed, do: @bell_armed, else: @bell_silenced
    [{:text, 160, 232, glyph, [font: :icons] ++ text_opts(40, @white, color)}]
  end

  defp warning_icon(false, _color), do: []

  defp warning_icon(true, color),
    do: [{:text, 24, 20, @warning, [font: :icons] ++ text_opts(20, @white, color)}]

  defp body(nil), do: [{:text, 160, 140, "Checking times", text_opts(26, @dim, @dark)}]

  defp body(arrivals) do
    arrivals
    |> Enum.take(@max_rows)
    |> Enum.with_index()
    |> Enum.map(fn {a, i} ->
      color = if a.status == :live, do: @white, else: @dim

      {:text, 160, @row_y + i * @row_gap, "#{a.line}  #{Arrival.eta_text(a)}",
       text_opts(30, color, @dark)}
    end)
  end

  @doc """
  Adds the time ("HH:MM", UK local) small at the top centre of a screen, on
  that screen's background.
  """
  @spec with_clock(list, NaiveDateTime.t() | Time.t()) :: list
  def with_clock([{:background, background} | _] = ops, now) do
    {text_bg, color} =
      case background do
        :splash -> {@blue, @white}
        @dark -> {@dark, @dim}
        hex -> {hex, @white}
      end

    text = Calendar.strftime(now, "%H:%M")
    ops ++ [{:text, 160, @clock_y, text, text_opts(@clock_size, color, text_bg)}]
  end

  # Bus list screens are dark (and entirely blank once today's buses are done).
  defp blank, do: {:background, @dark}

  defp text_opts(size, color, background),
    do: [size: size, color: color, background: background, align: :center]
end
