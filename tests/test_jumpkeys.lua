-- tests/test_jumpkeys.lua — буква-прыжок в списках свойств (17 окт): первая буква, кроме h j k l g f; по кругу
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
reaper = setmetatable({}, { __index = function() return function() end end })
local SP = dofile(DIR .. '/jf_tracker_sampleprops.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
eq('volume -> v', SP.jump_char('volume'), 'v')
eq('loop -> o (l is a value key)', SP.jump_char('loop'), 'o')
eq('length -> e', SP.jump_char('length'), 'e')
eq('fade in -> a (f is the jump label)', SP.jump_char('fade in'), 'a')
local rows = { { label = 'volume' }, { label = 'fade in' }, { label = 'pan' }, { label = 'fade out' }, { label = 'take volume' } }
eq('a from 1 -> fade in', SP.jump(rows, 1, 'a'), 2)
eq('a again -> fade out', SP.jump(rows, 2, 'a'), 4)
eq('a cycles back', SP.jump(rows, 4, 'a'), 2)
eq('p -> pan', SP.jump(rows, 1, 'p'), 3)
eq('no row on q', SP.jump(rows, 1, 'q'), nil)
-- у всех строк свойств есть буква
local miss = 0
for _, r in ipairs(SP.ROWS) do if not SP.jump_char(r.label) then miss = miss + 1 end end
eq('every property row has a jump letter', miss, 0)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
