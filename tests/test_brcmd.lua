-- tests/test_brcmd.lua — BRxx (beat repeat): разбор и длина среза LiveBeatRepeater по делениям такта
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
reaper = reaper or {}
local C = dofile(DIR .. '/jf_tracker_cmds.lua')
local SM = dofile(DIR .. '/jf_tracker_smart.lua')
local fails, n = 0, 0
local function ok(c, msg) n = n + 1; if not c then fails = fails + 1; print('FAIL ' .. msg) end end
local want = { [1] = 1, [2] = 3, [3] = 4, [4] = 5, [6] = 6, [8] = 7, [12] = 8, [16] = 9, [24] = 10, [32] = 11, [64] = 12, [128] = 13, [5] = 6 }   -- 1/5 ближе к 1/6 (1/4T)
for xx, idx in pairs(want) do ok(C.br_len(xx) == idx, ('BR%02X -> length %d, got %d'):format(xx, idx, C.br_len(xx))) end
local l = C.parse('BR08,BR00@1')
ok(#l == 2 and l[1].cmd == 'BR' and l[1].xx == 8 and l[2].xx == 0, 'BR parses, BR00 kept as the stop')
ok(SM.FX_MEAN.BR(8) == 'repeat 1/8 bar slice' and SM.FX_MEAN.BR(6) == 'repeat 1/4T bar slice' and SM.FX_MEAN.BR(0) == 'repeat off', 'BR meaning text')
ok(SM.FX_DESC.BR ~= nil, 'BR is in the command list')
print(('test_brcmd: %d/%d ok'):format(n - fails, n))
os.exit(fails == 0 and 0 or 1)
