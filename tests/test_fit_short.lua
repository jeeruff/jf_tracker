-- test_fit_short.lua — D.fit_short: имена эффектов согласными в тесноте
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/') or '.'
gfx = { measurestr = function(s) return utf8.len(s) * 8, 10 end, setfont = function() end }
reaper = setmetatable({}, { __index = function() return function() return 0 end end })
local D = dofile(DIR .. '/jf_tracker_draw.lua')
local n, bad = 0, 0
local function eq(a, b, m) n = n + 1; if a ~= b then bad = bad + 1; print('FAIL ' .. m .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end end
eq(D.fit_short('ReaVerbate', 40), 'RVrbt', 'vowels dropped, first kept')
eq(D.fit_short('Container', 40), 'Cntnr', 'container')
eq(D.fit_short('ReaComp (Cockos)', 56), 'ReaComp', 'vendor dropped first')
eq(D.fit_short('ReaComp (Cockos)', 40), 'RCmp', 'then consonants')
eq(D.fit_short('Компрессор', 40), 'Кмпрс', 'cyrillic vowels')
eq(D.fit_short('Air4', 40), 'Air4', 'fits - untouched')
eq(D.fit_short('Strawberry', 24), 'Str', 'still long - cut')
-- 20 окт: подписи меню — без заглавных, буква клавиши в слове
eq(D.hydra_text('Queue after REAPER RS5K'), 'queue after REAPER RS5K', 'menu: caps off, acronyms kept')
eq(D.hydra_mark('jump here now', 'j'), 1, 'menu: key at word start')
eq(D.hydra_mark('back: previous pattern', 'p'), 7, 'menu: word start beats inside')
eq(D.hydra_mark('chain: type', 'C'), 1, 'menu: upper key - any case')
eq(D.hydra_mark('undo / redo', 'z'), nil, 'menu: no such letter')
print(('%d checks, %d failed'):format(n, bad))
if bad > 0 then os.exit(1) end
