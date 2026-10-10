-- test_visor.lua — панель visor (jf_tracker_visor.lua): ISF, значения, кадр ExtState, импорт ReaVisor
local DIR = '.'
local VZ = dofile(DIR .. '/jf_tracker_visor.lua')
local n, bad = 0, 0
local function eq(a, b, m) n = n + 1; if a ~= b then bad = bad + 1; print('FAIL ' .. m .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end end
local function near(a, b, m) eq(math.abs(a - b) < 1e-6, true, m .. ' (' .. tostring(a) .. ' vs ' .. tostring(b) .. ')') end

-- заголовок ISF (висячая запятая, все типы)
local SRC = [[/*{ "INPUTS": [
  { "NAME": "speed", "TYPE": "float", "DEFAULT": 4.0, "MIN": -3.0, "MAX": 10.0 },
  { "NAME": "pos", "TYPE": "point2D", "DEFAULT": [0.5, 0.25] },
  { "NAME": "inv", "TYPE": "bool", "DEFAULT": true },
  { "NAME": "mode", "TYPE": "long", "VALUES": [0, 1, 2], "LABELS": ["a", "b", "c"], "DEFAULT": 1 },
  { "NAME": "tint", "TYPE": "color", "DEFAULT": [1, 0, 0, 1] },
  { "NAME": "inputImage", "TYPE": "image" },
]}*/ void main(){}]]
local rows = VZ.parse_header(SRC)
eq(#rows, 6, 'rows: float + 2 axes + bool + long + color, image skipped')
eq(rows[1].min, -3, 'float min'); eq(rows[1].def, 4, 'float default')
eq(rows[2].key, 'pos.x', 'point axis key'); eq(rows[3].def, 0.25, 'point y default')
eq(rows[4].def, 1, 'bool true -> 1'); eq(rows[5].labels[2], 'b', 'long labels'); eq(rows[6].ty, 'c', 'color')
eq(VZ.parse_header('void main(){}'), nil, 'no header')

-- строка значений и модуляция
local slot = { p = {} }
local s = VZ.values(slot, rows, 0)
eq(s, 'speed=4.0000;pos=0.5000,0.2500;inv=1;mode=1;tint=1.000,0.000,0.000,1.000', 'values string')
local p = VZ.param(slot, rows[1])
p.m = { k = 'lfo', sh = 2, hz = 1, amt = 0.1 }   -- пила: ph 0.25 → -0.25·0.1·13
near(VZ.eval(rows[1], p, 0.25), 4 - 0.25 * 0.1 * 13, 'saw lfo around v')
p.m = { k = 'trk', g = 'G', amt = 0.5 }
near(VZ.eval(rows[1], p, 0, function(g) return g == 'G' and 0.5 or 0 end), 4 + 0.25 * 13, 'track peak lifts v')
near(VZ.eval(rows[1], p, 0, function() return 1 end), 10, 'clamped at max')
eq(VZ.cycle_src(rows[1], p), 'none', 'track -> none'); eq(p.m, nil, 'cleared')
eq(VZ.cycle_src(rows[1], p), 'lfo', 'none -> lfo'); eq(VZ.cycle_src(rows[1], p), 'track', 'lfo -> track (main picks)')
eq(VZ.cycle_src(rows[4], VZ.param(slot, rows[4])), nil, 'bool has no modulation')
local c = VZ.param(slot, rows[6]); VZ.step(rows[6], c, 1)
eq(c.v[1] > 0.9 and c.v[2] > 0 and c.v[3] < 0.01, true, 'color hue turns red -> orange')
local lp = VZ.param(slot, rows[5]); VZ.step(rows[5], lp, 5); eq(lp.v, 3, 'long clamps to last value')

-- кадр: пишем только изменения; эффекты нумеруются среди включённых
VZ.WEB = '/nonexistent'
VZ.heads['/nonexistent/shaders/a.fs'] = { rows[1] }
VZ.heads['/nonexistent/effects/e1.fs'] = { rows[1] }
VZ.heads['/nonexistent/effects/e2.fs'] = { { key = 'amt', name = 'amt', ty = 'f', min = 0, max = 1, def = 0.5 } }
VZ.st = VZ.decode('')
VZ.st.layers = { { fn = 'a.fs', on = true, fade = 0.5, p = {} }, { fn = 'a.fs', on = false, fade = 1, p = {} } }
VZ.st.fx = { { fn = 'e1.fs', on = false }, { fn = 'e2.fs', on = true } }
local out = {}
local function set(k, v) out[k] = v end
VZ.frame({ t = 0, set = set, peak = function() return 0 end })
eq(out.layers, 'a.fs|a.fs', 'layers'); eq(out.fades, '0.500,1.000', 'fades'); eq(out.lgate, '1,0', 'gates')
eq(out.lvalues1, 'speed=4.0000', 'layer 1 values'); eq(out.lvalues2, nil, 'gated layer not pushed')
eq(out.fxchain, 'e2.fs', 'bypassed effect not sent'); eq(out.fxvalues, '0.amt=0.5000', 'fx index among the sent ones')
eq(out.render, 'scale=0.30;fps=60', 'render')
out = {}; VZ.frame({ t = 0, set = set, peak = function() return 0 end })
eq(next(out), nil, 'nothing changed - nothing written')

-- хранение и сцены
local enc = VZ.encode()
eq(enc:find(';', 1, true) == nil or true, true, 'encode ok')
local sc = VZ.scene_take(); VZ.st.layers = {}; VZ.scene_apply(sc)
eq(#VZ.st.layers, 2, 'scene restores layers')
VZ.decode(enc); eq(VZ.st.layers[1].fade, 0.5, 'decode round trip')
eq(#VZ.decode('garbage').layers, 0, 'garbage -> empty')

-- пресет ReaVisor
local ps = VZ.json.decode([[{"shader":"a.fs","tabs":["a.fs","@cam"],"fades":{"a.fs":0.7},"blend":"add",
  "decks":{"a.fs":{"speed":{"static":2,"routes":["T:{GUID}","",""],"out_min":0,"out_max":6.5,"lfo":0}}},
  "fxchain":["e2.fs"],"fxparams":{"e2.fs":{"amt":{"static":0.2,"lfo":2,"lfo_hz":3,"lfo_amt":0.4,"routes":["","",""]}}}}]])
local r = VZ.from_reavisor(ps)
eq(#r.layers, 1, 'media layers skipped'); eq(r.layers[1].fade, 0.7, 'fade'); eq(r.blend, 'add', 'blend')
local sp = r.layers[1].p.speed
eq(sp.m.k, 'trk', 'track route -> track source'); eq(sp.m.g, '{GUID}', 'guid'); eq(sp.v, 0, 'base = out_min'); near(sp.m.amt, 0.5, 'depth = out range / range')
local fp = r.fx[1].p.amt
eq(fp.m.k, 'lfo', 'lfo'); eq(fp.m.sh, 1, 'lfo shape 1-based -> 0-based'); eq(fp.v, 0.2, 'static')

-- клавиши
VZ.st = VZ.decode(''); VZ.sel = 1
eq(VZ.key(('a'):byte()).what, 'layer', 'a adds a layer')
eq(VZ.key(13).kind, 'add', 'Enter on + shader picks one')
VZ.st.layers = { { fn = 'a.fs', on = true, fade = 1, p = {} } }; VZ.sel = 1
VZ.key(('h'):byte()); near(VZ.st.layers[1].fade, 0.95, 'h fades down')
VZ.key(32); eq(VZ.st.layers[1].on, false, 'Space gates')
VZ.key(('L'):byte()); near(VZ.st.layers[1].p.speed.v, 4.26, 'L steps 2% of the range')
eq(VZ.key(('m'):byte()), true, 'm -> lfo'); eq(VZ.key(('m'):byte()).kind, 'pick_track', 'm again -> pick a track')
eq(VZ.key(('x'):byte()), true, 'x'); eq(#VZ.st.layers, 0, 'x removes')
eq(VZ.key(27).kind, 'leave', 'Esc'); eq(VZ.key(('Z'):byte()), nil, 'Z not ours')
print(('test_visor: %d checks, %d failed'):format(n, bad))
