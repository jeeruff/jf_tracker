-- jf_tracker_harm.lua — вкладка harmonizer (8 окт), рядом с midi.
--
-- Лад: тоника + мажор / минор (натуральный); auto — по нотам трека курсора.
-- Ступени: трезвучия и септаккорды лада (I ii iii IV V vi vii° / i ii° III
-- iv v VI VII); щелчок или 1..7 — аккорд в строку курсора, Shift (! @ # …)
-- — септаккорд. Анализ: аккорд строки курсора и аккорды трека в паттерне.
--
-- Клавиши (фокус вкладки): 1..7 / ! @ # $ % ^ & — записать; h l — тоника
-- вниз / вверх; m — мажор ↔ минор; a — лад по нотам трека; c — трек одним
-- лейном аккордов (:chord); Esc — в трекер.
--
-- HM.key / HM.click возвращают действие { write = sym } | { lane = true } |
-- 'leave' | true; запись делает main (ctx.chord_cmd). Без reaper.*.

local HM = {}
local U, CH
HM.root = 0
HM.minor = false

local SCALE = { [false] = { 0, 2, 4, 5, 7, 9, 11 }, [true] = { 0, 2, 3, 5, 7, 8, 10 } }
local TRI = { [false] = { '', 'm', 'm', '', '', 'm', 'dim' }, [true] = { 'm', 'dim', '', 'm', 'm', '', '' } }
local SEV = { [false] = { 'maj7', 'm7', 'm7', 'maj7', '7', 'm7', 'm7b5' }, [true] = { 'm7', 'm7b5', 'maj7', 'm7', 'm7', 'maj7', '7' } }
local ROM = { [false] = { 'I', 'ii', 'iii', 'IV', 'V', 'vi', 'vii°' }, [true] = { 'i', 'ii°', 'III', 'iv', 'v', 'VI', 'VII' } }
local SHIFTD = { ['!'] = 1, ['@'] = 2, ['#'] = 3, ['$'] = 4, ['%'] = 5, ['^'] = 6, ['&'] = 7 }

function HM.init(u, ch) U, CH = u, ch end

-- обозначение ступени k (1..7) лада: трезвучие / септаккорд
function HM.degree(k, seventh)
  local pc = (HM.root + SCALE[HM.minor][k]) % 12
  return CH.NAMES[pc + 1] .. (seventh and SEV[HM.minor][k] or TRI[HM.minor][k])
end
function HM.key_name() return CH.NAMES[HM.root + 1] .. (HM.minor and ' minor' or ' major') end

-- лад по высотам нот (счёт по ступеням, тоника — с бонусом): лучший мажор / минор
function HM.detect(pitches)
  local cnt = {}
  for i = 0, 11 do cnt[i] = 0 end
  for _, p in ipairs(pitches or {}) do cnt[p % 12] = cnt[p % 12] + 1 end
  local best, br, bm = -1, 0, false
  for r = 0, 11 do
    for _, mn in ipairs({ false, true }) do
      local s = 0
      for k, iv in ipairs(SCALE[mn]) do s = s + cnt[(r + iv) % 12] * ((k == 1 or k == 5) and 1.3 or 1) end
      if s > best + 1e-9 then best, br, bm = s, r, mn end
    end
  end
  if best <= 0 then return nil end
  return br, bm
end

-- рисунок: info = { col_name, here (аккорд строки курсора), list = { {row, name} … } }
function HM.draw(L, x, y, w, h, focus, info, fit, hint)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hv
  local rh = L.rh
  local function btn(bx, by, bw, lab, on, data, col)
    local hot = mx >= bx and mx < bx + bw and my >= by and my < by + rh
    U.set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(U.CYAN, 0.25) or U.BG)); gfx.rect(bx, by, bw, rh - 1, 1)
    U.set(hot and U.AMBER or (on and U.CYAN or U.LINE)); gfx.rect(bx, by, bw, rh - 1, 0)
    U.text(bx + L.pad, by, fit(lab, bw - 2 * L.pad), hot and U.AMBER or (col or U.TEXT))
    if hot then hv = data end
    if hint then hint('harm', bx, by, bw, rh, data) end
    return bx + bw + 2
  end
  -- строка 1: лад и кнопки
  local cx = x
  U.text(cx, y, 'key', U.GREY); cx = cx + U.measure('key ') + L.pad
  cx = btn(cx, y, U.measure('<') + 2 * L.pad, '<', false, { kind = 'root', d = -1 })
  cx = btn(cx, y, U.measure('C# minor') + 2 * L.pad, HM.key_name(), true, { kind = 'mode' }, U.CYAN)
  cx = btn(cx, y, U.measure('>') + 2 * L.pad, '>', false, { kind = 'root', d = 1 })
  cx = btn(cx, y, U.measure('auto') + 2 * L.pad, 'auto', false, { kind = 'auto' })
  cx = btn(cx, y, U.measure('chord lane') + 2 * L.pad, 'chord lane', info.lane, { kind = 'lane' })
  if info.col_name then U.text(cx + L.pad, y, fit(info.col_name .. (info.here and ('  now: ' .. info.here) or '  now: -'), x + w - cx - L.pad), info.here and U.TEXT or U.GREY) end
  -- строки 2..3: ступени — трезвучия и септаккорды
  local cw = math.max(U.measure('G#m') + 2 * L.pad, math.floor((w - 6 * 2) / 7))   -- 8 окт: узко — все 7, подписи обрезаются (было одна кнопка)
  for row = 0, 1 do
    local by = y + (1 + row) * (rh + 2)
    if by + rh > y + h then break end
    for k = 1, 7 do
      local bx = x + (k - 1) * (cw + 2)
      if bx + cw > x + w then break end
      local sym = HM.degree(k, row == 1)
      local lab = (row == 0 and cw >= U.measure('vii° G#dim') + 2 * L.pad and (ROM[HM.minor][k] .. ' ') or '') .. sym
      btn(bx, by, cw, lab, info.here == sym, { kind = 'deg', k = k, seventh = row == 1 })
    end
  end
  -- анализ: аккорды трека в паттерне
  local ay = y + 3 * (rh + 2) + 2
  if ay + rh <= y + h then
    U.text(x, ay, 'chords', U.GREY)
    local tx = x + U.measure('chords ') + L.pad
    local ty = ay
    for _, e in ipairs(info.list or {}) do
      local s = ('%04d %s'):format(e.row, e.name)
      local sw = U.measure(s) + 2 * L.pad
      if tx + sw > x + w then ty = ty + rh; tx = x + U.measure('chords ') + L.pad; if ty + rh > y + h then break end end
      U.text(tx, ty, s, e.cur and U.AMBER or U.TEXT)
      tx = tx + sw
    end
    if #(info.list or {}) == 0 then U.text(tx, ay, 'no notes on this track in the pattern', U.DIM) end
  end
  return hv
