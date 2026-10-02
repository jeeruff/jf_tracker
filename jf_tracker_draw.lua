-- jf_tracker_draw.lua — отрисовка снимка трекера в gfx.
--
-- Ничего не читает из REAPER: на входе снимок модели, строки вида и
-- состояние; пики, значения огибающих и сайдбар — через колбэки.
-- Шрифт: битмап gfx.setfont(0) или TTF моноширинный (`:font N`,
-- D.set_font). Все размеры МЕРЯЮТСЯ (gfx.measurestr / TH()), поэтому
-- смена шрифта меняет всё пропорционально.
--
-- Сверху вниз / слева направо: [полоска пула трека курсора] → заголовок →
-- матрица паттернов | номера строк | треки → lanes → подколонки
-- «нота vol delay [команды…]» → огибающие трека | сайдбар-браузер.
-- Свёрнутый трек (fold) — узкая колонка с точками. Курсор — инверсное
-- поле, его строка подсвечена на всю ширину. Стиль: прямые углы, 1 px,
-- активное — цветом; ширины от содержимого, при нехватке — прокрутка.
--
-- Плоский список подколонок L.flat — система координат курсора Vim-слоя:
-- fi = индекс в L.flat, row = строка. Огибающие в L.flat не входят.

local D = {}
local U, get_peaks, MX
D.font_id = 0
D.hint = nil   -- функция сбора целей подсказок (kind, x, y, w, h, data); ставит main
local function hint(kind, x, y, w, h, data) if D.hint then D.hint(kind, x, y, w, h, data) end end
local ms, TH   -- объявлены ниже (set_font)

function D.init(u, peaks_fn, matrix)
  U, get_peaks, MX = u, peaks_fn, matrix
  -- общие примитивы для матрицы/браузера/слайсера — через масштабируемый текст
  U.text = function(x, y, str, col, bg) D.text(x, y, str, col, bg) end
  U.textc = function(x, y, w, str, col) D.text(x + (w - ms(str)) / 2, y, str, col) end
  U.textr = function(x, y, w, str, col) D.text(x + w - ms(str), y, str, col) end
  U.measure, U.texth = ms, TH
  -- контраст ярче: текст тянем к 7:1 (U — копия модуля, jf_looper не трогаем)
  U.TEXT = U.readable(U.TEXT, U.BG, 7.0)
  U.GREY = U.mix(U.TEXT, U.BG, 0.40)
  U.CYAN = U.readable(U.CYAN, U.BG, 4.5)
  D.PEAK  = U.readable(U.theme('col_tr1_peaks', { 0.55, 0.62, 0.70 }), U.BG, 4.0)
  D.PEAKM = U.mix(D.PEAK, U.BG, 0.55)
  D.BAR   = U.mix(U.BG, U.TEXT, 0.62)
  D.BEAT  = U.DIM
  D.PLAY  = U.tint(U.AMBER, 0.22)
  D.CUR   = U.AMBER
  D.CURROW = U.mix(U.BG, U.TEXT, 0.16)
  D.CURTOP = U.AMBER                            -- яркая верхняя кромка строки курсора
  D.EDITTOP = U.readable({ 0.30, 0.95, 0.40 }, U.BG, 4.5)  -- зелёная кромка edit-курсора
  D.VIS   = U.tint(U.CYAN, 0.25)
  D.EMPTY = U.mix(U.BG, U.TEXT, 0.34)
  D.CONT  = U.GREY
  D.ENVBAR = U.tint(U.CYAN, 0.45)
  D.FX    = U.mix(U.TEXT, U.AMBER, 0.5)
  D.SEP   = U.mix(U.BG, U.TEXT, 0.70)           -- жирные границы модулей (2 px)
  D.FOCUS = U.mix(U.TEXT, { 1, 1, 1 }, 0.55)    -- светлый ободок модуля с фокусом (просьба 1 окт: без розового)
  D.FOCUS_INS = { 1.0, 0.15, 0.1 }              -- та же рамка в INSERT (красная, толще)
  D.ENVLINE = U.readable(U.CYAN, U.BG, 4.5)
end

-- шрифт: 0 — битмап REAPER (масштаб ×N пиксель-в-пиксель через кеш строк и
-- gfx.blit — тот самый PT2-вид), N>0 — TTF моноширинный размера N.
-- D.SPACE — зазор над буквами в строке (`:space`), входит в высоту строки.
D.SCALE, D.SPACE = 1, 2
local tcache, next_img = {}, 100
local IMG_FIRST, IMG_LAST = 100, 999

function D.set_font(state)
  local n = tonumber(state.font) or 0
  if n > 0 then
    gfx.setfont(1, state.fontface or 'JetBrainsMono Nerd Font Mono', n)
    D.font_id = 1
    D.SCALE = 1
  else
    D.font_id = 0
    -- только целые x1..x4 (дробный пробовали 1 окт — кривой; Ctrl +/- шаг 1)
    D.SCALE = math.max(1, math.min(4, math.floor(tonumber(state.fontscale) or 2)))
  end
  D.SPACE = math.max(0, math.min(12, math.floor(tonumber(state.fontspace) or 2)))
  if state.glyphface and state.glyphface ~= '' then D.glyph_face = state.glyphface end
  tcache, next_img = {}, IMG_FIRST
  if D.reset_vcache then D.reset_vcache() end      -- вертикальные имена — тоже из старого шрифта
  if D.reset_glyph then D.reset_glyph(); D.reset_measure() end
  gfx.setfont(D.font_id)
  D.bitmap_th = gfx.texth
end

