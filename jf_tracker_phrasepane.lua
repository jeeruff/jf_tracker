-- jf_tracker_phrasepane.lua — панель phrases (31 окт): список фраз проекта (регионы ph:NAME в библиотеке).
--
-- Строка: имя, длина в долях, вхождений (триггеров) в песне. Клавиши: j k — строка, Enter — фраза нотой-триггером
-- в курсор трекера (трек курсора, C-4), e — к источнику (курсор в его регион: правка источника меняет все вхождения),
-- n — новая из блока / паттерна (:phrase), r — переименовать, x x — удалить (источник, его айтемы и все триггеры),
-- Esc — в трекер. Без reaper.* — тест tests/test_phrasepane.lua; данные и запись — main (ctx.phr_*).

local PHP = {}
PHP.sel = 1
PHP.xpend = nil   -- x нажат один раз: имя фразы, ждём второй x

-- list = { { name, lenq, n } } → действие: true (съедено), 'leave', { op = 'insert' | 'goto' | 'new' | 'rename' | 'delete', name }
function PHP.key(list, c)
  local ch = (c > 0 and c < 256) and string.char(c) or ''
  local n = #list
  local cur = list[PHP.sel]
  if ch ~= 'x' then PHP.xpend = nil end
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
    if on then U.set(U.tint(U.AMBER, focused and 0.3 or 0.15)); gfx.rect(x + 1, ry, w - 2, rh, 1) end
    local warn = PHP.xpend == r.name
    if PHP.editing == r.name then U.set(U.AMBER); gfx.rect(x + 1, ry, 2, rh, 1) end   -- правится в трекере
    U.text(x + pad, ry, fit((warn and 'x again - delete ' or '') .. r.name, w - 3 * pad - cw), warn and U.RED or (on and U.AMBER or U.TEXT))
    U.text(x + w - pad - cw, ry, ('%6.1f q  %3dx'):format(r.lenq or 0, r.n or 0), r.n and r.n > 0 and U.CYAN or U.DIM)
    if mx >= x and mx < x + w and my >= ry and my < ry + rh then hover = { row = idx } end
  end
  return hover
end

return PHP
