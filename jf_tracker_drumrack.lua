-- jf_tracker_drumrack.lua — drumrs5k (16 окт): контейнер RS5K видом драм-рэка.
--
-- Контейнер «drumrs5k имя» — пэды параллельно (parallel = 1 со второго): каждый
-- пэд — RS5K или подконтейнер «pad» [RS5K, filter, eq, comp, dist] — эффекты
-- пэда обрабатывают только его звук. В DSP — сетка ячеек: имя пэда и подпись
-- на выбор (cell: note — MIDI-нота, key — клавиша q2w3er, wave — волна куска,
-- spec — спектральные пики); справа — свойства выбранного пэда и слоты эффектов.
--
-- Слоты: четыре категории (flt eq comp dist) — список любимых эффектов на
-- категорию (ExtState, свои добавляются из браузера), плюс stretch — запекание
-- куска алгоритмом REAPER (RS5K сам время не тянет).
--
-- Без reaper.*: расчёты и раскладка; тест tests/test_drumrack.lua.

local DR = {}

DR.CELL_MODES = { 'note', 'key', 'wave', 'spec' }
DR.CATS = { 'flt', 'eq', 'comp', 'dist' }
DR.CAT_NAME = { flt = 'filter', eq = 'eq', comp = 'compressor', dist = 'distortion' }

-- любимые по умолчанию — штатные REAPER (есть у всех); свои — ExtState drumfav_<cat>
DR.DEFAULT_FAV = {
  flt = { 'JS: Moog 4-Pole Filter', 'JS: State Variable Morphing Filter', 'JS: Resonant Lowpass Filter' },
  eq = { 'ReaEQ (Cockos)' },
  comp = { 'ReaComp (Cockos)', 'ReaXcomp (Cockos)' },
  dist = { 'JS: Saturation', 'JS: Distortion', 'JS: Waveshaping Distortion' },
}

local WORDS = {
  flt = { 'filter', 'lowpass', 'highpass', 'bandpass', 'svf', 'ladder', 'moog', 'lpf', 'hpf', 'cutoff', 'formant', 'wah' },
  eq = { 'eq', 'equal', 'tilt', 'shelf', 'parametric' },
  comp = { 'comp', 'limit', 'glue', 'dynamic', 'transient', 'gate', 'expander', 'leveler' },
  dist = { 'dist', 'satur', 'drive', 'crush', 'tube', 'tape', 'fuzz', 'clip', 'decimat', 'bitcrush', 'derez', 'console', 'density', 'overdrive' },
}

