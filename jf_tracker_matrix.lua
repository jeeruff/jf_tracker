-- jf_tracker_matrix.lua — матрица паттернов (этап 3).
--
-- Узкая панель слева: вертикаль — регионы в порядке проигрывания
-- (паттерны), горизонталь — треки. Ячейка = трек × регион:
--   схема: линии по четвертям региона, микровид: штрихи, заглушено: X
--   «< NN >» у слота — переключить паттерн (длина и содержимое региона;
--   единственный экземпляр уходит в библиотеку после маркера =LIB)
-- строка играющего региона подсвечена. Курсор матрицы (фокус по Tab):
-- h j k l — ячейка, движение прокручивает трекер к началу региона и ставит
-- курсор трекера в ту же строку/трек; m / Enter — mute всех items ячейки
-- (B_MUTE, undo-блок); правый клик — то же мышью. Нет регионов — панели нет.
-- y — запомнить регион как паттерн, p — его повтор в конце проекта (алиас:
-- регионы с одним именем синхронизируются, см. jf_tracker_alias.lua).
--
-- Регионы читает модель (M.regions), записи идут через edit.mute_span.
-- Блок ячеек: Shift+hjkl / v — выделение от якоря; Ctrl+N mute, Ctrl+X и
-- Cmd+Backspace вырезать, Ctrl+C / Ctrl+V копировать и вставить от курсора
-- (содержимое ячеек-целей заменяется, хвосты режутся по региону).
-- Границы ЖЁСТКИЕ: items режутся по регионам (A.trim) — кнопка trim / t /
-- :trim, и автоматически после правок при :autosync. Зум z: схема (ряд в
-- строку) ↔ детальный (ряд в 4 строки, время сверху вниз, цвета items,
-- мини-огибающие, плейхед линией).

local MX = {}
local U, ctx

MX.cur = { ri = 1, ci = 1 }
MX.focus = false
MX.anchor = nil        -- якорь блока (Shift+hjkl / v); блок = anchor..cur
MX.picks = {}          -- 9 окт: ячейки вразброс (Cmd+щелчок), ключ «ri:ci» → { ri, ci }
MX.selmode = false     -- 9 окт: режим sel (кнопка zoom) — в трекере только треки выделенных ячеек
-- треки выделения: блок + ячейки вразброс; пусто — ячейка курсора. ci → true
function MX.sel_cols()
  local out, any = {}, false
  if MX.anchor then
    local _, _, c0, c1 = MX.block()
    for ci = c0, c1 do out[ci] = true; any = true end
  end
  for _, p in pairs(MX.picks) do out[p.ci] = true; any = true end
  if not any and MX.cur.ci and MX.cur.ci >= 1 then out[MX.cur.ci] = true end
  return out
end
function MX.block()
  local a = MX.anchor or MX.cur
  -- колонки номера / имени (ci −1 / 0) в блок не входят — только треки
  return math.min(a.ri, MX.cur.ri), math.max(a.ri, MX.cur.ri), math.max(1, math.min(a.ci, MX.cur.ci)), math.max(1, a.ci, MX.cur.ci)
end

function MX.init(u, c) U, ctx = u, c end

-- ── состояние ячеек ───────────────────────────────────────────────────────
-- grid[ri][ci] = { state = 'empty'|'has'|'muted', cov = доля строк региона
-- под событиями, ev = { {pos=0..1, len=0..1, kind, muted} … } } — для двух
-- зумов: схема (полоска загруженности) и микровид (события по позициям).
local cache = { snap = nil, regs = nil, grid = nil }
MX.zoom = 'schematic'       -- 'schematic' | 'detail'; `:mxzoom`, в матрице z

