-- tests/test_actin.lua (12 ноя) — вход с контроллера через экшены: разбор, энкодеры, применение к слайдеру
local DIR = (debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.')
local AI = dofile(DIR .. '/jf_tracker_actin.lua')
local n, fail = 0, 0
local function ok(c, m) n = n + 1; if not c then fail = fail + 1; print('FAIL ' .. m) end end

-- разбор: строка на событие, мусор пропускается
local ev = AI.parse('value 0 127 64\nreform:scale 1 127 127\nbad\nhumanizer:amt -1 127 0.5\n')
ok(#ev == 3, 'parse count ' .. #ev)
ok(ev[1].target == 'value' and ev[1].mode == 0 and ev[1].res == 127 and ev[1].val == 64, 'parse abs')
ok(ev[2].target == 'reform:scale' and ev[2].mode == 1 and ev[2].val == 127, 'parse rel')
ok(ev[3].val == 0.5, 'parse float')
ok(#AI.parse('') == 0 and #AI.parse(nil) == 0, 'parse empty')

-- энкодеры
ok(AI.delta(1, 127) == -1 and AI.delta(1, 1) == 1 and AI.delta(1, 125) == -3, 'delta mode 1')
ok(AI.delta(2, 63) == -1 and AI.delta(2, 65) == 1 and AI.delta(2, 64) == 0, 'delta mode 2')
ok(AI.delta(3, 65) == -1 and AI.delta(3, 1) == 1, 'delta mode 3')
ok(AI.delta(0, 100) == 0, 'delta abs = 0')

-- слайдер: abs — доля диапазона с шагом, rel — шаг на щелчок, зажим
local v = 1
local sl = { min = 0.25, max = 4, step = 0.05, get = function() return v end, set = function(x) v = x end }
ok(AI.apply(sl, 0, 127, 127) and math.abs(v - 4) < 1e-9, 'abs max ' .. v)
ok(AI.apply(sl, 0, 127, 0) and math.abs(v - 0.25) < 1e-9, 'abs min ' .. v)
ok(AI.apply(sl, 0, 16383, 8192) and math.abs(v - 2.15) < 1e-9, '14-bit mid ' .. v)
ok(not AI.apply(sl, 0, 16383, 8192), 'same value - no change')
ok(AI.apply(sl, 1, 127, 2) and math.abs(v - 2.25) < 1e-9, 'rel +2 ' .. v)
ok(AI.apply(sl, 2, 127, 63) and math.abs(v - 2.2) < 1e-9, 'rel64 -1 ' .. v)
v = 4; ok(not AI.apply(sl, 1, 127, 1), 'rel at max clamps - no change')
-- OSC: режим -1, значение 0..1
local iv = 0
local isl = { min = -64, max = 64, step = 1, get = function() return iv end, set = function(x) iv = x end }
ok(AI.apply(isl, -1, 1, 0.75) and iv == 32, 'osc 0..1 → ' .. iv)
-- переключатель: abs — порог половины, rel — вверх вкл, вниз выкл
local t = false
local tg = { toggle = true, get = function() return t end, set = function(x) t = x end }
ok(AI.apply(tg, 0, 127, 127) and t == true, 'toggle on')
ok(not AI.apply(tg, 0, 127, 100), 'toggle stays on')
ok(AI.apply(tg, 1, 127, 127) and t == false, 'toggle rel down → off')

-- текст экшена: цель в строке, get_action_context
local s = AI.script(AI.ACTIONS[5])
ok(s:find('get_action_context', 1, true) and s:find("'reform:scale %d %d %s\\n'", 1, true), 'script text')
ok(#AI.ACTIONS >= 8, 'actions list')

-- reaper-kb.ini → подписи: SCR даёт id, KEY — комментарий REAPER
local kb = 'SCR 4 0 RSaa11 "Script: jf_tracker_reform_scale.lua" "jf_tracker/actions/jf_tracker_reform_scale.lua"\n' ..
  'SCR 4 0 RSbb22 "Script: jf_tracker_value.lua" "jf_tracker/actions/jf_tracker_value.lua"\n' ..
  'KEY 255 149 _RSaa11 0\t\t # Main : MIDI Chan 1 CC 21 : Script: jf_tracker_reform_scale.lua\n' ..
  'KEY 1 76 _RSbb22 0\t\t # Main : L : Script: jf_tracker_value.lua\n' ..
  'KEY 255 248 989 0\t\t # Main : Mousewheel : OVERRIDE DEFAULT : View: Scroll vertically\n'
local b = AI.bindings(kb)
ok(b.reform_scale == 'MIDI Chan 1 CC 21', 'binding midi ' .. tostring(b.reform_scale))
ok(b.value == 'L', 'binding key ' .. tostring(b.value))
ok(b.next == nil and next(AI.bindings('')) == nil, 'no binding')

print(('test_actin: %d checks, %d failed'):format(n, fail))
os.exit(fail == 0 and 0 or 1)
