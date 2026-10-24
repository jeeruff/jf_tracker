-- jf_tracker_slicer.lua — виртуальная нарезка сэмпла (инструмента пула).
--
-- Слайс — не файл и не правка источника: таблица тайм-кодов в
-- P_EXT:jf_slices у item-инструмента (секунды от начала item) +
-- P_EXT:jf_slice_base (D_STARTOFFS на момент нарезки). Вставка слайса k —
-- копия item с D_STARTOFFS = base + t_k и D_LENGTH = t_{k+1} − t_k (с учётом
-- rate), P_EXT:jf_slice = k. В INSERT при выбранном нарезанном инструменте
-- верхний ряд q w e r t y u i o p вставляет слайсы 1..10; в колонке команд
-- 0Sxx — слайс xx (без нарезки — offset xx/256 источника, как в Renoise).
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
S.snap = false       -- кнопка snap (2 окт): края выделения, маркеры и зона липнут к транзиентам / маркерам
S.sens = 0.5
S.mode = ''
S.env = nil          -- огибающая |пик| для волны и детекции
S.msg = ''
S.sel = nil          -- выделение { a, b } в секундах item (мышь / клавиши)
S.drag = nil         -- протяжка выделения ('sel') или вынос выделения ('out')
S.file_src = nil     -- PCM-источник файла браузера (один, старый уничтожается)
S.view = 'peaks'     -- вид волны: 'peaks' | 'spec' (спектральные пики REAPER: цвет по частоте, как в колонке трека)

function S.init(c) ctx = c end
local commit                 -- объявлен заранее: S.mouse_up зовёт его раньше определения (2 окт)

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
  local env = { n = spl, rate = rate, span = span, v = {}, max = 0 }
  local raw = (rv >> 20) & 0xF ~= 0
  for i = 1, spl do
    local a, b = t[i], raw and t[i] or t[n + i]     -- блок min — со сдвигом n запрошенных (4 окт)
    env.v[i] = math.max(math.abs(a or 0), math.abs(b or 0))
    if env.v[i] > env.max then env.max = env.v[i] end
  end
  return env
end

function S.open(entry, track)
  S.entry, S.track = entry, track
  S.env_t0, S.env_retry = nil, nil                  -- 9 окт: повтор пустой волны — заново для нового сэмпла
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

-- притяжение: ближайший транзиент или маркер слайса в пределах 8 px волны;
-- skip — номер маркера, который сейчас тянется (к себе не липнет)
function S.snap_t(t, skip)
  if not S.snap or not t then return t end
  local w = S.wave and S.wave.w or 0
  local thr = (w > 0 and S.wave.len and S.wave.len > 0) and (8 / w * ((S.wave.vb or S.wave.len) - (S.wave.va or 0))) or 0.02
  local best, bd = t, thr
  local function try(c) local dd = math.abs(c - t); if dd < bd then best, bd = c, dd end end
  for _, c in ipairs(S.trans or {}) do try(c) end
  local sl = (S.active and S.slices) or (S.entry and S.entry.slices) or {}
  for k, c in ipairs(sl) do if k ~= skip then try(c) end end
  return best
end

-- экран → секунды e по окну вида (зум); x вне волны — к краю окна
function S.x_to_t(mx)
  local wv = S.wave
  if not wv or wv.w <= 0 then return 0 end
  local va, vb = wv.va or 0, wv.vb or wv.len
  return va + math.max(0, math.min(1, (mx - wv.x) / wv.w)) * (vb - va)
end
-- зум у секунды t (k < 1 — ближе), прокрутка на долю окна
function S.zoom(k, t)
  local wv = S.wave; if not wv then return end
  local len = wv.len
  local va, vb = wv.va or 0, wv.vb or len
  local span = math.max(0.005, math.min(len, (vb - va) * k))
  t = t or (va + vb) / 2
  local f = (t - va) / math.max(1e-9, vb - va)
  local na = math.max(0, math.min(len - span, t - f * span))
  S.va, S.vb = na, na + span
  if span >= len - 1e-6 then S.va, S.vb = 0, nil end
end
function S.scroll(d)
  local wv = S.wave; if not wv then return end
  local len = wv.len
  local va, vb = wv.va or 0, wv.vb or len
  local span = vb - va
  local na = math.max(0, math.min(len - span, va + d * span))
  S.va, S.vb = na, na + span
end

function S.select_all() if S.entry then S.sel = { a = 0, b = S.entry.len } end end

-- мышь по волне: доля ширины → секунды; down внутри выделения = вынос
function S.mouse_down(frac)
  if not S.entry then return end
  local t = frac * S.entry.len
  if S.sel and t >= math.min(S.sel.a, S.sel.b) and t <= math.max(S.sel.a, S.sel.b) and S.sel.b ~= S.sel.a then
    S.drag = { kind = 'out', x0 = gfx.mouse_x, y0 = gfx.mouse_y, active = false }
  else
    t = S.snap_t(t)
    S.sel = { a = t, b = t }
    S.drag = { kind = 'sel' }
  end
end
-- перетаскивание слайс-маркера k (просьба 1 окт): между соседями, commit на отпускании
function S.slice_down(k)
  if not S.entry or not S.slices[k] then return end
  S.drag = { kind = 'slice', k = k, t0 = S.slices[k], mx0 = gfx.mouse_x }
  S.zedge_k, S.zedge_e = k, S.entry.item or S.entry.path   -- 10 окт: зум края показывает последнюю схваченную линию
  -- клик по линии слайса (5 окт) — этот слайс выбран в модуле слайсов
  if ctx and ctx.select_slice then ctx.select_slice(S.entry, k) end
  if ctx and ctx.set_last_slice then ctx.set_last_slice(k) end
end
function S.mouse_move(frac)
  if S.drag and S.drag.kind == 'slice' and S.entry and frac then
    local k = S.drag.k
    local lo = S.slices[k - 1] and (S.slices[k - 1] + 0.002) or 0   -- 11 окт: первый слайс — до самого нулевого сэмпла
    local hi = (S.slices[k + 1] or S.entry.len) - 0.002
    -- 10 окт: Shift — fine, как в зуме: мышь двигает линию в 10 раз медленнее от места, где нажат Shift;
    -- отпустил Shift — линия не прыгает к мыши, смещение остаётся
    local d, len = S.drag, S.entry.len
    local t
    if (gfx.mouse_cap & 8) == 8 then
      if not d.fa then d.fa, d.ft = frac, S.slices[k] end
      t = d.ft + (frac - d.fa) * len * 0.1
    else
      if d.fa then d.off = S.slices[k] - frac * len; d.fa = nil end
      t = S.snap_t(frac * len + (d.off or 0), k)
    end
    S.slices[k] = math.max(lo, math.min(hi, t))
    if math.abs(S.slices[k] - (S.drag.t0 or 0)) > 1e-6 then S.roll(S.slices[k], S.line_is_end(S.drag.t0)) end   -- 10 окт: roll
  end
  if S.drag and S.drag.kind == 'sel' and S.entry and frac then S.sel.b = math.max(0, math.min(S.entry.len, S.snap_t(frac * S.entry.len))) end
  if S.drag and S.drag.kind == 'out' and not S.drag.active and (math.abs(gfx.mouse_x - S.drag.x0) > 6 or math.abs(gfx.mouse_y - S.drag.y0) > 6) then S.drag.active = true end
end
function S.mouse_up()
  local d = S.drag
  S.drag = nil
  if d and d.kind == 'slice' then
    -- клик без протяжки — только выбор (граница не двигается, без правки)
    -- 15 окт: выбранным остаётся слайс ЭТОЙ метки (после сдвига список пересобран — номер другой;
    -- выбор прыгал на соседний слева)
    local function keep(t)
      local k = d.k
      for i, u in ipairs(S.slices or {}) do if math.abs(u - t) < 1e-6 then k = i end end
      if S.entry and ctx.select_slice then ctx.select_slice(S.entry, k); S.zedge_k, S.zedge_e = k, S.entry.item or S.entry.path end
      if ctx.set_last_slice then ctx.set_last_slice(k) end
      return k
    end
    if math.abs(gfx.mouse_x - (d.mx0 or gfx.mouse_x)) < 3 then
      if d.t0 then S.slices[d.k] = d.t0 end
      S.msg = ('slice S%02X selected'):format(keep(S.slices[d.k]))
      return d
    end
    local tnew = S.slices[d.k]
    commit(); S.msg = ('slice %d moved'):format(keep(tnew))
    S.roll(S.slices[d.k], S.line_is_end(d.t0), true)   -- 10 окт: auto play — кусок у края, не весь слайс
    return d
  end
  if S.sel and S.sel.b < S.sel.a then S.sel.a, S.sel.b = S.sel.b, S.sel.a end
  if S.sel and S.sel.b - S.sel.a < 0.001 then
    local t = S.sel.a
    S.sel = nil
    -- 10 окт, опция slice by click = click (как Slice Marker Tool в Renoise): щелчок без протяжки — слайс
    if d and d.kind == 'sel' and ctx.slice_by_click and ctx.slice_by_click() == 'click' then S.add_at(t)
    elseif d and d.kind == 'sel' and S.entry and #(S.slices or {}) > 0 and ctx.select_slice then
      -- 10 окт: режим double — одиночный щелчок между линиями выбирает этот слайс
      local k = 0
      for i, u in ipairs(S.slices) do if u <= t + 1e-6 then k = i end end
      if k > 0 then
        ctx.select_slice(S.entry, k); S.zedge_k, S.zedge_e = k, S.entry.item or S.entry.path
        if ctx.set_last_slice then ctx.set_last_slice(k) end
        S.msg = ('slice S%02X selected'):format(k)
      end
    end
  end
  return d
end
function S.span() if S.sel then return math.min(S.sel.a, S.sel.b), math.max(S.sel.a, S.sel.b) end end

