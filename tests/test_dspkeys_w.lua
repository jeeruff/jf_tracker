-- test_dspkeys_w.lua — w / W в DSP (22 окт): следующий / предыдущий модуль по кругу, N w, из слайдера параметра
package.path = './?.lua;' .. package.path
local DK = dofile('jf_tracker_dspkeys.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
DK.init({ msg = function() end, dsp_value = function() end })
local sel = { fx = 1, param = 3 }
local function key(s) for ch in s:gmatch('.') do DK.key(ch:byte(), sel, 4, 9, {}) end end
DK.digits_play = false
key('w'); eq('w: next module', sel.fx, 2); eq('w: parameter back to 1', sel.param, 1)
key('W'); eq('W: previous', sel.fx, 1)
key('W'); eq('W on the first wraps to the last', sel.fx, 4)
key('w'); eq('w on the last wraps to the first', sel.fx, 1)
key('2w'); eq('2w: two modules on', sel.fx, 3)
DK.pslider = true; key('w'); eq('w from a parameter slider: next module', sel.fx, 4); eq('…slider closed', DK.pslider, nil)
DK.pads = true; sel.fx = 2; DK.pad_param_key = nil; key('w'); eq('pads mode: w is not module navigation', sel.fx, 2); DK.pads = nil
print(('%d checks, %d failed'):format(n, bad)); os.exit(bad == 0 and 0 or 1)
