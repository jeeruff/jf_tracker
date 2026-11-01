-- tests/test_fipm.lua — полосы free item positioning для наложенных нот (E.fipm_slots)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
reaper = reaper or {}
local ok_e, E = pcall(dofile, DIR .. '/jf_tracker_edit.lua')
local fails, n = 0, 0
local function ok(c, msg) n = n + 1; if not c then fails = fails + 1; print('FAIL ' .. msg) end end
ok(ok_e and E and E.fipm_slots, 'edit module loads without REAPER')
if ok_e then
  local s, k = E.fipm_slots({ { 0, 1 }, { 1, 2 }, { 2, 3 } }, 0.03)
  ok(k == 1 and s[1] == 1 and s[3] == 1, 'notes one after another - one strip')
  s, k = E.fipm_slots({ { 0, 2 }, { 0, 2 }, { 0, 2 }, { 0, 2 } }, 0.03)
  ok(k == 4 and s[1] == 1 and s[4] == 4, 'a chord of four - four strips')
  s, k = E.fipm_slots({ { 0, 1.01 }, { 1, 2 } }, 0.03)
  ok(k == 1, 'a 10 ms crossfade is not an overlap')
  s, k = E.fipm_slots({ { 0, 3 }, { 1, 2 }, { 2.5, 4 } }, 0.03)
  ok(k == 2 and s[2] == 2 and s[3] == 2, 'the long note keeps strip 1, the others take the free strip 2')
end
print(('test_fipm: %d/%d ok'):format(n - fails, n))
os.exit(fails == 0 and 0 or 1)