-- избранное: «имя|имя|…» ↔ список; пустая строка — умолчание
function DR.parse_fav(s, cat)
  local out = {}
  for raw in (s or ''):gmatch('[^|]+') do
    local nm = raw:match('^%s*(.-)%s*$')
    if nm ~= '' then out[#out + 1] = nm end
  end
  if #out == 0 then for _, nm in ipairs(DR.DEFAULT_FAV[cat] or {}) do out[#out + 1] = nm end end
  return out
end
function DR.encode_fav(list) return table.concat(list or {}, '|') end
-- добавить в начало (свежее — первым), без повторов, не больше 12
function DR.fav_add(list, nm)
  local out = { nm }
  for _, x in ipairs(list or {}) do if x ~= nm and #out < 12 then out[#out + 1] = x end end
  return out
end

-- имя плагина без префикса типа и разработчика: «VST3: Pro-Q 3 (FabFilter)» → «Pro-Q 3»
function DR.short(nm)
  return ((nm or ''):gsub('^[^:]*: ', ''):gsub('%s*%b()%s*$', ''))
end

-- категория эффекта в пэде: сначала избранное (точное имя), потом слова имени;
-- eq раньше flt («ReaEQ» — эквалайзер, хоть и фильтрует)
function DR.cat_of(nm, favs)
  local s = DR.short(nm):lower()
  for _, cat in ipairs(DR.CATS) do
    for _, f in ipairs(favs and favs[cat] or {}) do if DR.short(f):lower() == s then return cat end end
  end
  for _, cat in ipairs({ 'eq', 'flt', 'comp', 'dist' }) do
    for _, w in ipairs(WORDS[cat]) do if s:find(w, 1, true) then return cat end end
  end
  return nil
end

-- место нового эффекта в пэде: после RS5K и после эффектов категорий раньше в DR.CATS;
-- cats — категории детей пэда по порядку (первый — RS5K: 'rs5k'); 0-based индекс
function DR.insert_pos(cats, cat)
  local rank = {}
  for k, c in ipairs(DR.CATS) do rank[c] = k end
  local want = rank[cat] or 99
  local pos = 0
  for k, c in ipairs(cats) do
    if c == 'rs5k' or (rank[c] or 99) <= want then pos = k end
  end
  return pos
end

-- сетка пэдов: n пэдов в w × h пикселей; ячейка не уже minw и не ниже minh;
-- колонок — степень двойки до 8 (4 × 4 как у пэдов), сколько влезает
function DR.grid(n, w, h, minw, minh)
  n = math.max(1, n or 1)
  local cols = 1
  for _, c in ipairs({ 8, 4, 2 }) do
    if w // c >= minw then cols = c; break end
  end
  cols = math.min(cols, n)
  local rows = math.ceil(n / cols)
  local cw = w // cols
  local ch = math.max(minh, math.min(h // math.max(1, rows), minh * 3))
  local fit = math.max(1, h // ch)            -- рядов на экран (больше — прокрутка)
  return { cols = cols, rows = rows, cw = cw, ch = ch, fit = fit }
end

-- клавиша набора для ноты: piano — карта «буква (или её код) → полутон от C октавы», oct — октава;
-- нота вне раскладки — nil
function DR.key_of(note, piano, oct)
  if not (note and piano) then return nil end
  local off = note - ((oct or 4) + 1) * 12
  local best
  for k, o in pairs(piano) do
    local ch = type(k) == 'number' and k >= 32 and k < 127 and string.char(k) or k   -- keys.piano: коды символов
    if o == off and type(ch) == 'string' and #ch == 1 then
      if not best or ch < best then best = ch end
    end
  end
  return best
end

-- пэд из ребёнка контейнера: RS5K сам или первый ребёнок подконтейнера;
-- kid.entry — модуль ребёнка (model.build_one), kid.entry.kids — внуки
-- 19 окт: в ячейке — любые контейнеры: первый RS5K в глубину (слой RS5K параллельно, эффекты, вложенные контейнеры)
function DR.pad_rs5k(kid, depth)
  local e = kid and kid.entry
  if not e then return nil end
  if e.rs5k then return e, kid.i end
  if e.container and (depth or 0) < 4 then
    for _, g in ipairs(e.kids or {}) do
      local re, ri = DR.pad_rs5k(g, (depth or 0) + 1)
      if re then return re, ri end
    end
  end
  return nil
end
-- контейнер — драм-рэк: больше одного пэда и все дети — пэды
function DR.is_rack(kids)
  if not kids or #kids < 2 then return false end
  for _, kid in ipairs(kids) do if not DR.pad_rs5k(kid) then return false end end
  return true
end

-- stretch: запись параметров запекания в P_EXT трека (по GUID RS5K) — «файл|a|b|режим|полутоны|скорость»
function DR.bake_encode(t)
  return ('%s|%.6f|%.6f|%d|%.3f|%.4f'):format(t.file or '', t.a or 0, t.b or 1, t.mode or -1, t.pitch or 0, t.rate or 1)
end
function DR.bake_decode(s)
  local f, a, b, m, p, r = (s or ''):match('^(.*)|([%d%.%-]+)|([%d%.%-]+)|(%-?%d+)|([%d%.%-]+)|([%d%.%-]+)$')
  if not f or f == '' then return nil end
  return { file = f, a = tonumber(a), b = tonumber(b), mode = tonumber(m), pitch = tonumber(p), rate = tonumber(r) }
end

return DR
