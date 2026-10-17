-- tests/test_rowshift.lua — Backspace / Insert строк со свингом (17 окт): нота едет на строки сетки со свингом,
-- её задержка внутри строки сохраняется; раньше сдвиг на время строки давал «свинговые» задержки (14, 5A …)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
reaper = setmetatable({
  TimeMap2_timeToQN = function(_, t) return t * 2 end,      -- 120 BPM
  TimeMap2_QNToTime = function(_, q) return q / 2 end,
  ValidatePtr = function() return false end,
}, { __index = function() return function() end end })
local E = dofile(DIR .. '/jf_tracker_edit.lua')
local n, bad = 0, 0
local function near(name, got, want) n = n + 1; if math.abs(got - want) > 1e-6 then bad = bad + 1; print(('FAIL %s: got %.6f want %.6f'):format(name, got, want)) end end
E.sw = { on = true, div = 0.25, amt = 0.33 }               -- свинг 16-х, LPB 4
local lpb = 4
local st = function(r) return E.swing_time(r, lpb) end
near('odd row up 1 -> even row, no delay', E.row_shift(nil, st(5), lpb, -1), st(4))
near('even row up 1 -> odd row, swung', E.row_shift(nil, st(4), lpb, -1), st(3))
near('delay kept', E.row_shift(nil, st(5) + 0.01, lpb, -1), st(4) + 0.01)
near('insert: down 1', E.row_shift(nil, st(6), lpb, 1), st(7))
near('down 3', E.row_shift(nil, st(2), lpb, 3), st(5))
E.sw = { on = false, div = 0.25, amt = 0 }
near('no swing = row time', E.row_shift(nil, 1.0, lpb, -1), 1.0 - 0.125)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
