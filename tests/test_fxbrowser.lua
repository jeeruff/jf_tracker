-- test_fxbrowser.lua — папки, группы, избранное браузера эффектов: lua tests/test_fxbrowser.lua
package.path = './?.lua;' .. package.path
gfx = { mouse_x = 0, mouse_y = 0 }
local FB = dofile('jf_tracker_fxbrowser.lua')
local n, bad = 0, 0
local function eq(name, got, want)
  n = n + 1
  if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end
FB.list = {
  { label = 'VST3: Pro-Q 4 (FabFilter)', data = '/Library/Audio/Plug-Ins/VST3/FabFilter Pro-Q 4.vst3<123' },
  { label = 'VST: ADT (airwindows)', data = '/Library/Audio/Plug-Ins/VST/ADT.vst' },
  { label = 'JS: jf_rec', data = 'jf_rec.jsfx' },
  { label = 'AU: Thing (Some Dev)', data = 'Some Dev: Thing' },
}
eq('key strips path and uid, spaces to _', FB.fxkey(FB.list[1]), 'FabFilter_Pro-Q_4.vst3')
eq('kind vst3', FB.kind(FB.list[1]), 'VST3')
eq('kind js', FB.kind(FB.list[3]), 'JS')
FB.set_tags({ ['ADT.vst'] = 'Delay|Modulation' }, { ['ADT.vst'] = 'airwindows' }, { ['FabFilter_Pro-Q_4.vst3'] = true })
eq('dev from tags', FB.dev(FB.list[2]), 'airwindows')
eq('dev from label', FB.dev(FB.list[4]), 'Some Dev')
eq('native favourite', FB.is_fav(FB.list[1]), true)

FB.folder = 'all'; eq('all lists everything', #FB.results(), 4)
FB.folder = 'fav'; eq('fav: native only', #FB.results(), 1)
FB.toggle_fav(FB.list[3]); eq('fav: + own', #FB.results(), 2)
FB.toggle_fav(FB.list[3]); eq('fav: own removed', #FB.results(), 1)

FB.folder = 'type'
local res = FB.results()
local hdrs = 0
for _, r in ipairs(res) do if r.hdr then hdrs = hdrs + 1 end end
eq('type: one header per kind', hdrs, 4)
eq('type: first row is a header', res[1].hdr ~= nil, true)
FB.cur = 1; FB.skip_hdr(1); eq('cursor skips header', res[FB.cur].hdr, nil)
eq('selected is an fx', FB.selected() ~= nil, true)

FB.folder = 'cat'
res = FB.results()
eq('cat: known category first, ? last', res[1].hdr, 'Delay')
eq('cat: unknown grouped last', res[#res - 3].hdr or res[#res - 1].hdr or '?', '?')

FB.folder = 'rec'; eq('rec empty', #FB.results(), 0)
FB.push_recent(FB.list[2]); FB.push_recent(FB.list[4]); FB.push_recent(FB.list[2])
res = FB.results()
eq('rec: newest first, no duplicates', #res, 2)
eq('rec order', res[1].it.label, 'VST: ADT (airwindows)')

FB.folder = 'all'; FB.query = 'pro'
eq('search inside folder', #FB.results(), 1)

-- 21 окт: дерево (широкая панель): узлы типов / категорий / разработчиков, фильтр по узлу
FB.query = ''; FB.tree_on = true
local tr = FB.tree()
local found = {}
for _, r in ipairs(tr) do if r.node then found[r.node.k .. ':' .. tostring(r.node.v)] = r.n end end
eq('tree: all', found['all:nil'], 4)
eq('tree: VST3 type', found['type:VST3'], 1)
eq('tree: category Delay', found['cat:Delay'], 1)
eq('tree: developer airwindows', found['dev:airwindows'], 1)
FB.node = { k = 'type', v = 'JS' }; eq('tree filter JS', #FB.results(), 1)
FB.node = { k = 'cat', v = 'Modulation' }; eq('tree filter category (second tag)', #FB.results(), 1)
FB.node = { k = 'all' }; FB.tree_on = false
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
