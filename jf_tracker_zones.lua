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

-- 25 окт: n цепей поровну по 0..127, соседи перекрываются кроссфейдом xf (доля части, 0..0.5): у края
-- диапазона скатов нет (первая звучит с 0, последняя до 127)
function Z.spread(n, xf)
  local out = {}
  if n < 1 then return out end
  local w = 128 / n
  local x = math.floor(w * (xf or 0.25) + 0.5)
  for i = 1, n do
    local a, b = math.floor((i - 1) * w + 0.5), math.floor(i * w + 0.5) - 1
    local lo = i == 1 and 0 or math.max(0, a - x)
    local hi = i == n and 127 or math.min(127, b + x)
    local flo = i == 1 and 0 or math.min(b, a + x)
    local fhi = i == n and 127 or math.max(flo, b - x)
    out[i] = Z.norm({ lo = lo, hi = hi, flo = flo, fhi = fhi })
  end
  return out
end
-- текст зоны: «0..63» без скатов, «0..63 fade 48..72»: полная сила — flo..fhi
function Z.text(z)
  z = Z.norm(z)
  if z.flo == z.lo and z.fhi == z.hi then return ('%d..%d'):format(z.lo, z.hi) end
  return ('%d..%d full %d..%d'):format(z.lo, z.hi, z.flo, z.fhi)
end
-- разбор «lo hi [flo fhi]» → зона или nil
function Z.parse(s)
  local t = {}
  for v in (s or ''):gmatch('%d+') do t[#t + 1] = math.max(0, math.min(127, tonumber(v))) end
  if #t < 2 then return nil end
  return Z.norm({ lo = t[1], hi = t[2], flo = t[3] or t[1], fhi = t[4] or t[2] })
end

local NN = { 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B' }
function Z.label(kind, v)
  if kind == 'key' then return NN[v % 12 + 1] .. (v // 12 - 1) end   -- как в REAPER: 60 = C4, 0 = C-1
  return tostring(v)
end

return Z
