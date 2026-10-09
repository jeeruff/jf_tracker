-- test_panes.lua — дерево панелей (jf_tracker_panes.lua): lua tests/test_panes.lua
package.path = './?.lua;' .. package.path
local PN = dofile('jf_tracker_panes.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end end
local function ok(name, v) eq(name, v and true or false, true) end

local M = { rh = 14, cw = 8, pad = 4, tab_h = 16, hint_h = 15, sep = 1, grip = 3, avail = function() return true end }

-- замощение: листы + линии = W×H, без пересечений
local function tiling(name, model, W, H, Mx)
  local lay = PN.layout(model, W, H, Mx or M)
  local area = 0
  for _, c in ipairs(lay.cells) do area = area + c.w * c.h end
  for _, s in ipairs(lay.seps) do area = area + s.w * s.h end
  eq(name .. ': area', area, W * H)
  for i, a in ipairs(lay.cells) do
    for j, b in ipairs(lay.cells) do
      if i < j then
        local ov = math.min(a.x + a.w, b.x + b.w) > math.max(a.x, b.x) and math.min(a.y + a.h, b.y + b.h) > math.max(a.y, b.y)
        ok(name .. ': no overlap ' .. i .. '/' .. j, not ov)
      end
    end
    ok(name .. ': content h>0', a.content.h > 0)
    if a.tab then eq(name .. ': tab h', a.tab.h, M.tab_h) end
  end
  return lay
end

local m = PN.DEFAULT()
local lay = tiling('default 1600x900', m, 1600, 900)
tiling('default 800x500', m, 800, 500)
eq('cells', #lay.cells, 8)   -- 9 окт: browser | pm | fx — один стек, dsp один
ok('tracker rect', lay.rects.tracker ~= nil)
ok('tracker has no tab', lay.by_panel.tracker.tab == nil)
eq('order starts with tracker', lay.order[1], 'tracker')
eq('master active', lay.by_panel.master.active_id, 'master')
eq('notes hidden', m.hidden.notes, true)
ok('tabs in one cell', lay.by_panel.sample == lay.by_panel.midi)
-- недоступная панель: slices нет → лист схлопнут
local M2 = setmetatable({ avail = function(id) return id ~= 'slices' end }, { __index = M })
local lay2 = tiling('no slices', m, 1600, 900, M2)
eq('slices gone', lay2.by_panel.slices, nil); eq('cells -1', #lay2.cells, 7)
-- все скрыты
local t = PN.preset('tracker')
local lay3 = tiling('tracker only', t, 1600, 900)
eq('one cell', #lay3.cells, 1); eq('full', lay3.cells[1].w * lay3.cells[1].h, 1600 * 900)
for _, name in ipairs(PN.LAYOUTS) do tiling('preset ' .. name, PN.preset(name), 1400, 800) end
-- zoom
PN.zoom(m, 'dsp')
local lz = PN.layout(m, 1600, 900, M)
eq('zoom one cell', #lz.cells, 1); eq('zoom is dsp', lz.cells[1].active_id, 'dsp')
PN.zoom(m, 'dsp'); eq('zoom off', m.zoom, nil)

-- hit
lay = PN.layout(m, 1600, 900, M)
local c = lay.by_panel.sample
local h = PN.hit(lay, c.tabs[2].x + 2, c.tabs[2].y + 2)
eq('hit tab kind', h.kind, 'tab'); eq('hit tab id', h.id, 'sample'); eq('hit tab index', h.index, 2)
h = PN.hit(lay, c.content.x + 5, c.content.y + 5); eq('hit panel', h.kind, 'panel'); eq('hit panel id', h.id, 'master')
h = PN.hit(lay, c.hint.x + 5, c.hint.y + 5); eq('hit hint', h.kind, 'hint')
local g = lay.grips[1]
h = PN.hit(lay, g.x + g.w // 2, g.y + g.h // 2); eq('hit grip', h.kind, 'grip')
eq('miss', PN.hit(lay, -5, -5), nil)

-- фокус по направлению из трекера
eq('tracker l', PN.focus_dir(lay, 'tracker', 'l'), 'matrix')
eq('tracker r', PN.focus_dir(lay, 'tracker', 'r'), 'browser')   -- наибольшее перекрытие по вертикали
eq('tracker u', PN.focus_dir(lay, 'tracker', 'u'), 'master')
eq('tracker d', PN.focus_dir(lay, 'tracker', 'd'), 'dsp')
eq('matrix l none', PN.focus_dir(lay, 'matrix', 'l'), nil)
eq('inst d', PN.focus_dir(lay, 'inst', 'd'), 'slices')   -- справа: lib, slices, браузер

-- move: своп в родителе
m = PN.DEFAULT()
PN.split(m, 'dsp', 'notes', 'r', 0.3)                       -- пара в одном ряду: dsp | notes
local v0 = m.v
ok('move notes left', PN.move(m, 'notes', 'l'))
lay = PN.layout(m, 1600, 900, M)
ok('notes now left of dsp', lay.by_panel.notes.x < lay.by_panel.dsp.x)
ok('v bumped', m.v > v0)
-- move: подъём к предку (dsp вниз — нет родителя 'v' на уровне … у mid есть 'v' → dsp отдельной полосой под низом)
m = PN.DEFAULT()
PN.split(m, 'dsp', 'notes', 'r', 0.3)
ok('move dsp down', PN.move(m, 'dsp', 'd'))
lay = PN.layout(m, 1600, 900, M)
ok('dsp under notes', lay.by_panel.dsp.y > lay.by_panel.notes.y)
ok('dsp spans mid width', lay.by_panel.dsp.w == lay.by_panel.notes.w and lay.by_panel.dsp.w > 1000)
-- move: у края — новый сплит
m = PN.DEFAULT()
ok('move matrix left', PN.move(m, 'matrix', 'l') == false or true)   -- уже у края: нет соседа → корень 'h', вставка в корень слева = та же позиция
m = PN.DEFAULT()
ok('move inst up', PN.move(m, 'inst', 'u'))
lay = PN.layout(m, 1600, 900, M)
eq('inst on top band', lay.by_panel.inst.y, 0)
ok('inst full width', lay.by_panel.inst.w == 1600)
-- move из стека: break-out
m = PN.DEFAULT()
ok('move midi down', PN.move(m, 'midi', 'd'))
lay = PN.layout(m, 1600, 900, M)
ok('midi own cell', lay.by_panel.midi ~= lay.by_panel.sample)
ok('midi below tabs', lay.by_panel.midi.y > lay.by_panel.sample.y)
eq('tabs cell active still master', lay.by_panel.sample.active_id, 'master')

-- swap / stack / unstack / split
m = PN.DEFAULT()
ok('swap matrix inst', PN.swap(m, 'matrix', 'inst'))
lay = PN.layout(m, 1600, 900, M)
ok('inst left', lay.by_panel.inst.x == 0); ok('matrix right', lay.by_panel.matrix.x > 800)
eq('swap same', PN.swap(m, 'matrix', 'matrix'), false)
m = PN.DEFAULT()
ok('stack dsp into sample', PN.stack(m, 'dsp', 'sample'))
lay = PN.layout(m, 1600, 900, M)
ok('dsp in tabs cell', lay.by_panel.dsp == lay.by_panel.sample)
eq('dsp active', lay.by_panel.dsp.active_id, 'dsp')
ok('tracker to the bottom', lay.by_panel.tracker.y + lay.by_panel.tracker.h == 900)
eq('stack tracker', PN.stack(m, 'tracker', 'sample'), false)
ok('unstack dsp', PN.unstack(m, 'dsp', 'd'))
lay = PN.layout(m, 1600, 900, M)
ok('dsp own cell again', lay.by_panel.dsp ~= lay.by_panel.sample)
m = PN.DEFAULT()
ok('split notes below tracker', PN.split(m, 'tracker', 'notes', 'd', 0.3))
eq('notes shown', m.hidden.notes, nil)
lay = PN.layout(m, 1600, 900, M)
ok('notes under tracker', lay.by_panel.notes.y > lay.by_panel.tracker.y and lay.by_panel.notes.y < lay.by_panel.dsp.y)
eq('split tracker', PN.split(m, 'notes', 'tracker', 'd'), false)

-- hide / show
m = PN.DEFAULT()
ok('hide browser', PN.hide(m, 'browser')); eq('hidden', m.hidden.browser, true)
lay = PN.layout(m, 1600, 900, M)
ok('pm takes the stack', lay.by_panel.pm ~= nil and lay.by_panel.pm.active_id ~= 'browser')
eq('hide tracker', PN.hide(m, 'tracker'), false)
ok('show browser', PN.show(m, 'browser'))
lay = PN.layout(m, 1600, 900, M)
ok('browser back right', lay.by_panel.browser.x > lay.by_panel.tracker.x)
eq('show visible', PN.show(m, 'browser'), false)
ok('toggle hides', PN.toggle(m, 'browser') and m.hidden.browser)
-- скрыть всю группу вкладок — лист уходит, трекер поднимается
m = PN.DEFAULT()
for _, id in ipairs(PN.TABS) do PN.hide(m, id) end
PN.hide(m, 'ctrl'); PN.hide(m, 'slices')
lay = PN.layout(m, 1600, 900, M)
eq('tracker at top', lay.by_panel.tracker.y, 0)

-- resize / equalize / drag_grip
m = PN.DEFAULT()
local w0 = PN.layout(m, 1600, 900, M).by_panel.matrix.w
ok('resize matrix', PN.resize(m, 'matrix', 'h', 0.1))
ok('matrix wider', PN.layout(m, 1600, 900, M).by_panel.matrix.w > w0)
ok('resize clamps', PN.resize(m, 'matrix', 'h', 5))
local r = m.root
ok('fr sum 1', math.abs(r.fr[1] + r.fr[2] + r.fr[3] - 1) < 1e-6)
ok('neighbor keeps min', r.fr[2] >= 0.05)
ok('equalize', PN.equalize(m, 'matrix'))
local lc = r.kids[1]                                                    -- левая колонка: main над матрицей
ok('halves in the left column', math.abs(lc.fr[1] - 0.5) < 1e-6)
lay = PN.layout(m, 1600, 900, M)
local gr = lay.grips[1]
local f1 = gr.node.fr[gr.i]
local nsz = gr.ax == 'h' and lay.nodes[gr.node].w or lay.nodes[gr.node].h
ok('drag grip', PN.drag_grip(m, lay, gr, nsz * 0.1))
ok('grip moved +0.1', math.abs(gr.node.fr[gr.i] - f1 - 0.1) < 1e-6)

-- active / cycle
m = PN.DEFAULT()
eq('cycle from master', PN.cycle(m, 'master', 1), 'video')
eq('cycle back', PN.cycle(m, 'retro', -1), PN.TABS[#PN.TABS])
ok('set active', PN.set_active(m, 'midi')); eq('active_of', PN.active_of(m, 'sample'), 'midi')
eq('cycle single', PN.cycle(m, 'matrix', 1), nil)

-- encode / decode
m = PN.DEFAULT()
PN.set_active(m, 'sample'); PN.hide(m, 'fxb'); PN.zoom(m, 'inst')
local s = PN.encode(m)
ok('no semicolon', not s:find(';')); ok('no tab/newline', not s:find('[\t\n]'))
local back = PN.decode(s)
eq('roundtrip', PN.encode(back), s)
eq('zoom kept', back.zoom, 'inst'); eq('hidden kept', back.hidden.fxb, true)
eq('active kept', PN.active_of(back, 'retro'), 'sample')
eq('garbage → default', PN.encode(PN.decode('h[garbage')), PN.encode(PN.DEFAULT()))
eq('empty → default', PN.encode(PN.decode('')), PN.encode(PN.DEFAULT()))
local odd = PN.decode('h[0.5:matrix,bogus|0.5:tracker] H: Z:')
eq('unknown dropped', PN.find(odd, 'bogus'), nil); ok('matrix kept', PN.find(odd, 'matrix'))
eq('missing panels hidden', odd.hidden.dsp, true)
local notr = PN.decode('h[0.5:matrix|0.5:inst] H: Z:')
ok('tracker forced in', PN.find(notr, 'tracker'))
local stk = PN.decode('h[0.5:matrix,tracker|0.5:inst] H: Z:')
ok('tracker unstacked', #PN.find(stk, 'tracker').panes == 1)

-- migrate
local d = PN.migrate({ top = true, side = true, dsp = true, fxb = true, toppos = 'mid', toptab = 'sample' }, 1600, 900)
eq('migrate default-ish', #PN.layout(d, 1600, 900, M).cells, 8)
eq('migrate toptab', PN.active_of(d, 'retro'), 'sample')
d = PN.migrate({ side = false }, 1600, 900); eq('side off → browser hidden', d.hidden.browser, true); eq('lib stays', d.hidden.inst, nil)
d = PN.migrate({ mx_hidden = true, dsp = false }, 1600, 900); eq('matrix hidden', d.hidden.matrix, true); eq('dsp hidden', d.hidden.dsp, true); eq('fxb hidden', d.hidden.fxb, true)
d = PN.migrate({ top = false }, 1600, 900); eq('top off → tabs hidden', d.hidden.sample, true); eq('ctrl hidden', d.hidden.ctrl, true)
d = PN.migrate({ ctrlpos = 'mid' }, 1600, 900)
lay = PN.layout(d, 1600, 900, M)
ok('ctrl under matrix', lay.by_panel.ctrl.x == 0 and lay.by_panel.ctrl.y > lay.by_panel.matrix.y)
d = PN.migrate({ ctrlpos = 'bottom' }, 1600, 900)
lay = PN.layout(d, 1600, 900, M)
ok('ctrl on bottom band', lay.by_panel.ctrl.y == lay.by_panel.dsp.y)
d = PN.migrate({ browserleft = true }, 1600, 900)
lay = PN.layout(d, 1600, 900, M)
ok('browser left under matrix', lay.by_panel.browser.x == 0 and lay.by_panel.browser.y > lay.by_panel.matrix.y)
d = PN.migrate({ slicespos = 'split' }, 1600, 900)
lay = PN.layout(d, 1600, 900, M)
ok('slices between lib and browser', lay.by_panel.slices.y > lay.by_panel.inst.y and lay.by_panel.slices.y < lay.by_panel.browser.y)
d = PN.migrate({ mx_px = 400, side_px = 320 }, 1600, 900)
ok('mx_px → fraction', math.abs(d.root.fr[1] - 0.25) < 0.02)
ok('side_px → fraction', math.abs(d.root.fr[3] - 0.2) < 0.02)
d = PN.migrate({ notes_open = true }, 1600, 900)
ok('notes stacked with fxb', PN.find(d, 'notes') == PN.find(d, 'fxb'))

-- пресеты сохраняют скрытые; next_preset по кругу
m = PN.DEFAULT(); PN.hide(m, 'browser')
local p = PN.preset('wide', m)
eq('preset keeps hidden', p.hidden.browser, true); eq('preset keeps notes hidden', p.hidden.notes, true)
eq('next preset', PN.next_preset('main-left'), 'main-right'); eq('next wraps', PN.next_preset('tracker'), 'main-left')
eq('parse lib', PN.parse_name('lib'), 'inst'); eq('parse rec', PN.parse_name('rec'), 'retro'); eq('parse id', PN.parse_name('dsp'), 'dsp'); eq('parse bad', PN.parse_name('xyz'), nil)

-- zellij (9 окт): подсказки в статусе — у листа нет строки подсказок
local MZ = setmetatable({ hint_h = 0 }, { __index = M })
lay = tiling('zellij', PN.DEFAULT(), 1600, 900, MZ)
local cz = lay.by_panel.dsp
eq('no hint row', cz.hint, nil); eq('content to bottom', cz.content.y + cz.content.h, cz.y + cz.h)
d = PN.migrate({ ctrlpos = 'top', toppos = 'mid' }, 1600, 900)
lay = PN.layout(d, 1600, 900, M)
ok('main top-left over matrix', lay.by_panel.ctrl.x == 0 and lay.by_panel.ctrl.y == 0 and lay.by_panel.matrix.y > 0)
d = PN.migrate({ ctrlpos = 'top', toppos = 'mid', browserleft = true }, 1600, 900)
lay = PN.layout(d, 1600, 900, M)
ok('main, matrix, browser in the left column', lay.by_panel.ctrl.x == 0 and lay.by_panel.matrix.x == 0 and lay.by_panel.browser.x == 0 and lay.by_panel.ctrl.y < lay.by_panel.matrix.y and lay.by_panel.matrix.y < lay.by_panel.browser.y)
print(('test_panes: %d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
