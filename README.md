# foxbus

The example app for [nest_gen2](https://github.com/integration-technology/nest_gen2_sdk):
a repurposed Nest Learning Thermostat (2nd gen) as a bus-arrival display.

foxbus has its own [semantic versioning](https://semver.org/) and is kept as a
GitHub app (not published to Hex) against a tagged SDK release, with a
`NEST_GEN2_PATH` environment variable override for co-developing both repos at
once — see `mix.exs`. Every release is a git tag (`v0.1.0`) with an entry in
[CHANGELOG.md](CHANGELOG.md).

| foxbus | nest_gen2 |
|---|---|
| 0.1.x | 0.1.x |

Turning the dial moves between three screens, clockwise forwards and anticlockwise
back, with Nest's own click. By default (see "Changing the route or stops" below
for overriding this):

1. **Splash** — the fox on the blue disc and the room temperature.
2. **To Uxbridge** — the next 104s and 105s at Carousel stop `040000001207`.
3. **To High Wycombe** — the next 104s and 105s at Carousel stop `040000001208`.

This is currently Holtspur rather than the project's usual Coleshill stops
(`040000002201`/`040000002202`) — Coleshill is closed by a Carousel notice
until Tuesday, so the default is pointed at Holtspur meanwhile. Revert
`mix.exs`'s `stops`/`lines` once 105 is back to normal there.

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

UK time comes from `Foxbus.LondonTime` (the fixed BST rule) instead of tzdata,
and HTTPS is verified against Mozilla's CA set in `priv/cacerts.pem` (from
curl.se, MPL-2.0), since the Nest has no general certificate store.

Settings (the stops, adapters, dial step) are in `mix.exs` under `env`, because on
the Nest the app starts from plain `erl`, which never reads `config/*.exs`.

## Changing the route or stops without a rebuild

The line, the two stops, and which one shows by default can be overridden at
runtime by `Foxbus.Config`, which reads a plain `.exs` file on disk — by
default `config.exs` next to the other device assets (`assets_dir`, normally
`/media/scratch/.nest_gen2_sdk/foxbus/`). Copy `config.exs.example` there,
edit it, and restart the app (`app_watchdog.sh` or `kill -TERM 1`) — no
recompile or redeploy needed. A missing file, or a key it doesn't set, falls
back to mix.exs' compiled `env`; a malformed file is ignored rather than
stopping the app from booting.

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
../nest_gen2_sdk/platform/deploy_app.sh . [--no-test]
```

Runs the tests and a prod build, checks foxbus was built against the same
`nest_gen2` version installed on the Nest (refusing on a mismatch), uploads
foxbus and its other dependencies (never the SDK itself) to the device, and
restarts it.

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
