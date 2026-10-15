-- jf_tracker_visor.lua — панель visor: шейдеры ReaVisor прямо из трекера (10 окт).
--
-- Картинку рисует страница ReaVisor в браузере (веб-интерфейс REAPER,
-- localhost:8080/isf/index.html, WebGL); трекер — её пульт вместо reavisor.lua.
-- Протокол — ExtState ISFVIZ (страница только читает его ~30 раз в секунду):
--   layers = «a.fs|b.fs», fades = «1.000,0.500», lgate = «1,0», blend =
--   normal|add, lvalues<i> = «имя=0.42;цвет=1,0,0,1;точка=0.5,0.5»,
--   fxchain = «x.fs|y.fs» (эффекты по порядку), fxvalues = «0.имя=0.3;…»
--   (индекс — среди включённых), mvalues — master.fs, render = «scale=0.30;fps=60».
--
-- Модель (VZ.st, хранится в проекте — ProjExtState jf_tracker/visor, JSON):
--   layers = { { fn, on, fade, p = { [ключ] = { v, m } } } }   до 8 слоёв-шейдеров
--   fx     = { { fn, on, p = … } }                              цепочка эффектов
--   master = { p = … }                                          master.fs
--   blend, follow (сцены идут за слотом под плейхедом), scenes = { [имя слота] = снимок }
-- Ключ параметра — имя входа ISF, у point2D — «имя.x» / «имя.y».
-- v — значение (число; у color — {r,g,b,a}); m — модуляция одного источника:
--   { k = 'lfo', sh = форма 0..6, hz, amt }  — качается вокруг v на amt диапазона
--   { k = 'trk', g = GUID трека, amt }       — пик трека поднимает v на amt диапазона
--
-- VZ.draw(L, U, x, y, w, h, focused, env, fit, hint) → hover
-- VZ.key(c) / VZ.click(hv) → действие { kind = … } | true (съели) | nil (не наше)
-- VZ.frame(env) — посчитать и отдать странице (env.set(key, val), env.peak(guid))
-- Чтение файлов — io.open (шейдеры лежат в reaper_www_root/isf); reaper.* —
-- только в main. Тест — tests/test_visor.lua.

local VZ = {}
VZ.SECTION = 'ISFVIZ'
VZ.MAXL = 8
VZ.sel = 1          -- строка левого списка (слои, эффекты, master)
VZ.psel = 1         -- строка параметра справа
VZ.pscroll = 0
VZ.gal = false      -- 11 окт: клавиши в сетке пресетов (i)
VZ.gsel = 1         -- карточка пресета в сетке
VZ.gcols = 1        -- колонок в сетке (из отрисовки — для j k)
VZ.pnames = {}      -- имена пресетов ReaVisor (main кладёт из ISFVIZ/preset_names)
VZ.heads = {}       -- путь → разобранные входы (кэш, false — не читается)
VZ.cache = {}       -- последние отданные значения ExtState (пишем только изменения)
VZ.dirty = false    -- модель изменилась — main сохранит в проект

-- 11 окт: матрица модуляций — общие источники: 4 LFO (своя форма и частота), пики треков, макросы
function VZ.default_lfos() return { { sh = 0, hz = 0.5 }, { sh = 1, hz = 0.25 }, { sh = 2, hz = 1 }, { sh = 3, hz = 2 } } end
VZ.mxv = false      -- вид матрицы вместо параметров (M)
VZ.mr, VZ.mc = 1, 1 -- курсор матрицы: строка источника, колонка параметра (0 — подпись источника)
VZ.mcs = 0          -- прокрутка колонок
VZ.env_macro = nil  -- значение макроса k (0..1) — main кладёт в кадре
local function new_state()
  return { layers = {}, fx = {}, master = { p = {} }, blend = 'normal', follow = true, scenes = {},
           scale = 0.3, fps = 60, lfos = VZ.default_lfos() }
end
VZ.st = new_state()

