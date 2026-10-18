-- tests/test_playlist.lua — playlist матрицы: разбор текста, модификаторы, секции, хранение (18 окт)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local PL = dofile(DIR .. '/jf_tracker_playlist.lua')
local n, bad = 0, 0
local function eq(name, got, want)
  n = n + 1
  if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end
end

local A1, B1, C1 = { name = 'A1', idx = 1 }, { name = 'B1', idx = 2 }, { name = 'C1', idx = 4 }
local by = { a1 = A1, b1 = B1, c1 = C1 }
local function find(ref)
  local r = ref:lower()
  if r == 'verse' then return { { rg = A1, rows = 32 }, { rg = B1, rows = 32 } } end
  if r == '4' then return { { rg = C1, rows = 32 } } end
  if by[r] then return { { rg = by[r], rows = 32 } } end
end

local st, toks, errs = PL.parse('A1 b1x2', find)
eq('plain: steps', #st, 3); eq('plain: no errors', #errs, 0)
eq('plain: lower case finds', st[2].rg, B1); eq('repeat: twice', st[3].rg, B1)
eq('plain: whole', PL.whole(st[1]), true)
st = PL.parse('A1:16', find)
eq('len: 16 rows', st[1].len, 16); eq('len: not whole', PL.whole(st[1]), false)
st = PL.parse('A1/4', find); eq('div: a quarter', st[1].len, 8)
st = PL.parse('A1+8', find); eq('skip: from', st[1].from, 8); eq('skip: the rest', st[1].len, 24)
st = PL.parse('A1+8:8*2', find); eq('combo: steps', #st, 2); eq('combo: from', st[2].from, 8); eq('combo: len', st[2].len, 8)
st = PL.parse('A1:99', find); eq('len: capped by the pattern', st[1].len, 32)
st = PL.parse('verse x2', find)
eq('section: patterns in order', st[1].rg, A1); eq('section: then', st[2].rg, B1)
eq('section + separate word x2: not a modifier', #select(3, PL.parse('verse x2', find)), 1)
st = PL.parse('versex2', find); eq('section x2', #st, 4)
st = PL.parse('4', find); eq('number: region', st[1].rg, C1)
st, toks, errs = PL.parse('A1 Z9 A1?3', find)
eq('errors: two', #errs, 2); eq('errors: the good word plays', #st, 1); eq('errors: marked word', toks[2].err ~= nil, true)
eq('tokens: positions', toks[2].s, 4); eq('tokens: end', toks[2].e, 5)
st = PL.parse('A1, B1;C1|A1', find); eq('separators', #st, 4)
eq('summary', select(2, PL.summary(PL.parse('A1 B1:8', find))), 40)
local c = PL.complete('a', { 'A1', 'A2', 'B1', 'arp', 'A1' })
eq('complete: matches', #c, 3); eq('complete: sorted', c[1], 'A1'); eq('complete: arp', c[3], 'arp')
local l = PL.decode(PL.encode({ { name = 'main', text = 'A1 B1x2' }, { name = 'short', text = 'A1:8' } }))
eq('store: two', #l, 2); eq('store: name', l[2].name, 'short'); eq('store: text', l[1].text, 'A1 B1x2')
eq('free name', PL.free_name({ { name = 'playlist 1' } }), 'playlist 2')
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
