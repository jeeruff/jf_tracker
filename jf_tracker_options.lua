-- jf_tracker_options.lua — окно Options: все переключатели и числа трекера
-- в одном всплывающем списке (кнопка «options» в контроле, :options, \o).
--
-- Строка = { key=, label=, kind='toggle'|'cycle'|'num', get=, set=, values=,
-- min=, max=, step=, desc= }. Список строит main (он знает state/vim) и
-- передаёт в O.open(items). Модуль не трогает reaper.*: только gfx через U.
--
-- Клавиши: j k / стрелки — строка; Enter Space l h + - — переключить или
-- изменить (Shift ×10); 0 — сброс к min; Esc q — закрыть. Мышь: клик по
-- строке — переключить (toggle/cycle) или выбрать (num), колесо — изменить.

local O = { active = false, sel = 1, scroll = 0, items = {}, hover = nil, page = 'list', about = nil, ascroll = 0 }
local U, ctx

function O.init(u, c) U, ctx = u, c end

function O.open(items, about)
  O.items = items or O.items
  -- about может быть функцией (3 окт): страница собирается заново при каждом
  -- входе — логотип каждый раз в новом стиле
  if type(about) == 'function' then O.about_fn = about; O.about = about() else O.about = about or O.about end
  O.page = 'list'
  O.active = true
  O.sel = math.max(1, math.min(#O.items, O.sel))
end
function O.close() O.active = false end

local function val_text(it)
  if it.kind == 'about' then return 'Enter' end
  local v = it.get()
  if it.kind == 'toggle' then return v and 'on' or 'off' end
  if it.kind == 'cycle' then return tostring(v) end
  if it.fmt then return it.fmt:format(v) end
  return tostring(v)
end

-- изменить строку: d = +1/-1 (num/cycle), 0 = переключить (toggle) / шаг вперёд
function O.adjust(it, d)
  if not it then return end
  if it.kind == 'about' then O.page = 'about'; O.ascroll = 0; if O.about_fn then O.about = O.about_fn() end; return end
  if it.kind == 'toggle' then it.set(not it.get())
  elseif it.kind == 'cycle' then
    local v = it.get(); local k = 1
    for i, x in ipairs(it.values) do if x == v then k = i end end
    local n = #it.values
    k = ((k - 1 + (d == 0 and 1 or d)) % n) + 1
    it.set(it.values[k])
  elseif it.kind == 'num' then
    if d == 0 then return end
    local v = (it.get() or 0) + d * (it.step or 1)
    if it.min then v = math.max(it.min, v) end
    if it.max then v = math.min(it.max, v) end
    it.set(v)
  end
end

function O.key(c)
  local ch = c < 256 and string.char(c) or ''
  if O.page == 'about' then
    local n = #(O.about or {})
    if c == 27 or ch == 'q' or c == 13 then O.page = 'list'
    elseif ch == 'j' or c == 1685026670 then O.ascroll = math.min(math.max(0, n - 1), O.ascroll + 1)
    elseif ch == 'k' or c == 30064 then O.ascroll = math.max(0, O.ascroll - 1)
    elseif ch == 'g' then O.ascroll = 0 end
    return true
  end
  local shift = ctx.mods and ctx.mods().shift
  local n = #O.items
  local it = O.items[O.sel]
  if c == 27 or ch == 'q' then O.close()
  elseif ch == 'j' or c == 1685026670 then O.sel = math.min(n, O.sel + 1)
  elseif ch == 'k' or c == 30064 then O.sel = math.max(1, O.sel - 1)
  elseif ch == 'g' then O.sel = 1
  elseif ch == 'G' then O.sel = n
  elseif c == 13 or ch == ' ' then O.adjust(it, 0)
  elseif ch == 'l' or ch == '+' or ch == '=' or c == 1919379572 then O.adjust(it, shift and 10 or 1)
  elseif ch == 'h' or ch == '-' or c == 1818584692 then O.adjust(it, shift and -10 or -1)
  elseif ch == '0' and it and it.kind == 'num' and it.min then it.set(it.min)
  end
  return true
end

function O.wheel(d)
  if O.page == 'about' then O.ascroll = math.max(0, O.ascroll - d); return end
  O.adjust(O.items[O.hover or O.sel], d)
end

function O.click(mx, my)
  if O.hover then O.sel = O.hover; O.adjust(O.items[O.sel], O.items[O.sel].kind == 'num' and 0 or 0) end
  if O.box and (mx < O.box[1] or mx > O.box[1] + O.box[3] or my < O.box[2] or my > O.box[2] + O.box[4]) then O.close() end
end

-- отрисовка поверх всего: панель по центру окна
function O.draw(L, W, H)
  if not O.active then return end
  local rh = L.rh
  local n = #O.items
  local lw, vw = L.cw * 22, L.cw * 12
  local dw = 0
  for _, it in ipairs(O.items) do dw = math.max(dw, U.measure(it.desc or '')) end
  local bw = math.min(W - 2 * L.pad - 20, lw + vw + math.min(dw, L.cw * 40) + 4 * L.pad)
  local nvis = math.max(3, math.min(n, math.floor((H - 6 * rh) / rh)))
  local bh = (nvis + 3) * rh
  local bx, by = math.floor((W - bw) / 2), math.floor((H - bh) / 2)
  O.box = { bx, by, bw, bh }
  if O.sel - 1 < O.scroll then O.scroll = O.sel - 1 end
  if O.sel > O.scroll + nvis then O.scroll = O.sel - nvis end
  U.set(U.BG); gfx.rect(bx, by, bw, bh, 1)
  U.set(U.TEXT); gfx.rect(bx, by, bw, bh, 0)
  if O.page == 'about' then
    -- about: версия и список изменений (jf_tracker_version.lua)
    O.hover = nil                     -- клик по about не должен переключать опции под ним
    U.text(bx + L.pad, by + 2, ctx.fit('about   j k / wheel: scroll   Esc: back', bw - 2 * L.pad), U.AMBER)
    U.set(U.LINE); gfx.rect(bx, by + rh + 2, bw, 1, 1)
    local lines = O.about or {}
    local nv = math.floor((bh - rh - 6) / rh)
    for r = 1, nv do
      local s = lines[O.ascroll + r]
      if not s then break end
      local col = s:match('^%d+%.%d') and U.AMBER or (s:match('^jf_tracker') and U.CYAN or U.TEXT)
      U.text(bx + L.pad, by + rh + 4 + (r - 1) * rh, ctx.fit(s, bw - 2 * L.pad), col)
    end
    return
  end
  U.text(bx + L.pad, by + 2, 'options', U.AMBER)
  local hx = bx + L.pad + U.measure('options') + 3 * L.pad
  U.text(hx, by + 2, ctx.fit('j k: row   Enter / Space / h l + -: change   Esc: close', bx + bw - L.pad - hx), U.GREY)
  U.set(U.LINE); gfx.rect(bx, by + rh + 2, bw, 1, 1)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  O.hover = nil
  for r = 1, nvis do
    local i = O.scroll + r
    local it = O.items[i]
    if not it then break end
    local y = by + rh + 4 + (r - 1) * rh
    if it.sep then U.set(U.DIM); gfx.rect(bx + L.pad, y + math.floor(rh / 2), bw - 2 * L.pad, 1, 1)
    else
      local hot = mx >= bx and mx < bx + bw and my >= y and my < y + rh
      if hot then O.hover = i end
      if i == O.sel then U.set(U.tint(U.AMBER, 0.25)); gfx.rect(bx + 1, y, bw - 2, rh, 1)
      elseif hot then U.set(U.PANEL); gfx.rect(bx + 1, y, bw - 2, rh, 1) end
      U.text(bx + L.pad, y + 1, ctx.fit(it.label, lw - L.pad), i == O.sel and U.AMBER or U.TEXT)
      local vt = val_text(it)
      local on = it.kind == 'toggle' and it.get()
      U.text(bx + L.pad + lw, y + 1, ctx.fit(vt, vw - L.pad), on and U.CYAN or (it.kind == 'toggle' and U.GREY or U.TEXT))
      if it.desc then U.text(bx + L.pad + lw + vw, y + 1, ctx.fit(it.desc, bw - lw - vw - 2 * L.pad), U.GREY) end
    end
  end
  U.set(U.LINE); gfx.rect(bx, by + bh - rh - 2, bw, 1, 1)
  local it = O.items[O.sel]
  U.text(bx + L.pad, by + bh - rh, ctx.fit(it and it.desc or '', bw - 2 * L.pad), U.GREY)
end

return O
