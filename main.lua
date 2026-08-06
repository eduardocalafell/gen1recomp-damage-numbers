-- Damage Numbers
-- ---------------------------------------------------------------------------
-- RPG-style floating damage numbers over the Pokemon that just got hit, in the
-- game's own font, colour-coded by what caused the damage.
--
-- v0.3.0 design (see the gen1recomp engine source):
--   * Move damage: the battle.damage_dealt event (real HP removed + crit flag).
--   * Recoil / confusion / trap: these go through battle:applyDamage(target,dmg)
--     but emit no event, so we wrap that method (read-only, pcall-guarded, and
--     we always return the original result) to capture target + amount.
--   * Poison / burn / leech seed: these don't even use applyDamage, so we catch
--     them from the visible HP-bar drain (battler.shownHP) and classify by the
--     battler's status (mon.status == "PSN"/"BRN", battler.leechSeeded).
--   * Every number is TIMED to when its HP bar actually starts draining -- i.e.
--     after the animation -- and FADES on real time (love.timer.getTime) so
--     fast-forward (--speed / x4) doesn't blink it away.
-- ---------------------------------------------------------------------------

return function(mod)
  local ok_font, Font = pcall(require, "src.render.Font")
  if not ok_font then Font = nil end
  local ok_pfx, PaletteFX = pcall(require, "src.render.PaletteFX")
  if not ok_pfx then PaletteFX = nil end
  local getTime = (love.timer and love.timer.getTime) or nil
  local function now() return getTime and getTime() or 0 end

  ----------------------------------------------------------------------------
  -- Options
  ----------------------------------------------------------------------------
  mod.options:define({
    { key = "enabled", label = "DAMAGE NUMBERS", type = "choice",
      default = "on", choices = { { "ON", "on" }, { "OFF", "off" } } },
    { key = "size", label = "NUMBER SIZE", type = "choice",
      default = "2x", choices = { { "1X", "1x" }, { "2X", "2x" } } },
    -- poison / burn / leech / recoil / other, coloured by cause
    { key = "passive", label = "STATUS & RECOIL", type = "choice",
      default = "on", choices = { { "ON", "on" }, { "OFF", "off" } } },
  })

  local function optionValue(game, key)
    local opts = game and game.save and game.save.options
    local bucket = opts and opts.modOptions and opts.modOptions[mod.id]
    local v = bucket and bucket[key]
    if v == nil then v = mod.options:get(key) end
    return v
  end

  ----------------------------------------------------------------------------
  -- Tunables (real seconds for time, native GB pixels for layout)
  ----------------------------------------------------------------------------
  local LIFE, FADE, RISE, STALE = 0.95, 0.30, 16, 3.0
  local PADX, BOXH = 3, 9
  local ANCHOR = {
    foe = { x = 120, y = 34 },
    player = { x = 44, y = 66 },
  }

  -- box styles per cause: { fill = {r,g,b}, frame = {r,g,b} or nil = black }
  -- fills are light so the (always-black) GB-font digits stay readable.
  local STYLE = {
    move   = { fill = { 1.00, 1.00, 1.00 }, frame = nil },
    crit   = { fill = { 1.00, 1.00, 1.00 }, frame = { 1.00, 0.82, 0.20 } },
    recoil = { fill = { 0.98, 0.72, 0.70 }, frame = { 0.80, 0.15, 0.15 } },
    poison = { fill = { 0.82, 0.68, 0.92 }, frame = { 0.55, 0.20, 0.75 } },
    burn   = { fill = { 1.00, 0.80, 0.55 }, frame = { 0.85, 0.35, 0.05 } },
    leech  = { fill = { 0.72, 0.92, 0.62 }, frame = { 0.20, 0.60, 0.15 } },
    other  = { fill = { 0.86, 0.86, 0.86 }, frame = { 0.40, 0.40, 0.40 } },
  }

  ----------------------------------------------------------------------------
  -- State
  ----------------------------------------------------------------------------
  -- per-side queue of records waiting for their bar to drain:
  --   { amount, cause = "pending"|"move", crit, target, t }
  local queue = { foe = {}, player = {} }
  local prevShown = { foe = nil, player = nil }
  local draining = { foe = false, player = false }
  local drainStart = { foe = nil, player = nil } -- startHP for residual measure
  local lastAttacker = { battler = nil, at = 0 }
  local floats = {} -- { amount, side, style, born }
  local curBattle = nil

  local function sideOf(battle, battler)
    if battler == battle.player then return "player" end
    if battler == battle.enemy then return "foe" end
    return nil
  end

  -- Wrap applyDamage once per battle to log non-move HP losses (recoil, etc).
  local function installWrap(battle)
    if battle.__dmgnum_wrapped then return end
    local orig = battle.applyDamage
    if type(orig) ~= "function" then return end
    battle.__dmgnum_wrapped = true
    battle.applyDamage = function(self, target, dmg)
      local before = target and target.mon and target.mon.hp
      local dealt = orig(self, target, dmg)
      pcall(function()
        if not (target and target.mon and before) then return end
        local after = target.mon.hp
        if after and after < before then
          local side = sideOf(self, target)
          if side then
            local q = queue[side]
            q[#q + 1] = { amount = before - after, cause = "pending",
                          target = target, t = now() }
          end
        end
      end)
      return dealt -- never alter the engine's result
    end
  end

  local function resetFor(battle)
    curBattle = battle
    queue.foe, queue.player = {}, {}
    prevShown.foe, prevShown.player = nil, nil
    draining.foe, draining.player = false, false
    drainStart.foe, drainStart.player = nil, nil
    lastAttacker = { battler = nil, at = 0 }
    floats = {}
    installWrap(battle)
  end

  -- Move damage: accurate value + crit. Upgrade the applyDamage record the
  -- move-hit just logged (it runs a few lines before this event fires).
  mod.events:on("battle.damage_dealt", function(e)
    if not e or not e.target or not e.battle then return end
    lastAttacker = { battler = e.user, at = now() }
    local side = sideOf(e.battle, e.target)
    if not side then return end
    local dmg = math.floor((e.damage or 0) + 0.5)
    local q = queue[side]
    for i = #q, 1, -1 do
      if q[i].cause == "pending" and q[i].target == e.target
         and q[i].amount == dmg then
        q[i].cause, q[i].crit = "move", (e.crit and true or false)
        return
      end
    end
    -- nothing to upgrade (e.g. a substitute ate it): queue it anyway
    if dmg > 0 then
      q[#q + 1] = { amount = dmg, cause = "move", crit = e.crit and true or false,
                    target = e.target, t = now() }
    end
  end)

  mod.events:on("battle.started", function(e)
    if e and e.battle then resetFor(e.battle) end
  end)

  ----------------------------------------------------------------------------
  -- Classification
  ----------------------------------------------------------------------------
  local function styleForRecord(rec, t0)
    if rec.cause == "move" then
      return rec.crit and STYLE.crit or STYLE.move
    end
    -- an un-upgraded applyDamage record: recoil hits the attacker itself
    if rec.target == lastAttacker.battler and t0 - lastAttacker.at < 1.5 then
      return STYLE.recoil
    end
    return STYLE.other -- confusion self-hit, trap, crash damage
  end

  local function styleForResidual(battler)
    local status = battler and battler.mon and battler.mon.status
    if status == "PSN" then return STYLE.poison end
    if status == "BRN" then return STYLE.burn end
    if battler and battler.leechSeeded then return STYLE.leech end
    return STYLE.other
  end

  local function spawn(side, amount, style, t0)
    floats[#floats + 1] =
      { amount = amount, side = side, style = style, born = t0 }
    if #floats > 24 then table.remove(floats, 1) end
  end

  ----------------------------------------------------------------------------
  -- Draw one number: coloured box + black GB-font digits
  ----------------------------------------------------------------------------
  local function drawFloat(f, scale, t0)
    if not Font then return end
    local text = tostring(f.amount)
    local boxW, boxH = Font.width(text) + PADX * 2, BOXH

    local age = t0 - f.born
    local t = age / LIFE
    local anchor = f.side == "player" and ANCHOR.player or ANCHOR.foe
    local cx = anchor.x
    local cy = anchor.y - RISE * (1 - (1 - t) * (1 - t))
    local a = 1
    if age > LIFE - FADE then a = math.max(0, (LIFE - age) / FADE) end

    local fill = f.style.fill
    local frame = f.style.frame
    local gfx = love.graphics
    gfx.push("all")
    gfx.setShader()
    gfx.translate(cx, cy)
    gfx.scale(scale, scale)
    local x0, y0 = math.floor(-boxW / 2), math.floor(-boxH / 2)
    gfx.setColor(fill[1], fill[2], fill[3], a)
    gfx.rectangle("fill", x0, y0, boxW, boxH)
    gfx.setColor(0, 0, 0, a)
    gfx.rectangle("line", x0 + 0.5, y0 + 0.5, boxW - 1, boxH - 1)
    if frame then
      gfx.setColor(frame[1], frame[2], frame[3], a)
      gfx.rectangle("line", x0 + 1.5, y0 + 1.5, boxW - 3, boxH - 3)
    end
    gfx.setColor(1, 1, 1, a) -- GB tile digits stay black; alpha still fades
    Font.draw(text, x0 + PADX, y0 + 1)
    gfx.pop()

    if PaletteFX and PaletteFX.markTrueColor then
      PaletteFX.markTrueColor(
        math.floor(cx - boxW * scale / 2) - 1,
        math.floor(cy - boxH * scale / 2) - 1,
        math.ceil(boxW * scale) + 2, math.ceil(boxH * scale) + 2)
    end
  end

  ----------------------------------------------------------------------------
  -- Overlay hook: watch bar drains, spawn + draw numbers
  ----------------------------------------------------------------------------
  mod.hooks:wrap("battle.overlay", function(next, battle)
    local result = next()
    if not battle then return result end
    if battle ~= curBattle then resetFor(battle) end

    local t0 = now()
    local passive = optionValue(battle.game, "passive") == "on"
    local sides = { foe = battle.enemy, player = battle.player }

    for side, b in pairs(sides) do
      local shown = b and b.shownHP
      if type(shown) == "number" then
        local prev = prevShown[side]
        if prev and shown < prev - 0.001 then
          if not draining[side] then
            local rec = table.remove(queue[side], 1) -- FIFO, matches drain order
            if rec then
              local style = styleForRecord(rec, t0)
              if rec.cause == "move" or passive then
                spawn(side, rec.amount, style, t0)
              end
            else
              drainStart[side] = prev -- residual: measure over the drain
            end
          end
          draining[side] = true
        else
          if draining[side] and drainStart[side] then
            local amt = math.floor(drainStart[side] - shown + 0.5)
            if amt > 0 and passive then
              spawn(side, amt, styleForResidual(b), t0)
            end
          end
          drainStart[side] = nil
          draining[side] = false
        end
        prevShown[side] = shown
      end
    end

    -- drop records whose bar never drained (substitute hits, etc.)
    for _, side in ipairs({ "foe", "player" }) do
      local q = queue[side]
      local i = 1
      while i <= #q do
        if t0 - (q[i].t or t0) > STALE then table.remove(q, i) else i = i + 1 end
      end
    end

    if optionValue(battle.game, "enabled") == "on" and Font then
      local scale = optionValue(battle.game, "size") == "1x" and 1 or 2
      for i = #floats, 1, -1 do
        if t0 - floats[i].born >= LIFE then
          table.remove(floats, i)
        else
          drawFloat(floats[i], scale, t0)
        end
      end
    end

    return result
  end)

  if mod.log and mod.log.info then
    mod.log:info("Damage Numbers v0.3.0 loaded")
  end
end
