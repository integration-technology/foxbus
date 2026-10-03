# Changelog

All notable changes to `foxbus`. Versions follow [Semantic Versioning](https://semver.org/):
while the version is 0.x, a minor release (0.1 → 0.2) may change behaviour.

Depends on [`nest_gen2`](https://github.com/integration-technology/nest_gen2_sdk);
foxbus 0.2.x targets nest_gen2 0.2.x.

## 0.2.0 (2026-10-03)

- Wi-Fi settings: pressing the dial on the splash opens a settings screen showing Wi-Fi
  status (SSID, IP, signal), the foxbus and SDK versions, and a flow to join a different
  network (scan → pick → a character-wheel password entry for secured networks it doesn't
  already know → connect). ~60 s idle, or selecting Back, returns to the splash. Built
  against `Foxbus.Ports.WifiSource`, backed by `NestGen2.Wifi` (nest_gen2 0.2.0).
- The alarm bell no longer arms itself: pressing the dial on a stop screen arms its next
  bus, and a bus only chirps once armed and within 5 minutes; a second press mutes it.
  Previously the bell armed itself automatically the moment a bus went imminent.
- Disruption notices are now checked per stop rather than for the whole app: a notice
  naming specific affected stops only shows its warning line on those stops, not on every
  stop watching the same line (`CarouselDisruptionsSource` now also reads a notice's
  "Affected stops" list, the same markup `CarouselStopClosureSource` reads for closures).
- Dependency: `nest_gen2` bumped to `~> 0.2.0`.

## 0.1.1 (2026-10-02)

- Dependency only: `nest_gen2` now comes from [Hex](https://hex.pm/packages/nest_gen2)
  (`~> 0.1.0`) instead of a GitHub tag. Same SDK code (0.1.0); no behaviour change.

## 0.1.0 (2026-10-02)

First release.

- Live arrivals scraped from Carousel's per-stop departure board (`CarouselScrapeSource`),
  filtered to a configurable list of lines (`Foxbus.Config.lines/0`) so a shared stop can
  watch several routes at once without showing the others.
- Screens: a countdown (minutes, or the clock time — "Tomorrow HH:MM" once the board rolls
  over to the next day), a bell that arms itself when a bus is 5 minutes or less away and
  chirps until silenced or the bus has gone, and "No more buses today" when the board is
  empty.
- Disruption awareness: a small warning icon when the watched line has an active notice
  (`CarouselDisruptionsSource`), and a full red "closed" screen with the notice's own text
  when Carousel names the exact stop as affected (`CarouselStopClosureSource`) — no
  countdown shown, since there's no real bus behind it.
- `Foxbus.Config`: the route, stops, and default screen are overridable at runtime from a
  plain `config.exs` on disk, without a rebuild — see `config.exs.example`.
- For testing: auto-advances off the splash to the first stop after 10 s of no interaction.
- Hexagonal structure throughout (ports/adapters per concern), with `StubSource` and
  friends for developing without the network.