-- ровная нарезка: n кусков по длине item (в секундах item, не источника)
-- нарезка виртуальная → применяется сразу (P_EXT), Enter не нужен
function commit()
  if S.entry and S.entry.item and ctx.edit and ctx.edit.set_slices then
    ctx.edit.set_slices(S.entry.item, S.slices)
    S.entry.slices = {}
    for _, t in ipairs(S.slices) do S.entry.slices[#S.entry.slices + 1] = t end
    S.msg = ('%d slices'):format(#S.slices)
  end
end
S.commit = commit

-- 10 окт: слайс мышью — поставить на t / удалить k (сразу в item, как остальная нарезка)
-- 10 окт: auto play как roll на SP-404 — пока тянешь край, короткий кусок у него
-- перезапускается: начало — RW мс от линии, конец — RW мс перед ним
S.RW = 0.12
function S.roll(t, is_end, force)
  if not (ctx.state and ctx.state.sliceaudition and S.entry and t) then return end
  local now = R.time_precise()
  if not force and now - (S.roll_t or 0) < S.RW then return end
  S.roll_t = now
  local a, b
  -- 11 окт: кусок не длиннее самого слайса — короткий слайс (0.07 с) не залезает в соседний
  local prev, nxt = 0, S.entry.len
  for _, u in ipairs(S.slices or {}) do
    if u < t - 1e-6 and u > prev then prev = u end
    if u > t + 1e-6 and u < nxt then nxt = u end
  end
  if is_end then a, b = math.max(prev, t - S.RW), t else a, b = t, math.min(nxt, t + S.RW) end
  if b > a then ctx.preview_slice(S.track, S.entry, a, b) end
end
-- тянется ли конец выбранного слайса (линия = конец зоны)
function S.line_is_end(t0) return S.zone_cur and math.abs((S.zone_cur[2] or -1) - t0) < 1e-6 or false end

function S.add_at(t)
  if not (S.entry and S.entry.item) then S.msg = 'slices live on items: put the sample on a track or into the lib first'; return end
  if t <= 0.002 or t >= S.entry.len - 0.002 then return end
  for _, u in ipairs(S.slices) do if math.abs(u - t) < 0.002 then return end end
  S.slices[#S.slices + 1] = t; table.sort(S.slices)
  commit()
  for k, u in ipairs(S.slices) do if u == t then S.msg = ('slice %02X added (double click on its line removes it)'):format(k) end end
end
function S.remove(k)
  if not (S.entry and S.entry.item and S.slices[k]) then return end
  table.remove(S.slices, k); commit()
  S.msg = ('slice %02X removed (%d left)'):format(k, #S.slices)
end

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
-- 10 окт: модуль детектора (Opt+D) — параметры как Transient detection / Dynamic split REAPER
S.DT = { thr_db = nil, gap_ms = 40, pre_ms = 0 }   -- thr_db nil — порог от чувствительности
S.dpanel = false
S.dsel = 1
-- 20 окт: детектор — чистая функция огибающей (beatsync to transient зовёт её для любого сэмпла, не трогая S)
local function detect_env(env, erate)
  local trans, amp = {}, {}
  if not env then return trans, amp end
  local thr = 0.04 + (1 - S.sens) * 0.30
  if S.DT.thr_db then thr = 10 ^ (S.DT.thr_db / 20) end
  local ratio = 1.6 + (1 - S.sens) * 2.5
  local gap = math.floor(env.rate * (S.DT.gap_ms or 40) / 1000)
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
        trans[#trans + 1] = t_src / (erate or 1)
        -- громкость атаки (~30 мс после начала) — для smart quantize: сильный / слабый
        local a = 0
        for j = i, math.min(env.n, i + math.floor(env.rate * 0.03)) do if env.v[j] > a then a = env.v[j] end end
        amp[#trans] = a
        last = i
      end
    end
  end
  return trans, amp
end
S.detect_env = detect_env
function S.detect()
  S.trans, S.trans_amp = detect_env(S.env, S.entry and S.entry.rate)
end
-- транзиенты сэмпла e ({ src, offs, len, rate }) — время в item при его rate
function S.transients_of(e) return (detect_env(build_env(e), e.rate)) end

function S.use_transients()
  S.detect()
  S.slices = {}
  if #S.trans == 0 or S.trans[1] > 0.01 then S.slices[1] = 0 end
  local pre = (S.DT.pre_ms or 0) / 1000
  for _, t in ipairs(S.trans) do S.slices[#S.slices + 1] = math.max(0, t - pre) end
  table.sort(S.slices)
  S.mode = ('transients %d (sens %.2f)'):format(#S.slices, S.sens)
  commit()
end

-- smart slice (8 окт, s s): транзиенты чувствительно, у каждого — яркость
-- атаки (доля энергии первой разности: бочка тёмная, хет / снейр / перкуссия
-- светлые; 25 мс после начала). Порог тёмный / светлый — медиана яркостей
-- этого сэмпла. Слайс ставится только на контрастном ударе: после тёмного —
-- первый светлый, после светлого — первый тёмный; одинаковые подряд (ролл
-- хетов, дубль бочки) сливаются в один слайс. Чтение — аудио-аксессор take
S.SMART_GAP = 0.06
local function brightness(x, n)
  local en, df = 0, 0
  for i = 2, n do local a = x[i] or 0; en = en + a * a; local d = a - (x[i - 1] or 0); df = df + d * d end
  if en < 1e-9 then return nil end
  return df / en
end
function S.brightness_reader()
  local e = S.entry
  -- 10 окт: сперва WAV напрямую (смещение / скорость item): аудио-аксессор заглушённого
  -- item (lib — заглушённый трек) отдаёт тишину — smart slice находил 0 dark / 0 bright
  if S.sg and e and e.fpath and e.fpath:lower():match('%.wav$') then
    local fr, fsr = S.sg.wav_reader(e.fpath)
    if fr then
      local offs, rate = e.offs or 0, (e.rate and e.rate ~= 0) and math.abs(e.rate) or 1
      local n = math.floor(fsr * 0.025)
      return function(t) return brightness(fr(offs + t * rate, n), n) end, function() end
    end
  end
  if not (e and e.take and R.ValidatePtr(e.take, 'MediaItem_Take*')) then return nil end
  local acc = R.CreateTakeAudioAccessor(e.take)
  if not acc then return nil end
  local src = R.GetMediaItemTake_Source(e.take)
  local sr = src and R.GetMediaSourceSampleRate(src) or 44100
  if not sr or sr <= 0 then sr = 44100 end
  local n = math.floor(sr * 0.025)
  local buf = R.new_array(n)
  local st = R.GetAudioAccessorStartTime(acc)
  return function(t)
    buf.clear()
    if R.GetAudioAccessorSamples(acc, sr, 1, st + t, n, buf) < 0 then return nil end
    return brightness(buf.table(), n)
  end, function() R.DestroyAudioAccessor(acc) end
end

function S.smart_slice()
  if not S.entry then return 0 end
  local sens0 = S.sens
  S.sens = math.min(1, math.max(S.sens, 0.75))       -- кандидаты — с запасом, отбор — по спектру
  S.detect()
  S.sens = sens0
  local cand = {}
  for _, t in ipairs(S.trans or {}) do cand[#cand + 1] = t end
  if #cand == 0 then S.msg = 'smart slice: no transients'; return 0 end
  local read, done = S.brightness_reader()
  if not read then S.use_transients(); S.msg = 'smart slice: no audio access - plain transients'; return #S.slices end
  local br = {}
  for i, t in ipairs(cand) do br[i] = read(t) end
  done()
  local sorted = {}
  for i = 1, #cand do if br[i] then sorted[#sorted + 1] = br[i] end end
  table.sort(sorted)
  local med = sorted[math.max(1, math.floor((#sorted + 1) / 2))] or 0
  S.slices = {}
  if cand[1] > 0.01 then S.slices[1] = 0 end
  local last_cls, last_t
  local nd, nb = 0, 0
  for i, t in ipairs(cand) do
    if br[i] then
      local cls = br[i] > med and 'b' or 'd'
      if cls ~= last_cls and (not last_t or t - last_t >= S.SMART_GAP) then
        S.slices[#S.slices + 1] = t
        last_cls, last_t = cls, t
        if cls == 'b' then nb = nb + 1 else nd = nd + 1 end
      end
    end
  end
  table.sort(S.slices)
  S.mode = ('smart %d (dark %d, bright %d)'):format(#S.slices, nd, nb)
  commit()
  S.msg = S.mode
  return #S.slices
end

function S.apply()
  if not S.entry then return end
  ctx.edit.set_slices(S.entry.item, S.slices)
  S.msg = ('%d slices stored'):format(#S.slices)
  S.active = false
end

-- 15 окт: после undo / redo — нарезка и края с item (слайсер держал прежние в памяти)
function S.resync()
  local e = S.entry
  if not (e and e.item and not e.file and R.ValidatePtr(e.item, 'MediaItem*')) then return end
  local sl = ctx.edit and ctx.edit.item_slices and ctx.edit.item_slices(e.item) or {}
  S.slices = {}
  for _, t in ipairs(sl) do S.slices[#S.slices + 1] = t end
  e.slices = #S.slices > 0 and { table.unpack(S.slices) } or nil
  local tk = R.GetActiveTake(e.item)
  if tk then e.offs = R.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS') end
  e.len = R.GetMediaItemInfo_Value(e.item, 'D_LENGTH')
  S.wcur = nil
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
  -- 8 окт: slice playthru — нота слайса играет до конца сэмпла, превью так же
  if S.entry.item and ctx.edit and ctx.edit.playthru and ctx.edit.playthru(S.entry.item) then t1 = S.entry.len end
  ctx.preview_slice(S.track, S.entry, t0, t1)
  -- 10 окт: кнопка follow — сыгранный на клавиатуре слайс становится выбранным (список, зона, зум края)
  if ctx.state and ctx.state.slicefollow and ctx.select_slice then ctx.select_slice(S.entry, k); S.zedge_k, S.zedge_e = k, S.entry.item or S.entry.path end
end

-- прослушивание слайса (4 окт): хроматическая раскладка q 2 w 3 e r 5 t …, как
-- вставка в трекере и подписи над волной (слайс k = нота C-4 + k - 1 на
-- текущей октаве); прежняя q..p = 1..10 и цифры-нарезки с ней спорили
-- 15 окт: во вкладке item нотные клавиши — только верхний ряд q 2 w 3 e …; в раскладке renoise
-- нижний ряд (z s x d c v …) — команды слайсера, верхний — со сдвигом на октаву вниз (q — весь сэмпл)
local TOP_ROW = { q = 1, ['2'] = 1, w = 1, ['3'] = 1, e = 1, r = 1, ['5'] = 1, t = 1, ['6'] = 1, y = 1, ['7'] = 1,
                  u = 1, i = 1, ['9'] = 1, o = 1, ['0'] = 1, p = 1 }
local function item_off(code)
  local off = ctx and ctx.piano and ctx.piano[code]
  if off == nil then return nil end
  if ctx.keys_renoise and ctx.keys_renoise() then
    if not (code < 256 and TOP_ROW[string.char(code)]) then return nil end
    off = off - 12
  end
  return off
end
local function piano_slice(c)
  local off = item_off(c)
  if off == nil then return nil end
  local oct = (ctx.octave and ctx.octave()) or 4
  local base = (ctx.slice_base and ctx.slice_base()) or 60
  return (oct + 1) * 12 + off - base + 1
end
S.piano_slice = piano_slice

-- клавиши; true — съедена
-- 15 окт: частота источника (кадры линейки hex и gw)
function S.srate(e)
  local src = e and e.src
  if not src and e and e.item and R.ValidatePtr(e.item, 'MediaItem*') then
    local tk = R.GetActiveTake(e.item)
    src = tk and R.GetMediaItemTake_Source(tk)
  end
  local sr = src and R.GetMediaSourceSampleRate(src) or 0
  return sr > 0 and sr or 44100
end
-- кадр источника от начала сэмпла (как в линейке) ↔ секунды e
function S.frame_of(e, t) return math.floor(t * ((e.rate and e.rate ~= 0) and e.rate or 1) * S.srate(e) + 0.5) end
function S.time_of(e, fr) return fr / S.srate(e) / ((e.rate and e.rate ~= 0) and e.rate or 1) end
-- 15 окт: сколько файла за краями сэмпла (секунды e): до начала и после конца; nil — не item
function S.more(e)
  if not (e and e.item and not e.file and R.ValidatePtr(e.item, 'MediaItem*')) then return nil end
  local tk = R.GetActiveTake(e.item)
  local src = tk and R.GetMediaItemTake_Source(tk)
  local slen = src and R.GetMediaSourceLength(src) or 0
  if slen <= 0 then return nil end
  local rate = (e.rate and e.rate ~= 0) and e.rate or 1
  return math.max(0, (e.offs or 0) / rate), math.max(0, (slen - (e.offs or 0)) / rate - e.len)
end
-- вернуть файл за краем: side 'a' — до начала, 'b' — после конца (все ноты, как ручки ia / ib)
function S.more_do(side)
  local e = S.entry
  local pre, post = S.more(e)
  if not pre or not ctx.autotrim then return end
  if side == 'a' and pre > 1e-4 then ctx.autotrim(e, -pre, e.len)
  elseif side == 'b' and post > 1e-4 then ctx.autotrim(e, 0, e.len + post)
  else S.msg = side == 'a' and 'the sample already starts at the file start' or 'the sample already ends at the file end' end
end
-- 16 окт: край сэмпла (g[ g]): у выделения на волне — его край, иначе курсор волны / метка выбранного слайса
function S.edge_trim(ch)
  if not (S.entry and S.entry.item and not S.entry.file and ctx.autotrim) then return end
  local a, b = S.span()
  local e, t = S.entry, nil
  if a then t = (ch == '[') and a or b
  elseif S.wcur and S.wcur_e == e.item then t = S.wcur
  else
    local k = (ctx.ssel and ctx.ssel.item == e.item) and ctx.ssel.k or 0
    if k and k > 0 and S.slices[k] then t = S.bounds(S.slices, k, e.len) end
  end
  if not t then S.msg = 'g[ g]: gw HEX - a wave cursor, or select a slice (slices pane, j k), or drag a span on the wave'
  elseif ch == '[' and t > 1e-4 then ctx.autotrim(e, t, e.len); S.wcur = nil
  elseif ch == ']' and t < e.len - 1e-4 then ctx.autotrim(e, 0, t); S.wcur = nil
  else S.msg = ch == '[' and 'the sample already starts here' or 'the sample already ends here' end
end
-- 15 окт: Tab / Shift+Tab — курсор волны к следующему / прошлому транзиенту (стандарт нарезки:
-- прошёл, послушал кусок до следующего, $ — разрезать здесь)
function S.trans_step(dir)
  local e = S.entry
  if not (e and e.item and not e.file) then S.msg = 'Tab: transients of a sample on a track or in the lib'; return end
  if #(S.trans or {}) == 0 and S.env then S.detect() end
  if #(S.trans or {}) == 0 then S.msg = 'no transients found (Opt+D - the detector)'; return end
  local t0 = (S.wcur and S.wcur_e == e.item) and S.wcur or (dir > 0 and -1 or e.len + 1)
  local best
  for _, u in ipairs(S.trans) do
    if dir > 0 and u > t0 + 1e-6 and (not best or u < best) then best = u end
    if dir < 0 and u < t0 - 1e-6 and (not best or u > best) then best = u end
  end
  if not best then S.msg = dir > 0 and 'the last transient' or 'the first transient'; return end
  S.wcur, S.wcur_e = best, e.item
  local nxt = e.len
  for _, u in ipairs(S.trans) do if u > best + 1e-6 and u < nxt then nxt = u end end
  if ctx.preview_slice then ctx.preview_slice(S.track, e, best, nxt) end
  if S.va and S.vb and (best < S.va or best > S.vb) then local sp = S.vb - S.va; S.va = math.max(0, best - sp / 2); S.vb = S.va + sp end
  S.msg = ('transient %X - $ cuts a slice here, Tab / Shift+Tab - next / previous'):format(S.frame_of(e, best))
end
-- $ — слайс у курсора волны (без нарезки — первый слайс с начала и этот)
function S.cut_here()
  local e = S.entry
  if not (S.wcur and S.wcur_e == (e and e.item)) then S.msg = '$: Tab to a transient (or gw HEX) first'; return end
  if #S.slices == 0 then S.slices[1] = 0 end
  S.add_at(S.wcur)
end
-- d + клавиша слайса — удалить его; dd — слайс под курсором волны / выбранный
function S.delete_key(c)
  local ch = c < 256 and string.char(c) or ''
  local k
  if ch == 'd' then
    local e = S.entry
    if S.wcur and S.wcur_e == (e and e.item) then for i, u in ipairs(S.slices) do if u <= S.wcur + 1e-6 then k = i end end end
    if not k then k = (ctx.ssel and e and ctx.ssel.item == e.item) and ctx.ssel.k or nil end
  else k = S.piano_slice and S.piano_slice(c) end
  if not k or k < 1 or not S.slices[k] then S.msg = 'd: a slice key (1 f1 2 ...; qwerty 2 w 3 e) or d - the slice under the wave cursor'; return end
  S.remove(k)
end
-- ближайший транзиент к t (детекция по требованию); нет — t
function S.snap_trans(t)
  if #(S.trans or {}) == 0 and S.env then S.detect() end
  local best
  for _, u in ipairs(S.trans or {}) do if not best or math.abs(u - t) < math.abs(best - t) then best = u end end
  return best or t
end

function S.key(c)
  local ch = c < 256 and string.char(c) or ''
  -- 10 окт: Opt+D — модуль детектора транзиентов; пока открыт — его клавиши первыми
  local mods = ctx.mods and ctx.mods() or {}
  local cpd = (c >= 0x75000000 and c < 0x76000000) and (c - 0x75000000) or c
  if (mods.alt and (ch == 'd' or ch == 'D')) or cpd == 8706 then S.dt_toggle(); return true end
  if S.dpanel and S.dt_key(c, mods.shift) then return true end
  -- 15 окт: gw HEX Enter — курсор волны на кадр линейки (по умолчанию к ближайшему транзиенту;
  -- Shift+Enter — ровно туда); [ ] ставят по нему начало / конец
  if S.gbuf then
    if c == 27 then S.gbuf = nil; S.msg = ''
    elseif c == 8 then S.gbuf = S.gbuf:sub(1, -2)
    elseif c == 13 and S.entry then
      local fr = tonumber(S.gbuf ~= '' and S.gbuf or '0', 16) or 0
      local t = math.max(0, math.min(S.entry.len, S.time_of(S.entry, fr)))
      local exact = mods.shift
      S.wcur = exact and t or S.snap_trans(t); S.wcur_e = S.entry.item
      S.gbuf = nil
      S.msg = ('wave cursor %X%s - g[ g] set the sample start / end here'):format(S.frame_of(S.entry, S.wcur), exact and '' or ' (snapped to a transient; Shift+Enter - exact)')
    elseif ch:match('^%x$') then S.gbuf = S.gbuf .. ch:upper()
    end
    if S.gbuf then S.msg = 'gw ' .. S.gbuf .. '_  hex frame, Enter - to the nearest transient, Shift+Enter - exact, Esc' end
    return true
  end
  -- 15 окт: u — undo, Ctrl+R — redo и во вкладке item (u была нотой верхнего ряда — слушала слайс)
  if (ch == 'u' or c == 18) and ctx.edit then
    if ch == 'u' then ctx.edit.undo() else ctx.edit.redo() end
    S.msg = (ch == 'u' and 'undo: ' or 'redo: ') .. tostring(R.Undo_CanUndo2(0) or '')
    return true
  end
  -- 16 окт: 4 / 8 без меню убраны — играя, сбивали слайсы; нарезка — только s 4 / s 8
  if S.dpend then
    S.dpend = nil
    if c ~= 27 then S.delete_key(c) else S.msg = '' end
    return true
  end
  if ch == 'd' and S.entry and not S.entry.file then S.dpend = true; S.msg = 'd: a slice key (1 f1 2 ...; qwerty 2 w 3 e) deletes it, d - the slice under the wave cursor'; return true end
  if ch == '$' and S.entry and not S.entry.file then S.cut_here(); return true end
  if S.gpend then
    S.gpend = nil
    if ch == 'w' then S.gbuf = ''; S.msg = 'gw _  hex frame of the ruler, Enter'; return true end
    -- 16 окт: g[ g] — край сэмпла здесь (autotrim; было [ ] — спорило с октавой frow и резало сэмпл);
    -- g{ g} — вернуть файл за краем (было g[ g])
    if ch == '[' or ch == ']' then S.edge_trim(ch); return true end
    if ch == '{' or ch == '}' then S.more_do(ch == '{' and 'a' or 'b'); return true end
  elseif ch == 'g' and S.entry and not S.entry.file then S.gpend = true; S.msg = 'g: w - go to a hex position on the wave, [ ] - the sample starts / ends here, { } - give back the file before / after it'; return true end
  local a, b = S.span()
  -- 17 окт: прицел активен — клавиши его кнопок (подписаны на кнопках): S smk, 0 0-cross, t t-snap, q quant
  -- (s cut, Q squant — ниже, как были); раньше цифр-нот: 0 при прицеле — 0-cross
  if S.cross and not a and ctx.state then
    local tg = ({ ['0'] = 'cut0x', t = 'cutsnap', q = 'cutquant' })[ch]
    if tg then
      local st = ctx.state
      st[tg] = not st[tg]
      local nm = ({ cut0x = '0-cross', cutsnap = 't-snap', cutquant = 'quant' })[tg]
      S.msg = nm .. (st[tg] and ' on' or ' off') .. (tg == 'cutquant' and not st.cutsnap and ' (works with t-snap)' or '')
      return true
    end
    if ch == 'S' and ctx.smk_at then ctx.smk_at(S.cross, S.cut_point(S.cross.t + S.cross.dt)); return true end
  end
  -- 14 окт: s — меню нарезки и в раскладке renoise (15 окт: весь нижний ряд renoise здесь — команды)
  local pk = S.entry and not S.entry.file and piano_slice(c)
  if pk then
    if pk == 0 then ctx.preview_slice(S.track, S.entry, 0, S.entry.len); S.msg = 'q: the whole sample'   -- 5 окт
    elseif pk >= 1 and pk <= #(S.slices or {}) then S.preview(pk) else S.msg = ('no slice %d (%d slices)'):format(pk, #(S.slices or {})) end
    return true
  end
  if c == 27 then if S.sel then S.sel = nil else S.close() end
  elseif c == 13 then
    -- Enter: есть выделение — вставить в строку курсора; иначе применить нарезку
    if a then ctx.drop_span_cursor(S.entry, a, b) else commit() end
  elseif ch == 'a' then S.select_all()
  elseif ch == 'v' then S.cycle_view()
  elseif ch == 'D' or (ch == 'd' and a) then if a then ctx.depot_span(S.entry, a, b) end
  elseif ch == ' ' and a then ctx.preview_slice(S.track, S.entry, a, b)
  elseif S.entry and S.entry.file and (ch == 'x' or ch == 's') then
    S.msg = 'file: slices live on items - drag selection to a track or D: to lib, then slice'
  -- нарезка (4 окт): префикс s — всплывашка: t транзиенты, 2 4 8 1 3 6 —
  -- равные части 2 4 8 16 32 64 (цифры без s — клавиши нот, слушают слайсы)
  -- 12 окт: прицел ноты под курсором трекера: [ ] — ±5 мс, { } — ±0.5 мс (h l заняты панелью свойств),
  -- s — разрезать эту ноту здесь; меню нарезки — S (без ноты под курсором — и s)
  -- 15 окт: [ ] — начало / конец сэмпла; прицел — { } по 1 мс
  elseif S.cross and not a and (ch == '{' or ch == '}') then
    S.cross.dt = S.cross.dt + (ch == '}' and 0.001 or -0.001)
    S.msg = ('cut point %+.1f ms from the row ({ } - 1 ms) - s cuts the note here'):format(S.cross.dt * 1000)
  elseif ch == 's' and S.cross and ctx.cut_at then
    local te = S.cut_point(S.cross.t + S.cross.dt)
    ctx.cut_at(S.cross, te, ctx.state and ctx.state.cutsnap and ctx.state.cutquant); S.cross = nil
  elseif (ch == 'S' or ch == 's') and ctx.slice_hydra then ctx.slice_hydra()
  elseif ch == '+' or ch == '=' then S.sens = math.min(1, S.sens + 0.05); if S.mode:match('^transients') then S.use_transients() else S.detect(); S.mode = ('detect %d (sens %.2f)'):format(#S.trans, S.sens) end
  elseif ch == '-' then S.sens = math.max(0, S.sens - 0.05); if S.mode:match('^transients') then S.use_transients() else S.detect(); S.mode = ('detect %d (sens %.2f)'):format(#S.trans, S.sens) end
  elseif ch == 'x' then S.clear()
  elseif ch == 'Q' then S.smart_quantize()                              -- smart quantize (2 окт)
  -- 10 окт: zz — item на всё окно (как zz в других модулях); autotrim — T
  elseif ch == 'z' and not S.pend_z then S.pend_z = R.time_precise(); S.msg = 'z: z - item on the whole window, w - across the whole width, x - taller'
  elseif S.pend_z and (ch == 'z' or ch == 'w' or ch == 'x') then   -- 24 окт: как у DSP — zz / zw / zx
    S.pend_z = nil
    if ch == 'z' then if ctx.sample_big then ctx.sample_big() end
    elseif ch == 'w' then if ctx.pane_wide then ctx.pane_wide('sample') end
    else if ctx.dsp_tall then ctx.dsp_tall('sample') end end
  elseif ch == 'T' then S.autotrim()                                   -- autotrim: тишина в начале / конце (2 окт)
  elseif (ch == '<' or ch == '>' or ch == ',' or ch == '.') and S.entry and S.entry.item then
    S.vol_step((ch == '>' or ch == '.') and 1 or -1)
  elseif ch == 'n' and S.entry and S.entry.item then ctx.edit.normalize(S.entry.item); S.msg = 'normalized (peak 0 dB)'
  elseif ch == ' ' then ctx.edit.play_stop()
  else return true end     -- всё остальное тоже съедаем: оверлей модальный
  return true
end

-- Вид сэмпла во вкладке «sample» верхней панели (прямоугольник x,y,w,h).
-- S.active и тот же инструмент — режим правки (рабочие слайсы, транзиенты,
-- подсказка клавиш); иначе — инструмент e как есть, с сохранёнными слайсами.
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
  if id == 'slq' then if ctx.slq_menu then ctx.slq_menu() end; return end   -- 11 окт: квантизация старта слайсов (шаг auto)
  if id == 'follow' then                             -- 10 окт: сыгранный на клавиатуре слайс — выбранный
    if ctx.state then
      ctx.state.slicefollow = not ctx.state.slicefollow
      if ctx.save_flag then ctx.save_flag('slicefollow', ctx.state.slicefollow) end
      S.msg = 'follow ' .. (ctx.state.slicefollow and 'on: the slice you play on the keyboard becomes the selected one' or 'off')
    end
    return
  end
  if id == 'mono' then                               -- 9 окт: один голос на трек при вставке / poly
    if ctx.mono_toggle then ctx.mono_toggle() end
    return
  end
  if id == 'snap' then
    S.snap = not S.snap
    if S.snap and S.entry and #S.trans == 0 and S.detect then S.detect() end   -- транзиенты для притяжения
    S.msg = 'snap ' .. (S.snap and ('on: ' .. #S.trans .. ' transients + slice markers') or 'off')
    return
  end
  if not S.entry or S.entry.file then return end
  local n = id:match('^eq(%d+)$')
  if n then S.equal(tonumber(n))
  elseif id == 'trans' then S.use_transients()
  elseif id == 'sens-' or id == 'sens+' then
    S.sens = math.max(0, math.min(1, S.sens + (id == 'sens+' and 0.05 or -0.05)))
    S.use_transients()
  elseif id == 'clear' then S.clear()
  elseif id == 'smkall' then   -- 16 окт: stretch-маркеры на всех границах слайсов (и на краях item)
    if ctx.slices_to_smk then ctx.slices_to_smk(S.entry.item, S.slices or {}) end
  elseif id == 'quant' then S.smart_quantize()
  elseif id == 'autotrim' then S.autotrim()
  elseif id == 'scram' and ctx.scramble then ctx.scramble()
  elseif id == 'pthru' and ctx.sp_adjust then ctx.sp_adjust(S.entry, 'pthru', 1) end   -- slice playthru кнопкой (6 окт)
end

-- smart quantize (2 окт; 5 окт — все к шестнадцатым): транзиенты → stretch-маркеры; было: сильные к
-- ближайшим долям, слабые к шестнадцатым; длина — до целых тактов / долей
-- параметры квантайзера (5 окт, панель Q): шаг сетки в QN, захват (доля
-- шага), предел растяжения куска, сила притяжения 0..1
S.qprm = { step = 0.25, window = 1 / 3, maxr = 1.25, strength = 1 }
S.qpreview = false               -- панель открыта: превью плана на волне
function S.quant_hits()
  local hits = {}
  for k, t in ipairs(S.trans) do hits[#hits + 1] = { t = t, amp = (S.trans_amp or {})[k] or 0 } end
  return hits
end
function S.smart_quantize()
  local e = S.entry
  if not e or e.file or not e.item then S.msg = 'quantize: open an instrument (not a browser file)'; return end
  S.detect()
  if #S.trans == 0 then S.msg = 'quantize: no transients (sens+ for more)'; return end
  local hits = S.quant_hits()
  local n, kept, newlen = ctx.edit.smart_quantize(e.item, hits, S.qprm)
  S.msg = n and ('quantized: %d of %d transients, length %.3fs'):format(kept or 0, #hits, newlen or 0) or 'quantize failed'
end

-- autotrim (2 окт): срезать тишину в начале и в конце по огибающей пиков
-- (порог −48 дБ от пика, не ниже −60 дБ); 5 мс до атаки и 20 мс хвоста
-- оставляются, чтобы не щёлкало. Правку (offset / длина всех нот этого
-- инструмента, сдвиг слайсов) делает main — ctx.autotrim, один undo.
function S.trim_bounds(env, len, rate)
  if not env or (env.n or 0) == 0 then return nil, 'no peaks yet' end
  local mx = 0
  for i = 1, env.n do if env.v[i] > mx then mx = env.v[i] end end
  if mx <= 0 then return nil, 'silent' end
  local thr = math.max(0.001, mx * 10 ^ (-48 / 20))
  local i0, i1
  for i = 1, env.n do if env.v[i] > thr then i0 = i; break end end
  for i = env.n, 1, -1 do if env.v[i] > thr then i1 = i; break end end
  if not i0 then return nil, 'silent' end
  rate = (rate and rate ~= 0) and rate or 1
  local a = math.max(0, (i0 - 1) / env.rate - 0.005) / rate
  local b = math.min(len, (i1 / env.rate + 0.02) / rate)
  if a < 0.002 and len - b < 0.002 then return nil, 'no silence to cut' end
  return a, b
end
function S.autotrim()
  local e = S.entry
  if not e or e.file or not e.item then S.msg = 'autotrim: open an instrument (not a browser file)'; return end
  local a, b = S.trim_bounds(S.env, e.len, e.rate)
  if not a then S.msg = 'autotrim: ' .. tostring(b); return end
  ctx.autotrim(e, a, b)
end

function S.cycle_view()
  S.view = ({ peaks = 'spec', spec = 'sgram', sgram = 'peaks' })[S.view] or 'peaks'
  return S.view
end

-- 10 окт: зум края (как в Xfer Nerve) — что показывать снизу крупно:
-- тянущаяся линия слайса → край тянущейся зоны → выбранный в списке слайс →
-- последняя схваченная линия → начало зоны. Возвращает t (секунды e), подпись, k линии
-- строки панели детектора: { key, label, get, set(v), min, max, step, fine, fmt }
S.DROWS = {
  { 'sens', 'sensitivity', function() return S.sens end, function(v) S.sens = v end, 0, 1, 0.05, 0.01, '%.2f' },
  { 'thr', 'threshold', function() return S.DT.thr_db or -60.5 end, function(v) S.DT.thr_db = v <= -60 and nil or v end, -60.5, 0, 1, 0.25, nil },
  { 'gap', 'min gap', function() return S.DT.gap_ms end, function(v) S.DT.gap_ms = v end, 5, 500, 5, 1, '%d ms' },
  { 'pre', 'pre-attack', function() return S.DT.pre_ms end, function(v) S.DT.pre_ms = v end, 0, 30, 1, 0.25, '%.1f ms' },
}
local function drow_txt(r)
  local v = r[3]()
  if r[1] == 'thr' then return S.DT.thr_db and ('%.1f dB'):format(S.DT.thr_db) or 'auto' end
  return r[9]:format(v)
end
local function d_redetect() if S.env then S.detect(); S.mode = ('detect %d (sens %.2f)'):format(#S.trans, S.sens) end end
function S.dt_adjust(i, d)
  local r = S.DROWS[i]; if not r then return end
  r[4](math.max(r[5], math.min(r[6], r[3]() + d)))
  d_redetect()
end
-- клавиши панели (пока открыта); true — съели
function S.dt_key(c, shift)
  local ch = c > 0 and c < 256 and string.char(c) or ''
  local r = S.DROWS[S.dsel]
  if c == 27 then S.dpanel = false; S.msg = 'transient detector closed'
  elseif ch == 'j' or c == 1685026670 then S.dsel = math.min(#S.DROWS, S.dsel + 1)
  elseif ch == 'k' or c == 30064 then S.dsel = math.max(1, S.dsel - 1)
  elseif ch == 'l' or ch == 'L' or c == 1919379572 then S.dt_adjust(S.dsel, (shift or ch == 'L') and r[8] or r[7])
  elseif ch == 'h' or ch == 'H' or c == 1818584692 then S.dt_adjust(S.dsel, -((shift or ch == 'H') and r[8] or r[7]))
  elseif c == 13 then S.use_transients(); S.msg = ('sliced at %d transients'):format(#S.slices)
  elseif ch == 's' then S.smart_slice()
  elseif ch == 'x' then S.clear()
  else return false end
  return true
end
function S.dt_toggle()
  S.dpanel = not S.dpanel
  if S.dpanel then d_redetect(); S.msg = 'transient detector: j k parameter, h l value (Shift fine), Enter slice, s smart, x clear, Esc close' end
end
-- отрисовка панели (x, y, w, h); тянуть слайдер мышью — по горизонтали
function S.dt_draw(U, L, x, y, w, h)
  local rh, pad = L.rh, L.pad
  U.set(U.PANEL); gfx.rect(x, y, w, h, 1)
  U.set(U.LINE); gfx.rect(x + w - 1, y, 1, h, 1)
  U.text(x + pad, y + 1, ctx.fit('transients', w - 2 * pad), U.AMBER)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local down = (gfx.mouse_cap & 1) == 1
  local lw = math.floor(w * 0.45)
  for i, r in ipairs(S.DROWS) do
    local ry = y + i * rh + 2
    local sel = i == S.dsel
    local hot = mx >= x and mx < x + w and my >= ry and my < ry + rh
    if sel or hot then U.set(U.tint(U.AMBER, sel and 0.25 or 0.12)); gfx.rect(x + 1, ry, w - 2, rh, 1) end
    U.text(x + pad, ry, ctx.fit(r[2], lw - pad), (sel or hot) and U.AMBER or U.TEXT)
    local bx, bw = x + lw, w - lw - pad
    local f = (r[3]() - r[5]) / (r[6] - r[5])
    U.set(U.DIM); gfx.rect(bx, ry + rh - 3, bw, 1, 1)
    U.set((sel or hot) and U.AMBER or U.GREY); gfx.rect(bx, ry + rh - 4, math.max(1, math.floor(bw * f)), 3, 1)
    U.text(bx, ry, ctx.fit(drow_txt(r), bw), (sel or hot) and U.TEXT or U.GREY)
    if down and hot and not S.dt_prev then S.dsel = i; S.dt_drag = { i = i, bx = bx, bw = bw } end
  end
  if S.dt_drag and down then
    local r = S.DROWS[S.dt_drag.i]
    local f = math.max(0, math.min(1, (mx - S.dt_drag.bx) / math.max(1, S.dt_drag.bw)))
    local v = r[5] + f * (r[6] - r[5])
    v = math.floor(v / r[8] + 0.5) * r[8]
    if math.abs(v - r[3]()) > 1e-9 then r[4](v); d_redetect() end
  elseif not down then S.dt_drag = nil end
  local cy = y + (#S.DROWS + 1) * rh + 6
  U.text(x + pad, cy, ctx.fit(('%d transients'):format(#(S.trans or {})), w - 2 * pad), U.CYAN)
  -- кнопки: apply / smart / clear
  local bx = x + pad
  local by = cy + rh + 2
  S.dt_btn = nil
  for _, b in ipairs({ { 'apply', 'Enter' }, { 'smart', 's' }, { 'clear', 'x' } }) do
    local bw = U.measure(b[1]) + 2 * pad
    if bx + bw > x + w - pad then bx = x + pad; by = by + rh + 2 end
    local hot = mx >= bx and mx < bx + bw and my >= by and my < by + rh
    U.set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, by, bw, rh, 1)
    U.set(hot and U.AMBER or U.LINE); gfx.rect(bx, by, bw, rh, 0)
    U.text(bx + pad, by, b[1], hot and U.AMBER or U.TEXT)
    if hot and down and not S.dt_prev then S.dt_btn = b[1] end
    bx = bx + bw + pad
  end
  if S.dt_btn == 'apply' then S.dt_key(13) elseif S.dt_btn == 'smart' then S.smart_slice() elseif S.dt_btn == 'clear' then S.clear() end
  U.text(x + pad, by + rh + 4, ctx.fit('Opt+D or Esc - close', w - 2 * pad), U.GREY)
  S.dt_prev = down
  return mx >= x and mx < x + w and my >= y and my < y + h
end

-- 12 окт: прицел у ноты под курсором трекера (если она этого инструмента): base — место звука на строке
-- курсора (секунды e), dt — сдвиг h l / H L / мышью; s режет только эту ноту в точке прицела
-- 12 окт: точка реза с привязками: t-snap — ближайший транзиент, 0-cross — ближайший переход через ноль (±10 мс)
function S.cut_point(te)
  local st = ctx.state or {}
  local e = S.cross and S.cross.e
  if st.cutsnap then
    if #(S.trans or {}) == 0 and S.detect then S.detect() end
    local best = ctx.AIM and ctx.AIM.nearest(S.trans, te)
    if best then te = best end
  end
  if st.cut0x and e and S.zero_cross then te = S.zero_cross(e, te) or te end
  return te
end
function S.cross_update(e)
  local c = ctx.cursor_cross and ctx.cursor_cross(e)
  if not c then S.cross = nil; return end
  -- 17 окт: прицел — у последнего касания: курсор сдвинулся (или фокус вернулся в трекер) — нота под курсором;
  -- слайс выбран / сыгран позже — прицел на его крае (и его клавиши / кнопки — тоже не про ноту курсора)
  if c.key ~= S.cross_key then S.cross_key = c.key; S.cursor_t = R.time_precise() end
  if (S.slice_t or 0) > (S.cursor_t or 0) then S.cross = nil; return end
  c.e = e
  if not S.cross or S.cross.key ~= c.key then c.dt = 0; S.cross = c
  else local dt = S.cross.dt; S.cross = c; c.dt = dt end
end
function S.edge_focus(e, zone, editing)
  if not (ctx.state and ctx.state.edgezoom ~= false) then return nil end
  local sl = editing and S.slices or (e.slices or {})
  if editing and S.drag and S.drag.kind == 'slice' and sl[S.drag.k] then return sl[S.drag.k], ('S%02X line'):format(S.drag.k), S.drag.k end
  if S.zdrag and S.zdrag.k and sl[S.zdrag.k] then return sl[S.zdrag.k], ('S%02X line'):format(S.zdrag.k), S.zdrag.k end
  local zd = S.zone_drag
  if zd and zone and (zd.edge == 'a' or zd.edge == 'b') then return zd.edge == 'a' and zone[1] or zone[2], zd.edge == 'a' and 'zone start' or 'zone end' end
  if S.cross then return S.cross.t + S.cross.dt, ('cursor %+.1f ms'):format(S.cross.dt * 1000) end
  local k = ctx.selected_slice and ctx.selected_slice(e)
  if k and k > 0 and sl[k] then return sl[k], ('S%02X start'):format(k), k end
  if S.zedge_k and sl[S.zedge_k] and S.zedge_e == (e.item or e.path) then return sl[S.zedge_k], ('S%02X line'):format(S.zedge_k), S.zedge_k end
  if zone then return zone[1], 'zone start' end
  -- ничего не выбрано — как в Nerve, окно всё равно есть: первая линия слайса, иначе начало сэмпла
  if sl[1] then return sl[1], 'S01 line', 1 end
  return 0, 'sample start'
end
-- сэмплы окна [t0, t0 + span] секунд e: WAV напрямую (смещение / скорость item), иначе аудио-аксессор take
local function zoom_samples(e, t0, span)
  local key = tostring(e.fpath) .. ':' .. tostring(e.offs) .. ':' .. tostring(e.rate) .. ':' .. ('%.5f:%.5f'):format(t0, span)
  if S.zs and S.zs.key == key then return S.zs.s, S.zs.n end
  local rk = tostring(e.fpath) .. tostring(e.take)
  if not (S.zr and S.zr.key == rk) then
    local fn, sr, file = nil, nil, false
    if S.sg and e.fpath and e.fpath:lower():match('%.wav$') then fn, sr = S.sg.wav_reader(e.fpath); file = fn ~= nil end
    if not fn and S.sg and e.take and R.ValidatePtr(e.take, 'MediaItem_Take*') then fn, sr = S.sg.take_reader(e.take) end
    S.zr = { key = rk, fn = fn, sr = sr or 44100, file = file }
  end
  local zr = S.zr
  if not zr.fn then return nil end
  local rate = (e.rate and e.rate ~= 0) and math.abs(e.rate) or 1
  local n = math.max(16, math.min(65536, math.floor(span * rate * zr.sr)))
  local ft = zr.file and ((e.offs or 0) + math.max(0, t0) * rate) or math.max(0, t0)
  -- 11 окт: окно левее начала item — слева нули, звук с 0 встаёт на своё место
  -- (раньше читался с 0 и растягивался на всё окно: волна съезжала влево от линии)
  local pad = t0 < 0 and math.min(n, math.floor(-t0 / span * n + 0.5)) or 0
  -- 12 окт: файл читается напрямую — левее начала item звук файла есть (прицел ноты из другого куска); нули — только до начала файла
  if zr.file and t0 < 0 then
    local fr = (e.offs or 0) + t0 * rate
    ft = math.max(0, fr)
    pad = fr < 0 and math.min(n, math.floor(-fr / (span * rate) * n + 0.5)) or 0
  end
  local s = zr.fn(ft, n - pad)
  if pad > 0 and s then
    local s2 = {}
    for i = 1, pad do s2[i] = 0 end
    for i = 1, n - pad do s2[pad + i] = s[i] or 0 end
    s = s2
  end
  S.zs = { key = key, s = s, n = n }
  return s, n
end
-- 12 окт: ближайший к te переход через ноль в окне ±10 мс (секунды e)
function S.zero_cross(e, te)
  local span = 0.02
  local s, n = zoom_samples(e, te - span / 2, span)
  if not s or n < 4 then return nil end
  local i = ctx.AIM and ctx.AIM.zero_index(s, n)
  return i and (te - span / 2 + (i - 1) / n * span) or nil
end

-- zone = { a, b, inst } — играемая зона (секунды e) выбранного инструмента,
-- когда e — его исходник (слайс/кусок показывается на фоне целого сэмпла)
function S.draw_in(U, L, x, y, w, h, e, track, zone)
  S.ap_hot = false
  if zone and not (zone[1] and zone[2]) then zone = nil end   -- 15 окт: неполная зона (слайс отрезан) — без неё, не падать
  if not e then
    -- пустой трек: запись — во вкладке rec (3 окт)
    U.text(x, y + 1, ctx.fit('no instrument - select one in the lib, or record one in the rec tab', w), U.GREY)
    return nil
  end
  -- 9 окт: свежий файл (только записан / склеен) — пиков ещё нет или они
  -- нулевые: волна была плоской до перезапуска. Пока пусто — перечитывать
  -- раз в полсекунды (не дольше 30 с от открытия)
  if S.active and S.entry and (not S.env or (S.env.max or 1) < 1e-7) then
    local now = R.time_precise()
    S.env_t0 = S.env_t0 or now
    if now - S.env_t0 < 30 and now >= (S.env_retry or 0) then
      S.env_retry = now + 0.5
      local ok, env = pcall(build_env, S.entry)
      if ok and env then S.env = env; if (env.max or 0) >= 1e-7 then S.msg = '' end end
    end
  else S.env_t0 = nil end
  local editing = S.active and S.entry and S.entry.item == e.item
  local rh = L.rh
  -- один заголовок в просмотре и правке (3 окт: двойной клик менял экран)
  local nsl = editing and #S.slices or (e.slices and #e.slices or 0)
  local title = ('%s  offs %.3f  len %.3f  rate %.2f%s'):format(e.name, e.offs or 0, e.len or 0, e.rate or 1,
        nsl > 0 and ('  slices ' .. nsl) or '')
  if editing and S.mode ~= '' and S.mode ~= 'stored' then title = title .. '  - ' .. S.mode end
  if zone then title = title .. ('  [inst %02d plays %.3f-%.3fs]'):format(zone[3] or 0, zone[1], zone[2]) end
  -- кнопки вида справа в заголовке
  local vx = x + w
  local hover_view
  for _, v in ipairs({ 'big', 'sgram', 'spec', 'peaks' }) do
    local bw = U.measure(v) + 2 * L.pad
    vx = vx - bw
    local on = (v == 'big' and ctx.state and ctx.state.sample_big) or S.view == v
    local hot = gfx.mouse_x >= vx and gfx.mouse_x < vx + bw and gfx.mouse_y >= y and gfx.mouse_y < y + rh
    U.set(on and U.tint(U.CYAN, 0.3) or U.BG); gfx.rect(vx, y, bw, rh, 1)
    U.set(on and U.CYAN or U.LINE); gfx.rect(vx, y, bw, rh, 0)
    U.text(vx + L.pad, y + 1, v, on and U.CYAN or (hot and U.TEXT or U.GREY))
    if hot then hover_view = v end
    if ctx.hint then ctx.hint('sampleview', vx, y, bw, rh, v) end
    vx = vx - 2
  end
  if e.muted and not e.depot then title = title .. '  (muted)' end   -- 10 окт: в lib заглушено всё — не пишем
  U.text(x, y, ctx.fit(title, vx - x - L.pad), U.TEXT)
  local hint = editing
    and (e.file and 'Enter: insert @cursor  D: to lib  a: all  Space: play  g[ g]: edges'
         or 's: 2/4/8 1(16) 3(32) 6(64) equal, t transients  + - sens  x clear  v view')
    or 'dblclick / :slice / \\is — edit slices;  1 f1 2 ... slices 1 2 3, ` whole (qwerty: q whole, 2 w 3 e)  drag: select → drop on track'
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
  -- [rec] в левом углу ряда (3 окт): запись в item — режим вкладки (кольцо
  -- jf_rec); есть всегда — и у файла браузера
  local bx = x
  local brow = 0                       -- 9 окт: кнопки не влезли (x2) — перенос на строку ниже, волна ниже
  if not e.file and e.item then
    local BTN = { { 'snap', 'snap' }, { 'trim', 'autotrim' }, { '2', 'eq2' }, { '4', 'eq4' }, { '8', 'eq8' }, { '16', 'eq16' }, { '32', 'eq32' }, { '64', 'eq64' },
                  { 'transients', 'trans' }, { '-', 'sens-' }, { '+', 'sens+' }, { 'clear', 'clear' }, { 'stretch', 'smkall' }, { 'playthru', 'pthru' }, { (ctx.slq_label and ctx.slq_label()) or 'q 0', 'slq' }, { 'mono', 'mono' }, { 'follow', 'follow' } }   -- 9 окт: scramble — во вкладке macros   -- quantize — Q (панель) и \\q у курсора (5 окт)
    for _, b in ipairs(BTN) do
      local bw = U.measure(b[1]) + 2 * L.pad   -- 24 окт: приписки клавиш убраны (просьба) — клавиша в статусе при наведении
      local lim = brow == 0 and (x + hint_w) or (x + w)
      if bx + bw > lim then
        if brow >= 1 then break end
        brow, bx = brow + 1, x; lim = x + w
      end
      local by = y + rh + brow * rh
      local hot = gfx.mouse_x >= bx and gfx.mouse_x < bx + bw and gfx.mouse_y >= by and gfx.mouse_y < by + rh
      local on = (b[2] == 'slq' and ctx.slq_rows and ctx.slq_rows() > 0) or (b[2] == 'snap' and S.snap) or (b[2] == 'pthru' and ctx.playthru_of and ctx.playthru_of(e)) or (b[2] == 'mono' and ctx.mono_on and ctx.mono_on()) or (b[2] == 'follow' and ctx.state and ctx.state.slicefollow)   -- playthru (6 окт): горит, когда включён
      U.set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(U.CYAN, 0.3) or U.BG)); gfx.rect(bx, by, bw, rh, 1)
      U.set(hot and U.AMBER or (on and U.CYAN or U.LINE)); gfx.rect(bx, by, bw, rh, 0)
      U.text(bx + L.pad, by + 1, b[1], hot and U.AMBER or (on and U.CYAN or U.TEXT))
      if hot then hover_sbtn = b[2] end
      if ctx.hint then ctx.hint('slicebtn', bx, by, bw, rh, b[2]) end
      -- 12 окт: transients - + — одна группа: общая линия снизу (чувствительность — к детектору)
      if b[2] == 'trans' then S.grp = { x0 = bx, y = by + rh } elseif b[2] == 'sens+' and S.grp and S.grp.y == by + rh then
        U.set(U.mix(U.AMBER, U.PANEL, 0.35)); gfx.rect(S.grp.x0, by + rh, bx + bw - S.grp.x0, 1, 1)
      end
      bx = bx + bw + 2
    end
    if editing and #S.trans > 0 then
      local st = ctx.fit(('sens %.2f'):format(S.sens), (brow == 0 and (x + hint_w) or (x + w)) - bx - L.pad)
      U.text(bx + L.pad, y + rh + brow * rh + 1, st, U.GREY)
      bx = bx + U.measure(st) + 2 * L.pad
    end
  else
    U.text(bx, y + rh, ctx.fit(hint, x + hint_w - bx), U.GREY)
  end
  -- волна: peaks / spec — нативные спектральные пики REAPER, цвет той же
  -- функцией, что колонка волны трека (ctx.spec_colour); спектрограмма
  -- убрана 1 окт
  local wy, wh = y + (2 + brow) * rh + 2, h - (3 + brow) * rh - 4
  -- 17 окт: полоса-обзор — всегда наверху, на всю ширину, над прицелом и его кнопками; высота — 2 строки (у волны)
  local BH, bar_y, bar_x, bar_w = 2 * rh, nil, x, w   -- 17 окт: 2 строки (3 — много)
  if wh > BH + 8 * rh then bar_y = wy; wy = wy + BH + 2; wh = wh - BH - 2 end
  -- 10 окт: под волной — полоска-обзор (весь item мини-волной, рамка — окно зума)
  -- 10 окт: полоска только при зуме; опция wave scrollbar — волной (по умолчанию) или обычной полосой
  if S.zoom_e ~= e.item and S.zoom_e ~= e.path then S.va, S.vb, S.zoom_e = 0, nil, e.item or e.path end
  local zoomed0 = S.vb ~= nil and (math.min(S.vb, e.len or 1) - (S.va or 0)) < ((e.len or 0) > 0 and e.len or 1) - 1e-6
  local wavebar = not (ctx.state and ctx.state.wavebar == false)
  local SBH = 0   -- 17 окт: обзор — в нижней строке, под волной места не берёт
  S.cross_update(e)
  local zt, zlab, zk = S.edge_focus(e, zone, S.active and S.entry and S.entry.item == e.item)
  local ZH = 0
  -- 12 окт: прицел (зум края) — раньше полосы-обзора: при зуме обзор отнимал высоту, и прицел пропадал
  -- 19 окт: прицел — только когда не дублирует волну: его окно ±zwin не шире трети видимого куска внизу
  local vspan0 = math.max(1e-3, math.min(e.len > 0 and e.len or 1, S.vb or e.len or 1) - math.max(0, S.va or 0))
  if zt and wh > 9 * rh and 2 * (S.zwin or 0.04) * 3 <= vspan0 then ZH = math.floor(wh * 0.42); wh = wh - ZH - 2 end   -- волна пополам: сверху целиком, снизу край
  -- 16 окт: вкладка item внизу экрана (опция zoom on top, по умолчанию вкл) — прицел НАД полной волной
  local ztop = ZH > 0 and S.zoom_top
  local zy_top = ztop and wy or nil
  if ztop then wy = wy + ZH + 2 end
  if SBH > 8 and wh - SBH - 2 < 3 * rh then SBH = 8 end   -- места мало — обзор тонкой полосой, прицел остаётся
  if SBH > 0 then wh = wh - SBH - 2 end
  if wh < 6 then return end
  -- 10 окт: модуль детектора транзиентов (Opt+D) — слева от волны, волна сужается
  S.dt_hot = nil
  if S.dpanel and S.active and S.entry and S.entry.item == e.item then
    local dpw = math.min(math.floor(w * 0.30), L.cw * 34)
    local ph = wh + (ZH > 0 and (ZH + 2) or 0) + (SBH > 0 and (SBH + 2) or 0)
    S.dt_hot = S.dt_draw(U, L, x, zy_top or wy, dpw, ph)   -- 16 окт: прицел наверху — панель от его верха
    x, w = x + dpw + 2, w - dpw - 2
  end
  -- окно вида (3 окт, зум): va..vb секунд e; колесо над волной — зум у мыши,
  -- вбок / Shift+колесо — прокрутка; новый инструмент — целиком
  local len = e.len > 0 and e.len or 1
  local va = math.max(0, math.min(len, S.va or 0))
  local vb = math.max(va + 1e-3, math.min(len, S.vb or len))
  local span = vb - va
  local function tx(t) return x + math.floor((t - va) / span * w) end
  -- пики на всю длину с плотностью окна; пиксель → индекс по окну
  local ntot = math.max(w, math.min(16384, math.floor(w * len / span)))
  local function idx_of(px, n) return math.floor((va + px / w * span) / len * n) + 1 end
  -- 15 окт: линейка над волной, как в Renoise — кадры источника от начала сэмпла в hex
  if wh > 4 * rh then
    local RH = rh - 2
    U.set(U.BG); gfx.rect(x, wy, w, RH, 1)
    local sr, rate = S.srate(e), (e.rate and e.rate ~= 0) and e.rate or 1
    local f0, f1 = va * rate * sr, vb * rate * sr
    local lw = U.measure('FFFFFF') + 2 * L.pad
    local need = (f1 - f0) * lw / math.max(1, w)          -- кадров на подпись
    local st = 1
    while st < need do                                      -- шаг 1 2 4 8 × 16^k: круглые hex
      local m = 1
      while m < 16 and st * m < need do m = m * 2 end
      if st * m >= need then st = st * m; break end
      st = st * 16
    end
    for k = math.ceil(f0 / st), math.floor(f1 / st) do
      local fr = k * st
      local px = x + math.floor((fr / rate / sr - va) / span * w)
      U.set(U.LINE); gfx.rect(px, wy + RH - 4, 1, 4, 1)
      local lab = ('%X'):format(fr)
      if px + 2 + U.measure(lab) < x + w then U.text(px + 2, wy, lab, U.GREY) end
    end
    U.set(U.LINE); gfx.rect(x, wy + RH - 1, w, 1, 1)
    wy, wh = wy + RH, wh - RH
  end
  U.set(U.PANEL); gfx.rect(x, wy, w, wh, 1)
  local cy, hh = wy + wh / 2, wh / 2 - 1
  local base = U.readable(U.theme('col_tr1_peaks', { 0.55, 0.62, 0.70 }), U.BG, 4.0)
  if e.muted and not e.depot then base = U.mix(base, U.BG, 0.45) end   -- заглушённый — тусклее; 10 окт: кроме lib (там заглушено всё — волна была тусклой всегда)
  U.set(base)
  -- волна правки — теми же пиками item, что просмотр (3 окт): огибающая
  -- S.env читалась линейно и растягивала файл на всю ширину, а item в лупе
  -- за концом файла играет начало — картинки расходились. S.env — для детекции
  -- 10 окт: выделенный слайс — не фоном, а волной чуть ярче; опция waveinv — инверсно:
  -- светлый блок, волна в нём вырезана тёмным
  local zx0, zx1, zcol, zin_prev
  local wave_view = S.view ~= 'sgram' and S.view ~= 'spec'
  if zone and wave_view then
    zx0 = math.max(x, math.min(x + w, tx(math.max(0, math.min(len, zone[1])))))
    zx1 = math.max(x, math.min(x + w, tx(math.max(0, math.min(len, zone[2])))))
    if ctx.state and ctx.state.waveinv then
      U.set(U.mix(base, U.BG, 0.15)); gfx.rect(zx0, wy, math.max(1, zx1 - zx0), wh, 1)
      zcol = U.BG
    else zcol = U.mix(base, { 1, 1, 1 }, 0.35) end
    U.set(base)
  end
  local env = (editing and S.view == 'peaks' and not (ctx.peaks and e.item)) and S.env or nil
  local sgj = S.view == 'sgram' and ctx.sgram and ctx.sgram(e)
  if sgj then
    -- спектрограмма (5 окт): картинка задания, окно зума va..vb; досчитывается
    local c0 = math.floor(va / len * sgj.cols)
    local c1 = math.max(c0 + 1, math.floor(vb / len * sgj.cols))
    gfx.blit(sgj.img, 1, 0, c0, 0, c1 - c0, sgj.rows, x, wy, w, wh)
    if not sgj.done then U.text(x + 4, wy + 2, ('spectrogram %d%%'):format(math.floor(sgj.col / sgj.cols * 100)), U.GREY) end
  elseif S.view == 'sgram' then
    U.text(x + 4, wy + 2, 'spectrogram: no audio to read (wav files and lib items)', U.GREY)
  elseif S.view == 'spec' and ctx.peaks then
    local pk = ctx.peaks(e, ntot, true)
    if pk and pk.n > 0 then
      for px = 0, w - 1 do
        local idx = idx_of(px, pk.n)
        local a, b = pk.min[idx] or 0, pk.max[idx] or 0
        if b - a < 0.02 then a, b = -0.01, 0.01 end
        local cc = (pk.spec and ctx.spec_colour) and ctx.spec_colour(pk.spec[idx]) or base
        if e.muted and not e.depot then cc = U.mix(cc, U.BG, 0.45) end
        gfx.set(cc[1], cc[2], cc[3], 1)
        gfx.line(x + px, cy - b * hh, x + px, cy - a * hh)
      end
    else gfx.line(x, cy, x + w, cy) end
  elseif env and env.n > 0 then
    for px = 0, w - 1 do
      local i0 = idx_of(px, env.n)
      local i1 = idx_of(px + 1, env.n) - 1
      local m = 0
      for i = i0, math.max(i0, i1) do if env.v[i] and env.v[i] > m then m = env.v[i] end end
      local inz = zx0 and x + px >= zx0 and x + px < zx1
      if inz ~= zin_prev then U.set(inz and zcol or base); zin_prev = inz end
      gfx.line(x + px, cy - m * hh, x + px, cy + m * hh)
    end
  else
    local pk = ctx.peaks and ctx.peaks(e, ntot)
    S.dbg = ('sample w=%d src=%s len=%.3f rate=%.2f offs=%.3f pk=%s guid=%s'):format(w, tostring(e.src), e.len or -1, e.rate or -1, e.offs or -1, pk and pk.n or 'nil', tostring(e.guid))
    if pk and pk.n > 0 then
      for px = 0, w - 1 do
        local idx = idx_of(px, pk.n)
        local a, b = pk.min[idx] or 0, pk.max[idx] or 0
        if b - a < 0.02 then a, b = -0.01, 0.01 end
        local inz = zx0 and x + px >= zx0 and x + px < zx1
        if inz ~= zin_prev then U.set(inz and zcol or base); zin_prev = inz end
        gfx.line(x + px, cy - b * hh, x + px, cy - a * hh)
      end
      U.set(base)
    else gfx.line(x, cy, x + w, cy) end
  end
  -- позиция проигрывания файла из браузера (превью) и на большой волне (2 окт)
  if e.file and ctx.preview_pos then
    local pos, plen, ppath = ctx.preview_pos()
    if pos and ppath == e.path and (e.len or 0) > 0 then
      local px = tx(math.max(0, math.min(e.len, pos)))
      U.set(U.AMBER); gfx.rect(px, wy, 1, wh, 1)
    end
  elseif e.item and ctx.preview_src_pos then
    -- превью инструмента, слайса, Shift+нота, MIDI-клавиатура (3 окт): плейхед
    -- на волне любой записи того же файла, если позиция в её отрезке
    local spos, path = ctx.preview_src_pos()
    if spos and path ~= '' and path == e.fpath and (e.len or 0) > 0 then
      local pos = (spos - (e.offs or 0)) / ((e.rate and e.rate ~= 0) and e.rate or 1)
      if pos >= va and pos <= vb then
        local px = math.min(x + w - 1, tx(pos))
        U.set(U.AMBER); gfx.rect(px, wy, 1, wh, 1)
      end
    end
  end
  -- транзиенты (только в правке) и слайсы с буквами
  if editing then
    U.set(U.GREY)
    for _, t in ipairs(S.trans) do
      local px = tx(t)
      if px >= x and px < x + w then gfx.line(px, wy, px, wy + 6); gfx.line(px, wy + wh - 6, px, wy + wh) end
    end
    -- превью квантайзера (5 окт): пойманный удар — голубая черта, цель —
    -- янтарная, между ними стрелка-линия сверху; пропущенные — красные
    if S.qpreview and e.item and S.entry and S.entry.item == e.item and ctx.edit.quant_plan then
      local plan = ctx.edit.quant_plan(e.item, S.quant_hits(), S.qprm)
      for _, k in ipairs(plan.kept) do
        local a, b = tx(k.t), tx(k.n)
        U.set(U.CYAN); gfx.rect(a, wy, 1, wh, 1)
        U.set(U.AMBER); gfx.rect(b, wy, 1, wh, 1)
        gfx.rect(math.min(a, b), wy + 2, math.abs(b - a) + 1, 2, 1)
      end
      U.set(U.RED)
      for _, sk in ipairs(plan.skipped) do local a = tx(sk.t); gfx.rect(a, wy + wh - 10, 1, 10, 1) end
      S.qinfo = ('%d caught, %d skipped, length %.3fs'):format(#plan.kept, #plan.skipped, plan.newlen or 0)
    end
  end
  -- играемая зона исходника: чуть светлее фон и края
  -- края зоны слайса тянутся мышью (2 окт): S.zone_hot = 'a' | 'b' под мышью,
  -- S.wave = прямоугольник волны и длина — main считает долю и правит item
  S.zone_hot = nil
  S.wave = { x = x, y = wy, w = w, h = wh, len = len, va = va, vb = vb }
  -- 10 окт: тянешь линию слайса — край зоны выделенного слайса идёт за ней сразу (не после отпускания)
  if zone and S.drag and S.drag.kind == 'slice' and S.drag.t0 and S.slices[S.drag.k] then
    local nt = S.slices[S.drag.k]
    zone = { zone[1], zone[2], zone[3] }
    if math.abs(zone[1] - S.drag.t0) < 1e-6 then zone[1] = nt end
    if math.abs(zone[2] - S.drag.t0) < 1e-6 then zone[2] = nt end
  end
  S.zone_cur = zone and (S.entry and S.entry.item == e.item) and zone or nil
  if zone then
    local za, zb = math.max(0, math.min(len, zone[1])), math.max(0, math.min(len, zone[2]))
    local px0, px1 = math.max(x, math.min(x + w, tx(za))), math.max(x, math.min(x + w, tx(zb)))
    local mxw, myw = gfx.mouse_x, gfx.mouse_y
    local inw = myw >= wy and myw < wy + wh
    local dragging = S.zone_drag and S.zone_drag.edge
    -- ручки (2 окт, правка): треугольники начала и конца — вверху, под строкой
    -- подписей маркеров (сами подписи не перекрываются); полоса внизу зоны —
    -- тянет всю зону целиком. Маркеры исходника тянутся вне этих полос.
    local TY = wy + 1                     -- треугольники — у верхнего края волны (4 окт)
    local TH = 8
    local BY = wy + wh - 6                -- полоса переноса
    if not S.drag and inw then
      local da, db = math.abs(mxw - px0), math.abs(mxw - px1)
      if myw >= TY and myw < TY + TH and math.min(da, db) <= 6 then S.zone_hot = (da <= db) and 'a' or 'b'
      elseif myw >= BY - 2 and mxw >= px0 and mxw <= px1 then S.zone_hot = 'move' end
    end
    if not wave_view then U.set(U.TEXT); gfx.a = 0.10; gfx.rect(px0, wy, math.max(1, px1 - px0), wh, 1); gfx.a = 1 end   -- спектр / спектрограмма — фоном, как было
    for _, ed in ipairs({ { 'a', px0 }, { 'b', math.max(px0, px1 - 1) } }) do
      local hot = S.zone_hot == ed[1] or dragging == ed[1]
      U.set(hot and U.AMBER or U.TEXT); gfx.a = hot and 1 or 0.55
      gfx.rect(hot and ed[2] - 1 or ed[2], wy, hot and 3 or 1, wh, 1)
      gfx.a = 1
      -- треугольник внутрь зоны
      local d = ed[1] == 'a' and 1 or -1
      for k = 0, 6 do
        local wdt = 7 - k
        gfx.rect(d > 0 and ed[2] or (ed[2] - wdt + 1), TY + k, wdt, 1, 1)
      end
    end
    -- MIDI-нота слайса (4 окт) — справа от треугольника начала (C4, C#4 …)
    -- 10 окт: нота зоны сверху убрана — у каждой линии слайса своя нота внизу
    S.zone_px0 = px0
    -- полоса переноса всей зоны
    local mhot = S.zone_hot == 'move' or dragging == 'move'
    -- 10 окт: цветом линий слайса и у самого низа — с краями зоны под прямым углом
    U.set(U.AMBER); gfx.a = mhot and 1 or 0.85
    gfx.rect(px0, wy + wh - 4, math.max(2, px1 - px0 + 1), 4, 1)
    gfx.a = 1
  end
  -- 11 окт: начало и конец самого item — ручки-треугольники снизу волны (голубые);
  -- тянуть внутрь — обрезать, за край волны — расширить в пределах файла.
  -- На отпускании main правит все ноты инструмента (ctx.autotrim, один undo)
  S.item_hot, S.item_e = nil, nil
  if e.item and not e.file and wave_view then
    S.item_e = e
    local mxw, myw = gfx.mouse_x, gfx.mouse_y
    local IY = wy + wh - 18
    local idg = S.item_drag and S.item_drag.e and S.item_drag.e.item == e.item and S.item_drag or nil
    for _, ed in ipairs({ { 'ia', 0 }, { 'ib', len } }) do
      local mine = idg and idg.edge == ed[1]
      local t = (mine and idg.t) or ed[2]
      if mine or (t >= va - 1e-6 and t <= vb + 1e-6) then
        local px = math.max(x, math.min(x + w - 1, tx(t)))
        if ed[1] == 'ib' and not mine then px = math.max(x, px - 1) end
        if not S.drag and not idg and not (S.zone_drag) and myw >= IY and myw < IY + 10 and math.abs(mxw - px) <= 6 then S.item_hot = ed[1]; S.zone_hot = nil end
        local hot = S.item_hot == ed[1] or mine
        -- отрезаемая часть — притушена
        if mine and ed[1] == 'ia' and t > 0 then gfx.set(0, 0, 0, 0.55); gfx.rect(x, wy, math.max(0, px - x), wh, 1) end
        if mine and ed[1] == 'ib' and t < len then gfx.set(0, 0, 0, 0.55); gfx.rect(px, wy, math.max(0, x + w - px), wh, 1) end
        gfx.a = 1
        U.set(hot and U.AMBER or U.CYAN)
        if mine or hot then gfx.rect(px, wy, 1, wh, 1) end
        local d = ed[1] == 'ia' and 1 or -1
        for k = 0, 6 do local wdt = 7 - k; gfx.rect(d > 0 and px or (px - wdt + 1), IY + 9 - k, wdt, 1, 1) end
      end
    end
  end
  -- клип сессии (6 окт): метки лупа L (тянутся: S.zone_hot 'la' / 'lb'),
  -- кнопка xf — кроссфейд шва лупа (клик — 0 / 10 / 30 / 60 / 120 мс)
  if zone and zone.loop then
    local mxw, myw = gfx.mouse_x, gfx.mouse_y
    local dragging = S.zone_drag and S.zone_drag.edge
    for i, t in ipairs(zone.loop) do
      if t >= va and t <= vb then
        local lx = tx(t)
        local nm = i == 1 and 'la' or 'lb'
        local hot0 = not S.drag and not S.zone_hot and myw >= wy + 10 and myw < wy + wh - 8 and math.abs(mxw - lx) <= 4
        if hot0 then S.zone_hot = nm end
        local hot = S.zone_hot == nm or dragging == nm
        U.set(U.CYAN); gfx.rect(hot and lx - 1 or lx, wy, hot and 3 or 1, wh, 1)
        U.text(lx + 3, wy + wh - L.rh - 7, 'L', hot and U.AMBER or U.CYAN)
      end
    end
    if zone.clip then
      local lbl = ('xf %d ms'):format(math.floor((zone.xf or 0) * 1000 + 0.5))
      local bw = U.measure(lbl) + 2 * L.pad
      local bx, by = x + w - bw - 2, wy + 2
      local hot = gfx.mouse_x >= bx and gfx.mouse_x < bx + bw and gfx.mouse_y >= by and gfx.mouse_y < by + rh
      if hot and not S.drag then S.zone_hot = 'xf' end
      U.set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, by, bw, rh, 1)
      U.set((zone.xf or 0) > 0 and U.CYAN or U.LINE); gfx.rect(bx, by, bw, rh, 0)
      U.text(bx + L.pad, by + 1, lbl, (zone.xf or 0) > 0 and U.CYAN or U.GREY)
    end
  end
  local slices = editing and S.slices or (e.slices or {})
  local hover_slice
  -- подписи слайсов (4 окт): клавиша хроматической раскладки q 2 w 3 e r 5 t …,
  -- которая вставит этот слайс на текущей октаве (слайс k = нота C-4 + k - 1);
  -- клавиши нет — номер
  local key_of = {}
  do
    local oct = (ctx and ctx.octave and ctx.octave()) or 4
    local base = (ctx and ctx.slice_base and ctx.slice_base()) or 60
    for code in pairs((ctx and ctx.piano) or {}) do
      local off = item_off(code)
      if off then
        local k = (oct + 1) * 12 + off - base + 1
        local nm = code < 256 and string.char(code) or (ctx.key_name and ctx.key_name(code)) or '?'   -- 16 окт: F-ряд (frow) — f4
        key_of[k] = (code < 256 and ctx.key_label and ctx.key_label(nm)) or nm
      end
    end
  end
  -- 15 окт: первый слайс — начало сэмпла, конец последнего — его конец: волна вне — притушена,
  -- края — скобками [ ] во всю высоту (видно, что играет, после dd первых слайсов)
  if #slices > 0 and wave_view then
    local a0 = slices[1]
    local pa, pb = tx(a0), tx(len)
    if a0 > va + 1e-6 then gfx.set(0, 0, 0, 0.6); gfx.rect(x, wy, math.max(0, math.min(x + w, pa) - x), wh, 1) end
    if pb < x + w then gfx.set(0, 0, 0, 0.6); gfx.rect(math.max(x, pb), wy, x + w - math.max(x, pb), wh, 1) end
    gfx.a = 1
    U.set(U.AMBER)
    if pa >= x and pa < x + w then gfx.rect(pa, wy, 2, wh, 1); gfx.rect(pa, wy, 6, 2, 1); gfx.rect(pa, wy + wh - 2, 6, 2, 1) end
    if pb > x and pb <= x + w then gfx.rect(pb - 2, wy, 2, wh, 1); gfx.rect(pb - 6, wy, 6, 2, 1); gfx.rect(pb - 6, wy + wh - 2, 6, 2, 1) end
  end
  -- 15 окт: в файле есть звук за краем сэмпла — метка у края «< 3.21s» / «10.27s >»; щелчок
  -- (или g{ g}) возвращает его
  S.more_hot = nil
  if wave_view and e.item and not e.file then
    local pre, post = S.more(e)
    local function tag(side, secs)
      local lab = side == 'a' and ('< %.2fs'):format(secs) or ('%.2fs >'):format(secs)
      local tw = U.measure(lab) + 2 * L.pad
      local bx = side == 'a' and (x + 8) or (x + w - tw - 8)
      local by = wy + math.floor((wh - rh) / 2)   -- 16 окт: посередине волны по высоте (внизу налезала на подписи нот)
      local hot = gfx.mouse_x >= bx and gfx.mouse_x < bx + tw and gfx.mouse_y >= by and gfx.mouse_y < by + rh
      if hot then S.more_hot = side end
      -- край волны штрихами: там продолжается файл
      U.set(U.CYAN)
      local ex = side == 'a' and x or (x + w - 3)
      for yy = wy, wy + wh - 1, 4 do gfx.rect(ex, yy, 3, 2, 1) end
      U.set(hot and U.tint(U.CYAN, 0.35) or U.BG); gfx.rect(bx, by, tw, rh, 1)
      U.set(U.CYAN); gfx.rect(bx, by, tw, rh, 0)
      U.text(bx + L.pad, by, lab, hot and U.TEXT or U.CYAN)
    end
    if pre and pre > 0.005 and va <= 1e-6 then tag('a', pre) end
    if post and post > 0.005 and vb >= len - 1e-6 then tag('b', post) end
  end
  -- 15 окт: курсор волны (gw) — светлая линия с hex-кадром
  if S.wcur and S.wcur_e == e.item and S.wcur >= va and S.wcur <= vb then
    local px = tx(S.wcur)
    local lab = ('%X'):format(S.frame_of(e, S.wcur))
    U.set(U.TEXT); gfx.rect(px, wy, 1, wh, 1); gfx.rect(px + 1, wy + 1, U.measure(lab) + 4, rh, 1)
    U.text(px + 3, wy + 1, lab, U.BG, U.TEXT)
  end
  local in_wave = gfx.mouse_x >= x and gfx.mouse_x < x + w and gfx.mouse_y >= wy and gfx.mouse_y < wy + wh
  local lab_end = -1e9            -- 6 окт: подписи не налезают — только если влезает до следующей линии и после прошлой подписи
  for k, t in ipairs(slices) do
    local px = tx(t)
    -- только в рамках волны (3 окт: слайсы исходника за концом показанного куска лезли на свойства)
    if t < va - 1e-6 or px > x + w - 1 then goto next_slice end
    local hot = (in_wave and math.abs(gfx.mouse_x - px) <= 4) or (S.drag and S.drag.kind == 'slice' and S.drag.k == k)
    if hot then hover_slice = k end
    local onkey = key_of[k] ~= nil
    U.set(hot and U.TEXT or (onkey and U.AMBER or U.CYAN)); gfx.rect(hot and (px - 1) or px, wy, hot and 3 or 1, wh, 1)
    -- 10 окт: номер — сверху слева; нота MIDI — внизу слева; клавиша — над нотой,
    -- только с включённой клавиатурой; у выделенного слайса — на тех же местах
    local base = (ctx and ctx.slice_base and ctx.slice_base()) or 61
    local p = base + k - 1
    local NM = { 'C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-' }
    local num = ('%02X'):format(k)
    local note = (p >= 0 and p <= 127) and (NM[p % 12 + 1] .. (p // 12 - 1)) or ''
    local keyl = (ctx and ctx.piano_on and ctx.piano_on()) and (key_of[k] or '') or ''
    local lw = math.max(U.measure(num), U.measure(note), keyl ~= '' and U.measure(keyl) or 0)
    local edge = zone and S.zone_px0 and math.abs(px - S.zone_px0) < 3
    local lx = px + (edge and 9 or 3)                    -- у края зоны — правее треугольника
    local nx = slices[k + 1] and math.min(x + w, tx(slices[k + 1])) or (x + w)
    if lx + lw <= nx - 1 and lx >= lab_end + 2 and wh >= 3 * rh + 8 then
      local cc = hot and U.TEXT or (onkey and U.AMBER or U.CYAN)
      -- 11 окт: подписи на чёрной подложке — волна под ними не мешает читать
      -- 20 окт: подложка на четверть светлее чёрного (к фону темы), цифры — до контраста 7:1 к ней (оттенок тот же)
      local back = U.mix({ 0, 0, 0 }, U.BG, 0.25)
      local function lab(ty, str, col)
        if str == '' then return end
        U.set(back); gfx.rect(lx - 1, ty, U.measure(str) + 2, rh - 1, 1)
        U.text(lx, ty, str, U.readable(col, back, 7))
      end
      lab(wy + 1, num, cc)
      local by = wy + wh - rh - 7                        -- над полосой переноса зоны
      lab(by, note, hot and U.TEXT or U.GREY)
      lab(by - rh, keyl, cc)
      lab_end = lx + lw
    end
    ::next_slice::
  end
  -- выделение (общее для правки и просмотра: S.entry совпадает с e)
  local sel = (S.entry and (S.entry == e or S.entry.item == e.item and e.item)) and S.sel or nil
  if sel then
    local a, b = math.min(sel.a, sel.b), math.max(sel.a, sel.b)
    local px0, px1 = tx(a), tx(b)
    px0, px1 = math.max(x, math.min(x + w, px0)), math.max(x, math.min(x + w, px1))
    U.set(U.AMBER); gfx.a = 0.25; gfx.rect(px0, wy, math.max(1, px1 - px0), wh, 1); gfx.a = 1
    gfx.rect(px0, wy, 1, wh, 1); gfx.rect(math.max(px0, px1 - 1), wy, 1, wh, 1)
  end
  local foot = (editing and S.msg ~= '' and S.msg ~= ('%d slices stored'):format(#S.slices)) and S.msg
    or ((#slices > 0 and ctx.state and ctx.state.hints) and '1 f1 2 ... slices  ` whole  Opt+key pitch' or '')   -- 13 окт: подсказка клавиш — только при хинтах   -- 10 окт: коротко — число слайсов и так видно
  if sel then foot = ('sel %.3fs - %.3fs (%.3fs)  Enter: insert @cursor  D: lib  drag: to a track / the lib as a slice   '):format(math.min(sel.a, sel.b), math.max(sel.a, sel.b), math.abs(sel.b - sel.a)) .. foot end
  if span < len - 1e-6 then foot = ('zoom %.2f-%.2fs  wheel: zoom, sideways: scroll   '):format(va, vb) .. foot end
  -- зум края (10 окт, Nerve): окрестность края ±S.zwin крупно; тянуть — точно двигать
  -- линию слайса (отпустил — сохранено), колесо — шире / уже
  S.zoom_hot = nil
  -- 15 окт: beatsync — линейка битов по низу волны: N рисок на длину сэмпла, такт (4) — длиннее; без цифр (подписи нот рядом)
  if e.bsync and e.bsync > 0 and len > 0 then
    local nb = math.floor(e.bsync + 0.5)
    for k = 0, nb do
      local t = len * k / nb
      if t >= va - 1e-6 and t <= vb + 1e-6 then
        local px = tx(t)
        local bar = k % 4 == 0
        U.set(bar and U.AMBER or U.GREY); gfx.rect(px, wy + wh - (bar and 8 or 4), 1, bar and 8 or 4, 1)
      end
    end
  end
  -- 10 окт: плейхед — белая линия в волне (и в зуме, и на полоске-обзоре ниже)
  local pht, pt0
  if ctx.item_playpos and e.item then pht, pt0 = ctx.item_playpos(e.item) end
  if pht and (pht < 0 or pht > len) then pht = nil end
  -- 10 окт: след — сыгранный кусок подсвечен и гаснет 1.5 с после конца: короткий слайс
  -- пролетает за пару кадров, а след остаётся видно, где именно прошёл звук
  local now = reaper.time_precise()
  if pht and pt0 then
    local tr = S.trail
    if not (tr and tr.item == e.item and tr.a == pt0 and pht >= tr.b - 0.05) then tr = { item = e.item, a = pt0, b = pt0 }; S.trail = tr end
    tr.b, tr.at = math.max(tr.b, pht), now
  end
  local trl = S.trail and S.trail.item == e.item and S.trail
  local tra = trl and (pht and 0.16 or 0.16 * (1 - (now - trl.at) / 0.6)) or 0   -- 10 окт: тусклее, гаснет за 0.6 с
  if trl and tra <= 0 then S.trail, trl = nil, nil end
  local function trail_rect(t0z, t1z, x0, w0, y0, h0)       -- след в окне t0z..t1z шириной w0
    if not trl then return end
    local a2, b2 = math.max(trl.a, t0z), math.min(trl.b, t1z)
    if b2 <= a2 then return end
    local px0 = x0 + math.floor((a2 - t0z) / (t1z - t0z) * w0)
    local px1 = x0 + math.floor((b2 - t0z) / (t1z - t0z) * w0)
    -- градиент одной нативной gradrect: у начала прозрачно, к плейхеду ярче
    local ww = math.max(1, px1 - px0)
    local c = U.TEXT
    local span2 = math.max(1e-6, trl.b - trl.a)
    local al0, al1 = tra * (a2 - trl.a) / span2, tra * (b2 - trl.a) / span2   -- окно зума режет след — яркость по месту, не заново
    gfx.gradrect(px0, y0, ww, h0, c[1], c[2], c[3], al0, 0, 0, 0, (al1 - al0) / ww)
  end
  trail_rect(va, vb, x, w, wy, wh)
  if ZH > 0 then
    local zy = zy_top or (wy + wh + 2)
    local W2 = S.zwin or 0.04
    local t0 = zt - W2                     -- край — по центру окна
    U.set(U.BG); gfx.rect(x, zy, w, ZH, 1)
    -- 16 окт: прицел — бледная сетка трекера (такты / доли / строки) и stretch-маркеры ноты, в секундах окна (по маркерам)
    local zgrid = S.cross and zlab and zlab:match('^cursor') and ctx.aim_grid and ctx.aim_grid(S.cross, t0, t0 + 2 * W2)
    if zgrid then
      for _, g in ipairs(zgrid.rows) do
        local gx = x + math.floor((g.te - t0) / (2 * W2) * w)
        U.set(U.mix(U.TEXT, U.BG, g.kind == 'bar' and 0.45 or (g.kind == 'beat' and 0.65 or 0.82)))
        gfx.rect(gx, zy, 1, ZH, 1)
      end
    end
    local smp, n = zoom_samples(e, t0, 2 * W2)
    local zc, zh2 = zy + ZH / 2, ZH / 2 - 2
    -- 10 окт: зум повторяет вид волны — sgram: кусок спектрограммы фоном; spec: окраска по частоте
    local sgz = S.view == 'sgram' and ctx.sgram and ctx.sgram(e)
    if sgz then
      local c0 = math.max(0, t0 / len * sgz.cols)
      local cw2 = math.max(1, 2 * W2 / len * sgz.cols)
      gfx.a = 0.85; gfx.blit(sgz.img, 1, 0, c0, 0, cw2, sgz.rows, x, zy, w, ZH); gfx.a = 1
    end
    local spk = S.view == 'spec' and ctx.peaks and ctx.peaks(e, math.max(w, math.min(16384, math.floor(w * len / span))), true)
    if smp and n then
      local pk = 0.02
      for i = 1, n do local v = math.abs(smp[i] or 0); if v > pk then pk = v end end
      U.set(sgz and U.TEXT or base)
      local function spcol(tt)
        if spk and spk.spec and spk.n > 0 and ctx.spec_colour then
          local cc = ctx.spec_colour(spk.spec[math.max(1, math.min(spk.n, math.floor(tt / len * spk.n) + 1))])
          gfx.set(cc[1], cc[2], cc[3], 1)
        end
      end
      if n / w < 4 then
        -- 10 окт: мало сэмплов на пиксель — сплошная линия через сэмплы (чёрточки min..max рассыпались в точки)
        local px0, py0
        for i = 1, n do
          local xx = x + (i - 0.5) / n * w
          local yy = zc - (smp[i] or 0) / pk * zh2
          spcol(t0 + (i - 0.5) / n * 2 * W2)
          if px0 then gfx.line(px0, py0, xx, yy, 1) end
          px0, py0 = xx, yy
        end
      end
      for px = 0, (n / w < 4) and -1 or (w - 1) do
        local i0, i1 = math.floor(px / w * n) + 1, math.max(math.floor(px / w * n) + 1, math.floor((px + 1) / w * n))
        local mn, mx3 = 1e9, -1e9
        for i = i0, math.min(n, i1) do local v = smp[i] or 0; if v < mn then mn = v end; if v > mx3 then mx3 = v end end
        spcol(t0 + (px + 0.5) / w * 2 * W2)
        if mx3 >= mn then gfx.line(x + px, zc - mx3 / pk * zh2, x + px, zc - mn / pk * zh2) end
      end
    else U.text(x + 4, zy + rh + 2, 'no audio to read here', U.GREY) end   -- 10 окт: второй строкой (налезало на подпись края)
    -- 11 окт: до нулевого сэмпла item и после его конца — пустота (не звук файла за краями item)
    -- 12 окт: прицел ноты из другого куска файла — край item не граница, звук файла там есть (zoom_samples читает
    -- его напрямую); пустота только до начала файла (маска по краям item затирала всё окно: «не видно»)
    local aimz = S.cross and zlab and zlab:match('^cursor') and S.zr and S.zr.file
    if aimz then
      local rate = (e.rate and e.rate ~= 0) and math.abs(e.rate) or 1
      local fr0 = (e.offs or 0) + t0 * rate
      if fr0 < 0 then U.set(U.BG); gfx.rect(x, zy, math.min(w, math.floor(-fr0 / (2 * W2 * rate) * w)), ZH, 1) end
    elseif t0 < 0 then U.set(U.BG); gfx.rect(x, zy, math.min(w, math.floor(-t0 / (2 * W2) * w)), ZH, 1) end
    if not aimz and t0 + 2 * W2 > len then
      local ex = x + math.max(0, math.floor((len - t0) / (2 * W2) * w))
      U.set(U.BG); gfx.rect(ex, zy, x + w - ex, ZH, 1)
    end
    -- линии слайсов в окне и сам край по центру
    local zsl = (S.active and S.entry and S.entry.item == e.item) and S.slices or (e.slices or {})
    for k2, t2 in ipairs(zsl) do
      if k2 ~= zk and t2 > t0 and t2 < t0 + 2 * W2 then U.set(U.CYAN); gfx.rect(x + math.floor((t2 - t0) / (2 * W2) * w), zy, 1, ZH, 1) end
    end
    -- 16 окт: stretch-маркеры как в REAPER: линии скорости отрезков (выше центра — быстрее), ромб из половинок по скоростям
    -- слева / справа (зелёный — быстрее, фиолетовый — медленнее); ромб тянется мышью (точно, без привязки, один undo)
    if zgrid then
      local function rc(r) if not r or math.abs(r - 1) < 0.005 then return U.TEXT end; return r > 1 and U.GREEN or (U.MAGENTA or U.mix(U.RED, U.CYAN, 0.5)) end
      local zc2 = zy + math.floor(ZH / 2)
      local mxz, myz = gfx.mouse_x, gfx.mouse_y
      S.zslope_hot = nil
      -- линия скорости: от r·(1 − slope) в начале отрезка к r·(1 + slope) в конце (наклон — постепенное ускорение);
      -- тянуть линию вверх / вниз — наклон (Option+клик — сброс в 0)
      local function ry(r) return zc2 - math.floor(math.max(-1, math.min(1, (r - 1) * 2)) * (ZH / 2 - 4)) end
      for _, sg in ipairs(zgrid.segs) do
        local sl = sg.sl or 0
        local xa, xb = x + math.floor((sg.a - t0) / (2 * W2) * w), x + math.floor((sg.b - t0) / (2 * W2) * w)
        local function rat(t) local f = (sg.tb > sg.ta) and (t - sg.ta) / (sg.tb - sg.ta) or 0; return sg.r * (1 - sl) + 2 * sg.r * sl * f end
        local ya, yb = ry(rat(sg.a)), ry(rat(sg.b))
        local near = mxz >= xa and mxz <= xb and xb > xa and math.abs(myz - (ya + (yb - ya) * (mxz - xa) / math.max(1, xb - xa))) <= 3
        if near and not S.zsmk_drag then S.zslope_hot = sg end
        if math.abs(sg.r - 1) >= 0.005 or math.abs(sl) > 0.005 or near then
          U.set(near and U.AMBER or rc(sg.r)); gfx.line(xa, ya, xb, yb, 1)
          if xb - xa > U.measure('0.00x') + 4 then U.text(xa + 3, zy + ZH - rh - 1, ('%.2fx'):format(sg.r), U.mix(U.TEXT, U.BG, 0.3)) end
        end
      end
      local downz = (gfx.mouse_cap & 1) == 1
      local pressz = downz and not S.zp_prev
      S.zp_prev = downz
      S.zsmk_hot = nil
      local hz = math.max(4, math.floor(rh / 2))
      for _, m in ipairs(zgrid.smk) do
        local gx = x + math.floor((m.te - t0) / (2 * W2) * w)
        local hot = math.abs(mxz - gx) <= hz and myz >= zy and myz < zy + ZH
        if hot then S.zsmk_hot = m end
        U.set(hot and U.AMBER or U.mix(U.AMBER, U.BG, 0.3)); gfx.rect(gx, zy, hot and 2 or 1, ZH, 1)
        U.set(rc(m.up)); gfx.triangle(gx, zc2 - hz, gx - hz, zc2, gx, zc2 + hz)
        U.set(rc(m.dn)); gfx.triangle(gx + 1, zc2 - hz, gx + 1 + hz, zc2, gx + 1, zc2 + hz)
        if pressz and hot and not S.zsmk_drag and ctx.edit and (gfx.mouse_cap & 16) == 16 then
          -- 22 окт: Option+щелчок — удалить маркер (как в REAPER и в колонке волны трекера)
          local it = zgrid.item
          local tk = it and R.ValidatePtr(it, 'MediaItem*') and R.GetActiveTake(it)
          if tk then
            ctx.edit.run('stretch marker delete', function() R.DeleteTakeStretchMarkers(tk, m.idx, 1); R.UpdateItemInProject(it) end)
            if ctx.edit.note_modified then ctx.edit.note_modified(it) end
            S.msg = 'stretch marker removed (Option+click)'
            if ctx.model then ctx.model.invalidate() end
          end
          pressz = false
        elseif pressz and hot and not S.zsmk_drag and ctx.edit then
          S.zsmk_drag = { idx = m.idx, p0 = m.p, x0 = mxz, lo = m.lo, hi = m.hi, item = zgrid.item, spp = 2 * W2 / w * zgrid.k, active = false }
        end
      end
      -- наклон отрезка мышью
      if pressz and S.zslope_hot and not S.zsmk_hot and not S.zsmk_drag then
        local sg = S.zslope_hot
        local tk = R.ValidatePtr(zgrid.item, 'MediaItem*') and R.GetActiveTake(zgrid.item)
        if tk and (gfx.mouse_cap & 16) == 16 then
          ctx.edit.run('stretch slope reset', function() R.SetTakeStretchMarkerSlope(tk, sg.idx, 0); R.UpdateItemInProject(zgrid.item) end)
          if ctx.model and ctx.model.invalidate then ctx.model.invalidate() end
        elseif tk then
          S.zslope_drag = { idx = sg.idx, s0 = sg.sl or 0, y0 = myz, item = zgrid.item, active = false, side = (mxz - x) / w > ((sg.a + sg.b) / 2 - t0) / (2 * W2) and 1 or -1 }
        end
      end
      local sd = S.zslope_drag
      if sd then
        local tk = R.ValidatePtr(sd.item, 'MediaItem*') and R.GetActiveTake(sd.item)
        if downz and tk then
          if not sd.active and math.abs(myz - sd.y0) > 2 then sd.active = true; ctx.edit.item_drag_begin('stretch slope') end
          if sd.active then
            -- за правую половину — конец отрезка вверх = быстрее к концу; за левую — наоборот
            local ns = math.max(-0.99, math.min(0.99, sd.s0 + (sd.y0 - myz) / (ZH / 2) * sd.side))
            R.SetTakeStretchMarkerSlope(tk, sd.idx, ns); R.UpdateItemInProject(sd.item)
            S.msg = ('stretch slope %.2f (Option+click on the line: 0)'):format(ns)
            if ctx.model and ctx.model.invalidate then ctx.model.invalidate() end
          end
        else
          if sd.active then ctx.edit.note_modified(sd.item); ctx.edit.item_drag_end() end
          S.zslope_drag = nil
        end
      elseif S.zslope_hot and not S.zsmk_hot then S.msg = 'stretch rate line - drag up / down: slope (gradual speed-up / slow-down), Option+click: back to 0' end
      local dg = S.zsmk_drag
      if dg then
        local tk = R.ValidatePtr(dg.item, 'MediaItem*') and R.GetActiveTake(dg.item)
        if downz and tk then
          if not dg.active and math.abs(mxz - dg.x0) > 2 then dg.active = true; ctx.edit.item_drag_begin('stretch marker') end
          if dg.active then
            local np = math.max(dg.lo + 0.002, math.min(dg.hi - 0.002, dg.p0 + (mxz - dg.x0) * dg.spp))
            R.SetTakeStretchMarker(tk, dg.idx, np); R.UpdateItemInProject(dg.item)
            S.msg = ('stretch marker %+.1f ms'):format((np - dg.p0) * 1000)
            if ctx.model and ctx.model.invalidate then ctx.model.invalidate() end
          end
        else
          if dg.active then ctx.edit.note_modified(dg.item); ctx.edit.item_drag_end() end
          S.zsmk_drag = nil
        end
      elseif S.zsmk_hot then S.msg = 'stretch marker - drag: move it (fine, no snap), Option+click: delete; in the tracker: drag the amber line, S / x / J K' end
    end
    U.set(U.AMBER); gfx.rect(x + math.floor(w / 2), zy, 2, ZH, 1)
    trail_rect(t0, t0 + 2 * W2, x, w, zy, ZH)
    if pht and pht > t0 and pht < t0 + 2 * W2 then U.set(U.TEXT); gfx.rect(x + math.floor((pht - t0) / (2 * W2) * w), zy, 1, ZH, 1) end
    -- 10 окт: сверху — только цифры; подсказка — внизу и только с хинтами
    do   -- 11 окт: на чёрной подложке, как подписи слайсов
      local zs = ctx.fit(('%s  %.4fs  ±%d ms'):format(zlab or 'edge', zt, math.floor(W2 * 1000 + 0.5)), w - 8 - (U.measure('spam') + 2 * L.pad + 6))
      gfx.set(0, 0, 0, 1); gfx.rect(x + 3, zy + 1, U.measure(zs) + 2, rh - 1, 1)
      U.text(x + 4, zy + 1, zs, U.GREY)
    end
    if ctx.hints_on and ctx.hints_on() and ZH > 3 * rh then
      U.hint_text(x + 4, zy + ZH - rh - 1, zk and 'drag: fine move   wheel: wider / closer' or 'wheel: wider / closer', w - 8, U.BG)
    end
    local mx2, my2 = gfx.mouse_x, gfx.mouse_y
    local down = (gfx.mouse_cap & 1) == 1
    -- 10 окт: кнопка spam (была auto play) справа вверху прицела — сдвинул линию и отпустил: слайс играет сам
    local ap_on = ctx.state and ctx.state.sliceaudition
    local apl = 'spam'
    local apw = U.measure(apl) + 2 * L.pad
    local apx, apy = x + w - apw - 2, zy + 1
    local aphot = mx2 >= apx and mx2 < apx + apw and my2 >= apy and my2 < apy + rh
    S.ap_hot = aphot
    U.set(ap_on and U.tint(U.CYAN, 0.3) or (aphot and U.tint(U.AMBER, 0.3) or U.BG)); gfx.rect(apx, apy, apw, rh - 1, 1)
    U.set(ap_on and U.CYAN or (aphot and U.AMBER or U.LINE)); gfx.rect(apx, apy, apw, rh - 1, 0)
    U.text(apx + L.pad, apy, apl, ap_on and U.CYAN or (aphot and U.AMBER or U.TEXT))
    if aphot and down and not S.zd_prev and ctx.state then
      ctx.state.sliceaudition = not ctx.state.sliceaudition
      S.msg = 'spam ' .. (ctx.state.sliceaudition and 'on: a moved slice line plays its slice' or 'off')
    end
    local tg_hot = false   -- 12 окт: 0-cross / t-snap / quant — строкой под прицелом
    local inz = not aphot and not tg_hot and mx2 >= x and mx2 < x + w and my2 >= zy and my2 < zy + ZH
    if inz then S.zoom_hot = true end
    if down and inz and not S.zd_prev and zk and S.active and S.entry and S.entry.item == e.item and S.slices[zk] then
      S.zdrag = { k = zk, mx0 = mx2, t0 = S.slices[zk], span = 2 * W2 }
    end
    -- 12 окт: прицел ноты курсора — тянуть мышью в окне (точка реза)
    if down and inz and not S.zd_prev and not zk and S.cross then S.xdrag = { mx0 = mx2, dt0 = S.cross.dt, span = 2 * W2 } end
    if S.xdrag then
      if down and S.cross then S.cross.dt = S.xdrag.dt0 + (mx2 - S.xdrag.mx0) / w * S.xdrag.span else S.xdrag = nil end
    end
    if S.zdrag and S.slices[S.zdrag.k] then
      local k3 = S.zdrag.k
      local lo, hi = S.slices[k3 - 1] and (S.slices[k3 - 1] + 0.002) or 0, (S.slices[k3 + 1] or len) - 0.002   -- первый — до 0
      S.slices[k3] = math.max(lo, math.min(hi, S.zdrag.t0 + (mx2 - S.zdrag.mx0) / w * S.zdrag.span))
      if down and math.abs(S.slices[k3] - S.zdrag.t0) > 1e-6 then S.roll(S.slices[k3], S.line_is_end(S.zdrag.t0)) end   -- roll
      if not down then
        local moved = math.abs(S.slices[k3] - S.zdrag.t0) > 1e-6
        local zt0 = S.zdrag.t0
        S.zdrag = nil
        if moved then commit(); S.msg = ('slice %02X moved (fine)'):format(k3); S.roll(S.slices[k3], S.line_is_end(zt0), true) end
      end
    end
    S.zd_prev = down
  end
  -- полоска-обзор (10 окт): весь item, рамка — что видно сейчас; тянуть / щёлкнуть — прокрутка
  -- 17 окт: полоса — в нижней строке модуля (между подсказкой и cut … quant), волна высоту не теряет
  local function ovbar(x, sy, w, SBH)
    local mx2, my2 = gfx.mouse_x, gfx.mouse_y
    local inside = mx2 >= x and mx2 < x + w and my2 >= sy and my2 < sy + SBH
    U.set(U.BG); gfx.rect(x, sy, w, SBH, 1)
    local pk = wavebar and ctx.peaks and ctx.peaks(e, math.max(16, w))
    U.set(U.mix(base, U.BG, 0.35))
    if not wavebar then U.set(U.DIM); gfx.rect(x, sy + math.floor(SBH / 2), w, 1, 1) end   -- обычная полоса: дорожка
    if pk and pk.n > 0 then
      local c2, h2 = sy + SBH / 2, SBH / 2
      for px = 0, w - 1, 2 do
        local idx = math.floor(px / w * pk.n) + 1
        local a, b = pk.min[idx] or 0, pk.max[idx] or 0
        gfx.rect(x + px, math.floor(c2 - b * h2), 1, math.max(1, math.floor((b - a) * h2)), 1)
      end
    end
    if pht then U.set(U.TEXT); gfx.rect(x + math.floor(pht / len * w), sy, 1, SBH, 1) end
    local zoomed = span < len - 1e-6
    local p0, p1 = x + math.floor(va / len * w), x + math.max(2, math.floor(vb / len * w))
    if zoomed then
      U.set(U.AMBER); gfx.a = (inside or S.sbdrag) and 0.30 or 0.18; gfx.rect(p0, sy, math.max(2, p1 - p0), SBH, 1); gfx.a = 1
      gfx.rect(p0, sy, math.max(2, p1 - p0), SBH, 0)
    else U.set(U.LINE); gfx.rect(x, sy, w, SBH, 0) end
    local down = (gfx.mouse_cap & 1) == 1
    if down and inside and not S.sb_prev and zoomed then
      local t = (mx2 - x) / w * len
      S.sbdrag = { off = (t >= va and t <= vb) and (t - va) or span / 2 }   -- щелчок мимо рамки — рамка центром туда
    end
    if not down then S.sbdrag = nil end
    S.sb_prev = down
    if S.sbdrag then
      local t = (mx2 - x) / w * len
      local nva = math.max(0, math.min(len - span, t - S.sbdrag.off))
      S.va, S.vb = nva, nva + span
    end
  end
  -- 12 окт: строка под прицелом — слева подсказка, справа в линию spam / 0-cross / t-snap / quant
  do
    local fy = wy + wh + ((ZH > 0 and not ztop) and (ZH + 2) or 0) + (SBH > 0 and (SBH + 2) or 0) + 2   -- 16 окт: прицел наверху — его высота уже в wy (строка уезжала за модуль)
    -- 17 окт: прицел наверху — его кнопки на нём (справа внизу), а не под слайсами
    local by2 = (ztop and zy_top) and (zy_top + ZH - rh - 1) or fy
    local KEYS = S.cross and { act_cut = 's', act_smk = 'S', act_sq = 'Q', cut0x = '0', cutsnap = 't', cutquant = 'q' } or nil   -- прицел активен — клавиши на кнопках
    local st = ctx.state or {}
    local mx2, my2 = gfx.mouse_x, gfx.mouse_y
    local down = (gfx.mouse_cap & 1) == 1
    local press = down and not S.cb_prev
    S.cb_prev = down
    -- 16 окт: и действия прицела — cut (как s), smk (stretch-маркер на строку), squant (smart quantize, как Q)
    local BT = { { 'act_cut', 'cut', act = true }, { 'act_smk', 'smk', act = true }, { 'act_sq', 'squant', act = true },
                 { 'cut0x', '0-cross' }, { 'cutsnap', 't-snap' }, { 'cutquant', 'quant' } }
    -- 16 окт: что делает каждая — в строку подсказки модуля и в статус окна (ctx.status_from_slicer)
    S.CUT_DESC = S.CUT_DESC or {
      act_cut = 'cut (s): cut the note under the cursor at the aimed point - the sound after it becomes the next note',
      act_smk = 'smk (S): a stretch marker at the aimed point, snapped to the row start - the hit lands on the grid',
      act_sq = 'squant (Q): smart quantize - the hits of the sample move to the nearest rows with stretch markers, the sound stays whole',
      cut0x = '0-cross (0 while aiming): cuts and markers move to the nearest zero crossing - no click at the edge',
      cutsnap = 't-snap (t while aiming): the aimed point snaps to the nearest transient of the sample',
      cutquant = 'quant (q while aiming, with t-snap): the snapped transient also goes to the nearest row of the grid (with swing)',
    }
    local bx = x + w
    S.cut_hot = nil
    for k = #BT, 1, -1 do
      local b = BT[k]
      local kk = KEYS and KEYS[b[1]]
      local pre = (kk and b.act) and (kk .. ' ') or ''   -- действия — клавиша перед словом, тоглы — первая буква и есть клавиша
      local poff = pre ~= '' and (U.measure(kk) + L.pad) or 0   -- пробел в конце measure не считает
      local bw2 = poff + U.measure(b[2]) + 2 * L.pad
      bx = bx - bw2 - (k < #BT and 2 or 0)
      local on = not b.act and st[b[1]] and (b[1] ~= 'cutquant' or st.cutsnap)
      local col = b[3] or U.AMBER
      local hot2 = mx2 >= bx and mx2 < bx + bw2 and my2 >= by2 and my2 < by2 + rh
      if hot2 then S.cut_hot = b[1]; foot = S.CUT_DESC[b[1]] or foot end
      U.set(on and U.tint(col, 0.3) or (hot2 and U.tint(U.AMBER, 0.2) or U.BG)); gfx.rect(bx, by2, bw2, rh - 1, 1)
      U.set(on and col or (hot2 and U.AMBER or U.LINE)); gfx.rect(bx, by2, bw2, rh - 1, 0)
      local tcol = on and col or ((b[1] == 'cutquant' and not st.cutsnap) and U.DIM or (hot2 and U.AMBER or U.TEXT))
      if pre ~= '' then U.text(bx + L.pad, by2, kk, U.AMBER); U.text(bx + L.pad + poff, by2, b[2], tcol)
      else
        U.text(bx + L.pad, by2, b[2], tcol)
        if kk and not on then U.text(bx + L.pad, by2, kk, U.AMBER) end   -- первая буква — клавиша
      end
      if hot2 and press and b.act then
        local need = b[1] ~= 'act_sq'
        if need and not S.cross then S.msg = b[2] .. ': aim at a note first (the cursor on a note of this sample)'
        elseif b[1] == 'act_cut' then local te = S.cut_point(S.cross.t + S.cross.dt); ctx.cut_at(S.cross, te, st.cutsnap and st.cutquant); S.cross = nil
        elseif b[1] == 'act_smk' and ctx.smk_at then ctx.smk_at(S.cross, S.cut_point(S.cross.t + S.cross.dt))
        elseif b[1] == 'act_sq' then S.smart_quantize() end
      elseif hot2 and press and ctx.state then
        st[b[1]] = not st[b[1]]
        S.msg = b[2] .. (st[b[1]] and ' on' or ' off') .. (b[1] == 'cutquant' and not st.cutsnap and ' (works with t-snap)' or '')
      end
    end
    local troom = math.max(0, (by2 ~= fy and (x + w) or bx) - x - L.pad)
    if bar_y then ovbar(bar_x, bar_y, bar_w, BH) end   -- 17 окт: полоса-обзор — наверху (см. bar_y)
    if foot ~= S.msg and U.hint_text then U.hint_text(x, fy, foot, troom, U.PANEL)   -- 15 окт: стандарт подсказок
    else U.text(x, fy, ctx.fit(foot, troom), U.GREY) end   -- 10 окт: подсказка — приглушённо
  end
  if hover_view then return { e = e, view = hover_view } end
  if hover_sbtn then return { e = e, sbtn = hover_sbtn } end
  if hover_vol then return { e = e, vol = true } end
  if hover_norm then return { e = e, norm = true } end
  if gfx.mouse_x >= x and gfx.mouse_x < x + w and gfx.mouse_y >= wy and gfx.mouse_y < wy + wh then
    return { e = e, frac = S.x_to_t(gfx.mouse_x) / len, slice = hover_slice, wave = true }
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
