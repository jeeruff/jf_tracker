-- jf_tracker_chord.lua — аккорды (8 окт): анализатор и гармонайзер.
--
-- CH.name(pitches)        — MIDI-ноты → обозначение («A#m», «G#6», «Cmaj7/E»);
--                           одна нота — её имя, не узнали — «A#?».
-- CH.parse(sym)           — «Cm7», «F#maj9/A#» → root (0..11), интервалы, bass.
-- CH.voicing(sym, oct)    — обозначение → MIDI-ноты, тесное расположение от
--                           корня в октаве oct (4 → C-4 = 60), бас — ниже.
--
-- Без reaper.* — тестируется в tests/test_chord.lua.

local CH = {}

CH.NAMES = { 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B' }
local PC = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11 }

-- шаблоны: суффикс → интервалы от корня (порядок = предпочтение при равенстве)
CH.T = {
  { '', { 0, 4, 7 } }, { 'm', { 0, 3, 7 } }, { '7', { 0, 4, 7, 10 } }, { 'maj7', { 0, 4, 7, 11 } },
  { 'm7', { 0, 3, 7, 10 } }, { 'dim', { 0, 3, 6 } }, { 'aug', { 0, 4, 8 } }, { 'sus4', { 0, 5, 7 } },
  { 'sus2', { 0, 2, 7 } }, { '6', { 0, 4, 7, 9 } }, { 'm6', { 0, 3, 7, 9 } }, { 'm7b5', { 0, 3, 6, 10 } },
  { 'dim7', { 0, 3, 6, 9 } }, { 'mMaj7', { 0, 3, 7, 11 } }, { 'add9', { 0, 2, 4, 7 } }, { 'madd9', { 0, 2, 3, 7 } },
  { '9', { 0, 2, 4, 7, 10 } }, { 'maj9', { 0, 2, 4, 7, 11 } }, { 'm9', { 0, 2, 3, 7, 10 } }, { '7sus4', { 0, 5, 7, 10 } },
  { 'aug7', { 0, 4, 8, 10 } }, { '5', { 0, 7 } },
  -- без квинты — частые голосоведения
  { '7', { 0, 4, 10 } }, { 'maj7', { 0, 4, 11 } }, { 'm7', { 0, 3, 10 } },
}
local function key(set) table.sort(set); return table.concat(set, ',') end
local BY = {}
for i, t in ipairs(CH.T) do
  local k = key({ table.unpack(t[2]) })
  if not BY[k] then BY[k] = { suffix = t[1], rank = i } end
end
local SUF = {}
for _, t in ipairs(CH.T) do if not SUF[t[1]] then SUF[t[1]] = t[2] end end

function CH.note_name(p) return CH.NAMES[p % 12 + 1] end

function CH.name(pitches)
  if not pitches or #pitches == 0 then return nil end
  local lo, pcs, seen = math.huge, {}, {}
  for _, p in ipairs(pitches) do
    if p < lo then lo = p end
    local c = p % 12
    if not seen[c] then seen[c] = true; pcs[#pcs + 1] = c end
  end
  local bass = lo % 12
  if #pcs == 1 then return CH.NAMES[bass + 1] end
  local best
  for _, root in ipairs(pcs) do
    local rel = {}
    for _, c in ipairs(pcs) do rel[#rel + 1] = (c - root) % 12 end
    local m = BY[key(rel)]
    if m then
      -- корень в басу — лучше; дальше — порядок шаблонов
      local score = (root == bass and 0 or 100) + m.rank
      if not best or score < best.score then best = { root = root, suffix = m.suffix, score = score } end
    end
  end
  if not best then return CH.NAMES[bass + 1] .. '?' end
  local s = CH.NAMES[best.root + 1] .. best.suffix
  if best.root ~= bass then s = s .. '/' .. CH.NAMES[bass + 1] end
  return s
end

-- «C#m7/G#» → root 1, ints {0,3,7,10}, bass 8; не узнали — nil
local function pc_of(s)
  local l, acc = s:match('^([A-Ga-g])([#b]?)')
  if not l then return nil end
  local v = PC[l:upper()] + (acc == '#' and 1 or (acc == 'b' and -1 or 0))
  return v % 12, #l + #acc
end
function CH.parse(sym)
  sym = (sym or ''):gsub('%s', '')
  local root, n = pc_of(sym)
  if not root then return nil end
  local rest = sym:sub(n + 1)
  local bass
  local main, b = rest:match('^(.-)/(.+)$')
  if main then bass = pc_of(b); rest = main end
  local alias = { M = '', maj = '', min = 'm', ['-'] = 'm', mi = 'm', ['°'] = 'dim', o = 'dim', ['+'] = 'aug', M7 = 'maj7', ['Δ'] = 'maj7', ['ø'] = 'm7b5', ['-7'] = 'm7', min7 = 'm7', sus = 'sus4' }
  rest = alias[rest] or rest
  local ints = SUF[rest]
  if not ints then return nil end
  return { root = root, ints = ints, bass = bass, suffix = rest }
end

-- ноты: корень в октаве oct (C-4 = 60 при oct 4), остальное — вверх тесно;
-- бас (/X) — отдельной нотой на октаву ниже корня
function CH.voicing(sym, oct)
  local c = CH.parse(sym)
  if not c then return nil end
  local base = (oct or 4) * 12 + 12 + c.root
  local out = {}
  for _, i in ipairs(c.ints) do out[#out + 1] = base + i end
  if c.bass and c.bass ~= c.root then
    local b = (oct or 4) * 12 + c.bass
    while b >= base do b = b - 12 end
    table.insert(out, 1, b)
  end
  return out
end

-- линия аккордов (8 окт, chord follow): ноты { {t0, t1, pitch}, … } (время
-- проекта) → точки смены { {pos, mask, root}, … } по возрастанию pos:
-- mask — 12 бит классов звучащих нот (0 — тишина), root — корень по CH.name
-- (не узнали — бас; тишина — −1). Соседние одинаковые точки сливаются
function CH.timeline(notes)
  local pts = {}
  for _, n in ipairs(notes or {}) do pts[#pts + 1] = n[1]; pts[#pts + 1] = n[2] end
  table.sort(pts)
  local out = {}
  local last
  for i, t in ipairs(pts) do
    if i == 1 or t > pts[i - 1] + 1e-6 then
      local mask, ps = 0, {}
      for _, n in ipairs(notes) do
        if n[1] <= t + 1e-6 and n[2] > t + 1e-6 then mask = mask | (1 << (n[3] % 12)); ps[#ps + 1] = n[3] end
      end
      local root = -1
      if #ps > 0 then
        local nm = CH.name(ps)
        local c = nm and CH.parse((nm:gsub('%?$', '')))
        if c and not nm:find('?', 1, true) then root = c.root
        else local lo = math.huge; for _, p in ipairs(ps) do if p < lo then lo = p end end; root = lo % 12 end
      end
      if not last or last.mask ~= mask or last.root ~= root then
        last = { pos = t, mask = mask, root = root }
        out[#out + 1] = last
      end
    end
  end
  return out
end

-- нотный стан (9 окт): высота → ступень (C-1 = 0, C4 = 28, E4 = 30 — нижняя
-- линия скрипичного ключа) и знак (диезы, как CH.NAMES)
local LETTER = { C = 0, D = 1, E = 2, F = 3, G = 4, A = 5, B = 6 }
function CH.staff_step(p)
  local nm = CH.NAMES[p % 12 + 1]
  local oct = p // 12 - 1
  return oct * 7 + LETTER[nm:sub(1, 1)], (nm:sub(2) ~= '' and nm:sub(2) or nil)
end

-- гитара (9 окт): аппликатура аккорда в стандартном строе (E A D G B E),
-- лады по струнам от 6-й (низкой) к 1-й, −1 — не играть. Перебор окон по 4
-- лада (и открытые струны): в басу — корень (или бас /X), все звуки
-- аккорда, без заглушённых посередине, ближе к началу грифа
CH.TUNING = { 40, 45, 50, 55, 59, 64 }
local gcache = {}
function CH.guitar(sym)
  if gcache[sym] ~= nil then return gcache[sym] or nil end
  local c = CH.parse(sym)
  if not c then gcache[sym] = false; return nil end
  local want, nwant = {}, 0
  for _, i in ipairs(c.ints) do local pc = (c.root + i) % 12; if not want[pc] then want[pc] = true; nwant = nwant + 1 end end
  local bass = c.bass or c.root
  if not want[bass] then want[bass] = true; nwant = nwant + 1 end
  local best, bscore
  local fr = {}
  for b = 0, 9 do
    local opts = {}
    for s = 1, 6 do
      local o = { -1 }
      for f = (b == 0 and 0 or b), b + 3 do if want[(CH.TUNING[s] + f) % 12] then o[#o + 1] = f end end
      if b > 0 and want[CH.TUNING[s] % 12] then o[#o + 1] = 0 end
      opts[s] = o
    end
    local function rec(s)
      if s > 6 then
        -- оценка
        local low, n, inner, have, cnt, lo, hi = nil, 0, 0, {}, 0, 99, 0
        local started, gap, fretted, opens = false, false, false, 0
        for k = 1, 6 do
          local f = fr[k]
          if f >= 0 then
            if gap then inner = inner + 1 end
            started = true; n = n + 1
            local pc = (CH.TUNING[k] + f) % 12
            if not low then low = pc end
            if not have[pc] then have[pc] = true; cnt = cnt + 1 end
            if f > 0 then lo = math.min(lo, f); hi = math.max(hi, f); fretted = true
            elseif fretted then opens = opens + 1 end                       -- открытая над прижатой — неудобно
          elseif started then gap = true end
        end
        -- открытая сразу над прижатым басом (F: 1 0 3 …) — неудобно
        local bopen = false
        for k = 1, 5 do if fr[k] >= 0 then bopen = fr[k] > 0 and fr[k + 1] == 0; break end end
        if not low or low ~= bass or n < math.min(4, nwant) then return end
        -- заглушённая посередине: только если дальше снова звук
        local sc = (nwant - cnt) * 20 + inner * 8 + (6 - n) * 2 + (hi > 0 and (hi - lo) or 0) + b * 1.5 + opens * (b > 0 and 4 or 0) + (bopen and 3 or 0)
        if not bscore or sc < bscore then bscore = sc; best = { table.unpack(fr) } end
        return
      end
      for _, f in ipairs(opts[s]) do fr[s] = f; rec(s + 1) end
    end
    rec(1)
  end
  gcache[sym] = best or false
  return best
end

return CH
