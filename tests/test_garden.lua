-- test_garden.lua — вкладка Garden без REAPER: lua tests/test_garden.lua
package.path = './?.lua;' .. package.path
gfx = { mouse_x = 0, mouse_y = 0 }
local GD = dofile('jf_tracker_garden.lua')
local n, bad = 0, 0
local function eq(name, got, want)
  n = n + 1
  if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end
local calls = {}
local function last() return calls[#calls] or '' end
GD.init({}, {
  garden_loop = function(ri, ci, k) calls[#calls + 1] = ('loop:%d:%d:%s'):format(ri, ci, tostring(k)) end,
  garden_fit = function(ri, ci) calls[#calls + 1] = ('fit:%d:%d'):format(ri, ci) end,
  garden_mute = function(ri, ci) calls[#calls + 1] = ('mute:%d:%d'):format(ri, ci) end,
  region_space = function(rg) calls[#calls + 1] = 'queue:' .. tostring(rg and rg.name) end,
  garden_cmd = function(a) calls[#calls + 1] = 'cmd:' .. a end,
  garden_field = function() return nil end,
  mods = function() return {} end,
})
local snap = { cols = {
  { name = 'drums', lanes = { { items = { { r0 = 0, item = 'k1', loop_rows = 4 }, { r0 = 70, item = 'k2' } } } } },
  { name = 'bass', lanes = { { items = { { r0 = 64, item = 'b1', muted = true } } } } },
  { name = 'pad', lanes = { { items = {} } } },
} }
local seq = { { name = 'A', r0 = 0, r1 = 64 }, { name = 'B', r0 = 64, r1 = 128 } }
local g = GD.cells(snap, seq, { [3] = true })
eq('A drums loop 4', g[1][1].per, 4)
eq('A drums item', g[1][1].item, 'k1')
eq('B drums has (no loop)', g[2][1].has and g[2][1].per == nil, true)
eq('B bass muted', g[2][2].muted, true)
eq('A bass empty', g[1][2].has, false)
eq('pad orca target', g[1][3].orca, true)

GD.cur = { ri = 1, ci = 1 }
GD.key(('1'):byte(), snap, seq); GD.key(('6'):byte(), snap, seq); GD.key(13, snap, seq)
eq('16 Enter -> loop 16', last(), 'loop:1:1:16')
GD.key(13, snap, seq); eq('Enter without digits -> queue', last(), 'queue:A')
GD.key(('j'):byte(), snap, seq); eq('j moves', GD.cur.ri, 2)
GD.key(('>'):byte(), snap, seq); eq('> loop to region end', last(), 'loop:2:1:nil')
GD.key(('<'):byte(), snap, seq); eq('< region to item end', last(), 'fit:2:1')
GD.key(('m'):byte(), snap, seq); eq('m mute', last(), 'mute:2:1')
GD.cur = { ri = 1, ci = 1 }
GD.key(('+'):byte(), snap, seq); eq('+ next period after 4', last(), 'loop:1:1:6')
GD.key(('-'):byte(), snap, seq); eq('- previous period before 4', last(), 'loop:1:1:3')
GD.key(('O'):byte(), snap, seq); eq('O toggles orca', last(), 'cmd:toggle')
GD.key(('o'):byte(), snap, seq); eq('o -> orca page', GD.page, 'orca')
GD.key(27, snap, seq); eq('Esc on orca page without field -> grid', GD.page, 'grid')
eq('unknown key not eaten', GD.key(('q'):byte(), snap, seq), false)
print(('%d checks, %d failed'):format(n, bad))
