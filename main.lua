-- Damage Numbers
-- ---------------------------------------------------------------------------
-- RPG-style floating damage numbers over the Pokemon that just got hit.
--
-- v0.2.0 design (see the gen1recomp engine source):
--   * VALUE comes from the battle.damage_dealt event (the real HP removed).
--   * TIMING is driven by battler.shownHP -- the HP the bar actually displays
--     as it drains (BattleState makeBattler: "shownHP = the HP the bar
--     displays"). We only pop the number when that bar STARTS draining, which
--     is after the attack animation, not during turn resolution.
--   * The number is drawn in the engine's own Game Boy font (src.render.Font),
--     inside a small white box like the game's UI, and it fades on REAL TIME
--     (love.timer.getTime) so fast-forward (--speed / x4) doesn't blink it away.
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
    {
      key = "enabled",
      label = "DAMAGE NUMBERS",
      type = "choice",
      default = "on",
      choices = { { "ON", "on" }, { "OFF", "off" } },
    },
    {
      key = "size",
      label = "NUMBER SIZE",
      type = "choice",
      default = "2x",
      choices = { { "1X", "1x" }, { "2X", "2x" } },
    },
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
  local LIFE = 0.95 -- seconds a number stays on screen
  local FADE = 0.30 -- seconds of fade-out at the end
  local RISE = 16 -- native px it floats upward over its life
  local STALE = 2.5 -- drop a pending hit if the bar never drains within this
  local PADX = 3 -- box horizontal padding (unscaled px)
  local BOXH = 9 -- box height (8px font + 1)
  local CRIT = { 1.00, 0.82, 0.20 } -- gold accent for crits
  local ANCHOR = {
    foe = { x = 120, y = 34 }, -- enemy front sprite (7x7 slot, hlcoord 12,0)
    player = { x = 44, y = 66 }, -- player back sprite (x=8, feet y=96, 2x)
  }

  ----------------------------------------------------------------------------
  -- State
  ----------------------------------------------------------------------------
  -- pending damage waiting for its bar to start draining
  local pending = {
    foe = { total = 0, crit = false, at = 0 },
    player = { total = 0, crit = false, at = 0 },
  }
  local prevShown = { foe = nil, player = nil }
  local draining = { foe = false, player = false }
  local floats = {} -- { amount, side, crit, born }
  local curBattle = nil

  -- accurate value + crit flag, straight from the engine
  mod.events:on("battle.damage_dealt", function(e)
    if not e or not e.target or type(e.damage) ~= "number" or e.damage <= 0 then
      return
    end
    local side = e.target.isPlayer and "player" or "foe"
    local p = pending[side]
    p.total = p.total + math.floor(e.damage + 0.5)
    p.crit = p.crit or (e.crit and true or false)
    p.at = now()
  end)

  local function resetFor(battle)
    curBattle = battle
    prevShown.foe, prevShown.player = nil, nil
    draining.foe, draining.player = false, false
    pending.foe.total, pending.foe.crit = 0, false
    pending.player.total, pending.player.crit = 0, false
    floats = {}
  end

  ----------------------------------------------------------------------------
  -- Draw one number: white box + black GB-font digits, gold frame on crits
  ----------------------------------------------------------------------------
  local function drawFloat(f, scale, t0)
    if not Font then return end
    local text = tostring(f.amount)
    local tw = Font.width(text)
    local boxW = tw + PADX * 2
    local boxH = BOXH

    local age = t0 - f.born
    local t = age / LIFE
    local anchor = f.side == "player" and ANCHOR.player or ANCHOR.foe
    local cx = anchor.x
    local cy = anchor.y - RISE * (1 - (1 - t) * (1 - t)) -- ease-out rise
    local a = 1
    if age > LIFE - FADE then a = math.max(0, (LIFE - age) / FADE) end

    local gfx = love.graphics
    gfx.push("all")
    gfx.setShader()
    gfx.translate(cx, cy)
    gfx.scale(scale, scale)

    local x0 = math.floor(-boxW / 2)
    local y0 = math.floor(-boxH / 2)
    -- white box like the game's text UI
    gfx.setColor(1, 1, 1, a)
    gfx.rectangle("fill", x0, y0, boxW, boxH)
    -- black 1px frame
    gfx.setColor(0, 0, 0, a)
    gfx.rectangle("line", x0 + 0.5, y0 + 0.5, boxW - 1, boxH - 1)
    -- crit: gold inner frame
    if f.crit then
      gfx.setColor(CRIT[1], CRIT[2], CRIT[3], a)
      gfx.rectangle("line", x0 + 1.5, y0 + 1.5, boxW - 3, boxH - 3)
    end
    -- digits: engine GB font renders black; alpha still fades it
    gfx.setColor(1, 1, 1, a)
    Font.draw(text, x0 + PADX, y0 + 1)
    gfx.pop()

    -- keep the box crisp through the palette pass (native coords, post-scale)
    if PaletteFX and PaletteFX.markTrueColor then
      PaletteFX.markTrueColor(
        math.floor(cx - boxW * scale / 2) - 1,
        math.floor(cy - boxH * scale / 2) - 1,
        math.ceil(boxW * scale) + 2,
        math.ceil(boxH * scale) + 2)
    end
  end

  ----------------------------------------------------------------------------
  -- Overlay hook: track the bar drain, spawn + draw numbers
  ----------------------------------------------------------------------------
  mod.hooks:wrap("battle.overlay", function(next, battle)
    local result = next()
    if not battle then return result end
    if battle ~= curBattle then resetFor(battle) end

    local t0 = now()
    local sides = { foe = battle.enemy, player = battle.player }

    -- spawn a number the frame a battler's displayed HP starts falling
    for side, b in pairs(sides) do
      local shown = b and b.shownHP
      if type(shown) == "number" then
        local prev = prevShown[side]
        if prev and shown < prev - 0.001 then
          if not draining[side] then
            local p = pending[side]
            if p.total > 0 then
              floats[#floats + 1] =
                { amount = p.total, side = side, crit = p.crit, born = t0 }
              p.total, p.crit = 0, false
            end
          end
          draining[side] = true
        else
          draining[side] = false
        end
        prevShown[side] = shown
      end
    end

    -- forget a hit whose bar never drained (e.g. fully absorbed by a sub)
    for _, side in ipairs({ "foe", "player" }) do
      local p = pending[side]
      if p.total > 0 and t0 - p.at > STALE then p.total, p.crit = 0, false end
    end

    -- draw
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
    mod.log:info("Damage Numbers v0.2.0 loaded")
  end
end
