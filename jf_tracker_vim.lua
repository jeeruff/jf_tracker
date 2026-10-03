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

-- строк, на сколько двигать курсор после вставки инструмента e (слайс k)
local function adv_rows(e, k)
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
  if f.env then return f.compact and 1 or 2 end   -- огибающая: значение, форма сегмента (свёрнутый — только значение)
  if f.compact then return 1 end           -- свёрнутый трек: только нота
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
local function motion(c, n)
  local cur = V.cur
  local last = ctx.snap().last_row or 0
  local L = ctx.layout()
  if c == ('j'):byte() or c == DOWN then return { fi = cur.fi, row = cur.row + n, linewise = true }
  elseif c == ('k'):byte() or c == UP then return { fi = cur.fi, row = math.max(0, cur.row - n), linewise = true }
  elseif c == ('h'):byte() or c == LEFT then local fi, fld = step_field(-1, n); return { fi = fi, row = cur.row, field = fld }
  elseif c == ('l'):byte() or c == RIGHT then local fi, fld = step_field(1, n); return { fi = fi, row = cur.row, field = fld }
  elseif c == ('H'):byte() or c == ('L'):byte() then
    local F = flat(); local f = F[cur.fi]; if not f then return nil end
    local ci = f.ci + (c == ('H'):byte() and -n or n)
    for i, g in ipairs(F) do if g.ci == ci then return { fi = i, row = cur.row } end end
    return { fi = c == ('H'):byte() and 1 or nflat(), row = cur.row }
  elseif c == ('w'):byte() or c == ('b'):byte() then
    -- w / b — только своя подколонка
    local r = cur.row
    local dir = c == ('w'):byte() and 1 or -1
    for _ = 1, n do r = next_head(cur.fi, r, dir, false) or r end
    return { fi = cur.fi, row = r, exclusive = dir > 0 or nil, linewise = true }
  elseif c == ('W'):byte() or c == ('B'):byte() then
    local fi, r = cur.fi, cur.row
    local dir = c == ('W'):byte() and 1 or -1
    for _ = 1, n do
      local nfi, nr = next_any(fi, r, dir)
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
  local heads = V.heads_in(f0, f1, r0, r1)
  local edited = true
  if op == 'd' or op == 'x' or op == 'c' then
    V.regs['"'] = E.yank(heads, lpb(), r0, f0)
    E.delete(heads, lpb())
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
    if fld == 1 then E.transpose(heads, lpb(), d)
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
    if not FX_LETTERS[ch] then return false end
    V.hexbuf = ch; return false
  end
  if not is_hex then return false end
  buf = buf .. ch
  local need = fld >= 4 and 3 or 2
  if #buf < need then V.hexbuf = buf; return false end
  V.hexbuf = nil
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

local function replay(keys)
  if V.replaying > 8 then return end
  V.replaying = V.replaying + 1
  for _, k in ipairs(keys) do V.key(k) end
  V.replaying = V.replaying - 1
end

-- ── пианино ───────────────────────────────────────────────────────────────
local function piano_pitch(c)
  local off = ctx.piano[c]
  if off == nil then return nil end
  return (V.octave + 1) * 12 + off
end

