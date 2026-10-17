-- tests/test_padseq.lua — pads (MPC): список паттернов, клавиша → паттерн, sudden-фаза, запись порядка (17 окт)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local P = dofile(DIR .. '/jf_tracker_padseq.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
local function rg(idx, name, a, b) return { idx = idx, name = name, pos = a, rgnend = b } end
local seq = { rg(1, 'A1', 0, 2), rg(2, 'B1', 2, 4), rg(3, 'A1', 4, 6), { gap = true, name = '', pos = 6, rgnend = 8 }, rg(4, 'C1', 8, 9) }
seq[#seq + 1] = { idx = 9, name = 'drop', pos = 0, rgnend = 6, section = true }
local L = P.list(seq)
eq('unique patterns in song order', #L, 3); eq('first A1', L[1].name, 'A1'); eq('then B1', L[2].name, 'B1'); eq('then C1', L[3].name, 'C1')
eq('key offset 0 = first', P.pick(L, 0).name, 'A1'); eq('offset 2 = third', P.pick(L, 2).name, 'C1'); eq('past the list', P.pick(L, 5), nil)
eq('sudden keeps the phase', P.sudden_pos(seq[1], 1.5, seq[2]), 3.5)
eq('sudden: phase wraps a shorter pattern', P.sudden_pos(seq[1], 1.5, seq[5]), 8.5)
P.rec, P.log = true, {}
P.rec_tick(seq[1], 0.1); P.rec_tick(seq[1], 1.0); P.rec_tick(seq[2], 2.1); P.rec_tick(seq[2], 0.2)   -- B1 played again (jump back)
local names = table.concat(P.names(), ' ')
eq('rec: the played order, a repeat counts', names, 'A1 B1 B1')
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
