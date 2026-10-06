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
  -- 5 окт: остальное из окна свойств item REAPER (позиция у сэмпла lib не нужна)
  { k = 'finshape', label = 'fade in shape' }, { k = 'foutshape', label = 'fade out shape' },
  { k = 'tvol', label = 'take volume' }, { k = 'offs', label = 'start offset' }, { k = 'len', label = 'length' },
  { k = 'snap', label = 'snap offset' }, { k = 'chan', label = 'channels' },
  { k = 'mute', label = 'mute' }, { k = 'lock', label = 'lock' },
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
  if ctx.sp_raw then return (ctx.sp_raw(e, k)) or '' end
  return ''
end

-- ширина, которую свойства реально займут (5 окт): высокая панель — все строки
-- в одной-двух колонках, остаток отдаётся волне (не пустое место справа)
function SP.fit_w(L, w, h)
  local per = math.max(1, math.floor((h - L.rh) / L.rh))
  local ncols = math.max(1, math.floor((w + L.pad) / math.min(w, L.cw * 36)))
  local colw = math.floor((w + L.pad) / ncols)
  local need = math.min(ncols, math.ceil(#SP.ROWS / per))
  return math.min(w, need * colw)
end
function SP.draw(L, x, y, w, h, e, focused)
  SP.hover = nil
  SP.slider = nil
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
  -- кнопка v (5 окт): раскрыть верхнюю панель так, чтобы все свойства влезли
  local per0 = math.max(1, math.floor((h - L.rh) / L.rh))
  local nc0 = math.max(1, math.floor((w + L.pad) / math.min(w, L.cw * 36)))
  local overflow = #SP.ROWS > per0 * nc0
  local vbw = overflow and (U.measure('v') + 2 * L.pad) or 0
  if overflow then
    local bx = x + w - vbw
    local vh = tmx >= bx and tmx < bx + vbw and tmy >= y and tmy < y + L.rh
    U.set(vh and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, y, vbw, L.rh, 1)
    U.set(vh and U.AMBER or U.LINE); gfx.rect(bx, y, vbw, L.rh, 0)
    U.text(bx + L.pad, y, 'v', vh and U.AMBER or U.TEXT)
    if vh then SP.hover = { fit = true } end
  end
  U.text(x + L.pad, y, ctx.fit(title, w - L.pad - vbw - L.pad), U.AMBER)
  -- колонки (5 окт): широкая панель — строки сверху вниз, потом следующая
  -- колонка; ширина колонки как у прежней узкой панели, ничего не тянется
  local per = math.max(1, math.floor((h - L.rh) / L.rh))
  -- колонок столько, сколько влезает по ~36 символов; ширина — поровну (5 окт:
  -- последняя забирала весь остаток, у первой дорожки были узкие)
  -- не влезает — скролл-бар средней толщины справа (5 окт)
  local sbw = overflow and 7 or 0
  local wc = w - sbw - (overflow and 2 or 0)
  local ncols = math.max(1, math.floor((wc + L.pad) / math.min(wc, L.cw * 36)))
  local colw = math.floor((wc + L.pad) / ncols)
  local cap = per * ncols
  SP.scroll = SP.scroll or 0
  if SP.sel > SP.scroll + cap then SP.scroll = SP.sel - cap end
  if SP.sel <= SP.scroll then SP.scroll = SP.sel - 1 end
  SP.scroll = math.max(0, math.min(SP.scroll, math.max(0, #SP.ROWS - cap)))
  if overflow and ctx.vbar then ctx.vbar('sprops', x + w - sbw, y + L.rh, sbw, per * L.rh, SP.scroll, cap, #SP.ROWS) end
  local n = math.min(#SP.ROWS, SP.scroll + cap)
  -- колонка имён — по самому длинному имени (5 окт: пустое место до значений)
  local lw = 0
  for _, r in ipairs(SP.ROWS) do lw = math.max(lw, U.measure(r.label)) end
  lw = math.min(lw + 2 * L.pad, math.floor(colw * 0.45))
  if SP.sel > #SP.ROWS then SP.sel = #SP.ROWS end
  local x0, w0 = x, w
  for i = SP.scroll + 1, n do
    local r = SP.ROWS[i]
    local j = i - SP.scroll
    local ci = (j - 1) // per
    local x, w = x0 + ci * colw, colw - L.pad
    local ry = y + ((j - 1) % per + 1) * L.rh
    local sel = focused and i == SP.sel
    local hot0 = mx >= x and mx < x + w and my >= ry and my < ry + L.rh
    local foc = sel or hot0                                   -- 6 окт: фокус / мышь — имя, значение, дорожка жёлтым
    if sel then U.set(U.tint(U.AMBER, 0.25)); gfx.rect(x, ry, w, L.rh, 1)
    elseif hot0 then U.set(U.tint(U.AMBER, 0.12)); gfx.rect(x, ry, w, L.rh, 1) end
    U.text(x + L.pad, ry, ctx.fit(r.label, lw - L.pad), foc and U.AMBER or U.GREY)
    -- слайдер (5 окт): у чисел — дорожка между подписью и значением, тянуть мышью
    local vt = SP.value(e, r.k)
    local fr, centered = nil, false
    if ctx.sp_frac then fr, centered = ctx.sp_frac(e, r.k) end
    local vw = math.max(U.measure('-00.0 dB'), U.measure(vt)) + L.pad
    -- 5 окт: имя | значение | дорожка — значение сразу за именем
    local sx, sw = x + lw + vw, w - lw - vw - L.pad
    local hot = mx >= x and mx < x + w and my >= ry and my < ry + L.rh
    if fr and sw >= L.cw * 4 then
      local cy = ry + math.floor(L.rh / 2)
      local onbar = hot and mx >= sx - 2 and mx < sx + sw + 2
      U.set(U.DIM); gfx.rect(sx, cy - 1, sw, 2, 1)
      U.set((foc or onbar or (SP.drag and SP.drag.k == r.k)) and U.AMBER or U.TEXT)
      fr = math.max(0, math.min(1, fr))
      if centered then
        local mid, px = sx + math.floor(sw / 2), sx + math.floor(fr * sw + 0.5)
        gfx.rect(math.min(mid, px), ry + 4, math.max(1, math.abs(px - mid)), L.rh - 8, 1)
        U.set(U.LINE); gfx.rect(mid, ry + 3, 1, L.rh - 6, 1)
      else gfx.rect(sx, ry + 4, math.max(1, math.floor(fr * sw + 0.5)), L.rh - 8, 1) end
      -- метки привязки (rate: ×½ ×1.5 ×2 …) — чёрточки под дорожкой
      if ctx.sp_marks then
        U.set(U.GREY)
        for _, mf in ipairs(ctx.sp_marks(r.k) or {}) do gfx.rect(sx + math.floor(mf * sw + 0.5), ry + L.rh - 3, 1, 2, 1) end
      end
      U.text(x + lw, ry, vt, foc and U.AMBER or U.TEXT)
      if onbar then SP.slider = { k = r.k, x = sx, w = sw } end
    else
      U.text(x + lw, ry, ctx.fit(vt, w - lw - L.pad), foc and U.AMBER or U.TEXT)
    end
    if hot then SP.hover = { row = i, k = r.k, bar = SP.slider and SP.slider.k == r.k and SP.slider or nil } end
    if ctx.hint then ctx.hint('sprop', x, ry, w, L.rh, i) end
  end
end

-- список слайсов инструмента (4 окт, как семплы внутри инструмента Renoise):
-- строка 0 — весь сэмпл, дальше слайсы: клавиша, Sxx, длина; выбранный —
-- подсветка, без нот — тусклый. rows = { { k, len, key, has } }, sel = k.
-- Возвращает k под мышью (SP.slice_hover)
-- зум списка (5 окт): строки ×1 / ×2 / ×3 — превью (волна слайса, кривая
-- automation) крупнее; кнопка zoom в шапке списка
SP.szoom = 1
SP.zprev = 0
local function zoom_button(L, x, y, w)
  local lbl = SP.szoom > 1 and ('zoom x' .. SP.szoom) or 'zoom'
  local bw = U.measure(lbl) + 2 * L.pad
  local bx = x + w - bw
  local mx, my, cap = gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap
  local hot = mx >= bx and mx < bx + bw and my >= y and my < y + L.rh
  local press = cap & 1 == 1 and SP.zprev & 1 == 0
  SP.zprev = cap
  if hot and press then SP.szoom = SP.szoom % 3 + 1; SP.zoom_clicked = true end
  U.set(SP.szoom > 1 and U.tint(U.AMBER, 0.3) or (hot and U.PANEL or U.BG)); gfx.rect(bx, y, bw, L.rh, 1)
  U.set((hot or SP.szoom > 1) and U.AMBER or U.LINE); gfx.rect(bx, y, bw, L.rh, 0)
  U.text(bx + L.pad, y, lbl, (hot or SP.szoom > 1) and U.AMBER or U.GREY)
  SP.zoom_hot = hot
  return bw + L.pad
end

-- мини-волна куска [a, b) секунд item (пики всего item, своя часть)
local function mini_wave(e, a, b, x, y, w, h, col)
  if not (e and ctx.peaks) or w < 4 or h < 3 or (e.len or 0) <= 0 then return end
  local pk = ctx.peaks(e, 2048)
  if not (pk and pk.n and pk.n > 0) then return end
  local cy, hh = y + h / 2, h / 2
  U.set(col)
  for px = 0, w - 1 do
    local t = a + (b - a) * px / w
    local idx = math.max(1, math.min(pk.n, math.floor(t / e.len * pk.n) + 1))
    local lo, hi = pk.min[idx] or 0, pk.max[idx] or 0
    if hi - lo < 0.04 then lo, hi = -0.02, 0.02 end
    gfx.line(x + px, cy - hi * hh, x + px, cy - lo * hh)
  end
end

function SP.draw_slices(L, x, y, w, h, rows, sel, root)
  SP.slice_hover = nil
  local mx, my = gfx.mouse_x, gfx.mouse_y
  U.set(U.LINE); gfx.rect(x - 2, y, 1, h, 1)
  local zw = zoom_button(L, x, y, w)
  U.text(x + L.pad, y, ctx.fit(('slices %d'):format(math.max(0, #rows - 1)), w - L.pad - zw), U.AMBER)
  local RH = L.rh * SP.szoom
  -- подсказка клавиш (4 окт): только с опцией hints, нижней строкой
  local hints = ctx.state and ctx.state.hints
  local n = math.max(1, math.floor((h - L.rh - (hints and L.rh or 0)) / RH))
  if hints then U.text(x + L.pad, y + h - L.rh, ctx.fit('opt+j k: step', w - L.pad), U.DIM) end
  SP.slice_scroll = SP.slice_scroll or 0
  local si = 1
  for i, r in ipairs(rows) do if r.k == sel then si = i end end
  -- за выбором — только когда он сменился (полосой / колесом можно листать)
  if SP.slice_last ~= sel then
    SP.slice_last = sel
    if si - 1 < SP.slice_scroll then SP.slice_scroll = si - 1 end
    if si > SP.slice_scroll + n then SP.slice_scroll = si - n end
  end
  SP.slice_scroll = math.max(0, math.min(math.max(0, #rows - n), SP.slice_scroll))
  SP.slice_nvis = n
  for i = 1, n do
    local r = rows[SP.slice_scroll + i]
    if not r then break end
    local ry = y + L.rh + (i - 1) * RH
    local on = r.k == sel
    local hot = mx >= x and mx < x + w and my >= ry and my < ry + RH
    if on or hot then U.set(on and U.tint(U.AMBER, 0.3) or U.tint(U.AMBER, 0.15)); gfx.rect(x, ry, w, RH, 1) end
    local lbl = r.k == 0 and (('%s %s'):format(r.key or ' ', (r.name and r.name ~= '') and r.name or 'whole')) or (('%s S%02X'):format(r.key or ' ', r.k))
    local lt = r.len < 10 and ('%.2fs'):format(r.len) or ('%.1fs'):format(r.len)
    U.text(x + L.pad, ry, ctx.fit(lbl, w - U.measure(lt) - 3 * L.pad), on and U.AMBER or ((r.has or r.k == 0) and U.TEXT or U.GREY))
    U.text(x + w - L.pad - U.measure(lt), ry, lt, U.GREY)
    -- зум: волна куска строкой ниже подписи
    if SP.szoom > 1 and root and r.t0 then
      mini_wave(root, r.t0, r.t0 + r.len, x + L.pad, ry + L.rh, w - 2 * L.pad, RH - L.rh - 2, on and U.AMBER or U.mix(U.TEXT, U.BG, 0.3))
    end
    if hot then SP.slice_hover = r.k end
    if ctx.hint then ctx.hint('slice', x, ry, w, RH, r.k) end      -- метка f (5 окт)
  end
  return SP.slice_hover
end

-- automation как инструмент (5 окт): пулы automation items трека — подпись,
-- мини-линия кривой, длина; выбранный подсвечен. Возвращает номер под мышью
function SP.draw_ai(L, x, y, w, h, list, sel)
  SP.slice_hover = nil
  local mx, my = gfx.mouse_x, gfx.mouse_y
  U.set(U.PANEL); gfx.rect(x, y, w, h, 1)
  local zw = zoom_button(L, x, y, w)
  U.text(x + L.pad, y, ctx.fit(('automation %d'):format(#list), w - 2 * L.pad - zw), U.GREY)
  if #list == 0 then U.text(x + L.pad, y + L.rh, ctx.fit('no automation items on this track', w - 2 * L.pad), U.DIM); return nil end
  local RH = L.rh * SP.szoom
  local nvis = math.max(1, math.floor((h - L.rh) / RH))
  SP.slice_nvis = nvis
  SP.slice_scroll = math.max(0, math.min(SP.slice_scroll or 0, math.max(0, #list - nvis)))
  for r = SP.slice_scroll + 1, math.min(#list, SP.slice_scroll + nvis) do
    local a = list[r]
    local ry = y + L.rh + (r - SP.slice_scroll - 1) * RH
    local on = r == sel
    local hot = mx >= x and mx < x + w and my >= ry and my < ry + RH
    if on or hot then U.set(on and U.tint(U.AMBER, 0.3) or U.tint(U.AMBER, 0.15)); gfx.rect(x, ry, w, RH, 1) end
    local lt = (a.len or 0) < 10 and ('%.2fs'):format(a.len or 0) or ('%.1fs'):format(a.len or 0)
    local zoomed = SP.szoom > 1
    local lw = zoomed and (w - U.measure(lt) - 2 * L.pad) or math.floor(w * 0.45)
    U.text(x + L.pad, ry, ctx.fit(a.label or '', lw - L.pad), on and U.AMBER or U.TEXT)
    U.text(x + w - L.pad - U.measure(lt), ry, lt, U.GREY)
    -- мини-линия: точки пула, время и значение — по своим min / max; в зуме —
    -- под подписью во всю ширину
    local px0, pw, py0, ph
    if zoomed then px0, pw, py0, ph = x + L.pad, w - 2 * L.pad, ry + L.rh, RH - L.rh - 2
    else px0, pw, py0, ph = x + lw, w - lw - U.measure(lt) - 3 * L.pad, ry + 3, L.rh - 6 end
    local pts = a.pts or {}
    if pw > 8 and ph > 2 and #pts > 0 then
      local t0, t1, v0, v1 = math.huge, -math.huge, a.smin or a.min or math.huge, a.smax or a.max or -math.huge
      for _, p in ipairs(pts) do t0 = math.min(t0, p[1]); t1 = math.max(t1, p[1]); if not a.min then v0 = math.min(v0, p[2]); v1 = math.max(v1, p[2]) end end
      if t1 - t0 < 1e-9 then t1 = t0 + 1 end
      if v1 - v0 < 1e-9 then v1 = v0 + 1 end
      U.set(on and U.AMBER or U.CYAN)
      local lx, ly
      for _, p in ipairs(pts) do
        local qx = px0 + math.floor(math.max(0, math.min(1, (p[1] - t0) / (t1 - t0))) * (pw - 1))
        local qy = py0 + ph - 1 - math.floor(math.max(0, math.min(1, (p[2] - v0) / (v1 - v0))) * (ph - 1))
        if lx then gfx.line(lx, ly, qx, qy) end
        lx, ly = qx, qy
      end
    end
    if hot then SP.slice_hover = r end
    if ctx.hint then ctx.hint('slice', x, ry, w, RH, r) end
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
  -- 5 окт: j k — строка, h l — значение (как Vim); заглавные — то же
  if ch == 'J' or ch == 'j' then SP.sel = math.min(#SP.ROWS, SP.sel + 1)
  elseif ch == 'K' or ch == 'k' then SP.sel = math.max(1, SP.sel - 1)
  elseif ch == 'H' or ch == 'h' then if e then ctx.sp_adjust(e, SP.ROWS[SP.sel].k, -1) end
  elseif ch == 'L' or ch == 'l' then if e then ctx.sp_adjust(e, SP.ROWS[SP.sel].k, 1) end
  elseif ch == 'R' then if e then ctx.sp_reset(e, SP.ROWS[SP.sel].k) end
  else return false end
  return true
end

return SP
