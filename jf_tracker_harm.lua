-- jf_tracker_harm.lua — вкладка harmonizer (8 окт), рядом с midi.
--
-- Лад: тоника + мажор / минор (натуральный); auto — по нотам трека курсора.
-- Ступени: трезвучия и септаккорды лада (I ii iii IV V vi vii° / i ii° III
-- iv v VI VII); щелчок или 1..7 — аккорд в строку курсора, Shift (! @ # …)
-- — септаккорд. Анализ: аккорд строки курсора и аккорды трека в паттерне.
--
-- Клавиши (фокус вкладки): 1..7 / ! @ # $ % ^ & — записать; h l — тоника
-- вниз / вверх; m — мажор ↔ минор; a — лад по нотам трека; c — трек одним
-- лейном аккордов (:chord); s — нотный стан, t — гитарный таб; j — just (натуральный строй
-- микротонами 72-EDO, 16 окт); Esc — в трекер.
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

-- 16 окт: натуральный строй (just intonation, 5- и 7-limit) — аккорд пишется микротонами 72-EDO
-- (ступень 1/6 тона = 16.7 цента): интервал от корня аккорда → чистое отношение → поправка в ступенях.
-- Терция 5/4 = 386 ц (−1), малая 6/5 = 316 ц (+1), септима 7/4 = 969 ц (−2) у доминантового 7,
-- 9/5 = 1018 ц (+1) у минорного; j во вкладке — вкл / выкл
HM.ji = false
HM.JI_RATIO = { [0] = 1, 16 / 15, 9 / 8, 6 / 5, 5 / 4, 4 / 3, 45 / 32, 3 / 2, 8 / 5, 5 / 3, 7 / 4, 15 / 8 }
function HM.ji_step(semis, minor7)
  local iv = semis % 12
  local r = HM.JI_RATIO[iv]
  if iv == 10 and minor7 then r = 9 / 5 end
  local cents = 1200 * math.log(r, 2)
  return math.floor((cents - iv * 100) / (100 / 6) + 0.5)
end
-- ступени для нот аккорда sym: { [pitch] = m } (корень и чистая квинта — 0, без записи)
function HM.ji_micro(sym, pitches)
  local c = CH and CH.parse(sym)
  if not c then return {} end
  local m7 = c.suffix and c.suffix:match('^m') ~= nil and not c.suffix:match('^maj')
  local out = {}
  for _, p in ipairs(pitches or {}) do
    local st = HM.ji_step(p - c.root, m7)
    if st ~= 0 then out[p] = st end
  end
  return out
end

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

-- нотный стан (9 окт): скрипичный ключ, ноты аккорда столбиком (секунды —
-- сдвиг вправо), диезы буквой #, добавочные линии. Возвращает ширину
function HM.staff(L, x, y, h, sym)
  local ps = CH.voicing(sym, 4)
  if not ps then return 0 end
  local st = {}
  local lo, hi = 30, 38
  for i, p in ipairs(ps) do
    local s, acc = CH.staff_step(p)
    st[i] = { s = s, acc = acc }
    lo, hi = math.min(lo, s), math.max(hi, s)
  end
  -- полшага — по высоте панели (стан крупный), но не больше строки
  local hs = math.max(3, math.min(L.rh, math.floor(h / (hi - lo + 3))))
  table.sort(st, function(a, b) return a.s < b.s end)
  local yb = y + hs + (hi - 30) * hs                       -- нижняя линия (E4)
  if yb + (30 - lo) * hs + hs > y + h then yb = y + h - hs - (30 - lo) * hs end
  local function sy(s) return yb - (s - 30) * hs end
  local aw = U.measure('#')
  local cw = U.measure('G')
  local nx = x + cw + 2 * aw + 6                            -- столбец нот
  local r = math.max(2, hs - 1)                            -- головка чуть меньше промежутка: терции не слипаются
  local w = nx - x + 4 * r + 6
  U.set(U.GREY)
  for k = 0, 4 do gfx.rect(x, sy(30 + 2 * k), w, 1, 1) end
  U.text(x, sy(32) - math.floor(L.th / 2), 'G', U.DIM)       -- ключ соль — буквой (на линии G4)
  local prev, shifted, accn = nil, false, 0
  for _, e in ipairs(st) do
    local dx = 0
    if prev and e.s == prev + 1 and not shifted then dx = 2 * r + 1; shifted = true else shifted = false end
    local cx, cy = nx + r + dx, sy(e.s)
    -- добавочные линии
    U.set(U.GREY)
    for ls = 28, e.s, -2 do gfx.rect(cx - r - 2, sy(ls), 2 * r + 5, 1, 1) end
    for ls = 40, e.s, 2 do gfx.rect(cx - r - 2, sy(ls), 2 * r + 5, 1, 1) end
    U.set(U.TEXT); gfx.circle(cx, cy, r, 1, 0)
    if e.acc then
      accn = accn + 1
      U.text(nx - aw - 2 - ((accn % 2 == 0) and aw + 1 or 0), cy - math.floor(L.th / 2), '#', U.TEXT)
    end
    prev = e.s
  end
  return w
end

-- гитарный таб (9 окт): шесть строк e B G D A E, лад на линии (x — не играть)
function HM.tab(L, x, y, sym)
  local g = CH.guitar(sym)
  if not g then return 0 end
  local NM = { 'E', 'A', 'D', 'G', 'B', 'e' }
  local lw = U.measure('e ')
  local fw = U.measure('10')
  local w = lw + fw + 4 * L.pad
  for k = 6, 1, -1 do
    local ry = y + (6 - k) * L.rh
    local f = g[k]
    U.text(x, ry, NM[k], U.GREY)
    U.set(U.DIM); gfx.rect(x + lw, ry + math.floor(L.rh / 2), w - lw, 1, 1)
    local t = f < 0 and 'x' or tostring(f)
    local tx = x + lw + 2 * L.pad + math.floor((fw - U.measure(t)) / 2)
    U.set(U.BG); gfx.rect(tx - 1, ry + 1, U.measure(t) + 2, L.rh - 2, 1)
    U.text(tx, ry, t, f < 0 and U.DIM or U.TEXT)
  end
  return w
end

-- рисунок: info = { col_name, here (аккорд строки курсора), list = { {row, name} … } }
-- 9 окт: кнопки — по ширине подписи, плотной группой слева (раньше тянулись
-- на всю ширину — далеко водить мышь); справа — стан и таб аккорда под
-- мышью (наведена кнопка) или строки курсора
HM.show_staff, HM.show_tab = true, true
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
  local function bw_of(s) return U.measure(s) + 2 * L.pad end
  -- строка 1: лад, затем вид (staff / tab), затем трек и аккорд строки
  local cx = x
  U.text(cx, y, 'key', U.GREY); cx = cx + U.measure('key ') + L.pad
  cx = btn(cx, y, bw_of('<'), '<', false, { kind = 'root', d = -1 })
  cx = btn(cx, y, bw_of('C# minor'), HM.key_name(), true, { kind = 'mode' }, U.CYAN)
  cx = btn(cx, y, bw_of('>'), '>', false, { kind = 'root', d = 1 })
  cx = btn(cx, y, bw_of('auto'), 'auto', false, { kind = 'auto' })
  cx = btn(cx, y, bw_of('chord lane'), 'chord lane', info.lane, { kind = 'lane' }) + L.cw
  cx = btn(cx, y, bw_of('staff'), 'staff', HM.show_staff, { kind = 'staff' })
  cx = btn(cx, y, bw_of('tab'), 'tab', HM.show_tab, { kind = 'tab' })
  cx = btn(cx, y, bw_of('just'), 'just', HM.ji, { kind = 'ji' })   -- 16 окт: натуральный строй микротонами (j)
  -- 21 окт: лад в трекере — ноты вне лада красноватые (o), набор в ладу (i)
  cx = btn(cx, y, bw_of('out'), 'out', info.keymark, { kind = 'kmark' })
  cx = btn(cx, y, bw_of('in key'), 'in key', info.keysnap, { kind = 'ksnap' })
  if info.col_name then U.text(cx + L.pad, y, fit(info.col_name .. (info.here and ('  now: ' .. info.here) or '  now: -'), x + w - cx - L.pad), info.here and U.TEXT or U.GREY) end
  -- строки 2..3: ступени — одна ширина на все (по самой длинной подписи)
  local roman = true
  local cw = bw_of('vii° G#dim')
  if 7 * (cw + 2) > w * 0.6 then roman = false; cw = bw_of('C#mMaj7') end
  if 7 * (cw + 2) > w then cw = math.max(bw_of('G#m'), math.floor((w - 12) / 7)) end
  local gx1 = x + 7 * (cw + 2)
  for row = 0, 1 do
    local by = y + (1 + row) * (rh + 2)
    if by + rh > y + h then break end
    for k = 1, 7 do
      local sym = HM.degree(k, row == 1)
      local lab = (row == 0 and roman and (ROM[HM.minor][k] .. ' ') or '') .. sym
      btn(x + (k - 1) * (cw + 2), by, cw, lab, info.here == sym, { kind = 'deg', k = k, seventh = row == 1 })
    end
  end
  -- аккорды трека в паттерне — под кнопками, в ширину их группы
  local ay = y + 3 * (rh + 2) + 2
  local ty = ay
  if ay + rh <= y + h then
    U.text(x, ay, 'chords', U.GREY)
    local tx0 = x + U.measure('chords ') + L.pad
    local tx = tx0
    for _, e in ipairs(info.list or {}) do
      local s = ('%04d %s'):format(e.row, e.name)
      local sw = U.measure(s) + 2 * L.pad
      if tx + sw > gx1 then ty = ty + rh; tx = tx0; if ty + rh > y + h then break end end
      U.text(tx, ty, s, e.cur and U.AMBER or U.TEXT)
      tx = tx + sw
    end
    if #(info.list or {}) == 0 then U.text(tx, ay, fit('no notes on this track in the pattern', gx1 - tx), U.DIM) end
  end
  -- справа: стан и таб
  local show = (hv and hv.kind == 'deg') and HM.degree(hv.k, hv.seventh) or info.here
  local px = gx1 + 2 * L.cw
  local py = y + rh + 2
  -- 26 окт: справа не влезает (узкая панель) — стан и таб под списком аккордов, во всю ширину
  if px + 10 * L.cw > x + w then px, py = x, ty + rh + 4 end
  if (HM.show_staff or HM.show_tab) and px + 10 * L.cw <= x + w and py + 3 * rh <= y + h then
    if show and CH.parse((show:gsub('%?$', ''))) then
      U.text(px, py, show, (hv and hv.kind == 'deg') and U.AMBER or U.TEXT)
      local qx = px
      local ph = y + h - py - rh
      if HM.show_staff then qx = qx + HM.staff(L, qx, py + rh, ph, show) + 2 * L.cw end
      if HM.show_tab and qx + U.measure('e 10') + 4 * L.pad <= x + w and 6 * rh <= y + h - py - rh then HM.tab(L, qx, py + rh, show) end
    else
      U.text(px, py, fit('hover a chord, or put the cursor on one', x + w - px), U.DIM)
    end
  end
  return hv
end

-- действие по кнопке
function HM.click(d, pitches)
  if not d then return nil end
  if d.kind == 'root' then HM.root = (HM.root + d.d) % 12; return true
  elseif d.kind == 'mode' then HM.minor = not HM.minor; return true
  elseif d.kind == 'auto' then return { keyauto = true }   -- 21 окт: лад песни по всем трекам (:key), все лады
  elseif d.kind == 'kmark' then return { key = 'mark' }
  elseif d.kind == 'ksnap' then return { key = 'snap' }
  elseif d.kind == 'lane' then return { lane = true }
  elseif d.kind == 'staff' then HM.show_staff = not HM.show_staff; return true
  elseif d.kind == 'tab' then HM.show_tab = not HM.show_tab; return true
  elseif d.kind == 'ji' then HM.ji = not HM.ji; return true
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
  if ch == 's' then return HM.click({ kind = 'staff' }) end
  if ch == 't' then return HM.click({ kind = 'tab' }) end
  if ch == 'j' then return HM.click({ kind = 'ji' }) end
  if ch == 'o' then return HM.click({ kind = 'kmark' }) end
  if ch == 'i' then return HM.click({ kind = 'ksnap' }) end
  return nil
end

return HM
