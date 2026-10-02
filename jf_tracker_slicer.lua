-- jf_tracker_slicer.lua — виртуальная нарезка сэмпла (инструмента пула).
--
-- Слайс — не файл и не правка источника: таблица тайм-кодов в
-- P_EXT:jf_slices у item-инструмента (секунды от начала item) +
-- P_EXT:jf_slice_base (D_STARTOFFS на момент нарезки). Вставка слайса k —
-- копия item с D_STARTOFFS = base + t_k и D_LENGTH = t_{k+1} − t_k (с учётом
-- rate), P_EXT:jf_slice = k. В INSERT при выбранном нарезанном инструменте
-- верхний ряд q w e r t y u i o p вставляет слайсы 1..10; в колонке команд
-- Sxx — слайс xx (без нарезки — offset xx/256 источника, как в Renoise).
--
-- Слайсер живёт во вкладке «sample» верхней панели (S.draw_in): волна
-- горизонтально, маркеры слайсов, транзиенты (своя детекция по пикам PCM_Source_GetPeaks 500 Гц:
-- почти нативно — пики считает REAPER). Клавиши: 8 / 1 (16) / 3 (32) / 6 (64)
-- — ровная нарезка, t — по транзиентам, + − чувствительность, q…p — послушать
-- слайс, Enter — применить, Esc — закрыть, x — снять нарезку.

local S = {}
local R = reaper
local ctx
S.active = false
S.entry = nil
S.track = nil
S.slices = {}        -- секунды от начала item
S.trans = {}         -- найденные транзиенты (секунды)
S.sens = 0.5
S.mode = ''
S.env = nil          -- огибающая |пик| для волны и детекции
S.msg = ''
S.sel = nil          -- выделение { a, b } в секундах item (мышь / клавиши)
S.drag = nil         -- протяжка выделения ('sel') или вынос выделения ('out')
S.file_src = nil     -- PCM-источник файла браузера (один, старый уничтожается)
S.view = 'peaks'     -- вид волны: 'peaks' | 'spec' (спектральные пики REAPER: цвет по частоте, как в колонке трека)

function S.init(c) ctx = c end

-- огибающая пиков 500 Гц по окну item (источник от offs на len*rate секунд)
local function build_env(e)
  local src = (ctx and ctx.model and ctx.model.online_src) and ctx.model.online_src(e.src) or e.src
  if not src then return nil end
  local span = e.len * (e.rate or 1)
  local rate = 500
  local n = math.max(16, math.min(40000, math.floor(span * rate)))
  local buf = R.new_array(n * 2)
  buf.clear()
  local rv = R.PCM_Source_GetPeaks(src, rate, e.offs or 0, 1, n, 0, buf)
  local spl = rv & 0xfffff
  if spl == 0 then
    R.PCM_Source_BuildPeaks(src, 0)
    for _ = 1, 400 do if R.PCM_Source_BuildPeaks(src, 1) == 0 then break end end
    R.PCM_Source_BuildPeaks(src, 2)
    rv = R.PCM_Source_GetPeaks(src, rate, e.offs or 0, 1, n, 0, buf)
    spl = rv & 0xfffff
  end
  if spl == 0 then return nil end
  local t = buf.table()
  local env = { n = spl, rate = rate, span = span, v = {} }
  local raw = (rv >> 20) & 0xF ~= 0
  for i = 1, spl do
    local a, b = t[i], raw and t[i] or t[spl + i]
    env.v[i] = math.max(math.abs(a or 0), math.abs(b or 0))
  end
  return env
end

