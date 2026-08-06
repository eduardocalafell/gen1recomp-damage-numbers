-- Damage Numbers
-- ---------------------------------------------------------------------------
-- Floating, RPG-style damage (and heal) numbers in battle, in the game's own
-- font, colour-coded by cause.
--
-- v0.4.0 sources (see the gen1recomp engine source):
--   * Move damage  -> battle.damage_dealt event (real HP removed + crit).
--   * Recoil/confusion/trap -> read-only wrap of battle:applyDamage.
--   * Poison/burn/leech -> read-only wrap of Status.residual, which splits the
--     one combined drain into its parts (leech = how much the opponent healed,
--     poison/burn = the rest of the drop).
--   * Healing (Recover/Rest, Absorb-style drains, the leech-seed heal) shows as
--     a green "+N": the HP bar animates UP toward mon.hp, so a rising shownHP is
--     a heal. Amount is measured from that rise.
--   * Timing follows the visible HP-bar drain/fill (battler.shownHP); fade runs
--     on real time (love.timer.getTime) so fast-forward doesn't blink it away.
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
    { key = "passive", label = "STATUS & RECOIL", type = "choice",
      default = "on", choices = { { "ON", "on" }, { "OFF", "off" } } },
    { key = "heals", label = "HEAL NUMBERS", type = "choice",
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
  -- Tunables
  ----------------------------------------------------------------------------
  local LIFE, FADE, RISE, STALE = 0.95, 0.30, 16, 3.0
  local PADX, BOXH = 3, 9
  local ANCHOR = {
    foe = { x = 120, y = 34 },
    player = { x = 44, y = 66 },
  }
  local STYLE = {
    move   = { fill = { 1.00, 1.00, 1.00 }, frame = nil },
    crit   = { fill = { 1.00, 1.00, 1.00 }, frame = { 1.00, 0.82, 0.20 } },
    recoil = { fill = { 0.98, 0.72, 0.70 }, frame = { 0.80, 0.15, 0.15 } },
    poison = { fill = { 0.82, 0.68, 0.92 }, frame = { 0.55, 0.20, 0.75 } },
    burn   = { fill = { 1.00, 0.80, 0.55 }, frame = { 0.85, 0.35, 0.05 } },
    leech  = { fill = { 0.72, 0.92, 0.62 }, frame = { 0.20, 0.60, 0.15 } },
    other  = { fill = { 0.86, 0.86, 0.86 }, frame = { 0.40, 0.40, 0.40 } },
    heal   = { fill = { 0.70, 0.96, 0.66 }, frame = { 0.12, 0.62, 0.20 } },
  }

  ----------------------------------------------------------------------------
  -- State
  ----------------------------------------------------------------------------
  local queue = { foe = {}, player = {} }          -- move/recoil/etc records
  local residualPending = { foe = {}, player = {} } -- {amount, style} per tick
  local track = { foe = {}, player = {} }           -- per-side bar tracker
  local lastAttacker = { battler = nil, at = 0 }
  local floats = {}
  local curBattle = nil

  local function sideOf(battle, battler)
    if battler == battle.player then return "player" end
    if battler == battle.enemy then return "foe" end
    return nil
  end

  local function styleForResidual(battler)
    local status = battler and battler.mon and battler.mon.status
    if status == "PSN" then return STYLE.poison end
    if status == "BRN" then return STYLE.burn end
    if battler and battler.leechSeeded then return STYLE.leech end
    return STYLE.other
  end

  ----------------------------------------------------------------------------
  -- Read-only wraps
  ----------------------------------------------------------------------------
  -- Recoil / confusion / trap all funnel through applyDamage (no event).
  local function installDamageWrap(battle)
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
      return dealt
    end
  end

  -- Poison/burn/leech run through Status.residual, which the engine drains as
  -- ONE bar move. Splitting needs the parts, so wrap it once (process-wide).
  local ok_status, Status = pcall(require, "src.battle.Status")
  if ok_status and Status and type(Status.residual) == "function"
     and not Status.__dmgnum_wrapped then
    local orig = Status.residual
    Status.__dmgnum_wrapped = true
    Status.residual = function(battler, opponent, battle)
      local bBefore = battler and battler.mon and battler.mon.hp
      local oBefore = opponent and opponent.mon and opponent.mon.hp
      local msgs = orig(battler, opponent, battle)
      pcall(function()
        if not (battle and battler and battler.mon and bBefore) then return end
        local side = sideOf(battle, battler)
        if not side then return end
        local drop = math.max(0, bBefore - battler.mon.hp)
        local leech = 0
        if opponent and opponent.mon and oBefore then
          leech = math.max(0, opponent.mon.hp - oBefore)
        end
        local dot = drop - leech -- poison/burn portion
        local rp = residualPending[side]
        if dot > 0 then rp[#rp + 1] = { amount = dot, style = styleForResidual(battler) } end
        if leech > 0 then rp[#rp + 1] = { amount = leech, style = STYLE.leech } end
      end)
      return msgs
    end
  end

  local function resetFor(battle)
    curBattle = battle
    queue.foe, queue.player = {}, {}
    residualPending.foe, residualPending.player = {}, {}
    track.foe, track.player = {}, {}
    lastAttacker = { battler = nil, at = 0 }
    floats = {}
    installDamageWrap(battle)
  end

  mod.events:on("battle.damage_dealt", function(e)
    if not e or not e.target or not e.battle then return end
    lastAttacker = { battler = e.user, at = now() }
    local side = sideOf(e.battle, e.target)
    if not side then return end
    local dmg = math.floor((e.damage or 0) + 0.5)
    local q = queue[side]
    for i = #q, 1, -1 do
      if q[i].cause == "pending" and q[i].target == e.target and q[i].amount == dmg then
        q[i].cause, q[i].crit = "move", (e.crit and true or false)
        return
      end
    end
    if dmg > 0 then
      q[#q + 1] = { amount = dmg, cause = "move", crit = e.crit and true or false,
                    target = e.target, t = now() }
    end
  end)

  mod.events:on("battle.started", function(e)
    if e and e.battle then resetFor(e.battle) end
  end)

  ----------------------------------------------------------------------------
  -- Spawning
  ----------------------------------------------------------------------------
  local function styleForRecord(rec, t0)
    if rec.cause == "move" then return rec.crit and STYLE.crit or STYLE.move end
    if rec.target == lastAttacker.battler and t0 - lastAttacker.at < 1.5 then
      return STYLE.recoil
    end
    return STYLE.other
  end

  local function spawn(side, amount, style, t0, heal, yoff)
    floats[#floats + 1] = { amount = amount, side = side, style = style,
                            born = t0, heal = heal or false, yoff = yoff or 0 }
    if #floats > 24 then table.remove(floats, 1) end
  end

  ----------------------------------------------------------------------------
  -- Draw one number: coloured box + black GB-font digits (+ a "+" for heals)
  ----------------------------------------------------------------------------
  local function drawPlus(x, y, col, a) -- small 5x5 cross
    local g = love.graphics
    g.setColor(col[1], col[2], col[3], a)
    g.rectangle("fill", x, y + 2, 5, 1)
    g.rectangle("fill", x + 2, y, 1, 5)
  end

  local function drawFloat(f, scale, t0)
    if not Font then return end
    local text = tostring(f.amount)
    local digitsW = Font.width(text)
    local plusW = f.heal and 6 or 0
    local boxW, boxH = plusW + digitsW + PADX * 2, BOXH

    local age = t0 - f.born
    local t = age / LIFE
    local anchor = f.side == "player" and ANCHOR.player or ANCHOR.foe
    local cx = anchor.x
    local cy = anchor.y - f.yoff - RISE * (1 - (1 - t) * (1 - t))
    local a = 1
    if age > LIFE - FADE then a = math.max(0, (LIFE - age) / FADE) end

    local fill, frame = f.style.fill, f.style.frame
    local g = love.graphics
    g.push("all")
    g.setShader()
    g.translate(cx, cy)
    g.scale(scale, scale)
    local x0, y0 = math.floor(-boxW / 2), math.floor(-boxH / 2)
    g.setColor(fill[1], fill[2], fill[3], a)
    g.rectangle("fill", x0, y0, boxW, boxH)
    g.setColor(0, 0, 0, a)
    g.rectangle("line", x0 + 0.5, y0 + 0.5, boxW - 1, boxH - 1)
    if frame then
      g.setColor(frame[1], frame[2], frame[3], a)
      g.rectangle("line", x0 + 1.5, y0 + 1.5, boxW - 3, boxH - 3)
    end
    if f.heal then drawPlus(x0 + PADX, y0 + 2, frame or { 0, 0, 0 }, a) end
    g.setColor(1, 1, 1, a) -- GB tile digits stay black; alpha still fades
    Font.draw(text, x0 + PADX + plusW, y0 + 1)
    g.pop()

    if PaletteFX and PaletteFX.markTrueColor then
      PaletteFX.markTrueColor(
        math.floor(cx - boxW * scale / 2) - 1,
        math.floor(cy - boxH * scale / 2) - 1,
        math.ceil(boxW * scale) + 2, math.ceil(boxH * scale) + 2)
    end
  end

  ----------------------------------------------------------------------------
  -- Overlay hook: watch each bar move up/down, spawn + draw numbers
  ----------------------------------------------------------------------------
  mod.hooks:wrap("battle.overlay", function(next, battle)
    local result = next()
    if not battle then return result end
    if battle ~= curBattle then resetFor(battle) end

    local t0 = now()
    local passive = optionValue(battle.game, "passive") == "on"
    local heals = optionValue(battle.game, "heals") == "on"
    local sides = { foe = battle.enemy, player = battle.player }

    -- Bar movement is bounded by the engine's own b.draining flag, which stays
    -- true across the mid-drain drainHold pauses (stepHPDrain) -- so one drain =
    -- one number, and an intra-drain pause can't be mistaken for a new hit.
    for side, b in pairs(sides) do
      local shown = b and b.shownHP
      if type(shown) == "number" then
        local tr = track[side]
        local drainingNow = b.draining and true or false
        if tr.mon ~= (b and b.mon) then -- switch: re-baseline, no number
          tr.mon, tr.prevShown, tr.wasDraining, tr.startHP, tr.kind =
            b and b.mon, shown, drainingNow, nil, nil
        elseif drainingNow and not tr.wasDraining then -- DRAIN START
          local startHP = tr.prevShown or shown
          local goal = (b.mon and b.mon.hp) or shown
          tr.startHP, tr.kind = startHP, nil
          if goal < startHP - 0.001 then -- damage
            local rp = residualPending[side]
            if #rp > 0 then
              if passive then
                for i, r in ipairs(rp) do
                  spawn(side, r.amount, r.style, t0, false, (i - 1) * (BOXH + 1))
                end
              end
              residualPending[side] = {}
            else
              local rec = table.remove(queue[side], 1)
              if rec then
                if rec.cause == "move" or passive then
                  spawn(side, rec.amount, styleForRecord(rec, t0), t0)
                end
              else
                tr.kind = "measure-dmg" -- unknown source: measure at drain end
              end
            end
          elseif goal > startHP + 0.001 then -- heal
            tr.kind = "measure-heal"
          end
          tr.wasDraining = true
        elseif (not drainingNow) and tr.wasDraining then -- DRAIN END
          if tr.kind == "measure-dmg" and passive then
            local amt = math.floor((tr.startHP or shown) - shown + 0.5)
            if amt > 0 then spawn(side, amt, styleForResidual(b), t0) end
          elseif tr.kind == "measure-heal" and heals then
            local amt = math.floor(shown - (tr.startHP or shown) + 0.5)
            if amt > 0 then spawn(side, amt, STYLE.heal, t0, true) end
          end
          tr.kind, tr.startHP, tr.wasDraining = nil, nil, false
        end
        tr.prevShown = shown
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
    mod.log:info("Damage Numbers v0.4.0 loaded")
  end
end
