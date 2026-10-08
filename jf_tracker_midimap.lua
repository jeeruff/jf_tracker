-- jf_tracker_midimap.lua — MIDI learn для слайсера (вкладка midi, 2 окт).
--
-- Привязка = цель + (устройство, канал, CC или нота). Вход читает main
-- (MIDI_GetRecentInputEvent — буфер последних событий REAPER, без JSFX) и
-- отдаёт сюда каждое событие: MM.feed → действие для main или nil (не наше —
-- событие идёт дальше: запись нот, прослушивание).
--
-- Цели трёх видов:
--   value    ручка: abs (0..127 → 0..1) или энкодер rel (1..63 вверх,
--            65..127 вниз — дополнительный код) / rel64 (64 ± n)
--   trigger  кнопка: нота (note-on) или CC (фронт через 64: кнопки 127 / 0)
--   pads     нота-основа: основа = слайс 1, +1 полутон — следующий слайс
-- Learn: выбрать цель, Enter — следующий CC / нота становятся её привязкой.
-- Привязки глобальные (ExtState с persist): контроллер у пользователя один
-- на все проекты. Сериализация — строки «цель|устройство|канал|вид|номер|режим».
--
-- Без reaper.*: тестируется tests/test_midimap.lua.

local MM = {}

MM.TARGETS = {
  { id = 'zone_start', kind = 'value', label = 'slice start', d = 'start of the slice zone on the big sample (or of the selection)' },
  { id = 'zone_end', kind = 'value', label = 'slice end', d = 'end of the slice zone (or of the selection)' },
  { id = 'zone_move', kind = 'value', label = 'slice move', d = 'move the whole zone / selection, same length' },
  { id = 'sens', kind = 'value', label = 'sensitivity', d = 'transient sensitivity (re-slices when sliced by transients)' },
  { id = 'vol', kind = 'value', label = 'volume', d = 'sample volume -60..+24 dB' },
  { id = 'inst', kind = 'value', label = 'instrument', d = 'select instrument (knob: whole list, encoder: step)' },
  { id = 'pads', kind = 'pads', label = 'slice pads', d = 'learned note = slice 1, next notes = next slices (preview)' },
  { id = 'eq2', kind = 'trigger', label = 'equal 2', d = 'slice into 2 equal parts' },
  { id = 'eq4', kind = 'trigger', label = 'equal 4', d = 'slice into 4' },
  { id = 'eq8', kind = 'trigger', label = 'equal 8', d = 'slice into 8' },
  { id = 'eq16', kind = 'trigger', label = 'equal 16', d = 'slice into 16' },
  { id = 'eq32', kind = 'trigger', label = 'equal 32', d = 'slice into 32' },
  { id = 'trans', kind = 'trigger', label = 'transients', d = 'slice at transients' },
  { id = 'detect', kind = 'trigger', label = 'detect', d = 'detect transients (show only)' },
  { id = 'clear', kind = 'trigger', label = 'clear slices', d = 'remove the slicing' },
  { id = 'snap', kind = 'trigger', label = 'snap', d = 'snap on / off' },
  { id = 'quant', kind = 'trigger', label = 'quantize', d = 'smart quantize' },
  { id = 'autotrim', kind = 'trigger', label = 'autotrim', d = 'cut the silence at the start and the end' },
  { id = 'all', kind = 'trigger', label = 'select all', d = 'selection = whole sample' },
  { id = 'preview', kind = 'trigger', label = 'preview', d = 'play the zone / selection' },
  { id = 'insert', kind = 'trigger', label = 'insert', d = 'insert the selection at the tracker cursor (Enter)' },
  { id = 'depot', kind = 'trigger', label = 'to library', d = 'selection becomes a new instrument in the track library' },
  { id = 'norm', kind = 'trigger', label = 'normalize', d = 'normalize the sample' },
  { id = 'view', kind = 'trigger', label = 'view', d = 'peaks / spectral' },
  { id = 'inst_next', kind = 'trigger', label = 'next inst', d = 'next instrument' },
  { id = 'inst_prev', kind = 'trigger', label = 'prev inst', d = 'previous instrument' },
  { id = 'slicer', kind = 'trigger', label = 'open slicer', d = 'show the sample tab' },
  { id = 'play', kind = 'trigger', label = 'play / stop', d = 'transport' },
}
local BY_ID = {}
for i, t in ipairs(MM.TARGETS) do BY_ID[t.id] = t; t.i = i end
MM.BY_ID = BY_ID

