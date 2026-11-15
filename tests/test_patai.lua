-- test_patai.lua — автоматизация паттерна в automation items (16 ноя): настоящий jf_tracker_pooled.lua на имитации
-- огибающих и AI REAPER. Проверяется: заворачивание точек паттерна в AI, длина AI при смене длины паттерна, связь AI
-- у повторов (общий пул). Темп (ускорение / замедление) — работа самого REAPER, здесь не
-- имитируется. Запуск: lua tests/test_patai.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local fails, checks = 0, 0
local function ok(name, cond, info)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL ' .. name .. (info and (' (' .. tostring(info) .. ')') or '')) end
end
local function near(a, b) return a and b and math.abs(a - b) < 1e-6 end

local proj = { tracks = {} }
local npool = 0
local unknown = {}
local R = setmetatable({}, { __index = function(_, k) return function() unknown[k] = (unknown[k] or 0) + 1; return nil end end })
reaper = R
local function new_track(name) local tr = { name = name, items = {}, envs = {} }; proj.tracks[#proj.tracks + 1] = tr; return tr end
local function new_env(tr, name) local e = { name = name, pts = {}, ais = {} }; tr.envs[#tr.envs + 1] = e; return e end
R.CountTracks = function() return #proj.tracks end
R.GetTrack = function(_, i) return proj.tracks[i + 1] end
R.GetTrackName = function(tr) return true, tr.name end
R.CountTrackMediaItems = function(tr) return #tr.items end
R.CountTrackEnvelopes = function(tr) return #tr.envs end
R.GetTrackEnvelope = function(tr, i) return tr.envs[i + 1] end
R.CountEnvelopePoints = function(e) return #e.pts end
R.GetEnvelopePoint = function(e, i) local p = e.pts[i + 1]; if not p then return false end; return true, p.t, p.v, 0, 0, false end
R.SetEnvelopePoint = function(e, i, t, v) local p = e.pts[i + 1]; if not p then return false end; p.t = t or p.t; p.v = v or p.v; return true end
R.Envelope_SortPoints = function(e) table.sort(e.pts, function(a, b) return a.t < b.t end) end
R.CountAutomationItems = function(e) return #e.ais end
-- как в REAPER: пул < 0 — новый AI собирает точки отрезка из огибающей; пул >= 0 — экземпляр этого пула
R.InsertAutomationItem = function(e, pool, pos, len)
  local ai = { pos = pos, len = len, pts = {} }
  if pool < 0 then
    npool = npool + 1; ai.pool = npool
    for i = #e.pts, 1, -1 do local p = e.pts[i]; if p.t >= pos - 1e-9 and p.t < pos + len - 1e-9 then table.insert(ai.pts, 1, { t = p.t - pos, v = p.v }); table.remove(e.pts, i) end end
  else ai.pool = pool end
  e.ais[#e.ais + 1] = ai
  return #e.ais - 1
end
R.GetSetAutomationItemInfo = function(e, k, key, v, set)
  local ai = e.ais[k + 1]; if not ai then return 0 end
  local f = ({ D_POSITION = 'pos', D_LENGTH = 'len', D_POOL_ID = 'pool' })[key]
  if not f then return 0 end
  if set then ai[f] = v end
  return ai[f]
end
R.GetMediaItemInfo_Value = function() return 0 end
R.SetMediaItemInfo_Value = function() return true end
R.GetTrackMediaItem = function(tr, i) return tr.items[i + 1] end

local model = { DEPOT = 'DEPOT', is_lib_name = function(n) return n == 'LIB' end }
local P = dofile(DIR .. '/jf_tracker_pooled.lua'); P.init(model, {})

-- песня: A1 [0,8), B1 [8,16), A1 [16,24) (повтор), трек с огибающей: точки в A1 и в B1, одна — до песни нет
local function build()
  proj.tracks = {}
  local tr = new_track('synth')
  local e = new_env(tr, 'Cutoff')
  for _, p in ipairs({ { 1, 0.2 }, { 5, 0.8 }, { 9, 0.5 }, { 30, 0.1 } }) do e.pts[#e.pts + 1] = { t = p[1], v = p[2] } end
  local lib = new_track('LIB'); new_env(lib, 'Volume').pts[1] = { t = 2, v = 1 }
  local regs = { { idx = 1, name = 'A1', pos = 0, rgnend = 8 }, { idx = 2, name = 'B1', pos = 8, rgnend = 16 }, { idx = 3, name = 'A1', pos = 16, rgnend = 24 } }
  return tr, e, regs, lib
end

-- 1. заворачивание
do
  local _, e, regs, lib = build()
  local made, fit = P.pat_ai_wrap({ regs[1] })
  ok('wrap: one AI made for the pattern with points', made == 1 and fit == 0, made .. '/' .. fit)
  ok('wrap: AI spans the pattern', #e.ais == 1 and near(e.ais[1].pos, 0) and near(e.ais[1].len, 8))
  ok('wrap: the two points of A1 moved into the AI', #e.ais[1].pts == 2, #e.ais[1].pts)
  ok('wrap: points of other patterns stay on the envelope', #e.pts == 2, #e.pts)
  ok('wrap: the library track is not touched', #lib.envs[1].ais == 0 and #lib.envs[1].pts == 1)
  made = P.pat_ai_wrap({ regs[1] })
  ok('wrap again: nothing new (the AI is already there)', made == 0 and #e.ais == 1, made)
  made = P.pat_ai_wrap({ regs[3] })
  ok('wrap: a pattern without points gets no AI', made == 0 and #e.ais == 1, made)
end
-- 2. длина паттерна
do
  local _, e, regs = build()
  P.pat_ai_wrap({ regs[1] })
  ok('resize: AI follows the longer pattern', P.pat_ai_fit(0, 12) == 1 and near(e.ais[1].len, 12), e.ais[1].len)
  ok('resize: AI follows the shorter pattern', P.pat_ai_fit(0, 4) == 1 and near(e.ais[1].len, 4), e.ais[1].len)
  ok('resize: same length - nothing to do', P.pat_ai_fit(0, 4) == 0)
  ok('resize: another pattern start - nothing touched', P.pat_ai_fit(8, 20) == 0 and near(e.ais[1].len, 4))
end
-- 3. повторы (алиасы)
do
  local _, e, regs = build()
  P.pat_ai_wrap({ regs[1] })
  local n = P.pat_ai_link(regs, regs[1])
  ok('alias: the repeat gets a linked AI', n == 1 and #e.ais == 2, n)
  ok('alias: at the start of the repeat, its length', e.ais[2] and near(e.ais[2].pos, 16) and near(e.ais[2].len, 8))
  ok('alias: the same pool (an edit in one changes both)', e.ais[2] and e.ais[2].pool == e.ais[1].pool)
  ok('alias: B1 (another name) gets nothing', P.ai_at(e, 8) == nil)
  ok('alias again: no second AI on the repeat', P.pat_ai_link(regs, regs[1]) == 0 and #e.ais == 2)
end
-- сдвиг AI при вставке / удалении времени делает edit.time_insert / time_delete (jf_tracker_edit.lua) — здесь не проверяется

local u = {}
for k, c in pairs(unknown) do u[#u + 1] = k .. ' x' .. c end
table.sort(u)
if #u > 0 then print('not imitated (returned nil): ' .. table.concat(u, ', ')) end
print(('%d checks, %d failed'):format(checks, fails))
os.exit(fails == 0 and 0 or 1)
