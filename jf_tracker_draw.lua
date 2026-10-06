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
-- масштаб битмап-шрифта: x1..x3 (3 окт: x4 — только для будущего PT-mode)
D.SCALE_MAX = 3
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
  D.PEAKB, D.PEAKMB = U.mix(D.PEAK, U.BG, 0.62), U.mix(D.PEAK, U.BG, 0.8)   -- волна фоном (3 окт)
  D.BAR   = U.mix(U.BG, U.TEXT, 0.62)
  D.BEAT  = U.DIM
  D.PLAY  = U.tint(U.AMBER, 0.22)
  D.CUR   = U.AMBER
  D.CURROW = U.mix(U.BG, U.TEXT, 0.16)
  D.CURTOP = U.AMBER                            -- яркая верхняя кромка строки курсора
  D.EDITTOP = U.readable({ 0.30, 0.95, 0.40 }, U.BG, 4.5)  -- зелёная кромка edit-курсора
  D.VIS   = U.tint(U.CYAN, 0.25)
  D.EMPTY = U.mix(U.BG, U.TEXT, 0.34)
  D.EMPTY_UNDER = U.mix(U.BG, U.TEXT, 0.20)     -- точки сетки под item: слегка видны (2 окт)
  D.CONT  = U.GREY
  D.ENVBAR = U.tint(U.CYAN, 0.45)
  D.FX    = U.mix(U.TEXT, U.AMBER, 0.5)
  D.SEP   = U.mix(U.BG, U.TEXT, 0.38)           -- границы модулей: тусклые (3 окт; фокус — ярче)
  D.SEPW  = 2                                   -- толщина границ модулей (3 окт: жирнее), линии внутри модулей — 1 px
  D.FOCUS = U.mix(U.TEXT, { 1, 1, 1 }, 0.55)    -- светлый ободок модуля с фокусом (просьба 1 окт: без розового)
  D.FOCUS_INS = { 1.0, 0.15, 0.1 }              -- та же рамка в INSERT (красная, толще)
  D.ENVLINE = U.readable(U.CYAN, U.BG, 4.5)
  -- фон шапки трека (3 окт): как TCP REAPER — col_tr1_bg темы, выделенный —
  -- col_seltrack; цвет трека подмешивается так же (~30 %, сверено по TCP)
  D.HDR = U.HDR or U.theme('col_tr1_bg', U.mix(U.PANEL, U.TEXT, 0.12))
  D.HDRSEL = U.HDRSEL or U.theme('col_seltrack', U.mix(D.HDR, U.TEXT, 0.10))
  -- темы (3 окт, jf_tracker_themes.lua): mono — всё серым, кроме ячейки курсора
  D.mono = U.MONO and true or false
  -- цвета кнопок как в REAPER (3 окт): запись — фиолетовая, FX трека — зелёная;
  -- во всех темах, в mono тоже (исключения серого фильтра)
  D.ARM, D.FXG = { 0.66, 0.36, 0.90 }, { 0.40, 0.66, 0.30 }
  D.ARM_T, D.FXG_T = U.mix(U.PANEL, D.ARM, 0.55), U.mix(U.PANEL, D.FXG, 0.85)
  D.FXTXT = { 0.94, 1.0, 0.90 }                -- светлый текст на зелёном, как FX в REAPER
  D.KEEP = { [D.ARM] = true, [D.ARM_T] = true, [D.FXG] = true, [D.FXG_T] = true, [D.FXTXT] = true }
  D.CURCELL = U.MONO_CURSOR or U.TEXT
  U.set = function(c, a) D.set(c, a) end           -- матрица / браузер / слайсер — через тот же фильтр
end

-- шрифт: 0 — битмап REAPER (масштаб ×N пиксель-в-пиксель через кеш строк и
-- gfx.blit — тот самый PT2-вид), N>0 — TTF моноширинный размера N.
-- D.SPACE — зазор над буквами в строке (`:space`), входит в высоту строки.
D.SCALE, D.SPACE = 1, 2
local tcache, next_img = {}, 100
-- номера картинок gfx — только 0..1023 (1200+ молча не создаются: так 2 окт пропали
-- вертикальные имена матрицы и подписи линейки). 100..799 текст, 800..959
-- вертикальный текст, 960..1019 спектрограммы анализатора, 1022 логотип about, 1023 черновик поворота
-- 90..97 спектрограммы вкладки item (jf_tracker_sgram), 99 главный модуль; номера gfx — только 0..1023
local IMG_FIRST, IMG_LAST = 100, 799

-- пиксельные TTF (5 окт, опция font): кириллица, греческий, блоки, рамки —
-- без гибрида; px — родной размер (кегль = px × масштаб — чётко)
D.TTF_FACES = {
  bigblue = { face = 'BigBlueTermPlus Nerd Font Mono', px = 12 },    -- DOS 8×12 (Departure и Gohu не прижились, 5 окт)
  iosevka = { face = 'IosevkaTerm Nerd Font Mono', px = 14 },        -- вектор, узкий, 7429 символов
}
function D.set_font(state)
  local tf = D.TTF_FACES[state.ttf or 'off']
  D.ttf = tf and true or false
  if tf then
    local fs = tonumber(state.fontscale) or 2
    if fs ~= 1.5 then fs = math.max(1, math.min(3, math.floor(fs))) end
    D.ttf_face, D.ttf_size, D.ttf_px = tf.face, math.floor(tf.px * fs + 0.5), tf.px
    gfx.setfont(1, D.ttf_face, D.ttf_size)
    D.font_id = 1
    D.SCALE = 1
  else
    D.font_id = 0
    -- только целые x1..x4 (дробный пробовали 1 окт — кривой; Ctrl +/- шаг 1)
    -- x1.5 (5 окт) — единственный дробный масштаб; остальные целые; x4 — только PT-mode
    local fs = tonumber(state.fontscale) or 2
    if fs ~= 1.5 then fs = math.floor(fs) end
    D.SCALE = math.max(1, math.min(state.ptmode and 4 or D.SCALE_MAX, fs))
  end
  D.SPACE = math.max(0, math.min(12, math.floor(tonumber(state.fontspace) or 2)))
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
-- не-ASCII (кириллица, Δ, ø) в битмап-режиме — TTF-шрифт на выбор (4 окт,
-- опция letters font): k — кегль к высоте строки битмапа (заглавные вровень,
-- по пробе), bold — жирный рядом с толстым битмапом, odd — нечётный кегль
-- (пиксельные чётче). По умолчанию BigBlueTermPlus — DOS-шрифт, ближе всех к битмапу
D.GLYPH_FACES = {
  { key = 'bigblue',   face = 'BigBlueTermPlus Nerd Font Mono', k = 1.5 },   -- 4 окт: крупнее, единственный
  { key = 'departure', face = 'DepartureMono Nerd Font Mono',   k = 1.4 },
  { key = 'terminess', face = 'Terminess Nerd Font Mono',       k = 1.5, bold = true },
  { key = '3270',      face = '3270 Nerd Font Mono',            k = 1.5, bold = true },
  { key = 'jetbrains', face = 'JetBrainsMono Nerd Font Mono',   k = 1.35, bold = true },
  { key = 'monocraft', face = 'Monocraft',                      k = 1.875, odd = true },
  { key = 'menlo',     face = 'Menlo',                          k = 1.35, bold = true },
}
D.glyph_key = 'bigblue'
local function glyph_spec()
  for _, g in ipairs(D.GLYPH_FACES) do if g.key == D.glyph_key then return g end end
  return D.GLYPH_FACES[1]
end
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
  local g = glyph_spec()
  local sz = math.max(8, math.floor((D.bitmap_th or 8) * g.k + 0.5))
  if g.odd and sz % 2 == 0 then sz = sz - 1 end
  local sig = g.face .. '|' .. sz
  if glyph_sig ~= sig then
    if g.bold then gfx.setfont(2, g.face, sz, string.byte('b')) else gfx.setfont(2, g.face, sz) end
    glyph_sig = sig
  else gfx.setfont(2) end
end
D.reset_glyph = function() glyph_sig = nil end
-- ширина куска битмапом: measurestr не считает хвостовые пробелы (' ' = 0) —
-- между русскими словами пропадали пробелы (4 окт); меряем с меткой
local function ascii_w(t) return gfx.measurestr(t .. '.') - gfx.measurestr('.') end
local mcache, mcount = {}, 0
local function measure_raw(str)
  if D.hybrid and str:find('[\128-\255]') then
    local w = mcache[str]
    if w then return w end
    w = 0
    for _, sg in ipairs(segments(str)) do
      if sg.glyph then glyph_font(); w = w + gfx.measurestr(sg.t); gfx.setfont(D.font_id)
      else w = w + ascii_w(sg.t) end
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
  -- строка с глифами: картинка на 2 px ниже — хвосты р у щ не срезаются
  local hi = (D.hybrid and str:find('[\128-\255]')) and (h + 2) or h
  gfx.setimgdim(id, w, hi)
  local old = gfx.dest
  gfx.dest = id
  if bg then gfx.set(bg[1], bg[2], bg[3], 1) else gfx.set(0, 0, 0, 1) end
  gfx.rect(0, 0, w, hi, 1)
  gfx.set(col[1], col[2], col[3], 1)
  gfx.setfont(D.font_id)
  if D.hybrid and str:find('[\128-\255]') then
    local x = 0
    for _, sg in ipairs(segments(str)) do
      if sg.glyph then glyph_font() else gfx.setfont(D.font_id) end
      local sw = sg.glyph and gfx.measurestr(sg.t) or ascii_w(sg.t)
      local gy = sg.glyph and math.floor((h - gfx.texth) / 2) or 0
      gfx.x, gfx.y = x, gy; gfx.drawstr(sg.t)
      x = x + sw
    end
    gfx.setfont(D.font_id)
  else
    gfx.x, gfx.y = 0, 0; gfx.drawstr(str)
  end
  gfx.dest = old
  e = { id = id, w = w, h = hi }
  tcache[key] = e
  return e
end