MM.binds = {}           -- id цели → { dev, ch, kind = 'cc'|'note', num, mode }
MM.learning = nil       -- id цели, ждущей события
MM.cur = 1              -- строка вкладки
MM.scroll = 0
MM.last = ''            -- последнее входящее событие (подпись)
MM.hint = nil           -- метки f (ставит main)
MM.MODES = { 'abs', 'rel', 'rel64' }
local held = {}         -- id → последнее значение CC (фронт кнопок)

local function ev_text(kind, ch, num, v, dev)
  return ('%s %d ch%d%s%s'):format(kind == 'cc' and 'CC' or 'note', num, ch + 1, v and (' = ' .. v) or '', (dev and dev ~= '') and ('  ' .. dev) or '')
end
MM.ev_text = ev_text

function MM.bind_text(b)
  if not b then return '-' end
  return ev_text(b.kind, b.ch, b.num, nil, nil)
end

-- событие: st, d1, d2 (байты), dev (имя устройства). Возвращает действие:
--   { learned = цель, bind = }                       learn завершён
--   { t = цель, v = 0..1 } | { t =, d = ±n }         ручка abs / энкодер
--   { t = цель, trig = true }                        кнопка
--   { t = 'pads', k = номер слайса, vel = }          пэд
--   { eaten = true }                                 наше, но без действия (note-off, отпускание)
-- или nil — событие не наше.
local function feed0(st, d1, d2, dev)
  if not st then return nil end
  local hi, ch = st & 0xF0, st & 0x0F
  local kind
  if hi == 0xB0 then kind = 'cc'
  elseif hi == 0x90 and (d2 or 0) > 0 then kind = 'on'
  elseif hi == 0x80 or (hi == 0x90 and (d2 or 0) == 0) then kind = 'off'
  else return nil end
  dev = dev or ''
  MM.last = ev_text(kind == 'cc' and 'cc' or 'note', ch, d1, kind == 'cc' and d2 or (kind == 'on' and ('on ' .. d2) or 'off'), dev)
  if MM.learning then
    if kind == 'off' then return { eaten = true } end
    local t = BY_ID[MM.learning]
    local b = { dev = dev, ch = ch, kind = kind == 'cc' and 'cc' or 'note', num = d1, mode = 'abs' }
    -- одно событие — одна цель: прежняя привязка этого CC / ноты снимается
    for id, ob in pairs(MM.binds) do
      if ob.dev == b.dev and ob.ch == b.ch and ob.kind == b.kind and ob.num == b.num then MM.binds[id] = nil end
    end
    MM.binds[t.id] = b
    MM.learning = nil
    held[t.id] = d2
    return { learned = t.id, bind = b }
  end
  local ekind = kind == 'cc' and 'cc' or 'note'
  for id, b in pairs(MM.binds) do
    if b.kind == ekind and b.ch == ch and (b.dev == '' or b.dev == dev) then
      local t = BY_ID[id]
      if t and t.kind == 'pads' and ekind == 'note' and d1 >= b.num and d1 < b.num + 64 then
        if kind == 'on' then return { t = id, k = d1 - b.num + 1, vel = d2 } end
        return { eaten = true }
      elseif t and b.num == d1 then
        if t.kind == 'value' and ekind == 'cc' then
          if b.mode == 'rel' then return { t = id, d = d2 < 64 and d2 or d2 - 128 }
          elseif b.mode == 'rel64' then return { t = id, d = d2 - 64 }
          else return { t = id, v = d2 / 127 } end
        elseif t.kind == 'value' then
          -- нота на ручке: шаг вверх (без отпускания)
          if kind == 'on' then return { t = id, d = 1 } end
          return { eaten = true }
        else
          if ekind == 'cc' then
            local prev = held[id] or 0
            held[id] = d2
            if d2 >= 64 and prev < 64 then return { t = id, trig = true } end
            return { eaten = true }
          end
          if kind == 'on' then return { t = id, trig = true } end
          return { eaten = true }
        end
      end
    end
  end
  return nil
end

