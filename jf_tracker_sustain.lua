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

-- кривые кроссфейда шва: auto — линейная для похожих кусков, иначе равной мощности
S.CURVES = { { 'auto', 'auto' }, { 'lin', 'linear' }, { 'eq', 'equal power' }, { 's', 's-curve' } }
S.CURVES_BY = {}
for _, c in ipairs(S.CURVES) do S.CURVES_BY[c[1]] = c[2] end

-- метка инструмента «on ls le xf» (P_EXT:jf_loop) ↔ таблица; off — точки помнятся
-- 13 окт: «on ls le xf boff путь» — запечённый луп: файл с кроссфейдом, луп в нём с boff секунд
function S.parse(tag)
  local on, a, b, x, rest = (tag or ''):match('^(%d)%s+(%S+)%s+(%S+)%s+(%S+)%s*(.*)$')
  a, b, x = tonumber(a), tonumber(b), tonumber(x)
  if not (a and b and x) or b <= a then return nil end
  local lp = { on = on == '1', ls = a, le = b, xf = x, curve = 'auto', flat = true }
  -- 13 окт: c=<кривая кроссфейда> f=<выравнивание громкости 1 / 0> — до файла
  while true do
    local key, v, r2 = (rest or ''):match('^(%a)=(%S+)%s*(.*)$')
    if not key then break end
    if key == 'c' and S.CURVES_BY[v] then lp.curve = v elseif key == 'f' then lp.flat = v ~= '0' end
    rest = r2
  end
  local bo, path = (rest or ''):match('^(%S+)%s+(.+)$')
  if tonumber(bo) and path and path ~= '' then lp.boff, lp.file = tonumber(bo), path end
  return lp
end
function S.tag(lp)
  local t = ('%d %.6f %.6f %.6f'):format(lp.on and 1 or 0, lp.ls, lp.le, lp.xf or 0)
  if lp.curve and lp.curve ~= 'auto' then t = t .. ' c=' .. lp.curve end
  if lp.flat == false then t = t .. ' f=0' end
  if lp.file and lp.boff then t = t .. (' %.6f %s'):format(lp.boff, lp.file) end
  return t
end

