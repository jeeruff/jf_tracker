-- jf_tracker_mixer.lua — простой микшер (7 окт): полоса на трек шириной его
-- колонки трекера (тот же масштаб). Сверху — инсерты эффектов (клик —
-- выбрать в DSP, двойной клик — окно, «+ fx» — добавить, бросок эффекта из
-- списка — сюда), ниже — панорама, фейдер с метром, M S R.
-- Живёт под клипами в виде session и один вместо тела трекера (Shift+Tab).
-- Всё, что можно нажать, — цели прыжков f (ctx.hint).
--
-- Клавиши (фокус mixer): h l — трек, j k — громкость −/+ 0.5 дБ (J K — 3 дБ),
-- H L — панорама, m s r — mute / solo / arm, Enter / o — окно первого эффекта,
-- + — добавить эффект (fzf), 0 — 0 дБ, Esc / Shift+Tab — назад.
--
-- Без reaper.* в рисовании: значения — через ctx.mix_* (main).

local MIX = {}
local U, ctx

MIX.ci = 1            -- трек курсора микшера

function MIX.init(u, c) U, ctx = u, c end

-- −60..+12 дБ ↔ 0..1 (как кольцо arc на странице clips)
function MIX.db_to_fr(db) return math.max(0, math.min(1, (db + 60) / 72)) end
function MIX.fr_to_db(fr) return math.max(-60, math.min(12, fr * 72 - 60)) end

-- раскладка полосы (чистая): сколько строк инсертов влезает при высоте h
function MIX.layout(h, rh)
  local bottom = rh + 2                   -- M S R
  local pan = rh + 2
  local fader_min = 4 * rh
  local slots = math.max(1, math.min(8, math.floor((h - bottom - pan - fader_min - 4) / rh)))
  return { slots = slots, ins_h = slots * rh, pan_h = pan, bot_h = bottom,
           fader_h = h - slots * rh - pan - bottom - 4 }
end

