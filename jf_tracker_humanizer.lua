-- jf_tracker_humanizer.lua — панель humanizer (19 окт): тонкая настройка «человечности».
--
-- Одна таблица диапазонов на всё: вставка нот (human при наборе) и макрос :human (уже стоящие ноты).
-- amount — общая доля (0..100 %), строки — диапазон каждого измерения при 100 % и галка вкл / выкл.
-- Клавиши: j k — строка, h l — значение (Shift — мелкий шаг), Space — вкл / выкл строки,
-- Enter — применить к выделению / треку в регионе (:human), i — human при вставке вкл / выкл, 0 — умолчания.
-- Без reaper.* — тест tests/test_humanizer.lua; хранение и применение — main (HU.encode / decode, ctx.hum_apply).

local HU = {}

HU.ROWS = {
  { k = 'amt',    label = 'amount',     min = 0, max = 100, step = 5,   fmt = '%d %%',     def = 0, noon = true },
  { k = 'time',   label = 'time ±',     min = 0, max = 50,  step = 1,   fmt = '%d ms',     def = 10 },
  { k = 'vel',    label = 'velocity ±', min = 0, max = 64,  step = 1,   fmt = '%d',        def = 12 },
  { k = 'vol',    label = 'volume ±',   min = 0, max = 6,   step = 0.1, fmt = '%.1f dB',   def = 1.5 },
  { k = 'pitch',  label = 'pitch ±',    min = 0, max = 50,  step = 1,   fmt = '%d ct',     def = 8 },
  { k = 'rate',   label = 'speed ±',    min = 0, max = 2,   step = 0.1, fmt = '%.1f %%',   def = 0.3 },
  { k = 'pan',    label = 'pan ±',      min = 0, max = 50,  step = 1,   fmt = '%d %%',     def = 10 },
  { k = 'attack', label = 'attack',     min = 0, max = 30,  step = 1,   fmt = '%d ms',     def = 6 },
  { k = 'len',    label = 'length ±',   min = 0, max = 20,  step = 1,   fmt = '%d %%',     def = 4 },
}
HU.sel = 1

-- состояние: { v = {k = число}, on = {k = bool}, ins = bool (human при вставке), dsp = { {name, track, fx, param, range %} } }
-- dsp (19 окт): точки вариации — параметры эффектов, которые humanizer чуть сдвигает на каждом шаге с нотой
-- (автоматизация ступенькой: текущее значение ± range × amount); хранятся в проекте (main)
function HU.defaults()
  local s = { v = {}, on = {}, ins = true, dsp = {} }
  for _, r in ipairs(HU.ROWS) do s.v[r.k] = r.def; s.on[r.k] = true end
  return s
