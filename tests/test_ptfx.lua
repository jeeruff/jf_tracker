-- tests/test_ptfx.lua — раскладка команд ProTracker (PT-mode): набор → наши коды, показ обратно
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local PT = dofile(DIR .. '/jf_tracker_ptfx.lua')
local fails, n = 0, 0
local function ok(c, msg) n = n + 1; if not c then fails = fails + 1; print('FAIL ' .. msg) end end
local function to(c, xx) local a, b = PT.to_ours(c, xx); return a and (a .. ('%02X'):format(b)) or nil end

ok(to('9', 0x40) == '0940', '940 -> 0940')
ok(to('C', 0x40) == '0M80', 'C40 (full) -> 0M80')
ok(to('C', 0x7F) == '0M80', 'C over 40 is clamped to 40')
ok(to('D', 0x10) == 'ZB0A', 'D10 -> break to row 10')
ok(to('D', 0x1A) == nil, 'D1A is not decimal')
ok(to('A', 0x40) == '0I40' and to('A', 0x04) == '0O40', 'A40 up, A04 down')
ok(to('A', 0x44) == nil, 'A44 both ways - refused')
ok(to('F', 0x7D) == 'ZT7D' and to('F', 0x06) == nil, 'F7D tempo, F06 speed refused')
ok(to('E', 0x93) == '0R08', 'E93 retrig 3 ticks -> 8/16 row')
ok(to('E', 0xC3) == nil and to('7', 0x44) == nil, 'EC3 and 7xx not in jf_tracker')
ok(to('0', 0x37) == '0A37' and to('1', 0x05) == '0U05' and to('2', 0x05) == '0D05' and to('B', 0x03) == 'ZJ03', '0 1 2 B')

ok(PT.show('0M80') == 'C40 ', 'show 0M80 as C40')
ok(PT.show('ZB0A') == 'D10 ', 'show ZB0A as D10')
ok(PT.show('0S40') == '940 ' and PT.show('0940') == '940 ', 'offset shows as 9xx')
ok(PT.show('SI10') == 'SI10', 'no PT equivalent - shown as is')
-- туда и обратно
for _, s in ipairs({ '940', 'C20', 'D32', 'A40', 'A07', 'F7D', 'B05', '037', '4A3', 'E93' }) do
  local a, b = PT.to_ours(s:sub(1, 1), tonumber(s:sub(2), 16))
  ok(a and PT.show(a .. ('%02X'):format(b)) == s .. ' ', 'round trip ' .. s .. ' -> ' .. tostring(a and PT.show(a .. ('%02X'):format(b))))
end

print(('test_ptfx: %d/%d ok'):format(n - fails, n))
os.exit(fails == 0 and 0 or 1)
