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
function MX.block()
  local a = MX.anchor or MX.cur
  return math.min(a.ri, MX.cur.ri), math.max(a.ri, MX.cur.ri), math.min(a.ci, MX.cur.ci), math.max(a.ci, MX.cur.ci)
end

function MX.init(u, c) U, ctx = u, c end

-- ── состояние ячеек ───────────────────────────────────────────────────────
-- grid[ri][ci] = { state = 'empty'|'has'|'muted', cov = доля строк региона
-- под событиями, ev = { {pos=0..1, len=0..1, kind, muted} … } } — для двух
-- зумов: схема (полоска загруженности) и микровид (события по позициям).
local cache = { snap = nil, regs = nil, grid = nil }
MX.zoom = 'schematic'       -- 'schematic' | 'detail'; `:mxzoom`, в матрице z

local BTNS = { { 'fold', 'fold' }, { 'zoom', 'zoom' }, { 'fill', 'fill' }, { 'sync', 'sync' }, { 'trim', 'trim' }, { 'ruler', 'ruler' }, { 'loops', 'loops' }, { 'add', '+' } }
local FOLD_BTNS = { { 'fold', 'fold' } }        -- свёрнутая: одна кнопка — развернуть
MX.loops = false         -- слой лупов (бывший Garden, 2 окт): период лупа в ячейках, клавиши лупов
MX.ruler = true          -- вертикальная линейка тактов слева (кнопка ruler, R)
MX.fold = false          -- свёрнутая матрица (3 окт): номера, имена треков, ячейки — без имён / длин / линейки (кнопка fold, F)
MX.ENV_PTS = 12          -- отсчётов огибающей на ячейку в детальном зуме

