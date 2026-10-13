-- jf_tracker_sustain.lua — луп удержания инструмента (13 окт): нота длиннее сэмпла держится,
-- пока не отпустят (пэды, 808). Без reaper.* — тест tests/test_sustain.lua.
--
-- Точки лупа ls, le — секунды ФАЙЛА (как D_STARTOFFS), xf — кроссфейд шва (OVERLAP секции).
-- Нота с лупом в проекте — два item, трекер видит один:
--   голова — сама нота во всю длину, её источник — секция файла [0, ls) без лупа: атака, потом тишина;
--   хвост — item-секция [ls, le) с лупом и OVERLAP xf, встык с головой (тот же отсчёт файла), до конца ноты.
-- Хвост — производное: edit.run пересобирает его после каждой правки (S.plan), трекер его не показывает.
--
-- S.find — точки сам: две точки в устойчивой части звука, похожие по спектру и громкости,
-- потом шов доводится по форме волны (корреляция) и встаёт на переход через ноль.

local S = {}

-- ── хвост ноты ──────────────────────────────────────────────────────────
-- n = { pos, len, offs, rate } — нота (голова); lp = { ls, le } — секунды файла.
-- → { pos, len, offs } хвоста (offs — внутри секции [ls, le)) или nil — нота кончается до лупа
function S.plan(n, lp)
  local per = lp.le - lp.ls
  if per <= 1e-4 then return nil end
  local r = (n.rate and n.rate > 0) and n.rate or 1
  local t_ls = n.pos + (lp.ls - n.offs) / r            -- где голова доходит до начала лупа
  local pos, offs
  if t_ls >= n.pos then pos, offs = t_ls, 0
  else pos, offs = n.pos, (n.offs - lp.ls) % per end    -- нота начинается внутри лупа (правая часть реза)
  local len = n.pos + n.len - pos
  if len <= 1e-3 then return nil end
  return { pos = pos, len = len, offs = offs }
end

-- метка инструмента «on ls le xf» (P_EXT:jf_loop) ↔ таблица; off — точки помнятся
function S.parse(tag)
  local on, a, b, x = (tag or ''):match('^(%d)%s+(%S+)%s+(%S+)%s+(%S+)')
  a, b, x = tonumber(a), tonumber(b), tonumber(x)
  if not (a and b and x) or b <= a then return nil end
  return { on = on == '1', ls = a, le = b, xf = x }
end
function S.tag(lp) return ('%d %.6f %.6f %.6f'):format(lp.on and 1 or 0, lp.ls, lp.le, lp.xf or 0) end

-- ── БПФ (радикс-2, на месте) ────────────────────────────────────────────
local function fft(re, im, n)
  local j = 1
  for i = 1, n do
    if i < j then re[i], re[j] = re[j], re[i]; im[i], im[j] = im[j], im[i] end
    local m = n >> 1
    while m >= 1 and j > m do j = j - m; m = m >> 1 end
    j = j + m
  end
  local len = 2
  while len <= n do
    local ang = -2 * math.pi / len
    local wr, wi = math.cos(ang), math.sin(ang)
    for i = 1, n, len do
      local cr, ci = 1, 0
      for k = 0, len / 2 - 1 do
        local a, b = i + k, i + k + len / 2
        local tr = re[b] * cr - im[b] * ci
        local ti = re[b] * ci + im[b] * cr
        re[b], im[b] = re[a] - tr, im[a] - ti
        re[a], im[a] = re[a] + tr, im[a] + ti
        cr, ci = cr * wr - ci * wi, cr * wi + ci * wr
      end
    end
    len = len * 2
  end
end
S._fft = fft

local NF = 2048                 -- окно спектра
local NB = 24                   -- полосы (логарифмически 40 Гц … sr/2)
local HANN = {}
for i = 1, NF do HANN[i] = 0.5 - 0.5 * math.cos(2 * math.pi * (i - 1) / (NF - 1)) end