-- ── командная строка ──────────────────────────────────────────────────────
-- Таблица команд: исполнение, подсказка (список снизу при наборе) и Tab.
V.COMMANDS = {
  { 'q', '', 'close window' }, { 'w', '', 'save project' }, { 'wq', '', 'save and close' },
  { 'lpb', 'N', 'rows per beat (1..64)' }, { 'step', 'N|auto', 'step after input / note length' },
  { 'oct', 'N', 'input octave' }, { 'inst', 'N', 'instrument slot' },
  { 'fx', 'N', 'fx command columns (0..4)' }, { 'env', '', 'envelope columns' },
  { 'scale', 'N', 'bitmap scale x1..3 (Ctrl +/- too); x4 is kept for PT-mode' }, { 'options', '', 'all options in one window' }, { 'about', '[logo]', 'version, changes and the logo (a name part picks it: marquee, rubble, plum …)' }, { 'theme', 'name', 'reaper (native) | modus-vivendi | modus-operandi | gruvbox | catppuccin | mono' }, { 'name', 'text', 'matrix: rename the cursor region' }, { 'len', 'N|Ns|Nb', 'matrix: cursor region length - N steps (LPB), Ns seconds, Nb bars; later regions and items ripple' }, { 'add', '[bars] [name]', 'matrix: new region after the last one, from the next bar (+)' }, { 'space', 'N', 'gap above letters, px' }, { 'tab', 'item|modulate|midi|grid|retro|orca|master', 'top panel tab' }, { 'scopemode', '[scope|spec|sgram]', 'analyzer: scope / spectrum / spectrogram' }, { 'retro', '[add]', 'retro sampler tab; add = jf_rec on cursor track' }, { 'top', '', 'top panel' }, { 'meters', '', 'peak meters over columns (PT style)' }, { 'wave', '[column|note|off]', 'wave: own column (spectral peaks + stretch markers) / in the note field / off' }, { 'xfade', '[on|off|now|ms]', 'x-fade of inserted notes: on/off, crossfade now, length ms' }, { 'mxzoom', '', 'matrix: schema <-> detail' }, { 'scopes', '', 'scopes: JSFX bridge on tracks on/off' }, { 'dsp', '', 'bottom DSP panel (track fx)' }, { 'punch', '', 'punch: time selection = cursor region, auto-punch' }, { 'recmode', '', 'record mode (hydra)' }, { 'lanes', '', 'cursor track: fixed lanes on/off' },
  { 'rec', '', 'record arm cursor track' }, { 'input', '', 'choose record input (hydra)' }, { 'smartin', '', 'most active input (jf_smart_set_input)' }, { 'slice', '', 'slice instrument (virtual)' },
  { 'poolprev', '', 'preview instrument on select' }, { 'side', '', 'sidebar browser' }, { 'curscope', '', 'cursor line = oscilloscope, cursor fixed in the centre' },
  { 'browse', 'path', 'browser root' }, { 'dock', '', 'dock <-> fullscreen (F11)' }, { 'preview', '', 'preview on input' },
  { 'pitchmode', 'shift|resample', 'track pitch mode' },
  { 'sync', '', 'sync same-name regions' }, { 'autosync', '', 'sync after edits' },
  { 'follow', '', 'view follows playhead' }, { 'lock', '', 'tracker cursor = REAPER edit cursor and selected track' }, { 'fixed', '', 'cursor fixed at screen centre (Impulse Tracker)' }, { 'debug', '', 'fps and key codes' },
  { 'fold', '', 'fold all tracks' }, { 'unfold', '', 'unfold all' },
  { 'trim', '', 'trim items to region bounds (strict patterns)' },
  { 'beatsync', '[beat|bar|N]', 'stretch event end to the nearest beat / bar / N rows (= key, N=)' },
  { 'quantize', '', 'smart quantize the instrument: loud transients to beats, soft to 16ths, length to whole bars / beats (stretch markers)' },
  { 'tname', 'text', 'rename the cursor track (dblclick on the track name)' },
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
  elseif cmd == 'step' and arg == 'auto' then V.step_auto = not V.step_auto; V.msg = 'step: ' .. (V.step_auto and 'auto (to the end of the inserted item / slice)' or tostring(V.step))
  elseif cmd == 'step' and n then V.step = math.max(0, math.floor(n)); V.step_auto = false
  elseif cmd == 'oct' and n then V.octave = math.max(0, math.min(8, math.floor(n)))
  elseif cmd == 'inst' and n then ctx.pool_select(math.floor(n))
  elseif cmd == 'follow' then st.follow = not st.follow
  elseif cmd == 'debug' then st.debug = not st.debug
  elseif cmd == 'fold' then ctx.fold_all(true)
  elseif cmd == 'unfold' then ctx.fold_all(false)
  elseif cmd == 'fx' and n then st.fxcols = math.max(0, math.min(4, math.floor(n)))
  elseif cmd == 'env' then st.envs = not st.envs
  elseif cmd == 'preview' then st.preview = not st.preview; V.msg = 'preview ' .. (st.preview and 'on' or 'off')
  elseif cmd == 'pitchmode' then
    local f = flat()[V.cur.fi]
    if f and (arg == 'shift' or arg == 'resample') then ctx.set_pitchmode(f.col, arg); V.msg = f.col.name .. ': ' .. arg
    else V.msg = ':pitchmode shift|resample' end
  elseif cmd == 'font' or cmd == 'nerd' or cmd == 'fontface' or cmd == 'face' or cmd == 'hybrid' then
    -- TTF и Nerd-иконки убраны (3 окт): только битмап REAPER, масштаб :scale 1..3
    V.msg = 'TTF fonts and icons are gone - bitmap only (:scale 1..3, Ctrl +/-)'
  elseif cmd == 'scale' and n then local k = math.max(1, math.min(3, math.floor(n))); ctx.set_scale(k); V.msg = 'bitmap x' .. k .. (n > 3 and ' (x4 is kept for PT-mode)' or '')
  elseif cmd == 'space' and n then ctx.set_space(math.max(0, math.min(12, math.floor(n)))); V.msg = 'space ' .. math.floor(n)
  elseif cmd == 'tab' then
    -- вкладка item — бывшая sample (:tab sample убран, 3 окт); orca — бывшая garden
    if arg == 'sample' then V.msg = 'tab: item (the old sample tab)'; return end
    local a = (arg == 'mod' or arg == 'modulate') and 'modulation' or ((arg == 'item') and 'sample' or ((arg == 'orca') and 'garden' or arg))
    st.toptab = (a == 'sample' or a == 'modulation' or a == 'midi' or (a == 'grid' and st.gridtab) or a == 'retro' or a == 'garden') and a or 'master'
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
  elseif cmd == 'iname' then ctx.rename_inst(arg)
  elseif cmd == 'garden' or cmd == 'orca' then ctx.garden_cmd(arg ~= '' and arg or 'show')
  elseif cmd == 'midi' then st.top = true; st.toptab = 'midi'; if ctx.set_focus then ctx.set_focus('top') end
  elseif cmd == 'loops' then if ctx.mx_loops_toggle then ctx.mx_loops_toggle() end
  elseif cmd == 'vel' and n then V.vel = math.max(1, math.min(127, math.floor(n))); V.msg = 'velocity ' .. V.vel
  elseif cmd == 'loop' then
    if n then ctx.loop('item', math.max(1, math.floor(n)))
    elseif arg == 'region' or arg == 'off' then ctx.loop(arg)
    else ctx.loop('item') end
  elseif cmd == 'options' or cmd == 'opt' then ctx.options()
  elseif cmd == 'about' then ctx.about(arg)
  elseif cmd == 'theme' then
    if arg and arg ~= '' then if ctx.apply_theme(arg) then V.msg = 'theme: ' .. arg end else V.msg = 'themes: reaper modus-vivendi modus-operandi gruvbox catppuccin mono' end
  elseif cmd == 'name' then ctx.mx_name(arg)
  elseif cmd == 'len' then ctx.mx_len(arg)
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
  elseif cmd == 'dsp' then ctx.toggle_dsp()
  elseif cmd == 'punch' then ctx.punch()
  elseif cmd == 'recmode' then V.open_hydra(ctx.hydra_recmode())
  elseif cmd == 'lanes' then ctx.toggle_lanes()
  elseif cmd == 'rec' then ctx.rec_arm()
  elseif cmd == 'input' then V.open_hydra(ctx.hydra_inputs())
  elseif cmd == 'smartin' then ctx.smart_input()
  elseif cmd == 'slice' then ctx.open_slicer()
  elseif cmd == 'poolprev' then st.poolprev = not st.poolprev; V.msg = 'pool preview ' .. (st.poolprev and 'on' or 'off')
  elseif cmd == 'side' then st.side = not st.side
  elseif cmd == 'curscope' then ctx.set_curline(st.curline == 'scope' and 'top' or 'scope')
    V.msg = 'curscope ' .. (st.curline == 'scope' and ('on (cursor fixed in the centre)' .. (st.scopes and '' or ' - turn track scopes on to see the signal')) or 'off')
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
    if m then V.cur.fi, V.cur.row = m.fi, m.row; if m.field then V.cur.field = m.field end; clamp_cur(); ensure_visible() end
    V.count = nil; V.hexbuf = nil; return true
  elseif ch == 'g' then V.cur.row = 0; ensure_visible(); return true
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
  elseif ch == 'a' then V.step_auto = not V.step_auto; V.msg = 'step: ' .. (V.step_auto and 'auto' or tostring(V.step)); return true
  elseif ch == 's' then V.cmd_from = 'insert'; V.mode = 'cmd'; V.cmdline = 'step '; return true
  elseif ch == 'd' then
    -- d — оператор Vim (d3w, dd, dG…): ждёт счётчик и движение, потом обратно в INSERT (2 окт)
    V.mode = 'normal'; V.pending = 'd'; V.count = nil; V.back_insert = true; V.hexbuf = nil; return true
  elseif ch == 'M' then local hs = heads(); if #hs > 0 then ctx.edit.mute(hs, lpb()); finish_edit() end; return true   -- mute — Shift+m (3 окт)
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
                [710] = 'i', [248] = 'o', [960] = 'p', [8482] = '2', [163] = '3', [8734] = '5', [167] = '6',
                [182] = '7', [170] = '9', [186] = '0' }
