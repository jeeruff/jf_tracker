-- jf_tracker_themetab.lua — вкладка theme окна Options (10 окт): темы и шрифты
-- с примерами. Тема — карточка «мини-трекер» её цветами (шапки треков, номера
-- строк, ноты, курсор, плейхед, статус INSERT); шрифт — строка, нарисованная
-- этим шрифтом. h j k l — выбор (сетка тем, потом список шрифтов), Enter /
-- щелчок — применить; o — свой шрифт, i — поставить шрифты из комплекта,
-- r — перечитать свои темы. Колесо — прокрутка.
--
-- Окно Options отдаёт вкладке прямоугольник (TT.draw) и клавиши (TT.key);
-- данные и действия — через ctx (TT.init): themes() → { {name, pal}, … },
-- theme(), apply_theme(name), fonts() → { {key, face, size, tip}, … },
-- font(), set_font(key), own_font(), install_fonts(), reload_themes().
-- Превью шрифтов рисуются один раз в картинку 799 (смена шрифта на кадр дорога).

local TT = { sec = 1, i = { 1, 1 }, scroll = 0, rects = {}, hot = nil, btn_hot = nil, fkey = nil }
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
      gfx.setfont(5, f.face, f.size); C(U.TEXT)
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

local BTNS = { { 'o', 'own font' }, { 'i', 'install bundled fonts' }, { 'd', 'download fonts' }, { 'r', 'reload my themes' } }

