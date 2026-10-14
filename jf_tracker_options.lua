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
    -- поиск — только в открытой вкладке (5 окт)
    local grp = 'options'
    for _, it in ipairs(O.all) do
      if it.sep then grp = it.group or 'options' end
      if not it.sep and (#O.tabs == 0 or grp == O.tab) and fuzzy((it.label or '') .. ' ' .. (it.desc or '') .. ' ' .. (it.value or '') .. ' ' .. (it.key or ''), O.query) then view[#view + 1] = it end
    end
  elseif O.tab == 'all' then view = O.all
  else
    -- вкладка = группа разделов (5 окт): заголовок с group = 'hotkeys' и всё под
    -- ним — вкладка hotkeys, остальное — options
    local grp = 'options'
    for _, it in ipairs(O.all) do
      if it.sep then grp = it.group or 'options' end
      if grp == O.tab then view[#view + 1] = it end
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
function O.set_tab(t) O.tab = t; O.sel, O.scroll = 1, 0; O.query = ''; O.rebuild(); if ctx.opt_tab then ctx.opt_tab(t) end; if t == 'theme' and ctx.theme_tab then ctx.theme_tab.sync() end end
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
  O.page, O.ascroll, O.active = 'about', 0, true
end
function O.close() O.active = false; O.drag = nil end

local function val_text(it)
  if it.kind == 'action' then return it.value or '' end
  if it.kind == 'text' then return it.get and tostring(it.get()) or '' end
  local v = it.get()
  if it.kind == 'toggle' then return v and 'on' or 'off' end
  if it.kind == 'cycle' then return tostring(v) end
  if it.fmt then return it.fmt:format(v) end
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

function O.key(c)
  local ch = c < 256 and string.char(c) or ''
  if O.page == 'about' then
    local n = O.about_n or #(O.about or {})
    if c == 27 or ch == 'q' or c == 13 then O.close()
    elseif ch == 'j' or c == 1685026670 then O.ascroll = math.min(math.max(0, n - 1), O.ascroll + 1)
    elseif ch == 'k' or c == 30064 then O.ascroll = math.max(0, O.ascroll - 1)
    elseif ch == 'g' then O.ascroll = 0 end
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
    elseif c == 13 then O.typing = false
    elseif c == 8 then O.query = O.query:sub(1, -2); O.sel = 1; O.rebuild()
    elseif c == 1685026670 then O.sel = math.min(#O.items, O.sel + 1)
    elseif c == 30064 then O.sel = math.max(1, O.sel - 1)
    elseif c >= 32 and c < 127 then O.query = O.query .. ch; O.sel = 1; O.rebuild() end
    return true
  end
  if ch == '/' or ch == 'f' then O.typing = true; O.query = ''; O.rebuild(); return true end
  if c == 9 or ch == ']' then O.step_tab(shift and -1 or 1); return true end
  if c == 25 or ch == '[' then O.step_tab(-1); return true end
  if c == 27 and O.query ~= '' then O.query = ''; O.rebuild(); return true end
  -- 10 окт: вкладка theme — своя сетка (темы карточками, шрифты своим шрифтом)
  if O.tab == 'theme' and O.query == '' and ctx.theme_tab and ctx.theme_tab.key(c) then return true end
  local n = #O.items
  local it = O.items[O.sel]
  if it and it.masked and it.masked() and (c == 13 or ch == ' ' or ch == 'l' or ch == 'h' or ch == '+' or ch == '-') then it.unmask(); return true end
  if c == 27 or ch == 'q' then O.close()
  elseif ch == 'j' or c == 1685026670 then O.sel = math.min(n, O.sel + 1); while O.items[O.sel] and O.items[O.sel].sep and O.sel < n do O.sel = O.sel + 1 end
  elseif ch == 'k' or c == 30064 then O.sel = math.max(1, O.sel - 1); while O.items[O.sel] and O.items[O.sel].sep and O.sel > 1 do O.sel = O.sel - 1 end
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
  if O.tab == 'theme' and O.query == '' and ctx.theme_tab then ctx.theme_tab.wheel(d); return end
  local it = O.items[O.hover or O.sel]
  -- список (хоткеи, действия, полоса прокрутки): колесо листает (5 окт)
  if O.sb_hot or not it or it.kind == 'action' or it.kind == 'text' then
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
  if O.page == 'about' and O.link_hot then if ctx.open_url then ctx.open_url(O.link_hot) end; return end
  if O.close_hot and O.page ~= 'about' then O.close(); return end
  if O.tab_hot then O.set_tab(O.tab_hot); return end
  if O.tab == 'theme' and O.query == '' and ctx.theme_tab and ctx.theme_tab.click() then return end
  if O.find_hot then O.typing = true; return end
  if O.sb_hot then O.sb_drag = true; return end
  if O.hover then
    O.sel = O.hover
    local it = O.items[O.sel]
    local r = O.vrect and O.vrect[O.sel]
    if it.masked and it.masked() then it.unmask(); return end
    -- cycle (3 окт): значения кнопками в ряд — клик по кнопке ставит его;
    -- кнопки не влезли — клик по строке шагает по кругу, как раньше
    if it.kind == 'cycle' and O.hbtn and O.hbtn.i == O.sel then it.set(it.values[O.hbtn.k])
    elseif it.kind == 'cycle' and it.pick then it.pick()   -- 10 окт: щелчок по строке font / theme — выпадашка
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
  U.text(bx + L.pad, by + 2, ctx.fit((O.title or 'about') .. '   j k / wheel: scroll   Esc: close', bw - 2 * L.pad), U.AMBER)
  U.set(U.LINE); gfx.rect(bx, by + rh + 2, bw, 1, 1)
  local y = by + rh + 2 + L.pad
  if O.logo and LGO then
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

function O.draw(L, W, H)
  if not O.active then return end
  if O.page == 'about' then return draw_about(L, W, H) end
  local rh = L.rh
  local n = #O.items
  local lw, vw = L.cw * 22, L.cw * 12
  local dw = 0
  for _, it in ipairs(O.items) do
    if it.kind == 'cycle' then
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
  local ncw = 1
  if not O.compact and O.tab ~= 'hotkeys' then
    ncw = math.max(1, math.min(4, math.floor((W - 4 * L.pad - 20) / colw0)))   -- 13 окт: окно во всю ширину — колонок сколько влезет
    if ncw > 1 then bw = ncw * colw0 end
  end
  O.roww = colw0
  if false then
  end
  local ncol = O.query == '' and ncw or 1
  O.nfull = O.nfull or {}                                -- по вкладке: хоткеи длиннее опций
  local tk = tostring(O.tab or '')
  if O.query == '' then O.nfull[tk] = math.max(O.nfull[tk] or 0, n) end
  local rows = math.max(12, math.ceil((O.nfull[tk] or n) / ncw), math.ceil(n / ncol))
  if O.tab == 'theme' and O.query == '' then rows = math.max(rows, 60); bw = math.max(bw, math.min(W - 2 * L.pad - 20, L.cw * 150)) end   -- вкладка theme — во всю высоту
  local nvis = math.max(3, math.min(rows, math.floor((H - 6 * rh) / rh)))
  local nvis2 = math.max(3, nvis - 1 - ((#O.tabs > 0) and 1 or 0))   -- вкладки — своей строкой над поиском
  nvis = nvis2
  -- 13 окт: окно опций — одного размера на всех вкладках, почти во всё окно (раньше прыгало по вкладкам)
  if not O.compact then
    bw = W - 4 * L.pad
    nvis = math.max(3, math.floor((H - 4 * L.pad) / rh) - 4 - ((#O.tabs > 0) and 1 or 0))
  end
  local bh = (nvis + 4 + ((#O.tabs > 0) and 1 or 0)) * rh
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
  if not O.compact then U.text(hx, by + 2, ctx.fit((#O.tabs > 0 and 'j k: row   Enter / h l: change   Tab: next tab   /: find   Esc: close' or 'j k: row   Enter / h l: change   /: find   Esc: close'), bx + bw - L.pad - hx - U.measure('x') - 3 * L.pad), U.GREY) end   -- до крестика
  U.set(U.LINE); gfx.rect(bx, by + rh + 2, bw, 1, 1)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  -- вкладки (5 окт) и поле поиска справа; не влезают — по ширине, до поиска
  O.tab_hot, O.find_hot = nil, nil
  if not O.compact then
    local ty = by + rh + 4
    -- поиск (5 окт): строка ввода слева, широкая; пустая — подсказка тусклым
    local fq = O.typing and ('/' .. O.query .. '_') or (O.query ~= '' and ('/' .. O.query) or '/ find')
    local fw = math.max(math.floor(bw / 3), U.measure(fq) + 2 * L.pad)
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
      U.set(on and U.tint(U.AMBER, 0.35) or (hot and U.PANEL or U.BG)); gfx.rect(tx, ty, w, rh - 1, 1)
      U.set(on and U.AMBER or (hot and U.TEXT or U.LINE)); gfx.rect(tx, ty, w, rh - 1, 0)
      U.text(tx + L.pad, ty, t, on and U.AMBER or (hot and U.TEXT or U.GREY))
      tx = tx + w + 2
    end
    local fhot = mx >= fx and mx < fx + fw and my >= fy and my < fy + rh
    if fhot then O.find_hot = true end
    U.set(O.typing and U.tint(U.AMBER, 0.25) or (fhot and U.PANEL or U.BG)); gfx.rect(fx, fy, fw, rh - 1, 1)
    U.set((O.typing or O.query ~= '') and U.AMBER or U.LINE); gfx.rect(fx, fy, fw, rh - 1, 0)
    U.text(fx + L.pad, fy, fq, (O.typing or O.query ~= '') and U.AMBER or U.GREY)
  end
  local by0 = by
  if not O.compact then by = by + rh * ((#O.tabs > 0) and 2 or 1) end   -- список — под вкладками и поиском
  O.nvis = cap
  if O.tab == 'theme' and O.query == '' and ctx.theme_tab then
    ctx.theme_tab.draw(bx + L.pad, by + rh + 4, bw - 2 * L.pad, by0 + bh - (by + rh + 4) - 4)
    return
  end
  -- полоса прокрутки списка (5 окт): хоткеев сотни
  O.sb_hot = nil
  local sbw = 0
  if #O.items > cap then
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
  for r = 1, cap do
    local i = O.scroll + r
    local it = O.items[i]
    if not it then break end
    local col, rr = (r - 1) // nvis, (r - 1) % nvis
    local y = by + rh + 4 + rr * rh
    -- колонка: свои x и ширина (у последней — минус полоса прокрутки)
    local bx, bw = bx + col * colw, (col == ncol - 1) and (bw - col * colw) or (colw - L.pad)
    bw = math.min(bw, O.roww or bw)                   -- 13 окт: строка — по содержимому, не до края окна (колесо справа не меняло опции)
    if it.sep then
      -- раздел (4 окт): заголовок темы, иначе — тонкая линия
      if it.gap then                                  -- 10 окт: пустая строка перед разделом
      elseif it.title then U.text(bx + L.pad, y + 1, it.title, U.CYAN); U.set(U.DIM); gfx.rect(bx + L.pad + U.measure(it.title) + L.pad, y + math.floor(rh / 2), bw - 3 * L.pad - U.measure(it.title), 1, 1)
      else U.set(U.DIM); gfx.rect(bx + L.pad, y + math.floor(rh / 2), bw - 2 * L.pad, 1, 1) end
    else
      local hot = mx >= bx and mx < bx + bw and my >= y and my < y + rh
      if hot then O.hover = i end
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
        if tot <= room then
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
          U.text(vx, y + 1, ctx.fit(vt, room), U.TEXT)
        end
      elseif it.hk then
        -- хоткей (5 окт): модуль узкой колонкой, описание — своей колонкой до края
        local mw = L.cw * 12
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
