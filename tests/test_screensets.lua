-- test_screensets.lua — формат скринсетов: lua tests/test_screensets.lua
package.path = './?.lua;' .. package.path
local SS = dofile('jf_tracker_screensets.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end end
local sets = { work = { o_theme = 'mono', top = true, dsp = false, top_px = 240, o_note = 'a;b' }, pt = { fontscale = 4 } }
local text = SS.encode(sets, { 'work', 'pt' })
local back, order = SS.decode(text)
eq('order kept', table.concat(order, ','), 'work,pt')
eq('string', back.work.o_theme, 'mono'); eq('true', back.work.top, true); eq('false survives', back.work.dsp, false)
eq('number', back.work.top_px, 240); eq('semicolon escaped', back.work.o_note, 'a;b'); eq('second set', back.pt.fontscale, 4)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