-- clips — сразу за fold (6 окт): в конце ряда кнопка уходила под ручки < > = у линии раздела
local BTNS = { { 'fold', 'sel' }, { 'zoom', 'detail' }, { 'fill', 'fill' }, { 'sync', 'sync' }, { 'trim', 'trim' }, { 'ruler', 'ruler' }, { 'loops', 'loops' }, { 'add', '+' } }
local FOLD_BTNS = { { 'fold', 'zoom' } }        -- свёрнутая: одна кнопка — развернуть (7 окт: fold зовётся zoom, clips из матрицы убраны)
-- кнопки, которые видны (5 окт): sync — только без autosync (он и так
-- синхронизирует после каждой правки), loops — только в режиме .dev (Garden)
local function btns()
  if MX.fold and not MX.clips then return FOLD_BTNS end   -- свёрнутая: fold и clips   -- clips поверх fold: нужен весь ряд, чтобы выключить
  local out = {}
  for _, b in ipairs(BTNS) do
    local hide = (b[1] == 'sync' and ctx and ctx.autosync_on and ctx.autosync_on()) or (b[1] == 'loops' and not (ctx and ctx.dev_on and ctx.dev_on()))
    if not hide then out[#out + 1] = b end
  end
  return out
end
MX.loops = false         -- слой лупов (бывший Garden, 2 окт): период лупа в ячейках, клавиши лупов
MX.ruler = true          -- вертикальная линейка тактов слева (кнопка ruler, R)
MX.clips = false         -- вид clips (6 окт): сессия в панели матрицы — сцены × треки, запуск клипов (кнопка clips, zz — на всё окно)
MX.fold = false          -- свёрнутая матрица (3 окт): номера, имена треков, ячейки — без имён / длин / линейки (кнопка fold, F)
MX.ENV_PTS = 12          -- отсчётов огибающей на ячейку в детальном зуме

-- клетка: события трека col на лейнах lanes в регионе rg (MX.grid — все
-- лейны трека, MX.vgrid — один лейн виртуальной колонки сессии)
-- 8 окт: события колонки — один раз списком по строке начала (было: для
-- каждой клетки сетки — перебор всех нот трека; 425 × 28 клеток ≈ 46 мс)
local function col_index(lanes)
  local list, maxlen = {}, 1
  for _, lane in ipairs(lanes) do
    for _, sub in ipairs(lane.subs) do
      for r, cell in pairs(sub) do
        if cell.kind == 'audio' or cell.kind == 'midi' then
          local n = cell.rows or 1
          list[#list + 1] = { r = r, cell = cell }
          if n > maxlen then maxlen = n end
        end
      end
    end
  end
  table.sort(list, function(a, b) return a.r < b.r end)
  return { list = list, maxlen = maxlen }
end
local function first_ge(list, v)               -- первый индекс с list[i].r >= v
  local lo, hi = 1, #list + 1
  while lo < hi do local m = (lo + hi) // 2; if list[m].r < v then lo = m + 1 else hi = m end end
  return lo
end
local function cell_of(col, lanes, rg, rgb_of, model, idx)
      local span = math.max(1, rg.r1 - rg.r0)
      local has, all_muted, covered, ev = false, true, 0, {}
      idx = idx or col_index(lanes)
      local list = idx.list
      for k = first_ge(list, rg.r0 - idx.maxlen + 1), first_ge(list, rg.r1) - 1 do
        local r, cell = list[k].r, list[k].cell
        do
          do
            do
              local r1 = r + (cell.rows or 1) - 1
              if r < rg.r1 and r1 >= rg.r0 then
                has = true
                if not cell.muted then all_muted = false end
                local a, b = math.max(r, rg.r0), math.min(r1 + 1, rg.r1)
                covered = covered + (b - a)
                -- цвет события: цвет item (аудио — в голове, MIDI — по item), иначе трека
                local rgb = cell.rgb
                if not rgb and cell.item and model and model.item_rgb then
                  rgb = rgb_of[cell.item]
                  if rgb == nil then rgb = model.item_rgb(cell.item) or false; rgb_of[cell.item] = rgb end
                  rgb = rgb or nil
                end
                ev[#ev + 1] = { pos = (a - rg.r0) / span, len = (b - a) / span, kind = cell.kind, muted = cell.muted, rgb = rgb or col.rgb,
                                head = cell.kind == 'audio' and cell or nil, cut = (r < rg.r0) and (rg.r0 - r) / math.max(1, r1 - r + 1) or 0,   -- head: волна в клипе (6 окт)
                                pitch = cell.kind == 'midi' and r >= rg.r0 and cell.pitch or nil, r0 = r }   -- 8 окт: аккорды клипа (ноты одной строки)
              end
            end
          end
        end
      end
      -- мини-автоматизация: отсчёты каждой огибающей трека на длине региона
      -- 8 окт: отсчёты — лениво, при первой отрисовке клетки (MX.cell_envs):
      -- сетка строится на весь проект после каждой пересборки, и десятки
      -- Envelope_Evaluate на огибающую в каждой клетке давали пик ~110 мс
      local envsrc = (model and model.env_samples and col.envs and #col.envs > 0) and { col = col, pos = rg.pos, e1 = rg.rgnend } or nil
      return { state = has and (all_muted and 'muted' or 'has') or 'empty', cov = math.min(1, covered / span), ev = ev, envsrc = envsrc }
end

function MX.cell_envs(g)
  if g.envs or not g.envsrc then return g.envs end
  local src, envs = g.envsrc, {}
  local model = ctx and ctx.model
  if not model then return nil end
  for _, e in ipairs(src.col.envs) do envs[#envs + 1] = { e = e, pts = model.env_samples(e, src.pos, src.e1, MX.ENV_PTS) } end
  g.envs, g.envsrc = envs, nil
  return envs
end
function MX.grid(snap, regions)
  if cache.snap == snap and cache.regs == regions then return cache.grid end
  local t0 = reaper.time_precise()
  local grid = {}
  local rgb_of = {}        -- item → цвет (один вызов на item)
  local model = ctx and ctx.model
  local idxs = {}
  for ri, rg in ipairs(regions) do
    local row = {}
    for ci, col in ipairs(snap.cols) do
      idxs[ci] = idxs[ci] or col_index(col.lanes)
      row[ci] = cell_of(col, col.lanes, rg, rgb_of, model, idxs[ci])
    end
    grid[ri] = row
  end
  cache.snap, cache.regs, cache.grid = snap, regions, grid
  local dt = (reaper.time_precise() - t0) * 1000
  if dt > 5 and ctx and ctx.dlog and ctx.state and ctx.state.debug then ctx.dlog(('matrix grid %d x %d: %.1f ms'):format(#regions, #snap.cols, dt)) end
  return grid
end

-- ── сессия по лейнам (7 окт): виртуальная колонка = лейн трека ──────────
-- у трека с фиксированными лейнами — колонка на каждый лейн (два клипа на
-- одном треке играют вместе: REAPER играет пересекающиеся items), у
-- обычного — одна. { ci, li, col, track, lane (I_FIXEDLANE или nil), name, guid, rgb }
local vcache = {}
function MX.vcols(snap)
  if vcache.snap == snap then return vcache.vs end
  local V = {}
  for ci, col in ipairs(snap.cols) do
    local n = #(col.lanes or {})
    if n <= 1 then
      V[#V + 1] = { ci = ci, li = 1, col = col, track = col.track, name = col.name, guid = col.guid, rgb = col.rgb, lanes = col.lanes, armed = col.armed }
    else
      for li, lane in ipairs(col.lanes) do
        local lname = (lane.name and lane.name ~= '') and lane.name or ('L' .. ((lane.idx or (li - 1)) + 1))
        V[#V + 1] = { ci = ci, li = li, col = col, track = col.track, lane = lane.idx or (li - 1), name = col.name .. ' ' .. lname,
                      guid = col.guid .. ':' .. li, rgb = col.rgb, lanes = { lane }, armed = col.armed }
      end
    end
  end
  vcache.snap, vcache.vs, vcache.grid, vcache.regs = snap, { cols = V }, nil, nil
  return vcache.vs
end
function MX.vgrid(snap, regions)
  local vs = MX.vcols(snap)
  if vcache.grid and vcache.regs == regions then return vcache.grid end
  local grid, rgb_of, model = {}, {}, ctx and ctx.model
  local vidx = {}
  for ri, rg in ipairs(regions) do
    local row = {}
    for vi, v in ipairs(vs.cols) do vidx[vi] = vidx[vi] or col_index(v.lanes); row[vi] = cell_of(v.col, v.lanes, rg, rgb_of, model, vidx[vi]) end
    grid[ri] = row
  end
  vcache.grid, vcache.regs = grid, regions
  return grid
end

-- ── раскладка ─────────────────────────────────────────────────────────────
MX.fill = true          -- схематичное заполнение ячеек (кнопка «fill»)
MX.name_h = 0

-- ДЕТАЛЬНЫЙ ЗУМ — ПО ВЕРТИКАЛИ (решение пользователя 1 окт): ряд слота в
-- MX.DETAIL_ROWS раз выше, ширина почти та же; время в ячейке идёт сверху
-- вниз, как в трекере: items — цветными блоками, огибающие — линиями.
MX.DETAIL_ROWS = 4
-- плавный зум (5 окт, как в REAPER): MX.vz — высота строки в строках текста
-- (Cmd+колесо), MX.hz — ширина ячейки в символах (Option+колесо); detail —
-- когда строка выше 1.75; MX.hs — первая видимая колонка (гориз. прокрутка)
MX.vz, MX.hz, MX.hs = 1, 2, 0
function MX.set_zoom(vz, hz)
  MX.vz = math.max(1, math.min(10, vz or MX.vz))
  MX.hz = math.max(1, math.min(16, hz or MX.hz))
  MX.zoom = MX.vz >= 1.75 and 'detail' or 'schematic'
end
function MX.toggle_zoom()
  if MX.zoom == 'detail' then MX.set_zoom(1, 2) else MX.set_zoom(MX.DETAIL_ROWS, 3) end
end

function MX.width(L, nregions, ncols)
  -- «< NN >»: стрелки и номер не налезают — ширина из частей с зазорами
  L.mx_arrow_w = U.measure('<')
  -- линейка слева (2 окт): «такт.доля» начала слота, риски тактов и долей
  L.mx_ruler_w = (MX.ruler and not MX.fold) and (U.measure('999.9') + 2 * L.pad + 4) or 0
  L.mx_idx_w = L.mx_ruler_w + L.pad + 2 * (L.mx_arrow_w + 3) + U.measure('00') + L.pad
  L.mx_dur_w = MX.fold and 0 or (U.measure('9999') + L.pad)          -- колонка длины региона в шагах
  -- размер такта в начале региона (5 окт); 9 окт: у всех один — колонки нет (:sig остаётся)
  L.mx_sig_w = (MX.fold or MX.sig_same) and 0 or (U.measure('15/16') + L.pad)
  -- 9 окт: имя региона — по самому длинному имени (с прошлого кадра), 3..6 знаков
  local nmw = math.max(U.measure('WWW'), math.min(U.measure('WWWWWW'), MX.rgname_px or U.measure('WWWW'))) + 2   -- +2: поле имени уже на 2 px
  L.mx_label_w = MX.fold and L.mx_idx_w or (L.mx_idx_w + nmw + L.pad + L.mx_sig_w + L.mx_dur_w)
  L.mx_cell_w = math.floor(L.cw * MX.hz) + 2 * L.pad
  L.mx_row_h = math.max(L.rh, math.floor(L.rh * MX.vz + 0.5))
  -- кнопки шапки не выходят за рамку модуля: ширина — не меньше ряда кнопок
  local bw = L.pad
  for _, b in ipairs(btns()) do
    local label = b[2]
    if ctx and ctx.ic then label = ctx.ic(b[1], label) end
    bw = bw + U.measure(label) + 2 * L.pad + L.pad
  end
  MX.btns_w = bw
  -- шапка матрицы: вертикальные имена треков (до 10 букв) + полоса кнопок
  -- 8 окт: высота — по самому длинному имени трека (прошлый кадр), не больше 10 знаков
  MX.name_h = L.cw * math.max(3, math.min(10, MX.name_chars or 10)) + 4
  L.mx_head_h = L.rh + 2 + MX.name_h + 4
  -- справа — колонка кнопок < > = у линии раздела: ячейки под неё не уходят
  local knob_w = U.measure('>') + 2 * L.pad + 6
  local w = math.max(L.mx_label_w + ncols * L.mx_cell_w + L.pad + knob_w, MX.btns_w + L.pad + knob_w)   -- ряд кнопок не под ручками
  if MX.clips then w = math.max(w, L.cw * 8 + math.min(ncols, 6) * L.cw * 8 + 3 * L.pad + knob_w) end   -- clips: клетки не уже 8 знаков (до 6 треков без прокрутки)
  return w
end

-- ── отрисовка ─────────────────────────────────────────────────────────────
-- Панель ниже верхней полосы. Сверху — кнопки (zoom / fill / lib), под ними
-- имена треков вертикально, затем строки-слоты: «< NN > имя» и ячейки.
-- Ячейка: схема — горизонтальные линии по четвертям региона (где есть
-- события), микровид — штрихи по позициям; заглушено — X поверх.
-- Возвращает hover = { ri=, ci=, prev=, next=, btn= }.

function MX.draw(L, snap, regions, info, Y, Wd, Hd)
  do   -- 9 окт: ширина имени региона на следующий кадр (MX.width) — по всем регионам, не по видимым
    local w = 0
    local s0, same = nil, true
    for _, rg in ipairs(regions) do
      if not rg.gap then
        w = math.max(w, U.measure(rg.name ~= '' and rg.name or ('#' .. tostring(rg.idx))))
        if info.sig_at then
          local n, d = info.sig_at(rg.pos)
          local k = (n or 4) .. '/' .. (d or 4)
          if s0 and k ~= s0 then same = false end
          s0 = s0 or k
        end
      end
    end
    MX.rgname_px, MX.sig_same = w, same
  end
  -- пустой проект (нет регионов) — матрица всё равно видна: кнопки, + (2 окт)
  local grid = MX.grid(snap, regions)
  local W = Wd or L.matrix_w                -- 9 окт, панели: ширина и верх / низ листа (x — 0, сдвиг буфером)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover = {}
  -- верх / низ матрицы: главный модуль может стоять в левой колонке (3 окт)
  local hy = Y or L.mx_top or L.header_y
  local ybot = Y and (Y + Hd) or L.mx_bot or (L.body_y + L.body_h + (L.low_h or L.hsb_h or 0))
  U.set(U.PANEL); gfx.rect(0, hy, W, ybot - hy, 1)
  hover.inside = mx >= 0 and mx < W and my >= hy and my < ybot      -- колесо над матрицей (5 окт)
  -- кнопки
  local bx = L.pad
  for _, b in ipairs(btns()) do
    local label = b[2]
    if ctx.ic then label = ctx.ic(b[1], label) end
    local bw = U.measure(label) + 2 * L.pad
    local hot = mx >= bx and mx < bx + bw and my >= hy + 1 and my < hy + L.rh + 1
    U.set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, hy + 1, bw, L.rh, 1)
    U.set(U.LINE); gfx.rect(bx, hy + 1, bw, L.rh, 0)
    U.text(bx + L.pad, hy + 2, label, hot and U.AMBER or (((b[1] == 'ruler' and MX.ruler) or (b[1] == 'loops' and MX.loops) or (b[1] == 'fill' and MX.fill) or (b[1] == 'fold' and MX.selmode) or (b[1] == 'clips' and MX.clips)) and U.CYAN or U.TEXT))
    if hot then hover.btn = b[1] end
    if ctx.hint then ctx.hint('mxbtn', bx, hy + 1, bw, L.rh, b[1]) end
    bx = bx + bw + L.pad
  end
  MX.ss_split_y = nil
  -- вид clips (6 окт): вместо слотов — сетка сессии (компактная), hover — её поля
  -- clips (6 окт, просьба): клипы сверху — компактно, матрица слотов ниже
  if MX.clips and ctx.ss_draw then
    local avail = ybot - hy - L.rh - 2
    -- высота: тянется мышью за линию снизу (ctx.ss_px), иначе — по рядам, до 45 %
    local px = ctx.ss_px and ctx.ss_px()
    local ch = px and math.max(3 * L.rh, math.min(avail - 6 * L.rh, px))
      or (ctx.ss_height and ctx.ss_height(W - 6, math.floor(avail * 0.45)) or math.floor(avail * 0.4))
    MX.ss_top = hy + L.rh + 2                              -- верх блока клипов
    MX.ss_split_y = MX.ss_top + ch                         -- линия раздела clips | слоты (ручка высоты)
    local hv = ctx.ss_draw(L, 0, hy + L.rh + 2, W - 6, ch)
    for k, v in pairs(hv) do hover[k] = v end
    hover.sess_view = true
    U.set(U.LINE); gfx.rect(0, hy + L.rh + 2 + ch, W - 4, 1, 1)
    hy = hy + ch + 2
  end
  -- вертикальные имена треков
  local ny = hy + L.rh + 3
  local nmax = 0                                      -- 8 окт: самое длинное имя среди ВИДИМЫХ колонок
  for ci, col in ipairs(snap.cols) do
    local x = L.mx_label_w + (ci - 1 - MX.hs) * L.mx_cell_w
    if x + L.mx_cell_w > W - 4 then break end
    if ci > MX.hs then nmax = math.max(nmax, utf8.len(col.name ~= '' and col.name or tostring(ci)) or 0) end
  end
  MX.name_chars = nmax
  for ci, col in ipairs(snap.cols) do
    local x = L.mx_label_w + (ci - 1 - MX.hs) * L.mx_cell_w
    if x + L.mx_cell_w > W - 4 then break end
    if ci > MX.hs then
    local is_cur = (info.cur_ci == ci)
    ctx.vtext(x + (L.mx_cell_w - L.th) / 2, ny, MX.name_h - 2, col.name ~= '' and col.name or tostring(ci),
      is_cur and U.AMBER or U.TEXT, U.PANEL)
    if col.rgb then U.set(col.rgb); gfx.rect(x + 1, ny + MX.name_h, L.mx_cell_w - 2, 2, 1) end
    end
  end
  -- аранжировка (9 окт): пустой угол над слотами, левее имён треков —
  -- имя и управление: < имя >, new dup del; строки — сколько влезает
  do
    local ax0, ax1, ay = L.pad, L.mx_label_w - L.pad, ny
    local nrow = math.floor((MX.name_h + 2) / L.rh)
    local an, ac, anum = nil, 0, 0
    if ctx.arr_name then an, ac, anum = ctx.arr_name() end
    local function btn(bx, by, label, id, on)
      local bw = U.measure(label) + 2 * L.pad
      if bx + bw > ax1 then return bx end
      local hot = mx >= bx and mx < bx + bw and my >= by and my < by + L.rh
      U.set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, by, bw, L.rh, 1)
      U.set(U.LINE); gfx.rect(bx, by, bw, L.rh, 0)
      U.text(bx + L.pad, by + 1, label, hot and U.AMBER or (on and U.CYAN or U.TEXT))
      if hot then hover.btn = id end
      if ctx.hint then ctx.hint('mxbtn', bx, by, bw, L.rh, id) end
      return bx + bw + L.pad
    end
    if nrow >= 1 and ax1 - ax0 >= 8 * L.cw then
      local rows = {}
      if nrow >= 3 then rows[#rows + 1] = 'title' end
      rows[#rows + 1] = 'name'
      if nrow >= 2 then rows[#rows + 1] = 'ops' end
      for _, r in ipairs(rows) do
        if r == 'title' then
          local nol = anum > 0 and ctx.arr_has_lanes and not ctx.arr_has_lanes()
          U.text(ax0, ay + 1, ctx.fit(anum > 0 and (('arrangement %d/%d'):format(ac, anum) .. (nol and ' - no lanes' or '')) or 'arrangement', ax1 - ax0), nol and U.AMBER or U.GREY)
        elseif r == 'name' then
          local bx = btn(ax0, ay, '<', 'arrprev')
          local nw = ax1 - bx - (U.measure('>') + 3 * L.pad)
          local lab = ctx.fit(an or 'none - new makes one', math.max(0, nw - 2 * L.pad))
          local hot = mx >= bx and mx < bx + nw and my >= ay and my < ay + L.rh
          U.set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, ay, nw, L.rh, 1)
          U.set(U.LINE); gfx.rect(bx, ay, nw, L.rh, 0)
          U.text(bx + L.pad, ay + 1, lab, hot and U.AMBER or (an and U.CYAN or U.GREY))
          if hot then hover.btn = 'arrname' end
          if ctx.hint then ctx.hint('mxbtn', bx, ay, nw, L.rh, 'arrname') end
          btn(bx + nw + L.pad, ay, '>', 'arrnext')
        else
          local bx = btn(ax0, ay, 'new', 'arrnew')
          bx = btn(bx, ay, 'dup', 'arrdup')
          bx = btn(bx, ay, 'clear', 'arrclear')         -- 10 окт: пустой лист (новые пустые лейны)
          bx = btn(bx, ay, 'del', 'arrdel')
          if ctx.mx_launch_on then btn(bx, ay, 'clips', 'arrclips', ctx.mx_launch_on()) end
        end
        ay = ay + L.rh + 1
      end
    end
  end
  local top = hy + L.mx_head_h
  local rh = L.mx_row_h or L.rh
  local RW = L.mx_ruler_w or 0
  local marks = info.marks or {}
  -- маркер =START строкой до первого слота, =END — после последнего (2 окт);
  -- такт маркера — поле ввода прямо на линии (5 окт): клик — набор такта
  -- (цифры, точка, Enter, Esc), колесо — ±такт, Shift+клик — строка курсора.
  -- Маркера нет — строка тусклая с «--», поле его создаст
  local function mark_row(mk, y, which)
    local c = mk.missing and U.GREY or (mk.rgb or U.CYAN)
    local ed = MX.mkedit and MX.mkedit.which == which
    local val = ed and (MX.mkedit.buf .. '_') or mk.bar
    local fw = math.max(U.measure(val), U.measure('000.0')) + 4
    local fx = L.pad
    -- 9 окт: линия — от правого края ячейки (слева её обрезок читался как «--» мимо ячейки)
    U.set(c); gfx.rect(fx + fw, y + math.floor(L.rh / 2), W - 4 - fx - fw, 1, 1)
    local lx = math.max(RW, fx + fw + L.pad) + L.pad
    local hot = mx >= fx and mx < fx + fw and my >= y and my < y + L.rh
    U.set(ed and U.BG or (hot and U.tint(U.AMBER, 0.3) or U.PANEL)); gfx.rect(fx, y, fw, L.rh, 1)
    U.set((ed or hot) and U.AMBER or U.LINE); gfx.rect(fx, y, fw, L.rh, 0)
    U.text(fx + math.floor((fw - U.measure(val)) / 2), y + 1, val, ed and U.AMBER or c)   -- значение — посередине ячейки
    if hot then hover.btn = which == 'start' and 'mkstart' or 'mkend' end
    U.set(U.PANEL); gfx.rect(lx - 2, y, U.measure(mk.name) + 4, L.rh, 1)
    U.text(lx, y + 1, mk.name, c)
  end
  local mk_start = marks.start or { name = '=START', bar = '--', missing = true }
  local mk_stop = marks.stop or { name = '=END', bar = '--', missing = true }
  mark_row(mk_start, top, 'start'); top = top + L.rh
  -- колонки по горизонтали (5 окт): сколько влезает, прокрутка MX.hs за
  -- курсором; полоса снизу, если не все
  local ncv = math.max(1, math.floor((W - 4 - L.mx_label_w) / L.mx_cell_w))
  local ncols = #snap.cols
  if MX.last_ci ~= MX.cur.ci then
    MX.last_ci = MX.cur.ci
    if MX.cur.ci - 1 < MX.hs then MX.hs = MX.cur.ci - 1 end
    if MX.cur.ci - 1 >= MX.hs + ncv then MX.hs = MX.cur.ci - ncv end
  end
  MX.hs = math.max(0, math.min(MX.hs, math.max(0, ncols - ncv)))
  local hbar_h = ncols > ncv and 5 or 0
  if hbar_h > 0 and ctx.hbar then ctx.hbar('matrixh', L.mx_label_w, ybot - 4, ncv * L.mx_cell_w, 3, MX.hs, ncv, ncols) end
  local bottom = ybot - L.rh - hbar_h
  local nvis = math.max(1, math.floor((bottom - top) / rh))
  MX.scroll = MX.scroll or 0
  -- за курсором — только когда он сдвинулся (4 окт): полосой / колесом листается
  if MX.last_ri ~= MX.cur.ri then
    MX.last_ri = MX.cur.ri
    if MX.cur.ri - 1 < MX.scroll then MX.scroll = MX.cur.ri - 1 end
    if MX.cur.ri - 1 >= MX.scroll + nvis then MX.scroll = MX.cur.ri - nvis end
  end
  MX.scroll = math.max(0, math.min(MX.scroll, math.max(0, #regions - nvis)))
  local aw = U.measure('<')
  for i = 1, nvis do
    local ri = MX.scroll + i
    local rg = regions[ri]
    if not rg then break end
    local y = top + (i - 1) * rh
    MX.row_y = MX.row_y or {}; MX.row_y[ri] = y          -- для всплывашки :name / :len у своей строки
    local playing = info.play_row and info.play_row >= rg.r0 and info.play_row < rg.r1
    local queued = MX.queued and MX.queued.idx == rg.idx and math.abs(MX.queued.pos - rg.pos) < 1e-6
    if playing then U.set(U.tint(U.AMBER, 0.22)); gfx.rect(0, y, W, rh, 1) end
    if queued then U.set(U.tint(U.CYAN, 0.30)); gfx.rect(0, y, W, rh, 1) end
    -- плейхед внутри слота (детальный зум): тонкая линия по времени
    if playing and rh > L.rh then
      local fy = y + math.floor((info.play_row - rg.r0) / math.max(1, rg.r1 - rg.r0) * rh)
      U.set(U.AMBER); gfx.rect(L.mx_label_w, fy, W - L.mx_label_w, 1, 1)
    elseif playing then
      -- 8 окт: строка в одну высоту — плейхед по горизонтали: полоса прогресса
      -- снизу и риска на месте (по клеткам паттерна, слева направо)
      local frac = (info.play_row - rg.r0) / math.max(1, rg.r1 - rg.r0)
      local x0 = L.mx_label_w
      local fx = x0 + math.floor(frac * (W - x0 - 2) + 0.5)
      U.set(U.AMBER); gfx.rect(x0, y + rh - 2, fx - x0, 2, 1); gfx.rect(fx, y + 1, 2, rh - 2, 1)
    end
    if my >= y and my < y + rh and mx < W then hover.ri = ri end
    -- цвет региона (2 окт): полоска у края и подкраска под номером и именем —
    -- тот же цвет, что на таймлайне REAPER, в уголке трекера и у номеров шагов
    if not rg.gap and info.region_rgb then
      local c = info.region_rgb(rg.color)
      if c then
        U.set(U.tint(c, 0.22)); gfx.rect(RW + 3, y + 1, L.mx_label_w - L.mx_dur_w - L.mx_sig_w - 3 - RW, L.rh - 1, 1)
        U.set(c); gfx.rect(RW + 1, y + 1, 2, rh - 1, 1)
      end
    end
    -- линейка: черта начала слота, «такт.доля», риски тактов (длинные) и долей
    if RW > 0 then
      U.set(U.LINE); gfx.rect(0, y, RW - 2, 1, 1)
      if info.bar_label then U.text(L.pad, y + 1, info.bar_label(rg.pos), U.GREY) end
      if info.ticks then
        for _, tk in ipairs(info.ticks(rg)) do
          local ty = y + math.floor(tk.f * rh)
          if tk.bar then U.set(U.TEXT); gfx.rect(RW - 8, ty, 6, 1, 1)
          elseif rh > L.rh then U.set(U.DIM); gfx.rect(RW - 5, ty, 3, 1, 1) end
        end
      end
      U.set(U.DIM); gfx.rect(RW - 2, y, 1, rh, 1)
    end
    -- «< NN >»: стрелки переключают паттерн слота
    local lc = playing and U.AMBER or (queued and U.CYAN or U.TEXT)
    local xa = RW + L.pad                              -- '<'
    local xn = xa + aw + 3                             -- номер
    local xb = xn + U.measure('00') + 3                -- '>'
    local hot_prev = hover.ri == ri and mx >= xa and mx < xn
    local hot_next = hover.ri == ri and mx >= xb and mx < xb + aw + 3
    if rg.gap then
      -- свободный такт (между регионами / до =END): без паттерна, имя → создаёт регион
      U.text(xn, y + 1, '..', U.DIM)
    else
      U.text(xa, y + 1, '<', hot_prev and U.AMBER or U.GREY)
      U.text(xn, y + 1, ('%02d'):format((info.pat_num and info.pat_num(rg) or rg.idx) % 100), U.TEXT)
      U.text(xb, y + 1, '>', hot_next and U.AMBER or U.GREY)
      if hot_prev then hover.prev = ri elseif hot_next then hover.next = ri end
    end
    -- курсор на номере (9 окт): Enter / < > — паттерн слота
    if MX.cur.ri == ri and MX.cur.ci == -1 then
      U.set(MX.focus and U.AMBER or U.LINE); gfx.rect(xa - 2, y, xb + aw + 3 - xa + 2, L.rh, 0)
    end
    if not rg.gap then
      if ctx.hint then ctx.hint('mxprev', xa, y, aw + 3, L.rh, ri); ctx.hint('mxnext', xb, y, aw + 3, L.rh, ri) end
    end
    -- имя и длина — интерактивные (1 окт): dblclick имени → :name, клик по
    -- длине → :len; hover.name / hover.dur = ri
    local nx, nw = L.mx_idx_w + 2, L.mx_label_w - L.mx_idx_w - L.mx_dur_w - L.mx_sig_w - 2 - L.pad   -- mx_idx_w уже с линейкой
    if MX.fold then nw = 0 end                         -- свёрнута: без имени и длины
    local hot_name = nw > 0 and hover.ri == ri and mx >= nx and mx < nx + nw
    if nw > 0 then
    local rgn = rg.gap and 'bar' or (rg.name ~= '' and rg.name or ('#' .. tostring(rg.idx)))
    U.text(nx, y + 1, ctx.fit(rgn, nw), hot_name and U.AMBER or (rg.gap and U.DIM or lc))
    if hot_name then hover.name = ri end
    if MX.cur.ri == ri and MX.cur.ci == 0 then U.set(MX.focus and U.AMBER or U.LINE); gfx.rect(nx - 2, y, nw + 2, L.rh, 0) end   -- курсор на имени: Enter / i — имя
    if ctx.hint then ctx.hint('mxname', nx, y, nw, L.rh, ri) end
    -- длительность: в тактах (по QN и размеру 4/4 проекта), дробь — до 0.5
    do
      -- длина в шагах по LPB (просьба 1 окт: без тактов и секунд)
      local ds = tostring(math.floor((rg.r1 - rg.r0) + 0.5))
      local dx = L.mx_label_w - L.mx_dur_w
      local hot_dur = hover.ri == ri and mx >= dx and mx < L.mx_label_w
      U.text(L.mx_label_w - L.pad - U.measure(ds), y + 1, ds, hot_dur and U.AMBER or U.GREY)
      if hot_dur then hover.dur = ri end
      if ctx.hint then ctx.hint('mxdur', dx, y, L.mx_dur_w, L.rh, ri) end
      -- размер такта в начале региона (5 окт): клик — :sig для этого паттерна
      if L.mx_sig_w > 0 and info.sig_at and not rg.gap then
        local n, d = info.sig_at(rg.pos)
        local ss = ('%d/%d'):format(n or 4, d or 4)
        local sx = dx - L.mx_sig_w
        local hot_sig = hover.ri == ri and mx >= sx and mx < dx
        U.text(dx - L.pad - U.measure(ss), y + 1, ss, hot_sig and U.AMBER or U.DIM)
        if hot_sig then hover.sig = ri end
        if ctx.hint then ctx.hint('mxsig', sx, y, L.mx_sig_w, L.rh, ri) end
      end
    end
    end
    for ci = 1, #snap.cols do
      local x = L.mx_label_w + (ci - 1 - MX.hs) * L.mx_cell_w
      if x + L.mx_cell_w > W - 4 then break end              -- узкая матрица (ширина мышью): не лезть в трекер
      if ci > MX.hs then
      local g = grid[ri][ci]
      local col = snap.cols[ci]
      U.set(U.DIM); gfx.rect(x, y, L.mx_cell_w, rh, 0)
      local iw = L.mx_cell_w - 4
      if MX.fill then
        if MX.zoom == 'detail' then
          -- время сверху вниз: items — блоки цветом item, огибающие — линии
          local ih = rh - 4
          for _, e in ipairs(g.ev) do
            local ey = y + 2 + math.floor(e.pos * ih)
            local eh = math.max(2, math.floor(e.len * ih + 0.5))
            local rgb = e.rgb or (e.kind == 'midi' and U.CYAN or U.TEXT)
            U.set(e.muted and U.mix(U.GREY, U.BG, 0.5) or U.mix(rgb, U.BG, 0.25)); gfx.rect(x + 2, ey, iw, eh, 1)
            U.set(e.muted and U.GREY or rgb); gfx.rect(x + 2, ey, iw, eh, 0)
          end
          if g.envsrc or g.envs then MX.cell_envs(g) end
          if g.envs and info.env_shown and info.env_shown(col) then
            for _, en in ipairs(g.envs) do
              local n = #en.pts
              U.set(ctx.env_colour and ctx.env_colour(en.e) or U.GREEN)
              local px, py
              for k, v in ipairs(en.pts) do
                local vx = x + 2 + math.floor(v * (iw - 1))
                local vy = y + 2 + math.floor((k - 0.5) / n * ih)
                if px then gfx.line(px, py, vx, vy) end
                px, py = vx, vy
              end
            end
          end
        else
          -- схема: четыре четверти региона сверху вниз — линия там, где есть события
          local q = { 0, 0, 0, 0 }
          for _, e in ipairs(g.ev) do
            local a, b = e.pos, e.pos + e.len
            for k = 1, 4 do
              local qa, qb = (k - 1) / 4, k / 4
              local ov = math.min(b, qb) - math.max(a, qa)
              if ov > 0 then q[k] = math.min(1, q[k] + ov * 4) end
            end
          end
          local gap = (rh - 4) / 4
          local rgb = g.ev[1] and g.ev[1].rgb or U.TEXT   -- схема в цвете первого item
          for k = 1, 4 do
            if q[k] > 0 then
              local ly = y + 2 + math.floor((k - 0.5) * gap)
              local lw = math.max(3, math.floor(q[k] * iw + 0.5))
              U.set(g.state == 'muted' and U.GREY or rgb)
              gfx.rect(x + 2 + math.floor((iw - lw) / 2), ly, lw, q[k] > 0.5 and 2 or 1, 1)
            end
          end
        end
        if g.state == 'muted' then
          U.set(U.RED); gfx.line(x + 2, y + 2, x + L.mx_cell_w - 3, y + rh - 3); gfx.line(x + 2, y + rh - 3, x + L.mx_cell_w - 3, y + 2)
        end
      end
      -- слой лупов: период лупа первого item трека в слоте (- без лупа, x заглушено)
      if MX.loops and info.loop_cells and info.loop_text then
        local lt = info.loop_text(info.loop_cells[ri] and info.loop_cells[ri][ci])
        if lt then
          local tw = U.measure(lt)
          U.set(U.PANEL); gfx.rect(x + math.floor((L.mx_cell_w - tw) / 2) - 1, y + 1, tw + 2, L.rh - 1, 1)
          U.text(x + math.floor((L.mx_cell_w - tw) / 2), y + 1, lt, U.CYAN)
        end
      end
      -- клипы (9 окт, экспериментально): клетка — клип сессии; играет —
      -- зелёная рамка и «>», ждёт границы — мигает янтарём
      if ctx.mx_clip_state and g.state ~= 'empty' then
        local cs = ctx.mx_clip_state(ri, ci)
        if cs == 'live' then
          U.set(U.GREEN); gfx.rect(x, y, L.mx_cell_w, rh, 0); gfx.rect(x + 1, y + 1, L.mx_cell_w - 2, rh - 2, 0)
          U.set(U.BG); gfx.rect(x + 2, y + 1, U.measure('>') + 2, L.rh - 2, 1)
          U.text(x + 3, y + 1, '>', U.GREEN)
        elseif cs == 'pend' and math.floor(reaper.time_precise() * 4) % 2 == 0 then
          U.set(U.AMBER); gfx.rect(x, y, L.mx_cell_w, rh, 0)
        end
      end
      if MX.anchor then
        local r0, r1, c0, c1 = MX.block()
        if ri >= r0 and ri <= r1 and ci >= c0 and ci <= c1 then U.set(U.AMBER); gfx.a = 0.22; gfx.rect(x, y, L.mx_cell_w, rh, 1); gfx.a = 1 end
      end
      if MX.picks[ri .. ':' .. ci] then U.set(U.AMBER); gfx.a = 0.22; gfx.rect(x, y, L.mx_cell_w, rh, 1); gfx.a = 1; gfx.rect(x, y, L.mx_cell_w, rh, 0) end
      if MX.cur.ri == ri and MX.cur.ci == ci then
        U.set(MX.focus and U.AMBER or U.LINE); gfx.rect(x, y, L.mx_cell_w, rh, 0)
        gfx.rect(x + 1, y + 1, L.mx_cell_w - 2, rh - 2, 0)
      end
      if hover.ri == ri and mx >= x and mx < x + L.mx_cell_w then
        hover.ci = ci
        if my - y <= 2 then hover.cellrep = { ri = ri, ci = ci, edge = 'top', x = x }
        elseif y + rh - 1 - my <= 2 then hover.cellrep = { ri = ri, ci = ci, edge = 'bottom', x = x } end
      end
      if ctx.hint then ctx.hint('mx', x, y, L.mx_cell_w, rh, { ri = ri, ci = ci }) end
      end
    end
  end
  -- 9 окт, как в Renoise: край клетки (верх / низ, 3 px) — потянуть, и клетка
  -- повторится в следующих слотах (алиасы; Option — уникальные копии)
  do
    local e = hover.cellrep
    if e and MX.row_y[e.ri] then
      local ey = MX.row_y[e.ri] + (e.edge == 'top' and 0 or rh - 2)
      U.set(U.AMBER); gfx.rect(e.x, ey, L.mx_cell_w, 2, 1)
    end
  end
  do
    local last = math.min(#regions, MX.scroll + nvis)
    local ye = top + (last - MX.scroll) * rh
    if last == #regions and ye + L.rh <= ybot then mark_row(mk_stop, ye, 'end') end
  end
  if ctx.vbar then ctx.vbar('matrix', W - 5, top, 3, nvis * rh, MX.scroll, nvis, #regions) end   -- поверх строк
  return hover
end

-- ── навигация и действия ──────────────────────────────────────────────────
local function clamp(regions, ncols)
  if MX.cur.ri < 1 then MX.cur.ri = 1 elseif MX.cur.ri > #regions then MX.cur.ri = math.max(1, #regions) end
  -- 9 окт: левее треков — имя региона (ci 0) и номер «< NN >» (ci −1)
  if MX.cur.ci < -1 then MX.cur.ci = -1 elseif MX.cur.ci > ncols then MX.cur.ci = math.max(1, ncols) end
end

-- Живая матрица: движение курсора ведёт edit-курсор REAPER к региону
-- (когда проект стоит); во время воспроизведения Space ставит регион в
-- ОЧЕРЕДЬ — прыжок случится на границе текущего региона (main обрабатывает
-- MX.queued в кадре). Так edit-курсор и плейхед живут отдельно.
MX.queued = nil

function MX.goto_cell(regions, snap, ri, ci)
  if ci == 0 and MX.fold then ci = MX.cur.ci > 0 and -1 or 1 end   -- свёрнута: имени нет — через него
  MX.cur.ri, MX.cur.ci = ri, ci
  clamp(regions, #snap.cols)
  local rg = regions[MX.cur.ri]
  if rg then ctx.scroll_to(rg.r0, math.max(1, MX.cur.ci)); ctx.region_cursor(rg) end
end

function MX.space(regions)
  local rg = regions[MX.cur.ri]
  if rg then ctx.region_space(rg) end
end

function MX.toggle_mute(regions, snap)
  local rg = regions[MX.cur.ri]
  local col = snap.cols[MX.cur.ci]
  if rg and col then ctx.edit.mute_span(col.track, rg.pos, rg.rgnend, nil) end
end

-- клавиши в фокусе матрицы; возвращает true, если съедена.
-- Vim-раскладка слотов (2 окт): слот = строка матрицы (регион или свободный такт).
--   o O       новый пустой такт после / перед      dd   удалить слот (в регистр)
--   yy Y      взять слот в регистр                  p P  вставить после / перед
--   A         alias — связанный повтор (пул MIDI + группа)   C D ^D  clone — копия без связи, новое имя
--   U         make unique — отвязать повтор (новое имя, свой пул, без группы)
--   x         вырезать ячейку / блок
--   n cc cw r i  имя    =  длина    [ ] ± такт   { } ± шаг    < > паттерн слота
--   m Enter mute   Space очередь / play   + регион в конце (N+ — N штук)   u ^R undo / redo
-- В блоке (v / Shift+hjkl): y копия, d x вырезать, m (Ctrl+N) mute.
MX.pending = nil
local MX_HINT = {
  d = 'd: d delete slot (to register) | Esc',
  y = 'y: y yank slot | Esc',
  c = 'c: c / w rename region | Esc',
  g = 'g: g first slot | Esc',
  z = 'z: z session - clips over the whole window | i zoom detail | Esc',
}
function MX.pending_hint() return MX.pending and MX_HINT[MX.pending] or nil end
local OPS = { d = true, y = true, g = true, z = true }

function MX.key(c, regions, snap)
  local ch = c < 256 and string.char(c) or ''
  local mods = ctx.mods and ctx.mods() or {}
  -- оператор ждёт второй клавиши: dd yy cc cw gg
  if MX.pending then
    local op = MX.pending
    MX.pending = nil
    if c == 27 then return true end
    local pcount = MX.pcount; MX.pcount = nil
    if op == 'd' and ch == 'd' then ctx.slot_delete(pcount)
    elseif op == 'y' and ch == 'y' then ctx.slot_yank()
    elseif op == 'y' and ch == 'p' then ctx.slot_new('clone')        -- yp — дубль (5 окт: одна клавиша на функцию)
    elseif op == 'g' and ch == 'g' then MX.goto_cell(regions, snap, 1, MX.cur.ci)
    elseif op == 'z' and ch == 'z' then if ctx.ss_big then ctx.ss_big() end   -- session (6 окт)
    elseif op == 'z' and ch == 'i' then MX.toggle_zoom()
    else ctx.msg(op .. ch .. ': not a matrix command (? - help)') end
    return true
  end
  -- блок: Shift+hjkl (H J K L) тянет от якоря, v — якорь/снять, Esc — снять
  if ch == 'H' or ch == 'J' or ch == 'K' or ch == 'L' then
    if not MX.anchor then MX.anchor = { ri = MX.cur.ri, ci = MX.cur.ci } end
    local dx, dy = 0, 0
    if ch == 'H' then dx = -1 elseif ch == 'L' then dx = 1 elseif ch == 'J' then dy = 1 else dy = -1 end
    MX.goto_cell(regions, snap, MX.cur.ri + dy, MX.cur.ci + dx); return true
  end
  if ch == 'v' then if MX.anchor then MX.anchor = nil else MX.anchor = { ri = MX.cur.ri, ci = MX.cur.ci } end; return true end
  if c == 27 and (MX.anchor or next(MX.picks)) then MX.anchor = nil; MX.picks = {}; return true end
  -- в блоке y / d / x действуют на ячейки блока
  if MX.anchor and ch == 'y' then ctx.mx_block('copy'); return true end
  if MX.anchor and (ch == 'd' or ch == 'x') then ctx.mx_block('cut'); return true end
  if MX.anchor and ch == 'M' then ctx.mx_block('mute'); return true end
  -- Ctrl+N mute блока, Ctrl+X / Cmd+Backspace вырезать, Ctrl+C копия, Ctrl+V вставка, Ctrl+D дубль
  if c == 14 then ctx.mx_block('mute'); return true end
  if c == 24 or (c == 8 and mods.cmd) then ctx.mx_block('cut'); return true end
  if c == 3 then ctx.mx_block('copy'); return true end
  if c == 22 then ctx.mx_block('paste'); return true end
  if c == 18 then ctx.edit.redo(); ctx.mx_refresh(); return true end
  -- Ctrl+hjkl приходят кодами 8/10/11/12 — те же движения
  if mods.ctrl and (c == 8 or c == 10 or c == 11 or c == 12) then
    local dx, dy = 0, 0
    if c == 8 then dx = -1 elseif c == 12 then dx = 1 elseif c == 10 then dy = 1 else dy = -1 end
    MX.goto_cell(regions, snap, MX.cur.ri + dy, MX.cur.ci + dx); return true
  end
  -- 10 окт: D / Backspace / Del — на номере или имени слота удалить слот, на
  -- ячейке вырезать её (раньше Backspace уходил в трекер и удалял там строку)
  if ch == 'D' or ((c == 8 or c == 6579564) and not mods.ctrl) then
    if MX.cur.ci < 1 then ctx.slot_delete() else ctx.mx_block('cut') end
    return true
  end
  -- 10 окт: w / b — следующий / предыдущий слот с паттерном (пустые такты ..
  -- мимо), e — последний такт этого слота; 0 ^ $ — первая / последняя колонка
  if (ch == 'w' or ch == 'b' or ch == 'e') and not MX.count then
    local d = ch == 'b' and -1 or 1
    local ri = MX.cur.ri
    if ch == 'e' then
      while regions[ri + 1] and regions[ri + 1].gap do ri = ri + 1 end
    else
      ri = ri + d
      while regions[ri] and regions[ri].gap do ri = ri + d end
    end
    if regions[ri] then MX.goto_cell(regions, snap, ri, MX.cur.ci) else ctx.msg(ch == 'b' and 'no slot above' or 'no slot below') end
    return true
  end
  if (ch == '0' and not MX.count) or ch == '^' then MX.goto_cell(regions, snap, MX.cur.ri, MX.fold and -1 or 0); return true end
  if ch == '$' then MX.goto_cell(regions, snap, MX.cur.ri, #snap.cols); return true end
  -- 9 окт: курсор на имени (ci 0) — Enter / i / r переименовать; на номере
  -- (ci −1) — Enter: номер паттерна цифрами (10 окт; < > — листать)
  if MX.cur.ci == 0 and (c == 13 or ch == 'i' or ch == 'r') then ctx.mx_name_prompt(); return true end
  if MX.cur.ci == -1 and c == 13 then if ctx.slot_pat_prompt then ctx.slot_pat_prompt() else ctx.slot_cycle(MX.cur.ri, 1) end; return true end
  if MX.cur.ci < 1 and (ch == 'm' or ch == 'M' or ch == 'x' or c == 22 or c == 3 or c == 24) then ctx.msg('on the region name / number - move to a track cell (l)'); return true end
  -- слой лупов: цифры+Enter, > < + - = — лупы ячейки (вместо паттерна / длины)
  if MX.loops and ctx.mx_loop_key and ctx.mx_loop_key(c) then return true end
  -- счётчик (2 окт): 4+ — четыре региона одним шагом
  if ch:match('^%d$') and (MX.count or ch ~= '0') then
    MX.count = math.min(64, (MX.count or 0) * 10 + tonumber(ch)); ctx.msg(MX.count .. ' (+ regions)'); return true
  end
  local count = MX.count
  MX.count = nil
  if OPS[ch] then MX.pending, MX.pcount = ch, count; ctx.msg((count and (count .. ' ') or '') .. ch .. '...'); return true end   -- 10 окт: счётчик доживает до второй клавиши (5dd)
  -- Ctrl+Up / Ctrl+Down (9 окт, как Paketti в Renoise): дубль слота выше / ниже,
  -- в копии заглушённые треки пустые
  if mods.ctrl and (c == 30064 or c == 1685026670) then ctx.slot_new('clone_nomute', c == 30064); return true end
  if ch == 'j' or c == 1685026670 then MX.goto_cell(regions, snap, MX.cur.ri + 1, MX.cur.ci)
  elseif ch == 'k' or c == 30064 then MX.goto_cell(regions, snap, MX.cur.ri - 1, MX.cur.ci)
  elseif ch == 'h' or c == 1818584692 then MX.goto_cell(regions, snap, MX.cur.ri, MX.cur.ci - 1)
  elseif ch == 'l' or c == 1919379572 then MX.goto_cell(regions, snap, MX.cur.ri, MX.cur.ci + 1)
  elseif ch == 'G' then MX.goto_cell(regions, snap, #regions, MX.cur.ci)
  elseif ch == 'M' then MX.toggle_mute(regions, snap)                -- mute — Shift+m, как в трекере (3 окт)
  elseif ch == 'f' then MX.fill = not MX.fill
  elseif ch == 'F' then if ctx.mx_zoom_cycle then ctx.mx_zoom_cycle() end   -- 9 окт: F — sel (fold убран)
  elseif ch == 'R' then ctx.mx_ruler_toggle()
  elseif ch == 't' then if ctx.mx_trim then ctx.mx_trim() end
  elseif ch == '+' then ctx.mx_add(nil, nil, count)
  elseif ch == 'o' then ctx.slot_new('empty', false)
  elseif ch == 'O' then ctx.slot_new('empty', true)
  elseif ch == 'p' then ctx.slot_new('put', false)
  elseif ch == 'P' then ctx.slot_new('put', true)
  elseif ch == 'A' then ctx.slot_new('alias')                       -- alias: связанный повтор
  elseif ch == 'U' then if ctx.slot_unique then ctx.slot_unique() end   -- make unique
  elseif ch == 'x' then ctx.mx_block('cut')
  elseif ch == 'n' then ctx.mx_name_prompt()
  elseif ch == '=' then ctx.mx_len_prompt()
  elseif ch == ']' then ctx.slot_len_step('bar', 1)
  elseif ch == '[' then ctx.slot_len_step('bar', -1)
  elseif ch == '}' then ctx.slot_len_step('step', 1)
  elseif ch == '{' then ctx.slot_len_step('step', -1)
  elseif ch == '<' then ctx.slot_cycle(MX.cur.ri, -1)
  elseif ch == '>' then ctx.slot_cycle(MX.cur.ri, 1)
  elseif ch == 'u' then ctx.edit.undo(); ctx.mx_refresh()
  elseif c == 9 or c == 27 then ctx.toggle_focus()
  elseif ch == ' ' then MX.space(regions)
  else return false end
  return true
end

return MX
