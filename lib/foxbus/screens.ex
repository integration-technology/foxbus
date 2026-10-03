defmodule Foxbus.Screens do
  @moduledoc """
  The Nest's screens: the splash (fox and room temperature) followed by one
  screen per watched stop. Turning the dial moves between them, clockwise
  forwards and anticlockwise back, wrapping round; each step clicks.

  For testing: if nobody touches the dial or button within 10 s of boot, it
  moves off the splash onto the first stop by itself, so a restart shows live
  times without a manual turn. Any real interaction cancels this.

  No alarm sounds by default — pressing the dial on a stop screen arms its
  next bus (see `Foxbus.Screens.Layout.press/2`); the bell starts chirping
  once that bus is 5 minutes or less away. The Nest only chirps and wakes the
  screen for the stop currently on display, not for an armed bus at a stop
  nobody's looking at; turning the dial away stops the chirp, and turning
  back resumes it. It keeps chirping until either the dial is pressed again
  to mute it, or the bus has gone (a different bus arrives next, or it drops
  off the board). While chirping, a `NestGen2.Power.keep_awake/1` hold keeps
  the screen lit instead of repeatedly calling `Power.wake/0`; the hold is
  released the moment chirping stops, for whichever reason.

  When Carousel names a stop's exact ATCO code as affected by a notice, its
  screen turns red with the direction and the notice's explanation in place of
  any countdown — there are no buses to show a time for. Until that first
  closure check has come back — notably, right after boot — a stop screen
  says "Checking times" rather than risk showing a scheduled, non-arriving
  bus time ahead of knowing the stop might be closed.

  Arrivals, a stop's disruption status, and a stop's closure, all arrive
  through `Foxbus.Adapters.Sinks.ScreensSink`.

  Carousel's board doesn't always drop a bus the moment it actually departs —
  its live ETA can stay reported as "due" (0 min) for a while after. Rather
  than leave the screen stuck green on a bus that's already gone, once the
  next bus has read as due for more than `@stale_due_ms`, it's treated as
  gone and the one behind it (if any) takes its place.

  Pressing the dial on the splash opens settings (`Foxbus.Screens.Settings`,
  rendered by `Foxbus.Screens.SettingsLayout`) — Wi-Fi status, versions, and
  changing network. While open: a `Power.keep_awake(:settings)` hold keeps
  the screen lit, the dial turns and presses route to `Settings.navigate/2`
  and `Settings.select/1` instead of the normal screens, the password wheel
  gets a finer dial step, and ~60 s idle returns to the splash. Scanning and
  connecting run in a `Task` — both can take tens of seconds, and nothing
  here must block the display that long.

  Deliberate trade-off: the arrival alarm is fully suppressed while settings
  is open (the underlying screen index is frozen on `:splash`, which never
  chirps), rather than interrupting a Wi-Fi flow to show a stop screen. A bus
  going imminent mid-settings is silent until settings is left.
  """
  use GenServer
  alias NestGen2.{Display, Image, Piezo, Power}
  alias Foxbus.LondonTime
  alias Foxbus.Domain.Arrival
  alias Foxbus.Screens.{Layout, Settings, SettingsLayout}

  @tick_ms 10_000
  @auto_advance_ms 10_000
  @chirp_every_ms 3_000
  # Two quick rising tones: {frequency Hz, length ms, delay ms from the start}.
  @chirp [{2600, 70, 0}, {3300, 90, 130}]
  @settings_idle_ms 60_000
  @settings_result_ms 5_000
  # How long the next bus can read as due (0 min) before it's treated as
  # gone rather than still shown — see the moduledoc.
  @stale_due_ms 3 * 60_000
  # Finer than the normal screen_step_degrees, for picking one of ~26+
  # characters on the password wheel rather than switching between 2-3 screens.
  @password_step_degrees 15

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec show_arrivals(atom, list) :: :ok
  def show_arrivals(stop, arrivals), do: GenServer.cast(__MODULE__, {:arrivals, stop, arrivals})

  @spec show_disruption(atom, String.t() | nil) :: :ok
  def show_disruption(stop, explanation),
    do: GenServer.cast(__MODULE__, {:disruption, stop, explanation})

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
    auto_advance_timer = Process.send_after(self(), :auto_advance, @auto_advance_ms)

    screens = [:splash | Enum.map(stops, &elem(&1, 0))]
    default_index = Enum.find_index(screens, &(&1 == Foxbus.Config.default_screen())) || 0

    state = %{
      screens: screens,
      titles: Map.new(stops, fn {key, _id, title} -> {key, title} end),
      index: default_index,
      arrivals: %{},
      fetched_at: %{},
      due_since: %{},
      bells: %{},
      disruptions: %{},
      closures: %{},
      temperature: nil,
      background: background,
      icons: Application.app_dir(:foxbus, ["priv", "MaterialIcons-Regular.ttf"]),
      shown: nil,
      chirping: nil,
      power_hold: nil,
      auto_advance_timer: auto_advance_timer,
      settings: nil,
      settings_power_hold: nil,
      settings_idle_timer: nil,
      settings_result_timer: nil,
      settings_task_ref: nil
    }

    {:ok, render(state)}
  end

  @impl true
  def handle_cast({:arrivals, stop, arrivals}, state) do
    state = %{
      state
      | arrivals: Map.put(state.arrivals, stop, arrivals),
        fetched_at: Map.put(state.fetched_at, stop, now()),
        due_since: track_due(state.due_since, stop, arrivals)
    }

    state = if current(state) == stop, do: render(state), else: state
    {:noreply, update_chirp(state)}
  end

  def handle_cast({:disruption, stop, explanation}, state) do
    state = %{state | disruptions: Map.put(state.disruptions, stop, explanation)}
    state = if current(state) == stop, do: render(state), else: state
    {:noreply, state}
  end

  def handle_cast({:closure, stop, explanation}, state) do
    state = %{state | closures: Map.put(state.closures, stop, explanation)}
    state = if current(state) == stop, do: render(state), else: state
    {:noreply, update_chirp(state)}
  end

  @impl true
  def handle_info({:nest_gen2, :dial_step, %{direction: direction}}, %{settings: nil} = state) do
    steps = step(direction) + pending_steps()
    state = cancel_auto_advance(state)
    state = %{state | index: Layout.navigate(state.index, length(state.screens), steps)}
    {:noreply, state |> render() |> update_chirp()}
  end

  def handle_info({:nest_gen2, :dial_step, %{direction: direction}}, state) do
    total = step(direction) + pending_steps()
    dir = if total >= 0, do: :cw, else: :ccw
    old_screen = state.settings.screen

    new_settings =
      Enum.reduce(1..abs(total)//1, state.settings, fn _, s -> Settings.navigate(s, dir) end)

    adjust_dial_step(old_screen, new_settings.screen)
    state = %{state | settings: new_settings} |> reset_settings_idle_timer()
    {:noreply, render(state)}
  end

  def handle_info({:nest_gen2, :climate, %{temperature_c: t}}, state) do
    state = %{state | temperature: t}

    {:noreply,
     if(current(state) == :splash and state.settings == nil, do: render(state), else: state)}
  end

  def handle_info({:nest_gen2, :button, :down}, %{settings: nil} = state) do
    state = cancel_auto_advance(state)
    stop = current(state)

    if stop == :splash do
      {:noreply, state |> open_settings() |> render()}
    else
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
  end

  def handle_info({:nest_gen2, :button, :down}, state) do
    old_screen = state.settings.screen
    {new_settings, effect} = Settings.select(state.settings)
    adjust_dial_step(old_screen, new_settings.screen)
    state = %{state | settings: new_settings} |> reset_settings_idle_timer()
    handle_settings_effect(effect, state)
  end

  # A scan or connect Task finished normally.
  def handle_info({ref, result}, %{settings_task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, apply_task_result(state, result)}
  end

  # A scan or connect Task crashed outright, rather than returning {:error, _}.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{settings_task_ref: ref} = state)
      when reason != :normal do
    {:noreply, apply_task_result(state, {:error, reason})}
  end

  def handle_info(:settings_idle_timeout, %{settings: nil} = state), do: {:noreply, state}

  def handle_info(:settings_idle_timeout, state),
    do: {:noreply, state |> close_settings() |> render()}

  def handle_info(:settings_result_timeout, %{settings: %{screen: :result} = s} = state),
    do:
      {:noreply,
       %{state | settings: %{s | screen: :menu}, settings_result_timer: nil} |> render()}

  def handle_info(:settings_result_timeout, state), do: {:noreply, state}

  # For testing: moves off the splash onto the first stop after a few seconds
  # of nobody touching the dial or button, so a restart doesn't need a manual
  # turn to see live times. Does nothing once cancelled by real interaction,
  # or if there's no stop to move to.
  def handle_info(:auto_advance, state) do
    state = %{state | auto_advance_timer: nil}

    case {state.settings, state.index, Enum.at(state.screens, 1)} do
      {nil, 0, stop} when stop != nil ->
        {:noreply, %{state | index: 1} |> render() |> update_chirp()}

      _ ->
        {:noreply, state}
    end
  end

  # The countdown and the clock move on between fetches: redraw when the minute
  # or colour changes.
  def handle_info(:tick, state) do
    schedule_tick()
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

  defp cancel_auto_advance(%{auto_advance_timer: nil} = state), do: state

  defp cancel_auto_advance(state) do
    Process.cancel_timer(state.auto_advance_timer)
    # cancel_timer/1 only stops a timer that hasn't fired yet — if the 10 s
    # deadline had already passed by the time this ran, its :auto_advance
    # message is already in our mailbox and cancel_timer can't retract it.
    # Left alone, it would still fire later (after this interaction), moving
    # the screen out from under whatever the user just did. A device test
    # hit exactly this: a dial turn back to the splash, then a press, ended
    # up on a stop screen instead of settings, because the stale message
    # jumped the index in between.
    receive do
      :auto_advance -> :ok
    after
      0 -> :ok
    end

    %{state | auto_advance_timer: nil}
  end

  defp open_settings(state) do
    status = wifi_source().status()
    versions = %{foxbus: foxbus_version(), sdk: sdk_version()}
    {:ok, hold} = Power.keep_awake(:settings)

    %{state | settings: Settings.open(status, versions), settings_power_hold: hold}
    |> reset_settings_idle_timer()
  end

  defp close_settings(state) do
    if state.settings_power_hold, do: Power.release(state.settings_power_hold)
    if state.settings_idle_timer, do: Process.cancel_timer(state.settings_idle_timer)
    if state.settings_result_timer, do: Process.cancel_timer(state.settings_result_timer)
    # Defensive: :back only ever reaches here from :menu, never :password, so
    # the dial step should already be restored — but cheap to make sure.
    adjust_dial_step(:password, :menu)

    %{
      state
      | settings: nil,
        settings_power_hold: nil,
        settings_idle_timer: nil,
        settings_result_timer: nil,
        settings_task_ref: nil
    }
  end

  defp reset_settings_idle_timer(state) do
    if state.settings_idle_timer, do: Process.cancel_timer(state.settings_idle_timer)
    timer = Process.send_after(self(), :settings_idle_timeout, @settings_idle_ms)
    %{state | settings_idle_timer: timer}
  end

  # The password wheel needs a finer dial step than the 2-3 highlightable
  # items on every other settings screen, since it's picking one of 26+
  # characters rather than switching screens.
  defp adjust_dial_step(screen, screen), do: :ok
  defp adjust_dial_step(:password, _new), do: NestGen2.Dial.set_step(screen_step_degrees())
  defp adjust_dial_step(_old, :password), do: NestGen2.Dial.set_step(@password_step_degrees)
  defp adjust_dial_step(_old, _new), do: :ok

  defp screen_step_degrees, do: Application.fetch_env!(:foxbus, :screen_step_degrees)

  defp handle_settings_effect(nil, state), do: {:noreply, render(state)}

  defp handle_settings_effect(:exit_to_splash, state),
    do: {:noreply, state |> close_settings() |> render()}

  defp handle_settings_effect(:scan, state) do
    %Task{ref: ref} = Task.async(fn -> wifi_source().scan() end)
    {:noreply, %{state | settings_task_ref: ref} |> render()}
  end

  defp handle_settings_effect({:connect, ssid, password}, state) do
    %Task{ref: ref} = Task.async(fn -> wifi_source().connect(ssid, password) end)
    {:noreply, %{state | settings_task_ref: ref} |> render()}
  end

  defp apply_task_result(state, result) do
    new_settings =
      case state.settings.screen do
        :scanning -> Settings.scan_result(state.settings, result)
        :connecting -> Settings.connect_result(state.settings, result)
      end

    %{state | settings: new_settings, settings_task_ref: nil}
    |> maybe_start_result_timer(new_settings)
    |> render()
  end

  defp maybe_start_result_timer(state, %{screen: :result, connect_result: {:ok, _}}) do
    timer = Process.send_after(self(), :settings_result_timeout, @settings_result_ms)
    %{state | settings_result_timer: timer}
  end

  defp maybe_start_result_timer(state, _settings), do: state

  defp wifi_source, do: Application.fetch_env!(:foxbus, :wifi_source)

  defp foxbus_version, do: Application.spec(:foxbus, :vsn) |> to_string()

  # NestGen2.version/0 is new in nest_gen2 0.2.0; this rescues against
  # running settings against an older SDK during the transition, rather than
  # crashing the whole settings screen over a version string.
  defp sdk_version do
    NestGen2.version()
  rescue
    _ -> "?"
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
    case effective_arrivals(state, stop) do
      [bus | _] -> bus
      _ -> nil
    end
  end

  # Remembers when the current next bus first read as due (eta <= 0), per
  # stop, so effective_arrivals/2 can tell "just went due" from "been due a
  # suspiciously long time" — see the moduledoc. Keyed by bus_key, not just
  # presence, so a new bus reading due immediately (rather than the same one
  # lingering) restarts the clock.
  defp track_due(due_since, stop, [%Arrival{eta_minutes: eta} = bus | _]) when eta <= 0 do
    key = Layout.bus_key(bus)

    case Map.get(due_since, stop) do
      {^key, _first_seen} -> due_since
      _ -> Map.put(due_since, stop, {key, now()})
    end
  end

  defp track_due(due_since, stop, _arrivals), do: Map.delete(due_since, stop)

  # The fetched arrivals, minus a leading bus that's read as due for longer
  # than @stale_due_ms — Carousel's board doesn't always drop a departed bus
  # promptly, and showing it forever as "0 min" looks like foxbus has frozen.
  defp effective_arrivals(state, stop) do
    arrivals = Map.get(state.arrivals, stop)

    case {arrivals, Map.get(state.due_since, stop)} do
      {[bus | rest], {key, first_seen}} ->
        if Layout.bus_key(bus) == key and now() - first_seen > @stale_due_ms,
          do: rest,
          else: arrivals

      _ ->
        arrivals
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

  defp disruption(state, stop), do: Map.get(state.disruptions, stop)

  # A closed (or not-yet-known) stop never counts as arriving/soon: there's no
  # real bus behind a stale scrape, or none confirmed yet, so nothing should
  # auto-arm or chirp for it.
  defp mode(state, stop) do
    case closure_status(state, stop) do
      {:ok, nil} -> Layout.mode(effective_arrivals(state, stop), elapsed(state, stop))
      _ -> :list
    end
  end

  defp signature(%{settings: settings}) when settings != nil do
    {:settings, settings, Calendar.strftime(LondonTime.now(), "%H:%M")}
  end

  defp signature(state) do
    minute = Calendar.strftime(LondonTime.now(), "%H:%M")

    case current(state) do
      :splash ->
        {:splash, state.temperature, minute}

      stop ->
        {stop, mode(state, stop), bell(state, stop), effective_arrivals(state, stop),
         disruption(state, stop), closure_status(state, stop), minute}
    end
  end

  # Every 10 s, and just after each minute turns so the clock changes on time.
  defp schedule_tick do
    to_minute = 60_000 - rem(System.os_time(:millisecond), 60_000) + 50
    Process.send_after(self(), :tick, min(@tick_ms, to_minute))
  end

  defp render(%{settings: settings} = state) when settings != nil do
    settings
    |> SettingsLayout.render()
    |> Layout.with_clock(LondonTime.now())
    |> Enum.each(&draw(&1, state))

    Display.present()
    %{state | shown: signature(state)}
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
                effective_arrivals(state, stop),
                elapsed(state, stop),
                bell(state, stop),
                disruption(state, stop)
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

  defp draw({:rect, x, y, w, h, color}, _state), do: Display.fill_rect(x, y, w, h, color)

  defp draw({:text, x, y, text, opts}, state) do
    opts = if opts[:font] == :icons, do: Keyword.put(opts, :font, state.icons), else: opts
    Display.put_text(x, y, text, opts)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
