-- tests/test_doc_keys.lua — справка F1: j k строкой-курсором, переход между разделами, o — браузер (17 окт)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local DOC = dofile(DIR .. '/jf_tracker_doc.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
DOC.secs = { { id = 'intro', title = 'a' }, { id = 'mixer', title = 'b' } }
DOC.sec, DOC.scroll, DOC.line, DOC.nlines, DOC.hits = 1, 0, 1, 3, {}
local j, k = ('j'):byte(), ('k'):byte()
DOC.key(j); eq('j: line 2', DOC.line, 2)
DOC.key(j); DOC.key(j); eq('j at the end: next section', DOC.sec, 2); eq('next section: line 1', DOC.line, 1)
DOC.key(k); eq('k at the top: previous section', DOC.sec, 1); eq('previous section: from the end', DOC.line, 1e9)
eq('o: browser', DOC.key(('o'):byte()), 'browser')
DOC.sec = 2; eq('anchor: section id', DOC.anchor(), 'mixer')
DOC.sec = 1; eq('anchor: intro has none', DOC.anchor(), nil)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
