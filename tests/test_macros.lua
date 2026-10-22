-- test_macros.lua (22 окт): макро-параметры — фейдерами слева, в конец списка, секции не съезжают
reaper = setmetatable({}, { __index = function() return function() return nil end end })
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
package.path = DIR .. '/?.lua;' .. package.path
local M = dofile(DIR .. '/jf_tracker_model.lua')
local n, bad = 0, 0
local function eq(a, b, w) n = n + 1; if a ~= b then bad = bad + 1; print(('FAIL %s: %s ~= %s'):format(w, tostring(a), tostring(b))) end end
eq(M.is_macro_name('Macro 1'), true, 'Macro 1'); eq(M.is_macro_name('macro8'), true, 'macro8')
eq(M.is_macro_name('M3'), true, 'M3'); eq(M.is_macro_name('Macro Depth'), false, 'Macro Depth is not a macro')
eq(M.is_macro_name('Mix'), false, 'Mix')
eq(M.is_macro_name('M1: -'), true, 'Surge M1: -'); eq(M.is_macro_name('M1 Filter'), false, 'M1 Filter is not')
local e = { name = 'Vital', params = { { name = 'Macro 1' }, { name = 'Cutoff' }, { name = 'Macro 2' }, { name = 'Reso' } }, heads = { [2] = 'FILTER' } }
M.macroize({ e })
eq(e.nmacro, 2, 'two macros'); eq(e.params[1].name, 'Cutoff', 'normal params first'); eq(e.params[3].mfader, true, 'macros at the end, marked')
eq(e.heads[1], 'FILTER', 'head moved with its param')
local one = { params = { { name = 'Macro 1' }, { name = 'x' } } }
M.macroize({ one }); eq(one.nmacro, nil, 'one macro - not a bank')
local kit = { kit = true, params = { { name = 'Macro 1' }, { name = 'Macro 2' } } }
M.macroize({ kit }); eq(kit.nmacro, nil, 'kits keep their own macros')
-- 22 окт: имя макроса из плагина
eq(M.macro_label('M1: Brightness'), 'Brightness', 'surge named macro')
eq(M.macro_label('M3: -'), nil, 'surge unnamed macro')
eq(M.macro_label('M2:   '), nil, 'empty name')
eq(M.macro_label('Macro 4'), nil, 'generic Macro N - no name')
eq(M.macro_label('Macro 5: Drive'), 'Drive', 'Macro N: name')
eq(M.macro_label('Wobble'), 'Wobble', 'a plain name stays')
print(('%d checks, %d failed'):format(n, bad)); os.exit(bad == 0 and 0 or 1)
