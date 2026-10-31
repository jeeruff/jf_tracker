-- jf_tracker_themetab.lua — вкладка theme окна Options (10 окт): темы и шрифты
-- с примерами. Тема — карточка «мини-трекер» её цветами (шапки треков, номера
-- строк, ноты, курсор, плейхед, статус INSERT); шрифт — строка, нарисованная
-- этим шрифтом. h j k l — выбор (сетка тем, потом список шрифтов), Enter /
-- щелчок — применить; o — свой шрифт, i — поставить шрифты из комплекта,
-- r — перечитать свои темы, - + — размер шрифта, [ ] — интервал строк (11 окт), b — жирный (31 окт). Колесо — прокрутка.
--
-- Окно Options отдаёт вкладке прямоугольник (TT.draw) и клавиши (TT.key);
-- данные и действия — через ctx (TT.init): themes() → { {name, pal}, … },
-- theme(), apply_theme(name), fonts() → { {key, face, size, tip}, … },
-- font(), set_font(key), own_font(), install_fonts(), reload_themes().
-- Превью шрифтов рисуются один раз в картинку 799 (смена шрифта на кадр дорога).

local TT = { sec = 1, i = { 1, 1 }, scroll = 0, rects = {}, hotp = {}, btnp = {}, scr = {}, fkey = nil }
local U, ctx
local IMG = 799                   -- 10 окт: было 90 — это картинки спектрограмм (90..97), они затирали друг друга

function TT.init(u, c) U, ctx = u, c end

local function C(col, a) gfx.set(col[1], col[2], col[3], a or 1) end

