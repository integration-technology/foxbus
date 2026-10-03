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
      there are none left today); if the ones shown go to more than one
      destination — a shared stop watching several lines (see
      `Foxbus.Config.lines/0`) — each row gets its own destination under it,
      since the screen's one configured title can't speak for all of them.
      No alarm can be set from here — only the countdown screens below have
      a single bus to arm
    * 10 minutes or less (`:soon`) — orange, the minutes as a large countdown
    * 5 minutes or less (`:arriving`) — green; a bell armed by a press (see
      `press/2`) chirps here, until muted or the bus has gone

  Any of the three gets a short line of the notice's own title, below the
  countdown, when this stop has an active disruption notice on one of its
  lines — not just an icon, since the dial is already taken by arming or
  muting the alarm here, so this is the only way to see what the issue
  actually is without navigating away. A notice naming specific affected
  stops only shows on those stops, not every stop on the line (see
  `Foxbus.Adapters.Sources.CarouselDisruptionsSource`).

  A fourth look, `closed/2`, replaces all of that: when Carousel's board
  names this exact stop as affected by a notice, there is no countdown to
  show — just the direction and why, on red.
  """
  alias Foxbus.Domain.Arrival

  @blue "#435FA6"
  # Darker and more saturated than the originals (#A2551B / #206F37) — a
  # device-capture request from Owain, unverified since the next one.
  @orange "#8A3A00"
  @green "#145C29"
  @red "#C62828"
  @white "#FFFFFF"
  @dark "#1C1C1E"
  @dim "#9A9AA0"
  @soon_minutes 10
  @arriving_minutes 5
  @max_rows 4
  @row_y 96
  @row_gap 40
  @multi_dest_max_rows 3
  @multi_dest_row_gap 54
  @clock_y 20
  @clock_size 20
  @splash_clock_y 46
  @splash_clock_size 48
  @bell_armed "\u{E7F7}"
  @bell_silenced "\u{E7F6}"

  @type mode :: :list | {:soon, non_neg_integer} | {:arriving, non_neg_integer}
  @type bell :: :none | :armed | :silenced
  @type bus_key :: {String.t(), String.t(), Time.t() | nil}

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

  @doc """
  Identifies one specific departure, as reported by the most recent fetch —
  not a stable cross-fetch identity by itself. Line and destination alone
  aren't enough: a shared stop's list can show the same route to the same
  place more than once (an earlier and a later departure), and this is what
  tells those two apart at the moment this is called.

  It is NOT safe to compare two bus_key/1 values from different fetches for
  equality, though — scheduled_time isn't stable for a live bus.
  `Foxbus.Adapters.Sources.CarouselScrapeSource` computes it fresh each poll
  as now + the reported eta, which converges on the bus's true arrival
  minute but normally shifts by about a minute every time that eta itself
  ticks down, not just when the bus is genuinely running late. Matching one
  fetch's bus_key against an earlier one's needs tolerance for that drift —
  see `Foxbus.Screens`' tolerant re-matching, which is what actually tracks
  an armed or due bus from poll to poll; this is just the identity snapshot
  it starts from and compares against.
  """
  @spec bus_key(Arrival.t()) :: {String.t(), String.t(), Time.t() | nil}
  def bus_key(%Arrival{line: line, destination: destination, scheduled_time: scheduled_time}),
    do: {line, destination, scheduled_time}

  # See bus_key/1's drift warning: a scheduled_time comparison needs enough
  # slack to absorb normal eta-ticking, while still keeping two genuinely
  # different departures distinct — those are normally tens of minutes
  # apart, not a handful.
  @rebind_tolerance_minutes 3

  @doc """
  Finds whichever of `arrivals` is most likely the same physical departure
  as `key` (an earlier bus_key/1), tolerating the drift bus_key/1 warns
  about — or nil if none is close enough to count. Matches by line and
  destination, then by whichever scheduled_time is closest to `key`'s own,
  within #{@rebind_tolerance_minutes} minutes; a tie goes to whichever
  comes first in `arrivals` (lowest eta, since callers pass an
  eta-sorted list).

  Returns the match's own, fresh bus_key/1 — not `key` itself — so a
  caller tracking a bus across fetches (`Foxbus.Screens`, for both the
  alarm and the stale-due check) can update its stored reference to the
  bus's current estimate each time, rather than comparing every future
  fetch back against the original arm time and accumulating drift.
  """
  @spec rebind([Arrival.t()], bus_key) :: bus_key | nil
  def rebind(arrivals, {line, destination, time}) do
    arrivals
    |> Enum.filter(&(&1.line == line and &1.destination == destination))
    |> Enum.filter(&times_close?(&1.scheduled_time, time))
    |> Enum.min_by(&time_distance(&1.scheduled_time, time), fn -> nil end)
    |> case do
      nil -> nil
      bus -> bus_key(bus)
    end
  end

  defp times_close?(nil, nil), do: true
  defp times_close?(nil, _time), do: false
  defp times_close?(_time, nil), do: false
  defp times_close?(t1, t2), do: time_distance(t1, t2) <= @rebind_tolerance_minutes

  defp time_distance(nil, nil), do: 0
  defp time_distance(t1, t2), do: abs(Time.diff(t1, t2, :minute))

  @doc """
  The splash: fox (already in the background) and the temperature — a dashed
  placeholder before the first climate reading comes in, since that can take
  a little while after boot.
  """
  @spec splash(float | nil) :: list
  def splash(nil),
    do: [{:background, :splash}, {:text, 160, 240, "--°C", text_opts(36, @dim, @blue)}]

  def splash(temperature_c) do
    text = :erlang.float_to_binary(temperature_c * 1.0, decimals: 1) <> "°C"
    [{:background, :splash}, {:text, 160, 240, text, text_opts(36, @white, @blue)}]
  end

  @doc """
  A stop screen. `arrivals` is nil until the first fetch has come back;
  `elapsed_ms` is the time since that fetch; `bell` is the next bus's bell;
  `disruption` is the active notice's title (or nil), shown as a short line
  below the countdown, on top of any mode; `uncertain?` marks a bus that's
  read as due (0 min) for a while without actually arriving — Carousel's
  board doesn't always drop a departed bus promptly, so this could mean it's
  held up rather than gone (see `Foxbus.Screens`, which tracks how long and
  eventually drops it from the list entirely rather than leave it
  `uncertain?` forever).
  """
  @spec stop(String.t(), [Arrival.t()] | nil, non_neg_integer, bell, String.t() | nil, boolean) ::
          list
  def stop(
        title,
        arrivals,
        elapsed_ms \\ 0,
        bell \\ :none,
        disruption \\ nil,
        uncertain? \\ false
      ) do
    case mode(arrivals, elapsed_ms) do
      :list when arrivals == [] ->
        [
          blank(),
          {:text, 160, 54, title, text_opts(24, @white, @dark)},
          {:text, 160, 140, "No more buses today", text_opts(22, @dim, @dark)}
        ] ++ warning_line(disruption, @dark)

      :list ->
        # The configured title ("To Uxbridge") names one direction; when the
        # shown buses go to more than one place (a shared stop watching
        # several lines), it would contradict half of them, so it's dropped
        # rather than shown alongside destinations that disagree with it.
        title_line =
          if multi_destination?(arrivals),
            do: [],
            else: [{:text, 160, 54, title, text_opts(24, @white, @dark)}]

        [blank() | title_line] ++ body(arrivals) ++ warning_line(disruption, @dark)

      {:soon, m} ->
        countdown(title, hd(arrivals), m, @orange, bell, false) ++
          warning_line(disruption, @orange)

      {:arriving, m} ->
        countdown(title, hd(arrivals), m, @green, bell, uncertain?) ++
          warning_line(disruption, @green)
    end
  end

  @doc """
  The stop-closure screen: Carousel's board has named this exact stop (by ATCO
  code) as affected by a notice, so there's no countdown to show, just the
  direction and why — on red, in place of the usual three looks.
  """
  @spec closed(String.t(), String.t()) :: list
  def closed(title, explanation) do
    body =
      explanation
      |> wrap(22)
      # 6 lines x 28 px from y=104 reaches y=244, comfortably inside the 145 px
      # safe circle; a longer notice is truncated rather than drawn off-screen.
      |> Enum.take(6)
      |> Enum.with_index()
      |> Enum.map(fn {line, i} ->
        {:text, 160, 104 + i * 28, line, text_opts(20, @white, @red)}
      end)

    [{:background, @red}, {:text, 160, 54, title, text_opts(24, @white, @red)} | body]
  end

  @doc """
  Greedy word-wrap to a fixed character budget per line. There's no font
  metrics available on this device (no `Text.measure`), so this is a
  conservative guess tuned by eye on the real screen rather than measured —
  see Layout's moduledoc on the safe circle shrinking width away from centre.
  """
  @spec wrap(String.t(), pos_integer) :: [String.t()]
  def wrap(text, max_chars) do
    text
    |> String.split()
    |> Enum.reduce([], fn word, lines ->
      case lines do
        [] ->
          [word]

        [current | rest] ->
          candidate = current <> " " <> word

          if String.length(candidate) <= max_chars,
            do: [candidate | rest],
            else: [word, current | rest]
      end
    end)
    |> Enum.reverse()
  end

  defp countdown(title, bus, minutes, color, bell, uncertain?) do
    minutes_text = if uncertain?, do: "#{minutes}?", else: Integer.to_string(minutes)
    minutes_color = if uncertain?, do: @dim, else: @white

    [
      {:background, color},
      {:text, 160, 48, title, text_opts(22, @white, color)},
      {:text, 160, 76, bus.line, text_opts(26, @white, color)},
      {:text, 160, 102, minutes_text, text_opts(96, minutes_color, color)},
      {:text, 160, 200, "min", text_opts(26, @white, color)}
      | bell_icon(bell, color)
    ]
  end

  defp bell_icon(:none, _color), do: []

  defp bell_icon(bell, color) do
    glyph = if bell == :armed, do: @bell_armed, else: @bell_silenced
    [{:text, 160, 232, glyph, [font: :icons] ++ text_opts(40, @white, color)}]
  end

  defp warning_line(nil, _color), do: []

  # (160, 264): below "min" (y=200) and the bell icon (y=232). A real device
  # capture showed the previous (160, 270) + 20 chars running to ~147 px from
  # centre — just outside the 145 px safe circle, with letters starting to
  # hide under the bezel — so this is narrower (16 chars) and nudged up 6 px,
  # while keeping a 32 px gap below the bell icon so the two don't collide.
  # One line only, so a long title is truncated rather than wrapped (contrast
  # closed/2, which has the whole screen to wrap into).
  defp warning_line(explanation, color),
    do: [{:text, 160, 264, truncate(explanation, 16), text_opts(18, @white, color)}]

  @doc "Cuts text to at most `max_chars`, with an ellipsis if it was longer."
  @spec truncate(String.t(), pos_integer) :: String.t()
  def truncate(text, max_chars) do
    if String.length(text) <= max_chars,
      do: text,
      else: String.slice(text, 0, max_chars - 1) <> "…"
  end

  defp body(nil), do: [{:text, 160, 140, "Checking times", text_opts(26, @dim, @dark)}]

  defp body(arrivals) do
    if multi_destination?(arrivals),
      do: body_with_destinations(arrivals),
      else: body_rows(arrivals)
  end

  # True once more than one line is watched (see Foxbus.Config.lines/0) and
  # they genuinely go different places — the stop's single configured title
  # ("To Uxbridge") is then wrong for whichever ones don't terminate there, so
  # each row needs its own destination instead of relying on the title.
  defp multi_destination?(nil), do: false

  defp multi_destination?(arrivals),
    do: arrivals |> Enum.map(& &1.destination) |> Enum.uniq() |> length() > 1

  # Row text sizes were bumped up from the original 30/26/15 (Owain found
  # the list hard to read without glasses) — unverified on the real device,
  # like every pixel-exact choice here; expect another pass once there's a
  # capture to check nothing's crowded or run off the safe circle.
  @row_size 36
  @multi_dest_row_size 30
  @multi_dest_destination_size 18

  defp body_rows(arrivals) do
    arrivals
    |> Enum.take(@max_rows)
    |> Enum.with_index()
    |> Enum.map(fn {a, i} ->
      color = if a.status == :live, do: @white, else: @dim

      {:text, 160, @row_y + i * @row_gap, "#{a.line}  #{Arrival.eta_text(a)}",
       text_opts(@row_size, color, @dark)}
    end)
  end

  defp body_with_destinations(arrivals) do
    arrivals
    |> Enum.take(@multi_dest_max_rows)
    |> Enum.with_index()
    |> Enum.flat_map(fn {a, i} ->
      color = if a.status == :live, do: @white, else: @dim
      y = @row_y + i * @multi_dest_row_gap

      [
        {:text, 160, y, "#{a.line}  #{Arrival.eta_text(a)}",
         text_opts(@multi_dest_row_size, color, @dark)},
        # Shrunk from 24 to 20 chars to match the bigger font — a
        # proportional guess, also unverified.
        {:text, 160, y + 24, truncate(a.destination, 20),
         text_opts(@multi_dest_destination_size, @dim, @dark)}
      ]
    end)
  end

  @doc """
  Adds the time ("HH:MM", UK local) to a screen, on that screen's background:
  much larger on the splash — it's the one screen meant to be read from
  across the room, like a desk clock — and small at the top centre elsewhere,
  out of the way of the countdown.
  """
  @spec with_clock(list, NaiveDateTime.t() | Time.t()) :: list
  def with_clock([{:background, :splash} | _] = ops, now) do
    text = Calendar.strftime(now, "%H:%M")
    ops ++ [{:text, 160, @splash_clock_y, text, text_opts(@splash_clock_size, @white, @blue)}]
  end

  def with_clock([{:background, background} | _] = ops, now) do
    {text_bg, color} =
      case background do
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
