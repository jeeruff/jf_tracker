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

return CH