-- монитор (2 окт): последние события со своей судьбой — цель / learn / мимо
MM.log = {}
MM.LOG_MAX = 64
function MM.feed(st, d1, d2, dev)
  local a = feed0(st, d1, d2, dev)
  if st and (st & 0xF0) >= 0x80 then
    local hi = st & 0xF0
    local what
    if hi == 0xB0 then what = ('CC  %3d = %3d'):format(d1 or 0, d2 or 0)
    elseif hi == 0x90 and (d2 or 0) > 0 then what = ('on  %3d v%3d'):format(d1 or 0, d2 or 0)
    elseif hi == 0x80 or hi == 0x90 then what = ('off %3d'):format(d1 or 0)
    elseif hi == 0xE0 then what = ('bend %5d'):format(((d2 or 0) << 7 | (d1 or 0)) - 8192)
    elseif hi == 0xD0 then what = ('aftertouch %3d'):format(d1 or 0)
    elseif hi == 0xA0 then what = ('poly at %3d %3d'):format(d1 or 0, d2 or 0)
    elseif hi == 0xC0 then what = ('program %3d'):format(d1 or 0)
    else what = ('%02X %d %d'):format(st, d1 or 0, d2 or 0) end
    local fate
    if a and a.learned then fate = 'learned ' .. BY_ID[a.learned].label
    elseif a and a.t then fate = BY_ID[a.t] and BY_ID[a.t].label or a.t
    elseif a then fate = '(bound)' end
    table.insert(MM.log, 1, { ch = (st & 0x0F) + 1, what = what, dev = dev or '', fate = fate })
    while #MM.log > MM.LOG_MAX do table.remove(MM.log) end
  end
  return a
end

