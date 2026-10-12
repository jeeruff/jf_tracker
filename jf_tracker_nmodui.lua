-- jf_tracker_nmodui.lua — модуль note mod (12 окт): слоты модуляции инструмента.
--
-- Строка на слот: номер, параметр, превью кривой пула, rate (скорость по высоте
-- ноты), loop. Последняя строка — «+ add»: слот из последнего тронутого
-- параметра FX трека инструмента. Клавиши (фокус в модуле): j k строка,
-- a — добавить, Enter — кривая в редакторе (вкладка automation), r — rate,
-- l — loop, d — удалить слот, Esc — трекер. Мышь: щелчок — строка, двойной —
-- кривая, щелчок по r / l — переключить.
-- Без reaper.*: данные (list) и действия — через ctx (main).

local N = { sel = 1, hover = nil, prev = 0, last = { t = 0, i = 0 } }
local U, ctx

function N.init(u, c) U, ctx = u, c end

-- кнопка-переключатель буквой (только буквы, без значков)
local function toggle(L, x, y, lbl, on, hot)
  local bw = U.measure(lbl) + 2 * L.pad
  U.set(on and U.tint(U.CYAN, 0.3) or (hot and U.PANEL or U.BG)); gfx.rect(x, y + 1, bw, L.rh - 2, 1)
  U.set((on or hot) and U.CYAN or U.LINE); gfx.rect(x, y + 1, bw, L.rh - 2, 0)
  U.text(x + L.pad, y, lbl, on and U.CYAN or (hot and U.AMBER or U.GREY))
  return bw
end

-- превью кривой: pts = { { t01, v01 } … }
local function curve(x, y, w, h, pts, col)
  if not pts or #pts == 0 or w < 4 then return end
  U.set(U.DIM); gfx.rect(x, y + h - 1, w, 1, 1)
  U.set(col)
  local px, py
  for _, p in ipairs(pts) do
    local cx, cy = x + math.floor(p[1] * (w - 1) + 0.5), y + h - 1 - math.floor(p[2] * (h - 1) + 0.5)
    if px then gfx.line(px, py, cx, cy) end
    px, py = cx, cy
  end
  if px and px < x + w - 1 then gfx.line(px, py, x + w - 1, py) end
end

-- list = { name = инструмент, slots = { { label, rate, loop, pts, missing } } }
function N.draw(L, x, y, w, h, list, focused)
  N.hover = nil
  local mx, my, cap = gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap
  local press = cap & 1 == 1 and N.prev & 1 == 0
  N.prev = cap
  if not list then
    U.text(x + L.pad, y, ctx.fit('note mod: select an instrument (a sample in the lib)', w - L.pad), U.GREY)
    return
  end
  U.text(x + L.pad, y, ctx.fit('note mod - ' .. (list.name or 'instrument'), w - L.pad), U.AMBER)
  local n = #list.slots + 1
  if N.sel > n then N.sel = n end
  local per = math.max(1, math.floor((h - L.rh) / L.rh))
  N.scroll = math.max(0, math.min(N.scroll or 0, n - per))
  if N.sel > N.scroll + per then N.scroll = N.sel - per elseif N.sel <= N.scroll then N.scroll = N.sel - 1 end
  local numw = U.measure('00') + L.pad
  for i = N.scroll + 1, math.min(n, N.scroll + per) do
    local ry = y + (i - N.scroll) * L.rh
    local sel = focused and i == N.sel
    local hot = mx >= x and mx < x + w and my >= ry and my < ry + L.rh
    if sel then U.set(U.tint(U.AMBER, 0.25)); gfx.rect(x, ry, w, L.rh, 1)
    elseif hot then U.set(U.tint(U.AMBER, 0.12)); gfx.rect(x, ry, w, L.rh, 1) end
    local s = list.slots[i]
    local what
    if not s then
      U.text(x + L.pad, ry, ctx.fit('+ add: the last touched parameter of an fx on this track', w - L.pad), (sel or hot) and U.AMBER or U.GREY)
      what = 'add'
    else
      U.text(x + L.pad, ry, tostring(i), U.GREY)
      -- справа налево: l, r, кривая; имя — что осталось
      local bx = x + w
      local lw = U.measure('loop') + 2 * L.pad
      bx = bx - lw
      local hl = hot and mx >= bx
      toggle(L, bx, ry, 'loop', s.loop, hl)
      local rw = U.measure('rate') + 2 * L.pad
      bx = bx - rw - 2
      local hr = hot and mx >= bx and mx < bx + rw
      toggle(L, bx, ry, 'rate', s.rate, hr)
      local cw = math.min(L.cw * 12, math.max(0, bx - x - numw - L.cw * 10))
      if cw >= L.cw * 3 then curve(bx - cw - L.pad, ry + 3, cw, L.rh - 6, s.pts, (sel or hot) and U.AMBER or U.CYAN); bx = bx - cw - L.pad end
      U.text(x + numw, ry, ctx.fit(s.label .. (s.missing and '  (fx gone)' or ''), bx - x - numw - L.pad), s.missing and U.RED or ((sel or hot) and U.AMBER or U.TEXT))
      what = hl and 'loop' or (hr and 'rate' or 'row')
    end
    if hot then
      N.hover = { i = i, what = what }
      if ctx.status then ctx.status(what == 'add' and 'note mod: a - add the last touched parameter (move a knob first)'
        or (what == 'rate' and 'rate (r): the curve runs faster for higher notes - C-4 = x1, an octave up = x2')
        or (what == 'loop' and 'loop (l): the curve repeats to the end of the note; off - once, then holds')
        or 'note mod: Enter / double click - edit the curve, d - delete, j k - row') end
      if press then
        N.sel = i
        if ctx.nmod_focus then ctx.nmod_focus() end
        local now = reaper and reaper.time_precise and reaper.time_precise() or os.clock()
        if what == 'rate' or what == 'loop' then ctx.nmod_flag(i, what)
        elseif what == 'add' then ctx.nmod_add()
        elseif now - N.last.t < 0.35 and N.last.i == i then ctx.nmod_edit(i) end
        N.last = { t = now, i = i }
      end
    end
  end
end

function N.key(c, list)
  local ch = c < 256 and string.char(c) or ''
  local n = list and (#list.slots + 1) or 1
  if ch == 'j' or ch == 'J' then N.sel = math.min(n, N.sel + 1)
  elseif ch == 'k' or ch == 'K' then N.sel = math.max(1, N.sel - 1)
  elseif ch == 'a' then ctx.nmod_add()
  elseif c == 13 then if list and list.slots[N.sel] then ctx.nmod_edit(N.sel) else ctx.nmod_add() end
  elseif ch == 'r' then if list and list.slots[N.sel] then ctx.nmod_flag(N.sel, 'rate') end
  elseif ch == 'l' then if list and list.slots[N.sel] then ctx.nmod_flag(N.sel, 'loop') end
  elseif ch == 'd' then if list and list.slots[N.sel] then ctx.nmod_del(N.sel) end
  else return false end
  return true
end

return N
