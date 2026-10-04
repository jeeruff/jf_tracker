-- jf_tracker_sampleprops.lua — панель свойств сэмпла справа от волны
-- (вкладка Sample, 2 окт; как свойства сэмпла в Renoise, но всё нативное:
-- item и take REAPER). Правит выбранный в списке инструментов элемент:
-- исходный сэмпл или конкретный слайс / кусок (ребёнок в дереве).
--
-- Строки: volume, pan, transpose, finetune, rate, beatsync, keep pitch, stretch
-- (алгоритм I_PITCHMODE), loop, fade in, fade out, take fx, normalize.
-- Клавиши (вкладка Sample в фокусе): J / K строка, H / L значение − / +
-- (тоггл, цикл алгоритмов, открыть take FX, нормализовать), R сброс.
-- Мышь: клик — строка, колесо — значение, двойной клик — сброс / действие.
-- Без reaper.*: значения из записи пула, правка через ctx.sp_adjust / sp_reset.

local SP = { sel = 1, hover = nil }
local U, ctx

SP.ROWS = {
  { k = 'vol', label = 'volume' }, { k = 'pan', label = 'pan' },
  { k = 'st', label = 'transpose' }, { k = 'cent', label = 'finetune' },
  { k = 'rate', label = 'rate' }, { k = 'bsync', label = 'beatsync' }, { k = 'ppitch', label = 'keep pitch' },
  { k = 'mode', label = 'stretch' }, { k = 'loop', label = 'loop' },
  { k = 'fin', label = 'fade in' }, { k = 'fout', label = 'fade out' },
  { k = 'fx', label = 'take fx' }, { k = 'norm', label = 'normalize' },
}

function SP.init(u, c) U, ctx = u, c end

local function pan_txt(p) if math.abs(p or 0) < 0.005 then return 'C' end; return ((p < 0) and 'L' or 'R') .. math.floor(math.abs(p) * 100 + 0.5) end

function SP.value(e, k)
  if k == 'vol' then local v = e.vol or 1; return v > 1e-6 and ('%+.1f dB'):format(20 * math.log(v, 10)) or '-inf' end
  if k == 'pan' then return pan_txt(e.tpan) end
  local p = e.pitch or 0
  local st = math.floor(p + 0.5)
  if k == 'st' then return ('%+d st'):format(st) end
  if k == 'cent' then return ('%+d ct'):format(math.floor((p - st) * 100 + 0.5)) end
  if k == 'rate' then return ('%.3f'):format(e.rate or 1) .. (e.bsync and ' (bsync)' or '') end
  if k == 'bsync' then return e.bsync and ('%d beats (wheel, R: off)'):format(e.bsync) or 'off (L: on)' end
  if k == 'ppitch' then return e.ppitch and 'on' or 'off' end
  if k == 'mode' then return ctx.pitch_mode_name(e.pmode or -1) end
  if k == 'loop' then return e.loop and 'on' or 'off' end
  if k == 'fin' then return ('%d ms'):format(math.floor((e.fin or 0) * 1000 + 0.5)) end
  if k == 'fout' then return ('%d ms'):format(math.floor((e.fout or 0) * 1000 + 0.5)) end
  if k == 'fx' then return (e.nfx or 0) > 0 and (('%d: %s'):format(e.nfx, (e.fxnames or {})[1] or '')) or 'none (click: add, dbl: window)' end
  if k == 'norm' then return 'L: peak 0 dB' end
  return ''
end