-- спектр окна вокруг отсчёта c: громкости полос (дБ) и общий уровень (дБ)
local function feature(x, c, sr)
  local re, im = {}, {}
  local e = 0
  for i = 1, NF do
    local v = x[c - NF // 2 + i] or 0
    e = e + v * v
    re[i] = v * HANN[i]; im[i] = 0
  end
  fft(re, im, NF)
  local bands = {}
  local f0, f1 = 40, sr / 2
  for b = 1, NB do
    local lo = math.max(1, math.floor(f0 * (f1 / f0) ^ ((b - 1) / NB) / sr * NF))
    local hi = math.max(lo, math.floor(f0 * (f1 / f0) ^ (b / NB) / sr * NF) - 1)
    local s = 0
    for k = lo, math.min(hi, NF / 2 - 1) do s = s + re[k + 1] ^ 2 + im[k + 1] ^ 2 end
    bands[b] = 10 * math.log(s / (hi - lo + 1) + 1e-12, 10)
  end
  return { bands = bands, db = 10 * math.log(e / NF + 1e-12, 10) }
end

-- похожесть точек (меньше — лучше): средняя разница полос, громкость; тихие полосы весят меньше
local function distance(a, b)
  local d, w = 0, 0
  for k = 1, NB do
    local top = math.max(a.bands[k], b.bands[k])
    local wk = top > -80 and 1 or 0.2
    d = d + wk * math.abs(a.bands[k] - b.bands[k]); w = w + wk
  end
  return d / math.max(w, 1e-9) + 0.7 * math.abs(a.db - b.db)
end

-- нормированная корреляция окон x[a-h .. a+h] и x[b-h .. b+h]
local function ncc(x, a, b, h, stride)
  local sab, saa, sbb = 0, 0, 0
  for k = -h, h, stride or 1 do
    local u, v = x[a + k] or 0, x[b + k] or 0
    sab = sab + u * v; saa = saa + u * u; sbb = sbb + v * v
  end
  if saa < 1e-12 or sbb < 1e-12 then return 0 end
  return sab / math.sqrt(saa * sbb)
end
S._ncc = ncc

-- ближайший к i переход через ноль снизу вверх (x[k-1] < 0 <= x[k]) в пределах ±w
local function rising_zero(x, i, w)
  for d = 0, w do
    for _, k in ipairs({ i + d, i - d }) do
      local p, q = x[k - 1], x[k]
      if p and q and p < 0 and q >= 0 then return k end
    end
  end
  return i
end

-- x — моно-отсчёты (1-based), sr; a, b — отсчёты куска инструмента [a, b).
-- opt: min_len (с, 0.12), hop (с, 0.02). → { ls, le } (отсчёты, 1-based), match 0..1 — или nil, причина
function S.find(x, sr, a, b, opt)
  opt = opt or {}
  a, b = math.max(1, a or 1), math.min(#x, b or #x)
  local n = b - a
  if n < sr * 0.15 then return nil, 'the sample is too short for a loop' end
  -- огибающая: уровень на шагах 10 мс; пик атаки, конец устойчивой части (−18 дБ от пика)
  local hop = math.max(1, math.floor(sr * 0.01))
  local env, pk, pki = {}, 0, a
  for i = a, b - hop, hop do
    local e = 0
    for k = i, i + hop - 1 do local v = x[k] or 0; e = e + v * v end
    e = math.sqrt(e / hop)
    env[#env + 1] = { i = i, e = e }
    if e > pk then pk, pki = e, i end
  end
  if pk < 1e-5 then return nil, 'silence' end
  -- конец атаки — первая точка выше −3 дБ от пика (у ровного пэда пик — где угодно)
  for _, v in ipairs(env) do if v.e >= pk * 0.7 then pki = v.i; break end end
  local s0 = math.max(pki + hop * 3, a + math.floor(n * 0.1))
  local s1 = s0
  for _, v in ipairs(env) do if v.i > s0 and v.e > pk * 0.125 then s1 = v.i end end
  s1 = math.min(s1, b - NF)
  local min_len = math.floor((opt.min_len or 0.12) * sr)
  if s1 - s0 < min_len then
    -- короткая устойчивая часть (808, удар): берём вторую половину звука как есть
    s0 = a + math.floor(n * 0.35); s1 = b - NF
    if s1 - s0 < min_len then return nil, 'no steady part to loop' end
  end
  -- кандидаты: шаг hop2, не больше 48 точек
  local step = math.max(math.floor((opt.hop or 0.02) * sr), math.floor((s1 - s0) / 48))
  local pts = {}
  for i = s0, s1, step do pts[#pts + 1] = { i = i, f = feature(x, i, sr) } end
  local span = s1 - s0
  local pairs_ = {}
  for i = 1, #pts do
    for j = i + 1, #pts do
      local L = pts[j].i - pts[i].i
      if L >= min_len then
        -- длинный луп лучше (меньше слышна периодичность); начало лупа — раньше лучше
        pairs_[#pairs_ + 1] = { a = pts[i].i, b = pts[j].i, sc = distance(pts[i].f, pts[j].f) - 2.0 * L / span + 0.5 * (pts[i].i - s0) / span }
      end
    end
  end
  if #pairs_ == 0 then return nil, 'no loop found' end
  table.sort(pairs_, function(p, q) return p.sc < q.sc end)
  -- шов у 8 лучших по спектру: начало — на переход через ноль; конец — сдвиг в ±15 мс с лучшей
  -- корреляцией окон вокруг шва (что играет после конца, продолжает то, что было после начала):
  -- грубо с шагом 4 отсчёта по прореженному окну, потом точно ±4
  local h = math.floor(sr * 0.012)
  local w = math.floor(sr * 0.015)
  local best
  for k = 1, math.min(8, #pairs_) do
    local pr = pairs_[k]
    local ls = rising_zero(x, pr.a, math.floor(sr * 0.003))
    local le, bc = pr.b, -2
    for d = -w, w, 4 do
      local c = ncc(x, ls, pr.b + d, h, 3)
      if c > bc then bc, le = c, pr.b + d end
    end
    local c0 = le
    for d = -4, 4 do
      local c = ncc(x, ls, c0 + d, h)
      if c > bc then bc, le = c, c0 + d end
    end
    le = rising_zero(x, le, math.floor(sr * 0.0005))
    local m = ncc(x, ls, le, h)
    if not best or m - 0.01 * k > best.m then best = { ls = ls, le = le, match = math.max(0, m), m = m - 0.01 * k } end
  end
  best.m = nil
  return best
end

return S
