-- jf_tracker_fxparse.lua — парсер параметров плагина по тексту значения (PLAN_DSP этапы 1–2, 22 окт).
--
-- Правила взяты из образцов tests/fixtures/fxdump (RS5K, Surge XT): тексты при 0 / .25 / .5 / .75 / 1.
--   FP.unit(text)        → 'db' 'hz' 'time' 'pct' 'semi' 'cent' 'note' 'onoff' 'num' 'text'
--   FP.num(text)         → число в базовой единице (Hz, ms, dB; −inf → −math.huge) или nil
--   FP.classify(texts, toggle) → { kind = toggle | steps | bipolar | db | freq | time | pct | semi | note | plain,
--                                  unit, log (шаг не линейный: частота / время), bipolar }
--   FP.compact(text)     → короткий вид значения: 25087.71 Hz → 25.1k, 353.6 ms → 354ms, 3.36 s → 3.4s,
--                          -7.47 dB → -7.5, -inf dB → -inf, 50.00 % → 50%, 3.50 semitones → +3.5st
--   FP.abbr(name, n)     → короче по словарю сокращений (длиннее n — обрежет fit отрисовки)
-- Без reaper.* — тест tests/test_fxparse.lua.

local FP = {}

local function trim(s) return ((s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

-- 22 окт: Serum 2 — «25% [-21.1 dB]» (главное — в скобках), «-∞», пан «-50 L» / «25 R», октавы «-4 oct»
local function norm(text)
  local t = trim(text):lower():gsub('\226\136\158', 'inf')      -- ∞ → inf
  local br = t:match('%[([^%]]*)%]')
  if br and br:find('db', 1, true) then t = trim(br) end
  return t
end
function FP.unit(text)
  local t = norm(text)
  if t == '' then return nil end
  if t:match('^[%+%-]?inf') and t:find('db', 1, true) then return 'db' end
  if t:find('%f[%a]db%f[%A]') or t:match('db$') then return 'db' end
  if t:find('%f[%a]k?hz%f[%A]') or t:match('k?hz$') then return 'hz' end
  if t:find('semitone', 1, true) or t:match('%d%s*st$') then return 'semi' end
  if t:match('^[%+%-]?[%d%.]+%s*oct') then return 'oct' end
  if t:find('cent', 1, true) then return 'cent' end
  if t:match('^[%+%-]?[%d%.]+%s*ms$') or t:match('^[%+%-]?[%d%.]+%s*s$') or t:match('^[%+%-]?[%d%.]+%s*sec') then return 'time' end
  if t:match('^[%+%-]?[%d%.]+%s*%%') then return 'pct' end
  if t:match('^[%+%-]?[%d%.]+%s*[lr]$') then return 'pan' end
  if trim(text):match('^[A-G][#b]?%-?%d$') then return 'note' end
  if t == 'on' or t == 'off' then return 'onoff' end
  if t:match('^[%+%-]?%d*%.?%d+$') then return 'num' end
  return 'text'
end

function FP.num(text)
  local t = norm(text)
  if t:match('^%-inf') then return -math.huge end
  if t:match('^%+?inf') then return math.huge end
  local n = tonumber(t:match('^[%+%-]?%d*%.?%d+'))
  if not n then return nil end
  local u = FP.unit(text)
  if u == 'hz' and t:find('khz', 1, true) then n = n * 1000 end
  if u == 'time' and not t:find('ms', 1, true) then n = n * 1000 end   -- секунды → ms
  if u == 'pan' and t:match('l$') and n > 0 then n = -n end           -- «50 L» без минуса — левее
  return n
end

local UKIND = { db = 'db', hz = 'freq', time = 'time', pct = 'pct', semi = 'semi', cent = 'semi', oct = 'semi', pan = 'plain', note = 'note', num = 'plain' }

function FP.classify(texts, toggle)
  local units, distinct, nd = {}, {}, 0
  for _, s in ipairs(texts) do
    local u = FP.unit(s)
    if u then units[#units + 1] = u end
    local k = trim(s):lower()
    if k ~= '' and not distinct[k] then distinct[k] = true; nd = nd + 1 end
  end
  local main
  local cnt = {}
  for _, u in ipairs(units) do cnt[u] = (cnt[u] or 0) + 1; if not main or cnt[u] > cnt[main] then main = u end end
  local r = { unit = main }
  -- переключатель: флаг плагина или два значения из 0 / 1 / on / off
  local binary = nd == 2
  if binary then for k in pairs(distinct) do if not (k == '0' or k == '1' or k == 'on' or k == 'off') then binary = false end end end
  if toggle or binary then r.kind = 'toggle'; return r end
  if main == 'text' or main == 'onoff' then r.kind = 'steps'; return r end
  if main == 'note' and nd == 1 then r.kind = 'plain'; return r end   -- Keytrack Root Key: C4 на всём ходу — показ, не ступени
  local n1, n3, n5 = FP.num(texts[1]), FP.num(texts[3]), FP.num(texts[5])
  if n1 and n3 and n5 and n1 > -math.huge and n5 < math.huge then
    local span = n5 - n1
    if n1 < 0 and n5 > 0 and math.abs(n3) <= math.abs(span) * 0.02 then r.bipolar = true end
    if span ~= 0 and (main == 'hz' or main == 'time') then
      local mid = (n1 + n5) / 2
      if math.abs(n3 - mid) > math.abs(span) * 0.2 then r.log = true end
    end
  end
  r.kind = r.bipolar and 'bipolar' or (UKIND[main] or 'plain')
  return r
end

local function g(v, d)   -- число без лишних нулей
  local s = ('%.' .. d .. 'f'):format(v)
  if s:find('%.') then s = s:gsub('0+$', ''):gsub('%.$', '') end
  return s
end

function FP.compact(text)
  local u = FP.unit(text)
  local n = FP.num(text)
  if not n then return trim(text) end
  if n == -math.huge then return '-inf' end
  local a = math.abs(n)
  if u == 'hz' then
    if a >= 10000 then return g(n / 1000, 1) .. 'k' elseif a >= 1000 then return g(n / 1000, 2) .. 'k'
    elseif a >= 100 then return g(n, 0) elseif a >= 10 then return g(n, 1) end
    return g(n, 2)
  elseif u == 'time' then
    if a >= 10000 then return g(n / 1000, 1) .. 's' elseif a >= 1000 then return g(n / 1000, 2) .. 's'
    elseif a >= 10 then return g(n, 0) .. 'ms' end
    return g(n, 1) .. 'ms'
  elseif u == 'db' then return (n > 0 and '+' or '') .. g(n, 1)
  elseif u == 'pct' then return g(n, a >= 10 and 0 or 1) .. '%'
  elseif u == 'semi' then return (n > 0 and '+' or '') .. g(n, 1) .. 'st'
  elseif u == 'cent' then return (n > 0 and '+' or '') .. g(n, 0) .. 'ct'
  elseif u == 'oct' then return (n > 0 and '+' or '') .. g(n, 0) .. 'oct'
  elseif u == 'pan' then return n == 0 and 'C' or (g(math.abs(n), 0) .. (n < 0 and 'L' or 'R')) end
  return trim(text)
end

-- словарь: слово (нижний регистр) → сокращение; порядок не важен, применяются по одному, пока не влезет
FP.ABBR = {
  highpass = 'hp', lowpass = 'lp', bandpass = 'bp', notch = 'ntch', feedback = 'fb', frequency = 'freq',
  resonance = 'reso', cutoff = 'cut', attack = 'att', decay = 'dec', sustain = 'sus', release = 'rel',
  amount = 'amt', envelope = 'env', oscillator = 'osc', volume = 'vol', level = 'lvl', detune = 'det',
  keytrack = 'kt', velocity = 'vel', modulation = 'mod', depth = 'dpt', offset = 'offs', width = 'wid',
  balance = 'bal', filter = 'flt', shape = 'shp', phase = 'ph', drive = 'drv', octave = 'oct', pitch = 'ptch',
  channel = 'ch', stereo = 'st', position = 'pos', threshold = 'thr', ratio = 'rat', gain = 'gn', range = 'rng',
  minimum = 'min', maximum = 'max', start = 'st', ['end'] = 'end', note = 'nt', voices = 'vox', sample = 'smp',
  crossfade = 'xf', length = 'len', mode = 'md', type = 'typ', time = 't', rate = 'rt', delay = 'dly',
  reverb = 'rvb', chorus = 'chr', distortion = 'dist', compressor = 'comp', ring = 'rng', noise = 'nz',
  sine = 'sin', triangle = 'tri', tri = 'tri', square = 'sqr', sawtooth = 'saw', saw = 'saw', random = 'rnd', ramp = 'rmp', pulse = 'pls',   -- 31 окт: формы LFO — кнопки ступеней
  global = 'gl', portamento = 'porta', pitchbend = 'pb', bend = 'bnd', round = 'rnd', robin = 'rb',
}

function FP.abbr(name, n)
  name = trim(name)
  if #name <= n then return name end
  local words = {}
  for w in name:gmatch('%S+') do words[#words + 1] = w end
  local function join() return table.concat(words, ' ') end
  -- 1) словарь: с самого длинного слова
  local order = {}
  for i = 1, #words do order[i] = i end
  table.sort(order, function(a, b) return #words[a] > #words[b] end)
  for _, i in ipairs(order) do
    local a = FP.ABBR[words[i]:lower()]
    if a then words[i] = a; if #join() <= n then return join() end end
  end
  -- 23 окт: дальше — как есть (обрежет fit, по краю видно, что обрезано): «без гласных» давало нечитаемое (Mdrmr)
  return join()
end

-- 22 окт (этап 1): огибающие — attack, [hold], decay, sustain, release подряд с общим префиксом группы
-- («Amp Attack», «Env 2 Decay», «f att», «1 A»), между ними — их форма («Attack Shape», curve, slope):
-- Surge (A shape D shape S R), Serum 2 (A H D S R). Одна буква (A D S R) — только полной группой подряд.
-- names → { [первый] = { last = последний, role = { [индекс] = 'a' 'h' 'd' 's' 'r' 'x' (форма) }, a = , h = , d = , s = , r = } }
local ADSR_KEY = {
  attack = 'a', att = 'a', atk = 'a', a = 'a', hold = 'h', hld = 'h', h = 'h', decay = 'd', dec = 'd', dcy = 'd', d = 'd',
  sustain = 's', sus = 's', s = 's', release = 'r', rel = 'r', rls = 'r', r = 'r',
}
local function adsr_split(name)
  local t = trim(name):lower()
  local shape = false
  local base = t:match('^(.-)%s+shape$') or t:match('^(.-)%s+curve$') or t:match('^(.-)%s+slope$')
  if base then t, shape = base, true end
  local pre, w = t:match('^(.-)%s*([%a]+)$')
  if not w then return nil end
  local k = ADSR_KEY[w]
  if not k then return nil end
  return k, pre, #w == 1, shape
end
function FP.adsr_groups(names)
  local out = {}
  local i = 1
  while i <= #names - 3 do
    local k1, p1, s1, sh1 = adsr_split(names[i])
    local g
    if k1 == 'a' and not sh1 then
      g = { a = i, role = { [i] = 'a' } }
      local want = { 'h', 'd', 's', 'r' }
      local wi, j = 1, i + 1
      while j <= #names and wi <= #want do
        local k, pre, single, sh = adsr_split(names[j])
        if not k or pre ~= p1 or single ~= s1 then break end
        if sh then g.role[j] = 'x'                                   -- форма предыдущего узла
        elseif k == want[wi] then g[k] = j; g.role[j] = k; wi = wi + 1
        elseif want[wi] == 'h' and k == 'd' then wi = wi + 1; g.d = j; g.role[j] = 'd'; wi = wi + 1   -- hold нет
        else break end
        j = j + 1
      end
      if g.d and g.s and g.r then g.last = g.r; out[i] = g; i = g.r + 1 else g = nil end
    end
    if not g then i = i + 1 end
  end
  return out
end

return FP
