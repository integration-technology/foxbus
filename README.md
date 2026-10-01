# foxbus

The reference app for [nest_gen2_sdk](https://github.com/integration-technology/nest_gen2_sdk):
a repurposed Nest Learning Thermostat (2nd gen) as a bus-arrival display.

Turning the dial moves between three screens, clockwise forwards and anticlockwise
back, with Nest's own click:

1. **Splash** — the fox on the blue disc and the room temperature.
2. **To Chesham** — the next buses at Carousel stop `040000002201`.
3. **To High Wycombe** — the next buses at Carousel stop `040000002202`.

A bus shows its line and when it's due: a countdown at 10 minutes or less
("4 min"), otherwise the clock time ("at 15:22"). Live buses are white, timetabled
ones slightly dimmer. The screen wakes on the dial or when someone walks up, and
sleeps after 30 seconds.

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

## Build and test

The Nest runs OTP 26 / Elixir 1.17, so build with that toolchain:

```sh
. ../nest_gen2_sdk/platform/host_env.sh
mix deps.get
mix test
MIX_ENV=prod mix compile
```

## Assets

`assets/screen.png` is the 320×320 background: the blue disc (radius 160, black
corners, like the stock UI) with the fox in the centre. `tools/make_assets.py`
turns it into `build/screen.raw`; deploy that to
`/media/scratch/.nest_gen2_sdk/foxbus/screen.raw`. Text is rendered on the device
from the Nest's own Akkurat font by the SDK, so foxbus needs no font files.

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
certificate bundle under MPL-2.0.
