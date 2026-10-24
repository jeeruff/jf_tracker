-- test_offrel.lua — явный OFF трекера: note-off со скоростью отпускания 1 (24 окт)
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
_G.reaper = setmetatable({}, { __index = function() return function() return false end end })
local M = dofile(DIR .. '/jf_tracker_model.lua')
local n, bad = 0, 0
local function ok(c, what) n = n + 1; if not c then bad = bad + 1; print('FAIL ' .. what) end end
local function ev(off, msg) return string.pack('<i4Bs4', off, 0, msg) end
local buf = ev(0, string.char(0x90, 36, 100)) .. ev(240, string.char(0x80, 36, 0))       -- обычный конец
         .. ev(240, string.char(0x90, 38, 100)) .. ev(240, string.char(0x80, 38, M.OFF_REL))  -- явный OFF
         .. ev(240, string.char(0x90, 40, 100)) .. ev(240, string.char(0x90, 40, 0))     -- note-on 0 — обычный
local notes = M.parse_midi(buf)
ok(#notes == 3, 'three notes')
ok(notes[1].rel == 0, 'a plain note end is not an explicit OFF')
ok(notes[2].rel == M.OFF_REL, 'release velocity 1 - the explicit OFF')
ok(notes[3].rel == 0, 'note-on velocity 0 is a plain end')
ok(M.CHOKE_SELF == 17, 'choke 17 - the self mode of jf_tracker_choke')
print(('test_offrel: %d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
