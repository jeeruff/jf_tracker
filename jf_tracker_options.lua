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

local TX = dofile((debug.getinfo(1, 'S').source:match('^@(.*/)') or './') .. 'jf_tracker_utf8.lua')   -- 20 окт: набор Юникодом (кириллица)
local O = { active = false, sel = 1, scroll = 0, items = {}, hover = nil, page = 'list', about = nil, ascroll = 0 }
local U, ctx

function O.init(u, c) U, ctx = u, c end

-- 5 окт: вкладки по разделам (sep с title), вкладка all — все на одной
-- странице, / — fzf по всем опциям (имя + описание); O.items — то, что видно
O.all, O.tabs, O.tab, O.query, O.typing = {}, {}, nil, '', false
local function fuzzy(hay, q)
  hay = hay:lower()
  for w in q:lower():gmatch('%S+') do
    local pos = 1
    for ch in w:gmatch('.') do
      local f = hay:find(ch, pos, true)
      if not f then return false end
      pos = f + 1
    end
  end
  return true
end
function O.rebuild()
  local view = {}
  if O.query ~= '' then
    -- 16 окт: поиск — только по своей вкладке (options — опции, hotkeys — клавиши);
    -- сначала строки с запросом подряд, потом буквы по порядку
    local grp, near, far = 'options', {}, {}
    local q = O.query:lower()
    for _, it in ipairs(O.all) do
      if it.sep then grp = it.group or 'options' end
      if (O.tab == 'all' or grp == O.tab) and not it.sep and it.kind ~= 'block' then
        local hay = (it.label or '') .. ' ' .. (it.desc or '') .. ' ' .. (it.value or '') .. ' ' .. (it.key or '')
        if hay:lower():find(q, 1, true) then near[#near + 1] = it
        elseif fuzzy(hay, O.query) then far[#far + 1] = it end
      end
    end
    for _, it in ipairs(near) do view[#view + 1] = it end
    for _, it in ipairs(far) do view[#view + 1] = it end
  elseif O.tab == 'all' then view = O.all
  else
    -- вкладка = группа разделов (5 окт): заголовок с group = 'hotkeys' и всё под
    -- ним — вкладка hotkeys, остальное — options
    local grp = 'options'
    for _, it in ipairs(O.all) do
      if it.sep then grp = it.group or 'options' end
      if grp == O.tab then
        -- 14 окт: блок (темы и шрифты) — своими строками списка, рисует его владелец
        if it.kind == 'block' then
          local n = math.max(4, math.ceil((it.height and it.height() or 30 * 20) / math.max(1, O.rh or 20)))
          it.nrows = n
          for k = 1, n do view[#view + 1] = { blockrow = true, k = k, of = it, label = '' } end
        else view[#view + 1] = it end
      end
    end
  end
  O.items = view
  O.sel = math.max(1, math.min(#O.items, O.sel))
  while O.items[O.sel] and O.items[O.sel].sep and O.sel < #O.items do O.sel = O.sel + 1 end
end
function O.open(items, tab)
  O.compact, O.numbuf = nil, nil
  O.all = items or O.all
  -- вкладки по разделам убраны (5 окт, «дурацкая идея»); остались две —
  -- options и hotkeys (группы заголовков); без групп — одна страница
  -- 10 окт: вкладки — options и группы заголовков по порядку (audio, hotkeys)
  O.tabs = {}
  for _, it in ipairs(O.all) do
    if it.sep and it.group then
      if #O.tabs == 0 then O.tabs[1] = 'options' end
      local dup = false
      for _, t in ipairs(O.tabs) do if t == it.group then dup = true end end
      if not dup then O.tabs[#O.tabs + 1] = it.group end
    end
  end
  O.tab = 'all'
  if #O.tabs > 0 then
    O.tab = 'options'
    for _, t in ipairs(O.tabs) do if t == tab then O.tab = t end end
  end
  O.query, O.typing = '', false
  O.page = 'list'
  O.active = true
  O.rebuild()
end
-- компактная панель (5 окт): свойства item у курсора — те же строки, без
-- вкладок и поиска, у точки anchor = { x, y }; title — заголовок
function O.open_panel(items, title, anchor)
  O.all, O.items, O.tabs, O.tab, O.query, O.typing = items, items, {}, nil, '', false
  O.compact = { title = title or '', x = anchor and anchor.x, y = anchor and anchor.y }
  O.page, O.active, O.sel, O.scroll, O.numbuf = 'list', true, 1, 0, nil
end
function O.set_tab(t) O.tab = t; O.sel, O.scroll = 1, 0; O.query = ''; O.rebuild(); if ctx.opt_tab then ctx.opt_tab(t) end end
function O.step_tab(d)
  if #O.tabs == 0 then return end
  local i = 1
  for k, t in ipairs(O.tabs) do if t == O.tab then i = k end end
  O.set_tab(O.tabs[(i - 1 + d) % #O.tabs + 1])
end
-- about отдельно, из главного модуля (3 окт): fn() → { logo = { lines = … }, text = { строки } };
-- Esc закрывает окно целиком, не возвращает в список опций
function O.open_about(fn)
  local a = fn()
  O.logo, O.about, O.title = a.logo, a.text or {}, a.title
  O.page, O.ascroll, O.active, O.ab_log = 'about', 0, true, nil   -- 17 окт: about открывается с начала (не в changelog)
end
function O.close() O.active = false; O.drag = nil end

local function val_text(it)
  if it.kind == 'action' then return it.value or '' end
  if it.kind == 'text' then return it.get and tostring(it.get()) or '' end
  local v = it.get()
  if it.kind == 'toggle' then return v and 'on' or 'off' end
  if it.kind == 'cycle' then return tostring(v) end
  if it.fmt then return it.fmt:format(it.fmt:find('%%d') and math.floor(v + 0.5) or v) end   -- 21 окт: дробное с %d ронялo кадр
  return tostring(v)
end

-- изменить строку: d = +1/-1 (num/cycle), 0 = переключить (toggle) / шаг вперёд
function O.adjust(it, d)
  if not it then return end
  if it.kind == 'action' or it.kind == 'text' then if it.fn then it.fn() end; return end   -- действие / текст (промпт) (5 окт)
  if it.pick and d == 0 then return it.pick() end   -- 10 окт: Enter на font / theme — выпадашка с превью
  if it.kind == 'toggle' then it.set(not it.get())
  elseif it.kind == 'cycle' then
    local v = it.get(); local k = 1
    for i, x in ipairs(it.values) do if x == v then k = i end end
    local n = #it.values
    k = ((k - 1 + (d == 0 and 1 or (d > 0 and 1 or -1))) % n) + 1
    it.set(it.values[k])
  elseif it.kind == 'num' then
    if d == 0 then return end
    local v = (it.get() or 0) + d * (it.step or 1)
    if it.min then v = math.max(it.min, v) end
    if it.max then v = math.min(it.max, v) end
    it.set(v)
  end
end

-- 17 окт: about ↔ changelog: в changelog текст с строки «changes», логотипа нет
function O.toggle_log()
  O.ab_log = not O.ab_log
  O.ascroll = 0
  if O.ab_log then
    for i, l in ipairs(O.wrapped or {}) do if l[1] == 'changes' then O.ascroll = i - 1; break end end
  end
end
function O.key(c)
  local ch = c < 256 and string.char(c) or ''
  if O.page == 'about' then
    local n = O.about_n or #(O.about or {})
    if c == 27 or ch == 'q' or c == 13 then O.close()
    elseif ch == 'j' or c == 1685026670 then O.ascroll = math.min(math.max(0, n - 1), O.ascroll + 1)
    elseif ch == 'k' or c == 30064 then O.ascroll = math.max(0, O.ascroll - 1)
    elseif ch == 'g' then O.ascroll = 0
    elseif ch == 'c' and not O.title then O.toggle_log() end
    return true
  end
  local shift = ctx.mods and ctx.mods().shift
  local cur = O.items[O.sel]
  -- число цифрами (5 окт): 0-9 . - копятся, Enter — поставить, Esc / BS — правка
  if cur and cur.kind == 'num' and (ch:match('^[%d%.]$') or (ch == '-' and not O.numbuf)) and not O.typing then
    O.numbuf = (O.numbuf or '') .. ch; return true
  end
  if O.numbuf then
    if c == 13 then
      local v = tonumber(O.numbuf); O.numbuf = nil
      if v and cur then
        if cur.min then v = math.max(cur.min, v) end
        if cur.max then v = math.min(cur.max, v) end
        cur.set(v)
      end
      return true
    elseif c == 8 then O.numbuf = O.numbuf:sub(1, -2); if O.numbuf == '' then O.numbuf = nil end; return true
    elseif c == 27 then O.numbuf = nil; return true end
    O.numbuf = nil
  end
  if O.compact and (ch == '/' or ch == 'f' or c == 9 or ch == '[' or ch == ']') then return true end
  -- поиск: набор прямо в окне
  if O.typing then
    if c == 27 then O.typing = false; O.query = ''; O.rebuild()
    elseif c == 13 then   -- 26 окт: Enter в поиске — сразу менять подсвеченную опцию (не только закрыть поиск)
      O.typing = false
      local it0 = O.items[O.sel]
      if it0 and not it0.sep and not it0.blockrow then
        if it0.masked and it0.masked() then it0.unmask() else O.adjust(it0, 0) end
      end
    elseif c == 8 then O.query = TX.bs(O.query); O.sel = 1; O.rebuild()
    elseif c == 1685026670 then O.sel = math.min(#O.items, O.sel + 1)
    elseif c == 30064 then O.sel = math.max(1, O.sel - 1)
    elseif TX.char(c) then O.query = O.query .. TX.char(c); O.sel = 1; O.rebuild() end
    return true
  end
  if ch == '/' then O.typing = true; O.query = ''; O.rebuild(); return true end
  if ch == 'f' and ctx.opt_hints then ctx.opt_hints(); return true end   -- 31 окт: f — прыжок (метки строк и вкладок опций); поиск — /
  -- 31 окт: Cmd / Ctrl + h l — между вкладками опций (как между панелями)
  if (c == 8 or c == 12) and ctx.mods and (ctx.mods().ctrl or ctx.mods().cmd) then O.step_tab(c == 8 and -1 or 1); return true end
  if (ch == 'h' or ch == 'l') and ctx.mods and ctx.mods().cmd then O.step_tab(ch == 'h' and -1 or 1); return true end
  if c == 9 or ch == ']' then O.step_tab(shift and -1 or 1); return true end
  if c == 25 or ch == '[' then O.step_tab(-1); return true end
  if c == 27 and O.query ~= '' then O.query = ''; O.rebuild(); return true end
  local n = #O.items
  local it = O.items[O.sel]
  -- 14 окт: строка блока (темы и шрифты) — клавиши его владельцу; j / k за край — в список
  if it and it.blockrow and c ~= 27 and ch ~= 'q' then
    local r = it.of.key and it.of.key(c)
    if r == 'down' then
      local i = O.sel; while O.items[i] and O.items[i].blockrow do i = i + 1 end
      while O.items[i] and O.items[i].sep do i = i + 1 end
      O.sel = math.min(n, i)
    elseif r == 'up' then
      local i = O.sel; while O.items[i] and O.items[i].blockrow do i = i - 1 end
      while i > 1 and O.items[i] and O.items[i].sep do i = i - 1 end
      O.sel = math.max(1, i)
    elseif r then O.block_follow = true end
    return true
  end
  if it and it.masked and it.masked() and (c == 13 or ch == ' ' or ch == 'l' or ch == 'h' or ch == '+' or ch == '-') then it.unmask(); return true end
  if c == 27 or ch == 'q' then O.close()
  elseif ch == 'j' or c == 1685026670 then O.sel = math.min(n, O.sel + 1); while O.items[O.sel] and O.items[O.sel].sep and O.sel < n do O.sel = O.sel + 1 end; O.block_follow = true
  elseif ch == 'k' or c == 30064 then O.sel = math.max(1, O.sel - 1); while O.items[O.sel] and O.items[O.sel].sep and O.sel > 1 do O.sel = O.sel - 1 end; O.block_follow = true
  elseif ch == 'g' then O.sel = 1
  elseif ch == 'G' then O.sel = n
  elseif c == 13 or ch == ' ' then O.adjust(it, 0)
  -- 6 окт: h l — шаг, Shift (H L) — мелкий шаг (десятая)
  elseif ch == 'l' or ch == 'L' or ch == '+' or ch == '=' or c == 1919379572 then O.adjust(it, (shift or ch == 'L') and 0.1 or 1)
  elseif ch == 'h' or ch == 'H' or ch == '-' or c == 1818584692 then O.adjust(it, (shift or ch == 'H') and -0.1 or -1)
  elseif ch == '0' and it and it.kind == 'num' and it.min then it.set(it.min)
  end
  return true
end

function O.wheel(d)
  if O.page == 'about' then O.ascroll = math.max(0, O.ascroll - d); return end
  if O.block_hot and O.block_hot.wheel then O.block_hot.wheel(d); return end   -- 31 окт: блок со своей прокруткой (темы, шрифты)
  -- 20 окт: колонки выше окна — колесо мимо строки листает их
  if O.masonry_on and (O.mover or 0) > 0 and not O.hover then
    O.mscroll = math.max(0, math.min(O.mover, (O.mscroll or 0) - d * 3 * (O.rh or 16)))
    return
  end
  local it = O.items[O.hover or O.sel]
  -- список (хоткеи, действия, полоса прокрутки): колесо листает (5 окт)
  if O.sb_hot or not it or it.kind == 'action' or it.kind == 'text' or it.blockrow then
    local nv = O.nvis or 10
    O.scroll = math.max(0, math.min(math.max(0, #O.items - nv), O.scroll - d * 3))
    O.sel = math.max(O.scroll + 1, math.min(O.scroll + nv, O.sel))
    return
  end
  if it and it.masked and it.masked() then return end
  O.adjust(it, d)
end

-- мышь (3 окт): toggle — клик; num — слайдер как в DSP (клик / протяжка);
-- cycle — список значений под ячейкой, повторный клик по ней закрывает
local function num_from_x(it, r, mx)
  local fr = math.max(0, math.min(1, (mx - r[1]) / math.max(1, r[3])))
  local v = (it.min or 0) + fr * ((it.max or 1) - (it.min or 0))
  local st = it.step or 1
  v = (it.min or 0) + math.floor((v - (it.min or 0)) / st + 0.5) * st
  it.set(math.max(it.min or v, math.min(it.max or v, v)))
end

-- ПКМ по строке опции (6 окт): добавить в быстрые опции / убрать оттуда
function O.rclick()
  local it = O.hover and O.items[O.hover]
  if not (it and it.key and not it.sep and (it.kind == 'toggle' or it.kind == 'cycle') and ctx.quick_toggle) then return false end
  ctx.quick_toggle(it.key, it.label)
  return true
end

function O.click(mx, my)
  if O.page == 'about' and O.log_hot then O.toggle_log(); return end   -- 17 окт: кнопка changelog
  if O.page == 'about' and O.link_hot then if ctx.open_url then ctx.open_url(O.link_hot) end; return end
  if O.close_hot and O.page ~= 'about' then O.close(); return end
  if O.tab_hot then O.set_tab(O.tab_hot); return end
  if O.block_hot and O.block_hot.click and O.block_hot.click() then
    for i, it in ipairs(O.items) do if it.blockrow and it.of == O.block_hot then O.sel = i; break end end
    return
  end
  if O.find_hot then O.typing = true; return end
  if O.sb_hot then O.sb_drag = true; return end
  if O.hover then
    O.sel = O.hover
    local it = O.items[O.sel]
    local r = O.vrect and O.vrect[O.sel]
    if it.masked and it.masked() then it.unmask(); return end
    -- cycle (3 окт): значения кнопками в ряд — клик по кнопке ставит его;
    -- кнопки не влезли — клик по строке шагает по кругу, как раньше
    if it.kind == 'cycle' and it.pick then it.pick()   -- 10 окт: щелчок по строке font / theme — выпадашка (31 окт: раньше кнопок — устаревшая кнопка перебивала)
    elseif it.kind == 'cycle' and O.hbtn and O.hbtn.i == O.sel then it.set(it.values[O.hbtn.k])
    elseif it.kind == 'cycle' then O.adjust(it, 1)
    elseif it.kind == 'num' and it.min and it.max and r then
      if mx >= r[1] - 2 and mx < r[1] + r[3] + 2 then O.drag = { i = O.sel }; num_from_x(it, r, mx) end
    else O.adjust(it, 0) end
  end
  if O.box and (mx < O.box[1] or mx > O.box[1] + O.box[3] or my < O.box[2] or my > O.box[2] + O.box[4]) then O.close() end
end

-- отрисовка поверх всего: панель по центру окна
-- about: логотип (jf_tracker_logo.lua рисует сам, по сетке) и версия / изменения
local function draw_about(L, W, H)
  local rh = L.rh
  local LGO = ctx.logo
  local lw = (O.logo and LGO and not O.logo.scroll) and LGO.size(O.logo) * L.cw or 0   -- бегущей строке ширина не нужна
  local bw = math.min(W - 2 * L.pad - 20, math.max(lw, L.cw * 80) + 4 * L.pad)
  local bh = math.min(H - 2 * rh, math.max(rh * 12, H - 6 * rh))
  local bx, by = math.floor((W - bw) / 2), math.floor((H - bh) / 2)
  O.box = { bx, by, bw, bh }
  O.hover = nil                       -- клик по about не должен переключать опции под ним
  U.set(U.BG); gfx.rect(bx, by, bw, bh, 1)
  U.set(U.TEXT); gfx.rect(bx, by, bw, bh, 0)
  -- 17 окт: кнопка changelog (c) справа в шапке — только список изменений, без логотипа и вступления
  local lb = O.ab_log and 'about' or 'changelog'
  local lbw = U.measure(lb) + 2 * L.pad
  local lbx = bx + bw - lbw - L.pad
  O.log_hot = not O.title and gfx.mouse_x >= lbx and gfx.mouse_x < lbx + lbw and gfx.mouse_y >= by + 1 and gfx.mouse_y < by + rh + 1 or nil
  U.text(bx + L.pad, by + 2, ctx.fit((O.title or 'about') .. '   j k / wheel: scroll   c: ' .. lb .. '   Esc: close', lbx - bx - 2 * L.pad), U.AMBER)
  if not O.title then
    U.set(O.log_hot and U.tint(U.AMBER, 0.3) or U.PANEL); gfx.rect(lbx, by + 1, lbw, rh, 1)
    U.set(O.ab_log and U.AMBER or U.LINE); gfx.rect(lbx, by + 1, lbw, rh, 0)
    U.text(lbx + L.pad, by + 2, lb, O.log_hot and U.AMBER or U.TEXT)
  end
  U.set(U.LINE); gfx.rect(bx, by + rh + 2, bw, 1, 1)
  local y = by + rh + 2 + L.pad
  if O.logo and LGO and not O.ab_log then
    -- чёрная плашка с полем в клетку, как в генераторах ANSI; рисуется один
    -- раз в картинку 1022 (дизеринг попиксельный), дальше только blit
    local cw, ch = LGO.cell(O.logo, bw - 2 * L.pad - 4 * L.cw, L.cw, rh)
    if O.logo.scroll then cw, ch = L.cw, rh end          -- бегущая строка: без сжатия
    if cw then
      local w, h = LGO.size(O.logo)
      local iw, ih = (w + 2) * cw, (h + 1) * ch
      local drip_h = O.logo.drip and 4 * ch or 0             -- место для капель под логотипом
      local roles = { text = U.TEXT, accent = U.AMBER, line = U.LINE }
      local key = O.logo.name .. cw .. 'x' .. ch .. (O.logo.native and ('|' .. U.TEXT[1] .. U.AMBER[1] .. U.LINE[1]) or '')
      if O.logo_key ~= key then
        local old = gfx.dest
        gfx.setimgdim(1022, -1, -1); gfx.setimgdim(1022, iw, ih)
        gfx.dest = 1022
        gfx.set(0, 0, 0, 1); gfx.rect(0, 0, iw, ih, 1)
        LGO.draw(O.logo, cw, math.floor(ch / 2), cw, ch, U.AMBER, roles)
        gfx.dest = old
        O.logo_key = key
      end
      if O.logo.scroll then
        -- бегущая строка (3 окт): окно шириной с about едет по картинке по
        -- кругу, между повторами — зазор в ширину окна; ~6 символов в секунду
        local aw = bw - 2 * L.pad
        local per = iw + aw
        local off = math.floor(((ctx.now and ctx.now() or os.clock()) * cw * 6) % per)
        local dx = bx + L.pad
        -- картинка входит справа: экранная x = dx + aw - off
        local sx = dx + aw - off
        local a0, a1 = math.max(dx, sx), math.min(dx + aw, sx + iw)
        if a1 > a0 then gfx.blit(1022, 1, 0, a0 - sx, 0, a1 - a0, ih, a0, y, a1 - a0, ih) end
      else
        local lx0 = bx + math.floor((bw - iw) / 2)
        if O.logo.water then
          -- вода (5 окт): верх — как есть; от середины ряда water вниз (под чёрной
          -- полосой — отражение) — по строке пикселей со сдвигом синусом, глубже —
          -- сильнее; по краям — чёрная плашка, сдвиг не открывает фон
          local t = ctx.now and ctx.now() or os.clock()
          local sy0 = math.floor(ch / 2) + (O.logo.water - 1) * ch + math.floor(ch / 2)
          gfx.blit(1022, 1, 0, 0, 0, iw, sy0, lx0, y, iw, sy0)
          local amp = math.max(1, math.floor(cw * 0.6))
          gfx.set(0, 0, 0, 1); gfx.rect(lx0 - amp, y + sy0, iw + 2 * amp, ih - sy0, 1)
          for py = sy0, ih - 1 do
            local depth = (py - sy0) / math.max(1, ih - sy0)
            local off = math.floor(amp * (0.25 + 0.75 * depth) * math.sin(t * 2.4 + py * 0.45) + 0.5)
            gfx.blit(1022, 1, 0, 0, py, iw, 1, lx0 + off, y + py, iw, 1)
          end
        elseif O.logo.glitch then
          -- глитч (6 окт): короткие вспышки — ряды клеток рывком сдвигаются по
          -- горизонтали на 1..3 клетки, иногда с цветной полосой; между — покой
          local t = ctx.now and ctx.now() or os.clock()
          local cyc = t % 2.2
          local burst = cyc < 0.22 or (cyc > 1.1 and cyc < 1.2)
          gfx.set(0, 0, 0, 1); gfx.rect(lx0 - 3 * cw, y, iw + 6 * cw, ih, 1)
          if not burst then gfx.blit(1022, 1, 0, 0, 0, iw, ih, lx0, y, iw, ih)
          else
            local fr = math.floor(t * 24)
            local y0 = math.floor(ch / 2)
            gfx.blit(1022, 1, 0, 0, 0, iw, y0, lx0, y, iw, y0)
            local rows = math.ceil((ih - y0) / ch)
            for r = 0, rows - 1 do
              local h0 = math.min(ch, ih - y0 - r * ch)
              local rnd = (math.sin((fr + 1) * 12.9898 + r * 78.233) * 43758.5453) % 1
              local off = rnd < 0.45 and math.floor((rnd * 14 - 3) + 0.5) * cw or 0
              gfx.blit(1022, 1, 0, 0, y0 + r * ch, iw, h0, lx0 + off, y + y0 + r * ch, iw, h0)
              if rnd > 0.9 then gfx.set(0.37, 0.72, 0.77, 0.35); gfx.rect(lx0 + off, y + y0 + r * ch, iw, math.max(1, math.floor(h0 / 3)), 1); gfx.a = 1 end
            end
          end
        else
          gfx.blit(1022, 1, 0, 0, 0, iw, ih, lx0, y, iw, ih)
        end
        if O.logo.drip and LGO.drops then
          -- кровь (3 окт): капля растёт из нижнего края буквы, отрывается и
          -- падает блоком с тёмным хвостом, уходит за край; под логотипом — место
          local t = ctx.now and ctx.now() or os.clock()
          local base = y + ih - math.floor(ch / 2)
          local fall = 4 * ch
          local red, dark = LGO.PAL.lightred, LGO.PAL.red
          for _, d in ipairs(LGO.drops(O.logo)) do
            local ph = (t * d.speed + d.phase) % 1
            local x0 = lx0 + d.col * cw + math.floor(cw / 4)
            local dw = math.max(1, math.floor(cw / 2))
            if ph < 0.35 then
              -- набухает: потёк вниз от буквы
              local h = math.floor(ph / 0.35 * ch)
              gfx.set(dark[1], dark[2], dark[3], 1); gfx.rect(x0, base, dw, h + 1, 1)
            else
              local yy = base + math.floor((ph - 0.35) / 0.65 * fall)
              gfx.set(dark[1], dark[2], dark[3], 0.6); gfx.rect(x0, yy - math.floor(ch / 2), dw, math.floor(ch / 2), 1)
              gfx.set(red[1], red[2], red[3], 1); gfx.rect(x0, yy, dw, math.max(2, math.floor(ch / 2)), 1)
            end
          end
          gfx.a = 1
        end
        if O.logo.glint then
          -- блик по металлу (5 окт): косая полоса света идёт по буквам — та же
          -- картинка поверх себя, сложением: светлеют только линии, чёрное
          -- остаётся чёрным; мышь над логотипом — блик идёт за ней
          local t = ctx.now and ctx.now() or os.clock()
          local band = math.max(cw * 3, math.floor(iw / 14))
          local over = gfx.mouse_x >= lx0 and gfx.mouse_x < lx0 + iw and gfx.mouse_y >= y and gfx.mouse_y < y + ih
          local cx = over and (gfx.mouse_x - lx0) or (((t % 3.5) / 3.5) * (iw + 2 * band + ih) - band - ih / 2)
          local m0, a0 = gfx.mode, gfx.a
          gfx.mode = 1                                         -- сложение
          local step = 2
          for py = 0, ih - 1, step do
            local x0 = math.floor(cx - band / 2 + (ih / 2 - py) * 0.6)   -- наклон полосы
            local sx0, sx1 = math.max(0, x0), math.min(iw, x0 + band)
            if sx1 > sx0 then
              -- к краям полосы — слабее: три ступени яркости
              for k = 0, 2 do
                local inset = math.floor(k * band / 6)
                local a1, b1 = math.max(sx0, x0 + inset), math.min(sx1, x0 + band - inset)
                if b1 > a1 then gfx.a = 0.28; gfx.blit(1022, 1, 0, a1, py, b1 - a1, step, lx0 + a1, y + py, b1 - a1, step) end
              end
            end
          end
          gfx.mode, gfx.a = m0, a0
        end
        if O.logo.pulse then
          -- перелив (3 окт): медленная волна по столбцам — от полной яркости до
          -- чёрного; поверх готовой картинки полупрозрачные чёрные полосы
          local t = ctx.now and ctx.now() or os.clock()
          local ncol = math.floor(iw / cw)
          for k = 0, ncol - 1 do
            local a = 0.5 - 0.5 * math.cos(t * 0.9 - k * 0.18)
            if a > 0.02 then gfx.set(0, 0, 0, a); gfx.rect(lx0 + k * cw, y, cw, ih, 1) end
          end
          gfx.a = 1
        end
      end
      y = y + ih + drip_h + L.pad
    else
      if not O.title then U.text(bx + L.pad, y, ctx.fit(LGO.SHORT, bw - 2 * L.pad), U.AMBER); y = y + rh + L.pad end   -- tutorial — без логотипа
    end
  end
  -- перенос по словам под ширину окна (продолжение — с отступом пункта);
  -- пересчёт только при смене ширины или текста
  local tw = bw - 2 * L.pad
  if O.wrap_w ~= tw or O.wrap_src ~= O.about then
    local out = {}
    for _, s in ipairs(O.about or {}) do
      local col = s:match('^%d+%.%d') and U.AMBER or (s:match('^jf_tracker') and U.CYAN or U.TEXT)
      local ind = s:match('^(%s*%-?%s*)') or ''
      local cur = ''
      for w in s:gmatch('%S+') do
        local try = cur == '' and (s:match('^%s*') .. w) or (cur .. ' ' .. w)
        if cur ~= '' and U.measure(try) > tw then
          out[#out + 1] = { cur, col }; cur = (' '):rep(#ind) .. w
        else cur = try end
      end
      out[#out + 1] = { cur, col }
    end
    O.wrapped, O.wrap_w, O.wrap_src = out, tw, O.about
  end
  local lines = O.wrapped
  O.about_n = #lines
  O.link_hot = nil
  local nv = math.floor((by + bh - y) / rh)
  for r = 1, nv do
    local l = lines[O.ascroll + r]
    if not l then break end
    local ly = y + (r - 1) * rh
    -- ссылка (4 окт): https://… — кликабельна, под мышью подчёркнута
    -- e-mail (6 окт) — тоже ссылка: клик открывает mailto:
    local url = l[1]:match('(https?://%S+)') or l[1]:match('([%w%._%-]+@[%w%-]+%.[%w%.%-]+)')
    if url then
      local pre = l[1]:sub(1, l[1]:find(url, 1, true) - 1)
      local ux, uw = bx + L.pad + U.measure(pre), U.measure(url)
      local hot = gfx.mouse_x >= ux and gfx.mouse_x < ux + uw and gfx.mouse_y >= ly and gfx.mouse_y < ly + rh
      U.text(bx + L.pad, ly, pre, l[2])
      U.text(ux, ly, url, hot and U.AMBER or U.CYAN)
      U.set(hot and U.AMBER or U.CYAN); gfx.rect(ux, ly + rh - 2, uw, 1, 1)
      if hot then O.link_hot = url:find('://', 1, true) and url or ('mailto:' .. url) end
    else
      U.text(bx + L.pad, ly, ctx.fit(l[1], tw), l[2])
    end
  end
end

-- 15 окт: раскладка кирпичами: разделы (заголовок sep с title … до следующего) — рамками в колонки;
-- → { place = { {i, x, y, w} }, frames = { {x, y, w, h, title, i0, i1} } } или nil (не влезает / поиск / хоткеи)
function O.masonry_plan(L, bx, y0, bw, ch)
  O.side_ok = false
  if O.compact or O.query ~= '' then return nil end
  local rh, pad = L.rh, L.pad
  local secs, cur = {}, nil
  for i, it in ipairs(O.items) do
    if it.sep then
      if it.title and it.title ~= '' then cur = { title = it.title, rows = {} }; secs[#secs + 1] = cur end
    elseif it.hk then return nil                       -- хоткеи — длинный список: одной колонкой
    else
      if not cur then cur = { title = '', rows = {} }; secs[#secs + 1] = cur end
      cur.rows[#cur.rows + 1] = i
    end
  end
  -- 15 окт: раздел-блок (темы и шрифты) — не колонкой: в узкой колонке карточки тем по одной
  -- в ряд, блок выше экрана; он занимает всю ширину справа от колонок опций
  -- 31 окт: блок side (шрифты) — под колонками опций на всю оставшуюся высоту (слева много места); не влез — его
  -- содержимое рисует широкий блок (O.side_ok = false)
  local list, wide, side = {}, nil, nil
  for _, sc in ipairs(secs) do
    if #sc.rows > 0 then
      local it = O.items[sc.rows[1]]
      if it.blockrow and it.of.side then side = side or { sc = sc, blk = it.of }
      elseif it.blockrow and not wide then wide = { sc = sc, blk = it.of } else list[#list + 1] = sc end
    end
  end
  if #list == 0 then return nil end
  local colw = O.roww or (L.cw * 56)
  local fw = colw + 2 * pad                            -- рамка: строка + поля
  local gap = 2 * pad
  local ncols = math.max(1, math.floor((bw - 2 * pad + gap) / (fw + gap)))
  -- 15 окт: раздел выше колонки не отменяет раскладку — продолжается рамкой в следующей колонке;
  -- рвётся только между строками, блок — целиком
  for _, sc in ipairs(list) do
    sc.atoms = {}
    for _, i in ipairs(sc.rows) do
      local it, last = O.items[i], sc.atoms[#sc.atoms]
      if it.blockrow and last and last.of == it.of then last[#last + 1] = i
      else sc.atoms[#sc.atoms + 1] = { i, of = it.blockrow and it.of or nil } end
    end
  end
  local function fh(n) return (n + 1) * rh + 6 end    -- строка заголовка + строки + низ рамки
  -- по порядку: раздел — в текущую колонку; не влез — остаток в следующую (та же подпись)
  local function pack(hmax, maxc)
    local cols, ci, yy = { {} }, 1, 0
    for _, sc in ipairs(list) do
      local fr = nil
      -- 31 окт: раздел, что целиком влезает в колонку, не рвётся — переходит в следующую колонку весь
      local tot = fh(#sc.rows)
      if yy > 0 and yy + tot > hmax and tot <= hmax then ci = ci + 1; yy = 0; cols[ci] = {}; if ci > maxc then return nil end end
      for _, a in ipairs(sc.atoms) do
        if fh(#a) > hmax then return nil end
        local n = fr and #fr.rows or 0
        if not fr or fr.y + fh(n + #a) > hmax then
          if fr then yy = fr.y + fh(n) + 6 end
          if yy > 0 and yy + fh(#a) > hmax then ci = ci + 1; yy = 0; cols[ci] = {} end
          if ci > maxc then return nil end
          fr = { sc = sc, y = yy, rows = {} }
          cols[ci][#cols[ci] + 1] = fr
        end
        for _, i in ipairs(a) do fr.rows[#fr.rows + 1] = i end
      end
      if fr then yy = fr.y + fh(#fr.rows) + 6 end
    end
    return cols
  end
  -- с блоком: колонок опций — сколько нужно на всю высоту, остальное блоку (не уже одной колонки)
  local maxc = ncols
  if wide then
    maxc = nil
    for k = 1, ncols - 1 do if pack(ch, k) then maxc = k; break end end
    if not maxc then return nil end
  end
  -- наименьшая высота колонок, при которой всё влезает (колонки ровнее, низ окна свободнее);
  -- с блоком справа колонки во всю высоту — ровнять незачем
  local lo, hi = 0, ch
  -- 20 окт: не влезло по высоте — колонки всё равно на всю ширину (тёмное пустое не оставлять), выше окна;
  -- лишнее — вертикальной прокруткой O.mscroll (колесо, курсор j k), а не одним столбцом
  local over = 0
  if not pack(hi, maxc) then
    if wide then return nil end
    local top = hi
    while not pack(top, maxc) do top = top * 2; if top > 400000 then return nil end end
    lo, hi = ch, top
    for _ = 1, 24 do local mid = math.floor((lo + hi) / 2); if pack(mid, maxc) then hi = mid else lo = mid + 1 end; if lo >= hi then break end end
    over = hi - ch
  end
  if not wide and over == 0 then
    -- 31 окт: колонки не ниже самого длинного раздела (если он влезает в окно) — разделы модулей одной рамкой
    for _, sc in ipairs(list) do local t = fh(#sc.rows); if t <= ch and t > lo and pack(math.max(hi, t), maxc) then lo = t end end
    if lo > hi then hi = lo end
    for _ = 1, 20 do local mid = math.floor((lo + hi) / 2); if pack(mid, maxc) then hi = mid else lo = mid + 1 end; if lo >= hi then break end end
  end
  local cols = pack(hi, maxc)
  local place, frames = {}, {}
  for c, col in ipairs(cols) do
    local x = bx + pad + (c - 1) * (fw + gap)
    for _, e in ipairs(col) do
      local fy = y0 + e.y
      frames[#frames + 1] = { x = x, y = fy, w = fw, h = fh(#e.rows), title = e.sc.title, i0 = e.rows[1], i1 = e.rows[#e.rows] }
      for k, i in ipairs(e.rows) do place[#place + 1] = { i = i, x = x + pad, y = fy + k * rh + 2, w = colw - 2 * pad } end
    end
  end
  if side and wide and over == 0 then
    local bot = 0
    for _, col in ipairs(cols) do local e = col[#col]; if e then bot = math.max(bot, e.y + fh(#e.rows) + 6) end end
    local r = side.sc.rows
    if ch - bot >= 8 * rh then
      frames[#frames + 1] = { x = bx + pad, y = y0 + bot, w = #cols * (fw + gap) - gap, h = ch - bot, title = side.sc.title, i0 = r[1], i1 = r[#r], block = side.blk }
      O.side_ok = true
    end
  end
  if wide then
    local x = bx + pad + #cols * (fw + gap)
    local r = wide.sc.rows
    frames[#frames + 1] = { x = x, y = y0, w = bx + bw - pad - x, h = ch, title = wide.sc.title, i0 = r[1], i1 = r[#r], block = wide.blk }
  end
  table.sort(place, function(a, b) return a.i < b.i end)
  if over > 0 then
    O.mscroll = math.max(0, math.min(over, O.mscroll or 0))
    -- выбранная строка — в окне
    for _, pl in ipairs(place) do
      if pl.i == O.sel then
        local yv = pl.y - O.mscroll
        if yv < y0 + rh then O.mscroll = math.max(0, pl.y - y0 - rh)
        elseif yv + rh > y0 + ch then O.mscroll = math.min(over, pl.y + rh - y0 - ch) end
        break
      end
    end
    local sc0 = O.mscroll
    local vis = {}
    for _, pl in ipairs(place) do
      pl.y = pl.y - sc0
      if pl.y >= y0 and pl.y + rh <= y0 + ch then vis[#vis + 1] = pl end
    end
    place = vis
    for _, fr in ipairs(frames) do
      local a, b = fr.y - sc0, fr.y - sc0 + fr.h
      fr.y, fr.h = math.max(a, y0 - math.floor(rh / 2)), math.min(b, y0 + ch) - math.max(a, y0 - math.floor(rh / 2))
      if a < y0 - math.floor(rh / 2) then fr.title = nil end           -- заголовок уехал вверх — рамка без подписи
      if fr.h <= rh then fr.h = 0 end
    end
    local fv = {}
    for _, fr in ipairs(frames) do if fr.h > 0 then fv[#fv + 1] = fr end end
    frames = fv
  else O.mscroll = 0 end
  O.mover = over
  return { place = place, frames = frames, ncols = #cols, over = over }
end

function O.draw(L, W, H)
  if not O.active then return end
  if O.page == 'about' then return draw_about(L, W, H) end
  local rh = L.rh
  local n = #O.items
  local lw, vw = L.cw * 22, L.cw * 12
  local dw = 0
  for _, it in ipairs(O.items) do
    if it.kind == 'cycle' and not it.dropdown then   -- 20 окт: dropdown — значение и «v», ширину не раздувает
      local tot = 0
      for _, v in ipairs(it.values) do tot = tot + U.measure(tostring(v)) + 2 * L.pad + 2 end
      dw = math.max(dw, tot - vw)
    end
  end
  local bw = math.min(W - 2 * L.pad - 20, math.max(lw + vw + dw + 3 * L.pad, L.cw * 72))
  -- 9 окт: опции — в 2-3 колонки, если хватает ширины (строки сверху вниз,
  -- потом следующая колонка; j k идут по порядку); хоткеи — одной колонкой
  local colw0 = math.max(lw + vw + math.min(dw, L.cw * 24) + 3 * L.pad, L.cw * 56)   -- длинный цикл (темы) — текстом, колонку не раздувает
  -- 9 окт: поиск размер окна не меняет — ширина как без поиска (результаты
  -- одной колонкой), высота — по самому длинному списку без фильтра (O.nfull),
  -- не меньше 12 строк; что не влезло — скроллом
  -- 14 окт: одной колонкой со скроллом (колонки по ширине убраны)
  local ncw = 1
  O.roww = colw0
  local ncol = O.query == '' and ncw or 1
  O.nfull = O.nfull or {}                                -- по вкладке: хоткеи длиннее опций
  local tk = tostring(O.tab or '')
  if O.query == '' then O.nfull[tk] = math.max(O.nfull[tk] or 0, n) end
  local rows = math.max(12, math.ceil((O.nfull[tk] or n) / ncw), math.ceil(n / ncol))
  local nvis = math.max(3, math.min(rows, math.floor((H - 6 * rh) / rh)))
  local nvis2 = math.max(3, nvis - 1 - ((#O.tabs > 0) and 1 or 0))   -- вкладки — своей строкой над поиском
  nvis = nvis2
  -- 13 окт: окно опций — одного размера на всех вкладках, почти во всё окно (раньше прыгало по вкладкам)
  if not O.compact then
    -- 18 окт: в полтора раза меньше окна трекера (просьба: трекер вокруг виден)
    -- 31 окт: не влезло в полтора раза меньшее окно — на всё окно (всё сразу на экране), остаток — прокруткой с полосой
    local k = (O.big and O.tab == O.big_tab) and 1.02 or 1.5
    bw = math.floor((W - 4 * L.pad) / k)
    nvis = math.max(3, math.floor((H - 4 * L.pad) / k / rh) - 5 - ((#O.tabs > 0) and 1 or 0))
  end
  local bh = (nvis + 5 + ((#O.tabs > 0) and 1 or 0)) * rh   -- 14 окт: +1 строка — поиск в 2 строки
  local bx, by = math.floor((W - bw) / 2), math.floor((H - bh) / 2)
  if O.compact then
    nvis = math.min(n, math.floor((H - 4 * rh) / rh))
    bw = math.min(W - 2 * L.pad, math.max(lw + vw + 3 * L.pad + L.cw * 12, L.cw * 52))
    bh = (nvis + 2) * rh + 4
    bx = math.max(L.pad, math.min(W - bw - L.pad, O.compact.x or bx))
    by = math.max(2, math.min(H - bh - 2, O.compact.y or by))
  end
  O.box = { bx, by, bw, bh }
  local cap = nvis * ncol
  if O.sel - 1 < O.scroll then O.scroll = O.sel - 1 end
  if O.sel > O.scroll + cap then O.scroll = O.sel - cap end
  U.set(U.BG); gfx.rect(bx, by, bw, bh, 1)
  U.set(U.TEXT); gfx.rect(bx, by, bw, bh, 0)
  U.text(bx + L.pad, by + 2, ctx.fit(O.compact and O.compact.title or 'options', bw - 2 * L.pad - U.measure('x') - 2 * L.pad), U.AMBER)
  -- крестик закрытия в правом углу (3 окт)
  do
    local cw2 = U.measure('x') + 2 * L.pad
    local cx = bx + bw - cw2 - 1
    local hot = gfx.mouse_x >= cx and gfx.mouse_x < cx + cw2 and gfx.mouse_y >= by + 1 and gfx.mouse_y < by + 1 + rh
    O.close_hot = hot
    U.set(hot and U.tint(U.RED, 0.4) or U.BG); gfx.rect(cx, by + 1, cw2, rh, 1)
    U.text(cx + L.pad, by + 2, 'x', hot and U.TEXT or U.GREY)
  end
  local hx = bx + L.pad + U.measure('options') + 3 * L.pad
  if not O.compact then
    local hs = #O.tabs > 0 and 'j k: row   Enter / h l: change   Tab: next tab   /: find   Esc: close' or 'j k: row   Enter / h l: change   /: find   Esc: close'
    local hw = bx + bw - L.pad - hx - U.measure('x') - 3 * L.pad   -- до крестика
    if U.hint_text then U.hint_text(hx, by + 2, hs, hw, U.BG) else U.text(hx, by + 2, ctx.fit(hs, hw), U.GREY) end   -- 15 окт: стандарт подсказок
  end
  U.set(U.LINE); gfx.rect(bx, by + rh + 2, bw, 1, 1)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  -- вкладки (5 окт) и поле поиска справа; не влезают — по ширине, до поиска
  O.tab_hot, O.find_hot = nil, nil
  if not O.compact then
    local ty = by + rh + 4
    -- поиск (5 окт): строка ввода слева, широкая; 14 окт — в 2 строки, пустая — подсказка
    -- призрачным цветом, как начать искать
    local fq = O.typing and ('/' .. O.query .. '_') or (O.query ~= '' and ('/' .. O.query) or '/')
    local fw = math.max(math.floor(bw * 2 / 3), U.measure(fq) + 2 * L.pad)
    local fx = bx + L.pad
    -- вкладки — строкой над поиском (5 окт)
    local tx = bx + L.pad
    local fy = ty + ((#O.tabs > 0) and rh or 0)
    for _, t in ipairs(O.tabs) do
      local w = U.measure(t) + 2 * L.pad
      if tx + w > bx + bw - L.pad then break end
      local on = t == O.tab and O.query == ''
      local hot = mx >= tx and mx < tx + w and my >= ty and my < ty + rh
      if hot then O.tab_hot = t end
      if ctx.hint then ctx.hint('opttab', tx, ty, w, rh - 1, t) end   -- 31 окт: f-прыжок на вкладку опций
      U.set(on and U.tint(U.AMBER, 0.35) or (hot and U.PANEL or U.BG)); gfx.rect(tx, ty, w, rh - 1, 1)
      U.set(on and U.AMBER or (hot and U.TEXT or U.LINE)); gfx.rect(tx, ty, w, rh - 1, 0)
      U.text(tx + L.pad, ty, t, on and U.AMBER or (hot and U.TEXT or U.GREY))
      tx = tx + w + 2
    end
    local fh = 2 * rh
    local fhot = mx >= fx and mx < fx + fw and my >= fy and my < fy + fh
    if fhot then O.find_hot = true end
    U.set(O.typing and U.tint(U.AMBER, 0.25) or (fhot and U.PANEL or U.BG)); gfx.rect(fx, fy, fw, fh - 1, 1)
    U.set((O.typing or O.query ~= '') and U.AMBER or U.LINE); gfx.rect(fx, fy, fw, fh - 1, 0)
    local ty3 = fy + math.floor((fh - rh) / 2)
    U.text(fx + L.pad, ty3, fq, (O.typing or O.query ~= '') and U.AMBER or U.GREY)
    if O.query == '' then
      local gx = fx + L.pad + U.measure(fq) + L.pad
      local hk = O.tab == 'hotkeys'   -- 16 окт: поиск — по своей вкладке
      local ghost = O.typing and (hk and 'a key or a word: dd, macro, slice   Enter: keep   Esc: clear' or 'letters in order: pnc finds pan column, a space splits words   Enter: keep   Esc: clear')
        or (hk and 'press / or f, then type: finds hotkeys by key, module and description' or 'press / or f anywhere here, or click - then type: letters in order find the option')
      U.text(gx, ty3, ctx.fit(ghost, fx + fw - L.pad - gx), U.DIM)
    end
  end
  local by0 = by
  if not O.compact then by = by + rh * ((#O.tabs > 0) and 3 or 2) end   -- список — под вкладками и поиском (2 строки)
  O.nvis = cap
  local masonry = O.masonry_plan(L, bx, by + rh + 4, bw - 8, nvis * rh)   -- 15 окт: разделы рамками в колонки (см. O.masonry_plan)
  if masonry and masonry.over > 0 and not O.compact and not O.big then O.big, O.big_tab = true, O.tab end   -- 31 окт: следующий кадр — на всё окно
  -- 31 окт: полоса прокрутки справа, когда всё не влезло (колесо / j k)
  if masonry and masonry.over > 0 then
    local ty, th = by + rh + 4, nvis * rh
    local tot = th + masonry.over
    local kh = math.max(rh, math.floor(th * th / tot))
    local ky = ty + math.floor((th - kh) * (O.mscroll or 0) / math.max(1, masonry.over))
    U.set(U.LINE); gfx.rect(bx + bw - 6, ty, 3, th, 1)
    U.set(U.AMBER); gfx.rect(bx + bw - 7, ky, 5, kh, 1)
  end
  if masonry then O.scroll = 0 end
  -- полоса прокрутки списка (5 окт): хоткеев сотни
  O.sb_hot = nil
  local sbw = 0
  if #O.items > cap and not masonry then
    sbw = 7
    local sx, sy, sh = bx + bw - sbw - 2, by + rh + 4, nvis * rh
    local th = math.max(8, math.floor(sh * cap / #O.items))
    local maxs = math.max(1, #O.items - cap)
    if O.sb_drag then
      if gfx.mouse_cap & 1 == 1 then
        local f = math.max(0, math.min(1, (my - sy - th / 2) / math.max(1, sh - th)))
        O.scroll = math.floor(f * maxs + 0.5); O.sel = math.max(O.scroll + 1, math.min(O.scroll + cap, O.sel))
      else O.sb_drag = nil end
    end
    local ty2 = sy + math.floor((sh - th) * math.min(1, O.scroll / maxs))
    O.sb_hot = mx >= sx - 2 and mx < sx + sbw + 2 and my >= sy and my < sy + sh
    U.set(U.DIM); gfx.rect(sx + 3, sy, 1, sh, 1)
    U.set((O.sb_hot or O.sb_drag) and U.AMBER or U.LINE); gfx.rect(sx, ty2, sbw, th, 1)
  end
  O.sbw = sbw
  O.hover = nil
  O.hbtn = nil
  O.vrect = {}
  -- протяжка слайдера: пока кнопка мыши держится
  if O.drag then
    if gfx.mouse_cap & 1 == 1 and O.vrect_last and O.vrect_last[O.drag.i] then num_from_x(O.items[O.drag.i], O.vrect_last[O.drag.i], mx)
    else O.drag = nil end
  end
  local colw = math.floor(bw / ncol)
  O.rh = rh
  O.block_hot = nil
  -- 15 окт: места — где рисовать строку i: { i, x, y, w }. Опции без поиска — разделы рамками,
  -- кирпичами в колонки по ширине окна (всё на одном экране, высота колонок — наименьшая, при которой
  -- влезает по порядку); не влезает — прежний список со скроллом
  local place, frames = {}, nil
  if masonry then
    place, frames = masonry.place, masonry.frames
  else
    for r = 1, cap do
      local i = O.scroll + r
      if not O.items[i] then break end
      local col, rr = (r - 1) // nvis, (r - 1) % nvis
      local x, w = bx + col * colw, (col == ncol - 1) and (bw - col * colw) or (colw - L.pad)
      place[#place + 1] = { i = i, x = x, y = by + rh + 4 + rr * rh, w = (O.tab == 'hotkeys' or O.tab == 'theme' or O.tab == 'fx commands') and w or math.min(w, O.roww or w) }   -- 17 окт: хоткеи — во всю ширину (описания резались); 18 окт: и theme
    end
  end
  O.masonry_on = masonry and true or nil
  -- 14 окт: блок — строки подряд; рисуется один раз с первой видимой его строки
  local drawn_block = {}
  for pi, pl in ipairs(place) do
    local it0 = O.items[pl.i]
    if it0 and it0.blockrow and not drawn_block[it0.of] then
      drawn_block[it0.of] = true
      local nb = 0
      while place[pi + nb] and O.items[place[pi + nb].i] and O.items[place[pi + nb].i].blockrow and O.items[place[pi + nb].i].of == it0.of do nb = nb + 1 end
      local yb, r = pl.y, pi
      local blk = it0.of
      local bx, bw = pl.x, pl.w + 2 * L.pad - (masonry and 0 or (sbw + 2))
      if blk.draw then
        local _, sy0, sy1 = blk.draw(bx + L.pad, yb, bw - 2 * L.pad, nb * rh, (it0.k - 1) * rh)
        if mx >= bx and mx < bx + bw and my >= yb and my < yb + nb * rh then O.block_hot = blk end
        -- выбор внутри блока виден: список листается за ним
        local cur = O.items[O.sel]
        if O.block_follow and not masonry and cur and cur.blockrow and cur.of == blk and sy0 then
          O.block_follow = nil
          local first = O.scroll + r - (it0.k - 1)
          local r0, r1 = first + math.floor(sy0 / rh), first + math.ceil(sy1 / rh)
          if r0 <= O.scroll then O.scroll = math.max(0, r0 - 1) elseif r1 > O.scroll + cap then O.scroll = r1 - cap end
          O.sel = math.max(O.scroll + 1, math.min(O.scroll + cap, r0))
        end
      end
    end
  end
  -- высота блока поменялась (ширина окна, шрифт) — строки пересобрать
  for _, it in ipairs(O.all or {}) do
    if it.kind == 'block' and it.height and it.nrows and it.nrows ~= math.max(4, math.ceil(it.height() / rh)) then O.rebuild() end
  end
  -- рамки разделов: под строками; раздел с выбранной строкой — акцентом (фокус)
  for _, fr in ipairs(frames or {}) do
    local foc = O.sel >= fr.i0 and O.sel <= fr.i1
    local ty = fr.y + math.floor(rh / 2)
    U.set(foc and U.AMBER or U.LINE); gfx.rect(fr.x, ty, fr.w, fr.h - math.floor(rh / 2), 0)
    if fr.title and fr.title ~= '' then
      local tw = U.measure(fr.title) + 2 * L.pad
      U.set(U.BG); gfx.rect(fr.x + L.pad, fr.y, tw, rh, 1)
      U.text(fr.x + 2 * L.pad, fr.y + 1, fr.title, foc and U.AMBER or U.CYAN)
    end
  end
  -- 15 окт: блок справа (темы и шрифты) — рамкой во всю высоту, рисует владелец со своей прокруткой
  for _, fr in ipairs(frames or {}) do
    if fr.block and fr.block.draw then
      local x, y, w, h = fr.x + L.pad, fr.y + rh + 2, fr.w - 2 * L.pad, fr.h - rh - 6
      fr.block.draw(x, y, w, h, nil)
      if mx >= x and mx < x + w and my >= y and my < y + h then O.block_hot = fr.block end
    end
  end
  for _, pl in ipairs(place) do
    local i = pl.i
    local it = O.items[i]
    if not it then break end
    local y = pl.y
    -- колонка: свои x и ширина (13 окт: строка — по содержимому, не до края окна)
    local bx, bw = pl.x, pl.w
    if it.blockrow then
    elseif it.sep then
      -- раздел (4 окт): заголовок темы, иначе — тонкая линия
      if it.gap then                                  -- 10 окт: пустая строка перед разделом
      elseif it.title then U.text(bx + L.pad, y + 1, it.title, U.CYAN); U.set(U.DIM); gfx.rect(bx + L.pad + U.measure(it.title) + L.pad, y + math.floor(rh / 2), bw - 3 * L.pad - U.measure(it.title), 1, 1)
      else U.set(U.DIM); gfx.rect(bx + L.pad, y + math.floor(rh / 2), bw - 2 * L.pad, 1, 1) end
    else
      local hot = mx >= bx and mx < bx + bw and my >= y and my < y + rh
      if hot then O.hover = i end
      if ctx.hint then ctx.hint('optrow', bx, y, bw, rh, i) end   -- 31 окт: f-прыжок на строку опций
      if i == O.sel then U.set(U.tint(U.AMBER, 0.25)); gfx.rect(bx + 1, y, bw - 2, rh, 1)
      elseif hot then U.set(U.PANEL); gfx.rect(bx + 1, y, bw - 2, rh, 1) end
      local masked = it.masked and it.masked()
      U.text(bx + L.pad, y + 1, ctx.fit(it.label, lw - L.pad), masked and U.DIM or ((i == O.sel or hot) and U.AMBER or U.TEXT))   -- 6 окт: фокус / мышь — имя жёлтым
      -- 6 окт: точка слева от имени — опция есть в быстрых опциях (ПКМ по имени)
      if it.key and ctx.quick_has and ctx.quick_has(it.key) then U.set(U.LINE); gfx.rect(bx + math.floor(L.pad / 2) - 1, y + math.floor(rh / 2) - 1, 2, 2, 1) end
      local vt = val_text(it)
      local on = it.kind == 'toggle' and it.get()
      local vx = bx + L.pad + lw
      O.vrect[i] = { vx, y, vw - L.pad, rh }
      if masked then
        -- перекрыто text only (4 окт): вместо значения — предупреждение
        U.text(vx, y + 1, ctx.fit('text only is on - click turns it off', bx + bw - L.pad - vx), hot and U.AMBER or U.DIM)
      elseif it.kind == 'num' and it.min and it.max then
        -- слайдер как в DSP: тонкая дорожка, заливка до значения, число справа
        local tw = math.max(8, vw - L.pad - U.measure(vt) - L.pad)
        O.vrect[i] = { vx, y, tw, rh }
        local fr = math.max(0, math.min(1, ((it.get() or 0) - it.min) / math.max(1e-9, it.max - it.min)))
        local cy = y + math.floor(rh / 2)
        local shot = (hot and mx < vx + tw + 2 and mx >= vx - 2) or (O.drag and O.drag.i == i)
        U.set(U.DIM); gfx.rect(vx, cy - 1, tw, 2, 1)
        local foc = shot or hot or i == O.sel                  -- 6 окт: фокус — дорожка, значение, имя жёлтым
        U.set(foc and U.AMBER or U.TEXT); gfx.rect(vx, y + 4, math.max(1, math.floor(fr * tw + 0.5)), rh - 8, 1)
        if O.numbuf and i == O.sel then vt = O.numbuf .. '_' end
        U.text(vx + tw + L.pad, y + 1, vt, foc and U.AMBER or U.TEXT)
      elseif it.kind == 'cycle' then
        -- все значения кнопками в ряд до правого края (описание — внизу при наведении)
        local room = bx + bw - L.pad - vx
        local tot = 0
        for _, v in ipairs(it.values) do tot = tot + U.measure(tostring(v)) + 2 * L.pad + 2 end
        if it.swatch then   -- 31 окт: квадратики цветов (cursor accent): щелчок / h l — выбор, без выпадашки
          local cur = it.get()
          local sw = rh - 2
          local x = vx
          for k, v in ipairs(it.values) do
            local on2 = v == cur
            local h2 = mx >= x and mx < x + sw and my >= y and my < y + rh
            if h2 then O.hbtn = { i = i, k = k } end
            local c = v == 'grey' and U.GREY or ctx.hex_rgb(v) or U.GREY
            if v == 'grey' then U.set(c) else gfx.set(c[1], c[2], c[3], 1) end   -- 31 окт: настоящий цвет — мимо фильтра темы (в красной теме все были красными)
            gfx.rect(x + 1, y + 2, sw - 2, sw - 2, 1)
            U.set(on2 and U.AMBER or (h2 and U.TEXT or U.LINE)); gfx.rect(x, y + 1, sw, sw, 0)
            if on2 then gfx.rect(x - 1, y, sw + 2, sw + 2, 0) end
            x = x + sw + 3
          end
        elseif tot <= room and not it.dropdown then
          local cur = it.get()
          local x = vx
          for k, v in ipairs(it.values) do
            local lb = tostring(v)
            local w = U.measure(lb) + 2 * L.pad
            local on2 = v == cur
            local h2 = mx >= x and mx < x + w and my >= y and my < y + rh
            if h2 then O.hbtn = { i = i, k = k } end
            U.set(on2 and U.tint(U.AMBER, 0.35) or (h2 and U.PANEL or U.BG)); gfx.rect(x, y + 1, w, rh - 1, 1)
            -- 5 окт: на 1 px выше дна строки — снизу текста пусто, как у кнопок главного модуля
            U.set(on2 and U.AMBER or (h2 and U.TEXT or U.LINE)); gfx.rect(x, y + 1, w, rh - 1, 0)
            U.text(x + L.pad, y + 1, lb, on2 and U.AMBER or (h2 and U.TEXT or U.GREY))
            x = x + w + 2
          end
        else
          U.text(vx, y + 1, ctx.fit(vt .. (it.dropdown and '  v' or ''), room), U.TEXT)
        end
      elseif it.hk then
        -- хоткей (5 окт): модуль узкой колонкой, описание — своей колонкой до края
        -- 17 окт: колонка модуля — по самому длинному имени (не больше 26 знаков; было 12 — «panes (tmux»)
        if O.hk_mw_n ~= #O.items or O.hk_mw_cw ~= L.cw then
          local m = 0
          for _, e in ipairs(O.items) do if e.hk then m = math.max(m, U.measure(tostring(e.value or ''))) end end
          O.hk_mw, O.hk_mw_n, O.hk_mw_cw = math.min(m + 2 * L.pad, L.cw * 26), #O.items, L.cw
        end
        local mw = math.max(L.cw * 12, O.hk_mw)
        U.text(vx, y + 1, ctx.fit(vt, mw - L.pad), U.GREY)
        U.text(vx + mw, y + 1, ctx.fit(it.desc or '', bx + bw - L.pad - (O.sbw or 0) - vx - mw), U.TEXT)
      else
        U.text(vx, y + 1, ctx.fit(vt, vw - L.pad), on and U.CYAN or (it.kind == 'toggle' and U.GREY or U.TEXT))
      end
    end
  end
  O.vrect_last = O.vrect
  if O.compact then O.vrect_last = O.vrect; return end
  U.set(U.LINE); gfx.rect(bx, by0 + bh - rh - 2, bw, 1, 1)
  -- описание — строки под мышью, иначе выбранной клавишами
  local it = O.items[O.hover or O.sel]
  U.text(bx + L.pad, by0 + bh - rh, ctx.fit(it and it.desc or '', bw - 2 * L.pad), U.GREY)   -- описания короткие (3 окт), в строку
end

return O
