-- test_slicer_zoom.lua — зум и прокрутка волны вкладки item: lua tests/test_slicer_zoom.lua
package.path = './?.lua;' .. package.path
_G.reaper = {}; _G.gfx = { mouse_x = 0 }
local S = dofile('jf_tracker_slicer.lua')
local n, bad = 0, 0
local function near(name, got, want) n = n + 1; if math.abs((got or 1e9) - want) > 1e-6 then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end end
S.wave = { x = 100, w = 400, len = 4 }
near('full: x -> t', S.x_to_t(300), 2)
S.zoom(0.5, 2)                                  -- вдвое ближе у 2 с
near('zoom keeps the point', S.va, 1); near('zoom span', S.vb - S.va, 2)
S.wave.va, S.wave.vb = S.va, S.vb
near('zoomed: x -> t', S.x_to_t(300), 2)
near('zoomed: left edge', S.x_to_t(100), 1)
S.scroll(0.5)
near('scroll half a window', S.va, 2); near('scroll keeps span', S.vb - S.va, 2)
S.wave.va, S.wave.vb = S.va, S.vb
S.scroll(5)
near('scroll clamps at the end', S.vb, 4)
S.wave.va, S.wave.vb = S.va, S.vb
S.zoom(10, 3)
near('zoom out to full resets', S.va, 0); n = n + 1; if S.vb ~= nil then bad = bad + 1; print('FAIL full view vb nil') end
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
