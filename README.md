# foxbus

The reference app for [nest_gen2_sdk](https://github.com/integration-technology/nest_gen2_sdk):
a repurposed Nest Learning Thermostat (2nd gen) showing the fox logo on a blue
disc, turning with the ring (with Nest's own click), waking when someone walks
up, and showing the room temperature underneath in Nest's Akkurat font. It grows
into a bus-arrival display.

**Status:** the behaviour runs today on the SDK's Erlang prototype
(`nest_gen2_sdk/prototype`). This repository holds foxbus's artwork and asset
pipeline, and becomes the Elixir app once the SDK package exists.

## Assets

`assets/screen.png` is the whole 320×320 screen: the blue disc (radius 160,
black corners, like the stock UI) with the fox upright in the centre.

```sh
tools/make_assets.py
```

writes to `build/`:

| File | What |
|---|---|
| `screen.raw` | Background, 320×320 BGRX |
| `fox_frames.raw` | 360 pre-rendered 140×140 fox boxes, one per degree (28 MB; ~3.5 MB on the device's compressed flash) |

The temperature text is rendered on the device by the SDK's `textrender` helper
from the Nest's own Akkurat font, so foxbus needs no font files.

Deploy both files to `/media/scratch/.nest_gen2_sdk/` (as `test.raw` and
`fox_frames.raw` for the current prototype).

## Credits

foxbus runs on Nests rooted with
[NoLongerEvil-Thermostat](https://github.com/codykociemba/NoLongerEvil-Thermostat)
by codykociemba, which builds on omap_loader (grant-h / ajb142), the Nest DFU
Attack research (exploiteers / GTVHacker) and the FULU right-to-repair bounty.
See [nest_gen2_sdk](https://github.com/integration-technology/nest_gen2_sdk#credits)
for the full credits.

## Licence

GPL-3.0-only; see [LICENSE](LICENSE). Nest's Akkurat font is licensed separately
and is never part of this repository.
