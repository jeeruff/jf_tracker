-- jf_tracker_phrasepane.lua — панель phrases (31 окт): список фраз проекта (регионы ph:NAME в библиотеке).
--
-- Строка: имя, длина в долях, вхождений (триггеров) в песне. Клавиши: j k — строка, Enter — фраза нотой-триггером
-- в курсор трекера (трек курсора, C-4), e — к источнику (курсор в его регион: правка источника меняет все вхождения),
-- n — новая из блока / паттерна (:phrase), r — переименовать, x x — удалить (источник, его айтемы и все триггеры),
-- Esc — в трекер. Без reaper.* — тест tests/test_phrasepane.lua; данные и запись — main (ctx.phr_*).

local PHP = {}
PHP.sel = 1
PHP.xpend = nil   -- x нажат один раз: имя фразы, ждём второй x
PHP.col = 1       -- 31 окт (lf): колонка — 1 список, 3 места (где стоит); 2 — содержимое (только смотреть)
PHP.usel = 1      -- выбранное место в колонке 3
local NN = { 'C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-' }
local function nname(p) return NN[p % 12 + 1] .. math.floor(p / 12 - 1) end

-- list = { { name, lenq, n } } → действие: true (съедено), 'leave', { op = 'insert' | 'goto' | 'new' | 'rename' | 'delete', name }
function PHP.key(list, c)
  local ch = (c > 0 and c < 256) and string.char(c) or ''
  local n = #list
  local cur = list[PHP.sel]
  if ch ~= 'x' then PHP.xpend = nil end
  -- 31 окт (lf): l — к местам фразы (правая колонка), h — назад к списку; там j k — место, Enter — к нему
  if PHP.col == 3 then
    local nu = cur and cur.uses and #cur.uses or 0
    if ch == 'h' or c == 1818584692 or c == 27 then PHP.col = 1; return true
    elseif ch == 'j' or c == 1685026670 then PHP.usel = math.min(math.max(1, nu), PHP.usel + 1); return true
    elseif ch == 'k' or c == 30064 then PHP.usel = math.max(1, PHP.usel - 1); return true
    elseif c == 13 or ch == 'l' then if cur and nu > 0 then return { op = 'use', name = cur.name, i = PHP.usel } end; return true end
    return true
  end
  if (ch == 'l' or c == 1919379572) and cur then PHP.col = 3; PHP.usel = 1; return true end
  if ch == 'j' or c == 1685026670 then PHP.sel = math.min(math.max(1, n), PHP.sel + 1); return true
  elseif ch == 'k' or c == 30064 then PHP.sel = math.max(1, PHP.sel - 1); return true
  elseif ch == 'g' then PHP.sel = 1; return true
  elseif ch == 'G' then PHP.sel = math.max(1, n); return true
  elseif ch == 'n' then return { op = 'new' }
  elseif c == 27 then return 'leave' end
  if not cur then return false end
  if c == 13 then return { op = 'insert', name = cur.name }
  elseif ch == 'e' then return { op = 'edit', name = cur.name }   -- 31 окт: правка тем же трекером; ещё раз — назад
  elseif ch == 'r' then return { op = 'rename', name = cur.name }
  elseif ch == 'x' then
    if PHP.xpend == cur.name then PHP.xpend = nil; return { op = 'delete', name = cur.name } end
    PHP.xpend = cur.name
    return { op = 'confirm', name = cur.name }
  end
  return false
end