-- ── хранение ────────────────────────────────────────────────────────────
function MM.serialize()
  local out = {}
  for _, t in ipairs(MM.TARGETS) do
    local b = MM.binds[t.id]
    if b then out[#out + 1] = ('%s|%s|%d|%s|%d|%s'):format(t.id, (b.dev or ''):gsub('[|\n]', ' '), b.ch, b.kind, b.num, b.mode or 'abs') end
  end
  return table.concat(out, '\n')
end

function MM.parse(s)
  MM.binds = {}
  for line in (s or ''):gmatch('[^\n]+') do
    local id, dev, ch, kind, num, mode = line:match('^([%w_]+)|(.-)|(%d+)|(%a+)|(%d+)|(%w+)$')
    if id and BY_ID[id] and (kind == 'cc' or kind == 'note') then
      MM.binds[id] = { dev = dev, ch = tonumber(ch), kind = kind, num = tonumber(num), mode = mode }
    end
  end
end

-- ── вкладка ─────────────────────────────────────────────────────────────
local UP, DOWN = 30064, 1685026670
-- true — съедено; 'leave' — в трекер; 'save' — привязки изменились
function MM.key(c)
  local ch = c < 256 and string.char(c) or ''
  local n = #MM.TARGETS
  if c == 27 then
    if MM.learning then MM.learning = nil; return true end
    return 'leave'
  end
  local t = MM.TARGETS[MM.cur]
  if ch == 'j' or c == DOWN then MM.cur = math.min(n, MM.cur + 1)
  elseif ch == 'k' or c == UP then MM.cur = math.max(1, MM.cur - 1)
  elseif ch == 'g' then MM.cur = 1
  elseif ch == 'G' then MM.cur = n
  elseif c == 13 or ch == 'l' or ch == 'L' then MM.learning = (MM.learning == t.id) and nil or t.id
  elseif ch == 'd' or ch == 'x' or c == 8 then
    if MM.binds[t.id] then MM.binds[t.id] = nil; return 'save' end
  elseif ch == 'm' then
    local b = MM.binds[t.id]
    if b and b.kind == 'cc' and t.kind == 'value' then
      local k = 1
      for i, m in ipairs(MM.MODES) do if m == b.mode then k = i end end
      b.mode = MM.MODES[k % #MM.MODES + 1]
      return 'save'
    end
  else return false end
  return true
end

-- отрисовка в (x, y, w, h); hover = { row = i, btn = 'learn'|'clear'|'mode' }
function MM.draw(U, L, x, y, w, h, focused, fit)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover
  -- слева — монитор входа (2 окт), справа — привязки
  local lw = math.max(L.cw * 22, math.floor(w * 0.36))
  if w - lw < L.cw * 30 then lw = 0 end                -- узко: только привязки
  if lw > 0 then
    U.text(x, y, fit('monitor  (all MIDI inputs)', lw - L.pad), U.GREY)
    local nrow = math.max(1, math.floor((h - L.rh - 2) / L.rh))
    for i = 1, math.min(nrow, #MM.log) do
      local e = MM.log[i]
      local ry = y + L.rh + 2 + (i - 1) * L.rh
      local head = ('ch%-2d %s'):format(e.ch, e.what)
      local hw = U.measure(head)
      U.text(x, ry + 1, fit(head, lw - L.pad), i == 1 and U.TEXT or U.GREY)
      local rest = e.fate and ('-> ' .. e.fate) or e.dev
      local rx = x + hw + L.pad
      if rest ~= '' and rx + U.measure('-> ab') < x + lw - L.pad then
        U.text(rx, ry + 1, fit(rest, x + lw - L.pad - rx), e.fate and U.AMBER or U.DIM)
      end
    end
    if #MM.log == 0 then U.text(x, y + L.rh + 3, fit('move a knob / hit a pad: events show here', lw - L.pad), U.DIM) end
    U.set(U.LINE); gfx.rect(x + lw - math.floor(L.pad / 2) - 1, y, 1, h, 1)
    x, w = x + lw + L.pad, w - lw - L.pad
  end
  local head = MM.learning and ('learn: ' .. BY_ID[MM.learning].label .. ' - move a knob / hit a pad or key (Esc cancels)')
    or 'midi learn - Enter: learn, d: clear, m: abs / rel / rel64'
  U.text(x, y, fit(head, lw > 0 and w or math.floor(w * 0.62)), MM.learning and U.AMBER or U.GREY)
  if lw == 0 then U.text(x + math.floor(w * 0.64), y, fit('in: ' .. (MM.last ~= '' and MM.last or '-'), w - math.floor(w * 0.64)), U.GREY) end
  local top = y + L.rh + 2
  local nvis = math.max(1, math.floor((h - L.rh - 2) / L.rh))
  -- две колонки, если влезают: имя | привязка | режим
  local colw = w
  local ncol = (w >= L.cw * 76 and #MM.TARGETS > nvis) and 2 or 1
  local per = nvis * ncol
  -- 8 окт: не влезают — справа скроллбар (тянуть, колесо), колонки уже на его ширину
  local sbw = (#MM.TARGETS > per and MM.vbar) and 6 or 0
  colw = math.floor((w - sbw) / ncol)
  MM.per = per
  if MM.cur - 1 < MM.scroll then MM.scroll = MM.cur - 1 end
  if MM.cur - 1 >= MM.scroll + per then MM.scroll = MM.cur - per end
  local name_w = math.min(U.measure('transients ') + L.pad, math.floor(colw * 0.34))
  local mode_w = U.measure('rel64') + 2 * L.pad
  for slot = 0, per - 1 do
    local i = MM.scroll + slot + 1
    local t = MM.TARGETS[i]
    if not t then break end
    local cx = x + math.floor(slot / nvis) * colw
    local ry = top + (slot % nvis) * L.rh
    local b = MM.binds[t.id]
    local sel = i == MM.cur
    local lrn = MM.learning == t.id
    local hot = mx >= cx and mx < cx + colw - L.pad and my >= ry and my < ry + L.rh
    if lrn then U.set(U.tint(U.AMBER, 0.35)); gfx.rect(cx, ry, colw - L.pad, L.rh, 1)
    elseif sel then U.set(focused and U.tint(U.AMBER, 0.22) or U.LINE); gfx.rect(cx, ry, colw - L.pad, L.rh, 1)
    elseif hot then U.set(U.tint(U.TEXT, 0.08)); gfx.rect(cx, ry, colw - L.pad, L.rh, 1) end
    local kc = t.kind == 'value' and U.CYAN or (t.kind == 'pads' and U.AMBER or U.TEXT)
    U.text(cx + L.pad, ry + 1, fit(t.label, name_w - L.pad), (sel or lrn) and U.AMBER or kc)
    local bx = cx + name_w + L.pad
    local bw = colw - name_w - mode_w - 3 * L.pad
    local bt = lrn and 'waiting...' or (b and (MM.bind_text(b) .. (t.kind == 'pads' and '+' or '') .. ((b.dev and b.dev ~= '') and ('  ' .. b.dev) or '')) or '-')
    U.text(bx, ry + 1, fit(bt, bw), b and U.TEXT or U.DIM)
    if b and b.kind == 'cc' and t.kind == 'value' then
      local mxx = cx + colw - L.pad - mode_w
      U.text(mxx + L.pad, ry + 1, b.mode or 'abs', (b.mode or 'abs') ~= 'abs' and U.CYAN or U.GREY)
      if hot and mx >= mxx then hover = { row = i, btn = 'mode' } end
    end
    if hot and not hover then hover = { row = i, btn = 'learn' } end
    if MM.hint then MM.hint('midirow', cx, ry, colw - L.pad, L.rh, i) end
  end
  if sbw > 0 then MM.vbar('midimap', x + w - sbw, top, sbw, nvis * L.rh, MM.scroll, per, #MM.TARGETS) end
  return hover
end

return MM
