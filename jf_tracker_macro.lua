-- jf_tracker_macro.lua — макро-вид трекера (3 окт, :macro): вид «с высоты».
--
-- Поверх тела трекера: строка = такт, колонки — те же треки, что в шапке.
-- В клетке: плотность событий такта блоками (▁▂▃▄▅▆▇█ рисуются клетками
-- шириной в символ, как метры) и первая нота такта; слева — номер такта и
-- имя региона, который в нём начинается. Курсор — такт строки курсора
-- трекера; j / k — такт вниз / вверх (J K — по 4), g / G — начало / конец,
-- h / l — треки (Vim как обычно), Enter / Esc / :macro — назад в трекер на
-- этот такт. Без reaper.*: данные — из снимка модели.
-- 6 ноя: обзор (zO) — вертикальная свёртка: строка = bpr тактов (1 … 256), - / + грубее / мельче, 0 — вся песня
-- в экран; слева номер такта и время (mm:ss), справа — плотность событий по трекам

local MC = { scroll = 0, bpr = 1, nvis = 30 }
MC.BPR = { 1, 2, 4, 8, 16, 32, 64, 128, 256 }
local U

function MC.init(u) U = u end

-- события по тактам: [ci][bar] = { n = число голов, note = первая нота }
local cache_sid, cache_rpb, cache
local function counts(snap, rpb)
  if cache_sid == snap.sid and cache_sid ~= nil and cache_rpb == rpb and cache then return cache end   -- 6 ноя: номер снимка, не сам снимок
  local out, last = {}, 0
  for ci, col in ipairs(snap.cols or {}) do
    local t = {}
    for _, lane in ipairs(col.lanes or {}) do
      for _, sub in ipairs(lane.subs or {}) do
        for r, cell in pairs(sub) do
          if (cell.kind == 'audio' or cell.kind == 'midi') and cell.row0 == r and r >= 0 then
            local b = r // rpb
            local e = t[b]
            if not e then e = { n = 0, row = math.huge }; t[b] = e end
            e.n = e.n + 1
            if r < e.row then e.row, e.note = r, cell.note end
            if b > last then last = b end
          end
        end
      end
    end
    out[ci] = t
  end
  cache_sid, cache_rpb, cache = snap.sid, rpb, { by = out, last = last }
  return cache
end

-- регион, начинающийся в такте b (имя для левой колонки)
local function region_at_bar(regions, b, rpb)
  for _, rg in ipairs(regions or {}) do
    -- 8 ноя: заглушки «no pattern» (idx < 0) — не регион (были метки -1 на каждой строке)
    if rg.r0 and rg.r0 >= 0 and rg.r0 // rpb == b and (rg.idx or 0) >= 0 then return rg end   -- 6 ноя: начинается в строке (строка = bpr тактов)
  end
end