function TT.draw(x, y, w, h)
  local L, text, ms = ctx.L(), ctx.text, ctx.measure
  local rh, pad = L.rh, L.pad
  local themes, fonts = ctx.themes(), ctx.fonts()
  local mx, my = gfx.mouse_x, gfx.mouse_y
  TT.rects, TT.hot, TT.btn_hot = {}, nil, nil
  -- раскладка: темы — карточками, шрифты — строками в 2-3 колонки
  local cw = ms('00') + 2 * pad + 3 * (ms('C-4 01 7F') + 2 * pad)
  local ch = 7 * rh + 2
  local tcols = math.max(1, math.floor((w + pad) / (cw + pad)))
  local ph = rh
  for _, f in ipairs(fonts) do if f.size then ph = math.max(ph, f.size + 4) end end
  local pw = ms('x') * 34
  local fcols = math.max(1, math.floor((w + pad) / (pw + pad)))
  TT.tcols, TT.fcols, TT.nt, TT.nf = tcols, fcols, #themes, #fonts
  font_img(fonts, pw, ph)
  local trows = math.ceil(#themes / tcols)
  local fy0 = rh + trows * (ch + pad) + rh            -- от верха контента: заголовок тем, сетка, заголовок шрифтов
  -- держать выбранное в окне
  local sy0, sy1
  if TT.sec == 1 then local r = (TT.i[1] - 1) // tcols; sy0 = rh + r * (ch + pad); sy1 = sy0 + ch
  else local r = (TT.i[2] - 1) // fcols; sy0 = fy0 + rh + r * ph; sy1 = sy0 + ph end
  local bh = rh + 4                                    -- строка кнопок внизу
  local vh = h - bh
  if sy0 - TT.scroll < 0 then TT.scroll = sy0 - (TT.sec == 1 and rh or 0) end
  if sy1 - TT.scroll > vh then TT.scroll = sy1 - vh end
  local total = fy0 + rh + math.ceil(#fonts / fcols) * ph
  TT.scroll = math.max(0, math.min(TT.scroll, math.max(0, total - vh)))
  local function vis(yy, hh) return yy >= y and yy + hh <= y + vh end
  local oy = y - TT.scroll
  if vis(oy, rh) then text(x, oy, 'themes - h j k l, Enter applies', U.AMBER) end
  local cur_t = ctx.theme()
  for i, th in ipairs(themes) do
    local r, c = (i - 1) // tcols, (i - 1) % tcols
    local cx, cy = x + c * (cw + pad), oy + rh + r * (ch + pad)
    if vis(cy, ch) then
      card(L, text, ms, cx, cy, cw, ch, th.name, th.pal, th.name == cur_t)
      local sel = TT.sec == 1 and TT.i[1] == i
      if sel then C(U.AMBER); gfx.rect(cx - 2, cy - 2, cw + 4, ch + 4, 0); gfx.rect(cx - 1, cy - 1, cw + 2, ch + 2, 0) end
      if mx >= cx and mx < cx + cw and my >= cy and my < cy + ch then TT.hot = { 1, i }; C(U.TEXT); gfx.rect(cx - 1, cy - 1, cw + 2, ch + 2, 0) end
    end
  end
  local fy = oy + fy0
  if vis(fy, rh) then text(x, fy, 'fonts - each in its own face; font scale changes their size', U.AMBER) end
  local cur_f = ctx.font()
  for i, f in ipairs(fonts) do
    local r, c = (i - 1) // fcols, (i - 1) % fcols
    local cx, cy = x + c * (pw + pad), fy + rh + r * ph
    if vis(cy, ph) then
      local sel = TT.sec == 2 and TT.i[2] == i
      if sel then C(U.AMBER, 0.30); gfx.rect(cx, cy, pw, ph, 1) end
      gfx.blit(IMG, 1, 0, 0, (i - 1) * ph, math.min(pw, w - (cx - x)), ph, cx, cy, math.min(pw, w - (cx - x)), ph)
      if f.key == cur_f then C(U.AMBER); gfx.rect(cx, cy, pw, ph, 0) end
      if mx >= cx and mx < cx + pw and my >= cy and my < cy + ph then TT.hot = { 2, i }; C(U.TEXT); gfx.rect(cx, cy, pw, ph, 0) end
    end
  end
  -- кнопки
  local bx, by = x, y + h - rh - 2
  C(U.LINE); gfx.rect(x, by - 3, w, 1, 1)
  for _, b in ipairs(BTNS) do
    local lab = b[1] .. ' ' .. b[2]
    local bw = ms(lab) + 2 * pad
    if bx + bw > x + w then break end
    local hot = mx >= bx and mx < bx + bw and my >= by and my < by + rh
    if hot then TT.btn_hot = b[1] end
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
end

local function apply()
  if TT.sec == 1 then local th = ctx.themes()[TT.i[1]]; if th then ctx.apply_theme(th.name) end
  else local f = ctx.fonts()[TT.i[2]]; if f then ctx.set_font(f.key); TT.fkey = nil end end
end

local function act(k)
  if k == 'o' then ctx.own_font() elseif k == 'i' then ctx.install_fonts() elseif k == 'd' then ctx.download_fonts()
  elseif k == 'r' then ctx.reload_themes(); TT.fkey = nil end
end

-- клавиши вкладки; true — съели
function TT.key(c)
  local ch = c > 0 and c < 256 and string.char(c) or ''
  local s = TT.sec
  local n, cols = (s == 1 and TT.nt or TT.nf) or 1, (s == 1 and TT.tcols or TT.fcols) or 1
  local i = TT.i[s]
  if ch == 'l' or c == 1919379572 then TT.i[s] = math.min(n, i + 1)
  elseif ch == 'h' or c == 1818584692 then TT.i[s] = math.max(1, i - 1)
  elseif ch == 'j' or c == 1685026670 then
    if i + cols <= n then TT.i[s] = i + cols elseif s == 1 then TT.sec = 2 end
  elseif ch == 'k' or c == 30064 then
    if i - cols >= 1 then TT.i[s] = i - cols elseif s == 2 then TT.sec = 1 end
  elseif ch == 'g' then TT.sec, TT.i[1] = 1, 1
  elseif ch == 'G' then TT.sec, TT.i[2] = 2, TT.nf or 1
  elseif c == 13 or ch == ' ' then apply()
  elseif ch == 'o' or ch == 'i' or ch == 'd' or ch == 'r' then act(ch)
  else return false end
  return true
end

function TT.click()
  if TT.btn_hot then act(TT.btn_hot); return true end
  if TT.hot then TT.sec, TT.i[TT.hot[1]] = TT.hot[1], TT.hot[2]; apply(); return true end
  return false
end

function TT.wheel(d) TT.scroll = math.max(0, TT.scroll - d * (ctx.L().rh * 3)) end

-- выбор = текущие тема и шрифт (при открытии вкладки)
function TT.sync()
  for i, th in ipairs(ctx.themes()) do if th.name == ctx.theme() then TT.i[1] = i end end
  for i, f in ipairs(ctx.fonts()) do if f.key == ctx.font() then TT.i[2] = i end end
end

return TT
