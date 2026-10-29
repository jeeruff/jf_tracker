-- tests/test_dsprack.lua — раскладка мини-роутера (RK.route_layout)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local RK = dofile(DIR .. '/jf_tracker_dsprack.lua')
local fails, n = 0, 0
local function ok(c, msg) n = n + 1; if not c then fails = fails + 1; print('FAIL ' .. msg) end end
local O = { x = 0, y = 0, w = 200, h = 100, nw = 30, nh = 10, gx = 6, bw = 4, rgap = 2 }

-- последовательно: вправо, черта между каждым
local b, l = RK.route_layout({ { k = 1 }, { k = 2 }, { k = 3 } }, O)
ok(#b == 3, 'three boxes')
ok(b[1].y == b[2].y and b[2].y == b[3].y, 'serial: one row')
ok(b[2].x == b[1].x + 30 + 6 and b[3].x == b[2].x + 36, 'serial: step nw + gx')
ok(#l == 2 and l[1].x1 == b[1].x + 30 and l[1].x2 == b[2].x, 'links between columns')

-- параллельно: столбиком под предыдущим, без черты
b, l = RK.route_layout({ { k = 1 }, { k = 2, par = 1 }, { k = 3, par = 1 }, { k = 4 } }, O)
ok(b[2].x == b[1].x and b[3].x == b[1].x, 'parallel: same column')
ok(b[2].y == b[1].y + 12 and b[3].y == b[1].y + 24, 'parallel: rows nh + rgap')
ok(b[4].y == b[1].y and b[4].x > b[1].x, 'after a parallel group - next column, top row')
ok(#l == 1, 'one link (group -> next)')

-- первый узел с par — не бывает параллельным (нечему)
b = RK.route_layout({ { k = 1, par = 1 } }, O)
ok(b[1].x == 0 and b[1].y == 0, 'first par node - own column')

-- контейнер: [ перед ним, ] после последнего ребёнка, место под скобки
local br
b, l, br = RK.route_layout({ { k = 1, cont = true }, { k = 2 }, { k = 3, ncend = 1 }, { k = 4 } }, O)
ok(br[1] and not br[1].right and br[1].x == 0, '[ at the container start')
ok(b[1].x == 4, 'container box after [')
ok(br[2] and br[2].right and br[2].x == b[3].x + 30 + 1, '] after the last child')
ok(b[4].x >= br[2].x + 2, 'next node right of ]')

-- не влезло в ширину — полоса ниже, без черты через перенос
local many = {}
for i = 1, 8 do many[i] = { k = i } end
b, l = RK.route_layout(many, O)
ok(b[6].y > b[1].y and b[6].x == 0, 'wrap: 6th node starts a new band at x')
local cross = false
for _, li in ipairs(l) do if li.x2 < li.x1 then cross = true end end
ok(not cross, 'no link across the wrap')

-- не влезло по высоте — cut, лишние не рисуются
local _, _, _, cut = RK.route_layout(many, { x = 0, y = 0, w = 80, h = 30, nw = 30, nh = 10, gx = 6, bw = 4 })
ok(cut, 'cut when out of height')

-- прямоугольники не перекрываются
b = RK.route_layout({ { k = 1 }, { k = 2, par = 1 }, { k = 3, cont = true }, { k = 4, par = 1 }, { k = 5, ncend = 1 }, { k = 6 } }, O)
local over = false
for i = 1, #b do for j = i + 1, #b do
  local p, q = b[i], b[j]
  if p.x < q.x + q.w and q.x < p.x + p.w and p.y < q.y + q.h and q.y < p.y + p.h then over = true end
end end
ok(not over, 'boxes do not overlap')

-- блок FXCHAIN: вложенные <...> (VST с base64, контейнер), конец — свой '>'
local ch = '<TRACK\nNAME x\n<FXCHAIN\nSHOW 0\n<VST "VST: A" a.vst 0\nAAAA\n>\nFXID {1}\n<CONTAINER Container "" \n<JS foo ""\n0 0\n>\n>\n>\n<ITEM\nPOSITION 0\n>\n>\n'
local fc, a, e = RK.fxchain(ch)
ok(fc and fc:sub(1, 9) == '<FXCHAIN\n', 'fxchain starts at <FXCHAIN')
ok(fc and fc:sub(-2) == '>\n' and not fc:find('<ITEM', 1, true), 'fxchain ends before <ITEM')
ok(ch:sub(1, a - 1) .. fc .. ch:sub(e + 1) == ch, 'fxchain positions splice back')
ok(RK.fxchain('<TRACK\nNAME x\n>\n') == nil, 'no fxchain - nil')

-- подписи согласными
ok(RK.abbrev('jf_slixer') == 'jfs', 'abbrev jf_slixer -> jfs')
ok(RK.abbrev('slixer') == 'slx', 'abbrev slixer')
ok(RK.abbrev('Container') == 'Cnt', 'abbrev Container')
ok(RK.abbrev('VST: ReaEQ (Cockos)') == 'RQ', 'abbrev drops prefix and vendor')
ok(RK.abbrev('Eau') == 'Eau', 'too few consonants - the name start')

-- 29 окт: вертикальный вид: последовательно — вниз, параллельно — вправо в той же строке, контейнер — отступ детей
do
  local nodes = { { k = 1, name = 'A' }, { k = 2, name = 'B', cont = true }, { k = 3, name = 'C', depth = 1 }, { k = 4, name = 'D', depth = 1, par = 1 }, { k = 5, name = 'E' } }
  local b = RK.route_layout_v(nodes, { x = 0, y = 0, w = 200, h = 200, nw = 40, nh = 10, gx = 6, bw = 4, rgap = 2, ind = 8 })
  ok(#b == 5, 'vertical: all five boxes')
  ok(b[2].y > b[1].y and b[2].x == b[1].x, 'vertical: serial goes down')
  ok(b[3].x == 8, 'vertical: inside a container - indented')
  ok(b[4].y == b[3].y and b[4].x > b[3].x, 'vertical: parallel - to the right in the same row')
  ok(b[5].y > b[3].y and b[5].x == 0, 'vertical: next serial below, no indent')
end
print(('test_dsprack: %d/%d ok'):format(n - fails, n))
os.exit(fails == 0 and 0 or 1)