function V.note_key(c, mods)
  mods = mods or {}
  -- Cmd (3 окт): нота с удержанием — длина = сколько держали (+ j / ↓ шаги);
  -- Cmd+Shift — то же, но сэмпл растягивается на эту длину
  if mods.cmd then
    local base = (c >= 1 and c <= 26) and (c + 96) or c
    local cb = (base < 256) and string.char(base) or ''
    if SHIFTED[cb] then base = SHIFTED[cb]:byte() elseif cb:match('^[QWERTYUIOP]$') then base = cb:lower():byte() end
    return base, mods.shift and 'hold_stretch' or 'hold'
  end
  local ch = (c < 256) and string.char(c) or ''
  if OPTCH[c] then return OPTCH[c]:byte(), 'beside' end
  if mods.ctrl and c >= 1 and c <= 26 then return c + 96, 'capture' end
  if SHIFTED[ch] then return SHIFTED[ch]:byte(), 'audition' end
  if ch:match('^[QWERTYUIOP]$') then return ch:lower():byte(), 'audition' end
  if mods.ctrl then return c, 'capture' end
  if mods.alt then return c, 'beside' end
  if mods.shift then return c, 'audition' end
  return c, 'insert'
end

function V.key_impl(c)
  if c <= 0 then return end
  local E = ctx.edit
  local st = ctx.state
  local n = V.count or 1

  -- слайсер (оверлей) перехватывает всё
  if ctx.slicer_active and ctx.slicer_active() then ctx.slicer_key(c); return end
  -- fzf-пикер перехватывает всё
  if V.picker then V.picker_key(c); return end
  -- hydra перехватывает всё
  if V.hydra then V.hydra_key(c); return end

  -- командная строка (+ подсказка и Tab-дополнение)
  if V.mode == 'cmd' then
    local back = (V.cmd_from == 'insert') and 'insert' or 'normal'
    if c == ESC then V.mode = back; V.cmdline = nil; V.cmd_cycle = nil
    elseif c == ENTER then
      local line = V.cmdline or ''
      V.mode = back; V.cmdline = nil; V.cmd_cycle = nil
      return run_cmd(line)
    elseif c == TAB then
      local matches, word = V.cmd_matches(V.cmdline)
      if #matches > 0 then
        V.cmd_cycle = ((V.cmd_cycle or 0) % #matches) + 1
        local m = matches[V.cmd_cycle]
        V.cmdline = m[1] .. (m[2] ~= '' and ' ' or '')
      end
    elseif c == BS then V.cmdline = (V.cmdline or ''):sub(1, -2); V.cmd_cycle = nil
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
                 [729] = 'h', [8710] = 'j', [730] = 'k', [172] = 'l' }
  -- ⌘+цифра — слот пула (1..9, 0 = 10) в любом режиме
  if mods.cmd and c >= ('0'):byte() and c <= ('9'):byte() and V.mode ~= 'cmd' and V.mode ~= 'search'
     and not ((V.mode == 'insert' or V.piano) and ctx.piano[c]) then      -- в INSERT / слое пианино ⌘+цифра — нота с удержанием
    local k = c - ('0'):byte(); if k == 0 then k = 10 end
    if ctx.pool_select then ctx.pool_select(k) end
    V.count = nil; return
  end
  local hk = HJKL[c]
  if hk and (mods.ctrl or mods.alt or mods.cmd) and V.mode ~= 'cmd' and V.mode ~= 'search' then
    if mods.ctrl then
      local dx, dy = 0, 0
      if hk == 'h' then dx = -1 elseif hk == 'l' then dx = 1 elseif hk == 'j' then dy = 1 elseif hk == 'k' then dy = -1 end
      if ctx.matrix_move then ctx.matrix_move(dx * n, dy * n) end
    elseif mods.cmd then
      if ctx.pool_select then ctx.pool_select(V.inst + ((hk == 'j' or hk == 'l') and n or -n)) end
    else
      local t
      if hk == 'h' then t = motion(('H'):byte(), n) elseif hk == 'l' then t = motion(('L'):byte(), n)
      elseif hk == 'j' then t = motion(('W'):byte(), n) else t = motion(('B'):byte(), n) end
      if t then V.cur.fi, V.cur.row = t.fi, t.row; clamp_cur(); ensure_visible() end
    end
    V.count = nil; return
  end

  -- лидер \ — hydra действий (контекстное меню с клавиатуры), ? — шпаргалка
  if c == ('\\'):byte() and not (V.mode == 'insert' and (env_of(V.cur.fi) or (V.cur.field or 1) == 2)) then
    V.open_hydra(ctx.hydra_root()); return   -- в INSERT на огибающей / vol `\` — макрос спада
  end

  record(c)

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
    local m = motion(c, 1)
    if m and (c == UP or c == DOWN or c == LEFT or c == RIGHT or c == PGUP or c == PGDN or c == HOME or c == END) then
      V.cur.fi, V.cur.row = m.fi, m.row
      if m.field then V.cur.field = m.field end
      V.hexbuf = nil; clamp_cur(); ensure_visible(); return
    end
    if c == 32 then E.play_stop(); return end
    local fld = V.cur.field or 1
    local env = env_of(V.cur.fi)
    if (c == 62 or c == 60) and fld == 1 and not env then ctx.loop(c == 62 and 'item' or 'region'); return end
    if env and fld == 2 and nfields() >= 2 then
      -- поле формы: буквы сокращения (lin sqr slo fas fae bez) → форма точки строки
      local lc = (c < 256) and string.char(c):lower() or ''
      if c == ESC then V.shapebuf = nil
      elseif lc:match('^[a-z]$') then
        local buf = (V.shapebuf or '') .. lc
        local m = V.shape_match(buf)
        if m == false then V.shapebuf = nil; V.msg = 'shape: lin sqr slo fas fae bez'
        elseif m == nil then V.shapebuf = buf; V.msg = 'shape ' .. buf .. '…'
        else V.shapebuf = nil; ctx.env_shape(env, V.cur.row, m); V.cur.row = V.cur.row + V.step; ensure_visible() end
      end
      return
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
      if ch:match('^[0-9A-F]$') then
        local buf = (V.hexbuf or '') .. ch
        if #buf < 2 then V.hexbuf = buf; return end
        V.hexbuf = nil
        ctx.env_set(env, V.cur.row, tonumber(buf, 16) / 255)
        V.cur.row = V.cur.row + V.step; ensure_visible()
      end
      return
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
    if fld > 1 then
      -- поля vol / delay / команд: hex-ввод, потом шаг вниз; не-hex → управление KEYS
      local heads = V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row)
      if hex_entry(c, fld, heads) then V.cur.row = V.cur.row + V.step; ensure_visible(); return end
      if V.hexbuf then return end
      keys_control(c); return
    end
    if keys_control(c) then return end
    if c == ('`'):byte() or c == ('~'):byte() then
      E.note_off(V.covering(V.cur.fi, V.cur.row), lpb(), V.cur.row)
      V.cur.row = V.cur.row + V.step; ensure_visible(); return
    end
    if c == ('['):byte() then V.octave = math.max(0, V.octave - 1); return end
    if c == (']'):byte() then V.octave = math.min(8, V.octave + 1); return end
    -- модификатор ноты (2 окт): Shift — только прослушать, Option — вставить
    -- рядом (новая подколонка), Ctrl — захват звука канала (F5, пока прослушка)
    local how, mods = 'insert', (ctx.mods and ctx.mods() or {})
    c, how = V.note_key(c, mods)
    -- нарезанный инструмент: верхний ряд q..p = слайсы 1..10
    local f0 = flat()[V.cur.fi]
    local inst0 = f0 and (f0.col.pool or {})[V.inst]
    local UP = { q = 1, w = 2, e = 3, r = 4, t = 5, y = 6, u = 7, i = 8, o = 9, p = 10 }
    local chq = (c < 256) and string.char(c) or ''
    if inst0 and inst0.slices and #inst0.slices > 0 and UP[chq] then
      local k = UP[chq]
      local t0s = inst0.slices[k]
      if how == 'hold' or how == 'hold_stretch' then
        local lane = f0.lane or f0.col.lanes[1]
        if ctx.hold_start then ctx.hold_start({ track = f0.col.track, lane_idx = f0.col.fixed and lane.idx or nil, row = V.cur.row, slice = k,
          item = inst0.item, entry = inst0, vel = V.vel, stretch = how == 'hold_stretch', key = chq, replace = f0.sub and f0.sub[V.cur.row] }) end
        return
      end
      if how == 'audition' or how == 'capture' then
        if t0s and ctx.preview_slice then ctx.preview_slice(f0.col.track, inst0, t0s, inst0.slices[k + 1] or inst0.len) end
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
      local it = E.insert_slice(f0.col.track, f0.col.fixed and lane.idx or nil, lpb(), V.cur.row, inst0.item, k, tx)
      E.beside = false
      if st.preview and ctx.preview_slice and t0s then ctx.preview_slice(f0.col.track, inst0, t0s, inst0.slices[k + 1] or inst0.len) end
      if V.step_auto and it and E.item_end and E.row_of_time then
        local t_end = E.item_end(it)
        local r = math.max(V.cur.row + 1, (E.row_of_time(t_end, lpb())))   -- слайс короче строки — всё равно шаг
        V.stitch = { fi = V.cur.fi, row = r, t = t_end }
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
        if how == 'hold' or how == 'hold_stretch' then
          local chh = (c < 256) and string.char(c) or ''
          if ctx.hold_start then ctx.hold_start({ track = f.col.track, lane_idx = f.col.fixed and lane.idx or nil, row = V.cur.row, pitch = pitch,
            item = inst and inst.item, vel = V.vel, stretch = how == 'hold_stretch', key = chh, replace = f.sub and f.sub[V.cur.row] }) end
          return
        end
        -- Shift+нота — только звук; Ctrl+нота — захват (F5, пока звук)
        if how == 'audition' or how == 'capture' then
          if ctx.preview then ctx.preview(f.col.track, pitch, inst and inst.item, V.cur.row, V.step_auto and 1 or V.step) end
          if how == 'capture' then V.msg = 'Ctrl+note: capture of the channel output is planned (F5) - auditioned only' end
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
        E.insert_note(f.col.track, f.col.fixed and lane.idx or nil, lpb(), V.cur.row, pitch, V.vel, stp, inst and inst.item)
        E.beside = false
        if st.preview and ctx.preview then ctx.preview(f.col.track, pitch, inst and inst.item, V.cur.row, stp) end
        V.cur.row = V.cur.row + adv_rows(inst); ensure_visible()
      end
    end
    return
  end

  -- слой пианино в NORMAL (3 окт, как M в Ableton): m — вкл / выкл (mute — Shift+M); клавиши
  -- пианино (верхний ряд + цифры) звучат, Cmd+клавиша — нота с удержанием
  -- (Cmd+Shift — с растяжкой), остальное — обычные Vim-команды
  if V.mode == 'normal' and not V.pending and not V.op then
    if c == ('m'):byte() then
      V.piano = not V.piano
      V.msg = V.piano and 'piano on (m): top row plays, Cmd+note inserts with the held length, Cmd+Shift stretches' or 'piano off'
      return
    end
    if V.piano then
      if c == ESC then V.piano = false; V.msg = 'piano off'; return end
      local mods = ctx.mods and ctx.mods() or {}
      local base, how = V.note_key(c, mods)
      local f0 = flat()[V.cur.fi]
      local inst0 = f0 and (f0.col.pool or {})[V.inst]
      local chq = (base < 256) and string.char(base) or ''
      local UPK = { q = 1, w = 2, e = 3, r = 4, t = 5, y = 6, u = 7, i = 8, o = 9, p = 10 }
      local k = (inst0 and inst0.slices and #inst0.slices > 0) and UPK[chq] or nil
      local pitch = (not k) and piano_pitch(base) or nil
      if f0 and (k or pitch) then
        local lane = f0.lane or f0.col.lanes[1]
        if how == 'hold' or how == 'hold_stretch' then
          if ctx.hold_start then ctx.hold_start({ track = f0.col.track, lane_idx = f0.col.fixed and lane.idx or nil, row = V.cur.row, pitch = pitch, slice = k,
            item = inst0 and inst0.item, entry = inst0, vel = V.vel, stretch = how == 'hold_stretch', key = chq }) end
        elseif k then
          if ctx.preview_slice then ctx.preview_slice(f0.col.track, inst0, inst0.slices[k], inst0.slices[k + 1] or inst0.len) end
        elseif ctx.preview then ctx.preview(f0.col.track, pitch, inst0 and inst0.item, V.cur.row, 1) end
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
      if c == ('g'):byte() then
        local t = { fi = V.cur.fi, row = V.count and (n - 1) or 0, linewise = true }
        if V.op then
          local f0, f1, r0, r1 = range_or_event(V.op, t)
          local e = apply(V.op, f0, f1, r0, r1); V.op = nil; if e then finish_edit() else finish_move() end
        else V.cur.row = t.row; finish_move() end
        V.count = nil; ensure_visible(); return
      end
      V.count = nil; finish_move(); return
    elseif p == 'z' then
      local L = ctx.layout()
      if c == ('z'):byte() then st.row0 = math.max(0, V.cur.row - math.floor(L.nrows / 2))
      elseif c == ('t'):byte() then st.row0 = V.cur.row
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
      elseif c == ('M'):byte() then ctx.fold_all(true); ctx.relayout(); clamp_cur()
      elseif c == ('R'):byte() then ctx.fold_all(false); ctx.relayout(); clamp_cur()
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
      local pitch = piano_pitch(c)
      if pitch then
        local f0, f1, r0, r1 = V.cur.fi, V.cur.fi, V.cur.row, V.cur.row
        if V.mode == 'visual' or V.mode == 'vline' then f0, f1, r0, r1 = V.visual_range() end
        E.set_pitch(V.heads_in(f0, f1, r0, r1), lpb(), pitch)
        V.mode = 'normal'; finish_edit()
      else finish_move() end
      V.count = nil; return
    elseif p == 'q' then
      if c >= ('a'):byte() and c <= ('z'):byte() then V.macro = { name = string.char(c), keys = {} }; V.msg = 'recording @' .. string.char(c) end
      V.count = nil; finish_move(); return
    elseif p == '@' then
      local name = (c == ('@'):byte()) and V.last_macro or string.char(c)
      local keys = name and V.regs['@' .. name]
      if keys then V.last_macro = name; V.cmdbuf = {}; for _ = 1, n do replay(keys) end end
      V.count = nil; return
    elseif p == 'd' or p == 'y' or p == 'c' then
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
      if p == 'd' and c == ('t'):byte() then
        if ctx.clear_track() then finish_edit() else finish_move() end
        V.count = nil; return
      end
      local t = motion(c, n)
      if t then
        local f0, f1, r0, r1 = range_or_event(p, t)
        local e = apply(p, f0, f1, r0, r1)
        if e then finish_edit() else finish_move() end
      else finish_move() end
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
    V.cur.fi, V.cur.row = t.fi, t.row
    if t.field then V.cur.field = t.field end
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
  elseif ch == '/' then V.mode = 'search'; V.searchline = ''; V.count = nil; return
  elseif ch == 'n' then for _ = 1, n do V.find_next(1) end
  elseif ch == 'N' then for _ = 1, n do V.find_next(-1) end
  elseif ch == '*' then
    local h = V.covering(V.cur.fi, V.cur.row)[1]
    if h then V.search = h.name ~= '' and h.name or h.note; V.find_next(1) end
  elseif ch == '?' then V.open_hydra(ctx.hydra_keys())
  elseif ch == 'd' or ch == 'y' or ch == 'c' then V.pending = ch; return
  elseif ch == 'g' or ch == 'z' or ch == 'r' or ch == '@' then V.pending = ch; return
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
  elseif ch == 'x' then
    apply('x', V.cur.fi, V.cur.fi, V.cur.row, V.cur.row + n - 1); finish_edit()
  elseif ch == 'M' then                                  -- mute — Shift+m; m — слой пианино (3 окт)
    apply('m', V.cur.fi, V.cur.fi, V.cur.row, V.cur.row + n - 1); finish_edit()
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
  elseif c == ctrl('r') then E.redo(); finish_move()
  elseif ch == '.' then
    if V.last_edit then local keys = V.last_edit; V.cmdbuf = {}; for _ = 1, n do replay(keys) end end
  elseif ch == '[' then V.octave = math.max(0, V.octave - 1)
  elseif ch == ']' then V.octave = math.min(8, V.octave + 1)
  elseif ch == '(' then ctx.pool_select(V.inst - 1)
  elseif ch == ')' then ctx.pool_select(V.inst + 1)
  elseif ch == 'F' then st.follow = not st.follow
  elseif ch == ' ' then E.play_stop()
  elseif c == ENTER then E.cursor_to(ctx.row_time(V.cur.row))
  elseif c == TAB then ctx.toggle_focus()
  elseif c == ESC then V.count = nil; finish_move()
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
function V.open_hydra(h)
  V.hydra = h; V.hydra_stack = {}
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
        V.hydra = type(it.sub) == 'function' and it.sub() or it.sub
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
    local first = math.max(1, pk.sel - 13)
    for i = first, math.min(#pk.matches, first + 13) do
      lines[#lines + 1] = { key = (i == pk.sel) and '>' or ' ', text = pk.matches[i].label }
    end
    return { title = pk.title .. ' > ' .. pk.query .. '_' .. ('  (%d)'):format(#pk.matches), lines = lines, kind = 'picker', hl = pk.sel - first + 1 }
  elseif V.hydra then
    local lines = {}
    for _, it in ipairs(V.hydra.items or {}) do
      lines[#lines + 1] = { key = it.key, text = it.label .. (it.sub and ' …' or '') }
    end
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

function V.visual_range()
  local a, b = V.anchor or V.cur, V.cur
  local f0, f1 = math.min(a.fi, b.fi), math.max(a.fi, b.fi)
  if V.mode == 'vline' then f0, f1 = 1, nflat() end
  return f0, f1, math.min(a.row, b.row), math.max(a.row, b.row)
end

-- подсказка продолжений ожидающего оператора — справа в строке статуса
-- (просьба 2 окт: нажал d — видно, что можно дальше)
local PENDING_HINT = {
  d = 'd: d rows | w event | W whole item | t track in region | j k rows | G to end | gg to start | } { bar | $ fields | 3w count | Esc',
  y = 'y: y rows | w event | j k rows | G to end | gg to start | } { bar | 3j count | Esc',
  c = 'c: c rows (replace) | w event | j k rows | } { bar | Esc',
  g = 'g: g first row | Esc',
  z = 'z: a fold track | c close | o open | f folder | M fold all | R open all | z center | t top | b bottom',
  r = 'r: note key sets pitch | hex digits set field | Esc',
  q = 'q: a..z record macro into register',
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
  local m = ({ normal = '', insert = '-- INSERT --', visual = '-- VISUAL --', vline = '-- V-LINE --',
               cmd = ':' .. (V.cmdline or ''), search = '/' .. (V.searchline or '') })[V.mode] or ''
  local extra = ''
  if V.macro then extra = ' rec@' .. V.macro.name end
  if V.pending then extra = extra .. ' ' .. V.pending end
  if V.hexbuf then extra = extra .. ' [' .. V.hexbuf .. '_]' end
  if V.count then extra = extra .. ' ' .. V.count end
  return m .. extra, ('oct %d vel %d step %s inst %d'):format(V.octave, V.vel or 100, V.step_auto and 'auto' or tostring(V.step), V.inst)
end

-- обёртка: оператор, начатый из INSERT (d…), по завершении возвращает в INSERT
function V.key(c)
  local p0 = V.cur.fi * 1e6 + V.cur.row * 10 + (V.cur.field or 1)
  local r = V.key_impl(c)
  -- набор сокращения формы живёт только на месте: курсор ушёл — сброс (ревью 2 окт)
  if V.shapebuf and (V.cur.fi * 1e6 + V.cur.row * 10 + (V.cur.field or 1)) ~= p0 then V.shapebuf = nil end
  if V.mode ~= 'insert' then V.shapebuf = nil end
  if V.back_insert and not V.pending and not V.op then
    if V.mode == 'normal' then V.mode = 'insert' end
    V.back_insert = nil
  end
  return r
end

return V
