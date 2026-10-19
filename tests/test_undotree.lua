-- test_undotree.lua — модель дерева undo (15 окт)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local UT = dofile(DIR .. '/jf_tracker_undotree.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end

local T = UT.new()
local a = UT.add(T, 'a'); local b = UT.add(T, 'b'); local c = UT.add(T, 'c')
eq('linear cur', T.cur, c)
UT.undo(T); UT.undo(T)
eq('two undos at a', T.cur, a)
eq('redo goes to b', UT.live_kid(T, a), b)
-- ветка: новая правка на a — b и c умирают
local d, dead = UT.add(T, 'd')
eq('dead count', #dead, 2)
eq('b dead', T.nodes[b].live, false); eq('c dead', T.nodes[c].live, false)
eq('d live', T.nodes[d].live, true)
eq('a kids', #T.nodes[a].kids, 2)
-- путь: к a — undo 1; к c — только снимком; к d снова — redo
local p = UT.plan(T, a); eq('plan to a undo', p.undo, 1); eq('plan to a redo', #p.redo, 0)
p = UT.plan(T, c); eq('plan to dead c', p.restore, c)
UT.undo(T); p = UT.plan(T, d); eq('plan back to d', p.redo[1], d); eq('plan up 0', p.undo, 0)
UT.redo(T); eq('redo to d', T.cur, d)
p = UT.plan(T, 0); eq('to the original', p.undo, 2)
-- раскладка: d (вторая ветка a) — своя колонка
local rows, maxc = UT.layout(T)
eq('rows', #rows, 5); eq('newest on top', rows[1].id, d)
local colof = {}; for _, r in ipairs(rows) do colof[r.id] = r.col end
eq('b continues a', colof[b], colof[a]); eq('d in a new column', colof[d] > colof[a], true); eq('maxc', maxc, 1)
-- файл событий: повтор даёт то же дерево
local log = {}
local T2 = UT.new()
local function rec(id) log[#log + 1] = UT.ev_node(T2.nodes[id]) end
rec(UT.add(T2, 'a')); rec(UT.add(T2, 'b'))
UT.undo(T2); log[#log + 1] = UT.ev_cur(T2.cur)
local nd, dd = UT.add(T2, 'x'); rec(nd); for _, id in ipairs(dd) do log[#log + 1] = UT.ev_dead(id) end
log[#log + 1] = UT.ev_snap(2, 'TRACK\t3\nabc\n')
local L, snaps = UT.load(table.concat(log))
eq('load cur', L.cur, nd); eq('load b dead', L.nodes[2].live, false); eq('load snap', snaps[2], 'TRACK\t3\nabc\n')
eq('load b has snap', L.nodes[2].snap, true)
-- упаковка снимка: данные с переводами строк и табами — как есть
local data = UT.pack({ { 'T', 'line1\nline2\twith tab' }, { 'M', '' }, { 'K', 'x' } })
local parts = UT.unpack(data)
eq('pack parts', #parts, 3); eq('pack body', parts[1][2], 'line1\nline2\twith tab'); eq('pack empty', parts[2][2], ''); eq('pack tag', parts[3][1], 'K')
-- сессия на имитации стека undo REAPER: состояние проекта — строка, стек — подписи и состояния
do
  local R = { hist = { { label = '', state = 'S0' } }, pos = 1, cc = 0, state = 'S0', files = {} }
  local function top() return R.hist[R.pos] end
  local function push(label, state)
    for i = #R.hist, R.pos + 1, -1 do R.hist[i] = nil end         -- новая правка отбрасывает redo
    R.hist[#R.hist + 1] = { label = label, state = state }; R.pos = #R.hist; R.state = state; R.cc = R.cc + 1
  end
  local api = {
    undo_desc = function() return R.pos > 1 and top().label or '' end,
    redo_desc = function() return R.hist[R.pos + 1] and R.hist[R.pos + 1].label or '' end,
    count = function() return R.cc end,
    do_undo = function() if R.pos > 1 then R.pos = R.pos - 1; R.state = top().state; R.cc = R.cc + 1 end end,
    do_redo = function() if R.hist[R.pos + 1] then R.pos = R.pos + 1; R.state = top().state; R.cc = R.cc + 1 end end,
    capture = function() return R.state end,
    restore = function(data, label) push(label, data) end,
    read = function(path) return R.files[path] end,
    append = function(path, s2) R.files[path] = (R.files[path] or '') .. s2 end,
    now = function() return 0 end,
  }
  local S = UT.session(api, 'p.jf-undo')
  local function tedit(label, state) push('jf_tracker: ' .. label, state); UT.hook(S, 'jf_tracker: ' .. label) end
  local function tundo() UT.before_undo(S); api.do_undo(); UT.poll(S) end
  tedit('a', 'A'); tedit('a', 'A2'); tedit('b', 'B')            -- две одинаковые подписи подряд
  eq('s: three nodes', S.T.seq, 3)
  UT.hook(S, 'jf_tracker: nothing'); eq('s: an edit without an undo step - no node', S.T.seq, 3)
  push('Move items', 'N'); UT.poll(S)                             -- правка мимо трекера
  eq('s: native node', S.T.nodes[S.T.cur].label, 'Move items')
  tundo(); tundo()                                                -- трекером: до B, потом до A2
  eq('s: at A2', R.state, 'A2'); eq('s: tree at node 2', S.T.cur, 2)
  eq('s: snapshot of the native node', S.snaps[4], 'N')
  api.do_undo(); UT.poll(S)                                       -- Cmd+Z мимо трекера: снимок через шаг вперёд-назад
  eq('s: native undo to A', S.T.cur, 1); eq('s: state A', R.state, 'A'); eq('s: snapshot of A2', S.snaps[2], 'A2')
  tedit('c', 'C')                                                 -- ветка от A: A2, B, N умирают
  eq('s: A2 dead', S.T.nodes[2].live, false); eq('s: N dead', S.T.nodes[4].live, false)
  local msg = UT.go(S, 4, function() tundo() end, function() api.do_redo() end)   -- на мёртвую ветку — снимок
  eq('s: restored N', R.state, 'N'); eq('s: restore is a new node', S.T.nodes[S.T.cur].label, 'jf_tracker: undotree to Move items')
  msg = UT.go(S, 5, function() tundo() end, function() api.do_redo() end)          -- назад к C родным undo
  eq('s: back at C', R.state, 'C'); eq('s: at node C', S.T.cur, 5)
  eq('s: go msg', msg, 'undo tree: at "c"')
  -- файл: повтор событий даёт то же дерево и снимки
  local L2, sn2 = UT.load(R.files['p.jf-undo'])
  eq('s: file nodes', L2.seq, S.T.seq); eq('s: file snap N', sn2[4], 'N'); eq('s: file cur', L2.cur, S.T.cur)
end
-- 16 окт: большой вид — шкала времени
do
  local T = UT.new()
  UT.add(T, 'a', 1000); UT.add(T, 'b', 1130); UT.add(T, 'c', 4600)
  local t0, t1 = UT.span(T)
  eq('span: from the first timed node', t0, 1000); eq('span: to the last', t1, 4600)
  local tk, step = UT.ticks(t0, t1, 6)
  eq('ticks: round step that fits', step, 600)
  eq('ticks: no more than maxn', #tk <= 6, true)
  eq('ticks: aligned to the step', tk[1] % 600, 0)
  eq('ticks: inside the span', tk[1] >= t0 and tk[#tk] <= t1, true)
  eq('ticks: empty span', #UT.ticks(5, 5, 4), 0)
  eq('delta: seconds', UT.delta(12), '+12s'); eq('delta: minutes', UT.delta(300), '+5m')
  eq('delta: hours', UT.delta(7300), '+2h'); eq('delta: none', UT.delta(0), '')
end
-- 19 окт: сжатие файла — dump → load: те же узлы, текущий, умершие; снимков — сколько было в памяти
do
  local T = UT.new()
  UT.add(T, 'a', 1); UT.add(T, 'b', 2); T.cur = 1; UT.add(T, 'c', 3)
  local snaps = { [1] = 'SNAP1', [3] = 'SNAP3' }
  local T2, s2 = UT.load(UT.dump(T, snaps))
  eq('dump: nodes', #(function() local t = {}; for id in pairs(T2.nodes) do t[#t + 1] = id end; return t end)(), 4)
  eq('dump: cur', T2.cur, T.cur)
  eq('dump: dead', T2.nodes[2].live, false)
  eq('dump: snap', s2[3], 'SNAP3')
end
-- 19 окт: регрессия — сессия из файла (UT.session с текстом): падала на snap_keep (локальная ниже по файлу)
do
  local T = UT.new(); UT.add(T, 'a', 1)
  local txt = UT.dump(T, { [1] = 'S1' })
  local api = { read = function() return txt end, undo_desc = function() return '' end, redo_desc = function() return '' end, count = function() return 0 end }
  local ok, S = pcall(UT.session, api, '/tmp/x.jf-undo')
  eq('session from a file', ok, true)
  eq('session snap', ok and S.snaps[1], 'S1')
end
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
