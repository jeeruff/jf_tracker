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

local TX = dofile((debug.getinfo(1, 'S').source:match('^@(.*/)') or './') .. 'jf_tracker_utf8.lua')   -- 20 окт: набор Юникодом (кириллица)
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
local function adv_rows(e, k, tr, pitch)
  -- 25 окт: нота играет слайс сэмплера (пэд drumrs5k / RS5K с этой нотой) — next и auto шагают на длину слайса
  if (V.step_next or V.step_auto) and tr and pitch and ctx.note_slice_secs and ctx.edit and ctx.edit.row_time then
    local secs = ctx.note_slice_secs(tr, pitch)
    local lp = ctx.state.lpb or 4
    local rs = ctx.edit.row_time(V.cur.row + 1, lp, 0) - ctx.edit.row_time(V.cur.row, lp, 0)
    if secs and secs > 0 and rs > 0 then return math.max(1, math.floor(secs / rs + 0.5)) end
  end
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
  if f.env then   -- огибающая: значение, форма сегмента (свёрнутый — только значение)
    -- 20 окт: узкая колонка (мастер — числами) — формы нет: курсор поля формы рисовался в соседней колонке строкой ниже
    local Lx = ctx.layout()
    if f.compact or (f.w and Lx and Lx.env_w and f.w < Lx.env_w) then return 1 end
    return 2
  end
  if f.compact then return (f.G and f.G.nfields) or 1 end   -- свёрнутый трек: только нота (21 окт: свёрнутый MIDI — нота и vol)
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
      -- 20 окт: с последнего поля вправо — сложенный мастер раскрывается (auto / fold), курсор идёт в него
      if fi >= nflat() and dir > 0 and ctx.master_peek and ctx.master_peek() then end
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
-- 29 окт: OFF с задержкой в прямоугольнике → { { cell, row } … }
function V.offs_in(f0, f1, r0, r1)
  local F, out = flat(), {}
  if f0 > f1 then f0, f1 = f1, f0 end
  if r0 > r1 then r0, r1 = r1, r0 end
  for fi = f0, f1 do
    local f = F[fi]
    if f then
      for _, sub in ipairs(subs_of(f)) do
        for r = r0, r1 do
          local c = sub[r]
          if c and c.kind == 'off' and c.of and (c.delay or 0) > 0 then out[#out + 1] = { cell = c, row = r } end
        end
      end
    end
  end
  return out
end
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
          if c and c.fold then for _, h in ipairs(c.fold) do if not seen[h] then seen[h] = true; h.fi = fi; out[#out + 1] = h end end end   -- 19 окт: сложенные (fold) — тоже ноты строки
        end
      end
    end
  end
  return out
end

-- 20 окт: zu — раскрыть сложенное (fold): группы времён (в долях) сложенных нот строк выделения
-- (v / V) или строки курсора → main подбирает наименьший LPB, где они встают в свои строки (до 128);
-- ещё раз — прежний LPB
function V.unfold_zoom()
  if not ctx.unfold_zoom then return end
  if ctx.state.lpb_before_unfold then return ctx.unfold_zoom(nil) end
  local r0, r1 = V.cur.row, V.cur.row
  if (V.mode == 'visual' or V.mode == 'vline') and V.anchor then r0, r1 = math.min(V.anchor.row, V.cur.row), math.max(V.anchor.row, V.cur.row) end
  local lpb = ctx.state.lpb or 4
  local function qn(h) return ((h.row0 or 0) + (h.delay or 0) / 256) / lpb end
  local groups = {}
  for _, f in ipairs(flat()) do
    if not f.env then
      for _, sub in ipairs(subs_of(f)) do
        for r = r0, r1 do
          local c = sub[r]
          if c and c.fold then
            local g = {}
            if is_head(c) and c.row0 then g[1] = qn(c) end
            for _, h in ipairs(c.fold) do g[#g + 1] = qn(h) end
            groups[#groups + 1] = g
          end
        end
      end
    end
  end
  return ctx.unfold_zoom(groups)
end

-- события, накрывающие строку (голова, cont или off на этой строке)
-- 13 окт: пустой MIDI-клип, что начинается в строке row колонки fi (рисуется «#») → item
function V.empty_midi_at(fi, row)
  local f = flat()[fi]
  if not (f and f.col and not f.env and not f.ml) then return nil end
  local lane = f.lane or f.col.lanes[1]
  for _, it in ipairs(lane and lane.items or {}) do
    if math.floor(it.r0 + 1e-6) <= row and row < math.max(it.r1, math.floor(it.r0 + 1e-6) + 1) - 1e-6 then   -- строка внутри клипа (крошечный — его строка)
      if it.empty then return it.item end   -- пустой клип
      -- 19 окт: клип без видимых нот (ноты за его концом, клип в строку) — тоже удаляется dw / x
      local a0, a1 = math.floor(it.r0 + 1e-6), math.max(math.floor(it.r0 + 1e-6), math.ceil(it.r1 - 1e-6) - 1)
      if #V.heads_in(fi, fi, a0, a1) == 0 then return it.item end
    end
  end
end
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

-- 12 окт: команды строки — у каждой строки свои. Голова ноты, смещение строки от её начала
-- (четверти) и команды этой строки: первая строка — head.fx, строка внутри — fx ячейки продолжения
function V.fx_cell(fi, row)
  local f = flat()[fi]
  if not f then return nil end
  for _, sub in ipairs(subs_of(f)) do
    local c = sub[row]
    if c and (c.kind == 'audio' or c.kind == 'midi') then return { head = c, off = 0, fx = c.fx or {} } end
    if c and c.kind == 'cont' and c.of then
      local h = c.of
      -- 21 окт: и у MIDI-ноты своя команда строки (смещение от её начала; было — всегда первая строка)
      return { head = h, off = (row - (h.row0 or row)) / lpb(), fx = c.fx or {}, run = c.run, midi = h.kind == 'midi' or nil }
    end
  end
  return nil
end
-- 12 окт: что стоит в слоте i команд строки — своя команда или бледная (действует со строк выше);
-- бледные встают в пустые слоты по порядку, как их рисует draw
function V.fx_slot(fi, row, i)
  local fc = V.fx_cell(fi, row)
  if not fc then return nil end
  if fc.fx[i] then return fc.fx[i], false, fc end
  local j = 1
  for k = 1, i - 1 do if not fc.fx[k] then j = j + 1 end end
  local r = fc.run and fc.run[j]
  return r, r ~= nil, fc
end
-- 12 окт: стоп действующих команд строки — по 00 на каждый род (одна отмена)
function V.fx_stop(fi, row)
  local fc = V.fx_cell(fi, row)
  if not fc or fc.midi or not fc.run or #fc.run == 0 then
    V.msg = 'nothing runs here to stop (` stops a command that goes on from the rows above)'
    return false
  end
  local E = ctx.edit
  local codes = {}
  for _, t in ipairs(fc.run) do codes[#codes + 1] = t:sub(1, 2) end
  local function put() for _, code in ipairs(codes) do E.set_fx({ fc.head }, lpb(), code, 0, fc.off) end end
  if E.run then E.run('fx stop', put) else put() end
  V.msg = 'stop: ' .. table.concat(codes, '00 ') .. '00'
  return true
end
-- 13 окт: продолжение команды (Ctrl+Option + / -): ближайшая своя команда выше в этом слоте —
-- в строку курсора та же команда со значением ±1 (громкость — поле громкости ±1), курсор на шаг
function V.fx_continue(d)
  local fi, fld = V.cur.fi, V.cur.field or 1
  local E = ctx.edit
  if fld == 2 then
    local hs = V.heads_in(fi, fi, V.cur.row, V.cur.row)
    local prev
    for r = V.cur.row - 1, math.max(0, V.cur.row - 512), -1 do local h = V.heads_in(fi, fi, r, r)[1]; if h and h.vol and tonumber(h.vol, 16) then prev = tonumber(h.vol, 16); break end end
    if not (prev and #hs > 0) then V.msg = 'continue: a note on this row and one with a volume above'; return end
    E.set_vol(hs, lpb(), math.max(0, math.min(255, prev + d))); V.msg = ('continue: vol %02X'):format(math.max(0, math.min(255, prev + d)))
  elseif fld >= 4 then
    local code, xx
    for r = V.cur.row - 1, math.max(0, V.cur.row - 512), -1 do
      local t, pale = V.fx_slot(fi, r, fld - 3)
      if t and not pale then code, xx = t:sub(1, 2), tonumber(t:sub(3), 16); break end
    end
    local fc = V.fx_cell(fi, V.cur.row)
    if not (code and xx and fc) then V.msg = 'continue: a command above in this column and a note sounding here'; return end
    local nx = math.max(0, math.min(255, xx + d))
    E.set_fx({ fc.head }, lpb(), code, nx, V.fx_rowable(code) and fc.off > 0 and fc.off or nil)
    V.msg = ('continue: %s%02X'):format(code, nx)
  else V.msg = 'continue (Ctrl+Option + -): on the volume or a command column'; return end
  V.cur.row = V.cur.row + step_rows(); ensure_visible()
end
-- 22 окт: шаг курсора после записи не из клавиш (XY-пресет → автоматизация в INSERT)
function V.step_advance() V.cur.row = V.cur.row + step_rows(); ensure_visible() end
-- код живёт в строке (огибающая / генератор / песня) или у всей ноты (свойство item: 0S 0M 0P SI …)
-- 29 окт: пустой слот команды (поле курсора) внутри ноты — команда сверху в том же слоте той же ноты сюда; → true, если поставлена
function V.fx_prev_fill(fi, row, delta)   -- delta (30 окт, Ctrl+Opt+A / X) — сразу «сверху ± delta»
  local fld = V.cur.field or 1
  if fld < 4 then return false end
  local i = fld - 3
  local fc = V.fx_cell(fi, row)
  if not (fc and fc.head) or fc.fx[i] then return false end
  local code
  for r = row - 1, (fc.head.row0 or row) - 1, -1 do
    local f2 = V.fx_cell(fi, r)
    if not (f2 and f2.head == fc.head) then break end
    if f2.fx[i] then code = f2.fx[i]; break end
  end
  if not code or #code < 4 then return false end
  local cc = code:sub(1, 2)
  local off = (fc.off > 0 and V.fx_rowable(cc)) and fc.off or nil
  if fc.off > 0 and not off then V.msg = cc .. ' works on the note row only'; return false end
  local v = math.max(0, math.min(255, (tonumber(code:sub(3, 4), 16) or 0) + (delta or 0)))
  ctx.edit.set_fx({ fc.head }, lpb(), cc, v, off)
  V.msg = delta and ('%s%02X - the one above %+d'):format(cc, v, delta) or ('%s from above - Ctrl+A / X again changes it'):format(code)
  return true
end
function V.fx_rowable(code) return ctx.edit and ctx.edit.cmds and ctx.edit.cmds.CODES and ctx.edit.cmds.CODES[code] and true or false end

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

-- 16 окт: лейн (cmd / visor мастера, CC / PC …) — события в f.ml.ev[row]: w b e W B видят и их
local function ml_next(f, row, dir)
  local best
  for r in pairs(f.ml.ev or {}) do
    if (dir > 0 and r > row or dir < 0 and r < row) and (not best or (dir > 0 and r < best) or (dir < 0 and r > best)) then best = r end
  end
  return best
end

local function next_head(fi, row, dir, any_sub)
  local F = flat()
  local f = F[fi]
  if not f then return nil end
  if f.env then return env_next(f, row, dir) end
  if f.ml then return ml_next(f, row, dir) end
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
-- 18 окт: только внутри паттерна курсора (вне паттерна — не дальше 4 тактов): за его концом — шаг 1,
-- а не прыжок к объекту через 10 минут (мусор за песней уводил курсор на строку 6944)
function V.next_rows()
  local r = next_head(V.cur.fi, V.cur.row, 1, true)
  if not r then return 1 end
  local lim = ctx.pattern_end_row and ctx.pattern_end_row(V.cur.row)
  if not lim then lim = V.cur.row + 16 * ((ctx.state and ctx.state.lpb) or 4) end
  if r >= lim then return 1 end
  return math.max(1, r - V.cur.row)
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
      elseif f and f.ml then
        if (f.ml.ev or {})[r] then return i, r end
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
-- 13 окт: начало пустого MIDI-клипа (#) — тоже событие (w b W B, dw)
local function empty_start(f, r)
  if not (f and f.col) or f.env or f.ml then return false end
  local lane = f.lane or f.col.lanes[1]
  for _, it in ipairs(lane and lane.items or {}) do
    if math.floor(it.r0 + 1e-6) == r then
      if it.empty then return true end
      -- 22 окт: и клип без видимых нот (ноты за его концом) — как у x / dw (V.empty_midi_at): w b на нём встают
      local a0, a1 = r, math.max(r, math.ceil(it.r1 - 1e-6) - 1)
      local any = false
      for _, sub in ipairs(lane.subs or {}) do
        for rr = a0, a1 do local c = sub[rr]; if c and (c.kind == 'midi' or c.kind == 'audio' or c.kind == 'cont' or c.kind == 'off') then any = true; break end end
        if any then break end
      end
      if not any then return true end
    end
  end
  return false
end
local function track_event(f, r, strict)
  if f.env then return (not strict) and env_has(f, r) end
  if f.ml then return (not strict) and (f.ml.ev or {})[r] ~= nil end   -- 16 окт: события лейна (маркеры cmd, visor, CC) — для w b
  if f.folded then return false end
  for _, sub in ipairs(subs_of(f)) do if is_event(sub[r], strict) then return true end end
  return empty_start(f, r)
end
-- событие в одной подколонке (операторы dw / d2w — прямоугольник своей подколонки)
local function next_ev(fi, row, dir)
  local f = flat()[fi]
  if not f then return nil end
  if f.env then return env_next(f, row, dir) end
  if f.ml then return ml_next(f, row, dir) end
  local last = ctx.snap().last_row or 0
  local r = row + dir
  while r >= 0 and r <= last + 1 do
    for _, sub in ipairs(subs_of(f)) do if is_event(sub[r]) then return r end end
    if empty_start(f, r) then return r end
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
  if f.ml then return ml_next(f, row, 1) or row end      -- 16 окт: лейн — следующее событие
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
  -- 20 окт: подполе, которого у колонки больше нет (кит без Sxx, лейн без инструмента), — сброс,
  -- иначе l из «slc» вело на громкость той же колонки и курсор стоял на месте
  if (cur.sub == 'slc' and not V.slc_field_ok()) or (cur.sub == 'inst' and not V.inst_field_ok())
    or (cur.sub == 'wave' and not V.wave_field_ok()) or (cur.sub == 'pan' and not V.pan_field_ok()) then cur.sub = nil end
  local last = ctx.snap().last_row or 0
  local L = ctx.layout()
  if c == ('j'):byte() or c == DOWN then return { fi = cur.fi, row = cur.row + n, linewise = true }
  elseif c == ('k'):byte() or c == UP then return { fi = cur.fi, row = math.max(0, cur.row - n), linewise = true }
  -- 16 окт: колонка волны (режим column) — подполе слева от ноты: h с ноты — в волну, l — назад на ноту
  elseif (c == ('h'):byte() or c == LEFT) and n == 1 and (cur.field or 1) == 1 and not cur.sub and V.wave_field_ok() then
    return { fi = cur.fi, row = cur.row, field = 1, sub = 'wave' }
  elseif (c == ('l'):byte() or c == RIGHT) and n == 1 and cur.sub == 'wave' then
    return { fi = cur.fi, row = cur.row, field = 1 }
  elseif (c == ('h'):byte() or c == LEFT) and n == 1 and cur.sub == 'wave' then
    local fi, fld = step_field(-1, 1); return { fi = fi, row = cur.row, field = fld }
  -- 14 окт: колонка пана — подполе громкости: vol → pan → дальше; h с поля за ним — на пан
  elseif (c == ('l'):byte() or c == RIGHT) and n == 1 and (cur.field or 1) == 2 and cur.sub ~= 'pan' and V.pan_field_ok() then
    return { fi = cur.fi, row = cur.row, field = 2, sub = 'pan' }
  elseif (c == ('h'):byte() or c == LEFT) and n == 1 and (cur.field or 1) == 2 and cur.sub == 'pan' then
    return { fi = cur.fi, row = cur.row, field = 2 }
  elseif (c == ('l'):byte() or c == RIGHT) and n == 1 and (cur.field or 1) == 2 and cur.sub == 'pan' then
    local fi, fld = step_field(1, 1); return { fi = fi, row = cur.row, field = fld }
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
  -- 12 окт: поле команды — две половины, как в Renoise: слева код (0D), справа значение (12); l / h — по ним
  elseif (c == ('l'):byte() or c == RIGHT) and n == 1 and (cur.field or 1) >= 4 and cur.sub ~= 'val' then
    return { fi = cur.fi, row = cur.row, field = cur.field, sub = 'val' }
  elseif (c == ('h'):byte() or c == LEFT) and n == 1 and (cur.field or 1) >= 4 and cur.sub == 'val' then
    return { fi = cur.fi, row = cur.row, field = cur.field }
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
  elseif c == ('h'):byte() or c == LEFT then
    local fi, fld = step_field(-1, n)
    local sub = (fld or 1) >= 4 and 'val' or nil
    if fld == 2 and fi == cur.fi then local sv = V.cur; V.cur = { fi = fi, row = cur.row, field = 2 }; if V.pan_field_ok() then sub = 'pan' end; V.cur = sv end
    return { fi = fi, row = cur.row, field = fld, sub = sub }
  elseif c == ('l'):byte() or c == RIGHT then
    local fi, fld = step_field(1, n)
    -- 16 окт: в новую подколонку с колонкой волны — сперва на волну (как h с ноты): шаг линейки прыжков
    if fi ~= cur.fi and (fld or 1) == 1 then
      local sv = V.cur; V.cur = { fi = fi, row = cur.row, field = 1 }
      local w = V.wave_field_ok(); V.cur = sv
      if w then return { fi = fi, row = cur.row, field = 1, sub = 'wave' } end
    end
    return { fi = fi, row = cur.row, field = fld }
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
    -- 31 окт: в своей колонке: огибающая / лейн — следующая точка этой колонки; команда — следующая команда этой
    -- подколонки; нота и её поля (inst vol del) — следующая нота колонки. Поле курсора не меняется
    local f = flat()[fi]
    local fld = cur.field or 1
    if f and not f.folded then
      local last = ctx.snap().last_row or 0
      local function step(row)
        if f.env or f.ml then return next_head(fi, row, dir, false) end
        if fld >= 4 and V.fx_cell then
          local i = fld - 3
          local rr = row + dir
          while rr >= 0 and rr <= last + 1 do
            local fc = V.fx_cell(fi, rr)
            if fc and fc.fx and fc.fx[i] then return rr end
            rr = rr + dir
          end
          return nil
        end
        return nil, 'note'
      end
      if f.env or f.ml or fld >= 4 then
        local moved = false
        for _ = 1, n do local nr = step(r); if not nr then break end; r = nr; moved = true end
        if not moved then V.msg = dir > 0 and 'nothing further in this column' or 'nothing above in this column' end
        return { fi = fi, row = r, field = fld, linewise = true }
      end
      -- нота и её поля — следующая нота трека (любая его подколонка), без точек огибающих и событий лейнов
      for _ = 1, n do
        local nfi, nr = next_track(fi, r, dir, true)
        if not nfi then break end
        fi, r = nfi, nr
      end
      return { fi = fi, row = r, field = fld, linewise = true }
    end
    for _ = 1, n do
      local nfi, nr = next_track(fi, r, dir)
      if not nfi then break end
      fi, r = nfi, nr
    end
    return { fi = fi, row = r, field = 1, linewise = true }
  elseif c == ('W'):byte() or c == ('B'):byte() then
    -- 30 окт: W / B — следующее / предыдущее событие на ЛЮБОМ треке (нота, item, точка автоматизации, событие лейна);
    -- строки по порядку, в строке — слева направо (w / b — свой трек)
    local F = flat()
    local fi, r = cur.fi, cur.row
    local dir = c == ('W'):byte() and 1 or -1
    local last = ctx.snap().last_row or 0
    for _ = 1, n do
      local hit
      local rr, first = r, true
      while rr >= 0 and rr <= last + 1 and not hit do
        if dir > 0 then
          for i = 1, #F do if (not first or i > fi) and F[i] and not F[i].folded and track_event(F[i], rr, false) then hit = { i, rr }; break end end
        else
          for i = #F, 1, -1 do if (not first or i < fi) and F[i] and not F[i].folded and track_event(F[i], rr, false) then hit = { i, rr }; break end end
        end
        first = false; rr = rr + dir
      end
      if not hit then break end
      fi, r = hit[1], hit[2]
    end
    return { fi = fi, row = r, field = 1, exclusive = dir > 0 or nil, linewise = true }
  elseif c == ('e'):byte() then
    return { fi = cur.fi, row = event_end(cur.fi, cur.row), linewise = true, exclusive = true }   -- 19 окт: граница — строка после события, оператор её не берёт
  elseif c == ('E'):byte() then
    -- 15 окт: E — конец нижнего видимого события трека (последнее, что начинается на экране)
    local st = ctx.state
    local bottom = (st.row0 or 0) + L.nrows
    bottom = math.min(bottom, (ctx.snap().last_row or 0) + 2)   -- 16 окт: экран длиннее трека — поиск от конца содержимого (иначе nil, dE молчал)
    local r = next_ev(cur.fi, bottom, -1)
    if not r then return nil end
    return { fi = cur.fi, row = event_end(cur.fi, r), linewise = true, exclusive = true }
  elseif c == ('G'):byte() then
    -- 20 окт: gg proj/pat relative — в виде pattern G на последнюю строку паттерна
    if not V.count and ctx.state.ggrel and ctx.state.view_reg and ctx.region_rows then
      local _, r1 = ctx.region_rows(); if r1 then return { fi = cur.fi, row = r1, linewise = true } end
    end
    return { fi = cur.fi, row = V.count and (n - 1) or last, linewise = true }
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
  -- 24 окт: d / x на поле громкости, задержки, команды (одна колонка) — строго ячейка: очистить это поле у нот
  -- строк, ноты остаются (было: удалялось событие целиком)
  local fld = V.cur.field or 1
  if (op == 'd' or op == 'x') and f0 == f1 and fld >= 2 and V.cur.sub ~= 'inst' and V.cur.sub ~= 'wave' and V.mode ~= 'visual' and V.mode ~= 'vline' and V.field_set then
    if #heads == 0 then V.msg = 'nothing in this cell'; return false end
    E.run('clear the cell', function() for _, h in ipairs(heads) do V.field_set(h, fld, nil) end end)
    V.msg = ('cell cleared: %d'):format(#heads)
    return true
  end
  if op == 'd' or op == 'x' or op == 'c' then
    V.regs['"'] = E.yank(heads, lpb(), r0, f0)
    E.delete(heads, lpb())
    -- 11 окт: OFF в диапазоне — убрать: нота звучит до следующего события подколонки (нет — до конца региона), как в Renoise
    for fi = f0, f1 do
      local fl = flat()[fi]
      for _, sub in ipairs(fl and subs_of(fl) or {}) do
        for r = r0, r1 do
          local c = sub[r]
          if c and c.kind == 'off' and c.of and c.of.stub then E.all_off_del(c.of)   -- 31 окт: OFF без ноты (CC 123)
          elseif c and c.kind == 'off' and c.of then
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
      for _, h in ipairs(heads) do
        local s0 = h.slice or (h.kind == 'midi' and ctx.midi_kit_slice and ctx.midi_kit_slice(h.item, h.pitch)) or 0   -- 19 окт: пэд кита — от своего Sxx
        if ctx.set_slice then ctx.set_slice({ h }, math.max(0, s0 + d)) end
      end
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
      -- k-я команда строки: xx ± d (если команды нет — ничего); 12 окт: строка внутри ноты — её команда
      local fc = #heads == 0 and V.fx_cell(V.cur.fi, V.cur.row)
      if fc then
        local f = fc.fx[fld - 3]
        if f then E.set_fx({ fc.head }, lpb(), f:sub(1, 2), tonumber(f:sub(3), 16) + d, V.fx_rowable(f:sub(1, 2)) and fc.off or nil) end
      end
      for _, h in ipairs(heads) do
        local f = (h.fx or {})[fld - 3]
        -- 20 окт: auto capture — поле пустое: команда ближайшей ноты выше в этой колонке (код и значение), сразу ± d
        if not f and h.row0 then
          local best
          for _, h2 in ipairs(V.heads_in(f0, f0, 0, math.max(0, h.row0 - 1))) do
            local f2 = (h2.fx or {})[fld - 3]
            if f2 and h2 ~= h and (h2.row0 or -1) < h.row0 and (not best or h2.row0 > best.row0) then best = { row0 = h2.row0, f = f2 } end
          end
          if best then f = best.f; V.msg = ('auto capture: %s from row %d'):format(best.f, best.row0) end
        end
        if f then E.set_fx({ h }, lpb(), f:sub(1, 2), math.max(0, math.min(255, tonumber(f:sub(3), 16) + d))) end
      end
    end
  end
  return edited
end

-- hex-ввод: поле 2/3 — две цифры, поле команды — код (два символа, как в
-- Renoise: 0U, SF, ZT; 12 окт) + две цифры. Возвращает true, когда значение
-- принято (буфер сброшен).
local function fx_code_ok(code)
  local d = ctx.SM and ctx.SM.FX_DESC
  return d and d[code] ~= nil
end
local function fx_prefix_ok(ch)
  for _, e in ipairs((ctx.SM and ctx.SM.FX) or {}) do if e[1]:sub(1, 1) == ch then return true end end
  return false
end
local function hex_entry(c, fld, heads)
  local ch = (c < 256) and string.char(c):upper() or ''
  local buf = V.hexbuf or ''
  local is_hex = ch:match('^[0-9A-F]$') ~= nil
  -- 1 ноя: PT-mode — команда как в ProTracker: три hex-знака (C40, 940, D10, E93), перевод в наш код
  if fld >= 4 and ctx.PTFX then
    if not is_hex then return false end
    buf = buf .. ch
    if #buf < 3 then V.hexbuf = buf; V.msg = buf .. '_: ProTracker command (0 arp 1 2 slide 3 porta 4 vib 7 trem 9 offset A vol slide B jump C vol D break E9 retrig F tempo)'; return false end
    V.hexbuf = nil
    local code, val = ctx.PTFX.to_ours(buf:sub(1, 1), tonumber(buf:sub(2), 16))
    if not code then V.msg = buf .. ': ' .. tostring(val); return 'none' end
    buf = code .. ('%02X'):format(val)
    V.cur.sub = nil
    goto pt_write
  end
  if fld >= 4 and V.cur.sub ~= 'val' then
    -- 12 окт: левая половина — код. Буква — сразу код 0x (D = 0D), S и Z — приставки (SI, ZT),
    -- 0 — по привычке (0D). Код готов — курсор на значение, ждёт две цифры
    -- (h j k l — не коды, они ходят; ZJ — J после Z, это код)
    local code
    if buf == '' then
      if ch == '0' or ch == 'S' or ch == 'Z' then
        V.hexbuf = ch; V.msg = ch .. '_: the second letter of the code (' .. (ch == 'S' and 'SI SO SL SM SB SF' or (ch == 'Z' and 'ZT ZJ ZB' or '0D 0U 0V 0T 09 ...')) .. ')'
        return false
      end
      if not (ch:match('^%a$') and fx_code_ok('0' .. ch)) then return false end
      code = '0' .. ch
    else
      if not fx_code_ok(buf .. ch) then V.msg = ('%s%s: no such effect (0x effects, Sx sample, Zx song; Enter - the list)'):format(buf, ch); return false end
      code = buf .. ch
    end
    V.hexbuf = code; V.cur.sub = 'val'; V.fx_back = true
    V.msg = ('%s %s - now two hex digits'):format(code, (ctx.SM and ctx.SM.FX_DESC and ctx.SM.FX_DESC[code]) or '')
    return false
  end
  if fld >= 4 then
    -- 12 окт: правая половина — значение. Код — только что набранный, иначе своей команды слота,
    -- иначе бледной (действующей со строк выше): 08 под бледной 0D10 пишет 0D08
    if not is_hex then return false end
    if #buf < 2 then
      local cur = V.fx_slot(V.cur.fi, V.cur.row, fld - 3)
      if not cur then V.msg = 'no command here - type its code on the left half first (h; D = 0D, SI, ZT ...)'; return 'none' end
      buf = cur:sub(1, 2)
    end
    buf = buf .. ch
    if #buf < 4 then V.hexbuf = buf; return false end
    V.hexbuf = nil
    if V.fx_back then V.cur.sub = nil; V.fx_back = nil end   -- набирали с кода — следующая строка тоже с кода
  else
    if not is_hex then return false end
    buf = buf .. ch
    if #buf < 2 then V.hexbuf = buf; return false end
    V.hexbuf = nil
  end
  -- vol на строке продолжения аудио (5 окт): точка огибающей громкости take
  if fld == 2 and #heads == 0 then
    local h = V.covering(V.cur.fi, V.cur.row)[1]
    if h and h.kind == 'audio' and h.item then ctx.edit.cont_vol(h.item, ctx.row_time(V.cur.row), tonumber(buf, 16), ctx.row_time(V.cur.row + 1)); return true end
  end
  ::pt_write::
  if #heads == 0 then V.msg = 'no note in this row - type the note first (vol / delay / effects belong to a note)'; return 'none' end
  if fld == 2 and V.cur.sub == 'pan' then ctx.edit.set_pan(heads, tonumber(buf, 16))   -- 14 окт: колонка пана
  elseif fld == 2 then ctx.edit.set_vol(heads, lpb(), tonumber(buf, 16))
  elseif fld == 3 then ctx.edit.set_delay(heads, lpb(), tonumber(buf, 16))
  else
    -- 12 окт: у каждой строки своя команда. В колонке строки стояла другая — уступает место новой.
    -- Свойство item (0S 0M 0P SI …) — у всей ноты: на строке внутри ноты уходит в её первую строку
    local code, val = buf:sub(1, 2), tonumber(buf:sub(3), 16)
    local fc = V.fx_cell(V.cur.fi, V.cur.row)
    local rowable = V.fx_rowable(code)
    if fc and fc.off > 0 then
      local old = fc.fx[fld - 3]
      if rowable then
        if old and old:sub(1, 2) ~= code then ctx.edit.clear_fx({ fc.head }, lpb(), old:sub(1, 2), fc.off) end
        ctx.edit.set_fx({ fc.head }, lpb(), code, val, fc.off)
      else
        -- 12 окт: не писать молча в первую строку ноты выше (пользователь: «вставляет команду в предыдущий ряд»)
        V.msg = ('%s is a property of the whole note - type it on its row %04d (or on a new note here)'):format(buf, fc.head.row0 or 0)
        return 'none'
      end
    else
      for _, h in ipairs(heads) do
        local old = (h.fx or {})[fld - 3]
        if old and old:sub(1, 2) ~= code then ctx.edit.clear_fx({ h }, lpb(), old:sub(1, 2)) end
      end
      ctx.edit.set_fx(heads, lpb(), code, val)
    end
  end
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
  local busy, quiet = {}, {}   -- 31 окт: ~ / Ctrl+~ — треки, где на строке ничего не звучит, получают свободный OFF
  for i, f in ipairs(F) do
    if not f.env and ((scope == 'all') or (scope == 'track' and cur and f.ci == cur.ci) or (scope == 'sub' and i == V.cur.fi)) then
      for _, h in ipairs(V.covering(i, V.cur.row)) do if not h.stub then heads[#heads + 1] = h; busy[f.ci] = true end end   -- 31 окт: OFF без ноты — не нота
      if f.col and f.col.track and not f.ml and not f.col.master and not quiet[f.ci] then quiet[f.ci] = f end
    end
  end
  if scope ~= 'sub' and ctx.edit.all_off then
    local n = 0
    for ci, f in pairs(quiet) do
      local here = f.sub and f.sub[V.cur.row]
      if not busy[ci] and not (here and here.of and here.of.stub) then
        ctx.edit.all_off(f.col.track, f.lane and f.lane.idx or nil, lpb(), V.cur.row); n = n + 1
      end
    end
    if #heads > 0 then ctx.edit.note_off(heads, lpb(), V.cur.row) end
    V.msg = ('OFF on %s: %d note(s) end here, %d free OFF'):format(scope == 'all' and 'all tracks' or 'the track', #heads, n)
    return #heads + n
  end
  if #heads == 0 and scope == 'sub' and cur and cur.sub and cur.sub[V.cur.row] and cur.sub[V.cur.row].of and cur.sub[V.cur.row].of.stub then
    V.msg = 'OFF is already here'; return 0
  end
  if #heads == 0 and scope == 'sub' and cur and cur.sub then   -- 21 окт: тонкая нота выше — дотянуть её до этого OFF
    local h = V.head_above(cur.sub, V.cur.row)
    -- 31 окт: только нота этого паттерна — нота из прошлого паттерна дотянуться не может (её клип кончился), OFF молча
    -- пропадал («note off: 1», а на экране ничего); тогда — all notes off
    local pr0 = ctx.region_rows and ctx.region_rows()
    -- 31 окт: выше — OFF без ноты (all notes off): ` ниже переносит его сюда, как OFF ноты
    if h and h.stub and not (pr0 and (h.row0 or -1) < pr0) and ctx.edit.all_off_del then
      ctx.edit.all_off_del(h)
      ctx.edit.all_off(cur.col.track, cur.lane and cur.lane.idx or nil, lpb(), V.cur.row)
      V.msg = ('OFF moved to row %04d (all notes off)'):format(V.cur.row)
      return 1
    end
    if h and not h.stub and not (pr0 and (h.row0 or -1) < pr0) then heads[1] = h end
  end
  -- 31 окт: свободный OFF один на промежуток между нотами: уже есть в этом паттерне выше / ниже (без ноты между) —
  -- он переезжает сюда, второй не ставится
  if #heads == 0 and scope == 'sub' and cur and cur.sub and ctx.edit.all_off_del then
    local pr0, pr1 = ctx.region_rows and ctx.region_rows()
    pr0, pr1 = pr0 or V.cur.row - 4096, pr1 or V.cur.row + 4096
    local found
    for _, dir in ipairs({ -1, 1 }) do
      local r = V.cur.row + dir
      while not found and r >= pr0 and r <= pr1 do
        local c = cur.sub[r]
        if c and c.of and c.of.stub then found = c.of
        elseif c and (c.kind == 'midi' or c.kind == 'audio') then break end
        r = r + dir
      end
    end
    if found then
      ctx.edit.all_off_del(found)
      ctx.edit.all_off(cur.col.track, cur.lane and cur.lane.idx or nil, lpb(), V.cur.row)
      V.msg = ('OFF moved to row %04d'):format(V.cur.row)
      return 1
    end
  end
  -- 31 окт: ничего не звучит (подколонка) — OFF всё равно ставится: all notes off на трек
  if #heads == 0 and scope == 'sub' and cur and cur.col and not cur.ml and ctx.edit.all_off then
    ctx.edit.all_off(cur.col.track, cur.lane and cur.lane.idx or nil, lpb(), V.cur.row)
    V.msg = 'OFF: all notes off here (stops whatever still sounds on the track)'
    return 1
  end
  ctx.edit.note_off(heads, lpb(), V.cur.row)          -- пусто — note_off ничего не делает
  V.msg = ('note off (%s): %d'):format(scope == 'all' and 'all tracks' or (scope == 'track' and 'track' or 'subcolumn'), #heads)
  if #heads == 0 then V.msg = 'note off: nothing sounds here - OFF ends a note playing above this row' end   -- 31 окт
  return #heads
end
-- 13 окт: край ноты под курсором на строку (Option+Shift: J / K — конец позже / раньше,
-- H / L — начало раньше / позже; начало тянет и offset источника, как trim). Без растяжки;
-- что звучит за концом сэмпла — по лупу инструмента. По сетке строк, один undo
function V.note_edge(edge, d)
  local hs = V.covering(V.cur.fi, V.cur.row)
  local n = 0
  local L = lpb()
  for _, h in ipairs(hs) do
    local it = h.item
    if h.kind == 'audio' and it and reaper.ValidatePtr(it, 'MediaItem*') then
      local pos = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
      local len = reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
      local r = math.floor(ctx.model.row_of_time(edge == 'end' and pos + len or pos, L) + 0.5) + d
      local t = ctx.row_time(r)
      if (edge == 'end' and t > pos + 1e-4) or (edge == 'start' and t < pos + len - 1e-4 and t >= 0) then
        ctx.edit.item_drag_begin('note ' .. edge)
        ctx.edit.item_drag_to(it, edge, t)
        n = n + 1
      end
    end
  end
  ctx.edit.item_drag_end()
  V.msg = n > 0 and ('note %s %s %d row(s) (Ctrl+Shift+J K - the end, H L - the start)'):format(edge, d > 0 and 'later by' or 'earlier by', math.abs(d))
          or 'note edge: no audio note under the cursor (MIDI notes: drag)'
end
-- 13 окт: slip — источник внутри аудио-ноты под курсором на строку (d = 1: звук вниз, -1: вверх)
function V.note_slip(d)
  local n = 0
  for _, h in ipairs(V.covering(V.cur.fi, V.cur.row)) do
    local it = h.item
    local tk = h.kind == 'audio' and it and reaper.ValidatePtr(it, 'MediaItem*') and reaper.GetActiveTake(it)
    if tk then
      local pos = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
      local row_s = ctx.row_time(V.cur.row + 1) - ctx.row_time(V.cur.row)
      local rate = reaper.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE'); if rate <= 0 then rate = 1 end
      local offs = reaper.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS')
      local loop = reaper.GetMediaItemInfo_Value(it, 'B_LOOPSRC') == 1
      local no = offs - d * row_s * rate
      if not loop then no = math.max(0, no) end
      if math.abs(no - offs) > 1e-9 then
        ctx.edit.run('slip', function() reaper.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', no) end)
        ctx.edit.note_modified(it)
        n = n + 1
      end
    end
  end
  ctx.model.invalidate()
  V.msg = n > 0 and ('slip: the sound %s a row inside the note (Shift+Opt+Cmd+J K)'):format(d > 0 and 'down' or 'up') or 'slip: no audio note under the cursor (or the start of the file)'
end
-- 16 окт: ` в NORMAL — прослушать весь сэмпл инструмента (был прыжок назад; есть гарпун и Ctrl+O)
-- 16 окт: Option+Shift+2 (€ в раскладке US) — панель макросов
function V.is_mac_key(c) return c == 8364 or c == 0x75000000 + 8364 end
-- 16 окт: Tab / Shift+Tab в колонке волны — к следующему / предыдущему удару: stretch-маркер ноты
-- (жёлтая метка) или начало ноты; строки — по всем нотам колонки
function V.wave_marks(fi)
  local f = flat()[fi]
  local out, seen = {}, {}
  if not f then return out end
  local function add(r) if not seen[r] then seen[r] = true; out[#out + 1] = r end end
  for _, sub in ipairs(subs_of(f)) do
    for r, c in pairs(sub) do
      if is_head(c) then
        add(r)
        for _, fr in ipairs(c.smk or {}) do add((c.row0 or r) + math.floor(fr * (c.rows or 1))) end
      end
    end
  end
  table.sort(out)
  return out
end
function V.wave_step(dir)
  local m = V.wave_marks(V.cur.fi)
  local to
  if dir > 0 then for _, r in ipairs(m) do if r > V.cur.row then to = r; break end end
  else for i = #m, 1, -1 do if m[i] < V.cur.row then to = m[i]; break end end end
  if not to then V.msg = dir > 0 and 'wave: no hit below' or 'wave: no hit above'; return false end
  V.cur.row = to; ensure_visible()
  V.msg = ('wave: hit at row %d (Tab / Shift+Tab)'):format(to)
  return true
end
function V.play_whole()
  local f0 = flat()[V.cur.fi]
  local inst0 = f0 and (f0.col.pool or {})[V.inst]
  if f0 and ctx.inst_fx and ctx.inst_fx(f0.col) then inst0 = nil end
  local root = inst0 and (inst0.parent or inst0)
  if f0 and ctx.preview then ctx.preview(f0.col.track, (ctx.model and ctx.model.BASE_NOTE) or 60, root and root.item, V.cur.row, 1) end
  V.msg = root and ('whole sample: ' .. (root.name or '')) or 'whole sample: no sample instrument here'
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
-- 15 окт: опция slice1 — q = слайс 1 (база на полутон ниже), весь сэмпл — клавиша 1
local function slice1_on() if ctx.slice1_on then return ctx.slice1_on() end; return ctx.state and ctx.state.slice1 end   -- 16 окт: frow — всегда
function V.slice_base() return ((ctx.model and (ctx.model.SLICE_BASE or ctx.model.BASE_NOTE)) or 60) + 1 - (slice1_on() and 1 or 0) end   -- 18 окт: база слайсов — опция base octave
local function piano_pitch(c)
  local off = ctx.piano[c]
  if off == nil then return nil end
  return (V.octave + 1) * 12 + off
end

-- ── командная строка ──────────────────────────────────────────────────────
-- Таблица команд: исполнение, подсказка (список снизу при наборе) и Tab.
V.COMMANDS = {
  { 'q', '', 'close window' }, { 'w', '', 'save project' }, { 'wq', '', 'save and close' },
  { 'lpb', 'N', 'rows per beat (1..128)' }, { 'metro', '[menu]', 'metronome on / off; menu - speed, accents, pre-roll' }, { 'vis', 'scene', 'visor event on the cursor row = scene / preset (empty - delete)' }, { 'vzsave', 'name', 'visor: save the look as a preset' }, { 'vzset', 'N', 'visor: the selected parameter / matrix cell = N' }, { 'step', 'N|auto|next', 'step after input: rows / to the end of the item / to the next object' },
  { 'oct', 'N', 'input octave' }, { 'inst', 'N', 'instrument slot' },
  { 'fx', 'N', 'fx command columns (0..4)' }, { 'env', '', 'envelope columns' },
  { 'tempoclean', '', 'tempo map: write every tempo marker again (REAPER rebuilds a stale map - a tempo change without a marker); the patterns stay on their beats' },
  { 'patternkb', '[quant|sudden|rec|off]', 'MPC style: the note keys play the patterns of the song (quant - seamless after the playing one, sudden - at once); rec - record the order, rec again - write it after the song (= :pads)' }, { 'seq', 'text|play|stop|write|new [name]|dup|name N|del|next|prev', 'seq - the order of patterns (was chain / playlist; :ch, :pl too): the order as text - A1 A1 B1x2 C1:16 D1-8 D1/2 B2+8 verse 4 (pattern / section name, region number; xN repeat, :N first N rows, /N a part, -N skip N rows, +N then its first N rows again); Tab completes names; play - seamless on whole patterns; write - after the song' }, { 'tsec', 'name', 'a section over the REAPER time selection (Tr in the matrix picks a quick name: intro verse chorus drop break …)' }, { 'section', 'name', 'a section (a region without a code) over the selected pattern slots of the matrix (Shift+J K on the names)' }, { 'unstack', '', 'patterns that start at the same place: the extra one becomes a linked repeat after the original' }, { 'human', '[all|nopitch|notime] [N%]', 'humanizer: the notes of the block / track in the region get small random timing, pitch, volume, pan, attack and length' }, { 'scale', 'N', 'bitmap scale x1..3 (Cmd +/- too); x4 is kept for PT-mode' }, { 'options', '', 'all options in one window' }, { 'off', '[all]', 'note off at the cursor row on the whole track (all - on every track); in INSERT ` subcolumn, ~ (Shift+`) all tracks, Ctrl+~ the track' }, { 'repeat', '[all]', 'repeat the part of the region above the cursor down to the region end (Ctrl+Opt+J; all - every track)' }, { 'mac', 'name', 'play a macro by name (saved, built-in or @a) at the cursor; \\ q - all of them in a menu' }, { 'macsave', 'a name', 'keep register a as a named macro (macros tab, Data/jf_tracker_macros.txt)' }, { 'tcolor', '#rrggbb', 'colour of the cursor track by its code (tc - the colour grid)' }, { 'transients', '', 'transient detector module in the item tab (= Opt+D): sensitivity, threshold, min gap, pre-attack, live; Enter slices' }, { 'arr', '[new [name]|name text|dup|clear|del|next|prev|N]', 'arrangements: named sets of the fixed lanes that play (\\ P a)' }, { 'about', '[logo]', 'version, changes and the logo (a name part picks it: marquee, rubble, plum …)' }, { 'theme', 'name', 'reaper (native) | modus-vivendi | modus-operandi | solarized-dark | solarized-light | gruvbox | catppuccin | mono | protracker | impulse' }, { 'name', 'text', 'matrix: rename the cursor region' }, { 'sec', '[show|repeat|copy|loop|move N|copyto N|aliasto N]', 'the section of the cursor slot of the matrix: show it in the tracker, repeat it after itself (linked) / copy, loop, move before slot N (copy / alias); no argument - its menu (a click on its strip)' }, { 'gain', '', 'router gain staging: level meters (jf_tracker_probe) before and after every row of the chain, the dB change above the row; again - off (also when the router closes)' }, { 'pal', 'render|playlist|kb', 'palette of the matrix: the picked cells as a new pattern at the end / their patterns to the playlist / clipkb on-off' }, { 'pnote', 'text', 'a note on the pattern (kept in the project, shown under its name in the palette; empty - delete); dblclick a name in the palette' }, { 'len', 'N|Ns|Nb', 'matrix: cursor region length - N steps (LPB), Ns seconds, Nb bars; later regions and items ripple' }, { 'add', '[bars] [name]', 'matrix: new region after the last one, from the next bar (+)' }, { 'space', 'N', 'gap above letters, px' }, { 'tab', 'item|automation|modulation|midi|grid|retro|orca|master', 'top panel tab' }, { 'optsave', 'name', 'save all options as a profile' }, { 'optload', 'name', 'load an options profile' }, { 'optdel', 'name', 'delete an options profile' }, { 'redo', '', 'redo (also Cmd+Shift+Z; Ctrl+R is the rec tab)' }, { 'undo', '', 'undo (also u, Cmd+Z)' }, { 'sig', 'N/D [all|here]', 'time signature for the whole project or this pattern; a longer bar - fill the missing beats empty / with the last beat / keep' }, { 'scopemode', '[scope|spec|sgram]', 'analyzer: scope / spectrum / spectrogram' }, { 'retro', '[add]', 'retro sampler tab; add = jf_rec on cursor track' }, { 'top', '', 'top panel' }, { 'meters', '', 'peak meters over columns (PT style)' }, { 'wave', '[column|note|off]', 'wave: own column (spectral peaks + stretch markers) / in the note field / off' }, { 'xfade', '[on|off|now|ms]', 'x-fade of inserted notes: on/off, crossfade now, length ms' }, { 'mxzoom', '', 'matrix: schema <-> detail' }, { 'scopes', '', 'scopes: JSFX bridge on tracks on/off' }, { 'dsp', '[big]', 'bottom DSP panel (track fx); big - the chain with its routing on the whole window (zz in DSP)' }, { 'patternize', '1|2|4|8|16|items|markers', 'the empty parts of the project become patterns (regions A1 A2 …): every N bars, by the items of the cursor track, or by markers; existing patterns stay (matrix menu)' }, { 'shiftrec', '', 'shift rec (the shift button under rec): waits for a MIDI note, then records from the cursor row at the project rate (x0.5 - slow, plays back fast); again - cancel / stop' }, { 'punch', '', 'punch: time selection = cursor region, auto-punch' }, { 'recmode', '', 'record mode (hydra)' }, { 'lanes', '', 'cursor track: fixed lanes on/off' },
  { 'z', '<words>', 'zoxide: jump the browser to the most used / recent folder matching the words (last word - in the folder name)' }, { 'zi', '', 'zoxide: pick from the visited folders (fzf), best first' }, { 'pane', '<panel> left|right|top|bottom|with <p>|swap <p>|hide|show|zoom, reset, <layout>', 'panes (tmux / zellij): move, stack, hide, layouts; no argument - layout string' }, { 'rec', '', 'record arm cursor track' }, { 'input', '', 'choose record input (hydra)' }, { 'smartin', '', 'most active input (jf_smart_set_input)' }, { 'slice', '', 'slice instrument (virtual)' },
{ 'printjumps', '', 'play the song in the mind following ZB / ZJ and write the resulting order after the song (section printed): whole patterns as linked repeats, broken ones as cut copies, jumps stripped there - so REAPER renders the jumps; a loop stops at its first repeat (:pj)' }, { 'fprint', '', 'fingerprint the samples of the map index from REAPER peaks (attack, decay, noisiness, brightness, loudness) in the background; again - stop' }, { 'similar', '', 'samples that sound like the one in the browser / the audio note under the cursor (same class by name, nearest fingerprints): listen on select, Enter - into the lib' }, { 'blood', '', 'experimental: a pool of blood along the bottom, the sound throws drops that splash back with ripples; again - off' }, { 'sand', '', 'experimental: a sand bed under every track, its sound throws grains up (louder - higher); again - off' }, { 'frame', '[off|cracks|blood|lightning|vhs]', 'experimental: a frame inside the tracker; no argument - the menu; red in INSERT' }, { 'cracks', '', 'experimental: cracks along the inner edge of the tracker, the colours around seep through; again - off' }, { 'bar', '', 'a bar starts here: the tempo since the last tempo marker changes so the nearest bar line lands on the cursor (its row; in audio of the cursor track - the stretch marker / item start within half a row); the items of the cursor track keep their time, the rest follows the beats' }, { 'patstart', '', 'the nearest pattern starts here (the tempo of the pattern before it fits)' }, { 'patend', '', 'the pattern of the cursor ends here (its tempo fits)' }, { 'poolprev', '', 'preview instrument on select' }, { 'side', '', 'sidebar browser' }, { 'legato', 'off|auto|fill', 'notes of the track join the next note (stretched, pitch kept, follows the tempo); fill - only the length grows to the next note, not stretched (the instrument loop plays on); off - back; auto - keep it while inserting' }, { 'pmtag', 'words', 'jf_pm tags of the project picked with T in the pm tab' }, { 'interp', 'vol|delay|note|0X', 'VISUAL: values from the first to the last event, linear by rows (Paketti)' }, { 'note', 'C-4 [rows]', 'a note of the instrument at the cursor' }, { 'sl', 'N [rows] [+semis]', 'slice N at the cursor' }, { 'whole', '[rows]', 'the whole sample (mother item)' }, { 'fxa', '', 'store all parameters of the selected DSP fx as A' }, { 'fxb', '', 'store them as B' }, { 'morph', 'N', 'morph the selected fx from A (0) to B (100)' }, { 'scramble', '', 'slice notes swap their slices randomly (VISUAL, else the cursor track in the region)' }, { 'xf', 'op [n]', 'transform the block (VISUAL) or the cursor track in the region: stretch k (time x k), reverse, rotate n, shuffle, gravity g (denser to the end, as a fall; g<1 to the start), bounce r (intervals shrink x r), fib (Fibonacci rows), tuplet n (n notes evenly), golden (volume / phi each), vel k' }, { 'arcforget', '', 'monome arc: forget the rings of the effect in DSP - they follow the DSP cursor again' }, { 'mackey', 'name x', 'give a saved macro the register letter x: @x plays it, 3@x three times' }, { 'reload', '', 'restart the tracker from its files (after an update) - the layout and options stay' }, { 'shotpane', '<panel|window|x,y,w,h> [file.png]', 'a picture of a panel (or the window, a rectangle) into help/ - the pictures of the help; works with the window off screen' }, { 'keys', '', 'write every key of every module as text: Data/jf_tracker_keys.md (options - :optsave name, macros - Data/jf_tracker_macros.txt)' }, { 'phrase', 'NAME', 'the block (V) or the pattern of the cursor, on the cursor track -> a phrase: its items go to the library as the source ph:NAME, in their place - one trigger note on the cursor track (C-4 plays as is, other notes transpose, velocity scales, the length cuts); edit the source - every trigger follows' }, { 'dedouble', '', 'doubled notes (same note at the same time) on the cursor row of the track - one is kept (VISUAL - in the selection)' }, { 'sw', 'N', 'swap the event under the cursor with the Nth below (= Ngw)' }, { 'tutorial', '', 'first steps in thirteen points' }, { 'swing', 'N | on | off | 1/16', 'REAPER grid swing: amount -100..100 % (33 = triplet), division; no argument - the menu' }, { 'pm', '[big | grid | list | sort date|name|bpm|status | daw all|rpp|other]', 'jf_pm project cards in the browser (pm tab); big - over the whole window' }, { 'font', 'name | next | prev | off | <family> [px]', 'tracker font: off - the REAPER bitmap, any installed family by name (custom), or a terminal monospace font (bigblue, bb437, departure, gohu11, gohu14, terminess, proggy, profont, 3270, monocraft, iosevka, jetbrains, hack, plex ...); next / prev - step through them' }, { 'audio', 'dev <name> | bs N | sr N | sr off | bs off', 'audio device of REAPER (CoreAudio): device by name, buffer size, sample rate - applied at once (the audio restarts); no argument - the options tab audio' }, { 'eu', 'k [n] [r]', 'Euclid as item geometry: a new MIDI item at the cursor, k hits in n rows (default 16), rotated by r, its source looped up to the pattern end - REAPER plays the repeats; the note - of the cursor row (else C-4)' }, { 'viper', '', 'VIPER mode (Cmd+F10): one tracker pane, only the tracks of the items selected in REAPER, the cursor follows the REAPER edit cursor, the whole project; again - back' }, { 'quant', '[notes|offs|auto|start|end|items|all] [bar|pattern|track]', 'quantize to the row grid: notes (delay), OFFs, automation points, item starts / ends; V - the selection, else the cursor track in the bar / pattern / track; no argument - the menu (\\ Q)' }, { 'mem', '', 'what holds the memory of the tracker: the heap before / after a full collect, the biggest parts (status, debug log)' }, { 'memprof', '[sec]', 'which code lines make the most garbage: a sampling hook for N seconds (5), KB/s per file:line (status, debug log)' }, { 'jftop', '', 'what in the tracker takes the time: each part of the frame in ms (top module, rows, matrix, browser, keys ...); r - reset, t - performance view, Esc - close' }, { 'logo', '[name]', 'one of the jf_tracker artworks in the middle of the tracker; any key or click closes it' }, { 'dev', '[on|off]', 'developer copy only: off shows the tracker as release users get it (no grid, orca, pm cards); takes effect after reopening the tracker' }, { 'ssave', 'name', 'save the view (options + module layout) as a screenset' }, { 'sload', 'name', 'load a screenset' }, { 'libsave', 'name', 'save the lib as a kit (REAPER track template, browser tab kits)' }, { 'libdir', 'name', 'the files picked with Opt+Enter into the lib as the folder <name>' }, { 'big', '', 'big sample editor: the item tab over the whole window, wheel zoom' }, { 'macro', '', 'zoom out: a row is a beat (LPB 1); again - back to the previous LPB' }, { 'unfold', '', 'zoom in (= zu): LPB rises to the smallest one where the folded notes of the selection / cursor row get their own rows (up to 128); again - back' }, { 'harmonize', '[beat|half]', 'the melody of the cursor track (the V selection, else the pattern) -> the best chord of the key (:key) for every bar (beat / half bar) into the chord lane of the master' }, { 'tr', '[sel|col|track|all] +3|-12|o1|d2|^1|chord [Am]|ji', 'transpose, Vim style: semitones, o octaves, d degrees of the key, ^ 1/6 tones, to the chord of the row, just intonation; no argument - the transposer dropdown' }, { 'nooff', '[all]', 'remove every OFF in what you see (project / sec / pat; V - the selection): the cursor track; all - the matrix selection (block / cells), else the cursor track; the notes ring to the next event' }, { 'offnotes', '[all]', 'an OFF right after every note (the row below it) in what you see (V - the selection): the cursor track; all - the matrix selection (block / cells), else the cursor track' }, { 'gui', '', 'the native window of the selected DSP fx over its block (follows it; again - back to the tracker view); also the gui button in the fx head' }, { 'neg', '', 'negative harmony: the notes of the selection (else the cursor row, all tracks) mirrored around the axis of the key (C: between Eb and E - C<->G, E<->Eb, F<->D), the octave kept; again - back' }, { 'pitch', '', 'pitch of the sample: the audio note on the cursor row (or the lib sample) gets take markers - a note per slice (A3, +cents) or a chord (Am); again - replaced' }, { 'transcribe', '', 'audio solo under the cursor -> MIDI: selects the item and opens jf_transcribe (aubionotes; Transcribe, tune, Apply - the notes land on a new track)' }, { 'bass', '[fifth]', 'a bass line on the cursor track from the chord lane of the master (the pattern or the V selection): the root of every chord, fifth - root then fifth' }, { 'voice2', '3|6|-3|-6', 'a second voice in the key for the notes of the selection (else the row): a third / sixth above (+) or below (-)' }, { 'prog', '[notes] I V vi IV | Am 2 | F 2 | G7', 'a progression from the bar of the cursor (lengths in bars, default 1) into the chord lane of the master; notes - also the chords as notes on the cursor track (voice leading)' }, { 'key', '[Am | D dorian | mark | snap | off]', 'key of the song: empty - from the MIDI notes of every track (not kits); a name - set it; mark - notes out of the key red; snap - typing in the key; off - no key' }, { 'chd', 'Am7', 'a chord on the cursor row of the chord column of the master (empty - remove)' }, { 'chord', '[Cm7 | off | lane | read [beat] | hear [beat] | lead]', 'no argument - the cursor track as one chord lane (names from its notes, OFF ends); a symbol - write that chord at the cursor row (replaces the notes starting there). The chord lane track drives JS jf_tracker_chordfollow: put it on other tracks - their notes snap to the chord of the moment' }, { 'pt', 'new', 'PT-mode (ProTracker, OG-mode merged in, :og too): 4 channels track1..track4, 31 samples, 64-row patterns, font x2, note / sample / vol / one command, scopes on top; :pt new creates CH1..CH4; again - back' }, { 'arp', 'live | [up|down|updown|random|played] [step] [oct] [gate%]', 'chord on the cursor row -> arpeggio over its length' }, { 'fixslices', '', 'repair slice notes copied from a stretch-marked sample (they all played its start)' },
  { 'start', '[bar[.beat]]', '=START marker of the sequence (empty = cursor row)' }, { 'end', '[bar[.beat]]', '=END marker of the sequence' },
  { 'cc', '[N]', 'CC lane: N - a MIDI-item CC column (events of the MIDI items of the track); empty - ReaControlMIDI on the track, its parameter as an envelope column' }, { 'pc', '', 'program change column of the MIDI items of the cursor track' }, { 'curvesave', 'name', 'save the open automation item curve (Data/jf_tracker_curves)' }, { 'curves', '', 'browser on the saved curves - Enter loads one into the open automation item' },
  { 'browse', 'path', 'browser root' }, { 'dock', '', 'dock <-> fullscreen (Cmd+F11)' }, { 'preview', '', 'preview on input' },
  { 'pitchmode', 'shift|resample', 'track pitch mode' },
  { 'sync', '', 'sync same-name regions' }, { 'autosync', '', 'sync after edits' },
  { 'follow', '', 'view follows playhead' }, { 'lock', '', 'tracker cursor = REAPER edit cursor and selected track' }, { 'fixed', '', 'cursor fixed at screen centre (Impulse Tracker)' }, { 'debug', '', 'debug log (jf_tracker_debug.log in the REAPER folder): keys and where they were handled, clicks, actions, errors; fps in the status' },
  { 'fold', '', 'fold all tracks' }, { 'unfold', '', 'unfold all' },
  { 'trim', '', 'trim items to region bounds (strict patterns)' },
  { 'beatsync', '[beat|bar|N]', 'stretch event end to the nearest beat / bar / N rows (= key, N=)' },
  { 'quantize', '', 'smart quantize the instrument: loud transients to beats, soft to 16ths, length to whole bars / beats (stretch markers)' },
  { 'tname', 'text', 'rename the cursor track (dblclick on the track name)' },
  { 'fxdump', '', 'DSP: dump the parameters of the module under the cursor (names, steps, value texts at 0 .25 .5 .75 1) into tests/fixtures/fxdump - samples for the parameter parser' },
  { 'snapname', 'text', 'name of the mixer snapshot just saved (prompt for name in the snapshots panel)' },
  { 'fxname', 'text', 'rename the selected fx or container in the chain (empty - its own name back)' },
  { 'zone', 'lo hi [full-lo full-hi]', 'the chain zone of a container (0..127): where the chain sounds for chain select, full in the middle, fades at the edges (click the numbers in CHAINS)' },
  { 'iname', 'text', 'rename the selected instrument in all its items (click the name in sample properties)' },
  { 'orca', '[on|off|clear|pin|reset|size WxH|load]', 'Orca tab: Orca field (plants notes into the timeline while playing)' },
  { '!', 'text', 'REAPER actions (all, incl. scripts / custom): fzf, recent first - kept apart from tracker commands; also \\ a' },
  { 'midi', '', 'MIDI learn tab: knobs and pads of a controller drive the slicer (Enter: learn)' },
  { 'loops', '', 'matrix loops layer: cells show item loop periods, digits+Enter / > < + - edit them' },
  { 'vel', 'N', 'velocity of inserted notes 1..127 ({ } with frow, c C with qwerty)' },
  { 'loop', '[N|region|off]', 'loop item to region end (>), N = loop period in rows (N>), region = region to item end (<), off' },
  { 'deltime', '[N] [all]', 'delete N rows of time in region (Backspace / Shift)' }, { 'instime', '[N] [all]', 'insert N rows of time in region (Opt+Backspace; Shift - all tracks)' },
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
  elseif cmd == 'chcol' then if ctx.chain_col_hex then ctx.chain_col_hex(arg) end   -- 28 окт: свой цвет цепочки
  elseif cmd == 'bar' or cmd == 'patstart' or cmd == 'patend' then   -- 31 окт: такт / край паттерна здесь — темп под трек курсора
    if cmd == 'bar' then ctx.bar_here() else ctx.pat_edge_here(cmd == 'patend' and 'end' or 'start') end
  elseif cmd == 'quant' or cmd == 'quantize' then   -- 29 окт: :quant [notes|offs|auto|start|end|items|all] [bar|pattern|track]
    local w = {}; for t in (arg or ''):gmatch('%S+') do w[#w + 1] = t end
    local SC = { bar = 'bar', pat = 'pattern', pattern = 'pattern', track = 'track' }
    for _, t in ipairs(w) do if SC[t] then ctx.state.qscope = SC[t] end end
    local what = w[1] and not SC[w[1]] and w[1] or nil
    if what and ctx.quant_do then ctx.quant_do(what) elseif ctx.quant_menu then ctx.quant_menu() end
  elseif cmd == 'eu' or cmd == 'euclid' then   -- 30 окт: :eu k [n] [r] — Евклид геометрией айтема (зациклен до конца паттерна)
    local w = {}; for t in (arg or ''):gmatch('%S+') do w[#w + 1] = tonumber(t) end
    if not w[1] then V.msg = ':eu k [n] [r] - k hits in n rows (n: default 16), rotated by r; a looped MIDI item from the cursor to the pattern end'
    elseif ctx.euclid_here then ctx.euclid_here(w[1], w[2], w[3]) end
  elseif cmd == 'viper' then if ctx.viper_toggle then ctx.viper_toggle() end   -- 29 окт: viper — трекер как часть REAPER
  elseif cmd == 'manual' or cmd == 'help' then if ctx.help_big then ctx.help_big() end   -- 29 окт: справка панелью
  elseif cmd == 'console' then if ctx.console_open then ctx.console_open() end   -- 28 окт: консоль Strudel
  elseif cmd == 'reload' then ctx.reloading = true; return 'quit'   -- 15 окт: перезапуск со свежими файлами (правки без рестарта REAPER)
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
      for _, h in ipairs(heads) do if h.kind == 'audio' then ctx.edit.set_fx({ h }, lpb(), dir == 'in' and 'SI' or 'SO', xx) end end
    end
  elseif cmd == 'step' and arg == 'auto' then V.step_auto = not V.step_auto; V.step_next = false; V.msg = 'step: ' .. (V.step_auto and 'auto (to the end of the inserted item / slice)' or tostring(V.step))
  elseif cmd == 'step' and arg == 'next' then V.step_next = not V.step_next; V.step_auto = false; V.msg = 'step: ' .. (V.step_next and 'next (to the next note / item / command / envelope point of the track)' or tostring(V.step))
  elseif cmd == 'step' and n then V.step = math.max(0, math.floor(n)); V.step_auto = false; V.step_next = false
  elseif cmd == 'oct' and n then V.octave = math.max(0, math.min(8, math.floor(n)))
  elseif cmd == 'inst' and n then ctx.pool_select(math.floor(n))
  elseif cmd == 'follow' then st.follow = not st.follow
  elseif cmd == 'shotpane' then if ctx.shot_pane then ctx.shot_pane(arg) end   -- 17 окт: снимок панели в help/
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
    -- вкладка item — внутренний id sample; orca — garden
    local a = (arg == 'automation' or arg == 'auto') and 'automation' or ((arg == 'mod' or arg == 'modulate' or arg == 'modulation') and 'modulation') or ((arg == 'item') and 'sample' or ((arg == 'orca') and 'garden' or arg))
    st.toptab = (a == 'sample' or a == 'automation' or a == 'modulation' or a == 'midi' or (a == 'grid' and st.gridtab) or a == 'retro' or (a == 'garden' and st.dev)) and a or 'master'
  elseif cmd == 'scopemode' then ctx.scopemode(arg ~= '' and arg or nil)
  elseif cmd == 'retro' then
    st.top = true; st.toptab = 'retro'
    if arg == 'add' then ctx.retro_add() end
  elseif cmd == 'pool' or cmd == 'top' then st.top = not st.top
  elseif cmd == 'meters' then st.meters = not st.meters
  elseif cmd == 'wave' then ctx.wave_mode(arg ~= '' and arg or nil)
  elseif cmd == 'lock' then st.lock = not st.lock; V.msg = 'lock to REAPER cursor: ' .. (st.lock and 'on' or 'off')
  elseif cmd == 'blood' then st.bloodviz = not st.bloodviz; V.msg = 'blood visualizer: ' .. (st.bloodviz and 'on' or 'off') .. ' (experimental)'
  elseif cmd == 'printjumps' or cmd == 'pj' then ctx.print_jumps()   -- 1 ноя: ZB / ZJ — на таймлайн
  elseif cmd == 'fprint' then ctx.fprint_cmd()   -- 1 ноя: отпечатки звуков индекса карты
  elseif cmd == 'similar' or cmd == 'sim' then ctx.similar_cmd()
  elseif cmd == 'sand' then st.sand = not st.sand; V.msg = 'sand visualizer: ' .. (st.sand and 'on' or 'off') .. ' (experimental)'
  elseif cmd == 'frame' then   -- 31 окт: рамка трекера; без аргумента — меню
    local function set(v) st.framefx = v; st.cracks = v ~= 'off'; V.msg = 'frame: ' .. v end
    if arg ~= '' then set(arg) else
      local items = {}
      for k, v in pairs({ o = 'off', c = 'cracks', b = 'blood', l = 'lightning', v = 'vhs' }) do items[#items + 1] = { key = k, label = v .. ((st.framefx == v) and '  *' or ''), fn = function() set(v) end } end
      V.open_hydra({ title = 'frame of the tracker (experimental; red in INSERT)', items = items })
    end
  elseif cmd == 'cracks' then st.framefx = st.cracks and 'off' or 'cracks'; st.cracks = not st.cracks; V.msg = 'cracks: ' .. (st.cracks and 'on' or 'off') .. ' (experimental; options look)'
  elseif cmd == 'fixed' then st.fixed = not st.fixed; V.msg = 'fixed cursor: ' .. (st.fixed and 'on' or 'off')
  elseif cmd == 'xfade' then
    if n then ctx.xfade_len(0, math.floor(n)) elseif arg == 'now' then ctx.xfade_now() elseif arg == 'off' or arg == 'on' then if (arg == 'on') ~= (st.xfade == true) then ctx.xfade_toggle() end else ctx.xfade_toggle() end
  elseif cmd == 'mxzoom' then ctx.mx_zoom()
  elseif cmd == 'trim' then if ctx.mx_trim then ctx.mx_trim() end
  elseif cmd == 'quantize' or cmd == 'squant' then ctx.smart_quantize()
  elseif cmd == 'tname' then ctx.rename_track(arg)
  elseif cmd == 'fxdump' then if ctx.fxdump then ctx.fxdump() end   -- 22 окт: снимок параметров модуля DSP под курсором (PLAN_DSP этап 0)
  elseif cmd == 'snapname' then if ctx.msn_name then ctx.msn_name(arg) end   -- 22 окт: имя снапшота микшера (prompt for name)
  elseif cmd == 'fxname' then if ctx.fx_rename then ctx.fx_rename(arg) end
  elseif cmd == 'zone' then if ctx.zone_cmd then ctx.zone_cmd(arg) end   -- 25 окт
  elseif cmd == 'iname' then ctx.rename_inst(arg)
  elseif cmd == 'orca' then ctx.garden_cmd(arg ~= '' and arg or 'show')
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
    if arg and arg ~= '' then if ctx.apply_theme(arg) then V.msg = 'theme: ' .. arg end else V.msg = 'themes: ' .. table.concat(ctx.theme_list and ctx.theme_list() or { 'reaper' }, ' ') end
  elseif cmd == 'name' then ctx.mx_name(arg)
  elseif cmd == 'sec' then if ctx.sec_cmd then ctx.sec_cmd(arg) end   -- 18 окт: секция слота курсора матрицы
  elseif cmd == 'gain' then if ctx.gain_toggle then ctx.gain_toggle() end   -- 18 окт: измерители между эффектами
  elseif cmd == 'pal' then   -- 18 окт: палитра — playlist (30 окт: render / kb убраны вместе с clipkb)
    if arg == 'playlist' then ctx.palette_to_playlist() else V.msg = 'pal playlist' end
  elseif cmd == 'pnote' then if ctx.pat_note_set then ctx.pat_note_set(arg) end   -- 18 окт: заметка паттерна
  elseif cmd == 'redo' then ctx.edit.redo(); V.msg = 'redo'                     -- 5 окт: Ctrl+R теперь вкладка rec
  elseif cmd == 'undo' then ctx.edit.undo(); V.msg = 'undo'
  elseif cmd == 'iprop' then local k, v = (arg or ''):match('^(%S+)%s*(.*)$'); if k and ctx.item_prop then ctx.item_prop(k, v or '') end   -- свойства item (5 окт)
  elseif cmd == 'optsave' then ctx.opt_save(arg)                -- профили опций (5 окт)
  elseif cmd == 'keys' then if ctx.keys_export then ctx.keys_export() end   -- 15 окт: все клавиши текстом (Data/jf_tracker_keys.md)
  elseif cmd == 'optload' then ctx.opt_load(arg)
  elseif cmd == 'optdel' then ctx.opt_del(arg)
  elseif cmd == 'len' then ctx.mx_len(arg)
  elseif cmd == 'pat' then if ctx.slot_set_pattern then ctx.slot_set_pattern(tonumber(arg)) end   -- 10 окт: :pat N — паттерн N в слот курсора матрицы
  elseif cmd == 'sig' then ctx.sig_cmd(arg)
  elseif cmd == 'rgbpm' then if ctx.region_bpm then ctx.region_bpm(arg) end   -- 13 окт: окно BPM паттерна (колонка матрицы)
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
  elseif cmd == 'tempoclean' then if ctx.tempo_clean then ctx.tempo_clean() end   -- 25 окт
  elseif cmd == 'pads' or cmd == 'patternkb' then if ctx.pads_cmd then ctx.pads_cmd(arg) end   -- 17 окт: MPC pads (18 окт: patternkb)
  elseif cmd == 'pl' or cmd == 'playlist' or cmd == 'ch' or cmd == 'chain' or cmd == 'seq' then   -- 31 окт: seq (было chain — путалось с цепью DSP)   -- 19 окт: chain (бывший playlist) if ctx.pl_cmd then ctx.pl_cmd(arg) end   -- 18 окт: playlist матрицы
  elseif cmd == 'section' then if ctx.section_make then ctx.section_make(arg) end   -- 17 окт: секция поверх слотов
  elseif cmd == 'tsec' then if ctx.tsel_section_named then ctx.tsel_section_named(arg) end   -- 18 окт: секция из time selection
  elseif cmd == 'unstack' then if ctx.unstack then ctx.unstack() end   -- 17 окт: стопка паттернов → подряд
  elseif cmd == 'patternize' then if ctx.patternize_cmd then ctx.patternize_cmd(arg) end   -- 12 окт: = меню матрицы
  elseif cmd == 'presetsave' then if ctx.preset_save then ctx.preset_save(arg) end   -- 16 окт: трек курсора — пресетом (шаблон без items)
  elseif cmd == 'macset' then if ctx.mac_set then ctx.mac_set(arg) end   -- 16 окт: поле макроса из редактора вкладки macros
  elseif cmd == 'drumstr' then if ctx.drumstr_cmd then ctx.drumstr_cmd(arg) end   -- 16 окт: drumrs5k — запечь растяжку пэда: rate semitones
  elseif cmd == 'codes' then if ctx.codes_cmd then ctx.codes_cmd(arg) end   -- 12 окт: конвертер кодов паттернов (= меню матрицы c h d)
  elseif cmd == 'shiftrec' then if ctx.shift_rec then ctx.shift_rec() end   -- 12 окт: = кнопка shift под rec
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
    -- :interp [vol|delay|note|код команды] (4 окт, из Paketti — Esa Ruoho):
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
      else for _, fx in ipairs(h.fx or {}) do if fx:sub(1, 2) == letter then return tonumber(fx:sub(3), 16) end end end
    end
    local n = 0
    E.run('interpolate ' .. what, function()
      for fi = math.min(f0, f1), math.max(f0, f1) do
        local hs = V.heads_in(fi, fi, r0, r1)
        table.sort(hs, function(a, b) return a.row0 < b.row0 end)
        local letter = (#what == 2) and what:upper() or nil
        if what == 'cmd' and hs[1] then letter = ((hs[1].fx or {})[1] or ''):sub(1, 2) end
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
  elseif cmd == 'spset' then if ctx.sp_set_value then ctx.sp_set_value(arg) end   -- 15 окт: ввод значения свойства сэмпла (клик по числу)
  elseif cmd == 'arcforget' then if ctx.arc_forget then ctx.arc_forget() end   -- 15 окт: arc — забыть назначения эффекта
  elseif cmd == 'mackey' then if ctx.mac_key then ctx.mac_key(arg) end   -- 15 окт: :mackey имя x — макрос на регистр @x
  elseif cmd == 'og' then if ctx.pt_toggle then ctx.pt_toggle() end   -- 31 окт: OG-mode слит с PT-mode
  elseif cmd == 'phedit' then if ctx.phr_edit_toggle then ctx.phr_edit_toggle(arg ~= '' and arg or nil) end   -- 31 окт: правка фразы / назад
  elseif cmd == 'phrename' then   -- 31 окт: :phrename OLD NEW (панель phrases, r)
    local a, b = (arg or ''):match('^(%S+)%s+(%S+)')
    if a and ctx.phr_rename then ctx.phr_rename(a, b) else V.msg = ':phrename OLD NEW' end
  elseif cmd == 'phrase' or cmd == 'ph' then   -- 31 окт: фраза из блока (V) или паттерна курсора — PLAN_PHRASES.md шаг 2
    if ctx.phrase_make then ctx.phrase_make(arg) end
  elseif cmd == 'dedouble' then
    -- 14 окт: :dedouble — одинаковые ноты в одно время на строке курсора трека (все подколонки);
    -- VISUAL — в выделении
    local hs = {}
    if V.cmd_from == 'visual' or V.cmd_from == 'vline' then
      local f0, f1, r0, r1 = V.visual_range(); hs = V.heads_in(f0, f1, r0, r1)
    else
      local F = flat(); local col = F[V.cur.fi] and F[V.cur.fi].col
      for fi, f in ipairs(F) do
        if f.col == col and not f.env then for _, h in ipairs(V.heads_in(fi, fi, V.cur.row, V.cur.row)) do hs[#hs + 1] = h end end
      end
    end
    local n = ctx.edit.dedouble(hs, lpb())
    V.mode = 'normal'
    V.msg = n > 0 and ('dedouble: %d doubled note(s) removed'):format(n) or 'dedouble: no doubled notes on this row of the track'
  elseif cmd == 'xf' then
    -- 15 окт: модификаторы (jf_tracker_xform): VISUAL — блок, иначе трек курсора в регионе
    local XF = ctx.XF
    local name, num   -- 29 окт: «and» срезал число (:xf rotate 4 → без 4)
    if XF then name, num = XF.parse(arg) end
    if not name then V.msg = ':xf stretch k | reverse | rotate n | shuffle | gravity g | bounce r | fib | tuplet n | golden | vel k'; return end
    local hs, r0, r1
    if V.cmd_from == 'visual' or V.cmd_from == 'vline' then
      local f0, f1; f0, f1, r0, r1 = V.visual_range(); hs = V.heads_in(f0, f1, r0, r1); r1 = r1 + 1
    else
      local F = flat(); local col = F[V.cur.fi] and F[V.cur.fi].col
      if ctx.region_rows then r0, r1 = ctx.region_rows() end
      if not r0 then V.msg = 'xf: select a block (v) or put the cursor in a region'; return end
      r1 = r1 + 1                                             -- region_rows отдаёт последнюю строку включительно
      hs = {}
      for fi, f in ipairs(F) do
        if f.col == col and not f.env then for _, h in ipairs(V.heads_in(fi, fi, r0, r1 - 1)) do hs[#hs + 1] = h end end
      end
    end
    if #hs == 0 then V.msg = 'xf: no notes in the block'; return end
    local ev = {}
    for i, h in ipairs(hs) do ev[i] = { row = (h.row0 or 0) + (h.delay or 0) / 256, v = (tonumber(h.vol or '80', 16) or 128) / 255 } end
    local out = XF.apply(name, ev, r0, r1, num)
    local rows, vols = {}, {}
    local moved, changed = false, false
    for _, e in ipairs(out) do
      rows[e.i] = e.row; vols[e.i] = e.v
      if math.abs(e.row - ev[e.i].row) > 1e-6 then moved = true end
      if math.abs((e.v or 0) - (ev[e.i].v or 0)) > 1e-6 then changed = true end
    end
    local n = ctx.edit.retime(hs, lpb(), moved and rows or nil, changed and vols or nil, 'xf ' .. name)
    V.seed = (V.seed or 1) + 1
    V.mode = 'normal'
    V.msg = ('xf %s: %d note(s), rows %d..%d'):format(name, n, r0, r1 - 1)
  elseif cmd == 'human' then
    -- 17 окт: :human [all | nopitch | notime] [N%] — humanizer уже стоящих нот: VISUAL — блок, иначе трек курсора в регионе
    local mode = (arg or ''):match('%a+') or 'all'
    local amt = (tonumber((arg or ''):match('(%d+)%%?')) or 100) / 100
    local opt = { time = true, pitch = true, vol = true, pan = true, attack = true, len = true }
    if mode == 'nopitch' then opt.pitch = false elseif mode == 'notime' then opt.time = false end
    local hs = V.hum_heads(V.cmd_from == 'visual' or V.cmd_from == 'vline')
    local n = ctx.edit.humanize_notes(hs, lpb(), opt, amt)
    V.mode = 'normal'
    V.msg = ('human %s %d%%: %d note(s) a little different (u - undo)'):format(mode, math.floor(amt * 100 + 0.5), n)
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
  elseif cmd == 'mem' then if ctx.mem then ctx.mem() end   -- 21 окт: кто держит память Lua
  elseif cmd == 'memprof' then if ctx.memprof then ctx.memprof(arg) end   -- 21 окт: кто делает мусор (выборка по строкам)
  elseif cmd == 'transpose' and arg and arg:match('^d%-?%d+$') then V.transpose_scope('sel', tonumber(arg:sub(2)), nil, true)   -- 21 окт: :transpose d2 — по ступеням лада
  elseif cmd == 'transpose' then if arg and tonumber(arg) then V.transpose_scope('sel', math.floor(tonumber(arg))) else V.transpose_smart() end   -- 12 окт
  elseif cmd == 'audio' then if ctx.audio_cmd then ctx.audio_cmd(arg) end   -- 10 окт: dev <имя> | bs N | sr N | apply
  elseif cmd == 'logo' then if ctx.logo_show then ctx.logo_show(arg) end
  elseif cmd == 'dev' then if ctx.dev_set then ctx.dev_set(arg) end
  elseif cmd == 'tutorial' or cmd == 'tutor' then if ctx.tutorial then ctx.tutorial(arg == 'text') end
  elseif cmd == 'vis' then if ctx.vis_set then ctx.vis_set(V.cur.row, arg) end   -- 13 окт: событие visor текстом в строке курсора
  elseif cmd == 'mcmd' then if ctx.mcmd_set then ctx.mcmd_set(V.cur.row, arg) end   -- 11 окт: команда мастера (маркер) в строке курсора
  elseif cmd == 'metro' then                                 -- 13 окт: :metro — вкл / выкл, :metro menu — выпадашка
    if arg == 'menu' then ctx.metro_menu() else reaper.Main_OnCommand(40364, 0); V.msg = 'metronome ' .. (reaper.GetToggleCommandState(40364) == 1 and 'on' or 'off') end
  elseif cmd == 'vzsave' then if ctx.visor_save then ctx.visor_save(arg) end   -- 13 окт: пресет визора
  elseif cmd == 'vzset' then if ctx.visor_set then ctx.visor_set(arg) end
  elseif cmd == 'libsave' then if ctx.kit_save then ctx.kit_save(arg) end
  elseif cmd == 'libdir' then if ctx.files_to_folder_named then ctx.files_to_folder_named(arg) end   -- 27 окт: Opt+Enter — новая папка lib
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
      local n = ctx.edit.legato(f.col.track, lane_idx, t0, t1, w == 'off', w == 'fill')
      V.msg = ('legato%s: %d note(s) on %s'):format(w == 'off' and ' off' or (w == 'fill' and ' fill (lengths only, the loop of the instrument plays on)' or ''), n, f.col.name or '')
    end
    ctx.model.invalidate()
  elseif cmd == 'pmtag' then if ctx.pm_set_tags then ctx.pm_set_tags(arg) end
  elseif cmd == 'chord' then if ctx.chord_cmd then ctx.chord_cmd(arg) end   -- 8 окт: вид аккордов / гармонайзер
  elseif cmd == 'chd' then if ctx.chd_set then ctx.chd_set(V.cur.row, arg) end   -- 21 окт: аккорд в колонке chord мастера
  elseif cmd == 'key' then if ctx.key_cmd then ctx.key_cmd(arg) end   -- 21 окт: лад песни
  elseif cmd == 'prog' then if ctx.prog_cmd then ctx.prog_cmd(arg) end   -- 21 окт: прогрессия в колонку chord мастера
  elseif cmd == 'harmonize' then if ctx.harmonize_cmd then ctx.harmonize_cmd(arg) end   -- 21 окт: мелодия → аккорды
  elseif cmd == 'gui' then if ctx.fxgui_cmd then ctx.fxgui_cmd() end   -- 27 окт: окно плагина поверх блока DSP
  elseif cmd == 'neg' then if ctx.negative_cmd then ctx.negative_cmd() end   -- 27 окт: негативная гармония
  elseif cmd == 'pitch' then if ctx.pitch_mark then ctx.pitch_mark() end   -- 26 окт: высота сэмпла → take-маркеры
  elseif cmd == 'tr' then V.tr_cmd(arg)   -- 26 окт: транспоз в стиле Vim (:tr +3, :tr track d2, :tr chord, :tr ji)
  elseif cmd == 'offnotes' then V.offnotes(arg == 'all')   -- 26 окт: OFF сразу после каждой ноты
  elseif cmd == 'nooff' then V.nooff(arg == 'all')   -- 26 окт: убрать все OFF (трек / all) в том, что видно
  elseif cmd == 'transcribe' then if ctx.transcribe_cmd then ctx.transcribe_cmd() end   -- 21 окт: соло → MIDI (jf_transcribe)
  elseif cmd == 'bass' then if ctx.bass_cmd then ctx.bass_cmd(arg) end   -- 21 окт: бас по колонке chord
  elseif cmd == 'voice2' then if ctx.voice2_cmd then ctx.voice2_cmd(arg) end   -- 21 окт: второй голос в ладу
  -- 6 окт: птичий вид убран — :macro теперь зум-аут (строка = доля), повтор — прежний LPB
  elseif cmd == 'macro' then if ctx.zoom_out_toggle then ctx.zoom_out_toggle() end
  elseif cmd == 'unfold' then V.unfold_zoom()   -- 20 окт: = zu
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
-- 16 окт: клавиша INSERT как команда NORMAL, потом снова INSERT (оператор d… дождётся движения и вернёт)
local function ins_as_normal(c2)
  V.mode = 'normal'
  local r = V.key_impl(c2)
  if V.mode == 'normal' then
    if V.pending or V.op then V.back_insert = true else V.mode = 'insert' end
  end
  return r
end
local function keys_control(c)
  local ch = (c < 256) and string.char(c) or ''
  if ctx.keys_renoise and ctx.keys_renoise() and ctx.piano[c] then return false end   -- 13 окт: renoise — нижний ряд играет ноты
  -- 16 окт: frow — цифры и F-ряд играют ноты (- = — тоже ноты, не LPB), октава [ ], громкость { };
  -- буквы свободны — всё остальное в INSERT это команды Vim (как в NORMAL), цифры — не счётчик, а ноты
  if ctx.keys_frow and ctx.keys_frow() then
    if ctx.piano[c] then return false end
    local nb, nhow = V.note_key(c, ctx.mods and ctx.mods() or {})
    if nb and ctx.piano[nb] and nhow ~= 'cmd' then return false end   -- Option / Ctrl+Shift + нота (Shift — с опцией preview)
    if ch == '[' then V.octave = math.max(0, V.octave - 1); V.msg = 'octave ' .. V.octave; return true end
    if ch == ']' then V.octave = math.min(8, V.octave + 1); V.msg = 'octave ' .. V.octave; return true end
    if c == 123 or c == 125 then V.vel = math.max(1, math.min(127, (V.vel or 100) + (c == 125 and 8 or -8))); V.msg = 'velocity ' .. V.vel; return true end
    if c == ('`'):byte() or c == ('~'):byte() then return false end   -- note-off — у INSERT свой
    ins_as_normal(c); return true
  end
  -- 14 окт: renoise — c в нотах, громкость { } (Shift к октаве [ ])
  if ctx.keys_renoise and ctx.keys_renoise() and (c == 123 or c == 125) then
    V.vel = math.max(1, math.min(127, (V.vel or 100) + (c == 125 and 8 or -8))); V.msg = 'velocity ' .. V.vel; return true
  end
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
local SHIFTED = { ['@'] = '2', ['#'] = '3', ['%'] = '5', ['^'] = '6', ['&'] = '7', ['('] = '9', [')'] = '0',
                  ['!'] = '1', ['$'] = '4', ['*'] = '8', ['_'] = '-', ['+'] = '=' }   -- 16 окт: frow — белые 1 4 8 - = тоже слушаются Shift
V.SHIFTED = SHIFTED
local OPTCH = { [339] = 'q', [8721] = 'w', [180] = 'e', [174] = 'r', [8224] = 't', [165] = 'y', [168] = 'u',
                [710] = 'i', [248] = 'o', [960] = 'p' }
                -- 16 окт: Option+цифры — снова только инструменты (15 окт были диезами аккорда — спорили с Opt+1)
-- 16 окт: Shift+Option (раскладка US) — pitch слайса; Option+цифра больше не спорит с выбором инструмента Opt+1
local SHOPTCH = { [338] = 'q', [8222] = 'w', [8240] = 'r', [711] = 't', [193] = 'y', [216] = 'o', [8719] = 'p',
                  [8260] = '1', [8250] = '4', [176] = '8', [8212] = '-', [177] = '=',   -- 16 окт: frow — Shift+Option на белых 1 4 8 - =
                  [8364] = '2', [8249] = '3', [64257] = '5', [64258] = '6', [8225] = '7', [183] = '9', [8218] = '0',
                  [184] = 'z', [205] = 's', [731] = 'x', [206] = 'd', [199] = 'c', [9674] = 'v', [733] = 'g',
                  [305] = 'b', [211] = 'h', [732] = 'n', [212] = 'j', [194] = 'm' }
-- 17 окт: Option+цифра (US) и Option+нижний ряд renoise — те же клавиши нот
local OPTDIGCH = { [161] = '1', [8482] = '2', [163] = '3', [162] = '4', [8734] = '5', [167] = '6', [182] = '7', [8226] = '8',
                   [170] = '9', [186] = '0', [8211] = '-', [8800] = '=',
                   [937] = 'z', [223] = 's', [8776] = 'x', [8706] = 'd', [231] = 'c', [8730] = 'v', [169] = 'g', [8747] = 'b',
                   [729] = 'h', [732] = 'n', [8710] = 'j', [181] = 'm', [8804] = ',', [172] = 'l', [8805] = '.', [8230] = ';', [247] = '/' }
-- 17 окт: модификаторы на нотной клавише — одна схема (пользователь):
--   Shift — прослушать; Option — выбранный слайс на высоте клавиши (без нарезки — нота рядом, аккорд);
--   Option+Shift — прослушать это; Ctrl — слайс от клавиши до конца сэмпла (playthru одной ноты; без нарезки —
--   нота с удержанием); Ctrl+Shift — прослушать это; Cmd — не нота (Cmd+цифра — канал, Cmd+F1 F2 — микротон)
function V.note_key(c, mods)
  mods = mods or {}
  local cp = (c >= 0x75000000 and c < 0x76000000) and (c - 0x75000000) or c   -- 'u'-префикс не-ASCII (5 окт)
  local ch = (c < 256) and string.char(c) or ''
  local function unshift(b)
    local cb = (b < 256) and string.char(b) or ''
    if SHIFTED[cb] then return SHIFTED[cb]:byte() end
    if cb:match('^%u$') then return cb:lower():byte() end
    return b
  end
  if mods.cmd then return c, 'cmd' end
  -- 17 окт (2): Ctrl+цифра — всегда шаг; Ctrl+нота — не нота (удержание убрано), Ctrl+Shift+нота — слайс до конца
  if mods.ctrl then
    local base = (c >= 1 and c <= 26) and (c + 96) or unshift(c)
    return base, mods.shift and 'thru' or 'cmd'
  end
  if mods.alt then
    local m = SHOPTCH[cp] or OPTCH[cp] or OPTDIGCH[cp]
    local base = m and m:byte() or unshift(c)
    if mods.shift or SHOPTCH[cp] then return base, (ctx.state and ctx.state.shiftlisten) and 'pitch_aud' or 'cmd' end
    return base, 'pitch'
  end
  -- 17 окт: прослушивание Shift (и Option+Shift) — только с опцией Shift+keys preview (по умолчанию выкл,
  -- как в Renoise: послушать — выйти из INSERT, клавиши играют в KEYS); без неё Shift+клавиша — команда / хоткей
  local aud = ctx.state and ctx.state.shiftlisten
  if SHOPTCH[cp] then return SHOPTCH[cp]:byte(), aud and 'pitch_aud' or 'cmd' end
  if OPTCH[cp] then return OPTCH[cp]:byte(), 'pitch' end
  if not aud and (mods.shift or SHIFTED[ch] or ch:match('^%u$')) then return c, 'cmd' end
  if mods.shift and c > 255 and ctx.piano and ctx.piano[c] then return c, 'audition' end   -- frow: Shift+F (чёрная)
  if SHIFTED[ch] then return SHIFTED[ch]:byte(), 'audition' end
  if ch:match('^[QWERTYUIOP]$') then return ch:lower():byte(), 'audition' end
  if mods.shift and ch:match('^%u$') then return ch:lower():byte(), 'audition' end
  if mods.shift then return c, 'audition' end
  return c, 'insert'
end
-- 17 окт: нотная клавиша с Ctrl / Option в INSERT при клавиатуре (поле ноты) — нота, не хоткей: шаг Ctrl+цифра,
-- инструмент Option+цифра, Ctrl+h j k l, Ctrl - + и др. пропускают её (транспоз F — при выключенной клавиатуре)
function V.mod_note(c)
  if not (V.mode == 'insert' and V.piano and (V.cur.field or 1) == 1 and ctx.piano) then return false end
  local m = ctx.mods and ctx.mods() or {}
  if m.cmd or not (m.ctrl or m.alt) then return false end
  if m.ctrl and not m.shift then return false end   -- 17 окт (2): Ctrl+цифра / - + — шаг, не нота
  if m.ctrl and (c == 45 or c == 61 or c == 95 or c == 43 or c == 31) then return false end
  local b = V.note_key(c, m)
  return ctx.piano[b] ~= nil
end

-- 18 окт: клавиша сейчас сыграет ноту (KEYS / INSERT с клавиатурой в поле ноты) — справка на ней не вспыхивает
function V.plays_note(c)
  if not (V.piano and ctx.piano) or V.pending or V.op or V.picker or V.hydra then return false end
  local nm = V.mode == 'normal' or V.mode == 'visual' or V.mode == 'vline'
  if not (nm or (V.mode == 'insert' and (V.cur.field or 1) == 1)) then return false end
  local base, how = V.note_key(c, ctx.mods and ctx.mods() or {})
  return how ~= 'cmd' and ctx.piano[base] ~= nil
end

function V.key_impl(c)
  -- 31 окт: INSERT на hex-поле (лейн CC / PC / AT, команда): d набирался цифрой D, и w после него был простым
  -- движением — dw не удалял. D одна в наборе + w W b e (не hex-цифры) = оператор d, как везде
  if V.mode == 'insert' and (c == 119 or c == 87 or c == 98 or c == 101) and V.hexbuf and V.hexbuf:upper() == 'D' then
    V.hexbuf = nil; V.mode = 'normal'; V.pending = 'd'; V.count = nil; V.back_insert = true
  end
  if c <= 0 then return end
  local E = ctx.edit
  local st = ctx.state
  local n = V.count or 1
  -- 31 окт: Ctrl+Shift+A / X — крупный шаг: нота ±12 (октава), огибающая ±1/16, прочее (vol, команды, CC) ±16 (0x10)
  if (c == 1 or c == 24) and V.mode ~= 'cmd' and V.mode ~= 'search' and ctx.mods and ctx.mods().shift and ctx.mods().ctrl then
    local f = flat()[V.cur.fi]
    local big = (f and f.env) and 4 or (((V.cur.field or 1) == 1 and not (f and f.ml)) and 12 or 16)
    n = n * big; V.count = n
  end

  -- открытые fzf-пикер и hydra — первыми (4 окт: меню нарезки s открывалось
  -- поверх слайсера, а t / 8 … забирал слайсер как ноты — «st не резал»)
  if V.picker then V.picker_key(c); return end
  if V.hydra then V.hydra_key(c); return end
  -- 16 окт: курсор в колонке волны: s — разрезать ноту на строке, S — stretch-маркер (ещё раз — убрать), x убрать,
  -- J K — удар строки на строку вниз / вверх (a — огибающие, не трогаем)
  if V.cur.sub == 'wave' and not V.pending and not V.op and (V.mode == 'normal' or V.mode == 'insert') and ctx.wave_key then
    local wch = (c < 256) and string.char(c) or ''
    if wch == 's' then
      local hs = V.covering(V.cur.fi, V.cur.row)
      if hs and hs[1] then ctx.edit.split(hs, lpb(), V.cur.row); V.msg = 'cut at this row (S - a stretch marker instead)' else V.msg = 'wave: no note on this row' end
      V.count = nil; return
    end
    if wch == 'S' or wch == 'x' or wch == 'J' or wch == 'K' then
      local hs = V.covering(V.cur.fi, V.cur.row)
      if hs and hs[1] then ctx.wave_key(wch == 'S' and 'enter' or wch, hs[1], V.cur.row, V.count or 1) else V.msg = 'wave: no audio note on this row' end
      V.count = nil; return
    end
  end
  -- 15 окт: Esc при набранном счётчике (или d в лейне мастера) — только сброс набора, режим не меняется
  if c == ESC and not V.pending and (V.count or V.mlpend) then V.count, V.mlpend = nil, nil; V.msg = ''; return end
  -- слайсер (оверлей) перехватывает всё остальное — кроме выбора инструмента /
  -- трека (10 окт: Opt+J / K из браузера молча съедал открытый слайсер):
  -- Option+hjkl, Option+цифра, Cmd+цифра идут дальше, как без слайсера
  -- 10 окт: Opt+D (∂) во вкладке item — модуль детектора транзиентов (слайсер откроется, если закрыт)
  do
    local cpd = (c >= 0x75000000 and c < 0x76000000) and (c - 0x75000000) or c
    local m1 = ctx.mods and ctx.mods() or {}
    -- 20 окт: Opt+W (∑) в NORMAL — курсор на мастер (сложенный раскрывается); в INSERT Option+w — нота, как была
    -- 20 окт: Shift+Ctrl+F — найти сэмпл для этого места и поставить его в сэмплер (Shift+F — аудио item)
    -- 29 окт: Shift+Opt+F — в сэмплер, Ctrl+Shift+F — выбрать базу (просьба: Shift+F — аудио item, сэмплер — Shift+Opt+F)
    if c == 6 and m1.ctrl and m1.shift and V.mode == 'normal' and st.focus == 'tracker' and ctx.sample_find then ctx.sample_find('pickdb'); return end
    -- 20 окт: Shift+Opt+F (Ï) — выбрать базу для поиска сэмпла этого места (Shift+F — сразу поиск в базе)
    if (cpd == 207 or (m1.alt and m1.shift and (c == 70 or c == 102))) and V.mode == 'normal' and not V.piano and st.focus == 'tracker' and ctx.sample_find then ctx.sample_find('sampler'); return end
    if (cpd == 8721 or (m1.alt and c == 119)) and V.mode == 'normal' and not V.piano and st.focus == 'tracker' and ctx.master_jump then ctx.master_jump(); return end
    -- 24 окт: Opt+V (√) в NORMAL / VISUAL — умное выделение: до конца субдоли, доли, такта, паттерна; в INSERT — нота
    if (cpd == 8730 or (m1.alt and not m1.shift and c == 118)) and (V.mode == 'normal' or V.mode == 'visual' or V.mode == 'vline') and not V.piano and st.focus == 'tracker' and ctx.smart_select then ctx.smart_select(); return end
    if (cpd == 8706 or (m1.alt and (c == 100 or c == 68))) and ctx.slicer_dt and (st.focus == 'sample' or st.focus == 'sprops' or st.focus == 'slices' or (st.focus == 'top' and st.toptab == 'sample')) then ctx.slicer_dt(); return end
  end
  -- 24 окт: слайсер берёт клавиши, только когда фокус на нём (вкладка item / slices / свойства сэмпла); фокус в трекере —
  -- клавиши трекеру (было: открытый слайсер съедал всё — «клавиатура слишком на него влияет»)
  local sl_focus = st.focus == 'slices' or st.focus == 'sprops' or st.focus == 'sample' or (st.focus == 'top' and st.toptab == 'sample')
  if sl_focus and ctx.slicer_active and ctx.slicer_active() then
    local m0 = ctx.mods and ctx.mods() or {}
    local cp = (c >= 0x75000000 and c < 0x76000000) and (c - 0x75000000) or c
    local SEL = { [729] = true, [8710] = true, [730] = true, [172] = true,
                  [161] = true, [8482] = true, [163] = true, [162] = true, [8734] = true, [167] = true, [182] = true, [8226] = true, [170] = true, [186] = true }
    local pass = SEL[cp] or ((m0.cmd or m0.alt) and not m0.ctrl and c >= ('0'):byte() and c <= ('9'):byte())
    if not pass then ctx.slicer_key(c); return end
  end

  -- командная строка (+ подсказка и Tab-дополнение)
  -- 13 окт: окно ввода имени (V.open_prompt): без «:команды» и подсказок. Первая буква / цифра
  -- заменяет имя целиком (оно выделено); стрелки / Home / End / Backspace — правка имени на месте
  if V.prompt and (V.mode ~= 'cmd' or (V.cmdline or ''):sub(1, #V.prompt.pre) ~= V.prompt.pre) then V.prompt = nil end   -- ушли из окна иначе (щелчок)
  if V.mode == 'cmd' and V.prompt then
    local pr = V.prompt
    local back = (V.cmd_from == 'insert') and 'insert' or 'normal'
    local t = V.cmdline:sub(#pr.pre + 1)
    local n = utf8.len(t) or #t
    local function cut(a, b) local ia = utf8.offset(t, a + 1) or (#t + 1); local ib = utf8.offset(t, b + 1) or (#t + 1); return t:sub(1, ia - 1), t:sub(ib) end
    local cp = (c >= 0x75000000 and c < 0x76000000) and (c - 0x75000000) or c
    if c == ESC then V.mode = back; V.cmdline = nil; V.prompt = nil; return
    elseif c == ENTER then local line = V.cmdline; V.mode = back; V.cmdline = nil; V.prompt = nil; return run_cmd(line)
    elseif c == LEFT then pr.pos = math.max(0, pr.pos - 1); pr.fresh = false
    elseif c == RIGHT then pr.pos = math.min(n, pr.pos + 1); pr.fresh = false
    elseif c == 1752132965 then pr.pos = 0; pr.fresh = false
    elseif c == 6647396 then pr.pos = n; pr.fresh = false
    elseif c == BS then
      if pr.fresh then t, pr.pos = '', 0
      elseif pr.pos > 0 then local a, b = cut(pr.pos - 1, pr.pos); t = a .. b; pr.pos = pr.pos - 1 end
      pr.fresh = false
    elseif c == 6579564 then
      if pr.fresh then t, pr.pos = '', 0 elseif pr.pos < n then local a, b = cut(pr.pos, pr.pos + 1); t = a .. b end
      pr.fresh = false
    elseif cp >= 32 and cp ~= 127 and cp < 0x110000 and (cp < 0xF700 or cp > 0xF8FF) then
      local ch = utf8.char(cp)
      if pr.fresh then t, pr.pos = ch, 1
      else local a, b = cut(pr.pos, pr.pos); t = a .. ch .. b; pr.pos = pr.pos + 1 end
      pr.fresh = false
    end
    V.cmdline = pr.pre .. t
    return
  end
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
    elseif c == TAB and ctx.pl_words and ((V.cmdline or ''):match('^pl ') or (V.cmdline or ''):match('^playlist ') or (V.cmdline or ''):match('^ch ') or (V.cmdline or ''):match('^chain ')) then
      -- 18 окт: :pl — Tab дополняет последнее слово именем паттерна / секции (повтор — следующее)
      local line = V.cmdline
      local pc = V.pl_comp
      if not (pc and pc.last == line) then
        local pre, word = line:match('^(.-)(%S*)$')
        local stem, mods = word:match('^(.-)([x%*:/%+%-]%d.*)$')
        if not stem then stem, mods = word, '' end
        pc = { pre = pre, mods = mods, list = ctx.PL.complete(stem, ctx.pl_words()), i = 0 }
      end
      if #pc.list > 0 then
        pc.i = pc.i % #pc.list + 1
        V.cmdline = pc.pre .. pc.list[pc.i] .. pc.mods
        pc.last = V.cmdline; V.pl_comp = pc
        if #pc.list > 1 then V.msg = table.concat(pc.list, ' ') end
      end
    elseif c == TAB then
      local matches, word = V.cmd_matches(V.cmdline)
      if #matches > 0 then
        V.cmd_cycle = ((V.cmd_cycle or 0) % #matches) + 1
        local m = matches[V.cmd_cycle]
        V.cmdline = m[1] .. (m[2] ~= '' and ' ' or '')
      end
    elseif c == BS then V.cmdline = TX.bs(V.cmdline); V.cmd_cycle = nil
    elseif c == 47 and ctx.name_suggest and ctx.name_suggest(V.cmdline or '') then V.cmd_cycle = nil   -- «/» в имени — подсказки
    elseif TX.char(c) then V.cmdline = (V.cmdline or '') .. TX.char(c); V.cmd_cycle = nil end   -- 20 окт: и кириллица
    return
  end

  -- строка поиска
  if V.mode == 'search' then
    local back = (V.cmd_from == 'insert') and 'insert' or 'normal'
    if c == ESC then V.mode = back; V.searchline = nil
    elseif c == ENTER then
      V.search = V.searchline; V.mode = back; V.searchline = nil
      V.find_next(1)
    elseif c == BS then V.searchline = TX.bs(V.searchline)
    elseif TX.char(c) then V.searchline = (V.searchline or '') .. TX.char(c) end
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
    local d = OPTDIG[cp] or ((mods.alt and not mods.shift and c >= ('0'):byte() and c <= ('9'):byte()) and (c - ('0'):byte()) or nil)
    if d and not mods.ctrl and not mods.cmd and V.mode ~= 'cmd' and V.mode ~= 'search' and not V.mod_note(c) then
      if d == 0 then d = 10 end
      if ctx.pool_select then ctx.pool_select(d) end
      V.count = nil; return
    end
  end
  -- 13 окт: вставить пустую строку (Mac без Insert): Option+Backspace — на месте курсора
  -- (Shift — на всех треках); Ctrl+Option+Cmd+J — под курсором, K — над ним
  if V.mode ~= 'cmd' and V.mode ~= 'search' and ctx.time_edit and not env_of(V.cur.fi) then
    -- 17 окт: Shift — все треки (общее правило: ⌫, Opt+⌫, Shift+` note-off)
    local ins_at, all
    if c == BS and mods.alt and not mods.ctrl and not mods.cmd then ins_at = V.cur.row; all = mods.shift or false
    elseif mods.ctrl and mods.alt and mods.cmd and (c == 10 or c == 11 or c == ('j'):byte() or c == ('k'):byte() or c == 8710 or c == 730) then
      ins_at = (c == 10 or c == ('j'):byte() or c == 8710) and V.cur.row + 1 or V.cur.row
      all = mods.shift or false
    end
    if ins_at then
      local nr = V.count or 1
      ctx.time_edit('insert', V.cur.fi, ins_at, nr, all)
      V.count = nil
      V.msg = ('inserted %d empty row(s) %s'):format(nr, all and 'on all tracks' or 'on the track') .. ((ctx.state and ctx.state.view_reg and ctx.state.bsmode ~= 'track') and ' - pattern view: what goes past the pattern end is dropped (as Renoise; zp - project view carries it on)' or '')
      return
    end
  end
  -- 10 окт: Ctrl+цифра — длина шага (step 0..9; 0 — курсор стоит), step auto выкл
  if mods.ctrl and not mods.alt and not mods.cmd and c >= ('0'):byte() and c <= ('9'):byte() and V.mode ~= 'cmd' and V.mode ~= 'search' and not V.mod_note(c) then
    V.step = math.floor(c) - ('0'):byte(); V.step_auto = false; V.step_next = false   -- 18 окт: floor — код клавиши float, шаг показывался 2.0
    V.msg = 'step ' .. V.step .. (V.step == 0 and ' - the cursor stays' or ' row(s)')
    V.count = nil; return
  end
  -- 10 окт: ⌘+цифра — прыжок на канал N (1..9, 0 = 10) в любом режиме (было —
  -- инструмент, теперь он только на Option+цифре); Ctrl+O — назад
  if mods.cmd and not mods.shift and c >= ('0'):byte() and c <= ('9'):byte() and V.mode ~= 'cmd' and V.mode ~= 'search' then   -- 17 окт: и в INSERT (Cmd — не нота)
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
  if hk and V.mod_note(c) then hk = nil end   -- 17 окт: renoise h j l — ноты (Ctrl / Option + нота)
  -- 27 окт: Shift+Opt+J / K — LPB +1 / −1 (J раскрывает строки, K собирает), как + и - (на немецкой раскладке + только с Shift); было транспоз инструмента
  if mods.alt and mods.shift and not mods.ctrl and not mods.cmd and (hk == 'j' or hk == 'k' or c == DOWN or c == UP) and V.mode ~= 'cmd' and V.mode ~= 'search' then
    for _ = 1, n do ctx.set_lpb(nil, (hk == 'k' or c == UP) and -1 or 1) end
    V.msg = 'LPB ' .. ctx.state.lpb .. '  (Shift+Opt+J opens rows / K folds them)'
    V.count = nil; return
  end
  -- 27 окт: Shift+Opt+H / L — колонки трека курсора уже / шире по шагу, как z, / z. (счётчик — N шагов); было playrate инструмента
  if mods.alt and mods.shift and not mods.ctrl and not mods.cmd and (hk == 'h' or hk == 'l' or c == LEFT or c == RIGHT) and V.mode ~= 'cmd' and V.mode ~= 'search' then
    if ctx.width_step then for _ = 1, n do ctx.width_step((hk == 'l' or c == RIGHT) and 1 or -1, 'cur') end end
    V.count = nil; return
  end
  -- повтор паттерна над курсором (4 окт, Paketti): Ctrl+Opt+J / ↓ — трек курсора;
  -- все треки — :repeat all (Shift+Opt+J с 10 окт — транспоз)
  -- 27 окт: Ctrl+Opt+H / L — playrate выбранного инструмента медленнее / быстрее (счётчик — N шагов)
  if mods.alt and mods.ctrl and not mods.cmd and not mods.shift and (hk == 'h' or hk == 'l' or c == LEFT or c == RIGHT) and V.mode ~= 'cmd' and V.mode ~= 'search' then
    if ctx.inst_rate then ctx.inst_rate(((hk == 'l' or c == RIGHT) and 1 or -1) * n) end
    V.count = nil; return
  end
  if mods.alt and mods.ctrl and not mods.cmd and (hk == 'j' or c == DOWN) and V.mode ~= 'cmd' and V.mode ~= 'search' then
    if ctx.repeat_pattern then ctx.repeat_pattern(false) end
    V.count = nil; return
  end
  -- 17 окт: Ctrl+Shift+J / K — конец ноты под курсором на строку позже / раньше, H / L — начало раньше / позже
  -- (время — Ctrl; Opt+Shift — звук: транспоз / playrate инструмента). note_edge с 13 окт не был подключён
  -- 17 окт: в VISUAL Ctrl+Shift+h j k l — двигать само выделение (рамку) на колонку / строку, размер тот же
  if hk and mods.ctrl and mods.shift and not mods.alt and not mods.cmd and (V.mode == 'visual' or V.mode == 'vline') then
    local f0, f1, r0, r1 = V.visual_range()
    local df = (hk == 'h' and -1 or (hk == 'l' and 1 or 0)) * n
    local dr = (hk == 'k' and -1 or (hk == 'j' and 1 or 0)) * n
    if V.mode == 'vline' then df = 0 end
    df = math.max(1 - f0, math.min(nflat() - f1, df)); dr = math.max(-r0, dr)
    V.cur.fi, V.cur.row = V.cur.fi + df, V.cur.row + dr
    if V.vbox then
      V.vbox = { f0 + df, f1 + df, r0 + dr, r1 + dr, at = { fi = V.cur.fi, row = V.cur.row } }
    elseif V.anchor then V.anchor = { fi = V.anchor.fi + df, row = V.anchor.row + dr } end
    V.count = nil; ensure_visible(); return
  end
  if hk and mods.ctrl and mods.shift and not mods.alt and not mods.cmd and (V.mode == 'normal' or V.mode == 'insert') and not V.mod_note(c) then
    if hk == 'j' or hk == 'k' then V.note_edge('end', hk == 'j' and n or -n) else V.note_edge('start', hk == 'l' and n or -n) end
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
        V.open_prompt('step ', ''); return
      end
      -- Shift+стрелки = Shift+hjkl (6 окт)
      local sha = mods.shift and ({ [LEFT] = 'h', [DOWN] = 'j', [UP] = 'k', [RIGHT] = 'l' })[c]
      -- 11 окт: INSERT на поле значения (vol / delay / команда / огибающая) — буквы и есть ввод
      -- (S80, L.., D..), как в Renoise: s и Shift+HJKL не выделяют; выделение — Shift+стрелки
      local valf = V.mode == 'insert' and not sha and (((V.cur.field or 1) > 1) or env_of(V.cur.fi))
      if sha then chs = sha:upper() end
      if not valf and (SH[chs] or (chs == 's' and V.mode == 'insert')) then
        if V.mode ~= 'visual' and V.mode ~= 'vline' then
          if V.mode == 'insert' then V.back_insert = true end
          V.mode = 'visual'; V.vfield, V.vtrack = nil, nil; V.anchor = { fi = V.cur.fi, row = V.cur.row }
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
    -- 31 окт: \ — меню того, что под курсором; \\ — главное (было наоборот)
    -- 1 ноя: в трекере \ — сразу главное меню (меню под курсором — Enter); в модулях — их быстрое меню
    local st = ctx.state
    if st and st.focus == 'tracker' and ctx.main_menu then ctx.main_menu()
    elseif ctx.context_here then ctx.context_here() elseif ctx.main_menu then ctx.main_menu() else V.open_hydra(ctx.hydra_root()) end; return
  end

  record(c)

  -- 11 окт: колонка cmd мастера (маркеры проекта): Enter — текст команды в строке :,
  -- ! — действие REAPER (маркер «!id» REAPER исполняет сам), BS / Del (и x в NORMAL) — удалить
  do
    local cf = flat()[V.cur.fi]
    -- 13 окт: колонки visor и cmd мастера — Vim-правка событий: dd вырезать, yy копировать, p вставить
    -- в строку курсора (перенос = dd j p), c / r — правка текста строкой : (visor: Enter — выбор с превью)
    if cf and cf.ml and (cf.ml.kind == 'vis' or cf.ml.kind == 'cmd' or cf.ml.kind == 'chd') and V.mode == 'normal' then
      local kind, ch = cf.ml.kind, (c > 0 and c < 256) and string.char(c) or ''
      local set = (kind == 'vis' and ctx.vis_set) or (kind == 'chd' and ctx.chd_set) or ctx.mcmd_set   -- 21 окт: и колонка chord
      local e = cf.ml.ev[V.cur.row]
      local pend = V.mlpend; V.mlpend = nil
      if (ch == 'd' or ch == 'y') and pend == ch then
        if not e then V.msg = 'no event on this row'; return end
        V.mlreg = { kind = kind, text = e.text }
        if ch == 'd' and set then set(V.cur.row, '') end
        V.msg = (ch == 'd' and 'cut: ' or 'copied: ') .. e.text .. ' - p puts it on the cursor row'
        return
      end
      -- 15 окт: dw / dW — событие под курсором, иначе ближайшее ниже (как dw в Vim): маркер на мастере
      if pend == 'd' and (ch == 'w' or ch == 'W') then
        local row = V.cur.row
        if not e then
          local best
          for r in pairs(cf.ml.ev or {}) do if r > row and (not best or r < best) then best = r end end
          row, e = best, best and cf.ml.ev[best]
        end
        if not e then V.msg = 'no event below'; return end
        V.mlreg = { kind = kind, text = e.text }
        if set then set(row, '') end
        V.msg = 'cut: ' .. e.text .. ' - p puts it on the cursor row'
        return
      end
      if ch == 'd' or ch == 'y' then V.mlpend = ch; return end
      if ch == 'p' or ch == 'P' then
        local r = V.mlreg
        if not (r and r.kind == kind) then V.msg = 'nothing copied from this column (dd / yy)'; return end
        if set then set(V.cur.row, r.text) end
        return
      end
      if ch == 'c' or ch == 'r' then
        V.cmd_from = V.mode; V.mode = 'cmd'; V.cmdline = ((kind == 'vis' and 'vis ') or (kind == 'chd' and 'chd ') or 'mcmd ') .. (e and e.text or '')
        return
      end
    end
    -- 11 окт: колонка visor (маркеры v:): Enter — выбор сцены / пресета с превью, BS / Del / x — удалить
    if cf and cf.ml and cf.ml.kind == 'vis' and (V.mode == 'normal' or V.mode == 'insert') then
      if c == 13 and ctx.visor_pick then ctx.visor_pick(V.cur.row); return end
      if c == BS or c == DEL or (V.mode == 'normal' and c == ('x'):byte()) then
        if ctx.vis_set then ctx.vis_set(V.cur.row, '') end; return
      end
    end
    -- 21 окт: колонка chord мастера: Enter — аккорды лада ступенями, BS / Del / x — убрать
    if cf and cf.ml and cf.ml.kind == 'chd' and (V.mode == 'normal' or V.mode == 'insert') then
      if c == 13 and ctx.chd_pick then ctx.chd_pick(V.cur.row); return end
      if c == BS or c == DEL or (V.mode == 'normal' and c == ('x'):byte()) then
        if ctx.chd_set then ctx.chd_set(V.cur.row, '') end; return
      end
    end
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
    if chk == ':' then V.cmd_from = 'insert'; V.mode = 'cmd'; V.cmdline = ''; V.prompt = nil; V.hexbuf = nil; return end
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
    -- 1 ноя: PT-mode — Enter и в INSERT вставляет пустую строку (Return ProTracker; Shift — все каналы)
    if c == 13 and ctx.state and ctx.state.ptmode and not env_of(V.cur.fi) and not V.hexbuf and ctx.time_edit then
      ctx.time_edit('insert', V.cur.fi, V.cur.row, 1, ctx.mods and ctx.mods().shift or false); return
    end
    local fld = V.cur.field or 1
    -- MIDI-лейн (6 окт): две hex-цифры — CC / PC в строку (в MIDI item под ней),
    -- BS / Del — события лейна в строке долой; остальное — управление KEYS
    local mlf = flat()[V.cur.fi]
    if mlf and mlf.ml then
      local ml = mlf.ml
      local hx = (c < 256) and string.char(c):upper() or ''
      if c == BS or c == DEL then ctx.ml_del(mlf, V.cur.row); V.hexbuf = nil; return end
      if c == 13 and not V.hexbuf and ctx.lane_menu and ctx.lane_menu() then return end   -- 31 окт: Enter — что вставить
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
    -- (dd x yy p w } счётчики …), после них снова INSERT; форма точки — Ctrl+Opt+1..6 / Enter
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
    -- 13 окт: Backspace на поле ноты — удалить строку: всё ниже поднимается (трек; Shift — все треки),
    -- как в NORMAL; Delete — только событие под курсором
    -- 21 окт: на ноте Backspace удаляет её (как Delete); удалить строку — Backspace на пустой строке
    if c == BS and fld == 1 and #V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row) > 0 and not (ctx.mods and ctx.mods().shift) then
      E.delete(V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row), lpb()); V.msg = 'note deleted (Backspace on an empty row - delete the row)'
      V.hexbuf = nil; return
    end
    if c == BS and fld == 1 and ctx.time_edit then
      ctx.time_edit('delete', V.cur.fi, V.cur.row, 1, ctx.mods and ctx.mods().shift or false)   -- Shift — все треки
      V.hexbuf = nil; return
    end
    if c == DEL and fld == 1 and #V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row) == 0 then
      local em = V.empty_midi_at(V.cur.fi, V.cur.row)
      if em and ctx.delete_item then ctx.delete_item(em); V.msg = 'empty MIDI clip deleted'; V.hexbuf = nil; return end
    end
    if c == BS or c == DEL then
      local heads = V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row)
      if fld == 1 then E.delete(heads, lpb())
      elseif fld == 2 and V.cur.sub == 'pan' then E.set_pan(heads, 128)
      elseif fld == 2 then E.set_vol(heads, lpb(), 128)
      elseif fld == 3 then E.set_delay(heads, lpb(), 0)
      else
        local fc = #heads == 0 and V.fx_cell(V.cur.fi, V.cur.row)   -- 12 окт: строка внутри ноты — её команда
        if fc and fc.off > 0 then
          local f = fc.fx[fld - 3]
          if f then E.clear_fx({ fc.head }, lpb(), f:sub(1, 2), fc.off) end
        end
        for _, h in ipairs(heads) do
          local f = (h.fx or {})[fld - 3]
          if f then E.clear_fx({ h }, lpb(), f:sub(1, 2)) end
        end
      end
      V.hexbuf = nil; return
    end
    if V.cur.sub == 'slc' and fld == 1 then
      -- 11 окт: поле слайса — две hex-цифры, номер слайса ноты (00 — весь сэмпл)
      local ch2 = (c < 256) and string.char(c):upper() or ''
      -- 12 окт: S — как поле показывает (S03): приставка, дальше две цифры
      if ch2 == 'S' and (V.hexbuf or '') == '' then V.msg = 'S__: slice - now two hex digits (00 - the whole sample)'; return end
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
      -- 12 окт: команда на строке без ноты — звучащей ноте (как в Renoise: команда действует на играющую ноту;
      -- у нас команды хранятся в ноте, и показываются у неё)
      if fld >= 4 and #heads == 0 then heads = V.covering(V.cur.fi, V.cur.row) end
      -- 31 окт: gg / G в колонке команд — к началу / концу, как в NORMAL (эффектов GG / G нет: g начинал код 0G)
      if fld >= 4 and ((c == ('G'):byte() and not V.hexbuf) or (c == ('g'):byte() and V.hexbuf and (V.hexbuf:upper() == 'G' or V.hexbuf:upper() == '0G'))) then
        V.hexbuf = nil
        if V.fx_back then V.cur.sub = nil; V.fx_back = nil end
        if c == ('g'):byte() then V.mode = 'normal'; V.pending = 'g'; return as_normal(c) end   -- первая g ушла в набор — gg целиком
        return as_normal(c)
      end
      -- 12 окт: ` в колонке команд — стоп того, что здесь действует (0D… → 0D00), как note-off у ноты
      if fld >= 4 and c == ('`'):byte() then
        V.hexbuf = nil
        V.fx_stop(V.cur.fi, V.cur.row)
        V.cur.row = V.cur.row + step_rows(); ensure_visible(); return
      end
      -- 17 окт: набор не закончен — Enter дописывает нулями (0D1 → 0D10, 0D → 0D00, vol 8 → 80) и пишет;
      -- не цифра на значении (w и т.п.) — набор отменяется, ничего не пишется
      if V.hexbuf and fld >= 2 and not (fld >= 4 and V.cur.sub ~= 'val') then
        if c == 13 then
          local he2
          -- 17 окт: опция hex fill: right (по умолчанию) — набранное — младшие разряды (3 → 03), left — старшие (3 → 30)
          if (ctx.state and ctx.state.hexfill) ~= 'left' then
            local buf = V.hexbuf
            local code = fld >= 4 and buf:sub(1, 2) or ''
            local dig = fld >= 4 and buf:sub(3) or buf
            dig = ('0'):rep(math.max(0, 2 - #dig)) .. dig
            V.hexbuf = fld >= 4 and code or nil
            for k = 1, #dig do he2 = hex_entry(dig:byte(k), fld, heads); if he2 then break end end
          else
            for _ = 1, 4 do
              if not V.hexbuf then break end
              he2 = hex_entry(48, fld, heads)
              if he2 then break end
            end
          end
          V.hexbuf = nil
          if he2 == true then V.cur.row = V.cur.row + step_rows(); ensure_visible() end
          return
        end
        if c < 256 and string.char(c):match('^%a$') and not string.char(c):upper():match('^[0-9A-F]$') and not string.char(c):match('^[hjklHJKL]$') then
          V.msg = (V.hexbuf or '') .. ': cancelled'; V.hexbuf = nil
          if V.fx_back then V.cur.sub = nil; V.fx_back = nil end
          return
        end
      end
      -- 21 окт: Shift+S / Shift+M — соло / mute трека и в колонке команд (строчные s / m — коды: SI…, 0M)
      if (c == 83 or c == 77) and (V.hexbuf or '') == '' and ctx.track_toggle then ctx.track_toggle(c == 77 and 'mute' or 'solo'); return end
      local b0, m0 = V.hexbuf, V.msg
      local he = hex_entry(c, fld, heads)
      if he == 'none' then return end
      if he then V.cur.row = V.cur.row + step_rows(); ensure_visible(); return end
      if V.hexbuf and V.hexbuf ~= b0 then return end   -- набор продолжается
      -- 12 окт: колонка команд — буквы и цифры это код (0x Sx Zx), а не команды NORMAL:
      -- d / y / c … здесь не удаляют и не копируют. Движение (h j k l) — как было
      if fld >= 4 and c < 256 and string.char(c):match('^%w$') and not string.char(c):match('^[hjklHJKL]$') then
        if V.msg == m0 then   -- hex_entry сам не объяснил
          V.msg = (V.hexbuf and (V.hexbuf .. string.char(c):upper() .. ': no such effect') or (V.cur.sub == 'val' and (string.char(c) .. ': the value is two hex digits (h - the code half)') or (string.char(c) .. ': no effect code - D = 0D, U = 0U, S_ / Z_ - SI ZT ...'))) .. ' - Enter: the list'
        end
        return
      end
      V.hexbuf = nil                                   -- 11 окт: чужая клавиша обрывает набор и работает
      if V.fx_back then V.cur.sub = nil; V.fx_back = nil end   -- 12 окт: брошенный код — курсор обратно на код
      if not V.piano then return as_normal(c) end
      keys_control(c); return
    end
    -- 31 окт: note-off — не нота: работает и при выключенной клавиатуре (без неё ` уходил в NORMAL — педаль / весь сэмпл)
    if not V.piano and (c == ('`'):byte() or c == ('~'):byte()) then
      local mods2 = ctx.mods and ctx.mods() or {}
      local tilde = c == ('~'):byte() or mods2.shift
      V.note_off_scope(tilde and (mods2.ctrl and 'track' or 'all') or 'sub')
      V.cur.row = V.cur.row + step_rows(); ensure_visible(); return
    end
    if not V.piano then return as_normal(c) end      -- поле ноты без клавиатуры: ноты не пишутся
    if keys_control(c) then return end
    -- note-off (9 окт): ` — подколонка курсора; 17 окт: ~ (Shift+`) — все треки (Shift = все треки, как у ⌫),
    -- Ctrl+~ — весь трек (было: ~ трек, Ctrl+~ все); Ctrl+` — шаг next (13 окт)
    if c == ('`'):byte() or c == ('~'):byte() then
      local mods2 = ctx.mods and ctx.mods() or {}
      local tilde = c == ('~'):byte() or mods2.shift
      local scope = tilde and (mods2.ctrl and 'track' or 'all') or 'sub'
      V.note_off_scope(scope)
      -- 17 окт: ` в NORMAL — весь сэмпл, в INSERT — note-off: подсказать, как вставить весь сэмпл
      if c == ('`'):byte() and slice1_on() then V.msg = (V.msg ~= '' and (V.msg .. ' - ') or '') .. 'note-off; the whole sample: Ctrl+Shift+1 (Ctrl+Shift + a slice key - from that slice to the end)' end
      V.cur.row = V.cur.row + step_rows(); ensure_visible(); return
    end
    if c == ('['):byte() then V.octave = math.max(0, V.octave - 1); return end
    if c == (']'):byte() then V.octave = math.min(8, V.octave + 1); return end
    -- нотные клавиши пишут только при включённой клавиатуре (11 окт; 10 окт писали всегда)
    -- модификатор ноты (2 окт): Shift — только прослушать, Option — вставить
    -- рядом (новая подколонка), Ctrl — захват звука канала (F5, пока прослушка)
    local how, mods = 'insert', (ctx.mods and ctx.mods() or {})
    c, how = V.note_key(c, mods)
    if how == 'cmd' then return end   -- 17 окт: Cmd — не нота (Cmd+цифра — канал, выше; Cmd+буква — ничего)
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
    -- 17 окт: схема модификаторов (V.note_key): Ctrl — слайс до конца сэмпла (Ctrl+1 — весь), Ctrl+Shift — прослушать;
    -- без нарезки Ctrl — нота с удержанием. Option — выбранный слайс на высоте клавиши, Option+Shift — прослушать;
    -- без нарезки Option — нота рядом (аккорд)
    local thru = false
    if how == 'thru' then
      if sliced then thru = true; how = 'insert'
      else V.msg = 'Ctrl+Shift+note: a slice to the end - only on a sliced sound'; return end
    end
    local paud = how == 'pitch_aud'
    if paud then how = 'pitch' end
    -- 16 окт: кнопка $pitch — простая нота на нарезанном пишет ВЫБРАННЫЙ слайс на высоте клавиши (как Option)
    if sliced and (how == nil or how == 'insert') and not thru and ctx.slicepitch_on and ctx.slicepitch_on() then how = 'pitch' end
    if how == 'pitch' and not sliced then how = paud and 'audition' or 'beside' end   -- без нарезки: Option — рядом
    if sliced and how == 'pitch' then
      local selk = (ctx.selected_slice and ctx.selected_slice(inst0)) or V.last_slice or 1
      -- 17 окт: опция slice pitch from 6 — 0 полутонов на 6-й белой (A): на одной октаве и вниз, и вверх
      local ctr = (st.slicepitch0 == '6') and 9 or 0
      if selk == 0 then sliced = false; how = paud and 'audition' or 'insert'
      else semis = kp - (SB - 1) - ctr; kp = SB + selk - 1; how = paud and 'audition' or 'insert' end
    end
    if sliced and kp - SB + 1 == 0 then                              -- q (slice1: 1): весь сэмпл — обычный путь ноты
      sliced = false
      if slice1_on() then kp = kp + 1 end           -- 15 окт: 1 — на полутон ниже q, сэмпл без транспоза
    end
    if sliced then
      local k = kp - SB + 1
      -- режим слайса (10 окт): random / sequence — слайс выбирает режим, клавиша лишь бьёт
      if ctx.slice_pick and (how == 'insert' or how == 'beside') and not V.arp_live then k = ctx.slice_pick(#inst0.slices, k) end
      if k < 1 or k > #inst0.slices then V.msg = ('no slice %d (the sample has %d) - [ ] shift by an octave'):format(k, #inst0.slices); return end
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
        if t0s and ctx.preview_slice then ctx.preview_slice(f0.col.track, inst0, t0s, (not (inst0.playthru or thru) and inst0.slices[k + 1]) or inst0.len, semis) end
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
        elseif cell and (cell.kind == 'audio' or cell.kind == 'midi') then E.keep_empty = true; E.delete({ cell }, lpb()); E.keep_empty = nil end   -- 21 окт: перезапись — клип остаётся
      end
      if how ~= 'beside' then E.cap_row, E.cap_lpb = V.next_event_row(f0.sub, V.cur.row), lpb() end
      if ctx.auto_pattern then ctx.auto_pattern(V.cur.row) end   -- 21 окт: свободный такт — сначала паттерн
      E.thru_once = thru
      local okI, it = pcall(E.insert_slice, f0.col.track, f0.col.fixed and lane.idx or nil, lpb(), V.cur.row, inst0.item, k, tx)
      E.cap_row, E.thru_once = nil, nil
      if not okI then error(it, 0) end
      if it and semis ~= 0 and E.slice_pitch then E.slice_pitch(it, semis) end
      E.beside = false
      if st.preview and ctx.preview_slice and t0s then ctx.preview_slice(f0.col.track, inst0, t0s, (not (inst0.playthru or thru) and inst0.slices[k + 1]) or inst0.len, semis) end
      if thru then V.msg = ('slice %d to the end of the sample (Ctrl+Shift + a slice key)'):format(k) end
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
        -- 19 окт: кит drumrs5k — клавиша = пэд (как слайс нарезанного сэмпла): высота — нота этого пэда
        local kp0 = ctx.kit_key_pitch and how ~= 'beside' and ctx.kit_key_pitch(f.col, pitch)
        if kp0 then pitch = kp0
        elseif ctx.key_snap and not f.kit and not (inst and inst.slices) then pitch = ctx.key_snap(pitch) end   -- 21 окт: набор в ладу (:key snap)
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
          if ctx.preview then ctx.preview(f.col.track, pitch, (ctx.inst_src and ctx.inst_src(f.col, inst) or (inst and inst.item)), V.cur.row, V.step_auto and 1 or V.step, nil, (c < 256) and string.char(c) or nil) end
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
          elseif cell and cell.kind == 'midi' and cell.pitch then
            -- 22 окт: MIDI-нота поверх MIDI-ноты — меняется только высота: длина и OFF остаются (было: удаление
            -- и новая нота длиной в шаг — OFF срезался)
            local src = ctx.inst_src and ctx.inst_src(f.col, inst) or (inst and inst.item)
            if src == nil or src == 'midi' then
              E.set_pitch({ cell }, lpb(), pitch)
              if st.preview and ctx.preview then ctx.preview(f.col.track, pitch, src, V.cur.row, V.step_auto and 1 or V.step) end
              V.cur.row = V.cur.row + adv_rows(inst, nil, f.col.track, pitch); ensure_visible()
              return
            end
            E.keep_empty = true; E.delete({ cell }, lpb()); E.keep_empty = nil
          elseif cell and (cell.kind == 'audio' or cell.kind == 'midi') then
            E.keep_empty = true; E.delete({ cell }, lpb()); E.keep_empty = nil   -- строка с названием — перезапись (21 окт: клип остаётся)
          end
        end
        local stp = V.step_auto and 1 or V.step
        if not beside then E.cap_row, E.cap_lpb = V.next_event_row(f.sub, V.cur.row), lpb() end
        local newpat = ctx.auto_pattern and ctx.auto_pattern(V.cur.row)   -- 21 окт: свободный такт — сначала паттерн
        local sr = ctx.state.notesus and V.sustain_row(f.sub, V.cur.row) or nil   -- 21 окт: опция note until OFF (выкл по умолчанию)
        E.sus_t = sr and ctx.row_time and ctx.row_time(sr) or nil
        local okN, errN = pcall(E.insert_note,f.col.track, f.col.fixed and lane.idx or nil, lpb(), V.cur.row, pitch, (ctx.ins_vel and ctx.ins_vel(V.vel) or V.vel), stp, (ctx.inst_src and ctx.inst_src(f.col, inst) or (inst and inst.item)))
        E.cap_row, E.sus_t = nil, nil
        if not okN then E.beside = false; error(errN, 0) end
        E.beside = false
        if st.preview and ctx.preview then ctx.preview(f.col.track, pitch, (ctx.inst_src and ctx.inst_src(f.col, inst) or (inst and inst.item)), V.cur.row, stp) end
        if newpat and ctx.auto_pat_msg then V.msg = ctx.auto_pat_msg end
        V.cur.row = V.cur.row + adv_rows(inst, nil, f.col.track, pitch); ensure_visible()
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
    -- 21 окт: в VISUAL клавиатура не перехватывает префиксы и метки (g gt gg, f) — выделение их ждёт
    if V.piano and (V.mode == 'visual' or V.mode == 'vline') and (c == ('g'):byte() or c == ('f'):byte()) then
    elseif V.piano then
      if V.mode == 'normal' and ((c == 13 and ctx.esc_vim and ctx.esc_vim()) or (c == ESC and not (ctx.esc_vim and ctx.esc_vim()))) then V.mode = 'insert';   -- Esc mode vim: вход только Enter / i (12 окт: иначе Enter — смарт-панель)
      V.msg = (ctx.hints_on and ctx.hints_on()) and 'INSERT with the keyboard: the note keys write notes' or ''; return end   -- описание — только с хинтами (5 окт)
      local rn = (ctx.keys_renoise and ctx.keys_renoise()) or (ctx.keys_frow and ctx.keys_frow())   -- 13 окт: renoise — z x ноты, октава [ ]; 16 окт: frow — так же
      if c == (rn and '[' or 'z'):byte() then V.octave = math.max(0, V.octave - 1); V.msg = 'octave ' .. V.octave; return end
      if c == (rn and ']' or 'x'):byte() then V.octave = math.min(8, V.octave + 1); V.msg = 'octave ' .. V.octave; return end
      -- 15 окт: громкость и в KEYS (клавиатура в NORMAL): renoise — { }, иначе c C (как в INSERT)
      if (rn and (c == 123 or c == 125)) or (not rn and (c == 99 or c == 67)) then
        V.vel = math.max(1, math.min(127, (V.vel or 100) + ((c == 125 or c == 67) and 8 or -8))); V.msg = 'velocity ' .. V.vel; return
      end
      if c == ('`'):byte() and V.mode == 'normal' and ctx.pedal_key then ctx.pedal_key(); return end   -- 21 окт: ` — педаль (держать), было: весь сэмпл
      -- 16 окт: Option+Shift+2 (€) — панель макросов и при клавиатуре в NORMAL; Shift+2 (@) снова прослушивает ноту
      if V.is_mac_key(c) and V.mode == 'normal' and ctx.mac_panel then ctx.mac_panel(V.count or 1); V.count = nil; return end
      local mods = ctx.mods and ctx.mods() or {}
      local base, how = V.note_key(c, mods)
      if how == 'cmd' then base = -1 end   -- 17 окт: Cmd — не нота (Cmd+цифра — канал)
      local thru0 = how == 'thru' or how == 'thru_aud'   -- 17 окт: Ctrl — слайс до конца сэмпла
      if how == 'pitch_aud' then how = 'pitch' end
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
        if thru0 then how = sliced0 and 'insert' or 'hold' end
        if sliced0 then
          if how == 'pitch' or ((how == nil or how == 'insert') and ctx.slicepitch_on and ctx.slicepitch_on()) then how = 'beside' end   -- 16 окт: $pitch / Shift+Option
          if how == 'beside' then
            local selk = (ctx.selected_slice and ctx.selected_slice(inst0)) or V.last_slice or 1
            if selk > 0 then k = selk; psemis = kp0 - (SB0 - 1) - ((st.slicepitch0 == '6') and 9 or 0) end
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
            if ctx.preview_slice then ctx.preview_slice(f0.col.track, inst0, inst0.slices[k], (not (inst0.playthru or thru0) and inst0.slices[k + 1]) or inst0.len, psemis) end
          elseif ctx.preview then ctx.preview(f0.col.track, pitch, inst0 and inst0.item, V.cur.row, 1, nil, chq) end   -- chq — клавиша: луп удержания до отпускания
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
      if c == ('i'):byte() and (V.mode == 'visual' or V.mode == 'vline') and not V.op then
        V.interp_menu(); return   -- 19 окт: gi — интерполятор (формы кривой)
      end
      if c == ('r'):byte() and (V.mode == 'visual' or V.mode == 'vline') and not V.op then
        if ctx.rf_open then ctx.rf_open() end; return   -- 19 окт: gr — reform выделенных нот
      end
      -- 10 окт: g + цифры + Enter (или g) — на строку с этим номером (g12 ↵ → 0012); Esc — отмена
      if c >= 48 and c <= 57 and not V.op then
        V.gnum = (V.gnum or '') .. string.char(c); V.pending = 'g'
        V.msg = 'g' .. V.gnum .. ' - Enter: go to row ' .. ('%04d'):format(tonumber(V.gnum)); return   -- номер — как подпись строки (отсчёт rowbase)
      end
      if V.gnum and (c == 13 or c == ('g'):byte()) and not V.op then
        local r = tonumber(V.gnum) or 0; V.gnum = nil
        if r ~= V.cur.row and ctx.jump_mark then ctx.jump_mark() end
        V.cur.row = math.max(0, r - (ctx.state.rowbase or 1)); V.count = nil; finish_move(); ensure_visible(); return   -- 29 окт: подпись 0001 = строка 0
      end
      V.gnum = nil
      if c == ('g'):byte() then
        -- 10 окт: Ngg — строка N, как её подпись (0012 = 12gg); было N−1, как строки Vim с 1
        local t = { fi = V.cur.fi, row = V.count and math.max(0, n - (ctx.state.rowbase or 1)) or 0, linewise = true }   -- 29 окт: Ngg — строка с подписью N
        -- 20 окт: опция gg proj/pat relative — в виде pattern gg ведёт на первую строку паттерна курсора
        if not V.count and ctx.state.ggrel and ctx.state.view_reg and ctx.region_rows then
          local r0 = ctx.region_rows(); if r0 then t.row = r0 end
        end
        if V.op then
          local f0, f1, r0, r1 = range_or_event(V.op, t)
          local e = apply(V.op, f0, f1, r0, r1); V.op = nil; if e then finish_edit() else finish_move() end
        else
          if t.row ~= V.cur.row and ctx.jump_mark then ctx.jump_mark() end   -- 9 окт: gg — в список прыжков
          V.cur.row = t.row; finish_move()
        end
        V.count = nil; ensure_visible(); return
      end
      if (c == ('t'):byte() or c == ('T'):byte()) and not V.op then
        -- 12 окт: gt — вкладка модуля, gT — вкладка проекта REAPER: выпадашка; Ngt / NgT — сразу N-я
        -- (20 окт: gt «следующая вкладка» отменён — это уже Tab)
        local k = V.count; V.count = nil; finish_move()
        if c == ('t'):byte() then if ctx.tab_menu then ctx.tab_menu(k) end elseif ctx.project_menu then ctx.project_menu(k) end
        return
      end
      if (c == ('q'):byte() or c == ('Q'):byte()) and not V.op then
        -- 31 окт: gq — меню квантования (ноты, OFF, автоматизация, края), gQ — квантование входа (кнопка qtz)
        V.count = nil; finish_move()
        if c == ('q'):byte() then if ctx.quant_menu then ctx.quant_menu() end elseif ctx.qtz_menu then ctx.qtz_menu() end
        return
      end
      if c == ('m'):byte() and not V.op then
        -- 13 окт: gm — меню метронома (вкл / выкл, скорость, акценты, пре-ролл)
        V.count = nil; finish_move(); if ctx.metro_menu then ctx.metro_menu() end; return
      end
      -- 19 окт: gp / gP — начало / последняя строка паттерна (региона) курсора, gs / gS — секции;
      -- с оператором — движение (dgP — до конца паттерна). gs раньше дублировал Enter (смарт-панель)
      if c == ('p'):byte() or c == ('P'):byte() or c == ('s'):byte() or c == ('S'):byte() then
        local sec = c == ('s'):byte() or c == ('S'):byte()
        local r0, r1
        if sec then if ctx.section_rows then r0, r1 = ctx.section_rows(V.cur.row) end
        elseif ctx.region_rows then r0, r1 = ctx.region_rows() end
        V.count = nil
        if not r0 then V.op = nil; V.msg = sec and 'no section here' or 'no pattern here'; finish_move(); return end
        local t = { fi = V.cur.fi, row = (c == ('p'):byte() or c == ('s'):byte()) and r0 or r1, linewise = true }
        if V.op then
          local f0, f1, q0, q1 = range_or_event(V.op, t)
          local e = apply(V.op, f0, f1, q0, q1); V.op = nil; if e then finish_edit() else finish_move() end
        else
          if t.row ~= V.cur.row and ctx.jump_mark then ctx.jump_mark() end
          V.cur.row = t.row; finish_move()
        end
        ensure_visible(); return
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
      elseif c == ('x'):byte() then if ctx.xfade_native then ctx.xfade_native(V.covering(V.cur.fi, V.cur.row)) end   -- 13 окт: zx — редактор кроссфейдов REAPER
      elseif c == ('X'):byte() then if ctx.dsp_tall then ctx.dsp_tall('mixer') end   -- 26 окт: zX — микшер в 1.5 раза выше, ещё раз — назад
      elseif c == ('1'):byte() then if ctx.mono_lane_cur then ctx.mono_lane_cur() end   -- 24 окт: z1 — трек курсора на одном нотном лейне (моно), ещё раз — свободно
      elseif c == ('p'):byte() then if ctx.view_reg then ctx.view_reg() end   -- 20 окт: zp — вид: паттерн курсора / весь проект
      elseif c == ('s'):byte() then if ctx.view_mode then ctx.view_mode(ctx.view_cur() == 'section' and 'project' or 'section') end   -- 26 окт: zs — вид: секция курсора / весь проект
      elseif c == ('u'):byte() then V.unfold_zoom()   -- 20 окт: zu — раскрыть сложенные ноты (LPB до 128), ещё раз — назад
      elseif c == ('r'):byte() then if ctx.dsp_big then ctx.dsp_big() end            -- zr: роутер на месте трекера (7 окт)
      elseif c == ('R'):byte() then if ctx.router_big then ctx.router_big() end      -- zR: большой роутер на всё окно (7 окт)
      elseif c == ('e'):byte() then if ctx.env_view then ctx.env_view() end   -- 12 окт: ze — вид колонки огибающей: значения / кривая
      elseif c == ('W'):byte() then if ctx.wave_menu then ctx.wave_menu() end   -- 12 окт: вид волны (выпадашка); 31 окт: zW (было zw)
      elseif c == ('w'):byte() then if ctx.fit_width then ctx.fit_width() end   -- 31 окт: zw — все треки одной ширины, чтобы влезли
      elseif c == ('l'):byte() then if ctx.lpb_menu then ctx.lpb_menu() end   -- 1 ноя: zl — пресеты LPB (T триоли, D квинтоли)
      elseif c == ('h'):byte() then if ctx.fit_height then ctx.fit_height() end   -- 31 окт: zh — вид (паттерн / секция / проект) по высоте в экран
      elseif c == ('Z'):byte() then if ctx.fixed_toggle then ctx.fixed_toggle() end   -- 12 окт: zZ — фиксированный курсор (zz — один раз в центр, zZ — всегда)
      elseif c == ('t'):byte() then st.row0 = math.max(0, V.cur.row)   -- 12 окт: zt — снова Vim: строка курсора наверх (транспозиция — Opt/Shift/Ctrl+F1 F2, меню)
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
      elseif c == ('m'):byte() then if ctx.pane_min then ctx.pane_min() end   -- 20 окт: zm — свернуть панель в фокусе (микшер — F3)
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
        for _, h in ipairs(heads) do if h.kind == 'audio' and h.slice then slc[#slc + 1] = h else rest[#rest + 1] = h end end
        if rhow == 'pitch_aud' then rhow = 'pitch' end
        if #slc > 0 and rhow ~= 'cmd' then
          if rhow == 'pitch' then E.run('slice pitch', function() for _, h in ipairs(slc) do if E.slice_pitch then E.slice_pitch(h.item, pitch - V.slice_base()) end end end)
          elseif pitch - V.slice_base() + 1 < 1 then V.msg = 'the key below slice 1 is the whole sample - a slice note keeps its slice (` in NORMAL plays it, :whole writes it)'
          else E.set_fx(slc, lpb(), '0S', pitch - V.slice_base() + 1) end
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
      if keys then V.last_macro = name; V.cmdbuf = {}; V.count = nil; for _ = 1, n do replay(keys) end end   -- 15 окт: счётчик — до повторов (2@a было три раза)
      if not keys and c < 256 and ctx.mac_by_key then ctx.mac_by_key(string.char(c)) end   -- 15 окт: 1..9 A..Z — свои / встроенные, / — по имени
      V.count = nil; return
    elseif p == 'T' then
      -- 11 окт: T f — take FX ноте под курсором (fzf), T o — её цепь в DSP
      local ch = string.char(c < 256 and c or 0)
      if ch == 'f' and ctx.dsp_take_slice then ctx.dsp_take_slice()
      elseif ch == 'o' and ctx.take_fx_open then ctx.take_fx_open() end
      finish_move(); V.count = nil; return
    elseif p == 't' then
      -- 16 окт: t + цифры — номера треков (как в REAPER, 0 = 10), потом a: t123a — запись у треков 1 2 3
      if c >= ('0'):byte() and c <= ('9'):byte() then
        V.tlist = (V.tlist or '') .. string.char(c); V.pending = 't'; V.msg = 't' .. V.tlist .. '  (a - arm, s - solo, m - mute these tracks)'; return
      end
      local tl = V.tlist; V.tlist = nil
      -- 28 окт: счётчик перед t — тоже номера треков: 135tm = t135m (mute 1 3 5), 24ts, 12ta
      if not tl and V.count and (c == ('a'):byte() or c == ('s'):byte() or c == ('m'):byte()) then tl = tostring(math.floor(V.count)) end
      if tl and (c == ('a'):byte() or c == ('s'):byte() or c == ('m'):byte()) then
        local nums = {}
        for d in tl:gmatch('%d') do nums[#nums + 1] = d == '0' and 10 or tonumber(d) end
        if c == ('a'):byte() and ctx.rec_arm_list then ctx.rec_arm_list(nums)
        elseif ctx.tracks_flag then ctx.tracks_flag(nums, c == ('s'):byte() and 'I_SOLO' or 'B_MUTE') end   -- 21 окт: t23s / t23m — соло / mute треков 2 3
        finish_move(); V.count = nil; return
      elseif tl then V.msg = 't' .. tl .. ': a (arm), s (solo) or m (mute) takes track numbers'; finish_move(); V.count = nil; return end
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
        elseif ch == 'm' and ctx.track_toggle then ctx.track_toggle('mute')   -- 21 окт: tm — mute трека курсора
        elseif ch == 'u' and ctx.unsolo_all then ctx.unsolo_all()          -- 21 окт: tu — снять все соло и mute
        elseif ch == 'a' and ctx.rec_arm then ctx.rec_arm(V.count)   -- 16 окт: 6ta — шесть треков от курсора
        elseif ch == 'A' and ctx.autoarm_all then ctx.autoarm_all()   -- 20 окт: tA — autoarm всех треков (кнопка autoarm)
        elseif ch == 'i' and ctx.input_picker and col then ctx.input_picker(col)
        elseif ch == 'I' and ctx.smart_input and col then ctx.smart_input(col)   -- 10 окт: tI — активный вход (jf_smart_set_input)
        elseif ch == 'l' and ctx.toggle_lanes then ctx.toggle_lanes()
        elseif ch == 'w' and ctx.track_wave and col then ctx.track_wave(col)   -- 21 окт: tw — колонка волны трека: показать / убрать (снова — авто)
        elseif ch == 'f' and ctx.fx_picker then ctx.fx_picker()
        elseif ch == 'R' and ctx.route_menu and col then ctx.route_menu(col)
        elseif ch == 'T' and ctx.template_picker then ctx.template_picker()   -- 11 окт: tT — шаблоны треков (fzf)
        elseif ch == 'F' and ctx.track_into_left then ctx.track_into_left()   -- 11 окт: tF — в папку трека слева
        -- 30 окт: tg — склеить трек в паттерне в один айтем; t} — конец лупа на строке курсора; t+ t- — rate ×2 / ÷2
        elseif ch == 'g' and ctx.item_glue then ctx.item_glue(); V.count = nil; finish_edit(); return
        elseif ch == '}' and ctx.item_loop_end then ctx.item_loop_end(); V.count = nil; finish_edit(); return
        elseif (ch == '+' or ch == '=' or ch == '-') and ctx.item_rate then ctx.item_rate(ch == '-' and 0.5 or 2); V.count = nil; finish_edit(); return end
        finish_move()
      end
      V.count = nil; return
    elseif p == 'da' then
      -- 19 окт: daw → dT (одна клавиша на функцию)
      if ctx.clear_track_part and string.char(c):lower():match('^[eljkh]$')
        and ctx.clear_track_part(string.char(c):lower(), string.char(c):match('%u') ~= nil) then finish_edit()   -- 17 окт: dae dal daj dak dah; заглавная — все треки (daE — в паттерне)
      else finish_move() end
      V.count = nil; return
    elseif p == 'd' or p == 'y' or p == 'c' then
      -- 10 окт: dd — строки (5dd — пять, как в Vim); трек удаляет td (было dd с 4 окт)
      -- 30 окт: dd как в Vim — строки уходят, ниже подтягивается (как Backspace; Ndd — N строк); dw — очистить N строк
      -- трека без сдвига (прежний dd), dW — то же на всех треках; целый item — di
      if p == 'd' and c == ('d'):byte() and ctx.time_edit and not env_of(V.cur.fi) then
        V.count = nil
        ctx.time_edit('delete', V.cur.fi, V.cur.row, n, false); finish_edit()
        return
      end
      -- 31 окт: только когда в строках есть что чистить и колонка не огибающая / лейн / команда (у них свой dw ниже);
      -- пустая строка — dw берёт следующее событие, как до 30 окт (иначе dw на пустом месте молча ничего не делал)
      local fw = flat()[V.cur.fi]
      local wspecial = c == ('w'):byte() and fw and (fw.env or (fw.ml and fw.ml.ev) or ((not fw.narrow) and (V.cur.field or 1) >= 4))
      if p == 'd' and (c == ('W'):byte() or (c == ('w'):byte() and not wspecial and #V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row + n - 1) > 0)) then
        local F = flat()
        local f0, f1 = V.cur.fi, V.cur.fi
        if c == ('W'):byte() then f0, f1 = 1, #F end
        local e = apply('d', f0, f1, V.cur.row, V.cur.row + n - 1); V.count = nil
        if e then finish_edit() else finish_move() end
        return
      end
      if p == 'd' and c == ('i'):byte() then
        if ctx.delete_item_at_cursor() then finish_edit() else finish_move() end
        V.count = nil; return
      end
      if c == p:byte() then      -- yy cc: n строк
        local f0, f1, r0, r1 = V.cur.fi, V.cur.fi, V.cur.row, V.cur.row + n - 1
        local e = apply(p, f0, f1, r0, r1); V.count = nil
        if e then finish_edit() else finish_move() end
        return
      end
      if c >= ('0'):byte() and c <= ('9'):byte() and not (c == ('0'):byte() and not V.count) then
        V.count = math.floor((V.count or 0) * 10 + (c - 48)); V.pending = p; return
      end
      if c == ('g'):byte() then V.op = p; V.pending = 'g'; return end
      -- 19 окт: yc — поле курсора (vol / delay / команда) на весь паттерн в регистр
      if p == 'y' and c == ('c'):byte() then
        local fld = V.cur.field or 1
        if fld < 2 or env_of(V.cur.fi) then V.msg = 'yc: put the cursor on vol, delay or a command field'
        else
          local r0, r1
          if ctx.region_rows then r0, r1 = ctx.region_rows() end
          local cnt = V.field_yank(V.cur.fi, V.cur.fi, r0 or 0, r1 or 1000000, fld)
          V.msg = ('yc: %d value(s) of the field in the pattern - p puts them at the cursor row'):format(cnt)
        end
        V.count = nil; finish_move(); return
      end
      -- dW — весь item под курсором (не только нота MIDI); dt — весь трек
      -- курсора в регионе (вне региона — до =END). Просьба 2 окт.
      -- 13 окт: dc — колонка огибающей курсора целиком: точки, automation items, сама колонка
      if p == 'd' and c == ('c'):byte() then
        local f = flat()[V.cur.fi]
        if f and (f.env or f.ml) and ctx.env_remove then ctx.env_remove(f) ; V.count = nil; finish_edit()
        else V.msg = 'dc: put the cursor on an automation column' end
        return
      end
      -- 20 окт: dC — поле курсора (vol / delay / команда) очистить во всём треке (все подколонки, все регионы); ноты остаются
      if p == 'd' and c == ('C'):byte() then
        local f, fld = flat()[V.cur.fi], V.cur.field or 1
        if not f or f.env or f.ml or fld < 2 then V.msg = 'dC: put the cursor on vol, delay or a command field'
        else
          local fa, fb = V.cur.fi, V.cur.fi
          local function same(g) return g and g.col == f.col and not g.env and not g.ml end
          while same(flat()[fa - 1]) do fa = fa - 1 end
          while same(flat()[fb + 1]) do fb = fb + 1 end
          local hs = V.heads_in(fa, fb, 0, math.max(0, ctx.snap().last_row or 0) + 1)
          ctx.edit.run('clear field in the track', function() for _, h in ipairs(hs) do V.field_set(h, fld, nil) end end)
          V.msg = ('dC: the field cleared on %d note(s) of the track'):format(#hs)
          V.count = nil; finish_edit(); return
        end
        V.count = nil; finish_move(); return
      end
      -- 27 окт: dw на огибающей, MIDI-лейне (CC / PB / PC, cmd мастера) или в колонке команды — событие курсора (нет — следующее
      -- ниже); 3dw — три события подряд; курсор на месте: снова dw — следующее
      if p == 'd' and c == ('w'):byte() then
        local f, fld = flat()[V.cur.fi], V.cur.field or 1
        local kind = f and ((f.env and 'env') or (f.ml and f.ml.ev and 'ml') or ((not f.narrow) and fld >= 4 and 'fx'))
        if kind then
          local n, row = math.max(1, V.count or 1), V.cur.row
          local rows, hs = {}, {}
          if kind == 'env' then
            for _, r in ipairs((ctx.env_point_rows and ctx.env_point_rows(f.env)) or {}) do if r >= row then rows[#rows + 1] = r end end
          elseif kind == 'ml' then
            for r in pairs(f.ml.ev) do if type(r) == 'number' and r >= row then rows[#rows + 1] = r end end
          else
            for _, h in ipairs(V.heads_in(V.cur.fi, V.cur.fi, row, math.max(row, ctx.snap().last_row or 0) + 1)) do
              if V.field_get(h, fld) ~= nil then rows[#rows + 1] = h.row0 or row; hs[#hs + 1] = h end
            end
          end
          table.sort(rows)
          while #rows > n do rows[#rows] = nil end
          if #rows == 0 then V.msg = 'dw: no event here or below'; V.count = nil; finish_move(); return end
          ctx.edit.run('dw ' .. kind, function()
            if kind == 'env' then apply('d', V.cur.fi, V.cur.fi, rows[1], rows[#rows])
            elseif kind == 'ml' then for _, r in ipairs(rows) do ctx.ml_del(f, r) end
            else for _, h in ipairs(hs) do if (h.row0 or row) <= rows[#rows] then V.field_set(h, fld, nil) end end end
          end)
          V.msg = ('dw: %d event(s) deleted (%04d%s)'):format(#rows, rows[1], #rows > 1 and ('..%04d'):format(rows[#rows]) or '')
          V.count = nil; finish_edit(); return
        end
      end
      -- 31 окт: dw на пустой строке, а следующее событие подколонки — OFF: удалить этот OFF (свободный — CC 123;
      -- OFF ноты — нота звучит дальше, до следующего события / конца клипа), а не ноту целиком
      if p == 'd' and c == ('w'):byte() and #V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row) == 0 then
        local f = flat()[V.cur.fi]
        local nr = f and not f.env and not f.ml and next_ev(V.cur.fi, V.cur.row - 1, 1)
        local cell = nr and f.sub and f.sub[nr]
        if cell and cell.kind == 'off' and cell.of then
          if cell.clipend then V.msg = '=== is the end of the clip (pattern) - nothing to delete'; V.count = nil; finish_move(); return end
          if cell.of.stub then
            ctx.edit.all_off_del(cell.of)
            V.msg = ('free OFF at row %04d deleted'):format(nr)
            V.count = nil; finish_edit(); return
          end
          local h = cell.of
          local nx
          for r2, cl in pairs(f.sub) do if type(r2) == 'number' and r2 > nr and (cl.kind == 'midi' or cl.kind == 'audio' or (cl.kind == 'off' and cl.of ~= h)) and (not nx or r2 < nx) then nx = r2 end end
          if not nx and ctx.region_rows then local _, r1 = ctx.region_rows(); if r1 then nx = r1 + 1 end end
          if nx then
            ctx.edit.note_off({ h }, lpb(), nx - (ctx.edit.OFF_END and 1 or 0))
            V.msg = ('OFF at row %04d removed: the note sounds on to row %04d'):format(nr, nx)
            V.count = nil; finish_edit(); return
          end
        end
      end
      -- 21 окт: опция treat OFF as event — dw изнутри ноты / на её OFF: удалить этот OFF (нота до следующего события / конца паттерна)
      if p == 'd' and c == ('w'):byte() and ctx.state.offevent then
        local f = flat()[V.cur.fi]
        local cell = f and f.sub and f.sub[V.cur.row]
        local h = cell and (cell.kind == 'off' or cell.kind == 'cont') and cell.of
        if cell and cell.clipend then V.msg = '=== is the end of the clip (pattern): the note plays to here - nothing to delete'; V.count = nil; finish_move(); return end
        if h and (h.kind == 'midi' or h.kind == 'audio') then
          local endr = (h.row0 or 0) + math.max(1, h.rows or 1)
          local nx
          for r, cl in pairs(f.sub) do if type(r) == 'number' and r >= endr and (cl.kind == 'midi' or cl.kind == 'audio' or (cl.kind == 'off' and cl.of ~= h)) and (not nx or r < nx) then nx = r end end
          if not nx and ctx.region_rows then local _, r1 = ctx.region_rows(); if r1 then nx = r1 + 1 end end
          if nx and nx > endr - 1 then
            ctx.edit.note_off({ h }, lpb(), nx - (ctx.edit.OFF_END and 1 or 0))
            V.msg = ('OFF removed: the note sounds to row %04d'):format(nx)
            V.count = nil; finish_edit(); return
          end
        end
      end
      -- 13 окт: dw / dW внутри пустого MIDI-клипа (#) — удалить клип, как item
      if p == 'd' and (c == ('w'):byte() or c == ('W'):byte()) and #V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row) == 0 then
        local em = V.empty_midi_at(V.cur.fi, V.cur.row)
        if em and ctx.delete_item then ctx.delete_item(em); V.msg = 'empty MIDI clip deleted'; V.count = nil; finish_edit(); return end
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
      if p == 'd' and c == ('T'):byte() then   -- 19 окт: dT — всё на треке курсора во всех регионах (было daw; =LIB остаётся)
        if ctx.clear_track(true) then finish_edit() else finish_move() end
        V.count = nil; return
      end
      if p == 'd' and c == ('R'):byte() then   -- 17 окт: dR — регион на всех треках
        if ctx.clear_region_all and ctx.clear_region_all() then finish_edit() else finish_move() end
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
      -- 19 окт: de / ce внутри ноты — хвост ноты от курсора до её конца (нота кончается перед курсором);
      -- раньше пустой диапазон отдавал оператору следующую ноту — она и удалялась
      local fl0 = flat()[V.cur.fi]
      if t and (p == 'd' or p == 'c') and c == ('e'):byte() and fl0 and not fl0.env and not fl0.ml then
        local tail = {}
        for _, h in ipairs(V.covering(V.cur.fi, V.cur.row)) do if h.row0 < V.cur.row then tail[#tail + 1] = h end end
        if #tail > 0 then
          local E = ctx.edit
          E.note_off(tail, lpb(), V.cur.row - 1 + (E.OFF_END and 0 or 1))
          V.msg = ('%se: the note ends before row %04d (its tail deleted)'):format(p, V.cur.row)
          if p == 'c' then V.mode = 'insert' end
          finish_edit(); V.count = nil; return
        end
      end
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
    V.count = math.floor((V.count or 0) * 10 + (c - 48)); return
  end

  -- VISUAL: операторы на выделении
  if V.mode == 'visual' or V.mode == 'vline' then
    local f0, f1, r0, r1 = V.visual_range()
    local done = false
    if c == ESC then V.mode = 'normal'; done = true; finish_move()
    elseif c == ('o'):byte() then V.cur, V.anchor = V.anchor, V.cur; done = true
    elseif c == ('R'):byte() and ctx.razor_from then   -- 16 окт: R — выделение в razor edit REAPER (те же строки × треки)
      ctx.razor_from(f0, f1, r0, r1); V.mode = 'normal'; finish_move(); done = true
    elseif c == ('T'):byte() then V.transpose_smart('sel'); done = true   -- 26 окт: Shift+T и в VISUAL — транспозитор выделения
    elseif (c == ('d'):byte() or c == ('x'):byte() or c == ('y'):byte() or c == ('c'):byte()
        or c == ('M'):byte() or c == ('s'):byte()) and not (V.vfield and (c == ('d'):byte() or c == ('x'):byte() or c == ('y'):byte())) then   -- 23 окт: поле-колонка — своя ветка ниже (было — удалялись ноты целиком)
      local e = apply(c == ('M'):byte() and 'm' or string.char(c), f0, f1, r0, r1)
      V.cur.fi, V.cur.row = f0, r0
      if V.mode ~= 'insert' then V.mode = 'normal' end
      if e then finish_edit() else finish_move() end
      done = true
    elseif c == ctrl('a') or c == ctrl('x') then
      -- 28 окт: выделение остаётся (жми ещё раз); лейны CC / PB и огибающие в выделении — их события тоже ±
      local d = (c == ctrl('a') and 1 or -1) * (V.count or 1)
      ctx.edit.run('nudge the selection', function()
        for fi = f0, f1 do
          local f = flat()[fi]
          if f and f.ml and f.ml.ev and ctx.nudge_lane then
            for r = r0, r1 do if f.ml.ev[r] then ctx.nudge_lane(fi, r, d) end end
          elseif f and f.env and ctx.env_nudge then
            for _, r in ipairs((ctx.env_point_rows and ctx.env_point_rows(f.env)) or {}) do if r >= r0 and r <= r1 then ctx.env_nudge(f.env, r, d / 64) end end
          end
        end
        apply(c == ctrl('a') and '+' or '-', f0, f1, r0, r1)
      end)
      V.count = nil; finish_edit(); done = true
    elseif c == ('p'):byte() and V.regs['"'] and V.regs['"'].kind == 'field' then
      local n = V.field_paste(V.regs['"'], f0, r0); V.msg = ('field: %d value(s) put'):format(n)
      V.cur.fi, V.cur.row = f0, r0; V.mode = 'normal'; V.vfield = nil; finish_edit(); done = true
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
    elseif (c == ('a'):byte() or c == ('i'):byte()) and V.mode == 'visual' then V.smart_expand(c == ('a'):byte() and 1 or -1); done = true   -- 17 окт: a шире / i уже (Paketti; v — режим)
    elseif c == ('v'):byte() then
      -- 19 окт: v по кругу: поле → весь трек → выход
      if V.mode ~= 'visual' then V.mode = 'visual'; V.vfield = nil; V.vtrack = nil
      elseif V.vfield then V.vfield = nil; V.vtrack = true; V.msg = 'visual: the whole track (v - off)'
      elseif not V.vtrack then V.vtrack = true; V.msg = 'visual: the whole track (v - off)'
      else V.vtrack = nil; V.mode = 'normal'; finish_move() end
      done = true
    elseif c == ('Q'):byte() then
      -- 20 окт: Q — квантайз выделения в сетку строк: каждая нота — на ближайшую строку (delay 0), длина не меняется
      local hs, rows, n = V.heads_in(f0, f1, r0, r1), {}, 0
      local list = {}
      for _, h in ipairs(hs) do
        if (h.kind == 'midi' or h.kind == 'audio') and h.row0 then
          local d = tonumber(h.delay) or 0
          local rr = math.floor(h.row0 + d / 256 + 0.5)
          if d ~= 0 or rr ~= h.row0 then list[#list + 1] = h; rows[#list] = rr; n = n + 1 end
        end
      end
      if n > 0 and ctx.edit.retime then ctx.edit.retime(list, lpb(), rows, nil, 'quantize to the grid'); finish_edit() else finish_move() end
      V.msg = n > 0 and ('Q: %d note(s) to the nearest row (of %d)'):format(n, #hs) or ('Q: %d note(s), all on the grid already'):format(#hs)
      V.cur.fi, V.cur.row = f0, r0; V.mode = 'normal'; V.vfield = nil; done = true
    elseif V.vfield and (c == ('y'):byte() or c == ('d'):byte() or c == ('x'):byte()) then
      -- 19 окт: поле-колонка: y — значения поля в регистр, d / x — очистить поле (ноты остаются)
      local fld = V.vfield
      if c == ('y'):byte() then
        local n = V.field_yank(f0, f1, r0, r1, fld); V.msg = ('yank: %d value(s) of the field - p puts them into the notes of the rows'):format(n); finish_move()
      else
        local hs = V.heads_in(f0, f1, r0, r1)
        if c == ('x'):byte() then V.field_yank(f0, f1, r0, r1, fld) end   -- 29 окт: x — вырезать (в регистр)
        local offs = fld == 3 and V.offs_in(f0, f1, r0, r1) or {}
        ctx.edit.run('clear field', function()
          for _, h in ipairs(hs) do V.field_set(h, fld, nil) end
          -- 29 окт: задержка у OFF (конец ноты внутри строки) — тоже: конец на начало строки OFF
          for _, o in ipairs(offs) do ctx.edit.note_off({ o.cell.of }, lpb(), o.row) end
        end)
        V.msg = ('field cleared on %d note(s)%s'):format(#hs, #offs > 0 and (', %d OFF'):format(#offs) or ''); finish_edit()
      end
      V.cur.fi, V.cur.row = f0, r0; V.mode = 'normal'; V.vfield = nil; done = true
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
  elseif c == 13 then V.count = nil; finish_move()
    local st = ctx.state
    -- 1 ноя: PT-mode — Enter как Return в ProTracker: пустая строка в канале курсора, ниже — вниз (Shift — все каналы)
    if st and st.ptmode and not env_of(V.cur.fi) and ctx.time_edit then
      ctx.time_edit('insert', V.cur.fi, V.cur.row, n, ctx.mods and ctx.mods().shift or false); finish_edit(); return
    end
    -- старое Enter: на огибающей / MIDI-лейне — меню «что вставить», иначе смарт-панель значений поля
    local function values()
      if V.mode ~= 'visual' and V.mode ~= 'vline' and ctx.lane_menu and ctx.lane_menu() then return end
      V.smart()
    end
    -- 1 ноя: Enter — лидер трекера: меню того, что под курсором; Enter Enter — значения поля (как было)
    if V.mode == 'normal' and ctx.context_key then
      V.hydra = nil
      ctx.context_key()
      if V.hydra then
        V.hydra.on_enter = values
        table.insert(V.hydra.items, 1, { label = 'Enter  - values of this field (note, instrument, vol, command ...)', fn = values })
        return
      end
    end
    values(); return
  elseif ch == 'I' and not env_of(V.cur.fi) then
    -- 12 окт: I как в Vim — INSERT с начала строки: первая подколонка трека, поле ноты
    -- (было «вставить время» — пустая строка со сдвигом; это Insert и :instime)
    local f = flat()[V.cur.fi]
    if f and f.col then for i, g in ipairs(flat()) do if g.col == f.col then V.cur.fi = i; break end end end
    V.cur.field = 1; clamp_cur(); V.mode = 'insert'; V.count = nil; return
  elseif ch == 'a' then if not (ctx.envs_folded and ctx.envs_folded()) then ctx.toggle_envs() end; V.count = nil; return   -- 24 окт: на сложенном треке — его автоматизация
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
  elseif ch == 'v' then V.mode = 'visual'; V.anchor = { fi = V.cur.fi, row = V.cur.row }; V.sx, V.vbox = nil, nil
    -- 19 окт: первое v — только поле курсора (vol / delay / команда); на ноте — подколонка, как было
    V.vtrack = nil; V.vfield = ((V.cur.field or 1) >= 2 and not env_of(V.cur.fi)) and V.cur.field or nil
  elseif ch == 'V' then V.mode = 'vline'; V.vfield, V.vtrack = nil, nil; V.anchor = { fi = V.cur.fi, row = V.cur.row }
  elseif ch == ':' then V.cmd_from = V.mode; V.mode = 'cmd'; V.cmdline = ''; V.prompt = nil; V.count = nil; return
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
  elseif ch == 'R' and V.mode == 'normal' and ctx.retro_insert then ctx.retro_insert(); V.count = nil; return   -- 21 окт: R — последнее сыгранное (ретро-буфер MIDI REAPER) с курсора
  elseif ch == 'T' and V.mode == 'normal' then V.transpose_smart(); return   -- 26 окт: Shift+T — транспозитор (выпадашка, как :tr)
  elseif c == 8224 and V.mode == 'normal' then V.pending = 'T'; return   -- 26 окт: Opt+T — take ноты под курсором (было T; t — трек)
  elseif V.is_mac_key(c) and V.mode ~= 'insert' and ctx.mac_panel then V.count = nil; ctx.mac_panel(n); return   -- 16 окт: Option+Shift+2 — большая панель макросов у курсора (@a — регистр, как в Vim)
  elseif ch == 'g' or ch == 'z' or ch == 'r' or ch == '@' or ch == "'" then V.pending = ch; return   -- ' — harpoon (9 окт)
  elseif ch == 'q' then
    if V.macro then
      V.regs['@' .. V.macro.name] = V.macro.keys
      table.remove(V.regs['@' .. V.macro.name])     -- сам `q` не в макросе
      V.last_macro = V.macro.name; V.msg = 'macro @' .. V.macro.name; V.macro = nil
    else V.pending = 'q' end
    V.count = nil; return
  elseif (c == BS or c == INS) and not env_of(V.cur.fi) then
    -- Backspace: удалить время строки (трек курсора; Shift — все треки) в
    -- рамках региона; Insert (или :instime) — вставить время. Счётчик = строк.
    local all = ctx.mods and ctx.mods().shift or false   -- Shift — все треки
    if ctx.time_edit then ctx.time_edit(c == BS and 'delete' or 'insert', V.cur.fi, V.cur.row, n, all) end
    finish_edit()
  elseif env_of(V.cur.fi) and (ch == 'x' or c == BS or c == DEL or c == ctrl('a') or c == ctrl('x')) then
    -- колонка огибающей в NORMAL: x/BS — удалить точку, ^A/^X — ±1/64
    local env = env_of(V.cur.fi)
    if (V.cur.field or 1) == 2 and nfields() >= 2 and (c == ctrl('a') or c == ctrl('x')) then ctx.env_shape_step(env, V.cur.row, c == ctrl('a') and 1 or -1)
    elseif c == ctrl('a') then ctx.env_nudge(env, V.cur.row, n / 64)
    elseif c == ctrl('x') then ctx.env_nudge(env, V.cur.row, -n / 64)
    else for r = V.cur.row, V.cur.row + n - 1 do ctx.env_del(env, r) end end
    -- 31 окт: Ctrl+Opt+A / X и на огибающей — курсор на шаг step вниз (лесенка), как на лейнах и командах
    if (c == ctrl('a') or c == ctrl('x')) and ctx.mods and ctx.mods().alt then
      V.cur.row = V.cur.row + ((type(V.step) == 'number' and V.step > 0) and V.step or 1)
    end
    finish_edit()
  elseif ch == 'x' and (flat()[V.cur.fi] or {}).ml then
    for r = V.cur.row, V.cur.row + n - 1 do ctx.ml_del(flat()[V.cur.fi], r) end; finish_edit()   -- MIDI-лейн: события строк
  elseif ch == 'x' and #V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row) == 0 and V.empty_midi_at(V.cur.fi, V.cur.row) and ctx.delete_item then
    ctx.delete_item(V.empty_midi_at(V.cur.fi, V.cur.row)); V.msg = 'empty MIDI clip deleted'; finish_edit()   -- 13 окт: «#» — пустой клип (16 окт: знак µ)
  elseif ch == 'x' and ctx.ripple_mode and ctx.ripple_mode() > 0 and ctx.time_edit and #V.heads_in(V.cur.fi, V.cur.fi, V.cur.row, V.cur.row) > 0 then
    -- 16 окт: ripple (кнопка rip, как в REAPER) — нота уходит вместе со своими строками: всё ниже подтягивается
    -- (per track — этот трек, all tracks — все); без ripple — как было
    local r1 = event_end(V.cur.fi, V.cur.row)
    ctx.time_edit('delete', V.cur.fi, V.cur.row, math.max(1, r1 - V.cur.row + 1), ctx.ripple_mode() == 2); finish_edit()
  elseif ch == 'x' then
    apply('x', V.cur.fi, V.cur.fi, V.cur.row, V.cur.row + n - 1); finish_edit()
  elseif ch == 'M' or ch == 'S' then                     -- 9 окт: Shift+M / Shift+S — mute / solo трека (события — M в VISUAL)
    if ctx.track_toggle then ctx.track_toggle(ch == 'M' and 'mute' or 'solo') end
  elseif ch == 's' then
    apply('s', V.cur.fi, V.cur.fi, V.cur.row, V.cur.row); finish_edit()
  elseif (c == ctrl('a') or c == ctrl('x')) and ctx.roll_step and ctx.roll_step() then
    -- 28 окт: roll + опция step a/x — событие строки курсора копией на шаг ниже, там ±1 (A выше / X ниже), курсор туда:
    -- каждое нажатие — следующая ступень (рампа громкости, команды, ноты, CC)
    local d = c == ctrl('a') and 1 or -1
    local st = (type(V.step) == 'number' and V.step > 0) and V.step or 1
    local fi, r0 = V.cur.fi, V.cur.row
    local r1 = r0 + st
    local f = flat()[fi]
    if f and (f.ml or env_of(fi)) and ctx.nudge_lane then
      V.cur.row = r1
      ctx.nudge_lane(fi, r1, d); ctx.nudge_lane(fi, r1, d * n)   -- пусто: первое — значение сверху, второе — ±
      finish_edit()
    else
      local heads = V.heads_in(fi, fi, r0, r0)
      if #heads == 0 then V.msg = 'step a/x: nothing on the cursor row to continue'; return end
      local reg = E.yank(heads, lpb(), r0, fi)
      E.paste(reg, lpb(), r1, paste_targets(fi), false)
      V.cur.row = r1
      for _ = 1, n do apply(d > 0 and '+' or '-', fi, fi, r1, r1) end
      finish_edit()
    end
  elseif c == ctrl('a') or c == ctrl('x') then   -- 27 окт: лейн / огибающая — пусто: значение сверху, дальше ±; иначе ноты
    -- 29 окт: пустая клетка команды внутри ноты — сначала значение команды сверху (той же колонки, той же ноты), дальше ±;
    -- Ctrl+Opt+A / X — то же и курсор на шаг step вниз
    -- 30 окт: с Opt (шаг вниз) пустая клетка — сразу «сверху ± 1»: второго нажатия на ней не будет (было 41 41 41)
    local stepd = ctx.mods and ctx.mods().alt
    if not V.fx_prev_fill(V.cur.fi, V.cur.row, stepd and ((c == ctrl('a') and 1 or -1) * n) or nil) then
      if not (ctx.nudge_lane and ctx.nudge_lane(V.cur.fi, V.cur.row, (c == ctrl('a') and 1 or -1) * n, stepd)) then
        apply(c == ctrl('a') and '+' or '-', V.cur.fi, V.cur.fi, V.cur.row, V.cur.row)
      end
    end
    if stepd then
      local st = (type(V.step) == 'number' and V.step > 0) and V.step or 1
      V.cur.row = V.cur.row + st
    end
    finish_edit()
  elseif ch == 'p' or ch == 'P' then
    local reg = V.regs['"']
    if reg and reg.kind == 'field' then   -- 19 окт: значения поля (yc / y в поле) — в ноты строк
      local cnt = V.field_paste(reg, V.cur.fi, V.cur.row); V.msg = ('field: %d value(s) put'):format(cnt); finish_edit()
    elseif reg and reg.kind == 'env' then
      local env = env_of(V.cur.fi)
      if env then for k = 0, n - 1 do ctx.env_paste(env, V.cur.row + k * (reg.rows or 1), reg) end; finish_edit()
      else V.msg = 'register has envelope points - put the cursor on an envelope column' end
    elseif env_of(V.cur.fi) then V.msg = 'register has notes - put the cursor on a note column'
    else
      -- 15 окт: 2p — копии друг за другом (каждая на высоту регистра ниже), как в Vim; было n раз в ту же строку — одна
      for k = 0, n - 1 do E.paste(reg, lpb(), V.cur.row + k * ((reg and reg.rows) or 1), paste_targets(V.cur.fi), ch == 'P') end   -- 13 окт: p заменяет ноту строки, P — рядом
      finish_edit()
    end
  elseif ch == 'u' then local d; for _ = 1, n do d = E.undo() end; V.msg = d and ('undo: ' .. d) or 'nothing to undo'; finish_move()   -- 15 окт: 3u — три шага
  elseif c == ctrl('r') and not (ctx.mods and (ctx.mods().ctrl or ctx.mods().alt or ctx.mods().cmd)) then for _ = 1, n do E.redo() end; finish_move()   -- 5 окт: Ctrl+R — вкладка rec (main); 15 окт: со счётчиком
  elseif ch == '.' then
    -- 15 окт: счётчик — до повторов (иначе первый повтор брал его сам: 2. давало три раза)
    if V.last_edit then local keys = V.last_edit; V.cmdbuf = {}; V.count = nil; for _ = 1, n do replay(keys) end end
  elseif ch == '[' then V.octave = math.max(0, V.octave - n)   -- 15 окт: счётчик — на N
  elseif ch == ']' then V.octave = math.min(8, V.octave + n)
  elseif ch == '(' then ctx.pool_select(V.inst - n)
  elseif ch == ')' then ctx.pool_select(V.inst + n)
  elseif ch == 'F' then if ctx.sample_find then ctx.sample_find() else st.follow = not st.follow end   -- 20 окт: Shift+F — найти сэмпл для этого места (follow — кнопкой / опцией)
  elseif ch == ' ' then E.play_stop()
  elseif c == ENTER and ctx.mods and ctx.mods().shift and ctx.describe_cell then
    -- Shift+Enter (3 окт): что именно под курсором — исходник, номер, слайс, кусок файла
    local f = flat()[V.cur.fi]
    local cell = f and f.sub and f.sub[V.cur.row]
    if cell and cell.kind == 'cont' then cell = cell.of end
    V.msg = ctx.describe_cell(cell)
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

-- 16 окт: папки пикера деревом (как ranger / lf): group пункта — путь «A / B», колонка на уровень
-- (сколько уровней — по самому глубокому пути), справа — имена. pk.gpath[k] — выбранная строка
-- колонки k (1 — all: дальше не фильтруем), pk.col — колонка фокуса (depth + 1 — имена)
local function split_path(g)
  local out = {}
  for part in ((g or '') .. ' / '):gmatch('(.-) / ') do if part ~= '' then out[#out + 1] = part end end
  return out
end
local function tree_sort(node)
  table.sort(node.list, function(a, b) return a.name:lower() < b.name:lower() end)
  for _, e in ipairs(node.list) do tree_sort(e.node) end
end
-- список колонки k: { {name, n, node}, … } с all первой; nil — колонки нет (выше выбран all)
local function picker_col(pk, k)
  local node = pk.tree
  for lv = 1, k - 1 do
    local gi = pk.gpath[lv] or 1
    if gi <= 1 then return nil end
    node = node.list[gi - 1].node
    if not node or #node.list == 0 then return nil end
  end
  local out = { { name = 'all', n = node.n } }
  for _, e in ipairs(node.list) do out[#out + 1] = e end
  return out
end
-- префикс пути выбранных папок («Basses / A.Liv») или nil
local function picker_prefix(pk)
  local parts, node = {}, pk.tree
  for lv = 1, pk.depth do
    local gi = pk.gpath[lv] or 1
    if gi <= 1 then break end
    local e = node.list[gi - 1]
    if not e then break end
    parts[#parts + 1] = e.name; node = e.node
  end
  return #parts > 0 and table.concat(parts, ' / ') or nil
end

local function picker_filter()
  local pk = V.picker
  local out = {}
  -- 16 окт: папки (у пунктов group): без набора — пункты выбранной папки (и вложенных), с набором — поиск по всем
  local pre = pk.tree and pk.query == '' and picker_prefix(pk) or nil
  local q = pk.fresh and '' or pk.query            -- 18 окт: текущее имя в строке (fresh) — список весь
  for i, it in ipairs(pk.items) do
    if not pre or it.group == pre or (it.group or ''):sub(1, #pre + 3) == pre .. ' / ' then
      local sc = fuzzy_score(it.label, q)
      if sc then out[#out + 1] = { it = it, sc = sc, i = i } end
    end
  end
  -- при равном счёте — порядок списка (недавние действия сверху остаются сверху)
  table.sort(out, function(a, b) if a.sc ~= b.sc then return a.sc > b.sc end return a.i < b.i end)
  pk.matches = {}
  for i, m in ipairs(out) do pk.matches[i] = m.it end
  -- 18 окт: свободный текст (pk.free): набранное, которого нет в списке, — своей строкой; без совпадений — первой
  if pk.free and pk.query ~= '' and not pk.fresh then
    local exact = false
    for _, it in ipairs(pk.matches) do if it.label == pk.query then exact = true; break end end
    if not exact then
      local fr = { label = pk.query, free = true }
      if #pk.matches == 0 then pk.matches[1] = fr else pk.matches[#pk.matches + 1] = fr end
    end
  end
  if pk.sel > #pk.matches then pk.sel = math.max(1, #pk.matches) end
end

function V.picker_refilter() if V.picker then picker_filter() end end
function V.open_picker(title, items, on_pick, query)
  V.picker = { title = title, items = items, query = query or '', sel = 1, matches = {}, on_pick = on_pick }
  local tree, depth, ng = { list = {}, by = {}, n = #items }, 0, 0
  for _, it in ipairs(items) do
    if it.group then
      local parts = split_path(it.group)
      depth = math.max(depth, #parts)
      local node = tree
      for _, nm in ipairs(parts) do
        local e = node.by[nm]
        if not e then e = { name = nm, n = 0, node = { list = {}, by = {}, n = 0 } }; node.by[nm] = e; node.list[#node.list + 1] = e; if node == tree then ng = ng + 1 end end
        e.n = e.n + 1; e.node.n = e.n
        node = e.node
      end
    end
  end
  if ng >= 2 then
    tree_sort(tree)
    local pk = V.picker
    pk.tree, pk.depth, pk.gpath, pk.col = tree, depth, {}, 1
  end
  picker_filter()
end
-- выбрать строку i колонки папок k (мышь / клавиши); глубже — снова all
function V.picker_pick(k, i)
  local pk = V.picker
  local list = pk and pk.tree and picker_col(pk, k)
  if not (list and list[i]) then return end
  pk.gpath[k] = i
  for lv = k + 1, pk.depth do pk.gpath[lv] = nil end
  pk.sel = 1; picker_filter()
end

function V.picker_key(c)
  local pk = V.picker
  -- 16 окт: папки как в lf — h l j k g G (l на имени — выбрать), / — поиск (любая другая буква — тоже)
  if pk.tree and pk.query == '' and not pk.typing then
    local ch = (c > 0 and c < 256) and string.char(c) or ''
    if ch == '/' then pk.typing = true; return end
    if ch == 'h' then c = LEFT elseif ch == 'j' then c = DOWN elseif ch == 'k' then c = UP
    elseif ch == 'l' then c = (pk.col <= pk.depth) and RIGHT or ENTER
    elseif ch == 'g' or ch == 'G' then
      if pk.col <= pk.depth then local list = picker_col(pk, pk.col) or {}; V.picker_pick(pk.col, ch == 'g' and 1 or #list)
      else pk.sel = ch == 'g' and 1 or math.max(1, #pk.matches) end
      return
    end
  end
  if pk.typing and c == ESC and pk.query == '' then pk.typing = nil; return end   -- выход из поиска — снова lf
  if pk.typing and c == BS and pk.query == '' then pk.typing = nil; return end
  -- 16 окт: колонки — ← → / Tab; в колонке папок ↑ ↓ — папка, Enter / → — глубже (или к именам)
  if pk.tree and pk.query == '' then
    if c == LEFT then pk.col = math.max(1, pk.col - 1); return
    elseif c == 9 then pk.col = pk.depth + 1; return
    elseif c == RIGHT or (c == ENTER and pk.col <= pk.depth) then
      local nxt = pk.col + 1
      if nxt <= pk.depth and not picker_col(pk, nxt) then nxt = pk.depth + 1 end   -- выбран all / лист — сразу к именам
      pk.col = math.min(pk.depth + 1, nxt); return
    elseif pk.col <= pk.depth then
      local list = picker_col(pk, pk.col) or {}
      local gi = pk.gpath[pk.col] or 1
      if c == 14 or c == DOWN or c == 10 then V.picker_pick(pk.col, math.min(#list, gi + 1)); return
      elseif c == 16 or c == UP or c == 11 then V.picker_pick(pk.col, math.max(1, gi - 1)); return end
    end
  end
  if pk.fresh and c == BS then pk.query, pk.fresh, pk.sel, pk.moved = '', nil, 1, nil; picker_filter(); return end      -- 18 окт: BS — имя стёрто
  if pk.fresh and TX.char(c) then pk.query, pk.fresh, pk.sel = '', nil, 1 end                   -- набор — заменяет
  if c == ESC then V.picker = nil
  elseif c == ENTER and pk.free and pk.query == '' and not pk.fresh and pk.allow_empty and not pk.moved then   -- 18 окт: стрелками выбран пункт — берём его
    V.picker = nil
    if pk.on_pick then local ok, e = pcall(pk.on_pick, { label = '', free = true }); if not ok then V.msg = tostring(e):match('[^\n]*$') end end
  elseif c == ENTER then
    local it = pk.matches[pk.sel]
    V.picker = nil
    if it and pk.on_pick then local ok, e = pcall(pk.on_pick, it); if not ok then V.msg = tostring(e):match('[^\n]*$') end end
  elseif c == BS then pk.query = TX.bs(pk.query); picker_filter()
  elseif c == 14 or c == DOWN or c == 10 then pk.sel = math.min(#pk.matches, pk.sel + 1); pk.moved = true
  elseif c == 16 or c == UP or c == 11 then pk.sel = math.max(1, pk.sel - 1); pk.moved = true
  elseif TX.char(c) then pk.query = pk.query .. TX.char(c); pk.typing = pk.tree and true or nil; picker_filter() end
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
  V.menu_sort(h.items, function(it) return it.key end, h.nosort)
  return h
end
-- 28 окт: все меню — по алфавиту КЛАВИШ (правило пользователя): a A b B … (заглавная сразу за строчной), потом
-- цифры, знаки; без клавиши — в конце; равные — в прежнем порядке
function V.key_rank(k)
  if type(k) ~= 'string' or k == '' then return 100000 end
  local ch = k:sub(1, 1)
  local b = ch:byte()
  if ch:match('%a') then return ch:lower():byte() * 2 + (ch:match('%u') and 1 or 0) end
  if ch:match('%d') then return 1000 + b end
  return 2000 + b
end
function V.menu_sort(items, keyf, nosort)
  if nosort or type(items) ~= 'table' or #items < 3 then return end
  local ord = {}
  for i, it in ipairs(items) do ord[it] = i end
  table.sort(items, function(a, b)
    local ka, kb = V.key_rank(keyf(a)), V.key_rank(keyf(b))
    if ka ~= kb then return ka < kb end
    return ord[a] < ord[b]
  end)
end
function V.open_hydra(h)
  V.hydra = V.hydra_fix(h); V.hydra_stack = {}
  -- 27 окт: открыто щелчком (кнопка мыши нажата) и место не задано — меню у мыши, не у курсора трекера
  local st = ctx.state
  if st and not st.popup_at and gfx and (gfx.mouse_cap or 0) & 3 ~= 0 then st.popup_at = { kind = 'xy', x = gfx.mouse_x, y = gfx.mouse_y + 4 } end
end

function V.hydra_key(c)
  local h = V.hydra
  if c == ESC then V.hydra = nil; return end
  if c == 13 and h and h.on_enter then local f = h.on_enter; V.hydra = nil; local ok, e = pcall(f); if not ok then V.msg = tostring(e):match('[^\n]*$') end; return end   -- 1 ноя: Enter Enter
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
    local named = pk.tree and pk.query == '' and picker_prefix(pk) ~= nil   -- 16 окт: внутри папки — только имя
    for i = first, math.min(#pk.matches, first + nr - 1) do
      local m = pk.matches[i]
      lines[#lines + 1] = { key = (i == pk.sel) and '>' or ' ', text = named and (m.name or m.label) or m.label, col = m.col, code = m.code, tag = m.tag, pn = m.pn, fxn = m.fxn }   -- col: свой цвет строки (маршрутизация, 9 окт)
    end
    local groups
    if pk.tree and pk.query == '' then   -- 18 окт: набор ищет по всему — папки прячутся, список во всю ширину
      -- колонки папок по уровням (пустая — колонки нет); focus — номер колонки
      groups = { cols = {}, focus = pk.query == '' and pk.col or nil, items_focus = pk.col > pk.depth }
      for k = 1, pk.depth do
        local list = picker_col(pk, k)
        local sel = pk.gpath[k] or 1
        local gfirst = math.max(1, sel - (nr - 1))
        local col = { first = gfirst, sel = sel, lines = {} }
        if list then
          for i = gfirst, math.min(#list, gfirst + nr - 1) do
            local g = list[i]
            col.lines[#col.lines + 1] = (g.node and #g.node.list > 0 and k < pk.depth) and ('%s  %d >'):format(g.name, g.n) or ('%s  %d'):format(g.name, g.n)
          end
        end
        if #col.lines > 0 then groups.cols[#groups.cols + 1] = col end   -- 18 окт: пустая колонка — без места (была пустота посередине)
      end
      if groups.focus and groups.focus > #groups.cols then groups.focus = nil end
    end
    -- 9 окт: пусто — строкой, иначе окно сжималось до клочка заголовка («ro»)
    if #lines == 0 then lines[1] = { key = ' ', text = 'no matches - Backspace (Ctrl+J / K or arrows move, letters search)', col = { 0.6, 0.6, 0.6 } } end
    -- 18 окт: строка поиска — мигающий курсор и «type to search» (рисует draw.popup по search_*); title — для ширины
    return { title = pk.title .. ' > ' .. pk.query .. '_' .. ('  (%d)'):format(#pk.matches), search_head = pk.title .. ' > ', search = pk.query, search_fresh = pk.fresh, search_tail = ('  (%d)'):format(#pk.matches) .. (#pk.matches > 0 and '   arrows / Ctrl+J K: choose, Enter: take' or ''), lines = lines, kind = 'picker', first = first, nmatch = #pk.matches, hl = #pk.matches > 0 and (pk.sel - first + 1) or nil, groups = groups }
  elseif V.hydra then
    local lines = {}
    for _, it in ipairs(V.hydra.items or {}) do
      lines[#lines + 1] = { key = it.key, text = it.label .. ((it.sub and not it.label:find('…', 1, true)) and ' …' or ''), hk = it.hk }   -- 9 окт: без двойного …
    end
    -- 11 окт: хинты включены — внизу меню «как сюда быстро» (h.how): для мышечной памяти
    if V.hydra.how and ctx.state and ctx.state.hints then lines[#lines + 1] = { key = ' ', text = 'fast: ' .. V.hydra.how, col = { 0.55, 0.55, 0.55 } } end
    return { title = V.hydra.title or '', lines = lines, kind = 'hydra' }
  elseif V.mode == 'cmd' and V.prompt then
    local t = (V.cmdline or ''):sub(#V.prompt.pre + 1)
    local b = utf8.offset(t, V.prompt.pos + 1) or (#t + 1)
    return { title = t, before = t:sub(1, b - 1), fresh = V.prompt.fresh, lines = {}, kind = 'prompt' }
  elseif V.mode == 'cmd' then
    local matches, word = V.cmd_matches(V.cmdline)
    local lines = {}
    for i, c in ipairs(matches) do
      if i > 14 then break end
      lines[#lines + 1] = { key = c[1] .. (c[2] ~= '' and (' ' .. c[2]) or ''), text = c[3] }
    end
    -- 13 окт: совпадений нет — строкой (иначе окно сжималось до «:i» и казалось, что набор сбросился)
    if #lines == 0 then lines[1] = { key = ' ', text = 'no such command - Backspace, or :! for REAPER actions', col = { 0.6, 0.6, 0.6 } } end
    -- 15 окт: набранное — в поле над списком, не заголовком
    return { title = 'commands - Tab completes', lines = lines, kind = 'cmd', hl = #matches > 0 and V.cmd_cycle or nil }
  elseif V.mode == 'search' then
    return { title = '/' .. (V.searchline or ''), lines = { { key = 'Enter', text = 'find next' }, { key = 'n / N', text = 'next / previous' }, { key = '*', text = 'search name under cursor' } }, kind = 'search' }
  end
  return nil
end

-- 10 окт: транспозиция как в Renoise (F1 / F2 — полутон, F11 / F12 — октава):
-- scope = 'sel' (выделение, иначе событие строки курсора) | 'col' (колонка, паттерн)
-- | 'track' (все колонки трека, паттерн) | 'pattern' (все треки, паттерн)
V.TSCOPE = { sel = 'selection', col = 'column', track = 'track', pattern = 'pattern' }
function V.transpose_scope(scope, d, micro, diat)   -- 16 окт: micro — d ступеней 1/6 тона (72-EDO), не полутонов; 21 окт: diat — d ступеней лада
  local F = flat()
  local f0, f1, r0, r1
  if scope == 'sel' then
    if V.mode == 'visual' or V.mode == 'vline' then f0, f1, r0, r1 = V.visual_range()
    else f0, f1, r0, r1 = V.cur.fi, V.cur.fi, V.cur.row, V.cur.row end
  else
    local a, b = (ctx.view_rows or ctx.region_rows)()   -- 26 окт: то, что видно (project / section / pattern)
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
  if diat then
    local r, id
    if ctx.key_now then r, id = ctx.key_now() end   -- and режет второе значение (lua-and-truncates-multivalue)
    if not r then V.msg = 'transpose by degrees: no key - :key (from the notes) or :key Am'; return false end
    local TH = ctx.TH
    ctx.edit.transpose_map(notes, lpb(), function(p) return TH.step(p, d, r, id) end, ('transpose %+d degree(s)'):format(d))
    V.last_edit = nil
    V.msg = ('transpose %s %+d degree(s) of %s %s: %d note(s)'):format(V.TSCOPE[scope] or scope, d, ctx.CH_NAMES[r + 1], TH.BY[id].name, #notes)
    return true
  end
  if micro then ctx.edit.micro_nudge(notes, lpb(), d) else ctx.edit.transpose(notes, lpb(), d) end
  V.last_edit = nil
  V.msg = ('transpose %s %+d%s: %d note(s)'):format(V.TSCOPE[scope] or scope, d, micro and '/6 tone' or '', #notes)
  return true
end
-- 26 окт: ноты области (как transpose_scope): sel / col / track / pattern (все треки; строки — то, что видно)
function V.scope_notes(scope)
  local F = flat()
  local f0, f1, r0, r1
  if scope == 'sel' then
    if V.mode == 'visual' or V.mode == 'vline' then f0, f1, r0, r1 = V.visual_range()
    else f0, f1, r0, r1 = V.cur.fi, V.cur.fi, V.cur.row, V.cur.row end
  else
    local a, b = (ctx.view_rows or ctx.region_rows)()
    r0, r1 = a or 0, b or ((ctx.snap().last_row or 0))
    if scope == 'col' then f0, f1 = V.cur.fi, V.cur.fi
    elseif scope == 'track' then
      local ci = F[V.cur.fi] and F[V.cur.fi].ci
      for i, f in ipairs(F) do if f.ci == ci and not f.env then f0 = f0 or i; f1 = i end end
    else f0, f1 = 1, #F end
  end
  if not f0 then return {}, nil end
  local notes = {}
  for _, h in ipairs(V.heads_in(f0, f1, r0, r1)) do if h.kind == 'midi' or h.kind == 'audio' then notes[#notes + 1] = h end end
  return notes, f0, f1, r0, r1
end
-- 26 окт: ТРАНСПОЗИТОР — выпадашка в паре с harmonizer: полутоны −12…+12, октавы, ступени лада, к аккорду строки
-- (колонка аккордов мастера), JI (натуральный строй аккорда удара), области; listen — выбор звучит со сдвигом
function V.transpose_smart(scope)
  if not ctx.smart_open then return end
  scope = scope or ((V.mode == 'visual' or V.mode == 'vline') and 'sel' or V.tr_scope or 'sel')
  V.tr_scope = scope
  local notes = V.scope_notes(scope)
  local items = {}
  for d = -12, -1 do items[#items + 1] = { label = ('%d'):format(d), v = d, tip = ('%s %+d semitone(s)'):format(V.TSCOPE[scope], d) } end
  for d = 1, 12 do items[#items + 1] = { label = ('+%d'):format(d), v = d, tip = ('%s %+d semitone(s)'):format(V.TSCOPE[scope], d) } end
  for _, d in ipairs({ -36, -24, -12, 12, 24, 36 }) do items[#items + 1] = { label = ('oct %+d'):format(d // 12), v = d, tip = ('%s %+d octave(s)'):format(V.TSCOPE[scope], d // 12) } end
  for _, d in ipairs({ -3, -2, -1, 1, 2, 3 }) do items[#items + 1] = { label = ('deg %+d'):format(d), v = 'deg:' .. d, tip = ('%s %+d degree(s) of the key (harmonizer / :key)'):format(V.TSCOPE[scope], d) } end
  items[#items + 1] = { label = 'to chord', v = 'chord', tip = 'every note to the nearest tone of the chord of its row (chord column of the master, :chord read / hear)' }
  items[#items + 1] = { label = 'just', v = 'ji', tip = 'just intonation: the chord of every hit gets its microtones (72-EDO, MTS-ESP Master on the track)' }
  items[#items + 1] = { label = 'micro -', v = 'micro:-1', tip = '1/6 tone down' }
  items[#items + 1] = { label = 'micro +', v = 'micro:1', tip = '1/6 tone up' }
  while #items % 12 ~= 0 do items[#items + 1] = { label = '', dim = true } end
  for _, sc in ipairs({ 'sel', 'col', 'track', 'pattern' }) do
    items[#items + 1] = { label = sc == 'pattern' and 'all tracks' or V.TSCOPE[sc], v = 'scope:' .. sc, on = sc == scope, tip = 'transpose the ' .. V.TSCOPE[sc] .. ' (what you see: project / sec / pat)' }
  end
  ctx.smart_open({ title = ('transpose - %s: %d note(s) (listen - hear it moved)'):format(V.TSCOPE[scope], #notes), items = items, cols = 12, sel = 13,
    on_sel = function(it) if type(it.v) == 'number' and ctx.tr_listen then ctx.tr_listen(notes, it.v) end end,
    on_pick = function(it)
      if type(it.v) == 'string' and it.v:match('^scope:') then V.transpose_smart(it.v:sub(7)); return nil end
      V.tr_apply(scope, it.v)
    end })
end
-- одно действие транспозитора (выпадашка и :tr): число — полутоны, deg:N, chord, ji, micro:N
function V.tr_apply(scope, v)
  if type(v) == 'number' then return V.transpose_scope(scope, v) end
  if type(v) ~= 'string' then return false end
  local dg = v:match('^deg:(%-?%d+)$')
  if dg then return V.transpose_scope(scope, tonumber(dg), nil, true) end
  local mc = v:match('^micro:(%-?%d+)$')
  if mc then return V.transpose_scope(scope, tonumber(mc), true) end
  local notes = V.scope_notes(scope)
  if #notes == 0 then V.msg = 'transpose: no notes in the ' .. (V.TSCOPE[scope] or scope); return false end
  if v == 'chord' or v:match('^chord ') then
    local n = ctx.tr_to_chord(notes, v:match('^chord%s+(%S+)'))
    V.last_edit = nil
    V.msg = ('to chord: %d of %d note(s) moved to the chord of their row%s'):format(n, #notes, n == 0 and ' (no chord column? :chord read / hear)' or '')
    return true
  end
  if v == 'ji' then
    local n, mts = ctx.tr_ji(notes)
    V.msg = ('just: %d hit(s) in just intonation%s'):format(n, mts and ' + MTS-ESP Master on the track' or '')
    return true
  end
  return false
end
-- :tr [sel|col|track|all] +3 | -12 | d2 | chord [Am] | ji | ^1 — быстро, в стиле Vim; без аргумента — выпадашка
function V.tr_cmd(arg)
  local w = {}
  for t in (arg or ''):gmatch('%S+') do w[#w + 1] = t end
  local SC = { sel = 'sel', col = 'col', column = 'col', track = 'track', all = 'pattern', pattern = 'pattern' }
  local scope = (V.mode == 'visual' or V.mode == 'vline') and 'sel' or 'sel'
  if w[1] and SC[w[1]] then scope = SC[table.remove(w, 1)] end
  local a = w[1]
  if not a then return V.transpose_smart(scope) end
  if tonumber(a) then return V.tr_apply(scope, math.floor(tonumber(a))) end
  local d = a:match('^d([%+%-]?%d+)$'); if d then return V.tr_apply(scope, 'deg:' .. tonumber(d)) end
  local m = a:match('^%^([%+%-]?%d+)$'); if m then return V.tr_apply(scope, 'micro:' .. tonumber(m)) end
  local o = a:match('^o([%+%-]?%d+)$'); if o then return V.tr_apply(scope, 12 * tonumber(o)) end
  if a == 'chord' then return V.tr_apply(scope, w[2] and ('chord ' .. w[2]) or 'chord') end
  if a == 'ji' or a == 'just' then return V.tr_apply(scope, 'ji') end
  V.msg = ':tr [sel|col|track|all] +3 | -12 | o1 (octave) | d2 (degrees) | ^1 (1/6 tone) | chord [Am] | ji'
end
-- 26 окт: :nooff [all] — убрать все OFF в том, что видно (project / sec / pat): трек курсора, all — все треки;
-- нота звучит до следующего события (как dd на OFF)
function V.nooff(all)
  local F = flat()
  local a, b = (ctx.view_rows or ctx.region_rows)()
  local r0, r1 = a or 0, b or ((ctx.snap().last_row or 0))
  local ci = F[V.cur.fi] and F[V.cur.fi].ci
  local sf0, sf1, mcols
  if V.mode == 'visual' or V.mode == 'vline' then sf0, sf1, r0, r1 = V.visual_range()
  elseif all then
    -- 29 окт: all — не все треки проекта: выделение матрицы (блок / ячейки — их треки и паттерны), иначе трек курсора
    local mc, ma, mb
    if ctx.mx_scope then mc, ma, mb = ctx.mx_scope() end
    if mc then mcols, r0, r1 = mc, ma, mb end
    all = false
  end   -- 26 окт: выделение
  local n = 0
  ctx.edit.run('remove OFFs', function()
    for fi, fl in ipairs(F) do
      if ((sf0 and fi >= sf0 and fi <= sf1) or (mcols and mcols[fl.ci]) or (not sf0 and not mcols and fl.ci == ci)) and not fl.env then
        for _, sub in ipairs(subs_of(fl)) do
          -- 26 окт: по головам нот, не по клеткам OFF: у ноты короче строки OFF сложен в голову (клетки нет) —
          -- её пропускали; сложенные в клетку ноты (c.fold) — туда же
          for r = r0, r1 do
            local c = sub[r]
            if c and (c.kind == 'midi' or c.kind == 'audio') then
              local nxt
              for r2 = r + 1, r + 4096 do local c2 = sub[r2]; if c2 and (c2.kind == 'audio' or c2.kind == 'midi') then nxt = r2; break end end
              local stop = nxt or ((ctx.region_end_row and ctx.region_end_row(r) or (r + 15)) + 1)
              local hs = { c }
              for _, h in ipairs(c.fold or {}) do hs[#hs + 1] = h end
              ctx.edit.unoff(hs, lpb(), stop)   -- до начала следующего события, без метки OFF
              n = n + #hs
            end
          end
        end
      end
    end
  end)
  ctx.model.invalidate()
  if sf0 then V.mode = 'normal' end
  V.msg = ('nooff: %d note(s) ring to the next one %s'):format(n, sf0 and 'in the selection' or ((all and 'on all tracks' or 'on the track') .. ' in the ' .. (ctx.view_cur and ctx.view_cur() or 'pattern')))
end
-- 26 окт: OFF сразу после каждой ноты (строкой ниже головы) — в выделении, иначе на треке / всех треках в том, что видно;
-- следующее событие в той же строке — нота остаётся как есть
function V.offnotes(all)
  local F = flat()
  local a, b = (ctx.view_rows or ctx.region_rows)()
  local r0, r1 = a or 0, b or ((ctx.snap().last_row or 0))
  local ci = F[V.cur.fi] and F[V.cur.fi].ci
  local sf0, sf1, mcols
  if V.mode == 'visual' or V.mode == 'vline' then sf0, sf1, r0, r1 = V.visual_range()
  elseif all then
    -- 29 окт: all — не все треки проекта: выделение матрицы (блок / ячейки — их треки и паттерны), иначе трек курсора
    local mc, ma, mb
    if ctx.mx_scope then mc, ma, mb = ctx.mx_scope() end
    if mc then mcols, r0, r1 = mc, ma, mb end
    all = false
  end
  local n = 0
  ctx.edit.run('OFF after every note', function()
    for fi, fl in ipairs(F) do
      if ((sf0 and fi >= sf0 and fi <= sf1) or (mcols and mcols[fl.ci]) or (not sf0 and not mcols and fl.ci == ci)) and not fl.env then
        for _, sub in ipairs(subs_of(fl)) do
          for r = r0, r1 do
            local c = sub[r]
            local nx = sub[r + 1]
            if c and (c.kind == 'midi' or c.kind == 'audio') and not (nx and (nx.kind == 'midi' or nx.kind == 'audio')) then
              local hs = { c }
              for _, h in ipairs(c.fold or {}) do hs[#hs + 1] = h end   -- сложенные в клетку ноты — тоже
              ctx.edit.note_off(hs, lpb(), r + 1)
              n = n + #hs
            end
          end
        end
      end
    end
  end)
  ctx.model.invalidate()
  if sf0 then V.mode = 'normal' end
  V.msg = ('off notes: OFF after %d note(s) %s'):format(n, sf0 and 'in the selection' or ((all and 'on all tracks' or 'on the track') .. ' in the ' .. (ctx.view_cur and ctx.view_cur() or 'pattern')))
end
-- 17 окт: умное выделение (как Paketti): v в VISUAL по кругу — колонка в доле → колонка в такте → такт (все
-- треки) → половина паттерна (региона курсора) → весь паттерн → снова колонка в доле. Отсчёт — от клетки, где начали
local SX = { 'column in the beat', 'column in the bar', 'the column', 'the bar, all tracks', 'half the pattern', 'the whole pattern' }
local SX_START = 3   -- 17 окт: первый шаг — колонка вертикально (весь паттерн), a — шире, i — уже (доля / такт)
function V.smart_expand(dir)
  dir = dir or 1
  local o = V.sx
  local first = not o
  if first then o = { fi = V.cur.fi, row = V.cur.row, step = SX_START - dir } end   -- от клетки курсора; курсор не двигается
  V.sx = o
  local L0 = lpb()
  local rg0, rg1
  if ctx.region_rows then rg0, rg1 = ctx.region_rows() end
  for _ = 1, #SX do
    o.step = (o.step - 1 + dir) % #SX + 1
    if o.step == 1 or o.step == 2 or o.step == 4 or rg0 then break end   -- нет региона — колонки / полпаттерна / паттерна нет
  end
  local f0, f1, r0, r1 = o.fi, o.fi, o.row, o.row
  if o.step == 1 then r0 = math.floor(o.row / L0) * L0; r1 = r0 + L0 - 1
  elseif o.step == 2 or o.step == 4 then
    local b0, b1 = ctx.bar_of_row(o.row); r0, r1 = b0, b1 - 1
    if o.step == 4 then f0, f1 = 1, nflat() end
  elseif o.step == 3 then r0, r1 = rg0, rg1          -- колонка курсора на весь паттерн
  else
    f0, f1 = 1, nflat()
    r0, r1 = rg0, rg1
    if o.step == 5 then
      local mid = rg0 + math.floor((rg1 - rg0 + 1) / 2)
      if o.row < mid then r1 = mid - 1 else r0 = mid end
    end
  end
  V.mode = 'visual'; V.vfield, V.vtrack = nil, nil
  V.vbox = { f0, f1, r0, r1, at = { fi = V.cur.fi, row = V.cur.row } }   -- рамка выделения; курсор на месте
  V.msg = ('select: %s (a - wider, i - narrower, Esc - off)'):format(SX[o.step])
end
function V.visual_range()
  local vb = V.vbox
  if vb and V.mode == 'visual' and vb.at.fi == V.cur.fi and vb.at.row == V.cur.row then return vb[1], vb[2], vb[3], vb[4] end
  V.vbox, V.sx = nil, nil                           -- курсор ушёл — обычное выделение от якоря
  local a, b = V.anchor or V.cur, V.cur
  local f0, f1 = math.min(a.fi, b.fi), math.max(a.fi, b.fi)
  if V.mode == 'vline' then f0, f1 = 1, nflat() end
  if V.vtrack and V.mode == 'visual' then   -- 19 окт: второе v — все подколонки треков выделения
    local F = flat()
    local c0, c1 = F[f0] and F[f0].col, F[f1] and F[f1].col
    while f0 > 1 and F[f0 - 1] and F[f0 - 1].col == c0 do f0 = f0 - 1 end
    while F[f1 + 1] and F[f1 + 1].col == c1 do f1 = f1 + 1 end
  end
  return f0, f1, math.min(a.row, b.row), math.max(a.row, b.row)
end

-- подсказка продолжений ожидающего оператора — справа в строке статуса
-- (просьба 2 окт: нажал d — видно, что можно дальше)
local PENDING_HINT = {
  d = 'd: d rows out, below moves up (3dd) | w clear the row, nothing moves | W clear the row, all tracks | i whole item | c automation column | C the cursor field in the whole track | t remove time selection | r track in region | R region, all tracks | T whole track, all regions | a all... (e l j k h) | p up to the pause | P all of the selected tracks | j k rows | G to end | gg to start | } { bar | $ fields | 3w count | Esc',
  y = 'y: y rows | c the field column (pattern) | w event | j k rows | G to end | gg to start | } { bar | 3j count | Esc',
  c = 'c: c rows (replace) | w event | j k rows | } { bar | Esc',
  g = 'g: g top | 12 Enter row 0012 | p P pattern start / end | s S section start / end | w swap | m metronome | q Q quantize / input quantize | t module menu | T project tab | VISUAL: i interpolate, r reform | Esc',
  T = 'T: f add take fx to the note under the cursor | o its take fx chain in DSP | Esc',
  z = 'z: a fold | c o compact / open | C strip | f folder | M all | . , < > width | z zoom | u unfold rows | p pattern / project | m minimize the pane | t b top / bottom',   -- 15 окт: главное; полный список — меню which-key
  r = 'r: note key sets pitch | hex digits set field | Esc',
  q = 'q: a..z record macro into register',
  da = 'da: e automation | l the row | j below | k above | h all but the row - the track; E L J K H - all tracks (E - in the pattern) | Esc',
  ['@'] = '@: a..z play macro | @ repeat last',
}
function V.pending_hint()
  if not V.pending then return nil end
  local p = V.op and V.pending == 'g' and V.op or V.pending
  local h = PENDING_HINT[p]
  if not h then return nil end
  return (V.count and (tostring(V.count) .. ' ') or '') .. h
end

-- 13 окт: окно ввода имени: pre — команда (её не видно), text — нынешнее имя (выделено)
function V.open_prompt(pre, text)
  -- 18 окт: выпадашка (текущее в строке, варианты, своё набором) вместо строки «:pre текст» — ctx.ask_prompt
  if ctx.ask_prompt and not V.raw_prompt then V.picker = nil; return ctx.ask_prompt(pre, text) end
  V.cmd_from = (V.mode == 'cmd') and (V.cmd_from or 'normal') or V.mode
  V.mode = 'cmd'; V.cmdline = pre .. (text or '')
  V.prompt = { pre = pre, pos = utf8.len(text or '') or #(text or ''), fresh = true }
end
function V.status()
  local m = ({ normal = '', insert = '-- INSERT --', visual = '-- VISUAL --', vline = '-- V-LINE --',
               cmd = V.prompt and 'rename' or (':' .. (V.cmdline or '')), search = '/' .. (V.searchline or '') })[V.mode] or ''
  -- 15 окт: KEYS — не режим (видимая клавиатура), убран. Набранное (счётчик, оператор) — третьим значением:
  -- рисуется у курсора [3d_], взгляд не прыгает; hex ([E_]) — уже в самой ячейке; запись макроса — слово режима MACROS@имя
  local extra = tostring(V.count or '') .. (V.pending or V.mlpend or '')   -- 15 окт: и d в лейнах мастера
  if V.macro then m = 'MACROS@' .. V.macro.name end
  return m, ('oct %d vel %d step %s inst %d'):format(V.octave, V.vel or 100, V.step_next and 'next' or (V.step_auto and 'auto' or tostring(V.step)), V.inst), extra
end

-- обёртка: оператор, начатый из INSERT (d…), по завершении возвращает в INSERT
function V.key(c)
  if ctx.piano_on then V.piano = ctx.piano_on() end    -- клавиатура = видна снизу (m), 5 окт
  local p0 = V.cur.fi * 1e6 + V.cur.row * 10 + (V.cur.field or 1)
  local r = V.key_impl(c)
  local E0 = ctx.edit
  if E0 and E0.skip_msg then V.msg = E0.skip_msg; E0.skip_msg = nil end   -- 19 okt: команда, которую нота не умеет
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
-- 19 окт: поле как колонка — v (первый раз) выделяет только поле курсора, yc копирует поле на весь паттерн,
-- p кладёт значения поля в ноты строк. Поле: 2 vol, 3 delay, 4+ команда k (значение — код + xx)
local function field_get(h, fld)
  if fld == 2 then return tonumber(h.vol or '', 16) elseif fld == 3 then return h.delay
  else return (h.fx or {})[fld - 3] end
end
local function field_set(h, fld, v)
  local E = ctx.edit
  if v == nil then
    if fld == 2 then E.set_vol({ h }, lpb(), 128) elseif fld == 3 then E.set_delay({ h }, lpb(), 0)
    else local cur = (h.fx or {})[fld - 3]; if cur then E.clear_fx({ h }, lpb(), cur:sub(1, 2)) end end
    return
  end
  if fld == 2 then E.set_vol({ h }, lpb(), v) elseif fld == 3 then E.set_delay({ h }, lpb(), v)
  elseif type(v) == 'string' then E.set_fx({ h }, lpb(), v:sub(1, 2), tonumber(v:sub(3), 16) or 0) end
end
V.field_get, V.field_set = field_get, field_set
function V.field_yank(f0, f1, r0, r1, fld)
  local reg = { kind = 'field', fld = fld, rows = r1 - r0 + 1, vals = {} }
  local n = 0
  -- 29 окт: колонка команд — каждая строка (команды строк внутри нот тоже), не только головы нот
  if fld >= 4 then
    local i = fld - 3
    local last = (ctx.snap and ctx.snap() and ctx.snap().last_row) or r1
    for fi = f0, f1 do
      for row = r0, math.min(r1, last + 1) do
        local fc = V.fx_cell(fi, row)
        local code = fc and fc.fx[i]
        if code then reg.vals[#reg.vals + 1] = { dr = row - r0, v = code }; n = n + 1 end
      end
    end
    V.regs['"'] = reg
    return n
  end
  for _, h in ipairs(V.heads_in(f0, f1, r0, r1)) do
    local v = field_get(h, fld)
    if v ~= nil then reg.vals[#reg.vals + 1] = { dr = (h.row0 or r0) - r0, v = v }; n = n + 1 end
  end
  V.regs['"'] = reg
  return n
end
function V.field_paste(reg, fi, row)
  local fld = (reg.fld >= 4 and (V.cur.field or 1) >= 4) and V.cur.field or reg.fld   -- команда — в колонку команды курсора
  local n = 0
  ctx.edit.run('paste field', function()
    for _, e in ipairs(reg.vals) do
      local hs = V.heads_in(fi, fi, row + e.dr, row + e.dr)
      for _, h in ipairs(hs) do field_set(h, fld, e.v); n = n + 1 end
      -- 21 окт: команда на строку внутри ноты (не её голова) — командой этой строки
      if #hs == 0 and fld >= 4 and type(e.v) == 'string' and #e.v == 4 then
        local fc = V.fx_cell(fi, row + e.dr)
        if fc and fc.off > 0 and V.fx_rowable(e.v:sub(1, 2)) then ctx.edit.set_fx({ fc.head }, lpb(), e.v:sub(1, 2), tonumber(e.v:sub(3), 16), fc.off); n = n + 1 end
      end
    end
  end)
  return n
end
-- 19 окт: интерполяция с формой: ноты между первой и последней получают значение поля по кривой
-- shape: lin | log | exp | sin (туда и обратно: к последней ноте — снова начальное значение); b — конец (nil — у последней)
function V.interp_shape(f0, f1, r0, r1, fld, shape, b0)
  local E = ctx.edit
  local n = 0
  local code
  E.run('interpolate ' .. shape, function()
    for fi = f0, f1 do
      local hs = V.heads_in(fi, fi, r0, r1)
      table.sort(hs, function(a, b) return a.row0 < b.row0 end)
      if #hs >= 2 then
        local va = field_get(hs[1], fld)
        local vb = b0 or field_get(hs[#hs], fld)
        if type(va) == 'string' then code = va:sub(1, 2); va = tonumber(va:sub(3), 16) end
        if type(vb) == 'string' then code = code or vb:sub(1, 2); vb = tonumber(vb:sub(3), 16) end
        if va and vb then
          local ra, rb = hs[1].row0, hs[#hs].row0
          for k = 2, #hs do
            local t = (hs[k].row0 - ra) / math.max(1, rb - ra)
            local f
            if shape == 'log' then f = math.log(1 + 9 * t) / math.log(10)
            elseif shape == 'exp' then f = (10 ^ t - 1) / 9
            elseif shape == 'sin' then f = math.sin(math.pi * t)
            else f = t end
            local v = math.floor(va + (vb - va) * f + 0.5)
            if k < #hs or shape == 'sin' or b0 then
              field_set(hs[k], fld, code and (code .. ('%02X'):format(math.max(0, math.min(255, v)))) or v); n = n + 1
            end
          end
        end
      end
    end
  end)
  return n, code
end
-- 19 окт: gi — выпадашка форм; нет значения у последней ноты — сетка значений (конец / вершина синуса)
function V.interp_menu()
  local f0, f1, r0, r1 = V.visual_range()
  local fld = V.vfield or V.cur.field or 1
  if fld < 2 then V.msg = 'gi: put the cursor on vol, delay or a command field (notes - Cmd+I)'; return end
  local function go(shape)
    local hs = V.heads_in(f0, f1, r0, r1)
    table.sort(hs, function(a, b) return a.row0 < b.row0 end)
    local last = hs[#hs]
    local function run(b0)
      local n = V.interp_shape(f0, f1, r0, r1, fld, shape, b0)
      V.mode = 'normal'; V.vfield = nil
      V.msg = n > 0 and ('interpolate %s: %d note(s)'):format(shape, n) or 'interpolate: needs 2+ notes and a value on the first'
      if ctx.model and ctx.model.invalidate then ctx.model.invalidate() end
    end
    if #hs >= 2 and (shape == 'sin' or field_get(last, fld) == nil) and ctx.smart_open and ctx.SM then
      local va = field_get(hs[1], fld); if type(va) == 'string' then va = tonumber(va:sub(3), 16) end
      local its, cs, sl = ctx.SM.values(256, va, true)
      ctx.smart_open({ title = shape == 'sin' and 'sine: the peak value (it comes back)' or 'interpolate: the end value', items = its, cols = cs, sel = sl,
        on_pick = function(it) if type(it.v) == 'number' then run(it.v) end end })
    else run(nil) end
  end
  V.open_hydra({ title = 'interpolate ' .. (fld == 2 and 'vol' or (fld == 3 and 'delay' or 'command')), items = {
    { key = 'l', label = 'linear', fn = function() go('lin') end },
    { key = 'g', label = 'logarithmic (fast, then slow)', fn = function() go('log') end },
    { key = 'e', label = 'exponential (slow, then fast)', fn = function() go('exp') end },
    { key = 's', label = 'sine - up to a value and back', fn = function() go('sin') end } } })
end
-- 19 окт: ноты для humanizer (:human и панель): VISUAL — блок, иначе трек курсора в регионе курсора
function V.hum_heads(vis)
  if vis == nil then vis = V.mode == 'visual' or V.mode == 'vline' end
  if vis then local f0, f1, r0, r1 = V.visual_range(); return V.heads_in(f0, f1, r0, r1) end
  local F = flat(); local col = F[V.cur.fi] and F[V.cur.fi].col
  local r0, r1
  if ctx.region_rows then r0, r1 = ctx.region_rows() end
  r0, r1 = r0 or 0, r1 or 1000000
  local hs = {}
  for fi, f in ipairs(F) do
    if f.col == col and not f.env then for _, h in ipairs(V.heads_in(fi, fi, r0, r1)) do hs[#hs + 1] = h end end
  end
  return hs
end
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
    if f.ml.kind == 'vis' and ctx.visor_pick then ctx.visor_pick(row); return true end   -- 11 окт: сетка сцен с превью
    if not (f.ml.kind == 'cc' or f.ml.kind == 'pc') then V.msg = 'smart: this MIDI lane has no values'; return false end
    items, cols, sel = SM.values(128, nil, hexf, 'delete the events of this row')
    title = ('%s %s  %s'):format(f.ml.kind:upper(), f.ml.num and tostring(f.ml.num) or '', where)
    pick = function(it)
      if it.v == 'clear' then ctx.ml_del(f, row) else ctx.ml_set(f, row, it.v) end
      done()
    end
  elseif f.env then
    if vis and r1 > r0 and ctx.env_curves then return ctx.env_curves(f, r0, r1) end   -- 24 окт: выделение — кривые
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
    local base = #pool0 + (ctx.empty_slots and ctx.empty_slots(#pool0) or 0) + (ctx.inst_off and ctx.inst_off(f.col) or 0)   -- 21 окт: сквозные номера
    for k, fi2 in ipairs(ctx.track_insts and ctx.track_insts(f.col) or {}) do
      items[#items + 1] = { label = ('%02d %s'):format(ctx.inst_disp and ctx.inst_disp(f.col, base + k) or (base + k), fi2.name or 'instrument'), v = base + k, tip = (fi2.name or '') .. '  (plugin - the note becomes MIDI)' }
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
    local old = h1 and ni or nil
    pick = function(it)
      if ctx.set_inst then ctx.set_inst(heads(), it.v) end; V.inst = it.v; done()
      -- 21 окт: и остальные ноты трека с прежним инструментом — в паттерне / на всём треке (меню)
      if old and old ~= it.v and ctx.inst_ask_all then ctx.inst_ask_all(f.col, old, it.v) end
    end
    if not h1 then V.msg = 'smart: an empty row - the instrument is chosen for the next notes' end
  elseif fld == 1 then
    local h1 = heads()[1]
    items, cols, sel = SM.notes(h1 and h1.pitch, V.octave, h1 and h1.micro)
    title = (h1 and ('note %s'):format(h1.note or '') or 'note') .. '  ' .. where
    listen = function(it)
      if type(it.v) ~= 'number' or not ctx.preview then return end   -- микротон — слышен после выбора
      local inst = (f.col.pool or {})[V.inst]
      if ctx.inst_fx and ctx.inst_fx(f.col) then inst = nil end
      ctx.preview(f.col.track, it.v, (ctx.inst_src and ctx.inst_src(f.col, inst) or (inst and inst.item)), row, 1)
    end
    pick = function(it)
      if it.v == nil then return SM.p end
      local hs = heads()
      if type(it.v) == 'table' and it.v.micro then
        -- 24 окт: микротон у нот строки: сдвиг до выбранной ступени (MIDI — MTS перед нотой, аудио — дробный pitch)
        if #hs == 0 then V.msg = 'microtone: put a note in this row first'; return SM.p end
        for _, h in ipairs(hs) do
          local d = it.v.micro - (h.micro or 0)
          if d ~= 0 then E.micro_nudge({ h }, lpb(), d) end
        end
        V.msg = ('microtone %s: %+.1f cents'):format(it.label, it.v.micro * 100 / 6)
        done(); return
      end
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
    -- 12 окт: смысл значения в подсказке: громкость — dB (80 = 0 dB) / velocity, задержка — доля строки
    local mean = fld == 3 and function(v) return ('%d/256 row (%d%%)'):format(v, math.floor(v / 256 * 100 + 0.5)) end
      or (h1.kind == 'midi' and function(v) return 'velocity ' .. math.min(127, v) end
      or function(v) return v == 0 and '-inf dB' or ('%+.1f dB'):format(20 * math.log(v / 128, 10)) end)
    items, cols, sel = SM.values(n, cur, true, fld == 2 and 'volume back to default' or 'no delay', mean)
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
    local hs0 = heads()
    local fc = (#hs0 == 0 and not vis) and V.fx_cell(fi, row) or nil   -- 12 окт: строка внутри ноты — её команды
    if fc then hs0 = { fc.head } end
    local h1 = hs0[1]
    if not h1 then V.msg = 'commands belong to a note: no note sounds in this row - put the cursor on a note (or its rows)'; return false end
    local have = (fc and fc.fx or h1.fx or {})[fld - 3]
    local function vals(letter, curx)
      local its, cs, sl = SM.values(256, curx, true, 'delete ' .. letter .. 'xx', SM.FX_MEAN and SM.FX_MEAN[letter])
      local desc = SM.FX_DESC[letter] or ''
      -- 17 окт: прослушать значение — команда пишется в ноту и нота звучит с ней (ретриггер — копии, их не
      -- услышать без записи); Esc без выбора — прежнее значение назад
      local heard = false
      local function restore()
        if not heard then return end
        local hs = fc and { fc.head } or heads()
        local off = (fc and fc.off > 0 and V.fx_rowable(letter)) and fc.off or nil
        if have and have:sub(1, 2) == letter then E.set_fx(hs, lpb(), letter, tonumber(have:sub(3), 16), off)
        else E.clear_fx(hs, lpb(), letter, off) end
      end
      return { title = ('%sxx  %s  %s'):format(letter, desc, where), items = its, cols = cs, sel = sl,
               on_sel = function(it)
                 if type(it.v) ~= 'number' then return end
                 local hs = fc and { fc.head } or heads()
                 local off = (fc and fc.off > 0 and V.fx_rowable(letter)) and fc.off or nil
                 E.set_fx(hs, lpb(), letter, it.v, off); heard = true
                 if ctx.model and ctx.model.invalidate then ctx.model.invalidate() end
                 -- 19 окт: MIDI-нота — звучит только она (в инструмент трека, как превью пэда), не весь item транспортом
                 local h0 = hs[1]
                 if h0 and h0.kind == 'midi' and h0.pitch and h0.item and ctx.preview then
                   local tr = reaper.GetMediaItem_Track(h0.item)
                   local _, nt
                   if E.midi_note_of then _, nt = E.midi_note_of(h0, lpb()) end   -- 29 окт: «and» срезал nt
                   local pp = (nt and nt.pitch) or h0.pitch
                   if tr and letter == '0R' and ctx.preview_retrig then   -- 28 окт: слышно повторы, не одну ноту
                     ctx.preview_retrig(tr, pp, it.v, nt and nt.len_rows or h0.len_rows or h0.rows)
                   elseif tr then ctx.preview(tr, pp, 'midi') end   -- 0S на ките мог сменить пэд
                   -- 19 окт: 0U / 0D — изгиб слышно: pitch bend шагами за время превью (0.4 с), наклон — xx/16 полутона за строку
                   if (letter == '0U' or letter == '0D') and ctx.preview_bend and ctx.row_sec then
                     ctx.preview_bend(h0.ch or 0, E.cmds.slide_semis({ cmd = letter, xx = it.v }, 1, pp) / ctx.row_sec(), 0.4, tr)   -- 30 окт: стиль слайда
                   end
                 elseif ctx.play_note_item and h0 and h0.item then ctx.play_note_item(h0.item) end
               end,
               on_close = restore,
               on_pick = function(it)
                 local hs = fc and { fc.head } or heads()
                 local off = (fc and fc.off > 0 and V.fx_rowable(letter)) and fc.off or nil
                 if have and have:sub(1, 2) ~= letter then E.clear_fx(hs, lpb(), have:sub(1, 2), (fc and fc.off > 0 and V.fx_rowable(have:sub(1, 2))) and fc.off or nil) end
                 if it.v == 'clear' then E.clear_fx(hs, lpb(), letter, off) else E.set_fx(hs, lpb(), letter, it.v, off) end
                 done()
               end }
    end
    if have then
      local p = vals(have:sub(1, 2), tonumber(have:sub(3), 16))
      return ctx.smart_open(p)
    end
    -- 19 окт: MIDI-нота — только команды, которые она умеет (система команд: 0U 0D 0G …); 0S, SI, SO, SL … — у аудио
    local midi = h1 and h1.kind == 'midi'
    local kitn = midi and E.kit_pad and h1.item and h1.pitch and E.kit_pad(reaper.GetMediaItem_Track(h1.item), h1.pitch)
    items, cols, sel = SM.fx_letters(midi and function(code) return (E.cmds and E.cmds.CODES[code]) or (code == '0S' and kitn) end or nil)   -- нота кита: 0S — сдвиг окна пэда
    -- 24 окт: fzf — команды ноты и параметры эффектов трека (сверху выбранный / последние тронутые);
    -- параметр — его огибающая колонкой рядом, курсор (и выделение) — на неё
    if ctx.fx_param_picker and f.col and f.col.track then
      return ctx.fx_param_picker(f.col, items, function(code) return ctx.smart_open(vals(code, nil)) end, { row = row, r0 = r0, r1 = r1, vis = vis })
    end
    title = 'command  ' .. where .. (midi and '  (MIDI note: 0S offset and item commands - audio only; drumrs5k: the note picks the pad)' or '')
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
-- 21 окт: где кончится новая MIDI-нота: следующее событие подколонки (нота или OFF), иначе конец паттерна курсора
function V.sustain_row(sub, row)
  local best
  for r, cell in pairs(sub or {}) do
    if r > row and (cell.kind == 'audio' or cell.kind == 'midi' or cell.kind == 'off') and (not best or r < best) then best = r end
  end
  if not best and ctx.region_rows then local _, r1 = ctx.region_rows(); if r1 and r1 >= row then best = r1 + 1 end end
  return best
end
-- 21 окт: ` под тонкой нотой (уже кончилась выше) — её голова выше по подколонке, без OFF / событий между
function V.head_above(sub, row)
  for r = row - 1, math.max(0, row - 4096), -1 do
    local cell = sub and sub[r]
    if cell then
      if cell.kind == 'midi' then return cell end
      if (cell.kind == 'cont' or cell.kind == 'off') and cell.of and cell.of.kind == 'midi' then return cell.of end   -- 21 окт: и за её OFF — перенести OFF ниже
      return nil
    end
  end
end
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
function V.pan_field_ok()
  local f = flat()[V.cur.fi]
  if not f or f.env or f.compact or f.folded or f.ml then return false end
  local G = f.G or ctx.layout()
  return G.x_pan and true or false
end
function V.wave_field_ok()   -- 16 окт: колонка волны есть у этой подколонки
  local f = flat()[V.cur.fi]
  if not f or f.env or f.folded or f.ml then return false end   -- 20 окт: MIDI-лейн (PB, CC …) — волны нет, l уводил в невидимое подполе
  -- 22 окт: узкая колонка (уровень ширины «нота», compact → GC) волну показывает — курсор туда тоже (решает G.w_wave)
  local G = f.G or ctx.layout()
  return (G.w_wave or 0) > 0
end
function V.inst_field_ok()
  local f = flat()[V.cur.fi]
  if not f or f.env or f.folded or f.ml then return false end   -- 20 окт: и MIDI-лейн (h загонял туда «slice»); 21 окт: свёрнутый — по раскладке (GCM — есть, GC — нет)
  local G = f.G or ctx.layout()
  return G.x_inst and true or false   -- 11 окт: false у узких подколонок — поля нет
end

V.ensure_visible = ensure_visible   -- курсор в окне (9 окт: вкладка video)

return V
