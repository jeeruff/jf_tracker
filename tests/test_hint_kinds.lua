-- test_hint_kinds.lua (22 окт): у каждой метки f (hint('вид', …)) есть прыжок в hint_go — иначе f + метка
-- молча ничего не делал (playthru слайсера, панель mod · auto, XY, снапшоты микшера)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local kinds, n, bad = {}, 0, 0
for _, f in ipairs({ 'jf_tracker.lua', 'jf_tracker_draw.lua', 'jf_tracker_matrix.lua', 'jf_tracker_slicer.lua', 'jf_tracker_macros.lua', 'jf_tracker_sampleprops.lua' }) do
  local h = io.open(DIR .. '/' .. f); if h then local s = h:read('a'); h:close(); for k in s:gmatch("hint%('([%w_]+)'") do kinds[k] = true end end
end
local h = io.open(DIR .. '/jf_tracker.lua'); local s = h:read('a'); h:close()
local body = s:match('local function hint_go%(t%)(.-)\n%-%- ── контекстное меню')
assert(body, 'hint_go not found')
local handled = {}
for k in body:gmatch("kind == '([%w_]+)'") do handled[k] = true end
local names = {}; for k in pairs(kinds) do names[#names + 1] = k end; table.sort(names)
for _, k in ipairs(names) do n = n + 1; if not handled[k] then bad = bad + 1; print('FAIL no jump for hint kind ' .. k) end end
print(('test_hint_kinds: %d kinds, %d without a jump'):format(n, bad)); os.exit(bad == 0 and 0 or 1)