function SP.draw(L, x, y, w, h, e, focused)
  SP.hover = nil
  local mx, my = gfx.mouse_x, gfx.mouse_y
  U.set(U.LINE); gfx.rect(x - 2, y, 1, h, 1)
  if not e or not e.item then
    U.text(x + L.pad, y, ctx.fit('properties: select an instrument', w - L.pad), U.GREY)
    return
  end
  local title = (e.depth or 0) > 0 and e.parent
    and (((e.slice_k and e.slice_k > 0) and ('s' .. e.slice_k) or 'cut') .. ' of ' .. e.parent.name)
    or e.name
  local tmx, tmy = gfx.mouse_x, gfx.mouse_y
  local thot = tmx >= x and tmx < x + w and tmy >= y and tmy < y + L.rh
  if thot then U.set(U.tint(U.AMBER, 0.2)); gfx.rect(x, y, w, L.rh, 1); SP.hover = { title = true, row = 0 } end
  U.text(x + L.pad, y, ctx.fit(title, w - L.pad), U.AMBER)
  local lw = math.floor(w * 0.45)
  local n = math.min(#SP.ROWS, math.floor((h - L.rh) / L.rh))
  if SP.sel > #SP.ROWS then SP.sel = #SP.ROWS end
  for i = 1, n do
    local r = SP.ROWS[i]
    local ry = y + i * L.rh
    local sel = focused and i == SP.sel
    if sel then U.set(U.tint(U.AMBER, 0.25)); gfx.rect(x, ry, w, L.rh, 1) end
    U.text(x + L.pad, ry, ctx.fit(r.label, lw - L.pad), sel and U.AMBER or U.GREY)
    U.text(x + lw, ry, ctx.fit(SP.value(e, r.k), w - lw - L.pad), U.TEXT)
    if mx >= x and mx < x + w and my >= ry and my < ry + L.rh then SP.hover = { row = i, k = r.k } end
    if ctx.hint then ctx.hint('sprop', x, ry, w, L.rh, i) end
  end
end

-- список слайсов инструмента (4 окт, как семплы внутри инструмента Renoise):
-- строка 0 — весь сэмпл, дальше слайсы: клавиша, Sxx, длина; выбранный —
-- подсветка, без нот — тусклый. rows = { { k, len, key, has } }, sel = k.
-- Возвращает k под мышью (SP.slice_hover)
function SP.draw_slices(L, x, y, w, h, rows, sel)
  SP.slice_hover = nil
  local mx, my = gfx.mouse_x, gfx.mouse_y
  U.set(U.LINE); gfx.rect(x - 2, y, 1, h, 1)
  U.text(x + L.pad, y, ctx.fit(('slices %d   opt+j k'):format(math.max(0, #rows - 1)), w - L.pad), U.AMBER)
  local n = math.max(1, math.floor((h - L.rh) / L.rh))
  SP.slice_scroll = SP.slice_scroll or 0
  local si = 1
  for i, r in ipairs(rows) do if r.k == sel then si = i end end
  if si - 1 < SP.slice_scroll then SP.slice_scroll = si - 1 end
  if si > SP.slice_scroll + n then SP.slice_scroll = si - n end
  for i = 1, n do
    local r = rows[SP.slice_scroll + i]
    if not r then break end
    local ry = y + i * L.rh
    local on = r.k == sel
    local hot = mx >= x and mx < x + w and my >= ry and my < ry + L.rh
    if on or hot then U.set(on and U.tint(U.AMBER, 0.3) or U.tint(U.AMBER, 0.15)); gfx.rect(x, ry, w, L.rh, 1) end
    local lbl = r.k == 0 and 'whole' or (('%s S%02X'):format(r.key or ' ', r.k))
    local lt = r.len < 10 and ('%.2fs'):format(r.len) or ('%.1fs'):format(r.len)
    U.text(x + L.pad, ry, ctx.fit(lbl, w - U.measure(lt) - 3 * L.pad), on and U.AMBER or ((r.has or r.k == 0) and U.TEXT or U.GREY))
    U.text(x + w - L.pad - U.measure(lt), ry, lt, U.GREY)
    if hot then SP.slice_hover = r.k end
  end
  return SP.slice_hover
end

-- информация о файле браузера (2 окт): вместо свойств, когда в модуле файл
-- info = { name, dir, rows = { {label, value} … } } — собирает main (ctx.file_info)
function SP.draw_info(L, x, y, w, h, info, playing)
  SP.hover = nil
  U.set(U.LINE); gfx.rect(x - 2, y, 1, h, 1)
  if not info then U.text(x + L.pad, y, ctx.fit('file: no info', w - L.pad), U.GREY); return end
  U.text(x + L.pad, y, ctx.fit((playing and '> ' or '') .. info.name, w - L.pad), playing and U.CYAN or U.AMBER)
  local lw = math.floor(w * 0.36)
  local n = math.floor((h - L.rh) / L.rh)
  for i = 1, math.min(n, #info.rows) do
    local r = info.rows[i]
    local ry = y + i * L.rh
    U.text(x + L.pad, ry, ctx.fit(r[1], lw - L.pad), U.GREY)
    U.text(x + lw, ry, ctx.fit(r[2], w - lw - L.pad), U.TEXT)
  end
end

-- клавиши; true — съедена
function SP.key(c, e)
  local ch = c < 256 and string.char(c) or ''
  if ch == 'J' then SP.sel = math.min(#SP.ROWS, SP.sel + 1)
  elseif ch == 'K' then SP.sel = math.max(1, SP.sel - 1)
  elseif ch == 'H' then if e then ctx.sp_adjust(e, SP.ROWS[SP.sel].k, -1) end
  elseif ch == 'L' then if e then ctx.sp_adjust(e, SP.ROWS[SP.sel].k, 1) end
  elseif ch == 'R' then if e then ctx.sp_reset(e, SP.ROWS[SP.sel].k) end
  else return false end
  return true
end

return SP
