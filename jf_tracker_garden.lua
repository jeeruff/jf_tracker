-- jf_tracker_garden.lua — вкладка Garden (F2, 2 окт): нелинейность внутри
-- линейного REAPER. Две страницы:
--   grid — строки = последовательность (регионы и свободные такты от
--          =START до =END), колонки = треки; ячейка = период лупа первого
--          item трека в регионе (шагов), '-' item без лупа, '.' пусто, 'x'
--          всё заглушено, '*' сюда сажает Orca. Клавиши: hjkl, цифры+Enter =
--          луп N шагов, > item до конца региона, < регион до конца item,
--          + - период по лестнице, m mute, Enter/Space очередь региона,
--          o поле Orca, O Orca вкл/выкл, p закрепить посаженное, x снести.
--   orca — поле букв (jf_tracker_orca.lua): стрелки / Ctrl+hjkl курсор,
--          любой символ ставится, . или BS стирает, ! = *, Space play/stop,
--          Esc → grid. Подсветка: сработавшие — янтарные, строчные — серые.
-- Без reaper.*: данные через ctx (garden_loop / garden_fit / garden_mute /
-- region_space / garden_cmd / garden_field / garden_save).

-- 2 окт: сетка лупов переехала в матрицу (слой «loops»), вкладка — только поле
-- Orca (подпись «orca»); страница grid осталась для совместимости
local GD = { cur = { ri = 1, ci = 1 }, scroll = 0, page = 'orca', numbuf = nil, ocur = { x = 0, y = 0 }, oscroll = 0, glow = {} }
local U, ctx
local LADDER = { 1, 2, 3, 4, 6, 8, 12, 16, 24, 32 }

function GD.init(u, c) U, ctx = u, c end

-- ячейки: первый item трека в строке последовательности
function GD.cells(snap, seq, targets)
  local grid = {}
  for ri, rg in ipairs(seq) do
    local row = {}
    for ci, col in ipairs(snap.cols) do
      local first, all_muted, any = nil, true, false
      for _, lane in ipairs(col.lanes or {}) do
        for _, it in ipairs(lane.items or {}) do
          if it.r0 >= rg.r0 - 1e-6 and it.r0 < rg.r1 - 1e-6 then
            any = true
            if not it.muted then all_muted = false end
            if not first or it.r0 < first.r0 then first = it end
          end
        end
      end
      row[ci] = { has = any, per = first and first.loop_rows, item = first and first.item, muted = any and all_muted,
                  orca = targets and targets[ci] or false }
    end
    grid[ri] = row
  end
  return grid
end

-- клавиши лупов из матрицы (слой loops): цифры, Enter (с числом), > < + - =
-- на ячейке (ri, ci) матрицы; true — съедено
function GD.loop_key(c, snap, seq, ri, ci)
  local ch = c < 256 and string.char(c) or ''
  if not (ch:match('^%d$') or ch == '>' or ch == '<' or ch == '+' or ch == '-' or ch == '=' or (c == 13 and GD.numbuf)) then return false end
  GD.cur.ri, GD.cur.ci = ri, ci
  local page = GD.page
  GD.page = 'grid'
  local r = GD.key(c, snap, seq)
  GD.page = page
  return r
end
function GD.cell_text(g) return g and (g.muted and 'x' or (g.per and tostring(math.min(99, math.floor(g.per + 0.5))) or (g.has and '-' or nil))) or nil end

local function cell_text(g)
  if g.muted then return 'x' end
  if g.per then local n = math.floor(g.per + 0.5); return n >= 100 and '99' or tostring(n) end
  if g.has then return '-' end
  return '.'
end

