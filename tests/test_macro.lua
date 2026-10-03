-- test_macro.lua — макро-вид на стабах: lua tests/test_macro.lua
package.path = './?.lua;' .. package.path
_G.gfx = { rect = function() end }
local drawn = {}
local U = { set = function() end, measure = function(s) return #s * 8 end, mix = function(a) return a end,
  text = function(x, y, s) drawn[#drawn + 1] = s end, BG = {}, TEXT = {}, AMBER = {}, GREY = {}, CYAN = {}, DIM = {}, GREEN = {} }
local MC = dofile('jf_tracker_macro.lua')
MC.init(U)
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end end
local function head(row, note) return { kind = 'audio', row0 = row, note = note } end
local sub = { [0] = head(0, 'C-4'), [4] = head(4, 'D-4'), [16] = head(16, 'E-4'), [40] = head(40, 'F-4') }
local snap = { cols = { { lanes = { { subs = { sub } } } } } }
local L = { rh = 16, cw = 8, pad = 4, cols = { { ci = 1, x = 100, w = 120, col = { rgb = nil } } } }
MC.draw(L, snap, 0, 0, 400, 160, 60, 0, 16, { { r0 = 16, name = 'verse', idx = 2 } }, function(s) return s end)
local all = table.concat(drawn, '|')
eq('bar 1 first note', all:find('C-4', 1, true) ~= nil, true)
eq('bar 2 first note', all:find('E-4', 1, true) ~= nil, true)
eq('bar 3 first note', all:find('F-4', 1, true) ~= nil, true)
eq('region name on its bar', all:find('verse', 1, true) ~= nil, true)
eq('second note of bar 1 not shown', all:find('D-4', 1, true), nil)
eq('j: next bar', MC.key(('j'):byte(), 5, 16), 16)
eq('k: bar start above', MC.key(('k'):byte(), 20, 16), 0)
eq('J: 4 bars', MC.key(('J'):byte(), 0, 16), 64)
eq('G: last bar', MC.key(('G'):byte(), 0, 16, 45), 32)
eq('Enter leaves', MC.key(13, 0, 16), 'leave')
eq('other keys pass', MC.key(('h'):byte(), 0, 16), nil)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
