defmodule Foxbus.Screens do
  @moduledoc """
  The Nest's screens: the splash (fox and room temperature) followed by one
  screen per watched stop. Turning the dial moves between them, clockwise
  forwards and anticlockwise back, wrapping round; each step clicks.

  On a stop screen, pressing the dial sets the next bus's bell (see
  `Foxbus.Screens.Layout.press/2`). When an armed bus is 5 minutes or less away
  the Nest chirps, wakes the screen and shows that stop, until the bell is
  silenced or the bus has gone.

  Arrivals, and the line's disruption status, arrive through
  `Foxbus.Adapters.Sinks.ScreensSink`.
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

  @impl true
  def init(nil) do
    stops = Application.fetch_env!(:foxbus, :stops)
    dir = Application.fetch_env!(:foxbus, :assets_dir)
    background = Image.from_raw(320, 320, File.read!(Path.join(dir, "screen.raw")))

    NestGen2.Dial.set_step(Application.fetch_env!(:foxbus, :screen_step_degrees))
    NestGen2.subscribe([:dial_step, :climate, :button])
    schedule_tick()

    state = %{
      screens: [:splash | Enum.map(stops, &elem(&1, 0))],
      titles: Map.new(stops, fn {key, _id, title} -> {key, title} end),
      index: 0,
      arrivals: %{},
      fetched_at: %{},
      bells: %{},
      disrupted: false,
      temperature: nil,
      background: background,
      icons: Application.app_dir(:foxbus, ["priv", "MaterialIcons-Regular.ttf"]),
      shown: nil,
      chirping: nil
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

    state = if current(state) == stop, do: render(state), else: state
    {:noreply, update_chirp(state)}
  end

  def handle_cast({:disruption, disrupted?}, state) do
    state = %{state | disrupted: disrupted?}
    state = if current(state) != :splash, do: render(state), else: state
    {:noreply, state}
  end

  @impl true
  def handle_info({:nest_gen2, :dial_step, %{direction: direction}}, state) do
    steps = step(direction) + pending_steps()
    state = %{state | index: Layout.navigate(state.index, length(state.screens), steps)}
    {:noreply, render(state)}
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
    state = if signature(state) != state.shown, do: render(state), else: state
    {:noreply, update_chirp(state)}
  end

  def handle_info(:chirp, %{chirping: stop} = state) when stop != nil do
    for {hz, ms, delay} <- @chirp, do: Process.send_after(self(), {:tone, hz, ms}, delay)
    Power.wake()
    Process.send_after(self(), :chirp, @chirp_every_ms)
    {:noreply, state}
  end

  def handle_info(:chirp, state), do: {:noreply, state}

  def handle_info({:tone, hz, ms}, state) do
    Piezo.tone(hz, ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Starts chirping for the first stop whose armed bus is arriving (jumping to
  # it), or stops when none is.
  defp update_chirp(state) do
    chirping =
      Enum.find(tl(state.screens), fn stop ->
        Layout.chirping?(mode(state, stop), bell(state, stop))
      end)

    cond do
      chirping == state.chirping ->
        state

      chirping == nil ->
        %{state | chirping: nil}

      true ->
        send(self(), :chirp)
        index = Enum.find_index(state.screens, &(&1 == chirping))
        render(%{state | chirping: chirping, index: index})
    end
  end

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
  defp mode(state, stop), do: Layout.mode(Map.get(state.arrivals, stop), elapsed(state, stop))

  defp signature(state) do
    minute = Calendar.strftime(LondonTime.now(), "%H:%M")

    case current(state) do
      :splash ->
        {:splash, state.temperature, minute}

      stop ->
        {stop, mode(state, stop), bell(state, stop), Map.get(state.arrivals, stop),
         state.disrupted, minute}
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
          Layout.stop(
            state.titles[stop],
            Map.get(state.arrivals, stop),
            elapsed(state, stop),
            bell(state, stop),
            state.disrupted
          )
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