end
function HU.encode(s)
  local o = {}
  for _, r in ipairs(HU.ROWS) do o[#o + 1] = ('%s=%g:%d'):format(r.k, s.v[r.k] or r.def, s.on[r.k] == false and 0 or 1) end
  o[#o + 1] = 'ins=' .. (s.ins == false and '0' or '1')
  return table.concat(o, ',')
end
function HU.decode(str)
  local s = HU.defaults()
  for k, v, on in (str or ''):gmatch('(%a+)=([%-%d%.]+):(%d)') do
    if s.v[k] ~= nil then s.v[k] = tonumber(v) or s.v[k]; s.on[k] = on ~= '0' end
  end
  local ins = (str or ''):match('ins=(%d)')
  if ins then s.ins = ins ~= '0' end
  return s
end

local function clamp(r, v) return math.max(r.min, math.min(r.max, v)) end
local function round(r, v) local q = 5 / r.step; return math.floor(v * q + 0.5) / q end   -- до мелкого шага (step / 5)

-- клавиша → 'apply' | 'changed' | 'leave' | true (съедена) | false (не наша)
-- строки панели: параметры, затем цели DSP (HU.sel > #ROWS — цель)
function HU.nrows(s) return #HU.ROWS + #(s.dsp or {}) end
function HU.key(s, c, shift)
  local ch = c > 0 and c < 256 and string.char(c) or ''
  local di = HU.sel - #HU.ROWS
  if ch == 'a' then return 'add' end
  if di >= 1 and s.dsp[di] then
    local t = s.dsp[di]
    if ch == 'x' or c == 8 then table.remove(s.dsp, di); HU.sel = math.min(HU.sel, HU.nrows(s)); return 'changed' end
    if ch == 'h' or ch == 'l' or ch == 'H' or ch == 'L' or c == 1818584692 or c == 1919379572 then
      local d = (ch == 'l' or ch == 'L' or c == 1919379572) and 1 or -1
      t.range = math.max(0, math.min(50, (t.range or 5) + d * ((shift or ch == 'H' or ch == 'L') and 0.2 or 1))); return 'changed'
    end
    if ch == ' ' then t.off = not t.off; return 'changed' end
  end
  local r = HU.ROWS[math.min(HU.sel, #HU.ROWS)]
  if ch == 'j' or c == 1685026670 then HU.sel = math.min(HU.nrows(s), HU.sel + 1); return true end
  if ch == 'k' or c == 30064 then HU.sel = math.max(1, HU.sel - 1); return true end
  if ch == 'g' then HU.sel = 1; return true end
  if ch == 'G' then HU.sel = HU.nrows(s); return true end
  if di >= 1 then return true end
  if ch == 'h' or ch == 'l' or ch == 'H' or ch == 'L' or c == 1818584692 or c == 1919379572 then
    local d = (ch == 'l' or ch == 'L' or c == 1919379572) and 1 or -1
    local st = (shift or ch == 'H' or ch == 'L') and r.step / 5 or r.step
    s.v[r.k] = round(r, clamp(r, (s.v[r.k] or r.def) + d * st)); return 'changed'
  end
  if ch == ' ' then
    if r.noon then s.ins = not s.ins else s.on[r.k] = not s.on[r.k] end
    return 'changed'
  end
  if ch == 'i' then s.ins = not s.ins; return 'changed' end
  if ch == '0' then local d = HU.defaults(); for k, v in pairs(d.v) do if k ~= 'amt' then s.v[k] = v; s.on[k] = true end end; return 'changed' end
  if c == 13 then return 'apply' end
  if c == 27 then return 'leave' end
  return false
end

-- значение строки по x мыши на слайдере
function HU.set_from_x(s, i, frac)
  local r = HU.ROWS[i]; if not r then return end
  s.v[r.k] = round(r, clamp(r, r.min + math.max(0, math.min(1, frac)) * (r.max - r.min)))
end

-- рисование: U — палитра (text / measure / dslider / set / tint), L — сетка (rh, pad, cw); возвращает hover
function HU.draw(U, L, s, x, y, w, h, focus, mx, my, ctx_fit)
  local hv = {}
  local rh, pad = L.rh, L.pad
  local lw = 0
  for _, r in ipairs(HU.ROWS) do lw = math.max(lw, U.measure(r.label)) end
  local vw = U.measure('00.0 dB')
  local bw = U.measure('[x]')
  local yy = y + 2
  U.text(x + pad, yy, 'humanizer', U.GREY)
  local ins = 'insert ' .. (s.ins and 'on' or 'off')
  local iw = U.measure(ins) + 2 * pad
  local ix = x + w - pad - iw
  local ihot = mx >= ix and mx < ix + iw and my >= yy and my < yy + rh
  U.set(s.ins and U.tint(U.CYAN, 0.25) or (ihot and U.tint(U.AMBER, 0.3) or U.BG)); gfx.rect(ix, yy, iw, rh - 1, 1)
  U.set(s.ins and U.CYAN or U.LINE); gfx.rect(ix, yy, iw, rh - 1, 0)
  U.text(ix + pad, yy, ins, ihot and U.AMBER or (s.ins and U.CYAN or U.GREY))
  if ihot then hv.ins = true end
  yy = yy + rh + 2
  for i, r in ipairs(HU.ROWS) do
    if yy + rh > y + h then break end
    local on = r.noon or s.on[r.k] ~= false
    local cur = focus and i == HU.sel
    local bx = x + pad
    if not r.noon then
      local bhot = mx >= bx and mx < bx + bw and my >= yy and my < yy + rh
      U.text(bx, yy, on and '[x]' or '[ ]', bhot and U.AMBER or (on and U.TEXT or U.DIM))
      if bhot then hv.toggle = i end
    end
    local lx = bx + bw + pad
    U.text(lx, yy, r.label, cur and U.AMBER or (on and U.TEXT or U.GREY))
    local sx = lx + lw + pad
    local sw = math.max(4 * L.cw, x + w - pad - vw - pad - sx)
    local v = s.v[r.k] or r.def
    local hot = mx >= sx - 2 and mx < sx + sw + 2 and my >= yy and my < yy + rh
    U.dslider(sx, yy + math.floor(rh / 2), sw, (v - r.min) / math.max(1e-9, r.max - r.min), false, (hot or cur) and U.AMBER or (on and U.TEXT or U.DIM), hot, rh)
    local vs = r.fmt:find('%%d') and r.fmt:format(math.floor(v + 0.5)) or r.fmt:format(v)   -- 21 окт: мелкий шаг (10.2) с %d ронял кадр
    U.text(x + w - pad - U.measure(vs), yy, vs, on and U.GREY or U.DIM)
    if hot then hv.slider = { i = i, x0 = sx, w = sw } end
    if mx >= x and mx < x + w and my >= yy and my < yy + rh then hv.row = i end
    yy = yy + rh
  end
  -- 19 окт: точки вариации DSP
  if yy + rh <= y + h then
    U.text(x + pad, yy, #(s.dsp or {}) > 0 and 'dsp variation' or 'dsp variation: a - add the parameter selected in DSP', U.GREY); yy = yy + rh
  end
  for di, t in ipairs(s.dsp or {}) do
    if yy + rh > y + h then break end
    local i = #HU.ROWS + di
    local cur = focus and i == HU.sel
    local bx = x + pad
    local bhot = mx >= bx and mx < bx + bw and my >= yy and my < yy + rh
    U.text(bx, yy, t.off and '[ ]' or '[x]', bhot and U.AMBER or (t.off and U.DIM or U.TEXT))
    if bhot then hv.dtoggle = di end
    local vs = ('±%.1f %%'):format(t.range or 5)
    local nx = bx + bw + pad
    U.text(nx, yy, ctx_fit and ctx_fit(t.name or '?', x + w - pad - U.measure(vs) - pad - nx) or (t.name or '?'), cur and U.AMBER or (t.off and U.GREY or U.TEXT))
    U.text(x + w - pad - U.measure(vs), yy, vs, t.off and U.DIM or U.GREY)
    if mx >= x and mx < x + w and my >= yy and my < yy + rh then hv.row = i end
    yy = yy + rh
  end
  if yy + rh <= y + h then
    local ap = 'apply (Enter)'
    local aw = U.measure(ap) + 2 * pad
    local ahot = mx >= x + pad and mx < x + pad + aw and my >= yy + 2 and my < yy + 2 + rh
    U.set(ahot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(x + pad, yy + 2, aw, rh - 1, 1)
    U.set(ahot and U.AMBER or U.LINE); gfx.rect(x + pad, yy + 2, aw, rh - 1, 0)
    U.text(x + 2 * pad, yy + 2, ap, ahot and U.AMBER or U.TEXT)
    if ahot then hv.apply = true end
    local hint = 'to the selection, else the track in the region'
    if x + 3 * pad + aw + U.measure(hint) <= x + w then U.text(x + 3 * pad + aw, yy + 2, hint, U.DIM) end
  end
  return hv
end

return HU
