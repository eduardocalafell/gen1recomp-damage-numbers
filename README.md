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
- Listens to the engine event **`battle.damage_dealt`**, whose payload already
  carries the real HP removed (`damage`), the target (`target.isPlayer`), and
  `crit` / `typeMult`. No HP diffing needed.
- Draws through the **`battle.overlay`** hook in native Game Boy pixels
  (160x144), and calls `PaletteFX.markTrueColor` so the colors stay crisp.

## Options (mod manager -> Damage Numbers -> Options)
- **DAMAGE NUMBERS**: ON / OFF
- **CRIT COLOR**: GOLD / WHITE

## Tweaking
Open `main.lua` and edit the constants near the top:
- `LIFE`, `FADE`, `RISE` — how long numbers last, fade, and how far they rise.
- `ANCHOR.foe` / `ANCHOR.player` — where numbers appear for each side.

## Known limitations (v0.1.0)
- Shows **move damage only**. Passive damage (poison, burn, recoil, confusion
  self-hit) doesn't fire `battle.damage_dealt`, so it isn't shown yet.
- Positions are tuned for the standard battle layout; wide/voxel-3D layouts may
  need different anchors.
