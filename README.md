# Damage Numbers

RPG-style floating damage numbers over the Pokemon that just got hit.

## What it does
When a move connects, the amount of HP it removed pops up over the target and
floats upward while fading out. Critical hits show in gold.

- **Enemy hits** appear over the enemy's front sprite.
- **Your Pokemon's hits** appear over your back sprite.
- Multi-hit moves (Double Kick, Fury Attack, etc.) spread out so each hit is
  readable.

## How it works (for the curious / for hacking on it)
- **Value** comes from the engine event **`battle.damage_dealt`** (the real HP
  removed) plus its `crit` flag.
- **Timing** is driven by **`battler.shownHP`** — the HP the bar visibly drains
  to. The number appears the moment that bar starts falling, i.e. after the
  attack animation, not during turn resolution.
- **Rendering** uses the engine's own Game Boy font (`src.render.Font`) inside a
  white box like the game UI, drawn through the **`battle.overlay`** hook.
  `PaletteFX.markTrueColor` keeps it crisp through the palette pass.
- **Fade** runs on real wall-clock time (`love.timer.getTime`), so fast-forward
  (`--speed` / x4) no longer blinks the number away.

## Options (mod manager -> Damage Numbers -> Options)
- **DAMAGE NUMBERS**: ON / OFF
- **NUMBER SIZE**: 1X / 2X

## Tweaking
Open `main.lua` and edit the constants near the top:
- `LIFE`, `FADE`, `RISE` — how long numbers last (seconds), fade, and rise.
- `ANCHOR.foe` / `ANCHOR.player` — where numbers appear for each side.

## Known limitations
- Shows **move damage only**. Passive damage (poison, burn, recoil, confusion
  self-hit) doesn't fire `battle.damage_dealt`, so it isn't shown yet.
- Positions are tuned for the standard battle layout; wide/voxel-3D layouts may
  need different anchors.