function MX.grid(snap, regions)
  if cache.snap == snap and cache.regs == regions then return cache.grid end
  local grid = {}
  local rgb_of = {}        -- item → цвет (один вызов на item)
  local model = ctx and ctx.model
  for ri, rg in ipairs(regions) do
    local row = {}
    local span = math.max(1, rg.r1 - rg.r0)
    for ci, col in ipairs(snap.cols) do
      local has, all_muted, covered, ev = false, true, 0, {}
      for _, lane in ipairs(col.lanes) do
        for _, sub in ipairs(lane.subs) do
          for r, cell in pairs(sub) do
            if cell.kind == 'audio' or cell.kind == 'midi' then
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
                ev[#ev + 1] = { pos = (a - rg.r0) / span, len = (b - a) / span, kind = cell.kind, muted = cell.muted, rgb = rgb or col.rgb }
              end
            end
          end
        end
      end
      -- мини-автоматизация: отсчёты каждой огибающей трека на длине региона
      local envs
      if model and model.env_samples and col.envs and #col.envs > 0 then
        envs = {}
        for _, e in ipairs(col.envs) do
          envs[#envs + 1] = { e = e, pts = model.env_samples(e, rg.pos, rg.rgnend, MX.ENV_PTS) }
        end
      end
      row[ci] = { state = has and (all_muted and 'muted' or 'has') or 'empty', cov = math.min(1, covered / span), ev = ev, envs = envs }
    end
    grid[ri] = row
  end
  cache.snap, cache.regs, cache.grid = snap, regions, grid
  return grid
end

-- ── раскладка ─────────────────────────────────────────────────────────────
MX.fill = true          -- схематичное заполнение ячеек (кнопка «fill»)
MX.name_h = 0

-- ДЕТАЛЬНЫЙ ЗУМ — ПО ВЕРТИКАЛИ (решение пользователя 1 окт): ряд слота в
-- MX.DETAIL_ROWS раз выше, ширина почти та же; время в ячейке идёт сверху
-- вниз, как в трекере: items — цветными блоками, огибающие — линиями.
MX.DETAIL_ROWS = 4

function MX.width(L, nregions, ncols)
  -- «< NN >»: стрелки и номер не налезают — ширина из частей с зазорами
  L.mx_arrow_w = U.measure('<')
  -- линейка слева (2 окт): «такт.доля» начала слота, риски тактов и долей
  L.mx_ruler_w = (MX.ruler and not MX.fold) and (U.measure('999.9') + 2 * L.pad + 4) or 0
  L.mx_idx_w = L.mx_ruler_w + L.pad + 2 * (L.mx_arrow_w + 3) + U.measure('00') + L.pad
  L.mx_dur_w = MX.fold and 0 or (U.measure('9999') + L.pad)          -- колонка длины региона в шагах
  L.mx_label_w = MX.fold and L.mx_idx_w or (L.mx_idx_w + U.measure('WWWWWW') + L.pad + L.mx_dur_w)
  L.mx_cell_w = (MX.zoom == 'detail' and L.cw * 3 or L.cw * 2) + 2 * L.pad
  L.mx_row_h = MX.zoom == 'detail' and L.rh * MX.DETAIL_ROWS or L.rh
  -- кнопки шапки не выходят за рамку модуля: ширина — не меньше ряда кнопок
  local bw = L.pad
  for _, b in ipairs(MX.fold and FOLD_BTNS or BTNS) do
    local label = b[2]
    if b[1] == 'zoom' then label = 'zoom' elseif b[1] == 'fill' then label = 'grid' end
    if ctx and ctx.ic then label = ctx.ic(b[1], label) end
    bw = bw + U.measure(label) + 2 * L.pad + L.pad
  end
  MX.btns_w = bw
  -- шапка матрицы: вертикальные имена треков (до 10 букв) + полоса кнопок
  MX.name_h = L.cw * 12 + 4
  L.mx_head_h = L.rh + 2 + MX.name_h + 4
  -- справа — колонка кнопок < > = у линии раздела: ячейки под неё не уходят
  local knob_w = U.measure('>') + 2 * L.pad + 6
  return math.max(L.mx_label_w + ncols * L.mx_cell_w + L.pad + knob_w, MX.btns_w + L.pad)
end

-- ── отрисовка ─────────────────────────────────────────────────────────────
-- Панель ниже верхней полосы. Сверху — кнопки (zoom / fill / lib), под ними
-- имена треков вертикально, затем строки-слоты: «< NN > имя» и ячейки.
-- Ячейка: схема — горизонтальные линии по четвертям региона (где есть
-- события), микровид — штрихи по позициям; заглушено — X поверх.
-- Возвращает hover = { ri=, ci=, prev=, next=, btn= }.

function MX.draw(L, snap, regions, info)
  -- пустой проект (нет регионов) — матрица всё равно видна: кнопки, + (2 окт)
  local grid = MX.grid(snap, regions)
  local W = L.matrix_w
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover = {}
  local hy = L.header_y
  U.set(U.PANEL); gfx.rect(0, hy, W, L.body_y + L.body_h - hy, 1)
  -- кнопки
  local bx = L.pad
  for _, b in ipairs(MX.fold and FOLD_BTNS or BTNS) do
    local label = b[2]
    if b[1] == 'zoom' then label = 'zoom' end
    if b[1] == 'fill' then label = MX.fill and 'fill' or 'grid' end
    if ctx.ic then label = ctx.ic(b[1], label) end
    local bw = U.measure(label) + 2 * L.pad
    local hot = mx >= bx and mx < bx + bw and my >= hy + 1 and my < hy + L.rh + 1
    U.set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, hy + 1, bw, L.rh, 1)
    U.set(U.LINE); gfx.rect(bx, hy + 1, bw, L.rh, 0)
    U.text(bx + L.pad, hy + 2, label, hot and U.AMBER or (((b[1] == 'ruler' and MX.ruler) or (b[1] == 'loops' and MX.loops) or (b[1] == 'fold' and MX.fold)) and U.CYAN or U.TEXT))
    if hot then hover.btn = b[1] end
    if ctx.hint then ctx.hint('mxbtn', bx, hy + 1, bw, L.rh, b[1]) end
    bx = bx + bw + L.pad
  end
  -- вертикальные имена треков
  local ny = hy + L.rh + 3
  for ci, col in ipairs(snap.cols) do
    local x = L.mx_label_w + (ci - 1) * L.mx_cell_w
    if x + L.mx_cell_w > W - 4 then break end
    local is_cur = (info.cur_ci == ci)
    ctx.vtext(x + (L.mx_cell_w - L.th) / 2, ny, MX.name_h - 2, col.name ~= '' and col.name or tostring(ci),
      is_cur and U.AMBER or U.TEXT, U.PANEL)
    if col.rgb then U.set(col.rgb); gfx.rect(x + 1, ny + MX.name_h, L.mx_cell_w - 2, 2, 1) end
  end
  local top = hy + L.mx_head_h
  local rh = L.mx_row_h or L.rh
  local RW = L.mx_ruler_w or 0
  local marks = info.marks or {}
  -- маркер =START строкой до первого слота, =END — после последнего (2 окт)
  local function mark_row(mk, y)
    local c = mk.rgb or U.CYAN
    U.set(c); gfx.rect(0, y + math.floor(L.rh / 2), W - 4, 1, 1)
    if RW > 0 then
      U.set(U.PANEL); gfx.rect(L.pad, y, U.measure(mk.bar) + 2, L.rh, 1)
      U.text(L.pad + 1, y + 1, mk.bar, c)
    end
    local lx = RW + L.pad
    U.set(U.PANEL); gfx.rect(lx - 2, y, U.measure(mk.name) + 4, L.rh, 1)
    U.text(lx, y + 1, mk.name, c)
  end
  if marks.start then mark_row(marks.start, top); top = top + L.rh end
  local bottom = L.body_y + L.body_h - (marks.stop and L.rh or 0)
  local nvis = math.max(1, math.floor((bottom - top) / rh))
  MX.scroll = MX.scroll or 0
  if MX.cur.ri - 1 < MX.scroll then MX.scroll = MX.cur.ri - 1 end
  if MX.cur.ri - 1 >= MX.scroll + nvis then MX.scroll = MX.cur.ri - nvis end
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
    end
    if my >= y and my < y + rh and mx < W then hover.ri = ri end
    -- цвет региона (2 окт): полоска у края и подкраска под номером и именем —
    -- тот же цвет, что на таймлайне REAPER, в уголке трекера и у номеров шагов
    if not rg.gap and info.region_rgb then
      local c = info.region_rgb(rg.color)
      if c then
        U.set(U.tint(c, 0.22)); gfx.rect(RW + 3, y + 1, L.mx_label_w - L.mx_dur_w - 3 - RW, L.rh - 1, 1)
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
      if ctx.hint then ctx.hint('mxprev', xa, y, aw + 3, L.rh, ri); ctx.hint('mxnext', xb, y, aw + 3, L.rh, ri) end
    end
    -- имя и длина — интерактивные (1 окт): dblclick имени → :name, клик по
    -- длине → :len; hover.name / hover.dur = ri
    local nx, nw = L.mx_idx_w + 2, L.mx_label_w - L.mx_idx_w - L.mx_dur_w - 2 - L.pad   -- mx_idx_w уже с линейкой
    if MX.fold then nw = 0 end                         -- свёрнута: без имени и длины
    local hot_name = nw > 0 and hover.ri == ri and mx >= nx and mx < nx + nw
    if nw > 0 then
    U.text(nx, y + 1, ctx.fit(rg.gap and 'bar' or (rg.name ~= '' and rg.name or ('#' .. tostring(rg.idx))), nw), hot_name and U.AMBER or (rg.gap and U.DIM or lc))
    if hot_name then hover.name = ri end
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
    end
    end
    for ci = 1, #snap.cols do
      local x = L.mx_label_w + (ci - 1) * L.mx_cell_w
      if x + L.mx_cell_w > W - 4 then break end              -- узкая матрица (ширина мышью): не лезть в трекер
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
      if MX.anchor then
        local r0, r1, c0, c1 = MX.block()
        if ri >= r0 and ri <= r1 and ci >= c0 and ci <= c1 then U.set(U.AMBER); gfx.a = 0.22; gfx.rect(x, y, L.mx_cell_w, rh, 1); gfx.a = 1 end
      end
      if MX.cur.ri == ri and MX.cur.ci == ci then
        U.set(MX.focus and U.AMBER or U.LINE); gfx.rect(x, y, L.mx_cell_w, rh, 0)
        gfx.rect(x + 1, y + 1, L.mx_cell_w - 2, rh - 2, 0)
      end
      if hover.ri == ri and mx >= x and mx < x + L.mx_cell_w then hover.ci = ci end
      if ctx.hint then ctx.hint('mx', x, y, L.mx_cell_w, rh, { ri = ri, ci = ci }) end
    end
  end
  if marks.stop then
    local last = math.min(#regions, MX.scroll + nvis)
    local ye = top + (last - MX.scroll) * rh
    if last == #regions and ye + L.rh <= L.body_y + L.body_h then mark_row(marks.stop, ye) end
  end
  return hover
end

-- ── навигация и действия ──────────────────────────────────────────────────
local function clamp(regions, ncols)
  if MX.cur.ri < 1 then MX.cur.ri = 1 elseif MX.cur.ri > #regions then MX.cur.ri = math.max(1, #regions) end
  if MX.cur.ci < 1 then MX.cur.ci = 1 elseif MX.cur.ci > ncols then MX.cur.ci = math.max(1, ncols) end
end

-- Живая матрица: движение курсора ведёт edit-курсор REAPER к региону
-- (когда проект стоит); во время воспроизведения Space ставит регион в
-- ОЧЕРЕДЬ — прыжок случится на границе текущего региона (main обрабатывает
-- MX.queued в кадре). Так edit-курсор и плейхед живут отдельно.
MX.queued = nil

function MX.goto_cell(regions, snap, ri, ci)
  MX.cur.ri, MX.cur.ci = ri, ci
  clamp(regions, #snap.cols)
  local rg = regions[MX.cur.ri]
  if rg then ctx.scroll_to(rg.r0, MX.cur.ci); ctx.region_cursor(rg) end
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
}
function MX.pending_hint() return MX.pending and MX_HINT[MX.pending] or nil end
local OPS = { d = true, y = true, c = true, g = true }

function MX.key(c, regions, snap)
  local ch = c < 256 and string.char(c) or ''
  local mods = ctx.mods and ctx.mods() or {}
  -- оператор ждёт второй клавиши: dd yy cc cw gg
  if MX.pending then
    local op = MX.pending
    MX.pending = nil
    if c == 27 then return true end
    if op == 'd' and ch == 'd' then ctx.slot_delete()
    elseif op == 'y' and ch == 'y' then ctx.slot_yank()
    elseif op == 'c' and (ch == 'c' or ch == 'w') then ctx.mx_name_prompt()
    elseif op == 'g' and ch == 'g' then MX.goto_cell(regions, snap, 1, MX.cur.ci)
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
  if c == 27 and MX.anchor then MX.anchor = nil; return true end
  -- в блоке y / d / x действуют на ячейки блока
  if MX.anchor and ch == 'y' then ctx.mx_block('copy'); return true end
  if MX.anchor and (ch == 'd' or ch == 'x') then ctx.mx_block('cut'); return true end
  if MX.anchor and ch == 'm' then ctx.mx_block('mute'); return true end
  -- Ctrl+N mute блока, Ctrl+X / Cmd+Backspace вырезать, Ctrl+C копия, Ctrl+V вставка, Ctrl+D дубль
  if c == 14 then ctx.mx_block('mute'); return true end
  if c == 24 or (c == 8 and mods.cmd) then ctx.mx_block('cut'); return true end
  if c == 3 then ctx.mx_block('copy'); return true end
  if c == 22 then ctx.mx_block('paste'); return true end
  if c == 4 then ctx.slot_new('clone'); return true end
  if c == 18 then ctx.edit.redo(); ctx.mx_refresh(); return true end
  -- Ctrl+hjkl приходят кодами 8/10/11/12 — те же движения
  if mods.ctrl and (c == 8 or c == 10 or c == 11 or c == 12) then
    local dx, dy = 0, 0
    if c == 8 then dx = -1 elseif c == 12 then dx = 1 elseif c == 10 then dy = 1 else dy = -1 end
    MX.goto_cell(regions, snap, MX.cur.ri + dy, MX.cur.ci + dx); return true
  end
  -- слой лупов: цифры+Enter, > < + - = — лупы ячейки (вместо паттерна / длины)
  if MX.loops and ctx.mx_loop_key and ctx.mx_loop_key(c) then return true end
  -- счётчик (2 окт): 4+ — четыре региона одним шагом
  if ch:match('^%d$') and (MX.count or ch ~= '0') then
    MX.count = math.min(64, (MX.count or 0) * 10 + tonumber(ch)); ctx.msg(MX.count .. ' (+ regions)'); return true
  end
  local count = MX.count
  MX.count = nil
  if OPS[ch] then MX.pending = ch; ctx.msg(ch .. '...'); return true end
  if ch == 'j' or c == 1685026670 then MX.goto_cell(regions, snap, MX.cur.ri + 1, MX.cur.ci)
  elseif ch == 'k' or c == 30064 then MX.goto_cell(regions, snap, MX.cur.ri - 1, MX.cur.ci)
  elseif ch == 'h' or c == 1818584692 then MX.goto_cell(regions, snap, MX.cur.ri, MX.cur.ci - 1)
  elseif ch == 'l' or c == 1919379572 then MX.goto_cell(regions, snap, MX.cur.ri, MX.cur.ci + 1)
  elseif ch == 'G' then MX.goto_cell(regions, snap, #regions, MX.cur.ci)
  elseif ch == 'm' or c == 13 then MX.toggle_mute(regions, snap)
  elseif ch == 'z' then MX.zoom = MX.zoom == 'detail' and 'schematic' or 'detail'
  elseif ch == 'f' then MX.fill = not MX.fill
  elseif ch == 'F' then if ctx.mx_fold_toggle then ctx.mx_fold_toggle() else MX.fold = not MX.fold end
  elseif ch == 'R' then ctx.mx_ruler_toggle()
  elseif ch == 't' then if ctx.mx_trim then ctx.mx_trim() end
  elseif ch == '+' then ctx.mx_add(nil, nil, count)
  elseif ch == 'o' then ctx.slot_new('empty', false)
  elseif ch == 'O' then ctx.slot_new('empty', true)
  elseif ch == 'p' then ctx.slot_new('put', false)
  elseif ch == 'P' then ctx.slot_new('put', true)
  elseif ch == 'D' or ch == 'C' then ctx.slot_new('clone')         -- clone: независимая копия (как Duplicate / Clone в Renoise)
  elseif ch == 'A' then ctx.slot_new('alias')                       -- alias: связанный повтор
  elseif ch == 'U' then if ctx.slot_unique then ctx.slot_unique() end   -- make unique
  elseif ch == 'Y' then ctx.slot_yank()
  elseif ch == 'x' then ctx.mx_block('cut')
  elseif ch == 'n' or ch == 'r' or ch == 'i' then ctx.mx_name_prompt()
  elseif ch == '=' then ctx.mx_len_prompt()
  elseif ch == ']' then ctx.slot_len_step('bar', 1)
  elseif ch == '[' then ctx.slot_len_step('bar', -1)
  elseif ch == '}' then ctx.slot_len_step('step', 1)
  elseif ch == '{' then ctx.slot_len_step('step', -1)
  elseif ch == '<' or ch == ',' then ctx.slot_cycle(MX.cur.ri, -1)
  elseif ch == '>' or ch == '.' then ctx.slot_cycle(MX.cur.ri, 1)
  elseif ch == 'u' then ctx.edit.undo(); ctx.mx_refresh()
  elseif c == 9 or c == 27 then ctx.toggle_focus()
  elseif ch == ' ' then MX.space(regions)
  else return false end
  return true
end

return MX
