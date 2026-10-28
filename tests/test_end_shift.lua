-- tests/test_end_shift.lua — =END вправо: всё, что за ним (библиотека паттернов, =SESSION, items, огибающие),
-- едет вместе с ним (A.shift_lib); песня и трек LIB — на месте; маркер =END в старой точке не едет
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local fails, n = 0, 0
local function ok(c, msg) n = n + 1; if not c then fails = fails + 1; print('FAIL ' .. msg) end end
local function near(a, b) return math.abs(a - b) < 1e-6 end

-- стаб проекта: треки с items { pos, len } и огибающими { points = { t } }, маркеры / регионы
local P
local function build()
  P = {
    tracks = {
      { name = 'Track 1', items = { { pos = 0, len = 2 }, { pos = 6, len = 1 }, { pos = 14, len = 2 }, { pos = 18, len = 1 } },
        envs = { { pts = { 1, 7, 14, 15 }, ai = { 3, 16 } } } },
      { name = 'Track 2', items = { { pos = 7, len = 6 } }, envs = {} },   -- нота песни через =END (7..13)
      { name = 'LIB', items = { { pos = 0, len = 20 } }, envs = {} },      -- сэмпл библиотеки длиннее песни
    },
    marks = {
      { isrgn = false, pos = 0, name = '=START' },
      { isrgn = true, pos = 0, rgnend = 4, name = 'A1' },
      { isrgn = true, pos = 4, rgnend = 8, name = 'B1' },
      { isrgn = false, pos = 8, name = '=END' },
      { isrgn = true, pos = 14, rgnend = 16, name = 'L1' },        -- библиотечный паттерн за =END
      { isrgn = true, pos = 18, rgnend = 22, name = '=SESSION' },
    },
  }
  for k, m in ipairs(P.marks) do m.idx = k; m.color = 0 end
end
local function sorted_marks()
  local t = {}
  for _, m in ipairs(P.marks) do t[#t + 1] = m end
  table.sort(t, function(a, b) return a.pos < b.pos end)
  return t
end
reaper = setmetatable({
  CountTracks = function() return #P.tracks end,
  GetTrack = function(_, i) return P.tracks[i + 1] end,
  GetTrackName = function(tr) return true, tr.name end,
  CountTrackMediaItems = function(tr) return #tr.items end,
  GetTrackMediaItem = function(tr, i) return tr.items[i + 1] end,
  GetMediaItemInfo_Value = function(it, k) return k == 'D_POSITION' and it.pos or it.len end,
  SetMediaItemInfo_Value = function(it, k, v) if k == 'D_POSITION' then it.pos = v else it.len = v end end,
  CountTrackEnvelopes = function(tr) return #tr.envs end,
  GetTrackEnvelope = function(tr, i) return tr.envs[i + 1] end,
  CountEnvelopePoints = function(e) return #e.pts end,
  GetEnvelopePoint = function(e, i) return true, e.pts[i + 1], 0, 0, 0, false end,
  SetEnvelopePoint = function(e, i, t) e.pts[i + 1] = t end,
  CountAutomationItems = function(e) return #e.ai end,
  GetSetAutomationItemInfo = function(e, i, _, v, set) if set then e.ai[i + 1] = v end; return e.ai[i + 1] end,
  EnumProjectMarkers3 = function(_, i)
    local m = sorted_marks()[i + 1]
    if not m then return 0 end
    return 1, m.isrgn, m.pos, m.rgnend or 0, m.name, m.idx, m.color
  end,
  SetProjectMarkerByIndex = function(_, i, isrgn, pos, rgnend, idx, name)
    local m = sorted_marks()[i + 1]
    m.pos, m.rgnend = pos, isrgn and rgnend or nil
  end,
}, { __index = function() return function() end end })

local A = dofile(DIR .. '/jf_tracker_alias.lua')
A.init({ is_lib_name = function(nm) return nm == 'LIB' end, DEPOT = 'LIB' }, {})
local function mark(name) for _, m in ipairs(P.marks) do if m.name == name then return m end end end

-- =END 8 -> 11 (на 3 вправо)
build()
local moved = A.shift_lib(8, 3, { ['=END'] = true })
local t1, t2, lib = P.tracks[1], P.tracks[2], P.tracks[3]
ok(near(t1.items[1].pos, 0) and near(t1.items[2].pos, 6), 'song items stay')
ok(near(t1.items[3].pos, 17) and near(t1.items[4].pos, 21), 'library and session items move by 3')
ok(near(t2.items[1].pos, 7) and near(t2.items[1].len, 6), 'a song note across =END is not cut or moved')
ok(#t2.items == 1, 'no split')
ok(near(lib.items[1].pos, 0) and near(lib.items[1].len, 20), 'LIB track untouched')
local e = t1.envs[1]
ok(near(e.pts[1], 1) and near(e.pts[2], 7) and near(e.pts[3], 17) and near(e.pts[4], 18), 'envelope points after =END move, before stay')
ok(near(e.ai[1], 3) and near(e.ai[2], 19), 'automation items after =END move')
ok(near(mark('=START').pos, 0) and near(mark('A1').pos, 0) and near(mark('B1').rgnend, 8), 'song markers / regions stay')
ok(near(mark('=END').pos, 8), '=END itself is left for the caller')
ok(near(mark('L1').pos, 17) and near(mark('L1').rgnend, 19), 'library region moves with its length')
ok(near(mark('=SESSION').pos, 21) and near(mark('=SESSION').rgnend, 25), 'session zone moves')
ok(moved == 2 + 2, 'count: 2 items + 2 regions')

-- library still after =END: nothing after the new =END is before it
local lib_start = math.huge
for _, m in ipairs(P.marks) do if m.isrgn and m.pos >= 8 then lib_start = math.min(lib_start, m.pos) end end
ok(lib_start >= 11, 'the library never starts left of the new =END')

-- 0 delta - nothing
build()
ok(A.shift_lib(8, 0) == 0 and near(P.tracks[1].items[3].pos, 14), 'zero delta - nothing moves')

-- a big move (8 -> 30): the order of regions is kept (no region jumps over another)
build()
A.shift_lib(8, 22, { ['=END'] = true })
ok(near(mark('L1').pos, 36) and near(mark('=SESSION').pos, 40), 'big move keeps the order')

-- moving left (shrink, -2 from 14): items at / after 14 move back, those before stay
build()
A.shift_lib(14, -2)
ok(near(P.tracks[1].items[3].pos, 12) and near(P.tracks[1].items[2].pos, 6), 'negative delta moves only what is after t')

print(('test_end_shift: %d/%d ok'):format(n - fails, n))
os.exit(fails == 0 and 0 or 1)
