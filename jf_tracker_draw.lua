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
-- 19 окт: бросок файлов на рэк — подсветка ячеек, куда лягут: под мышью и (несколько отмеченных) N нот с неё
-- D.drop_note — нота под мышью прошлого кадра; info.drag_n — сколько файлов летит
function D.drop_lit(info, note, hot)
  if not info.dragging then D.drop_note = nil; return false end
  if hot then return true end
  local n0, n = D.drop_note, info.drag_n or 1
  return n0 ~= nil and note ~= nil and n > 1 and note >= n0 and note < n0 + n
end
function D.drop_mark(x, y, w, h)
  U.set(U.tint(U.AMBER, 0.35)); gfx.rect(x, y, w, h, 1)
  U.set(U.AMBER); gfx.rect(x, y, w, h, 0); gfx.rect(x + 1, y + 1, w - 2, h - 2, 0)
end
local function hint(kind, x, y, w, h, data) if D.hint then D.hint(kind, x, y, w, h, data) end end
-- рамка выделения Ctrl-мыши (Cmd+щелчок, 8 окт) — объявлена до всех рисовальщиков
local function csel_frame(x, y, w, h) U.set(U.CYAN); gfx.rect(x, y, w, h, 0) end
local ms, TH   -- объявлены ниже (set_font)
local EMPTY = { '...', '..', '..' }   -- пустые поля ячейки (16 окт: наверху — раскладка меняет ширину ноты)

function D.init(u, peaks_fn, matrix)
  U, get_peaks, MX = u, peaks_fn, matrix
  -- общие примитивы для матрицы/браузера/слайсера — через масштабируемый текст
  U.text = function(x, y, str, col, bg) D.text(x, y, str, col, bg) end
  U.textc = function(x, y, w, str, col) D.text(x + (w - ms(str)) / 2, y, str, col) end
  U.textr = function(x, y, w, str, col) D.text(x + w - ms(str), y, str, col) end
  U.measure, U.texth = ms, TH
  U.hint_text, U.hint_colors = D.hint_text, D.hint_colors   -- 15 окт: стандарт подсказок для модулей
  -- контраст ярче: текст тянем к 7:1 (U — копия модуля, jf_looper не трогаем)
  U.TEXT = U.readable(U.TEXT, U.BG, 7.0)
  U.GREY = U.mix(U.TEXT, U.BG, 0.40)
  U.CYAN = U.readable(U.CYAN, U.BG, 4.5)
  D.PEAK  = U.readable(U.theme('col_tr1_peaks', { 0.55, 0.62, 0.70 }), U.BG, 4.0)
  D.PEAKM = U.mix(D.PEAK, U.BG, 0.55)
  -- 16 окт: волна фоном — от фона к тексту (видна всегда, тише цифр); было от цвета пиков темы — на заливке item пропадала
  D.PEAKB, D.PEAKMB = U.mix(U.BG, U.TEXT, 0.30), U.mix(U.BG, U.TEXT, 0.15)   -- волна фоном (3 окт)
  D.BAR   = U.mix(U.BG, U.TEXT, 0.62)
  D.BEAT  = U.DIM
  -- плейхед (8 окт): цвет курсора воспроизведения темы REAPER (playcursor_color),
  -- строка — намёком; хвост — сыгранные строки выше, тают (Options: playhead tail)
  -- 9 окт: строка — янтарь ярче, хвост — градиент того же цвета
  D.PLAYC = U.AMBER
  D.PLAY  = U.tint(U.AMBER, 0.36)
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
  -- 11 окт: цвета колонок как в Renoise (Default.xrnc: Pattern_Default_Font_*), контраст к фону темы:
  -- нота и инструмент — текстом, громкость жёлтая, delay голубой, слайс / смещение сэмпла — Other (лиловый)
  local function rn(r, g, b) return U.readable({ r / 255, g / 255, b / 255 }, U.BG, 3) end
  D.RN_VOL, D.RN_PAN, D.RN_DELAY = rn(212, 206, 42), rn(158, 214, 140), rn(66, 193, 234)
  D.RN_PITCH, D.RN_GLOBAL, D.RN_OTHER = rn(180, 80, 34), rn(253, 151, 21), rn(186, 104, 187)
  D.SEP   = U.mix(U.BG, U.TEXT, 0.38)           -- границы модулей: тусклые (3 окт; фокус — ярче)
  D.SEPW  = 2                                   -- толщина границ модулей (3 окт: жирнее), линии внутри модулей — 1 px
  D.FOCUS = U.mix(U.TEXT, { 1, 1, 1 }, 0.55)    -- светлый ободок модуля с фокусом (просьба 1 окт: без розового)
  D.FOCUS_INS = { 1.0, 0.15, 0.1 }              -- та же рамка в INSERT (красная, толще)
  -- 15 окт: цвет режима — рамка поля и слово режима: NORMAL белый, INSERT красный, VISUAL янтарный, ввод команды голубой
  local function cp(c) return { c[1], c[2], c[3] } end   -- копия: своя запись в D.KEEP, не весь янтарь цветной в mono
  D.MODE_COL = { normal = { 1, 1, 1 }, insert = D.FOCUS_INS, visual = cp(U.AMBER), vline = nil, cmd = cp(U.CYAN), search = nil }
  D.light_bg = type(U.BG) == 'table' and (0.2126 * (U.BG[1] or 0) + 0.7152 * (U.BG[2] or 0) + 0.0722 * (U.BG[3] or 0)) > 0.45 or false   -- 20 окт: светлая тема (крупный текст — по альфе)
  -- 20 окт: слово режима — читаемо к панели (светлые темы: белый NORMAL / KEYS пропадал — тянется к тёмному)
  for k, c in pairs(D.MODE_COL) do if c then D.MODE_COL[k] = U.readable(c, U.PANEL, 4.5) end end
  D.MODE_COL.vline, D.MODE_COL.search = D.MODE_COL.visual, D.MODE_COL.cmd
  D.REC = cp(U.RED)                               -- 15 окт: O записи (rec, ^O) — красное и в mono
  D.ENVLINE = U.readable(U.CYAN, U.BG, 4.5)
  -- фон шапки трека (3 окт): как TCP REAPER — col_tr1_bg темы, выделенный —
  -- col_seltrack; цвет трека подмешивается так же (~30 %, сверено по TCP)
  D.HDR = U.HDR or U.theme('col_tr1_bg', U.mix(U.PANEL, U.TEXT, 0.12))
  D.HDRSEL = U.HDRSEL or U.theme('col_seltrack', U.mix(D.HDR, U.TEXT, 0.10))
  -- темы (3 окт, jf_tracker_themes.lua): mono — всё серым, кроме ячейки курсора
  D.mono = U.MONO and true or false
  D.mono_tint = U.MONO_TINT   -- 24 окт: rednight / greennight — серый по яркости в оттенок
  -- цвета кнопок как в REAPER (3 окт): запись — фиолетовая, FX трека — зелёная;
  -- во всех темах, в mono тоже (исключения серого фильтра)
  D.ARM, D.FXG = { 0.66, 0.36, 0.90 }, { 0.40, 0.66, 0.30 }
  -- 6 окт: тинт Theme Tweaker — сдвиг по опорным цветам темы (с правками /
  -- без, флаги 0 / 1) переносится и на запись, и на FX; своих ключей у
  -- кнопок в теме нет (у REAPER это картинки)
  do
    local s0, s1 = { 0, 0, 0 }, { 0, 0, 0 }
    for _, k in ipairs({ 'col_tr1_bg', 'col_tr2_bg', 'col_seltrack', 'col_env1', 'col_main_bg2', 'col_main_text2' }) do
      local ok0, a = pcall(reaper.GetThemeColor, k, 1)
      local ok1, b = pcall(reaper.GetThemeColor, k, 0)
      if ok0 and ok1 and a and b and a >= 0 and b >= 0 then
        local r0, g0, b0 = reaper.ColorFromNative(a)
        local r1, g1, b1 = reaper.ColorFromNative(b)
        s0[1], s0[2], s0[3] = s0[1] + r0, s0[2] + g0, s0[3] + b0
        s1[1], s1[2], s1[3] = s1[1] + r1, s1[2] + g1, s1[3] + b1
      end
    end
    local function tw(c)
      local o = {}
      for i = 1, 3 do o[i] = math.max(0, math.min(1, c[i] * math.max(0.25, math.min(4, (s1[i] + 8) / (s0[i] + 8))))) end
      return o
    end
    D.ARM, D.FXG = tw(D.ARM), tw(D.FXG)
  end
  D.ARM_T, D.FXG_T = U.mix(U.PANEL, D.ARM, 0.55), U.mix(U.PANEL, D.FXG, 0.85)
  D.FXTXT = { 0.94, 1.0, 0.90 }                -- светлый текст на зелёном, как FX в REAPER
  D.KEEP = { [D.ARM] = true, [D.ARM_T] = true, [D.FXG] = true, [D.FXG_T] = true, [D.FXTXT] = true,
             [D.MODE_COL.visual] = true, [D.MODE_COL.cmd] = true, [D.REC] = true }   -- 15 окт: цвета режимов и O записи
  D.SL_DIM = U.mix(U.TEXT, U.BG, 0.1)   -- 28 окт: виджеты невыбранных параметров DSP
  D.CURCELL = D.CUR_ACC or U.MONO_CURSOR or U.TEXT   -- 28 окт: курсор в фокусе — акцентом (опция cursor accent)
  if D.acc_apply then D.acc_apply() end
  D.OFFKEY = U.readable(U.mix(U.RED, U.TEXT, 0.35), U.BG, 4.0)   -- 21 окт: нота вне лада (с проверкой контраста)
  U.set = function(c, a) D.set(c, a) end           -- матрица / браузер / слайсер — через тот же фильтр
end

-- шрифт: 0 — битмап REAPER (масштаб ×N пиксель-в-пиксель через кеш строк и
-- gfx.blit — тот самый PT2-вид), N>0 — TTF моноширинный размера N.
-- D.SPACE — зазор над буквами в строке (`:space`), входит в высоту строки.
D.SCALE, D.SPACE = 1, 2
local tcache, next_img = {}, 100
-- номера картинок gfx — только 0..1023 (1200+ молча не создаются: так 2 окт пропали
-- вертикальные имена матрицы и подписи линейки). 100..799 текст, 800..959
-- вертикальный текст, 960..1017 спектрограммы анализатора, 1018..1019 лупа big fixed cursor, 1022 логотип about, 1023 черновик поворота
-- 86 замер глифов SMuFL (стан harmonizer), 89 схема роутера DSP (dspbig), 90..97 спектрограммы вкладки item (jf_tracker_sgram), 99 главный модуль; номера gfx — только 0..1023
local IMG_FIRST, IMG_LAST = 100, 796   -- 16 окт: 797 — чистый кадр fps-буфера (наложения не копятся); 10 окт: 799 — превью шрифтов вкладки theme (90..97 — спектрограммы); 11 окт: 798 — буфер панели (pn_buffered)
-- кольцо картинок текста (6 окт): по половинам — при входе в половину
-- выселяются только её строки (и их ×2-копии e.ov); раньше переполнение
-- сбрасывало весь кэш, и экран из сотен строк (pm cards) перезапекался
-- целиком каждые пару секунд — пики кадра 20 мс
local IMG_MID = IMG_FIRST + (IMG_LAST - IMG_FIRST + 1) // 2
local function tc_alloc()
  if next_img > IMG_LAST then next_img = IMG_FIRST end
  if next_img == IMG_FIRST or next_img == IMG_MID then
    local lo, hi = next_img, (next_img == IMG_FIRST) and (IMG_MID - 1) or IMG_LAST
    for str, t in pairs(tcache) do
      for k, v in pairs(t) do
        if v.id >= lo and v.id <= hi then t[k] = nil
        elseif v.ov and v.ov >= lo and v.ov <= hi then v.ov = nil end
      end
      if next(t) == nil then tcache[str] = nil end
    end
  end
  local id = next_img; next_img = next_img + 1
  return id
end

-- пиксельные TTF (5 окт, опция font): кириллица, греческий, блоки, рамки —
-- без гибрида; px — родной размер (кегль = px × масштаб — чётко)
-- 10 окт: больше терминальных моноширинных (все — Nerd Fonts, уже стоят у
-- пользователя); D.TTF_LIST — порядок в опции font: пиксельные, потом векторные
D.TTF_FACES = {
  bigblue = { face = 'BigBlueTermPlus Nerd Font Mono', px = 12, d = 'BigBlueTerm+, pixel DOS, by VileR (int10h.org), bundled' },   -- DOS 8×12 (Departure и Gohu не прижились, 5 окт)
  bb437 = { face = 'BigBlueTerm437 Nerd Font Mono', px = 12, d = 'BigBlueTerm 437, pixel IBM PC code page, by VileR (int10h.org), bundled' },
  departure = { face = 'DepartureMono Nerd Font Mono', px = 11, d = 'Departure Mono, pixel, by Helena Zhang & Tobias Fried, bundled' },
  gohu11 = { face = 'GohuFont 11 Nerd Font Mono', px = 11, d = 'Gohu 11, pixel X11 terminal, by Hugo Chargois, bundled' },
  gohu14 = { face = 'GohuFont 14 Nerd Font Mono', px = 14, d = 'Gohu 14, pixel X11 terminal, by Hugo Chargois, bundled' },
  terminess = { face = 'Terminess Nerd Font Mono', px = 12, d = 'Terminus, the Linux console font, by Dimitar Zhekov, bundled' },
  proggy = { face = 'ProggyClean Nerd Font Mono', px = 13, d = 'ProggyClean, pixel, by Tristan Grimmer, bundled' },
  profont = { face = 'ProFont IIx Nerd Font Mono', px = 12, d = 'ProFont, classic Mac terminal, bundled' },
  ['3270'] = { face = '3270 Nerd Font Mono', px = 14, d = 'IBM 3270 terminal, by Ricardo Banffy, bundled' },
  shure = { face = 'ShureTechMono Nerd Font Mono', px = 14, d = 'Share Tech Mono, techy' },
  monocraft = { face = 'Monocraft', px = 12, d = 'Monocraft, Minecraft-like pixel' },
  iosevka = { face = 'IosevkaTerm Nerd Font Mono', px = 14, d = 'Iosevka Term, narrow vector, the most symbols' },        -- вектор, узкий, 7429 символов
  iosevkaslab = { face = 'IosevkaTermSlab Nerd Font Mono', px = 14, d = 'Iosevka Term Slab, narrow with serifs' },
  jetbrains = { face = 'JetBrainsMono Nerd Font Mono', px = 14, d = 'JetBrains Mono' },
  hack = { face = 'Hack Nerd Font Mono', px = 14, d = 'Hack' },
  fira = { face = 'FiraMono Nerd Font Mono', px = 14, d = 'Fira Mono' },
  inconsolata = { face = 'Inconsolata Nerd Font Mono', px = 14, d = 'Inconsolata' },
  commit = { face = 'CommitMono Nerd Font Mono', px = 14, d = 'Commit Mono' },
  plex = { face = 'BlexMono Nerd Font Mono', px = 14, d = 'IBM Plex Mono' },
  cascadia = { face = 'CaskaydiaMono Nerd Font Mono', px = 14, d = 'Cascadia Mono' },
  geist = { face = 'GeistMono Nerd Font Mono', px = 14, d = 'Geist Mono' },
  victor = { face = 'VictorMono Nerd Font Mono', px = 14, d = 'Victor Mono, narrow' },
  space = { face = 'SpaceMono Nerd Font Mono', px = 14, d = 'Space Mono, wide retro' },
  ubuntu = { face = 'UbuntuMono Nerd Font Mono', px = 14, d = 'Ubuntu Mono, narrow' },
  mononoki = { face = 'Mononoki Nerd Font Mono', px = 14, d = 'mononoki' },
  proto = { face = '0xProto Nerd Font Mono', px = 14, d = '0xProto' },
  monaspace = { face = 'MonaspiceNe Nerd Font Mono', px = 14, d = 'Monaspace Neon' },
}
D.TTF_LIST = { 'bigblue', 'bb437', 'departure', 'gohu11', 'gohu14', 'terminess', 'proggy', 'profont', '3270', 'shure', 'monocraft',
  'iosevka', 'iosevkaslab', 'jetbrains', 'hack', 'fira', 'inconsolata', 'commit', 'plex', 'cascadia', 'geist', 'victor', 'space', 'ubuntu', 'mononoki', 'proto', 'monaspace' }
function D.set_font(state)
  local tf = D.TTF_FACES[state.ttf or 'off']
  -- 10 окт: свой шрифт — любое установленное семейство по имени (:font Имя [px])
  if state.ttf == 'custom' and (state.ttfcustom or '') ~= '' then tf = { face = state.ttfcustom, px = tonumber(state.ttfpx) or 14 } end
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
  -- 11 окт: мелкий шрифт (метры, подписи колонок) — всегда x1: битмап без масштаба,
  -- TTF — родной кегль; при x1 он равен обычному
  D.SMALL = D.ttf and math.min(1, D.ttf_px / math.max(1, D.ttf_size)) or 1 / D.SCALE
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
-- 16 окт: знак MIDI в lib — µ (битмап без глифов его не рисует — там u)
function D.mu() return (D.ttf or D.hybrid) and 'µ' or 'u' end
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
-- 21 окт: память — гибридный шрифт режет строку с глифами на каждый text() каждый кадр (заметный мусор)
local SEGC, SEGN = {}, 0
local function segments(str)
  local hit = SEGC[str]
  if hit then return hit end
  if SEGN > 4000 then SEGC, SEGN = {}, 0 end
  SEGN = SEGN + 1
  local out, ascii = {}, {}
  SEGC[str] = out
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
  -- 21 окт: ключ — строка, затем число цвета и фона (24 бита каждый): склейка строки-ключа на каждый text()
  -- была главным мусором кадра (сотни строк × 6 чисел в строки)
  local c24 = math.floor(col[1] * 255) * 65536 + math.floor(col[2] * 255) * 256 + math.floor(col[3] * 255)
  local key = c24 * 67108864 + (bg and (math.floor(bg[1] * 255) * 65536 + math.floor(bg[2] * 255) * 256 + math.floor(bg[3] * 255)) or (16777216 + (D.light_bg and 1 or 0)))
  local ts = tcache[str]
  local e = ts and ts[key]
  if e then return e end
  gfx.setfont(D.font_id)
  local w, h = measure_raw(str) + 2, gfx.texth            -- +2 (6 окт): при ×1.5 правый столбец буквы (O) срезался
  local id = tc_alloc()
  -- строка с глифами: картинка на 2 px ниже — хвосты р у щ не срезаются
  local hi = (D.hybrid and str:find('[\128-\255]')) and (h + 2) or h
  gfx.setimgdim(id, w, hi)
  local old = gfx.dest
  gfx.dest = id
  -- 20 окт: светлая тема без подложки — фон картинки прозрачный (a2 = 0), вывод обычным наложением по альфе:
  -- сложение (mode 1) чёрного фона с текстом на светлом окне давало белый текст (kcast, крупные надписи)
  local clear = not bg and D.light_bg
  if bg then gfx.set(bg[1], bg[2], bg[3], 1) else gfx.set(0, 0, 0, 1) end
  if clear then gfx.a2 = 0 end
  gfx.rect(0, 0, w, hi, 1)
  gfx.a2 = 1
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
  e = { id = id, w = w, h = hi, clear = clear }
  if not ts then ts = {}; tcache[str] = ts end
  ts[key] = e
  return e
end

-- ── раскладка ─────────────────────────────────────────────────────────────
-- панели (9 окт): раскладка дерева — мемо по сигнатуре (модель, окно, шрифт,
-- доступность панелей); в кадре — только сравнения, без аллокаций
D.pn_M = { sep = 1, grip = 5 }
D.pn_sig = {}
function D.panes_layout(state, L, nregions, ncols)
  local M, s = D.pn_M, D.pn_sig
  local m = state.panes
  if m then D.panes.pin_mixer(m); D.panes.pin_sprops(m) end   -- 11 окт: и properties — всегда своей панелью у item   -- 11 окт: mixer — всегда прямо под трекером (полоски — под его колонками)
  local H = gfx.h - L.status_h
  local sl, gr, dv = state.slices_on and 1 or 0, state.gridtab and 1 or 0, state.dev and 1 or 0
  local mxa = (state.mixer and state.mixpos == 'bottom') and 1 or 0
  -- 10 окт: properties — только когда вкладка item активна в своём стеке
  local it = 0
  do local lf = D.panes.find(m, 'sample'); if state.propsitem == false or (lf and lf.panes[lf.active] == 'sample') then it = 1 end end   -- опция properties with item
  if state.sp_none then it = 0 end                      -- 11 окт: сэмпла нет — нечего показывать
  local lo = state.loop_on and 1 or 0
  if D.pn_lay and s.m == m and s.v == m.v and s.w == gfx.w and s.h == H and s.rh == L.rh and s.cw == L.cw and s.sl == sl and s.gr == gr and s.dv == dv and s.it == it and s.lo == lo and s.mxa == mxa and s.ab == (state.tababc and 1 or 0) and s.hi == D.hint_mode(state) then
    return D.pn_lay
  end
  s.m, s.v, s.w, s.h, s.rh, s.cw, s.sl, s.gr, s.dv = m, m.v, gfx.w, H, L.rh, L.cw, sl, gr, dv
  s.ab = state.tababc and 1 or 0
  s.it = it
  s.lo = lo
  s.mxa = mxa
  s.hi = D.hint_mode(state)
  if state.tababc then D.panes.sort_stacks(m) end
  M.rh, M.cw, M.pad = L.rh, L.cw, L.pad
  D.TABGAP = 3                                           -- 19 окт: пустота над вкладками — панели видно отдельно
  M.tab_h = L.rh + 2 + D.TABGAP                         -- подпись листа — вкладкой над рамкой
  M.hint_h = (state.hints and state.hintpos == 'panes') and (L.rh + 1) or 0   -- 10 окт: строка клавиш под каждой панелью (hints where)
  M.hint_trk = (state.hints and state.hintpos == 'tabs') and (L.rh + 1) or nil   -- 15 окт: tabs — подсказки в строке вкладок; у трекера вкладок нет — его строка внизу
  M.tabw = function(id) return ms(D.ic(id, D.panes.BY[id].label)) end
  -- item: все параметры сэмпла в две колонки + строка заголовка + строки кнопок вкладки
  M.minh = function(id)
    if id == 'sample' and D.sprops_rows then return (math.ceil(D.sprops_rows / 2) + 1) * L.rh + 2 * L.rh + 10 end
    if id == 'mixer' then return 8 * L.rh end           -- 11 окт: фейдер и кнопки читаемы
  end
  M.avail = function(id)
    local p = D.panes.BY[id]
    local a = p and p.avail
    if a == 'itemtab' then return it == 1 end
    if a == 'slices_on' then return sl == 1 elseif a == 'gridtab' then return gr == 1 elseif a == 'dev' then return dv == 1 end
    if a == 'mixer' then return mxa == 1 end            -- 11 окт: модуль mixer — когда микшер включён и он снизу
    if a == 'merged' then return false end              -- 18 окт: modulation — страница automation
    return true
  end
  D.pn_lay = D.panes.layout(m, gfx.w, H, M, D.top_inset or 0)   -- 28 окт: без рамки — всё на 1 px ниже (верхняя линия видна)
  return D.pn_lay
end

function D.layout(snap, state, nregions)
  -- модули вплотную (8 окт: опция module gap убрана — она обрезала модули):
  -- между соседями одна линия 1 px; активный — рамка внутри своих границ
  D.SEPW = 1
  D.SEP = U.mix(U.BG, U.TEXT, 0.38)
  gfx.setfont(D.font_id)
  local L = {}
  L.th = TH()
  L.rh = L.th + 2 + D.SPACE + (D.SCALE % 1 ~= 0 and 1 or 0)   -- x1.5 (5 окт): +1 px снизу текста в кнопках
  L.pad = ms(' ')
  if L.pad < 2 then L.pad = math.max(3, math.floor(ms('W') / 2)) end
  L.cw = ms('W')
  L.w_note = ms(D.micro and 'C#4^^' or 'C#4')   -- 16 окт: микротоны — метка ^ / v после октавы (2 знака)
  EMPTY[1] = D.micro and '.....' or '...'
  L.w_vol = ms('FF')
  L.w_del = ms('FF')
  L.w_fx = ms('0UFF')                -- 12 окт: код из двух символов, как в Renoise
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
  -- 11 окт: номер слайса — своё поле после инструмента (нота | инструмент | слайс | vol), hex как в списке слайсов
  -- 21 окт: отдельной колонки слайса нет — слайс это команда 0Sxx в колонке fx (как в Renoise); показ — draw_cell
  L.w_slc = ms('S00')
  L.x_slc = false
  L.x_vol = L.x_inst + L.w_inst + L.pad
  -- порядок: волна | нота | инстр. | vol | fx1..n | delay (просьба 1 окт)
  -- 14 окт: колонка пана (опция pan column) — сразу за громкостью, hex 00..FF, 80 — центр
  L.w_pan = ms('00')
  L.x_pan = state.pancol and (L.x_vol + L.w_vol + L.pad) or false
  L.x_fx = {}
  local x = L.x_pan and (L.x_pan + L.w_pan + L.pad) or (L.x_vol + L.w_vol + L.pad)
  for k = 1, L.nfx do L.x_fx[k] = x; x = x + L.w_fx + L.pad end
  L.x_del = x
  x = L.x_del + L.w_del + L.pad
  -- 19 окт: fold — узкая колонка знака «o» справа (строка со сложенными быстрыми нотами)
  -- 27 окт: вместо колонки +N справа — знак «+» перед нотой (как папка в lf); место только у лейнов со сложенным (L.foldG)
  L.fold_on = state.foldfast and true or false; L.x_fold = nil; L.w_fold = ms('+')
  L.envmark = state.envmark and true or false   -- 27 окт: «~» строк с автоматизацией — в той же колонке
  L.sub_w = x
  -- узкая подколонка (2 окт): ноты аккорда MIDI — только нота и velocity,
  -- без волны, fx и delay; отдельный лейн — только фиксированная дорожка REAPER
  L.sub_w_narrow = L.pad + L.w_note + L.pad + L.w_vol + L.pad
  L.GN = setmetatable({ narrow = true, w_wave = 0, nfx = 0, x_wave = L.pad, x_note = L.pad, x_inst = false, x_slc = false, x_pan = false,
    x_vol = L.pad + L.w_note + L.pad, x_fx = {}, x_del = L.pad + L.w_note + L.pad, sub_w = L.sub_w_narrow }, { __index = L })
  -- свёрнутый трек (fold, 2 окт): только волна и нота; ноты аккорда — только нота;
  -- огибающие — узкая схема: линия в символ шириной + hex значения точек
  L.sub_w_compact = L.x_note + L.w_note + L.pad
  L.GC = setmetatable({ notes_only = true, nfx = 0, x_inst = false, x_slc = false, x_pan = false, x_fx = {}, x_vol = L.x_note, x_del = L.x_note, sub_w = L.sub_w_compact }, { __index = L })
  L.sub_w_compact_n = L.pad + L.w_note + L.pad
  L.GCN = setmetatable({ notes_only = true, narrow = true, w_wave = 0, nfx = 0, x_wave = L.pad, x_note = L.pad, x_inst = false, x_slc = false, x_pan = false, x_fx = {},
    x_vol = L.pad, x_del = L.pad, sub_w = L.sub_w_compact_n }, { __index = L })
  -- 21 окт: свёрнутый чистый MIDI-трек — вместо пустой колонки волны номер инструмента и громкость: нота | инстр. | vol
  do
    local xi = L.pad + L.w_note + L.pad
    local xv = xi + L.w_inst + L.pad
    L.GCM = setmetatable({ narrow = true, w_wave = 0, nfx = 0, x_wave = L.pad, x_note = L.pad, x_inst = xi, x_slc = false, x_pan = false, x_fx = {},
      x_vol = xv, x_del = xv, x_fold = false, nfields = 2, sub_w = xv + L.w_vol + L.pad }, { __index = L })
  end
  -- 19 окт: трек кита drumrs5k — без поля Sxx (пэд = нота): поля правее него сдвинуты влево.
  -- L.kitG(G) — кит-вариант любой раскладки с полем слайса (обычная, уровни ширины GL), кэш на раскладку
  L.GKc = setmetatable({}, { __mode = 'k' })
  -- 20 окт: лейн с take FX у нот — после ноты значок fx (зелёная рамка, как кнопка FX item в REAPER): поля правее
  -- сдвинуты на его ширину; у остальных лейнов места не резервируется
  L.w_tfx = ms('fx') + 4
  L.GTc = setmetatable({}, { __mode = 'k' })
  function L.tfxG(G)
    G = G or L
    if not G.x_inst or G.notes_only or G.narrow or G.wave_only then return G end
    local k = L.GTc[G]
    if k then return k end
    local s0, d = G.x_note + (G.w_note or L.w_note), L.w_tfx + L.pad
    local function sh(v) if v and v >= s0 then return v + d end return v end
    local fx2 = {}
    for n, v in ipairs(G.x_fx or {}) do fx2[n] = sh(v) end
    k = setmetatable({ x_tfx = s0 + L.pad, x_inst = sh(G.x_inst), x_slc = G.x_slc and sh(G.x_slc) or G.x_slc, x_vol = sh(G.x_vol),
      x_pan = G.x_pan and sh(G.x_pan) or G.x_pan, x_fx = fx2, x_del = sh(G.x_del), x_fold = G.x_fold and sh(G.x_fold) or G.x_fold,
      sub_w = G.sub_w + d }, { __index = G })
    L.GTc[G] = k
    return k
  end
  -- 27 окт: лейн со сложенными нотами — узкая колонка «+» перед нотой, поля от ноты правее на её ширину; кэш на раскладку
  L.GFc = setmetatable({}, { __mode = 'k' })
  -- 27 окт (2): в лейне и сложенные ноты, и автоматизация — строка низкая: колонка в два знака «+~»; высокая — «~» под «+»
  L.fold2_tall = L.rh >= 2 * L.th
  L.GFc2 = setmetatable({}, { __mode = 'k' })
  function L.foldG(G, both)
    G = G or L
    local wide = both and not L.fold2_tall
    local cache = wide and L.GFc2 or L.GFc
    local k = cache[G]
    if k then return k end
    -- 27 окт (6): колонка «+ ~» — справа у подколонки (сложенное раскладывается вправо), поля не сдвигаются
    local d = (wide and ms('+~') or L.w_fold) + L.pad
    k = setmetatable({ x_fold = G.sub_w - L.pad + 1, sub_w = G.sub_w + d, fold_wide = wide or nil }, { __index = G })
    cache[G] = k
    return k
  end
  -- 21 окт: чистый MIDI-трек (ни аудио в лейне, ни сэмплов в lib, не кит) — без колонки волны: поля левее на её ширину
  L.GWc = setmetatable({}, { __mode = 'k' })
  function L.nowaveG(G)
    G = G or L
    if not ((G.w_wave or 0) > 0) or G.wave_only then return G end
    local k = L.GWc[G]
    if k then return k end
    local d = G.w_wave + L.pad
    local function sh(v) if v then return v - d end return v end
    local fx2 = {}
    for n, v in ipairs(G.x_fx or {}) do fx2[n] = sh(v) end
    k = setmetatable({ w_wave = 0, x_note = sh(G.x_note), x_inst = G.x_inst and sh(G.x_inst) or false, x_slc = G.x_slc and sh(G.x_slc) or false,
      x_vol = sh(G.x_vol), x_pan = G.x_pan and sh(G.x_pan) or false, x_fx = fx2, x_del = sh(G.x_del),
      x_fold = G.x_fold and sh(G.x_fold) or G.x_fold, x_tfx = G.x_tfx and sh(G.x_tfx) or G.x_tfx, sub_w = G.sub_w - d }, { __index = G })
    L.GWc[G] = k
    return k
  end
  function L.kitG(G)
    G = G or L
    if not G.x_slc or G.notes_only then return G end
    local k = L.GKc[G]
    if k then return k end
    local s0, d = G.x_slc, (G.w_slc or L.w_slc) + L.pad
    local function sh(v) if v and v > s0 then return v - d end return v end
    local fx2 = {}
    for n, v in ipairs(G.x_fx or {}) do fx2[n] = sh(v) end
    k = setmetatable({ x_slc = false, x_vol = sh(G.x_vol), x_pan = G.x_pan and sh(G.x_pan) or false, x_fx = fx2, x_del = sh(G.x_del),
      x_fold = G.x_fold and sh(G.x_fold) or G.x_fold, sub_w = G.sub_w - d }, { __index = G })
    L.GKc[G] = k
    return k
  end
  L.fold_w = ms('o') + 2 * L.pad
  L.chord_w = ms('G#maj7/C') + 2 * L.pad              -- лейн аккордов (:chord, 8 окт)
  -- уровни ширины колонки (7 окт): колесо (высота трека REAPER при sync
  -- header) шагает по одному полю: 0 полоска, 1 нота, 2 + vol, 3 + delay,
  -- 4..7 + fx-колонки по одной, дальше + подколонки нот; автоматизация — когда
  -- колонка шире 50 знаков. GL[k] — раскладка подколонки уровня k (1..7)
  L.MAXFX = 4
  L.MAXLVL = 3 + L.MAXFX + 3
  L.GL = { [1] = L.GC }
  local function fold_tail(t, xx) t.x_fold = false; t.sub_w = xx end
  L.GL[2] = { narrow = true, nfx = 0, x_fx = {}, x_del = L.x_vol + L.w_vol + L.pad, nfields = 2 }
  fold_tail(L.GL[2], L.x_vol + L.w_vol + L.pad)
  setmetatable(L.GL[2], { __index = L })
  for k = 0, L.MAXFX do
    local t = { nfx = k, x_fx = {}, nfields = 3 + k }
    local xx = L.x_vol + L.w_vol + L.pad
    for i = 1, k do t.x_fx[i] = xx; xx = xx + L.w_fx + L.pad end
    t.x_del = xx; fold_tail(t, xx + L.w_del + L.pad)
    L.GL[3 + k] = setmetatable(t, { __index = L })
  end
  -- 11 окт: wave only — аудио-подколонка полосой волны; ширина по зуму трека (кэш по ширине)
  L.GW = {}
  L.waveonly_on = state.waveonly and not state.textonly   -- не wave_only: его унаследовали бы все геометрии (__index = L)
  L.env_hex_w = ms(state.envfmt == 'hex' and 'FF' or '127')   -- формат значений (6 окт)
  L.env_bar_w = ms('WWWW')
  -- поле формы сегмента (2 окт): lin sqr slo fas fae bez — справа от значения
  -- форма сегмента (2 окт, правка): не отдельной колонкой, а под значением точки
  -- и только если не lin — правая часть колонки шириной в «bez»
  L.env_shape_w = ms('bez')
  -- дорожка кривой — за ручкой automation item (6 окт: минимум кривой падал в ручку)
  L.env_bx = L.th + 5             -- 6 окт: на пиксель ближе к ручке
  L.env_w = L.env_bx + L.env_bar_w + L.pad + math.max(L.env_hex_w, L.env_shape_w) + L.pad
  L.env_cw = L.env_bx + L.cw + L.pad + L.env_hex_w + L.pad
  L.GE = setmetatable({ env_bar_w = L.cw, env_compact = true }, { __index = L })
  -- 24 окт: узкая колонка по умолчанию — 3 знака значения (вид values) и тонкая ручка automation item слева
  L.G3 = setmetatable({ env_bx = 4, env_bar_w = ms('000'), env_compact = true, env3 = true }, { __index = L })
  L.env3_w = 4 + ms('000') + 2 * L.pad
  -- ширина браузера: перетащенная мышью (state.side_px) или по кнопке <>
  L.side_w = state.side and (state.side_px or (L.cw * (state.sidenarrow and 20 or 36) + 2 * L.pad)) or 0
  -- браузер слева (7 окт, опция browserleft): lib + браузер — в левой колонке
  -- над матрицей, справа сайдбара нет (трекер шире)
  L.browser_left = state.browserleft and L.side_w > 0 or false
  L.lside_w = L.browser_left and L.side_w or 0          -- справа остаются инструменты и слайсы
  -- правая панель свёрнута — узкая полоса с кнопкой < (2 окт)
  L.rstrip_w = state.side and 0 or (ms('<') + 2 * L.pad + 6)
  -- модуль слайсов (4 окт): колонка в верхней панели справа (у lib), по её
  -- высоте — не на всё окно; пока у выбранного инструмента есть слайсы
  L.slices_split = state.slices_on and state.slicespos == 'split' and state.side   -- половина модуля инструментов (опция slices)
  L.slices_w = (state.slices_on and state.top and not L.slices_split) and math.max(L.cw * 16, math.min(L.cw * 20, math.floor(gfx.w * 0.12))) or 0
  L.win_w = gfx.w - L.side_w - L.rstrip_w
  L.side_x = L.win_w                               -- левый край сайдбара / полосы
  L.matrix_w = MX and MX.width(L, nregions or 0, #snap.cols) or 0
  if L.browser_left then L.matrix_w = math.max(L.matrix_w, L.lside_w + D.SEPW) end
  -- матрица: свёрнута — узкая полоса с кнопкой >; ширина мышью (ручка = на линии раздела)
  L.mx_strip_w = ms('>') + 2 * L.pad + 6
  if state.mx_hidden then L.matrix_w = L.mx_strip_w
  elseif MX and MX.fold and state.mx_fold_px then L.matrix_w = math.max(L.cw * 6, (MX.btns_w or 0) + L.pad, math.min(math.floor(gfx.w * 0.6), state.mx_fold_px))   -- fold: своя ширина мышью
  elseif state.mx_px and MX and not MX.fold then L.matrix_w = math.max((MX.btns_w or 0) + L.pad + ms('>') + 2 * L.pad + 6, math.min(math.floor(gfx.w * 0.6), state.mx_px)) end
  -- линейка слева от номеров строк (2 окт): имена регионов и маркеров
  -- горизонтально на своих строках, цвет регионов — как линейка REAPER
  -- две узкие дорожки с вертикальным текстом: регионы (полоса цвета) и маркеры
  L.rg_w = (state.ruler == false) and 0 or (2 * (L.th + 6) + L.pad + 2)   -- +2: зазор от разделителя матрицы
  -- 10 окт: линейка прыжков по строкам (relativenumber Vim) — колонка на 2 цифры
  -- левее полосы регионов; регионы сдвигаются на неё
  L.jl_w = state.rowjumps and (ms('99') + L.pad + 2) or 0
  L.ruler_w = L.jl_w + L.rg_w
  -- линейка таймлайна между полосами регионов и номерами (3 окт, опция tlruler): метки REAPER
  -- на долях — beats (такт.доля), time (время), both
  local tlr = state.tlruler or 'off'
  -- 20 окт: united stepruler — такт.доля в колонке номеров (beats там не нужен; both → только time)
  L.united = state.unitedruler and true or false
  L.relwave = state.relwave and true or false
  if L.united and tlr == 'beats' then tlr = 'off' elseif L.united and tlr == 'both' then tlr = 'time' end
  L.tlr = tlr
  L.tl_w = (tlr == 'beats' and ms('999.4') + L.pad) or (tlr == 'time' and ms('0:00.000') + L.pad)
    or (tlr == 'both' and ms('999.4') + ms('0:00.000') + 2 * L.pad) or 0
  L.num_w = math.max(ms('0000'), L.united and ms('999.4') or 0) + 2 * L.pad
  -- 13 окт: линейка (регионы / маркеры, прыжки) — слева от номеров или справа, у мастера (опция ruler side)
  L.ruler_right = state.rulerside == 'right' and L.rg_w > 0
  L.rl = L.ruler_right and L.jl_w or L.ruler_w   -- 13 окт: линейка прыжков всегда слева, у номеров;           -- что слева от номеров строк
  L.label_w = L.rl + L.num_w + L.tl_w
  -- верхняя панель (как в Renoise 2): контрол | скоупы | инструменты трека
  -- верхняя панель: +15 % (просьба 1 окт) — место под монтаж mono-модуля
  -- 5 окт: на 15% выше (больше строк свойств сэмпла)
  L.top_h = state.top and (state.top_px or math.max(5 * L.rh + 8, math.min(math.floor(11 * L.rh * 1.15), math.floor(gfx.h * 0.19 * 1.15)))) or 0
  if state.top and state.top_px then L.top_h = math.max(4 * L.rh + 8, math.min(math.floor(gfx.h * 0.5), state.top_px)) end
  -- большой редактор сэмпла (3 окт, :big): вкладка item на всю высоту окна
  if state.top and state.sample_big and state.toptab == 'sample' then L.top_h = math.max(L.top_h, gfx.h - (L.rh + 4) - 2) end
  L.pool_h = L.top_h
  L.ctrl_w = L.cw * 30 + 2 * L.pad
  L.inst_w = state.side and 0 or (L.cw * 32 + 2 * L.pad)
  -- положение верхнего модуля (3 окт): top — над трекером, mid — над DSP,
  -- bottom — под DSP; статус-бар: bottom — низ окна, tracker — строка в модуле трекера
  L.toppos = (state.toppos == 'mid' or state.toppos == 'bottom' or state.toppos == 'clips') and state.toppos or 'top'   -- 8 окт: clips — под клипами, над строками трекера
  -- 15 окт: как в Emacs — индикатор режима (modeline) в полосе трекера, строка статуса (echo area) всегда
  -- внизу окна; опции положения нет
  -- статус в пианинке (5 окт): третья строка полосы; клавиатура спрятана (m) —
  -- статус внизу окна
  L.kbstat = false                                    -- 15 окт: режима в полосе нет — модлайн в поле трекера, полоса компактнее
  -- положение полосы транспорта (5 окт): tracker — под трекером (как было),
  -- top — во всю ширину над верхней панелью, bottom — под DSP над статусом;
  -- снаружи трекера — со своей строкой подсказок под ней
  L.tppos = (state.transpos == 'top' or state.transpos == 'bottom') and state.transpos or 'tracker'
  L.tp_h = L.tppos ~= 'tracker' and ((2 * L.rh + 6 + (L.kbstat and (2 * L.rh + 2) or 0)) + (state.hints and (L.rh + 1) or 0) + (state.tpstyle == 'full' and (2 * L.rh + 6) or 0)) or 0   -- 15 окт: full — 4 строки   -- 11 окт: full — строка |<< freeze slow >>| dub
  L.top_first = L.toppos == 'top'
  L.jr_h = state.jumps and L.rh or 0
  D.jr_bg = state.jrbg                                -- 10 окт: подложка линейки прыжков (опция)                  -- 9 окт: линейка прыжков над шапками (как relativenumber в Vim)
  L.header_y = (L.toppos == 'top' and L.top_h or 0) + (L.tppos == 'top' and L.tp_h or 0)
  L.meter_h = 0
  -- шапка трека (2 окт): имя | R I M S A | громкость | панорама | лейн −+ / огибающие | подписи
  -- шапка (2 окт): имя | R I M S A | громкость | панорама | лейн / огибающие [| подписи — опция]
  -- скопы треков — во вкладке scopes (3 окт), строки в шапке нет
  -- строка входа (3 окт, опция hdrin): in <вход> [smart] — под панорамой, лейны ниже
  L.hr_in = (state.hdrin ~= false and not (state.mixer and state.mixpos == 'bottom')) and 1 or 0   -- 9 окт: с нижним микшером вход — в его полосе
  L.hr_info = state.hdrinfo and 3 or 0             -- инструменты / инсерты / сенды в шапке (опция header info, 7 окт)
  -- микшер (8 окт, быстрая опция mixer): шапка разворачивается — вместо строк
  -- громкости и панорамы (2) полоса микшера: фейдер шириной в лейн, справа
  -- (один лейн — под ним) эффекты с параметрами
  L.mixer = state.mixer and true or false
  -- 16 окт: микшер вкладкой в стеке (с dsp) и вкладка не активна — микшера нет (шапки — как без него)
  do local pl = D.pn_lay; if L.mixer and pl and pl.by_panel and pl.by_panel.mixer and not pl.rects.mixer then L.mixer = false end end
  -- 8 окт: микшер — над трекером (в шапке) или под ним (кнопки v ^ в уголке)
  L.mix_bottom = L.mixer and state.mixpos == 'bottom' or false
  L.mix_rows = L.mixer and math.max(6, tonumber(state.mix_rows) or 16) or 0
  -- 9 окт: схема маршрутизации — полосой в верху нижнего микшера (опция mixroute)
  L.route_h = (L.mix_bottom and state.mixroute ~= false) and (D.rt_need or (3 * ms('W') + 16)) or 0
  L.mix_h = L.mix_bottom and (L.mix_rows * L.rh + 4 + L.route_h) or 0
  L.hr_vp = L.mixer and (L.mix_bottom and 0 or L.mix_rows) or 2
  -- 11 окт: +1 строка уголка — кнопка markers под регионом; кнопки лейнов
  -- (- + a+) — по-прежнему последняя строка шапки, прямо над номерами колонок
  L.lane_row = 3 + L.hr_vp + L.hr_in + L.hr_info
  -- 12 окт: подписи полей — вертикально обычным шрифтом (как имена дорожек): высота — самое длинное слово
  L.cap_rows = state.captions and math.max(1, math.ceil((ms('delay') + 6) / L.rh)) or 0
  L.header_rows = 4 + L.hr_vp + L.hr_in + L.hr_info + L.cap_rows
  -- 20 окт: имя трека — чуть больше места (+2 px) и опция big trackname x1.5 / x2: шапка выше на запас, кнопки ниже
  L.hname_k = tonumber(state.bigname) or 1
  L.hname_x = math.floor((L.hname_k - 1) * (L.th or L.rh) + 0.5) + 2
  L.header_h = L.header_rows * L.rh + 3 + L.hname_x
  L.btn_w = L.cw + 4                             -- кнопки M S R в шапке
  L.status_h = L.rh + 4                               -- статус внизу окна (15 окт: всегда)
  L.status_in = 0
  L.dsp_h = state.khelp and math.max(7 * L.rh + 8, math.floor(gfx.h * 0.22))
    or (state.dsp and math.max(4 * L.rh + 8, math.floor(gfx.h * 0.18)) or 0)
  -- строка effects (7 окт): эффекты и сенды трека — под шапками
  -- 8 окт: узкий трек — эффекты столбиком; высота строки — по самому
  -- длинному столбику прошлого кадра (D.fxrow_lines ставит main), до 6 строк
  L.fxrow_h = (state.fxrow and not L.mixer) and ((D.fxrow_lines or 1) * L.rh + 2) or 0   -- в микшере эффекты — часть его полосы
  L.fxrow_y = L.header_y + L.header_h
  L.sess_y = L.fxrow_y + L.fxrow_h
  L.sess_h = 0                                   -- 30 окт: клипы сессии удалены; sess_y — место toppos clips
  L.body_y = L.sess_y + L.sess_h + (L.toppos == 'clips' and L.top_h or 0) + L.jr_h
  -- строка подсказок под каждым модулем (опция hints, 2 окт): своё место, не поверх
  L.hint_h = state.hints and (L.rh + 1) or 0
  -- горизонтальный скролл-бар треков под телом трекера (3 окт): место всегда,
  -- чтобы тело не прыгало, когда треки перестают помещаться
  L.hsb_h = 8
  -- пианинка (4 окт): в INSERT (5 окт, без m) — полоса клавиш под скролл-баром, над статусом
  -- полоса под трекером (5 окт): транспорт всегда, клавиатура слева — по m
  -- 15 окт: у символов кнопок пусто сверху — кнопки ниже на tp_cut, строки 3-4 и низ полосы выше на столько же
  -- (не больше зазора между строками: текст второй строки не налезает на третью)
  -- 15 окт: кнопки — одни символы в одну строку: полоса — 3 строки (кнопки, |<< freeze …, маркеры / punch)
  L.tp_cut = 0
  L.piano_h = 2 * L.rh + 6 + (L.kbstat and (2 * L.rh + 2) or 0) + (state.tpstyle == 'full' and (L.rh + 2) or 0)   -- 15 окт: full — 4 строки + режим (2) без пустых   -- 15 окт: full — 4-я строка ({ } под vel, rate под кнопками, swing под метрономом)   -- 12 окт: статус — две строки (режим x2), под рядом кнопок   -- 11 окт: full — строка под кнопками
  -- 15 окт: модлайн — своя строка под полем (как в Emacs): режим крупно, справа где курсор; без наложения на строки
  L.mode_h = 0   -- 16 окт: модлайна нет (смысла не было) — режим и место курсора в полосе транспорта
  L.low_h = L.mix_h + L.hsb_h + L.mode_h + (L.tppos == 'tracker' and L.piano_h or 0)   -- всё, что под телом в модуле трекера (микшер снизу — первым)
  L.body_h = math.max(0, gfx.h - L.body_y - L.status_h - L.status_in - L.dsp_h - L.hint_h - L.low_h - ((L.toppos == 'mid' or L.toppos == 'bottom') and L.top_h or 0) - (L.tppos == 'bottom' and L.tp_h or 0))
  L.mix_y = L.body_y + L.body_h                     -- микшер под трекером (mix_h = 0, если он сверху)
  L.route_y = L.mix_y
  L.hsb_y = L.mix_y + L.mix_h
  L.mode_y = L.hsb_y + L.hsb_h
  L.piano_y = L.mode_y + L.mode_h
  if L.tppos == 'top' then L.piano_y = 0 elseif L.tppos == 'bottom' then L.piano_y = gfx.h - L.status_h - L.tp_h end
  L.stat_y = L.body_y + L.body_h + L.low_h          -- статус в трекере (status_in)
  L.under_y = L.stat_y + L.status_in                -- строки подсказок тела
  local after = L.under_y + L.hint_h
  L.trk_bot = after                                 -- низ модуля трекера (тело, статус в нём, подсказки)
  if L.toppos == 'mid' then L.top_y = after; L.dsp_y = after + L.top_h
  elseif L.toppos == 'bottom' then L.dsp_y = after; L.top_y = after + L.dsp_h
  elseif L.toppos == 'clips' then L.top_y = L.sess_y + L.sess_h; L.dsp_y = after
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
      -- 8 окт: высота — по содержимому (прошлый кадр), не верхней панели:
      -- растягивание верхнего модуля сжимало матрицу (баг)
      local bh = D.ctrl_need_h or (L.top_h + (state.ptabs and (L.rh + 3) or 0))
      if L.ctrlpos == 'top' then
        L.ctrl_box = { 0, L.header_y, cw, bh }
        L.mx_top = L.header_y + bh
      else
        L.ctrl_box = { 0, L.trk_bot - bh, cw, bh }
        L.mx_bot = L.trk_bot - bh
      end
      if state.mx_hidden then L.matrix_w = math.max(L.matrix_w, L.ctrl_w + D.SEPW) end
    end
    L.ctrl_w = L.ctrl_box[3]
  end
  -- браузер слева (7 окт): верх колонки — матрица (под главным модулем),
  -- ниже — браузер; инструменты со слайсами — справа на всю высоту
  L.lside_rect = nil
  if L.browser_left then
    local y0 = L.mx_top or L.header_y
    local y1 = L.mx_bot or L.trk_bot
    local split = y0 + math.max(6 * L.rh, math.min(y1 - y0 - 6 * L.rh, math.floor((y1 - y0) * (state.lside_frac or 0.4))))
    L.lside_y0, L.lside_y1, L.lside_split = y0, y1, split   -- линию раздела тянут мышью (8 окт)
    L.mx_bot = split - (L.hint_h or 0)              -- строка подсказок матрицы — над разделом, не на браузере
    local ybot = gfx.h - L.status_h                 -- до самого низа: DSP — правее браузера (7 окт)
    L.lside_rect = { 0, split + D.SEPW, L.matrix_w - D.SEPW, ybot - split - D.SEPW }
  end
  -- 8 окт: верхняя панель над DSP (mid) — шириной с трекер: слева матрица
  -- (браузер справа — матрица тянется вниз до DSP / списка эффектов) или
  -- браузер слева (он и так до низа)
  L.top_x0, L.mx_ext = 0, nil
  if L.toppos == 'clips' and L.top_h > 0 then L.top_x0 = L.matrix_w end   -- под клипами — шириной с трекер
  if L.toppos == 'mid' and L.top_h > 0 and L.matrix_w > 0 and (L.browser_left or (not state.mx_hidden and L.ctrlpos ~= 'mid')) then
    L.top_x0 = L.matrix_w
    if not L.browser_left then L.mx_bot = L.dsp_y - (L.hint_h or 0); L.mx_ext = true end
  end
  -- панели (9 окт, опция panes, бета): дерево tmux / zellij — трекер берёт
  -- координаты из своего листа, прежние модули положения (верх, DSP,
  -- сайдбар, левая колонка) не рисуются: их рисует оболочка листов
  L.pn = nil
  if state.panes_ui and D.panes and state.panes then
    -- zellij: подсказки клавиш панели в фокусе — одной строкой внизу окна, над статусом
    L.pn_keys = (state.hints and state.hintpos == 'status') and (L.rh + 1) or 0
    L.status_h = (L.rh + 4) + L.pn_keys
    local lay = D.panes_layout(state, L, nregions, #snap.cols)
    L.pn = lay
    local c = lay.by_panel.tracker
    local tr = c and c.content or { x = 0, y = 0, w = gfx.w, h = gfx.h - L.status_h }
    -- 15 окт: развёрнут другой модуль (zz) — у трекера листа нет: не раскладывать его на всё окно под ним
    -- (шапка «fx Superior», транспорт и модлайн ложились поверх развёрнутого слайсера)
    if not c and ((state.panes.zoom and state.panes.zoom ~= 'tracker') or state.panes.zoomv) then tr = { x = 0, y = gfx.h - L.status_h, w = gfx.w, h = 0 }; L.pn_hidden_tracker = true else L.pn_hidden_tracker = nil end
    L.side_w, L.rstrip_w, L.slices_w, L.inst_w, L.top_h, L.pool_h, L.dsp_h = 0, 0, 0, 0, 0, 0, 0
    L.browser_left, L.lside_rect, L.slices_split = false, nil, false
    L.ctrl_alone, L.ctrl_box, L.ctrl_dsp, L.mx_top, L.mx_bot, L.mx_ext, L.top_x0 = false, nil, nil, nil, nil, nil, 0
    L.hint_h = 0                                         -- подсказки — строкой статуса (zellij)
    L.matrix_w = tr.x
    L.win_w = tr.x + tr.w
    L.side_x = L.win_w
    L.header_y = tr.y + (L.tppos == 'top' and L.tp_h or 0)
    L.fxrow_y = L.header_y + L.header_h
    L.sess_y = L.fxrow_y + L.fxrow_h
    local bot = tr.y + tr.h
    L.sess_h = 0
    L.body_y = L.sess_y + L.sess_h + L.jr_h         -- 9 окт: линейка прыжков — между клипами и строками
    -- 11 окт: модуль mixer — полоски рисуются в его листе (по колонкам трекера), в теле трекера места не берут
    local mxl = L.mix_bottom and lay.by_panel.mixer
    local mxr = mxl and lay.rects.mixer   -- 16 окт: только активная вкладка (в стеке с dsp)
    if mxr then L.low_h = L.low_h - L.mix_h; L.mix_h = 0 end
    L.body_h = math.max(0, bot - L.body_y - L.status_in - L.low_h - (L.tppos == 'bottom' and L.tp_h or 0))
    L.mix_y = L.body_y + L.body_h
    L.route_y = L.mix_y
    L.hsb_y = L.mix_y + L.mix_h
    L.mix_pane = mxr or nil
    if mxr then
      L.route_h = math.min(L.route_h, math.max(0, mxr.h - 6 * L.rh))
      L.mix_y, L.mix_h = mxr.y, mxr.h
      L.mix_rows = math.max(4, math.floor((mxr.h - 4 - L.route_h) / L.rh))
      L.route_y = L.mix_y
    end
    L.mode_y = L.hsb_y + L.hsb_h
    L.piano_y = L.mode_y + L.mode_h
    if L.tppos == 'top' then L.piano_y = tr.y elseif L.tppos == 'bottom' then L.piano_y = bot - L.tp_h end
    L.stat_y = L.body_y + L.body_h + L.low_h
    L.under_y = L.stat_y + L.status_in
    L.trk_bot = bot
    L.top_y, L.dsp_y = 0, bot
  end
  L.nrows = math.max(1, math.floor(L.body_h / L.rh))
  -- 11 окт: мастер справа (по умолчанию, как в Renoise) — правый угол под него зарезервирован, каналы до него
  L.mstrip_w = L.label_w + (L.ruler_right and L.rg_w or 0)   -- ширина полосы мастера (как было с линейкой слева)
  L.master_right = L.mix_bottom and snap.master and snap.master.vol and state.masterpos ~= 'left' and L.mstrip_w >= 6 * L.cw or false
  L.master_w = L.master_right and math.min(L.mstrip_w, 10 * L.cw + 2 * L.pad) or 0   -- 13 окт: полоса мастера экономнее (дальше — по его колонкам)
  -- 11 окт: колонка мастера (как show master track в REAPER, по умолчанию вкл) — его огибающие; нет огибающих — пустая дорожка
  L.mtrack = state.showmaster ~= false and snap.master and snap.master.track and not state.ptmode or false
  if L.mtrack then
    local ne = math.max(1, #(snap.master.envs or {}))
    L.cmd_w = snap.master.cmd and (2 * L.pad + ms('WWWWW')) or 0     -- 11 окт: колонка cmd (маркеры); 13 окт: уже
    -- 13 окт: огибающие мастера (темп) по умолчанию числами — колонка в ширину числа
    L.menv_w = L.env_bx + ms('000') + 2 * L.pad
    -- 11 окт: колонка visor (маркеры v:) — когда visor включён или в песне есть его события
    local mv = snap.master.vis
    L.vis_w = (mv and (#mv.rows > 0 or state.visor_on)) and (2 * L.pad + ms('WWWWWWW')) or 0
    local mcd = snap.master.chd   -- 21 окт: колонка chord — когда включена или в песне есть аккорды
    L.chd_w = (mcd and (#mcd.rows > 0 or state.chordlane)) and (2 * L.pad + ms('WWWWWW')) or 0
    local function mew(e) local m = state.envvals and state.envvals[(snap.master.guid or '') .. '/' .. (e.name or '')]; return (m == nil or m == 'vals') and L.menv_w or L.env_w end
    L.menv_of = mew
    local ew = 0
    for _, e in ipairs(snap.master.envs or {}) do ew = ew + mew(e) + 1 end
    if #(snap.master.envs or {}) == 0 then ew = L.env_w + 1 end
    L.master_w = math.max(L.master_w, ew + 1 + (L.cmd_w > 0 and (L.cmd_w + 1) or 0) + (L.vis_w > 0 and (L.vis_w + 1) or 0) + ((L.chd_w or 0) > 0 and (L.chd_w + 1) or 0))
  end
  -- 17 окт: мастер сложен (кнопка fold в его шапке; опция auto fold master — сам, когда треки не влезают):
  -- два символа — стерео-метр и подавление компрессора / лимитера мастера, колонок нет
  -- 20 окт: auto — сложен, пока курсор не на мастере (state.m_peek — раскрыт: клик, Opt+W, l с последнего поля)
  L.mfold = L.mtrack and (state.mfold or state.mfoldauto) and not state.m_peek or false
  L.master_w_full = L.master_w
  if L.mfold then L.master_w = 6 * ms('W') + 2 * L.pad + 2 end   -- 20 окт: стерео-пики + RMS по бокам (4 знака — узко)
  L.cols_r = L.win_w - L.master_w - (L.ruler_right and L.rg_w or 0)
  L.flat, L.cols = {}, {}
  L.hs_full, L.hs_n, L.hs_before, L.hs_list = 0, 0, 0, {}
  L.hs_cut = nil
  L.cols_cut = nil
  L.pt_n, L.pt_avail = 0, 0          -- PT-mode: показано / есть каналов (не больше 4)
  local cx = L.matrix_w + L.label_w
  local first = state.hscroll or 1
  local hide_below = nil          -- глубина свёрнутой папки: дети не показываются
  for ci, col in ipairs(snap.cols) do
    local depth = col.depth or 0
    if hide_below and depth <= hide_below then hide_below = nil end
    local hidden = (hide_below ~= nil and depth > hide_below) or (state.mxonly ~= nil and not state.mxonly[col.guid])   -- 9 окт: sel матрицы
      or (state.thide ~= nil and state.thide[col.guid] == true)                 -- 11 окт: скрыт в track list
    if not hidden and col.folder and state.fcollapse and state.fcollapse[col.guid] then hide_below = depth end
    local vis = (not hidden) and ci >= first and cx < L.cols_r and not L.hs_cut   -- 17 окт: после не влезшего — не показывать
    -- PT-mode (3 окт): ровно 4 канала от прокрутки
    if state.ptmode and not hidden and ci >= first then
      L.pt_avail = L.pt_avail + 1
      if L.pt_n >= 4 then vis = false end
    end
    -- fold: true — компактный вид (волна + нота), 'mini' — полоска в символ (прежний fold)
    local fs = state.folds[col.guid]
    -- уровень ширины (7 окт): задан — колонка по нему, свёртка za не действует
    local lvl = (not state.ptmode) and ((state.wlevel and state.wlevel[col.guid]) or state.wzlevel) or nil
    if lvl and state.autozoom and state.az_full == col.guid and not (state.wlevel and state.wlevel[col.guid]) then lvl = nil end   -- 20 окт: autozoom — трек курсора во всю ширину
    if lvl and fs ~= 'chord' then fs = (lvl <= 0 and 'mini') or (lvl == 1 and true) or nil end   -- 26 окт: chord lane не сбивается уровнем ширины (autozoom)
    if state.ptmode then fs = nil end             -- PT-mode: каналы во всю ширину, без свёрток
    -- зум ширины (Cmd + горизонтальное колесо, 3 окт): 1 — все треки компактно
    -- (нота + волна), 2 — все полоской; 0 — как у каждого трека
    local c = { col = col, ci = ci, x = vis and cx or nil, lanes = {}, envs = {}, folded = fs == 'mini' or fs == 'chord', chord = fs == 'chord', compact = fs == true, hidden = hidden }
    -- 27 окт (2): «~» — только автоматизация, которой сейчас не видно колонкой (огибающие / MIDI-лейны этого трека)
    if L.envmark and col.env_rows then
      local seen = {}
      local se = state.trackenvs and state.trackenvs[col.guid]
      if se == nil then se = state.envs end
      if c.compact then se = true end
      if lvl and not (state.trackenvs and state.trackenvs[col.guid] == true) then se = false end   -- уровни ширины: огибающие — только у широкого
      if state.ptmode then se = false end
      if se then for _, e in ipairs(col.envs or {}) do seen['e:' .. (e.name or '')] = true end end
      if not hidden and not c.folded and state.midilanes ~= false and not c.compact and not state.ptmode then
        for _, ml in ipairs(col.mlanes or {}) do seen['m:' .. tostring(ml.key)] = true end
      end
      local rows, any = {}, false
      for _, m in ipairs(col.env_rows) do if not seen[m.key] then for r in pairs(m.rows) do rows[r] = true; any = true end end end
      c.marks = any and rows or nil
    end
    local lx = (c.x or 0) + 1
    if c.folded then
      local fw = c.chord and L.chord_w or L.fold_w    -- 8 окт: лейн аккордов — шире полоски
      L.flat[#L.flat + 1] = { ci = ci, col = col, folded = true, chord = c.chord, x = vis and lx or nil, w = fw }
      c.lanes[1] = { lane = col.lanes[1], x = lx, w = fw, nsub = 1, f0 = #L.flat, folded = true }
      lx = lx + fw + 1
    else
      for li, lane in ipairs(col.lanes) do
        -- минимум подколонок задаёт пользователь кнопками -/+ над лейном (1 окт)
        local nsub = math.max(1, #lane.subs, (state.subs_min or {})[col.guid .. ':' .. tostring(lane.idx)] or 0)
        if lvl and lvl > 3 + L.MAXFX and li == 1 then nsub = math.max(nsub, 1 + lvl - 3 - L.MAXFX) end   -- шире всех fx — подколонки нот
        local ln = { lane = lane, x = lx, nsub = nsub, f0 = #L.flat + 1, sx = {} }
        local off = 0
        for si = 1, nsub do
          local narrow = si > 1 and not (lane.audio_sub and lane.audio_sub[si])
          local G = c.compact and (narrow and L.GCN or L.GC) or (narrow and L.GN or nil)
          if lvl and lvl >= 2 and not narrow then G = L.GL[math.min(lvl, 3 + L.MAXFX)] end
          if not narrow and D.col_is_kit(col) then G = L.kitG(G) end   -- 19 окт: кит — без Sxx (и на уровнях ширины)
          if lane.has_tfx and not narrow then G = L.tfxG(G) end
          -- 21 окт: волна — только когда есть что показать (аудио в лейне или кит с сэмплами); tw — выбор трека (D.wave_pref:
          -- true / false / nil = авто). Пул lib общий на все треки — по нему не судить (так колонка не уходила никогда)
          if not narrow then
            local pref = D.wave_pref and D.wave_pref(col)
            local show = lane.audio_sub ~= nil or D.col_is_kit(col) or (D.has_slx and D.has_slx(col))   -- 28 окт: и slixer (main)
            if pref ~= nil then show = pref end
            if not show then G = (G == L.GC) and L.GCM or L.nowaveG(G) end
          end
          do   -- 27 окт: «+» / «~» перед нотой
            local fo = L.fold_on and lane.has_fold
            local em = L.envmark and li == 1 and si == 1 and c.marks
            -- 28 окт: уровень ширины прячет команды / задержку — у ноты с ними тоже «~» (иначе 0R8B не видно вовсе)
            local hm
            if L.envmark and not narrow then
              local G0 = G or L
              local nf, nodel = G0.nfx or L.nfx, G0.narrow or G0.notes_only
              for row, cell in pairs(lane.subs[si] or {}) do
                if type(cell) == 'table' and (cell.kind == 'audio' or cell.kind == 'midi') then
                  local fx = cell.fx
                  if (nodel and (cell.delay or 0) > 0) or (fx and #fx > nf) then hm = hm or {}; hm[row] = true
                  elseif fx and nf < L.nfx then for i = nf + 1, #fx do if fx[i] and fx[i] ~= '' then hm = hm or {}; hm[row] = true end end end
                end
              end
            end
            em = em or hm
            if not narrow and (fo or em) then G = L.foldG(G, fo and em) end
            ln.hm = ln.hm or {}; ln.hm[si] = hm
          end
          if L.waveonly_on and lane.audio_sub and lane.audio_sub[si] then
            -- зум трека: без него / свёрнут — 3 знака, каждый шаг колеса — +2, до 24
            local ww = math.min(L.cw * 24, L.cw * (3 + 2 * math.max(0, (lvl or 1) - 1)))
            L.GW[ww] = L.GW[ww] or setmetatable({ wave_only = true, notes_only = true, nfx = 0, x_fx = {}, x_inst = false, x_slc = false, w_wave = ww, x_wave = L.pad,
              wave = state.wavemode == 'column' and 'spec' or 'peaks', x_note = L.pad, x_vol = L.pad, x_del = L.pad, sub_w = ww + 2 * L.pad }, { __index = L })
            G = L.GW[ww]
          end
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
      -- уровни: автоматизация — последней, когда колонка шире 50 знаков; 24 окт: a на треке (огибающие трека явно вкл.) — видна всегда
      if lvl and not (state.trackenvs and state.trackenvs[col.guid] == true) then show_env = (lx - (c.x or 0)) >= 50 * L.cw end
      if state.ptmode then show_env = false end     -- PT-mode: только ноты
      if show_env and col.envs then
        -- 24 окт: по умолчанию — узко (значение в 3 знака): правка — во вкладке automation или точками; опция envwide — как было
        local narrow_env = c.compact or not state.envwide
        local three = not c.compact and not state.envwide
        local ew = three and L.env3_w or (narrow_env and L.env_cw or L.env_w)
        for _, e in ipairs(col.envs) do
          -- огибающая — тоже элемент L.flat (курсор заходит, INSERT правит точки)
          L.flat[#L.flat + 1] = { ci = ci, col = col, env = e, sub = {}, x = vis and lx or nil, w = ew, compact = narrow_env or nil }
          c.envs[#c.envs + 1] = { e = e, x = lx, w = ew, fi = #L.flat, G = three and L.G3 or (narrow_env and L.GE or nil) }
          lx = lx + ew + 1
        end
      end
    end
      -- MIDI-лейны (6 окт, опция midi lanes): узкие колонки после огибающих
      c.mls = {}
      if not hidden and not c.folded and state.midilanes ~= false and not c.compact and not state.ptmode then   -- 9 окт: сложенный — в знак, без MIDI-лейнов
        for _, ml in ipairs(col.mlanes or {}) do
          local mw = L.pad + ((ml.kind == 'tx') and ms('WWWWW') or ms(state.envfmt == 'hex' and 'FF' or '127')) + L.pad + ms('W')
          L.flat[#L.flat + 1] = { ci = ci, col = col, ml = ml, sub = {}, x = vis and lx or nil, w = mw }
          c.mls[#c.mls + 1] = { ml = ml, x = lx, w = mw, fi = #L.flat }
          lx = lx + mw + 1
        end
      end
    c.w = lx - (c.x or 0)
    -- 8 окт: колонка не влезла целиком — режем по границе трекера (шапка и
    -- строка эффектов выходили за линию модуля); подколонки за краем — без x
    -- 17 окт: не влез целиком и он не первый видимый — не показывать (и всё после него): к нему ведёт
    -- полоса прокрутки треков; раньше он рисовался обрезанным («drum» у мастера)
    -- 20 окт: влезает хотя бы половина — показать обрезанным (ниже), меньше — спрятать
    if vis and c.x and c.x + c.w > L.cols_r - 2 and #L.cols > 0 and (L.cols_r - 2 - c.x) < c.w / 2 then
      for k = (c.lanes[1] and c.lanes[1].f0 or #L.flat + 1), #L.flat do local f = L.flat[k]; if f.ci == ci then f.x = nil end end
      vis = false; L.hs_cut = true; lx = cx
    end
    if vis and c.x and c.x + c.w > L.cols_r - 2 then
      L.cols_cut = true   -- 20 окт: autozoom — не влез целиком
      local lim = L.cols_r - 2
      c.w = math.max(0, lim - c.x)
      for k = (c.lanes[1] and c.lanes[1].f0 or #L.flat + 1), #L.flat do
        local f = L.flat[k]
        if f.x and f.ci == ci then
          if f.x >= lim then f.x = nil elseif f.x + f.w > lim then f.w = lim - f.x end
        end
      end
      for _, ev in ipairs(c.envs) do if ev.x >= lim then ev.x = lim; ev.w = 0 elseif ev.x + ev.w > lim then ev.w = lim - ev.x end end
      for _, ln in ipairs(c.lanes) do if ln.x and ln.w and ln.x + ln.w > lim then ln.w = math.max(0, lim - ln.x) end end   -- 21 окт: кнопки −+ / a+ шапки — от обрезанной ширины
      for k = #c.mls, 1, -1 do   -- 21 окт: PB лез на Tempo мастера — за краем лейна нет, у края обрезан
        local ml = c.mls[k]
        if ml.x >= lim - L.pad then table.remove(c.mls, k) elseif ml.x + ml.w > lim then ml.w = lim - ml.x end
      end
    end
    if vis then L.cols[#L.cols + 1] = c; cx = lx; if lx <= L.cols_r then L.hs_full = (L.hs_full or 0) + 1; if state.ptmode then L.pt_n = L.pt_n + 1 end end end
    if not hidden then L.hs_n = (L.hs_n or 0) + 1; L.hs_list[L.hs_n] = ci; if ci < first then L.hs_before = (L.hs_before or 0) + 1 end end
    -- скрытые дети свёрнутой папки: записи L.flat остаются (курсор не ломается), x = nil
    if hidden then for _, f in ipairs(L.flat) do if f.ci == ci then f.x = nil end end end
  end
  -- 11 окт: колонка мастера — справа, в своём углу; огибающие — элементы L.flat (курсор, точки), как у трека
  -- 17 окт: auto fold master — треки не влезли: сложить на следующей раскладке; развернуть, только если справа
  -- хватит места на полную ширину мастера (иначе сложил-развернул по кругу)
  if L.mtrack and L.mfold then L.mcol = nil
  elseif L.mtrack then
    local mc = snap.master
    local ci = #snap.cols + 1
    local c = { col = mc, ci = ci, x = L.cols_r + 1, lanes = {}, envs = {}, mls = {}, master = true, mtrack = true }
    local lx = c.x
    for _, e in ipairs(mc.envs or {}) do
      local ew2 = L.menv_of and L.menv_of(e) or L.env_w
      L.flat[#L.flat + 1] = { ci = ci, col = mc, env = e, sub = {}, x = lx, w = ew2 }
      c.envs[#c.envs + 1] = { e = e, x = lx, w = ew2, fi = #L.flat }
      lx = lx + ew2 + 1
    end
    if mc.cmd then
      L.flat[#L.flat + 1] = { ci = ci, col = mc, ml = mc.cmd, sub = {}, x = lx, w = L.cmd_w }
      c.mls[#c.mls + 1] = { ml = mc.cmd, x = lx, w = L.cmd_w, fi = #L.flat }
      lx = lx + L.cmd_w + 1
    end
    if mc.chd and (L.chd_w or 0) > 0 then   -- 21 окт: chord lane — первой из колонок событий мастера
      L.flat[#L.flat + 1] = { ci = ci, col = mc, ml = mc.chd, sub = {}, x = lx, w = L.chd_w }
      c.mls[#c.mls + 1] = { ml = mc.chd, x = lx, w = L.chd_w, fi = #L.flat }
      lx = lx + L.chd_w + 1
    end
    if mc.vis and L.vis_w > 0 then
      L.flat[#L.flat + 1] = { ci = ci, col = mc, ml = mc.vis, sub = {}, x = lx, w = L.vis_w }
      c.mls[#c.mls + 1] = { ml = mc.vis, x = lx, w = L.vis_w, fi = #L.flat }
      lx = lx + L.vis_w + 1
    end
    c.w = L.master_w - 1
    c.empty = #c.envs == 0 and not mc.cmd
    L.mcol = c
    L.cols[#L.cols + 1] = c
  else L.mcol = nil end
  L.total_w = cx
  return L
end

-- ── примитивы ─────────────────────────────────────────────────────────────
-- mono: серый по яркости, кроме ячейки курсора (D.CURCELL)
local function mono(c)
  if not D.mono or c == D.CURCELL or c == D.FOCUS_INS or c == D.ACC_KEEP or (D.KEEP and D.KEEP[c]) then return c end   -- курсор, рамка INSERT, R и FX — цветные
  local t = D.mono_tint
  if t then local l = math.max(c[1], c[2], c[3]); return { l * t[1], l * t[2], l * t[3] } end   -- по наибольшему каналу: уже тонированное не темнеет
  local l = 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]
  return { l, l, l }
end
D.mono_col = mono
-- текст в mono: не темнее порога — тусклые подписи (=START, пустые слоты,
-- подсказки) иначе пропадали на тёмном фоне (3 окт); фон и линии — как есть
local function mono_text(c)
  if not D.mono or c == D.CURCELL or c == D.FOCUS_INS or c == D.ACC_KEEP or (D.KEEP and D.KEEP[c]) then return c end
  local t = D.mono_tint
  if t then local l = math.max(0.40, c[1], c[2], c[3]); return { l * t[1], l * t[2], l * t[3] } end
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
  -- 9 окт, стандарт: текст не выходит за модуль. D.clip = { x0, x1 } ставит
  -- отрисовка модуля; всё, что правее x1, обрезается (fit), левее x0 — нет
  local cl = D.clip
  if cl then
    if x >= cl[2] or x + ms(s) <= cl[1] then return end
    if cl[3] and (y < cl[3] - 2 or y >= cl[4]) then return end   -- 9 окт, панели: и по высоте листа
    if x + ms(s) > cl[2] then s = D.fit(s, cl[2] - x); if s == '' then return end end
  end
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
  if D.SCALE % 1 ~= 0 and not e.clear then   -- 20 окт: прозрачная картинка — без промежуточного ×2 (альфа в нём не сохранялась бы)
    -- дробный масштаб (x1.5, 5 окт): ближайший сосед даёт штрихи 1-2-1-2 px;
    -- поэтому картинка ×(2·масштаб) без сглаживания и вывод /2 со сглаживанием —
    -- все штрихи одной толщины, край мягкий
    local k = math.floor(D.SCALE * 2 + 0.5)
    if not e.ov or e.ovk ~= k then
      local id = tc_alloc()
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
    gfx.mode = ((bg or e.clear) and 0 or 1) | 4          -- 4 = без фильтрации при масштабировании; прозрачная — обычным наложением
    -- 10 окт: с подложкой — без запаса +2 px справа (он нужен только ×1.5): при ×2 он
    -- торчал из блока курсора ступенькой
    local sw = bg and math.max(1, e.w - 2) or e.w
    gfx.blit(e.id, 1, 0, 0, 0, sw, e.h, math.floor(x), math.floor(y), sw * D.SCALE, e.h * D.SCALE)
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
-- 11 окт: мелкий шрифт — подписи колонок, деления dB; всегда x1 (D.SMALL считает set_font)
D.SMALL = D.SMALL or 1
function D.small_measure(s)
  if D.ttf then gfx.setfont(3, D.ttf_face, D.ttf_px); local w = gfx.measurestr(s); gfx.setfont(D.font_id); return w end
  local s0 = D.SCALE; D.SCALE = 1; local w = ms(s); D.SCALE = s0; return w
end
function D.small_text(x, y, s, col)
  if s == nil or s == '' then return end
  if D.ttf then
    gfx.setfont(3, D.ttf_face, D.ttf_px)
    set(col); gfx.x, gfx.y = math.floor(x), math.floor(y + D.SPACE); gfx.drawstr(s)
    gfx.setfont(D.font_id)
    return
  end
  local s0 = D.SCALE; D.SCALE = 1; text(x, y, s, col); D.SCALE = s0   -- ровно x1 (x1.5 · 2/3 давал 0.999…)
end
-- 19 окт: прямоугольник со срезанными углами (r px) — заливка или рамка, пиксельно (без сглаживания)
local function rrect(x, y, w, h, fill, r)
  r = r or 2
  if w <= 2 * r or h <= 2 * r then gfx.rect(x, y, w, h, fill and 1 or 0); return end
  if fill then
    gfx.rect(x + r, y, w - 2 * r, h, 1); gfx.rect(x, y + r, w, h - 2 * r, 1)
    for k = 1, r - 1 do gfx.rect(x + r - k, y + k, w - 2 * (r - k), h - 2 * k, 1) end
  else
    gfx.line(x + r, y, x + w - 1 - r, y); gfx.line(x + r, y + h - 1, x + w - 1 - r, y + h - 1)
    gfx.line(x, y + r, x, y + h - 1 - r); gfx.line(x + w - 1, y + r, x + w - 1, y + h - 1 - r)
    for k = 1, r - 1 do
      gfx.rect(x + r - k, y + k, 1, 1, 1); gfx.rect(x + w - 1 - r + k, y + k, 1, 1, 1)
      gfx.rect(x + r - k, y + h - 1 - k, 1, 1, 1); gfx.rect(x + w - 1 - r + k, y + h - 1 - k, 1, 1, 1)
    end
  end
end
D.rrect = rrect
-- 27 окт (5): кнопки ‹ ξ › у правого края выбранной строки lib (поверх волны): ξ — случайный сэмпл по имени папки, ‹ › — по выпавшим
function D.lib_xi_btns(L, right, y, mx, my, hover)
  local bw = ms('W') + 6   -- 27 окт: ширины — шрифтом трекера (ms), не системным: ξ стоял неровно
  local x0 = right - 3 * (bw + 1)
  for k, b in ipairs({ { '<', 'prev' }, { 'ξ', 'rand' }, { '>', 'next' } }) do
    local bx = x0 + (k - 1) * (bw + 1)
    local hot = mx >= bx and mx < bx + bw and my >= y and my < y + L.rh
    set(hot and U.tint(U.AMBER, 0.35) or U.PANEL); gfx.rect(bx, y + 1, bw, L.rh - 2, 1)
    set(hot and U.AMBER or U.LINE); gfx.rect(bx, y + 1, bw, L.rh - 2, 0)
    text(bx + math.floor((bw - ms(b[1])) / 2), y + 1, b[1], hot and U.AMBER or U.TEXT)
    if hot then hover.libxi = b[2]; hover.pool = nil end
  end
end
-- 27 окт: gain reduction (GainReduction_dB компрессоров / лимитеров: ReaComp, ReaXcomp, ReaLimit, плагины с этим полем)
-- шапка трека: красная полоса справа налево по полосе метра (шкала 0..24 dB) и число
function D.gr_hdr(L, x, y, w, gr)
  if not gr or gr < 0.1 then return end
  local fw = math.max(1, math.floor(w * math.min(1, gr / 24) + 0.5))
  set(U.RED); gfx.rect(x + w - fw, y - 1, fw, 3, 1)
end
-- микшер: столбик сверху вниз от 0 dB у правого края коробки фейдера (та же шкала, что фейдер)
-- 31 окт: режим автоматизации трека тремя буквами цветом (шапка трека, имя в полосе микшера); touch / latch / write
-- мигают — пишут прямо сейчас. Справа до xr, → ширина; щелчок — следующий режим (Shift — предыдущий)
D.AMODE = { [0] = { 'trm', 'DIM' }, [1] = { 'rea', 'GREEN' }, [2] = { 'tch', 'AMBER' }, [3] = { 'wri', 'RED' }, [4] = { 'lat', 'MAGENTA' }, [5] = { 'lpv', 'CYAN' } }
function D.amode_tag(L, xr, y, col, hover, mx, my)
  local tr = col and col.track
  if not (tr and reaper.ValidatePtr(tr, 'MediaTrack*')) then return 0 end
  local m = math.floor(reaper.GetMediaTrackInfo_Value(tr, 'I_AUTOMODE'))
  local e = D.AMODE[m] or D.AMODE[0]
  local w = U.measure('www') + 4
  local x = xr - w
  local c = U[e[2]] or U.mix(U.RED, U.CYAN, 0.5)
  if m >= 2 and m <= 4 and math.floor(reaper.time_precise() * 3) % 2 == 0 then c = U.mix(c, U.BG, 0.65) end   -- мигает
  local hot = mx >= x and mx < x + w and my >= y and my < y + L.rh
  if hot then set(D.CURROW); gfx.rect(x, y + 1, w, L.rh - 2, 1); hover.btn = { col = col, what = 'automode' } end
  text(x + 2, y, e[1], hot and U.AMBER or c)
  return w
end
function D.gr_mix(x, ypos, gr)
  if not gr or gr < 0.1 then return end
  local y0, y1 = ypos(0), ypos(-math.min(60, gr))
  set(U.RED); gfx.rect(x, y0, 3, math.max(1, y1 - y0), 1)
end
-- DSP: «-4.2» красным за именем модуля
function D.gr_tag(L, x, y, gr)
  if not gr or gr < 0.1 then return end
  local s = ('-%.1f'):format(gr)
  set(U.RED); gfx.rect(x, y + 1, ms(s) + 2 * L.pad, L.rh - 1, 1)
  text(x + L.pad, y + 1, s, U.BG)
end
-- 27 окт: рамка / заливка модуля DSP: rounded racks — скруглённая, иначе прямоугольник
function D.mod_box(x, y, w, h, fill) if D.round_rack then rrect(x, y, w, h, fill, 4) else gfx.rect(x, y, w, h, fill and 1 or 0) end end
-- 19 окт: хоткеи параметров сэмплера пэда (режим пэдов: буква — прыжок к параметру; буквы свободны в режиме пэдов)
D.PADKEYS = { volume = 'v', pan = 'n', ['min vol'] = 'i', root = 'o', pitch = 't', bend = 'b', attack = 'a', decay = 'd',
  sustain = 's', release = 'e', ['note-off'] = 'f', loop = 'u', ['vel lo'] = 'w', ['vel hi'] = 'q', chance = 'c' }
-- 19 окт: ADSR поверх волны — линия в 2 px контрастным зелёным, на узлах ромбики (hot — янтарём, залитый)
function D.adsr_line(pts, bg, hot_i)
  local c = U.readable(U.mix(U.GREEN, U.TEXT, 0.25), bg or U.PANEL, 4.5)
  set(c)
  for i = 1, #pts - 1 do
    local a, b = pts[i], pts[i + 1]
    gfx.line(a[1], a[2], b[1], b[2]); gfx.line(a[1], a[2] - 1, b[1], b[2] - 1)
  end
  local r = math.max(3, math.floor((D.L_rh or 16) / 4))
  for i = 2, #pts - 1 do
    local x, y = pts[i][1], pts[i][2]
    set(i == hot_i and U.AMBER or c)
    gfx.triangle(x, y - r, x + r, y, x, y + r, x - r, y)
    if i ~= hot_i then set(bg or U.PANEL); gfx.triangle(x, y - r + 2, x + r - 2, y, x, y + r - 2, x - r + 2, y) end
  end
end

-- 21 окт: обрезка — мемо (ширина → строка → результат, сброс по объёму и при смене шрифта) и старт с оценки
-- по пропорции ширин: было по символу с конца, подстрока на каждый шаг — сотни строк мусора на длинной подписи
local FITC, FITN, FITS, FITF = {}, 0, nil, nil
local function fit(s, w)
  if FITS ~= D.SCALE or FITF ~= D.font_id then FITC, FITN, FITS, FITF = {}, 0, D.SCALE, D.font_id end
  local fw = FITC[w]
  local r = fw and fw[s]
  if r then return r end
  local full = ms(s)
  if full <= w then r = s
  else
    local n = math.min(#s, math.floor(#s * w / math.max(1, full)) + 1)
    while n < #s and ms(s:sub(1, n + 1)) <= w do n = n + 1 end
    while n > 0 do
      local nb = s:byte(n + 1)
      if not (nb and nb >= 128 and nb < 192) and ms(s:sub(1, n)) <= w then break end
      n = n - 1
    end
    r = s:sub(1, n)
  end
  if not fw then fw = {}; FITC[w] = fw end
  fw[s] = r
  FITN = FITN + 1
  if FITN > 6000 then FITC, FITN = {}, 0 end
  return r
end
D.fit = fit
-- 8 окт: короткое имя для тесных мест (эффекты сбоку фейдера) — не влезает,
-- значит без «(вендора)», потом согласными: первая буква и все не-гласные
-- (ReaVerbate → RVrbt, Container → Cntnr); и это длинно — обрезка fit
local VOW = {}
for _, ch in utf8.codes('aeiouyаеёиоуыэюя') do VOW[ch] = true end
function D.fit_short(s, w)
  if ms(s) <= w then return s end
  local b = s:gsub('%s*%b()%s*$', '')
  if b ~= '' and ms(b) <= w then return b end
  if b == '' then b = s end
  local out, first = {}, true
  for _, ch in utf8.codes(b) do
    if first or not (VOW[ch] or ch == 32) then out[#out + 1] = utf8.char(ch) end
    first = false
  end
  return fit(table.concat(out), w)
end

-- строка подсказок модуля: «клавиша действие» парами, клавиши янтарём; пара,
-- которая не влезает целиком, не рисуется (без наложений); модуль в фокусе ярче
-- маршрутизация всех треков (9 окт, вкладка routing в DSP): под каждой
-- колонкой трекера — что куда: > сенд (цвет трека-получателя, dB), < ресив,
-- > out N аппаратный выход, > master; не влезло — +N. Щелчок — окно
-- маршрутизации трека. Данные — кэш по счётчику изменений проекта
D.rt_cache = { sc = -1, by = {} }
local function routing_of(tr)
  local sc = reaper.GetProjectStateChangeCount(0)
  local c = D.rt_cache
  if c.sc ~= sc then c.sc, c.by = sc, {} end
  local r = c.by[tr]
  if r then return r end
  r = {}
  local function nm(t) local _, n = reaper.GetTrackName(t); return n end
  local function db(v) return v > 1e-6 and ('%+.0f'):format(20 * math.log(v, 10)) or '-inf' end
  for i = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
    local d = reaper.GetTrackSendInfo_Value(tr, 0, i, 'P_DESTTRACK')
    local col = reaper.GetTrackColor(d)
    r[#r + 1] = { dir = '>', name = nm(d), dest = d, cat = 0, idx = i, db = db(reaper.GetTrackSendInfo_Value(tr, 0, i, 'D_VOL')),
                  mute = reaper.GetTrackSendInfo_Value(tr, 0, i, 'B_MUTE') == 1, rgb = col ~= 0 and { reaper.ColorFromNative(col) } or nil }
  end
  for i = 0, reaper.GetTrackNumSends(tr, -1) - 1 do
    local s = reaper.GetTrackSendInfo_Value(tr, -1, i, 'P_SRCTRACK')
    r[#r + 1] = { dir = '<', name = nm(s), cat = -1, idx = i, db = db(reaper.GetTrackSendInfo_Value(tr, -1, i, 'D_VOL')), mute = reaper.GetTrackSendInfo_Value(tr, -1, i, 'B_MUTE') == 1, recv = true }
  end
  for i = 0, reaper.GetTrackNumSends(tr, 1) - 1 do
    local ch = math.floor(reaper.GetTrackSendInfo_Value(tr, 1, i, 'I_DSTCHAN')) & 1023
    r[#r + 1] = { dir = '>', name = ('out %d/%d'):format(ch + 1, ch + 2), hw = true, cat = 1, idx = i, mute = reaper.GetTrackSendInfo_Value(tr, 1, i, 'B_MUTE') == 1 }
  end
  if reaper.GetMediaTrackInfo_Value(tr, 'B_MAINSEND') == 1 then
    local par = reaper.GetParentTrack(tr)
    r[#r + 1] = { dir = '>', name = par and ('^ ' .. nm(par)) or 'master', main = true }
  end
  c.by[tr] = r
  return r
end
-- диаграмма маршрутизации всех треков (9 окт, кнопка routing на мастере):
-- поверх тела трекера; трек — коробка, колонка — по самому длинному пути
-- сигнала до мастера (источники слева, мастер и аппаратные выходы справа).
-- Провода: сенд — голубой (заглушён — серый), выход в папку / мастер —
-- тусклый, аппаратный — янтарь. Щелчок по коробке — попап маршрутизации
-- трека. Граф — кэш по счётчику изменений проекта
D.rd_cache = { sc = -1 }
local function route_graph(cols, master)
  local sc = reaper.GetProjectStateChangeCount(0)
  local c = D.rd_cache
  if c.sc == sc and c.g then return c.g end
  local nodes, by = {}, {}
  for _, col in ipairs(cols) do
    if col.track and reaper.ValidatePtr(col.track, 'MediaTrack*') then
      local n = { col = col, tr = col.track, name = col.name ~= '' and col.name or '-', rgb = col.rgb, out = {} }
      nodes[#nodes + 1] = n; by[col.track] = n
    end
  end
  local mnode = master and master.track and { col = master, tr = master.track, name = 'master', master = true, out = {} } or nil
  if mnode then nodes[#nodes + 1] = mnode; by[master.track] = mnode end
  local hw = {}
  local function hwnode(ch)
    local k = ch
    if not hw[k] then hw[k] = { name = ('out %d/%d'):format(ch + 1, ch + 2), hw = true, out = {}, ch = ch } end
    return hw[k]
  end
  for _, n in ipairs(nodes) do
    local tr = n.tr
    for i = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
      local d = by[reaper.GetTrackSendInfo_Value(tr, 0, i, 'P_DESTTRACK')]
      if d then n.out[#n.out + 1] = { to = d, kind = 'send', mute = reaper.GetTrackSendInfo_Value(tr, 0, i, 'B_MUTE') == 1 } end
    end
    for i = 0, reaper.GetTrackNumSends(tr, 1) - 1 do
      local ch = math.floor(reaper.GetTrackSendInfo_Value(tr, 1, i, 'I_DSTCHAN')) & 1023
      n.out[#n.out + 1] = { to = hwnode(ch), kind = 'hw', mute = reaper.GetTrackSendInfo_Value(tr, 1, i, 'B_MUTE') == 1 }
    end
    if not n.master and reaper.GetMediaTrackInfo_Value(tr, 'B_MAINSEND') == 1 then
      local par = reaper.GetParentTrack(tr)
      local d = par and by[par] or mnode
      if d then n.out[#n.out + 1] = { to = d, kind = 'main' } end
    end
  end
  -- глубина = самый длинный путь до стока (петли обрезаются)
  local depth, busy = {}, {}
  local function dep(n)
    if depth[n] then return depth[n] end
    if busy[n] then return 0 end
    busy[n] = true
    local d = 0
    for _, e in ipairs(n.out) do if not e.to.hw then d = math.max(d, 1 + dep(e.to)) end end
    busy[n] = nil
    depth[n] = d
    return d
  end
  local maxd = 0
  for _, n in ipairs(nodes) do maxd = math.max(maxd, dep(n)) end
  local hwl = {}
  for _, h in pairs(hw) do hwl[#hwl + 1] = h end
  table.sort(hwl, function(a, b) return a.ch < b.ch end)
  local g = { nodes = nodes, hw = hwl, depth = depth, maxd = maxd }
  c.sc, c.g = sc, g
  return g
end
-- 9 окт (вертикально): диаграмма — прямо над нижним микшером, по его
-- колонкам. Каждая связь — своя горизонтальная полоса: из колонки трека
-- вверх, по полосе к колонке получателя, вниз в его полосу микшера
-- (стрелка). Мастер — колонка под номерами строк; аппаратные выходы — к
-- правому краю с подписью. Щелчок над колонкой — попап маршрутизации трека
function D.route_diagram(L, cols, master, x, y, w, h, opts)
  local hover = {}
  local mx, my = gfx.mouse_x, gfx.mouse_y
  set(U.BG); gfx.rect(x, y, w, h, 1)
  local g = route_graph(cols, master)
  -- центры колонок: треки — по L.cols, мастер — колонка номеров строк
  local cx, cc = {}, {}
  for _, c in ipairs(L.cols or {}) do
    if c.col and c.col.track and c.x then cx[c.col.track] = c.x + math.floor(c.w / 2); cc[c.col.track] = c end
  end
  -- 11 окт: мастер справа (его полоса микшера в углу) — туда и провода; слева — как было
  local mxx, mxw = L.matrix_w, L.label_w
  if L.master_right then mxx = L.cols_r end
  if master and master.track then cx[master.track] = mxx + math.floor(mxw / 2); cc[master.track] = { x = mxx, w = mxw, col = master, master = true } end
  local bot = y + h - 2
  -- связи по порядку: сенды, аппаратные, выходы в папку / мастер (последними — ниже всех)
  local links = {}
  for _, n in ipairs(g.nodes) do
    for _, e in ipairs(n.out) do
      local a = cx[n.tr]
      local b = e.to.hw and (x + w - L.pad - ms(e.to.name) - 4) or (e.to.tr and cx[e.to.tr])
      if a and b then links[#links + 1] = { a = a, b = b, e = e, n = n, ord = e.kind == 'main' and 3 or (e.kind == 'hw' and 2 or 1) } end
    end
  end
  table.sort(links, function(p, q) if p.ord ~= q.ord then return p.ord > q.ord end; return math.abs(p.a - p.b) < math.abs(q.a - q.b) end)
  -- 11 окт: провода — нижняя часть (до 40 %), над ними — устройства треков столбиком
  local links_h = math.min(math.floor(h * 0.4), #links * L.rh + 6)
  local step = math.max(3, math.min(L.rh, math.floor((links_h - 4) / math.max(1, #links))))
  text(x + L.pad, y + 2, fit('routing - all tracks over the mixer: cyan sends, grey to folder / master, amber hardware; click over a track - its routing; Esc - back', w - 2 * L.pad), U.AMBER)
  -- стойки колонок (тонко) — чтобы было видно, где чья колонка
  for tr, xx in pairs(cx) do set(U.mix(U.LINE, U.BG, 0.5)); gfx.rect(xx, y + L.rh + 4, 1, h - L.rh - 6, 1) end
  -- 11 окт: устройства трека — цепь DSP, повёрнутая на 90° против часовой: первое
  -- у полосы микшера (внизу), дальше вверх; блок — имя и мини-полоски параметров.
  -- Щелчок — этот эффект в DSP
  local dtop, dbot = y + L.rh + 4, bot - links_h - 4
  for tr, c in pairs(cc) do
    local fxs = c.col and c.col.fx or {}
    local bw0 = c.w - 4
    if #fxs > 0 and dbot - dtop >= L.rh + 4 and bw0 >= 3 * L.cw then
      local bx0 = c.x + 2
      local avail = dbot - dtop
      -- 11 окт: схема (как вкладка fx routing): рамка с именем, между блоками — провод;
      -- параметры — только в большом виде (зум) с опцией p
      local withp = opts and opts.params
      local gap = withp and 2 or 8
      local bh0 = withp and math.max(L.rh + 4, math.min(6 * L.rh + 4, math.floor(avail / #fxs) - gap)) or (L.rh + 4)
      local yb = dbot
      for k, f in ipairs(fxs) do
        local by0 = yb - bh0
        if by0 < dtop then
          text(bx0 + 2, dtop, fit(('+%d'):format(#fxs - k + 1), bw0 - 4), U.GREY); break
        end
        local hot = mx >= bx0 and mx < bx0 + bw0 and my >= by0 and my < yb
        if k > 1 then set(U.LINE); gfx.rect(c.x + math.floor(c.w / 2), yb, 1, gap, 1) end     -- провод к прошлому блоку
        set(hot and D.CURROW or U.BG); gfx.rect(bx0, by0, bw0, bh0, 1)
        set(hot and U.AMBER or (f.enabled and U.LINE or U.DIM)); gfx.rect(bx0, by0, bw0, bh0, 0)
        text(bx0 + 2, by0 + 2, fit(f.name or '?', bw0 - 4), f.enabled and (f.container and U.AMBER or U.TEXT) or U.GREY)
        local prow = withp and math.floor((bh0 - L.rh - 4) / L.rh) or 0
        local pw = bw0 - 6
        for pi = 1, math.min(prow, #(f.params or {})) do
          local pp = f.params[pi]
          local py = by0 + 2 + pi * L.rh
          local okp, v = pcall(reaper.TrackFX_GetParamNormalized, tr, pp.fx or f.i, pp.i)
          local nl = fit(pp.name or '', math.floor(pw * 0.45))
          text(bx0 + 3, py, nl, U.GREY)
          local bx1 = bx0 + 3 + math.floor(pw * 0.48)
          local bw1 = bx0 + bw0 - 3 - bx1
          if bw1 > 4 then
            set(U.mix(U.LINE, U.BG, 0.4)); gfx.rect(bx1, py + math.floor(L.rh / 2) - 1, bw1, 2, 1)
            if okp and v then set(f.enabled and U.CYAN or U.GREY); gfx.rect(bx1, py + math.floor(L.rh / 2) - 1, math.max(1, math.floor(bw1 * v)), 2, 1) end
          end
        end
        if hot then hover.rdev = { col = c.col, k = k, master = c.master } end
        yb = by0 - gap
      end
    end
  end
  for k, l in ipairs(links) do
    local ly = bot - k * step
    if ly < y + L.rh + 4 then break end
    local e = l.e
    if e.kind == 'hw' then set(e.mute and U.GREY or U.AMBER)
    elseif e.kind == 'main' then set(U.mix(U.GREY, U.BG, 0.3))
    else set(e.mute and U.GREY or U.CYAN) end
    local a, b = l.a + ((k % 3) - 1) * 2, l.b + ((k % 3) - 1) * 2
    gfx.rect(a, ly, 1, bot - ly + 1, 1)                        -- из колонки вверх
    gfx.rect(math.min(a, b), ly, math.abs(b - a) + 1, 1, 1)    -- по полосе
    if e.to.hw then
      text(b + 3, ly - math.floor(L.th / 2), e.to.name, e.mute and U.GREY or U.AMBER)
    else
      gfx.rect(b, ly, 1, bot - ly + 1, 1)                      -- вниз в получателя
      gfx.triangle(b - 2, bot - 3, b + 2, bot - 3, b, bot)
    end
    gfx.rect(a - 1, ly - 1, 3, 3, 1)                           -- узел у источника
  end
  -- щелчок над колонкой — её маршрутизация
  if my >= y and my < y + h then
    for tr, c in pairs(cc) do
      if not hover.rdev and mx >= c.x and mx < c.x + c.w then hover.btn = { col = c.col, what = 'route' } end
    end
  end
  return hover
end

-- схема маршрутизации над нижним микшером (9 окт, опция mixer routing):
-- в каждой колонке — дорожки выходов (сенды, аппаратные) с вертикальными
-- именами, под ними провода к колонке получателя (цвет получателя). Щелчок
-- по дорожке — меню маршрутизации трека. Высота — по длинному имени (D.rt_need)
-- 11 окт: модуль tracks — как Track Manager в REAPER: все треки строками (отступ по
-- вложенности, цвет, папка > / -), справа матрица флажков: T — виден в трекере,
-- tcp / mcp — в REAPER (арранжировка / микшер), M S R — mute / solo / arm.
-- Щелчок по клетке — переключить, протяжка вниз по столбцу — то же значение на
-- все строки (как в REAPER), щелчок по заголовку столбца — весь столбец, по имени —
-- к треку, ПКМ по имени — скрыть / показать в трекере, колесо — листать.
-- Клавиатура (фокус tracks): j k строки, h l столбцы, Space — клетка, Enter — к треку,
-- a — весь столбец, z — папка, / — фильтр по имени
D.TL = { cur = 1, col = 1, scroll = 0, filter = '', typing = false }
D.tl_scroll = 0
D.TL_ALL = {
  { k = 'T',   h = 'T',   d = 'shown in the tracker (and its mixer strip)' },
  { k = 'tcp', h = 'tcp', d = 'REAPER: shown in the arrange view (TCP)' },
  { k = 'mcp', h = 'mcp', d = 'REAPER: shown in the mixer (MCP)' },
  { k = 'M',   h = 'M',   d = 'mute' },
  { k = 'S',   h = 'S',   d = 'solo' },
  { k = 'R',   h = 'R',   d = 'record arm' },
}
-- 13 окт: tcp / mcp — только с опцией tracks: tcp / mcp (state.tlrp); D.TL_COLS — видимые (кадр ставит)
D.TL_SHORT = { D.TL_ALL[1], D.TL_ALL[4], D.TL_ALL[5], D.TL_ALL[6] }
D.TL_COLS = D.TL_SHORT
-- строки списка: индексы snap.cols; свёрнутые папки прячут детей, фильтр — по имени
-- (с фильтром видны и треки из свёрнутых папок)
function D.tl_rows(state, snap)
  local cols, list, hide_below = snap and snap.cols or {}, {}, nil
  local f = (D.TL.filter or ''):lower()
  for ci, col in ipairs(cols) do
    local d = col.depth or 0
    if f ~= '' then
      if (col.name or ''):lower():find(f, 1, true) then list[#list + 1] = ci end
    else
      if hide_below and d <= hide_below then hide_below = nil end
      if not hide_below then list[#list + 1] = ci end
      if not hide_below and col.folder and state.fcollapse and state.fcollapse[col.guid] then hide_below = d end
    end
  end
  return list
end
-- 13 окт: дерево как в lf — трек (папка) → его инструменты (папки: слайсы, варианты лупа) → его
-- automation; неиспользуемые инструменты — папка lib в конце. Строки:
-- { k = 't', ci } трек · { k = 'i', ci, i } инструмент (i — номер в пуле) · { k = 'c', ci, i } его ребёнок ·
-- { k = 'a', ci, n } папка automation трека · { k = 'ai', ci, env, ai } item автоматизации · { k = 'lib', n } папка lib.
-- Открыто: трек — пока не TL.closed[guid]; инструмент / automation / lib — TL.open[ключ]. С фильтром — только треки.
function D.tl_tree(state, snap)
  local TL = D.TL
  TL.open, TL.closed = TL.open or {}, TL.closed or {}
  local cols = snap and snap.cols or {}
  local out = {}
  local tl = D.tl_rows(state, snap)
  local pool = (cols[1] and cols[1].pool) or {}
  local kids = {}
  for j, e in ipairs(pool) do if e.parent then kids[e.parent] = kids[e.parent] or {}; table.insert(kids[e.parent], j) end end
  -- 13 окт: внутри инструмента — его слайсы (S01 … с клавишей, что их играет; вместо модуля slices),
  -- варианты лупа L1 … и куски, что не слайсы
  local function inst_rows(ci, i, d)
    local e = pool[i]
    local key = 'i:' .. (e.gkey or tostring(i))
    local other = {}
    for _, j in ipairs(kids[e] or {}) do if not (e.slices and pool[j].slice_k and pool[j].slice_k > 0) then other[#other + 1] = j end end
    local ns = e.slices and #e.slices or 0
    local nl = e.layers and #e.layers or 0                -- 19 окт: слоёный ¥ — его слои папкой, как слайсы
    out[#out + 1] = { k = 'i', ci = ci, i = i, d = d, key = key, nk = ns + #other + nl, ns = ns }
    if TL.open[key] then
      for lk = 1, nl do out[#out + 1] = { k = 'y', ci = ci, i = i, lk = lk, d = d + 1 } end
      for sk = 1, ns do out[#out + 1] = { k = 's', ci = ci, i = i, sk = sk, d = d + 1 } end
      for _, j in ipairs(other) do out[#out + 1] = { k = 'c', ci = ci, i = j, d = d + 1 } end
    end
  end
  -- 13 окт: корень используется на треке, если там лежит он сам или любой его кусок / слайс / вариант
  -- (нота — отдельная запись того же файла, дочерняя корню из lib: раньше корень числился «not used»)
  local uses = {}
  for _, e in ipairs(pool) do
    local r, n = e, 0
    while r.parent and n < 16 do r = r.parent; n = n + 1 end
    for nm in pairs(e.track_set or {}) do uses[r] = uses[r] or {}; uses[r][nm] = true end
  end
  local function used_on(e, nm) return uses[e] and uses[e][nm] end
  local filt = (TL.filter or '') ~= ''
  for _, ci in ipairs(tl) do
    local col = cols[ci]
    local d = col.depth or 0
    local n, ais = 0, 0
    for i, e in ipairs(pool) do if not e.parent and used_on(e, col.name) then n = n + 1 end end
    for _, en in ipairs(col.envs or {}) do ais = ais + #(en.ais or {}) end
    n = n + #(D.tl_insts and D.tl_insts(col) or {})
    out[#out + 1] = { k = 't', ci = ci, d = d, n = n + ais }
    if not filt and not TL.closed[col.guid] then
      for i, e in ipairs(pool) do if not e.parent and used_on(e, col.name) then inst_rows(ci, i, d + 1) end end
      -- 13 окт: MIDI-клипы трека — папкой (раньше — в модуле slices при выбранном midi)
      -- 13 окт: плагины-инструменты трека (RS5K, VSTi, киты) — строками, выбор как в lib
      for _, fi in ipairs(D.tl_insts and D.tl_insts(col) or {}) do out[#out + 1] = { k = 'p', ci = ci, d = d + 1, fx = fi.fx, name = fi.name, kind = fi.kind } end
      local mcs = D.tl_midi and D.tl_midi(col) or {}
      if #mcs > 0 then
        local key = 'm:' .. col.guid
        out[#out + 1] = { k = 'm', ci = ci, d = d + 1, n = #mcs, key = key }
        if TL.open[key] then for _, mc in ipairs(mcs) do out[#out + 1] = { k = 'mc', ci = ci, d = d + 2, mc = mc } end end
      end
      if ais > 0 then
        local key = 'a:' .. col.guid
        out[#out + 1] = { k = 'a', ci = ci, d = d + 1, n = ais, key = key }
        if TL.open[key] then
          for _, en in ipairs(col.envs or {}) do for _, ai in ipairs(en.ais or {}) do out[#out + 1] = { k = 'ai', ci = ci, d = d + 2, env = en, ai = ai } end end
        end
      end
    end
  end
  if not filt then
    local un = {}
    for i, e in ipairs(pool) do if not e.parent and not (uses[e] and next(uses[e])) then un[#un + 1] = i end end
    if #un > 0 then
      out[#out + 1] = { k = 'lib', n = #un, d = 0, key = 'lib' }
      if TL.open.lib then for _, i in ipairs(un) do inst_rows(nil, i, 1) end end
    end
  end
  return out
end

-- 13 окт: превью сэмпла строкой дерева (как колонка preview прежней lib): волна e (или его куска
-- [a, b] секунд), выбранный слайс / кусок — инверсией (D.lib_zone), границы слайсов — чёрточками
local function tree_wave(L, e, wx, y, npix, rh, a, b)
  if npix < 8 or not e then return end
  local len = e.len or 0
  if len <= 0 then return end
  a, b = a or 0, b or len
  local head = e
  if a > 0 or b < len then
    local r = (e.rate and e.rate > 0) and e.rate or 1
    head = { src = e.src, guid = tostring(e.guid) .. ':' .. ('%.4f'):format(a), offs = (e.offs or 0) + a * r, len = b - a, rate = r }
  end
  local pk = get_peaks and get_peaks(head, npix)
  local rgb = e.rgb or U.CYAN
  local wc = U.readable(U.mix(rgb, U.TEXT, 0.35), U.BG, 4.0)
  local cy, hh = y + rh / 2, rh / 2 - 1
  local za, zb
  local z = D.lib_zone
  if z and z.root == e and head == e then
    za = math.floor(math.max(0, z.a) / len * npix)
    zb = math.max(za + 1, math.floor(math.min(len, z.b) / len * npix))
    set(wc); gfx.rect(wx + za, y, zb - za, rh, 1)
  end
  set(wc)
  if pk and pk.n and pk.n > 0 then
    for px = 0, npix - 1 do
      local idx = math.floor(px / npix * pk.n) + 1
      local lo, hi = pk.min[idx] or 0, pk.max[idx] or 0
      if hi - lo < 0.03 then lo, hi = -0.015, 0.015 end
      local inz = za and px >= za and px < zb
      if inz then set(U.BG) end
      gfx.line(wx + px, cy - hi * hh, wx + px, cy - lo * hh)
      if inz then set(wc) end
    end
  else gfx.line(wx, cy, wx + npix, cy) end
  if head == e and e.slices then
    set(U.mix(wc, U.BG, 0.35))
    for _, t in ipairs(e.slices) do
      local px = wx + math.floor(t / len * npix)
      if px > wx and px < wx + npix and not (za and px - wx >= za and px - wx <= zb) then gfx.rect(px, y + 1, 1, rh - 2, 1) end
    end
  end
end

function D.track_list(L, state, snap, info, hover, x, y, w, h, foc)
  local TL = D.TL
  local mx, my = gfx.mouse_x, gfx.mouse_y
  D.TL_COLS = state.tlrp and D.TL_ALL or D.TL_SHORT
  set(U.PANEL); gfx.rect(x, y, w, h, 1)             -- 13 окт: фон панели темы, как у соседей (был чёрный BG)
  local cols = snap and snap.cols or {}
  local list = D.tl_tree(state, snap)                   -- 13 окт: дерево (треки, инструменты, automation)
  TL.rows = list
  TL.n = #list
  if TL.follow then                                      -- 13 окт: после правки дерева — курсор на тот же трек
    for li, r in ipairs(list) do if r.k == 't' and cols[r.ci] and cols[r.ci].guid == TL.follow then TL.cur = li; TL.follow = nil; break end end
  end
  TL.cur = math.max(1, math.min(TL.cur, math.max(1, #list)))
  TL.col = math.max(1, math.min(TL.col, #D.TL_COLS))
  -- ширина столбцов матрицы; не влезает с именем (меньше 6 знаков) — столбцы справа отпадают
  local cw = {}
  for i, c in ipairs(D.TL_COLS) do cw[i] = math.max(ms(c.h), ms('W')) + L.pad end
  local ncol = #D.TL_COLS
  local function mw(n) local s = 0; for i = 1, n do s = s + cw[i] end; return s end
  while ncol > 1 and w - 2 * L.pad - mw(ncol) < 6 * L.cw do ncol = ncol - 1 end
  local gx = x + w - L.pad - 3 - mw(ncol)            -- левый край матрицы (3 px — полоса прокрутки)
  local inside = mx >= x and mx < x + w and my >= y and my < y + h
  -- строка 0: «tracks N» или фильтр, заголовки столбцов
  local ttl = (TL.typing or TL.filter ~= '') and ('/' .. TL.filter .. (TL.typing and '_' or '')) or ('tracks %d'):format(#cols)
  -- 13 окт: кнопка zoom — слайсы строками с волной (+ - в модуле: x1..x3; щелчок: x1 / x2)
  local zl = (TL.zoom or 1) > 1 and ('zoom x' .. TL.zoom) or 'zoom'
  local zbw = ms(zl) + 2 * L.pad
  local zbx = gx - zbw - L.pad
  local zroom = zbx > x + L.pad + ms('tracks 99') + L.pad
  if zroom then
    local zh = inside and my >= y and my < y + L.rh and mx >= zbx and mx < zbx + zbw
    set((TL.zoom or 1) > 1 and U.tint(U.AMBER, 0.3) or (zh and D.CURROW or U.BG)); gfx.rect(zbx, y, zbw, L.rh, 1)
    set((zh or (TL.zoom or 1) > 1) and U.AMBER or U.LINE); gfx.rect(zbx, y, zbw, L.rh, 0)
    text(zbx + L.pad, y, zl, (zh or (TL.zoom or 1) > 1) and U.AMBER or U.GREY)
    if zh then hover.tlist_zoom = true end
  end
  text(x + L.pad, y, fit(ttl, (zroom and zbx or gx) - x - 2 * L.pad), (TL.typing or TL.filter ~= '') and U.CYAN or U.GREY)
  local cx = gx
  for i = 1, ncol do
    local c = D.TL_COLS[i]
    local hot = inside and my >= y and my < y + L.rh and mx >= cx and mx < cx + cw[i]
    local sel = foc and i == TL.col
    text(cx + math.floor((cw[i] - ms(c.h)) / 2), y, c.h, hot and U.AMBER or (sel and U.CYAN or U.GREY))
    if hot then hover.tlist_hdr = c.k end
    hint('tlhdr', cx, y, cw[i], L.rh, c.k)
    cx = cx + cw[i]
  end
  local nvis = math.max(1, math.floor((h - L.rh) / L.rh))
  TL.nvis = nvis
  -- 13 окт: высота строки — слайс с волной при зуме выше
  local function rowh(r) return (r and r.k == 's' and (TL.zoom or 1) > 1) and L.rh * TL.zoom or L.rh end
  local function fit_from(s0)
    local hh, n = h - L.rh, 0
    while list[s0 + n + 1] and hh - rowh(list[s0 + n + 1]) >= 0 do hh = hh - rowh(list[s0 + n + 1]); n = n + 1 end
    return math.max(1, n)
  end
  -- клавиатурный курсор — в видимых строках
  if foc then
    if TL.cur <= TL.scroll then TL.scroll = TL.cur - 1 end
    while TL.cur > TL.scroll + fit_from(TL.scroll) do TL.scroll = TL.scroll + 1 end
  end
  TL.scroll = math.max(0, math.min(TL.scroll, math.max(0, #list - nvis)))
  D.tl_scroll = TL.scroll
  if inside then hover.tlist_area = { n = #list, nvis = nvis } end
  local cf = info.vcur and L.flat and L.flat[info.vcur.fi]
  local cg = cf and cf.col and cf.col.guid
  local get = info.tl_get
  local pool = (cols[1] and cols[1].pool) or {}
  local ry0, li = y + L.rh, TL.scroll
  while true do
    li = li + 1
    local rw = list[li]
    if not rw then break end
    local rhh = rowh(rw)
    if ry0 + rhh > y + h then break end
    local ry = ry0
    ry0 = ry0 + rhh
    if rw.k ~= 't' then
      -- 13 окт: строка внутри трека: инструмент (номер, цвет, имя; + / - — его слайсы и варианты), automation, lib
      local hot = inside and my >= ry and my < ry + rhh
      local kc = foc and li == TL.cur
      local e = rw.i and pool[rw.i]
      local on = e and info.inst_cur and info.inst_cur() == rw.i
      if on or hot or kc then set(on and U.tint(U.AMBER, 0.3) or U.tint(U.AMBER, 0.15)); gfx.rect(x, ry, w, rhh, 1) end
      if kc then set(D.FOCUS or U.CYAN); gfx.rect(x, ry, 2, rhh, 1) end
      local ix = x + L.pad + (rw.d or 0) * math.floor(L.cw / 2) + 5
      local lbl, colr
      if rw.k == 's' then
        -- слайс: клавиша, что его играет (раскладка октавы курсора), Sxx — команда в трекере, имя / длина
        local kl = info.slice_note and info.slice_note(rw.sk) or nil   -- 19 окт: нота слайса (была клавиша)
        local t0 = e and e.slices and e.slices[rw.sk] or 0
        local t1 = e and e.slices and (e.slices[rw.sk + 1] or e.len) or t0
        local ss = info.ssel and info.ssel()
        local son = ss and e and ss.item == e.item and ss.k == rw.sk
        lbl = ('%-3s  S%02X  %.2fs'):format(kl or '---', rw.sk, math.max(0, t1 - t0))
        colr = son and U.AMBER or U.TEXT
        if son then set(U.tint(U.AMBER, 0.25)); gfx.rect(x, ry, w, rhh, 1) end
        -- зум: волна куска строкой ниже подписи (как было в модуле slices)
        if rhh > L.rh and info.mini_wave and e then info.mini_wave(e, t0, t1, ix, ry + L.rh, x + w - ix - L.pad - 3, rhh - L.rh - 2, son and U.AMBER or U.mix(U.TEXT, U.BG, 0.3)) end
      elseif rw.k == 'y' then
        -- 19 окт: слой ¥: имя его сэмпла, сдвиг / громкость / цикл, m — выключен, p — фаза
        local l = e and e.layers and e.layers[rw.lk]
        local src = l and info.layer_src and info.layer_src(l.guid)
        local fl = l and ((l.mute and ' m' or '') .. (l.phase and ' p' or '') .. ((l.cn or 1) > 1 and (' %d/%d'):format(l.ck, l.cn) or '')) or ''
        lbl = l and ('¥ L%d %s  %+gms %+gdB%s'):format(rw.lk, src and src.name or '?', l.offs or 0, l.vol or 0, fl) or '¥ ?'
        colr = (l and l.mute) and U.DIM or U.TEXT
      elseif rw.k == 'm' then lbl = ((TL.open[rw.key] and '- ') or '+ ') .. (D.mu() .. ' midi clips  %d'):format(rw.n); colr = U.GREY
      elseif rw.k == 'mc' then lbl = D.mu() .. ' ' .. ((rw.mc.label or '') ~= '' and rw.mc.label or 'clip') .. ('  %04d'):format(rw.mc.row or 0); colr = U.CYAN
      elseif rw.k == 'i' or rw.k == 'c' then
        if e and e.rgb then rawset_col(e.rgb); gfx.rect(ix - 5, ry + 2, 2, L.rh - 4, 1) end
        local mk = rw.k == 'i' and (rw.nk > 0 and ((TL.open[rw.key] and '- ') or '+ ') or '  ') or ''
        local nm = e and e.name or '?'
        if rw.k == 'c' and e then nm = (e.lvar_n and ('L' .. e.lvar_n)) or (e.slice_k and e.slice_k > 0 and ('s' .. e.slice_k)) or 'cut' end
        lbl = ('%s%02d %s'):format(mk, rw.i, nm)
        if rw.k == 'i' and (rw.ns or 0) > 0 and info.slice_key then   -- нарезан: клавиша целого сэмпла (S00)
          local kl = info.slice_key(0)
          if kl then lbl = lbl .. '  ' .. kl .. ' whole' end
        end
        colr = on and U.AMBER or (rw.k == 'c' and U.GREY or U.TEXT)
      elseif rw.k == 'a' then lbl = ((TL.open[rw.key] and '- ') or '+ ') .. ('~ automation  %d'):format(rw.n); colr = U.GREY
      elseif rw.k == 'p' then
        local sel = info.inst_fx and info.inst_fx(cols[rw.ci]) == rw.fx
        lbl = '~ ' .. (rw.name or 'instrument'); colr = sel and U.AMBER or U.CYAN
        if sel then set(U.tint(U.AMBER, 0.3)); gfx.rect(x, ry, w, rhh, 1) end
      elseif rw.k == 'ai' then lbl = '~ ' .. (rw.env.name or '') .. ((rw.ai.label or '') ~= '' and ('  ' .. rw.ai.label) or ''); colr = U.CYAN
      else lbl = ((TL.open[rw.key] and '- ') or '+ ') .. ('lib/  %d not used'):format(rw.n); colr = U.GREY end
      -- превью справа: инструмент — весь сэмпл (выбранный кусок инверсией), слайс — его кусок
      local pw = math.floor(w * 0.38)
      local px0 = x + w - L.pad - 3 - pw
      local lab_w = x + w - ix - L.pad
      if e and (rw.k == 'i' or rw.k == 'c' or (rw.k == 's' and rhh <= L.rh)) and px0 > ix + ms(lbl) + L.pad then
        lab_w = px0 - L.pad - ix
        if rw.k == 's' then
          local t0 = e.slices and e.slices[rw.sk] or 0
          tree_wave(L, e, px0, ry, pw, L.rh, t0, e.slices and (e.slices[rw.sk + 1] or e.len) or e.len)
        else tree_wave(L, e, px0, ry, pw, L.rh) end
      end
      text(ix, ry, fit(lbl, lab_w), colr)
      if hot then
        hover.tlist = { ci = rw.ci, what = 'row', li = li }
        -- 13 окт: щелчок по «+ / -» — открыть / закрыть папку (инструмент, automation, midi, lib)
        local c1 = lbl:sub(1, 1)
        if rw.key and (c1 == '+' or c1 == '-') and mx >= ix - 4 and mx < ix + ms('+ ') then hover.tlist.fold_key = rw.key end
      end
      goto tl_next
    end
    local ci = rw.ci
    local col = cols[ci]
    local hid = state.thide and state.thide[col.guid]
    local on = cg and col.guid == cg
    local kc = foc and li == TL.cur
    local hot = inside and my >= ry and my < ry + L.rh
    if on or hot or kc then set(on and U.tint(U.AMBER, 0.3) or U.tint(U.AMBER, 0.15)); gfx.rect(x, ry, w, L.rh, 1) end
    if kc then set(D.FOCUS or U.CYAN); gfx.rect(x, ry, 2, L.rh, 1) end
    if TL.marks and TL.marks[col.guid] then set(U.tint(U.CYAN, 0.3)); gfx.rect(x + 2, ry, w - 2, L.rh, 1); set(U.CYAN); gfx.rect(x, ry, 2, L.rh, 1) end   -- 13 окт: отмечен (Space)
    local ix = x + L.pad + (TL.filter ~= '' and 0 or (col.depth or 0) * math.floor(L.cw / 2))
    if col.rgb then rawset_col(col.rgb); gfx.rect(ix, ry + 2, 3, L.rh - 4, 1) end
    ix = ix + 5
    local fw = 0
    if col.folder then
      local fl = (state.fcollapse and state.fcollapse[col.guid]) and '>' or '-'
      fw = ms(fl) + L.pad
      local fh = hot and mx >= ix and mx < ix + fw
      text(ix, ry, fl, fh and U.AMBER or U.CYAN)
      if fh then hover.tlist = { ci = ci, what = 'fold' } end
    end
    local tnm = col.name ~= '' and col.name or ('Track ' .. ci)
    if TL.closed and TL.closed[col.guid] and (rw.n or 0) > 0 then tnm = tnm .. '  +' .. rw.n end   -- 13 окт: закрыт — сколько внутри
    text(ix + fw, ry, fit(tnm, gx - ix - fw - L.pad), on and U.AMBER or (hid and U.DIM or U.TEXT))
    if hot and not hover.tlist and mx < gx then hover.tlist = { ci = ci, what = 'go', li = li } end
    hint('tlist', x, ry, gx - x, L.rh, { ci = ci, what = 'go' })
    -- матрица флажков: включено — буква столбца на подложке, выключено — точка
    cx = gx
    for k = 1, ncol do
      local c = D.TL_COLS[k]
      local v = get and get(col, c.k)
      local ch = hot and mx >= cx and mx < cx + cw[k]
      local ksel = kc and k == TL.col
      if v then set(U.tint(c.k == 'R' and (D.ARM or U.RED) or ((c.k == 'M' or c.k == 'S') and U.AMBER or U.CYAN), ch and 0.45 or 0.28)); gfx.rect(cx + 1, ry + 1, cw[k] - 2, L.rh - 2, 1) end
      if ch or ksel then set(ch and U.AMBER or (D.FOCUS or U.CYAN)); gfx.rect(cx + 1, ry + 1, cw[k] - 2, L.rh - 2, 0) end
      local lbl = v and c.h or '.'
      text(cx + math.floor((cw[k] - ms(lbl)) / 2), ry, lbl, v and U.TEXT or U.DIM)
      if ch then hover.tlist = { ci = ci, what = 'cell', key = c.k, li = li } end
      cx = cx + cw[k]
    end
    ::tl_next::
  end
  if #list > nvis and D.vbar then D.vbar('tlist', x + w - 3, y + L.rh, 3, nvis * L.rh, TL.scroll, nvis, #list) end
  if inside and hover.tlist_hdr then
    for _, c in ipairs(D.TL_COLS) do if c.k == hover.tlist_hdr then hover.tlist_tip = c.d end end
  elseif inside and hover.tlist and hover.tlist.what == 'cell' then
    for _, c in ipairs(D.TL_COLS) do if c.k == hover.tlist.key then hover.tlist_tip = c.d end end
  end
end

-- 11 окт: шаблоны треков — «< имя >» в шапке DSP; D.PR.cur — текущий (стрелки, выпадашка)
D.PR = { cur = 1 }

function D.route_strip(L, info, hover, x0, x1)
  local y0, h = L.route_y, L.route_h
  if not y0 or h <= 0 then return end
  local mx, my = gfx.mouse_x, gfx.mouse_y
  set(U.PANEL); gfx.rect(x0, y0, x1 - x0, h, 1)
  set(D.SEP); gfx.rect(x0, y0, x1 - x0, D.SEPW, 1)
  local cw1 = ms('W')
  local lw = L.th + 4
  local wires_h = 10
  local nameh = h - wires_h - 4
  local xof = {}                                    -- трек → середина его колонки
  for _, c in ipairs(L.cols or {}) do if c.col and c.col.track and c.x then xof[c.col.track] = c.x + math.floor(c.w / 2) end end
  local need, wires = 0, {}
  for _, c in ipairs(L.cols or {}) do
    local col = c.col
    local tr = col and col.track
    if tr and not c.master and c.x and c.x + c.w > x0 and c.x < x1 and reaper.ValidatePtr(tr, 'MediaTrack*') then
      set(U.LINE); gfx.rect(c.x, y0, 1, h, 1)
      local outs = {}
      for _, e in ipairs(routing_of(tr)) do if not e.recv and not e.main then outs[#outs + 1] = e end end
      local fit_n = math.max(0, math.floor((c.w - 4) / lw))
      for k, e in ipairs(outs) do
        if k > fit_n then break end
        local lx = c.x + 2 + (k - 1) * lw
        if k == fit_n and #outs > fit_n then text(lx + 1, y0 + 3, '+', U.CYAN); break end
        local tc = e.mute and U.GREY or (e.hw and U.AMBER or U.CYAN)
        local hot = mx >= lx and mx < lx + lw and my >= y0 and my < y0 + h
        if hot then set(D.CURROW); gfx.rect(lx, y0 + 2, lw - 1, h - 3, 1); hover.btn = { col = col, what = 'route', send = e } end   -- 16 окт: Option+клик — удалить этот маршрут
        D.vtext(lx + 2, y0 + 3, nameh, e.name, tc, hot and D.CURROW or U.PANEL, true)
        need = math.max(need, #e.name)
        if e.dest and xof[e.dest] then wires[#wires + 1] = { x = lx + math.floor(lw / 2), tx = xof[e.dest], rgb = e.rgb, mute = e.mute, col = col, e = e } end
        hint('btn', lx, y0 + 2, lw, h - 3, { col = col, what = 'route' })
      end
      if #outs == 0 then text(c.x + L.pad, y0 + 3, '-', U.DIM) end
    end
  end
  -- провода: вниз из дорожки, по горизонтали к колонке получателя, стрелка вниз
  local wy0 = y0 + h - wires_h - 1
  -- 16 окт: провод под мышью (±2 px) — янтарём; Option+клик удаляет маршрут, клик — меню маршрутизации
  local whot
  for k, w in ipairs(wires) do
    local y = wy0 + 2 + ((k - 1) % 4) * 2
    local near = (my >= y - 2 and my <= y + 2 and mx >= math.min(w.x, w.tx) - 2 and mx <= math.max(w.x, w.tx) + 2)
      or (math.abs(mx - w.x) <= 2 and my >= wy0 - 1 and my <= y) or (math.abs(mx - w.tx) <= 2 and my >= y and my < y0 + h)
    if near then whot = k end
  end
  if whot then local w = wires[whot]; hover.btn = { col = w.col, what = 'route', send = w.e } end
  for k, w in ipairs(wires) do
    local y = wy0 + 2 + ((k - 1) % 4) * 2
    if k == whot then set(U.AMBER) elseif w.mute then set(U.GREY) elseif w.rgb then rawset_col(w.rgb) else set(U.CYAN) end
    gfx.rect(w.x, wy0 - 1, 1, y - wy0 + 1, 1)
    gfx.rect(math.min(w.x, w.tx), y, math.abs(w.tx - w.x) + 1, 1, 1)
    gfx.rect(w.tx, y, 1, y0 + h - 1 - y, 1)
    gfx.rect(w.tx - 1, y0 + h - 3, 3, 1, 1)
  end
  D.rt_need = need == 0 and (L.rh + 4) or (math.max(3, math.min(10, need)) * cw1 + wires_h + 6)   -- нет выходов — одна строка
end

D.PANE_KEYS = { { 'Cmd+hjkl', 'panel' }, { 'Cmd+Shift+hjkl', 'move' }, { 'Ctrl+W', 'panes' }, { 'F2', 'tracker' }, { '?', 'help' } }
-- 15 окт: стандарт подсказок ВЕЗДЕ (активный модуль или нет): клавиша — акцентным цветом на 75 %,
-- описание — текстом на 60 % (тускло, но читаемо); на фоне bg, с проверкой контраста
function D.hint_colors(bg)
  bg = bg or U.PANEL
  -- 15 окт: клавиша тише (60 %); 24 окт: клавиша средней яркости, описание совсем тихое
  return U.readable(U.mix(bg, U.AMBER, 0.70), bg, 3.0), U.readable(U.mix(bg, U.TEXT, 0.38), bg, 1.8)
end
-- строка подсказок одной строкой: куски через 2+ пробела; «клавиша: что» — по двоеточию,
-- иначе последнее слово — что, остальное — клавиши («q whole», «2 w 3 e ... slices»)
function D.hint_text(x, y, s, maxw, bg)
  local kc, dc = D.hint_colors(bg)
  local cx, x1 = x, x + (maxw or 1e9)
  local sp = ms(' ') > 0 and ms(' ') or 4
  for raw in (s .. '  '):gmatch('(.-)%s%s+') do
    local chunk = raw:gsub('^%s+', '')
    if chunk ~= '' then
      local k, d = chunk:match('^(.-):%s*(.*)$')
      if not k then k, d = chunk:match('^(.*)%s(%S+)$') end
      if not k then k, d = chunk, '' end
      local kw, dw = ms(k), (d ~= '' and ms(d) or 0)
      if cx + kw > x1 then break end
      text(cx, y, k, kc)
      if d ~= '' then
        if cx + kw + sp + dw > x1 then text(cx + kw + sp, y, D.fit(d, x1 - cx - kw - sp), dc); break end
        text(cx + kw + sp, y, d, dc)
      end
      cx = cx + kw + (d ~= '' and (sp + dw) or 0) + 2 * sp
    end
  end
end
-- 15 окт: режим подсказок для кэша раскладки: 0 нет / в статусе, 1 под панелью, 2 в строке вкладок
-- 15 окт: кнопка s/e матрицы выключена — маркеров =START / =END нет нигде (линейка у мастера, линии по трекам)
function D.se_hidden(state, mk) return state.mxmarks == false and (mk.name == '=START' or mk.name == '=END') end
function D.hint_mode(state) return state.hints and ((state.hintpos == 'panes' and 1) or (state.hintpos == 'tabs' and 2)) or 0 end
-- пары «клавиша что» в строку от x до x1 (строка вкладок): с подложкой — по строке идёт линия рамки
function D.hint_pairs(x, y, x1, items, bg)
  local kc, dc = D.hint_colors(bg)
  local sp = math.max(4, ms(' '))
  -- сначала — что влезает, потом одна сплошная подложка (по частям — линия рамки просвечивала «-» между парами)
  local fit_n, cx = 0, x
  for i, it in ipairs(items or {}) do
    local w2 = ms(it[1]) + sp + ms(it[2])
    if cx + w2 > x1 then break end
    fit_n, cx = i, cx + w2 + 2 * sp
  end
  if fit_n == 0 then return end
  set(bg or U.PANEL); gfx.rect(x - 2 * sp, y - 1, cx - x, (type(TH) == 'function' and TH() or 12) + 2, 1)
  cx = x
  for i = 1, fit_n do
    local it = items[i]
    local kw = ms(it[1])
    text(cx, y, it[1], kc)
    text(cx + kw + sp, y, it[2], dc)
    cx = cx + kw + sp + ms(it[2]) + 2 * sp
  end
end
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
    local kc, dc = D.hint_colors(U.PANEL)
    text(cx, y + 1, it[1], kc)
    text(cx + kw + sp, y + 1, it[2], dc)
    cx = cx + kw + sp + dw + 2 * sp
  end
end

-- вертикальный текст (имена треков в матрице). gfx.blit с поворотом режет
-- результат прямоугольником назначения, поэтому поворачиваем честно:
-- текст → картинка A (w×h) → попиксельно в картинку B (h×w), B блитится с
-- масштабом. Кеш по строке+цвету, картинки 1000..1022 (сброс по кругу).
-- вертикальный текст: картинки 800..935 (136 подписей: имена в матрице,
-- регионы и маркеры линейки), 1023 — черновик поворота
local VFIRST, VLAST = 800, 934   -- 11 окт: 936..959 — превью визора (кольцо картинок ReaVisor); 13 окт: 935 — живая картинка визора
local vcache, vnext = {}, VFIRST
D.reset_vcache = function() vcache, vnext = {}, VFIRST end
-- top = true — прижать к верху отведённой высоты (имена на линейке, 2 окт),
-- иначе к низу (имена треков в матрице растут снизу, как в Renoise)
function D.vtext(x, y, h_avail, str, col, bg, top)
  bg = bg or U.PANEL
  -- 16 окт: по настоящей ширине слова (было по W — step в две строки резался до ste)
  while #str > 1 and ms(str) > h_avail do str = str:sub(1, -2) end
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

-- 19 окт: трек с рэком drumrs5k (кэш на снимок: col живёт до перестройки)
local kit_cols = setmetatable({}, { __mode = 'k' })
function D.col_is_kit(col)
  local fx = col.fx   -- ключ — сам список FX: колонка живёт дольше, fx приходит позже / пересобирается
  if not fx then return false end
  local v = kit_cols[fx]
  if v == nil then
    v = false
    for _, f in ipairs(fx) do if f.kit then v = true; break end end
    kit_cols[fx] = v
  end
  return v
end
function D.field_rect(L, fld)
  if fld == 'inst' then return L.x_inst or L.x_note, ms('00') end      -- поле инструмента (5 окт)
  if fld == 'slc' then return L.x_slc or L.x_note, L.w_slc or ms('S00') end   -- 11 окт: поле слайса
  if fld == 'pan' then return L.x_pan or L.x_vol, L.w_pan or ms('00') end      -- 14 окт: поле пана
  if fld == 'wave' then return L.x_wave, L.w_wave end                          -- 16 окт: колонка волны
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
  local pk
  if head.kpk then pk = head.kpk(math.min(total, 8192), column and mode == 'spec')   -- 19 окт: пэд drumrs5k — пики файла пэда
  else pk = get_peaks and get_peaks(head, math.min(total, 8192), column and mode == 'spec') end
  local cx, hw, x0w
  if column then cx = x + L.x_wave + L.w_wave / 2; hw = (L.w_wave / 2) - 1; x0w = x + L.x_wave
  else cx = x + L.x_note + L.w_note / 2; hw = (L.w_note / 2) - 1 end
  -- 20 окт: relative wave — тише нота, уже волна (vol / velocity hex, 80 = полная ширина)
  if L.relwave and head.vol then
    local v = tonumber(head.vol, 16)
    if v and v < 128 then hw = hw * math.max(0.12, v / 128) end
  end
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
    if column then   -- 19 окт: тихие госты не ниткой — пики сжаты степенью 0.6 (громкие почти те же)
      mx = mx > 0 and mx ^ 0.6 or -((-mx) ^ 0.6); mn = mn > 0 and mn ^ 0.6 or -((-mn) ^ 0.6)
    end
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
  -- 16 окт: и в режимах note / back — еле видная линия поверх волны (удар слайса подтянут к сетке q:
  -- одна нота с маркерами вместо ghost-кусков); x0w..x1w — ширина, где лежит волна
  if head.smk and not inv and D.show_smk ~= false then          -- опция stretch markers (5 окт)
    local xa, xb
    if column then set(U.AMBER); xa, xb = x0w, x0w + L.w_wave - 1
    else set(U.mix(U.AMBER, U.BG, 0.65)); xa, xb = x + L.x_note, x + L.x_note + L.w_note - 1 end
    local mxm, mym = gfx.mouse_x, gfx.mouse_y
    local base = i * L.rh - off
    local mcol = column and U.AMBER or U.mix(U.AMBER, U.BG, 0.65)
    for k, fr in ipairs(head.smk) do
      local q = math.floor(fr * total)
      local py = q - base
      if py >= 0 and py < L.rh then
        -- 16 окт: ромб как в REAPER — половинки по скорости отрезков сверху и снизу (зелёный — быстрее, фиолетовый — медленнее)
        local hz = math.max(3, math.floor(L.rh / 3))
        local segs = head.smk_src and head.smk_src.segs or {}
        local up, dn
        for _, sg in ipairs(segs) do
          if math.abs(sg.f1 - fr) < 1e-6 then up = sg.r end
          if math.abs(sg.f0 - fr) < 1e-6 then dn = sg.r end
        end
        local function rc(r) if not r or math.abs(r - 1) < 0.005 then return U.TEXT end; return r > 1 and U.GREEN or (U.MAGENTA or U.mix(U.RED, U.CYAN, 0.5)) end
        local dx = math.floor((xa + xb) / 2)
        set(rc(up)); gfx.triangle(dx - hz, y + py, dx + hz, y + py, dx, y + py - hz)
        set(rc(dn)); gfx.triangle(dx - hz, y + py, dx + hz, y + py, dx, y + py + hz)
        set(mcol)
        -- 16 окт: маркер мышью (±3 px) — тянуть вверх / вниз (main: smk_drag); под мышью — янтарём во всю яркость
        local hot = mxm >= xa and mxm <= xb and math.abs(mym - (y + py)) <= 3
        if hot then D.smk_hot = { item = head.item, frac = fr }; set(U.AMBER) end
        gfx.line(xa, y + py, xb, y + py)
        if hot then gfx.line(xa, y + py + 1, xb, y + py + 1); set(mcol) end
      end
    end
  end
  -- 16 окт: скорость отрезков между stretch-маркерами (как в REAPER): вертикаль правее центра — быстрее, левее — медленнее;
  -- в начале отрезка подпись 1.11x (если влезает в ширину волны)
  if head.smk and head.smk_src and head.smk_src.segs and not inv and D.show_smk ~= false then
    local xa, xb = column and x0w or (x + L.x_note), column and (x0w + L.w_wave - 1) or (x + L.x_note + L.w_note - 1)
    local cxs = math.floor((xa + xb) / 2)
    local hw2 = math.max(2, math.floor((xb - xa) / 2) - 1)
    local base = i * L.rh - off
    for _, sg in ipairs(head.smk_src.segs) do
      local q0, q1 = math.floor(sg.f0 * total), math.floor(sg.f1 * total)
      local a0, a1 = math.max(q0, base), math.min(q1, base + L.rh)
      if a1 > a0 and (math.abs(sg.r - 1) >= 0.005 or math.abs(sg.sl or 0) > 0.005) then
        -- 16 окт: наклон (slope) — скорость меняется по отрезку: от r·(1 − s) к r·(1 + s), линия — наклонная
        local rs, re = sg.r * (1 - (sg.sl or 0)), sg.r * (1 + (sg.sl or 0))
        local function lxo(r) return cxs + math.floor(math.max(-1, math.min(1, (r - 1) * 2)) * hw2) end
        local function at(q) local f = (q1 > q0) and (q - q0) / (q1 - q0) or 0; return rs + (re - rs) * f end
        set(sg.r > 1 and U.GREEN or (U.MAGENTA or U.mix(U.RED, U.CYAN, 0.5)))   -- 16 окт: ярче (просьба), 2 px
        gfx.line(lxo(at(a0)), y + a0 - base, lxo(at(a1)), y + a1 - base - 1); gfx.line(lxo(at(a0)) + 1, y + a0 - base, lxo(at(a1)) + 1, y + a1 - base - 1)
        if q0 >= base and q0 < base + L.rh and (xb - xa) >= ms('0.00x') then
          text(xa + 1, y + q0 - base + 1, ('%.2fx'):format(sg.r), U.mix(U.TEXT, U.BG, 0.3))
        end
      end
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
-- группа кода команды → цвет (как в Renoise); Z… — глобальные, прочее — RN_OTHER
local FXG = { ['0M'] = 'RN_VOL', ['0I'] = 'RN_VOL', ['0O'] = 'RN_VOL', SI = 'RN_VOL', SO = 'RN_VOL', ['0P'] = 'RN_PAN',
  ['0U'] = 'RN_PITCH', ['0D'] = 'RN_PITCH', ['0G'] = 'RN_PITCH', ['0V'] = 'RN_PITCH', ['0A'] = 'RN_PITCH', SF = 'RN_PITCH', SB = 'RN_GLOBAL' }
D.fx_slots, D.fx_dim = {}, {}   -- 12 окт: слоты команд строки продолжения (переиспользуются, без аллокаций в кадре)
D.FX_COL = setmetatable({}, { __index = function(_, k) return FXG[k] and D[FXG[k]] end })
local function empty_text(fld) return fld <= 3 and EMPTY[fld] or '....' end

-- 18 окт: цвет поля (как у его значения): громкость, delay, команды, слайс, пан; нота и инструмент — текстом (nil)
function D.field_rgb(fld)
  if fld == 2 or fld == 'vol' then return D.RN_VOL elseif fld == 3 or fld == 'delay' then return D.RN_DELAY
  elseif fld == 'slc' then return D.RN_OTHER elseif fld == 'pan' then return D.RN_PAN or U.CYAN
  elseif type(fld) == 'number' and fld >= 4 then return D.RN_OTHER end
end
-- 18 окт (опция dot colours): пустые точки поля — оттенком его цвета; кэш на базовый цвет строки (акцент меняет его)
D.dot_cache = setmetatable({}, { __mode = 'k' })
function D.dot_col(fld, col)
  if not D.dotcolor or (col ~= D.EMPTY and col ~= D.EMPTY_UNDER) then return col end
  local fc = D.field_rgb(fld)
  if not fc then return col end
  local m = D.dot_cache[col]
  if not m then m = {}; D.dot_cache[col] = m end
  local r = m[fc]
  if not r then r = U.mix(col, fc, 0.5); m[fc] = r end
  return r
end
-- 21 окт: помощники ячейки — один раз на файл (были замыканиями внутри draw_cell: 3 на ячейку × тысяча ячеек
-- за кадр — главный мусор строк); состояние текущей ячейки — в полях DCS
local DCS = { NOFX = {} }
function DCS.c(fld, col)
  return (DCS.inv == fld and not (D.fx_half and type(fld) == 'number' and fld >= 4)) and U.BG or (DCS.ghost and U.DIM or D.dot_col(fld, col))
end
-- инверсное поле: текст с непрозрачной подложкой цвета заливки
-- 12 окт: курсор на половине поля команды (код | значение): инверсна только эта половина
function DCS.text(tx, tyy, str, col)
  local hx, inv = DCS.hx, DCS.inv
  if hx and tx == hx and #str == 4 then
    local w2, a, b = ms('00'), str:sub(1, 2), str:sub(3, 4)
    if D.fx_half == 'val' then text(tx, tyy, a, col); text(tx + w2, tyy, b, U.BG, D.inv_bg or U.TEXT)
    else text(tx, tyy, a, U.BG, D.inv_bg or U.TEXT); text(tx + w2, tyy, b, col) end
    return
  end
  if inv and col == U.BG then text(tx, tyy, str, col, D.inv_bg or U.TEXT) else text(tx, tyy, str, col) end
end
-- поле инструмента: номер на строке ноты; пустое — точки. Рисуется ПОСЛЕ
-- волны (4 окт: волна фоном закрашивала зелёный номер)
-- 31 окт: имя фразы тейка (ph:NAME) или false; кэш по тейку (слабые ключи), сброс по счётчику правок проекта
D.ph_cache = setmetatable({}, { __mode = 'k' })
function D.phrase_of(take)
  local sc = reaper.GetProjectStateChangeCount(0)
  if D.ph_sc ~= sc then D.ph_sc = sc; D.ph_cache = setmetatable({}, { __mode = 'k' }) end
  local v = D.ph_cache[take]
  if v == nil then
    local _, nm = reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', false)
    v = (nm or ''):match('^ph:(.+)$') or false
    D.ph_cache[take] = v
  end
  return v
end
function DCS.inst()
  local L, cell, x, ty = DCS.L, DCS.cell, DCS.x, DCS.ty
  local text, c = DCS.text, DCS.c
  if not (L.x_inst and not DCS.name_row) then return end
  local n = cell and (cell.kind == 'audio') and ((D.inst_num and D.inst_num[cell.item]) or (D.inst_of and D.inst_of[cell.item]))   -- номер исходника (3 окт)
  -- 31 окт: нота-триггер фразы (тейк ph:NAME) — вместо инструмента знак фразы " и первая буква её имени
  local ph = cell and cell.kind == 'midi' and cell.take and D.phrase_of(cell.take)
  if ph then text(x + L.x_inst, ty, '"' .. ph:sub(1, 1), c('inst', cell.muted and U.AMBER or U.AMBER))
  elseif not n and cell and cell.kind == 'midi' and D.midi_inst then n = D.midi_inst(cell.item, cell.pitch) end   -- 11 окт: MIDI — плагин, что играет ноту (RS5K по диапазону)
  if ph then
  elseif n then text(x + L.x_inst, ty, D.DEC2[n % 100], c('inst', cell.muted and U.GREY or U.TEXT))   -- Renoise: инструмент цветом ноты
  else text(x + L.x_inst, ty, '..', c('inst', (cell and cell.kind == 'cont' and cell.of.kind == 'audio') and D.EMPTY_UNDER or D.EMPTY)) end
  if L.x_slc then
    local sk = cell and ((cell.kind == 'audio' and cell.slice) or (cell.kind == 'midi' and D.midi_slice and D.midi_slice(cell.item, cell.pitch)))   -- 19 окт: пэд кита — Sxx
    if sk then text(x + L.x_slc, ty, D.SHEX[sk % 256], c('slc', cell.muted and U.GREY or D.RN_OTHER))   -- своё поле: курсор инструмента его не красит
    else text(x + L.x_slc, ty, '...', c('slc',  (cell and cell.kind == 'cont' and cell.of.kind == 'audio') and D.EMPTY_UNDER or D.EMPTY)) end
  end
  if L.x_pan then
    local pv = cell and cell.kind == 'audio' and cell.pan
    if pv then text(x + L.x_pan, ty, pv, c('pan', cell.muted and U.GREY or (D.RN_PAN or U.CYAN)))
    else text(x + L.x_pan, ty, '..', c('pan', (cell and cell.kind == 'cont' and cell.of.kind == 'audio') and D.EMPTY_UNDER or D.EMPTY)) end
  end
end
D.DEC2, D.SHEX, D.HEX2 = {}, {}, {}
for i = 0, 255 do D.DEC2[i] = ('%02d'):format(i % 100); D.SHEX[i] = ('S%02X'):format(i); D.HEX2[i] = ('%02X'):format(i) end
local function draw_cell(L, cell, x, y, ty, inv)
  -- 11 окт: wave only — в аудио-подколонке только волна (пустая строка — тусклая точка по центру)
  if L.wave_only then
    if D.cur_box then D.cur_box(); D.cur_box = nil end
    local head = cell and (cell.kind == 'cont' and cell.of or cell)
    if head and head.kind == 'audio' then draw_wave(L, head, cell.kind == 'cont' and cell.i or 0, x, y, head.muted, false)
    elseif head and head.note then text(x + L.pad, ty, head.note, U.TEXT)   -- нота MIDI в аудио-подколонке — как есть
    else text(x + L.x_wave + math.floor(L.w_wave / 2) - math.floor(ms('.') / 2), ty, '.', D.EMPTY) end
    return
  end
  DCS.L, DCS.cell, DCS.x, DCS.ty, DCS.inv, DCS.ghost = L, cell, x, ty, inv, cell and cell.ghost   -- 15 окт: ghost-слайс (playthru + q) — бледно, как подсказка
  DCS.hx = D.fx_half and type(inv) == 'number' and inv >= 4 and L.x_fx and L.x_fx[inv - 3] and (x + L.x_fx[inv - 3])
  local c, text, draw_inst = DCS.c, DCS.text, DCS.inst
  local nf = L.notes_only and 1 or (L.narrow and 2 or (3 + L.nfx))
  local name_row = cell and cell.kind == 'cont' and cell.i == 1 and cell.of.kind == 'audio' and D.itemnames and cell.of.name ~= ''
  DCS.name_row = name_row
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
  -- 19 окт: fold — сложенные быстрые ноты строки: линия в своё время внутри строки (белая — нота; под командами — цвет команд)
  -- 19 окт (2): линии поверх текста читались как зачёркивание — вместо них знак «o» сбоку ячейки (как колонка Orca)
  -- 20 окт: take FX у ноты — значок fx после ноты (своё место: L.x_tfx есть только у таких лейнов)
  if cell and cell.tfx and L.x_tfx and (cell.kind == 'audio' or cell.kind == 'midi') then
    local bx, bw = x + L.x_tfx, L.w_tfx
    set(U.GREEN); gfx.rect(bx, y + 1, bw, L.rh - 2, 0)
    text(bx + 2, ty, 'fx', U.GREEN)
  end
  if cell and cell.fold and L.x_fold then
    -- 27 окт: в строке сложены ещё ноты — «+» перед нотой (как папка в lf), раскрыть — zu или LPB (+ / Opt+Shift+J)
    text(x + L.x_fold, ty, '+', U.CYAN)
    -- гребёнка (мини-таймлайн строки) — выключена:
    -- -- 19 окт (4): заметнее — подложка колонки, чёрточки в 2 px: сложенные — янтарём, видимая — белым
    -- local top, bh = y + 1, L.rh - 2
    -- set(U.tint(U.AMBER, 0.14)); gfx.rect(sx, top, tw, bh, 1)
    -- set(U.tint(U.AMBER, 0.35)); gfx.rect(sx, top, tw, bh, 0)
    -- local base = top + bh - 1
    -- local function tick(h, bright)
    --   local px = sx + 1 + math.max(0, math.min(tw - 4, math.floor((h.delay or 0) / 256 * (tw - 3))))
    --   local v = (tonumber(h.vol or '', 16) or 100) / 127
    --   local th = math.max(3, math.floor((bh - 2) * math.max(0.3, math.min(1, v)) + 0.5))
    --   set(h.muted and U.GREY or (bright and U.TEXT or U.AMBER))
    --   gfx.rect(px, base - th + 1, 2, th, 1)
    --   if h.fx and #h.fx > 0 then set(U.CYAN); gfx.rect(px, top, 2, 2, 1) end
    -- end
    -- if cell.kind == 'midi' or cell.kind == 'audio' then tick(cell, true) end
    -- for _, fh in ipairs(cell.fold) do tick(fh, false) end
    -- -- 19 окт: «+» перед нотой, в которой что-то сложено (как папка в lib: 01+)
    -- if cell.kind == 'midi' or cell.kind == 'audio' then   -- только у ноты (не у OFF / продолжения)
    --   local pw = ms('+')
    --   local px = x + L.x_note - pw - 1
    --   if px < x + 1 then px = x + L.x_note + ms('C-4') + 1 end   -- слева нет места — сразу за нотой
    --   text(px, ty, '+', U.CYAN)
    -- end
    -- for _, fh in ipairs(cell.fold) do   -- линии в своё время внутри строки (пока выключено)
    --   local yy = y + math.max(1, math.min(L.rh - 2, math.floor((fh.delay or 0) / 256 * L.rh + 0.5)))
    --   set(fh.muted and U.GREY or U.TEXT); gfx.rect(x + L.x_note, yy, math.max(4, L.w_note), 1, 1)
    --   if fh.fx and #fh.fx > 0 and L.x_fx and L.x_fx[1] then set(D.RN_OTHER or U.CYAN); gfx.rect(x + L.x_fx[1], yy, L.w_fx or 8, 1, 1) end
    -- end
  end
  draw_inst()
  if k == 'audio' or k == 'midi' then
    local muted = cell.muted
    local offkey = D.key_pcs and cell.pitch and not cell.video and not D.key_pcs[math.floor(cell.pitch + 0.5) % 12]   -- 21 окт: нота вне лада (:key mark)
    text(x + L.x_note, ty, cell.video and 'VID' or cell.note, c(1, muted and U.GREY or (cell.video and U.CYAN or (offkey and D.OFFKEY or U.TEXT))))   -- видео-событие (9 окт)
    if cell.micro and D.micro and D.micro_tag then text(x + L.x_note + ms(cell.note), ty, D.micro_tag(cell.micro), c(1, muted and U.GREY or U.CYAN)) end   -- 16 окт
    if not L.notes_only then text(x + L.x_vol, ty, cell.vol, c(2, muted and U.GREY or D.RN_VOL)) end   -- 11 окт: цвета Renoise
    if L.narrow or L.notes_only then
    elseif cell.delay > 0 then text(x + L.x_del, ty, D.HEX2[cell.delay % 256], c(3, D.RN_DELAY))
    else text(x + L.x_del, ty, '..', c(3, D.EMPTY)) end
    local fx = cell.fx or DCS.NOFX
    -- 21 окт: слайс аудио-ноты — 0Sxx в первой свободной колонке команд (своей 0S нет)
    local vs_i
    if k == 'audio' and cell.slice and L.nfx > 0 then
      local has = false
      for i = 1, L.nfx do if fx[i] and fx[i]:sub(1, 2) == '0S' then has = true end end
      if not has then for i = 1, L.nfx do if not fx[i] then vs_i = i; break end end end
    end
    for i = 1, L.nfx do
      if i == vs_i then text(x + L.x_fx[i], ty, '0S' .. D.HEX2[cell.slice % 256], c(3 + i, muted and U.GREY or (D.FX_COL['0S'] or D.RN_OTHER)))
      elseif fx[i] then
        -- 11 окт: цвет команды — по группе, как в Renoise: громкость / панорама / питч / глобальные / прочее
        local col = D.FX_COL[fx[i]:sub(1, 2)] or (fx[i]:sub(1, 1) == 'Z' and D.RN_GLOBAL) or D.RN_OTHER
        text(x + L.x_fx[i], ty, fx[i], c(3 + i, muted and U.GREY or col))
      else text(x + L.x_fx[i], ty, '....', c(3 + i, D.EMPTY)) end
    end
  elseif k == 'off' then
    text(x + L.x_note, ty, D.OFF_TXT or 'OFF', c(1, D.CONT))   -- 8 окт: опция note OFF glyph — «|» вместо OFF
    if not L.notes_only then text(x + L.x_vol, ty, '..', c(2, D.EMPTY)) end
    if L.narrow or L.notes_only then
    elseif cell.delay and cell.delay > 0 then text(x + L.x_del, ty, D.HEX2[cell.delay % 256], c(3, D.CONT))
    else text(x + L.x_del, ty, '..', c(3, D.EMPTY)) end
    for i = 1, L.nfx do text(x + L.x_fx[i], ty, '....', c(3 + i, D.EMPTY)) end
  elseif k == 'cont' then
    local head = cell.of
    if head.kind == 'audio' then
      -- сетка трекера слегка просматривается под item (2 окт): бледные точки
      -- в полях, где ничего не написано
      local named = D.itemnames and cell.i == 1 and head.name ~= ''
      local fxv = head.fx or {}
      -- 12 окт: что стоит в слотах команд строки: свои — ярко, действующие с прошлых строк — бледно
      local slot = D.fx_slots
      for i = 1, L.nfx do slot[i] = false end
      if not L.narrow and not L.notes_only then
        local own, run, j = cell.fx, cell.run, 1
        for i = 1, L.nfx do
          if own and own[i] then slot[i] = own[i]; D.fx_dim[i] = false
          elseif run and run[j] then slot[i] = run[j]; D.fx_dim[i] = true; j = j + 1 end
        end
      end
      for fld = named and (nf + 1) or 1, nf do      -- строка имени: без точек под текстом
        local skip = (fld == 2 and cell.vol ~= nil) or (fld >= 4 and slot[fld - 3])
        if not skip then
          local fx = D.field_rect(L, fld)
          text(x + fx, ty, empty_text(fld), c(fld, D.EMPTY_UNDER))
        end
      end
      -- точка огибающей громкости take на этой строке (5 окт)
      if cell.vol and not L.notes_only and not (named and nf < 2) then text(x + L.x_vol, ty, cell.vol, c(2, D.RN_VOL)) end
      if named then
        -- вторая строка: имя item (опция item names, 3 окт); номер — на строке ноты
        -- курсор на этой строке: подложка — шириной поля ноты, не всего имени (3 окт)
        if inv == 1 then text(x + L.x_note, ty, fit(head.name, L.w_note), U.BG)
        else text(x + L.x_note, ty, fit(head.name, L.sub_w - L.x_note - L.pad), U.GREY) end
      end
      -- 12 окт: у строки внутри ноты — свои команды (действуют с этой строки до следующей того же рода)
      for i = 1, L.nfx do
        local f = slot[i]
        if f then
          local col = head.muted and U.GREY or (D.FX_COL[f:sub(1, 2)] or (f:sub(1, 1) == 'Z' and D.RN_GLOBAL) or D.RN_OTHER)
          text(x + L.x_fx[i], ty, f, c(3 + i, D.fx_dim[i] and U.mix(U.BG, col, 0.38) or col))
        end
      end
      -- 6 окт: команды не переносятся на строки ниже — видно столько, сколько
      -- колонок fx (−+ в шапке); остальные скрыты, как в трекерах
    else
      text(x + L.x_note + (L.w_note - ms('|')) / 2, ty, '|', c(1, D.CONT))
      for fld = 2, nf do
        local fx = D.field_rect(L, fld)
        text(x + fx, ty, empty_text(fld), c(fld, D.EMPTY))
      end
    end
  end
end

-- пустая строка трекера (7 окт, session в масштабе трекера): точки во всех
-- полях всех видимых колонок — сетка та же, что у строк трекера
function D.empty_row(L, y)
  for _, c in ipairs(L.cols or {}) do
    if c.x then
      for _, ln in ipairs(c.lanes) do
        for si = 1, ln.nsub do
          local f = L.flat[ln.f0 + si - 1]
          if f and f.x then
            if c.folded then text(f.x + L.pad, y + 1, '...', D.EMPTY)
            else draw_cell(f.G or L, nil, f.x, y, y + 1) end
          end
        end
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

-- лейн аккордов (8 окт, :chord): на строке, где ноты начинаются, —
-- обозначение (D.CH.name), пока звучат — «¦», все кончились — OFF
function D.draw_chord_cell(L, col, row, x, y, ty, inv, w)
  local text_ = text
  local function tx(xx, yy, str, c2) if inv then text_(xx, yy, str, c2, D.inv_bg or U.TEXT) else text_(xx, yy, str, c2) end end
  local pitches, cont, off = {}, false, false
  for _, lane in ipairs(col.lanes) do
    for _, sub in ipairs(lane.subs) do
      local c = sub[row]
      if c then
        if c.kind == 'midi' and c.row0 == row then pitches[#pitches + 1] = c.pitch
        elseif c.kind == 'off' then off = true
        elseif c.kind == 'cont' or c.kind == 'midi' then cont = true end
      end
    end
  end
  if #pitches > 0 and D.CH then
    tx(x + L.pad, ty, fit(D.CH.name(pitches) or '?', w - 2 * L.pad), inv and U.BG or U.CYAN)
  elseif cont then tx(x + math.floor((w - ms('¦')) / 2), ty, '¦', inv and U.BG or U.GREY)
  elseif off then tx(x + L.pad, ty, D.OFF_TXT or 'OFF', inv and U.BG or U.GREY)
  else tx(x + math.floor((w - ms('...')) / 2), ty, '...', inv and U.BG or D.EMPTY) end
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
-- 24 окт: команда ноты → параметр сэмплера по смыслу (рамка в DSP): модуль — рэк drumrs5k или RS5K
local HL_PAT = { volume = { '^volume$', '^volume ' }, pan = { '^pan$', '^pan ' }, pitch = { '^pitch$', '^pitch adjust', '^pitch ~' }, start = { '^start', '^sample start' } }
function D.hl_role(f, p, role)
  local nm = ((f.fxname or '') .. ' ' .. (f.name or '')):lower()
  if not (f.kit or nm:find('rs5k', 1, true) or nm:find('reasamplomatic', 1, true)) then return false end
  local pn = (p.name or ''):lower()
  for _, pat in ipairs(HL_PAT[role] or {}) do if pn:find(pat) then return true end end
  return false
end
-- 24 окт: матрица пинов (как Pin Connector REAPER, в стиле трекера): слева — каналы трека, столбцы — входы плагина,
-- справа — выходы; клетка — квадрат, включённая — залита; курсор клавиш — янтарная рамка; + - каналы, r сброс
function D.pins_draw(L, info, x, y, w, h, mx, my, hover)
  local m = info.pinmx
  local st, PINS = m.st, info.PINS
  local cs = math.max(L.rh, L.cw * 2)
  local lw = ms('track 32') + 3 * L.pad
  local nameh = 0
  for p = 0, st.nin - 1 do nameh = math.max(nameh, ms(st.inn[p] or '')) end
  for p = 0, st.nout - 1 do nameh = math.max(nameh, ms(st.outn[p] or '')) end
  nameh = math.min(nameh, 10 * L.cw)
  local gap = 2 * L.cw
  local bw2 = math.min(w - 4, lw + (st.nin + st.nout) * cs + gap + lw + 2 * L.pad)
  local bh2 = math.min(h - 4, L.rh * 3 + st.nch * cs + 2 * L.pad + L.rh)
  local bx, by = x + 2, y + 2
  local at = m.k and D.io_btn and D.io_btn[m.k]   -- 24 окт: под кнопкой «in / out» своего модуля
  if at then
    bx = math.max(x + 2, math.min(x + w - bw2 - 2, at.x))
    by = math.max(y + 2, math.min(y + h - bh2 - 2, at.y + 1))
  end
  set(U.PANEL); gfx.rect(bx, by, bw2, bh2, 1)
  set(U.AMBER); gfx.rect(bx, by, bw2, bh2, 0)
  local inside = mx >= bx and mx < bx + bw2 and my >= by and my < by + bh2
  if inside then   -- модули под матрицей щелчок не получают
    local drop = {}
    for k2 in pairs(hover) do if type(k2) == 'string' and (k2:match('^dsp') or k2:match('^kit') or k2 == 'zone' or k2:match('^eq') or k2 == 'dbparam') then drop[#drop + 1] = k2 end end
    for _, k2 in ipairs(drop) do hover[k2] = nil end
  end
  text(bx + L.pad, by + 1, fit(m.name .. ' - pins: ' .. st.nin .. ' in, ' .. st.nout .. ' out', bw2 - 12 * L.cw), U.AMBER)
  -- кнопки справа: + - (каналы трека), r сброс, x закрыть
  local bx2 = bx + bw2 - L.pad
  for _, b in ipairs({ { 'x', { close = true } }, { 'r', { reset = true } }, { '+', { chan = 1 } }, { '-', { chan = -1 } } }) do
    local kw = ms(b[1]) + 2 * L.pad
    bx2 = bx2 - kw - 2
    local hot = mx >= bx2 and mx < bx2 + kw and my >= by + 1 and my < by + L.rh
    set(hot and U.tint(U.AMBER, 0.35) or U.BG); gfx.rect(bx2, by + 1, kw, L.rh - 1, 1)
    set(hot and U.AMBER or U.LINE); gfx.rect(bx2, by + 1, kw, L.rh - 1, 0)
    text(bx2 + L.pad, by + 1, b[1], hot and U.AMBER or U.TEXT)
    if hot then hover.pinmx = b[2] end
  end
  local gy = by + 2 * L.rh + 2
  local cells, ix, ox = PINS.grid(st, bx + L.pad, gy, cs, cs, lw, gap)
  -- подписи столбцов: «in» / «out» и номер пина; имя пина — в статусе под мышью (вертикальный текст — нет)
  text(ix, by + L.rh + 1, fit('in', st.nin * cs), U.GREY)
  text(ox, by + L.rh + 1, fit('out', st.nout * cs), U.GREY)
  for ch = 0, st.nch - 1 do
    local yy = gy + ch * cs
    if yy + cs > by + bh2 then break end
    text(bx + L.pad, yy + math.floor((cs - L.th) / 2), 'track ' .. (ch + 1), U.GREY)
    text(ox + st.nout * cs + L.pad, yy + math.floor((cs - L.th) / 2), fit('track ' .. (ch + 1), lw), U.GREY)
  end
  local cu = m.cur
  for _, c in ipairs(cells) do
    if c.y + c.h <= by + bh2 then
      local on = PINS.has((c.side == 'in' and st.ins or st.outs)[c.pin], c.ch)
      local hot = mx >= c.x and mx < c.x + c.w and my >= c.y and my < c.y + c.h
      set(U.mix(U.LINE, U.BG, 0.3)); gfx.rect(c.x, c.y, c.w, c.h, 0)
      if on then set(hot and U.AMBER or U.TEXT); gfx.rect(c.x + 2, c.y + 2, c.w - 4, c.h - 4, 1)
      elseif hot then set(U.tint(U.AMBER, 0.3)); gfx.rect(c.x + 1, c.y + 1, c.w - 2, c.h - 2, 1) end
      if cu.side == c.side and cu.pin == c.pin and cu.ch == c.ch then set(U.AMBER); gfx.rect(c.x, c.y, c.w, c.h, 0); gfx.rect(c.x + 1, c.y + 1, c.w - 2, c.h - 2, 0) end
      if hot then
        hover.pinmx = { cell = c }
        D.aw_status = ('%s %s  <->  track channel %d: %s (click / Space)'):format(c.side == 'in' and 'input' or 'output', (c.side == 'in' and st.inn or st.outn)[c.pin] or '', c.ch + 1, on and 'connected' or 'off')
      end
    end
  end
  -- номера пинов над столбцами
  for p = 0, st.nin - 1 do text(ix + p * cs + 2, gy - L.rh, tostring(p + 1), U.DIM) end
  for p = 0, st.nout - 1 do text(ox + p * cs + 2, gy - L.rh, tostring(p + 1), U.DIM) end
  if inside and not hover.pinmx then hover.pinmx = { none = true } end
end
local function draw_env_cell(L, ev, prev, x, y, ty, e, nxt, vals)
  if not ev then return end
  if vals == 'steps' then
    -- 12 окт: шаги (ze s) — фейдер на строку, как степпер 303: дорожка во всю полосу,
    -- заливка до значения строки; число — у строк с точкой
    local bw = L.env_bar_w
    local h = math.max(2, L.rh - 3)
    set(U.tint(U.CYAN, 0.12)); gfx.rect(x + L.env_bx, y + 1, bw, h, 1)
    set(U.CYAN); gfx.rect(x + L.env_bx, y + 1, math.max(1, math.floor(ev.v * bw + 0.5)), h, 1)
    if ev.pt then
      text(x + L.env_bx + bw + L.pad, ty, D.envfmt == 'hex' and string.format('%02X', math.floor(ev.v * 255 + 0.5)) or tostring(math.floor(ev.v * 127 + 0.5)), U.TEXT)
    end
    return
  end
  if vals == 'bars' then
    -- 24 окт: значения и полоски (ze b): под числом — линия длиной по значению строки, как у MIDI CC
    set(U.mix(env_colour(e), U.BG, 0.35)); gfx.rect(x + L.env_bx, y + L.rh - 4, math.max(1, math.floor(ev.v * (L.env_bar_w - 1) + 0.5)), 3, 1)
  end
  if vals then
    -- 12 окт: вид «значения» (ze) — как колонка команд: число в строке точки, иначе точки
    if ev.pt then
      local tempo = e and e.name and e.name:lower():find('tempo', 1, true) and e.max and e.min   -- 13 окт: темп — сам BPM
      local vt = tempo and ('%d'):format(math.floor(e.min + ev.v * (e.max - e.min) + 0.5))
        or (D.envfmt == 'hex' and string.format('%02X', math.floor(ev.v * 255 + 0.5)) or ('%3d'):format(math.floor(ev.v * 127 + 0.5)))
      text(x + L.env_bx, ty, vt, env_colour(e))
    elseif prev and prev.pt and prev.ramp then text(x + L.env_bx, ty, prev.ramp, U.CYAN)   -- 25 окт: темп плавно растёт / падает
    else text(x + L.env_bx, ty, D.envfmt == 'hex' and '..' or '...', D.EMPTY) end
    return
  end
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
    -- точки кружочками, как в REAPER (6 окт); опция envelope points
    if D.envpoints ~= false then gfx.circle(ex, cy, L.env_compact and 1 or 2, 0, 1) end
    -- 11 окт: темп (колонка мастера) — сам BPM, не 0..127
    local tempo = e and e.name and e.name:lower():find('tempo', 1, true) and e.max and e.min
    local vt = tempo and ('%d'):format(math.floor(e.min + ev.v * (e.max - e.min) + 0.5))
      or (D.envfmt == 'hex' and string.format('%02X', math.floor(ev.v * 255 + 0.5)) or tostring(math.floor(ev.v * 127 + 0.5)))
    text(tx, ty, vt, U.TEXT)
  elseif prev and prev.pt and prev.ramp then text(tx, ty, prev.ramp, U.CYAN)   -- 25 окт: темп — ^ подъём, v спад
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
local SG_IMG = 960                 -- спектрограммы: 960..1017 (58 слотов; 1018-1019 — лупа big fixed cursor)
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
  elseif mode == 'sgram' and info.spec and slot < 58 then
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
        -- 12 окт: зоны, как у метров REAPER: зелёная до −9 дБ, янтарная до −0.1, красная — только верх
        -- (раньше вся полоса цвета пика: удар нормализованного сэмпла в 0 дБ красил её целиком)
        local function hz(db) return math.floor(math.max(0, math.min(1, (db + 60) / 60)) * (mh - 2) + 0.5) end
        local y0 = my0 + mh - 1
        local zones = { { 0, math.min(hh, hz(-9)), U.GREEN }, { hz(-9), math.min(hh, hz(-0.1)), U.AMBER }, { hz(-0.1), hh, U.RED } }
        for _, z in ipairs(zones) do
          if z[2] > z[1] then set(z[3]); gfx.rect(bxx + 1, y0 - z[2], bw - 2, z[2] - z[1], 1) end
        end
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
    -- полосы (7 окт): из параметров с p.band (модель берёт их из имён — любое
    -- число и тип); старый модуль без band — 4 полосы по подписям
    local bands = {}
    for i, p in ipairs(f.params or {}) do
      if p.band then
        local b = bands[p.band] or { t = p.btype }
        bands[p.band] = b
        local s = vals[i] and vals[i].s or ''
        local mult = s:lower():find('%dk') and 1000 or 1
        local v = tonumber((s:gsub(',', '.')):match('[-+]?%d*%.?%d+'))
        if s:find('inf') then v = s:find('%-') and -150 or 150 end
        b[p.bk] = v and v * mult or nil
      end
    end
    if #bands == 0 then
      bands = {
        { t = 'ls', f = pnum(f, vals, '1 lo f'), g = pnum(f, vals, '1 lo g'), q = pnum(f, vals, '1 lo q') },
        { t = 'pk', f = pnum(f, vals, '2 f'), g = pnum(f, vals, '2 g'), q = pnum(f, vals, '2 q') },
        { t = 'pk', f = pnum(f, vals, '3 f'), g = pnum(f, vals, '3 g'), q = pnum(f, vals, '3 q') },
        { t = 'hs', f = pnum(f, vals, '4 hi f'), g = pnum(f, vals, '4 hi g'), q = pnum(f, vals, '4 hi q') },
      }
    end
    local gg = pnum(f, vals, 'gain') or 0
    local function resp(fq)
      local db = gg
      for _, b in ipairs(bands) do
        if b.f and b.f > 0 then
          local o = math.log(fq / b.f, 2)
          local g = b.g or 0
          local sg = math.max(0.05, (b.q or 2) / 2)
          if b.t == 'pk' then db = db + g * math.exp(-0.5 * (o / sg) ^ 2)
          elseif b.t == 'ls' then db = db + g / (1 + math.exp(o * 4))
          elseif b.t == 'hs' then db = db + g / (1 + math.exp(-o * 4))
          elseif b.t == 'hp' then db = db - 18 / (1 + math.exp(o * 4))     -- срезы — без усиления
          elseif b.t == 'lp' then db = db - 18 / (1 + math.exp(-o * 4))
          elseif b.t == 'nt' then db = db - 18 * math.exp(-0.5 * (o / math.min(sg, 0.3)) ^ 2)
          elseif b.t == 'bp' then db = db - 12 * (1 - math.exp(-0.5 * (o / sg) ^ 2)) end
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
    -- точки полос (7 окт): тянутся мышью — D.eq_hit читает вызывающий
    D.eq_hit = { x = x, y = y, w = w, h = h, sc = sc, cy = cy, pts = {} }
    for i, b in ipairs(bands) do
      if b.f and b.f > 0 then
        local bx2 = x + 1 + math.floor(lx(b.f) * (w - 3))
        local by2 = math.floor(cy - math.max(-18, math.min(18, b.g or 0)) * sc + 0.5)
        D.eq_hit.pts[#D.eq_hit.pts + 1] = { i = i, x = bx2, y = by2 }
        local hot = D.eq_hot == i and D.eq_hot_fx == f.i
        set(hot and U.AMBER or U.CYAN); gfx.rect(bx2 - (hot and 3 or 2), by2 - (hot and 3 or 2), hot and 7 or 5, hot and 7 or 5, 1)
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
    local function pt(i, o) o = math.max(-60, math.min(0, o)); return ox + (i + 60) / 60 * side, oy + side - (o + 60) / 60 * side end   -- в рамке (порог ниже −60)
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
      -- feedback ≥ 0 дБ: повторы не затухают (растут) — высота по рамке, красным (7 окт: линии уходили за вид)
      local hh = math.min(h - 4, math.floor(a * (h - 4)))
      if hh < 1 then break end
      set(g >= 1 and U.RED or U.AMBER); gfx.rect(px, y + h - 2 - hh, 2, hh, 1)
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
  elseif kind == 'verb' then
    local room = math.max(0, math.min(1, (pnum(f, vals, 'room') or 50) / 100))
    local damp = math.max(0, math.min(1, (pnum(f, vals, 'damp') or 50) / 100))
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
-- 22 окт: блок трека в DSP вертикальной колонкой (место — модулям): кнопки по две в ряд, vol и pan —
-- вертикальные фейдеры с вертикальными подписями, значения под ними, smart, in / out — вертикальные кнопки.
-- → ширина (0 — не нарисован)
function D.track_block_v(L, info, col, x, y, h, hover, rawc)
  local io = info.trk_io and info.trk_io(col)
  if not (col and io) then return 0 end
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local bw0 = math.max(L.btn_w or 0, ms('fx') + 4)
  local w = math.max(2 * bw0 + 3 * L.pad, ms('-00.0') + 2 * L.pad, ms('smart') + 2 * L.pad)
  local mode = info.hdrfill or 'line'
  local base = (info.trsel or {})[col.guid] and D.HDRSEL or D.HDR
  local tint = col.rgb and mode ~= 'off'
  local rbg = tint and U.mix(base, col.rgb, 0.18) or base
  local fill = tint and rawc or set
  fill(rbg); gfx.rect(x, y, w, h, 1)
  local T0, G0 = U.TEXT, U.GREY
  U.TEXT, U.GREY = U.readable(T0, rbg, 4.5), U.readable(G0, rbg, 3.0)
  local mon = col.recmon or 0
  local btns = { { 'r', col.armed, D.ARM, 'arm' }, { 'i', mon > 0, U.CYAN, 'monitor', mon == 2 },
                 { 'm', col.muted, U.AMBER, 'mute' }, { 's', col.solo, U.GREEN, 'solo' },
                 { 'ø', io.phase, U.AMBER, 'phase', nil, true }, { 'fx', not io.fxen, U.RED, 'fxen', nil, true },
                 { '~', #(col.envs or {}) > 0, U.CYAN, 'auto' } }
  local yy, bh = y + 3, L.rh - 3
  for i, b in ipairs(btns) do
    local bx = x + L.pad + ((i - 1) % 2) * (bw0 + L.pad)
    local by = yy + math.floor((i - 1) / 2) * L.rh
    local on = b[2]
    local hot = mx >= bx and mx < bx + bw0 and my >= by and my < by + bh + 1
    local onc = b[3] == D.ARM and D.ARM_T or U.tint(b[3], 0.5)
    set((on and not b[5]) and onc or U.PANEL); gfx.rect(bx, by, bw0, bh, 1)
    set(hot and U.AMBER or (on and b[3] or U.DIM)); gfx.rect(bx, by, bw0, bh, 0)
    text(bx + math.floor((bw0 - ms(b[1])) / 2), by + math.floor((bh - (L.th or bh)) / 2) - (D.SPACE or 0), b[1], on and b[3] or U.readable(G0, U.PANEL, 4.5))
    if hot then if b[6] then hover.trkio = { col = col, what = b[4] } else hover.btn = { col = col, what = b[4] } end end
  end
  yy = yy + math.ceil(#btns / 2) * L.rh + 2
  -- фейдеры: высота — остаток минус значения, smart и in / out
  local live = info.trs_live
  local function lv(what, v) return (live and live.guid == col.guid and live.what == what) and live.v or v end
  local rem = y + h - yy
  local ioh = math.max(ms('out') + 2 * L.pad, math.floor(rem * 0.38))
  local smh = info.smart_ok and L.rh or 0
  local fh = rem - ioh - 2 * L.rh - smh - 6   -- 22 окт: значения vol и pan — двумя строками под фейдерами (в одну слипались «-7.C»)
  local cw2 = math.floor((w - 3 * L.pad) / 2)
  local vol = lv('vol', col.vol or 1)
  local db = vol > 1e-6 and 20 * math.log(vol, 10) or -150
  local pan = lv('pan', col.pan or 0)
  local vrow = 0
  local function fader(cx, what, frac, centered, label, val)
    if fh < 2 * L.rh then return end
    local tx = cx + L.th + 2                                 -- дорожка — справа от вертикальной подписи
    local tw2 = math.max(4, cx + cw2 - tx)
    local hot = mx >= cx and mx < cx + cw2 and my >= yy and my < yy + fh
    D.vtext(cx, yy, fh, label, hot and U.AMBER or U.GREY, rbg)
    local mid = tx + math.floor(tw2 / 2)
    set(U.DIM); gfx.rect(mid - 1, yy, 2, fh, 1)
    local ky = yy + fh - 1 - math.floor(frac * (fh - 1) + 0.5)
    set(hot and U.AMBER or U.CYAN)
    if centered then local cy = yy + math.floor(fh / 2); gfx.rect(mid - 1, math.min(cy, ky), 2, math.abs(ky - cy) + 1, 1)
    else gfx.rect(mid - 1, ky, 2, yy + fh - ky, 1) end
    set(hot and U.AMBER or U.TEXT); gfx.rect(tx, ky - 1, tw2, 3, 1)  -- ручка поперёк дорожки
    text(x + L.pad, yy + fh + 2 + vrow * L.rh, fit(val, w - 2 * L.pad), U.GREY); vrow = vrow + 1
    if hot then hover.trs = { col = col, what = what, vert = true, strip = true, y0 = yy + fh, h = fh, sv = math.max(0, math.min(1, (yy + fh - my) / math.max(1, fh))) } end
    if D.csel_on(col.guid, what) then csel_frame(cx - 1, yy, cw2 + 2, fh) end
  end
  fader(x + L.pad, 'vol', D.fader_pos(db), false, 'vol', db <= -60 and '-inf' or ('%+.1f'):format(db))
  fader(x + 2 * L.pad + cw2, 'pan', (pan + 1) / 2, true, 'pan', math.abs(pan) < 0.005 and 'C' or ((pan < 0 and 'L' or 'R') .. math.floor(math.abs(pan) * 100 + 0.5)))
  yy = yy + math.max(0, fh) + 2 * L.rh + 4
  if smh > 0 then
    local hot = mx >= x + L.pad and mx < x + w - L.pad and my >= yy and my < yy + L.rh
    set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(x + L.pad, yy + 1, w - 2 * L.pad, L.rh - 2, 1)
    set(hot and U.AMBER or U.DIM); gfx.rect(x + L.pad, yy + 1, w - 2 * L.pad, L.rh - 2, 0)
    text(x + 2 * L.pad, yy, fit('smart', w - 3 * L.pad), hot and U.AMBER or U.GREY)
    if hot then hover.trkio = { col = col, what = 'smart' } end
    yy = yy + L.rh
  end
  -- in / out — вертикальными кнопками: in — выбор входа, out — master и посылы (панель сендов)
  local ih = y + h - yy - 3
  if ih > L.cw * 3 then
    local cells = { { 'in ' .. (io.input:gsub(' / in ', '/'):gsub(' / ', '/')), 'input', true },
                    { 'out ' .. (io.mainsend and 'master' or 'no master') .. ('  s%d r%d'):format(#io.sends, io.recv), 'sends', io.mainsend } }
    for i, c in ipairs(cells) do
      local cx = x + L.pad + (i - 1) * (cw2 + L.pad)
      local hot = mx >= cx and mx < cx + cw2 and my >= yy and my < yy + ih
      set(hot and U.tint(U.AMBER, 0.25) or U.BG); gfx.rect(cx, yy, cw2, ih, 1)
      set(hot and U.AMBER or U.DIM); gfx.rect(cx, yy, cw2, ih, 0)
      D.vtext(cx + math.floor((cw2 - L.th) / 2), yy + 2, ih - 4, c[1], hot and U.AMBER or (c[3] and U.TEXT or U.GREY), hot and U.tint(U.AMBER, 0.25) or U.BG)
      if hot then hover.trkio = { col = col, what = c[2] } end
    end
    if D.sendpop == col.guid then D.late_send = function() D.draw_sendpop(L, info, col, io, x, yy, hover) end end
  end
  U.TEXT, U.GREY = T0, G0
  set(U.LINE); gfx.rect(x, y, w, h, 0)
  return w
end
function D.track_block(L, info, col, x, y, w, h, hover, rawc)
  local io = info.trk_io and info.trk_io(col)
  if not (col and io) then return 0 end
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local mode = info.hdrfill or 'line'
  local base = (info.trsel or {})[col.guid] and D.HDRSEL or D.HDR
  local tint = col.rgb and mode ~= 'off'
  local nbg = tint and U.mix(base, col.rgb, 0.30) or base
  local rbg = tint and U.mix(base, col.rgb, 0.18) or base
  rbg = U.mix(rbg, { 0, 0, 0 }, 0.10)   -- 28 окт: блок трека в DSP на 10 % темнее
  local fill = tint and rawc or set
  fill(rbg); gfx.rect(x, y, w, h, 1)
  local T0, G0 = U.TEXT, U.GREY
  U.TEXT, U.GREY = U.readable(T0, rbg, 4.5), U.readable(G0, rbg, 3.0)
  -- 4 окт (компактнее): имени нет — оно на вкладке трека в шапке DSP; кнопки — первой строкой
  local yy = y + 3   -- 16 окт: на px ниже — кнопки не на линии рамки
  -- кнопки — как в шапке трека (16 окт): строчные, запись (o) и фаза (ø) круглые, i · m s · fx ~
  local bx = x + L.pad
  local mon = col.recmon or 0
  local bh = L.rh - 3
  local btns = { { 'r', col.armed, D.ARM, 'arm', nil, false, round = true }, { 'i', mon > 0, U.CYAN, 'monitor', mon == 2 },
                 { 'm', col.muted, U.AMBER, 'mute', gap = true }, { 's', col.solo, U.GREEN, 'solo' },
                 { 'ø', io.phase, U.AMBER, 'phase', nil, true, round = true, gap = true }, { 'fx', not io.fxen, U.RED, 'fxen', nil, true },
                 { '~', #(col.envs or {}) > 0, U.CYAN, 'auto' }, { '[]', false, U.CYAN, 'contain', nil, true } }   -- 23 окт: [] — все эффекты трека в один контейнер
  for _, b in ipairs(btns) do
    if b.gap then bx = bx + L.pad end
    local bw = b.round and bh or math.max(L.btn_w, ms(b[1]) + 4)
    if bx + bw > x + w - L.pad then break end
    local on = b[2]
    local hot = mx >= bx and mx < bx + bw and my >= yy and my < yy + bh + 1
    if b[4] == 'phase' then   -- 16 окт: ø — просто буква, без кнопки-фона
      text(bx + math.floor((bw - ms('ø')) / 2), yy + math.floor((bh - (L.th or bh)) / 2) - (D.SPACE or 0), 'ø', (hot or on) and U.AMBER or U.readable(G0, rbg, 4.5))
    elseif b.round then
      local r = math.floor((bh - 1) / 2)
      local cx, cy = bx + math.floor(bw / 2), yy + math.floor(bh / 2)
      local rc = b[4] == 'arm' and U.readable(U.RED, U.PANEL, 3) or (on and b[3] or U.readable(G0, U.PANEL, 4.5))
      set(on and ((b[3] == D.ARM and D.ARM_T) or U.tint(b[3], 0.5)) or U.PANEL); gfx.circle(cx, cy, r, 1, 1)
      set(hot and U.AMBER or (on and b[3] or (b[4] == 'arm' and rc or U.DIM))); gfx.circle(cx, cy, r, 0, 1)
      if b[4] == 'arm' then
        local aa = col.track and reaper.GetMediaTrackInfo_Value(col.track, 'B_AUTO_RECARM') == 1
        if aa then text(cx - math.floor(ms('a') / 2) + 1, cy - math.floor((L.th or bh) / 2) - (D.SPACE or 0), 'a', on and U.TEXT or rc)   -- 27 окт: +1 px — у ширины буквы справа пустой столбец, центр по чернилам
        else set(on and U.TEXT or rc); gfx.circle(cx, cy, math.max(1, math.floor(r / 2)), on and 1 or 0, 1) end
      else text(cx - math.floor(ms(b[1]) / 2), cy - math.floor((L.th or bh) / 2) - (D.SPACE or 0), b[1], on and U.TEXT or rc) end
    else
      set((on and not b[5]) and ((b[3] == D.ARM and D.ARM_T) or U.tint(b[3], 0.5)) or U.PANEL); gfx.rect(bx, yy, bw, bh, 1)
      set(hot and U.AMBER or (on and b[3] or U.DIM)); gfx.rect(bx, yy, bw, bh, 0)
      text(bx + math.floor((bw - ms(b[1])) / 2), yy + math.floor((bh - (L.th or bh)) / 2) - (D.SPACE or 0), b[1], on and b[3] or U.readable(G0, U.PANEL, 4.5))
    end
    if hot then
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
    U.dslider(wx0, cy, ww, frac, centered, hot and U.AMBER or U.TEXT, hot, L.rh)   -- 13 окт: ромбик
    text(wx0 + ww + L.pad + vres - ms(val), sy, val, U.GREY)
    if hot then hover.trs = { col = col, what = what, x0 = wx0, w = ww } end
    if D.csel_on(col.guid, what) then csel_frame(wx0 - 1, sy + 2, ww + 2, L.rh - 4) end
  end
  local vol = lv('vol', col.vol or 1)
  local db = vol > 1e-6 and 20 * math.log(vol, 10) or -150
  if yy + L.rh <= y + h then slider(yy, (math.max(-60, math.min(12, db)) + 60) / 72, false, 'vol', db <= -60 and '-inf' or ('%+.1f'):format(db), 'vol'); yy = yy + L.rh end
  local pan = lv('pan', col.pan or 0)
  local ptxt = math.abs(pan) < 0.005 and 'C' or ((pan < 0 and 'L' or 'R') .. math.floor(math.abs(pan) * 100 + 0.5))
  if yy + L.rh <= y + h then slider(yy, (pan + 1) / 2, true, 'pan', ptxt, 'pan'); yy = yy + L.rh end
  -- строки-кнопки: вход, выход, отправки
  local function row(label, val, what, on, reserve)
    if yy + L.rh > y + h then return end
    local hot = mx >= x and mx < x + w and my >= yy and my < yy + L.rh
    if hot then set(U.tint(U.AMBER, 0.2)); gfx.rect(x + 1, yy, w - 2, L.rh, 1); hover.trkio = { col = col, what = what } end
    text(x + L.pad, yy, label, U.GREY)
    local lx = x + L.pad + ms('send ') + L.pad
    text(lx, yy, fit(val, x + w - L.pad - lx - (reserve or 0)), on == false and U.GREY or U.TEXT)   -- 11 окт: место под кнопку справа
    yy = yy + L.rh
  end
  -- smart (4 окт: из шапки трека сюда) — кнопкой справа в строке in
  local sy0 = yy
  local sbw = ms('smart') + 2 * L.pad
  local show_smart = info.smart_ok and w > ms('in ') + 6 * L.cw + sbw + 3 * L.pad
  row('in', (io.input:gsub(' / in ', '/'):gsub(' / ', '/')) .. ' v', 'input', nil, show_smart and (sbw + L.pad) or 0)
  if show_smart and yy > sy0 then
    local sx = x + w - L.pad - sbw
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
  -- 22 окт: быстрые пресеты трека — XY-пэд на пустом месте, в углах снапшоты 1..4 (все параметры FX трека),
  -- шайба — морф между ними; щелчок по пустому углу — запомнить, по полному — вызвать, Shift — перезаписать
  local sinfo = info.track_snaps and info.track_snaps(col)
  -- 29 окт: мини-роутер — под XY (кнопка route — слева, под take fx); auto / mod открыты — роутер шире, под ними тоже
  local tm0 = info.trk_mods and info.trk_mods(col)
  local rh2 = (tm0 and tm0.wroute) and math.max(5 * L.rh, math.floor(h * 0.4)) or 0
  D.snap_pad(L, sinfo, col, x, w, yy, y + h - rh2 - yy - 6, mx, my, hover, hint)
  -- 22 окт: mod · auto — у правого края блока две вертикальные кнопки: auto (сверху) и mod (снизу);
  -- любая раскрытая — блок вдвое шире, справа панель: сверху автоматизация, снизу модуляция с редакторами
  local tm = info.trk_mods and info.trk_mods(col)
  local extra = 0
  if tm then
    local sw = L.th + 6
    local sx = x + w
    local open = tm.wauto or tm.wmod
    local th0 = (open and rh2 > 0) and (h - rh2) or h   -- роутер под панелью — кнопки над ним
    local hh = math.floor(th0 / 2)
    for bi, b in ipairs({ { 'wauto', 'auto ' .. (tm.nauto or 0), tm.wauto, y, hh }, { 'wmod', 'mod ' .. (tm.nmod or 0), tm.wmod, y + hh, th0 - hh } }) do
      local by, bh2 = b[4], b[5]
      local hot = mx >= sx and mx < sx + sw and my >= by and my < by + bh2
      local bg = b[3] and U.tint(U.AMBER, 0.30) or (hot and U.tint(U.AMBER, 0.20) or rbg)
      set(bg); gfx.rect(sx, by, sw, bh2, 1)
      set((b[3] or hot) and U.AMBER or U.LINE); gfx.rect(sx, by, sw, bh2, 0)
      local tl = math.min(ms(b[2]), bh2 - 6)
      D.vtext(sx + math.floor((sw - L.th) / 2), by + 3, tl, b[2], (b[3] or hot) and U.AMBER or U.GREY, bg, true)
      if hot then hover.trkmod = { col = col, what = b[1] } end
      hint('trkmod', sx, by, sw, bh2, { what = b[1] })
    end
    extra = sw
    if tm.wauto or tm.wmod then
      local pw, px = w, sx + sw
      fill(rbg); gfx.rect(px, y, pw, h, 1)
      extra = extra + pw
      local h1 = h - rh2
      local ah = tm.wauto and (tm.wmod and math.max(3 * L.rh, math.floor(h1 * 0.35)) or h1) or 0
      if tm.wauto then D.auto_section(L, info, col, tm, px, y, pw, ah, hover) end
      if tm.wmod then
        if tm.wauto then set(U.LINE); gfx.rect(px + L.pad, y + ah - 1, pw - 2 * L.pad, 1, 1) end
        D.mod_section(L, info, col, tm, px, y + ah, pw, h1 - ah, hover)
      end
      set(U.LINE); gfx.rect(px, y, pw, h1, 0)
    end
  end
  U.TEXT, U.GREY = T0, G0
  set(U.LINE); gfx.rect(x, y, w, h, 0)                -- рамка, как у блоков FX
  if rh2 > 0 then   -- 29 окт: роутер — под XY, в ширину блока; под auto / mod — только когда они открыты (кнопки не закрывать)
    -- 30 окт: поверх рамок — расширенный роутер одним полем, без вертикальных разделителей блока / кнопок / панели
    local rw = (tm0 and (tm0.wauto or tm0.wmod)) and (w + extra) or w
    fill(rbg); gfx.rect(x + 1, y + h - rh2, rw - 2, rh2 - 1, 1)
    set(U.LINE); gfx.rect(x + L.pad, y + h - rh2, rw - 2 * L.pad, 1, 1)
    D.route_section(L, info, col, x, y + h - rh2, rw, rh2, hover)
    set(U.LINE); gfx.rect(x, y + h - rh2, rw, rh2, 0)
  end
  return w + extra
end

-- 22 окт: XY-пэд снимков (4 угла, шайба — морф); 28 окт: общий — шапка трека и контейнер (col — псевдо-колонка)
function D.snap_pad(L, sinfo, col, x, w, yy, room, mx, my, hover, hint)
  if not (sinfo and room >= 4 * L.rh) then return end

    local side = math.max(4 * L.rh, math.min(w - 2 * L.pad, room))
    local px0, py0 = x + math.floor((w - side) / 2), yy + 3
    local cbw = math.max(L.btn_w or 0, ms('4') + 6)
    local onpad = mx >= px0 and mx < px0 + side and my >= py0 and my < py0 + side
    set(U.BG); gfx.rect(px0, py0, side, side, 1)
    set(onpad and U.AMBER or U.LINE); gfx.rect(px0, py0, side, side, 0)
    set(U.mix(U.LINE, U.BG, 0.5)); gfx.rect(px0 + math.floor(side / 2), py0 + 1, 1, side - 2, 1); gfx.rect(px0 + 1, py0 + math.floor(side / 2), side - 2, 1, 1)
    local corners = { { px0 + 1, py0 + 1 }, { px0 + side - cbw - 1, py0 + 1 }, { px0 + 1, py0 + side - L.rh }, { px0 + side - cbw - 1, py0 + side - L.rh } }
    local oncorner
    for i, c in ipairs(corners) do
      local on = sinfo.has[i]
      local hot = mx >= c[1] and mx < c[1] + cbw and my >= c[2] and my < c[2] + L.rh - 1
      set(hot and U.tint(U.AMBER, 0.35) or (on and U.tint(U.CYAN, 0.35) or U.PANEL)); gfx.rect(c[1], c[2], cbw, L.rh - 1, 1)
      set(hot and U.AMBER or (on and U.CYAN or U.DIM)); gfx.rect(c[1], c[2], cbw, L.rh - 1, 0)
      text(c[1] + math.floor((cbw - ms(tostring(i))) / 2), c[2], tostring(i), hot and U.AMBER or (on and U.TEXT or U.GREY))
      if hot then hover.snapc = { col = col, i = i }; oncorner = true end
      hint('snapc', c[1], c[2], cbw, L.rh - 1, { i = i })
    end
    local n = 0; for i = 1, 4 do if sinfo.has[i] then n = n + 1 end end
    if n >= 2 then
      local cx = px0 + math.floor(sinfo.x * (side - 1) + 0.5)
      local cy = py0 + math.floor(sinfo.y * (side - 1) + 0.5)
      U.diamond(cx, cy, math.max(3, math.floor(L.rh / 3)), (onpad or sinfo.drag) and U.AMBER or U.CYAN, sinfo.drag)
    elseif n < 2 and side > ms('2 snapshots') + 2 * cbw then
      text(px0 + math.floor((side - ms('corners: save')) / 2), py0 + math.floor(side / 2) - L.rh, 'corners: save', U.DIM)
    end
    if onpad and not oncorner then hover.snappad = { col = col, x0 = px0, y0 = py0, side = side } end
end
-- 28 окт: мини-роутер — схема цепочки маленькими прямоугольниками: последовательно — вправо (черта между),
-- параллельно предыдущему — столбиком под ним; модули контейнера — с [ перед первым и ] после последнего; не
-- влезло в ширину — следующей полосой ниже; выбранный — янтарём, выключенный — тускло; щелчок — к модулю
function D.route_section(L, info, col, x, y, w, h, hover)
  local nodes = info.route_nodes and info.route_nodes(col) or {}
  local mx, my = gfx.mouse_x, gfx.mouse_y
  text(x + L.pad, y + 2, fit('ROUTE', w - 2 * L.pad), U.AMBER)
  do   -- 29 окт: > — большой fx routing (роутер REAPER в стиле трекера), был вкладкой слева
    local gx = x + L.pad + ms('ROUTE') + L.pad
    local gw = ms('>') + 2 * L.pad
    local hot = mx >= gx and mx < gx + gw and my >= y + 2 and my < y + L.rh + 1
    set(hot and U.tint(U.AMBER, 0.35) or U.PANEL); gfx.rect(gx, y + 2, gw, L.rh - 1, 1)
    set(hot and U.AMBER or U.LINE); gfx.rect(gx, y + 2, gw, L.rh - 1, 0)
    text(gx + L.pad, y + 2, '>', hot and U.AMBER or U.GREY)
    if hot then hover.dsprouter = true end
    if D.hint then D.hint('dsprouting', gx, y + 2, gw, L.rh - 1, 'route') end
  end
  -- 28 окт (2): справа от заголовка — слоты цепей 1..4 (сравнение: вся цепочка FX трека), ниже — схема в окошке
  local cs = info.chslots and info.chslots(col)
  if cs then
    local sbw = ms('4') + 2 * L.pad
    local sx = x + w - L.pad - 4 * (sbw + 2)
    if sx > x + L.pad + ms('ROUTE') + ms('>') + 4 * L.pad then
      for i = 1, 4 do
        local bx2 = sx + (i - 1) * (sbw + 2)
        local hot = mx >= bx2 and mx < bx2 + sbw and my >= y + 2 and my < y + L.rh + 1
        local on, cur = cs.has[i], cs.cur == i
        set(hot and U.tint(U.AMBER, 0.35) or (cur and U.tint(U.AMBER, 0.3) or (on and U.tint(U.CYAN, 0.3) or U.PANEL))); gfx.rect(bx2, y + 2, sbw, L.rh - 1, 1)
        set((hot or cur) and U.AMBER or (on and U.CYAN or U.DIM)); gfx.rect(bx2, y + 2, sbw, L.rh - 1, 0)
        text(bx2 + L.pad, y + 2, tostring(i), (hot or cur) and U.AMBER or (on and U.TEXT or U.GREY))
        if hot then hover.trkmod = { col = col, what = 'chslot', i = i } end
      end
    end
  end
  D.route_draw(L, nodes, col, x + L.pad, y + L.rh + 4, w - 2 * L.pad, y + h - 3 - (y + L.rh + 4), hover)
end
-- 28 окт: схема в окошке (шапка трека и вкладка route контейнера): nodes — узлы route_nodes (все / только внутри)
function D.route_draw(L, nodes, col, wx, wy, ww, wh, hover)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  if wh < L.rh + 4 then return end
  set(U.BG); gfx.rect(wx, wy, ww, wh, 1)
  set(U.LINE); gfx.rect(wx, wy, ww, wh, 0)
  if #nodes == 0 then text(wx + L.pad, wy + 2, fit('no fx', ww - 2 * L.pad), U.DIM); return end
  if not D.RK then return end
  -- 29 окт: вертикальный вид (последовательно — вниз, параллельно — вправо); имя — шире (нет нужды в 3 буквах)
  -- 29 окт (2): прямоугольники стоят (повёрнуты на 90° против часовой): узкие высокие, имя — вертикально снизу вверх;
  -- последовательно — вправо, параллельно — столбиком ниже (раскладка route_layout)
  local vert = D.route_vert == true   -- 29 окт (3): стоячие — неудобно; по умолчанию снова в строку, 3-4 буквы
  local lay = D.RK.route_layout
  local maxpar, run = 1, 1
  for i, n in ipairs(nodes) do if i > 1 and (n.par or 0) > 0 then run = run + 1; maxpar = math.max(maxpar, run) else run = 1 end end
  local nhv = vert and math.max(4 * L.cw, math.min(ms('WWWWWWWWW') + 2 * L.pad, math.floor((wh - 2 * L.pad) / maxpar) - 4)) or L.rh
  local nwv = vert and (L.rh + 2) or math.max(ms('WWWW') + 2 * L.pad, 4 * L.cw + 4)
  local eqw = ms('=') + 2   -- 30 окт: слева место под = параллельного в первом столбце
  local boxes, links, br, _, wraps = lay(nodes, { x = wx + L.pad + eqw, y = wy + L.pad, w = ww - 2 * L.pad - eqw - ms('>') - 2, h = wh - 2 * L.pad,
    nw = nwv, nh = nhv, gx = vert and math.max(4, L.pad) or math.max(6, 2 * L.pad, ms('=') + 4), bw = math.max(3, L.pad), rgap = 4 })
  set(U.GREY)
  for _, wr in ipairs(wraps or {}) do text(wr.x, wr.y, '>', U.GREY) end   -- 30 окт: цепочка продолжается полосой ниже
  for _, l in ipairs(links) do
    if l.v then gfx.rect(l.x, l.y1, 1, math.max(1, l.y2 - l.y1), 1) else gfx.rect(l.x1, l.y, math.max(1, l.x2 - l.x1), 1, 1) end
  end
  D.rboxes = boxes   -- клавиатура мини-роутера: порядок узлов
  for _, b in ipairs(br) do
    set(U.tint(U.AMBER, 0.6)); gfx.rect(b.x, b.y, 2, b.h, 1)
    local hx = b.right and (b.x - 2) or b.x
    gfx.rect(hx, b.y, 4, 1, 1); gfx.rect(hx, b.y + b.h - 1, 4, 1, 1)
  end
  local sel = D.rsel or D.dsp_selk   -- 29 окт: свой курсор роутера (щелчок), DSP — двойным / Enter
  local rd = D.rdrag
  D.rdrop = nil
  for bi, b in ipairs(boxes) do
    local n = b.n
    local hot = mx >= b.x and mx < b.x + b.w and my >= b.y and my < b.y + b.h
    local isel = sel == n.k
    local moving = (rd and rd.k == n.k) or (D.rlift == n.k)   -- 29 окт: x — «поднят»
    local tgt = D.rlift and D.rlift ~= n.k and isel           -- поднят другой: курсор — место вставки
    local fillc = n.cont and U.tint(U.AMBER, 0.18) or ((n.depth or 0) > 0 and U.tint(U.CYAN, 0.08 + 0.06 * math.min(3, n.depth)) or U.PANEL)
    set((hot and not rd) and U.tint(U.AMBER, 0.35) or fillc); gfx.rect(b.x, b.y, b.w, b.h, 1)
    set((hot or isel or moving) and U.AMBER or (n.en and U.LINE or U.DIM)); gfx.rect(b.x, b.y, b.w, b.h, 0)
    if (n.par or 0) > 0 and bi > 1 and boxes[bi - 1].x == b.x then text(b.x - ms('=') - 1, b.y, '=', U.GREY) end   -- 30 окт: параллельно — знак = слева (была черта)
    local lb = D.RK.abbrev(n.name, 4)
    if moving and D.rlift then set(U.tint(U.CYAN, 0.35)); gfx.rect(b.x, b.y, b.w, b.h, 1); set(U.CYAN); gfx.rect(b.x, b.y, b.w, b.h, 0) end
    if tgt then set(U.CYAN); gfx.rect(b.x + b.w, b.y, 2, b.h, 1) end   -- вставится после него (правее)
    if isel and D.rkb then set(D.CUR_ACC or U.AMBER); gfx.rect(b.x - 1, b.y - 1, b.w + 2, b.h + 2, 0) end
    local tc = (hot or isel or moving) and U.AMBER or (n.en and U.TEXT or U.GREY)
    if vert then D.vtext(b.x + math.floor((b.w - TH()) / 2), b.y + 2, b.h - 4, n.name or '?', tc, (hot and not rd) and U.tint(U.AMBER, 0.35) or fillc)
    else text(b.x + math.floor((b.w - ms(lb)) / 2), b.y, lb, tc) end
    -- бросок: левая половина — до, правая — после, ниже узла (до следующего ряда) — параллельно ему
    if rd and not moving and mx >= b.x - 3 and mx < b.x + b.w + 3 and my >= b.y and my < b.y + b.h + L.rh then
      local mode = my >= b.y + b.h and 'par' or (mx < b.x + b.w / 2 and 'before' or 'after')
      D.rdrop = { k = n.k, mode = mode }
      set(U.CYAN)
      if mode == 'par' then gfx.rect(b.x, b.y + b.h + 1, b.w, 2, 1)
      elseif mode == 'before' then gfx.rect(b.x - 3, b.y - 1, 2, b.h + 2, 1)
      else gfx.rect(b.x + b.w + 1, b.y - 1, 2, b.h + 2, 1) end
    end
    if hot and not rd then hover.trkmod = { col = col, what = 'rnode', k = n.k, par = n.par, name = n.name } end
  end
end

-- 22 окт: LFO REAPER графикой — значение 0..1 формы shape в точке t (два периода на ширину)
function D.lfo_val(shape, t)
  local f = (2 * t) % 1
  if shape == 1 then return f < 0.5 and 1 or 0
  elseif shape == 2 then return 1 - f
  elseif shape == 3 then return f
  elseif shape == 4 then return 1 - math.abs(2 * f - 1)
  elseif shape == 5 then local k = math.floor(t * 8); local v = math.sin(k * 12.9898 + 4.1) * 43758.5453; return v - math.floor(v)
  end
  return 0.5 + 0.5 * math.sin(2 * math.pi * 2 * t)
end

-- мини-график строки панели: LFO — волна (циан), иначе кривая огибающей по песне
local function mod_graph(x, y, w, h, r, col)
  if w < 6 or h < 3 then return end
  set(U.mix(U.LINE, U.BG, 0.4)); gfx.rect(x, y + h - 1, w, 1, 1)
  set(col)
  local px, py
  for i = 0, w - 1 do
    local t = i / math.max(1, w - 1)
    local v
    if r.lfoshape then v = 0.5 + (D.lfo_val(r.lfoshape, t) - 0.5) * math.max(0.15, math.min(1, r.lfostr or 1))
    elseif r.pts then
      local f = t * (#r.pts - 1)
      local a = math.floor(f)
      local p0, p1 = r.pts[a + 1], r.pts[math.min(#r.pts, a + 2)]
      v = p0[2] + (p1[2] - p0[2]) * (f - a)
    else return end
    local cy = y + h - 1 - math.floor(v * (h - 1) + 0.5)
    if px then gfx.line(px, py, x + i, cy) end
    px, py = x + i, cy
  end
end

local PK_PRE = { [0.25] = '1/16', [0.5] = '1/8', [1] = '1/4', [2] = '1/2', [4] = '1 bar', [8] = '2 bars' }

-- строка кнопок с переносом: list = { { what, label, on, sel, data } }; возвращает новый yy
local function btn_row(L, x, w, yy, list, hover, col, enabled)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local bx = x + L.pad
  for n, b in ipairs(list) do
    local bw = ms(b[2]) + 2 * L.pad
    if bx + bw > x + w - L.pad and n > 1 then bx = x + L.pad; yy = yy + L.rh end
    local hb = enabled and mx >= bx and mx < bx + bw and my >= yy and my < yy + L.rh
    set(hb and U.tint(U.AMBER, 0.35) or (b[3] and U.tint(U.CYAN, 0.35) or U.PANEL)); gfx.rect(bx, yy + 1, bw, L.rh - 2, 1)
    set((hb or b[4]) and U.AMBER or (b[3] and U.CYAN or U.DIM)); gfx.rect(bx, yy + 1, bw, L.rh - 2, 0)
    text(bx + L.pad, yy, b[2], enabled and ((hb or b[4]) and U.AMBER or (b[3] and U.TEXT or U.GREY)) or U.DIM)
    if hb then hover.trkmod = { col = col, what = b[1], tab = b[5], v = b[5] } end
    hint('trkmod', bx, yy, bw, L.rh, { what = b[1], tab = b[5], v = b[5] })
    bx = bx + bw + 2
  end
  return yy + L.rh
end
local function btn_rows_n(L, x, w, list)
  local rows, bx = 1, x + L.pad
  for n, b in ipairs(list) do
    local bw = ms(b[2]) + 2 * L.pad
    if bx + bw > x + w - L.pad and n > 1 then rows = rows + 1; bx = x + L.pad end
    bx = bx + bw + 2
  end
  return rows
end

-- строки параметров (filter: 'auto' | 'mod'); возвращает yy
local function mod_rows(L, col, tm, x, yy, w, ymax, filter, hover)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local list = {}
  for ri, r in ipairs(tm.rows) do if (filter == 'auto' and r.env) or (filter == 'mod' and r.ismod) then list[#list + 1] = ri end end
  local nfit = math.max(0, math.floor((ymax - yy) / L.rh))
  local more = #list > nfit and nfit > 0
  local nshow = math.min(#list, more and nfit - 1 or nfit)
  if #list == 0 and nfit > 0 then
    text(x + L.pad, yy, fit(filter == 'auto' and 'no automation on this track' or 'nothing modulated - pick a parameter, a tab below', w - 2 * L.pad), U.GREY)
    return yy + L.rh
  end
  local FL = filter == 'mod' and { { 'lfo', 'L', U.CYAN }, { 'acs', 'A', U.GREEN }, { 'lnk', 'K', U.AMBER }, { 'pk', 'P', U.AMBER } } or {}
  local flw = filter == 'mod' and ms('LAKP') + L.pad or 0
  local gw = math.floor(w * (filter == 'auto' and 0.45 or 0.3))
  for n = 1, nshow do
    local ri = list[n]
    local row = tm.rows[ri]
    local hot = mx >= x and mx < x + w and my >= yy and my < yy + L.rh
    if hot or row.sel then set(U.tint(U.AMBER, row.sel and 0.25 or 0.15)); gfx.rect(x + 1, yy, w - 2, L.rh, 1) end
    if hot then hover.trkmod = { col = col, what = 'row', r = ri, auto = filter == 'auto' } end
    local gx = x + w - L.pad - gw
    local fx0 = gx - L.pad - flw
    text(x + L.pad, yy, fit(row.label, fx0 - x - 2 * L.pad), row.sel and U.AMBER or U.TEXT)
    for _, fl in ipairs(FL) do
      if row[fl[1]] then text(fx0, yy, fl[2], fl[3]) end
      fx0 = fx0 + ms(fl[2])
    end
    local g = filter == 'auto' and { pts = row.pts } or row
    mod_graph(gx, yy + 2, gw, L.rh - 4, g, (filter == 'mod' and row.lfoshape) and U.CYAN or (hot and U.AMBER or U.GREY))
    yy = yy + L.rh
  end
  if more then text(x + L.pad, yy, fit(('+%d more - automation tab'):format(#list - nshow), w - 2 * L.pad), U.GREY); yy = yy + L.rh end
  return yy
end

function D.auto_section(L, info, col, tm, x, y, w, h, hover)
  local yy = y + 3
  text(x + L.pad, yy, fit('automation  ' .. (tm.nauto or 0), w - 2 * L.pad), U.AMBER)
  yy = yy + L.rh
  mod_rows(L, col, tm, x, yy, w, y + h - 2, 'auto', hover)
end

-- ползунок настройки модуляции: имя, полоса, значение; протяжка — ctx.mdrag
-- 31 окт: 8 слотов быстрой загрузки slixer плитками в полосе sx0..sx1 на высоте qy (мини-волна, имя поверх)
function D.slx_slots(L, info, f, k, sx0, sx1, qy, hover, mx, my, drag)
  local qw = math.min(L.cw * 9, math.floor((sx1 - sx0 - 7 * 2) / 8))
  if qw < L.cw * 3 then return false end
  local sl = info.slx_slots() or {}
  for i = 0, 7 do
    local e = sl[i + 1] or {}
    local qx, qh = sx0 + i * (qw + 2), L.rh - 1
    local full = e.path and e.path ~= ''
    local hot = not drag and mx >= qx and mx < qx + qw and my >= qy and my < qy + qh
    set(hot and U.tint(U.AMBER, 0.25) or U.BG); gfx.rect(qx, qy, qw, qh, 1)
    local pk = full and info.slx_slot_peaks and info.slx_slot_peaks(e.path, 24)
    if pk then
      set(U.tint(U.CYAN, hot and 0.45 or 0.3))
      local n = math.min(#pk, qw - 2)
      for c = 0, n - 1 do
        local v = pk[math.floor(c * #pk / n) + 1] or 0
        local hh = math.max(1, math.floor(v * (qh - 2) + 0.5))
        gfx.rect(qx + 1 + math.floor(c * (qw - 2) / n), qy + math.floor((qh - hh) / 2), math.max(1, math.floor((qw - 2) / n)), hh, 1)
      end
    end
    set(hot and U.AMBER or U.LINE); gfx.rect(qx, qy, qw, qh, 0)
    text(qx + 2, qy, fit(full and e.name or tostring(i + 1), qw - 4), hot and U.AMBER or (full and U.TEXT or U.DIM))
    if hot then hover.dspbtn = { fx = k, f = f, what = 'qslot', slot = i, path = e.path or '', name = e.name } end
    hint('dspbtn', qx, qy, qw, qh, { fx = k, what = 'qslot', slot = i })
  end
  return true
end
-- 31 окт: маленький модуль (1..3 параметра, без своего вида, XY выключен) — колонкой под предыдущим маленьким, если
-- влезает по высоте; между ними стрелка v (сигнал идёт вниз). → bx, by, bh
function D.stack_place(L, info, f, ncol, bx, boxy, bh0)
  f._small = nil
  local np = 0
  for _, p in ipairs(f.params or {}) do if not p.mfader then np = np + 1 end end
  local xy = info.dsp_xy and info.dsp_xy[tostring(f.fguid or f.i)]
  local small = np >= 1 and np <= 3 and ncol == 1 and not f.view and not f.container and not f.kit and not f.rs5k
    and not f.wave and not f.xy and not f.pages and not f.inner and not f.nmacro and not (xy and xy.on)
  if not small then D.stk = nil; return bx, boxy, bh0 end
  f._small = true
  local h = (np + 2) * L.rh + 6
  local s = D.stk
  if s and s.y + h <= boxy + bh0 then
    -- стрелка v в промежутке над модулем
    text(s.x + math.floor((s.w - ms('v')) / 2), s.y - L.rh, 'v', U.GREY)
    return s.x, s.y, h
  end
  D.stk = { x = bx, y = boxy + h + L.rh, w = 0 }
  return bx, boxy, h
end
-- 31 окт: XY модуля (zx вкл / выкл): оси — параметры из info.dsp_xy[guid] (x, y) или первые два; заголовок x: / y: —
-- щелчок открывает список параметров; Cmd+щелчок по параметру — X, следующий — Y
function D.xy2(L, info, f, k, vals, bx, by, bw, bh, pw, hover, mx, my, drag)
  local key = tostring(f.fguid or f.i)
  local xy = info.dsp_xy and info.dsp_xy[key]
  if not (xy and xy.on) then return end
  local ix = {}
  for pi, p in ipairs(f.params or {}) do if not p.mfader then ix[#ix + 1] = pi end end
  local qx, qy = xy.x or ix[1], xy.y or ix[2]
  if not (qx and qy) then return end
  local side = math.min(pw, bh - (L.rh + 1) - (#ix + 2) * L.rh - 6)
  if side < L.rh * 3 then return end
  local px0, py0 = bx + L.pad + math.floor((pw - side) / 2), by + bh - side - 3
  -- строка осей над пэдом: x: имя  y: имя (щелчок — выбрать параметр)
  local ly = py0 - L.rh
  local hw = math.floor(side / 2)
  for a, q in ipairs({ qx, qy }) do
    local lx = px0 + (a - 1) * hw
    local lab = (a == 1 and 'x: ' or 'y: ') .. ((f.params[q] and f.params[q].name) or '?')
    local hot = not drag and mx >= lx and mx < lx + hw and my >= ly and my < ly + L.rh
    text(lx, ly, fit(lab, hw - 2), hot and U.AMBER or U.GREY)
    if hot then hover.dspbtn = { fx = k, f = f, what = 'xyaxis', axis = a == 1 and 'x' or 'y' } end
  end
  local nx = vals[qx] and vals[qx].n or 0.5
  local ny = vals[qy] and vals[qy].n or 0.5
  set(U.PANEL); gfx.rect(px0, py0, side, side, 1)
  set(U.LINE); gfx.rect(px0, py0, side, side, 0)
  set(U.DIM); gfx.rect(px0 + math.floor(side / 2), py0, 1, side, 1); gfx.rect(px0, py0 + math.floor(side / 2), side, 1, 1)
  local hot = not drag and mx >= px0 and mx < px0 + side and my >= py0 and my < py0 + side
  local dx, dy = px0 + math.floor(nx * (side - 1) + 0.5), py0 + math.floor((1 - ny) * (side - 1) + 0.5)
  set(hot and U.AMBER or U.CYAN); gfx.circle(dx, dy, math.max(3, math.floor(L.rh / 3)), 1, 1)
  if hot then hover.dspxy = { fx = k, f = f, x = px0, y = py0, s = side, qx = qx, qy = qy } end
end
local function mslider(L, col, x, yy, w, sl, val, fmtx, hover, enabled)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local lw, vw = ms('depth') + L.pad, ms('1000 ms') + L.pad   -- подписи до 5 букв (rate att rel offs), значение до 7
  local bx, bw = x + L.pad + lw, w - 2 * L.pad - lw - vw
  if bw < 10 then return yy end
  local fr = math.max(0, math.min(1, (val - sl[3]) / math.max(1e-9, sl[4] - sl[3])))
  local hot = enabled and mx >= bx - 2 and mx < bx + bw + 2 and my >= yy and my < yy + L.rh
  text(x + L.pad, yy, sl[2], hot and U.AMBER or U.GREY)
  set(U.mix(U.LINE, U.BG, 0.3)); gfx.rect(bx, yy + math.floor(L.rh / 2) - 1, bw, 2, 1)
  set(enabled and (hot and U.AMBER or U.CYAN) or U.DIM); gfx.rect(bx, yy + math.floor(L.rh / 2) - 1, math.floor(bw * fr + 0.5), 2, 1)
  gfx.rect(bx + math.floor((bw - 3) * fr + 0.5), yy + 3, 3, L.rh - 6, 1)
  local f = sl[5]
  local vs = f == 'pct' and ('%d%%'):format(math.floor(val * 100 + 0.5)) or (f == 'hz' and (fmtx and ('%.2f qn'):format(val) or ('%.2f Hz'):format(val)) or f:format(val))
  text(x + w - L.pad - ms(vs), yy, vs, hot and U.AMBER or U.TEXT)
  if hot then hover.trkmod = { col = col, what = 'sl', key = sl[1], lo = sl[3], hi = sl[4], x0 = bx, w = bw, name = sl[2] } end
  return yy + L.rh
end

-- вертикальная пианинка 2 октавы (вход MIDI трека светится) + метр velocity входа
local function vpiano(L, info, col, x, y, w, h)
  local t, v, pn = nil, nil, nil
  if info.midi_in then t, v, pn = info.midi_in(col.guid) end
  local age = t and (reaper.time_precise() - t) or 99
  local lo = pn and math.max(0, math.min(104, 12 * math.floor(pn / 12) - 12 + (pn % 12 >= 6 and 12 or 0))) or 48
  local kh = math.max(2, math.floor(h / 24))
  local mw = 4
  local kw = w - mw - 2
  set(U.BG); gfx.rect(x, y, w, h, 1)
  for k = 0, 23 do
    local note = lo + k
    local ky = y + h - (k + 1) * kh
    if ky < y then break end
    local blk = ({ [1] = 1, [3] = 1, [6] = 1, [8] = 1, [10] = 1 })[note % 12]
    local lit = pn == note and age < 0.6
    set(lit and U.AMBER or (blk and U.mix(U.BG, U.TEXT, 0.15) or U.mix(U.BG, U.TEXT, 0.55)))
    gfx.rect(x, ky, blk and math.floor(kw * 0.6) or kw, kh - 1, 1)
    if note == 60 then set(U.CYAN); gfx.rect(x + kw - 2, ky, 2, kh - 1, 1) end   -- C-4: keytrack x1
  end
  -- метр velocity: высота — сила последней ноты входа, гаснет за 0.8 с
  local lvl = v and age < 0.8 and (v / 127) * (1 - age / 0.8) or 0
  set(U.LINE); gfx.rect(x + w - mw, y, mw, h, 0)
  if lvl > 0 then set(U.GREEN); gfx.rect(x + w - mw + 1, y + h - math.floor(h * lvl), mw - 2, math.floor(h * lvl), 1) end
end

-- редактор кривой premod: точки ромбами, линия; протяжка точки, двойной щелчок — точка, ПКМ — убрать
local function curve_edit(L, info, col, x, y, w, h, cv, hover)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  set(U.BG); gfx.rect(x, y, w, h, 1)
  set(U.LINE); gfx.rect(x, y, w, h, 0)
  if not cv then return end
  local ix, iy, iw, ih = x + 3, y + 3, w - 6, h - 6
  local function P(pt) return ix + math.floor(pt[1] * (iw - 1) + 0.5), iy + ih - 1 - math.floor(pt[2] * (ih - 1) + 0.5) end
  set(U.mix(U.LINE, U.BG, 0.5)); gfx.rect(ix, iy + math.floor(ih / 2), iw, 1, 1)
  set(U.CYAN)
  local px, py
  for _, pt in ipairs(cv.pts) do local cx, cy = P(pt); if px then gfx.line(px, py, cx, cy) end; px, py = cx, cy end
  local onpt
  for i, pt in ipairs(cv.pts) do
    local cx, cy = P(pt)
    local hot = math.abs(mx - cx) <= 4 and math.abs(my - cy) <= 4
    if hot then onpt = i - 1 end
    set(hot and U.AMBER or U.TEXT)
    for d = 0, 3 do gfx.rect(cx - d, cy - 3 + d, 2 * d + 1, 1, 1); gfx.rect(cx - d, cy + 3 - d, 2 * d + 1, 1, 1) end
  end
  local ph = info.pm_phase and info.pm_phase()
  if ph then set(U.AMBER); gfx.rect(ix + math.floor(ph * (iw - 1)), iy, 1, ih, 1) end
  if mx >= x and mx < x + w and my >= y and my < y + h then hover.trkmod = { col = col, what = 'cv', k = onpt, x0 = ix, y0 = iy, w = iw, h = ih } end
end

local function ctx_sl(info, tab) return info.modsl and info.modsl[tab] or {} end   -- ползунки вкладки (ctx.MODSL)
local LFO_SH = { { 0, 'sin' }, { 1, 'sqr' }, { 2, 'saw-' }, { 3, 'saw+' }, { 4, 'tri' }, { 5, 'rnd' } }

function D.mod_section(L, info, col, tm, x, y, w, h, hover)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local yy = y + 3
  text(x + L.pad, yy, fit('modulation  ' .. (tm.nmod or 0), w - 2 * L.pad), U.AMBER)
  yy = yy + L.rh
  local m = tm.sel and info.modedit and info.modedit(col, tm) or nil
  local tab = info.modtab and info.modtab() or 'lfo'
  -- список модулированных — не больше трёх строк, редактор важнее
  yy = mod_rows(L, col, tm, x, yy, w, math.min(y + h - 6 * L.rh, yy + 3 * L.rh), 'mod', hover)
  text(x + L.pad, yy, fit(tm.sel and ('> ' .. tm.sel) or '> pick a parameter in DSP', w - 2 * L.pad), tm.sel and U.TEXT or U.GREY)
  yy = yy + L.rh
  local act = m and m.act or {}
  local TABS = { { 'tab', 'lfo', act.lfo, tab == 'lfo', 'lfo' }, { 'tab', 'acs', act.acs, tab == 'acs', 'acs' }, { 'tab', 'link', act.lnk, tab == 'lnk', 'lnk' },
    { 'tab', 'env', act.env, tab == 'env', 'env' }, { 'tab', 'premod', act.pm, tab == 'pm', 'pm' } }
  yy = btn_row(L, x, w, yy, TABS, hover, col, tm.sel ~= nil)
  if not m then return end
  local bottom = y + h - 3
  local on = act[tab]
  local NAME = { lfo = 'lfo', acs = 'acs', lnk = 'link', env = 'envelope', pm = 'premod' }
  local top = { { 'on', NAME[tab] .. (on and ' on' or ' off'), on } }
  if tab == 'lfo' then top[#top + 1] = { 'sync', 'sync', m.sync }
  elseif tab == 'acs' then top[#top + 1] = { 'chan', m.chan34 and 'in 3/4' or 'in 1/2', m.chan34 }; top[#top + 1] = { 'side', 'side' }
  elseif tab == 'lnk' then top[#top + 1] = { 'pick', 'source' }
  elseif tab == 'env' then top[#top + 1] = { 'envshow', 'show' }; top[#top + 1] = { 'follow', 'follow' }   -- 22 окт: за другим треком / огибающей
  elseif tab == 'pm' and m.pk then
    top[#top + 1] = { 'pkpre', 'pre ' .. (PK_PRE[m.pk.pre] or ('%g'):format(m.pk.pre)) }
    top[#top + 1] = { 'pkkey', 'key', m.pk.key }; top[#top + 1] = { 'pkvel', 'vel', m.pk.vel }
    top[#top + 1] = { 'pkhum', 'hum ' .. (m.pk.hum or 0) .. '%', (m.pk.hum or 0) > 0 }
    local NNm = { 'C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-' }
    top[#top + 1] = { 'pkpitch', m.pk.pitch and (NNm[m.pk.pitch % 12 + 1] .. (m.pk.pitch // 12 - 1)) or 'all notes', m.pk.pitch ~= nil }   -- 22 окт: одна высота (бочка кита)
    top[#top + 1] = { 'pktest', 'test' }
  end
  yy = btn_row(L, x, w, yy, top, hover, col, true)
  if tab == 'lfo' then
    local gh = math.min(3 * L.rh, bottom - yy - (btn_rows_n(L, x, w, LFO_SH) + #ctx_sl(info, 'lfo')) * L.rh)
    if gh >= L.rh then
      local gx, gw = x + L.pad, w - 2 * L.pad
      set(U.BG); gfx.rect(gx, yy + 1, gw, gh - 2, 1); set(U.LINE); gfx.rect(gx, yy + 1, gw, gh - 2, 0)
      mod_graph(gx + 2, yy + 3, gw - 4, gh - 6, { lfoshape = m.shape, lfostr = m.vals['lfo.strength'] }, on and U.CYAN or U.GREY)
      yy = yy + gh
    end
    local SH = {}
    for _, sh in ipairs(LFO_SH) do SH[#SH + 1] = { 'shape', sh[2], m.shape == sh[1], false, sh[1] } end
    yy = btn_row(L, x, w, yy, SH, hover, col, true)
  elseif tab == 'lnk' then
    text(x + L.pad, yy, fit('from ' .. (m.src or '- (source: pick one)'), w - 2 * L.pad), m.src and U.TEXT or U.GREY)
    yy = yy + L.rh
  elseif tab == 'env' then
    local gh = bottom - yy - L.rh
    if gh >= L.rh and m.envpts then
      local gx, gw = x + L.pad, w - 2 * L.pad
      set(U.BG); gfx.rect(gx, yy + 1, gw, gh - 2, 1); set(U.LINE); gfx.rect(gx, yy + 1, gw, gh - 2, 0)
      mod_graph(gx + 2, yy + 3, gw - 4, gh - 6, { pts = m.envpts }, U.CYAN)
      yy = yy + gh
      text(x + L.pad, yy, fit(('%d points over the song - show: in REAPER'):format(m.npts or 0), w - 2 * L.pad), U.GREY)
    elseif not m.envpts then text(x + L.pad, yy, fit('no envelope yet - envelope off: click to make it', w - 2 * L.pad), U.GREY) end
    return
  elseif tab == 'pm' then
    if not m.pk then text(x + L.pad, yy, fit('a curve before every note of the track (premod off: click)', w - 2 * L.pad), U.GREY); return end
    local eh = bottom - yy - 2
    if eh >= 2 * L.rh then
      local pw2 = math.max(L.cw * 3, math.floor(w * 0.18))
      curve_edit(L, info, col, x + L.pad, yy + 1, w - 3 * L.pad - pw2, eh, m.curve, hover)
      vpiano(L, info, col, x + w - L.pad - pw2, yy + 1, pw2, eh)
    end
    return
  end
  for _, sl in ipairs(ctx_sl(info, tab)) do
    if yy + L.rh > bottom then break end
    yy = mslider(L, col, x, yy, w, sl, m.vals[sl[1]] or sl[3], tab == 'lfo' and m.sync, hover, on)
  end
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
-- режим PANE: номер листа (1..9 — фокус цифрой) у правого края его верхней строки
function D.pane_badge(L, c, h)
  local ns = tostring(c.num)
  local nx = c.x + c.w - ms(ns) - L.pad - 2
  local g0 = D.TABGAP or 0                              -- 19 окт: под пустотой над вкладками
  set(U.AMBER); gfx.rect(nx - 2, c.y + g0, ms(ns) + 4, h - g0, 1)
  -- 13 окт: обрезка — своего листа (от прошлого листа оставалась чужая — цифру срезало, плашка пустая)
  local keep = D.clip
  D.clip = { c.x, c.x + c.w, c.y, c.y + h }
  text(nx, c.y + g0 + 1, ns, U.BG)
  D.clip = keep
end
-- 11 окт: у трекера нет строки вкладок, и его тело рисуется после рамок —
-- номер ставится в проходе post (поверх шапки), иначе его не видно
function D.pane_badge_tracker(L, on)
  local c = D.pn_tracker_cell
  if on and L and c and c.num and c.num <= 9 then D.pane_badge(L, c, L.rh) end
end

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
      -- 15 окт: arc — куда идут кольца: эффект (из DSP; память по имени эффекта) и 4 параметра; клик — назначить
      local ai = info.arc_info and info.arc_info()
      if ai then
        local head = ('arc -> %s / %s%s'):format(ai.track ~= '' and ai.track or '?', ai.fx, ai.mem and '  (remembered)' or '  (from the DSP cursor)')
        text(X0 + 2, y0 + 1, fit(head, MW - 2 * L.pad), U.TEXT)
        y0 = y0 + L.rh
        local cw4 = math.floor((MW - 2 * L.pad) / 4)
        for n = 1, 4 do
          local rx = X0 + (n - 1) * cw4
          local r = ai.rings[n]
          local hot = mx >= rx and mx < rx + cw4 - 2 and my >= y0 and my < y0 + 2 * L.rh
          set(hot and D.CURROW or U.PANEL); gfx.rect(rx, y0, cw4 - 2, 2 * L.rh, 1)
          set(hot and U.AMBER or U.LINE); gfx.rect(rx, y0, cw4 - 2, 2 * L.rh, 0)
          text(rx + L.pad, y0 + 1, fit(n .. ' ' .. (r and r.name or '- click: assign'), cw4 - 2 * L.pad - 2), r and U.TEXT or U.DIM)
          if r and r.v then
            local bw = cw4 - 2 * L.pad - 2
            set(U.DIM); gfx.rect(rx + L.pad, y0 + L.rh + math.floor(L.rh / 2), bw, 2, 1)
            set(U.AMBER); gfx.rect(rx + L.pad, y0 + L.rh + math.floor(L.rh / 2) - 1, math.floor(bw * r.v + 0.5), 4, 1)
          end
          if hot then hover.arcring = n end
          hint('arcring', rx, y0, cw4 - 2, 2 * L.rh, n)
        end
        y0 = y0 + 2 * L.rh + 4
      else
        text(X0 + 2, y0 + 1, fit('arc: pick an effect in DSP - its 4 parameters go to the rings', MW - 2 * L.pad), U.GREY)
        y0 = y0 + L.rh + 2
      end
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
      local lines = { 'rows 1-7: slots x tracks', 'lit: events  X: muted', 'arc: rings = the effect above (none: 1 lpb 2 oct 3 step 4 inst)', 'col 16: host (mod list)' }
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
      -- 6 окт: набор и порядок — c.quick («id,id|id,…|…», три колонки; правка —
      -- ПКМ по имени опции в окне Options). Встроенные — свои подписи и флаги,
      -- остальные опции — c.qgen[id] = { label, on }
      local QL = { q_mx = 'matrix', q_ruler = 'ruler', q_hints = 'hints', q_listen = 'listen', debug = 'debug', q_scopes = 'scopes',
        q_input = 'input', q_captions = 'col names', q_names = 'names', q_wave = 'wave', q_colors = 'colours', q_envs = 'envs',
        q_meters = 'meters', q_dsp = 'dsp', q_side = 'browser', q_preview = 'preview', q_keys = 'kcast', oneclick = 'one click',
        autofocus = 'autofocus', perf = 'performance', follow = 'follow', lock = 'lock', fixed = 'fixed', q_endstop = 'end stop' }
      local cols = {}
      for part in ((c.quick or '') .. '|'):gmatch('([^|]*)|') do
        local col = {}
        for id in part:gmatch('[^,]+') do
          if id == 'xfade' then col[#col + 1] = q('xfade', c.xfade and ('x-fade ' .. (c.xfade_ms or 10)) or 'x-fade', c.xfade)
          elseif QL[id] then col[#col + 1] = q(id, QL[id], c[id], (id == 'q_keys' and { sizer = true }) or (id == 'q_side' and { sizer = { { '<', 'q_sidel' }, { '>', 'q_sider' } } }) or nil)   -- browser < > (7 окт): слева / справа
          elseif c.qgen and c.qgen[id] then col[#col + 1] = q(id, c.qgen[id].label, c.qgen[id].on, id == 'mixer' and { sizer = { { '^', 'q_mixup' }, { 'v', 'q_mixdn' } } } or nil) end   -- mixer ^ v (8 окт): над / под трекером
        end
        cols[#cols + 1] = col
        if #cols == 3 then break end
      end
      for k = #cols + 1, 3 do cols[k] = {} end
      local out, n = {}, math.max(#cols[1], #cols[2], #cols[3])
      for r = 1, n do for k = 1, 3 do out[#out + 1] = cols[k][r] or { false } end end
      return out
    end)() },
  }
  local colw = math.floor((L.ctrl_w - 2 * L.pad) / 3)
  L.ctrl_area = { 0, 0, L.ctrl_w, H - 2 }                 -- главный модуль: фокус ctrl (3 окт)
  D.ctrl_rect = D.ctrl_rect or {}
  local y = 2
  local qx, qw                                   -- колонки группы quick (6 окт): ширина по словам
  local function cell(it, ci)
    if not it[1] then return end                   -- пустая клетка колонки
    local x = L.pad + (qx and qx[ci] or ci * colw)
    local colw = qw and qw[ci] or colw
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
      -- 11 окт: тёмный текст на жёлтом — с подложкой (при масштабе текст кладётся сложением, чёрный пропадал)
      if on then text(x + 3, y + 1, fit(it[2], colw - 6), U.BG, U.AMBER)
      else text(x + 3, y + 1, fit(it[2], colw - 6), (hot or kbd) and U.AMBER or U.GREY) end
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
      for _, z in ipairs(type(it.sizer) == 'table' and it.sizer or { { '-', 'q_kcm' }, { '+', 'q_kcp' } }) do
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
  -- вкладки проектов (8 окт): тонкая строка сверху, кнопки поровну
  -- (не уже 6 знаков, лишние — «+N»); активная — янтарём, * — не сохранён
  if c.ptabs and #c.ptabs > 0 then
    local n = #c.ptabs
    local tw = L.ctrl_w - 2 * L.pad
    local bw = math.max(6 * L.cw, math.floor(tw / n))
    local fitn = math.max(1, math.floor(tw / bw))
    local x = L.pad
    for i, t in ipairs(c.ptabs) do
      if i > fitn or (i == fitn and n > fitn) then text(x + 2, y + 1, '+' .. (n - i + 1), U.CYAN); break end
      local w2 = (i == fitn) and (L.pad + tw - x) or bw
      local hot = mx >= x and mx < x + w2 - 2 and my >= y and my < y + L.rh
      -- 10 окт: вкладки, а не кнопки — как ярлыки стека панелей: |a|b|c| на общей линии,
      -- активная подсвечена и «открыта» книзу, у неактивных — только разделители
      if i == 1 then set(U.LINE); gfx.rect(L.pad, y + L.rh, tw, 1, 1) end
      set(t.on and U.tint(U.AMBER, 0.30) or (hot and D.CURROW or U.PANEL)); gfx.rect(x, y, w2 - 1, L.rh, 1)
      set(t.on and U.AMBER or U.LINE); gfx.rect(x, y, 1, L.rh, 1); gfx.rect(x + w2 - 2, y, 1, L.rh, 1)
      if t.on then gfx.rect(x, y, w2 - 1, 1, 1); set(U.tint(U.AMBER, 0.30)); gfx.rect(x + 1, y + L.rh, w2 - 3, 1, 1) end
      text(x + 4, y + 1, fit((t.dirty and '*' or '') .. t.name, w2 - 8), t.on and U.AMBER or (hot and U.TEXT or U.GREY))
      if hot then hover.ctrl = 'ptab:' .. (i - 1) end
      hint('ctrl', x, y, w2 - 2, L.rh, 'ptab:' .. (i - 1))
      x = x + w2
    end
    y = y + L.rh + 3
  end
  for gi, g in ipairs(groups) do
    local ci = 0
    -- 6 окт: быстрые опции — ширина колонок по самому длинному слову колонки
    -- (одинаковые обрезали performance); не влезает — поровну, как раньше
    qx, qw = nil, nil
    if g.name == 'quick' then
      local need = { 0, 0, 0 }
      for i, it in ipairs(g.items) do
        local k = (i - 1) % 3 + 1
        if it[1] then need[k] = math.max(need[k], ms(it[2] or '') + (it.sizer and ms(' - +') or 0) + 6) end
      end
      local total = L.ctrl_w - 2 * L.pad
      local sum = need[1] + need[2] + need[3]
      if sum <= total then
        local extra = math.floor((total - sum) / 3)
        qw = { [0] = need[1] + extra, need[2] + extra, need[3] + extra }
        qx = { [0] = 0, qw[0], qw[0] + qw[1] }
      end
    end
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
  D.ctrl_need_h = y + 4                              -- 8 окт: своя высота модуля (по содержимому), не высота верхней панели
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
  -- 8 окт: над DSP при браузере слева — правее левой колонки (браузер идёт
  -- до низа окна и закрывал вкладки и начало волны)
  local X0 = L.top_x0 or 0
  set(U.PANEL); gfx.rect(X0, 0, L.win_w - X0, H, 1)
  -- граница модуля (3 окт): наверху — линия снизу (к трекеру); mid / bottom —
  -- сверху (к трекеру или DSP и списку эффектов), снизу её даёт DSP / статус —
  -- иначе стык без линии или две линии рядом
  set(D.SEP); gfx.rect(X0, (not L.top_first) and 0 or H - 2, gfx.w - X0, D.SEPW, 1)
  if X0 > 0 then gfx.rect(X0 - 2, 0, D.SEPW, H, 1) end
  local mx, my = gfx.mouse_x, gfx.mouse_y

  if not L.ctrl_alone then draw_ctrl(L, info, H, hover) end

  -- центр: вкладки scope | sample | mod | retro | master
  local sx0 = X0 + (L.ctrl_alone and L.pad or (L.ctrl_w + L.pad))
  local sx1 = L.win_w - L.inst_w - L.pad - (L.slices_w or 0)   -- справа — модуль слайсов
  local tab = info.toptab or 'scope'
  local tx = sx0
  if tab == 'scope' then tab = 'master' end   -- вкладки scope больше нет: анализаторы в master
  for _, t in ipairs(info.tabs or { 'sample', 'automation', 'midi', 'retro', 'garden', 'master' }) do   -- garden подписан «orca», midi — learn, grid — опция (2 окт)
    local lbl = D.ic(t, (t == 'garden' and 'orca') or (t == 'sample' and 'item') or (t == 'retro' and 'rec') or (t == 'harm' and 'harmonizer') or t)
    local tw = ms(lbl) + 2 * L.pad
    local on = t == tab
    -- 6 окт: вкладки с y = 2, как кнопки главного модуля — пиксель фона под кромкой
    local hot = mx >= tx and mx < tx + tw and my >= 2 and my < 2 + L.rh
    -- rec — оттенок кнопки записи (фиолетовый, как R), остальные — янтарь
    local acc, acc_t = U.AMBER, U.tint(U.AMBER, 0.35)
    if t == 'retro' then acc, acc_t = D.ARM, D.ARM_T end
    set(on and acc_t or (hot and D.CURROW or (t == 'retro' and U.mix(U.BG, D.ARM, 0.15) or U.BG))); gfx.rect(tx, 2, tw, L.rh, 1)
    set((on or t == 'retro') and acc or U.LINE); gfx.rect(tx, 2, tw, L.rh, 0)
    text(tx + L.pad, 3, lbl, on and (t == 'retro' and U.TEXT or acc) or (t == 'retro' and D.ARM or U.GREY))
    if hot then hover.tab = t end
    hint('tab', tx, 2, tw, L.rh, t)
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
      local hot = mx >= bx and mx < bx + bw and my >= 2 and my < 2 + L.rh
      set(on and U.tint(U.CYAN, 0.3) or (hot and D.CURROW or U.BG)); gfx.rect(bx, 2, bw, L.rh, 1)
      set(on and U.CYAN or U.LINE); gfx.rect(bx, 2, bw, L.rh, 0)
      text(bx + L.pad, 3, m, on and U.CYAN or (hot and U.TEXT or U.GREY))
      if hot then hover.scopemode = m end
      hint('scopemode', bx, 2, bw, L.rh, m)
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
      text(sx0, cy0 + 1, 'no instrument - select one in the lib, or record one in the rec tab', U.GREY)
    end
  elseif tab == 'automation' then
    -- автоматизация (12 окт): params, кривая, генератор LFO, automation item
    if info.mm_draw then hover.mm = info.mm_draw(L, sx0, cy0, sx1 - sx0, H - cy0 - 2) end
  elseif tab == 'modulation' then
    -- модуляционная матрица (jf_tracker_modmatrix.lua): таблица L1 / ENV / LNK
    if info.mmx_draw then hover.mm = info.mmx_draw(L, sx0, cy0, sx1 - sx0, H - cy0 - 2) end
  elseif tab == 'grid' then
    -- monome (jf_grid): шина, владелец, мини-грид, легенда
    draw_mono(L, info, sx0, cy0, sx1 - sx0, H - 2, hover)
  elseif tab == 'video' then
    -- video (9 окт, jf_tracker_video.lua): пульт видео трека и список видео-item
    if info.video_draw then hover.video = info.video_draw(L, sx0, cy0, sx1 - sx0, H - cy0 - 2) end
  elseif tab == 'visor' then
    -- visor (10 окт, jf_tracker_visor.lua): слои шейдеров ReaVisor, эффекты, master, сцены по слотам
    if info.visor_draw then hover.visor = info.visor_draw(L, sx0, cy0, sx1 - sx0, H - cy0 - 2) end
  elseif tab == 'macros' then
    -- macros (9 окт, jf_tracker_macros.lua): записанные регистры, свои, встроенные
    if info.macros_draw then hover.macros = info.macros_draw(L, sx0, cy0, sx1 - sx0, H - cy0 - 2) end
  elseif tab == 'harm' then
    -- harmonizer (8 окт, jf_tracker_harm.lua): лад, ступени, аккорды трека
    if info.harm_draw then hover.harm = info.harm_draw(L, sx0, cy0, sx1 - sx0, H - cy0 - 2) end
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
        text(wx, y + wh + 1, fit(('sel %.2fs  drag: select · a: all · Space: play · p: put @cursor · d: to lib (=LIB) · g[ g]: edges'):format(secs), ww), U.GREY)
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
  if sort == 'type' then
    -- 9 окт: по типу — группы audio / video (заголовком), внутри — порядок пула;
    -- automation — как всегда, последней строкой
    for _, ty in ipairs({ 'audio', 'midi', 'video' }) do
      local first = true
      for i, e in ipairs(pool) do
        if not e.parent and (e.stype or 'audio') == ty then
          if first then rows[#rows + 1] = { hdr = ty, name = ty }; first = false end
          rows[#rows + 1] = { i = i }
        end
      end
    end
    return add_empty(rows, pool)
  end
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
  -- 19 окт: кнопка track (группы по трекам) убрана — это вкладка tracks (дерево трек → инструменты)
  if true then
    rows[#rows + 1] = { hdr = 'audio', name = '' }
    for i, e in ipairs(pool) do if not e.parent then rows[#rows + 1] = { i = i } end end
    return add_empty(rows, pool)
  end
  local cur_home
  for i, e in ipairs(pool) do
    if (e.depth or 0) == 0 and e.home ~= cur_home then
      cur_home = e.home
      rows[#rows + 1] = { hdr = e.home or '?', name = e.home }
    end
    if not e.parent then rows[#rows + 1] = { i = i } end    -- слайсы вложены в исходник (3 окт)
  end
  -- 9 окт: группа одна (сэмплы своего трека) — заголовок «audio», как
  -- «instruments» у плагинов ниже; несколько треков — их имена
  local nh, h1 = 0, nil
  for _, r in ipairs(rows) do if r.hdr then nh = nh + 1; h1 = r end end
  if nh == 1 then h1.hdr = 'audio' end
  return add_empty(rows, pool)
end

-- ── папки и разделители lib (10 окт) ──────────────────────────────────────
-- Только отображение (номера и items не трогаются). Папки (опция folders):
-- внутри группы трека сэмплы одной категории — kick, snare, hat … или общая
-- основа имени без цифр — от 3 штук под заголовком «/kicks 5». Разделители:
-- D.lib_seps[gkey] = узор — строка после инструмента (хранит проект, main).
D.LIB_CATS = { { 'kick', 'kicks' }, { 'bd', 'kicks' }, { 'snare', 'snares' }, { 'sd', 'snares' }, { 'rim', 'snares' },
  { 'hihat', 'hats' }, { 'hat', 'hats' }, { 'hh', 'hats' }, { 'clap', 'claps' }, { 'cp', 'claps' }, { 'perc', 'percs' },
  { 'tom', 'toms' }, { 'crash', 'cymbals' }, { 'ride', 'cymbals' }, { 'cym', 'cymbals' }, { 'shaker', 'percs' }, { 'conga', 'percs' },
  { 'bass', 'bass' }, { 'sub', 'bass' }, { '808', 'bass' }, { 'vox', 'vox' }, { 'vocal', 'vox' }, { 'chop', 'chops' },
  { 'loop', 'loops' }, { 'break', 'loops' }, { 'fx', 'fx' }, { 'sfx', 'fx' }, { 'riser', 'fx' }, { 'pad', 'pads' },
  { 'chord', 'keys' }, { 'piano', 'keys' }, { 'keys', 'keys' }, { 'synth', 'synths' }, { 'lead', 'synths' } }
function D.lib_cat(name)
  local n = (name or ''):lower()
  for _, c in ipairs(D.LIB_CATS) do
    local k = c[1]
    -- слово целиком или на границе (bop_kick11, kick hard, 808_sub)
    if n:find('%f[%w]' .. k) or n:find('_' .. k) or n:find(k .. '%d') or n:find(k .. '[%s_%-]') or n == k then return c[2] end
  end
  -- общая основа: без цифр, хвостовых разделителей и метки-префикса
  local stem = n:gsub('%.%w+$', ''):gsub('%d+', ''):gsub('[%s_%-%.]+$', ''):gsub('^[%s_%-%.]+', '')
  return stem ~= '' and stem or nil
end
local function lib_folders(rows, pool)
  local out, seg = {}, {}
  local function flush()
    local cnt, first = {}, {}
    for k, r in ipairs(seg) do
      local e = r.i and pool[r.i]
      r.cat = e and (e.libdir or D.lib_cat(e.name)) or nil   -- 27 окт: явная папка (загрузка в папку) главнее слов имени
      r.explicit = e and e.libdir and true or nil
      if r.cat then cnt[r.cat] = (cnt[r.cat] or 0) + 1; first[r.cat] = first[r.cat] or k end
    end
    local done = {}
    for k, r in ipairs(seg) do
      local c = r.cat
      if c and (cnt[c] >= 3 or r.explicit) then
        if not done[c] then
          done[c] = true
          -- 27 окт: свёрнутая (h / щелчок по заголовку) — только заголовок «>kicks 5», сэмплы скрыты (j k их пропускают)
          local folded = D.LIBF and D.LIBF[c]
          local mem = {}
          for _, r2 in ipairs(seg) do if r2.cat == c then mem[#mem + 1] = r2.i end end
          out[#out + 1] = { hdr = ((folded and '>' or '/') .. '%s  %d'):format(c, cnt[c]), folder = c, members = mem }
          for _, r2 in ipairs(seg) do
            if r2.cat == c then
              if folded then D.lib_hidden[r2.i] = true else out[#out + 1] = r2 end
            end
          end
        end
      else out[#out + 1] = r end
    end
    seg = {}
  end
  for _, r in ipairs(rows) do
    if r.i then seg[#seg + 1] = r else flush(); out[#out + 1] = r end
  end
  flush()
  return out
end
local pool_rows0 = D.pool_rows
function D.pool_rows(pool, sort, col, cols)
  local rows = pool_rows0(pool, sort, col, cols)
  D.lib_hidden = {}
  D.lib_folder_of = {}
  if D.lib_folders_on then rows = lib_folders(rows, pool) end
  for _, r in ipairs(rows) do if r.folder then for _, i in ipairs(r.members or {}) do D.lib_folder_of[i] = r.folder end end end
  -- 27 окт: остановки курсора в порядке строк на экране: сэмплы и заголовки папок (j k встают и на имя папки)
  D.lib_nav = {}
  for _, r in ipairs(rows) do
    if r.folder then D.lib_nav[#D.lib_nav + 1] = { folder = r.folder }
    elseif r.i and r.sub then D.lib_nav[#D.lib_nav + 1] = { i = r.i, kind = r.sub, k = r.k }   -- 27 окт: слайсы / слои открытой папки — тоже остановки
    elseif r.i then D.lib_nav[#D.lib_nav + 1] = { i = r.i } end
  end
  local seps = D.lib_seps
  if seps and next(seps) then
    local out = {}
    for _, r in ipairs(rows) do
      out[#out + 1] = r
      local e = r.i and pool[r.i]
      if e and seps[e.gkey] then out[#out + 1] = { sep = seps[e.gkey], key = e.gkey } end
    end
    rows = out
  end
  return rows
end
-- узоры разделителей (ASCII — битмап REAPER знает только его): единица узора
-- повторяется на ширину строки
D.SEP_ARTS = { '-', '=', '~', '.', '_.', '-=', '=-', '~=', '. ', '- ', '-- ', '.:', ':.', '*.', '+-', '/\\', '\\/', '<>', '><', '_.-*-.', '.-~-.', '-~', '~-~', '|.', '=+', ':: ', '# ', 'o.', '.o', '*', ' / ', ' \\ ' }
function D.sep_line(art, n)
  if not art or art == '' then art = '-' end
  return string.rep(art, math.ceil(n / #art)):sub(1, math.max(0, n))
end

-- пианинка (4 окт, слой пианино m): полторы октавы верхнего ряда клавиатуры —
-- белые q w e r t y u i o p (C..E), чёрные 2 3 5 6 7 9 0; на клавишах буквы,
-- держимые — янтарём, последняя сыгранная — тускло; слева октава.
-- p = { octave, held = { [смещение] = true }, last = смещение }
D.PIANO_WHITE = { { 0, 'q' }, { 2, 'w' }, { 4, 'e' }, { 5, 'r' }, { 7, 't' }, { 9, 'y' }, { 11, 'u' }, { 12, 'i' }, { 14, 'o' }, { 16, 'p' } }
D.PIANO_BLACK = { { 1, '2', 1 }, { 3, '3', 2 }, { 6, '5', 4 }, { 8, '6', 5 }, { 10, '7', 6 }, { 13, '9', 8 }, { 15, '0', 9 } }   -- [3] — после какой белой
-- 13 окт: раскладка renoise; 14 окт — две октавы целиком, узкими клавишами: нижняя — ряд z s x d …
-- (октава курсора), верхняя — q 2 w 3 … (октавой выше)
D.PIANO_RENOISE = false
function D.piano_layout(renoise)
  -- 16 окт: 'frow' — цифры белыми, F-ряд чёрными, октава [ ] (как renoise — узко)
  D.PIANO_FROW = renoise == 'frow'
  D.PIANO_RENOISE = (renoise and true or false) and not D.PIANO_FROW
  if D.PIANO_FROW then
    D.PIANO_WHITE = { { 0, '1' }, { 2, '2' }, { 4, '3' }, { 5, '4' }, { 7, '5' }, { 9, '6' }, { 11, '7' }, { 12, '8' }, { 14, '9' }, { 16, '0' }, { 17, '-' }, { 19, '=' } }
    D.PIANO_BLACK = { { 1, 'f1', 1 }, { 3, 'f2', 2 }, { 6, 'f4', 4 }, { 8, 'f5', 5 }, { 10, 'f6', 6 }, { 13, 'f8', 8 }, { 15, 'f9', 9 }, { 18, 'f11', 11 } }
  elseif renoise then
    D.PIANO_WHITE = { { 0, 'z' }, { 2, 'x' }, { 4, 'c' }, { 5, 'v' }, { 7, 'b' }, { 9, 'n' }, { 11, 'm' },
                      { 12, 'q' }, { 14, 'w' }, { 16, 'e' }, { 17, 'r' }, { 19, 't' }, { 21, 'y' }, { 23, 'u' } }
    D.PIANO_BLACK = { { 1, 's', 1 }, { 3, 'd', 2 }, { 6, 'g', 4 }, { 8, 'h', 5 }, { 10, 'j', 6 },
                      { 13, '2', 8 }, { 15, '3', 9 }, { 18, '5', 11 }, { 20, '6', 12 }, { 22, '7', 13 } }
  else
    D.PIANO_WHITE = { { 0, 'q' }, { 2, 'w' }, { 4, 'e' }, { 5, 'r' }, { 7, 't' }, { 9, 'y' }, { 11, 'u' }, { 12, 'i' }, { 14, 'o' }, { 16, 'p' } }
    D.PIANO_BLACK = { { 1, '2', 1 }, { 3, '3', 2 }, { 6, '5', 4 }, { 8, '6', 5 }, { 10, '7', 6 }, { 13, '9', 8 }, { 15, '0', 9 } }
  end
end
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
  -- 6 окт: text — два ряда кнопок словами (колонки: rev / rec, play / fwd, pause / loop)
  if c.tptext then
    -- 9 окт: кнопки как на кассетнике — сверху символ, снизу слово; [5] — символ
    return { { 'tp_rew', 'rew', nil, nil, '<<' }, { 'tp_pause', 'pause', ps & 2 == 2 and U.AMBER or nil, nil, '||' },
             { 'tp_play', playing and 'stop' or 'play', playing and U.GREEN or nil, nil, playing and '[]' or '>' },
             { 'loop', 'loop', c.loop and U.CYAN or nil, nil, (D.ttf or D.hybrid) and '∞' or 'oo' },   -- 19 окт: loop — рядом с play, ff — крайний справа
             { 'rec', 'rec', c.recording and D.REC or nil, D.REC, 'O' }, { 'tp_fwd', 'ff', nil, nil, '>>' } }
  end
  if not c.tpbuttons then
    return { { 'rec', 'rec', c.recording and U.RED or nil, U.RED }, { 'loop', D.ttf and '∞' or 'loop', c.loop and U.CYAN or nil } }
  end
  return { { 'tp_rew', '<<' }, { 'tp_play', '>', playing and U.GREEN or nil },
           { 'tp_pause', '||', ps & 2 == 2 and U.AMBER or nil }, { 'rec', 'O', c.recording and D.REC or nil, D.REC },
           { 'tp_fwd', '>>' }, { 'loop', D.ttf and '∞' or 'loop', c.loop and U.CYAN or nil } }
end
-- 11 окт: вторая строка full-транспорта, по колонкам кнопок: rew | pause | play | rec | ff | loop
D.RATE_SNAPS = { 0.25, 0.5, 0.75, 1, 1.5, 2 }
function D.transport_sub(c)
  -- 15 окт: слов нет — символы: * freeze (*N — заморожено N), ^O^ shift rec (^ — шифт, O — как rec), ++ dub; слова — в статусе
  local frz = c.frz and ('**%s'):format(c.frz) or '**'   -- 19 окт: ** — freeze-луп (было *)
  -- 11 окт: под play — slow (белая: игра /2), под rec — smart (запись по нажатию, обсуждается)
  -- 19 окт: под || — |> (стоп на месте, как Esc), под loop — ** freeze; dub убран
  return { { 'tp_start', '|<<' }, { 'stophere', '|>', nil },
           { 'slowplay', 'x0.5', halves = {   -- 12 окт: две половины — x0.5 и x2; включённая мигает
             { 'slowplay', '/2', (c.halfplay == 0.5 and reaper and reaper.time_precise and math.floor(reaper.time_precise() * 2) % 2 == 0) and U.TEXT or nil },
             { 'fastplay', 'x2', (c.halfplay == 2 and reaper and reaper.time_precise and math.floor(reaper.time_precise() * 2) % 2 == 0) and U.TEXT or nil } } },
           { 'freeze', frz, c.frz and U.CYAN or nil },
           { 'shiftrec', '^O^', (c.shiftrec == 'rec' or (c.shiftrec == 'wait' and reaper and reaper.time_precise and math.floor(reaper.time_precise() * 2) % 2 == 0)) and U.RED or nil },   -- 12 окт: shift rec (была smart); ждёт ноту — мигает
           { 'tp_end', '>>|' } }
end
function D.transport_groups(c, L)   -- 15 окт: L — для ширины вертикальной подписи step
  local sig = (c.sig_num and c.sig_den) and ('%d/%d'):format(c.sig_num, c.sig_den) or '4/4'
  local num = math.max(1, math.min(16, c.sig_num or 4))
  local cur = c.beat and (math.floor(c.beat) + 1) or 0
  local function tg(id, label, on) return { id, label .. ' ' .. (on and 'on' or 'off'), on and U.CYAN or U.GREY } end
  local g = {}
  if not (c.bigbpm or c.tpfull) then
    g[#g + 1] = { { { 'play', '> ' .. (c.pos or ''), c.playing and U.GREEN or U.TEXT } },   -- > — намёк: клик играет (5 окт)
                  { { 'bpm', c.bpm_edit and ('BPM [%s]'):format(c.bpm_edit ~= '' and c.bpm_edit or '...') or ('BPM %.1f'):format(c.bpm or 0), c.bpm_edit and U.AMBER or U.TEXT } } }
  end
  -- 11 окт: скорость проекта — своей группой: x1.00 (щелчок — список, колесо ±0.05) и слайдер с точками-защёлками
  g[#g + 1] = { { { 'rate', ('rate x%.2f'):format(c.rate or 1), math.abs((c.rate or 1) - 1) > 1e-3 and U.AMBER or U.GREY } },
                { { 'ratebar', '', nil, slider = { rate = c.rate or 1 } } } }
  -- metro — рядом с долями (визуальный метроном), в свободном месте строки LPB (5 окт)
  -- 9 окт: LPB — к step / inst (настройки ввода); swing — самым правым блоком со слайдером
  g[#g + 1] = { { { 'sig', 'sig ' .. sig }, tg('metro', 'metro', c.metro) },
                { { 'beats', ('bar %d beat %d/%d'):format(c.bar or 1, math.max(1, cur), num), U.TEXT, beats = { num = num, cur = cur } } } }
  local lsn = { { 'ls_ins', 'insert', c.hear and U.AMBER or U.GREY }, { 'ls_step', 'step', c.trklisten and U.AMBER or U.GREY }, { 'ls_sel', 'sel', c.sellisten and U.AMBER or U.GREY }, { 'ls_line', 'line', c.steplisten and U.AMBER or U.GREY } }   -- включённые — янтарём (ярче голубого)
  -- 15 окт: шаг — крупно (×2, как BPM), без слова step (оно — вертикальной скобкой); inst ввода не показываем
  -- 15 окт: сетка блока — крупный шаг слева (ширина по значению, не уже «16» — соседи не прыгают от цифры
  -- к цифре), справа две ровные колонки: LPB / pitch и legato / human (общая ширина колонки — res)
  local stxt = ({ auto = 'a', next = 'n' })[c.step] or tostring(c.step or 0)   -- 15 окт: режимы шага буквой — ширина как у числа
  local stepw = math.max(D.big_measure(stxt, 2), D.big_measure('16', 2)) + L.th + L.pad   -- + вертикальная подпись step (15 окт)
  local col2, col3 = 'pitch resample', 'human 100%'
  -- 16 окт: подпись step — на две строки, как oct (цифра выше)
  g[#g + 1] = { boxed = true,   -- 15 окт: без вертикальной скобки — подпись step под цифрой
                { { 'step', stxt, big = true, res = (#stxt <= 2) and '16' or nil, vlab = 'step', vlab_rows = 2 }, { 'lpb', ('LPB %d'):format(c.lpb or 0), res = col2 },
                  { 'holdroll', c.holdroll and 'roll' or 'hold', c.holdroll and U.CYAN or U.GREY, res = 'hold' },   -- 28 окт: Opt+`
                  { 'legato', 'legato', c.legato and U.CYAN or U.GREY, res = col3 } },
                { { '_', '', w = stepw }, { 'pitch', 'pitch ' .. (c.pitchmode or 'shift'), res = col2 }, { '_', '', res = 'hold' },
                  { 'human', (c.human or 0) > 0 and ('human %d%%'):format(c.human) or 'human', (c.human or 0) > 0 and U.CYAN or U.GREY, res = col3 } } }   -- 15 окт: human — тайминг, высота, velocity
  -- 12 окт: listen — что звучит при правке: insert (вставленное), step (строка курсора, его трек), sel (выделение), line (строка, все треки).
  -- Полный транспорт: третьей строкой под step / vel (подпись listen — под клавиатурой), иначе своей группой
  -- 15 окт: третья строка — подпись step под цифрой; четвёртая — listen и что слушать (два «step» не рядом)
  if c.tpfull then
    -- 15 окт: listen — третьей строкой, под цифрой (слева — вертикальная подпись step на весь блок)
    -- 16 окт: как oct / vel — listen под цифрой шага (с начала блока), insert step sel line — под колонкой LPB / pitch
    local row4 = { { '_listen', 'listen', U.GREY } }   -- подпись строки, не кнопка
    local pad4 = stepw - ms('listen') - (2 * L.pad + 6)
    if pad4 > 0 then row4[#row4 + 1] = { '_', '', w = pad4 } end
    for _, it in ipairs(lsn) do row4[#row4 + 1] = it end
    table.insert(g[#g], row4)
  else g[#g + 1] = { boxed = true, { { 'listen', 'listen', U.GREY } }, lsn } end
  -- запись (5 окт): рядом с метрономом
  -- транспорт и запись (5 окт): кнопки [<<][>][II][o][>>], под ними метроном,
  -- punch, pre-roll, rec>lib
  -- кнопки [<<][>][II][o][>>] — крупно справа от модуса (D.transport_buttons)
  -- 11 окт: тоглы записи — без on / off (цвет: голубой — вкл), иначе блок не влезал рядом с x1.00
  local function tc(id, label, on) return { id, label, on and U.CYAN or U.GREY } end
  -- 16 окт: ripple — выпадашка (off / per track / all), голубой — вкл
  local rip = { 'ripple', ({ [0] = 'ripple', 'ripple trk', 'ripple all' })[c.ripple or 0], (c.ripple or 0) > 0 and U.CYAN or U.GREY, res = 'ripple all' }
  g[#g + 1] = { { tc('punch', 'punch', c.punch), tc('preroll', 'pre-roll', c.preroll), rip },
                { tc('reclib', 'rec>lib', c.reclib),
                  { 'slow', c.slowrate and ('slow %s'):format(({ [0.5] = '1/2', [0.25] = '1/4' })[c.slowrate] or (math.abs(c.slowrate - 2 / 3) < 1e-3 and '2/3') or '1/3') or 'slow',
                    c.slowrec and U.RED or (c.slowrate and U.CYAN or U.GREY) } } }   -- 11 окт: slow rec (Shift+Space)
  g[#g + 1] = { { tg('follow', 'follow', c.follow) },
                { tg('lock', 'lock', c.lock), tg('fixed', 'fixed', c.fixed),
                  { 'xfade', c.xfade and ('auto x-fade %dms'):format(c.xfade_ms or 10) or 'auto x-fade off', c.xfade and U.CYAN or U.GREY } } }
  g[#g + 1] = { { { 'swing', c.swing_on and (c.swing_txt or 'swing') or 'swing', c.swing_on and U.CYAN or U.GREY } },   -- 15 окт: выкл — просто «swing» серым
                { { 'swingbar', '', nil, slider = { v = c.swing_amt or 0 } } } }
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
  legato = { { 'click', 'toggle' }, { ':legato fill', 'the track' } },
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
      local kc, dc = D.hint_colors(U.PANEL)
      text(cx, y + 1, it[1], kc)
      text(cx + kw + sp, y + 1, it[2], dc)
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
  if L.tppos ~= 'tracker' then set(D.SEP); gfx.rect(x, y, w, 1, 1) end   -- 16 окт: под трекером линию даёт его низ — была двойная
  local ly = y + 3
  local x_all, w_all = x, w
  -- 16 окт: модлайна нет — слово режима снова в полосе, слева (ширина постоянная: по самому широкому
  -- из NORMAL / INSERT / VISUAL, длиннее — обрезается); остальное правее
  if info and info.status_left then
    local res = 0
    for _, mw0 in ipairs({ 'NORMAL', 'INSERT', 'VISUAL', 'KEYS' }) do res = math.max(res, (D.draw_mode(L, 0, 0, 1e6, mw0, true))) end
    D.draw_mode(L, x + L.pad, ly + math.floor((math.min(h, 3 * L.rh) - 2 * L.th) / 2) - 2, 3 * res, info.status_left)
    x = x + res + 3 * L.pad; w = w - res - 3 * L.pad
  end
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
    local zx = (D.PIANO_RENOISE or D.PIANO_FROW) and '[- ]+' or 'z- x+'   -- 14 окт: в renoise z x — ноты, октава — [ ]
    local lw = math.max(ms(lbl), ms(zx)) + 2 * L.pad
    if cc.tpfull then
      -- 15 окт: oct — подпись вертикально, цифра крупно (×2) на две строки; клавиши — строкой под vel
      local ds = tostring(p.octave or 4)
      lw = L.th + L.pad + math.max(D.big_measure(ds, 2), D.big_measure('9', 2)) + 2 * L.pad
      D.vtext(x + L.pad, ly, 2 * L.rh, 'oct', U.GREY, U.PANEL)
      D.big_text(x + L.pad + L.th + L.pad, ly, ds, U.readable(dim and U.GREY or U.AMBER, U.PANEL, 4.5), 2)   -- 20 окт: читаемо и на светлых темах
    else
      text(x + L.pad, ly, lbl, dim and U.GREY or U.AMBER)
      text(x + L.pad, ly + L.rh, zx, U.GREY)
    end
    local kx = x + lw
    -- 12 окт: velocity — под клавиатурой, третьей строкой (c - тише, C - громче, как z x для октавы)
    if cc.tpfull then
      local vy = ly + 2 * L.rh + 2 - (L.tp_cut or 0)
      -- 15 окт: vel — строкой «vel 111» (как было), справа слайдер 1..127 (тянуть)
      local vl = ('vel %d'):format(cc.vel or 100)
      local vw = math.max(ms(vl), ms('vel 127'))
      local vhot = mx >= x + L.pad - 2 and mx < x + L.pad + vw + 2 and my >= vy and my < vy + L.rh
      if vhot then set(D.CURROW); gfx.rect(x + L.pad - 2, vy, vw + 4, L.rh, 1); hover.ctrl = 'vel' end
      text(x + L.pad, vy, vl, vhot and U.AMBER or (dim and U.GREY or U.AMBER))
      hint('ctrl', x + L.pad, vy, vw, L.rh, 'vel')
      D.strip_cell.vel = { x + L.pad, vy, vw }
      local bx = x + L.pad + vw + L.pad + 2
      -- 15 окт: короче — правый конец у настоящего края клавиатуры (та же ширина клавиши, что ниже), не залезает на step
      local kwv = math.floor(math.min(((D.PIANO_SMALL or D.PIANO_RENOISE) and 0 or ms('W')) + ms('W') + 4, (w - lw - L.pad) / (#D.PIANO_WHITE + 12)))
      -- 19 окт: слайдер + $pt + pedal — в ширину клавиатуры (слайдер масштабируется), дальше не лезут (там row / col)
      local kr = kx + #D.PIANO_WHITE * kwv - 1
      local tail = (ms('$pt') + 2 * L.pad) + 2 + (ms('ped') + 2 * L.pad) + L.pad   -- 19 окт: ped — короче, vel длиннее
      local bw = math.max(L.cw * 2, kr - bx - tail)
      local bhot = mx >= bx - 2 and mx < bx + bw + 2 and my >= vy and my < vy + L.rh
      U.dslider(bx, vy + math.floor(L.rh / 2), bw, ((cc.vel or 100) - 1) / 126, false, (bhot or vhot) and U.AMBER or U.TEXT, bhot, L.rh)
      if bhot then hover.ctrl = 'velbar' end
      hint('ctrl', bx, vy, bw, L.rh, 'velbar')
      D.strip_cell.velbar = { bx, vy, bw }
      -- 16 окт: $pitch — клавиши играют выбранный слайс по высоте (тогл, справа от громкости)
      do
        local pl = '$pt'   -- 19 окт: короче (было $pitch)
        local pw2 = ms(pl) + 2 * L.pad
        local px2 = bx + bw + L.pad
        if px2 + pw2 <= math.max(kr, x + L.pad) + 1 then
          local on = cc.slicepitch
          local ph = mx >= px2 and mx < px2 + pw2 and my >= vy and my < vy + L.rh
          set(on and U.tint(U.CYAN, 0.3) or (ph and U.tint(U.AMBER, 0.3) or U.BG)); gfx.rect(px2, vy, pw2, L.rh - 1, 1)
          set(on and U.CYAN or (ph and U.AMBER or U.LINE)); gfx.rect(px2, vy, pw2, L.rh - 1, 0)
          text(px2 + L.pad, vy, pl, on and U.CYAN or (ph and U.AMBER or U.GREY))
          if ph then hover.ctrl = 'slicepitch' end
          hint('ctrl', px2, vy, pw2, L.rh, 'slicepitch')
          -- 16 окт: pedal — сустейн (CC64), горит, когда нажат (и педалью MIDI-клавиатуры)
          local dl = 'ped'
          local dw2 = ms(dl) + 2 * L.pad
          local dx2 = px2 + pw2 + 2
          if dx2 + dw2 <= kr + 1 then
            local don = info and info.wheels and info.wheels().pedal
            local dh = mx >= dx2 and mx < dx2 + dw2 and my >= vy and my < vy + L.rh
            set(don and U.tint(U.GREEN, 0.35) or (dh and U.tint(U.AMBER, 0.3) or U.BG)); gfx.rect(dx2, vy, dw2, L.rh - 1, 1)
            set(don and U.GREEN or (dh and U.AMBER or U.LINE)); gfx.rect(dx2, vy, dw2, L.rh - 1, 0)
            text(dx2 + L.pad, vy, dl, don and U.GREEN or (dh and U.AMBER or U.GREY))
            if dh then hover.ctrl = 'pedal' end
            hint('ctrl', dx2, vy, dw2, L.rh, 'pedal')
          end
        end
      end
      -- 15 окт: строки клавиш oct / vel нет — при наведении они в статусе (vel крупно занял две строки)
    end
    -- 8 окт: клавиша на символ шире буквы (так читалось); опция small piano —
    -- впритык к букве (для крупного битмапа x2 и узких окон)
    local kw0 = ((D.PIANO_SMALL or D.PIANO_RENOISE) and 0 or ms('W')) + ms('W') + 4   -- 14 окт: renoise — 2 октавы, узко
    local kw = math.floor(math.min(kw0, (w - lw - L.pad) / (#D.PIANO_WHITE + 12)))
    if kw >= 4 then
      local ky, kh = y + 2, 2 * L.rh + 3
      local letters = kw >= ms('W') + 4
      local held, last = p.held or {}, p.last
      -- 16 окт: колёса — pitch и mod вертикальными фейдерами с ромбиком слева от клавиш: показывают вход
      -- MIDI-клавиатуры, тянутся мышью (значение — в виртуальную клавиатуру; pitch отпустил — в центр)
      if info and info.wheels then
        local wv = info.wheels()
        local fw = math.max(6, math.floor(L.cw * 0.9))
        for i, wd in ipairs({ { 'pb', (wv.bend or 0) * 0.5 + 0.5, 'pitch' }, { 'mod', wv.mod or 0, 'mod' } }) do
          local fx0 = kx + (i - 1) * (fw + L.pad)
          local hot = mx >= fx0 - 1 and mx < fx0 + fw + 1 and my >= ky and my < ky + kh
          set(U.mix(U.BG, { 0, 0, 0 }, 0.5)); gfx.rect(fx0, ky, fw, kh, 1)
          set(hot and U.AMBER or U.LINE); gfx.rect(fx0, ky, fw, kh, 0)
          if wd[1] == 'pb' then set(U.DIM); gfx.rect(fx0 + 1, ky + math.floor(kh / 2), fw - 2, 1, 1) end
          local dy = ky + 2 + math.floor((1 - wd[2]) * (kh - 5) + 0.5)
          local dr = math.max(2, math.floor(fw / 2))
          set(hot and U.AMBER or U.TEXT)
          local cxw = fx0 + math.floor(fw / 2)
          for t = 0, dr do gfx.line(cxw - (dr - t), dy - t, cxw + (dr - t), dy - t); gfx.line(cxw - (dr - t), dy + t, cxw + (dr - t), dy + t) end
          if hot then hover.ctrl = 'wheel_' .. wd[1]; hover.wheel = { what = wd[1], y0 = ky, h = kh } end
          hint('ctrl', fx0, ky, fw, kh, 'wheel_' .. wd[1])
        end
        kx = kx + 2 * (fw + L.pad) + L.pad
      end
      local white_c = U.mix(U.BG, U.TEXT, dim and 0.22 or 0.85)   -- 15 окт: выкл — ещё тусклее (было 0.35)
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
          text(bx + math.floor((kw - 1 - ms(lb)) / 2), ky + kh - L.rh, lb, U.readable(U.BG, kf, dim and 2.0 or 4.5), kf)
          out.letters = out.letters + 1
        end
      end
      local bw, bh = math.max(3, math.min(kw - 2, math.max(ms('W') + 2, math.floor(kw * 0.6)))), math.floor(kh * 0.6)   -- 8 окт: цифра на чёрной видна и в минимальной
      if D.PIANO_FROW then bh = math.max(bh, kh - L.rh - 1) end   -- 16 окт: frow — чёрная до строки подписей белых: f и номер столбиком
      for _, k in ipairs(D.PIANO_BLACK) do
        local bx = kx + k[3] * kw - math.floor(bw / 2) - 1
        local fill = key_fill(k[1], U.PANEL)
        set(fill); gfx.rect(bx, ky, bw, bh, 1)
        set(U.LINE); gfx.rect(bx, ky, bw, bh, 0)
        out.black = out.black + 1
        local blb = k[2]
        local fl = D.PIANO_FROW and blb:match('^f(%d+)$')
        if fl and letters then
          -- 16 окт: f-клавиша — «f» сверху, номер под ним, своим мелким шрифтом (влезает в узкую чёрную)
          local px = math.max(7, math.min(math.floor((bh - 2) / 2), math.floor(bw * 0.9)))
          if D.fkey_px ~= px then gfx.setfont(7, 'Menlo', px, string.byte('b')); D.fkey_px = px else gfx.setfont(7) end
          local tc = U.readable(U.TEXT, fill, 7)                     -- 16 окт: ярко всегда (и у блёклой клавиатуры)
          set(tc)
          local fw = gfx.measurestr('f')
          gfx.x, gfx.y = bx + math.floor((bw - fw) / 2), ky + 1; gfx.drawstr('f')
          local nw = gfx.measurestr(fl)
          if nw > bw - 1 then nw = gfx.measurestr(fl:sub(-1)); fl = fl:sub(-1) end
          gfx.x, gfx.y = bx + math.floor((bw - nw) / 2), ky + 1 + px; gfx.drawstr(fl)
          gfx.setfont(D.font_id)
          out.letters = out.letters + 1
          blb = nil
        elseif ms(blb) > bw - 2 and #blb > 1 then blb = blb:sub(2) end          -- 16 окт: f11 не влезло — 11
        if blb and letters and bw >= ms(blb) + 2 then
          text(bx + math.floor((bw - ms(blb)) / 2), ky + 1, blb, dim and U.mix(fill, U.TEXT, 0.4) or U.readable(U.TEXT, fill, 4.5))
          out.letters = out.letters + 1
        end
      end
      -- 15 окт: нота играет — клавиатура вспыхивает (рамка и лёгкая заливка янтарём)
      if p.glow then
        local gw = #D.PIANO_WHITE * kw
        set(U.AMBER, 0.12); gfx.rect(kx - 2, ky - 2, gw + 3, kh + 4, 1); gfx.a = 1
        set(U.AMBER); gfx.rect(kx - 2, ky - 2, gw + 3, kh + 4, 0)
      end
      tx = kx + #D.PIANO_WHITE * kw + 2 * L.pad
      local nk = D.PIANO_FROW and '1 f1 2' or (D.PIANO_RENOISE and 'zsx q2w' or 'q2w3e')
      local ok2 = (D.PIANO_RENOISE or D.PIANO_FROW) and '[ ]' or 'z x'
      D.strip_cols[#D.strip_cols + 1] = { x + L.pad, tx - L.pad, (p.ins and { { nk, 'notes' }, { ok2, 'oct' } }) or { { ok2, 'oct' }, { 'm', 'keys' } } }
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
  -- 12 окт: it.res — самая длинная подпись этой ячейки (step 1 → step auto): место заранее, соседи не прыгают
  -- 15 окт: it.big — крупно (×2, как BPM) на две строки; it.w — пустое место заданной ширины
  local function cw_of(it)
    if it.big then return math.max(D.big_measure(it[2], 2), it.res and D.big_measure(it.res, 2) or 0) + (it.vlab and (L.th + L.pad) or 0) end   -- 15 окт: vlab — подпись вертикально слева
    if it.w then return it.w end
    return math.max(ms(it[2]), it.res and ms(it.res) or 0) + (it.beats and (math.max(it.beats.num, it.bres or 0) * (math.max(4, L.rh - 6) + 2) + L.pad) or 0) + (it.slider and (8 * L.cw) or 0) end
  -- 12 окт: boxed — ячейки в рамках, промежуток шире (step / inst / LPB / vel / pitch / listen)
  local function gap_of(g) return g.boxed and (gap + 6) or gap end
  -- 12 окт: bracket — группа в квадратных скобках, слева её имя вертикально (step)
  local function br_l(g) return g.bracket and (L.th + 8) or 0 end
  local function group_w(g)
    local gw = br_l(g)
    local gp = gap_of(g)
    for _, row in ipairs(g) do
      local rw = 0
      for k, it in ipairs(row) do rw = rw + cw_of(it) + (k > 1 and gp or 0) end
      gw = math.max(gw, rw)
    end
    return gw
  end
  local function draw_group(g, gx, gw, y0)
    local gap = gap_of(g)
    if g.bracket then
      local by0, bh = (y0 or ly) - 1, #g * L.rh + 1
      local tl = math.min(ms(g.bracket), bh)
      D.vtext(gx, by0 + math.floor((bh - tl) / 2), tl, g.bracket, U.GREY, U.PANEL)
      -- 12 окт: без рамок и скобок (в Big Blue наезжали) — только буквы
      gx = gx + br_l(g)
    end
    for ri, row in ipairs(g) do
      local cx, cy = gx, (y0 or ly) + (ri - 1) * L.rh - ((ri >= 3 and not y0) and (L.tp_cut or 0) or 0)   -- 15 окт: строки 3-4 — выше (tp_cut)
      for _, it in ipairs(row) do
        local iw = cw_of(it)
        local ih = it.big and (2 * L.rh) or L.rh
        local hot = it[1]:sub(1, 1) ~= '_' and cell_hot(cx, cy, iw, ih)
        local kbd = info.focus == 'ctrl' and info.ctrl_sel == it[1]   -- 25 окт: курсор клавиатуры виден и в полосе транспорта
        if kbd then set(U.tint(U.AMBER, 0.35)); gfx.rect(cx - 2, cy, iw + 4, ih, 1) end
        if it[1]:sub(1, 1) ~= '_' then D.ctrl_rect = D.ctrl_rect or {}; D.ctrl_rect[it[1]] = { cx, cy + ih - L.rh, iw, L.rh } end
        if hot then set(D.CURROW); gfx.rect(cx - 2, cy, iw + 4, ih, 1); hover.ctrl = it[1] end
        if it.big and it.vlab then
          -- 16 окт: подпись длиннее двух строк (step) — выше, в верхний отступ полосы (до 3 px), не в строку listen
          local vh = (it.vlab_rows or 2) * L.rh
          local up = math.max(0, math.min(3, ms(it.vlab) - vh))
          D.vtext(cx, cy - up, vh + up + 2, it.vlab, U.GREY, U.PANEL)   -- +2 — зазор до строки listen
          -- 19 окт: step сменился — цифра вспыхивает крупнее (×4 → ×2 за полсекунды), янтарём
          local fl = it[1] == 'step' and D.step_flash and reaper.time_precise() - D.step_flash
          if fl and fl < 0.5 and D.stepflash_on then
            local k = fl < 0.17 and 4 or (fl < 0.34 and 3 or 2)
            local bx2, by2 = cx + L.th + L.pad, cy - (k - 2) * math.floor(L.rh / 2)
            set(U.PANEL); gfx.rect(bx2 - 2, by2 - 2, D.big_measure(it[2], k) + 4, k * L.rh + 4, 1)
            D.big_text(bx2, by2, it[2], U.AMBER, k)
          else
            D.big_text(cx + L.th + L.pad, cy, it[2], hot and U.AMBER or (it[3] or U.TEXT), 2)
          end
        elseif it.big then D.big_text(cx, cy, it[2], hot and U.AMBER or (it[3] or U.TEXT), 2)
        elseif it[1] ~= '_' then text(cx, cy + 1, it[2], hot and U.AMBER or (it[3] or U.TEXT)) end
        if it.beats then
          local bs = math.max(4, L.rh - 6)
          local bx = cx + ms(it[2]) + L.pad
          for k = 1, (it.bres and math.min(it.beats.num, it.bres) or it.beats.num) do   -- 25 окт: не шире зарезервированного
            set(k == it.beats.cur and U.AMBER or U.DIM)
            gfx.rect(bx + (k - 1) * (bs + 2), cy + math.floor((L.rh - bs) / 2), bs, bs, k == it.beats.cur and 1 or 0)
          end
        end
        if it.slider and it.slider.rate then
          -- 11 окт: слайдер скорости 0.25..2, точки-защёлки на 0.25 0.5 0.75 1 1.5 2
          local sw2 = 8 * L.cw
          local yy = cy + math.floor(L.rh / 2)
          set(U.DIM); gfx.rect(cx, yy - 1, sw2, 2, 1)
          for _, m in ipairs(D.RATE_SNAPS) do
            local mx2 = cx + math.floor((m - 0.25) / 1.75 * (sw2 - 1) + 0.5)
            set(m == 1 and U.GREY or U.DIM); gfx.rect(mx2, cy + 3, 1, L.rh - 6, 1)
          end
          local r = math.max(0.25, math.min(2, it.slider.rate))
          local px = cx + math.floor((r - 0.25) / 1.75 * (sw2 - 1) + 0.5)
          U.diamond(px, yy, math.max(3, math.floor((L.rh - 6) / 2)), (hot or math.abs(r - 1) > 1e-3) and U.AMBER or U.TEXT, hot)   -- 13 окт: ромбик
        elseif it.slider then                                 -- 9 окт: слайдер свинга −100..100 %, от центра
          local sw2 = 8 * L.cw
          local mid = cx + math.floor(sw2 / 2)
          local yy = cy + math.floor(L.rh / 2)
          set(U.DIM); gfx.rect(cx, yy - 1, sw2, 2, 1)
          set(U.GREY); gfx.rect(mid, cy + 3, 1, L.rh - 6, 1)
          local v = math.max(-1, math.min(1, it.slider.v or 0))
          local px = mid + math.floor(v * (sw2 / 2 - 1) + 0.5)
          local sc = hot and U.AMBER or (math.abs(v) > 1e-6 and U.CYAN or U.TEXT)
          set(sc, 0.6); gfx.rect(math.min(mid, px), yy - 1, math.max(1, math.abs(px - mid)), 3, 1)
          U.diamond(px, yy, math.max(3, math.floor((L.rh - 6) / 2)), sc, hot)   -- 13 окт: ромбик
        end
        hint('ctrl', cx, cy, iw, L.rh, it[1])
        D.strip_cell[it[1]] = { cx, cy, iw }          -- всплывашка у своей ячейки (:sig, 5 окт)
        cx = cx + iw + gap
        -- 12 окт: тонкая черта между ячейками группы — бледнее разделителя групп
        if row[_ + 1] and not g.boxed then set(U.mix(U.LINE, U.PANEL, 0.75)); gfx.rect(cx - math.floor(gap / 2) - 1, cy + 3, 1, L.rh - 6, 1) end
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
  for i, b in ipairs(blist) do local kk = (b[1] == 'rec' and bk == 2 and not D.ttf and (D.SCALE * BK) % 1 ~= 0) and 2 or BK; b.k = kk; tws[i] = bk == 2 and D.big_measure(b[2], kk) or ms(b[2]); bws[i] = tws[i] + 2 * L.pad + (b[1] == 'rec' and 3 * L.pad or 0); btot = btot + bws[i] + (i > 1 and 2 or 0) end
  -- text (9 окт): одна строка кнопок высотой в две строки — символ сверху по
  -- центру, слово снизу; ширина у всех одна (по самому длинному слову)
  local tbw
  local TW = {}   -- 19 окт: ширина каждой колонки транспорта
  if c.tptext then
    tbw = 0
    for _, b in ipairs(blist) do tbw = math.max(tbw, ms(b[5] or b[2])) end   -- 15 окт: слов нет — ширина по символу и нижнему ряду
    if c.tpfull then for _, b in ipairs(D.transport_sub(c)) do if b[1] then tbw = math.max(tbw, ms(b[2])) end end end   -- 11 окт: и нижняя строка
    tbw = tbw + 2 * L.pad
    -- 15 окт: кнопки узкие (символы) — колонка не уже третьей строки: маркеры (10 на 2 колонки), rate, punch pre lib slow на 3
    if c.tpfull then
      local rec = ms('punch') + ms('pre') + ms('lib') + ms('slow*') + ms('rip*') + 10 * L.pad   -- 16 окт: + ripple
      -- 16 окт: маркеры — одна кнопка markers (выпадашка с номерами), запись — на 4 колонки: кнопки уже
      tbw = math.max(tbw, ms('mark') + 2 * L.pad, ms('x1.10') + 2 * L.pad, math.ceil((rec - 6) / 4))
    end
    -- 19 окт: колонки — по своему содержимому (верх + низ), play — широкая (прежняя общая ширина);
    -- третья строка: mark над rew, rate над pause, тоглы записи — от play до конца (не влезли — play шире)
    local wide = tbw
    local sub0 = c.tpfull and D.transport_sub(c) or {}
    local pi
    for i, b in ipairs(blist) do
      local w2 = ms(b[5] or b[2])
      local sb = sub0[i]
      if sb and sb.halves then w2 = math.max(w2, ms('/2') + ms('x2') + 2 * L.pad + 4) elseif sb and sb[1] then w2 = math.max(w2, ms(sb[1] == 'tp_start' and '<<' or sb[2])) end   -- 21 окт: |<< — черта торчит влево, ширину по <<
      TW[i] = w2 + 2 * L.pad
      if b[1] == 'tp_play' then pi = i end
    end
    local need = 0
    if c.tpfull then   -- 19 окт: mark под <<, rate под play, тоглы записи — правее play
      TW[1] = math.max(TW[1], ms('mark') + L.pad)   -- 21 окт: на символ уже (подпись mark — без полного отступа)
      if pi then TW[pi] = math.max(TW[pi], ms('x1.10') + 2 * L.pad) end
      need = ms('pun') + ms('pre') + ms('slo*') + ms('rip*') + 8 * L.pad
      local pre = -2
      for i = 1, (pi or 2) do pre = pre + TW[i] + 2 end
      need = pre + 2 + need
    end
    D.tp_play_i = pi
    local _ = wide   -- 19 окт: play — только по своему содержимому (/2 x2 под ним), без растяжки под строку тоглов
    btot = -2
    for i = 1, #blist do btot = btot + TW[i] + 2 end
    -- строка тоглов записи (от колонки 3) длиннее кнопок — группа шире на неё, кнопки остаются узкими
    if need > 0 then btot = math.max(btot, need) end   -- тоглы записи длиннее колонок справа от play — группа шире
  end
  local function draw_text_buttons(bx0)
    local bx = bx0
    local by, bh = ly, L.rh   -- 15 окт: одна строка — только символ
    -- 12 окт: срезанный угол — только у крайних кнопок блока (фон в угол, рамка по диагонали, 2 px)
    local function cut(cx, cy, dx, dy, frame)
      set(U.PANEL); gfx.rect(cx, cy, 1, 1, 1); gfx.rect(cx + dx, cy, 1, 1, 1); gfx.rect(cx, cy + dy, 1, 1, 1)
      set(frame); gfx.rect(cx + dx, cy + dy, 1, 1, 1)
    end
    local sub_on = c.tpfull
    for bi, b in ipairs(blist) do
      local bw = TW[bi] or tbw
      local hot = mx >= bx and mx < bx + bw and my >= by and my < by + bh
      local on = b[3] ~= nil
      local tc = hot and U.AMBER or (b[4] or b[3] or U.TEXT)
      set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(b[3], 0.3) or U.BG)); gfx.rect(bx, by, bw, bh, 1)
      local fr = hot and U.AMBER or (on and b[3] or U.LINE)
      set(fr); gfx.rect(bx, by, bw, bh, 0)
      if bi == 1 then cut(bx, by, 1, 1, fr); if not sub_on then cut(bx, by + bh - 1, 1, -1, fr) end end
      if bi == #blist then cut(bx + bw - 1, by, -1, 1, fr); if not sub_on then cut(bx + bw - 1, by + bh - 1, -1, -1, fr) end end
      local sym = b[5] or ''
      if b[1] == 'loop' and (D.ttf or D.hybrid) then
        -- 16 окт: ∞ лупа — крупнее строки (свой шрифт, слот 6; создаётся раз на размер), по центру кнопки
        local px = math.max(10, math.floor(bh * 1.25))
        if D.inf_px ~= px then gfx.setfont(6, 'Helvetica', px); D.inf_px = px else gfx.setfont(6) end
        local gw, gh = gfx.measurestr('∞'), gfx.texth
        set(tc); gfx.x, gfx.y = bx + math.floor((bw - gw) / 2), by + math.floor((bh - gh) / 2) + 1
        gfx.drawstr('∞')
        gfx.setfont(D.font_id)
      else
      -- 9 окт: символ — на 2 px ниже рамки, слово — на 1 px выше нижней (не заходят на границу)
      text(bx + math.floor((bw - ms(sym ~= '' and sym or b[2])) / 2), by, sym ~= '' and sym or b[2], tc)   -- 15 окт: слов (rew, play …) нет — при наведении они в статусе
      end
      if hot then hover.ctrl = b[1] end
      hint('ctrl', bx, by, bw, bh, b[1])
      bx = bx + bw + 2
    end
    -- 11 окт: full — строка кнопок под транспортом (|<< freeze · slow >>| dub), колонка в колонку
    if c.tpfull then
      local sub = D.transport_sub(c)
      local sx, sy = bx0, by + bh + 2
      for si, b in ipairs(sub) do
        local tw = TW[si] or tbw   -- 19 окт: своя ширина колонки
        if b.halves then
          local hw = math.floor((tw - 2) / 2)
          for k, h in ipairs(b.halves) do
            local hx = sx + (k - 1) * (hw + 2)
            local w2 = k == 2 and (tw - hw - 2) or hw
            local hot = mx >= hx and mx < hx + w2 and my >= sy and my < sy + L.rh
            local on = h[3] ~= nil
            set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(h[3], 0.3) or U.BG)); gfx.rect(hx, sy, w2, L.rh, 1)
            set(hot and U.AMBER or (on and h[3] or U.LINE)); gfx.rect(hx, sy, w2, L.rh, 0)
            text(hx + math.floor((w2 - ms(h[2])) / 2), sy, fit(h[2], w2 - 2), hot and U.AMBER or (h[3] or U.GREY))
            if hot then hover.ctrl = h[1] end
            hint('ctrl', hx, sy, w2, L.rh, h[1])
          end
        elseif b[1] then
          local hot = mx >= sx and mx < sx + tw and my >= sy and my < sy + L.rh
          local on = b[3] ~= nil
          set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(b[3], 0.3) or U.BG)); gfx.rect(sx, sy, tw, L.rh, 1)
          local fr2 = hot and U.AMBER or (on and b[3] or U.LINE)
          set(fr2); gfx.rect(sx, sy, tw, L.rh, 0)
          if si == 1 then cut(sx, sy + L.rh - 1, 1, -1, fr2) end
          if si == #sub then cut(sx + tw - 1, sy + L.rh - 1, -1, -1, fr2) end
          -- 15 окт: |<< прижат влево, >>| вправо (к своему краю); у ^O буква O — красная, как у rec
          local lab, lc = fit(b[2], tw - 2), hot and U.AMBER or (b[4] or b[3] or U.GREY)
          local tx = sx + math.floor((tw - ms(lab)) / 2)
          -- 16 окт: << / >> — ровно под << / >> верхнего ряда (по центру ячейки), черта | торчит наружу
          if b[1] == 'tp_start' then tx = sx + math.floor((tw - ms('<<')) / 2) - ms('|') elseif b[1] == 'tp_end' then tx = sx + math.floor((tw - ms('>>')) / 2) end
          if b[1] == 'shiftrec' and lab == '^O^' then   -- 15 окт: ^O^ (просьба), O — красное, как у rec
            text(tx, sy, '^', lc); text(tx + ms('^'), sy, 'O', hot and U.AMBER or D.REC); text(tx + ms('^O'), sy, '^', lc)
          else text(tx, sy, lab, lc) end
          if hot then hover.ctrl = b[1] end
          hint('ctrl', sx, sy, tw, L.rh, b[1])
        end
        sx = sx + tw + 2
      end
    end
    D.strip_cols[#D.strip_cols + 1] = { bx0, bx0 + math.max(btot, sep), { { 'Space', 'play' }, { 'Opt+R', 'rec' } } }
    -- 15 окт: строка под кнопками — по колонкам: под rew / pause — маркеры 1..0, под play — rate,
    -- под rec и дальше — тоглы записи (punch pre-roll rec>lib slow; не влезли — короче)
    if c.tpfull then
      local ry = ly + 2 * L.rh + 2   -- 15 окт: маркеры / punch — третьей строкой (кнопки в одну строку)
      local colx = function(i) local x2 = bx0; for k = 1, i - 1 do x2 = x2 + (TW[k] or tbw) + 2 end; return x2 end   -- 19 окт: колонки разной ширины
      local function cellb(id, lab, x0, w0, on, dimc)
        local hot = cell_hot(x0, ry, w0, L.rh)
        if hot then set(D.CURROW); gfx.rect(x0 - 1, ry, w0 + 2, L.rh, 1); hover.ctrl = id end
        text(x0 + math.floor((w0 - ms(lab)) / 2), ry, lab, hot and U.AMBER or (on and U.CYAN or (dimc and U.DIM or U.GREY)))
        hint('ctrl', x0, ry, w0, L.rh, id)
      end
      -- 16 окт: маркеры — кнопка markers (не влезло — mk), щелчок — выпадашка 1..0
      local any = false
      for k = 1, 10 do if c.marks and c.marks[k] then any = true end end
      -- 19 окт: третья строка: mark под <<, rate (x1.00 + слайдер) под play, тоглы записи — с колонки после play
      local pi3 = D.tp_play_i or 2
      local w1 = TW[1] or tbw
      cellb('markers', 'mark', colx(1), w1, false, not any)   -- 16 окт: mark (не mk)
      local rx0 = colx(pi3)
      local w2c = TW[pi3] or tbw
      local rv = c.rate or 1
      local rl = ('x%.2f'):format(rv)
      local rhot = cell_hot(rx0, ry, w2c, L.rh)
      text(rx0, ry, rl, rhot and U.AMBER or (math.abs(rv - 1) > 1e-3 and U.AMBER or U.GREY))
      -- слайдер — только в своей колонке (ромбик не на соседей); не влезает — одно значение (тянуть / колесо)
      local dr = math.max(3, math.floor((L.rh - 6) / 2)) + 2
      local sx2 = rx0 + ms(rl) + L.pad + dr
      local sw2 = rx0 + w2c - dr - sx2
      local r = math.max(0.25, math.min(2, rv))
      local inline = sw2 >= L.cw * 2
      if inline then U.dslider(sx2, ry + math.floor(L.rh / 2), sw2, (r - 0.25) / 1.75, false, rhot and U.AMBER or U.TEXT, rhot, L.rh)
      else sx2, sw2 = rx0, w2c end
      if rhot then hover.ctrl = 'ratebar' end
      hint('ctrl', rx0, ry, w2c, L.rh, 'ratebar')
      D.strip_cell.ratebar = { sx2, ry, sw2 }
      D.strip_cell.ratebar_inline = inline or nil
      -- 20 окт: узко — клик по значению открывает слайдер над ним (c.rate_pop), тянуть по нему
      D.strip_cell.ratepop = nil
      if c.rate_pop and not inline then
        local pw2 = 14 * L.cw
        local px2 = math.max(L.pad, math.min(gfx.w - pw2 - L.pad, rx0))
        local py2 = ry - L.rh - 4
        set(U.PANEL); gfx.rect(px2, py2, pw2, L.rh + 2, 1)
        set(U.AMBER); gfx.rect(px2, py2, pw2, L.rh + 2, 0)
        local ssx, ssw = px2 + dr + 2, pw2 - 2 * dr - 4
        local phot = mx >= px2 and mx < px2 + pw2 and my >= py2 and my < py2 + L.rh + 2
        U.dslider(ssx, py2 + 1 + math.floor(L.rh / 2), ssw, (r - 0.25) / 1.75, false, U.AMBER, phot, L.rh)
        if phot then hover.ctrl = 'ratepop' end
        D.strip_cell.ratepop = { ssx, py2, ssw }
      end
      -- запись: с колонки после play до конца группы
      local ax, a1 = colx(pi3 + 1), bx0 + btot
      local full = { { 'punch', 'pun', c.punch }, { 'preroll', 'pre', c.preroll }, { 'slow', c.slowrate and 'slo*' or 'slo', c.slowrec or c.slowrate },   -- 19 окт: короче (pun / slo)
                     { 'ripple', ({ [0] = 'ripple', 'ripple', 'ripple*' })[c.ripple or 0], (c.ripple or 0) > 0 } }   -- 16 окт: ripple (* — all tracks)
      local tot = 0
      for _, t in ipairs(full) do tot = tot + ms(t[2]) + 2 * L.pad end
      if ax + tot > a1 then full[4][2] = (c.ripple or 0) == 2 and 'rip*' or 'rip' end   -- 16 окт: тесно — rip
      for _, t in ipairs(full) do
        local w0 = ms(t[2]) + 2 * L.pad
        if ax + w0 > a1 + L.pad then break end
        cellb(t[1], t[2], ax, w0, t[3])
        ax = ax + w0
      end
    end
  end
  local function draw_buttons(bx0)
    if c.tptext then return draw_text_buttons(bx0) end
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
      if bk == 2 then D.big_text(bx + math.floor((bw - tws[i]) / 2), (b.k or BK) == BK and ty or (by + math.max(1, math.floor((bh - (b.k or BK) * L.th) / 2)) - (D.SPACE or 0)), b[2], hot and U.AMBER or (b[4] or b[3] or U.TEXT), b.k or BK)   -- запись ×2 целым масштабом: при ×1.5 O рубилась   -- b[4]: свой цвет (o — красная)
      else text(bx + math.floor((bw - tws[i]) / 2), by + 1, b[2], hot and U.AMBER or (b[4] or b[3] or U.TEXT)) end
      if hot then hover.ctrl = b[1] end
      hint('ctrl', bx, by, bw, bh, b[1])
      bx = bx + bw + 2
    end
    D.strip_cols[#D.strip_cols + 1] = { bx0, bx0 + math.max(btot, sep), { { 'Space', 'play' }, { 'Opt+R', 'rec' } } }
  end
  -- время и BPM крупно (опция big time and BPM)
  local big = (c.bigbpm or c.tpfull) and {
    { 'play', '> ' .. (c.pos or ''), c.playing and U.GREEN or U.TEXT },
    { 'bpm', c.bpm_edit and ((c.bpm_edit ~= '' and c.bpm_edit or '...') .. ' BPM') or ('%.1f BPM'):format(c.bpm or 0), c.bpm_edit and U.AMBER or U.TEXT },   -- 16 окт: при вводе слово BPM остаётся
    { 'sig', (c.sig_num and c.sig_den) and ('%d/%d'):format(c.sig_num, c.sig_den) or '4/4', U.TEXT },   -- 15 окт: размер — крупно справа от BPM
  } or nil
  local bigw = 0
  -- 16 окт: BPM — постоянная ширина (по «000.0 BPM»): ввод числа и смена темпа не двигают соседей
  local BKT = c.bigbpm and 2 or 1   -- 19 окт: опция big time and BPM — крупно (x2) / обычным текстом на том же месте
  if big then for i, b in ipairs(big) do b.w = D.big_measure(b[2], BKT); if b[1] == 'bpm' then b.w = math.max(b.w, D.big_measure('000.0 BPM', BKT)) end; bigw = bigw + b.w + (i > 1 and 3 * L.pad or 0) end end
  local function draw_big(bx)
    local bx0 = bx
    for _, b in ipairs(big) do
      local hot = cell_hot(bx, ly, b.w, 2 * L.rh)
      -- 25 окт: курсор клавиатуры (фокус транспорта, f на BPM) — подложкой и янтарём; прямоугольник — для выпадашки под ним
      local kbd = info.focus == 'ctrl' and info.ctrl_sel == b[1]
      if kbd then set(U.tint(U.AMBER, 0.35)); gfx.rect(bx - 2, ly, b.w + 4, 2 * L.rh, 1) end
      D.ctrl_rect = D.ctrl_rect or {}; D.ctrl_rect[b[1]] = { bx, ly + L.rh, b.w, L.rh }
      D.big_text(bx, ly + (BKT == 1 and math.floor(L.rh / 2) or 0), b[2], (hot or kbd) and U.AMBER or b[3], BKT)
      if hot then hover.ctrl = b[1] end
      hint('ctrl', bx, ly, b.w, 2 * L.rh, b[1])
      bx = bx + b.w + 3 * L.pad
    end
    -- 11 окт: full — размер, метроном и доли одной строкой под крупными временем и BPM
    if c.tpfull and D.sig_line then draw_group(D.sig_line, bx0, bigw, ly + 2 * L.rh + 2 - (L.tp_cut or 0)) end
    if c.tpfull and D.swing_line then local sw0 = group_w(D.sig_line) + 3 * L.pad; draw_group(D.swing_line, bx0 + sw0, bigw - sw0, ly + 2 * L.rh + 2) end   -- 15 окт: swing — в строку с метрономом
  end
  -- порядок блоков
  local by_id = {}
  for _, g in ipairs(D.transport_groups(c, L)) do by_id[g[1][1][1]] = g end
  local order = {}
  local function addg(id) if by_id[id] then order[#order + 1] = { w = group_w(by_id[id]), draw = function(gx, gw) draw_group(by_id[id], gx, gw) end } end end
  -- 16 окт: где курсор — у клавиатуры (был модлайн): трек, ниже колонка и строка
  do
    local vc = info.vcur
    local f = vc and L.flat and L.flat[vc.fi]
    if f and f.col then
      local fname = D.cursor_field_name(f, vc)
      local fcol = not f.env and not f.ml and not f.folded and (D.field_rgb(vc.sub or vc.field or 1) or (vc.sub == 'inst' and U.TEXT))
      local l1 = (f.col.name ~= '' and f.col.name) or 'track'
      local l2 = ('%04d'):format(math.max(0, vc.row or 0) + (D.ROW_BASE or 1))
      local cl = ms('col') + L.pad          -- пробел в битмапе — нулевой ширины: отступ L.pad
      local lw = math.max(ms(fit(l1, 14 * L.cw)), cl + ms(fname), cl + ms(l2), 10 * L.cw)
      order[#order + 1] = { w = lw, draw = function(gx)
        text(gx, ly, fit(l1, lw), U.TEXT)
        text(gx, ly + L.rh, 'col', U.GREY); text(gx + cl, ly + L.rh, fit(fname, lw - cl), fcol or U.TEXT)   -- 18 окт: цветом колонки
        if h >= 3 * L.rh then text(gx, ly + 2 * L.rh, 'row', U.GREY); text(gx + cl, ly + 2 * L.rh, l2, U.TEXT) end
      end }
    end
  end
  addg('step')
  addg('listen')   -- 12 окт: step / sel / line
  order[#order + 1] = { w = btot, draw = draw_buttons }
  -- 11 окт: full — sig / metro / доли под BPM (одна строка); блок шириной по большей из строк
  if big and c.tpfull and by_id.sig then
    local g = by_id.sig
    -- 15 окт: строка под BPM — metro словом-тумблером (цвет — вкл), доли квадратиками без «bar 1 beat 2/4»
    -- (позиция крупно рядом); swing — туда же, если влезает
    local mt = { 'metro', 'metro', c.metro and U.CYAN or U.GREY }
    local bt = {}; for k2, v2 in pairs(g[2][1]) do bt[k2] = v2 end; bt[2] = ''
    bt.bres = 15   -- 25 окт: место под 15 долей заранее — длинный размер не двигает соседей
    -- 25 окт: swing — слева от metro (размер — крупно справа от BPM, как BPM по опции)
    local sw = by_id.swing
    D.sig_line = sw and { { sw[1][1], sw[2][1], mt, bt } } or { { mt, bt } }
  else D.sig_line = nil end
  -- 15 окт: full — rate под кнопками, swing под метрономом (одной строкой: подпись и слайдер)
  D.rate_line = (c.tpfull and c.tptext and by_id.rate) and true or nil   -- 15 окт: rate — под play (строка под кнопками)
  D.swing_line = nil   -- 25 окт: swing теперь в строке метронома (sig_line)
  -- 15 окт: swing — в строку с метрономом, только если влезает в ширину BPM; иначе — у правого края, как раньше
  if D.swing_line and group_w(D.sig_line) + 3 * L.pad + group_w(D.swing_line) > bigw then D.swing_line = nil end
  local bigw2 = D.sig_line and math.max(bigw, group_w(D.sig_line)) or bigw
  if big then order[#order + 1] = { w = bigw2, draw = draw_big } else addg('play') end
  if not D.rate_line then addg('rate') end         -- 11 окт: скорость проекта (15 окт: full — под кнопками)
  if not D.sig_line then addg('sig') end   -- 11 окт: в full он под BPM
  if not (c.tpfull and c.tptext) then addg('punch') end   -- 9 окт: LPB — в блоке step (15 окт: full — под rec)
  -- 9 окт: swing со слайдером — у самого правого края (тоглы follow / lock … — в главном модуле)
  local last = (by_id.swing and not D.swing_line and not (D.sig_line and #D.sig_line[1] > 2)) and { w = group_w(by_id.swing), draw = function(gx, gw) draw_group(by_id.swing, gx, gw) end } or nil
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
  -- 15 окт: режим — модлайном в поле трекера (D.draw_mode), в полосе его нет
  return out
end

-- 18 окт: ВИМЪ / ВИЙ / КЛАВИСИНЪ (просьба)
-- 13 окт: у письменностей — своё слово режима (старославянский, китайский, арабский, клингонский pIqaD)
-- 15 окт: все слова режима, включая модуль в фокусе (UNDO, LIB, DSP…); клингонский — латиницей
-- клингонского, в pIqaD переводит klingon() ниже; слова без перевода — латиница как есть
local MW = {
  --            Ponomar            Songti SC     Diwan Thuluth        клингонский
  NORMAL     = { 'ВИПЕРЪ',          '常规',       'عادي',             'motlh' },
  INSERT     = { 'ВСТАВКА',         '插入',       'إدراج',            'lIch' },
  VISUAL     = { 'ВИЙ',             '选择',       'تحديد',            'legh' },
  ['V-LINE'] = { 'СТРОКА',          '行选',       'سطر',              'tlhegh' },
  KEYS       = { 'КЛАВИСИНЪ',       '键盘',       'مفاتيح',           'leQ' },
  UNDO       = { 'ВОЗВРАТЪ',        '撤销',       'تراجع',            'chegh' },
  PANE       = { 'ОКНО',            '窗格',       'لوحة',             'Qorwagh' },
  CONTROL    = { 'УПРАВА',          '控制',       'تحكم',             'SeH' },   -- 27 окт: CONTROL → CONTROL
  FADE       = { 'ДВИЖОКЪ',         '推子',       'منزلق',            'joD' },
  TRACKS     = { 'ДОРОЖКИ',         '轨道',       'مسارات',           'He' },
  CTRL       = { 'ВЛАСТЬ',          '控制',       'تحكم',             'SeH' },
  COMMAND    = { 'ПОВЕЛѢНІЕ',       '命令',       'أمر',              "ra'" },
  SEARCH     = { 'ПОИСКЪ',          '搜索',       'بحث',              'nej' },
  RENAME     = { 'ИМЯ',             '重命名',     'تسمية',            'pong' },
  AUTOMATION = { 'САМОДѢЙСТВІЕ',    '自动化',     'أتمتة',            'mIw' },
  BROWSER    = { 'ОБЗОРЪ',          '浏览',       'متصفح',            'nejwI\'' },
  CLIPBOARD  = { 'ХРАНИЛИЩЕ',       '剪贴板',     'حافظة',            'pol' },
  CLIPS      = { 'ОТРЫВКИ',         '片段',       'مقاطع',            "pe'" },
  DSP        = { 'ЗВУКЪ',           '处理',       'معالجة',           'wab' },
  FX         = { 'ДѢЙСТВА',         '效果',       'مؤثرات',           'choH' },
  GRID       = { 'РѢШЕТКА',         '网格',       'شبكة',             'mach' },
  HARMONIZER = { 'СОГЛАСІЕ',        '和声',       'تناغم',            'bom' },
  ITEM       = { 'ПРЕДМЕТЪ',        '条目',       'عنصر',             'Doch' },
  SAMPLER    = { 'СЭМПЛЕРЪ',        '采样器',     'مُعيِّن',            'wab' },   -- 16 окт: вкладка item в фокусе
  LIB        = { 'КНИЖНИЦА',        '库',         'مكتبة',            'paq' },
  MACROS     = { 'МАКРОСЫ',         '宏',         'وحدات',            'ra\'mey' },
  VIPER      = { 'ГАДЮКА',          '蝰蛇',       'أفعى',             'ghargh' },   -- 22 окт: панель main — режим VIPER (просьба)
  MASTER     = { 'ВЛАДЫКА',         '总线',       'الإخراج',          'pIn' },
  MATRIX     = { 'МАТРИЦА',         '矩阵',       'مصفوفة',           'mIr' },
  MIDI       = { 'МИДИ',            '迷笛',       'ميدي',             'QIn' },
  MIXER      = { 'СМѢСИТЕЛЬ',       '混音',       'مازج',             'DuD' },
  MODULATION = { 'ИЗМѢНЕНІЕ',       '调制',       'تضمين',            'choH' },
  NOTES      = { 'ЗАПИСИ',          '笔记',       'ملاحظات',          'ghItlh' },
  ORCA       = { 'ОРКА',            '逆戟鲸',     'أوركا',            'Qogh' },
  PM         = { 'ДѢЛА',            '项目',       'مشاريع',           'Qu\'' },
  PROPERTIES = { 'СВОЙСТВА',        '属性',       'خصائص',            'Daj' },
  REC        = { 'ЗАПИСЬ',          '录音',       'تسجيل',            'qon' },
  SCOPES     = { 'ЗЕРЦАЛА',         '示波器',     'راسم',             'leghwI\'' },
  SLICES     = { 'ЛОМТИ',           '切片',       'شرائح',            "pe'" },
  TRACKER    = { 'ТРЕКЕРЪ',         '音轨器',     'متتبع',            'ghoch' },
  VIDEO      = { 'ВИДѢНІЕ',         '视频',       'فيديو',            'mIllogh' },
  VISOR      = { 'ЗЕРЦАЛО',         '视觉',       'مرئيات',           'legh' },
  TOP        = { 'ВЕРХЪ',           '顶部',       'أعلى',             'Dung' },
  -- 18 окт: новые режимы и панели
  PATTERNKB  = { 'УЗОРКЛАВЪ',       '图案键',     'أنماط',            "mIr leQ" },   -- ноты играют паттерны (MPC)
  PERFORMANCE = { 'УСИЛІЕ',         '性能',       'أداء',             'HoS' },
  ACTIONS    = { 'ДѢЯНІЯ',          '动作',       'إجراءات',          "ta'" },
  HELP       = { 'ПОМОЩЬ',          '帮助',       'مساعدة',           'QaH' },
  ['NOTE MOD'] = { 'НОТОИЗМѢНА',    '音符调制',   'تضمين',            'bom choH' },
  REAPER     = { 'ЖНЕЦЪ',           '收割者',     'حاصد',             "HoHwI'" },   -- 15 окт: клавиши у REAPER (окно без фокуса)
}
-- pIqaD (CSUR U+F8D0…): клингонская латиница → знаки; tlh ch gh ng — один знак
local function klingon(w)
  local L1 = { a = 0, b = 1, D = 3, e = 4, H = 6, I = 7, j = 8, l = 9, m = 10, n = 11, o = 13, p = 14, q = 15, Q = 16, r = 17, S = 18, t = 19, u = 21, v = 22, w = 23, y = 24, ["'"] = 25 }
  local out, i = {}, 1
  while i <= #w do
    local c3, c2, c1 = w:sub(i, i + 2), w:sub(i, i + 1), w:sub(i, i)
    local cp, n
    if c3 == 'tlh' then cp, n = 20, 3
    elseif c2 == 'ch' then cp, n = 2, 2
    elseif c2 == 'gh' then cp, n = 5, 2
    elseif c2 == 'ng' then cp, n = 12, 2
    else cp, n = L1[c1], 1 end
    out[#out + 1] = cp and utf8.char(0xF8D0 + cp) or c1
    i = i + n
  end
  return table.concat(out)
end
-- 16 окт: глаголица — буквами из церковнославянского столбца (кириллица → U+2C00…)
local GLAG = { ['А'] = 0, ['Б'] = 1, ['В'] = 2, ['Г'] = 3, ['Д'] = 4, ['Е'] = 5, ['Ё'] = 5, ['Э'] = 5, ['Ж'] = 6, ['Ѕ'] = 7, ['З'] = 8,
  ['И'] = 9, ['Й'] = 10, ['І'] = 11, ['К'] = 13, ['Л'] = 14, ['М'] = 15, ['Н'] = 16, ['О'] = 17, ['П'] = 18, ['Р'] = 19,
  ['С'] = 20, ['Т'] = 21, ['У'] = 22, ['Ф'] = 23, ['Х'] = 24, ['Щ'] = 27, ['Ц'] = 28, ['Ч'] = 29, ['Ш'] = 30, ['Ъ'] = 31,
  ['Ь'] = 32, ['Ѣ'] = 33, ['Я'] = 33, ['Ю'] = 35 }
local function glagolitic(w)
  local out = {}
  for _, cp in utf8.codes(w) do
    local ch = utf8.char(cp)
    if ch == 'Ы' then out[#out + 1] = utf8.char(0x2C00 + 31, 0x2C00 + 11)
    elseif GLAG[ch] then out[#out + 1] = utf8.char(0x2C00 + GLAG[ch])
    else out[#out + 1] = ch end
  end
  return table.concat(out)
end
D.MODE_SCRIPT = { ['Ponomar'] = {}, ['Songti SC'] = {}, ['Diwan Thuluth'] = {}, ['pIqaD qolqoS'] = {}, ['Noto Sans Glagolitic'] = {} }
for k, v in pairs(MW) do
  D.MODE_SCRIPT['Ponomar'][k], D.MODE_SCRIPT['Songti SC'][k], D.MODE_SCRIPT['Diwan Thuluth'][k] = v[1], v[2], v[3]
  D.MODE_SCRIPT['pIqaD qolqoS'][k] = klingon(v[4])
  D.MODE_SCRIPT['Noto Sans Glagolitic'][k] = glagolitic(v[1])
end
-- 15 окт: таблица вынесена — превью шрифтов во вкладке тем пишет тем же словом
-- 15 окт: множитель размера — у шрифта мелкое очко при той же высоте строки (арабский был вдвое мельче)
D.MODE_FONT_SCALE = { ['Diwan Thuluth'] = 2.0, ['Ponomar'] = 1.6, ['Songti SC'] = 1.3, ['Noto Sans Glagolitic'] = 1.2, ['Savoye LET'] = 1.6, ['Brush Script MT'] = 1.2, ['SignPainter'] = 1.3 }
-- 15 окт: слово режима крупно (×2 или декоративным шрифтом mode font): str — «РЕЖИМ | …» (берётся до |),
-- sx0, sy0 — левый верх, sw — ширина места (слово не шире трети); dry — только измерить; → ширина слова, высота
-- 22 окт: выпадашка-клавиатура для параметра-ноты DSP (note lo / hi, root): 0..127, текущая — голубым, под мышью —
-- янтарём, подпись октав C0 … C9; D.notepop = { k, pi, x, y, cur, name } ставит main; щелчок по клавише — hover.notepop
function D.draw_notepop(L, hover)
  local np = D.notepop
  local W, H = gfx.w, gfx.h
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local nwhite = 75
  local kw = math.max(5, math.floor(math.min(W - 4 * L.pad, L.cw * 90) / nwhite))
  local kbw = kw * nwhite
  local kh = 3 * L.rh
  local pw, ph = kbw + 2 * L.pad, kh + 2 * L.rh + 2 * L.pad
  local px = math.max(L.pad, math.min(W - pw - L.pad, (np.x or 0) - math.floor(pw / 2)))
  local py = (np.y or 0) - ph - 4
  if py < L.pad then py = math.min(H - ph - L.pad, (np.y or 0) + L.rh) end
  for k0 in pairs(hover) do if mx >= px and mx < px + pw and my >= py and my < py + ph then hover[k0] = nil end end
  hover.notepop_in = mx >= px and mx < px + pw and my >= py and my < py + ph or nil
  set(U.PANEL); gfx.rect(px, py, pw, ph, 1)
  set(U.AMBER); gfx.rect(px, py, pw, ph, 0)
  local NN = { 'C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-' }
  local function nm(n) local o = n // 12 - 1; local b = NN[n % 12 + 1]; if o < 0 then b = b:gsub('%-$', '') end; return b .. o end
  local kx0, ky0 = px + L.pad, py + L.pad + L.rh
  local WHITE = { [0] = 0, 2, 4, 5, 7, 9, 11 }
  local wpos, hot = {}, nil
  local wi = 0
  for n = 0, 127 do
    local pc = n % 12
    if pc == 0 or pc == 2 or pc == 4 or pc == 5 or pc == 7 or pc == 9 or pc == 11 then wpos[n] = wi; wi = wi + 1 end
  end
  -- чёрные сверху приоритетнее при наведении
  local bh = math.floor(kh * 0.6)
  for n = 0, 127 do
    if not wpos[n] then
      local x = kx0 + wpos[n - 1] * kw + kw - math.floor(kw / 3)
      if mx >= x and mx < x + math.max(2, math.floor(kw * 2 / 3)) and my >= ky0 and my < ky0 + bh then hot = n end
    end
  end
  if not hot then for n, w0 in pairs(wpos) do local x = kx0 + w0 * kw; if mx >= x and mx < x + kw and my >= ky0 and my < ky0 + kh then hot = n end end end
  for n, w0 in pairs(wpos) do
    local x = kx0 + w0 * kw
    set(n == hot and U.AMBER or (n == np.cur and U.CYAN or U.mix(U.TEXT, U.BG, 0.2))); gfx.rect(x, ky0, kw - 1, kh, 1)
    if n % 12 == 0 then text(x, ky0 + kh + 1, 'C' .. (n // 12 - 1), U.GREY) end
  end
  for n = 0, 127 do
    if not wpos[n] then
      local x = kx0 + wpos[n - 1] * kw + kw - math.floor(kw / 3)
      set(n == hot and U.AMBER or (n == np.cur and U.CYAN or U.BG)); gfx.rect(x, ky0, math.max(2, math.floor(kw * 2 / 3)), bh, 1)
    end
  end
  text(px + L.pad, py + L.pad, fit((np.name or 'note') .. ': ' .. (hot and nm(hot) or (np.cur and nm(np.cur) or '')) .. ((D.info and D.info.hints) and '   click - set, Esc / click outside - close' or ''), pw - 2 * L.pad), U.AMBER)
  if hot then hover.notepop = hot end
end
-- 22 окт: снапшоты микшера слева в пустом месте микшера — как окно SWS Snapshots: вкладки snapshots | xy;
-- snapshots — кнопки new prev next up down sws, таблица # / name / date / time (щелчок — вызвать, Cmd — записать
-- поверх, Alt — удалить, ПКМ — меню), фильтр SWS (full mix / visibility / custom + галочки) и опции, если влезают
-- по высоте (иначе кнопка filter — меню); xy — пэд: 4 угла = громкость и пан всех треков, шайба — морф
function D.draw_mixsnaps(L, info, hover)
  local ms0 = info.mixsnaps
  local x0 = L.mix_pane and L.mix_pane.x or 0
  local x1
  for _, c in ipairs(L.cols or {}) do if c.x and c.x > x0 and (not x1 or c.x < x1) then x1 = c.x end end
  if L.mix_pane then x1 = math.min(x1 or (L.mix_pane.x + L.mix_pane.w), L.mix_pane.x + L.mix_pane.w) end
  if not x1 then return end
  local y0, h = L.mix_y + 3, L.mix_h - 6
  local x, w = x0 + L.pad, x1 - x0 - 2 * L.pad
  if w < ms('new prev') + 6 * L.pad or h < 3 * L.rh then return end
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local rh = L.rh
  local function btn(bx, by, label, on, sel, h2)
    local bw = ms(label) + 2 * L.pad
    local hot = mx >= bx and mx < bx + bw and my >= by and my < by + rh - 1
    set(hot and U.tint(U.AMBER, 0.35) or (on and U.tint(U.CYAN, 0.3) or U.PANEL)); gfx.rect(bx, by, bw, rh - 2, 1)
    set((hot or sel) and U.AMBER or (on and U.CYAN or U.DIM)); gfx.rect(bx, by, bw, rh - 2, 0)
    text(bx + L.pad, by, label, (hot or sel) and U.AMBER or (on and U.TEXT or U.GREY))
    if hot then hover.mixsnap = h2 end
    hint('mixsnap', bx, by, bw, rh - 2, h2)
    return bw
  end
  -- 30 окт: XY — под списком (вкладки xy больше нет: одно место); угол — снапшот из списка (правый клик) или микшер сейчас
  local function xypad(py0, side)
    local xy = ms0.xy or { has = {}, from = {} }
    local px0 = x + math.floor((w - side) / 2)
    local function lab(i) return (xy.from or {})[i] and (i .. ':' .. xy.from[i]) or tostring(i) end
    local cbw = 0
    for i = 1, 4 do cbw = math.max(cbw, ms(lab(i)) + 2 * L.pad) end
    local onpad = mx >= px0 and mx < px0 + side and my >= py0 and my < py0 + side
    set(U.BG); gfx.rect(px0, py0, side, side, 1)
    set(onpad and U.AMBER or U.LINE); gfx.rect(px0, py0, side, side, 0)
    set(U.mix(U.LINE, U.BG, 0.5)); gfx.rect(px0 + math.floor(side / 2), py0 + 1, 1, side - 2, 1); gfx.rect(px0 + 1, py0 + math.floor(side / 2), side - 2, 1, 1)
    local corners = { { px0 + 1, py0 + 1 }, { px0 + side - cbw - 1, py0 + 1 }, { px0 + 1, py0 + side - rh }, { px0 + side - cbw - 1, py0 + side - rh } }
    local oncorner
    for i, c in ipairs(corners) do
      local hot = mx >= c[1] and mx < c[1] + cbw and my >= c[2] and my < c[2] + rh - 1
      btn(c[1], c[2], lab(i), xy.has[i], false, { what = 'xyc', arg = i })
      if hot then oncorner = true end
    end
    local n = 0; for i = 1, 4 do if xy.has[i] then n = n + 1 end end
    if n >= 2 then
      local cx, cy = px0 + math.floor((xy.x or 0.5) * (side - 1)), py0 + math.floor((xy.y or 0.5) * (side - 1))
      set(xy.drag and U.AMBER or U.CYAN)
      for d = 0, 4 do gfx.rect(cx - d, cy - 4 + d, 2 * d + 1, 1, 1); gfx.rect(cx - d, cy + 4 - d, 2 * d + 1, 1, 1) end
    elseif side >= ms('xy: corners') + 2 * L.pad and side >= 3 * rh then
      text(px0 + math.floor((side - ms('xy: corners')) / 2), py0 + math.floor((side - rh) / 2), 'xy: corners', U.DIM)
    end
    if onpad and not oncorner then hover.mixsnap = { what = 'xypad', x0 = px0, y0 = py0, side = side } end
  end
  local yy = y0
  -- кнопки: new prev next up down sws (+ filter, если блок фильтра не влезает)
  -- 30 окт: фильтр SWS и опции — только кнопкой filter (меню) рядом с sws; место под таблицей — списку и XY
  local B = { { 'new', 'new' }, { 'prev', 'prev' }, { 'next', 'next' }, { 'up', 'up' }, { 'down', 'down' }, { 'sws', 'win' }, { 'filter', 'filtermenu' } }
  local bx = x
  for _, b in ipairs(B) do
    local bw = ms(b[1]) + 2 * L.pad
    if bx + bw > x + w and bx > x then bx = x; yy = yy + rh end
    bx = bx + btn(bx, yy, b[1], false, false, { what = b[2] }) + 2
  end
  yy = yy + rh + 2
  -- таблица
  local nw = ms('12') + L.pad
  local tw = ms('00:00:00') + L.pad
  local dw = ms('00.00.00') + L.pad
  local showt = w - nw - tw >= ms('Mix 12') + L.pad
  local showd = showt and (w - nw - tw - dw >= ms('Mix 12') + L.pad)
  local namew = w - nw - (showt and tw or 0) - (showd and dw or 0)
  set(U.mix(U.BG, U.TEXT, 0.12)); gfx.rect(x, yy, w, rh, 1)
  text(x + 2, yy, '#', U.GREY); text(x + nw, yy, fit('name', namew - L.pad), U.GREY)
  if showd then text(x + nw + namew, yy, 'date', U.GREY) end
  if showt then text(x + w - tw, yy, 'time', U.GREY) end
  yy = yy + rh
  local listh = (y0 + h) - yy
  local nvis = math.max(1, math.floor(listh / rh))
  local want = math.max(3, math.min(12, #ms0.rows + 1))   -- 30 окт: строк — по снапшотам (SWS: 12), остаток — XY
  local padside
  if nvis > want then
    local room = listh - want * rh - 4
    local side = math.min(w, room)
    if side >= 4 * rh then nvis = math.max(want, math.floor((listh - side - 4) / rh)); padside = side end   -- остаток под XY — снова списку
  end
  for i = 1, nvis do
    local ry = yy + (i - 1) * rh
    local r = ms0.rows[i]
    set(i % 2 == 0 and U.mix(U.BG, U.TEXT, 0.05) or U.BG); gfx.rect(x, ry, w, rh, 1)
    if r then
      local cur = ms0.cur == r.slot
      local hot = mx >= x and mx < x + w and my >= ry and my < ry + rh
      if cur or hot then set(U.tint(U.AMBER, cur and 0.25 or 0.15)); gfx.rect(x, ry, w, rh, 1) end
      local tc = (cur or hot) and U.AMBER or U.TEXT
      text(x + 2, ry, tostring(r.slot), (cur or hot) and U.AMBER or U.GREY)
      text(x + nw, ry, fit(r.name ~= '' and r.name or ('Mix ' .. r.slot), namew - L.pad), tc)
      if showd then text(x + nw + namew, ry, fit(r.date or '', dw - 2), U.GREY) end
      if showt then text(x + w - tw, ry, fit(r.time or '', tw - 2), U.GREY) end
      if hot then hover.mixsnap = { what = 'row', i = i } end
      hint('mixsnap', x, ry, w, rh, { what = 'row', i = i })
    end
  end
  if #ms0.rows > nvis then text(x + w - ms('+' .. (#ms0.rows - nvis)), yy + (nvis - 1) * rh, '+' .. (#ms0.rows - nvis), U.GREY) end
  set(U.LINE); gfx.rect(x, yy - rh, w, nvis * rh + rh, 0)
  if padside then xypad(yy + nvis * rh + 4, padside) end
end
-- 23 окт: дети контейнера — колонками; маленькие (до 5 параметров) подряд по цепочке (serial) — друг под другом
-- в одной колонке: сигнал течёт сверху вниз. rows — строк под параметры. → place[ki] = { c = колонка с 0,
-- hr = строка заголовка (−1 — верхний, в шапке), r0 = первая строка параметров }, число колонок
-- 23 окт: вид цепи пэда drumrs5k. Есть цепи chain N (параллельный бросок) — как Ableton: столбец-список строк
-- (цепи и эффекты пэда, | / =), выбранная строка — её эффекты колонками (до 2); нет цепей — эффекты пэда колонками (до 3).
-- → { list = bool, ncols = колонок справа, sel, show = { эффекты колонками }, slot = выбранная строка }
function D.pad_chain_view(kid, key)
  local slots = kid and kid.slots or {}
  local has = false
  for _, sl in ipairs(slots) do if sl.chain then has = true end end
  -- 23 окт: сами эффекты — полноценными модулями за рэком (model.expand_inner); здесь — только список цепей
  if not has then return { list = false, ncols = 0, show = {} } end
  D.chain_sel = D.chain_sel or {}
  local sel = math.max(1, math.min(#slots, D.chain_sel[key] or 1))
  return { list = true, ncols = 1, sel = sel, show = {}, slot = slots[sel] }
end
-- 24 окт: контейнер — рэк, как в Ableton / Bitwig: слева шапка (имя, макросы, XY), в середине эффекты на подложке
-- цвета контейнера (щели между ними залиты — видно, что это одно целое), справа — замыкание «out»; рамка сверху и снизу
-- через все три части. Вложенный контейнер — подложка гуще (глубина). D.cst[f] — начало рэка (x, ряд, номер блока).
-- 24 окт: цвет параллельной ветки (lane 1, 2, …) — скобка под её модулем / контейнером
-- 28 окт: акцент курсора — и у его кромки, строки плейхеда и хвоста (один цвет с ячейкой курсора)
function D.acc_apply()
  local a = D.CUR_ACC
  if not a then return end
  D.CUR, D.CURTOP, D.PLAYC = a, a, a
  D.PLAY = U.tint(a, 0.36)
  D.CURCELL = a
end
local function lane_col(n) local P = { U.CYAN, U.GREEN, U.YELLOW, U.RED }; return P[(n - 1) % #P + 1] end
D.lane_col = lane_col
-- 28 окт: контейнер — только яркие [ ] внутри по краям: без линий над / под модулями, без ступенек и скобок
-- (5 контейнеров = 10 линий — нечитаемо); зазор от шрифта: G = L.pad между модулями и от скобки до модуля
-- 28 окт (3): высота — как у модуля с его внешним пикселем рамки (by - 1 … by + bh), усики длиннее, от шрифта
local function sq_bracket(x, y, h, right, L)
  y, h = y - 1, h + 2
  local hw = math.max(4, L.pad + 1)   -- 28 окт (5): усики короче — от их концов до модуля видно зазор
  gfx.rect(x, y, 2, h, 1)
  local hx = right and (x + 2 - hw) or x
  gfx.rect(hx, y, hw, 2, 1); gfx.rect(hx, y + h - 2, hw, 2, 1)
end
-- 28 окт (4): цвет скобок — тёмный янтарь; ярко — только у выделенного в DSP контейнера; выключен — тускло
local function br_col(c)
  if not (c.enabled and not c.poff) then return U.DIM end
  return (D.sel_i and c.i == D.sel_i) and U.AMBER or U.tint(U.AMBER, 0.45)
end
local function brg(L) return math.max(6, 2 * L.pad) end   -- 28 окт (2): от скобки до модуля — полный зазор (пол-зазора липло)
function D.lane_close(L, f, bx, boxy, bh0)
  local st = D.lst
  if not (st and st.f == f and st.y == boxy) then return end
  if (D.rack_ext or 0) < 3 then return end
  set((f.enabled and not f.poff) and ((D.chain_col and D.chain_col(f.inner.parent, f.inner.lane or f.inner.bi)) or lane_col(f.inner.lane or f.inner.bi)) or U.DIM)   -- 28 окт: полоса ÷N — своим цветом (или выбранным)
  gfx.rect(st.x, boxy + bh0 + 1, math.max(2, bx - L.pad - st.x), 2, 1)   -- ветка — черта под модулем, без ножек
  if D.lane_top then gfx.rect(st.x, boxy - 3, math.max(2, bx - L.pad - st.x), 2, 1) end   -- 28 окт: опция — и над модулем
end
function D.rack_open(L, f, k, bx, boxy, bh0)
  if f.wrap then
    set(br_col(f)); sq_bracket(bx, boxy, bh0, false, L)
    D.cst[f] = { x = bx, y = boxy, k = k }
    bx = bx + 2 + brg(L)
  end
  if f.inner and (f.inner.lane or f.inner.bi) and not f.wrap then D.lst = { f = f, x = bx, y = boxy } end
  return bx
end
-- конец рэка: ] за последним модулем (добавить внутрь — кнопка + в шапке контейнера, бросок — щель у модуля)
function D.rack_close(L, f, bx, boxy, bh0, drag, mx, my, hover)
  for _, c in ipairs(f.cend) do
    local st = D.cst[c]
    local x = bx - L.pad + brg(L)
    -- 28 окт (2): поля броска в конце нет — щель «после последнего модуля» делает то же (была двойная плашка)
    if st and st.y == boxy then
      set(br_col(c)); sq_bracket(x, boxy, bh0, true, L)
    end
    bx = x + 2 + L.pad
  end
  return bx
end
-- 24 окт: назначения макросов контейнера строками под его ручками (M — янтарём, сила со знаком)
-- 24 окт: ручка — кольцо (как на Nagra / Kudelski): дуга 270°, тусклая — весь ход, яркая — значение, риска — указатель
function D.knob(cx, cy, r, v, col)
  local a0, a1 = -0.75 * math.pi, 0.75 * math.pi
  local av = a0 + (a1 - a0) * math.max(0, math.min(1, v or 0))
  set(U.DIM); gfx.arc(cx, cy, r, a0, a1, 1); gfx.arc(cx, cy, r - 1, a0, a1, 1)
  set(col or U.CYAN); gfx.arc(cx, cy, r, a0, av, 1); gfx.arc(cx, cy, r - 1, a0, av, 1)
  gfx.line(cx, cy, cx + math.sin(av) * (r - 1), cy - math.cos(av) * (r - 1), 1)
end
-- 24 окт: под ручками макросов: [+] [−] сколько; что на каком («M1 Serum cutoff +50»); цепи контейнера — строкой
-- каждая: ручка громкости (Wet цепи, тянуть вверх / вниз), имя, m (выкл.), s (только она)
function D.macro_list() end   -- 25 окт: макросы контейнера убраны (★-параметры и связи — в CHAINS / LINKS)
-- 24 окт: отдел цепей контейнера: слева вертикальная подпись chains, справа строка на цепь — ручка громкости
-- (Wet цепи), | / = и имя, m, s
local function tr0_of(info) return info.pool_col and info.pool_col.track end
function D.cont_chains(L, info, f, x0, y, w0, ymax, k, drag, mx, my, hover)
  -- 31 окт: цепь = поток контейнера: начинается первым модулем или модулем с parallel (=), за ним — его
  -- последовательные (|); строка на цепь, а не на модуль (было перепутано)
  local chains = {}
  for ki, kd in ipairs(f.kids or {}) do
    if not (kd.name or ''):find('jf_tracker_macro', 1, true) then
      if #chains == 0 or (kd.parallel or 0) > 0 then chains[#chains + 1] = { ki = ki, kd = kd, kis = {}, kds = {} } end
      local c = chains[#chains]
      c.kis[#c.kis + 1] = ki; c.kds[#c.kds + 1] = kd
    end
  end
  if #chains == 0 or y + L.rh > ymax then return end
  -- 28 окт: заголовок — переключатели CHAINS | ROUTE | XY (одно на всю высоту); не chains — вернуть низ строки и вкладку
  set(U.LINE); gfx.rect(x0, y + L.rh - 2, w0, 1, 1)
  D.ctab = D.ctab or {}
  local tkey = tostring(f.fguid or f.i)
  -- 29 окт: CHAINS — верхняя половина (всегда), рядом слоты вариантов 1..5 (параметры + mix / вкл цепей + углы XY);
  -- ROUTE | XY — переключатель внизу половины, под ним нижняя половина (щелчок по горящему — убрать)
  local tab = D.ctab[tkey] or 'xy'
  if tab == 'chains' then tab = 'none' end
  text(x0 + L.pad, y, 'CHAINS', U.AMBER)
  local tx = x0 + ms('CHAINS') + 3 * L.pad
  local cv = info.cvars and info.cvars(info.pool_col, f)
  if cv then
    local cbw = ms('8') + 2 * L.pad
    for i = 1, 5 do
      if tx + cbw > x0 + w0 then break end
      local on, cur = cv.has[i], cv.cur == i
      local hb = not drag and mx >= tx and mx < tx + cbw and my >= y and my < y + L.rh - 2
      set(hb and U.tint(U.AMBER, 0.35) or (cur and U.tint(U.CYAN, 0.35) or (on and U.tint(U.CYAN, 0.12) or U.PANEL))); gfx.rect(tx, y, cbw, L.rh - 2, 1)
      set(hb and U.AMBER or (on and U.CYAN or U.DIM)); gfx.rect(tx, y, cbw, L.rh - 2, 0)
      text(tx + L.pad, y, tostring(i), hb and U.AMBER or (on and U.TEXT or U.GREY))
      if hb then hover.dspbtn = { fx = k, f = f, what = 'cvar', i = i } end
      if D.hint then D.hint('dspbtn', tx, y, cbw, L.rh - 2, { fx = k, what = 'cvar', i = i }) end
      tx = tx + cbw + 1
    end
  end
  y = y + L.rh + 1
  local full = ymax
  local hy = math.max(y + 4 * L.rh, math.floor((y + full) / 2))   -- строка переключателя — граница половин
  if hy + L.rh > full then hy = full - L.rh end
  ymax = hy - 2
  local x, w = x0, w0
  local function btn(bx0, lbl, what, extra)
    local w2 = ms(lbl) + 2 * L.pad
    local hb = not drag and mx >= bx0 and mx < bx0 + w2 and my >= y and my < y + L.rh
    local on = extra and extra.on
    set(hb and U.tint(U.AMBER, 0.35) or (on and U.tint(extra.col or U.AMBER, 0.3) or U.BG)); gfx.rect(bx0, y, w2, L.rh - 1, 1)
    set(hb and U.AMBER or (on and (extra.col or U.AMBER) or U.LINE)); gfx.rect(bx0, y, w2, L.rh - 1, 0)
    text(bx0 + L.pad, y, lbl, hb and U.AMBER or (on and (extra.col or U.AMBER) or U.GREY))
    if hb then hover.dspbtn = { fx = k, f = f, what = what, ki = extra and extra.ki } end
    if D.hint then D.hint('dspbtn', bx0, y, w2, L.rh - 1, { fx = k, what = what }) end
    return bx0 + w2 + 2
  end
  -- 24 окт: таблица как Chain List в Drum Rack (Ableton): заголовки колонок Chain | Mix, строка на цепь —
  -- имя (щелчок — курсор DSP на её модуль, выбранная — подложкой), Mix — поле с заливкой (Wet цепи: тянуть
  -- по горизонтали, щелчок — сразу туда), m (выкл.), s (только она)
  local non = 0
  for _, c in ipairs(chains) do
    c.on = false
    for _, kd in ipairs(c.kds) do if kd.enabled then c.on = true end end
    if c.on then non = non + 1 end
  end
  local sw = ms('s') + 2 * L.pad
  local vbw = ms('100%') + 2 * L.pad
  local bxs = x + w - 2 * sw - 2
  local vbx = bxs - vbw - 3
  local nw = vbx - x - 3
  text(x, y, fit('chain', nw), U.DIM); text(vbx + L.pad, y, 'mix', U.DIM)
  y = y + L.rh
  -- 28 окт: список цепей — в своём окошке (тёмный фон, рамка): видно, что это список
  local wy0 = y - 1
  local nrows = 0; for _, c in ipairs(chains) do nrows = nrows + 1 + #c.kds end   -- 31 окт: и модули цепей
  local wy1 = math.min(ymax, y + nrows * (L.rh + 1) + 1)
  set(U.BG); gfx.rect(x - 2, wy0, w + 4, wy1 - wy0, 1)
  for ci, c in ipairs(chains) do
    if y + L.rh > ymax then break end
    local kd = c.kd
    local selk = false
    for _, kk in ipairs(c.kds) do if D.sel_i == kk.i then selk = true end end
    local nhot = not drag and mx >= x and mx < x + nw and my >= y and my < y + L.rh
    -- 31 окт: цепь выделена своим цветом (строка и её модули), выключенная — серым
    local ccol = (D.chain_col and D.chain_col(f, (kd.entry and kd.entry.inner and kd.entry.inner.lane) or ci)) or lane_col((kd.entry and kd.entry.inner and kd.entry.inner.lane) or ci)
    if not c.on then ccol = U.DIM end
    set(U.tint(ccol, selk and 0.45 or (nhot and 0.35 or 0.25))); gfx.rect(x, y, nw, L.rh - 1, 1)
    if D.ckb and D.ckb.k == k and D.ckb.ki == c.ki then set(D.CUR_ACC or U.AMBER); gfx.rect(x - 1, y - 1, w + 2, L.rh + 1, 0) end   -- 29 окт: курсор клавиатуры CHAINS
    -- 28 окт: ветка — полоска её цвета слева (тот же цвет, что черта под модулем)
    -- цвет цепи (тот же, что черта под её модулями): номер потока
    local lane = (kd.entry and kd.entry.inner and kd.entry.inner.lane) or ci
    set(c.on and ((D.chain_col and D.chain_col(f, lane)) or lane_col(lane)) or U.DIM); gfx.rect(x, y, 3, L.rh - 1, 1)
    local nms = {}
    for _, kk in ipairs(c.kds) do nms[#nms + 1] = kk.name or '?' end
    text(x + L.pad + 2, y, fit(('chain %d  %d fx'):format(ci, #c.kds), nw - 2 * L.pad - 2), selk and U.TEXT or (c.on and U.TEXT or U.GREY))   -- модули — строками ниже
    if nhot then hover.dspbtn = { fx = k, f = f, what = 'cjump', ki = c.ki, kid = kd, kis = c.kis } end
    if D.hint then D.hint('dspbtn', x, y, nw, L.rh - 1, { fx = k, what = 'cjump' }) end
    local v = kd.wet_i and info.fxp_get and info.fxp_get(kd.i, kd.wet_i) or nil
    if v then
      local shot = not drag and mx >= vbx and mx < vbx + vbw and my >= y and my < y + L.rh
      set(U.BG); gfx.rect(vbx, y, vbw, L.rh - 1, 1)
      set(shot and U.tint(U.AMBER, 0.45) or U.tint(kd.enabled and U.CYAN or U.GREY, 0.35)); gfx.rect(vbx, y, math.max(1, math.floor(v * vbw + 0.5)), L.rh - 1, 1)
      set(shot and U.AMBER or U.LINE); gfx.rect(vbx, y, vbw, L.rh - 1, 0)
      local vs = math.floor(v * 100 + 0.5) .. '%'
      text(vbx + math.floor((vbw - ms(vs)) / 2), y, vs, shot and U.AMBER or U.TEXT)
      if shot then hover.cslide = { fx = kd.i, idx = kd.wet_i, x = vbx, w = vbw, name = (kd.name or 'chain') .. ' mix' } end
      if D.hint then D.hint('dspbtn', vbx, y, vbw, L.rh, { fx = k, what = 'cslide' }) end
    end
    local bx2 = btn(bxs, 'm', 'cmute', { ki = c.ki, on = not c.on, col = U.RED })
    btn(bx2, 's', 'csolo', { ki = c.ki, on = c.on and non == 1 and #chains > 1, col = U.GREEN })
    y = y + L.rh + 1
    -- 31 окт: модули цепи — строками с отступом: щелчок — курсор DSP на модуль (двойной — DSP), m — выкл. модуль
    for _, kk in ipairs(c.kds) do
      if y + L.rh > ymax then break end
      local fhot = not drag and mx >= x and mx < x + nw and my >= y and my < y + L.rh
      local fsel = D.sel_i == kk.i
      set(U.tint(ccol, fsel and 0.35 or (fhot and 0.2 or 0.1))); gfx.rect(x + 2 * L.pad, y, nw - 2 * L.pad, L.rh - 1, 1)
      set(ccol); gfx.rect(x, y, 3, L.rh - 1, 1)   -- полоска цвета цепи и у её модулей
      text(x + 3 * L.pad, y, fit(kk.name or '?', nw - 4 * L.pad), kk.enabled and (fsel and U.TEXT or U.GREY) or U.DIM)
      if fhot then hover.dspbtn = { fx = k, f = f, what = 'cjump', kid = kk } end
      btn(bxs, 'm', 'cfxm', { ki = kk.i, on = not kk.enabled, col = U.RED })
      y = y + L.rh + 1
    end
  end
  set(U.LINE); gfx.rect(x - 2, wy0, w + 4, math.max(2, y - wy0 + 1), 0)
  y = y + 3
  -- 25 окт: две цепи — кроссфейд одной ручкой нативно: mix второй цепи следует за mix первой с −100 % (база 1)
  -- 28 окт: кнопка A<>B (было x-fade — путалось с кроссфейдом нот); горит, когда связь стоит; щелчок — вкл / выкл;
  -- объяснение — в статусе при наведении
  if #chains == 2 and y + L.rh <= ymax then
    local c2 = chains[2].kd
    local on = false
    for _, l in ipairs(info.links_of and tr0_of(info) and info.links_of(tr0_of(info), f) or {}) do
      if l.t == c2.i and l.tp == c2.wet_i then on = true end
    end
    local b1 = btn(x, on and 'A<>B on' or 'A<>B', 'cxfade', { on = on })
    if on then text(b1 + L.pad, y, fit('mix of ' .. (chains[1].kd.name or '1'), x + w - b1 - L.pad), U.DIM) end
    y = y + L.rh + 2
  end
  -- связи «параметр следует за параметром» (нативный Link): строка — кто за кем и сила, справа — график зависимости
  local links = info.links_of and tr0_of(info) and info.links_of(tr0_of(info), f) or {}
  if #links > 0 and y + 2 * L.rh <= ymax then
    y = y + 2
    set(U.LINE); gfx.rect(x, y + L.rh - 2, w, 1, 1)
    text(x, y, 'LINKS', U.AMBER)
    y = y + L.rh
    local gw = 2 * L.rh
    for _, l in ipairs(links) do
      if y + L.rh > ymax then break end
      local hot = not drag and mx >= x and mx < x + w and my >= y and my < y + L.rh
      local amt = (' %+d%%'):format(math.floor(l.sc * 100 + 0.5))
      local aw = ms(amt)
      text(x, y, fit((l.tpname or '?') .. ' <- ' .. (l.spname or '?'), w - gw - aw - 2 * L.pad), hot and U.AMBER or U.TEXT)
      text(x + w - gw - aw - L.pad, y, amt, l.sc < 0 and U.RED or U.CYAN)
      -- график: по X — ведущий 0..1, по Y — ведомый (база + сила × ведущий, обрезка 0..1)
      local gx, gy, gh = x + w - gw, y + 1, L.rh - 3
      set(U.PANEL); gfx.rect(gx, gy, gw, gh, 1); set(U.LINE); gfx.rect(gx, gy, gw, gh, 0)
      local function Y(v) return gy + gh - 1 - math.floor(math.max(0, math.min(1, v)) * (gh - 1) + 0.5) end
      set(U.CYAN)
      local px, py
      for i = 0, gw - 1 do
        local xv = i / (gw - 1)
        local yy = Y(l.base + l.sc * xv)
        if px then gfx.line(px, py, gx + i, yy) end
        px, py = gx + i, yy
      end
      if hot then hover.dspbtn = { fx = k, f = f, what = 'linkrow', link = l } end
      y = y + L.rh
    end
  end
  -- 29 окт: переключатель ROUTE | XY — внизу половины цепей
  set(U.LINE); gfx.rect(x0, hy - 1, w0, 1, 1)
  local tx2 = x0
  for _, t in ipairs({ { 'route', 'ROUTE' }, { 'xy', 'XY' } }) do
    local tw2 = ms(t[2]) + 2 * L.pad
    if tx2 + tw2 > x0 + w0 then break end
    local on = tab == t[1]
    local hb = not drag and mx >= tx2 and mx < tx2 + tw2 and my >= hy and my < hy + L.rh - 1
    if on then set(U.tint(U.AMBER, 0.25)); gfx.rect(tx2, hy, tw2, L.rh - 1, 1) end
    text(tx2 + L.pad, hy, t[2], (on or hb) and U.AMBER or U.GREY)
    if hb then hover.dspbtn = { fx = k, f = f, what = 'ctab', tab = on and 'none' or t[1], key = tkey } end
    tx2 = tx2 + tw2 + 2
  end
  return hy + L.rh, tab   -- низ переключателя — под ним ROUTE / XY (нижняя половина)
end
-- 23 окт: шапка эффекта внутри контейнера (цепь пэда, цепь полосы) — обычная шапка модуля: + O Δ B x справа
-- (узко — только B x); возвращает ширину под имя
-- 24 окт: ширины колонки макросов модуля: всё, полоса вкладок, панель macro, панель xy (0 — закрыта)
function D.mac_w(L, info, f)
  if not (f.nmacro and (not f.container or f.wrap)) then return 0, 0, 0, 0 end   -- 24 окт: и контейнер-рэк
  local nm = f.fxname or f.name
  local vt = L.th + 2 * L.pad + 2
  local mpw = (info.macfold and info.macfold[nm]) and 0 or (L.cw * 14 + 2 * L.pad)
  local xo = info.xyopen and info.xyopen[nm]
  if xo == nil then xo = f.wrap and true or false end   -- у контейнера XY раскрыт сразу
  local xpw = (xo and f.nmacro >= 2) and (L.cw * 14 + 2 * L.pad) or 0
  -- 24 окт: у контейнера подписи отделов горизонтально (заголовок строкой сверху), без полосы вкладок;
  -- сложенный отдел — узкий, по ширине своей подписи
  if f.wrap then
    vt = 0
    if mpw == 0 then mpw = ms('★') + 2 * L.pad + 2 end
    if xpw == 0 and f.nmacro >= 2 then xpw = ms('XY') + 2 * L.pad + 2 end
  end
  return vt + mpw + xpw, vt, mpw, xpw
end
-- 24 окт: XY-пэд модуля на макросах 1 и 2 (Surge M1 / M2 …): тянуть — оба сразу
function D.mac_xy(L, f, vals, x, y, w, h, k, drag, mx, my, hover)
  local qx, qy
  for pi, p in ipairs(f.params) do if p.mfader then if not qx then qx = pi elseif not qy then qy = pi end end end
  if not (qx and qy) then return end
  local side = math.max(L.rh * 2, math.min(w - 2 * L.pad, h - L.rh))
  local px0, py0 = x + math.floor((w - side) / 2), y
  local nx = vals[qx] and vals[qx].n or 0
  local ny = vals[qy] and vals[qy].n or 0
  set(U.PANEL); gfx.rect(px0, py0, side, side, 1)
  set(U.LINE); gfx.rect(px0, py0, side, side, 0)
  set(U.DIM); gfx.rect(px0 + math.floor(side / 2), py0, 1, side, 1); gfx.rect(px0, py0 + math.floor(side / 2), side, 1, 1)
  local dx, dy = px0 + math.floor(nx * (side - 1) + 0.5), py0 + math.floor((1 - ny) * (side - 1) + 0.5)
  if py0 + side + L.rh <= y + h + 2 then
    -- 25 окт: подпись — имена параметров (★ контейнера / макросы плагина), не M1 / M2
    local an = (f.params[qx].pinname or f.params[qx].mlabel or 'x'):sub(1, 6)
    local bn = (f.params[qy].pinname or f.params[qy].mlabel or 'y'):sub(1, 6)
    text(px0, py0 + side + 1, fit(('%s %d  %s %d'):format(an, math.floor(nx * 100 + 0.5), bn, math.floor(ny * 100 + 0.5)), side), U.GREY)
  end
  -- 28 окт: углы 1..4 — снимки всех параметров модуля (пусто — запомнить, полный — вызвать, Shift — перезаписать);
  -- шайба — по-прежнему два макроса
  local oncorner
  local si, sc   -- 29 окт: and срезал второе значение — sc = nil, угол не запоминался (ошибка snaps_of)
  if D.info and D.info.fx_snaps then si, sc = D.info.fx_snaps(f) end
  if si and side >= 4 * L.rh then
    local cbw = math.max(L.btn_w or 0, ms('4') + 6)
    local corners = { { px0 + 1, py0 + 1 }, { px0 + side - cbw - 1, py0 + 1 }, { px0 + 1, py0 + side - L.rh }, { px0 + side - cbw - 1, py0 + side - L.rh } }
    for i, c in ipairs(corners) do
      local on = si.has[i]
      local hot = not drag and mx >= c[1] and mx < c[1] + cbw and my >= c[2] and my < c[2] + L.rh - 1
      set(hot and U.tint(U.AMBER, 0.35) or (on and U.tint(U.CYAN, 0.35) or U.PANEL)); gfx.rect(c[1], c[2], cbw, L.rh - 1, 1)
      set(hot and U.AMBER or (on and U.CYAN or U.DIM)); gfx.rect(c[1], c[2], cbw, L.rh - 1, 0)
      text(c[1] + math.floor((cbw - ms(tostring(i))) / 2), c[2], tostring(i), hot and U.AMBER or (on and U.TEXT or U.GREY))
      if hot then hover.snapc = { col = sc, i = i }; oncorner = true end
    end
  end
  -- 29 окт: шайба — поверх цифр углов и в границах пэда (в углу — четверть круга)
  set(U.AMBER); D.disc_clip(dx, dy, math.max(3, math.floor(L.rh / 3)), px0, py0, px0 + side - 1, py0 + side - 1)
  if not oncorner and not drag and mx >= px0 and mx < px0 + side and my >= py0 and my < py0 + side then
    hover.dspxy = { fx = k, f = f, x = px0, y = py0, s = side, qx = qx, qy = qy }
  end
end
-- 29 окт: залитый круг, обрезанный прямоугольником (строками; gfx.circle не режется)
function D.disc_clip(cx, cy, r, x0, y0, x1, y1)
  for dy = -r, r do
    local yy = cy + dy
    if yy >= y0 and yy <= y1 then
      local hw = math.floor(math.sqrt(math.max(0, r * r - dy * dy)) + 0.5)
      local a, b = math.max(x0, cx - hw), math.min(x1, cx + hw)
      if b >= a then gfx.rect(a, yy, b - a + 1, 1, 1) end
    end
  end
end
function D.kid_head(L, info, cx, hy, w, kid, k, f, drag, mx, my, hover)
  local kb = ms('O') + 2 * L.pad
  local onw = ms('off') + 2 * L.pad   -- 24 окт: B → on / off (понятнее)
  local full = w - 2 * L.pad - 4 * kb - onw - 12 >= L.cw * 8
  local bs = { { 'x', 'kdel' }, { kid.enabled and 'on' or 'off', 'kbypass', onw } }
  if full then bs[3], bs[4], bs[5] = { '∆', 'kdelta' }, { 'e', 'kopen' }, { '+', 'klastp' } end
  local dl = full and info.fx_delta and info.fx_delta(kid)
  local x = cx + w - 1
  -- 24 окт: опция dspleft — кнопки сразу за именем
  local tot = 0
  for _, b in ipairs(bs) do tot = tot + (b[3] or kb) + 2 end
  local nw = math.max(L.cw, w - tot - 2 * L.pad - 1)
  -- 24 окт (вечер): кнопки эффекта в цепи — снова справа
  for _, b in ipairs(bs) do
    local kb = b[3] or kb
    x = x - kb - 2
    local hb = not drag and mx >= x and mx < x + kb and my >= hy and my < hy + L.rh
    local lit = (b[2] == 'kbypass' and not kid.enabled) or (b[2] == 'kdelta' and dl)
    local red = b[2] == 'kdel'
    set(hb and U.tint(red and U.RED or U.AMBER, 0.35) or (lit and U.tint(U.AMBER, 0.25) or U.BG)); gfx.rect(x, hy, kb, L.rh - 1, 1)
    set(hb and (red and U.RED or U.AMBER) or U.LINE); gfx.rect(x, hy, kb, L.rh - 1, 0)
    text(x + L.pad, hy, b[1], hb and (red and U.RED or U.AMBER) or (lit and U.AMBER or U.GREY))
    if hb then hover.dspbtn = { fx = k, f = f, what = b[2], kid = kid } end
  end
  return math.max(L.cw, x - cx - 2 * L.pad - 2)
end
function D.kid_pack(f, rows)
  local n = {}
  for _, p in ipairs(f.params or {}) do if p.kid and not p.macro then n[p.kid] = (n[p.kid] or 0) + 1 end end
  local place, col, used, prev_small = {}, -1, 0, false
  for ki, kid in ipairs(f.kids or {}) do
    local nk = n[ki] or 0
    local small = nk <= 5
    if ki > 1 and small and prev_small and (kid.parallel or 0) == 0 and used + 1 + nk <= rows then
      place[ki] = { c = col, hr = used, r0 = used + 1 }
      used = used + 1 + nk
    else
      col = col + 1
      place[ki] = { c = col, hr = -1, r0 = 0 }
      used = nk
    end
    prev_small = small
  end
  return place, col + 1
end
-- 22 окт: высота параметра DSP в строках: 5..8 положений — столбик кнопок (по строке на положение, имя
-- вертикально слева), если влезает по высоте; иначе одна строка (больше 8 — выпадашка)
function D.param_rows(p, nfit)
  if p and p.mfader then return 0 end   -- 22 окт: макрос — фейдером слева, строк не занимает
  local n = p and p.kind == 'steps' and p.nsteps or 0
  -- 23 окт: кнопки в две колонки, имя строкой сверху: 1 + ceil(n / 2) строк (6 положений — 4, было 6)
  local rows = 1 + math.ceil(n / 2)
  return (n >= 5 and n <= 8 and rows <= (nfit or 0)) and rows or 1
end
-- поток параметров по колонкам с учётом высоты и секций (heads[pi] — заголовок перед параметром: своя строка,
-- секция целиком переносится в новую колонку, если в ней помещается) → spos[pi] = { col, row, rows },
-- spos.heads[pi] = { col, row }; второе — число колонок
function D.param_flow(params, heads, nfit, col0)
  local spos, col, row = { heads = {} }, col0 or 0, 0
  for pi = 1, #params do
    if heads and heads[pi] then
      local n, j = D.param_rows(params[pi], nfit), 1
      while params[pi + j] and not heads[pi + j] do n = n + D.param_rows(params[pi + j], nfit); j = j + 1 end
      -- заголовок не остаётся внизу без своего первого параметра (столбик кнопок — тоже)
      if row > 0 and (row >= nfit - 1 or (row + 1 + n > nfit and 1 + n <= nfit) or row + 1 + D.param_rows(params[pi], nfit) > nfit) then col, row = col + 1, 0 end
      spos.heads[pi] = { col, row }
      row = row + 1
    end
    local hp = D.param_rows(params[pi], nfit)
    if row > 0 and row + hp > nfit then col, row = col + 1, 0 end
    spos[pi] = { col, row, hp }
    row = row + hp
  end
  return spos, col + 1 - (col0 or 0)
end
-- 22 окт: имя колонки под курсором (инфо у клавиатуры): MIDI-лейн (PB, CC74, cmd, chord, visor) и сложенный
-- трек — своим именем; было — по номеру поля, и курсор на PB показывал «note»
function D.cursor_field_name(f, vc)
  if not f then return '' end
  if f.env then return f.env.name or 'envelope' end
  if f.ml then return f.ml.name or f.ml.kind or 'lane' end
  if f.folded then return 'folded' end
  local sub = vc and vc.sub
  if sub == 'inst' then return 'inst' elseif sub == 'wave' then return 'wave' elseif sub == 'slc' then return 'slice' elseif sub == 'pan' then return 'pan' end
  local fld = (vc and vc.field) or 1
  return ({ 'note', 'vol', 'delay' })[fld] or ('fx ' .. (fld - 3))
end
function D.draw_mode(L, sx0, sy0, sw, str, dry)
  local mode = (str or ''):match('^([^|]*)') or ''
  -- 15 окт: набор команды / поиска — полем под курсором трекера; здесь только слово режима
  if mode:match('^%s*:') then mode = 'COMMAND' elseif mode:match('^%s*/') then mode = 'SEARCH' elseif mode:match('^%s*rename') then mode = 'RENAME' end
  mode = (mode or ''):gsub('%-%-', ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' ')
  if mode == 'MAIN' then mode = 'VIPER' end   -- 22 окт: MAIN → VIPER mode
  local reap0 = D.reap_glitch and mode:match('^REAPER') ~= nil   -- 16 окт: до обрезки по месту (REAP… тоже REAPER); 27 окт: полосатый — только с reaper glitch, иначе шрифтом режима
  -- 15 окт: цвет режима (D.MODE_COL), как у рамки поля; модуль в фокусе (LIB, UNDO…) — янтарный
  local MK = { INSERT = 'insert', VISUAL = 'visual', ['V-LINE'] = 'vline', COMMAND = 'cmd', SEARCH = 'search', RENAME = 'cmd', NORMAL = 'normal', KEYS = 'normal' }
  local mk = MK[mode:match('^[%u%-]+') or '']
  local col = mk and D.MODE_COL[mk] or U.AMBER
  local dx = sx0
  local sy = sy0
  local tr = D.modefont and D.MODE_SCRIPT[D.modefont]
  if tr and mode ~= '' then
    -- 15 окт: целиком (NOTE MOD), иначе первое слово (TOP:item, UNDO …)
    if tr[mode] then mode = tr[mode]
    else
      local w1 = mode:match('^([%u%-]+)')
      if w1 and tr[w1] then mode = tr[w1] .. mode:sub(#w1 + 1) end
    end
  end
  if D.modefont and mode ~= '' and not reap0 then   -- 16 окт: REAPER — всегда контрастным битмапом
    -- 13 окт: декоративный шрифт режима (опция mode font): высота — две строки, слово целиком
    local hpx = math.floor(3 * L.th * (D.MODE_FONT_SCALE[D.modefont] or 1))   -- 13 окт: в полтора раза крупнее (просьба)
    gfx.setfont(4, D.modefont, hpx)
    -- 18 окт: длинное слово (КЛАВИСИНЪ) — сначала мельче, до полутора строк; обрезка — только если и так не влезло
    while gfx.measurestr(mode) > math.floor(sw / 3) and hpx > math.floor(1.5 * L.th) do hpx = hpx - 1; gfx.setfont(4, D.modefont, hpx) end
    while mode ~= '' and gfx.measurestr(mode) > math.floor(sw / 3) do mode = mode:sub(1, (utf8.offset(mode, -1) or 1) - 1) end   -- по символам (UTF-8)
    local mw, mh = gfx.measurestr(mode)
    if not dry then set(col); gfx.x, gfx.y = sx0, sy + math.floor((2 * L.th - mh) / 2); gfx.drawstr(mode) end
    gfx.setfont(D.font_id)
    dx = sx0 + mw
    mode = ''
  end
  while mode ~= '' and D.big_measure(mode, 2) > math.floor(sw / 3) do mode = mode:sub(1, -2) end
  -- 16 окт: REAPER (клавиши у REAPER, не у трекера) — контрастно: белым на чёрном, чёрные косые полоски поверх
  local reap = reap0
  if mode ~= '' then
    if not dry then
      if reap then
        -- 16 окт: «разодрано» (так и задумано, пользователь: «пусть и будет»): белым на чёрном, чёрные косые полосы поверх
        local bw2 = D.big_measure(mode, 2)
        set({ 0, 0, 0 }); gfx.rect(sx0 - 2, sy - 1, bw2 + 4, 2 * L.th + 2, 1)
        D.big_text(sx0, sy, mode, { 1, 1, 1 }, 2)
        set({ 0, 0, 0 })
        for k = -2 * L.th, bw2 + 2 * L.th, 5 do
          for t = 0, 1 do gfx.line(sx0 + k + t, sy + 2 * L.th, sx0 + k + t + 2 * L.th, sy) end
        end
        set({ 1, 1, 1 }); gfx.rect(sx0 - 2, sy - 1, bw2 + 4, 2 * L.th + 2, 0)
      else D.big_text(sx0, sy, mode, col, 2) end
    end
    dx = sx0 + D.big_measure(mode, 2)
  end
  return dx - sx0, 2 * L.th
end

-- 15 окт: строка ввода (:команда, /поиск, переименование) — полем под курсором трекера, не в статусе;
-- a = { x, y } — место; → высота поля (всплывашка подсказок — ниже него)
function D.input_line(L, a, str)
  if not (a and str and str ~= '') then return 0 end
  local w = math.min(gfx.w - a.x - L.pad, math.max(ms(str) + 3 * L.pad, L.cw * 40))
  local x = math.max(L.pad, math.min(gfx.w - w - L.pad, a.x))
  local h = L.rh + 4
  set(U.BG); gfx.rect(x, a.y, w, h, 1)
  set(U.AMBER); gfx.rect(x, a.y, w, h, 0)
  text(x + L.pad, a.y + 2, fit(str .. '_', w - 2 * L.pad), U.TEXT)
  return h
end

-- тонкий вертикальный скролл-бар списка (4 окт): матрица, lib, браузер.
-- key — чей; scroll / nvis / total — строки; рисуется, только если не всё
-- влезло. D.vbars[key] — прямоугольник для мыши (main: клик / протяжка)
D.vbars = {}
-- 8 окт: толщина одна на все скроллбары (опция scrollbar width, по умолчанию
-- 3 px), прижаты к правому / нижнему краю отведённого места; чуть ярче
function D.vbar(key, x, y, w, h, scroll, nvis, total)
  D.vbars[key] = nil
  local sw = D.SBW or 3; x = x + w - sw - 1; w = sw     -- на пиксель от края: не сливается с линией модуля
  if total <= nvis or h < 8 then return end
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local th = math.max(6, math.floor(h * nvis / total))
  local ty = y + math.floor((h - th) * math.min(1, scroll / math.max(1, total - nvis)))
  local hot = mx >= x - 6 and mx < x + w + 4 and my >= y and my < y + h   -- 23 окт: зона шире — мышь попадает
  local drag = D.vbar_drag and D.vbar_drag.key == key
  -- 8 окт: без дорожки во всю высоту — она рядом с границей модуля давала
  -- двойную линию; только ползунок; 23 окт: под мышью — толще и янтарём (видно, что возьмётся)
  local gw = (hot or drag) and (w + 2) or w
  set((hot or drag) and U.AMBER or U.GREY); gfx.rect(x - (gw - w), ty, gw, th, 1)
  D.vbars[key] = { x = x + (D.pn_ox or 0), y = y, w = w, h = h, nvis = nvis, total = total, hot = hot, ty = ty, th = th, a0 = y, alen = h }
end
-- горизонтальная полоса (5 окт, матрица): та же запись, ось x
function D.hbar(key, x, y, w, h, scroll, nvis, total)
  D.vbars[key] = nil
  local sw = D.SBW or 3; y = y + h - sw - 1; h = sw
  if total <= nvis or w < 8 then return end
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local tw = math.max(6, math.floor(w * nvis / total))
  local tx = x + math.floor((w - tw) * math.min(1, scroll / math.max(1, total - nvis)))
  local hot = mx >= x and mx < x + w and my >= y - 6 and my < y + h + 4   -- 23 окт: зона шире
  local drag = D.vbar_drag and D.vbar_drag.key == key
  local gh = (hot or drag) and (h + 2) or h
  set((hot or drag) and U.AMBER or U.GREY); gfx.rect(tx, y - (gh - h), tw, gh, 1)
  local ox = D.pn_ox or 0   -- 23 окт: экранные x (лист панели в буфере со сдвигом): протяжка сравнивает с экранной мышью
  D.vbars[key] = { horiz = true, x = x + ox, y = y, w = w, h = h, nvis = nvis, total = total, hot = hot, ty = tx + ox, th = tw, a0 = x + ox, alen = w }
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
  -- 11 окт: save — в меню kit (одно место); sort — выпадашка (не перебор по кругу: положений больше двух)
  -- bsync: beatsync выбранного инструмента — длина под N долей темпа в месте
  -- каждой ноты; горит, когда включён
  local on = cur and cur.bsync
  local blbl = on and ('bsync %d'):format(on) or 'bsync'
  local bw2 = ms(blbl) + 2 * L.pad
  local bx2 = fx - bw2 - L.pad
  hbtn(bx2, bw2, blbl, on and true or false, U.CYAN, 'poolbsync')
  local sw2 = ms('sort') + 2 * L.pad
  local sx2 = bx2 - sw2 - L.pad
  if sx2 > ix + L.pad + ms('kit') + 2 * L.pad then hbtn(sx2, sw2, 'sort', false, U.CYAN, 'poolsort'); bx2 = sx2 end
  -- 11 окт: пресет lib — справа, как у эффекта в DSP: < имя > (имя — список и сохранить, < > — соседний; заменяет всю lib)
  do
    local nm = info.kit_name or 'no preset'
    local aw = ms('<') + 2
    -- 11 окт: load — слева от пресета: выпадашка китов, кит ДОБАВЛЯЕТСЯ в lib
    local lw3 = ms('load') + 2 * L.pad
    local lx3 = ix + L.pad
    hbtn(lx3, lw3, 'load', false, U.CYAN, 'poolload')
    local room = bx2 - L.pad - (lx3 + lw3 + L.pad)
    local ptw = math.min(ms('< ' .. nm .. ' >') + L.pad, room)
    if ptw > ms('<>') + ms('pre') then
      local px = bx2 - L.pad - ptw
      local parts = { { '<', 'poolpprev', px, aw }, { nm, 'poolkit', px + aw, ptw - 2 * aw }, { '>', 'poolpnext', px + ptw - aw, aw } }
      for _, pp in ipairs(parts) do
        local hot = mx >= pp[3] and mx < pp[3] + pp[4] and my >= by0 and my < by0 + L.rh
        if hot then set(U.tint(U.AMBER, 0.3)); gfx.rect(pp[3], by0, pp[4], L.rh, 1); hover[pp[2]] = true end
        text(pp[3] + (pp[2] == 'poolkit' and 2 or 1), iy + 3, fit(pp[1], pp[4] - 2), hot and U.AMBER or (pp[2] == 'poolkit' and (info.kit_name and U.CYAN or U.GREY) or U.GREY))
        hint(pp[2], pp[3], by0, pp[4], L.rh, true)
      end
    end
  end
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
    -- 12 окт: insert (играть при вставке) переехал в транспорт — кнопка hear у step / inst / LPB
    -- swap (3 окт): звук инструмента ↔ файл, выбранный в браузере; горит — подменён
    if info.swap_state then tbtn('swap', info.swap_state() == 'on', 'swapbtn') end
  end
  -- 13 окт: вид tracks во вкладке lib — дерево трек → инструменты → слайсы / automation / MIDI,
  -- неиспользованные — в lib/; кнопки шапки lib (load, пресет, track, sort, bsync, find) остаются
  if info.lib_tree then
    local ty = iy + L.rh + 4
    info.lib_tree(ix + 1, ty, w - 2, iy + H - L.rh - 5 - ty)
    return
  end
  local rows = D.pool_rows(pool, sort, col, info.cols)
  -- 9 окт: инструменты-плагины трека (VSTi / AUi / CLAPi, JSFX-инструменты) —
  -- своя секция с номерами после сэмплов; выбран — клавиши пишут MIDI-ноты в
  -- него. automation — самой последней строкой, со своим номером
  local nsamp = #pool + D.empty_slots(#pool)
  local tins = info.track_insts and info.track_insts(col) or {}
  -- 10 окт: инструменты — все проектные: свои (трека курсора) с номерами, чужие — с именем трека,
  -- щелчок переводит курсор на тот трек; automation и midi — своими секциями, как instruments
  -- 20 окт: порядок — по трекам проекта, постоянный (свои больше не поднимаются наверх: список дёргался при смене трека)
  -- 21 окт: номера — сквозные по трекам проекта (и у чужих: номер ведёт курсор на их трек), как в REAPER;
  -- показ — подряд за видимыми сэмплами и пустыми слотами (скрытые слайсы пула номеров не занимают)
  do local nr = 0; for _, e in ipairs(pool) do if not e.parent then nr = nr + 1 end end; nsamp = nr + D.empty_slots(#pool) end
  local inst_rows, own_done = {}, false
  local gn = 0
  local function add_own() for k, fi in ipairs(tins) do inst_rows[#inst_rows + 1] = { instfx = fi.fx, name = fi.name, kind = fi.kind, num = nsamp + gn + k } end; gn = gn + #tins; own_done = true end
  if info.track_insts then
    for _, c in ipairs(info.cols or {}) do
      if c == col or c.track == (col and col.track) then if not own_done then add_own() end
      else
        for _, fi in ipairs(info.track_insts(c)) do gn = gn + 1; inst_rows[#inst_rows + 1] = { instfx = fi.fx, name = fi.name, kind = c.name or fi.kind, col = c, num = nsamp + gn } end
      end
    end
  end
  if not own_done then add_own() end
  if #inst_rows > 0 then rows[#rows + 1] = { hdr = 'instruments', name = '' } end
  for _, o in ipairs(inst_rows) do rows[#rows + 1] = o end
  rows[#rows + 1] = { hdr = 'automation', name = '' }
  rows[#rows + 1] = { auto = true, num = nsamp + gn + 1 }   -- automation как инструмент (5 окт); 21 окт: после всех инструментов проекта
  rows[#rows + 1] = { hdr = 'midi', name = '' }
  rows[#rows + 1] = { midi = true, num = nsamp + gn + 2 }   -- MIDI-клипы трека / проекта (10 окт)
  -- 10 окт: секции audio / instruments / automation / midi; опция lib tabs — вкладками (F4),
  -- иначе разделителями с пустой строкой перед каждой
  local SECS = { instruments = true, automation = true, midi = true }
  do
    local sec, out = 'audio', {}
    for _, row in ipairs(rows) do
      if row.hdr and SECS[row.hdr] then sec = row.hdr end
      row.sec = sec
    end
    if info.libtabs then
      local want = info.libtab or 'audio'
      for _, row in ipairs(rows) do
        if row.sec == want and not (row.hdr and (SECS[row.hdr] or row.hdr == 'audio')) then out[#out + 1] = row end
      end
    else
      for i, row in ipairs(rows) do
        if row.hdr and SECS[row.hdr] and i > 1 then out[#out + 1] = { gap = true, sec = row.sec } end
        out[#out + 1] = row
      end
    end
    rows = out
  end
  -- 19 окт: lib как в lf — инструмент со слоями / слайсами — папка (+ / -), открыт — дети строками под ним
  do
    D.LIBO = D.LIBO or {}
    local out = {}
    for _, row in ipairs(rows) do
      out[#out + 1] = row
      local e = row.i and not row.sub and pool[row.i]
      if e and not e.parent and D.LIBO[e.gkey or ''] then
        for lk = 1, #(e.layers or {}) do out[#out + 1] = { sub = 'y', i = row.i, k = lk, sec = row.sec } end
        for sk = 1, #(e.slices or {}) do out[#out + 1] = { sub = 's', i = row.i, k = sk, sec = row.sec } end
      end
    end
    rows = out
  end
  L.pool_rows = rows
  -- 10 окт: хинты включены — сверху строка-расшифровка пометок lib
  local LEG = (L.hint_h or 0) > 0 and L.rh or 0
  local TBH = info.libtabs and (L.rh + 2) or 0             -- строка вкладок lib
  local nvis = math.max(1, math.floor((H - 3 * L.rh - 6 - LEG - TBH) / L.rh))
  -- прокрутка: выбранный инструмент (и его заголовок группы) в окне
  local sel_r = 1
  for r, row in ipairs(rows) do if (not info.auto_inst and not info.midi_inst and (row.i == inst or row.empty == inst or (cur and cur.parent and pool[row.i or 0] == cur.parent))) or (info.auto_inst and row.auto) or (info.midi_inst and row.midi) then sel_r = r end end
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
  -- колонка ~ (9 окт): у item есть точки в огибающих take — щелчок открывает
  -- их во вкладке automation; место — только если такой item есть
  local TILDE = D.ttf and '∿' or '~'
  local tew = 0
  if info.pool_tenv then
    for _, e in pairs(pool) do if type(e) == 'table' and info.pool_tenv(e) > 0 then tew = ms(TILDE) + 2 * L.pad; break end end
  end
  -- заголовки колонок (3 окт): # (порядок: дерево треков / метки), name, len,
  -- preview; клик — сортировка, активная — янтарём
  do
    local hy2 = iy + 2 + L.rh
    local XPW, XBW = ms('-12.5') + L.pad, ms('16b') + L.pad   -- 19 окт: колонки pt (транспозиция) и bs (beatsync)
    local cols_h = { { '#', ix + 6, sort == 'track' or sort == 'mark', sort == 'mark' and '#@' or '#', 'index' },
                     { 'name', ix + 6 + ms('00+ 16$ '), sort == 'name', 'name', 'name' },   -- 26 окт: над именами (после «01+ 16$»)
                     -- 26 окт: len / pt / bs — по правому краю, как их значения (6-е поле — правый край)
                     { 'len', ix + 6 + label_w + L.pad, sort == 'len', 'len', 'len', ix + 6 + label_w + L.pad + ms('88.88s') },
                     { 'pt', ix + 6 + label_w + L.pad + ms('88.88s') + L.pad, false, 'pt', nil, ix + 6 + label_w + L.pad + ms('88.88s') + L.pad + XPW - L.pad },
                     { 'bs', ix + 6 + label_w + L.pad + ms('88.88s') + L.pad + XPW, false, 'bs', nil, ix + 6 + label_w + L.pad + ms('88.88s') + L.pad + XPW + XBW - L.pad } }
    if tew > 0 then cols_h[#cols_h + 1] = { '~', ix + 6 + label_w + L.pad + ms('88.88s') + 2 * L.pad + XPW + XBW, false, TILDE, nil } end
    cols_h[#cols_h + 1] = { 'preview', ix + 6 + label_w + L.pad + ms('88.88s') + L.pad + XPW + XBW + tew, false, 'preview', nil }
    -- type (9 окт): у правого края строки заголовков — сортировка по типу
    local tyw = ms('type')
    local tyx = ix + w - L.pad - 4 - tyw
    local prevx = cols_h[#cols_h][2] + ms(cols_h[#cols_h][4]) + L.pad
    if tyx >= prevx then
      local hot = mx >= tyx and mx < tyx + tyw and my >= hy2 and my < hy2 + L.rh
      text(tyx, hy2, 'type', sort == 'type' and U.AMBER or (hot and U.TEXT or U.GREY))
      if hot then hover.poolsortcol = 'type' end
      hint('poolsortcol', tyx, hy2, tyw, L.rh, 'type')
    end
    for k, h2 in ipairs(cols_h) do
      local x1 = cols_h[k + 1] and cols_h[k + 1][2] or (ix + w - L.pad)
      if h2[2] + ms(h2[4]) <= x1 then
        local hot = h2[5] and mx >= h2[2] and mx < x1 and my >= hy2 and my < hy2 + L.rh
        text(h2[6] and (h2[6] - ms(h2[4])) or h2[2], hy2, h2[4], h2[3] and U.AMBER or (hot and U.TEXT or U.GREY))
        if hot then hover.poolsortcol = h2[5] end
        if h2[5] then hint('poolsortcol', h2[2], hy2, x1 - h2[2], L.rh, h2[5]) end
      end
    end
    set(U.DIM); gfx.rect(ix + 2, hy2 + L.rh - 1, w - 4, 1, 1)
  end
  if TBH > 0 then
    -- вкладки lib (10 окт): как вкладки панелей — рамками встык, активная янтарём
    local ty = iy + 2 + 2 * L.rh + LEG
    local tx = ix + 2
    for _, nm in ipairs({ 'audio', 'instruments', 'automation', 'midi' }) do
      local tw2 = ms(nm) + 2 * L.pad
      if tx + tw2 > ix + w - 2 then break end
      local on = (info.libtab or 'audio') == nm
      local hot = mx >= tx and mx < tx + tw2 and my >= ty and my < ty + L.rh
      set(on and U.tint(U.AMBER, 0.25) or (hot and D.CURROW or U.BG)); gfx.rect(tx, ty, tw2, L.rh, 1)
      set(on and U.AMBER or U.LINE); gfx.rect(tx, ty, tw2, L.rh, 0)
      text(tx + L.pad, ty, nm, on and U.AMBER or (hot and U.TEXT or U.GREY))
      if hot then hover.libtab = nm end
      hint('libtab', tx, ty, tw2, L.rh, nm)
      tx = tx + tw2 - 1
    end
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
    local y = iy + 2 + 2 * L.rh + LEG + TBH + (r - D.pool_scroll - 1) * L.rh
    if row.gap then
      -- пустая строка перед секцией
    elseif row.hdr then
      local hrgb = trgb[row.name] or U.LINE
      set(hrgb); gfx.rect(ix + 2, y + 1, 2, L.rh - 2, 1)
      -- 26 окт: значок типа — в заголовке раздела, не в каждой строке
      local glyph = ({ audio = '@ ', instruments = '# ', midi = D.mu() .. ' ', automation = '~ ' })[row.hdr] or ''
      local tw = ms(glyph .. row.hdr)
      local hcol = U.TEXT
      if row.folder then   -- 27 окт: заголовок папки lib — щелчок сворачивает / разворачивает; курсор в свёрнутой — подсветка
        local hot = mx >= ix and mx < ix + w and my >= y and my < y + L.rh
        local here = false
        if D.LIBF and D.LIBF[row.folder] then for _, i in ipairs(row.members or {}) do if i == inst then here = true end end end
        if D.lib_hdr == row.folder then here = true end   -- 27 окт: курсор на самом имени папки (j k)
        if here then set(U.tint(U.AMBER, 0.30)); gfx.rect(ix + 1, y, w - 2, L.rh, 1); hcol = U.AMBER
        elseif hot then set(U.tint(U.AMBER, 0.15)); gfx.rect(ix + 1, y, w - 2, L.rh, 1) end
        if hot then hover.libdirh = row.folder end
      end
      text(ix + 6, y + 1, fit(glyph .. row.hdr, w - 12), hcol)
      -- разделитель: длинная линия после имени
      set(U.LINE); gfx.rect(ix + 6 + tw + L.pad, y + math.floor(L.rh / 2), w - 8 - tw - 2 * L.pad, 1, 1)
    elseif row.auto then
      local sel = info.auto_inst
      local hot = mx >= ix and mx < ix + w and my >= y and my < y + L.rh
      if sel then set(U.tint(U.AMBER, 0.30)); gfx.rect(ix + 1, y, w - 2, L.rh, 1) end
      text(ix + 6, y + 1, fit(('%02d    automation'):format(row.num or 0) .. (info.auto_n and (' /' .. info.auto_n) or ''), w - 12), sel and U.AMBER or U.GREY)
      if hot then hover.pool = { ci = info.pool_ci, auto = true } end
      hint('pool', ix + 2, y, w - 4, L.rh, 'auto')
    elseif row.sep then
      -- разделитель (10 окт): узор на ширину строки, тускло; ПКМ — сменить / убрать
      local hot = mx >= ix and mx < ix + w and my >= y and my < y + L.rh
      local nch = math.max(1, math.floor((w - 12) / math.max(1, ms('-'))))
      text(ix + 6, y + 1, fit(D.sep_line(row.sep, nch), w - 12), hot and U.GREY or U.DIM)
      if hot then hover.pool = { ci = info.pool_ci, sep = row.key } end
    elseif row.midi then
      local sel = info.midi_inst
      local hot = mx >= ix and mx < ix + w and my >= y and my < y + L.rh
      if sel then set(U.tint(U.AMBER, 0.30)); gfx.rect(ix + 1, y, w - 2, L.rh, 1) end
      text(ix + 6, y + 1, fit(('%02d    midi clips'):format(row.num or 0) .. (info.midi_n and (' /' .. info.midi_n .. ' ' .. (info.midi_scope or '')) or ''), w - 12), sel and U.AMBER or U.GREY)
      if hot then hover.pool = { ci = info.pool_ci, midi = true } end
      hint('pool', ix + 2, y, w - 4, L.rh, 'midi')
    elseif row.instfx then
      local rc = row.col or col
      local sel = info.inst_fx and info.inst_fx(rc) == row.instfx and not row.col
      local hot = mx >= ix and mx < ix + w and my >= y and my < y + L.rh
      if sel then set(U.tint(U.CYAN, 0.30)); gfx.rect(ix + 1, y, w - 2, L.rh, 1)
      elseif hot then set(D.CURROW); gfx.rect(ix + 1, y, w - 2, L.rh, 1) end
      local kd = row.kind or 'fx'
      if kd == 'kit' then kd = '#' end                   -- 16 окт: # — drumrs5k / кит RS5K
      if row.col and row.col.rgb then set(row.col.rgb); gfx.rect(ix + 2, y + 1, 2, L.rh - 2, 1) end   -- чужой трек — его цветом
      local kw = math.min(ms(kd), math.floor(w * 0.35))
      text(ix + 6, y + 1, fit((row.num and ('%02d '):format(row.num) or '-- ') .. row.name, w - 12 - kw - L.pad), sel and U.CYAN or (row.col and U.GREY or U.TEXT))
      text(ix + w - L.pad - 4 - kw, y + 1, fit(kd, kw), sel and U.CYAN or U.GREY)
      if hot then hover.pool = { ci = info.pool_ci, instfx = row.instfx, col = row.col } end
      hint('poolinst', ix + 2, y, w - 4, L.rh, row.instfx)
    elseif row.sub then
      -- 19 окт: ребёнок папки lib: слой ¥ (имя его сэмпла, сдвиг, громкость, флаги) или слайс (клавиша, Sxx, длина)
      local e = pool[row.i]
      local hot = mx >= ix and mx < ix + w and my >= y and my < y + L.rh
      local cs = D.LIBSUB
      local on = cs and cs.i == row.i and cs.kind == row.sub and cs.k == row.k
      if on then set(U.tint(U.AMBER, 0.30)); gfx.rect(ix + 1, y, w - 2, L.rh, 1) elseif hot then set(D.CURROW); gfx.rect(ix + 1, y, w - 2, L.rh, 1) end
      local lbl
      if row.sub == 'y' then
        local l = e.layers and e.layers[row.k]
        local src = l and info.layer_src and info.layer_src(l.guid)
        local fl = l and ((l.mute and ' m' or '') .. (l.phase and ' p' or '') .. ((l.cn or 1) > 1 and (' %d/%d'):format(l.ck, l.cn) or '')) or ''
        lbl = l and ('¥ L%d %s  %+gms %+gdB%s'):format(row.k, src and src.name or '?', l.offs or 0, l.vol or 0, fl) or '¥ ?'
      else
        local t0 = e.slices and e.slices[row.k] or 0
        local t1 = e.slices and (e.slices[row.k + 1] or e.len) or t0
        local nl = info.slice_note and info.slice_note(row.k) or '---'   -- 19 окт: нота слайса вместо клавиши
        lbl = ('%-3s  S%02X'):format(nl or '---', row.k)
        -- 19 окт: длина, pt, bs — в колонках инструмента (под len / pt / bs); pt — свой у ноты-слайса в lib, иначе инструмента
        local dx = ix + 6 + label_w + L.pad
        local dw = ms('88.88s') + L.pad
        if w - (dx - ix) - L.pad > dw + 8 then
          local len = math.max(0, t1 - t0)
          local ds = len < 10 and ('%.2fs'):format(len) or ('%.1fs'):format(len)
          text(dx + dw - L.pad - ms(ds), y + 1, ds, on and U.AMBER or U.GREY)
          local XPW, XBW = ms('-12.5') + L.pad, ms('16b') + L.pad
          local pv = e.pitch or 0
          for _, o in ipairs(pool) do if o.parent == e and o.slice_k == row.k then pv = o.pitch or pv; break end end
          local ps = math.abs(pv) < 0.005 and '0' or ('%+g'):format(math.floor(pv * 10 + 0.5) / 10)
          text(dx + dw + XPW - L.pad - ms(ps), y + 1, ps, math.abs(pv) >= 0.005 and U.TEXT or U.DIM)
          local bs = e.bsync and ('%gb'):format(e.bsync) or '-'
          text(dx + dw + XPW + XBW - L.pad - ms(bs), y + 1, bs, e.bsync and U.CYAN or U.DIM)
        else lbl = lbl .. ('  %.2fs'):format(math.max(0, t1 - t0)) end
      end
      text(ix + 6 + 4 * L.cw, y + 1, fit(lbl, row.sub == 's' and math.min(w - 12 - 4 * L.cw, label_w - 4 * L.cw) or (w - 12 - 4 * L.cw)), on and U.AMBER or U.TEXT)
      if hot then hover.pool = { ci = info.pool_ci, i = row.i, sub = row.sub, k = row.k } end
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
      local sel = (i == inst or (cur and cur.parent == e)) and not D.lib_hdr   -- выбран слайс — горит исходник; 27 окт: курсор на имени папки — строка не горит (было двойное выделение)
      if D.lib_marks and D.lib_marks[i] then set(U.tint(U.CYAN, 0.3)); gfx.rect(ix + 1, y, w - 2, L.rh, 1); set(U.CYAN); gfx.rect(ix + 1, y, 2, L.rh, 1) end   -- 27 окт: отмечен (m); 31 окт: бирюзой, как отметки fx / tracks
      local rr = info.inst_range                -- диапазон v (2 окт)
      local inr = rr and i >= rr[1] and i <= rr[2] and not sel
      local here = col and e.track_set and e.track_set[col.name]
      local lib = e.depot and not (e.tracks and e.tracks[1])
      if sel then set(U.tint(U.AMBER, 0.30)); gfx.rect(ix + 1, y, w - 2, L.rh, 1)
      elseif inr then set(U.tint(U.CYAN, 0.22)); gfx.rect(ix + 1, y, w - 2, L.rh, 1) end
      if D.lib_layer_t == i then set(U.CYAN); gfx.rect(ix + 1, y, w - 2, L.rh, 0) end   -- 19 окт: сюда — слоем
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
        local pk = e.parent and e.parent.kit                -- 10 окт: часть набора & — своим именем файла
        local kname = pk and e.slice_k and #pk == #(e.parent.slices or {}) and pk[e.slice_k] or nil
        body = '  ' .. (tree and ((last and '`-' or '|-') .. ' ') or '') .. (kname or (e.slice_k and e.slice_k > 0 and ('s' .. e.slice_k) or 'cut'))
      end
      -- 10 окт: « /N» нарезанного всегда видно — режется имя, а не число слайсов; (muted) — не у lib
      local nkids = child and 0 or (#(e.layers or {}) + #(e.slices or {}))   -- 19 окт: папка (как lf): + закрыта, - открыта
      -- 26 окт: число слайсов — сразу после + / - («01+ 16$ amenbro»), не в конце строки
      -- 27 окт: отмечен (m) — «*» между номером и именем, как в lf
      local mk = (D.lib_marks and D.lib_marks[i]) and '*' or ' '
      local pre = ('%02d%s%s '):format(e.num or i, mk, nkids > 0 and (((D.LIBO or {})[e.gkey or ''] and '-' or '+') .. (' %2d$'):format(nkids)) or '     ')
      if nkids > 0 and mx >= ix + 6 + ms('00 ') and mx < ix + 6 + ms('00 +') + 2 and my >= y and my < y + L.rh then hover.libfold = e.gkey end
      local suf = ''   -- 11 окт: нарезан — «15$» = 15 слайсов (было « /15») .. ((e.muted and not e.depot) and ' (muted)' or '')
      if not child then body = (e.kit and '& ' or (e.layers and '¥ ' or '')) .. fit(e.name or '', math.max(ms('W'), label_w - 6 - ms(pre) - ms(suf) - ms('& '))) end   -- 26 окт: @ — в заголовке audio   -- 16 окт: @ — аудио, & — набор файлов
      -- 13 окт: «16$» — отдельно, не обрезается вместе с именем
      local lcol = sel and U.AMBER or (e.muted and U.GREY or (here and U.TEXT or U.GREY))
      local head = fit(pre .. body, math.max(ms('W'), label_w - 6 - ms(suf)))
      text(ix + 6, y + 1, head, lcol)
      if suf ~= '' then text(ix + 6 + ms(head), y + 1, suf, lcol) end
      -- длительность (3 окт): колонка перед мини-волной, место — у волны
      local dw = ms('88.88s') + L.pad
      local len = e.len or 0
      local dtxt = len < 10 and ('%.2fs'):format(len) or (len < 100 and ('%.1fs'):format(len) or ('%dm%02d'):format(len // 60, math.floor(len % 60)))
      local dx = ix + 6 + label_w + L.pad
      if w - (dx - ix) - L.pad > dw + 8 then
        text(dx + dw - L.pad - ms(dtxt), y + 1, dtxt, sel and U.AMBER or U.GREY)
      else dw = 0 end
      local tx0 = dx + dw
      -- 19 окт: pt — транспозиция (полутоны take), bs — beatsync в долях («-» — выкл)
      local XPW, XBW = ms('-12.5') + L.pad, ms('16b') + L.pad
      if dw > 0 then
        local ps = math.abs(e.pitch or 0) < 0.005 and '0' or ('%+g'):format(math.floor((e.pitch or 0) * 10 + 0.5) / 10)
        text(tx0 + XPW - L.pad - ms(ps), y + 1, ps, (math.abs(e.pitch or 0) >= 0.005) and U.TEXT or U.DIM)
        local bs = e.bsync and ('%gb'):format(e.bsync) or '-'
        text(tx0 + XPW + XBW - L.pad - ms(bs), y + 1, bs, e.bsync and U.CYAN or U.DIM)
        tx0 = tx0 + XPW + XBW
      else XPW, XBW = 0, 0 end
      local ntenv = tew > 0 and info.pool_tenv(e) or 0
      local wx = dx + dw + XPW + XBW + tew
      local rowhot = mx >= ix and mx < ix + w and my >= y and my < y + L.rh
      if ntenv > 0 then
        local th = rowhot and mx >= tx0 and mx < wx
        text(tx0 + L.pad, y + 1, TILDE, th and U.AMBER or U.CYAN)
      end
      local npix = w - (wx - ix) - L.pad
      if npix > 8 and e.stype == 'midi' then
        -- MIDI-клип (9 окт): мини-пиано-ролл вместо волны — ноты чёрточками
        local lo, hi = 127, 0
        for _, n in ipairs(e.notes or {}) do lo = math.min(lo, n[3]); hi = math.max(hi, n[3]) end
        local wc = U.readable(U.mix(rgb, U.TEXT, 0.35), U.BG, 4.0)
        set(U.mix(U.BG, U.TEXT, 0.08)); gfx.rect(wx, y + 1, npix, L.rh - 2, 1)
        set(wc)
        if hi < lo then gfx.line(wx, y + L.rh / 2, wx + npix, y + L.rh / 2)
        else
          local span = math.max(1, hi - lo)
          for _, n in ipairs(e.notes) do
            local nx0 = wx + math.floor(math.max(0, n[1]) * npix)
            local nx1 = wx + math.max(nx0 - wx + 1, math.floor(math.min(1, n[2]) * npix))
            local ny = y + L.rh - 2 - math.floor((n[3] - lo) / span * (L.rh - 4) + 0.5)
            gfx.rect(nx0, ny, math.max(1, nx1 - nx0), 1, 1)
          end
        end
      elseif npix > 8 then
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
      -- зоны (9 окт): ~ — огибающие take (вкладка automation), волна — вкладка item
      if rowhot then hover.pool = { ci = info.pool_ci, i = i, tenv = (ntenv > 0 and mx >= tx0 and mx < wx) or nil, wave = (mx >= wx and npix > 8) or nil } end
      hint('pool', ix + 2, y, w - 4, L.rh, i)
      if sel and not child then D.lib_xi_btns(L, ix + w - 4, y, mx, my, hover) end   -- 27 окт (5): ‹ ξ › — случайный сэмпл и назад / вперёд
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
  D.vbar('lib', ix + w - 4, iy + 2 + 2 * L.rh + LEG + TBH, 3, nvis * L.rh, D.pool_scroll, nvis, #rows)
  if LEG > 0 then
    set(U.PANEL); gfx.rect(ix + 1, iy + 2 + 2 * L.rh, w - 2, LEG, 1)
    text(ix + 6, iy + 2 + 2 * L.rh, fit('@ audio  & files kit  N$ slices  # drumrs5k  ~ automation  ' .. D.mu() .. ' midi clips  (muted)', w - 12), U.GREY)
  end
  D.pool_dbg = table.concat(dbg, ' | ')
end

-- ── кадр ──────────────────────────────────────────────────────────────────
-- info: ph_row, cur_row, playing, status_left/right, vcur, vis, focus,
--       regions, env_values(e), pool_col, inst, browser_draw(L,x,y,w,h)
-- hover: row, fi, field, cell, col, header_col, matrix={ri,ci}, pool, browser
-- jftop (6 окт): профайлер кадра на метках — pmark(имя) закрывает прошлый
-- участок и открывает новый, кадр делится на куски без пропусков; nil — закрыть.
-- Пишет только при D.prof_on (открыт jftop или опция debug)
D.prof, D.prof_on, D.prof_ord = {}, false, 0
-- 21 окт: и память — сборщик стоит на время кадра (stop / restart), разница count между метками = КБ,
-- выделенные участком (куча гуляла 310..540 МБ: ~0.5 МБ мусора за кадр — искать, кто)
local pm_name, pm_t, pm_k
function D.pmark(name)
  if not D.prof_on then if pm_name then collectgarbage('restart') end; pm_name = nil; return end
  local t = reaper.time_precise()
  local k = collectgarbage('count')
  if pm_name then
    local p = D.prof[pm_name]
    if not p then D.prof_ord = D.prof_ord + 1; p = { n = 0, sum = 0, max = 0, ema = 0, kb = 0, ord = D.prof_ord }; D.prof[pm_name] = p end
    local dt = (t - pm_t) * 1000
    p.n = p.n + 1; p.sum = p.sum + dt; p.last = dt
    p.ema = p.n == 1 and dt or (p.ema * 0.95 + dt * 0.05)
    local dk = math.max(0, k - pm_k)
    p.kb = p.n == 1 and dk or (p.kb * 0.95 + dk * 0.05)
    if dt > p.max then p.max = dt end
  elseif name then collectgarbage('stop') end
  if not name then collectgarbage('restart') end
  pm_name, pm_t, pm_k = name, t, collectgarbage('count')
end

-- шкала фейдера микшера (8 окт): амплитуда в степени 1/4 от +12 dB — верх
-- (около 0 dB) растянут, низ сжат, как у фейдеров пультов
local FMAX = 10 ^ (12 / 20)
D.FADER_W = function(L) return math.max(3 * L.cw + 4, ms('-48') + 6) end   -- ширина коробки фейдера (9 окт: была 5 знаков)
D.MINI_W = function(L) return L.cw + 5 end   -- 11 окт: мини-полоса (свёрнутая колонка / низкий микшер)
-- 11 окт: мини-полоса — мини-кноб панорамы сверху, под ним фейдер в знак шириной
-- (метр + риска уровня); свёрнутая колонка и микшер ниже 3 строк фейдера
function D.mini_strip(col, x, w, y0, y1, info, hover, mx, my, L)
  local live = info.trs_live
  local function lv(what, v) return (live and live.guid == col.guid and live.what == what) and live.v or v end
  local ks = info.kslider
  local kd = w | 1
  if y1 - y0 >= kd + 14 then
    local r = kd >> 1
    local cx, cy = x + r, y0 + r
    local frac = (lv('pan', col.pan or 0) + 1) / 2
    local khot = mx >= x and mx < x + kd and my >= y0 and my < y0 + kd
    local kon = ks and ks.what == 'pan' and ks.col and ks.col.guid == col.guid
    local kdark = U.mix(U.BG, { 0, 0, 0 }, 0.55)
    set(kdark); gfx.circle(cx, cy, r, 1, 0)
    set((khot or kon) and U.AMBER or U.LINE); gfx.circle(cx, cy, r, 0, 0)
    local a = (frac - 0.5) * 1.5 * math.pi
    set(U.readable((khot or kon) and U.AMBER or U.TEXT, kdark, 7))
    gfx.rect(cx + math.floor(math.sin(a) * (r - 2) + 0.5), cy - math.floor(math.cos(a) * (r - 2) + 0.5), 1, 1, 1)
    if khot then hover.trs = { col = col, what = 'pan', knob = true, sv = frac } end
    if D.csel_on(col.guid, 'pan') then csel_frame(x - 1, y0 - 1, kd + 2, kd + 2) end
    hint('trs', x, y0, kd, kd, { col = col, what = 'pan' })
    y0 = y0 + kd + 2
  end
  -- 11 окт: M S R внизу, если над ними остаётся фейдер от 3 строк
  local bh = L and (L.rh - 2) or 0
  if L and y1 - y0 >= 3 * (bh + 2) + 3 * L.rh then
    local bs = { { 'M', col.muted, U.AMBER, 'mute' }, { 'S', col.solo, U.GREEN, 'solo' }, { 'R', col.armed, D.ARM, 'arm' } }
    local by = y1 - 3 * (bh + 2) + 2
    for _, b in ipairs(bs) do
      local hot = mx >= x and mx < x + w and my >= by and my < by + bh + 2
      set(b[2] and ((b[3] == D.ARM and D.ARM_T) or U.tint(b[3], 0.5)) or (hot and D.CURROW or U.PANEL)); gfx.rect(x, by, w, bh, 1)
      set(b[2] and b[3] or U.DIM); gfx.rect(x, by, w, bh, 0)
      text(x + math.floor((w - ms(b[1])) / 2), by, b[1], b[2] and b[3] or (b[4] == 'arm' and U.readable(U.RED, U.PANEL, 3) or U.readable(U.GREY, U.PANEL, 4.5)))
      if hot then hover.btn = { col = col, what = b[4] } end
      hint('btn', x, by, w, bh + 2, { col = col, what = b[4] })
      by = by + bh + 2
    end
    y1 = y1 - 3 * (bh + 2)
  end
  if y1 - y0 < 12 then return end
  local th = y1 - y0
  local dark = U.mix(U.BG, { 0, 0, 0 }, 0.55)
  local vol = lv('vol', col.vol or 1)
  local db = vol > 1e-6 and 20 * math.log(vol, 10) or -150
  local hotf = mx >= x and mx < x + w and my >= y0 and my < y1
  local kon = ks and ks.what == 'vol' and ks.col and ks.col.guid == col.guid
  local function yp(d) return y1 - 2 - math.floor((th - 4) * D.fader_pos(d) + 0.5) end
  set(dark); gfx.rect(x, y0, w, th, 1)
  set((hotf or kon) and U.AMBER or U.LINE); gfx.rect(x, y0, w, th, 0)
  if info.peaks then
    local pl, pr = info.peaks(col)
    local pk = math.max(pl or 0, pr or 0)
    local pdb = pk > 1e-6 and 20 * math.log(pk, 10) or -150
    if pdb > -60 then
      local ya = yp(pdb)
      set(pdb > 0 and U.RED or (pdb > -6 and U.AMBER or U.GREEN)); gfx.rect(x + 2, ya, math.max(1, w - 4), y1 - 2 - ya, 1)
    end
  end
  set(U.readable(U.GREY, dark, 3)); gfx.rect(x + 1, yp(0), 2, 1, 1)                        -- риска 0 dB
  set(U.readable((hotf or kon) and U.AMBER or U.TEXT, dark, 4)); gfx.rect(x + 1, yp(db) - 1, w - 2, 3, 1)
  if hotf then hover.trs = { col = col, what = 'vol', vert = true, y0 = y1 - 2, h = th - 4, sv = math.max(0, math.min(1, (y1 - 2 - my) / math.max(1, th - 4))) } end
  if D.csel_on(col.guid, 'vol') then csel_frame(x, y0, w, th) end
  hint('trs', x, y0, w, th, { col = col, what = 'vol' })
end
D.mix_hold = {}   -- guid → удержание пиков фейдера (рисунок __): {db,t} L, {db,t} R; max / clip — нативные
function D.fader_pos(db)
  if db <= -150 then return 0 end
  return math.max(0, math.min(1, (10 ^ (math.min(12, db) / 20) / FMAX) ^ 0.25))
end
function D.fader_db(p)
  p = math.max(0, math.min(1, p))
  if p <= 0 then return -150 end
  return 20 * math.log((p ^ 4) * FMAX, 10)
end

-- big fixed cursor (8 окт): лупа ×2 строки курсора поверх готового тела.
-- b = { x0, x1, sx, sw, yc, yb, rh } (main); кадр — в буфере (gfx.dest ≠ -1).
-- 1019 — строки ниже курсора, 1018 — отрезок строки курсора; блит без
-- фильтрации — пиксели битмапа ровно ×2, как у шрифта ×2
-- мышь с Ctrl (8 окт): выделенные цели — голубой рамкой. D.csel — модуль
-- jf_tracker_ctrlmouse (ставит main), ключи — как CM.key
function D.csel_on(tid, fx, p)
  local S = D.csel
  if not S or #S.order == 0 or not tid then return false end
  if p then return S.sel['fx|' .. tostring(tid) .. '|' .. tostring(fx) .. '|' .. tostring(p)] ~= nil end
  return S.sel['trk|' .. tostring(tid) .. '|' .. tostring(fx)] ~= nil
end
D.csel_frame = csel_frame

local bc_w, bc_h = 0, 0
function D.bigcur(b)
  local d = gfx.dest
  if d == -1 then return end
  local w, rh = b.x1 - b.x0, b.rh
  local h = b.yb - b.yc                      -- строка курсора + всё ниже — одним чтением из кадра
  if bc_w ~= w or bc_h ~= h then bc_w, bc_h = w, h; gfx.setimgdim(1019, -1, -1); gfx.setimgdim(1019, w, h) end
  local mode, a = gfx.mode, gfx.a
  gfx.a = 1; gfx.mode = 4
  gfx.dest = 1019
  gfx.blit(d, 1, 0, b.x0, b.yc, w, h, 0, 0, w, h)
  gfx.dest = d
  local below = h - 2 * rh
  if below > 0 then gfx.blit(1019, 1, 0, 0, rh, w, below, b.x0, b.yc + 2 * rh, w, below) end
  gfx.blit(1019, 1, 0, b.sx - b.x0, 0, b.sw, rh, b.x0, b.yc, b.sw * 2, rh * 2)
  gfx.mode, gfx.a = mode, a
end

-- ── панели (9 окт, бета): оболочка листов дерева tmux / zellij ───────────
-- У листа рамка; подпись (и подписи стека) — в верхней линии рамки, как в
-- zellij; фокус — линия и активная подпись цветом фокуса. Содержимое — в
-- прямоугольник листа с D.clip. Линии раздела — одной серией в конце (встык,
-- без двойных). Лист не у левого края, а модуль рисует от x = 0 (матрица) —
-- через закадровый буфер 1021 со сдвигом мыши.
local function pn_buffered(x, y, w, h, fn)
  if x == 0 then return fn() end
  -- 11 окт: свой буфер 798 — 1021 занят буфером кадра (опция fps / big fixed cursor), переразмер ломал кадр
  if D.pnb_w ~= w or D.pnb_h ~= gfx.h then gfx.setimgdim(798, w, gfx.h); D.pnb_w, D.pnb_h = w, gfx.h end
  local dest0, mx0 = gfx.dest, gfx.mouse_x
  gfx.dest = 798
  set(U.PANEL); gfx.rect(0, y, w, h, 1)
  gfx.mouse_x = mx0 - x
  D.pn_ox = x          -- 23 окт: сдвиг буфера — полосы прокрутки запоминают экранные x (щелчок приходит в экранных)
  local ok, res = pcall(fn)
  D.pn_ox = 0
  gfx.mouse_x, gfx.dest = mx0, dest0
  if not ok then error(res, 0) end
  gfx.blit(798, 1, 0, 0, y, w, h, x, y, w, h)
  return res
end

D.PMN = {}
-- 17 окт: цвет панели (опция pane colours): свой оттенок у каждой, шаг по золотому сечению — соседние
-- вкладки стопки не похожи; контраст к фону панели как у текста; rec — цвет записи. Кэш — до смены темы
-- shades — светлее / темнее акцента темы (U.CYAN — от цвета выбранного трека темы)
local function hsv(h, sat, v)
  local k = math.floor(h * 6); local f = h * 6 - k
  local p1, q, t = v * (1 - sat), v * (1 - f * sat), v * (1 - (1 - f) * sat)
  return ({ { v, t, p1 }, { q, v, p1 }, { p1, v, t }, { p1, q, v }, { t, p1, v }, { v, p1, q } })[k % 6 + 1]
end
function D.pane_col(id, mode, hue)
  local mk = mode .. ':' .. tostring(hue or 0)
  if D.PCOL_BG ~= U.PANEL or D.PCOL_M ~= mk then D.PCOL, D.PCOL_BG, D.PCOL_M = {}, U.PANEL, mk end
  local c = D.PCOL[id]
  if c then return c end
  local idx = 1
  for i, p in ipairs(D.panes.PANELS) do if p.id == id then idx = i; break end end
  if mode == 'shades' then
    -- 17 окт: основа — акцент темы или оттенок из опции shades hue (1..360); пять чётких ступеней светлоты
    -- (плавная шкала давала соседям почти один тон), соседние номера — через ступень
    local base = (hue and hue > 0) and U.readable(hsv((hue % 360) / 360, 0.6, 0.9), U.PANEL, 3.0) or U.CYAN
    local lv = ({ -0.5, -0.25, 0, 0.35, 0.7 })[(idx * 2) % 5 + 1]
    c = lv < 0 and U.mix(base, U.PANEL, -lv) or U.mix(base, U.TEXT, lv)
    c = U.readable(c, U.PANEL, 2.2)
  elseif id == 'retro' then c = D.ARM
  else
    local h, sat, v = (0.08 + idx * 0.618034) % 1, 0.55, 0.92
    c = U.readable(hsv(h, sat, v), U.PANEL, 3.0)
  end
  D.PCOL[id] = c
  return c
end
-- 28 окт: кэш панелей — «спокойная» панель (lib, браузер, справка …) рисуется в общий буфер 1022 размером с окно, только
-- когда что-то поменялось; в прочих кадрах её прямоугольник копируется из буфера. Перерисовка: эпоха main (ввод, правка,
-- снимок, фокус, раскладка, курсор), мышь над панелью (и кадр после ухода), фокус на ней, раз в 0.5 с (фоновые
-- обновления), воспроизведение — у панелей с плейхедом, хинты-прыжки. Трекер, микшер, DSP, вкладки с волной — всегда
D.PC_OK = { inst = true, browser = true, map = true, help = true, hints = true, notes = true, clipboard = true, undotree = true,
  actions = true, harm = true, reform = true, humanizer = true, renderer = true, console = true, tracks = true, patterns = true,
  matrix = true, fxb = true, sprops = true, nmod = true, macros = true, pm = true }
D.PC_OK.dsp = true
D.PC_PLAY = { matrix = true, patterns = true, browser = true, map = true, inst = true, dsp = true }   -- плейхед / превью / метры
D.pc_st = {}
function D.pc_hit(id, c, info, inside, foc)
  if not (D.pc_on and D.PC_OK[id] and not c.min) then return false end
  if D.pc_w ~= gfx.w or D.pc_h ~= gfx.h then gfx.setimgdim(1022, gfx.w, gfx.h); D.pc_w, D.pc_h = gfx.w, gfx.h; D.pc_st = {} end
  local st = D.pc_st[id]
  local now = reaper.time_precise()
  if st and st.ep == info.pc_epoch and st.x == c.x and st.y == c.y and st.w == c.w and st.h == c.h and not inside and not st.inside
     and not foc and now - st.t < 0.5 and not (info.pc_live and D.PC_PLAY[id]) and not info.hn_active then
    gfx.blit(1022, 1, 0, c.x, c.y, c.w, c.h, c.x, c.y, c.w, c.h)
    D.pc_hits = (D.pc_hits or 0) + 1
    return true
  end
  return false
end
function D.pc_begin(id, c)
  if not (D.pc_on and D.PC_OK[id] and not c.min and D.pc_w) then return nil end
  local d0 = gfx.dest
  gfx.dest = 1022
  return { id = id, d0 = d0, c = c }
end
function D.pc_end(pc, info, inside)
  if not pc then return end
  local c = pc.c
  gfx.dest = pc.d0; gfx.a = 1; gfx.mode = 0
  gfx.blit(1022, 1, 0, c.x, c.y, c.w, c.h, c.x, c.y, c.w, c.h)
  D.pc_st[pc.id] = { ep = info.pc_epoch, x = c.x, y = c.y, w = c.w, h = c.h, t = reaper.time_precise(), inside = inside }
end
function D.panes_frame(L, snap, state, info, hover, ph)
  L.pn_dsp = nil
  local PN, lay = D.panes, L.pn
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local foc = (info.mixfocus and info.focus == 'tracker') and 'mixer' or info.focus   -- 11 окт: фокус микшера
  local function focused(id) return foc == id or (foc == 'top' and id == info.toptab) end
  local rects = {}
  for _, c in ipairs(lay.cells) do
    local id = c.active_id
    if id then D.PMN[id] = D.PMN[id] or ('pane: ' .. id); D.pmark(D.PMN[id]) end   -- 17 окт: jftop — время каждой панели отдельно
    if id == 'tracker' then
      rects.tracker = { c.x, c.y, c.w, c.h }
      D.pn_tracker_cell = c                        -- 11 окт: его номер в PANE рисуется поверх (D.pane_badge_tracker)
      if c.hint and info.hint_bars then           -- 10 окт: и у трекера своя строка клавиш (hints where = panes)
        D.hint_bar(setmetatable({ hint_h = c.hint.h }, { __index = L }), c.hint.x, c.hint.y, c.hint.w,
          info.hint_bars(info.vmode == 'insert' and 'insert' or 'tracker') or D.PANE_KEYS, foc == 'tracker')
      end
    elseif id and D.pc_hit(id, c, info, mx >= c.x and mx < c.x + c.w and my >= c.y and my < c.y + c.h, focused(id)) then
      -- 28 окт: кэш — панель скопирована из буфера; прямоугольники для щелчков и фокуса — как при отрисовке
      local ct = c.content
      local rk = PN.BY[id].tab and 'top' or id
      if rk ~= 'top' or id == info.toptab or not rects.top then rects[rk] = { ct.x, ct.y, ct.w, ct.h } end
      if PN.BY[id].tab then rects[id] = { ct.x, ct.y, ct.w, ct.h } end
    elseif id then
      local pcb = D.pc_begin(id, c)
      local ct = c.content
      -- 11 окт: mixer — полоски уже нарисованы трекером (раньше оболочки): фон только под подписью
      set(U.PANEL); gfx.rect(c.x, c.y, c.w, id == 'mixer' and math.max(0, ct.y - c.y) or c.h, 1)
      -- верхняя линия рамки и подписи на ней
      local fon = focused(id)
      if c.tab then
        local th = c.tab.h
        local G0 = D.TABGAP or 0
        -- 19 окт: над вкладками — G0 px пустоты (фон окна); вкладка — рамка сверху и с боков, линия панели — под вкладками,
        -- выбранная вкладка открыта вниз (её фон поверх линии) — как настоящая вкладка
        set(U.BG); gfx.rect(c.x, c.y, c.w, G0, 1)
        local tyt, tth = c.y + G0, th - G0
        local lyl = c.y + th - 1
        local pm = state.panecol ~= 'off' and state.panecol or nil   -- 17 окт: цвета панелей
        local pcol = pm and function(pid) return D.pane_col(pid, pm, state.shadehue) end or nil
        set(fon and D.FOCUS or (pcol and U.mix(pcol(id), U.PANEL, 0.55)) or D.SEP); gfx.rect(c.x, lyl, c.w, 1, 1)
        local stack = #c.tabs >= 1                        -- 10 окт: вкладки везде — и у одиночной панели (|lib|), как у стека |rec|item|
        for _, t in ipairs(c.tabs) do
          local lbl = fit(D.ic(t.id, PN.BY[t.id].label), t.w - 2 * L.pad)
          if lbl ~= '' then
            local on = t.id == id
            local hot = mx >= t.x and mx < t.x + t.w and my >= t.y and my < t.y + t.h
            local tx = t.x + L.pad
            if stack then
              local bx, bw = tx - L.pad // 2 - 1, ms(lbl) + L.pad + 2
              -- 15 окт: вкладка в фокусе — акцентом (жёлтым), активные в других стопках — контрастно, но тише
              local soft = U.TEXT   -- 15 окт: выбранная вне фокуса — сам заголовок полным TEXT (было тише — терялся)
              if pcol and on and not fon then soft = pcol(t.id) end   -- выбранная вне фокуса — рамка и фон её цветом
              set(on and (fon and U.tint(U.AMBER, 0.30) or U.tint(soft, 0.20)) or (hot and D.CURROW or U.PANEL)); gfx.rect(bx, tyt, bw, tth - (on and 0 or 1), 1)
              set(on and (fon and U.AMBER or soft) or (pcol and U.mix(pcol(t.id), U.PANEL, 0.6)) or U.LINE)
              gfx.rect(bx, tyt, bw, 1, 1); gfx.rect(bx, tyt, 1, tth, 1); gfx.rect(bx + bw - 1, tyt, 1, tth, 1)
            else
              set(U.PANEL); gfx.rect(tx - 3, tyt, ms(lbl) + 6, tth, 1)   -- фон под подписью на всю высоту строки
            end
            local col = on and (fon and U.AMBER or U.TEXT) or (hot and U.TEXT or U.GREY)
            if t.id == 'retro' and not on then col = D.ARM end
            if pcol and not (on and fon) then col = (on or hot) and pcol(t.id) or U.mix(pcol(t.id), U.PANEL, 0.25) end
            text(tx, tyt + 1, lbl, col)
            if hot then hover.ptab = { id = t.id } end
            hint('ptab', t.x, t.y, t.w, t.h, t.id)
          end
        end
      end
      -- 15 окт: hints where = tabs — клавиши модуля в строке вкладок, справа от подписей (глаз уже здесь)
      if c.tab and info.hint_bars and state.hints and state.hintpos == 'tabs' and id ~= 'mixer' then
        local last = c.tabs[#c.tabs]
        local hx = (last and (last.x + math.min(last.w, ms(fit(D.ic(last.id, PN.BY[last.id].label), last.w - 2 * L.pad)) + 2 * L.pad)) or c.x) + 3 * L.pad
        local page = (id == 'browser' and (info.browser_page or 'browser')) or (id == 'pm' and 'pm') or (id == 'garden' and 'orca') or PN.BY[id].hint or id
        if PN.BY[id].tab and id == info.toptab and info.top_page then page = info.top_page end   -- 15 окт: вкладка — подсказки её страницы (холст automation)
        local bar = info.hint_bars(page) or D.PANE_KEYS
        D.qm_bars = D.qm_bars or setmetatable({}, { __mode = 'k' })
        local qb = D.qm_bars[bar]
        if not qb then qb = { { '\\', 'menu' } }; for _, it in ipairs(bar) do qb[#qb + 1] = it end; D.qm_bars[bar] = qb end
        local badge = (state.pane_mode and c.num and c.num <= 9) and (3 * L.cw) or 0
        D.hint_pairs(hx, c.y + (D.TABGAP or 0) + 1, c.x + c.w - L.pad - badge, qb, U.PANEL)
      end
      -- режим PANE: номер листа (1..9 — фокус цифрой) у правого края рамки
      if state.pane_mode and c.num and c.num <= 9 and c.tab then D.pane_badge(L, c, c.tab.h) end
      D.clip = { ct.x, ct.x + ct.w, ct.y, ct.y + ct.h }
      local inside = mx >= ct.x and mx < ct.x + ct.w and my >= ct.y and my < ct.y + ct.h
      if c.min then   -- 20 окт: свёрнута (zm) — только вкладки, модуль не рисуется
      elseif id == 'reform' and info.rf_draw then hover.rf = info.rf_draw(L, ct.x, ct.y, ct.w, ct.h, foc == 'reform'); if not inside then hover.rf = nil end   -- 19 окт
      elseif id == 'renderer' and info.rd_draw then hover.rd = info.rd_draw(L, ct.x, ct.y, ct.w, ct.h, foc == 'renderer'); if not inside then hover.rd = nil end   -- 20 окт
      elseif id == 'phrases' and info.phr_draw then hover.phr = info.phr_draw(L, ct.x, ct.y, ct.w, ct.h, foc == 'phrases'); if not inside then hover.phr = nil end   -- 31 окт
      elseif id == 'lfogen' and info.lfogen_draw then hover.lfogen = info.lfogen_draw(L, ct.x, ct.y, ct.w, ct.h, foc == 'lfogen'); if not inside then hover.lfogen = nil end   -- 31 окт
      elseif id == 'humanizer' and info.hum_draw then hover.hum = info.hum_draw(L, ct.x, ct.y, ct.w, ct.h, foc == 'humanizer'); if not inside then hover.hum = nil end   -- 19 окт
      elseif id == 'perf' and info.perf_pane then info.perf_pane(L, ct.x, ct.y, ct.w, ct.h)   -- 18 окт: своя панель
      elseif id == 'patterns' then   -- 19 окт: палитра паттернов — своя панель (клетки — под треками матрицы)
        if info.patlist_draw then   -- 19 окт вечер: кубики на всю панель, строка chain — внизу
          local chy = ct.y + ct.h - L.rh - 2
          local _, hv = info.patlist_draw(L, ct.x + 2, ct.y + 2, ct.w - 6, chy - ct.y - 4)
          if info.chain_draw then local _, chv = info.chain_draw(L, ct.x, chy, ct.w - 4); for k, v in pairs(chv) do hv[k] = v end end
          hover.patpane = inside and hv or nil
        end
      elseif id == 'matrix' then
        if MX then
          hover.matrix = pn_buffered(ct.x, ct.y, ct.w, ct.h, function()
            return MX.draw(L, snap, info.regions or {}, { play_row = ph, sig_at = info.sig_at, cur_ci = info.cur_ci, cur_region = info.cur_region, cur_region_full = info.cur_region_full, pat_num = info.pat_num, loop_cells = info.loop_cells, loop_text = info.loop_text, region_rgb = info.region_rgb, bar_label = info.mx_bar_label, ticks = info.mx_ticks, marks = info.mx_marks, view = D.mx_view,
              env_shown = function(col) local v = state.trackenvs and state.trackenvs[col.guid]; if v == nil then v = state.envs end; return v end }, ct.y, ct.w, ct.h)
          end)
        end
      elseif id == 'tracks' then
        D.track_list(L, state, snap, info, hover, ct.x + 1, ct.y + 2, ct.w - 2, ct.h - 4, foc == 'tracks')   -- 11 окт: Track Manager
      elseif id == 'map' and info.map_draw then
        hover.browser = info.map_draw(L, ct.x, ct.y, ct.w, ct.h)          -- 27 окт: карта сэмплов — своя панель
      elseif id == 'pm' and info.pm_draw then
        hover.browser = info.pm_draw(L, ct.x, ct.y, ct.w, ct.h)          -- 9 окт: проекты — своя панель
      elseif id == 'browser' and info.browser_draw then
        hover.browser = info.browser_draw(L, ct.x, ct.y, ct.w, ct.h)
        if info.browser_fxb then local fh = info.browser_fxb(); if fh then hover.fxb = fh end end   -- 9 окт: вкладка fx браузера (router big) — щелчки
      elseif id == 'inst' then
        info.lib_tree = state.libtree == true and function(tx, ty, tw, th) D.track_list(L, state, snap, info, hover, tx, ty, tw, th, foc == 'inst') end or nil
        D.draw_instruments(L, info, ct.x, ct.y, ct.w, ct.h, hover)
      elseif id == 'clipboard' and info.clip_draw then
        info.clip_draw(L, ct.x + L.pad, ct.y + 2, ct.w - 2 * L.pad, ct.h - 4, foc == 'clipboard', hover)
      elseif id == 'manual' and info.manual_draw then   -- 29 окт: справка панелью
        local mh = info.manual_draw(L, ct.x, ct.y, ct.w, ct.h)
        if inside and type(mh) == 'table' then for k2, v2 in pairs(mh) do hover[k2] = v2 end end
      elseif id == 'console' and info.console_draw then   -- 28 окт: консоль Strudel
        info.console_draw(L, ct.x, ct.y, ct.w, ct.h, foc == 'console')
      elseif id == 'hints' and info.hints_draw then   -- 28 окт: что делает модуль под мышью
        info.hints_draw(L, ct.x + L.pad, ct.y + 2, ct.w - 2 * L.pad, ct.h - 4, foc == 'hints', hover)
      elseif id == 'help' and info.help_draw then   -- 17 окт: справка модуля в фокусе
        info.help_draw(L, ct.x + L.pad, ct.y + 2, ct.w - 2 * L.pad, ct.h - 4, foc == 'help', hover)
      elseif id == 'actions' and info.act_draw then   -- 16 окт
        info.act_draw(L, ct.x + L.pad, ct.y + 2, ct.w - 2 * L.pad, ct.h - 4, foc == 'actions', hover)
      elseif id == 'undotree' and info.ut_draw then
        info.ut_draw(L, ct.x + L.pad, ct.y + 2, ct.w - 2 * L.pad, ct.h - 4, foc == 'undotree', hover)
      elseif id == 'slices' and info.slices_draw then
        local hs = info.slices_draw(L, ct.x + 3, ct.y + 2, ct.w - 5, ct.h - 4)
        if hs ~= nil then hover.slices = hs end
      elseif id == 'sprops' and info.sprops_draw then
        info.sprops_draw(L, ct.x + L.pad, ct.y + 2, ct.w - 2 * L.pad, ct.h - 4)
      elseif id == 'nmod' and info.nmod_draw then
        info.nmod_draw(L, ct.x + L.pad, ct.y + 2, ct.w - 2 * L.pad, ct.h - 4)
      elseif id == 'fxb' and info.fxb_draw then
        local hv = info.fxb_draw(L, ct.x, ct.y, ct.w, ct.h)
        if hv ~= nil then hover.fxb = hv end
      elseif id == 'notes' and info.notes_draw then
        local ok, hn = pcall(info.notes_draw, L, ct.x + L.pad, ct.y, ct.w - 2 * L.pad, ct.h - 2)
        if ok and inside then hover.notes = hn or 'text' end
      elseif id == 'dsp' then
        L.pn_dsp = ct                                    -- рисует блок DSP ниже в кадре (его координаты — из листа)
      elseif id == 'ctrl' then
        -- главный модуль рисует от (0, 0) шириной L.ctrl_w — в буфер 99, сдвиг мыши и меток f по x и y
        local bx, by, bw, bh = ct.x, ct.y, ct.w, ct.h
        if D.ctrl_buf_w ~= bw or D.ctrl_buf_h ~= bh then gfx.setimgdim(99, bw, bh); D.ctrl_buf_w, D.ctrl_buf_h = bw, bh end
        local dest0, mx0, my0, hint0, cw0, clip0 = gfx.dest, gfx.mouse_x, gfx.mouse_y, D.hint, L.ctrl_w, D.clip
        gfx.dest = 99; gfx.mouse_x, gfx.mouse_y = mx0 - bx, my0 - by; D.clip = nil; U.mouse_off = { bx, by }   -- 31 окт: сдвиг буфера — для геометрии мыши
        if hint0 then D.hint = function(kind, x, y, w, h, data) return hint0(kind, x + bx, y + by, w, h, data) end end
        L.ctrl_w = bw
        set(U.PANEL); gfx.rect(0, 0, bw, bh, 1)
        local hv = {}
        local ok, err = pcall(draw_ctrl, L, info, bh, hv)
        gfx.mouse_x, gfx.mouse_y, D.hint, gfx.dest, L.ctrl_w, D.clip = mx0, my0, hint0, dest0, cw0, clip0; U.mouse_off = nil
        if not ok then error(err, 0) end
        gfx.blit(99, 1, 0, 0, 0, bw, bh, bx, by, bw, bh)
        for _, r in pairs(D.ctrl_rect or {}) do if not r.shifted then r[1] = r[1] + bx; r[2] = r[2] + by; r.shifted = true end end
        if L.ctrl_area then L.ctrl_area = { L.ctrl_area[1] + bx, L.ctrl_area[2] + by, L.ctrl_area[3], L.ctrl_area[4] } end
        if inside then hover.ctrl, hover.zone = hv.ctrl, hv.zone end
      elseif PN.BY[id].tab then
        -- вкладка: прежняя верхняя панель рисует содержимое активной вкладки в
        -- буфер 1020 (без главного модуля, lib и слайсов), на экран — только
        -- область под её строкой вкладок
        local cy0 = 1 + L.rh + 3
        local bw, bh = ct.w, ct.h + cy0 - 2         -- 9 окт: тело вкладки = ct.h − 4: 2 px сверху и снизу, ничего не срезается
        if D.pnt_w ~= bw or D.pnt_h ~= bh then gfx.setimgdim(1020, bw, bh); D.pnt_w, D.pnt_h = bw, bh end
        local sv = { L.top_h, L.top_x0, L.win_w, L.inst_w, L.slices_w, L.ctrl_alone, L.top_first, info.toptab }
        L.top_h, L.top_x0, L.win_w, L.inst_w, L.slices_w, L.ctrl_alone, L.top_first, info.toptab = bh, 0, bw, 0, 0, true, true, id
        local dest0, mx0, my0, hint0, clip0 = gfx.dest, gfx.mouse_x, gfx.mouse_y, D.hint, D.clip
        local dy = ct.y - cy0 + 2                           -- содержимое на 2 px ниже рамки
        gfx.dest = 1020; gfx.mouse_x, gfx.mouse_y = mx0 - ct.x, my0 - dy; D.clip = nil; U.mouse_off = { ct.x, dy }
        if hint0 then D.hint = function(kind, x, y, w, h, data) if y >= cy0 then return hint0(kind, x + ct.x, y + dy, w, h, data) end end end
        local ok, th = xpcall(draw_topbar, debug.traceback, L, info)
        gfx.mouse_x, gfx.mouse_y, D.hint, gfx.dest, D.clip = mx0, my0, hint0, dest0, clip0; U.mouse_off = nil
        L.top_h, L.top_x0, L.win_w, L.inst_w, L.slices_w, L.ctrl_alone, L.top_first, info.toptab = table.unpack(sv, 1, 8)
        if ok then
          gfx.blit(1020, 1, 0, 0, cy0 - 2, bw, ct.h, ct.x, ct.y, bw, ct.h)   -- 2 px запаса сверху (кнопки не на рамке), тело короче — низ цел
        else
          -- 9 окт: ошибка одной вкладки не роняет трекер — сообщение на её месте, стек в debug log
          set(U.PANEL); gfx.rect(ct.x, ct.y, ct.w, ct.h, 1)
          text(ct.x + L.pad, ct.y + 2, fit('tab ' .. tostring(id) .. ': ' .. tostring(th):match('[^\n]*'), ct.w - 2 * L.pad), U.RED)
          if D.tab_err ~= th then D.tab_err = th; if info.dlog then info.dlog('TAB ERROR ' .. tostring(id) .. ': ' .. tostring(th)) end end
          th = nil
        end
        if inside and type(th) == 'table' then for k, v in pairs(th) do if k ~= 'tab' then hover[k] = v end end end
      elseif id ~= 'mixer' then
        text(ct.x + L.pad, ct.y + 2, fit(PN.BY[id].label, ct.w - 2 * L.pad), U.GREY)
      end
      D.clip = nil
      -- 11 окт: 'top' — лист АКТИВНОЙ вкладки (стеков вкладок может быть два: clips сверху, visor слева;
      -- последний нарисованный перетирал, и рамка фокуса стояла не там, куда шли клавиши)
      local rk = PN.BY[id].tab and 'top' or id
      if rk ~= 'top' or id == info.toptab or not rects.top then rects[rk] = { ct.x, ct.y, ct.w, ct.h } end
      if PN.BY[id].tab then rects[id] = { ct.x, ct.y, ct.w, ct.h } end
      -- 10 окт: строка клавиш панели (хинты включены) — в самом низу листа
      if c.hint and info.hint_bars then
        local page = (id == 'browser' and (info.browser_page or 'browser')) or (id == 'pm' and 'pm') or (id == 'garden' and 'orca') or PN.BY[id].hint or id
        local hl = setmetatable({ hint_h = c.hint.h }, { __index = L })
        -- 10 окт: первой — \ menu (быстрое меню модуля), дальше клавиши модуля
        local bar = info.hint_bars(page) or D.PANE_KEYS
        D.qm_bars = D.qm_bars or setmetatable({}, { __mode = 'k' })
        local qb = D.qm_bars[bar]
        if not qb then qb = { { '\\', 'menu' } }; for _, it in ipairs(bar) do qb[#qb + 1] = it end; D.qm_bars[bar] = qb end
        D.hint_bar(hl, c.hint.x, c.hint.y, c.hint.w, qb, fon)
      end
      D.pc_end(pcb, info, mx >= c.x and mx < c.x + c.w and my >= c.y and my < c.y + c.h)
    end
  end
  D.pmark('panes: lines and grips')
  -- линии раздела и ручки: ручка под мышью — янтарём
  set(D.SEP)
  for _, sp in ipairs(lay.seps) do gfx.rect(sp.x, sp.y, sp.w, sp.h, 1) end
  for _, g in ipairs(lay.grips) do
    if mx >= g.x and mx < g.x + g.w and my >= g.y and my < g.y + g.h then
      hover.pgrip = g
      for _, k in ipairs({ 'row', 'cell', 'fi', 'col', 'field', 'browser', 'matrix', 'pool', 'rownum' }) do hover[k] = nil end
      set(U.AMBER)
      if g.ax == 'h' then gfx.rect(g.x + math.floor(g.w / 2) - 1, g.y, 2, g.h, 1) else gfx.rect(g.x, g.y + math.floor(g.h / 2) - 1, g.w, 2, 1) end
      break
    end
  end
  D.pn_rects = rects
end

-- 17 окт: сложенный мастер — шапка M и кнопка (развернуть), в теле стерео-метр L R во всю высоту и красная полоса
-- подавления сверху (максимум GainReduction_dB среди эффектов мастера: ReaComp, ReaLimit, плагины с этим полем)
-- 20 окт: Shift+F — что встанет на место: рамка на длину сэмпла в строках, волна сверху вниз (время — вниз), имя
function D.sf_draw(L, info, state)
  local g = info.sf_ghost and info.sf_ghost()
  if not g then return end
  local f = L.flat[g.fi]
  if not (f and f.x and f.w) then return end
  local row0 = state.row0 or 0
  local y0 = L.body_y + (g.row - row0) * L.rh
  local y1 = y0 + g.rows * L.rh
  local top, bot = math.max(L.body_y, y0), math.min(L.body_y + L.body_h, y1)
  if bot <= top then return end
  local x, w = f.x + 1, f.w - 2
  local keep = D.clip; D.clip = { x, x + w }
  gfx.set(U.AMBER[1], U.AMBER[2], U.AMBER[3], 0.14); gfx.rect(x, top, w, bot - top, 1); gfx.a = 1
  if g.path and info.file_peaks then
    local n = math.max(2, math.floor((y1 - y0) / 2))
    local pk = info.file_peaks(g.path, n)
    if pk and pk.n and pk.n > 0 then
      local cx, hw = x + math.floor(w / 2), math.floor(w / 2) - 2
      set(U.mix(U.AMBER, U.BG, 0.25))
      for yy = top, bot - 1 do
        local i = math.floor((yy - y0) / math.max(1, y1 - y0) * pk.n) + 1
        local a, b = pk.min[i] or 0, pk.max[i] or 0
        gfx.line(cx + a * hw, yy, cx + b * hw, yy)
      end
    end
  end
  set(U.AMBER); gfx.rect(x, top, w, bot - top, 0)
  if y0 >= L.body_y then
    set(U.BG); gfx.rect(x + 1, y0 + 1, math.min(w - 2, ms(g.name) + 2 * L.pad), L.rh - 1, 1)
    text(x + L.pad, y0 + 1, g.name, U.AMBER)
  end
  D.clip = keep
end
-- 20 окт: правый край последней видимой колонки трека (мастер сложен — граница его полосы)
function D.cols_edge(L)
  local e
  for _, c in ipairs(L.cols or {}) do
    if c.x and c.w and not c.master then e = math.max(e or 0, math.min(c.x + c.w, L.cols_r + 1)) end
  end
  return e
end
function D.mfold_draw(L, snap, hover)
  if not (L.mfold and snap.master and snap.master.track) then return end
  local tr = snap.master.track
  if not reaper.ValidatePtr(tr, 'MediaTrack*') then return end
  local x, w = L.cols_r + 1, L.master_w - 2
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hy, hh = L.header_y, L.header_h
  -- 20 окт: зазор от последней колонки до полосы — фон, граница — линия на всю высоту (шапка, линейка прыжков, строки)
  local ex = D.cols_edge(L) or x
  local ybot = L.body_y + L.body_h
  if ex < x then set(U.BG); gfx.rect(ex + 1, L.header_y, x - ex - 1, ybot - L.header_y, 1) end
  set(U.LINE); gfx.rect(ex, L.header_y, 1, ybot - L.header_y, 1)
  local keep = D.clip; D.clip = { x, x + w + 1 }   -- своя колонка: клип модуля рядом резал подписи
  local function done() D.clip = keep end
  set(D.HDR); gfx.rect(x, hy, w, hh, 1)
  -- 20 окт: ∑ — мастер (Opt+W набирает ∑ и ведёт сюда курсор); < — раскрыть
  text(x + L.pad, hy + 1, '∑', U.AMBER)
  local by = hy + L.rh + 2
  local bw = ms('<') + 4
  local hot = mx >= x + 1 and mx < x + 1 + bw and my >= by and my < by + L.rh
  set(hot and D.CURROW or U.PANEL); gfx.rect(x + 1, by, bw, L.rh - 2, 1)
  set(U.DIM); gfx.rect(x + 1, by, bw, L.rh - 2, 0)
  text(x + 3, by, '<', hot and U.AMBER or U.TEXT)
  if hot then hover.mfold = true end
  local gr = 0
  for k = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local ok, v = reaper.TrackFX_GetNamedConfigParm(tr, k, 'GainReduction_dB')
    local g = ok and tonumber(v)
    if g then gr = math.max(gr, math.abs(g)) end
  end
  -- подавление компрессора / лимитера — числом под <, если влезает (была третья полоса)
  if gr > 0.05 and by + 2 * L.rh <= hy + hh then
    local gs = ('-%.0f'):format(gr)
    if ms(gs) <= w - 2 then text(x + 1, by + L.rh, gs, U.RED) end
  end
  -- 20 окт (2): метр — как у треков (их стиль meterstyle, высота 57.5 % тела, тусклее): пики L R посередине,
  -- RMS L R (Track_GetPeakInfo 1024 / 1025 — то, что показывает VU мастера) узкими столбиками по бокам
  local y0, h0 = L.body_y, L.body_h
  set(U.BG); gfx.rect(x, y0, w, h0, 1)
  local pt = D.meterstyle == 'pt'
  local ncell = math.max(1, math.floor(L.nrows * 0.575))
  local maxh = pt and math.floor(h0 * 0.575) or ncell * L.rh
  local by = pt and (y0 + h0) or (y0 + L.nrows * L.rh)
  local function bar(bx, bw0, v, cyan)
    v = math.max(0, math.min(1, v))
    if pt then
      local segs = cyan and { { 0, 1, U.CYAN } } or { { 0, 0.6, U.GREEN }, { 0.6, 0.85, U.AMBER }, { 0.85, 1, U.RED } }
      for _, sg in ipairs(segs) do
        local s0, s1 = math.floor(sg[1] * maxh), math.floor(math.min(v, sg[2]) * maxh)
        if s1 > s0 then gfx.set(sg[3][1], sg[3][2], sg[3][3], 0.45); gfx.rect(bx, by - s1, bw0, s1 - s0, 1) end
      end
    else
      local eighths, cell = math.floor(v * ncell * 8 + 0.5), 0
      while eighths > 0 and cell < ncell do
        local part = math.min(8, eighths)
        local frac = (cell + 1) / ncell
        local col = cyan and U.CYAN or (frac > 0.85 and U.RED or (frac > 0.6 and U.AMBER or U.GREEN))
        local cy1 = by - cell * L.rh - 1
        local hh2 = math.max(1, math.floor((L.rh - 2) * part / 8 + 0.5))
        gfx.set(col[1], col[2], col[3], 0.5); gfx.rect(bx, cy1 - hh2, bw0, hh2, 1)
        eighths = eighths - part; cell = cell + 1
      end
    end
    gfx.a = 1
  end
  local rw = math.max(2, math.floor(L.cw / 2))
  local pw = math.max(2, math.floor((w - 4 - 2 * rw - 3) / 2))
  local px0 = x + 2 + rw + 1
  for ch = 0, 1 do
    bar(px0 + ch * (pw + 1), pw, reaper.Track_GetPeakInfo(tr, ch), false)
    bar(ch == 0 and (x + 2) or (px0 + 2 * pw + 2), rw, reaper.Track_GetPeakInfo(tr, 1024 + ch), true)
  end
  if mx >= x and mx < x + w and my >= y0 and my < y0 + h0 then hover.mfold_meter = gr end
  done()
end
function D.frame(L, snap, rows, state, info)
  D.clip = nil                                          -- граница модуля (9 окт) — только внутри своего блока
  D.SBW = math.max(1, math.min(12, tonumber(state.sbw) or 3))
  D.PHTAIL = math.max(0, math.min(32, tonumber(state.phtail) or 0))
  D.OFF_TXT = state.offbar and '|' or 'OFF'
  D.meterstyle = state.meterstyle   -- 20 окт: сложенный мастер рисует метр тем же стилем
  D.PIANO_SMALL = state.pianosmall or false
  D.mix_under, D.mix_under_next = D.mix_under_next, nil   -- микшер: был узкий трек → у всех фейдер ниже на 3 строки
  D.pmark('draw: top module')
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
      local bx0 = math.max(0, (L.top_x0 or 0) - 2)   -- левая колонка (браузер / матрица) — не затирать; 8 окт: −2 — левая граница модуля в кадре
      gfx.blit(1020, 1, 0, bx0, 0, gfx.w - bx0, L.top_h, bx0, ty, gfx.w - bx0, L.top_h)
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
    hover.poolkit = th.poolkit or hover.poolkit
    hover.poolpprev, hover.poolpnext = th.poolpprev or hover.poolpprev, th.poolpnext or hover.poolpnext
    hover.poolsort = th.poolsort or hover.poolsort
    hover.poolsortcol = th.poolsortcol
    hover.poolbsync = th.poolbsync or hover.poolbsync
    hover.scopemode, hover.monobtn, hover.retrobtn, hover.retro = th.scopemode, th.monobtn, th.retrobtn, th.retro
    hover.mm = th.mm
    hover.midimap = th.midimap
    hover.notes = th.notes or hover.notes
    hover.zone = th.zone or hover.zone
    hover.garden = th.garden
  end

  D.pmark('draw: track headers')
  -- 11 окт: модуль mixer — фон его листа до полосок (оболочка листов рисуется позже и его не трогает)
  if L.mix_pane then set(U.PANEL); gfx.rect(L.mix_pane.x, L.mix_pane.y, L.mix_pane.w, L.mix_pane.h, 1) end
  -- заголовок
  local hy = L.header_y
  set(U.PANEL); gfx.rect(tx0, hy, W - tx0, L.header_h, 1)
  local HX = L.hname_x or 0   -- 20 окт: запас строки имени — всё под именем ниже на HX
  hy = hy + HX
  local trsel = info.trsel or {}
  -- master (9 окт): нижний микшер — полоса master под колонкой номеров строк
  -- (там было пусто); та же отрисовка, что у трека, без шапки
  local hcols = L.cols
  if L.mix_bottom and snap and snap.master and snap.master.vol and (L.mstrip_w or L.label_w) >= 6 * L.cw and not L.mcol then   -- 17 окт: и при сложенном мастере (в микшере он нужен)   -- 11 окт: колонка мастера есть — полоса микшера у неё
    hcols = { table.unpack(L.cols) }
    hcols[#hcols + 1] = { col = snap.master, x = L.master_right and L.cols_r or tx0, w = L.master_right and L.master_w or L.label_w, lanes = {}, envs = {}, mls = {}, master = true }   -- 11 окт: справа
  end
  for _, c in ipairs(hcols) do
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
    if not c.master then
      hset(rbg); gfx.rect(c.x + 1, hy + nh, c.w - 1, L.header_h - 2 - nh - HX, 1)
      hset(nbg); gfx.rect(c.x + 1, hy - HX, c.w - 1, nh + HX, 1)
    end
    -- фон светлее панели: текст шапки подтянуть по контрасту (на колонку)
    local T0, G0 = U.TEXT, U.GREY
    U.TEXT, U.GREY = U.readable(T0, rbg, 4.5), U.readable(G0, rbg, 3.0)
    -- подписи кнопок (7 окт): читаемы на заливке КНОПКИ (панель), не шапки —
    -- на светлой шапке серый темнел и на тёмной кнопке пропадал (R I M S, + −)
    local BTXT = U.readable(G0, U.PANEL, 4.5)
    -- папки: вложенные треки сдвинуты и приглушены, папка помечена «+»
    local indent = (col.depth or 0) * L.cw
    local nm = (col.folder and ((state.fcollapse and state.fcollapse[col.guid]) and '> ' or '- ') or '') .. (col.name ~= '' and col.name or '-')
    -- имя трека — на всю ширину колонки (кнопки переехали строкой ниже);
    -- на светлой заливке — тёмным (контраст по яркости фона)
    local ncol = col.muted and U.GREY or ((col.depth or 0) > 0 and U.mix(U.TEXT, U.GREY, 0.4) or U.TEXT)
    ncol = U.readable(ncol, nbg, 4.5)
    if c.folded and not c.chord then   -- 26 окт: лейн аккордов широкий — обычная шапка и полоса микшера, не свёрнутая
      -- свёрнут в полоску (4 окт): имя вертикально во всю высоту шапки
      hset(rbg); gfx.rect(c.x + 1, hy, c.w - 1, nh, 1)
      -- 9 окт: в микшере у полоски — фейдер в знак шириной (метр + риска
      -- уровня); имя — над ним. Тянуть / f / Ctrl — как у большого
      local fy0, fy1
      if L.mixer then
        if L.mix_bottom then
          fy0, fy1 = L.mix_y + 4 + (L.route_h or 0), L.mix_y + L.mix_h - 3
          hset(rbg); gfx.rect(c.x + 1, L.mix_y, c.w - 1, L.mix_h, 1)
          set(D.SEP); gfx.rect(c.x, L.mix_y, c.w + 1, D.SEPW, 1)
        else
          fy0, fy1 = hy + 2 * L.rh + 1 + math.floor(L.mix_rows * L.rh / 3), hy + (2 + L.mix_rows) * L.rh - 2
        end
      end
      local nmh = (fy0 and not L.mix_bottom) and (fy0 - 4 - (hy + 2)) or (L.header_h - 5 - HX)
      D.vtext(c.x + math.floor((c.w - L.th) / 2), hy + 2, nmh, col.name ~= '' and col.name or '-', U.readable(ncol, rbg, 4.5), rbg, true)
      if fy0 and fy1 - fy0 >= 12 then D.mini_strip(col, c.x + 2, c.w - 3, fy0, fy1, info, hover, mx, my, L) end   -- 11 окт: + мини-кноб панорамы
    elseif not c.master then
      -- 20 окт: big trackname — крупно (x1.5 / x2), по ширине колонки
      local k = L.hname_k or 1
      if k > 1 then
        local s, aw = nm, c.w - 2 * L.pad - indent
        local bk = nm .. '|' .. aw .. '|' .. k                          -- 20 окт: обрезка по ширине — кэш (не мерить каждый кадр)
        D.bign = D.bign or {}
        if D.bign[bk] then s = D.bign[bk]
        else
          while #s > 1 and D.big_measure(s, k) > aw do s = s:sub(1, -2) end
          D.bign_n = (D.bign_n or 0) + 1; if D.bign_n > 500 then D.bign, D.bign_n = {}, 0 end
          D.bign[bk] = s
        end
        D.big_text(c.x + L.pad + indent, hy - HX + 1, s, ncol, k)
      else
        local amw = 0
        if not c.folded and c.w - 2 * L.pad - indent > ms('www') + 4 + 3 * L.cw then amw = D.amode_tag(L, c.x + c.w - L.pad, hy - HX + 1 + math.floor(HX / 2), col, hover, mx, my) end   -- 31 окт
        text(c.x + L.pad + indent, hy - HX + 1 + math.floor(HX / 2), fit(nm, c.w - 2 * L.pad - indent - (amw > 0 and amw + 2 or 0)), ncol)
      end
    else
      text(c.x + L.pad, hy - HX + 1 + math.floor(HX / 2), fit('∑ master', c.w - 2 * L.pad), U.AMBER)   -- 16 окт: шапка мастера подписана; 20 окт: ∑ (Opt+W)
      -- 17 окт: [fold] — сложить мастер в два символа (стерео-метр и подавление)
      if c.mtrack then
        local fw = ms('fold') + 4
        local fx = c.x + c.w - fw - 2
        if fx > c.x + ms('∑ master') + 2 * L.pad then
          local fhot = mx >= fx and mx < fx + fw and my >= hy and my < hy + L.rh
          set(fhot and D.CURROW or U.PANEL); gfx.rect(fx, hy + 1, fw, L.rh - 2, 1)
          set(U.DIM); gfx.rect(fx, hy + 1, fw, L.rh - 2, 0)
          text(fx + 2, hy + 1, 'fold', fhot and U.AMBER or U.GREY)
          if fhot then hover.mfold = true end
          -- 20 окт: [auto] — сложен, пока курсор не на мастере
          local aw = ms('auto') + 4
          local ax = fx - aw - 2
          if ax > c.x + ms('∑ master') + 2 * L.pad then
            local ahot = mx >= ax and mx < ax + aw and my >= hy and my < hy + L.rh
            local on = state.mfoldauto
            set(on and U.tint(U.CYAN, 0.25) or (ahot and D.CURROW or U.PANEL)); gfx.rect(ax, hy + 1, aw, L.rh - 2, 1)
            set(on and U.CYAN or U.DIM); gfx.rect(ax, hy + 1, aw, L.rh - 2, 0)
            text(ax + 2, hy + 1, 'auto', ahot and U.AMBER or (on and U.CYAN or U.GREY))
            if ahot then hover.mfoldauto = true end
          end
        end
      end
    end
    if col.rgb and mode == 'line' and not c.folded and not c.master then rawset_col(col.rgb); gfx.rect(c.x + 1 + indent, hy + L.rh - 1, c.w - 2 - indent, 2, 1) end
    -- 9 окт: полосы отступа вложенного трека нет (лишний серый разделитель) — вложенность видна по отступу имени
    if col.sel and not c.folded then set(U.CYAN); gfx.rect(c.x + 1, hy, c.w - 1, L.rh, 0) end   -- выделен в REAPER (Option+цифра)
    -- 30 окт: мастер — курсор на его колонке (или выделен в REAPER): рамка имени, как у выделенного трека
    if c.master then
      local vcm = info.vcur and L.flat and L.flat[info.vcur.fi]
      if (vcm and vcm.col == col) or (col.track and reaper.ValidatePtr(col.track, 'MediaTrack*') and reaper.IsTrackSelected(col.track)) then
        set(U.CYAN); gfx.rect(c.x + 1, hy, c.w - 1, L.rh, 0)
      end
    end
    if not c.master then hint('header', c.x + indent, hy, math.max(L.cw * 3, c.w - indent), L.rh, col) end
    -- строка 2: кнопки в порядке REAPER — R I M S A (A = автоматизация, как trim)
    if not c.folded or c.chord then   -- 26 окт: и лейн аккордов (у него своя полоса микшера, кнопки)
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
      -- 15 окт: без заглавных — i m s sro (пользователь: «no caps»)
      local labels = { { 'r', col.armed, D.ARM, 'arm' },
                       { 'i', mon > 0, U.CYAN, 'monitor', mon == 2 },
                       { 'm', col.muted, U.AMBER, 'mute' }, { 's', col.solo, U.GREEN, 'solo' },
                       { 'ø', col.phase, U.AMBER, 'phase' },          -- 8 окт: инверсия фазы (буква, как в блоке трека DSP)
                       { '~', nenv > 0, U.CYAN or U.AMBER, 'auto' } }   -- 15 окт: ~ — автоматизация (было trim), знак из глоссария справки
      -- 25 окт: fx — зелёная, когда на треке есть звучащие эффекты; серая — пусто, вся цепь выключена или все в bypass. Щелчок — цепь вкл / выкл
      if not c.master and col.track then
        D.hfx = D.hfx or {}
        local now = reaper.time_precise()
        local hc = D.hfx[col.guid]
        if not hc or now - hc.t > 0.25 then
          local n, live = reaper.TrackFX_GetCount(col.track), false
          if reaper.GetMediaTrackInfo_Value(col.track, 'I_FXEN') ~= 0 then
            for i = 0, n - 1 do if reaper.TrackFX_GetEnabled(col.track, i) then live = true; break end end
          end
          hc = { t = now, n = n, live = live }; D.hfx[col.guid] = hc
        end
        table.insert(labels, 5, { 'fx', hc.live, U.GREEN, 'fxen', fxn = hc.n })
      end
      -- trim (огибающие трека, бывшая A) — справа от всех кнопок, у края шапки (3 окт)
      local trim_w = ms('~') + 4
      local trim_x = c.x + c.w - L.pad - trim_w
      -- 9 окт: микшер открыт — R I M S ø столбиком справа от фейдера, в том же
      -- порядке (как кнопки у фейдера в микшере REAPER); в шапке остаётся trim.
      -- Не влезает по ширине / высоте полосы — как было, в строке шапки
      local mixcol = false
      if L.mixer and not c.master then
        local lw1 = (#c.lanes > 1 and c.lanes[1].w) or c.w
        local fxb = ((state.bigfader or state.ptmode) and (ms('-48') + 2) or 0) + D.FADER_W(L)
        local fh0 = (L.mix_rows - (tonumber(D.mix_under) or 0)) * L.rh - ((L.mix_bottom and state.mixnames ~= 'off') and L.rh or 0) - ((L.mix_bottom and state.hdrin ~= false) and L.rh or 0)
        mixcol = lw1 - 2 * L.pad >= fxb + L.btn_w + 2 and fh0 >= 6 * L.rh
        -- 9 окт: крупнее — до 2× по высоте (сколько позволяет фейдер) и по
        -- ширине, если эффекты остаются сбоку; 6-я — trim (автоматизация)
        if mixcol then
          -- 11 окт: как в микшере REAPER — маленькие, в строку высотой, плотным столбиком сверху (не растягиваются)
          D.mcb_w, D.mcb_h = math.max(L.btn_w, L.rh + 4), L.rh
        end
      end
      local function hbtn(b, x, by, bwk, bh, round)
        bh = bh or (L.rh - 2)
        -- 15 окт: буква — по центру рамки (по высоте шрифта, не строки)
        local tyc = by + math.floor((bh - (L.th or (L.rh - 2))) / 2) - (D.SPACE or 0)
        local on = b[2]
        local fill = on and (b[4] ~= 'auto' or env_shown) and not b[5]   -- b[5]: мониторинг «авто» — только контур
        -- 16 окт: ø — просто буква, без кнопки-фона
        if b[4] == 'phase' then
          local hot = mx >= x and mx < x + bwk and my >= by and my < by + bh
          -- 20 окт: в рамке, как соседние кнопки (включена — янтарная рамка)
          set(hot and D.CURROW or U.PANEL); gfx.rect(x, by, bwk, bh, 1)
          set((hot or on) and U.AMBER or U.DIM); gfx.rect(x, by, bwk, bh, 0)
          text(x + math.floor((bwk - ms('ø')) / 2), tyc, 'ø', (hot or on) and U.AMBER or BTXT)
          if hot then hover.trkio = { col = col, what = 'phase' } end
          hint('trkio', x, by, bwk, bh + 2, { col = col, what = 'phase' })
          return
        end
        -- 18 окт: ~ (автоматизация) — тоже просто знак, поярче: огибающие показаны — голубой, есть — текст, нет — серый
        -- (≈ — будущий знак модуляции)
        if b[4] == 'auto' then
          local hot = mx >= x and mx < x + bwk and my >= by and my < by + bh
          set(hot and D.CURROW or U.PANEL); gfx.rect(x, by, bwk, bh, 1)   -- 20 окт: в рамке
          set(hot and U.AMBER or (env_shown and U.CYAN or U.DIM)); gfx.rect(x, by, bwk, bh, 0)
          text(x + math.floor((bwk - ms('~')) / 2), tyc, '~', hot and U.AMBER or (on and (env_shown and U.CYAN or U.TEXT) or U.GREY))
          if hot then hover.btn = { col = col, what = 'auto' } end
          hint('btn', x, by, bwk, bh + 2, { col = col, what = 'auto' })
          D.trim_at = D.trim_at or {}; D.trim_at[col.guid] = { x, by + L.rh - 1, x + bwk }
          return
        end
        if b[4] == 'fxen' then   -- 25 окт: fx — буквами в рамке, зелёным при звучащих эффектах
          local hot = mx >= x and mx < x + bwk and my >= by and my < by + bh
          set(hot and D.CURROW or (on and U.tint(U.GREEN, 0.3) or U.PANEL)); gfx.rect(x, by, bwk, bh, 1)
          set(hot and U.AMBER or (on and U.GREEN or U.DIM)); gfx.rect(x, by, bwk, bh, 0)
          text(x + math.floor((bwk - ms('fx')) / 2), tyc, 'fx', hot and U.AMBER or (on and U.GREEN or U.GREY))
          if hot then hover.trkio = { col = col, what = 'fxen' } end
          hint('trkio', x, by, bwk, bh + 2, { col = col, what = 'fxen' })
          return
        end
        -- 15 окт: круглые — запись (кружок внутри; A — автоарм при выборе трека) и фаза (ø)
        if round then
          -- 30 окт: круг — в высоте соседних кнопок (bh), не bh + 2: был выше имени, потом залезал на fx ниже
          local r = math.floor((math.min(bwk, bh) - 1) / 2)
          local cx, cy = x + math.floor(bwk / 2), by + math.floor((bh - 1) / 2)
          local hot = mx >= x and mx < x + bwk and my >= by and my < by + bh
          local rc = b[4] == 'arm' and U.readable(U.RED, U.PANEL, 3) or (on and b[3] or BTXT)
          set(fill and ((b[3] == D.ARM and D.ARM_T) or U.tint(b[3], 0.5)) or U.PANEL); gfx.circle(cx, cy, r, 1, 1)
          set(hot and U.AMBER or (on and b[3] or (b[4] == 'arm' and rc or U.DIM))); gfx.circle(cx, cy, r, 0, 1)
          if b[4] == 'arm' then
            local aa = col.track and reaper.GetMediaTrackInfo_Value(col.track, 'B_AUTO_RECARM') == 1
            -- 15 окт: строчная a (без заглавных), по центру круга — не по прямоугольнику кнопки (съезжала)
            local al = b.cap and 'A' or 'a'   -- 16 окт: в микшере — A, как в REAPER (просьба; в шапке строчная)
            if aa then text(cx - math.floor(ms(al) / 2) + 1, cy - math.floor((L.th or (L.rh - 2)) / 2) - (D.SPACE or 0) + (b.cap and 1 or 0), al, on and U.TEXT or rc)   -- заглавная — на px ниже и правее (центр круга)
            else set(on and U.TEXT or rc); gfx.circle(cx, cy, math.max(1, math.floor(r / 2)), on and 1 or 0, 1) end
          else text(cx - math.floor(ms(b[1]) / 2), cy - math.floor((L.th or (L.rh - 2)) / 2) - (D.SPACE or 0), b[1], on and U.TEXT or BTXT) end
          local key = b[4] == 'phase' and 'trkio' or 'btn'
          if hot then hover[key] = { col = col, what = b[4] } end
          hint(key, x, by, bwk, bh + 2, { col = col, what = b[4] })
          return
        end
        set(fill and ((b[3] == D.ARM and D.ARM_T) or U.tint(b[3], 0.5)) or U.PANEL); gfx.rect(x, by, bwk, bh, 1)
        set(on and b[3] or U.DIM); gfx.rect(x, by, bwk, bh, 0)
        text(x + math.floor((bwk - ms(b[1])) / 2), tyc, b[1], on and b[3] or (b[4] == 'arm' and U.readable(U.RED, U.PANEL, 3) or BTXT))   -- 9 окт: R — красная всегда
        if b[4] == 'phase' then
          if mx >= x and mx < x + bwk and my >= by and my < by + bh then hover.trkio = { col = col, what = 'phase' } end
          hint('trkio', x, by, bwk, bh + 2, { col = col, what = 'phase' })
        else
          if mx >= x and mx < x + bwk and my >= by and my < by + bh then hover.btn = { col = col, what = b[4] } end
          hint('btn', x, by, bwk, bh + 2, { col = col, what = b[4] })
        end
        if b[4] == 'auto' then D.trim_at = D.trim_at or {}; D.trim_at[col.guid] = { x, by + L.rh - 1, x + bwk } end   -- меню trim под кнопкой
      end
      -- 12 окт: R I M S ø и SRO — вдвое шире, если до trim хватает места
      local avail = (trim_x or (c.x + c.w)) - bx - L.pad
      local srw = ms('SRO') + 4
      local bwh = math.max(L.btn_w, math.min(2 * L.cw + 4, math.floor((avail - srw * 1.5) / 5) - 1))   -- сколько влезает, не шире двойной
      D.hbtn_w = bwh
      -- 15 окт: (R) I · M S · SRO … (ø) trim: запись круглой, M S — отступом, фаза — у trim; высота — в строку (низ резался)
      local gap = L.pad
      -- 15 окт: рамки на 15 % больше (просьба); по высоте — до строки громкости, не на неё
      bwh = math.floor(bwh * 1.15 + 0.5); D.hbtn_w = bwh
      trim_w = math.max(ms('~'), ms('ø')) + 7; trim_x = c.x + c.w - L.pad - trim_w   -- 20 окт: ~ и ø — в рамке, чуть шире
      -- 30 окт: 2 px между строками кнопок (и зоны щелчка без захода на соседнюю строку) — не прицеливаться
      local bhh = L.rh - 3
      local phw = math.max(ms('~'), ms('ø')) + 7
      local ph_x = trim_x - 1 - phw
      -- 18 окт: узкий трек — r i m s сжимаются (до ширины буквы), чтобы /// влезли в первую строку
      do
        local sw0 = ms(D.sroslash and '///' or 'sro') + 4
        local bmin = ms('m') + 4
        while bwh > bmin and bx + 4 * (bwh + 1) + 2 * L.pad + sw0 > ph_x - L.pad do bwh = bwh - 1 end
        D.hbtn_w = bwh
      end
      -- 16 окт: не влезло в строку кнопок — во вторую, свободную строку над − + (узкий трек: m s ø ~ sro не пропадают)
      local rest = {}
      local fxw = ms('fx') + 6
      local sro0 = ms(D.sroslash and '///' or 'sro') + 4
      D.hfx_row1 = nil
      for k, b in ipairs(c.master and {} or labels) do
        local x = bx + (k - 1) * (bwh + 1) + (k >= 3 and gap or 0)
        local bwk = bwh
        if b[4] == 'phase' then x, bwk = ph_x, phw end
        if b[4] == 'auto' then x, bwk = trim_x, trim_w end
        if b[4] == 'fxen' then bwk = fxw end   -- 25 окт: сразу за s; не влезает до /// и ø — во вторую строку
        if b[4] == 'fxen' and (mixcol or x + fxw + L.pad + sro0 > ph_x - L.pad) then
          rest[#rest + 1] = b
        elseif b[4] == 'fxen' then D.hfx_row1 = fxw + 1; hbtn(b, x, by, bwk, bhh, false)
        elseif ((b[4] == 'auto' or b[4] == 'phase') and ph_x < bx + 4 * (bwh + 1) + gap + L.pad) or x + bwk > c.x + c.w - 1 then
          rest[#rest + 1] = b
        elseif not mixcol then hbtn(b, x, by, bwk, bhh, b[4] == 'arm' or b[4] == 'phase') end
      end
      -- 25 окт: мастер — кнопка mono (как MONO в микшере REAPER: действие 40917, сумма L+R)
      if c.master and not mixcol then
        D.mmono = D.mmono or { t = 0 }
        local now = reaper.time_precise()
        if now - D.mmono.t > 0.25 then D.mmono.t = now; D.mmono.on = reaper.GetToggleCommandState(40917) == 1 end
        local mw = ms('mono') + 6
        if bx + mw <= c.x + c.w - 1 then
          local on = D.mmono.on
          local hot = mx >= bx and mx < bx + mw and my >= by and my < by + bhh + 2
          -- 27 окт: mono включён — мигает розовым (раз в полсекунды: яркая заливка / бледная), не забыть, что слушаешь моно
          local blink = on and math.floor(now * 2) % 2 == 0
          set(hot and D.CURROW or (on and U.tint(U.PINK, blink and 0.75 or 0.25) or U.PANEL)); gfx.rect(bx, by, mw, bhh, 1)
          set(hot and U.AMBER or (on and U.PINK or U.DIM)); gfx.rect(bx, by, mw, bhh, 0)
          text(bx + 3, by + math.floor((bhh - (L.th or (L.rh - 2))) / 2) - (D.SPACE or 0), 'mono', hot and U.AMBER or (on and (blink and U.BG or U.PINK) or BTXT))
          if hot then hover.mmono = true end
          hint('mmono', bx, by, mw, bhh + 2, true)
        end
      end
      local by2 = hy + (L.lane_row - 1) * L.rh
      local x2 = bx
      local function row2(w) if mixcol or L.hr_info > 0 or x2 + w > c.x + c.w - 1 then return nil end; local x = x2; x2 = x2 + w + 1; return x end
      -- 16 окт: порядок второй строки — sro, ø, … ; ~ (автоматизация) — у правого края шапки (рисуется ниже, после sro)
      local function draw_rest()
        for _, b in ipairs(rest) do
          if b.done then b.done = nil
          elseif b[4] == 'auto' then
            local x = c.x + c.w - L.pad - bwh
            if not mixcol and L.hr_info == 0 and x >= x2 then hbtn(b, x, by2, bwh, bhh, false) end
          else
            local bw2 = b[4] == 'fxen' and fxw or bwh
            local x = row2(bw2)
            if x then hbtn(b, x, by2, bw2, bhh, b[4] == 'phase') end
          end
        end
      end
      -- route (9 окт): SRO вместо слова — S сенды, R ресивы, O аппаратные
      -- выходы; буква светится, если есть. Щелчок — окно маршрутизации трека.
      -- Без микшера — после ø, если влезает до trim; с микшером — в начале строки
      -- 9 окт: с микшером — седьмой в столбике у фейдера (буквы столбиком,
      -- если в ширину не влезают); не влезает по высоте — в строке шапки
      local function sro(rx, ry, rw, rhh, vert)
        local has = { reaper.GetTrackNumSends(col.track, 0) > 0, reaper.GetTrackNumSends(col.track, -1) > 0, reaper.GetTrackNumSends(col.track, 1) > 0 }
        local hot = mx >= rx and mx < rx + rw and my >= ry and my < ry + rhh + 2
        set(hot and D.CURROW or U.PANEL); gfx.rect(rx, ry, rw, rhh, 1)
        set((has[1] or has[2] or has[3]) and U.CYAN or U.DIM); gfx.rect(rx, ry, rw, rhh, 0)
        local th3 = L.rh - 4
        local lx = vert and 0 or (rx + math.floor((rw - ms('sro')) / 2))
        local ly = vert and (ry + math.floor((rhh - 3 * th3) / 2) - 1) or (ry + math.floor((rhh - (L.rh - 2)) / 2))
        if D.sroslash ~= false then
          -- 16 окт: /// — жирными полосками (как в REAPER): сенды голубым, ресивы зелёным, выходы янтарём
          local n = 3
          local seg = vert and math.floor((rhh - 4) / n) or math.floor((rw - 4) / n)
          for i = 1, n do
            local k3 = ({ U.CYAN, U.GREEN, U.AMBER })[i]
            local cc = has[i] and k3 or U.mix(k3, U.PANEL, 0.68)   -- 16 окт: пусто — бледным своим цветом, есть — ярко
            set(cc)
            local x0, y0, x1, y1
            -- 16 окт: внутри рамки — отступ 2 px с каждой стороны с учётом толщины (3 px)
            if vert then
              local yy = ry + 2 + (i - 1) * seg
              x0, y0, x1, y1 = rx + 3, yy + seg - 2, rx + rw - 6, yy + 2
            else
              -- 20 окт: плотно — шаг = наклон + толщина + 1 px, тройка по центру рамки
              local sl = math.max(2, math.floor((rhh - 5) * 0.45))
              local step = sl + 4
              while step > 4 and 3 * step + 1 > rw - 4 do step = step - 1; sl = math.max(2, step - 4) end
              local xx = rx + math.floor((rw - (3 * step - 1)) / 2) + (i - 1) * step
              x0, y0, x1, y1 = xx, ry + rhh - 3, xx + sl, ry + 2
            end
            if x1 > x0 then for t = 0, 2 do gfx.line(x0 + t, y0, x1 + t, y1) end end
          end
          if hot then hover.btn = { col = col, what = 'route' } end
          hint('btn', rx, ry, rw, rhh + 2, { col = col, what = 'route' })
          return
        end
        for i, ch in ipairs(D.sroslash and { '/', '/', '/' } or { 's', 'r', 'o' }) do   -- 16 окт: опция routing as /// (как в REAPER)
          local k3 = ({ U.CYAN, U.GREEN, U.AMBER })[i]
          local cc = has[i] and k3 or U.mix(k3, U.PANEL, 0.68)   -- S голубой, R зелёный, O янтарь; 16 окт: пусто — бледным своим
          if vert then text(rx + math.floor((rw - ms(ch)) / 2), ly + (i - 1) * th3, ch, cc)
          elseif rw >= 2 * ms('SRO') then text(rx + math.floor((i - 1) * rw / 3 + (rw / 3 - ms(ch)) / 2), ly, ch, cc)   -- 12 окт: широкая — буквы врозь
        else text(lx, ly, ch, cc); lx = lx + ms(ch) end
        end
        if hot then hover.btn = { col = col, what = 'route' } end
        hint('btn', rx, ry, rw, rhh + 2, { col = col, what = 'route' })
      end
      D.sro_col = nil
      if not c.master and col.track and reaper.ValidatePtr(col.track, 'MediaTrack*') then
        if mixcol then
          local vert = ms(D.sroslash and '///' or 'SRO') + 4 > D.mcb_w
          local rhh = vert and math.max(D.mcb_h, 3 * (L.rh - 4) + 4) or D.mcb_h
          local fh0 = (L.mix_rows - (tonumber(D.mix_under) or 0)) * L.rh - ((L.mix_bottom and state.mixnames ~= 'off') and L.rh or 0) - ((L.mix_bottom and state.hdrin ~= false) and L.rh or 0)
          if 6 * (D.mcb_h + 2) + rhh <= fh0 then D.sro_col = { rhh = rhh, vert = vert, draw = sro } end
        end
        -- 15 окт: SRO — после M S (фаза ушла к trim)
        local hw1 = (D.hbtn_w or L.btn_w) + 1
        local rx = mixcol and bx or (bx + 4 * hw1 + 2 * L.pad + (D.hfx_row1 or 0))
        local lim = mixcol and (c.x + c.w - 1) or (ph_x - L.pad)
        local sw0 = ms(D.sroslash and '///' or 'sro') + 4               -- 16 окт: по настоящей ширине (было по заглавным SRO — не влезало между s и ø)
        local rw = D.sroslash ~= false and sw0 or math.max(sw0, math.min(2 * sw0, lim - rx))   -- 12 окт: SRO шире, сколько влезает; 20 окт: /// — плотно, не растягивать
        if not D.sro_col and rx + rw <= lim then sro(rx, by, rw, bhh, false)
        elseif not D.sro_col then
          -- 16 окт: вторая строка — ø под p (панорама), за ним sro; ~ — у правого края (draw_rest)
          for _, b in ipairs(rest) do if b[4] == 'phase' then local x = row2(math.max(ms('ø') + 4, L.btn_w)); if x then hbtn(b, x, by2, math.max(ms('ø') + 4, L.btn_w), bhh, true) end; b.done = true end end
          local w2 = ms(D.sroslash and '///' or 'sro') + 4; local x = row2(w2); if x then sro(x, by2, w2, bhh, false) end
        end
      end
      draw_rest()   -- 16 окт: остальное второй строки и ~ справа
      D.hdr_row2_free = (x2 == bx) and by2 or nil   -- 16 окт: вторая строка кнопок пуста — там строка width
      -- строки 3 и 4: громкость и панорама — горизонтальные слайдеры как в DSP;
      -- панорама: stereo pan (5) — pan + width, dual pan (6) — L + R в одной строке
      local live = info.trs_live
      local function slider(sx, sy, sw, frac, centered, label, val, what, in_pop, noval)
        -- узко (3 окт): дорожке меньше трёх символов — слайдер сворачивается в
        -- кнопку-букву; клик — всплывающий слайдер под ней (D.trspop), повтор — закрыть
        -- 22 окт: порог — дорожка с местом под значение уже 5 знаков (было: без значения, меньше 3 — мелкий слайдер оставался)
        local vres0 = noval and 0 or (math.max(ms(what == 'vol' and '-00.0' or (what == 'width' and '100' or 'R100')), ms(val or '')) + L.pad)
        if not in_pop and sw - ms(label) - 2 * L.pad - vres0 < ms('000') then   -- 22 окт: 3 знака (5 сворачивал и нормальные слайдеры)
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
        -- 18 окт: панорама — цвет стороны (как в REAPER): левая половина фиолетовая, правая зелёная
        U.dslider(wx0, cy, ww, frac, centered, acc, hot, L.rh, what == 'pan' or what == 'panl' or what == 'panr')   -- 13 окт: ромбик
        if show_val then text(wx0 + ww + L.pad + vres - ms(val), sy, val, U.GREY) end
        if hot then hover.trs = { col = col, what = what, x0 = wx0, w = ww, sv = math.max(0, math.min(1, (mx - wx0) / math.max(1, ww))) } end
        if D.csel_on(col.guid, what) then csel_frame(wx0 - 1, sy + 2, ww + 2, L.rh - 4) end
        hint('trs', wx0, sy, ww, L.rh, { col = col, what = what })
        if D.slr then D.slr[#D.slr + 1] = { g = 'trs:' .. tostring(col.guid), col = col, trk = what, name = label .. ' ' .. (col.name or ''), own = col.name, pn = label, x = wx0, y = sy, w = ww, h = L.rh } end   -- 14 окт: CONTROL
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
      local py = hy + 3 * L.rh + 1
      local px, pw = sx, sw
      local mixin_y                                   -- 9 окт: строка входа в полосе нижнего микшера
      if L.mixer then
        -- 8 окт: полоса микшера. Сверху вниз: dB, панорама (две строки
        -- зарезервированы всегда), фейдер. Фейдер ОДНОГО размера на всех
        -- треках: высота — 2/3 полосы, ширина — подписи + коробка 6 знаков;
        -- эффекты с параметрами — сбоку (если влезают) / под фейдером
        local y1 = L.mix_bottom and (L.mix_y + 3 + (L.route_h or 0)) or (hy + 2 * L.rh + 1)
        local H = L.mix_rows * L.rh
        if c.master then D.lufs_row_y = nil end
        if L.mix_bottom then
          hset(rbg); gfx.rect(c.x + 1, L.mix_y, c.w - 1, L.mix_h, 1)
          set(D.SEP); gfx.rect(c.x, L.mix_y, c.w + 1, D.SEPW, 1)
          -- 9 окт: шапка далеко — имя трека ещё раз в полосе (опция mixer names)
          if state.mixnames ~= 'off' and not c.master then
            H = H - L.rh
            local ny = y1 + H
            if state.mixnames == 'top' then ny = y1; y1 = y1 + L.rh end
            local amw = (c.w - 2 * L.pad > ms('www') + 4 + 3 * L.cw) and D.amode_tag(L, c.x + c.w - L.pad, ny, col, hover, mx, my) or 0   -- 31 окт
            text(c.x + L.pad, ny, fit(nm, c.w - 2 * L.pad - (amw > 0 and amw + 2 or 0)), ncol)
          end
          if state.hdrin ~= false and not c.master then H = H - L.rh; mixin_y = y1 + H end   -- вход — над именем, под эффектами
          -- 9 окт: мастер — кнопка routing внизу полосы (аппаратные выходы, окно)
          if c.master and col.track then
            H = H - 2 * L.rh                              -- 10 окт: строка среднего LUFS над routing
            D.lufs_row_y = y1 + H
            local ry, rx, rw = y1 + H + L.rh, c.x + 2, math.min(c.w - 4, ms('routing') + 2 * L.pad)   -- 13 окт: ровно под кнопкой метра
            local hw = reaper.GetTrackNumSends(col.track, 1) > 0
            local hot = mx >= rx and mx < rx + rw and my >= ry and my < ry + L.rh
            set(hot and D.CURROW or U.PANEL); gfx.rect(rx, ry + 1, rw, L.rh - 1, 1)
            set(hw and U.AMBER or U.DIM); gfx.rect(rx, ry + 1, rw, L.rh - 1, 0)
            text(rx + L.pad, ry, fit('routing', rw - 2 * L.pad), (hot or state.routeview) and U.AMBER or (hw and U.AMBER or BTXT))
            if hot then hover.btn = { col = col, what = 'routeview' } end   -- 9 окт: диаграмма всех треков
            hint('btn', rx, ry, rw, L.rh, { col = col, what = 'routeview' })
            -- SRO мастера — его собственная маршрутизация (попап, как у треков)
            local sx2, sw2 = rx + rw + 2, ms(D.sroslash and '///' or 'SRO') + 4
            if sx2 + sw2 <= c.x + c.w - 1 then
              local has = { reaper.GetTrackNumSends(col.track, 0) > 0, reaper.GetTrackNumSends(col.track, -1) > 0, hw }
              local hot2 = mx >= sx2 and mx < sx2 + sw2 and my >= ry and my < ry + L.rh
              set(hot2 and D.CURROW or U.PANEL); gfx.rect(sx2, ry + 1, sw2, L.rh - 1, 1)
              set((has[1] or has[2] or has[3]) and U.CYAN or U.DIM); gfx.rect(sx2, ry + 1, sw2, L.rh - 1, 0)
              local lx = sx2 + 2
              for i, ch in ipairs(D.sroslash and { '/', '/', '/' } or { 'S', 'R', 'O' }) do   -- 17 окт: опция routing as /// и у мастера
                local k3 = ({ U.CYAN, U.GREEN, U.AMBER })[i]
                text(lx, ry, ch, has[i] and k3 or U.mix(k3, U.PANEL, 0.68)); lx = lx + ms(ch)   -- 16 окт: пусто — бледным своим цветом
              end
              if hot2 then hover.btn = { col = col, what = 'route' } end
              hint('btn', sx2, ry, sw2, L.rh, { col = col, what = 'route' })
            end
          end
        end
        local lw1 = (#c.lanes > 1 and c.lanes[1].w) or c.w
        local lblw0 = ms('-48') + 2
        -- 9 окт: по умолчанию — узкая коробка 5 знаков без подписей; big fader
        -- (и pt-mode) — с подписями dB слева
        local bigf = state.bigfader or state.ptmode
        -- 9 окт: отступ вложенности (дети папки) фейдер не сужает — у каналов
        -- одной ширины фейдер и кноб одинаковые (полосы отступа больше нет)
        local fx_w = math.min(lw1 - 2 * L.pad, (bigf and lblw0 or 0) + D.FADER_W(L))   -- 9 окт: 3 знака (метки -12 / -48), было 5 — на x2 слишком широко
        -- 9 окт: линия «фейдер | эффекты» — продолжение вертикали колонки
        -- трекера (граница лейна / подколонки / огибающей), стык встык; фейдер
        -- с кнобом — посередине своей части. Нет подходящей линии — как было
        local sx = c.x + L.pad
        -- 10 окт: у мастера по тонкому столбику громкости (LUFS) слева и справа от фейдера
        -- 10 окт: пропорции мастера — столбики LUFS втрое шире прежних, коробка
        -- пиков в 2.5 раза уже прежней широкой; справа всегда место под эффекты
        -- мастера (от 3 букв)
        local lufs_w = (c.master and col.track) and 3 * math.max(3, math.floor(L.cw / 2)) or 0
        -- 11 окт: низкий микшер (фейдер короче 3 строк) — мини-полоса, как у свёрнутой колонки
        local und0 = tonumber(D.mix_under) or 0
        local compact = (((und0 > 0 and not c.master) and (H - und0 * L.rh) or H) - 4 - (4 * L.rh + 7)) < 3 * L.rh
        if compact then lufs_w = 0; fx_w = D.MINI_W(L) end
        if lufs_w > 0 then sx = sx + lufs_w + 2 end
        -- 10 окт: мастер без эффектов — свёрнут в широкий фейдер (вся полоса;
        -- пики L R посередине, LUFS по краям, имя — в строке значения)
        local mfx_need = 3 * ms('W') + 2 * L.pad + 4                 -- место эффектов мастера: 3 буквы
        if lufs_w > 0 then
          local room = c.w - 2 * L.pad - 2 * (lufs_w + 2)
          fx_w = math.max(6, math.min(math.floor(room / 2.5), room - mfx_need))
        end
        local sepx, sepc
        local colw = mixcol and (D.mcb_w + 2) or 0      -- столбик кнопок справа от фейдера
        if not c.master then
          local need = sx + fx_w + colw + L.pad
          local function cand(x, cl) if x >= need and c.x + c.w - 2 - (x + 2) >= 5 * L.cw and (not sepx or x < sepx) then sepx, sepc = x, cl end end
          for li, ln in ipairs(c.lanes) do
            if li > 1 then cand(ln.x - 1, U.DIM) end
            for si = 2, ln.nsub or 1 do cand(ln.x + (ln.sx and ln.sx[si] or (si - 1) * L.sub_w), D.EMPTY) end
          end
          for _, ev in ipairs(c.envs) do cand(ev.x - 1, U.DIM) end
          for _, m in ipairs(c.mls or {}) do cand(m.x - 1, U.DIM) end
          if sepx then sx = c.x + 1 + math.floor((sepx - c.x - 1 - fx_w - colw) / 2) end
        end
        -- эффекты сбоку, если влезают 5 знаков — тогда фейдер на всю высоту
        -- полосы; иначе под ним 3 строки эффектов. Высота фейдера при этом
        -- одна на всех треках: решает ширина трека, а она у треков своя —
        -- поэтому всегда берём меньшую (H − 3 строки), если хоть один трек
        -- узкий (L.mix_under — с прошлого кадра)
        local side = sepx ~= nil or c.x + c.w - 2 - (sx + fx_w + colw + lufs_w + 2 + L.pad + 2) >= ((lufs_w > 0) and (mfx_need - 2 * L.pad) or 5 * L.cw)
        -- 10 окт: резерв под эффекты под фейдером — по числу эффектов (0..3 строки), не всегда 3:
        -- без эффектов фейдеры на всю высоту (было пустое место снизу)
        if not side and not c.master then
          local nfx = math.min(3, #((c.col and c.col.fx) or {}))
          D.mix_under_next = math.max(tonumber(D.mix_under_next) or 0, nfx)
        end   -- узкий master не перестраивает треки (9 окт)
        local und = tonumber(D.mix_under) or 0
        local fh = (und > 0 and not (c.master and not side)) and (H - und * L.rh) or H
        -- 16 окт: как в микшере REAPER — запись (o) под фейдером, размером с кноб панорамы; фейдер короче
        local rec_d = (mixcol and not compact) and math.min(2 * L.rh - 2, fx_w) or 0
        if compact then D.mini_strip(col, sx, fx_w, y1, y1 + fh - 2, info, hover, mx, my, L) else
        local vtxt = db <= -60 and '-inf' or ('%+.1f'):format(db)
        if ms(vtxt) > fx_w then vtxt = db <= -60 and '-' or ('%+.0f'):format(db) end   -- 9 окт: узко — без десятых
        if lufs_w > 0 then
          -- мастер: имя слева и dB справа — строкой во всю полосу, эффекты под ней
          local vw = ms(vtxt)
          text(c.x + c.w - L.pad - vw, y1, vtxt, U.GREY)
          text(c.x + L.pad, y1, fit('master', c.w - 3 * L.pad - vw), U.AMBER)
        elseif ms(vtxt) <= fx_w then text(sx + math.floor((fx_w - ms(vtxt)) / 2), y1, vtxt, U.GREY) end
        local pyy = y1 + L.rh
        -- 9 окт: узкий фейдер — панорама кнобом (две строки, тянуть вверх /
        -- вниз, Shift мелко); big fader — слайдерами, как было
        local function knob(kx, ky, d, frac, what, val, width)
          local r = math.floor((d - 1) / 2)
          local cx, cy = kx + r, ky + r
          local khot = mx >= kx and mx < kx + 2 * r + 1 and my >= ky and my < ky + 2 * r + 1
          local ks = info.kslider
          local kon = ks and ks.what == what and ks.col and ks.col.guid == col.guid
          local kdark = U.mix(U.BG, { 0, 0, 0 }, 0.55)
          set(kdark); gfx.circle(cx, cy, r, 1, 0)
          set((khot or kon) and U.AMBER or U.LINE); gfx.circle(cx, cy, r, 0, 0)
          -- шкала: от центра (верх) до значения — дуга цветом, риска — указатель
          local a = (frac - 0.5) * 1.5 * math.pi                   -- −135° … +135°, 0 — верх
          -- 9 окт: дуги значения нет — только точка-указатель
          -- указатель — яркая точка на краю (9 окт, вместо линии)
          local pcol = U.readable((khot or kon) and U.AMBER or U.TEXT, kdark, 7)
          local pr = math.max(1, math.floor(r / 5))   -- 30 окт: шарик чуть меньше (было r / 4)
          local rr = r - pr - 3   -- 30 окт: на 2 px ближе к центру
          set(pcol)
          gfx.circle(cx + math.floor(math.sin(a) * rr + 0.5), cy - math.floor(math.cos(a) * rr + 0.5), pr, 1, 0)
          if val and kx + 2 * r + 1 + L.pad + ms(val) <= sx + fx_w then text(kx + 2 * r + 1 + L.pad, ky + math.floor((2 * r + 1 - L.th) / 2), val, U.GREY) end
          if khot then hover.trs = { col = col, what = what, knob = true, sv = frac } end
          if D.csel_on(col.guid, what) then csel_frame(kx - 1, ky - 1, 2 * r + 3, 2 * r + 3) end
          hint('trs', kx, ky, 2 * r + 1, 2 * r + 1, { col = col, what = what })
        end
        -- 10 окт: одна панорама — кноб ровно над метром по центру; две (stereo pan / dual pan) —
        -- двумя слайдерами, как в микшере REAPER
        -- 16 окт: свой кноб на режим пана — balance / mono: одна точка; stereo pan: кноб + вертикальный
        -- слайдер width справа (тянуть вверх — шире); dual pan: два кноба L и R рядом
        local kd = math.min(2 * L.rh - 2, fx_w)
        if not bigf and state.panknob ~= false and col.panmode == 6 and fx_w >= 2 * (L.rh + 2) then
          local d2 = math.min(2 * L.rh - 2, math.floor((fx_w - 2) / 2))
          knob(sx, pyy, d2, (lv('panl', col.panL or -1) + 1) / 2, 'panl')
          knob(sx + fx_w - d2, pyy, d2, (lv('panr', col.panR or 1) + 1) / 2, 'panr')
        elseif not bigf and state.panknob ~= false and col.panmode ~= 6 then
          -- 18 окт: над кнобом пана — слайдер width (правка в режиме без ширины включает stereo pan — edit.track_value)
          local wv = lv('width', col.width or 1)
          -- 18 окт: дорожкой без подписи (in_pop = true — не сворачиваться в кнопку w в узкой зоне); значение — в статусе
          slider(sx, pyy, fx_w, (wv + 1) / 2, true, '', math.floor(wv * 100 + 0.5) .. '', 'width', true, true)
          local d = math.min(kd, 2 * L.rh - 2)
          knob(sx + math.floor((fx_w - d) / 2), pyy + L.rh, d, (lv('pan', col.pan or 0) + 1) / 2, 'pan', pan_txt(lv('pan', col.pan or 0)))
        elseif col.panmode == 5 then
          slider(sx, pyy, fx_w, (lv('pan', col.pan or 0) + 1) / 2, true, 'p', pan_txt(lv('pan', col.pan or 0)), 'pan', nil, true)
          slider(sx, pyy + L.rh, fx_w, (lv('width', col.width or 1) + 1) / 2, true, 'w', math.floor(lv('width', col.width or 1) * 100 + 0.5) .. '', 'width', nil, true)
        elseif col.panmode == 6 then
          -- 18 окт: dual pan в узкой полоске — две дорожки (L сверху, R снизу, как в микшере REAPER), не кнопки L R;
          -- in_pop = true — не сворачиваться; без подписи, значение — в статусе
          local narrow = not bigf and fx_w - ms('L') - 2 * L.pad < ms('000')
          slider(sx, pyy, fx_w, (lv('panl', col.panL or -1) + 1) / 2, true, narrow and '' or 'L', pan_txt(lv('panl', col.panL or -1)), 'panl', narrow or nil, true)
          slider(sx, pyy + L.rh, fx_w, (lv('panr', col.panR or 1) + 1) / 2, true, narrow and '' or 'R', pan_txt(lv('panr', col.panR or 1)), 'panr', narrow or nil, true)
        else
          slider(sx, pyy, fx_w, (lv('pan', col.pan or 0) + 1) / 2, true, 'p', pan_txt(lv('pan', col.pan or 0)), 'pan', nil, true)
        end
        local wrow = (not bigf and state.panknob ~= false and col.panmode ~= 6) and L.rh or 0   -- 18 окт: строка width над паном
        local ty0, ty1 = y1 + 4 * L.rh + 7 + wrow, y1 + fh - 4 - (rec_d > 0 and (rec_d + 4) or 0)   -- строка над метром — макс. пик
        local th = math.max(8, ty1 - ty0)
        -- тёмная коробка, внутри метр как в DSP (две полоски L R в рамках),
        -- шкала dB слева (+6 0 -6 -12 -24 -48), ручка [-] поверх;
        -- клавиатура — метка f → k j
        local function ypos(dbv) return ty0 + th - math.floor(th * D.fader_pos(dbv) + 0.5) end
        local hot = mx >= sx and mx < sx + fx_w and my >= ty0 - 4 and my < ty0 + th + 4
        local ks = info.kslider
        local kon = ks and ks.what == 'vol' and ks.col and ks.col.guid == col.guid
        if kon then set(U.AMBER); gfx.rect(c.x + 1, y1 - 1, c.w - 1, H, 0) end   -- полоса под клавиатурой (щелчок / f): k j громкость, h l панорама
        local lblw = (bigf and fx_w >= lblw0 + 4 * L.cw) and lblw0 or 0
        local bx0, bw0 = sx + lblw, fx_w - lblw
        if D.slr then D.slr[#D.slr + 1] = { g = 'mix', ori = 'v', col = col, trk = 'vol', name = col.name or '', x = bx0, y = ty0, w = bw0, h = th } end   -- 14 окт: CONTROL — фейдеры вертикальные
        local dark = U.mix(U.BG, { 0, 0, 0 }, 0.55)
        local tick = U.mix(U.GREY, dark, 0.45)          -- 9 окт: риски темнее, как метки
        set(dark); gfx.rect(bx0, ty0 - 6, bw0, th + 9, 1)
        set((hot or kon) and U.AMBER or U.LINE); gfx.rect(bx0, ty0 - 6, bw0, th + 9, 0)
        -- метр: пики трека, шкала та же, что у фейдера (метки совпадают);
        -- удержание пика __ (1.5 с, потом падает) — своё, только рисунок;
        -- максимум цифрами сверху и клип (> 0 dB, красное ==) — НАТИВНЫЕ
        -- (Track_GetPeakHoldDB, как в микшере REAPER: те же цифры, тот же
        -- сброс; щелчок по числу — hover.mixpk — чистит оба)
        local hold = D.mix_hold[col.guid]
        if not hold then hold = { { db = -150, t = 0 }, { db = -150, t = 0 } }; D.mix_hold[col.guid] = hold end
        hold.max = -150
        if col.track and reaper.ValidatePtr(col.track, 'MediaTrack*') then
          for ch = 0, 1 do hold.max = math.max(hold.max, reaper.Track_GetPeakHoldDB(col.track, ch, false) * 100) end
        end
        hold.clip = hold.max > 0
        local now = reaper.time_precise()
        local mw = math.max(2, math.floor((bw0 - 10) / 2))
        -- 22 окт: где-то solo — у остальных каналов метр тусклее и маленькая яркая s! (их не слышно)
        local muted_by_solo = false
        if not col.solo and not col.master then
          for _, c2 in ipairs(L.cols or {}) do if c2.col and c2.col.solo then muted_by_solo = true; break end end
        end
        for k2 = 1, 2 do
          local pk = 0
          if info.peaks then local pl, pr = info.peaks(col); pk = (k2 == 1 and pl or pr) or 0 end
          local pdb = pk > 1e-6 and 20 * math.log(pk, 10) or -150
          local hk = hold[k2]
          if pdb >= hk.db then hk.db, hk.t = pdb, now
          elseif now - hk.t > 1.5 then hk.db = math.max(pdb, hk.db - 20 * (now - hk.t - 1.5)) end
          local mx0 = bx0 + 4 + (k2 - 1) * (mw + 2)
          set(U.mix(dark, U.TEXT, 0.12)); gfx.rect(mx0, ty0, mw, th, 0)
          if pdb > -60 then
            local function seg(d0, d1, c3) local ya, yb = ypos(math.min(pdb, d1)), ypos(d0); if yb > ya then set(muted_by_solo and U.mix(c3, dark, 0.55) or c3); gfx.rect(mx0 + 1, ya, mw - 2, yb - ya, 1) end end
            seg(-60, -6, U.GREEN); if pdb > -6 then seg(-6, 0, U.AMBER) end; if pdb > 0 then seg(0, 12, U.RED) end
          end
          if hk.db > -60 then
            set(hk.db > 0 and U.RED or (hk.db > -6 and U.AMBER or U.GREEN)); gfx.rect(mx0 + 1, ypos(hk.db), mw - 2, 1, 1)
          end
          if hold.clip then set(U.RED); gfx.rect(mx0 + 1, ty0 - 2, mw - 2, 1, 1); gfx.rect(mx0 + 1, ty0 - 4, mw - 2, 1, 1) end
        end
        if muted_by_solo then
          local sw2 = D.small_measure('s!')
          local sh2 = math.max(4, math.floor((L.th or L.rh) * D.SMALL))
          if sw2 <= bw0 - 2 then
            local sx2, sy2 = bx0 + math.floor((bw0 - sw2) / 2), ty0 + th - sh2 - 2
            set(dark); gfx.rect(sx2 - 1, sy2 - 1, sw2 + 2, sh2 + 2, 1)          -- подложка: метки и метр под s! не просвечивают
            D.small_text(sx2, sy2, 's!', U.AMBER)
          end
        end
        -- 9 окт: макс. пик — строкой сразу над коробкой, приглушённо; нет
        -- сигнала — пусто (без -inf)
        local pty = ty0 - 6 - L.rh
        local pk2
        if lufs_w > 0 and col.track then
          -- 10 окт: мастер — удержание каждого канала (L R), как у REAPER; над
          -- коробкой вместе со столбиками RMS, не влезают — один максимум
          local hl, hr = reaper.Track_GetPeakHoldDB(col.track, 0, false) * 100, reaper.Track_GetPeakHoldDB(col.track, 1, false) * 100
          local x0, x1 = bx0 - 2 - lufs_w, bx0 + bw0 + 2 + lufs_w
          local a1, a2
          for _, fmt in ipairs({ '%.1f', '%.0f' }) do
            a1 = hl > -60 and fmt:format(hl) or '-inf'; a2 = hr > -60 and fmt:format(hr) or '-inf'
            if ms(a1) + L.pad + ms(a2) <= x1 - x0 then break end
          end
          if hold.max > -60 and ms(a1) + L.pad + ms(a2) <= x1 - x0 then
            pk2 = true
            text(x0, pty, a1, hl > 0 and U.readable(U.RED, rbg, 3) or U.readable(U.GREY, rbg, 3))
            text(x1 - ms(a2), pty, a2, hr > 0 and U.readable(U.RED, rbg, 3) or U.readable(U.GREY, rbg, 3))
          end
        end
        if hold.max > -60 and not pk2 then
          local ptxt = ('%+.1f'):format(hold.max)
          if ms(ptxt) > bw0 then ptxt = ('%+.0f'):format(hold.max) end                 -- 9 окт: не вылезать за коробку
          if ms(ptxt) <= bw0 then text(bx0 + math.floor((bw0 - ms(ptxt)) / 2), pty, ptxt, hold.clip and U.readable(U.RED, rbg, 3) or U.readable(U.GREY, rbg, 3)) end
        end
        if mx >= bx0 and mx < bx0 + bw0 and my >= pty and my < ty0 - 6 then hover.mixpk = col.track end
        local last_ly
        for _, m in ipairs(state.dbmarks ~= false and { 6, 0, -6, -12, -24, -48 } or {}) do   -- быстрая опция dB marks
          local yy = ypos(m)
          set(m == 0 and U.mix(U.TEXT, dark, 0.35) or tick); gfx.rect(bx0 + 1, yy, 2, 1, 1); gfx.rect(bx0 + bw0 - 3, yy, 2, 1, 1)
          -- подпись — только если не налезает на предыдущую (без наложений)
          -- 11 окт: деления мелким шрифтом — центр цифры на риске, помещается больше
          local sh = math.max(4, math.floor((L.th or L.rh) * D.SMALL))
          local ly = yy - D.SPACE - math.floor(sh / 2) - 1
          -- 30 окт: короткая коробка (микшер низкий) — без подписей: «+6» налезал на фейдер; риски остаются
          if th >= 4 * (sh + 2) and (not last_ly or ly >= last_ly + sh + 1) and ly + sh <= ty0 + th + math.floor(L.rh / 2) then
            local ml = (m > 0 and '+' or '') .. m
            local mw = D.small_measure(ml)
            if lblw > 0 then
              D.small_text(bx0 - 2 - mw, ly, ml, m == 0 and U.TEXT or U.GREY)
              hint('trsmark', bx0 - 2 - mw, ly, mw, sh, { col = col, db = m })   -- f: громкость на метку
              last_ly = ly
            elseif mw <= bw0 - 2 then
              -- 9 окт: узкий фейдер — метки внутри коробки, серым (f прыгает на них)
              local lx = bx0 + math.floor((bw0 - mw) / 2)
              D.small_text(lx, ly, ml, U.mix(U.GREY, dark, 0.45))   -- 9 окт: метки внутри коробки — темнее
              hint('trsmark', lx, ly, mw, sh, { col = col, db = m })
              last_ly = ly
            end
          end
        end
        -- 10 окт: громкость мастера — нативная (Track_GetPeakInfo 1024 / 1025,
        -- как VU мастера REAPER в режиме loudness): тонкие столбики по бокам
        -- коробки в той же шкале, риска — удержание REAPER (сброс — щелчок по
        -- числу пика). Каналы 1024 / 1025 — то, что показывает VU мастера
        -- (у пользователя RMS): левый столбик L, правый R
        if lufs_w > 0 and reaper.ValidatePtr(col.track, 'MediaTrack*') then
          local hmax
          for k2, ch in ipairs({ 1024, 1025 }) do
            local v = reaper.Track_GetPeakInfo(col.track, ch)
            local ldb = v > 1e-6 and 20 * math.log(v, 10) or -150
            local hdb = reaper.Track_GetPeakHoldDB(col.track, ch, false) * 100
            local lx0 = k2 == 1 and (bx0 - 2 - lufs_w) or (bx0 + bw0 + 2)
            set(dark); gfx.rect(lx0, ty0 - 6, lufs_w, th + 9, 1)
            if ldb > -60 then local ya = ypos(math.min(ldb, 12)); set(U.CYAN); gfx.rect(lx0, ya, lufs_w, ty0 + th - ya, 1) end
            if hdb > -60 then set(U.TEXT); gfx.rect(lx0, ypos(math.min(hdb, 12)), lufs_w, 1, 1) end
            hmax = math.max(hmax or -150, hdb)
          end
          -- строка над routing — как у REAPER: «RMS -16.9», его удержание (то,
          -- что показывает VU мастера: RMS / LUFS — по режиму его метра)
          if D.lufs_row_y then
            -- 11 окт: подпись — кнопка режима метра мастера REAPER (RMS / LUFS-M / LUFS-S …, без JSFX):
            -- щелчок — выпадашка режимов; щелчок по числу — сброс удержания
            local lbl = (info.master_meter_mode and info.master_meter_mode()) or 'RMS'
            local val = (hmax or -150) > -60 and ('%.1f'):format(hmax) or '-inf'
            local lw2 = ms(lbl) + 2 * L.pad
            if lw2 + ms(' ' .. val) <= c.w - L.pad then
              local bx3, by3 = c.x + 2, D.lufs_row_y
              local bhot = mx >= bx3 and mx < bx3 + lw2 and my >= by3 and my < by3 + L.rh
              set(bhot and U.tint(U.AMBER, 0.3) or rbg); gfx.rect(bx3, by3, lw2, L.rh, 1)
              set(bhot and U.AMBER or U.LINE); gfx.rect(bx3, by3, lw2, L.rh, 0)
              text(bx3 + L.pad, by3, lbl, bhot and U.AMBER or U.readable(U.GREEN, rbg, 3))
              text(bx3 + lw2 + L.pad, by3, val, U.TEXT)
              if bhot then hover.mixmode = true end
              hint('mixmode', bx3, by3, lw2, L.rh, true)
            end
            if not hover.mixmode and mx >= c.x and mx < c.x + c.w and my >= D.lufs_row_y and my < D.lufs_row_y + L.rh then hover.mixpk = col.track end   -- щелчок — сброс
          end
        end
        if info.gr_of then D.gr_mix(bx0 + bw0 - 3, ypos, info.gr_of(col)) end   -- 27 окт: подавление — столбик от 0 dB
        -- ручка: 11 окт — просто риска «__» во всю коробку (была колпачком в рамке)
        local hy2 = ypos(db)
        local hc = U.readable((hot or kon) and U.AMBER or U.TEXT, dark, 4)
        set(hc); gfx.rect(bx0 + 1, hy2, bw0 - 2, 2, 1)
        if hot then hover.trs = { col = col, what = 'vol', vert = true, y0 = ty0 + th, h = th, sv = math.max(0, math.min(1, (ty0 + th - my) / math.max(1, th))) } end
        if D.csel_on(col.guid, 'vol') then csel_frame(bx0, ty0, bw0, th) end
        hint('trs', bx0, ty0, bw0, th, { col = col, what = 'vol' })
        end   -- compact / фейдер
        if mixcol then
          -- 16 окт: раскладка как в микшере REAPER — сверху m s ~ ø sro, внизу под фейдером (o) запись, рядом i
          local colx = sx + fx_w + 2 + (lufs_w > 0 and lufs_w + 2 or 0)
          for k, li in ipairs({ 3, 4, 6, 5 }) do
            local b = labels[li]
            hbtn(b, colx, y1 + (k - 1) * (D.mcb_h + 2) + 1, D.mcb_w, D.mcb_h, false)
          end
          local sc = D.sro_col
          if sc then sc.draw(colx, y1 + 4 * (D.mcb_h + 2) + 1, D.mcb_w, sc.rhh, sc.vert) end
          if rec_d and rec_d > 0 then
            local ry = y1 + fh - rec_d - 3
            local rb = setmetatable({ cap = true }, { __index = labels[1] })
            hbtn(rb, sx + math.floor((fx_w - rec_d) / 2), ry, rec_d, rec_d - 2, true)
            hbtn(labels[2], colx, ry + math.floor((rec_d - D.mcb_h) / 2), D.mcb_w, D.mcb_h, false)
          end
        end
        -- эффекты (часть микшера): сбоку от фейдера, если влезают короткие
        -- имена (от 5 знаков), на всю высоту полосы; иначе — под фейдером
        if info.fx_stack and (side or not c.master) then
          local sx1 = sepx and (sepx + 2) or (sx + fx_w + colw + lufs_w + L.pad + 2)
          local ex, ey, ew, eh
          if side then
            ex, ey, ew, eh = sx1, y1, c.x + c.w - 2 - sx1, H
            if sepx then
              local ly0 = L.mix_bottom and L.mix_y or (y1 - 1)               -- от горизонтали над микшером — встык
              set(sepc); gfx.rect(sepx, ly0, 1, (L.mix_bottom and L.mix_h or H + 1), 1)
            else local o = (c.master and lufs_w > 0) and L.rh or 0; set(U.LINE); gfx.rect(ex - 2, ey + o, 1, eh - o, 1) end   -- не через строку имени мастера
            if c.master then
              if lufs_w == 0 then text(ex + 2, ey, fit('master', ew - 2), U.AMBER) end
              ey, eh = ey + L.rh, eh - L.rh                       -- строка имени (с LUFS — во всю полосу, выше)
            end   -- имя — над эффектами мастера (с LUFS — строкой сверху)
          else
            ex, ey, ew, eh = c.x + 2, y1 + fh, c.w - 4, H - fh
            set(U.LINE); gfx.rect(ex, ey - 1, ew, 1, 1)
          end
          info.fx_stack(hover, col, ex, ex + ew, ey, math.max(1, math.floor(eh / L.rh)), true)
        end
      else
      slider(sx, hy + 2 * L.rh + 1, sw, (math.max(-60, math.min(12, db)) + 60) / 72, false, 'v', db <= -60 and '-inf' or ('%+.1f'):format(db), 'vol')
      -- 19 окт: метр трека — тонкая полоса под v (та же шкала -60..+12): пик трека (взведённый аудио — вход);
      -- вход MIDI на трек — жёлтая вспышка, гаснет за 0.3 с
      if not c.master and info.hdrmeter ~= false then
        local my0 = hy + 3 * L.rh - 1
        local lw0 = ms('v') + L.pad
        local mx0, mw0 = sx + lw0, math.max(4, sw - lw0)
        local pl, pr = 0, 0
        if info.peaks then pl, pr = info.peaks(col) end
        local pk = math.max(pl or 0, pr or 0)
        local pdb = pk > 1e-6 and 20 * math.log(pk, 10) or -150
        if pdb > -60 then
          local fw = math.floor(mw0 * (math.min(12, pdb) + 60) / 72 + 0.5)
          set(pdb > 0 and U.RED or (pdb > -6 and U.AMBER or U.GREEN)); gfx.rect(mx0, my0, fw, 2, 1)
        end
        if info.gr_of then D.gr_hdr(L, mx0, my0, mw0, info.gr_of(col)) end   -- 27 окт: подавление компрессора трека
        local age = info.midi_in_age and info.midi_in_age(col)
        if age and age < 0.3 then
          local yl = U.YELLOW or U.AMBER
          gfx.set(yl[1], yl[2], yl[3], 1 - age / 0.3); gfx.rect(mx0, my0, mw0, 2, 1); gfx.a = 1
        end
      end
      -- 16 окт: width — своей строкой под паном: w ----+----, от центра в обе стороны ---===--- (шире —
      -- длиннее, отрицательная — красным); строка — вторая строка кнопок, если она пуста
      local wrow = D.hdr_row2_free and D.hdr_row2_free > py and col.panmode ~= 6 and not c.master and D.hdr_row2_free or nil
      if wrow then
        local wv = lv('width', col.width or 1)
        local lw = ms('w') + L.pad
        local vres = ms('-100') + L.pad
        local wx0, ww = px + lw, math.max(8, pw - lw - vres - L.pad)
        local cy = wrow + math.floor(L.rh / 2)
        local hot = mx >= wx0 - 2 and mx < wx0 + ww + 2 and my >= wrow and my < wrow + L.rh
        text(px, wrow, 'w', U.GREY)
        set(U.LINE); gfx.rect(wx0, cy, ww, 1, 1)
        local mid = wx0 + math.floor(ww / 2)
        set(U.GREY); gfx.rect(mid, cy - 2, 1, 5, 1)
        local hl = math.floor(math.min(1, math.abs(wv)) * ww / 2 + 0.5)
        set(wv < 0 and U.RED or (hot and U.AMBER or U.TEXT)); gfx.rect(mid - hl, cy - 1, 2 * hl + 1, 3, 1)
        local vt = ('%d'):format(math.floor(wv * 100 + 0.5))
        text(wx0 + ww + L.pad + vres - L.pad - ms(vt), wrow, vt, U.GREY)
        if hot then hover.trs = { col = col, what = 'width', x0 = wx0, w = ww, sv = math.max(0, math.min(1, (mx - wx0) / math.max(1, ww))) } end
        hint('trs', wx0, wrow, ww, L.rh, { col = col, what = 'width' })
        if D.slr then D.slr[#D.slr + 1] = { g = 'trs:' .. tostring(col.guid), col = col, trk = 'width', name = 'w ' .. (col.name or ''), own = col.name, pn = 'w', x = wx0, y = wrow, w = ww, h = L.rh } end
        local ks = info.kslider
        if ks and ks.what == 'width' and ks.col and ks.col.guid == col.guid then set(U.AMBER); gfx.rect(wx0 - 2, wrow + 1, ww + 4, L.rh - 2, 0) end
      end
      if col.panmode == 5 and wrow then
        slider(px, py, pw, (lv('pan', col.pan or 0) + 1) / 2, true, 'p', pan_txt(lv('pan', col.pan or 0)), 'pan')
      elseif col.panmode == 5 then
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
      end   -- микшер / строки громкости и панорамы
      -- строка входа (3 окт): in <вход> — клик: список входов (fzf) под ней,
      -- повторный клик закрывает; smart — в DSP-модуле трека (4 окт)
      if (L.hr_in > 0 or mixin_y) and info.input_name and not c.master then
        local iy = mixin_y or (hy + (2 + L.hr_vp) * L.rh + 1)
        local iw = sw
        local sx = sx
        if mixin_y then sx, iw = c.x + L.pad, c.w - 2 * L.pad end   -- своя копия: sx ниже нужен строкам инфо
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
      -- инфо трека (7 окт, опция header info): l — инструменты из lib на
      -- треке, fx — инсерты (клик — в DSP, двойной — окно), s — сенды (клик —
      -- окно маршрутизации); фишки по ширине, что не влезло — «+N»
      if L.hr_info > 0 and info.hdr_info and not c.master then
        local hi = info.hdr_info(col) or {}
        local y0 = hy + (2 + L.hr_vp + L.hr_in) * L.rh + 1
        local rows = { { 'l', hi.inst or {}, 'hdrinst' }, { 'fx', hi.fx or {}, 'hdrfx' }, { 's', hi.sends or {}, 'hdrsend' } }
        for ri, row in ipairs(rows) do
          local ry = y0 + (ri - 1) * L.rh
          text(sx, ry, row[1], U.GREY)
          local cx = sx + ms('fx') + L.pad
          local right = sx + sw
          for k, it in ipairs(row[2]) do
            local lab = fit(it.name or '', L.cw * 9)
            local cw2 = ms(lab) + 2 * L.pad
            local more = #row[2] - k + 1
            if cx + cw2 > right - (more > 1 and ms('+9') + 2 or 0) then
              if more > 0 then text(right - ms('+' .. more), ry, '+' .. more, U.CYAN) end
              break
            end
            local hot = mx >= cx and mx < cx + cw2 and my >= ry and my < ry + L.rh
            set(hot and U.tint(U.AMBER, 0.3) or U.PANEL); gfx.rect(cx, ry, cw2, L.rh - 1, 1)
            text(cx + L.pad, ry, lab, hot and U.AMBER or ((it.off and U.GREY) or BTXT))
            if hot then hover[row[3]] = { col = col, k = k, it = it, x = cx, w = cw2, y = ry } end   -- x w y: бросок вставки в место цепи (9 окт)
            hint(row[3], cx, ry, cw2, L.rh, { col = col, k = k })
            cx = cx + cw2 + 2
          end
        end
      end
    end
    for li, ln in ipairs(c.lanes) do
      -- −+ подколонок — над нотным полем (3 окт; раньше справа в строке лейна);
      -- справа в строке последнего лейна — −+ колонок эффектов (вместо опции fx)
      local by = hy + L.lane_row * L.rh + 1
      local G1 = (L.flat[ln.f0] or {}).G or L
      local nx = ln.x + (ln.sx and ln.sx[1] or 0) + (G1.x_note or 0)
      local function pm(x0, kind, onhot)
        -- 28 окт: зажат Option — ярко − + подколонок нот, Ctrl+Option — − + колонок эффектов
        local cap = gfx.mouse_cap
        local lit = cap & 16 ~= 0 and cap & 4 == 0 and (kind == 'fxcolbtn') == (cap & 32 ~= 0)
        for k, b in ipairs({ { '-', -1 }, { '+', 1 } }) do
          local bx = x0 + (k - 1) * (L.btn_w + 2)
          local hot = mx >= bx and mx < bx + L.btn_w and my >= by and my < by + L.rh - 1
          set(hot and D.CURROW or (lit and U.tint(U.AMBER, 0.35) or U.PANEL)); gfx.rect(bx, by, L.btn_w, L.rh - 2, 1)
          set(lit and U.AMBER or U.DIM); gfx.rect(bx, by, L.btn_w, L.rh - 2, 0)
          text(bx + 2, by, b[1], (hot or lit) and U.AMBER or BTXT)
          if hot then onhot(b[2]) end
          hint(kind, bx, by, L.btn_w, L.rh, kind == 'lanebtn' and { col = col, lane = ln.lane, d = b[2], n = ln.nsub } or { d = b[2] })
        end
      end
      local bw2 = 2 * L.btn_w + 2
      if col.fixed and not c.folded then
        local lname = ln.lane.name ~= '' and ln.lane.name or ('L' .. (ln.lane.idx + 1))
        text(ln.x + L.pad, hy + L.lane_row * L.rh + 2, fit(lname, nx - ln.x - 2 * L.pad), U.GREY)
      end
      if not c.folded and not c.master then
        -- 24 окт: [1][−][+] — 1 первой (трек на одном нотном лейне), − + правее; места на три нет — только − +
        local one = false   -- 24 окт (вечер): кнопка 1 убрана (лишние кнопки в шапке) — моно-лейн: z1 / меню трека
        if nx + bw2 <= ln.x + ln.w then
          pm(nx + (one and (L.btn_w + 2) or 0), 'lanebtn', function(d) hover.lanebtn = { col = col, lane = ln.lane, d = d, n = ln.nsub } end)
          -- 29 окт: сколько нотных колонок — числом сразу за − + (1 — одна колонка)
          if nx + bw2 + 2 + ms('8') <= ln.x + ln.w then text(nx + bw2 + 2, by, tostring(ln.nsub or 1), (ln.nsub or 1) == 1 and U.GREY or U.CYAN) end
          local ox = nx
          if one then
            local on = info.mono_on(col)
            local hot = mx >= ox and mx < ox + L.btn_w and my >= by and my < by + L.rh - 1
            set(hot and D.CURROW or (on and U.tint(U.CYAN, 0.35) or U.PANEL)); gfx.rect(ox, by, L.btn_w, L.rh - 2, 1)
            set(on and U.CYAN or U.DIM); gfx.rect(ox, by, L.btn_w, L.rh - 2, 0)
            text(ox + 2, by, '1', hot and U.AMBER or (on and U.CYAN or BTXT))
            if hot then hover.lanemono = { col = col, lane = ln.lane } end
            hint('lanebtn', ox, by, L.btn_w, L.rh, { col = col, lane = ln.lane, d = 0, n = ln.nsub, mono = true })
          end
        end
        local fx0 = ln.x + ln.w - bw2 - 1
        if li == #c.lanes and fx0 > nx + bw2 + L.pad and not c.master then   -- 17 окт: у мастера колонок эффектов нет (кнопки ложились на cmd / visor); его a+ — ниже
          pm(fx0, 'fxcolbtn', function(d) hover.fxcolbtn = { d = d, col = col } end)   -- 12 окт: и трек кнопки
          -- 6 окт: лейнов огибающих нет — a+ (добавить лейн автоматизации) левее
          local aw = ms('a+') + 4
          local ax = fx0 - aw - L.pad
          if #c.envs == 0 and not state.ptmode and ax > nx + bw2 + L.pad then
            local by = hy + L.lane_row * L.rh + 1
            local ahot = mx >= ax and mx < ax + aw and my >= by and my < by + L.rh - 1
            set(ahot and D.CURROW or U.PANEL); gfx.rect(ax, by, aw, L.rh - 2, 1)
            set(U.DIM); gfx.rect(ax, by, aw, L.rh - 2, 0)
            text(ax + 2, by, 'a+', ahot and U.AMBER or BTXT)
            if ahot then hover.envpm = { col = col, d = 1 } end
            hint('envpm', ax, by, aw, L.rh, { col = col, d = 1 })
          end
        end
      end
      if li > 1 then set(U.DIM); gfx.rect(ln.x - 1, hy + L.lane_row * L.rh + 1, 1, L.rh, 1) end
    end
    for _, m in ipairs(c.mls or {}) do
      text(m.x + L.pad, hy + L.lane_row * L.rh + 2, fit(m.ml.name, m.w - L.pad), U.CYAN)
      set(U.DIM); gfx.rect(m.x - 1, hy + L.lane_row * L.rh + 1, 1, L.rh, 1)
      hint('mlane', m.x, hy + L.lane_row * L.rh, m.w, L.rh, m.fi)
    end
    -- 11 окт: мастер без показанных огибающих — a+ (любая автоматизация мастера: громкость,
    -- панорама, параметры его FX, Tempo); с огибающими + стоит у последней, как у треков
    if c.master and #c.envs == 0 and c.col and c.col.track then
      local aw = ms('a+') + 4
      local m = (c.mls or {})[#(c.mls or {})]
      local ax = m and (m.x + m.w - aw - 2) or (c.x + c.w - aw - 2)
      local by = hy + L.lane_row * L.rh + 1
      if not m or ax > m.x + ms('cmd') + 2 * L.pad then
        local ahot = mx >= ax and mx < ax + aw and my >= by and my < by + L.rh - 1
        set(ahot and D.CURROW or U.PANEL); gfx.rect(ax, by, aw, L.rh - 2, 1)
        set(U.DIM); gfx.rect(ax, by, aw, L.rh - 2, 0)
        text(ax + 2, by, 'a+', ahot and U.AMBER or BTXT)
        if ahot then hover.envpm = { col = c.col, d = 1 } end
        hint('envpm', ax, by, aw, L.rh, { col = c.col, d = 1 })
      end
    end
    for ei, ev in ipairs(c.envs) do
      -- 6 окт: справа в шапке лейна − (спрятать лейн; огибающая и точки
      -- остаются), у последнего лейна ещё + (добавить: выбор параметра);
      -- имя — до кнопок, не под ними
      local ly2 = hy + L.lane_row * L.rh
      local nb = (ei == #c.envs) and 2 or 1
      local bx0 = ev.x + ev.w - nb * (L.btn_w + 2) - 1
      local room = not c.compact and (bx0 - ev.x - 2 * L.pad) >= ms('WW')
      -- 24 окт: имя параметра — коротко: «S01 сэмпл: Pitch adjust / drumrs5k …» → «Pitch adjust» (префикс съедал всё место)
      local en = (ev.e.name or ''):gsub(' / .*$', '')
      en = en:match(':%s*(.+)$') or en
      text(ev.x + L.pad, ly2 + 2, fit(en, room and (bx0 - ev.x - 2 * L.pad) or (ev.w - 2 * L.pad)), env_colour(ev.e))
      local on_btn = false
      if room then
        for k, b in ipairs(nb == 2 and { { '+', 1 }, { '-', -1 } } or { { '-', -1 } }) do
          local bx, by = bx0 + (k - 1) * (L.btn_w + 2), ly2 + 1
          local bhot = mx >= bx and mx < bx + L.btn_w and my >= by and my < by + L.rh - 1
          set(bhot and D.CURROW or U.PANEL); gfx.rect(bx, by, L.btn_w, L.rh - 2, 1)
          set(U.DIM); gfx.rect(bx, by, L.btn_w, L.rh - 2, 0)
          text(bx + 2, by, b[1], bhot and U.AMBER or BTXT)
          if bhot then hover.envpm = { col = c.col, e = ev.e, d = b[2] }; on_btn = true end
          hint('envpm', bx, by, L.btn_w, L.rh, { col = c.col, e = ev.e, d = b[2] })
        end
      end
      -- имя огибающей — своё меню (клик: удалить кривую / очистить точки), 2 окт
      if not on_btn and mx >= ev.x and mx < ev.x + ev.w and my >= hy + L.lane_row * L.rh and my < hy + (L.lane_row + 1) * L.rh then hover.header_env = { e = ev.e, col = c.col } end
      hint('env', ev.x, hy + L.lane_row * L.rh, ev.w, L.rh, ev.fi)
      set(U.DIM); gfx.rect(ev.x - 1, hy + L.lane_row * L.rh + 1, 1, L.rh, 1)
    end
    -- третья строка: что делает каждая подколонка (просьба 1 окт). Подписи
    -- короче ширины поля на символ, чтобы соседние не слипались; полное
    -- описание — в статус-баре при наведении (hover.caption)
    if not c.folded and state.captions then           -- подписи колонок — опция (Options → column captions)
      local cy3 = hy + (L.lane_row + 1) * L.rh + 2
      local caph = L.cap_rows * L.rh - 4
      local function cap(x, w, txt, kind)
        -- 12 окт: подпись вертикально, снизу вверх, по центру поля (1x, не мелкий шрифт); ширина — высота строки
        if w >= L.th then D.vtext(x + math.floor((w - L.th) / 2), cy3, caph, txt, U.GREY, rbg) end
        if mx >= x and mx < x + w + L.pad and my >= cy3 and my < cy3 + caph then hover.caption = kind end
      end
      for _, ln in ipairs(c.lanes) do
        for si = 1, ln.nsub do
          local sx = ln.x + (ln.sx and ln.sx[si] or (si - 1) * L.sub_w)
          local G = (L.flat[ln.f0 + si - 1] or {}).G or L
          if G.w_wave > 0 then cap(sx + G.x_wave, G.w_wave, 'wave', 'wave') end
          cap(sx + G.x_note, L.w_note, 'note', 'note')
          if G.x_inst then cap(sx + G.x_inst, ms('00'), 'ins', 'inst') end        -- 12 окт: поле инструмента подписано
          if G.x_slc and not G.notes_only then cap(sx + G.x_slc, G.w_slc or ms('S00'), 'slc', 'slc') end
          if not G.notes_only then cap(sx + G.x_vol, L.w_vol, 'vol', 'vol') end
          if not (G.narrow or G.notes_only) then
            -- 11 окт: поля — по раскладке самой подколонки (уровень зума), не по полной: за краем — нет подписей
            local sw = (L.flat[ln.f0 + si - 1] or {}).w or L.sub_w
            for k = 1, (G.nfx or L.nfx) do local fx = (G.x_fx or L.x_fx)[k]; if fx and fx < sw then cap(sx + fx, L.w_fx, 'fx' .. k, 'fx') end end
            if (G.x_del or L.x_del) < sw then cap(sx + (G.x_del or L.x_del), L.w_del, 'delay', 'delay') end
          end
        end
      end
      for _, ev in ipairs(c.envs) do cap(ev.x + L.pad, ev.w - 2 * L.pad, 'env', 'env') end
    end
    U.TEXT, U.GREY = T0, G0
    set(U.LINE); gfx.rect(c.x, hy, 1, L.header_h, 1)
    if my >= hy and my < hy + L.header_h and mx >= c.x and mx < c.x + c.w then hover.header_col = col end
    -- 9 окт: фон полосы нижнего микшера — тоже «шапка» (щелчок выделяет трек)
    if L.mix_bottom and mx >= c.x and mx < c.x + c.w and my >= L.mix_y and my < L.mix_y + L.mix_h then hover.header_col = col end
  end
  set(D.SEP); gfx.rect(tx0, hy + L.header_h - 2, W - tx0, 1, 1)
  -- 9 окт: линейка прыжков (опция jumps) — между клипами и строками, как relativenumber в
  -- Vim по горизонтали: у каждого трека — сколько до него от курсора (3L / 3H
  -- прыгают туда), у трека курсора — его номер янтарём
  if (L.jr_h or 0) > 0 then
    -- 10 окт: линейка прыжков ПО ЯЧЕЙКАМ — над каждой ячейкой, куда встаёт l / h,
    -- сколько нажатий до неё (как 3l / 2h; голубые — слева); ячейка курсора — пусто.
    -- Порядок — как ходит l (info.vorder = vim.vorder); подполе инструмента не считается (Nl его пропускает)
    local jy = L.body_y - L.jr_h
    -- 10 окт: подложка — опцией (по умолчанию нет: фон окна); цифры приглушены
    set(D.jr_bg and U.PANEL or U.BG); gfx.rect(tx0, jy, W - tx0, L.jr_h, 1)
    local vc, vo = info.vcur, info.vorder
    if vc and vo and L.flat then
      local idx, cur_i = 0, nil
      local pos = {}
      for fi, f in ipairs(L.flat) do
        local G = f.G or L
        local inst_ok = not (f.env or f.folded) and G.x_inst and true or false   -- 21 окт: и свёрнутый MIDI (GCM: нота | инстр. | vol) — курсор туда ходит   -- 11 окт: x_inst = false у узких подколонок (false ~= nil давало шаг в невидимое поле)
        for _, fld in ipairs(vo(fi)) do
          -- 16 окт: колонка волны — шаг перед нотой (h с ноты, l из соседней подколонки встают на неё)
          if fld == 1 and (G.w_wave or 0) > 0 and not (f.env or f.folded or f.ml) then   -- 22 окт: и у узкой (уровень «нота», GC) — волна там есть
            idx = idx + 1
            if fi == vc.fi and vc.sub == 'wave' then cur_i = idx end
            if f.x then pos[#pos + 1] = { i = idx, f = f, fld = 'wave' } end
          end
          idx = idx + 1
          local half = type(fld) == 'number' and fld >= 4 and not (f.env or f.compact or f.folded)   -- 12 окт: поле команды — два шага (код | значение)
          if fi == vc.fi and fld == (vc.field or 1) and vc.sub ~= 'inst' and vc.sub ~= 'slc' and vc.sub ~= 'pan' and vc.sub ~= 'wave' and not (half and vc.sub == 'val') then cur_i = idx end
          if f.x then pos[#pos + 1] = { i = idx, f = f, fld = fld, half = half and 'code' or nil } end
          if half then
            idx = idx + 1
            if fi == vc.fi and fld == vc.field and vc.sub == 'val' then cur_i = idx end
            if f.x then pos[#pos + 1] = { i = idx, f = f, fld = fld, half = 'val' } end
          end
          if fld == 2 and (f.G or L).x_pan and not (f.env or f.compact or f.folded) then   -- 14 окт: подполе пана — шаг
            idx = idx + 1
            if fi == vc.fi and vc.field == 2 and vc.sub == 'pan' then cur_i = idx end
            if f.x then pos[#pos + 1] = { i = idx, f = f, fld = 'pan' } end
          end
          if fld == 1 and inst_ok then          -- подполе инструмента — тоже шаг (10 окт)
            idx = idx + 1
            if fi == vc.fi and vc.sub == 'inst' then cur_i = idx end
            if f.x then pos[#pos + 1] = { i = idx, f = f, fld = 'inst' } end
            if G.x_slc and not G.notes_only then   -- 11 окт: и подполе слайса — шаг
              idx = idx + 1
              if fi == vc.fi and vc.sub == 'slc' then cur_i = idx end
              if f.x then pos[#pos + 1] = { i = idx, f = f, fld = 'slc' } end
            end
          end
        end
      end
      D.jr_master_d = cur_i and (idx + 1 - cur_i) or nil   -- 20 окт: шагов l до сложенного мастера (за последней ячейкой)
      local last_r = -1e9                     -- 11 окт: метка, налезающая на предыдущую, пропускается (узкие поля инструмент / слайс)
      local function lab_x(p, d)
        local fx, fw = D.field_rect(p.f.G or L, p.fld)
        if p.half then fw = ms('00'); if p.half == 'val' then fx = (fx or 0) + fw end end
        if p.f.ml or p.f.env then fw = math.floor((p.f.w or 0) / (p.half and 2 or 1)); fx = (p.half == 'val') and fw or 0 end
        local lab = ('%d'):format(math.floor(math.abs(d) + 0.5))
        return p.f.x + (fx or 0) + math.floor(((fw or 0) - ms(lab)) / 2), ms(lab)
      end
      -- 13 окт: «0» курсора — главное: соседние метки, налезающие на него, не рисуются
      local c0, c1
      for _, p in ipairs(pos) do if cur_i and p.i == cur_i then local lx, lw = lab_x(p, 0); c0, c1 = lx - 1, lx + lw + 1 end end
      for _, p in ipairs(pos) do
        local d = cur_i and (p.i - cur_i) or nil
        if d and d ~= 0 and c0 then local lx, lw = lab_x(p, d); if lx < c1 and lx + lw > c0 then d = nil end end
        if d then
          local fx, fw = D.field_rect(p.f.G or L, p.fld)
          if p.half then fw = ms('00'); if p.half == 'val' then fx = (fx or 0) + fw end end
          -- 13 окт: колонки мастера (cmd, visor, огибающие) — поля по своей ширине, не по раскладке трека (цифры налезали)
          if p.f.ml or p.f.env then
            fw = math.floor((p.f.w or 0) / (p.half and 2 or 1)); fx = (p.half == 'val') and fw or 0
          end
          local cx = p.f.x + (fx or 0)
          local lab = ('%d'):format(math.floor(math.abs(d) + 0.5))
          local lx = cx + math.floor(((fw or 0) - ms(lab)) / 2)
          if ms(lab) <= (fw or 0) + 2 and cx >= tx0 and cx + (fw or 0) <= ((p.f.x < L.cols_r) and L.cols_r or W) and (lx > last_r + 1 or d == 0) then   -- 21 окт: поле трека у мастера — не дальше его границы
            text(lx, jy, lab, d == 0 and U.AMBER or U.mix(d < 0 and U.CYAN or U.GREY, U.BG, 0.35))   -- 0 — ячейка курсора
            last_r = lx + ms(lab)
          end
        end
      end
    end
    for _, c in ipairs(L.cols or {}) do
      -- 24 окт: той же линией, что в строках и шапке, и у мастера (была вдвое бледнее и без мастера — линия «рвалась»
      -- в этой строке, а у мастера разделитель Temp | cmd торчал только в шапке)
      if c.x and c.ci then set(U.LINE); gfx.rect(c.x, jy, 1, L.jr_h, 1) end
    end
    -- 20 окт: сложенный мастер — и у него метка: через столько l курсор встанет на мастер (он раскроется)
    if L.mfold and D.jr_master_d and D.jr_master_d > 0 then
      local lab = tostring(D.jr_master_d)
      local mx0, mw0 = L.cols_r + 1, L.master_w - 2
      if ms(lab) <= mw0 then
        set(D.jr_bg and U.PANEL or U.BG); gfx.rect(mx0, jy, mw0, L.jr_h, 1)
        text(mx0 + math.floor((mw0 - ms(lab)) / 2), jy, lab, U.mix(U.GREY, U.BG, 0.35))
      end
    end
  end
  if L.mix_bottom and (L.route_h or 0) > 0 then D.route_strip(L, info, hover, L.matrix_w or 0, W) end
  -- 9 окт: попап маршрутизации открыт — каналы-получатели (S голубой),
  -- источники (R зелёный), сам трек (белый), трек под строкой — янтарь, 2 px
  local rhl = info.route_hl and info.route_hl()
  if rhl then
    local yb = L.mix_bottom and (L.mix_y + L.mix_h) or (hy + L.header_h)
    for _, c in ipairs(L.cols or {}) do
      local g = c.col and c.col.guid
      local cc = g and ((rhl.sel == g) and U.AMBER or rhl[g])
      if cc and c.x then
        set(cc)
        gfx.rect(c.x + 1, hy, c.w - 1, L.header_h - 2, 0); gfx.rect(c.x + 2, hy + 1, c.w - 3, L.header_h - 4, 0)
        if L.mix_bottom then gfx.rect(c.x + 1, L.mix_y, c.w - 1, L.mix_h, 0); gfx.rect(c.x + 2, L.mix_y + 1, c.w - 3, L.mix_h - 2, 0) end
      end
    end
  end
  -- уголок над номерами строк (2 окт; 7 окт): ряд 0 — proj | region, ряд 1 —
  -- session | router, ряд 2 — номер и имя региона в его цвете, ряд 3 — /2 x2
  -- слева и als cln парой справа, последний — длина «< N >»
  do
    local rg = info.cur_region_full
    local bx, bw = tx0 + 3, L.label_w - 4              -- 9 окт: зазор от границы модуля (2 px) — левая рамка кнопок видна
    local function small(x, y, label, what, on, kind, oc)   -- oc — свой цвет включённой (31 окт: proj sec pat)
      local w1 = ms(label) + 2
      local hot = mx >= x and mx < x + w1 and my >= y and my < y + L.rh
      local cc = oc or U.CYAN
      set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(cc, 0.25) or U.BG)); gfx.rect(x, y, w1, L.rh, 1)
      set(hot and U.AMBER or (on and cc or U.LINE)); gfx.rect(x, y, w1, L.rh, 0)
      text(x + 1, y, label, hot and U.AMBER or (on and cc or U.TEXT))
      if hot then hover[kind] = what end
      hint(kind, x, y, w1, L.rh, what)
      return x + w1 + 2
    end
    -- ряд 0: proj | region (5 окт: было all | reg); не влезает — region → rgn
    local x0 = bx
    -- 20 окт: project | pattern (было proj | region); узко — proj | pat; zp переключает
    -- 26 окт: + section (zs): project | sec | pattern — что видно, то и правит транспозиция
    local wide = ms('project') + ms('sec') + ms('pattern') + 9 <= bw
    local vm = info.view_mode or (info.view_reg and 'pattern' or 'project')
    -- 31 окт: цвета вида — проект красный, секция жёлтая, паттерн зелёный
    x0 = small(x0, hy + 1, wide and 'project' or 'proj', 'all', vm == 'project', 'viewbtn', U.RED)
    x0 = small(x0, hy + 1, 'sec', 'sec', vm == 'section', 'viewbtn', U.AMBER)
    small(x0, hy + 1, wide and 'pattern' or 'pat', 'reg', vm == 'pattern', 'viewbtn', U.GREEN)
    do
      -- 7 окт: router живёт в DSP FX, микшер убран (одно место у инструмента)
      local full = ms('clips') + ms('effects') + ms('param') + 12 <= bw   -- effects словом — только если и param влезает
      local x1 = bx
      local x2 = small(x1, hy + 1 + L.rh, full and 'effects' or 'fx', 'effects', info.fxrow, 'viewbtn')   -- строка эффектов и сендов треков (7 окт)
      -- 8 окт: param — рядом с effects (одно место; было в строке effects и в
      -- уголке микшера); не влезает слово — «p»
      local plb = (x2 + ms('param') + 4 <= bx + bw) and 'param' or ((x2 + ms('p') + 4 <= bx + bw) and 'p' or nil)
      if plb then small(x2, hy + 1 + L.rh, plb, 'fxparams', info.fxparams, 'viewbtn') end
      -- 18 окт: autoarm — под clips (просьба; был в шапке мастера): все треки на автоарм / обратно, горит — у всех
      local all, nt = true, reaper.CountTracks(0)
      for i = 0, nt - 1 do if reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, i), 'B_AUTO_RECARM') ~= 1 then all = false; break end end
      all = all and nt > 0
      local ay = hy + 1 + 2 * L.rh
      D.cn_r1x = plb and (x2 + ms(plb) + 4) or x2   -- 20 окт: свободное место ряда 1 (az mk низкой шапки)
      -- 20 окт: ряд autoarm / fold — на своём месте и в низкой шапке (микшер внизу): влезает над последним рядом
      if ay + L.rh <= hy + (L.header_rows - 1) * L.rh + 2 then
        local xf = small(bx, ay, ms('autoarm all') + 4 <= bw and 'autoarm all' or (ms('autoarm') + 4 <= bw and 'autoarm' or 'arm'), all and 'off' or 'on', all, 'mautoarm')   -- 22 окт: autoarm all — флаг всем трекам
        -- 19 окт: fold быстрых нот — в строке autoarm справа (статус объясняет)
        local fl = (xf + ms('fold') + 2 <= bx + bw) and 'fold' or ((xf + ms('fd') + 2 <= bx + bw) and 'fd' or nil)
        if fl then small(bx + bw - ms(fl) - 2, ay, fl, 'foldfast', state.foldfast, 'viewbtn') end
      else
        local xa = D.cn_r1x
        if xa + ms('arm') + 2 <= bx + bw then small(xa, hy + 1 + L.rh, 'arm', all and 'off' or 'on', all, 'mautoarm'); D.cn_r1x = xa + ms('arm') + 4 end
      end
    end
    -- 20 окт: строка 3 — номер и имя паттерна курсора (и секция) в его цвете; клик — выпадашка команд паттерна
    -- (очередь, alias, clone, /2 x2, длина …); als cln — в ней. Вертикальная шапка справа от мастера — отменена
    local ny = hy + 1 + 3 * L.rh
    if ny + L.rh <= hy + (L.header_rows - 2) * L.rh + 2 then ny = hy + (L.header_rows - 2) * L.rh + 2 end   -- 31 окт: имя — прямо над длиной (zoom mark — выше)
    -- 20 окт (2): строка эффектов есть — имя паттерна в ней, под размером и кнопками (main, вместо подписи fx)
    if ny > hy + 1 + 3 * L.rh - 1 and ny + L.rh <= hy + (L.header_rows - 1) * L.rh + 2 and not (state.fxrow and (L.fxrow_h or 0) > 0) then
      local rg = info.cur_region_full
      local nhot = mx >= bx and mx < bx + bw and my >= ny and my < ny + L.rh
      if rg then
        local c = rg.rgb or U.LINE
        set(nhot and U.tint(U.AMBER, 0.3) or U.tint(c, 0.30)); gfx.rect(bx, ny, bw, L.rh, 1)
        set(c); gfx.rect(bx, ny, 3, L.rh, 1)
        local t = tostring(rg.idx) .. (rg.name ~= '' and (' ' .. rg.name) or '') .. ((rg.sec and rg.sec ~= '') and (' / ' .. rg.sec) or '')
        text(bx + 5, ny, fit(t, bw - 7), nhot and U.AMBER or U.TEXT)
      else
        text(bx + 5, ny, fit('no pattern', bw - 7), U.DIM)
      end
      if nhot then hover.rghead = true end
    end
  end
  -- последняя строка уголка (20 окт): «< N >» — длина региона курсора в шагах (стрелки и колесо ±1 шаг,
  -- клик по числу — выпадашка длин), справа x2 /2; строкой выше — autozoom и markers
  do
    local bx, y4 = tx0 + 3, hy + (L.header_rows - 1) * L.rh + 2
    local bw = L.label_w - 4
    local function btn(x, y, label, kind, what, on)
      local w1 = ms(label) + 2
      local hot = mx >= x and mx < x + w1 and my >= y and my < y + L.rh
      set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(U.CYAN, 0.25) or U.BG)); gfx.rect(x, y, w1, L.rh, 1)
      set(hot and U.AMBER or (on and U.CYAN or U.LINE)); gfx.rect(x, y, w1, L.rh, 0)
      text(x + 1, y, label, hot and U.AMBER or (on and U.CYAN or U.TEXT))
      if hot then hover[kind] = what end
      hint(kind, x, y, w1, L.rh, what)
      return w1
    end
    -- строка выше: autozoom слева, markers справа (не влезло слово — mk / az)
    local ya = y4 - L.rh
    if ya >= hy + 1 + 3 * L.rh - 1 then
      -- 31 окт: сразу под autoarm (ряд 4) — autozoom, ниже markers полностью (каждый своей строкой)
      local yz = hy + 1 + 3 * L.rh
      -- 31 окт: без полосы эффектов в строке 4 — имя паттерна (выше), тогда autozoom … mk строкой над длиной
      local named = not (state.fxrow and (L.fxrow_h or 0) > 0) and yz + L.rh <= hy + (L.header_rows - 2) * L.rh + 2
      if named then
        local yr = yz   -- 31 окт: zoom mark — в строке 4, имя паттерна — под ними, над длиной
        btn(bx, yr, (ms('autozoom') + ms('mark') + 6 <= bw) and 'autozoom' or 'zoom', 'viewbtn', 'autozoom', state.autozoom)
        btn(bx + bw - ms('mark') - 2, yr, 'mark', 'viewbtn', 'markers')
      else
        btn(bx, yz, (ms('autozoom') + 2 <= bw) and 'autozoom' or 'zoom', 'viewbtn', 'autozoom', state.autozoom)
        if yz + L.rh <= y4 - L.rh then btn(bx, yz + L.rh, (ms('markers') + 2 <= bw) and 'markers' or 'mark', 'viewbtn', 'markers')
        else btn(bx + bw - ms('mark') - 2, yz, 'mark', 'viewbtn', 'markers') end   -- 31 окт: короче — zoom / mark (не az mk)
      end
    else
      -- 20 окт: низкая шапка — az mk в конце ряда 1 (за param), x2 /2 остаются на своём месте у длины
      local xr = D.cn_r1x or bx
      local yr = hy + 1 + L.rh
      if xr + ms('mark') + 2 <= bx + bw then
        local mw = ms('mark') + 2
        btn(bx + bw - mw, yr, 'mark', 'viewbtn', 'markers')
        if xr + ms('zoom') + 2 <= bx + bw - mw - 2 then btn(bx + bw - mw - 2 - (ms('zoom') + 2), yr, 'zoom', 'viewbtn', 'autozoom', state.autozoom) end
      end
    end
    D.rglen_at = nil
    if info.cur_region and not D.len_in_fx then   -- 31 окт: длина и x2 /2 — над именем паттерна в полосе эффектов
      local rg = info.cur_region
      -- x2 /2 справа от длины — и в низкой шапке (20 окт: markers ушли в ряд 1)
      local rx = bx + bw
      rx = rx - (ms('/2') + 2); btn(rx, y4, '/2', 'rgbtn', 'half')
      rx = rx - 2 - (ms('x2') + 2); btn(rx, y4, 'x2', 'rgbtn', 'double')
      rx = rx - 2
      local aw = ms('<') + 2
      local s2 = tostring(math.max(0, math.floor((rg.r1 - rg.r0) + 0.5)))
      local lw = rx - bx
      local inb = my >= y4 and my < y4 + L.rh
      local hl = inb and mx >= bx and mx < bx + aw
      local hr = inb and mx >= bx + lw - aw and mx < bx + lw
      local hn = inb and not hl and not hr and mx >= bx and mx < bx + lw
      set(hn and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, y4, lw, L.rh, 1)
      set(hn and U.AMBER or U.LINE); gfx.rect(bx, y4, lw, L.rh, 0)
      text(bx + math.max(aw, math.floor((lw - ms(s2)) / 2)), y4, fit(s2, lw - 2 * aw), hn and U.AMBER or U.TEXT)
      text(bx + 1, y4, '<', hl and U.AMBER or U.GREY)
      text(bx + lw - ms('>') - 1, y4, '>', hr and U.AMBER or U.GREY)
      if hl then hover.rglen = -1 elseif hr then hover.rglen = 1 elseif hn then hover.rglen = 0 end
      hint('rglen', bx, y4, aw, L.rh, -1); hint('rglen', bx + aw, y4, lw - 2 * aw, L.rh, 0); hint('rglen', bx + lw - aw, y4, aw, L.rh, 1)
      D.rglen_at = { bx, y4 + L.rh + 1 }
    end
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
  -- 20 окт: мастер сложен — полосы до края последней колонки (не за линию мастера)
  local WB = W
  if L.mfold then WB = D.cols_edge(L) or W end
  for i, r in ipairs(rows) do
    local y = L.body_y + (i - 1) * L.rh
    if ph then
      local k = ph - r.row
      if k == 0 then set(D.PLAY); gfx.rect(tx0, y, WB - tx0, L.rh, 1)
      elseif k > 0 and k <= D.PHTAIL then set(D.PLAYC, 0.30 * (1 - k / (D.PHTAIL + 1))); gfx.rect(tx0, y, WB - tx0, L.rh, 1) end
    end
    if vc and vc.row == r.row then set(state.fixed and U.mix(D.CURROW, U.TEXT, 0.12) or D.CURROW); gfx.rect(tx0, y, WB - tx0, L.rh, 1); D.cur_y = y end
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
              -- 12 окт: точка реза прицела вкладки item — полоска поперёк ноты, рисуется поверх волны (ниже)
              if info.aim_cut and info.aim_cut.item == it.item then
                local ay = yr(info.aim_cut.rf)
                if ay > cy0 and ay < cy1 then D.aim_line = { x0, ay, w0 } end
              end
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
                -- 16 окт: только верх и низ (начало / конец item); боковые кромки рядом с линией между треками
                -- давали 3-4 линии подряд — между треками одна линия
                set(col)
                if y0 >= by0 then gfx.rect(fx0, cy0, fw0, 2, 1) end
                if y1 <= by1 then gfx.rect(fx0, cy1 - 2, fw0, 2, 1) end
              end
              -- 13 окт: пустой MIDI-клип — знак в его первой строке (16 окт: µ, # — drumrs5k; Del / x на ней — удалить клип)
              if it.empty and y0 >= by0 and y0 < by1 then
                local mu = D.mu()                                -- 16 окт: знак MIDI — µ (# теперь drumrs5k)
                set(U.BG); gfx.rect(x0 + 2, y0 + 1, ms(mu) + 4, L.rh - 2, 1)
                text(x0 + 4, y0 + 1, mu, U.mix(rgb, U.TEXT, 0.6))
                if mx >= x0 and mx < x0 + ms(mu) + 6 and my >= y0 and my < y0 + L.rh then hover.emptymidi = it.item end
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
          -- 6 окт: наложенные automation items — по слотам: у каждого своя
          -- узкая ручка рядом, рамка — от неё; подпись только на широкой
          -- ручке (на узкой имя — в статусе), чтобы ничего не наслаивалось
          local slot, nslot = {}, 1
          if #(ev.e.ais or {}) > 1 then
            local order, ends = {}, {}
            for _, ai in ipairs(ev.e.ais) do order[#order + 1] = ai end
            table.sort(order, function(a, b) return a.r0 < b.r0 end)
            for _, ai in ipairs(order) do
              local s = 1
              while ends[s] and ends[s] > ai.r0 + 1e-6 do s = s + 1 end
              ends[s] = ai.r1; slot[ai] = s
              if s > nslot then nslot = s end
            end
          end
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
              local sw = (ev.G and ev.G.env3) and 3 or (L.th + 4)   -- 24 окт: в узкой колонке — тонкая ручка
              local hw = nslot > 1 and math.max(3, math.floor(sw / nslot)) or sw
              local hx = ev.x + ((slot[ai] or 1) - 1) * hw
              set(U.mix(col, U.TEXT, ai.sel and 0.4 or 0.0)); gfx.rect(hx, cy0, ev.x + ev.w - hx, cy1 - cy0, 0)
              local hot = hover.aiedge and hover.aiedge.e == ev.e and hover.aiedge.idx == ai.idx
              -- ручка слева — полоса в строку текста шириной, в ней имя вертикально (2 окт)
              -- ручка (6 окт): рисуется ПОСЛЕ строк, непрозрачной — линии тактов
              -- её не режут, как полосу с именем в REAPER; здесь — только запись
              D.ai_handles = D.ai_handles or {}
              local hd = { x = hx, y = cy0, w = hw, h = cy1 - cy0, col = col, hot = hot and hover.aiedge.edge == 'move', label = hw >= L.th + 2 and ai.label or nil, seams = {} }
              D.ai_handles[#D.ai_handles + 1] = hd
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
                    gfx.line(ev.x + ev.w - 1, ly - tz, ev.x + ev.w - 1 - tz, ly); gfx.line(ev.x + ev.w - 1 - tz, ly, ev.x + ev.w - 1, ly + tz)
                    hd.seams[#hd.seams + 1] = ly                  -- вырез на ручке — поверх неё, после строк
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
                elseif mx >= hx and mx < hx + hw then edge = 'move' end
                if edge then hover.aiedge = { e = ev.e, idx = ai.idx, edge = edge, pos = ai.pos, len = ai.len, col = c.col, label = ai.label } end
              end
            end
          end
        end
      end
    end
  end
  -- выделение VISUAL (8 окт): без рамки (она ложилась на соседнюю колонку) и
  -- одним полупрозрачным прямоугольником на колонку, под текстом, вместо
  -- заливки каждой ячейки — быстрее и без швов
  if vis then
    local y0, y1
    for i, r in ipairs(rows) do
      if not r.clip and r.row >= vis.r0 and r.row <= vis.r1 then
        local yy = L.body_y + (i - 1) * L.rh
        y0 = y0 or yy; y1 = yy + L.rh
      end
    end
    if y0 then
      for fi = vis.f0, vis.f1 do
        local f = L.flat[fi]
        if f and f.x then
          if f.env then set(U.TEXT, 0.10) else set(U.CYAN, 0.16) end
          if vis.field and not f.env and not f.ml then   -- 19 окт: v на поле — только оно
            local fx2, fw2 = D.field_rect(f.G or L, vis.field)
            if fx2 then gfx.rect(f.x + fx2 - 1, y0, fw2 + 2, y1 - y0, 1) end
          else gfx.rect(f.x, y0, f.w, y1 - y0, 1) end
        end
      end
      gfx.a = 1
    end
  end
  D.pmark('draw: rows')
  -- граница регионов (5 окт): тонкие линии цвета регионов у линии такта —
  -- уходящий над ней, следующий под ней; фоном, items рисуются поверх
  local rgedge = {}
  if info.ruler and info.ruler.regions and state.rgedges ~= false then
    for _, rg in ipairs(info.ruler.regions) do
      local e0 = rgedge[rg.r0] or {}; e0.nxt = rg.rgb or D.BAR; rgedge[rg.r0] = e0
      local e1 = rgedge[rg.r1] or {}; e1.prv = rg.rgb or D.BAR; rgedge[rg.r1] = e1
    end
  end
  -- 21 окт: граница паттерна — линия 2 px цвета линий темы (явнее линии такта), граница секции — 2 px её цветом поверх
  local patb, secb = {}, {}
  if state.rgedges ~= false then
    for _, rg in ipairs(info.ruler and info.ruler.regions or {}) do
      patb[math.floor(rg.r0 + 0.5)] = true; patb[math.floor(rg.r1 + 0.5)] = true
    end
    for _, sc in ipairs(info.sections or {}) do
      local c = (info.region_rgb and sc.color and sc.color ~= 0 and info.region_rgb(sc.color)) or U.CYAN
      secb[math.floor(sc.r0 + 0.5)] = c; secb[math.floor(sc.r1 + 0.5)] = c
    end
  end
  -- 13 окт: линии маркеров через все треки (опция marker lines) — цвет маркера, у верха его строки
  local mkline = {}
  if info.ruler and info.ruler.markers and state.mkedges then
    for _, mk in ipairs(info.ruler.markers) do if not D.se_hidden(state, mk) then mkline[math.floor(mk.row_f + 1e-6)] = mk.rgb or U.AMBER end end
  end
  -- 15 окт: яркость точек и номера строки — по акценту (такт / сильные доли паттерна метронома ярко,
  -- как номер; деления доли — ступенями тише); база восстанавливается после строк
  local empty0, under0 = D.EMPTY, D.EMPTY_UNDER
  local ACC_F = { [0] = 1, 0.8, 0.5, 0.3, 0.15, 0 }
  -- 19 окт: волна пэда drumrs5k под MIDI-нотой кита: строка → { голова-волна, номер строки в ней }; конец — следующая
  -- нота подколонки (one-shot) или и OFF (obey note-offs); голова выше окна тоже звучит
  local kwmap = nil
  if info.kit_wave and #rows > 0 then
    local r0, r1 = rows[1].row, rows[#rows].row
    D.kw_heads = D.kw_heads or setmetatable({}, { __mode = 'k' })
    for fi, f in ipairs(L.flat) do
      local G = f.G or L
      if f.x and f.lane and f.sub and (G.w_wave or 0) > 0 and f.col and info.kit_wave(f.col) then
        local hs = D.kw_heads[f.sub]
        if not hs then
          hs = {}
          for row, cl in pairs(f.sub) do if type(row) == 'number' and (cl.kind == 'midi' or cl.kind == 'off' or cl.kind == 'audio') then hs[#hs + 1] = { row = row, c = cl } end end
          table.sort(hs, function(p, q) return p.row < q.row end)
          D.kw_heads[f.sub] = hs
        end
        for k, h in ipairs(hs) do
          if h.row > r1 then break end
          if h.c.kind == 'midi' and h.c.pitch and h.row >= r0 - 2048 then
            -- 19 окт: голова-волна — раз на снимок (h живёт, пока жив f.sub), не каждый кадр
            local ph = h.ph
            if ph == nil then ph = info.kit_wave(f.col, h.c.pitch, h.row); if ph == 'wait' then ph = false else ph = ph or false; h.ph = ph end end   -- 28 окт: 'wait' — slixer ещё не ответил
            if ph == false then ph = nil end
            if ph then
              local e = h.row + math.ceil(ph.rows_f)
              for k2 = k + 1, #hs do
                local nx = hs[k2]
                -- 24 окт: OFF обрывает волну, если пэд его слушает: obey без choke-группы — любой; в группе / «сам себя» — только явный
                if nx.c.kind ~= 'off' or (ph.obey and ((ph.choke or 0) == 0 or nx.c.explicit)) then e = math.min(e, nx.row); break end
              end
              if e > r0 then
                ph.muted = ph.muted or h.c.muted
                kwmap = kwmap or {}
                local m = kwmap[fi] or {}; kwmap[fi] = m
                for rr = math.max(r0, h.row), math.min(r1, e - 1) do m[rr] = { ph, rr - h.row } end
              end
            end
          end
        end
      end
    end
  end
  for i, r in ipairs(rows) do
    local y = L.body_y + (i - 1) * L.rh
    local ty = y + 1
    local is_cur_row = vc and vc.row == r.row
    local af = ACC_F[r.acc or 5] or 0
    D.EMPTY = af > 0 and U.mix(empty0, U.TEXT, af) or empty0
    D.EMPTY_UNDER = af > 0 and U.mix(under0, U.TEXT, af * 0.6) or under0
    if mkline[r.row] then set(mkline[r.row], 0.75); gfx.rect(tx0, y, W - tx0, 1, 1); gfx.a = 1 end
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
    if secb[r.row] then D.sec_lines = D.sec_lines or {}; D.sec_lines[#D.sec_lines + 1] = { tx0, y, W - tx0, secb[r.row] }   -- 23 окт: поверх ячеек (фон колонок закрывал)
    elseif patb[r.row] then set(U.LINE); gfx.rect(tx0, y, W - tx0, 2, 1) end
    -- кромки: строка курсора — янтарная, edit-курсор — зелёная; опция
    -- curline (3 окт): top / bottom / off. Начинаются за разделителем матрицы;
    -- метки у номера строки нет (3 окт, просьба)
    local cl = state.curline or 'top'
    if cl ~= 'off' then
      local ly = cl == 'bottom' and (y + L.rh - 1) or y
      -- от края полос регионов / маркеров вправо (через линейку, если она
      -- включена): на сами полосы не заходит (3 окт)
      local lx = tx0 + L.rl
      if is_cur_row then set(D.CURTOP); gfx.rect(lx, ly, W - lx, 1, 1) end
      if r.row == cur then set(D.EDITTOP); gfx.rect(lx, ly, W - lx, 1, 1) end
      -- 6 окт: кромки ещё раз после ячеек — серая ячейка курсора их закрывала
      if is_cur_row or r.row == cur then D.edge_lines = D.edge_lines or {}; D.edge_lines[#D.edge_lines + 1] = { lx, ly, W - lx, r.row == cur } end
    end
    -- 20 окт: united stepruler — на долях такт.доля (такт ярче), шаги под ней — номером чуть темнее
    local ulab = L.united and (r.beat or r.bar) and not r.clip and info.tl_label and (info.tl_label(r.row))
    if ulab then text(tx0 + L.rl + L.tl_w + L.pad, ty, ulab, (is_cur_row or r.bar) and U.TEXT or U.mix(U.TEXT, U.GREY, 0.5))
    else
      local nc = is_cur_row and U.TEXT or ((r.acc or 5) <= 2 and D.EMPTY or U.GREY)
      if L.united and not is_cur_row then nc = U.mix(nc, U.BG, 0.2) end
      text(tx0 + L.rl + L.tl_w + L.pad, ty, r.label, nc)   -- 15 окт: номер — яркостью акцента, как точки
    end
    -- линейка таймлайна: на долях, такт ярче (формат меток — как у линейки
    -- REAPER); слева от номеров шагов, за полосами регионов (3 окт)
    if L.tl_w > 0 and (r.beat or r.bar) and info.tl_label then
      local b, t = info.tl_label(r.row)
      local tx = tx0 + L.rl + L.pad
      local tcol = r.bar and U.TEXT or U.GREY
      local tlr = L.tlr or state.tlruler
      if tlr == 'beats' or tlr == 'both' then text(tx, ty, b, tcol); tx = tx + ms('999.4') + L.pad end
      if tlr == 'time' or tlr == 'both' then text(tx, ty, t, tlr == 'both' and U.GREY or tcol) end
    end
    local in_body = not r.clip and my >= y and my < y + L.rh and my >= L.body_y and my < L.body_y + L.nrows * L.rh and mx < W
    if in_body then hover.row = r end
    -- номера шагов (2 окт): протяжка = time selection REAPER
    if in_body and mx >= tx0 + L.rl and mx < tx0 + L.label_w then hover.rownum = r.row end
    for _, c in ipairs(L.cols) do
      -- 21 окт: трек уходит под мастер — его текст не дальше границы мастера
      local clip_k = D.clip
      if not c.master then   -- пересечение с клипом кадра
        local tc = D.trk_clip or {}; D.trk_clip = tc
        tc[1], tc[2] = clip_k and clip_k[1] or 0, math.min(clip_k and clip_k[2] or 1e9, L.cols_r - 1)
        tc[3], tc[4] = clip_k and clip_k[3], clip_k and clip_k[4]
        D.clip = tc
      end
      -- подсказка-прыжок: одна на такт в колонке трека (не на каждое событие)
      -- 20 окт: и на долях (строки с точками темнее) — приоритетные прыжки по трекеру (метки раньше кнопок)
      if (r.bar or r.beat) and not r.clip and c.lanes[1] then hint(r.bar and 'bar' or 'beat', c.x + 1, y, c.w - 2, L.rh, { fi = c.lanes[1].f0, row = r.row }) end
      for _, ln in ipairs(c.lanes) do
        for si = 1, ln.nsub do
          local fi = ln.f0 + si - 1
          local f = L.flat[fi]
          local x = f.x
          if x then
            local inv = (vc and vc.fi == fi and vc.row == r.row) and (c.folded and 1 or (vc.field or 1)) or nil
            if inv == 1 and vc.sub == 'inst' and (f.G or L).x_inst then inv = 'inst' end   -- курсор на номере инструмента
            if inv == 1 and vc.sub == 'slc' and (f.G or L).x_slc then inv = 'slc' end     -- 11 окт: курсор на слайсе
            if inv == 2 and vc.sub == 'pan' and (f.G or L).x_pan then inv = 'pan' end     -- 14 окт: курсор на пане
            if inv == 1 and vc.sub == 'wave' and ((f.G or L).w_wave or 0) > 0 then inv = 'wave' end   -- 16 окт: курсор в волне
            D.fx_half = (type(inv) == 'number' and inv >= 4 and not c.folded and not f.env) and (vc.sub == 'val' and 'val' or 'code') or nil   -- 12 окт
            -- ячейка курсора (4 окт): подложка — ПОВЕРХ волны ячейки, под текстом;
            -- draw_cell зовёт D.cur_box сразу после волны (волна фоном её закрашивала)
            if inv then
              D.inv_bg = info.focus == 'tracker' and D.CURCELL or U.LINE   -- 28 окт: акцент — у курсора в фокусе (D.CURCELL), вне фокуса — тусклый
              local G, folded, inv_f, fw0, half = f.G or L, c.folded, inv, f.w, D.fx_half
              D.cur_box = function()
                set(D.inv_bg)
                if folded then gfx.rect(x, y, fw0, L.rh, 1)
                elseif half then   -- 12 окт: половина поля команды
                  local fx = D.field_rect(G, inv_f); local w2 = ms('00')
                  if half == 'val' then gfx.rect(x + fx + w2 - 1, y, w2 + 2, L.rh, 1) else gfx.rect(x + fx - 1, y, w2 + 1, L.rh, 1) end
                elseif inv_f == 'wave' then local fx, fw = D.field_rect(G, 'wave'); set(D.CUR_ACC or U.AMBER); gfx.rect(x + fx - 1, y, fw + 2, L.rh, 0)   -- 16 окт: рамкой — волна видна
                else local fx, fw = D.field_rect(G, inv_f); gfx.rect(x + fx - 1, y, fw + 2, L.rh, 1) end
              end
              if c.folded or r.row < 0 or r.clip then D.cur_box(); D.cur_box = nil end
            end
            local cell
            if r.clip then
            elseif r.row < 0 then
              -- 11 окт: до начала проекта — пустые ячейки точками, вдвое тусклее (видно, что это «минус»)
              if not (c.chord or c.folded) then
                local e0, u0 = D.EMPTY, D.EMPTY_UNDER
                D.EMPTY = U.mix(U.BG, e0, 0.45); D.EMPTY_UNDER = D.EMPTY
                draw_cell(f.G or L, nil, x, y, ty, inv)
                D.EMPTY, D.EMPTY_UNDER = e0, u0
              end
            elseif c.chord then D.draw_chord_cell(L, c.col, r.row, x, y, ty, inv ~= nil, f.w)
            elseif c.folded then draw_fold_cell(L, c.col, r.row, x, y, ty, inv ~= nil)
            else
              cell = f.sub[r.row]; draw_cell(f.G or L, cell, x, y, ty, inv)
              -- 27 окт: в строке есть автоматизация трека — «~» в колонке слева от ноты (сложенные ноты «+» важнее)
              -- «+» уже нарисован: «~» рядом (колонка в два знака) или под ним (высокая строка); без «+» — на его месте
              local G2 = f.G or L
              local hm = c.lanes[f.li] and c.lanes[f.li].hm and c.lanes[f.li].hm[f.si]
              if G2.x_fold and ((f.si == 1 and f.li == 1 and c.marks and c.marks[r.row]) or (hm and hm[r.row])) then
                if not (cell and cell.fold) then text(x + G2.x_fold, ty, '~', D.ENVMARK or U.AMBER)
                elseif G2.fold_wide then text(x + G2.x_fold + ms('+'), ty, '~', D.ENVMARK or U.AMBER)
                elseif L.fold2_tall then text(x + G2.x_fold, ty + L.th, '~', D.ENVMARK or U.AMBER) end
              end
              -- 20 окт: метка-прыжок и на каждой ноте (её поле ноты)
              if cell and (cell.kind == 'audio' or cell.kind == 'midi') then hint('note', x + ((f.G or L).x_note or 0), y, math.max(ms('aa'), (f.G or L).w_note or 0), L.rh, { fi = fi, row = r.row }) end
              local kw = kwmap and kwmap[fi] and kwmap[fi][r.row]
              if kw and not (cell and (cell.kind == 'audio' or (cell.kind == 'cont' and cell.of and cell.of.kind == 'audio'))) then draw_wave(f.G or L, kw[1], kw[2], x, y, kw[1].muted, false) end
            end
            -- 13 окт: набираемая команда / значение — прямо в ячейке курсора («0R__»), не только в статусе
            if inv and info.hexbuf and info.hexbuf ~= '' and type(inv) == 'number' and inv >= 2 and not c.folded and not f.env then
              local fx, fw = D.field_rect(f.G or L, inv)
              local hb = info.hexbuf
              local need = inv >= 4 and 4 or 2
              local t = hb .. string.rep('_', math.max(0, need - #hb))
              set(U.tint(U.AMBER, 0.45)); gfx.rect(x + fx - 1, y, math.max(fw, ms(t)) + 2, L.rh, 1)
              text(x + fx, ty, t, U.AMBER)
            end
            -- 15 окт: набранное (счётчик, оператор: 3d) — тегом [3d_] сразу за ячейкой курсора; рисуется в конце кадра
            if inv and info.typed and info.typed ~= '' then
              local fx, fw = D.field_rect(f.G or L, type(inv) == 'number' and inv or 1)
              D.typed_at = { x = x + fx, y = y, ty = ty, w = fw, s = '[' .. info.typed .. '_]' }   -- 15 окт: прямо на ячейке курсора
            end
            D.cur_box = nil; D.fx_half = nil
            if in_body and mx >= x and mx < x + f.w then
              hover.fi = fi; hover.cell = cell; hover.col = c.col
              -- 19 окт: колонки команд — по геометрии этой подколонки (у трека их бывает больше общего L.nfx);
              -- промежуток между полями — ближайшее (щелчок по пустой ячейке ставит курсор в её поле)
              local Gf = f.G or L
              local best, bd
              for fld = 1, f.compact and 1 or (f.narrow and 2 or (3 + math.max(Gf.nfx or L.nfx or 0, #(Gf.x_fx or {})))) do
                local fx, fw = D.field_rect(Gf, fld)
                if fx then
                  if mx >= x + fx and mx < x + fx + fw + L.pad then best = fld; bd = 0; break end
                  local dd = math.min(math.abs(mx - (x + fx)), math.abs(mx - (x + fx + fw)))
                  if not bd or dd < bd then best, bd = fld, dd end
                end
              end
              hover.field = best
              -- номер инструмента под мышью (5 окт) — подполе ноты
              local G2 = f.G or L
              if G2.x_inst and mx >= x + G2.x_inst and mx < x + G2.x_inst + ms('00') + 2 then hover.field = 1; hover.fsub = 'inst' end
              if G2.x_slc and not G2.notes_only and mx >= x + G2.x_slc and mx < x + G2.x_slc + (G2.w_slc or ms('S00')) + 2 then hover.field = 1; hover.fsub = 'slc' end   -- 11 окт
              do
              end
            end
          end
        end
      end
      for _, ev in ipairs(c.envs) do
        local EG = ev.G or L
        if r.clip then goto env_next end
        -- выделение на лейне огибающей (6 окт): Shift+j/k, мышь — лёгкое
        -- высветление фона, линия и точки под ним видны
        if vc and vc.fi == ev.fi and vc.row == r.row then
          set(info.focus == 'tracker' and (D.CUR_ACC or U.AMBER) or U.LINE)   -- 28 окт: полый курсор (огибающая) — цветом курсора
          if not ((vc.field or 1) == 2 and not ev.G) then gfx.rect(ev.x, y, ev.w, L.rh, 0) end
        end
        -- курсор поля формы — под значением точки (строка ниже курсора)
        if vc and vc.fi == ev.fi and vc.row == r.row - 1 and (vc.field or 1) == 2 and not ev.G then
          set(info.focus == 'tracker' and (D.CUR_ACC or U.AMBER) or U.LINE)
          gfx.rect(ev.x + L.env_bx + L.env_bar_w + L.pad - 1, y, L.env_shape_w + 2, L.rh, 0)
        end
        draw_env_cell(EG, env_vals[ev][i], env_vals[ev][i - 1], ev.x, y, ty, ev.e, env_vals[ev][i + 1], (D.envvals and D.envvals[(c.col.guid or '') .. '/' .. (ev.e.name or '')]) or ((c.master or EG.env3) and 'vals') or nil)   -- 13 окт: у мастера по умолчанию — числа
        do   -- 30 окт: JOG — новые значения шагов огибающей: столбик и точка янтарём до записи
          local jv = D.jog and D.jog.env == ev.e.env and D.jog.map[r.row]
          if jv then
            local bx0, bw0 = ev.x + EG.env_bx, EG.env_bar_w
            set(U.AMBER, D.jog.row == r.row and 0.7 or 0.35); gfx.rect(bx0, y + 2, math.max(1, math.floor(jv * (bw0 - 1) + 0.5)), L.rh - 4, 1); gfx.a = 1
            set(U.AMBER); gfx.circle(bx0 + math.floor(jv * (bw0 - 1) + 0.5), y + math.floor(L.rh / 2), 2, 1, 1)
          end
        end
        if in_body and mx >= ev.x and mx < ev.x + ev.w then
          hover.col = c.col; hover.env = ev.e; hover.envv = env_vals[ev][i]; hover.fi = ev.fi
          hover.envx = math.max(0, math.min(1, (mx - ev.x - L.env_bx) / (EG.env_bar_w - 1)))
          -- поле формы — с клавиатуры (l, буквы в INSERT); мышь — всегда значение
          hover.field = 1
          -- точный клик по точке (±4 px) — её можно тянуть в любом режиме (2 окт)
          local ev0 = env_vals[ev][i]
          if ev0 and ev0.pt then
            local px = ev.x + EG.env_bx + math.floor(ev0.v * (EG.env_bar_w - 1) + 0.5)
            if math.abs(mx - px) <= 4 and math.abs(my - (y + 1)) <= 4 then hover.envpt = { e = ev.e, row = r.row, bx = ev.x + EG.env_bx, bw = EG.env_bar_w } end
          end
        end
        ::env_next::
      end
      -- MIDI-лейны: значение на строке события; CC / PC держатся тусклой
      -- полоской до следующего события; пусто — точки поля
      for _, m in ipairs(c.mls or {}) do
        if r.clip then goto ml_next end
        do
          local ml = m.ml
          local e = ml.ev[r.row]
          local foc = vc and vc.fi == m.fi and vc.row == r.row
          -- 15 окт: курсор — как везде (заливка D.CURCELL, текст цветом фона), не янтарная рамка
          local cbg = foc and (info.focus == 'tracker' and D.CURCELL or U.LINE) or nil
          if cbg then set(cbg); gfx.rect(m.x, y, m.w, L.rh, 1) end
          local function ctext(tx2, ty2, str, col) text(tx2, ty2, str, cbg and U.BG or col) end
          if (ml.kind == 'cc' or ml.kind == 'pc' or ml.kind == 'at' or ml.kind == 'pat' or ml.kind == 'pb') then
            -- держится ли значение: последнее событие до строки
            local held
            for k = #ml.rows, 1, -1 do if ml.rows[k] <= r.row then held = ml.ev[ml.rows[k]].v; break end end
            if held and ml.kind == 'pb' then
              -- 22 окт: бенд — от центра (64 = без бенда — пусто; было — полоска на полширины в каждой строке)
              local cx0, half = m.x + math.floor(m.w / 2), math.floor((m.w - 2) / 2)
              local d = math.floor((held - 64) / 64 * half + 0.5)
              if d ~= 0 then set(U.mix(U.CYAN, U.BG, 0.35)); gfx.rect(d > 0 and cx0 or cx0 + d, y + L.rh - 4, math.abs(d), 3, 1) end
            elseif held and (ml.kind == 'cc' or ml.kind == 'at' or ml.kind == 'pat') then
              set(U.mix(U.CYAN, U.BG, 0.35)); gfx.rect(m.x + 1, y + L.rh - 4, math.max(1, math.floor(held / 127 * (m.w - 2))), 3, 1)   -- 11 окт: ярче и толще — было еле видно
            end
          end
          -- 30 окт: JOG (CONTROL) — значения шагов прямо в клетках: столбик янтарём и новое число, до записи
          local jv = D.jog and D.jog.mlname == ml.name and D.jog.track == c.col.track and D.jog.map[r.row]
          if jv then
            set(U.AMBER, D.jog.row == r.row and 0.85 or 0.45); gfx.rect(m.x + 1, y + 1, math.max(1, math.floor(jv * (m.w - 2) + 0.5)), L.rh - 2, 1); gfx.a = 1
            text(m.x + L.pad, ty, fit(D.envfmt == 'hex' and ('%02X'):format(math.floor(jv * 127 + 0.5)) or tostring(math.floor(jv * 127 + 0.5)), m.w - L.pad), D.jog.row == r.row and U.BG or U.TEXT)
          elseif e then
            local txt = ml.kind == 'tx' or ml.kind == 'cmd' or ml.kind == 'vis' or ml.kind == 'chd'
            local t = txt and ((e.text ~= '' and e.text) or 'mark') or (ml.kind == 'sx' and 'SX' or (D.envfmt == 'hex' and ('%02X'):format(e.v or 0) or tostring(e.v or 0)))
            -- 13 окт: visor / cmd — текст команды строкой (без картинок поверх строк), секции через пробел:
            -- первое слово (сцена / команда) ярко, аргументы тусклее
            local head, rest = t:match('^(%S+)(%s.*)$')
            if (ml.kind == 'vis' or ml.kind == 'cmd') and head then
              local hc = e.n > 1 and U.AMBER or U.CYAN
              local hw = gfx.measurestr(head)
              ctext(m.x + L.pad, ty, fit(head, m.w - L.pad), hc)
              if hw < m.w - L.pad - L.cw then ctext(m.x + L.pad + hw, ty, fit(rest, m.w - L.pad - hw), U.mix(U.TEXT, U.BG, 0.3)) end
            else ctext(m.x + L.pad, ty, fit(t, m.w - L.pad), e.n > 1 and U.AMBER or U.CYAN) end
          else ctext(m.x + L.pad, ty, (ml.kind == 'tx' or ml.kind == 'cmd' or ml.kind == 'vis' or ml.kind == 'chd') and '....' or '..', D.EMPTY) end
          if in_body and mx >= m.x and mx < m.x + m.w then hover.col = c.col; hover.fi = m.fi; hover.mlane = ml; hover.field = 1 end
        end
        ::ml_next::
      end
      D.clip = clip_k
    end
  end
  D.EMPTY, D.EMPTY_UNDER = empty0, under0
  -- 15 окт: поле трекера (строки и шапка подколонок) — для рамки фокуса; модлайн — режим крупно в его
  -- левом нижнем углу на подложке (курсор в нижних строках — в левом верхнем, чтобы не закрыть его)
  D.trk_field = { tx0, L.body_y - L.rh - 1, W - tx0, L.body_h + L.rh + 1 + (D.SBW or 3) + 2 }
  -- модлайн (15 окт): своя строка под полем — режим крупно слева, справа мелко: трек и строка курсора
  if (L.mode_h or 0) > 0 and L.mode_y then
    local my0 = L.mode_y
    set(U.PANEL); gfx.rect(tx0, my0, W - tx0, L.mode_h, 1)
    local x = tx0 + (L.rl or 0) + L.pad
    local mw = D.draw_mode(L, x, my0 + 3, 3 * (W - tx0), info.status_left or 'NORMAL')
    -- сегменты, как в Emacs: трек · поле · строка · такт.доля · регион · выделение; имя — TEXT, подписи — GREY
    local f = vc and L.flat and L.flat[vc.fi]
    local segs = {}
    if f and f.col then
      segs[#segs + 1] = { (f.col.name ~= '' and f.col.name) or 'track' }
      local fld = vc.field or 1
      local fname = f.env and (f.env.name or 'envelope') or (vc.sub == 'inst' and 'inst') or (vc.sub == 'wave' and 'wave') or (vc.sub == 'slc' and 'slice') or (vc.sub == 'pan' and 'pan')
        or ({ 'note', 'vol', 'delay' })[fld] or ('fx ' .. (fld - 3))
      segs[#segs + 1] = { fname, 'col' }   -- 16 окт: подпись col (было field)
      local row = math.max(0, vc.row or 0)
      segs[#segs + 1] = { ('%04d'):format(row + (D.ROW_BASE or 1)), 'row' }
      if info.bbt then segs[#segs + 1] = { info.bbt(row), 'bar' } end
      for _, rg in ipairs(info.ruler and info.ruler.regions or {}) do
        if row >= rg.r0 and row < rg.r1 and (rg.name or '') ~= '' then segs[#segs + 1] = { rg.name, 'region' }; break end
      end
      local vs = info.vis
      if vs and vs.r0 then segs[#segs + 1] = { ('%d x %d'):format(math.abs(vs.r1 - vs.r0) + 1, math.abs((vs.f1 or 0) - (vs.f0 or 0)) + 1), 'rows x cols' } end
    end
    local wx = x + mw + 3 * L.pad
    local ty = my0 + 3 + math.floor(L.th / 2)
    for k, sg in ipairs(segs) do
      if k > 1 then text(wx, ty, '·', U.DIM); wx = wx + ms('·') + 2 * L.pad end
      if sg[2] then local lb = sg[2]; if wx + ms(lb) + L.pad >= W - L.pad then break end; text(wx, ty, lb, U.GREY); wx = wx + ms(lb) + L.pad end   -- пробел в битмапе — нулевой ширины
      local room = W - L.pad - wx
      if room <= ms('W') then break end
      text(wx, ty, fit(sg[1], room), U.TEXT); wx = wx + math.min(room, ms(sg[1])) + 2 * L.pad
    end
  end
  D.mfold_draw(L, snap, hover)   -- 17 окт: сложенный мастер
  D.sf_draw(L, info, state)      -- 20 окт: Shift+F — призрак сэмпла на месте вставки
  D.pmark('draw: ai handles, tint, cursor')
  for _, e in ipairs(D.sec_lines or {}) do set(e[4]); gfx.rect(e[1], e[2], e[3], 2, 1) end   -- граница секции — её цветом через все треки
  D.sec_lines = nil
  for _, e in ipairs(D.edge_lines or {}) do set(e[4] and D.EDITTOP or D.CURTOP); gfx.rect(e[1], e[2], e[3], 1, 1) end
  D.edge_lines = nil
  if D.aim_line then   -- 12 окт: полоска реза прицела — янтарь, как линия прицела во вкладке item, с мягким ореолом
    local a = D.aim_line
    set(U.AMBER, 0.25); gfx.rect(a[1] + 2, a[2] - 2, a[3] - 4, 5, 1)
    set(U.AMBER); gfx.rect(a[1] + 2, a[2], a[3] - 4, 1, 1)
    D.aim_line = nil
  end
  -- ручки automation items (6 окт): поверх линий строк, непрозрачные; имя
  -- вертикально; швы лупа — вырезы цвета фона в ручке
  for _, hd in ipairs(D.ai_handles or {}) do
    -- цвет ручки = цвет огибающей как есть (6 окт: как полоса с именем в REAPER,
    -- без притемнения); под мышью — чуть светлее
    local hc = hd.hot and U.mix(hd.col, U.TEXT, 0.25) or hd.col
    set(hc); gfx.rect(hd.x, hd.y, hd.w, hd.h, 1)
    if hd.h > L.th * 2 and hd.label then D.vtext(hd.x + 2, hd.y + 2, hd.h - 4, hd.label, U.BG, hc, true) end
    -- вырез шва на ручке (6 окт: «жёсткие»): мельче и тоном ручки, не чёрным
    local tz = math.max(2, math.floor(L.rh / 5))
    set(U.mix(hd.col, U.BG, 0.75))
    for _, ly in ipairs(hd.seams) do gfx.triangle(hd.x, ly - tz, hd.x, ly + tz, hd.x + tz, ly) end
  end
  D.ai_handles = nil
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
    local maxh = math.floor(L.body_h * 0.575)   -- 15 окт: на 15 % выше
    for _, c in ipairs(L.cols) do
      if c.x then
        local pl, pr = info.peaks(c.col)
        local v = math.min(1, math.max(pl or 0, pr or 0))
        if v > 0 then
          local x0, w0 = c.x + 2, math.max(2, math.min(c.w - 4, 3 * L.cw))   -- 8 окт: одной ширины на всех треках (было — треть колонки)
          local segs = c.col.armed and { { 0, 0.6, U.mix(U.RED, U.BG, 0.5) }, { 0.6, 0.85, U.mix(U.RED, U.BG, 0.25) }, { 0.85, 1, U.RED } }   -- 19 окт: взведён — метр записи красной гаммой
            or { { 0, 0.6, U.GREEN }, { 0.6, 0.85, U.AMBER }, { 0.85, 1, U.RED } }
          for _, sg in ipairs(segs) do
            local s0, s1 = math.floor(sg[1] * maxh), math.floor(math.min(v, sg[2]) * maxh)
            if s1 > s0 then gfx.set(sg[3][1], sg[3][2], sg[3][3], 0.45); gfx.rect(x0, math.max(L.body_y, by - s1), w0, s1 - s0, 1) end
          end
        end
      end
    end
    gfx.a = 1
  elseif state.meters and info.peaks then
    local rh = L.rh
    local ncell = math.max(1, math.floor(L.nrows * 0.575))     -- до середины тела (15 окт: на 15 % выше)
    local by = L.body_y + L.nrows * rh
    local cwm = math.max(3, L.cw - 1)
    for _, c in ipairs(L.cols) do
      if c.x and (not c.folded or c.chord) then
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
            if c.col.armed then col = U.mix(U.RED, U.BG, 0.55 * (1 - frac)) end   -- 19 окт: взведён — метр записи: красный, ярче к верху
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
  -- 19 окт: вход MIDI прямо на треке — жёлтый столбик справа от метров L R (и без метров), гаснет за 0.3 с
  if info.midi_in_age then
    local cwm = math.max(3, L.cw - 1)
    local by = L.body_y + L.nrows * L.rh
    local hh = math.floor(L.body_h * 0.575)
    for _, c in ipairs(L.cols) do
      if c.x and (not c.folded or c.chord) and c.col and not c.col.master then
        local age, vel = info.midi_in_age(c.col)
        local DEC = 0.4
        if age and age < DEC then
          -- 19 окт: метр MIDI — высота по velocity, спад за 0.4 с; клетками строк, низ тусклый, верх ярче (как L R)
          local yl = U.YELLOW or U.AMBER
          local x0 = (state.meterstyle == 'pt') and (c.x + 2 + math.max(2, math.min(c.w - 4, 3 * L.cw)) + 2) or (c.x + 2 + 2 * (cwm + 1) + 1)
          local v = math.max(0, math.min(1, (vel or 100) / 127)) * (1 - age / DEC)
          local ncell = math.max(1, math.floor(L.nrows * 0.575))
          local eighths = math.floor(v * ncell * 8 + 0.5)
          local cell = 0
          while eighths > 0 and cell < ncell do
            local part = math.min(8, eighths)
            local frac = (cell + 1) / ncell
            local cc = U.mix(yl, U.BG, 0.55 * (1 - frac))
            local cy1 = by - cell * L.rh - 1
            local h1 = math.max(1, math.floor((L.rh - 2) * part / 8 + 0.5))
            gfx.set(cc[1], cc[2], cc[3], 0.85); gfx.rect(x0, cy1 - h1, cwm, h1, 1)
            eighths = eighths - part; cell = cell + 1
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
    for _, m in ipairs(c.mls or {}) do set(U.DIM); gfx.rect(m.x - 1, L.body_y, 1, L.body_h, 1) end
  end
  -- 21 окт: треки не влезли — уходят под мастер: виньетка у правого края (мастер не рисуется поверх)
  if L.cols_cut or L.hs_cut then
    local ex = D.cols_edge(L)
    if ex then
      local vw = math.min(3 * L.cw, 24)
      local n = math.max(1, vw // 2)
      local y0, y1 = L.header_y, L.body_y + L.body_h
      for k = 1, n do set(U.BG, 0.85 * k / n); gfx.rect(ex - (n - k + 1) * 2, y0, 2, y1 - y0, 1) end
      gfx.a = 1
    end
  end
  -- линейка (2 окт): регионы и маркеры вертикальным текстом вдоль своих строк
  local rx0 = L.ruler_right and (L.win_w - L.rg_w - L.jl_w) or tx0   -- 13 окт: справа — у мастера (без линейки прыжков)
  if L.ruler_right then set(U.LINE); gfx.rect(rx0 + L.jl_w, L.body_y, 1, L.body_h, 1) end
  if L.jl_w > 0 and #rows > 0 then
    local cr = info.vcur and info.vcur.row          -- курсор трекера (cur_row — edit-курсор REAPER)
    -- 10 окт: как верхняя линейка — подложка опцией jump ruler background, 0 у курсора, цифры приглушены
    set(D.jr_bg and U.PANEL or U.BG); gfx.rect(tx0 + 1, L.body_y, L.jl_w - 1, #rows * L.rh, 1)
    for i, r in ipairs(rows) do
      local d = cr and (r.row - cr)
      if d and not r.clip and math.abs(d) < 100 then
        local lab = ('%d'):format(math.floor(math.abs(d) + 0.5))   -- 10 окт: целым (строки приходят дробными — было «5.0»)
        text(tx0 + L.jl_w - 2 - ms(lab), L.body_y + (i - 1) * L.rh + 1, lab, d == 0 and U.AMBER or U.mix(d < 0 and U.CYAN or U.GREY, U.BG, 0.35))
      end
    end
  end
  if L.rg_w > 0 and info.ruler and #rows > 0 then
    local row0, nr = rows[1].row, #rows
    local function ry(row) return L.body_y + (row - row0) * L.rh end
    local bot = L.body_y + nr * L.rh
    local laneR, laneM = rx0 + L.jl_w + 3, rx0 + L.jl_w + 3 + L.th + 6       -- 2 px зазора: разделитель матрицы виден (3 окт); jl_w — линейка прыжков
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
        if y1 - y0 > L.th and state.rgnames ~= false then D.vtext(laneR + 4, y0 + 2, y1 - y0 - 4, rg.name ~= '' and rg.name or ('#' .. tostring(rg.idx)), U.TEXT, bgc, true) end
      end
    end
    local mks = {}
    for _, mk in ipairs(info.ruler.markers) do
      local row = math.floor(mk.row_f + 1e-6)
      if row >= row0 and row < row0 + nr and not D.se_hidden(state, mk) then mks[#mks + 1] = { row = row, mk = mk } end
    end
    table.sort(mks, function(p, q) return p.row < q.row end)
    for k, m in ipairs(mks) do
      local y = ry(m.row)
      local ynext = mks[k + 1] and ry(mks[k + 1].row) or bot
      local c = m.mk.rgb or U.AMBER
      set(c); gfx.rect(laneR, y, L.rg_w - 5, 1, 1); gfx.rect(laneM, y, 2, math.max(2, ynext - y), 1)
      if ynext - y > L.th and state.mknames ~= false then D.vtext(laneM + 3, y + 2, ynext - y - 4, m.mk.name ~= '' and m.mk.name or tostring(m.mk.idx), c, U.BG, true) end
    end
    if mx >= rx0 + L.jl_w and mx < rx0 + L.ruler_w and my >= L.body_y and my < bot then hover.ruler = row0 + math.floor((my - L.body_y) / L.rh) end
  end
  -- полоска цвета региона у номеров шагов (2 окт): тот же цвет, что в
  -- уголке с именем, на линейке и в матрице
  if L.ruler_w > 0 and info.ruler and #rows > 0 and state.rgbar ~= false then
    local row0, nr = rows[1].row, #rows
    local c0 = info.view_clip and info.view_clip[1] or -math.huge
    local c1 = info.view_clip and info.view_clip[2] or math.huge
    for _, rg in ipairs(info.ruler.regions) do
      local a, b = math.max(rg.r0, row0, c0), math.min(rg.r1, row0 + nr, c1)
      if b > a and rg.rgb then
        set(rg.rgb); gfx.rect(tx0 + L.rl, L.body_y + (a - row0) * L.rh, 2, (b - a) * L.rh, 1)
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
      gfx.a = info.punch and 0.30 or 0.16; gfx.rect(tx0 + L.rl + 2, y0, L.label_w - L.rl - 3, y1 - y0, 1)
      gfx.a = 0.05; gfx.rect(tx0 + L.label_w, y0, W - tx0 - L.label_w, y1 - y0, 1)
      gfx.a = 1
      local sx = tx0 + math.max(L.rl, 5) - 3                 -- спина скобки; 18 окт: усы — вправо, «[» (просьба)
      gfx.rect(sx, y0, 2, y1 - y0, 1)
      if info.timesel[1] >= row0 then gfx.rect(sx, y0, 7, 2, 1) end
      if info.timesel[2] <= row0 + nr then gfx.rect(sx, y1 - 2, 7, 2, 1) end
    end
  end
  -- линии справа от номеров шагов нет (3 окт, просьба): колонки треков начинаются со своей линии
  if tx0 > 0 and not L.pn then set(D.SEP); gfx.rect(tx0 - 2, hy, D.SEPW, L.body_y + L.body_h + L.low_h - hy, 1) end
  if L.total_w < W then set(U.LINE); gfx.rect(L.total_w, hy, 1, L.body_y + L.body_h - hy, 1) end

  D.pmark('draw: matrix / performance')
  -- 21 окт: что видно в трекере (строки тела, треки) — матрица подсвечивает эту зону светло-серым
  do
    local V = D.mx_view or { cols = {} }; D.mx_view = V
    local v0, v1
    for _, r in ipairs(rows) do if r.row and not r.clip then if not v0 or r.row < v0 then v0 = r.row end; if not v1 or r.row + 1 > v1 then v1 = r.row + 1 end end end
    for k in pairs(V.cols) do V.cols[k] = nil end
    for _, c in ipairs(L.cols or {}) do if c.ci and not c.master and c.x and (c.w or 0) > 0 then V.cols[c.ci] = true end end
    V.r0, V.r1 = v0, v1
  end
  if L.pn then D.panes_frame(L, snap, state, info, hover, ph)
  elseif MX and L.matrix_w > 0 and not state.mx_hidden and info.perf_draw then
    -- производительность (6 окт): на месте матрицы, пока открыта
    local y0 = L.mx_top or L.header_y
    local y1 = L.mx_bot or (L.body_y + L.body_h + (L.low_h or 0))
    info.perf_draw(L, 0, y0, L.matrix_w - D.SEPW, y1 - y0)
  elseif MX and L.matrix_w > 0 and not state.mx_hidden and not L.pn then
    hover.matrix = MX.draw(L, snap, info.regions or {}, { play_row = ph, sig_at = info.sig_at, cur_ci = info.cur_ci, cur_region = info.cur_region, cur_region_full = info.cur_region_full, pat_num = info.pat_num, loop_cells = info.loop_cells, loop_text = info.loop_text, region_rgb = info.region_rgb, bar_label = info.mx_bar_label, ticks = info.mx_ticks, marks = info.mx_marks, view = D.mx_view,
      env_shown = function(col) local v = state.trackenvs and state.trackenvs[col.guid]; if v == nil then v = state.envs end; return v end })
  end
  -- кнопки на линии раздела матрица | трекер (2 окт): внизу < свернуть / > развернуть,
  -- над ней = — ручка ширины (тянуть, двойной клик — авто)
  if MX and L.matrix_w > 0 and not L.pn then
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

  -- 8 окт: панель вкладок над DSP шириной с трекер — левая граница после
  -- матрицы (её фон шёл до самого края и закрывал линию)
  if (L.top_x0 or 0) > 0 and L.top_h > 0 then set(D.SEP); gfx.rect(L.top_x0 - 2, L.top_y, D.SEPW, L.top_h, 1) end
  D.pmark('draw: browser')
  if L.lside_rect and info.browser_draw then
    -- браузер слева (7 окт): справа — инструменты и слайсы на всю высоту,
    -- слева под матрицей — браузер (вкладка fx — список эффектов)
    local hh = L.hint_h or 0
    local total = gfx.h - L.status_h
    local W = L.side_x
    set(U.PANEL); gfx.rect(W, 0, L.side_w, total, 1)
    L.inst_side_h, L.side_y0, L.inst_knob_w, L.slices_split_rect = total, 0, 0, nil
    local ihl = total - hh
    if L.slices_split and info.slices_draw and ihl > 8 * L.rh then
      local top_h = math.floor(ihl / 2)
      D.draw_instruments(L, info, W, 0, L.side_w, top_h, hover)
      set(D.SEP); gfx.rect(W, top_h, L.side_w, D.SEPW, 1)
      local hs = info.slices_draw(L, W + 3, top_h + 3, L.side_w - 5, ihl - top_h - 4)
      if hs ~= nil then hover.slices = hs end
      L.slices_split_rect = { W, top_h + 1, L.side_w, ihl - top_h - 1 }
    else
      D.draw_instruments(L, info, W, 0, L.side_w, ihl, hover)
    end
    if hh > 0 then D.hint_bar(L, W, total - hh, L.side_w, (info.hint_bars or function() end)('inst'), info.focus == 'inst') end
    local r = L.lside_rect
    set(U.PANEL); gfx.rect(r[1], r[2], r[3], r[4], 1)
    set(D.SEP); gfx.rect(0, r[2] - D.SEPW, r[3], D.SEPW, 1)
    hover.browser = info.browser_draw(L, r[1], r[2], r[3], r[4] - hh)
    if info.browser_fxb then local fh = info.browser_fxb(); if fh then hover.fxb = fh end end
    if hh > 0 then D.hint_bar(L, r[1], r[2] + r[4] - hh, r[3], (info.hint_bars or function() end)(info.browser_page or 'browser'), info.focus == 'browser') end
  elseif L.side_w > 0 and info.browser_draw then
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
    if info.browser_fxb then local fh = info.browser_fxb(); if fh then hover.fxb = fh end end   -- вкладка fx браузера (7 окт)
    if hh > 0 then
      D.hint_bar(L, W, sy0 + ih - hh, L.side_w - gw - 2 * L.pad, (info.hint_bars or function() end)('inst'), info.focus == 'inst')
      D.hint_bar(L, W, sy0 + total - hh, L.side_w, (info.hint_bars or function() end)(info.browser_page or 'browser'), info.focus == 'browser')
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
    if L.matrix_w > 0 and not state.mx_hidden then D.hint_bar(L, 0, (L.lside_split or L.mx_ext) and L.mx_bot or hy2, L.matrix_w - 1, (info.hint_bars or function() end)('matrix'), info.focus == 'matrix') end
    -- под полосой транспорта — подсказки её элементов, каждая под своим (5 окт)
    if not (L.piano_h > 0 and L.tppos == 'tracker' and info.hint_bars and D.strip_hints(L, L.matrix_w, hy2, L.win_w - L.matrix_w, info.focus == 'tracker')) then
      D.hint_bar(L, L.matrix_w, hy2, L.win_w - L.matrix_w, (info.hint_bars or function() end)(info.vmode == 'insert' and 'insert' or 'tracker'), info.focus == 'tracker')
    end
  end
  -- режим справки (?): то же место внизу занимает контекстная справка
  D.pmark('draw: dsp, help, keyboard strip')
  -- DSP (9 окт, панели): место — лист dsp (L.pn_dsp), иначе полоса внизу
  local DX, DY, DH, DR = nil, L.dsp_y, L.dsp_h, L.win_w
  if L.pn then local r = L.pn_dsp; if r then DX, DY, DH, DR = r.x, r.y, r.h, r.x + r.w else DH = 0 end end
  -- 28 окт: кэш и для DSP (транспорт стоит — метры стоят): прямоугольник листа
  D.dpc = D.dpc or {}   -- поле D: в draw.frame предел 200 локальных
  D.dpc.c = (DH > 0) and { x = DX or (L.browser_left and L.matrix_w or 0), y = DY, h = DH } or nil
  if D.dpc.c then D.dpc.c.w = DR - D.dpc.c.x end
  D.dpc.inside = D.dpc.c and mx >= D.dpc.c.x and mx < D.dpc.c.x + D.dpc.c.w and my >= D.dpc.c.y and my < D.dpc.c.y + D.dpc.c.h
  D.dpc.b = nil
  if DH > 0 and info.khelp and info.khelp_draw then
    local dy = DY                                   -- под строкой подсказок тела (или под верхним модулем)
    local lx0 = DX or (L.browser_left and L.matrix_w or 0)        -- браузер слева до самого низа (7 окт)
    local xo = lx0 + (L.ctrl_dsp and (L.ctrl_w + D.SEPW) or 0)     -- главный модуль слева в полосе DSP (3 окт)
    set(U.PANEL); gfx.rect(lx0, dy, DR - lx0, DH, 1)
    set(D.SEP); gfx.rect(lx0, dy, DR - lx0, D.SEPW, 1)
    hover.khelp = info.khelp_draw(L, xo, dy, DR - xo, DH) or true
    L.dsp_rect = { xo, dy, DR - xo, DH }
  elseif DH > 0 and not info.pinmx and D.pc_hit('dsp', D.dpc.c, info, D.dpc.inside, info.focus == 'dsp' or info.focus == 'fxb') then
    -- 28 окт: DSP из кэша (L.dsp_rect — с прошлой отрисовки)
  elseif DH > 0 then
    D.dpc.b = (not info.pinmx) and D.pc_begin('dsp', D.dpc.c) or nil
    local dy = DY                                   -- под строкой подсказок тела (или под верхним модулем)
    local lx0 = DX or (L.browser_left and L.matrix_w or 0)        -- браузер слева до самого низа (7 окт): DSP — правее него
    D.clip = { lx0, DR - 1, DY, DY + DH }                         -- 9 окт: ничего за правый край DSP
    set(U.PANEL); gfx.rect(lx0, dy, DR - lx0, DH, 1)
    set(D.SEP); gfx.rect(lx0, dy, DR - lx0, D.SEPW, 1)
    local col = info.pool_col
    local fxs = info.dsp_fxs or (col and col.fx) or {}
    -- браузер эффектов слева (2 окт): продолжение левой колонки под матрицей
    local fbw = 0
    local xo = lx0 + (L.ctrl_dsp and (L.ctrl_w + D.SEPW) or 0)     -- главный модуль слева в полосе DSP (3 окт)
    if info.fxb_draw and not L.pn then           -- панели: у fx list свой лист
      -- ширина матрицы, пока она открыта; свёрнутая матрица список эффектов не сжимает (2 окт)
      local own = math.min(L.cw * 26, math.floor(DR / 4))
      fbw = (L.matrix_w and L.matrix_w > 0 and not state.mx_hidden) and math.max(L.matrix_w, math.floor(own * 0.6)) or own
      if info.fxb_px then fbw = math.max(L.cw * 12, math.min(math.floor(DR * 0.5), info.fxb_px)) end   -- ширина мышью (3 окт)
      if info.fxb_expand then
        -- фокус на браузере: он раскрывается на всю левую колонку (за счёт
        -- матрицы и главного модуля) в конце кадра, после статуса; здесь — место
        set(U.PANEL); gfx.rect(xo, dy + 2, fbw, DH - 2, 1)
        D.fxb_popup = { w0 = fbw }
      else hover.fxb = info.fxb_draw(L, xo, dy + 2, fbw, DH - 2 - (L.hint_h or 0)) end
      L.fxb_rect = { xo, dy + 2, fbw, DH - 2 }
    else L.fxb_rect = nil end
    fbw = fbw + xo
    -- граница список эффектов | DSP (3 окт: была чёрная щель)
    if fbw > 0 then set(D.SEP); gfx.rect(fbw - 2, dy, D.SEPW, DH, 1) end
    -- шапка: имя трека (цвет как шапка канала), [track fx] [take fx], затем имя цепочки
    do
      local hx = fbw + L.pad
      local tcol = info.dsp_col or info.pool_col
      if tcol then
        local nm = tcol.name ~= '' and tcol.name or 'track'
        local nw = ms(nm) + 2 * L.pad
        local nb = (tcol.rgb and (info.hdrfill or 'line') ~= 'off') and U.mix(D.HDR, tcol.rgb, 0.30) or D.HDR
        if tcol.rgb and (info.hdrfill or 'line') ~= 'off' then rawset_col(nb) else set(nb) end
        gfx.rect(hx, dy + 2, nw, L.rh, 1)
        -- 11 окт: щелчок по имени — блок трека (R I M S, vol, pan, in, out) открыть / закрыть
        local hot = mx >= hx and mx < hx + nw and my >= dy + 2 and my < dy + 2 + L.rh
        if hot or info.dsptrack then set(hot and U.AMBER or U.LINE); gfx.rect(hx, dy + 2, nw, L.rh, 0) end
        text(hx + L.pad, dy + 3, nm, hot and U.AMBER or U.readable(U.TEXT, nb, 4.5))
        if hot then hover.dsptrkname = true end
        hint('dsptrkname', hx, dy + 2, nw, L.rh, true)
        hx = hx + nw + L.pad
      end
      -- 11 окт: шаблоны треков «< имя >»: стрелки листают, щелчок по имени — выпадашка (fzf),
      -- выбор вставляет трек(и) после трека курсора; 21 окт: сразу за именем трека (слева) — справа
      -- над эффектом стоит «< патч >» синта, рядом их путали
      local tr_right = DR - L.pad
      local items = info.presets and info.presets() or {}
      if #items > 0 then
        local PR = D.PR
        PR.cur = math.max(1, math.min(PR.cur or 1, #items))
        local aw = ms('<') + 2 * L.pad
        local nm = items[PR.cur].name
        local nw = math.min(L.cw * 22, math.max(L.cw * 10, ms(nm) + 2 * L.pad))
        local tw = 2 * aw + nw
        local tx = hx
        if tx + tw < DR - L.pad - L.cw * 4 then
          local yb = dy + 2
          for i, part in ipairs({ { '<', -1, tx, aw }, { nm, 0, tx + aw, nw }, { '>', 1, tx + aw + nw, aw } }) do
            local px, pw2 = part[3], part[4]
            local hot = mx >= px and mx < px + pw2 and my >= yb and my < yb + L.rh
            set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(px, yb, pw2, L.rh, 1)
            set(hot and U.AMBER or U.LINE); gfx.rect(px, yb, pw2, L.rh, 0)
            local lbl = i == 2 and fit(part[1], pw2 - 2 * L.pad) or part[1]
            text(px + (i == 2 and L.pad or math.floor((pw2 - ms(lbl)) / 2)), dy + 3, lbl, hot and U.AMBER or (i == 2 and U.TEXT or U.GREY))
            if hot then hover.tmpl = part[2] end
            hint('tmpl', px, yb, pw2, L.rh, part[2])
          end
          hx = tx + tw + L.pad
        end
      end
      -- имя трека уже слева от кнопок; здесь — имя take (цепочка take) и подсказка
      text(hx, dy + 3, fit((info.dsp_is_take and (info.dsp_title or '') or '') .. (#fxs == 0 and '  (no fx: pick one in the fx list, or / )' or ''), tr_right - hx), info.dsp_is_take and U.AMBER or U.GREY)
    end
    local bx = fbw + L.pad
    local lvl = info.pool_col and info.dsp_levels and info.dsp_levels(info.pool_col)
    local mw = math.max(ms('o') + 4, 12)                -- тонкие метры (5 окт)
    -- 15 окт: стандарт размерности DSP — все блоки (вкладки track / take / route, блок трека, FX, заглушки,
    -- роутер) в одной полосе: верх под шапкой, низ над полосой прокрутки цепочки — рамки встают вровень
    local sbh = (D.SBW or 3) + 4
    local boxy, boxh = dy + L.rh + 3, DH - L.rh - 6 - (L.hint_h or 0) - sbh
    D.DSP_BOX = { y = boxy, h = boxh }
    local mby, mbh = boxy, boxh
    -- 11 окт: track fx / take fx / fx routing — колонкой в начале модуля, подписи
    -- вертикально (как имена треков в матрице); шапка остаётся под имя трека
    do
      local vw = L.rh + 2
      local gap = 2
      local bh3 = math.floor((mbh - 2 * gap) / 3)   -- 29 окт: третья — route (мини-роутер под XY); fx routing — > у ROUTE
      if bh3 >= 2 * L.cw then
        local tmr = info.trk_mods and info.pool_col and info.trk_mods(info.pool_col)
        local BT = { { 'track', false, 'track fx' }, { 'take', true, 'take fx' }, { 'route', 'wroute', 'route' } }
        for i, b in ipairs(BT) do
          local by = mby + (i - 1) * (bh3 + gap)
          local hot = mx >= bx and mx < bx + vw and my >= by and my < by + bh3
          local on
          if b[2] == 'wroute' then on = tmr and tmr.wroute or false else on = b[2] ~= nil and (info.dsp_is_take or false) == b[2] end
          local g = on and b[2] == false                 -- track fx включена — зелёная, как FX на канале REAPER
          local bg = g and D.FXG_T or (hot and U.tint(U.AMBER, 0.3) or (on and U.tint(U.AMBER, 0.15) or U.BG))
          local fg = g and D.FXTXT or (on and U.AMBER or (hot and U.AMBER or U.GREY))
          set(bg); gfx.rect(bx, by, vw, bh3, 1)
          set(g and D.FXG or ((on or hot) and U.AMBER or U.LINE)); gfx.rect(bx, by, vw, bh3, 0)
          local tl = math.min(ms(b[3]), bh3 - 4)
          D.vtext(bx + math.floor((vw - TH()) / 2), by + math.floor((bh3 - tl) / 2), tl, b[3], mono(fg), mono(bg))
          if b[2] == 'wroute' then
            if hot then hover.trkmod = { col = info.pool_col, what = 'wroute' } end
            hint('trkmod', bx, by, vw, bh3, { what = 'wroute' })
          else
            if hot then hover.dsptarget = b[1] end
            hint('dsptarget', bx, by, vw, bh3, b[1])
          end
        end
        bx = bx + vw + L.pad
      end
    end
    if lvl then
      D.dsp_meter(L, bx, mby, mw, mbh, '', lvl.inp, 'in', hover)   -- 12 окт: без буквы — и так вход
      bx = bx + mw + L.pad
    end
    -- блок трека — первый слева, закреплён (не перетаскивается с FX)
    D.pmark('dsp: track strip')
    if info.pool_col and info.trk_io and info.dsptrack then
      -- 22 окт: опция slim DSP track header — узкой вертикальной колонкой; по умолчанию — строками (L.cw * 19), под ними XY-пресеты
      local used = info.dsptrackslim and D.track_block_v(L, info, info.pool_col, bx, boxy, boxh, hover, rawset_col)
        or D.track_block(L, info, info.pool_col, bx, boxy, L.cw * 19, boxh, hover, rawset_col)
      if used > 0 then bx = bx + used + L.pad end
    end
    D.aw_status = nil
    local drag = info.dsp_drag                 -- { k = блок } | { new = true } — идёт перетаскивание
    local blocks = {}
    local bw = L.cw * 22
    local sel = info.dsp_sel or {}
    -- 6 окт: блоки, что не влезли, молча пропадали (контейнер в 2 колонки —
    -- первым). Теперь: не влезает — одна колонка; цепочка длиннее панели —
    -- сдвиг так, чтобы выбранный блок был виден; по краям «<N» / «N>» —
    -- сколько блоков за краем (клик — выбрать ближний скрытый)
    -- 12 окт: справа — метр выхода и вертикальная кнопка compensate за ним (у правого края модуля)
    local cvw = L.th + 6
    local right = DR - (lvl and (mw + cvw + 2 * L.pad) or 0)
    local stubw = ms('99>') + 2 * L.pad
    -- 11 окт: под блоками — полоса прокрутки цепочки (вместо кнопок «<N» / «N>»)
    local bh0 = boxh
    -- 24 окт: есть рэки контейнеров — под модулями полоса 7 px под их скобки, полоса прокрутки — ниже неё
    D.rack_band = 0
    for _, f in ipairs(fxs) do if f.inner and (f.inner.lane or f.inner.bi) then D.rack_band = 4; break end end   -- 28 окт: и полосы ÷N   -- 28 окт: только черты веток (скобок под модулями нет)
    bh0 = bh0 - D.rack_band
    local function ncol_of(f)
      -- 19 окт: рэк drumrs5k в низкой панели — параметры пэда расходятся колонками вправо
      if f.kit and D.DR and f.kids then
        local np = 0
        for _, p in ipairs(f.params or {}) do if p.kid == 1 and not p.macro and not (p.gkid and p.gkid >= 2) then np = np + 1 end end
        -- 21 окт: тот же счёт, что в раскладке (rmax, строка слотов + волна WR): было rows - 6 — на строку меньше,
        -- и при 25 параметрах выходила пустая четвёртая колонка справа
        local rows = math.max(2, math.floor((bh0 - L.rh - 2) / L.rh) - 2)
        local avail = math.floor((bh0 - 3 * L.rh) / L.rh)
        local WR = avail >= 14 and 4 or (avail >= 9 and 3 or 0)
        local first = math.max(1, rows - 1 - WR)           -- первая колонка: под слотами и волной
        local extra = np > first and math.ceil((np - first) / rows) or 0
        local kk2 = tostring(info.pool_col and info.pool_col.guid or '') .. ':' .. tostring(f.fguid or f.i)
        local lst = (D.kit_list or {})[kk2] == 'list' and 1 or 0   -- 23 окт: список — вдвое шире сетки (+ колонка)
        -- 23 окт: эффекты выбранного пэда — колонками за параметрами сэмплера (цепочка пэда вправо), до трёх
        local kid0 = f.kids[(D.kit_sel or {})[kk2] or 0]
        local nsl = kid0 and D.pad_chain_view(kid0, kk2 .. ':' .. tostring((D.kit_sel or {})[kk2] or 0)).ncols or 0
        return math.min(5 + lst, 2 + extra + lst) + nsl
      end
      if f.bands and f.kids and #f.kids > 0 then return 1 end   -- 23 окт: ÷N — список полос + кроссовер; эффекты полосы — модулями за ним
      if f.view == 'eq' then return info.eqgraph and 2 or (f.cols or 1) end   -- ReaEQ: график на 2 колонки / только параметры
      if f.auto then
        local rows_fit = math.max(1, math.floor((bh0 - L.rh - 2 - ((f.pages and f.page and (info.dsptabs or 'bottom') ~= 'right') and (L.rh + 1) or 0)) / L.rh))   -- 22 окт: минус строка вкладок
        local _, nc = D.param_flow(f.params, f.heads, rows_fit, 0)   -- 22 окт: с высотой столбиков кнопок и заголовками секций (zP развёрнуто)
        return math.max(1, math.min(f.heads and 5 or 3, nc))
      end
      -- 16 окт: секции потоком (f.heads) — колонок столько, сколько займёт поток при этой высоте
      if f.heads and not f.container then
        local nfit2 = math.max(2, math.floor((bh0 - L.rh - 2 - ((f.pages and f.page and (info.dsptabs or 'bottom') ~= 'right') and (L.rh + 1) or 0)) / L.rh))   -- 22 окт: минус строка вкладок
        local _, nc = D.param_flow(f.params, f.heads, nfit2, 0)   -- 22 окт: тот же поток, что в раскладке
        return nc
      end
      if f.container and f.wrap then return f.xy and 2 or 1 end   -- 24 окт: обёртка — шапка, макросы, XY; дети — модулями следом
      if f.container and f.kids and not f.kit then   -- 23 окт: маленькие дети — столбиком, колонок меньше
        local rows = math.floor((bh0 - L.rh - 2) / L.rh) - 2
        local _, nc = D.kid_pack(f, rows)
        return (f.has_macros and 1 or 0) + nc
      end
      return f.cols or 1
    end
    -- первый видимый блок — D.dsp_first (полоса прокрутки); выбор другого эффекта
    -- подтягивает его в поле зрения, прокрутка мимо выбора его не трогает
    local first = 1   -- 22 окт: прокрутка по пикселям (D.dsp_px) — блоки не пропускаются
    if false then
      D.dsp_sel_last = sel.fx
      if sel.fx and sel.fx >= 1 and sel.fx <= #fxs then
        local est = 1
        local sum = 0
        for k = 1, sel.fx do sum = sum + L.cw * 14 + L.pad end      -- по самой узкой колонке
        while est < sel.fx and bx + sum > right do sum = sum - L.cw * 14 - L.pad; est = est + 1 end
        if sel.fx < first then first = sel.fx elseif est > first then first = est end
      end
    end
    first = math.max(1, math.min(first, math.max(1, #fxs)))
    D.dsp_first = first
    local sb_x0, nshown = bx, 0
    local function stub(x, label, k, at_right)
      local sy = boxy
      local hot = not drag and mx >= x and mx < x + stubw and my >= sy and my < sy + bh0
      set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(x, sy, stubw, bh0, 1)
      set(hot and U.AMBER or U.LINE); gfx.rect(x, sy, stubw, bh0, 0)
      text(x + math.floor((stubw - ms(label)) / 2), sy + math.floor((bh0 - L.rh) / 2), label, hot and U.AMBER or U.GREY)
      if hot then hover.dsp = { fx = k, f = fxs[k] } end
      hint('dsp', x, sy, stubw, L.rh, { fx = k })
    end
    -- роутер (7 окт): в панели DSP FX вместо блоков — схема цепочки (имена и
    -- кабели), прокрутка по горизонтали; метры in / out остаются по краям
    if info.dsp_router and info.draw_router then
      local hv = info.draw_router(bx, boxy, right - bx - L.pad, bh0)
      for k2, v2 in pairs(hv or {}) do hover[k2] = v2 end
      bx = right
      goto dsp_router_done
    end
    -- 22 окт: прокрутка цепочки — плавно, по пикселям (не по блоку): блоки во всю свою ширину рисуются в
    -- буфер 700 со сдвигом D.dsp_px, на экран — только окно цепочки [cx0, cx1); мышь вне окна — не над блоками
    do   -- 22 окт: свои локальные — goto роутера не прыгает в их область
    local cx0, cx1 = bx, right
    D.dsp_px = D.dsp_px or 0
    if D.dsp_px_t then
      D.dsp_px = D.dsp_px + (D.dsp_px_t - D.dsp_px) * 0.35
      if math.abs(D.dsp_px_t - D.dsp_px) < 0.5 then D.dsp_px, D.dsp_px_t = D.dsp_px_t, nil end
    end
    if D.dsp_maxpx then D.dsp_px = math.max(0, math.min(D.dsp_maxpx, D.dsp_px)) end   -- 24 окт: до рисования, не после
    local px = math.floor(D.dsp_px + 0.5)
    local dest0, mx0 = gfx.dest, mx
    if D.dsp_bufw ~= gfx.w or D.dsp_bufh ~= gfx.h then gfx.setimgdim(700, gfx.w, gfx.h); D.dsp_bufw, D.dsp_bufh = gfx.w, gfx.h end
    gfx.dest = 700
    D.rack_ext = D.rack_band or 0   -- 24 окт: под блоками — черты веток; 28 окт: и в zz (ряды через L.pad — черта в зазоре)
    gfx.blit(dest0, 1, 0, cx0, boxy - 4, cx1 - cx0, bh0 + 6 + D.rack_ext, cx0, boxy - 4, cx1 - cx0, bh0 + 6 + D.rack_ext)   -- фон под блоками (24 окт: и 3 px над — рамка рэка)
    if mx < cx0 or mx >= cx1 then mx = -100000 end
    -- 23 окт: DSP развёрнут (zz) и высоко — модули рядами, как строки: слева направо, следующий ряд снова слева
    -- (сигнал идёт по рядам); рядов — сколько влезает модулей в высоту ≥ 16 строк, до трёх; прокрутки нет
    local boxy0, bh00 = boxy, bh0
    local wrap = info.dsp_wide and math.min(3, math.floor((bh0 + L.pad) / (16 * L.rh + L.pad))) or 1
    if wrap > 1 then bh0 = math.floor((bh00 - (wrap - 1) * L.pad) / wrap); px = 0; D.dsp_px, D.dsp_px_t = 0, nil end
    local wrow = 1
    local function wrap_next(w2)
      if wrap > 1 and bx + w2 > cx1 and bx > cx0 + 1 and wrow < wrap then
        wrow = wrow + 1; bx = cx0; boxy = boxy0 + (wrow - 1) * (bh0 + L.pad)
        return true
      end
    end
    bx = cx0 - px
    -- подсказки и группы CONTROL — только у того, что в окне (спрятанное за краем мышь не находит)
    local hint0, nslr0 = D.hint, D.slr and #D.slr or 0
    if hint0 then D.hint = function(kind, x, y, w, h, data) if x + w > cx0 and x < cx1 then hint0(kind, x, y, w, h, data) end end end
    D.dsp_vx = {}                                -- место блока в цепочке (от её начала) — подтянуть выбранный
    D.cst, D.info = {}, info
    D.rack_plus = {}
    D.fxgui_rect = {}   -- 27 окт: блоки с окном плагина поверх (gui) — заново каждый кадр
    D.dsp_sel_rect = nil
    D.sel_i = fxs[sel.fx or 0] and fxs[sel.fx or 0].i or nil   -- 24 окт: выбранный модуль — подложкой в списке цепей
    D.dsp_selk = sel.fx   -- 28 окт: мини-роутер — выбранный узел
    D.pmark('dsp: layout')
    D.stk = nil   -- 31 окт: колонка маленьких модулей (сверху вниз)
    for k, f in ipairs(fxs) do
      bx = D.rack_open(L, f, k, bx, boxy, bh0)
      do
      -- 22 окт: модуль сложен (zf / zF) — узкая полоса во всю высоту: кнопки x B сверху, имя вертикально (щелчок — развернуть)
      if info.dsp_mfold and info.dsp_mfold[tostring(f.fguid or f.i)] then
        local kb = ms('O') + 2 * L.pad
        local onw = ms('off') + 2 * L.pad   -- 24 окт: on / off вместо B
        local fw = math.max(onw, L.th + 2 * L.pad) + 2
        wrap_next(fw)
        D.dsp_vx[k] = { bx + px - cx0, fw }
        if bx + fw <= cx0 or bx >= cx1 then bx = bx + fw + L.pad; goto next_block end   -- вне окна — только место
        nshown = nshown + 1
        local is_sel = sel.fx == k
        blocks[#blocks + 1] = { x = bx, w = fw, y = boxy, h = bh0, k = k, cont = f.container, bands = f.bands, inner = f.inner }
        local picked = (info.dsp_range and k >= info.dsp_range[1] and k <= info.dsp_range[2]) or (info.dsp_marks and info.dsp_marks[k])
        set(picked and U.tint(U.CYAN, 0.22) or U.BG); gfx.rect(bx, boxy, fw, bh0, 1)
        set(f.enabled and (is_sel and U.AMBER or U.LINE) or U.DIM); gfx.rect(bx, boxy, fw, bh0, 0)
        local yy, on_btn = boxy + 1, false
        -- 28 окт: сложенный — заголовок: те же кнопки, что в шапке (x, on, ∆ дельта, e окно), столбиком; имя ниже
        local sdl = info.fx_delta and info.fx_delta(f)
        local sbt = { { 'x', 'del' }, { f.enabled and 'on' or 'off', 'bypass', onw } }
        if bh0 > 7 * L.rh then sbt[3] = { '∆', 'delta' }; sbt[4] = { 'e', 'open' } end
        for _, b in ipairs(sbt) do
          local kb = b[3] or kb
          local kx = bx + math.floor((fw - kb) / 2)
          local hot = not drag and mx >= kx and mx < kx + kb and my >= yy and my < yy + L.rh - 1
          local lit = (b[2] == 'bypass' and not f.enabled) or (b[2] == 'delta' and sdl)
          local hc = b[2] == 'del' and U.RED or U.AMBER
          set(hot and U.tint(hc, 0.35) or (lit and U.tint(U.AMBER, 0.25) or U.BG)); gfx.rect(kx, yy, kb, L.rh - 1, 1)
          set(hot and hc or (lit and U.AMBER or U.LINE)); gfx.rect(kx, yy, kb, L.rh - 1, 0)
          text(kx + L.pad, yy, b[1], hot and hc or (lit and U.AMBER or U.TEXT))
          if hot then hover.dspbtn = { fx = k, f = f, what = b[2] }; on_btn = true end
          hint('dspbtn', kx, yy, kb, L.rh - 1, { fx = k, what = b[2] })
          yy = yy + L.rh
        end
        local nh = boxy + bh0 - yy - 2
        local hot = not drag and not on_btn and mx >= bx and mx < bx + fw and my >= yy and my < boxy + bh0
        if nh > L.cw then
          D.vtext(bx + math.floor((fw - L.th) / 2), yy + 1, nh, (f.enabled and '' or '(off) ') .. (f.name or ''),
            (hot or is_sel) and U.AMBER or (f.enabled and U.TEXT or U.GREY), U.BG)
        end
        if hot then hover.dspbtn = { fx = k, f = f, what = 'mfold' } end
        hint('dspbtn', bx, yy, fw, math.max(1, nh), { fx = k, what = 'mfold' })
        bx = bx + fw + L.pad
        goto next_block
      end
      local ncol = ncol_of(f)
      -- ширина колонки: 22 знака; тесно — оставшиеся блоки делят место
      -- поровну, но не уже 14 знаков (имя и значения режет fit)
      local bw1 = L.cw * (f.colw or 22)   -- 13 окт: модуль может просить колонку шире; 22 окт: всегда своя ширина (целиком, прокрутка плавная)
      -- 19 окт: рэк drumrs5k не свёрнут (zf) — колонки вдвое шире: пэды 4 × 4 крупно (m > s, волна, подписи, группа)
      -- 19 окт: размер пэдов рэка zs + s / m / l: l — колонки вдвое шире, m — в 1.5 раза меньше l, s — мелкие (прежний вид)
      if f.kit and D.DR and info.kitsize ~= 's' then
        local k2 = info.kitsize == 'm' and (4 / 3) or 2
        local b2 = math.floor(bw1 * k2)
        if 2 * b2 <= cx1 - cx0 then bw1 = b2 end
      end
      local by = boxy
      local bh = bh0
      bx, by, bh = D.stack_place(L, info, f, ncol, bx, boxy, bh0)   -- 31 окт: маленькие — колонкой, стрелка v
      -- автомодуль (4 окт): колонок столько, сколько параметров влезает по
      -- строкам (≤ 3) — без пустой колонки справа; места больше — больше параметров
      local room = math.huge   -- 22 окт: модуль целиком, не поджимается к краю (прокрутка плавная)
      -- 22 окт: колонка MACRO и вкладки справа — тоже место: считать их до подгонки колонок (иначе Surge
      -- «не влезал» целиком и пропадал, хотя справа было пусто); один столбец не влез — столбец уже, до 10 знаков
      local tabpos0 = info.dsptabs or 'bottom'
      local vtw0 = (f.pages and f.page and tabpos0 == 'right') and (L.th + 2 * L.pad + 2) or 0
      local mw0 = D.mac_w(L, info, f)
      local extra = vtw0 + mw0
      if ncol > 1 and bx + bw1 * ncol + extra > room and bx + bw1 + extra <= room then ncol = math.max(1, math.floor((room - bx - extra) / bw1)) end   -- 13 окт: сколько влезает (было — сразу одна)
      if ncol == 1 and bx + bw1 + extra > room and room - bx - extra - L.pad >= L.cw * 10 then bw1 = room - bx - extra - L.pad end
      local bw = bw1 * ncol
      -- 26 окт: пульт slixer — во всю ширину DSP: кнопки в меньше рядов, волне и прицелу больше высоты
      -- 27 окт: не во всю ширину, а по самому длинному ряду кнопок (просьба: «широковато, поуже»)
      D.pmark('dsp: slx head')
      if f.view == 'slixer' and D.SX and not f.container then
        local v0 = info.dsp_view and info.dsp_view('slixer', f.i)
        D.pmark('dsp: slx items')
        local rows, low = D.SX.items(v0, function(name) return info.slx_param and info.slx_param(f.i, name) end)
        D.pmark('dsp: slx natw')
        local nat = math.max(D.SX.natural_w(rows, ms, L.pad), D.SX.natural_w({ (function() local fl = {}; for _, r in ipairs(low or {}) do for _, it in ipairs(r) do fl[#fl + 1] = it end end; return fl end)() }, ms, L.pad)) + 2 * L.pad + 2
        -- 31 окт: ширина модуля только растёт за сессию — значение в кнопке не двигает соседей и волну
        D.slx_natw = D.slx_natw or {}
        local nk = tostring(f.fguid or f.i)
        nat = math.max(nat, D.slx_natw[nk] or 0); D.slx_natw[nk] = nat
        bw = math.max(bw, math.min(cx1 - cx0 - 2 * L.pad, nat))
      end
      -- 19 окт: рэк drumrs5k на всё окно в виде list — модуль во всю ширину DSP (таблица пэдов не вылезает за рамку)
      if f.kit and D.DR then
        local kk = tostring(info.pool_col and info.pool_col.guid or '') .. ':' .. tostring(f.fguid or f.i)
        local _ = kk   -- 23 окт: список — на месте сетки (шириной с неё), модуль не растягивается во всю ширину
      end
      -- 16 окт (вечер): свёрнутый модуль со страницами (zf) — справа колонка вертикальных вкладок
      -- 22 окт: вкладки страниц — опция dsptabs: bottom (строкой снизу) / top (строкой под шапкой) / right (колонкой справа)
      local tabpos = info.dsptabs or 'bottom'
      local htab = (f.pages and f.page and tabpos ~= 'right') and L.rh or 0
      local vtw = (f.pages and f.page and tabpos == 'right') and (L.th + 2 * L.pad + 2) or 0
      bw = bw + vtw
      -- 22 окт: макросы (Macro 1..8) — колонка MACRO слева в модуле: горизонтальные слайдеры; щелчок по заголовку —
      -- свернуть в узкую полосу с вертикальной подписью (info.macfold по имени плагина)
      -- 24 окт: слева — колонка вертикальных вкладок macro / xy, каждая раскрывает свою панель справа от себя
      D.pmark('dsp: macw')
      local mw, vt, mpw, xpw = D.mac_w(L, info, f)
      D.pmark('dsp: frame0')
      local macfold = mpw == 0
      bw = bw + mw
      if wrap_next(bw) then by = boxy end   -- 23 окт: следующий ряд
      D.dsp_vx[k] = { bx + px - cx0, bw }
      if bx + bw <= cx0 or bx >= cx1 then bx = bx + bw + L.pad; goto next_block end   -- вне окна — только место (полоса прокрутки)
      nshown = nshown + 1
      local is_sel = sel.fx == k
      blocks[#blocks + 1] = { x = bx, w = bw, y = by, h = bh, k = k, cont = f.container, bands = f.bands, inner = f.inner }
      if is_sel and not D.dsp_sel_rect then D.dsp_sel_rect = { x = bx + L.pad, y = by, w = bw, h = L.rh, mod = true } end   -- без параметра — под шапкой модуля
      local in_rng = (info.dsp_range and k >= info.dsp_range[1] and k <= info.dsp_range[2]) or (info.dsp_marks and info.dsp_marks[k])
      -- 27 окт: rounded racks — и модули со скруглёнными углами; край модуля — 2 px и контрастнее линий внутри (иерархия границ)
      -- 27 окт: D.mod_box без локали (у этой функции предел 200 локалей в Lua 5.4 — проверка tools/maxlocals.py / luac5.4)
      set(in_rng and U.tint(U.CYAN, 0.22) or U.BG); D.mod_box(bx, by, bw, bh, true)   -- 19 окт: выбранный — рамкой и заголовком, без заливки (она гасила цвета внутри)
      local ins_here = is_sel and info.dsp_ins   -- 22 окт: INSERT параметра — рамка модуля красная, двойная
      -- 24 окт: выбранный — янтарь в 2 px, остальные — рамка тише (выбранный модуль терялся среди рамок рэка)
      set(ins_here and U.RED or ((info.dsp_learn == k) and U.CYAN or ((f.enabled and not f.poff) and (is_sel and U.AMBER or U.mix(U.LINE, U.TEXT, 0.35)) or U.DIM))); D.mod_box(bx, by, bw, bh, false)
      -- 27 окт: второй пиксель рамки — снаружи (в зазоре между модулями): внутри он ложился под кнопки шапки
      if is_sel and not ins_here then set(U.AMBER); D.mod_box(bx - 1, by - 1, bw + 2, bh + 2, false)
      elseif f.enabled and not f.poff and info.dsp_learn ~= k and not ins_here then D.mod_box(bx - 1, by - 1, bw + 2, bh + 2, false) end   -- 2 px и у остальных
      if info.dsp_learn == k or ins_here then D.mod_box(bx - 1, by - 1, bw + 2, bh + 2, false) end     -- learn: двойная голубая рамка
      if vtw > 0 then
        local tx0, ty = bx + bw - vtw, by + L.rh + 2
        set(U.LINE); gfx.rect(tx0, by + L.rh + 1, 1, bh - L.rh - 3, 1)
        for pi2, pn in ipairs(f.pages) do
          local th2 = ms(pn) + 2 * L.pad
          if ty + th2 > by + bh - 2 then break end
          local on = pi2 == f.page
          local hot = not drag and mx >= tx0 and mx < bx + bw - 1 and my >= ty and my < ty + th2
          set(on and U.tint(U.AMBER, 0.3) or (hot and U.tint(U.AMBER, 0.15) or U.BG)); gfx.rect(tx0 + 1, ty, vtw - 3, th2 - 1, 1)
          D.vtext(tx0 + L.pad, ty, th2, pn, on and U.AMBER or (hot and U.TEXT or U.GREY), on and U.tint(U.AMBER, 0.3) or (hot and U.tint(U.AMBER, 0.15) or U.BG))
          if hot then hover.dspbtn = { fx = k, f = f, what = 'kpage', page = pi2 } end
          ty = ty + th2 + 1
        end
      end
      local tab_top = 0
      if htab > 0 then
        local tx, ty = bx + 1, by + bh - htab - 1
        if tabpos == 'top' then ty = by + L.rh + 1; tab_top = htab + 1 end
        set(U.LINE); gfx.rect(bx + 1, tabpos == 'top' and (ty + htab) or (ty - 1), bw - 2, 1, 1)
        for pi2, pn in ipairs(f.pages) do
          local tw2 = ms(pn) + 2 * L.pad
          if tx + tw2 > bx + bw - 1 then break end
          local on = pi2 == f.page
          local hot = not drag and mx >= tx and mx < tx + tw2 and my >= ty and my < ty + htab
          set(on and U.tint(U.AMBER, 0.3) or (hot and U.tint(U.AMBER, 0.15) or U.BG)); gfx.rect(tx, ty, tw2 - 1, htab, 1)
          text(tx + L.pad, ty, pn, on and U.AMBER or (hot and U.TEXT or U.GREY))
          if hot then hover.dspbtn = { fx = k, f = f, what = 'kpage', page = pi2 } end
          tx = tx + tw2
        end
        bh = bh - htab - 1
      end
      -- кнопки блока (2 окт): O — окно, B — bypass, x в правом углу — удалить
      local kb = ms('O') + 2 * L.pad
      -- Δ (4 окт; буква, не значок — философия: только буквы алфавитов) — delta solo REAPER (:delta): слышна разница вход − выход эффекта
      -- 11 окт: + — меню последнего тронутого параметра этого эффекта (как кнопка Param в REAPER)
      -- 24 окт: B → on / off (понятнее; ширина — по «off», кнопка не прыгает)
      -- 31 окт: on / off — не кнопкой справа, а кружком перед именем (яркий — включён, тёмный — выключен); onw = −3 убирает её место
      local onw = -3
      local bxs = { { 'x', 'del', bx + bw - kb - 1 }, { '_', 'mfoldin', bx + bw - 2 * kb - onw - 7 }, { '∆', 'delta', bx + bw - 3 * kb - onw - 8 },
                    { 'e', 'open', bx + bw - 4 * kb - onw - 11 }, { '+', 'lastp', bx + bw - 5 * kb - onw - 14 } }   -- 31 окт: _ — сложить (zf), сразу слева от x
      local dlt = info.fx_delta and info.fx_delta(f)
      local tw = bw - 2 * L.pad - 5 * kb - onw - 15
      -- узкий блок (6 окт): имени меньше 8 знаков — остаются B и x, O и Δ — клавишами
      if tw < L.cw * 8 then bxs = { bxs[1] }; tw = bw - 2 * L.pad - kb - 2 end
      -- ReaEQ (7 окт): P — только параметры, G — только график
      if f.view == 'eq' and tw > L.cw * 8 + kb then
        bxs[#bxs + 1] = { info.eqgraph and 'P' or 'G', 'vmode', bxs[#bxs][3] - kb - 2 }
        tw = tw - kb - 2
      end
      -- 23 окт: ÷ — эффект в полосы (3 / 4 / 5 band, нативные сплиттер + джойнер REAPER), только верхний уровень
      if not f.container and not f.kids and not f.inner and tw > L.cw * 10 + kb then
        bxs[#bxs + 1] = { '÷', 'bands', bxs[#bxs][3] - kb - 2 }
        tw = tw - kb - 2
      end
      -- 27 окт: gui — родное окно плагина поверх этого блока (ездит с ним; блок ушёл с экрана — окно закрыто)
      if not f.container and tw > L.cw * 10 + ms('gui') + 2 * L.pad then
        local gw = ms('gui') + 2 * L.pad
        bxs[#bxs + 1] = { 'gui', 'gui', bxs[#bxs][3] - gw - 2, gw }
        tw = tw - gw - 2
      end
      if D.fxgui and next(D.fxgui) and not f.fguid and info.fx_guid then f.fguid = info.fx_guid(f) end   -- 27 окт: обычный эффект — GUID для окна
      local gui_on = D.fxgui and f.fguid and D.fxgui[f.fguid]
      if gui_on then
        D.fxgui_rect = D.fxgui_rect or {}
        D.fxgui_rect[f.fguid] = { x = bx + 1, y = by + L.rh + 1, w = bw - 2, h = bh - L.rh - 2, fi = f.fx or f.i, vis = bx >= cx0 and bx + bw <= cx1 }
      end
      -- 24 окт: [] — пустой контейнер внутрь этого (вложенность любая)
      if f.container and not f.kit and not f.bands and not f.inner and #bxs > 1 and tw > L.cw * 8 + kb then
        local cwb = ms('[]') + 2 * L.pad
        bxs[#bxs + 1] = { '[]', 'cnew', bxs[#bxs][3] - cwb - 2, cwb }
        tw = tw - cwb - 2
      end
      -- 31 окт: slixer — кнопки шапки (gui f + e ∆ x) строкой ниже, в правом краю ряда кнопок пульта: в шапке только
      -- кружок, имя, in / out, пресет и слоты (шапка читалась плохо); пульт под них уже на f.slx_hdrw
      f.slx_bry = by   -- поле, не local: лимит 200 локалей функции
      f.slx_hdrw = nil
      -- 31 окт (вечер): назад — кнопки шапки снова в шапке, вниз (в ряд пульта под detect) ушли слоты быстрой загрузки

      -- пресет (4 окт): «< имя >» справа от имени эффекта; клик по имени —
      -- список, < > — предыдущий / следующий
      local pre = info.fx_preset and not f.container and info.fx_preset(f)
      local ptw = 0
      local on_btn = false
      local pre_at   -- 24 окт: кнопки слева (опция dspleft) — пресет рисуется после них
      if pre and tw > L.cw * 14 then
        ptw = math.min(math.floor(tw * 0.6), ms('<>' .. pre.name) + 3 * L.pad)   -- 31 окт: стрелки < > вместе перед именем — не прыгают, пустоты нет
        pre_at = function(px)
        local aw = ms('<') + 2
        local parts = { { '<', 'pprev', px, aw }, { '>', 'pnext', px + aw, aw }, { pre.name, 'preset', px + 2 * aw + 2, ptw - 2 * aw - 2 } }
        for _, pp in ipairs(parts) do
          local hot = not drag and mx >= pp[3] and mx < pp[3] + pp[4] and my >= by + 1 and my < by + L.rh
          if hot then set(U.tint(U.AMBER, 0.3)); gfx.rect(pp[3], by + 1, pp[4], L.rh - 1, 1); hover.dspbtn = { fx = k, f = f, what = pp[2] }; on_btn = true end
          hint('dspbtn', pp[3], by + 1, pp[4], L.rh - 1, { fx = k, what = pp[2] })
          text(pp[3] + (pp[2] == 'preset' and 2 or 1), by + 1, fit(pp[1], pp[4] - 2), hot and U.AMBER or (pp[2] == 'preset' and (pre.none and U.GREY or U.CYAN) or U.GREY))
        end
        end
        if not info.dspleft then pre_at(bx + L.pad + tw - ptw) end
        tw = tw - ptw - L.pad
      end
      -- 23 окт: модуль полосы ÷N (за контейнером) — «полоса > имя», рамка цветом контейнера
      local inp = f.inner and (f.inner.wrap and (string.rep('.', (f.inner.depth or 1) - 1) .. ((f.inner.par or 0) > 0 and '= ' or '| ')) or ((f.inner.band or '') .. ' > ')) or ''   -- 24 окт: в обёртке — | / = (последовательно / параллельно)
      -- 24 окт: справа от имени — кнопка входов / выходов «2 in 2/6 out» (как у REAPER): щелчок — матрица пинов
      local iol = (not f.container or f.wrap) and info.fx_io and info.fx_io(f) or nil   -- 24 окт: и у контейнера-рэка (пины его выхода)
      local iow = iol and (ms(iol) + 2 * L.pad) or 0
      -- 24 окт: число эффектов — без jf_tracker_macro (ручки макросов — не эффект: «2 fx» при одном Surge)
      local nfx = 0
      if f.container then for _, kd in ipairs(f.kids or {}) do if not (kd.name or ''):find('jf_tracker_macro', 1, true) then nfx = nfx + 1 end end end
      local full = '   ' .. inp .. (f.container and ('[' .. f.name .. '] ' .. nfx .. ' fx') or f.name)   -- 31 окт: три знака — место кружка on / off (не на рамке)
      if iol and tw < ms(full) + iow + L.pad + L.cw * 6 then iol, iow = nil, 0 end   -- тесно — имя важнее
      local nmtxt = fit(full, tw - (iol and (iow + L.pad) or 0))
      text(bx + L.pad, by + 1, nmtxt, (f.enabled and not f.poff) and (f.container and U.AMBER or U.TEXT) or U.GREY)
      do   -- 31 окт: кружок on / off перед именем: состояние САМОГО модуля — ярко-зелёный вкл, тёмный выкл; щелчок — переключить
        local on = f.enabled
        local cr = math.max(3, math.floor(L.rh / 3))
        local ccx, ccy = bx + L.pad + cr + 3, by + 1 + math.floor((L.rh - 1) / 2)
        local hot = not drag and math.abs(mx - ccx) <= cr + 3 and my >= by + 1 and my < by + L.rh
        set(on and U.GREEN or U.LINE); gfx.circle(ccx, ccy, cr, 1, 1)
        if hot then set(U.AMBER); gfx.circle(ccx, ccy, cr + 1, 0, 1) end   -- наведение — обводка, цвет состояния не меняется
        if hot then hover.dspbtn = { fx = k, f = f, what = 'bypass' }; on_btn = true end
        hint('dspbtn', ccx - cr - 2, by + 1, 2 * cr + 4, L.rh - 1, { fx = k, what = 'bypass' })
      end
      if info.gr_fx then D.gr_tag(L, bx + L.pad + ms(nmtxt) + L.pad + (iol and (iow + L.pad) or 0), by, info.gr_fx(f)) end   -- 27 окт: подавление этого эффекта
      if iol then
        local ix0 = bx + L.pad + ms(nmtxt .. '.') - ms('.') + L.pad
        local ihot = not drag and mx >= ix0 and mx < ix0 + iow and my >= by + 1 and my < by + L.rh
        set(ihot and U.tint(U.AMBER, 0.35) or U.BG); gfx.rect(ix0, by + 1, iow, L.rh - 1, 1)
        set(ihot and U.AMBER or U.LINE); gfx.rect(ix0, by + 1, iow, L.rh - 1, 0)
        text(ix0 + L.pad, by + 1, iol, ihot and U.AMBER or U.GREY)
        D.io_btn = D.io_btn or {}; D.io_btn[k] = { x = ix0, y = by + L.rh }   -- 24 окт: матрица пинов — под кнопкой
        if ihot then hover.dspbtn = { fx = k, f = f, what = 'pins' }; on_btn = true end
        hint('dspbtn', ix0, by + 1, iow, L.rh - 1, { fx = k, what = 'pins' })
      end
      -- 24 окт: опция dspleft — кнопки и пресет сразу за именем (у большого модуля не тянуться в правый край)
      -- 24 окт (вечер): кнопки — снова в правом краю (просьба), у имени — только пресет «< имя >»
      if info.dspleft and tw > 0 then
        local x = bx + L.pad + ms(nmtxt .. '.') - ms('.') + L.pad + (iol and (iow + L.pad) or 0)
        if pre_at then pre_at(x) end
      end
      -- 27 окт: slixer — 8 слотов быстрой загрузки плитками в свободном месте шапки: мини-волна, имя поверх;
      -- щелчок — загрузить (заказ 10), пустой — номер тускло
      D.pmark('dsp: slx slots')
      -- 31 окт: слоты — в пульте, в свободном конце ряда под detect (D.slx_slots после кнопок пульта)
      if f.inner and not f.inner.wrap then set(U.tint(U.AMBER, 0.55)); gfx.rect(bx + 1, by + 1, bw - 2, bh - 2, 0) end   -- 24 окт: в рэке — без второй рамки (слипалась)
      if tw > 0 then
        for _, b in ipairs(bxs) do
          local kx = b[3] - 1   -- 27 окт: на пиксель внутрь — не ложиться на рамку модуля (2 px)
          local kb = b[4] or kb   -- 24 окт: [] шире буквы
          local hot = not drag and mx >= kx and mx < kx + kb and my >= f.slx_bry + 2 and my < f.slx_bry + L.rh
          local lit = (b[2] == 'bypass' and not f.enabled) or (b[2] == 'delta' and dlt) or (b[2] == 'gui' and gui_on)
          -- 11 окт: включённая дельта мигает (слышна только разница — легко забыть)
          -- 20 окт: мигает ярко — сплошной янтарь и тёмная буква / обычный «горит» (было: тусклая подложка гасла — не видно)
          local flash = b[2] == 'delta' and dlt and reaper and reaper.time_precise and math.floor(reaper.time_precise() * 2) % 2 == 0
          set(hot and U.tint(b[2] == 'del' and U.RED or U.AMBER, 0.35) or (flash and U.AMBER or (lit and U.tint(U.AMBER, 0.25) or U.BG))); gfx.rect(kx, f.slx_bry + 2, kb, L.rh - 2, 1)
          set(hot and (b[2] == 'del' and U.RED or U.AMBER) or ((lit or flash) and U.AMBER or U.LINE)); gfx.rect(kx, f.slx_bry + 2, kb, L.rh - 2, 0)
          local bc = hot and (b[2] == 'del' and U.RED or U.AMBER) or (flash and U.BG or (lit and U.AMBER or U.TEXT))
          if b[2] == 'delta' then
            -- 11 окт: дельта — буквой ∆, но шрифтом Menlo: в ProFont и Δ, и ∆ нарисованы «домиком»; слот 5 — только её (20 окт: kcast 8, тема 9)
            local th = math.max(8, math.min(L.rh + 2, math.floor(TH() * 1.45)))   -- 20 окт: крупнее (∆ Menlo мелкий — не видно)
            if D.menlo_th ~= th then gfx.setfont(5, 'Menlo', th); D.menlo_th = th else gfx.setfont(5) end   -- шрифт с именем — один раз на размер
            local gw2 = gfx.measurestr('∆')
            set(bc); gfx.x = kx + math.floor((kb - gw2) / 2); gfx.y = f.slx_bry + 3 + math.floor((L.rh - 1 - gfx.texth) / 2)   -- 31 окт: ∆ на 2 px ниже
            gfx.drawstr('∆')
            gfx.setfont(D.font_id or 1)
          else text(kx + L.pad, f.slx_bry + 1 - (b[1] == '_' and 3 or (b[1] == 'e' and 2 or 0)), b[1], bc) end   -- 31 окт: e тоже чуть выше   -- 31 окт: _ чуть выше
          if hot then hover.dspbtn = { fx = k, f = f, what = b[2] }; on_btn = true end
          hint('dspbtn', kx, f.slx_bry + 2, kb, L.rh - 2, { fx = k, what = b[2] })   -- 11 окт: кнопки шапки эффекта — по f
        end
      end
      if not drag and not on_btn and mx >= bx and mx < bx + bw and my >= by and my < by + L.rh then hover.dsp = { fx = k, f = f } end
      hint('dsp', bx, by, bw, L.rh, { fx = k })
      local vals = info.fx_values and info.fx_values(f) or {}
      if mw > 0 then
        local hy = by + L.rh + 2
        -- вкладки: верхняя половина — macro N, нижняя — xy; раскрытая — янтарём на подложке
        local th2 = math.floor((bh - L.rh - 4) / 2)
        local fopen = f.wrap and not (info.macfold and info.macfold[f.fxname or f.name])
        local xopen = xpw > 0
        if f.wrap then
          xopen = info.xyopen and info.xyopen[f.fxname or f.name]
          if xopen == nil then xopen = true end
          xopen = xopen and f.nmacro >= 2
          -- 24 окт: контейнер — заголовки отделов строкой: MACRO N | XY (щелчок — сложить / раскрыть)
          for _, tb in ipairs({ { '★', 'macfold', fopen, bx, mpw }, { 'XY', 'xyfold', xopen, bx + mpw, xpw } }) do
            if tb[5] > 0 then
              local tx, tw2 = tb[4] + L.pad, tb[5] - 2 * L.pad
              local hot = not drag and mx >= tb[4] and mx < tb[4] + tb[5] and my >= hy and my < hy + L.rh
              set(U.LINE); gfx.rect(tx, hy + L.rh - 2, tw2, 1, 1)
              text(tx, hy, fit(tb[1], tw2), hot and U.TEXT or (tb[3] and U.AMBER or U.GREY))
              if hot then hover.dspbtn = { fx = k, f = f, what = tb[2] } end
              hint('dspbtn', tb[4], hy, tb[5], L.rh, { fx = k, what = tb[2] })
            end
          end
          macfold = not fopen
        end
        for ti, tb in ipairs(f.wrap and {} or { { 'macro ' .. f.nmacro, 'macfold', mpw > 0 }, { 'xy', 'xyfold', xpw > 0 } }) do
          local ty = hy + (ti - 1) * th2
          local hot = not drag and mx >= bx and mx < bx + vt and my >= ty and my < ty + th2
          local fill = tb[3] and U.tint(U.AMBER, 0.22) or (hot and U.tint(U.AMBER, 0.12) or U.BG)
          set(fill); gfx.rect(bx + 1, ty, vt - 2, th2 - 1, 1)
          set(tb[3] and U.AMBER or U.LINE); gfx.rect(bx + 1, ty, vt - 2, th2 - 1, 0)
          D.vtext(bx + math.floor((vt - L.th) / 2), ty + 2, th2 - 6, tb[1], (hot or tb[3]) and U.AMBER or U.GREY, fill, true)
          if hot then hover.dspbtn = { fx = k, f = f, what = tb[2] } end
          hint('dspbtn', bx, ty, vt, th2, { fx = k, what = tb[2] })
        end
        if xpw > 0 and (not f.wrap or xopen) then
          local xy0 = f.wrap and (hy + L.rh + 1) or hy
          D.mac_xy(L, f, vals, bx + vt + mpw, xy0, xpw, by + bh - xy0 - 2, k, drag, mx, my, hover)
        end
        if not macfold then
          local hx, hw = bx + vt + L.pad, mpw - 2 * L.pad
          local hy = f.wrap and (hy + 1) or (hy - L.rh + 2)   -- заголовок MACRO — во вкладке (у контейнера — строкой над ними); слайдеры с верха
          local mi, mybot = 0, hy
          -- 22 окт: имена макросов из плагина (p.mlabel) — строкой над слайдером, если по высоте влезают все
          -- (номер + имя, слайдер во всю ширину); не влезают — как раньше: номер слева, имя — в статусе
          -- 24 окт: макрос контейнера — подпись по назначению: имя параметра цели («cutoff», ещё — «+2»); без
          -- назначения — только номер (было «jf_tracker_m…» у всех: имя выведенного параметра)
          if f.wrap then for _, p in ipairs(f.params) do p.mlabel = p.pinname end end   -- 25 окт: ★ — имя параметра (эффект — в статусе)
          local named = false
          for _, p in ipairs(f.params) do if p.mfader and p.mlabel then named = true; break end end
          local two = named and (hy + (1 + 2 * f.nmacro) * L.rh <= by + bh - 2)
          for pi, p in ipairs(f.params) do
            if p.mfader then
              mi = mi + 1
              local py = two and (hy + L.rh + (mi - 1) * 2 * L.rh) or (hy + mi * L.rh)
              if py + (two and 2 or 1) * L.rh > by + bh - 2 then break end
              local v = vals[pi] or { n = 0, s = '' }
              local psel = is_sel and sel.param == pi
              local hot = not drag and mx >= hx and mx < hx + hw and my >= py and my < py + (two and 2 or 1) * L.rh
              if two then
                text(hx, py, fit(mi .. ' ' .. (p.mlabel or '-'), hw), (hot or psel) and U.AMBER or (p.mlabel and U.TEXT or U.GREY))
                py = py + L.rh
              end
              local lab = two and '' or tostring(mi)
              local lw = two and 0 or (ms('8') + L.pad)
              local wx0, ww = hx + lw, hw - lw
              if lw > 0 then text(hx, py, fit(lab, lw - 2), (hot or psel) and U.AMBER or U.TEXT) end
              local cy = py + math.floor(L.rh / 2)
              set(U.DIM); gfx.rect(wx0, cy - 1, ww, 2, 1)
              set((hot or psel) and U.AMBER or U.CYAN); gfx.rect(wx0, py + 4, math.max(1, math.floor(math.max(0, math.min(1, v.n)) * ww + 0.5)), L.rh - 8, 1)
              if hot then hover.dsp = { fx = k, f = f, param = pi, sv = math.max(0, math.min(1, (mx - wx0) / math.max(1, ww))), onwidget = mx >= wx0 - 2 } end
              hint('dspparam', hx, py, hw, L.rh, { fx = k, param = pi })
              local mlb = p.mlabel and (mi .. ' ' .. p.mlabel) or p.name   -- 26 окт: CONTROL — подпись макроса из плагина, как в DSP
              if D.slr then D.slr[#D.slr + 1] = { g = 'dspmacro:' .. tostring(k), dsp = true, fx = p.fx or f.i, p = p.i, name = mlb, own = f.name, pn = mlb, x = wx0, y = py, w = ww, h = L.rh } end
              mybot = py + L.rh
            end
          end
          -- 24 окт: контейнер — под ручками + / − и что на каком макросе
          if f.wrap and info.macro_links and info.pool_col and info.pool_col.track then
            f._lx, f._lw, f._ybot = hx, hw, mybot
            D.macro_list(L, info, f, by, bh, k, drag, mx, my, hover)
          end
        end
        set(U.LINE); gfx.rect(bx + mw - 2, by + L.rh + 2, 1, bh - L.rh - 4, 1)
        bx, bw = bx + mw, bw - mw   -- параметры — правее фейдеров (вернуть в конце блока)
      end
      local pw = bw1 - 2 * L.pad
      local nfit = math.floor((bh - L.rh - 2) / L.rh)
      -- Airwindows (4 окт): строка под именем — категория цветом и описание
      local awi = f.airwin and info.airwin_info and info.airwin_info(f.airwin)
      local aw_off = 0
      -- 9 окт: группы (пульт slixer) — строка заголовков, колонка = rows строк;
      -- не влезает по высоте — обычным списком
      -- 10 окт: волна slixer / grain — полосой сверху во всю ширину блока (до 5
      -- строк + строка статуса у slixer), параметры под ней во всех колонках;
      -- не влезает по высоте — прежняя колонка слева
      local wtop, wtop_wh = 0, 0
      f.slx_geo = nil
      D.pmark('dsp: slx frame')
      if f.view == 'slixer' and D.SX and not f.container then
        -- 25 окт: пульт slixer 1 в 1 с окном: ряды кнопок, обзор, волна (пэдов нет, 26 окт); параметры — под ними
        local v0 = info.dsp_view and info.dsp_view('slixer', f.i)
        local P = function(name) return info.slx_param and info.slx_param(f.i, name) end
        local rows, low = D.SX.items(v0, P)
        local lay, nbr = D.SX.layout(rows, bx + L.pad, by + L.rh + 1, bw - 2 * L.pad - (f.slx_hdrw or 0), L.rh, ms, L.pad)   -- 31 окт: справа — кнопки шапки
        local _, nb2 = D.SX.layout(low or {}, 0, 0, bw - 2 * L.pad, L.rh, ms, L.pad)   -- 26 окт: MIDI · ARP под волной
        if not (low and #low > 0) then nb2 = 0 end
        if info.slx_slots then nb2 = nb2 + 1 end   -- 31 окт: строка слотов быстрой загрузки — в самом низу модуля
        nbr = nbr + nb2
        local need = f.rows and (f.rows + (f.groups and 1 or 0)) or 0
        local wr = math.min(16, nfit - need - nbr - 1 - 1)   -- 26 окт: до 16 строк — волна + прицел
        if wr < 3 then need = 0; wr = math.min(16, nfit - nbr - 1 - 1) end
        if wr >= 2 then
          f.slx_geo = { lay = lay, nbr = nbr, nb2 = nb2, low = low, wr = wr, v = v0, noparams = need == 0 }
          wtop_wh = wr * L.rh
          wtop = (nbr - nb2 + 1 + wr + 1) * L.rh + 3   -- 26 окт: ряды MIDI · ARP — внизу модуля, не над параметрами
          nfit = nfit - (nbr + 1 + wr + 1)
          aw_off = wtop
        end
      elseif (f.view == 'slixer' or f.view == 'grain' or f.rs5k) and not f.container then   -- 10 окт: RS5K — тоже полосой сверху
        local need = f.rows and (f.rows + (f.groups and 1 or 0)) or math.ceil(#f.params / math.max(1, ncol))
        local srow = (f.view == 'slixer' or f.rs5k) and 1 or 0         -- RS5K: строка кнопок над волной
        local wrows = math.min(f.rs5k and 6 or 5, nfit - need - srow)
        if wrows >= 2 then
          wtop_wh = wrows * L.rh
          wtop = wtop_wh + srow * L.rh + 3
          nfit = nfit - wrows - srow - 1
          aw_off = wtop
        end
      end
      -- 11 окт: Video processor — строка кнопок code / apply / revert под именем; код открыт —
      -- редактор на весь блок (параметры — после закрытия); пресеты — строка < имя > в шапке
      if f.vproc and not f.container and nfit >= 2 then
        local ed = info.vp_editor and info.vp_editor(f)
        local rx, ry = bx + L.pad, by + L.rh + 1
        local function vbtn(lbl, what, on)
          local w2 = ms(lbl) + 2 * L.pad
          if rx + w2 > bx + bw - L.pad then return end
          local hot = not drag and mx >= rx and mx < rx + w2 and my >= ry and my < ry + L.rh
          set(on and U.tint(U.CYAN, 0.3) or (hot and U.tint(U.AMBER, 0.3) or U.BG)); gfx.rect(rx, ry, w2, L.rh - 1, 1)
          set(on and U.CYAN or (hot and U.AMBER or U.LINE)); gfx.rect(rx, ry, w2, L.rh - 1, 0)
          text(rx + L.pad, ry, lbl, on and U.CYAN or (hot and U.AMBER or U.TEXT))
          if hot then hover.rs5k = { fx = k, f = f, what = what } end
          rx = rx + w2 + 2
        end
        vbtn('code', 'vp_code', ed ~= nil)
        if ed then
          vbtn('apply', 'vp_apply'); vbtn('revert', 'vp_revert')
          local tip = 'Cmd+S apply, Esc close'
          if rx + L.pad + ms(tip) <= bx + bw - L.pad then text(rx + L.pad, ry, tip, U.GREY) end
          local ey = ry + L.rh + 1
          if by + bh - ey > 2 * L.rh then
            ed.draw(U, L, bx + 1, ey, bw - 2, by + bh - ey - 1, info.focus == 'dsp', fit, (ed.dirty and 'edited - not applied' or 'code'))
          end
          nfit = 0
        else
          nfit = nfit - 1; aw_off = aw_off + L.rh
        end
      end
      local grp = f.groups and f.rows and nfit - 1 >= f.rows
      if grp then nfit = f.rows; aw_off = wtop + L.rh end
      aw_off = aw_off + tab_top   -- 22 окт: вкладки сверху — параметры ниже них
      if awi then
        -- 11 окт: строки «[категория]» в блоке нет — категория и описание только в
        -- статусе внизу (под мышью или выбранный блок), блок — под параметры
        local over = mx >= bx and mx < bx + bw and my >= by and my < by + bh
        if (over or (is_sel and not D.aw_status)) and (awi.desc or '') ~= '' then
          D.aw_status = (f.airwin or '') .. (awi.cat ~= '' and (' - ' .. awi.cat) or '') .. ': ' .. awi.desc
        end
      end
      local pcol0 = 0
      local cl                                     -- развёрнутый контейнер: pi → { колонка, ряд }
      if f.container and f.kids then
        -- строка броска (6 окт): «| serial» — за предыдущим, «= parallel» —
        -- параллельно ему; при броске половина под мышью горит голубым
        local function drop_row(x0, y0, w0)
          local hw = math.floor(w0 / 2)
          local grey = U.readable(U.GREY, is_sel and U.tint(U.AMBER, 0.18) or U.BG, 4.5)
          local lit = drag and my >= by and my < by + bh and mx >= bx + bw / 4 and mx < bx + bw * 3 / 4
          local short = ms('= parallel') > hw - 2 * L.pad      -- тесно — обе половины коротко
          for hi, part in ipairs({ { '|', 'serial' }, { '=', 'parallel' } }) do
            local px = x0 + (hi - 1) * hw
            local on = lit and ((hi == 2) == (mx >= bx + bw / 2))
            if on then set(U.tint(U.CYAN, 0.3)); gfx.rect(px, y0, hw - 1, L.rh, 1) end
            text(px + L.pad, y0, fit(part[1] .. ' ' .. (short and part[2]:sub(1, 3) or part[2]), hw - 2 * L.pad), on and U.CYAN or grey)
          end
        end
        local function kid_label(kid, w0)
          local glyph = kid.parallel == 1 and '=' or (kid.parallel == 2 and '+' or '|')
          return fit((kid.enabled and '' or '(off) ') .. glyph .. ' ' .. kid.name .. (kid.container and ' [..]' or ''), w0)
        end
        if f.wrap then
          -- 24 окт: контейнер-обёртка: под шапкой — его макросы (и XY по двум первым); пусто — гнездо для броска;
          -- дети — полноразмерными модулями следом, в рамке контейнера
          local ky = by + L.rh + 1
          local nreal = 0   -- 24 окт: макро-JSFX — не эффект (пустой контейнер с макросами — всё ещё гнездо)
          for _, kd in ipairs(f.kids) do if not (kd.name or ''):find('jf_tracker_macro', 1, true) then nreal = nreal + 1 end end
          if nreal == 0 then
            -- макросы уже есть (новый контейнер — 4) — гнездо в нижней половине, под ними
            local ey0 = #f.params > 0 and (by + math.floor(bh / 2)) or (ky + 2)
            local ex, ey, ew, eh = bx + L.pad, ey0, bw - 2 * L.pad, by + bh - ey0 - 4
            local lit = drag and mx >= bx and mx < bx + bw and my >= by and my < by + bh
            set(lit and U.tint(U.CYAN, 0.25) or U.tint(U.CYAN, 0.06)); gfx.rect(ex, ey, ew, eh, 1)
            set(lit and U.CYAN or U.tint(U.CYAN, 0.5))
            for dx = 0, ew - 1, 6 do gfx.rect(ex + dx, ey, math.min(3, ew - dx), 1, 1); gfx.rect(ex + dx, ey + eh - 1, math.min(3, ew - dx), 1, 1) end
            for dy = 0, eh - 1, 6 do gfx.rect(ex, ey + dy, 1, math.min(3, eh - dy), 1); gfx.rect(ex + ew - 1, ey + dy, 1, math.min(3, eh - dy), 1) end
            -- 24 окт: описание — только с хинтами; так — одна строка
            local lines = info.hints and { { 'empty container', U.TEXT }, { 'drop an fx here', U.GREY }, { 'or a container', U.GREY }, { '[] a container inside', U.DIM }, { 'af add fx', U.DIM } }
              or { { 'drop fx here', U.GREY } }
            local ty0 = ey + math.max(2, math.floor((eh - #lines * L.rh) / 2))
            for li, ln in ipairs(lines) do
              local yy = ty0 + (li - 1) * L.rh
              if yy + L.rh <= ey + eh - 1 then text(ex + L.pad, yy, fit(ln[1], ew - 2 * L.pad), lit and U.CYAN or ln[2]) end
            end
          end
          -- 24 окт: отдел цепей — правее вкладок макросов / xy, во всю высоту
          if nreal > 0 then
            local ye, ctab = D.cont_chains(L, info, f, bx + L.pad, ky + 1, bw - 2 * L.pad, by + bh - 3, k, drag, mx, my, hover)
            -- 28 окт: вкладка XY — 4 угла = снимки всех модулей внутри, шайба — морф; ROUTE — схема того, что внутри
            if ye and ctab == 'xy' and info.cont_snaps then
              local si, cc = info.cont_snaps(info.pool_col, f)
              D.snap_pad(L, si, cc, bx + L.pad, bw - 2 * L.pad, ye + 2, by + bh - ye - 8, mx, my, hover, hint)
            elseif ye and ctab == 'route' and info.route_nodes and info.pool_col then
              local inside = {}
              for _, n in ipairs(info.route_nodes(info.pool_col)) do
                local g = fxs[n.k]
                local p = g and g.inner and g.inner.parent
                while p and p ~= f do p = p.inner and p.inner.parent end
                if p == f then inside[#inside + 1] = n end
              end
              D.route_draw(L, inside, info.pool_col, bx + L.pad, ye + 2, bw - 2 * L.pad, by + bh - ye - 8, hover)
            end
          end
        elseif f.bands and #f.kids > 0 then
          -- 23 окт: ÷N bands (как Ableton): слева — полосы строками сверху вниз high … low (щелчок — открыть цепь),
          -- под ними — кроссовер (частоты сплиттера; правка идёт во все полосы); справа — эффекты выбранной полосы
          -- колонками (сплиттер в начале цепи не показан — он часть контейнера)
          D.kit_sel = D.kit_sel or {}
          local kkey = tostring(info.pool_col and info.pool_col.guid or '') .. ':' .. tostring(f.fguid or f.i)
          local nb = #f.kids
          local sb = math.max(1, math.min(nb, D.kit_sel[kkey] or 1))
          D.kit_sel[kkey] = sb
          set(U.tint(U.AMBER, 0.55)); gfx.rect(bx + 1, by + 1, bw - 2, bh - 2, 0)
          local hy = by + L.rh + 1
          local cw_on = ms('off') + L.pad
          local cw_n = ms('9 fx') + L.pad
          for r = 1, nb do
            local b = nb - r + 1
            local kid = f.kids[b]
            local ry = hy + (r - 1) * L.rh
            local on = b == sb
            local hotr = not drag and mx >= bx and mx < bx + bw1 and my >= ry and my < ry + L.rh
            if on or hotr then set(on and U.tint(U.AMBER, 0.28) or D.CURROW); gfx.rect(bx + 2, ry, bw1 - 3, L.rh, 1) end
            local ng = math.max(0, #(kid.entry and kid.entry.kids or {}) - 1)
            local nw0 = bw1 - 2 * L.pad - cw_on - cw_n
            text(bx + L.pad, ry, fit(kid.name or ('band ' .. b), nw0 - L.pad), kid.enabled and (on and U.AMBER or (hotr and U.TEXT or U.TEXT)) or U.DIM)
            text(bx + L.pad + nw0, ry, fit(ng > 0 and (ng .. ' fx') or '-', cw_n - L.pad), U.GREY)
            local ox = bx + bw1 - L.pad - cw_on
            local hon = hotr and mx >= ox
            text(ox, ry, kid.enabled and 'on' or 'off', hon and U.AMBER or (kid.enabled and U.GREEN or U.RED))
            if hon then hover.dspbtn = { fx = k, f = f, what = 'kbypass', kid = kid }
            elseif hotr then hover.dspkit = { k = k, key = kkey, ki = b } end
            hint('dspkit', bx, ry, bw1, L.rh, { key = kkey, ki = b })
            -- 23 окт: эффект / модуль тащат на строку полосы — в конец её цепи (голубая рамка строки)
            if drag and (drag.new or (drag.k and drag.k ~= k)) and mx >= bx and mx < bx + bw1 and my >= ry and my < ry + L.rh then
              hover.kitdrop = { k = k, f = f, ki = b, kid = kid, pos = #(kid.entry and kid.entry.kids or {}), band = true }
              set(U.CYAN); gfx.rect(bx + 2, ry, bw1 - 3, L.rh, 0)
            end
          end
          local xy = hy + nb * L.rh + 2
          set(U.LINE); gfx.rect(bx + L.pad, xy - 1, bw1 - 2 * L.pad, 1, 1)
          text(bx + L.pad, xy, fit('crossover', bw1 - 2 * L.pad), U.GREY)
          set(U.LINE); gfx.rect(bx + bw1, by + L.rh + 1, 1, bh - L.rh - 4, 1)
          -- раскладка параметров: кроссовер — сплиттер low (kid 1, внук 1) под списком; цепь — колонками; остальное спрятано
          cl = {}
          local cnt = {}
          for pi, p in ipairs(f.params) do
            if p.kid == 1 and p.gkid == 1 and not p.macro then
              cnt.x = (cnt.x or 0) + 1; cl[pi] = { 0, nb + cnt.x - 1 }
            else cl[pi] = { 99, 0 } end
          end
        elseif f.kit and ncol >= 2 then
          -- 11 окт: кит RS5K — слева «all» и слайсы строками (имя, нота, громкость), щелчок —
          -- выбрать; справа свойства выбранного слайса тем же модулем RS5K. all — общий
          -- контроль: показаны параметры первого слайса, запись идёт на все (ctx.fx_write)
          D.kit_sel = D.kit_sel or {}
          local kkey = tostring(info.pool_col and info.pool_col.guid or '') .. ':' .. tostring(f.fguid or f.i)   -- 19 окт: GUID рэка, не номер
          local ks = math.max(0, math.min(#f.kids, D.kit_sel[kkey] or 0))
          f.kit_all = ks == 0
          set(U.tint(U.AMBER, 0.55)); gfx.rect(bx + 1, by + 1, bw - 2, bh - 2, 0)
          local hy = by + L.rh + 1
          local function kv(ki, want)
            for pi, p in ipairs(f.params) do
              if p.kid == ki and (p.name or ''):lower():find(want, 1, true) then return vals[pi] and vals[pi].s or '' end
            end
            return ''
          end
          -- 19 окт: рэк на всё окно (zz) — вкладки pads | list; list — таблица всех пэдов со всеми параметрами
          D.kit_list = D.kit_list or {}
          local zoomed = info.dsp_zoomed
          -- 19 окт: вид pads | list — кнопка list в шапке (вкладки на всё окно убраны: одна кнопка на функцию)
          if D.DR and (D.kit_list[kkey] or (zoomed and 'list' or 'pads')) == 'list' then   -- 19 окт: и без zz (кнопка list)
            -- 23 окт: список — на месте сетки пэдов (шириной с неё), параметры выбранного пэда — справа, как у сетки
            f._klist = true
            local bwl = 2 * bw1 - 3   -- 23 окт: вдвое шире сетки — колонки vol / grp / chk влезают
            local COLS = { { 'note', 'note lo', 4 }, { 'name', nil, 12 }, { 'vol', 'volume', 6 }, { 'grp', 'g', 5 }, { 'chk', 'cg', 5 }, { 'on', 'on', 3 } }
            -- узко — сначала без grp / chk, потом без vol, имя короче (колонки не вылезают за вкладку)
            local avail = math.floor((bwl - 2 * L.pad) / L.cw)
            local function sum() local t = 0; for _, c2 in ipairs(COLS) do t = t + c2[3] end; return t end
            for _, drop in ipairs({ 'chk', 'grp', 'vol' }) do
              if sum() <= avail then break end
              for i2, c2 in ipairs(COLS) do if c2[1] == drop then table.remove(COLS, i2); break end end
            end
            if sum() > avail then for _, c2 in ipairs(COLS) do if c2[1] == 'name' then c2[3] = math.max(4, c2[3] - (sum() - avail)) end end end
            local tot = sum()
            local cwx = math.max(L.cw, math.floor((bwl - 2 * L.pad) / tot))
            local ly0 = hy
            local xh = bx + L.pad
            local pbw = ms('pads') + 2 * L.pad   -- 23 окт: кнопка pads — справа в строке заголовков (вкладка сбоку убрана)
            local pbx = bx + bwl - pbw - 2
            for _, c2 in ipairs(COLS) do if xh < pbx then text(xh, ly0, fit(c2[1], math.min(c2[3] * cwx, pbx - xh) - L.pad), U.GREY) end; xh = xh + c2[3] * cwx end
            D.kit_viewbtn = { x = pbx, y = ly0, w = pbw, lbl = 'pads' }
            set(U.LINE); gfx.rect(bx + L.pad, ly0 + L.rh, bwl - 2 * L.pad, 1, 1)
            local function pidx(ki, want)
              for pi, p in ipairs(f.params) do if p.kid == ki and (p.name or ''):lower():find(want, 1, true) then return pi end end
            end
            local nrow = math.max(1, math.floor((by + bh - ly0 - L.rh - 4) / L.rh))
            D.kit_lscroll = D.kit_lscroll or {}
            local sc = math.max(0, math.min(#f.kids - nrow, D.kit_lscroll[kkey] or 0))
            D.kit_lks = D.kit_lks or {}   -- 25 окт: к выбору — только когда он сменился (колесо / полоса не возвращаются)
            if ks ~= D.kit_lks[kkey] then
              if ks > 0 and ks - 1 < sc then sc = ks - 1 elseif ks > sc + nrow then sc = ks - nrow end
              D.kit_lks[kkey] = ks
            end
            D.kit_lscroll[kkey] = sc
            for r = 1, nrow do
              local ki = sc + r
              local kid = f.kids[ki]
              if not kid then break end
              local ry = ly0 + L.rh + 2 + (r - 1) * L.rh
              local on = ki == ks
              local hotr = not drag and mx >= bx and mx < bx + bwl and my >= ry and my < ry + L.rh
              local hit = D.pad_hit and kid.note and D.pad_hit[kid.note]
              local flash = hit and reaper.time_precise() - hit < 0.25
              if flash then set(U.tint(U.GREEN, 0.35)); gfx.rect(bx + 2, ry, bwl - 4, L.rh, 1)
              elseif on or hotr then set(on and U.tint(U.AMBER, 0.28) or D.CURROW); gfx.rect(bx + 2, ry, bwl - 4, L.rh, 1) end
              local x2 = bx + L.pad
              for _, c2 in ipairs(COLS) do
                local cw3 = c2[3] * cwx
                local s2, col2, what = '', kid.enabled and U.TEXT or U.DIM, nil
                if c2[1] == 'name' then s2 = kid.name or ''
                elseif c2[1] == 'note' then local nn = kid.note; s2 = nn and (({ 'C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-' })[nn % 12 + 1] .. math.max(0, nn // 12 - 1)) or '---'
                elseif c2[1] == 'grp' then s2 = (kid.group or 0) > 0 and ('grp' .. kid.group) or '-'; col2 = (kid.group or 0) > 0 and U.CYAN or U.DIM; what = 'kgroup'
                elseif c2[1] == 'chk' then s2 = (kid.choke or 0) == 17 and 'off' or ((kid.choke or 0) > 0 and ('chk' .. kid.choke) or '-');   -- 24 окт: 17 — OFF обрывает col2 = (kid.choke or 0) > 0 and U.RED or U.DIM; what = 'kchoke'
                elseif c2[1] == 'on' then s2 = kid.enabled and 'on' or 'off'; col2 = kid.enabled and U.GREEN or U.RED; what = 'kbypass'
                else s2 = kv(ki, c2[2]) end
                local hc = hotr and mx >= x2 and mx < x2 + cw3
                text(x2, ry, fit(s2, cw3 - L.pad), hc and U.AMBER or (on and c2[1] == 'name' and U.AMBER or col2))
                if hc then
                  if what then hover.dspbtn = { fx = k, f = f, what = what, kid = kid, ki = ki }
                  elseif c2[2] and c2[1] ~= 'note' then hover.kitcell = { k = k, pi = pidx(ki, c2[2]), ki = ki, key = kkey } end
                end
                x2 = x2 + cw3
              end
              if hotr and not hover.dspbtn and not hover.kitcell then hover.dspkit = { k = k, key = kkey, ki = ki }; hover.dspkid = { k = k, f = f, ki = ki, kid = kid } end
            end
            D.kit_lkey = kkey; D.vbar('kitlist', bx, ly0 + L.rh + 2, bwl - 2, nrow * L.rh, sc, nrow, #f.kids)
            bx, bw = bx + bw1, bw - bw1   -- дальше (вкладка, пэд, параметры) — правее списка; правый край модуля тот же
          else f._klist = nil
          end
          if f._klist then   -- 23 окт: список уже нарисован на месте сетки — ни сетки, ни старого списка слайсов
          elseif D.DR then
            -- 16 окт: drumrs5k — сетка пэдов вместо списка: шапка «all · N pads · cell: …»,
            -- ячейка — имя пэда и подпись (note / key / wave / spec); щелчок — выбрать
            -- и прослушать (main), выбранный — янтарём, выключенный — тускло
            local ah = ms('all') + 2 * L.pad
            local hot_all = not drag and mx >= bx + 2 and mx < bx + 2 + ah and my >= hy and my < hy + L.rh
            set(ks == 0 and U.tint(U.AMBER, 0.3) or (hot_all and U.tint(U.AMBER, 0.15) or U.BG)); gfx.rect(bx + 2, hy, ah, L.rh - 1, 1)
            set(ks == 0 and U.AMBER or U.LINE); gfx.rect(bx + 2, hy, ah, L.rh - 1, 0)
            text(bx + 2 + L.pad, hy, 'all', ks == 0 and U.AMBER or (hot_all and U.TEXT or U.GREY))
            if hot_all then hover.dspkit = { k = k, key = kkey, ki = 0 } end
            -- 23 окт: midi out — MIDI-посылы рэка на другие треки (пэды и ноты играют и там); горит, когда есть
            local mo_n = info.midi_out_n and info.pool_col and info.midi_out_n(info.pool_col.track) or 0
            local mol = mo_n > 0 and ('midi out ' .. mo_n) or 'midi out'
            local mow = ms(mol) + 2 * L.pad
            local mox = bx + 2 + ah + 2
            if mox + mow < bx + bw1 - ms('cell') - ms('list') - 6 * L.pad then
              local hm = not drag and mx >= mox and mx < mox + mow and my >= hy and my < hy + L.rh
              set(hm and U.tint(U.AMBER, 0.3) or (mo_n > 0 and U.tint(U.CYAN, 0.3) or U.BG)); gfx.rect(mox, hy, mow, L.rh - 1, 1)
              set(hm and U.AMBER or (mo_n > 0 and U.CYAN or U.LINE)); gfx.rect(mox, hy, mow, L.rh - 1, 0)
              text(mox + L.pad, hy, mol, hm and U.AMBER or (mo_n > 0 and U.TEXT or U.GREY))
              if hm then hover.dspbtn = { fx = k, f = f, what = 'kmidi' } end
              hint('dspbtn', mox, hy, mow, L.rh - 1, { fx = k, what = 'kmidi' })
              ah = ah + mow + 2   -- счётчик пэдов и кнопки правее — после неё
            end
            -- 31 окт: new kit (случайный кит: все / выбранный / 16 видимых) и ‹ ξ › — похожий сэмпл выбранному пэду
            do
              local bl = { { 'new kit', 'knew' } }
              if ks > 0 then bl[#bl + 1] = { '<', 'kxprev' }; bl[#bl + 1] = { 'ξ', 'kxi' }; bl[#bl + 1] = { '>', 'kxnext' } end
              local nx = bx + 2 + ah
              for _, b2 in ipairs(bl) do
                local w2 = ms(b2[1]) + 2 * L.pad
                if nx + w2 < bx + bw1 - ms('cell') - ms('list') - 6 * L.pad then
                  local hn = not drag and mx >= nx and mx < nx + w2 and my >= hy and my < hy + L.rh
                  set(hn and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(nx, hy, w2, L.rh - 1, 1)
                  set(hn and U.AMBER or U.LINE); gfx.rect(nx, hy, w2, L.rh - 1, 0)
                  text(nx + L.pad, hy, b2[1], hn and U.AMBER or (b2[2] == 'knew' and U.TEXT or U.CYAN))
                  if hn then hover.dspbtn = { fx = k, f = f, what = b2[2], ki = ks, kkey = kkey } end
                  hint('dspbtn', nx, hy, w2, L.rh - 1, { fx = k, what = b2[2] })
                  nx = nx + w2 + 2; ah = ah + w2 + 2
                end
              end
              D.kit_win = D.kit_win or {}; D.kit_win[kkey] = D.kit_scroll and D.kit_scroll[kkey]   -- видимые 16: ряд окна
            end
            local cm = info.drumcell or 'note'
            local cl_lbl = 'cell'   -- 23 окт: просто cell (режим подписи — в выпадашке)
            local cw2 = ms(cl_lbl) + 2 * L.pad
            local cxb = bx + bw1 - cw2 - 2
            if cxb > bx + 2 + ah + L.pad then
              local hc = not drag and mx >= cxb and mx < cxb + cw2 and my >= hy and my < hy + L.rh
              set(hc and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(cxb, hy, cw2, L.rh - 1, 1)
              set(hc and U.AMBER or U.LINE); gfx.rect(cxb, hy, cw2, L.rh - 1, 0)
              text(cxb + L.pad, hy, cl_lbl, hc and U.AMBER or U.TEXT)
              if hc then hover.dspbtn = { fx = k, f = f, what = 'kcell' } end
              -- 19 окт: list — все пэды таблицей (все параметры), на месте сетки; ещё раз — пэды
              D.kit_list = D.kit_list or {}
              local lon = (D.kit_list[kkey] or (info.dsp_zoomed and 'list' or 'pads')) == 'list'
              local lbw = ms('list') + 2 * L.pad   -- 23 окт: list — снова кнопкой в шапке, левее cell
              local lxb = cxb - lbw - 2
              if lxb > bx + 2 + ah + L.pad then
                D.kit_viewbtn = { x = lxb, y = hy, w = lbw, lbl = 'list' }
                -- 19 окт: размер пэдов s / m / l — кнопка с выпадашкой (3 значения — не перебор по кругу)
                local szl = 'size ' .. (info.kitsize or 'l')
                local szw = ms(szl) + 2 * L.pad
                local szx = lxb - szw - 2
                if not lon and szx > bx + 2 + ah + L.pad + ms('20 pads') + L.pad then
                  local hs = not drag and mx >= szx and mx < szx + szw and my >= hy and my < hy + L.rh
                  set(hs and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(szx, hy, szw, L.rh - 1, 1)
                  set(hs and U.AMBER or U.LINE); gfx.rect(szx, hy, szw, L.rh - 1, 0)
                  text(szx + L.pad, hy, szl, hs and U.AMBER or U.TEXT)
                  if hs then hover.dspbtn = { fx = k, f = f, what = 'ksize' } end
                end
              end
              local cnt_s = ('%d pads'):format(#f.kids)
              if ms(cnt_s) <= lxb - (bx + 2 + ah + 2 * L.pad) then text(bx + 2 + ah + L.pad, hy, cnt_s, U.DIM) end
            end
            local gx0, gy0 = bx + 2, hy + L.rh + 1
            local gw, gh = bw1 - 4, by + bh - 3 - gy0 - (L.rh + 3)   -- 19 окт: внизу — строка grp / chk / r
            -- 18 окт: всегда 4 × 4 (как пэды MPC), справа — карта всех 128 пэдов кубиками 4 × 32 (прокрутка / прыжок)
            local cube = math.max(2, math.min(5, math.floor((gh - 2) / 32) - 1))
            local mw = 4 * (cube + 1) + 4
            gw = gw - mw
            local mapx = gx0 + 1                               -- 18 окт: карта слева (просьба), пэды правее
            gx0 = gx0 + mw
            -- 18 окт (2): кубик = нота MIDI 0..127, снизу вверх по 4 в ряду (как пэды MPC / drum rack): ряд — 4 ноты,
            -- 3 ряда — октава; сетка 4 × 4 — окно из 16 нот снизу вверх; пэд стоит на кубике своей ноты
            -- 19 окт: пэды квадратные (сторона — меньшая из ширины / высоты четверти, не меньше трёх строк текста)
            local side = math.min(gw // 4, math.max(4 * L.rh + 6, gh // 4))   -- 19 окт: крупнее (имя + мини-волна + кнопки)   -- 19 окт: не шире четверти колонки (низкая панель — прокрутка рядов, но не наезд на свойства)
            if info.kitsize ~= 's' then side = math.max(2 * L.rh, math.min(gw // 4, gh // 4)) end   -- 19 окт: m / l — строго 4 × 4 на всё место
            local G = { cols = 4, cw = side, ch = side }
            G.fit = info.kitsize == 's' and math.max(1, math.min(32, gh // G.ch)) or math.max(1, math.min(4, gh // G.ch))   -- s — сколько влезает рядов мелко
            local function pos(ki) local kd = f.kids[ki]; return math.max(0, math.min(127, (kd and kd.note) or (48 + ki - 1))) end
            local by_note = {}
            for ki2 in ipairs(f.kids) do local pn = pos(ki2); if not by_note[pn] then by_note[pn] = ki2 end end
            D.kit_scroll = D.kit_scroll or {}
            local wb = D.kit_scroll[kkey]                     -- нижний ряд окна (ряд = 4 ноты)
            if not wb then
              local lo
              for ki2 in ipairs(f.kids) do local pn = pos(ki2); if not lo or pn < lo then lo = pn end end
              wb = (lo or (D.slice_base_note or 48)) // 4     -- нижний пэд, без пэдов — базовая октава (C3)
            end
            -- 19 окт: октава клавиатуры ([ ]) сменилась — окно пэдов к ней (нижний ряд — с ноты октавы)
            D.kit_octs = D.kit_octs or {}
            if D.kit_octave and D.kit_octs[kkey] ~= D.kit_octave then
              if D.kit_octs[kkey] ~= nil then wb = ((D.kit_octave + 1) * 12) // 4; D.kit_wheel = true end
              D.kit_octs[kkey] = D.kit_octave
            end
            -- колесо над картой или сеткой — по рядам (курсор пэда окно не возвращает, пока сам не сдвинулся)
            if gfx.mouse_wheel ~= 0 and not drag and mx >= mapx and mx < gx0 + 4 * G.cw and my >= gy0 and my < by + bh then
              wb = wb + (gfx.mouse_wheel > 0 and 1 or -1); gfx.mouse_wheel = 0; D.kit_wheel = true
            end
            D.kit_selseen = D.kit_selseen or {}
            local skey = tostring(ks) .. ':' .. tostring(D.kit_note and D.kit_note[kkey])
            if D.kit_selseen[kkey] ~= skey then D.kit_selseen[kkey] = skey; D.kit_wheel = nil end
            local kn = ks == 0 and D.kit_note and D.kit_note[kkey] or nil      -- 19 окт: курсор режима пэдов на пустой ноте
            if (ks > 0 or kn) and not D.kit_wheel then
              local kr = (ks > 0 and pos(ks) or kn) // 4
              if kr < wb then wb = kr elseif kr >= wb + G.fit then wb = kr - G.fit + 1 end
            end
            wb = math.max(0, math.min(wb, 32 - G.fit))
            D.kit_scroll[kkey] = wb
            local NN = { 'C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-' }
            local function nname(n) return NN[n % 12 + 1] .. math.max(0, n // 12 - 1) end
            -- карта: 4 колонки × 32 ряда снизу вверх
            do
              local mx0, my0 = mapx + 2, gy0
              -- жёлтый — выбранный (его семплер справа), оранжевый — занятый, серый — пустой,
              -- красный — выключен (mute), зелёный мигает — соло (включён один из нескольких)
              local non = 0
              for _, kd2 in ipairs(f.kids) do if kd2.enabled then non = non + 1 end end
              local blink = math.floor(reaper.time_precise() * 3) % 2 == 0
              for r = 0, 31 do
                local cym = my0 + (31 - r) * (cube + 1)
                if r % 3 == 0 and r > 0 then set(U.mix(U.LINE, U.PANEL, 0.3)); gfx.rect(mx0 - 1, cym + cube + 1, 4 * (cube + 1), 1, 1) end   -- октава
                for c = 0, 3 do
                  local note = r * 4 + c
                  local ki = by_note[note]
                  local kid = ki and f.kids[ki]
                  local cxm = mx0 + c * (cube + 1)
                  local solo = kid and kid.enabled and non == 1 and #f.kids > 1
                  local col2 = not kid and U.mix(U.LINE, U.PANEL, 0.5)
                    or (solo and (blink and U.GREEN or U.mix(U.GREEN, U.PANEL, 0.5)))
                    or (not kid.enabled and U.RED)
                    or (ki == ks and U.YELLOW) or U.mix(U.AMBER, U.PANEL, 0.4)   -- 19 окт: занятые темнее — соседи не сливаются, выбранный ярче
                  local hit2 = D.pad_hit and D.pad_hit[note]
                  if hit2 and reaper.time_precise() - hit2 < 0.25 then col2 = U.GREEN end
                  set(col2); gfx.rect(cxm, cym, cube, cube, kid and 1 or 0)
                  if ki == ks and kid and not kid.enabled then set(U.YELLOW); gfx.rect(cxm - 1, cym - 1, cube + 2, cube + 2, 0) end
                  if not drag and kid and mx >= cxm and mx < cxm + cube + 1 and my >= cym and my < cym + cube + 1 then hover.dspkid = { k = k, f = f, ki = ki, kid = kid } end
                end
              end
              set(U.AMBER); gfx.rect(mx0 - 2, my0 + (31 - (wb + G.fit - 1)) * (cube + 1) - 1, 4 * (cube + 1) + 3, G.fit * (cube + 1) + 1, 0)   -- видимое окно
              local mh = 32 * (cube + 1)
              if not drag and mx >= mx0 - 2 and mx < mx0 + 4 * (cube + 1) + 2 and my >= my0 and my < my0 + mh then
                local rr = 31 - math.floor((my - my0) / (cube + 1))
                local cc = math.max(0, math.min(3, math.floor((mx - mx0) / (cube + 1))))
                hover.dspkitmap = { key = kkey, row = rr, fit = G.fit, ki = by_note[rr * 4 + cc], note = rr * 4 + cc, f = f }
              end
            end
            -- 19 окт: Ctrl+Cmd — тачпад играет нижние 4 ряда окна: рамка вокруг них
            if D.pad_zone and D.pad_zone.key == kkey then
              local ry0 = gy0 + math.max(0, G.fit - 4) * G.ch
              set(U.AMBER); gfx.rect(gx0 - 2, ry0 - 2, 4 * G.cw + 2, math.min(4, G.fit) * G.ch + 2, 0)
            end
            -- пустые ноты окна — тусклые рамки с именем ноты
            for rr = 0, G.fit - 1 do
              for c = 0, 3 do
                local note = (wb + rr) * 4 + c
                if not by_note[note] then
                  local ex, ey = gx0 + c * G.cw, gy0 + (G.fit - 1 - rr) * G.ch
                  set(note == kn and U.AMBER or U.mix(U.LINE, U.PANEL, 0.5)); rrect(ex, ey, G.cw - 2, G.ch - 2, false)
                  -- 19 окт: пустая нота — цель броска файлов (новый пэд на этой ноте)
                  local ehot = not drag and mx >= ex and mx < ex + G.cw - 2 and my >= ey and my < ey + G.ch - 2
                  if ehot then
                    hover.dspkit = { k = k, key = kkey, ki = 0, note = note }; hover.dspkid = { k = k, f = f, ki = 0, note = note }
                    if info.dragging then D.drop_note = note end
                  end
                  if D.drop_lit(info, note, ehot) then D.drop_mark(ex, ey, G.cw - 2, G.ch - 2) end
                  text(ex + L.pad, ey + 1, nname(note), U.mix(U.DIM, U.PANEL, 0.4))
                end
              end
            end
            local non_on = 0
            for _, kd2 in ipairs(f.kids) do if kd2.enabled then non_on = non_on + 1 end end
            for ki, kid in ipairs(f.kids) do
              local pn = pos(ki)
              local r, c = G.fit - 1 - (pn // 4 - wb), pn % 4
              if by_note[pn] == ki and r >= 0 and r < G.fit then
                local cx0, cy0 = gx0 + c * G.cw, gy0 + r * G.ch
                local cw0, ch0 = G.cw - 2, G.ch - 2
                local hot = not drag and mx >= cx0 and mx < cx0 + cw0 and my >= cy0 and my < cy0 + ch0
                -- 23 окт: эффект из fx list тащат на пэд — в пэд (его цепочка, справа от сэмплера); подсветка цели
                if drag and (drag.new or (drag.k and drag.k ~= k)) and mx >= cx0 and mx < cx0 + cw0 and my >= cy0 and my < cy0 + ch0 then
                  hover.kitdrop = { k = k, f = f, ki = ki, kid = kid, par = mx >= cx0 + cw0 // 2 }
                  D.kitdrop_cell = { cx0, cy0, cw0, ch0 }   -- 23 окт: половины | serial / = parallel — поверх пэда, после него
                end
                local on = ki == ks or (D.pad_zone and D.pad_zone.key == kkey and D.pad_zone.note == pn)   -- 19 окт: зона тачпада 4 × 4
                local hit = D.pad_hit and kid.note and D.pad_hit[kid.note]
                local flash = hit and reaper.time_precise() - hit < 0.25        -- 19 окт: сыгранный (клавиатура / щелчок) — вспышка
                set(flash and U.tint(U.GREEN, 0.45) or (on and U.tint(U.AMBER, 0.28) or (hot and U.tint(U.AMBER, 0.12) or U.PANEL))); rrect(cx0, cy0, cw0, ch0, true)
                set(on and U.AMBER or (hot and U.GREY or U.LINE)); rrect(cx0, cy0, cw0, ch0, false)
                local fg = kid.enabled and (on and U.AMBER or (hot and U.TEXT or U.GREY)) or U.DIM
                local nm = kid.name or ''
                nm = nm:match('^S%x%x%s+(.+)$') and nm:match('^(S%x%x)') or nm        -- «S01 kick» → S01 (имя сэмпла у всех одно)
                -- 19 окт: заголовок пэда — его нота (key — клавиша); Sxx на пэде уже не нужен
                if cm == 'key' then nm = kid.note and info.drum_key and info.drum_key(kid.note) or nm
                elseif kid.note then nm = ({ 'C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-' })[kid.note % 12 + 1] .. math.max(0, kid.note // 12 - 1) end
                local tag = #(kid.slots or {}) > 0 and ('+' .. #kid.slots) or ''
                -- 19 окт: на пэде — его группы: g1 (играют вместе), c1 (choke)
                local long = ms('grp1 chk1') <= cw0 - 2 * L.pad      -- 19 окт: влезает — grp / chk, как у кнопок; тесно — g / c
                local gp, cp = long and 'grp' or 'g', long and 'chk' or 'c'
                local gtag = ((kid.group or 0) > 0 and (gp .. kid.group) or '') .. ((kid.choke or 0) > 0 and (((kid.group or 0) > 0 and ' ' or '') .. cp .. kid.choke) or '')
                if gtag ~= '' then tag = gtag .. (tag ~= '' and (' ' .. tag) or '') end
                local tw = ms(tag)
                text(cx0 + L.pad, cy0 + 1, fit((kid.enabled and '' or '(off) ') .. nm, cw0 - 2 * L.pad - (tw > 0 and tw + L.pad or 0)), fg)
                if tw > 0 then text(cx0 + cw0 - L.pad - tw, cy0 + 1, tag, U.CYAN) end
                -- 19 окт: нижний ряд пэда — m (mute) слева, > (послушать) шире посередине, s (solo) справа
                if ch0 >= 3 * L.rh then   -- 19 окт: мелкий пэд — без кнопок (не наезжают на имя)
                  local byb = cy0 + ch0 - L.rh - 1
                  local wm = ms('m') + 2 * L.pad
                  local bxs = { { 'm', 'kpm', cx0 + 2, wm }, { '>', 'kpp', cx0 + 2 + wm + 2, cw0 - 2 * wm - 8 }, { 's', 'kps', cx0 + cw0 - 2 - wm, wm } }
                  local soloed = kid.enabled and non_on == 1 and #f.kids > 1
                  for _, b in ipairs(bxs) do
                    if b[4] >= ms(b[1]) + 2 then
                      local hb = not drag and mx >= b[3] and mx < b[3] + b[4] and my >= byb and my < byb + L.rh
                      local lit = (b[2] == 'kpm' and not kid.enabled) or (b[2] == 'kps' and soloed)
                      local lc = b[2] == 'kpm' and U.RED or (b[2] == 'kps' and U.GREEN or U.AMBER)
                      set(hb and U.tint(lc, 0.35) or (lit and U.tint(lc, 0.3) or U.BG)); rrect(b[3], byb, b[4], L.rh, true, 2)
                      set(hb and lc or (lit and lc or U.LINE)); rrect(b[3], byb, b[4], L.rh, false, 2)
                      text(b[3] + math.floor((b[4] - ms(b[1])) / 2), byb, b[1], (hb or lit) and lc or U.GREY)
                      if hb then hover.dspbtn = { fx = k, f = f, what = b[2], kid = kid, ki = ki } end
                    end
                  end
                end
                local ay, ah2 = cy0 + L.rh + 1, ch0 - (ch0 >= 3 * L.rh and 2 or 1) * L.rh - 3
                if cm == 'wave' or cm == 'spec' then
                  local npx = cw0 - 4
                  local pk = kid.file and npx > 4 and ah2 > 3 and info.file_peaks and info.file_peaks(kid.file, npx, kid.pad_a, kid.pad_b, cm == 'spec')
                  local wcol = U.readable(U.mix(U.CYAN, U.TEXT, 0.35), U.PANEL, 3.0)
                  local mid, hh = ay + ah2 / 2, ah2 / 2 - 1
                  if pk and pk.n and pk.n > 0 then
                    set(kid.enabled and wcol or U.DIM)
                    for px = 0, npx - 1 do
                      local idx = math.floor(px / npx * pk.n) + 1
                      local lo, hi = pk.min[idx] or 0, pk.max[idx] or 0
                      if cm == 'spec' and pk.spec and kid.enabled then set(D.spec_colour(pk.spec[idx])) end
                      gfx.line(cx0 + 2 + px, mid - math.min(1, hi) * hh, cx0 + 2 + px, mid - math.max(-1, lo) * hh)
                    end
                  else set(U.LINE); gfx.line(cx0 + 2, mid, cx0 + 2 + npx, mid) end
                elseif ah2 >= L.rh - 2 then
                  -- 19 окт: мини-волна сэмпла пэда фоном под подписью (тускло)
                  local npx = cw0 - 4
                  local pk = kid.file and npx > 4 and info.file_peaks and info.file_peaks(kid.file, npx, kid.pad_a, kid.pad_b, true)   -- 19 окт: спектральные пики
                  if pk and pk.n and pk.n > 0 then
                    local mid, hh = ay + ah2 / 2, ah2 / 2 - 1
                    set(U.mix(kid.enabled and U.CYAN or U.DIM, U.PANEL, 0.6))
                    for px = 0, npx - 1 do
                      local idx = math.floor(px / npx * pk.n) + 1
                      if pk.spec and kid.enabled then set(U.mix(D.spec_colour(pk.spec[idx]), U.PANEL, 0.3)) end   -- цвет = частота, чуть приглушён под подписью
                      gfx.line(cx0 + 2 + px, mid - math.min(1, pk.max[idx] or 0) * hh, cx0 + 2 + px, mid - math.max(-1, pk.min[idx] or 0) * hh)
                    end
                  end
                  -- 19 окт: нота — в заголовке пэда; второй строкой поверх волны больше не пишется
                end
                if hot then hover.dspkit = { k = k, key = kkey, ki = ki }; hover.dspkid = { k = k, f = f, ki = ki, kid = kid, rect = { cx0, cy0, cw0, ch0 } }; if info.dragging then D.drop_note = kid.note end end
                if D.drop_lit(info, kid.note, hot) then D.drop_mark(cx0, cy0, cw0, ch0) end   -- 19 окт: ячейка, куда ляжет брошенный файл
                hint('dspkit', cx0, cy0, cw0, ch0, { key = kkey, ki = ki })
              end
            end
          else
            text(bx + L.pad, hy, fit(('%d$'):format(#f.kids), bw1 - 2 * L.pad), U.GREY)
            local nrow = math.max(1, math.floor((bh - 2 * L.rh - 4) / L.rh))
            D.kit_scroll = D.kit_scroll or {}
            local sc = D.kit_scroll[kkey] or 0
            local total = #f.kids + 1                           -- строка all + слайсы
            if ks + 1 <= sc then sc = ks elseif ks + 1 > sc + nrow then sc = ks + 1 - nrow end
            sc = math.max(0, math.min(sc, math.max(0, total - nrow)))
            D.kit_scroll[kkey] = sc
            for r = 1, nrow do
              local ki = sc + r - 1                             -- 0 = all
              if ki > #f.kids then break end
              local kid = ki > 0 and f.kids[ki] or nil
              local ry = hy + r * L.rh
              local hot = not drag and mx >= bx and mx < bx + bw1 and my >= ry and my < ry + L.rh
              local on = ki == ks
              if on or hot then set(on and U.tint(U.AMBER, 0.3) or U.tint(U.AMBER, 0.15)); gfx.rect(bx + 2, ry, bw1 - 3, L.rh, 1) end
              if kid then
                local nm = (kid.name or ''):match('^(%S+)') or ('S%02d'):format(ki)
                local note = kv(ki, 'note range start'); if note == '' then note = kv(ki, 'note lo') end
                local line = ('%-4s %-4s %s'):format(nm, note, kv(ki, 'volume'))
                text(bx + L.pad, ry, fit((kid.enabled and '' or '(off) ') .. line, bw1 - 2 * L.pad), kid.enabled and (on and U.AMBER or (hot and U.TEXT or U.GREY)) or U.DIM)
                if hot then hover.dspkit = { k = k, key = kkey, ki = ki }; hover.dspkid = { k = k, f = f, ki = ki, kid = kid } end
              else
                text(bx + L.pad, ry, fit('all  - every slice at once', bw1 - 2 * L.pad), on and U.AMBER or (hot and U.TEXT or U.CYAN))
                if hot then hover.dspkit = { k = k, key = kkey, ki = 0 } end
              end
              hint('dspkit', bx, ry, bw1, L.rh, { key = kkey, ki = ki })
            end
          end
          -- 23 окт: list / pads — кнопкой в шапке (pads: левее cell; list: справа в строке заголовков); zv
          local vb = D.kit_viewbtn
          D.kit_viewbtn = nil
          if D.DR and f.kit and vb then
            local hl = not drag and mx >= vb.x and mx < vb.x + vb.w and my >= vb.y and my < vb.y + L.rh
            set(hl and U.tint(U.AMBER, 0.3) or (f._klist and U.tint(U.AMBER, 0.2) or U.BG)); gfx.rect(vb.x, vb.y, vb.w, L.rh - 1, 1)
            set(hl and U.AMBER or U.LINE); gfx.rect(vb.x, vb.y, vb.w, L.rh - 1, 0)
            text(vb.x + L.pad, vb.y, vb.lbl, hl and U.AMBER or U.TEXT)
            if hl then hover.dspbtn = { fx = k, f = f, what = 'kview', view = vb.lbl, key = kkey } end
            hint('dspbtn', vb.x, vb.y, vb.w, L.rh - 1, { fx = k, what = 'kview', view = vb.lbl, key = kkey })
          end
          if D.DR and ks > 0 then   -- 19 окт: свойства пэда (его сэмплер) — своей серой рамкой, отдельно от рамки рэка
            set(U.mix(U.LINE, U.GREY, 0.45)); rrect(bx + bw1 + 1, by + L.rh + 1, bw - bw1 - 3, bh - L.rh - 4, false)
          else set(U.LINE); gfx.rect(bx + bw1, by + L.rh + 1, 1, bh - L.rh - 4, 1) end
          -- шапка второй колонки: выбранный слайс с B / x, или all
          local cx = bx + bw1
          local kid = ks > 0 and f.kids[ks] or nil
          if kid then
            local kb2 = ms('x') + 2 * L.pad
            local onw = ms('off') + 2 * L.pad   -- 24 окт: on / off вместо B
            for _, b in ipairs({ { 'x', 'kdel', cx + bw1 - kb2 - 1 }, { kid.enabled and 'on' or 'off', 'kbypass', cx + bw1 - kb2 - onw - 3, onw } }) do
              local kb2 = b[4] or kb2
              local hb = not drag and mx >= b[3] and mx < b[3] + kb2 and my >= hy and my < hy + L.rh
              local lit = b[2] == 'kbypass' and not kid.enabled
              set(hb and U.tint(b[2] == 'kdel' and U.RED or U.AMBER, 0.35) or (lit and U.tint(U.AMBER, 0.25) or U.BG)); gfx.rect(b[3], hy, kb2, L.rh - 1, 1)
              set(hb and (b[2] == 'kdel' and U.RED or U.AMBER) or U.LINE); gfx.rect(b[3], hy, kb2, L.rh - 1, 0)
              text(b[3] + L.pad, hy, b[1], hb and (b[2] == 'kdel' and U.RED or U.AMBER) or (lit and U.AMBER or U.GREY))
              if hb then hover.dspbtn = { fx = k, f = f, what = b[2], kid = kid } end
            end
            -- 19 окт: grp (пэды группы звучат вместе), chk (choke — обрывают друг друга), r (пэд в роутере) — строкой
            -- под пэдами в левой колонке: имя пэда в шапке целиком; щелчок — выпадашка / роутер
            local gw = 0
            if D.DR and kid.note then
              local by2 = by + bh - L.rh - 4
              local gx = bx + L.pad
              local noff, non = 0, 0
              for _, kd in ipairs(f.kids) do if kd.enabled then non = non + 1 else noff = noff + 1 end end
              local soloed = non == 1 and #f.kids > 1
              for _, gb in ipairs({ { 'kall_m', 'm', (noff > 0 and not soloed) and 1 or 0, U.RED }, { 'kall_s', 's', soloed and 1 or 0, U.GREEN },
                  { 'kgroup', 'grp', kid.group, U.CYAN }, { 'kchoke', 'chk', kid.choke, U.RED }, { 'kroute', 'r', (kid.entry and kid.entry.container) and 1 or 0, U.CYAN } }) do
                local n = gb[3] or 0
                local one = gb[1] == 'kroute' or gb[1] == 'kall_m' or gb[1] == 'kall_s'
                local gl = one and gb[2] or (n == 17 and gb[1] == 'kchoke' and 'off' or (n > 0 and (gb[2] .. n) or gb[2]))   -- 24 окт: choke 17 — «OFF обрывает»
                local bw2 = one and (ms(gb[2]) + 2 * L.pad) or (ms(gb[2] .. '16') + 2 * L.pad)
                if gx + bw2 > bx + bw1 - L.pad then break end
                local hb = not drag and mx >= gx and mx < gx + bw2 and my >= by2 and my < by2 + L.rh
                set(hb and U.tint(U.AMBER, 0.35) or (n > 0 and U.tint(gb[4], 0.25) or U.BG)); gfx.rect(gx, by2, bw2, L.rh - 1, 1)
                set(hb and U.AMBER or (n > 0 and gb[4] or U.LINE)); gfx.rect(gx, by2, bw2, L.rh - 1, 0)
                text(gx + math.floor((bw2 - ms(gl)) / 2), by2, gl, hb and U.AMBER or (n > 0 and gb[4] or U.GREY))
                if hb then hover.dspbtn = { fx = k, f = f, what = gb[1], kid = kid, ki = ks } end
                hint(gb[1], gx, by2, bw2, L.rh, { kid = kid })
                gx = gx + bw2 + 2
              end
            end
            text(cx + L.pad, hy, fit(kid.name or '', bw1 - 2 * L.pad - 2 * kb2 - 4 - gw), kid.enabled and U.CYAN or U.GREY)
          else
            text(cx + L.pad, hy, fit(('all %d slices - a change goes to every RS5K'):format(#f.kids), bw1 - 2 * L.pad), U.AMBER)
          end
          cl = {}
          local show = ks > 0 and ks or 1
          local cnt = 0
          -- 16 окт: drumrs5k — первая строка правой колонки: слоты эффектов пэда (flt eq comp dist)
          -- и str (запекание растяжки); есть эффект — голубым, его имя в подсказке
          if D.DR and kid then
            local sy = by + 2 * L.rh + 2
            local sxb = cx + L.pad
            local slots = {}
            for _, sl in ipairs(kid.slots or {}) do slots[sl.cat] = slots[sl.cat] or sl end
            local list = {}
            for _, cat in ipairs(D.DR.CATS) do list[#list + 1] = cat end
            list[#list + 1] = 'str'
            for _, cat in ipairs(list) do
              local sl = slots[cat]
              local on = sl ~= nil or (cat == 'str' and kid.baked)
              local w2 = ms(cat) + 2 * L.pad
              if sxb + w2 > cx + bw1 - L.pad then break end
              local hb = not drag and mx >= sxb and mx < sxb + w2 and my >= sy and my < sy + L.rh
              set(on and U.tint(U.CYAN, 0.3) or (hb and U.tint(U.AMBER, 0.3) or U.BG)); gfx.rect(sxb, sy, w2, L.rh - 1, 1)
              set(on and U.CYAN or (hb and U.AMBER or U.LINE)); gfx.rect(sxb, sy, w2, L.rh - 1, 0)
              text(sxb + L.pad, sy, cat, (sl and not sl.enabled) and U.GREY or (on and U.CYAN or (hb and U.AMBER or U.TEXT)))
              if hb then hover.dspbtn = { fx = k, f = f, what = 'kslot', kid = kid, cat = cat, slot = sl, ki = ks } end
              sxb = sxb + w2 + 2
            end
            cnt = 1
            -- 19 окт: волна сэмпла пэда с зоной start..end и ADSR поверх — как в модуле RS5K (показ; правка — слайдеры ниже)
            local avail = math.floor((bh - 3 * L.rh) / L.rh)
            local WR = avail >= 14 and 4 or (avail >= 9 and 3 or 0)
            if WR > 0 and kid.file then
              local wx, wy = cx + L.pad, sy + L.rh + 1
              local ww, wh = bw1 - 2 * L.pad, WR * L.rh - 3
              set(U.PANEL); rrect(wx, wy, ww, wh, true)
              set(U.LINE); rrect(wx, wy, ww, wh, false)
              local na, nb = kid.pad_a or 0, kid.pad_b or 1
              local pk = info.file_peaks and info.file_peaks(kid.file, ww)
              local cyw, hh = wy + math.floor(wh / 2), math.floor(wh / 2) - 2
              if pk and pk.n and pk.n > 0 then
                for px = 1, ww - 2 do
                  local fr = px / ww
                  set((fr >= na and fr <= nb) and U.TEXT or U.DIM)
                  local i2 = math.floor(fr * pk.n) + 1
                  local lo, hi = pk.min[i2] or 0, pk.max[i2] or 0
                  if hi - lo < 0.03 then lo, hi = -0.015, 0.015 end
                  gfx.line(wx + px, cyw - hi * hh, wx + px, cyw - lo * hh)
                end
              end
              local gx0 = wx + math.floor(na * (ww - 1) + 0.5)
              local gx1 = math.max(gx0 + 8, wx + math.floor(nb * (ww - 1) + 0.5))
              set(U.AMBER); gfx.rect(gx0, wy, 1, wh, 1); gfx.rect(gx1, wy, 1, wh, 1)
              local tA = (tonumber(kv(ks, 'attack')) or 1) / 1000
              local tD = (tonumber(kv(ks, 'decay')) or 250) / 1000
              local tR = (tonumber(kv(ks, 'release')) or 1) / 1000
              local sdb = tonumber(kv(ks, 'sustain')) or 0
              local sl = sdb <= -60 and 0 or math.min(1, 10 ^ (sdb / 20) / 2)
              local flen = info.file_len and info.file_len(kid.file)
              local dur = flen and flen > 0 and (nb - na) * flen or nil
              local pps = dur and (gx1 - gx0) / math.max(1e-3, dur) or (gx1 - gx0) / math.max(1e-3, tA + tD + tR + 0.3)
              local function X(t) return math.min(gx1, gx0 + math.floor(t * pps + 0.5)) end
              local ay0, ah0 = wy + 2, wh - 4
              local function Y(v) return ay0 + ah0 - math.floor(v * ah0) end
              local x1, x2 = X(tA), X(tA + tD)
              local x3 = math.max(x2, gx1 - math.floor(tR * pps + 0.5))
              D.L_rh = L.rh
              D.adsr_line({ { gx0, Y(0) }, { x1, Y(1) }, { x2, Y(sl) }, { x3, Y(sl) }, { gx1, Y(0) } }, U.PANEL)
              cnt = 1 + WR
            end
          end
          -- 19 окт: не влезли по высоте — следующая колонка справа (с верха), сколько колонок дал ncol_of
          local rmax = math.max(2, nfit - 2)
          local colp = 1
          -- 23 окт: параметры эффектов пэда (внуки 2..) — не в колонки сэмплера (было наслоение с цепью), а в колонки цепи
          local kd0 = D.DR and ks > 0 and f.kids[ks] or nil
          local cv = kd0 and D.pad_chain_view(kd0, kkey .. ':' .. ks) or { ncols = 0, show = {} }
          local nsl0 = cv.ncols
          local vis0 = ncol - (f._klist and 1 or 0)
          local scnt = {}
          for pi, p in ipairs(f.params) do
            if p.kid == show and not p.macro and p.gkid and p.gkid >= 2 then
              -- колонка эффекта: без цепей — внук j; с цепями — эффект m выбранной цепи (или сам выбранный эффект пэда)
              cl[pi] = { 99, 0 }   -- 23 окт: эффекты пэда — модулями за рэком
              local _ = scnt, vis0
            elseif p.kid == show and not p.macro then
              if cnt >= rmax and colp + 1 < ncol - nsl0 then colp, cnt = colp + 1, 0 end
              cl[pi] = { colp, cnt }; cnt = cnt + 1
            else cl[pi] = { 99, 0 } end
          end
          -- 24 окт: видимые параметры кита (выбранного пэда) — j / k ходят только по ним (были скрытые параметры
          -- других пэдов: выбор «не двигался»)
          D.kit_vis = D.kit_vis or {}
          local kv0 = {}
          for pi = 1, #f.params do if cl[pi] and cl[pi][1] ~= 99 then kv0[#kv0 + 1] = pi end end
          D.kit_vis[k] = kv0
          -- 23 окт: цепочка пэда — его эффекты (за сэмплером) колонками справа: имя, B x, параметры (тянуть)
          if D.DR and ks > 0 and f.kids[ks] and info.db_params then
            local kd = f.kids[ks]
            local ckey = kkey .. ':' .. ks
            local cv2 = D.pad_chain_view(kd, ckey)
            local nsl = cv2.ncols
            local vis = ncol - (f._klist and 1 or 0)
            local hy2 = by + L.rh + 1
            local c0 = 1
            if cv2.list then
              -- список цепей (как Ableton): | / = , имя, N fx, wet, on; щелчок — её эффекты справа; внизу — бросок новой цепи
              c0 = 2
              local lx = bx + (vis - nsl) * bw1
              set(U.LINE); gfx.rect(lx, by + L.rh + 1, 1, bh - L.rh - 4, 1)
              text(lx + L.pad, hy2, fit('chains', bw1 - 2 * L.pad), U.GREY)
              local tr0 = info.pool_col and info.pool_col.track
              local cw_on, cw_n, cw_w = ms('off') + L.pad, ms('9 fx') + L.pad, ms('100%')
              for r, sl in ipairs(kd.slots) do
                local ry = hy2 + r * L.rh
                if ry + 2 * L.rh > by + bh - 2 then break end
                local on = r == cv2.sel
                local hotr = not drag and mx >= lx and mx < lx + bw1 and my >= ry and my < ry + L.rh
                if on or hotr then set(on and U.tint(U.AMBER, 0.28) or D.CURROW); gfx.rect(lx + 2, ry, bw1 - 3, L.rh, 1) end
                local par = (sl.parallel or 0) > 0
                text(lx + L.pad, ry, par and '=' or '|', par and U.CYAN or U.GREY)
                local nx = lx + L.pad + ms('= ')
                local nw0 = lx + bw1 - L.pad - cw_on - cw_n - cw_w - nx
                text(nx, ry, fit(sl.name or '', nw0 - L.pad), sl.enabled and (on and U.AMBER or U.TEXT) or U.DIM)
                if sl.chain then text(nx + nw0, ry, fit(#sl.chain .. ' fx', cw_n - L.pad), U.GREY) end
                local wv = sl.wet_i and sl.wet_i >= 0 and tr0 and reaper.TrackFX_GetParamNormalized(tr0, sl.i, sl.wet_i)
                if wv then
                  local wx = nx + nw0 + cw_n
                  set(U.mix(U.LINE, U.BG, 0.3)); gfx.rect(wx, ry + L.rh // 2, cw_w - L.pad, 1, 1)
                  set(U.CYAN); gfx.rect(wx, ry + 3, math.floor((cw_w - L.pad) * wv + 0.5), L.rh - 6, 1)
                end
                local ox = lx + bw1 - L.pad - cw_on
                local hon = hotr and mx >= ox
                text(ox, ry, sl.enabled and 'on' or 'off', hon and U.AMBER or (sl.enabled and U.GREEN or U.RED))
                if hon then hover.dspbtn = { fx = k, f = f, what = 'kbypass', kid = sl }
                elseif hotr then hover.dspbtn = { fx = k, f = f, what = 'kchain', key = ckey, idx = r } end
                -- бросок на строку цепи — в конец этой цепи (эффект пэда — за ним, в цепь пэда)
                if drag and (drag.new or (drag.k and drag.k ~= k)) and mx >= lx and mx < lx + bw1 and my >= ry and my < ry + L.rh then
                  if sl.chain then hover.kitdrop = { k = k, f = f, ki = ks, kid = kd, chain = sl }
                  else hover.kitdrop = { k = k, f = f, ki = ks, kid = kd, pos = sl.gi } end
                  set(U.CYAN); gfx.rect(lx + 2, ry, bw1 - 3, L.rh, 0)
                end
              end
              local dy = hy2 + (#kd.slots + 1) * L.rh + 2
              if dy + L.rh <= by + bh - 2 then
                local dhot = drag and (drag.new or (drag.k and drag.k ~= k)) and mx >= lx and mx < lx + bw1 and my >= dy - 2 and my < by + bh - 2
                set(dhot and U.tint(U.CYAN, 0.35) or U.tint(U.CYAN, 0.08)); gfx.rect(lx + 2, dy, bw1 - 4, L.rh, 1)
                text(lx + L.pad, dy, fit('= drop fx here - a new chain', bw1 - 2 * L.pad), dhot and U.TEXT or U.GREY)
                if dhot then hover.kitdrop = { k = k, f = f, ki = ks, kid = kd, par = true } end
              end
            end
            for j = 1, #cv2.show do
              local sl = cv2.show[j]
              local cx = bx + (vis - nsl + c0 + j - 2) * bw1
              set(U.LINE); gfx.rect(cx, by + L.rh + 1, 1, bh - L.rh - 4, 1)
              local nw = D.kid_head(L, info, cx, hy2, bw1, { i = sl.i, name = sl.name, enabled = sl.enabled }, k, f, drag, mx, my, hover)
              text(cx + L.pad, hy2, fit(sl.name or '', nw), sl.enabled and U.CYAN or U.GREY)
              -- параметры — общими виджетами (раскладка cl выше), как у сэмплера
            end

          end
          -- 23 окт: тащат эффект за модуль сэмплера (правее его параметров) — те же две кнопки для выбранного пэда
          if drag and (drag.new or (drag.k and drag.k ~= k)) and D.DR and ks > 0 and f.kids[ks] and not hover.kitdrop and not cv.list then
            local ax = bx + (colp + 1) * bw1
            if bx + bw - ax < bw1 then ax = bx + bw1 end
            local ay, ah2 = by + L.rh + 2, bh - L.rh - 6
            if mx >= ax and mx < bx + bw - 2 and my >= ay and my < ay + ah2 then
              local aw = bx + bw - 2 - ax
              hover.kitdrop = { k = k, f = f, ki = ks, kid = f.kids[ks], par = mx >= ax + aw // 2 }
              D.kitdrop_cell = { ax, ay, aw, ah2 }
            end
          end
          ::kit_done::
          -- 23 окт: бросок эффекта на пэд / на цепь пэда — две половины: | serial (в цепь пэда за сэмплером) и
          -- = parallel (новая цепь внутри пэда параллельно: контейнер в контейнере)
          if D.kitdrop_cell then
            local q = D.kitdrop_cell
            D.kitdrop_cell = nil
            local hw = q[3] // 2
            local kd = hover.kitdrop
            for hi, part in ipairs({ { '|', 'serial' }, { '=', 'parallel' } }) do
              local px = q[1] + (hi - 1) * hw
              local on = kd and ((hi == 2) == (kd.par and true or false))
              set(on and U.tint(U.CYAN, 0.45) or U.tint(U.CYAN, 0.12)); gfx.rect(px, q[2], hw - 1, q[4], 1)
              set(U.CYAN); gfx.rect(px, q[2], hw - 1, q[4], 0)
              local lbl = ms(part[1] .. ' ' .. part[2]) <= hw - 2 * L.pad and (part[1] .. ' ' .. part[2]) or part[1]
              text(px + math.max(1, (hw - ms(lbl)) // 2), q[2] + (q[4] - L.rh) // 2, lbl, on and U.TEXT or U.CYAN)
            end
          end
        elseif #f.kids > 0 and (D.kit_list or {})[tostring(info.pool_col and info.pool_col.guid or '') .. ':' .. tostring(f.fguid or f.i)] == 'list' then
          -- 23 окт: контейнер списком цепей (zv) — как рэк drumrs5k: строка на ребёнка — | за предыдущим / = параллельно,
          -- имя, внутри N fx, wet (громкость цепи), on; щелчок — цепь, on — bypass; zv — обратно колонками
          set(U.tint(U.AMBER, 0.55)); gfx.rect(bx + 1, by + 1, bw - 2, bh - 2, 0)
          local ly0 = by + L.rh + 1
          local tr0 = info.pool_col and info.pool_col.track
          local ckey = tostring(info.pool_col and info.pool_col.guid or '') .. ':' .. tostring(f.fguid or f.i)
          -- 23 окт: key / vel / chain — зоны цепей (как Instrument Rack в Ableton): список слева, полосы зон справа
          D.zone_view = D.zone_view or {}
          local zk = D.zone_view[ckey]
          local Z = D.Z
          local lw = zk and math.max(ms('= name 9 fx 100% off') + 4 * L.pad, math.floor(bw * 0.38)) or bw
          if zk and lw > bw - 12 * L.cw then zk, lw = nil, bw end   -- узко — без зон
          local cw_par, cw_on, cw_wet, cw_n = ms('= '), ms('off') + L.pad, ms('100%') + L.pad, ms('99 fx') + L.pad
          local nx0 = bx + L.pad + cw_par
          local nw0 = lw - 2 * L.pad - cw_par - cw_on - cw_wet - cw_n
          -- шапка: key vel chain (кнопки, 2 положения: показан / нет) и подсказка
          local hx = bx + L.pad
          for _, zb in ipairs({ { 'key', 'key' }, { 'vel', 'vel' }, { 'chain', 'sel' } }) do
            local w0 = ms(zb[1]) + 2 * L.pad
            local on = D.zone_view[ckey] == zb[2]
            local hb = not drag and mx >= hx and mx < hx + w0 and my >= ly0 and my < ly0 + L.rh
            set(hb and U.tint(U.AMBER, 0.3) or (on and U.tint(U.AMBER, 0.25) or U.BG)); gfx.rect(hx, ly0, w0, L.rh - 1, 1)
            set(hb and U.AMBER or U.LINE); gfx.rect(hx, ly0, w0, L.rh - 1, 0)
            text(hx + L.pad, ly0, zb[1], (hb or on) and U.AMBER or U.GREY)
            if hb then hover.dspbtn = { fx = k, f = f, what = 'kzone', key = ckey, kind = zb[2] } end
            hx = hx + w0 + 2
          end
          if not zk then text(hx + L.pad, ly0, fit('| serial  = parallel   zv - columns', bx + bw - hx - 2 * L.pad), U.GREY) end
          set(U.LINE); gfx.rect(bx + L.pad, ly0 + L.rh, bw - 2 * L.pad, 1, 1)
          -- линейка зон: над полосами (в строке шапки, правее кнопок)
          local zx = bx + lw
          local zw = bx + bw - L.pad - zx
          local function X(v) return zx + math.floor(v / 128 * zw + 0.5) end
          local sels = {}
          if zk then
            set(U.LINE); gfx.rect(zx - 1, ly0 + L.rh + 1, 1, bh - 2 * L.rh - 4, 1)
            local last = -1e9
            for v = 0, 127 do
              local tick = zk == 'key' and v % 12 == 0 or (zk ~= 'key' and v % 32 == 0)
              if tick then
                set(U.mix(U.LINE, U.BG, 0.4)); gfx.rect(X(v), ly0 + L.rh + 1, 1, bh - 2 * L.rh - 4, 1)
                local lb = Z.label(zk, v)
                if X(v) > last + L.pad and X(v) + ms(lb) < zx + zw and X(v) > hx + L.pad then text(X(v) + 2, ly0, lb, U.GREY); last = X(v) + ms(lb) end
              end
            end
          end
          for ki, kid in ipairs(f.kids) do
            local ry = ly0 + L.rh + 2 + (ki - 1) * L.rh
            if ry + L.rh > by + bh - 2 then break end
            local hotr = not drag and mx >= bx and mx < bx + lw and my >= ry and my < ry + L.rh
            local issel = is_sel and info.dsp_kid == ki
            if hotr or issel then set(issel and U.tint(U.AMBER, 0.25) or D.CURROW); gfx.rect(bx + 2, ry, lw - 4, L.rh, 1) end
            local par = (kid.parallel or 0) > 0 and ki > 1
            text(bx + L.pad, ry, par and '=' or '|', par and U.CYAN or U.GREY)
            local nfx = kid.container and ((tr0 and select(2, reaper.TrackFX_GetNamedConfigParm(tr0, kid.i, 'container_count'))) or '?') or nil
            text(nx0, ry, fit((kid.container and '[' or '') .. (kid.name or '') .. (kid.container and ']' or ''), nw0 - L.pad), kid.enabled and (hotr and U.AMBER or U.TEXT) or U.GREY)
            local xn = nx0 + nw0
            if nfx then text(xn, ry, fit(tostring(nfx) .. ' fx', cw_n - L.pad), U.GREY) end
            local wv = kid.wet_i and kid.wet_i >= 0 and tr0 and reaper.TrackFX_GetParamNormalized(tr0, kid.i, kid.wet_i)
            if wv then
              local wx = xn + cw_n
              set(U.mix(U.LINE, U.BG, 0.3)); gfx.rect(wx, ry + L.rh // 2, cw_wet - L.pad, 1, 1)
              set(U.CYAN); gfx.rect(wx, ry + 3, math.floor((cw_wet - L.pad) * wv + 0.5), L.rh - 6, 1)
            end
            local ox = bx + lw - L.pad - cw_on
            local hon = hotr and mx >= ox
            text(ox, ry, kid.enabled and 'on' or 'off', hon and U.AMBER or (kid.enabled and U.GREEN or U.RED))
            if hon then hover.dspbtn = { fx = k, f = f, what = 'kbypass', kid = kid }
            elseif hotr then hover.dspkid = { k = k, f = f, ki = ki, kid = kid } end
            if zk then
              -- полоса зоны: скаты — клиньями, полная часть — заливкой; без плагина зоны — вся ширина бледно
              local zz = info.zone_read and info.zone_read(tr0, kid)
              if zz then sels[#sels + 1] = zz.addr end
              local z = zz and zz[zk] or { lo = Z.MIN[zk], hi = 127, flo = Z.MIN[zk], fhi = 127 }
              local y0, y1 = ry + 2, ry + L.rh - 2
              local xl, xfl, xfh, xh = X(z.lo), X(z.flo), X(z.fhi + 1), X(z.hi + 1)
              local col = zz and (kid.enabled and U.GREEN or U.GREY) or U.DIM
              set(U.tint(col, 0.55)); gfx.rect(xfl, y0, math.max(1, xfh - xfl), y1 - y0, 1)
              if xfl > xl then gfx.triangle(xl, y1, xfl, y0, xfl, y1) end
              if xh > xfh then gfx.triangle(xfh, y0, xh, y1, xfh, y1) end
              set(col); gfx.rect(xl, y0 - 1, math.max(1, xh - xl), 1, 1)
              -- мышь: край (±4 px) — lo / hi; в верхней половине у скатов — flo / fhi; внутри — сдвиг всей зоны
              if not drag and my >= ry and my < ry + L.rh and mx >= zx and mx < zx + zw then
                local what
                local top = my < ry + L.rh // 2
                if top and math.abs(mx - xfl) <= 4 then what = 'flo'
                elseif top and math.abs(mx - xfh) <= 4 then what = 'fhi'
                elseif math.abs(mx - xl) <= 4 then what = 'lo'
                elseif math.abs(mx - xh) <= 4 then what = 'hi'
                elseif mx > xl and mx < xh then what = 'move' end
                if what then
                  hover.zone = { kind = zk, what = what, zaddr = zz and zz.addr, z = z, x0 = zx, w = zw, c = f.i, k = ki - 1 }
                  set(U.AMBER)
                  local ex = what == 'lo' and xl or (what == 'hi' and xh or (what == 'flo' and xfl or (what == 'fhi' and xfh or nil)))
                  if ex then gfx.rect(ex - 1, y0 - 1, 2, y1 - y0 + 2, 1) else gfx.rect(xl, y0 - 1, math.max(1, xh - xl), y1 - y0 + 2, 0) end
                end
              end
            end
          end
          -- chain: бегунок select (общий регулятор) в линейке — тянуть; цепи звучат, где он внутри их зоны
          if zk == 'sel' and #sels > 0 then
            local z1 = info.zone_read(tr0, f.kids[1])
            local sv = 0
            for _, kd in ipairs(f.kids) do local zz = info.zone_read(tr0, kd); if zz then sv = zz.select; break end end
            local sx = X(sv + 0.5)
            set(U.AMBER); gfx.rect(sx - 1, ly0 + 2, 3, bh - L.rh - 6, 1)
            if not drag and my >= ly0 and my < ly0 + L.rh and mx >= zx and mx < zx + zw then
              hover.zone = { kind = 'sel', what = 'select', x0 = zx, w = zw, sels = sels, c = f.i, k = 0, z = z1 and z1.sel }
            end
          end
          cl = {}
          for pi in ipairs(f.params) do cl[pi] = { 99, 0 } end
        elseif #f.kids > 0 and ncol >= ((f.has_macros and 1 or 0) + select(2, D.kid_pack(f, nfit - 2))) then
          -- развёрнут (6 окт): контейнер — рамка, внутри колонка на каждый
          -- плагин: имя (| за предыдущим, = параллельно, + с суммой) и его
          -- параметры тем же модулем, что на верхнем уровне; макросы — первой
          -- колонкой; низ — строка броска
          local base = f.has_macros and 1 or 0
          set(U.tint(U.AMBER, 0.55)); gfx.rect(bx + 1, by + 1, bw - 2, bh - 2, 0)
          local hy = by + L.rh + 1
          if base == 1 then text(bx + L.pad, hy, fit('macros', bw1 - 2 * L.pad), U.GREY) end
          local place = D.kid_pack(f, nfit - 2)
          for ki, kid in ipairs(f.kids) do
            local pl = place[ki]
            local c = base + pl.c
            if c >= ncol then break end
            local cx = bx + c * bw1
            if c > 0 and pl.hr < 0 then set(U.LINE); gfx.rect(cx, by + L.rh + 1, 1, bh - 2 * L.rh - 4, 1) end
            local hy = hy
            if pl.hr >= 0 then   -- 23 окт: под предыдущим в той же колонке — заголовок строкой, черта над ним
              hy = by + 2 * L.rh + 2 + pl.hr * L.rh
              set(U.LINE); gfx.rect(cx + L.pad, hy - 1, bw1 - 2 * L.pad, 1, 1)
            end
            -- B / x у каждого плагина внутри (6 окт): bypass / удалить без выбора блока
            local kb2 = ms('x') + 2 * L.pad
            local onw = ms('off') + 2 * L.pad   -- 24 окт: on / off вместо B
            local kbx = { { 'x', 'kdel', cx + bw1 - kb2 - 1 }, { kid.enabled and 'on' or 'off', 'kbypass', cx + bw1 - kb2 - onw - 3, onw } }
            local onb = false
            for _, b in ipairs(kbx) do
              local kb2 = b[4] or kb2
              local hb = not drag and mx >= b[3] and mx < b[3] + kb2 and my >= hy and my < hy + L.rh
              local lit = b[2] == 'kbypass' and not kid.enabled
              set(hb and U.tint(b[2] == 'kdel' and U.RED or U.AMBER, 0.35) or (lit and U.tint(U.AMBER, 0.25) or U.BG)); gfx.rect(b[3], hy, kb2, L.rh - 1, 1)
              set(hb and (b[2] == 'kdel' and U.RED or U.AMBER) or U.LINE); gfx.rect(b[3], hy, kb2, L.rh - 1, 0)
              text(b[3] + L.pad, hy, b[1], hb and (b[2] == 'kdel' and U.RED or U.AMBER) or (lit and U.AMBER or U.GREY))
              if hb then hover.dspbtn = { fx = k, f = f, what = b[2], kid = kid }; onb = true end
            end
            local nxt = place[ki + 1]
            local ybot = (nxt and nxt.c == pl.c) and (by + 2 * L.rh + 2 + nxt.hr * L.rh) or (by + bh - L.rh - 2)
            local hot = not drag and not onb and mx >= cx and mx < cx + bw1 and my >= hy and my < ybot
            text(cx + L.pad, hy, kid_label(kid, bw1 - 2 * L.pad - 2 * kb2 - 4), kid.enabled and (hot and U.AMBER or U.CYAN) or U.GREY)
            if hot then hover.dspkid = { k = k, f = f, ki = ki, kid = kid } end
          end
          cl = {}
          local cnt = {}
          for pi, p in ipairs(f.params) do
            if p.macro then
              cnt.m = (cnt.m or 0) + 1; cl[pi] = { 0, cnt.m - 1 }
            else
              local pl = place[p.kid or 1] or { c = (p.kid or 1) - 1, r0 = 0 }
              local key = p.kid or 1
              cnt[key] = (cnt[key] or 0) + 1
              cl[pi] = { base + pl.c, pl.r0 + cnt[key] - 1 }
            end
          end
          if nfit >= 3 then drop_row(bx + L.pad, by + bh - L.rh - 2, bw - 2 * L.pad) end
        else
          -- свёрнут (не влез / пустой): список детей и строка броска
          pcol0 = 1
          local ky = by + L.rh + 1
          if #f.kids == 0 then
            -- 24 окт: пустой контейнер — рамка-гнездо с подсказкой: что в него класть
            local ex, ey, ew, eh = bx + L.pad, ky + 2, bw - 2 * L.pad, by + bh - ky - L.rh - 6
            if eh >= 3 * L.rh then
              local lit = drag and mx >= ex and mx < ex + ew and my >= ey and my < ey + eh
              set(lit and U.tint(U.CYAN, 0.25) or U.tint(U.CYAN, 0.06)); gfx.rect(ex, ey, ew, eh, 1)
              set(lit and U.CYAN or U.tint(U.CYAN, 0.5))
              for dx = 0, ew - 1, 6 do gfx.rect(ex + dx, ey, math.min(3, ew - dx), 1, 1); gfx.rect(ex + dx, ey + eh - 1, math.min(3, ew - dx), 1, 1) end
              for dy = 0, eh - 1, 6 do gfx.rect(ex, ey + dy, 1, math.min(3, eh - dy), 1); gfx.rect(ex + ew - 1, ey + dy, 1, math.min(3, eh - dy), 1) end
              local lines = { { 'empty container', U.TEXT }, { 'drop an fx here', U.GREY }, { 'or a container', U.GREY }, { '[] - a container inside', U.DIM } }
              local ty0 = ey + math.max(2, math.floor((eh - #lines * L.rh) / 2))
              for li, ln in ipairs(lines) do
                local yy = ty0 + (li - 1) * L.rh
                if yy + L.rh <= ey + eh - 1 then
                  local s0 = fit(ln[1], ew - 2 * L.pad)
                  text(ex + math.max(L.pad, math.floor((ew - ms(s0)) / 2)), yy, s0, lit and U.CYAN or ln[2])
                end
              end
              ky = ey + eh + 2
            end
          end
          for ki, kid in ipairs(f.kids) do
            if ki > nfit - 1 then break end
            local kx = bx + L.pad
            set(kid.parallel > 0 and U.CYAN or U.LINE); gfx.rect(kx + L.cw // 2, ky, 2, L.rh, 1)
            if kid.parallel > 0 then gfx.rect(kx + L.cw // 2 + 4, ky, 2, L.rh, 1) end
            local kb2 = ms('x') + 2 * L.pad
            local xb = bx + bw - kb2 - L.pad
            local hb = not drag and mx >= xb and mx < xb + kb2 and my >= ky and my < ky + L.rh
            set(hb and U.tint(U.RED, 0.35) or U.BG); gfx.rect(xb, ky, kb2, L.rh - 1, 1)
            set(hb and U.RED or U.LINE); gfx.rect(xb, ky, kb2, L.rh - 1, 0)
            text(xb + L.pad, ky, 'x', hb and U.RED or U.GREY)
            if hb then hover.dspbtn = { fx = k, f = f, what = 'kdel', kid = kid } end
            local hot = not drag and not hb and mx >= bx and mx < bx + bw and my >= ky and my < ky + L.rh
            text(kx + L.cw + L.pad, ky, kid_label(kid, pw - L.cw - 3 * L.pad - kb2), kid.enabled and (hot and U.AMBER or U.TEXT) or U.GREY)
            if hot then hover.dspkid = { k = k, f = f, ki = ki, kid = kid } end
            ky = ky + L.rh
          end
          if ky + L.rh <= by + bh - 2 then drop_row(bx + L.pad, ky, pw) end
        end
      end
      if f.view == 'grain' then
        -- гранулятор: облако — 16 колонок волны, точки зёрен (свежее выше),
        -- окно зума, позиция головки зёрен, голова записи (красная)
        local wx, wy, ww, wh = bx + L.pad, by + L.rh + 1, pw, bh - L.rh - 4
        if wtop > 0 then ww, wh = bw - 2 * L.pad, wtop_wh else pcol0 = 1 end
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
      D.pmark('dsp: modules')
      if f.view == 'slixer' and f.slx_geo then
        D.pmark('dsp: slixer')
        -- 25 окт: пульт 1 в 1 с окном плагина (jf_tracker_slxpanel.lua)
        local G = f.slx_geo
        local v = G.v
        local x0, y0, w0 = bx + L.pad, by + L.rh + 1, bw - 2 * L.pad
        local hb = D.SX.draw_buttons(U, L, G.lay, text, ms, set, mx, my, drag)
        if hb then hover.slx = { fx = k, f = f, it = hb.it, x = hb.x, y = hb.y, w = hb.w, h = hb.h } end
        -- 31 окт: слоты быстрой загрузки — строкой в самом низу модуля (как было в окне плагина)
        if info.slx_slots then D.slx_slots(L, info, f, k, x0, x0 + w0, by + bh - L.rh - 2, hover, mx, my, drag) end
        local wy = y0 + (G.nbr - (G.nb2 or 0)) * L.rh
        D.slx_zoom = D.slx_zoom or {}
        local zst = D.slx_zoom[f.i]
        local ovh = L.rh - 3
        -- 26 окт: прицел (снайперский зум края, как в слайсере) — под волной, ~40 % высоты при 6+ строках
        local zr = G.wr >= 6 and math.floor(G.wr * 0.42) or 0
        if zr > 0 then zr = zr + 1 end   -- 27 окт: прицел на строку выше, волна на строку ниже
        local wh = (G.wr - zr) * L.rh - (zr > 0 and 2 or 0)
        local dr = D.slx_drag and D.slx_drag.fi == f.i and D.slx_drag or nil
        -- 26 окт: опция aim zoom on top (общая со слайсером) — прицел над волной
        local atop = zr > 0 and info.slx_aimtop and info.slx_aimtop()
        -- 27 окт: сверху вниз — обзор (скролл), прицел, волна
        local aim_y = wy
        local wave_y
        if atop then aim_y = wy + ovh + 1; wave_y = aim_y + zr * L.rh + 1 end
        -- 27 окт: опция scroll under the sample — обзор (скролл) под волной: [прицел] волна обзор (без новых локалей: D.slx_ovy)
        D.slx_ovy = nil
        if info.slx_ovbelow and info.slx_ovbelow() then
          if atop then aim_y = wy; wave_y = wy + zr * L.rh + 1 else wave_y = wy end
          D.slx_ovy = wave_y + wh + 1
        end
        local hw = D.SX.draw_wave(U, L, v, x0, D.slx_ovy or wy, w0, ovh, wh, text, ms, set, mx, my, zst, drag or dr, dr, wave_y)
        if hw then hover.slxwave = { fx = k, f = f, w = hw } end
        local sy = D.slx_ovy and (D.slx_ovy + ovh + 1) or ((wave_y or (wy + ovh + 1)) + wh + 1)   -- строка статуса сразу под волной (или под обзором)
        -- 26 окт: MIDI · ARP — в самом низу модуля, под группами параметров (как в окне плагина)
        local lay2 = {}
        if (G.nb2 or 0) > 0 then
          lay2 = D.SX.layout(G.low, x0, by + bh - G.nb2 * L.rh - 2, w0, L.rh, ms, L.pad)
          local hb2 = D.SX.draw_buttons(U, L, lay2, text, ms, set, mx, my, drag)
          if hb2 then hover.slx = { fx = k, f = f, it = hb2.it, x = hb2.x, y = hb2.y, w = hb2.w, h = hb2.h } end
        end
        if not atop then aim_y = sy end
        -- 26 окт: по высоте не влез (стандартная высота DSP) — прицел справа от групп параметров, на их высоту
        local ax, aw2, ah = x0, w0, zr * L.rh
        local side = false
        if zr == 0 and not G.noparams and f.groups and f.rows then
          local px = bx + #f.groups * bw1 + L.pad
          local pw2 = bx + bw - L.pad - px
          if pw2 >= L.cw * 24 then side = true; ax, aw2, ah, aim_y = px, pw2, (f.rows + 1) * L.rh - 2, by + L.rh + 1 + wtop end
        end
        if (zr > 0 or side) and v and v.frames and v.frames > 0 then
          D.slx_aim = D.slx_aim or {}
          -- 28 окт: прицел — всегда выбранный срез (нажатый мидью / клавиатурой / мышью / новый), не граница под мышью
          -- и не срез, что звучит в thru; тянется граница — она
          local edge = (dr and dr.edge) or ((v.sel and v.sel >= 0) and (v.sel + 1)) or D.slx_aim[f.i]
          if edge and not (v.starts and v.starts[edge]) then edge = nil end
          local ns = D.slx_newsel   -- новый срез дошёл до slixer — выбрать его (прицел сразу на нём)
          if ns and ns.fi == f.i and v.starts then
            if reaper.time_precise() > ns.t then D.slx_newsel = nil
            else
              for i = 1, v.nsl or 0 do
                if v.starts[i] and math.abs(v.starts[i] - ns.frame) < 64 then
                  D.slx_newsel = nil; edge = i
                  if v.sel ~= i - 1 and info.slx_select then info.slx_select(i - 1) end
                  break
                end
              end
            end
          end
          if edge and v.starts[edge] then D.slx_aim[f.i] = edge end
          local sr = math.max(1, v.sr or 48000)
          local w2 = math.floor((D.slx_zwin or 0.04) * sr)
          local center = edge and ((dr and dr.edge == edge and dr.fine and dr.fine.base) or v.starts[edge]) or 0
          local A = edge and { edge = edge, center = center, w2 = w2, spam = info.slx_spam and info.slx_spam(), fine = dr and dr.edge == edge and dr.frame or nil } or nil
          if A and info.slx_aim then A.pk = info.slx_aim(center - w2, 2 * w2, math.min(aw2, 2 * w2)) end
          local zy = aim_y
          local ha = D.SX.draw_aim(U, L, v, ax, zy, aw2, ah, text, ms, set, mx, my, A, drag or dr)
          if ha then hover.slxaim = { fx = k, f = f, a = ha } end
          if not atop and not side then sy = zy + zr * L.rh + 1 end
        end
        local st
        if v and v.frames and v.frames > 0 then
          st = ('%d Hz  %.2fs  %d slices%s'):format(math.floor(v.sr or 0), v.frames / math.max(1, v.sr or 48000), v.nsl, v.sel >= 0 and ('  sel %d'):format(v.sel + 1) or '')
        elseif v and v.other then st = 'shown on the first slixer of the chain'
        elseif v and v.old then st = 'update jf_slixer (no tracker view)'
        elseif v and v.wait then st = 'waiting for slixer...'
        else st = 'empty - x in the lib / browser menu, or drop a file on the wave' end
        text(x0, sy, fit(st, w0), U.GREY)
        for _, ly in ipairs({ G.lay, lay2 }) do
          for _, b in ipairs(ly) do if b.it.kind ~= 'zone' then hint('slx', b.x, b.y, b.w, L.rh - 1, { fx = k, f = f, it = b.it, x = b.x, y = b.y, w = b.w, h = L.rh - 1 }) end end
        end
      elseif f.view == 'slixer' then
        -- slixer (9 окт): волна деки во всю первую колонку; срезы — чередующейся
        -- подложкой и линией начала, выбранный — янтарём, играющие голоса —
        -- зелёными головками; внизу — число срезов и длина
        local wx, wy, ww, wh = bx + L.pad, by + L.rh + 1, pw, bh - 2 * L.rh - 4
        if wtop > 0 then ww, wh = bw - 2 * L.pad, wtop_wh else pcol0 = 1 end
        local v = info.dsp_view and info.dsp_view('slixer', f.i)
        -- 11 окт: бросок файла (браузер / lib) на волну — сэмпл в этот slixer
        if mx >= wx and mx < wx + ww and my >= wy and my < wy + math.max(4, wh) then hover.slxwave = { fx = k, f = f } end
        set(U.PANEL); gfx.rect(wx, wy, ww, math.max(4, wh), 1)
        set(U.LINE); gfx.rect(wx, wy, ww, math.max(4, wh), 0)
        local st, stc = '', U.DIM
        if v and v.frames and v.frames > 0 and wh > 6 then
          local fr = v.frames
          local function xof(p) return wx + math.floor(math.max(0, math.min(1, p / fr)) * (ww - 1)) end
          for i = 1, v.nsl do
            local a, b = xof(v.starts[i] or 0), xof(v.ends[i] or 0)
            if b > a then
              if i - 1 == v.sel then set(U.tint(U.AMBER, 0.28)) elseif i % 2 == 0 then set(U.tint(U.TEXT, 0.06)) else set(U.PANEL) end
              gfx.rect(a, wy + 1, b - a, wh - 2, 1)
            end
          end
          local pk = v.peaks
          local cy, hh = wy + wh / 2, wh / 2 - 1
          if pk and (pk.n or 0) > 0 then
            set(U.readable(U.mix(U.CYAN, U.TEXT, 0.3), U.PANEL, 4.0))
            for px = 0, ww - 1 do
              local i = math.floor(px / ww * pk.n) + 1
              local mxv, mnv = pk.max[i] or 0, pk.min[i] or 0
              if mxv - mnv < 0.01 then mxv, mnv = 0.005, -0.005 end
              gfx.line(wx + px, cy - math.min(1, mxv) * hh, wx + px, cy - math.max(-1, mnv) * hh)
            end
          end
          for i = 1, v.nsl do
            set(i - 1 == v.sel and U.AMBER or U.mix(U.LINE, U.TEXT, 0.35)); gfx.rect(xof(v.starts[i] or 0), wy + 1, 1, wh - 2, 1)
          end
          set(U.GREEN)
          for _, p in ipairs(v.voices) do gfx.rect(xof(p), wy, 1, wh, 1) end
          st = ('%d slices  %.2fs%s'):format(v.nsl, fr / math.max(1, v.sr or 48000), v.sel >= 0 and ('  sel %d'):format(v.sel + 1) or '')
          stc = v.alive and U.GREY or U.DIM
        elseif v and v.other then st = 'wave: shown on the first slixer of the chain'
        elseif v and v.old then st = 'wave: update jf_slixer (no tracker view)'
        elseif v and v.wait then st = 'wave: waiting for slixer...'
        else st = 'wave: empty deck (load or record a sample)' end
        text(wx, wy + math.max(4, wh) + 2, fit(st, ww), stc)
      end
      local eq_only = f.view == 'eq' and info.eqgraph            -- ReaEQ: только график, во весь блок
      if f.view and D.FX_VIEWS[f.view] and not (f.view == 'eq' and not info.eqgraph) then
        -- вид встроенного эффекта REAPER (4 окт) — первая колонка
        pcol0 = 1
        VRH = L.rh
        D.eq_hit = nil
        D.fx_view(f.view, f, vals, bx + L.pad, by + L.rh + 1, eq_only and (bw - 2 * L.pad) or pw, bh - L.rh - 4)
        -- ReaEQ: щелчок в виде хватает ближайшую точку полосы (не блок)
        local eh = f.view == 'eq' and D.eq_hit
        if eh and not drag and mx >= eh.x and mx < eh.x + eh.w and my >= eh.y and my < eh.y + eh.h and #eh.pts > 0 then
          local best, bd
          for _, pt in ipairs(eh.pts) do local d = (pt.x - mx) ^ 2 + (pt.y - my) ^ 2; if not bd or d < bd then best, bd = pt, d end end
          hover.dspeq = { fx = k, f = f, band = best.i, hit = eh }
        end
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
        local qx, qy = f.params[f.xy_x], f.params[f.xy_y]
        if D.slr and qx and qy then D.slr[#D.slr + 1] = { g = 'dspxy:' .. tostring(k), dsp = true, xy = { qx.fx or f.i, qx.i, qy.fx or f.i, qy.i }, name = f.name or 'XY', x = px0, y = py0, w = side, h = side } end   -- 14 окт: CONTROL — XY
      end
      if not f.xy and not f.view and not f.container and not f.kit and not f.rs5k and not f.wave then D.xy2(L, info, f, k, vals, bx, by, bw, bh, pw, hover, mx, my, drag) end   -- 31 окт: zx
      if f.wave then
        -- сэмплер (RS5K): волна файла с зоной start..end, ручки тянутся мышью,
        -- бросок файла из браузера — новый сэмпл
        pcol0 = 1
        local wx, wy = bx + L.pad, by + L.rh + 1
        local ww, wh = pw, bh - L.rh - 4
        -- 10 окт: полосой сверху во всю ширину блока; над ней строка кнопок (режим, файлы, pitch)
        if wtop > 0 then
          pcol0 = 0
          ww, wh = bw - 2 * L.pad, wtop_wh
          local bxr = wx
          local mode = f.rs5k_mode
          local function rbtn(lbl, what, on)
            local w2 = ms(lbl) + 2 * L.pad
            if bxr + w2 > wx + ww then return end
            local hot = not drag and mx >= bxr and mx < bxr + w2 and my >= wy and my < wy + L.rh
            set(on and U.tint(U.CYAN, 0.3) or (hot and U.tint(U.AMBER, 0.3) or U.BG)); gfx.rect(bxr, wy, w2, L.rh - 1, 1)
            set(on and U.CYAN or (hot and U.AMBER or U.LINE)); gfx.rect(bxr, wy, w2, L.rh - 1, 0)
            text(bxr + L.pad, wy, lbl, on and U.CYAN or (hot and U.AMBER or U.TEXT))
            if hot then hover.rs5k = { fx = k, f = f, what = what } end
            bxr = bxr + w2 + 2
          end
          rbtn('freely', 'mode0', mode == 0); rbtn('sample', 'mode1', mode == 1); rbtn('note', 'mode2', mode == 2)
          bxr = bxr + L.pad
          rbtn('browse', 'browse'); rbtn('item', 'item'); rbtn('list' .. ((f.rs5k_n or 0) > 1 and (' ' .. f.rs5k_n) or ''), 'list'); rbtn('detect pitch', 'detect')
          wy = wy + L.rh
        end
        local na = f.wave_a and vals[f.wave_a] and vals[f.wave_a].n or 0
        local nb = f.wave_b and vals[f.wave_b] and vals[f.wave_b].n or 1
        set(U.PANEL); gfx.rect(wx, wy, ww, wh, 1)
        set(U.LINE); gfx.rect(wx, wy, ww, wh, 0)
        local name = f.file and (f.file:match('[^/]+$') or f.file) or 'no sample - drop a file from the browser here'
        local th = L.rh
        text(wx + 2, wy + 1, fit(name, (f.rs5k and math.floor(ww * 0.64) or ww) - 4), f.file and U.GREY or U.DIM)   -- 10 окт: справа — ADSR
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
        -- 10 окт: ADSR прямо на волне, во времени сэмпла: атака от start, release кончается
        -- на end зоны (нота «держится» до конца звука); три ручки тянутся мышью
        if f.rs5k and wh > 3 * L.rh then
          local function pv(sub) for pi2, p2 in ipairs(f.params) do if p2.name == sub then return vals[pi2] end end end
          local at, de, su, re = pv('attack'), pv('decay'), pv('sustain'), pv('release')
          if at and de and su and re then
            local gx0 = wx + math.floor(na * (ww - 1) + 0.5)
            local gx1 = math.max(gx0 + 8, wx + math.floor(nb * (ww - 1) + 0.5))
            local ay0, ah0 = gy + 2, math.max(4, gh - 4)
            local tA = (tonumber(at.s) or 1) / 1000; local tD = (tonumber(de.s) or 250) / 1000; local tR = (tonumber(re.s) or 1) / 1000
            local sdb = tonumber(su.s) or 0
            local sl = sdb <= -60 and 0 or math.min(1, 10 ^ (sdb / 20) / 2)   -- 0 dB — половина высоты (как в RS5K: sustain до +6)
            local flen = f.file and info.file_len and info.file_len(f.file)
            local dur = flen and flen > 0 and (nb - na) * flen or nil
            local pps = dur and (gx1 - gx0) / math.max(1e-3, dur) or (gx1 - gx0) / math.max(1e-3, tA + tD + tR + 0.3)
            local function X(t) return math.min(gx1, gx0 + math.floor(t * pps + 0.5)) end
            local function Y(v) return ay0 + ah0 - math.floor(v * ah0) end
            local x1, x2 = X(tA), X(tA + tD)
            local x3 = math.max(x2, gx1 - math.floor(tR * pps + 0.5))
            local lab = ('A %s  D %s  S %s  R %s'):format(at.s, de.s, su.s, re.s)
            text(wx + ww - ms(lab) - 4 >= wx + math.floor(ww * 0.4) and (wx + ww - ms(lab) - 4) or (wx + math.floor(ww * 0.4)), wy + 1, fit(lab, math.floor(ww * 0.6) - 4), U.GREEN)
            local hs = { { 'a', x1, Y(1) }, { 'ds', x2, Y(sl) }, { 'r', x3, Y(sl) } }
            local near, nd
            if not drag and mx >= wx and mx < wx + ww and my >= wy and my < wy + wh then
              for _, hp in ipairs(hs) do local dd = math.abs(mx - hp[2]) + math.abs(my - hp[3]); if dd <= 1.5 * L.rh and (not nd or dd < nd) then near, nd = hp[1], dd end end
            end
            local ad = info.adsr_drag and info.adsr_drag()
            -- 19 окт: линия и ромбики на узлах (ручки a / ds / r — узлы 2..4) одной функцией с волной пэда
            local hot_i
            for hi, hp in ipairs(hs) do if (near == hp[1]) or (ad and ad.f == f and ad.part == hp[1]) then hot_i = hi + 1 end end
            D.L_rh = L.rh
            D.adsr_line({ { gx0, Y(0) }, { x1, Y(1) }, { x2, Y(sl) }, { x3, Y(sl) }, { gx1, Y(0) } }, U.PANEL, hot_i)
            if near then hover.dspadsr = { fx = k, f = f, part = near, w = math.max(1, gx1 - gx0), h = ah0 } end
          end
        end
        if not drag and not hover.dspadsr and mx >= wx and mx < wx + ww and my >= wy and my < wy + wh then
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
      -- 13 окт: секции (f.heads[pi] — заголовок перед параметром): поток по колонкам, заголовок —
      -- своя строка (янтарь + линия), внизу колонки не остаётся — переносится с секцией
      local spos
      local tall = false   -- 22 окт: есть параметр-столбик (5..8 положений) — поток с высотой
      for _, p0 in ipairs(f.params) do if D.param_rows(p0, nfit) > 1 then tall = true; break end end
      if (f.heads or tall) and not cl and not grp then
        spos = D.param_flow(f.params, f.heads, nfit, pcol0)
        for pi, hp in pairs(spos.heads) do
          local hy = by + L.rh + 1 + aw_off + hp[2] * L.rh
          if hp[1] < ncol and nfit >= 2 then
            local hx = bx + hp[1] * bw1 + L.pad
            set(U.LINE); gfx.rect(hx, hy + L.rh - 2, pw, 1, 1)
            local hc = f.headcol and ({ red = U.RED, orange = U.AMBER, yellow = U.YELLOW, cyan = U.CYAN, green = U.GREEN })[f.headcol[f.heads[pi]] or ''] or U.AMBER   -- 27 окт: цвет секции (Cosmos)
            text(hx, hy, fit(f.heads[pi], pw), hc)
          end
        end
      end
      -- 22 окт: attack decay sustain release подряд в одной колонке — графиком огибающей на их 4 строки (ромбы на узлах)
      -- 22 окт (2): любая группа A [H] D S R с общим префиксом и формами между узлами (Serum A H D S R, Surge с shape) —
      -- D.FP.adsr_groups; график на все её строки, если группа целиком в одной колонке
      local adsr_of = {}
      if not cl and not grp and D.FP then
        local names = {}
        for pi0, p0 in ipairs(f.params) do names[pi0] = p0.name or '' end
        for a0, g in pairs(D.FP.adsr_groups(names)) do
          local okc
          if spos then okc = spos[a0] and spos[g.last] and spos[a0][1] == spos[g.last][1] and spos[g.last][2] - spos[a0][2] == g.last - a0
          else okc = math.floor((a0 - 1) / nfit) == math.floor((g.last - 1) / nfit) end
          if okc then g.first = a0; for q = a0, g.last do adsr_of[q] = g end end
        end
      end
      for pi, p in ipairs(f.params) do
        if eq_only then break end
        if p.mfader and mw > 0 then goto next_param end   -- 22 окт: макрос — фейдером слева
        if spos then if spos[pi][1] >= ncol then break end
        elseif not cl and pi > nfit * (ncol - pcol0) then break end
        local colk = spos and spos[pi][1] or (pcol0 + math.floor((pi - 1) / nfit))
        local py = by + L.rh + 1 + aw_off + (spos and spos[pi][2] or ((pi - 1) % nfit)) * L.rh
        if grp and (pi - 1) % nfit == 0 then
          local gt = f.groups[math.floor((pi - 1) / nfit) + 1]
          if gt then text(bx + colk * bw1 + L.pad, by + L.rh + 1 + wtop, fit(gt, pw), U.AMBER) end
        end
        if cl then
          -- развёрнутый контейнер: своя колонка у каждого плагина, под именем;
          -- последняя строка — строка броска
          local c = cl[pi]
          if c[1] >= ncol or c[2] >= nfit - 2 then goto next_param end
          colk, py = c[1], by + 2 * L.rh + 2 + c[2] * L.rh
        end
        local bxc = bx + colk * bw1
        -- rec (4 окт): параметры — снизу справа, под волной, последней строкой вверх
        if f.view == 'rec' then bxc = bx + bw - bw1; py = by + bh - (#f.params - pi + 2) * L.rh - 3 end   -- строка статуса, справа
        local v = vals[pi] or { n = 0, s = '' }
        local psel = is_sel and sel.param == pi
        local pins = psel and info.dsp_ins   -- 22 окт: INSERT параметра (i) — красным, набор вместо значения
        -- 23 окт: под мышью — цветом как выбранный (колесо меняет именно его): микро-отклик
        if not psel and not drag and mx >= bxc + L.pad and mx < bxc + L.pad + pw and my >= py and my < py + (spos and spos[pi] and spos[pi][3] or 1) * L.rh then psel = true end
        -- строка параметра: имя | виджет | значение — без подложки, белым;
        -- выбранный параметр — янтарное имя и виджет
        local acc = pins and U.RED or (psel and ((is_sel and sel.param == pi and D.CURCELL ~= U.TEXT and D.CURCELL) or U.AMBER) or U.TEXT)   -- 28 окт: выбранный (не под мышью) — цветом курсора: в mono тот же, что у курсора нот (D.CURCELL не серится), иначе опция cursor accent
        -- 22 окт: 5..8 положений — столбик кнопок по строке на положение, имя параметра вертикально слева
        local tallh = spos and spos[pi] and spos[pi][3] or 1
        -- 24 окт: параметр под курсором трекера (огибающая / команда ноты) — контрастная рамка
        local hl = info.cur_param_hl
        if hl and ((hl.pi and hl.pi == p.i and hl.fx == (p.fx or f.i)) or (hl.role and D.hl_role(f, p, hl.role))) then
          set(U.TEXT); gfx.rect(bxc + L.pad - 2, py, pw + 3, tallh * L.rh, 0); gfx.rect(bxc + L.pad - 1, py + 1, pw + 1, tallh * L.rh - 2, 0)
        end
        if tallh > 1 then
          local labs = (info.step_labels and info.step_labels(f, p)) or {}
          local cur = (p.stepnorm and D.step_index and D.step_index(p, v.n) or math.floor(v.n * (p.nsteps - 1) + 0.5))
          local x0 = bxc + L.pad
          local nmh = tallh * L.rh
          local ncol_c = pins and U.RED or (psel and ((is_sel and sel.param == pi and D.CURCELL ~= U.TEXT and D.CURCELL) or U.AMBER) or U.TEXT)
          -- 23 окт: имя строкой сверху, кнопки — две колонки вдвое уже (по строкам: 1 2 / 3 4 / 5 6)
          text(x0, py, fit(p.name or '', pw), ncol_c)
          local half = math.floor((pw - 2) / 2)
          for kk = 0, p.nsteps - 1 do
            local bx2 = x0 + (kk % 2) * (half + 2)
            local yy = py + (1 + kk // 2) * L.rh
            local on = kk == cur
            local hot = not drag and mx >= bx2 and mx < bx2 + half and my >= yy and my < yy + L.rh
            set(on and U.tint(U.CYAN, 0.3) or (hot and U.tint(U.AMBER, 0.2) or U.BG)); gfx.rect(bx2, yy + 1, half, L.rh - 2, 1)
            set(hot and U.AMBER or (on and U.CYAN or U.LINE)); gfx.rect(bx2, yy + 1, half, L.rh - 2, 0)
            local lab = (pins and on) and (info.dsp_ins.buf .. '_') or (labs[kk + 1] or tostring(kk + 1))
            text(bx2 + L.pad, yy, fit(lab, half - 2 * L.pad), (pins and on) and U.RED or (hot and U.AMBER or (on and U.CYAN or U.GREY)))
            if hot then hover.dsp = { fx = k, f = f, param = pi, sv = kk / math.max(1, p.nsteps - 1), onwidget = true } end
          end
          if not drag and not hover.dsp and mx >= x0 and mx < x0 + pw and my >= py and my < py + L.rh then hover.dsp = { fx = k, f = f, param = pi } end
          hint('dspparam', x0, py, pw, nmh, { fx = k, param = pi })
          goto next_param
        end
        if adsr_of[pi] then
          local g = adsr_of[pi]
          local n = g.last - g.first + 1
          local gx, gw = bxc + L.pad, pw
          local gy0, gh = py - (pi - g.first) * L.rh, n * L.rh
          local LET = { a = 'A', h = 'H', d = 'D', s = 'S', r = 'R', x = '~' }
          local lmax = ms('S +00.00')   -- 22 окт: по самому длинному значению группы (было — «A 19.2 m»)
          for q = g.first, g.last do local vv = vals[q]; if vv and vv.s then lmax = math.max(lmax, ms('A ' .. vv.s)) end end
          local labw = math.min(math.floor(gw * 0.55), lmax + L.pad)
          local ex0, ex1 = gx + 4, gx + gw - labw - 4
          if pi == g.first then
            set(U.mix(U.BG, U.TEXT, 0.05)); gfx.rect(gx, gy0 + 1, gw - labw, gh - 2, 1)
            set(U.LINE); gfx.rect(gx, gy0 + 1, gw - labw, gh - 2, 0)
            local function nv(q) return q and math.max(0, math.min(1, (vals[q] or {}).n or 0)) or 0 end
            local seg = (ex1 - ex0) / (g.h and 3.9 or 3.4)
            local top, bot = gy0 + 4, gy0 + gh - 5
            local function Y(l) return bot - math.floor(l * (bot - top) + 0.5) end
            local xa = ex0 + math.floor(nv(g.a) * seg + 0.5)
            local xh = xa + (g.h and math.floor(nv(g.h) * seg * 0.5 + 0.5) or 0)
            local xd = xh + math.floor(nv(g.d) * seg + 0.5)
            local xs = xd + math.floor(0.4 * seg + 0.5)
            local xr = math.min(ex1, xs + math.floor(nv(g.r) * seg + 0.5))
            local ys = Y(nv(g.s))
            local pts = { { ex0, bot }, { xa, top } }
            if g.h then pts[#pts + 1] = { xh, top } end
            pts[#pts + 1] = { xd, ys }; pts[#pts + 1] = { xs, ys }; pts[#pts + 1] = { xr, bot }
            local role = is_sel and sel.param and g.role[sel.param]
            local off = g.h and 1 or 0
            local hot_i = ({ a = 2, h = 3, d = 3 + off, s = 4 + off, r = 5 + off })[role or '']
            D.L_rh = L.rh
            D.adsr_line(pts, U.BG, hot_i)
          end
          local lab = (pins and (info.dsp_ins.buf .. '_')) or ((LET[g.role[pi]] or '?') .. ' ' .. (v.s or ''))
          text(gx + gw - labw + L.pad, py, fit(lab, labw - L.pad), pins and U.RED or (psel and ((is_sel and sel.param == pi and D.CURCELL ~= U.TEXT and D.CURCELL) or U.AMBER) or U.GREY))
          if not drag and mx >= gx and mx < gx + gw and my >= py and my < py + L.rh then
            hover.dsp = { fx = k, f = f, param = pi, sv = math.max(0, math.min(1, (mx - ex0) / math.max(1, ex1 - ex0))), onwidget = mx < ex1 + 4 }
          end
          hint('dspparam', gx, py, gw, L.rh, { fx = k, param = pi })
          if D.slr then D.slr[#D.slr + 1] = { g = 'dsp:' .. tostring(k) .. ':' .. bxc, dsp = true, fx = p.fx or f.i, p = p.i, name = p.name .. (p.mk or ''), own = f.name, pn = p.name .. (p.mk or ''), x = gx, y = py, w = gw, h = L.rh } end
          goto next_param
        end
        local nw = math.floor(pw * 0.40)
        local wx0 = bxc + L.pad + nw
        local ww = math.floor(pw * 0.34)
        local vx = wx0 + ww + L.pad
        local vw = bxc + L.pad + pw - vx
        local cy = py + math.floor(L.rh / 2)
        local step_sv, steps_inline, step_direct, notepk
        if p.kind == 'toggle' then
          local on = v.n >= 0.5
          local sz = L.rh - 6
          set(on and (acc == U.TEXT and D.SL_DIM or acc) or U.BG); gfx.rect(wx0, py + 3, sz, sz, 1)
          set(on and (acc == U.TEXT and D.SL_DIM or acc) or U.LINE); gfx.rect(wx0, py + 3, sz, sz, 0)
        elseif p.kind == 'steps' and p.nsteps then
          local cur = (p.stepnorm and D.step_index and D.step_index(p, v.n) or math.floor(v.n * (p.nsteps - 1) + 0.5))
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
            -- 22 окт: до 4 положений — щелчок по квадрату ставит его (без выпадашки), под мышью — янтарный
            local direct = p.nsteps <= 4
            for kk = 0, p.nsteps - 1 do
              local sx = wx0 + kk * (segw + 1)
              local hot = direct and not drag and mx >= sx and mx < sx + segw + 1 and my >= py and my < py + L.rh
              if hot then step_sv = kk / math.max(1, p.nsteps - 1) end
              set(hot and U.AMBER or (kk == cur and (acc == U.TEXT and D.SL_DIM or acc) or U.DIM)); gfx.rect(sx, py + 4, segw, L.rh - 8, (kk == cur or hot) and 1 or 0)
            end
            if direct then step_direct = true end
          end
        else
          local cc = (acc == U.TEXT and p.cat and p.cat ~= 'other' and p.cat ~= 'mode') and D.cat_colour(p.cat) or nil
          local notep = (p.show == 'note' or p.show == 'root') and tonumber(v.s)
          notepk = notep and true or nil
          if notep then
            -- 22 окт: параметр-нота (note lo / hi, root) — мини-клавиатура октавы, нота — янтарём, октава — в значении
            local pc = p.show == 'root' and nil or (math.floor(notep + 0.5) % 12)
            if p.show == 'root' then
              local lo = 0
              for pi2, p2 in ipairs(f.params) do if p2.show == 'note' and p2.name == 'note lo' then lo = tonumber((vals[pi2] or {}).s) or 0 end end
              pc = math.floor(lo - notep + 0.5) % 12
            end
            local WH = { 0, 2, 4, 5, 7, 9, 11 }
            local kw = math.max(2, math.floor(ww / 7))
            local ky, kh = py + 2, L.rh - 4
            for wi, wpc in ipairs(WH) do
              local kx = wx0 + (wi - 1) * kw
              set(wpc == pc and U.AMBER or U.mix(U.TEXT, U.BG, 0.25)); gfx.rect(kx, ky, kw - 1, kh, 1)
            end
            local BL = { [1] = 1, [3] = 2, [6] = 4, [8] = 5, [10] = 6 }   -- чёрная → после какой белой
            for bpc, after in pairs(BL) do
              local kx = wx0 + after * kw - math.floor(kw / 3)
              set(bpc == pc and U.AMBER or U.BG); gfx.rect(kx, ky, math.max(1, math.floor(kw * 2 / 3)), math.floor(kh * 0.6), 1)
            end
          elseif info.param_bipolar and info.param_bipolar(f, p) then
            -- 22 окт: ноль посередине (pan, pitch, детюн) — ромбик от центра, как пан в шапке трека
            local ispan = (p.name or ''):lower():match('pan') ~= nil
            local dr = math.max(3, math.floor((L.rh - 6) / 2))   -- 22 окт: ромб на краю не наезжает на значение
            U.dslider(wx0 + dr, cy, math.max(4, ww - 2 * dr), v.n, true, cc or (acc == U.TEXT and D.SL_DIM or acc), psel, L.rh, ispan)
          else
          set(U.DIM); gfx.rect(wx0, cy - 1, ww, 2, 1)                       -- дорожка
          -- цвет категории (громкость / фильтр / время …) — заливкой слайдера,
          -- не полоской у имени (3 окт: полоска липла к первой букве)
          set(cc or (acc == U.TEXT and D.SL_DIM or acc)); gfx.rect(wx0, py + 4, math.max(1, math.floor(v.n * ww + 0.5)), L.rh - 8, 1)   -- 28 окт: невыбранные — на 10 % тусклее (D.SL_DIM)
          end
        end
        -- 28 окт: метка ~ / ≈ — без пробелов, прямо перед слайдером (правый край колонки имени); имя — до неё
        local pnm, pnw = p.name or '', nw - L.pad - ((p.mk or '') ~= '' and (ms((p.mk:gsub(' ', ''))) + 2) or 0)
        if D.FP and ms(pnm) > pnw then pnm = D.FP.abbr(pnm, math.max(1, math.floor(pnw / math.max(1, ms('m'))))) end   -- 22 окт: сокращение по словарю, а не обрезка по буквам (highpas → hp)
        text(bxc + L.pad, py, fit(pnm, pnw), pins and U.RED or (psel and ((is_sel and sel.param == pi and D.CURCELL ~= U.TEXT and D.CURCELL) or U.AMBER) or U.TEXT))
        if (p.mk or '') ~= '' then
          text(bxc + nw - ms((p.mk:gsub(' ', ''))), py, (p.mk:gsub(' ', '')), U.CYAN)
          -- 28 окт: метка — кнопка: щелчок / f-прыжок — панель automation с кривой и колонка огибающей в трекере
          if not drag and mx >= bxc + nw - ms((p.mk:gsub(' ', ''))) - 1 and mx < bxc + nw + 1 and my >= py and my < py + L.rh then
            hover.dspbtn = { fx = k, f = f, what = 'pauto', param = pi }
            set(U.CYAN); gfx.rect(bxc + nw - ms((p.mk:gsub(' ', ''))) - 2, py, ms((p.mk:gsub(' ', ''))) + 3, L.rh, 0)
          end
          hint('dspbtn', bxc + nw - ms((p.mk:gsub(' ', ''))) - 1, py, ms((p.mk:gsub(' ', ''))) + 2, L.rh, { fx = k, what = 'pauto', param = pi })
        end
        if pins then   -- набор — поверх значения (у ступенчатых — поверх подписей)
          local ix = steps_inline and wx0 or vx
          local iw = bxc + L.pad + pw - ix
          set(U.BG); gfx.rect(ix, py, iw, L.rh, 1)
          text(ix, py, fit(info.dsp_ins.buf .. '_', iw), U.RED)
          steps_inline = true   -- значение ниже не рисовать
        end
        -- 19 окт: пэд drumrs5k — буква-хоткей параметра оранжевым (прыжок в режиме пэдов)
        if f.kit and D.DR and p.kid and not psel then
          local hk = D.PADKEYS[(p.name or ''):lower()]
          local at = hk and (p.name or ''):lower():find(hk, 1, true)
          if at and ms(p.name:sub(1, at)) <= nw - L.pad then text(bxc + L.pad + ms(p.name:sub(1, at - 1)), py, p.name:sub(at, at), U.mix(U.AMBER, U.RED, 0.25)) end
        end   -- 15 окт: ~ автоматизирован, ≈ модулирован (18 окт, было %; знак после обрезки имени)
        if vw > 4 and not steps_inline then
          -- 10 окт: вид значения из реестра (RS5K): нота именем, root — нота оригинала, канал 0 — all
          local vs = v.s
          local NN = { 'C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-' }
          local function nname(n)
            n = math.floor((n or 0) + 0.5)
            local o = n // 12 - 1
            local b = NN[n % 12 + 1]
            if o < 0 then b = b:gsub('%-$', '') end          -- октава −1: «C-1», не «C--1»
            return b .. o
          end
          if p.show == 'note' and tonumber(v.s) then vs = nname(tonumber(v.s))
          elseif p.show == 'root' and tonumber(v.s) then
            local lo = 0
            for pi2, p2 in ipairs(f.params) do if p2.show == 'note' and p2.name == 'note lo' then lo = tonumber((vals[pi2] or {}).s) or 0 end end
            vs = nname(lo - tonumber(v.s))                 -- нота оригинала; сдвиг — в статусе
          elseif p.show == 'chan' then vs = (v.s == '0') and 'all' or v.s
          elseif p.labels and #p.labels == 2 then vs = p.labels[(v.n >= 0.5) and 2 or 1] end
          if D.FP and ms(vs) > vw then vs = D.FP.compact(vs) end   -- 22 окт: не влезает — короткий вид (25087.71 Hz → 25.1k, 353.6 ms → 354ms)
          text(vx, py, fit(vs, vw), U.GREY)
        end
        if not drag and mx >= bxc + L.pad and mx < bxc + L.pad + pw and my >= py and my < py + L.rh then
          hover.dsp = { fx = k, f = f, param = pi, frac = (mx - bx - L.pad) / pw,
                        sv = math.max(0, math.min(1, (mx - wx0) / math.max(1, ww))), onwidget = mx >= wx0 - 2 and mx < wx0 + ww + 2 }
          if notepk then hover.dsp.onwidget = false; hover.dsp.notepick = true   -- 22 окт: нота — щелчок открывает клавиатуру, не ставит значение
          elseif steps_inline or step_direct then hover.dsp.onwidget = step_sv ~= nil; hover.dsp.sv = step_sv or hover.dsp.sv
          elseif p.kind == 'steps' and p.nsteps then hover.dsp.steplist = true end   -- клик — список (5 окт)
        end
        if D.csel_on(D.csel_dsp_tid, p.fx or f.i, p.i) then csel_frame(bxc + L.pad - 1, py, pw + 2, L.rh) end
        hint('dspparam', bxc + L.pad, py, pw, L.rh, { fx = k, param = pi })
        if is_sel and sel.param == pi then D.dsp_sel_rect = { x = bxc + L.pad, y = py, w = pw, h = L.rh } end   -- 24 окт: выпадашки — под ним
        if f.wrap then f._lx, f._lw, f._ybot = bxc + L.pad, pw, py + L.rh end   -- 24 окт: под макросами — их назначения
        -- 14 окт: CONTROL (Opt+Cmd с 26 окт) — параметры колонки устройства одной группой
        if D.slr then D.slr[#D.slr + 1] = { g = 'dsp:' .. tostring(k) .. ':' .. bxc, dsp = true, fx = p.fx or f.i, p = p.i, name = p.name .. (p.mk or ''), own = f.name, pn = p.name .. (p.mk or ''), x = bxc + L.pad, y = py, w = pw, h = L.rh } end
        ::next_param::
      end
      -- 24 окт: контейнер — под ручками макросов что на каком: «M1 Serum cutoff +50»
      f._ybot, f._nomac = nil, nil
      -- ПКМ / клик в любом месте блока (6 окт) — этот блок, а не модуль в фокусе
      if not drag and not hover.dsp and not hover.dspbtn and not hover.rs5k and mx >= bx and mx < bx + bw and my >= by and my < by + bh then hover.dsp = { fx = k, f = f } end
      if mw > 0 then bx, bw = bx - mw, bw + mw end   -- 22 окт: назад после фейдеров макросов
      -- 24 окт: опция offdim — у выключенного (off) модуля параметры приглушены пеленой фона
      if info.offdim and not (f.enabled and not f.poff) and bh > L.rh + 2 then set(U.BG, D.OFFDIM or 0.4); gfx.rect(bx + 1, by + L.rh + 1, bw - 2, bh - L.rh - 2, 1); gfx.a = 1 end
      if f._small and D.stk then D.stk.y = by + bh + L.rh; D.stk.w = bw end
      bx = bx + bw + L.pad
      end
      ::next_block::
      if f.inner and (f.inner.lane or f.inner.bi) and not f.wrap then D.lane_close(L, f, bx, boxy, bh0) end
      if f.cend then bx = D.rack_close(L, f, bx, boxy, bh0, drag, mx, my, hover) end
    end
    -- 28 окт: конец цепочки — «+» (щелчок — поиск эффекта fzf, в конец цепи); при перетаскивании там щель
    if not drag and #fxs > 0 then
      local pw = math.max(3 * L.cw, ms('+') + 4 * L.pad)
      local hot = mx >= bx and mx < bx + pw and my >= boxy and my < boxy + bh0
      if hot then set(U.tint(U.AMBER, 0.15)); gfx.rect(bx, boxy, pw, bh0, 1) end
      text(bx + math.floor((pw - ms('+')) / 2), boxy + math.floor((bh0 - L.rh) / 2), '+', hot and U.AMBER or U.tint(U.AMBER, 0.7))
      if hot then hover.dspbtn = { fx = #fxs, what = 'chainadd' } end
      hint('dspbtn', bx, boxy, pw, bh0, { fx = #fxs, what = 'chainadd' })
      bx = bx + pw + L.pad
    end
    -- окно цепочки — на экран; всё, что левее / правее, осталось в буфере
    D.dsp_total = wrap > 1 and 0 or (bx + px - cx0)   -- рядами — без прокрутки
    boxy, bh0 = boxy0, bh00
    gfx.dest = dest0
    gfx.blit(700, 1, 0, cx0, boxy - 4, cx1 - cx0, bh0 + 6 + D.rack_ext, cx0, boxy - 4, cx1 - cx0, bh0 + 6 + D.rack_ext)
    mx = mx0
    D.hint = hint0
    if D.slr then
      local keep = {}
      for i2 = nslr0 + 1, #D.slr do local e = D.slr[i2]; if e.x + e.w > cx0 and e.x < cx1 then keep[#keep + 1] = e end end
      for i2 = #D.slr, nslr0 + 1, -1 do D.slr[i2] = nil end
      for _, e in ipairs(keep) do D.slr[#D.slr + 1] = e end
    end
    local vw = cx1 - cx0
    local maxpx = math.max(0, D.dsp_total - vw)
    D.dsp_view, D.dsp_maxpx = vw, maxpx
    D.dsp_px = math.max(0, math.min(maxpx, D.dsp_px))
    if D.dsp_px_t then D.dsp_px_t = math.max(0, math.min(maxpx, D.dsp_px_t)) end
    -- выбранный модуль (w / W, щелчок, harpoon) — плавно в поле зрения, целиком, если влезает
    if sel.fx ~= D.dsp_sel_last and D.dsp_noscroll and reaper.time_precise() - D.dsp_noscroll < 0.5 then
      D.dsp_sel_last, D.dsp_noscroll = sel.fx, nil   -- 24 окт: выбор щелчком по параметру — без прокрутки
    end
    if sel.fx ~= D.dsp_sel_last then
      D.dsp_sel_last = sel.fx
      local v = D.dsp_vx[sel.fx or 0]
      if v then
        local t = D.dsp_px_t or D.dsp_px
        if v[1] < t then t = v[1] elseif v[1] + v[2] > t + vw then t = math.min(v[1], v[1] + v[2] - vw + L.pad) end
        if t ~= (D.dsp_px_t or D.dsp_px) then D.dsp_px_t = math.max(0, math.min(maxpx, t)) end
      end
    end
    -- полоса прокрутки цепочки: ползунок = окно из всей ширины цепочки, едет плавно (по пикселям)
    hover.dsphsb = nil; D.dsp_sb_n = nil
    if not (info.dsp_router and info.draw_router) and #fxs > 0 and maxpx > 0 then
      local x0, w = cx0, cx1 - cx0 - L.pad
      local sy = dy + 3 + L.rh + bh0 + 2 + (D.rack_band or 0)
      local h = D.SBW or 3
      if w > 20 then
        D.dsp_sb_n = #fxs   -- горизонтальное колесо над DSP листает цепочку
        local tw = math.max(12, math.floor(w * vw / math.max(1, D.dsp_total)))
        local tx = x0 + math.floor((w - tw) * (D.dsp_px / math.max(1, maxpx)) + 0.5)
        tx = math.max(x0, math.min(tx, x0 + w - tw))
        local inbar = not hover.dspbtn and mx >= x0 and mx < x0 + w and my >= sy - 5 and my < sy + h + 6   -- 22 окт: зона шире полоски, но не над вкладками / кнопками
        local onthumb = inbar and mx >= tx and mx < tx + tw
        set(U.mix(U.LINE, U.BG, 0.5)); gfx.rect(x0, sy + math.floor(h / 2), w, 1, 1)
        set((onthumb or D.dsphsb_drag) and U.AMBER or U.GREY); gfx.rect(tx, sy, tw, h, 1)
        if inbar then hover.dsphsb = { thumb = onthumb, w = w, tw = tw, dir = mx < tx and -1 or 1 } end
      end
    end
    end
    ::dsp_router_done::
    -- выход после всех эффектов и кнопка компенсации громкости под ним (4 окт)
    if lvl then
      -- 12 окт: метр выхода — у правого края модуля во всю высоту; compensate — вертикальной кнопкой за ним
      -- (была буква c под метром, она ужимала метр)
      local cx = DR - L.pad - cvw
      local ox = cx - 2 - mw
      D.dsp_meter(L, ox, mby, mw, mbh, 'o', lvl.out, 'out', hover)
      -- 12 окт: compensate — треть высоты; ниже — автогромкость: фейдер так, чтобы пик выхода стал 0 / −6 / −12 / −18 / −24 дБ
      local ch = math.max(L.rh, math.floor(mbh / 3))
      local hot = mx >= cx and mx < cx + cvw and my >= mby and my < mby + ch
      local on = lvl.comp_on
      local bg = on and U.tint(U.CYAN, 0.35) or (hot and U.tint(U.AMBER, 0.3) or U.BG)
      set(bg); gfx.rect(cx, mby, cvw, ch, 1)
      set(on and U.CYAN or (hot and U.AMBER or U.LINE)); gfx.rect(cx, mby, cvw, ch, 0)
      local lbl = ms('compensate') <= ch - 4 and 'compensate' or 'comp'
      local tl = math.min(ms(lbl), ch - 4)
      D.vtext(cx + math.floor((cvw - L.th) / 2), mby + math.floor((ch - tl) / 2), tl, lbl, on and U.CYAN or (hot and U.AMBER or U.GREY), bg)
      if hot then hover.dspcomp = info.pool_col end
      local T = { 0, -6, -12, -18, -24 }
      local ay, ah = mby + ch + 2, math.floor((mbh - ch - 2) / #T)
      if ah >= ms('-24') + 4 then
        for k, tdb in ipairs(T) do
          local by2 = ay + (k - 1) * ah
          local h2 = ah - 2
          local hot2 = mx >= cx and mx < cx + cvw and my >= by2 and my < by2 + h2
          local bg2 = hot2 and U.tint(U.AMBER, 0.3) or U.BG
          set(bg2); gfx.rect(cx, by2, cvw, h2, 1)
          set(hot2 and U.AMBER or U.LINE); gfx.rect(cx, by2, cvw, h2, 0)
          local s = tostring(tdb)
          local tl2 = math.min(ms(s), h2 - 4)
          D.vtext(cx + math.floor((cvw - L.th) / 2), by2 + math.floor((h2 - tl2) / 2), tl2, s, hot2 and U.AMBER or U.GREY, bg2)
          if hot2 then hover.dspauto = { col = info.pool_col, db = tdb } end
        end
      end
    end
    -- перетаскивание (блок или FX из списка): куда встанет — янтарная черта
    -- между блоками; половина блока под мышью решает «до» или «после»
    -- бросок внутрь контейнера (6 окт): средняя половина блока-контейнера —
    -- двойная голубая рамка вместо черты; края блока — как раньше, до / после
    if drag and my >= dy and my < dy + DH and mx >= fbw then
      for _, b in ipairs(D.rack_plus or {}) do   -- 24 окт: поле «+» в конце рэка — в конец контейнера
        if b.k ~= drag.k and mx >= b.x and mx < b.x + b.w and my >= b.y and my < b.y + b.h then hover.dsp_into, hover.dsp_into_par = b.k, (my >= b.y + math.floor(b.h / 2)) and 1 or 0 end   -- 28 окт: верх | / низ =
      end
      for _, b in ipairs(blocks) do
        if b.cont and not b.bands and b.k ~= drag.k and mx >= b.x + b.w / 4 and mx < b.x + b.w * 3 / 4 and my >= b.y and my < b.y + b.h then
          set(U.CYAN); gfx.rect(b.x, b.y, b.w, b.h, 0); gfx.rect(b.x + 1, b.y + 1, b.w - 2, b.h - 2, 0)
          hover.dsp_into = b.k
          hover.dsp_into_par = my >= b.y + b.h / 2 and 1 or 0     -- 28 окт: нижняя половина — parallel (как у поля «+»)
          set(U.CYAN); gfx.rect(b.x + 2, math.floor(b.y + b.h / 2), b.w - 4, 1, 1)
        end
      end
    end
    -- 28 окт: щель броска — небольшой проём во всю высоту, две секции: верх | — последовательно, низ = — параллельно
    -- предыдущему (половина под мышью — по высоте модуля); → 0 / 1
    local function drop_slot(gx, y0, h0)
      local sw2 = math.max(ms('=') + 2 * L.pad, 3 * L.pad)
      local x0 = gx - math.floor(sw2 / 2)
      local hh = math.floor(h0 / 2)
      local low = my >= y0 + hh
      set(U.BG); gfx.rect(x0, y0, sw2, h0, 1)
      set(U.tint(U.CYAN, 0.3)); gfx.rect(x0, low and y0 + hh or y0, sw2, low and h0 - hh or hh, 1)
      set(U.CYAN); gfx.rect(x0, y0, sw2, h0, 0); gfx.rect(x0, y0 + hh, sw2, 1, 1)
      text(x0 + math.floor((sw2 - ms('|')) / 2), y0 + math.floor((hh - L.rh) / 2), '|', low and U.GREY or U.CYAN)
      text(x0 + math.floor((sw2 - ms('=')) / 2), y0 + hh + math.floor((h0 - hh - L.rh) / 2), '=', low and U.CYAN or U.GREY)
      return low and 1 or 0
    end
    -- 24 окт: над модулем внутри рэка — место в его контейнере: левая половина — перед ним, правая — после
    if drag and not hover.dsp_into and my >= dy and my < dy + DH and mx >= fbw then
      for _, b in ipairs(blocks) do
        local inn = b.inner
        if inn and inn.wrap and inn.parent and b.k ~= drag.k and mx >= b.x and mx < b.x + b.w and my >= b.y and my < b.y + b.h then
          local before = mx < b.x + b.w / 2
          local gx = before and (b.x - math.floor(L.pad / 2) - 1) or (b.x + b.w + math.floor(L.pad / 2))
          local par = drop_slot(gx, b.y, b.h)
          hover.dsp_gin = { c = inn.parent, pos = before and ((inn.ki or 1) - 1) or (inn.ki or 1), name = fxs[b.k] and fxs[b.k].name, par = par }
          break
        end
      end
    end
    if drag and not hover.dsp_into and not hover.dsp_gin and my >= dy and my < dy + DH and mx >= fbw then
      local gap, gx = #blocks > 0 and blocks[#blocks].k or 0, (#blocks > 0 and (blocks[#blocks].x + blocks[#blocks].w + math.floor(L.pad / 2)) or (fbw + L.pad))
      for _, b in ipairs(blocks) do   -- 23 окт: модули полосы (inner) — не щели верхнего уровня
        if not b.inner and mx < b.x + b.w / 2 then gap = b.k - 1; gx = b.x - math.floor(L.pad / 2) - 1; break end
      end
      local tl = 0   -- щель — в позициях верхнего уровня REAPER (без модулей полос)
      for i = 1, gap do if fxs[i] and not fxs[i].inner then tl = tl + 1 end end
      gap = tl
      local gy, gh = dy + 3 + L.rh, DH - L.rh - 6 - (L.hint_h or 0)
      hover.dsp_gpar = drop_slot(gx, boxy, bh0)   -- 28 окт: | / = — как внутри рэка
      hover.dsp_gap = gap
    end
    if drag and drag.k then
      for _, b in ipairs(blocks) do
        if b.k == drag.k then set(U.BG); gfx.a = 0.5; gfx.rect(b.x, b.y, b.w, b.h, 1); gfx.a = 1 end
      end
    end
    if (L.hint_h or 0) > 0 then
      local hy3 = dy + DH - L.hint_h
      if fbw > 0 then D.hint_bar(L, 0, hy3, fbw - 1, (info.hint_bars or function() end)(info.notes_draw and 'notes' or 'fxb'), info.focus == 'fxb' or info.focus == 'notes') end
      D.hint_bar(L, fbw, hy3, DR - fbw, (info.hint_bars or function() end)('dsp'), info.focus == 'dsp')
    end
    L.dsp_rect = { fbw, dy, DR - fbw, DH }
    D.clip = nil
    if info.pinmx and info.PINS then D.pins_draw(L, info, fbw, dy, DR - fbw, DH, mx, my, hover) end   -- 24 окт: матрица пинов поверх DSP
    D.pc_end(D.dpc.b, info, D.dpc.inside)
  end

  -- 11 окт: кнопка «<» и протяжка у линии трекер | браузер убраны — размеры и показ панелей у дерева (ручки, Ctrl+W)

  -- прямоугольники модулей (3 окт) — для рамки фокуса; границы модулей рисуют
  -- разделители D.SEP: 1 px, тусклые (одна линия, без наложений)
  do
    local rects = {
      -- до низа модуля (5 окт): статус в трекере и строка подсказок — внутри рамки
      tracker = { tx0, hy, W - tx0, (L.trk_bot or (L.body_y + L.body_h + L.low_h)) - hy },
      matrix = (L.matrix_w > 0 and not state.mx_hidden) and { 0, hy, L.matrix_w, (L.lside_split or (L.mx_ext and L.dsp_y) or L.trk_bot or (L.body_y + L.body_h + L.low_h)) - hy } or nil,
      browser = (L.lside_rect and { L.lside_rect[1], L.lside_rect[2], L.lside_rect[3], L.lside_rect[4] }) or (L.side_w > 0 and { L.side_x, (L.side_y0 or 0) + (L.inst_side_h or 0) + 2, L.side_w, gfx.h - L.status_h - (L.side_y0 or 0) - (L.inst_side_h or 0) - 2 }) or nil,
      top = L.top_h > 0 and L.top_rect or nil,
      ctrl = L.top_h > 0 and L.ctrl_area or nil,
      inst = (L.inst_w > 0 or L.side_w > 0) and L.inst_rect or nil,
      dsp = L.dsp_h > 0 and L.dsp_rect or nil,
      fxb = L.dsp_h > 0 and L.fxb_rect or nil,
      notes = L.notes_rect,
      slices = L.slices_rect,
    }
    D.module_rects = rects          -- только для рамки фокуса: границы модулей — разделители D.SEP (1 px)
    if L.pn then D.module_rects = D.pn_rects or rects end   -- панели (9 окт): прямоугольники листов
  end
  -- статус — в самом низу окна, под DSP-панелью (раньше делил y с ней и
  -- перекрывал её шапку)
  -- статус-бар (3 окт): внизу окна (bottom) или строкой под телом трекера,
  -- по ширине матрица + трекер (tracker)
  local sx, sy, sw, sh = 0, gfx.h - L.status_h, gfx.w, L.status_h
  -- 11 окт: подсказки в статусе («…: h l signal, j k row, a / A add») — клавиши яркими, описание обычным текстом
  local KEYW = { Esc = 1, Enter = 1, Tab = 1, Space = 1, Bksp = 1, click = 1, rclick = 1, dblclick = 1, wheel = 1, drag = 1, zz = 1, Del = 1 }
  local function keyish(t)
    return #t <= 2 or t:match('^%p+$') or KEYW[t] or t:match('^%^') or t:match('^Shift') or t:match('^Cmd') or t:match('^Ctrl') or t:match('^Opt') or t:match('^Alt')
  end
  local function key_text(x, y, str, maxw, head_col)
    str = fit(str, maxw)
    local pre, list = str:match('^(.-:%s)(.*)$')
    local parts = {}
    if list then for p in (list .. ', '):gmatch('(.-), ') do parts[#parts + 1] = p end end
    local hits = 0
    for _, p in ipairs(parts) do if keyish(p:match('^(%S+)') or 'longword') then hits = hits + 1 end end
    if #parts < 2 or hits * 2 < #parts then text(x, y, str, head_col); return end
    text(x, y, pre, head_col); x = x + ms(pre)
    for i, p in ipairs(parts) do
      local keys, rest, n = {}, nil, 0
      for tok in p:gmatch('%S+') do
        n = n + 1
        if not rest and keyish(tok) and n <= 4 then keys[#keys + 1] = tok else rest = rest and (rest .. ' ' .. tok) or tok end
      end
      if #keys == 0 then text(x, y, p, U.TEXT); x = x + ms(p)
      else
        local ks = table.concat(keys, ' ')
        text(x, y, ks, U.AMBER); x = x + ms(ks)
        if rest then local r = ' ' .. rest; text(x, y, r, U.TEXT); x = x + ms(r) end
      end
      if i < #parts then text(x, y, ', ', U.GREY); x = x + ms(', ') end
    end
  end
  -- панели (9 окт): строка клавиш панели в фокусе (как zellij), статус под ней
  if L.pn and (L.pn_keys or 0) > 0 then
    local f = info.focus
    local page = (state.router_big and 'router') or (state.dsp_big and 'dspbig') or (f == 'tracker' and (info.vmode == 'insert' and 'insert' or 'tracker'))
      or (f == 'top' and D.panes.BY[info.toptab or ''] and D.panes.BY[info.toptab].hint)
      or (f == 'browser' and (info.browser_page or 'browser')) or (f == 'slices' and 'inst') or f
    set(U.PANEL); gfx.rect(0, sy, gfx.w, L.pn_keys, 1)
    -- 10 окт: у панелей hint_h = 0 — hint_bar выходил сразу, строка была пустой; высота — своя
    -- нет своей строки у модуля — общие клавиши панелей
    if not state.pane_mode and info.hint_bars then
      local items = info.hint_bars(page) or D.PANE_KEYS
      D.hint_bar(setmetatable({ hint_h = L.pn_keys }, { __index = L }), 0, sy, gfx.w, items, true)
      -- 10 окт: мышь над строкой клавиш — полный набор клавиш модуля в фокусе (страница справки)
      local mx2, my2 = gfx.mouse_x, gfx.mouse_y
      local P = info.key_page and info.key_page(page)
      if P and my2 >= sy and my2 < sy + L.pn_keys and mx2 >= 0 and mx2 < gfx.w then
        local lines = {}
        for _, e in ipairs(P.e or {}) do lines[#lines + 1] = { key = e.k, text = e.m or e.d } end
        if #lines > 0 then D.popup(L, { kind = 'info', title = 'keys: ' .. (P.title or page) .. '  (? - full help)', lines = lines }, { x = L.pad, y = sy, above = true }) end
      end
    end
    sy, sh = sy + L.pn_keys, sh - L.pn_keys
  end
  if L.status_in > 0 then
    -- в модуле трекера: под треками (от границы матрицы), под матрицей — её фон
    sx, sy, sw, sh = L.matrix_w, L.stat_y, L.win_w - L.matrix_w, L.status_in
    -- 8 окт: только если под статусом — матрица; браузер слева / матрица до DSP — не трогать (рвало браузер)
    if L.matrix_w > 0 and not L.lside_rect and not L.mx_ext and not state.mx_hidden then set(U.PANEL); gfx.rect(0, sy, L.matrix_w, sh, 1) end
  end
  if sh > 0 then
    set(U.PANEL); gfx.rect(sx, sy, sw, sh, 1)
    set(D.SEP); gfx.rect(sx, sy, sw, D.SEPW, 1)
    -- слева режим/сообщение (не шире трети), дальше — описание того, на что
    -- наведена мышь, во всю оставшуюся ширину
    -- 15 окт: режим — в полосе трекера (modeline); здесь — то, что после «|» (сообщение), без слова режима
    local left = (info.status_left or ''):match('^[^|]*|(.*)$') or ''   -- «РЕЖИМ | сообщение»: режим — до первой |
    left = fit((left:gsub('^%s+', '')), sw / 3)
    key_text(sx + L.pad, sy + 2, left, sw / 3, U.AMBER)
    local hx = sx + L.pad + (left ~= '' and (ms(left) + 3 * L.pad) or 0)
    local desc = info.status_right or ''
    if desc == '' then desc = D.aw_status or '' end
    D.aw_status = nil                    -- DSP спрятан — строка не залипает
    D.aw_status = nil
    if desc ~= '' then
      if left ~= '' then set(D.SEP); gfx.rect(hx - 2 * L.pad + L.pad // 2, sy + 2, 1, sh - 2, 1) end
      key_text(hx, sy + 2, desc, sx + sw - hx - L.pad, U.TEXT)
    end
  end
  if L.side_w > 0 then set(D.SEP); gfx.rect((L.side_x or L.win_w) - 2, 0, D.SEPW, gfx.h - L.status_h, 1) end
  -- модуль слайсов (4 окт): своя колонка, линия слева
  D.pmark('draw: slices list')
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
  D.pmark('draw: popups, focus frame')
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
    -- рамка фокуса — по раскрытому списку (6 окт: рисовалась по прежнему месту
    -- и резала список линией поперёк)
    if D.module_rects then D.module_rects.fxb = { 0, py, pw, pb - py } end
  else D.fxb_popup = nil end
  -- keycaster (4 окт): последние нажатия в пустой правой части тела трекера —
  -- новое снизу, старое поднимается и гаснет (info.keycast: { label, t, n })
  if info.keycast and #info.keycast > 0 and L.cols and #L.cols > 0 then
    -- 11 окт: последняя колонка L.cols — мастер у правого края (mtrack); keycast —
    -- после последнего обычного трека, иначе его зона начиналась за окном
    local lc = L.cols[#L.cols]
    for k = #L.cols, 1, -1 do if not L.cols[k].master then lc = L.cols[k]; break end end
    local kx0 = (lc.x or 0) + (lc.w or 0) + 2 * L.pad
    -- 11 окт: мастер справа (колонка Tempo у края) — keycast до него, а не до края окна
    local kx1 = (L.master_right and not L.mfold and L.cols_r or W) - L.pad   -- 21 окт: сложенный мастер — к стенке окна, поверх его узкой полосы (на подложке)
    local kfold = L.mfold and true or false
    local now = info.now or 0
    -- свой масштаб (4 окт: keys - / keys + в главном модуле)
    local s0, kcs = D.SCALE, (info.keycast_scale or 0) > 0 and info.keycast_scale or nil
    if kcs then
      if D.ttf then gfx.setfont(3, D.ttf_face, math.floor(D.ttf_px * kcs + 0.5))   -- TTF: свой кегль, не зум (5 окт)
      else D.SCALE = kcs end
    end
    local krh = TH() + 2
    -- 20 окт: справа нет места (треки во всю ширину, сложенный мастер) — поверх правых треков на подложке
    -- (было: зона уже 6 знаков — keycast молча не рисовался, «невидим» в solarized)
    local kback = kfold   -- 21 окт: над полосой сложенного мастера — на подложке
    -- 21 окт: на подложке — вплотную к правой линии треков (D.cols_edge), не через неё в зазор у мастера
    if kx1 - kx0 < L.cw * 10 then
      kx1 = math.min(kx1, (D.cols_edge(L) or (kx1 + L.pad)) - L.pad)
      kx0 = math.max((L.cols[1].x or 0) + L.cw * 4, kx1 - L.cw * 18); kback = true
    end
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
          -- 20 окт: светлая тема — свежая клавиша основным (тёмным) текстом, янтарь на светлом не читался
          local light = D.light_bg
          local col = i == 0 and (light and U.TEXT or U.AMBER) or U.mix(U.TEXT, U.BG, math.min(0.8, 0.25 + age / 5))
          if D.kcfont then
            -- 20 окт: опция keycast font — свой шрифт (из mode font), высота строки keycast
            -- длинное слово — мельче, пока не влезет в зону (до полувысоты), потом — обрезка по символам
            local px = math.floor(krh * 1.1)
            gfx.setfont(8, D.kcfont, px)   -- 20 окт: свой слот 8 — слот 5 кэширует Menlo для ∆ (kcast портил его: огромная ∆)
            local lw = gfx.measurestr(lbl)
            while lw > kx1 - kx0 and px > math.floor(krh * 0.5) do px = px - 1; gfx.setfont(8, D.kcfont, px); lw = gfx.measurestr(lbl) end
            while lw > kx1 - kx0 and #lbl > 1 do lbl = lbl:sub(1, (utf8.offset(lbl, -1) or #lbl) - 1); lw = gfx.measurestr(lbl) end
            if kback then set(U.BG); gfx.rect(kx1 - lw - L.pad, y, lw + 2 * L.pad, krh, 1) end
            set(col); gfx.x, gfx.y = kx1 - lw, y + math.floor((krh - gfx.texth) / 2); gfx.drawstr(lbl)
            gfx.setfont(D.font_id)
          else
            local fl = fit(lbl, kx1 - kx0)
            if kback then set(U.BG); gfx.rect(kx1 - ms(fl) - L.pad, y, ms(fl) + 2 * L.pad, krh, 1) end
            text(kx1 - ms(fl), y, fl, col)
          end
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
    local w = W - x0 - L.pad - 2                         -- 22 окт: на 2 px от края — рамка INSERT на него не ложится
    local h = math.min(L.hsb_h - 2, D.SBW or 3)          -- 8 окт: толщина, как у всех скроллбаров
    local y = L.hsb_y + math.floor((L.hsb_h - h) / 2)
    hover.hsb = nil
    if w > 20 and L.hs_n > 0 and (L.hs_full or 0) < L.hs_n then   -- 22 окт: все треки на экране — полосы нет (ползунок во всю ширину ничего не двигал)
      local n = L.hs_n
      local tw = math.max(12, math.floor(w * math.min(1, math.max(1, L.hs_full) / n)))
      local tx = x0 + math.floor((w - tw) * (n > L.hs_full and (L.hs_before / math.max(1, n - L.hs_full)) or 0))
      tx = math.min(tx, x0 + w - tw)
      local inbar = mx >= x0 and mx < x0 + w and my >= L.hsb_y and my < L.hsb_y + L.hsb_h
      local onthumb = inbar and mx >= tx and mx < tx + tw
      set((onthumb or D.hsb_drag) and U.AMBER or (n > L.hs_full and U.GREY or U.LINE)); gfx.rect(tx, y, tw, h, 1)
      if inbar then hover.hsb = { thumb = onthumb, x0 = x0, w = w, n = n, page = math.max(1, L.hs_full), dir = mx < tx and -1 or 1 } end
    end
  end
  -- пианинка (4 окт): слой пианино — полоса клавиш под скролл-баром треков
  if L.piano_h > 0 then
    local p = (state.hints or state.pianokeys) and info.piano or nil   -- 8 окт: клавиатура — с подсказками или быстрой опцией keys
    if p then p.ins = info.vmode == 'insert' end
    local st
    if L.kbstat or (info.ctrl and info.ctrl.bigstatus) then
      st = { info.status_left or '', ((info.status_right or '') ~= '' and info.status_right) or D.aw_status or '', small = L.kbstat }
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
    -- 8 окт: над матрицей (top) — граница снизу, к матрице (пропадала)
    if L.ctrlpos == 'top' and not L.ctrl_dsp then set(D.SEP); gfx.rect(0, bh - D.SEPW, bw + D.SEPW, D.SEPW, 1) end
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
  if D.notes_popup and info.notes_draw and not L.pn then   -- панели: у заметок свой лист
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
  if L.mix_bottom and L.mix_h > 0 and info.mixsnaps then D.draw_mixsnaps(L, info, hover) end   -- 22 окт: снапшоты SWS в пустом месте микшера
  if D.late_send then local f = D.late_send; D.late_send = nil; f() end
  if D.late_pop then local f = D.late_pop; D.late_pop = nil; f() end
  if D.notepop then D.draw_notepop(L, hover) end   -- 22 окт: клавиатура всех октав для параметра-ноты
  -- верхняя линия главного модуля и верхней панели (5 окт): как у lib сверху;
  -- до сайдбара — у него своя
  if L.top_h > 0 and L.top_first then set(D.SEP); gfx.rect(0, L.top_y or 0, (L.side_w or 0) > 0 and (L.side_x or L.win_w) - 2 or L.win_w, D.SEPW, 1) end
  -- 15 окт: тег набранного у курсора — поверх соседних ячеек
  local ta = D.typed_at
  D.typed_at = nil
  if ta and info.typed and info.typed ~= '' then
    local w = math.max(ms(ta.s), ta.w or 0) + 2
    set(U.tint(U.AMBER, 0.45)); gfx.rect(ta.x - 1, ta.y, w, L.rh, 1)
    text(ta.x, ta.ty, ta.s, U.AMBER)
  end
  -- рамка фокуса клавиатуры: модуль, которому идут клавиши; последней в
  -- кадре (5 окт) — скроллбар, пианинка и разделители закрывали низ и право
  do
    local f = (info.mixfocus and info.focus == 'tracker') and 'mixer' or info.focus   -- 11 окт: фокус микшера
    local rects = D.module_rects or {}
    local r = rects[f]
    -- 15 окт: фокус и режим — разные рамки: фокус (куда идут клавиши) — вокруг всего модуля, как у всех;
    -- режим INSERT (клавиши пишут в проект) — красная вокруг поля строк, где пишутся ноты
    local ins = info.vmode == 'insert' and info.focus == 'tracker'
    if info.win_focus == false then r = nil end   -- 15 окт: клавиши у REAPER — рамок фокуса нет
    if r then
      -- 15 окт: опция dim unfocused — остальные модули слегка притушены; до рамок — иначе тень ложилась
      -- на рамку там, где прямоугольник соседа перекрывает трекер (пропадала верхняя кромка)
      local dk = (tonumber(state.dimfocus) or 0) / 100   -- 15 окт: сила — слайдер в опциях (0 = выкл)
      if dk > 0 then
        local seen = { [table.concat(r, ',')] = true }
        for k, r2 in pairs(rects) do
          local key = table.concat(r2, ',')
          if k ~= f and not seen[key] and r2[3] > 0 and r2[4] > 0 then seen[key] = true; gfx.set(0, 0, 0, dk); gfx.rect(r2[1], r2[2], r2[3], r2[4], 1) end
        end
        gfx.a = 1
      end
      set(D.FOCUS)
      -- 8 окт: ободок внутри модуля (на пиксель внутрь): общая линия с соседом
      -- остаётся серой — видно, какой из двух соседних активен; INSERT — 2 px
      -- 10 окт: рамка — по самой границе модуля, второй пиксель INSERT — наружу (на линию-разделитель):
      -- внутри (на 1-2 px) она ложилась на содержимое — кнопку R крайнего трека
      -- 15 окт: снова 1 px (INSERT — 2): толстая рамка закрывала края растягивания панелей
      gfx.rect(r[1], r[2], r[3], r[4], 0)
      -- рамка режима: поле строк трекера в цвете режима (D.MODE_COL); INSERT — 2 px
      -- 28 окт: INSERT — красная рамка поля строк и при фокусе в другой панели (клавиши нот всё ещё пишут)
      local insany = info.vmode == 'insert'
      local tf = ((info.focus == 'tracker' and not info.mixfocus) or insany) and D.trk_field
      if tf then
        set(D.MODE_COL[info.vmode] or D.MODE_COL.normal); gfx.rect(tf[1], tf[2], tf[3], tf[4], 0)
        if ins or insany then gfx.rect(tf[1] + 1, tf[2] + 1, tf[3] - 2, tf[4] - 2, 0) end
      end
      -- 15 окт: опция focus beacon — фокус перешёл в модуль: рамка вспыхивает и стягивается к нему за 0.4 с
      local now = reaper.time_precise()
      if D.focus_last ~= f then
        if D.focus_last and state.focusbeacon then D.fbeacon = { t = now } end
        D.focus_last = f
      end
      local fb = D.fbeacon
      if fb then
        local k = (now - fb.t) / 0.4
        if k >= 1 then D.fbeacon = nil
        else
          local g = math.floor(12 * (1 - k) ^ 2)
          set(U.AMBER, 0.8 * (1 - k))
          for d = 0, 2 do gfx.rect(r[1] - g - d, r[2] - g - d, r[3] + 2 * (g + d), r[4] + 2 * (g + d), 0) end
          gfx.a = 1
        end
      end
    end
  end
  -- 11 окт: перенос трека за шапку — куда ляжет: линия между колонками или рамка (в папку)
  local hd = D.hdr_drop
  if hd then
    set(U.AMBER)
    local y0, y1 = L.header_y, L.trk_bot or (gfx.h - L.status_h)
    if hd.kind == 'into' then gfx.rect(hd.x, y0, hd.w, y1 - y0, 0); gfx.rect(hd.x + 1, y0 + 1, hd.w - 2, y1 - y0 - 2, 0)
    else gfx.rect(hd.x - 1, y0, 3, y1 - y0, 1) end
  end

  return hover
end

-- ── всплывашка снизу (which-key / подсказка команд / поиск) ───────────────
-- Панель над строкой статуса: колонками «клавиша  действие». Ширина — от
-- содержимого, высота — от числа строк (до половины окна).
-- anchor = { x, y } — место правки: всплывашка под ним (не влезает — над ним)
function D.popup(L, p, anchor)
  D.popup_hot, D.popup_rect, D.popup_pick, D.popup_group, D.popup_gcols = nil, nil, nil, nil, nil
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
    if ln.hk and D.hints_on then hw = math.max(hw, ms(ln.hk)) end   -- 23 окт: колонка хоткеев — только с hints
  end
  tw = math.min(tw, ms(string.rep('W', 60)))          -- длинные описания — обрезаются (fit), меню не во весь экран
  -- колонка хоткеев (5 окт): своя ширина, без наложений; описания ужимаются
  local hcol = hw > 0 and (hw + 2 * L.pad) or 0
  local maxcol = math.floor((W - 3 * L.pad) / ncol)
  if L.pad + kw + 2 * L.pad + hcol + tw + 2 * L.pad > maxcol then tw = math.max(ms('WWWWWWWW'), maxcol - (L.pad + kw + 2 * L.pad + hcol + 2 * L.pad)) end
  local colw = L.pad + kw + 2 * L.pad + hcol + tw + 2 * L.pad
  -- 9 окт: пикер не уже заголовка (до 60 знаков) — поиск не сжимает окно
  -- 13 окт: окно ввода имени (vim.open_prompt): одна строка — текст, курсор; fresh — весь текст выделен
  if p.kind == 'prompt' then colw = math.max(ms(string.rep('W', 24)), ms(p.title or '') + ms('WW')) + 2 * L.pad end
  if (p.kind == 'picker' or p.kind == 'cmd') and ncol == 1 then
    local tmin = math.min(ms(p.title or ''), ms(string.rep('W', 60))) + 2 * L.pad
    if colw < tmin then tw = tw + (tmin - colw); colw = tmin end
  end
  -- 16 окт: пикер с папками — слева колонка папок (своя ширина, до 28 знаков), справа имена
  local gw, gws = 0, {}
  if p.groups then
    -- 16 окт: колонки папок по уровням, у каждой своя ширина (до 24 знаков)
    for k, col in ipairs(p.groups.cols) do
      local cw = ms('all  0000')
      for _, t in ipairs(col.lines) do cw = math.max(cw, ms(t)) end
      gws[k] = math.min(cw, ms(string.rep('W', 24))) + 3 * L.pad
      gw = gw + gws[k]
      nrow = math.max(nrow, math.min(#col.lines, maxrows))
    end
  end
  local w = math.min(W - 2 * L.pad, ncol * colw + L.pad + gw)
  local h = (nrow + 1) * L.rh + 2 * L.pad
  -- 27 окт: заголовок влезает целиком (меню не уже своей подписи)
  if p.title and p.title ~= '' and p.kind ~= 'prompt' then w = math.min(W - 2 * L.pad, math.max(w, ms(p.title) + 2 * L.pad + 2)) end
  local x, y = L.pad, sy - h - 2
  if anchor and anchor.box then
    -- 6 окт: всплывашка в заданный прямоугольник (действия REAPER на всю матрицу)
    local b = anchor.box
    x, y, w, h = b[1], b[2], b[3], b[4]
    ncol, nrow = 1, math.min(n, math.max(1, math.floor((h - 2 * L.pad) / L.rh) - 1))
    colw = w
    tw = math.max(ms('WWWW'), w - (L.pad + kw + 2 * L.pad + hcol + 2 * L.pad))
  elseif anchor then
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
  if p.kind == 'prompt' then
    local t = p.title or ''
    local tx, ty = x + L.pad, y + L.pad
    if p.fresh and t ~= '' then set(U.tint(U.AMBER, 0.35)); gfx.rect(tx - 1, ty, ms(t) + 2, L.rh, 1) end
    text(tx, ty + 1, t, U.TEXT)
    local cx = tx + ms(p.before or t)
    set(U.AMBER); gfx.rect(cx, ty, 2, L.rh, 1)
    return
  end
  if p.search_head then
    -- 18 окт: поиск выбора — набранное, мигающий курсор; пусто — тусклое приглашение
    local tx, ty = x + L.pad, y + L.pad
    local head = fit(p.search_head, w - 2 * L.pad)
    text(tx, ty, head, U.CYAN); tx = tx + ms(head)
    if p.search ~= '' then
      if p.search_fresh then set(U.tint(U.AMBER, 0.35)); gfx.rect(tx - 1, ty, ms(p.search) + 2, L.rh, 1) end   -- 18 окт: текущее имя — выделено, набор заменит
      text(tx, ty, p.search, U.TEXT); tx = tx + ms(p.search)
    end
    if math.floor(reaper.time_precise() * 2.5) % 2 == 0 then set(U.AMBER); gfx.rect(tx, ty, 2, L.rh, 1) end
    tx = tx + 4
    if p.search == '' then local ph = 'type to search'; text(tx, ty, ph, U.DIM); tx = tx + ms(ph) end
    text(tx, ty, fit(p.search_tail or '', math.max(0, x + w - L.pad - tx)), U.GREY)   -- не за рамку
  else
    text(x + L.pad, y + L.pad, fit(p.title or '', w - 2 * L.pad), p.kind == 'hydra' and U.AMBER or U.CYAN)
  end
  if p.groups then
    local cx = x
    for k, G in ipairs(p.groups.cols) do
      local cw = gws[k]
      local foc = p.groups.focus == k
      for i, t in ipairs(G.lines) do
        if i > nrow then break end
        local gi = G.first + i - 1
        local ly = y + L.pad + i * L.rh
        local on = gi == G.sel
        local mhot = gfx.mouse_x >= cx + L.pad and gfx.mouse_x < cx + cw and gfx.mouse_y >= ly and gfx.mouse_y < ly + L.rh
        if mhot then D.popup_group = { k, gi } end
        if on or mhot then set(on and (foc and D.CURROW or U.tint(U.AMBER, 0.15)) or D.CURROW); gfx.rect(cx + L.pad, ly, cw - 2 * L.pad, L.rh, 1) end
        text(cx + 2 * L.pad, ly + 1, fit(t, cw - 3 * L.pad), on and U.AMBER or (foc and U.TEXT or U.GREY))
      end
      set(U.LINE); gfx.rect(cx + cw - L.pad, y + L.pad + L.rh, 1, h - 2 * L.pad - L.rh, 1)
      D.popup_gcols = D.popup_gcols or {}; D.popup_gcols[#D.popup_gcols + 1] = { x0 = cx, x1 = cx + cw, k = k, sel = G.sel, n = G.n or #G.lines }   -- 25 окт: колесо — своя колонка
      cx = cx + cw
    end
  end
  for i, ln in ipairs(p.lines) do
    local ci = math.floor((i - 1) / nrow)
    local ri = (i - 1) % nrow
    local lx = x + L.pad + ci * colw + gw
    local ly = y + L.pad + (ri + 1) * L.rh
    if lx + colw > x + w + L.pad + 1 and ci > 0 then break end
    -- мышь (5 окт): строка гидры под мышью подсвечена, клик — её буква
    -- 10 окт: и пикер (fzf-список) — строка под мышью подсвечена, клик — выбор
    local pick_ok = p.kind == 'picker' and p.first and i <= (p.nmatch or 0) - p.first + 1
    local mhot = (p.kind == 'hydra' or pick_ok) and gfx.mouse_x >= lx and gfx.mouse_x < lx + colw - L.pad and gfx.mouse_y >= ly and gfx.mouse_y < ly + L.rh
    if mhot and p.kind == 'hydra' then D.popup_hot = ln.key end
    if mhot and pick_ok then D.popup_pick = p.first + i - 1 end
    if p.hl == i and p.kind == 'picker' then set(U.tint(U.AMBER, 0.3)); gfx.rect(lx, ly, colw - L.pad, L.rh, 1)   -- 18 окт: выбранное в поиске — заметно
    elseif p.hl == i or mhot then set(D.CURROW); gfx.rect(lx, ly, colw - L.pad, L.rh, 1) end
    text(lx + L.pad, ly + 1, ln.key or '', p.kind == 'hydra' and U.AMBER or U.TEXT)
    if ln.hk and D.hints_on then text(lx + L.pad + kw + 2 * L.pad, ly + 1, fit(ln.hk, hw), U.CYAN) end
    if ln.chips then   -- 16 окт: «клавиша имя» подряд, клавиша — янтарём
      local cx = lx + L.pad + kw + 2 * L.pad + hcol
      for _, ch in ipairs(ln.chips) do
        local wd = ms(ch[1]) + ms('W') + ms(ch[2]) + 2 * ms('W')   -- 16 окт: пробелы в конце measurestr не считает
        if cx + wd > lx + colw then break end
        text(cx, ly + 1, ch[1], U.AMBER); text(cx + ms(ch[1]) + ms('W'), ly + 1, ch[2], U.TEXT)
        cx = cx + wd
      end
    elseif p.kind == 'hydra' then
      -- 20 окт: меню без заглавных (Queue → queue, REAPER / RS5K — как есть), буква клавиши — янтарём в самом слове
      local tx0 = lx + L.pad + kw + 2 * L.pad + hcol
      local t = fit(D.hydra_text(ln.text or ''), tw)
      local col = ln.col or U.GREY
      local at = D.hydra_mark(t, ln.key)
      if at then
        local pre = t:sub(1, at - 1)
        text(tx0, ly + 1, pre, col)
        local ch = t:sub(at, at)
        local cx = tx0 + ms(pre .. '.') - ms('.')   -- 21 окт: measurestr не считает пробел в конце («rowto the top»)
        text(cx, ly + 1, ch, U.AMBER)
        set(U.AMBER); gfx.rect(cx, ly + L.rh - 2, ms(ch), 1, 1)
        text(cx + ms(ch), ly + 1, t:sub(at + 1), col)
      else text(tx0, ly + 1, t, col) end
    elseif ln.pn then
      -- 24 окт: параметр в поиске: [ярлык] ● имя параметра — ярко, эффект — тускло; не влезло — режется эффект
      local tx0 = lx + L.pad + kw + 2 * L.pad + hcol
      local hl2 = p.hl == i and p.kind == 'picker'
      local cx = tx0
      if ln.tag then
        local tc = ln.tag == 'selected' and U.AMBER or (ln.tag == 'touched' and U.CYAN or U.GREEN)
        text(cx, ly + 1, ln.tag, tc); cx = cx + ms(ln.tag .. '..') - ms('.')
      end
      local room = tx0 + tw - cx
      local pn = fit(ln.pn, room)
      text(cx, ly + 1, pn, hl2 and U.TEXT or U.mix(U.TEXT, U.GREY, 0.3))
      local fx0 = cx + ms(pn .. '...') - ms('.')
      if ln.fxn and ln.fxn ~= '' and tx0 + tw - fx0 > L.cw * 3 then text(fx0, ly + 1, fit(ln.fxn, tx0 + tw - fx0), U.DIM) end
    elseif ln.code or ln.tag then
      -- 24 окт: fzf команды / параметра — код команды её цветом (как в колонке), ярлык selected / touched / recent — своим
      local tx0 = lx + L.pad + kw + 2 * L.pad + hcol
      local t = fit(ln.text or '', tw)
      local head = ln.code or ln.tag
      local hc = ln.code and (D.FX_COL[ln.code] or (ln.code:sub(1, 1) == 'Z' and D.RN_GLOBAL) or D.RN_OTHER)
                 or (ln.tag == 'selected' and U.AMBER or (ln.tag == 'touched' and U.CYAN or U.GREEN))
      local rest = (p.hl == i and p.kind == 'picker') and U.TEXT or U.GREY
      if t:sub(1, #head) == head then
        text(tx0, ly + 1, head, hc)
        text(tx0 + ms(head .. '.') - ms('.'), ly + 1, t:sub(#head + 1), rest)
      else text(tx0, ly + 1, t, rest) end
    else text(lx + L.pad + kw + 2 * L.pad + hcol, ly + 1, fit(ln.text or '', tw), (p.hl == i and p.kind == 'picker') and U.TEXT or (ln.col or U.GREY)) end
  end
end
-- 20 окт: подпись меню без заглавных — слово с заглавной и строчными дальше (Queue, Shift) → строчными;
-- аббревиатуры (REAPER, RS5K, MIDI, A1) остаются
function D.hydra_text(t)
  return (t:gsub('%f[%w](%u)(%l)', function(a, b) return a:lower() .. b end))
end
-- позиция буквы клавиши в подписи: начало слова, потом где угодно; регистр — точно, потом любой
function D.hydra_mark(t, key)
  if not key or #key ~= 1 or not key:match('%w') then return nil end
  local function find(k, ci)
    local s = ci and t:lower() or t
    local at = s:find('%f[%w]' .. k)
    return at or s:find(k, 1, true)
  end
  return find(key, false) or find(key:lower(), true)
end

return D
