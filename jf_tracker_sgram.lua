-- jf_tracker_sgram.lua — спектрограмма (5 окт): время × частота тепловой картой.
--
-- Не спектральные пики REAPER (один цвет на точку), а настоящая
-- спектрограмма: окно Ханна 1024, БПФ (reaper.array:fft_real), строки —
-- частоты 30 Гц .. Найквист по логарифму, яркость — уровень −90..0 дБ.
-- Считается по кусочку за кадр (G.tick с бюджетом) в offscreen-картинку и
-- дальше только выводится. Источник — читатель: reader(t, n) → массив
-- моно-сэмплов (take — аудио-аксессор, файл — WAV напрямую).

local G = { jobs = {}, order = {} }
local R = reaper
local N = 1024
-- картинки 90..97 (по кругу). 5 окт: были 1030..1037 — у gfx номера только
-- 0..1023, setimgdim молча не работал, спектрограмма была пустой
local IMG0, IMGN = 90, 8
local next_img = 0

-- палитра: тёмный → синий → фиолетовый → красный → оранжевый → жёлтый
local PAL = { { 0.05, 0.05, 0.08 }, { 0.10, 0.12, 0.45 }, { 0.45, 0.10, 0.55 }, { 0.85, 0.15, 0.20 }, { 0.98, 0.55, 0.10 }, { 1.00, 0.95, 0.40 } }
local function colour(v)               -- v 0..1
  v = math.max(0, math.min(1, v)) * (#PAL - 1)
  local i = math.floor(v)
  local fr = v - i
  local a, b = PAL[i + 1], PAL[math.min(#PAL, i + 2)]
  return a[1] + (b[1] - a[1]) * fr, a[2] + (b[2] - a[2]) * fr, a[3] + (b[3] - a[3]) * fr
end

local win = {}
for i = 0, N - 1 do win[i + 1] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (N - 1)) end

-- задание: key — что считаем; reader(t, n) → таблица n сэмплов или nil;
-- len — секунды; sr — частота дискретизации для оси частот
function G.get(key, reader, len, sr, cols, rows)
  local j = G.jobs[key]
  if j and j.cols == cols and j.rows == rows then return j end
  if j then G.jobs[key] = nil end
  local img = IMG0 + next_img
  next_img = (next_img + 1) % IMGN
  -- картинку с тем же номером держало другое задание — оно уходит
  for k, o in pairs(G.jobs) do if o.img == img then G.jobs[k] = nil end end
  j = { key = key, reader = reader, len = math.max(1e-3, len), sr = sr or 44100, cols = cols, rows = rows, col = 0, img = img, done = false }
  -- строка → диапазон бинов (лог-частота 30 Гц .. Найквист)
  j.bins = {}
  local ny = j.sr / 2
  for r = 0, rows - 1 do
    local f0 = 30 * (ny / 30) ^ (r / rows)
    local f1 = 30 * (ny / 30) ^ ((r + 1) / rows)
    local b0 = math.max(1, math.floor(f0 / j.sr * N))
    local b1 = math.max(b0, math.min(N / 2 - 1, math.floor(f1 / j.sr * N)))
    j.bins[r] = { b0, b1 }
  end
  local d0 = gfx.dest
  gfx.setimgdim(img, cols, rows)
  gfx.dest = img
  gfx.set(PAL[1][1], PAL[1][2], PAL[1][3], 1); gfx.rect(0, 0, cols, rows, 1)
  gfx.dest = d0
  G.jobs[key] = j
  return j
end

local buf = R.new_array and R.new_array(N) or nil

-- одна колонка
local function column(j)
  local t = (j.col + 0.5) / j.cols * j.len - N / 2 / j.sr
  local s = j.reader(t, N)
  local d0 = gfx.dest
  gfx.dest = j.img
  if s then
    for i = 1, N do buf[i] = (s[i] or 0) * win[i] end
    buf.fft_real(N, true)
    local t2 = buf.table()
    local mags = {}
    for b = 0, N / 2 - 1 do
      local re, im = t2[2 * b + 1] or 0, t2[2 * b + 2] or 0
      mags[b] = math.sqrt(re * re + im * im)
    end
    for r = 0, j.rows - 1 do
      local bb = j.bins[r]
      local m = 0
      for b = bb[1], bb[2] do if mags[b] > m then m = mags[b] end end
      local db = m > 1e-9 and 20 * math.log(m / (N / 4), 10) or -150
      local cr, cg, cb = colour((db + 90) / 90)
      gfx.set(cr, cg, cb, 1)
      gfx.rect(j.col, j.rows - 1 - r, 1, 1, 1)
    end
  end
  gfx.dest = d0
  j.col = j.col + 1
  if j.col >= j.cols then j.done = true end
end

-- кадр: считать колонки, пока не кончится бюджет (секунды)
function G.tick(budget)
  if not buf then return end
  local t0 = R.time_precise()
  for _, j in pairs(G.jobs) do
    while not j.done and R.time_precise() - t0 < budget do column(j) end
    if R.time_precise() - t0 >= budget then return end
  end
end

-- ── читатели ───────────────────────────────────────────────────────────────
-- take: аудио-аксессор (любой формат); t — секунды от начала take
function G.take_reader(take)
  local acc = R.CreateTakeAudioAccessor(take)
  if not acc then return nil end
  local src = R.GetMediaItemTake_Source(take)
  local sr = src and R.GetMediaSourceSampleRate(src) or 44100
  if not sr or sr <= 0 then sr = 44100 end
  local st = R.GetAudioAccessorStartTime(acc)
  local a = R.new_array(N)
  return function(t, n)
    a.clear()
    if R.GetAudioAccessorSamples(acc, sr, 1, st + math.max(0, t), n, a) < 0 then return nil end
    return a.table()
  end, sr, (R.GetAudioAccessorEndTime(acc) - st)
end

-- WAV-файл (PCM 16 / 24 / 32, float 32): моно — первый канал
function G.wav_reader(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local function u32(s, i) return string.unpack('<I4', s, i) end
  local hdr = f:read(12)
  if not hdr or hdr:sub(1, 4) ~= 'RIFF' or hdr:sub(9, 12) ~= 'WAVE' then f:close(); return nil end
  local fmt, ch, sr, bits, data_at, data_len
  while true do
    local ch_hdr = f:read(8)
    if not ch_hdr or #ch_hdr < 8 then break end
    local id, sz = ch_hdr:sub(1, 4), u32(ch_hdr, 5)
    if id == 'fmt ' then
      local b = f:read(sz)
      fmt, ch, sr = string.unpack('<I2I2I4', b)
      bits = string.unpack('<I2', b, 15)
      if fmt == 0xFFFE and #b >= 26 then fmt = string.unpack('<I2', b, 25) end   -- WAVE_FORMAT_EXTENSIBLE
      if sz % 2 == 1 then f:read(1) end
    elseif id == 'data' then
      data_at, data_len = f:seek(), sz; break
    else f:seek('cur', sz + (sz % 2)) end
  end
  if not (data_at and fmt and ch and sr and bits) then f:close(); return nil end
  local bps = bits // 8
  local block = bps * ch
  local nframes = data_len // block
  local code = (fmt == 3 and bits == 32) and '<f' or (bits == 16 and '<i2' or (bits == 24 and '<i3' or (bits == 32 and '<i4' or nil)))
  if not code then f:close(); return nil end
  local scale = fmt == 3 and 1 or (2 ^ (bits - 1))
  return function(t, n)
    local first = math.floor(t * sr)
    local out = {}
    local lo = math.max(0, first)
    local hi = math.min(nframes, first + n)
    if hi > lo then
      f:seek('set', data_at + lo * block)
      local raw = f:read((hi - lo) * block) or ''
      for k = 0, hi - lo - 1 do
        local p = k * block + 1
        if p + bps - 1 <= #raw then out[lo - first + k + 1] = string.unpack(code, raw, p) / scale end
      end
    end
    for i = 1, n do out[i] = out[i] or 0 end
    return out
  end, sr, nframes / sr
end

return G
