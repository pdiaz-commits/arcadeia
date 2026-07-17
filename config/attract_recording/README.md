# `config/attract_recording/` — per-game RAM layouts

Each `<game_id>.yaml` here tells `scripts/mame/teach_attract.sh <game_key>`
**exactly where** in MAME memory to look, so the generic recorder
(`scripts/mame/teach_attract.lua`) can dump the attract-mode demo
without game-specific Lua code.

The launcher reads the YAML, emits a Lua companion at
`scripts/mame/.teach_attract_<game_id>.lua`, and MAME loads it via the
`ARCADEIA_ATTRACT_CFG` env var.

## Two modes

| `mode`     | Best for                              | What gets recorded                              |
|------------|---------------------------------------|-------------------------------------------------|
| `tile`     | atetris                               | heights per col, active-piece cells, bg tile    |
| `sprite`   | wboy, gngb, outrun, …                 | `{code, sx, sy}` for every non-zero sprite      |

## Tile mode schema

```yaml
mode: tile
game_id: <id>
record_seconds: 60           # how long to record (60 = 1 minute demo)
sample_every: 4              # log every N frames (4 ≈ 15 Hz at 60 fps)
boot_skip_frames: 0          # frames to wait before recording (skip title)

tile:
  base: 0x1000               # maincpu program-space base addr of tile grid
  col_count: 64              # cells per row (row stride)
  bytes_per_cell: 2          # 1 or 2 bytes per tile code

  bg_scan:                   # window where to detect "background" tile
    rows: [rlo, rhi]         #   (most-frequent code wins)
    cols: [clo, chi]
  playfield:                 # actual gameplay window
    rows: [rlo, rhi]
    cols: [clo, chi]
```

For atetris the layout is `(r*64 + c)*2` bytes per tile starting at `0x1000`.

## Sprite mode schema

```yaml
mode: sprite
game_id: <id>
record_seconds: 60
sample_every: 3
boot_skip_frames: 0

sprite:
  base: 0xd000               # maincpu program-space base addr of spriteram
  stride: 8                  # bytes per sprite entry
  sprite_count: 256          # how many sprite slots to scan
  code_offset: 0             # byte offset within a sprite entry for the code
  x_raw_offset: 2            # byte offset for the raw X byte
  x_offset: -128             # signed addend applied to raw_x → screen sx
  y_raw_offset: 1            # byte offset for the raw Y byte
  y_transform: flip          # flip | direct | offset
                             #   flip: sy = 256 - raw_y
                             #   direct: sy = raw_y
                             #   offset: sy = raw_y - 0x100
  ignore_codes: [0, 255]     # sprite codes that mean "empty slot" (skip)
```

## Adding a new game

1. Find the `game_id` in `config/games.yaml` (e.g. `frogger` → `game_id: frogger`).
2. Locate the relevant RAM in the MAME driver source (e.g. `vendor/mame/src/mame/frogger.cpp`).
   Look for `SPRITE_RAM`, `spriteram`, `videoram`, `objectram` — the
   byte stride and offsets are usually right next to those declarations.
3. Cross-check with an existing `scripts/mame/<game>_ai.lua` if one exists.
4. Drop `config/attract_recording/<game_id>.yaml` with the right values.
5. Run `scripts/mame/teach_attract.sh <game_key> --dry-run` to verify
   the Lua config it generates parses.
6. Run for real: `scripts/mame/teach_attract.sh <game_key> --no-window`.
   Check `logs/demos/attract_<game_id>_*.jsonl` and `logs/demos/mame_attract_last.log`.

## Quick verification

```bash
# Generate Lua config without launching MAME:
scripts/mame/teach_attract.sh atetris --dry-run
# Should print a Lua table with mode=tile, tile.base=0x1000, etc.
```