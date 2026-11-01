-- test_tour.lua — тур tutorial на стабах: шаги засчитываются действием
package.path = './?.lua;' .. package.path
_G.gfx = { mouse_x = 0, mouse_y = 0, rect = function() end }
local T = dofile('jf_tracker_tour.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end end
local env = { fi = 1, row = 0, mode = 'normal', inst = 1, change = 0, hj = 0 }
local function e(t) local x = {}; for k, v in pairs(env) do x[k] = v end; for k, v in pairs(t or {}) do x[k] = v end; return x end
T.start(); eq('start asks for the tracker focus', T.want_focus, 'tracker'); T.tick(e(), 0)
eq('step 1 (why jf) waits', T.ok, false)
T.tick(e({ row = 1 }), 1); eq('j -> ok', T.ok, true)
T.tick(e({ row = 1 }), 2); eq('advances to step 2 (move)', T.step, 2)
T.tick(e({ row = 1 }), 2.1)
T.tick(e({ row = 2 }), 2.2); eq('move: j alone not enough, h/l needed', T.ok, false)
T.tick(e({ row = 2, fi = 2 }), 3); eq('l -> ok', T.ok, true)
T.tick(e({ row = 2, fi = 2 }), 4); eq('step 3 (f)', T.step, 3)
T.tick(e({ row = 2, fi = 2 }), 4.1)
T.tick(e({ row = 2, fi = 2, hj = 1 }), 5); eq('label jump -> ok', T.ok, true)
T.tick(e({ row = 2, fi = 2, hj = 1 }), 6); eq('step 4 (modes)', T.step, 4)
T.tick(e({ row = 2, fi = 2, hj = 1 }), 6.1)
T.tick(e({ mode = 'insert', hj = 1 }), 7); eq('insert alone not yet', T.ok, false)
T.tick(e({ mode = 'normal', hj = 1 }), 8); eq('insert then Esc -> ok', T.ok, true)
T.go(1); eq('step 5 (write notes) stays in the tracker', T.want_focus, 'tracker')
T.go(1); eq('step 6 asks for the lib focus', T.want_focus, 'inst')
T.go(-5); eq('back to step 1', T.step, 1); eq('step reset', T.ok, false)
T.go(5); eq('forward clamps', T.step, 6)
T.stop(); eq('stopped', T.active, false)
eq('14 steps (1 ноя: + modes)', #T.STEPS, 14)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
