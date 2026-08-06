# Damage Numbers

RPG-style floating damage numbers over the Pokemon that just got hit, in the
game's own font, colour-coded by what caused the damage.

## What it does
When something takes damage — or heals — the amount pops up over that Pokemon
and floats upward while fading out, timed to when its HP bar actually moves.

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
  - **healing — green "+N"** (Recover/Rest, Absorb-style drains, the leech-seed
    heal on the seeder)
- Poison + leech on the same Pokemon show as **two separate numbers** (purple
  and green) even though the game drains them together.
- Multi-hit moves (Double Kick, Fury Attack, etc.) show each hit.

## How it works (for the curious / for hacking on it)
- **Move damage** — the engine event **`battle.damage_dealt`** (real HP removed
  + `crit`).
- **Recoil / confusion / trap** — go through `battle:applyDamage` with no event,
  so the mod wraps that method (read-only, `pcall`-guarded, always returns the
  engine's own result) to read target + amount.
- **Poison / burn / leech seed** — a read-only wrap of `Status.residual` splits
  the one combined drain into its parts: leech = how much the opponent healed,
  poison/burn = the rest of the drop.
- **Healing** — the HP bar animates *up* toward `mon.hp`, so a rising `shownHP`
  is a heal; the amount is measured from that rise.
- **Timing** — every number waits for its HP bar to start moving (i.e. after
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
- **HEAL NUMBERS**: ON / OFF — the green "+N" heal numbers

## Tweaking
Open `main.lua` and edit the constants near the top:
- `LIFE`, `FADE`, `RISE` — how long numbers last (seconds), fade, and rise.
- `STYLE` — the box colours per cause.
- `ANCHOR.foe` / `ANCHOR.player` — where numbers appear for each side.

## Known limitations
- Positions are tuned for the standard battle layout; wide/voxel-3D layouts may
  need different anchors.