-- рисование; → hover { row = i } | { btn = 'new' } | nil
function PHP.draw(U, L, list, x, y, w, h, focused, mx, my, fit)
  local pad, rh = L.pad, L.rh
  local hover
  -- шапка: кнопка new и подсказка
  local nb = 'new (n)'
  local nw = U.measure(nb) + 2 * pad
  local hot = mx >= x + pad and mx < x + pad + nw and my >= y and my < y + rh
  U.set(hot and U.AMBER or U.LINE); gfx.rect(x + pad, y, nw, rh - 1, 0)
  U.text(x + 2 * pad, y, nb, hot and U.AMBER or U.GREY)
  if hot then hover = { btn = 'new' } end
  U.text(x + 2 * pad + nw, y, fit(PHP.editing and ('  editing ' .. PHP.editing .. ' - e: back to the song') or '  Enter - at the cursor, e - edit it in the tracker', math.max(0, w - nw - 3 * pad)), PHP.editing and U.AMBER or U.DIM)
  y = y + rh + 2
  if #list == 0 then
    U.text(x + pad, y, fit('no phrases - V a block (or the cursor in a pattern), then n or :phrase NAME', w - 2 * pad), U.GREY)
    return hover
  end
  if PHP.sel > #list then PHP.sel = #list end
  -- 31 окт (lf): широко — три колонки: фразы | что внутри | где стоит
  local lw = w
  local cur = list[PHP.sel]
  local lf = w >= U.measure('0') * 70 and cur
  if lf then
    lw = math.max(U.measure('0') * 22, math.floor(w * 0.3))
    local cx, cw2 = x + lw + pad, math.floor((w - lw) * 0.55) - pad
    local ux, uw = cx + cw2 + pad, x + w - (cx + cw2 + pad)
    U.set(U.LINE); gfx.rect(cx - math.floor(pad / 2) - 1, y, 1, h - rh - 2, 1); gfx.rect(ux - math.floor(pad / 2) - 1, y, 1, h - rh - 2, 1)
    -- середина: ноты источника строками (номер строки от начала фразы, нота, vel)
    U.text(cx, y, fit(('%s: %d event(s)'):format(cur.name, #(cur.notes or {})), cw2), U.GREY)
    local nv = math.floor((h - 2 * rh - 2) / rh)
    for i = 1, math.min(nv, #(cur.notes or {})) do
      local n = cur.notes[i]
      local s = n.audio and ('%04d  %s'):format(n.row, n.audio ~= '' and n.audio or 'audio') or ('%04d  %s %02X'):format(n.row, nname(n.pitch), n.vel)
      U.text(cx, y + i * rh, fit(s, cw2), n.muted and U.DIM or (n.audio and U.CYAN or U.TEXT))
    end
    if #(cur.notes or {}) > nv then U.text(cx, y + (nv + 1) * rh, '...', U.DIM) end
    -- справа: где стоит (трек, строка, высота триггера); l — сюда, Enter / щелчок — к нему
    U.text(ux, y, fit(('used %dx%s'):format(#(cur.uses or {}), PHP.col == 3 and '' or '  (l)'), uw), U.GREY)
    for i = 1, math.min(nv, #(cur.uses or {})) do
      local u = cur.uses[i]
      local ry = y + i * rh
      local on = PHP.col == 3 and i == PHP.usel
      if on then U.set(U.tint(U.AMBER, focused and 0.3 or 0.15)); gfx.rect(ux - 2, ry, uw + 2, rh, 1) end
      local hot = mx >= ux and mx < ux + uw and my >= ry and my < ry + rh
      U.text(ux, ry, fit(('%s  %04d  %s'):format(u.track, u.row, u.pitch and nname(u.pitch) or ''), uw), (on or hot) and U.AMBER or U.TEXT)
      if hot then hover = { use = i } end
    end
  end
  w = lw
  local nvis = math.max(1, math.floor((h - rh - 2) / rh))
  local top = math.max(0, math.min(PHP.sel - nvis, #list - nvis))
  if PHP.sel - 1 < top then top = PHP.sel - 1 end
  local cw = U.measure('0000.0 q  000x')   -- колонки справа: длина и вхождения — строгая ширина
  for i = 1, nvis do
    local idx = top + i
    local r = list[idx]
    if not r then break end
    local ry = y + (i - 1) * rh
    local on = idx == PHP.sel
    if on then U.set(U.tint(U.AMBER, (focused and PHP.col == 1) and 0.3 or 0.15)); gfx.rect(x + 1, ry, w - 2, rh, 1) end
    local warn = PHP.xpend == r.name
    if PHP.editing == r.name then U.set(U.AMBER); gfx.rect(x + 1, ry, 2, rh, 1) end   -- правится в трекере
    U.text(x + pad, ry, fit((warn and 'x again - delete ' or '') .. r.name, w - 3 * pad - cw), warn and U.RED or (on and U.AMBER or U.TEXT))
    U.text(x + w - pad - cw, ry, ('%6.1f q  %3dx'):format(r.lenq or 0, r.n or 0), r.n and r.n > 0 and U.CYAN or U.DIM)
    if mx >= x and mx < x + w and my >= ry and my < ry + rh then hover = { row = idx } end
  end
  return hover
end

return PHP
