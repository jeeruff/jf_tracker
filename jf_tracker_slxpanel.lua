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
  if v then v.wavecol = math.floor((pv('Waveform colours') or 0) + 0.5) end   -- 31 окт: draw_wave красит по нему
  local SY = { 'off', 'pitch', 'str' }
  local rows = {
    {
      -- 26 окт: подписи SLICE нет — и так ясно (кнопки нарезки первые)
      -- 31 окт: setup — как в окне плагина: цвет волны (peaks / brightness / spectral …) — пульт и колонка трекера
      { kind = 'menu', lab = 'setup', src = 'p', name = 'Waveform colours', items = { 'peaks', 'brightness by frequency', 'line', 'array', 'spectral colours' }, tip = 'setup: waveform colours - plain peaks, dark low / bright high, or spectral hues (the tracker wave column follows)' },
      { kind = 'act', lab = 'detect', key = 'd', what = 'detect', tip = 'find transients and cut there; moving sens re-runs it' },
      { kind = 'menu', lab = ({ 'transient', 'equal', 'pitch' })[math.floor(slm + 0.5) + 1], key = 't', src = 'p', name = 'Slice mode', items = { 'transient', 'equal', 'pitch' }, tip = 'slicing mode: transients (sens), equal parts, or pitch changes' },
      { kind = 'val', lab = 'sens', val = ('%.2f'):format(pv('Transient sensitivity') or 0.5), src = 'p', name = 'Transient sensitivity', step = 0.05, lo = 0.05, hi = 1, slider = true, raw = pv('Transient sensitivity') or 0.5, tip = 'transient sensitivity: more - more slices (detect re-runs when you let go)' },
      { kind = 'act', lab = 'classify', key = 'c', src = 'press', tip = 'guess each slice: kick / snare / hat / perc / crash / ride / voice / fx, and route to class buses' },
      { kind = 'tog', lab = 'auto', key = 'a', on = v and v.auto, src = 'op', code = 4, tip = 'slice automatically after loading' },
      { kind = 'act', lab = 'clear', key = 'x', src = 'op', code = 3, tip = 'remove every slice marker (the audio stays)' },
      { kind = 'act', lab = 'gate', key = 'g', src = 'press', tip = 'gate: mute the quiet slices (below the threshold)' },
      { kind = 'tog', lab = 'q: trans', key = 'r', on = (pv('Q by transients') or 0) > 0.5, src = 'p', name = 'Q by transients', tip = 'q: trans - incoming notes snap to the transients of the sample' },
      { kind = 'act', lab = 'undo', key = 'z', src = 'press', tip = 'undo the last slicing change' },
      { kind = 'act', lab = 'midi', key = 'e', src = 'press', tip = 'write the slice timing as a MIDI item on this track at the edit cursor' },
      { kind = 'act', lab = 'names', key = 'n', src = 'press', tip = 'write MIDI note names onto this track - the piano roll shows what each key does' },
      -- 26 окт: группы SYNC нет — sync (луп в темпе) здесь, к сэмплу; q — в MIDI, thru — в ARP
      { kind = 'menu', lab = 'sync: ' .. SY[sy + 1], key = 's', on = sy > 0, src = 'op', code = 6, items = SY, tip = 'fit the loop to whole beats at project tempo: pitch - repitch, str - granular stretch' },
    },
  }
  -- 26 окт: MIDI · ARP — под волной, как в окне плагина (SX.items отдаёт их вторым списком)
  local low = {
    {
      { kind = 'zone', lab = 'MIDI' },
      { kind = 'menu', lab = 'q: ' .. QN[math.floor(qg + 0.5) + 1], key = 'q', on = qg > 0.5, src = 'p', name = 'Input quantize', items = QN, tip = 'quantize incoming notes to the grid' },
      { kind = 'menu', lab = KM[km + 1] or 'piano', key = 'p', on = km > 0, src = 'op', code = 9, items = KM, tip = 'note layout: chromatic, piano (white keys), or by class' },
      { kind = 'tog', lab = 'vel', key = 'v', on = (pv('VEL: ignore incoming velocity') or 0) > 0.5, src = 'p', name = 'VEL: ignore incoming velocity', tip = 'vel: ignore incoming velocity (fixed level)' },
      { kind = 'val', lab = 'ch', val = (function() local c = math.floor((pv('MIDI channel (0=omni)') or 0) + 0.5); return c == 0 and 'omni' or tostring(c) end)(), src = 'p', name = 'MIDI channel (0=omni)', step = 1, lo = 0, hi = 16, tip = 'MIDI channel it listens to (omni - all)' },
      { kind = 'val', lab = 'root', val = (function()   -- 31 окт: root note — нотой (C-3), не числом
          local n = math.floor((pv('Base note') or 48) + 0.5)
          return ({ 'C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-' })[n % 12 + 1] .. (n // 12 - 1)
        end)(), src = 'p', name = 'Base note', step = 1, lo = 0, hi = 127, tip = 'root note: the note of slice 1 (default C-3 = 48); slice 2 - a semitone up, and so on' },
    },
  }
  -- 31 окт: STRETCH выбранного среза (и выделенных) — алгоритм, зерно, растяжение (заказ 13 экземпляру);
  -- своей колонкой в сетке параметров после LEVEL (третий список), не рядом под волной
  local st = (v and (v.st_alg or -1) >= 0) and (function()
      -- 31 окт: без выпадашек — алгоритм кнопками, растяжение и зерно слайдерами (протяжка / щелчок по дорожке, колесо)
      local SA = { 'grain', 'cycle', 'tape', 'cloud', 'sync' }
      local alg = math.floor(v.st_alg + 0.5)
      local rv, sv = v.st_ratio or 0.5, v.st_size or 0.5
      local out = { { kind = 'zone', lab = 'STRETCH' } }
      for k, nm in ipairs(SA) do
        out[#out + 1] = { kind = 'tog', lab = nm, on = alg == k - 1, src = 'op', code = 13, field = 1, arg = k - 1, tip = 'stretch algorithm of the selected slice(s): ' .. nm }
      end
      out[#out + 1] = { kind = 'val', lab = 'x', val = ('%.2f'):format(8 ^ (2 * rv - 1)), src = 'op', code = 13, field = 3, slider = true, raw = rv, lo = 0, hi = 1, step = 1 / 48,
        tip = 'stretch of the selected slice(s): x0.13 .. x8 (middle - x1), the pitch stays' }
      out[#out + 1] = { kind = 'val', lab = 'grain', val = ('%dms'):format(math.floor((0.02 + sv * 0.1) * 1000 + 0.5)), src = 'op', code = 13, field = 2, slider = true, raw = sv, lo = 0, hi = 1, step = 0.05,
        tip = 'grain size 20 .. 120 ms: short - buzzy and tight, long - smooth' }
      return out
    end)() or nil
  low[#low + 1] = {
      { kind = 'zone', lab = 'ARP' },
      { kind = 'tog', lab = 'arp', key = 'b', on = (pv('ARP: on') or 0) > 0.5, src = 'p', name = 'ARP: on' },
      { kind = 'tog', lab = 'thru', key = 'h', on = (pv('Playthrough') or 0) > 0.5, src = 'p', name = 'Playthrough' },
      { kind = 'menu', lab = AR[math.floor(ar + 0.5) + 1] or '1/8', src = 'p', name = 'ARP: rate', items = AR },
      { kind = 'menu', lab = AO[math.floor(ao + 0.5) + 1] or 'up', src = 'p', name = 'ARP: order', items = AO },
      { kind = 'menu', lab = 'ped: ' .. (AP[math.floor(ap + 0.5) + 1] or 'thru'), on = ap > 0.5, src = 'p', name = 'Pedal role', items = AP },
      { kind = 'val', lab = 'gate', val = ('%d%%'):format(math.floor((pv('ARP: gate (note length)') or 0.5) * 100 + 0.5)), src = 'p', name = 'ARP: gate (note length)', step = 0.05, lo = 0.05, hi = 1 },
      { kind = 'menu', lab = 'out: ' .. OM[math.floor(om + 0.5) + 1], key = 'o', on = om > 0.5, src = 'p', name = 'Output routing', items = OM },
    }
  -- 26 окт: в DSP — только нужное: ARTIC (артикуляторы), tala и keys (клавиатура — у трекера своя) — в окне плагина
  return rows, low, st
end

-- 26 окт: буква клавиши — частью слова (первая такая буква подписи); нет в подписи — дописана после
local function key_at(it)
  if not it.key then return nil end
  return it.lab:lower():find(it.key, 1, true)
end
SX.key_at = key_at
-- 31 окт: ширина кнопки не зависит от текущего значения (иначе «transient» → «pitch» менял ширину всего модуля):
-- меню — по самому длинному пункту, число — не уже 5 знаков
local function bw_of(it, ms, pad)
  local lab = it.lab
  if it.kind == 'menu' and it.items then for _, x in ipairs(it.items) do if ms(x) > ms(lab) then lab = x end end end
  local w = ms(lab) + 2 * pad
  if it.key and not key_at(it) then w = w + ms(it.key) + 3 end
  if it.kind == 'val' then w = w + math.max(ms(' ' .. (it.val or '')), ms(' 00.00')) end
  if it.slider then w = w + ms('WWWWW') + pad end   -- 27 окт: дорожка слайдера между подписью и числом
  if it.kind == 'menu' then w = w + 7 end
  return w
end

-- раскладка кнопок: { {x, y, w, it}, ... } и число строк. 26 окт: потоком — группы идут друг за другом
-- и переносятся по ширине (пустых хвостов у рядов нет, лишние строки уходят волне); подпись группы
-- не остаётся в конце строки — переносится вместе со своей первой кнопкой
function SX.layout(rows, x0, y0, w, rh, ms, pad)
  local flat = {}
  for _, row in ipairs(rows) do for _, it in ipairs(row) do flat[#flat + 1] = it end end
  local function wof(it) return it.kind == 'zone' and (ms(it.lab) + 2 * pad) or bw_of(it, ms, pad) end
  local out, x, y, nrow = {}, x0, y0, 1
  for i, it in ipairs(flat) do
    local bw = wof(it)
    local need = bw
    if it.kind == 'zone' and flat[i + 1] then need = bw + wof(flat[i + 1]) end
    if x > x0 and x + need > x0 + w then x = x0; y = y + rh; nrow = nrow + 1 end
    out[#out + 1] = { x = x, y = y, w = bw, it = it }
    x = x + bw + (it.kind == 'zone' and 0 or 2)
  end
  return out, nrow
end

-- 27 окт: естественная ширина пульта — самый длинный ряд кнопок (каждый ряд в одну строку)
function SX.natural_w(rows, ms, pad)
  local mw = 0
  for _, row in ipairs(rows or {}) do
    local x = 0
    for _, it in ipairs(row) do x = x + (it.kind == 'zone' and (ms(it.lab) + 2 * pad) or (bw_of(it, ms, pad) + 2)) end
    mw = math.max(mw, x)
  end
  return mw
end
-- 31 окт: курсор пульта — элемент, по которому щёлкнули (команды slixer — не параметры, у DSP-курсора их нет)
function SX.key_of(it) return (it.name or '') .. '|' .. (it.lab or '') .. '|' .. tostring(it.field or it.code or '') end
-- рисование кнопок; hover → { it = …, x, y, w }
function SX.draw_buttons(U, L, lay, text, ms, set, mx, my, drag)
  local hv
  local th = L.th or (L.rh - 2)
  for _, b in ipairs(lay) do
    local it, x, y, w = b.it, b.x, b.y, b.w
    local h = L.rh - 1
    local ty = y   -- 26 окт: как у кнопок трекера — от верха рамки (по центру высоты шрифта вылезало вниз)
    if it.kind == 'zone' then
      local zc = ({ SLICE = U.AMBER, SYNC = U.GREEN, MIDI = U.CYAN, ARP = U.AMBER, ARTIC = U.GREEN })[it.lab] or U.GREY
      text(x + L.pad, ty, it.lab, zc)
    else
      local hot = not drag and mx >= x and mx < x + w and my >= y and my < y + h
      local on = it.on
      set(on and U.tint(U.AMBER, 0.55) or (hot and U.tint(U.AMBER, 0.25) or U.BG)); gfx.rect(x, y, w, h, 1)
      set(hot and U.AMBER or (on and U.AMBER or U.LINE)); gfx.rect(x, y, w, h, 0)
      if SX.cur and SX.cur == SX.key_of(it) then   -- 31 окт: курсор пульта — двойная рамка и метка слева
        set(U.AMBER); gfx.rect(x - 1, y - 1, w + 2, h + 2, 0); gfx.rect(x - 2, y, 2, h, 1)
      end
      local tc = on and U.BG or (hot and U.AMBER or U.TEXT)
      local tx = x + L.pad
      text(tx, ty, it.lab, tc)
      local ki = key_at(it)
      if ki then
        local px = tx + ms(it.lab:sub(1, ki - 1))
        text(px, ty, it.lab:sub(ki, ki), on and U.BG or U.AMBER)
        if on then set(U.BG); gfx.rect(px, y + h - 3, ms(it.lab:sub(ki, ki)), 1, 1) end
      end
      tx = tx + ms(it.lab)
      local trk
      if it.slider then   -- 27 окт: слайдер, как в трекере: тонкая дорожка, заливка до значения
        local tw2 = ms('WWWWW')
        local sx0 = tx + L.pad
        local fr = math.max(0, math.min(1, ((it.raw or 0) - (it.lo or 0)) / math.max(1e-9, (it.hi or 1) - (it.lo or 0))))
        set(U.DIM); gfx.rect(sx0, y + math.floor(h / 2) - 1, tw2, 2, 1)
        set(hot and U.AMBER or U.TEXT); gfx.rect(sx0, y + 3, math.max(1, math.floor(tw2 * fr + 0.5)), h - 6, 1)
        trk = { x = sx0, w = tw2 }
        tx = sx0 + tw2
      end
      if it.kind == 'val' then text(tx, ty, ' ' .. (it.val or ''), on and U.BG or U.CYAN); tx = tx + ms(' ' .. (it.val or '')) end
      if it.key and not ki then text(tx + 3, ty, it.key, on and U.BG or U.AMBER); tx = tx + 3 + ms(it.key) end
      if it.kind == 'menu' then
        set(tc); local ax, ay = x + w - 7, y + math.floor(h / 2) - 1
        gfx.triangle(ax, ay, ax + 4, ay, ax + 2, ay + 3)
      end
      if hot then hv = { it = it, x = x, y = y, w = w, h = h, trk = trk } end
    end
  end
  return hv
end

-- волна как слайсер трекера: полоса-обзор + основная; zst = { f0, fn } (окно зума в кадрах, на модуль)
-- 26 окт: пэдов нет — срез на волне сам интерактивный: под мышью светлее, у границы — ручка
-- (hv.edge = номер среза, чью начальную границу тянуть); dr = { edge, frame } — граница в протяжке
-- 31 окт: цвет точки волны по спектральному центроиду (экспорт slixer +4100): 1 — тёмные низы / светлые верха,
-- 4 — оттенок (низ янтарь, середина зелень, верх голубой); иначе / тишина — nil (серый)
function SX.wave_rgb(mode, ctr)
  if not ctr or ctr < 0 then return nil end
  if mode == 1 then
    local t = math.min(1, ctr * 1.25)
    return 0.26 + 0.74 * t * t, 0.30 + 0.70 * t * t, 0.34 + 0.66 * t
  elseif mode == 4 then
    if ctr < 0.35 then local t = ctr / 0.35; return 1, 0.35 + 0.50 * t, 0.12
    elseif ctr < 0.6 then local t = (ctr - 0.35) / 0.25; return 1 - 0.65 * t, 0.90, 0.15 + 0.30 * t
    else local t = math.min(1, (ctr - 0.6) / 0.4); return 0.35 - 0.15 * t, 0.90 - 0.25 * t, 0.45 + 0.55 * t end
  end
end
function SX.draw_wave(U, L, v, x, y, w, ovh, wh, text, ms, set, mx, my, zst, drag, dr, wave_y)
  local hv
  local fr = v and v.frames or 0
  set(U.mix(U.BG, U.PANEL, 0.5)); gfx.rect(x, y, w, ovh, 1)
  local wy = wave_y or (y + ovh + 1)   -- 27 окт: волна может стоять ниже (между обзором и ней — прицел)
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
  -- 26 окт: плейхед заливкой — сыгранная часть звучащего среза ярко-жёлтая, стретч давлением к концу краснее
  local play = {}
  for k, p in ipairs(v.voices or {}) do
    local s0 = starts[(v.vslice[k] or -1) + 1]
    if s0 then play[#play + 1] = { a = math.min(s0, p), b = math.max(s0, p), s0 = s0, p = p, ats = (v.vats and v.vats[k]) or 0 } end
  end
  for px = 0, w - 1 do
    local fa, fb = f0 + px / w * fn, f0 + (px + 1) / w * fn
    local a, b = peak_at(fa, fb)
    if a < b then a, b = 0.005, -0.005 end
    local hit
    local fc = (fa + fb) / 2
    for _, q in ipairs(play) do if fc >= q.a and fc <= q.b then hit = q end end
    if hit then
      local t = math.abs(fc - hit.s0) / math.max(1, math.abs(hit.p - hit.s0)) * hit.ats
      gfx.set(1, 0.86 - 0.70 * t, 0.22 - 0.16 * t, 1)
    else
      local r, g, b2
      if pk and pk.ctr and (v.wavecol == 1 or v.wavecol == 4) then r, g, b2 = SX.wave_rgb(v.wavecol, pk.ctr[math.max(1, math.min(pk.n, math.floor(fc / fr * pk.n) + 1))]) end
      if r then gfx.set(r, g, b2, 1) else set(U.GREY) end
    end
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
      if ms(lb) + 4 < room then text(sx + 3, wy - 1, lb, U.AMBER) end   -- 28 окт: номер среза чуть выше
      local n = v.notes and v.notes[i]
      if n and n >= 0 then
        local nm = NN[n % 12 + 1] .. (math.floor(n / 12) - 1)   -- 31 окт: как в трекере (60 = C-4), было на октаву выше
        if ms(nm) + 4 < room then text(sx + 3, wy + wh - th - 3, nm, U.GREY) end   -- 26 окт: выше — низ букв не срезается
      end
    end
  end
  set(U.GREEN)
  for _, p in ipairs(v.voices or {}) do local px = xof(p); if px >= x and px < x + w then gfx.rect(px, wy, 1, wh, 1) end end
  if not drag and mx >= x and mx < x + w and ((my >= y and my < y + ovh) or (my >= wy and my < wy + wh)) then
    hv = { over = my < y + ovh and 'overview' or 'wave', slice = hs, edge = he, frame = fpos, fr = fr, f0 = f0, fn = fn, x = x, w = w }
  end
  return hv
end

-- 26 окт: прицел — снайперский зум у границы, как в слайсере трекера: окно ±W2 кадров вокруг края
-- A = { edge, center, w2 (кадров), pk = { max, min, n } (настоящие сэмплы slixer), spam, fine }
-- → hover { spam = true } | { aim = true, edge, base, span } (тянуть — точно двигать, колесо — шире / ближе)
function SX.draw_aim(U, L, v, x, y, w, h, text, ms, set, mx, my, A, drag)
  local hv
  set(U.BG); gfx.rect(x, y, w, h, 1)
  set(U.LINE); gfx.rect(x, y, w, h, 0)
  local fr = v and v.frames or 0
  if not (fr > 0 and A and A.edge) then
    text(x + 4, y + 1, 'aim: point at a slice edge (or select a slice) - its edge up close here', U.GREY)
    return nil
  end
  local span = 2 * A.w2
  local t0 = A.center - A.w2
  local function xof(p) return x + (p - t0) / span * w end
  local pk = A.pk
  local cy, hh = y + h / 2, h / 2 - 2
  if pk and pk.n > 0 then
    local amp = 0.02
    for i = 1, pk.n do amp = math.max(amp, math.abs(pk.max[i] or 0), math.abs(pk.min[i] or 0)) end
    set(U.mix(U.TEXT, U.BG, 0.25))
    if pk.n < w / 2 then   -- мало сэмплов на окно — линия через сэмплы
      local px0, py0
      for i = 1, pk.n do
        local xx, yy = x + (i - 0.5) / pk.n * w, cy - (pk.max[i] or 0) / amp * hh
        if px0 then gfx.line(px0, py0, xx, yy, 1) end
        px0, py0 = xx, yy
      end
    else
      for px = 0, w - 1 do
        local i = math.min(pk.n, math.floor(px / w * pk.n) + 1)
        gfx.line(x + px, cy - (pk.max[i] or 0) / amp * hh, x + px, cy - (pk.min[i] or 0) / amp * hh)
      end
    end
    if t0 < 0 then set(U.BG); gfx.rect(x + 1, y + 1, math.min(w - 2, xof(0) - x), h - 2, 1) end
    if t0 + span > fr then local ex = math.max(x + 1, xof(fr)); set(U.BG); gfx.rect(ex, y + 1, x + w - 1 - ex, h - 2, 1) end
  else text(x + 4, y + h - (L.th or L.rh) - 2, 'reading slixer...', U.GREY) end
  set(U.DIM); gfx.rect(x, math.floor(cy), w, 1, 1)
  for i = 1, v.nsl do   -- соседние границы — бирюзой, своя — янтарём
    local p = (i == A.edge and A.fine) and A.fine or v.starts[i]
    if p and p >= t0 and p <= t0 + span then
      local px = math.floor(xof(p))
      if i == A.edge then set(U.AMBER); gfx.rect(px, y, 2, h, 1) else set(U.CYAN); gfx.rect(px, y, 1, h, 1) end
    end
  end
  local sr = math.max(1, v.sr or 48000)
  local ep = A.fine or v.starts[A.edge] or 0
  local lb = ('slice %02X  %.4fs  ±%d ms'):format(A.edge, ep / sr, math.floor(A.w2 / sr * 1000 + 0.5))
  local spl = 'spam'
  local sw = ms(spl) + 2 * L.pad
  local sx, sy = x + w - sw - 2, y + 1
  set(U.BG); gfx.rect(x + 3, y + 1, ms(lb) + 2, L.rh - 1, 1)
  text(x + 4, y + 1, lb, U.GREY)
  local shot = not drag and mx >= sx and mx < sx + sw and my >= sy and my < sy + L.rh - 1
  set(A.spam and U.tint(U.CYAN, 0.3) or (shot and U.tint(U.AMBER, 0.3) or U.BG)); gfx.rect(sx, sy, sw, L.rh - 1, 1)
  set(A.spam and U.CYAN or (shot and U.AMBER or U.LINE)); gfx.rect(sx, sy, sw, L.rh - 1, 0)
  text(sx + L.pad, sy, spl, A.spam and U.CYAN or (shot and U.AMBER or U.TEXT))
  if shot then return { spam = true, x = sx, y = sy, w = sw } end
  if not drag and mx >= x and mx < x + w and my >= y and my < y + h then
    hv = { aim = true, edge = A.edge, base = v.starts[A.edge], span = span, x = x, w = w }
  end
  return hv
end

return SX
