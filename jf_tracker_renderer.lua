-- jf_tracker_renderer.lua — панель renderer (20 окт, gB): баунс нот в аудио и инструмент DSP → сэмплер.
--
-- notes   — выделенные ноты (VISUAL; иначе нота под курсором, иначе трек в регионе) звучат через FX трека
--           и ложатся аудио на новый трек под ним («<трек> bounce»), исходные ноты — по желанию заглушить.
-- sampler — инструмент трека играет ноты from..to шагом step, каждую в layers громкостях (velocity),
--           всё — одним рендером в файл; на новом треке «<инструмент> sampled» RS5K на каждый кусок:
--           своя зона нот (до середины к соседям), свой диапазон velocity (слои RS5K: Minimum / Maximum velocity),
--           высота от корня (режим note). Длина ноты len, хвост tail (затухание) — в каждом куске.
-- Клавиши: j k — строка, h l — значение (Shift — мелко), Space — переключатель, Enter — рендер, Esc — выйти,
-- 0 — умолчания. Без reaper.* — тест tests/test_renderer.lua; рендер — main (ctx.rd_render).

local RD = { sel = 1 }

local NN = { 'C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-' }
local function nname(n) n = math.floor(n + 0.5); return NN[n % 12 + 1] .. (n // 12 - 1) end
RD.nname = nname

RD.ROWS = {
  { k = 'mode',   label = 'what',       toggle = true, def = false, on = 'instrument -> sampler', off = 'notes -> audio' },
  { k = 'tail',   label = 'tail',       min = 0,   max = 8,   step = 0.1, fmt = '%.1f s', def = 1.0 },
  { k = 'mute',   label = 'mute source', toggle = true, def = false, only = 'notes' },
  { k = 'lo',     label = 'notes from', min = 0,   max = 127, step = 1,   note = true, def = 36, only = 'sampler' },
  { k = 'hi',     label = 'notes to',   min = 0,   max = 127, step = 1,   note = true, def = 84, only = 'sampler' },
  { k = 'step',   label = 'every',      min = 1,   max = 24,  step = 1,   fmt = '%d st', def = 3, only = 'sampler' },
  { k = 'layers', label = 'vel layers', min = 1,   max = 8,   step = 1,   fmt = '%d', def = 2, only = 'sampler' },
  { k = 'len',    label = 'note length', min = 0.1, max = 8,  step = 0.1, fmt = '%.1f s', def = 1.5, only = 'sampler' },
  { k = 'obey',   label = 'note-offs',  toggle = true, def = false, on = 'obey (sustain)', off = 'one shot', only = 'sampler' },
}

function RD.defaults()
  local p = {}
  for _, r in ipairs(RD.ROWS) do p[r.k] = r.def end
  return p
end
function RD.encode(p)
  local o = {}
  for _, r in ipairs(RD.ROWS) do
    local v = p[r.k]
    if r.toggle then v = v and 1 or 0 end
    o[#o + 1] = ('%s=%g'):format(r.k, v or 0)
  end
  return table.concat(o, ',')
end
function RD.decode(s)
  local p = RD.defaults()
  local by = {}
  for _, r in ipairs(RD.ROWS) do by[r.k] = r end
  for k, v in (s or ''):gmatch('(%a+)=([%-%d%.]+)') do
    local r = by[k]
    if r then
      if r.toggle then p[k] = v ~= '0' else p[k] = math.max(r.min, math.min(r.max, tonumber(v) or r.def)) end
    end
  end
  return p
end
-- строка нужна в этом режиме?
function RD.row_on(p, r) return not r.only or (r.only == 'sampler') == (p.mode == true) end

-- план сэмплера: { { note, vel, lo, hi, vlo, vhi, t0, t1 } … } — t в секундах от начала рендера
function RD.plan(p)
  local lo, hi = math.min(p.lo, p.hi), math.max(p.lo, p.hi)
  local st = math.max(1, math.floor(p.step + 0.5))
  local roots = {}
  for n = lo, hi, st do roots[#roots + 1] = n end
  if roots[#roots] ~= hi then roots[#roots + 1] = hi end
  local K = math.max(1, math.floor(p.layers + 0.5))
  local dur = p.len + p.tail
  local out = {}
  for i, n in ipairs(roots) do
    local zl = i == 1 and 0 or (math.floor((roots[i - 1] + n) / 2) + 1)
    local zh = i == #roots and 127 or math.floor((n + roots[i + 1]) / 2)
    for k = 1, K do
      local v = math.floor(127 * k / K + 0.5)
      local vlo = k == 1 and 1 or (math.floor(127 * (k - 1) / K + 0.5) + 1)
      local t0 = #out * dur
      out[#out + 1] = { note = n, vel = v, lo = zl, hi = zh, vlo = vlo, vhi = v, t0 = t0, t1 = t0 + dur }
    end
  end
  return out
end

local function clamp(r, v) return math.max(r.min, math.min(r.max, v)) end

-- клавиша → 'render' | 'changed' | 'leave' | true | false
function RD.key(p, c, shift)
  local ch = c > 0 and c < 256 and string.char(c) or ''
  local function move(d)
    local n, i = #RD.ROWS, RD.sel
    repeat i = math.max(1, math.min(n, i + d)) until RD.row_on(p, RD.ROWS[i]) or i == 1 or i == n
    if RD.row_on(p, RD.ROWS[i]) then RD.sel = i end
  end
  if not RD.row_on(p, RD.ROWS[RD.sel]) then RD.sel = 1 end
  local r = RD.ROWS[RD.sel]
  if ch == 'j' or c == 1685026670 then move(1); return true end
  if ch == 'k' or c == 30064 then move(-1); return true end
  if ch == 'g' then RD.sel = 1; return true end
  if c == 13 then return 'render' end
  if c == 27 then return 'leave' end
  if ch == '0' then local d = RD.defaults(); for k, v in pairs(d) do if k ~= 'mode' then p[k] = v end end; return 'changed' end
  if r.toggle then
    if ch == ' ' or ch == 'h' or ch == 'l' or c == 1818584692 or c == 1919379572 then p[r.k] = not p[r.k]; return 'changed' end
    return true
  end
  if ch == 'h' or ch == 'l' or ch == 'H' or ch == 'L' or c == 1818584692 or c == 1919379572 then
    local d = (ch == 'l' or ch == 'L' or c == 1919379572) and 1 or -1
    local st = r.step
    if shift or ch == 'H' or ch == 'L' then st = r.step < 1 and r.step / 5 or r.step
    elseif r.note then st = 12 end                    -- нота: h l — октава, Shift — полутон
    p[r.k] = clamp(r, (p[r.k] or r.def) + d * st)
    return 'changed'
  end
  return false
end

function RD.set_from_x(p, i, frac)
  local r = RD.ROWS[i]; if not r or r.toggle then return end
  local v = r.min + math.max(0, math.min(1, frac)) * (r.max - r.min)
  if r.step >= 1 then v = math.floor(v + 0.5) else v = math.floor(v / r.step + 0.5) * r.step end
  p[r.k] = clamp(r, v)
end

-- рисование; info = { track = имя трека, inst = инструмент или nil, n = нот выделено }
function RD.draw(U, L, p, info, x, y, w, h, focus, mx, my)
  local hv = {}
  local rh, pad = L.rh, L.pad
  local lw = 0
  for _, r in ipairs(RD.ROWS) do lw = math.max(lw, U.measure(r.label)) end
  local vw = U.measure('instrument -> sampler')
  local vwn = U.measure('000.0 s')
  local yy = y + 2
  local head
  if p.mode then head = info.inst and ('bouncer: ' .. info.inst .. ' -> RS5K sampler') or 'bouncer: no instrument on the cursor track'
  else head = ('bouncer: %d note(s) of %s -> audio'):format(info.n or 0, info.track or 'the track') end
  U.text(x + pad, yy, head, U.GREY)
  yy = yy + rh + 2
  for i, r in ipairs(RD.ROWS) do
    if RD.row_on(p, r) then
      if yy + rh > y + h then break end
      local cur = focus and i == RD.sel
      local lx = x + pad
      U.text(lx, yy, r.label, cur and U.AMBER or U.TEXT)
      if RD.hint then RD.hint('rd', lx, yy, lw, rh, { row = i }) end   -- 21 окт: метки f (RD.hint = ctx.hint)
      local sx = lx + lw + pad
      local hot = mx >= sx and mx < x + w - pad and my >= yy and my < yy + rh
      if r.toggle then
        local on = p[r.k]
        local lab = on and (r.on or 'on') or (r.off or 'off')
        local bw = U.measure(lab) + 2 * pad
        U.set(on and U.tint(U.CYAN, 0.25) or (hot and U.tint(U.AMBER, 0.3) or U.BG)); gfx.rect(sx, yy, bw, rh - 1, 1)
        U.set(on and U.CYAN or U.LINE); gfx.rect(sx, yy, bw, rh - 1, 0)
        U.text(sx + pad, yy, lab, hot and U.AMBER or (on and U.CYAN or U.GREY))
        if hot then hv.toggle = i end
        if RD.hint then RD.hint('rd', sx, yy, bw, rh, { toggle = i }) end
      else
        local sw = math.max(4 * L.cw, x + w - pad - vwn - pad - sx)
        local v = p[r.k] or r.def
        U.dslider(sx, yy + math.floor(rh / 2), sw, (v - r.min) / (r.max - r.min), false, (hot or cur) and U.AMBER or U.TEXT, hot, rh)
        local vs = r.note and nname(v) or (r.fmt:find('%%d') and r.fmt:format(math.floor(v + 0.5)) or r.fmt:format(v))   -- 21 окт: дробное с %d
        U.text(x + w - pad - U.measure(vs), yy, vs, U.GREY)
        if hot then hv.slider = { i = i, x0 = sx, w = sw } end
      end
      if mx >= x and mx < x + w and my >= yy and my < yy + rh then hv.row = i end
      yy = yy + rh
    end
  end
  if p.mode and yy + rh <= y + h then
    local pl = RD.plan(p)
    local tot = pl[#pl] and pl[#pl].t1 or 0
    U.text(x + pad, yy, ('%d sample(s), %.0f s of audio, an RS5K each in one container'):format(#pl, tot), U.DIM)
    yy = yy + rh
  end
  if yy + rh + 2 <= y + h then
    local lab = 'bounce (Enter)'
    local bw = U.measure(lab) + 2 * pad
    local bh = mx >= x + pad and mx < x + pad + bw and my >= yy + 2 and my < yy + 2 + rh
    U.set(bh and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(x + pad, yy + 2, bw, rh - 1, 1)
    U.set(bh and U.AMBER or U.LINE); gfx.rect(x + pad, yy + 2, bw, rh - 1, 0)
    U.text(x + 2 * pad, yy + 2, lab, bh and U.AMBER or U.TEXT)
    if bh then hv.render = true end
    if RD.hint then RD.hint('rd', x + pad, yy + 2, bw, rh, { render = true }) end
  end
  local _ = vw
  return hv
end

return RD
