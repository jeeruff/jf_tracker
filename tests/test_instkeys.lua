-- test_instkeys.lua — грамматика модуля инструментов без REAPER: lua tests/test_instkeys.lua
package.path = './?.lua;' .. package.path
local IK = dofile('jf_tracker_instkeys.lua')
local n, bad = 0, 0
local function eq(name, got, want)
  n = n + 1
  if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end
local log = {}
local function last() return log[#log] or '' end
local cur = 2
IK.init({
  msg = function() end,
  inst_cut = function(a, b) log[#log + 1] = ('cut:%d-%d'):format(a, b) end,
  inst_yank = function(a, b, q) log[#log + 1] = ('yank:%d-%d%s'):format(a, b, q and ':q' or '') end,
  inst_put = function(before) log[#log + 1] = 'put:' .. (before and 'P' or 'p') end,
  inst_select = function(i) cur = i; log[#log + 1] = 'sel:' .. i end,
  open_slicer = function() log[#log + 1] = 'slicer' end,
  inst_listen = function() log[#log + 1] = 'listen' end,
  inst_listen_toggle = function() log[#log + 1] = 'listen_toggle' end,
  inst_find = function() log[#log + 1] = 'find' end,
  inst_track = function(d) log[#log + 1] = 'track:' .. d end,
})
local function k(s) local r; for ch in s:gmatch('.') do r = IK.key(ch:byte(), cur, 3, 8) end; return r end

k('dd'); eq('dd cuts current', last(), 'cut:2-2')
k('yy'); eq('yy yanks', last(), 'yank:2-2')
k('p'); eq('p puts after', last(), 'put:p')
k('P'); eq('P puts before', last(), 'put:P')
k('yp'); eq('yp duplicates: put', last(), 'put:p'); eq('yp duplicates: quiet yank first', log[#log - 1], 'yank:2-2:q')
local nx = #log; k('x'); eq('x is not a lib key any more (dd cuts)', #log, nx)
k('d'); eq('pending hint after d', IK.pending_hint() ~= nil, true)
IK.key(27, cur, 3, 8); eq('Esc cancels pending', IK.pending, nil)
local nq = #log; k('dq'); eq('unknown op does nothing', #log, nq)
-- диапазон
cur = 1
k('v'); k('j'); k('j'); eq('j extends in range', cur, 3)
k('d'); eq('v + d cuts range', last(), 'cut:1-3'); eq('range cleared', IK.anchor, nil)
cur = 3; k('v'); k('k'); k('y'); eq('v + y yanks range', last(), 'yank:2-3')
-- диапазон не заходит в пустые слоты
cur = 2; k('v'); cur = 6; k('d'); eq('range clipped to instruments', last(), 'cut:2-3')
-- пустой слот: x не режет
cur = 5; local before = #log; k('x'); eq('x on empty slot does nothing', #log, before)
-- навигация и прочее
cur = 8; k('j'); eq('j stops at last slot', cur, 8)
k('g'); eq('g first', cur, 1)
k('G'); eq('G last instrument', cur, 3)
IK.key(13, cur, 3, 8); eq('Enter slicer', last(), 'slicer')
k(' '); eq('Space listens', last(), 'listen')
k('a'); eq('a toggles listen on select', last(), 'listen_toggle')
k('/'); eq('/ finds', last(), 'find')
k('h'); eq('h track left', last(), 'track:-1')
eq('Esc leaves', IK.key(27, cur, 3, 8), 'leave')
eq('u is not ours (vim undo)', IK.key(('u'):byte(), cur, 3, 8), false)

print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