-- ── запечённый луп (13 окт) ─────────────────────────────────────────────
-- Кроссфейд шва не на лету, а в файле (как сэмплеры): последние X отсчётов лупа плавно
-- переходят в X отсчётов ПЕРЕД его началом. Тогда за последним отсчётом лупа звучит то,
-- что в файле шло перед ls, — а следом ls: шов непрерывен при любых точках (щелчка нет,
-- разница громкости / фазы размазана по X). chs — каналы (1-based, отсчёт k = кадр k-1),
-- ls, le — кадры (0-based), X — длина кроссфейда в кадрах.
-- sr (13 окт) — выровнять громкость участка: спад (808, пэд с затуханием) делится на свою огибающую,
-- весь луп звучит громкостью точки ls (там голова передаёт хвосту — стык непрерывен), шов сходится
-- и по уровню. nil — без выравнивания.
-- → каналы кадров [ls - X, le) (луп в них начинается с X), X
function S.bake(chs, ls, le, X, sr, opt)
  opt = opt or {}
  X = math.max(0, math.min(X, ls, (le - ls) // 2))
  if sr and opt.flat ~= false then chs = S.flatten(chs, ls - X, le, ls, sr) end
  -- 13 окт: фаза — конец лупа сдвигается (до ±20 мс), чтобы X кадров перед le совпали по фазе
  -- с X кадрами перед ls: долгий кроссфейд не складывает две копии в разной фазе (гребёнка, «широко»)
  if sr and opt.align ~= false and X > 0 then
    local nle = S.align(chs, ls, le, X, sr)
    if nle ~= le then le = nle; X = math.max(0, math.min(X, ls, (le - ls) // 2)) end
  end
  -- закон: похожие куски (корреляция > 0.5) — линейный (без горба громкости), иначе равной мощности
  local sab, saa, sbb = 0, 0, 0
  for _, x in ipairs(chs) do
    for k = 0, X - 1 do
      local u, v = x[le - X + k + 1] or 0, x[ls - X + k + 1] or 0
      sab = sab + u * v; saa = saa + u * u; sbb = sbb + v * v
    end
  end
  local lin = saa > 1e-12 and sbb > 1e-12 and sab / math.sqrt(saa * sbb) > 0.5
  local cv = opt.curve or 'auto'
  if cv == 'lin' then lin = true elseif cv == 'eq' then lin = false end
  local out = {}
  for c, x in ipairs(chs) do
    local o = {}
    for f = ls - X, le - 1 do o[#o + 1] = x[f + 1] or 0 end
    for k = 0, X - 1 do
      local t = (k + 1) / X
      local gi, go
      if cv == 's' then gi = t * t * (3 - 2 * t); go = 1 - gi
      elseif lin then gi, go = t, 1 - t else gi, go = math.sin(t * math.pi / 2), math.cos(t * math.pi / 2) end
      local i = (le - X + k) - (ls - X) + 1
      o[i] = (x[le - X + k + 1] or 0) * go + (x[ls - X + k + 1] or 0) * gi
    end
    out[c] = o
  end
  return out, X, le
end

-- конец лупа с лучшей фазой: le' в [le - D, le + D] (D — 20 мс, не за ls + X), где окно
-- перед le' сильнее всего похоже на окно перед ls (нормированная корреляция, каналы вместе,
-- окно до 4096 кадров, через отсчёт — быстро)
function S.align(chs, ls, le, X, sr)
  local W = math.min(X, 4096)
  local D = math.floor(0.02 * sr)
  local n = math.huge
  for _, x in ipairs(chs) do n = math.min(n, #x) end
  local lo, hi = math.max(ls + 2 * W, le - D), math.min(n, le + D)
  if hi <= lo then return le end
  local saa = 0
  for _, x in ipairs(chs) do for k = ls - W, ls - 1, 2 do local v = x[k + 1] or 0; saa = saa + v * v end end
  if saa < 1e-12 then return le end
  local function corr(e, st)
    local sab, sbb = 0, 0
    for _, x in ipairs(chs) do
      for k = 0, W - 1, st do
        local u, v = x[e - W + k + 1] or 0, x[ls - W + k + 1] or 0
        sab = sab + u * v; sbb = sbb + u * u
      end
    end
    return sbb > 1e-12 and sab / math.sqrt(saa * sbb * (st == 4 and 0.5 or 1)) or -1
  end
  -- грубо (шаг 4 по сдвигу и окну), потом точно рядом с лучшим
  local best, bc = le, -2
  local function scan(a, b, st, wst)
    for e = a, b, st do
      local c = corr(e, wst)
      if c > bc + 1e-9 or (math.abs(c - bc) <= 1e-9 and math.abs(e - le) < math.abs(best - le)) then bc, best = c, e end
    end
  end
  scan(lo, hi, 4, 4)
  bc = -2
  scan(math.max(lo, best - 4), math.min(hi, best + 4), 1, 2)
  return best
end

-- выравнивание громкости кадров [a, b): огибающая — RMS окон по 50 мс (шаг 25 мс, все каналы),
-- между центрами окон — линейно; усиление = огибающая в ref / огибающая (±24 дБ, тишина ниже −60 дБ не тянется).
-- → новые каналы той же длины (вне [a, b) — как были)
function S.flatten(chs, a, b, ref, sr)
  local W = math.max(64, math.floor(0.05 * sr)); local hop = W // 2
  local cs, ev = {}, {}
  for c0 = a, math.max(a, b - W), hop do
    local e = 0
    for _, x in ipairs(chs) do for f = c0, c0 + W - 1 do local v = x[f + 1] or 0; e = e + v * v end end
    cs[#cs + 1] = c0 + W / 2; ev[#ev + 1] = math.sqrt(e / (W * #chs))
  end
  if #cs == 0 then return chs end
  local function env(f)
    if f <= cs[1] then return ev[1] end
    if f >= cs[#cs] then return ev[#cs] end
    local i = math.floor((f - cs[1]) / hop) + 1
    local t = (f - cs[i]) / hop
    return ev[i] + (ev[i + 1] - ev[i]) * t
  end
  local r = env(ref)
  if r < 1e-6 then return chs end
  local out = {}
  for c, x in ipairs(chs) do
    local o = {}
    for f = a, b - 1 do
      local e = env(f)
      local g = e > r * 1e-3 and math.max(1 / 16, math.min(16, r / e)) or 1   -- до ±24 дБ; ниже −60 дБ от ls — тишина, не тянуть
      o[f + 1] = (x[f + 1] or 0) * g
    end
    out[c] = setmetatable(o, { __index = x })
  end
  return out
end

-- WAV PCM 16 / 24 / 32, float 32 → { sr, ch = { канал = отсчёты } } (кадры [0, nmax)), или nil
function S.wav_read(path, nmax)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local hdr = f:read(12)
  if not hdr or hdr:sub(1, 4) ~= 'RIFF' or hdr:sub(9, 12) ~= 'WAVE' then f:close(); return nil end
  local fmt, nch, sr, bits, at, len
  while true do
    local h = f:read(8)
    if not h or #h < 8 then break end
    local id, sz = h:sub(1, 4), string.unpack('<I4', h, 5)
    if id == 'fmt ' then
      local b = f:read(sz)
      fmt, nch, sr = string.unpack('<I2I2I4', b); bits = string.unpack('<I2', b, 15)
      if fmt == 0xFFFE and #b >= 26 then fmt = string.unpack('<I2', b, 25) end
      if sz % 2 == 1 then f:read(1) end
    elseif id == 'data' then at, len = f:seek(), sz; break
    else f:seek('cur', sz + sz % 2) end
  end
  if not (at and fmt and nch and sr and bits) then f:close(); return nil end
  local bps = bits // 8
  local code = (fmt == 3 and bits == 32) and '<f' or (bits == 16 and '<i2' or (bits == 24 and '<i3' or (bits == 32 and '<i4' or nil)))
  if not code then f:close(); return nil end
  local scale = fmt == 3 and 1 or 2 ^ (bits - 1)
  local n = math.min(len // (bps * nch), nmax or math.huge)
  local raw = f:read(n * bps * nch) or ''
  f:close()
  local ch = {}
  for c = 1, nch do ch[c] = {} end
  local p = 1
  for k = 1, n do
    for c = 1, nch do ch[c][k] = string.unpack(code, raw, p) / scale; p = p + bps end
  end
  return { sr = sr, ch = ch, n = n }
end

-- каналы → WAV float 32
function S.wav_write(path, sr, chs)
  local nch, n = #chs, #chs[1]
  local f = io.open(path, 'wb')
  if not f then return false end
  local data = n * nch * 4
  f:write('RIFF', string.pack('<I4', 36 + data), 'WAVE', 'fmt ', string.pack('<I4I2I2I4I4I2I2', 16, 3, nch, sr, sr * nch * 4, nch * 4, 32), 'data', string.pack('<I4', data))
  local buf, K = {}, 4096
  for k0 = 1, n, K do
    local t = {}
    for k = k0, math.min(n, k0 + K - 1) do for c = 1, nch do t[#t + 1] = chs[c][k] end end
    buf[#buf + 1] = string.pack(('<' .. ('f'):rep(#t)), table.unpack(t))
  end
  f:write(table.concat(buf)); f:close()
  return true
end

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
  local cands = {}                                   -- 13 окт: все доведённые кандидаты (looploom рисует их)
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
    cands[#cands + 1] = { ls = ls, le = le, match = math.max(0, m), spec = pr.sc }
    if not best or m - 0.01 * k > best.m then best = { ls = ls, le = le, match = math.max(0, m), m = m - 0.01 * k } end
  end
  best.m = nil
  table.sort(cands, function(p, q) return p.match > q.match end)
  best.cands = cands
  return best
end

return S