-- ── JSON (заголовок ISF, хранение, пресеты ReaVisor) ─────────────────────
local json = {}
VZ.json = json
function json.encode(v)
  local t = type(v)
  if t == 'nil' then return 'null'
  elseif t == 'boolean' then return v and 'true' or 'false'
  elseif t == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then return '0' end
    return string.format('%.6g', v)
  elseif t == 'string' then
    return '"' .. v:gsub('[%c"\\]', function(c) return string.format('\\u%04x', c:byte()) end) .. '"'
  elseif t == 'table' then
    local parts = {}
    if #v > 0 or next(v) == nil then
      for _, item in ipairs(v) do parts[#parts + 1] = json.encode(item) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local item = v[k]; if item == nil then item = v[tonumber(k)] end
      parts[#parts + 1] = json.encode(k) .. ':' .. json.encode(item)
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return 'null'
end

do
  local value
  local function ws(s, i) local _, j = s:find('^[ \t\r\n]*', i); return j + 1 end
  local ESC = { n = '\n', t = '\t', r = '\r', b = '\b', f = '\f' }
  local function str(s, i)
    local buf, j = {}, i + 1
    while j <= #s do
      local c = s:sub(j, j)
      if c == '"' then return table.concat(buf), j + 1 end
      if c == '\\' then
        local e = s:sub(j + 1, j + 1)
        if e == 'u' then buf[#buf + 1] = utf8.char(tonumber(s:sub(j + 2, j + 5), 16) or 32); j = j + 6
        else buf[#buf + 1] = ESC[e] or e; j = j + 2 end
      else buf[#buf + 1] = c; j = j + 1 end
    end
    error('unterminated string')
  end
  value = function(s, i)
    i = ws(s, i)
    local c = s:sub(i, i)
    if c == '"' then return str(s, i)
    elseif c == '{' then
      local o = {}
      i = ws(s, i + 1)
      if s:sub(i, i) == '}' then return o, i + 1 end
      while true do
        local k; k, i = str(s, ws(s, i))
        i = ws(s, i)
        if s:sub(i, i) ~= ':' then error('expected :') end
        local v; v, i = value(s, i + 1)
        o[k] = v
        i = ws(s, i)
        local d = s:sub(i, i)
        if d == '}' then return o, i + 1 end
        if d ~= ',' then error('expected ,') end
        i = i + 1
        if s:sub(ws(s, i), ws(s, i)) == '}' then return o, ws(s, i) + 1 end   -- висячая запятая (бывает в ISF)
      end
    elseif c == '[' then
      local a = {}
      i = ws(s, i + 1)
      if s:sub(i, i) == ']' then return a, i + 1 end
      while true do
        local v; v, i = value(s, i)
        a[#a + 1] = v
        i = ws(s, i)
        local d = s:sub(i, i)
        if d == ']' then return a, i + 1 end
        if d ~= ',' then error('expected ,') end
        i = i + 1
        if s:sub(ws(s, i), ws(s, i)) == ']' then return a, ws(s, i) + 1 end
      end
    elseif s:sub(i, i + 3) == 'true' then return true, i + 4
    elseif s:sub(i, i + 4) == 'false' then return false, i + 5
    elseif s:sub(i, i + 3) == 'null' then return nil, i + 4 end
    local num = s:match('^-?%d*%.?%d*[eE]?[+%-]?%d*', i)
    if not num or num == '' then error('bad token at ' .. i) end
    return tonumber(num) or 0, i + #num
  end
  function json.decode(s)
    if type(s) ~= 'string' or s == '' then return nil end
    local ok, v = pcall(value, s, 1)
    if ok then return v end
    return nil
  end
end

-- ── ISF: входы шейдера → строки параметров ──────────────────────────────
-- строка: { key, name, ty = 'f' | 'b' | 'l' | 'c', axis, min, max, def, values, labels }
function VZ.parse_header(src)
  local i = src and src:find('/*', 1, true)
  local j = i and src:find('*/', i + 2, true)
  if not i or not j then return nil, 'no ISF header' end
  local head = json.decode(src:sub(i + 2, j - 1))
  if type(head) ~= 'table' then return nil, 'ISF header is not JSON' end
  local rows = {}
  for _, inp in ipairs(head.INPUTS or {}) do
    local ty, name = inp.TYPE, inp.NAME
    if type(name) ~= 'string' then ty = nil end
    if ty == 'float' then
      local def = tonumber(inp.DEFAULT) or 0
      local mn, mx = tonumber(inp.MIN), tonumber(inp.MAX)
      mn = mn or math.min(0, def); mx = mx or math.max(1, def * 2)
      if mx <= mn then mx = mn + 1 end
      rows[#rows + 1] = { key = name, name = name, ty = 'f', min = mn, max = mx, def = math.min(math.max(def, mn), mx) }
    elseif ty == 'point2D' then
      local d, mn, mx = inp.DEFAULT or {}, inp.MIN or {}, inp.MAX or {}
      for a, ax in ipairs({ 'x', 'y' }) do
        local amn, amx = tonumber(mn[a]) or 0, tonumber(mx[a]) or 1
        if amx <= amn then amx = amn + 1 end
        local def = math.min(math.max(tonumber(d[a]) or (amn + amx) / 2, amn), amx)
        rows[#rows + 1] = { key = name .. '.' .. ax, name = name, axis = a, ty = 'f', min = amn, max = amx, def = def }
      end
    elseif ty == 'bool' then
      rows[#rows + 1] = { key = name, name = name, ty = 'b', min = 0, max = 1, def = (inp.DEFAULT == true or inp.DEFAULT == 1) and 1 or 0 }
    elseif ty == 'long' then
      local r = { key = name, name = name, ty = 'l', def = math.floor(tonumber(inp.DEFAULT) or 0) }
      if type(inp.VALUES) == 'table' and #inp.VALUES > 0 then
        r.values, r.labels = {}, {}
        for k, v in ipairs(inp.VALUES) do
          r.values[k] = math.floor(tonumber(v) or 0)
          r.labels[k] = type(inp.LABELS) == 'table' and inp.LABELS[k] and tostring(inp.LABELS[k]) or tostring(r.values[k])
        end
        r.min, r.max = 1, #r.values
        local di = 1   -- храним номер в списке, DEFAULT — само значение
        for k, v in ipairs(r.values) do if v == r.def then di = k end end
        r.def = di
      else
        r.min, r.max = math.floor(tonumber(inp.MIN) or 0), math.floor(tonumber(inp.MAX) or math.max(10, r.def))
      end
      rows[#rows + 1] = r
    elseif ty == 'color' then
      local d = type(inp.DEFAULT) == 'table' and inp.DEFAULT or { 1, 1, 1, 1 }
      rows[#rows + 1] = { key = name, name = name, ty = 'c', def = { d[1] or 1, d[2] or 1, d[3] or 1, d[4] or 1 } }
    end
  end
  return rows, head
end

-- пути: VZ.WEB = <ресурсы>/reaper_www_root/isf (ставит main)
function VZ.path_of(kind, fn)
  if kind == 'master' then return VZ.WEB .. '/master.fs' end
  return VZ.WEB .. '/' .. (kind == 'fx' and 'effects' or 'shaders') .. '/' .. fn
end

function VZ.rows(kind, fn)
  local path = VZ.path_of(kind, fn)
  local r = VZ.heads[path]
  if r == nil then
    r = false
    local f = io.open(path, 'r')
    if f then
      local src = f:read('*a'); f:close()
      local rows = VZ.parse_header(src)
      if rows then
        r = {}
        for _, row in ipairs(rows) do
          if kind == 'layer' or row.ty == 'f' then r[#r + 1] = row end   -- эффекты и master — только float (как ReaVisor)
        end
      end
    end
    VZ.heads[path] = r
  end
  return r or {}
end

local function copy(v)
  if type(v) ~= 'table' then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = copy(x) end
  return o
end
VZ.copy = copy

-- параметр модели для строки (создаётся со значением по умолчанию)
function VZ.param(slot, row)
  slot.p = slot.p or {}
  local p = slot.p[row.key]
  if not p then p = { v = copy(row.def) }; slot.p[row.key] = p end
  if row.ty == 'c' and type(p.v) ~= 'table' then p.v = copy(row.def) end
  if row.ty ~= 'c' and type(p.v) ~= 'number' then p.v = row.def end
  return p
end

-- ── модуляция ───────────────────────────────────────────────────────────
VZ.SHAPES = { [0] = 'sin', 'tri', 'saw', 'sqr', 'ramp', 'rise', 'fall' }
function VZ.wave(sh, ph)
  if sh == 0 then return 0.5 + 0.5 * math.sin(ph * 2 * math.pi)
  elseif sh == 1 then return ph < 0.5 and ph * 2 or 2 - ph * 2
  elseif sh == 2 then return ph
  elseif sh == 3 then return ph < 0.5 and 1 or 0
  elseif sh == 4 then return 1 - ph
  elseif sh == 5 then return ph < 0.25 and ph * 4 or (1 - ph) / 0.75
  elseif sh == 6 then return ph < 0.75 and ph / 0.75 or (1 - ph) * 4 end
  return 0.5
end

-- значение float-параметра в момент t; peak(guid) → 0..1
function VZ.eval(row, p, t, peak)
  local v = VZ.eval1(row, p, t, peak)
  if type(p.mods) ~= 'table' or next(p.mods) == nil or type(v) ~= 'number' then return v end
  local span = row.max - row.min
  for src, amt in pairs(p.mods) do v = v + VZ.src_val(src, t, peak) * amt * span end
  return math.min(math.max(v, row.min), row.max)
end
function VZ.eval1(row, p, t, peak)
  local v, m = p.v, p.m
  if type(m) ~= 'table' then return v end
  local span = row.max - row.min
  local out = v
  if m.k == 'lfo' then
    out = v + (VZ.wave(m.sh or 0, ((t or 0) * (m.hz or 0.5)) % 1) - 0.5) * (m.amt or 0.5) * span
  elseif m.k == 'trk' then
    out = v + ((peak and m.g and peak(m.g)) or 0) * (m.amt or 1) * span
  end
  return math.min(math.max(out, row.min), row.max)
end
-- значение источника матрицы сейчас: LFO -0.5..0.5, пик трека и макрос 0..1
function VZ.src_val(src, t, peak)
  local k = tostring(src)
  local li = tonumber(k:match('^L(%d)$'))
  if li then
    local l = (VZ.st.lfos or {})[li]
    if not l then return 0 end
    return VZ.wave(l.sh or 0, ((t or 0) * (l.hz or 0.5)) % 1) - 0.5
  end
  local g = k:match('^T:(.+)$')
  if g then return (peak and peak(g)) or 0 end
  local mi = tonumber(k:match('^M(%d+)$'))
  if mi then return (VZ.env_macro and VZ.env_macro(mi)) or 0 end
  return 0
end

-- строка значений одного слоя / эффекта / master
function VZ.values(slot, rows, t, peak, prefix)
  local parts, i, pre = {}, 1, prefix or ''
  while i <= #rows do
    local row = rows[i]
    local p = VZ.param(slot, row)
    if row.axis == 1 and rows[i + 1] and rows[i + 1].name == row.name then
      local q = VZ.param(slot, rows[i + 1])
      parts[#parts + 1] = ('%s%s=%.4f,%.4f'):format(pre, row.name, VZ.eval(row, p, t, peak), VZ.eval(rows[i + 1], q, t, peak))
      i = i + 2
    else
      if row.ty == 'f' then parts[#parts + 1] = ('%s%s=%.4f'):format(pre, row.name, VZ.eval(row, p, t, peak))
      elseif row.ty == 'b' then parts[#parts + 1] = ('%s%s=%d'):format(pre, row.name, p.v >= 0.5 and 1 or 0)
      elseif row.ty == 'l' then parts[#parts + 1] = ('%s%s=%d'):format(pre, row.name, row.values and row.values[math.floor(p.v)] or math.floor(p.v))
      elseif row.ty == 'c' then local c = p.v; parts[#parts + 1] = ('%s%s=%.3f,%.3f,%.3f,%.3f'):format(pre, row.name, c[1], c[2], c[3], c[4] or 1) end
      i = i + 1
    end
  end
  return table.concat(parts, ';')
end

-- ── кадр: всё в ExtState (только изменившееся) ──────────────────────────
-- env = { t, set(key, val), peak(guid) }
function VZ.frame(env)
  local st = VZ.st
  local function put(k, v) if VZ.cache[k] ~= v then VZ.cache[k] = v; env.set(k, v) end end
  local names, fades, gates = {}, {}, {}
  for i, l in ipairs(st.layers) do
    if i > VZ.MAXL then break end
    names[i] = l.fn
    fades[i] = ('%.3f'):format(l.fade or 1)
    gates[i] = l.on == false and '0' or '1'
    if l.on ~= false and (l.fade or 1) > 0.001 then
      put('lvalues' .. i, VZ.values(l, VZ.rows('layer', l.fn), env.t, env.peak))
    end
  end
  put('layers', table.concat(names, '|'))
  put('fades', table.concat(fades, ','))
  put('lgate', table.concat(gates, ','))
  put('blend', st.blend or 'normal')
  local fxn, fxv, n = {}, {}, 0
  for _, e in ipairs(st.fx) do
    if e.on ~= false then
      fxn[#fxn + 1] = e.fn
      local s = VZ.values(e, VZ.rows('fx', e.fn), env.t, env.peak, n .. '.')
      if s ~= '' then fxv[#fxv + 1] = s end
      n = n + 1
    end
  end
  put('fxchain', table.concat(fxn, '|'))
  put('fxvalues', table.concat(fxv, ';'))
  put('mvalues', VZ.values(st.master, VZ.rows('master'), env.t, env.peak))
  put('render', ('scale=%.2f;fps=%d'):format(st.scale or 0.3, st.fps or 60))
end

-- ── хранение и сцены ────────────────────────────────────────────────────
function VZ.encode() return json.encode(VZ.st) end
function VZ.decode(s)
  local t = json.decode(s)
  local st = new_state()
  if type(t) == 'table' then
    for k, v in pairs(t) do st[k] = v end
    if type(st.layers) ~= 'table' then st.layers = {} end
    if type(st.fx) ~= 'table' then st.fx = {} end
    if type(st.master) ~= 'table' then st.master = { p = {} } end
    if type(st.scenes) ~= 'table' then st.scenes = {} end
    if type(st.lfos) ~= 'table' or #st.lfos < 4 then st.lfos = VZ.default_lfos() end
  end
  VZ.st = st
  VZ.cache = {}
  return st
end

-- снимок сцены: всё, кроме самих сцен и качества картинки
function VZ.scene_take()
  local st = VZ.st
  return { layers = copy(st.layers), fx = copy(st.fx), master = copy(st.master), blend = st.blend, preset = st.preset }
end
function VZ.scene_apply(sc)
  if type(sc) ~= 'table' then return false end
  local st = VZ.st
  st.layers = copy(sc.layers or {}); st.fx = copy(sc.fx or {})
  st.master = copy(sc.master or { p = {} }); st.blend = sc.blend or 'normal'
  st.preset = sc.preset
  VZ.dirty = true
  return true
end

-- пресет ReaVisor (ExtState ISFVIZ/preset:<имя>, JSON) → сцена трекера
function VZ.from_reavisor(ps)
  if type(ps) ~= 'table' then return nil end
  if type(ps.jf) == 'table' and type(ps.jf.layers) == 'table' then return copy(ps.jf) end   -- 13 окт: сохранён трекером — снимок целиком
  local function conv(params, rows)
    local out = {}
    if type(params) ~= 'table' then return out end
    for _, row in ipairs(rows) do
      local sp = params[row.name]
      if type(sp) == 'table' and row.axis then sp = type(sp.axes) == 'table' and sp.axes[row.axis] or nil end
      if type(sp) == 'table' and sp.static ~= nil then
        local p = { v = copy(sp.static) }
        if row.ty == 'l' and row.values then   -- ReaVisor хранит значение, трекер — номер в списке
          local di = 1
          for k, v in ipairs(row.values) do if v == p.v then di = k end end
          p.v = di
        end
        if row.ty == 'f' and type(p.v) == 'number' then
          local span = row.max - row.min
          local r1 = type(sp.routes) == 'table' and sp.routes[1] or ''
          if (tonumber(sp.lfo) or 0) > 0 then
            p.m = { k = 'lfo', sh = math.floor(sp.lfo) - 1, hz = tonumber(sp.lfo_hz) or 0.5, amt = tonumber(sp.lfo_amt) or 0.5 }
          elseif type(r1) == 'string' and r1:sub(1, 2) == 'T:' and span > 0 then
            local mn, mx = tonumber(sp.out_min) or row.min, tonumber(sp.out_max) or row.max
            p.v = mn; p.m = { k = 'trk', g = r1:sub(3), amt = (mx - mn) / span }
          end
        end
        out[row.key] = p
      end
    end
    return out
  end
  local sc = { layers = {}, fx = {}, master = { p = {} }, blend = ps.blend == 'add' and 'add' or 'normal' }
  local tabs = type(ps.tabs) == 'table' and #ps.tabs > 0 and ps.tabs or { ps.shader }
  for _, fn in ipairs(tabs) do
    if type(fn) == 'string' and fn:sub(1, 1) ~= '@' and #sc.layers < VZ.MAXL then
      local params = type(ps.decks) == 'table' and ps.decks[fn] or (fn == ps.shader and ps.params) or nil
      local fade = type(ps.fades) == 'table' and tonumber(ps.fades[fn]) or 1
      sc.layers[#sc.layers + 1] = { fn = fn, on = true, fade = fade, p = conv(params, VZ.rows('layer', fn)) }
    end
  end
  for _, fn in ipairs(type(ps.fxchain) == 'table' and ps.fxchain or {}) do
    if type(fn) == 'string' then
      sc.fx[#sc.fx + 1] = { fn = fn, on = true, p = conv(type(ps.fxparams) == 'table' and ps.fxparams[fn], VZ.rows('fx', fn)) }
    end
  end
  return sc
end

-- 13 окт: сцена трекера → пресет ReaVisor (ExtState ISFVIZ/preset:<имя>): слои, значения, LFO
-- и маршрут трека первого источника — в его полях (страница / reavisor.lua поймут), плюс jf —
-- снимок целиком (эффекты, master, матрица): трекер берёт его без перевода
function VZ.to_reavisor()
  local sc = VZ.scene_take()
  local function conv(slot, rows)
    local out = {}
    for _, row in ipairs(rows) do
      local p = slot.p and slot.p[row.key]
      if p then
        local v = p.v
        if row.ty == 'l' and row.values then v = row.values[math.floor(v)] end
        local sp = { static = copy(v) }
        if row.ty == 'f' and p.m and p.m.k == 'lfo' then sp.lfo, sp.lfo_hz, sp.lfo_amt = (p.m.sh or 0) + 1, p.m.hz, p.m.amt
        elseif row.ty == 'f' and p.m and p.m.k == 'trk' then
          sp.routes = { 'T:' .. p.m.g }; sp.out_min = p.v; sp.out_max = p.v + (p.m.amt or 0) * (row.max - row.min)
        end
        if row.axis then
          out[row.name] = out[row.name] or { axes = {} }
          out[row.name].axes[row.axis] = sp
        else out[row.name] = sp end
      end
    end
    return out
  end
  local ps = { tabs = {}, fades = {}, decks = {}, fxchain = {}, fxparams = {}, blend = sc.blend, jf = sc }
  for _, l in ipairs(sc.layers) do
    ps.tabs[#ps.tabs + 1] = l.fn; ps.fades[l.fn] = l.fade or 1
    ps.decks[l.fn] = conv(l, VZ.rows('layer', l.fn))
  end
  for _, e in ipairs(sc.fx) do
    if e.on ~= false then ps.fxchain[#ps.fxchain + 1] = e.fn; ps.fxparams[e.fn] = conv(e, VZ.rows('fx', e.fn)) end
  end
  ps.shader = ps.tabs[1]; ps.params = ps.tabs[1] and ps.decks[ps.tabs[1]] or {}
  return ps
end

-- 13 окт: значение под курсором текстом (для ввода =) и ввод числа: матрица (M) — сила связи,
-- иначе выбранный параметр (число — в его диапазоне, список — номер, вкл — 0 / 1)
function VZ.value_text(env)
  local e = VZ.cur()
  if VZ.mxv then
    local srcs, pars = VZ.sources(env), VZ.mx_params(e)
    local src, pc = srcs[VZ.mr], pars[VZ.mc]
    if not (src and pc and e and e.slot) then return nil end
    local p = VZ.param(e.slot, pc.row)
    return ('%.2f'):format(type(p.mods) == 'table' and p.mods[src.id] or 0), src.name .. ' -> ' .. pc.row.name, '-2 .. 2'
  end
  local row = e and e.rows and e.rows[VZ.psel]
  if not (row and e.slot) then return nil end
  local p = VZ.param(e.slot, row)
  if row.ty == 'f' then return ('%.3f'):format(p.v), row.name, ('%.3f .. %.3f'):format(row.min, row.max) end
  if row.ty == 'l' or row.ty == 'b' then return tostring(math.floor(p.v)), row.name, ('%d .. %d'):format(row.min or 0, row.max or 1) end
  return nil
end
function VZ.set_value(v, env)
  v = tonumber(v)
  if not v then return false end
  local e = VZ.cur()
  if VZ.mxv then
    local srcs, pars = VZ.sources(env), VZ.mx_params(e)
    local src, pc = srcs[VZ.mr], pars[VZ.mc]
    if not (src and pc and e and e.slot) then return false end
    local p = VZ.param(e.slot, pc.row)
    p.mods = type(p.mods) == 'table' and p.mods or {}
    v = math.max(-2, math.min(2, v))
    p.mods[src.id] = v ~= 0 and v or nil
  else
    local row = e and e.rows and e.rows[VZ.psel]
    if not (row and e.slot) or row.ty == 'c' then return false end
    local p = VZ.param(e.slot, row)
    if row.ty == 'f' then p.v = math.max(row.min, math.min(row.max, v))
    elseif row.ty == 'b' then p.v = v >= 0.5 and 1 or 0
    else p.v = math.max(row.min, math.min(row.max, math.floor(v + 0.5))) end
  end
  VZ.dirty = true
  return true
end

-- ── левый список: слои, эффекты, master ─────────────────────────────────
-- элемент: { kind = 'layer' | 'fx' | 'master' | 'addl' | 'addfx', i, slot }
function VZ.list()
  local st, out = VZ.st, {}
  for i, l in ipairs(st.layers) do out[#out + 1] = { kind = 'layer', i = i, slot = l } end
  if #st.layers < VZ.MAXL then out[#out + 1] = { kind = 'addl' } end
  for i, e in ipairs(st.fx) do out[#out + 1] = { kind = 'fx', i = i, slot = e } end
  out[#out + 1] = { kind = 'addfx' }
  out[#out + 1] = { kind = 'master', slot = st.master }
  return out
end

function VZ.cur()
  local list = VZ.list()
  VZ.sel = math.max(1, math.min(#list, VZ.sel))
  local e = list[VZ.sel]
  if e and e.slot then
    e.rows = VZ.rows(e.kind, e.slot.fn)
  end
  return e, list
end

-- шаг значения строки (dir ±1, fine — мелко)
function VZ.step(row, p, dir, fine)
  if row.ty == 'f' then
    local st = (row.max - row.min) * (fine and 0.002 or 0.02)
    p.v = math.min(math.max(p.v + dir * st, row.min), row.max)
  elseif row.ty == 'b' then p.v = p.v >= 0.5 and 0 or 1
  elseif row.ty == 'l' then p.v = math.min(math.max(math.floor(p.v) + dir, row.min), row.max)
  elseif row.ty == 'c' then
    -- цвет: H L крутят оттенок (HSV), яркость и насыщенность держатся
    local r, g, b = p.v[1], p.v[2], p.v[3]
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local h, s, v = 0, mx > 0 and (mx - mn) / mx or 0, mx
    if mx > mn then
      if mx == r then h = ((g - b) / (mx - mn)) % 6 elseif mx == g then h = (b - r) / (mx - mn) + 2 else h = (r - g) / (mx - mn) + 4 end
      h = h / 6
    end
    if s == 0 then s, v = 1, math.max(v, 0.5) end
    h = (h + dir * (fine and 0.005 or 0.03)) % 1
    local i = math.floor(h * 6); local f = h * 6 - i
    local P, Q, T = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    local rgb = ({ { v, T, P }, { Q, v, P }, { P, v, T }, { P, Q, v }, { T, P, v }, { v, P, Q } })[i % 6 + 1]
    p.v = { rgb[1], rgb[2], rgb[3], p.v[4] or 1 }
  end
  VZ.dirty = true
end

-- источник по кругу: нет → LFO → трек (трек выбирает main) → нет
function VZ.cycle_src(row, p)
  if row.ty ~= 'f' then return nil end
  VZ.dirty = true
  if not p.m then p.m = { k = 'lfo', sh = 0, hz = 0.5, amt = 0.3 }; return 'lfo' end
  if p.m.k == 'lfo' then p.m = nil; return 'track' end   -- трек выберет main (fzf), Esc — без модуляции
  p.m = nil
  return 'none'
end

function VZ.src_text(p, tname)
  local m = p and p.m
  if not m then return '' end
  if m.k == 'lfo' then return ('~%s %.2fHz %d%%'):format(VZ.SHAPES[m.sh or 0] or '?', m.hz or 0.5, math.floor((m.amt or 0) * 100 + 0.5)) end
  if m.k == 'trk' then return ('>%s %d%%'):format(tname and tname(m.g) or 'track', math.floor((m.amt or 0) * 100 + 0.5)) end
  return ''
end

local function rnd_of(row, p)
  if row.ty == 'f' then p.v = row.min + math.random() * (row.max - row.min)
  elseif row.ty == 'b' then p.v = math.random() < 0.5 and 0 or 1
  elseif row.ty == 'l' then p.v = math.random(row.min, row.max)
  elseif row.ty == 'c' then p.v = { math.random(), math.random(), math.random(), 1 } end
end
function VZ.randomize(e)
  if not (e and e.slot) then return end
  for _, row in ipairs(e.rows or {}) do rnd_of(row, VZ.param(e.slot, row)) end
  VZ.dirty = true
end

-- ── матрица модуляций (11 окт) ───────────────────────────────────────────
-- строки — источники: L1..L4, пики треков (env.tracks), макросы M1..M16 (env.macros);
-- колонки — числовые параметры выбранного слоя / эффекта / master; клетка — сила связи
function VZ.sources(env)
  local out = {}
  for i, l in ipairs(VZ.st.lfos or {}) do
    out[#out + 1] = { id = 'L' .. i, name = ('L%d %s %.2fHz'):format(i, VZ.SHAPES[l.sh or 0] or '?', l.hz or 0.5), lfo = i }
  end
  for _, t in ipairs(env and env.tracks or {}) do out[#out + 1] = { id = 'T:' .. t.g, name = t.name ~= '' and t.name or 'track', trk = t.g } end
  for k = 1, (env and env.macros or 0) do out[#out + 1] = { id = 'M' .. k, name = ('M%d macro'):format(k), mac = k } end
  return out
end
function VZ.mx_params(e)
  local out = {}
  for i, r in ipairs(e and e.rows or {}) do if r.ty == 'f' then out[#out + 1] = { row = r, i = i } end end
  return out
end
-- клавиши матрицы: h j k l — курсор, + - — сила (Shift / fine — мелко), цифры — .N, две подряд — .NN,
-- x — убрать, ~ — знак; на подписи LFO: + - частота, w форма; J K — слой, M / Esc — назад
function VZ.mx_key(c, fine, env)
  local ch = c > 0 and c < 256 and string.char(c) or ''
  local e = VZ.cur()
  local srcs, pars = VZ.sources(env), VZ.mx_params(e)
  VZ.mr = math.max(1, math.min(#srcs, VZ.mr))
  VZ.mc = math.max(0, math.min(#pars, VZ.mc))
  local src = srcs[VZ.mr]
  if c == 27 or ch == 'M' then VZ.mxv = false; return true end
  if ch:match('^[jklh]$') then VZ.mxbuf = nil end
  if ch == 'j' then VZ.mr = math.min(#srcs, VZ.mr + 1); return true end
  if ch == 'k' then VZ.mr = math.max(1, VZ.mr - 1); return true end
  if ch == 'l' then VZ.mc = math.min(#pars, VZ.mc + 1); return true end
  if ch == 'h' then VZ.mc = math.max(0, VZ.mc - 1); return true end
  if ch == 'J' then VZ.sel = math.min(#VZ.list(), VZ.sel + 1); return true end
  if ch == 'K' then VZ.sel = math.max(1, VZ.sel - 1); return true end
  if not src then return true end
  if VZ.mc == 0 then
    local l = src.lfo and VZ.st.lfos[src.lfo]
    if l and (ch == '+' or ch == '=' or ch == '-') then l.hz = math.min(16, math.max(0.01, ch == '-' and l.hz / 1.25 or l.hz * 1.25)); VZ.dirty = true
    elseif l and ch == 'w' then l.sh = ((l.sh or 0) + 1) % 7; VZ.dirty = true end
    return true
  end
  local pc = pars[VZ.mc]
  if not (pc and e and e.slot) then return true end
  local p = VZ.param(e.slot, pc.row)
  p.mods = type(p.mods) == 'table' and p.mods or {}
  local a = p.mods[src.id] or 0
  local d = tonumber(ch)
  -- 13 окт: цифры как в трекере: первая — десятые (5 → .50), вторая — сотые (5 7 → .57);
  -- знак сохраняется (~ меняет), x — убрать; другая клавиша или ячейка — набор закрыт
  if d and #ch == 1 then
    local now = (reaper and reaper.time_precise or os.clock)()
    local cell = VZ.mr .. ':' .. VZ.mc
    if VZ.mxbuf and VZ.mxcell == cell and #VZ.mxbuf == 1 and now - (VZ.mxt or 0) < 2 then
      VZ.mxbuf = VZ.mxbuf .. ch; a = (a < 0 and -1 or 1) * tonumber(VZ.mxbuf) / 100; VZ.mxbuf = nil
    else
      VZ.mxbuf, VZ.mxcell, VZ.mxt = ch, cell, now; a = (a < 0 and -1 or 1) * d / 10
    end
  else
    VZ.mxbuf = nil
    if ch == '+' or ch == '=' or ch == '-' then a = a + (ch == '-' and -1 or 1) * (fine and 0.01 or 0.05)
    elseif ch == '~' then a = -a
    elseif ch == 'x' then a = 0
    else return nil end
  end
  a = math.max(-2, math.min(2, math.floor(a * 100 + 0.5) / 100))
  p.mods[src.id] = a ~= 0 and a or nil
  VZ.dirty = true
  return true
end
-- отрисовка матрицы в прямоугольнике (вместо параметров)
function VZ.draw_matrix(L, U, x, y, w, h, focused, env, fit, hint)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local ms, pad, rh = U.measure, L.pad, L.rh
  local e = VZ.cur()
  local srcs, pars = VZ.sources(env), VZ.mx_params(e)
  local hover
  if not (e and e.slot) or #pars == 0 then
    U.text(x, y, fit('matrix: pick a layer / effect with numeric parameters (J K)', w), U.GREY)
    return nil
  end
  VZ.mr = math.max(1, math.min(#srcs, VZ.mr))
  VZ.mc = math.max(0, math.min(#pars, VZ.mc))
  local lw = math.min(ms('W') * 16, math.floor(w * 0.35))
  -- 13 окт: подписи колонок — вертикально (как имена треков в матрице): колонки узкие, влезает больше
  local vt = VZ.vtext
  local cw = vt and (ms('-.00') + pad) or (ms('-0.00') + 2 * pad)
  local hh = vt and math.min(ms('W') * 8, math.max(rh, math.floor(h * 0.4))) or rh
  local ncv = math.max(1, math.floor((w - lw) / cw))
  if VZ.mc > VZ.mcs + ncv then VZ.mcs = VZ.mc - ncv end
  if VZ.mc >= 1 and VZ.mc <= VZ.mcs then VZ.mcs = VZ.mc - 1 end
  VZ.mcs = math.max(0, math.min(VZ.mcs, #pars - ncv))
  -- заголовок: имена параметров (коротко), полное — в подсказке
  for k = 1, ncv do
    local pc = pars[VZ.mcs + k]
    if not pc then break end
    local cx = x + lw + (k - 1) * cw
    local nm = pc.row.name .. (pc.row.axis and (pc.row.axis == 1 and '.x' or '.y') or '')
    local on = VZ.mcs + k == VZ.mc
    if vt then vt(cx + math.floor((cw - rh) / 2), y, hh, nm, on and U.AMBER or U.GREY, U.PANEL)
    else U.text(cx + pad, y, fit(nm, cw - pad), on and U.AMBER or U.GREY) end
    if mx >= cx and mx < cx + cw and my >= y and my < y + hh then hover = { kind = 'mxh', tip = 'parameter ' .. nm } end
  end
  local ty = y + hh + 2
  local nrv = math.max(1, math.floor((y + h - ty) / rh))
  VZ.mrs = VZ.mrs or 0
  if VZ.mr > VZ.mrs + nrv then VZ.mrs = VZ.mr - nrv end
  if VZ.mr <= VZ.mrs then VZ.mrs = math.max(0, VZ.mr - 1) end
  for k = 1, nrv do
    local si = (VZ.mrs or 0) + k
    local src = srcs[si]
    if not src then break end
    local ry = ty + (k - 1) * rh
    local sv = VZ.src_val(src.id, env.t or 0, env.peak)
    local lv = src.lfo and (sv + 0.5) or sv
    -- подпись источника + его уровень сейчас
    local lab_on = si == VZ.mr and VZ.mc == 0
    if si == VZ.mr then U.set(focused and U.mix(U.BG, U.TEXT, 0.10) or U.mix(U.BG, U.TEXT, 0.05)); gfx.rect(x, ry, w, rh, 1) end
    U.set(U.mix(U.CYAN, U.BG, 0.55)); gfx.rect(x, ry + rh - 3, math.max(1, math.floor(math.max(0, math.min(1, lv)) * (lw - pad))), 2, 1)
    U.text(x + 2, ry, fit(src.name, lw - pad - 2), lab_on and U.AMBER or (src.lfo and U.CYAN or (src.mac and U.GREEN or U.TEXT)))
    if mx >= x and mx < x + lw and my >= ry and my < ry + rh then
      hover = { kind = 'mxcell', si = si, pc = 0, tip = src.lfo and ('LFO %d: + - rate, w shape; drag a cell: depth'):format(src.lfo) or (src.name .. ': level now - feeds the parameters it is routed to') }
    end
    for c2 = 1, ncv do
      local pi = VZ.mcs + c2
      local pc = pars[pi]
      if not pc then break end
      local cx = x + lw + (c2 - 1) * cw
      local p = VZ.param(e.slot, pc.row)
      local a = type(p.mods) == 'table' and p.mods[src.id] or nil
      local on = si == VZ.mr and pi == VZ.mc
      -- 13 окт: пустая ячейка — точки (место ввода, как в трекере); набор цифр — VZ.mxbuf
      local typing = on and VZ.mxbuf
      if not a and not typing then U.text(cx + math.floor((cw - ms('..')) / 2), ry, '..', U.DIM) end
      if a then
        local mid = cx + math.floor(cw / 2)
        local len = math.floor(math.min(1, math.abs(a)) * (cw / 2 - 2) + 0.5)
        U.set(a > 0 and U.CYAN or U.AMBER)
        if a > 0 then gfx.rect(mid, ry + 3, math.max(1, len), rh - 6, 1) else gfx.rect(mid - len, ry + 3, math.max(1, len), rh - 6, 1) end
      end
      if on then
        U.set(focused and U.AMBER or U.LINE); gfx.rect(cx, ry, cw - 1, rh, 0)
        if typing then U.text(cx + 1, ry, fit(VZ.mxbuf .. '_', cw - 1), U.AMBER, U.BG)
        elseif a then U.text(cx + 1, ry, fit(('%.2f'):format(a):gsub('^0', ''):gsub('^%-0', '-'), cw - 1), U.TEXT, U.BG) end
      end
      if mx >= cx and mx < cx + cw and my >= ry and my < ry + rh then
        hover = { kind = 'mxcell', si = si, pc = pi, tip = ('%s -> %s: %s - click: select, wheel: depth, digits: 5 = .50, 5 7 = .57, ~ sign, x clear'):format(src.name, pc.row.name, a and ('%.2f'):format(a) or 'off') }
      end
      if hint then hint('visor', cx, ry, cw - 1, rh, { kind = 'mxcell', si = si, pc = pi }) end
    end
  end
  return hover
end

-- ── клавиши ─────────────────────────────────────────────────────────────
-- j k — список, J K — параметр, h l — уровень слоя, H L — значение (Ctrl — мелко,
-- main передаёт fine), Space — вкл / выкл, a — слой, e — эффект, Enter / r —
-- заменить, x — убрать, < > — порядок, m — источник, [ ] — глубина, { } —
-- частота / форма, 0 — сброс, R — случайно, o — страница, b — смесь,
-- s — сцена в слот курсора, S — сцены за плейхедом, i — пресет ReaVisor, Esc — трекер
function VZ.key(c, fine)
  local ch = c > 0 and c < 256 and string.char(c) or ''
  local e, list = VZ.cur()
  local st = VZ.st
  local rows = e and e.rows or {}
  VZ.psel = math.max(1, math.min(math.max(1, #rows), VZ.psel))
  local row = rows[VZ.psel]
  local p = row and e.slot and VZ.param(e.slot, row)
  -- 11 окт: zz — визор на всё окно (zoom), как в других модулях; z сам по себе — ждёт второй
  if VZ.zpend then
    VZ.zpend = nil
    if ch == 'z' then return { kind = 'zoom' } end
  elseif ch == 'z' then VZ.zpend = true; return true end
  -- 11 окт: n N — следующий / предыдущий пресет (как < > у пресета эффекта в DSP)
  if ch == 'n' or ch == 'N' then return { kind = 'preset_step', dir = ch == 'n' and 1 or -1 } end
  -- сетка пресетов (i): h j k l по карточкам, Enter — взять, Esc / i — назад к списку
  if VZ.gal then
    local n, cols = #(VZ.pnames or {}), math.max(1, VZ.gcols or 1)
    if c == 27 or ch == 'i' then VZ.gal = false; return true
    elseif c == 13 or ch == ' ' then local nm = (VZ.pnames or {})[VZ.gsel]; if nm then return { kind = 'preset', name = nm } end; return true
    elseif ch == 'l' then VZ.gsel = math.min(n, VZ.gsel + 1); return true
    elseif ch == 'h' then VZ.gsel = math.max(1, VZ.gsel - 1); return true
    elseif ch == 'j' then VZ.gsel = math.min(n, VZ.gsel + cols); return true
    elseif ch == 'k' then VZ.gsel = math.max(1, VZ.gsel - cols); return true
    end
  end
  if ch == '=' then return { kind = 'input' } end         -- 13 окт: ввести число с клавиатуры (:vzset)
  if VZ.mxv then
    local r = VZ.mx_key(c, fine, VZ.last_env)
    if r ~= nil then return r end
  elseif ch == 'M' then VZ.mxv = true; return true end
  if c == 27 then return { kind = 'leave' }
  elseif ch == 'j' then VZ.sel = math.min(#list, VZ.sel + 1); VZ.psel = 1; return true
  elseif ch == 'k' then VZ.sel = math.max(1, VZ.sel - 1); VZ.psel = 1; return true
  elseif ch == 'J' then VZ.psel = math.min(math.max(1, #rows), VZ.psel + 1); return true
  elseif ch == 'K' then VZ.psel = math.max(1, VZ.psel - 1); return true
  elseif ch == 'H' or ch == 'L' then
    if p then VZ.step(row, p, ch == 'L' and 1 or -1, fine) end
    return true
  elseif ch == 'h' or ch == 'l' then
    if e and e.kind == 'layer' then
      e.slot.fade = math.min(1, math.max(0, (e.slot.fade or 1) + (ch == 'l' and 0.05 or -0.05))); VZ.dirty = true
    end
    return true
  elseif ch == ' ' then
    if e and (e.kind == 'layer' or e.kind == 'fx') then e.slot.on = e.slot.on == false; VZ.dirty = true
    elseif e and e.kind == 'addl' then return { kind = 'add', what = 'layer' }
    elseif e and e.kind == 'addfx' then return { kind = 'add', what = 'fx' } end
    return true
  elseif ch == 'a' then return { kind = 'add', what = 'layer' }
  elseif ch == 'e' then return { kind = 'add', what = 'fx' }
  elseif c == 13 or ch == 'r' then
    if e and (e.kind == 'layer' or e.kind == 'addl') then return { kind = e.kind == 'layer' and 'replace' or 'add', what = 'layer', i = e.i } end
    if e and (e.kind == 'fx' or e.kind == 'addfx') then return { kind = e.kind == 'fx' and 'replace' or 'add', what = 'fx', i = e.i } end
    return true
  elseif ch == 'x' then
    if e and e.kind == 'layer' then table.remove(st.layers, e.i); VZ.dirty = true
    elseif e and e.kind == 'fx' then table.remove(st.fx, e.i); VZ.dirty = true end
    return true
  elseif ch == '<' or ch == '>' then
    local t = e and (e.kind == 'layer' and st.layers or e.kind == 'fx' and st.fx)
    local j = t and e.i + (ch == '>' and 1 or -1)
    if t and j >= 1 and j <= #t then t[e.i], t[j] = t[j], t[e.i]; VZ.sel = VZ.sel + (j - e.i); VZ.dirty = true end
    return true
  elseif ch == 'm' then
    if not p then return true end
    local r = VZ.cycle_src(row, p)
    if r == 'track' then return { kind = 'pick_track', key = row.key } end
    return true
  elseif ch == '[' or ch == ']' then
    if p and p.m then p.m.amt = math.min(2, math.max(-2, (p.m.amt or 0.5) + (ch == ']' and 0.05 or -0.05))); VZ.dirty = true end
    return true
  elseif ch == '{' or ch == '}' then
    if p and p.m and p.m.k == 'lfo' then
      local hz = p.m.hz or 0.5
      p.m.hz = math.min(16, math.max(0.01, ch == '}' and hz * 1.25 or hz / 1.25)); VZ.dirty = true
    end
    return true
  elseif ch == 'w' then
    if p and p.m and p.m.k == 'lfo' then p.m.sh = ((p.m.sh or 0) + 1) % 7; VZ.dirty = true end
    return true
  elseif ch == '0' then
    if p then p.v = copy(row.def); p.m = nil; VZ.dirty = true end
    return true
  elseif ch == 'R' then VZ.randomize(e); return true
  elseif ch == 'o' then return { kind = 'open' }
  elseif ch == 'b' then st.blend = st.blend == 'add' and 'normal' or 'add'; VZ.dirty = true; return true
  elseif ch == 's' then return { kind = 'scene_save' }
  elseif ch == 'S' then st.follow = not st.follow; VZ.dirty = true; return { kind = 'msg', text = 'visor: scenes ' .. (st.follow and 'follow the slot under the playhead' or 'stay as they are') }
  elseif ch == 'i' then
    -- 11 окт: i — сетка пресетов с превью (выбор h j k l / мышью), вместо списка fzf
    VZ.gal = true
    for k2, nm in ipairs(VZ.pnames or {}) do if nm == st.preset then VZ.gsel = k2 end end
    return true
  elseif ch == 'p' then return { kind = 'power' }
  end
  return nil
end

function VZ.click(hv)
  if not hv then return nil end
  if hv.kind == 'row' then
    VZ.sel = hv.i
    local e = VZ.cur()
    if e and (e.kind == 'addl' or e.kind == 'addfx') then return { kind = 'add', what = e.kind == 'addl' and 'layer' or 'fx' } end
    if hv.gate and e and e.slot then e.slot.on = e.slot.on == false; VZ.dirty = true end
    if hv.fade and e and e.kind == 'layer' then e.slot.fade = hv.fade; VZ.dirty = true; return { kind = 'drag_fade', x0 = hv.fx0, w = hv.fw } end
    return true
  elseif hv.kind == 'param' then
    VZ.psel = hv.i
    local e = VZ.cur()
    local row = e and e.rows and e.rows[hv.i]
    if not row then return true end
    local p = VZ.param(e.slot, row)
    if hv.src then
      local r = VZ.cycle_src(row, p)
      if r == 'track' then return { kind = 'pick_track', key = row.key } end
      return true
    end
    if row.ty == 'f' then p.v = row.min + hv.v * (row.max - row.min); VZ.dirty = true; return { kind = 'drag', i = hv.i, x0 = hv.x0, w = hv.w }
    else VZ.step(row, p, 1) end
    return true
  end
  if hv.kind == 'mxcell' then VZ.mr, VZ.mc = hv.si, hv.pc; return true end
  if hv.kind == 'mxtoggle' then VZ.mxv = not VZ.mxv; return true end
  if hv.kind == 'preset' then VZ.gsel = hv.i; return { kind = 'preset', name = hv.name } end
  if hv.kind == 'pgal' then
    VZ.gal = not VZ.gal
    for k2, nm in ipairs(VZ.pnames or {}) do if nm == VZ.st.preset then VZ.gsel = k2 end end
    return true
  end
  if hv.kind == 'pprev' or hv.kind == 'pnext' then return { kind = 'preset_step', dir = hv.kind == 'pnext' and 1 or -1 } end
  return { kind = hv.kind }
end

-- протяжка (main зовёт, пока кнопка зажата): v — 0..1 по x
function VZ.drag(d, v)
  local e = VZ.cur()
  if not (e and e.slot) then return end
  if d.kind == 'drag_fade' then if e.kind == 'layer' then e.slot.fade = v end
  else
    local row = e.rows and e.rows[d.i]
    if row and row.ty == 'f' then VZ.param(e.slot, row).v = row.min + v * (row.max - row.min) end
  end
  VZ.dirty = true
end

-- колесо над параметром
function VZ.wheel(hv, dir, fine)
  if not hv then return end
  if hv.kind == 'mxcell' then
    VZ.mr, VZ.mc = hv.si, hv.pc
    VZ.mx_key((dir > 0 and '+' or '-'):byte(), fine, VZ.last_env)
    return
  end
  if hv.kind == 'param' then
    local e = VZ.cur()
    local row = e and e.rows and e.rows[hv.i]
    if row then VZ.step(row, VZ.param(e.slot, row), dir, fine) end
  elseif hv.kind == 'row' then
    local e = VZ.list()[hv.i]
    if e and e.kind == 'layer' then e.slot.fade = math.min(1, math.max(0, (e.slot.fade or 1) + dir * 0.05)); VZ.dirty = true end
  end
end

-- ── отрисовка ───────────────────────────────────────────────────────────
-- env = { on (отдаём странице), scene (имя слота курсора, есть ли сцена), tname(guid), thumb(kind, fn, x, y, w, h) }
local function short(fn) return (fn or ''):gsub('%.fs$', ''):gsub('_', ' ') end
VZ.short = short

-- сетка пресетов: карточка = превью (картинка первого шейдера пресета) + имя;
-- env.pthumb(name, x, y, w, h) рисует превью; выбранная — янтарная рамка
function VZ.draw_gallery(L, U, x, y, w, h, focused, env, fit, hint)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local ms, pad, rh = U.measure, L.pad, L.rh
  local names = VZ.pnames or {}
  local hover
  if #names == 0 then
    U.text(x + pad, y, fit('no ReaVisor presets (ISFVIZ preset_names) - save one in ReaVisor first', w - 2 * pad), U.GREY)
    return nil
  end
  local cwmin = ms('W') * 14
  local cols = math.max(1, math.floor(w / cwmin))
  local cw = math.floor(w / cols)
  local th = math.min(math.floor((cw - 2 * pad) * 9 / 16), h - rh - pad)
  if th < rh then return nil end                  -- 11 окт: карточка не влезает по высоте — без сетки
  local ch = th + rh + pad
  VZ.gcols = cols
  VZ.gsel = math.max(1, math.min(#names, VZ.gsel))
  local nrows = math.max(1, math.floor(h / ch))
  local row0 = VZ.grow0 or 0
  local sr = (VZ.gsel - 1) // cols
  if sr < row0 then row0 = sr elseif sr >= row0 + nrows then row0 = sr - nrows + 1 end
  VZ.grow0 = row0
  local cur = VZ.st.preset
  for i = row0 * cols + 1, math.min(#names, (row0 + nrows) * cols) do
    local k = i - 1 - row0 * cols
    local cx = x + (k % cols) * cw + pad
    local cy = y + (k // cols) * ch
    local bw = cw - 2 * pad
    local nm = names[i]
    local hot = mx >= cx and mx < cx + bw and my >= cy and my < cy + ch - pad
    local sel = i == VZ.gsel and VZ.gal
    U.set(U.mix(U.BG, U.TEXT, 0.05)); gfx.rect(cx, cy, bw, th, 1)
    if not (env.pthumb and env.pthumb(nm, cx, cy, bw, th)) then
      U.text(cx + pad, cy + math.floor((th - rh) / 2), fit('no preview', bw - 2 * pad), U.DIM)
    end
    local col = (sel and focused) and U.AMBER or (hot and U.TEXT or (nm == cur and U.CYAN or U.LINE))
    U.set(col); gfx.rect(cx, cy, bw, th, 0)
    if sel or hot then gfx.rect(cx + 1, cy + 1, bw - 2, th - 2, 0) end
    U.text(cx, cy + th, fit(nm, bw), nm == cur and U.CYAN or ((hot or sel) and U.AMBER or U.TEXT))
    if hot then hover = { kind = 'preset', i = i, name = nm, tip = 'preset ' .. nm .. ': click - take it (layers, effects, values, LFOs, track routes)' } end
    if hint then hint('visor', cx, cy, bw, th, { kind = 'preset', i = i, name = nm }) end
  end
  return hover
end

function VZ.draw(L, U, x, y, w, h, focused, env, fit, hint)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local ms = U.measure
  local hover
  env = env or {}
  VZ.last_env = env
  local st = VZ.st
  local pad, rh = L.pad, L.rh
  -- верхняя строка: кнопки (буквами), не влезло — следующая строка
  local bx, by = x + pad, y
  local function room(wd) if bx + wd > x + w - pad and bx > x + pad then bx, by = x + pad, by + rh + 2 end end
  local function b(label, on, kind, tip)
    local bw = ms(label) + 2 * pad
    room(bw)
    if by + rh > y + h then return end            -- 11 окт: перенос ниже дна панели — не рисовать
    local hot = mx >= bx and mx < bx + bw and my >= by and my < by + rh
    U.set(on and U.tint(U.AMBER, 0.25) or (hot and U.mix(U.BG, U.TEXT, 0.16) or U.BG)); gfx.rect(bx, by, bw, rh, 1)
    U.set(on and U.AMBER or U.LINE); gfx.rect(bx, by, bw, rh, 0)
    U.text(bx + pad, by, label, on and U.AMBER or (hot and U.TEXT or U.GREY))
    if hot then hover = { kind = kind, tip = tip } end
    if hint then hint('visor', bx, by, bw, rh, kind) end
    bx = bx + bw + pad
  end
  b(env.on and 'on' or 'off', env.on, 'power', 'send the picture state to the visualizer page (p); off - the page keeps the last frame')
  b('web page', false, 'open', 'open the visualizer page in the browser (o): localhost:8080/isf/index.html - the picture is there; F fullscreen, H hides the HUD')
  -- 11 окт: пресет, как у эффекта в DSP: < имя > — щелчок по имени — сетка с превью, стрелки — соседний
  do
    local nm = st.preset or 'preset'
    local aw = ms('<') + 2 * pad
    local tw = math.min(ms(nm), ms('W') * 16) + 2 * pad
    room(2 * aw + tw)
    local parts = { { '<', 'pprev', bx, aw, 'previous preset (N)' }, { nm, 'pgal', bx + aw, tw, 'presets of ReaVisor with previews (i): click one to take it' }, { '>', 'pnext', bx + aw + tw, aw, 'next preset (n)' } }
    for _, pp in ipairs(by + rh <= y + h and parts or {}) do
      local hot = mx >= pp[3] and mx < pp[3] + pp[4] and my >= by and my < by + rh
      local on = pp[2] == 'pgal' and VZ.gal
      U.set(on and U.tint(U.AMBER, 0.25) or (hot and U.mix(U.BG, U.TEXT, 0.16) or U.BG)); gfx.rect(pp[3], by, pp[4], rh, 1)
      U.set(U.LINE); gfx.rect(pp[3], by, pp[4], rh, 0)
      U.text(pp[3] + pad, by, fit(pp[1], pp[4] - 2 * pad), hot and U.AMBER or (pp[2] == 'pgal' and (st.preset and U.CYAN or U.GREY) or U.GREY))
      if hot then hover = { kind = pp[2], tip = pp[5] } end
      if hint then hint('visor', pp[3], by, pp[4], rh, pp[2]) end
    end
    bx = bx + 2 * aw + tw + pad
  end
  b('save', false, 'psave', 'save the look as a preset (:vzsave name): layers, effects, values, LFOs, the matrix - ReaVisor sees it too')
  b(st.blend == 'add' and 'add' or 'mix', st.blend == 'add', 'blend', 'how layers stack (b): mix - by fade, add - light adds up')
  b('scene', env.scene_has, 'scene_save', 'save everything as the scene of the cursor slot ' .. (env.scene or '') .. ' (s); with follow it comes back when the playhead enters the slot')
  b('follow', st.follow, 'follow', 'scenes follow the slot under the playhead (S)')
  b('mod matrix', VZ.mxv, 'mxtoggle', 'modulation matrix (M): sources - LFO 1-4, track peaks, macros - into the parameters of the selected layer')
  b('macros', (env.macros or 0) > 0, 'macros', (env.macros or 0) > 0 and 'macros M1..M16 (jf_visor_macros on the master): click - pick one to show as an automation column of the master' or 'macros: click - put 16 knobs (jf_visor_macros) on the master; their automation in the tracker drives the matrix rows M1..M16')
  b(('res %d%%'):format(math.floor((st.scale or 0.3) * 100 + 0.5)), false, 'res', 'render resolution of the page: click - next (lower is lighter for the GPU)')
  b(('fps %d'):format(st.fps or 60), false, 'fps', 'frame rate cap of the page: click - next')
  local top = by + rh + 4
  if top + rh > y + h then return hover end        -- 11 окт: под кнопками места нет
  -- левая колонка: список
  local list = VZ.list()
  VZ.sel = math.max(1, math.min(#list, VZ.sel))
  local lw = math.max(ms('W') * 18, math.min(math.floor(w * 0.36), ms('W') * 34))
  local fw = ms('W') * 5
  -- 13 окт: живая картинка страницы — внизу левой колонки, всегда (env.live рисует кадр)
  -- во всю ширину колонки, без рамки — часть панели; от дна отступ pad (не налезает на границу)
  local lvw = lw - 1
  local lvh = lvw * 9 // 16
  local lbot = y + h
  if env.live and y + h - top >= lvh + 4 * rh then
    local lx, lyy = x + 1, y + h - lvh - pad
    lbot = lyy - pad
    U.set(U.mix(U.BG, U.TEXT, 0.04)); gfx.rect(lx, lyy, lvw, lvh, 1)
    if not env.live(lx, lyy, lvw, lvh) then
      U.text(lx + pad, lyy + (lvh - rh) // 2, fit(env.on and 'waiting for the page (o opens it)' or 'off - p sends the picture', lvw - 2 * pad), U.DIM)
    end
    if mx >= lx and mx < lx + lvw and my >= lyy and my < lyy + lvh then hover = { kind = 'open', tip = 'the picture of the page now - click opens the page (o)' } end
  end
  local nrow = math.max(1, math.floor((lbot - top) / rh))
  local ly = top
  local last_kind
  for i, e in ipairs(list) do
    -- заголовки групп — по строке перед первой строкой группы
    local grp = (e.kind == 'layer' or e.kind == 'addl') and 'layers' or (e.kind == 'fx' or e.kind == 'addfx') and 'effects' or nil
    if grp and grp ~= last_kind then
      if ly + rh > lbot then break end
      U.text(x + pad, ly, grp, U.GREY); ly = ly + rh; last_kind = grp
    elseif e.kind == 'master' then last_kind = 'master' end
    if ly + rh > lbot then break end
    local hot = mx >= x and mx < x + lw and my >= ly and my < ly + rh
    local sel = i == VZ.sel
    if sel then U.set(focused and U.mix(U.BG, U.TEXT, 0.14) or U.mix(U.BG, U.TEXT, 0.07)); gfx.rect(x + 1, ly, lw - 2, rh, 1) end
    local tx = x + pad
    if e.kind == 'addl' or e.kind == 'addfx' then
      -- 13 окт: доступная команда — тусклее; клавиша в скобках — только при хинтах
      local hk = env and env.hints and (e.kind == 'addl' and ' (a)' or ' (e)') or ''
      U.text(tx + ms('00 '), ly, (e.kind == 'addl' and '+ shader' or '+ effect') .. hk, hot and U.AMBER or U.DIM)
      if hot then hover = { kind = 'row', i = i, tip = e.kind == 'addl' and 'add a shader layer (a) - fzf over the ReaVisor shaders' or 'add an effect to the chain (e) - it runs on the mix of the layers' } end
    else
      local on = e.slot.on ~= false
      local num = e.kind == 'master' and 'M ' or ('%d '):format(e.i)
      local gw = ms('00 ')
      local ghot = hot and mx < tx + gw
      U.text(tx, ly, num, on and (ghot and U.AMBER or U.TEXT) or U.DIM)
      local nm = e.kind == 'master' and 'master' or short(e.slot.fn)
      local nx = tx + gw
      local right = x + lw - pad - (e.kind == 'layer' and (fw + pad) or 0)
      U.text(nx, ly, fit(nm, right - nx), on and ((hot or sel) and U.AMBER or U.TEXT) or U.GREY)
      local fhot
      if e.kind == 'layer' then
        local fx0 = x + lw - pad - fw
        U.set(U.DIM); gfx.rect(fx0, ly + math.floor(rh / 2) - 1, fw, 2, 1)
        U.set(on and U.CYAN or U.GREY); gfx.rect(fx0, ly + 4, math.max(1, math.floor((e.slot.fade or 1) * fw + 0.5)), rh - 8, 1)
        fhot = hot and mx >= fx0
        if fhot then hover = { kind = 'row', i = i, fade = math.max(0, math.min(1, (mx - fx0) / fw)), fx0 = fx0, fw = fw, tip = 'layer level - drag / wheel (h l)' } end
      end
      if hot and not fhot then
        hover = { kind = 'row', i = i, gate = ghot or nil,
                  tip = ghot and 'on / off (Space)' or (e.kind == 'master' and 'master stage: brightness, contrast, fade … of the whole picture'
                        or (e.kind == 'layer' and 'shader layer: Enter replace, x remove, < > order, R random' or 'effect: Enter replace, x remove, < > order')) }
      end
    end
    ly = ly + rh
  end
  -- 11 окт: сетка пресетов — справа всегда, если панель широкая (zz), иначе по i вместо параметров
  local wide = w - lw >= ms('W') * 110
  if wide or VZ.gal then
    local gw = wide and math.floor((w - lw) * 0.45) or (w - lw - pad)
    local gx = x + w - gw
    U.set(U.LINE); gfx.rect(gx - math.floor(pad / 2) - 1, top, 1, y + h - top, 1)
    local gh = VZ.draw_gallery(L, U, gx, top, gw - pad, y + h - top, focused, env, fit, hint)
    if gh then hover = gh end
    if not wide then return hover end
    w = w - gw
  end
  -- 13 окт: матрица модуляций всегда видна — под параметрами (M — клавиши в неё и обратно)
  local mx0 = x + lw + pad
  if y + h - top >= 12 * rh then
    local nsrc = #VZ.sources(env)
    local mhh = math.min((nsrc + 1) * rh + 2 + (VZ.vtext and U.measure('WWWWWWW') or 0), (y + h - top) * 45 // 100)   -- 13 окт: + вертикальные подписи
    -- 13 окт: высота матрицы — тянуть линию над ней (VZ.mx_frac — доля области)
    if VZ.mx_frac then mhh = math.floor((y + h - top) * VZ.mx_frac) end
    mhh = math.max(mhh, 4 * rh)
    mhh = math.min(mhh, y + h - top - 4 * rh)
    local mtop = y + h - mhh - pad                -- отступ от дна: последний ряд не на границе
    do
      local ly = mtop - pad // 2 - 1
      local mxp, myp = gfx.mouse_x, gfx.mouse_y
      local near = mxp >= mx0 and mxp < x + w and math.abs(myp - ly) <= 3
      local down = gfx.mouse_cap & 1 == 1
      if VZ.mx_drag and not down then VZ.mx_drag = nil end
      if near and down and not VZ.mx_drag and not VZ.mx_down0 then VZ.mx_drag = true end
      VZ.mx_down0 = down
      if VZ.mx_drag then VZ.mx_frac = math.max(0.15, math.min(0.85, (y + h - pad - myp) / math.max(1, y + h - top))) end
      if near or VZ.mx_drag then U.set(U.AMBER); gfx.rect(mx0, ly - 1, x + w - mx0, 3, 1); hover = { kind = 'mxsplit', tip = 'drag: the modulation matrix taller / lower' } end
    end
    U.set(U.LINE); gfx.rect(mx0 - math.floor(pad / 2) - 1, top, 1, y + h - top, 1)
    gfx.rect(mx0 - math.floor(pad / 2) - 1, mtop - pad // 2 - 1, x + w - mx0 + math.floor(pad / 2) + 1, 1, 1)
    local mh = VZ.draw_matrix(L, U, mx0, mtop, x + w - mx0 - pad, mhh, focused and VZ.mxv, env, fit, hint)
    if mh then hover = mh end
    h = mtop - pad - y
    focused = focused and not VZ.mxv
  elseif VZ.mxv then
    U.set(U.LINE); gfx.rect(mx0 - math.floor(pad / 2) - 1, top, 1, y + h - top, 1)
    local mh = VZ.draw_matrix(L, U, mx0, top, x + w - mx0 - pad, y + h - top, focused, env, fit, hint)
    return mh or hover
  end
  -- справа: параметры выбранного
  local e = VZ.cur()
  local px0 = x + lw + pad
  U.set(U.LINE); gfx.rect(px0 - math.floor(pad / 2) - 1, top, 1, y + h - top, 1)
  local rows = e and e.rows or {}
  local pw = x + w - px0 - pad
  -- превью шейдера (картинка ReaVisor, если есть) — справа сверху, параметры обходят его
  local thw = 0
  if e and e.slot and e.kind ~= 'master' and env.thumb and pw > ms('W') * 50 then
    local tw2 = math.min(math.floor(pw * 0.3), (y + h - top) * 16 // 9)
    if tw2 >= ms('W') * 8 and env.thumb(e.kind == 'fx' and 'effects' or 'shaders', e.slot.fn, x + w - pad - tw2, top, tw2, tw2 * 9 // 16) then thw = tw2 + pad end
  end
  if not (e and e.slot) then
    U.text(px0, top, fit(e and (e.kind == 'addl' and 'Enter / a - pick a shader' or 'Enter / e - pick an effect') or '', pw), U.GREY)
    return hover
  end
  if #rows == 0 then
    U.text(px0, top, fit(e.kind == 'master' and 'no master.fs - is ReaVisor at reaper_www_root/isf?' or 'no parameters', pw - thw), U.GREY)
    return hover
  end
  VZ.psel = math.max(1, math.min(#rows, VZ.psel))
  local nvis = math.max(1, math.floor((y + h - top) / rh))
  if VZ.psel > VZ.pscroll + nvis then VZ.pscroll = VZ.psel - nvis end
  if VZ.psel <= VZ.pscroll then VZ.pscroll = math.max(0, VZ.psel - 1) end
  VZ.pscroll = math.max(0, math.min(VZ.pscroll, #rows - nvis))
  if U.vbar then U.vbar('visorp', px0, top, pw, nvis * rh, VZ.pscroll, nvis, #rows) end   -- 15 окт: длинному списку — полоса всегда
  local nw = 0
  for _, r in ipairs(rows) do nw = math.max(nw, ms(r.name .. (r.axis and (r.axis == 1 and '.x' or '.y') or ''))) end
  local pwr = pw - thw
  nw = math.min(nw, math.floor(pwr * 0.3))
  local vw = ms('-000.00')
  local sw = math.min(ms('>WWWWWWWW 100%'), math.floor(pwr * 0.28))
  for k = 1, nvis do
    local i = VZ.pscroll + k
    local row = rows[i]
    if not row then break end
    local ry = top + (k - 1) * rh
    local rowr = (ry < top + (thw > 0 and (thw - pad) * 9 // 16 + 2 or 0)) and (pwr) or pw
    local p = VZ.param(e.slot, row)
    local tx0 = px0 + nw + pad
    local tw = rowr - nw - vw - sw - 3 * pad
    local hot = mx >= px0 and mx < px0 + rowr and my >= ry and my < ry + rh
    local sel = i == VZ.psel
    if sel then U.set(focused and U.mix(U.BG, U.TEXT, 0.12) or U.mix(U.BG, U.TEXT, 0.06)); gfx.rect(px0 - 2, ry, rowr + 2, rh, 1) end
    local label = row.name .. (row.axis and (row.axis == 1 and '.x' or '.y') or '')
    U.text(px0, ry, fit(label, nw), (hot or sel) and U.AMBER or U.GREY)
    local vt
    if tw > 4 then
      if row.ty == 'f' then
        local n = (p.v - row.min) / (row.max - row.min)
        U.set(U.DIM); gfx.rect(tx0, ry + math.floor(rh / 2) - 1, tw, 2, 1)
        U.set(hot and U.AMBER or U.TEXT); gfx.rect(tx0, ry + 4, math.max(1, math.floor(n * tw + 0.5)), rh - 8, 1)
        if p.m then
          -- куда качает модуляция сейчас — тонкая метка
          local cur = (VZ.eval(row, p, env.t or 0, env.peak) - row.min) / (row.max - row.min)
          U.set(U.CYAN); gfx.rect(tx0 + math.floor(cur * (tw - 1) + 0.5), ry + 2, 1, rh - 4, 1)
        end
        vt = ('%.2f'):format(p.v)
      elseif row.ty == 'b' then vt = p.v >= 0.5 and 'on' or 'off'; U.text(tx0, ry, vt, p.v >= 0.5 and U.AMBER or U.GREY); vt = nil
      elseif row.ty == 'l' then U.text(tx0, ry, fit(row.labels and row.labels[math.floor(p.v)] or tostring(math.floor(p.v)), tw), U.TEXT)
      elseif row.ty == 'c' then
        gfx.set(p.v[1], p.v[2], p.v[3], 1); gfx.rect(tx0, ry + 3, math.min(tw, ms('WWWW')), rh - 6, 1)
        U.set(U.LINE); gfx.rect(tx0, ry + 3, math.min(tw, ms('WWWW')), rh - 6, 0)
      end
    end
    if vt then U.text(tx0 + tw + pad, ry, fit(vt, vw), U.GREY) end
    local sx = px0 + rowr - sw
    local stxt = VZ.src_text(p, env.tname)
    local shot = hot and mx >= sx
    if row.ty == 'f' then U.text(sx, ry, fit(stxt ~= '' and stxt or (shot and '+ mod (m)' or '--'), sw), stxt ~= '' and U.CYAN or (shot and U.AMBER or U.DIM)) end
    if hot then
      if shot and row.ty == 'f' then
        hover = { kind = 'param', i = i, src = true, tip = 'modulation: click / m - none > LFO > track peak; [ ] depth, { } rate, w shape' }
      else
        hover = { kind = 'param', i = i, x0 = tx0, w = math.max(1, tw), v = math.max(0, math.min(1, (mx - tx0) / math.max(1, tw))),
                  tip = label .. (row.ty == 'f' and (' %.3f .. %.3f - drag / wheel (Shift fine), 0 default; J K select, H L change'):format(row.min, row.max) or ' - click / H L change') }
      end
    end
  end
  return hover
end

return VZ
