-- jf_tracker_slxpanel.lua — пульт jf_slixer в DSP трекера, 1 в 1 с окном плагина (25 окт).
-- Сверху три ряда кнопок (SLICE / SYNC + MIDI / ARP + out + ARTIC) с буквами клавиш, под ними
-- полоса-обзор, волна как в слайсере трекера (янтарные срезы, hex сверху, клавиша и нота снизу,
-- колесо — зум к мыши), под волной пэды. Данные — вид slixer из gmem (ctx.slixer_view),
-- действия — hover.slx = { what, arg, kind } (обработчик — ctx.slx_do в jf_tracker.lua).
-- SX.rows(...) — сколько строк займут кнопки при ширине w (без рисования, для раскладки модуля).

local SX = {}

-- кнопки: kind = act (действие), tog (вкл / выкл), menu (выпадашка), val (число, колесо), zone (подпись группы)
-- src: p = параметр плагина по имени, op = команда slixer (TRKV+6100), press = клавиша окна, tr = трекер
function SX.items(v, P)
  local function pv(name) return P(name) end
  local slm = pv('Slice mode') or 0
  local qg = pv('Input quantize') or 0
  local QN = { 'off', '1/32', '1/16T', '1/16', '1/8T', '1/8', '1/4' }
  local ar = pv('ARP: rate') or 3
  local AR = { '1/1', '1/2', '1/4', '1/8', '1/8T', '1/16', '1/32' }
  local ao = pv('ARP: order') or 0
  local AO = { 'up', 'down', 'up-down', 'random', 'played' }
  local ap = pv('Pedal role') or 0
  local AP = { 'thru', 'hold', 'latch' }
  local om = pv('Output routing') or 0
  local OM = { 'mix', 'class', 'slice' }
  local km = v and v.kmode or 1
  local KM = { 'chrom', 'piano', 'class' }
  local sy = v and v.sync or 0
  local SY = { 'off', 'pitch', 'str' }
  local rows = {
    {
      { kind = 'zone', lab = 'SLICE' },
      { kind = 'act', lab = 'detect', key = 'd', what = 'detect' },
      { kind = 'menu', lab = 'm: ' .. ({ 'transient', 'equal', 'pitch' })[math.floor(slm + 0.5) + 1], key = 'm', src = 'p', name = 'Slice mode', items = { 'transient', 'equal', 'pitch' } },
      { kind = 'val', lab = 'sens', val = ('%.2f'):format(pv('Transient sensitivity') or 0.5), src = 'p', name = 'Transient sensitivity', step = 0.05, lo = 0.05, hi = 1 },
      { kind = 'act', lab = 'classify', key = 'c', src = 'press' },
      { kind = 'tog', lab = 'auto', key = 'a', on = v and v.auto, src = 'op', code = 4 },
      { kind = 'act', lab = 'clear', key = 'x', src = 'op', code = 3 },
      { kind = 'act', lab = 'gate', key = 'g', src = 'press' },
      { kind = 'tog', lab = 'q: trans', key = 'r', on = (pv('Q by transients') or 0) > 0.5, src = 'p', name = 'Q by transients' },
      { kind = 'act', lab = 'undo', key = 'z', src = 'press' },
      { kind = 'act', lab = 'midi', key = 'e', src = 'press' },
      { kind = 'act', lab = 'names', key = 'n', src = 'press' },
    },
    {
      { kind = 'zone', lab = 'SYNC' },
      { kind = 'tog', lab = 'thru', key = 't', on = (pv('Playthrough') or 0) > 0.5, src = 'p', name = 'Playthrough' },
      { kind = 'menu', lab = 'sync: ' .. SY[sy + 1], key = 's', on = sy > 0, src = 'op', code = 6, items = SY },
      { kind = 'menu', lab = 'q: ' .. QN[math.floor(qg + 0.5) + 1], key = 'q', on = qg > 0.5, src = 'p', name = 'Input quantize', items = QN },
      { kind = 'zone', lab = 'MIDI' },
      { kind = 'menu', lab = KM[km + 1] or 'piano', key = 'p', on = km > 0, src = 'op', code = 9, items = KM },
      { kind = 'tog', lab = 'tala', on = (pv('Tala browser and map') or 0) > 0.5, src = 'p', name = 'Tala browser and map' },
      { kind = 'tog', lab = 'keys', key = 'k', on = v and v.keys, src = 'op', code = 5 },
      { kind = 'tog', lab = 'vel', key = 'v', on = (pv('VEL: ignore incoming velocity') or 0) > 0.5, src = 'p', name = 'VEL: ignore incoming velocity' },
      { kind = 'val', lab = 'ch', val = (function() local c = math.floor((pv('MIDI channel (0=omni)') or 0) + 0.5); return c == 0 and 'omni' or tostring(c) end)(), src = 'p', name = 'MIDI channel (0=omni)', step = 1, lo = 0, hi = 16 },
      { kind = 'val', lab = 'bas', val = tostring(math.floor((pv('Base note') or 24) + 0.5)), src = 'p', name = 'Base note', step = 1, lo = 0, hi = 127 },
    },
    {
      { kind = 'zone', lab = 'ARP' },
      { kind = 'tog', lab = 'arp', key = 'b', on = (pv('ARP: on') or 0) > 0.5, src = 'p', name = 'ARP: on' },
      { kind = 'menu', lab = AR[math.floor(ar + 0.5) + 1] or '1/8', src = 'p', name = 'ARP: rate', items = AR },
      { kind = 'menu', lab = AO[math.floor(ao + 0.5) + 1] or 'up', src = 'p', name = 'ARP: order', items = AO },
      { kind = 'menu', lab = 'ped: ' .. (AP[math.floor(ap + 0.5) + 1] or 'thru'), on = ap > 0.5, src = 'p', name = 'Pedal role', items = AP },
      { kind = 'val', lab = 'gate', val = ('%d%%'):format(math.floor((pv('ARP: gate (note length)') or 0.5) * 100 + 0.5)), src = 'p', name = 'ARP: gate (note length)', step = 0.05, lo = 0.05, hi = 1 },
      { kind = 'menu', lab = 'out: ' .. OM[math.floor(om + 0.5) + 1], key = 'o', on = om > 0.5, src = 'p', name = 'Output routing', items = OM },
      { kind = 'zone', lab = 'ARTIC' },
    },
  }
  local NM = { 'arp', 'soft', 'stac' }
  for i = 1, 8 do
    local used = v and v.artused and v.artused[i]
    local lab = (used and NM[i]) or tostring(i)
    rows[3][#rows[3] + 1] = { kind = 'tog', lab = lab, key = lab ~= tostring(i) and tostring(i) or nil, on = v and v.art == i - 1, src = 'op', code = 7, arg = i - 1 }   -- пустой слот: цифра и есть клавиша
  end
  return rows
end

local function bw_of(it, ms, pad)
  local w = ms(it.lab) + 2 * pad
  if it.key then w = w + ms(it.key) + 3 end
  if it.kind == 'val' then w = w + ms(' ' .. (it.val or '')) end
  if it.kind == 'menu' then w = w + 7 end
  return w
end

-- раскладка кнопок: { {x, y, w, it}, ... } и число строк; переносит, если не влезает
function SX.layout(rows, x0, y0, w, rh, ms, pad)
  local out, y, nrow = {}, y0, 0
  for _, row in ipairs(rows) do
    local x = x0
    nrow = nrow + 1
    for _, it in ipairs(row) do
      local bw = it.kind == 'zone' and (ms(it.lab) + 2 * pad) or bw_of(it, ms, pad)
      if x > x0 and x + bw > x0 + w then x = x0; y = y + rh; nrow = nrow + 1 end
      out[#out + 1] = { x = x, y = y, w = bw, it = it }
      x = x + bw + (it.kind == 'zone' and 0 or 2)
    end
    y = y + rh
  end
  return out, nrow
end

-- рисование кнопок; hover → { it = …, x, y, w }
function SX.draw_buttons(U, L, lay, text, ms, set, mx, my, drag)
  local hv
  local th = L.th or (L.rh - 2)
  for _, b in ipairs(lay) do
    local it, x, y, w = b.it, b.x, b.y, b.w
    local h = L.rh - 1
    local ty = y + math.floor((h - th) / 2) - (U.SPACE or 0)
    if it.kind == 'zone' then
      local zc = ({ SLICE = U.AMBER, SYNC = U.GREEN, MIDI = U.CYAN, ARP = U.AMBER, ARTIC = U.GREEN })[it.lab] or U.GREY
      text(x + L.pad, ty, it.lab, zc)
    else
      local hot = not drag and mx >= x and mx < x + w and my >= y and my < y + h
      local on = it.on
      set(on and U.tint(U.AMBER, 0.55) or (hot and U.tint(U.AMBER, 0.25) or U.BG)); gfx.rect(x, y, w, h, 1)
      set(hot and U.AMBER or (on and U.AMBER or U.LINE)); gfx.rect(x, y, w, h, 0)
      local tc = on and U.BG or (hot and U.AMBER or U.TEXT)
      local tx = x + L.pad
      text(tx, ty, it.lab, tc); tx = tx + ms(it.lab)
      if it.kind == 'val' then text(tx, ty, ' ' .. (it.val or ''), on and U.BG or U.CYAN); tx = tx + ms(' ' .. (it.val or '')) end
      if it.key then text(tx + 3, ty, it.key, on and U.BG or U.AMBER); tx = tx + 3 + ms(it.key) end
      if it.kind == 'menu' then
        set(tc); local ax, ay = x + w - 7, y + math.floor(h / 2) - 1
        gfx.triangle(ax, ay, ax + 4, ay, ax + 2, ay + 3)
      end
      if hot then hv = { it = it, x = x, y = y, w = w, h = h } end
    end
  end
  return hv
end

-- волна как слайсер трекера: полоса-обзор + основная; zst = { f0, fn } (окно зума в кадрах, на модуль)
-- 26 окт: пэдов нет — срез на волне сам интерактивный: под мышью светлее, у границы — ручка
-- (hv.edge = номер среза, чью начальную границу тянуть); dr = { edge, frame } — граница в протяжке
function SX.draw_wave(U, L, v, x, y, w, ovh, wh, text, ms, set, mx, my, zst, drag, dr)
  local hv
  local fr = v and v.frames or 0
  set(U.mix(U.BG, U.PANEL, 0.5)); gfx.rect(x, y, w, ovh, 1)
  local wy = y + ovh + 1
  set(U.PANEL); gfx.rect(x, wy, w, wh, 1)
  if not (fr and fr > 0) then return nil end
  local pk = v.peaks
  local f0, fn = 0, fr
  if zst and zst.fn and zst.fn > 0 and zst.fn < fr then f0, fn = zst.f0 or 0, zst.fn end
  local function peak_at(a, b)   -- кадры a..b → макс / мин по пикам (512 бинов на всю деку)
    if not (pk and (pk.n or 0) > 0) then return 0, 0 end
    local i0 = math.max(1, math.floor(a / fr * pk.n) + 1)
    local i1 = math.max(i0, math.min(pk.n, math.floor(b / fr * pk.n) + 1))
    local mxv, mnv = -1, 1
    for i = i0, i1 do mxv = math.max(mxv, pk.max[i] or 0); mnv = math.min(mnv, pk.min[i] or 0) end
    return mxv, mnv
  end
  -- обзор
  local oc, oh = y + ovh / 2, ovh / 2 - 1
  set(U.GREY)
  for px = 0, w - 1 do
    local a, b = peak_at(px / w * fr, (px + 1) / w * fr)
    if a < b then a, b = 0.005, -0.005 end
    gfx.line(x + px, oc - math.min(1, a) * oh, x + px, oc - math.max(-1, b) * oh)
  end
  if fn < fr then
    local ax, bx2 = x + f0 / fr * w, x + (f0 + fn) / fr * w
    set(U.AMBER); gfx.rect(ax, y, math.max(1, bx2 - ax), ovh, 0)
  end
  -- основная
  local function xof(p) return x + (p - f0) / fn * w end
  local starts = v.starts
  if dr and dr.edge and starts[dr.edge] then
    starts = {}
    for i = 1, v.nsl do starts[i] = v.starts[i] end
    starts[dr.edge] = dr.frame
  end
  local function endof(i) return i < v.nsl and starts[i + 1] or (v.ends[i] or fr) end
  local inw = not drag and mx >= x and mx < x + w and my >= wy and my < wy + wh
  local fpos = f0 + (mx - x) / w * fn
  local hs, he = -1, nil   -- срез под мышью; граница рядом (±4 px, кроме первой)
  if inw then
    for i = 1, v.nsl do
      if fpos >= (starts[i] or 0) then hs = i - 1 end
      if i > 1 and math.abs(xof(starts[i] or 0) - mx) <= 4 then he = i end
    end
  end
  local sel = v.sel
  if sel and sel >= 0 and starts[sel + 1] then
    local a, b = math.max(x, xof(starts[sel + 1])), math.min(x + w, xof(endof(sel + 1)))
    if b > a then set(U.tint(U.AMBER, 0.14)); gfx.rect(a, wy, b - a, wh, 1) end
  end
  if hs >= 0 and not he and hs ~= sel then
    local a, b = math.max(x, xof(starts[hs + 1])), math.min(x + w, xof(endof(hs + 1)))
    if b > a then set(U.tint(U.TEXT, 0.06)); gfx.rect(a, wy, b - a, wh, 1) end
  end
  local cy, hh = wy + wh / 2, wh / 2 - 1
  set(U.GREY)
  for px = 0, w - 1 do
    local a, b = peak_at(f0 + px / w * fn, f0 + (px + 1) / w * fn)
    if a < b then a, b = 0.005, -0.005 end
    gfx.line(x + px, cy - math.min(1, a) * hh, x + px, cy - math.max(-1, b) * hh)
  end
  local th = L.th or (L.rh - 2)
  local NN = { 'C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-' }
  for i = 1, v.nsl do
    local sx = xof(starts[i] or 0)
    local ex = i < v.nsl and xof(starts[i + 1] or fr) or (x + w)
    if sx >= x - 1 and sx <= x + w then
      local grab = he == i or (dr and dr.edge == i)
      set(grab and U.TEXT or U.AMBER); gfx.rect(math.floor(sx) - (grab and 1 or 0), wy, (grab or i - 1 == sel) and 2 or 1, wh, 1)
      local room = math.min(ex, x + w) - sx
      local lb = ('%02X'):format(i)
      if ms(lb) + 4 < room then text(sx + 3, wy + 1, lb, U.AMBER) end
      local n = v.notes and v.notes[i]
      if n and n >= 0 then
        local nm = NN[n % 12 + 1] .. math.floor(n / 12)
        if ms(nm) + 4 < room then text(sx + 3, wy + wh - th - 1, nm, U.GREY) end
      end
    end
  end
  set(U.GREEN)
  for _, p in ipairs(v.voices or {}) do local px = xof(p); if px >= x and px < x + w then gfx.rect(px, wy, 1, wh, 1) end end
  if not drag and mx >= x and mx < x + w and my >= y and my < wy + wh then
    hv = { over = my < wy and 'overview' or 'wave', slice = hs, edge = he, frame = fpos, fr = fr, f0 = f0, fn = fn, x = x, w = w }
  end
  return hv
end

return SX
