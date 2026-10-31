-- test_phrasepane.lua — панель phrases (31 окт): клавиши → действия, x x — удаление с подтверждением
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
gfx = setmetatable({ mouse_x = -1, mouse_y = -1, a = 1 }, { __index = function() return function() end end })
local PHP = dofile(DIR .. '/jf_tracker_phrasepane.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
local list = { { name = 'drums', lenq = 4, n = 2 }, { name = 'fill', lenq = 2, n = 0 } }
local b = function(s) return s:byte() end
PHP.sel = 1
eq('j', PHP.key(list, b'j') and PHP.sel, 2)
eq('j at the end stays', PHP.key(list, b'j') and PHP.sel, 2)
eq('k', PHP.key(list, b'k') and PHP.sel, 1)
eq('Enter inserts', PHP.key(list, 13).op, 'insert')
eq('e edits it in the tracker', PHP.key(list, b'e').op, 'edit')
eq('r renames', PHP.key(list, b'r').name, 'drums')
eq('n new', PHP.key(list, b'n').op, 'new')
eq('first x asks', PHP.key(list, b'x').op, 'confirm')
eq('second x deletes', PHP.key(list, b'x').op, 'delete')
PHP.key(list, b'x'); PHP.key(list, b'j')
eq('another key cancels the x', PHP.key(list, b'x').op, 'confirm')
eq('Esc leaves', PHP.key(list, 27), 'leave')
eq('empty list: Enter is not ours', PHP.key({}, 13), false)
local U = { AMBER = {}, LINE = {}, GREY = {}, DIM = {}, TEXT = {}, CYAN = {}, RED = {}, set = function() end, text = function() end, measure = function(s) return #s * 7 end, tint = function(c) return c end }
gfx.mouse_x, gfx.mouse_y = 10, 14 + 2 + 3
local hv = PHP.draw(U, { pad = 4, rh = 14 }, list, 0, 0, 300, 100, true, gfx.mouse_x, gfx.mouse_y, function(s) return s end)
eq('hover the first row', hv and hv.row, 1)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
