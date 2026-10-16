-- test_drumrack.lua — drumrs5k (16 окт): избранное, категории, место в пэде, сетка, клавиши, запекание
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local DR = dofile(DIR .. '/jf_tracker_drumrack.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end

-- избранное
local f = DR.parse_fav('', 'comp')
eq('empty -> defaults', f[1], 'ReaComp (Cockos)')
f = DR.parse_fav(' A | B ||', 'comp')
eq('parse trims', f[2], 'B'); eq('parse count', #f, 2)
eq('encode', DR.encode_fav({ 'A', 'B' }), 'A|B')
f = DR.fav_add({ 'A', 'B', 'C' }, 'B')
eq('add moves to front', f[1], 'B'); eq('add no dup', #f, 3); eq('add keeps order', f[2], 'A')

-- категории
eq('short', DR.short('VST3: Pro-Q 3 (FabFilter)'), 'Pro-Q 3')
eq('cat eq before flt', DR.cat_of('VST: ReaEQ (Cockos)'), 'eq')
eq('cat filter', DR.cat_of('JS: Moog 4-Pole Filter'), 'flt')
eq('cat comp', DR.cat_of('VST: ReaComp (Cockos)'), 'comp')
eq('cat dist', DR.cat_of('JS: Saturation'), 'dist')
eq('cat unknown', DR.cat_of('JS: Volume Adjustment'), nil)
eq('cat from favs', DR.cat_of('AU: Odd Thing (X)', { dist = { 'AU: Odd Thing (X)' } }), 'dist')

-- место в пэде: [rs5k, eq] + comp → после eq; + flt → после rs5k
eq('pos comp after eq', DR.insert_pos({ 'rs5k', 'eq' }, 'comp'), 2)
eq('pos flt before eq', DR.insert_pos({ 'rs5k', 'eq' }, 'flt'), 1)
eq('pos into empty pad', DR.insert_pos({ 'rs5k' }, 'dist'), 1)
eq('pos before an unknown fx (it stays last)', DR.insert_pos({ 'rs5k', 'eq', 'other' }, 'dist'), 2)

-- сетка
local g = DR.grid(16, 400, 200, 60, 30)
eq('grid 4 cols', g.cols, 4); eq('grid 4 rows', g.rows, 4); eq('grid cell w', g.cw, 100)
g = DR.grid(16, 520, 200, 60, 30)
eq('grid 8 cols when wide', g.cols, 8)
g = DR.grid(3, 520, 200, 60, 30)
eq('grid no more cols than pads', g.cols, 3)
g = DR.grid(32, 250, 120, 60, 30)
eq('grid scrolls: fit < rows', g.fit < g.rows, true)

-- клавиши
local piano = { q = 0, ['2'] = 1, w = 2, ['3'] = 3, e = 4, r = 5 }
eq('key C of octave 4', DR.key_of(60, piano, 4), 'q')
eq('key E', DR.key_of(64, piano, 4), 'e')
eq('key out of layout', DR.key_of(72, piano, 4), nil)
eq('key by char code', DR.key_of(62, { [('w'):byte()] = 2 }, 4), 'w')

-- пэды
local rs = { entry = { rs5k = true }, i = 5 }
local padc = { i = 9, entry = { container = true, kids = { { i = 11, entry = { rs5k = true } }, { i = 12, entry = {} } } } }
local _, id = DR.pad_rs5k(padc)
eq('pad in sub-container -> its RS5K', id, 11)
eq('rack: RS5K + pad', DR.is_rack({ rs, padc }), true)
eq('rack: one pad is not a rack', DR.is_rack({ rs }), false)
eq('rack: foreign fx', DR.is_rack({ rs, { entry = {} } }), false)

-- запекание
local s = DR.bake_encode({ file = '/a|b/x.wav', a = 0.25, b = 0.5, mode = 589824, pitch = -2, rate = 1.5 })
local t = DR.bake_decode(s)
eq('bake file with |', t and t.file, '/a|b/x.wav'); eq('bake mode', t and t.mode, 589824); eq('bake rate', t and t.rate, 1.5)
eq('bake bad', DR.bake_decode('garbage'), nil)

print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
