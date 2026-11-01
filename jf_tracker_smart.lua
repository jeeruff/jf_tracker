-- jf_tracker_smart.lua — смарт-панель (9 окт, как Smart Select в PlayerPro /
-- Paketti): у ячейки курсора всплывает сетка значений того поля, где стоит
-- курсор — ноты (октавы × 12), громкость, задержка, команда (сперва буква,
-- потом значение), инструмент, точка огибающей / CC. Выбор мышью (наведение +
-- щелчок) или h j k l + Enter; Esc, щелчок мимо или ПКМ — закрыть.
--
-- Что показать и что делать при выборе, решает вызывающий (vim: V.smart):
-- SM.open{ title, items = { {label, v, tip, on}, … }, cols, sel, on_pick(it) }
-- on_pick может вернуть следующую сетку (буква команды → её значения).
-- 10 окт: p.cell_w (px) и p.cell_rows (высота ячейки в строках) — для превью;
-- it.draw(x, y, w, h, sel) рисует ячейку сам (шрифт своим шрифтом, тема цветами)
-- Без reaper.* — тест tests/test_smart.lua.

local SM = { p = nil, rect = nil, hot = nil }
-- 11 окт: listen (кнопка внизу, по умолчанию вкл) — смена выбора звучит: p.on_sel(it) у вызывающего
SM.listen = true
SM.on_listen = nil      -- main: запомнить вкл / выкл
local function notify(p, i)
  if not (SM.listen and p and p.on_sel) then return end
  local it = p.items[i]
  if it then pcall(p.on_sel, it) end
end

function SM.active() return SM.p ~= nil end
function SM.close()
  local p = SM.p
  SM.p, SM.rect, SM.hot, SM.hot_prev, SM.typed = nil, nil, nil, nil, nil
  if p and p.on_close and not p.picked then pcall(p.on_close) end   -- 17 окт: закрыли без выбора (Esc) — вызывающий откатит прослушанное
end

