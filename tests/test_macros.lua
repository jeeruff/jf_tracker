-- test_macros.lua — вкладка macros: lua tests/test_macros.lua
local MR = dofile('jf_tracker_macros.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end end
local keys = { 100, 100, 106, 13, 60, 27 }
local s = MR.encode(keys)
eq('encode', s, 'ddj<13><60><27>')
local back = MR.decode(s)
eq('decode len', #back, 6); eq('decode enter', back[4], 13); eq('decode <', back[5], 60)
local list = MR.parse('# c\nmy fill\t:scramble\nbad line\nhop\tjjj<13>\n')
eq('parse count', #list, 2); eq('parse name', list[1].name, 'my fill'); eq('parse body', list[2].body, 'jjj<13>')
eq('serialize round trip', #MR.parse(MR.serialize(list)), 2)
local rows = MR.rows({ ['@a'] = { 100, 100 }, ['@b'] = {}, ['"'] = { 1 } }, list)
local rec = 0; for _, r in ipairs(rows) do if r.kind == 'rec' then rec = rec + 1 end end
eq('only non-empty letter registers', rec, 1)
MR.sel = 1
local r = MR.key(13, rows)
eq('Enter plays the first macro', type(r) == 'table' and r.kind, 'play')
eq('first selectable is @a', r.row.name, 'a')
eq('s saves recorded', MR.key(('s'):byte(), rows).kind, 'save')
MR.key(('j'):byte(), rows); MR.key(('j'):byte(), rows)
eq('d on saved deletes', MR.key(('d'):byte(), rows).kind, 'delete')
eq('unknown key passes', MR.key(('z'):byte(), rows), nil)
-- 16 окт: описание в файле, .jfm, тело для глаз, клавиши редактора
local l2 = MR.parse(MR.serialize({ { name = 'fill', body = 'dd<13>', key = 'x', desc = 'a fill' }, { name = 'plain', body = ':off' } }))
eq('desc round trip', l2[1].desc, 'a fill'); eq('key kept with desc', l2[1].key, 'x'); eq('no desc', l2[2].desc, nil)
local jm = MR.jfm_decode(MR.jfm_encode({ name = 'my fill', body = 'dd<13>', desc = 'd', by = 'me', key = 'q' }))
eq('jfm name', jm and jm.name, 'my fill'); eq('jfm body', jm and jm.body, 'dd<13>'); eq('jfm by', jm and jm.by, 'me'); eq('jfm key', jm and jm.key, 'q')
eq('jfm bad', MR.jfm_decode('hello'), nil)
eq('file name', MR.file_name('my fill / 2'), 'my_fill_2.jfm')
eq('pretty', MR.pretty('dd<13>j<27>'), 'dd Enter j Esc')
eq('pretty cmd as is', MR.pretty(':xf rotate 4'), ':xf rotate 4')
local r3 = MR.rows({}, {}, nil, { { name = 'sh', body = ':off', file = 'sh.jfm' } })
local has_sh = false; for _, r in ipairs(r3) do if r.kind == 'shared' then has_sh = true end end
eq('shared section', has_sh, true)
MR.sel, MR.dir = 0, 3; MR.fix_sel(r3)   -- 18 окт: lf — папка shared (recorded, saved, shared)
eq('lf: first of the folder', r3[MR.sel] and r3[MR.sel].kind, 'shared')
MR.key(('h'):byte(), r3); MR.key(('k'):byte(), r3); eq('lf: k in folders - the previous folder', MR.dir, 2)
MR.key(('j'):byte(), r3); MR.key(('l'):byte(), r3); eq('lf: back to shared', MR.dir, 3)
eq('e edits', MR.key(('e'):byte(), r3).kind, 'edit')
eq('a new', MR.key(('a'):byte(), r3).kind, 'new')
-- 16 окт: хоткеи
eq('hk encode', MR.hk_encode(10, { ctrl = true, alt = true }), 'CA-10')
eq('hk label ctrl letter', MR.hk_label('CA-10'), 'Ctrl+Opt+J')
eq('hk label cmd', MR.hk_label('MS-107'), 'Cmd+Shift+K')
local l3 = MR.parse(MR.serialize({ { name = 'x', body = ':off', hotkey = 'CA-10' } }))
eq('hotkey round trip', l3[1].hotkey, 'CA-10'); eq('no desc with hotkey', l3[1].desc, nil)
print(('test_macros: %d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