-- ── раскладка ─────────────────────────────────────────────────────────────
function D.layout(snap, state, nregions)
  gfx.setfont(D.font_id)
  local L = {}
  L.th = TH()
  L.rh = L.th + 2 + D.SPACE + (D.SCALE % 1 ~= 0 and 1 or 0)   -- x1.5 (5 окт): +1 px снизу текста в кнопках
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
  L.wave = (state.wavemode == 'column') and 'spec' or 'off'
  D.wave_none = state.wavemode == 'off'                -- без волны совсем (3 окт)
  D.show_smk = state.stretchmarks ~= false
  D.wave_back = state.wavemode == 'back'               -- волна фоном во всю ширину item, под текстом (3 окт)
  -- text only (4 окт): в ячейках только текст — без волны, заливки и рамки item
  if state.textonly then L.wave = 'off'; D.wave_none = true; D.wave_back = false end
  L.w_wave = L.wave == 'off' and 0 or L.cw * 3
  L.x_wave = L.pad
  L.x_note = L.pad + (L.w_wave > 0 and (L.w_wave + L.pad) or 0)
  -- номер инструмента на строке ноты, как в Renoise (3 окт): поле только для
  -- показа, поля курсора Vim прежние (нота, vol, delay, fx)
  L.w_inst = ms('00')
  L.x_inst = L.x_note + L.w_note + L.pad
  L.x_vol = L.x_inst + L.w_inst + L.pad
  -- порядок: волна | нота | инстр. | vol | fx1..n | delay (просьба 1 окт)
  L.x_fx = {}
  local x = L.x_vol + L.w_vol + L.pad
  for k = 1, L.nfx do L.x_fx[k] = x; x = x + L.w_fx + L.pad end
  L.x_del = x
  x = L.x_del + L.w_del + L.pad
  L.sub_w = x
  -- узкая подколонка (2 окт): ноты аккорда MIDI — только нота и velocity,
  -- без волны, fx и delay; отдельный лейн — только фиксированная дорожка REAPER
  L.sub_w_narrow = L.pad + L.w_note + L.pad + L.w_vol + L.pad
  L.GN = setmetatable({ narrow = true, w_wave = 0, nfx = 0, x_wave = L.pad, x_note = L.pad, x_inst = false,
    x_vol = L.pad + L.w_note + L.pad, x_fx = {}, x_del = L.pad + L.w_note + L.pad, sub_w = L.sub_w_narrow }, { __index = L })
  -- свёрнутый трек (fold, 2 окт): только волна и нота; ноты аккорда — только нота;
  -- огибающие — узкая схема: линия в символ шириной + hex значения точек
  L.sub_w_compact = L.x_note + L.w_note + L.pad
  L.GC = setmetatable({ notes_only = true, nfx = 0, x_inst = false, x_fx = {}, x_vol = L.x_note, x_del = L.x_note, sub_w = L.sub_w_compact }, { __index = L })
  L.sub_w_compact_n = L.pad + L.w_note + L.pad
  L.GCN = setmetatable({ notes_only = true, narrow = true, w_wave = 0, nfx = 0, x_wave = L.pad, x_note = L.pad, x_inst = false, x_fx = {},
    x_vol = L.pad, x_del = L.pad, sub_w = L.sub_w_compact_n }, { __index = L })
  L.fold_w = ms('o') + 2 * L.pad
  L.env_hex_w = ms('FF')
  L.env_bar_w = ms('WWWW')
  -- поле формы сегмента (2 окт): lin sqr slo fas fae bez — справа от значения
  -- форма сегмента (2 окт, правка): не отдельной колонкой, а под значением точки
  -- и только если не lin — правая часть колонки шириной в «bez»
  L.env_shape_w = ms('bez')
  -- дорожка кривой — за ручкой automation item (6 окт: минимум кривой падал в ручку)
  L.env_bx = L.th + 6
  L.env_w = L.env_bx + L.env_bar_w + L.pad + math.max(L.env_hex_w, L.env_shape_w) + L.pad
  L.env_cw = L.env_bx + L.cw + L.pad + L.env_hex_w + L.pad
  L.GE = setmetatable({ env_bar_w = L.cw, env_compact = true }, { __index = L })
  -- ширина браузера: перетащенная мышью (state.side_px) или по кнопке <>
  L.side_w = state.side and (state.side_px or (L.cw * (state.sidenarrow and 20 or 36) + 2 * L.pad)) or 0
  -- правая панель свёрнута — узкая полоса с кнопкой < (2 окт)
  L.rstrip_w = state.side and 0 or (ms('<') + 2 * L.pad + 6)
  -- модуль слайсов (4 окт): колонка в верхней панели справа (у lib), по её
  -- высоте — не на всё окно; пока у выбранного инструмента есть слайсы
  L.slices_split = state.slices_on and state.slicespos == 'split' and state.side   -- половина модуля инструментов (опция slices)
  L.slices_w = (state.slices_on and state.top and not L.slices_split) and math.max(L.cw * 16, math.min(L.cw * 20, math.floor(gfx.w * 0.12))) or 0
  L.win_w = gfx.w - L.side_w - L.rstrip_w
  L.side_x = L.win_w                               -- левый край сайдбара / полосы
  L.matrix_w = MX and MX.width(L, nregions or 0, #snap.cols) or 0
  -- матрица: свёрнута — узкая полоса с кнопкой >; ширина мышью (ручка = на линии раздела)
  L.mx_strip_w = ms('>') + 2 * L.pad + 6
  if state.mx_hidden then L.matrix_w = L.mx_strip_w
  elseif MX and MX.fold and state.mx_fold_px then L.matrix_w = math.max(L.cw * 6, math.min(math.floor(gfx.w * 0.6), state.mx_fold_px))   -- fold: своя ширина мышью
  elseif state.mx_px and MX and not MX.fold then L.matrix_w = math.max((MX.btns_w or 0) + L.pad, math.min(math.floor(gfx.w * 0.6), state.mx_px)) end
  -- линейка слева от номеров строк (2 окт): имена регионов и маркеров
  -- горизонтально на своих строках, цвет регионов — как линейка REAPER
  -- две узкие дорожки с вертикальным текстом: регионы (полоса цвета) и маркеры
  L.ruler_w = (state.ruler == false) and 0 or (2 * (L.th + 6) + L.pad + 2)   -- +2: зазор от разделителя матрицы
  -- линейка таймлайна между полосами регионов и номерами (3 окт, опция tlruler): метки REAPER
  -- на долях — beats (такт.доля), time (время), both
  local tlr = state.tlruler or 'off'
  L.tl_w = (tlr == 'beats' and ms('999.4') + L.pad) or (tlr == 'time' and ms('0:00.000') + L.pad)
    or (tlr == 'both' and ms('999.4') + ms('0:00.000') + 2 * L.pad) or 0
  L.num_w = ms('0000') + 2 * L.pad
  L.label_w = L.ruler_w + L.num_w + L.tl_w
  -- верхняя панель (как в Renoise 2): контрол | скоупы | инструменты трека
  -- верхняя панель: +15 % (просьба 1 окт) — место под монтаж mono-модуля
  -- 5 окт: на 15% выше (больше строк свойств сэмпла)
  L.top_h = state.top and (state.top_px or math.max(5 * L.rh + 8, math.min(math.floor(11 * L.rh * 1.15), math.floor(gfx.h * 0.19 * 1.15)))) or 0
  if state.top and state.top_px then L.top_h = math.max(4 * L.rh + 8, math.min(math.floor(gfx.h * 0.5), state.top_px)) end
  -- большой редактор сэмпла (3 окт, :big): вкладка item на всю высоту окна
  if state.top and state.sample_big and state.toptab == 'sample' then L.top_h = math.max(L.top_h, gfx.h - (state.statpos == 'tracker' and 0 or (L.rh + 4)) - 2) end
  L.pool_h = L.top_h
  L.ctrl_w = L.cw * 30 + 2 * L.pad
  L.inst_w = state.side and 0 or (L.cw * 32 + 2 * L.pad)
  -- положение верхнего модуля (3 окт): top — над трекером, mid — над DSP,
  -- bottom — под DSP; статус-бар: bottom — низ окна, tracker — строка в модуле трекера
  L.toppos = (state.toppos == 'mid' or state.toppos == 'bottom') and state.toppos or 'top'
  L.statpos = (state.statpos == 'tracker' or state.statpos == 'keyboard') and state.statpos or 'bottom'
  -- статус в пианинке (5 окт): третья строка полосы; клавиатура спрятана (m) —
  -- статус внизу окна
  L.kbstat = L.statpos == 'keyboard'                  -- полоса транспорта есть всегда (5 окт)
  -- положение полосы транспорта (5 окт): tracker — под трекером (как было),
  -- top — во всю ширину над верхней панелью, bottom — под DSP над статусом;
  -- снаружи трекера — со своей строкой подсказок под ней
  L.tppos = (state.transpos == 'top' or state.transpos == 'bottom') and state.transpos or 'tracker'
  L.tp_h = L.tppos ~= 'tracker' and (((L.kbstat and 3 or 2) * L.rh + 6) + (state.hints and (L.rh + 1) or 0)) or 0
  L.top_first = L.toppos == 'top'
  L.header_y = (L.toppos == 'top' and L.top_h or 0) + (L.tppos == 'top' and L.tp_h or 0)
  L.meter_h = 0
  -- шапка трека (2 окт): имя | R I M S A | громкость | панорама | лейн −+ / огибающие | подписи
  -- шапка (2 окт): имя | R I M S A | громкость | панорама | лейн / огибающие [| подписи — опция]
  -- скопы треков — во вкладке scopes (3 окт), строки в шапке нет
  -- строка входа (3 окт, опция hdrin): in <вход> [smart] — под панорамой, лейны ниже
  L.hr_in = (state.hdrin ~= false) and 1 or 0
  L.lane_row = 4 + L.hr_in
  L.header_rows = 5 + L.hr_in + (state.captions and 1 or 0)
  L.header_h = L.header_rows * L.rh + 3
  L.btn_w = L.cw + 4                             -- кнопки M S R в шапке
  L.status_h = L.statpos == 'bottom' and (L.rh + 4) or 0     -- статус внизу окна
  L.status_in = L.statpos == 'tracker' and (L.rh + 4) or 0   -- статус в модуле трекера
  L.dsp_h = state.khelp and math.max(7 * L.rh + 8, math.floor(gfx.h * 0.22))
    or (state.dsp and math.max(4 * L.rh + 8, math.floor(gfx.h * 0.18)) or 0)
  L.body_y = L.header_y + L.header_h
  -- строка подсказок под каждым модулем (опция hints, 2 окт): своё место, не поверх
  L.hint_h = state.hints and (L.rh + 1) or 0
  -- горизонтальный скролл-бар треков под телом трекера (3 окт): место всегда,
  -- чтобы тело не прыгало, когда треки перестают помещаться
  L.hsb_h = 8
  -- пианинка (4 окт): в INSERT (5 окт, без m) — полоса клавиш под скролл-баром, над статусом
  -- полоса под трекером (5 окт): транспорт всегда, клавиатура слева — по m
  L.piano_h = (L.kbstat and 3 or 2) * L.rh + 6
  L.low_h = L.hsb_h + (L.tppos == 'tracker' and L.piano_h or 0)   -- всё, что под телом в модуле трекера
  L.body_h = math.max(0, gfx.h - L.body_y - L.status_h - L.status_in - L.dsp_h - L.hint_h - L.low_h - (L.toppos ~= 'top' and L.top_h or 0) - (L.tppos == 'bottom' and L.tp_h or 0))
  L.hsb_y = L.body_y + L.body_h
  L.piano_y = L.hsb_y + L.hsb_h
  if L.tppos == 'top' then L.piano_y = 0 elseif L.tppos == 'bottom' then L.piano_y = gfx.h - L.status_h - L.tp_h end
  L.stat_y = L.body_y + L.body_h + L.low_h          -- статус в трекере (status_in)
  L.under_y = L.stat_y + L.status_in                -- строки подсказок тела
  local after = L.under_y + L.hint_h
  L.trk_bot = after                                 -- низ модуля трекера (тело, статус в нём, подсказки)
  if L.toppos == 'mid' then L.top_y = after; L.dsp_y = after + L.top_h
  elseif L.toppos == 'bottom' then L.dsp_y = after; L.top_y = after + L.dsp_h
  else L.top_y = (L.tppos == 'top' and L.tp_h or 0); L.dsp_y = after end
  -- главный модуль отдельно от верхней панели (3 окт, экспериментально):
  -- state.ctrlpos top — левый верх (над матрицей), mid — низ левой колонки над
  -- DSP, bottom — слева в полосе DSP (список эффектов сдвигается вправо).
  -- Совпадает с положением верхней панели — внутри неё, как раньше.
  L.ctrlpos = (state.ctrlpos == 'mid' or state.ctrlpos == 'bottom') and state.ctrlpos or 'top'
  if L.ctrlpos == 'bottom' and L.dsp_h <= 0 then L.ctrlpos = 'mid' end
  L.ctrl_alone = L.top_h > 0 and L.ctrlpos ~= L.toppos or false
  L.mx_top, L.mx_bot, L.ctrl_box, L.ctrl_dsp, L.ctrl_area = nil, nil, nil, nil, nil
  if L.ctrl_alone then
    if L.ctrlpos == 'bottom' then
      L.ctrl_dsp = true
      L.ctrl_box = { 0, L.dsp_y, L.ctrl_w, L.dsp_h }
    else
      -- в левой колонке: колонка не уже модуля
      if not state.mx_hidden then L.matrix_w = math.max(L.matrix_w, L.ctrl_w + D.SEPW) end
      local cw = state.mx_hidden and L.ctrl_w or (L.matrix_w - D.SEPW)
      if L.ctrlpos == 'top' then
        L.ctrl_box = { 0, L.header_y, cw, L.top_h }
        L.mx_top = L.header_y + L.top_h
      else
        L.ctrl_box = { 0, L.trk_bot - L.top_h, cw, L.top_h }
        L.mx_bot = L.trk_bot - L.top_h
      end
      if state.mx_hidden then L.matrix_w = math.max(L.matrix_w, L.ctrl_w + D.SEPW) end
    end
    L.ctrl_w = L.ctrl_box[3]
  end
  L.nrows = math.max(1, math.floor(L.body_h / L.rh))
  L.flat, L.cols = {}, {}
  L.hs_full, L.hs_n, L.hs_before, L.hs_list = 0, 0, 0, {}
  L.pt_n, L.pt_avail = 0, 0          -- PT-mode: показано / есть каналов (не больше 4)
  local cx = L.matrix_w + L.label_w
  local first = state.hscroll or 1
  local hide_below = nil          -- глубина свёрнутой папки: дети не показываются
  for ci, col in ipairs(snap.cols) do
    local depth = col.depth or 0
    if hide_below and depth <= hide_below then hide_below = nil end
    local hidden = hide_below ~= nil and depth > hide_below
    if not hidden and col.folder and state.fcollapse and state.fcollapse[col.guid] then hide_below = depth end
    local vis = (not hidden) and ci >= first and cx < L.win_w
    -- PT-mode (3 окт): ровно 4 канала от прокрутки
    if state.ptmode and not hidden and ci >= first then
      L.pt_avail = L.pt_avail + 1
      if L.pt_n >= 4 then vis = false end
    end
    -- fold: true — компактный вид (волна + нота), 'mini' — полоска в символ (прежний fold)
    local fs = state.folds[col.guid]
    if state.ptmode then fs = nil end             -- PT-mode: каналы во всю ширину, без свёрток
    -- зум ширины (Cmd + горизонтальное колесо, 3 окт): 1 — все треки компактно
    -- (нота + волна), 2 — все полоской; 0 — как у каждого трека
    if (state.wzoom or 0) >= 2 then fs = 'mini' elseif (state.wzoom or 0) == 1 and fs == nil then fs = true end
    local c = { col = col, ci = ci, x = vis and cx or nil, lanes = {}, envs = {}, folded = fs == 'mini', compact = fs == true, hidden = hidden }
    local lx = (c.x or 0) + 1
    if c.folded then
      L.flat[#L.flat + 1] = { ci = ci, col = col, folded = true, x = vis and lx or nil, w = L.fold_w }
      c.lanes[1] = { lane = col.lanes[1], x = lx, w = L.fold_w, nsub = 1, f0 = #L.flat, folded = true }
      lx = lx + L.fold_w + 1
    else
      for li, lane in ipairs(col.lanes) do
        -- минимум подколонок задаёт пользователь кнопками -/+ над лейном (1 окт)
        local nsub = math.max(1, #lane.subs, (state.subs_min or {})[col.guid .. ':' .. tostring(lane.idx)] or 0)
        local ln = { lane = lane, x = lx, nsub = nsub, f0 = #L.flat + 1, sx = {} }
        local off = 0
        for si = 1, nsub do
          local narrow = si > 1 and not (lane.audio_sub and lane.audio_sub[si])
          local G = c.compact and (narrow and L.GCN or L.GC) or (narrow and L.GN or nil)
          local sw = G and G.sub_w or L.sub_w
          ln.sx[si] = off
          L.flat[#L.flat + 1] = { ci = ci, col = col, lane = lane, li = li, si = si, sub = lane.subs[si] or {},
                                  x = vis and (lx + off) or nil, w = sw, narrow = narrow or nil, G = G,
                                  compact = c.compact or nil }
          off = off + sw
        end
        ln.w = off
        c.lanes[#c.lanes + 1] = ln
        lx = lx + ln.w + 1
      end
      local show_env = state.trackenvs and state.trackenvs[col.guid]
      if show_env == nil then show_env = state.envs end
      if c.compact then show_env = true end         -- свёрнутый: автоматизация видна всегда, схемой
      if state.ptmode then show_env = false end     -- PT-mode: только ноты
      if show_env and col.envs then
        local ew = c.compact and L.env_cw or L.env_w
        for _, e in ipairs(col.envs) do
          -- огибающая — тоже элемент L.flat (курсор заходит, INSERT правит точки)
          L.flat[#L.flat + 1] = { ci = ci, col = col, env = e, sub = {}, x = vis and lx or nil, w = ew, compact = c.compact or nil }
          c.envs[#c.envs + 1] = { e = e, x = lx, w = ew, fi = #L.flat, G = c.compact and L.GE or nil }
          lx = lx + ew + 1
        end
      end
    end
    c.w = lx - (c.x or 0)
    if vis then L.cols[#L.cols + 1] = c; cx = lx; if lx <= L.win_w then L.hs_full = (L.hs_full or 0) + 1; if state.ptmode then L.pt_n = L.pt_n + 1 end end end
    if not hidden then L.hs_n = (L.hs_n or 0) + 1; L.hs_list[L.hs_n] = ci; if ci < first then L.hs_before = (L.hs_before or 0) + 1 end end
    -- скрытые дети свёрнутой папки: записи L.flat остаются (курсор не ломается), x = nil
    if hidden then for _, f in ipairs(L.flat) do if f.ci == ci then f.x = nil end end end
  end
  L.total_w = cx
  return L
end

-- ── примитивы ─────────────────────────────────────────────────────────────
-- mono: серый по яркости, кроме ячейки курсора (D.CURCELL)
local function mono(c)
  if not D.mono or c == D.CURCELL or c == D.FOCUS_INS or (D.KEEP and D.KEEP[c]) then return c end   -- курсор, рамка INSERT, R и FX — цветные
  local l = 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]
  return { l, l, l }
end
D.mono_col = mono
-- текст в mono: не темнее порога — тусклые подписи (=START, пустые слоты,
-- подсказки) иначе пропадали на тёмном фоне (3 окт); фон и линии — как есть
local function mono_text(c)
  if not D.mono or c == D.CURCELL or c == D.FOCUS_INS or (D.KEEP and D.KEEP[c]) then return c end
  local l = math.max(0.40, 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3])
  return { l, l, l }
end
local function set(c, a) c = mono(c); gfx.set(c[1], c[2], c[3], a or 1) end
D.set = set
-- мимо фильтра mono: цвета треков в шапке остаются цветными (3 окт)
local function rawset_col(c, a) gfx.set(c[1], c[2], c[3], a or 1) end
-- bg — непрозрачная подложка (для инверсного курсора); без bg при масштабе
-- >1 текст блитится аддитивно (чёрный фон картинки не виден)
local function text(x, y, s, col, bg)
  if s == nil or s == '' then return end
  if bg then col, bg = mono(col), mono(bg) else col = mono_text(col) end   -- с подложкой (курсор) — без порога
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
        cx = cx + (sg.glyph and gfx.measurestr(sg.t) or ascii_w(sg.t))
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
  gfx.a = 1
  if D.SCALE % 1 ~= 0 then
    -- дробный масштаб (x1.5, 5 окт): ближайший сосед даёт штрихи 1-2-1-2 px;
    -- поэтому картинка ×(2·масштаб) без сглаживания и вывод /2 со сглаживанием —
    -- все штрихи одной толщины, край мягкий
    local k = math.floor(D.SCALE * 2 + 0.5)
    if not e.ov or e.ovk ~= k then
      if next_img > IMG_LAST then tcache, next_img = {}, IMG_FIRST end
      local id = next_img; next_img = next_img + 1
      local d0 = gfx.dest
      gfx.setimgdim(id, e.w * k, e.h * k)
      gfx.dest = id
      gfx.mode = 4
      gfx.blit(e.id, 1, 0, 0, 0, e.w, e.h, 0, 0, e.w * k, e.h * k)
      gfx.dest = d0
      e.ov, e.ovk = id, k
    end
    gfx.mode = (bg and 0 or 1) | 4          -- без сглаживания (5 окт: сглаженный /2 мелкий текст размывал)
    gfx.blit(e.ov, 1, 0, 0, 0, e.w * k, e.h * k, math.floor(x), math.floor(y), e.w * D.SCALE, e.h * D.SCALE)
  else
    gfx.mode = (bg and 0 or 1) | 4          -- 4 = без фильтрации при масштабировании
    gfx.blit(e.id, 1, 0, 0, 0, e.w, e.h, math.floor(x), math.floor(y), e.w * D.SCALE, e.h * D.SCALE)
  end
  gfx.mode = mode
end
D.text = text
-- крупный текст (время и BPM, 5 окт): битмап — масштабом ×k, TTF — свой кегль
-- ×k в слоте 3 (картинка ×2 размывала TTF)
function D.big_measure(s, k)
  if D.ttf then gfx.setfont(3, D.ttf_face, D.ttf_size * k); local w = gfx.measurestr(s); gfx.setfont(D.font_id); return w end
  local s0 = D.SCALE; D.SCALE = s0 * k; local w = ms(s); D.SCALE = s0; return w
end
function D.big_text(x, y, s, col, k)
  if D.ttf then
    gfx.setfont(3, D.ttf_face, D.ttf_size * k)
    set(col); gfx.x, gfx.y = math.floor(x), math.floor(y + D.SPACE); gfx.drawstr(s)
    gfx.setfont(D.font_id)
    return
  end
  local s0 = D.SCALE; D.SCALE = s0 * k; text(x, y, s, col); D.SCALE = s0
end
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

-- строка подсказок модуля: «клавиша действие» парами, клавиши янтарём; пара,
-- которая не влезает целиком, не рисуется (без наложений); модуль в фокусе ярче
function D.hint_bar(L, x, y, w, items, active)
  if not L.hint_h or L.hint_h <= 0 or not items or w <= 0 then return end
  set(U.PANEL); gfx.rect(x, y, w, L.hint_h, 1)
  set(U.LINE); gfx.rect(x, y, w, 1, 1)
  -- своей вертикали у строки подсказок нет (3 окт): границы модулей рисуют сами
  -- модули на всю высоту, со строкой подсказок — иначе стыки с выступами
  local sp = math.max(L.pad, ms(' '))        -- в битмапе ширина пробела 0
  local cx = x + L.pad
  for _, it in ipairs(items) do
    local kw, dw = ms(it[1]), ms(it[2])
    if cx + kw + sp + dw > x + w - L.pad then break end
    text(cx, y + 1, it[1], active and U.AMBER or U.GREY)
    text(cx + kw + sp, y + 1, it[2], active and U.TEXT or U.mix(U.GREY, U.PANEL, 0.25))
    cx = cx + kw + sp + dw + 2 * sp
  end
end

-- вертикальный текст (имена треков в матрице). gfx.blit с поворотом режет
-- результат прямоугольником назначения, поэтому поворачиваем честно:
-- текст → картинка A (w×h) → попиксельно в картинку B (h×w), B блитится с
-- масштабом. Кеш по строке+цвету, картинки 1000..1022 (сброс по кругу).
-- вертикальный текст: картинки 800..959 (160 подписей: имена в матрице,
-- регионы и маркеры линейки), 1023 — черновик поворота
local VFIRST, VLAST = 800, 959
local vcache, vnext = {}, VFIRST
D.reset_vcache = function() vcache, vnext = {}, VFIRST end
-- top = true — прижать к верху отведённой высоты (имена на линейке, 2 окт),
-- иначе к низу (имена треков в матрице растут снизу, как в Renoise)
function D.vtext(x, y, h_avail, str, col, bg, top)
  bg = bg or U.PANEL
  local maxchars = math.max(1, math.floor(h_avail / math.max(1, ms('W'))))
  if #str > maxchars then str = str:sub(1, maxchars) end
  local key = str .. '|' .. math.floor(col[1] * 255) .. ',' .. math.floor(col[2] * 255) .. ',' .. math.floor(col[3] * 255) .. '|' .. math.floor(bg[1] * 255) .. ',' .. math.floor(bg[2] * 255) .. ',' .. math.floor(bg[3] * 255)
  local e = vcache[key]
  if not e then
    if vnext > VLAST then vcache, vnext = {}, VFIRST end
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
  local mode = gfx.mode; gfx.mode = 4; gfx.a = 1            -- 4 — без размытия при масштабе (5 окт)
  -- прижать к низу отведённой высоты (как в Renoise: имя растёт снизу)
  local dh = e.h * D.SCALE
  local dy = top and y or (y + math.max(0, h_avail - dh))
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
  if fld == 'inst' then return L.x_inst or L.x_note, ms('00') end      -- поле инструмента (5 окт)
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
  -- своя колонка (3 окт): курсор на ноте её не касается — волна не темнеет;
  -- инверсия только в режиме note, где волна лежит под подсвеченным полем
  if column then inv = nil end
  local pk = get_peaks and get_peaks(head, math.min(total, 8192), column and mode == 'spec')
  local cx, hw, x0w
  if column then cx = x + L.x_wave + L.w_wave / 2; hw = (L.w_wave / 2) - 1; x0w = x + L.x_wave
  else cx = x + L.x_note + L.w_note / 2; hw = (L.w_note / 2) - 1 end
  local base_col = inv and U.BG or (muted and D.PEAKM or D.PEAK)
  set(base_col)
  -- непрерывная ось (3 окт): без спектральных пиков волна не рвётся на тишине
  -- и у item без пиков (офлайн) — сплошная линия в границах item, пики поверх
  if not (column and mode == 'spec') then
    local p0 = math.max(0, off - i * L.rh)
    local p1 = math.min(L.rh, total - (i * L.rh - off))
    if p1 > p0 then gfx.rect(math.floor(cx), y + p0, 1, p1 - p0, 1) end
  end
  if not pk or pk.n == 0 then return end
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
  if column and head.smk and not inv and D.show_smk ~= false then          -- опция stretch markers (5 окт)
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
  local nf = L.notes_only and 1 or (L.narrow and 2 or (3 + L.nfx))
  local name_row = cell and cell.kind == 'cont' and cell.i == 1 and cell.of.kind == 'audio' and D.itemnames and cell.of.name ~= ''
  -- поле инструмента: номер на строке ноты; пустое — точки. Рисуется ПОСЛЕ
  -- волны (4 окт: волна фоном закрашивала зелёный номер)
  local function draw_inst()
    if not (L.x_inst and not name_row) then return end
    local n = cell and (cell.kind == 'audio') and ((D.inst_num and D.inst_num[cell.item]) or (D.inst_of and D.inst_of[cell.item]))   -- номер исходника (3 окт)
    if n then text(x + L.x_inst, ty, ('%02d'):format(n % 100), c('inst', cell.muted and U.GREY or U.GREEN))
    else text(x + L.x_inst, ty, '..', c('inst', (cell and cell.kind == 'cont' and cell.of.kind == 'audio') and D.EMPTY_UNDER or D.EMPTY)) end
  end
  if not cell then
    if D.cur_box then D.cur_box(); D.cur_box = nil end
    draw_inst()
    for fld = 1, nf do
      local fx = D.field_rect(L, fld)
      text(x + fx, ty, empty_text(fld), c(fld, D.EMPTY))
    end
    return
  end
  local k = cell.kind
  if D.wave_back and (k == 'audio' or (k == 'cont' and cell.of.kind == 'audio')) then
    -- фон (3 окт): волна во всю ширину подколонки, тусклая, текст поверх
    local head = k == 'audio' and cell or cell.of
    local G = D.wave_back_geo
    if not G or G.base ~= L then
      G = setmetatable({ base = L, w_wave = 0, wave = 'off', x_note = L.pad, w_note = math.max(4, (L.sub_w or 40) - 2 * L.pad) }, { __index = L })
      D.wave_back_geo = G
    end
    local p0, pm0 = D.PEAK, D.PEAKM
    D.PEAK, D.PEAKM = D.PEAKB, D.PEAKMB
    draw_wave(G, head, k == 'audio' and 0 or cell.i, x, y, head.muted, false)
    D.PEAK, D.PEAKM = p0, pm0
  elseif L.w_wave > 0 then
    -- колонка волны: голова и все cont-строки аудио-item
    if k == 'audio' then draw_wave(L, cell, 0, x, y, cell.muted, inv == 1)
    elseif k == 'cont' and cell.of.kind == 'audio' then draw_wave(L, cell.of, cell.i, x, y, cell.of.muted, inv == 1) end
  elseif k == 'cont' and cell.of.kind == 'audio' and not D.wave_none and not D.wave_back then
    local head = cell.of
    local text_rows = (D.itemnames and head.name ~= '') and 2 or 1
    -- режим note: волна под подсвеченным полем рисуется инверсией — подложка раньше
    if D.cur_box then D.cur_box(); D.cur_box = nil end
    if cell.i >= text_rows then draw_wave(L, head, cell.i, x, y, head.muted, inv == 1) end
  end
  if D.cur_box then D.cur_box(); D.cur_box = nil end
  draw_inst()
  if k == 'audio' or k == 'midi' then
    local muted = cell.muted
    text(x + L.x_note, ty, cell.note, c(1, muted and U.GREY or U.TEXT))
    if not L.notes_only then text(x + L.x_vol, ty, cell.vol, c(2, muted and U.GREY or U.CYAN)) end
    if L.narrow or L.notes_only then
    elseif cell.delay > 0 then text(x + L.x_del, ty, string.format('%02X', cell.delay), c(3, U.TEXT))
    else text(x + L.x_del, ty, '..', c(3, D.EMPTY)) end
    local fx = cell.fx or {}
    for i = 1, L.nfx do
      if fx[i] then text(x + L.x_fx[i], ty, fx[i], c(3 + i, muted and U.GREY or D.FX))
      else text(x + L.x_fx[i], ty, '...', c(3 + i, D.EMPTY)) end
    end
  elseif k == 'off' then
    text(x + L.x_note, ty, 'OFF', c(1, D.CONT))
    if not L.notes_only then text(x + L.x_vol, ty, '..', c(2, D.EMPTY)) end
    if L.narrow or L.notes_only then
    elseif cell.delay and cell.delay > 0 then text(x + L.x_del, ty, string.format('%02X', cell.delay), c(3, D.CONT))
    else text(x + L.x_del, ty, '..', c(3, D.EMPTY)) end
    for i = 1, L.nfx do text(x + L.x_fx[i], ty, '...', c(3 + i, D.EMPTY)) end
  elseif k == 'cont' then
    local head = cell.of
    if head.kind == 'audio' then
      -- сетка трекера слегка просматривается под item (2 окт): бледные точки
      -- в полях, где ничего не написано
      local named = D.itemnames and cell.i == 1 and head.name ~= ''
      local fxv = head.fx or {}
      for fld = named and (nf + 1) or 1, nf do      -- строка имени: без точек под текстом
        local skip = (fld > 3 and L.nfx > 0 and cell.i >= 1 and fxv[cell.i * L.nfx + (fld - 3)] ~= nil)
                     or (fld == 2 and cell.vol ~= nil)
        if not skip then
          local fx = D.field_rect(L, fld)
          text(x + fx, ty, empty_text(fld), c(fld, D.EMPTY_UNDER))
        end
      end
      -- точка огибающей громкости take на этой строке (5 окт)
      if cell.vol and not L.notes_only and not (named and nf < 2) then text(x + L.x_vol, ty, cell.vol, c(2, U.CYAN)) end
      if named then
        -- вторая строка: имя item (опция item names, 3 окт); номер — на строке ноты
        -- курсор на этой строке: подложка — шириной поля ноты, не всего имени (3 окт)
        if inv == 1 then text(x + L.x_note, ty, fit(head.name, L.w_note), U.BG)
        else text(x + L.x_note, ty, fit(head.name, L.sub_w - L.x_note - L.pad), U.GREY) end
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
-- смена темы / Theme Adjuster (2 окт): сбросить кэши цветов огибающих
function D.reset_colours() env_col_cache = {} end
-- цвет огибающих (6 окт, правка): цвет темы С поправками Theme Tweaker
-- (флаг 0) — яркость, насыщенность и оттенок меняются вместе с REAPER;
-- раньше (2 окт) брался сырой цвет (флаг 1) и был тусклее аранжировки
local function theme_orig(key, fb)
  local ok, v = pcall(reaper.GetThemeColor, key, 0)
  if not ok or not v or v < 0 then return U.theme(key, fb) end
  local r, g, b = reaper.ColorFromNative(v)
  if r + g + b == 0 then return fb end
  return { r / 255, g / 255, b / 255 }
end
local function env_colour(e)
  if not e.key then return U.GREEN end
  local c = env_col_cache[e.key]
  if not c then
    c = U.readable(theme_orig(e.key, { 0.3, 0.8, 0.3 }), U.BG, 3.0)
    env_col_cache[e.key] = c
  end
  return c
end

D.env_colour = function(e) return env_colour(e) end   -- для матрицы (мини-огибающие)

-- формы сегмента REAPER 0..5 → сокращения (как меню Set segment shape)
D.ENV_SHAPES = { [0] = 'lin', [1] = 'sqr', [2] = 'slo', [3] = 'fas', [4] = 'fae', [5] = 'bez' }
local function draw_env_cell(L, ev, prev, x, y, ty, e, nxt)
  if not ev then return end
  -- ломаная по подточкам строки (M.ENV_SUB) и дальше до первого значения
  -- следующей строки — линия сплошная, в 1 px, как в аранжировке (2 окт: без
  -- разрывов на границах строк); цвет — тот же, что у этой огибающей (ключ темы)
  local function px_of(v) return x + L.env_bx + math.floor(v * (L.env_bar_w - 1) + 0.5) end
  set(env_colour(e))
  local pts = { { px_of(ev.v), y } }
  local sub = ev.sub or {}
  local n = #sub + 1
  for j, v in ipairs(sub) do pts[#pts + 1] = { px_of(v), y + L.rh * j / n } end
  pts[#pts + 1] = { px_of(nxt and nxt.v or (sub[#sub] or ev.v)), y + L.rh }
  for k = 2, #pts do gfx.line(pts[k - 1][1], pts[k - 1][2], pts[k][1], pts[k][2]) end
  local ex, cy = pts[1][1], y + 1
  local tx = x + L.env_bx + L.env_bar_w + L.pad
  if ev.pt then
    gfx.rect(ex - 2, cy - 2, L.env_compact and 3 or 5, L.env_compact and 3 or 5, 1)
    text(tx, ty, string.format('%02X', math.floor(ev.v * 255 + 0.5)), U.TEXT)
  elseif not L.env_compact and prev and prev.pt and prev.shape and prev.shape ~= 0 then
    -- форма сегмента точки строкой выше — под её значением, только если не lin
    text(tx, ty, D.ENV_SHAPES[prev.shape] or '?', U.CYAN)
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
local SG_IMG = 960                 -- спектрограммы: 960..1019 (60 слотов)
-- bare (3 окт): цвет линии осциллограммы без подложки — скоп поверх полоски курсора
local function draw_analyzer(x, y, w, h, slot, mode, info, bare)
  if not slot or w < 8 or h < 4 then return end
  if not bare then set(U.PANEL); gfx.rect(x, y, w, h, 1) end
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
  elseif mode == 'sgram' and info.spec and slot < 60 then
    local st = sg[slot]
    if not st then st = { col = 0, frame = -1 }; sg[slot] = st; gfx.setimgdim(SG_IMG + slot, SG_COLS, SG_ROWS) end
    local fr = info.spec_frame and info.spec_frame(slot) or 0
    if fr ~= st.frame then
      st.frame = fr
      local bands = info.spec(slot)
      if bands then
        local dest = gfx.dest; gfx.dest = SG_IMG + slot
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
    if n1 > 0 then gfx.blit(SG_IMG + slot, 1, 0, st.col, 0, n1, SG_ROWS, x, y, w1, h) end
    if st.col > 0 then gfx.blit(SG_IMG + slot, 1, 0, 0, 0, st.col, SG_ROWS, x + w1, y, w - w1, h) end
    gfx.mode = mode0
  elseif info.scope then
    local sc = info.scope(slot)
    if not sc then return end
    set(bare or U.GREEN)
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

-- цвета категорий параметров DSP (3 окт): от палитры темы, читаемые на фоне
function D.cat_colour(cat)
  local c = ({ gain = U.GREEN, filter = U.CYAN, time = U.AMBER, mix = U.GREY, dyn = U.RED,
               pitch = U.mix(U.RED, U.CYAN, 0.5), stereo = U.mix(U.GREEN, U.CYAN, 0.5), mod = U.mix(U.AMBER, U.RED, 0.5) })[cat]
  return c and U.readable(c, U.BG, 2.5) or nil
end

-- ── метр DSP-модуля (4 окт): вход слева (in — вход записи, pre — до
-- эффектов), выход справа (out — после всех эффектов и фейдера); две
-- полосы L / R, −60..0 дБ, сверху подпись, снизу пик в дБ
function D.dsp_meter(L, x, y, w, h, label, lv, what, hover)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  -- тонкий (5 окт): буква сверху, две полоски, число дБ — в статусе по наведению
  set(U.PANEL); gfx.rect(x, y, w, h, 1)
  text(x + math.floor((w - ms(label)) / 2), y + 1, label, U.GREY)
  local pk = math.max(lv and lv[1] or 0, lv and lv[2] or 0)
  D.meter_db = D.meter_db or {}
  D.meter_db[what] = pk > 1e-6 and 20 * math.log(pk, 10) or -150
  local my0, mh = y + L.rh + 1, h - L.rh - 2
  if mh > 4 then
    local bw = math.max(2, math.floor((w - 3) / 2))
    for ch = 1, 2 do
      local v = lv and lv[ch] or 0
      local d = v > 1e-6 and 20 * math.log(v, 10) or -150
      local fr = math.max(0, math.min(1, (d + 60) / 60))
      local bxx = x + 1 + (ch - 1) * (bw + 1)
      set(U.DIM); gfx.rect(bxx, my0, bw, mh, 0)
      local hh = math.floor(fr * (mh - 2) + 0.5)
      if hh > 0 then
        set(d > -0.1 and U.RED or (d > -9 and U.AMBER or U.GREEN))
        gfx.rect(bxx + 1, my0 + mh - 1 - hh, bw - 2, hh, 1)
      end
    end
  end
  if hover and mx >= x and mx < x + w and my >= y and my < y + h then hover.dspmeter = what end
end

-- ── виды встроенных эффектов REAPER (4 окт): картинка состояния в первой
-- колонке блока — АЧХ ReaEQ, кривая ReaComp, полосы ReaXcomp, повторы
-- ReaDelay, комната ReaVerbate, шкалы ReaGate / ReaLimit. Значения — из
-- отформатированных строк параметров (v.s) по подписям из реестра
-- цвет категории Airwindows: стабильный по имени, читаемый на фоне
function D.aw_colour(cat)
  local h = 0
  for i = 1, #(cat or '') do h = (h * 31 + cat:byte(i)) % 360 end
  local c = U.hsv and U.hsv(h, 0.55, 0.95) or nil
  if not c then
    local pal = { U.CYAN, U.GREEN, U.AMBER, U.RED, U.mix(U.CYAN, U.RED, 0.5), U.mix(U.GREEN, U.AMBER, 0.5) }
    c = pal[h % #pal + 1]
  end
  return U.readable(c, U.BG, 4.0)
end
D.FX_VIEWS = { ir = true, amigo = true, eq = true, comp = true, gate = true, limit = true, xcomp = true, delay = true, verb = true }
local VRH = 8
local function pnum(f, vals, label)
  for i, p in ipairs(f.params or {}) do
    if p.name == label then
      local s = vals[i] and vals[i].s or ''
      if s:find('inf') then return s:find('%-') and -150 or 150 end
      local mult = s:lower():find('%dk') and 1000 or 1
      local v = tonumber((s:gsub(',', '.')):match('[-+]?%d*%.?%d+'))
      return v and v * mult or nil
    end
  end
end
local function lx(fq) return math.log(math.max(20, math.min(20000, fq)) / 20) / math.log(1000) end   -- 20 Гц..20 кГц → 0..1
function D.fx_view(kind, f, vals, x, y, w, h)
  set(U.PANEL); gfx.rect(x, y, w, h, 1)
  set(U.LINE); gfx.rect(x, y, w, h, 0)
  if w < 20 or h < 12 then return end
  local function hline(v, col) set(col); gfx.rect(x + 1, math.floor(v), w - 2, 1, 1) end
  local function freq_grid()
    set(U.mix(U.PANEL, U.LINE, 0.6))
    for _, fq in ipairs({ 100, 1000, 10000 }) do gfx.rect(x + math.floor(lx(fq) * (w - 1)), y + 1, 1, h - 2, 1) end
  end
  if kind == 'eq' then
    freq_grid()
    local cy = y + h / 2
    hline(cy, U.LINE)
    local bands = {
      { t = 'ls', f = pnum(f, vals, '1 lo f'), g = pnum(f, vals, '1 lo g'), q = pnum(f, vals, '1 lo q') },
      { t = 'pk', f = pnum(f, vals, '2 f'), g = pnum(f, vals, '2 g'), q = pnum(f, vals, '2 q') },
      { t = 'pk', f = pnum(f, vals, '3 f'), g = pnum(f, vals, '3 g'), q = pnum(f, vals, '3 q') },
      { t = 'hs', f = pnum(f, vals, '4 hi f'), g = pnum(f, vals, '4 hi g'), q = pnum(f, vals, '4 hi q') },
    }
    local gg = pnum(f, vals, 'gain') or 0
    local function resp(fq)
      local db = gg
      for _, b in ipairs(bands) do
        if b.f and b.g and b.f > 0 then
          local o = math.log(fq / b.f, 2)
          if b.t == 'pk' then local sg = math.max(0.05, (b.q or 2) / 2); db = db + b.g * math.exp(-0.5 * (o / sg) ^ 2)
          elseif b.t == 'ls' then db = db + b.g / (1 + math.exp(o * 4))
          else db = db + b.g / (1 + math.exp(-o * 4)) end
        end
      end
      return db
    end
    local sc = (h / 2 - 2) / 18
    set(U.AMBER)
    local py
    for px = 0, w - 3 do
      local fq = 20 * 1000 ^ (px / (w - 3))
      local yy = math.floor(cy - math.max(-18, math.min(18, resp(fq))) * sc + 0.5)
      if py then gfx.line(x + px, py, x + 1 + px, yy) end
      py = yy
    end
    for i, b in ipairs(bands) do
      if b.f and b.g and b.f > 0 then
        local bx2 = x + 1 + math.floor(lx(b.f) * (w - 3))
        local by2 = math.floor(cy - math.max(-18, math.min(18, b.g)) * sc + 0.5)
        set(U.CYAN); gfx.rect(bx2 - 2, by2 - 2, 5, 5, 1)
        if h > 3 * VRH then text(bx2 + 3, by2 - VRH, tostring(i), U.GREY) end
      end
    end
  elseif kind == 'comp' then
    local thr = pnum(f, vals, 'thresh') or 0
    local ratio = math.max(1, pnum(f, vals, 'ratio') or 1)
    local side = math.min(w, h) - 4
    local ox, oy = x + math.floor((w - side) / 2), y + 2
    set(U.LINE); gfx.line(ox, oy + side, ox + side, oy)
    local function out(i) return i < thr and i or thr + (i - thr) / ratio end
    local function pt(i, o) return ox + (i + 60) / 60 * side, oy + side - (o + 60) / 60 * side end
    set(U.AMBER)
    local px0, py0 = pt(-60, out(-60))
    for k = 1, 30 do local i = -60 + k * 2; local px1, py1 = pt(i, out(i)); gfx.line(px0, py0, px1, py1); px0, py0 = px1, py1 end
    local tx, ty = pt(math.max(-60, math.min(0, thr)), math.max(-60, math.min(0, thr)))
    set(U.CYAN); gfx.rect(math.floor(tx) - 2, math.floor(ty) - 2, 5, 5, 1)
    text(ox + 2, oy + side - VRH - 2, ('%g:1'):format(math.floor(ratio * 10 + 0.5) / 10), U.GREY)
  elseif kind == 'gate' or kind == 'limit' then
    local thr = pnum(f, vals, 'thresh') or 0
    local function ly(db) return y + 2 + (1 - (math.max(-60, math.min(0, db)) + 60) / 60) * (h - 4) end
    set(U.mix(U.PANEL, U.GREEN, 0.25)); gfx.rect(x + 2, math.floor(ly(thr)), w - 4, math.max(1, math.floor(y + h - 2 - ly(thr))), 1)
    hline(ly(thr), U.AMBER)
    text(x + 3, math.max(y + 1, math.floor(ly(thr)) - VRH - 1), ('thr %.0f'):format(math.max(-99, thr)), U.AMBER)
    if kind == 'gate' then
      local hy = pnum(f, vals, 'hyst') or 0
      if hy < 0 then hline(ly(thr + hy), U.GREY) end
    else
      local ce = pnum(f, vals, 'ceiling') or 0
      hline(ly(ce), U.RED)
      text(x + w - ms('ceil') - 3, math.floor(ly(ce)) + 1, 'ceil', U.RED)
    end
  elseif kind == 'xcomp' then
    freq_grid()
    local lo = 20
    local cols = { U.CYAN, U.GREEN, U.AMBER, U.RED }
    for b = 1, 4 do
      local top = (b < 4) and (pnum(f, vals, b .. ' top') or 20000) or 20000
      local x0 = x + 1 + math.floor(lx(lo) * (w - 3))
      local x1 = x + 1 + math.floor(lx(top) * (w - 3))
      local thr = pnum(f, vals, b .. ' thr') or 0
      local rt = pnum(f, vals, b .. ' ratio') or 1
      local hh = math.floor((1 - (math.max(-60, math.min(0, thr)) + 60) / 60) * (h - 4))
      set(U.mix(U.PANEL, cols[b], 0.35)); gfx.rect(x0 + 1, y + 2, math.max(1, x1 - x0 - 2), math.max(1, hh), 1)
      set(cols[b]); gfx.rect(x0 + 1, y + 2 + hh, math.max(1, x1 - x0 - 2), 1, 1)
      if x1 - x0 > ms('9:1') + 2 then text(x0 + 2, y + h - VRH - 2, ('%g:1'):format(math.floor(rt * 10 + 0.5) / 10), U.GREY) end
      if b < 4 then set(U.LINE); gfx.rect(x1, y + 1, 1, h - 2, 1) end
      lo = top
    end
  elseif kind == 'delay' then
    local len = math.max(0.05, pnum(f, vals, 'length') or 1)
    local fb = pnum(f, vals, 'feedback') or -150
    local g = fb <= -100 and 0 or 10 ^ (fb / 20)
    local span = len * 8
    local a = 1
    set(U.TEXT); gfx.rect(x + 2, y + 2, 2, h - 4, 1)
    for k = 1, 32 do
      local px = x + 2 + math.floor(k * len / span * (w - 6))
      if px > x + w - 3 then break end
      local hh = math.floor(a * (h - 4))
      if hh < 1 then break end
      set(U.AMBER); gfx.rect(px, y + h - 2 - hh, 2, hh, 1)
      a = a * g
    end
  elseif kind == 'ir' then
    -- импульс ReaVerb (5 окт): спектрограмма файла импульса; ниже — имя
    local j, nm
    if D.ir_job then j, nm = D.ir_job(f) end
    if j then
      gfx.blit(j.img, 1, 0, 0, 0, j.cols, j.rows, x + 1, y + 1, w - 2, h - VRH - 3)
      if not j.done then text(x + 3, y + 2, ('%d%%'):format(math.floor(j.col / j.cols * 100)), U.GREY) end
    else text(x + 3, y + 2, fit('no impulse file (load one in ReaVerb)', w - 6), U.DIM) end
    if nm then text(x + 3, y + h - VRH - 1, fit(nm, w - 6), U.GREY) end
  elseif kind == 'amigo' then
    -- лента сэмпла: Start..End — играемая часть, Loop Start — метка; ниже —
    -- режимы буквами и Sample Rate шкалой (лоу-фай: левее — грязнее)
    local function pn(label) for i, p in ipairs(f.params or {}) do if p.name == label then return vals[i] and vals[i].n or 0, vals[i] and vals[i].s or '' end end; return 0, '' end
    local st, en, lp = pn('start'), pn('end'), pn('loop at')
    local loopon = (select(2, pn('loop')) or ''):lower():find('on') ~= nil
    local th = math.max(6, math.floor(h * 0.45))
    local sx0, sw = x + 2, w - 4
    set(U.mix(U.PANEL, U.LINE, 0.5)); gfx.rect(sx0, y + 2, sw, th, 1)
    local a, b = math.min(st, en), math.max(st, en)
    set(U.mix(U.PANEL, U.AMBER, 0.45)); gfx.rect(sx0 + math.floor(a * sw), y + 2, math.max(1, math.floor((b - a) * sw)), th, 1)
    set(U.AMBER); gfx.rect(sx0 + math.floor(a * sw), y + 2, 1, th, 1); gfx.rect(sx0 + math.floor(b * sw) - 1, y + 2, 1, th, 1)
    if loopon then set(U.CYAN); gfx.rect(sx0 + math.floor(lp * sw), y + 2, 1, th, 1) end
    local ry = y + th + 4
    local flags = { { 'rev', (select(2, pn('reverse')) or ''):lower():find('on') }, { 'pp', (select(2, pn('ping pong')) or ''):lower():find('on') },
                    { 'loop', loopon }, { 'gate', (select(2, pn('gate')) or ''):lower():find('on') } }
    local fx0 = x + 3
    for _, fl in ipairs(flags) do
      if fx0 + ms(fl[1]) > x + w - 2 then break end
      text(fx0, ry, fl[1], fl[2] and U.AMBER or U.DIM); fx0 = fx0 + ms(fl[1]) + ms(' ')
    end
    local srn, srs = pn('rate hz')
    local by3 = ry + VRH + 3
    if by3 + VRH < y + h then
      set(U.LINE); gfx.rect(x + 3, by3 + math.floor(VRH / 2), w - 6, 1, 1)
      set(U.mix(U.RED, U.GREEN, srn)); gfx.rect(x + 3, by3 + 2, math.max(1, math.floor(srn * (w - 6))), VRH - 4, 1)
      text(x + 3, by3 + VRH + 1, fit('sr ' .. srs, w - 6), U.GREY)
    end
  elseif kind == 'verb' then
    local room = (pnum(f, vals, 'room') or 50) / 100
    local damp = (pnum(f, vals, 'damp') or 50) / 100
    local wd = math.max(0.1, math.min(1, (pnum(f, vals, 'width') or 1)))
    local cx, cy = x + w / 2, y + h / 2
    for r = 1, 5 do
      local sz = (0.25 + 0.75 * room) * (1 - (r - 1) * 0.17)
      local hw, hh = sz * (w / 2 - 2) * wd, sz * (h / 2 - 2)
      set(U.mix(U.PANEL, U.CYAN, math.max(0.08, (1 - damp * 0.8) * (1 - (r - 1) / 5))))
      gfx.rect(math.floor(cx - hw), math.floor(cy - hh), math.floor(2 * hw), math.floor(2 * hh), 0)
    end
  end
end

-- ── блок трека слева в DSP (3 окт): полноценное управление выбранным треком ──
-- имя, R I M S A + фаза / FX, громкость, панорама, вход (меню), master send,
-- отправки (клик — окно маршрутизации REAPER). Фон — цвет трека, как шапка
-- канала; слайдеры и кнопки — те же hover.trs / hover.btn, что в шапке
function D.track_block(L, info, col, x, y, w, h, hover, rawc)
  local io = info.trk_io and info.trk_io(col)
  if not (col and io) then return 0 end
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local mode = info.hdrfill or 'line'
  local base = (info.trsel or {})[col.guid] and D.HDRSEL or D.HDR
  local tint = col.rgb and mode ~= 'off'
  local nbg = tint and U.mix(base, col.rgb, 0.30) or base
  local rbg = tint and U.mix(base, col.rgb, 0.18) or base
  local fill = tint and rawc or set
  fill(rbg); gfx.rect(x, y, w, h, 1)
  local T0, G0 = U.TEXT, U.GREY
  U.TEXT, U.GREY = U.readable(T0, rbg, 4.5), U.readable(G0, rbg, 3.0)
  -- 4 окт (компактнее): имени нет — оно на вкладке трека в шапке DSP; кнопки — первой строкой
  local yy = y + 2
  -- кнопки
  local bx = x + L.pad
  local mon = col.recmon or 0
  local btns = { { 'R', col.armed, D.ARM, 'arm' }, { 'I', mon > 0, U.CYAN, 'monitor', mon == 2 },
                 { 'M', col.muted, U.AMBER, 'mute' }, { 'S', col.solo, U.GREEN, 'solo' },
                 { 'ø', io.phase, U.AMBER, 'phase', nil, true }, { 'FX', not io.fxen, U.RED, 'fxen', nil, true } }
  for _, b in ipairs(btns) do
    -- ø фазы — буква (4 окт: был круг с чертой); не-ASCII рисует системный моно
    local bw = math.max(L.btn_w, ms(b[1]) + 4)
    if bx + bw > x + w - L.pad then break end
    local on = b[2]
    set((on and not b[5]) and ((b[3] == D.ARM and D.ARM_T) or U.tint(b[3], 0.5)) or U.PANEL); gfx.rect(bx, yy, bw, L.rh - 2, 1)
    set(on and b[3] or U.DIM); gfx.rect(bx, yy, bw, L.rh - 2, 0)
    text(bx + math.floor((bw - ms(b[1])) / 2), yy, b[1], on and b[3] or U.GREY)
    if mx >= bx and mx < bx + bw and my >= yy and my < yy + L.rh then
      if b[6] then hover.trkio = { col = col, what = b[4] } else hover.btn = { col = col, what = b[4] } end
    end
    bx = bx + bw + 1
  end
  yy = yy + L.rh
  -- слайдеры громкости и панорамы (как в шапке)
  local live = info.trs_live
  local function lv(what, v) return (live and live.guid == col.guid and live.what == what) and live.v or v end
  local function slider(sy, frac, centered, label, val, what)
    -- место под значение постоянное (3 окт): дорожка и её центр не прыгают от C к R100
    local vres = math.max(ms('-00.0'), ms(val))
    local lw, vw = ms(label) + L.pad, vres + L.pad
    local wx0, ww = x + L.pad + lw, math.max(4, w - 2 * L.pad - lw - vw)
    local cy = sy + math.floor(L.rh / 2)
    local hot = mx >= wx0 - 2 and mx < wx0 + ww + 2 and my >= sy and my < sy + L.rh
    text(x + L.pad, sy, label, U.GREY)
    set(U.DIM); gfx.rect(wx0, cy - 1, ww, 2, 1)
    frac = math.max(0, math.min(1, frac))
    set(hot and U.AMBER or U.TEXT)
    if centered then
      local mid, px = wx0 + math.floor(ww / 2), wx0 + math.floor(frac * ww + 0.5)
      gfx.rect(math.min(mid, px), sy + 4, math.max(1, math.abs(px - mid)), L.rh - 8, 1)
    else gfx.rect(wx0, sy + 4, math.max(1, math.floor(frac * ww + 0.5)), L.rh - 8, 1) end
    text(wx0 + ww + L.pad + vres - ms(val), sy, val, U.GREY)
    if hot then hover.trs = { col = col, what = what, x0 = wx0, w = ww } end
  end
  local vol = lv('vol', col.vol or 1)
  local db = vol > 1e-6 and 20 * math.log(vol, 10) or -150
  if yy + L.rh <= y + h then slider(yy, (math.max(-60, math.min(12, db)) + 60) / 72, false, 'vol', db <= -60 and '-inf' or ('%+.1f'):format(db), 'vol'); yy = yy + L.rh end
  local pan = lv('pan', col.pan or 0)
  local ptxt = math.abs(pan) < 0.005 and 'C' or ((pan < 0 and 'L' or 'R') .. math.floor(math.abs(pan) * 100 + 0.5))
  if yy + L.rh <= y + h then slider(yy, (pan + 1) / 2, true, 'pan', ptxt, 'pan'); yy = yy + L.rh end
  -- строки-кнопки: вход, выход, отправки
  local function row(label, val, what, on)
    if yy + L.rh > y + h then return end
    local hot = mx >= x and mx < x + w and my >= yy and my < yy + L.rh
    if hot then set(U.tint(U.AMBER, 0.2)); gfx.rect(x + 1, yy, w - 2, L.rh, 1); hover.trkio = { col = col, what = what } end
    text(x + L.pad, yy, label, U.GREY)
    local lx = x + L.pad + ms('send ') + L.pad
    text(lx, yy, fit(val, x + w - L.pad - lx), on == false and U.GREY or U.TEXT)
    yy = yy + L.rh
  end
  -- smart (4 окт: из шапки трека сюда) — кнопкой справа в строке in
  local sy0 = yy
  local sbw = ms('smart') + 2 * L.pad
  local show_smart = info.smart_ok and w > ms('in ') + 6 * L.cw + sbw + 3 * L.pad
  row('in', (io.input:gsub(' / in ', '/'):gsub(' / ', '/')) .. ' v', 'input')
  if show_smart and yy > sy0 then
    local sx = x + w - L.pad - sbw
    set(U.PANEL); gfx.rect(sx - L.pad, sy0, sbw + L.pad, L.rh, 1)        -- текст входа не залезает под кнопку
    local hot = mx >= sx and mx < sx + sbw and my >= sy0 and my < sy0 + L.rh
    set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(sx, sy0 + 1, sbw, L.rh - 2, 1)
    set(hot and U.AMBER or U.DIM); gfx.rect(sx, sy0 + 1, sbw, L.rh - 2, 0)
    text(sx + L.pad, sy0, 'smart', hot and U.AMBER or U.GREY)
    if hot then hover.trkio = { col = col, what = 'smart' } end
  end
  -- out и сенды одной строкой (4 окт): слева master (клик — вкл / выкл),
  -- справа «sN rN v» — панель сендов
  local ry0 = yy
  if yy + L.rh <= y + h then
    local stxt = ('s%d r%d %s'):format(#io.sends, io.recv, D.sendpop == col.guid and '^' or 'v')
    local sw = ms(stxt) + 2 * L.pad
    local sx = x + w - L.pad - sw
    local hot1 = mx >= x and mx < sx and my >= yy and my < yy + L.rh
    local hot2 = mx >= sx and mx < x + w and my >= yy and my < yy + L.rh
    if hot1 then set(U.tint(U.AMBER, 0.2)); gfx.rect(x + 1, yy, sx - x - 1, L.rh, 1); hover.trkio = { col = col, what = 'mainsend' } end
    if hot2 then set(U.tint(U.AMBER, 0.2)); gfx.rect(sx, yy, x + w - sx - 1, L.rh, 1); hover.trkio = { col = col, what = 'sends' } end
    text(x + L.pad, yy, 'out', U.GREY)
    local lx = x + L.pad + ms('send ') + L.pad
    text(lx, yy, fit((io.mainsend and 'master' or 'no master') .. (io.hw > 0 and (' +hw' .. io.hw) or ''), sx - lx - L.pad), io.mainsend and U.TEXT or U.GREY)
    text(sx + L.pad, yy, stxt, (#io.sends > 0 or io.recv > 0) and U.TEXT or U.GREY)
    yy = yy + L.rh
  end
  for _, sd in ipairs(io.sends) do
    local sdb = sd.vol > 1e-6 and 20 * math.log(sd.vol, 10) or -150
    row('send', ('%s  %s'):format(sd.name, sdb <= -60 and '-inf' or ('%+.1f'):format(sdb)), 'routing', not sd.mute)
  end
  if D.sendpop == col.guid then
    D.late_send = function() D.draw_sendpop(L, info, col, io, x, ry0, hover) end
  end
  U.TEXT, U.GREY = T0, G0
  set(U.LINE); gfx.rect(x, y, w, h, 0)                -- рамка, как у блоков FX
  return w
end

-- панель сендов трека (3 окт): над строкой sends блока трека DSP (не влезает —
-- под ней); строка — имя, громкость слайдером, m (mute), x (удалить); сверху
-- + send (fzf по трекам) и routing (окно REAPER)
function D.draw_sendpop(L, info, col, io, ax, ay, hover)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local pw = math.min(L.win_w - 2 * L.pad, L.cw * 40 + 2 * L.pad)
  local n = #io.sends
  local ph = (n + 1 + (n == 0 and 1 or 0)) * L.rh + 2 * L.pad
  local px = math.max(L.pad, math.min(L.win_w - pw - L.pad, ax))
  local py = ay - ph
  if py < 2 then py = ay + L.rh end
  local inside = mx >= px and mx < px + pw and my >= py and my < py + ph
  if inside then for k in pairs(hover) do hover[k] = nil end; hover.sendpop_in = true end
  set(U.PANEL); gfx.rect(px, py, pw, ph, 1)
  set(U.AMBER); gfx.rect(px, py, pw, ph, 0)
  local y = py + L.pad
  local x = px + L.pad
  text(x, y, fit('sends ' .. (col.name or ''), pw - 2 * L.pad - ms('+ send routing') - 3 * L.pad), U.AMBER)
  local bx = px + pw - L.pad
  for _, b in ipairs({ { 'routing', 'routing' }, { '+ send', 'add' } }) do
    local bw = ms(b[1]) + 2 * L.pad
    bx = bx - bw
    local hot = mx >= bx and mx < bx + bw and my >= y and my < y + L.rh
    set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, y, bw, L.rh - 1, 1)
    set(hot and U.AMBER or U.LINE); gfx.rect(bx, y, bw, L.rh - 1, 0)
    text(bx + L.pad, y, b[1], hot and U.AMBER or U.TEXT)
    if hot then hover.sendpop = { col = col, what = b[2] } end
    bx = bx - 2
  end
  y = y + L.rh
  if n == 0 then text(x, y, fit('no sends - + send: pick a track (fzf)', pw - 2 * L.pad), U.GREY) end
  local nw = math.floor((pw - 2 * L.pad) * 0.35)
  for i, sd in ipairs(io.sends) do
    local db = sd.vol > 1e-6 and 20 * math.log(sd.vol, 10) or -150
    text(x, y, fit(sd.name, nw - L.pad), sd.mute and U.GREY or U.TEXT)
    -- кнопки справа: m x
    local rx = px + pw - L.pad
    for _, b in ipairs({ { 'x', 'del' }, { 'm', 'mute' } }) do
      local bw = L.btn_w
      rx = rx - bw
      local on = b[2] == 'mute' and sd.mute
      local hot = mx >= rx and mx < rx + bw and my >= y and my < y + L.rh
      set(on and U.tint(U.AMBER, 0.5) or (hot and D.CURROW or U.BG)); gfx.rect(rx, y + 1, bw, L.rh - 2, 1)
      set(U.DIM); gfx.rect(rx, y + 1, bw, L.rh - 2, 0)
      text(rx + 2, y, b[1], (on or hot) and U.AMBER or U.GREY)
      if hot then hover.sendpop = { col = col, what = b[2], idx = i - 1 } end
      rx = rx - 2
    end
    -- громкость: дорожка, число справа (место постоянное)
    local vt = db <= -60 and '-inf' or ('%+.1f'):format(db)
    local vres = ms('-00.0')
    local sx0 = x + nw
    local sw = rx - L.pad - vres - L.pad - sx0
    if sw > 8 then
      local fr = (math.max(-60, math.min(12, db)) + 60) / 72
      local cy = y + math.floor(L.rh / 2)
      local hot = mx >= sx0 - 2 and mx < sx0 + sw + 2 and my >= y and my < y + L.rh
      set(U.DIM); gfx.rect(sx0, cy - 1, sw, 2, 1)
      set(hot and U.AMBER or U.TEXT); gfx.rect(sx0, y + 4, math.max(1, math.floor(fr * sw + 0.5)), L.rh - 8, 1)
      text(sx0 + sw + L.pad + vres - ms(vt), y, vt, U.GREY)
      if hot then hover.sendvol = { col = col, idx = i - 1, x0 = sx0, w = sw } end
    end
    y = y + L.rh
  end
end

-- «призрак» перетаскивания (DSP-блок и т.п.): янтарная бирка у курсора
function D.ghost(label)
  if not label then return end
  local bw = ms(label) + 2 * 6
  local x, y = gfx.mouse_x + 12, gfx.mouse_y - TH() // 2
  set(U.AMBER); gfx.rect(x, y, bw, TH() + 2, 1)
  set(U.BG); gfx.rect(x, y, bw, TH() + 2, 0)
  text(x + 6, y + 1, label, U.BG, U.AMBER)
end

local function draw_mono(L, info, X0, Y0, MW, H, hover)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  -- mono-модуль (jf_grid), вкладка grid (2 окт: из блока управления): состояние шины, владелец, мини-грид того, что
  -- показывает мод трекера, легенда. Кнопки take / grid — владение поверхностью.
  do
    local mo = info.mono
    local y0 = Y0
    if not mo then text(X0, y0, 'no monome data (jf_grid)', U.GREY) end
    if mo and H - y0 > 2 * L.rh then
      local st = mo.alive and ('grid ' .. (mo.grid and 'ok' or '--') .. '  arc ' .. (mo.arc and 'ok' or '--') .. '  owner ' .. (mo.owner_name or '-'))
                 or 'daemon jf_grid: not running'
      text(X0 + 2, y0 + 1, fit('mono  ' .. st, MW - 2 * L.pad - ms('[take][grid]') - L.pad), mo.alive and (mo.owner_id == 9 and U.AMBER or U.TEXT) or U.GREY)
      -- кнопки справа
      local bx = (X0 + MW) - L.pad
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
      local cs = math.max(2, math.min(math.floor((MW * 0.45) / 16), math.floor(avail / 8)))
      if mo.leds then
        for ry = 1, 8 do
          for cx = 1, 16 do
            local v = (mo.leds[ry] and mo.leds[ry][cx]) or 0
            set(U.mix(U.BG, U.AMBER, 0.08 + v / 15 * 0.92))
            gfx.rect(X0 + (cx - 1) * cs, y0 + (ry - 1) * cs, cs - 1, cs - 1, 1)
          end
        end
      end
      -- подписи: над сеткой буквы треков, под нижним рядом — что делает кнопка
      if mo.cols then
        for cx = 1, math.min(15, #mo.cols) do
          local ch = (mo.cols[cx] or '?'):sub(1, 1)
          if cs >= L.cw then text(X0 + (cx - 1) * cs, y0 - L.rh, ch, U.GREY) end
        end
      end
      -- легенда — горизонтально справа от мини-грида
      local lx = X0 + 16 * cs + L.pad
      local lw = (X0 + MW) - lx - L.pad
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
            D.vtext(X0 + (cx - 1) * cs + math.floor((cs - L.th) / 2), vy, vh, names[cx], cx == 16 and U.DIM or U.GREY, U.PANEL)
          end
        end
      end
    end
  end
end

-- главный модуль (help / options / транспорт) в своих координатах: x от 0,
-- y от 0, высота H, ширина L.ctrl_w; рисует верхняя панель или отдельно (3 окт)
local function draw_ctrl(L, info, H, hover)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local c = info.ctrl or {}
  -- контрол (2 окт): три группы — control (транспорт, размер и доли,
  -- метроном, ввод), options (вид), help; каждая группа — с новой строки,
  -- без линий и подписей (просьба пользователя). monome — во вкладке grid.
  local sig = (c.sig_num and c.sig_den) and ('%d/%d'):format(c.sig_num, c.sig_den) or '4/4'
  -- 3 окт (просьба): сверху — help / about / options / notes; тонкая линия;
  -- опции вида; тонкая линия; внизу модуля, прижато ко дну — транспорт и ввод
  local groups = {
    { name = 'help', items = {
      -- кнопки с рамкой (4 окт): открытое окно — оранжевый фон, иначе серый текст
      { 'help', 'help', btn = true, on = c.khelp }, { 'about', 'about', btn = true, on = c.about_open },
      { 'options', 'options', btn = true, on = c.options_open }, { 'notes', 'notes', btn = true, on = c.notes },
      { 'tutorial', 'tutorial', btn = true, on = c.tour }, { 'screensets', 'screensets', btn = true, on = c.ss_open },
    } },
    -- транспорт и ввод (5 окт) — в полосе под трекером (D.transport_groups)
    -- быстрые вкл / выкл (4 окт): самое частое из вида — кнопками в рамке
    -- быстрые вкл / выкл (5 окт): колонка — где это на экране: слева / в центре
    -- (сверху вниз, как на экране) / справа; пустые клетки — { false }
    { name = 'quick', items = (function()
      local function q(id, label, on, extra) local t = { id, label, on and U.CYAN or U.GREY }; if extra then for k, v in pairs(extra) do t[k] = v end end; return t end
      local cols = {
        { q('q_mx', 'matrix', c.q_mx), q('q_ruler', 'ruler', c.q_ruler), q('q_hints', 'hints', c.q_hints), q('q_listen', 'listen', c.q_listen) },
        { q('q_scopes', 'scopes', c.q_scopes), q('q_input', 'input', c.q_input), q('q_captions', 'col names', c.q_captions), q('q_names', 'names', c.q_names),
          q('q_wave', 'wave', c.q_wave), q('q_colors', 'colours', c.q_colors), q('q_envs', 'envs', c.q_envs), q('q_meters', 'meters', c.q_meters), q('q_dsp', 'dsp', c.q_dsp) },
        { q('q_side', 'browser', c.q_side), q('q_preview', 'preview', c.q_preview), q('q_keys', 'kcast', c.q_keys, { sizer = true }),
          q('oneclick', 'one click', c.oneclick), q('autofocus', 'autofocus', c.autofocus),
          -- тоглы из полосы транспорта (5 окт)
          q('follow', 'follow', c.follow), q('lock', 'lock', c.lock), q('fixed', 'fixed', c.fixed), q('xfade', c.xfade and ('x-fade ' .. (c.xfade_ms or 10)) or 'x-fade', c.xfade) },
      }
      local out, n = {}, math.max(#cols[1], #cols[2], #cols[3])
      for r = 1, n do for k = 1, 3 do out[#out + 1] = cols[k][r] or { false } end end
      return out
    end)() },
  }
  local colw = math.floor((L.ctrl_w - 2 * L.pad) / 3)
  L.ctrl_area = { 0, 0, L.ctrl_w, H - 2 }                 -- главный модуль: фокус ctrl (3 окт)
  D.ctrl_rect = D.ctrl_rect or {}
  local y = 2
  local function cell(it, ci)
    if not it[1] then return end                   -- пустая клетка колонки
    local x = L.pad + ci * colw
    if y + L.rh > H - 2 then return end
    local hot = mx >= x and mx < x + colw and my >= y and my < y + L.rh
    local kbd = info.focus == 'ctrl' and info.ctrl_sel == it[1]       -- курсор клавиатуры (3 окт)
    if it.btn then
      -- кнопка окна: рамка; открыто — оранжевый фон и тёмный текст
      local on = it.on
      set(on and U.AMBER or ((hot or kbd) and D.CURROW or U.PANEL)); gfx.rect(x, y, colw - 2, L.rh, 1)
      set(on and U.AMBER or ((hot or kbd) and U.AMBER or U.LINE)); gfx.rect(x, y, colw - 2, L.rh, 0)
      if hot then hover.ctrl = it[1] end
      D.ctrl_rect[it[1]] = { x, y, colw, L.rh }
      text(x + 3, y + 1, fit(it[2], colw - 6), on and U.BG or ((hot or kbd) and U.AMBER or U.GREY))
      hint('ctrl', x, y, colw, L.rh, it[1])
      return
    end
    if kbd then set(U.tint(U.AMBER, 0.35)); gfx.rect(x, y, colw - 2, L.rh, 1)
    elseif hot then set(D.CURROW); gfx.rect(x, y, colw - 2, L.rh, 1) end
    if hot then hover.ctrl = it[1] end
    D.ctrl_rect[it[1]] = { x, y, colw, L.rh }
    text(x + 2, y + 1, fit(it[2], colw - 4), it[3] or U.TEXT)
    if it.sizer then
      -- keys - + (4 окт): та же клетка — слово вкл / выкл, - + размер
      local sx = x + 2 + ms(it[2] .. ' ')
      for _, z in ipairs({ { '-', 'q_kcm' }, { '+', 'q_kcp' } }) do
        local zw = ms(z[1]) + L.pad
        local zh = mx >= sx - 1 and mx < sx + zw and my >= y and my < y + L.rh
        if zh then hover.ctrl = z[2] end
        text(sx, y + 1, z[1], zh and U.AMBER or U.GREY)
        sx = sx + zw
      end
    end
    hint('ctrl', x, y, colw, L.rh, it[1])
  end
  -- доли: размер, такт, квадраты долей (текущая горит), строк на долю / такт
  local function beats_row()
    if y + L.rh > H - 2 then return end
    local x = L.pad + 2
    local num = math.max(1, math.min(16, c.sig_num or 4))
    local cur = c.beat and (math.floor(c.beat) + 1) or 0
    local bs = math.max(4, L.rh - 6)
    local lbl = ('bar %d  beat %d/%d'):format(c.bar or 1, math.max(1, cur), num)
    text(x, y + 1, lbl, U.TEXT)
    x = x + ms(lbl) + L.pad
    local sq_w = num * (bs + 2)
    local tail = ('%d/beat %d/bar'):format(c.lpb or 4, c.rows_bar or 16)
    local room = L.ctrl_w - L.pad - x
    if sq_w <= room then
      for k = 1, num do
        local bx = x + (k - 1) * (bs + 2)
        local by = y + math.floor((L.rh - bs) / 2)
        local on = k == cur
        set(on and (c.playing and U.AMBER or U.TEXT) or U.BG); gfx.rect(bx, by, bs, bs, 1)
        set(k == 1 and U.AMBER or U.LINE); gfx.rect(bx, by, bs, bs, 0)
      end
      x = x + sq_w + L.pad
      if ms(tail) <= L.ctrl_w - L.pad - x then text(x, y + 1, tail, U.GREY) end
    end
    local hot = mx >= L.pad and mx < L.ctrl_w - L.pad and my >= y and my < y + L.rh
    if hot then hover.ctrl = 'beats' end
    y = y + L.rh
  end
  -- строк в группе (доли — своя строка во всю ширину)
  local function grows(g)
    local n, ci = 0, 0
    for _, it in ipairs(g.items) do
      if it[1] == 'beats' then if ci > 0 then n = n + 1; ci = 0 end; n = n + 1
      else ci = ci + 1; if ci == 3 then ci = 0; n = n + 1 end end
    end
    return n + (ci > 0 and 1 or 0)
  end
  local function thin(yy) set(D.SEP); gfx.rect(L.pad, yy, L.ctrl_w - 2 * L.pad, 1, 1) end
  for gi, g in ipairs(groups) do
    local ci = 0
    if gi > 1 then
      local gap = 3
      -- 4 окт: пустого места нет — транспорт сразу под кнопками окон, под ним
      -- быстрые вкл / выкл; заметки и скринсеты — всплывашками у кнопок
      y = y + gap                                     -- 5 окт: без линии между группами
    end
    for _, it in ipairs(g.items) do
      if it[1] == 'beats' then
        if ci > 0 then y = y + L.rh; ci = 0 end
        beats_row()
      else
        cell(it, ci)
        ci = ci + 1
        if ci == 3 then ci = 0; y = y + L.rh end
      end
    end
    if ci > 0 then y = y + L.rh end
    if g.name == 'help' then D.ctrl_help_bottom = y + 1 end
  end
  -- заметки — всплывашкой от низа кнопок окон (D.notes_popup), тур — в
  -- оставшемся месте под быстрыми кнопками
  if info.notes_draw then D.notes_popup = { y = D.ctrl_help_bottom or 2 } end
  L.zone_rect = nil
  if info.zone_draw and info.ctrl and info.ctrl.tour and H - 3 - (y + 3) >= 2 * L.rh then
    local zx, zy, zw, zh = L.pad, y + 3, L.ctrl_w - 2 * L.pad, H - 3 - (y + 3)
    thin(y + 1)
    L.zone_rect = { zx, zy, zw, zh }
    local ok, hz = pcall(info.zone_draw, L, zx, zy, zw, zh)
    if ok then hover.zone = hz end
  end
  set(D.SEP); gfx.rect(L.ctrl_w, 0, D.SEPW, H, 1)
end

local function draw_topbar(L, info)
  local hover = {}
  local H = L.top_h
  set(U.PANEL); gfx.rect(0, 0, L.win_w, H, 1)
  -- граница модуля (3 окт): наверху — линия снизу (к трекеру); mid / bottom —
  -- сверху (к трекеру или DSP и списку эффектов), снизу её даёт DSP / статус —
  -- иначе стык без линии или две линии рядом
  set(D.SEP); gfx.rect(0, (not L.top_first) and 0 or H - 2, gfx.w, D.SEPW, 1)
  local mx, my = gfx.mouse_x, gfx.mouse_y

  if not L.ctrl_alone then draw_ctrl(L, info, H, hover) end

  -- центр: вкладки scope | sample | mod | retro | master
  local sx0 = L.ctrl_alone and L.pad or (L.ctrl_w + L.pad)
  local sx1 = L.win_w - L.inst_w - L.pad - (L.slices_w or 0)   -- справа — модуль слайсов
  local tab = info.toptab or 'scope'
  local tx = sx0
  if tab == 'scope' then tab = 'master' end   -- вкладки scope больше нет: анализаторы в master
  for _, t in ipairs(info.tabs or { 'sample', 'modulation', 'midi', 'retro', 'garden', 'master' }) do   -- garden подписан «orca», midi — learn, grid — опция (2 окт)
    local lbl = D.ic(t, (t == 'garden' and 'orca') or (t == 'modulation' and 'modulate') or (t == 'sample' and 'item') or (t == 'retro' and 'rec') or t)
    local tw = ms(lbl) + 2 * L.pad
    local on = t == tab
    local hot = mx >= tx and mx < tx + tw and my >= 1 and my < 1 + L.rh
    -- rec — оттенок кнопки записи (фиолетовый, как R), остальные — янтарь
    local acc, acc_t = U.AMBER, U.tint(U.AMBER, 0.35)
    if t == 'retro' then acc, acc_t = D.ARM, D.ARM_T end
    set(on and acc_t or (hot and D.CURROW or (t == 'retro' and U.mix(U.BG, D.ARM, 0.15) or U.BG))); gfx.rect(tx, 1, tw, L.rh, 1)
    set((on or t == 'retro') and acc or U.LINE); gfx.rect(tx, 1, tw, L.rh, 0)
    text(tx + L.pad, 1, lbl, on and (t == 'retro' and U.TEXT or acc) or (t == 'retro' and D.ARM or U.GREY))
    if hot then hover.tab = t end
    hint('tab', tx, 1, tw, L.rh, t)
    tx = tx + tw + 2
  end
  -- режим анализатора (scope / spec / sgram) — для вкладок scope и master, как
  -- переключатель режима пиков в REAPER
  local amode = info.scopemode or 'scope'
  if (tab == 'master' or tab == 'scopes') and info.scope then   -- режим анализатора: master и scopes
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
  local HT = H
  H = H - (L.hint_h or 0)        -- место под строку подсказок вкладки
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
      -- пустой трек: запись — во вкладке rec (3 окт: кнопки [rec] здесь больше нет)
      text(sx0, cy0 + 1, 'no instrument - the rec tab records one', U.GREY)
    end
  elseif tab == 'modulation' then
    -- модуляционная матрица (jf_tracker_modmatrix.lua): таблица L1 / ENV / LNK
    if info.mm_draw then hover.mm = info.mm_draw(L, sx0, cy0, sx1 - sx0, H - cy0 - 2) end
  elseif tab == 'grid' then
    -- monome (jf_grid): шина, владелец, мини-грид, легенда
    draw_mono(L, info, sx0, cy0, sx1 - sx0, H - 2, hover)
  elseif tab == 'midi' then
    -- MIDI learn (jf_tracker_midimap.lua): цели слайсера и их CC / ноты
    if info.midi_draw then hover.midimap = info.midi_draw(L, sx0, cy0, sx1 - sx0, H - cy0 - 2) end
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
      btn('all', 'all'); btn('play', 'play', c and c.playing); btn('stop', 'stop'); btn('put', 'put'); btn('depot', 'lib')
      btn('loop ' .. tostring(r.loop_bars or 2), 'loop'); btn('add', 'add')
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
        text(wx, y + wh + 1, fit(('sel %.2fs  drag: select · a: all · Space: play · p: put @cursor · d: to lib (=LIB) · [ ]: edges'):format(secs), ww), U.GREY)
      elseif not c then
        text(wx, y, 'select a track with jf_rec (< >)', U.GREY)
      end
    end
  elseif tab == 'scopes' then
    -- вкладка scopes (3 окт): скоп на каждый трек сеткой — ячейка не уже 12
    -- символов, рядов сколько нужно; в ячейке анализатор (режим кнопками
    -- справа вверху), метры L R и имя трека; клик — курсор на трек
    local n = #cols
    local aw, ah = sx1 - sx0, H - cy0 - 2
    if n == 0 then text(sx0, cy0, 'no tracks', U.GREY)
    elseif not info.scope or not cols[1].scope_slot then
      local msg = 'track scopes are off - click here to put the scope bridge on every track'
      text(sx0, cy0, fit(msg, aw), U.GREY)
      if mx >= sx0 and mx < sx1 and my >= cy0 and my < cy0 + L.rh then hover.scopes_on = true end
    elseif aw > 20 and ah > 2 * L.rh then
      local minw = L.cw * 12
      local ncol = math.max(1, math.min(n, math.floor(aw / minw)))
      local nrow = math.ceil(n / ncol)
      local cw = math.floor(aw / ncol)
      local ch = math.floor(ah / nrow)
      if ch < 2 * L.rh then nrow = math.max(1, math.floor(ah / (2 * L.rh))); ch = math.floor(ah / nrow) end
      for i, col in ipairs(cols) do
        local r = math.floor((i - 1) / ncol)
        if r >= nrow then break end
        local x = sx0 + ((i - 1) % ncol) * cw
        local y = cy0 + r * ch
        local sh = ch - L.rh - 2
        local pl, pr = 0, 0
        if info.peaks then pl, pr = info.peaks(col) end
        local bw = math.max(2, math.floor(L.cw / 2))
        local ow = cw - 2 * (bw + 1) - 6
        if col.scope_slot and ow > 8 and sh > 4 then draw_analyzer(x + 2, y, ow, sh, col.scope_slot, amode, info) end
        for k, v in ipairs({ pl, pr }) do
          local bx = x + 2 + ow + 2 + (k - 1) * (bw + 1)
          set(U.DIM); gfx.rect(bx, y, bw, sh, 1)
          local hpx = math.floor(math.min(1, v) * sh + 0.5)
          if hpx > 0 then set(meter_color(v)); gfx.rect(bx, y + sh - hpx, bw, hpx, 1) end
        end
        if col.rgb then set(col.rgb); gfx.rect(x + 2, y + sh + 1, 2, L.rh - 2, 1) end
        text(x + 6, y + sh + 1, fit(col.name, cw - 10), col == info.pool_col and U.AMBER or U.GREY)
        if mx >= x and mx < x + cw and my >= y and my < y + ch then hover.scope = col end
        hint('scope', x, y, cw, ch, col)
      end
    end
  end

  -- инструменты: в верхней панели, только если сайдбар скрыт
  if (L.hint_h or 0) > 0 then
    -- за границей главного модуля (+2): строка не заливает его вертикаль (3 окт: уголок)
    D.hint_bar(L, sx0 - L.pad + D.SEPW, H - 2, sx1 - sx0 + 2 * L.pad - D.SEPW, (info.hint_bars or function() end)(info.top_page or tab), info.focus == 'top')
    if L.inst_w > 0 then D.hint_bar(L, gfx.w - L.inst_w, H - 2, L.inst_w, (info.hint_bars or function() end)('inst'), info.focus == 'inst') end
  end
  if L.inst_w > 0 then D.draw_instruments(L, info, gfx.w - L.inst_w, 0, L.inst_w, H, hover) end
  H = HT
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
-- пустые слоты после инструментов (2 окт): «..» — встать, засэмплить ретро,
-- бросить фрагмент / файл; минимум 2, до 8 слотов всего
function D.empty_slots(n) return math.max(2, 8 - (n or 0)) end
local function add_empty(rows, pool)
  for k = 1, D.empty_slots(#pool) do rows[#rows + 1] = { empty = #pool + k } end
  -- пустые слоты продолжают номера исходников (слайсы номеров не берут)
  local nr = 0
  for _, e in ipairs(pool) do if not e.parent then nr = nr + 1 end end
  for _, r in ipairs(rows) do if r.empty then r.num = nr + (r.empty - #pool) end end
  return rows
end
function D.pool_rows(pool, sort, col, cols)
  local rows = {}
  if sort == 'len' or sort == 'mark' or sort == 'name' then
    local idx = {}
    for i = 1, #pool do idx[i] = i end
    local function rank(e)
      local here = col and e.track_set and e.track_set[col.name]
      return (here and 0 or 4) + (e.slices and 0 or 2) + ((e.depot and not (e.tracks and e.tracks[1])) and 1 or 0)
    end
    table.sort(idx, function(a, b)
      local ea, eb = pool[a], pool[b]
      if sort == 'mark' then local ra, rb = rank(ea), rank(eb); if ra ~= rb then return ra < rb end end
      if sort == 'name' and ea.name ~= eb.name then return (ea.name or ''):lower() < (eb.name or ''):lower() end
      if ea.len ~= eb.len then return ea.len < eb.len end
      return a < b
    end)
    for _, i in ipairs(idx) do if not pool[i].parent then rows[#rows + 1] = { i = i } end end   -- слайсы вложены (3 окт)
    return add_empty(rows, pool)
  end
  -- дерево (2 окт): пул уже упорядочен моделью — трек (где лежит исходник),
  -- исходный сэмпл, под ним его слайсы; заголовок при смене трека корня
  local cur_home
  for i, e in ipairs(pool) do
    if (e.depth or 0) == 0 and e.home ~= cur_home then
      cur_home = e.home
      rows[#rows + 1] = { hdr = e.home or '?', name = e.home }
    end
    if not e.parent then rows[#rows + 1] = { i = i } end    -- слайсы вложены в исходник (3 окт)
  end
  return add_empty(rows, pool)
end

-- пианинка (4 окт, слой пианино m): полторы октавы верхнего ряда клавиатуры —
-- белые q w e r t y u i o p (C..E), чёрные 2 3 5 6 7 9 0; на клавишах буквы,
-- держимые — янтарём, последняя сыгранная — тускло; слева октава.
-- p = { octave, held = { [смещение] = true }, last = смещение }
D.PIANO_WHITE = { { 0, 'q' }, { 2, 'w' }, { 4, 'e' }, { 5, 'r' }, { 7, 't' }, { 9, 'y' }, { 11, 'u' }, { 12, 'i' }, { 14, 'o' }, { 16, 'p' } }
D.PIANO_BLACK = { { 1, '2', 1 }, { 3, '3', 2 }, { 6, '5', 4 }, { 8, '6', 5 }, { 10, '7', 6 }, { 13, '9', 8 }, { 15, '0', 9 } }   -- [3] — после какой белой
-- транспорт (5 окт, из главного модуля): две строки ячеек { id, текст, цвет };
-- транспорт блоками (5 окт): сетка | шаг | переключатели; в блоке — две
-- строки ячеек { id, текст, цвет }; id — те же, что у главного модуля
-- (клик / колесо — ctrl_action). Время и BPM — свой крупный блок слева
-- луп: в TTF-шрифте — символ ∞ (в нём он есть), в битмапе — слово loop (5 окт)
function D.transport_buttons(c)
  -- маленькие кнопки символами ASCII (5 окт): единственное исключение из
  -- правила «словами» — << > || o >> loop; play — и stop (зелёная, пока играет)
  local ps = c.playstate or 0
  local playing = ps & 1 == 1
  -- 5 окт: без опции «I really want to have transport buttons» — только [rec] и [loop]
  if not c.tpbuttons then
    return { { 'rec', 'rec', c.recording and U.RED or nil, U.RED }, { 'loop', D.ttf and '∞' or 'loop', c.loop and U.CYAN or nil } }
  end
  return { { 'tp_rew', '<<' }, { 'tp_play', '>', playing and U.GREEN or nil },
           { 'tp_pause', '||', ps & 2 == 2 and U.AMBER or nil }, { 'rec', 'o', c.recording and U.RED or nil, U.RED },
           { 'tp_fwd', '>>' }, { 'loop', D.ttf and '∞' or 'loop', c.loop and U.CYAN or nil } }
end
function D.transport_groups(c)
  local sig = (c.sig_num and c.sig_den) and ('%d/%d'):format(c.sig_num, c.sig_den) or '4/4'
  local num = math.max(1, math.min(16, c.sig_num or 4))
  local cur = c.beat and (math.floor(c.beat) + 1) or 0
  local function tg(id, label, on) return { id, label .. ' ' .. (on and 'on' or 'off'), on and U.CYAN or U.GREY } end
  local g = {}
  if not c.bigbpm then
    g[#g + 1] = { { { 'play', '> ' .. (c.pos or ''), c.playing and U.GREEN or U.TEXT } },   -- > — намёк: клик играет (5 окт)
                  { { 'bpm', c.bpm_edit and ('BPM [%s]'):format(c.bpm_edit ~= '' and c.bpm_edit or '...') or ('BPM %.1f'):format(c.bpm or 0), c.bpm_edit and U.AMBER or U.TEXT } } }
  end
  -- metro — рядом с долями (визуальный метроном), в свободном месте строки LPB (5 окт)
  g[#g + 1] = { { { 'lpb', ('LPB %d'):format(c.lpb or 0) }, { 'sig', 'sig ' .. sig }, tg('metro', 'metro', c.metro) },
                { { 'beats', ('bar %d beat %d/%d'):format(c.bar or 1, math.max(1, cur), num), U.TEXT, beats = { num = num, cur = cur } } } }
  g[#g + 1] = { { { 'step', 'step ' .. tostring(c.step or 0) }, { 'inst', ('inst %d'):format(c.inst or 0) } },
                { { 'vel', ('vel %d'):format(c.vel or 100) }, { 'pitch', 'pitch ' .. (c.pitchmode or 'shift') } } }
  -- запись (5 окт): рядом с метрономом
  -- транспорт и запись (5 окт): кнопки [<<][>][II][o][>>], под ними метроном,
  -- punch, pre-roll, rec>lib
  -- кнопки [<<][>][II][o][>>] — крупно справа от модуса (D.transport_buttons)
  g[#g + 1] = { { tg('punch', 'punch', c.punch), tg('preroll', 'pre-roll', c.preroll) },
                { tg('reclib', 'rec>lib', c.reclib) } }
  g[#g + 1] = { { tg('follow', 'follow', c.follow) },
                { tg('lock', 'lock', c.lock), tg('fixed', 'fixed', c.fixed),
                  { 'xfade', c.xfade and ('auto x-fade %dms'):format(c.xfade_ms or 10) or 'auto x-fade off', c.xfade and U.CYAN or U.GREY } } }
  return g
end

-- полоса под трекером: слева клавиатура (m прячет), в остальном месте по
-- центру — транспорт двумя строками (BPM крупно — опция big BPM), статус —
-- третьей строкой (status bar: keyboard). p — клавиатура или nil
-- подсказки под полосой транспорта (5 окт): каждая — под своим элементом.
-- D.strip_cols = { { x0, x1, { {клавиша, что}, … } }, … } собирает piano_strip,
-- рисует D.strip_hints в строке подсказок трекера
D.strip_cols = {}
D.strip_cell = {}
local STRIP_HINTS = {
  play = { { 'dblclick', 'type BPM' } },
  lpb = { { 'wheel', 'LPB' }, { 'click', 'sig' } },
  step = { { 'wheel', 'value' }, { 'c C', 'vel' } },
  punch = { { 'click', 'toggle' }, { 'Opt+R', 'rec' } },
  follow = { { 'F', 'follow' }, { 'click', 'toggle' } },
}
function D.strip_hints(L, x, y, w, active)
  local cols = D.strip_cols
  if not cols or #cols == 0 or not L.hint_h or L.hint_h <= 0 then return false end
  set(U.PANEL); gfx.rect(x, y, w, L.hint_h, 1)
  set(U.LINE); gfx.rect(x, y, w, 1, 1)
  local sp = math.max(L.pad, ms(' '))
  for _, cl in ipairs(cols) do
    local cx, x1 = math.max(x + L.pad, cl[1]), math.min(x + w - L.pad, cl[2])
    for _, it in ipairs(cl[3]) do
      local kw, dw = ms(it[1]), ms(it[2])
      if cx + kw + sp + dw > x1 then break end
      text(cx, y + 1, it[1], active and U.AMBER or U.GREY)
      text(cx + kw + sp, y + 1, it[2], active and U.TEXT or U.mix(U.GREY, U.PANEL, 0.25))
      cx = cx + kw + sp + dw + 2 * sp
    end
  end
  return true
end
function D.piano_strip(L, x, y, w, h, p, info, hover, st)
  local out = { white = 0, black = 0, letters = 0 }
  D.strip_cols = {}
  local mx, my = gfx.mouse_x, gfx.mouse_y
  set(U.PANEL); gfx.rect(x, y, w, h, 1)
  set(D.SEP); gfx.rect(x, y, w, 1, 1)
  local ly = y + 3
  local x_all, w_all = x, w
  -- big status (5 окт): левая треть — режим крупно (две строки высотой),
  -- клавиатура и транспорт — правее; мелкий статус — строкой под ними
  local cc = info and info.ctrl or {}
  -- big status ОТКЛЮЧЁН (5 окт): не хватало места остальному транспорту; код оставлен
  --[==[
  if cc.bigstatus and st and w > 60 * L.cw then
    -- ширина — по тексту (5 окт: треть была многовато), не больше трети;
    -- INSERT — красным
    local s = ((st[1] or ''):match('^[^|]*') or ''):gsub('%-%-', ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' ')
    local room = math.floor(w / 3) - 3 * L.pad
    while s ~= '' and D.big_measure(s, 2) > room do s = s:sub(1, -2) end
    local third = (s ~= '' and D.big_measure(s, 2) or 0) + 3 * L.pad
    local ins = info and info.vmode == 'insert'
    if s ~= '' then D.big_text(x + L.pad, ly, s, ins and U.RED or U.AMBER, 2) end
    set(U.mix(U.LINE, U.PANEL, 0.5)); gfx.rect(x + third - L.pad, ly + 1, 1, 2 * L.rh - 2, 1)
    x, w = x + third, w - third
    st.big = true
  end
  --]==]
  local tx = x + L.pad
  if p then
    local dim = p.active == false
    local lbl = ('oct %d'):format(p.octave or 4)
    local zx = 'z- x+'
    local lw = math.max(ms(lbl), ms(zx)) + 2 * L.pad
    text(x + L.pad, ly, lbl, dim and U.GREY or U.AMBER)
    text(x + L.pad, ly + L.rh, zx, U.GREY)
    local kx = x + lw
    local kw = math.floor(math.min(4 * L.cw, (w - lw - L.pad) / 22))       -- клавиатуре — до ~половины полосы
    if kw >= 4 then
      local ky, kh = y + 2, 2 * L.rh + 3
      local letters = kw >= ms('W') + 4
      local held, last = p.held or {}, p.last
      local white_c = U.mix(U.BG, U.TEXT, dim and 0.35 or 0.85)
      local function key_fill(off, base)
        if held[off] then return U.tint(U.AMBER, 0.75) end
        if off == last then return U.mix(base, U.AMBER, 0.35) end
        return base
      end
      for i, k in ipairs(D.PIANO_WHITE) do
        local bx = kx + (i - 1) * kw
        set(key_fill(k[1], white_c)); gfx.rect(bx, ky, kw - 1, kh, 1)
        set(U.LINE); gfx.rect(bx, ky, kw - 1, kh, 0)
        out.white = out.white + 1
        if letters then
          -- тёмная буква на светлой клавише — с подложкой цвета клавиши (5 окт): без
          -- неё картинка текста ×2 складывается с фоном, и тёмное пропадало
          local kf = key_fill(k[1], white_c)
          local lb = D.key_label and D.key_label(k[2]) or k[2]               -- русская раскладка — кириллицей (5 окт)
          text(bx + math.floor((kw - 1 - ms(lb)) / 2), ky + kh - L.rh, lb, U.readable(U.BG, kf, dim and 3.0 or 4.5), kf)
          out.letters = out.letters + 1
        end
      end
      local bw, bh = math.max(3, math.floor(kw * 0.6)), math.floor(kh * 0.6)
      for _, k in ipairs(D.PIANO_BLACK) do
        local bx = kx + k[3] * kw - math.floor(bw / 2) - 1
        local fill = key_fill(k[1], U.PANEL)
        set(fill); gfx.rect(bx, ky, bw, bh, 1)
        set(U.LINE); gfx.rect(bx, ky, bw, bh, 0)
        out.black = out.black + 1
        if letters and bw >= ms('W') + 2 then
          text(bx + math.floor((bw - ms(k[2])) / 2), ky + 1, k[2], U.readable(U.TEXT, fill, 4.5))
          out.letters = out.letters + 1
        end
      end
      tx = kx + #D.PIANO_WHITE * kw + 2 * L.pad
      D.strip_cols[#D.strip_cols + 1] = { x + L.pad, tx - L.pad, (p.ins and { { 'q2w3e', 'notes' }, { 'z x', 'oct' } }) or { { 'z x', 'oct' }, { 'm', 'keys' } } }
    end
  end
  -- полоса транспорта (5 окт): от детального к общему — клавиатура, шаг
  -- (step / inst / vel / pitch), кнопки транспорта, время и BPM, LPB / sig /
  -- доли / metro, запись; тоглы — у самого правого края. Блоки слева
  -- направо, что не влезло — не рисуется (без наложений)
  local tw = x + w - L.pad - tx
  if tw <= 0 or not info then return out end
  local c = info.ctrl or {}
  local function cell_hot(cx, cy, cw, ch) return mx >= cx and mx < cx + cw and my >= cy and my < cy + ch end
  local gap, sep = 2 * L.pad, 3 * L.pad
  local function cw_of(it) return ms(it[2]) + (it.beats and (it.beats.num * (math.max(4, L.rh - 6) + 2) + L.pad) or 0) end
  local function group_w(g)
    local gw = 0
    for _, row in ipairs(g) do
      local rw = 0
      for k, it in ipairs(row) do rw = rw + cw_of(it) + (k > 1 and gap or 0) end
      gw = math.max(gw, rw)
    end
    return gw
  end
  local function draw_group(g, gx, gw)
    for ri, row in ipairs(g) do
      local cx, cy = gx, ly + (ri - 1) * L.rh
      for _, it in ipairs(row) do
        local iw = cw_of(it)
        local hot = cell_hot(cx, cy, iw, L.rh)
        if hot then set(D.CURROW); gfx.rect(cx - 2, cy, iw + 4, L.rh, 1); hover.ctrl = it[1] end
        text(cx, cy + 1, it[2], hot and U.AMBER or (it[3] or U.TEXT))
        if it.beats then
          local bs = math.max(4, L.rh - 6)
          local bx = cx + ms(it[2]) + L.pad
          for k = 1, it.beats.num do
            set(k == it.beats.cur and U.AMBER or U.DIM)
            gfx.rect(bx + (k - 1) * (bs + 2), cy + math.floor((L.rh - bs) / 2), bs, bs, k == it.beats.cur and 1 or 0)
          end
        end
        hint('ctrl', cx, cy, iw, L.rh, it[1])
        D.strip_cell[it[1]] = { cx, cy, iw }          -- всплывашка у своей ячейки (:sig, 5 окт)
        cx = cx + iw + gap
      end
    end
    local first = g[1] and g[1][1] and g[1][1][1]
    if STRIP_HINTS[first] then D.strip_cols[#D.strip_cols + 1] = { gx, gx + math.max(gw, sep), STRIP_HINTS[first] } end
  end
  -- кнопки транспорта: << > || o >> loop — ×2 (5 окт), чётко: битмап целым
  -- масштабом без сглаживания (big_text); плотно, зазор 2 px
  local blist = D.transport_buttons(c)
  local bws, tws, btot = {}, {}, 0
  local bk = c.tpbuttons and 2 or 1                     -- полный набор — крупно (×1.5, 6 окт); rec / loop — обычного размера
  local BK = D.ttf and 1.5 or 1.5
  for i, b in ipairs(blist) do tws[i] = bk == 2 and D.big_measure(b[2], BK) or ms(b[2]); bws[i] = tws[i] + 2 * L.pad + (b[1] == 'rec' and 3 * L.pad or 0); btot = btot + bws[i] + (i > 1 and 2 or 0) end
  local function draw_buttons(bx0)
    -- крупные (5 окт, правка): кнопка на всю высоту полосы (+2 px сверху и снизу),
    -- символ ниже прежнего — по центру чернил; TTF — кегль ×1.7 (чуть мельче)
    local bx, by, bh = bx0, (bk == 2) and (ly - 2) or (ly + math.floor(L.rh / 2)), (bk == 2) and (2 * L.rh + 4) or L.rh
    local ty = by + math.max(1, math.floor((bh - BK * L.th) / 2)) - (D.SPACE or 0)
    -- скруглённый угол (5 окт: «ещё чуть подрезать»): срезать треугольник
    -- i + j < R - 1 и провести рамку по диагонали i + j = R - 1
    local R = 4
    local function round_corner(cx, cy, dx, dy, frame)
      set(U.PANEL)
      for i = 0, R - 2 do for j = 0, R - 2 - i do gfx.rect(cx + dx * i, cy + dy * j, 1, 1, 1) end end
      set(frame)
      for i = 0, R - 1 do gfx.rect(cx + dx * i, cy + dy * (R - 1 - i), 1, 1, 1) end
    end
    for i, b in ipairs(blist) do
      local bw = bws[i]
      local hot = mx >= bx and mx < bx + bw and my >= by and my < by + bh
      local on = b[3] ~= nil
      set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(b[3], 0.3) or U.BG)); gfx.rect(bx, by, bw, bh, 1)
      set(hot and U.AMBER or (on and b[3] or U.LINE)); gfx.rect(bx, by, bw, bh, 0)
      local frame = hot and U.AMBER or (on and b[3] or U.LINE)
      if i == 1 then round_corner(bx, by, 1, 1, frame); round_corner(bx, by + bh - 1, 1, -1, frame) end
      if i == #blist then round_corner(bx + bw - 1, by, -1, 1, frame); round_corner(bx + bw - 1, by + bh - 1, -1, -1, frame) end
      if bk == 2 then D.big_text(bx + math.floor((bw - tws[i]) / 2), ty, b[2], hot and U.AMBER or (b[4] or b[3] or U.TEXT), BK)   -- b[4]: свой цвет (o — красная)
      else text(bx + math.floor((bw - tws[i]) / 2), by + 1, b[2], hot and U.AMBER or (b[4] or b[3] or U.TEXT)) end
      if hot then hover.ctrl = b[1] end
      hint('ctrl', bx, by, bw, bh, b[1])
      bx = bx + bw + 2
    end
    D.strip_cols[#D.strip_cols + 1] = { bx0, bx0 + math.max(btot, sep), { { 'Space', 'play' }, { 'Opt+R', 'rec' } } }
  end
  -- время и BPM крупно (опция big time and BPM)
  local big = c.bigbpm and {
    { 'play', '> ' .. (c.pos or ''), c.playing and U.GREEN or U.TEXT },
    { 'bpm', c.bpm_edit and (c.bpm_edit ~= '' and c.bpm_edit or '...') or ('%.1f BPM'):format(c.bpm or 0), c.bpm_edit and U.AMBER or U.TEXT },
  } or nil
  local bigw = 0
  if big then for i, b in ipairs(big) do b.w = D.big_measure(b[2], 2); bigw = bigw + b.w + (i > 1 and 3 * L.pad or 0) end end
  local function draw_big(bx)
    for _, b in ipairs(big) do
      local hot = cell_hot(bx, ly, b.w, 2 * L.rh)
      D.big_text(bx, ly, b[2], hot and U.AMBER or b[3], 2)
      if hot then hover.ctrl = b[1] end
      hint('ctrl', bx, ly, b.w, 2 * L.rh, b[1])
      bx = bx + b.w + 3 * L.pad
    end
  end
  -- порядок блоков
  local by_id = {}
  for _, g in ipairs(D.transport_groups(c)) do by_id[g[1][1][1]] = g end
  local order = {}
  local function addg(id) if by_id[id] then order[#order + 1] = { w = group_w(by_id[id]), draw = function(gx, gw) draw_group(by_id[id], gx, gw) end } end end
  addg('step')
  order[#order + 1] = { w = btot, draw = draw_buttons }
  if big then order[#order + 1] = { w = bigw, draw = draw_big } else addg('play') end
  addg('lpb'); addg('punch')
  local last = nil                -- тоглы (follow / lock / fixed / x-fade) — в главном модуле (5 окт)
  local right = x + w - L.pad
  local limit = right - (last and (last.w + sep) or 0)
  local cx = tx
  local function divider(at) set(U.mix(U.LINE, U.PANEL, 0.5)); gfx.rect(at, ly + 1, 1, 2 * L.rh - 2, 1) end
  for i, b in ipairs(order) do
    local start = cx + (i > 1 and sep or 0)
    if start + b.w > limit then break end
    if i > 1 then divider(cx + math.floor(sep / 2) - 1) end
    b.draw(start, b.w)
    cx = start + b.w
  end
  -- тоглы — у правого края
  if last and right - last.w >= cx + sep then
    local lx = right - last.w
    divider(lx - math.floor(sep / 2) - 1)
    last.draw(lx, last.w)
  end
  -- статус третьей строкой (опция status bar: keyboard)
  if st and st.big then
    -- big status: режим уже крупно слева — здесь только мелкое, во всю ширину
    if st.small and st[2] ~= '' then text(x_all + L.pad, ly + 2 * L.rh, fit(st[2], w_all - 2 * L.pad), U.TEXT) end
  elseif st and st.small ~= false then
    local sy = ly + 2 * L.rh
    local sx0 = x + L.pad
    local sw = x + w - L.pad - sx0
    local left = fit(st[1], math.floor(sw / 3))
    text(sx0, sy, left, (p and p.ins) and D.FOCUS_INS or U.AMBER)
    local dx = sx0 + (left ~= '' and (ms(left) + 3 * L.pad) or 0)
    if st[2] ~= '' and dx < sx0 + sw then text(dx, sy, fit(st[2], sx0 + sw - dx), U.TEXT) end
  end
  return out
end

-- тонкий вертикальный скролл-бар списка (4 окт): матрица, lib, браузер.
-- key — чей; scroll / nvis / total — строки; рисуется, только если не всё
-- влезло. D.vbars[key] — прямоугольник для мыши (main: клик / протяжка)
D.vbars = {}
function D.vbar(key, x, y, w, h, scroll, nvis, total)
  D.vbars[key] = nil
  if total <= nvis or h < 8 then return end
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local th = math.max(6, math.floor(h * nvis / total))
  local ty = y + math.floor((h - th) * math.min(1, scroll / math.max(1, total - nvis)))
  local hot = mx >= x - 3 and mx < x + w + 3 and my >= y and my < y + h
  local drag = D.vbar_drag and D.vbar_drag.key == key
  set(U.DIM); gfx.rect(x + math.floor(w / 2), y, 1, h, 1)
  set((hot or drag) and U.AMBER or U.LINE); gfx.rect(x, ty, w, th, 1)
  D.vbars[key] = { x = x, y = y, w = w, h = h, nvis = nvis, total = total, hot = hot, ty = ty, th = th, a0 = y, alen = h }
end
-- горизонтальная полоса (5 окт, матрица): та же запись, ось x
function D.hbar(key, x, y, w, h, scroll, nvis, total)
  D.vbars[key] = nil
  if total <= nvis or w < 8 then return end
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local tw = math.max(6, math.floor(w * nvis / total))
  local tx = x + math.floor((w - tw) * math.min(1, scroll / math.max(1, total - nvis)))
  local hot = mx >= x and mx < x + w and my >= y - 3 and my < y + h + 3
  local drag = D.vbar_drag and D.vbar_drag.key == key
  set(U.DIM); gfx.rect(x, y + math.floor(h / 2), w, 1, 1)
  set((hot or drag) and U.AMBER or U.LINE); gfx.rect(tx, y, tw, h, 1)
  D.vbars[key] = { horiz = true, x = x, y = y, w = w, h = h, nvis = nvis, total = total, hot = hot, ty = tx, th = tw, a0 = x, alen = w }
end

D.pool_scroll = 0
D.pool_dbg = ''
function D.draw_instruments(L, info, ix, iy, w, H, hover)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  set(U.PANEL); gfx.rect(ix, iy, w, H, 1)
  set(D.SEP); gfx.rect(ix - 2, iy, D.SEPW, H, 1)
  L.inst_rect = { ix, iy, w, H - 2 }
  local col = info.pool_col
  local pool = col and col.pool or {}
  local inst = info.inst or 1
  local cur = pool[inst]
  local nroots = 0
  for _, e in ipairs(pool) do if not e.parent then nroots = nroots + 1 end end
  local head = ('lib %d'):format(nroots)                -- слайсы не считаются (вложены)
  if cur and cur.tracks and #cur.tracks > 0 then head = head .. '  @ ' .. table.concat(cur.tracks, ', ') end
  -- справа налево: sort (track / len / mark), find (fzf, 2 окт), bsync (3 окт);
  -- у каждой своя x (раньше sort рисовалась поверх find — от неё торчало «d»)
  local sort = info.poolsort or 'track'
  local by0 = iy + 2
  local function hbtn(x, bw, lbl, on, onc, key)
    local hot = mx >= x and mx < x + bw and my >= by0 and my < by0 + L.rh
    set(on and U.tint(onc, 0.25) or (hot and D.CURROW or U.BG)); gfx.rect(x, by0, bw, L.rh, 1)
    set(on and onc or U.LINE); gfx.rect(x, by0, bw, L.rh, 0)
    text(x + L.pad, iy + 3, lbl, on and onc or (hot and U.TEXT or U.GREY))
    if hot then hover[key] = true end
    hint(key, x, by0, bw, L.rh, true)
  end
  -- сортировка — строкой заголовков колонок под шапкой (3 окт), не кнопкой
  local sbx = ix + w - L.pad
  local fw = ms('find') + 2 * L.pad
  local fx = sbx - fw - L.pad
  hbtn(fx, fw, 'find', false, U.GREY, 'poolfind')
  -- save (4 окт): набор lib — шаблон трека REAPER (jf_kits)
  local svw = ms('save') + 2 * L.pad
  fx = fx - svw - L.pad
  hbtn(fx, svw, 'save', false, U.GREY, 'poolsave')
  -- bsync: beatsync выбранного инструмента — длина под N долей темпа в месте
  -- каждой ноты; горит, когда включён
  local on = cur and cur.bsync
  local blbl = on and ('bsync %d'):format(on) or 'bsync'
  local bw2 = ms(blbl) + 2 * L.pad
  local bx2 = fx - bw2 - L.pad
  hbtn(bx2, bw2, blbl, on and true or false, U.CYAN, 'poolbsync')
  sbx = bx2                                  -- заголовок обрезается до кнопок
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
    tbtn('preview', info.poolprev, 'prevbtn')
    tbtn('insert', info.inspreview, 'insprevbtn')
    -- swap (3 окт): звук инструмента ↔ файл, выбранный в браузере; горит — подменён
    if info.swap_state then tbtn('swap', info.swap_state() == 'on', 'swapbtn') end
  end
  local rows = D.pool_rows(pool, sort, col, info.cols)
  rows[#rows + 1] = { auto = true }               -- automation как инструмент — последней строкой (5 окт)
  L.pool_rows = rows
  local nvis = math.max(1, math.floor((H - 3 * L.rh - 6) / L.rh))
  -- прокрутка: выбранный инструмент (и его заголовок группы) в окне
  local sel_r = 1
  for r, row in ipairs(rows) do if (not info.auto_inst and (row.i == inst or row.empty == inst or (cur and cur.parent and pool[row.i or 0] == cur.parent))) or (info.auto_inst and row.auto) then sel_r = r end end
  local hdr_r = sel_r
  while hdr_r > 1 and not rows[hdr_r].hdr do hdr_r = hdr_r - 1 end
  -- за курсором — только когда он сдвинулся (4 окт): полосой / колесом можно листать
  if D.pool_last_sel ~= sel_r then
    D.pool_last_sel = sel_r
    if sel_r > D.pool_scroll + nvis then D.pool_scroll = sel_r - nvis end
    if hdr_r <= D.pool_scroll then D.pool_scroll = hdr_r - 1 end
  end
  if D.pool_scroll > math.max(0, #rows - nvis) then D.pool_scroll = math.max(0, #rows - nvis) end
  if D.pool_scroll < 0 then D.pool_scroll = 0 end
  local label_w = math.min(L.cw * 18, math.floor(w * 0.55))
  -- заголовки колонок (3 окт): # (порядок: дерево треков / метки), name, len,
  -- preview; клик — сортировка, активная — янтарём
  do
    local hy2 = iy + 2 + L.rh
    local cols_h = { { '#', ix + 6, sort == 'track' or sort == 'mark', sort == 'mark' and '#@' or '#', 'index' },
                     { 'name', ix + 6 + ms('00 @ '), sort == 'name', 'name', 'name' },
                     { 'len', ix + 6 + label_w + L.pad, sort == 'len', 'len', 'len' },
                     { 'preview', ix + 6 + label_w + L.pad + ms('88.88s') + L.pad, false, 'preview', nil } }
    for k, h2 in ipairs(cols_h) do
      local x1 = cols_h[k + 1] and cols_h[k + 1][2] or (ix + w - L.pad)
      if h2[2] + ms(h2[4]) <= x1 then
        local hot = h2[5] and mx >= h2[2] and mx < x1 and my >= hy2 and my < hy2 + L.rh
        text(h2[2], hy2, h2[4], h2[3] and U.AMBER or (hot and U.TEXT or U.GREY))
        if hot then hover.poolsortcol = h2[5] end
        if h2[5] then hint('poolsortcol', h2[2], hy2, x1 - h2[2], L.rh, h2[5]) end
      end
    end
    set(U.DIM); gfx.rect(ix + 2, hy2 + L.rh - 1, w - 4, 1, 1)
  end
  -- цвет трека по имени — запасной цвет волны, когда у item нет своего
  local trgb = {}
  for _, c in ipairs(info.cols or {}) do if c.rgb and not trgb[c.name] then trgb[c.name] = c.rgb end end
  local dbg = {}
  -- перестановка протяжкой (3 окт): цель — перед исходником строки под мышью
  -- (нижняя половина строки — перед следующим), линия вставки янтарём
  local drag = D.lib_drag and D.lib_drag.active
  D.lib_drop = nil
  local drop_y
  for r = D.pool_scroll + 1, math.min(#rows, D.pool_scroll + nvis) do
    local row = rows[r]
    local y = iy + 2 + 2 * L.rh + (r - D.pool_scroll - 1) * L.rh
    if row.hdr then
      local hrgb = trgb[row.name] or U.LINE
      set(hrgb); gfx.rect(ix + 2, y + 1, 2, L.rh - 2, 1)
      local tw = ms(row.hdr)
      text(ix + 6, y + 1, fit(row.hdr, w - 12), U.TEXT)
      -- разделитель: длинная линия после имени
      set(U.LINE); gfx.rect(ix + 6 + tw + L.pad, y + math.floor(L.rh / 2), w - 8 - tw - 2 * L.pad, 1, 1)
    elseif row.auto then
      local sel = info.auto_inst
      local hot = mx >= ix and mx < ix + w and my >= y and my < y + L.rh
      if sel then set(U.tint(U.AMBER, 0.30)); gfx.rect(ix + 1, y, w - 2, L.rh, 1) end
      text(ix + 6, y + 1, fit('~~ automation' .. (info.auto_n and (' /' .. info.auto_n) or ''), w - 12), sel and U.AMBER or U.GREY)
      if hot then hover.pool = { ci = info.pool_ci, auto = true } end
      hint('pool', ix + 2, y, w - 4, L.rh, 'auto')
    elseif row.empty then
      -- пустой слот: номер и «..»; выбранный — подсветка, бросок сюда — в библиотеку трека
      local sel = row.empty == inst
      local hot = mx >= ix and mx < ix + w and my >= y and my < y + L.rh
      if sel then set(U.tint(U.AMBER, 0.30)); gfx.rect(ix + 1, y, w - 2, L.rh, 1)
      elseif hot and info.dragging then set(U.tint(U.CYAN, 0.25)); gfx.rect(ix + 1, y, w - 2, L.rh, 1) end
      text(ix + 6, y + 1, ('%02d    ..'):format(row.num or row.empty), sel and U.AMBER or U.DIM)
      if hot then hover.pool = { ci = info.pool_ci, i = row.empty, empty = true } end
      hint('pool', ix + 2, y, w - 4, L.rh, row.empty)
    else
      local i = row.i
      local e = pool[i]
      local rgb = e.rgb or (e.tracks and trgb[e.tracks[1]]) or (col and col.rgb) or U.GREY
      local sel = i == inst or (cur and cur.parent == e)   -- выбран слайс — горит исходник
      local rr = info.inst_range                -- диапазон v (2 окт)
      local inr = rr and i >= rr[1] and i <= rr[2] and not sel
      local here = col and e.track_set and e.track_set[col.name]
      local lib = e.depot and not (e.tracks and e.tracks[1])
      if sel then set(U.tint(U.AMBER, 0.30)); gfx.rect(ix + 1, y, w - 2, L.rh, 1)
      elseif inr then set(U.tint(U.CYAN, 0.22)); gfx.rect(ix + 1, y, w - 2, L.rh, 1) end
      set(rgb); gfx.rect(ix + 2, y + 1, 2, L.rh - 2, 1)
      -- метки: @ трек курсора, $ нарезан; ребёнок (слайс / кусок исходника) —
      -- с отступом и sN вместо имени исходника (дерево как в Renoise, 2 окт)
      local child = (e.depth or 0) > 0
      -- меток @ / $ нет (3 окт): слайсы вложены, трек виден по цветной полоске
      local body
      if child then
        -- ветка дерева: |- у среднего ребёнка, `- у последнего (2 окт: видно, что слайс — часть сэмпла)
        -- ветки только в дереве (сортировка по трекам): в len / mark соседи — не братья
        local tree = (info.poolsort or 'track') == 'track'
        local nxt = pool[i + 1]
        local last = not (nxt and (nxt.depth or 0) > 0 and nxt.parent == e.parent)
        body = '  ' .. (tree and ((last and '`-' or '|-') .. ' ') or '') .. (e.slice_k and e.slice_k > 0 and ('s' .. e.slice_k) or 'cut')
      else body = e.name .. (e.slices and (' /' .. #e.slices) or '') end
      local lbl = ('%02d %s%s'):format(e.num or i, body, e.muted and ' (muted)' or '')
      text(ix + 6, y + 1, fit(lbl, label_w - 6), sel and U.AMBER or (e.muted and U.GREY or (here and U.TEXT or U.GREY)))
      -- длительность (3 окт): колонка перед мини-волной, место — у волны
      local dw = ms('88.88s') + L.pad
      local len = e.len or 0
      local dtxt = len < 10 and ('%.2fs'):format(len) or (len < 100 and ('%.1fs'):format(len) or ('%dm%02d'):format(len // 60, math.floor(len % 60)))
      local dx = ix + 6 + label_w + L.pad
      if w - (dx - ix) - L.pad > dw + 8 then
        text(dx + dw - L.pad - ms(dtxt), y + 1, dtxt, sel and U.AMBER or U.GREY)
      else dw = 0 end
      local wx = dx + dw
      local npix = w - (wx - ix) - L.pad
      if npix > 8 then
        local pk = get_peaks and get_peaks(e, npix)
        local cy, hh = y + L.rh / 2, L.rh / 2 - 1
        local wc = U.readable(U.mix(rgb, U.TEXT, 0.35), U.BG, 4.0)
        if e.muted then wc = U.mix(wc, U.BG, 0.45) end
        -- зона слайса (4 окт): инверсия волны — фон цвета волны, волна цвета
        -- фона, без рамок и полос
        local z, za, zb = D.lib_zone
        if z and z.root == e and (e.len or 0) > 0 then
          za = math.floor(math.max(0, z.a) / e.len * npix)
          zb = math.max(za + 1, math.floor(math.min(e.len, z.b) / e.len * npix))
          set(wc); gfx.rect(wx + za, y, zb - za, L.rh, 1)
        end
        local inv = U.BG
        set(wc)
        if pk and pk.n > 0 then
          for px = 0, npix - 1 do
            local idx = math.floor(px / npix * pk.n) + 1
            local a, b = pk.min[idx] or 0, pk.max[idx] or 0
            if b - a < 0.03 then a, b = -0.015, 0.015 end
            local inz = za and px >= za and px < zb
            if inz then set(inv) end
            gfx.line(wx + px, cy - b * hh, wx + px, cy - a * hh)
            if inz then set(wc) end
          end
        else gfx.line(wx, cy, wx + npix, cy) end
        -- слайсы вложены (3 окт): границы слайсов исходника тонкими чёрточками,
        -- (внутри инвертированной зоны не рисуются)
        if e.slices and (e.len or 0) > 0 then
          set(U.mix(wc, U.BG, 0.35))
          for _, t in ipairs(e.slices) do
            local px = wx + math.floor(t / e.len * npix)
            local inz = za and px - wx >= za and px - wx <= zb
            if px > wx and px < wx + npix and not inz then gfx.rect(px, y + 1, 1, L.rh - 2, 1) end
          end
        end
        dbg[#dbg + 1] = ('%02d wx%d n%d pk%s wc%.2f,%.2f,%.2f'):format(i, wx, npix, pk and pk.n or '-', wc[1], wc[2], wc[3])
      end
      if mx >= ix and mx < ix + w and my >= y and my < y + L.rh then hover.pool = { ci = info.pool_ci, i = i } end
      hint('pool', ix + 2, y, w - 4, L.rh, i)
      if drag and my >= y and my < y + L.rh then
        if my < y + L.rh / 2 then D.lib_drop, drop_y = { before = i }, y
        else
          local nx                                   -- следующий исходник ниже
          for r2 = r + 1, #rows do if rows[r2].i then nx = rows[r2].i; break end end
          D.lib_drop, drop_y = { before = nx }, y + L.rh
        end
      end
    end
  end
  if drop_y then set(U.AMBER); gfx.rect(ix + 2, drop_y - 1, w - 4, 2, 1) end
  D.vbar('lib', ix + w - 4, iy + 2 + 2 * L.rh, 3, nvis * L.rh, D.pool_scroll, nvis, #rows)
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
    local th
    if (L.top_y or 0) == 0 then th = draw_topbar(L, info)
    else
      -- не наверху (mid / bottom): рисуется в буфер 1020 в своих координатах и
      -- выводится на top_y; мышь и метки f на время отрисовки — со сдвигом
      local ty = L.top_y
      if D.top_buf_w ~= gfx.w or D.top_buf_h ~= L.top_h then gfx.setimgdim(1020, gfx.w, L.top_h); D.top_buf_w, D.top_buf_h = gfx.w, L.top_h end
      local dest0, my0, hint0 = gfx.dest, gfx.mouse_y, D.hint
      gfx.dest = 1020
      gfx.mouse_y = my0 - ty
      if hint0 then D.hint = function(kind, x, y, w, h, data) return hint0(kind, x, y + ty, w, h, data) end end
      local ok, res = pcall(draw_topbar, L, info)
      gfx.mouse_y, D.hint, gfx.dest = my0, hint0, dest0
      if not ok then error(res, 0) end
      th = res
      gfx.blit(1020, 1, 0, 0, 0, gfx.w, L.top_h, 0, ty, gfx.w, L.top_h)
      -- прямоугольники для фокуса и меню — в координаты окна
      if L.top_rect then L.top_rect[2] = L.top_rect[2] + ty end
      if L.ctrl_area then L.ctrl_area[2] = L.ctrl_area[2] + ty end
      if L.notes_rect then L.notes_rect[2] = L.notes_rect[2] + ty end
      if D.notes_popup and not D.notes_popup.shifted then D.notes_popup.y = D.notes_popup.y + ty; D.notes_popup.shifted = true end
      if L.inst_w > 0 and L.inst_rect then L.inst_rect[2] = L.inst_rect[2] + ty end
      for _, r in pairs(D.ctrl_rect or {}) do r[2] = r[2] + ty; r.shifted = true end
    end
    hover.scopes_on = th.scopes_on
    hover.ctrl, hover.scope, hover.pool, hover.tab, hover.mod, hover.sample, hover.prevbtn = th.ctrl, th.scope, th.pool, th.tab, th.mod, th.sample, th.prevbtn
    hover.recbtn = th.recbtn
    hover.insprevbtn = th.insprevbtn
    hover.poolfind = th.poolfind
    hover.poolsave = th.poolsave or hover.poolsave
    hover.poolsortcol = th.poolsortcol
    hover.poolbsync = th.poolbsync or hover.poolbsync
    hover.scopemode, hover.monobtn, hover.retrobtn, hover.retro = th.scopemode, th.monobtn, th.retrobtn, th.retro
    hover.mm = th.mm
    hover.midimap = th.midimap
    hover.notes = th.notes or hover.notes
    hover.zone = th.zone or hover.zone
    hover.garden = th.garden
  end

  -- заголовок
  local hy = L.header_y
  set(U.PANEL); gfx.rect(tx0, hy, W - tx0, L.header_h, 1)
  local trsel = info.trsel or {}
  for _, c in ipairs(L.cols) do
    local col = c.col
    -- фон шапки (3 окт), опция hdrfill: line — полоска цвета под именем,
    -- header — залита строка имени, full — вся шапка (ниже имени тусклее);
    -- цвет приглушён к панели, как REAPER тонирует TCP (кнопки и слайдеры
    -- читаются); выделенный в REAPER трек — чуть светлее
    local mode = state.hdrfill or 'line'                -- off — без цвета трека совсем
    local fill = col.rgb and (mode == 'header' or mode == 'full')
    local base = trsel[col.guid] and D.HDRSEL or D.HDR    -- фон TCP REAPER (выделенный — его цвет)
    local nbg = fill and U.mix(base, col.rgb, 0.30) or base
    local rbg = (fill and mode == 'full') and U.mix(base, col.rgb, 0.18) or base
    local nh = L.rh + 1                                    -- строка имени (кнопки — с hy + rh + 1)
    local hset = fill and rawset_col or set               -- цвет трека — и в mono
    hset(rbg); gfx.rect(c.x + 1, hy + nh, c.w - 1, L.header_h - 2 - nh, 1)
    hset(nbg); gfx.rect(c.x + 1, hy, c.w - 1, nh, 1)
    -- фон светлее панели: текст шапки подтянуть по контрасту (на колонку)
    local T0, G0 = U.TEXT, U.GREY
    U.TEXT, U.GREY = U.readable(T0, rbg, 4.5), U.readable(G0, rbg, 3.0)
    -- папки: вложенные треки сдвинуты и приглушены, папка помечена «+»
    local indent = (col.depth or 0) * L.cw
    local nm = (col.folder and ((state.fcollapse and state.fcollapse[col.guid]) and '> ' or '- ') or '') .. (col.name ~= '' and col.name or '-')
    -- имя трека — на всю ширину колонки (кнопки переехали строкой ниже);
    -- на светлой заливке — тёмным (контраст по яркости фона)
    local ncol = col.muted and U.GREY or ((col.depth or 0) > 0 and U.mix(U.TEXT, U.GREY, 0.4) or U.TEXT)
    ncol = U.readable(ncol, nbg, 4.5)
    if c.folded then
      -- свёрнут в полоску (4 окт): имя вертикально во всю высоту шапки
      hset(rbg); gfx.rect(c.x + 1, hy, c.w - 1, nh, 1)
      D.vtext(c.x + math.floor((c.w - L.th) / 2), hy + 2, L.header_h - 5, col.name ~= '' and col.name or '-', U.readable(ncol, rbg, 4.5), rbg, true)
    else
      text(c.x + L.pad + indent, hy + 1, fit(nm, c.w - 2 * L.pad - indent), ncol)
    end
    if col.rgb and mode == 'line' and not c.folded then rawset_col(col.rgb); gfx.rect(c.x + 1 + indent, hy + L.rh - 1, c.w - 2 - indent, 2, 1) end
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
      local labels = { { 'R', col.armed, D.ARM, 'arm' },
                       { 'I', mon > 0, U.CYAN, 'monitor', mon == 2 },
                       { 'M', col.muted, U.AMBER, 'mute' }, { 'S', col.solo, U.GREEN, 'solo' },
                       { 'trim', nenv > 0, U.CYAN or U.AMBER, 'auto' } }
      -- trim (огибающие трека, бывшая A) — справа от всех кнопок, у края шапки (3 окт)
      local trim_w = ms('trim') + 4
      local trim_x = c.x + c.w - L.pad - trim_w
      for k, b in ipairs(labels) do
        local x = bx + (k - 1) * (L.btn_w + 1)
        local bwk = L.btn_w
        if b[4] == 'auto' then x, bwk = trim_x, trim_w; if x < bx + 4 * (L.btn_w + 1) + L.pad then break end end
        if x + bwk > c.x + c.w - 1 then break end
        local on = b[2]
        local fill = on and (b[4] ~= 'auto' or env_shown) and not b[5]   -- b[5]: мониторинг «авто» — только контур
        set(fill and ((b[3] == D.ARM and D.ARM_T) or U.tint(b[3], 0.5)) or U.PANEL); gfx.rect(x, by, bwk, L.rh - 2, 1)
        set(on and b[3] or U.DIM); gfx.rect(x, by, bwk, L.rh - 2, 0)
        text(x + 2, by, b[1], on and b[3] or U.GREY)
        if mx >= x and mx < x + bwk and my >= by and my < by + L.rh then hover.btn = { col = col, what = b[4] } end
        hint('btn', x, by, bwk, L.rh, { col = col, what = b[4] })
        if b[4] == 'auto' then D.trim_at = D.trim_at or {}; D.trim_at[col.guid] = { x, by + L.rh - 1, x + bwk } end   -- меню trim под кнопкой
      end
      -- строки 3 и 4: громкость и панорама — горизонтальные слайдеры как в DSP;
      -- панорама: stereo pan (5) — pan + width, dual pan (6) — L + R в одной строке
      local live = info.trs_live
      local function slider(sx, sy, sw, frac, centered, label, val, what, in_pop, noval)
        -- узко (3 окт): дорожке меньше трёх символов — слайдер сворачивается в
        -- кнопку-букву; клик — всплывающий слайдер под ней (D.trspop), повтор — закрыть
        if not in_pop and sw - ms(label) - 2 * L.pad < ms('000') then
          local bw = math.min(sw, math.max(L.btn_w, ms(label) + 4))
          local open = D.trspop and D.trspop.guid == col.guid and D.trspop.what == what
          local off_default = centered and math.abs(frac - 0.5) > 0.003 or (not centered and math.abs(frac - 60 / 72) > 0.003)
          local hot = mx >= sx and mx < sx + bw and my >= sy and my < sy + L.rh
          set(open and U.tint(U.AMBER, 0.3) or (hot and D.CURROW or U.PANEL)); gfx.rect(sx, sy + 1, bw, L.rh - 2, 1)
          set(open and U.AMBER or U.DIM); gfx.rect(sx, sy + 1, bw, L.rh - 2, 0)
          text(sx + 2, sy, label, (open or hot) and U.AMBER or (off_default and U.TEXT or U.GREY))
          if hot then hover.trsbtn = { col = col, what = what } end
          hint('trsbtn', sx, sy, bw, L.rh, { col = col, what = what })
          if open then
            -- сам слайдер — в конце кадра поверх всего (D.late_pop)
            D.late_pop = function()
              local pw = math.min(W - 2 * L.pad, L.cw * 22 + 2 * L.pad)
              local ph = L.rh + 2 * L.pad
              local px = math.max(L.pad, math.min(W - pw - L.pad, sx))
              local py = sy + L.rh
              local inside = mx >= px and mx < px + pw and my >= py and my < py + ph
              if inside then for k in pairs(hover) do hover[k] = nil end end
              set(U.PANEL); gfx.rect(px, py, pw, ph, 1)
              set(U.AMBER); gfx.rect(px, py, pw, ph, 0)
              slider(px + L.pad, py + L.pad, pw - 2 * L.pad, frac, centered, label, val, what, true)
              if hover.trs then hover.trs.pop = true end
              if inside then hover.trspop_in = true end
            end
          end
          return
        end
        -- место под значение постоянное (3 окт): центр панорамы не съезжает,
        -- когда C становится L37 / R100; значение прижато вправо
        -- резерв по самому длинному значению этого слайдера (5 окт): громкость -00.0,
        -- панорама R100, ширина 100 — два слайдера в строке получают дорожку шире
        local vres = math.max(ms(what == 'vol' and '-00.0' or (what == 'width' and '100' or 'R100')), ms(val))
        local vw = vres + L.pad
        local lw = ms(label) + L.pad
        -- узкий трек (свёрнутый): значение не влезает — без него, не в соседа (ревью 2 окт)
        -- noval (5 окт): два слайдера в строке — без чисел, вся половина под дорожку;
        -- значение — в статусе при наведении / протяжке
        local show_val = not noval and sw >= lw + vw + L.pad + 12
        if not show_val then vw = 0 end
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
        if show_val then text(wx0 + ww + L.pad + vres - ms(val), sy, val, U.GREY) end
        if hot then hover.trs = { col = col, what = what, x0 = wx0, w = ww, sv = math.max(0, math.min(1, (mx - wx0) / math.max(1, ww))) } end
        hint('trs', wx0, sy, ww, L.rh, { col = col, what = what })
        -- слайдер под клавиатурой (метка f, 5 окт): янтарная рамка
        local ks = info.kslider
        if ks and ks.what == what and ks.col and ks.col.guid == col.guid then set(U.AMBER); gfx.rect(wx0 - 2, sy + 1, ww + 4, L.rh - 2, 0) end
      end
      local function db_of(v) return v > 1e-6 and 20 * math.log(v, 10) or -150 end
      local function pan_txt(p) if math.abs(p) < 0.005 then return 'C' end; return (p < 0 and 'L' or 'R') .. math.floor(math.abs(p) * 100 + 0.5) end
      -- громкость — своя строка на всю ширину; панорама — своя строка ниже
      -- (stereo pan — p + w, dual — L + R), 2 окт
      local sx, sw = c.x + L.pad + indent, c.w - 2 * L.pad - indent
      local vol = (live and live.guid == col.guid and live.what == 'vol') and live.v or (col.vol or 1)
      local db = db_of(vol)
      local function lv(what, v) return (live and live.guid == col.guid and live.what == what) and live.v or v end
      slider(sx, hy + 2 * L.rh + 1, sw, (math.max(-60, math.min(12, db)) + 60) / 72, false, 'v', db <= -60 and '-inf' or ('%+.1f'):format(db), 'vol')
      local py = hy + 3 * L.rh + 1
      local px, pw = sx, sw
      if col.panmode == 5 then
        local half = math.floor(pw / 2)
        slider(px, py, half - L.pad, (lv('pan', col.pan or 0) + 1) / 2, true, 'p', pan_txt(lv('pan', col.pan or 0)), 'pan', nil, true)
        slider(px + half, py, pw - half, (lv('width', col.width or 1) + 1) / 2, true, 'w', math.floor(lv('width', col.width or 1) * 100 + 0.5) .. '', 'width', nil, true)
      elseif col.panmode == 6 then
        local half = math.floor(pw / 2)
        slider(px, py, half - L.pad, (lv('panl', col.panL or -1) + 1) / 2, true, 'L', pan_txt(lv('panl', col.panL or -1)), 'panl', nil, true)
        slider(px + half, py, pw - half, (lv('panr', col.panR or 1) + 1) / 2, true, 'R', pan_txt(lv('panr', col.panR or 1)), 'panr', nil, true)
      else
        slider(px, py, pw, (lv('pan', col.pan or 0) + 1) / 2, true, 'p', pan_txt(lv('pan', col.pan or 0)), 'pan')
      end
      -- строка входа (3 окт): in <вход> — клик: список входов (fzf) под ней,
      -- повторный клик закрывает; smart — в DSP-модуле трека (4 окт)
      if L.hr_in > 0 and info.input_name then
        local iy = hy + 4 * L.rh + 1
        local iw = sw
        local hot = mx >= sx and mx < sx + iw and my >= iy and my < iy + L.rh
        local open = info.in_open and info.in_open(col)
        if hot or open then set(open and U.tint(U.AMBER, 0.3) or D.CURROW); gfx.rect(sx, iy, iw, L.rh - 1, 1) end
        text(sx, iy, 'i', U.GREY)
        local nm = info.input_name(col):gsub(' / in ', '/'):gsub(' / ', '/')    -- in 3 / in 4 → in 3/4
        text(sx + ms('i') + L.pad, iy, fit(nm .. ' v', iw - ms('i') - L.pad), nm == 'none' and U.GREY or ((hot or open) and U.AMBER or U.TEXT))
        D.in_at = D.in_at or {}
        D.in_at[col.guid] = { sx, iy + L.rh, sx + iw }
        if hot then hover.hdrin = { col = col, what = 'list' } end
        hint('hdrin', sx, iy, iw, L.rh, { col = col, what = 'list' })
      end
    end
    for li, ln in ipairs(c.lanes) do
      -- −+ подколонок — над нотным полем (3 окт; раньше справа в строке лейна);
      -- справа в строке последнего лейна — −+ колонок эффектов (вместо опции fx)
      local by = hy + L.lane_row * L.rh + 1
      local G1 = (L.flat[ln.f0] or {}).G or L
      local nx = ln.x + (ln.sx and ln.sx[1] or 0) + (G1.x_note or 0)
      local function pm(x0, kind, onhot)
        for k, b in ipairs({ { '-', -1 }, { '+', 1 } }) do
          local bx = x0 + (k - 1) * (L.btn_w + 2)
          local hot = mx >= bx and mx < bx + L.btn_w and my >= by and my < by + L.rh - 1
          set(hot and D.CURROW or U.PANEL); gfx.rect(bx, by, L.btn_w, L.rh - 2, 1)
          set(U.DIM); gfx.rect(bx, by, L.btn_w, L.rh - 2, 0)
          text(bx + 2, by, b[1], hot and U.AMBER or U.GREY)
          if hot then onhot(b[2]) end
          hint(kind, bx, by, L.btn_w, L.rh, kind == 'lanebtn' and { col = col, lane = ln.lane, d = b[2], n = ln.nsub } or { d = b[2] })
        end
      end
      local bw2 = 2 * L.btn_w + 2
      if col.fixed and not c.folded then
        local lname = ln.lane.name ~= '' and ln.lane.name or ('L' .. (ln.lane.idx + 1))
        text(ln.x + L.pad, hy + L.lane_row * L.rh + 2, fit(lname, nx - ln.x - 2 * L.pad), U.GREY)
      end
      if not c.folded then
        if nx + bw2 <= ln.x + ln.w then
          pm(nx, 'lanebtn', function(d) hover.lanebtn = { col = col, lane = ln.lane, d = d, n = ln.nsub } end)
        end
        local fx0 = ln.x + ln.w - bw2 - 1
        if li == #c.lanes and fx0 > nx + bw2 + L.pad then
          pm(fx0, 'fxcolbtn', function(d) hover.fxcolbtn = d end)
        end
      end
      if li > 1 then set(U.DIM); gfx.rect(ln.x - 1, hy + L.lane_row * L.rh + 1, 1, L.rh, 1) end
    end
    for _, ev in ipairs(c.envs) do
      text(ev.x + L.pad, hy + L.lane_row * L.rh + 2, fit(ev.e.name, ev.w - 2 * L.pad), env_colour(ev.e))
      -- имя огибающей — своё меню (клик: удалить кривую / очистить точки), 2 окт
      if mx >= ev.x and mx < ev.x + ev.w and my >= hy + L.lane_row * L.rh and my < hy + (L.lane_row + 1) * L.rh then hover.header_env = { e = ev.e, col = c.col } end
      hint('env', ev.x, hy + L.lane_row * L.rh, ev.w, L.rh, ev.fi)
      set(U.DIM); gfx.rect(ev.x - 1, hy + L.lane_row * L.rh + 1, 1, L.rh, 1)
    end
    -- третья строка: что делает каждая подколонка (просьба 1 окт). Подписи
    -- короче ширины поля на символ, чтобы соседние не слипались; полное
    -- описание — в статус-баре при наведении (hover.caption)
    if not c.folded and state.captions then           -- подписи колонок — опция (Options → column captions)
      local cy3 = hy + (L.lane_row + 1) * L.rh + 2
      local function cap(x, w, txt, kind)
        text(x, cy3, fit(txt, w), U.GREY)
        if mx >= x and mx < x + w + L.pad and my >= cy3 and my < cy3 + L.rh then hover.caption = kind end
      end
      for _, ln in ipairs(c.lanes) do
        for si = 1, ln.nsub do
          local sx = ln.x + (ln.sx and ln.sx[si] or (si - 1) * L.sub_w)
          local G = (L.flat[ln.f0 + si - 1] or {}).G or L
          if G.w_wave > 0 then cap(sx + G.x_wave, G.w_wave, L.wave == 'spec' and 'wav' or 'wv', 'wave') end
          cap(sx + G.x_note, L.w_note, 'nt', 'note')
          if not G.notes_only then cap(sx + G.x_vol, L.w_vol, 'vl', 'vol') end
          if not (G.narrow or G.notes_only) then
            for k = 1, L.nfx do cap(sx + L.x_fx[k], L.w_fx, 'fx' .. k, 'fx') end
            cap(sx + L.x_del, L.w_del, 'dl', 'delay')
          end
        end
      end
      for _, ev in ipairs(c.envs) do cap(ev.x + L.pad, ev.w - 2 * L.pad, 'env', 'env') end
    end
    U.TEXT, U.GREY = T0, G0
    set(U.LINE); gfx.rect(c.x, hy, 1, L.header_h, 1)
    if my >= hy and my < hy + L.header_h and mx >= c.x and mx < c.x + c.w then hover.header_col = col end
  end
  set(D.SEP); gfx.rect(tx0, hy + L.header_h - 2, W - tx0, 1, 1)
  -- уголок над номерами строк (2 окт): ряд 0 — вид all | reg (весь трек /
  -- только регион курсора), ряд 1 — номер и имя региона в его цвете, ряд 2 —
  -- /2 x2 dup одной строкой (узкие кнопки: влезают на x1..x4, проверено расчётом)
  do
    local rg = info.cur_region_full
    local bx, bw = tx0 + 1, L.label_w - 2
    local function small(x, y, label, what, on, kind)
      local w1 = ms(label) + 2
      local hot = mx >= x and mx < x + w1 and my >= y and my < y + L.rh
      set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(U.CYAN, 0.25) or U.BG)); gfx.rect(x, y, w1, L.rh, 1)
      set(hot and U.AMBER or (on and U.CYAN or U.LINE)); gfx.rect(x, y, w1, L.rh, 0)
      text(x + 1, y, label, hot and U.AMBER or (on and U.CYAN or U.TEXT))
      if hot then hover[kind] = what end
      hint(kind, x, y, w1, L.rh, what)
      return x + w1 + 2
    end
    -- ряд 0: proj | region (5 окт: было all | reg); не влезает — region → rgn
    local x0 = bx
    local lb = (ms('proj') + ms('region') + 4 * L.pad + 6 <= bw) and 'region' or 'rgn'
    x0 = small(x0, hy + 1, 'proj', 'all', not info.view_reg, 'viewbtn')
    small(x0, hy + 1, lb, 'reg', info.view_reg, 'viewbtn')
    -- ряд 1: номер + имя
    local ny = hy + 1 + L.rh
    if rg then
      local c = rg.rgb or U.LINE
      set(U.tint(c, 0.30)); gfx.rect(bx, ny, bw, L.rh, 1)
      set(c); gfx.rect(bx, ny, 3, L.rh, 1)
      -- номер региона REAPER всегда перед именем (2 окт): «1 intro», безымянный — «2»;
      -- справа cln — независимая копия паттерна (3 окт), имя — до неё
      -- справа als — связанный повтор (alias, как в Renoise), имя — до неё
      local cw1 = ms('als') + 2
      local cx = bx + bw - cw1
      text(bx + 5, ny, fit(tostring(rg.idx) .. (rg.name ~= '' and (' ' .. rg.name) or ''), cx - bx - 7), U.TEXT)
      small(cx, ny, 'als', 'alias', false, 'rgbtn')
    else
      text(bx + 5, ny, fit('no region', bw - 7), U.DIM)
    end
    -- ряд 2: /2 x2 dup
    if rg then
      local by2 = ny + L.rh
      if by2 + L.rh <= hy + (L.header_rows - 2) * L.rh + 2 then
        local x = bx
        for _, bt in ipairs({ { 'half', '/2' }, { 'double', 'x2' }, { 'clone', 'cln' } }) do
          if x + ms(bt[2]) + 2 > bx + bw then break end
          x = small(x, by2, bt[2], bt[1], false, 'rgbtn')
        end
      end
    end
  end
  -- длина региона курсора в шагах — квадрат над номерами строк: число на
  -- 2-й строке шапки, «<» «>» на 3-й (клик / колесо = ±1 шаг, ripple как :len)
  if info.cur_region then
    local rg = info.cur_region
    local s = tostring(math.max(0, math.floor((rg.r1 - rg.r0) + 0.5)))
    local bx, bw = tx0 + 1, L.label_w - 2
    local y2, y3 = hy + (L.header_rows - 2) * L.rh + 2, hy + (L.header_rows - 1) * L.rh + 2
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
  -- выделенные в REAPER треки: тело колонки чуть светлее (строки курсора и
  -- плейхеда ложатся поверх)
  for _, c in ipairs(L.cols) do
    if (info.trsel or {})[c.col.guid] then set(U.mix(U.BG, U.TEXT, 0.09)); gfx.rect(c.x + 1, L.body_y, c.w - 1, L.body_h, 1) end
  end
  -- полосы строки курсора и плейхеда — до рамок items (5 окт): item и
  -- automation item лежат поверх, сверху — только зелёная линия курсора
  for i, r in ipairs(rows) do
    local y = L.body_y + (i - 1) * L.rh
    if r.row == ph then set(D.PLAY); gfx.rect(tx0, y, W - tx0, L.rh, 1) end
    if vc and vc.row == r.row then set(state.fixed and U.mix(D.CURROW, U.TEXT, 0.12) or D.CURROW); gfx.rect(tx0, y, W - tx0, L.rh, 1) end
  end
  -- рамки items — ДО строк (5 окт): фоном, под волной и текстом; раньше
  -- рисовались последними и резали ноту, начатую посреди строки.
  -- Тонкая кайма по дробным строкам начала/конца — так item
  -- отличим от MIDI-нот внутри него. Аудио — в своей подколонке, MIDI — на
  -- всю lane. Цвет item (или трека), приглушённый; выбранный в REAPER — ярче.
  do
    local top_row = rows[1] and rows[1].row or 0
    local by0, by1 = L.body_y, L.body_y + L.nrows * L.rh
    -- вид reg: рамки только в строках региона
    if info.view_clip then
      by0 = math.max(by0, L.body_y + (info.view_clip[1] - top_row) * L.rh)
      by1 = math.min(by1, L.body_y + (info.view_clip[2] - top_row) * L.rh)
    end
    local function yr(rf) return L.body_y + math.floor((rf - top_row) * L.rh + 0.5) end
    for _, c in ipairs(L.cols) do
      if not c.folded then
        for _, ln in ipairs(c.lanes) do
          for _, it in ipairs(ln.lane.items or {}) do
            local x0, w0 = ln.x, ln.w
            local G = L
            if it.si then local f = L.flat[ln.f0 + it.si - 1]; x0, w0 = f and f.x, f and f.w; G = (f and f.G) or L end
            local y0, y1 = yr(it.r0), yr(it.r1)
            if x0 and y1 > by0 and y0 < by1 then
              -- мышь: край рамки (±3 px) — trim начала/конца, внутри — сдвиг
              if mx >= x0 and mx < x0 + w0 and my >= y0 - 3 and my <= y1 + 3 then
                local edge = (math.abs(my - y1) <= 3) and 'end' or ((math.abs(my - y0) <= 3) and 'start' or 'move')
                if not hover.itemedge or edge ~= 'move' then
                  hover.itemedge = { item = it.item, edge = edge, col = c.col, lane = ln.lane, r0 = it.r0, r1 = it.r1 }
                end
              end
              -- цвет item (опция item colours) и прозрачность заливки (item fill opacity), 3 окт
              local rgb = state.itemcol ~= false and (it.rgb or c.col.rgb) or U.GREY
              local col = it.sel and U.mix(rgb, U.TEXT, 0.3) or U.mix(rgb, U.BG, it.muted and 0.7 or 0.45)
              if D.mono then col = U.mix(col, U.TEXT, 0.35) end   -- mono: кайма светлее (была слишком тёмной)
              local cy0, cy1 = math.max(by0, y0), math.min(by1, y1)
              local fa = state.textonly and 0 or (state.itemalpha or 5) / 100
              set(rgb); gfx.a = it.sel and math.min(1, fa * 1.8 + 0.01) or fa       -- полупрозрачно: сетка видна (2 окт)
              gfx.rect(x0, cy0, w0, cy1 - cy0, 1)
              gfx.a = 1
              -- рамка (опция item frame, 3 окт): item — вокруг всего item, wave —
              -- только вокруг колонки волны (нет колонки — вокруг item), off — без
              local fr = state.textonly and 'off' or (state.itemframe or 'item')
              local fx0, fw0 = x0, w0
              if fr == 'wave' and (G.w_wave or 0) > 0 then fx0, fw0 = x0 + (G.x_wave or L.pad) - 1, G.w_wave + 2 end
              if fr ~= 'off' then
                set(col)
                gfx.rect(fx0, cy0, fw0, cy1 - cy0, 0)                         -- кайма 2 px
                gfx.rect(fx0 + 1, cy0 + 1, math.max(0, fw0 - 2), math.max(0, cy1 - cy0 - 2), 0)
                if y0 < by0 then set(U.BG); gfx.rect(fx0, by0, fw0, 2, 1) end   -- срез сверху: без верхней кромки
                if y1 > by1 then set(U.BG); gfx.rect(fx0, by1 - 2, fw0, 2, 1) end
              end
              -- стыки лупа item (2 окт): косые срезы поперёк, как у automation items
              if it.loop_rows and it.loop_rows > 1e-6 then
                set(col)
                local rr = it.r0 + (it.loop_first or it.loop_rows)
                local guard = 0
                while rr < it.r1 - 1e-6 and guard < 512 do
                  local ly = yr(rr)
                  if ly > cy0 and ly < cy1 then
                    -- шов лупа как в REAPER (5 окт): контрастная линия поперёк и
                    -- треугольные вырезы на обеих границах item, остриём внутрь
                    set(U.mix(col, U.TEXT, 0.6)); gfx.rect(x0 + 1, ly, w0 - 2, 1, 1)
                    local tz = math.max(3, math.floor(L.rh / 3))
                    gfx.triangle(x0, ly - tz, x0, ly + tz, x0 + tz, ly)
                    gfx.triangle(x0 + w0 - 1, ly - tz, x0 + w0 - 1, ly + tz, x0 + w0 - 1 - tz, ly)
                    set(col)
                    -- стык тянется: длина периода (Option — растяжение)
                    if mx >= x0 and mx < x0 + w0 and math.abs(my - ly) <= 3 then
                      hover.seam = { kind = 'item', item = it.item, k = guard + 1, midi = it.midi, x0 = x0, w = w0 }
                    end
                  end
                  rr = rr + it.loop_rows; guard = guard + 1
                end
              end
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
              -- как в аранжировке REAPER (2 окт): цвет кривой, еле заметная
              -- заливка, рамка; слева полоса потолще — ручка (тянуть = сдвиг,
              -- как шапка item в REAPER), край сверху / снизу — начало / длина;
              -- стыки лупа — срезами поперёк
              -- как в REAPER по умолчанию (6 окт): не выделен — серый (рамка и
              -- ручка с подписью), выделен — цветом огибающей
              local col = ai.sel and env_colour(ev.e) or U.mix(U.GREY, U.BG, 0.2)
              -- заливка — опцией (6 окт): по умолчанию прозрачная, как в REAPER — только рамка
              if state.aifill then
                set(col); gfx.a = ai.sel and 0.16 or 0.08
                gfx.rect(ev.x + 1, cy0, ev.w - 2, cy1 - cy0, 1)
                gfx.a = 1
              end
              set(U.mix(col, U.TEXT, ai.sel and 0.4 or 0.0)); gfx.rect(ev.x, cy0, ev.w, cy1 - cy0, 0)
              local hot = hover.aiedge and hover.aiedge.e == ev.e and hover.aiedge.idx == ai.idx
              -- ручка слева — полоса в строку текста шириной, в ней имя вертикально (2 окт)
              local sw = L.th + 4
              set(col); gfx.a = (hot and hover.aiedge.edge == 'move') and 0.85 or 0.55
              gfx.rect(ev.x, cy0, sw, cy1 - cy0, 1); gfx.a = 1
              if cy1 - cy0 > L.th * 2 and ai.label then D.vtext(ev.x + 2, cy0 + 2, cy1 - cy0 - 4, ai.label, U.BG, U.mix(col, U.BG, 0.45), true) end
              set(col)
              if y0 >= by0 then gfx.rect(ev.x, y0, ev.w, (hot and hover.aiedge.edge == 'start') and 3 or 2, 1) end
              if hot and hover.aiedge.edge == 'end' and y1 <= by1 then gfx.rect(ev.x, y1 - 2, ev.w, 3, 1) end
              if ai.loop_rows and ai.loop_rows > 0 then
                local rr = ai.loop_first or (ai.r0 + ai.loop_rows)
                local guard = 0
                while rr < ai.r1 - 1e-6 and guard < 512 do
                  local ly = yr(rr)
                  if ly > cy0 and ly < cy1 then
                    -- стык лупа (6 окт): как у обычных items — треугольные вырезы
                    -- на обеих границах, остриём внутрь (без косой палки)
                    -- как в REAPER (6 окт): вырез прозрачный — внутри фон, по краям V рамки
                    local tz = math.max(3, math.floor(L.rh / 3))
                    local fc = { gfx.r, gfx.g, gfx.b }
                    set(U.BG)
                    gfx.triangle(ev.x, ly - tz, ev.x, ly + tz, ev.x + tz, ly)
                    gfx.triangle(ev.x + ev.w - 1, ly - tz, ev.x + ev.w - 1, ly + tz, ev.x + ev.w - 1 - tz, ly)
                    gfx.set(fc[1], fc[2], fc[3], 1)
                    gfx.line(ev.x, ly - tz, ev.x + tz, ly); gfx.line(ev.x + tz, ly, ev.x, ly + tz)
                    gfx.line(ev.x + ev.w - 1, ly - tz, ev.x + ev.w - 1 - tz, ly); gfx.line(ev.x + ev.w - 1 - tz, ly, ev.x + ev.w - 1, ly + tz)
                    if mx >= ev.x and mx < ev.x + ev.w and math.abs(my - ly) <= 3 then
                      hover.seam = { kind = 'ai', env = ev.e.env, idx = ai.idx, k = guard + 1, r0 = ai.r0, per = ai.loop_rows,
                                     first = (ai.loop_first or (ai.r0 + ai.loop_rows)) - ai.r0, x0 = ev.x, w = ev.w, name = ev.e.name }
                    end
                  end
                  rr = rr + ai.loop_rows; guard = guard + 1
                end
              end
              -- мышь: ручка слева — сдвиг, край сверху — начало, снизу — длина
              if mx >= ev.x and mx < ev.x + ev.w and my >= y0 - 3 and my <= y1 + 3 then
                local edge
                if math.abs(my - y0) <= 3 then edge = 'start' elseif math.abs(my - y1) <= 3 then edge = 'end'
                elseif mx < ev.x + L.th + 4 then edge = 'move' end
                if edge then hover.aiedge = { e = ev.e, idx = ai.idx, edge = edge, pos = ai.pos, len = ai.len, col = c.col } end
              end
            end
          end
        end
      end
    end
  end
  D.vis_box = nil
  -- граница регионов (5 окт): тонкие линии цвета регионов у линии такта —
  -- уходящий над ней, следующий под ней; фоном, items рисуются поверх
  local rgedge = {}
  if info.ruler and info.ruler.regions then
    for _, rg in ipairs(info.ruler.regions) do
      local e0 = rgedge[rg.r0] or {}; e0.nxt = rg.rgb or D.BAR; rgedge[rg.r0] = e0
      local e1 = rgedge[rg.r1] or {}; e1.prv = rg.rgb or D.BAR; rgedge[rg.r1] = e1
    end
  end
  for i, r in ipairs(rows) do
    local y = L.body_y + (i - 1) * L.rh
    local ty = y + 1
    local is_cur_row = vc and vc.row == r.row
    if r.bar then set(D.BAR); gfx.rect(tx0, y, W - tx0, 1, 1)
    elseif r.beat then set(D.BEAT); gfx.rect(tx0, y, W - tx0, 1, 1) end
    -- треки с включённой записью (5 окт): чуть покрасневший фон колонки
    for _, cc in ipairs(L.cols) do
      if cc.x and cc.col and cc.col.armed then gfx.set(U.RED[1], U.RED[2], U.RED[3], 0.07); gfx.rect(cc.x, y, cc.w, L.rh, 1); gfx.a = 1 end
    end
    -- до ячеек этой строки: нижний пиксель — уходящему, верхний+1 — следующему
    local eg, en = rgedge[r.row], rgedge[r.row + 1]
    if eg and eg.prv and eg.nxt then set(eg.nxt); gfx.rect(tx0, y + 1, W - tx0, 1, 1) end
    if en and en.prv and en.nxt then set(en.prv); gfx.rect(tx0, y + L.rh - 1, W - tx0, 1, 1) end
    -- кромки: строка курсора — янтарная, edit-курсор — зелёная; опция
    -- curline (3 окт): top / bottom / off. Начинаются за разделителем матрицы;
    -- метки у номера строки нет (3 окт, просьба)
    local cl = state.curline or 'top'
    if cl ~= 'off' then
      local ly = cl == 'bottom' and (y + L.rh - 1) or y
      -- от края полос регионов / маркеров вправо (через линейку, если она
      -- включена): на сами полосы не заходит (3 окт)
      local lx = tx0 + L.ruler_w
      if is_cur_row then set(D.CURTOP); gfx.rect(lx, ly, W - lx, 1, 1) end
      if r.row == cur then set(D.EDITTOP); gfx.rect(lx, ly, W - lx, 1, 1) end
    end
    text(tx0 + L.ruler_w + L.tl_w + L.pad, ty, r.label, (is_cur_row or r.beat) and U.TEXT or U.GREY)
    -- линейка таймлайна: на долях, такт ярче (формат меток — как у линейки
    -- REAPER); слева от номеров шагов, за полосами регионов (3 окт)
    if L.tl_w > 0 and (r.beat or r.bar) and info.tl_label then
      local b, t = info.tl_label(r.row)
      local tx = tx0 + L.ruler_w + L.pad
      local tcol = r.bar and U.TEXT or U.GREY
      local tlr = state.tlruler
      if tlr == 'beats' or tlr == 'both' then text(tx, ty, b, tcol); tx = tx + ms('999.4') + L.pad end
      if tlr == 'time' or tlr == 'both' then text(tx, ty, t, tlr == 'both' and U.GREY or tcol) end
    end
    local in_body = not r.clip and my >= y and my < y + L.rh and my >= L.body_y and my < L.body_y + L.nrows * L.rh and mx < W
    if in_body then hover.row = r end
    -- номера шагов (2 окт): протяжка = time selection REAPER
    if in_body and mx >= tx0 + L.ruler_w and mx < tx0 + L.label_w then hover.rownum = r.row end
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
              -- 5 окт: полупрозрачно — рамки и цвета items под выделением видны;
              -- границу блока рисует контур после строк
              set(U.CYAN, 0.16); gfx.rect(x, y, f.w, L.rh, 1); gfx.a = 1
              local vb = D.vis_box
              if not vb then vb = {}; D.vis_box = vb end
              vb.x0 = math.min(vb.x0 or x, x); vb.x1 = math.max(vb.x1 or (x + f.w), x + f.w)
              vb.y0 = math.min(vb.y0 or y, y); vb.y1 = math.max(vb.y1 or (y + L.rh), y + L.rh)
            end
            local inv = (vc and vc.fi == fi and vc.row == r.row) and (c.folded and 1 or (vc.field or 1)) or nil
            if inv == 1 and vc.sub == 'inst' and (f.G or L).x_inst then inv = 'inst' end   -- курсор на номере инструмента
            -- ячейка курсора (4 окт): подложка — ПОВЕРХ волны ячейки, под текстом;
            -- draw_cell зовёт D.cur_box сразу после волны (волна фоном её закрашивала)
            if inv then
              D.inv_bg = info.focus == 'tracker' and D.CURCELL or U.LINE
              local G, folded, inv_f, fw0 = f.G or L, c.folded, inv, f.w
              D.cur_box = function()
                set(D.inv_bg)
                if folded then gfx.rect(x, y, fw0, L.rh, 1)
                else local fx, fw = D.field_rect(G, inv_f); gfx.rect(x + fx - 1, y, fw + 2, L.rh, 1) end
              end
              if c.folded or r.row < 0 or r.clip then D.cur_box(); D.cur_box = nil end
            end
            local cell
            if r.row < 0 or r.clip then
            elseif c.folded then draw_fold_cell(L, c.col, r.row, x, y, ty, inv ~= nil)
            else cell = f.sub[r.row]; draw_cell(f.G or L, cell, x, y, ty, inv) end
            D.cur_box = nil
            if in_body and mx >= x and mx < x + f.w then
              hover.fi = fi; hover.cell = cell; hover.col = c.col
              for fld = 1, f.compact and 1 or (f.narrow and 2 or (3 + L.nfx)) do
                local fx, fw = D.field_rect(f.G or L, fld)
                if mx >= x + fx and mx < x + fx + fw + L.pad then hover.field = fld; break end
              end
              -- номер инструмента под мышью (5 окт) — подполе ноты
              local G2 = f.G or L
              if G2.x_inst and mx >= x + G2.x_inst and mx < x + G2.x_inst + ms('00') + 2 then hover.field = 1; hover.fsub = 'inst' end
              do
              end
            end
          end
        end
      end
      for _, ev in ipairs(c.envs) do
        local EG = ev.G or L
        if r.clip then goto env_next end
        if vc and vc.fi == ev.fi and vc.row == r.row then
          set(info.focus == 'tracker' and U.AMBER or U.LINE)
          if not ((vc.field or 1) == 2 and not ev.G) then gfx.rect(ev.x, y, ev.w, L.rh, 0) end
        end
        -- курсор поля формы — под значением точки (строка ниже курсора)
        if vc and vc.fi == ev.fi and vc.row == r.row - 1 and (vc.field or 1) == 2 and not ev.G then
          set(info.focus == 'tracker' and U.AMBER or U.LINE)
          gfx.rect(ev.x + L.env_bx + L.env_bar_w + L.pad - 1, y, L.env_shape_w + 2, L.rh, 0)
        end
        draw_env_cell(EG, env_vals[ev][i], env_vals[ev][i - 1], ev.x, y, ty, ev.e, env_vals[ev][i + 1])
        if in_body and mx >= ev.x and mx < ev.x + ev.w then
          hover.col = c.col; hover.env = ev.e; hover.envv = env_vals[ev][i]; hover.fi = ev.fi
          hover.envx = math.max(0, math.min(1, (mx - ev.x - L.env_bx) / (EG.env_bar_w - 1)))
          -- поле формы — с клавиатуры (l, буквы в INSERT); мышь — всегда значение
          hover.field = 1
          -- точный клик по точке (±4 px) — её можно тянуть в любом режиме (2 окт)
          local ev0 = env_vals[ev][i]
          if ev0 and ev0.pt then
            local px = ev.x + EG.env_bx + math.floor(ev0.v * (EG.env_bar_w - 1) + 0.5)
            if math.abs(mx - px) <= 4 and math.abs(my - (y + 1)) <= 4 then hover.envpt = { e = ev.e, row = r.row } end
          end
        end
        ::env_next::
      end
    end
  end
  -- контур выделения (5 окт): видно границу блока, содержимое не закрыто
  if D.vis_box then local b = D.vis_box; set(U.CYAN); gfx.rect(b.x0, b.y0, b.x1 - b.x0, b.y1 - b.y0, 0); D.vis_box = nil end
  -- каналы при mute / solo (5 окт, как во всех трекерах; опция tint channels):
  -- заглушённые — тусклые; есть solo — тусклые все, кроме solo
  if state.tintmute ~= false then
    local any_solo = false
    for _, c in ipairs(L.cols) do if c.col and c.col.solo then any_solo = true; break end end
    for _, c in ipairs(L.cols) do
      if c.x and c.col and (c.col.muted or (any_solo and not c.col.solo)) then
        gfx.set(U.BG[1], U.BG[2], U.BG[3], 0.55); gfx.rect(c.x, L.body_y, c.w, L.body_h, 1)
        gfx.set(U.BG[1], U.BG[2], U.BG[3], 0.35); gfx.rect(c.x, L.header_y, c.w, L.body_y - L.header_y, 1)
        gfx.a = 1
      end
    end
  end


  -- направляющая тянущегося стыка лупа
  if info.seam_guide then
    local g = info.seam_guide
    set(U.CYAN); gfx.rect(g.x, g.y, g.w, 2, 1)
  end
  -- пик-метры ПОВЕРХ колонок, псевдографикой (3 окт): два столбика L R
  -- шириной в символ у левого края колонки, из клеток строк трекера (зазор 1 px,
  -- как текстовые блоки ▁▂▃▄▅▆▇█): полные клетки снизу, верхняя — восьмыми
  -- долями; зелёный / янтарный / красный по высоте, полупрозрачно — текст виден
  -- стиль pt (4 окт, как было): полупрозрачный столбик в треть колонки от
  -- низа тела до середины, сегменты зелёный / янтарный / красный
  if state.meters and info.peaks and state.meterstyle == 'pt' then
    local by = L.body_y + L.body_h
    local maxh = math.floor(L.body_h * 0.5)
    for _, c in ipairs(L.cols) do
      if c.x then
        local pl, pr = info.peaks(c.col)
        local v = math.min(1, math.max(pl or 0, pr or 0))
        if v > 0 then
          local x0, w0 = c.x + 2, math.max(2, math.floor(c.w * 0.3))
          for _, sg in ipairs({ { 0, 0.6, U.GREEN }, { 0.6, 0.85, U.AMBER }, { 0.85, 1, U.RED } }) do
            local s0, s1 = math.floor(sg[1] * maxh), math.floor(math.min(v, sg[2]) * maxh)
            if s1 > s0 then gfx.set(sg[3][1], sg[3][2], sg[3][3], 0.45); gfx.rect(x0, math.max(L.body_y, by - s1), w0, s1 - s0, 1) end
          end
        end
      end
    end
    gfx.a = 1
  elseif state.meters and info.peaks then
    local rh = L.rh
    local ncell = math.max(1, math.floor(L.nrows * 0.5))       -- до середины тела
    local by = L.body_y + L.nrows * rh
    local cwm = math.max(3, L.cw - 1)
    for _, c in ipairs(L.cols) do
      if c.x and not c.folded then
        local pl, pr = info.peaks(c.col)
        for k, v in ipairs({ pl or 0, pr or 0 }) do
          v = math.min(1, math.max(0, v))
          local eighths = math.floor(v * ncell * 8 + 0.5)
          local x0 = c.x + 2 + (k - 1) * (cwm + 1)
          local cell = 0
          while eighths > 0 and cell < ncell do
            local part = math.min(8, eighths)
            local frac = (cell + 1) / ncell
            local col = frac > 0.85 and U.RED or (frac > 0.6 and U.AMBER or U.GREEN)
            local cy1 = by - cell * rh - 1                  -- низ клетки (зазор 1 px сверху и снизу)
            local hh = math.max(1, math.floor((rh - 2) * part / 8 + 0.5))
            gfx.set(col[1], col[2], col[3], 0.5)
            gfx.rect(x0, cy1 - hh, cwm, hh, 1)
            eighths = eighths - part
            cell = cell + 1
          end
        end
      end
    end
    gfx.a = 1
  end

  -- разделители
  for _, c in ipairs(L.cols) do
    set(U.LINE); gfx.rect(c.x, L.body_y, 1, L.body_h, 1)
    for li, ln in ipairs(c.lanes) do
      if li > 1 then set(U.DIM); gfx.rect(ln.x - 1, L.body_y, 1, L.body_h, 1) end
      for si = 2, ln.nsub do set(D.EMPTY); gfx.rect(ln.x + (ln.sx and ln.sx[si] or (si - 1) * L.sub_w), L.body_y, 1, L.body_h, 1) end
    end
    for _, ev in ipairs(c.envs) do set(U.DIM); gfx.rect(ev.x - 1, L.body_y, 1, L.body_h, 1) end
  end
  -- линейка (2 окт): регионы и маркеры вертикальным текстом вдоль своих строк
  if L.ruler_w > 0 and info.ruler and #rows > 0 then
    local row0, nr = rows[1].row, #rows
    local function ry(row) return L.body_y + (row - row0) * L.rh end
    local bot = L.body_y + nr * L.rh
    local laneR, laneM = tx0 + 3, tx0 + 3 + L.th + 6       -- 2 px зазора: разделитель матрицы виден (3 окт)
    local c0 = info.view_clip and info.view_clip[1] or -math.huge
    local c1 = info.view_clip and info.view_clip[2] or math.huge
    for _, rg in ipairs(info.ruler.regions) do
      local a, b = math.max(rg.r0, row0, c0), math.min(rg.r1, row0 + nr, c1)
      if b > a then
        local y0, y1 = ry(a), ry(b)
        local c = rg.rgb or U.LINE
        local bgc = U.tint(c, 0.25)
        set(c); gfx.rect(laneR, y0, 3, y1 - y0, 1)
        set(bgc); gfx.rect(laneR + 3, y0, L.th + 2, y1 - y0, 1)
        if rg.r0 >= row0 then set(c); gfx.rect(laneR, y0, L.th + 5, 1, 1) end
        if y1 - y0 > L.th then D.vtext(laneR + 4, y0 + 2, y1 - y0 - 4, rg.name ~= '' and rg.name or ('#' .. tostring(rg.idx)), U.TEXT, bgc, true) end
      end
    end
    local mks = {}
    for _, mk in ipairs(info.ruler.markers) do
      local row = math.floor(mk.row_f + 1e-6)
      if row >= row0 and row < row0 + nr then mks[#mks + 1] = { row = row, mk = mk } end
    end
    table.sort(mks, function(p, q) return p.row < q.row end)
    for k, m in ipairs(mks) do
      local y = ry(m.row)
      local ynext = mks[k + 1] and ry(mks[k + 1].row) or bot
      local c = m.mk.rgb or U.AMBER
      set(c); gfx.rect(laneR, y, L.ruler_w - 5, 1, 1); gfx.rect(laneM, y, 2, math.max(2, ynext - y), 1)
      if ynext - y > L.th then D.vtext(laneM + 3, y + 2, ynext - y - 4, m.mk.name ~= '' and m.mk.name or tostring(m.mk.idx), c, U.BG, true) end
    end
    if mx >= tx0 and mx < tx0 + L.ruler_w and my >= L.body_y and my < bot then hover.ruler = row0 + math.floor((my - L.body_y) / L.rh) end
  end
  -- полоска цвета региона у номеров шагов (2 окт): тот же цвет, что в
  -- уголке с именем, на линейке и в матрице
  if L.ruler_w > 0 and info.ruler and #rows > 0 then
    local row0, nr = rows[1].row, #rows
    local c0 = info.view_clip and info.view_clip[1] or -math.huge
    local c1 = info.view_clip and info.view_clip[2] or math.huge
    for _, rg in ipairs(info.ruler.regions) do
      local a, b = math.max(rg.r0, row0, c0), math.min(rg.r1, row0 + nr, c1)
      if b > a and rg.rgb then
        set(rg.rgb); gfx.rect(tx0 + L.ruler_w, L.body_y + (a - row0) * L.rh, 2, (b - a) * L.rh, 1)
      end
    end
  end
  -- time selection REAPER (2 окт, правка): фон номеров шагов ярко-серый,
  -- бледная полоса по паттерну и скобка «]» у правого края линейки
  if info.timesel and #rows > 0 then
    local row0, nr = rows[1].row, #rows
    local a, b = math.max(info.timesel[1], row0, info.view_clip and info.view_clip[1] or -math.huge), math.min(info.timesel[2], row0 + nr, info.view_clip and info.view_clip[2] or math.huge)
    if b > a then
      local y0, y1 = L.body_y + (a - row0) * L.rh, L.body_y + (b - row0) * L.rh
      -- авто-панч (5 окт): та же зона красным — запись только в ней
      local grey = info.punch and U.RED or { 0.80, 0.80, 0.80 }
      set(grey)
      gfx.a = info.punch and 0.30 or 0.16; gfx.rect(tx0 + L.ruler_w + 2, y0, L.label_w - L.ruler_w - 3, y1 - y0, 1)
      gfx.a = 0.05; gfx.rect(tx0 + L.label_w, y0, W - tx0 - L.label_w, y1 - y0, 1)
      gfx.a = 1
      local sx = tx0 + L.ruler_w - 3                 -- спина скобки; усы — влево: «]»
      gfx.rect(sx, y0, 2, y1 - y0, 1)
      if info.timesel[1] >= row0 then gfx.rect(sx - 5, y0, 7, 2, 1) end
      if info.timesel[2] <= row0 + nr then gfx.rect(sx - 5, y1 - 2, 7, 2, 1) end
    end
  end
  -- линии справа от номеров шагов нет (3 окт, просьба): колонки треков начинаются со своей линии
  if tx0 > 0 then set(D.SEP); gfx.rect(tx0 - 2, hy, D.SEPW, L.body_y + L.body_h + L.low_h - hy, 1) end
  if L.total_w < W then set(U.LINE); gfx.rect(L.total_w, hy, 1, L.body_y + L.body_h - hy, 1) end

  if MX and L.matrix_w > 0 and not state.mx_hidden then
    hover.matrix = MX.draw(L, snap, info.regions or {}, { play_row = ph, cur_ci = info.cur_ci, pat_num = info.pat_num, loop_cells = info.loop_cells, loop_text = info.loop_text, region_rgb = info.region_rgb, bar_label = info.mx_bar_label, ticks = info.mx_ticks, marks = info.mx_marks,
      env_shown = function(col) local v = state.trackenvs and state.trackenvs[col.guid]; if v == nil then v = state.envs end; return v end })
  end
  -- кнопки на линии раздела матрица | трекер (2 окт): внизу < свернуть / > развернуть,
  -- над ней = — ручка ширины (тянуть, двойной клик — авто)
  if MX and L.matrix_w > 0 then
    local bot = L.body_y + L.body_h
    local bw = ms('>') + 2 * L.pad
    local lx = L.matrix_w - 1
    if state.mx_hidden then
      set(U.PANEL); gfx.rect(0, hy, L.matrix_w - 1, bot - hy, 1)
      set(D.SEP); gfx.rect(lx - 1, hy, D.SEPW, bot - hy, 1)
    end
    local function knob(y, lbl, what)
      local bx = math.max(1, lx - math.floor(bw / 2))   -- на линии модуля (4 окт), по центру
      local hot = mx >= bx and mx < bx + bw and my >= y and my < y + L.rh
      set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, y, bw, L.rh, 1)
      set(hot and U.AMBER or U.LINE); gfx.rect(bx, y, bw, L.rh, 0)
      text(bx + L.pad, y, lbl, hot and U.AMBER or U.TEXT)
      if hot then hover.mxctl = what end
      hint('mxctl', bx, y, bw, L.rh, what)
    end
    -- 4 окт: кнопок нет — тянется сама линия (подсветка под мышью),
    -- свёрнутая полоска разворачивается кликом; свернуть — быстрая кнопка matrix
    local _ = knob
    if mx >= lx - 3 and mx <= lx + 3 and my >= hy and my < bot then
      for _, k in ipairs({ 'row', 'cell', 'fi', 'col', 'field', 'browser', 'matrix', 'pool', 'rownum' }) do hover[k] = nil end; hover.mxctl = state.mx_hidden and 'open' or 'grip'
      set(U.AMBER); gfx.rect(lx - 1, hy, 2, bot - hy, 1)
    elseif state.mx_hidden and mx >= 0 and mx < lx and my >= hy and my < bot then
      hover.mxctl = 'open'
    end
  end

  if L.side_w > 0 and info.browser_draw then
    -- сайдбар во всю высоту окна: от верха до статус-бара (инструменты сверху, браузер снизу)
    local sy0 = 0
    local total = gfx.h - L.status_h - sy0
    local W = L.side_x                                -- сайдбар правее модуля слайсов (4 окт)
    set(U.PANEL); gfx.rect(W, sy0, L.side_w, total, 1)
    local ih = math.max(4 * L.rh, math.min(total - 6 * L.rh, state.inst_px or math.floor(total * 0.40)))
    L.inst_side_h = ih
    L.side_y0 = sy0
    local hh = L.hint_h or 0
    -- ручка = высоты инструментов (2 окт): справа над линией раздела — в строке
    -- подсказок (она короче на ширину ручки), без подсказок — в нижнем ряду инструментов
    local gw = ms('=') + 2 * L.pad
    L.inst_knob_w = hh > 0 and 0 or (gw + L.pad)
    -- slices = split (4 окт): нарезанный айтем — нижняя половина модуля
    -- инструментов отдаётся списку слайсов
    local ihl = ih - hh
    L.slices_split_rect = nil
    if L.slices_split and info.slices_draw and ihl > 8 * L.rh then
      local top_h = math.floor(ihl / 2)
      D.draw_instruments(L, info, L.side_x, sy0, L.side_w, top_h, hover)
      set(D.SEP); gfx.rect(L.side_x, sy0 + top_h, L.side_w, D.SEPW, 1)
      local hs = info.slices_draw(L, L.side_x + 3, sy0 + top_h + 3, L.side_w - 5, ihl - top_h - 4)
      if hs ~= nil then hover.slices = hs end
      L.slices_split_rect = { L.side_x, sy0 + top_h + 1, L.side_w, ihl - top_h - 1 }
    else
      D.draw_instruments(L, info, L.side_x, sy0, L.side_w, ih - hh, hover)
    end
    hover.browser = info.browser_draw(L, L.side_x, sy0 + ih + 2, L.side_w, total - ih - 2 - hh)
    if hh > 0 then
      D.hint_bar(L, W, sy0 + ih - hh, L.side_w - gw - 2 * L.pad, (info.hint_bars or function() end)('inst'), info.focus == 'inst')
      D.hint_bar(L, W, sy0 + total - hh, L.side_w, (info.hint_bars or function() end)('browser'), info.focus == 'browser')
    end
    -- линия раздела инструменты | браузер — той же толщины, что между модулями
    set(D.SEP); gfx.rect(W, sy0 + ih, L.side_w, D.SEPW, 1)
    -- высота инструментов (4 окт): тянется сама линия раздела, без кнопки =
    if mx >= W and mx < W + L.side_w and my >= sy0 + ih - 3 and my <= sy0 + ih + 3 then
      for _, k in ipairs({ 'row', 'cell', 'fi', 'col', 'field', 'browser', 'matrix', 'pool', 'rownum' }) do hover[k] = nil end; hover.sidectl = 'instgrip'
      set(U.AMBER); gfx.rect(W, sy0 + ih - 1, L.side_w, 2, 1)
    end
  end

  -- нижняя DSP-панель: FX трека курсора блоками, параметры мини-слайдерами
  -- строки подсказок трекера и матрицы — в резерве под телом (опция hints)
  if (L.hint_h or 0) > 0 then
    local hy2 = L.under_y
    if L.matrix_w > 0 and not state.mx_hidden then D.hint_bar(L, 0, hy2, L.matrix_w - 1, (info.hint_bars or function() end)('matrix'), info.focus == 'matrix') end
    -- под полосой транспорта — подсказки её элементов, каждая под своим (5 окт)
    if not (L.piano_h > 0 and L.tppos == 'tracker' and info.hint_bars and D.strip_hints(L, L.matrix_w, hy2, L.win_w - L.matrix_w, info.focus == 'tracker')) then
      D.hint_bar(L, L.matrix_w, hy2, L.win_w - L.matrix_w, (info.hint_bars or function() end)(info.vmode == 'insert' and 'insert' or 'tracker'), info.focus == 'tracker')
    end
  end
  -- режим справки (?): то же место внизу занимает контекстная справка
  if L.dsp_h > 0 and info.khelp and info.khelp_draw then
    local dy = L.dsp_y                                   -- под строкой подсказок тела (или под верхним модулем)
    local xo = L.ctrl_dsp and (L.ctrl_w + D.SEPW) or 0     -- главный модуль слева в полосе DSP (3 окт)
    set(U.PANEL); gfx.rect(0, dy, L.win_w, L.dsp_h, 1)
    set(D.SEP); gfx.rect(0, dy, L.win_w, D.SEPW, 1)
    hover.khelp = info.khelp_draw(L, xo, dy, L.win_w - xo, L.dsp_h) or true
    L.dsp_rect = { xo, dy, L.win_w - xo, L.dsp_h }
  elseif L.dsp_h > 0 then
    local dy = L.dsp_y                                   -- под строкой подсказок тела (или под верхним модулем)
    set(U.PANEL); gfx.rect(0, dy, L.win_w, L.dsp_h, 1)
    set(D.SEP); gfx.rect(0, dy, L.win_w, D.SEPW, 1)
    local col = info.pool_col
    local fxs = info.dsp_fxs or (col and col.fx) or {}
    -- браузер эффектов слева (2 окт): продолжение левой колонки под матрицей
    local fbw = 0
    local xo = L.ctrl_dsp and (L.ctrl_w + D.SEPW) or 0     -- главный модуль слева в полосе DSP (3 окт)
    if info.fxb_draw then
      -- ширина матрицы, пока она открыта; свёрнутая матрица список эффектов не сжимает (2 окт)
      local own = math.min(L.cw * 26, math.floor(L.win_w / 4))
      fbw = (L.matrix_w and L.matrix_w > 0 and not state.mx_hidden) and math.max(L.matrix_w, math.floor(own * 0.6)) or own
      if info.fxb_px then fbw = math.max(L.cw * 12, math.min(math.floor(L.win_w * 0.5), info.fxb_px)) end   -- ширина мышью (3 окт)
      if info.fxb_expand then
        -- фокус на браузере: он раскрывается на всю левую колонку (за счёт
        -- матрицы и главного модуля) в конце кадра, после статуса; здесь — место
        set(U.PANEL); gfx.rect(xo, dy + 2, fbw, L.dsp_h - 2, 1)
        D.fxb_popup = { w0 = fbw }
      else hover.fxb = info.fxb_draw(L, xo, dy + 2, fbw, L.dsp_h - 2 - (L.hint_h or 0)) end
      L.fxb_rect = { xo, dy + 2, fbw, L.dsp_h - 2 }
    else L.fxb_rect = nil end
    fbw = fbw + xo
    -- граница список эффектов | DSP (3 окт: была чёрная щель)
    if fbw > 0 then set(D.SEP); gfx.rect(fbw - 2, dy, D.SEPW, L.dsp_h, 1) end
    -- шапка: имя трека (цвет как шапка канала), [track fx] [take fx], затем имя цепочки
    do
      local hx = fbw + L.pad
      local tcol = info.pool_col
      if tcol then
        local nm = tcol.name ~= '' and tcol.name or 'track'
        local nw = ms(nm) + 2 * L.pad
        local nb = (tcol.rgb and (info.hdrfill or 'line') ~= 'off') and U.mix(D.HDR, tcol.rgb, 0.30) or D.HDR
        if tcol.rgb and (info.hdrfill or 'line') ~= 'off' then rawset_col(nb) else set(nb) end
        gfx.rect(hx, dy + 2, nw, L.rh, 1)
        text(hx + L.pad, dy + 3, nm, U.readable(U.TEXT, nb, 4.5))
        hx = hx + nw + L.pad
      end
      for _, b in ipairs({ { 'track', false, 'track fx' }, { 'take', true, 'take fx' } }) do
        local on = (info.dsp_is_take or false) == b[2]
        local bw = ms(b[3]) + 2 * L.pad
        local hot = mx >= hx and mx < hx + bw and my >= dy + 2 and my < dy + 2 + L.rh
        -- track fx включена — зелёная, как FX на канале REAPER (3 окт)
        local g = on and not b[2]
        set(g and D.FXG_T or (hot and U.tint(U.AMBER, 0.3) or (on and U.tint(U.AMBER, 0.15) or U.BG))); gfx.rect(hx, dy + 2, bw, L.rh, 1)
        set(g and D.FXG or (on and U.AMBER or U.LINE)); gfx.rect(hx, dy + 2, bw, L.rh, 0)
        text(hx + L.pad, dy + 3, b[3], g and D.FXTXT or (on and U.AMBER or (hot and U.TEXT or U.GREY)))
        if hot then hover.dsptarget = b[1] end
        hint('dsptarget', hx, dy + 2, bw, L.rh, b[1])
        hx = hx + bw + L.pad
      end
      -- имя трека уже слева от кнопок; здесь — имя take (цепочка take) и подсказка
      text(hx, dy + 3, fit((info.dsp_is_take and (info.dsp_title or '') or '') .. (#fxs == 0 and '  (no fx: pick one in the fx list, or / )' or ''), gfx.w - hx - L.pad), info.dsp_is_take and U.AMBER or U.GREY)
    end
    local bx = fbw + L.pad
    local lvl = info.pool_col and info.dsp_levels and info.dsp_levels(info.pool_col)
    local mw = math.max(ms('o') + 4, 12)                -- тонкие метры (5 окт)
    local mby, mbh = dy + L.rh + 4, L.dsp_h - L.rh - 6 - (L.hint_h or 0)
    if lvl then
      D.dsp_meter(L, bx, mby, mw, mbh, lvl.src == 'in' and 'i' or 'p', lvl.inp, 'in', hover)
      bx = bx + mw + L.pad
    end
    -- блок трека — первый слева, закреплён (не перетаскивается с FX)
    if info.pool_col and info.trk_io then
      local tw = L.cw * 19                         -- 4 окт: компактнее (было 24)
      local used = D.track_block(L, info, info.pool_col, bx, dy + L.rh + 4, tw, L.dsp_h - L.rh - 6 - (L.hint_h or 0), hover, rawset_col)
      if used > 0 then bx = bx + used + L.pad end
    end
    D.aw_status = nil
    local drag = info.dsp_drag                 -- { k = блок } | { new = true } — идёт перетаскивание
    local blocks = {}
    local bw = L.cw * 22
    local sel = info.dsp_sel or {}
    for k, f in ipairs(fxs) do
      local ncol = f.cols or 1
      local bw1 = L.cw * 22
      local by = dy + 3 + L.rh
      local bh = L.dsp_h - L.rh - 6 - (L.hint_h or 0)
      -- автомодуль (4 окт): колонок столько, сколько параметров влезает по
      -- строкам (≤ 3) — без пустой колонки справа; места больше — больше параметров
      if f.auto then
        local rows_fit = math.max(1, math.floor((bh - L.rh - 2) / L.rh))
        ncol = math.max(1, math.min(3, math.ceil(#f.params / rows_fit)))
      end
      local bw = bw1 * ncol
      if bx + bw > L.win_w - (lvl and (mw + L.pad) or 0) then break end
      local is_sel = sel.fx == k
      blocks[#blocks + 1] = { x = bx, w = bw, y = by, h = bh, k = k }
      local in_rng = info.dsp_range and k >= info.dsp_range[1] and k <= info.dsp_range[2]
      set(in_rng and U.tint(U.CYAN, 0.22) or (is_sel and U.tint(U.AMBER, 0.18) or U.BG)); gfx.rect(bx, by, bw, bh, 1)
      set((info.dsp_learn == k) and U.CYAN or (f.enabled and (is_sel and U.AMBER or U.LINE) or U.DIM)); gfx.rect(bx, by, bw, bh, 0)
      if info.dsp_learn == k then gfx.rect(bx + 1, by + 1, bw - 2, bh - 2, 0) end     -- learn: двойная голубая рамка
      -- кнопки блока (2 окт): O — окно, B — bypass, x в правом углу — удалить
      local kb = ms('O') + 2 * L.pad
      -- Δ (4 окт; буква, не значок — философия: только буквы алфавитов) — delta solo REAPER (:delta): слышна разница вход − выход эффекта
      local bxs = { { 'x', 'del', bx + bw - kb - 1 }, { 'B', 'bypass', bx + bw - 2 * kb - 4 }, { 'Δ', 'delta', bx + bw - 3 * kb - 7 }, { 'O', 'open', bx + bw - 4 * kb - 8 } }
      local dlt = info.fx_delta and info.fx_delta(f)
      local tw = bw - 2 * L.pad - 4 * kb - 9
      -- пресет (4 окт): «< имя >» справа от имени эффекта; клик по имени —
      -- список, < > — предыдущий / следующий
      local pre = info.fx_preset and not f.container and info.fx_preset(f)
      local ptw = 0
      local on_btn = false
      if pre and tw > L.cw * 14 then
        ptw = math.min(math.floor(tw * 0.6), ms('< ' .. pre.name .. ' >') + L.pad)
        local px = bx + L.pad + tw - ptw
        local aw = ms('<') + 2
        local parts = { { '<', 'pprev', px, aw }, { pre.name, 'preset', px + aw, ptw - 2 * aw }, { '>', 'pnext', px + ptw - aw, aw } }
        for _, pp in ipairs(parts) do
          local hot = not drag and mx >= pp[3] and mx < pp[3] + pp[4] and my >= by + 1 and my < by + L.rh
          if hot then set(U.tint(U.AMBER, 0.3)); gfx.rect(pp[3], by + 1, pp[4], L.rh - 1, 1); hover.dspbtn = { fx = k, f = f, what = pp[2] }; on_btn = true end
          text(pp[3] + (pp[2] == 'preset' and 2 or 1), by + 1, fit(pp[1], pp[4] - 2), hot and U.AMBER or (pp[2] == 'preset' and U.CYAN or U.GREY))
        end
        tw = tw - ptw - L.pad
      end
      text(bx + L.pad, by + 1, fit((f.enabled and '' or '(off) ') .. (f.container and ('[' .. f.name .. '] ' .. #f.kids .. ' fx') or f.name), tw), f.enabled and (f.container and U.AMBER or U.TEXT) or U.GREY)
      if tw > 0 then
        for _, b in ipairs(bxs) do
          local kx = b[3]
          local hot = not drag and mx >= kx and mx < kx + kb and my >= by + 1 and my < by + L.rh
          local lit = (b[2] == 'bypass' and not f.enabled) or (b[2] == 'delta' and dlt)
          set(hot and U.tint(b[2] == 'del' and U.RED or U.AMBER, 0.35) or (lit and U.tint(U.AMBER, 0.25) or U.BG)); gfx.rect(kx, by + 1, kb, L.rh - 1, 1)
          set(hot and (b[2] == 'del' and U.RED or U.AMBER) or U.LINE); gfx.rect(kx, by + 1, kb, L.rh - 1, 0)
          text(kx + L.pad, by + 1, b[1], hot and (b[2] == 'del' and U.RED or U.AMBER) or (lit and U.AMBER or U.GREY))
          if hot then hover.dspbtn = { fx = k, f = f, what = b[2] }; on_btn = true end
        end
      end
      if not drag and not on_btn and mx >= bx and mx < bx + bw and my >= by and my < by + L.rh then hover.dsp = { fx = k, f = f } end
      hint('dsp', bx, by, bw, L.rh, { fx = k })
      local vals = info.fx_values and info.fx_values(f) or {}
      local pw = bw1 - 2 * L.pad
      local nfit = math.floor((bh - L.rh - 2) / L.rh)
      -- Airwindows (4 окт): строка под именем — категория цветом и описание
      local awi = f.airwin and info.airwin_info and info.airwin_info(f.airwin)
      local aw_off = 0
      if awi and nfit > 2 then
        nfit = nfit - 1; aw_off = L.rh
        local ay = by + L.rh + 1
        local tag = awi.cat ~= '' and ('[' .. awi.cat .. '] ') or ''
        local ccol = D.aw_colour(awi.cat)
        text(bx + L.pad, ay, fit(tag, bw - 2 * L.pad), ccol)
        -- описание — в статус (5 окт): под мышью или выбранный блок
        local over = mx >= bx and mx < bx + bw and my >= by and my < by + bh
        if (over or (is_sel and not D.aw_status)) and (awi.desc or '') ~= '' then
          D.aw_status = (f.airwin or '') .. ' ' .. tag .. awi.desc
        end
      end
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
      if f.view == 'grain' then
        -- гранулятор: облако — 16 колонок волны, точки зёрен (свежее выше),
        -- окно зума, позиция головки зёрен, голова записи (красная)
        pcol0 = 1
        local wx, wy, ww, wh = bx + L.pad, by + L.rh + 1, pw, bh - L.rh - 4
        local g = info.dsp_view and info.dsp_view('grain')
        set(U.PANEL); gfx.rect(wx, wy, ww, wh, 1)
        set(U.LINE); gfx.rect(wx, wy, ww, wh, 0)
        if g and g.alive then
          if g.z1 > g.z0 then set(U.tint(U.CYAN, 0.12)); gfx.rect(wx + math.floor(g.z0 * ww), wy + 1, math.max(1, math.floor((g.z1 - g.z0) * ww)), wh - 2, 1) end
          local cw = ww / 16
          local cy, hh = wy + math.floor(wh / 2), math.floor(wh / 2) - 2
          for i = 1, 16 do
            local v = g.wave[i] or 0
            local x0 = wx + math.floor((i - 1) * cw) + 1
            local bw2 = math.max(1, math.floor(cw) - 1)
            set(U.mix(U.DIM, U.TEXT, 0.6)); gfx.rect(x0, cy - math.floor(v * hh), bw2, math.max(1, math.floor(v * hh * 2)), 1)
            local row = g.grow[i] or -1
            if row >= 0 then
              set(U.AMBER)
              gfx.circle(x0 + math.floor(bw2 / 2), wy + 3 + math.floor(row / 7 * (wh - 8)), math.max(2, math.floor(L.rh / 5)), 1, 1)
            end
          end
          set(U.AMBER); gfx.rect(wx + math.floor(g.pos * (ww - 1)), wy, 1, wh, 1)
          if g.rec then set(U.RED); gfx.rect(wx + math.floor(g.head * (ww - 1)), wy, 2, wh, 1) end
        else
          text(wx + 2, wy + 1, fit('no grain data (drop a sound in jf_grgrain)', ww - 4), U.DIM)
        end
        if not drag and mx >= wx and mx < wx + ww and my >= wy and my < wy + wh then
          hover.dspview = { fx = k, f = f, x = wx, w = ww }
        end
      end
      if f.view and D.FX_VIEWS[f.view] then
        -- вид встроенного эффекта REAPER (4 окт) — первая колонка
        pcol0 = 1
        VRH = L.rh
        D.fx_view(f.view, f, vals, bx + L.pad, by + L.rh + 1, pw, bh - L.rh - 4)
      end
      if f.view == 'rec' then
        -- jf_rec (4 окт): волна кольца, выделение a..b, голова превью;
        -- статус и буквы-кнопки внизу; протяжка и кнопки — hover.retro /
        -- hover.retrobtn, как во вкладке rec
        -- волна — во всю ширину блока (4 окт), параметры — строкой внизу справа
        pcol0 = 0
        local wx, wy, ww = bx + L.pad, by + L.rh + 1, bw - 2 * L.pad
        local wh = bh - 3 * L.rh - 6
        local r = info.dsp_view and info.dsp_view('rec', ww)
        local c = r and r.cur
        set(U.PANEL); gfx.rect(wx, wy, ww, math.max(4, wh), 1)
        set(U.LINE); gfx.rect(wx, wy, ww, math.max(4, wh), 0)
        if c and wh > 6 then
          local a, b = r.sel.a, r.sel.b
          if b < a then a, b = b, a end
          set(U.tint(U.AMBER, 0.25)); gfx.rect(wx + math.floor(a * ww), wy, math.max(1, math.floor((b - a) * ww)), wh, 1)
          local pk = c.peaks
          local cy, hh = wy + wh / 2, wh / 2 - 1
          if pk and pk.n > 0 then
            set(U.readable(U.mix(c.col.rgb or U.TEXT, U.TEXT, 0.3), U.BG, 4.0))
            for px = 0, ww - 1 do
              local i = math.floor(px / ww * pk.n) + 1
              local mxv, mnv = pk.max[i] or 0, pk.min[i] or 0
              if mxv - mnv < 0.01 then mxv, mnv = 0.005, -0.005 end
              gfx.line(wx + px, cy - mxv * hh, wx + px, cy - mnv * hh)
            end
          end
          set(U.AMBER); gfx.rect(wx + math.floor(a * ww), wy, 1, wh, 1); gfx.rect(wx + math.floor(b * ww) - 1, wy, 1, wh, 1)
          if c.pb and c.pb > 0 then set(U.GREEN); gfx.rect(wx + math.floor(c.pb * ww), wy, 1, wh, 1) end
          if not drag and mx >= wx and mx < wx + ww and my >= wy and my < wy + wh then hover.retro = (mx - wx) / ww; hover.retro_src = 'dsp' end
          local st = c.alive and ('%ds %s  sel %.2fs'):format(c.len, c.writing and 'rec' or 'paused', c.len * (b - a)) or 'silent: enable jf_rec'
          text(wx, wy + wh + 2, fit(st, ww - bw1), c.alive and (c.writing and U.RED or U.GREY) or U.GREY)
          local kx, ky = wx, wy + wh + 2 + L.rh
          for _, k in ipairs({ { 'all', 'all' }, { 'play', 'play' }, { 'stop', 'stop' }, { 'put', 'put' }, { 'lib', 'lib' } }) do
            local kw = ms(k[1]) + L.pad + 2
            if kx + kw > wx + ww then break end
            local hot = not drag and mx >= kx and mx < kx + kw and my >= ky and my < ky + L.rh
            local on = k[2] == 'play' and c.playing
            set(on and U.tint(U.AMBER, 0.3) or (hot and D.CURROW or U.BG)); gfx.rect(kx, ky, kw, L.rh, 1)
            set((hot or on) and U.AMBER or U.LINE); gfx.rect(kx, ky, kw, L.rh, 0)
            text(kx + math.floor((kw - ms(k[1])) / 2), ky, k[1], (hot or on) and U.AMBER or U.GREY)
            if hot then hover.retrobtn = k[2]; hover.retro_src = 'dsp' end
            kx = kx + kw + 1
          end
        else
          text(wx + 2, wy + 1, fit('jf_rec: no buffer yet (open the rec tab once / enable)', ww - 4), U.DIM)
        end
      end
      if f.xy then
        -- XY-пэд (TG33 vector): квадрат в первой колонке, точка — X / Y, Y вверх
        pcol0 = 1
        local side = math.max(L.rh * 2, math.min(pw, bh - L.rh - 4))
        local px0, py0 = bx + L.pad + math.floor((pw - side) / 2), by + L.rh + 1
        local nx = vals[f.xy_x] and vals[f.xy_x].n or 0.5
        local ny = vals[f.xy_y] and vals[f.xy_y].n or 0.5
        set(U.PANEL); gfx.rect(px0, py0, side, side, 1)
        set(U.LINE); gfx.rect(px0, py0, side, side, 0)
        set(U.DIM); gfx.rect(px0 + math.floor(side / 2), py0, 1, side, 1); gfx.rect(px0, py0 + math.floor(side / 2), side, 1, 1)
        local dx, dy = px0 + math.floor(nx * (side - 1) + 0.5), py0 + math.floor((1 - ny) * (side - 1) + 0.5)
        set(U.AMBER); gfx.circle(dx, dy, math.max(3, math.floor(L.rh / 3)), 1, 1)
        if side >= L.cw * 6 then
          text(px0 + 2, py0 + side - L.rh, fit(('%d / %d'):format(math.floor(nx * 127 + 0.5), math.floor(ny * 127 + 0.5)), side - 4), U.GREY)
        end
        if not drag and mx >= px0 and mx < px0 + side and my >= py0 and my < py0 + side then
          hover.dspxy = { fx = k, f = f, x = px0, y = py0, s = side }
        end
      end
      if f.wave then
        -- сэмплер (RS5K): волна файла с зоной start..end, ручки тянутся мышью,
        -- бросок файла из браузера — новый сэмпл
        pcol0 = 1
        local wx, wy = bx + L.pad, by + L.rh + 1
        local ww, wh = pw, bh - L.rh - 4
        local na = f.wave_a and vals[f.wave_a] and vals[f.wave_a].n or 0
        local nb = f.wave_b and vals[f.wave_b] and vals[f.wave_b].n or 1
        set(U.PANEL); gfx.rect(wx, wy, ww, wh, 1)
        set(U.LINE); gfx.rect(wx, wy, ww, wh, 0)
        local name = f.file and (f.file:match('[^/]+$') or f.file) or 'no sample - drop a file from the browser here'
        local th = L.rh
        text(wx + 2, wy + 1, fit(name, ww - 4), f.file and U.GREY or U.DIM)
        local gy, gh = wy + th + 1, wh - th - 2
        if f.file and gh > 4 and ww > 8 then
          local pk = info.file_peaks and info.file_peaks(f.file, ww)
          local cy, hh = gy + math.floor(gh / 2), math.floor(gh / 2) - 1
          for px = 0, ww - 1 do
            local fr = px / ww
            local inside = fr >= na and fr <= nb
            set(inside and U.TEXT or U.DIM)
            if pk and pk.n > 0 then
              local i = math.floor(fr * pk.n) + 1
              local a, b = pk.min[i] or 0, pk.max[i] or 0
              if b - a < 0.03 then a, b = -0.015, 0.015 end
              gfx.line(wx + px, cy - b * hh, wx + px, cy - a * hh)
            end
          end
          for _, e in ipairs({ { na, 'a' }, { nb, 'b' } }) do
            local lx = wx + math.floor(e[1] * (ww - 1) + 0.5)
            set(U.AMBER); gfx.rect(lx, gy, 1, gh, 1)
            local tri = math.max(3, math.floor(L.rh / 3))
            gfx.triangle(lx, gy + tri, lx - tri, gy, lx + tri, gy)
          end
        end
        if not drag and mx >= wx and mx < wx + ww and my >= wy and my < wy + wh then
          local fr = math.max(0, math.min(1, (mx - wx) / math.max(1, ww - 1)))
          hover.dspwave = { fx = k, f = f, frac = fr, x = wx, w = ww, edge = math.abs(fr - na) <= math.abs(fr - nb) and 'a' or 'b' }
        end
      end
      -- A / B (4 окт): есть оба снимка — нижняя строка блока: «A ━━●━━ B», тянуть
      local ab = info.fx_ab and info.fx_ab(f)
      if ab and nfit > 2 then
        nfit = nfit - 1
        local ry = by + bh - L.rh - 2
        local ax, aw2 = bx + L.pad, bw - 2 * L.pad
        local lw = ms('A') + L.pad
        local tx0, tw0 = ax + lw, aw2 - 2 * lw
        local hot = not drag and mx >= ax and mx < ax + aw2 and my >= ry and my < ry + L.rh
        text(ax, ry, 'A', (ab.t or 0) < 0.5 and U.CYAN or U.GREY)
        text(ax + aw2 - ms('B'), ry, 'B', (ab.t or 0) >= 0.5 and U.CYAN or U.GREY)
        set(U.DIM); gfx.rect(tx0, ry + math.floor(L.rh / 2) - 1, tw0, 2, 1)
        local hx = tx0 + math.floor((ab.t or 0) * (tw0 - 1) + 0.5)
        set(hot and U.AMBER or U.CYAN); gfx.rect(hx - 1, ry + 3, 3, L.rh - 6, 1)
        if hot then hover.dspab = { f = f, x = tx0, w = tw0 } end
      end
      for pi, p in ipairs(f.params) do
        if pi > nfit * (ncol - pcol0) then break end
        local colk = pcol0 + math.floor((pi - 1) / nfit)
        local bxc = bx + colk * bw1
        local py = by + L.rh + 1 + aw_off + ((pi - 1) % nfit) * L.rh
        -- rec (4 окт): параметры — снизу справа, под волной, последней строкой вверх
        if f.view == 'rec' then bxc = bx + bw - bw1; py = by + bh - (#f.params - pi + 2) * L.rh - 3 end   -- строка статуса, справа
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
        local step_sv, steps_inline
        if p.kind == 'toggle' then
          local on = v.n >= 0.5
          local sz = L.rh - 6
          set(on and acc or U.BG); gfx.rect(wx0, py + 3, sz, sz, 1)
          set(on and acc or U.LINE); gfx.rect(wx0, py + 3, sz, sz, 0)
        elseif p.kind == 'steps' and p.nsteps then
          local cur = math.floor(v.n * (p.nsteps - 1) + 0.5)
          -- выбором (4 окт): подписи положений в ряд — текущее голубым, под
          -- мышью янтарным, клик выбирает; не влезают — квадраты, как раньше
          local labs = info.step_labels and info.step_labels(f, p)
          local avail = bxc + L.pad + pw - wx0
          local tot = 0
          if labs then for _, lb in ipairs(labs) do tot = tot + ms(lb) + L.pad end end
          if labs and tot - L.pad <= avail then
            local lx = wx0
            for kk, lb in ipairs(labs) do
              local lw = ms(lb)
              local hot = not drag and mx >= lx - 1 and mx < lx + lw + L.pad and my >= py and my < py + L.rh
              if hot then step_sv = (kk - 1) / math.max(1, p.nsteps - 1) end
              text(lx, py, lb, hot and U.AMBER or ((kk - 1) == cur and U.CYAN or U.GREY))
              lx = lx + lw + L.pad
            end
            steps_inline = true
          else
            local segw = math.max(2, math.floor((ww - (p.nsteps - 1)) / p.nsteps))
            for kk = 0, p.nsteps - 1 do
              set(kk == cur and acc or U.DIM); gfx.rect(wx0 + kk * (segw + 1), py + 4, segw, L.rh - 8, kk == cur and 1 or 0)
            end
          end
        else
          set(U.DIM); gfx.rect(wx0, cy - 1, ww, 2, 1)                       -- дорожка
          -- цвет категории (громкость / фильтр / время …) — заливкой слайдера,
          -- не полоской у имени (3 окт: полоска липла к первой букве)
          local cc = (acc == U.TEXT and p.cat and p.cat ~= 'other' and p.cat ~= 'mode') and D.cat_colour(p.cat) or nil
          set(cc or acc); gfx.rect(wx0, py + 4, math.max(1, math.floor(v.n * ww + 0.5)), L.rh - 8, 1)
        end
        text(bxc + L.pad, py, fit(p.name, nw - L.pad), psel and U.AMBER or U.TEXT)
        if vw > 4 and not steps_inline then text(vx, py, fit(v.s, vw), U.GREY) end
        if not drag and mx >= bxc + L.pad and mx < bxc + L.pad + pw and my >= py and my < py + L.rh then
          hover.dsp = { fx = k, f = f, param = pi, frac = (mx - bx - L.pad) / pw,
                        sv = math.max(0, math.min(1, (mx - wx0) / math.max(1, ww))), onwidget = mx >= wx0 - 2 and mx < wx0 + ww + 2 }
          if steps_inline then hover.dsp.onwidget = step_sv ~= nil; hover.dsp.sv = step_sv or hover.dsp.sv
          elseif p.kind == 'steps' and p.nsteps then hover.dsp.steplist = true end   -- клик — список (5 окт)
        end
        hint('dspparam', bxc + L.pad, py, pw, L.rh, { fx = k, param = pi })
      end
      bx = bx + bw + L.pad
    end
    -- выход после всех эффектов и кнопка компенсации громкости под ним (4 окт)
    if lvl then
      local cbh = L.rh
      D.dsp_meter(L, bx, mby, mw, mbh - cbh - 2, 'o', lvl.out, 'out', hover)
      local cy = mby + mbh - cbh
      local hot = mx >= bx and mx < bx + mw and my >= cy and my < cy + cbh
      local on = lvl.comp_on
      local lbl = 'c'                                    -- comp буквой (5 окт), значение — в статусе
      set(on and U.tint(U.CYAN, 0.35) or (hot and U.tint(U.AMBER, 0.3) or U.BG)); gfx.rect(bx, cy, mw, cbh, 1)
      set(on and U.CYAN or (hot and U.AMBER or U.LINE)); gfx.rect(bx, cy, mw, cbh, 0)
      text(bx + math.floor((mw - ms(lbl)) / 2), cy, fit(lbl, mw - 2), on and U.CYAN or (hot and U.AMBER or U.GREY))
      if hot then hover.dspcomp = info.pool_col end
    end
    -- перетаскивание (блок или FX из списка): куда встанет — янтарная черта
    -- между блоками; половина блока под мышью решает «до» или «после»
    if drag and my >= dy and my < dy + L.dsp_h and mx >= fbw then
      local gap, gx = #blocks, (#blocks > 0 and (blocks[#blocks].x + blocks[#blocks].w + math.floor(L.pad / 2)) or (fbw + L.pad))
      for _, b in ipairs(blocks) do
        if mx < b.x + b.w / 2 then gap = b.k - 1; gx = b.x - math.floor(L.pad / 2) - 1; break end
      end
      local gy, gh = dy + 3 + L.rh, L.dsp_h - L.rh - 6 - (L.hint_h or 0)
      set(U.AMBER); gfx.rect(gx - 1, gy, 3, gh, 1)
      gfx.rect(gx - 4, gy, 9, 2, 1); gfx.rect(gx - 4, gy + gh - 2, 9, 2, 1)
      hover.dsp_gap = gap
    end
    if drag and drag.k then
      for _, b in ipairs(blocks) do
        if b.k == drag.k then set(U.BG); gfx.a = 0.5; gfx.rect(b.x, b.y, b.w, b.h, 1); gfx.a = 1 end
      end
    end
    if (L.hint_h or 0) > 0 then
      local hy3 = dy + L.dsp_h - L.hint_h
      if fbw > 0 then D.hint_bar(L, 0, hy3, fbw - 1, (info.hint_bars or function() end)(info.notes_draw and 'notes' or 'fxb'), info.focus == 'fxb' or info.focus == 'notes') end
      D.hint_bar(L, fbw, hy3, L.win_w - fbw, (info.hint_bars or function() end)('dsp'), info.focus == 'dsp')
    end
    L.dsp_rect = { fbw, dy, L.win_w - fbw, L.dsp_h }
  end

  -- кнопки у линии раздела трекер | правая панель (2 окт): > свернуть, < развернуть,
  -- = тянуть ширину; стоят слева от линии, чтобы не закрывать кнопки браузера
  do
    local bw = ms('<') + 2 * L.pad
    local bot = gfx.h - L.status_h
    local lx = L.side_x or L.win_w                   -- левый край правой панели / полосы
    if not state.side then
      set(U.PANEL); gfx.rect(lx, L.header_y, L.rstrip_w, bot - L.header_y, 1)
      set(D.SEP); gfx.rect(lx, L.header_y, D.SEPW, bot - L.header_y, 1)
    end
    local function knob(y, lbl, what)
      local bx = lx - math.floor(bw / 2)               -- на линии модуля (4 окт), по центру
      local hot = mx >= bx and mx < bx + bw and my >= y and my < y + L.rh
      set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, y, bw, L.rh, 1)
      set(hot and U.AMBER or U.LINE); gfx.rect(bx, y, bw, L.rh, 0)
      text(bx + L.pad, y, lbl, hot and U.AMBER or U.TEXT)
      if hot then hover.sidectl = what end
      hint('sidectl', bx, y, bw, L.rh, what)
    end
    -- панель открыта: кнопки в трекере у низа его тела, над нижней панелью
    -- (DSP / справка), иначе они ложились на текст справки (2 окт)
    -- 4 окт: кнопок нет — тянется сама линия, свёрнутая полоса — клик
    -- разворачивает; свернуть — быстрая кнопка browser
    local _ = knob
    if mx >= lx - 3 and mx <= lx + 3 and my >= L.header_y and my < bot then
      for _, k in ipairs({ 'row', 'cell', 'fi', 'col', 'field', 'browser', 'matrix', 'pool', 'rownum' }) do hover[k] = nil end; hover.sidectl = state.side and 'grip' or 'open'
      set(U.AMBER); gfx.rect(lx - 1, L.header_y, 2, bot - L.header_y, 1)
    elseif not state.side and mx > lx + 3 and mx < lx + L.rstrip_w and my >= L.header_y and my < bot then
      hover.sidectl = 'open'
    end
  end

  -- прямоугольники модулей (3 окт) — для рамки фокуса; границы модулей рисуют
  -- разделители D.SEP: 1 px, тусклые (одна линия, без наложений)
  do
    local rects = {
      -- до низа модуля (5 окт): статус в трекере и строка подсказок — внутри рамки
      tracker = { tx0, hy, W - tx0, (L.trk_bot or (L.body_y + L.body_h + L.low_h)) - hy },
      matrix = (L.matrix_w > 0 and not state.mx_hidden) and { 0, hy, L.matrix_w, (L.trk_bot or (L.body_y + L.body_h + L.low_h)) - hy } or nil,
      browser = L.side_w > 0 and { L.side_x, (L.side_y0 or 0) + (L.inst_side_h or 0) + 2, L.side_w, gfx.h - L.status_h - (L.side_y0 or 0) - (L.inst_side_h or 0) - 2 } or nil,
      top = L.top_h > 0 and L.top_rect or nil,
      ctrl = L.top_h > 0 and L.ctrl_area or nil,
      inst = (L.inst_w > 0 or L.side_w > 0) and L.inst_rect or nil,
      dsp = L.dsp_h > 0 and L.dsp_rect or nil,
      fxb = L.dsp_h > 0 and L.fxb_rect or nil,
      notes = L.notes_rect,
      slices = L.slices_rect,
    }
    D.module_rects = rects          -- только для рамки фокуса: границы модулей — разделители D.SEP (1 px)
  end
  -- статус — в самом низу окна, под DSP-панелью (раньше делил y с ней и
  -- перекрывал её шапку)
  -- статус-бар (3 окт): внизу окна (bottom) или строкой под телом трекера,
  -- по ширине матрица + трекер (tracker)
  local sx, sy, sw, sh = 0, gfx.h - L.status_h, gfx.w, L.status_h
  if L.status_in > 0 then
    -- в модуле трекера: под треками (от границы матрицы), под матрицей — её фон
    sx, sy, sw, sh = L.matrix_w, L.stat_y, L.win_w - L.matrix_w, L.status_in
    if L.matrix_w > 0 then set(U.PANEL); gfx.rect(0, sy, L.matrix_w, sh, 1) end
  end
  if sh > 0 then
    set(U.PANEL); gfx.rect(sx, sy, sw, sh, 1)
    set(D.SEP); gfx.rect(sx, sy, sw, D.SEPW, 1)
    -- слева режим/сообщение (не шире трети), дальше — описание того, на что
    -- наведена мышь, во всю оставшуюся ширину
    local left = fit(info.status_left or '', sw / 3)
    -- mono: INSERT в статусе — красным, как рамка (3 окт)
    text(sx + L.pad, sy + 2, left, (D.mono and info.vmode == 'insert') and D.FOCUS_INS or U.AMBER)
    local hx = sx + L.pad + (left ~= '' and (ms(left) + 3 * L.pad) or 0)
    local desc = info.status_right or ''
    if desc == '' then desc = D.aw_status or '' end
    D.aw_status = nil                    -- DSP спрятан — строка не залипает
    D.aw_status = nil
    if desc ~= '' then
      if left ~= '' then set(D.SEP); gfx.rect(hx - 2 * L.pad + L.pad // 2, sy + 2, 1, sh - 2, 1) end
      text(hx, sy + 2, fit(desc, sx + sw - hx - L.pad), U.TEXT)
    end
  end
  if L.side_w > 0 then set(D.SEP); gfx.rect((L.side_x or L.win_w) - 2, 0, D.SEPW, gfx.h - L.status_h, 1) end
  -- модуль слайсов (4 окт): своя колонка, линия слева
  if (L.slices_w or 0) > 0 and L.top_h > 0 and info.slices_draw then
    local sx, sy, sh = L.win_w - L.slices_w, L.top_y or 0, L.top_h - 2
    set(U.PANEL); gfx.rect(sx, sy, L.slices_w, sh, 1)
    local hs = info.slices_draw(L, sx + 3, sy + 2, L.slices_w - 5, sh - 4)
    if hs ~= nil then hover.slices = hs end
    set(D.SEP); gfx.rect(sx, sy, D.SEPW, sh, 1)
    L.slices_rect = { sx, sy, L.slices_w, sh }
  else L.slices_rect = L.slices_split_rect end   -- линия сайдбара до статус-бара
  -- нижняя граница окна (4 окт): статус не внизу — модули внизу (DSP, сайдбар)
  -- закрываются общей линией во всю ширину; у сайдбара она была, у DSP — нет
  if L.status_h == 0 then set(D.SEP); gfx.rect(0, gfx.h - D.SEPW, gfx.w, D.SEPW, 1) end
  -- граница матрица | трекер — на всю высоту модуля трекера: тело, статус в
  -- нём, строка подсказок (3 окт: обрывалась у низа тела, статус её закрывал);
  -- рисуется после статуса и подсказок, ровно до следующего модуля
  if L.matrix_w > 0 and not state.mx_hidden then set(D.SEP); gfx.rect(L.matrix_w - 2, L.header_y, D.SEPW, (L.trk_bot or gfx.h) - L.header_y, 1) end
  -- браузер эффектов в фокусе (3 окт): во всю левую колонку — от верха матрицы
  -- до низа окна (матрица и главный модуль под ним), рисуется последним, мышь
  -- над ним не достаёт до того, что под ним
  if D.fxb_popup and info.fxb_draw then
    local p = D.fxb_popup
    D.fxb_popup = nil
    local pw = math.max(p.w0, L.matrix_w or 0, (L.top_h > 0) and L.ctrl_w or 0)
    pw = math.min(pw, math.floor(L.win_w * 0.6))
    local py = math.min(L.header_y, (L.top_h > 0 and (L.top_y or 0) > 0) and L.top_y or L.header_y)
    local pb = gfx.h - L.status_h
    local inside = mx >= 0 and mx < pw and my >= py and my < pb
    if inside then for k in pairs(hover) do hover[k] = nil end end
    set(U.BG); gfx.rect(0, py, pw, pb - py, 1)
    local hv = info.fxb_draw(L, 0, py + 1, pw, pb - py - 2)
    if inside then hover.fxb = hv or true end
    set(U.AMBER); gfx.rect(0, py, pw, pb - py, 0)
  else D.fxb_popup = nil end
  -- keycaster (4 окт): последние нажатия в пустой правой части тела трекера —
  -- новое снизу, старое поднимается и гаснет (info.keycast: { label, t, n })
  if info.keycast and #info.keycast > 0 and L.cols and #L.cols > 0 then
    local lc = L.cols[#L.cols]
    local kx0 = (lc.x or 0) + (lc.w or 0) + 2 * L.pad
    local kx1 = W - L.pad
    local now = info.now or 0
    -- свой масштаб (4 окт: keys - / keys + в главном модуле)
    local s0, kcs = D.SCALE, (info.keycast_scale or 0) > 0 and info.keycast_scale or nil
    if kcs then
      if D.ttf then gfx.setfont(3, D.ttf_face, math.floor(D.ttf_px * kcs + 0.5))   -- TTF: свой кегль, не зум (5 окт)
      else D.SCALE = kcs end
    end
    local krh = TH() + 2
    if kx1 - kx0 >= L.cw * 6 then
      local yb = L.body_y + L.body_h - krh - 2
      local i = 0
      for k = #info.keycast, 1, -1 do
        local e = info.keycast[k]
        local age = now - e.t
        if age < 4 then
          local y = yb - i * (krh + 2)
          if y < L.body_y then break end
          local lbl = e.label .. (e.n > 1 and (' x' .. e.n) or '')
          local col = i == 0 and U.AMBER or U.mix(U.TEXT, U.BG, math.min(0.8, 0.25 + age / 5))
          text(kx1 - ms(lbl), y, fit(lbl, kx1 - kx0), col)
          i = i + 1
        end
      end
    end
    D.SCALE = s0
    if D.ttf then gfx.setfont(D.font_id) end
  end
  -- скролл-бар треков (3 окт): дорожка под телом от номеров строк до края,
  -- ползунок = видимые треки из всех; клик мимо — страница, протяжка — скролл
  do
    local x0 = tx0 + L.label_w
    local w = W - x0 - L.pad
    local y = L.hsb_y + 1
    local h = L.hsb_h - 2
    hover.hsb = nil
    if w > 20 and L.hs_n > 0 then
      local n = L.hs_n
      local tw = math.max(12, math.floor(w * math.min(1, math.max(1, L.hs_full) / n)))
      local tx = x0 + math.floor((w - tw) * (n > L.hs_full and (L.hs_before / math.max(1, n - L.hs_full)) or 0))
      tx = math.min(tx, x0 + w - tw)
      local inbar = mx >= x0 and mx < x0 + w and my >= L.hsb_y and my < L.hsb_y + L.hsb_h
      local onthumb = inbar and mx >= tx and mx < tx + tw
      set(U.BG); gfx.rect(x0, y, w, h, 1)
      set(U.DIM); gfx.rect(x0, y + math.floor(h / 2), w, 1, 1)
      set((onthumb or D.hsb_drag) and U.AMBER or (n > L.hs_full and U.LINE or U.DIM)); gfx.rect(tx, y, tw, h, 1)
      if inbar then hover.hsb = { thumb = onthumb, x0 = x0, w = w, n = n, page = math.max(1, L.hs_full), dir = mx < tx and -1 or 1 } end
    end
  end
  -- пианинка (4 окт): слой пианино — полоса клавиш под скролл-баром треков
  if L.piano_h > 0 then
    local p = info.piano
    if p then p.ins = info.vmode == 'insert' end
    local st
    if L.kbstat or (info.ctrl and info.ctrl.bigstatus) then
      st = { info.status_left or '', ((info.status_right or '') ~= '' and info.status_right) or D.aw_status or '', small = L.kbstat }
      if L.kbstat then D.aw_status = nil end
    end
    if L.tppos == 'tracker' then D.piano_strip(L, tx0, L.piano_y, W - tx0, L.piano_h, p, info, hover, st)
    else
      -- снаружи трекера: во всю ширину окна без сайдбара, подсказки — своей строкой под ней
      D.piano_strip(L, 0, L.piano_y, L.win_w, L.piano_h, p, info, hover, st)
      if (L.hint_h or 0) > 0 then
        if not (info.hint_bars and D.strip_hints(L, 0, L.piano_y + L.piano_h, L.win_w, info.focus == 'tracker')) then
          set(U.PANEL); gfx.rect(0, L.piano_y + L.piano_h, L.win_w, L.hint_h, 1)
        end
      end
    end
  end
  -- главный модуль отдельно (3 окт): рисуется в буфер 99 и выводится в своё
  -- место; мышь, метки f и прямоугольники — со сдвигом, как у верхней панели
  if L.ctrl_alone and L.ctrl_box then
    local bx, by, bw, bh = L.ctrl_box[1], L.ctrl_box[2], L.ctrl_box[3], L.ctrl_box[4]
    if D.ctrl_buf_w ~= bw or D.ctrl_buf_h ~= bh then gfx.setimgdim(99, bw + D.SEPW, bh); D.ctrl_buf_w, D.ctrl_buf_h = bw, bh end
    local dest0, my0, hint0 = gfx.dest, gfx.mouse_y, D.hint
    gfx.dest = 99
    gfx.mouse_y = my0 - by
    if hint0 then D.hint = function(kind, x, y, w, h, data) return hint0(kind, x, y + by, w, h, data) end end
    set(U.PANEL); gfx.rect(0, 0, bw + D.SEPW, bh, 1)
    local hv = {}
    local ok, err = pcall(draw_ctrl, L, info, bh, hv)
    -- граница модуля сверху (к матрице / трекеру) — у mid / bottom
    if by > 0 then set(D.SEP); gfx.rect(0, 0, bw + D.SEPW, D.SEPW, 1) end
    gfx.mouse_y, D.hint, gfx.dest = my0, hint0, dest0
    if not ok then error(err, 0) end
    gfx.blit(99, 1, 0, 0, 0, bw + D.SEPW, bh, bx, by, bw + D.SEPW, bh)
    if L.ctrl_area then L.ctrl_area[2] = L.ctrl_area[2] + by end
    if L.notes_rect then L.notes_rect[2] = L.notes_rect[2] + by end
    if D.notes_popup and not D.notes_popup.shifted then D.notes_popup.y = D.notes_popup.y + by; D.notes_popup.shifted = true end
    for _, r in pairs(D.ctrl_rect or {}) do if not r.shifted then r[2] = r[2] + by; r.shifted = true end end
    local inside = mx >= bx and mx < bx + bw and my >= by and my < by + bh
    if inside then hover.ctrl, hover.notes, hover.zone = hv.ctrl, hv.notes, hv.zone end
  end
  -- заметки (4 окт): раскрыты вниз во всю левую колонку — от своего места в
  -- главном модуле до DSP (или низа окна), поверх матрицы
  if D.notes_popup and info.notes_draw then
    local p = D.notes_popup
    D.notes_popup = nil
    -- плавающее окошко (4 окт): место и размер — info.notes_win (тянется за
    -- шапку, размер — за правый нижний угол); нет — левая колонка, как раньше
    local px, py, pw, ph
    local nw = info.notes_win
    if nw then px, py, pw, ph = nw[1], nw[2], nw[3], nw[4]
    else
      px, py = 0, p.y
      pw = math.min(math.max(L.ctrl_w or 0, L.matrix_w or 0), math.floor(L.win_w * 0.6))
      ph = ((L.dsp_h > 0 and (L.dsp_y or 0) > py) and L.dsp_y or (gfx.h - L.status_h)) - py
    end
    pw = math.max(L.cw * 20, math.min(gfx.w, pw)); ph = math.max(4 * L.rh, math.min(gfx.h, ph))
    px = math.max(0, math.min(gfx.w - pw, px)); py = math.max(0, math.min(gfx.h - ph, py))
    local pb = py + ph
    do
      local inside = mx >= px and mx < px + pw and my >= py and my < pb
      if inside then for k in pairs(hover) do hover[k] = nil end end
      set(U.PANEL); gfx.rect(px, py, pw, ph, 1)
      local ok, hn = pcall(info.notes_draw, L, px + L.pad, py, pw - 2 * L.pad, ph - 2)
      if ok and inside then
        hover.notes = hn or 'text'
        local grip = math.max(8, L.cw)
        if mx >= px + pw - grip and my >= pb - grip then hover.notes = 'resize'
        elseif my < py + L.rh + 4 and (hn == nil or hn == 'text') then hover.notes = 'drag' end
      end
      set(info.focus == 'notes' and U.AMBER or D.SEP); gfx.rect(px, py, pw, ph, 0)
      -- угол размера: двойная кромка снизу справа (без значков)
      set(hover.notes == 'resize' and U.AMBER or U.LINE)
      gfx.rect(px + pw - L.cw, pb - 2, L.cw, 1, 1); gfx.rect(px + pw - 2, pb - L.cw, 1, L.cw, 1)
      L.notes_rect = { px, py, pw, ph }
    end
  else D.notes_popup = nil end
  -- всплывающий слайдер свёрнутой кнопки v / p (3 окт) — поверх всего
  if D.late_send then local f = D.late_send; D.late_send = nil; f() end
  if D.late_pop then local f = D.late_pop; D.late_pop = nil; f() end
  -- верхняя линия главного модуля и верхней панели (5 окт): как у lib сверху;
  -- до сайдбара — у него своя
  if L.top_h > 0 and L.top_first then set(D.SEP); gfx.rect(0, L.top_y or 0, (L.side_w or 0) > 0 and (L.side_x or L.win_w) - 2 or L.win_w, D.SEPW, 1) end
  -- рамка фокуса клавиатуры: модуль, которому идут клавиши; последней в
  -- кадре (5 окт) — скроллбар, пианинка и разделители закрывали низ и право
  do
    local f = info.focus
    local rects = D.module_rects or {}
    local r = rects[f]
    if r then
      -- INSERT — красная и на пиксель толще: видно, что клавиши пишут в проект
      local ins = info.vmode == 'insert' and info.focus == 'tracker'
      set(ins and D.FOCUS_INS or D.FOCUS)
      -- ободок ровно по границе модуля, без зазора: 1 px; INSERT — красный, 2 px
      gfx.rect(r[1], r[2], r[3], r[4], 0)
      if ins then gfx.rect(r[1] + 1, r[2] + 1, r[3] - 2, r[4] - 2, 0) end
    end
  end

  return hover
end

-- ── всплывашка снизу (which-key / подсказка команд / поиск) ───────────────
-- Панель над строкой статуса: колонками «клавиша  действие». Ширина — от
-- содержимого, высота — от числа строк (до половины окна).
-- anchor = { x, y } — место правки: всплывашка под ним (не влезает — над ним)
function D.popup(L, p, anchor)
  D.popup_hot, D.popup_rect = nil, nil
  if not p or not p.lines then return end
  local W = gfx.w
  local sy = L.body_y + L.body_h
  local n = #p.lines
  -- одна колонка (5 окт): столбец на всю высоту окна, вторая — только если не влезло
  local maxrows = math.max(1, math.floor((gfx.h - 4 * L.rh - (L.status_h or 0)) / L.rh) - 1)
  local ncol = math.max(1, math.ceil(n / maxrows))
  local nrow = math.min(n, maxrows)
  local kw, tw, hw = 0, 0, 0
  for _, ln in ipairs(p.lines) do
    kw = math.max(kw, ms(ln.key or ''))
    tw = math.max(tw, ms(ln.text or ''))
    if ln.hk then hw = math.max(hw, ms(ln.hk)) end
  end
  tw = math.min(tw, ms(string.rep('W', 60)))          -- длинные описания — обрезаются (fit), меню не во весь экран
  -- колонка хоткеев (5 окт): своя ширина, без наложений; описания ужимаются
  local hcol = hw > 0 and (hw + 2 * L.pad) or 0
  local maxcol = math.floor((W - 3 * L.pad) / ncol)
  if L.pad + kw + 2 * L.pad + hcol + tw + 2 * L.pad > maxcol then tw = math.max(ms('WWWWWWWW'), maxcol - (L.pad + kw + 2 * L.pad + hcol + 2 * L.pad)) end
  local colw = L.pad + kw + 2 * L.pad + hcol + tw + 2 * L.pad
  local w = math.min(W - 2 * L.pad, ncol * colw + L.pad)
  local h = (nrow + 1) * L.rh + 2 * L.pad
  local x, y = L.pad, sy - h - 2
  if anchor then
    -- right: не влезает вправо — правый край меню у правого края кнопки
    local ax = anchor.x
    if anchor.right and ax + w > W - L.pad then ax = anchor.right - w end
    x = math.max(L.pad, math.min(W - w - L.pad, ax))
    local bottom = gfx.h - (L.status_h or 0) - 2
    if anchor.above then y = anchor.y - h - 2 >= 2 and (anchor.y - h - 2) or (anchor.y + 3 * L.rh)   -- над ячейкой; транспорт наверху — под полосой (5 окт)
    elseif anchor.y + h <= bottom then y = anchor.y else y = math.max(2, anchor.y - L.rh - h) end
  end
  y = math.max(2, math.min(y, gfx.h - h - 2))         -- высокое меню целиком в окне (5 окт)
  D.popup_rect = { x, y, w, h }
  set(U.PANEL); gfx.rect(x, y, w, h, 1)
  -- рамка поярче (2 окт): видна поверх любого модуля
  set(U.mix(U.LINE, U.TEXT, 0.45)); gfx.rect(x, y, w, h, 0); gfx.rect(x + 1, y + 1, w - 2, h - 2, 0)
  text(x + L.pad, y + L.pad, fit(p.title or '', w - 2 * L.pad), p.kind == 'hydra' and U.AMBER or U.CYAN)
  for i, ln in ipairs(p.lines) do
    local ci = math.floor((i - 1) / nrow)
    local ri = (i - 1) % nrow
    local lx = x + L.pad + ci * colw
    local ly = y + L.pad + (ri + 1) * L.rh
    if lx + colw > x + w + L.pad then break end
    -- мышь (5 окт): строка гидры под мышью подсвечена, клик — её буква
    local mhot = p.kind == 'hydra' and gfx.mouse_x >= lx and gfx.mouse_x < lx + colw - L.pad and gfx.mouse_y >= ly and gfx.mouse_y < ly + L.rh
    if mhot then D.popup_hot = ln.key end
    if p.hl == i or mhot then set(D.CURROW); gfx.rect(lx, ly, colw - L.pad, L.rh, 1) end
    text(lx + L.pad, ly + 1, ln.key or '', p.kind == 'hydra' and U.AMBER or U.TEXT)
    if ln.hk then text(lx + L.pad + kw + 2 * L.pad, ly + 1, fit(ln.hk, hw), U.CYAN) end
    text(lx + L.pad + kw + 2 * L.pad + hcol, ly + 1, fit(ln.text or '', tw), U.GREY)
  end
end

return D
