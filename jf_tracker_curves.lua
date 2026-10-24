-- jf_tracker_curves.lua — кривые для выделения на колонке огибающей (24 окт): reform для автоматизации.
-- CV.LIST — пункты выпадашки по порядку: { id, key, label, kind = 'gen' (новая форма в диапазоне) | 'fx' (правка значений) }
-- CV.apply(id, vals) → новые значения (0..1) той же длины; vals — нынешние значения строк выделения.
-- Диапазон новых форм — от меньшего до большего нынешних; ровная линия (одно значение) — от 0 до него
-- (почти 0 — до 1): «фейдер стоит здесь, сделай подъём к нему». Без reaper.* — тест tests/test_curves.lua.

local CV = {}

CV.LIST = {
  { id = 'up',     key = 'u', label = 'ramp up',            kind = 'gen' },
  { id = 'down',   key = 'd', label = 'ramp down',          kind = 'gen' },
  { id = 'exp',    key = 'e', label = 'exp: slow, then fast', kind = 'gen' },
  { id = 'log',    key = 'g', label = 'log: fast, then slow', kind = 'gen' },
  { id = 'scurve', key = 's', label = 's-curve',            kind = 'gen' },
  { id = 'sine',   key = 'w', label = 'sine wave',          kind = 'gen' },
  { id = 'tri',    key = 't', label = 'triangle',           kind = 'gen' },
  { id = 'saw',    key = 'a', label = 'saw x4',             kind = 'gen' },
  { id = 'square', key = 'q', label = 'square x4',          kind = 'gen' },
  { id = 'random', key = 'r', label = 'random',             kind = 'gen' },
  { id = 'invert', key = 'i', label = 'invert (upside down)', kind = 'fx' },
  { id = 'rev',    key = 'x', label = 'reverse (back to front)', kind = 'fx' },
  { id = 'more',   key = 'm', label = 'more: stretch from the middle', kind = 'fx' },
  { id = 'less',   key = 'n', label = 'less: squeeze to the middle', kind = 'fx' },
  { id = 'uplift', key = 'k', label = 'all up a step (+1/16)', kind = 'fx' },
  { id = 'lower',  key = 'j', label = 'all down a step (-1/16)', kind = 'fx' },
  { id = 'smooth', key = 'o', label = 'smooth',             kind = 'fx' },
  { id = 'steps',  key = 'p', label = 'quantize to 8 steps', kind = 'fx' },
  { id = 'flat',   key = 'f', label = 'flat: the average',  kind = 'fx' },
}
CV.BY = {}
for _, c in ipairs(CV.LIST) do CV.BY[c.id] = c end

local function clamp(v) return math.max(0, math.min(1, v)) end

function CV.range(vals)
  local lo, hi = math.huge, -math.huge
  for _, v in ipairs(vals) do lo = math.min(lo, v); hi = math.max(hi, v) end
  if lo == math.huge then return 0, 1 end
  if hi - lo < 1e-3 then
    if hi < 0.05 then return 0, 1 end
    return 0, hi
  end
  return lo, hi
end

-- форма 0..1 по t 0..1 (k — номер строки, для random — детерминированный шум от seed)
local SHAPE = {
  up = function(t) return t end,
  down = function(t) return 1 - t end,
  exp = function(t) return t * t * t end,
  log = function(t) return 1 - (1 - t) ^ 3 end,
  scurve = function(t) return t * t * (3 - 2 * t) end,
  sine = function(t) return 0.5 - 0.5 * math.cos(t * 2 * math.pi) end,
  tri = function(t) return 1 - math.abs(2 * t - 1) end,
  saw = function(t) local p = (t * 4) % 1; return (t >= 1) and 1 or p end,
  square = function(t) return (math.floor(t * 8) % 2 == 0) and 1 or 0 end,
}

function CV.apply(id, vals, seed)
  local n = #vals
  local out = {}
  if n == 0 then return out end
  local c = CV.BY[id]
  if not c then return vals end
  if c.kind == 'gen' then
    local lo, hi = CV.range(vals)
    local rnd = seed or 12345
    for k = 1, n do
      local t = n > 1 and (k - 1) / (n - 1) or 0
      local s
      if id == 'random' then rnd = (rnd * 1103515245 + 12345) % 2147483648; s = rnd / 2147483648
      else s = SHAPE[id](t) end
      out[k] = clamp(lo + s * (hi - lo))
    end
    return out
  end
  local sum = 0
  for _, v in ipairs(vals) do sum = sum + v end
  local mean = sum / n
  for k, v in ipairs(vals) do
    if id == 'invert' then out[k] = 1 - v
    elseif id == 'rev' then out[k] = vals[n - k + 1]
    elseif id == 'more' then out[k] = clamp(mean + (v - mean) * 1.5)
    elseif id == 'less' then out[k] = clamp(mean + (v - mean) * 0.5)
    elseif id == 'uplift' then out[k] = clamp(v + 1 / 16)
    elseif id == 'lower' then out[k] = clamp(v - 1 / 16)
    elseif id == 'smooth' then out[k] = ((vals[k - 1] or v) + 2 * v + (vals[k + 1] or v)) / 4
    elseif id == 'steps' then out[k] = math.floor(v * 7 + 0.5) / 7
    elseif id == 'flat' then out[k] = mean
    else out[k] = v end
  end
  return out
end

return CV
