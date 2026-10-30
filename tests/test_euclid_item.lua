-- tests/test_euclid_item.lua — :eu (30 окт): Евклид геометрией айтема — k нот из n строк, ротация, источник зациклен,
-- айтем протянут до конца паттерна
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local fails, n = 0, 0
local function ok(c, msg) n = n + 1; if not c then fails = fails + 1; print('FAIL ' .. msg) end end

local IT
reaper = setmetatable({
  CreateNewMIDIItemInProj = function(tr, t0, t1) IT = { pos = t0, len = t1 - t0, notes = {}, v = {}, take = { name = '' } }; return IT end,
  GetActiveTake = function(it) return it.take end,
  MIDI_GetPPQPosFromProjTime = function(_, t) return t * 960 end,
  MIDI_InsertNote = function(_, _, _, a, b, ch, pi, ve) IT.notes[#IT.notes + 1] = { a = a, b = b, pi = pi, ve = ve } end,
  SetMediaItemInfo_Value = function(it, k, v) it.v[k] = v end,
  GetSetMediaItemTakeInfo_String = function(tk, k, v) tk.name = v; return true, v end,
  TimeMap2_QNToTime = function(_, q) return q end,
  TimeMap2_timeToQN = function(_, t) return t end,
}, { __index = function() return function() return 0 end end })
local E = dofile(DIR .. '/jf_tracker_edit.lua')
E.run = function(_, fn) fn() end
-- row_time внутри модуля: строка = 1/lpb четверти (время = QN в стабе)
local function steps()
  local t = {}
  for _, x in ipairs(IT.notes) do t[#t + 1] = math.floor(x.a / 960 * 4 + 0.5) end
  return table.concat(t, ' ')
end

E.euclid_loop('tr', nil, 4, 0, 8, 3, 0, 60, 100, 32)
ok(#IT.notes == 3, 'three hits in eight: ' .. #IT.notes)
ok(steps() == '0 3 6', 'tresillo 0 3 6: ' .. steps())
ok(IT.v.B_LOOPSRC == 1, 'source looped')
ok(math.abs((IT.v.D_LENGTH or 0) - 8) < 1e-6, 'item to the pattern end (32 rows = 8 QN): ' .. tostring(IT.v.D_LENGTH))
ok(IT.take.name == 'e3/8', 'take named e3/8')
E.euclid_loop('tr', nil, 4, 0, 8, 3, 1, 60, 100, 32)
ok(#IT.notes == 3 and steps() ~= '0 3 6', 'rotation moves the hits: ' .. steps())
E.euclid_loop('tr', nil, 4, 0, 5, 5, 0, 62, 90, nil)
ok(#IT.notes == 5 and IT.notes[1].pi == 62 and IT.notes[1].ve == 90, 'k = n - every row, pitch and velocity kept')

print(('test_euclid_item: %d/%d ok'):format(n - fails, n))
os.exit(fails == 0 and 0 or 1)
