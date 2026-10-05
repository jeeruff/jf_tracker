-- test_keys_ru.lua — русская раскладка (5 окт): 'u'-префикс REAPER, подписи клавиш
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local K = dofile(DIR .. '/jf_tracker_keys.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
local U = 0x75000000
eq('р (u-prefixed) -> h', K.translate(U + utf8.codepoint('р')), ('h'):byte())
eq('layout marked russian', K.ru, true)
eq('label q -> й', K.label('q'), 'й')
eq('Ж -> :', K.translate(U + utf8.codepoint('Ж')), (':'):byte())
eq('plain codepoint works too', K.translate(utf8.codepoint('о')), ('j'):byte())
eq('latin letter keeps itself', K.translate(('k'):byte()), ('k'):byte())
eq('latin letter -> layout latin', K.ru, false)
eq('label q -> q', K.label('q'), 'q')
eq('arrow untouched', K.translate(K.down), K.down)
eq('en dash (u-prefixed, not cyrillic) untouched', K.translate(1962942483), 1962942483)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
