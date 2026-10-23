-- jf_tracker_zones.lua — зоны цепей рэка (23 окт): key / vel / sel, как Key / Vel / Chain в Ableton Rack.
-- Зона: lo..hi — звучит, flo..fhi (внутри) — в полную силу, между — линейный скат. Тот же расчёт —
-- в Effects/jf_tracker_zone.jsfx (zgain). Без reaper.* — тест tests/test_zones.lua.
local Z = {}

Z.JSFX = 'JS: jf_tracker_zone'
-- слайдеры плагина (с 0): зона → { lo, hi, flo, fhi }; select — общий регулятор рэка
Z.SL = { key = { 0, 1, 2, 3 }, vel = { 4, 5, 6, 7 }, sel = { 8, 9, 10, 11 } }
Z.SELECT = 12
Z.MIN = { key = 0, vel = 1, sel = 0 }

function Z.norm(z)
  local lo, hi = z.lo, z.hi
  if hi < lo then lo, hi = hi, lo end
  local flo = math.max(lo, math.min(hi, z.flo or lo))
  local fhi = math.max(flo, math.min(hi, z.fhi or hi))
  return { lo = lo, hi = hi, flo = flo, fhi = fhi }
end

function Z.gain(x, z)
  z = Z.norm(z)
  if x < z.lo or x > z.hi then return 0 end
  if x < z.flo then return (x - z.lo + 1) / (z.flo - z.lo + 1) end
  if x > z.fhi then return (z.hi - x + 1) / (z.hi - z.fhi + 1) end
  return 1
end

-- перетаскивание края: what = lo | hi | flo | fhi | move (всю зону на d); края не выходят за 0..127 / друг за друга
function Z.drag(z, what, v, kind)
  local mn = Z.MIN[kind or 'key'] or 0
  v = math.max(mn, math.min(127, math.floor(v + 0.5)))
  local r = { lo = z.lo, hi = z.hi, flo = z.flo, fhi = z.fhi }
  if what == 'lo' then
    local d = math.min(v, r.hi) - r.lo
    r.lo = r.lo + d; r.flo = math.max(r.lo, r.flo + (r.flo == z.lo and d or 0))
  elseif what == 'hi' then
    local d = math.max(v, r.lo) - r.hi
    r.hi = r.hi + d; r.fhi = math.min(r.hi, r.fhi + (r.fhi == z.hi and d or 0))
  elseif what == 'flo' then r.flo = math.max(r.lo, math.min(r.fhi, v))
  elseif what == 'fhi' then r.fhi = math.min(r.hi, math.max(r.flo, v))
  elseif what == 'move' then
    local d = math.max(mn - r.lo, math.min(127 - r.hi, v))
    r.lo, r.hi, r.flo, r.fhi = r.lo + d, r.hi + d, r.flo + d, r.fhi + d
  end
  return Z.norm(r)
end

local NN = { 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B' }
function Z.label(kind, v)
  if kind == 'key' then return NN[v % 12 + 1] .. (v // 12 - 1) end   -- как в REAPER: 60 = C4, 0 = C-1
  return tostring(v)
end

return Z