function SM.open(p, anchor)
  if not p or not p.items or #p.items == 0 then SM.close(); return false end
  p.cols = math.max(1, math.min(p.cols or 16, #p.items))
  p.sel = math.max(1, math.min(#p.items, p.sel or 1))
  if anchor then p.anchor = anchor elseif SM.p then p.anchor = SM.p.anchor end
  SM.p, SM.hot, SM.typed = p, nil, nil
  return true
end

-- 12 окт: набор с клавиатуры — что ячейка «печатает»: it.t, иначе подпись без пробелов и дефисов
-- (C-4 → C4, 9E → 9E); пустые / служебные (--, ---) не набираются
local function typed_of(it)
  if it.t then return it.t end
  local t = (it.label or ''):upper():gsub('[%s%-]', '')
  return t
end
-- набранный символ: true — принят (выбор сдвинулся), false — не начало ни одного значения
local function type_char(p, ch)
  local b = (SM.typed or '') .. ch:upper()
  local best, bd, exact
  local longer = false
  local s0 = SM.typed_from or p.sel
  for i, it in ipairs(p.items) do
    local t = typed_of(it)
    if it.ta and it.ta:sub(1, #b) == b then t = it.ta end   -- 17 окт: короткий набор команды: M = 0M, S I = SI (S — 0S)
    if t ~= '' and t:sub(1, #b) == b then
      if t == b and not exact then exact = i end
      if #t > #b then longer = true end
      local d = math.abs(i - s0)
      if not bd or d < bd then best, bd = i, d end
    end
  end
  if not best then return false end
  if not SM.typed then SM.typed_from = p.sel end
  SM.typed = b
  p.sel = exact or best
  -- 12 окт: набор однозначен (ровно это значение, длиннее с тем же началом нет) — выбрано сразу, без Enter:
  -- 0V в списке команд — его значения, 9E — записано (просьба: «начал вводить — пусть вводится»)
  if exact and not longer and not SM.no_auto then
    SM.typed, SM.typed_from = nil, nil
    SM.pick(p.sel)
  end
  return true
end
SM.type_char = type_char

local function pick(i)
  local p = SM.p
  local it = p and p.items[i]
  if not it then return end
  p.picked = true
  local nxt = p.on_pick and p.on_pick(it)
  if type(nxt) == 'table' then SM.open(nxt)
  elseif SM.p == p then SM.close() end   -- 19 окт: выбор открыл другую панель (timesel → section) — её не закрывать
end
SM.pick = pick

-- клавиши; true — съели
local ESC, ENTER, UP, DOWN, LEFT, RIGHT = 27, 13, 30064, 1685026670, 1818584692, 1919379572
function SM.key(c)
  local p = SM.p
  if not p then return false end
  local n, cols = #p.items, p.cols
  local s0 = p.sel
  local r = SM.key_in(c, p, n, cols)
  if SM.p == p and p.sel ~= s0 then notify(p, p.sel) end
  return r
end
function SM.key_in(c, p, n, cols)
  local ch = c > 0 and c < 256 and string.char(c) or ''
  if p.on_key and p.on_key(c) then return true end   -- 16 окт: своя клавиша вызывающего (макросы: @@ — последний)
  -- 12 окт: печатный символ, который продолжает значение, — набор (сильнее навигации: 9E, C#4, 0U)
  if ch:match('^[%w#]$') and type_char(p, ch) then return true end
  if c == 8 then                                -- Backspace — символ набора назад
    if SM.typed then
      local b = SM.typed:sub(1, -2); SM.typed = nil; p.sel = SM.typed_from or p.sel
      for k = 1, #b do type_char(p, b:sub(k, k)) end
      if b == '' then SM.typed, SM.typed_from = nil, nil end
    end
    return true
  end
  if SM.typed and ch:match('^[%w#]$') then SM.msg = SM.typed .. ch:upper() .. ': no such value'; return true end
  if c ~= ENTER and ch ~= ' ' then SM.typed, SM.typed_from = nil, nil end   -- навигация обрывает набор
  if c == ESC or ch == 'q' then SM.close()
  elseif c == ENTER or ch == ' ' then pick(p.sel)
  elseif ch == 'h' or c == LEFT then p.sel = math.max(1, p.sel - 1)
  elseif ch == 'l' or c == RIGHT then p.sel = math.min(n, p.sel + 1)
  elseif ch == 'k' or c == UP then if p.sel - cols >= 1 then p.sel = p.sel - cols end
  elseif ch == 'j' or c == DOWN then if p.sel + cols <= n then p.sel = p.sel + cols end
  elseif ch == '0' or ch == '^' then p.sel = p.sel - (p.sel - 1) % cols
  elseif ch == '$' then p.sel = math.min(n, p.sel - (p.sel - 1) % cols + cols - 1)
  elseif ch == 'g' then p.sel = 1
  elseif ch == 'G' then p.sel = n
  end
  return true                                 -- пока открыта — все клавиши её
end

-- геометрия: ячейка = самая широкая подпись + поля; сетка у anchor (под
-- ячейкой, не влезает — над ней), целиком в окне
function SM.layout(L, ms, W, H)
  local p = SM.p
  local cw = 0
  for _, it in ipairs(p.items) do cw = math.max(cw, ms(it.label) + (it.sub and (ms(' ') + ms(it.sub)) or 0)) end
  cw = p.cell_w or (cw + 2 * L.pad)
  local crh = (p.cell_rows or 1) * L.rh
  local rows = math.ceil(#p.items / p.cols)
  local w = p.cols * cw + 2 * L.pad
  local tw = ms(p.title or '') + 2 * L.pad
  if w < tw then cw = cw + math.ceil((tw - w) / p.cols); w = p.cols * cw + 2 * L.pad end
  local h = rows * crh + 2 * L.rh + 2 * L.pad     -- заголовок, сетка, строка подсказки (и кнопка listen)
  local a = p.anchor or { x = L.pad, y = L.pad }
  local x = math.max(2, math.min(W - w - 2, a.x))
  local y = a.y
  if y + h > H - 2 then y = (a.top or a.y) - h - 2 end
  y = math.max(2, math.min(y, H - h - 2))
  return x, y, w, h, cw, rows, crh
end

-- рисование; d = { L, set, rect, text, ms, fit, C = цвета }
function SM.draw(d)
  local p = SM.p
  if not p then return end
  local L, set, text, ms, C = d.L, d.set, d.text, d.ms, d.C
  local x, y, w, h, cw, rows, crh = SM.layout(L, ms, gfx.w, gfx.h)
  SM.rect = { x, y, w, h }
  set(C.PANEL); gfx.rect(x, y, w, h, 1)
  set(C.FRAME); gfx.rect(x, y, w, h, 0); gfx.rect(x + 1, y + 1, w - 2, h - 2, 0)
  local tline = (p.title or '') .. (SM.typed and ('   typed: ' .. SM.typed) or '')
  text(x + L.pad, y + L.pad, d.fit(tline, w - 2 * L.pad), C.CYAN)
  local gx, gy = x + L.pad, y + L.pad + L.rh
  local mx, my = gfx.mouse_x, gfx.mouse_y
  SM.hot = nil
  for i, it in ipairs(p.items) do
    local r, c = (i - 1) // p.cols, (i - 1) % p.cols
    local cx, cy = gx + c * cw, gy + r * crh
    local hot = mx >= cx and mx < cx + cw and my >= cy and my < cy + crh
    if hot then SM.hot = i end
    -- 9 окт: выбор клавишами — заметная янтарная заливка; текущее значение — янтарный текст
    local sel = i == p.sel
    if sel then set(C.SELF); gfx.rect(cx, cy, cw - 1, crh, 1) end
    if it.draw then it.draw(cx + 1, cy + 1, cw - 3, crh - 2, sel)
    else
      local col = sel and C.TEXT or (it.on and C.AMBER or (it.dim and C.GREY or C.TEXT))
      if it.sub then
        -- 12 окт: hex и рядом десятичное тусклым (9E 158)
        local tw = ms(it.label) + ms(' ') + ms(it.sub)
        local tx = cx + math.floor((cw - tw) / 2)
        text(tx, cy + 1, it.label, col)
        text(tx + ms(it.label) + ms(' '), cy + 1, it.sub, sel and C.TEXT or C.GREY)
      else
        local lx = cx + math.floor((cw - ms(it.label)) / 2)
        text(lx, cy + 1, it.label, col)
        if it.hl and not sel then   -- 17 окт: буквы набора — светлее
          local a, b = it.hl[1], it.hl[2]
          text(lx + ms(it.label:sub(1, a - 1) .. '.') - ms('.'), cy + 1, it.label:sub(a, b), C.AMBER)
        end
      end
    end
    if sel then set(C.AMBER); gfx.rect(cx, cy, cw - 1, crh, 0)
    elseif hot then set(C.TEXT); gfx.rect(cx, cy, cw - 1, crh, 0)
    elseif it.on then set(C.AMBER); gfx.rect(cx, cy, cw - 1, crh, 0) end
  end
  -- наведение на другую ячейку — тоже прослушивание
  if SM.hot and SM.hot ~= SM.hot_prev then notify(p, SM.hot) end
  SM.hot_prev = SM.hot
  -- кнопка listen справа внизу
  local by = gy + rows * crh
  -- 18 окт: listen — только когда выбор звучит (p.on_sel); в меню аранжировок и т. п. смысла нет
  local lw = p.on_sel and (ms('listen') + 2 * L.pad) or 0
  local lx = x + w - L.pad - lw
  local lhot = p.on_sel and mx >= lx and mx < lx + lw and my >= by and my < by + L.rh
  SM.lbtn = nil
  if p.on_sel then
    set(SM.listen and C.SELF or C.PANEL); gfx.rect(lx, by, lw, L.rh, 1)
    set(SM.listen and C.AMBER or C.GREY); gfx.rect(lx, by, lw, L.rh, 0)
    text(lx + L.pad, by, 'listen', (SM.listen or lhot) and C.AMBER or C.GREY)
    SM.lbtn = { lx, by, lw, L.rh }
  end
  -- подсказка: под мышью, иначе выбранное
  local ti = p.items[SM.hot or p.sel]
  local tip = lhot and ('listen: the choice sounds when it changes - ' .. (SM.listen and 'on' or 'off')) or (ti and (ti.tip or ti.label) or '')
  if not SM.hot and SM.msg then tip = SM.msg end
  SM.msg = nil
  text(x + L.pad, by, d.fit(tip, lx - x - 2 * L.pad), C.GREY)
end

-- мышь: щелчок по ячейке — выбор, мимо (или ПКМ) — закрыть. true — съели
function SM.click(mx, my, right)
  if not SM.p then return false end
  local r = SM.rect
  local inside = r and mx >= r[1] and mx < r[1] + r[3] and my >= r[2] and my < r[2] + r[4]
  if right or not inside then SM.close(); return true end
  local b = SM.lbtn
  if b and mx >= b[1] and mx < b[1] + b[3] and my >= b[2] and my < b[2] + b[4] then
    SM.listen = not SM.listen
    if SM.on_listen then SM.on_listen(SM.listen) end
    return true
  end
  if SM.hot then SM.p.sel = SM.hot; pick(SM.hot) end
  return true
end

function SM.inside(mx, my)
  local r = SM.rect
  return SM.p and r and mx >= r[1] and mx < r[1] + r[3] and my >= r[2] and my < r[2] + r[4]
end

-- ── сетки ─────────────────────────────────────────────────────────────────
SM.NAMES = { 'C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-' }
function SM.note_label(p) return SM.NAMES[p % 12 + 1] .. tostring(p // 12 - 1) end

-- ноты: октавы 0..9 строками по 12, ниже OFF и --- (удалить). cur — высота
-- ноты в ячейке (подсвечена), oct — октава ввода (выбор стартует там)
function SM.notes(cur, oct, micro)
  local items = {}
  for o = 0, 9 do
    for k = 0, 11 do
      local p = (o + 1) * 12 + k
      if p <= 127 then items[#items + 1] = { label = SM.note_label(p), v = p, on = p == cur, tip = ('note %s (%d)'):format(SM.note_label(p), p) } end
    end
  end
  while #items % 12 ~= 0 do items[#items + 1] = { label = '', v = nil, dim = true } end
  items[#items + 1] = { label = 'OFF', v = 'off', tip = 'note off: the sounding note ends in this row' }
  items[#items + 1] = { label = '---', v = 'del', tip = 'delete the event of this row' }
  -- 24 окт: микротоны 72-EDO — ступень 1/6 тона (16.7 ц) от ноты: v3 vv v · ^ ^^ ^3 (выбор — у ноты строки,
  -- панель остаётся открытой); метка как в трекере (C-4^)
  while #items % 12 ~= 0 do items[#items + 1] = { label = '', v = nil, dim = true } end
  for m = -3, 3 do
    local lb = m == 0 and '0' or ((m > 0 and '^' or 'v') .. (math.abs(m) == 2 and (m > 0 and '^' or 'v') or (math.abs(m) == 3 and '3' or '')))
    items[#items + 1] = { label = lb, v = { micro = m }, on = (micro or 0) == m and cur ~= nil,
                          tip = m == 0 and 'microtone off: the note in 12-EDO' or ('%+.1f cents (%+d/6 tone, 72-EDO; MTS for Surge XT / MTS-ESP)'):format(m * 100 / 6, m) }
  end
  local sel
  for i, it in ipairs(items) do if it.v == (cur or ((oct or 4) + 1) * 12) then sel = i end end
  return items, 12, sel
end

-- значения 0..n−1 (n = 128 или 256): hex — две цифры, midi — десятичные;
-- clear — ячейка «--» в конце (убрать значение)
function SM.values(n, cur, hex, clear, mean)
  local items = {}
  for v = 0, n - 1 do
    local m = mean and mean(v)
    items[#items + 1] = { label = hex and ('%02X'):format(v) or tostring(v), v = v, on = v == cur,
                          sub = hex and tostring(v) or nil,
                          tip = hex and (('%02X = %d'):format(v, v) .. (m and ('  ->  ' .. m) or '')) or (('%d  (hex %02X)'):format(v, v) .. (m and ('  ->  ' .. m) or '')) }
  end
  if clear then items[#items + 1] = { label = '--', v = 'clear', tip = clear } end
  local sel = cur and (cur + 1) or 1
  return items, 16, sel
end

-- коды команд (12 окт: два символа, как в Renoise; описания — как в справке;
-- порядок: часто нужные сперва). 0 — эффекты, S — свойства сэмпла (item),
-- Z — песня. Единственный список кодов для ввода, меню и подсказок
SM.FX = {
  { '0S', 'start offset xx/256 of the sample (drumrs5k: of the pad; sliced audio: slice xx; slixer: of the slice)' }, { '0M', 'note volume xx/80' }, { '0P', 'pan (80 = centre)' },
  { '0U', 'pitch up xx/16 semitone per row' }, { '0D', 'pitch down xx/16 semitone per row' },
  { '0G', 'glide from the previous note in xx rows' }, { '0V', 'vibrato: speed x (period 16/x rows), depth y/8 semitone' },
  { '0A', 'arpeggio 0, x, y semitones' }, { '0I', 'volume up xx/256 per row' }, { '0T', 'tremolo: speed x (period 16/x rows), depth y/16' }, { '0O', 'volume down xx/256 per row' },
  { '0R', 'retrigger every y/16 row, volume falls by x/16 each' }, { '0Y', 'maybe: probability xx/FF' },
  { 'SI', 'sample fade in xx/16 row' }, { 'SO', 'sample fade out xx/16 row' }, { 'SB', 'beatsync to xx rows (slixer: the slice stretched to xx rows)' }, { '0B', 'backwards: reverse (slixer note)' },
  { 'SF', 'finetune in cents (80 = 0)' }, { 'SL', 'SL00: loop source off' }, { 'SM', 'channel mode 0..4' },
  { 'ZT', 'tempo: BPM = xx' }, { 'ZJ', 'jump to sequence slot xx' }, { 'ZB', 'pattern break: after this row the next pattern plays, from its row xx' },
  { '09', 'sample offset xx/256 of the whole sample (ProTracker 9xx)' },
  { 'BR', 'beat repeat: from this row the track repeats a 1/xx bar slice (04 quarter, 08 eighth, 10 sixteenth, 06 / 0C triplets) till the next BR or the note end; BR00 stop. Puts LiveBeatRepeater at the end of the chain itself' },
}
-- 12 окт: короткие имена — список команд читается словами (0U pitch up), не только кодами
SM.FX_NAME = { ['0S'] = 'start offset', ['0M'] = 'volume', ['0P'] = 'pan', ['0U'] = 'pitch up', ['0D'] = 'pitch down', ['0G'] = 'glide', ['0V'] = 'vibrato', ['0A'] = 'arpeggio', ['0I'] = 'vol up', ['0O'] = 'vol down', ['0T'] = 'tremolo', ['0R'] = 'retrig', ['0Y'] = 'maybe', ['SI'] = 'fade in', ['SO'] = 'fade out', ['SB'] = 'beatsync', ['0B'] = 'reverse', ['SF'] = 'finetune', ['SL'] = 'loop', ['SM'] = 'channels', ['ZT'] = 'tempo', ['ZJ'] = 'jump', ['ZB'] = 'break', ['09'] = 'offset', BR = 'beat repeat' }
SM.FX_DESC = {}
for _, e in ipairs(SM.FX) do SM.FX_DESC[e[1]] = e[2] end
-- 12 окт: что значит значение xx команды — строка подсказки смарт-панели (9E = 158 -> …)
local function st(x) return ('%+.2f'):format(x):gsub('0+$', ''):gsub('%.$', '') end
SM.FX_MEAN = {
  ['0S'] = function(v) return ('start at %d%% (sliced audio: slice %d)'):format(math.floor(v / 256 * 100 + 0.5), v) end,
  ['0M'] = function(v) return ('volume %d%%'):format(math.floor(v / 128 * 100 + 0.5)) end,
  ['0P'] = function(v) if v == 128 then return 'centre' end; return (v < 128 and 'left ' or 'right ') .. math.floor(math.abs(v - 128) / 128 * 100 + 0.5) .. '%' end,
  ['0U'] = function(v) return st(v / 16) .. ' semitone per row' end,
  ['0D'] = function(v) return st(-v / 16) .. ' semitone per row' end,
  ['0G'] = function(v) return ('glide over %d rows'):format(v) end,
  ['0V'] = function(v) local x, y = v >> 4, v & 15; return x == 0 and 'vibrato off' or ('period %s rows, depth %s semitone'):format(st(16 / x):gsub('^%+', ''), st(y / 8):gsub('^%+', '')) end,
  ['0A'] = function(v) return ('arpeggio 0, +%d, +%d semitones'):format(v >> 4, v & 15) end,
  ['0I'] = function(v) return ('volume +%d%% per row'):format(math.floor(v / 256 * 100 + 0.5)) end,
  ['0O'] = function(v) return ('volume -%d%% per row'):format(math.floor(v / 256 * 100 + 0.5)) end,
  ['0T'] = function(v) local x, y = v >> 4, v & 15; return x == 0 and 'tremolo off' or ('period %s rows, depth %d%%'):format(st(16 / x):gsub('^%+', ''), math.floor(y / 16 * 100 + 0.5)) end,
  ['0R'] = function(v) local x, y = v >> 4, v & 15; return ('retrig every %s row, volume -%d%% each'):format(st((y > 0 and y or 4) / 16):gsub('^%+', ''), math.floor(x / 16 * 100 + 0.5)) end,
  ['0Y'] = function(v) return ('plays %d%% of the time'):format(math.floor(v / 255 * 100 + 0.5)) end,
  SI = function(v) return ('fade in %s row'):format(st(v / 16):gsub('^%+', '')) end,
  SO = function(v) return ('fade out %s row'):format(st(v / 16):gsub('^%+', '')) end,
  SB = function(v) return v == 0 and 'beatsync off' or ('fits %d rows'):format(v) end,
  ['0B'] = function(v) return v == 0 and 'forward' or 'backwards' end,
  SF = function(v) return ('%+d cents'):format(v - 128) end,
  SL = function(v) return v == 0 and 'loop off' or 'loop on' end,
  SM = function(v) return ({ 'normal', 'reverse stereo', 'mono (mix)', 'mono left', 'mono right' })[v + 1] or ('mode ' .. v) end,
  ZT = function(v) return ('tempo %d BPM'):format(v) end,
  ZJ = function(v) return ('jump to sequence slot %d'):format(v) end,
  ZB = function(v) return ('break: the next pattern from its row %d'):format(v) end,
  ['09'] = function(v) return ('start at %d%% of the sample'):format(math.floor(v / 256 * 100 + 0.5)) end,
  BR = function(v)   -- то же округление, что C.br_len: ближайшая длина репитера к 1/xx такта
    if v == 0 then return 'repeat off' end
    local B = { { 2, '2 bars' }, { 1, '1 bar' }, { 2 / 3, '1T' }, { 1 / 2, '1/2' }, { 1 / 3, '1/2T' }, { 1 / 4, '1/4' }, { 1 / 6, '1/4T' }, { 1 / 8, '1/8' },
      { 1 / 12, '1/8T' }, { 1 / 16, '1/16' }, { 1 / 24, '1/16T' }, { 1 / 32, '1/32' }, { 1 / 64, '1/64' }, { 1 / 128, '1/128' } }
    local best, bd = '?', 1e9
    for _, b in ipairs(B) do local d = math.abs(math.log(b[1] * v)); if d < bd then best, bd = b[2], d end end
    return 'repeat ' .. best .. ' bar slice'
  end,
}
function SM.fx_letters(only)   -- only(code) → false: команда этой ноте не подходит (19 окт: MIDI — без 0S, SI, SO …)
  local items = {}
  -- 17 окт: буква эффекта — сразу на него: 0x — одна буква (M = 0M), S_ Z_ — две (S I = SI; S и Enter — 0S); буквы светлее
  for _, e in ipairs(SM.FX) do
    local code = e[1]
    if only and not only(code) then goto fxl_next end
    local ta = code:sub(1, 1) == '0' and code:sub(2) or code
    items[#items + 1] = { label = code .. ' ' .. (SM.FX_NAME[code] or ''), t = code, ta = ta, v = code, tip = code .. 'xx  ' .. e[2],
                          hl = code:sub(1, 1) == '0' and { 2, 2 } or { 1, 2 } }
    ::fxl_next::
  end
  return items, 4, 1
end

return SM