-- ширина/высота текста с учётом масштаба битмапа
-- ГИБРИД (битмап + Nerd-иконки): битмап REAPER знает только ASCII, поэтому
-- строка режется на ASCII-куски (битмап, слот 0) и глифы (TTF, слот 2,
-- размер = высота битмапа). D.hybrid ставит main (:font 0 + :icons).
D.hybrid = false
D.glyph_face = 'JetBrainsMono Nerd Font Mono'
-- Разбор без исключений: utf8.codes бросает ошибку на битой UTF-8 (имя,
-- обрезанное посреди символа, cp1251 из чужих проектов) — так скрипт и падал.
-- gmatch по utf8.charpattern не бросает; одиночный «хвостовой» байт — пропуск.
local function segments(str)
  local out, ascii = {}, {}
  for ch in str:gmatch('[%z\1-\127\194-\253][\128-\191]*') do
    if #ch == 1 then ascii[#ascii + 1] = ch
    else
      if #ascii > 0 then out[#out + 1] = { t = table.concat(ascii) }; ascii = {} end
      out[#out + 1] = { t = ch, glyph = true }
    end
  end
  if #ascii > 0 then out[#out + 1] = { t = table.concat(ascii) } end
  return out
end
-- шрифт глифов создаётся ОДИН раз (setfont с именем дорогой), дальше —
-- переключение слота gfx.setfont(2)
local glyph_sig
local function glyph_font()
  local sz = math.max(8, math.floor(D.bitmap_th or 11))
  local sig = D.glyph_face .. '|' .. sz
  if glyph_sig ~= sig then gfx.setfont(2, D.glyph_face, sz); glyph_sig = sig else gfx.setfont(2) end
end
D.reset_glyph = function() glyph_sig = nil end
local mcache, mcount = {}, 0
local function measure_raw(str)
  if D.hybrid and str:find('[\128-\255]') then
    local w = mcache[str]
    if w then return w end
    w = 0
    for _, sg in ipairs(segments(str)) do
      if sg.glyph then glyph_font(); w = w + gfx.measurestr(sg.t); gfx.setfont(D.font_id)
      else w = w + gfx.measurestr(sg.t) end
    end
    mcount = mcount + 1
    if mcount > 4000 then mcache, mcount = {}, 0 end
    mcache[str] = w
    return w
  end
  return gfx.measurestr(str)
end
D.reset_measure = function() mcache, mcount = {}, 0 end
ms = function(str) return measure_raw(str) * D.SCALE end
TH = function() return math.ceil(gfx.texth * D.SCALE) end
D.measure, D.texth = ms, TH

-- строка → offscreen-картинка (один раз на строку+цвет+фон)
local function txt_img(str, col, bg)
  local key = str .. '|' .. math.floor(col[1] * 255) .. ',' .. math.floor(col[2] * 255) .. ',' .. math.floor(col[3] * 255)
    .. '|' .. (bg and (math.floor(bg[1] * 255) .. ',' .. math.floor(bg[2] * 255) .. ',' .. math.floor(bg[3] * 255)) or '')
  local e = tcache[key]
  if e then return e end
  if next_img > IMG_LAST then tcache, next_img = {}, IMG_FIRST end
  gfx.setfont(D.font_id)
  local w, h = measure_raw(str) + 1, gfx.texth
  local id = next_img; next_img = next_img + 1
  gfx.setimgdim(id, w, h)
  local old = gfx.dest
  gfx.dest = id
  if bg then gfx.set(bg[1], bg[2], bg[3], 1) else gfx.set(0, 0, 0, 1) end
  gfx.rect(0, 0, w, h, 1)
  gfx.set(col[1], col[2], col[3], 1)
  gfx.setfont(D.font_id)
  if D.hybrid and str:find('[\128-\255]') then
    local x = 0
    for _, sg in ipairs(segments(str)) do
      if sg.glyph then glyph_font() else gfx.setfont(D.font_id) end
      local sw = gfx.measurestr(sg.t)
      local gy = sg.glyph and math.floor((h - gfx.texth) / 2) or 0
      gfx.x, gfx.y = x, gy; gfx.drawstr(sg.t)
      x = x + sw
    end
    gfx.setfont(D.font_id)
  else
    gfx.x, gfx.y = 0, 0; gfx.drawstr(str)
  end
  gfx.dest = old
  e = { id = id, w = w, h = h }
  tcache[key] = e
  return e
end

-- ── раскладка ─────────────────────────────────────────────────────────────
function D.layout(snap, state, nregions)
  gfx.setfont(D.font_id)
  local L = {}
  L.th = TH()
  L.rh = L.th + 2 + D.SPACE
  L.pad = ms(' ')
  if L.pad < 2 then L.pad = math.max(3, math.floor(ms('W') / 2)) end
  L.cw = ms('W')
  L.w_note = ms('C#4')
  L.w_vol = ms('FF')
  L.w_del = ms('FF')
  L.w_fx = ms('9FF')
  L.nfx = state.fxcols or 0
  -- колонка волны слева от ноты (:wave peaks|rect|spec|off) — нативные пики REAPER, вертикально
  -- колонка волны: всегда спектральные пики REAPER (цвет = частота) +
  -- stretch-маркеры; только on/off (просьба 1 окт, режимы peaks/rect убраны)
  L.wave = (state.wave == 'off') and 'off' or 'spec'
  L.w_wave = L.wave == 'off' and 0 or L.cw * 3
  L.x_wave = L.pad
  L.x_note = L.pad + (L.w_wave > 0 and (L.w_wave + L.pad) or 0)
  L.x_vol = L.x_note + L.w_note + L.pad
  -- порядок: волна | нота | vol | fx1..n | delay (просьба 1 окт)
  L.x_fx = {}
  local x = L.x_vol + L.w_vol + L.pad
  for k = 1, L.nfx do L.x_fx[k] = x; x = x + L.w_fx + L.pad end
  L.x_del = x
  x = L.x_del + L.w_del + L.pad
  L.sub_w = x
  L.fold_w = ms('o') + 2 * L.pad
  L.env_hex_w = ms('FF')
  L.env_bar_w = ms('WWWW')
  L.env_w = L.pad + L.env_bar_w + L.pad + L.env_hex_w + L.pad
  -- ширина браузера: перетащенная мышью (state.side_px) или по кнопке <>
  L.side_w = state.side and (state.side_px or (L.cw * (state.sidenarrow and 20 or 36) + 2 * L.pad)) or 0
  L.win_w = gfx.w - L.side_w
  L.matrix_w = MX and MX.width(L, nregions or 0, #snap.cols) or 0
  L.label_w = ms('0000') + 2 * L.pad
  -- верхняя панель (как в Renoise 2): контрол | скоупы | инструменты трека
  -- верхняя панель: +15 % (просьба 1 окт) — место под монтаж mono-модуля
  L.top_h = state.top and (state.top_px or math.max(5 * L.rh + 8, math.min(math.floor(11 * L.rh), math.floor(gfx.h * 0.19)))) or 0
  if state.top and state.top_px then L.top_h = math.max(4 * L.rh + 8, math.min(math.floor(gfx.h * 0.5), state.top_px)) end
  L.pool_h = L.top_h
  L.ctrl_w = L.cw * 30 + 2 * L.pad
  L.inst_w = state.side and 0 or (L.cw * 32 + 2 * L.pad)
  L.header_y = L.top_h
  L.meter_h = 0
  -- шапка трека (2 окт): имя | R I M S A | громкость | панорама | лейн −+ / огибающие | подписи
  L.header_h = 6 * L.rh + 3
  L.btn_w = L.cw + 4                             -- кнопки M S R в шапке
  L.status_h = L.rh + 4
  L.dsp_h = state.dsp and math.max(4 * L.rh + 8, math.floor(gfx.h * 0.18)) or 0
  L.body_y = L.header_y + L.header_h
  L.body_h = math.max(0, gfx.h - L.body_y - L.status_h - L.dsp_h)
  L.nrows = math.max(1, math.floor(L.body_h / L.rh))
  L.flat, L.cols = {}, {}
  local cx = L.matrix_w + L.label_w
  local first = state.hscroll or 1
  local hide_below = nil          -- глубина свёрнутой папки: дети не показываются
  for ci, col in ipairs(snap.cols) do
    local depth = col.depth or 0
    if hide_below and depth <= hide_below then hide_below = nil end
    local hidden = hide_below ~= nil and depth > hide_below
    if not hidden and col.folder and state.fcollapse and state.fcollapse[col.guid] then hide_below = depth end
    local vis = (not hidden) and ci >= first and cx < L.win_w
    local c = { col = col, ci = ci, x = vis and cx or nil, lanes = {}, envs = {}, folded = state.folds[col.guid] == true, hidden = hidden }
    local lx = (c.x or 0) + 1
    if c.folded then
      L.flat[#L.flat + 1] = { ci = ci, col = col, folded = true, x = vis and lx or nil, w = L.fold_w }
      c.lanes[1] = { lane = col.lanes[1], x = lx, w = L.fold_w, nsub = 1, f0 = #L.flat, folded = true }
      lx = lx + L.fold_w + 1
    else
      for li, lane in ipairs(col.lanes) do
        -- минимум подколонок задаёт пользователь кнопками -/+ над лейном (1 окт)
        local nsub = math.max(1, #lane.subs, (state.subs_min or {})[col.guid .. ':' .. tostring(lane.idx)] or 0)
        local ln = { lane = lane, x = lx, w = nsub * L.sub_w, nsub = nsub, f0 = #L.flat + 1 }
        for si = 1, nsub do
          L.flat[#L.flat + 1] = { ci = ci, col = col, lane = lane, li = li, si = si, sub = lane.subs[si] or {},
                                  x = vis and (lx + (si - 1) * L.sub_w) or nil, w = L.sub_w }
        end
        c.lanes[#c.lanes + 1] = ln
        lx = lx + ln.w + 1
      end
      local show_env = state.trackenvs and state.trackenvs[col.guid]
      if show_env == nil then show_env = state.envs end
      if show_env and col.envs then
        for _, e in ipairs(col.envs) do
          -- огибающая — тоже элемент L.flat (курсор заходит, INSERT правит точки)
          L.flat[#L.flat + 1] = { ci = ci, col = col, env = e, sub = {}, x = vis and lx or nil, w = L.env_w }
          c.envs[#c.envs + 1] = { e = e, x = lx, w = L.env_w, fi = #L.flat }
          lx = lx + L.env_w + 1
        end
      end
    end
    c.w = lx - (c.x or 0)
    if vis then L.cols[#L.cols + 1] = c; cx = lx end
    -- скрытые дети свёрнутой папки: записи L.flat остаются (курсор не ломается), x = nil
    if hidden then for _, f in ipairs(L.flat) do if f.ci == ci then f.x = nil end end end
  end
  L.total_w = cx
  return L
end

-- ── примитивы ─────────────────────────────────────────────────────────────
local function set(c, a) gfx.set(c[1], c[2], c[3], a or 1) end
-- bg — непрозрачная подложка (для инверсного курсора); без bg при масштабе
-- >1 текст блитится аддитивно (чёрный фон картинки не виден)
local function text(x, y, s, col, bg)
  if s == nil or s == '' then return end
  y = y + D.SPACE
  if D.SCALE == 1 then
    -- ×1: прямой drawstr; в гибриде глифы — через сегменты (иначе битмап
    -- рисовал байты иконки как 3 лишних символа, и ширина не сходилась с ms)
    if D.hybrid and s:find('[\128-\255]') then
      if bg then set(bg); gfx.rect(x, y, measure_raw(s) + 1, gfx.texth, 1) end
      local cx = math.floor(x)
      local h = gfx.texth
      for _, sg in ipairs(segments(s)) do
        if sg.glyph then glyph_font() else gfx.setfont(D.font_id) end
        set(col); gfx.x, gfx.y = cx, math.floor(y) + (sg.glyph and math.floor((h - gfx.texth) / 2) or 0)
        gfx.drawstr(sg.t)
        cx = cx + gfx.measurestr(sg.t)
      end
      gfx.setfont(D.font_id)
      return
    end
    if bg then set(bg); gfx.rect(x, y, gfx.measurestr(s) + 1, gfx.texth, 1) end
    set(col); gfx.x, gfx.y = math.floor(x), math.floor(y); gfx.drawstr(s)
    return
  end
  local e = txt_img(s, col, bg)
  local mode = gfx.mode
  gfx.mode = (bg and 0 or 1) | 4          -- 4 = без фильтрации при масштабировании
  gfx.a = 1
  gfx.blit(e.id, 1, 0, 0, 0, e.w, e.h, math.floor(x), math.floor(y), e.w * D.SCALE, e.h * D.SCALE)
  gfx.mode = mode
end
D.text = text
local function fit(s, w)
  if ms(s) <= w then return s end
  local n = #s
  while n > 0 do
    -- граница символа: следующий байт не «хвостовой» (10xxxxxx)
    local nb = s:byte(n + 1)
    if not (nb and nb >= 128 and nb < 192) and ms(s:sub(1, n)) <= w then break end
    n = n - 1
  end
  return s:sub(1, n)
end
D.fit = fit

-- вертикальный текст (имена треков в матрице). gfx.blit с поворотом режет
-- результат прямоугольником назначения, поэтому поворачиваем честно:
-- текст → картинка A (w×h) → попиксельно в картинку B (h×w), B блитится с
-- масштабом. Кеш по строке+цвету, картинки 1000..1022 (сброс по кругу).
local vcache, vnext = {}, 1000
D.reset_vcache = function() vcache, vnext = {}, 1000 end
function D.vtext(x, y, h_avail, str, col, bg)
  bg = bg or U.PANEL
  local maxchars = math.max(1, math.floor(h_avail / math.max(1, ms('W'))))
  if #str > maxchars then str = str:sub(1, maxchars) end
  local key = str .. '|' .. math.floor(col[1] * 255) .. ',' .. math.floor(col[2] * 255) .. ',' .. math.floor(col[3] * 255)
  local e = vcache[key]
  if not e then
    if vnext > 1022 then vcache, vnext = {}, 1000 end
    local w, h = gfx.measurestr(str), gfx.texth
    if w < 1 then return end
    local A, B = 1023, vnext; vnext = vnext + 1
    local old = gfx.dest
    gfx.setimgdim(A, w, h)
    gfx.dest = A
    gfx.set(bg[1], bg[2], bg[3], 1); gfx.rect(0, 0, w, h, 1)
    gfx.set(col[1], col[2], col[3], 1); gfx.setfont(D.font_id); gfx.x, gfx.y = 0, 0; gfx.drawstr(str)
    gfx.setimgdim(B, h, w)
    -- поворот на −90°: (i, j) → (j, w−1−i); текст читается снизу вверх
    for i = 0, w - 1 do
      for j = 0, h - 1 do
        gfx.dest = A; gfx.x, gfx.y = i, j
        local r, g, bl = gfx.getpixel()
        gfx.dest = B; gfx.x, gfx.y = j, w - 1 - i
        gfx.set(r, g, bl, 1); gfx.setpixel(r, g, bl)
      end
    end
    gfx.dest = old
    e = { id = B, w = h, h = w }
    vcache[key] = e
  end
  local mode = gfx.mode; gfx.mode = 0; gfx.a = 1
  -- прижать к низу отведённой высоты (как в Renoise: имя растёт снизу)
  local dh = e.h * D.SCALE
  local dy = y + math.max(0, h_avail - dh)
  gfx.blit(e.id, 1, 0, 0, 0, e.w, e.h, math.floor(x), math.floor(dy), e.w * D.SCALE, dh)
  gfx.mode = mode
end

-- ── иконки Nerd Font (JetBrainsMono Nerd Font, :font N + :icons) ─────────
-- Битмап REAPER знает только ASCII, поэтому иконки — опция TTF-режима:
-- D.icons ставит main (state.icons и state.font > 0). D.ic(name, text) —
-- глиф + текст (или только глиф, если text пустой); без иконок — текст.
D.icons = false
local ICON = {
  play = 0xF04B, stop = 0xF04D, rec = 0xF111, mute = 0xF026, solo = 0xF025, arm = 0xF130, auto = 0xF0E7,
  folder = 0xF07B, file = 0xF1C7, db = 0xF1C0, pm = 0xF02D, wave = 0xF080, loop = 0xF01E, follow = 0xF05B,
  hide = 0xF00D, size = 0xF07E, sample = 0xF001, modulation = 0xF1DE, retro = 0xF1DA, master = 0xF0E4,
  matrix = 0xF00A, trim = 0xF0C4, sync = 0xF021, fill = 0xF009, zoom = 0xF00E, meters = 0xF0AE, inst = 0xF025,
  take = 0xF0A6, grid = 0xF00A, dsp = 0xF1DE, files = 0xF07B, autoprev = 0xF04B,
  monitor = 0xF025, monauto = 0xF0E7, proj = 0xF15B,
}
function D.ic(name, text)
  -- иконки только в TTF-режиме; битмап — строго буквы (решение пользователя)
  local cp = D.icons and not D.hybrid and D.font_id ~= 0 and ICON[name]
  if not cp then return text or name end
  local g = utf8.char(cp)
  if text == nil or text == '' then return g end
  return g .. ' ' .. text
end

function D.field_rect(L, fld)
  if fld == 1 then return L.x_note, L.w_note
  elseif fld == 2 then return L.x_vol, L.w_vol
  elseif fld == 3 then return L.x_del, L.w_del
  else return L.x_fx[fld - 3] or L.x_del, L.w_fx end
end

-- ── волна (вертикальная) ──────────────────────────────────────────────────
-- Инлайн (колонка волны выключена): в поле ноты на cont-строках, как раньше.
-- Колонка волны (L.w_wave > 0): на КАЖДОЙ строке item, слева от ноты, в
-- режимах REAPER: peaks (min..max вокруг оси), rect (модуль от левого края),
-- spec (пики + спектральная окраска: цвет по частоте, как «spectral peaks»).
local function hsv(h, sv, v)
  local c = v * sv; local hp = (h % 360) / 60; local x = c * (1 - math.abs(hp % 2 - 1)); local m = v - c
  local r, g, b
  if hp < 1 then r, g, b = c, x, 0 elseif hp < 2 then r, g, b = x, c, 0 elseif hp < 3 then r, g, b = 0, c, x
  elseif hp < 4 then r, g, b = 0, x, c elseif hp < 5 then r, g, b = x, 0, c else r, g, b = c, 0, x end
  return { r + m, g + m, b + m }
end
local spec_cache = {}
local function spec_colour(sp)
  local si = math.tointeger(math.floor(sp or 0)) or 0
  local freq = math.max(si & 0x7FFF, 30)
  local key = freq // 16
  local c = spec_cache[key]
  if not c then
    local h = math.min(math.log(freq / 60) / math.log(16000 / 60), 1)
    c = hsv(10 + h * 230, 0.6, 0.95); spec_cache[key] = c
  end
  return c
end
D.spec_colour = spec_colour
local function draw_wave(L, head, i, x, y, muted, inv)
  -- волна строго в границах item: дробные начало (start_f) и длина (rows_f)
  local total = math.max(1, math.floor((head.rows_f or head.rows) * L.rh + 0.5))
  local off = math.floor((head.start_f or 0) * L.rh + 0.5)
  local column = L.w_wave > 0
  local mode = L.wave
  local pk = get_peaks and get_peaks(head, math.min(total, 8192), column and mode == 'spec')
  if not pk or pk.n == 0 then return end
  local cx, hw, x0w
  if column then cx = x + L.x_wave + L.w_wave / 2; hw = (L.w_wave / 2) - 1; x0w = x + L.x_wave
  else cx = x + L.x_note + L.w_note / 2; hw = (L.w_note / 2) - 1 end
  local base_col = inv and U.BG or (muted and D.PEAKM or D.PEAK)
  set(base_col)
  local scale = pk.n / total
  for py = 0, L.rh - 1 do
    local q = i * L.rh + py - off          -- пиксель от начала item
    if q >= total then break end
    local idx = math.floor(q * scale) + 1
    if q >= 0 and idx <= pk.n then
    local mx, mn = pk.max[idx] or 0, pk.min[idx] or 0
    if mx > 1 then mx = 1 end; if mn < -1 then mn = -1 end
    if column and mode == 'spec' and pk.spec and not inv then
      local c = spec_colour(pk.spec[idx]); set(muted and U.mix(c, U.BG, 0.5) or c)
    end
    do
      local xa, xb = cx + mn * hw, cx + mx * hw
      if xb - xa < 1 then xa, xb = cx - 0.5, cx + 0.5 end
      gfx.line(xa, y + py, xb, y + py)
    end
    end
  end
  -- stretch-маркеры: янтарная чёрточка во всю ширину колонки на своей строке
  if column and head.smk and not inv then
    set(U.AMBER)
    for _, fr in ipairs(head.smk) do
      local q = math.floor(fr * total)
      local py = q - (i * L.rh - off)
      if py >= 0 and py < L.rh then gfx.line(x0w, y + py, x0w + L.w_wave - 1, y + py) end
    end
  end
  -- границы периода лупа (B_LOOPSRC): тусклые чёрточки по средней половине колонки
  if column and head.loop_rows and head.loop_rows > 0.05 and not inv then
    set(U.mix(U.AMBER, U.BG, 0.45))
    local rows_total = head.rows_f or head.rows or 1
    local q = (head.loop_first or head.loop_rows)
    local k = 0
    while q < rows_total and k < 512 do
      local pq = math.floor(q * L.rh)
      local py = pq - (i * L.rh - off)
      if py >= 0 and py < L.rh then gfx.line(x0w + L.w_wave / 4, y + py, x0w + L.w_wave * 3 / 4, y + py) end
      q = q + head.loop_rows; k = k + 1
    end
  end
end

-- ── ячейка ────────────────────────────────────────────────────────────────
-- Пустые поля рисуются каждое на своём x — точки стоят ровно под текстом.
local EMPTY = { '...', '..', '..' }
local function empty_text(fld) return fld <= 3 and EMPTY[fld] or '...' end

local function draw_cell(L, cell, x, y, ty, inv)
  local function c(fld, col) return (inv == fld) and U.BG or col end
  -- инверсное поле: текст с непрозрачной подложкой цвета заливки
  local text_ = text
  local function text(tx, tyy, str, col)
    if inv and col == U.BG then text_(tx, tyy, str, col, D.inv_bg or U.TEXT) else text_(tx, tyy, str, col) end
  end
  local nf = 3 + L.nfx
  if not cell then
    for fld = 1, nf do
      local fx = D.field_rect(L, fld)
      text(x + fx, ty, empty_text(fld), c(fld, D.EMPTY))
    end
    return
  end
  local k = cell.kind
  if L.w_wave > 0 then
    -- колонка волны: голова и все cont-строки аудио-item
    if k == 'audio' then draw_wave(L, cell, 0, x, y, cell.muted, inv == 1)
    elseif k == 'cont' and cell.of.kind == 'audio' then draw_wave(L, cell.of, cell.i, x, y, cell.of.muted, inv == 1) end
  elseif k == 'cont' and cell.of.kind == 'audio' then
    local head = cell.of
    local text_rows = head.name ~= '' and 2 or 1
    if cell.i >= text_rows then draw_wave(L, head, cell.i, x, y, head.muted, inv == 1) end
  end
  if k == 'audio' or k == 'midi' then
    local muted = cell.muted
    text(x + L.x_note, ty, cell.note, c(1, muted and U.GREY or U.TEXT))
    text(x + L.x_vol, ty, cell.vol, c(2, muted and U.GREY or U.CYAN))
    if cell.delay > 0 then text(x + L.x_del, ty, string.format('%02X', cell.delay), c(3, U.TEXT))
    else text(x + L.x_del, ty, '..', c(3, D.EMPTY)) end
    local fx = cell.fx or {}
    for i = 1, L.nfx do
      if fx[i] then text(x + L.x_fx[i], ty, fx[i], c(3 + i, muted and U.GREY or D.FX))
      else text(x + L.x_fx[i], ty, '...', c(3 + i, D.EMPTY)) end
    end
  elseif k == 'off' then
    text(x + L.x_note, ty, 'OFF', c(1, D.CONT))
    text(x + L.x_vol, ty, '..', c(2, D.EMPTY))
    if cell.delay and cell.delay > 0 then text(x + L.x_del, ty, string.format('%02X', cell.delay), c(3, D.CONT))
    else text(x + L.x_del, ty, '..', c(3, D.EMPTY)) end
    for i = 1, L.nfx do text(x + L.x_fx[i], ty, '...', c(3 + i, D.EMPTY)) end
  elseif k == 'cont' then
    local head = cell.of
    if head.kind == 'audio' then
      if cell.i == 1 and head.name ~= '' then
        -- строка имени: номер инструмента, затем имя — только если влезает
        -- целиком в ширину item (от поля ноты до края подколонки); иначе
        -- один номер (просьба 1 окт: имя не выезжает за рамку)
        local avail = L.sub_w - L.x_note - L.pad
        local n = D.inst_of and D.inst_of[head.item]
        local lbl = n and ('%02d'):format(n) or ''
        local full = (lbl ~= '' and (lbl .. ' ') or '') .. head.name
        if ms(full) <= avail then lbl = full elseif lbl == '' then lbl = fit(head.name, avail) end
        text(x + L.x_note, ty, lbl, c(1, head.muted and U.GREY or U.TEXT))
      end
      local fx = head.fx or {}
      if L.nfx > 0 and cell.i >= 1 then
        for i = 1, L.nfx do
          local v = fx[cell.i * L.nfx + i]
          if v then text(x + L.x_fx[i], ty, v, c(3 + i, D.FX)) end
        end
      end
    else
      text(x + L.x_note + (L.w_note - ms('|')) / 2, ty, '|', c(1, D.CONT))
      for fld = 2, nf do
        local fx = D.field_rect(L, fld)
        text(x + fx, ty, empty_text(fld), c(fld, D.EMPTY))
      end
    end
  end
end

local function draw_fold_cell(L, col, row, x, y, ty, inv)
  local text_ = text
  local function text(tx, tyy, str, c2) if inv then text_(tx, tyy, str, c2, D.inv_bg or U.TEXT) else text_(tx, tyy, str, c2) end end
  local glyph, colr = '.', D.EMPTY
  for _, lane in ipairs(col.lanes) do
    for _, sub in ipairs(lane.subs) do
      local c = sub[row]
      if c and (c.kind == 'audio' or c.kind == 'midi') then
        glyph = 'o'; colr = c.muted and U.GREY or (c.kind == 'midi' and U.CYAN or U.TEXT)
        break
      end
    end
    if glyph == 'o' then break end
  end
  text(x + (L.fold_w - ms(glyph)) / 2, ty, glyph, inv and U.BG or colr)
end

-- огибающая как в аранжировке REAPER: линия значения по строкам, точки —
-- квадратики, hex только у точек
local env_col_cache = {}
local ai_col_cache = {}
local function ai_colour(key)
  local c = ai_col_cache[key]
  if not c then c = U.theme(key, { 0.4, 0.7, 1.0 }); ai_col_cache[key] = c end
  return c
end

local function env_colour(e)
  if not e.key then return U.GREEN end
  local c = env_col_cache[e.key]
  if not c then
    c = U.readable(U.theme(e.key, { 0.3, 0.8, 0.3 }), U.BG, 3.0)
    env_col_cache[e.key] = c
  end
  return c
end

D.env_colour = function(e) return env_colour(e) end   -- для матрицы (мини-огибающие)

local function draw_env_cell(L, ev, prev, x, y, ty, e)
  if not ev then return end
  -- ломаная по подточкам строки (M.ENV_SUB) — без изломов на границах строк;
  -- цвет — тот же, что у этой огибающей в аранжировке (ключ темы)
  local function px_of(v) return x + L.pad + math.floor(v * (L.env_bar_w - 1) + 0.5) end
  set(env_colour(e))
  local pts = { { px_of(ev.v), y } }
  local sub = ev.sub or {}
  local n = #sub + 1
  for j, v in ipairs(sub) do pts[#pts + 1] = { px_of(v), y + L.rh * j / n } end
  for k = 2, #pts do gfx.line(pts[k - 1][1], pts[k - 1][2], pts[k][1], pts[k][2]) end
  local ex, cy = pts[1][1], y + 1
  if ev.pt then
    gfx.rect(ex - 2, cy - 2, 5, 5, 1)
    text(x + L.pad + L.env_bar_w + L.pad, ty, string.format('%02X', math.floor(ev.v * 255 + 0.5)), U.TEXT)
  end
end

-- ── верхняя панель ────────────────────────────────────────────────────────
-- Слева контрол (клик — переключить/цикл, колесо — ±1; hover.ctrl = имя),
-- по центру пик-метры треков (старый добрый VU), справа — инструменты
-- трека курсора: «N имя» + тонкая волна (hover.pool = {ci, i}).
local function meter_color(v)
  if v > 0.9 then return U.RED elseif v > 0.6 then return U.AMBER end
  return U.GREEN
end

-- ── анализатор: скоп / спектр / спектрограмма одного слота моста ──────────
-- mode: 'scope' — осциллограмма (кольцо 256 сэмплов), 'spec' — 48 полос
-- (бары), 'sgram' — спектрограмма: кольцо из SG_COLS столбцов в закадровом
-- изображении 1024+slot (столбец = один кадр FFT моста), на экран — два блита
-- (от головы до конца, затем начало), новое справа. Без reaper.*.
local SG_COLS, SG_ROWS = 64, 48
local sg = {}                 -- slot → { col = следующий столбец, frame = кадр моста }
local function heat(v)
  if v < 0.4 then return U.mix(U.BG, U.GREEN, 0.15 + v / 0.4 * 0.85)
  elseif v < 0.75 then return U.mix(U.GREEN, U.AMBER, (v - 0.4) / 0.35)
  else return U.mix(U.AMBER, U.RED, (v - 0.75) / 0.25) end
end
local function draw_analyzer(x, y, w, h, slot, mode, info)
  if not slot or w < 8 or h < 4 then return end
  set(U.PANEL); gfx.rect(x, y, w, h, 1)
  if mode == 'spec' and info.spec then
    local bands = info.spec(slot)
    if not bands then return end
    local nb = #bands
    local bw = w / nb
    for b = 1, nb do
      local v = bands[b] or 0
      local bh = math.floor(v * (h - 2) + 0.5)
      if bh > 0 then
        set(heat(v))
        gfx.rect(x + math.floor((b - 1) * bw), y + h - 1 - bh, math.max(1, math.floor(bw) - 1), bh, 1)
      end
    end
  elseif mode == 'sgram' and info.spec then
    local st = sg[slot]
    if not st then st = { col = 0, frame = -1 }; sg[slot] = st; gfx.setimgdim(1024 + slot, SG_COLS, SG_ROWS) end
    local fr = info.spec_frame and info.spec_frame(slot) or 0
    if fr ~= st.frame then
      st.frame = fr
      local bands = info.spec(slot)
      if bands then
        local dest = gfx.dest; gfx.dest = 1024 + slot
        local mode0 = gfx.mode; gfx.mode = 0; gfx.a = 1
        for b = 1, SG_ROWS do
          set(heat(bands[math.floor((b - 1) / SG_ROWS * #bands) + 1] or 0))
          gfx.rect(st.col, SG_ROWS - b, 1, 1, 1)
        end
        gfx.dest = dest; gfx.mode = mode0
        st.col = (st.col + 1) % SG_COLS
      end
    end
    local mode0 = gfx.mode; gfx.mode = 0; gfx.a = 1
    local n1 = SG_COLS - st.col            -- старые столбцы: col..end → слева
    local w1 = math.floor(w * n1 / SG_COLS)
    if n1 > 0 then gfx.blit(1024 + slot, 1, 0, st.col, 0, n1, SG_ROWS, x, y, w1, h) end
    if st.col > 0 then gfx.blit(1024 + slot, 1, 0, 0, 0, st.col, SG_ROWS, x + w1, y, w - w1, h) end
    gfx.mode = mode0
  elseif info.scope then
    local sc = info.scope(slot)
    if not sc then return end
    set(U.GREEN)
    local cy, hh = y + h / 2, h / 2 - 1
    local prevx, prevy
    for px = 0, w - 1 do
      local v = sc[math.floor(px / w * #sc) + 1] or 0
      if v > 1 then v = 1 elseif v < -1 then v = -1 end
      local yy = cy - v * hh
      if prevx then gfx.line(prevx, prevy, x + px, yy) end
      prevx, prevy = x + px, yy
    end
  end
end
D.draw_analyzer = draw_analyzer

-- «призрак» перетаскивания (DSP-блок и т.п.): янтарная бирка у курсора
function D.ghost(label)
  if not label then return end
  local bw = ms(label) + 2 * 6
  local x, y = gfx.mouse_x + 12, gfx.mouse_y - TH() // 2
  set(U.AMBER); gfx.rect(x, y, bw, TH() + 2, 1)
  set(U.BG); gfx.rect(x, y, bw, TH() + 2, 0)
  text(x + 6, y + 1, label, U.BG, U.AMBER)
end

local function draw_topbar(L, info)
  local hover = {}
  local H = L.top_h
  set(U.PANEL); gfx.rect(0, 0, L.win_w, H, 1)
  set(D.SEP); gfx.rect(0, H - 2, gfx.w, 2, 1)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local c = info.ctrl or {}

  -- контрол: сетка 3 колонки × 4 строки
  local items = {
    { 'play', (D.icons and (D.ic(c.playing and 'play' or 'stop', '') .. ' ') or (c.playing and '> ' or '# ')) .. (c.pos or ''), c.playing and U.GREEN or U.TEXT },
    { 'bpm', ('BPM %.1f'):format(c.bpm or 0) }, { 'lpb', ('LPB %d'):format(c.lpb or 0) },
    { 'oct', ('oct %d'):format(c.oct or 0) }, { 'step', 'step ' .. tostring(c.step or 0) }, { 'inst', ('inst %d'):format(c.inst or 0) },
    { 'vel', ('vel %d'):format(c.vel or 100) },
    { 'follow', D.ic('follow', 'follow ' .. (c.follow and 'on' or 'off')), c.follow and U.CYAN or U.GREY },
    { 'loop', D.ic('loop', 'loop ' .. (c.loop and 'on' or 'off')), c.loop and U.CYAN or U.GREY },
    { 'pitch', 'pitch ' .. (c.pitchmode or 'shift') },
    { 'font', (c.font or 0) > 0 and ('font %d'):format(c.font) or ('bitmap x%d'):format(math.floor(c.scale or 1)) }, { 'fx', ('fx %d'):format(c.fx or 0) },
    { 'meters', 'meters ' .. (c.meters and 'on' or 'off'), c.meters and U.CYAN or U.GREY },
    { 'wave', 'wv ' .. ((c.wave and c.wave ~= 'off') and 'on' or 'off'), (c.wave and c.wave ~= 'off') and U.CYAN or U.GREY },
    { 'options', 'options', U.AMBER },
    { 'xfade', c.xfade and ('xf %dms'):format(c.xfade_ms or 10) or 'xf off', c.xfade and U.CYAN or U.GREY },
    { 'lock', 'lock ' .. (c.lock and 'on' or 'off'), c.lock and U.CYAN or U.GREY },
    { 'fixed', 'fixed ' .. (c.fixed and 'on' or 'off'), c.fixed and U.CYAN or U.GREY },
  }
  local colw = math.floor((L.ctrl_w - 2 * L.pad) / 3)
  local rows_fit = math.max(1, math.floor((H - 4) / L.rh))
  for i, it in ipairs(items) do
    local ci, ri = (i - 1) % 3, math.floor((i - 1) / 3)
    if ri >= rows_fit then break end
    local x, y = L.pad + ci * colw, 2 + ri * L.rh
    local hot = mx >= x and mx < x + colw and my >= y and my < y + L.rh
    if hot then set(D.CURROW); gfx.rect(x, y, colw - 2, L.rh, 1); hover.ctrl = it[1] end
    text(x + 2, y + 1, fit(it[2], colw - 4), it[3] or U.TEXT)
    hint('ctrl', x, y, colw, L.rh, it[1])
  end
  -- mono-модуль (jf_grid): состояние шины, владелец, мини-грид того, что
  -- показывает мод трекера, легенда. Кнопки take / grid — владение поверхностью.
  do
    local mo = info.mono
    local y0 = 2 + math.min(rows_fit, math.ceil(#items / 3)) * L.rh + 2
    if mo and H - y0 > 2 * L.rh then
      set(D.SEP); gfx.rect(L.pad, y0, L.ctrl_w - 2 * L.pad, 1, 1)
      y0 = y0 + 2
      local st = mo.alive and ('grid ' .. (mo.grid and 'ok' or '--') .. '  arc ' .. (mo.arc and 'ok' or '--') .. '  owner ' .. (mo.owner_name or '-'))
                 or 'daemon jf_grid: not running'
      text(L.pad + 2, y0 + 1, fit('mono  ' .. st, L.ctrl_w - 2 * L.pad - ms('[take][grid]') - L.pad), mo.alive and (mo.owner_id == 9 and U.AMBER or U.TEXT) or U.GREY)
      -- кнопки справа
      local bx = L.ctrl_w - L.pad
      for _, b in ipairs({ { 'grid', 'grid' }, { 'take', 'take' } }) do
        local bw = ms(b[1]) + 2 * L.pad
        bx = bx - bw
        local on = (b[2] == 'take' and mo.owner_id == 9) or (b[2] == 'grid' and mo.alive and mo.owner_id == 0)
        local hot = mx >= bx and mx < bx + bw and my >= y0 and my < y0 + L.rh
        set(on and U.tint(U.AMBER, 0.3) or (hot and D.CURROW or U.BG)); gfx.rect(bx, y0, bw, L.rh, 1)
        set(on and U.AMBER or U.LINE); gfx.rect(bx, y0, bw, L.rh, 0)
        text(bx + L.pad, y0 + 1, b[1], on and U.AMBER or (hot and U.TEXT or U.GREY))
        if hot then hover.monobtn = b[2] end
        hint('monobtn', bx, y0, bw, L.rh, b[2])
        bx = bx - L.pad
      end
      y0 = y0 + L.rh + 2
      -- мини-грид 16×8 (яркость как на устройстве) + легенда справа
      local avail = H - 2 - y0
      local cs = math.max(2, math.min(math.floor((L.ctrl_w * 0.45) / 16), math.floor(avail / 8)))
      if mo.leds then
        for ry = 1, 8 do
          for cx = 1, 16 do
            local v = (mo.leds[ry] and mo.leds[ry][cx]) or 0
            set(U.mix(U.BG, U.AMBER, 0.08 + v / 15 * 0.92))
            gfx.rect(L.pad + (cx - 1) * cs, y0 + (ry - 1) * cs, cs - 1, cs - 1, 1)
          end
        end
      end
      -- подписи: над сеткой буквы треков, под нижним рядом — что делает кнопка
      if mo.cols then
        for cx = 1, math.min(15, #mo.cols) do
          local ch = (mo.cols[cx] or '?'):sub(1, 1)
          if cs >= L.cw then text(L.pad + (cx - 1) * cs, y0 - L.rh, ch, U.GREY) end
        end
      end
      -- легенда — горизонтально справа от мини-грида
      local lx = L.pad + 16 * cs + L.pad
      local lw = L.ctrl_w - lx - L.pad
      local lines = { 'rows 1-7: slots x tracks', 'lit: events  X: muted', 'arc: 1 lpb 2 oct 3 step 4 inst', 'col 16: host (mod list)' }
      for i, ln in ipairs(lines) do
        local ly = y0 + (i - 1) * L.rh
        if ly + L.rh > H - 2 then break end
        text(lx, ly + 1, fit(ln, lw), U.GREY)
      end
      -- под клетками нижнего ряда — что делает каждая кнопка, тонко и
      -- вертикально (повёрнутый битмап D.vtext), по одной подписи на клетку
      local names = { 'play', 'stop', 'rec', 'follow', 'loop', '', 'lpb-', 'lpb+', 'oct-', 'oct+', 'step-', 'step+', 'inst-', 'inst+', '', 'host' }
      local vy = y0 + 8 * cs + 2
      local vh = H - 2 - vy
      if cs >= L.th + 1 and vh >= L.cw * 3 then
        for cx = 1, 16 do
          if names[cx] ~= '' then
            D.vtext(L.pad + (cx - 1) * cs + math.floor((cs - L.th) / 2), vy, vh, names[cx], cx == 16 and U.DIM or U.GREY, U.PANEL)
          end
        end
      end
    end
  end
  set(D.SEP); gfx.rect(L.ctrl_w, 0, 2, H - 2, 1)

  -- центр: вкладки scope | sample | mod | retro | master
  local sx0 = L.ctrl_w + L.pad
  local sx1 = L.win_w - L.inst_w - L.pad
  local tab = info.toptab or 'scope'
  local tx = sx0
  if tab == 'scope' then tab = 'master' end   -- вкладки scope больше нет: анализаторы в master
  for _, t in ipairs({ 'sample', 'modulation', 'retro', 'garden', 'master' }) do
    local lbl = D.ic(t, t)
    local tw = ms(lbl) + 2 * L.pad
    local on = t == tab
    local hot = mx >= tx and mx < tx + tw and my >= 1 and my < 1 + L.rh
    set(on and U.tint(U.AMBER, 0.35) or (hot and D.CURROW or U.BG)); gfx.rect(tx, 1, tw, L.rh, 1)
    set(on and U.AMBER or U.LINE); gfx.rect(tx, 1, tw, L.rh, 0)
    text(tx + L.pad, 1, lbl, on and U.AMBER or U.GREY)
    if hot then hover.tab = t end
    hint('tab', tx, 1, tw, L.rh, t)
    tx = tx + tw + 2
  end
  -- режим анализатора (scope / spec / sgram) — для вкладок scope и master, как
  -- переключатель режима пиков в REAPER
  local amode = info.scopemode or 'scope'
  if tab == 'master' then
    local bx = sx1 - L.pad
    for _, m in ipairs({ 'sgram', 'spec', 'scope' }) do
      local bw = ms(m) + 2 * L.pad
      bx = bx - bw
      local on = m == amode
      local hot = mx >= bx and mx < bx + bw and my >= 1 and my < 1 + L.rh
      set(on and U.tint(U.CYAN, 0.3) or (hot and D.CURROW or U.BG)); gfx.rect(bx, 1, bw, L.rh, 1)
      set(on and U.CYAN or U.LINE); gfx.rect(bx, 1, bw, L.rh, 0)
      text(bx + L.pad, 1, m, on and U.CYAN or (hot and U.TEXT or U.GREY))
      if hot then hover.scopemode = m end
      hint('scopemode', bx, 1, bw, L.rh, m)
      bx = bx - 2
    end
  end
  local cy0 = 1 + L.rh + 3           -- верх содержимого вкладки
  L.top_rect = { sx0 - L.pad, 0, sx1 - sx0 + 2 * L.pad, H - 2 }
  local cols = info.cols or {}
  if tab == 'sample' and info.sample_draw then
    -- редактор сэмпла (слайсер) прямо под вкладкой
    hover.sample = info.sample_draw(sx0, cy0, sx1 - sx0 - L.pad, H - cy0 - 2)
  elseif tab == 'sample' then
    local col, e = info.pool_col, nil
    if col then e = (col.pool or {})[info.inst or 1] end
    if e then
      local ww, wh = sx1 - sx0 - L.pad, H - cy0 - L.rh - 4
      local wx = sx0
      text(wx, cy0, fit(('%s  offs %.3f  len %.3f  rate %.2f%s'):format(e.name, e.offs or 0, e.len or 0, e.rate or 1, e.slices and ('  slices ' .. #e.slices) or ''), ww), U.TEXT)
      local wy = cy0 + L.rh
      set(U.PANEL); gfx.rect(wx, wy, ww, wh, 1)
      local pk = get_peaks and get_peaks(e, ww)
      local cy, hh = wy + wh / 2, wh / 2 - 1
      set(U.readable(U.mix(e.rgb or U.LINE, U.TEXT, 0.35), U.BG, 4.0))
      if pk and pk.n > 0 then
        for px = 0, ww - 1 do
          local idx = math.floor(px / ww * pk.n) + 1
          local a, b = pk.min[idx] or 0, pk.max[idx] or 0
          if b - a < 0.02 then a, b = -0.01, 0.01 end
          gfx.line(wx + px, cy - b * hh, wx + px, cy - a * hh)
        end
      else gfx.line(wx, cy, wx + ww, cy) end
      for k, t in ipairs(e.slices or {}) do
        local px = wx + math.floor(t / (e.len > 0 and e.len or 1) * ww)
        set(U.AMBER); gfx.rect(px, wy, 1, wh, 1)
      end
      if mx >= wx and mx < wx + ww and my >= wy and my < wy + wh then hover.sample = e end
    else
      text(sx0, cy0, 'no instrument', U.GREY)
    end
  elseif tab == 'modulation' then
    -- модуляционная матрица (jf_tracker_modmatrix.lua): таблица L1 / ENV / LNK
    if info.mm_draw then hover.mm = info.mm_draw(L, sx0, cy0, sx1 - sx0, H - cy0 - 2) end
  elseif tab == 'garden' then
    -- Garden (jf_tracker_garden.lua): лупы регион × трек и поле Orca
    if info.garden_draw then hover.garden = info.garden_draw(L, sx0, cy0, sx1 - sx0, H - cy0 - 2) end
  elseif tab == 'master' then
    -- мастер: метры L/R, анализатор (скоп слот 31), цепь FX
    local m = info.master
    if not m then text(sx0, cy0, 'no master info', U.GREY)
    else
      local mh = H - cy0 - L.rh - 4
      local bw = math.max(3, L.cw)
      local x = sx0
      for k, v in ipairs({ m.peaks and m.peaks[1] or 0, m.peaks and m.peaks[2] or 0 }) do
        local bx = x + (k - 1) * (bw + 2)
        set(U.DIM); gfx.rect(bx, cy0, bw, mh, 1)
        local hpx = math.floor(math.min(1, v) * mh + 0.5)
        if hpx > 0 then set(meter_color(v)); gfx.rect(bx, cy0 + mh - hpx, bw, hpx, 1) end
      end
      text(x, cy0 + mh + 1, 'L R', U.GREY)
      x = x + 2 * bw + 6 + L.pad
      local fxw = math.min(L.cw * 18, math.floor((sx1 - x) * 0.4))
      local aw = sx1 - x - fxw - 2 * L.pad
      if m.scope_slot and aw > 20 then draw_analyzer(x, cy0, aw, mh, m.scope_slot, amode, info)
      else text(x, cy0, fit('no scope on master (:scopes)', aw), U.GREY) end
      text(x, cy0 + mh + 1, fit('MASTER ' .. amode, aw), U.AMBER)
      -- цепь FX мастера
      local fx0 = x + aw + L.pad
      text(fx0, cy0, 'fx', U.GREY)
      local nvis = math.max(1, math.floor((H - cy0 - 2) / L.rh) - 1)
      for i, f in ipairs(m.fx or {}) do
        if i > nvis then break end
        local fy = cy0 + i * L.rh
        text(fx0, fy, fit((f.enabled and '' or '(off) ') .. f.name, fxw - L.pad), f.enabled and U.TEXT or U.GREY)
      end
      if #(m.fx or {}) == 0 then text(fx0, cy0 + L.rh, 'no fx', U.GREY) end
    end
  elseif tab == 'retro' then
    -- ретро-сэмплер (jf_rec на треке): буфер, выделение, вставка
    local r = info.retro
    local y = cy0
    if not r or #r.tracks == 0 then
      text(sx0, y, 'no jf_rec on any track - a: add to cursor track (40 s ring buffer)', U.GREY)
      local bw = ms('add') + 2 * L.pad
      local hot = mx >= sx0 and mx < sx0 + bw and my >= y + L.rh and my < y + 2 * L.rh
      set(hot and D.CURROW or U.BG); gfx.rect(sx0, y + L.rh, bw, L.rh, 1); set(U.LINE); gfx.rect(sx0, y + L.rh, bw, L.rh, 0)
      text(sx0 + L.pad, y + L.rh + 1, 'add', hot and U.AMBER or U.TEXT)
      if hot then hover.retrobtn = 'add' end
      hint('retrobtn', sx0, y + L.rh, bw, L.rh, 'add')
    else
      local c = r.cur
      -- строка 1: трек ‹ ›, статус буфера, кнопки
      local bx = sx0
      local function btn(label, what, on)
        local bw = ms(label) + 2 * L.pad
        local hot = mx >= bx and mx < bx + bw and my >= y and my < y + L.rh
        set(on and U.tint(U.AMBER, 0.3) or (hot and D.CURROW or U.BG)); gfx.rect(bx, y, bw, L.rh, 1)
        set(on and U.AMBER or U.LINE); gfx.rect(bx, y, bw, L.rh, 0)
        text(bx + L.pad, y + 1, label, on and U.AMBER or (hot and U.TEXT or U.GREY))
        if hot then hover.retrobtn = what end
        hint('retrobtn', bx, y, bw, L.rh, what)
        bx = bx + bw + 2
      end
      btn('<', 'prev'); 
      text(bx, y + 1, fit((c and c.col.name or '?') .. ' #' .. tostring(c and c.slot or '?'), L.cw * 10), U.AMBER); bx = bx + L.cw * 10 + 2
      btn('>', 'next')
      bx = bx + L.pad
      btn('all', 'all'); btn('play', 'play', c and c.playing); btn('stop', 'stop'); btn('put', 'put'); btn('depot', 'depot'); btn('add', 'add')
      local st = c and (c.alive and (('%ds %s head %d%%'):format(c.len, c.writing and 'rec' or 'paused', math.floor(c.head * 100))) or 'jf_rec silent: open its panel / enable') or ''
      text(bx + L.pad, y + 1, fit(st, sx1 - bx - 2 * L.pad), c and c.alive and (c.writing and U.RED or U.GREY) or U.GREY)
      y = y + L.rh + 2
      -- волна буфера: старое слева, голова справа; выделение a..b
      local wx, ww, wh = sx0, sx1 - sx0 - L.pad, H - y - L.rh - 3
      if c and ww > 16 and wh > 6 then
        set(U.PANEL); gfx.rect(wx, y, ww, wh, 1)
        local pk = c.peaks
        local cy, hh = y + wh / 2, wh / 2 - 1
        local a, b = r.sel.a, r.sel.b
        if b < a then a, b = b, a end
        set(U.tint(U.AMBER, 0.25)); gfx.rect(wx + math.floor(a * ww), y, math.max(1, math.floor((b - a) * ww)), wh, 1)
        if pk then
          set(U.readable(U.mix(c.col.rgb or U.TEXT, U.TEXT, 0.3), U.BG, 4.0))
          for px = 0, ww - 1 do
            local i = math.floor(px / ww * pk.n) + 1
            local mxv, mnv = pk.max[i] or 0, pk.min[i] or 0
            if mxv - mnv < 0.01 then mxv, mnv = 0.005, -0.005 end
            gfx.line(wx + px, cy - mxv * hh, wx + px, cy - mnv * hh)
          end
        end
        -- маркеры выделения и курсор превью
        set(U.AMBER); gfx.rect(wx + math.floor(a * ww), y, 1, wh, 1); gfx.rect(wx + math.floor(b * ww) - 1, y, 1, wh, 1)
        if c.pb and c.pb > 0 then set(U.GREEN); gfx.rect(wx + math.floor(c.pb * ww), y, 1, wh, 1) end
        if mx >= wx and mx < wx + ww and my >= y and my < y + wh then hover.retro = (mx - wx) / ww end
        hint('retro', wx, y, ww, wh, true)
        local secs = c.len * (b - a)
        text(wx, y + wh + 1, fit(('sel %.2fs  drag: select · a: all · Space: play · p: put @cursor · d: to depot (=LIB) · [ ]: edges'):format(secs), ww), U.GREY)
      elseif not c then
        text(wx, y, 'select a track with jf_rec (< >)', U.GREY)
      end
    end
  elseif #cols > 0 and sx1 - sx0 > 20 then
    -- квадраскоп: осциллограф из gmem (мост jf_tracker_scope), под ним метры
    local w = math.min(L.cw * 14, math.floor((sx1 - sx0) / #cols))
    local mh = H - cy0 - L.rh - 4
    for i, col in ipairs(cols) do
      local x = sx0 + (i - 1) * w
      if x + w > sx1 then break end
      local pl, pr = 0, 0
      if info.peaks then pl, pr = info.peaks(col) end
      local bw = math.max(2, math.floor((w - 6) / 2))
      if col.scope_slot and info.scope then
        local ox, ow, oh = x + 2, w - 4 - bw * 2 - 4, mh
        if ow > 8 then
          draw_analyzer(ox, cy0, ow, oh, col.scope_slot, amode, info)
          x = x + ow + 2   -- метры правее скопа
        end
      end
      for k, v in ipairs({ pl, pr }) do
        local bx = x + 2 + (k - 1) * (bw + 1)
        set(U.DIM); gfx.rect(bx, cy0, bw, mh, 1)
        local hpx = math.floor(math.min(1, v) * mh + 0.5)
        if hpx > 0 then set(meter_color(v)); gfx.rect(bx, cy0 + mh - hpx, bw, hpx, 1) end
      end
      text(x + 2, cy0 + mh + 1, fit(col.name, w - 4), col == info.pool_col and U.AMBER or U.GREY)
      if mx >= x and mx < x + w and my < H then hover.scope = col end
      hint('scope', x, cy0, w, mh, col)
    end
  end

  -- инструменты: в верхней панели, только если сайдбар скрыт
  if L.inst_w > 0 then D.draw_instruments(L, info, gfx.w - L.inst_w, 0, L.inst_w, H, hover) end
  return hover
end

-- ── инструменты проекта (общий список, как в Renoise 3) ───────────────────
-- Прямоугольник (ix, iy, w, H); hover.pool / hover.prevbtn. «@» — сэмпл
-- используется на треке курсора; у выбранного — список треков.
-- Порядок показа пула (номера = индексы пула, не меняются):
--   track — группы по первому треку использования (порядок колонок), внутри
--           по длине; библиотека (*) — последней группой
--   len   — плоско по длине;  mark — плоско: @ (трек курсора), $, *, прочие
-- Возвращает список строк { hdr = имя } | { i = индекс пула }
function D.pool_rows(pool, sort, col, cols)
  local rows = {}
  if sort == 'len' or sort == 'mark' then
    local idx = {}
    for i = 1, #pool do idx[i] = i end
    local function rank(e)
      local here = col and e.track_set and e.track_set[col.name]
      return (here and 0 or 4) + (e.slices and 0 or 2) + ((e.depot and not (e.tracks and e.tracks[1])) and 1 or 0)
    end
    table.sort(idx, function(a, b)
      local ea, eb = pool[a], pool[b]
      if sort == 'mark' then local ra, rb = rank(ea), rank(eb); if ra ~= rb then return ra < rb end end
      if ea.len ~= eb.len then return ea.len < eb.len end
      return a < b
    end)
    for _, i in ipairs(idx) do rows[#rows + 1] = { i = i } end
    return rows
  end
  -- дерево (2 окт): пул уже упорядочен моделью — трек (где лежит исходник),
  -- исходный сэмпл, под ним его слайсы; заголовок при смене трека корня
  local cur_home
  for i, e in ipairs(pool) do
    if (e.depth or 0) == 0 and e.home ~= cur_home then
      cur_home = e.home
      rows[#rows + 1] = { hdr = e.home or '?', name = e.home }
    end
    rows[#rows + 1] = { i = i }
  end
  return rows
end

D.pool_scroll = 0
D.pool_dbg = ''
function D.draw_instruments(L, info, ix, iy, w, H, hover)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  set(U.PANEL); gfx.rect(ix, iy, w, H, 1)
  set(D.SEP); gfx.rect(ix - 2, iy, 2, H - 2, 1)
  L.inst_rect = { ix, iy, w, H - 2 }
  local col = info.pool_col
  local pool = col and col.pool or {}
  local inst = info.inst or 1
  local cur = pool[inst]
  local head = ('instruments %d'):format(#pool)
  if cur and cur.tracks and #cur.tracks > 0 then head = head .. '  @ ' .. table.concat(cur.tracks, ', ') end
  -- справа — кнопка сортировки (track / len / mark)
  local sort = info.poolsort or 'track'
  local sb = 'sort ' .. sort
  local sbw = ms(sb) + 2 * L.pad
  local sbx = ix + w - sbw - L.pad
  do
    local hot = mx >= sbx and mx < sbx + sbw and my >= iy + 2 and my < iy + 2 + L.rh
    set(hot and D.CURROW or U.BG); gfx.rect(sbx, iy + 2, sbw, L.rh, 1)
    set(U.LINE); gfx.rect(sbx, iy + 2, sbw, L.rh, 0)
    text(sbx + L.pad, iy + 3, sb, U.GREY)
    if hot then hover.poolsort = true end
    hint('poolsort', sbx, iy + 2, sbw, L.rh, true)
  end
  text(ix + L.pad, iy + 3, fit(head, sbx - ix - 2 * L.pad), U.GREY)
  -- внизу — два буквенных тоггла (2 окт): звук при выборе / звук при вставке
  do
    local by = iy + H - L.rh - 3
    local bx = ix + L.pad
    local function tbtn(lbl, on, key)
      local bw = ms(lbl) + 2 * L.pad
      local hot = mx >= bx and mx < bx + bw and my >= by and my < by + L.rh
      set(on and U.tint(U.AMBER, 0.25) or (hot and D.CURROW or U.BG)); gfx.rect(bx, by, bw, L.rh, 1)
      set(on and U.AMBER or U.LINE); gfx.rect(bx, by, bw, L.rh, 0)
      text(bx + L.pad, by, lbl, on and U.AMBER or (hot and U.TEXT or U.GREY))
      if hot then hover[key] = true end
      hint(key, bx, by, bw, L.rh, true)
      bx = bx + bw + L.pad
    end
    tbtn('select', info.poolprev, 'prevbtn')
    tbtn('insert', info.inspreview, 'insprevbtn')
    -- легенда меток
    local lg = '@ on cursor track  $ sliced  sN slice'
    text(bx + L.pad, by, fit(lg, ix + w - bx - 2 * L.pad), U.DIM)
  end
  local rows = D.pool_rows(pool, sort, col, info.cols)
  L.pool_rows = rows
  local nvis = math.max(1, math.floor((H - 2 * L.rh - 6) / L.rh))
  -- прокрутка: выбранный инструмент (и его заголовок группы) в окне
  local sel_r = 1
  for r, row in ipairs(rows) do if row.i == inst then sel_r = r end end
  local hdr_r = sel_r
  while hdr_r > 1 and not rows[hdr_r].hdr do hdr_r = hdr_r - 1 end
  if sel_r > D.pool_scroll + nvis then D.pool_scroll = sel_r - nvis end
  if hdr_r <= D.pool_scroll then D.pool_scroll = hdr_r - 1 end
  if D.pool_scroll > math.max(0, #rows - nvis) then D.pool_scroll = math.max(0, #rows - nvis) end
  if D.pool_scroll < 0 then D.pool_scroll = 0 end
  local label_w = math.min(L.cw * 18, math.floor(w * 0.55))
  -- цвет трека по имени — запасной цвет волны, когда у item нет своего
  local trgb = {}
  for _, c in ipairs(info.cols or {}) do if c.rgb and not trgb[c.name] then trgb[c.name] = c.rgb end end
  local dbg = {}
  for r = D.pool_scroll + 1, math.min(#rows, D.pool_scroll + nvis) do
    local row = rows[r]
    local y = iy + 2 + L.rh + (r - D.pool_scroll - 1) * L.rh
    if row.hdr then
      local hrgb = trgb[row.name] or U.LINE
      set(hrgb); gfx.rect(ix + 2, y + 1, 2, L.rh - 2, 1)
      local tw = ms(row.hdr)
      text(ix + 6, y + 1, fit(row.hdr, w - 12), U.TEXT)
      -- разделитель: длинная линия после имени
      set(U.LINE); gfx.rect(ix + 6 + tw + L.pad, y + math.floor(L.rh / 2), w - 8 - tw - 2 * L.pad, 1, 1)
    else
      local i = row.i
      local e = pool[i]
      local rgb = e.rgb or (e.tracks and trgb[e.tracks[1]]) or (col and col.rgb) or U.GREY
      local sel = i == inst
      local here = col and e.track_set and e.track_set[col.name]
      local lib = e.depot and not (e.tracks and e.tracks[1])
      if sel then set(U.tint(U.AMBER, 0.30)); gfx.rect(ix + 1, y, w - 2, L.rh, 1) end
      set(rgb); gfx.rect(ix + 2, y + 1, 2, L.rh - 2, 1)
      -- метки: @ трек курсора, $ нарезан; ребёнок (слайс / кусок исходника) —
      -- с отступом и sN вместо имени исходника (дерево как в Renoise, 2 окт)
      local child = (e.depth or 0) > 0
      local marks = (here and '@' or ' ') .. (e.slices and '$' or ' ')
      local body
      if child then body = ' ' .. (e.slice_k and e.slice_k > 0 and ('s' .. e.slice_k) or 'cut') .. ' ' .. ('%.2fs'):format(e.len)
      else body = e.name .. (e.slices and (' /' .. #e.slices) or '') end
      local lbl = ('%02d %s %s%s'):format(i, marks, body, e.muted and ' (muted)' or '')
      text(ix + 6, y + 1, fit(lbl, label_w - 6), sel and U.AMBER or (e.muted and U.GREY or (here and U.TEXT or U.GREY)))
      do
        local mx0 = ix + 6 + ms('00 ')
        if mx >= mx0 and mx < mx0 + ms(marks) + L.pad and my >= y and my < y + L.rh then hover.poolmark = { i = i, e = e, here = here, lib = lib } end
      end
      local wx = ix + 6 + label_w + L.pad
      local npix = w - (wx - ix) - L.pad
      if npix > 8 then
        local pk = get_peaks and get_peaks(e, npix)
        local cy, hh = y + L.rh / 2, L.rh / 2 - 1
        local wc = U.readable(U.mix(rgb, U.TEXT, 0.35), U.BG, 4.0)
        if e.muted then wc = U.mix(wc, U.BG, 0.45) end
        set(wc)
        if pk and pk.n > 0 then
          for px = 0, npix - 1 do
            local idx = math.floor(px / npix * pk.n) + 1
            local a, b = pk.min[idx] or 0, pk.max[idx] or 0
            if b - a < 0.03 then a, b = -0.015, 0.015 end
            gfx.line(wx + px, cy - b * hh, wx + px, cy - a * hh)
          end
        else gfx.line(wx, cy, wx + npix, cy) end
        dbg[#dbg + 1] = ('%02d wx%d n%d pk%s wc%.2f,%.2f,%.2f'):format(i, wx, npix, pk and pk.n or '-', wc[1], wc[2], wc[3])
      end
      if mx >= ix and mx < ix + w and my >= y and my < y + L.rh then hover.pool = { ci = info.pool_ci, i = i } end
      hint('pool', ix + 2, y, w - 4, L.rh, i)
    end
  end
  D.pool_dbg = table.concat(dbg, ' | ')
end

-- ── кадр ──────────────────────────────────────────────────────────────────
-- info: ph_row, cur_row, playing, status_left/right, vcur, vis, focus,
--       regions, env_values(e), pool_col, inst, browser_draw(L,x,y,w,h)
-- hover: row, fi, field, cell, col, header_col, matrix={ri,ci}, pool, browser
function D.frame(L, snap, rows, state, info)
  local W = L.win_w
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover = {}
  local tx0 = L.matrix_w

  if L.top_h > 0 then
    local th = draw_topbar(L, info)
    hover.ctrl, hover.scope, hover.pool, hover.tab, hover.mod, hover.sample, hover.prevbtn = th.ctrl, th.scope, th.pool, th.tab, th.mod, th.sample, th.prevbtn
    hover.insprevbtn = th.insprevbtn
    hover.scopemode, hover.monobtn, hover.retrobtn, hover.retro = th.scopemode, th.monobtn, th.retrobtn, th.retro
    hover.mm = th.mm
    hover.garden = th.garden
  end

  -- заголовок
  local hy = L.header_y
  set(U.PANEL); gfx.rect(tx0, hy, W - tx0, L.header_h, 1)
  for _, c in ipairs(L.cols) do
    local col = c.col
    -- папки: вложенные треки сдвинуты и приглушены, папка помечена «+»
    local indent = (col.depth or 0) * L.cw
    local nm = (col.folder and ((state.fcollapse and state.fcollapse[col.guid]) and '> ' or '- ') or '') .. (col.name ~= '' and col.name or '-')
    -- имя трека — на всю ширину колонки (кнопки переехали строкой ниже)
    text(c.x + L.pad + indent, hy + 1, fit(nm, c.w - 2 * L.pad - indent),
         col.muted and U.GREY or ((col.depth or 0) > 0 and U.mix(U.TEXT, U.GREY, 0.4) or U.TEXT))
    if col.rgb then set(col.rgb); gfx.rect(c.x + 1 + indent, hy + L.rh - 1, c.w - 2 - indent, 2, 1) end
    if (col.depth or 0) > 0 then set(U.DIM); gfx.rect(c.x + 1, hy, indent - 2, L.header_h - 1, 1) end
    hint('header', c.x + indent, hy, math.max(L.cw * 3, c.w - indent), L.rh, col)
    -- строка 2: кнопки в порядке REAPER — R I M S A (A = автоматизация, как trim)
    if not c.folded then
      local by = hy + L.rh + 1
      local bx = c.x + L.pad + indent
      -- A — индикатор автоматизации: есть огибающие у трека; залит, когда
      -- они показаны (`a`), только контур — когда спрятаны; клик = `a`
      local nenv = #(col.envs or {})
      local env_shown = state.trackenvs and state.trackenvs[col.guid]
      if env_shown == nil then env_shown = state.envs end
      -- M S R — буквами всегда (решение пользователя); A и мониторинг — иконками,
      -- без иконок — A и I. Мониторинг: 0 выкл, 1 вкл, 2 авто (tape) — контур
      local mon = col.recmon or 0
      local labels = { { 'R', col.armed, U.RED, 'arm' },
                       { 'I', mon > 0, U.CYAN, 'monitor', mon == 2 },
                       { 'M', col.muted, U.AMBER, 'mute' }, { 'S', col.solo, U.GREEN, 'solo' },
                       { 'A', nenv > 0, U.CYAN or U.AMBER, 'auto' } }
      for k, b in ipairs(labels) do
        local x = bx + (k - 1) * (L.btn_w + 1)
        if x + L.btn_w > c.x + c.w - 1 then break end
        local on = b[2]
        local fill = on and (b[4] ~= 'auto' or env_shown) and not b[5]   -- b[5]: мониторинг «авто» — только контур
        set(fill and U.tint(b[3], 0.5) or U.PANEL); gfx.rect(x, by, L.btn_w, L.rh - 2, 1)
        set(on and b[3] or U.DIM); gfx.rect(x, by, L.btn_w, L.rh - 2, 0)
        text(x + 2, by, b[1], on and b[3] or U.GREY)
        if mx >= x and mx < x + L.btn_w and my >= by and my < by + L.rh then hover.btn = { col = col, what = b[4] } end
        hint('btn', x, by, L.btn_w, L.rh, { col = col, what = b[4] })
      end
      -- строки 3 и 4: громкость и панорама — горизонтальные слайдеры как в DSP;
      -- панорама: stereo pan (5) — pan + width, dual pan (6) — L + R в одной строке
      local live = info.trs_live
      local function slider(sx, sy, sw, frac, centered, label, val, what)
        local vw = ms(val) + L.pad
        local lw = ms(label) + L.pad
        local wx0, ww = sx + lw, math.max(4, sw - lw - vw - L.pad)
        local cy = sy + math.floor(L.rh / 2)
        local hot = mx >= wx0 - 2 and mx < wx0 + ww + 2 and my >= sy and my < sy + L.rh
        local acc = hot and U.AMBER or U.TEXT
        text(sx, sy, label, U.GREY)
        set(U.DIM); gfx.rect(wx0, cy - 1, ww, 2, 1)
        frac = math.max(0, math.min(1, frac))
        if centered then
          local mid = wx0 + math.floor(ww / 2)
          local px = wx0 + math.floor(frac * ww + 0.5)
          set(acc); gfx.rect(math.min(mid, px), sy + 4, math.max(1, math.abs(px - mid)), L.rh - 8, 1)
          set(U.LINE); gfx.rect(mid, sy + 3, 1, L.rh - 6, 1)
        else
          set(acc); gfx.rect(wx0, sy + 4, math.max(1, math.floor(frac * ww + 0.5)), L.rh - 8, 1)
        end
        text(wx0 + ww + L.pad, sy, val, U.GREY)
        if hot then hover.trs = { col = col, what = what, x0 = wx0, w = ww, sv = math.max(0, math.min(1, (mx - wx0) / math.max(1, ww))) } end
        hint('trs', wx0, sy, ww, L.rh, { col = col, what = what })
      end
      local function db_of(v) return v > 1e-6 and 20 * math.log(v, 10) or -150 end
      local function pan_txt(p) if math.abs(p) < 0.005 then return 'C' end; return (p < 0 and 'L' or 'R') .. math.floor(math.abs(p) * 100 + 0.5) end
      local sx, sw = c.x + L.pad + indent, c.w - 2 * L.pad - indent
      local vol = (live and live.guid == col.guid and live.what == 'vol') and live.v or (col.vol or 1)
      local db = db_of(vol)
      slider(sx, hy + 2 * L.rh + 1, sw, (math.max(-60, math.min(12, db)) + 60) / 72, false, 'v', db <= -60 and '-inf' or ('%+.1f'):format(db), 'vol')
      local py = hy + 3 * L.rh + 1
      local function lv(what, v) return (live and live.guid == col.guid and live.what == what) and live.v or v end
      if col.panmode == 5 then
        local half = math.floor(sw / 2)
        slider(sx, py, half - L.pad, (lv('pan', col.pan or 0) + 1) / 2, true, 'p', pan_txt(lv('pan', col.pan or 0)), 'pan')
        slider(sx + half, py, sw - half, (lv('width', col.width or 1) + 1) / 2, true, 'w', math.floor(lv('width', col.width or 1) * 100 + 0.5) .. '', 'width')
      elseif col.panmode == 6 then
        local half = math.floor(sw / 2)
        slider(sx, py, half - L.pad, (lv('panl', col.panL or -1) + 1) / 2, true, 'L', pan_txt(lv('panl', col.panL or -1)), 'panl')
        slider(sx + half, py, sw - half, (lv('panr', col.panR or 1) + 1) / 2, true, 'R', pan_txt(lv('panr', col.panR or 1)), 'panr')
      else
        slider(sx, py, sw, (lv('pan', col.pan or 0) + 1) / 2, true, 'p', pan_txt(lv('pan', col.pan or 0)), 'pan')
      end
    end
    for li, ln in ipairs(c.lanes) do
      -- кнопки «-» «+» справа в строке лейна: число подколонок (просьба 1 окт)
      local bw2 = c.folded and 0 or (2 * L.btn_w + 2)
      if col.fixed and not c.folded then
        local lname = ln.lane.name ~= '' and ln.lane.name or ('L' .. (ln.lane.idx + 1))
        text(ln.x + L.pad, hy + 4 * L.rh + 2, fit(lname, ln.w - 2 * L.pad - bw2), U.GREY)
      end
      if not c.folded then
        local by = hy + 4 * L.rh + 1
        for k, b in ipairs({ { '-', -1 }, { '+', 1 } }) do
          local bx = ln.x + ln.w - bw2 + (k - 1) * (L.btn_w + 2)
          local hot = mx >= bx and mx < bx + L.btn_w and my >= by and my < by + L.rh - 1
          set(hot and D.CURROW or U.PANEL); gfx.rect(bx, by, L.btn_w, L.rh - 2, 1)
          set(U.DIM); gfx.rect(bx, by, L.btn_w, L.rh - 2, 0)
          text(bx + 2, by, b[1], hot and U.AMBER or U.GREY)
          if hot then hover.lanebtn = { col = col, lane = ln.lane, d = b[2], n = ln.nsub } end
          hint('lanebtn', bx, by, L.btn_w, L.rh, { col = col, lane = ln.lane, d = b[2], n = ln.nsub })
        end
      end
      if li > 1 then set(U.DIM); gfx.rect(ln.x - 1, hy + 4 * L.rh + 1, 1, L.rh, 1) end
    end
    for _, ev in ipairs(c.envs) do
      text(ev.x + L.pad, hy + 4 * L.rh + 2, fit(ev.e.name, ev.w - 2 * L.pad), env_colour(ev.e))
      hint('env', ev.x, hy + 4 * L.rh, ev.w, L.rh, ev.fi)
      set(U.DIM); gfx.rect(ev.x - 1, hy + 4 * L.rh + 1, 1, L.rh, 1)
    end
    -- третья строка: что делает каждая подколонка (просьба 1 окт). Подписи
    -- короче ширины поля на символ, чтобы соседние не слипались; полное
    -- описание — в статус-баре при наведении (hover.caption)
    if not c.folded then
      local cy3 = hy + 5 * L.rh + 2
      local function cap(x, w, txt, kind)
        text(x, cy3, fit(txt, w), U.GREY)
        if mx >= x and mx < x + w + L.pad and my >= cy3 and my < cy3 + L.rh then hover.caption = kind end
      end
      for _, ln in ipairs(c.lanes) do
        for si = 1, ln.nsub do
          local sx = ln.x + (si - 1) * L.sub_w
          if L.w_wave > 0 then cap(sx + L.x_wave, L.w_wave, L.wave == 'spec' and 'wav' or 'wv', 'wave') end
          cap(sx + L.x_note, L.w_note, 'nt', 'note')
          cap(sx + L.x_vol, L.w_vol, 'vl', 'vol')
          for k = 1, L.nfx do cap(sx + L.x_fx[k], L.w_fx, 'fx' .. k, 'fx') end
          cap(sx + L.x_del, L.w_del, 'dl', 'delay')
        end
      end
      for _, ev in ipairs(c.envs) do cap(ev.x + L.pad, ev.w - 2 * L.pad, 'env', 'env') end
    end
    set(U.LINE); gfx.rect(c.x, hy, 1, L.header_h, 1)
    if my >= hy and my < hy + L.header_h and mx >= c.x and mx < c.x + c.w then hover.header_col = col end
  end
  set(D.SEP); gfx.rect(tx0, hy + L.header_h - 2, W - tx0, 2, 1)
  -- длина региона курсора в шагах — квадрат над номерами строк: число на
  -- 2-й строке шапки, «<» «>» на 3-й (клик / колесо = ±1 шаг, ripple как :len)
  if info.cur_region then
    local rg = info.cur_region
    local s = tostring(math.max(0, math.floor((rg.r1 - rg.r0) + 0.5)))
    local bx, bw = tx0 + 1, L.label_w - 2
    local y2, y3 = hy + 4 * L.rh + 2, hy + 5 * L.rh + 2
    set(U.LINE); gfx.rect(bx, y2 - 1, bw, 2 * L.rh + 1, 0)
    text(bx + math.max(1, math.floor((bw - ms(s)) / 2)), y2, fit(s, bw - 2), U.TEXT)
    local hl = mx >= bx and mx < bx + bw / 2 and my >= y3 and my < y3 + L.rh
    local hr = mx >= bx + bw / 2 and mx < bx + bw and my >= y3 and my < y3 + L.rh
    text(bx + 1, y3, '<', hl and U.AMBER or U.GREY)
    text(bx + bw - ms('>') - 1, y3, '>', hr and U.AMBER or U.GREY)
    if hl then hover.rglen = -1 elseif hr then hover.rglen = 1
    elseif mx >= bx and mx < bx + bw and my >= y2 and my < y3 then hover.rglen = 0 end
    hint('rglen', bx, y3, math.floor(bw / 2), L.rh, -1); hint('rglen', bx + math.floor(bw / 2), y3, math.floor(bw / 2), L.rh, 1)
  end

  -- тело
  local ph = info.ph_row and math.floor(info.ph_row) or nil
  local cur = info.cur_row and math.floor(info.cur_row) or nil
  local vc, vis = info.vcur, info.vis
  local env_vals = {}
  for _, c in ipairs(L.cols) do
    for _, ev in ipairs(c.envs) do env_vals[ev] = info.env_values and info.env_values(ev.e) or {} end
  end
  for i, r in ipairs(rows) do
    local y = L.body_y + (i - 1) * L.rh
    local ty = y + 1
    local is_cur_row = vc and vc.row == r.row
    if r.row == ph then set(D.PLAY); gfx.rect(tx0, y, W - tx0, L.rh, 1) end
    if is_cur_row then set(state.fixed and U.mix(D.CURROW, U.TEXT, 0.12) or D.CURROW); gfx.rect(tx0, y, W - tx0, L.rh, 1) end
    if r.bar then set(D.BAR); gfx.rect(tx0, y, W - tx0, 1, 1)
    elseif r.beat then set(D.BEAT); gfx.rect(tx0, y, W - tx0, 1, 1) end
    -- кромки: строка курсора — яркая янтарная сверху, edit-курсор — зелёная
    if is_cur_row then set(D.CURTOP); gfx.rect(tx0, y, W - tx0, 1, 1) end
    if r.row == cur then set(D.EDITTOP); gfx.rect(tx0, y, W - tx0, 1, 1); gfx.rect(tx0, y, 3, L.rh, 1) end
    text(tx0 + L.pad, ty, r.label, (is_cur_row or r.beat) and U.TEXT or U.GREY)
    local in_body = my >= y and my < y + L.rh and my >= L.body_y and my < L.body_y + L.nrows * L.rh and mx < W
    if in_body then hover.row = r end
    for _, c in ipairs(L.cols) do
      -- подсказка-прыжок: одна на такт в колонке трека (не на каждое событие)
      if r.bar and c.lanes[1] then hint('bar', c.x + 1, y, c.w - 2, L.rh, { fi = c.lanes[1].f0, row = r.row }) end
      for _, ln in ipairs(c.lanes) do
        for si = 1, ln.nsub do
          local fi = ln.f0 + si - 1
          local f = L.flat[fi]
          local x = f.x
          if x then
            if vis and fi >= vis.f0 and fi <= vis.f1 and r.row >= vis.r0 and r.row <= vis.r1 then
              set(D.VIS); gfx.rect(x, y, f.w, L.rh, 1)
            end
            local inv = (vc and vc.fi == fi and vc.row == r.row) and (c.folded and 1 or (vc.field or 1)) or nil
            if inv then
              D.inv_bg = info.focus == 'tracker' and U.TEXT or U.LINE
              set(D.inv_bg)
              if c.folded then gfx.rect(x, y, f.w, L.rh, 1)
              else local fx, fw = D.field_rect(L, inv); gfx.rect(x + fx - 1, y, fw + 2, L.rh, 1) end
            end
            local cell
            if r.row < 0 then
            elseif c.folded then draw_fold_cell(L, c.col, r.row, x, y, ty, inv ~= nil)
            else cell = f.sub[r.row]; draw_cell(L, cell, x, y, ty, inv) end
            if in_body and mx >= x and mx < x + f.w then
              hover.fi = fi; hover.cell = cell; hover.col = c.col
              for fld = 1, 3 + L.nfx do
                local fx, fw = D.field_rect(L, fld)
                if mx >= x + fx and mx < x + fx + fw + L.pad then hover.field = fld; break end
              end
            end
          end
        end
      end
      for _, ev in ipairs(c.envs) do
        if vc and vc.fi == ev.fi and vc.row == r.row then
          set(info.focus == 'tracker' and U.AMBER or U.LINE); gfx.rect(ev.x, y, ev.w, L.rh, 0)
        end
        draw_env_cell(L, env_vals[ev][i], env_vals[ev][i - 1], ev.x, y, ty, ev.e)
        if in_body and mx >= ev.x and mx < ev.x + ev.w then
          hover.col = c.col; hover.env = ev.e; hover.envv = env_vals[ev][i]; hover.fi = ev.fi
          hover.envx = math.max(0, math.min(1, (mx - ev.x - L.pad) / (L.env_bar_w - 1)))
        end
      end
    end
  end

  -- рамки items: тонкая кайма по дробным строкам начала/конца — так item
  -- отличим от MIDI-нот внутри него. Аудио — в своей подколонке, MIDI — на
  -- всю lane. Цвет item (или трека), приглушённый; выбранный в REAPER — ярче.
  do
    local top_row = rows[1] and rows[1].row or 0
    local by0, by1 = L.body_y, L.body_y + L.nrows * L.rh
    local function yr(rf) return L.body_y + math.floor((rf - top_row) * L.rh + 0.5) end
    for _, c in ipairs(L.cols) do
      if not c.folded then
        for _, ln in ipairs(c.lanes) do
          for _, it in ipairs(ln.lane.items or {}) do
            local x0, w0 = ln.x, ln.w
            if it.si then local f = L.flat[ln.f0 + it.si - 1]; x0, w0 = f and f.x, f and f.w end
            local y0, y1 = yr(it.r0), yr(it.r1)
            if x0 and y1 > by0 and y0 < by1 then
              -- мышь: край рамки (±3 px) — trim начала/конца, внутри — сдвиг
              if mx >= x0 and mx < x0 + w0 and my >= y0 - 3 and my <= y1 + 3 then
                local edge = (math.abs(my - y1) <= 3) and 'end' or ((math.abs(my - y0) <= 3) and 'start' or 'move')
                if not hover.itemedge or edge ~= 'move' then
                  hover.itemedge = { item = it.item, edge = edge, col = c.col, lane = ln.lane, r0 = it.r0, r1 = it.r1 }
                end
              end
              local rgb = it.rgb or c.col.rgb or U.GREY
              local col = it.sel and U.mix(rgb, U.TEXT, 0.3) or U.mix(rgb, U.BG, it.muted and 0.7 or 0.45)
              local cy0, cy1 = math.max(by0, y0), math.min(by1, y1)
              -- почти прозрачная заливка с отливом цвета item (один rect — дёшево)
              set(rgb); gfx.a = it.sel and 0.16 or 0.10
              gfx.rect(x0, cy0, w0, cy1 - cy0, 1)
              gfx.a = 1
              set(col)
              gfx.rect(x0, cy0, w0, cy1 - cy0, 0)                           -- кайма 2 px
              gfx.rect(x0 + 1, cy0 + 1, math.max(0, w0 - 2), math.max(0, cy1 - cy0 - 2), 0)
              if y0 < by0 then set(U.BG); gfx.rect(x0, by0, w0, 2, 1) end   -- срез сверху: без верхней кромки
              if y1 > by1 then set(U.BG); gfx.rect(x0, by1 - 2, w0, 2, 1) end
            end
          end
        end
        -- automation items в колонках огибающих: полупрозрачная заливка
        -- цветом темы (env_item_vol/pan/mute/pitch) + кайма, как в аранжировке
        for _, ev in ipairs(c.envs) do
          for _, ai in ipairs(ev.e.ais or {}) do
            local y0, y1 = yr(ai.r0), yr(ai.r1)
            if y1 > by0 and y0 < by1 then
              local cy0, cy1 = math.max(by0, y0), math.min(by1, y1)
              local col = ai_colour(ev.e.ai_key or 'env_item_pitch')
              set(col); gfx.a = ai.sel and 0.45 or 0.28
              gfx.rect(ev.x, cy0, ev.w, cy1 - cy0, 1)
              gfx.a = 1
              set(U.mix(col, U.TEXT, ai.sel and 0.4 or 0.1)); gfx.rect(ev.x, cy0, ev.w, cy1 - cy0, 0)
            end
          end
        end
      end
    end
  end

  -- пик-метры ПОВЕРХ колонок, как в ProTracker: столбик от самого низа
  -- колонки вверх, высота = уровень × высота тела, полупрозрачный — текст
  -- под ним читается
  if state.meters and info.peaks then
    do
      local by = L.body_y + L.body_h
      do
        local maxh = math.floor(L.body_h * 0.5)          -- до середины тела
        for _, c in ipairs(L.cols) do
          local pl, pr = info.peaks(c.col)
          local v = math.min(1, math.max(pl, pr))
          local h = math.floor(v * maxh + 0.5)
          if h > 0 then
            local x0, w0 = c.x + 2, math.max(2, math.floor(c.w * 0.3))
            local y0 = math.max(L.body_y, by - h)
            local g, a, r = U.GREEN, U.AMBER, U.RED
            -- три сегмента снизу вверх: зелёный / янтарный / красный
            local seg = { { 0, 0.6, g }, { 0.6, 0.85, a }, { 0.85, 1, r } }
            for _, sg in ipairs(seg) do
              local s0, s1 = math.floor(sg[1] * maxh), math.floor(math.min(v, sg[2]) * maxh)
              if s1 > s0 then
                gfx.set(sg[3][1], sg[3][2], sg[3][3], 0.45)
                gfx.rect(x0, math.max(L.body_y, by - s1), w0, s1 - s0, 1)
              end
            end
          end
        end
      end
    end
  end

  -- разделители
  for _, c in ipairs(L.cols) do
    set(U.LINE); gfx.rect(c.x, L.body_y, 1, L.body_h, 1)
    for li, ln in ipairs(c.lanes) do
      if li > 1 then set(U.DIM); gfx.rect(ln.x - 1, L.body_y, 1, L.body_h, 1) end
      for si = 2, ln.nsub do set(D.EMPTY); gfx.rect(ln.x + (si - 1) * L.sub_w, L.body_y, 1, L.body_h, 1) end
    end
    for _, ev in ipairs(c.envs) do set(U.DIM); gfx.rect(ev.x - 1, L.body_y, 1, L.body_h, 1) end
  end
  set(D.SEP); gfx.rect(tx0 + L.label_w - 1, L.body_y, 2, L.body_h, 1)
  if tx0 > 0 then set(D.SEP); gfx.rect(tx0 - 1, hy, 2, L.body_y + L.body_h - hy, 1) end
  if L.total_w < W then set(U.LINE); gfx.rect(L.total_w, hy, 1, L.body_y + L.body_h - hy, 1) end

  if MX and L.matrix_w > 0 then
    hover.matrix = MX.draw(L, snap, info.regions or {}, { play_row = ph, cur_ci = info.cur_ci, pat_num = info.pat_num,
      env_shown = function(col) local v = state.trackenvs and state.trackenvs[col.guid]; if v == nil then v = state.envs end; return v end })
  end

  if L.side_w > 0 and info.browser_draw then
    -- сайдбар во всю высоту окна: от верха до статус-бара (инструменты сверху, браузер снизу)
    local sy0 = 0
    local total = gfx.h - L.status_h - sy0
    set(U.PANEL); gfx.rect(W, sy0, L.side_w, total, 1)
    local ih = math.max(4 * L.rh, math.min(total - 6 * L.rh, state.inst_px or math.floor(total * 0.40)))
    L.inst_side_h = ih
    L.side_y0 = sy0
    D.draw_instruments(L, info, W, sy0, L.side_w, ih, hover)
    hover.browser = info.browser_draw(L, W, sy0 + ih + 2, L.side_w, total - ih - 2)
  end

  -- нижняя DSP-панель: FX трека курсора блоками, параметры мини-слайдерами
  if L.dsp_h > 0 then
    local dy = L.body_y + L.body_h
    set(U.PANEL); gfx.rect(0, dy, L.win_w, L.dsp_h, 1)
    set(D.SEP); gfx.rect(0, dy, L.win_w, 2, 1)
    local col = info.pool_col
    local fxs = col and col.fx or {}
    text(L.pad, dy + 3, fit('dsp ' .. (col and col.name or '') .. (#fxs == 0 and '  (no fx; a - add)' or ''), gfx.w - 2 * L.pad), U.GREY)
    local bx = L.pad
    local bw = L.cw * 22
    local sel = info.dsp_sel or {}
    for k, f in ipairs(fxs) do
      local ncol = f.cols or 1
      local bw1 = L.cw * 22
      local bw = bw1 * ncol
      if bx + bw > L.win_w then break end
      local by = dy + 3 + L.rh
      local bh = L.dsp_h - L.rh - 6
      local is_sel = sel.fx == k
      set(is_sel and U.tint(U.AMBER, 0.18) or U.BG); gfx.rect(bx, by, bw, bh, 1)
      set(f.enabled and (is_sel and U.AMBER or U.LINE) or U.DIM); gfx.rect(bx, by, bw, bh, 0)
      text(bx + L.pad, by + 1, fit((f.enabled and '' or '(off) ') .. (f.container and ('[' .. f.name .. '] ' .. #f.kids .. ' fx') or f.name), bw - 2 * L.pad), f.enabled and (f.container and U.AMBER or U.TEXT) or U.GREY)
      if mx >= bx and mx < bx + bw and my >= by and my < by + L.rh then hover.dsp = { fx = k, f = f } end
      hint('dsp', bx, by, bw, L.rh, { fx = k })
      local vals = info.fx_values and info.fx_values(f) or {}
      local pw = bw1 - 2 * L.pad
      local nfit = math.floor((bh - L.rh - 2) / L.rh)
      local pcol0 = 0
      if f.container and f.kids then
        -- контейнер: левая колонка — дети и маршрутизация (| за предыдущим,
        -- = параллельно, + параллельно с суммой), параметры — правее
        pcol0 = 1
        local ky = by + L.rh + 1
        for ki, kid in ipairs(f.kids) do
          if ki > nfit then break end
          local glyph = kid.parallel == 1 and '=' or (kid.parallel == 2 and '+' or '|')
          local kx = bx + L.pad
          set(kid.parallel > 0 and U.CYAN or U.LINE); gfx.rect(kx + L.cw // 2, ky, 2, L.rh, 1)
          if kid.parallel > 0 then gfx.rect(kx + L.cw // 2 + 4, ky, 2, L.rh, 1) end
          text(kx + L.cw + L.pad, ky, fit((kid.enabled and '' or '(off) ') .. glyph .. ' ' .. kid.name .. (kid.container and ' [..]' or ''), pw - L.cw - 2 * L.pad), kid.enabled and U.TEXT or U.GREY)
          ky = ky + L.rh
        end
      end
      for pi, p in ipairs(f.params) do
        if pi > nfit * (ncol - pcol0) then break end
        local colk = pcol0 + math.floor((pi - 1) / nfit)
        local bxc = bx + colk * bw1
        local py = by + L.rh + 1 + ((pi - 1) % nfit) * L.rh
        local v = vals[pi] or { n = 0, s = '' }
        local psel = is_sel and sel.param == pi
        -- строка параметра: имя | виджет | значение — без подложки, белым;
        -- выбранный параметр — янтарное имя и виджет
        local acc = psel and U.AMBER or U.TEXT
        local nw = math.floor(pw * 0.40)
        local wx0 = bxc + L.pad + nw
        local ww = math.floor(pw * 0.34)
        local vx = wx0 + ww + L.pad
        local vw = bxc + L.pad + pw - vx
        local cy = py + math.floor(L.rh / 2)
        if p.kind == 'toggle' then
          local on = v.n >= 0.5
          local sz = L.rh - 6
          set(on and acc or U.BG); gfx.rect(wx0, py + 3, sz, sz, 1)
          set(on and acc or U.LINE); gfx.rect(wx0, py + 3, sz, sz, 0)
        elseif p.kind == 'steps' and p.nsteps then
          local segw = math.max(2, math.floor((ww - (p.nsteps - 1)) / p.nsteps))
          local cur = math.floor(v.n * (p.nsteps - 1) + 0.5)
          for kk = 0, p.nsteps - 1 do
            set(kk == cur and acc or U.DIM); gfx.rect(wx0 + kk * (segw + 1), py + 4, segw, L.rh - 8, kk == cur and 1 or 0)
          end
        else
          set(U.DIM); gfx.rect(wx0, cy - 1, ww, 2, 1)                       -- дорожка
          set(acc); gfx.rect(wx0, py + 4, math.max(1, math.floor(v.n * ww + 0.5)), L.rh - 8, 1)
        end
        text(bxc + L.pad, py, fit(p.name, nw - L.pad), psel and U.AMBER or U.TEXT)
        if vw > 4 then text(vx, py, fit(v.s, vw), U.GREY) end
        if mx >= bxc + L.pad and mx < bxc + L.pad + pw and my >= py and my < py + L.rh then
          hover.dsp = { fx = k, f = f, param = pi, frac = (mx - bx - L.pad) / pw,
                        sv = math.max(0, math.min(1, (mx - wx0) / math.max(1, ww))), onwidget = mx >= wx0 - 2 and mx < wx0 + ww + 2 }
        end
        hint('dspparam', bxc + L.pad, py, pw, L.rh, { fx = k, param = pi })
      end
      bx = bx + bw + L.pad
    end
    L.dsp_rect = { 0, dy, L.win_w, L.dsp_h }
  end

  -- рамка фокуса клавиатуры: модуль, которому идут клавиши
  do
    local f = info.focus
    local r
    if f == 'tracker' then r = { tx0, hy, W - tx0, L.body_y + L.body_h - hy }
    elseif f == 'matrix' and L.matrix_w > 0 then r = { 0, hy, L.matrix_w, L.body_y + L.body_h - hy }
    elseif f == 'browser' and L.side_w > 0 then r = { W, (L.side_y0 or 0) + (L.inst_side_h or 0) + 2, L.side_w, gfx.h - L.status_h - (L.side_y0 or 0) - (L.inst_side_h or 0) - 2 }
    elseif f == 'top' and L.top_rect then r = L.top_rect
    elseif f == 'inst' and L.inst_rect then r = L.inst_rect
    elseif f == 'dsp' and L.dsp_rect then r = L.dsp_rect end
    if r then
      -- INSERT — красная и на пиксель толще: видно, что клавиши пишут в проект
      local ins = info.vmode == 'insert' and info.focus == 'tracker'
      set(ins and D.FOCUS_INS or D.FOCUS)
      -- ободок ровно по границе модуля, без зазора: 1 px; INSERT — красный, 2 px
      gfx.rect(r[1], r[2], r[3], r[4], 0)
      if ins then gfx.rect(r[1] + 1, r[2] + 1, r[3] - 2, r[4] - 2, 0) end
    end
  end

  -- статус — в самом низу окна, под DSP-панелью (раньше делил y с ней и
  -- перекрывал её шапку)
  local sy = gfx.h - L.status_h
  set(U.PANEL); gfx.rect(0, sy, gfx.w, L.status_h, 1)
  set(D.SEP); gfx.rect(0, sy, gfx.w, 2, 1)
  if L.side_w > 0 then set(D.SEP); gfx.rect(L.win_w - 2, 0, 2, sy, 1) end   -- линия сайдбара до статус-бара
  -- слева режим/сообщение (не шире трети окна), дальше — описание того, на
  -- что наведена мышь, во всю оставшуюся ширину
  local left = fit(info.status_left or '', gfx.w / 3)
  text(L.pad, sy + 2, left, U.AMBER)
  local hx = L.pad + (left ~= '' and (ms(left) + 3 * L.pad) or 0)
  local desc = info.status_right or ''
  if desc ~= '' then
    if left ~= '' then set(D.SEP); gfx.rect(hx - 2 * L.pad + L.pad // 2, sy + 2, 2, L.status_h - 2, 1) end
    text(hx, sy + 2, fit(desc, gfx.w - hx - L.pad), U.TEXT)
  end
  return hover
end

-- ── всплывашка снизу (which-key / подсказка команд / поиск) ───────────────
-- Панель над строкой статуса: колонками «клавиша  действие». Ширина — от
-- содержимого, высота — от числа строк (до половины окна).
function D.popup(L, p)
  if not p or not p.lines then return end
  local W = gfx.w
  local sy = L.body_y + L.body_h
  local n = #p.lines
  local maxrows = math.max(1, math.floor((L.body_h / 2) / L.rh))
  local ncol = math.max(1, math.ceil(n / maxrows))
  local nrow = math.min(n, maxrows)
  local kw, tw = 0, 0
  for _, ln in ipairs(p.lines) do
    kw = math.max(kw, ms(ln.key or ''))
    tw = math.max(tw, ms(ln.text or ''))
  end
  local colw = L.pad + kw + 2 * L.pad + tw + 2 * L.pad
  local w = math.min(W - 2 * L.pad, ncol * colw + L.pad)
  local h = (nrow + 1) * L.rh + 2 * L.pad
  local x, y = L.pad, sy - h - 2
  set(U.PANEL); gfx.rect(x, y, w, h, 1)
  set(U.LINE); gfx.rect(x, y, w, h, 0)
  text(x + L.pad, y + L.pad, fit(p.title or '', w - 2 * L.pad), p.kind == 'hydra' and U.AMBER or U.CYAN)
  for i, ln in ipairs(p.lines) do
    local ci = math.floor((i - 1) / nrow)
    local ri = (i - 1) % nrow
    local lx = x + L.pad + ci * colw
    local ly = y + L.pad + (ri + 1) * L.rh
    if lx + colw > x + w + L.pad then break end
    if p.hl == i then set(D.CURROW); gfx.rect(lx, ly, colw - L.pad, L.rh, 1) end
    text(lx + L.pad, ly + 1, ln.key or '', p.kind == 'hydra' and U.AMBER or U.TEXT)
    text(lx + L.pad + kw + 2 * L.pad, ly + 1, fit(ln.text or '', tw), U.GREY)
  end
end

return D
