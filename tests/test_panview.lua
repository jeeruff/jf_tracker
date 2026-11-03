-- test_panview.lua (2 ноя) — вид пана: позиция ↔ пан (17 и 33), пан ячеек, строка трека
package.path = './?.lua;' .. package.path
local PV = dofile('jf_tracker_panview.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end end
eq('centre 17', PV.pos_of(0, 17), 9); eq('centre 33', PV.pos_of(0, 33), 17)
eq('hard left', PV.pos_of(-1, 17), 1); eq('hard right', PV.pos_of(1, 17), 17)
eq('pan of centre', PV.pan_of(9, 17), 0); eq('pan of 1', PV.pan_of(1, 17), -1); eq('pan of 17', PV.pan_of(17, 17), 1)
for i = 1, 33 do eq('roundtrip 33 #' .. i, PV.pos_of(PV.pan_of(i, 33), 33), i) end
eq('hex 80 = centre', PV.hex_pan(128), 0); eq('hex 00 = left', PV.hex_pan(0), -1); eq('hex FF = right', PV.hex_pan(255), 1)
eq('pan_hex centre', PV.pan_hex(0), 128); eq('pan_hex left', PV.pan_hex(-1), 0); eq('pan_hex right', PV.pan_hex(1), 255)
eq('audio pan hex', PV.pos_of(PV.cell_pan({ kind = 'audio', pan = '00' }), 17), 1)
eq('midi 0P', PV.pos_of(PV.cell_pan({ kind = 'midi', fx = { '0S10', '0PFF' } }), 17), 17)
eq('no pan - centre', PV.pos_of(PV.cell_pan({ kind = 'midi', fx = {} }), 17), 9)
local head = { kind = 'audio', pan = 'C0', note = 'C#4' }
local col = { lanes = { { subs = { { [3] = head, [4] = { kind = 'cont', of = head } } } } } }
local r3, r4 = PV.row(col, 3, 17), PV.row(col, 4, 17)
eq('row head', #r3 == 1 and not r3[1].cont, true); eq('row cont', r4[1] and r4[1].cont, true)
eq('same position', r3[1].pos, r4[1].pos); eq('right of centre', r3[1].pos > 9, true)
eq('glyph sharp', PV.glyph(head), 'c'); eq('glyph natural', PV.glyph({ note = 'E-4' }), 'E')
eq('label 17 - the note', PV.label({ note = 'C-4' }, 17), 'C-4'); eq('label micro', PV.label({ note = 'C#4', micro = 2 }, 33), 'C#4^^')
eq('label 13 - a letter', PV.label({ note = 'C#4' }, 13), 'c')
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
