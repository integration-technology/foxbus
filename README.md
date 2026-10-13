# foxbus

The example app for [nest_gen2](https://github.com/integration-technology/nest_gen2_sdk):
a repurposed Nest Learning Thermostat (2nd gen) as a bus-arrival display.

foxbus has its own [semantic versioning](https://semver.org/) and is kept as a
GitHub app (not published to Hex) against [nest_gen2 on Hex](https://hex.pm/packages/nest_gen2),
with a `NEST_GEN2_PATH` environment variable override for co-developing both
repos at once — see `mix.exs`. Every release is a git tag (`v0.1.0`) with an
entry in [CHANGELOG.md](CHANGELOG.md).

| foxbus | nest_gen2 |
|---|---|
| 0.2.x | 0.2.x |
| 0.1.x | 0.1.x |

Turning the dial moves between three screens, clockwise forwards and anticlockwise
back, with Nest's own click. By default (see "Changing the route or stops" below
for overriding this):

1. **Splash** — the fox on the blue disc and the room temperature.
2. **To Somewhere** — the next 104s at Carousel stop `000000000001`.
3. **To Elsewhere** — the next 104s at Carousel stop `000000000002`.

These are placeholder stops — see "Run foxbus on your own Nest" below for
pointing them at real ones.

A stop screen says "Checking times" until its first stop-closure check has
come back — this happens on every boot — rather than risk showing a
scheduled, non-arriving bus time before knowing whether the stop is closed.

A bus shows its line and when it's due: a countdown at 10 minutes or less
("4 min"), otherwise the clock time ("at 15:22", or "Tomorrow 06:25" once the
board has rolled over to tomorrow's first services). Live buses are white,
timetabled ones slightly dimmer. If a stop's board is simply empty, the screen
says "No more buses today". If Carousel instead names that stop's exact ATCO
code as affected by a notice, the screen turns red with the direction and the
notice's explanation — no countdown, since there's no real bus behind it. The
screen wakes on the dial or when someone walks up, and sleeps after 30 seconds.

No alarm sounds by default. On a stop's countdown screen (10 minutes or
less), pressing the dial arms its next bus, and the bell starts chirping
once that bus is 5 minutes or less away — pressing again mutes it. On the
plain list (more than 10 minutes out), pressing the dial instead selects a
row — the dial then moves a highlight between the listed buses, and pressing
again arms (or disarms) that specific one, wherever it is in the list; an
armed row keeps a small bell next to it. ~20 s of no interaction returns to
normal dial navigation. If a line has an active disruption notice that names
this stop specifically, a short line of the notice's own title shows below
the countdown; a notice naming other stops on the same line doesn't show
here.

## Structure

Hexagonal, carried over from the `busstop` app:

| Part | Module |
|---|---|
| Domain | `Foxbus.Domain.Arrival` — the arrival shape and how its time is shown |
| Ports | `Foxbus.Ports.ArrivalsSource`, `Foxbus.Ports.ArrivalsSink` |
| Application service | `Foxbus.Arrivals` — fetch from the source, publish to the sink |
| Source adapter | `Foxbus.Adapters.Sources.CarouselScrapeSource` (Carousel's board over HTTPS); `StubSource` for development |
| Driving adapter | `Foxbus.Adapters.Schedulers.AdaptiveBusPoller` — 60 s, 30 s near a bus, 30 min when there are none |
| Sink adapter | `Foxbus.Adapters.Sinks.ScreensSink` → `Foxbus.Screens` (drawing) and `Foxbus.Screens.Layout` (pure layout) |
| Settings | `Foxbus.Ports.WifiSource`, `Foxbus.Screens.Settings` (state machine) + `Foxbus.Screens.SettingsLayout` (pure layout) — see below |

UK time comes from `Foxbus.LondonTime` (the fixed BST rule) instead of tzdata,
and HTTPS is verified against Mozilla's CA set in `priv/cacerts.pem` (from
curl.se, MPL-2.0), since the Nest has no general certificate store.

Settings (the stops, adapters, dial step) are in `mix.exs` under `env`, because on
the Nest the app starts from plain `erl`, which never reads `config/*.exs`.

## Run foxbus on your own Nest

foxbus as cloned shows placeholder stops. To point it at your own:

**1. Find your stops' ATCO codes.** foxbus only talks to
[Carousel Buses'](https://www.carouselbuses.co.uk) own departure boards
(`Foxbus.Adapters.Sources.CarouselScrapeSource` and the disruption/closure
sources alongside it all hardcode `carouselbuses.co.uk`) — it doesn't yet
support other operators or a general journey-planner API. If Carousel
doesn't serve your stop, foxbus won't show anything for it. Each stop is
identified by its ATCO code (the standard UK bus-stop identifier, e.g.
`000000000001`), which you can look up by name on
[bustimes.org](https://bustimes.org) — it's in the stop's own URL there.
Confirm Carousel actually publishes live times for it by visiting
`https://www.carouselbuses.co.uk/stops/<the-code>` in a browser before
configuring foxbus: a working departure board means it'll work; nothing
there means Carousel doesn't serve that stop.

**2. Put the codes, names, and route(s) into config.** Two ways, same shape:

- At runtime, no rebuild — see "Changing the route or stops without a
  rebuild" below. This is the easier way to try a stop before committing to
  it.
- Compiled in, as `mix.exs`'s own defaults (so a bare `deploy_app.sh` with
  no Storage override set still shows the right thing) — edit the `stops`,
  `lines`, and (if you want one direction to show by default) matching
  `Foxbus.Config.default_screen/0` fallback in `mix.exs`'s `env`.

Either way, the shape is:

```elixir
stops: [
  {:towards_somewhere, "<your-stop-1-atco-code>", "To Somewhere"},
  {:towards_elsewhere, "<your-stop-2-atco-code>", "To Elsewhere"}
],
lines: ["<route-number>"]
```

`:towards_somewhere`/`:towards_elsewhere` are just atoms you pick to name
each screen internally — they can be anything, and aren't shown on screen.
The ATCO codes and the `"To Somewhere"` title text are the parts that are
actually about your stops; replace both, along with `lines` (the route
number(s) to watch at that stop — a list, since a shared stop can see more
than one route; see `Foxbus.Config`'s moduledoc). One stop works too, with
a single `{atom, code, title}` tuple.

**3. Deploy.** From the SDK folder, with foxbus cloned alongside it:

```sh
platform/deploy_app.sh ../foxbus
```

See "Deploy" below for what this does, including on a fresh Nest.

## Changing the route or stops without a rebuild

The line, the two stops, and which one shows by default can be overridden at
runtime by `Foxbus.Config`, which reads them from `NestGen2.Storage` — set
from your computer, no recompile or redeploy needed. They're only read once,
at start (the pollers are built from them then), so still need the app
restarted (`app_watchdog.sh` or `kill -TERM 1`) to take effect:

```sh
../nest_gen2_sdk/platform/storage.sh foxbus put stops '[{:towards_somewhere, "<code>", "To Somewhere"}, {:towards_elsewhere, "<code>", "To Elsewhere"}]'
../nest_gen2_sdk/platform/storage.sh foxbus put lines '["104"]'
../nest_gen2_sdk/platform/storage.sh foxbus put default_screen ':towards_somewhere'
```

A key Storage doesn't have falls back to mix.exs' compiled `env`
(`default_screen` to `:splash`); `platform/storage.sh foxbus delete <key>`
removes an override to go back to that. `platform/storage.sh foxbus list`
shows what's currently set.

Before nest_gen2 0.3.0 this was a hand-edited `config.exs` file
(`config.exs.example` was its template). `Foxbus.Config.migrate_from_file/0`
carries an existing one's values into Storage once, at the next boot after
upgrading, then leaves the old file alone — nothing needs doing by hand to
keep an existing install's route and stops.

## Wi-Fi settings

Pressing the dial on the splash opens settings: Wi-Fi status (SSID, IP,
signal), the foxbus and SDK versions, and a flow to join a different network:
scan → pick → "Join now" or "Save for later", sharing a character-wheel
password entry for secured networks it doesn't already know. "Save for
later" stores a network (replacing any saved entry with the same SSID)
without switching to it — for somewhere the Nest will go later, such as a
phone hotspot that's usually off at home; it only offers networks currently
in range, though, same limitation as joining. ~60 s idle, or selecting Back,
returns to the splash.

This is built against `Foxbus.Ports.WifiSource`, a port with two adapters:
`NestGen2WifiSource` (a thin wrapper over `NestGen2.Wifi`, nest_gen2 0.2.0 —
`save/2` needs 0.3.0 — what `mix.exs` configures by default) and
`FakeWifiSource` (deterministic, no real network, for developing and testing
the settings screens without hardware).

The menu's second item, "Screen", sets how the screen sleeps and wakes:
how long idle before it sleeps ("30 s" / "1 min" / "5 min" / "Always on"),
and whether it wakes when someone approaches ("Wake on approach"). Each row
is picked with the dial and cycled in place with a press — no further
screen to drill into. The dial and button always wake the screen; there's
no way to turn that off, since with wake-on-approach also off there'd be no
way back short of a reboot. The choice is saved to `NestGen2.Storage` (see
`Foxbus.ScreenPower`) and re-applied on every boot, since `NestGen2.Power`
itself always starts from its own defaults (30 s, every wake source).

## Build and test

The Nest runs OTP 26 / Elixir 1.17, so build with that toolchain:

```sh
. ../nest_gen2_sdk/platform/host_env.sh
mix deps.get
mix test
MIX_ENV=prod mix compile
```

## Deploy

```sh
../nest_gen2_sdk/platform/deploy_app.sh . [--no-test] [--sdk]
```

Runs the tests and a prod build, checks foxbus was built against the same
`nest_gen2` version installed on the Nest (refusing on a mismatch, unless
`--sdk` is given — that installs foxbus's version, replacing whatever's
there), uploads foxbus and its other dependencies to the device, and
restarts it. The first deploy to a fresh Nest always installs the SDK too,
`--sdk` or not. `--no-test` skips `mix test`; both flags work in either
order.

## Assets

`assets/screen.png` is the 320×320 background: the blue disc (radius 160, black
corners, like the stock UI) with the fox in the centre. `tools/make_assets.py`
turns it into `build/screen.raw`; deploy that to
`/media/scratch/.nest_gen2_sdk/foxbus/screen.raw`. Text is rendered on the device
from the Nest's own Akkurat font by the SDK, so foxbus needs no font file for
that. The bell and warning icons are a separate glyph font, bundled at
`priv/MaterialIcons-Regular.ttf` — see Licence below.

## Credits

foxbus runs on Nests rooted with
[NoLongerEvil-Thermostat](https://github.com/codykociemba/NoLongerEvil-Thermostat)
by codykociemba, which builds on omap_loader (grant-h / ajb142), the Nest DFU
Attack research (exploiteers / GTVHacker) and the FULU right-to-repair bounty.
See [nest_gen2_sdk](https://github.com/integration-technology/nest_gen2_sdk#credits)
for the full credits. Bus times come from Carousel Buses' public departure board.

## Licence

GPL-3.0-only; see [LICENSE](LICENSE). Nest's Akkurat font is licensed separately
and is never part of this repository. `priv/cacerts.pem` is Mozilla's CA
certificate bundle under MPL-2.0. `priv/MaterialIcons-Regular.ttf` is Google's
Material Icons font, an unmodified copy of version 1.017 from
[google/material-design-icons](https://raw.githubusercontent.com/google/material-design-icons/master/font/MaterialIcons-Regular.ttf)
(sha256 `ef149f08bdd2ff09a4e2c8573476b7b0f3fbb15b623954ade59899e7175bedda`),
licensed under Apache-2.0 — see [priv/MaterialIcons-LICENSE.txt](priv/MaterialIcons-LICENSE.txt).
