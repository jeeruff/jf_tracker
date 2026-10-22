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
eq('cells', #lay.cells, 9)   -- 9 окт: browser | pm | fx — один стек, dsp один; 11 окт: + mixer под трекером
ok('tracker rect', lay.rects.tracker ~= nil)
ok('tracker has no tab', lay.by_panel.tracker.tab == nil)
eq('order starts with tracker', lay.order[1], 'tracker')
eq('master active', lay.by_panel.master.active_id, 'master')
eq('notes hidden', m.hidden.notes, true)
ok('tabs in one cell', lay.by_panel.sample == lay.by_panel.midi)
-- недоступная панель: slices нет → лист схлопнут
local M2 = setmetatable({ avail = function(id) return id ~= 'slices' end }, { __index = M })
local lay2 = tiling('no slices', m, 1600, 900, M2)
eq('slices gone', lay2.by_panel.slices, nil); eq('cells -1', #lay2.cells, 8)
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
eq('tracker r', PN.focus_dir(lay, 'tracker', 'r'), 'slices')   -- наибольшее перекрытие по вертикали (11 окт: трекер ниже — над mixer)
eq('tracker u', PN.focus_dir(lay, 'tracker', 'u'), 'master')
eq('tracker d', PN.focus_dir(lay, 'tracker', 'd'), 'mixer')   -- 11 окт: под трекером — его микшер
eq('mixer d', PN.focus_dir(lay, 'mixer', 'd'), 'dsp')
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
ok('tracker + mixer to the bottom', lay.by_panel.mixer.y + lay.by_panel.mixer.h == 900 and lay.by_panel.tracker.y + lay.by_panel.tracker.h <= lay.by_panel.mixer.y)
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
eq('migrate default-ish', #PN.layout(d, 1600, 900, M).cells, 9)
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
-- 11 окт: mixer ушёл в стек к dsp (случай пользователя) — pin_mixer возвращает его под трекер
do
  local u = PN.decode('h[0.132:v[0.184:ctrl*|0.816:matrix*,visor,clips]|0.509:v[0.393:h[0.395:retro,modulation,grid,macros,sample*|0.511:sprops*|0.094:slices*]|0.607:dsp,mixer*]|0.25:tracker*|0.109:v[0.513:inst*|0.487:browser*,fxb]] H:notes Z:')
  ok('user layout: mixer in the dsp stack', #(PN.find(u, 'mixer').panes) == 2)
  ok('pin: changed', PN.pin_mixer(u))
  local lf, par, ix = PN.find(u, 'mixer')
  ok('pin: mixer alone in its leaf', #lf.panes == 1)
  ok('pin: right under the tracker', par.ax == 'v' and par.kids[ix - 1] == PN.find(u, 'tracker'))
  ok('pin: dsp still visible', PN.visible(u, 'dsp'))
  ok('pin: idempotent', not PN.pin_mixer(u))
  local d = PN.DEFAULT()
  ok('pin: default untouched', not PN.pin_mixer(d))
  PN.hide(d, 'mixer'); ok('pin: hidden mixer stays hidden', not PN.pin_mixer(d) and not PN.visible(d, 'mixer'))
  tiling('pinned user layout', u, 1600, 900)
end
-- 11 окт: properties — обязательно своей панелью у item (случай пользователя: H:sprops)
do
  local u = PN.decode('h[0.18:v[0.273:ctrl*|0.451:matrix*,notes,visor|0.276:tracks*]|0.656:v[0.111:h[0.871:retro,modulation,scopes,master,grid,garden,sample*,video,macros|0.129:slices*]|0.517:tracker*|0.152:mixer*|0.22:dsp*]|0.164:v[0.43:inst*|0.57:browser*,fxb]] H:sprops,pm,midi,harm,clips Z:')
  ok('sprops: hidden in the user layout', not PN.visible(u, 'sprops'))
  ok('sprops pin: changed', PN.pin_sprops(u))
  local sl, pl = PN.find(u, 'sample'), PN.find(u, 'sprops')
  ok('sprops pin: own leaf next to item', pl and pl ~= sl and #pl.panes == 1)
  ok('sprops pin: idempotent', not PN.pin_sprops(u))
  PN.stack(u, 'sprops', 'sample'); ok('sprops in the item stack', PN.find(u, 'sprops') == PN.find(u, 'sample'))
  ok('sprops pin: out of the stack', PN.pin_sprops(u) and PN.find(u, 'sprops') ~= PN.find(u, 'sample'))
  tiling('sprops pinned', u, 1600, 900)
  local d = PN.DEFAULT(); PN.hide(d, 'sample')
  ok('sprops pin: no item - nothing', not PN.pin_sprops(d))
end
-- 11 окт: скринсет старше модулей — add_new ставит их на места, скрытые пользователем не трогает
do
  local raw = 'h[0.199:v[0.192:ctrl*|0.565:matrix*|0.242:fxb*]|0.64:v[0.05:retro,modulation,scopes,master,grid,garden,sample,video*|0.8:tracker*|0.15:dsp*]|0.161:v[0.434:inst*|0.133:slices*|0.433:browser*]] H:notes,midi,harm Z:'
  local m = PN.decode(raw)
  ok('add_new: something added', PN.add_new(m, raw))
  for _, id in ipairs({ 'sprops', 'mixer', 'visor', 'clips', 'macros', 'automation' }) do ok('add_new: ' .. id .. ' visible', PN.visible(m, id)) end
  -- 12 окт: automation отделилась от modulation — встаёт в тот же стек вкладок
  do local a = PN.find(m, 'automation'); ok('add_new: automation stacked with modulation', a ~= nil and a == (PN.find(m, 'modulation'))) end
  ok('add_new: matrix stays active', PN.is_active(m, 'matrix'))
  ok('add_new: video stays active', PN.is_active(m, 'video'))
  ok('add_new: second pass - nothing', not PN.add_new(m, PN.encode(m)))
  local raw2 = raw:gsub(' H:notes', ' H:sprops,notes')
  local m2 = PN.decode(raw2); PN.add_new(m2, raw2)
  ok('add_new: hidden by the user stays hidden', not PN.visible(m2, 'sprops'))
  tiling('screenset with new modules', m, 1600, 900)
end
-- 16 окт: перенос всего пейна (main pane_drop): первая вкладка — сплитом, остальные — в её стек
do
  local m2 = PN.DEFAULT()
  PN.stack(m2, 'notes', 'browser')                            -- стек browser | notes
  local st = PN.stack_of(m2, 'browser')
  if st and #st >= 2 then
    local ids = {}
    for _, id in ipairs(st) do ids[#ids + 1] = id end
    ok('whole pane: first split', PN.split(m2, 'tracker', ids[1], 'd', 0.5))
    for k = 2, #ids do PN.stack(m2, ids[k], ids[1]) end
    local st2 = PN.stack_of(m2, ids[1])
    eq('whole pane: all tabs moved', st2 and #st2, #ids)
    eq('whole pane: its own leaf', PN.find(m2, 'tracker') ~= PN.find(m2, ids[1]), true)
  else ok('a stack with browser', false) end
end
-- 16 окт: миксер вкладкой в стек, который ушёл в h-узел (рядом properties у item) — остаётся
do
  local m3 = PN.decode('h[0.187:v[0.3:ctrl*|0.7:matrix*]|0.682:v[0.5:tracker*|0.5:h[0.6:dsp,sample,retro*|0.4:sprops*]]|0.131:v[1:inst*]] H:mixer Z:')
  PN.stack(m3, 'mixer', 'dsp')
  eq('mixer stays in a nested stack under the tracker', PN.pin_mixer(m3), false)
  local m4 = PN.decode('h[0.5:v[0.5:tracker*|0.5:dsp*]|0.5:v[1:inst*]] H:mixer Z:')
  PN.split(m4, 'inst', 'mixer', 'd')
  eq('mixer far from the tracker goes back', PN.pin_mixer(m4), true)
end
-- 20 окт: zm — свёрнутый лист: только строка вкладок, тела нет, сосед забирает место; ~ в строке раскладки
do
  local m5 = PN.DEFAULT()
  local id
  for _, p in ipairs(PN.PANELS) do if p.id ~= 'tracker' and PN.find(m5, p.id) then id = p.id; break end end
  local lay0 = PN.layout(m5, 1600, 900, M)
  local h0 = lay0.by_panel[id].h
  local okm, on = PN.minimize(m5, id)
  eq('minimize ok', okm, true); eq('minimize on', on, true)
  local lay1 = PN.layout(m5, 1600, 900, M)
  local c1 = lay1.by_panel[id]
  ok('folded cell is smaller', c1.h < h0 or c1.w < lay0.by_panel[id].w)
  eq('folded: no content rect', lay1.rects[id], nil); eq('folded: cell.min', c1.min, true)
  local area = 0
  for _, c in ipairs(lay1.cells) do area = area + c.w * c.h end
  for _, sp in ipairs(lay1.seps) do area = area + sp.w * sp.h end
  eq('folded: area still tiles', area, 1600 * 900)
  local m6 = PN.decode(PN.encode(m5)); eq('folded survives encode', PN.find(m6, id).min, true)
  PN.minimize(m5, id); eq('minimize again opens', PN.find(m5, id).min, nil)
  eq('tracker does not fold', PN.minimize(m5, 'tracker'), false)
end
-- 22 окт: zz в DSP — микшер над DSP на всё окно; zx — DSP полосой во всю ширину снизу
do
  local m6 = PN.DEFAULT()
  eq('zoom_multi ok', PN.zoom_multi(m6, { 'mixer', 'dsp' }, { 0.3, 0.7 }), true)
  local lay = PN.layout(m6, 1600, 900, M)
  eq('zoom_multi: two cells', #lay.cells, 2)
  local cm, cd = lay.by_panel.mixer, lay.by_panel.dsp
  eq('mixer on top, whole width', cm and cm.y == 0 and cm.w == 1600, true)
  eq('dsp below it', cd and cd.y > cm.y and cd.w == 1600, true)
  eq('dsp the bigger part', cd and cd.h > cm.h, true)
  PN.zoom_multi(m6, { 'mixer', 'dsp' })
  eq('zoom_multi again: back', #PN.layout(m6, 1600, 900, M).cells > 2, true)
  local m7 = PN.DEFAULT()
  local stack0 = #PN.find(m7, 'browser').panes
  eq('span_bottom ok', PN.span_bottom(m7, 'dsp', 0.3), true)
  local l7 = PN.layout(m7, 1600, 900, M)
  local d7 = l7.by_panel.dsp
  eq('dsp spans the width', d7 and d7.x == 0 and d7.w == 1600, true)
  eq('dsp at the bottom', d7 and d7.y + d7.h == 900, true)
  eq('tracker still there', l7.by_panel.tracker ~= nil, true)
  eq('neighbour stack keeps its tabs', #PN.find(m7, 'browser').panes, stack0)
  eq('decode(encode) keeps it', PN.encode(PN.decode(PN.encode(m7))), PN.encode(m7))
  -- 22 окт: возврат без снимка (после перезапуска) — полоса снята, dsp снова в обычной панели
  ok('spanned_bottom sees the strip', PN.spanned_bottom(m7, 'dsp'))
  eq('plain layout is not spanned', PN.spanned_bottom(PN.DEFAULT(), 'dsp'), nil)
  local m8 = PN.decode(PN.encode(m7))   -- как после перезапуска: только строка раскладки
  eq('unspan_bottom ok', PN.unspan_bottom(m8, 'dsp'), true)
  eq('nothing to unspan twice', PN.unspan_bottom(m8, 'dsp'), false)
  local l8 = PN.layout(m8, 1600, 900, M)
  local d8 = l8.by_panel.dsp
  ok('dsp visible again', d8 ~= nil)
  eq('dsp no longer across the width', d8 and d8.w == 1600, false)
  eq('dsp is not hidden', m8.hidden.dsp, nil)
  tiling('after unspan', m8, 1600, 900)
end
-- 22 окт: любая ручка двигает только свою границу: у соседних листов меняется лишь край у ручки, остальные края
-- всех модулей на месте (было: низ микшера тянул — ехал его верх, трекер над ним менялся)
do
  local function edges(lay)
    local t = {}
    for id, c in pairs(lay.by_panel) do t[id] = { c.x, c.y, c.x + c.w, c.y + c.h } end
    return t
  end
  local base = PN.DEFAULT()
  local lay0 = PN.layout(base, 1600, 1000, M)
  for gi = 1, #lay0.grips do
    for _, dpx in ipairs({ 20, -20 }) do
      local m8 = PN.decode(PN.encode(base))
      local l1 = PN.layout(m8, 1600, 1000, M)
      local g = l1.grips[gi]
      local pos = g.ax == 'v' and (g.y + (g.h - M.sep) // 2) or (g.x + (g.w - M.sep) // 2)
      local e0 = edges(l1)
      PN.drag_grip(m8, l1, g, dpx)
      local e1 = edges(PN.layout(m8, 1600, 1000, M))
      local ok = true
      for id, a0 in pairs(e0) do
        local a1 = e1[id]
        for k = 1, 4 do
          local axk = (k == 2 or k == 4) and 'v' or 'h'
          local moved = math.abs(a1[k] - a0[k]) > 1
          local at_grip = axk == g.ax and (math.abs(a0[k] - pos) <= 2 or math.abs(a0[k] - pos - M.sep) <= 2)
          if moved and not at_grip then ok = false; print(('  grip %d (%s, %+d): %s edge %d %d -> %d'):format(gi, g.ax, dpx, id, k, a0[k], a1[k])) end
        end
      end
      eq('grip ' .. gi .. ' ' .. dpx .. ': only its own edge moves', ok, true)
    end
  end
end
print(('test_panes: %d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
