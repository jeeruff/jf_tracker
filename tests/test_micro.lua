-- test_micro.lua — микротоны 72-EDO (16 окт): MTS sysex туда-обратно, метки ^ v, ноты потока с подстройкой
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
_G.reaper = setmetatable({}, { __index = function() return function() return 0 end end })
local M = dofile(DIR .. '/jf_tracker_model.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
local function near(name, got, want) n = n + 1; if math.abs((got or 1e9) - want) > 0.05 then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end

-- метки
eq('tag +1', M.micro_tag(1), '^'); eq('tag +2', M.micro_tag(2), '^^'); eq('tag +3', M.micro_tag(3), '^3')
eq('tag -1', M.micro_tag(-1), 'v'); eq('tag -2', M.micro_tag(-2), 'vv'); eq('tag 0', M.micro_tag(0), '')
eq('cents 16.7 = +1', M.micro_of_cents(16.67), 1); eq('cents -33 = -2', M.micro_of_cents(-33.3), -2)
eq('cents 2 = none', M.micro_of_cents(2), nil); eq('cents 80 clamps 3', M.micro_of_cents(80), 3)

-- sysex туда-обратно
local sx = M.mts_bytes(60, 6000 + 100 / 6)
eq('sysex length', #sx, 12); eq('sysex F0', sx:byte(1), 0xF0); eq('sysex F7', sx:byte(12), 0xF7)
local t = M.mts_parse(sx)
near('parse back +16.7 c', t and t[60], 100 / 6)
t = M.mts_parse(M.mts_bytes(64, 6400 - 200 / 6))
near('parse back -33.3 c', t and t[64], -200 / 6)
eq('not MTS', M.mts_parse(string.char(0xF0, 0x43, 0x10, 0xF7)), nil)

-- поток: sysex перед note-on даёт cents ноте той же клавиши
local function ev(off, msg) return string.pack('<i4Bs4', off, 0, msg) end
local buf = ev(0, M.mts_bytes(60, 6000 + 100 / 6)) .. ev(0, string.char(0x90, 60, 100)) .. ev(0, string.char(0x90, 64, 100))
  .. ev(480, string.char(0x80, 60, 0)) .. ev(0, string.char(0x80, 64, 0))
local notes = M.parse_midi(buf)
eq('two notes', #notes, 2)
near('C gets +16.7', notes[1] and notes[1].cents, 100 / 6)
eq('E plain', notes[2] and notes[2].cents, nil)

print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