-- карточка темы: мини-трекер её цветами
local TRACKS = { 'kick', 'bass', 'pad' }
local NOTES = {                      -- строка → ячейки трёх треков
  { 'C-4 01 7F', '--- .. ..', 'E-5 03 40' },
  { '--- .. ..', 'G-2 02 60', '--- .. ..' },
  { 'C-4 01 50', '--- .. ..', '--- .. ..' },
  { '--- .. ..', 'A#2 02 60', 'G-5 03 40' },
}
local function card(L, text, ms, x, y, w, h, name, t, on)
  local rh, pad = L.rh, L.pad
  C(t.BG); gfx.rect(x, y, w, h, 1)
  -- заголовок карточки
  C(t.PANEL); gfx.rect(x, y, w, rh, 1)
  text(x + pad, y, name .. (on and '  *' or ''), on and t.AMBER or t.TEXT, t.PANEL)
  -- шапки треков
  local nw = ms('00') + 2 * pad
  local cw = math.floor((w - nw) / 3)
  local hy = y + rh
  C(t.HDR or t.PANEL); gfx.rect(x, hy, w, rh, 1)
  local tc = { t.CYAN, t.GREEN, t.AMBER }
  for k, tn in ipairs(TRACKS) do
    local cx = x + nw + (k - 1) * cw
    C(tc[k]); gfx.rect(cx, hy + rh - 2, cw - 1, 2, 1)
    text(cx + pad, hy, tn, t.TEXT, t.HDR or t.PANEL)
  end
  -- строки: номер, ноты; строка 0 — доля (LINE), строка 2 — плейхед, курсор — ячейка 1/1
  for r, row in ipairs(NOTES) do
    local ry = hy + r * rh
    local rbg = r == 3 and U.mix(t.BG, t.GREEN, 0.22) or t.BG   -- плейхед — непрозрачная смесь (текст с подложкой)
    C(rbg); gfx.rect(x, ry, w, rh, 1)
    if r == 1 then C(t.LINE); gfx.rect(x, ry, w, 1, 1) end
    text(x + pad, ry, ('%02d'):format(r - 1), r == 1 and t.TEXT or t.GREY, rbg)
    for k, cell in ipairs(row) do
      local cx = x + nw + (k - 1) * cw
      local empty = cell:sub(1, 3) == '---'
      if r == 2 and k == 2 then
        local cwid = ms(cell:sub(1, 3))
        C(t.AMBER); gfx.rect(cx + pad - 1, ry, cwid + 2, rh, 1)
        text(cx + pad, ry, cell:sub(1, 3), t.BG, t.AMBER)
        text(cx + pad + cwid, ry, cell:sub(4), t.TEXT, rbg)
      elseif cx + pad + ms(cell) <= cx + cw then
        text(cx + pad, ry, cell, empty and t.GREY or t.TEXT, rbg)
      end
      C(t.DIM); gfx.rect(cx, ry, 1, rh, 1)
    end
  end
  -- статус
  local sy = hy + (#NOTES + 1) * rh
  C(t.PANEL); gfx.rect(x, sy, w, h - (sy - y), 1)
  text(x + pad, sy, '-- INSERT --', t.RED, t.PANEL)
  text(x + 2 * pad + ms('-- INSERT --'), sy, 'step 1', t.AMBER, t.PANEL)
  C(on and t.AMBER or t.LINE); gfx.rect(x, y, w, h, 0)
end

-- превью шрифтов: одна картинка, строка на шрифт
local function font_img(fonts, pw, ph)
  local key = pw .. ':' .. ph .. ':' .. #fonts .. ':' .. tostring(U.TEXT[1]) .. tostring(U.TEXT[2])
  for _, f in ipairs(fonts) do key = key .. f.key .. tostring(f.face) .. tostring(f.size) end
  if TT.fkey == key then return end
  local d0 = gfx.dest
  gfx.setimgdim(IMG, -1, -1); gfx.setimgdim(IMG, pw, ph * #fonts)
  gfx.dest = IMG
  for i, f in ipairs(fonts) do
    local y = (i - 1) * ph
    if f.face then
      gfx.setfont(9, f.face, f.size); C(U.TEXT)
      gfx.x, gfx.y = 4, y + math.floor((ph - gfx.texth) / 2)
      gfx.drawstr(f.key .. '   C-4 01 7F  Abc 0123')
    else
      gfx.setfont(ctx.font_id())
      ctx.text(4, y + math.floor((ph - ctx.L().rh) / 2), f.key .. '   C-4 01 7F  REAPER bitmap', U.TEXT)
    end
  end
  gfx.setfont(ctx.font_id()); gfx.dest = d0
  TT.fkey = key
end

local SCALES = { 1, 1.5, 2, 3 }
local BTNS = { { 'o', 'own font' }, { 'i', 'install bundled fonts' }, { 'd', 'download fonts' }, { 'r', 'reload my themes' } }

-- emb (14 окт): вкладки theme нет — блок внутри списка опций; emb.scroll — сдвиг (px) от верха
-- блока, прокрутку ведёт список, кнопки — в конце содержимого. → высота блока, sy0, sy1 выбранного
-- part (31 окт): 'themes' — только темы и кнопки, 'fonts' — размер, шрифты, шрифт слова режима (свой блок слева, где
-- много места), 'all' / nil — всё одним блоком. У каждой части своя прокрутка и своё «под мышью»
function TT.draw(x, y, w, h, emb, part)
  part = part or 'all'
  local showT, showF = part ~= 'fonts', part ~= 'themes'
  local L, text, ms = ctx.L(), ctx.text, ctx.measure
  local rh, pad = L.rh, L.pad
  local themes, fonts = ctx.themes(), ctx.fonts()
  local mx, my = gfx.mouse_x, gfx.mouse_y
  TT.rects = {}
  TT.hotp, TT.btnp, TT.scr = TT.hotp or {}, TT.btnp or {}, TT.scr or {}
  TT.hotp[part], TT.btnp[part] = nil, nil
  TT.scroll = TT.scr[part] or 0
  -- раскладка: темы — карточками, шрифты — строками в 2-3 колонки
  local cw = ms('00') + 2 * pad + 3 * (ms('C-4 01 7F') + 2 * pad)
  local ch = 7 * rh + 2
  local tcols = math.max(1, math.floor((w + pad) / (cw + pad)))
  local ph = rh
  for _, f in ipairs(fonts) do if f.size then ph = math.max(ph, f.size + 4) end end
  local pw = ms('x') * 34
  local fcols = math.max(1, math.floor((w + pad) / (pw + pad)))
  -- 31 окт: каждая часть — только свои размеры (широкий блок тем считал 5 колонок шрифтов — j k в шрифтах слева прыгали через 5)
  if showT then TT.tcols, TT.nt = tcols, #themes end
  if showF then TT.fcols, TT.nf = fcols, #fonts end
  font_img(fonts, pw, ph)
  local trows = math.ceil(#themes / tcols)
  -- 31 окт: размер и интервал не влезают в одну строку (крупный шрифт, узкий блок) — интервал второй строкой
  local SC0 = ctx.scales and ctx.scales() or SCALES
  local need = ms('size (- +)') + pad + 3 * pad + ms('line spacing ([ ])') + pad + 2 * (ms('-') + 2 * pad + 2) + ms('00') + pad + 3 * pad + ms('bold (b)') + 2 * pad + 2
  for _, v in ipairs(SC0) do need = need + ms(tostring(v)) + 2 * pad + 2 end
  local wrap2 = need > w - 6
  local srow = (wrap2 and 2 or 1) * (rh + 2) + 2       -- 11 окт: строка размер / интервал под заголовком шрифтов
  local tH = showT and (rh + trows * (ch + pad)) or 0
  local fy0 = (showT and (tH + rh) or 0) + srow     -- от верха контента: заголовок тем, сетка, заголовок шрифтов, настройки
  -- держать выбранное в окне
  local sy0, sy1
  if TT.sec == 1 then if showT then local r = (TT.i[1] - 1) // tcols; sy0 = rh + r * (ch + pad); sy1 = sy0 + ch end
  elseif showF then local r = (TT.i[2] - 1) // fcols; sy0 = fy0 + rh + r * ph; sy1 = sy0 + ph end
  local bh = showT and (rh + 4) or 0                   -- строка кнопок внизу (у части fonts её нет)
  local vh = h - bh
  -- 13 окт: шрифт слова режима (NORMAL / INSERT) — третья секция, ячейки своим шрифтом
  local mfs = ctx.modefonts and ctx.modefonts() or {}
  local mh = 3 * L.th + 4
  local mcols = math.max(1, math.floor((w + pad) / (pw + pad)))
  if showF then TT.mcols, TT.nm = mcols, #mfs end
  local my0 = fy0 + rh + math.ceil(#fonts / fcols) * ph + pad
  if TT.sec == 3 and showF then local r = ((TT.i[3] or 1) - 1) // mcols; sy0 = my0 + rh + r * (mh + 2); sy1 = sy0 + mh end
  local total = showF and (my0 + rh + math.ceil(#mfs / mcols) * (mh + 2)) or tH
  if emb then
    vh = h; TT.scroll = emb.scroll or 0
  else
    if sy0 and sy0 - TT.scroll < 0 then TT.scroll = sy0 - (TT.sec == 1 and rh or 0) end
    if sy1 and sy1 - TT.scroll > vh then TT.scroll = sy1 - vh end
    TT.scroll = math.max(0, math.min(TT.scroll, math.max(0, total - vh)))
    TT.scr[part] = TT.scroll
  end
  local function vis(yy, hh) return yy >= y and yy + hh <= y + vh end
  -- 31 окт: своя прокрутка и содержимое выше окна — полоса прокрутки справа (колесо листает)
  if not emb and total > vh and vh > 0 then
    local th = math.max(rh, math.floor(vh * vh / total))
    local ty = y + math.floor((vh - th) * TT.scroll / math.max(1, total - vh))
    C(U.LINE); gfx.rect(x + w - 3, y, 3, vh, 1)
    C(U.GREY); gfx.rect(x + w - 3, ty, 3, th, 1)
    w = w - 6
  end
  local oy = y - TT.scroll
  if showT and vis(oy, rh) then text(x, oy, 'themes - h j k l, Enter applies', U.AMBER) end
  local cur_t = ctx.theme()
  for i, th in ipairs(showT and themes or {}) do
    local r, c = (i - 1) // tcols, (i - 1) % tcols
    local cx, cy = x + c * (cw + pad), oy + rh + r * (ch + pad)
    if vis(cy, ch) then
      card(L, text, ms, cx, cy, cw, ch, th.name, th.pal, th.name == cur_t)
      local sel = TT.sec == 1 and TT.i[1] == i
      if sel then C(U.AMBER); gfx.rect(cx - 2, cy - 2, cw + 4, ch + 4, 0); gfx.rect(cx - 1, cy - 1, cw + 2, ch + 2, 0) end
      if mx >= cx and mx < cx + cw and my >= cy and my < cy + ch then TT.hotp[part] = { 1, i }; C(U.TEXT); gfx.rect(cx - 1, cy - 1, cw + 2, ch + 2, 0) end
    end
  end
  local fy = oy + fy0
  if showF and vis(fy - srow, rh) then text(x, fy - srow, 'fonts - each in its own face', U.AMBER) end
  -- размер (font scale) и интервал строк — кнопками, + - и [ ] с клавиатуры
  if showF then
    local sy = fy - srow + rh + 1
    if vis(sy, rh) then
      local bx = x
      local function btn(lab, on, what)
        local bw = ms(lab) + 2 * pad
        if bx + bw > x + w then return end
        local hot = mx >= bx and mx < bx + bw and my >= sy and my < sy + rh
        if hot then TT.btnp[part] = what end
        C(on and U.tint(U.AMBER, 0.3) or (hot and U.tint(U.AMBER, 0.15) or U.BG)); gfx.rect(bx, sy, bw, rh, 1)
        C(on and U.AMBER or U.LINE); gfx.rect(bx, sy, bw, rh, 0)
        text(bx + pad, sy, lab, (on or hot) and U.AMBER or U.TEXT)
        bx = bx + bw + 2
      end
      local function lab(t) if bx + ms(t) + pad <= x + w then text(bx, sy, t, U.GREY); bx = bx + ms(t) + pad end end
      local sc = ctx.scale()
      lab('size (- +)')
      for _, v in ipairs(ctx.scales and ctx.scales() or SCALES) do btn(tostring(v), sc == v, { 'scale', v }) end   -- 31 окт: у битмапа без 1.5
      bx = bx + 3 * pad
      if wrap2 then bx = x; sy = sy + rh + 2 end
      lab('line spacing ([ ])')
      btn('-', false, { 'space', -1 }); lab(tostring(ctx.space())); btn('+', false, { 'space', 1 })
      bx = bx + 3 * pad
      if ctx.bold then btn('bold (b)', ctx.bold(), { 'bold' }) end   -- 31 окт: жирный шрифт
    end
  end
  local cur_f = ctx.font()
  for i, f in ipairs(showF and fonts or {}) do
    local r, c = (i - 1) // fcols, (i - 1) % fcols
    local cx, cy = x + c * (pw + pad), fy + rh + r * ph
    if vis(cy, ph) then
      local sel = TT.sec == 2 and TT.i[2] == i
      if sel then C(U.AMBER, 0.30); gfx.rect(cx, cy, pw, ph, 1) end
      gfx.blit(IMG, 1, 0, 0, (i - 1) * ph, math.min(pw, w - (cx - x)), ph, cx, cy, math.min(pw, w - (cx - x)), ph)
      if f.key == cur_f then C(U.AMBER); gfx.rect(cx, cy, pw, ph, 0) end
      if mx >= cx and mx < cx + pw and my >= cy and my < cy + ph then TT.hotp[part] = { 2, i }; C(U.TEXT); gfx.rect(cx, cy, pw, ph, 0) end
    end
  end
  if showF then
    local my1 = oy + my0
    if vis(my1, rh) then text(x, my1, 'mode word in the status (NORMAL / INSERT) - its own font', U.AMBER) end
    local curm = ctx.modefont_get and ctx.modefont_get() or 'off'
    for i, nm in ipairs(mfs) do
      local r, c = (i - 1) // mcols, (i - 1) % mcols
      local cx, cy = x + c * (pw + pad), my1 + rh + r * (mh + 2)
      if vis(cy, mh) then
        local sel = TT.sec == 3 and TT.i[3] == i
        C(sel and U.tint(U.AMBER, 0.30) or U.BG); gfx.rect(cx, cy, pw, mh, 1)
        C((nm == curm) and U.AMBER or U.LINE); gfx.rect(cx, cy, pw, mh, 0)
        if nm == 'off' then text(cx + pad, cy + 2, 'off - tracker font', U.GREY)
        else
          gfx.setfont(9, nm, math.floor(2 * L.th * (ctx.mode_scale and ctx.mode_scale(nm) or 1)))
          local wd = ctx.mode_word and ctx.mode_word(nm) or 'INSERT'   -- 15 окт: письменность — своим словом (插入, إدراج, ВСТАВКА, pIqaD)
          C(U.AMBER); gfx.x, gfx.y = cx + pad, cy + 1; gfx.drawstr(wd)
          local iw = gfx.measurestr(wd .. ' ')
          gfx.setfont(ctx.font_id and ctx.font_id() or 1)
          text(cx + pad + iw, cy + mh - rh - 1, ctx.fit(nm, pw - iw - 2 * pad), U.GREY)
        end
        if mx >= cx and mx < cx + pw and my >= cy and my < cy + mh then TT.hotp[part] = { 3, i }; C(U.TEXT); gfx.rect(cx, cy, pw, mh, 0) end
      end
    end
  end
  -- кнопки
  if not showT then
    if emb then TT.last_f = { total = total + 4, sy0 = sy0, sy1 = sy1 }; return TT.last_f.total, sy0, sy1 end
    return
  end
  local bx, by = x, y + h - rh - 2
  if emb then
    by = oy + total + 4
    TT.last = { total = total + rh + 8, sy0 = sy0, sy1 = sy1 }
    if not vis(by - 3, rh + 3) then return TT.last.total, sy0, sy1 end
  end
  C(U.LINE); gfx.rect(x, by - 3, w, 1, 1)
  for _, b in ipairs(BTNS) do
    local lab = b[1] .. ' ' .. b[2]
    local bw = ms(lab) + 2 * pad
    if bx + bw > x + w then break end
    local hot = mx >= bx and mx < bx + bw and my >= by and my < by + rh
    if hot then TT.btnp[part] = b[1] end
    C(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, by, bw, rh, 1)
    C(U.LINE); gfx.rect(bx, by, bw, rh, 0)
    text(bx + pad, by, lab, hot and U.AMBER or U.TEXT)
    bx = bx + bw + pad
  end
  -- подсказка выбранного
  local tip
  if TT.sec == 1 and themes[TT.i[1]] then tip = 'theme ' .. themes[TT.i[1]].name
  elseif fonts[TT.i[2]] then tip = fonts[TT.i[2]].tip end
  if tip and bx + ms(tip) + pad < x + w then text(bx + pad, by, ctx.fit(tip, x + w - bx - pad), U.GREY) end
  if emb then return TT.last.total, sy0, sy1 end
end

local function apply()
  if TT.sec == 1 then local th = ctx.themes()[TT.i[1]]; if th then ctx.apply_theme(th.name) end
  elseif TT.sec == 3 then local nm = (ctx.modefonts and ctx.modefonts() or {})[TT.i[3] or 1]; if nm then ctx.modefont_set(nm) end
  else local f = ctx.fonts()[TT.i[2]]; if f then ctx.set_font(f.key); TT.fkey = nil end end
end

local function act(k)
  if type(k) == 'table' then
    if k[1] == 'scale' then ctx.set_scale(k[2]) elseif k[1] == 'bold' then ctx.set_bold(not ctx.bold()) else ctx.set_space(ctx.space() + k[2]) end
    TT.fkey = nil; return
  end
  if k == 'o' then ctx.own_font() elseif k == 'i' then ctx.install_fonts() elseif k == 'd' then ctx.download_fonts()
  elseif k == 'r' then ctx.reload_themes(); TT.fkey = nil end
end

-- клавиши вкладки; true — съели. part (31 окт): своя часть — темы (раздел 1) или шрифты (2, 3)
function TT.key(c, part)
  local ch = c > 0 and c < 256 and string.char(c) or ''
  local lo, hi = 1, 3
  if part == 'themes' then hi = 1 elseif part == 'fonts' then lo = 2 end
  if TT.sec < lo or TT.sec > hi then TT.sec = lo end
  local s = TT.sec
  TT.i[3] = TT.i[3] or 1
  local n = (s == 1 and TT.nt) or (s == 2 and TT.nf) or TT.nm or 1
  local cols = (s == 1 and TT.tcols) or (s == 2 and TT.fcols) or TT.mcols or 1
  local i = TT.i[s]
  if ch == 'l' or c == 1919379572 then TT.i[s] = math.min(n, i + 1)
  elseif ch == 'h' or c == 1818584692 then TT.i[s] = math.max(1, i - 1)
  elseif ch == 'j' or c == 1685026670 then
    if i + cols <= n then TT.i[s] = i + cols elseif s < hi then TT.sec = s + 1 else return 'down' end   -- 14 окт: из блока — в список опций
  elseif ch == 'k' or c == 30064 then
    if i - cols >= 1 then TT.i[s] = i - cols elseif s > lo then TT.sec = s - 1 else return 'up' end
  elseif ch == 'g' then TT.sec, TT.i[lo] = lo, 1
  elseif ch == 'G' then if hi >= 2 then TT.sec, TT.i[2] = 2, TT.nf or 1 else TT.i[1] = TT.nt or 1 end
  elseif c == 13 or ch == ' ' then apply()
  elseif ch == 'o' or ch == 'i' or ch == 'd' or ch == 'r' then act(ch)
  elseif ch == '+' or ch == '=' or ch == '-' then
    local sc, j = ctx.scale(), 1
    local SC = ctx.scales and ctx.scales() or SCALES
    for k2, v in ipairs(SC) do if v == sc then j = k2 end end
    j = math.max(1, math.min(#SC, j + (ch == '-' and -1 or 1)))
    act({ 'scale', SC[j] })
  elseif ch == '[' or ch == ']' then act({ 'space', ch == ']' and 1 or -1 })
  elseif ch == 'b' and ctx.bold then act({ 'bold' })   -- 31 окт: жирный шрифт
  else return false end
  return true
end

function TT.click(part)
  part = part or 'all'
  local bh, hh = TT.btnp and TT.btnp[part], TT.hotp and TT.hotp[part]
  if bh then act(bh); return true end
  if hh then TT.sec, TT.i[hh[1]] = hh[1], hh[2]; apply(); return true end
  return false
end

function TT.wheel(d, part) TT.scr = TT.scr or {}; part = part or 'all'; TT.scr[part] = math.max(0, (TT.scr[part] or 0) - d * (ctx.L().rh * 3)) end

-- выбор = текущие тема и шрифт (при открытии вкладки)
function TT.sync()
  for i, th in ipairs(ctx.themes()) do if th.name == ctx.theme() then TT.i[1] = i end end
  for i, f in ipairs(ctx.fonts()) do if f.key == ctx.font() then TT.i[2] = i end end
end

return TT