function S.open(entry, track)
  S.entry, S.track = entry, track
  S.env = build_env(entry)
  S.slices = {}
  for _, t in ipairs(entry.slices or {}) do S.slices[#S.slices + 1] = t end
  S.trans = {}
  S.mode = #S.slices > 0 and 'stored' or ''
  S.active = true
  S.msg = S.env and '' or 'no peaks (offline?)'
end

function S.close() S.active = false end

-- файл браузера в сэмпл-модуле: временная запись с PCM-источником (без item);
-- нарезка не сохраняется (некуда), зато выделение, превью, вставка и депо работают
function S.open_file(path, track)
  if S.file_src and S.file_src ~= (S.entry and S.entry.src) then pcall(R.PCM_Source_Destroy, S.file_src) end
  local src = R.PCM_Source_CreateFromFile(path)
  if not src then S.msg = 'cannot open ' .. path; return false end
  S.file_src = src
  local len = R.GetMediaSourceLength(src) or 0
  local e = { name = path:match('[^/]+$') or path, path = path, src = src, offs = 0, len = len, rate = 1, guid = 'file:' .. path, file = true }
  S.entry, S.track = e, track
  S.env = build_env(e)
  S.slices, S.trans, S.mode = {}, {}, 'file'
  S.sel = nil
  S.active = true
  S.msg = ''
  return true
end

function S.select_all() if S.entry then S.sel = { a = 0, b = S.entry.len } end end

-- мышь по волне: доля ширины → секунды; down внутри выделения = вынос
function S.mouse_down(frac)
  if not S.entry then return end
  local t = frac * S.entry.len
  if S.sel and t >= math.min(S.sel.a, S.sel.b) and t <= math.max(S.sel.a, S.sel.b) and S.sel.b ~= S.sel.a then
    S.drag = { kind = 'out', x0 = gfx.mouse_x, y0 = gfx.mouse_y, active = false }
  else
    S.sel = { a = t, b = t }
    S.drag = { kind = 'sel' }
  end
end
-- перетаскивание слайс-маркера k (просьба 1 окт): между соседями, commit на отпускании
function S.slice_down(k)
  if not S.entry or not S.slices[k] then return end
  S.drag = { kind = 'slice', k = k }
end
function S.mouse_move(frac)
  if S.drag and S.drag.kind == 'slice' and S.entry and frac then
    local k = S.drag.k
    local lo = (S.slices[k - 1] or 0) + 0.002
    local hi = (S.slices[k + 1] or S.entry.len) - 0.002
    S.slices[k] = math.max(lo, math.min(hi, frac * S.entry.len))
  end
  if S.drag and S.drag.kind == 'sel' and S.entry and frac then S.sel.b = math.max(0, math.min(S.entry.len, frac * S.entry.len)) end
  if S.drag and S.drag.kind == 'out' and not S.drag.active and (math.abs(gfx.mouse_x - S.drag.x0) > 6 or math.abs(gfx.mouse_y - S.drag.y0) > 6) then S.drag.active = true end
end
function S.mouse_up()
  local d = S.drag
  S.drag = nil
  if d and d.kind == 'slice' then commit(); S.msg = ('slice %d moved'):format(d.k); return d end
  if S.sel and S.sel.b < S.sel.a then S.sel.a, S.sel.b = S.sel.b, S.sel.a end
  if S.sel and S.sel.b - S.sel.a < 0.001 then S.sel = nil end
  return d
end
function S.span() if S.sel then return math.min(S.sel.a, S.sel.b), math.max(S.sel.a, S.sel.b) end end

-- ровная нарезка: n кусков по длине item (в секундах item, не источника)
-- нарезка виртуальная → применяется сразу (P_EXT), Enter не нужен
local function commit()
  if S.entry and S.entry.item and ctx.edit and ctx.edit.set_slices then
    ctx.edit.set_slices(S.entry.item, S.slices)
    S.entry.slices = {}
    for _, t in ipairs(S.slices) do S.entry.slices[#S.entry.slices + 1] = t end
    S.msg = ('%d slices'):format(#S.slices)
  end
end
S.commit = commit

function S.equal(n)
  S.slices = {}
  local len = S.entry.len
  for k = 0, n - 1 do S.slices[#S.slices + 1] = len * k / n end
  S.mode = 'equal ' .. n
  commit()
end

-- транзиенты: рост огибающей над локальным фоном, порог и отношение от
-- чувствительности, минимальный зазор 40 мс. Тайм-коды — в секундах item
-- (огибающая идёт по источнику с rate, пересчитываем).
function S.detect()
  S.trans = {}
  S.trans_amp = {}
  local env = S.env
  if not env then return end
  local thr = 0.04 + (1 - S.sens) * 0.30
  local ratio = 1.6 + (1 - S.sens) * 2.5
  local gap = math.floor(env.rate * 0.04)
  local win = 12
  local last = -gap
  for i = win + 1, env.n do
    local v = env.v[i]
    if v > thr and i - last > gap then
      local bg = 0
      for j = i - win, i - 1 do bg = bg + env.v[j] end
      bg = bg / win
      if v > bg * ratio then
        local t_src = (i - 1) / env.rate
        S.trans[#S.trans + 1] = t_src / (S.entry.rate or 1)
        -- громкость атаки (~30 мс после начала) — для smart quantize: сильный / слабый
        local a = 0
        for j = i, math.min(env.n, i + math.floor(env.rate * 0.03)) do if env.v[j] > a then a = env.v[j] end end
        S.trans_amp = S.trans_amp or {}
        S.trans_amp[#S.trans] = a
        last = i
      end
    end
  end
end

function S.use_transients()
  S.detect()
  S.slices = {}
  if #S.trans == 0 or S.trans[1] > 0.01 then S.slices[1] = 0 end
  for _, t in ipairs(S.trans) do S.slices[#S.slices + 1] = t end
  S.mode = ('transients %d (sens %.2f)'):format(#S.slices, S.sens)
  commit()
end

function S.apply()
  if not S.entry then return end
  ctx.edit.set_slices(S.entry.item, S.slices)
  S.msg = ('%d slices stored'):format(#S.slices)
  S.active = false
end

function S.clear()
  if not S.entry or not S.entry.item then return end
  ctx.edit.set_slices(S.entry.item, {})
  S.slices = {}; S.mode = ''; S.entry.slices = nil
  S.msg = 'slices removed'
end

-- границы слайса k (секунды item): start, end
function S.bounds(slices, k, len)
  local t0 = slices[k]
  if not t0 then return nil end
  local t1 = slices[k + 1] or len
  return t0, t1
end

function S.preview(k)
  local t0, t1 = S.bounds(S.slices, k, S.entry.len)
  if not t0 then return end
  ctx.preview_slice(S.track, S.entry, t0, t1)
end

local UPPER = { q = 1, w = 2, e = 3, r = 4, t = 5, y = 6, u = 7, i = 8, o = 9, p = 10 }

-- клавиши; true — съедена
function S.key(c)
  local ch = c < 256 and string.char(c) or ''
  local a, b = S.span()
  if c == 27 then if S.sel then S.sel = nil else S.close() end
  elseif c == 13 then
    -- Enter: есть выделение — вставить в строку курсора; иначе применить нарезку
    if a then ctx.drop_span_cursor(S.entry, a, b) else commit() end
  elseif ch == 'a' then S.select_all()
  elseif ch == 'v' then S.cycle_view()
  elseif ch == 'D' or (ch == 'd' and a) then if a then ctx.depot_span(S.entry, a, b) end
  elseif ch == ' ' and a then ctx.preview_slice(S.track, S.entry, a, b)
  elseif ch == '[' and a then S.sel.a = math.max(0, a - S.entry.len * 0.01); S.sel.b = b
  elseif ch == ']' and a then S.sel.a = a; S.sel.b = math.min(S.entry.len, b + S.entry.len * 0.01)
  elseif S.entry and S.entry.file and (ch == '8' or ch == '1' or ch == '3' or ch == '6' or ch == '4' or ch == '2' or ch == 'x' or ch == 't') then
    S.msg = 'file: slices live on items - drag selection to a track or D: to depot, then slice'
  elseif ch == '8' then S.equal(8)
  elseif ch == '1' then S.equal(16)
  elseif ch == '3' then S.equal(32)
  elseif ch == '6' then S.equal(64)
  elseif ch == '4' then S.equal(4)
  elseif ch == '2' then S.equal(2)
  elseif ch == 'd' then S.detect(); S.mode = ('detect %d (sens %.2f)'):format(#S.trans, S.sens)
  elseif ch == '+' or ch == '=' then S.sens = math.min(1, S.sens + 0.05); if S.mode:match('^transients') then S.use_transients() else S.detect(); S.mode = ('detect %d (sens %.2f)'):format(#S.trans, S.sens) end
  elseif ch == '-' then S.sens = math.max(0, S.sens - 0.05); if S.mode:match('^transients') then S.use_transients() else S.detect(); S.mode = ('detect %d (sens %.2f)'):format(#S.trans, S.sens) end
  elseif ch == 'x' then S.clear()
  elseif ch == 'Q' then S.smart_quantize()                              -- smart quantize (2 окт)
  elseif ch == 't' or ch == 's' then S.use_transients()                -- s: нарезать по транзиентам (2 окт)
  elseif (ch == '<' or ch == '>' or ch == ',' or ch == '.') and S.entry and S.entry.item then
    S.vol_step((ch == '>' or ch == '.') and 1 or -1)
  elseif ch == 'n' and S.entry and S.entry.item then ctx.edit.normalize(S.entry.item); S.msg = 'normalized (peak 0 dB)'
  elseif UPPER[ch] then S.preview(UPPER[ch])
  elseif ch == ' ' then ctx.edit.play_stop()
  else return true end     -- всё остальное тоже съедаем: оверлей модальный
  return true
end

-- Вид сэмпла во вкладке «sample» верхней панели (прямоугольник x,y,w,h).
-- S.active и тот же инструмент — режим правки (рабочие слайсы, транзиенты,
-- подсказка клавиш); иначе — инструмент e как есть, с сохранёнными слайсами.
-- ── спектрограмма: аксессор take → FFT 512 (Ханн) → 64 лог-полосы ──────
local function fft(re, im, n)
  local j = 1
  for i = 1, n do
    if i < j then re[i], re[j] = re[j], re[i]; im[i], im[j] = im[j], im[i] end
    local m = n // 2
    while m >= 1 and j > m do j = j - m; m = m // 2 end
    j = j + m
  end
  local len = 2
  while len <= n do
    local ang = -2 * math.pi / len
    local wr, wi = math.cos(ang), math.sin(ang)
    for i = 1, n, len do
      local cr, ci = 1, 0
      for k = 0, len // 2 - 1 do
        local a, b = i + k, i + k + len // 2
        local tr = re[b] * cr - im[b] * ci
        local ti = re[b] * ci + im[b] * cr
        re[b], im[b] = re[a] - tr, im[a] - ti
        re[a], im[a] = re[a] + tr, im[a] + ti
        cr, ci = cr * wr - ci * wi, cr * wi + ci * wr
      end
    end
    len = len * 2
  end
end

-- громкость item ±d dB (клавиши < >, колесо над полем vol)
function S.vol_step(d)
  local e = S.entry
  if not e or not e.item then return end
  local db = (e.vol or 1) > 0 and 20 * math.log(e.vol or 1, 10) or -150
  db = math.max(-60, math.min(24, math.floor(db + 0.5) + d))
  ctx.edit.item_vol(e.item, db)
  e.vol = 10 ^ (db / 20)     -- до следующего снимка
  S.msg = ('vol %+.1f dB'):format(db)
end

-- кнопка нарезки (2 окт): равные части / транзиенты / чувствительность / сброс
function S.button(id)
  if not S.entry or S.entry.file then return end
  local n = id:match('^eq(%d+)$')
  if n then S.equal(tonumber(n))
  elseif id == 'trans' then S.use_transients()
  elseif id == 'sens-' or id == 'sens+' then
    S.sens = math.max(0, math.min(1, S.sens + (id == 'sens+' and 0.05 or -0.05)))
    S.use_transients()
  elseif id == 'clear' then S.clear()
  elseif id == 'quant' then S.smart_quantize() end
end

-- smart quantize (2 окт): транзиенты сэмпла → stretch-маркеры, сильные к
-- ближайшим долям, слабые к шестнадцатым; длина — до целых тактов / долей
function S.smart_quantize()
  local e = S.entry
  if not e or e.file or not e.item then S.msg = 'quantize: open an instrument (not a browser file)'; return end
  S.detect()
  if #S.trans == 0 then S.msg = 'quantize: no transients (sens+ for more)'; return end
  local hits = {}
  for k, t in ipairs(S.trans) do hits[#hits + 1] = { t = t, amp = (S.trans_amp or {})[k] or 0 } end
  local n, kept, newlen = ctx.edit.smart_quantize(e.item, hits)
  S.msg = n and ('quantized: %d of %d transients, length %.3fs'):format(kept or 0, #hits, newlen or 0) or 'quantize failed'
end

function S.cycle_view()
  S.view = S.view == 'peaks' and 'spec' or 'peaks'
  return S.view
end

-- zone = { a, b, inst } — играемая зона (секунды e) выбранного инструмента,
-- когда e — его исходник (слайс/кусок показывается на фоне целого сэмпла)
function S.draw_in(U, L, x, y, w, h, e, track, zone)
  if not e then U.text(x, y, 'no instrument', U.GREY); return end
  local editing = S.active and S.entry and S.entry.item == e.item
  local rh = L.rh
  local title = editing
    and ('%s  (%.3fs)  %d slices%s'):format(e.name, e.len, #S.slices, S.mode ~= '' and ('  - ' .. S.mode) or '')
    or ('%s  offs %.3f  len %.3f  rate %.2f%s'):format(e.name, e.offs or 0, e.len or 0, e.rate or 1,
        e.slices and ('  slices ' .. #e.slices) or '')
  if zone then title = title .. ('  [inst %02d plays %.3f-%.3fs]'):format(zone[3] or 0, zone[1], zone[2]) end
  -- кнопки вида справа в заголовке
  local vx = x + w
  local hover_view
  for _, v in ipairs({ 'spec', 'peaks' }) do
    local bw = U.measure(v) + 2 * L.pad
    vx = vx - bw
    local on = S.view == v
    local hot = gfx.mouse_x >= vx and gfx.mouse_x < vx + bw and gfx.mouse_y >= y and gfx.mouse_y < y + rh
    U.set(on and U.tint(U.CYAN, 0.3) or U.BG); gfx.rect(vx, y, bw, rh, 1)
    U.set(on and U.CYAN or U.LINE); gfx.rect(vx, y, bw, rh, 0)
    U.text(vx + L.pad, y + 1, v, on and U.CYAN or (hot and U.TEXT or U.GREY))
    if hot then hover_view = v end
    if ctx.hint then ctx.hint('sampleview', vx, y, bw, rh, v) end
    vx = vx - 2
  end
  if e.muted then title = title .. '  (muted)' end
  U.text(x, y, ctx.fit(title, vx - x - L.pad), editing and U.AMBER or U.TEXT)
  local hint = editing
    and (e.file and 'Enter: insert @cursor  D: to depot  a: all  Space: play  [ ]: edges'
         or '2/4/8 1(16) 3(32) 6(64) equal  t transients (+ - sens)  x clear  v view')
    or 'dblclick / :slice / \\is — edit slices;  q..p insert slices (INSERT)  drag: select → drop on track'
  -- громкость item и нормализация — справа в строке подсказки (1 окт)
  local hover_vol, hover_norm
  local hint_w = w
  if S.show_vol and editing and e.item and e.vol then    -- громкость переехала в панель свойств (2 окт)
    local db = e.vol > 0 and 20 * math.log(e.vol, 10) or -150
    local nb = 'normalize'
    local nbw = U.measure(nb) + 2 * L.pad
    local nx = x + w - nbw
    local hot = gfx.mouse_x >= nx and gfx.mouse_x < nx + nbw and gfx.mouse_y >= y + rh and gfx.mouse_y < y + 2 * rh
    U.set(hot and U.tint(U.AMBER, 0.2) or U.BG); gfx.rect(nx, y + rh, nbw, rh, 1)
    U.set(U.LINE); gfx.rect(nx, y + rh, nbw, rh, 0)
    U.text(nx + L.pad, y + rh + 1, nb, hot and U.AMBER or U.GREY)
    if hot then hover_norm = true end
    if ctx.hint then ctx.hint('samplenorm', nx, y + rh, nbw, rh, true) end
    local vs = ('vol %+.1f dB'):format(db)
    local vw = U.measure(vs) + 2 * L.pad
    local vx = nx - vw - L.pad
    local hotv = gfx.mouse_x >= vx and gfx.mouse_x < vx + vw and gfx.mouse_y >= y + rh and gfx.mouse_y < y + 2 * rh
    U.set(hotv and U.tint(U.AMBER, 0.2) or U.BG); gfx.rect(vx, y + rh, vw, rh, 1)
    U.set(U.LINE); gfx.rect(vx, y + rh, vw, rh, 0)
    U.text(vx + L.pad, y + rh + 1, vs, math.abs(db) > 0.05 and U.AMBER or U.GREY)
    if hotv then hover_vol = true end
    if ctx.hint then ctx.hint('samplevol', vx, y + rh, vw, rh, true) end
    hint_w = vx - x - L.pad
  end
  -- кнопки нарезки (2 окт): вместо строки-подсказки у инструмента (не у файла
  -- браузера). Клик по кнопке открывает правку этого сэмпла, если она не открыта.
  local hover_sbtn
  if not e.file and e.item then
    local bx = x
    local BTN = { { '2', 'eq2' }, { '4', 'eq4' }, { '8', 'eq8' }, { '16', 'eq16' }, { '32', 'eq32' }, { '64', 'eq64' },
                  { 'transients', 'trans' }, { 'sens-', 'sens-' }, { 'sens+', 'sens+' }, { 'clear', 'clear' }, { 'quantize', 'quant' } }
    U.text(bx, y + rh, 'slice', U.GREY); bx = bx + U.measure('slice') + L.pad
    for _, b in ipairs(BTN) do
      local bw = U.measure(b[1]) + 2 * L.pad
      if bx + bw > x + hint_w then break end
      local hot = gfx.mouse_x >= bx and gfx.mouse_x < bx + bw and gfx.mouse_y >= y + rh and gfx.mouse_y < y + 2 * rh
      U.set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, y + rh, bw, rh, 1)
      U.set(hot and U.AMBER or U.LINE); gfx.rect(bx, y + rh, bw, rh, 0)
      U.text(bx + L.pad, y + rh + 1, b[1], hot and U.AMBER or U.TEXT)
      if hot then hover_sbtn = b[2] end
      if ctx.hint then ctx.hint('slicebtn', bx, y + rh, bw, rh, b[2]) end
      bx = bx + bw + 2
    end
    if editing and #S.trans > 0 then U.text(bx + L.pad, y + rh + 1, ctx.fit(('sens %.2f'):format(S.sens), x + hint_w - bx - L.pad), U.GREY) end
  else
    U.text(x, y + rh, ctx.fit(hint, hint_w), U.GREY)
  end
  -- волна: peaks / spec — нативные спектральные пики REAPER, цвет той же
  -- функцией, что колонка волны трека (ctx.spec_colour); спектрограмма
  -- убрана 1 окт
  local wy, wh = y + 2 * rh + 2, h - 3 * rh - 4
  if wh < 6 then return end
  U.set(U.PANEL); gfx.rect(x, wy, w, wh, 1)
  local cy, hh = wy + wh / 2, wh / 2 - 1
  local base = U.readable(U.theme('col_tr1_peaks', { 0.55, 0.62, 0.70 }), U.BG, 4.0)
  if e.muted then base = U.mix(base, U.BG, 0.45) end      -- заглушённый — волна тусклее
  U.set(base)
  local env = editing and S.view == 'peaks' and S.env or nil
  if S.view == 'spec' and ctx.peaks then
    local pk = ctx.peaks(e, w, true)
    if pk and pk.n > 0 then
      for px = 0, w - 1 do
        local idx = math.floor(px / w * pk.n) + 1
        local a, b = pk.min[idx] or 0, pk.max[idx] or 0
        if b - a < 0.02 then a, b = -0.01, 0.01 end
        local cc = (pk.spec and ctx.spec_colour) and ctx.spec_colour(pk.spec[idx]) or base
        if e.muted then cc = U.mix(cc, U.BG, 0.45) end
        gfx.set(cc[1], cc[2], cc[3], 1)
        gfx.line(x + px, cy - b * hh, x + px, cy - a * hh)
      end
    else gfx.line(x, cy, x + w, cy) end
  elseif env and env.n > 0 then
    for px = 0, w - 1 do
      local i0 = math.floor(px / w * env.n) + 1
      local i1 = math.floor((px + 1) / w * env.n)
      local m = 0
      for i = i0, math.max(i0, i1) do if env.v[i] and env.v[i] > m then m = env.v[i] end end
      gfx.line(x + px, cy - m * hh, x + px, cy + m * hh)
    end
  else
    local pk = ctx.peaks and ctx.peaks(e, w)
    S.dbg = ('sample w=%d src=%s len=%.3f rate=%.2f offs=%.3f pk=%s guid=%s'):format(w, tostring(e.src), e.len or -1, e.rate or -1, e.offs or -1, pk and pk.n or 'nil', tostring(e.guid))
    if pk and pk.n > 0 then
      for px = 0, w - 1 do
        local idx = math.floor(px / w * pk.n) + 1
        local a, b = pk.min[idx] or 0, pk.max[idx] or 0
        if b - a < 0.02 then a, b = -0.01, 0.01 end
        gfx.line(x + px, cy - b * hh, x + px, cy - a * hh)
      end
    else gfx.line(x, cy, x + w, cy) end
  end
  -- позиция проигрывания файла из браузера (превью) и на большой волне (2 окт)
  if e.file and ctx.preview_pos then
    local pos, plen, ppath = ctx.preview_pos()
    if pos and ppath == e.path and (e.len or 0) > 0 then
      local px = x + math.floor(math.max(0, math.min(1, pos / e.len)) * (w - 1))
      U.set(U.AMBER); gfx.rect(px, wy, 1, wh, 1)
    end
  end
  -- транзиенты (только в правке) и слайсы с буквами
  local len = e.len > 0 and e.len or 1
  if editing then
    U.set(U.GREY)
    for _, t in ipairs(S.trans) do
      local px = x + math.floor(t / len * w)
      gfx.line(px, wy, px, wy + 6); gfx.line(px, wy + wh - 6, px, wy + wh)
    end
  end
  -- играемая зона исходника: чуть светлее фон и края
  if zone then
    local za, zb = math.max(0, math.min(len, zone[1])), math.max(0, math.min(len, zone[2]))
    local px0, px1 = x + math.floor(za / len * w), x + math.floor(zb / len * w)
    U.set(U.TEXT); gfx.a = 0.10; gfx.rect(px0, wy, math.max(1, px1 - px0), wh, 1); gfx.a = 0.55
    gfx.rect(px0, wy, 1, wh, 1); gfx.rect(math.max(px0, px1 - 1), wy, 1, wh, 1); gfx.a = 1
  end
  local slices = editing and S.slices or (e.slices or {})
  local hover_slice
  local in_wave = gfx.mouse_x >= x and gfx.mouse_x < x + w and gfx.mouse_y >= wy and gfx.mouse_y < wy + wh
  for k, t in ipairs(slices) do
    local px = x + math.floor(t / len * w)
    local hot = (in_wave and math.abs(gfx.mouse_x - px) <= 4) or (S.drag and S.drag.kind == 'slice' and S.drag.k == k)
    if hot then hover_slice = k end
    U.set(hot and U.TEXT or (k <= 10 and U.AMBER or U.CYAN)); gfx.rect(hot and (px - 1) or px, wy, hot and 3 or 1, wh, 1)
    local lbl = k <= 10 and ('qwertyuiop'):sub(k, k) or tostring(k)
    U.text(px + 3, wy + 1, lbl, hot and U.TEXT or (k <= 10 and U.AMBER or U.CYAN))
  end
  -- выделение (общее для правки и просмотра: S.entry совпадает с e)
  local sel = (S.entry and (S.entry == e or S.entry.item == e.item and e.item)) and S.sel or nil
  if sel then
    local a, b = math.min(sel.a, sel.b), math.max(sel.a, sel.b)
    local px0, px1 = x + math.floor(a / len * w), x + math.floor(b / len * w)
    U.set(U.AMBER); gfx.a = 0.25; gfx.rect(px0, wy, math.max(1, px1 - px0), wh, 1); gfx.a = 1
    gfx.rect(px0, wy, 1, wh, 1); gfx.rect(math.max(px0, px1 - 1), wy, 1, wh, 1)
  end
  local foot = editing and (S.msg ~= '' and S.msg or ('%d slices; Sxx in fx column = slice'):format(#S.slices))
    or (#slices > 0 and ('%d slices stored'):format(#slices) or '')
  if sel then foot = ('sel %.3fs - %.3fs (%.3fs)  Enter: insert @cursor  D: depot  drag out: to track   '):format(math.min(sel.a, sel.b), math.max(sel.a, sel.b), math.abs(sel.b - sel.a)) .. foot end
  U.text(x, wy + wh + 2, ctx.fit(foot, w), U.TEXT)
  if hover_view then return { e = e, view = hover_view } end
  if hover_sbtn then return { e = e, sbtn = hover_sbtn } end
  if hover_vol then return { e = e, vol = true } end
  if hover_norm then return { e = e, norm = true } end
  if gfx.mouse_x >= x and gfx.mouse_x < x + w and gfx.mouse_y >= wy and gfx.mouse_y < wy + wh then
    return { e = e, frac = (gfx.mouse_x - x) / w, slice = hover_slice }
  end
end

-- призрак выноса выделения
function S.draw_drag(U, L)
  if not (S.drag and S.drag.kind == 'out' and S.drag.active and S.sel) then return end
  local label = ('%s %.2fs'):format(S.entry and S.entry.name or 'sel', math.abs(S.sel.b - S.sel.a))
  local bw = U.measure(label) + 2 * L.pad
  local x, y = gfx.mouse_x + 12, gfx.mouse_y - L.rh // 2
  U.set(U.AMBER); gfx.rect(x, y, bw, L.rh, 1); U.set(U.BG); gfx.rect(x, y, bw, L.rh, 0)
  U.text(x + L.pad, y + 1, label, U.BG, U.AMBER)
end

return S
