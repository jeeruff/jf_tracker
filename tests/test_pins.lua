-- test_pins.lua — матрица пинов (jf_tracker_pins.lua) на поддельном API
local PN = dofile('jf_tracker_pins.lua')
local n, bad = 0, 0
local function ok(c, what) n = n + 1; if not c then bad = bad + 1; print('FAIL ' .. what) end end

local pins = { [0] = { [0] = 1, [1] = 2 }, [1] = { [0] = 1, [1] = 2, [2] = 4, [3] = 8 } }
local A = {
  GetIOSize = function() return 0, 2, 4 end,
  GetPinMappings = function(_, _, isout, p) return pins[isout][p], 0 end,
  GetNamedConfigParm = function(_, _, key) if key == 'out_pin_2' then return true, 'Scene A L' end return false, '' end,
}
local st = PN.read(A, nil, 0, 6)
ok(st.nin == 2 and st.nout == 4 and st.nch == 6, 'sizes')
ok(PN.has(st.ins[0], 0) and not PN.has(st.ins[0], 1), 'input 1 from channel 1')
ok(st.outn[2] == 'Scene A L' and st.outn[0] == 'out 1', 'pin names')
ok(PN.toggle(st, 'out', 0, 2) == 5, 'toggle adds a channel')
ok(PN.toggle(st, 'out', 0, 2) == 1, 'toggle again removes it')
PN.reset(st)
ok(st.outs[3] == 8 and st.ins[1] == 2, 'reset is the diagonal')
local cells, ix, ox = PN.grid(st, 10, 20, 8, 6, 30, 12)
ok(#cells == 6 * (2 + 4), 'a cell for every pin and channel')
ok(ix == 40 and ox == 40 + 2 * 8 + 12, 'the outputs right of the inputs')
local st2 = PN.read(A, nil, 0, 99)
ok(st2.nch == PN.MAXCH, 'channels clamp to 32')
print(('test_pins: %d checks, %d failed'):format(n, bad))