-- отрисовка: x0 / y0 / w / h — тело трекера; L.cols — колонки треков;
-- label_w — левая колонка (номера); cur_row — строка курсора трекера
function MC.draw(L, snap, x0, y0, w, h, label_w, cur_row, rpb, regions, fit, tfn)
  local bar_rows = math.max(1, rpb)
  rpb = bar_rows * MC.bpr
  local c = counts(snap, rpb)
  local rh = L.rh
  local cap_y = y0                            -- 8 ноя: своя строка описания вида сверху, такты — под ней
  U.set(U.BG); gfx.rect(x0, y0, w, rh, 1)
  y0, h = y0 + rh, h - rh
  local nvis = math.max(1, math.floor(h / rh))
  MC.nvis, MC.bar_rows = nvis, bar_rows
  MC.last_bar = (c.last + 1) * MC.bpr
  local cur_bar = math.max(0, cur_row // rpb)
  if cur_bar < MC.scroll then MC.scroll = cur_bar end
  if cur_bar >= MC.scroll + nvis then MC.scroll = cur_bar - nvis + 1 end
  U.set(U.BG); gfx.rect(x0, y0, w, h, 1)
  local nb = math.max(c.last + 2, cur_bar + 1)
  if U.vbar then U.vbar('macroview', x0, y0, w, nvis * rh, MC.scroll, nvis, nb) end   -- 15 окт: длинному списку — полоса всегда
  local maxn = 1
  for _, t in pairs(c.by) do for _, e in pairs(t) do if e.n > maxn then maxn = e.n end end end
  for i = 0, nvis - 1 do
    local b = MC.scroll + i
    if b > nb + nvis then break end
    local y = y0 + i * rh
    if b == cur_bar then U.set(U.mix(U.BG, U.TEXT, 0.16)); gfx.rect(x0, y, w, rh, 1) end
    if b % 4 == 0 then U.set(U.mix(U.BG, U.TEXT, 0.10)); gfx.rect(x0, y, w, 1, 1) end
    local rg = region_at_bar(regions, b, rpb)
    local lbl = ('%3d'):format(b * MC.bpr + 1)
    if tfn and MC.bpr > 1 then local ts = tfn(b * rpb); if ts then lbl = lbl .. ' ' .. ts end end   -- 6 ноя: время начала строки
    U.text(x0 + 2, y + 1, lbl, b == cur_bar and U.AMBER or U.GREY)
    if rg then
      local nm = (rg.name and rg.name ~= '') and rg.name or tostring(rg.idx or '')
      U.text(x0 + 2 + U.measure(lbl .. ' '), y + 1, fit(nm, label_w - U.measure(lbl .. ' ') - 4), U.CYAN)
    end
    for _, col in ipairs(L.cols or {}) do
      if col.x then
        local e = (c.by[col.ci] or {})[b]
        local cx, cw = col.x + 2, col.w - 4
        if e and cw > 8 then
          -- плотность: клетки шириной в символ, сколько событий относительно
          -- самого плотного такта; полный блок — 8 восьмых высоты строки
          local cells = math.max(1, math.min(4, math.floor(cw / (L.cw * 3))))
          local eighths = math.max(1, math.floor(e.n / maxn * cells * 8 + 0.5))
          local rgb = col.col.rgb or U.GREEN
          for k = 0, cells - 1 do
            local part = math.max(0, math.min(8, eighths - k * 8))
            if part > 0 then
              local hh = math.max(1, math.floor((rh - 2) * part / 8 + 0.5))
              U.set(U.mix(rgb, U.TEXT, 0.25)); gfx.rect(cx + k * L.cw, y + rh - 1 - hh, L.cw - 1, hh, 1)
            end
          end
          local nx = cx + cells * L.cw + L.pad
          if e.note and nx + U.measure(e.note) < cx + cw then U.text(nx, y + 1, e.note, U.TEXT) end
        elseif cw > 8 then
          U.text(cx, y + 1, fit('.', cw), U.DIM)
        end
      end
    end
  end
  U.set(U.AMBER); gfx.rect(x0, y0 - 1, w, 1, 1)
  -- 8 ноя: что за вид — строкой справа сверху: строка = N тактов, слева такт (и время), в клетке — сколько нот /
  -- айтемов начинается и первая нота; клавиши. Не влезает — короче
  local nb2 = MC.bpr > 1 and ('%d bars'):format(MC.bpr) or '1 bar'
  local tags = {
    ('OVERVIEW: a row = %s, left - the bar%s, blocks - how many notes / items start there, then the first note;  j k move  - + zoom  0 whole song  Enter back'):format(nb2, MC.bpr > 1 and ' and its time' or ''),
    ('OVERVIEW: a row = %s, blocks - events in it;  j k  - +  0  Enter'):format(nb2),
    ('OVERVIEW %s / row  - + 0'):format(nb2) }
  local tag = tags[#tags]
  for _, t in ipairs(tags) do if U.measure(t) <= w - 8 then tag = t; break end end
  U.text(x0 + 4, cap_y + 1, tag, U.AMBER)
end

-- клавиши; возвращает новую строку курсора, 'leave' или nil (не своя)
-- 6 ноя: шаг свёртки: d = 1 — грубее, -1 — мельче; fit — вся песня (последний такт с событиями) в экран
function MC.zoom(d)
  local i = 1
  for k, v in ipairs(MC.BPR) do if v == MC.bpr then i = k end end
  i = math.max(1, math.min(#MC.BPR, i + d))
  MC.bpr = MC.BPR[i]
end
function MC.fit()
  local need = (MC.last_bar or 0) + 1
  for _, v in ipairs(MC.BPR) do MC.bpr = v; if math.ceil(need / v) <= (MC.nvis or 30) then break end end
  MC.scroll = 0
end
function MC.key(c, cur_row, rpb, last_row)
  local ch = c < 256 and string.char(c) or ''
  if ch == '-' or ch == '_' then MC.zoom(1); return cur_row
  elseif ch == '=' or ch == '+' then MC.zoom(-1); return cur_row
  elseif ch == '0' then MC.fit(); return cur_row end
  rpb = math.max(1, rpb) * MC.bpr
  local b = cur_row // rpb
  if ch == 'j' or c == 1685026670 then return (b + 1) * rpb
  elseif ch == 'k' or c == 30064 then return math.max(0, b - 1) * rpb
  elseif ch == 'J' then return (b + 4) * rpb
  elseif ch == 'K' then return math.max(0, b - 4) * rpb
  elseif ch == 'g' then return 0
  elseif ch == 'G' then return ((last_row or 0) // rpb) * rpb
  elseif c == 13 or c == 27 then return 'leave' end
  return nil
end

return MC
