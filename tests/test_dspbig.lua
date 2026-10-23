-- test_dspbig.lua — DSP big (7 окт): дерево, ряды, раскладка, навигация,
-- правки через ops. lua tests/test_dspbig.lua
package.path = './?.lua;' .. package.path
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end

-- цепочка: eq | [verb, dly] (dly parallel) | C1{ a, b(par) , c } | lim
-- адреса: верх 0..3; дети контейнера — условные 1000+
local fx = {
  [0] = { name = 'VST3: ReaEQ (Cockos)', guid = 'g-eq', par = 0, on = true },
  [1] = { name = 'JS: verb', guid = 'g-verb', par = 0, on = true, wet = 0.5 },
  [2] = { name = 'dly', guid = 'g-dly', par = 1, on = true, wet = 1 },
  [3] = { name = 'Container', guid = 'g-c1', par = 0, on = true, kids = { 1001, 1002, 1003 }, renamed = 'bus' },
  [4] = { name = 'lim', guid = 'g-lim', par = 0, on = false },
  [1001] = { name = 'a', guid = 'g-a', par = 0, on = true },
  [1002] = { name = 'b', guid = 'g-b', par = 1, on = true },
  [1003] = { name = 'c', guid = 'g-c', par = 0, on = true },
}
reaper = {
  TrackFX_GetCount = function() return 5 end,
  TrackFX_GetFXName = function(_, a) return true, fx[a].name end,
  TrackFX_GetFXGUID = function(_, a) return fx[a].guid end,
  TrackFX_GetEnabled = function(_, a) return fx[a].on end,
  TrackFX_GetParamFromIdent = function(_, a) return fx[a].wet and 7 or -1 end,
  TrackFX_GetParamNormalized = function(_, a) return fx[a].wet end,
  TrackFX_GetNamedConfigParm = function(_, a, k)
    local f = fx[a]
    if k == 'parallel' then return true, tostring(f.par) end
    if k == 'renamed_name' then return true, f.renamed or '' end
    if k == 'container_count' then if f.kids then return true, tostring(#f.kids) end return false, '' end
    local i = k:match('^container_item%.(%d+)$')
    if i and f.kids then return true, tostring(f.kids[tonumber(i) + 1]) end
    return false, ''
  end,
}
local M = dofile('jf_tracker_model.lua')
local DB = dofile('jf_tracker_dspbig.lua')
local log = {}
local ops = setmetatable({}, { __index = function(_, k) return function(...) local t = { k }; for _, v in ipairs({ ... }) do t[#t + 1] = tostring(v) end; log[#log + 1] = table.concat(t, ' ') end end })
DB.init({}, {}, ops)

local root = DB.read('TR', M.fxapi('TR'))
eq('top count', #root.kids, 5)
eq('short name', root.kids[1].name, 'ReaEQ'); eq('renamed container', root.kids[4].name, 'bus')
eq('wet read', root.kids[2].wet, 0.5); eq('no wet', root.kids[1].wet, nil)
eq('container kids', #root.kids[4].kids, 3); eq('kid addr', root.kids[4].kids[2].addr, 1002)
eq('kid parent', root.kids[4].kids[1].parent, root.kids[4])

local st = DB.stages(root.kids)
eq('stages: verb+dly in one row', #st, 4); eq('row 2 members', #st[2], 2)
local kst = DB.stages(root.kids[4].kids)
eq('container rows', #kst, 2); eq('a,b parallel', #kst[1], 2)

-- раскладка: узел 10×4, gap 2, bus 1, pad 1, th 2
local m = { nw = 10, nh = 4, gap = 2, bus = 1, pad = 1, th = 2 }
local w, h = DB.layout(root, m, 0, 0, 0)
-- контейнер: цепь (a|b) шириной 12 + gap 2 + c 10 = 24 → рамка 26; высота цепи 10 → 14
eq('container w', root.kids[4].w, 26); eq('container h', root.kids[4].h, 14)
eq('chain w', w, 10 + 2 + 12 + 2 + 26 + 2 + 10); eq('chain h', h, 14)
eq('parallel members stacked', root.kids[3].y > root.kids[2].y, true)
eq('serial same centre', root.kids[1].y + 2, root.kids[5].y + 2)
eq('kid inside frame', root.kids[4].kids[1].x > root.kids[4].x and root.kids[4].kids[3].x + 10 <= root.kids[4].x + 26, true)

-- навигация
local eqn, verb, dly, c1, lim = root.kids[1], root.kids[2], root.kids[3], root.kids[4], root.kids[5]
local a, b, c = c1.kids[1], c1.kids[2], c1.kids[3]
eq('l: eq → verb', DB.move(root, eqn, 'l'), verb); eq('j: verb → dly', DB.move(root, verb, 'j'), dly)
eq('l from dly → container', DB.move(root, dly, 'l'), c1); eq('l into container', DB.move(root, c1, 'l'), a)
eq('l: c (end of inner) → lim', DB.move(root, c, 'l'), lim); eq('h: a → container', DB.move(root, a, 'h'), c1)
eq('k at top stays', DB.move(root, verb, 'k'), verb); eq('l at the end stays', DB.move(root, lim, 'l'), lim)
DB.fold['g-c1'] = true; DB.layout(root, m, 0, 0, 0)
eq('folded: l skips inside', DB.move(root, c1, 'l'), lim); eq('folded: node size', c1.w, 10)
DB.fold = {}; DB.layout(root, m, 0, 0, 0)

-- точки вставки
local p, pos, pv = DB.insert_point(verb, false); eq('a on verb: after the row', pos, 3); eq('a: top', p, nil); eq('a: serial', pv, 0)
p, pos, pv = DB.insert_point(verb, true); eq('A on verb: right after', pos, 2); eq('A: parallel', pv, 1)
p, pos = DB.insert_point(a, false); eq('a inside container: parent', p, c1); eq('a inside: after a,b', pos, 2)

-- правки
log = {}
DB.delete(verb); eq('delete row head passes parallel', log[1], 'remove 1 2'); eq('sel after delete', DB.sel, 'g-dly')
log = {}; DB.delete(eqn); eq('delete serial', log[1], 'remove 0')
log = {}; DB.solo(verb); eq('solo bypasses the others', table.concat(log, ';'), 'enable 2 false')
dly.on = false; log = {}; DB.solo(verb); eq('solo again: all on', table.concat(log, ';'), 'enable 2 true'); dly.on = true
log = {}; DB.unity(dly); eq('unity: 1/2 each', log[1] .. ';' .. log[2], 'param 1 7 0.5;param 2 7 0.5')
log = {}; DB.solo(eqn); eq('solo outside a row', log[1], 'msg solo: not in a parallel row')

-- клавиши
DB.sel = 'g-eq'; log = {}
DB.key(('l'):byte(), root, 'TR'); eq('key l', DB.sel, 'g-verb')
DB.key(('b'):byte(), root, 'TR'); eq('key b', log[1], 'bypass 1')
DB.key(('|'):byte(), root, 'TR'); eq('| on a row head joins', log[2], 'parallel 1 1')
DB.sel = 'g-dly'; DB.key(('|'):byte(), root, 'TR'); eq('| on a member leaves', log[3], 'parallel 2 0')
DB.sel = 'g-eq'; DB.key(('|'):byte(), root, 'TR'); eq('| on the first fx refused', log[4]:match('^msg') ~= nil, true)
DB.sel = 'g-c1'; DB.key(('z'):byte(), root, 'TR'); DB.key(('a'):byte(), root, 'TR'); eq('za folds', DB.fold['g-c1'], true)
log = {}; DB.key(('d'):byte(), root, 'TR'); DB.key(('d'):byte(), root, 'TR'); eq('dd deletes', log[1], 'remove 3')
log = {}; DB.key(('z'):byte(), root, 'TR'); DB.key(('z'):byte(), root, 'TR'); eq('zz closes', log[1], 'close')
eq('unknown key not eaten', DB.key(('Y'):byte(), root, 'TR'), false)

-- 23 окт: полосы — [eq] [3-band splitter] [comp: каналы 3/4] [sat: 1/2] [verb: 5/6] [3-band joiner] [lim]
do
  eq('band kind splitter', select(1, DB.band_kind('JS: 3-Band Splitter')), 3)
  eq('band kind joiner', select(2, DB.band_kind('JS: loser/4-Band Joiner')), 4)
  eq('mask 1/2 -> band 0', DB.band_of_mask(1), 0); eq('mask 3/4 -> band 1', DB.band_of_mask(4), 1); eq('mask 5/6 -> band 2', DB.band_of_mask(16), 2)
  local function nd(k, t) t.k = k; t.guid = 'g' .. k; t.on = true; t.par = 0; return t end
  local root = { root = true, kids = { nd(0, { name = 'eq' }), nd(1, { name = 'split', split = 3, xover = { '200 Hz', '2000 Hz' } }),
    nd(2, { name = 'comp', pin_lo = 4 }), nd(3, { name = 'sat', pin_lo = 1 }), nd(4, { name = 'verb', pin_lo = 16 }),
    nd(5, { name = 'join', join = 3 }), nd(6, { name = 'lim' }) } }
  for _, k in ipairs(root.kids) do k.parent = root end
  DB.bandize(root)
  eq('bands: eq split 3 bands join lim', #root.kids, 7)
  local low, mid, high = root.kids[3], root.kids[4], root.kids[5]
  eq('low band virtual', low.virtual, true); eq('low has sat', low.kids[1] and low.kids[1].name, 'sat')
  eq('mid has comp', mid.kids[1] and mid.kids[1].name, 'comp'); eq('high has verb', high.kids[1] and high.kids[1].name, 'verb')
  eq('bands one parallel row', DB.stages(root.kids)[3][3], high)
  eq('band label', low.name, 'low  < 200 Hz'); eq('mid label', mid.name, 'mid  200 Hz-2000 Hz')
  eq('insert into mid after comp', DB.band_insert_pos(mid), 3)
  local empty = { kids = {}, s = root.kids[2] }
  eq('empty band - right after the splitter', DB.band_insert_pos(empty), 2)
  local m = { nw = 100, nh = 30, gap = 10, bus = 6, pad = 4, th = 14 }
  local okl = pcall(DB.layout, root, m, 0, 0, 200)
  eq('layout with bands', okl, true)
end
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