end

-- действие по кнопке
function HM.click(d, pitches)
  if not d then return nil end
  if d.kind == 'root' then HM.root = (HM.root + d.d) % 12; return true
  elseif d.kind == 'mode' then HM.minor = not HM.minor; return true
  elseif d.kind == 'auto' then local r, m = HM.detect(pitches); if r then HM.root, HM.minor = r, m end; return true
  elseif d.kind == 'lane' then return { lane = true }
  elseif d.kind == 'deg' then return { write = HM.degree(d.k, d.seventh) } end
end

function HM.key(c, pitches)
  local ch = c > 0 and c < 256 and string.char(c) or ''
  if c == 27 then return 'leave' end
  local k = tonumber(ch)
  if k and k >= 1 and k <= 7 then return { write = HM.degree(k, false) } end
  if SHIFTD[ch] then return { write = HM.degree(SHIFTD[ch], true) } end
  if ch == 'h' then return HM.click({ kind = 'root', d = -1 }) end
  if ch == 'l' then return HM.click({ kind = 'root', d = 1 }) end
  if ch == 'm' then return HM.click({ kind = 'mode' }) end
  if ch == 'a' then return HM.click({ kind = 'auto' }, pitches) end
  if ch == 'c' then return { lane = true } end
  return nil
end

return HM
