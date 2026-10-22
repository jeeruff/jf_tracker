-- jf_tracker_fxclass.lua — классификатор параметров FX и автомодуль (3 окт).
--
-- Любой эффект без своей записи в реестре становится модулем DSP: параметры
-- получают категорию и цвет, подгруппу из имени и порядок по важности.
--
-- Категория — сначала по единицам в тексте значения (dB, Hz, ms, %, st),
-- затем по словам имени: gain, filter, time, pitch, mix, dyn, stereo, mod,
-- mode (тумблеры и переключатели), other. «Freq» бывает и фильтром, и
-- скоростью LFO — единицы различают точнее имени.
-- Подгруппа — префикс имени: «amp1attack» → amp1 / attack, «f1cutoff» →
-- f1 / cutoff, «Osc 2 Pitch» → osc 2 / pitch, «Filter Cutoff» → filter /
-- cutoff, «ampAttack» → amp / attack.
-- Служебное (Bypass, Wet, Delta, MIDI CC, «Param 123», «#12», пустое)
-- выбрасывается.
--
-- Считается один раз на тип плагина (main кэширует по имени и числу
-- параметров), не каждый кадр. Без reaper.*: тестируется tests/test_fxclass.lua.

local FC = {}

FC.CATS = { 'gain', 'filter', 'time', 'pitch', 'mix', 'dyn', 'stereo', 'mod', 'mode', 'other' }

local WORDS = {
  gain = { 'gain', 'volume', 'vol', 'level', 'output', 'out', 'input', 'makeup', 'trim', 'amp', 'loud' },
  filter = { 'cutoff', 'cut', 'freq', 'frequency', 'reso', 'resonance', 'q', 'lp', 'hp', 'bp', 'filter', 'flt', 'tone', 'tilt', 'band', 'shelf', 'eq' },
  time = { 'attack', 'att', 'decay', 'dec', 'sustain', 'sus', 'release', 'rel', 'hold', 'delay', 'time', 'predelay', 'length', 'size', 'rate', 'speed', 'tempo', 'sync' },
  pitch = { 'pitch', 'tune', 'detune', 'semi', 'semitone', 'cent', 'cents', 'fine', 'coarse', 'transpose', 'octave', 'oct', 'note', 'key' },
  mix = { 'mix', 'wet', 'dry', 'blend', 'balance', 'send' },
  dyn = { 'threshold', 'thresh', 'ratio', 'knee', 'comp', 'limit', 'gate', 'drive', 'sat', 'saturation', 'dist', 'distortion', 'crush', 'bits' },
  stereo = { 'pan', 'width', 'spread', 'stereo', 'mid', 'side', 'ms' },
  mod = { 'lfo', 'depth', 'amount', 'amt', 'mod', 'modulation', 'env', 'envelope', 'feedback', 'fb', 'chorus', 'phaser', 'flanger', 'vibrato', 'tremolo' },
}
local WORD_CAT = {}
for cat, list in pairs(WORDS) do for _, w in ipairs(list) do WORD_CAT[w] = WORD_CAT[w] or cat end end

-- важность для автомодуля: чем больше, тем раньше
local RANK = { gain = 90, mix = 85, filter = 80, dyn = 70, time = 60, pitch = 55, mod = 50, stereo = 45, mode = 30, other = 10 }
local WORD_RANK = { cutoff = 12, reso = 8, resonance = 8, mix = 10, wet = 9, gain = 10, output = 9, threshold = 9, ratio = 6,
  attack = 6, release = 5, drive = 8, freq = 5, frequency = 5, decay = 4, time = 4, feedback = 4, size = 4, width = 3 }

local JUNK = { bypass = true, wet = false, delta = true }

-- служебный параметр?
function FC.junk(name)
  local n = (name or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
  if n == '' or n == '-' then return true end
  if n == 'bypass' or n == 'delta' or n == 'wet' then return true end   -- добавки REAPER к каждому FX
  if n:match('^midi cc') or n:match('^cc%s*%d') or n:match('^param%s*%d+$') or n:match('^#%d+$') or n:match('^parameter%s*%d+$') then return true end
  if n:match('^%-') then return true end                                 -- скрытый слайдер JSFX
  if n:match('^reserved') or n:match('^unused') or n:match('^%(unused') then return true end
  return false
end

-- подгруппа и основа имени
function FC.split(name)
  local s = (name or ''):gsub('^%s+', ''):gsub('%s+$', '')
  -- «Osc 2 Pitch», «Band 3 Freq», «LFO1 Rate»
  local g, rest = s:match('^(%a+%s*%d+)[%s_%-%.:/]+(.+)$')
  if g then return g:lower():gsub('%s+', ' '), rest end
  -- «amp1attack», «f1cutoff», «env2decay»
  g, rest = s:match('^(%a+%d+)(%a.*)$')
  if g then return g:lower(), rest end
  -- «ampAttack», «filterCutoff» (camelCase)
  g, rest = s:match('^(%l+)(%u%a.*)$')
  if g and #g >= 2 then return g, rest end
  -- «Filter Cutoff», «Amp: Attack», «EQ - Low Gain» — первое слово-группа
  g, rest = s:match('^(%a+)[%s_%-%.:/]+(.+)$')
  if g then
    local gl = g:lower()
    local known = { filter = 1, filt = 1, flt = 1, amp = 1, env = 1, lfo = 1, osc = 1, eq = 1, comp = 1, delay = 1, reverb = 1, verb = 1,
                    chorus = 1, dist = 1, drive = 1, mod = 1, pitch = 1, mix = 1, gate = 1, sat = 1, low = 1, high = 1, mid = 1, master = 1 }
    if known[gl] then return gl, rest end
  end
  return '', s
end

local function words_of(s)
  local out = {}
  for w in s:lower():gmatch('%a+') do out[#out + 1] = w end
  -- camelCase и склейки: «cutoff» внутри «f1cutoff» уже отрезан split'ом
  return out
end

-- категория: units — текст значения («-6.0 dB», «1200 Hz»), kind — slider / toggle / steps
function FC.class(name, units, kind)
  if kind == 'toggle' or kind == 'steps' then return 'mode' end
  local u = (units or ''):lower()
  if u:find('db') then return 'gain' end
  if u:find('%d%s*k?hz') then
    local n = (name or ''):lower()
    if n:find('lfo') or n:find('rate') or n:find('speed') or n:find('mod') then return 'mod' end
    return 'filter'
  end
  if u:find('%d%s*ms') or u:find('%d%s*sec') or u:find('%d%s*s$') then return 'time' end
  if u:find('semi') or u:find('%d%s*st$') or u:find('cent') then return 'pitch' end
  local _, base = FC.split(name)
  local best
  for _, w in ipairs(words_of(base)) do if WORD_CAT[w] then best = WORD_CAT[w]; break end end
  if not best then for _, w in ipairs(words_of(name or '')) do if WORD_CAT[w] then best = WORD_CAT[w]; break end end end
  if best then return best end
  if u:find('%%') then return 'mix' end
  return 'other'
end

-- макро-параметр: «Macro 1», «macro 8», «Macro1»
function FC.is_macro(name) return (name or ''):lower():match('^%s*macro%s*%d') ~= nil end

function FC.rank(name, cat)
  local r = RANK[cat] or 0
  local _, base = FC.split(name)
  for _, w in ipairs(words_of(base)) do r = r + (WORD_RANK[w] or 0) end
  return r
end

-- короткая подпись: «f1 cutoff», «osc 2 pitch»
function FC.label(name)
  local g, base = FC.split(name)
  base = base:gsub('%s+', ' ')
  if g ~= '' then return g .. ' ' .. base:lower() end
  return base
end

-- автомодуль: list = { { i =, name =, units =, kind = } … } → упорядоченный
-- список { i =, name = подпись, cat =, group = } длиной ≤ max, группы вместе,
-- внутри группы — по категории и важности; группы — по самой важной в группе
function FC.auto(list, max)
  local items, groups = {}, {}
  for _, p in ipairs(list) do
    if not FC.junk(p.name) then
      local g = FC.split(p.name)
      local cat = FC.class(p.name, p.units, p.kind)
      local it = { i = p.i, name = FC.label(p.name), cat = cat, group = g, rank = FC.rank(p.name, cat), kind = p.kind }
      items[#items + 1] = it
      groups[g] = math.max(groups[g] or 0, it.rank)
    end
  end
  -- макро (4 окт): «Macro N» плагина — всегда первыми, по порядку, вне
  -- сортировки по важности (это главные ручки синтов вроде Serum)
  local macros, rest = {}, {}
  for _, it in ipairs(items) do
    if FC.is_macro(it.name) then macros[#macros + 1] = it else rest[#rest + 1] = it end
  end
  local function mnum(it) return tonumber((it.name or ''):match('(%d+)')) or 0 end
  table.sort(macros, function(a, b) local x, y = mnum(a), mnum(b); if x ~= y then return x < y end return a.i < b.i end)
  items = rest
  -- лучшие max по важности, потом — сгруппировать
  table.sort(items, function(a, b) if a.rank ~= b.rank then return a.rank > b.rank end return a.i < b.i end)
  local top = {}
  for k = 1, math.min((max or 24) - #macros, #items) do top[k] = items[k] end
  local CI = {}
  for k, c in ipairs(FC.CATS) do CI[c] = k end
  table.sort(top, function(a, b)
    if a.group ~= b.group then
      if groups[a.group] ~= groups[b.group] then return groups[a.group] > groups[b.group] end
      return a.group < b.group
    end
    if CI[a.cat] ~= CI[b.cat] then return CI[a.cat] < CI[b.cat] end
    return a.i < b.i
  end)
  for k = #macros, 1, -1 do table.insert(top, 1, macros[k]) end
  return top
end

-- 22 окт: вкладки автомодуля (как у Surge): все параметры плагина → секции синта по префиксу группы
-- («osc 2», «lfo1», «filter») и словам имени. Порядок вкладок — SECTIONS; main — первая (FC.auto по всем),
-- остальное без секции туда же. Вкладки — только если секций с параметрами ≥ 2 и плагин не влезает в одну
-- страницу (> one); иначе nil. → { { name =, items = FC.auto(…) } … }
FC.SECTIONS = { 'osc', 'filter', 'env', 'lfo', 'mod', 'fx' }
local SEC_WORDS = {
  osc = { 'osc', 'oscillator', 'wave', 'wavetable', 'wt', 'shape', 'sub', 'noise', 'unison', 'voices', 'op', 'operator', 'carrier', 'modulator', 'pw', 'pwm', 'sync' },
  filter = { 'filter', 'filt', 'flt', 'vcf', 'cutoff', 'cut', 'reso', 'resonance', 'keytrk', 'keytrack', 'lp', 'hp', 'bp' },
  env = { 'env', 'envelope', 'adsr', 'eg', 'attack', 'att', 'decay', 'dec', 'sustain', 'sus', 'release', 'rel', 'hold' },
  lfo = { 'lfo' },
  mod = { 'mod', 'matrix', 'macro', 'velocity', 'vel', 'aftertouch', 'wheel', 'mw', 'modwheel' },
  fx = { 'fx', 'delay', 'reverb', 'verb', 'chorus', 'phaser', 'flanger', 'dist', 'distortion', 'eq', 'comp', 'bitcrush', 'crush' },
}
local SEC_OF = {}
for sec, list in pairs(SEC_WORDS) do for _, w in ipairs(list) do SEC_OF[w] = sec end end
function FC.section(name)
  local g = FC.split(name)
  local gw = (g or ''):match('^(%a+)')
  if gw and SEC_OF[gw] then return SEC_OF[gw] end      -- префикс решает: «lfo1 rate» — lfo, не время
  for _, w in ipairs(words_of(name or '')) do if SEC_OF[w] then return SEC_OF[w] end end
  return nil
end
function FC.pages(list, max, one)
  max, one = max or 42, one or 24
  local by, n = {}, 0
  for _, p in ipairs(list) do
    if not FC.junk(p.name) then
      n = n + 1
      local sec = FC.section(p.name)
      if sec then by[sec] = by[sec] or {}; by[sec][#by[sec] + 1] = p end
    end
  end
  if n <= one then return nil end
  local pages, nsec = { { name = 'main', items = FC.auto(list, max) } }, 0
  for _, sec in ipairs(FC.SECTIONS) do
    if by[sec] and #by[sec] >= 2 then nsec = nsec + 1; pages[#pages + 1] = { name = sec, items = FC.auto(by[sec], max) } end
  end
  if nsec < 2 then return nil end
  return pages
end

return FC
