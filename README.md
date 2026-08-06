# Damage Numbers

RPG-style floating damage numbers over the Pokemon that just got hit, in the
game's own font, colour-coded by what caused the damage.

## What it does
When something takes damage, the amount pops up over that Pokemon and floats
upward while fading out — timed to when its HP bar actually drains.

- **Enemy hits** appear over the enemy's front sprite; **your hits** over your
  back sprite.
- **Colour-coded by cause:**
  - move damage — white box
  - critical hit — gold frame
  - recoil — red
  - poison — purple
  - burn — orange
  - leech seed — green
  - other self-damage (confusion, trap/crash) — grey
- Multi-hit moves (Double Kick, Fury Attack, etc.) show each hit.

## How it works (for the curious / for hacking on it)
- **Move damage** — the engine event **`battle.damage_dealt`** (real HP removed
  + `crit`).
- **Recoil / confusion / trap** — go through `battle:applyDamage` with no event,
  so the mod wraps that method (read-only, `pcall`-guarded, always returns the
  engine's own result) to read target + amount.
- **Poison / burn / leech seed** — don't use `applyDamage` either, so they're
  read from the visible HP-bar drain (`battler.shownHP`) and classified by the
  battler's status (`mon.status`, `leechSeeded`).
- **Timing** — every number waits for its HP bar to start draining (i.e. after
  the animation), driven by `shownHP`.
- **Rendering** — the engine's Game Boy font (`src.render.Font`) in a coloured
  box, via the **`battle.overlay`** hook; `PaletteFX.markTrueColor` keeps the
  colours crisp through the palette pass.
- **Fade** — real wall-clock time (`love.timer.getTime`), so fast-forward
  (`--speed` / x4) doesn't blink the number away.

## Options (mod manager -> Damage Numbers -> Options)
- **DAMAGE NUMBERS**: ON / OFF
- **NUMBER SIZE**: 1X / 2X
- **STATUS & RECOIL**: ON / OFF — colour-coded poison/burn/leech/recoil numbers

## Tweaking
Open `main.lua` and edit the constants near the top:
- `LIFE`, `FADE`, `RISE` — how long numbers last (seconds), fade, and rise.
- `STYLE` — the box colours per cause.
- `ANCHOR.foe` / `ANCHOR.player` — where numbers appear for each side.

## Known limitations
- Positions are tuned for the standard battle layout; wide/voxel-3D layouts may
  need different anchors.
- If a Pokemon is both poisoned and leech-seeded, both ticks are coloured as
  poison (there's no per-tick source signal to tell them apart).
