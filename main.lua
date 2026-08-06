-- Damage Numbers
-- ---------------------------------------------------------------------------
-- Shows RPG-style floating damage numbers above the Pokemon that just got hit.
--
-- How it works (see the gen1recomp engine source):
--   * The engine fires  battle.damage_dealt  right after a move connects, with
--     the *actual* HP removed (already capped at the target's remaining HP).
--     We just listen for it -- no need to diff HP frame by frame.
--   * We draw through the official  battle.overlay  hook, which runs at the end
--     of the battle draw in native Game Boy pixels (160x144). markTrueColor
--     keeps our colors from being re-quantized by the palette pass.
--
-- Everything you'd normally want to tweak is a named constant below.
-- ---------------------------------------------------------------------------

return function(mod)
  -- PaletteFX lets colored pixels survive the palette post-process. Optional:
  -- if it's unavailable the numbers still draw, just palette-mapped.
  local ok_pfx, PaletteFX = pcall(require, "src.render.PaletteFX")
  if not ok_pfx then PaletteFX = nil end

  ----------------------------------------------------------------------------
  -- Options (appear under this mod's OPTIONS in the mod manager)
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
      key = "crit_color",
      label = "CRIT COLOR",
      type = "choice",
      default = "gold",
      choices = { { "GOLD", "gold" }, { "WHITE", "white" } },
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
  -- 3x5 pixel digit font
  ----------------------------------------------------------------------------
  local GLYPHS = {
    ["0"] = { "111", "101", "101", "101", "111" },
    ["1"] = { "010", "110", "010", "010", "111" },
    ["2"] = { "111", "001", "111", "100", "111" },
    ["3"] = { "111", "001", "111", "001", "111" },
    ["4"] = { "101", "101", "111", "001", "001" },
    ["5"] = { "111", "100", "111", "001", "111" },
    ["6"] = { "111", "100", "111", "101", "111" },
    ["7"] = { "111", "001", "010", "010", "010" },
    ["8"] = { "111", "101", "111", "101", "111" },
    ["9"] = { "111", "101", "111", "001", "111" },
  }
  local GLYPH_W, GLYPH_H, ADVANCE = 3, 5, 4 -- 3px wide + 1px gap = 4px per digit

  ----------------------------------------------------------------------------
  -- Animation / layout knobs -- tweak these freely
  ----------------------------------------------------------------------------
  local LIFE = 50 -- frames a number stays on screen
  local FADE = 16 -- frames of fade-out at the end
  local RISE = 14 -- pixels it floats upward over its life
  local ANCHOR = {
    -- Enemy front sprite sits in the 7x7 slot at hlcoord 12,0 (x=96..152).
    foe = { x = 120, y = 34 },
    -- Player back sprite: x=8, feet at y=96, drawn 2x.
    player = { x = 44, y = 66 },
  }
  local CRIT_COLOR = { 1.00, 0.82, 0.20 } -- gold

  ----------------------------------------------------------------------------
  -- Active numbers + a little spread so multi-hit moves don't stack exactly
  ----------------------------------------------------------------------------
  local active = {} -- { amount, isPlayer, crit, born, battle, dx }
  local spread = { foe = 0, player = 0 }
  local lastSpreadFrame = { foe = -999, player = -999 }

  mod.events:on("battle.damage_dealt", function(e)
    if not e or not e.target or type(e.damage) ~= "number" then return end
    if e.damage <= 0 then return end
    local side = e.target.isPlayer and "player" or "foe"
    local frame = (e.battle and e.battle.frame) or 0
    -- reset the spread counter once a burst of same-side hits is over
    if frame - lastSpreadFrame[side] > 8 then spread[side] = 0 end
    lastSpreadFrame[side] = frame
    local dx = (spread[side] % 3 - 1) * 9 -- -9, 0, +9, repeating
    spread[side] = spread[side] + 1
    active[#active + 1] = {
      amount = math.floor(e.damage + 0.5),
      isPlayer = e.target.isPlayer and true or false,
      crit = e.crit and true or false,
      born = frame,
      battle = e.battle,
      dx = dx,
    }
    if #active > 24 then table.remove(active, 1) end
  end)

  ----------------------------------------------------------------------------
  -- Draw one number: black outline pass, then colored fill pass
  ----------------------------------------------------------------------------
  local function drawNumber(text, cx, cy, r, g, b, a)
    local gfx = love.graphics
    local totalW = #text * ADVANCE - 1
    local ox = math.floor(cx - totalW / 2 + 0.5)
    local oy = math.floor(cy - GLYPH_H / 2 + 0.5)

    -- pass 1: 3x3 black block behind every lit pixel -> clean 1px outline
    gfx.setColor(0, 0, 0, a)
    for i = 1, #text do
      local rows = GLYPHS[text:sub(i, i)]
      if rows then
        local gx = ox + (i - 1) * ADVANCE
        for py = 1, GLYPH_H do
          local row = rows[py]
          for px = 1, GLYPH_W do
            if row:sub(px, px) == "1" then
              gfx.rectangle("fill", gx + px - 2, oy + py - 2, 3, 3)
            end
          end
        end
      end
    end

    -- pass 2: colored 1x1 fill on top
    gfx.setColor(r, g, b, a)
    for i = 1, #text do
      local rows = GLYPHS[text:sub(i, i)]
      if rows then
        local gx = ox + (i - 1) * ADVANCE
        for py = 1, GLYPH_H do
          local row = rows[py]
          for px = 1, GLYPH_W do
            if row:sub(px, px) == "1" then
              gfx.rectangle("fill", gx + px - 1, oy + py - 1, 1, 1)
            end
          end
        end
      end
    end

    if PaletteFX and PaletteFX.markTrueColor then
      PaletteFX.markTrueColor(ox - 1, oy - 1, totalW + 2, GLYPH_H + 2)
    end
  end

  ----------------------------------------------------------------------------
  -- Overlay hook: draw every live number, cull the expired ones
  ----------------------------------------------------------------------------
  mod.hooks:wrap("battle.overlay", function(next, battle)
    local result = next() -- let vanilla + lower-priority overlays draw first
    if not battle then return result end
    if optionValue(battle.game, "enabled") ~= "on" then return result end

    local now = battle.frame or 0
    local critWhite = optionValue(battle.game, "crit_color") == "white"
    local gfx = love.graphics
    gfx.push("all")
    gfx.setShader()

    for i = #active, 1, -1 do
      local n = active[i]
      local age = now - n.born
      if n.battle ~= battle or age < 0 or age >= LIFE then
        table.remove(active, i)
      else
        local t = age / LIFE
        local anchor = n.isPlayer and ANCHOR.player or ANCHOR.foe
        local cx = anchor.x + n.dx
        local cy = anchor.y - RISE * (1 - (1 - t) * (1 - t)) -- ease-out rise
        local a = 1
        if age > LIFE - FADE then a = (LIFE - age) / FADE end
        local r, g, b = 1, 1, 1
        if n.crit and not critWhite then
          r, g, b = CRIT_COLOR[1], CRIT_COLOR[2], CRIT_COLOR[3]
        end
        drawNumber(tostring(n.amount), cx, cy, r, g, b, a)
      end
    end

    gfx.pop()
    return result
  end)

  if mod.log and mod.log.info then
    mod.log:info("Damage Numbers loaded")
  end
end
