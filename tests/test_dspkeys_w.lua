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
-- 22 окт: INSERT параметра (i)
do
  local got
  DK.init({ msg = function() end, dsp_value = function() end, dsp_type_entry = function(k, pi, buf) got = k .. ':' .. pi .. ':' .. buf end })
  local s2 = { fx = 2, param = 3 }
  local function k2(str) for ch in str:gmatch('.') do DK.key(ch:byte(), s2, 4, 9, {}) end end
  k2('i'); eq('i opens the parameter INSERT', DK.ins ~= nil, true)
  k2('hp2'); DK.key(8, s2, 4, 9, {}); eq('letters and digits go to the buffer, BS erases', DK.ins.buf, 'hp')
  DK.key(13, s2, 4, 9, {}); eq('Enter sends the entry', got, '2:3:hp'); eq('…and closes it', DK.ins, nil)
  k2('i'); k2('12'); DK.key(27, s2, 4, 9, {}); eq('Esc cancels', DK.ins, nil); eq('…nothing sent', got, '2:3:hp')
  DK.digits_play = true; DK.pslider = true
  local r = DK.key(('5'):byte(), s2, 4, 9, {}); eq('KEYS on: a digit is not captured', r, false); eq('…no count', DK.num, nil)
  DK.digits_play = false; DK.pslider = nil
end
-- 22 окт: несколько модулей (Shift / Cmd-щелчок)
do
  local calls = {}
  DK.init({ msg = function() end, dsp_delete = function(a, b) calls[#calls + 1] = 'del ' .. a .. '-' .. b end,
    dsp_delete_list = function(l) calls[#calls + 1] = 'dellist ' .. table.concat(l, ',') end,
    dsp_bypass = function(k) calls[#calls + 1] = 'byp ' .. k end, dsp_pack = function(a, b) calls[#calls + 1] = 'pack ' .. a .. '-' .. b end })
  local s3 = { fx = 4, param = 1 }
  DK.marks = { [1] = true, [4] = true }
  eq('picked: Cmd marks in order', table.concat(DK.picked(s3), ','), '1,4')
  DK.key(('b'):byte(), s3, 6, 3, {}); eq('b bypasses every picked', calls[#calls - 1] .. ' / ' .. calls[#calls], 'byp 1 / byp 4')
  DK.key(('c'):byte(), s3, 6, 3, {}); eq('cc on picks apart: no pack', #calls, 2); eq('…pick dropped', DK.marks, nil)
  DK.marks = { [2] = true, [5] = true }
  DK.key(('x'):byte(), s3, 6, 3, {}); eq('x deletes picks apart as a list', calls[#calls], 'dellist 2,5')
  DK.anchor = 2; s3.fx = 4
  eq('picked: Shift range', table.concat(DK.picked(s3), ','), '2,3,4')
  DK.key(('x'):byte(), s3, 6, 3, {}); eq('x on a range: one delete', calls[#calls], 'del 2-4'); eq('…range dropped', DK.anchor, nil)
  DK.marks = { [3] = true }; DK.key(27, s3, 6, 3, {}); eq('Esc drops the pick', DK.marks, nil)
end
print(('%d checks, %d failed'):format(n, bad)); os.exit(bad == 0 and 0 or 1)