-- ── отрисовка ─────────────────────────────────────────────────────────────
function GD.draw(L, x, y, w, h, snap, seq, info, focused)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover
  local f = ctx.garden_field()
  local on = f and f.on and info.garden_on
  GD.page = 'orca'                  -- Garden больше нет (3 окт): вкладка — только поле Orca; лупы — слой матрицы
  local head = ('orca %s  frame %d'):format(on and 'on' or 'off', f and f.frame or 0)
  if GD.numbuf then head = head .. '  loop ' .. GD.numbuf .. '_' end
  U.text(x, y, ctx.fit(head, w), on and U.AMBER or U.GREY)
  local top = y + L.rh + 2
  if GD.page == 'orca' and f then return GD.draw_orca(L, x, top, w, h - L.rh - 2, f, focused) end
  local targets = f and on and ctx.orca_targets(f) or nil
  local grid = GD.cells(snap, seq, targets)
  local label_w = U.measure('00 WWWWWW') + L.pad
  local cw = U.measure('WW') + L.pad
  local ncols = math.max(0, math.floor((w - label_w) / cw))
  -- шапка: короткие имена треков
  for ci = 1, math.min(#snap.cols, ncols) do
    U.text(x + label_w + (ci - 1) * cw, top, ctx.fit(snap.cols[ci].name or '', cw - 2), U.GREY)
  end
  local ry0 = top + L.rh
  local nvis = math.max(1, math.floor((h - (ry0 - y)) / L.rh))
  if GD.cur.ri - 1 < GD.scroll then GD.scroll = GD.cur.ri - 1 end
  if GD.cur.ri > GD.scroll + nvis then GD.scroll = GD.cur.ri - nvis end
  if U.vbar then U.vbar('garden', x, ry0, w, nvis * L.rh, GD.scroll, nvis, #seq) end   -- 15 окт: длинному списку — полоса всегда
  for r = 1, nvis do
    local ri = GD.scroll + r
    local rg = seq[ri]
    if not rg then break end
    local yy = ry0 + (r - 1) * L.rh
    local playing = info.play_row and info.play_row >= rg.r0 and info.play_row < rg.r1
    local queued = info.queued and info.queued.pos == rg.pos
    local lbl = ('%02d %s'):format(ri % 100, rg.gap and 'bar' or (rg.name ~= '' and rg.name or ('#' .. tostring(rg.idx))))
    U.text(x, yy, ctx.fit(lbl, label_w - L.pad), playing and U.AMBER or (queued and U.CYAN or (rg.gap and U.DIM or U.TEXT)))
    for ci = 1, math.min(#snap.cols, ncols) do
      local g = grid[ri] and grid[ri][ci]
      local cx = x + label_w + (ci - 1) * cw
      local sel = focused and GD.cur.ri == ri and GD.cur.ci == ci
      if sel then U.set(U.TEXT); gfx.rect(cx - 1, yy, cw - 2, L.rh, 1) end
      local t = g and cell_text(g) or '.'
      if g and g.orca and t == '.' then t = '*' end
      local col = (g and g.muted) and U.RED or ((g and g.per) and U.AMBER or ((g and g.has) and U.TEXT or U.DIM))
      if g and g.orca then col = U.CYAN end
      U.text(cx, yy, t, sel and U.BG or col, sel and U.TEXT or nil)
      if mx >= cx - 1 and mx < cx + cw - 2 and my >= yy and my < yy + L.rh then hover = { ri = ri, ci = ci } end
    end
  end
  return hover
end

function GD.draw_orca(L, x, y, w, h, f, focused)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover
  local cw = U.measure('W') + 2
  local nvis = math.max(1, math.floor((h - L.rh) / L.rh))
  if GD.ocur.y < GD.oscroll then GD.oscroll = GD.ocur.y end
  if GD.ocur.y >= GD.oscroll + nvis then GD.oscroll = GD.ocur.y - nvis + 1 end
  local fired = f.fired or {}
  for r = 0, math.min(f.h - 1 - GD.oscroll, nvis - 1) do
    local yy = y + r * L.rh
    local oy = GD.oscroll + r
    for ox = 0, f.w - 1 do
      local cx = x + ox * cw
      if cx + cw > x + w then break end
      local ch = f.cells[oy][ox]
      local k = oy * 4096 + ox
      if fired[k] then GD.glow[k] = 3 end
      local cur = focused and GD.ocur.x == ox and GD.ocur.y == oy
      local col
      if ch == '.' then col = U.DIM
      elseif GD.glow[k] and GD.glow[k] > 0 then col = U.AMBER
      elseif ch:match('%l') then col = U.GREY
      elseif ch == ':' or ch == ';' or ch == '=' or ch == '$' then col = U.CYAN
      else col = U.TEXT end
      if cur then U.set(U.TEXT); gfx.rect(cx - 1, yy, cw, L.rh, 1) end
      U.text(cx, yy, ch, cur and U.BG or col, cur and U.TEXT or nil)
      if mx >= cx - 1 and mx < cx + cw - 1 and my >= yy and my < yy + L.rh then hover = { ox = ox, oy = oy } end
    end
  end
  -- подсказка оператора под курсором
  local ch = f.cells[GD.ocur.y] and f.cells[GD.ocur.y][GD.ocur.x] or '.'
  local doc = ctx.orca_doc(ch) or ('arrows / Ctrl+hjkl move, type to place, . erase, ! bang, Esc: grid')
  U.text(x, y + nvis * L.rh, ctx.fit(('(%d,%d) '):format(GD.ocur.x, GD.ocur.y) .. doc, w), U.GREY)
  return hover
end

-- затухание подсветки — раз на тик (зовёт main после ORCA.tick)
function GD.decay()
  for k, v in pairs(GD.glow) do if v <= 1 then GD.glow[k] = nil else GD.glow[k] = v - 1 end end
end

-- ── клавиши ───────────────────────────────────────────────────────────────
local UP, DOWN, LEFT, RIGHT = 30064, 1685026670, 1818584692, 1919379572

function GD.key(c, snap, seq)
  local ch = c < 256 and string.char(c) or ''
  if GD.page == 'orca' then
    local f = ctx.garden_field()
    if not f then return false end
    local mods = ctx.mods and ctx.mods() or {}
    if c == 27 then return false                        -- Esc — main уводит фокус в трекер
    elseif c == UP or (mods.ctrl and c == 11) then GD.ocur.y = math.max(0, GD.ocur.y - 1)
    elseif c == DOWN or (mods.ctrl and c == 10) then GD.ocur.y = math.min(f.h - 1, GD.ocur.y + 1)
    elseif c == LEFT or (mods.ctrl and c == 8) then GD.ocur.x = math.max(0, GD.ocur.x - 1)
    elseif c == RIGHT or (mods.ctrl and c == 12) then GD.ocur.x = math.min(f.w - 1, GD.ocur.x + 1)
    elseif c == 32 then ctx.play_stop()
    elseif c == 8 or c == 6579564 or ch == '.' then ctx.orca_set(GD.ocur.x, GD.ocur.y, '.')
    elseif ch == '!' then ctx.orca_set(GD.ocur.x, GD.ocur.y, '*')
    elseif c > 32 and c < 127 then ctx.orca_set(GD.ocur.x, GD.ocur.y, ch)
    else return false end
    return true
  end
  local nr, nc = #seq, #snap.cols
  local g = GD.cur
  if ch == 'h' or c == LEFT then g.ci = math.max(1, g.ci - 1)
  elseif ch == 'l' or c == RIGHT then g.ci = math.min(math.max(1, nc), g.ci + 1)
  elseif ch == 'k' or c == UP then g.ri = math.max(1, g.ri - 1)
  elseif ch == 'j' or c == DOWN then g.ri = math.min(math.max(1, nr), g.ri + 1)
  elseif ch == 'g' then g.ri = 1
  elseif ch == 'G' then g.ri = math.max(1, nr)
  elseif ch:match('^%d$') then GD.numbuf = (GD.numbuf or '') .. ch
  elseif c == 13 then
    if GD.numbuf then local n = tonumber(GD.numbuf); GD.numbuf = nil; if n and n > 0 then ctx.garden_loop(g.ri, g.ci, n) end
    else ctx.region_space(seq[g.ri]) end
  elseif c == 32 then GD.numbuf = nil; ctx.region_space(seq[g.ri])
  elseif ch == '>' then ctx.garden_loop(g.ri, g.ci, GD.numbuf and tonumber(GD.numbuf) or nil); GD.numbuf = nil
  elseif ch == '<' then ctx.garden_fit(g.ri, g.ci)
  elseif ch == '+' or ch == '=' or ch == '-' then
    local grid = GD.cells(snap, seq)
    local cur = grid[g.ri] and grid[g.ri][g.ci]
    local per = cur and cur.per and math.floor(cur.per + 0.5) or 0
    local k = 1
    for i, v in ipairs(LADDER) do if v <= per then k = i end end
    if ch == '-' then k = math.max(1, (per > 0 and k or 2) - 1) else k = math.min(#LADDER, per > 0 and k + 1 or 4) end
    ctx.garden_loop(g.ri, g.ci, LADDER[k])
  elseif ch == 'm' then ctx.garden_mute(g.ri, g.ci)
  elseif ch == 'o' then GD.page = 'orca'
  elseif ch == 'O' then ctx.garden_cmd('toggle')
  elseif ch == 'p' then ctx.garden_cmd('pin')
  elseif ch == 'x' then ctx.garden_cmd('clear')
  elseif c == 27 then if GD.numbuf then GD.numbuf = nil else return false end
  else return false end
  return true
end

return GD
