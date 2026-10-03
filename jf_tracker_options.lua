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

function O.open(items)
  O.items = items or O.items
  O.page = 'list'
  O.active = true
  O.sel = math.max(1, math.min(#O.items, O.sel))
end
-- about отдельно, из главного модуля (3 окт): fn() → { logo = { lines = … }, text = { строки } };
-- Esc закрывает окно целиком, не возвращает в список опций
function O.open_about(fn)
  local a = fn()
  O.logo, O.about = a.logo, a.text or {}
  O.page, O.ascroll, O.active = 'about', 0, true
end
function O.close() O.active = false; O.drag = nil end

local function val_text(it)
  local v = it.get()
  if it.kind == 'toggle' then return v and 'on' or 'off' end
  if it.kind == 'cycle' then return tostring(v) end
  if it.fmt then return it.fmt:format(v) end
  return tostring(v)
end

-- изменить строку: d = +1/-1 (num/cycle), 0 = переключить (toggle) / шаг вперёд
function O.adjust(it, d)
  if not it then return end
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
    local n = O.about_n or #(O.about or {})
    if c == 27 or ch == 'q' or c == 13 then O.close()
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

-- мышь (3 окт): toggle — клик; num — слайдер как в DSP (клик / протяжка);
-- cycle — список значений под ячейкой, повторный клик по ней закрывает
local function num_from_x(it, r, mx)
  local fr = math.max(0, math.min(1, (mx - r[1]) / math.max(1, r[3])))
  local v = (it.min or 0) + fr * ((it.max or 1) - (it.min or 0))
  local st = it.step or 1
  v = (it.min or 0) + math.floor((v - (it.min or 0)) / st + 0.5) * st
  it.set(math.max(it.min or v, math.min(it.max or v, v)))
end

function O.click(mx, my)
  if O.close_hot and O.page ~= 'about' then O.close(); return end
  if O.hover then
    O.sel = O.hover
    local it = O.items[O.sel]
    local r = O.vrect and O.vrect[O.sel]
    -- cycle (3 окт): значения кнопками в ряд — клик по кнопке ставит его;
    -- кнопки не влезли — клик по строке шагает по кругу, как раньше
    if it.kind == 'cycle' and O.hbtn and O.hbtn.i == O.sel then it.set(it.values[O.hbtn.k])
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
  U.text(bx + L.pad, by + 2, ctx.fit('about   j k / wheel: scroll   Esc: close', bw - 2 * L.pad), U.AMBER)
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
        gfx.blit(1022, 1, 0, 0, 0, iw, ih, lx0, y, iw, ih)
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
      U.text(bx + L.pad, y, ctx.fit(LGO.SHORT, bw - 2 * L.pad), U.AMBER); y = y + rh + L.pad
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
  local nv = math.floor((by + bh - y) / rh)
  for r = 1, nv do
    local l = lines[O.ascroll + r]
    if not l then break end
    U.text(bx + L.pad, y + (r - 1) * rh, ctx.fit(l[1], tw), l[2])
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
  local nvis = math.max(3, math.min(n, math.floor((H - 6 * rh) / rh)))
  local bh = (nvis + 3) * rh
  local bx, by = math.floor((W - bw) / 2), math.floor((H - bh) / 2)
  O.box = { bx, by, bw, bh }
  if O.sel - 1 < O.scroll then O.scroll = O.sel - 1 end
  if O.sel > O.scroll + nvis then O.scroll = O.sel - nvis end
  U.set(U.BG); gfx.rect(bx, by, bw, bh, 1)
  U.set(U.TEXT); gfx.rect(bx, by, bw, bh, 0)
  U.text(bx + L.pad, by + 2, 'options', U.AMBER)
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
  U.text(hx, by + 2, ctx.fit('j k: row   Enter / Space / h l + -: change   Esc: close', bx + bw - L.pad - hx - U.measure('x') - 3 * L.pad), U.GREY)   -- до крестика
  U.set(U.LINE); gfx.rect(bx, by + rh + 2, bw, 1, 1)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  O.hover = nil
  O.hbtn = nil
  O.vrect = {}
  -- протяжка слайдера: пока кнопка мыши держится
  if O.drag then
    if gfx.mouse_cap & 1 == 1 and O.vrect_last and O.vrect_last[O.drag.i] then num_from_x(O.items[O.drag.i], O.vrect_last[O.drag.i], mx)
    else O.drag = nil end
  end
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
      local vx = bx + L.pad + lw
      O.vrect[i] = { vx, y, vw - L.pad, rh }
      if it.kind == 'num' and it.min and it.max then
        -- слайдер как в DSP: тонкая дорожка, заливка до значения, число справа
        local tw = math.max(8, vw - L.pad - U.measure(vt) - L.pad)
        O.vrect[i] = { vx, y, tw, rh }
        local fr = math.max(0, math.min(1, ((it.get() or 0) - it.min) / math.max(1e-9, it.max - it.min)))
        local cy = y + math.floor(rh / 2)
        local shot = (hot and mx < vx + tw + 2 and mx >= vx - 2) or (O.drag and O.drag.i == i)
        U.set(U.DIM); gfx.rect(vx, cy - 1, tw, 2, 1)
        U.set(shot and U.AMBER or U.TEXT); gfx.rect(vx, y + 4, math.max(1, math.floor(fr * tw + 0.5)), rh - 8, 1)
        U.text(vx + tw + L.pad, y + 1, vt, U.TEXT)
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
            U.set(on2 and U.tint(U.AMBER, 0.35) or (h2 and U.PANEL or U.BG)); gfx.rect(x, y + 1, w, rh - 2, 1)
            U.set(on2 and U.AMBER or (h2 and U.TEXT or U.LINE)); gfx.rect(x, y + 1, w, rh - 2, 0)
            U.text(x + L.pad, y + 1, lb, on2 and U.AMBER or (h2 and U.TEXT or U.GREY))
            x = x + w + 2
          end
        else
          U.text(vx, y + 1, ctx.fit(vt, room), U.TEXT)
        end
      else
        U.text(vx, y + 1, ctx.fit(vt, vw - L.pad), on and U.CYAN or (it.kind == 'toggle' and U.GREY or U.TEXT))
      end
    end
  end
  O.vrect_last = O.vrect
  U.set(U.LINE); gfx.rect(bx, by + bh - rh - 2, bw, 1, 1)
  -- описание — строки под мышью, иначе выбранной клавишами
  local it = O.items[O.hover or O.sel]
  U.text(bx + L.pad, by + bh - rh, ctx.fit(it and it.desc or '', bw - 2 * L.pad), U.GREY)   -- описания короткие (3 окт), в строку
end

return O
