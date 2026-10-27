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
-- 26 окт: написание по ладу — в бемольных ладах (F Bb Eb Ab Db Gb мажор и их параллельные миноры) D# → Eb
local FLAT = { 'C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B' }
function HM.flats()
  local tonic = HM.minor and (HM.root + 3) % 12 or HM.root
  return ({ [5] = true, [10] = true, [3] = true, [8] = true, [1] = true, [6] = true })[tonic] or false
end
function HM.pc_name(pc) return (HM.flats() and FLAT or CH.NAMES)[pc % 12 + 1] end
-- имя аккорда (C#m7, A#/G …) — корень и бас по ладу
function HM.spell(name)
  if not (name and HM.flats()) then return name end
  local SH = { ['C#'] = 'Db', ['D#'] = 'Eb', ['F#'] = 'Gb', ['G#'] = 'Ab', ['A#'] = 'Bb' }
  name = name:gsub('^(%u#)', function(r) return SH[r] or r end)
  return (name:gsub('/(%u#)', function(r) return '/' .. (SH[r] or r) end))
end
function HM.degree(k, seventh)
  local pc = (HM.root + SCALE[HM.minor][k]) % 12
  return HM.pc_name(pc) .. (seventh and SEV[HM.minor][k] or TRI[HM.minor][k])
end
function HM.key_name() return HM.pc_name(HM.root) .. (HM.minor and ' minor' or ' major') end

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
-- 26 окт: НОТНЫЙ СТАН ПО-НАСТОЯЩЕМУ — глифы SMuFL из Reavura (Bravura внутри REAPER.app):
-- скрипичный ключ всегда, низкая одиночная нота — басовый, аккорд — два стана со скобкой;
-- головки noteheadBlack, общий штиль на стан, добавочные линии, ♯ ♭ глифами.
-- Где глиф встаёт по высоте, меряется один раз на размер: рисунок в скрытый буфер, верхний
-- пиксель + высота над базовой линией из рамок SMuFL (staff spaces) → смещение базовой линии.
local SM = { g = utf8.char(0xE050), f = utf8.char(0xE062), head = utf8.char(0xE0A4), sharp = utf8.char(0xE262), flat = utf8.char(0xE260) }
local SM_TOP = { g = 4.392, f = 1.048, head = 0.5, sharp = 1.4, flat = 1.756 }   -- bBoxNE.y, staff spaces
local SM_CACHE = {}
local SM_FONT, SM_IMG = 12, 86   -- шрифт 12, картинка 86 — свободны (0..9 шрифты трекера; картинки — список в jf_tracker_draw.lua:140)
-- замер одного глифа: верх и низ рисунка от точки gfx.y (пиксели), в скрытой картинке
local function scan(g, fsz, want_bot)
  local W, H = math.ceil(fsz * 1.2) + 8, math.ceil(fsz * 1.6) + 8
  gfx.setimgdim(SM_IMG, -1, -1); gfx.setimgdim(SM_IMG, W, H)
  gfx.dest = SM_IMG
  gfx.set(0, 0, 0, 1); gfx.rect(0, 0, W, H, 1)
  gfx.set(1, 1, 1, 1); gfx.x, gfx.y = 0, 0; gfx.drawstr(g)
  -- gfx.getpixel() читает точку gfx.x, gfx.y (не аргументы)
  local function row_hit(yy)
    for xx = 0, W - 1, 2 do gfx.x, gfx.y = xx, yy; if gfx.getpixel() > 0.4 then return true end end
    return false
  end
  local top, bot
  for yy = 0, H - 1 do if row_hit(yy) then top = yy; break end end
  if want_bot and top then for yy = H - 1, top, -1 do if row_hit(yy) then bot = yy; break end end end
  return top, bot
end
-- метрики под промежуток стана sp: размер шрифта подбирается так, чтобы головка была ровно sp
-- (размер gfx.setfont — высота строки шрифта, а не кегль em; у Bravura строка намного выше em)
local function smufl_metrics(sp)
  local c = SM_CACHE[sp]
  if c ~= nil then return c end
  local pd = gfx.dest
  local fi = gfx.getfont and gfx.getfont() or 0
  c = false
  local f0 = 16 * sp
  gfx.setfont(SM_FONT, 'Reavura', f0)
  local gw = gfx.measurestr(SM.g)
  if gw and gw > 0 then
    local t0, b0 = scan(SM.head, f0, true)
    if t0 and b0 and b0 > t0 then
      local fsz = math.max(4, math.floor(f0 * sp / (b0 - t0 + 1) + 0.5))
      gfx.setfont(SM_FONT, 'Reavura', fsz)
      c = { w = {}, fsz = fsz }
      for k, g in pairs(SM) do
        local t = scan(g, fsz)
        c[k] = t or 0
        c.w[k] = gfx.measurestr(g)
      end
    end
  end
  gfx.dest = pd
  gfx.setfont(fi)
  SM_CACHE[sp] = c
  return c
end

function HM.staff(L, x, y, h, sym)
  local ps = CH.voicing(sym, 4)
  if not ps then return 0 end
  local notes = {}
  -- 26 окт: знаки по ладу — в ладах с бемолями (F Bb Eb Ab Db Gb мажор, d g c f bb eb минор) D# пишется Eb
  local flats = HM.flats()
  for _, p in ipairs(ps) do
    local s0, acc = CH.staff_step(p)
    if acc and flats then s0, acc = s0 + 1, 'b' end                   -- D# → E♭ (ступень выше, бемоль)
    notes[#notes + 1] = { s = s0, acc = acc }
  end
  table.sort(notes, function(a, b) return a.s < b.s end)
  -- станы: скрипичный — линии 30..38 (E4..F5), басовый — 18..26 (G2..A3); до первой октавы — 28
  local both = #notes > 1
  local use_t = both or notes[1].s >= 28
  local use_b = both or not use_t
  local top, bot = use_t and 38 or 26, use_b and 18 or 30
  for _, n in ipairs(notes) do top = math.max(top, n.s); bot = math.min(bot, n.s) end
  local hs = math.max(2, math.min(math.floor(L.rh * 0.45), math.floor(h / (top - bot + 9))))   -- полпромежутка (26 окт: мельче — баланс с панелью)
  local sp = 2 * hs
  local function sy(st) return y + (top + 4 - st) * hs end
  local M = smufl_metrics(sp)
  local fi = gfx.getfont and gfx.getfont() or 0
  local function glyph(k, gx, line_y)   -- k встаёт базовой линией на line_y
    gfx.setfont(SM_FONT, 'Reavura', M.fsz)
    gfx.x, gfx.y = math.floor(gx), math.floor(line_y - SM_TOP[k] * sp - M[k])
    gfx.drawstr(SM[k])
    gfx.setfont(fi)
  end
  local headw = M and M.w.head or math.floor(sp * 1.2)
  local clefw = M and math.max(M.w.g, M.w.f) or U.measure('G')
  local accw = M and math.max(M.w.sharp, M.w.flat) or U.measure('#')
  local nx = x + sp + clefw + sp + 2 * accw + 2
  local w = nx - x + 2 * headw + 2 * sp
  -- линии станов, скобка системы
  U.set(U.GREY)
  if use_t then for k = 0, 4 do gfx.rect(x, sy(30 + 2 * k), w, 1, 1) end end
  if use_b then for k = 0, 4 do gfx.rect(x, sy(18 + 2 * k), w, 1, 1) end end
  if use_t and use_b then gfx.rect(x, sy(38), 1, sy(18) - sy(38) + 1, 1); gfx.rect(x + w - 1, sy(38), 1, sy(18) - sy(38) + 1, 1) end
  -- ключи
  U.set(U.TEXT)
  if M then
    if use_t then glyph('g', x + sp * 0.6, sy(32)) end
    if use_b then glyph('f', x + sp * 0.6, sy(24)) end
  else
    if use_t then U.text(x + 2, sy(32) - math.floor(L.th / 2), 'G', U.DIM) end
    if use_b then U.text(x + 2, sy(24) - math.floor(L.th / 2), 'F', U.DIM) end
  end
  -- ноты по станам: стан, сдвиг секунды, штиль
  local groups = { t = {}, b = {} }
  for _, n in ipairs(notes) do
    local g = (use_t and (not use_b or n.s >= 28)) and 't' or 'b'
    table.insert(groups[g], n)
  end
  local accn = 0
  for gk, gr in pairs(groups) do
    if #gr > 0 then
      local mid = gk == 't' and 34 or 22
      local sum = 0; for _, n in ipairs(gr) do sum = sum + n.s end
      local up = sum / #gr < mid                       -- ниже середины — штиль вверх
      local prev, shifted = nil, false
      local lo_y, hi_y
      for _, n in ipairs(gr) do
        local dx = 0
        if prev and n.s == prev + 1 and not shifted then dx = up and (headw - 1) or -(headw - 1); shifted = true else shifted = false end
        prev = n.s
        local hx, hy = nx + dx, sy(n.s)
        -- добавочные линии
        U.set(U.GREY)
        if gk == 't' then
          for ls = 28, n.s, -2 do gfx.rect(hx - 3, sy(ls), headw + 6, 1, 1) end
          for ls = 40, n.s, 2 do gfx.rect(hx - 3, sy(ls), headw + 6, 1, 1) end
        else
          for ls = 28, n.s, 2 do gfx.rect(hx - 3, sy(ls), headw + 6, 1, 1) end
          for ls = 16, n.s, -2 do gfx.rect(hx - 3, sy(ls), headw + 6, 1, 1) end
        end
        U.set(U.TEXT)
        if M then glyph('head', hx, hy)
        else for d = -hs + 1, hs - 1 do local k = math.floor(headw / 2 * math.sqrt(1 - (d / hs) ^ 2)); gfx.rect(hx + headw / 2 - k + d * 0.3, hy + d, 2 * k, 1, 1) end end
        if n.acc then
          accn = accn + 1
          local ax = nx - accw - 2 - ((accn % 2 == 0) and accw or 0)
          if M then glyph(n.acc == 'b' and 'flat' or 'sharp', ax, hy) else U.text(ax, hy - math.floor(L.th / 2), n.acc, U.TEXT) end
        end
        lo_y = math.max(lo_y or hy, hy); hi_y = math.min(hi_y or hy, hy)
      end
      -- штиль: вверх — справа от головок, вниз — слева; длина 3.5 промежутка за крайней нотой
      U.set(U.TEXT)
      local stw = math.max(1, math.floor(sp / 9))
      if up then gfx.rect(nx + headw - stw, hi_y - math.floor(3.5 * sp), stw, lo_y - hi_y + math.floor(3.5 * sp), 1)
      else gfx.rect(nx, hi_y, stw, lo_y - hi_y + math.floor(3.5 * sp), 1) end
    end
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
  cx = btn(cx, y, bw_of('transpose'), 'transpose', false, { kind = 'tr' })   -- 26 окт: транспозитор (T): полутоны, ступени, к аккорду, just, слушать
  if info.col_name then U.text(cx + L.pad, y, fit(info.col_name .. (info.here and ('  now: ' .. HM.spell(info.here)) or '  now: -'), x + w - cx - L.pad), info.here and U.TEXT or U.GREY) end
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
      btn(x + (k - 1) * (cw + 2), by, cw, lab, HM.spell(info.here) == sym, { kind = 'deg', k = k, seventh = row == 1 })
    end
  end
  -- 26 окт: аккорды трека в паттерне — колонкой сбоку от стана и таба (под кнопками места не занимают)
  local ay = y + 3 * (rh + 2) + 2
  local ty = ay - rh - 4
  -- 27 окт: ХРОМА и КАНДИДАТЫ под ступенями: 12 столбиков (C … B) того, что звучит (выделение, строка всех
  -- треков, chord lane, иначе звук трека); справа is — кандидаты (щелчок — в колонку аккордов мастера),
  -- try — neg (ноты зеркалом, n), P R L (нео-риманово), tt (тритоновая замена) — щелчок пишет аккорд в строку
  local hb = 0
  local narrow = gx1 + 2 * L.cw + 10 * L.cw > x + w
  local bx1 = narrow and (x + w) or gx1
  if info.chroma and ay + 3 * rh <= y + h then
    hb = 3 * rh + 4
    local bw = math.max(U.measure('C#') + 2, L.cw * 2)
    local bh = 2 * rh - 2
    local mxv = 0
    for i = 1, 12 do mxv = math.max(mxv, info.chroma[i]) end
    local P = info.cands and info.cands[1] and CH.parse(info.cands[1].sym)
    local inch = {}
    if P then for _, iv in ipairs(P.ints) do inch[(P.root + iv) % 12] = true end end
    for i = 0, 11 do
      local cx0 = x + i * bw
      local v = mxv > 0 and info.chroma[i + 1] / mxv or 0
      local hh = math.floor(v * bh + 0.5)
      U.set(U.tint(U.LINE, 0.5)); gfx.rect(cx0, ay, bw - 2, bh, 0)
      U.set(inch[i] and U.CYAN or U.GREY); if hh > 0 then gfx.rect(cx0, ay + bh - hh, bw - 2, hh, 1) end
      local nm = HM.pc_name(i)
      U.text(cx0 + math.floor((bw - 2 - U.measure(nm)) / 2), ay + bh + 1, nm, P and i == P.root and U.AMBER or (inch[i] and U.TEXT or U.DIM))
    end
    local qx0 = x + 12 * bw + L.cw
    local qx = qx0
    U.text(qx, ay, 'is', U.GREY); qx = qx + U.measure('is ') + L.pad
    for _, c in ipairs(info.cands or {}) do
      local lab = HM.spell(c.sym) .. (' %d'):format(math.floor(c.w * 100 + 0.5))
      local bw2 = bw_of(lab)
      if qx + bw2 > bx1 then break end
      qx = btn(qx, ay, bw2, lab, c.sym == (info.here and info.here:gsub('/.*$', '')), { kind = 'cand', sym = c.sym, why = 'what sounds - ' .. (info.src or '') .. ', weight ' .. math.floor(c.w * 100 + 0.5) .. ' %; click - into the chord column of the master' })
    end
    qx = qx0
    local ty2 = ay + rh + 2
    U.text(qx, ty2, 'try', U.GREY); qx = qx + U.measure('try ') + L.pad
    for _, t in ipairs(info.trans or {}) do
      local lab = t.lab .. ' ' .. HM.spell(t.sym)
      local bw2 = bw_of(lab)
      if qx + bw2 > bx1 then break end
      local data = t.lab == 'neg' and { kind = 'neg', why = t.why .. ' (n): the notes themselves are mirrored, the octave kept' } or { kind = 'xf', sym = t.sym, why = t.why .. '; click - this chord on the row' }
      qx = btn(qx, ty2, bw2, lab, false, data, t.lab == 'neg' and U.AMBER or nil)
    end
    local why = hv and hv.why or (info.src and ('source: ' .. info.src .. (info.base and (' - ' .. HM.spell(info.base)) or '')))
    if why then U.text(qx0, ay + 2 * rh + 3, fit(why, bx1 - qx0), U.DIM) end
  end
  -- справа: стан и таб
  local show = (hv and (hv.kind == 'deg')) and HM.degree(hv.k, hv.seventh) or ((hv and (hv.kind == 'cand' or hv.kind == 'xf')) and HM.spell(hv.sym)) or HM.spell(info.here)
  local px = gx1 + 2 * L.cw
  local py = y + rh + 2
  -- 26 окт: справа не влезает (узкая панель) — стан и таб под списком аккордов, во всю ширину
  if narrow then px, py = x, ty + rh + 4 + hb end
  if (HM.show_staff or HM.show_tab) and px + 10 * L.cw <= x + w and py + 3 * rh <= y + h then
    if show and CH.parse((show:gsub('%?$', ''))) then
      U.text(px, py, show, (hv and (hv.kind == 'deg' or hv.kind == 'cand' or hv.kind == 'xf')) and U.AMBER or U.TEXT)
      local qx = px
      local ph = y + h - py - rh
      if HM.show_staff then qx = qx + HM.staff(L, qx, py + rh, ph, show) + 2 * L.cw end
      if HM.show_tab and qx + U.measure('e 10') + 4 * L.pad <= x + w and 6 * rh <= y + h - py - rh then qx = qx + HM.tab(L, qx, py + rh, show) + 2 * L.cw end
      HM.chord_column(L, qx, py, x + w - qx, y + h - py, info)
    else
      U.text(px, py, fit('select notes, or a row with several notes', x + w - px), U.DIM)
      HM.chord_column(L, px, py + rh, x + w - px, y + h - py - rh, info)
    end
  end
  return hv
end

-- аккорды трека в паттерне — вертикально: «0080 Eb», текущий янтарём; не влезает по ширине — нет
function HM.chord_column(L, x, y, w, h, info)
  local list = info.list or {}
  if #list == 0 or w < U.measure('0000 C#m7b5') + L.pad then return end
  local rh = L.rh
  local n = math.max(0, math.floor(h / rh))
  local first = 1
  for i, e in ipairs(list) do if e.cur then first = math.max(1, i - math.floor(n / 2)) end end
  for i = first, math.min(#list, first + n - 1) do
    local e = list[i]
    U.text(x, y + (i - first) * rh, ('%04d %s'):format(e.row, HM.spell(e.name)), e.cur and U.AMBER or U.TEXT)
  end
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
  elseif d.kind == 'tr' then return { tr = true }
  elseif d.kind == 'staff' then HM.show_staff = not HM.show_staff; return true
  elseif d.kind == 'tab' then HM.show_tab = not HM.show_tab; return true
  elseif d.kind == 'ji' then HM.ji = not HM.ji; return true
  elseif d.kind == 'deg' then return { write = HM.degree(d.k, d.seventh) }
  elseif d.kind == 'cand' then return { mark = d.sym }   -- 27 окт
  elseif d.kind == 'xf' then return { write = d.sym }
  elseif d.kind == 'neg' then return { neg = true } end
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
  if ch == 'T' then return { tr = true } end
  if ch == 's' then return HM.click({ kind = 'staff' }) end
  if ch == 't' then return HM.click({ kind = 'tab' }) end
  if ch == 'j' then return HM.click({ kind = 'ji' }) end
  if ch == 'o' then return HM.click({ kind = 'kmark' }) end
  if ch == 'i' then return HM.click({ kind = 'ksnap' }) end
  if ch == 'n' then return { neg = true } end   -- 27 окт: негативная гармония (:neg)
  return nil
end

return HM
