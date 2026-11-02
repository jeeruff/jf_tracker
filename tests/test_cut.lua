-- tests/test_cut.lua — ^^^ (cut): CC120 у конца ноты помечает её cut, OFF (release) — нет
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
_G.reaper = setmetatable({}, { __index = function() return function() return 0 end end })
local M = dofile(DIR .. '/jf_tracker_model.lua')
local fails, n = 0, 0
local function ok(c, msg) n = n + 1; if not c then fails = fails + 1; print('FAIL ' .. msg) end end
local function ev(off, ...) local m = string.char(...); return string.pack('<i4Bs4', off, 0, m) end
-- нота 60 на канале 0: 0..480, на 480 — CC120; нота 62: 0..960 без CC120; нота 64 на канале 1, CC120 на канале 0 в её конце
local buf = ev(0, 0x90, 60, 100) .. ev(0, 0x90, 62, 100) .. ev(0, 0x91, 64, 100)
  .. ev(480, 0x80, 60, 0) .. ev(0, 0xB0, 120, 0) .. ev(0, 0x81, 64, 0) .. ev(480, 0x80, 62, 0)
local by = {}
for _, nt in ipairs(M.parse_midi(buf)) do by[nt.pitch] = nt end
ok(by[60] and by[60].cut == true, 'note ending on CC120 of its channel is cut')
ok(by[62] and not by[62].cut, 'note without CC120 is a plain OFF (release)')
ok(by[64] and not by[64].cut, 'CC120 of another channel does not cut')
print(('test_cut: %d/%d ok'):format(n - fails, n))
os.exit(fails == 0 and 0 or 1)
