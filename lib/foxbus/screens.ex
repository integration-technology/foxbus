defmodule Foxbus.Screens do
  @moduledoc """
  The Nest's screens: the splash (fox and room temperature) followed by one
  screen per watched stop. Turning the dial moves between them, clockwise
  forwards and anticlockwise back, wrapping round; each step clicks.

  A bus's bell arms itself the moment it's 5 minutes or less away (see
  `Foxbus.Screens.Layout.auto_arm/2`) — no press needed. The Nest only chirps
  and wakes the screen for the stop currently on display, not for an armed
  bus at a stop nobody's looking at; turning the dial away stops the chirp,
  and turning back resumes it. It keeps chirping until either the dial is
  pressed to silence it (see `Foxbus.Screens.Layout.press/2`) or the bus has
  gone (a different bus arrives next, or it drops off the board). While
  chirping, a `NestGen2.Power.keep_awake/1` hold keeps the screen lit instead
  of repeatedly calling `Power.wake/0`; the hold is released the moment
  chirping stops, for whichever reason.

  When Carousel names a stop's exact ATCO code as affected by a notice, its
  screen turns red with the direction and the notice's explanation in place of
  any countdown — there are no buses to show a time for. Until that first
  closure check has come back — notably, right after boot — a stop screen
  says "Checking times" rather than risk showing a scheduled, non-arriving
  bus time ahead of knowing the stop might be closed.

  Arrivals, the line's disruption status, and a stop's closure, all arrive
  through `Foxbus.Adapters.Sinks.ScreensSink`.
  """
  use GenServer
  alias NestGen2.{Display, Image, Piezo, Power}
  alias Foxbus.LondonTime
  alias Foxbus.Screens.Layout

  @tick_ms 10_000
  @chirp_every_ms 3_000
  # Two quick rising tones: {frequency Hz, length ms, delay ms from the start}.
  @chirp [{2600, 70, 0}, {3300, 90, 130}]

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec show_arrivals(atom, list) :: :ok
  def show_arrivals(stop, arrivals), do: GenServer.cast(__MODULE__, {:arrivals, stop, arrivals})

  @spec show_disruption(boolean) :: :ok
  def show_disruption(disrupted?), do: GenServer.cast(__MODULE__, {:disruption, disrupted?})

  @spec show_closure(atom, String.t() | nil) :: :ok
  def show_closure(stop, explanation),
    do: GenServer.cast(__MODULE__, {:closure, stop, explanation})

  @impl true
  def init(nil) do
    stops = Foxbus.Config.stops()
    dir = Application.fetch_env!(:foxbus, :assets_dir)
    background = Image.from_raw(320, 320, File.read!(Path.join(dir, "screen.raw")))

    NestGen2.Dial.set_step(Application.fetch_env!(:foxbus, :screen_step_degrees))
    NestGen2.subscribe([:dial_step, :climate, :button])
    schedule_tick()

    screens = [:splash | Enum.map(stops, &elem(&1, 0))]
    default_index = Enum.find_index(screens, &(&1 == Foxbus.Config.default_screen())) || 0

    state = %{
      screens: screens,
      titles: Map.new(stops, fn {key, _id, title} -> {key, title} end),
      index: default_index,
      arrivals: %{},
      fetched_at: %{},
      bells: %{},
      disrupted: false,
      closures: %{},
      temperature: nil,
      background: background,
      icons: Application.app_dir(:foxbus, ["priv", "MaterialIcons-Regular.ttf"]),
      shown: nil,
      chirping: nil,
      power_hold: nil
    }

    {:ok, render(state)}
  end

  @impl true
  def handle_cast({:arrivals, stop, arrivals}, state) do
    state = %{
      state
      | arrivals: Map.put(state.arrivals, stop, arrivals),
        fetched_at: Map.put(state.fetched_at, stop, now())
    }

    state = auto_arm_bells(state)
    state = if current(state) == stop, do: render(state), else: state
    {:noreply, update_chirp(state)}
  end

  def handle_cast({:disruption, disrupted?}, state) do
    state = %{state | disrupted: disrupted?}
    state = if current(state) != :splash, do: render(state), else: state
    {:noreply, state}
  end

  def handle_cast({:closure, stop, explanation}, state) do
    state = %{state | closures: Map.put(state.closures, stop, explanation)}
    state = auto_arm_bells(state)
    state = if current(state) == stop, do: render(state), else: state
    {:noreply, update_chirp(state)}
  end

  @impl true
  def handle_info({:nest_gen2, :dial_step, %{direction: direction}}, state) do
    steps = step(direction) + pending_steps()
    state = %{state | index: Layout.navigate(state.index, length(state.screens), steps)}
    {:noreply, state |> render() |> update_chirp()}
  end

  def handle_info({:nest_gen2, :climate, %{temperature_c: t}}, state) do
    state = %{state | temperature: t}
    {:noreply, if(current(state) == :splash, do: render(state), else: state)}
  end

  def handle_info({:nest_gen2, :button, :down}, state) do
    stop = current(state)

    case next_bus(state, stop) do
      nil ->
        {:noreply, state}

      bus ->
        chirping? = Layout.chirping?(mode(state, stop), bell(state, stop))
        new_bell = Layout.press(bell(state, stop), chirping?)
        state = put_in(state.bells[stop], {Layout.bus_key(bus), new_bell})
        {:noreply, state |> render() |> update_chirp()}
    end
  end

  # The countdown and the clock move on between fetches: redraw when the minute
  # or colour changes.
  def handle_info(:tick, state) do
    schedule_tick()
    state = auto_arm_bells(state)
    state = if signature(state) != state.shown, do: render(state), else: state
    {:noreply, update_chirp(state)}
  end

  # The power_hold taken in update_chirp/1 keeps the screen lit for as long as
  # this keeps rescheduling itself — no need to call Power.wake/0 here too.
  def handle_info(:chirp, %{chirping: stop} = state) when stop != nil do
    for {hz, ms, delay} <- @chirp, do: Process.send_after(self(), {:tone, hz, ms}, delay)
    Process.send_after(self(), :chirp, @chirp_every_ms)
    {:noreply, state}
  end

  def handle_info(:chirp, state), do: {:noreply, state}

  def handle_info({:tone, hz, ms}, state) do
    Piezo.tone(hz, ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Arms the alarm for any stop whose next bus has just become imminent, with
  # no press needed first (see Layout.auto_arm/2).
  defp auto_arm_bells(state) do
    bells =
      for stop <- tl(state.screens), reduce: state.bells do
        acc ->
          case Layout.auto_arm(bell(state, stop), mode(state, stop)) do
            :none ->
              acc

            # auto_arm/2 only returns non-:none for {:arriving, _}, which
            # Layout.mode/2 only returns for a non-empty arrivals list — so
            # next_bus/2 here is never nil.
            new_bell ->
              Map.put(acc, stop, {Layout.bus_key(next_bus(state, stop)), new_bell})
          end
      end

    %{state | bells: bells}
  end

  # Chirps only for the stop currently on screen — a bus going off at a stop
  # nobody's looking at neither sounds nor jumps the screen to it.
  defp update_chirp(state) do
    stop = current(state)

    chirping =
      if stop != :splash and Layout.chirping?(mode(state, stop), bell(state, stop)),
        do: stop

    cond do
      chirping == state.chirping ->
        state

      chirping == nil ->
        release_power_hold(state)
        %{state | chirping: nil, power_hold: nil}

      true ->
        # Release any previous hold first — this also covers switching
        # straight from one chirping stop to another, with no nil in between.
        release_power_hold(state)
        send(self(), :chirp)
        {:ok, hold} = Power.keep_awake(:alarm)
        %{state | chirping: chirping, power_hold: hold}
    end
  end

  defp release_power_hold(%{power_hold: nil}), do: :ok
  defp release_power_hold(%{power_hold: hold}), do: Power.release(hold)

  # A quick spin queues several steps; take them all in one redraw.
  defp pending_steps do
    receive do
      {:nest_gen2, :dial_step, %{direction: d}} -> step(d) + pending_steps()
    after
      0 -> 0
    end
  end

  defp step(:cw), do: 1
  defp step(:ccw), do: -1

  defp current(state), do: Enum.at(state.screens, state.index)

  defp next_bus(state, stop) do
    case Map.get(state.arrivals, stop) do
      [bus | _] -> bus
      _ -> nil
    end
  end

  # The bell only counts while it is still set for the stop's next bus.
  defp bell(state, stop) do
    with {key, bell} <- Map.get(state.bells, stop),
         %{} = bus <- next_bus(state, stop),
         ^key <- Layout.bus_key(bus) do
      bell
    else
      _ -> :none
    end
  end

  defp elapsed(state, stop), do: now() - Map.get(state.fetched_at, stop, now())

  # :error means no closure check has landed yet for this stop — distinct from
  # {:ok, nil}, which means one has and the stop is open. Map.get/2 alone
  # can't tell those apart, since both read back as nil.
  defp closure_status(state, stop), do: Map.fetch(state.closures, stop)

  # A closed (or not-yet-known) stop never counts as arriving/soon: there's no
  # real bus behind a stale scrape, or none confirmed yet, so nothing should
  # auto-arm or chirp for it.
  defp mode(state, stop) do
    case closure_status(state, stop) do
      {:ok, nil} -> Layout.mode(Map.get(state.arrivals, stop), elapsed(state, stop))
      _ -> :list
    end
  end

  defp signature(state) do
    minute = Calendar.strftime(LondonTime.now(), "%H:%M")

    case current(state) do
      :splash ->
        {:splash, state.temperature, minute}

      stop ->
        {stop, mode(state, stop), bell(state, stop), Map.get(state.arrivals, stop),
         state.disrupted, closure_status(state, stop), minute}
    end
  end

  # Every 10 s, and just after each minute turns so the clock changes on time.
  defp schedule_tick do
    to_minute = 60_000 - rem(System.os_time(:millisecond), 60_000) + 50
    Process.send_after(self(), :tick, min(@tick_ms, to_minute))
  end

  defp render(state) do
    ops =
      case current(state) do
        :splash ->
          Layout.splash(state.temperature)

        stop ->
          case closure_status(state, stop) do
            # No closure check has landed yet: show "Checking times" rather
            # than risk a scheduled, non-arriving bus time ahead of knowing
            # whether this stop is actually closed.
            :error ->
              Layout.stop(state.titles[stop], nil)

            {:ok, nil} ->
              Layout.stop(
                state.titles[stop],
                Map.get(state.arrivals, stop),
                elapsed(state, stop),
                bell(state, stop),
                state.disrupted
              )

            {:ok, explanation} ->
              Layout.closed(state.titles[stop], explanation)
          end
      end

    ops |> Layout.with_clock(LondonTime.now()) |> Enum.each(&draw(&1, state))
    Display.present()
    %{state | shown: signature(state)}
  end

  defp draw({:background, :splash}, state), do: Display.set_background(state.background)
  defp draw({:background, color}, _state), do: Display.set_background(color)

  defp draw({:text, x, y, text, opts}, state) do
    opts = if opts[:font] == :icons, do: Keyword.put(opts, :font, state.icons), else: opts
    Display.put_text(x, y, text, opts)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
