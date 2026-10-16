-- jf_tracker_layers.lua — слоёный инструмент (14 окт): несколько items звучат одной нотой.
-- Без reaper.* — тест tests/test_layers.lua.
--
-- Корень — item инструмента в lib; его метка P_EXT:jf_layers — список слоёв. Слой — свой item в
-- LIB (GUID в метке): файл, offset, take FX, цвет. Метка копируется с chunk в каждую ноту, так
-- что нота знает свои слои. На треке слои — производные items (P_EXT:jf_lof = GUID ноты),
-- трекер их не показывает (как копии ретриггера); E.layers_sync пересобирает их после правок.
--
-- Слой: guid | offs (мс, сдвиг от ноты) | pan (−1..1) | vol (дБ) | semis | rnd_pan | rnd_vol (дБ) |
-- rnd_semis | rnd_start (мс) | cycle «k/n» (k-я нота из каждых n; 1/1 — всегда) | flags (m — mute,
-- p — фаза перевёрнута)

local LY = {}

local FIELDS = { 'offs', 'pan', 'vol', 'semis', 'rpan', 'rvol', 'rsemis', 'rstart' }

function LY.new(guid) return { guid = guid, offs = 0, pan = 0, vol = 0, semis = 0, rpan = 0, rvol = 0, rsemis = 0, rstart = 0, ck = 1, cn = 1, mute = false, phase = false } end

-- метка → список слоёв (пустая / мусор → {})
function LY.parse(tag)
  local out = {}
  for ent in (tag or ''):gmatch('[^;]+') do
    local guid, rest = ent:match('^%s*({[^}]+})|(.*)$')
    if guid then
      local l = LY.new(guid)
      local parts = {}
      for p in (rest .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
      for i, k in ipairs(FIELDS) do local v = tonumber(parts[i]); if v then l[k] = v end end
      local ck, cn = (parts[9] or ''):match('^(%d+)/(%d+)$')
      if ck then l.ck, l.cn = math.max(1, tonumber(ck)), math.max(1, tonumber(cn)) end
      local fl = parts[10] or ''
      l.mute, l.phase = fl:find('m', 1, true) ~= nil, fl:find('p', 1, true) ~= nil
      if l.ck > l.cn then l.ck = l.cn end
      out[#out + 1] = l
    end
  end
  return out
end

local function num(v) local s = ('%.4f'):format(v or 0):gsub('0+$', ''):gsub('%.$', ''); return s == '-0' and '0' or s end
function LY.tag(list)
  local out = {}
  for _, l in ipairs(list or {}) do
    local p = { l.guid }
    for _, k in ipairs(FIELDS) do p[#p + 1] = num(l[k]) end
    p[#p + 1] = ('%d/%d'):format(l.ck or 1, l.cn or 1)
    p[#p + 1] = (l.mute and 'm' or '') .. (l.phase and 'p' or '')
    out[#out + 1] = table.concat(p, '|')
  end
  return table.concat(out, ';')
end

-- детерминированный «случайный» −1..1 из seed ноты, номера слоя и параметра (пересборка не меняет звук)
function LY.rnd(seed, n, what)
  local h = (math.floor(seed or 0) * 2654435761 + n * 40503 + what * 2246822519) % 4294967296
  h = (h ~ (h >> 13)) * 1274126177 % 4294967296
  h = h ~ (h >> 16)
  return (h % 20001) / 10000 - 1
end

-- что играет слой n у ноты: idx — номер ноты этого инструмента на треке (1, 2 …, для циклов), seed —
-- бросок ноты. → nil (не звучит в этот раз) или { dt (с), pan, gain (множитель), semis }
function LY.plan(l, n, idx, seed)
  if l.mute then return nil end
  local cn = math.max(1, l.cn or 1)
  if cn > 1 and ((idx or 1) - 1) % cn + 1 ~= (l.ck or 1) then return nil end
  local dt = ((l.offs or 0) + (l.rstart or 0) * LY.rnd(seed, n, 1)) / 1000
  local pan = math.max(-1, math.min(1, (l.pan or 0) + (l.rpan or 0) * LY.rnd(seed, n, 2)))
  local db = (l.vol or 0) + (l.rvol or 0) * LY.rnd(seed, n, 3)
  local gain = 10 ^ (db / 20) * (l.phase and -1 or 1)
  local semis = (l.semis or 0) + (l.rsemis or 0) * LY.rnd(seed, n, 4)
  return { dt = dt, pan = pan, gain = gain, semis = semis }
end

-- фазная корреляция (подсказка align): сдвиг слоя b относительно a в кадрах (±maxd), где окно
-- атаки сильнее всего совпадает (нормированная корреляция). a, b — отсчёты (1-based), w — окно
function LY.align(a, b, w, maxd)
  local best, bc = 0, -2
  for d = -maxd, maxd do
    local sab, saa, sbb = 0, 0, 0
    for k = 1, w do
      local u, v = a[k] or 0, b[k + d] or 0
      sab = sab + u * v; saa = saa + u * u; sbb = sbb + v * v
    end
    local c = (saa > 1e-12 and sbb > 1e-12) and sab / math.sqrt(saa * sbb) or -1
    if c > bc + 1e-9 then bc, best = c, d end
  end
  return best, bc
end

return LY