function MIX.draw(L, x0, y, h, cols, focused)
  local hover = { mixer = true }
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local lay = MIX.layout(h, L.rh)
  local last = cols[#cols]
  local right = last and last.x and (last.x + last.w) or x0
  U.set(U.BG); gfx.rect(x0, y, right - x0, h, 1)
  U.set(U.LINE); gfx.rect(x0, y, right - x0, 1, 1)
  for _, c in ipairs(cols) do
    if c.x and c.col then
      local ci = c.ci
      local sx, sw = c.x + 2, c.w - 4
      local cur = focused and ci == MIX.ci
      local rgb = c.col.rgb
      if cur then U.set(U.tint(U.AMBER, 0.10)); gfx.rect(c.x, y + 1, c.w, h - 1, 1) end
      U.set(U.LINE); gfx.rect(c.x, y, 1, h, 1)
      -- инсерты
      local fxs = ctx.mix_fx and ctx.mix_fx(ci) or {}
      local yy = y + 2
      for k = 1, lay.slots do
        local f = fxs[k]
        local hot = mx >= sx and mx < sx + sw and my >= yy and my < yy + L.rh
        if f then
          U.set(hot and U.tint(U.AMBER, 0.25) or U.PANEL); gfx.rect(sx, yy, sw, L.rh - 1, 1)
          if rgb then U.set(rgb); gfx.rect(sx, yy, 2, L.rh - 1, 1) end
          U.text(sx + 4, yy, ctx.fit(f.name, sw - 6), f.enabled and (hot and U.AMBER or U.TEXT) or U.GREY)
          if hot then hover.mixfx = { ci = ci, k = k, f = f } end
          if ctx.hint then ctx.hint('mixfx', sx, yy, sw, L.rh - 1, { ci = ci, k = k }) end
        elseif k == #fxs + 1 then
          U.set(hot and U.tint(U.AMBER, 0.25) or U.BG); gfx.rect(sx, yy, sw, L.rh - 1, 1)
          U.set(U.LINE); gfx.rect(sx, yy, sw, L.rh - 1, 0)
          U.text(sx + 4, yy, ctx.fit('+ fx', sw - 6), hot and U.AMBER or U.GREY)
          if hot then hover.mixadd = { ci = ci } end
          if ctx.hint then ctx.hint('mixadd', sx, yy, sw, L.rh - 1, { ci = ci }) end
        end
        if hot then hover.mixslot = { ci = ci, k = k } end
        yy = yy + L.rh
      end
      if #fxs > lay.slots then U.text(sx + sw - U.measure('+9'), y + 2 + (lay.slots - 1) * L.rh, '+' .. (#fxs - lay.slots + 1), U.CYAN) end
      -- панорама
      local py = y + 2 + lay.ins_h + 1
      local pan = ctx.mix_pan and ctx.mix_pan(ci) or 0
      local hotp = mx >= sx and mx < sx + sw and my >= py and my < py + L.rh
      U.set(U.DIM or U.LINE); gfx.rect(sx, py + math.floor(L.rh / 2), sw, 1, 1)
      local cxp = sx + math.floor(sw / 2)
      local px = sx + math.floor((pan + 1) / 2 * (sw - 1))
      U.set(hotp and U.AMBER or U.CYAN); gfx.rect(math.min(cxp, px), py + 3, math.max(1, math.abs(px - cxp)), L.rh - 6, 1); gfx.rect(px, py + 1, 1, L.rh - 2, 1)
      if hotp then hover.mixpan = { ci = ci, x = sx, w = sw } end
      if ctx.hint then ctx.hint('mixpan', sx, py, sw, L.rh, { ci = ci }) end
      -- фейдер и метр
      local fy, fh = py + lay.pan_h, lay.fader_h
      local db = ctx.mix_vol and ctx.mix_vol(ci) or 0
      local fr = MIX.db_to_fr(db)
      local mtr = ctx.ss_meter and ctx.ss_meter(ci) or 0
      local mw = math.max(3, math.floor(sw / 6))
      local tx = sx + math.floor((sw - mw) / 2) - 4
      local hotf = mx >= sx and mx < sx + sw and my >= fy and my < fy + fh
      U.set(U.LINE); gfx.rect(tx, fy + L.rh, 2, fh - L.rh - 2, 1)                     -- дорожка фейдера
      local uy = fy + L.rh + math.floor((1 - MIX.db_to_fr(0)) * (fh - L.rh - 2))
      U.set(U.GREY); gfx.rect(tx - 3, uy, 8, 1, 1)                                   -- 0 дБ
      local ty = fy + L.rh + math.floor((1 - fr) * (fh - L.rh - 2))
      U.set((hotf or MIX.drag and MIX.drag.ci == ci) and U.AMBER or U.TEXT); gfx.rect(tx - 4, ty - 2, 10, 4, 1)
      -- метр рядом с фейдером
      local mxx = tx + 10
      local mh = fh - L.rh - 2
      U.set(U.PANEL); gfx.rect(mxx, fy + L.rh, mw, mh, 1)
      if mtr > 0 then
        local hh = math.floor(mtr * mh)
        U.set(mtr >= 0.99 and U.RED or (mtr > 0.85 and U.AMBER or U.GREEN)); gfx.rect(mxx, fy + L.rh + mh - hh, mw, hh, 1)
      end
      U.text(sx, fy, ctx.fit(db <= -59.9 and '-inf' or ('%+.1f'):format(db), sw), hotf and U.AMBER or U.GREY)
      if hotf then hover.mixvol = { ci = ci, y = fy + L.rh, h = fh - L.rh - 2 } end
      if ctx.hint then ctx.hint('mixvol', sx, fy, sw, fh, { ci = ci }) end
      -- M S R
      local by = y + h - lay.bot_h
      local st = ctx.mix_state and ctx.mix_state(ci) or {}
      local bw = math.max(1, math.floor((sw - 2) / 3))
      for i, b in ipairs({ { 'M', 'mute', st.mute, U.AMBER }, { 'S', 'solo', st.solo, U.GREEN }, { 'R', 'arm', st.arm, U.RED } }) do
        local bx = sx + (i - 1) * (bw + 1)
        local hotb = mx >= bx and mx < bx + bw and my >= by and my < by + L.rh
        U.set(b[3] and U.tint(b[4], 0.45) or (hotb and U.tint(U.AMBER, 0.25) or U.BG)); gfx.rect(bx, by, bw, L.rh, 1)
        U.set(b[3] and b[4] or U.LINE); gfx.rect(bx, by, bw, L.rh, 0)
        U.text(bx + math.floor((bw - U.measure(b[1])) / 2), by, b[1], b[3] and b[4] or (hotb and U.AMBER or U.GREY))
        if hotb then hover.mixbtn = { ci = ci, what = b[2] } end
        if ctx.hint then ctx.hint('mixbtn', bx, by, bw, L.rh, { ci = ci, what = b[2] }) end
      end
    end
  end
  if focused then U.set(U.AMBER); gfx.rect(x0, y, right - x0, h, 0) end
  return hover
end

-- клавиши (true — съедена)
function MIX.key(c, ncols, mods)
  local ch = c < 256 and string.char(c) or ''
  if ch == 'h' then MIX.ci = math.max(1, MIX.ci - 1)
  elseif ch == 'l' then MIX.ci = math.min(math.max(1, ncols), MIX.ci + 1)
  elseif ch == 'j' then ctx.mix_vol_add(MIX.ci, -0.5)
  elseif ch == 'k' then ctx.mix_vol_add(MIX.ci, 0.5)
  elseif ch == 'J' then ctx.mix_vol_add(MIX.ci, -3)
  elseif ch == 'K' then ctx.mix_vol_add(MIX.ci, 3)
  elseif ch == 'H' then ctx.mix_pan_add(MIX.ci, -0.05)
  elseif ch == 'L' then ctx.mix_pan_add(MIX.ci, 0.05)
  elseif ch == '0' then ctx.mix_vol_set(MIX.ci, 0)
  elseif ch == 'm' then ctx.mix_toggle(MIX.ci, 'mute')
  elseif ch == 's' then ctx.mix_toggle(MIX.ci, 'solo')
  elseif ch == 'r' then ctx.mix_toggle(MIX.ci, 'arm')
  elseif ch == '+' then ctx.mix_add_fx(MIX.ci)
  elseif c == 13 or ch == 'o' then ctx.mix_open_fx(MIX.ci, 1)
  else return false end
  return true
end

return MIX
