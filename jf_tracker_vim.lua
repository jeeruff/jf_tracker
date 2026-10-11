-- jf_tracker_vim.lua — Vim-слой трекера: режимы, движения, операторы.
--
-- Философия: строка трекера = строка Vim, событие (item / нота) = слово,
-- подколонка = столбец. NORMAL — навигация и операторы, INSERT — ноты с
-- клавиатуры-пианино, VISUAL / V-LINE — блок, `:` — командная строка.
-- Счётчики перед командами, операторы с движениями (d3j, dw, yy, cG),
-- регистр по умолчанию, `.` повторяет последнюю правку, q{a-z}/@{a-z} —
-- макросы (записываются коды клавиш, проигрываются через тот же вход).
--
-- Модуль не трогает reaper.* напрямую: пишет через ctx.edit
-- (jf_tracker_edit.lua), читает снимок/раскладку через ctx. Поэтому машина
-- состояний гоняется стабами в tests/test_vim.lua.
--
-- Раскладка клавиш (нормальный режим):
--   h j k l   поле / строка (поля: нота, vol, delay, команды…)   H L  трек
--   w b e     событие вперёд / назад / граница после события
--   W B       событие в любой подколонке трека
--   gg G      начало / конец               { }        такт назад / вперёд
--   ^D ^U ^F ^B  полстраницы / страница     zz zt zb   прокрутка к курсору
--   0 $       первая / последняя колонка
--   x / dd    удалить событие / строку     d{motion}  удалить диапазон
--   y{motion} yy  скопировать              p          вставить у курсора
--   c{motion} cc  заменить (= d + insert)  s          разрезать по строке
--   m         mute                         ^A ^X      транспонировать ±1
--   r{нота}   задать высоту; на поле vol/delay — r{hex hex}, на команде r{буква hex hex}
--   1 (insert) note-off;  в INSERT на полях vol/delay/команд — hex-ввод
--   u ^R      undo / redo                  .          повторить правку
--   q{a-z} q  записать макрос              @{a-z} @@  проиграть
--   i         INSERT                       v V        VISUAL / V-LINE
--   a / A     огибающие показать-скрыть / fzf по всем параметрам автоматизации
--   za zc zo zM zR  свёртка колонок (точки на событиях, как в Renoise)
--   zf        свернуть/развернуть папку трека (дети прячутся)
--   [ ]       октава −/+                   ( )        слот пула −/+ (⌘+цифра = слот, ` = note-off)
--   :font N :pool :poolprev :side :browse   шрифт, полоска пула, превью пула, сайдбар
--   /текст n N *  поиск по имени / ноте / команде;  \  hydra действий (лидер);  ?  шпаргалка
--   : показывает список команд снизу, Tab дополняет
--   F         follow                       Space      play/stop
--   Enter     edit-курсор в строку         :          команда
--   Tab       фокус: матрица ↔ трекер      F1         справка (html)
--   ^H ^J ^K ^L  курсор матрицы из трекера (без смены фокуса)
--   ⌥H ⌥L / ⌥J ⌥K  трек назад/вперёд / событие трека вперёд/назад
--   ⌘J ⌘L / ⌘K ⌘H  инструмент трека следующий / предыдущий
--   :fx N :env :preview   колонки команд, огибающие, предпрослушивание

local V = {}
local ctx

local ESC, ENTER, TAB, BS, DEL = 27, 13, 9, 8, 6579564
local INS = 6909555          -- клавиша Insert (gfx 'ins')
local UP, DOWN, LEFT, RIGHT = 30064, 1685026670, 1818584692, 1919379572
local PGUP, PGDN, HOME, END = 1885828464, 1885824110, 1752132965, 6647396
local function ctrl(ch) return ch:byte() - 96 end

V.mode = 'normal'       -- канонический Vim (2 окт, решение пользователя); i → INSERT = Ableton-раскладка
V.cur = { fi = 1, row = 0, field = 1 }   -- field: 1 нота, 2 vol, 3 delay, 4.. команды
V.anchor = nil
V.hexbuf = nil           -- набираемое hex-значение (INSERT на полях / r)
V.count = nil
V.pending = nil          -- 'd' 'y' 'c' 'g' 'z' 'r' 'q' '@' '"'
V.regs = {}
V.macro = nil            -- { name=, keys={} } при записи
V.last_macro = nil
V.cmdbuf = {}            -- клавиши текущей команды (для `.`)
V.last_edit = nil
V.cmdline = nil          -- текст после `:`
V.octave = 4
V.step = 1
V.vel = 100            -- velocity вставляемых нот (c / C в KEYS, :vel N)
V.step_auto = false   -- авто-шаг: курсор за конец вставленного item / слайса (1 окт)
V.step_next = false   -- шаг next (3 окт): курсор на следующий объект трека — ноту, item, команду, точку огибающей

-- шаг после правки поля (hex, огибающие): next — до следующего объекта, иначе V.step
local function step_rows() if V.step_next then return V.next_rows and V.next_rows() or 1 end return V.step end
-- строк, на сколько двигать курсор после вставки инструмента e (слайс k)
local function adv_rows(e, k)
  if V.step_next then return V.next_rows and V.next_rows() or 1 end
  if not V.step_auto then return V.step end
  if not e or not e.len or not ctx.edit or not ctx.edit.row_time then return 1 end
  local lp = ctx.state.lpb or 4
  local rs = ctx.edit.row_time(V.cur.row + 1, lp, 0) - ctx.edit.row_time(V.cur.row, lp, 0)
  if rs <= 0 then return 1 end
  local secs = e.len
  if k and e.slices and e.slices[k] then secs = (e.slices[k + 1] or e.len) - e.slices[k] end
  return math.max(1, math.ceil(secs / rs - 1e-6))
end
V.inst = 1
V.msg = ''
V.replaying = 0
V.search = nil           -- текст поиска (/), n/N повторяют
V.hydra = nil            -- активная hydra { title, items = { {key,label,fn|sub} } }
V.hydra_stack = {}

function V.init(c) ctx = c end

-- ── доступ к раскладке ────────────────────────────────────────────────────
local function flat() return ctx.layout().flat end
local function nflat() return #flat() end
local function lpb() return ctx.state.lpb end
local function env_of(fi) local f = flat()[fi]; return f and f.env end

-- длина для макросов/`:ramp`: «4» — строки, «2b» — биты (по LPB), «» — 1 бит
local function parse_len(arg)
  arg = (arg or ''):match('^%s*(%S*)') or ''
  if arg == '' then return lpb() end
  local b = arg:match('^(%d+%.?%d*)[bB]$')
  if b then return math.max(1, math.floor(tonumber(b) * lpb() + 0.5)) end
  local n = tonumber(arg)
  return n and math.max(1, math.floor(n)) or nil
end
V.parse_len = parse_len

-- число полей подколонки: нота, vol, delay + колонки команд; свёрнутый трек — 1
local function nfields(fi)
  local f = flat()[fi or V.cur.fi]
  if not f or f.folded then return 1 end
  if f.ml then return 1 end                 -- MIDI-лейн (CC / PC / артикуляции / SysEx): одно поле
  if f.env then return f.compact and 1 or 2 end   -- огибающая: значение, форма сегмента (свёрнутый — только значение)
  if f.compact then return 1 end           -- свёрнутый трек: только нота
  if f.G and f.G.nfields then return f.G.nfields end   -- уровень ширины (7 окт): свои поля
  if f.narrow then return 2 end            -- узкая подколонка ноты аккорда: нота, velocity
  return 3 + (ctx.state.fxcols or 0)
end

-- формы сегмента огибающей (REAPER 0..5) и их сокращения; набор букв на поле
-- формы выбирает, как только префикс однозначен: b → bez, sq → sqr, fas …
V.SHAPES = { 'lin', 'sqr', 'slo', 'fas', 'fae', 'bez' }
function V.shape_match(buf)
  local hit, n = nil, 0
  for i, a in ipairs(V.SHAPES) do if a:sub(1, #buf) == buf then hit = i - 1; n = n + 1 end end
  if n == 1 then return hit end
  if n == 0 then return false end
  return nil                                 -- ещё неоднозначно
end

local function clamp_cur()
  local n = nflat()
  if n == 0 then V.cur.fi = 1 else
    if V.cur.fi < 1 then V.cur.fi = 1 elseif V.cur.fi > n then V.cur.fi = n end
  end
  if V.cur.row < 0 then V.cur.row = 0 end
  local nf = nfields()
  if not V.cur.field or V.cur.field < 1 then V.cur.field = 1 elseif V.cur.field > nf then V.cur.field = nf end
end

-- Визуальный порядок полей (просьба 1 окт): нота, vol, fx1..n, delay.
-- Номера полей логические (1 нота, 2 vol, 3 delay, 4+ fx) — меняется
-- только обход h/l и $; draw кладёт x_fx перед x_del тем же порядком.
local function vorder(fi)
  local nf = nfields(fi)
  local o = { 1 }
  if nf >= 2 then o[#o + 1] = 2 end
  for k = 4, nf do o[#o + 1] = k end
  if nf >= 3 then o[#o + 1] = 3 end
  return o
end
local function vpos(fi, fld)
  for i, f in ipairs(vorder(fi)) do if f == fld then return i end end
  return 1
end
function V.last_field(fi) local o = vorder(fi); return o[#o] end
V.vorder = vorder                    -- 10 окт: линейка прыжков по ячейкам (порядок полей, как ходит l)

-- шаг по полям: через границу подколонки
local function step_field(dir, n)
  local fi, fld = V.cur.fi, V.cur.field or 1
  local pos = vpos(fi, fld)
  for _ = 1, n do
    pos = pos + dir
    if pos < 1 then
      if fi > 1 then fi = fi - 1; pos = #vorder(fi) else pos = 1 end
    elseif pos > #vorder(fi) then
      if fi < nflat() then fi = fi + 1; pos = 1 else pos = #vorder(fi) end
    end
  end
  return fi, vorder(fi)[pos]
end

-- держать курсор в окне: строки — прокрутка, колонки — hscroll
local function ensure_visible()
  local L = ctx.layout()
  local st = ctx.state
  if V.cur.row < st.row0 then st.row0 = V.cur.row end
  if V.cur.row >= st.row0 + L.nrows then st.row0 = V.cur.row - L.nrows + 1 end
  local f = L.flat[V.cur.fi]
  if f then
    if f.ci < st.hscroll then st.hscroll = f.ci
    elseif f.x and f.x + f.w > L.win_w then
      st.hscroll = math.min(f.ci, st.hscroll + 1)
      ctx.relayout()
      local f2 = ctx.layout().flat[V.cur.fi]
      while f2 and f2.x and f2.x + f2.w > L.win_w and st.hscroll < f2.ci do
        st.hscroll = st.hscroll + 1; ctx.relayout(); f2 = ctx.layout().flat[V.cur.fi]
      end
    end
  end
end

-- ── ячейки ────────────────────────────────────────────────────────────────
-- подколонки flat-элемента: обычный — одна, свёрнутый трек — все его subs
local function subs_of(f)
  if f.folded then
    local out = {}
    for _, lane in ipairs(f.col.lanes) do for _, s in ipairs(lane.subs) do out[#out + 1] = s end end
    return out
  end
  return { f.sub }
end

local function is_head(c) return c and (c.kind == 'audio' or c.kind == 'midi') end
local function head_of(c)
  if not c then return nil end
  if is_head(c) then return c end
  return c.of
end

-- головы событий в прямоугольнике [f0..f1] × [r0..r1] (по строке головы)
function V.heads_in(f0, f1, r0, r1)
  local F = flat()
  if f0 > f1 then f0, f1 = f1, f0 end
  if r0 > r1 then r0, r1 = r1, r0 end
  local out, seen = {}, {}
  for fi = f0, f1 do
    local f = F[fi]
    if f then
      for _, sub in ipairs(subs_of(f)) do
        for r = r0, r1 do
          local c = sub[r]
          if is_head(c) and not seen[c] then seen[c] = true; c.fi = fi; out[#out + 1] = c end
        end
      end
    end
  end
  return out
end

-- события, накрывающие строку (голова, cont или off на этой строке)
function V.covering(fi, row)
  local f = flat()[fi]
  if not f then return {} end
  local out, seen = {}, {}
  for _, sub in ipairs(subs_of(f)) do
    local h = head_of(sub[row])
    if h and not seen[h] then seen[h] = true; h.fi = fi; out[#out + 1] = h end
  end
  return out
end

-- swap (4 окт): событие под курсором ↔ k-е событие ниже в той же колонке
function V.swap_forward(k)
  local fi, row = V.cur.fi, V.cur.row
  local a = V.covering(fi, row)[1]
  if not a then V.msg = 'gw: no event under the cursor'; return false end
  local hs = V.heads_in(fi, fi, a.row0 + 1, a.row0 + 100000)
  table.sort(hs, function(x, y) return x.row0 < y.row0 end)
  local b = hs[k]
  if not b then V.msg = ('gw: no event %d ahead (%d below)'):format(k, #hs); return false end
  if not ctx.edit.swap_events(a, b) then V.msg = 'gw: audio events only'; return false end
  V.cur.row = b.row0
  V.msg = ('swapped with the event %d ahead (row %d)'):format(k, b.row0)
  return true
end

-- ── движения ──────────────────────────────────────────────────────────────
-- строка с точкой огибающей после / до row (dir = 1 / -1) — точки как события
local function env_next(f, row, dir)
  local rows = (ctx.env_point_rows and ctx.env_point_rows(f.env)) or {}
  if dir > 0 then for _, r in ipairs(rows) do if r > row then return r end end
  else for i = #rows, 1, -1 do if rows[i] < row then return rows[i] end end end
  return nil
end
local function env_has(f, r)
  for _, x in ipairs((ctx.env_point_rows and ctx.env_point_rows(f.env)) or {}) do if x == r then return true end end
  return false
end

local function next_head(fi, row, dir, any_sub)
  local F = flat()
  local f = F[fi]
  if not f then return nil end
  if f.env then return env_next(f, row, dir) end
  local subs = subs_of(f)
  if any_sub then
    subs = {}
    for _, lane in ipairs(f.col.lanes) do for _, s in ipairs(lane.subs) do subs[#subs + 1] = s end end
  end
  local last = ctx.snap().last_row or 0
  local r = row + dir
  while r >= 0 and r <= last + 1 do
    for _, sub in ipairs(subs) do if is_head(sub[r]) then return r end end
    r = r + dir
  end
  return nil
end

-- шаг next (3 окт): строк до следующего объекта трека курсора (любая его
-- подколонка; в колонке огибающей — следующая точка); нет дальше — 1
function V.next_rows()
  local r = next_head(V.cur.fi, V.cur.row, 1, true)
  return r and math.max(1, r - V.cur.row) or 1
end

-- W / B — следующее / предыдущее событие в ЛЮБОЙ колонке (все треки, подколонки
-- и лейны; огибающие — нет): ближайшая строка, при равенстве — от колонки
-- курсора вправо по кругу; курсор переходит в эту колонку (просьба 2 окт)
local function next_any(fi, row, dir)
  local F = flat()
  local nf = #F
  if nf == 0 then return nil end
  local last = ctx.snap().last_row or 0
  local r = row + dir
  while r >= 0 and r <= last + 1 do
    for k = 0, nf - 1 do
      local i = (fi - 1 + k) % nf + 1
      local f = F[i]
      if f and f.env then
        if env_has(f, r) then return i, r end
      elseif f then
        for _, sub in ipairs(subs_of(f)) do if is_head(sub[r]) then return i, r end end
      end
    end
    r = r + dir
  end
  return nil
end

-- w / b (6 окт): события ТРЕКА курсора — все его подколонки и лейны
-- огибающих (точки — тоже события), как слова текста в Vim: строка трека —
-- строка текста, колонки — слева направо; курсор переходит в колонку события
-- 9 окт: событие для w / b — голова item, note-off, строка с точкой огибающей
-- громкости take (cell.vol); strict (W / B) — только головы аудио / MIDI item
local function is_event(c, strict)
  if strict then return is_head(c) end
  return is_head(c) or (c and c.kind == 'off') or false   -- 9 окт: точки громкости take — не события (x-fade «00» сбивал y3w)
end
local function track_event(f, r, strict)
  if f.env then return (not strict) and env_has(f, r) end
  if f.ml or f.folded then return false end
  for _, sub in ipairs(subs_of(f)) do if is_event(sub[r], strict) then return true end end
  return false
end
-- событие в одной подколонке (операторы dw / d2w — прямоугольник своей подколонки)
local function next_ev(fi, row, dir)
  local f = flat()[fi]
  if not f then return nil end
  if f.env then return env_next(f, row, dir) end
  local last = ctx.snap().last_row or 0
  local r = row + dir
  while r >= 0 and r <= last + 1 do
    for _, sub in ipairs(subs_of(f)) do if is_event(sub[r]) then return r end end
    r = r + dir
  end
  return nil
end
local function next_track(fi, row, dir, strict)
  local F = flat()
  local f0 = F[fi]
  if not f0 then return nil end
  local cols = {}
  for i, g in ipairs(F) do if g.ci == f0.ci then cols[#cols + 1] = i end end
  local last = ctx.snap().last_row or 0
  local r, first = row, true
  while r >= 0 and r <= last + 1 do
    if dir > 0 then
      for _, i in ipairs(cols) do if (not first or i > fi) and track_event(F[i], r, strict) then return i, r end end
    else
      for k = #cols, 1, -1 do local i = cols[k]; if (not first or i < fi) and track_event(F[i], r, strict) then return i, r end end
    end
    first = false; r = r + dir
  end
  return nil
end

-- `e` — на ГРАНИЦУ после события: верхняя кромка строки курсора совпадает с
-- концом item/ноты (а не последняя строка события)
local function event_end(fi, row)
  local f = flat()[fi]
  if not f then return row end
  if f.env then return env_next(f, row, 1) or row end    -- огибающая: конец «события» — следующая точка
  for _, sub in ipairs(subs_of(f)) do
    local h = head_of(sub[row])
    if h then return h.row0 + (h.rows or 1) end
  end
  return row
end

-- Возвращает цель {fi=, row=, exclusive=, linewise=} или nil.
local motion
function motion(c, n, op)
  local cur = V.cur
  local last = ctx.snap().last_row or 0
  local L = ctx.layout()
  if c == ('j'):byte() or c == DOWN then return { fi = cur.fi, row = cur.row + n, linewise = true }
  elseif c == ('k'):byte() or c == UP then return { fi = cur.fi, row = math.max(0, cur.row - n), linewise = true }
  -- поле инструмента (5 окт): подполе ноты между нотой и громкостью
  -- 11 окт: подполе слайса (Sxx) — за инструментом: нота → инструмент → слайс → громкость
  elseif (c == ('l'):byte() or c == RIGHT) and n == 1 and V.inst_field_ok() and (cur.field or 1) == 1 and cur.sub ~= 'inst' and cur.sub ~= 'slc' then
    return { fi = cur.fi, row = cur.row, field = 1, sub = 'inst' }
  elseif (c == ('l'):byte() or c == RIGHT) and n == 1 and cur.sub == 'inst' and V.slc_field_ok() then
    return { fi = cur.fi, row = cur.row, field = 1, sub = 'slc' }
  elseif (c == ('l'):byte() or c == RIGHT) and n == 1 and cur.sub == 'slc' then
    return { fi = cur.fi, row = cur.row, field = 2 }
  elseif (c == ('h'):byte() or c == LEFT) and n == 1 and V.slc_field_ok() and ((cur.field or 1) == 2 and cur.sub ~= 'slc') then
    return { fi = cur.fi, row = cur.row, field = 1, sub = 'slc' }
  elseif (c == ('h'):byte() or c == LEFT) and n == 1 and cur.sub == 'slc' then
    return { fi = cur.fi, row = cur.row, field = 1, sub = 'inst' }
  elseif (c == ('h'):byte() or c == LEFT) and n == 1 and V.inst_field_ok() and ((cur.field or 1) == 2 and cur.sub ~= 'inst') then
    return { fi = cur.fi, row = cur.row, field = 1, sub = 'inst' }
  elseif (c == ('h'):byte() or c == LEFT) and n == 1 and cur.sub == 'inst' then
    return { fi = cur.fi, row = cur.row, field = 1 }
  elseif (c == ('h'):byte() or c == LEFT or c == ('l'):byte() or c == RIGHT) and n > 1 then
    -- 10 окт: Nl / Nh = N одиночных шагов — каждая ячейка, куда встаёт l (и подполе
    -- инструмента), — шаг, как на линейке прыжков
    local save = V.cur
    local t = { fi = cur.fi, row = cur.row, field = cur.field, sub = cur.sub }
    for _ = 1, n do
      V.cur = { fi = t.fi, row = t.row, field = t.field or 1, sub = t.sub }
      local s1 = motion(c, 1, op)
      if not s1 then break end
      t = { fi = s1.fi or t.fi, row = s1.row or t.row, field = s1.field or 1, sub = s1.sub }
    end
    V.cur = save
    return t
  elseif c == ('h'):byte() or c == LEFT then local fi, fld = step_field(-1, n); return { fi = fi, row = cur.row, field = fld }
  elseif c == ('l'):byte() or c == RIGHT then local fi, fld = step_field(1, n); return { fi = fi, row = cur.row, field = fld }
  elseif c == ('H'):byte() or c == ('L'):byte() then
    local F = flat(); local f = F[cur.fi]; if not f then return nil end
    local ci = f.ci + (c == ('H'):byte() and -n or n)
    for i, g in ipairs(F) do if g.ci == ci then return { fi = i, row = cur.row } end end
    return { fi = c == ('H'):byte() and 1 or nflat(), row = cur.row }
  elseif (c == ('w'):byte() or c == ('b'):byte()) and op then
    -- оператор (dw yw cw …) — своя подколонка: прямоугольник через колонки
    -- трека удалял бы лишнее
    -- 9 окт: dNw — N событий вперёд (с пустой строки — N следующих, не пустоту
    -- до первого); событий не хватает — до конца трека / начала
    local r = cur.row
    local dir = c == ('w'):byte() and 1 or -1
    local f = flat()[cur.fi]
    if f and f.env then
      for _ = 1, n do r = next_head(cur.fi, r, dir, false) or r end   -- огибающая — как было (точки)
    else
      local steps = n
      if dir > 0 then
        local on = false
        if f then for _, sub in ipairs(subs_of(f)) do if is_event(sub[cur.row]) then on = true end end end
        if not on then steps = n + 1 end
      end
      local last = ctx.snap().last_row or 0
      for _ = 1, steps do
        local nr = next_ev(cur.fi, r, dir)
        if not nr then r = dir > 0 and (last + 1) or 0; break end
        r = nr
      end
    end
    return { fi = cur.fi, row = r, exclusive = dir > 0 or nil, linewise = true }
  elseif c == ('w'):byte() or c == ('b'):byte() then
    -- движение w / b — по всем колонкам трека, точки огибающих тоже (6 окт)
    local fi, r = cur.fi, cur.row
    local dir = c == ('w'):byte() and 1 or -1
    for _ = 1, n do
      local nfi, nr = next_track(fi, r, dir)
      if not nfi then break end
      fi, r = nfi, nr
    end
    return { fi = fi, row = r, field = 1, linewise = true }
  elseif c == ('W'):byte() or c == ('B'):byte() then
    -- 9 окт: W / B — только головы аудио / MIDI item своего трека (w / b — любое событие)
    local fi, r = cur.fi, cur.row
    local dir = c == ('W'):byte() and 1 or -1
    for _ = 1, n do
      local nfi, nr = next_track(fi, r, dir, true)
      if not nfi then break end
      fi, r = nfi, nr
    end
    return { fi = fi, row = r, field = 1, exclusive = dir > 0 or nil, linewise = true }
  elseif c == ('e'):byte() then
    return { fi = cur.fi, row = event_end(cur.fi, cur.row), linewise = true }
  elseif c == ('G'):byte() then return { fi = cur.fi, row = V.count and (n - 1) or last, linewise = true }
  elseif c == ('{'):byte() or c == ('}'):byte() then
    local r = cur.row
    for _ = 1, n do
      local b0, b1 = ctx.bar_of_row(r)
      if c == ('}'):byte() then r = b1 else r = (r > b0) and b0 or select(1, ctx.bar_of_row(math.max(0, b0 - 1))) end
    end
    return { fi = cur.fi, row = math.max(0, r), linewise = true }
  elseif c == ctrl('d') then return { fi = cur.fi, row = cur.row + math.floor(L.nrows / 2), linewise = true }
  elseif c == ctrl('u') then return { fi = cur.fi, row = math.max(0, cur.row - math.floor(L.nrows / 2)), linewise = true }
  elseif c == ctrl('f') or c == PGDN then return { fi = cur.fi, row = cur.row + L.nrows, linewise = true }
  elseif c == ctrl('b') or c == PGUP then return { fi = cur.fi, row = math.max(0, cur.row - L.nrows), linewise = true }
  elseif c == HOME then return { fi = cur.fi, row = 0, linewise = true }
  elseif c == END then return { fi = cur.fi, row = last, linewise = true }
  elseif c == ('$'):byte() then return { fi = nflat(), row = cur.row, field = V.last_field(nflat()) }
  elseif c == ('0'):byte() and not V.count then return { fi = 1, row = cur.row, field = 1 }
  end
  return nil
end

-- ── операторы ─────────────────────────────────────────────────────────────
local function range_from(target, linewise_force)
  local cur = V.cur
  local r0, r1 = cur.row, target.row
  if target.exclusive then
    if r1 > r0 then r1 = r1 - 1 elseif r1 < r0 then r0 = r0 - 1 end
  end
  local f0, f1 = cur.fi, target.fi
  if target.linewise or linewise_force then f1 = f0 end
  return math.min(f0, f1), math.max(f0, f1), math.min(r0, r1), math.max(r0, r1)
end

-- курсор в пустоте перед событием: dw / de / cw / yw «понимают», что впереди
-- item — диапазон без событий → берём событие, на которое встала цель
-- движения (решение пользователя 1 окт)
local function range_or_event(op, t)
  local f0, f1, r0, r1 = range_from(t)
  -- огибающая: в диапазоне нет точек (курсор на пустой строке) — оператор
  -- берёт точку цели движения: dw — следующую, db — предыдущую (2 окт)
  local ft = flat()[t.fi]
  if (op == 'd' or op == 'c' or op == 'y') and ft and ft.env and f0 == f1 then
    local any = false
    for r = r0, r1 do if env_has(ft, r) then any = true; break end end
    if not any and env_has(ft, t.row) then return t.fi, t.fi, t.row, t.row end
    return f0, f1, r0, r1
  end
  if (op == 'd' or op == 'c' or op == 'y') and #V.heads_in(f0, f1, r0, r1) == 0 then
    if #V.heads_in(t.fi, t.fi, t.row, t.row) > 0 then return t.fi, t.fi, t.row, t.row end
  end
  return f0, f1, r0, r1
end

local function paste_targets(fi)
  return function(dfi)
    local f = flat()[fi + dfi]
    if not f then return nil end
    local lane = f.lane or f.col.lanes[1]
    return { track = f.col.track, lane_idx = f.col.fixed and lane.idx or nil }
  end
end

-- применить оператор к прямоугольнику
local function apply(op, f0, f1, r0, r1)
  local E = ctx.edit
  -- колонка огибающей: операторы над точками строк (2 окт)
  local fenv = f0 == f1 and env_of(f0)
  if fenv and (op == 'd' or op == 'x' or op == 'c' or op == 'y') then
    V.regs['"'] = { kind = 'env', pts = ctx.env_points(fenv, r0, r1), rows = r1 - r0 + 1 }
    if op == 'y' then V.msg = ('yank %d point(s)'):format(#V.regs['"'].pts); return false end
    ctx.env_del_range(fenv, r0, r1)
    if op == 'c' then V.mode = 'insert' end
    return true
  end
  -- 9 окт: x / dl / dd на поле громкости строки-продолжения — точка огибающей
  -- громкости take («00» после x-fade), не весь item
  if (op == 'd' or op == 'x') and f0 == f1 and (V.cur.field or 1) == 2 and ctx.take_vol_del then
    local fl = flat()[f0]
    local n = 0
    for r = r0, r1 do
      for _, sub in ipairs(fl and subs_of(fl) or {}) do
        local c = sub[r]
        if c and c.kind == 'cont' and c.vol ~= nil and c.of and c.of.item then n = n + (ctx.take_vol_del(c.of.item, r) and 1 or 0) end
      end
    end
    if n > 0 then V.msg = ('take volume point(s) deleted: %d'):format(n); return true end
  end
  local heads = V.heads_in(f0, f1, r0, r1)
  local edited = true
  if op == 'd' or op == 'x' or op == 'c' then
    V.regs['"'] = E.yank(heads, lpb(), r0, f0)
    E.delete(heads, lpb())
    -- 11 окт: OFF в диапазоне — убрать: нота звучит до следующего события подколонки (нет — до конца региона), как в Renoise
    for fi = f0, f1 do
      local fl = flat()[fi]
      for _, sub in ipairs(fl and subs_of(fl) or {}) do
        for r = r0, r1 do
          local c = sub[r]
          if c and c.kind == 'off' and c.of then
            local nxt
            for r2 = r + 1, r + 4096 do local c2 = sub[r2]; if c2 and (c2.kind == 'audio' or c2.kind == 'midi') then nxt = r2; break end end
            local last = nxt and (nxt - 1) or (ctx.region_end_row and ctx.region_end_row(r)) or (r + 16)
            E.note_off({ c.of }, lpb(), last + (E.OFF_END and 0 or 1))
          end
        end
      end
    end
    if op == 'c' then V.mode = 'insert' end
  elseif op == 'y' then
    V.regs['"'] = E.yank(heads, lpb(), r0, f0); edited = false
    V.msg = ('yank %d'):format(#heads)
  elseif op == 'm' then E.mute(heads, lpb())
  elseif op == 's' then
    -- разрез по строке курсора всего, что её накрывает
    local cov = {}
    for fi = f0, f1 do for _, h in ipairs(V.covering(fi, V.cur.row)) do cov[#cov + 1] = h end end
    E.split(cov, lpb(), V.cur.row)
  elseif op == '+' or op == '-' then
    local d = (V.count or 1) * (op == '+' and 1 or -1)
    local fld = V.cur.field or 1
    if fld == 1 and V.cur.sub == 'slc' then
      -- 11 окт: слайс ±d
      for _, h in ipairs(heads) do if ctx.set_slice then ctx.set_slice({ h }, math.max(0, (h.slice or 0) + d)) end end
    elseif fld == 1 and V.cur.sub == 'inst' then
      -- инструмент ±d (5 окт)
      for _, h in ipairs(heads) do
        local n0 = ctx.inst_num_of and ctx.inst_num_of(h) or nil
        if n0 and ctx.set_inst then ctx.set_inst({ h }, math.max(1, n0 + d)) end
      end
    elseif fld == 1 then E.transpose(heads, lpb(), d)
    elseif fld == 2 then for _, h in ipairs(heads) do E.set_vol({ h }, lpb(), tonumber(h.vol, 16) + d) end
    elseif fld == 3 then for _, h in ipairs(heads) do E.set_delay({ h }, lpb(), h.delay + d) end
    else
      -- k-я команда головы: xx ± d (если команды нет — ничего)
      for _, h in ipairs(heads) do
        local f = (h.fx or {})[fld - 3]
        if f then E.set_fx({ h }, lpb(), f:sub(1, 1), tonumber(f:sub(2), 16) + d) end
      end
    end
  end
  return edited
end

-- hex-ввод: поле 2/3 — две цифры, поле команды — буква + две цифры.
-- Возвращает true, когда значение принято (буфер сброшен).
local FX_LETTERS = { ['9'] = true, ['8'] = true, C = true, I = true, O = true, L = true, M = true, S = true, T = true,
                     U = true, D = true, G = true, ['4'] = true, ['0'] = true, A = true, R = true, P = true, F = true, B = true }
local function hex_entry(c, fld, heads)
  local ch = (c < 256) and string.char(c):upper() or ''
  local buf = V.hexbuf or ''
  local is_hex = ch:match('^[0-9A-F]$') ~= nil
  if fld >= 4 and buf == '' then
    -- 6 окт, как в трекерах: команды просто стоят в колонках fx1, fx2 … по
    -- порядку. Занятая колонка: цифры меняют ЗНАЧЕНИЕ её команды; другая
    -- команда — только после удаления (BS). Пустая — буква + две цифры
    local f = heads[1] and (heads[1].fx or {})[fld - 3]
    if f then
      if is_hex then V.hexbuf = f:sub(1, 1) .. ch; return false end
      if ch:match('^%a$') then V.msg = ('%s: digits change its value; BS deletes it, then type another effect'):format(f) end
      return false
    end
    if not FX_LETTERS[ch] then return false end
    V.hexbuf = ch; return false
  end
  if not is_hex then return false end
  buf = buf .. ch
  local need = fld >= 4 and 3 or 2
  if #buf < need then V.hexbuf = buf; return false end
  V.hexbuf = nil
  -- vol на строке продолжения аудио (5 окт): точка огибающей громкости take
  if fld == 2 and #heads == 0 then
    local h = V.covering(V.cur.fi, V.cur.row)[1]
    if h and h.kind == 'audio' and h.item then ctx.edit.cont_vol(h.item, ctx.row_time(V.cur.row), tonumber(buf, 16), ctx.row_time(V.cur.row + 1)); return true end
  end
  if #heads == 0 then V.msg = 'no note in this row - type the note first (vol / delay / effects belong to a note)'; return 'none' end
  if fld == 2 then ctx.edit.set_vol(heads, lpb(), tonumber(buf, 16))
  elseif fld == 3 then ctx.edit.set_delay(heads, lpb(), tonumber(buf, 16))
  else ctx.edit.set_fx(heads, lpb(), buf:sub(1, 1), tonumber(buf:sub(2), 16)) end
  return true
end

-- ── регистрация клавиш для `.` и макросов ─────────────────────────────────
local function record(c)
  if V.macro and V.replaying == 0 then V.macro.keys[#V.macro.keys + 1] = c end
  V.cmdbuf[#V.cmdbuf + 1] = c
end

local function finish_edit()
  if V.replaying == 0 and #V.cmdbuf > 0 then V.last_edit = { table.unpack(V.cmdbuf) } end
  V.cmdbuf = {}
end
local function finish_move() V.cmdbuf = {} end

-- значение цифрами (6 окт), опция values: midi — 0..127 десятичными (ввод
-- кончается сам, когда следующая цифра уже не влезет; 005 = 5; Enter — сразу),
-- hex — две hex-цифры. → 'wait' | v01, raw (целое: 0..127 / 0..255) | nil
local function num_key(c)
  local ch = (c < 256) and string.char(c):upper() or ''
  if (ctx.envfmt and ctx.envfmt() or 'midi') == 'hex' then
    if not ch:match('^[0-9A-F]$') then return nil end
    local buf = (V.hexbuf or '') .. ch
    if #buf < 2 then V.hexbuf = buf; return 'wait' end
    V.hexbuf = nil
    return tonumber(buf, 16) / 255, tonumber(buf, 16)
  end
  local buf = V.hexbuf
  if c == 13 and buf then
    V.hexbuf = nil
    local n = math.min(127, tonumber(buf) or 0); return n / 127, n
  end
  if not ch:match('^[0-9]$') then return nil end
  buf = (buf or '') .. ch
  local n = tonumber(buf)
  if #buf < 3 and n * 10 <= 127 then V.hexbuf = buf; return 'wait' end
  V.hexbuf = nil
  n = math.min(127, n); return n / 127, n
end

local function replay(keys)
  if V.replaying > 8 then return end
  V.replaying = V.replaying + 1
  for _, k in ipairs(keys) do V.key(k) end
  V.replaying = V.replaying - 1
end
-- 9 окт: вкладка macros — проиграть клавиши (регистр / свой макрос) у курсора
-- note-off строки курсора: 'sub' — подколонка, 'track' — все колонки трека,
-- 'all' — все треки (9 окт)
function V.note_off_scope(scope)
  local F = flat()
  local cur = F[V.cur.fi]
  local heads = {}
  for i, f in ipairs(F) do
    if not f.env and ((scope == 'all') or (scope == 'track' and cur and f.ci == cur.ci) or (scope == 'sub' and i == V.cur.fi)) then
      for _, h in ipairs(V.covering(i, V.cur.row)) do heads[#heads + 1] = h end
    end
  end
  ctx.edit.note_off(heads, lpb(), V.cur.row)          -- пусто — note_off ничего не делает
  V.msg = ('note off (%s): %d'):format(scope == 'all' and 'all tracks' or (scope == 'track' and 'track' or 'subcolumn'), #heads)
  return #heads
end
function V.play_keys(keys, n)
  V.cmdbuf = {}
  for _ = 1, n or 1 do replay(keys) end
end

-- ── пианино ───────────────────────────────────────────────────────────────
-- имя ноты → MIDI (4 окт, :note): C-4 / C#4 / c4 / Db3 → 60 / 61 / 60 / 49
function V.parse_note(nm)
  local l, acc, oct = (nm or ''):upper():match('^([A-G])([#B%-]?)(%-?%d)$')
  if not l then return nil end
  local SEMI = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11 }
  local p = SEMI[l] + (acc == '#' and 1 or (acc == 'B' and -1 or 0))
  return (tonumber(oct) + 1) * 12 + p
end
-- нота слайса 1 (4 окт): C-4 = слайс 1, дальше хроматически
-- 5 окт (как в Renoise): q = C-4 — весь сэмпл, слайсы начинаются со следующей
-- клавиши: slice_base — нота слайса 1 = C-4 + 1
function V.slice_base() return ((ctx.model and ctx.model.BASE_NOTE) or 60) + 1 end
local function piano_pitch(c)
  local off = ctx.piano[c]
  if off == nil then return nil end
  return (V.octave + 1) * 12 + off
end

-- ── командная строка ──────────────────────────────────────────────────────
-- Таблица команд: исполнение, подсказка (список снизу при наборе) и Tab.
V.COMMANDS = {
  { 'q', '', 'close window' }, { 'w', '', 'save project' }, { 'wq', '', 'save and close' },
  { 'lpb', 'N', 'rows per beat (1..64)' }, { 'step', 'N|auto|next', 'step after input: rows / to the end of the item / to the next object' },
  { 'oct', 'N', 'input octave' }, { 'inst', 'N', 'instrument slot' },
  { 'fx', 'N', 'fx command columns (0..4)' }, { 'env', '', 'envelope columns' },
  { 'scale', 'N', 'bitmap scale x1..3 (Cmd +/- too); x4 is kept for PT-mode' }, { 'options', '', 'all options in one window' }, { 'off', '[all]', 'note off at the cursor row on the whole track (all - on every track); in INSERT ` subcolumn, ~ track, Ctrl+` all' }, { 'repeat', '[all]', 'repeat the part of the region above the cursor down to the region end (Ctrl+Opt+J; all - every track)' }, { 'mac', 'name', 'play a macro by name (saved, built-in or @a) at the cursor; \\ q - all of them in a menu' }, { 'macsave', 'a name', 'keep register a as a named macro (macros tab, Data/jf_tracker_macros.txt)' }, { 'tcolor', '#rrggbb', 'colour of the cursor track by its code (tc - the colour grid)' }, { 'transients', '', 'transient detector module in the item tab (= Opt+D): sensitivity, threshold, min gap, pre-attack, live; Enter slices' }, { 'arr', '[new [name]|name text|dup|clear|del|next|prev|N]', 'arrangements: named sets of the fixed lanes that play (\\ P a)' }, { 'about', '[logo]', 'version, changes and the logo (a name part picks it: marquee, rubble, plum …)' }, { 'theme', 'name', 'reaper (native) | modus-vivendi | modus-operandi | gruvbox | catppuccin | mono' }, { 'name', 'text', 'matrix: rename the cursor region' }, { 'len', 'N|Ns|Nb', 'matrix: cursor region length - N steps (LPB), Ns seconds, Nb bars; later regions and items ripple' }, { 'add', '[bars] [name]', 'matrix: new region after the last one, from the next bar (+)' }, { 'space', 'N', 'gap above letters, px' }, { 'tab', 'item|modulate|midi|grid|retro|orca|master', 'top panel tab' }, { 'optsave', 'name', 'save all options as a profile' }, { 'optload', 'name', 'load an options profile' }, { 'optdel', 'name', 'delete an options profile' }, { 'redo', '', 'redo (also Cmd+Shift+Z; Ctrl+R is the rec tab)' }, { 'undo', '', 'undo (also u, Cmd+Z)' }, { 'sig', 'N/D [all|here]', 'time signature for the whole project or this pattern; a longer bar - fill the missing beats empty / with the last beat / keep' }, { 'scopemode', '[scope|spec|sgram]', 'analyzer: scope / spectrum / spectrogram' }, { 'retro', '[add]', 'retro sampler tab; add = jf_rec on cursor track' }, { 'top', '', 'top panel' }, { 'meters', '', 'peak meters over columns (PT style)' }, { 'wave', '[column|note|off]', 'wave: own column (spectral peaks + stretch markers) / in the note field / off' }, { 'xfade', '[on|off|now|ms]', 'x-fade of inserted notes: on/off, crossfade now, length ms' }, { 'mxzoom', '', 'matrix: schema <-> detail' }, { 'scopes', '', 'scopes: JSFX bridge on tracks on/off' }, { 'dsp', '[big]', 'bottom DSP panel (track fx); big - the chain with its routing on the whole window (zz in DSP)' }, { 'punch', '', 'punch: time selection = cursor region, auto-punch' }, { 'recmode', '', 'record mode (hydra)' }, { 'lanes', '', 'cursor track: fixed lanes on/off' },
  { 'z', '<words>', 'zoxide: jump the browser to the most used / recent folder matching the words (last word - in the folder name)' }, { 'zi', '', 'zoxide: pick from the visited folders (fzf), best first' }, { 'pane', '<panel> left|right|top|bottom|with <p>|swap <p>|hide|show|zoom, reset, <layout>', 'panes (tmux / zellij): move, stack, hide, layouts; no argument - layout string' }, { 'rec', '', 'record arm cursor track' }, { 'input', '', 'choose record input (hydra)' }, { 'smartin', '', 'most active input (jf_smart_set_input)' }, { 'slice', '', 'slice instrument (virtual)' },
  { 'poolprev', '', 'preview instrument on select' }, { 'side', '', 'sidebar browser' }, { 'legato', 'off|auto', 'notes of the track join the next note (stretched, pitch kept, follows the tempo); off - back; auto - keep it while inserting' }, { 'pmtag', 'words', 'jf_pm tags of the project picked with T in the pm tab' }, { 'interp', 'vol|delay|note|X', 'VISUAL: values from the first to the last event, linear by rows (Paketti)' }, { 'note', 'C-4 [rows]', 'a note of the instrument at the cursor' }, { 'sl', 'N [rows] [+semis]', 'slice N at the cursor' }, { 'whole', '[rows]', 'the whole sample (mother item)' }, { 'fxa', '', 'store all parameters of the selected DSP fx as A' }, { 'fxb', '', 'store them as B' }, { 'morph', 'N', 'morph the selected fx from A (0) to B (100)' }, { 'scramble', '', 'slice notes swap their slices randomly (VISUAL, else the cursor track in the region)' }, { 'sw', 'N', 'swap the event under the cursor with the Nth below (= Ngw)' }, { 'tutorial', '', 'first steps in ten points' }, { 'swing', 'N | on | off | 1/16', 'REAPER grid swing: amount -100..100 % (33 = triplet), division; no argument - the menu' }, { 'pm', '[big | grid | list | sort date|name|bpm|status | daw all|rpp|other]', 'jf_pm project cards in the browser (pm tab); big - over the whole window' }, { 'font', 'name | next | prev | off | <family> [px]', 'tracker font: off - the REAPER bitmap, any installed family by name (custom), or a terminal monospace font (bigblue, bb437, departure, gohu11, gohu14, terminess, proggy, profont, 3270, monocraft, iosevka, jetbrains, hack, plex ...); next / prev - step through them' }, { 'audio', 'dev <name> | bs N | sr N | sr off | bs off', 'audio device of REAPER (CoreAudio): device by name, buffer size, sample rate - applied at once (the audio restarts); options tab audio, zB - buffer menu' }, { 'jftop', '', 'what in the tracker takes the time: each part of the frame in ms (top module, rows, matrix, browser, keys ...); r - reset, t - performance view, Esc - close' }, { 'logo', '[name]', 'one of the jf_tracker artworks in the middle of the tracker; any key or click closes it' }, { 'session', '[big | stop | quant bar|beat|now | bars N | off]', 'clips over the whole window (zz in the matrix): launch clips and scenes on the quantize boundary into the =SESSION loop zone; stop - all clips; off - transport stop, zone cleared' }, { 'dev', '[on|off]', 'developer copy only: off shows the tracker as release users get it (no grid, orca, pm cards); takes effect after reopening the tracker' }, { 'ssave', 'name', 'save the view (options + module layout) as a screenset' }, { 'sload', 'name', 'load a screenset' }, { 'libsave', 'name', 'save the lib as a kit (REAPER track template, browser tab kits)' }, { 'big', '', 'big sample editor: the item tab over the whole window, wheel zoom' }, { 'macro', '', 'zoom out: a row is a beat (LPB 1); again - back to the previous LPB' }, { 'chord', '[Cm7 | off]', 'no argument - the cursor track as one chord lane (names from its notes, OFF ends); a symbol - write that chord at the cursor row (replaces the notes starting there). The chord lane track drives JS jf_tracker_chordfollow: put it on other tracks - their notes snap to the chord of the moment' }, { 'pt', 'new', 'PT-mode: 4 channels big (x4), note / sample / vol / one command, scopes on top; :pt new creates CH1..CH4; again - back' }, { 'arp', 'live | [up|down|updown|random|played] [step] [oct] [gate%]', 'chord on the cursor row -> arpeggio over its length' }, { 'fixslices', '', 'repair slice notes copied from a stretch-marked sample (they all played its start)' },
  { 'start', '[bar[.beat]]', '=START marker of the sequence (empty = cursor row)' }, { 'end', '[bar[.beat]]', '=END marker of the sequence' },
  { 'cc', '[N]', 'CC lane: N - a MIDI-item CC column (events of the MIDI items of the track); empty - ReaControlMIDI on the track, its parameter as an envelope column' }, { 'pc', '', 'program change column of the MIDI items of the cursor track' }, { 'curvesave', 'name', 'save the open automation item curve (Data/jf_tracker_curves)' }, { 'curves', '', 'browser on the saved curves - Enter loads one into the open automation item' },
  { 'browse', 'path', 'browser root' }, { 'dock', '', 'dock <-> fullscreen (F11)' }, { 'preview', '', 'preview on input' },
  { 'pitchmode', 'shift|resample', 'track pitch mode' },
  { 'sync', '', 'sync same-name regions' }, { 'autosync', '', 'sync after edits' },
  { 'follow', '', 'view follows playhead' }, { 'lock', '', 'tracker cursor = REAPER edit cursor and selected track' }, { 'fixed', '', 'cursor fixed at screen centre (Impulse Tracker)' }, { 'debug', '', 'debug log (jf_tracker_debug.log in the REAPER folder): keys and where they were handled, clicks, actions, errors; fps in the status' },
  { 'fold', '', 'fold all tracks' }, { 'unfold', '', 'unfold all' },
  { 'trim', '', 'trim items to region bounds (strict patterns)' },
  { 'beatsync', '[beat|bar|N]', 'stretch event end to the nearest beat / bar / N rows (= key, N=)' },
  { 'quantize', '', 'smart quantize the instrument: loud transients to beats, soft to 16ths, length to whole bars / beats (stretch markers)' },
  { 'tname', 'text', 'rename the cursor track (dblclick on the track name)' },
  { 'fxname', 'text', 'rename the selected fx or container in the chain (empty - its own name back)' },
  { 'iname', 'text', 'rename the selected instrument in all its items (click the name in sample properties)' },
  { 'orca', '[on|off|clear|pin|reset|size WxH|load]', 'Orca tab: Orca field (plants notes into the timeline while playing); :garden is the old name' },
  { '!', 'text', 'REAPER actions (all, incl. scripts / custom): fzf, recent first - kept apart from tracker commands; also \\ a' },
  { 'midi', '', 'MIDI learn tab: knobs and pads of a controller drive the slicer (Enter: learn)' },
  { 'loops', '', 'matrix loops layer: cells show item loop periods, digits+Enter / > < + - edit them' },
  { 'vel', 'N', 'velocity of inserted notes 1..127 (c / C in INSERT)' },
  { 'loop', '[N|region|off]', 'loop item to region end (>), N = loop period in rows (N>), region = region to item end (<), off' },
  { 'deltime', '[N] [all]', 'delete N rows of time in region (Backspace / Shift)' }, { 'instime', '[N] [all]', 'insert N rows of time in region (Insert / I / Shift)' },
  { 'ramp', 'xx [len]', 'envelope ramp to xx (hex) over len rows / Nb beats; VISUAL: selection' },
  { 'fade', 'in|out [len]', 'fade of audio event over len rows / Nb beats' },
}

function V.cmd_matches(line)
  local word = (line or ''):match('^%s*(%S*)') or ''
  local out = {}
  for _, c in ipairs(V.COMMANDS) do
    if word == '' or c[1]:sub(1, #word) == word then out[#out + 1] = c end
  end
  return out, word
end

local function run_cmd(line)
  local st = ctx.state
  -- :!текст — действия REAPER (отдельно от команд трекера): fzf с запросом
  local bang = line:match('^%s*!%s*(.*)$')
  if bang then if ctx.reaper_actions then ctx.reaper_actions(bang) end; return end
  local cmd, arg = line:match('^%s*(%S+)%s*(.*)$')
  if not cmd then return end
  local n = tonumber(arg)
  if cmd == 'q' then return 'quit'
  elseif cmd == 'w' then ctx.edit.save(); V.msg = 'saved'
  elseif cmd == 'wq' then ctx.edit.save(); return 'quit'
  elseif cmd == 'pane' then if ctx.pane_cmd then ctx.pane_cmd(arg) end   -- панели (9 окт)
  elseif cmd == 'z' or cmd == 'zi' then if ctx.browse_z then ctx.browse_z(cmd == 'zi' and '' or arg) end   -- zoxide (9 окт)
  elseif cmd == 'lpb' and n then ctx.set_lpb(math.floor(n))
  elseif cmd == 'ramp' then
    -- :ramp FF 2b — от текущего значения на строке курсора к xx за len;
    -- в VISUAL/V-LINE — от первой до последней строки выделения
    local xx, rest = arg:match('^%s*(%x%x)%s*(.*)$')
    local env = env_of(V.cur.fi)
    if not env then V.msg = 'ramp: cursor not on envelope column'
    elseif not xx then V.msg = 'ramp xx [len]: xx hex 00..FF'
    else
      local r0, r1
      local vis = V.cmd_from == 'visual' or V.cmd_from == 'vline'
      if vis then local _, _, a, b = V.visual_range(); r0, r1 = a, b
      else local len = parse_len(rest); if not len then V.msg = 'ramp: bad len'; return end; r0, r1 = V.cur.row, V.cur.row + len end
      if r1 > r0 then ctx.env_ramp(env, r0, r1, nil, tonumber(xx, 16) / 255); V.msg = ('ramp %s over %d rows'):format(xx, r1 - r0) end
    end
  elseif cmd == 'fade' then
    local dir, rest = arg:match('^%s*(%a+)%s*(.*)$')
    local len = parse_len(rest)
    if dir ~= 'in' and dir ~= 'out' then V.msg = 'fade in|out [len]'
    elseif not len then V.msg = 'fade: bad len'
    else
      local heads = V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row)
      local xx = math.min(255, len * 16)
      for _, h in ipairs(heads) do if h.kind == 'audio' then ctx.edit.set_fx({ h }, lpb(), dir == 'in' and 'I' or 'O', xx) end end
    end
  elseif cmd == 'step' and arg == 'auto' then V.step_auto = not V.step_auto; V.step_next = false; V.msg = 'step: ' .. (V.step_auto and 'auto (to the end of the inserted item / slice)' or tostring(V.step))
  elseif cmd == 'step' and arg == 'next' then V.step_next = not V.step_next; V.step_auto = false; V.msg = 'step: ' .. (V.step_next and 'next (to the next note / item / command / envelope point of the track)' or tostring(V.step))
  elseif cmd == 'step' and n then V.step = math.max(0, math.floor(n)); V.step_auto = false; V.step_next = false
  elseif cmd == 'oct' and n then V.octave = math.max(0, math.min(8, math.floor(n)))
  elseif cmd == 'inst' and n then ctx.pool_select(math.floor(n))
  elseif cmd == 'follow' then st.follow = not st.follow
  elseif cmd == 'debug' then st.debug = not st.debug
  elseif cmd == 'fold' then ctx.fold_all(true)
  elseif cmd == 'unfold' then ctx.fold_all(false)
  elseif cmd == 'fx' and n then st.fxcols = math.max(0, math.min(4, math.floor(n)))
  elseif cmd == 'cc' then if ctx.cc_lane then ctx.cc_lane(arg) end
  elseif cmd == 'pc' then if ctx.ml_add then ctx.ml_add('pc') end
  elseif cmd == 'curvesave' then if ctx.curve_save then ctx.curve_save(arg) end
  elseif cmd == 'curves' then if ctx.curve_browse then ctx.curve_browse() end
  elseif cmd == 'env' then st.envs = not st.envs
  elseif cmd == 'preview' then st.preview = not st.preview; V.msg = 'preview ' .. (st.preview and 'on' or 'off')
  elseif cmd == 'pitchmode' then
    local f = flat()[V.cur.fi]
    if f and (arg == 'shift' or arg == 'resample') then ctx.set_pitchmode(f.col, arg); V.msg = f.col.name .. ': ' .. arg
    else V.msg = ':pitchmode shift|resample' end
  elseif cmd == 'font' or cmd == 'face' then
    -- 10 окт: :font <имя> | next | prev | off — шрифт трекера (как опция font)
    if ctx.font_set then ctx.font_set(arg) end
  elseif cmd == 'scale' and n then local k = (math.abs(n - 1.5) < 0.01) and 1.5 or math.max(1, math.min(3, math.floor(n))); ctx.set_scale(k); V.msg = 'bitmap x' .. tostring(k):gsub('%.0$', '') .. (n > 3 and ' (x4 is kept for PT-mode)' or '')
  elseif cmd == 'space' and n then ctx.set_space(math.max(0, math.min(12, math.floor(n)))); V.msg = 'space ' .. math.floor(n)
  elseif cmd == 'tab' then
    -- вкладка item — бывшая sample (:tab sample убран, 3 окт); orca — бывшая garden
    if arg == 'sample' then V.msg = 'tab: item (the old sample tab)'; return end
    local a = (arg == 'mod' or arg == 'modulate' or arg == 'automation' or arg == 'auto') and 'modulation' or ((arg == 'item') and 'sample' or ((arg == 'orca') and 'garden' or arg))
    st.toptab = (a == 'sample' or a == 'modulation' or a == 'midi' or (a == 'grid' and st.gridtab) or a == 'retro' or (a == 'garden' and st.dev)) and a or 'master'
  elseif cmd == 'scopemode' then ctx.scopemode(arg ~= '' and arg or nil)
  elseif cmd == 'retro' then
    st.top = true; st.toptab = 'retro'
    if arg == 'add' then ctx.retro_add() end
  elseif cmd == 'pool' or cmd == 'top' then st.top = not st.top
  elseif cmd == 'meters' then st.meters = not st.meters
  elseif cmd == 'wave' then ctx.wave_mode(arg ~= '' and arg or nil)
  elseif cmd == 'lock' then st.lock = not st.lock; V.msg = 'lock to REAPER cursor: ' .. (st.lock and 'on' or 'off')
  elseif cmd == 'fixed' then st.fixed = not st.fixed; V.msg = 'fixed cursor: ' .. (st.fixed and 'on' or 'off')
  elseif cmd == 'xfade' then
    if n then ctx.xfade_len(0, math.floor(n)) elseif arg == 'now' then ctx.xfade_now() elseif arg == 'off' or arg == 'on' then if (arg == 'on') ~= (st.xfade == true) then ctx.xfade_toggle() end else ctx.xfade_toggle() end
  elseif cmd == 'icons' then V.msg = 'icons are gone - bitmap only'
  elseif cmd == 'mxzoom' then ctx.mx_zoom()
  elseif cmd == 'trim' then if ctx.mx_trim then ctx.mx_trim() end
  elseif cmd == 'quantize' or cmd == 'squant' then ctx.smart_quantize()
  elseif cmd == 'tname' then ctx.rename_track(arg)
  elseif cmd == 'fxname' then if ctx.fx_rename then ctx.fx_rename(arg) end
  elseif cmd == 'iname' then ctx.rename_inst(arg)
  elseif cmd == 'garden' or cmd == 'orca' then ctx.garden_cmd(arg ~= '' and arg or 'show')
  elseif cmd == 'midi' then st.top = true; st.toptab = 'midi'; if ctx.set_focus then ctx.set_focus('top') end
  elseif cmd == 'start' or cmd == 'end' then if ctx.seq_marker then ctx.seq_marker(cmd, arg) end
  elseif cmd == 'loops' then if ctx.mx_loops_toggle then ctx.mx_loops_toggle() end
  elseif cmd == 'vel' and n then V.vel = math.max(1, math.min(127, math.floor(n))); V.msg = 'velocity ' .. V.vel
  elseif cmd == 'loop' then
    if n then ctx.loop('item', math.max(1, math.floor(n)))
    elseif arg == 'region' or arg == 'off' then ctx.loop(arg)
    else ctx.loop('item') end
  elseif cmd == 'options' or cmd == 'opt' then ctx.options()
  elseif cmd == 'about' then ctx.about(arg)
  elseif cmd == 'tcolor' then if ctx.track_colour_hex then ctx.track_colour_hex(arg) end   -- 10 окт: цвет трека кодом
  elseif cmd == 'transients' or cmd == 'trans' then   -- 10 окт: модуль детектора транзиентов (= Opt+D во вкладке item)
    if ctx.slicer_dt then ctx.slicer_dt() end
  elseif cmd == 'arr' then
    local w, rest = (arg or ''):match('^(%S*)%s*(.-)$')
    ctx.arr(w ~= '' and w or nil, rest)
  elseif cmd == 'theme' then
    if arg and arg ~= '' then if ctx.apply_theme(arg) then V.msg = 'theme: ' .. arg end else V.msg = 'themes: reaper modus-vivendi modus-operandi gruvbox catppuccin mono' end
  elseif cmd == 'name' then ctx.mx_name(arg)
  elseif cmd == 'redo' then ctx.edit.redo(); V.msg = 'redo'                     -- 5 окт: Ctrl+R теперь вкладка rec
  elseif cmd == 'undo' then ctx.edit.undo(); V.msg = 'undo'
  elseif cmd == 'iprop' then local k, v = (arg or ''):match('^(%S+)%s*(.*)$'); if k and ctx.item_prop then ctx.item_prop(k, v or '') end   -- свойства item (5 окт)
  elseif cmd == 'optsave' then ctx.opt_save(arg)                -- профили опций (5 окт)
  elseif cmd == 'optload' then ctx.opt_load(arg)
  elseif cmd == 'optdel' then ctx.opt_del(arg)
  elseif cmd == 'len' then ctx.mx_len(arg)
  elseif cmd == 'pat' then if ctx.slot_set_pattern then ctx.slot_set_pattern(tonumber(arg)) end   -- 10 окт: :pat N — паттерн N в слот курсора матрицы
  elseif cmd == 'sig' then ctx.sig_cmd(arg)
  elseif cmd == 'add' then local b, nm = arg:match('^(%d*)%s*(.*)$'); ctx.mx_add(tonumber(b) or 1, nm)
  elseif cmd == 'beatsync' or cmd == 'bs' then
    local heads
    if V.cmd_from == 'visual' or V.cmd_from == 'vline' then local f0, f1, r0, r1 = V.visual_range(); heads = V.heads_in(f0, f1, r0, r1)
    else heads = V.covering(V.cur.fi, V.cur.row); if #heads == 0 then heads = V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row) end end
    local unit = (arg == 'bar' or arg == 'beat') and arg or (n and tostring(math.floor(n)) or 'beat')
    V.msg = ('beatsync %s: %d event(s)'):format(unit, ctx.edit.beatsync(heads, lpb(), unit) or 0)
  elseif cmd == 'deltime' or cmd == 'instime' then
    if ctx.time_edit then ctx.time_edit(cmd == 'deltime' and 'delete' or 'insert', V.cur.fi, V.cur.row, n or 1, arg:find('all') ~= nil) end
  elseif cmd == 'scopes' then ctx.toggle_scopes()
  elseif cmd == 'dsp' then if arg:match('^%s*big') then ctx.dsp_big() else ctx.toggle_dsp() end
  elseif cmd == 'punch' then ctx.punch()
  elseif cmd == 'recmode' then V.open_hydra(ctx.hydra_recmode())
  elseif cmd == 'lanes' then ctx.toggle_lanes()
  elseif cmd == 'rec' then ctx.rec_arm()
  elseif cmd == 'input' then V.open_hydra(ctx.hydra_inputs())
  elseif cmd == 'smartin' then ctx.smart_input()
  elseif cmd == 'slice' then ctx.open_slicer()
  elseif cmd == 'poolprev' then st.poolprev = not st.poolprev; V.msg = 'pool preview ' .. (st.poolprev and 'on' or 'off')
  elseif cmd == 'side' then st.side = not st.side
  elseif (cmd == 'pt' or cmd == 'ptmode') and (arg or ''):match('^%s*new') then ctx.pt_new()
  elseif cmd == 'pt' or cmd == 'ptmode' then ctx.pt_toggle()
  elseif cmd == 'fxa' or cmd == 'fxb' then
    -- A / B (4 окт): снимок параметров выбранного эффекта DSP
    if ctx.ab_store then ctx.ab_store(cmd == 'fxa' and 'a' or 'b') end
  elseif cmd == 'morph' then
    local x = tonumber(arg or '')
    if x and ctx.ab_morph_sel then ctx.ab_morph_sel(x / 100) else V.msg = 'morph: like :morph 50 (0 = A, 100 = B)' end
  elseif cmd == 'interp' then
    -- :interp [vol|delay|note|буква команды] (4 окт, из Paketti — Esa Ruoho):
    -- в VISUAL у каждой колонки значения первого и последнего события тянутся
    -- линейно по строкам на события между ними; поле — по курсору или словом
    if not (V.cmd_from == 'visual' or V.cmd_from == 'vline') then V.msg = 'interp: select rows first (v / V)'; return end
    local f0, f1, r0, r1 = V.visual_range()
    local what = (arg or ''):match('^%s*(%S*)')
    if what == '' then
      local fld = V.cur.field or 1
      what = fld == 1 and 'note' or (fld == 2 and 'vol' or (fld == 3 and 'delay' or 'cmd'))
    end
    local E = ctx.edit
    local BASE = (ctx.model and ctx.model.BASE_NOTE) or 60
    local function get(h, letter)
      if what == 'vol' then return tonumber(h.vol or '', 16)
      elseif what == 'delay' then return h.delay
      elseif what == 'note' then return h.pitch or (h.semis and BASE + math.floor(h.semis + 0.5))
      else for _, fx in ipairs(h.fx or {}) do if fx:sub(1, 1) == letter then return tonumber(fx:sub(2), 16) end end end
    end
    local n = 0
    E.run('interpolate ' .. what, function()
      for fi = math.min(f0, f1), math.max(f0, f1) do
        local hs = V.heads_in(fi, fi, r0, r1)
        table.sort(hs, function(a, b) return a.row0 < b.row0 end)
        local letter = (#what == 1) and what:upper() or nil
        if what == 'cmd' and hs[1] then letter = ((hs[1].fx or {})[1] or ''):sub(1, 1) end
        if #hs >= 3 then
          local a, b = get(hs[1], letter), get(hs[#hs], letter)
          local ra, rb = hs[1].row0, hs[#hs].row0
          if a and b and rb > ra then
            for k = 2, #hs - 1 do
              local h = hs[k]
              local v = a + (b - a) * (h.row0 - ra) / (rb - ra)
              if what == 'vol' then E.set_vol({ h }, lpb(), v)
              elseif what == 'delay' then E.set_delay({ h }, lpb(), v)
              elseif what == 'note' then E.set_pitch({ h }, lpb(), math.floor(v + 0.5))
              elseif letter and letter ~= '' then E.set_fx({ h }, lpb(), letter, math.floor(v + 0.5)) end
              n = n + 1
            end
          end
        end
      end
    end)
    V.mode = 'normal'
    V.msg = n > 0 and ('interp %s: %d event(s) in between'):format(what, n) or 'interp: each column needs 3+ events with that value in the selection'
  elseif cmd == 'sw' then
    -- :sw N — то же, что Ngw
    if V.swap_forward(math.max(1, tonumber(arg or '') or 1)) and ctx.model then ctx.model.invalidate() end
  elseif cmd == 'off' then V.note_off_scope((arg or ''):match('all') and 'all' or 'track')   -- 9 окт: :off — трек, :off all — все треки
  elseif cmd == 'repeat' then if ctx.repeat_pattern then ctx.repeat_pattern((arg or ''):match('all') ~= nil) end   -- 9 окт: как Ctrl+Opt+J (all — все треки)
  elseif cmd == 'mac' then if ctx.mac_run then ctx.mac_run(arg) end   -- 9 окт: :mac имя — проиграть макрос
  elseif cmd == 'macsave' then if ctx.mac_save then ctx.mac_save(arg) end   -- 9 окт: :macsave a имя — регистр в свои макросы
  elseif cmd == 'scramble' then
    -- :scramble (4 окт, Paketti) — VISUAL: слайсы в выделении; иначе — все
    -- ноты-слайсы трека курсора в регионе курсора (без региона — весь трек)
    local hs
    if V.cmd_from == 'visual' or V.cmd_from == 'vline' then
      local f0, f1, r0, r1 = V.visual_range(); hs = V.heads_in(f0, f1, r0, r1)
    else
      local F = flat(); local col = F[V.cur.fi] and F[V.cur.fi].col
      local r0, r1
      if ctx.region_rows then r0, r1 = ctx.region_rows() end
      r0, r1 = r0 or 0, r1 or 1000000
      hs = {}
      for fi, f in ipairs(F) do
        if f.col == col then for _, h in ipairs(V.heads_in(fi, fi, r0, r1)) do hs[#hs + 1] = h end end
      end
    end
    local n = ctx.edit.scramble(hs, lpb())
    V.mode = 'normal'
    V.msg = n > 0 and ('scramble: %d slice note(s) got another slice'):format(n) or 'scramble: needs 2+ slice notes of one sample (select them or put the cursor in the region)'
  elseif cmd == 'big' then ctx.sample_big()
  elseif cmd == 'pm' then if ctx.pm_cmd then ctx.pm_cmd(arg) end
  elseif cmd == 'session' then if ctx.ss_cmd then ctx.ss_cmd(arg) end
  elseif cmd == 'note' then
    -- :note C-4 [строк] (4 окт): нота инструмента в строку курсора
    local nm, r = (arg or ''):match('^%s*(%S+)%s*(%d*)')
    local p = nm and V.parse_note and V.parse_note(nm)
    if p and ctx.insert_note_cmd then ctx.insert_note_cmd(p, tonumber(r)) else V.msg = 'note: like :note C-4 4' end
  elseif cmd == 'sl' then
    -- :sl N [строк] [+полутонов]
    local k, r, sm = (arg or ''):match('^%s*(%d+)%s*(%d*)%s*([%+%-]?%d*)')
    if k and ctx.insert_slice_cmd then ctx.insert_slice_cmd(tonumber(k), tonumber(r), tonumber(sm)) else V.msg = 'sl: like :sl 3 [rows] [+semis]' end
  elseif cmd == 'whole' then if ctx.insert_whole then ctx.insert_whole(tonumber(arg)) end
  elseif cmd == 'ssave' then if ctx.ss_save then ctx.ss_save(arg) end
  elseif cmd == 'sload' then if ctx.ss_load then ctx.ss_load((arg or ''):gsub('^%s+', '')) end
  elseif cmd == 'swing' then if ctx.swing_cmd then ctx.swing_cmd(arg) end
  elseif cmd == 'jftop' then if ctx.jftop then ctx.jftop() end
  elseif cmd == 'audio' then if ctx.audio_cmd then ctx.audio_cmd(arg) end   -- 10 окт: dev <имя> | bs N | sr N | apply
  elseif cmd == 'logo' then if ctx.logo_show then ctx.logo_show(arg) end
  elseif cmd == 'dev' then if ctx.dev_set then ctx.dev_set(arg) end
  elseif cmd == 'tutorial' or cmd == 'tutor' then if ctx.tutorial then ctx.tutorial(arg == 'text') end
  elseif cmd == 'mcmd' then if ctx.mcmd_set then ctx.mcmd_set(V.cur.row, arg) end   -- 11 окт: команда мастера (маркер) в строке курсора
  elseif cmd == 'libsave' then if ctx.kit_save then ctx.kit_save(arg) end
  elseif cmd == 'legato' then
    -- :legato [off|auto] (3 окт): ноты трека курсора встык со следующими, под темп;
    -- в VISUAL / V-LINE — строки выделения
    local f = flat()[V.cur.fi]
    if not (f and f.col) then V.msg = 'legato: no track'; return end
    local lane_idx = f.col.fixed and f.lane and f.lane.idx or nil
    local w = (arg or ''):match('^%s*(%a*)')
    if w == 'auto' then
      local on = not ctx.edit.legato_auto(f.col.track)
      ctx.edit.legato_auto(f.col.track, on)
      if on then ctx.edit.legato(f.col.track, lane_idx) end
      V.msg = 'legato auto ' .. (on and 'on' or 'off') .. ': ' .. (f.col.name or '')
    else
      local t0, t1
      if V.cmd_from == 'visual' or V.cmd_from == 'vline' then
        local _, _, r0, r1 = V.visual_range()
        t0, t1 = ctx.row_time(r0), ctx.row_time(r1 + 1)
      end
      local n = ctx.edit.legato(f.col.track, lane_idx, t0, t1, w == 'off')
      V.msg = ('legato%s: %d note(s) on %s'):format(w == 'off' and ' off' or '', n, f.col.name or '')
    end
    ctx.model.invalidate()
  elseif cmd == 'pmtag' then if ctx.pm_set_tags then ctx.pm_set_tags(arg) end
  elseif cmd == 'chord' then if ctx.chord_cmd then ctx.chord_cmd(arg) end   -- 8 окт: вид аккордов / гармонайзер
  -- 6 окт: птичий вид убран — :macro теперь зум-аут (строка = доля), повтор — прежний LPB
  elseif cmd == 'macro' then if ctx.zoom_out_toggle then ctx.zoom_out_toggle() end
  elseif cmd == 'arp' and (arg or ''):match('^%s*live') then
    V.arp_live = not V.arp_live
    V.msg = V.arp_live and 'arp live: hold notes in INSERT (or the piano layer) - an arpeggio is written at the tempo, step = :step; :arp up/down/... sets the order' or 'arp live off'
  elseif cmd == 'arp' then
    -- :arp [up|down|updown|random|played] [шаг] [октав] [gate %] (3 окт): аккорд
    -- строки курсора (все подколонки трека) → арпеджио на его длину
    local o = V.arp_opt or { order = 'up', step = 1, oct = 1, gate = 100 }
    local nums = {}
    for w in (arg or ''):gmatch('%S+') do
      local lw = w:lower()
      if lw == 'up' or lw == 'down' or lw == 'updown' or lw == 'random' or lw == 'played' then o.order = lw
      elseif lw:match('^%d+%%$') then o.gate = tonumber(lw:sub(1, -2))
      elseif tonumber(lw) then nums[#nums + 1] = tonumber(lw) end
    end
    if nums[1] then o.step = math.max(1, math.floor(nums[1])) end
    if nums[2] then o.oct = math.max(1, math.min(4, math.floor(nums[2]))) end
    if nums[3] then o.gate = nums[3] end
    V.arp_opt = o
    local f = flat()[V.cur.fi]
    local heads = {}
    if f and f.col then
      for _, g in ipairs(flat()) do
        if g.col == f.col and g.sub then
          local h = g.sub[V.cur.row]
          if h and (h.kind == 'audio' or h.kind == 'midi') then heads[#heads + 1] = h end
        end
      end
    end
    if #heads < 1 then V.msg = 'arp: no notes start on the cursor row of this track (put a chord there: notes in its subcolumns)'
    else
      local n = ctx.edit.arpeggiate(f.col.track, f.col.fixed and f.lane and f.lane.idx or nil, lpb(), V.cur.row, heads,
        { order = o.order, step = o.step, oct = o.oct, gate = (o.gate or 100) / 100, seed = math.floor((V.cur.row + 1) * 7919) })
      V.msg = ('arp %s: %d notes, step %d, %d oct, gate %d%%'):format(o.order, n, o.step, o.oct, o.gate or 100)
    end
  elseif cmd == 'fixslices' then local n = ctx.edit.fix_slices(); ctx.model.invalidate(); V.msg = ('fixslices: %d slice note(s) now play their own piece'):format(n)
  elseif cmd == 'dock' then ctx.toggle_dock()
  elseif cmd == 'reg' then
    local v
    if arg == 'on' then v = true elseif arg == 'off' then v = false end   -- без аргумента — переключить
    ctx.view_reg(v)
  elseif cmd == 'shape' then
    -- :shape fas — форма точек огибающей в строке курсора (VISUAL — в диапазоне строк)
    local env = env_of(V.cur.fi)
    local m = arg ~= '' and V.shape_match(arg:lower())
    if not env then V.msg = ':shape - cursor on an envelope column'
    elseif not m then V.msg = 'shape: lin sqr slo fas fae bez'
    else
      local r0, r1 = V.cur.row, V.cur.row
      if V.cmd_from == 'visual' or V.cmd_from == 'vline' then local _, _, a, b = V.visual_range(); r0, r1 = a, b end
      local n = 0
      for r = r0, r1 do if ctx.env_shape(env, r, m) then n = n + 1 end end
      V.msg = ('shape %s: %d point(s)'):format(V.SHAPES[m + 1], n)
    end
  elseif cmd == 'mkdir' then if ctx.browser_mkdir then ctx.browser_mkdir(arg) end
  elseif cmd == 'browse' then ctx.browse(arg ~= '' and arg or nil); st.side = true
  elseif cmd == 'sync' then V.msg = 'synced ' .. tostring(ctx.sync_here())
  elseif cmd == 'autosync' then st.autosync = not st.autosync; V.msg = 'autosync ' .. (st.autosync and 'on' or 'off')
  else V.msg = 'unknown: ' .. cmd end
end

-- ── главный вход ──────────────────────────────────────────────────────────
-- Возвращает 'quit' при выходе, иначе nil.
-- INSERT: управляющие клавиши нижних рядов (Ableton-стиль + Vim-движение, 2 окт).
-- Возвращает true, если клавиша съедена. Пианино — верхний ряд, сюда не попадает.
local function keys_control(c)
  local ch = (c < 256) and string.char(c) or ''
  local function heads() return V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row) end
  if ch == 'h' or ch == 'j' or ch == 'k' or ch == 'l' or ch == 'H' or ch == 'L' or ch == 'G' then
    local m = motion(c, V.count or 1)
    if m then V.cur.fi, V.cur.row = m.fi, m.row; if m.field then V.cur.field = m.field; V.cur.sub = m.sub end; clamp_cur(); ensure_visible() end
    V.count = nil; V.hexbuf = nil; return true
  elseif ch == 'g' then V.cur.row = 0; ensure_visible(); return true
  elseif (ch == '-' or ch == '+' or ch == '=') and (V.cur.field or 1) == 1 then   -- 10 окт: LPB, как в NORMAL
    ctx.set_lpb(nil, ch == '-' and -1 or 1); V.msg = 'LPB ' .. ctx.state.lpb; return true
  elseif ch == 'b' or ch == 'n' then
    local m = motion((ch == 'b' and '{' or '}'):byte(), 1)
    if m then V.cur.fi, V.cur.row = m.fi, m.row; clamp_cur(); ensure_visible() end
    return true
  elseif ch == 'z' then V.octave = math.max(0, V.octave - 1); return true
  elseif ch == 'x' then V.octave = math.min(8, V.octave + 1); return true
  elseif ch == 'c' then V.vel = math.max(1, (V.vel or 100) - 8); V.msg = 'velocity ' .. V.vel; return true
  elseif ch == 'C' then V.vel = math.min(127, (V.vel or 100) + 8); V.msg = 'velocity ' .. V.vel; return true
  elseif ch == ',' then ctx.pool_select(V.inst - 1); return true
  elseif ch == '.' then ctx.pool_select(V.inst + 1); return true
  elseif ch == ';' then                                       -- целый сэмпл (материнский item), 4 окт
    if ctx.insert_whole then ctx.insert_whole() end   -- 10 окт: INSERT пишет всегда (INSERT KEYS слит с INSERT)
    return true
  elseif ch == 'a' then V.step_auto = not V.step_auto; V.step_next = false; V.msg = 'step: ' .. (V.step_auto and 'auto' or tostring(V.step)); return true
  elseif ch == 'd' then
    -- d — оператор Vim (d3w, dd, dG…): ждёт счётчик и движение, потом обратно в INSERT (2 окт)
    V.mode = 'normal'; V.pending = 'd'; V.count = nil; V.back_insert = true; V.hexbuf = nil; return true
  elseif ch == 'M' or ch == 'S' then if ctx.track_toggle then ctx.track_toggle(ch == 'M' and 'mute' or 'solo') end; return true   -- 9 окт: Shift+M / Shift+S — mute / solo трека
  elseif ch == 'f' then
    local nf = nfields()
    local fld = V.cur.field or 1
    if nf < 4 then V.cur.field = 1 elseif fld < 4 or fld >= nf then V.cur.field = 4 else V.cur.field = fld + 1 end
    V.hexbuf = nil; return true
  end
  return false
end

-- Клавиша ноты с модификатором → (код базовой клавиши, как):
-- Shift (Q..P, @#%^&()) → 'audition'; Option (mac-символы œ∑®… или флаг alt)
-- → 'beside'; Ctrl (коды 1..26 или флаг ctrl) → 'capture'; иначе 'insert'.
local SHIFTED = { ['@'] = '2', ['#'] = '3', ['%'] = '5', ['^'] = '6', ['&'] = '7', ['('] = '9', [')'] = '0' }
local OPTCH = { [339] = 'q', [8721] = 'w', [180] = 'e', [174] = 'r', [8224] = 't', [165] = 'y', [168] = 'u',
                [710] = 'i', [248] = 'o', [960] = 'p' }   -- 9 окт: Option+цифры — инструменты (аккорд — буквы)
function V.note_key(c, mods)
  mods = mods or {}
  -- Cmd (3 окт): нота с удержанием — длина = сколько держали (+ j / ↓ шаги);
  -- Cmd+Shift — то же, но сэмпл растягивается на эту длину
  -- Cmd (4 окт): нота — питч ВСЕГО айтема (у нарезанного тоже)
  if mods.cmd then
    local base = c
    local cb = (base < 256) and string.char(base) or ''
    if SHIFTED[cb] then base = SHIFTED[cb]:byte() elseif cb:match('^[QWERTYUIOP]$') then base = cb:lower():byte() end
    return base, 'whole'
  end
  -- Ctrl (4 окт): нота с удержанием — длина = сколько держали (+ j / ↓)
  if mods.ctrl then
    local base = (c >= 1 and c <= 26) and (c + 96) or c
    return base, 'hold'
  end
  local ch = (c < 256) and string.char(c) or ''
  local cp = (c >= 0x75000000 and c < 0x76000000) and (c - 0x75000000) or c   -- 'u'-префикс не-ASCII (5 окт)
  if OPTCH[cp] then return OPTCH[cp]:byte(), 'beside' end

  if SHIFTED[ch] then return SHIFTED[ch]:byte(), 'audition' end
  if ch:match('^[QWERTYUIOP]$') then return ch:lower():byte(), 'audition' end
  if mods.alt then return c, 'beside' end
  if mods.shift then return c, 'audition' end
  return c, 'insert'
end

function V.key_impl(c)
  if c <= 0 then return end
  local E = ctx.edit
  local st = ctx.state
  local n = V.count or 1

  -- открытые fzf-пикер и hydra — первыми (4 окт: меню нарезки s открывалось
  -- поверх слайсера, а t / 8 … забирал слайсер как ноты — «st не резал»)
  if V.picker then V.picker_key(c); return end
  if V.hydra then V.hydra_key(c); return end
  -- слайсер (оверлей) перехватывает всё остальное — кроме выбора инструмента /
  -- трека (10 окт: Opt+J / K из браузера молча съедал открытый слайсер):
  -- Option+hjkl, Option+цифра, Cmd+цифра идут дальше, как без слайсера
  -- 10 окт: Opt+D (∂) во вкладке item — модуль детектора транзиентов (слайсер откроется, если закрыт)
  do
    local cpd = (c >= 0x75000000 and c < 0x76000000) and (c - 0x75000000) or c
    local m1 = ctx.mods and ctx.mods() or {}
    if (cpd == 8706 or (m1.alt and (c == 100 or c == 68))) and ctx.slicer_dt and (st.focus == 'sample' or (st.focus == 'top' and st.toptab == 'sample')) then ctx.slicer_dt(); return end
  end
  if ctx.slicer_active and ctx.slicer_active() then
    local m0 = ctx.mods and ctx.mods() or {}
    local cp = (c >= 0x75000000 and c < 0x76000000) and (c - 0x75000000) or c
    local SEL = { [729] = true, [8710] = true, [730] = true, [172] = true,
                  [161] = true, [8482] = true, [163] = true, [162] = true, [8734] = true, [167] = true, [182] = true, [8226] = true, [170] = true, [186] = true }
    local pass = SEL[cp] or ((m0.cmd or m0.alt) and not m0.ctrl and c >= ('0'):byte() and c <= ('9'):byte())
    if not pass then ctx.slicer_key(c); return end
  end

  -- командная строка (+ подсказка и Tab-дополнение)
  if V.mode == 'cmd' then
    local back = (V.cmd_from == 'insert') and 'insert' or 'normal'
    -- история (9 окт, как в zsh / atuin): ↑ ↓ Ctrl+P Ctrl+N — по набранному
    -- началу, Ctrl+R — fzf по всей истории (выбранная — в строку)
    V.hist = V.hist or (ctx.cmd_hist_load and ctx.cmd_hist_load()) or {}
    if c == UP or c == DOWN or c == 16 or c == 14 then
      local h = V.hist
      if not V.hist_pos then V.hist_pos, V.hist_pre = #h + 1, V.cmdline or '' end
      local d = (c == UP or c == 16) and -1 or 1
      local i = V.hist_pos + d
      while i >= 1 and i <= #h and h[i]:sub(1, #V.hist_pre) ~= V.hist_pre do i = i + d end
      if i < 1 then return end
      if i > #h then V.hist_pos = #h + 1; V.cmdline = V.hist_pre; return end
      V.hist_pos = i; V.cmdline = h[i]; V.cmd_cycle = nil
      return
    end
    if c == 18 then
      local items, seen = {}, {}
      for i = #V.hist, 1, -1 do local l = V.hist[i]; if not seen[l] then seen[l] = true; items[#items + 1] = { label = l, data = l } end end
      if #items == 0 then V.msg = 'no command history yet'; return end
      local from = V.cmd_from
      V.open_picker('command history (Enter - into the line)', items, function(it) V.cmd_from = from; V.mode = 'cmd'; V.cmdline = it.data end, V.cmdline or '')
      return
    end
    if c ~= UP and c ~= DOWN then V.hist_pos, V.hist_pre = nil, nil end
    if c == ESC then V.mode = back; V.cmdline = nil; V.cmd_cycle = nil
    elseif c == ENTER then
      local line = V.cmdline or ''
      V.mode = back; V.cmdline = nil; V.cmd_cycle = nil
      if line:match('%S') then
        for i = #V.hist, 1, -1 do if V.hist[i] == line then table.remove(V.hist, i) end end
        V.hist[#V.hist + 1] = line
        while #V.hist > 200 do table.remove(V.hist, 1) end
        if ctx.cmd_hist_save then ctx.cmd_hist_save(V.hist) end
      end
      return run_cmd(line)
    elseif c == TAB then
      local matches, word = V.cmd_matches(V.cmdline)
      if #matches > 0 then
        V.cmd_cycle = ((V.cmd_cycle or 0) % #matches) + 1
        local m = matches[V.cmd_cycle]
        V.cmdline = m[1] .. (m[2] ~= '' and ' ' or '')
      end
    elseif c == BS then V.cmdline = (V.cmdline or ''):sub(1, -2); V.cmd_cycle = nil
    elseif c == 47 and ctx.name_suggest and ctx.name_suggest(V.cmdline or '') then V.cmd_cycle = nil   -- «/» в имени — подсказки
    elseif c >= 32 and c < 127 then V.cmdline = (V.cmdline or '') .. string.char(c); V.cmd_cycle = nil end
    return
  end

  -- строка поиска
  if V.mode == 'search' then
    local back = (V.cmd_from == 'insert') and 'insert' or 'normal'
    if c == ESC then V.mode = back; V.searchline = nil
    elseif c == ENTER then
      V.search = V.searchline; V.mode = back; V.searchline = nil
      V.find_next(1)
    elseif c == BS then V.searchline = (V.searchline or ''):sub(1, -2)
    elseif c >= 32 and c < 127 then V.searchline = (V.searchline or '') .. string.char(c) end
    return
  end

  -- HJKL с модификаторами (macOS: gfx бит 4 = Cmd, 32 = Ctrl, 16 = Option):
  --   Ctrl   — курсор матрицы;  Option — треки (H/L) и события трека (J/K);
  --   Cmd    — инструмент трека (J/L следующий, K/H предыдущий).
  -- Ctrl+H = 8 = Backspace, Option+h = «˙» и т.п. — различаем по битам.
  local mods = ctx.mods and ctx.mods() or {}
  local HJKL = { [104] = 'h', [106] = 'j', [107] = 'k', [108] = 'l', [8] = 'h', [10] = 'j', [11] = 'k', [12] = 'l',
                 [729] = 'h', [8710] = 'j', [730] = 'k', [172] = 'l',
                 [LEFT] = 'h', [DOWN] = 'j', [UP] = 'k', [RIGHT] = 'l' }   -- 6 окт: стрелки = hjkl во всех сочетаниях
  -- 9 окт: Option+цифра — инструмент N lib (1..9, 0 = 10) в любом режиме, в
  -- пару к Option+J / K. На US-раскладке Option+цифра даёт символ (¡ ™ £ …).
  -- Ctrl+Option+цифра — форма сегмента огибающей (ниже), не трогаем
  do
    local OPTDIG = { [161] = 1, [8482] = 2, [163] = 3, [162] = 4, [8734] = 5, [167] = 6, [182] = 7, [8226] = 8, [170] = 9, [186] = 0 }
    local cp = (c >= 0x75000000 and c < 0x76000000) and (c - 0x75000000) or c
    local d = OPTDIG[cp] or ((mods.alt and c >= ('0'):byte() and c <= ('9'):byte()) and (c - ('0'):byte()) or nil)
    if d and not mods.ctrl and not mods.cmd and V.mode ~= 'cmd' and V.mode ~= 'search' then
      if d == 0 then d = 10 end
      if ctx.pool_select then ctx.pool_select(d) end
      V.count = nil; return
    end
  end
  -- 10 окт: Ctrl+цифра — длина шага (step 0..9; 0 — курсор стоит), step auto выкл
  if mods.ctrl and not mods.alt and not mods.cmd and c >= ('0'):byte() and c <= ('9'):byte() and V.mode ~= 'cmd' and V.mode ~= 'search' then
    V.step = c - ('0'):byte(); V.step_auto = false
    V.msg = 'step ' .. V.step .. (V.step == 0 and ' - the cursor stays' or ' row(s)')
    V.count = nil; return
  end
  -- 10 окт: ⌘+цифра — прыжок на канал N (1..9, 0 = 10) в любом режиме (было —
  -- инструмент, теперь он только на Option+цифре); Ctrl+O — назад
  if mods.cmd and not mods.shift and c >= ('0'):byte() and c <= ('9'):byte() and V.mode ~= 'cmd' and V.mode ~= 'search'
     and not ((V.mode == 'insert' or V.piano) and ctx.piano[c]) then      -- в INSERT / слое пианино ⌘+цифра — нота с удержанием
    local k = c - ('0'):byte(); if k == 0 then k = 10 end
    local to
    for i, f in ipairs(flat()) do if f.ci == k and not f.env then to = i; break end end
    if to then
      if to ~= V.cur.fi and ctx.jump_mark then ctx.jump_mark() end
      V.cur.fi = to; V.cur.field = 1; V.cur.sub = nil
      ensure_visible()
      local f = flat()[to]
      V.msg = ('channel %d: %s'):format(k, f.col and f.col.name or '')
    else V.msg = ('no channel %d'):format(k) end
    V.count = nil; return
  end
  local hk = HJKL[c]
  -- 10 окт: Shift+Opt+J / K — транспоз выбранного инструмента −1 / +1 полутон (счётчик — на N)
  if mods.alt and mods.shift and not mods.ctrl and not mods.cmd and (hk == 'j' or hk == 'k' or c == DOWN or c == UP) and V.mode ~= 'cmd' and V.mode ~= 'search' then
    if ctx.inst_transpose then ctx.inst_transpose(((hk == 'k' or c == UP) and 1 or -1) * n) end
    V.count = nil; return
  end
  -- 11 окт: Shift+Opt+H / L — playrate выбранного инструмента (не переход по трекам)
  if mods.alt and mods.shift and not mods.ctrl and not mods.cmd and (hk == 'h' or hk == 'l' or c == LEFT or c == RIGHT) and V.mode ~= 'cmd' and V.mode ~= 'search' then
    if ctx.inst_rate then ctx.inst_rate(((hk == 'l' or c == RIGHT) and 1 or -1) * n) end
    V.count = nil; return
  end
  -- повтор паттерна над курсором (4 окт, Paketti): Ctrl+Opt+J / ↓ — трек курсора;
  -- все треки — :repeat all (Shift+Opt+J с 10 окт — транспоз)
  if mods.alt and mods.ctrl and not mods.cmd and (hk == 'j' or c == DOWN) and V.mode ~= 'cmd' and V.mode ~= 'search' then
    if ctx.repeat_pattern then ctx.repeat_pattern(false) end
    V.count = nil; return
  end
  if hk and (mods.ctrl or mods.alt or mods.cmd) and V.mode ~= 'cmd' and V.mode ~= 'search' then
    if mods.ctrl then
      local dx, dy = 0, 0
      if hk == 'h' then dx = -1 elseif hk == 'l' then dx = 1 elseif hk == 'j' then dy = 1 elseif hk == 'k' then dy = -1 end
      if ctx.matrix_move then ctx.matrix_move(dx * n, dy * n) end
    elseif mods.alt and (hk == 'j' or hk == 'k') then
      -- 9 окт: Option+J / K — инструмент (сквозная нумерация lib: сэмплы,
      -- плагины, automation); со счётчиком — через N
      if ctx.pool_select then ctx.pool_select(V.inst + (hk == 'j' and n or -n)) end
    elseif mods.cmd and (hk == 'j' or hk == 'k') then
      -- Cmd+J / K (9 окт, было Option): слайс внутри инструмента; без слайсов —
      -- прыжок по item трека (W / B)
      if ctx.slice_step and ctx.slice_step(hk == 'j' and n or -n) then V.count = nil; return end
      local t = motion(hk == 'j' and ('W'):byte() or ('B'):byte(), n)
      if t then V.cur.fi, V.cur.row = t.fi, t.row; clamp_cur(); ensure_visible() end
    else
      -- Option+H / L — треки (Cmd+H / L — тоже)
      local t = motion(hk == 'h' and ('H'):byte() or ('L'):byte(), n)
      if t then V.cur.fi, V.cur.row = t.fi, t.row; clamp_cur(); ensure_visible() end
    end
    V.count = nil; return
  end

  -- форма сегмента прямо на лейне (6 окт): Ctrl+Opt+1..6 = lin sqr slo fas
  -- fae bez, в любом поле и режиме; голые цифры — значение точки
  do
    local mods = ctx.mods and ctx.mods() or {}
    local env = env_of(V.cur.fi)
    if env and mods.ctrl and mods.alt and not mods.cmd then
      -- Opt+цифра на US-раскладке даёт символ: ¡ ™ £ ¢ ∞ §
      local OPTD = { [161] = 1, [8482] = 2, [163] = 3, [162] = 4, [8734] = 5, [167] = 6 }
      local cp = (c >= 0x75000000 and c < 0x76000000) and (c - 0x75000000) or c
      local k = (cp >= 49 and cp <= 54) and (cp - 48) or OPTD[cp]
      if k then
        ctx.env_shape(env, V.cur.row, k - 1)
        V.msg = 'segment shape: ' .. ({ 'lin', 'sqr', 'slo', 'fas', 'fae', 'bez' })[k]
        V.count = nil; return
      end
    end
  end
  -- Shift+hjkl (5 окт): выделение, как Shift+стрелки — не в VISUAL войти с
  -- якорем на курсоре и шагнуть; из INSERT после операции — обратно в INSERT.
  -- s в INSERT — то же выделение без шага; Option+s (ß) — шаг (:step)
  do
    local chs = (c < 256) and string.char(c) or ''
    local mods = ctx.mods and ctx.mods() or {}
    local SH = { H = 'h', J = 'j', K = 'k', L = 'l' }
    local inmode = V.mode == 'normal' or V.mode == 'insert' or V.mode == 'visual' or V.mode == 'vline'
    if inmode and not V.pending and not V.op and not V.hexbuf and not V.shapebuf then
      if c == 223 or (chs == 's' and mods.alt) then
        V.cmd_from = V.mode == 'insert' and 'insert' or 'normal'; V.mode = 'cmd'; V.cmdline = 'step '; return
      end
      -- Shift+стрелки = Shift+hjkl (6 окт)
      local sha = mods.shift and ({ [LEFT] = 'h', [DOWN] = 'j', [UP] = 'k', [RIGHT] = 'l' })[c]
      if sha then chs = sha:upper() end
      if SH[chs] or (chs == 's' and V.mode == 'insert') then
        if V.mode ~= 'visual' and V.mode ~= 'vline' then
          if V.mode == 'insert' then V.back_insert = true end
          V.mode = 'visual'; V.anchor = { fi = V.cur.fi, row = V.cur.row }
        end
        if SH[chs] then
          local m = motion(SH[chs]:byte(), V.count or 1)
          if m then V.cur.fi, V.cur.row = m.fi, m.row; if m.field then V.cur.field = m.field; V.cur.sub = m.sub end; clamp_cur(); ensure_visible() end
        end
        V.count = nil; return
      end
    end
  end
  -- лидер \ — hydra действий (контекстное меню с клавиатуры), ? — шпаргалка
  if c == ('\\'):byte() and not (V.mode == 'insert' and (env_of(V.cur.fi) or (V.cur.field or 1) == 2)) then
    if ctx.main_menu then ctx.main_menu() else V.open_hydra(ctx.hydra_root()) end; return   -- 6 окт: \ — главное меню, \\ — контекст
  end

  record(c)

  -- 11 окт: колонка cmd мастера (маркеры проекта): Enter — текст команды в строке :,
  -- ! — действие REAPER (маркер «!id» REAPER исполняет сам), BS / Del (и x в NORMAL) — удалить
  do
    local cf = flat()[V.cur.fi]
    if cf and cf.ml and cf.ml.kind == 'cmd' and (V.mode == 'normal' or V.mode == 'insert') then
      local e = cf.ml.ev[V.cur.row]
      if c == 13 then V.cmd_from = V.mode; V.mode = 'cmd'; V.cmdline = 'mcmd ' .. (e and e.text or ''); return end
      if c == ('!'):byte() then V.cmd_from = V.mode; V.mode = 'cmd'; V.cmdline = 'mcmd !'; return end
      if c == BS or c == DEL or (V.mode == 'normal' and c == ('x'):byte()) then
        if ctx.mcmd_set then ctx.mcmd_set(V.cur.row, '') end; return
      end
    end
  end

  -- INSERT
  if V.mode == 'insert' then
    if c == ESC then
      if V.shapebuf then V.shapebuf = nil; return end
      if V.hexbuf then V.hexbuf = nil; return end
      V.mode = 'normal'; finish_edit(); return
    end
    local chk = (c < 256) and string.char(c) or ''
    if chk == ':' then V.cmd_from = 'insert'; V.mode = 'cmd'; V.cmdline = ''; V.hexbuf = nil; return end
    if chk == '/' and (V.cur.field or 1) == 1 and not env_of(V.cur.fi) then V.cmd_from = 'insert'; V.mode = 'search'; V.searchline = ''; V.hexbuf = nil; return end
    if chk == '?' then V.open_hydra(ctx.hydra_keys()); return end
    -- m — клавиатура вкл / выкл и в INSERT (5 окт): выключена — ноты не пишутся
    if chk == 'm' and not V.hexbuf and not V.shapebuf then
      if ctx.toggle_piano then ctx.toggle_piano() else V.piano = not V.piano end
      return
    end
    local m = motion(c, 1)
    if m and (c == UP or c == DOWN or c == LEFT or c == RIGHT or c == PGUP or c == PGDN or c == HOME or c == END) then
      V.cur.fi, V.cur.row = m.fi, m.row
      if m.field then V.cur.field = m.field; V.cur.sub = m.sub end
      V.hexbuf = nil; clamp_cur(); ensure_visible(); return
    end
    if c == 32 then E.play_stop(); return end
    local fld = V.cur.field or 1
    -- MIDI-лейн (6 окт): две hex-цифры — CC / PC в строку (в MIDI item под ней),
    -- BS / Del — события лейна в строке долой; остальное — управление KEYS
    local mlf = flat()[V.cur.fi]
    if mlf and mlf.ml then
      local ml = mlf.ml
      local hx = (c < 256) and string.char(c):upper() or ''
      if c == BS or c == DEL then ctx.ml_del(mlf, V.cur.row); V.hexbuf = nil; return end
      if ml.kind == 'cc' or ml.kind == 'pc' then
        local v, raw = num_key(c)
        if v == 'wait' then return end
        if v then
          ctx.ml_set(mlf, V.cur.row, math.min(127, raw))
          V.cur.row = V.cur.row + step_rows(); ensure_visible(); return
        end
      end
      V.hexbuf = nil                                 -- 11 окт: недобранное число не держит клавиши
      keys_control(c); return
    end
    local env = env_of(V.cur.fi)
    if (c == 62 or c == 60) and fld == 1 and not env then ctx.loop(c == 62 and 'item' or 'region'); return end
    -- 11 окт: огибающая в INSERT — как Vim: цифры — значение, остальное — команды NORMAL
    -- (dd x yy p w } счётчики …), после них снова INSERT; форма точки — Ctrl+Opt+1..6 / Ctrl+Enter
    local function env_normal(c2)
      V.mode = 'normal'
      local r = V.key_impl(c2)
      if V.mode == 'normal' then
        if V.pending or V.op then V.back_insert = true else V.mode = 'insert' end
      end
      return r
    end
    if env and fld == 2 and nfields() >= 2 then
      V.shapebuf = nil
      if c == ESC then return env_normal(c) end
      return env_normal(c)
    end
    if env then
      -- колонка огибающей: две hex-цифры — точка; BS — удалить; / и \ —
      -- текстовые макросы: пандус к max / min за 1 бит (этап 10)
      local ch = (c < 256) and string.char(c):upper() or ''
      if c == BS or c == DEL then ctx.env_del(env, V.cur.row); V.hexbuf = nil; return end
      if ch == '/' or ch == '\\' then
        ctx.env_ramp(env, V.cur.row, V.cur.row + lpb(), nil, ch == '/' and 1 or 0)
        V.cur.row = V.cur.row + lpb(); ensure_visible(); V.hexbuf = nil; return
      end
      local v = num_key(c)
      if v == 'wait' then return end
      if v then
        ctx.env_set(env, V.cur.row, v)
        V.cur.row = V.cur.row + step_rows(); ensure_visible(); return
      end
      -- + / - — шаг значения точки строки; остальное — команды NORMAL (11 окт)
      V.hexbuf = nil
      local lk = (c < 256) and string.char(c) or ''
      local hexm = (ctx.envfmt and ctx.envfmt() or 'midi') == 'hex'
      if lk == '+' or lk == '=' or lk == '-' then
        ctx.env_nudge(env, V.cur.row, (lk == '-' and -1 or 1) / (hexm and 255 or 127)); return
      end
      return env_normal(c)
    end
    if fld == 2 and (c == ('/'):byte() or c == ('\\'):byte()) then
      -- vol аудио-события: / фейд-ин, \ фейд-аут за 1 бит (команды Ixx/Oxx, xx = 1/16 строки)
      local heads = V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row)
      local xx = math.min(255, lpb() * 16)
      for _, h in ipairs(heads) do if h.kind == 'audio' then E.set_fx({ h }, lpb(), c == ('/'):byte() and 'I' or 'O', xx) end end
      V.hexbuf = nil; return
    end
    if c == BS or c == DEL then
      local heads = V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row)
      if fld == 1 then E.delete(heads, lpb())
      elseif fld == 2 then E.set_vol(heads, lpb(), 128)
      elseif fld == 3 then E.set_delay(heads, lpb(), 0)
      else
        for _, h in ipairs(heads) do
          local f = (h.fx or {})[fld - 3]
          if f then E.clear_fx({ h }, lpb(), f:sub(1, 1)) end
        end
      end
      V.hexbuf = nil; return
    end
    if V.cur.sub == 'slc' and fld == 1 then
      -- 11 окт: поле слайса — две hex-цифры, номер слайса ноты (00 — весь сэмпл)
      local ch2 = (c < 256) and string.char(c):upper() or ''
      if ch2:match('^[0-9A-F]$') then
        local buf = (V.hexbuf or '') .. ch2
        if #buf < 2 then V.hexbuf = buf; return end
        V.hexbuf = nil
        if ctx.set_slice then ctx.set_slice(V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row), tonumber(buf, 16)) end
        V.cur.row = V.cur.row + step_rows(); ensure_visible(); return
      end
      V.hexbuf = nil
      keys_control(c); return
    end
    if V.cur.sub == 'inst' and fld == 1 then
      -- поле инструмента (5 окт): номер инструмента ноты. 11 окт: десятичный, как его
      -- пишут ячейка и lib (01 02 … 09 10); первая цифра ставит сразу (2 → 02),
      -- вторая дописывает (1 2 → 12) и шагает вниз; номер — как в lib, не индекс pool
      local ch2 = (c < 256) and string.char(c) or ''
      if ch2:match('^[0-9]$') then
        local buf = (V.hexbuf or '') .. ch2
        local f = flat()[V.cur.fi]
        local idx = ctx.inst_from_num and ctx.inst_from_num(f and f.col, tonumber(buf))
        local heads = V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row)
        if #buf < 2 then
          V.hexbuf = buf
          if idx and ctx.set_inst then ctx.set_inst(heads, idx) end
          return
        end
        V.hexbuf = nil
        if idx and ctx.set_inst then ctx.set_inst(heads, idx)
        elseif not idx then V.msg = ('no instrument %s on this track'):format(buf) end
        V.cur.row = V.cur.row + step_rows(); ensure_visible(); return
      end
      V.hexbuf = nil                                   -- другая клавиша — набор окончен, клавиша работает
      keys_control(c); return
    end
    -- 11 окт: клавиатура выключена — INSERT для правки значений: нот нет, hex пишет
    -- поля, все остальные клавиши — команды NORMAL (вся клавиатура, все буквы), после
    -- них — снова INSERT (оператор d… дождётся движения и тоже вернёт)
    local function as_normal(c2)
      V.mode = 'normal'
      local r = V.key_impl(c2)
      if V.mode == 'normal' then
        if V.pending or V.op then V.back_insert = true else V.mode = 'insert' end
      end
      return r
    end
    if fld > 1 then
      -- поля vol / delay / команд: hex-ввод, потом шаг вниз; не-hex → управление KEYS
      local heads = V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row)
      local b0 = V.hexbuf
      local he = hex_entry(c, fld, heads)
      if he == 'none' then return end
      if he then V.cur.row = V.cur.row + step_rows(); ensure_visible(); return end
      if V.hexbuf and V.hexbuf ~= b0 then return end   -- набор продолжается
      V.hexbuf = nil                                   -- 11 окт: чужая клавиша обрывает набор и работает
      if not V.piano then return as_normal(c) end
      keys_control(c); return
    end
    if not V.piano then return as_normal(c) end      -- поле ноты без клавиатуры: ноты не пишутся
    if keys_control(c) then return end
    -- note-off (9 окт): ` — подколонка курсора, ~ — весь трек, Ctrl+` — все треки
    if c == ('`'):byte() or c == ('~'):byte() then
      local mods2 = ctx.mods and ctx.mods() or {}
      local scope = mods2.ctrl and 'all' or (c == ('~'):byte() and 'track' or 'sub')
      V.note_off_scope(scope)
      V.cur.row = V.cur.row + step_rows(); ensure_visible(); return
    end
    if c == ('['):byte() then V.octave = math.max(0, V.octave - 1); return end
    if c == (']'):byte() then V.octave = math.min(8, V.octave + 1); return end
    -- нотные клавиши пишут только при включённой клавиатуре (11 окт; 10 окт писали всегда)
    -- модификатор ноты (2 окт): Shift — только прослушать, Option — вставить
    -- рядом (новая подколонка), Ctrl — захват звука канала (F5, пока прослушка)
    local how, mods = 'insert', (ctx.mods and ctx.mods() or {})
    c, how = V.note_key(c, mods)
    -- нарезанный инструмент (4 окт, как Renoise): обычная MIDI-клавиатура
    -- q 2 w 3 e r 5 t …, слайс = нота: C-4 = 1, C#4 = 2 …; z / x — по 12.
    -- Option + клавиша — последний слайс с питчем этой ноты (q = исходный)
    local f0 = flat()[V.cur.fi]
    local inst0 = f0 and (f0.col.pool or {})[V.inst]
    if f0 and ctx.inst_fx and ctx.inst_fx(f0.col) then inst0 = nil end   -- 9 окт: плагин-инструмент — не слайсы
    local chq = (c < 256) and string.char(c) or ''
    local kp = piano_pitch(c)
    -- automation как инструмент (5 окт): клавиша — выбранный пул со скоростью по высоте
    if kp and ctx.auto_on and ctx.auto_on() and how ~= 'audition' then
      if ctx.ai_insert(kp, V.cur.row) then V.cur.row = V.cur.row + step_rows(); ensure_visible() end
      return
    end
    if kp and ctx.midi_on and ctx.midi_on() and how ~= 'audition' then   -- MIDI-клип трека / проекта (10 окт)
      if ctx.mc_insert(kp, V.cur.row) then V.cur.row = V.cur.row + step_rows(); ensure_visible() end
      return
    end
    local SB = V.slice_base()
    local sliced = inst0 and inst0.slices and #inst0.slices > 0 and kp
    local semis = 0
    -- 4 окт: Option — питч выбранного (слайс или весь айтем), Cmd — питч всего айтема
    if how == 'whole' then sliced = false; how = 'insert' end
    if sliced and how == 'beside' then
      local selk = (ctx.selected_slice and ctx.selected_slice(inst0)) or V.last_slice or 1
      if selk == 0 then sliced = false; how = 'insert'
      else semis = kp - (SB - 1); kp = SB + selk - 1; how = 'insert' end
    end
    if sliced and kp - SB + 1 == 0 then sliced = false end          -- q: весь сэмпл — обычный путь ноты
    if sliced then
      local k = kp - SB + 1
      -- режим слайса (10 окт): random / sequence — слайс выбирает режим, клавиша лишь бьёт
      if ctx.slice_pick and (how == 'insert' or how == 'beside') and not V.arp_live then k = ctx.slice_pick(#inst0.slices, k) end
      if k < 1 or k > #inst0.slices then V.msg = ('no slice %d (the sample has %d) - z / x shift by an octave'):format(k, #inst0.slices); return end
      V.last_slice = k
      if ctx.select_slice then ctx.select_slice(inst0, k) end
      -- живой арп из слайсов (4 окт): держатся клавиши-слайсы — чередуются по шагу
      if V.arp_live and how == 'insert' and ctx.arp_live_key then
        local lane = f0.lane or f0.col.lanes[1]
        ctx.arp_live_key({ track = f0.col.track, lane_idx = f0.col.fixed and lane.idx or nil, row = V.cur.row, pitch = SB + k - 1,
          slice = k, entry = inst0, item = inst0.item, vel = V.vel, key = chq })
        return
      end
      local t0s = inst0.slices[k]
      if how == 'hold' or how == 'hold_stretch' then
        local lane = f0.lane or f0.col.lanes[1]
        if ctx.hold_start then ctx.hold_start({ track = f0.col.track, lane_idx = f0.col.fixed and lane.idx or nil, row = V.cur.row, slice = k,
          item = inst0.item, entry = inst0, vel = V.vel, stretch = how == 'hold_stretch', key = chq, replace = f0.sub and f0.sub[V.cur.row] }) end
        return
      end
      if how == 'audition' or how == 'capture' then
        if t0s and ctx.preview_slice then ctx.preview_slice(f0.col.track, inst0, t0s, (not inst0.playthru and inst0.slices[k + 1]) or inst0.len, semis) end
        if how == 'capture' then V.msg = 'Ctrl+note: capture of the channel output is planned (F5) - auditioned only' end
        return
      end
      local lane = f0.lane or f0.col.lanes[1]
      E.beside = how == 'beside'
      -- шаг auto (3 окт): следующий слайс — ровно в конец предыдущего (строка +
      -- задержка xx/256), амен сшивается без щелей; курсор там, где кончился слайс
      local sx = V.stitch
      local tx = (V.step_auto and sx and sx.fi == V.cur.fi and sx.row == V.cur.row) and sx.t or nil
      -- слайс поверх события в строке — ПЕРЕЗАПИСЬ, как нота (3 окт: второй q
      -- ставил новый лейн); Option — рядом; на стыке хвост предыдущего не режем
      if how ~= 'beside' then
        local cell = f0.sub and f0.sub[V.cur.row]
        if cell and cell.kind == 'cont' and cell.of and not tx then E.note_off({ cell.of }, lpb(), V.cur.row)
        elseif cell and (cell.kind == 'audio' or cell.kind == 'midi') then E.delete({ cell }, lpb()) end
      end
      if how ~= 'beside' then E.cap_row, E.cap_lpb = V.next_event_row(f0.sub, V.cur.row), lpb() end
      local okI, it = pcall(E.insert_slice, f0.col.track, f0.col.fixed and lane.idx or nil, lpb(), V.cur.row, inst0.item, k, tx)
      E.cap_row = nil
      if not okI then error(it, 0) end
      if it and semis ~= 0 and E.slice_pitch then E.slice_pitch(it, semis) end
      E.beside = false
      if st.preview and ctx.preview_slice and t0s then ctx.preview_slice(f0.col.track, inst0, t0s, (not inst0.playthru and inst0.slices[k + 1]) or inst0.len, semis) end
      if V.step_auto and it and E.item_end and E.row_of_time then
        local t_end = E.item_end(it)
        local r = math.max(V.cur.row + 1, (E.row_of_time(t_end, lpb())))   -- слайс короче строки — всё равно шаг
        local q = ctx.slq_rows and ctx.slq_rows() or 0
        if q > 0 then
          -- 11 окт: старт по сетке — ближайшая клетка q строк после конца слайса (не раньше следующей строки)
          local r0, d0 = E.row_of_time(t_end, lpb())
          r = V.slq_snap(r0 + d0 / 256, q, V.cur.row)
          V.stitch = nil
        else V.stitch = { fi = V.cur.fi, row = r, t = t_end } end
        V.cur.row = r
      else
        V.stitch = nil
        V.cur.row = V.cur.row + adv_rows(inst0, k)
      end
      ensure_visible(); return
    end
    local pitch = piano_pitch(c)
    if pitch then
      local f = flat()[V.cur.fi]
      if f then
        local lane = f.lane or f.col.lanes[1]
        local inst = (f.col.pool or {})[V.inst]
        if ctx.inst_fx and ctx.inst_fx(f.col) then inst = nil end   -- 9 окт: плагин-инструмент — MIDI
        -- живой арпеджиатор (3 окт, :arp live): нота — в держимый аккорд
        if V.arp_live and how == 'insert' and ctx.arp_live_key then
          ctx.arp_live_key({ track = f.col.track, lane_idx = f.col.fixed and lane.idx or nil, row = V.cur.row, pitch = pitch,
            item = inst and inst.item, vel = V.vel, key = (c < 256) and string.char(c) or '' })
          return
        end
        if how == 'hold' or how == 'hold_stretch' then
          local chh = (c < 256) and string.char(c) or ''
          if ctx.hold_start then ctx.hold_start({ track = f.col.track, lane_idx = f.col.fixed and lane.idx or nil, row = V.cur.row, pitch = pitch,
            item = inst and inst.item, vel = V.vel, stretch = how == 'hold_stretch', key = chh, replace = f.sub and f.sub[V.cur.row] }) end
          return
        end
        -- Shift+нота — только звук; Ctrl+нота — захват (F5, пока звук)
        if how == 'audition' or how == 'capture' then
          if ctx.preview then ctx.preview(f.col.track, pitch, (ctx.inst_src and ctx.inst_src(f.col, inst) or (inst and inst.item)), V.cur.row, V.step_auto and 1 or V.step) end
          if how == 'capture' then V.msg = 'Ctrl+note: capture of the channel output is planned (F5) - auditioned only' end
          return
        end
        -- 9 окт: режим вставки инструмента (меню блока step / inst, правая кнопка):
        -- random — случайный из lib, sequence — следующий по кругу
        if ctx.ins_next and not (ctx.inst_fx and ctx.inst_fx(f.col)) then
          local ni = ctx.ins_next(f.col)
          if ni then inst = (f.col.pool or {})[ni] end
        end
        -- 9 окт: Option+нота — аккорд вводом: нота в следующую подколонку,
        -- курсор туда, длина аккорда — по времени ввода (ctx.chord_note)
        if how == 'beside' and ctx.chord_note then
          ctx.chord_note(f, lane, pitch, inst)
          return
        end
        -- нота поверх события: ПЕРЕЗАПИСЬ (старое удаляется), Option+нота —
        -- рядом, в новой подколонке, даже та же нота (решение пользователя 2 окт)
        local beside = how == 'beside'
        E.beside = beside
        if not beside then
          local cell = f.sub and f.sub[V.cur.row]
          if cell and cell.kind == 'cont' and cell.of then
            -- продолжение события: обрезать его в этой строке (как note-off),
            -- новая нота — в ту же подколонку
            E.note_off({ cell.of }, lpb(), V.cur.row)
          elseif cell and (cell.kind == 'audio' or cell.kind == 'midi') then
            E.delete({ cell }, lpb())       -- строка с названием — перезапись
          end
        end
        local stp = V.step_auto and 1 or V.step
        if not beside then E.cap_row, E.cap_lpb = V.next_event_row(f.sub, V.cur.row), lpb() end
        local okN, errN = pcall(E.insert_note,f.col.track, f.col.fixed and lane.idx or nil, lpb(), V.cur.row, pitch, (ctx.ins_vel and ctx.ins_vel(V.vel) or V.vel), stp, (ctx.inst_src and ctx.inst_src(f.col, inst) or (inst and inst.item)))
        E.cap_row = nil
        if not okN then E.beside = false; error(errN, 0) end
        E.beside = false
        if st.preview and ctx.preview then ctx.preview(f.col.track, pitch, (ctx.inst_src and ctx.inst_src(f.col, inst) or (inst and inst.item)), V.cur.row, stp) end
        V.cur.row = V.cur.row + adv_rows(inst); ensure_visible()
      end
    end
    return
  end

  -- клавиатура (5 окт, по просьбе): m — вкл / выкл (видна снизу = работает).
  -- Включена — у неё приоритет в NORMAL и VISUAL: верхний ряд и цифры —
  -- ноты (звучат; Cmd+нота — с удержанием), z / x — октава, Esc / Enter —
  -- INSERT (i здесь — нота). Выключена — чистый Vim.
  if (V.mode == 'normal' or V.mode == 'visual' or V.mode == 'vline') and not V.pending and not V.op then
    if c == ('m'):byte() then                          -- 9 окт: m — клавиатура снова (микшер — zm)
      if ctx.toggle_piano then ctx.toggle_piano() else V.piano = not V.piano end
      return
    end
    if V.piano then
      if V.mode == 'normal' and (c == 13 or (c == ESC and not (ctx.esc_vim and ctx.esc_vim()))) then V.mode = 'insert';   -- Esc mode vim: вход только Enter / i
      V.msg = (ctx.hints_on and ctx.hints_on()) and 'INSERT with the keyboard: the top row writes notes' or ''; return end   -- описание — только с хинтами (5 окт)
      if c == ('z'):byte() then V.octave = math.max(0, V.octave - 1); V.msg = 'octave ' .. V.octave; return end
      if c == ('x'):byte() then V.octave = math.min(8, V.octave + 1); V.msg = 'octave ' .. V.octave; return end
      local mods = ctx.mods and ctx.mods() or {}
      local base, how = V.note_key(c, mods)
      if ctx.piano and ctx.piano[base] then
        local f0 = flat()[V.cur.fi]
        local inst0 = f0 and (f0.col.pool or {})[V.inst]
        if f0 and ctx.inst_fx and ctx.inst_fx(f0.col) then inst0 = nil end   -- 9 окт: плагин-инструмент — не слайсы
        local chq = (base < 256) and string.char(base) or ''
        V.piano_last = ctx.piano[base]                         -- пианинка: последняя сыгранная клавиша
        -- нарезанный: нота — слайс по клавише; Option — выбранный с питчем; Cmd — весь
        local kp0 = piano_pitch(base)
        local SB0 = V.slice_base()
        local sliced0 = inst0 and inst0.slices and #inst0.slices > 0 and kp0
        local psemis, k = 0, nil
        if sliced0 and how ~= 'whole' then
          if how == 'beside' then
            local selk = (ctx.selected_slice and ctx.selected_slice(inst0)) or V.last_slice or 1
            if selk > 0 then k = selk; psemis = kp0 - (SB0 - 1) end
          else k = kp0 - SB0 + 1; if k == 0 then k = nil end end             -- q: весь сэмпл
        end
        if k and (k < 1 or k > #inst0.slices) then V.msg = ('no slice %d'):format(k); return end
        if k then V.last_slice = k; if how ~= 'beside' and ctx.select_slice then ctx.select_slice(inst0, k) end end
        local pitch = (not k) and piano_pitch(base) or nil
        if f0 and (k or pitch) then
          local lane = f0.lane or f0.col.lanes[1]
          if how == 'hold' or how == 'hold_stretch' then
            if ctx.hold_start then ctx.hold_start({ track = f0.col.track, lane_idx = f0.col.fixed and lane.idx or nil, row = V.cur.row, pitch = pitch, slice = k,
              item = inst0 and inst0.item, entry = inst0, vel = V.vel, stretch = how == 'hold_stretch', key = chq }) end
          elseif k then
            if ctx.preview_slice then ctx.preview_slice(f0.col.track, inst0, inst0.slices[k], (not inst0.playthru and inst0.slices[k + 1]) or inst0.len, psemis) end
          elseif ctx.preview then ctx.preview(f0.col.track, pitch, inst0 and inst0.item, V.cur.row, 1) end
        end
        return
      end
    end
  end

  -- ожидание второй клавиши
  local p = V.pending
  if p then
    V.pending = nil
    if c == ESC then V.count = nil; finish_move(); return end
    if p == 'g' then
      -- 10 окт: g + цифры + Enter (или g) — на строку с этим номером (g12 ↵ → 0012); Esc — отмена
      if c >= 48 and c <= 57 and not V.op then
        V.gnum = (V.gnum or '') .. string.char(c); V.pending = 'g'
        V.msg = 'g' .. V.gnum .. ' - Enter: go to row ' .. ('%04d'):format(tonumber(V.gnum)); return
      end
      if V.gnum and (c == 13 or c == ('g'):byte()) and not V.op then
        local r = tonumber(V.gnum) or 0; V.gnum = nil
        if r ~= V.cur.row and ctx.jump_mark then ctx.jump_mark() end
        V.cur.row = math.max(0, r); V.count = nil; finish_move(); ensure_visible(); return
      end
      V.gnum = nil
      if c == ('g'):byte() then
        -- 10 окт: Ngg — строка N, как её подпись (0012 = 12gg); было N−1, как строки Vim с 1
        local t = { fi = V.cur.fi, row = V.count and n or 0, linewise = true }
        if V.op then
          local f0, f1, r0, r1 = range_or_event(V.op, t)
          local e = apply(V.op, f0, f1, r0, r1); V.op = nil; if e then finish_edit() else finish_move() end
        else
          if t.row ~= V.cur.row and ctx.jump_mark then ctx.jump_mark() end   -- 9 окт: gg — в список прыжков
          V.cur.row = t.row; finish_move()
        end
        V.count = nil; ensure_visible(); return
      end
      if c == ('s'):byte() and not V.op then
        -- gs (9 окт): смарт-панель — сетка значений поля курсора (мышью / h j k l + Enter)
        V.count = nil; finish_move(); V.smart(); return
      end
      if c == ('w'):byte() then
        -- gw (4 окт): событие под курсором меняется местами с N-м вперёд в
        -- этой колонке (3gw — с третьим)
        local k = V.count or 1
        V.count = nil
        if V.swap_forward(k) then finish_edit() else finish_move() end
        return
      end
      V.count = nil; finish_move(); return
    elseif p == 'z' then
      local L = ctx.layout()
      -- 10 окт: фокус не в трекере (lib, browser, fx list, macros …) — zz = модуль на всё окно (zoom)
      -- 10 окт: zz везде — модуль в фокусе на всё окно (и трекер; центровка строки Vim заменена)
      if c == ('z'):byte() and ctx.zz_zoom and ctx.zz_zoom() then
      elseif c == ('z'):byte() then st.row0 = math.max(0, V.cur.row - math.floor(L.nrows / 2))
      elseif c == ('s'):byte() then if ctx.clips_toggle then ctx.clips_toggle() end   -- zs: клипы сессии в теле трекера (6 окт)
      elseif c == ('r'):byte() then if ctx.dsp_big then ctx.dsp_big() end            -- zr: роутер на месте трекера (7 окт)
      elseif c == ('R'):byte() then if ctx.router_big then ctx.router_big() end      -- zR: большой роутер на всё окно (7 окт)
      elseif c == ('t'):byte() then V.transpose_smart()          -- 10 окт: zt — транспозиция (было прокрутка курсора наверх)
      elseif c == ('b'):byte() then st.row0 = math.max(0, V.cur.row - L.nrows + 1)
      elseif c == ('a'):byte() or c == ('c'):byte() or c == ('o'):byte() then
        local f = flat()[V.cur.fi]
        if f then
          local v = (c == ('a'):byte()) and (not (f.folded or f.compact)) or (c == ('c'):byte())
          ctx.fold(f.col, v); ctx.relayout()
          -- курсор остаётся на том же треке; поле — в пределах новой подколонки
          for i, g in ipairs(flat()) do if g.col == f.col then V.cur.fi = i; break end end
          clamp_cur()
        end
      elseif c == ('f'):byte() then
        local f = flat()[V.cur.fi]
        if f and ctx.fold_folder then ctx.fold_folder(f.col); ctx.relayout() end
      elseif c == ('C'):byte() then
        -- zC — прежний fold: трек в полоску шириной в символ
        local f = flat()[V.cur.fi]
        if f then ctx.fold(f.col, 'mini'); ctx.relayout(); for i, g in ipairs(flat()) do if g.col == f.col then V.cur.fi = i; break end end; clamp_cur() end
      elseif c == ('m'):byte() then if ctx.toggle_mixer then ctx.toggle_mixer() end   -- 9 окт: zm — микшер вкл / выкл
      elseif c == ('B'):byte() then if ctx.audio_bs_menu then ctx.audio_bs_menu() end   -- 10 окт: zB — буфер аудиоустройства
      -- 9 окт: ширина по шагу, как Cmd+колесо: z> z< — все треки, z. z, — трек курсора (счётчик: 3z>)
      elseif (c == ('>'):byte() or c == ('<'):byte() or c == ('.'):byte() or c == (','):byte()) and ctx.width_step then
        local d = (c == ('>'):byte() or c == ('.'):byte()) and 1 or -1
        local f = flat()[V.cur.fi]
        local col = f and f.col
        for _ = 1, n do ctx.width_step(d, (c == ('.'):byte() or c == (','):byte()) and 'cur' or nil) end
        if col then for i, g in ipairs(flat()) do if g.col == col then V.cur.fi = i; break end end end
        clamp_cur()
      elseif c == ('M'):byte() then   -- zM (7 окт): свернуть все ↔ развернуть все (zR теперь большой роутер; :unfold — тоже)
        local any = false
        for _, g in ipairs(flat()) do if g.folded or g.compact then any = true; break end end
        ctx.fold_all(not any); ctx.relayout(); clamp_cur()
      end
      V.count = nil; finish_move(); return
    elseif p == 'r' then
      local fld = V.cur.field or 1
      if fld > 1 then
        local f0, f1, r0, r1 = V.cur.fi, V.cur.fi, V.cur.row, V.cur.row
        if V.mode == 'visual' or V.mode == 'vline' then f0, f1, r0, r1 = V.visual_range() end
        if hex_entry(c, fld, V.heads_in(f0, f1, r0, r1)) then V.mode = 'normal'; finish_edit()
        elseif V.hexbuf then V.pending = 'r'
        else finish_move() end
        V.count = nil; return
      end
      -- r + нота (4 окт): по тем же правилам, что ввод — на ноте-слайсе
      -- клавиша выбирает слайс, Option+клавиша — его питч; иначе — питч
      local rbase, rhow = V.note_key(c, ctx.mods and ctx.mods() or {})
      local pitch = piano_pitch(rbase)
      if pitch then
        local f0, f1, r0, r1 = V.cur.fi, V.cur.fi, V.cur.row, V.cur.row
        if V.mode == 'visual' or V.mode == 'vline' then f0, f1, r0, r1 = V.visual_range() end
        local heads = V.heads_in(f0, f1, r0, r1)
        local slc, rest = {}, {}
        for _, h in ipairs(heads) do if h.kind == 'audio' and (h.fx or {})[1] and tostring(h.fx[1]):match('^S%x%x$') then slc[#slc + 1] = h else rest[#rest + 1] = h end end
        if #slc > 0 and rhow ~= 'whole' then
          if rhow == 'beside' then E.run('slice pitch', function() for _, h in ipairs(slc) do if E.slice_pitch then E.slice_pitch(h.item, pitch - V.slice_base()) end end end)
          elseif pitch - V.slice_base() + 1 < 1 then V.msg = 'q is the whole sample - a slice note keeps its slice (; inserts the whole sample)'
          else E.set_fx(slc, lpb(), 'S', pitch - V.slice_base() + 1) end
        else for _, h in ipairs(slc) do rest[#rest + 1] = h end end
        if #rest > 0 then E.set_pitch(rest, lpb(), pitch) end
        V.mode = 'normal'; finish_edit()
      else finish_move() end
      V.count = nil; return
    elseif p == "'" then
      -- harpoon (9 окт): 'a добавить место, '1..'9 — к месту, '' — список, 'd — убрать
      if ctx.harpoon then ctx.harpoon((c < 256) and string.char(c) or '') end
      V.count = nil; finish_move(); return
    elseif p == 'q' then
      if c >= ('a'):byte() and c <= ('z'):byte() then V.macro = { name = string.char(c), keys = {} }; V.msg = 'recording @' .. string.char(c) end
      V.count = nil; finish_move(); return
    elseif p == '@' then
      local name = (c == ('@'):byte()) and V.last_macro or string.char(c)
      local keys = name and V.regs['@' .. name]
      if keys then V.last_macro = name; V.cmdbuf = {}; for _ = 1, n do replay(keys) end end
      V.count = nil; return
    elseif p == 'T' then
      -- 11 окт: T f — take FX ноте под курсором (fzf), T o — её цепь в DSP
      local ch = string.char(c < 256 and c or 0)
      if ch == 'f' and ctx.dsp_take_slice then ctx.dsp_take_slice()
      elseif ch == 'o' and ctx.take_fx_open then ctx.take_fx_open() end
      finish_move(); V.count = nil; return
    elseif p == 't' then
      if c == ('t'):byte() and ctx.new_track and ctx.new_track(n) then finish_edit()
      -- 10 окт: td / tx / tp — удалить / вырезать / вставить N треков (5td — пять)
      elseif (c == ('d'):byte() or c == ('x'):byte() or c == ('p'):byte()) and ctx.tracks_op and ctx.tracks_op(c == ('d'):byte() and 'delete' or (c == ('x'):byte() and 'cut' or 'paste'), n) then finish_edit()
      elseif (c == ('s'):byte() or c == ('r'):byte()) and ctx.bus_track and ctx.bus_track(c == ('s'):byte() and 'send' or 'recv') then finish_edit()   -- ts / tr
      -- 9 окт: всё про трек — под t, мнемонично (which-key 't')
      elseif c == ('y'):byte() and ctx.track_dup and ctx.track_dup() then finish_edit()
      elseif (c == ('j'):byte() or c == ('k'):byte()) and ctx.track_move and ctx.track_move(c == ('j'):byte() and 1 or -1, n) then finish_edit()
      else
        local ch = string.char(c < 256 and c or 0)
        local col = ctx.cur_col and ctx.cur_col()
        if ch == 'n' and ctx.rename_track_prompt then ctx.rename_track_prompt(); V.count = nil; return   -- режим cmd уже включён
        elseif ch == 'c' and ctx.track_colour then ctx.track_colour()
        elseif ch == 'a' and ctx.rec_arm then ctx.rec_arm()
        elseif ch == 'i' and ctx.input_picker and col then ctx.input_picker(col)
        elseif ch == 'I' and ctx.smart_input and col then ctx.smart_input(col)   -- 10 окт: tI — активный вход (jf_smart_set_input)
        elseif ch == 'l' and ctx.toggle_lanes then ctx.toggle_lanes()
        elseif ch == 'f' and ctx.fx_picker then ctx.fx_picker()
        elseif ch == 'R' and ctx.route_menu and col then ctx.route_menu(col)
        elseif ch == 'T' and ctx.template_picker then ctx.template_picker() end   -- 11 окт: tT — шаблоны треков (fzf)
        finish_move()
      end
      V.count = nil; return
    elseif p == 'da' then
      -- daw (4 окт): все item трека курсора в песне (библиотека за =LIB остаётся)
      if c == ('w'):byte() and ctx.clear_track(true) then finish_edit() else finish_move() end
      V.count = nil; return
    elseif p == 'd' or p == 'y' or p == 'c' then
      -- 10 окт: dd — строки (5dd — пять, как в Vim); трек удаляет td (было dd с 4 окт)
      if c == p:byte() then      -- dd yy cc: n строк
        local f0, f1, r0, r1 = V.cur.fi, V.cur.fi, V.cur.row, V.cur.row + n - 1
        local e = apply(p, f0, f1, r0, r1); V.count = nil
        if e then finish_edit() else finish_move() end
        return
      end
      if c >= ('0'):byte() and c <= ('9'):byte() and not (c == ('0'):byte() and not V.count) then
        V.count = (V.count or 0) * 10 + (c - 48); V.pending = p; return
      end
      if c == ('g'):byte() then V.op = p; V.pending = 'g'; return end
      -- dW — весь item под курсором (не только нота MIDI); dt — весь трек
      -- курсора в регионе (вне региона — до =END). Просьба 2 окт.
      if p == 'd' and c == ('W'):byte() then
        if ctx.delete_item_at_cursor() then finish_edit() else finish_move() end
        V.count = nil; return
      end
      -- dt — вырезать выделенное время (весь проект, дальше сдвигается),
      -- dr — очистить трек в регионе, daw — все item трека (4 окт)
      if p == 'd' and c == ('t'):byte() then
        if ctx.delete_time() then finish_edit() else finish_move() end
        V.count = nil; return
      end
      if p == 'd' and c == ('r'):byte() then
        if ctx.clear_track() then finish_edit() else finish_move() end
        V.count = nil; return
      end
      if p == 'd' and c == ('a'):byte() then V.pending = 'da'; return end
      -- 10 окт: dP — все items и автоматизация выбранных треков во всём проекте
      if p == 'd' and c == ('P'):byte() then
        if ctx.clear_tracks_all and ctx.clear_tracks_all() then finish_edit() else finish_move() end
        V.count = nil; return
      end
      -- 10 окт: dp — до паузы (как d} в Vim: абзац = серия событий лейна без
      -- пустой строки). С курсора вниз; курсор на пустой строке — ближайшая серия
      if p == 'd' and c == ('p'):byte() then
        local f = flat()[V.cur.fi]
        if not f or f.env then finish_move(); V.count = nil; return end
        local fa, fb = V.cur.fi, V.cur.fi
        while flat()[fa - 1] and flat()[fa - 1].col == f.col and flat()[fa - 1].lane == f.lane and not flat()[fa - 1].env do fa = fa - 1 end
        while flat()[fb + 1] and flat()[fb + 1].col == f.col and flat()[fb + 1].lane == f.lane and not flat()[fb + 1].env do fb = fb + 1 end
        local maxr = -1
        for fi = fa, fb do for _, sub in ipairs(subs_of(flat()[fi])) do for r in pairs(sub) do if type(r) == 'number' and r > maxr then maxr = r end end end end
        local function busy(r)
          for fi = fa, fb do for _, sub in ipairs(subs_of(flat()[fi])) do if sub[r] then return true end end end
          return false
        end
        local r0 = V.cur.row
        while r0 <= maxr and not busy(r0) do r0 = r0 + 1 end
        if r0 > maxr then V.msg = 'dp: nothing below - no events until the end'; finish_move(); V.count = nil; return end
        local r1 = r0
        while r1 + 1 <= maxr and busy(r1 + 1) do r1 = r1 + 1 end
        if apply('d', fa, fb, r0, r1) then
          V.msg = ('dp: rows %04d-%04d deleted (up to the pause)'):format(r0, r1)
          finish_edit()
        else finish_move() end
        V.count = nil; return
      end
      local t = motion(c, n, p)
      -- 9 окт: dl / dh (yl, cl …) — только своя подколонка: шаг по полю через
      -- край задевал соседнюю колонку; dl = x (событие строки курсора)
      if t and (c == ('l'):byte() or c == ('h'):byte() or c == RIGHT or c == LEFT) then t.fi = V.cur.fi; t.row = V.cur.row end
      if t then
        local f0, f1, r0, r1 = range_or_event(p, t)
        local e = apply(p, f0, f1, r0, r1)
        if e then finish_edit() else finish_move() end
      else
        -- 6 окт: dw на последней точке огибающей (дальше точек нет, движение
        -- не нашло цели) — сама точка курсора
        local ft = flat()[V.cur.fi]
        if ft and ft.env and (c == ('w'):byte() or c == ('e'):byte()) and env_has(ft, V.cur.row) then
          if apply(p, V.cur.fi, V.cur.fi, V.cur.row, V.cur.row) then finish_edit() else finish_move() end
        else finish_move() end
      end
      V.count = nil; return
    end
    return
  end

  -- счётчик
  if c >= ('0'):byte() and c <= ('9'):byte() and not (c == ('0'):byte() and not V.count) then
    V.count = (V.count or 0) * 10 + (c - 48); return
  end

  -- VISUAL: операторы на выделении
  if V.mode == 'visual' or V.mode == 'vline' then
    local f0, f1, r0, r1 = V.visual_range()
    local done = false
    if c == ESC then V.mode = 'normal'; done = true; finish_move()
    elseif c == ('o'):byte() then V.cur, V.anchor = V.anchor, V.cur; done = true
    elseif c == ('d'):byte() or c == ('x'):byte() or c == ('y'):byte() or c == ('c'):byte()
        or c == ('M'):byte() or c == ('s'):byte() then
      local e = apply(c == ('M'):byte() and 'm' or string.char(c), f0, f1, r0, r1)
      V.cur.fi, V.cur.row = f0, r0
      if V.mode ~= 'insert' then V.mode = 'normal' end
      if e then finish_edit() else finish_move() end
      done = true
    elseif c == ctrl('a') or c == ctrl('x') then
      apply(c == ctrl('a') and '+' or '-', f0, f1, r0, r1); V.mode = 'normal'; finish_edit(); done = true
    elseif c == ('p'):byte() then
      local reg = V.regs['"']
      local env = f0 == f1 and env_of(f0)
      if env and reg and reg.kind == 'env' then
        ctx.env_del_range(env, r0, r1); ctx.env_paste(env, r0, reg)
      elseif not env and not (reg and reg.kind == 'env') then
        local heads = V.heads_in(f0, f1, r0, r1)
        E.delete(heads, lpb())
        E.paste(reg, lpb(), r0, paste_targets(f0))
      else V.msg = 'register and selection differ (envelope points vs notes)' end
      V.cur.fi, V.cur.row = f0, r0; V.mode = 'normal'; finish_edit(); done = true
    elseif c == ('r'):byte() then V.pending = 'r'; return
    elseif c == ('V'):byte() then V.mode = 'vline'; done = true
    elseif c == ('v'):byte() then V.mode = 'visual'; done = true
    end
    if done then V.count = nil; ensure_visible(); return end
    -- иначе — движение расширяет выделение
  end

  -- движение
  local t = motion(c, n)
  if t then
    if c == ('G'):byte() and t.row ~= V.cur.row and ctx.jump_mark then ctx.jump_mark() end   -- 9 окт: G — в список прыжков (Ctrl+O назад)
    V.cur.fi, V.cur.row = t.fi, t.row
    if t.field then V.cur.field = t.field; V.cur.sub = t.sub end
    clamp_cur(); ensure_visible(); V.count = nil; finish_move(); return
  end

  -- NORMAL команды
  local ch = (c < 256) and string.char(c) or ''
  if ch == 'i' then V.mode = 'insert'; V.count = nil; return
  elseif ch == 'a' then ctx.toggle_envs(); V.count = nil; return
  elseif ch == 'o' then if ctx.reveal_item then ctx.reveal_item() end; V.count = nil; return
  elseif ch == '=' then
    -- beatsync (= как «выровнять» в Vim): конец события к ближайшей доле; N= — к N строкам
    local heads
    if V.mode == 'visual' or V.mode == 'vline' then local f0, f1, r0, r1 = V.visual_range(); heads = V.heads_in(f0, f1, r0, r1)
    else heads = V.covering(V.cur.fi, V.cur.row); if #heads == 0 then heads = V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row) end end
    local k = ctx.edit.beatsync(heads, lpb(), V.count and tostring(V.count) or 'beat')
    V.msg = ('beatsync %s: %d event(s)'):format(V.count and (V.count .. ' rows') or 'beat', k or 0)
    V.count = nil; finish_edit(); return
  -- лупы в регионе (F1): > item до конца региона (N> — период N шагов), < регион до конца item
  elseif ch == '>' then ctx.loop('item', V.count); V.count = nil; finish_edit(); return
  elseif ch == '<' then ctx.loop('region'); V.count = nil; finish_edit(); return
  elseif ch == 'A' then ctx.automation_picker(); V.count = nil; return
  elseif ch == 'v' then V.mode = 'visual'; V.anchor = { fi = V.cur.fi, row = V.cur.row }
  elseif ch == 'V' then V.mode = 'vline'; V.anchor = { fi = V.cur.fi, row = V.cur.row }
  elseif ch == ':' then V.cmd_from = V.mode; V.mode = 'cmd'; V.cmdline = ''; V.count = nil; return
  -- 6 окт: / — поиск КОМАНД под курсором (fzf: действия ячейки, клавиши модуля,
  -- :команды); поиск по содержимому — f (метки прыжка)
  elseif ch == '/' then V.count = nil; if ctx.command_search then ctx.command_search() else V.mode = 'search'; V.searchline = '' end; return
  elseif ch == 'n' then for _ = 1, n do V.find_next(1) end
  elseif ch == 'N' then for _ = 1, n do V.find_next(-1) end
  elseif ch == '*' then
    local h = V.covering(V.cur.fi, V.cur.row)[1]
    if h then V.search = h.name ~= '' and h.name or h.note; V.find_next(1) end
  elseif ch == '?' then V.open_hydra(ctx.hydra_keys())
  elseif ch == 'd' or ch == 'y' or ch == 'c' then V.pending = ch; return
  elseif ch == 't' and V.mode == 'normal' then V.pending = 't'; return   -- 8 окт: tt — новый трек
  elseif ch == 'T' and V.mode == 'normal' then V.pending = 'T'; return   -- 11 окт: T — take ноты под курсором (t — трек)
  elseif ch == 'g' or ch == 'z' or ch == 'r' or ch == '@' or ch == "'" then V.pending = ch; return   -- ' — harpoon (9 окт)
  elseif ch == 'q' then
    if V.macro then
      V.regs['@' .. V.macro.name] = V.macro.keys
      table.remove(V.regs['@' .. V.macro.name])     -- сам `q` не в макросе
      V.last_macro = V.macro.name; V.msg = 'macro @' .. V.macro.name; V.macro = nil
    else V.pending = 'q' end
    V.count = nil; return
  elseif (c == BS or c == INS or ch == 'I') and not env_of(V.cur.fi) then
    -- Backspace: удалить время строки (трек курсора; Shift — все треки) в
    -- рамках региона; Insert / I — вставить время. Счётчик = строк.
    local all = ctx.mods and ctx.mods().shift or false
    if ctx.time_edit then ctx.time_edit(c == BS and 'delete' or 'insert', V.cur.fi, V.cur.row, n, all) end
    finish_edit()
  elseif env_of(V.cur.fi) and (ch == 'x' or c == BS or c == DEL or c == ctrl('a') or c == ctrl('x')) then
    -- колонка огибающей в NORMAL: x/BS — удалить точку, ^A/^X — ±1/64
    local env = env_of(V.cur.fi)
    if (V.cur.field or 1) == 2 and nfields() >= 2 and (c == ctrl('a') or c == ctrl('x')) then ctx.env_shape_step(env, V.cur.row, c == ctrl('a') and 1 or -1)
    elseif c == ctrl('a') then ctx.env_nudge(env, V.cur.row, n / 64)
    elseif c == ctrl('x') then ctx.env_nudge(env, V.cur.row, -n / 64)
    else for r = V.cur.row, V.cur.row + n - 1 do ctx.env_del(env, r) end end
    finish_edit()
  elseif ch == 'x' and (flat()[V.cur.fi] or {}).ml then
    for r = V.cur.row, V.cur.row + n - 1 do ctx.ml_del(flat()[V.cur.fi], r) end; finish_edit()   -- MIDI-лейн: события строк
  elseif ch == 'x' then
    apply('x', V.cur.fi, V.cur.fi, V.cur.row, V.cur.row + n - 1); finish_edit()
  elseif ch == 'M' or ch == 'S' then                     -- 9 окт: Shift+M / Shift+S — mute / solo трека (события — M в VISUAL)
    if ctx.track_toggle then ctx.track_toggle(ch == 'M' and 'mute' or 'solo') end
  elseif ch == 's' then
    apply('s', V.cur.fi, V.cur.fi, V.cur.row, V.cur.row); finish_edit()
  elseif c == ctrl('a') then apply('+', V.cur.fi, V.cur.fi, V.cur.row, V.cur.row); finish_edit()
  elseif c == ctrl('x') then apply('-', V.cur.fi, V.cur.fi, V.cur.row, V.cur.row); finish_edit()
  elseif ch == 'p' or ch == 'P' then
    local reg = V.regs['"']
    if reg and reg.kind == 'env' then
      local env = env_of(V.cur.fi)
      if env then for k = 0, n - 1 do ctx.env_paste(env, V.cur.row + k * (reg.rows or 1), reg) end; finish_edit()
      else V.msg = 'register has envelope points - put the cursor on an envelope column' end
    elseif env_of(V.cur.fi) then V.msg = 'register has notes - put the cursor on a note column'
    else
      for _ = 1, n do E.paste(reg, lpb(), V.cur.row, paste_targets(V.cur.fi)) end
      finish_edit()
    end
  elseif ch == 'u' then E.undo(); finish_move()
  elseif c == ctrl('r') and not (ctx.mods and (ctx.mods().ctrl or ctx.mods().alt or ctx.mods().cmd)) then E.redo(); finish_move()   -- 5 окт: Ctrl+R — вкладка rec (main)
  elseif ch == '.' then
    if V.last_edit then local keys = V.last_edit; V.cmdbuf = {}; for _ = 1, n do replay(keys) end end
  elseif ch == '[' then V.octave = math.max(0, V.octave - 1)
  elseif ch == ']' then V.octave = math.min(8, V.octave + 1)
  elseif ch == '(' then ctx.pool_select(V.inst - 1)
  elseif ch == ')' then ctx.pool_select(V.inst + 1)
  elseif ch == 'F' then st.follow = not st.follow
  elseif ch == ' ' then E.play_stop()
  elseif c == ENTER and ctx.mods and ctx.mods().shift and ctx.describe_cell then
    -- Shift+Enter (3 окт): что именно под курсором — исходник, номер, слайс, кусок файла
    local f = flat()[V.cur.fi]
    local cell = f and f.sub and f.sub[V.cur.row]
    if cell and cell.kind == 'cont' then cell = cell.of end
    V.msg = ctx.describe_cell(cell)
  elseif c == ENTER then E.cursor_to(ctx.row_time(V.cur.row))
  elseif c == TAB then ctx.toggle_focus()
  elseif c == ESC then
    -- Esc (4 окт, как Edit mode в Renoise): из NORMAL — в INSERT; набранный
    -- счётчик Esc сначала только сбрасывает (как в Vim)
    -- 10 окт: опция Esc mode = vim — Esc только NORMAL (сбрасывает счётчик и сообщение)
    if V.count then V.count = nil; finish_move() elseif ctx.esc_vim and ctx.esc_vim() then V.msg = ''; finish_move() else V.mode = 'insert'; V.msg = '' end
  elseif ch == '+' or ch == '=' then ctx.set_lpb(nil, 1)
  elseif ch == '-' then ctx.set_lpb(nil, -1)
  end
  V.count = nil
  ensure_visible()
end

-- ── поиск (/) ─────────────────────────────────────────────────────────────
-- Совпадение: имя источника, имя ноты (C-4) или команда (9A0), без регистра.
local function head_matches(h, q)
  if not h or not q or q == '' then return false end
  q = q:lower()
  if (h.name or ''):lower():find(q, 1, true) then return true end
  if (h.note or ''):lower() == q then return true end
  for _, f in ipairs(h.fx or {}) do if f:lower():find(q, 1, true) then return true end end
  return false
end

function V.find_next(dir)
  local q = V.search
  if not q or q == '' then V.msg = 'no search'; return false end
  local F = flat()
  local last = ctx.snap().last_row or 0
  local total = last + 1
  local r = V.cur.row
  for _ = 1, total do
    r = r + dir
    if r > last then r = 0 elseif r < 0 then r = last end
    for fi, f in ipairs(F) do
      for _, sub in ipairs(subs_of(f)) do
        local c = sub[r]
        if is_head(c) and head_matches(c, q) then
          V.cur.fi, V.cur.row, V.cur.field = fi, r, 1
          ensure_visible(); V.msg = '/' .. q
          return true
        end
      end
    end
  end
  V.msg = 'not found: ' .. q
  return false
end

-- ── fzf-пикер ─────────────────────────────────────────────────────────────
-- Универсальный выбор из списка с нечётким поиском: буквы — запрос,
-- ^N/^P или стрелки — курсор, Enter — выбрать, Esc — закрыть.
-- items = { { label=, data= } … }, on_pick(item). Совпадение — подпоследовательность
-- без регистра; подстрока и короткая метка ранжируются выше.
V.picker = nil

local function fuzzy_score(label, q)
  if q == '' then return 1 end
  local l, qq = label:lower(), q:lower()
  local sub = l:find(qq, 1, true)
  if sub then return 1000 - sub - #label * 0.01 end
  local pos, first = 0, nil
  for i = 1, #qq do
    local c = qq:sub(i, i)
    local f = l:find(c, pos + 1, true)
    if not f then return nil end
    first = first or f
    pos = f
  end
  return 500 - (pos - first) - #label * 0.01
end

local function picker_filter()
  local pk = V.picker
  local out = {}
  for i, it in ipairs(pk.items) do
    local sc = fuzzy_score(it.label, pk.query)
    if sc then out[#out + 1] = { it = it, sc = sc, i = i } end
  end
  -- при равном счёте — порядок списка (недавние действия сверху остаются сверху)
  table.sort(out, function(a, b) if a.sc ~= b.sc then return a.sc > b.sc end return a.i < b.i end)
  pk.matches = {}
  for i, m in ipairs(out) do pk.matches[i] = m.it end
  if pk.sel > #pk.matches then pk.sel = math.max(1, #pk.matches) end
end

function V.picker_refilter() if V.picker then picker_filter() end end
function V.open_picker(title, items, on_pick, query)
  V.picker = { title = title, items = items, query = query or '', sel = 1, matches = {}, on_pick = on_pick }
  picker_filter()
end

function V.picker_key(c)
  local pk = V.picker
  if c == ESC then V.picker = nil
  elseif c == ENTER then
    local it = pk.matches[pk.sel]
    V.picker = nil
    if it and pk.on_pick then local ok, e = pcall(pk.on_pick, it); if not ok then V.msg = tostring(e):match('[^\n]*$') end end
  elseif c == BS then pk.query = pk.query:sub(1, -2); picker_filter()
  elseif c == 14 or c == DOWN or c == 10 then pk.sel = math.min(#pk.matches, pk.sel + 1)
  elseif c == 16 or c == UP or c == 11 then pk.sel = math.max(1, pk.sel - 1)
  elseif c >= 32 and c < 127 then pk.query = pk.query .. string.char(c); picker_filter() end
end

-- ── hydra (which-key) ─────────────────────────────────────────────────────
-- 9 окт: повтор буквы в меню (второй пункт был недостижим) — пункт берёт
-- следующую свободную букву своей подписи, в журнал debug — предупреждение
function V.hydra_fix(h)
  if type(h) ~= 'table' or not h.items then return h end
  local used, dups = {}, {}
  for _, it in ipairs(h.items) do
    if it.key and used[it.key] then
      dups[#dups + 1] = it.key
      local nk
      for ch in ((it.label or '') .. 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'):gmatch('%w') do
        if not used[ch] then nk = ch; break end
      end
      it.key = nk
    end
    if it.key then used[it.key] = true end
  end
  if #dups > 0 and ctx.dlog then ctx.dlog(('menu "%s": duplicate keys %s - moved to free letters'):format(tostring(h.title), table.concat(dups, ' '))) end
  return h
end
function V.open_hydra(h)
  V.hydra = V.hydra_fix(h); V.hydra_stack = {}
end

function V.hydra_key(c)
  local h = V.hydra
  if c == ESC then V.hydra = nil; return end
  if c == BS then V.hydra = table.remove(V.hydra_stack); return end
  local ch = (c < 256) and string.char(c) or ''
  for _, it in ipairs(h.items or {}) do
    if it.key == ch then
      if it.sub then
        V.hydra_stack[#V.hydra_stack + 1] = h
        V.hydra = V.hydra_fix(type(it.sub) == 'function' and it.sub() or it.sub)
      else
        V.hydra = nil
        if it.fn then local ok, e = pcall(it.fn); if not ok then V.msg = tostring(e):match('[^\n]*$') end end
      end
      return
    end
  end
end

-- содержимое всплывашки для отрисовки (или nil)
function V.popup()
  if V.picker then
    local pk = V.picker
    local lines = {}
    local nr = pk.rows or 14                      -- 6 окт: высота задаётся (действия REAPER — на всю матрицу)
    local first = math.max(1, pk.sel - (nr - 1))
    for i = first, math.min(#pk.matches, first + nr - 1) do
      lines[#lines + 1] = { key = (i == pk.sel) and '>' or ' ', text = pk.matches[i].label, col = pk.matches[i].col }   -- col: свой цвет строки (маршрутизация, 9 окт)
    end
    -- 9 окт: пусто — строкой, иначе окно сжималось до клочка заголовка («ro»)
    if #lines == 0 then lines[1] = { key = ' ', text = 'no matches - Backspace (Ctrl+J / K or arrows move, letters search)', col = { 0.6, 0.6, 0.6 } } end
    return { title = pk.title .. ' > ' .. pk.query .. '_' .. ('  (%d)'):format(#pk.matches), lines = lines, kind = 'picker', first = first, nmatch = #pk.matches, hl = #pk.matches > 0 and (pk.sel - first + 1) or nil }
  elseif V.hydra then
    local lines = {}
    for _, it in ipairs(V.hydra.items or {}) do
      lines[#lines + 1] = { key = it.key, text = it.label .. ((it.sub and not it.label:find('…', 1, true)) and ' …' or ''), hk = it.hk }   -- 9 окт: без двойного …
    end
    -- 11 окт: хинты включены — внизу меню «как сюда быстро» (h.how): для мышечной памяти
    if V.hydra.how and ctx.state and ctx.state.hints then lines[#lines + 1] = { key = ' ', text = 'fast: ' .. V.hydra.how, col = { 0.55, 0.55, 0.55 } } end
    return { title = V.hydra.title or '', lines = lines, kind = 'hydra' }
  elseif V.mode == 'cmd' then
    local matches, word = V.cmd_matches(V.cmdline)
    local lines = {}
    for i, c in ipairs(matches) do
      if i > 14 then break end
      lines[#lines + 1] = { key = c[1] .. (c[2] ~= '' and (' ' .. c[2]) or ''), text = c[3] }
    end
    return { title = ':' .. (V.cmdline or ''), lines = lines, kind = 'cmd', hl = V.cmd_cycle }
  elseif V.mode == 'search' then
    return { title = '/' .. (V.searchline or ''), lines = { { key = 'Enter', text = 'find next' }, { key = 'n / N', text = 'next / previous' }, { key = '*', text = 'search name under cursor' } }, kind = 'search' }
  end
  return nil
end

-- 10 окт: транспозиция как в Renoise (F1 / F2 — полутон, F11 / F12 — октава):
-- scope = 'sel' (выделение, иначе событие строки курсора) | 'col' (колонка, паттерн)
-- | 'track' (все колонки трека, паттерн) | 'pattern' (все треки, паттерн)
V.TSCOPE = { sel = 'selection', col = 'column', track = 'track', pattern = 'pattern' }
function V.transpose_scope(scope, d)
  local F = flat()
  local f0, f1, r0, r1
  if scope == 'sel' then
    if V.mode == 'visual' or V.mode == 'vline' then f0, f1, r0, r1 = V.visual_range()
    else f0, f1, r0, r1 = V.cur.fi, V.cur.fi, V.cur.row, V.cur.row end
  else
    local a, b = ctx.region_rows and ctx.region_rows()
    r0, r1 = a or 0, b or ((ctx.snap().last_row or 0))
    if scope == 'col' then f0, f1 = V.cur.fi, V.cur.fi
    elseif scope == 'track' then
      local ci = F[V.cur.fi] and F[V.cur.fi].ci
      for i, f in ipairs(F) do if f.ci == ci and not f.env then f0 = f0 or i; f1 = i end end
    else f0, f1 = 1, #F end
  end
  if not f0 then return false end
  local heads = V.heads_in(f0, f1, r0, r1)
  local notes = {}
  for _, h in ipairs(heads) do if h.kind == 'midi' or h.kind == 'audio' then notes[#notes + 1] = h end end
  if #notes == 0 then V.msg = ('transpose %s: no notes'):format(V.TSCOPE[scope] or scope); return false end
  ctx.edit.transpose(notes, lpb(), d)
  V.last_edit = nil
  V.msg = ('transpose %s %+d: %d note(s)'):format(V.TSCOPE[scope] or scope, d, #notes)
  return true
end
-- zt — умная выпадашка транспозиции: −24 … +24 и где (выделение / колонка / трек / паттерн)
function V.transpose_smart(scope)
  if not ctx.smart_open then return end
  scope = scope or 'sel'
  local items = {}
  for d = -24, 24 do
    items[#items + 1] = { label = d == 0 and '0' or ('%+d'):format(d), v = d, on = d == 0, dim = d == 0,
      tip = ('transpose the %s %+d semitone(s)'):format(V.TSCOPE[scope], d) }
  end
  while #items % 12 ~= 0 do items[#items + 1] = { label = '', dim = true } end
  for _, sc in ipairs({ 'sel', 'col', 'track', 'pattern' }) do
    items[#items + 1] = { label = V.TSCOPE[sc], v = 'scope:' .. sc, on = sc == scope, tip = 'transpose the ' .. V.TSCOPE[sc] .. ' (F1 F2: Opt sel, Shift+Ctrl column, Shift track, Ctrl pattern)' }
  end
  local sel = 25
  ctx.smart_open({ title = 'transpose - ' .. V.TSCOPE[scope] .. ' (h j k l, Enter)', items = items, cols = 12, sel = sel,
    on_pick = function(it)
      if type(it.v) == 'string' and it.v:match('^scope:') then V.transpose_smart(it.v:sub(7)); return nil end
      if type(it.v) == 'number' and it.v ~= 0 then V.transpose_scope(scope, it.v) end
    end })
end
function V.visual_range()
  local a, b = V.anchor or V.cur, V.cur
  local f0, f1 = math.min(a.fi, b.fi), math.max(a.fi, b.fi)
  if V.mode == 'vline' then f0, f1 = 1, nflat() end
  return f0, f1, math.min(a.row, b.row), math.max(a.row, b.row)
end

-- подсказка продолжений ожидающего оператора — справа в строке статуса
-- (просьба 2 окт: нажал d — видно, что можно дальше)
local PENDING_HINT = {
  d = 'd: d delete track | w event | W whole item | t remove time selection | r track in region | aw all items of track | j k rows | G to end | gg to start | } { bar | $ fields | 3w count | Esc',
  y = 'y: y rows | w event | j k rows | G to end | gg to start | } { bar | 3j count | Esc',
  c = 'c: c rows (replace) | w event | j k rows | } { bar | Esc',
  g = 'g: g first row | s smart panel (values of the field, mouse) | w swap with next event | Esc',
  T = 'T: f add take fx to the note under the cursor | o its take fx chain in DSP | Esc',
  z = 'z: a fold track | c close | o open | f folder | M fold all | R open all | z center | t top | b bottom | s clips (session)',
  r = 'r: note key sets pitch | hex digits set field | Esc',
  q = 'q: a..z record macro into register',
  da = 'da: w all items of the track (the lib after =LIB stays) | Esc',
  ['@'] = '@: a..z play macro | @ repeat last',
}
function V.pending_hint()
  if not V.pending then return nil end
  local p = V.op and V.pending == 'g' and V.op or V.pending
  local h = PENDING_HINT[p]
  if not h then return nil end
  return (V.count and (tostring(V.count) .. ' ') or '') .. h
end

function V.status()
  local m = ({ normal = V.piano and '-- KEYS --' or '', insert = '-- INSERT --', visual = '-- VISUAL --', vline = '-- V-LINE --',
               cmd = ':' .. (V.cmdline or ''), search = '/' .. (V.searchline or '') })[V.mode] or ''
  local extra = ''
  if V.macro then extra = ' rec@' .. V.macro.name end
  if V.pending then extra = extra .. ' ' .. V.pending end
  if V.hexbuf then extra = extra .. ' [' .. V.hexbuf .. '_]' end
  if V.count then extra = extra .. ' ' .. V.count end
  return m .. extra, ('oct %d vel %d step %s inst %d'):format(V.octave, V.vel or 100, V.step_next and 'next' or (V.step_auto and 'auto' or tostring(V.step)), V.inst)
end

-- обёртка: оператор, начатый из INSERT (d…), по завершении возвращает в INSERT
function V.key(c)
  if ctx.piano_on then V.piano = ctx.piano_on() end    -- клавиатура = видна снизу (m), 5 окт
  local p0 = V.cur.fi * 1e6 + V.cur.row * 10 + (V.cur.field or 1)
  local r = V.key_impl(c)
  if ctx.piano_on then V.piano = ctx.piano_on() end
  -- набор сокращения формы живёт только на месте: курсор ушёл — сброс (ревью 2 окт)
  if V.shapebuf and (V.cur.fi * 1e6 + V.cur.row * 10 + (V.cur.field or 1)) ~= p0 then V.shapebuf = nil end
  if V.hexbuf and (V.cur.fi * 1e6 + V.cur.row * 10 + (V.cur.field or 1)) ~= p0 then V.hexbuf = nil end   -- 11 окт: набор живёт в своей ячейке
  if V.mode ~= 'insert' then V.shapebuf = nil end
  -- в INSERT вернуться, когда операция (или выделение — s / Shift+hjkl, 5 окт) закончилась
  if V.back_insert and not V.pending and not V.op and V.mode ~= 'visual' and V.mode ~= 'vline' then
    if V.mode == 'normal' then V.mode = 'insert' end
    V.back_insert = nil
  end
  return r
end

-- команда из кнопки (4 окт): как набранная после : в текущем режиме
function V.run_cmd(line)
  V.cmd_from = V.mode
  local r = run_cmd(line)
  if V.mode == 'visual' or V.mode == 'vline' then V.mode = 'normal' end
  return r
end

-- смарт-панель (9 окт, gs / средний щелчок; как Smart Select PlayerPro):
-- сетка значений поля курсора у ячейки, выбор мышью или h j k l + Enter.
-- Правит то же, что r / ввод: нота (пусто — вставить, есть — высота),
-- vol / delay / команда (буква, потом значение), инструмент, огибающая, CC.
-- В VISUAL — весь блок (как r)
function V.smart()
  local SM = ctx.SM
  local f = flat()[V.cur.fi]
  if not (SM and f) then return false end
  local E = ctx.edit
  local fi, row, fld = V.cur.fi, V.cur.row, V.cur.field or 1
  local vis = V.mode == 'visual' or V.mode == 'vline'
  local f0, f1, r0, r1 = fi, fi, row, row
  if vis then f0, f1, r0, r1 = V.visual_range() end
  local function heads() return V.heads_in(f0, f1, r0, r1) end
  local hexf = (ctx.envfmt and ctx.envfmt() or 'midi') == 'hex'
  local function done() if vis then V.mode = 'normal' end; V.cmdbuf = {} end
  local where = (f.col and f.col.name or '') .. (' @ %04d'):format(row)
  local items, cols, sel, title, pick
  local listen, crows, cellw            -- 11 окт: прослушивание выбора (кнопка listen) и ячейки с волной
  if f.ml then
    if not (f.ml.kind == 'cc' or f.ml.kind == 'pc') then V.msg = 'smart: this MIDI lane has no values'; return false end
    items, cols, sel = SM.values(128, nil, hexf, 'delete the events of this row')
    title = ('%s %s  %s'):format(f.ml.kind:upper(), f.ml.num and tostring(f.ml.num) or '', where)
    pick = function(it)
      if it.v == 'clear' then ctx.ml_del(f, row) else ctx.ml_set(f, row, it.v) end
      done()
    end
  elseif f.env then
    local n = hexf and 256 or 128
    items, cols, sel = SM.values(n, nil, hexf, 'delete the point of this row')
    title = ('%s  %s'):format(f.env.name or 'envelope', where)
    pick = function(it)
      if it.v == 'clear' then ctx.env_del(f.env, row) else ctx.env_set(f.env, row, it.v / (n - 1)) end
      done()
    end
  elseif V.cur.sub == 'slc' and fld == 1 then
    -- 11 окт: слайсы инструмента ноты
    local h1 = heads()[1]
    local n = h1 and ctx.snap().inst_of and ctx.snap().inst_of[h1.item]
    local pe = n and f.col.pool and f.col.pool[n]
    local root = pe and (pe.parent or pe)
    if not (root and root.slices and #root.slices > 0) then V.msg = 'smart: this note has no sliced instrument'; return false end
    items = { { label = '00 the whole sample', v = 0 } }
    for k2 = 1, #root.slices do items[#items + 1] = { label = ('S%02X'):format(k2), v = k2 } end
    for k2, it in ipairs(items) do if it.v == (h1.slice or 0) then sel = k2 end end
    cols, title = math.min(6, #items), 'slice  ' .. where
    -- 11 окт: ячейка — номер и волна куска; listen — кусок звучит
    local function span(k2) if k2 == 0 then return 0, root.len end; return root.slices[k2], root.slices[k2 + 1] or root.len end
    crows, cellw = 3, ctx.layout().cw * 9
    for _, it in ipairs(items) do
      local a, b = span(it.v)
      it.label = it.v == 0 and 'all' or it.label
      it.tip = it.v == 0 and 'the whole sample' or ('slice S%02X  %.3f s'):format(it.v, b - a)
      it.draw = function(x, y, w, h, on) if ctx.mini_wave then ctx.mini_wave(root, a, b, x, y, w, h, on, it.label) end end
    end
    listen = function(it) local a, b = span(it.v); if ctx.preview_slice then ctx.preview_slice(f.col.track, root, a, b) end end
    pick = function(it) if ctx.set_slice then ctx.set_slice(heads(), it.v) end; done() end
  elseif V.cur.sub == 'inst' and fld == 1 then
    items = {}
    local h1 = heads()[1]
    for i, e in pairs(f.col.pool or {}) do
      -- 11 окт: только сами инструменты — слайсы (дети в lib) не дублируют имя
      if type(i) == 'number' and e and not e.parent then
        -- 11 окт: номер как в lib (e.num), не индекс pool
        local lb = ('%02d %s'):format(e.num or i, e.name or '')
        items[#items + 1] = { label = lb, v = i, tip = e.name .. (e.slices and #e.slices > 0 and ('  /' .. #e.slices .. ' slices') or ''),
          draw = (e.item and e.stype == 'audio') and function(x, y, w, h, on) if ctx.mini_wave then ctx.mini_wave(e, 0, e.len, x, y, w, h, on, lb) end end or nil }
      end
    end
    table.sort(items, function(a, b) return a.v < b.v end)
    -- 11 окт: и плагины-инструменты трека (VSTi / AUi / RS5K) — номером из lib
    local pool0 = f.col.pool or {}
    local base = #pool0 + (ctx.empty_slots and ctx.empty_slots(#pool0) or 0)
    for k, fi2 in ipairs(ctx.track_insts and ctx.track_insts(f.col) or {}) do
      items[#items + 1] = { label = ('%02d %s'):format(base + k, fi2.name or 'instrument'), v = base + k, tip = (fi2.name or '') .. '  (plugin - the note becomes MIDI)' }
    end
    if #items == 0 then V.msg = 'smart: no instruments on this track (lib)'; return false end
    -- выбран инструмент ноты под курсором (слайс — его исходник), иначе текущий
    local cur = V.inst
    local ni = h1 and h1.item and ctx.snap().inst_of and ctx.snap().inst_of[h1.item]
    if h1 and h1.kind == 'midi' and ctx.midi_inst_num then ni = ctx.midi_inst_num(h1.item, h1.pitch) end
    if ni then cur = ni end
    local pe = (f.col.pool or {})[cur]
    if pe and pe.parent then for i2, e2 in ipairs(f.col.pool) do if e2 == pe.parent then cur = i2 end end end
    for k, it in ipairs(items) do if it.v == cur then sel = k end end
    cols, title = 1, 'instrument  ' .. where
    crows, cellw = 2, ctx.layout().cw * 30
    listen = function(it)
      local e = f.col.pool[it.v]
      if e and e.item and ctx.preview then ctx.preview(f.col.track, ctx.model_base_note or 60, e.item, row, 1) end
    end
    pick = function(it) if ctx.set_inst then ctx.set_inst(heads(), it.v) end; V.inst = it.v; done() end
    if not h1 then V.msg = 'smart: an empty row - the instrument is chosen for the next notes' end
  elseif fld == 1 then
    local h1 = heads()[1]
    items, cols, sel = SM.notes(h1 and h1.pitch, V.octave)
    title = (h1 and ('note %s'):format(h1.note or '') or 'note') .. '  ' .. where
    listen = function(it)
      if type(it.v) ~= 'number' or not ctx.preview then return end
      local inst = (f.col.pool or {})[V.inst]
      if ctx.inst_fx and ctx.inst_fx(f.col) then inst = nil end
      ctx.preview(f.col.track, it.v, (ctx.inst_src and ctx.inst_src(f.col, inst) or (inst and inst.item)), row, 1)
    end
    pick = function(it)
      if it.v == nil then return SM.p end
      local hs = heads()
      if it.v == 'del' then E.delete(hs, lpb())
      elseif it.v == 'off' then E.note_off(V.covering(fi, row), lpb(), row)
      elseif #hs > 0 then E.set_pitch(hs, lpb(), it.v)
      elseif not vis then
        local lane = f.lane or f.col.lanes[1]
        local inst = (f.col.pool or {})[V.inst]
        if ctx.inst_fx and ctx.inst_fx(f.col) then inst = nil end   -- 9 окт: плагин-инструмент — MIDI
        local cell = f.sub and f.sub[row]
        if cell and cell.kind == 'cont' and cell.of then E.note_off({ cell.of }, lpb(), row) end
        E.insert_note(f.col.track, f.col.fixed and lane.idx or nil, lpb(), row, it.v, V.vel, V.step_auto and 1 or V.step, (ctx.inst_src and ctx.inst_src(f.col, inst) or (inst and inst.item)))
        if ctx.state.preview and ctx.preview then ctx.preview(f.col.track, it.v, (ctx.inst_src and ctx.inst_src(f.col, inst) or (inst and inst.item)), row, 1) end
      end
      done()
    end
  elseif fld == 2 or fld == 3 then
    local h1 = heads()[1]
    if not h1 then V.msg = 'smart: no event in this row'; return false end
    local cur = fld == 2 and tonumber(h1.vol or '', 16) or (fld == 3 and math.floor((h1.delay or 0) + 0.5) or nil)
    local n = (fld == 2 and h1.kind == 'midi') and 128 or 256
    items, cols, sel = SM.values(n, cur, true, fld == 2 and 'volume back to default' or 'no delay')
    title = (fld == 2 and 'volume' or 'delay xx/256 row') .. '  ' .. where
    if fld == 2 then
      -- 11 окт: нота ячейки звучит с этой громкостью
      listen = function(it) if ctx.listen_vol and type(it.v) == 'number' then ctx.listen_vol(f.col, h1, it.v, n) end end
    end
    pick = function(it)
      local hs = heads()
      if fld == 2 then E.set_vol(hs, lpb(), it.v == 'clear' and 128 or it.v)
      else E.set_delay(hs, lpb(), it.v == 'clear' and 0 or it.v) end
      done()
    end
  else
    local h1 = heads()[1]
    if not h1 then V.msg = 'smart: no event in this row'; return false end
    local have = (h1.fx or {})[fld - 3]
    local function vals(letter, curx)
      local its, cs, sl = SM.values(256, curx, true, 'delete ' .. letter .. 'xx')
      local desc = ''
      for _, e in ipairs(SM.FX) do if e[1] == letter then desc = e[2] end end
      return { title = ('%sxx  %s  %s'):format(letter, desc, where), items = its, cols = cs, sel = sl,
               on_pick = function(it)
                 local hs = heads()
                 if it.v == 'clear' then E.clear_fx(hs, lpb(), letter) else E.set_fx(hs, lpb(), letter, it.v) end
                 done()
               end }
    end
    if have then
      local p = vals(have:sub(1, 1), tonumber(have:sub(2), 16))
      return ctx.smart_open(p)
    end
    items, cols, sel = SM.fx_letters()
    title = 'command  ' .. where
    pick = function(it) return vals(it.v, nil) end
  end
  return ctx.smart_open({ title = title, items = items, cols = cols, sel = sel, on_pick = pick, on_sel = listen, cell_rows = crows, cell_w = cellw })
end

-- поле инструмента есть, если в раскладке есть колонка номера (не узкая колонка)
-- 11 окт: старт по сетке — ближайшая клетка q строк к дробной строке rf, строго после cur
function V.slq_snap(rf, q, cur)
  local r = math.floor(rf / q + 0.5) * q
  while r <= cur do r = r + q end
  return r
end
-- 11 окт: строка следующего события (голова ноты / item) в подколонке ниже row — новая нота обрывается на ней
function V.next_event_row(sub, row)
  local best
  for r, cell in pairs(sub or {}) do
    if r > row and (cell.kind == 'audio' or cell.kind == 'midi') and (not best or r < best) then best = r end
  end
  return best
end
function V.slc_field_ok()
  if not V.inst_field_ok() then return false end
  local f = flat()[V.cur.fi]
  local G = f.G or ctx.layout()
  return G.x_slc and not G.notes_only and true or false
end
function V.inst_field_ok()
  local f = flat()[V.cur.fi]
  if not f or f.env or f.compact or f.folded then return false end
  local G = f.G or ctx.layout()
  return G.x_inst and true or false   -- 11 окт: false у узких подколонок — поля нет
end

V.ensure_visible = ensure_visible   -- курсор в окне (9 окт: вкладка video)

return V
