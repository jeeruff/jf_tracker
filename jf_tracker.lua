-- jf_tracker.lua — трекерный вид таймлайна REAPER с Vim-редактированием.
--
-- Трекер — ВИД. Данные — нативные объекты проекта (треки, items, takes,
-- MIDI, lanes, регионы, огибающие). Своего формата хранения нет; закрыл
-- окно — проект как был. Все записи — в jf_tracker_edit.lua, каждая
-- своим undo-блоком.
--
-- Модули: model (единственный читатель reaper.*), draw (gfx), vim (режимы и
-- команды), edit (писатель), matrix (паттерны, живая очередь регионов),
-- alias (одноимённые регионы), preview (CF_Preview / транспорт), browser
-- (сайдбар файлов), keys (пианино, раскладка, коды; файл пользователя).
-- Палитра — jf_looper_ui.lua. Справка — F1 (jf_tracker_help.html).
--
-- ExtState jf_tracker/{dock,x,y,w,h,lpb,follow,folds,fxcols,envs,preview,
-- autosync,pitchmodes,font,pool,poolprev,side,browse}. hb — пульс для
-- проверки живости снаружи (время, треки, режим, fps, профиль кадра).

local SELF = debug.getinfo(1, 'S').source:sub(2)
local DIR = SELF:match('(.*)[/\\]') or '.'
local RES = reaper.GetResourcePath()
local EXT = 'jf_tracker'

local U = dofile(DIR .. '/jf_tracker_ui.lua')             -- своя копия (5 окт, релиз: без внешних зависимостей)
local model = dofile(DIR .. '/jf_tracker_model.lua')
local draw = dofile(DIR .. '/jf_tracker_draw.lua')
local keys = dofile(DIR .. '/jf_tracker_keys.lua')
local edit = dofile(DIR .. '/jf_tracker_edit.lua')
local vim = dofile(DIR .. '/jf_tracker_vim.lua')
local OPT = dofile(DIR .. '/jf_tracker_options.lua')   -- окно Options (1 окт)
OPT.tour = dofile(DIR .. '/jf_tracker_tour.lua')         -- интерактивный тур tutorial (4 окт); полем OPT: предел локальных
OPT.ask = dofile(DIR .. '/jf_tracker_ask.lua')           -- вопрос посреди окна (3 окт); полем OPT: главный чанк у предела локальных
local VER = dofile(DIR .. '/jf_tracker_version.lua')    -- версия и изменения (Options → about)
local SPROP = dofile(DIR .. '/jf_tracker_sampleprops.lua')  -- панель свойств сэмпла (вкладка Sample)
local MX = dofile(DIR .. '/jf_tracker_matrix.lua')
local PV = dofile(DIR .. '/jf_tracker_preview.lua')
local alias = dofile(DIR .. '/jf_tracker_alias.lua')
local B = dofile(DIR .. '/jf_tracker_browser.lua')
local MMX = dofile(DIR .. '/jf_tracker_modmatrix.lua')
MMX.CH = dofile(DIR .. '/jf_tracker_chord.lua')   -- аккорды: анализатор / гармонайзер (8 окт); полем MMX — предел локальных
draw.CH = MMX.CH
MMX.PP = dofile(DIR .. '/jf_tracker_params.lua')   -- панель params вкладки modulation (3 окт); полем MMX: предел локальных
local ORCA = dofile(DIR .. '/jf_tracker_orca.lua')       -- ядро Orca (Garden)
local GD = dofile(DIR .. '/jf_tracker_garden.lua')       -- вкладка Garden
MX.DB = dofile(DIR .. '/jf_tracker_dspbig.lua')          -- DSP big: роутинг цепочки на всё окно, zz в DSP (7 окт); полем MX: предел локальных
MX.WK = dofile(DIR .. '/jf_tracker_whichkey.lua')          -- подсказка второй клавиши в главном модуле (7 окт)
MX.SS = dofile(DIR .. '/jf_tracker_session.lua')         -- session: клипы как в Ableton, zz в матрице (6 окт); полем MX: предел локальных
local SL = dofile(DIR .. '/jf_tracker_slicer.lua')
SL.sg = dofile(DIR .. '/jf_tracker_sgram.lua')
edit.open_on_add = reaper.GetExtState(EXT, 'fxopen') == '1'          -- спектрограмма (5 окт): вид sgram, импульс ReaVerb
local CM = dofile(DIR .. '/jf_tracker_cmds.lua')
local HN = dofile(DIR .. '/jf_tracker_hints.lua')
local FB = dofile(DIR .. '/jf_tracker_fxbrowser.lua')   -- браузер эффектов слева от DSP (2 окт)
local KH = dofile(DIR .. '/jf_tracker_keyhelp.lua')
local IMP = dofile(DIR .. '/jf_tracker_import.lua')
local NT = dofile(DIR .. '/jf_tracker_notes.lua')        -- заметки проекта / item (2 окт)      -- импорт REX / XRNI (2 окт)
local MM = dofile(DIR .. '/jf_tracker_midimap.lua')       -- MIDI learn слайсера, вкладка midi (2 окт)
local LG = dofile(DIR .. '/jf_tracker_lfogen.lua')        -- генератор LFO в точки / automation item (2 окт)
local LOGO = dofile(DIR .. '/jf_tracker_logo.lua')        -- логотипы about (3 окт)
math.randomseed(math.floor(os.time() + (reaper.time_precise() % 1) * 1e6))   -- стиль логотипа — новый от запуска к запуску
local IK = dofile(DIR .. '/jf_tracker_instkeys.lua')      -- клавиши модуля инструментов (2 окт)
local DK = dofile(DIR .. '/jf_tracker_dspkeys.lua')      -- клавиши DSP-панели (2 окт)     -- контекстная справка ? (2 окт)
model.dspmods = dofile(DIR .. '/jf_tracker_dspmods.lua')
model.fxclass = dofile(DIR .. '/jf_tracker_fxclass.lua')   -- классификатор параметров, автомодуль (3 окт)
local HELP = DIR .. '/jf_tracker_help.html'

-- ── состояние ─────────────────────────────────────────────────────────────
local function ext(k, d)
  local v = reaper.GetExtState(EXT, k)
  if v == '' then return d end
  return tonumber(v) or v
end
-- флаг: сохранённое '0' — выкл. (раньше ext() превращал '0' в число 0, а
-- 0 ~= '0' в Lua истинно: любой выключенный флаг после рестарта включался — 2 окт)
local function flag(k, d)
  local v = reaper.GetExtState(EXT, k)
  if v == '' then return d and true or false end
  return v ~= '0'
end

local LPBS = { 1, 2, 3, 4, 6, 8, 12, 16 }
local state = {
  -- режим разработчика (5 окт): файл .dev рядом со скриптом (в .gitignore) —
  -- Orca и monome; в релизе их нет
  dev = reaper.file_exists(DIR .. '/.dev'),
  lpb = tonumber(ext('lpb', 4)) or 4,
  row0 = 0, hscroll = 1, folds = {}, debug = false, last_key = 0, status = '',
  focus = 'tracker',
  follow = flag('follow', true),                  -- вид следует за плейхедом при игре
  lock = flag('lock', true),                      -- курсор трекера ≡ edit-курсор + выделенный трек REAPER
  fixed = flag('fixed', false),                   -- курсор всегда в центре экрана (Impulse Tracker)
  fxcols = math.max(1, tonumber(ext('fxcols', 1)) or 1),   -- стандартные колонки: хотя бы одна fx (1 окт)
  envs = flag('envs', true),
  trackenvs = (function()                       -- огибающие по трекам: guid → true/false (nil = как envs)
    local t = {}
    for g, v in (reaper.GetExtState(EXT, 'trackenvs') or ''):gmatch('([^=,]+)=(%d)') do t[g] = v == '1' end
    return t
  end)(),
  preview = flag('preview', true),
  autosync = flag('autosync', true),
  pitchmodes = {},
  font = tonumber(ext('font', 0)) or 0,         -- 0 = битмап REAPER (масштаб fontscale), N = TTF
  fontscale = tonumber(ext('fontscale', 2)) or 2,
  poolsort = tostring(ext('poolsort', 'track')),
  fontspace = tonumber(ext('fontspace', 2)) or 2,
  toptab = (function() local t = ext('toptab', 'master'); if t == 'mod' then t = 'modulation' elseif t == 'scope' then t = 'master' elseif t == 'clips' then t = 'sample' end; return t end)(),   -- clips вкладкой убраны (7 окт)
  top = flag('top', true),                      -- верхняя панель (контрол | метры | инструменты)
  meters = flag('meters', false),               -- большие пик-метры в шапках треков
  pool = flag('pool', true),                    -- (устар.) = top
  poolprev = flag('poolprev', true),            -- прослушивать выбранный слот (кнопка preview)
  -- режим превью инструмента (3 окт): full — до конца item / Esc, hold — пока
  -- держишь кнопку мыши на строке, sec — первая секунда
  theme = (function() local v = reaper.GetExtState(EXT, 'theme'); return v ~= '' and v or 'reaper' end)(),   -- тема трекера (3 окт)
  tlruler = (function() local v = reaper.GetExtState(EXT, 'tlruler'); return (v == 'beats' or v == 'time' or v == 'both') and v or 'off' end)(),   -- линейка у номеров (3 окт)
  curline = (function() local v = reaper.GetExtState(EXT, 'curline'); return (v == 'bottom' or v == 'off') and v or 'top' end)(),   -- линия курсора (3 окт)
  prevmode = (function() local v = reaper.GetExtState(EXT, 'prevmode'); return (v == 'hold' or v == 'sec') and v or 'full' end)(),
  side = flag('side', false),                   -- сайдбар-браузер
  sidenarrow = flag('sidenarrow', false),       -- узкий сайдбар (кнопка <>)
  scopes = flag('scopes', false),               -- скопы дорожек в шапках (3 окт, вернули): JSFX-мост jf_tracker_scope на треках
  scopemode = (function() local v = reaper.GetExtState(EXT, 'scopemode'); return (v == 'spec' or v == 'sgram') and v or 'scope' end)(),
  icons = flag('icons', true),                    -- Nerd-иконки (TTF или гибрид с битмапом, :icons)
  glyphface = (function() local v = reaper.GetExtState(EXT, 'glyphface'); return v ~= '' and v or nil end)(),
  fontface = (function() local v = reaper.GetExtState(EXT, 'fontface'); return v ~= '' and v or 'JetBrainsMono Nerd Font Mono' end)(),
  xfade = flag('xfade', false),                   -- x-fade вставленных нот (\x, контрол xf)
  xfade_ms = tonumber(reaper.GetExtState(EXT, 'xfade_ms')) or 10,
  xfademode = reaper.GetExtState(EXT, 'xfademode') ~= '' and reaper.GetExtState(EXT, 'xfademode') or 'vol',   -- x-fade: vol (огибающая take, числа в колонке vol) | fades (5 окт)
  side_px = tonumber(reaper.GetExtState(EXT, 'side_px')),   -- ширина браузера мышью (nil = авто)
  top_px = tonumber(reaper.GetExtState(EXT, 'top_px')),     -- высота верхней панели мышью
  inst_px = tonumber(reaper.GetExtState(EXT, 'inst_px')),   -- высота инструментов в сайдбаре
  mx_px = tonumber(reaper.GetExtState(EXT, 'mx_px')),       -- ширина матрицы мышью (nil = авто)
  fxb_px = tonumber(reaper.GetExtState(EXT, 'fxb_px')),     -- ширина браузера эффектов мышью
  mx_fold_px = tonumber(reaper.GetExtState(EXT, 'mx_fold_px')),   -- ширина свёрнутой матрицы (fold)
  mx_hidden = reaper.GetExtState(EXT, 'mx_hidden') == '1',  -- матрица свёрнута в полосу
  wave = (function() local v = reaper.GetExtState(EXT, 'wave'); return (v == 'peaks' or v == 'rect' or v == 'spec' or v == 'off') and v or 'peaks' end)(),
  -- волна (3 окт): column — своя колонка со спектральными пиками, note — в поле
  -- ноты на строках item (бывший «off»), off — без волны совсем
  wavemode = (function()
    local v = reaper.GetExtState(EXT, 'wavemode')
    if v == 'column' or v == 'note' or v == 'back' or v == 'off' then return v end
    return reaper.GetExtState(EXT, 'wave') == 'off' and 'note' or 'column'
  end)(),
  itemcol = flag('itemcol', true),               -- заливка и кайма item его цветом (3 окт)
  itemalpha = tonumber(reaper.GetExtState(EXT, 'itemalpha')) or 5,   -- прозрачность заливки item, %
  dsp = flag('dsp', false),
  khelp = flag('khelp', false),
  endstop = flag('endstop', true),
  ttf = ({ bigblue = 'bigblue', iosevka = 'iosevka' })[reaper.GetExtState(EXT, 'ttf')] or 'off',   -- шрифт: битмап или пиксельный TTF (5 окт)
  opt_tab = reaper.GetExtState(EXT, 'opttab') ~= '' and reaper.GetExtState(EXT, 'opttab') or nil,   -- последняя вкладка опций (5 окт)
  -- время и BPM мелко (5 окт, просьба): новый ключ — прежнее «вкл» не тянется
  bigbpm = flag('bigbpm2', false),
  bigstatus = flag('bigstatus', true),
  tpbuttons = flag('tpbuttons', false),
  tpstyle = ({ symbols = 'big', big = 'big', text = 'text', min = 'min' })[reaper.GetExtState(EXT, 'tpstyle')] or (flag('tpbuttons', false) and 'big' or 'min'),   -- кнопки транспорта: min | big | text (6 окт; symbols → big)
  tintmute = flag('tintmute', true),
  aifill = flag('aifill', false),
  midilanes = flag('midilanes', true),
  aipoints = flag('aipoints', true),
  ssbars = tonumber(ext('ssbars', 8)) or 8,
  ss_px = tonumber(reaper.GetExtState(EXT, 'ss_px')),
  lside_frac = tonumber(reaper.GetExtState(EXT, 'lside_frac')),   -- раздел матрица | браузер слева (8 окт)   -- высота clips над матрицей (тянется мышью)
  ssbsync = flag('ssbsync', true),
  clipsview = flag('clipsview', false),             -- тело трекера — клипы сессии (сцены × треки), 6 окт                  -- аудио-клип в сессию — с beatsync (6 окт)
  mxclips = flag('mxclips', false),                 -- матрица в виде clips         -- длина зоны сессии в тактах (6 окт)
  measure = false,                                -- линейка мышью (7 окт, быстрая опция; не сохраняется)
  modgap = tonumber(reaper.GetExtState(EXT, 'modgap')),   -- зазор между модулями, px (7 окт)
  fxparams = flag('fxparams', false),
  mixpos = reaper.GetExtState(EXT, 'mixpos') == 'bottom' and 'bottom' or 'top',   -- микшер над / под трекером (кнопки v ^, 8 окт)
  ptabs = flag('ptabs', true),                    -- строка вкладок проектов над главным модулем (8 окт)
  notitle = flag('notitle', true),                -- плавающее окно без заголовка (быстрая опция title, 8 окт)
  mixer = flag('mixer', false),                    -- шапки развёрнуты в микшер (8 окт)             -- параметры TCP под своими эффектами в строке effects (8 окт)
  fxrow = flag('fxrow', false),                   -- строка эффектов и сендов под шапками (кнопка effects, 7 окт)
  hdrinfo = flag('hdrinfo', false),               -- шапка трека: инструменты, инсерты, сенды (7 окт)
  whichkey = flag('whichkey', true),              -- подсказка второй клавиши у курсора (7 окт)
  browserleft = flag('browserleft', false),       -- браузер слева над матрицей, вкладка fx (7 окт)
  eqgraph = flag('eqgraph', true),               -- ReaEQ в DSP: только график (кнопка P — только параметры), 7 окт
  dsptrack = flag('dsptrack', false),             -- блок трека слева в DSP (R I M S, vol, pan, in, out); по умолчанию выкл (6 окт)
  synchdr = flag('synchdr', false),               -- колонка трека сворачивается по высоте трека REAPER (6 окт)
  quick = (reaper.GetExtState(EXT, 'quick') ~= '' and reaper.GetExtState(EXT, 'quick')) or nil,   -- быстрые опции: набор (6 окт)
  debug = flag('debug', false),                    -- отладка: лог в jf_tracker_debug.log (6 окт)               -- точки automation item на лейне трекера (6 окт)
  envpoints = flag('envpoints', true),             -- точки огибающих кружочками (6 окт)            -- MIDI-лейны: CC / PC / артикуляции / SysEx колонками (6 окт)
  oneclick = flag('oneclick', true),               -- one click focus: клик по элементу открывает его модуль (6 окт)
  autofocus = flag('autofocus', false),            -- autofocus: курсор клавиатуры на элементе — его модуль (6 окт)                   -- заливка automation items в колонках огибающих (6 окт)                -- tint channels on solo / mute (5 окт)             -- I really want to have transport buttons (5 окт; выкл — только rec / loop)
  zoommods = reaper.GetExtState(EXT, 'zoommods') ~= '' and reaper.GetExtState(EXT, 'zoommods') or 'cmd',   -- зум колесом: cmd (обе оси) | split (Cmd — гориз., Option — верт., как REAPER), 5 окт
  transpos = reaper.GetExtState(EXT, 'transpos') ~= '' and reaper.GetExtState(EXT, 'transpos') or 'tracker',   -- полоса транспорта: tracker | top | bottom (5 окт)
  reclib = flag('reclib', true),                      -- записанное в трекер — ещё и инструментом в lib (5 окт)                -- режим крупно слева в полосе транспорта (5 окт)
  recdelprompt = flag('recdelprompt', true),          -- Esc при записи: спросить перед удалением тейка (5 окт)                      -- 5 окт: по умолчанию вкл
  stretchmarks = flag('stretchmarks', true),          -- stretch-маркеры на волне (5 окт)                     -- BPM крупно в полосе транспорта (5 окт)
  focusclick = reaper.GetExtState(EXT, 'focusclick') == 'click' and 'click' or 'option',   -- фокус мышью: Option-клик (5 окт)
  itemnames = flag('itemnames', true),           -- имя item второй строкой под нотой (3 окт)               -- стоп транспорта на =END (3 окт)
  mxruler = flag('mxruler', true),
  mxfold = flag('mxfold', true),                  -- 7 окт: по умолчанию свёрнута (кнопка zoom)
  fps = (function() local v = reaper.GetExtState(EXT, 'fps'); return (v == '30' or v == '25' or v == '24') and tonumber(v) or 'max' end)(),               -- матрица свёрнута: номера, имена треков, ячейки (3 окт)
  toppos = (function() local v = reaper.GetExtState(EXT, 'toppos2'); return (v == 'top' or v == 'bottom') and v or 'mid' end)(),   -- 8 окт: по умолчанию над DSP (ключ toppos2 — сброс старого top)
  wzoom = 0,                                                       -- 7 окт: прежний зум 0/1/2 заменён уровнями wzlevel
  wzlevel = tonumber(reaper.GetExtState(EXT, 'wzlevel')),         -- общий уровень ширины треков (Cmd + гор. колесо), nil — как у трека
  hdrin = reaper.GetExtState(EXT, 'hdrin') ~= '0',   -- строка входа в шапке трека (3 окт)
  curlead = tonumber(reaper.GetExtState(EXT, 'curlead')) or 15,
  notes_scale = tonumber(reaper.GetExtState(EXT, 'notesscale')) or 0,
  textonly = reaper.GetExtState(EXT, 'textonly') == '1',
  steplisten = reaper.GetExtState(EXT, 'steplisten') == '1',
  fxopen = reaper.GetExtState(EXT, 'fxopen') == '1',
  dspmeters = reaper.GetExtState(EXT, 'dspmeters') ~= '0',          -- метры входа / выхода в DSP (5 окт)               -- окно FX после добавления (5 окт)
  slicespos = (reaper.GetExtState(EXT, 'slicespos') == 'split') and 'split' or 'module',   -- модуль слайсов: отдельно / половина lib (4 окт)      -- step listen (4 окт)
  propspos = (reaper.GetExtState(EXT, 'propspos2') == 'left') and 'left' or 'right',   -- перенос влево отменён (4 окт): по умолчанию справа          -- text only (4 окт)
  keycast = reaper.GetExtState(EXT, 'keycast') ~= '0',
  kc_scale = tonumber(reaper.GetExtState(EXT, 'kcscale')) or 0,            -- keycaster (4 окт)
  -- плавающее окошко заметок (4 окт): x y w h или nil — левая колонка
  notes_win = (function() local a, b, c, d = reaper.GetExtState(EXT, 'noteswin'):match('^(%-?%d+) (%-?%d+) (%d+) (%d+)$'); return a and { tonumber(a), tonumber(b), tonumber(c), tonumber(d) } or nil end)(),   -- масштаб текста заметок (4 окт), 0 — как везде
  meterstyle = reaper.GetExtState(EXT, 'meterstyle') == 'pt' and 'pt' or 'blocks',   -- метры: blocks / pt (4 окт)     -- упреждение курсора при игре, мс (3 окт)
  itemframe = (function() local v = reaper.GetExtState(EXT, 'itemframe'); return (v == 'wave' or v == 'off') and v or 'item' end)(),   -- рамка item (3 окт)
  ctrlpos = (function() local v = reaper.GetExtState(EXT, 'ctrlpos'); return (v == 'mid' or v == 'bottom') and v or 'top' end)(),   -- главный модуль (3 окт)
  statpos = ({ tracker = 'tracker', keyboard = 'keyboard' })[reaper.GetExtState(EXT, 'statpos')] or 'bottom',
  envfmt = reaper.GetExtState(EXT, 'envfmt') == 'hex' and 'hex' or 'midi',   -- значения огибающих / CC: midi 0..127 или hex (6 окт)
  -- вкладка grid (monome, 2 окт): опция — monome есть не у всех; по умолчанию
  -- включена, если установлен демон jf_grid
  gridtab = reaper.file_exists(DIR .. '/.dev') and flag('gridtab', reaper.file_exists(reaper.GetResourcePath() .. '/Scripts/jf_grid/jf_grid.lua')) or false,
  -- pm cards (6 окт, экспериментально как grid / orca): вкладка pm браузера —
  -- сетка карточек jf_pm с превью, big — на всё окно (jf_tracker_pm.lua)
  -- модуля карточек нет в релизе (не отгружается) — без файла опции нет и с .dev
  pm_ok = reaper.file_exists(DIR .. '/jf_tracker_pm.lua'),
  pmgrid = reaper.file_exists(DIR .. '/.dev') and reaper.file_exists(DIR .. '/jf_tracker_pm.lua') and flag('pmgrid', true) or false,
  pmthumb = flag('pmthumb', true), pmicon = flag('pmicon', true),   -- превью / метка DAW на карточках pm
  keepsamples = flag('keepsamples', true),       -- страховка сэмплов (edit.keep_samples)
  copymedia = flag('copymedia', true),
  fxb = flag('fxb', true),
  hints = flag('hints', true),
  notes_open = flag('notes', false),            -- редактор заметок в главном модуле (3 окт; раньше — на месте списка эффектов)
  view_reg = flag('viewreg', false),            -- вид: только регион курсора (reg) / весь трек (all)                   -- строка подсказок под каждым модулем                       -- браузер эффектов слева в DSP-панели           -- копия файлов браузера в папку проекта               -- вертикальная линейка тактов слева в матрице                 -- контекстная справка в нижней панели (?)                     -- нижняя DSP-панель (FX трека)
  fcollapse = {},                               -- guid папки → свёрнута
}
-- миграция 1 окт (2): пользователь выбрал битмап ×2
-- ext() отдаёт число для числовых строк: сравнивать через tostring (иначе 3 ~= '3'
-- и шрифт сбрасывался в битмап при каждом старте)
if tostring(ext('font_v', '')) ~= '3' then state.font = 0; state.fontscale = 2 end
if (tonumber(state.fontscale) or 2) > 3 then state.fontscale = 3 end   -- x4 — только PT-mode (3 окт)
state.font = 0                                                         -- TTF убран (3 окт): только битмап
state.subs_min = {}
for k, v in tostring(ext('subsmin', '')):gmatch('([^=,]+)=(%d+)') do state.subs_min[k] = tonumber(v) end
state.wave_os = tonumber(ext('wave_os', 1)) or 1
state.wave = state.wavemode == 'column' and 'spec' or 'off'   -- старое поле — из трёх режимов волны (3 окт)
state.captions = tostring(ext('captions', '0')) == '1'     -- строка подписей колонок (по умолчанию выкл, 2 окт)
-- заливка шапки трека цветом (3 окт): line — полоска под именем, header —
-- строка имени, full — вся шапка (ниже имени тусклее). Один параметр, без
-- отдельного флага fat header (его ключ стирается)
state.hdrfill = (function()
  local v = reaper.GetExtState(EXT, 'hdrfill')
  return (v == 'header' or v == 'full' or v == 'off') and v or 'line'
end)()
reaper.DeleteExtState(EXT, 'fathdr', true)
state.pvvol = tonumber(ext('pvvol', 1)) or 1
PV.set_vol(state.pvvol)
vim.vel = math.max(1, math.min(127, tonumber(ext('vel', 100)) or 100))
model.OVERSAMPLE = state.wave_os
vim.step_auto = tostring(ext('step_auto', '0')) == '1'
vim.step_next = tostring(ext('step_next', '0')) == '1'
reaper.SetExtState(EXT, 'font_v', '3', true)
-- fold: «guid» — компактный, «guid=m» — полоска (zC), ревью 2 окт
for g in tostring(ext('folds', '')):gmatch('[^,]+') do
  local id, m = g:match('^([^=]+)=?(%a*)$')
  if id then state.folds[id] = (m == 'm') and 'mini' or true end
end
for g in tostring(ext('fcollapse', '')):gmatch('[^,]+') do state.fcollapse[g] = true end
for g, m in tostring(ext('pitchmodes', '')):gmatch('([^,=]+)=([^,]+)') do state.pitchmodes[g] = m end

local MY_ID = ('%d-%06d'):format(os.time(), math.floor((reaper.time_precise() % 1) * 1e6))
local snap, regions, L, rows = nil, {}, nil, {}
local seq = {}      -- регионы последовательности (без библиотеки =LIB)
local fps = { n = 0, t = reaper.time_precise(), v = 0 }
local prof = { snap = 0, layout = 0, draw = 0, upd = 0, n = 0, max = 0 }
local click = { t = 0, fi = nil, row = nil, zone = nil }   -- для двойного клика
local browse_last = nil                                     -- строка браузера, которую уже слушали (auto)
local inject_last = reaper.GetExtState(EXT, 'inject')       -- стартовое значение не исполняем
local body_drag = nil                                       -- Shift+протяжка блока в теле
local pt_drag = nil                                         -- протяжка точки огибающей (время + значение)
local ai_drag = nil                                         -- протяжка automation item (сдвиг / начало / длина)
local seam_drag = nil                                       -- протяжка стыка лупа (item / automation item)
local ts_drag = nil                                         -- протяжка по номерам шагов — time selection
local sel_drag = nil                                        -- протяжка мышью — выделение блока
local ev_drag = nil                                         -- протяжка события / блока мышью (перенос)
local cmd_text_cache                                        -- ctx.cmd_by_text
local dsp_drag = nil                                        -- перетаскивание DSP-блока
local fxb_drag = nil                                        -- перетаскивание FX из браузера эффектов
local resize_drag = nil                                     -- ресайз: 'side' | 'top'
local lock_sync = {}                                        -- lock: последнее синхронное состояние
local loop_cache = {}         -- GD.cells по (snap, seq): слой лупов матрицы
local beat_info = { bar = 1, beat = 0, num = 4, den = 4, rows_bar = 16 }   -- размер / доли для контрола
local dspwave_drag = nil      -- ручка start / end на волне RS5K (2 окт)
local dspxy_drag = nil        -- XY-пэд модуля DSP (TG33 vector, 2 окт)
local dspview_drag = nil      -- протяжка по живому виду модуля (гранулятор)
local idle = { n = 0, active_t = 0, input_t = 0, mkey = '' }   -- простой: реже рисуем (3 окт)
local fps_buf = { w = 0, h = 0, last = 0 }  -- буфер кадров для опции fps (1021)
local view_cache = {}         -- живые виды модулей DSP за кадр (gmem чужих пространств)
local lfo_hover = nil         -- наведение на панель LFO во вкладке modulation
local mod_pane = 'matrix'     -- 'matrix' | 'lfo': куда идут клавиши вкладки modulation
local lfo_src_env = nil       -- огибающая-источник генератора follow (запись из снимка)
local lfo_drag = nil          -- протяжка слайдера генератора кривых
local mm_drag = nil           -- слайдер полосы матрицы модуляции
local seq_cache = {}                                        -- последовательность матрицы (ctx.sequence)
local trs_drag = nil                                        -- протяжка слайдера громкости/панорамы в шапке
-- BPM (2 окт): двойной клик — ввод числа [..._], клик — список темпов
local bpm_menu = nil                                        -- { sel = n, hover = n }
local BPM_LIST = {
  { 'take from selected item', 'item' },
  { '60   slow / ambient', 60 }, { '70   hip hop slow', 70 }, { '75', 75 }, { '80   lo-fi', 80 }, { '85', 85 },
  { '87.5 half of 175', 87.5 }, { '90   boom bap', 90 }, { '93', 93 }, { '95', 95 }, { '100', 100 },
  { '105', 105 }, { '110', 110 }, { '115', 115 }, { '120  pop / house', 120 }, { '122  deep house', 122 },
  { '124  tech house', 124 }, { '125', 125 }, { '126', 126 }, { '128  house / edm', 128 }, { '130  techno', 130 },
  { '132', 132 }, { '135  trance', 135 }, { '138', 138 }, { '140  dubstep / grime', 140 }, { '145', 145 },
  { '150  footwork 160', 150 }, { '160  footwork', 160 }, { '165', 165 }, { '170  jungle', 170 },
  { '172', 172 }, { '174  drum & bass', 174 }, { '175', 175 }, { '180  breakcore', 180 }, { '200', 200 },
}
-- BPM из выделенного item: метаданные файла → число в имени → длина (целые такты 4/4)
local function bpm_from_item()
  local it = reaper.GetSelectedMediaItem(0, 0)
  if not it then
    local f = L and L.flat[vim.cur.fi]; local cell = f and f.sub and f.sub[vim.cur.row]
    if cell and cell.kind == 'cont' then cell = cell.of end
    it = cell and cell.item
  end
  local take = it and reaper.GetActiveTake(it)
  if not take or reaper.TakeIsMIDI(take) then return nil, 'select an audio item' end
  local src = reaper.GetMediaItemTake_Source(take)
  local function meta(k) if not reaper.GetMediaFileMetadata then return nil end; local ok, v = reaper.GetMediaFileMetadata(src, k); return ok and tonumber((v or ''):match('[%d%.]+')) or nil end
  local b = meta('ID3:TBPM') or meta('XMP:dm/tempo') or meta('ACID:tempo') or meta('Generic:BPM')
  if b and b > 30 and b < 400 then return b, 'metadata' end
  local fn = reaper.GetMediaSourceFileName(src, '') or ''
  local base = fn:match('[^/]+$') or fn
  local n = tonumber(base:match('(%d+%.?%d*)%s*[bB][pP][mM]') or '')
  if not n then for d in base:gmatch('[_%s%-](%d%d%d?)[_%s%-%.]') do local v = tonumber(d); if v and v >= 60 and v <= 200 then n = v; break end end end
  if n and n >= 40 and n <= 400 then return n, 'file name' end
  local len = reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
  if len > 0.2 then
    local best
    for _, beats in ipairs({ 4, 8, 16, 32, 2, 64 }) do
      local v = 60 * beats / len
      if v >= 80 and v <= 180 then best = v; break end
    end
    if best then return math.floor(best * 100 + 0.5) / 100, 'length (whole bars)' end
  end
  return nil, 'no tempo found'
end
local function set_bpm(v, why)
  v = math.max(20, math.min(400, v))
  edit.run('tempo', function() reaper.SetCurrentBPM(0, v, false) end)
  vim.msg = ('BPM %.2f%s'):format(v, why and ('  (' .. why .. ')') or '')
end
-- слайдер шапки: доля 0..1 → значение и ключ трека
local TRS_KEY = { vol = 'D_VOL', pan = 'D_PAN', width = 'D_WIDTH', panl = 'D_DUALPANL', panr = 'D_DUALPANR' }
local function trs_value(what, frac)
  if what == 'vol' then
    if frac <= 0.002 then return 0 end
    return 10 ^ ((frac * 72 - 60) / 20)
  end
  return math.max(-1, math.min(1, frac * 2 - 1))
end
local TRS_RESET = { vol = 1, pan = 0, width = 1, panl = -1, panr = 1 }
-- Garden: поле Orca хранится в проекте (ProjExtState jf_tracker/garden), одно на проект
local garden = { f = nil, planted = 0 }
local function garden_load()
  local _, txt = reaper.GetProjExtState(0, 'jf_tracker', 'garden')
  garden.f = (txt and txt ~= '' and ORCA.parse(txt)) or ORCA.new(32, 8)
  if not (txt and txt ~= '') then garden.f.on = false end
end
local function garden_save() if garden.f then reaper.SetProjExtState(0, 'jf_tracker', 'garden', ORCA.serialize(garden.f)) end end
garden_load()
local item_drag = nil                                       -- протяжка края / тела item мышью
local inject_cap = nil                                      -- модификаторы инъецированной клавиши
local env_drag = { key = nil }                             -- протяжка по огибающей
local modsel = 1                                          -- строка во вкладке modulation (фокус top)
local env_rows_cache = nil                                  -- строки с точками огибающих (Vim-движения)
local reselect_item = nil                                   -- после правки слайса: выбрать инструмент этого item
local sp_on_fx = false                                      -- строка take fx свойств выбрана (прошлый кадр)
local dsp_sel = { fx = 1, param = 1 }                     -- выбор в DSP-панели (фокус dsp)
-- ── пользовательские модули DSP (3 окт): learn касанием ─────────────────
-- Файл Data/jf_tracker/dspmods_user.txt: строка на эффект —
-- «имя<TAB>заголовок<TAB>колонки<TAB>i:подпись,i:подпись…». Приоритет:
-- пользовательский > кураторский реестр > автомодуль.
local UMOD_DIR = reaper.GetResourcePath() .. '/Data/jf_tracker'
local UMOD_FILE = UMOD_DIR .. '/dspmods_user.txt'
local function umod_load()
  local t = {}
  local f = io.open(UMOD_FILE, 'r')
  if not f then return t end
  for line in f:lines() do
    local name, title, cols, list = line:match('^([^\t]+)\t([^\t]*)\t(%d+)\t([^\t]*)')
    if name then
      local m = { title = title ~= '' and title or nil, cols = tonumber(cols) or 2, params = {} }
      -- XY-пэд (5 окт): пятое поле «xy:X:Y» — номера параметров плагина
      local xx, yy = line:match('\txy:(%-?%d+):(%-?%d+)')
      if xx then m.xy_x, m.xy_y = tonumber(xx), tonumber(yy) end
      for i, lab in list:gmatch('(%d+):([^,]*)') do m.params[#m.params + 1] = { i = tonumber(i), label = lab ~= '' and lab or nil } end
      t[name] = m
    end
  end
  f:close()
  return t
end
local function umod_save(t)
  model.fx_gen = (model.fx_gen or 0) + 1        -- модули поменялись — кэш цепочек FX сбросить
  reaper.RecursiveCreateDirectory(UMOD_DIR, 0)
  local f = io.open(UMOD_FILE, 'w')
  if not f then return false end
  local names = {}
  for k in pairs(t) do names[#names + 1] = k end
  table.sort(names)
  for _, k in ipairs(names) do
    local m = t[k]
    local parts = {}
    for _, p in ipairs(m.params) do parts[#parts + 1] = p.i .. ':' .. (p.label or ''):gsub('[,:\t\n]', ' ') end
    local xy = (m.xy_x and m.xy_y) and ('\txy:%d:%d'):format(m.xy_x, m.xy_y) or ''
    f:write(('%s\t%s\t%d\t%s%s\n'):format(k, (m.title or ''):gsub('[\t\n]', ' '), m.cols or 2, table.concat(parts, ','), xy))
  end
  f:close()
  return true
end
model.user_mods = umod_load()
local dsp_learn = nil         -- { k = блок, name = имя FX, last = ключ последнего касания }
local learn_poll            -- объявлен заранее: определение ниже, вызов из кадра
local tok_drag = nil          -- перетаскивание инструмента / региона на поле Orca (3 окт)
local orca_pending = nil      -- файл из браузера на Orca: ждём номер инструмента после снимка
local act_cache = { t = 0 }   -- список действий REAPER для \\ a / :! (2 мин)
local fxv_cache = {}

-- ── окно ──────────────────────────────────────────────────────────────────
gfx.init('jf_tracker', tonumber(ext('w', 900)), tonumber(ext('h', 600)),
         tonumber(ext('dock', 0)), tonumber(ext('x', 100)), tonumber(ext('y', 100)))
draw.set_font(state)

local function save_win()
  local d, x, y = gfx.dock(-1, 0, 0, 0, 0)
  local S = function(k, v) reaper.SetExtState(EXT, k, tostring(v), true) end
  -- PT-mode не сохраняется (3 окт): пишется раскладка, бывшая до него
  if state.ptmode and state.pt_saved then for k, v in pairs(state.pt_saved) do state[k] = v end; state.ptmode = false end
  if state.pm_big and state.pm_saved then for k, v in pairs(state.pm_saved) do state[k] = v end; state.pm_big = false end   -- pm big тоже (6 окт)
  if state.ss_big and state.ss_saved then for k, v in pairs(state.ss_saved) do state[k] = v end; state.ss_big = false end   -- session big тоже
  if state.pm_flush then pcall(state.pm_flush, true) end   -- правки индекса jf_pm — на диск (ctx здесь ещё не виден: поле state)
  S('dock', d); S('x', x); S('y', y); S('w', gfx.w); S('h', gfx.h)
  S('lpb', state.lpb); S('fxcols', state.fxcols); S('font', state.font); S('ssbars', state.ssbars or 8); S('ss_px', state.ss_px or ''); S('lside_frac', state.lside_frac or '')
  S('fontscale', state.fontscale); S('fontspace', state.fontspace); S('toptab', state.toptab)
  S('viewreg', state.view_reg and '1' or '0')
  S('notes', state.notes_open and '1' or '0')
  for _, k in ipairs({ 'follow', 'envs', 'preview', 'autosync', 'pool', 'poolprev', 'side', 'sidenarrow', 'top', 'meters', 'dsp', 'icons', 'xfade', 'lock', 'fixed', 'captions', 'khelp', 'endstop', 'itemnames', 'itemcol', 'scopes', 'mxruler', 'mxfold', 'keepsamples', 'copymedia', 'fxb', 'hints', 'gridtab', 'bigstatus', 'tpbuttons', 'tintmute', 'aifill', 'oneclick', 'autofocus', 'midilanes', 'envpoints', 'aipoints', 'debug', 'synchdr', 'dsptrack', 'eqgraph', 'browserleft', 'whichkey', 'hdrinfo', 'fxparams', 'mixer', 'notitle', 'ptabs', 'ssbsync', 'mxclips', 'clipsview', 'pmgrid', 'pmthumb', 'pmicon', 'reclib', 'stretchmarks', 'recdelprompt' }) do S(k, state[k] and '1' or '0') end
  S('pvvol', tostring(state.pvvol or 1)); S('step_auto', vim.step_auto and '1' or '0'); S('step_next', vim.step_next and '1' or '0'); S('wave_os', tostring(state.wave_os or 1)); S('vel', tostring(vim.vel or 100))
  do local t = {}; for k, v in pairs(state.subs_min or {}) do if v > 1 then t[#t + 1] = k .. '=' .. v end end; S('subsmin', table.concat(t, ',')) end
  S('bigbpm2', state.bigbpm and '1' or '0'); S('transpos', state.transpos or 'tracker'); S('tpstyle', state.tpstyle or 'min'); S('zoommods', state.zoommods or 'cmd'); S('xfade_ms', tostring(state.xfade_ms)); S('xfademode', state.xfademode or 'vol')
  do local t = {}; for g, v in pairs(state.trackenvs or {}) do t[#t + 1] = g .. '=' .. (v and '1' or '0') end; S('trackenvs', table.concat(t, ',')) end
  S('fps', tostring(state.fps or 'max')); S('toppos2', state.toppos or 'mid'); S('ctrlpos', state.ctrlpos or 'top'); S('wzoom', tostring(state.wzoom or 0)); S('hdrin', state.hdrin and '1' or '0'); S('curlead', tostring(state.curlead or 15)); S('meterstyle', state.meterstyle or 'blocks'); S('notesscale', tostring(state.notes_scale or 0)); S('keycast', state.keycast and '1' or '0'); S('textonly', state.textonly and '1' or '0'); S('steplisten', state.steplisten and '1' or '0'); S('fxopen', state.fxopen and '1' or '0'); S('dspmeters', state.dspmeters and '1' or '0'); S('slicespos', state.slicespos or 'module'); S('propspos2', state.propspos or 'right'); S('kcscale', tostring(state.kc_scale or 0)); S('itemframe', state.itemframe or 'item'); S('hdrfill', state.hdrfill or 'line'); S('statpos', state.statpos or 'bottom'); S('envfmt', state.envfmt or 'midi'); S('quick', state.quick or ''); S('opttab', state.opt_tab or 'theme'); S('ttf', state.ttf or 'off'); S('focusclick', state.focusclick or 'option')
  S('scopemode', state.scopemode or 'scope'); S('wave', state.wave or 'peaks'); S('poolsort', state.poolsort or 'track'); S('prevmode', state.prevmode or 'full'); S('curline', state.curline or 'top'); S('theme', state.theme or 'reaper'); S('tlruler', state.tlruler or 'off'); S('wavemode', state.wavemode or 'column'); S('itemalpha', tostring(state.itemalpha or 5))
  S('side_px', state.side_px and tostring(math.floor(state.side_px)) or ''); S('top_px', state.top_px and tostring(math.floor(state.top_px)) or '')
  S('inst_px', state.inst_px and tostring(math.floor(state.inst_px)) or '')
  S('mx_px', state.mx_px and tostring(math.floor(state.mx_px)) or ''); S('fxb_px', state.fxb_px and tostring(math.floor(state.fxb_px)) or ''); S('mx_fold_px', state.mx_fold_px and tostring(math.floor(state.mx_fold_px)) or ''); S('mx_hidden', state.mx_hidden and '1' or '0')
  S('glyphface', state.glyphface or ''); S('fontface', state.fontface or '')
  local pm = {}
  for g, m in pairs(state.pitchmodes) do pm[#pm + 1] = g .. '=' .. m end
  S('pitchmodes', table.concat(pm, ','))
  local fl = {}
  for g, v in pairs(state.folds) do if v then fl[#fl + 1] = g .. (v == 'mini' and '=m' or '') end end
  S('folds', table.concat(fl, ','))
  local fc = {}
  for g, v in pairs(state.fcollapse) do if v then fc[#fc + 1] = g end end
  S('fcollapse', table.concat(fc, ','))
  S('browse', B.root or '')
end

-- ── помощники ─────────────────────────────────────────────────────────────
local function relayout()
  -- пианинка (5 окт): видна по умолчанию, m в NORMAL прячет / показывает;
  -- ExtState jf_tracker/piano = '0' — спрятана
  if state.piano_show == nil then state.piano_show = reaper.GetExtState('jf_tracker', 'piano') ~= '0' end
  state.piano_strip = state.piano_show or nil
  L = draw.layout(snap, state, #regions)
  -- PT-mode (3 окт): масштаб — самый крупный, при котором 4 канала влезают
  -- (x4 → x3 → x2 → x1); заново при смене ширины окна
  if state.ptmode then
    if state.pt_w ~= gfx.w then state.pt_w, state.pt_fit = gfx.w, true; state.fontscale = 2;   -- 6 окт: ×4 было огромно, старт ×2
      draw.set_font(state); L = draw.layout(snap, state, #regions) end
    while state.pt_fit and L.pt_n < math.min(4, L.pt_avail) and (state.fontscale or 1) > 1 do
      state.fontscale = state.fontscale - 1; draw.set_font(state); L = draw.layout(snap, state, #regions)
    end
    state.pt_fit = false
  end
end
local function cur_col() local f = L and L.flat[vim.cur.fi]; return f and f.col end
local function playing() return reaper.GetPlayState() & 1 == 1 end

local function set_lpb(n, dir)
  local i = 1
  for j, v in ipairs(LPBS) do if v == state.lpb then i = j end end
  local new
  if n then new = n else
    i = i + (dir or 0)
    if i < 1 or i > #LPBS then return end
    new = LPBS[i]
  end
  if new < 1 or new > 64 then return end
  local q0, qc = state.row0 / state.lpb, vim.cur.row / state.lpb
  state.lpb = new
  state.row0 = math.floor(q0 * new)
  vim.cur.row = math.floor(qc * new)
end

local function select_item_in_reaper(item)
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
  reaper.UpdateArrange()
end

-- F11: док ↔ полный экран (рабочая область монитора — под строкой меню
-- macOS, над Dock). 8 окт: окно без рамки и заголовка (JS_Window_SetStyle
-- POPUP, есть js_ReaScriptAPI; без него — обычное окно); перед доком
-- рамка возвращается
local function toggle_dock(apply_title)
  -- окно без рамки и заголовка (JS_Window_SetStyle POPUP, нужен
  -- js_ReaScriptAPI); быстрая опция title (state.notitle) — вкл / выкл
  local function frameless(on)                     -- внутри: у главного чанка нет свободных локалей
    if not (reaper.JS_Window_Find and reaper.JS_Window_SetStyle) then return end
    local hwnd = reaper.JS_Window_Find('jf_tracker', true)
    if not hwnd then return end
    reaper.JS_Window_SetStyle(hwnd, on and 'POPUP' or 'CAPTION,SIZEBOX,SYSMENU')
    local l, t, r, b = reaper.my_getViewport(0, 0, 0, 0, 0, 0, 0, 0, true)
    -- macOS (y снизу): REAPER в своём полном экране кладёт поверх строки
    -- меню чёрную шторку выше рабочей области — верх окна не выше верха
    -- главного окна REAPER, иначе шапка трекера уезжает под шторку
    local _, ml, mt, mr, mb = reaper.JS_Window_GetRect(reaper.GetMainHwnd())
    if mt and mb and mt > mb and mb <= t + 1 and ml <= l and mr >= r then b = math.min(b, mt) end   -- только если REAPER сам во весь экран
    reaper.JS_Window_SetPosition(hwnd, l, t, r - l, b - t)
  end
  local docked = gfx.dock(-1) & 1 == 1
  if apply_title then                              -- опция title / старт: только рамка плавающего окна
    if not docked then frameless(state.notitle) end
    return
  end
  if docked then
    local l, t, r, b = reaper.my_getViewport(0, 0, 0, 0, 0, 0, 0, 0, true)
    gfx.dock(0, l, t, r - l, b - t)
    frameless(state.notitle)
    vim.msg = 'fullscreen' .. (state.notitle and '' or ' (title bar on - quick option title)')
  else
    frameless(false)
    local saved = tonumber(reaper.GetExtState(EXT, 'dock_last')) or 1
    if saved & 1 ~= 1 then saved = 1 end
    gfx.dock(saved)
    vim.msg = 'docked'
  end
  local nd = gfx.dock(-1)
  if nd & 1 == 1 then reaper.SetExtState(EXT, 'dock_last', tostring(nd), true) end
end

local function open_help()
  if reaper.CF_ShellExecute then reaper.CF_ShellExecute(HELP) else os.execute('open "' .. HELP .. '"') end
end

-- выбрать слот пула трека курсора (+ прослушать 1 с)
-- превью инструмента (3 окт): как прозвучит нота, до конца item; режим
-- state.prevmode; hold — только мышью (кнопка отпущена → стоп), с
-- клавиатуры hold играет целиком; Esc останавливает любое превью.
-- Полем PV, не local: главный чанк упёрся в 200 локальных, а pool_select
-- стоит раньше ctx
function PV.inst_preview(e, track, by_mouse)
  if not (e and e.item and reaper.ValidatePtr(e.item, 'MediaItem*')) then return end
  local mode = state.prevmode or 'full'
  PV.inst(track, e.item, mode == 'sec' and 1 or nil)
  state.prev_hold = (mode == 'hold' and by_mouse) or nil
end
local function pool_select(n)
  state.auto_inst = false                     -- выбран обычный инструмент — не automation (5 окт)
  local col = cur_col()
  local pool = col and col.pool or {}
  n = math.max(1, math.min(#pool + draw.empty_slots(#pool), n))
  -- слайсы в lib не показываются (3 окт): шаг на слайс — дальше, к следующему
  -- исходнику (вниз) или к своему исходнику (вверх)
  if pool[n] and pool[n].parent then
    if n > (vim.inst or 1) then while pool[n] and pool[n].parent do n = n + 1 end
    else while n > 1 and pool[n] and pool[n].parent do n = n - 1 end end
    n = math.max(1, math.min(#pool + draw.empty_slots(#pool), n))
  end
  vim.inst = n
  if n > #pool then
    -- пустой слот (2 окт): цель для ретро-захвата и бросков
    vim.msg = ('empty slot %02d: retro p / Enter puts the capture here, or drop a retro / sample selection or a file'):format(n)
    return
  end
  local e = pool[n]
  -- выбор инструмента возвращает сэмпл-модуль к нему (если там был файл браузера)
  if SL.entry and SL.entry.file then SL.close(); SL.entry = nil end
  vim.msg = ('inst %d: %s%s'):format(n, e.name, (e.tracks and #e.tracks > 0) and ('  @ ' .. table.concat(e.tracks, ', ')) or '')
  if state.poolprev and PV.available() then PV.inst_preview(e, col.track, state.prev_by_mouse) end
end

-- ── контекст для Vim-слоя, матрицы, браузера ──────────────────────────────
-- Объявление отдельно от конструктора: функции внутри таблицы ссылаются на
-- ctx.*, а `local ctx = {…}` не виден в собственном инициализаторе (они
-- брали глобальный ctx = nil — так падал Tab на ctx.set_focus).
-- цель DSP-панели (2 окт): цепочка трека курсора или take FX инструмента
-- (state.dsp_take — включается строкой «take fx» в свойствах сэмпла, t в DSP)
local dspt_cache = {}
local function dsp_target()
  local col = cur_col()
  if not col then return nil end
  if state.dsp_take then
    local e = (col.pool or {})[vim.inst]
    local tk = e and e.take
    if tk and reaper.ValidatePtr(tk, 'MediaItem_Take*') then
      if dspt_cache.snap ~= snap or dspt_cache.take ~= tk then dspt_cache = { snap = snap, take = tk, fx = model.take_fx(tk) } end
      return { track = tk, fx = dspt_cache.fx, name = e.name or 'take', take = true, col = col }
    end
  end
  return { track = col.track, fx = col.fx or {}, name = col.name, col = col }
end
-- ретро (2 окт): объявлены до ctx — ctx и hint_go обращаются к ним раньше
-- определений (иначе это были глобальные nil: a / j k / h l во вкладке retro падали)
local retro = { sel = { a = 0.5, b = 1.0 }, cur = nil, msg = '', peaks_t = 0, alive_t = 0, put_t = nil, drag = nil, pb_t = 0 }
local retro_current, retro_preview, retro_put, retro_loop
-- то же для меню (hydra), monome и контрола: используются в ctx / hint_go раньше определения
local track_actions, region_actions, event_actions, view_actions, mono_request, ctrl_action
local MONO_ID = 9             -- id мода трекера на шине jf_mono
local ctx
ctx = {
  model = model, edit = edit, state = state, piano = keys.piano,
  peaks = function(e, n, spec) return model.peaks(e, n, spec) end,
  spec_colour = function(sp) return draw.spec_colour(sp) end,
  snap = function() return snap end,
  layout = function() return L end,
  relayout = relayout,
  bar_of_row = function(row) return model.bar_of_row(row, state.lpb) end,
  row_time = function(row) return edit.row_time(row, state.lpb, 0) end,
  vbar = function(...) return draw.vbar(...) end,
  hbar = function(...) return draw.hbar(...) end,      -- тонкий скролл-бар списков (4 окт)
  -- tutorial (4 окт): первые шаги — окном about без логотипа
  -- повтор паттерна над курсором (4 окт, Paketti): регион под курсором (вне —
  -- =START..=END); all — все треки, иначе трек курсора. Один undo
  repeat_pattern = function(all)
    local rc = vim.cur.row
    local rg = alias.region_at(regions, edit.row_time(rc, state.lpb, 0))
    local r0, r1
    if rg then r0, r1 = rg.r0, rg.r1
    else
      r0 = model.row_of_time(model.marker_pos(model.START_MARKER) or 0, state.lpb)
      local te = model.marker_pos(model.END_MARKER)
      r1 = te and model.row_of_time(te, state.lpb) or (snap and snap.last_row or rc) + 1
    end
    r0, r1 = math.floor(r0 + 0.5), math.floor(r1 + 0.5)
    if rc <= r0 then vim.msg = 'repeat: put the cursor below the part to repeat (the region starts here)'; return end
    if rc >= r1 then vim.msg = 'repeat: the cursor is at the end of the region'; return end
    local tracks = {}
    if all then for _, c in ipairs(snap.cols) do tracks[#tracks + 1] = c.track end
    else local c = cur_col(); if c then tracks[1] = c.track end end
    local n = 0
    edit.run(all and 'repeat pattern (all tracks)' or 'repeat pattern', function()
      for _, tr in ipairs(tracks) do n = n + edit.repeat_above(tr, state.lpb, r0, rc, r1) end
    end)
    model.invalidate()
    vim.msg = ('repeat rows %d-%d down to %d%s: %d copies'):format(r0, rc - 1, r1 - 1, all and ' on all tracks' or '', n)
  end,
  -- ── вставка командами и меню \ i (4 окт) ─────────────────────────────
  -- цель: трек / лейн курсора, инструмент vim.inst; после вставки — шаг
  ins_target = function()
    local f = L and L.flat[vim.cur.fi]
    if not (f and f.col) then vim.msg = 'no track under the cursor'; return nil end
    local lane = f.lane or f.col.lanes[1]
    local inst = f.col.pool and f.col.pool[vim.inst]
    if inst and inst.parent then inst = inst.parent end
    return f.col.track, f.col.fixed and lane and lane.idx or nil, inst
  end,
  ins_advance = function(rows) vim.cur.row = vim.cur.row + math.max(1, rows or (vim.step_auto and 1 or vim.step)) end,
  insert_note_cmd = function(pitch, rows)
    local tr, lane, inst = ctx.ins_target(); if not tr then return end
    edit.insert_note(tr, lane, state.lpb, vim.cur.row, pitch, vim.vel, rows or math.max(1, vim.step), inst and inst.item)
    model.invalidate(); vim.msg = 'note ' .. model.note_name(pitch); ctx.ins_advance(rows)
  end,
  insert_slice_cmd = function(k, rows, semis)
    local tr, lane, inst = ctx.ins_target(); if not tr then return end
    if not (inst and inst.slices and inst.slices[k]) then vim.msg = 'no slice ' .. tostring(k); return end
    local it
    edit.run('insert slice ' .. k, function()
      it = edit.insert_slice(tr, lane, state.lpb, vim.cur.row, inst.item, k)
      if it and semis and semis ~= 0 then edit.slice_pitch(it, semis) end
      if it and rows then reaper.SetMediaItemInfo_Value(it, 'D_LENGTH', edit.row_time(vim.cur.row + rows, state.lpb, 0) - edit.row_time(vim.cur.row, state.lpb, 0)) end
    end)
    vim.last_slice = k
    model.invalidate(); vim.msg = ('slice %d = %s%s'):format(k, model.note_name(model.BASE_NOTE + k), (semis and semis ~= 0) and (' %+d st'):format(semis) or '')
    ctx.ins_advance(rows)
  end,
  insert_whole = function(rows)
    local tr, lane, inst = ctx.ins_target(); if not (tr and inst and inst.item) then vim.msg = 'no sample selected in the lib'; return end
    edit.insert_note(tr, lane, state.lpb, vim.cur.row, model.BASE_NOTE, vim.vel, rows or 1, inst.item)
    model.invalidate(); vim.msg = 'whole sample: ' .. (inst.name or '')
    ctx.ins_advance(rows)
  end,
  -- все слайсы подряд встык (\ i s a): каждый — в конец предыдущего, один undo
  insert_all_slices = function()
    local tr, lane, inst = ctx.ins_target(); if not tr then return end
    if not (inst and inst.slices and #inst.slices > 0) then vim.msg = 'the selected sample has no slices'; return end
    local t = edit.row_time(vim.cur.row, state.lpb, 0)
    edit.run('insert all slices', function()
      for k = 1, #inst.slices do
        local row = math.floor(edit.row_of_time(t, state.lpb))
        local it = edit.insert_slice(tr, lane, state.lpb, row, inst.item, k, t)
        if it then t = edit.item_end(it) end
      end
    end)
    vim.cur.row = math.max(vim.cur.row + 1, edit.row_of_time(t, state.lpb))
    model.invalidate(); vim.msg = ('%d slices in a row from %s'):format(#inst.slices, inst.name or '')
  end,
  -- слайс в меню: нота, длина в строках, мини-волна символами
  slice_label = function(inst, k)
    local a, b = inst.slices[k], inst.slices[k + 1] or inst.len
    local rate = (inst.rate and inst.rate ~= 0) and inst.rate or 1
    local rows = (edit.row_of_time(edit.row_time(vim.cur.row, state.lpb, 0) + (b - a), state.lpb) - vim.cur.row)
    local spark = ''
    local pk = model.peaks(inst, 96)
    if pk and pk.n > 0 and (inst.len or 0) > 0 then
      local BL = { '_', '.', ':', '|', 'I' }
      for j = 0, 5 do
        local t0, t1 = a + (b - a) * j / 6, a + (b - a) * (j + 1) / 6
        local m = 0
        for i = math.max(1, math.floor(t0 / inst.len * pk.n) + 1), math.min(pk.n, math.floor(t1 / inst.len * pk.n) + 1) do
          m = math.max(m, math.abs(pk.max[i] or 0), math.abs(pk.min[i] or 0))
        end
        spark = spark .. BL[math.max(1, math.min(5, math.floor(m * 5) + 1))]
      end
    end
    return ('slice %-2d %-4s %5.2f rows  %s'):format(k, model.note_name(model.BASE_NOTE + k), rows, spark), rate
  end,
  insert_hydra = function()
    local _, _, inst = ctx.ins_target()
    local items = {
      { key = 'n', label = 'note … (:note C-4 [rows])', fn = function() vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'note ' end },
      { key = 'w', label = 'whole sample' .. (inst and (': ' .. (inst.name or '')) or '') .. ' (;  :whole)', fn = function() ctx.insert_whole() end },
    }
    if inst and inst.slices and #inst.slices > 0 then
      items[#items + 1] = { key = 's', label = ('slice of %s (%d) …'):format(inst.name or '', #inst.slices), sub = function()
        local keysq = '1234567890bcdefghijklmnopqrtuvxyz'
        local sl = { { key = 'a', label = 'all slices in a row, stitched', fn = function() ctx.insert_all_slices() end } }
        for k = 1, math.min(#inst.slices, #keysq) do
          sl[#sl + 1] = { key = keysq:sub(k, k), label = (ctx.slice_label(inst, k)), fn = function() ctx.insert_slice_cmd(k) end }
        end
        return { title = 'insert slice - key: note - length - wave', items = sl }
      end }
    end
    items[#items + 1] = { key = 'e', label = 'automation …', sub = function() return { title = 'automation (cursor on an envelope column)', items = {
      { key = 'r', label = 'ramp to a value … (:ramp FF 2b)', fn = function() vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'ramp ' end },
      { key = 'f', label = 'fade in / out … (:fade)', fn = function() vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'fade ' end },
      { key = 'c', label = 'curve (LFO / podkat / follow) - modulation tab', fn = function() state.top = true; state.toptab = 'modulation'; mod_pane = 'lfo'; ctx.set_focus('top') end },
      { key = 'p', label = 'pick a parameter to automate (fzf)', fn = function() ctx.automation_picker() end },
    } } end }
    return { title = 'insert', items = items }
  end,
  -- скринсеты (4 окт): вид целиком под именем — все опции окна options и
  -- положения / размеры модулей; файл Data/jf_tracker_screensets.txt (вне репо)
  ss_file = function() return reaper.GetResourcePath() .. '/Data/jf_tracker_screensets.txt' end,
  SS_LAYOUT = { 'top', 'toptab', 'dsp', 'side', 'sidenarrow', 'mx_hidden', 'fxb', 'notes_open', 'khelp',
                'top_px', 'side_px', 'inst_px', 'mx_px', 'fxb_px', 'mx_fold_px', 'hscroll', 'fxcols', 'lpb', 'envs', 'follow', 'fixed', 'lock' },
  ss_read = function()
    local f = io.open(ctx.ss_file(), 'r')
    if not f then return {}, {} end
    local text = f:read('*a'); f:close()
    return draw.screensets.decode(text)
  end,
  ss_write = function(sets, order)
    reaper.RecursiveCreateDirectory(reaper.GetResourcePath() .. '/Data', 0)
    local f = io.open(ctx.ss_file(), 'w'); if not f then return false end
    f:write(draw.screensets.encode(sets, order)); f:close()
    return true
  end,
  ss_save = function(name)
    name = (name or ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('\t', ' ')
    if name == '' then vim.msg = 'ssave: a name please'; return end
    local t = {}
    for _, it in ipairs(ctx.option_items()) do
      if it.get and it.key then local v = it.get(); if type(v) ~= 'table' and v ~= nil then t['o_' .. it.key] = v end end
    end
    for _, k in ipairs(ctx.SS_LAYOUT) do local v = state[k]; if v ~= nil and type(v) ~= 'table' then t[k] = v end end
    local sets, order = ctx.ss_read()
    if not sets[name] then order[#order + 1] = name end
    sets[name] = t
    vim.msg = ctx.ss_write(sets, order) and ('screenset saved: ' .. name) or 'ssave: cannot write the file'
  end,
  ss_load = function(name)
    local sets = ctx.ss_read()
    local t = sets[name or '']
    if not t then vim.msg = 'no screenset ' .. tostring(name); return end
    for _, it in ipairs(ctx.option_items()) do
      local v = t['o_' .. (it.key or '')]
      if v ~= nil and it.set and it.get and it.get() ~= v then pcall(it.set, v) end
    end
    for _, k in ipairs(ctx.SS_LAYOUT) do if t[k] ~= nil then state[k] = t[k] end end
    if MX then MX.fold = state.mxfold end
    draw.set_font(state); model.invalidate()
    vim.msg = 'screenset: ' .. name
  end,
  ss_delete = function(name)
    local sets, order = ctx.ss_read()
    if not sets[name] then return end
    sets[name] = nil
    for i, n in ipairs(order) do if n == name then table.remove(order, i); break end end
    ctx.ss_write(sets, order)
    vim.msg = 'screenset deleted: ' .. name
  end,
  screensets_hydra = function()
    local _, order = ctx.ss_read()
    local keysq = '1234567890'
    local items = { { key = 's', label = 'save the current view as …', fn = function() vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'ssave ' end } }
    -- готовые виды и свои слоты (4 окт): pt-mode, большой сэмпл, макро;
    -- user1..3 — загрузить, пустой — сохранить в него текущий вид
    items[#items + 1] = { key = 'p', label = 'pt-mode (4 channels, big)', fn = function() ctx.pt_toggle() end }
    items[#items + 1] = { key = 'b', label = 'sample - the big sample editor', fn = function() ctx.sample_big() end }
    if state.pmgrid then items[#items + 1] = { key = 'm', label = 'pm cards - projects over the whole window', fn = function() ctx.pm_big() end } end
    items[#items + 1] = { key = 'S', label = 'session - clips over the whole window (zz in the matrix)', fn = function() ctx.ss_big() end }
    items[#items + 1] = { key = 'm', label = 'zoom out - a row is a beat (:macro)', fn = function() vim.run_cmd('macro') end }
    local have = {}
    for _, name in ipairs(order) do have[name] = true end
    for i, k in ipairs({ 'z', 'x', 'c' }) do
      local nm = 'user' .. i
      items[#items + 1] = { key = k, label = have[nm] and nm or (nm .. ' (empty - saves the current view)'), fn = function()
        if have[nm] then ctx.ss_load(nm) else vim.run_cmd('ssave ' .. nm) end
      end }
    end
    local n = 0
    for _, name in ipairs(order) do
      if not name:match('^user[123]$') then
        n = n + 1
        if n > #keysq then break end
        items[#items + 1] = { key = keysq:sub(n, n), label = name, fn = function() ctx.ss_load(name) end }
      end
    end
    if #order > 0 then
      items[#items + 1] = { key = 'd', label = 'delete …', sub = function()
        local del = {}
        for i, name in ipairs(order) do if i <= #keysq then del[#del + 1] = { key = keysq:sub(i, i), label = name, fn = function() ctx.ss_delete(name) end } end end
        return { title = 'delete screenset', items = del }
      end }
    end
    return { title = 'screensets', items = items }
  end,
  -- tutorial (4 окт): интерактивный тур — шаги в активной зоне главного модуля,
  -- всплывашки на модулях; повтор — выключить. :tutorial text — текстом
  tutorial = function(text)
    if text then OPT.open_about(function() return { title = 'tutorial', text = VER.TUTORIAL } end); return end
    if OPT.tour.active then OPT.tour.stop(); vim.msg = 'tour off' else OPT.tour.start(); vim.msg = 'tour: do what the bubble says - < > in the main module step back / forward' end
  end,
  -- MIDI-нота слайса зоны (4 окт): выученные пэды — их нота + (k - 1), иначе от C4
  slice_note = function(zone)
    local col = cur_col(); local e = col and col.pool and col.pool[zone[3]]
    local k = e and e.slice_k
    if not k or k < 1 then return nil end
    return ('S%02X'):format(k)                         -- как в ячейке: Sxx = слайс (4 окт, вечер)
  end,
  -- ссылка из about (4 окт): в браузере системы
  open_url = function(url)
    if reaper.CF_ShellExecute then reaper.CF_ShellExecute(url)
    else reaper.ExecProcess("/usr/bin/open '" .. url:gsub("'", "") .. "'", -1) end
    vim.msg = 'opened ' .. url
  end,
  set_lpb = set_lpb,
  -- зум-аут (6 окт, вместо птичьего вида): LPB 1, повтор — прежний LPB
  zoom_out_toggle = function()
    state.macro = false
    if state.lpb_before_zoom then set_lpb(state.lpb_before_zoom); state.lpb_before_zoom = nil; vim.msg = 'zoom back: LPB ' .. state.lpb
    else state.lpb_before_zoom = state.lpb; set_lpb(1); vim.msg = 'zoom out: a row is a beat (:macro again - back)' end
  end,
  fold = function(col, v) state.folds[col.guid] = v or nil; ctx.hdr_push(col) end,
  fold_all = function(v) for _, c in ipairs(snap.cols) do state.folds[c.guid] = v or nil; ctx.hdr_push(c) end end,
  -- sync track header size (6 окт): высота трека REAPER (I_TCPH) ↔ свёртка
  -- колонки: < 36 px — свёрнута (mini), < 80 — компактная, выше — полная;
  -- свёртка в трекере ставит высоту 24 / 56 / 96 (I_HEIGHTOVERRIDE)
  HDR_H = { mini = 24, compact = 34, full = 64 },   -- 7 окт: высоты = уровни 0 / 1 / 4 (шаг 10 px)
  hdr_want = function(h) return h < 36 and 'mini' or (h < 80 and true or nil) end,
  -- 7 окт: высота → уровень ширины колонки, шаг 10 px (24 px — полоска)
  hdr_level = function(h) return math.max(0, math.min(L and L.MAXLVL or 10, math.floor((h - 24) / 10 + 0.5))) end,
  hdr_push = function(col)
    if not (state.synchdr and col and col.track and reaper.ValidatePtr(col.track, 'MediaTrack*')) then return end
    local f = state.folds[col.guid]
    local h = f == 'mini' and ctx.HDR_H.mini or (f and ctx.HDR_H.compact or ctx.HDR_H.full)
    if state.wlevel then state.wlevel[col.guid] = f == 'mini' and 0 or (f and 1 or nil) end   -- za — уровень сбрасывается к свёртке
    reaper.SetMediaTrackInfo_Value(col.track, 'I_HEIGHTOVERRIDE', h)
    reaper.TrackList_AdjustWindows(false)
    ctx.hdr_t = reaper.time_precise() + 0.5           -- REAPER применит высоту не сразу — опрос чуть позже
  end,
  hdr_poll = function()
    if not state.synchdr then return end
    local now = reaper.time_precise()
    if now < (ctx.hdr_t or 0) + 0.25 then return end
    ctx.hdr_t = now
    for _, c in ipairs(snap.cols or {}) do
      if c.track and c.guid and reaper.ValidatePtr(c.track, 'MediaTrack*') then
        local h = reaper.GetMediaTrackInfo_Value(c.track, 'I_TCPH')
        -- 7 окт: колесо — по одному полю (уровни), не сразу полная / нота / полоска
        state.wlevel = state.wlevel or {}
        local lv = ctx.hdr_level(h)
        if state.wlevel[c.guid] ~= lv then state.wlevel[c.guid] = lv; ctx.hdr_lv_t = now end
      end
    end
  end,
  -- папка: свернуть/развернуть (дети прячутся); на не-папке — ищем родителя
  fold_folder = function(col)
    local target = col
    if not col.folder then
      for i = col and (function() for k, c in ipairs(snap.cols) do if c == col then return k end end end)() or 1, 1, -1 do
        local c = snap.cols[i]
        if c.folder and (c.depth or 0) < (col.depth or 0) then target = c; break end
      end
    end
    if not target or not target.folder then vim.msg = 'not in a folder'; return end
    state.fcollapse[target.guid] = (not state.fcollapse[target.guid]) or nil
    vim.msg = (state.fcollapse[target.guid] and 'collapsed ' or 'expanded ') .. target.name
  end,
  -- запись (этап 8): punch по региону курсора, режимы записи, lanes трека
  punch = function()
    local rg = alias.region_at(regions, edit.row_time(vim.cur.row, state.lpb, 0))
    local t0, t1
    if rg then t0, t1 = rg.pos, rg.rgnend else
      local r0, r1 = model.bar_of_row(vim.cur.row, state.lpb)
      t0, t1 = edit.row_time(r0, state.lpb, 0), edit.row_time(r1, state.lpb, 0)
    end
    reaper.GetSet_LoopTimeRange(true, false, t0, t1, false)
    for id = 40070, 40080 do
      local txt = reaper.kbd_getTextFromCmd(id, 0) or ''
      if txt:match('^Record: Set record mode to time selection auto%-punch') then reaper.Main_OnCommand(id, 0) end
    end
    vim.msg = ('punch %.2f–%.2f'):format(t0, t1)
  end,
  hydra_recmode = function()
    local items, k = {}, 1
    local keysq = '123456789abcdef'
    for _, range in ipairs({ { 40070, 40080 }, { 40250, 40260 } }) do
      for id = range[1], range[2] do
        local txt = reaper.kbd_getTextFromCmd(id, 0) or ''
        if txt:match('^Record: Set record mode to') and k <= #keysq then
          items[#items + 1] = { key = keysq:sub(k, k), label = txt:gsub('^Record: Set record mode to ', ''), fn = function() reaper.Main_OnCommand(id, 0) end }
          k = k + 1
        end
      end
    end
    return { title = 'record mode', items = items }
  end,
  toggle_lanes = function()
    local col = cur_col(); if not col then return end
    edit.run('lanes', function()
      local v = reaper.GetMediaTrackInfo_Value(col.track, 'I_FREEMODE') == 2 and 0 or 2
      reaper.SetMediaTrackInfo_Value(col.track, 'I_FREEMODE', v)
      reaper.UpdateTimeline()
    end)
  end,
  fit = draw.fit,
  now = function() return reaper.time_precise() end,     -- бегущая строка about (3 окт)
  logo = LOGO,                                             -- about рисует логотип (options)
  set_pitchmode = function(col, mode) state.pitchmodes[col.guid] = mode end,
  -- TTF: размер 10..32 (3 окт), 0 — битмап
  -- TTF убран (3 окт): только битмап REAPER; set_font оставлен для совместимости
  set_font = function() state.font = 0; draw.set_font(state) end,
  -- Nerd-шрифт для текста (TTF-режим) или для глифов (гибрид); ищем по подстроке
  set_scale = function(n) state.fontscale = n; draw.set_font(state) end,
  set_space = function(n) state.fontspace = n; draw.set_font(state) end,
  mod_toggle = function(col, m, what) edit.mod_toggle(col.track, m, what) end,
  toggle_dock = toggle_dock,
  -- macOS: бит 4 = Cmd, 32 = Ctrl, 16 = Option
  msg = function(m) vim.msg = m end,
  -- ── заметки (2 окт): project — заметки проекта; context — item под курсором,
  -- без item — трек (заметки трека SWS) ──────────────────────────────────────
  notes_owner = function()
    if NT.target == 'dev' and not state.debug then NT.target = 'project' end
    if NT.target == 'dev' then return 'dev', DIR .. '/CHECK.md', 'dev notes: what to check (CHECK.md, not in the project)' end   -- 8 окт
    if NT.target == 'project' then return 'project', nil, 'project notes' end
    local item = ctx.item_at_cursor()
    if item then
      local tk = reaper.GetActiveTake(item)
      return 'item', item, 'item: ' .. (tk and reaper.GetTakeName(tk) or '?')
    end
    local col = cur_col()
    if col and reaper.NF_GetSWSTrackNotes then return 'track', col.track, 'track: ' .. col.name end
    return 'none', nil, 'no item under the cursor (track notes need SWS)'
  end,
  notes_load = function()
    local kind, obj, title = ctx.notes_owner()
    local text = ''
    if kind == 'project' then text = reaper.GetSetProjectNotes(0, false, '')
    elseif kind == 'dev' then local fh = io.open(obj, 'r'); if fh then text = fh:read('a') or ''; fh:close() end; NT.dev_text = text
    elseif kind == 'item' then local _, t = reaper.GetSetMediaItemInfo_String(obj, 'P_NOTES', '', false); text = t or ''
    elseif kind == 'track' then text = reaper.NF_GetSWSTrackNotes and reaper.NF_GetSWSTrackNotes(obj) or '' end
    NT.set(text); NT.owner = obj; NT.kind = kind; NT.title = title
  end,
  notes_save = function()
    if not NT.dirty then return end
    local text = NT.text()
    if NT.kind == 'project' then reaper.GetSetProjectNotes(0, true, text)
    elseif NT.kind == 'dev' and NT.owner then local fh = io.open(NT.owner, 'w'); if fh then fh:write(text); fh:close(); NT.dev_text = text end
    elseif NT.kind == 'item' and NT.owner and reaper.ValidatePtr(NT.owner, 'MediaItem*') then
      edit.run('item notes', function() reaper.GetSetMediaItemInfo_String(NT.owner, 'P_NOTES', text, true) end)
    elseif NT.kind == 'track' and NT.owner and reaper.NF_SetSWSTrackNotes then reaper.NF_SetSWSTrackNotes(NT.owner, text) end
    NT.dirty = false; NT.saved_t = reaper.time_precise()
  end,
  notes_toggle = function()
    state.notes_open = not state.notes_open
    if state.notes_open then state.top = true; ctx.notes_load(); ctx.set_focus('notes')
    else ctx.notes_save(); if state.focus == 'notes' then ctx.set_focus('tracker') end end
    vim.msg = state.notes_open and ('notes: ' .. (NT.title or '')) or 'notes closed'
  end,
  -- dev notes (8 окт): файл CHECK.md меняется снаружи (его пополняет Claude) —
  -- открытый редактор без своих правок перечитывает его раз в 2 с
  notes_dev_poll = function()
    if not (state.notes_open and NT.kind == 'dev' and not NT.dirty and NT.owner) then return end
    local now = reaper.time_precise()
    if now - (ctx.dev_poll_t or 0) < 2 then return end
    ctx.dev_poll_t = now
    local fh = io.open(NT.owner, 'r'); if not fh then return end
    local text = fh:read('a') or ''; fh:close()
    if text ~= NT.dev_text then local l, c = NT.l, NT.c; NT.set(text); NT.l, NT.c = math.min(l, #NT.lines), 0; NT.dev_text = text end
  end,
  notes_target = function(t)
    ctx.notes_save(); NT.target = t; ctx.notes_load(); ctx.set_focus('notes')
  end,
  view_reg = function(on)
    if on == nil then on = not state.view_reg end
    state.view_reg = on
    vim.msg = on and 'view: region of the cursor only' or 'view: whole track'
  end,
  -- браузер: * / :mkdir — новая папка в текущей
  browser_mkdir_prompt = function()
    if B.mode ~= 'files' then vim.msg = 'mkdir: only in files'; return end
    vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'mkdir '
    vim.msg = 'new folder in ' .. B.path
  end,
  browser_mkdir = function(name) B.mkdir(name) end,
  -- ── DSP: действия грамматики эффектов (jf_tracker_dspkeys.lua) ─────────
  dsp_fx = function(k) local t = dsp_target(); return t, t and t.fx[k] end,
  -- границы слайса-инструмента по зоне на большом сэмпле: offset take и длина item
  -- (уже вставленные ноты — свои копии item, их это не трогает)
  slice_bounds = function(zd)
    local e, p = zd.e, zd.p
    if not (e.item and e.take and reaper.ValidatePtr(e.item, 'MediaItem*')) then vim.msg = 'slice item is gone'; return end
    local pr = (p.rate and p.rate ~= 0) and p.rate or 1
    local offs = p.offs + zd.a * pr
    local len = (zd.b - zd.a) * pr / ((e.rate and e.rate ~= 0) and e.rate or 1)
    -- все items этого слайса-инструмента (одинаковые offset и длина — один
    -- ключ пула), как правка слайса в Renoise: меняются все его ноты (ревью 2 окт)
    local items = {}
    for it, i in pairs((snap and snap.inst_of) or {}) do if i == zd.inst then items[#items + 1] = it end end
    if #items == 0 then items[1] = e.item end
    edit.run('slice bounds', function()
      for _, it in ipairs(items) do
        local tk = reaper.ValidatePtr(it, 'MediaItem*') and reaper.GetActiveTake(it)
        if tk then
          reaper.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', offs)
          reaper.SetMediaItemInfo_Value(it, 'D_LENGTH', len)
        end
      end
    end)
    model.invalidate()
    reselect_item = e.item             -- ключ инструмента сменился: курсор пула вернуть на него
    vim.msg = ('slice %s: %.3f - %.3fs (%.3fs), %d note(s) of this instrument updated'):format(e.slice_k and ('s' .. e.slice_k) or '', zd.a, zd.b, zd.b - zd.a, #items)
  end,
  -- autotrim (2 окт): [a, b] секунд инструмента e — offset и длина всех его
  -- нот (один ключ пула, как правка зоны слайса), нарезка сдвигается на a
  autotrim = function(e, a, b)
    local col = cur_col()
    local idx
    for i, pe in ipairs(col and col.pool or {}) do if pe.item == e.item then idx = i end end
    local items = idx and ctx.inst_items(idx) or {}
    if #items == 0 then items = { e.item } end
    local rate = (e.rate and e.rate ~= 0) and e.rate or 1
    local sl
    if e.slices and #e.slices > 0 then
      sl = {}
      for _, t in ipairs(e.slices) do local u = t - a; if u > -1e-4 and u < b - a - 1e-4 then sl[#sl + 1] = math.max(0, u) end end
      if #sl == 0 or sl[1] > 1e-4 then table.insert(sl, 1, 0) end
    end
    edit.run('autotrim', function()
      for _, it in ipairs(items) do
        local tk = reaper.ValidatePtr(it, 'MediaItem*') and reaper.GetActiveTake(it)
        if tk then
          reaper.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', reaper.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS') + a * rate)
          reaper.SetMediaItemInfo_Value(it, 'D_LENGTH', b - a)
        end
      end
      if sl then edit.set_slices(e.item, sl) end
    end)
    -- слайсер — на обрезанный сэмпл (огибающая заново)
    local old_len = e.len or b
    e.offs = (e.offs or 0) + a * rate; e.len = b - a; e.slices = sl
    if SL.entry == e then SL.open(e, col and col.track) end
    model.invalidate()
    reselect_item = e.item
    vim.msg = ('autotrim: cut %.3fs at the start, %.3fs at the end - %d item(s)%s'):format(a, math.max(0, old_len - b), #items, sl and (', ' .. #sl .. ' slices kept') or '')
  end,
  -- t в DSP / кнопки шапки: цепочка трека ↔ take FX инструмента
  dsp_toggle_target = function(to)
    if to == nil then to = not state.dsp_take end
    state.dsp_take = to and true or nil
    dsp_sel.fx, dsp_sel.param = 1, 1
    DK.anchor, DK.pending = nil, nil      -- диапазон / оператор не переезжают на другую цепочку
    local t = dsp_target()
    vim.msg = 'DSP: ' .. (t and (t.take and ('take fx of ' .. t.name) or ('track ' .. t.name)) or 'nothing')
  end,
  -- строка «take fx» свойств сэмпла: DSP показывает take FX; пустая цепочка —
  -- фокус в список эффектов (Enter добавит в take)
  take_fx_focus = function(e)
    state.dsp = true; state.dsp_take = true; dsp_sel.fx, dsp_sel.param = 1, 1; DK.anchor, DK.pending = nil, nil
    local n = (e and e.take and reaper.ValidatePtr(e.take, 'MediaItem_Take*')) and reaper.TakeFX_GetCount(e.take) or 0
    if n == 0 and state.fxb then ctx.set_focus('fxb'); vim.msg = 'take fx of ' .. (e and e.name or '?') .. ' is empty - pick an fx: Enter adds it to the take (dblclick on take fx: REAPER window)'
    else ctx.set_focus('dsp'); vim.msg = ('take fx of %s: %d fx (t: track fx)'):format(e and e.name or '?', n) end
  end,
  dsp_delete = function(k0, k1)
    local col = dsp_target(); local fxs = col and col.fx or {}
    if not fxs[k0] then vim.msg = 'dsp: no fx'; return end
    local names = {}
    edit.run('fx delete', function()
      for k = math.min(k1, #fxs), k0, -1 do names[#names + 1] = fxs[k].name; model.fxapi(col.track).Delete(col.track, fxs[k].i) end
    end)
    model.invalidate()
    dsp_sel.fx = math.max(1, k0 - 1); dsp_sel.param = 1
    vim.msg = 'fx deleted: ' .. table.concat(names, ', ') .. ' (u / Cmd+Z undo)'
  end,
  dsp_yank = function(k)
    local col, f = ctx.dsp_fx(k)
    if not f then vim.msg = 'dsp: no fx'; return end
    state.fx_reg = { track = col.track, guid = model.fxapi(col.track).GetFXGUID(col.track, f.i), name = f.name }
    vim.msg = 'yank fx ' .. f.name .. ' - p after, P before (any track)'
  end,
  dsp_paste = function(k, after)
    local reg = state.fx_reg
    local col, f = ctx.dsp_fx(k)
    if not (reg and col) then vim.msg = 'fx register empty (yy)'; return end
    if not (reaper.ValidatePtr(reg.track, 'MediaTrack*') or model.is_take(reg.track)) then vim.msg = 'yanked fx owner is gone'; return end
    local RA = model.fxapi(reg.track)
    local si
    for i = 0, RA.GetCount(reg.track) - 1 do if RA.GetFXGUID(reg.track, i) == reg.guid then si = i end end
    if not si then vim.msg = 'yanked fx is gone'; return end
    local di = f and (after and f.i + 1 or f.i) or model.fxapi(col.track).GetCount(col.track)
    edit.fx_copy(reg.track, si, col.track, di)
    dsp_sel.fx = f and (after and k + 1 or k) or 1
    vim.msg = 'fx copy: ' .. reg.name
  end,
  dsp_pack = function(k0, k1)
    local col = dsp_target(); local fxs = col and col.fx or {}
    if not (fxs[k0] and fxs[k1]) then vim.msg = 'dsp: no fx'; return end
    if edit.fx_pack(col.track, fxs[k0].i, fxs[k1].i) then dsp_sel.fx = k0; vim.msg = ('packed %d fx into a container'):format(k1 - k0 + 1)
    else vim.msg = 'pack failed (REAPER 7 containers)' end
  end,
  -- :fxname (6 окт): имя эффекта / контейнера в цепочке (renamed_name); цель —
  -- из меню (плагин внутри контейнера) или выбранный блок DSP
  fx_rename = function(name)
    local t = state.fxname_target; state.fxname_target = nil
    if not t then
      local col, f = ctx.dsp_fx(dsp_sel.fx)
      if f then t = { track = col.track, addr = f.i } end
    end
    if not t then vim.msg = 'fxname: no fx selected'; return end
    edit.fx_rename(t.track, t.addr, name)
    vim.msg = name ~= '' and ('fx renamed: ' .. name) or 'fx name reset'
  end,
  dsp_unpack = function(k)
    local col, f = ctx.dsp_fx(k)
    if not (f and f.container) then vim.msg = 'dc: not a container'; return end
    if edit.fx_unpack(col.track, f.i) then vim.msg = 'container unpacked: ' .. f.name end
  end,
  dsp_automate = function(k, pi)
    local col, f = ctx.dsp_fx(k)
    local p = f and f.params[pi]
    if not p then vim.msg = 'aa: no parameter'; return end
    if edit.fx_envelope(col.track, p.fx or f.i, p.i) then
      if col.take then vim.msg = 'take envelope on the instrument item: ' .. f.name .. ' / ' .. p.name .. ' (see it in REAPER; placed notes are copies)'
      else state.envs = true; vim.msg = 'automation: ' .. f.name .. ' / ' .. p.name .. ' (envelope column shown)' end
    end
  end,
  -- ad — удалить автоматизацию параметра; ai — automation item по item под курсором трекера
  dsp_param_env = function(k, pi, create)
    local col, f = ctx.dsp_fx(k)
    local p = f and f.params[pi]
    if not p then return nil end
    local id = p.fx or f.i
    local env
    if col.take then env = reaper.TakeFX_GetEnvelope(col.track, id, p.i, create)
    else env = reaper.GetFXEnvelope(col.track, id, p.i, create) end
    return env, col, f, p
  end,
  dsp_unautomate = function(k, pi)
    local env, _, f, p = ctx.dsp_param_env(k, pi, false)
    if not env then vim.msg = 'ad: this parameter has no automation'; return end
    edit.env_remove(env)
    vim.msg = 'automation removed: ' .. f.name .. ' / ' .. p.name
  end,
  -- параметр ребёнка контейнера → нативный макрос контейнера (container_map,
  -- REAPER 7.06+): макрос — обычный параметр контейнера, его модулируют
  -- нативные LFO / ACS / link (правый клик) и матрица modulate
  dsp_map_macro = function(k, pi)
    local t = dsp_target()
    local f = t and t.fx and t.fx[k]
    local p = f and f.params[pi]
    if not (f and f.container) then vim.msg = 'am: select a parameter inside a container block'; return end
    if not p or p.macro then vim.msg = 'am: pick a child parameter (not a macro)'; return end
    local A = model.fxapi(t.track)
    local idx
    edit.run('container macro', function()
      local ok, v = A.GetNamedConfigParm(t.track, f.i, ('container_map.add.%d.%d'):format(p.fx or f.i, p.i))
      idx = ok and tonumber(v)
    end)
    model.invalidate()
    vim.msg = idx and ('macro %d of %s = %s - right-click it: native LFO / ACS / link'):format(idx + 1, f.name, p.name)
      or 'am: REAPER refused the mapping (needs REAPER 7.06+)'
  end,
  -- ── learn касанием (3 окт): E на блоке DSP; ручки, тронутые в окне
  -- самого плагина (GetLastTouchedFX), добавляются в пользовательский модуль
  dsp_fxshort = function(t, f)
    local _, nm = model.fxapi(t.track).GetFXName(t.track, f.i, '')
    return ((nm or ''):gsub('^[^:]*: ', ''))
  end,
  dsp_learn_toggle = function()
    if dsp_learn then dsp_learn = nil; vim.msg = 'module learn: off (saved)'; return end
    local t = dsp_target()
    local f = t and t.fx[dsp_sel.fx]
    if not f then vim.msg = 'learn: no fx selected'; return end
    if f.container then vim.msg = 'learn: containers show their macros (am maps a child parameter)'; return end
    if t.take then vim.msg = 'learn: track fx only for now (t switches the DSP to the track)'; return end
    local short = ctx.dsp_fxshort(t, f)
    if not model.user_mods[short] then
      -- старт — то, что сейчас показано (автомодуль / кураторский)
      local m = { title = f.name ~= short and f.name or nil, cols = f.cols or 2, params = {} }
      for _, p in ipairs(f.params) do if not p.fx then m.params[#m.params + 1] = { i = p.i, label = p.name } end end
      model.user_mods[short] = m
      umod_save(model.user_mods)
    end
    local _, tn, fxn, pn = reaper.GetLastTouchedFX()
    dsp_learn = { k = dsp_sel.fx, name = short, fx = f.i, track = t.track, last = ('%s|%s|%s'):format(tn, fxn, pn) }
    model.invalidate()
    vim.msg = 'module learn: turn knobs in the plugin window - they join this block; x remove, J K move, < > columns, X / Y - XY pad axes, R reset, E / Esc done'
  end,
  -- ключи правки модуля в learn: x J K < > R; true — съедено
  dsp_learn_key = function(ch)
    local m = dsp_learn and model.user_mods[dsp_learn.name]
    if not m then return false end
    local i = dsp_sel.param
    if ch == 'x' then
      if m.params[i] then table.remove(m.params, i); dsp_sel.param = math.max(1, math.min(#m.params, i)) end
    elseif ch == 'J' and m.params[i + 1] then m.params[i], m.params[i + 1] = m.params[i + 1], m.params[i]; dsp_sel.param = i + 1
    elseif ch == 'K' and i > 1 and m.params[i - 1] then m.params[i], m.params[i - 1] = m.params[i - 1], m.params[i]; dsp_sel.param = i - 1
    elseif ch == '<' or ch == ',' then m.cols = math.max(1, (m.cols or 2) - 1)
    elseif ch == '>' or ch == '.' then m.cols = math.min(4, (m.cols or 2) + 1)
    elseif ch == 'X' or ch == 'Y' then
      -- XY-пэд (5 окт): выбранный параметр — ось X / Y; повтор — снять
      local p = m.params[i]
      if p then
        local key = ch == 'X' and 'xy_x' or 'xy_y'
        m[key] = (m[key] ~= p.i) and p.i or nil
        vim.msg = ('XY: %s = %s%s'):format(ch, m[key] and (p.label or ('#' .. p.i)) or 'off', (m.xy_x and m.xy_y) and ' - the pad is in the first column' or ' - set the other axis too')
      end
    elseif ch == 'R' then
      model.user_mods[dsp_learn.name] = nil; umod_save(model.user_mods); model.auto_reset(dsp_learn.name); model.invalidate()
      vim.msg = 'module reset: back to the automatic / curated layout'; dsp_learn = nil; return true
    else return false end
    umod_save(model.user_mods); model.invalidate()
    return true
  end,
  -- dm: снять нативную модуляцию выбранного параметра (LFO / ACS / link)
  dsp_unmodulate = function(k, pi)
    local t = dsp_target()
    local f = t and t.fx[k]
    local p = f and f.params[pi]
    if not p then vim.msg = 'dm: no parameter'; return end
    if t.take then vim.msg = 'dm: take FX modulation is edited in the plugin window'; return end
    edit.mod_remove(t.track, p.fx or f.i, p.i)
    vim.msg = 'modulation removed: ' .. f.name .. ' / ' .. p.name
  end,
  dsp_autoitem = function(k, pi)
    local t = dsp_target()
    if t and t.take then vim.msg = 'ai: automation items exist only on track envelopes (switch DSP to track: t)'; return end
    local item = ctx.item_at_cursor()
    if not item then vim.msg = 'ai: put the tracker cursor on an item'; return end
    local env, _, f, p = ctx.dsp_param_env(k, pi, true)
    if not env then vim.msg = 'ai: no parameter'; return end
    local pos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
    local len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
    edit.auto_item(env, pos, len)
    state.envs = true
    vim.msg = ('automation item: %s / %s, %.3fs at %.3fs'):format(f.name, p.name, len, pos)
  end,
  dsp_pick_param = function(k)
    local col, f = ctx.dsp_fx(k)
    if not f then vim.msg = 'dsp: no fx'; return end
    vim.open_picker('automate ' .. f.name, (function()
      local items = {}
      for pi = 0, f.np - 1 do local _, pn = model.fxapi(col.track).GetParamName(col.track, f.i, pi, ''); items[#items + 1] = { label = pn or ('p' .. pi), data = pi } end
      return items end)(), function(it) if edit.fx_envelope(col.track, f.i, it.data) then
        if col.take then vim.msg = 'take envelope on the instrument item: ' .. f.name .. ' / ' .. it.label
        else state.envs = true; vim.msg = 'automation: ' .. f.name .. ' / ' .. it.label end
      end end)
  end,
  dsp_value = function(k, pi, d, coarse)
    local col, f = ctx.dsp_fx(k)
    local p = f and f.params[pi]
    if not p then return end
    local id = p.fx or f.i
    local v = model.fxapi(col.track).GetParamNormalized(col.track, id, p.i)
    if p.kind == 'toggle' then edit.fx_param(col.track, id, p.i, v >= 0.5 and 0 or 1)
    elseif p.kind == 'steps' and p.nsteps then edit.fx_param(col.track, id, p.i, v + d / (p.nsteps - 1))
    else edit.fx_param(col.track, id, p.i, v + d * (coarse and 0.1 or 0.02)) end
  end,
  dsp_enter = function(k, pi)
    local col, f = ctx.dsp_fx(k)
    local p = f and f.params[pi]
    if p and p.kind == 'toggle' then ctx.dsp_value(k, pi, 1) elseif f then edit.fx_bypass(col.track, f.i) end
  end,
  dsp_bypass = function(k) local col, f = ctx.dsp_fx(k); if f then edit.fx_bypass(col.track, f.i) end end,
  dsp_show = function(k) local col, f = ctx.dsp_fx(k); if f then edit.fx_show(col.track, f.i) end end,
  -- браузер эффектов: добавить выбранный FX на трек курсора (pos — место в цепочке)
  -- своё избранное и недавние браузера эффектов (persistent ExtState, метки)
  fxb_save = function()
    local fav = {}
    for l in pairs(FB.ownfav) do fav[#fav + 1] = l end
    table.sort(fav)
    reaper.SetExtState(EXT, 'fxfav', table.concat(fav, '\n'), true)
    reaper.SetExtState(EXT, 'fxrecent', table.concat(FB.recent, '\n'), true)
  end,
  -- нативные папки и метки: reaper-fxtags.ini ([category] / [developer]) и
  -- Favorites из reaper-fxfolders.ini (пути плагинов → ключ имени файла)
  fxb_load_native = function()
    local res = reaper.GetResourcePath()
    local cat, dev, fav = {}, {}, {}
    local f = io.open(res .. '/reaper-fxtags.ini', 'r')
    if f then
      local sec
      for line in f:lines() do
        local s2 = line:match('^%[(.-)%]')
        if s2 then sec = s2
        else
          local k, v = line:match('^(.-)=(.*)$')
          if k then if sec == 'category' then cat[k] = v elseif sec == 'developer' then dev[k] = v end end
        end
      end
      f:close()
    end
    local g = io.open(res .. '/reaper-fxfolders.ini', 'r')
    if g then
      local secs, sec = {}, nil
      for line in g:lines() do
        local s2 = line:match('^%[(.-)%]')
        if s2 then sec = s2; secs[sec] = secs[sec] or {}
        elseif sec then local k, v = line:match('^(.-)=(.*)$'); if k then secs[sec][k] = v end end
      end
      g:close()
      local idx = secs.Folders or {}
      for i = 0, (tonumber(idx.NbFolders) or 0) - 1 do
        if (idx['Name' .. i] or ''):lower() == 'favorites' then
          for k, v in pairs(secs['Folder' .. (idx['Id' .. i] or i)] or {}) do
            if k:match('^Item%d+$') then fav[((v:gsub('<.*$', ''):match('([^/\\]+)$') or v):gsub(' ', '_'))] = true end
          end
        end
      end
    end
    FB.set_tags(cat, dev, fav)
    for l in (reaper.GetExtState(EXT, 'fxfav') or ''):gmatch('[^\n]+') do FB.ownfav[l] = true end
    FB.recent = {}
    for l in (reaper.GetExtState(EXT, 'fxrecent') or ''):gmatch('[^\n]+') do FB.recent[#FB.recent + 1] = l end
  end,
  fxb_add = function(it, pos)
    it = it or FB.selected()
    local col = dsp_target()
    if not (it and col) then vim.msg = 'fx: nothing selected'; return end
    edit.fx_add(col.track, it.data, pos)
    FB.push_recent(it); ctx.fxb_save()
    state.dsp = true
    vim.msg = '+ ' .. (FB.short(it.label)) .. ' → ' .. (col.take and ('take fx of ' .. col.name) or col.name) .. (pos and (' @' .. (pos + 1)) or '')
    -- 5 окт: фокус — туда, откуда пришли к поиску эффектов
    if state.focus == 'fxb' and state.fxb_back and state.fxb_back ~= 'fxb' then local b = state.fxb_back; state.fxb_back = nil; ctx.set_focus(b) end
  end,
  -- dW: удалить весь item под курсором (для MIDI — item целиком, не ноту)
  item_at_cursor = function()
    local f = L.flat[vim.cur.fi]
    local cell = f and f.sub and f.sub[vim.cur.row]
    if cell and (cell.kind == 'cont' or cell.kind == 'off') then cell = cell.of end
    local item = cell and cell.item
    if item and reaper.ValidatePtr(item, 'MediaItem*') then return item end
    return nil
  end,
  delete_item_at_cursor = function()
    local f = L.flat[vim.cur.fi]
    local cell = f and f.sub and f.sub[vim.cur.row]
    if cell and (cell.kind == 'cont' or cell.kind == 'off') then cell = cell.of end
    local item = cell and cell.item
    if not (item and reaper.ValidatePtr(item, 'MediaItem*')) then vim.msg = 'dW: no item under cursor'; return false end
    local tr = reaper.GetMediaItemTrack(item)
    edit.run('delete item', function() reaper.DeleteTrackMediaItem(tr, item) end)
    vim.msg = 'dW: item deleted'
    return true
  end,
  -- dt: очистить трек курсора в его регионе; вне региона — от =START до =END
  -- (библиотека за =LIB не трогается)
  -- dr — трек курсора в регионе (вне региона — =START..=END); daw (all = true) —
  -- все item трека в песне, библиотека за =LIB остаётся (4 окт)
  -- строки региона под курсором (4 окт: скрэмбл без выделения) или nil
  scramble = function() vim.run_cmd('scramble') end,
  -- поле инструмента (5 окт): номер инструмента ноты и его смена — нота
  -- заменяется нотой инструмента n того же трека (строка, длина, питч те же)
  inst_num_of = function(h) return h and h.item and snap and ((snap.inst_num and snap.inst_num[h.item]) or (snap.inst_of and snap.inst_of[h.item])) end,
  set_inst = function(heads, n)
    local f = L.flat[vim.cur.fi]; local col = f and f.col
    local e = col and (col.pool or {})[n]
    if not (e and e.item) then vim.msg = ('no instrument %02d on this track'):format(n); return end
    local done = 0
    edit.run('set instrument', function()
      for _, h in ipairs(heads) do
        if h.kind == 'audio' then
          local pitch = model.BASE_NOTE + math.floor((h.semis or 0) + 0.5)
          local rows = math.max(1, h.rows or 1)
          edit.delete({ h }, state.lpb)
          edit.insert_note(col.track, nil, state.lpb, h.row0, pitch, vim.vel, rows, e.item)
          done = done + 1
        end
      end
    end)
    model.invalidate()
    vim.msg = done > 0 and ('instrument %02d (%s)'):format(n, e.name or '') or 'instrument: audio notes only'
  end,
  -- импульс ReaVerb (5 окт): путь к файлу — FILE0 плагина, иначе из его
  -- состояния в чанке трека (base64 → поиск пути .wav / .aif / .flac)
  ir_path_cache = {},
  ir_path = function(tr, fx)
    local guid = reaper.TrackFX_GetFXGUID(tr, fx) or tostring(fx)
    local c = ctx.ir_path_cache[guid]
    if c and reaper.time_precise() - c.t < 3 then return c.path end
    local path
    local ok, v = reaper.TrackFX_GetNamedConfigParm(tr, fx, 'FILE0')
    if ok and v and v ~= '' then path = v end
    if not path then
      local _, chunk = reaper.GetTrackStateChunk(tr, '', false)
      local B = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
      local function b64(s)
        s = s:gsub('[^' .. B .. '=]', '')
        return (s:gsub('.', function(x) if x == '=' then return '' end local r, f = '', (B:find(x) - 1); for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and '1' or '0') end; return r end)
          :gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x) if #x ~= 8 then return '' end local c2 = 0; for i = 1, 8 do c2 = c2 + (x:sub(i, i) == '1' and 2 ^ (8 - i) or 0) end; return string.char(c2) end))
      end
      for blk in (chunk or ''):gmatch('<VST "[^"]*ReaVerb[^"]*"[^\n]*\n(.-)\n>') do
        local data = b64(blk)
        local pth = data:match('(/[^%z\r\n]-%.[Ww][Aa][Vv])') or data:match('(/[^%z\r\n]-%.[Aa][Ii][Ff]+)') or data:match('(/[^%z\r\n]-%.[Ff][Ll][Aa][Cc])')
        if pth then path = pth; break end
      end
    end
    ctx.ir_path_cache[guid] = { path = path, t = reaper.time_precise() }
    return path
  end,
  -- спектрограмма записи lib / файла (5 окт): задание SL.sg; nil — не из чего
  sgram = function(e)
    if not e then return nil end
    local key, reader, sr, len
    if e.file and e.path then
      key = 'f:' .. e.path
      if SL.sg.jobs[key] then return SL.sg.jobs[key] end
      reader, sr, len = SL.sg.wav_reader(e.path)
    elseif e.take and reaper.ValidatePtr(e.take, 'MediaItem_Take*') then
      key = 't:' .. tostring(e.guid or e.item) .. ':' .. ('%.4f'):format(e.len or 0)
      if SL.sg.jobs[key] then return SL.sg.jobs[key] end
      reader, sr, len = SL.sg.take_reader(e.take)
      len = e.len or len
    end
    if not reader then return nil end
    return SL.sg.get(key, reader, len or 1, sr, 1024, 128)
  end,
  -- выбранный слайс инструмента (4 окт): { item = корень, k = 0 весь / 1.. }
  ssel = {},
  slice_root = function()
    local col = cur_col(); local e = col and (col.pool or {})[vim.inst]
    if e and e.parent then e = e.parent end
    return e, col
  end,
  slice_child = function(col, root, k)
    for _, c in ipairs(col and col.pool or {}) do if c.parent == root and c.slice_k == k then return c end end
  end,
  slice_step = function(d)
    local root, col = ctx.slice_root()
    if not (root and root.slices and #root.slices > 0) then return false end
    local cur = (ctx.ssel.item == root.item) and ctx.ssel.k or 0
    local k = math.max(0, math.min(#root.slices, cur + d))
    ctx.ssel = { item = root.item, k = k, cell = ctx.ssel.cell }
    if k > 0 then
      vim.last_slice = k
      ctx.preview_slice(col.track, root, root.slices[k], (not root.playthru and root.slices[k + 1]) or root.len)
      vim.msg = ('slice S%02X%s'):format(k, ctx.slice_child(col, root, k) and '' or ' (no notes yet - its properties work once it is inserted)')
    else vim.msg = 'whole sample' end
    return true
  end,
  -- нарезка во вкладке item (4 окт): s — меню, вторая клавиша — как резать
  -- квантайзер (5 окт): панель параметров — в работе; пока применяет план по умолчанию
  -- панель квантайзера (5 окт): параметры у свойств сэмпла, превью плана на волне
  quant_open = function()
    if not (SL.active and SL.entry and SL.entry.item) then vim.msg = 'quantize: pick a sample of the track first'; return end
    SL.detect(); SL.qpreview = true
    local q = SL.qprm
    local GRIDS = { ['1/4'] = 1, ['1/8'] = 0.5, ['1/16'] = 0.25, ['1/32'] = 0.125 }
    local items = {
      { label = 'grid', kind = 'cycle', values = { '1/4', '1/8', '1/16', '1/32' }, desc = 'where the hits go',
        get = function() for k, v in pairs(GRIDS) do if v == q.step then return k end end return '1/16' end, set = function(v) q.step = GRIDS[v] or 0.25 end },
      { label = 'catch %', kind = 'num', min = 5, max = 50, step = 5, desc = 'a hit further than this share of the grid step stays where it is',
        get = function() return math.floor(q.window * 100 + 0.5) end, set = function(v) q.window = v / 100 end },
      { label = 'max stretch %', kind = 'num', min = 5, max = 100, step = 5, desc = 'a piece between markers may get this much faster / slower, else the hit is skipped',
        get = function() return math.floor((q.maxr - 1) * 100 + 0.5) end, set = function(v) q.maxr = 1 + v / 100 end },
      { label = 'strength %', kind = 'num', min = 0, max = 100, step = 10, desc = 'how far towards the grid (100 = onto it)',
        get = function() return math.floor(q.strength * 100 + 0.5) end, set = function(v) q.strength = v / 100 end },
      { label = 'sensitivity', kind = 'num', min = 0, max = 100, step = 5, desc = 'more - more hits are caught',
        get = function() return math.floor(SL.sens * 100 + 0.5) end, set = function(v) SL.sens = v / 100; SL.detect() end },
      { label = 'apply', kind = 'action', value = 'stretch markers', desc = 'write the stretch markers as shown on the wave', fn = function() SL.smart_quantize(); SL.qpreview = false; vim.msg = SL.msg; model.invalidate() end },
      { label = 'remove markers', kind = 'action', value = 'clear', desc = 'remove all stretch markers of this sample', fn = function()
          local it = SL.entry.item; local tk = reaper.GetActiveTake(it)
          edit.run('remove stretch markers', function() local n = reaper.GetTakeNumStretchMarkers(tk); if n > 0 then reaper.DeleteTakeStretchMarkers(tk, 0, n) end; reaper.UpdateItemInProject(it) end)
          model.invalidate(); vim.msg = 'stretch markers removed' end },
    }
    local r = ctx.sprops_rect
    OPT.open_panel(items, 'quantize - cyan hit -> amber target, red skipped', r and { x = r[1], y = r[2] } or nil)
    vim.msg = 'quantize: tune, the wave shows the plan; apply writes the stretch markers'
  end,
  slice_quick = function(ch)
    local EQ = { ['@'] = 4, ['#'] = 8, ['$'] = 16, ['%'] = 32, ['^'] = 64, ['&'] = 128 }
    if not (EQ[ch] or ch == '!' or ch == 'Q') then return false end
    if not SL.active and ctx.open_slicer then ctx.open_slicer() end
    if not (SL.active and SL.entry and not SL.entry.file) then vim.msg = 'slice: pick a sample of the track first'; return true end
    if EQ[ch] then SL.equal(EQ[ch]); vim.msg = ('%d equal slices'):format(EQ[ch])
    elseif ch == '!' then
      -- повтор ! — следующая чувствительность по кругу
      local SENS = { 0.3, 0.5, 0.7, 0.9 }
      local now = reaper.time_precise()
      local i = (ctx.tr_cycle and now - ctx.tr_cycle.t < 8 and ctx.tr_cycle.entry == SL.entry.item) and (ctx.tr_cycle.i % #SENS + 1) or 1
      ctx.tr_cycle = { i = i, t = now, entry = SL.entry.item }
      SL.sens = SENS[i]; SL.use_transients()
      vim.msg = ('transients: %d slices (sens %.1f, ! again - %s)'):format(#(SL.slices or {}), SL.sens, i < #SENS and 'more' or 'back to few')
    elseif ch == 'Q' then ctx.quant_open()
    end
    model.invalidate()
    return true
  end,
  slice_hydra = function()
    -- слайсер на выбранном сэмпле должен быть открыт — иначе резать нечего
    local function ready() if not SL.active and ctx.open_slicer then ctx.open_slicer() end; return SL.active and SL.entry and not SL.entry.file end
    local function eq(n) return function() if not ready() then vim.msg = 'slice: pick a sample of the track first'; return end; SL.equal(n); vim.msg = ('%d equal slices'):format(n) end end
    vim.open_hydra({ title = 'slice', items = {
      { key = 's', label = 'smart: transients + spectrum (kick, then the next bright hit, then dark again ...)', fn = function() if not ready() then vim.msg = 'slice: pick a sample of the track first'; return end; SL.smart_slice(); vim.msg = 'smart slice: ' .. (SL.mode or '') end },
      { key = 't', label = 'at transients', fn = function() if not ready() then vim.msg = 'slice: pick a sample of the track first'; return end; SL.use_transients(); vim.msg = ('sliced at transients: %d slices'):format(#(SL.slices or {})) end },
      { key = '2', label = '2 equal', fn = eq(2) }, { key = '4', label = '4 equal', fn = eq(4) }, { key = '8', label = '8 equal', fn = eq(8) },
      { key = '1', label = '16 equal', fn = eq(16) }, { key = '3', label = '32 equal', fn = eq(32) }, { key = '6', label = '64 equal', fn = eq(64) },
      { key = 'd', label = 'delete the slices', fn = function() if not ready() then return end; SL.clear() end },        -- s d (4 окт): d = delete, как в Vim
      { key = 'Q', label = 'quantize ... (panel, the plan on the wave)', fn = function() if not ready() then return end; ctx.quant_open() end },
      { key = 'z', label = 'autotrim the silence', fn = function() if not ready() then return end; SL.autotrim() end },
    } })
    state.popup_at = { kind = 'sprops' }                -- поверх панели свойств сэмпла (5 окт)
  end,
  octave = function() return vim.octave end,                            -- подписи слайсов в слайсере (4 окт)
  slice_base = function() return (model.SLICE_BASE or model.BASE_NOTE or 60) + 1 end,   -- нота слайса 1; C-4 = весь сэмпл (5 окт)     -- кнопка scramble вкладки item (4 окт)
  region_rows = function()
    local rg = alias.region_at(regions, edit.row_time(vim.cur.row, state.lpb, 0))
    if not rg then return nil end
    return math.floor(rg.r0 + 1e-6), math.ceil(rg.r1 - 1e-6) - 1, rg
  end,
  clear_track = function(all)
    local f = L.flat[vim.cur.fi]
    if not (f and f.col) then return false end
    local tr = f.col.track
    local rg = (not all) and alias.region_at(regions, edit.row_time(vim.cur.row, state.lpb, 0)) or nil
    local t0 = rg and rg.pos or (model.marker_pos(model.START_MARKER) or 0)
    local t1 = rg and rg.rgnend or model.marker_pos(model.END_MARKER) or (regions.lib_pos or math.huge)
    local n = 0
    edit.run('clear track', function()
      for i = reaper.CountTrackMediaItems(tr) - 1, 0, -1 do
        local it = reaper.GetTrackMediaItem(tr, i)
        local pos = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
        if pos >= t0 - 1e-6 and pos < t1 - 1e-6 then reaper.DeleteTrackMediaItem(tr, it); n = n + 1 end
      end
    end)
    vim.msg = ('%s: %d item(s) of %s cleared in %s'):format(all and 'daw' or 'dr', n, f.col.name, rg and (rg.name ~= '' and rg.name or ('region ' .. rg.idx)) or 'the song (the lib after =LIB kept)')
    return n > 0
  end,
  -- dt (4 окт) — вырезать выделенное время во всём проекте: нативное «Remove
  -- contents of time selection (moving later items)», всё после — сдвигается
  delete_time = function()
    local t0, t1 = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if t1 <= t0 + 1e-6 then vim.msg = 'dt: no time selection (drag the row numbers or V + :sel)'; return false end
    local cmd = ctx.cmd_by_text('Time selection: Remove contents of time selection (moving later items)') or 40201
    reaper.Main_OnCommand(cmd, 0)
    model.invalidate()
    vim.msg = ('dt: %.3f s removed from the project (%.3f-%.3f), later items moved'):format(t1 - t0, t0, t1)
    return true
  end,
  -- dd (4 окт) — удалить трек курсора целиком (с FX), один undo
  delete_track = function()
    local f = L.flat[vim.cur.fi]
    if not (f and f.col and reaper.ValidatePtr(f.col.track, 'MediaTrack*')) then return false end
    local name = f.col.name
    edit.run('delete track', function() reaper.DeleteTrack(f.col.track) end)
    model.invalidate()
    vim.msg = 'dd: track ' .. (name or '') .. ' deleted (ctrl+z - back)'
    return true
  end,
  -- страница справки для модуля в фокусе
  help_page = function()
    local f = state.focus
    if f == 'tracker' then return vim.mode == 'insert' and 'insert' or 'tracker'
    elseif f == 'browser' and B.mode == 'pm' and B.grid and state.pmgrid and not B.pmproj then return 'pm'
    elseif f == 'matrix' or f == 'inst' or f == 'browser' or f == 'fxb' or f == 'notes' or f == 'ctrl' then return f
    elseif f == 'dsp' then return state.khelp and 'help' or 'dsp'
    elseif f == 'top' then
      local t = state.toptab
      if t == 'garden' then return 'orca' end                   -- Garden убран: только Orca
      if t == 'scope' then return 'master' end
      return KH.PAGES[t] and t or 'tracker'
    end
    return 'tracker'
  end,
  toggle_help = function()
    state.khelp = not state.khelp
    if not state.khelp and state.focus == 'dsp' and not state.dsp then ctx.set_focus('tracker') end
    KH.pinned = false
    vim.msg = state.khelp and 'help: keys of the focused module below; Tab to it for search' or 'help off'
  end,
  mods = function()
    local cap = inject_cap or gfx.mouse_cap
    return { cmd = cap & 4 == 4, ctrl = cap & 32 == 32, alt = cap & 16 == 16, shift = cap & 8 == 8 }
  end,
  -- слайсер: оверлей нарезки инструмента (двойной клик по сэмплу / :slice / \is)
  slicer_active = function() return SL.active end,
  slicer_key = function(c) SL.key(c) end,
  open_slicer = function(n)
    local col = cur_col(); if not col then return end
    if n then pool_select(n) end
    local e = col.pool[n or vim.inst]
    if not e then vim.msg = 'no instrument'; return end
    -- слайс / кусок: редактируется исходник (его нарезка), кусок подсвечен зоной (2 окт)
    if e.parent then e = e.parent end
    SL.open(e, col.track)
    state.toptab = 'sample'
    state.focus = 'top'; MX.focus = false; B.focus = false
  end,
  peaks = model.peaks,
  -- `a` — все треки разом (сбрасывает поканальные переключения кнопкой A)
  toggle_envs = function() state.envs = not state.envs; state.trackenvs = {}; vim.msg = 'envelopes ' .. (state.envs and 'on' or 'off') .. ' (all tracks)' end,
  -- кнопка A в шапке — только этот трек
  toggle_track_envs = function(col)
    local cur = state.trackenvs[col.guid]; if cur == nil then cur = state.envs end
    state.trackenvs[col.guid] = not cur
    vim.msg = col.name .. ': envelopes ' .. (not cur and 'on' or 'off')
  end,
  -- действие REAPER по подстроке названия (скан 40000..42700 один раз, кеш)
  cmd_by_text = function(pat)
    cmd_text_cache = cmd_text_cache or {}
    if cmd_text_cache[pat] ~= nil then return cmd_text_cache[pat] or nil end
    local found
    local lp = pat:lower()
    for id = 40000, 42700 do
      local t = reaper.kbd_getTextFromCmd(id, 0)
      if t and t:lower():find(lp, 1, true) then found = id; break end
    end
    cmd_text_cache[pat] = found or false
    return found
  end,
  -- ── модуляционная матрица ──
  mod_field = function(r, key, val) local col = cur_col(); if col then edit.mod_field(col.track, r.fx, r.param, key, val) end end,
  mod_remove = function(r) local col = cur_col(); if col then edit.mod_remove(col.track, r.fx, r.param); vim.msg = 'modulation removed: ' .. r.pname end end,
  mod_open_fx = function(r) local col = cur_col(); if col then edit.fx_show(col.track, r.fx) end end,
  mod_window = function(r)
    local col = cur_col(); if not col then return end
    local v = reaper.TrackFX_GetParamNormalized(col.track, r.fx, r.param)
    reaper.TrackFX_SetParamNormalized(col.track, r.fx, r.param, v)       -- «последний тронутый»
    local cmd = ctx.cmd_by_text('parameter modulation/link') or ctx.cmd_by_text('parameter modulation')
    if cmd then reaper.Main_OnCommand(cmd, 0) else vim.msg = 'no modulation window action' end
  end,
  -- ── панель params (3 окт, jf_tracker_params.lua) ──
  edit_run = function(name, fn) edit.run(name, fn); model.invalidate() end,
  msg = function(s) vim.msg = s end,
  fx_addresses = function(tr) return model.fx_addresses(tr) end,
  open_picker = function(title, items, fn) vim.open_picker(title, items, fn) end,
  fx_show = function(fx) local col = cur_col(); if col then edit.fx_show(col.track, fx) end end,
  envs_shown = function()
    local col = cur_col(); if not col then return false end
    local v = state.trackenvs[col.guid]; if v == nil then v = state.envs end
    return v
  end,
  -- действие над треком, выделенным одним; выделение пользователя возвращается
  with_only_track = function(tr, fn)
    local sel = {}
    for i = 0, reaper.CountSelectedTracks(0) - 1 do sel[#sel + 1] = reaper.GetSelectedTrack(0, i) end
    reaper.SetOnlyTrackSelected(tr)
    fn()
    reaper.SetTrackSelected(tr, false)
    for _, t in ipairs(sel) do reaper.SetTrackSelected(t, true) end
  end,
  mod_add = function(r)
    local col = cur_col(); if not col then return end
    local base = reaper.TrackFX_GetParamNormalized(col.track, r.fx, r.param)
    edit.mod_field(col.track, r.fx, r.param, 'mod.baseline', ('%.4f'):format(base))
    edit.mod_field(col.track, r.fx, r.param, 'lfo.active', 1)
    model.invalidate()
    vim.msg = 'modulating ' .. r.label .. ' (L1 on) - m again: to the matrix'
  end,
  -- строка параметра в матрице модуляции
  mod_goto = function(r)
    local col = cur_col()
    for i, m in ipairs(col and col.mods or {}) do
      if m.fx == r.fx and m.param == r.param then MMX.row = i; break end
    end
    mod_pane = 'matrix'
  end,
  -- кривая LFO-генератора в огибающую строки (создаётся видимой)
  curve_to = function(tr, r)
    local env = MMX.PP.env_of(tr, r, false)
    if not env then MMX.PP.toggle_env(tr, r); env = MMX.PP.env_of(tr, r, false) end
    if not env then vim.msg = 'no envelope for ' .. r.label; return end
    reaper.SetCursorContext(2, env)
    model.invalidate()
    mod_pane = 'lfo'
    vim.msg = 'curves → ' .. r.label .. ' (g: automation item, p: points)'
  end,
  -- trim ПКМ: вкладка modulation, панель params на этом треке
  open_params = function(col)
    for i, f in ipairs(L and L.flat or {}) do if f.col == col then vim.cur.fi = i; break end end
    state.top = true; state.toptab = 'modulation'; mod_pane = 'params'
    ctx.set_focus('top')
    vim.msg = col.name .. ': all parameters - Enter: envelope, m: modulate, c: curve, v: used only, P: back'
  end,
  -- все параметры FX трека для fzf
  mod_param_items = function(skip)
    local col = cur_col(); if not col then return {} end
    local items = {}
    -- все FX, включая детей контейнеров (адреса 0x2000000…): модуляция нативна и на них
    for _, fa in ipairs(model.fx_addresses(col.track)) do
      local fx = fa.fx
      local _, fn = reaper.TrackFX_GetFXName(col.track, fx, ''); fn = fa.prefix .. (fn or ''):gsub('^[^:]*: ', '')
      for pi = 0, reaper.TrackFX_GetNumParams(col.track, fx) - 1 do
        if not (skip and skip.fx == fx and skip.param == pi) then
          local _, pn = reaper.TrackFX_GetParamName(col.track, fx, pi, '')
          items[#items + 1] = { label = fn .. ' / ' .. (pn or ('p' .. pi)), data = { fx = fx, param = pi } }
        end
      end
    end
    return items
  end,
  -- ── LFO → automation item / точки (2 окт, jf_tracker_lfogen.lua) ─────
  -- огибающая: колонка огибающей под курсором трекера, иначе выбранная в
  -- REAPER (своя запись из снимка, если трек виден). Где: time selection,
  -- иначе регион курсора, иначе такт от строки курсора.
  lfo_target = function()
    local ae = state.ai_edit
    if ae and mod_pane == 'ai' and reaper.ValidatePtr(ae.env, 'TrackEnvelope*') then
      return { e = { env = ae.env, min = ae.min, max = ae.max, name = ae.label }, label = 'item ' .. (ae.label or ''), ai = ae }
    end
    local f = L and L.flat[vim.cur.fi]
    if f and f.env then return { e = f.env, label = (f.col and f.col.name or '') .. ' / ' .. (f.env.name or 'env') } end
    local se = reaper.GetSelectedEnvelope(0)
    if not se then return nil end
    for _, c in ipairs(snap and snap.cols or {}) do
      for _, e in ipairs(c.envs or {}) do if e.env == se then return { e = e, label = c.name .. ' / ' .. e.name } end end
    end
    local _, nm = reaper.GetEnvelopeName(se, '')
    return { e = { env = se, name = nm or 'env', min = 0, max = 1 }, label = (nm or 'env') .. ' (selected)' }
  end,
  -- длина цели генератора в строках — для превью
  lfo_span_rows = function()
    local tg = ctx.lfo_target()
    local t0, t1
    if tg and tg.ai then t0, t1 = tg.ai.pos, tg.ai.pos + tg.ai.len else t0, t1 = ctx.lfo_span() end
    return model.row_of_time(t1, state.lpb) - model.row_of_time(t0, state.lpb)
  end,
  lfo_span = function()
    local t0, t1 = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if t1 > t0 + 1e-6 then return t0, t1, 'time selection' end
    local rg = alias.region_at(regions, edit.row_time(vim.cur.row, state.lpb, 0))
    if rg then return rg.pos, rg.rgnend, 'region ' .. (rg.name ~= '' and rg.name or rg.idx) end
    local t = edit.row_time(vim.cur.row, state.lpb, 0)
    local qn = reaper.TimeMap2_timeToQN(0, t)
    local _, qms, qme = reaper.TimeMap_QNToMeasures(0, qn + 1e-6)
    return t, reaper.TimeMap2_QNToTime(0, (qme and qms) and (qn + (qme - qms)) or (qn + 4)), 'one bar'
  end,
  -- follow env: огибающая-источник из всех огибающих проекта (fzf)
  lfo_pick_env = function()
    local items = {}
    for _, c in ipairs(snap and snap.cols or {}) do
      for _, e in ipairs(c.envs or {}) do items[#items + 1] = { label = c.name .. ' / ' .. e.name, data = e } end
    end
    if #items == 0 then vim.msg = 'follow: no visible envelopes (A on a track shows them)'; return end
    vim.open_picker('follow envelope', items, function(it) lfo_src_env = it.data; LG.src_env = it.label end)
  end,
  -- хиты подката (строки, дробные): события колонки или транзиенты её аудио
  lfo_hits = function(col, r0, r1)
    local hits = {}
    local lo, hi = r0 - LG.hold - LG.release, r1 + LG.lead
    if LG.hits == 'events' then
      for _, lane in ipairs(col.lanes or {}) do
        for _, sub in ipairs(lane.subs or {}) do
          for r, cell in pairs(sub) do
            if (cell.kind == 'audio' or cell.kind == 'midi') and cell.row0 == r then
              local h = r + (cell.delay or 0) / 256
              if h >= lo and h < hi then hits[#hits + 1] = h end
            end
          end
        end
      end
    else
      -- транзиенты аудио items трека: пики 200 Гц, рост над порогом (как anticipate)
      local t_lo, t_hi = edit.row_time(math.floor(lo), state.lpb, 0), edit.row_time(math.ceil(hi), state.lpb, 0)
      local thr = 0.02 + (1 - LG.sens) ^ 2 * 0.6
      for i = 0, reaper.CountTrackMediaItems(col.track) - 1 do
        local it = reaper.GetTrackMediaItem(col.track, i)
        local pos = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
        local len = reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
        local tk = reaper.GetActiveTake(it)
        if tk and not reaper.TakeIsMIDI(tk) and pos < t_hi and pos + len > t_lo then
          local src = reaper.GetMediaItemTake_Source(tk)
          local offs = reaper.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS')
          local rate = reaper.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
          local n = math.max(1, math.min(200000, math.floor(len * rate * 200)))
          local buf = reaper.new_array(n * 2)
          local rv = reaper.PCM_Source_GetPeaks(src, 200, offs, 1, n, 0, buf)
          local spl = rv & 0xfffff
          if spl > 0 then
            local t = buf.table()
            local prev, last = 0, -1e9
            for k = 1, spl do
              local a = math.max(math.abs(t[k] or 0), math.abs(t[n + k] or 0))   -- min — после n запрошенных
              local tm = pos + (k - 1) / 200 / (rate ~= 0 and rate or 1)
              if a - prev > thr and a > 0.05 and tm - last > 0.06 then
                local h = model.row_of_time(tm, state.lpb)
                if h >= lo and h < hi then hits[#hits + 1] = h end
                last = tm
              end
              prev = a
            end
          end
        end
      end
    end
    table.sort(hits)
    local out = {}
    for _, h in ipairs(hits) do if #out == 0 or h - out[#out] > 0.05 then out[#out + 1] = h end end
    return out
  end,
  -- источник follow: функция строка → 0..1 (огибающая или громкость аудио трека)
  lfo_follow_src = function(col, r0, r1)
    if LG.fsrc == 'env' then
      local e = lfo_src_env
      if not (e and e.env and reaper.ValidatePtr(e.env, 'TrackEnvelope*')) then return nil, 'pick the source envelope (Enter on source)' end
      local lo, hi = e.min or 0, e.max or 1
      return function(row)
        local _, v = reaper.Envelope_Evaluate(e.env, edit.row_time(row, state.lpb, 0), 0, 0)
        return ((v or lo) - lo) / ((hi - lo) ~= 0 and (hi - lo) or 1)
      end
    end
    -- громкость аудио: пики 100 Гц по items трека, нормализация по пику
    local t_lo, t_hi = edit.row_time(r0 - 16, state.lpb, 0), edit.row_time(r1 + 16, state.lpb, 0)
    local segs, peak = {}, 1e-6
    for i = 0, reaper.CountTrackMediaItems(col.track) - 1 do
      local it = reaper.GetTrackMediaItem(col.track, i)
      local pos = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
      local len = reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
      local tk = reaper.GetActiveTake(it)
      if tk and not reaper.TakeIsMIDI(tk) and pos < t_hi and pos + len > t_lo then
        local src = reaper.GetMediaItemTake_Source(tk)
        local rate = reaper.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
        local n = math.max(1, math.min(200000, math.floor(len * rate * 100)))
        local buf = reaper.new_array(n * 2)
        local rv = reaper.PCM_Source_GetPeaks(src, 100, reaper.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS'), 1, n, 0, buf)
        local spl = rv & 0xfffff
        if spl > 0 then
          local t, a = buf.table(), {}
          for k = 1, spl do a[k] = math.max(math.abs(t[k] or 0), math.abs(t[n + k] or 0)); if a[k] > peak then peak = a[k] end end   -- min — после n запрошенных
          segs[#segs + 1] = { pos = pos, len = len, rate = (rate ~= 0 and rate or 1), a = a }
        end
      end
    end
    if #segs == 0 then return nil, 'no audio on ' .. col.name end
    return function(row)
      local tm = edit.row_time(row, state.lpb, 0)
      for _, sg in ipairs(segs) do
        if tm >= sg.pos and tm < sg.pos + sg.len then
          local k = math.floor((tm - sg.pos) * sg.rate * 100) + 1
          return (sg.a[k] or 0) / peak
        end
      end
      return 0
    end
  end,
  lfo_make = function(mode)
    local tg = ctx.lfo_target()
    if not tg then vim.msg = 'LFO: put the tracker cursor on an envelope column (or select an envelope in REAPER)'; return end
    local e = tg.e
    local t0, t1, where = ctx.lfo_span()
    if tg.ai then t0, t1, where = tg.ai.pos, tg.ai.pos + tg.ai.len, 'automation item'; mode = 'into' end
    local r0, r1 = model.row_of_time(t0, state.lpb), model.row_of_time(t1, state.lpb)
    local pts
    -- 5 окт: волна от начала цели (как в превью), а не от строки 0 проекта
    if LG.type == 'lfo' then pts = LG.points(0, r1 - r0); for _, p in ipairs(pts) do p.row = p.row + r0 end
    else
      local scol = snap and snap.cols[LG.src_i]
      if not scol and not (LG.type == 'follow' and LG.fsrc == 'env') then vim.msg = LG.type .. ': no source track'; return end
      if LG.type == 'podkat' then
        local hits = ctx.lfo_hits(scol, r0, r1)
        if #hits == 0 then vim.msg = ('podkat: no %s on %s in the span'):format(LG.hits, scol.name); return end
        pts = LG.podkat_points(hits, r0, r1)
      else
        local fn, why = ctx.lfo_follow_src(scol, r0, r1)
        if not fn then vim.msg = 'follow: ' .. tostring(why); return end
        pts = LG.follow_points(fn, r0, r1)
      end
    end
    -- 6 окт: шкала огибающей — громкость фейдерная; 0..1 — между min и max в шкале
    local lo, hi = e.min or 0, e.max or 1
    local smode = reaper.GetEnvelopeScalingMode(e.env)
    -- e.min / e.max уже в шкале огибающей (модель, 6 окт)
    local function raw(v) return lo + math.max(0, math.min(1, v)) * (hi - lo) end
    local n = 0
    edit.run(mode == 'ai' and 'LFO automation item' or 'LFO points', function()
      local idx = mode == 'into' and tg.ai.idx or -1
      if mode == 'ai' then
        idx = reaper.InsertAutomationItem(e.env, -1, t0, t1 - t0)
        if not idx or idx < 0 then return end
      end
      reaper.DeleteEnvelopePointRangeEx(e.env, idx, t0 - 1e-6, t1 - 1e-6)
      for _, p in ipairs(pts) do
        local t = edit.row_time(p.row, state.lpb, 0)
        if t >= t0 - 1e-6 and t < t1 - 1e-6 then
          reaper.InsertEnvelopePointEx(e.env, idx, t, raw(p.v), p.shape, 0, false, true)
          n = n + 1
        end
      end
      reaper.Envelope_SortPointsEx(e.env, idx)
    end)
    state.envs = true
    local what = LG.type == 'lfo' and ('LFO %s %d rows'):format(LG.shape, LG.period)
      or (LG.type == 'podkat' and ('podkat %s from %s'):format(LG.hits, LG.src_names[LG.src_i] or '?'))
      or ('follow %s'):format(LG.fsrc == 'env' and (LG.src_env or '?') or ('audio of ' .. (LG.src_names[LG.src_i] or '?')))
    vim.msg = ('%s -> %s: %s, %d points (%s)'):format(what, mode == 'ai' and 'auto-item' or 'envelope', tg.label, n, where)
  end,
  mod_add_pick = function()
    local col = cur_col(); if not col then return end
    vim.open_picker('modulate parameter', ctx.mod_param_items(), function(it)
      local base = reaper.TrackFX_GetParamNormalized(col.track, it.data.fx, it.data.param)
      edit.mod_field(col.track, it.data.fx, it.data.param, 'mod.baseline', ('%.4f'):format(base))
      edit.mod_field(col.track, it.data.fx, it.data.param, 'lfo.active', 1)
      vim.msg = 'modulating ' .. it.label .. ' (L1 on)'
    end)
  end,
  mod_link_pick = function(r)
    local col = cur_col(); if not col then return end
    vim.open_picker('link ' .. r.pname .. ' to', ctx.mod_param_items({ fx = r.fx, param = r.param }), function(it)
      edit.mod_set(col.track, r.fx, r.param, 'plink', true, it.data.fx, it.data.param)
    end)
  end,
  -- x-fade: авто при вставке (вкл/выкл), длина, кроссфейд событий сейчас
  xfade_toggle = function() state.xfade = not state.xfade; vim.msg = ('x-fade on insert: %s (%d ms)'):format(state.xfade and 'on' or 'off', state.xfade_ms) end,
  xfade_len = function(d, abs)
    state.xfade_ms = math.max(1, math.min(500, abs or (state.xfade_ms + d)))
    vim.msg = ('x-fade %d ms'):format(state.xfade_ms)
  end,
  -- кроссфейд сейчас: VISUAL — выделенные события; иначе — колонка курсора в регионе курсора
  xfade_now = function()
    local heads
    if vim.mode == 'visual' or vim.mode == 'vline' then
      local f0, f1, r0, r1 = vim.visual_range(); heads = vim.heads_in(f0, f1, r0, r1)
    else
      local t = edit.row_time(vim.cur.row, state.lpb, 0)
      local rg = alias.region_at(regions, t)
      local r0, r1 = 0, (snap.last_row or 0) + 1
      if rg then r0, r1 = rg.r0, math.max(rg.r0, rg.r1 - 1) end   -- heads_in включительно, r1 региона — нет
      local f = L.flat[vim.cur.fi]
      local fi0, fi1 = vim.cur.fi, vim.cur.fi
      if f and f.col then
        -- все подколонки трека курсора
        for i, g in ipairs(L.flat) do if g.col == f.col and not g.env then fi0 = math.min(fi0, i); fi1 = math.max(fi1, i) end end
      end
      heads = vim.heads_in(fi0, fi1, r0, r1)
    end
    local n = edit.xfade_heads(heads, (state.xfade_ms or 10) / 1000)
    vim.msg = ('x-fade %d ms: %d join(s)'):format(state.xfade_ms, n)
  end,
  xfade_clear = function()
    local f = L.flat[vim.cur.fi]
    local heads = vim.heads_in(1, #L.flat, 0, (snap.last_row or 0) + 1)
    local mine = {}
    for _, h in ipairs(heads) do if f and h.item and reaper.GetMediaItem_Track(h.item) == f.col.track then mine[#mine + 1] = h end end
    local n = edit.xfade_heads(mine, 0)
    vim.msg = ('x-fade cleared on %d join(s)'):format(n)
  end,
  -- колонка волны: off → peaks → rect → spec (контрол «wave», :wave [режим])
  wave_mode = function(m, delta)
    -- колонка волны: только on/off — спектральные пики REAPER + stretch-маркеры
    -- три режима (3 окт): column → note → off; :wave column|note|off (on = column)
    local nxt = { column = 'note', note = 'back', back = 'off', off = 'column' }
    if m == 'on' or m == 'spec' or m == 'column' then state.wavemode = 'column'
    elseif m == 'note' or m == 'off' or m == 'back' then state.wavemode = m
    else state.wavemode = nxt[state.wavemode or 'column'] end
    state.wave = state.wavemode == 'column' and 'spec' or 'off'
    vim.msg = 'wave: ' .. ({ column = 'own column - spectral peaks (colour = frequency), amber = stretch markers', note = 'in the note field on the item rows', back = 'background - the whole item width, dim, under the text', off = 'off' })[state.wavemode]
  end,
  -- анализатор: scope → spec → sgram (кнопки у вкладок, :scopemode)
  scopemode = function(m)
    local order = { scope = 'spec', spec = 'sgram', sgram = 'scope' }
    state.scopemode = (m == 'scope' or m == 'spec' or m == 'sgram') and m or order[state.scopemode or 'scope']
    vim.msg = 'analyzer: ' .. state.scopemode
  end,
  mono_take = function(on) mono_request(on and MONO_ID or -1) end,
  retro_preview = function(on) return retro_preview(on) end,
  retro_all = function() retro.sel.a, retro.sel.b = 0, 1 end,
  retro_cycle = function(d)
    local _, trs = retro_current()
    if #trs == 0 then return end
    local i = ((retro.cur_i or 1) - 1 + d) % #trs + 1
    retro.cur = { col = trs[i], slot = trs[i].rec_slot, len = 40, srate = 48000, head = 0 }; retro.cur_i = i
  end,
  retro_add = function()
    local col = cur_col(); if not col then return end
    local ok, slot = edit.retro_add(col.track, snap.cols)
    vim.msg = ok and ('jf_rec on ' .. col.name .. ' slot ' .. slot) or 'jf_rec: add failed (Effects/jf_rec.jsfx?)'
    model.invalidate()
  end,
  retro_nudge = function(edge, d)
    local sel = retro.sel
    if edge == 'a' then sel.a = math.max(0, math.min(1, sel.a + d)) elseif edge == 'b' then sel.b = math.max(0, math.min(1, sel.b + d))
    else local w = sel.b - sel.a; sel.a = math.max(0, math.min(1 - w, sel.a + d)); sel.b = sel.a + w end
  end,
  -- время внутри региона: n строк от row; all — все треки (Shift)
  time_edit = function(what, fi, row, n, all)
    local f = L.flat[fi]; if not f or not f.col then return end
    local t0 = edit.row_time(row, state.lpb, 0)
    local t1 = edit.row_time(row + math.max(1, n or 1), state.lpb, 0)
    local rg = alias.region_at(regions, t0)
    local limit = rg and rg.rgnend or reaper.GetProjectLength(0) + 60
    if t1 > limit then t1 = limit end
    local trs = {}
    if all then for _, c in ipairs(snap.cols) do trs[#trs + 1] = c.track end else trs[1] = f.col.track end
    if what == 'delete' then edit.time_delete(trs, t0, t1, limit) else edit.time_insert(trs, t0, t1 - t0, limit) end
    vim.msg = ('%s time: %d row(s) %s%s'):format(what, n or 1, all and 'all tracks' or f.col.name, rg and (' in ' .. (rg.name ~= '' and rg.name or 'region')) or ' (no region: to project end)')
  end,
  -- блок матрицы: mute / cut / copy / paste (буфер — state.mx_clip)
  mx_block = function(what)
    if #seq == 0 then return end
    local r0, r1, c0, c1 = MX.block()
    if what == 'copy' then
      state.mx_clip = alias.cells_copy(seq, snap, r0, r1, c0, c1)
      state.mx_reg = { kind = 'cells' }
      vim.msg = ('matrix: copied %dx%d block'):format(r1 - r0 + 1, c1 - c0 + 1)
    elseif what == 'cut' then
      state.mx_clip = alias.cells_copy(seq, snap, r0, r1, c0, c1)
      state.mx_reg = { kind = 'cells' }
      local n
      edit.run('matrix cut', function() n = alias.cells_delete(seq, snap, r0, r1, c0, c1) end)
      vim.msg = ('matrix: cut %d item(s)'):format(n or 0)
    elseif what == 'mute' then
      local f
      edit.run('matrix mute block', function() f = alias.cells_mute(seq, snap, r0, r1, c0, c1) end)
      vim.msg = f == nil and 'matrix: block is empty' or ('matrix: block ' .. (f and 'muted' or 'unmuted'))
    elseif what == 'paste' then
      if not state.mx_clip then vim.msg = 'matrix: clipboard empty (Ctrl+C)'; return end
      local n
      edit.run('matrix paste', function() n = alias.cells_paste(seq, snap, MX.cur.ri, MX.cur.ci, state.mx_clip) end)
      vim.msg = ('matrix: pasted %d item(s)'):format(n or 0)
    end
    MX.anchor = nil
  end,
  -- матрица: обрезать items по границам регионов (кнопка trim / t / :trim)
  mx_trim = function()
    if #seq == 0 then vim.msg = 'no regions'; return end
    local n = 0
    edit.run('matrix trim', function() n = alias.trim(ctx.real_seq()) end)
    vim.msg = ('trim: %d item edge(s) cut to region bounds'):format(n)
  end,
  -- `o` — показать событие под курсором в REAPER: выделить item, зум на него,
  -- трек в видимую область, окно REAPER на передний план
  reveal_item = function()
    local f = L.flat[vim.cur.fi]
    local cell = f and f.sub and f.sub[vim.cur.row]
    if cell and (cell.kind == 'cont' or cell.kind == 'off') then cell = cell.of end
    local item = cell and cell.item
    if not item then vim.msg = 'no item under cursor'; return end
    reaper.PreventUIRefresh(1)
    reaper.SelectAllMediaItems(0, false)
    reaper.SetMediaItemSelected(item, true)
    reaper.SetOnlyTrackSelected(reaper.GetMediaItemTrack(item))
    reaper.PreventUIRefresh(-1)
    reaper.Main_OnCommand(40913, 0)   -- Track: Vertical scroll selected tracks into view
    reaper.Main_OnCommand(41622, 0)   -- View: Toggle zoom to selected items
    reaper.UpdateArrange()
    if reaper.JS_Window_SetForeground then reaper.JS_Window_SetForeground(reaper.GetMainHwnd()) end
    vim.msg = 'reveal: ' .. (cell.name or cell.note or '')
  end,
  -- осциллоскопы: JSFX-мост на всех треках (кроме DEPOT), чтение gmem
  -- fzf по всем установленным эффектам → добавить на трек курсора (DSP: a или /, hydra \f)
  fx_picker = function()
    local col = dsp_target(); if not col then return end
    vim.open_picker('add fx to ' .. (col.take and ('take fx of ' .. col.name) or col.name), ctx.fx_list(), function(it)
      edit.fx_add(col.track, it.data); state.dsp = true
      vim.msg = '+ ' .. it.label
    end)
  end,
  -- / в DSP (7 окт): поиск по уже добавленным эффектам и их параметрам;
  -- Enter — фокус на найденном (эффект или параметр)
  dsp_find = function()
    local t = dsp_target(); if not t then return end
    local items = {}
    for k, f in ipairs(t.fx or {}) do
      items[#items + 1] = { label = f.name, data = { k, 1 } }
      for pi, p in ipairs(f.params or {}) do items[#items + 1] = { label = f.name .. ' > ' .. (p.name or '?'), data = { k, pi } } end
    end
    if #items == 0 then vim.msg = 'no fx yet - af adds one'; return end
    vim.open_picker('find in the chain of ' .. (t.name or ''), items, function(it)
      dsp_sel.fx, dsp_sel.param = it.data[1], it.data[2]
      state.dsp = true; ctx.set_focus('dsp')
      vim.msg = it.label
    end)
  end,
  -- есть ли take FX у нот инструмента (7 окт, метка fx в колонке слайсов):
  -- карта номер в пуле → true, раз на снимок
  inst_has_fx = function(e)
    if ctx.ihf_snap ~= snap then
      ctx.ihf_snap, ctx.ihf = snap, {}
      for it, i in pairs(snap and snap.inst_of or {}) do
        local tk = reaper.ValidatePtr(it, 'MediaItem*') and reaper.GetActiveTake(it)
        if tk and reaper.TakeFX_GetCount(tk) > 0 then ctx.ihf[i] = true end
      end
    end
    for i, pe in ipairs(snap and snap.pool or {}) do if pe == e then return ctx.ihf[i] or false end end
    return false
  end,
  -- aF (7 окт): take FX на ноту / слайс под курсором трекера (её item)
  dsp_take_slice = function()
    local f = L.flat and L.flat[vim.cur.fi]
    local cell = f and f.sub and f.sub[vim.cur.row]
    if cell and cell.kind == 'cont' then cell = cell.of end
    local it = cell and cell.item
    local tk = it and reaper.ValidatePtr(it, 'MediaItem*') and reaper.GetActiveTake(it)
    if not tk then vim.msg = 'aF: put the tracker cursor on a note / slice first'; return end
    vim.open_picker('take fx of the note under the cursor', ctx.fx_list(), function(x)
      edit.run('take fx on the slice', function() reaper.TakeFX_AddByName(tk, x.data, -1) end)
      model.invalidate()
      vim.msg = '+ ' .. x.label .. ' (take fx of the note under the cursor)'
    end)
  end,
  fx_list = function()
    local items = {}
    if reaper.EnumInstalledFX then
      local i = 0
      while true do
        local ok, name, ident = reaper.EnumInstalledFX(i)
        if not ok then break end
        items[#items + 1] = { label = name, data = ident }
        i = i + 1
        if i > 5000 then break end
      end
    end
    return items
  end,
  toggle_dsp = function() state.dsp = not state.dsp; if not state.dsp and state.focus == 'dsp' then ctx.set_focus('tracker') end end,
  -- скопы (3 окт, вернули): мост jf_tracker_scope на каждый трек и мастер —
  -- осциллограф в шапке трека, анализатор вкладки master; выкл — мосты сняты
  toggle_scopes = function(on)
    if on == nil then on = not state.scopes end
    state.scopes = on
    edit.scopes(snap.cols, on)
    model.invalidate()
    vim.msg = on and 'scopes on: a scope row in every track header (jf_tracker_scope on the tracks and the master)' or 'scopes off: bridges taken off the tracks'
  end,
  -- fzf по всем параметрам автоматизации трека (кнопка trim — её трек, иначе
  -- трек курсора): огибающие трека и каждый параметр каждого FX, включая
  -- детей контейнеров (перечень панели params). Есть огибающая — сверху, ●;
  -- выбор — создать / показать огибающую (уже видна — не прятать)
  automation_picker = function(col, from_btn)
    col = col or cur_col(); if not col then return end
    local tr = col.track
    local PP = MMX.PP
    local items, rest = {}, {}
    for _, r in ipairs(PP.build(tr, model.fx_addresses)) do
      local env = PP.env_of(tr, r, false)
      local it = { label = (env and '● ' or '  ') .. r.label, data = r }
      if env then items[#items + 1] = it else rest[#rest + 1] = it end
    end
    for _, it in ipairs(rest) do items[#items + 1] = it end
    if #items == 0 then vim.msg = 'nothing to automate'; return end
    vim.open_picker('automation ' .. col.name .. ' (rclick trim: all parameters)', items, function(it)
      local r = it.data
      local env = PP.env_of(tr, r, false)
      local vis = env and select(2, reaper.GetSetEnvelopeInfo_String(env, 'VISIBLE', '', false)) == '1'
      if not vis then PP.toggle_env(tr, r) end
      state.trackenvs[col.guid] = true
      model.invalidate()
      vim.msg = 'envelope: ' .. r.label
    end)
    if from_btn then vim.picker.trim = col.guid; state.popup_at = { kind = 'trim', guid = col.guid } end
  end,
  preview_slice = function(track, entry, t0, t1, semis) PV.slice(track, entry, t0, t1, semis) end,
  -- выбранный слайс (4 окт): последний выделенный мышкой / Option+J K / сыгранный;
  -- 0 — весь айтем. Option+нота играет и пишет его с питчем
  selected_slice = function(root) if root and ctx.ssel.item == root.item then return ctx.ssel.k or 0 end return nil end,
  select_slice = function(root, k) if root then ctx.ssel = { item = root.item, k = k, cell = ctx.ssel.cell } end end,
  set_last_slice = function(k) vim.last_slice = k end,
  mx_zoom = function() MX.toggle_zoom() end,
  mx_fold_toggle = function() MX.fold = not MX.fold; state.mxfold = MX.fold; vim.msg = MX.fold and 'matrix folded: numbers, tracks, cells (fold / F to unfold)' or 'matrix unfolded' end,
  vtext = draw.vtext,
  -- огибающие: точка в строке (tol — полстроки), значение 0..1
  env_set = function(e, row, v)
    local t = edit.swing_time(row, state.lpb)                 -- свинг и для точек (6 окт)
    edit.env_set(e, t, v, (edit.row_time(row + 1, state.lpb, 0) - t) / 2)
  end,
  env_ramp = function(e, r0, r1, v0, v1)
    local t0, t1 = edit.row_time(r0, state.lpb, 0), edit.row_time(r1, state.lpb, 0)
    edit.env_ramp(e, t0, t1, v0, v1, (edit.row_time(r0 + 1, state.lpb, 0) - t0) / 2)
  end,
  env_del = function(e, row)
    local t = edit.row_time(row, state.lpb, 0)
    if not edit.env_del(e, t, (edit.row_time(row + 1, state.lpb, 0) - t) / 2) then vim.msg = 'no point here' end
  end,
  -- точки огибающей для Vim (2 окт): строки с точками (кэш на снимок), чтение,
  -- удаление и вставка диапазона строк. Время → строка тем же правилом, что
  -- у модели: точка в строке r, если row_time(r) <= t < row_time(r + 1).
  env_point_rows = function(e)
    env_rows_cache = env_rows_cache or {}
    local c = env_rows_cache[e.env]
    if c and c.snap == snap and c.lpb == state.lpb then return c.rows end
    local rows_, seen = {}, {}
    for i = 0, reaper.CountEnvelopePoints(e.env) - 1 do
      local ok, t = reaper.GetEnvelopePoint(e.env, i)
      if ok then
        local r = math.floor(model.row_of_time(t, state.lpb) + 1e-6)
        if not seen[r] then seen[r] = true; rows_[#rows_ + 1] = r end
      end
    end
    table.sort(rows_)
    env_rows_cache[e.env] = { snap = snap, lpb = state.lpb, rows = rows_ }
    return rows_
  end,
  env_points = function(e, r0, r1)
    local t0 = edit.row_time(r0, state.lpb, 0)
    local pts = edit.env_points(e, t0, edit.row_time(r1 + 1, state.lpb, 0))
    -- в регистре — сдвиг в QN от начала диапазона (темп цели может быть другим)
    local q0 = reaper.TimeMap2_timeToQN(0, t0)
    for _, p in ipairs(pts) do p.dq = reaper.TimeMap2_timeToQN(0, p.t) - q0; p.t = nil end
    return pts
  end,
  env_del_range = function(e, r0, r1)
    local n = edit.env_del_range(e, edit.row_time(r0, state.lpb, 0), edit.row_time(r1 + 1, state.lpb, 0))
    vim.msg = ('%s: %d point(s) deleted'):format(e.name or 'envelope', n)
  end,
  env_paste = function(e, row, reg)
    local t0 = edit.row_time(row, state.lpb, 0)
    local q0 = reaper.TimeMap2_timeToQN(0, t0)
    local pts = {}
    for _, p in ipairs(reg.pts or {}) do pts[#pts + 1] = { t = reaper.TimeMap2_QNToTime(0, q0 + p.dq), v = p.v, shape = p.shape, tension = p.tension } end
    edit.env_put_points(e, t0, edit.row_time(row + (reg.rows or 1), state.lpb, 0), pts)
    vim.msg = ('%s: %d point(s) pasted'):format(e.name or 'envelope', #pts)
  end,
  -- форма сегмента точки строки (2 окт): lin sqr slo fas fae bez
  env_shape = function(e, row, shape)
    local ok = edit.env_shape(e, edit.row_time(row, state.lpb, 0), edit.row_time(row + 1, state.lpb, 0), shape)
    if ok then vim.msg = 'shape ' .. (vim.SHAPES[shape + 1] or shape) else vim.msg = 'no point in this row' end
    return ok
  end,
  env_shape_step = function(e, row, d)
    local cur = edit.env_get_shape(e, edit.row_time(row, state.lpb, 0), edit.row_time(row + 1, state.lpb, 0))
    if not cur then vim.msg = 'no point in this row'; return end
    ctx.env_shape(e, row, (cur + d) % 6)
  end,
  envfmt = function() return state.envfmt or 'midi' end,
  -- быстрые опции (6 окт): набор настраивается ПКМ по имени опции в окне
  -- Options (точка перед именем — «есть в быстрых»). Три колонки «a,b|c|d»;
  -- ключ опции → id встроенной клетки, где она есть; иначе клетка общая
  QUICK_DEFAULT = 'q_mx,q_ruler,q_hints,q_listen,debug,measure,title|clipsview,dsp_big,mixer,q_scopes,q_input,q_captions,q_names,q_wave,q_colors,q_envs,q_meters,q_dsp|whichkey,q_side,q_preview,q_keys,oneclick,autofocus,perf,follow,lock,fixed,xfade',
  QUICK_ALIAS = { hints = 'q_hints', steplisten = 'q_listen', scopes = 'q_scopes', hdrin = 'q_input', captions = 'q_captions', itemnames = 'q_names',
    wavemode = 'q_wave', itemcol = 'q_colors', envs = 'q_envs', meters = 'q_meters', dsp = 'q_dsp', side = 'q_side', preview = 'q_preview',
    tlruler = 'q_ruler', keycast = 'q_keys', endstop = 'q_endstop' },
  quick_str = function()
    local q = state.quick
    -- 7 окт: session и router — в начале средней колонки (и в своей раскладке)
    if q and not q:find('measure', 1, true) then   -- 7 окт: measure — в конец левой колонки
      local a, rest = q:match('^([^|]*)(|.*)$')
      if a then q = a .. ',measure' .. rest; state.quick = q end
    end
    if q and q:find('dsp_big', 1, true) and not q:find('whichkey', 1, true) then   -- whichkey — в начало третьей колонки
      local a, b, c3 = q:match('^([^|]*)|([^|]*)|(.*)$')
      if a then q = a .. '|' .. b .. '|whichkey,' .. c3; state.quick = q end
    end
    if q and not q:find('title', 1, true) then local a, rest = q:match('^([^|]*)(|.*)$'); if a then q = a .. ',title' .. rest; state.quick = q end end   -- 8 окт: title — в конец левой колонки
    if q and q:find('dsp_big', 1, true) and not q:find('mixer', 1, true) then q = q:gsub('dsp_big', 'dsp_big,mixer', 1); state.quick = q end   -- 8 окт: mixer — под router
    if q and not q:find('dsp_big', 1, true) then
      q = q:gsub(',?clipsview', ''):gsub('^,', ''):gsub('|,', '|')
      local a, b = q:match('^([^|]*)|(.*)$')
      q = a and (a .. '|clipsview,dsp_big,' .. b) or q
      state.quick = q
    end
    return q or ctx.QUICK_DEFAULT
  end,
  quick_has = function(key)
    local id = ctx.QUICK_ALIAS[key] or key
    for x in ctx.quick_str():gmatch('[^,|]+') do if x == id then return true end end
    return false
  end,
  quick_toggle = function(key, label)
    local id = ctx.QUICK_ALIAS[key] or key
    local cols = {}
    for part in (ctx.quick_str() .. '|'):gmatch('([^|]*)|') do
      local col = {}
      for x in part:gmatch('[^,]+') do if x ~= id then col[#col + 1] = x end end
      cols[#cols + 1] = col
    end
    while #cols > 3 do table.remove(cols) end
    for k = #cols + 1, 3 do cols[k] = {} end
    local had = ctx.quick_has(key)
    if not had then                                  -- добавить в самую короткую колонку
      local best = 1
      for k = 2, 3 do if #cols[k] < #cols[best] then best = k end end
      table.insert(cols[best], id)
    end
    local parts = {}
    for k = 1, 3 do parts[k] = table.concat(cols[k], ',') end
    state.quick = table.concat(parts, '|')
    vim.msg = (label or key) .. (had and ' removed from' or ' added to') .. ' the quick options'
  end,
  -- клетки быстрых опций, которых нет среди встроенных: подпись и вкл из списка Options
  quick_generic = function()
    local out, BUILT = {}, { q_mx = 1, q_ruler = 1, q_hints = 1, q_listen = 1, debug = 1, q_scopes = 1, q_input = 1, q_captions = 1, q_names = 1, q_wave = 1,
      q_colors = 1, q_envs = 1, q_meters = 1, q_dsp = 1, q_side = 1, q_preview = 1, q_keys = 1, oneclick = 1, autofocus = 1, perf = 1, follow = 1, lock = 1, fixed = 1, xfade = 1, q_endstop = 1 }
    local need = {}
    for x in ctx.quick_str():gmatch('[^,|]+') do if not BUILT[x] then need[x] = true end end
    if next(need) == nil then return out end
    local now = reaper.time_precise()                -- список Options — не каждый кадр (2 Гц)
    if ctx.qgen_cache and now - ctx.qgen_t < 0.5 and ctx.qgen_key == ctx.quick_str() then return ctx.qgen_cache end
    ctx.qgen_t, ctx.qgen_key, ctx.qgen_cache = now, ctx.quick_str(), out
    ctx.qitems = ctx.qitems or {}
    for _, it in ipairs(ctx.option_items()) do
      if it.key and need[it.key] then
        ctx.qitems[it.key] = it
        local v = it.get and it.get()
        out[it.key] = { label = it.label, on = it.kind == 'toggle' and v and true or (it.kind ~= 'toggle' and v ~= nil and v ~= 'off' and v ~= false) }
      end
    end
    return out
  end,
  jftop = function() ctrl_action('jftop', 0) end,                  -- :jftop (6 окт)
  -- свинг (6 окт): сетка проекта REAPER — вкл / величина / деление; кнопка
  -- swing на транспорте открывает выпадашку, колесо ±1 %, :swing N | on | off
  swing_label = function()
    local s = edit.sw
    if not s.on then return 'swing off' end
    local d = s.div / 4
    local dv = d > 0 and ('1/%g'):format(math.floor(1 / d * 100 + 0.5) / 100) or '?'
    return ('swing %d%% %s'):format(math.floor(s.amt * 100 + 0.5), dv)
  end,
  swing_text = function()
    local s = edit.sw
    if not s.on then return 'swing off - grid straight' end
    return ('%s (MPC %d%%): new notes, points and quantize follow the REAPER grid swing; items with swing off stay straight'):format(ctx.swing_label(), math.floor(50 + s.amt * 50 + 0.5))
  end,
  swing_menu = function()
    edit.swing_read()
    local s = edit.sw
    local cur = s.on and math.floor(s.amt * 100 + 0.5) or 0
    local items = {
      { key = 't', label = (s.on and 'turn off' or 'turn on') .. ' (REAPER grid swing)', fn = function() edit.swing_set(not s.on, (not s.on and math.abs(s.amt) < 0.01) and 0.33 or nil); vim.msg = ctx.swing_text() end },
    }
    for _, p in ipairs({ { '0', 0, 'straight' }, { '1', 10 }, { '2', 20 }, { '3', 33, 'triplet, MPC 66' }, { '4', 40 }, { '5', 50, 'MPC 75' }, { '6', 66 }, { '7', 75 }, { '-', -25, 'early' } }) do
      items[#items + 1] = { key = p[1], label = ('%d%%%s%s'):format(p[2], p[3] and ('  ' .. p[3]) or '', (s.on and cur == p[2]) and '  *' or ''),
        fn = function() edit.swing_set(p[2] ~= 0, p[2] / 100); vim.msg = ctx.swing_text() end }
    end
    local d = s.div / 4
    for _, g in ipairs({ { 'q', '1/4', 0.25 }, { 'w', '1/8', 0.125 }, { 'e', '1/16', 0.0625 }, { 'r', '1/32', 0.03125 } }) do
      items[#items + 1] = { key = g[1], label = 'grid ' .. g[2] .. (math.abs(d - g[3]) < 1e-6 and '  *' or ''), fn = function() edit.swing_set(nil, nil, g[3]); vim.msg = ctx.swing_text() end }
    end
    items[#items + 1] = { key = 'c', label = 'custom … (:swing N, -100..100)', fn = function() vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'swing ' end }
    vim.open_hydra({ title = 'swing - ' .. ctx.swing_label(), items = items })
    state.popup_at = { kind = 'strip', id = 'swing' }
  end,
  swing_cmd = function(arg)
    arg = (arg or ''):lower()
    local n = tonumber(arg:match('^%s*(%-?%d+%.?%d*)'))
    local g = arg:match('1/(%d+)')
    if arg:match('off') then edit.swing_set(false)
    elseif n then edit.swing_set(n ~= 0, n / 100)
    elseif arg:match('on') then edit.swing_set(true, math.abs(edit.sw.amt) < 0.01 and 0.33 or nil)
    elseif not g then ctx.swing_menu(); return end
    if g then edit.swing_set(nil, nil, 1 / tonumber(g)) end
    vim.msg = ctx.swing_text()
  end,
  -- спрятать лейн огибающей (6 окт, − в шапке лейна): огибающая и точки
  -- остаются, + / a+ показывает снова
  env_hide = function(e)
    if not (e and reaper.ValidatePtr(e.env, 'TrackEnvelope*')) then return end
    edit.run('hide envelope ' .. (e.name or ''), function()
      reaper.GetSetEnvelopeInfo_String(e.env, 'VISIBLE', '0', true)
      reaper.TrackList_AdjustWindows(false)
    end)
    model.invalidate()
    vim.msg = (e.name or 'envelope') .. ' lane hidden - + shows it again'
  end,
  -- :logo (6 окт): артворк по центру трекера, каждый раз другой (:logo имя —
  -- конкретный); любая клавиша или клик закрывает. Рисуется один раз в
  -- картинку 98 (дизеринг попиксельный), дальше только blit
  -- :dev (6 окт): вид разработчика вкл / выкл — переименование .dev <-> .dev-off
  -- рядом со скриптом (без шелла). off = трекер как у пользователей релиза.
  -- Флаги читаются при старте, поэтому — перезапуск трекера. В копии без
  -- обоих файлов (релиз) команда ничего не делает
  dev_set = function(arg)
    local on, off = DIR .. '/.dev', DIR .. '/.dev-off'
    local has_on, has_off = reaper.file_exists(on), reaper.file_exists(off)
    if not (has_on or has_off) then vim.msg = 'dev: not a developer copy'; return end
    local want = arg == 'on' or (arg ~= 'off' and not has_on)
    if want == has_on then vim.msg = 'dev is already ' .. (want and 'on' or 'off'); return end
    local ok = want and os.rename(off, on) or os.rename(on, off)
    vim.msg = ok and ('dev ' .. (want and 'on' or 'off - the user view') .. ': close and open the tracker') or 'dev: could not rename the file'
  end,
  logo_show = function(name)
    local list = {}
    for i, lg in ipairs(LOGO.LOGOS) do if not lg.scroll then list[#list + 1] = i end end
    local pick
    -- по имени — любой, в т.ч. бегущая строка (в случайный выбор она не идёт)
    if name and name ~= '' then for i, lg in ipairs(LOGO.LOGOS) do if lg.name:find(name, 1, true) then pick = i; break end end end
    if not pick then
      repeat pick = list[math.random(1, #list)] until #list < 2 or pick ~= (ctx.LOGOPOP_last or 0)
    end
    ctx.LOGOPOP_last = pick
    ctx.LOGOPOP = { lg = LOGO.LOGOS[pick], key = nil, cap = gfx.mouse_cap }
    vim.msg = 'logo ' .. LOGO.LOGOS[pick].name .. ' - any key closes'
  end,
  logo_draw = function()
    local P = ctx.LOGOPOP
    local r = draw.module_rects and draw.module_rects.tracker
    if not (P and r) then return end
    local rx, ry, rw, rh = r[1], r[2], r[3], r[4]
    local lw, lh = LOGO.size(P.lg)
    local cw, ch = LOGO.cell(P.lg, math.floor(rw * 0.85), L.cw * 2, L.rh * 2)
    if not cw then ctx.LOGOPOP = nil; return end
    if lh * ch > rh * 0.8 then
      cw, ch = LOGO.cell(P.lg, math.floor(rw * 0.85 * (rh * 0.8) / (lh * ch)), L.cw * 2, L.rh * 2)
      if not cw then ctx.LOGOPOP = nil; return end
    end
    local pad = 2 * cw
    local iw, ih = lw * cw + 2 * pad, lh * ch + 2 * pad + (P.lg.drip and 4 * ch or 0)
    local key = P.lg.name .. cw .. 'x' .. ch
    if P.key ~= key then
      local dest = gfx.dest
      gfx.setimgdim(98, -1, -1); gfx.setimgdim(98, iw, ih)
      gfx.dest = 98
      gfx.set(0, 0, 0, 1); gfx.rect(0, 0, iw, ih, 1)
      LOGO.draw(P.lg, pad, pad, cw, ch, U.AMBER, { text = U.TEXT, accent = U.AMBER, line = U.LINE })
      gfx.dest = dest
      P.key = key
    end
    local x = rx + math.floor((rw - iw) / 2)
    local y = ry + math.floor((rh - ih) / 2)
    gfx.blit(98, 1, 0, 0, 0, iw, ih, x, y, iw, ih)
    U.set(U.AMBER); gfx.rect(x - 1, y - 1, iw + 2, ih + 2, 0)
    -- клик (новый, не тот, что открыл) — закрыть
    local cap = gfx.mouse_cap
    if (cap & 3) ~= 0 and (P.cap & 3) == 0 then ctx.LOGOPOP = nil end
    if ctx.LOGOPOP then P.cap = cap end
  end,
  -- отладка (6 окт): опция debug — всё, что происходит, строками в файл
  -- <REAPER>/jf_tracker_debug.log: клавиши (режим, фокус, поле, где съедена —
  -- файл:строка возврата обработчика key), клики (что под мышью), действия
  -- контролов, команды, ошибки. Файл > 1 MB — обрезается до последней половины
  dlog_path = reaper.GetResourcePath() .. '/jf_tracker_debug.log',
  dlog = function(s)
    if not state.debug then return end
    local f = io.open(ctx.dlog_path, 'a'); if not f then return end
    f:write(os.date('%H:%M:%S'), ('.%03d '):format(math.floor(reaper.time_precise() * 1000) % 1000), s, '\n'); f:close()
    ctx.dlog_n = (ctx.dlog_n or 0) + 1
    if ctx.dlog_n % 200 == 0 then
      local fr = io.open(ctx.dlog_path, 'r'); local all = fr and fr:read('a'); if fr then fr:close() end
      if all and #all > 1000000 then local fw = io.open(ctx.dlog_path, 'w'); if fw then fw:write(all:sub(-500000)); fw:close() end end
    end
  end,
  env_nudge = function(e, row, d)
    local t = edit.row_time(row, state.lpb, 0)
    edit.env_nudge(e, t, d, (edit.row_time(row + 1, state.lpb, 0) - t) / 2)
  end,
  -- слот последовательности → следующий/предыдущий паттерн по номеру
  slot_cycle = function(ri, dir)
    local seq = ctx.sequence()
    local slot = seq[ri]
    if not slot then return end
    if slot.gap then vim.msg = 'free bar: name it first (n)'; return end
    local list, by = model.patterns(regions)
    if #list < 2 then vim.msg = 'only one pattern'; return end
    local k = 1
    for i, p in ipairs(list) do if p.name == slot.name then k = i end end
    local p = list[((k - 1 + dir) % #list) + 1]
    if alias.set_slot(regions, slot, p) then
      vim.msg = ('slot %d → %02d %s (%d/%d)'):format(ri, p.num, p.name, p.num, #list)
      model.invalidate()
      regions = model.regions(state.lpb)        -- следующий щелчок — по свежим регионам
      seq = ctx.sequence()
    end
  end,
  -- Последовательность матрицы: от =START до =END (2 окт). Регионы как есть,
  -- свободное место между ними и до =END — строки по такту (rg.gap = true),
  -- имя такой строки (n / dblclick) создаёт регион на этом такте. Кэш по
  -- таблице регионов, LPB и маркерам.
  MX_BARS = 512,
  sequence = function()
    local s0 = regions.start_pos or 0
    local s1 = regions.end_pos
    -- 8 окт: без =END матрица длинная — 512 тактов свободных строк от =START
    -- (маркер не ставится; :end переносит конец)
    if not s1 then
      local _, m0 = reaper.TimeMap2_timeToBeats(0, s0)
      s1 = reaper.TimeMap2_beatsToTime(0, 0, (m0 or 0) + ctx.MX_BARS)
    end
    local key = tostring(regions) .. '|' .. state.lpb .. '|' .. s0 .. '|' .. tostring(s1)
    if seq_cache.key == key then return seq_cache.seq end
    local out, real = {}, {}
    for _, rg in ipairs(regions) do
      if not rg.lib and not rg.session and rg.rgnend > s0 + 1e-6 and (not s1 or rg.pos < s1 - 1e-6) then real[#real + 1] = rg end
    end
    local function bars(t0, t1)
      local t, n = t0, 0
      while t < t1 - 1e-4 and n < 512 do
        local qn = reaper.TimeMap2_timeToQN(0, t)
        local _, _, qme = reaper.TimeMap_QNToMeasures(0, qn + 1e-6)
        local tn = qme and reaper.TimeMap2_QNToTime(0, qme) or t1
        if tn <= t + 1e-4 then tn = t1 end
        tn = math.min(tn, t1)
        local q0, q1 = reaper.TimeMap2_timeToQN(0, t), reaper.TimeMap2_timeToQN(0, tn)
        out[#out + 1] = { gap = true, idx = -1, name = '', pos = t, rgnend = tn, qn0 = q0, qn1 = q1,
                          r0 = (model.row_of_qn(q0, state.lpb)), r1 = (model.row_of_qn(q1, state.lpb)), color = 0 }
        t = tn; n = n + 1
      end
    end
    local t = s0
    for _, rg in ipairs(real) do
      if rg.pos > t + 1e-4 then bars(t, rg.pos) end
      out[#out + 1] = rg
      if rg.rgnend > t then t = rg.rgnend end
    end
    if s1 and t < s1 - 1e-4 then bars(t, s1) end
    out.lib_pos = regions.lib_pos
    seq_cache.key, seq_cache.seq = key, out
    return out
  end,
  -- только настоящие регионы последовательности (без свободных тактов)
  real_seq = function()
    local o = {}
    for _, r in ipairs(seq) do if not r.gap then o[#o + 1] = r end end
    o.lib_pos = seq.lib_pos
    return o
  end,
  -- ── матрица: регионы интерактивно (1 окт) ──────────────────────────
  -- + / :add — новый регион после последнего с начала следующего такта;
  -- :name — имя региона курсора; :len N|Ns|Nb — длина (шаги по LPB /
  -- секунды / такты): следующие регионы, маркеры (=END, =LIB) и items всех
  -- треков едут на разницу, их длины сохраняются.
  -- слой лупов в матрице (2 окт, бывший Garden): ячейка = период лупа item
  -- вкладки верхней панели; grid — по опции (monome есть не у всех)
  top_tabs = function()
    -- rec — снова своя вкладка, первая (3 окт, просьба): кольцо jf_rec трека
    -- 5 окт: grid и orca (только .dev) — в самом конце
    local t = { 'retro', 'sample', 'modulation', 'midi', 'scopes', 'master' }   -- 7 окт: вкладки clips нет — сессия в теле трекера (zs)
    if state.gridtab then t[#t + 1] = 'grid' end
    if state.dev then t[#t + 1] = 'garden' end
    return t
  end,
  mx_loops_toggle = function()
    MX.loops = not MX.loops
    vim.msg = MX.loops and 'matrix loops: digits+Enter loop N steps, > to region end, < fit, + - period, m mute' or 'matrix loops: off'
  end,
  -- маркеры =START / =END с поля матрицы (5 окт): arg — 'такт[.доля]',
  -- число секунд или nil (строка курсора трекера)
  seq_marker = function(which, arg)
    local name = which == 'start' and model.START_MARKER or model.END_MARKER
    local t
    if type(arg) == 'number' then t = arg
    elseif arg and arg ~= '' then
      local b, bt = arg:match('^(%d+)%.?(%d*)$')
      if not b then vim.msg = which .. ' bar[.beat], e.g. 9 or 9.3; empty = cursor row'; return end
      t = reaper.TimeMap2_beatsToTime(0, math.max(0, (tonumber(bt) or 1) - 1), math.max(0, tonumber(b) - 1))
    else t = edit.row_time(vim.cur.row, state.lpb, 0) end
    t = math.max(0, t)
    local other = model.marker_pos(which == 'start' and model.END_MARKER or model.START_MARKER)
    if other and ((which == 'start' and t >= other - 1e-6) or (which == 'end' and t <= other + 1e-6)) then
      vim.msg = which == 'start' and 'start must be before end' or 'end must be after start'; return
    end
    edit.run(name .. ' marker', function()
      local _, nmk, nrg = reaper.CountProjectMarkers(0)
      for i = 0, nmk + nrg - 1 do
        local _, isr, _, _, nm, idx, col = reaper.EnumProjectMarkers3(0, i)
        if not isr and nm == name then reaper.SetProjectMarkerByIndex(0, i, false, t, 0, idx, nm, col); return end
      end
      reaper.AddProjectMarker(0, false, t, 0, name, -1)
    end)
    ctx.mx_refresh()
    local bt, m = reaper.TimeMap2_timeToBeats(0, t)
    vim.msg = ('%s at %d.%d'):format(name, m + 1, math.floor(bt + 1e-6) + 1)
  end,
  -- колесом по полю: ±1 такт, доля в такте сохраняется
  seq_marker_nudge = function(which, d)
    local p = model.marker_pos(which == 'start' and model.START_MARKER or model.END_MARKER)
    if not p then return ctx.seq_marker(which) end
    local bt, m = reaper.TimeMap2_timeToBeats(0, p)
    if m + d < 0 then return end
    ctx.seq_marker(which, reaper.TimeMap2_beatsToTime(0, bt, m + d))
  end,
  -- «/» в поле имени (5 окт): список частых имён (правила SWS + запас),
  -- fzf по уже набранному; выбор подставляет имя, строка остаётся для Enter
  name_suggest = function(line)
    ctx.NAMES = ctx.NAMES or dofile(DIR .. '/jf_tracker_names.lua')
    local pre, kind = ctx.NAMES.target(line or '')
    if not pre then return false end
    local items = {}
    for _, nm in ipairs(ctx.NAMES.list(kind)) do items[#items + 1] = { label = nm } end
    local back = vim.cmd_from
    vim.open_picker(kind .. ' name', items, function(it)
      vim.cmd_from = back; vim.mode = 'cmd'; vim.cmdline = pre .. it.label
    end)
    vim.picker.query = line:sub(#pre + 1)
    vim.picker_refilter()
    -- набранное — старое имя целиком (поле с текущим именем): тогда весь список
    if #vim.picker.matches == 0 then vim.picker.query = ''; vim.picker_refilter() end
    return true
  end,
  keyq = {},
  -- / в трекере (6 окт): fzf по всему, что можно сделать под курсором
  command_search = function()
    local items = {}
    -- действия ячейки (как в контекстной гидре)
    local f = L and L.flat[vim.cur.fi]
    local hv = { fi = vim.cur.fi, row = { row = vim.cur.row }, field = vim.cur.field, fsub = vim.cur.sub, cell = f and f.sub and f.sub[vim.cur.row], col = f and f.col }
    for _, it in ipairs(ctx.context_items(hv) or {}) do
      if it[1] ~= '--' and it[2] then items[#items + 1] = { label = (it[1]:gsub('^!', '')), data = { fn = it[2] } } end
    end
    -- клавиши модуля (страница справки)
    local page = vim.mode == 'insert' and 'insert' or 'tracker'
    for _, e in ipairs((KH.PAGES[page] or {}).e or {}) do
      local first = e.k:match('^(%S+)')
      local codes = first and ctx.tok_codes(first)
      if codes then items[#items + 1] = { label = e.k .. '  -  ' .. e.d, data = { keys = codes } } end
    end
    -- :команды
    for _, c in ipairs(vim.COMMANDS or {}) do
      items[#items + 1] = { label = ':' .. c[1] .. (c[2] ~= '' and (' ' .. c[2]) or '') .. '  -  ' .. c[3], data = { cmd = c[1], args = c[2] } }
    end
    vim.open_picker('commands at the cursor', items, function(it)
      local d = it.data
      if d.fn then d.fn()
      elseif d.keys then for _, cd in ipairs(d.keys) do ctx.keyq[#ctx.keyq + 1] = cd end
      elseif d.cmd then
        if d.args == '' then vim.run_cmd(d.cmd)
        else vim.cmd_from = vim.mode == 'insert' and 'insert' or 'normal'; vim.mode = 'cmd'; vim.cmdline = d.cmd .. ' ' end
      end
    end)
  end,
  -- ── пик у курсора (5 окт): \q к сетке, \Q — куда укажешь ──────────────
  -- атака рядом с t (секунды item): аудио-аксессор, огибающая блоками 2 мс,
  -- атака — наибольший рост над средним 20 мс до неё
  peak_near = function(it, t, win)
    local tk = reaper.GetActiveTake(it)
    if not tk or reaper.TakeIsMIDI(tk) then return nil end
    local acc = reaper.CreateTakeAudioAccessor(tk)
    if not acc then return nil end
    local st = reaper.GetAudioAccessorStartTime(acc)
    local sr, blk = 22050, 44
    local a0 = math.max(0, t - win)
    local n = math.floor((2 * win) * sr)
    local buf = reaper.new_array(n)
    reaper.GetAudioAccessorSamples(acc, sr, 1, st + a0, n, buf)
    reaper.DestroyAudioAccessor(acc)
    local s = buf.table()
    local env = {}
    for b = 0, math.floor(n / blk) - 1 do
      local m = 0
      for i = b * blk + 1, (b + 1) * blk do local v = math.abs(s[i] or 0); if v > m then m = v end end
      env[#env + 1] = m
    end
    local best, bi = 0, nil
    for i = 11, #env do
      local avg = 0
      for j = i - 10, i - 1 do avg = avg + env[j] end
      avg = avg / 10
      local rise = env[i] - avg
      if rise > best then best, bi = rise, i end
    end
    if not bi or best < 0.02 then return nil end
    return a0 + (bi - 1) * blk / sr
  end,
  -- stretch-маркер: звук из точки from (секунды item) переезжает в to
  peak_move = function(it, from, to)
    local tk = reaper.GetActiveTake(it)
    local len = reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
    edit.run('move peak (stretch marker)', function()
      if reaper.GetTakeNumStretchMarkers(tk) == 0 then reaper.SetTakeStretchMarker(tk, -1, 0); reaper.SetTakeStretchMarker(tk, -1, len) end
      local idx
      for i = 0, reaper.GetTakeNumStretchMarkers(tk) - 1 do
        local _, pos = reaper.GetTakeStretchMarker(tk, i)
        if math.abs(pos - from) < 0.005 then idx = i end
      end
      idx = idx or reaper.SetTakeStretchMarker(tk, -1, from)
      local _, _, src = reaper.GetTakeStretchMarker(tk, idx)
      local lo, hi = 0.001, len - 0.001
      if idx > 0 then local _, p = reaper.GetTakeStretchMarker(tk, idx - 1); lo = p + 0.001 end
      if idx < reaper.GetTakeNumStretchMarkers(tk) - 1 then local _, p = reaper.GetTakeStretchMarker(tk, idx + 1); hi = p - 0.001 end
      reaper.SetTakeStretchMarker(tk, idx, math.max(lo, math.min(hi, to)), src)
      reaper.UpdateItemInProject(it)
    end)
    model.invalidate()
  end,
  peak_at_cursor = function()
    local h = vim.covering(vim.cur.fi, vim.cur.row)[1]
    if not (h and h.kind == 'audio' and h.item) then vim.msg = 'peak: put the cursor on a sample'; return nil end
    local pos = reaper.GetMediaItemInfo_Value(h.item, 'D_POSITION')
    local t = edit.row_time(vim.cur.row, state.lpb, 0) - pos
    local rl = edit.row_time(vim.cur.row + 1, state.lpb, 0) - edit.row_time(vim.cur.row, state.lpb, 0)
    local p = ctx.peak_near(h.item, t + rl / 2, math.max(0.03, rl))
    if not p then vim.msg = 'peak: no attack near the cursor'; return nil end
    return h.item, p, pos
  end,
  peak_quantize = function()
    local it, p, pos = ctx.peak_at_cursor(); if not it then return end
    local r = math.floor(model.row_of_time(pos + p, state.lpb) + 0.5)
    local to = edit.row_time(r, state.lpb, 0) - pos
    ctx.peak_move(it, p, to)
    vim.msg = ('peak %.3fs -> row %04d (%+.1f ms)'):format(p, r, (to - p) * 1000)
  end,
  peak_pick = function()
    local it, p, pos = ctx.peak_at_cursor(); if not it then return end
    ctx.qmove = { item = it, from = p, pos = pos }
    vim.msg = ('peak at %.3fs: j k - the target row, Enter moves it there (stretch marker), Esc cancels'):format(p)
  end,
  -- ── automation как инструмент (5 окт, как во FL) ─────────────────────
  -- строка automation последней в lib; список — пулы automation items трека
  -- курсора; нотная клавиша вставляет выбранный пул в его огибающую на курсор,
  -- скорость — от высоты: C-4 = ×1, октава вверх = ×2
  auto_on = function() return state.auto_inst and true or false end,
  auto_select = function()
    state.auto_inst = true
    local n = #ctx.ai_list()
    vim.msg = n > 0 and ('automation: %d item(s) of the track - pick one in the slices list, a note key inserts it (C-4 = x1)'):format(n) or 'automation: no automation items on this track yet'
  end,
  ai_sel = 1,
  -- кривые automation (6 окт): Data/jf_tracker_curves/*.jfcurve
  curve_dir = function()
    local d = reaper.GetResourcePath() .. '/Data/jf_tracker_curves'
    reaper.RecursiveCreateDirectory(d, 0)
    return d
  end,
  curve_save = function(name)
    local ae = state.ai_edit
    if not ae then vim.msg = 'curve: open an automation item first (double click in the automation list)'; return end
    name = (name or ''):gsub('[/\\:]', '_')
    if name == '' then vim.msg = 'curve: :curvesave name'; return end
    ctx.AIE = ctx.AIE or dofile(DIR .. '/jf_tracker_aiedit.lua')
    local path = ctx.curve_dir() .. '/' .. name .. '.jfcurve'
    vim.msg = ctx.AIE.save(ae, path) and ('curve saved: ' .. name) or 'curve: cannot write'
  end,
  curve_load = function(path)
    local ae = state.ai_edit
    if not ae then vim.msg = 'curve: open an automation item first (double click in the automation list)'; return end
    ctx.AIE = ctx.AIE or dofile(DIR .. '/jf_tracker_aiedit.lua')
    local n = ctx.AIE.load(ae, path)
    model.invalidate()
    vim.msg = ('curve loaded: %s, %d points'):format(path:match('([^/]+)%.jfcurve$') or path, n)
  end,
  curve_browse = function()
    state.side = true
    ctx.browse(ctx.curve_dir())
    ctx.set_focus('browser')
    vim.msg = 'curves: Enter loads one into the open automation item (save: the save envelope button / :curvesave name)'
  end,
  -- MIDI-лейны (6 окт): пустой лейн :cc N / :pc, правка событий строки
  ml_add = function(x)
    local col = cur_col(); if not col then return end
    local t = model.extra_lanes[col.guid] or {}
    for _, y in ipairs(t) do if y == x then vim.msg = 'lane exists'; return end end
    t[#t + 1] = x; model.extra_lanes[col.guid] = t
    state.midilanes = true; model.invalidate()
    vim.msg = (x == 'pc' and 'PC' or ('CC' .. x)) .. ' lane on ' .. (col.name or '') .. ' - type hex per row (INSERT), x deletes'
  end,
  -- MIDI take трека, покрывающий время t
  ml_take = function(tr, t)
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, i)
      local p = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
      local tk = reaper.GetActiveTake(it)
      if tk and reaper.TakeIsMIDI(tk) and t >= p - 1e-6 and t < p + reaper.GetMediaItemInfo_Value(it, 'D_LENGTH') - 1e-6 then return tk, it end
    end
  end,
  ml_clear = function(tk, ml, p0, p1)
    local _, _, ccn, txn = reaper.MIDI_CountEvts(tk)
    if ml.kind == 'cc' or ml.kind == 'pc' then
      for k = ccn - 1, 0, -1 do
        local _, _, _, ppq, cm, _, m2 = reaper.MIDI_GetCC(tk, k)
        if ppq >= p0 and ppq < p1 and ((ml.kind == 'cc' and cm == 0xB0 and m2 == ml.num) or (ml.kind == 'pc' and cm == 0xC0)) then reaper.MIDI_DeleteCC(tk, k) end
      end
    else
      for k = txn - 1, 0, -1 do
        local _, _, _, ppq, typ = reaper.MIDI_GetTextSysexEvt(tk, k)
        if ppq >= p0 and ppq < p1 and ((ml.kind == 'sx' and typ == -1) or (ml.kind == 'tx' and typ and typ >= 1)) then reaper.MIDI_DeleteTextSysexEvt(tk, k) end
      end
    end
  end,
  ml_set = function(f, row, v)
    local tr = f.col.track
    local t0, t1 = edit.row_time(row, state.lpb, 0), edit.row_time(row + 1, state.lpb, 0)
    local tk = ctx.ml_take(tr, t0)
    if not tk then vim.msg = 'midi lane: no MIDI item under this row (make one: \\ n)'; return end
    local ml = f.ml
    edit.run(ml.name .. ' value', function()
      local p0, p1 = reaper.MIDI_GetPPQPosFromProjTime(tk, t0), reaper.MIDI_GetPPQPosFromProjTime(tk, t1)
      ctx.ml_clear(tk, ml, p0, p1)
      if ml.kind == 'cc' then reaper.MIDI_InsertCC(tk, false, false, p0, 0xB0, 0, ml.num, v)
      else reaper.MIDI_InsertCC(tk, false, false, p0, 0xC0, 0, v, 0) end
      reaper.MIDI_Sort(tk)
    end)
    model.invalidate()
    vim.msg = ('%s %02X at %04d'):format(ml.name, v, row)
  end,
  ml_del = function(f, row)
    local tr = f.col.track
    local t0, t1 = edit.row_time(row, state.lpb, 0), edit.row_time(row + 1, state.lpb, 0)
    edit.run(f.ml.name .. ' delete', function()
      for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, i)
        local tk = reaper.GetActiveTake(it)
        if tk and reaper.TakeIsMIDI(tk) then
          ctx.ml_clear(tk, f.ml, reaper.MIDI_GetPPQPosFromProjTime(tk, t0), reaper.MIDI_GetPPQPosFromProjTime(tk, t1))
          reaper.MIDI_Sort(tk)
        end
      end
    end)
    model.invalidate()
  end,
  -- CC-лейны (6 окт, вариант A): ReaControlMIDI на треке курсора; номер CC
  -- каждой строки выставляется в окне плагина (он в его двоичном состоянии),
  -- значение строки — параметр: его огибающая становится колонкой трекера
  cc_lane = function(arg)
    if tonumber(arg) then return ctx.ml_add(math.max(0, math.min(127, math.floor(tonumber(arg))))) end
    local col = cur_col()
    if not col or col.take then vim.msg = 'cc: put the cursor on a track'; return end
    local tr = col.track
    local fx = reaper.TrackFX_AddByName(tr, 'ReaControlMIDI', false, 0)
    local added = false
    if fx < 0 then
      edit.run('add ReaControlMIDI', function() fx = reaper.TrackFX_AddByName(tr, 'ReaControlMIDI', false, 1) end)
      added = true
    end
    if not fx or fx < 0 then vim.msg = 'cc: ReaControlMIDI not found'; return end
    if added then reaper.TrackFX_Show(tr, fx, 3) end
    local items = {}
    for p = 0, reaper.TrackFX_GetNumParams(tr, fx) - 1 do
      local _, pn = reaper.TrackFX_GetParamName(tr, fx, p, '')
      local has = reaper.GetFXEnvelope(tr, fx, p, false) ~= nil
      items[#items + 1] = { label = (pn ~= '' and pn or ('param ' .. p)) .. (has and '  (lane)' or ''), data = p }
    end
    vim.open_picker('CC lane: ReaControlMIDI parameter' .. (added and ' - set the CC numbers in its window' or ''), items, function(it)
      if edit.fx_envelope(tr, fx, it.data) then
        state.envs = true
        state.trackenvs = state.trackenvs or {}; state.trackenvs[col.guid] = true
        vim.msg = 'CC lane: ' .. it.label .. ' - a column of the track (type hex values per row, curves, automation items)'
      end
    end)
  end,
  -- показать модуль элемента (6 окт): нота / слайс — его сэмпл во вкладке item,
  -- automation item — редактор во вкладке modulation; фокус не уводится
  show_element = function(fi, row)
    local f = L and L.flat[fi]
    if not f then return end
    local foc = state.focus
    if f.env then
      if ctx.ai_pick_at(fi, row) then
        local a = ctx.ai_list()[ctx.ai_sel]
        if a then ctx.ai_edit_open(a); ctx.set_focus(foc) end
      end
      return
    end
    local cell = f.sub and f.sub[row]
    if cell and cell.kind == 'cont' then cell = cell.of end
    local n = cell and cell.item and snap and snap.inst_of and snap.inst_of[cell.item]
    -- 7 окт: нота-слайс — инструмент её исходника. Слайс в lib скрыт, а
    -- pool_select принимает скрытый слайс за шаг навигации и уходил к
    -- СЛЕДУЮЩЕМУ исходнику: нарезка в INSERT перескакивала на другой инструмент
    local pe = n and snap.pool and snap.pool[n]
    if pe and pe.parent then for i, e in ipairs(snap.pool) do if e == pe.parent then n = i; break end end end
    if n and (n ~= vim.inst or state.toptab ~= 'sample' or not state.top) then
      local pp = state.poolprev; state.poolprev = false
      pool_select(n)
      state.poolprev = pp
      state.top = true; state.toptab = 'sample'
      ctx.set_focus(foc)
    end
  end,
  -- редактор automation item (5 окт): вкладка modulation, страница item
  ai_edit_open = function(a)
    ctx.AIE = ctx.AIE or dofile(DIR .. '/jf_tracker_aiedit.lua')
    ctx.AIE.on_save = function() vim.cmd_from = vim.mode == 'insert' and 'insert' or 'normal'; vim.mode = 'cmd'; vim.cmdline = 'curvesave ' end
    ctx.AIE.on_load = function() ctx.curve_browse() end
    ctx.AIE.on_pick = function(b)                                  -- другой лейн пула (6 окт)
      for i, c in ipairs(ctx.ai_list()) do if c == b then ctx.ai_sel = i end end
      ctx.ai_edit_open(b)
    end
    state.ai_edit = { env = a.env, idx = a.idx, pos = a.pos, len = a.len, label = a.label, min = a.min, max = a.max, pool = a.pool, col = a.col }
    state.top = true; state.toptab = 'modulation'; mod_pane = 'ai'; ctx.set_focus('top')
    vim.msg = 'automation item ' .. (a.label or '') .. ': edit the points, the generator on the right writes into it'
  end,
  -- VISUAL = ПКМ-рамка REAPER (6 окт): блок выделяет items треков своих
  -- колонок нот и точки огибающих (и automation items) своих лейнов в
  -- диапазоне строк; прежнее выделение REAPER заменяется. Только при смене блока
  vis_sync = function(vis)
    local key = ('%d|%d|%d|%d'):format(vis.f0, vis.f1, vis.r0, vis.r1)
    if key == ctx.vis_key or not L then return end
    ctx.vis_key = key
    local t0 = edit.row_time(vis.r0, state.lpb, 0)
    local t1 = edit.row_time(vis.r1 + 1, state.lpb, 0)
    local tracks, envs = {}, {}
    for fi = vis.f0, vis.f1 do
      local f = L.flat[fi]
      if f and f.env then envs[f.env.env] = f.env
      elseif f and not f.ml and f.col and f.col.track then tracks[f.col.track] = true end
    end
    reaper.PreventUIRefresh(1)
    reaper.SelectAllMediaItems(0, false)
    for tr in pairs(tracks) do
      if reaper.ValidatePtr(tr, 'MediaTrack*') then
        for k = 0, reaper.CountTrackMediaItems(tr) - 1 do
          local it = reaper.GetTrackMediaItem(tr, k)
          local p = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
          local l = reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
          if p < t1 - 1e-9 and p + l > t0 + 1e-9 then reaper.SetMediaItemSelected(it, true) end
        end
      end
    end
    for env in pairs(envs) do
      if reaper.ValidatePtr(env, 'TrackEnvelope*') then
        for ai = -1, reaper.CountAutomationItems(env) - 1 do
          -- точка пула повторяется в каждом проходе лупа: сперва снять весь
          -- пул (0x10000000), потом выделить попавшие проходы
          if ai >= 0 then
            local FI = ai | 0x10000000
            for p = 0, reaper.CountEnvelopePointsEx(env, FI) - 1 do
              reaper.SetEnvelopePointEx(env, FI, p, nil, nil, nil, nil, false, true)
            end
          end
          for p = 0, reaper.CountEnvelopePointsEx(env, ai) - 1 do
            local _, tm, _, _, _, was = reaper.GetEnvelopePointEx(env, ai, p)
            local on = tm >= t0 - 1e-9 and tm < t1 - 1e-9
            if on ~= was and (ai < 0 or on) then reaper.SetEnvelopePointEx(env, ai, p, nil, nil, nil, nil, on, true) end
          end
        end
      end
    end
    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
  end,
  ai_list = function()
    local col = cur_col(); if not col then return {} end
    local c = ctx.ai_cache
    if c and c.snap == snap and c.col == col then return c.list end
    local list, seen = {}, {}
    for _, e in ipairs(col.envs or {}) do
      for _, ai in ipairs(e.ais or {}) do
        local pid = math.floor((reaper.GetSetAutomationItemInfo(e.env, ai.idx, 'D_POOL_ID', 0, false) or 0) + 0.5)
        local key = tostring(e.env) .. ':' .. pid
        if not seen[key] then
          seen[key] = true
          -- превью (6 окт): один материнский проход пула, значения в шкале
          -- огибающей (громкость — фейдерная), как в редакторе и в REAPER
          local pts = {}
          local mode = reaper.GetEnvelopeScalingMode(e.env)
          local FI = ai.idx | 0x10000000
          for p = 0, reaper.CountEnvelopePointsEx(e.env, FI) - 1 do
            local _, t, v = reaper.GetEnvelopePointEx(e.env, FI, p)
            pts[#pts + 1] = { t, v }
          end
          local smin, smax = e.min or 0, e.max or 1
          -- e.min / e.max уже в шкале огибающей (модель)
          list[#list + 1] = { col = draw.env_colour and draw.env_colour(e) or nil, env = e.env, envname = e.name, idx = ai.idx, pool = pid, len = ai.len, pos = ai.pos,
            rate = reaper.GetSetAutomationItemInfo(e.env, ai.idx, 'D_PLAYRATE', 0, false) or 1, label = ai.label, pts = pts, min = e.min, max = e.max, smin = smin, smax = smax }
        end
      end
    end
    ctx.ai_cache = { snap = snap, col = col, list = list }
    if ctx.ai_sel > #list then ctx.ai_sel = math.max(1, #list) end
    return list
  end,
  ai_insert = function(pitch, row)
    local a = ctx.ai_list()[ctx.ai_sel]
    if not a then vim.msg = 'automation: no automation items on this track'; return false end
    local rate = 2 ^ ((pitch - 60) / 12)
    local t = edit.swing_time(row, state.lpb)
    local base = (a.len or 1) * (a.rate or 1)                  -- длина пула при ×1
    edit.run('insert automation item', function()
      local i = reaper.InsertAutomationItem(a.env, a.pool, t, base / rate)
      if i and i >= 0 then reaper.GetSetAutomationItemInfo(a.env, i, 'D_PLAYRATE', rate, true) end
    end)
    model.invalidate()
    vim.msg = ('automation %s x%.2f'):format(a.label, rate)
    return true
  end,
  -- Opt / Cmd+Enter на automation item: выбрать его пул в списке
  ai_pick_at = function(fi, row)
    local f = L and L.flat[fi]
    local e = f and f.env
    if not (e and e.ais) then return false end
    for _, ai in ipairs(e.ais) do
      if row >= math.floor(ai.r0 + 1e-6) and row < ai.r1 - 1e-6 then
        local pid = math.floor((reaper.GetSetAutomationItemInfo(e.env, ai.idx, 'D_POOL_ID', 0, false) or 0) + 0.5)
        state.auto_inst = true
        for i, a in ipairs(ctx.ai_list()) do if a.env == e.env and a.pool == pid then ctx.ai_sel = i end end
        vim.msg = 'automation: ' .. (ai.label or '')
        return true
      end
    end
    return false
  end,
  -- зум колесом (5 окт): общие модификаторы трекера и матрицы. Возвращает
  -- dv, dh — величины колеса для вертикального / горизонтального зума, или nil
  zoom_axes = function(wv, wh)
    local m = ctx.mods()
    if (state.zoommods or 'cmd') == 'split' then
      if m.cmd and not m.alt then return 0, (wv ~= 0 and wv or wh) end
      if m.alt and not m.cmd then return (wv ~= 0 and wv or wh), 0 end
      return nil
    end
    if m.cmd then return wv, wh end
    return nil
  end,
  zacc = { v = 0, h = 0 },
  -- дискретный шаг из колеса / трекпада: копится до 120 (щелчок колеса)
  zoom_steps = function(axis, amount)
    ctx.zacc[axis] = ctx.zacc[axis] + amount / 120
    local n = ctx.zacc[axis] >= 0 and math.floor(ctx.zacc[axis]) or math.ceil(ctx.zacc[axis])
    ctx.zacc[axis] = ctx.zacc[axis] - n
    return n
  end,
  -- v в свойствах сэмпла (5 окт): верхняя панель — ровно под все строки
  sprops_fit = function()
    local r = ctx.sprops_rect; if not r then return end
    local w = ctx.sprops_maxw or r[3]
    local nc = math.max(1, math.floor((w + L.pad) / math.min(w, L.cw * 36)))
    local need = (math.ceil(#SPROP.ROWS / nc) + 1) * L.rh + 2
    state.top_px = math.floor(L.top_h + (need - r[4]))
    ctx.relayout()
    vim.msg = 'top panel fits the sample properties'
  end,
  hints_on = function() return state.hints end,
  mx_loop_key = function(c) return GD.loop_key(c, snap, seq, MX.cur.ri, MX.cur.ci) end,
  loop_cells = function()
    if loop_cache.snap ~= snap or loop_cache.seq ~= seq then
      loop_cache.snap, loop_cache.seq, loop_cache.grid = snap, seq, GD.cells(snap, seq)
    end
    return loop_cache.grid
  end,
  mx_refresh = function()
    model.invalidate()
    regions = model.regions(state.lpb)
    seq = ctx.sequence()
  end,
  -- Лайв (2 окт): count регионов одним undo-шагом, без страховки сэмплов
  -- (items не удаляются) и без автосинка; курсор остаётся в матрице —
  -- имя потом (n), а не обязательный вопрос посреди игры.
  mx_add = function(bars, name, count)
    count = math.max(1, math.min(64, count or 1))
    local n0 = #seq
    local names = {}
    local used = {}
    for _, r in ipairs(regions) do used[r.name] = true end
    for k = 1, count do
      local nm = (name and name ~= '') and (count > 1 and (name .. ' ' .. k) or name) or nil
      if not nm then
        local j = n0 + k
        while used[('%02d'):format(j)] do j = j + 1 end
        nm = ('%02d'):format(j)
      end
      used[nm] = true
      names[k] = nm
    end
    edit.no_rescue = true
    edit.run('add region', function()
      local list = ctx.real_seq()
      local rs = {}
      for i, r in ipairs(list) do rs[i] = r end
      for k = 1, count do
        -- =LIB мог уехать на прошлой итерации — позиция с проекта, не из кэша
        rs.lib_pos = model.lib_pos()
        local t0, t1 = alias.add_region(rs, names[k], bars or 1)
        rs[#rs + 1] = { pos = t0, rgnend = t1, name = names[k] }
      end
    end)
    ctx.mx_refresh()
    MX.goto_cell(seq, snap, #seq, MX.cur.ci)
    ctx.set_focus('matrix')
    vim.msg = count > 1 and ('%d regions added (%s..%s) - n: name'):format(count, names[1], names[count])
      or ('region %d "%s" added - n: name, = / [ ]: length'):format(#seq, names[1])
  end,
  -- ── слоты матрицы как строки Vim (2 окт) ────────────────────────────
  -- Регистр матрицы state.mx_reg: { kind = 'slot', sl = снимок } после yy / dd,
  -- { kind = 'cells' } после Ctrl+C / x / y в блоке. p — после курсора, P — перед.
  -- Каждая операция — один undo-шаг; хук edit.after выключен на время правки
  -- (как в set_region_len), иначе автосинк работал бы по старым регионам.
  slot_op = function(desc, fn)
    local hook = edit.after
    edit.after = nil
    local ok, r = pcall(edit.run, desc, fn)
    edit.after = hook
    ctx.mx_refresh()
    if not ok then error(r) end
  end,
  slot_yank = function(ri)
    local sl = alias.slot_snapshot(seq, snap, ri or MX.cur.ri)
    if not sl then vim.msg = 'no slot'; return end
    state.mx_reg = { kind = 'slot', sl = sl }
    vim.msg = ('yank slot %s: %d item(s), %d steps - p / P puts it'):format(sl.gap and 'bar' or (sl.name ~= '' and sl.name or '#'), sl.nitems, math.floor((seq[ri or MX.cur.ri].r1 - seq[ri or MX.cur.ri].r0) + 0.5))
  end,
  -- новый слот: kind = 'empty' (такт) | 'put' (регистр) | 'dup' (копия курсора, новое имя)
  slot_new = function(kind, before)
    if #seq == 0 then ctx.mx_add(); return end
    local ri = MX.cur.ri
    local rg = seq[ri]
    if not rg then return end
    local sl
    -- как в Renoise (3 окт): alias — связанный повтор (то же имя, пул MIDI и
    -- группа items с оригиналом; p слота, чей паттерн ещё есть, — тоже alias);
    -- clone (dup) — независимая копия с новым именем
    if kind == 'dup' then kind = 'clone' end
    local alias_src
    if kind == 'alias' and not rg.gap then alias_src = rg end
    if kind == 'put' then
      local reg = state.mx_reg
      if not reg then vim.msg = 'matrix register empty (yy / dd / Ctrl+C)'; return end
      if reg.kind == 'cells' then ctx.mx_block('paste'); return end
      sl = reg.sl
      if sl and sl.name and sl.name ~= '' then
        for _, r in ipairs(seq) do if not r.gap and r.name == sl.name then alias_src = r; break end end
      end
    end
    if alias_src then
      local t = before and rg.pos or rg.rgnend
      local n = 0
      ctx.slot_op('matrix repeat ' .. alias_src.name, function() n = alias.put_alias(alias_src, t) end)
      MX.goto_cell(seq, snap, before and ri or ri + 1, MX.cur.ci)
      vim.msg = ('alias of "%s": %d item(s), linked - MIDI pooled, items grouped (clone C: a free copy, U: make unique)'):format(alias_src.name, n)
      return
    end
    if kind == 'clone' then
      sl = alias.slot_snapshot(seq, snap, ri)
      if not sl then return end
      sl.name = alias.free_name(regions, sl.name)
    else
      local t = before and rg.pos or rg.rgnend
      local qn = reaper.TimeMap2_timeToQN(0, t)
      local _, qms, qme = reaper.TimeMap_QNToMeasures(0, qn + 1e-6)
      local blen = (qme and qms) and (qme - qms) or 4
      sl = { name = '', len = reaper.TimeMap2_QNToTime(0, qn + blen) - t, color = 0 }
    end
    local t = before and rg.pos or rg.rgnend
    local n = 0
    ctx.slot_op(({ empty = 'matrix new slot', put = 'matrix put slot', clone = 'matrix clone slot' })[kind],
      function() n = alias.put_slot(snap, t, sl) end)
    local target = before and ri or ri + 1
    MX.goto_cell(seq, snap, target, MX.cur.ci)
    if kind == 'empty' then
      vim.msg = 'new 1-bar slot - n: name, = / [ ]: length'
    else
      vim.msg = ('%s slot "%s": %d item(s)%s'):format(kind == 'clone' and 'cloned' or 'put', sl.name, n, kind == 'clone' and ' - free copy, no link' or '')
    end
  end,
  -- make unique (U): повтор под курсором матрицы отвязать — своё имя, свой пул, без группы
  slot_unique = function(ri)
    local rg = seq[ri or MX.cur.ri]
    if not rg or rg.gap then vim.msg = 'make unique: no pattern here'; return end
    local name, n
    ctx.slot_op('matrix make unique', function() name, n = alias.make_unique(regions, rg) end)
    vim.msg = ('make unique: "%s" is now "%s" - %d item(s) unlinked'):format(rg.name, name, n)
  end,
  slot_delete = function()
    local rg = seq[MX.cur.ri]
    if not rg then return end
    local sl = alias.slot_snapshot(seq, snap, MX.cur.ri)
    state.mx_reg = { kind = 'slot', sl = sl }
    ctx.slot_op('matrix delete slot', function() alias.delete_slot(rg) end)
    if MX.cur.ri > #seq then MX.cur.ri = math.max(1, #seq) end
    if #seq > 0 then MX.goto_cell(seq, snap, MX.cur.ri, MX.cur.ci) else ctx.set_focus('tracker') end
    vim.msg = ('deleted slot %s (%d item(s)) - p puts it back, u undo'):format(rg.gap and 'bar' or (rg.name ~= '' and rg.name or ('#' .. rg.idx)), sl and sl.nitems or 0)
  end,
  -- длина слота: ±1 такт / ±1 шаг (ripple, как :len)
  slot_len_step = function(unit, d)
    local rg = seq[MX.cur.ri]
    if not rg or rg.gap then vim.msg = 'free bar: name it first (n)'; return end
    local t1
    if unit == 'bar' then
      local _, qms, qme = reaper.TimeMap_QNToMeasures(0, rg.qn1 - 1e-6)
      local blen = (qme and qms) and (qme - qms) or 4
      t1 = reaper.TimeMap2_QNToTime(0, rg.qn1 + d * blen)
    else
      t1 = edit.row_time(rg.r1 + d, state.lpb, 0)
    end
    if t1 <= rg.pos + 1e-6 then vim.msg = 'min length'; return end
    ctx.set_region_len(rg, t1)
  end,
  mx_name_prompt = function(ri)
    if ri then MX.goto_cell(seq, snap, ri, MX.cur.ci) end
    local rg = seq[MX.cur.ri]
    if not rg then vim.msg = 'no region'; return end
    ctx.set_focus('matrix')
    state.popup_at = { kind = 'mxrow', ri = MX.cur.ri }
    vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'name ' .. rg.name
  end,
  -- ── размер такта (5 окт) ─────────────────────────────────────────────
  autosync_on = function() return state.autosync end,
  -- ── свои темы и профили опций (5 окт) ────────────────────────────────
  theme_dir = function() return reaper.GetResourcePath() .. '/Data/jf_tracker_themes' end,
  profile_dir = function() return reaper.GetResourcePath() .. '/Data/jf_tracker_profiles' end,
  list_files = function(dir, ext)
    local out, i = {}, 0
    while true do
      local f = reaper.EnumerateFiles(dir, i)
      if not f then break end
      if f:lower():match('%.' .. ext .. '$') then out[#out + 1] = f:gsub('%.' .. ext .. '$', '') end
      i = i + 1
    end
    table.sort(out)
    return out
  end,
  load_user_themes = function()
    local dir, n = ctx.theme_dir(), 0
    for _, name in ipairs(ctx.list_files(dir, 'txt')) do
      local fh = io.open(dir .. '/' .. name .. '.txt', 'r')
      if fh then
        local p = draw.themes.parse(fh:read('a')); fh:close()
        if p then draw.themes.add(name, p); n = n + 1 end
      end
    end
    return n
  end,
  theme_template = function()
    local dir = ctx.theme_dir()
    reaper.RecursiveCreateDirectory(dir, 0)
    local base, k = 'my-theme', 1
    local name = base
    while reaper.file_exists(dir .. '/' .. name .. '.txt') do k = k + 1; name = base .. '-' .. k end
    local fh = io.open(dir .. '/' .. name .. '.txt', 'w')
    if not fh then vim.msg = 'theme: cannot write ' .. dir; return end
    fh:write(draw.themes.template(U, name)); fh:close()
    ctx.load_user_themes()
    vim.msg = ('theme template %s.txt from the current colours - edit it, then "reload my themes" (%s)'):format(name, dir)
  end,
  -- профиль: key = value всех опций с key
  opt_save = function(name)
    name = (name or ''):gsub('[/:]', '-'):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then vim.msg = 'optsave name'; return end
    local dir = ctx.profile_dir()
    reaper.RecursiveCreateDirectory(dir, 0)
    local fh = io.open(dir .. '/' .. name .. '.txt', 'w')
    if not fh then vim.msg = 'profile: cannot write ' .. dir; return end
    local n = 0
    for _, it in ipairs(ctx.option_items()) do
      if it.key and it.get and it.kind ~= 'action' then fh:write(('%s = %s\n'):format(it.key, tostring(it.get()))); n = n + 1 end
    end
    fh:close()
    vim.msg = ('profile %s: %d options saved'):format(name, n)
  end,
  opt_load = function(name)
    local fh = io.open(ctx.profile_dir() .. '/' .. (name or '') .. '.txt', 'r')
    if not fh then vim.msg = 'no profile ' .. tostring(name); return end
    local vals = {}
    for line in fh:lines() do local k, v = line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$'); if k then vals[k] = v end end
    fh:close()
    local n = 0
    for _, it in ipairs(ctx.option_items()) do
      local v = it.key and vals[it.key]
      if v and it.set and it.kind ~= 'action' then
        local val
        if it.kind == 'toggle' then val = v == 'true'
        elseif it.kind == 'num' then val = tonumber(v)
        else for _, x in ipairs(it.values or {}) do if tostring(x) == v then val = x end end end
        if val ~= nil then pcall(it.set, val); n = n + 1 end
      end
    end
    ctx.relayout()
    vim.msg = ('profile %s: %d options loaded'):format(name, n)
  end,
  opt_del = function(name)
    if not (name or ''):match('^[%w _%-%.]+$') or name:find('%.%.') then vim.msg = 'profile: bad name'; return end   -- без путей (6 окт)
    local ok = os.remove(ctx.profile_dir() .. '/' .. name .. '.txt')
    vim.msg = ok and ('profile %s deleted'):format(name) or ('no profile ' .. tostring(name))
  end,
  opt_tab = function(t) state.opt_tab = t end,
  -- ── свойства item под курсором (5 окт): гидра вместо окна REAPER ──────
  -- числа — строкой :iprop key value (с текущим), переключатели — сразу
  item_props = function(item, anchor)
    if not (item and reaper.ValidatePtr(item, 'MediaItem*')) then vim.msg = 'no item'; return end
    local tk = reaper.GetActiveTake(item)
    local function iv(k) return reaper.GetMediaItemInfo_Value(item, k) end
    local function tv(k) return tk and reaper.GetMediaItemTakeInfo_Value(tk, k) or 0 end
    -- правка: свой undo-шаг, item обновить, модель — заново
    local function put(desc, fn) edit.run('item ' .. desc, function() fn(); reaper.UpdateItemInProject(item) end); model.invalidate() end
    local function itog(key, desc) return { label = desc, kind = 'toggle', get = function() return iv(key) >= 0.5 end, set = function(v) put(desc, function() reaper.SetMediaItemInfo_Value(item, key, v and 1 or 0) end) end } end
    local srclen = 0
    if tk then local src = reaper.GetMediaItemTake_Source(tk); srclen = src and reaper.GetMediaSourceLength(src) or 0 end
    local nm = tk and reaper.GetTakeName(tk) or ''
    local items = {
      { label = 'volume', kind = 'num', min = -60, max = 12, step = 0.5, fmt = '%+.1f dB',
        get = function() local v = iv('D_VOL'); return v > 1e-6 and math.floor(20 * math.log(v, 10) * 10 + 0.5) / 10 or -60 end,
        set = function(v) put('volume', function() reaper.SetMediaItemInfo_Value(item, 'D_VOL', v <= -60 and 0 or 10 ^ (v / 20)) end) end },
      { label = 'pan', kind = 'num', min = -100, max = 100, step = 1, fmt = '%+d',
        get = function() return math.floor(tv('D_PAN') * 100 + 0.5) end,
        set = function(v) if tk then put('pan', function() reaper.SetMediaItemTakeInfo_Value(tk, 'D_PAN', v / 100) end) end end },
      { label = 'transpose', kind = 'num', min = -48, max = 48, step = 1, fmt = '%+g st',
        get = function() return math.floor(tv('D_PITCH') * 100 + 0.5) / 100 end,
        set = function(v) if tk then put('transpose', function() reaper.SetMediaItemTakeInfo_Value(tk, 'D_PITCH', v) end) end end },
      { label = 'rate', kind = 'num', min = 0.1, max = 10, step = 0.01, fmt = '%.3f',
        get = function() return tv('D_PLAYRATE') end,
        set = function(v) if tk then put('rate', function() reaper.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', math.max(0.01, v)) end) end end },
      { label = 'keep pitch', kind = 'toggle', get = function() return tv('B_PPITCH') >= 0.5 end,
        set = function(v) if tk then put('keep pitch', function() reaper.SetMediaItemTakeInfo_Value(tk, 'B_PPITCH', v and 1 or 0) end) end end },
      itog('B_LOOPSRC', 'loop'), itog('B_MUTE', 'mute'),
      { label = 'swing', kind = 'toggle', get = function() return edit.item_swing(item) end,   -- 6 окт: свинг сетки для вставки / квантизации в этот item
        set = function(v) put('swing', function() edit.set_item_swing(item, v) end) end },
      { label = 'fade in', kind = 'num', min = 0, max = 5000, step = 5, fmt = '%d ms',
        get = function() return math.floor(iv('D_FADEINLEN') * 1000 + 0.5) end,
        set = function(v) put('fade in', function() reaper.SetMediaItemInfo_Value(item, 'D_FADEINLEN', v / 1000) end) end },
      { label = 'fade out', kind = 'num', min = 0, max = 5000, step = 5, fmt = '%d ms',
        get = function() return math.floor(iv('D_FADEOUTLEN') * 1000 + 0.5) end,
        set = function(v) put('fade out', function() reaper.SetMediaItemInfo_Value(item, 'D_FADEOUTLEN', v / 1000) end) end },
      { label = 'start offset', kind = 'num', min = 0, max = math.max(0.001, srclen), step = 0.01, fmt = '%.3f s',
        get = function() return tv('D_STARTOFFS') end,
        set = function(v) if tk then put('start offset', function() reaper.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', v) end) end end },
      { label = 'name', kind = 'text', get = function() return tk and reaper.GetTakeName(tk) or '' end, fn = function()
          state.iprop_item = item; OPT.close()
          vim.cmd_from = vim.mode == 'insert' and 'insert' or 'normal'; vim.mode = 'cmd'
          vim.cmdline = 'iprop name ' .. (tk and reaper.GetTakeName(tk) or '') end },
      { label = 'REAPER item properties window', kind = 'action', value = 'w', fn = function() OPT.close(); select_item_in_reaper(item); reaper.Main_OnCommand(40009, 0) end },
    }
    local a = anchor or ctx.cursor_anchor()
    OPT.open_panel(items, 'item ' .. nm .. '   j k row, h l / digits value, Enter, Esc', { x = a.x, y = a.y })
  end,
  -- :iprop key value — число / имя в item из item_props
  item_prop = function(key, val)
    local item = state.iprop_item
    if not (item and reaper.ValidatePtr(item, 'MediaItem*')) then vim.msg = 'iprop: no item (open the item menu first)'; return end
    local tk = reaper.GetActiveTake(item)
    local n = tonumber(val)
    local ok = true
    edit.run('item ' .. key, function()
      if key == 'vol' and n then reaper.SetMediaItemInfo_Value(item, 'D_VOL', n <= -150 and 0 or 10 ^ (n / 20))
      elseif key == 'pan' and tk then
        local v = val:upper():match('^C$') and 0 or (val:upper():match('^L(%d+)') and -tonumber(val:upper():match('^L(%d+)')) / 100) or (val:upper():match('^R(%d+)') and tonumber(val:upper():match('^R(%d+)')) / 100) or n
        if v then reaper.SetMediaItemTakeInfo_Value(tk, 'D_PAN', math.max(-1, math.min(1, v))) else ok = false end
      elseif key == 'pitch' and tk and n then reaper.SetMediaItemTakeInfo_Value(tk, 'D_PITCH', n)
      elseif key == 'rate' and tk and n and n > 0 then reaper.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', n)
      elseif key == 'fadein' and n then reaper.SetMediaItemInfo_Value(item, 'D_FADEINLEN', math.max(0, n / 1000))
      elseif key == 'fadeout' and n then reaper.SetMediaItemInfo_Value(item, 'D_FADEOUTLEN', math.max(0, n / 1000))
      elseif key == 'offs' and tk and n then reaper.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', n)
      elseif key == 'name' and tk then reaper.GetSetMediaItemTakeInfo_String(tk, 'P_NAME', val, true)
      else ok = false end
      reaper.UpdateItemInProject(item)
    end)
    model.invalidate()
    vim.msg = ok and ('item %s = %s'):format(key, val) or 'iprop: vol dB | pan C/L37/R50 | pitch st | rate x | fadein ms | fadeout ms | offs s | name text'
  end,
  -- якорь всплывашки: ячейка курсора трекера
  cursor_anchor = function()
    local f = L.flat[vim.cur.fi]
    local r = vim.cur.row - (rows[1] and rows[1].row or 0)
    if f and f.x and r >= 0 and r < L.nrows then return { kind = 'xy', x = f.x, y = L.body_y + (r + 1) * L.rh } end
    return { kind = 'xy', x = gfx.mouse_x, y = gfx.mouse_y + 4 }
  end,
  -- ── запись (5 окт) ───────────────────────────────────────────────────
  -- kind: 'tracker' — тейк остаётся на треке с курсора; 'inst' — новые тейки
  -- после остановки уходят в lib трека (каждый — свой инструмент)
  rec_start = function(kind)
    local col = cur_col()
    if not col then vim.msg = 'rec: no track under the cursor'; return end
    if reaper.GetPlayState() & 4 == 4 then vim.msg = 'rec: already recording'; return end
    local tr = col.track
    local before = {}
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do before[reaper.GetTrackMediaItem(tr, i)] = true end
    local t0 = edit.row_time(vim.cur.row, state.lpb, 0)
    if reaper.GetMediaTrackInfo_Value(tr, 'I_RECARM') ~= 1 then reaper.SetMediaTrackInfo_Value(tr, 'I_RECARM', 1) end
    state.rec_sess = { kind = kind, track = tr, row = vim.cur.row, t0 = t0, before = before, name = col.name }
    reaper.SetEditCurPos(t0, false, false)
    reaper.Main_OnCommand(1013, 0)                                 -- Transport: Record
    vim.msg = (kind == 'inst' and 'rec into a new sound of %s' or 'rec into %s from row %04d'):format(col.name, vim.cur.row)
      .. ' - Space: keep, Enter: keep + cursor back, Esc: delete'
  end,
  rec_stop = function(c)
    if c == 27 then
      if state.recdelprompt == false then
        reaper.Main_OnCommand(40668, 0); state.rec_sess = nil; vim.msg = 'rec: take deleted'; model.invalidate(); return
      end
      reaper.Main_OnCommand(1008, 0)                               -- пауза, пока решаем
      OPT.ask.open('delete the take?', 'Esc stopped the recording', {
        { key = 'k', label = 'keep it', fn = function() reaper.Main_OnCommand(40667, 0); ctx.rec_finish(false) end },
        { key = 'd', label = 'delete it', fn = function() reaper.Main_OnCommand(40668, 0); state.rec_sess = nil; vim.msg = 'rec: take deleted'; model.invalidate() end },
        { key = 'a', label = "delete it, don't ask again", fn = function()
            state.recdelprompt = false; reaper.Main_OnCommand(40668, 0); state.rec_sess = nil
            vim.msg = 'rec: take deleted (no question from now on - options: ask before deleting a take)'; model.invalidate() end },
      })
      return
    end
    reaper.Main_OnCommand(40667, 0)                                -- Stop (save all recorded media)
    ctx.rec_finish(c == 13)
  end,
  rec_finish = function(back)
    local s = state.rec_sess
    state.rec_sess = nil
    if not s then return end
    if s.kind == 'inst' and reaper.ValidatePtr(s.track, 'MediaTrack*') then
      local new = {}
      for i = 0, reaper.CountTrackMediaItems(s.track) - 1 do
        local it = reaper.GetTrackMediaItem(s.track, i)
        if not s.before[it] then new[#new + 1] = it end
      end
      local n = 0
      edit.run('rec to lib', function()
        for _, it in ipairs(new) do
          local tk = reaper.GetActiveTake(it)
          local src = tk and reaper.GetMediaItemTake_Source(tk)
          local path = src and reaper.GetMediaSourceFileName(src, '')
          if path and path ~= '' and edit.depot_add(path, s.track) then reaper.DeleteTrackMediaItem(s.track, it); n = n + 1 end
        end
      end)
      vim.msg = ('rec: %d take(s) -> lib of %s'):format(n, s.name or '')
    elseif state.reclib and reaper.ValidatePtr(s.track, 'MediaTrack*') then
      -- rec→lib (5 окт): тейк остаётся на месте и ещё становится инструментом
      local n = 0
      edit.run('rec copy to lib', function()
        for i = 0, reaper.CountTrackMediaItems(s.track) - 1 do
          local it = reaper.GetTrackMediaItem(s.track, i)
          if not s.before[it] then
            local tk = reaper.GetActiveTake(it)
            local src = tk and reaper.GetMediaItemTake_Source(tk)
            local path = src and reaper.GetMediaSourceFileName(src, '')
            if path and path ~= '' and edit.depot_add(path, s.track) then n = n + 1 end
          end
        end
      end)
      vim.msg = ('rec: take kept, %d new in the lib'):format(n)
    else vim.msg = 'rec: take kept' end
    if back then
      vim.cur.row = s.row
      reaper.SetEditCurPos(s.t0, false, false)
      vim.msg = vim.msg .. ', cursor back to the start'
    end
    model.invalidate()
  end,
  -- поиски (5 окт): Ctrl+/ — все эффекты (список слева от DSP), Cmd+/ — файлы
  -- (браузер), Option+/ — по цепи DSP трека курсора: блок или его параметр
  fx_search_global = function()
    state.dsp = true; state.fxb = true; state.khelp = false
    FB.query, FB.cur, FB.scroll = '', 1, 0
    ctx.relayout(); ctx.set_focus('fxb')
    vim.msg = 'fx: type to find, Enter adds to the cursor track'
  end,
  file_search = function()
    state.side = true; ctx.relayout(); ctx.set_focus('browser')
    if B.mode ~= 'files' then B.set_mode('files') end
    B.start_find()
  end,
  dsp_search = function()
    local t = dsp_target()
    if not t or #(t.fx or {}) == 0 then vim.msg = 'dsp: no fx on the cursor track'; return end
    local items = {}
    for k, f in ipairs(t.fx) do
      items[#items + 1] = { label = f.name, data = { k = k } }
      for pi, prm in ipairs(f.params or {}) do items[#items + 1] = { label = f.name .. ' · ' .. (prm.name or ''), data = { k = k, p = pi } } end
    end
    vim.open_picker('dsp of ' .. (t.name or 'track'), items, function(it)
      state.dsp = true; ctx.relayout(); ctx.set_focus('dsp')
      dsp_sel.fx = it.data.k; dsp_sel.param = it.data.p
      vim.msg = it.label
    end)
  end,
  -- \ в трекере (5 окт): контекст ячейки под курсором — то же, что правая кнопка
  -- 6 окт: \ — главное меню, \\ — контекст того, что под курсором / в фокусе
  context_here = function()
    if state.focus == 'tracker' then ctx.context_key(); return end
    local hv = {}
    if state.focus == 'dsp' then
      local t = dsp_target(); local fx = t and t.fx[dsp_sel.fx]
      if fx then hv.dsp = { fx = dsp_sel.fx, f = fx, param = dsp_sel.param } end
    elseif state.focus == 'matrix' then hv.matrix = { ri = MX.cur.ri, ci = MX.cur.ci }
    elseif state.focus == 'inst' then hv.pool = { i = vim.inst }
    elseif state.focus == 'fxb' then hv.fxb = { row = FB.cur }
    elseif state.focus == 'browser' then hv.browser = B.cur
    end
    local r = draw.module_rects and draw.module_rects[state.focus]
    ctx.open_context(hv, r and { kind = 'xy', x = r[1] + 8, y = r[2] + 2 * L.rh } or nil)
  end,
  main_menu = function()
    vim.open_hydra(ctx.hydra_root())
    state.popup_at = state.focus == 'tracker' and ctx.cursor_anchor() or { kind = 'ctrlbtn', name = 'help' }
  end,
  -- F1 (6 окт): большая справка поверх окна — все страницы, поиск; учиться
  -- трекеру, не выходя из REAPER (html — пунктом меню, потом станет зеркалом)
  help_big = function()
    if not ctx.DOC then ctx.DOC = dofile(DIR .. '/jf_tracker_doc.lua'); ctx.DOC.init(U, ctx, DIR .. '/jf_tracker_help.html') end
    state.khelp_big = not state.khelp_big
    vim.msg = state.khelp_big and 'help: / search, j k scroll, J K section, Esc or F1 - close, Shift+F1 - tutorial' or ''
  end,
  -- ? (6 окт): действия REAPER в стиле трекера — fzf на всю матрицу,
  -- недавние сверху (ExtState jf_tracker/act_recent)
  actions_picker = function()
    if not reaper.CF_EnumerateActions then vim.msg = 'actions: needs SWS (CF_EnumerateActions)'; return end
    if not ctx.act_items then
      local items, i = {}, 0
      while true do
        local id, name = reaper.CF_EnumerateActions(0, i, '')
        if not id or id <= 0 then break end
        if name and name ~= '' then items[#items + 1] = { label = name, data = id } end
        i = i + 1
      end
      ctx.act_items = items
    end
    local by, list, seen = {}, {}, {}
    for _, it in ipairs(ctx.act_items) do by[it.label] = it end
    for nm in (reaper.GetExtState(EXT, 'act_recent') or ''):gmatch('[^\n]+') do local it = by[nm]; if it and not seen[it] then list[#list + 1] = it; seen[it] = true end end
    for _, it in ipairs(ctx.act_items) do if not seen[it] then list[#list + 1] = it end end
    vim.open_picker('reaper actions', list, function(it)
      reaper.Main_OnCommand(it.data, 0)
      local rec = { it.label }
      for nm in (reaper.GetExtState(EXT, 'act_recent') or ''):gmatch('[^\n]+') do if nm ~= it.label and #rec < 30 then rec[#rec + 1] = nm end end
      reaper.SetExtState(EXT, 'act_recent', table.concat(rec, '\n'), true)
      vim.msg = 'action: ' .. it.label
    end)
    -- на всю матрицу (узкая / скрытая — на трекер)
    local x, y, w, h
    if not state.mx_hidden and L.matrix_w > L.cw * 40 then
      x, y = 0, L.mx_top or L.header_y
      w, h = L.matrix_w - draw.SEPW, (L.mx_bot or (L.body_y + L.body_h)) - y
    else
      local r = draw.module_rects and draw.module_rects.tracker or { L.matrix_w, L.header_y, L.win_w - L.matrix_w, L.body_h }
      x, y, w, h = r[1], r[2], r[3], r[4]
    end
    vim.picker.rows = math.max(5, math.floor((h - 2 * L.pad) / L.rh) - 2)
    state.popup_at = { kind = 'box', x = x, y = y, w = w, h = h }
  end,
  context_key = function()
    local f = L.flat[vim.cur.fi]
    local hv = { fi = vim.cur.fi, row = { row = vim.cur.row }, field = vim.cur.field, fsub = vim.cur.sub,
                 cell = f and f.sub and f.sub[vim.cur.row], col = f and f.col }
    local r = vim.cur.row - (rows[1] and rows[1].row or 0)
    local anchor = (f and f.x and r >= 0 and r < L.nrows) and { kind = 'xy', x = f.x, y = L.body_y + (r + 1) * L.rh } or nil
    if ctx.open_context then ctx.open_context(hv, anchor) end
  end,
  -- шаг слайдера шапки (колесо, клавиатура): громкость 0.5 dB, панорама 0.02;
  -- coarse — 3 dB / 0.1
  -- 8 окт: прыжок фейдера на метку dB (f) — сразу или ходом за N тактов /
  -- долей (счётчик перед f: 2f — такты, 2,f — доли). Цели — трек метки, а
  -- если он выделен в REAPER (Option+цифра) — все выделенные треки.
  -- Ход — точки огибающей Volume (создаётся, если нет): текущее значение в
  -- начале, цель в конце, между — линейно; после — громкость держится.
  -- Старт: играет — следующая граница квантизации сессии (bar / beat / now),
  -- стоит — строка курсора трекера
  fader_targets = function(col)
    local out = {}
    if col.track and reaper.IsTrackSelected(col.track) then
      for _, c2 in ipairs(snap and snap.cols or {}) do
        if c2.track and reaper.ValidatePtr(c2.track, 'MediaTrack*') and reaper.IsTrackSelected(c2.track) then out[#out + 1] = c2 end
      end
    end
    if #out == 0 then out[1] = col end
    return out
  end,
  fader_jump = function(col, db, glide)
    local cols = ctx.fader_targets(col)
    local amp = 10 ^ (db / 20)
    if not glide then
      edit.run('fader jump', function()
        for _, c2 in ipairs(cols) do edit.track_value(c2.track, 'D_VOL', amp) end
      end)
      model.invalidate()
      vim.msg = ('%s vol %+d dB'):format(#cols > 1 and (#cols .. ' tracks') or (col.name or ''), db)
      return
    end
    local t0
    if playing() then
      local p, q = reaper.GetPlayPosition(), MX.SS.quant
      t0 = q == 'now' and p or (q == 'beat' and ctx.ss_beat_after(p) or ctx.ss_bar_after(p))
    else t0 = edit.row_time(vim.cur.row, state.lpb, 0) end
    local t1
    if glide.unit == 'beat' then t1 = reaper.TimeMap2_QNToTime(0, reaper.TimeMap2_timeToQN(0, t0) + glide.n)
    else
      local bt, meas = reaper.TimeMap2_timeToBeats(0, t0)
      t1 = reaper.TimeMap2_beatsToTime(0, bt, meas + glide.n)
    end
    if t1 <= t0 then return end
    edit.run('fader glide', function()
      for _, c2 in ipairs(cols) do
        local tr = c2.track
        local env = reaper.GetTrackEnvelopeByName(tr, 'Volume')
        if not env then
          MMX.PP.toggle_env(tr, { kind = 'trk', env_name = 'Volume', words = 'volume', label = 'Volume' })
          env = reaper.GetTrackEnvelopeByName(tr, 'Volume')
        end
        if env then
          local mode = reaper.GetEnvelopeScalingMode(env)
          local _, v0 = reaper.Envelope_Evaluate(env, t0, 0, 0)
          local v1 = reaper.ScaleToEnvelopeMode(mode, amp)
          reaper.DeleteEnvelopePointRange(env, t0 - 1e-4, t1 + 1e-4)
          reaper.InsertEnvelopePoint(env, t0, v0, 0, 0, false, true)
          reaper.InsertEnvelopePoint(env, t1, v1, 0, 0, false, true)
          reaper.Envelope_SortPoints(env)
        end
      end
    end)
    model.invalidate()
    vim.msg = ('%s -> %+d dB in %d %s%s'):format(#cols > 1 and (#cols .. ' tracks') or (col.name or ''), db, glide.n,
      glide.unit == 'beat' and 'beat(s)' or 'bar(s)', playing() and (' from the next ' .. MX.SS.quant) or ' from the cursor')
  end,
  trs_nudge = function(col, what, d, coarse)
    local key = TRS_KEY[what]
    if not (col and key and reaper.ValidatePtr(col.track, 'MediaTrack*')) then return end
    local cur = reaper.GetMediaTrackInfo_Value(col.track, key)
    local v
    if what == 'vol' then
      local db = cur > 1e-6 and 20 * math.log(cur, 10) or -60
      v = 10 ^ (math.max(-60, math.min(12, db + d * (coarse and 0.1 or 0.5))) / 20)   -- 6 окт: Shift — мелкий шаг
    else v = math.max(-1, math.min(1, cur + d * (coarse and 0.005 or 0.02))) end
    edit.track_value(col.track, key, v); edit.track_undo('track ' .. what); model.invalidate()
    vim.msg = what == 'vol' and ('%s vol %+.1f dB'):format(col.name, v > 1e-6 and 20 * math.log(v, 10) or -150) or ('%s %s %+.2f'):format(col.name, what, v)
  end,
  -- клавиатурный слайдер (метка f на слайдере, 5 окт): h l / j k — шаг,
  -- Shift — крупно, 0 — сброс, Esc / Enter — готово; true — клавиша съедена
  kslider_key = function(c)
    local ks = state.kslider
    local ch = c > 0 and c < 256 and string.char(c) or ''
    if c == 1818584692 then ch = 'h' elseif c == 1919379572 then ch = 'l' elseif c == 1685026670 then ch = 'j' elseif c == 30064 then ch = 'k' end   -- стрелки
    -- 8 окт: фейдер микшера (f на фейдере) — k j громкость, h l панорама
    -- (у dual pan — левая), Shift — мелкий шаг; 0 — сброс громкости
    if state.mixer and ks.what == 'vol' then
      if ch == 'j' or ch == 'k' or ch == 'J' or ch == 'K' then
        ctx.trs_nudge(ks.col, 'vol', (ch == 'j' or ch == 'J') and -1 or 1, ch == 'J' or ch == 'K'); return true
      end
      if ch == 'h' or ch == 'l' or ch == 'H' or ch == 'L' then
        local pm = reaper.GetMediaTrackInfo_Value(ks.col.track, 'I_PANMODE')
        ctx.trs_nudge(ks.col, pm == 6 and 'panl' or 'pan', (ch == 'h' or ch == 'H') and -1 or 1, ch == 'H' or ch == 'L'); return true
      end
    end
    -- горизонтальный слайдер (5 окт): h l — значение (H L — мелкий шаг, 6 окт), j k —
    -- соседний слайдер шапки сверху вниз: громкость, панорама, ширина / L R
    if ch == 'h' or ch == 'l' or ch == 'H' or ch == 'L' then
      ctx.trs_nudge(ks.col, ks.what, (ch == 'h' or ch == 'H') and -1 or 1, ch == 'H' or ch == 'L'); return true
    end
    if ch == 'j' or ch == 'k' then
      local pm = reaper.GetMediaTrackInfo_Value(ks.col.track, 'I_PANMODE')
      local list = pm == 6 and { 'vol', 'panl', 'panr' } or (pm == 5 and { 'vol', 'pan', 'width' } or { 'vol', 'pan' })
      local i = 1
      for k, w in ipairs(list) do if w == ks.what then i = k end end
      i = math.max(1, math.min(#list, i + (ch == 'j' and 1 or -1)))
      ks.what = list[i]
      vim.msg = ('%s %s: h l change, j k next slider, 0 reset, Esc done'):format(ks.col.name or '', ks.what)
      return true
    end
    if ch == '0' then
      edit.track_value(ks.col.track, TRS_KEY[ks.what], TRS_RESET[ks.what]); edit.track_undo('track ' .. ks.what .. ' reset'); model.invalidate()
      vim.msg = ks.what .. ' reset'; return true
    end
    state.kslider = nil; draw.trspop = nil            -- всплывающий слайдер узкого трека закрывается вместе с фокусом
    vim.msg = 'slider: done'
    return c == 27 or c == 13                                 -- Esc / Enter — съедены; другое (Tab …) — дальше
  end,
  dev_on = function() return state.dev end,
  sig_at = function(t) local n, d = reaper.TimeMap_GetTimeSigAtTime(0, t + 1e-6); return n, d end,
  -- строка :sig с текущим размером; rg — для паттерна (матрица), иначе спросит
  sig_menu = function()
    local n0, d0 = ctx.sig_at(edit.row_time(vim.cur.row, state.lpb, 0))
    local list = {}
    for _, s in ipairs({ { '4', 4, 4 }, { '3', 3, 4 }, { '2', 2, 4 }, { '5', 5, 4 }, { '7', 7, 4 }, { 'e', 6, 8 }, { 's', 7, 8 }, { 'f', 5, 8 }, { 'n', 9, 8 }, { 't', 12, 8 } }) do
      list[#list + 1] = { key = s[1], label = ('%d/%d'):format(s[2], s[3]) .. ((s[2] == n0 and s[3] == d0) and '  *' or ''), fn = function() ctx.sig_cmd(('%d/%d'):format(s[2], s[3])) end }
    end
    list[#list + 1] = { key = 'c', label = 'other ... (:sig N/D)', fn = function() ctx.sig_prompt() end }
    vim.open_hydra({ title = 'time signature', items = list })
    state.popup_at = { kind = 'strip', id = 'sig' }
  end,
  -- колесо по размеру: числитель ±1 сразу на весь проект, ноты как есть (сетка пересчитывается)
  sig_wheel = function(d)
    local n, dd = ctx.sig_at(0)
    local nn = math.max(1, math.min(32, n + (d > 0 and 1 or -1)))
    if nn ~= n then ctx.sig_apply('all', nil, nn, dd, 'keep'); vim.msg = ('sig %d/%d'):format(nn, dd); ctx.mx_refresh() end
  end,
  sig_prompt = function(rg)
    local n, d = ctx.sig_at(rg and rg.pos or edit.row_time(vim.cur.row, state.lpb, 0))
    if rg then state.sig_rg = rg.idx; state.popup_at = { kind = 'mxrow', ri = MX.cur.ri } else state.sig_rg = nil; state.popup_at = { kind = 'strip', id = 'sig' } end
    vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = ('sig %d/%d%s'):format(n, d, rg and ' here' or '')
  end,
  -- :sig N/D [all|here]: весь проект или паттерн; такт длиннее прежнего —
  -- спросить, чем заполнить недостающие доли
  sig_cmd = function(arg)
    local n, d, scope = (arg or ''):match('^%s*(%d+)%s*/%s*(%d+)%s*(%a*)')
    n, d = tonumber(n), tonumber(d)
    if not n or n < 1 or n > 64 or not ({ [1] = 1, [2] = 1, [4] = 1, [8] = 1, [16] = 1, [32] = 1 })[d or 0] then vim.msg = 'sig N/D [all|here] - e.g. :sig 5/4'; return end
    local rg
    if state.sig_rg then for _, r in ipairs(regions) do if r.idx == state.sig_rg then rg = r end end end
    state.sig_rg = nil
    rg = rg or alias.region_at(regions, edit.row_time(vim.cur.row, state.lpb, 0))
    local function go(sc)
      if sc == 'here' and not rg then vim.msg = 'sig: the cursor is not in a pattern'; return end
      local t0 = sc == 'all' and 0 or rg.pos
      local on, od = ctx.sig_at(t0)
      if n * 4 / d > on * 4 / od + 1e-9 then
        local g = n * 4 / d - on * 4 / od
        OPT.ask.open(('%d/%d -> %d/%d: every bar gets %g more quarter(s)'):format(on, od, n, d, g), 'what goes into the new beats of each bar? (later patterns and items move)', {
          { key = 'k', label = 'keep the notes as they are (bars re-count)', fn = function() ctx.sig_apply(sc, rg, n, d, 'keep') end },
          { key = 'e', label = 'empty beats at the end of each bar', fn = function() ctx.sig_apply(sc, rg, n, d, 'empty') end },
          { key = 'l', label = 'repeat the last beat of each bar', fn = function() ctx.sig_apply(sc, rg, n, d, 'last') end },
        })
      else ctx.sig_apply(sc, rg, n, d, 'keep') end
    end
    if scope == 'all' or scope == 'here' then go(scope)
    else
      OPT.ask.open(('time signature %d/%d'):format(n, d), 'for the whole project or only this pattern?', {
        { key = 'n', label = 'cancel', fn = function() vim.msg = 'sig: unchanged' end },
        { key = 'a', label = 'whole project', fn = function() go('all') end },
        { key = 'r', label = 'this pattern' .. (rg and (' (' .. rg.name .. ')') or ' - none at the cursor'), fn = function() go('here') end },
      })
    end
  end,
  -- маркеры темпа / размера с позиции t и дальше — на dt (вставка долей)
  shift_tempo_markers = function(t, dt)
    for i = reaper.CountTempoTimeSigMarkers(0) - 1, 0, -1 do
      local ok, tp, _, _, bpm, num, den, lin = reaper.GetTempoTimeSigMarker(0, i)
      if ok and tp >= t - 1e-6 then reaper.SetTempoTimeSigMarker(0, i, tp + dt, -1, -1, bpm, num, den, lin) end
    end
  end,
  -- размер n/d маркером в t (есть маркер ровно там — правим его)
  set_sig_marker = function(t, n, d)
    local i = reaper.FindTempoTimeSigMarker(0, t + 1e-4)
    if i >= 0 then
      local ok, tp, _, _, bpm, _, _, lin = reaper.GetTempoTimeSigMarker(0, i)
      if ok and math.abs(tp - t) < 1e-3 then reaper.SetTempoTimeSigMarker(0, i, tp, -1, -1, bpm, n, d, lin); return end
    end
    reaper.SetTempoTimeSigMarker(0, -1, t, -1, -1, reaper.TimeMap2_GetDividedBpmAtTime(0, t), n, d, false)
  end,
  sig_apply = function(sc, rg, n, d, mode)
    local t0 = sc == 'all' and 0 or rg.pos
    local t1 = rg and sc == 'here' and rg.rgnend or 0
    if sc == 'all' then for _, r in ipairs(regions) do if r.rgnend > t1 then t1 = r.rgnend end end; if t1 <= 0 then t1 = reaper.GetProjectLength(0) end end
    local on, od = ctx.sig_at(t0)
    local an, ad = ctx.sig_at(t1)                                     -- размер после паттерна (вернуть)
    local q0, q1 = reaper.TimeMap2_timeToQN(0, t0), reaper.TimeMap2_timeToQN(0, t1)
    local oldbar, g = on * 4 / od, n * 4 / d - on * 4 / od
    local tracks = {}
    for i = 0, reaper.CountTracks(0) - 1 do tracks[#tracks + 1] = reaper.GetTrack(0, i) end
    local hook = edit.after
    edit.after = nil
    local nb = 0
    edit.run(('time signature %d/%d'):format(n, d), function()
      if mode ~= 'keep' and g > 1e-9 then
        -- с конца: позиции более ранних тактов не сдвигаются
        for k = math.floor((q1 - q0) / oldbar + 1e-6), 1, -1 do
          local qb = q0 + k * oldbar
          local tb = reaper.TimeMap2_QNToTime(0, qb)
          local dt = reaper.TimeMap2_QNToTime(0, qb + g) - tb
          ctx.shift_tempo_markers(tb, dt)
          alias.shift_markers(tb, dt)
          edit.time_insert(tracks, tb, dt, math.huge)
          if mode == 'last' then
            local ts = reaper.TimeMap2_QNToTime(0, qb - math.min(g, oldbar))
            for _, tr in ipairs(tracks) do alias.copy_span(tr, { pos = ts, rgnend = tb }, { pos = tb, rgnend = tb + dt }, nil, false) end
          end
          t1 = t1 + dt; nb = nb + 1
        end
        if sc == 'here' then alias.set_end(rg, t1) end
      end
      if sc == 'all' then
        for i = 0, reaper.CountTempoTimeSigMarkers(0) - 1 do
          local ok, tp, _, _, bpm, num, _, lin = reaper.GetTempoTimeSigMarker(0, i)
          if ok and num > 0 then reaper.SetTempoTimeSigMarker(0, i, tp, -1, -1, bpm, n, d, lin) end
        end
        ctx.set_sig_marker(0, n, d)
      else
        ctx.set_sig_marker(t1, an, ad)                                -- после паттерна — прежний размер
        ctx.set_sig_marker(t0, n, d)
      end
    end)
    edit.after = hook
    ctx.mx_refresh(); model.invalidate()
    vim.msg = ('time signature %d/%d: %s%s'):format(n, d, sc == 'all' and 'whole project' or ('pattern ' .. rg.name), nb > 0 and (', %d bar(s) got %s beats'):format(nb, mode == 'last' and 'repeated' or 'empty') or '')
  end,
  mx_len_prompt = function(ri)
    if ri then MX.goto_cell(seq, snap, ri, MX.cur.ci) end
    local rg = seq[MX.cur.ri]
    if not rg then vim.msg = 'no region'; return end
    ctx.set_focus('matrix')
    state.popup_at = { kind = 'mxrow', ri = MX.cur.ri }
    vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'len '
    vim.msg = ('len: N steps (lpb %d) | Ns seconds | Nb bars; now %d steps = %.3fs'):format(state.lpb, rg.r1 - rg.r0, rg.rgnend - rg.pos)
  end,
  mx_name = function(text)
    local rg = seq[MX.cur.ri]
    text = (text or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if not rg then vim.msg = 'no region'; return end
    if text == '' then vim.msg = 'name: empty'; return end
    if rg.gap then
      -- свободный такт → новый регион на нём
      edit.run('add region', function() reaper.AddProjectMarker2(0, true, rg.pos, rg.rgnend, text, -1, 0) end)
      ctx.mx_refresh(); vim.msg = 'region: ' .. text; return
    end
    edit.run('rename region', function() alias.rename(rg, text) end)
    ctx.mx_refresh()
    vim.msg = 'region: ' .. text
  end,
  mx_len = function(text)
    local rg = seq[MX.cur.ri]
    if not rg then vim.msg = 'no region'; return end
    if rg.gap then vim.msg = 'free bar: name it first (n)'; return end
    local v, unit = (text or ''):match('^%s*([%d%.]+)%s*(%a*)%s*$')
    v = tonumber(v)
    if not v or v <= 0 then vim.msg = 'len N (steps) | Ns (seconds) | Nb (bars)'; return end
    local t1
    if unit == 's' then t1 = rg.pos + v
    elseif unit == 'b' then
      local _, qms, qme = reaper.TimeMap_QNToMeasures(0, rg.qn0)
      t1 = reaper.TimeMap2_QNToTime(0, rg.qn0 + v * ((qme and qms) and (qme - qms) or 4))
    else t1 = edit.row_time(rg.r0 + v, state.lpb, 0) end
    ctx.set_region_len(rg, t1)
  end,
  -- общая смена длины региона: маркеры — alias.shift_markers, items и
  -- огибающие — E.time_insert/time_delete (разрез на границе, без лимита)
  set_region_len = function(rg, t1)
    local dt = t1 - rg.rgnend
    if math.abs(dt) < 1e-6 then vim.msg = 'same length'; return end
    if t1 <= rg.pos + 1e-6 then vim.msg = 'min 1 step'; return end
    local tracks = {}
    for i = 0, reaper.CountTracks(0) - 1 do tracks[#tracks + 1] = reaper.GetTrack(0, i) end
    -- хук автосинка/trim отключён на время правки: он работал бы по старому
    -- списку регионов (ревью 1 окт); после обновления списка — один вызов
    local hook = edit.after
    edit.after = nil
    edit.run('region length', function()
      alias.shift_markers(rg.rgnend, dt)
      alias.set_end(rg, t1)
      if dt > 0 then edit.time_insert(tracks, rg.rgnend, dt, math.huge)
      else edit.time_delete(tracks, t1, rg.rgnend, math.huge) end
    end)
    edit.after = hook
    ctx.mx_refresh()
    local steps = (reaper.TimeMap2_timeToQN(0, t1) - rg.qn0) * state.lpb
    vim.msg = ('region %s: %d steps (%+.3fs; later regions and items moved)'):format(rg.name, math.floor(steps + 0.5), dt)
  end,
  -- ── панель свойств сэмпла (2 окт) ───────────────────────────────────
  pitch_mode_name = function(m)
    if not m or m < 0 then return 'project' end
    local ok, name = reaper.EnumPitchShiftModes(m >> 16)
    return (ok and name and name ~= '') and name or ('mode ' .. (m >> 16))
  end,
  -- beatsync инструмента (3 окт): edit.bsync_* — метка на всех его копиях
  bsync_set = function(e, n)
    if not (e and e.item and reaper.ValidatePtr(e.item, 'MediaItem*')) then vim.msg = 'no item selected'; return end
    local items = ctx.inst_group(e)
    edit.bsync_set(items, e.item, n)
    model.invalidate()
    vim.msg = n and ('beatsync %s: %d beats, %d note(s) fitted to the tempo where they sit'):format(e.name, n, #items) or ('beatsync off: %s, %d note(s) back to rate %.3f'):format(e.name, #items, reaper.GetMediaItemTakeInfo_Value(reaper.GetActiveTake(e.item), 'D_PLAYRATE'))
  end,
  bsync_toggle = function(e)
    if not e then local col = cur_col(); e = col and col.pool[vim.inst] end
    if not e then vim.msg = 'no item selected'; return end
    if e.bsync then ctx.bsync_set(e, nil); return end
    local span = e.len * (e.rate or 1)
    ctx.bsync_set(e, edit.bsync_guess(span, reaper.GetCursorPosition()))
  end,
  bsync_adjust = function(e, d)
    if not e.bsync then if d > 0 then ctx.bsync_toggle(e) end return end
    local n = e.bsync + d
    if n < 1 then ctx.bsync_set(e, nil) else ctx.bsync_set(e, n) end
  end,
  -- блок трека в DSP (3 окт): вход, master send, фаза, FX, маршрутизация
  track_io = function(col, what)
    local tr = col and col.track
    if not (tr and reaper.ValidatePtr(tr, 'MediaTrack*')) then return end
    local function toggle(key, desc)
      local v = reaper.GetMediaTrackInfo_Value(tr, key)
      edit.run(desc, function() reaper.SetMediaTrackInfo_Value(tr, key, v == 1 and 0 or 1) end)
      model.invalidate()
    end
    if what == 'mainsend' then toggle('B_MAINSEND', 'track master send')
    elseif what == 'phase' then toggle('B_PHASE', 'track phase')
    elseif what == 'fxen' then toggle('I_FXEN', 'track fx on / off')
    elseif what == 'routing' then
      reaper.SetOnlyTrackSelected(tr)
      reaper.Main_OnCommand(40914, 0)              -- Track: set first selected track as last touched
      reaper.Main_OnCommand(40293, 0)              -- Track: view routing and I/O
    elseif what == 'input' then
      ctx.input_picker(col, { kind = 'xy', x = gfx.mouse_x, y = gfx.mouse_y + 4 })
    elseif what == 'smart' then ctx.smart_input(col)
    elseif what == 'sends' then
      draw.sendpop = draw.sendpop ~= col.guid and col.guid or nil
    elseif what == 'input_menu' then
      -- (старое) меню входа: нет, моно, стерео пары, MIDI все входы / все каналы
      local items, vals = { 'none' }, { -1 }
      local n = reaper.GetNumAudioInputs()
      local mono, ster = {}, {}
      for i = 0, n - 1 do mono[#mono + 1] = reaper.GetInputChannelName(i) or ('in ' .. (i + 1)); vals[#vals + 1] = i end
      for i = 0, n - 2, 2 do ster[#ster + 1] = ('%s / %s'):format(reaper.GetInputChannelName(i) or (i + 1), reaper.GetInputChannelName(i + 1) or (i + 2)); vals[#vals + 1] = 1024 + i end
      if #mono > 0 then mono[1] = '>mono|' .. mono[1]; mono[#mono] = '<' .. mono[#mono] end
      if #ster > 0 then ster[1] = '>stereo|' .. ster[1]; ster[#ster] = '<' .. ster[#ster] end
      for _, m in ipairs(mono) do items[#items + 1] = m end
      for _, m in ipairs(ster) do items[#items + 1] = m end
      items[#items + 1] = 'MIDI: all inputs, all channels'; vals[#vals + 1] = 4096 + (63 << 5)
      gfx.x, gfx.y = gfx.mouse_x, gfx.mouse_y
      local k = gfx.showmenu(table.concat(items, '|'))
      if k > 0 and vals[k] then
        edit.run('track input', function() reaper.SetMediaTrackInfo_Value(tr, 'I_RECINPUT', vals[k]) end)
        model.invalidate()
      end
    end
  end,
  -- наборы lib (4 окт): save — все сэмплы lib (исходники) в шаблон трека REAPER
  -- TrackTemplates/jf_kits/<имя>.RTrackTemplate; браузер kits — Enter в lib трека
  kit_save_prompt = function()
    local _, pname = reaper.EnumProjects(-1, '')
    local nm = (pname and pname ~= '' and pname:match('([^/]+)%.[Rr][Pp][Pp]$')) or 'kit'
    vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'libsave ' .. nm
  end,
  kit_save = function(name)
    name = (name or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then vim.msg = 'libsave: a name please'; return end
    local col = cur_col(); local items = {}
    for _, e in ipairs(col and col.pool or {}) do if not e.parent and e.item and reaper.ValidatePtr(e.item, 'MediaItem*') then items[#items + 1] = e.item end end
    if #items == 0 then vim.msg = 'libsave: the lib is empty'; return end
    local path, n = edit.kit_save(items, name)
    vim.msg = path and ('kit saved: %s (%d samples) - TrackTemplates/jf_kits, browser tab kits'):format(name, n) or 'libsave: cannot write the file'
    if B.mode == 'kits' then B.set_all(B.read_kits()) end
  end,
  kit_load = function(path, name)
    local col = cur_col(); if not col then vim.msg = 'kit: no track under the cursor'; return end
    local n = edit.kit_load(path, col.track)
    model.invalidate()
    vim.msg = ('kit %s: %d sample(s) into the lib of %s'):format(name or '', n, col.name or '')
  end,
  -- jf_pm (3 окт): открыть проект из вкладки pm (o). Уже открыт — переключить
  -- вкладку; иначе — вопрос: REAPER останавливает скрипты при открытии проекта,
  -- поэтому трекер перезапускает себя в новой вкладке (-nonewinst run_tracker)
  pm_open_project = function(path, name)
    local i = 0
    while true do
      local proj, fn = reaper.EnumProjects(i)
      if not proj then break end
      if fn == path then reaper.SelectProjectInstance(proj); vim.msg = 'pm: switched to the open tab ' .. (name or path); return end
      i = i + 1
    end
    OPT.ask.open('open ' .. (name or path), 'scripts stop when a project opens, the tracker starts again there', {
      { key = 'n', label = 'cancel', fn = function() vim.msg = 'pm: not opened' end },
      { key = 't', label = 'open in this tab (instead of the current project; REAPER asks to save it)', fn = function()
        local exe = reaper.GetExePath() .. '/REAPER.app/Contents/MacOS/REAPER'
        reaper.Main_openProject(path)
        reaper.ExecProcess(('"%s" -nonewinst "%s/jf_tracker.lua"'):format(exe, DIR), -1)
      end },
      { key = 'o', label = 'open in a new tab', fn = function()
        local exe = reaper.GetExePath() .. '/REAPER.app/Contents/MacOS/REAPER'
        reaper.Main_OnCommand(40859, 0)                      -- File: New project tab
        reaper.Main_openProject(path)
        -- сам скрипт, не tests/run_tracker.lua: tests/ в релиз не входит (5 окт)
        reaper.ExecProcess(('"%s" -nonewinst "%s/jf_tracker.lua"'):format(exe, DIR), -1)
      end },
    })
  end,
  -- jf_pm (3 окт): теги — :pmtag со словами (правится строка), статус — меню
  -- классов jf_pm (status_over, как канбан); B.pm_edit пишет индекс
  pm_tags = function(e)
    local card = B.pm_card(e.path)
    local cur = {}
    for _, t in ipairs(card and card.tags_extra or {}) do cur[#cur + 1] = t end
    state.pm_target = e.path
    vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'pmtag ' .. table.concat(cur, ' ')
  end,
  pm_set_tags = function(text)
    local path = state.pm_target
    if not path then vim.msg = 'pmtag: pick a project in the pm tab (T)'; return end
    local tags = {}
    for w in (text or ''):gmatch('[^%s,]+') do tags[#tags + 1] = (w:gsub('^#', '')) end
    local ok = B.pm_edit(path, function(c) c.tags_extra = #tags > 0 and tags or nil end)
    vim.msg = ok and ('jf_pm tags: ' .. (#tags > 0 and ('#' .. table.concat(tags, ' #')) or '(none)')) or 'jf_pm: project not in the index'
  end,
  pm_status = function(e)
    local _, core = B.pm_card(e.path)
    local list = core and core.STATUSES or {}
    local keysq = '1234567890-='
    local items = {}
    for k, st in ipairs(list) do
      if k > #keysq then break end
      items[#items + 1] = { key = keysq:sub(k, k), label = st, fn = function()
        local ok = B.pm_edit(e.path, function(c) c.status_over = st; c.status_over_base = (c.ext or {}).STATUS or '' end)
        vim.msg = ok and ('jf_pm status: ' .. e.name .. ' -> ' .. st) or 'jf_pm: project not in the index'
      end }
    end
    items[#items + 1] = { key = 'x', label = '(clear - back to STATUS of the .rpp)', fn = function()
      B.pm_edit(e.path, function(c) c.status_over, c.status_over_base = nil, nil end)
      vim.msg = 'jf_pm status cleared: ' .. e.name
    end }
    vim.open_hydra({ title = 'status ' .. e.name, items = items })
  end,
  -- большой редактор сэмпла (3 окт, :big / кнопка big): вкладка item на всё окно
  -- проект-менеджер jf_pm (6 окт): модуль карточек лениво; pm_cards — опция
  pm_mod = function()
    if not ctx.PM then
      ctx.PM = dofile(DIR .. '/jf_tracker_pm.lua'); ctx.PM.init(U, ctx)
      state.pm_flush = ctx.PM.flush
      local sh = reaper.GetExtState(EXT, 'pmshape'); ctx.PM.shape = (sh == 'square' or sh == 'compact') and sh or 'wide'
      ctx.PM.show_thumb, ctx.PM.show_icon = state.pmthumb ~= false, state.pmicon ~= false
    end
    return ctx.PM
  end,
  pm_cards = function() return state.pmgrid and state.pm_ok or false end,
  -- ── session (6 окт): клипы как в Ableton — модуль SS, REAPER здесь ──────
  alias = alias,
  -- DSP big (7 окт): цепочка FX на всё окно (MX.DB); панель DSP держится
  -- открытой, пока вид открыт (фокус dsp), на выходе — как было
  dsp_big = function()
    if state.dsp_big then
      state.dsp_big = false
      if state.dsp_big_saved ~= nil then state.dsp = state.dsp_big_saved; state.dsp_big_saved = nil end
      relayout(); ctx.set_focus(state.dsp and 'dsp' or 'tracker')
      vim.msg = 'router off: fx blocks'
    else
      state.dsp_big_saved = state.dsp
      state.dsp, state.dsp_big = true, true
      ctx.db_cache = nil
      relayout(); ctx.set_focus('dsp')
      vim.msg = 'router in DSP: h l signal, j k row, a / A add, | join row, s solo, = unity, b bypass, x delete, zz back'
    end
  end,
  -- большой роутер (7 окт, zR): на всё окно, узлы — устройства со слайдерами
  router_big = function()
    state.router_big = not state.router_big
    if state.router_big then
      state.rb_saved = state.dsp; state.dsp = true            -- клавиши DSP-ветки требуют панель
      state.rb_top = { state.top, state.toptab }
      state.top, state.toptab = true, 'modulation'           -- наверху — автоматизация (7 окт)
      state.rb_bmode = B.mode; B.mode = 'fx'; state.side = true   -- браузер — на вкладку fx (эффекты бросать в роутер)
      ctx.db_cache = nil; relayout(); ctx.set_focus('dsp'); vim.msg = 'router big: drag the sliders, dblclick - default, h l j k walk, zR / Esc back'
    else
      if state.rb_saved ~= nil and not state.dsp_big then state.dsp = state.rb_saved end
      if state.rb_top then state.top, state.toptab = state.rb_top[1], state.rb_top[2] end
      if state.rb_bmode then B.mode = state.rb_bmode; state.rb_bmode = nil end
      state.rb_saved, state.rb_top = nil, nil
      relayout(); ctx.set_focus(state.dsp and 'dsp' or 'tracker'); vim.msg = 'router big: back'
    end
  end,
  -- параметры узла: подобранные модулем DSP (кураторские), иначе первые 8 плагина
  db_params = function(addr)
    local t = dsp_target(); if not t then return {} end
    local out = {}
    for _, f in ipairs(t.fx or {}) do
      for _, p in ipairs(f.params or {}) do
        local pa = p.fx or f.i
        if pa == addr and p.i then out[#out + 1] = { name = p.name, i = p.i, fx = addr } end
      end
      if #out > 0 then return out end
    end
    local A = model.fxapi(t.track)
    for i = 0, math.min(8, A.GetNumParams(t.track, addr)) - 1 do
      local _, nm = A.GetParamName(t.track, addr, i, '')
      out[#out + 1] = { name = nm, i = i, fx = addr }
    end
    return out
  end,
  db_pval = function(addr, i)
    local t = dsp_target(); if not t then return 0, '' end
    local A = model.fxapi(t.track)
    local _, s2 = A.GetFormattedParamValue(t.track, addr, i, '')
    return A.GetParamNormalized(t.track, addr, i), s2
  end,
  -- дерево цепочки цели DSP; перечитывается 4 раза в секунду и после правки
  db_tree = function()
    local t = dsp_target(); if not t then return nil end
    local c = ctx.db_cache
    local now = reaper.time_precise()
    if not c or c.obj ~= t.track or now - c.t > 0.25 or c.gen ~= model.fx_gen then
      c = { obj = t.track, t = now, gen = model.fx_gen, root = MX.DB.read(t.track, model.fxapi(t.track)), title = (t.take and 'take fx of ' or '') .. (t.name or '') }
      ctx.db_cache = c
    end
    return c.root, c.obj, c.title
  end,
  ss_big = function()
    if state.ss_big then
      for k, v in pairs(state.ss_saved or {}) do state[k] = v end
      state.ss_big, state.ss_saved = false, nil
      relayout(); ctx.set_focus('matrix')
      vim.msg = MX.SS.playing_any() and 'session keeps playing (Q in the view or :session off stops it)' or 'session: back to the matrix'
    else
      state.ss_saved = {}
      for _, k in ipairs({ 'top', 'dsp', 'mx_hidden', 'side', 'khelp' }) do state.ss_saved[k] = state[k] end
      state.top, state.dsp, state.mx_hidden, state.side, state.khelp = false, false, false, false, false
      state.ss_big = true
      MX.SS.cur.ri, MX.SS.cur.ci = math.max(1, MX.cur.ri), math.max(1, MX.cur.ci)
      relayout(); ctx.set_focus('matrix')
      vim.msg = 'session: Enter launch, O / F scene, x stop, X stop all, q quantize, Space transport, Q off, zz / Esc back'
    end
  end,
  -- зона сессии: регион =SESSION за =END (трекер его не показывает); нет —
  -- создаётся через такт после всего проекта, длиной ssbars тактов
  ss_zone = function(qn)
    -- маркеры читаются напрямую, не из regions: таблица обновляется снимком,
    -- и два вызова подряд создавали две зоны (6 окт, песочница)
    local i = 0
    while true do
      local ret, isrgn, pos, rgnend, name = reaper.EnumProjectMarkers3(0, i)
      if not ret or ret == 0 then break end
      if isrgn and name == model.SESSION_REGION then
        local _, _, _, _, _, idx = reaper.EnumProjectMarkers3(0, i)
        return { pos = pos, rgnend = rgnend, session = true, name = name, idx = idx }
      end
      i = i + 1
    end
    -- только что созданный регион в этом же кадре через Enum ещё не виден —
    -- иначе второй вызов создавал вторую зону (6 окт)
    local c = state.ss_zone_new
    if c and reaper.time_precise() - c.t < 5 then return c end
    if not reaper.AddProjectMarker2 then return nil end
    local t = math.max(reaper.GetProjectLength(0), regions.end_pos or 0)
    for _, rg in ipairs(regions) do if rg.rgnend > t then t = rg.rgnend end end
    local _, meas = reaper.TimeMap2_timeToBeats(0, t)
    local z0 = reaper.TimeMap2_beatsToTime(0, 0, meas + 2)
    -- длина: НОК клипов (qn, 7 окт) или session bars
    local z1 = qn and reaper.TimeMap2_QNToTime(0, reaper.TimeMap2_timeToQN(0, z0) + qn) or reaper.TimeMap2_beatsToTime(0, 0, meas + 2 + (state.ssbars or 8))
    local idx = reaper.AddProjectMarker2(0, true, z0, z1, model.SESSION_REGION, -1, 0)
    model.invalidate()
    state.ss_zone_new = { pos = z0, rgnend = z1, session = true, name = model.SESSION_REGION, t = reaper.time_precise(), idx = idx }
    return state.ss_zone_new
  end,
  -- зона под need долей (7 окт, полиметрия): длиннее — регион растёт, луп
  -- транспорта следом, играющим клипам досаживается хвост [старый конец,
  -- новый) их фазой (он впереди плейхеда — не щёлкнет); shrink — можно и
  -- укоротить (никто не играет)
  ss_zone_fit = function(z, need, sq, shrink)
    if not (z and z.idx and need) then return z end
    local q0 = reaper.TimeMap2_timeToQN(0, z.pos)
    local cur = reaper.TimeMap2_timeToQN(0, z.rgnend) - q0
    if math.abs(need - cur) < 1e-4 or (need < cur and not shrink) then return z end
    local old_end, new_end = z.rgnend, reaper.TimeMap2_QNToTime(0, q0 + need)
    reaper.SetProjectMarker3(0, z.idx, true, z.pos, new_end, model.SESSION_REGION, 0)
    z.rgnend = new_end
    state.ss_zone_new = { pos = z.pos, rgnend = new_end, session = true, name = model.SESSION_REGION, t = reaper.time_precise(), idx = z.idx }
    local l0, l1 = reaper.GetSet_LoopTimeRange(false, true, 0, 0, false)
    if math.abs(l0 - z.pos) < 1e-4 then reaper.GetSet_LoopTimeRange(true, true, z.pos, new_end, false) end
    if new_end > old_end and snap then
      edit.run('session zone ' .. need .. ' beats', function()
        for ci, l in pairs(MX.SS.live) do
          local col, src = ctx.ss_V().cols[ci], sq[l.ri]
          if col and src then
            local o = MX.SS.plant_opt(l, col.track, src) or {}
            o.lane = col.lane
            alias.session_plant(col.track, src, z.pos, new_end, l.phase, nil, l.ri .. ':' .. ci, { old_end, new_end }, o)
          end
        end
      end)
    elseif new_end < old_end and snap then
      edit.run('session zone ' .. need .. ' beats', function() for _, col in ipairs(snap.cols) do alias.session_clear(col.track, new_end, old_end) end end)
    end
    model.invalidate()
    vim.msg = ('session zone: %g beats (common length of the clips)'):format(need)
    return z
  end,
  ss_bar_after = function(t)
    local _, meas = reaper.TimeMap2_timeToBeats(0, t)
    local n = reaper.TimeMap2_beatsToTime(0, 0, meas + 1)
    if n <= t + 1e-6 then n = reaper.TimeMap2_beatsToTime(0, 0, meas + 2) end
    return n
  end,
  ss_beat_after = function(t) return reaper.TimeMap2_QNToTime(0, math.floor(reaper.TimeMap2_timeToQN(0, t) + 1e-6) + 1) end,
  ss_playpos = function() return reaper.GetPlayPosition(), playing() end,
  ss_play = function(z)
    reaper.GetSet_LoopTimeRange(true, true, z.pos, z.rgnend, false)
    reaper.GetSetRepeat(1)
    reaper.SetEditCurPos(z.pos, true, true)
    if not playing() then reaper.OnPlayButton() end
  end,
  ss_apply = function(desc, fn)
    local ok, e = pcall(edit.run, desc, fn)
    if not ok then vim.msg = 'session: ' .. tostring(e):match('[^\n]*$') end
    model.invalidate()
  end,
  ss_transport = function() edit.play_stop() end,
  ss_stop_transport = function() if playing() then reaper.OnStopButton() end end,
  ss_quit = function()
    local z = ctx.ss_zone()
    reaper.OnStopButton()
    edit.run('session off', function()
      if z and snap then for _, col in ipairs(snap.cols) do alias.session_clear(col.track, z.pos, z.rgnend) end end
      -- страховка: всё с меткой jf_session где бы ни лежало
      for ti = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, ti)
        for k = reaper.CountTrackMediaItems(tr) - 1, 0, -1 do
          local it = reaper.GetTrackMediaItem(tr, k)
          local _, t = reaper.GetSetMediaItemInfo_String(it, 'P_EXT:jf_session', '', false)
          if t ~= '' then reaper.DeleteTrackMediaItem(tr, it) end
        end
      end
    end)
    reaper.GetSetRepeat(0)
    model.invalidate()
  end,
  ss_colname = function(ci) local c = ctx.ss_V().cols[ci]; return c and c.name or ('track ' .. ci) end,
  -- громкость трека для кольца arc на странице clips (7 окт): 0..1 = −60..+12 дБ
  ss_vol = function(ci)
    local c = ctx.ss_V().cols[ci]
    if not c or not c.track or not reaper.ValidatePtr(c.track, 'MediaTrack*') then return 0 end
    local v = reaper.GetMediaTrackInfo_Value(c.track, 'D_VOL')
    local db = v > 1e-6 and 20 * math.log(v, 10) or -60
    return math.max(0, math.min(1, (db + 60) / 72))
  end,
  ss_vol_add = function(ci, d)   -- d шагов по 0.5 дБ
    local c = ctx.ss_V().cols[ci]
    if not c or not c.track or not reaper.ValidatePtr(c.track, 'MediaTrack*') then return end
    local v = reaper.GetMediaTrackInfo_Value(c.track, 'D_VOL')
    local db = math.max(-60, math.min(12, (v > 1e-6 and 20 * math.log(v, 10) or -60) + d * 0.5))
    reaper.SetMediaTrackInfo_Value(c.track, 'D_VOL', db <= -60 and 0 or 10 ^ (db / 20))
    vim.msg = ('%s: %.1f dB'):format(c.name or ('track ' .. ci), db)
  end,
  ss_is_big = function() return state.ss_big and true or false end,
  -- 7 окт: колонки сессии — по лейнам (MX.vcols), клетки — MX.vgrid
  ss_V = function() return snap and MX.vcols(snap) or { cols = {} } end,
  ss_G = function() return snap and MX.vgrid(snap, seq) or {} end,
  -- инфо трека для шапки (7 окт): кэш на полсекунды по треку
  hdr_cache = {},
  -- параметры, вынесенные в TCP (8 окт): REAPER пишет их в chunk трека
  -- строкой PARM_TCP после FXID эффекта («80:… 84:…» — номер параметра до
  -- двоеточия); API нет — chunk читается не чаще раза в 2 с и при правках
  tcp_cache = {},
  tcp_params = function(col)
    local tr = col.track
    if not (tr and reaper.ValidatePtr(tr, 'MediaTrack*')) then return {} end
    local now, sc = reaper.time_precise(), reaper.GetProjectStateChangeCount(0)
    local c = ctx.tcp_cache[col.guid]
    if c and (c.sc == sc or now - c.t < 2) then return c.by end
    local by = {}
    if reaper.CountTCPFXParms then
      -- 8 окт: нативное API (CountTCPFXParms / GetTCPFXParm) — без чтения chunk
      for k = 0, reaper.CountTCPFXParms(0, tr) - 1 do
        local okp, fxi, pi = reaper.GetTCPFXParm(0, tr, k)
        local g = okp and reaper.TrackFX_GetFXGUID(tr, fxi)
        if g then by[g] = by[g] or {}; table.insert(by[g], pi) end
      end
      ctx.tcp_cache[col.guid] = { t = now, sc = sc, by = by }
      return by
    end
    local ok, chunk = reaper.GetTrackStateChunk(tr, '', false)
    if ok then
      local guid
      for ln in chunk:gmatch('[^\n]+') do
        local g = ln:match('^%s*FXID%s+(%b{})')
        if g then guid = g
        elseif guid then
          local rest = ln:match('^%s*PARM_TCP%s+(.*)$')
          if rest then
            local list = {}
            for tok in rest:gmatch('%S+') do local n = tonumber(tok:match('^(%d+)')); if n then list[#list + 1] = n end end
            by[guid] = list; guid = nil
          elseif ln:match('^%s*WAK') then guid = nil end
        end
      end
    end
    ctx.tcp_cache[col.guid] = { t = now, sc = sc, by = by }
    return by
  end,
  param_in_tcp = function(tr, fx, pi)
    if reaper.CountTCPFXParms then
      for k = 0, reaper.CountTCPFXParms(0, tr) - 1 do
        local ok, f2, p2 = reaper.GetTCPFXParm(0, tr, k)
        if ok and f2 == fx and p2 == pi then return true end
      end
    end
    return false
  end,
  param_tcp_toggle = function(tr, fx, pi, name)
    local ok, on = edit.fx_param_tcp(tr, fx, pi)
    ctx.tcp_cache, ctx.hdr_cache = {}, {}
    if ok and on and not state.fxparams then state.fxparams = true; state.fxrow = true; reaper.SetExtState(EXT, 'fxparams', '1', true); reaper.SetExtState(EXT, 'fxrow', '1', true); relayout() end
    vim.msg = ok and ((name or 'parameter') .. (on and ': in the track header (param)' or ': removed from the track header')) or 'track header: failed'
  end,
  -- меню параметра (8 окт): модуляция, автоматизация, шапка трека, умолчание
  param_menu_items = function(tr, fx, pi, pname, add)
    local function flag(what) local ok, v = reaper.TrackFX_GetNamedConfigParm(tr, fx, ('param.%d.%s.active'):format(pi, what)); return ok and v == '1' end
    pname = pname or select(2, reaper.TrackFX_GetParamName(tr, fx, pi, '')) or ('p' .. pi)
    add((flag('lfo') and '!' or '') .. 'Modulate ' .. pname .. ': LFO', function() edit.mod_set(tr, fx, pi, 'lfo') end)
    add((flag('acs') and '!' or '') .. 'Modulate: audio control (ACS)', function() edit.mod_set(tr, fx, pi, 'acs') end)
    add((flag('plink') and '!' or '') .. 'Link to parameter … (fzf)', function()
      local items = {}
      for f2 = 0, reaper.TrackFX_GetCount(tr) - 1 do
        local _, fnm = reaper.TrackFX_GetFXName(tr, f2, '')
        for q = 0, math.min(64, reaper.TrackFX_GetNumParams(tr, f2)) - 1 do
          if not (f2 == fx and q == pi) then
            local _, qn = reaper.TrackFX_GetParamName(tr, f2, q, '')
            items[#items + 1] = { label = (fnm or ''):gsub('^[^:]*: ', '') .. ' / ' .. (qn or q), data = { fx = f2, param = q } }
          end
        end
      end
      vim.open_picker('link ' .. pname .. ' to', items, function(it) edit.mod_set(tr, fx, pi, 'plink', true, it.data.fx, it.data.param) end)
    end)
    if flag('plink') then add('Unlink parameter', function() edit.mod_set(tr, fx, pi, 'plink', false) end) end
    add('Open parameter modulation window', function()
      local v = reaper.TrackFX_GetParamNormalized(tr, fx, pi); reaper.TrackFX_SetParamNormalized(tr, fx, pi, v)
      local cmd = ctx.cmd_by_text('parameter modulation/link') or ctx.cmd_by_text('parameter modulation')
      if cmd then reaper.Main_OnCommand(cmd, 0) else vim.msg = 'no modulation window action found' end
    end)
    add('Show automation envelope', function() edit.run('show envelope', function() reaper.GetFXEnvelope(tr, fx, pi, true) end); state.envs = true; model.invalidate() end)
    add((ctx.param_in_tcp(tr, fx, pi) and '!' or '') .. 'Show in track header (TCP, param)', function() ctx.param_tcp_toggle(tr, fx, pi, pname) end)
    add('Default value', function() edit.fx_param_default(tr, fx, pi); vim.msg = pname .. ': default' end)
    add('--', function() end)
  end,
  -- меню эффекта (8 окт): то же, что в DSP — bypass, окно, удалить, добавить
  fx_menu_items = function(tr, fx, fname, add)
    local en = reaper.TrackFX_GetEnabled(tr, fx)
    add((en and 'Bypass ' or 'Enable ') .. (fname or 'fx'), function() edit.fx_bypass(tr, fx) end)
    add('Open FX window', function() edit.fx_show(tr, fx) end)
    add('Show in DSP', function()
      for i, f in ipairs(L.flat or {}) do if f.col and f.col.track == tr then vim.cur.fi = i; break end end
      state.dsp = true; relayout()
      local c = cur_col(); for k, f in ipairs(c and c.fx or {}) do if f.i == fx then dsp_sel.fx = k end end
      ctx.set_focus('dsp')
    end)
    add('Rename … (:fxname)', function() state.fxname_target = { track = tr, addr = fx }; vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'fxname ' end)
    add('Remove FX', function() edit.fx_remove(tr, fx) end)
    add('Add FX … (fzf)', function() ctx.fx_picker() end)
  end,
  -- эффекты трека со строкой / столбиком (8 окт): строка effects и микшер.
  -- Рисует в [cx, right) от y0; avail — строк в распоряжении; vert — столбиком
  -- всегда (микшер); возвращает, сколько строк нужно (для высоты строки effects)
  -- кнопка param (параметры TCP под эффектами): в строке effects, в микшере —
  -- в уголке под кнопками вида (строки effects там нет)
  -- аккорды (8 окт): :chord — трек курсора одним лейном аккордов (state.folds
  -- = 'chord', ещё раз — обратно); :chord Cm7 — гармонайзер: аккорд в строку
  -- курсора (ноты, что там начинаются, заменяются; длина — как у них, иначе
  -- до следующих нот трека, не больше такта)
  chord_heads = function(col, row)
    local heads, pitches = {}, {}
    for _, lane in ipairs(col.lanes or {}) do
      for _, sub in ipairs(lane.subs or {}) do
        local c = sub[row]
        if c and c.kind == 'midi' and c.row0 == row then heads[#heads + 1] = c; pitches[#pitches + 1] = c.pitch end
      end
    end
    return heads, pitches
  end,
  chord_cmd = function(arg)
    local col = cur_col(); if not col then vim.msg = 'chord: no track under the cursor'; return end
    arg = (arg or ''):match('^%s*(.-)%s*$')
    if arg == '' or arg == 'off' then
      local on = state.folds[col.guid] == 'chord'
      if arg == 'off' then on = true end
      state.folds[col.guid] = (not on) and 'chord' or nil
      relayout()
      vim.msg = col.name .. (on and ': notes again' or ': one chord lane - names from the notes; :chord Cm7 writes a chord at the cursor')
      return
    end
    local pitches = MMX.CH.voicing(arg, math.max(1, math.min(7, (vim.octave or 4))))
    if not pitches then vim.msg = 'chord: what is ' .. arg .. '? (C Cm C7 Cmaj7 Cm7 Cdim Caug Csus4 C6 C9 ... /bass)'; return end
    local row = vim.cur.row
    local heads = ctx.chord_heads(col, row)
    local rows
    for _, h in ipairs(heads) do rows = math.max(rows or 0, h.rows or 1) end
    if not rows then
      local sn, sd = ctx.sig_at(edit.row_time(row, state.lpb, 0)); local rb = math.max(1, math.floor(state.lpb * sn * 4 / sd + 0.5))   -- такт в строках
      rows = rb
      for r = row + 1, row + rb - 1 do if #ctx.chord_heads(col, r) > 0 then rows = r - row; break end end
    end
    edit.run('chord ' .. arg, function()
      if #heads > 0 then edit.delete(heads, state.lpb) end
      for _, p in ipairs(pitches) do edit.insert_note(col.track, nil, state.lpb, row, p, vim.vel or 100, rows) end
    end)
    model.invalidate()
    vim.msg = ('%s: %s at %d, %d row(s) - %s'):format(col.name, arg, row, rows, table.concat((function() local t = {} for _, p in ipairs(pitches) do t[#t + 1] = model.note_name(p) end return t end)(), ' '))
  end,
  fx_stack = function(hover, col, cx, right, y0, avail, force_vert, MAXL)
    local mx, my = gfx.mouse_x, gfx.mouse_y
    local hi = ctx.hdr_info(col)
    local list = {}
    local np = 0
    for k, it in ipairs(hi.fx or {}) do
      list[#list + 1] = { it = it, k = k, kind = 'hdrfx' }
      for _, pi in ipairs(it.params or {}) do list[#list + 1] = { it = it, k = k, kind = 'hdrparam', param = pi }; np = np + 1 end   -- параметры TCP — под своим эффектом
    end
    for k, it in ipairs(hi.sends or {}) do list[#list + 1] = { it = it, k = k, kind = 'hdrsend' } end
    local sum = 0
    for _, e in ipairs(list) do sum = sum + U.measure(ctx.fit(e.it.name or '', L.cw * 9)) + 2 * L.pad + 2 end
    local vert = force_vert or np > 0 or (#list > 1 and sum > right - cx)
    local function pslider(e, x, y, w2)
      local tr, fx, pi = col.track, e.it.i, e.param
      if not (tr and fx and reaper.ValidatePtr(tr, 'MediaTrack*')) then return end
      local v = reaper.TrackFX_GetParamNormalized(tr, fx, pi)
      local _, pn = reaper.TrackFX_GetParamName(tr, fx, pi, '')
      local _, fv = reaper.TrackFX_GetFormattedParamValue(tr, fx, pi, '')
      local hot = (mx >= x and mx < x + w2 and my >= y and my < y + L.rh) or (ctx.hp_drag and ctx.hp_drag.track == tr and ctx.hp_drag.fx == fx and ctx.hp_drag.param == pi)
      local vw = U.measure(fv or '')
      local nw = w2 - 2 * L.pad - (vw + L.pad < w2 * 0.5 and vw + L.pad or 0)
      U.text(x + L.pad, y, ctx.fit(pn or ('p' .. pi), nw), hot and U.AMBER or U.GREY)
      if vw + L.pad < w2 * 0.5 then U.text(x + w2 - L.pad - vw, y, fv, hot and U.AMBER or U.TEXT) end
      U.set(U.LINE); gfx.rect(x + 1, y + L.rh - 3, w2 - 2, 2, 1)
      U.set(hot and U.AMBER or U.CYAN); gfx.rect(x + 1, y + L.rh - 3, math.max(1, math.floor((w2 - 2) * v + 0.5)), 2, 1)
      if hot then hover.hdrparam = { track = tr, fx = fx, param = pi, x = x + 1, w = w2 - 2, name = pn, col = col, k = e.k } end
      ctx.hint('hdrparam', x, y, w2, L.rh, { col = col, k = e.k })
    end
    local function chip(e, x, y, w2, lab)
      local hot = mx >= x and mx < x + w2 and my >= y and my < y + L.rh
      local cbg = hot and U.tint(U.AMBER, 0.3) or U.BG
      U.set(cbg); gfx.rect(x, y, w2, L.rh - 1, 1)
      -- 8 окт: шапка подменяет U.TEXT / U.GREY под свою заливку (на светлой —
      -- тёмные), а плашка тёмная — цвет подтягиваем к фону самой плашки
      U.text(x + L.pad, y, lab, U.readable(hot and U.AMBER or (e.it.off and U.GREY or (e.kind == 'hdrsend' and U.CYAN or U.TEXT)), cbg, 4.5))
      if hot then hover[e.kind] = { col = col, k = e.k, it = e.it } end
      ctx.hint(e.kind, x, y, w2, L.rh, { col = col, k = e.k })
    end
    if vert then
      local shown = math.min(#list, avail)
      for n = 1, shown do
        local e = list[n]
        local y = y0 + (n - 1) * L.rh
        if n == shown and #list > shown then U.text(cx + L.pad, y, '+' .. (#list - shown + 1), U.CYAN)
        elseif e.kind == 'hdrparam' then pslider(e, cx, y, right - cx)
        else chip(e, cx, y, right - cx, draw.fit_short(e.it.name or '', right - cx - 2 * L.pad)) end   -- тесно — согласными
      end
      return math.min(#list, MAXL or #list)
    end
    for n, e in ipairs(list) do
      local lab = ctx.fit(e.it.name or '', L.cw * 9)
      local w2 = U.measure(lab) + 2 * L.pad
      local more = #list - n + 1
      local avail_w = right - cx - (more > 1 and U.measure('+9') + 2 or 0)
      if w2 > avail_w and avail_w >= L.cw * 3 + 2 * L.pad then lab = ctx.fit(e.it.name or '', avail_w - 2 * L.pad); w2 = U.measure(lab) + 2 * L.pad end
      if cx + w2 > right - (more > 1 and U.measure('+9') + 2 or 0) then U.text(right - U.measure('+' .. more), y0, '+' .. more, U.CYAN); break end
      chip(e, cx, y0, w2, lab)
      cx = cx + w2 + 2
    end
    return 1
  end,
  hdr_info = function(col)
    local now = reaper.time_precise()
    local c = ctx.hdr_cache[col.guid]
    if c and now - c.t < 0.5 and c.snap == snap then return c end
    c = { t = now, snap = snap, inst = {}, fx = {}, sends = {} }
    for i, e in ipairs(snap and snap.pool or {}) do
      if not e.parent and e.home == col.name then c.inst[#c.inst + 1] = { name = e.name or '?', i = i } end
    end
    local tcp = state.fxparams and ctx.tcp_params(col) or nil
    for k, f in ipairs(col.fx or {}) do
      local e = { name = f.name, off = not f.enabled, k = k, i = f.i }
      if tcp and col.track and f.i and reaper.ValidatePtr(col.track, 'MediaTrack*') then e.params = tcp[reaper.TrackFX_GetFXGUID(col.track, f.i) or ''] end
      c.fx[#c.fx + 1] = e
    end
    local tr = col.track
    if tr and reaper.ValidatePtr(tr, 'MediaTrack*') then
      for si = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
        local dst = reaper.GetTrackSendInfo_Value(tr, 0, si, 'P_DESTTRACK')
        local nm = '?'
        if dst and reaper.ValidatePtr(dst, 'MediaTrack*') then local _, n2 = reaper.GetTrackName(dst); nm = n2 end
        c.sends[#c.sends + 1] = { name = '> ' .. nm, off = reaper.GetTrackSendInfo_Value(tr, 0, si, 'B_MUTE') == 1, si = si }
      end
    end
    ctx.hdr_cache[col.guid] = c
    return c
  end,
  -- щелчок по фишке шапки: эффект — в DSP (повтор — окно), инструмент — в lib,
  -- сенд — окно маршрутизации REAPER для трека
  hdr_pick = function(kind, col, k, dbl)
    for i, f in ipairs(L.flat or {}) do if f.col == col then vim.cur.fi = i; break end end
    if kind == 'fx' then
      state.dsp = true; dsp_sel.fx = k; relayout()
      if dbl and col.fx[k] then edit.fx_show(col.track, col.fx[k].i) end
      vim.msg = (col.name or '') .. ': ' .. ((col.fx[k] or {}).name or '')
    elseif kind == 'inst' then
      local c = ctx.hdr_cache[col.guid]; local it = c and c.inst[k]
      if it then pool_select(it.i); ctx.set_focus('inst') end
    elseif kind == 'send' then
      if col.track and reaper.ValidatePtr(col.track, 'MediaTrack*') then reaper.SetOnlyTrackSelected(col.track); reaper.Main_OnCommand(40293, 0) end
    end
  end,
  -- session в масштабе трекера (7 окт): строка точек, метр, follow actions
  empty_row = function(y) draw.empty_row(L, y) end,
  ss_clip_rows = function() return tonumber(state.ssrows) or 2 end,   -- 7 окт: клип — 2 строки (волна, имя поверх)
  -- follow actions: P_EXT:jf_ssfa трека = «idx=a,idx=a» (idx — номер региона-слота)
  ss_fa_cache = {},
  ss_fa = function(ci, ri, sq)
    local c = ctx.ss_V().cols[ci]
    local rg = (sq or seq)[ri]
    if not (c and c.track and rg) then return 'l' end
    local cache = ctx.ss_fa_cache[c.col and c.col.guid or c.guid]
    local now = reaper.time_precise()
    if not cache or now - cache.t > 1 then
      local _, v = reaper.GetSetMediaTrackInfo_String(c.track, 'P_EXT:jf_ssfa', '', false)
      cache = { t = now, map = {} }
      for k, a in (v or ''):gmatch('([%d%.]+)=(%a)') do cache.map[k] = a end   -- ключ «слот» или «слот.лейн» (7 окт)
      ctx.ss_fa_cache[c.col and c.col.guid or c.guid] = cache
    end
    return cache.map[tostring(rg.idx) .. ((c.li or 1) > 1 and ('.' .. c.li) or '')] or 'l'
  end,
  ss_fa_set = function(ci, ri, sq, a)
    local c = ctx.ss_V().cols[ci]
    local rg = (sq or seq)[ri]
    if not (c and c.track and rg) then return end
    ctx.ss_fa(ci, ri, sq)
    local map = ctx.ss_fa_cache[c.col and c.col.guid or c.guid].map
    map[tostring(rg.idx) .. ((c.li or 1) > 1 and ('.' .. c.li) or '')] = a ~= 'l' and a or nil
    local parts = {}
    for k, v in pairs(map) do parts[#parts + 1] = k .. '=' .. v end
    table.sort(parts)
    reaper.GetSetMediaTrackInfo_String(c.track, 'P_EXT:jf_ssfa', table.concat(parts, ','), true)
    -- играет этот клип — действие сразу в силе
    local lv = MX.SS.live[ci]
    if lv and lv.ri == ri then lv.fa = a; lv.fa_done = nil end
  end,
  -- песочница тестов: проект без имени, треки sandbox_setup.lua
  is_sandbox = function()
    local _, pname = reaper.EnumProjects(-1, '')
    if pname and pname ~= '' then return false end
    local names = {}
    for i = 0, reaper.CountTracks(0) - 1 do local _, nm = reaper.GetTrackName(reaper.GetTrack(0, i)); names[#names + 1] = nm end
    return table.concat(names, ',') == 'A drums,B lanes,M synth,DEPOT'
  end,
  -- zs / быстрая опция clips: тело трекера ↔ клипы сессии
  clips_toggle = function()
    state.clipsview = not state.clipsview
    reaper.SetExtState(EXT, 'clipsview', state.clipsview and '1' or '0', true)
    if state.clipsview then
      local f = L and L.flat and L.flat[vim.cur.fi]
      MX.SS.cur.ci = 1
      if f and snap then for i, v in ipairs(ctx.ss_V().cols) do if v.col == f.col then MX.SS.cur.ci = i; break end end end   -- первый лейн трека курсора
      MX.SS.cur.ri = math.max(1, MX.cur.ri)
      ctx.set_focus('session')
    elseif state.focus == 'session' then ctx.set_focus('tracker') end
    vim.msg = state.clipsview and 'session: clip mode - the keyboard launches clips (letters in the cells), Tab tracker' or 'tracker rows'
  end,
  ss_height = function(w, cap) return MX.SS.height(w, cap, math.max(1, #ctx.ss_V().cols), #seq, L.cw, L.rh, L.pad) end,
  ss_peaks = function(head, n) return model.peaks(head, n) end,
  ss_px = function() return state.ss_px end,
  -- луп / кроссфейд клипа (6 окт): один аудио-item в слоте с jf_cliploop или jf_clipxf
  ss_clip_opts = function(tr, rg)
    local items = alias.items_in(tr, rg.pos, rg.rgnend)
    if #items ~= 1 then return nil end
    local it = items[1]
    local tk = reaper.GetActiveTake(it)
    if not tk or reaper.TakeIsMIDI(tk) then return nil end
    local _, lp = reaper.GetSetMediaItemInfo_String(it, 'P_EXT:jf_cliploop', '', false)
    local _, xs = reaper.GetSetMediaItemInfo_String(it, 'P_EXT:jf_clipxf', '', false)
    local la, lb = (lp or ''):match('^([%-%d%.]+);([%-%d%.]+)$')
    local xf = (tonumber(xs) or 0) / 1000
    if not la and xf <= 0 then return nil end
    local rate = reaper.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
    local offs = reaper.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS')
    la, lb = tonumber(la) or offs, tonumber(lb) or (offs + reaper.GetMediaItemInfo_Value(it, 'D_LENGTH') * rate)
    return { item = it, la = la, lb = lb, rate = rate, xf = xf }
  end,
  -- R на клипе (6 окт): нативная запись в слот — arm трека, time selection =
  -- слот, режим auto-punch, пре-ролл такт, 1013; стоп — за концом слота
  -- (ctx.ss_rec_tick). Повторное R — стоп. Прежние arm / режим / выделение
  -- возвращаются после записи
  ss_record = function(ri, ci)
    if MX.SS.rec then ctx.ss_rec_stop('stopped'); return end
    local col, rg = ctx.ss_V().cols[ci], seq[ri]
    if not (col and rg) then return end
    if rg.gap then vim.msg = 'record: name the slot first (n) - empty bars are not clips yet'; return end
    local tr = col.track
    local prev = { arm = reaper.GetMediaTrackInfo_Value(tr, 'I_RECARM'), mode = nil }
    prev.t0, prev.t1 = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local punch
    for id = 40070, 40080 do
      local txt = reaper.kbd_getTextFromCmd(id, 0) or ''
      if txt:match('^Record: Set record mode to') and reaper.GetToggleCommandState(id) == 1 then prev.mode = id end
      if txt:match('^Record: Set record mode to time selection auto%-punch') then punch = id end
    end
    if not punch then vim.msg = 'record: no auto-punch record mode action found'; return end
    if playing() then reaper.OnStopButton() end
    reaper.SetMediaTrackInfo_Value(tr, 'I_RECARM', 1)
    reaper.GetSet_LoopTimeRange(true, false, rg.pos, rg.rgnend, false)
    reaper.Main_OnCommand(punch, 0)
    local _, meas = reaper.TimeMap2_timeToBeats(0, rg.pos)
    local pre = math.max(0, reaper.TimeMap2_beatsToTime(0, 0, math.max(0, meas - 1)))   -- такт пре-ролла
    reaper.SetEditCurPos(pre, true, false)
    MX.SS.rec = { ri = ri, ci = ci, track = tr, t1 = rg.rgnend, prev = prev, t = reaper.time_precise() }
    reaper.Main_OnCommand(1013, 0)
    vim.msg = ('record into %s / %s: count-in 1 bar, stops at the slot end (R - stop now)'):format(col.name, MX.SS.slot_name(rg, ri))
  end,
  ss_rec_stop = function(why)
    local r = MX.SS.rec; if not r then return end
    MX.SS.rec = nil
    if reaper.GetPlayState() & 4 == 4 then reaper.Main_OnCommand(40667, 0) elseif playing() then reaper.OnStopButton() end   -- стоп, записанное сохранить
    if reaper.ValidatePtr(r.track, 'MediaTrack*') then reaper.SetMediaTrackInfo_Value(r.track, 'I_RECARM', r.prev.arm) end
    if r.prev.mode then reaper.Main_OnCommand(r.prev.mode, 0) end
    reaper.GetSet_LoopTimeRange(true, false, r.prev.t0, r.prev.t1, false)
    model.invalidate()
    vim.msg = 'record into the clip: ' .. (why or 'done') .. ' - Enter launches it'
  end,
  -- каждый кадр: запись дошла до конца слота / остановлена снаружи
  ss_rec_tick = function()
    local r = MX.SS.rec; if not r then return end
    local st = reaper.GetPlayState()
    if reaper.time_precise() - r.t > 0.5 and st & 4 == 0 then ctx.ss_rec_stop('stopped outside'); return end
    if st & 4 == 4 and reaper.GetPlayPosition() >= r.t1 + 0.05 then ctx.ss_rec_stop('slot recorded') end
  end,
  -- dd в clips (6 окт): клип = items трека в слоте — удаляются (undo); играет — стоп
  ss_delete = function(ri, ci)
    local col, rg = ctx.ss_V().cols[ci], seq[ri]
    if not (col and rg) then return end
    local items = alias.items_in(col.track, rg.pos, rg.rgnend)
    if col.lane then   -- клип лейна (7 окт): только items этого лейна
      local keep = {}
      for _, it in ipairs(items) do if reaper.GetMediaItemInfo_Value(it, 'I_FIXEDLANE') == col.lane then keep[#keep + 1] = it end end
      items = keep
    end
    if #items == 0 then vim.msg = 'empty clip'; return end
    if MX.SS.live[ci] and MX.SS.live[ci].ri == ri then MX.SS.stop(ci) end
    edit.run('delete clip', function() for _, it in ipairs(items) do reaper.DeleteTrackMediaItem(col.track, it) end end)
    model.invalidate()
    vim.msg = ('clip deleted: %s / %s (%d items, u - undo)'):format(col.name, MX.SS.slot_name(rg, ri), #items)
  end,
  -- клип под курсором (6 окт): его сэмпл — во вкладке item, зона = начало / конец клипа, L — точки лупа
  -- выбор клипа (клик / курсор клип-мода): вкладка item показывает клип;
  -- prev — инструмент до клипа (вернуть, когда фокус уйдёт)
  ss_focus = function(ri, ci, grid)
    local cell = grid and grid[ri] and grid[ri][ci]
    local head
    for _, e in ipairs(cell and cell.ev or {}) do if e.head then head = e.head; break end end
    local prev = state.ss_clip and state.ss_clip.prev or vim.inst
    state.ss_clip = head and { item = head.item, prev = prev } or nil
    if not head then return end
    local n = snap and snap.inst_of and snap.inst_of[head.item]
    if n then
      local foc, pp = state.focus, state.poolprev
      state.poolprev = false; pool_select(n); state.poolprev = pp
      if not (state.top and state.toptab == 'clips') then state.top = true; state.toptab = 'sample' end   -- со вкладки clips не уводить
      ctx.set_focus(foc)
    end
  end,
  -- сетка сессии в панели матрицы (кнопка clips)
  ss_draw = function(Lx, x, y, w, h)
    if not snap then return {} end
    return MX.SS.draw_grid(Lx, x, y, w, h, seq, ctx.ss_V(), ctx.ss_G(), reaper.time_precise(), reaper.GetPlayPosition(), {}, true)
  end,
  -- 7 окт: вида clips в матрице нет — команда ведёт в тело трекера (zs)
  mx_clips_toggle = function() ctx.clips_toggle() end,
  -- файлы, брошенные на окно (Media Explorer, Finder): gfx.getdropfile
  os_drop = function(files, hv)
    if #files == 0 then return end
    local cell = hv.sess or (hv.matrix and hv.matrix.ri and hv.matrix.ci and hv.matrix) or nil
    if cell then
      -- на клетку сессии / ячейку матрицы: первый файл — в неё, следующие — в сцены ниже
      for k, f in ipairs(files) do if seq[cell.ri + k - 1] then ctx.ss_drop(cell.ri + k - 1, cell.ci, f) end end
    elseif hv.pool then for _, f in ipairs(files) do ctx.add_to_depot(f) end
    elseif hv.fi and hv.row then
      for k, f in ipairs(files) do ctx.drop_to(hv.fi, hv.row.row + k - 1, f) end
    else vim.msg = ('%d file(s): drop onto a track column, a session cell or the instruments'):format(#files) end
  end,
  -- бросок файла / карточки pm на клетку: в слот трека (как на колонку)
  ss_drop = function(ri, ci, path)
    local col, rg = ctx.ss_V().cols[ci], seq[ri]
    if not (col and rg) then return end
    for i, f in ipairs(L.flat) do
      if f.col == col.col and not f.folded and (not col.lane or (f.lane and f.lane.idx == col.lane)) then   -- лейн клипа (7 окт)
        local it = ctx.drop_to(i, rg.r0, path)
        -- аудио-клип — с beatsync по умолчанию (6 окт): ближайшая степень
        -- двойки долей по темпу слота, как B на инструменте; option session beatsync
        local bs = ''
        if it and state.ssbsync ~= false and reaper.ValidatePtr(it, 'MediaItem*') then
          local tk = reaper.GetActiveTake(it)
          if tk and not reaper.TakeIsMIDI(tk) and not path:lower():match('%.rpp$') then
            local span = reaper.GetMediaItemInfo_Value(it, 'D_LENGTH') * reaper.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
            local nb = edit.bsync_guess(span, rg.pos)
            edit.bsync_set({ it }, it, nb); model.invalidate()
            bs = (' beatsync %d'):format(nb)
          end
        end
        vim.msg = 'clip: ' .. (path:match('[^/]+$') or path) .. ' → ' .. col.name .. ' / ' .. MX.SS.slot_name(rg, ri) .. bs
        return
      end
    end
    vim.msg = 'session: the track column is folded'
  end,
  -- :session [big | stop | quant bar|beat|now | bars N | off]
  ss_cmd = function(arg)
    arg = (arg or ''):match('^%s*(.-)%s*$')
    local w1, w2 = arg:match('^(%S+)%s*(%S*)'); w1, w2 = w1 or '', w2 or ''
    if w1 == '' or w1 == 'big' then if not state.ss_big then ctx.ss_big() end
    elseif w1 == 'stop' and w2 == '' then MX.SS.stop_all(#ctx.ss_V().cols)
    elseif w1 == 'stop' and tonumber(w2) then MX.SS.stop(math.floor(tonumber(w2)))
    elseif w1 == 'launch' then
      local ri, ci = arg:match('^launch%s+(%d+)%s+(%d+)')
      if ri then MX.SS.launch(tonumber(ri), tonumber(ci), seq) else vim.msg = ':session launch <scene> <track>' end
    elseif w1 == 'scene' and tonumber(w2) then MX.SS.scene(math.floor(tonumber(w2)), seq, ctx.ss_G(), #ctx.ss_V().cols)
    elseif w1 == 'quant' and (w2 == 'bar' or w2 == 'beat' or w2 == 'now') then MX.SS.quant = w2; vim.msg = 'session quantize: ' .. w2
    elseif w1 == 'bars' and tonumber(w2) then state.ssbars = math.max(1, math.min(64, math.floor(tonumber(w2)))); vim.msg = 'session zone: ' .. state.ssbars .. ' bars (applies to a new zone; delete the =SESSION region to rebuild)'
    elseif w1 == 'jump' then local ci, k = arg:match('^jump%s+(%d+)%s+(%d+)'); if ci then MX.SS.jump(tonumber(ci), tonumber(k) - 1) end
    elseif w1 == 'loop' then local ci, a, b = arg:match('^loop%s+(%d+)%s+(%d+)%s+(%d+)'); if ci then MX.SS.loop(tonumber(ci), tonumber(a) - 1, tonumber(b) - 1) end
    elseif w1 == 'off' then MX.SS.quit()
    elseif w1 == 'clips' then ctx.mx_clips_toggle()
    elseif w1 == 'dump' then   -- тест: зона / live / pend
      local zz = model.session_zone(); local parts = { zz and ('zone %.2f..%.2f'):format(zz[1], zz[2]) or 'zone nil' }
      for ci, l in pairs(MX.SS.live) do parts[#parts + 1] = ('live[%d]=ri%d ph%.2f len%.2f a%.2f%s'):format(ci, l.ri, l.phase, l.len, l.a or 0, l.seg and (' seg' .. l.seg[1] .. '-' .. l.seg[2]) or '') end
      for ci, p in pairs(MX.SS.pend) do parts[#parts + 1] = ('pend[%d]=%s at%.2f'):format(ci, tostring(p.ri), p.at) end
      local i = 0
      while true do local ret, isrgn, pos, rgnend, name = reaper.EnumProjectMarkers3(0, i); if not ret or ret == 0 then break end; if isrgn then parts[#parts + 1] = ('rg[%s]%.1f-%.1f'):format(name, pos, rgnend) end; i = i + 1 end
      local g = snap and MX.grid(snap, seq) or {}
      local cells = {}
      for ri, row in pairs(g) do for ci, c in pairs(row) do if c.state ~= 'empty' then cells[#cells + 1] = ri .. ':' .. ci end end end
      table.sort(cells); parts[#parts + 1] = 'cells ' .. table.concat(cells, ',')
      -- зона в снимке: головы в строках зоны по колонкам
      if zz and snap then
        local r0z, r1z = model.row_of_time(zz[1], state.lpb), model.row_of_time(zz[2], state.lpb)
        local hs = {}
        for ci, col in ipairs(snap.cols) do
          local n = 0
          for _, lane in ipairs(col.lanes) do for _, sub in ipairs(lane.subs) do for r, cell in pairs(sub) do if r >= r0z and r < r1z and (cell.kind == 'audio' or cell.kind == 'midi') then n = n + 1 end end end end
          hs[#hs + 1] = n
        end
        parts[#parts + 1] = ('snapzone rows %d-%d heads %s show=%s end=%s'):format(math.floor(r0z), math.floor(r1z), table.concat(hs, '/'), tostring(model.SHOW_ZONE), tostring(snap.end_pos))
      end
      parts[#parts + 1] = 'msg=' .. tostring(vim.msg)
      reaper.SetExtState(EXT, 'ssdump', table.concat(parts, ' | '), false)
    else vim.msg = 'session: big | stop | quant bar|beat|now | bars N | off' end
  end,
  pm_big_on = function() return state.pm_big and true or false end,
  -- big (6 окт): карточки на всё окно — оверлей после draw.frame, раскладка
  -- сохраняется как в PT-mode и возвращается по Esc / b / :pm big
  pm_big = function()
    if state.pm_big then
      for k, v in pairs(state.pm_saved or {}) do state[k] = v end
      state.pm_big, state.pm_saved = false, nil
      relayout(); ctx.set_focus('browser')
      vim.msg = 'pm: back to the sidebar'
    else
      if not ctx.pm_cards() then vim.msg = 'pm cards: turn on the option pm cards (jf_pm) first'; return end
      state.pm_saved = {}
      for _, k in ipairs({ 'top', 'dsp', 'mx_hidden', 'side', 'khelp' }) do state.pm_saved[k] = state[k] end
      state.top, state.dsp, state.mx_hidden, state.side, state.khelp = false, false, true, true, false
      state.pm_big = true
      B.set_mode('pm'); B.grid = true
      relayout(); ctx.set_focus('browser')
      vim.msg = 'pm big: Esc / b - back; Enter open, Shift+Enter inside, Space listen, T tags, s status, p pin, a add'
    end
  end,
  -- :pm [big | grid | list | sort <mode> | daw <mode>] — без аргумента: вкладка pm
  pm_cmd = function(arg)
    arg = (arg or ''):match('^%s*(.-)%s*$')
    local w1, w2 = arg:match('^(%S+)%s*(%S*)')
    w1, w2 = w1 or '', w2 or ''                  -- :pm без слова — просто вкладка (nil ломал проверку ниже)
    if not ctx.pm_cards() and w1 ~= '' then vim.msg = 'pm cards: turn on the option pm cards (jf_pm) first'; return end
    if w1 == 'big' then ctx.pm_big(); return end
    state.side = true; B.set_mode('pm'); ctx.set_focus('browser')
    if w1 == 'grid' or w1 == 'list' then B.click(w1 == 'grid' and 'pmgrid' or 'pmlist')
    elseif w1 == 'sort' and w2 ~= '' then B.pm_sort = w2; reaper.SetExtState(EXT, 'pmsort', w2, true); B.pm = nil; B.set_all(B.read_pm()); vim.msg = 'pm: sort by ' .. w2
    elseif w1 == 'daw' and w2 ~= '' then B.pm_daw = w2; reaper.SetExtState(EXT, 'pmdaw', w2, true); B.pm = nil; B.set_all(B.read_pm()); vim.msg = 'pm: daw ' .. w2
    elseif w1 ~= '' then vim.msg = 'pm: big | grid | list | sort date|name|bpm|status | daw all|rpp|other' end
  end,
  -- a в сетке: проект сабпроектом в ячейку курсора (как бросок карточки)
  pm_add = function(e)
    if not (e and e.path) then return end
    ctx.drop_to(vim.cur.fi, vim.cur.row, e.path)
  end,
  preview_stop = function() PV.stop() end,
  sample_big = function()
    state.sample_big = not state.sample_big
    if state.sample_big then state.top = true; state.toptab = 'sample'; ctx.set_focus('top') end
    vim.msg = state.sample_big and 'big sample editor: wheel zoom at the mouse, sideways / Shift+wheel scroll; :big or big - back' or 'sample editor back to the top panel'
  end,
  -- PT-mode (3 окт, :pt): вид ProTracker — только трекер и скопы видимых
  -- треков сверху; матрица, lib / браузер, DSP спрятаны, курсор в центре, метры.
  -- Повтор — всё как было (state.pt_saved)
  pt_toggle = function()
    local K = { 'top', 'toptab', 'dsp', 'side', 'mx_hidden', 'fixed', 'meters', 'meterstyle', 'khelp', 'fontscale', 'fxcols', 'wavemode', 'wave', 'envs', 'lpb', 'wzoom', 'captions' }
    if state.ptmode then
      for _, k in ipairs(K) do state[k] = state.pt_saved and state.pt_saved[k] end
      state.ptmode, state.pt_saved = false, nil
      draw.set_font(state); model.invalidate()
      if state.focus ~= 'tracker' then ctx.set_focus('tracker') end
      vim.msg = 'PT-mode off: layout back'
    else
      state.pt_saved = {}
      for _, k in ipairs(K) do state.pt_saved[k] = state[k] end
      state.top, state.toptab, state.dsp, state.side, state.mx_hidden = true, 'scopes', false, false, true
      state.fixed, state.meters, state.meterstyle, state.khelp = true, true, 'pt', false
      -- «отупление» (3 окт): 4 канала, нота / сэмпл / громкость / одна команда,
      -- без волны и огибающих, LPB 4 (64 строки = 4 такта), битмап x4
      state.fxcols, state.wavemode, state.wave, state.envs, state.lpb, state.wzoom, state.captions = 1, 'off', 'off', false, 4, 0, false
      state.fontscale = 2                                    -- 6 окт: ×2 (×4 — огромно)
      state.pt_fit = true                                    -- кадр уменьшит масштаб, если 4 канала не влезли
      if not state.scopes then ctx.toggle_scopes(true) end
      state.ptmode = true
      draw.set_font(state); model.invalidate()
      ctx.set_focus('tracker')
      vim.msg = 'PT-mode: 4 channels, scopes on top (:pt again - back, :pt new - create CH1..CH4)'
    end
  end,
  -- :pt new (3 окт): в проекте ровно 4 канала CH1..CH4 (недостающие — новыми
  -- треками в конце), прокрутка на CH1, PT-mode включается
  pt_new = function()
    local have = {}
    for i = 0, reaper.CountTracks(0) - 1 do local _, nm = reaper.GetTrackName(reaper.GetTrack(0, i)); have[nm] = i end
    local made = edit.pt_tracks(have)
    model.invalidate()
    snap = model.snapshot(state.lpb)
    for ci, c in ipairs(snap.cols) do if c.name == 'CH1' then state.hscroll = ci; break end end
    if not state.ptmode then ctx.pt_toggle() end
    vim.msg = ('PT-mode: channels CH1..CH4 (%d new)'):format(made)
  end,
  -- треки, видимые сейчас в трекере (скопы PT-mode)
  visible_cols = function()
    local out = {}
    for _, c in ipairs(L and L.cols or {}) do if c.x and not c.hidden then out[#out + 1] = c.col end end
    return out
  end,
  -- прокрутка списков полосой / колесом (4 окт): lib, browser, matrix
  vbar_get = function(key)
    if key == 'lib' then return draw.pool_scroll elseif key == 'browser' then return B.scroll elseif key == 'matrix' then return MX.scroll or 0 elseif key == 'matrixh' then return MX.hs or 0
    elseif key == 'slices' then return SPROP.slice_scroll or 0 elseif key == 'sprops' then return SPROP.scroll or 0 end
    return 0
  end,
  vbar_scroll = function(key, v)
    local r = draw.vbars[key]
    local mx = r and math.max(0, r.total - r.nvis) or v
    v = math.max(0, math.min(mx, v))
    if key == 'lib' then draw.pool_scroll = v elseif key == 'browser' then B.scroll = v elseif key == 'matrix' then MX.scroll = v elseif key == 'matrixh' then MX.hs = v
    elseif key == 'slices' then SPROP.slice_scroll = v elseif key == 'sprops' then SPROP.scroll = v; SPROP.sel = math.max(SPROP.sel, v + 1) end
  end,
  -- swap (3 окт): 'on' — звук выбранного исходника подменён; файл — его новый
  -- звук (on) или выбранный в браузере (off)
  swap_info = function()
    local col = cur_col(); local e = col and col.pool[vim.inst]
    if e and e.parent then e = e.parent end
    if not (e and e.item and reaper.ValidatePtr(e.item, 'MediaItem*')) then return 'none' end
    if edit.swapped(e.item) then
      local tk = reaper.GetActiveTake(e.item); local src = tk and reaper.GetMediaItemTake_Source(tk)
      return 'on', src and reaper.GetMediaSourceFileName(src, ''):match('[^/]+$'), e
    end
    local be = B.entries and B.entries[B.cur]
    local path = be and not be.dir and not be.db and not be.trk and B.full(be)
    if path and not path:lower():match('%.wav$') and not path:lower():match('%.aiff?$') and not path:lower():match('%.flac$')
       and not path:lower():match('%.mp3$') and not path:lower():match('%.ogg$') and not path:lower():match('%.wv$') and not path:lower():match('%.caf$') and not path:lower():match('%.m4a$') then path = nil end
    return 'off', path and path:match('[^/]+$'), e, path
  end,
  swap_click = function()
    local st, file, e, path = ctx.swap_info()
    if st == 'on' then local n = edit.swap_source(e.item, nil); vim.msg = ('swap back: %d note(s) play the original again'):format(n)
    elseif st == 'off' and path then local n = edit.swap_source(e.item, path); vim.msg = ('swap: %s now plays %s in %d note(s)'):format(e.name or '?', file, n)
    else vim.msg = 'swap: select an audio file in the browser first' end
    model.invalidate()
  end,
  -- перестановка исходника в lib (3 окт): from — индекс пула (исходник),
  -- before — индекс пула исходника, перед которым встать (nil — в конец)
  lib_move = function(from, before)
    local col = cur_col(); local pool = col and col.pool or {}
    local src = pool[from]
    if not src or src.parent or from == before then return end
    local roots = {}
    for _, e in ipairs(pool) do if not e.parent and e ~= src then roots[#roots + 1] = e end end
    local at = #roots + 1
    for k, e in ipairs(roots) do if pool[before or 0] == e then at = k end end
    table.insert(roots, at, src)
    local items = {}
    for _, e in ipairs(roots) do items[#items + 1] = e.item end
    edit.lib_order(items)
    model.invalidate()
    reselect_item = src.item                 -- после пересборки выбор остаётся на нём
    vim.msg = ('lib: %s -> %02d'):format(src.name or '?', at)
  end,
  -- J / K в lib: выбранный исходник на место ниже / выше
  lib_step = function(d)
    local col = cur_col(); local pool = col and col.pool or {}
    local cur = pool[vim.inst]; if cur and cur.parent then cur = cur.parent end
    if not cur then return end
    local roots, at = {}, nil
    for i, e in ipairs(pool) do if not e.parent then roots[#roots + 1] = i; if e == cur then at = #roots end end end
    if not at then return end
    local from = roots[at]
    if d > 0 then
      if at >= #roots then return end
      ctx.lib_move(from, roots[at + 2])                -- перед тем, что был через один (nil — в конец)
    else
      if at <= 1 then return end
      ctx.lib_move(from, roots[at - 1])
    end
  end,
  -- Shift+Enter (3 окт): какой item / слайс под курсором — номер инструмента,
  -- исходник, слайс k или весь сэмпл, кусок файла, длина и rate
  describe_cell = function(cell)
    if not cell then return 'nothing under the cursor' end
    if cell.kind == 'midi' then return ('MIDI note %s ch %d vel %s'):format(cell.note or '?', (cell.ch or 0) + 1, tostring(cell.vel or '')) end
    local it = cell.item
    if not (it and reaper.ValidatePtr(it, 'MediaItem*')) then return 'no item under the cursor' end
    local tk = reaper.GetActiveTake(it)
    local src = tk and reaper.GetMediaItemTake_Source(tk)
    local file = src and (reaper.GetMediaSourceFileName(src, ''):match('[^/]+$')) or '?'
    local num = snap and snap.inst_num and snap.inst_num[it]
    local _, k = reaper.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice', '', false)
    local offs = tk and reaper.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS') or 0
    local rate = tk and reaper.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE') or 1
    local len = reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
    local what = (k ~= '' and ('slice S%02X'):format(tonumber(k) or 0)) or 'whole sample'
    return ('inst %s %s - %s | file %s @ %.3fs, %.3fs of file, len %.3fs, rate %.3f'):format(num and ('%02d'):format(num) or '--',
      cell.name or '', what, file, offs, len * rate, len, rate)
  end,
  -- имя входа записи трека (шапка, блок трека DSP)
  input_name = function(tr)
    local v = math.floor(reaper.GetMediaTrackInfo_Value(tr, 'I_RECINPUT'))
    if v < 0 then return 'none' end
    if v & 4096 ~= 0 then
      local dev, ch = (v >> 5) & 63, v & 31
      local dn = dev == 63 and 'all' or ((select(2, reaper.GetMIDIInputName(dev, ''))) or ('dev ' .. dev))
      return 'MIDI ' .. dn .. (ch == 0 and '' or (' ch ' .. ch))
    end
    local ch = v & 1023
    local nm = reaper.GetInputChannelName(ch) or ('in ' .. (ch + 1))
    if v & 1024 ~= 0 then nm = nm .. ' / ' .. (reaper.GetInputChannelName(ch + 1) or ('in ' .. (ch + 2))) end
    return nm
  end,
  -- список входов (3 окт): fzf под строкой входа; текущий отмечен ●; повторный
  -- клик по той же строке закрывает (picker.inp = guid трека)
  input_picker = function(col, anchor)
    if not col then return end
    if vim.picker and vim.picker.inp == col.guid then vim.picker = nil; return end
    local tr = col.track
    local cur = math.floor(reaper.GetMediaTrackInfo_Value(tr, 'I_RECINPUT'))
    local items = {}
    local function add(label, v) items[#items + 1] = { label = (v == cur and '● ' or '  ') .. label, data = v } end
    add('none', -1)
    local n = reaper.GetNumAudioInputs()
    -- 8 окт: у устройства 0 входов (CoreAudio без входа / закрыт) — всё равно
    -- аудио-входы 1..8 (пометка), и пункт настроек аудиоустройства
    local none = n == 0
    local na = none and 8 or n
    local function nm(i) return (not none and reaper.GetInputChannelName(i)) or ('in ' .. (i + 1)) end
    local tag = none and '   (the audio device has no inputs now)' or ''
    for i = 0, na - 1 do add('mono  ' .. nm(i) .. tag, i) end
    for i = 0, na - 2 do add(('stereo  %s / %s'):format(nm(i), nm(i + 1)) .. tag, 1024 + i) end
    if none then items[#items + 1] = { label = '  audio device settings ... (no inputs: pick an input device there)', data = 'prefs' } end
    add('MIDI  all inputs, all channels', 4096 + (63 << 5))
    for d = 0, reaper.GetNumMIDIInputs() - 1 do
      local ok, nm = reaper.GetMIDIInputName(d, '')
      if ok then add('MIDI  ' .. nm .. ', all channels', 4096 + (d << 5)) end
    end
    vim.open_picker('input ' .. col.name, items, function(it)
      if it.data == 'prefs' then reaper.Main_OnCommand(40099, 0); return end   -- Options: Audio device preferences
      edit.run('track input', function() reaper.SetMediaTrackInfo_Value(tr, 'I_RECINPUT', it.data) end)
      model.invalidate()
      vim.msg = col.name .. ' input: ' .. it.label:sub(4)
    end)
    vim.picker.inp = col.guid
    state.popup_at = anchor or { kind = 'in', guid = col.guid }
  end,
  -- + send (3 окт): fzf по трекам проекта → отправка с этого трека
  send_add = function(col)
    local items = {}
    for i = 0, reaper.CountTracks(0) - 1 do
      local t = reaper.GetTrack(0, i)
      if t ~= col.track then local _, nm = reaper.GetTrackName(t); items[#items + 1] = { label = ('%02d  %s'):format(i + 1, nm), data = t } end
    end
    if reaper.GetMasterTrack then items[#items + 1] = nil end
    vim.open_picker('send ' .. col.name .. ' to', items, function(it)
      edit.run('add send', function() reaper.CreateTrackSend(col.track, it.data) end)
      model.invalidate()
      vim.msg = col.name .. ' → ' .. it.label:gsub('^%d+%s+', '')
    end)
  end,
  send_action = function(sp)
    local tr = sp.col.track
    if sp.what == 'add' then ctx.send_add(sp.col)
    elseif sp.what == 'routing' then ctx.track_io(sp.col, 'routing')
    elseif sp.what == 'mute' then
      local v = reaper.GetTrackSendInfo_Value(tr, 0, sp.idx, 'B_MUTE')
      edit.run('send mute', function() reaper.SetTrackSendInfo_Value(tr, 0, sp.idx, 'B_MUTE', v == 1 and 0 or 1) end)
    elseif sp.what == 'del' then
      edit.run('remove send', function() reaper.RemoveTrackSend(tr, 0, sp.idx) end)
    end
    model.invalidate()
  end,
  -- items инструмента записи e (все связанные копии; без них — сам item)
  inst_group = function(e)
    local col = cur_col()
    local idx
    for i, pe in ipairs(col and col.pool or {}) do if pe == e or pe.item == e.item then idx = i end end
    local items = idx and ctx.inst_items(idx) or {}
    if #items == 0 then items = { e.item } end
    return items
  end,
  -- панель item (2 окт) правит ИНСТРУМЕНТ (3 окт): все его копии, см. edit.inst_prop
  playthru_of = function(e) return e and e.item and reaper.ValidatePtr(e.item, 'MediaItem*') and edit.playthru(e.item) or false end,
  sp_adjust = function(e, k, d)
    local it, tk = e.item, e.take
    if not (it and tk and reaper.ValidatePtr(it, 'MediaItem*')) then vim.msg = 'instrument item is gone'; return end
    local fine = ctx.mods().shift
    local items = ctx.inst_group(e)
    local function P(key, v, how, desc) edit.inst_prop(items, it, key, v, how, desc) end
    if k == 'vol' then
      local v = reaper.GetMediaItemInfo_Value(it, 'D_VOL')
      local db = v > 1e-6 and 20 * math.log(v, 10) or -60
      P('D_VOL', 10 ^ (math.max(-60, math.min(24, db + d * 0.5)) / 20), 'mul', 'sample volume')
    elseif k == 'pan' then P('take:D_PAN', math.max(-1, math.min(1, reaper.GetMediaItemTakeInfo_Value(tk, 'D_PAN') + d * 0.02)), 'add', 'sample pan')
    elseif k == 'st' then P('take:D_PITCH', reaper.GetMediaItemTakeInfo_Value(tk, 'D_PITCH') + d, 'add', 'sample transpose')
    elseif k == 'cent' then P('take:D_PITCH', reaper.GetMediaItemTakeInfo_Value(tk, 'D_PITCH') + d * 0.01, 'add', 'sample finetune')
    elseif k == 'rate' then
      local r = reaper.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
      P('take:D_PLAYRATE', math.max(0.1, math.min(10, r + d * 0.01)), 'mul', 'sample rate')
    elseif k == 'ppitch' then P('take:B_PPITCH', e.ppitch and 0 or 1, 'abs', 'sample keep pitch')
    elseif k == 'mode' then
      -- цикл алгоритмов растяжения: project → 0 → 1 … (EnumPitchShiftModes)
      local modes = { -1 }
      for m = 0, 63 do local ok, nm = reaper.EnumPitchShiftModes(m); if ok and nm and nm ~= '' then modes[#modes + 1] = m << 16 end end
      local cur = reaper.GetMediaItemTakeInfo_Value(tk, 'I_PITCHMODE')
      local k0 = 1
      for i, m in ipairs(modes) do if m == cur or (m >= 0 and cur >= 0 and (m >> 16) == (math.floor(cur) >> 16)) then k0 = i end end
      P('take:I_PITCHMODE', modes[(k0 - 1 + d) % #modes + 1], 'abs', 'sample stretch mode')
    elseif k == 'loop' then P('B_LOOPSRC', e.loop and 0 or 1, 'abs', 'sample loop')
    elseif k == 'fin' or k == 'fout' then
      local key = k == 'fin' and 'D_FADEINLEN' or 'D_FADEOUTLEN'
      P(key, math.max(0, reaper.GetMediaItemInfo_Value(it, key) + d * (fine and 0.001 or 0.005)), 'abs', 'sample fade')
    elseif k == 'bsync' then ctx.bsync_adjust(e, d)
    -- 5 окт: остальное из окна свойств item
    elseif k == 'tvol' then
      local v = reaper.GetMediaItemTakeInfo_Value(tk, 'D_VOL')
      local db = v > 1e-6 and 20 * math.log(math.abs(v), 10) or -60
      P('take:D_VOL', 10 ^ (math.max(-60, math.min(24, db + d * 0.5)) / 20), 'mul', 'take volume')
    elseif k == 'offs' then P('take:D_STARTOFFS', math.max(0, reaper.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS') + d * (fine and 0.001 or 0.01)), 'abs', 'start offset')
    elseif k == 'len' then P('D_LENGTH', math.max(0.01, reaper.GetMediaItemInfo_Value(it, 'D_LENGTH') + d * (fine and 0.001 or 0.01)), 'abs', 'length')
    elseif k == 'snap' then P('D_SNAPOFFSET', math.max(0, reaper.GetMediaItemInfo_Value(it, 'D_SNAPOFFSET') + d * (fine and 0.001 or 0.01)), 'abs', 'snap offset')
    elseif k == 'finshape' or k == 'foutshape' then
      local key = k == 'finshape' and 'C_FADEINSHAPE' or 'C_FADEOUTSHAPE'
      P(key, (math.floor(reaper.GetMediaItemInfo_Value(it, key)) + d) % 7, 'abs', 'fade shape')
    elseif k == 'chan' then P('take:I_CHANMODE', (math.floor(reaper.GetMediaItemTakeInfo_Value(tk, 'I_CHANMODE')) + d) % 5, 'abs', 'channel mode')
    elseif k == 'mute' then P('B_MUTE', reaper.GetMediaItemInfo_Value(it, 'B_MUTE') >= 0.5 and 0 or 1, 'abs', 'mute')
    elseif k == 'lock' then P('C_LOCK', reaper.GetMediaItemInfo_Value(it, 'C_LOCK') >= 0.5 and 0 or 1, 'abs', 'lock')
    elseif k == 'pthru' then
      local on = not edit.playthru(it)
      edit.set_playthru(it, items, on)
      vim.msg = 'slice playthru ' .. (on and 'on: each slice plays on to the end of the sample (the next note cuts it)' or 'off: each slice stops at the next slice')
    elseif k == 'swing' then
      local on = not edit.item_swing(it)
      edit.run('instrument swing', function() for _, x in ipairs(items) do edit.set_item_swing(x, on) end end)
      vim.msg = 'swing ' .. (on and 'on' or 'off') .. (' for %d note(s) of the instrument'):format(#items)
    elseif k == 'fx' then ctx.take_fx_focus(e)                          -- DSP показывает take FX (2 окт)
    elseif k == 'norm' then
      -- нормализация по представителю, остальным — то же отношение громкости
      local v0 = reaper.GetMediaItemInfo_Value(it, 'D_VOL')
      edit.run('normalize instrument', function()
        edit.normalize(it)
        local v1 = reaper.GetMediaItemInfo_Value(it, 'D_VOL')
        reaper.SetMediaItemInfo_Value(it, 'D_VOL', v0)
        edit.inst_prop(items, it, 'D_VOL', v1, 'mul', 'normalize')
      end)
      vim.msg = ('normalized (peak 0 dB), %d note(s) of the instrument'):format(#items)
    end
    PV.live(items)                                  -- колесо / h l — тоже слышно сразу (6 окт)
    model.invalidate()
  end,
  -- новые строки свойств (5 окт): текст и доля слайдера читаем здесь (модуль — без reaper.*)
  sp_raw = function(e, k)
    local it, tk = e.item, e.take
    if not (it and tk and reaper.ValidatePtr(it, 'MediaItem*')) then return '' end
    local SH = { [0] = 'linear', 'fast start', 'fast end', 'fast start steep', 'fast end steep', 'slow start/end', 'slow start/end steep' }
    local CH = { [0] = 'normal', 'reverse stereo', 'mono (mix)', 'mono (left)', 'mono (right)' }
    if k == 'tvol' then local v = reaper.GetMediaItemTakeInfo_Value(tk, 'D_VOL'); return v > 1e-6 and ('%+.1f dB'):format(20 * math.log(math.abs(v), 10)) or '-inf' end
    if k == 'offs' then return ('%.3f s'):format(reaper.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS')) end
    if k == 'len' then return ('%.3f s'):format(reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')) end
    if k == 'snap' then return ('%.3f s'):format(reaper.GetMediaItemInfo_Value(it, 'D_SNAPOFFSET')) end
    if k == 'finshape' then return SH[math.floor(reaper.GetMediaItemInfo_Value(it, 'C_FADEINSHAPE'))] or '?' end
    if k == 'foutshape' then return SH[math.floor(reaper.GetMediaItemInfo_Value(it, 'C_FADEOUTSHAPE'))] or '?' end
    if k == 'chan' then return CH[math.floor(reaper.GetMediaItemTakeInfo_Value(tk, 'I_CHANMODE'))] or 'channel' end
    if k == 'mute' then return reaper.GetMediaItemInfo_Value(it, 'B_MUTE') >= 0.5 and 'on' or 'off' end
    if k == 'lock' then return reaper.GetMediaItemInfo_Value(it, 'C_LOCK') >= 0.5 and 'on' or 'off' end
    if k == 'swing' then return edit.item_swing(it) and ('on - ' .. ctx.swing_label()) or 'off - straight' end
    if k == 'pthru' then return edit.playthru(it) and 'on - slices play to the end of the sample' or 'off - to the next slice' end
    return ''
  end,
  -- доля слайдера и «от центра»; nil — строка без слайдера
  sp_frac = function(e, k)
    local it, tk = e.item, e.take
    if not (it and tk and reaper.ValidatePtr(it, 'MediaItem*')) then return nil end
    local function dbf(v) local db = v > 1e-6 and 20 * math.log(math.abs(v), 10) or -60; return (math.max(-60, math.min(12, db)) + 60) / 72 end
    local len = reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
    if k == 'vol' then return dbf(reaper.GetMediaItemInfo_Value(it, 'D_VOL')) end
    if k == 'tvol' then return dbf(reaper.GetMediaItemTakeInfo_Value(tk, 'D_VOL')) end
    if k == 'pan' then return (reaper.GetMediaItemTakeInfo_Value(tk, 'D_PAN') + 1) / 2, true end
    local p = reaper.GetMediaItemTakeInfo_Value(tk, 'D_PITCH')
    if k == 'st' then return (math.floor(p + 0.5) + 24) / 48, true end
    if k == 'cent' then return ((p - math.floor(p + 0.5)) * 100 + 50) / 100, true end
    if k == 'rate' then return ctx.rate_frac(reaper.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')), true end
    if k == 'fin' then return reaper.GetMediaItemInfo_Value(it, 'D_FADEINLEN') / math.max(1e-3, len) end
    if k == 'fout' then return reaper.GetMediaItemInfo_Value(it, 'D_FADEOUTLEN') / math.max(1e-3, len) end
    if k == 'snap' then return reaper.GetMediaItemInfo_Value(it, 'D_SNAPOFFSET') / math.max(1e-3, len) end
    if k == 'offs' then
      local src = reaper.GetMediaItemTake_Source(tk)
      local sl = src and reaper.GetMediaSourceLength(src) or 0
      return sl > 0 and reaper.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS') / sl or nil
    end
    return nil
  end,
  -- протяжка слайдера: доля → значение (всем нотам инструмента, как колесо)
  sp_set_frac = function(e, k, fr)
    local it, tk = e.item, e.take
    if not (it and tk and reaper.ValidatePtr(it, 'MediaItem*')) then return end
    fr = math.max(0, math.min(1, fr))
    local items = ctx.inst_group(e)
    local function P(key, v, how, desc) edit.inst_prop(items, it, key, v, how, desc) end
    local len = reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
    if k == 'vol' or k == 'tvol' then
      local v = fr <= 0.002 and 0 or 10 ^ ((fr * 72 - 60) / 20)
      if k == 'vol' then P('D_VOL', v, 'mul', 'sample volume') else P('take:D_VOL', v, 'mul', 'take volume') end
    elseif k == 'pan' then P('take:D_PAN', fr * 2 - 1, 'add', 'sample pan')
    elseif k == 'st' then
      local p = reaper.GetMediaItemTakeInfo_Value(tk, 'D_PITCH')
      P('take:D_PITCH', math.floor(fr * 48 + 0.5) - 24 + (p - math.floor(p + 0.5)), 'add', 'sample transpose')
    elseif k == 'cent' then
      local p = reaper.GetMediaItemTakeInfo_Value(tk, 'D_PITCH')
      P('take:D_PITCH', math.floor(p + 0.5) + (math.floor(fr * 100 + 0.5) - 50) / 100, 'add', 'sample finetune')
    elseif k == 'rate' then
      -- лёгкая привязка (5 окт): ближе 1.2% дорожки к метке — ровно на неё
      local r = 2 ^ (ctx.RATE_LO + fr * (ctx.RATE_HI - ctx.RATE_LO))
      for _, m in ipairs(ctx.RATE_MARKS) do if math.abs(fr - ctx.rate_frac(m)) < 0.012 then r = m end end
      P('take:D_PLAYRATE', r, 'mul', 'sample rate')
    elseif k == 'fin' then P('D_FADEINLEN', fr * len, 'abs', 'sample fade')
    elseif k == 'fout' then P('D_FADEOUTLEN', fr * len, 'abs', 'sample fade')
    elseif k == 'snap' then P('D_SNAPOFFSET', fr * len, 'abs', 'snap offset')
    elseif k == 'offs' then
      local src = reaper.GetMediaItemTake_Source(tk)
      local sl = src and reaper.GetMediaSourceLength(src) or 0
      if sl > 0 then P('take:D_STARTOFFS', fr * sl, 'abs', 'start offset') end
    end
    PV.live(items)                                  -- звучащее превью — сразу с новым питчем / rate / громкостью (6 окт)
    model.invalidate()
  end,
  -- rate: лог-шкала ×0.2 … ×5, метки на простых отношениях (5 окт)
  RATE_LO = math.log(0.2, 2), RATE_HI = math.log(5, 2),
  RATE_MARKS = { 0.2, 0.25, 1 / 3, 0.5, 2 / 3, 0.75, 1, 1.5, 2, 3, 4, 5 },
  rate_frac = function(r) return (math.log(math.max(1e-3, r), 2) - ctx.RATE_LO) / (ctx.RATE_HI - ctx.RATE_LO) end,
  sp_marks = function(k)
    if k ~= 'rate' then return nil end
    local out = {}
    for _, m in ipairs(ctx.RATE_MARKS) do out[#out + 1] = ctx.rate_frac(m) end
    return out
  end,
  -- выпадашка выбора (5 окт): stretch, формы фейдов, каналы — список у мыши
  sp_menu = function(e, k)
    local it, tk = e.item, e.take
    if not (it and tk and reaper.ValidatePtr(it, 'MediaItem*')) then return false end
    local items = ctx.inst_group(e)
    local function P(key, v, desc) edit.inst_prop(items, it, key, v, 'abs', desc); model.invalidate() end
    local list, title = {}, k
    local KEYS = '123456789abcdefghijklmnopqrstuvwxyz'
    local function add(label, fn, on) local n = #list + 1; list[n] = { key = KEYS:sub(n, n), label = label .. (on and '  *' or ''), fn = fn } end
    if k == 'mode' then
      title = 'stretch'
      local cur = reaper.GetMediaItemTakeInfo_Value(tk, 'I_PITCHMODE')
      add('project default', function() P('take:I_PITCHMODE', -1, 'stretch mode') end, cur < 0)
      for m = 0, 63 do
        local ok, nm = reaper.EnumPitchShiftModes(m)
        if ok and nm and nm ~= '' then add(nm, function() P('take:I_PITCHMODE', m << 16, 'stretch mode') end, cur >= 0 and (math.floor(cur) >> 16) == m) end
      end
    elseif k == 'finshape' or k == 'foutshape' then
      title = k == 'finshape' and 'fade in shape' or 'fade out shape'
      local key = k == 'finshape' and 'C_FADEINSHAPE' or 'C_FADEOUTSHAPE'
      local cur = math.floor(reaper.GetMediaItemInfo_Value(it, key))
      for i, nm in ipairs({ 'linear', 'fast start', 'fast end', 'fast start steep', 'fast end steep', 'slow start/end', 'slow start/end steep' }) do
        add(nm, function() P(key, i - 1, 'fade shape') end, cur == i - 1)
      end
    elseif k == 'chan' then
      title = 'channels'
      local cur = math.floor(reaper.GetMediaItemTakeInfo_Value(tk, 'I_CHANMODE'))
      for i, nm in ipairs({ 'normal', 'reverse stereo', 'mono (mix)', 'mono (left)', 'mono (right)' }) do
        add(nm, function() P('take:I_CHANMODE', i - 1, 'channel mode') end, cur == i - 1)
      end
    else return false end
    vim.open_hydra({ title = title, items = list })
    state.popup_at = { kind = 'xy', x = gfx.mouse_x, y = gfx.mouse_y + 4 }
    return true
  end,
  sp_reset = function(e, k)
    local it, tk = e.item, e.take
    if not (it and tk and reaper.ValidatePtr(it, 'MediaItem*')) then return end
    local items = ctx.inst_group(e)
    local function P(key, v, how, desc) edit.inst_prop(items, it, key, v, how, desc) end
    if k == 'vol' then P('D_VOL', 1, 'mul', 'sample volume reset')
    elseif k == 'pan' then P('take:D_PAN', 0, 'add', 'sample pan reset')
    elseif k == 'st' or k == 'cent' then P('take:D_PITCH', 0, 'add', 'sample pitch reset')
    elseif k == 'mode' then P('take:I_PITCHMODE', -1, 'abs', 'sample stretch reset')
    elseif k == 'fin' then P('D_FADEINLEN', 0, 'abs', 'sample fade reset')
    elseif k == 'fout' then P('D_FADEOUTLEN', 0, 'abs', 'sample fade reset')
    elseif k == 'bsync' then ctx.bsync_set(e, nil)
    elseif k == 'tvol' then P('take:D_VOL', 1, 'mul', 'take volume reset')
    elseif k == 'offs' then P('take:D_STARTOFFS', 0, 'abs', 'start offset reset')
    elseif k == 'snap' then P('D_SNAPOFFSET', 0, 'abs', 'snap offset reset')
    elseif k == 'finshape' then P('C_FADEINSHAPE', 0, 'abs', 'fade shape reset')
    elseif k == 'foutshape' then P('C_FADEOUTSHAPE', 0, 'abs', 'fade shape reset')
    elseif k == 'chan' then P('take:I_CHANMODE', 0, 'abs', 'channel mode reset')
    elseif k == 'len' then return
    else ctx.sp_adjust(e, k, 1); return end
    model.invalidate()
  end,
  -- ── инструменты как объекты Vim (2 окт, jf_tracker_instkeys.lua) ─────
  -- Регистр state.inst_reg = { снимки }; cut кладёт туда вырезанное.
  inst_select = function(n) pool_select(n) end,
  inst_listen = function() local col = cur_col(); local e = col and col.pool[vim.inst]; if e then ctx.inst_preview(e, col.track) end end,
  inst_preview = function(...) return PV.inst_preview(...) end,
  -- нота с удержанием (3 окт, Cmd+нота в INSERT / слое пианино): звук сразу,
  -- длина растёт в темпе, пока клавиша держится (JS_VKeys_GetState), j / ↓
  -- добавляют шаг; отпустили — запись (edit.hold_insert). Без js_ReaScriptAPI —
  -- обычная вставка на шаг
  hold_start = function(spec)
    if state.hold then return end
    spec.lpb = state.lpb
    spec.rows = math.max(1, vim.step_auto and 1 or vim.step)
    if not reaper.JS_VKeys_GetState then
      edit.hold_insert(spec); model.invalidate()
      vim.msg = 'hold needs js_ReaScriptAPI - inserted with the step length'
      return
    end
    spec.vk = (spec.key or ''):upper():byte() or 0
    spec.t0 = reaper.time_precise()
    spec.extra = 0
    spec.row_dur = math.max(0.01, edit.row_time(spec.row + 1, state.lpb, 0) - edit.row_time(spec.row, state.lpb, 0))
    if spec.slice and spec.entry then PV.slice(spec.track, spec.entry, spec.entry.slices[spec.slice], spec.entry.slices[spec.slice + 1] or spec.entry.len)
    elseif spec.pitch then ctx.preview(spec.track, spec.pitch, spec.item, spec.row, 64) end
    state.hold = spec
    vim.msg = 'hold: release to insert' .. (spec.stretch and ' (stretched)' or '') .. ' - j / down add a step, Esc cancels'
  end,
  -- живой арпеджиатор (3 окт): первая нота открывает сессию (state.arpl), каждая
  -- следующая — в аккорд (порядок нажатия для played); кадр пишет шаги
  arp_live_key = function(spec)
    if not reaper.JS_VKeys_GetState then vim.msg = 'arp live needs js_ReaScriptAPI'; return end
    local vk = (spec.key or ''):upper():byte() or 0
    local a = state.arpl
    if not a then
      local o = vim.arp_opt or { order = 'up', oct = 1, gate = 100 }
      a = { track = spec.track, lane_idx = spec.lane_idx, item = spec.item, vel = spec.vel, row0 = spec.row,
            step = math.max(1, vim.step or 1), keys = {}, done = -1, t0 = reaper.time_precise(), last = reaper.time_precise(),
            order = o.order or 'up', oct = o.oct or 1, entry = spec.entry,   -- entry — нарезанный сэмпл: арп из слайсов (4 окт)
            row_dur = math.max(0.01, edit.row_time(spec.row + 1, state.lpb, 0) - edit.row_time(spec.row, state.lpb, 0)) }
      state.arpl = a
    end
    for _, k in ipairs(a.keys) do if k.vk == vk then return end end
    a.keys[#a.keys + 1] = { vk = vk, pitch = spec.pitch }
    a.last = reaper.time_precise()
    if a.entry and spec.slice then
      local e = a.entry
      ctx.preview_slice(spec.track, e, e.slices[spec.slice], (not e.playthru and e.slices[spec.slice + 1]) or e.len)
    else ctx.preview(spec.track, spec.pitch, spec.item, spec.row, 1) end
  end,
  preview_src_pos = function() return PV.src_position() end,
  inst_listen_toggle = function() state.poolprev = not state.poolprev; vim.msg = 'listen on select: ' .. (state.poolprev and 'on' or 'off') end,
  inst_track = function(d) vim.key((d < 0 and 'H' or 'L'):byte()) end,
  inst_items = function(i)
    local items = {}
    for it, k in pairs((snap and snap.inst_of) or {}) do if k == i then items[#items + 1] = it end end
    return items
  end,
  inst_yank = function(i0, i1, quiet)
    local col = cur_col(); local pool = col and col.pool or {}
    local reg = {}
    for i = i0, i1 do
      local e = pool[i]
      local sn = e and e.item and reaper.ValidatePtr(e.item, 'MediaItem*') and edit.inst_snapshot(e.item)
      if sn then reg[#reg + 1] = sn end
    end
    if #reg == 0 then vim.msg = 'nothing to yank'; return end
    state.inst_reg = reg
    if not quiet then vim.msg = ('yank %d instrument(s): %s - p / P puts a copy into the track library'):format(#reg, reg[1].name) end
  end,
  inst_cut = function(i0, i1)
    local col = cur_col(); local pool = col and col.pool or {}
    ctx.inst_yank(i0, i1, true)
    local items = {}
    for i = i0, i1 do for _, it in ipairs(ctx.inst_items(i)) do items[#items + 1] = it end end
    if #items == 0 then vim.msg = 'no instrument here'; return end
    local first = pool[i0]
    local n = edit.inst_delete(items)
    vim.msg = ('cut %d instrument(s) (%s): %d item(s) - events and library; p puts it back, u undo'):format(i1 - i0 + 1, first and first.name or '?', n)
    model.invalidate()
  end,
  inst_put = function(before)
    local reg = state.inst_reg
    local col = cur_col()
    if not reg or #reg == 0 then vim.msg = 'instrument register empty (yy / dd)'; return end
    if not col then vim.msg = 'no track'; return end
    -- имя занято (оригинал на месте) — новое «имя 2», иначе пул склеит копию с ним
    local names, used = {}, {}
    for _, e in ipairs(col.pool or {}) do used[e.name] = true end
    for k, sn in ipairs(reg) do
      local nm = sn.name
      if used[nm] then nm = alias.free_name(col.pool or {}, nm); while used[nm] do nm = alias.free_name({ { name = nm } }, nm) end end
      used[nm] = true
      names[k] = nm
    end
    local items = edit.inst_put(col.track, reg, names)
    if items[1] then reselect_item = items[1] end
    vim.msg = ('put %d instrument(s) into the %s library: %s'):format(#items, col.name, table.concat(names, ', '))
  end,
  inst_find = function()
    local col = cur_col(); local pool = col and col.pool or {}
    local items = {}
    for i, e in ipairs(pool) do
      local nm = (e.depth or 0) > 0 and e.parent
        and (((e.slice_k and e.slice_k > 0) and ('s' .. e.slice_k) or 'cut') .. ' of ' .. e.parent.name)
        or e.name
      items[#items + 1] = { label = ('%02d %s  [%s]'):format(i, nm, e.home or ''), data = i }
    end
    state.popup_at = { kind = 'inst' }                -- окно поиска — у панели инструментов
    vim.open_picker('find instrument', items, function(it) ctx.set_focus('inst'); pool_select(it.data) end)
  end,
  -- клик по модулю переносит в него фокус (по прямоугольникам модулей)
  focus_at = function(x, y)
    local function inr(r) return r and x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4] end
    local f
    if state.pm_big then f = 'browser' end
    if state.ss_big then f = 'matrix' end
    if f then
    elseif inr(L.inst_rect) then f = 'inst'
    elseif inr(L.slices_rect) then f = 'slices'
    elseif state.side and x >= (L.side_x or L.win_w) and y > (L.side_y0 or 0) + (L.inst_side_h or 0) and y < gfx.h - L.status_h then f = 'browser'
    elseif inr(L.notes_rect) then f = 'notes'
    elseif inr(L.ctrl_area) then f = 'ctrl'
    elseif inr(L.fxb_rect) then f = 'fxb'
    elseif inr(L.dsp_rect) then f = 'dsp'
    elseif inr(L.top_rect) then f = 'top'
    elseif not state.mx_hidden and x < L.matrix_w and y >= L.header_y and y < L.body_y + L.body_h then f = 'matrix'
    elseif x >= L.matrix_w and x < L.win_w and y >= L.header_y and y < L.body_y + L.body_h then f = 'tracker' end
    if f and f ~= state.focus then ctx.set_focus(f) end
  end,
  -- окно Options: список строит здесь (знает state / vim); модуль — только показ и клавиши.
  -- Тот же список — гидра \ o (4 окт): быстрые переключатели без окна
  option_items = function()
    local function flag(k, label, desc) return { key = k, label = label, kind = 'toggle', desc = desc, get = function() return state[k] end, set = function(v) state[k] = v end } end
    local items = {
      -- то, что есть ячейками главного модуля (follow, lock, fixed, step, LPB, fx, wave, x-fade, meters, hints, caps, bitmap), здесь не дублируется (3 окт);
      -- сайдбар-браузер — тоже: его сворачивает кнопка > у края трекера (и :side)
      { sep = true, title = 'theme' },
      { key = 'theme', label = 'theme', kind = 'cycle', values = draw.themes.LIST, desc = 'palette; reaper = colours of the REAPER theme, mono = grey but the cursor; my themes - from Data/jf_tracker_themes', get = function() return state.theme or 'reaper' end, set = function(v) ctx.apply_theme(v) end },
      { label = 'make a theme from the current colours', kind = 'action', value = 'template', desc = 'writes Data/jf_tracker_themes/my-theme.txt: twelve colours as key = #rrggbb - edit them in any text editor', fn = function() ctx.theme_template() end },
      { label = 'reload my themes', kind = 'action', value = 'reload', desc = 'read Data/jf_tracker_themes again; a changed theme is applied at once', fn = function() local n = ctx.load_user_themes(); ctx.apply_theme(state.theme); vim.msg = ('my themes: %d'):format(n); ctx.options() end },
      { label = 'open the themes folder', kind = 'action', value = 'folder', desc = 'the folder with your theme files', fn = function() local d = ctx.theme_dir(); reaper.RecursiveCreateDirectory(d, 0); if reaper.CF_ShellExecute then reaper.CF_ShellExecute(d) else os.execute('open "' .. d .. '"') end end },
      { sep = true, title = 'look' },
      { key = 'ttf', label = 'font', kind = 'cycle', values = { 'off', 'bigblue', 'iosevka' }, desc = 'off - the REAPER bitmap; bigblue - BigBlueTerm, pixel DOS font; iosevka - Iosevka Term, narrow vector font with the most symbols (font scale = their size)', get = function() return state.ttf or 'off' end, set = function(v) state.ttf = v; draw.set_font(state); ctx.relayout() end },
      { key = 'fontscale', label = 'font scale', kind = 'cycle', values = { 1, 1.5, 2, 3 }, desc = 'pixel size of the bitmap font (x4 only in PT-mode)', get = function() local f = tonumber(state.fontscale) or 2; return f == 1.5 and 1.5 or math.floor(f) end, set = function(v) ctx.set_scale(v) end },
      { key = 'fps', label = 'frame rate', kind = 'cycle', values = { 'max', 30, 25, 24 }, desc = 'redraws per second; max = every REAPER tick (~33, no higher for scripts)', get = function() return state.fps or 'max' end, set = function(v) state.fps = v end },
      { key = 'curline', label = 'cursor line', kind = 'cycle', values = { 'top', 'bottom', 'off' }, desc = 'cursor lines (amber cursor, green REAPER cursor): top / bottom edge / none', get = function() return state.curline or 'top' end, set = function(v) state.curline = v end },
      flag('clipsview', 'session', 'the tracker body shows the session: scenes (slots) x tracks, clips with waves and names; headers, inputs and arms stay live; zz in the tracker toggles it'),
      flag('ssbsync', 'session beatsync', 'an audio file dropped on a session cell gets beatsync: stretched to the nearest power of two of beats at the tempo of its slot'),
      { key = 'ssbars', label = 'session bars', kind = 'num', min = 1, max = 64, step = 1, fmt = '%d', desc = 'length of the =SESSION zone the clips loop in (new zone only - delete the region to rebuild); clips of 1 / 2 / 4 / 8 bars loop seamlessly in 8', get = function() return state.ssbars or 8 end, set = function(v) state.ssbars = math.floor(v) end },
      { key = 'modgap', label = 'module gap', kind = 'num', min = 0, max = 20, step = 1, fmt = '%d px', desc = 'space between modules (experiment): 0..20 px; wider than 2 px - empty background instead of a line', get = function() return tonumber(state.modgap) or 2 end, set = function(v) state.modgap = v; reaper.SetExtState(EXT, 'modgap', tostring(v), true) end },
      { key = 'curlead', label = 'cursor lead', kind = 'num', min = 0, max = 60, step = 1, fmt = '%d ms', desc = 'draw the playing cursor ahead by this; raise it if it trails the sound', get = function() return state.curlead or 15 end, set = function(v) state.curlead = v end },
      { key = 'tlruler', label = 'timeline ruler', kind = 'cycle', values = { 'off', 'beats', 'time', 'both' }, desc = 'REAPER ruler left of the row numbers: bar.beat, time or both', get = function() return state.tlruler or 'off' end, set = function(v) state.tlruler = v end },
      { sep = true, title = 'layout' },
      flag('top', 'top panel', 'control / item / modulate / midi'),
      { key = 'toppos', label = 'top panel position', kind = 'cycle', values = { 'top', 'mid', 'bottom' }, desc = 'tabs rec / item / modulate: above the tracker / above DSP / below DSP', get = function() return state.toppos or 'mid' end, set = function(v) state.toppos = v end },
      { key = 'ctrlpos', label = 'main module position', kind = 'cycle', values = { 'top', 'mid', 'bottom' }, desc = 'experimental: help / options / transport - top left, above DSP, in DSP', get = function() return state.ctrlpos or 'top' end, set = function(v) state.ctrlpos = v end },
      { key = 'envfmt', label = 'values', kind = 'cycle', values = { 'midi', 'hex' }, desc = 'envelope points and CC / PC lanes: midi 0..127 typed in decimal (ends by itself when one more digit cannot fit; 005 = 5, Enter ends early) or hex 00..FF', get = function() return state.envfmt or 'midi' end, set = function(v) state.envfmt = v end },
      { key = 'statpos', label = 'status bar', kind = 'cycle', values = { 'bottom', 'tracker', 'keyboard' }, desc = 'status line at the window bottom, inside the tracker module, or in the keyboard strip (m shows it)', get = function() return state.statpos or 'bottom' end, set = function(v) state.statpos = v end },
      { key = 'focusclick', label = 'focus by mouse', kind = 'cycle', values = { 'option', 'click' }, desc = 'option: a plain click works in a module but keeps the keyboard focus, Option+click moves it; click: every click moves the focus', get = function() return state.focusclick or 'option' end, set = function(v) state.focusclick = v end },
      flag('recdelprompt', 'ask before deleting a take', 'Esc while recording: ask before the take is deleted (off - delete at once)'),
      flag('stretchmarks', 'stretch markers', 'amber ticks of the item stretch markers on the wave'),
      flag('bigbpm', 'big time and BPM', 'the position and the BPM two rows tall in the transport bar under the tracker'),
      -- big status отключён (5 окт): места не хватает транспорту
      -- flag('bigstatus', 'big status', 'the mode big at the left of the transport bar (INSERT, KEYS, MATRIX ...); the transport buttons, keyboard and transport follow, the small info goes under them'),
      flag('envpoints', 'envelope points', 'envelope points as small circles in the envelope columns and the item editor, as REAPER draws them'),
      flag('pmgrid', 'pm cards (jf_pm)', 'experimental: the pm tab of the browser as a grid of project cards with thumbnails (image / DAW mark / preview wave / mini arrangement); b or :pm big - over the whole window'),
      { key = 'pmshape', label = 'pm card shape', kind = 'cycle', values = { 'wide', 'compact', 'square' }, desc = 'wide - thumbnail left, name, preview wave, bpm / date, status; compact - three rows, the wave inside the thumbnail; square - thumbnail on top (w in the pm grid)', get = function() return ctx.pm_mod().shape end, set = function(v) ctx.pm_mod().shape = v; ctx.PM.invalidate(); reaper.SetExtState(EXT, 'pmshape', v, true) end },
      { key = 'pmthumb', label = 'pm card thumbnail', kind = 'toggle', desc = 'the preview picture on the cards (off - text only, more cards)', get = function() return state.pmthumb ~= false end, set = function(v) state.pmthumb = v; if ctx.PM then ctx.PM.show_thumb = v end end },
      { key = 'pmicon', label = 'pm card daw mark', kind = 'toggle', desc = 'the two-letter DAW mark (Ab, FL, Lg ...) right of the name', get = function() return state.pmicon ~= false end, set = function(v) state.pmicon = v; if ctx.PM then ctx.PM.show_icon = v end end },
      { key = 'dsp_big', label = 'router', kind = 'toggle', desc = 'the fx chain of the cursor track as a routing graph in the DSP FX panel (zr; zR - big router)', get = function() return state.dsp_big end, set = function(v) if (v and true or false) ~= (state.dsp_big and true or false) then ctx.dsp_big() end end },
      flag('measure', 'measure', 'ruler on the mouse: a click sets the start, the next click the end - size in px, chars and rows; with debug on every measure goes to the debug log and ExtState jf_tracker/measure (what is under both points). s - PNG of the measured box (or the whole window) next to the system screenshots, named like them + _jftracker; the path and the report go to the debug log and ExtState jf_tracker/shot. Right click / Esc - off'),
      { key = 'title', label = 'title bar', kind = 'toggle', desc = 'the title bar of the floating (fullscreen, F11) window; off - no frame, no title (js_ReaScriptAPI)', get = function() return not state.notitle end, set = function(v) state.notitle = not v; toggle_dock(true) end },
      flag('ptabs', 'project tabs', 'a thin row of the open REAPER project tabs on top of the main module; click - switch, * - unsaved changes'),
      flag('mixer', 'mixer', 'the track headers unfold into a mixer: a fader one lane wide (dragged vertically), pan / width under it, the fx with their TCP parameters right of it (one-lane track - under it); ø - phase invert'),
      flag('hdrinfo', 'header info', 'track headers show the instruments of the track (lib), its inserts (click - DSP, dblclick - window) and its sends (click - routing window)'),
      flag('whichkey', 'whichkey', 'after a prefix key (d y c g z r q @, z in DSP) a popup at the cursor lists what can follow'),
      flag('browserleft', 'browser left', 'lib + browser in the left column above the matrix (no sidebar on the right); the fx list becomes the fx tab of the browser'),
      flag('eqgraph', 'reaeq graph only', 'ReaEQ in the DSP panel: the curve only, drag the band points (P in its header - parameters only)'),
      flag('dsptrack', 'dsp track block', 'the track block on the left of the DSP panel: R I M S, volume, pan, input, output (off - the fx chain only)'),
      flag('synchdr', 'sync track header size', 'the track column follows the REAPER track height, both ways: low track - folded, middle - compact, tall - full; folding a column (za) sets the REAPER height'),
      flag('aipoints', 'automation item points', 'the points of automation items on the envelope lanes of the tracker (every loop pass), with their hex values'),
      flag('midilanes', 'midi lanes', 'columns of the MIDI items of a track: CC by number, program change, articulations (text / notation events), SysEx; hex per row edits CC / PC'),
      flag('oneclick', 'one click focus', 'a click on a note / slice shows its sample in the item tab, on an automation item - opens it in the modulation tab'),
      flag('autofocus', 'autofocus', 'the keyboard cursor on a note / slice / automation item shows its module by itself'),
      flag('aifill', 'automation item fill', 'a light fill inside automation items in the envelope columns; off - transparent with the frame, as REAPER draws them'),
      flag('tintmute', 'tint channels on solo / mute', 'muted channels are dim; with a solo on, every channel but the soloed ones is dim (as in other trackers)'),
      { key = 'tpstyle', label = 'transport buttons', kind = 'cycle', values = { 'min', 'big', 'text' }, desc = 'min - only [rec] and [loop] (Space plays, Opt+R records); big - big << > || O >> loop; text - two rows of small word buttons, rec red', get = function() return state.tpstyle or 'min' end, set = function(v) state.tpstyle = v end },
      { key = 'zoommods', label = 'zoom with', kind = 'cycle', values = { 'cmd', 'split' }, desc = 'tracker and matrix the same: cmd - Cmd + multiscroll zooms both ways (up/down - rows, left/right - width); split - as in REAPER: Cmd + wheel zooms horizontally, Option + wheel vertically. Without modifiers the wheel scrolls rows, the horizontal wheel scrolls columns', get = function() return state.zoommods or 'cmd' end, set = function(v) state.zoommods = v end },
      { key = 'transpos', label = 'transport bar', kind = 'cycle', values = { 'tracker', 'top', 'bottom' }, desc = 'tracker - under the tracker; top - the whole width over the top panel (sample module); bottom - under the DSP modules, over the status bar', get = function() return state.transpos or 'tracker' end, set = function(v) state.transpos = v; ctx.relayout() end },
      { key = 'xfademode', label = 'x-fade by', kind = 'cycle', values = { 'vol', 'fades' }, desc = 'vol - crossfades are volume ramps of the take envelopes, shown as values in the vol column (type vol on any row of a sample to add a point); fades - REAPER item fades', get = function() return state.xfademode or 'vol' end, set = function(v) state.xfademode = v end },
      flag('dsp', 'dsp panel', 'track fx at the bottom'),
      flag('dspmeters', 'dsp meters', 'in / out meters and gain comp (c) at the edges of the DSP panel'),
      flag('gridtab', 'grid tab (monome)', 'tab for the monome grid / arc (jf_grid daemon)'),
      flag('hints', 'module hints', 'a line of key hints under every module'),
      { sep = true, title = 'track' },
      { key = 'hdrfill', label = 'track header colour', kind = 'cycle', values = { 'off', 'line', 'header', 'full' }, desc = 'track colour in the header: none / strip under the name / name row / all', get = function() return state.hdrfill or 'line' end, set = function(v) state.hdrfill = v end },
      { key = 'hdrin', label = 'input row', kind = 'toggle', desc = 'input row in the track header: the input list by click (smart input: DSP module)', get = function() return state.hdrin end, set = function(v) state.hdrin = v end },
      flag('captions', 'column captions', 'a row under the track header naming the fields (nt vl dl fx)'),
      flag('meters', 'meters', 'peak meters over the track columns'),
      { key = 'meterstyle', label = 'meter style', kind = 'cycle', values = { 'blocks', 'pt' }, desc = 'blocks: pseudographic L R cells; pt: ProTracker bars, see-through (PT-mode uses them)', get = function() return state.meterstyle or 'blocks' end, set = function(v) state.meterstyle = v end },
      { key = 'scopes', label = 'track scopes', kind = 'toggle', desc = 'track oscilloscopes + master analyzer (a small JSFX on every track)', get = function() return state.scopes end, set = function(v) ctx.toggle_scopes(v) end },
      { sep = true, title = 'notes and items' },
      flag('textonly', 'text only', 'cells show only the text: no wave behind the notes, no item fill, no item frame'),
      { key = 'slicespos', label = 'slices', kind = 'cycle', values = { 'module', 'split' }, desc = 'slice list: its own module in the top panel, or the lower half of the lib when the item is sliced', get = function() return state.slicespos or 'module' end, set = function(v) state.slicespos = v end },
      { key = 'propspos', label = 'sample settings', kind = 'cycle', values = { 'left', 'right' }, desc = 'the sample properties in the item tab: left or right of the wave', get = function() return state.propspos or 'right' end, set = function(v) state.propspos = v end },
      { key = 'wavemode', label = 'wave', kind = 'cycle', values = { 'column', 'note', 'back', 'off' }, desc = 'wave: own column / in the note field / item background / none', get = function() return state.wavemode or 'column' end, set = function(v) ctx.wave_mode(v) end },
      { key = 'wave_os', label = 'wave detail', kind = 'cycle', values = { 1, 2, 4 }, desc = 'peaks per pixel in waves: higher = finer, slower', get = function() return state.wave_os or 1 end, set = function(v) state.wave_os = v; model.OVERSAMPLE = v; model.clear_peaks() end },
      { key = 'itemframe', label = 'item frame', kind = 'cycle', values = { 'item', 'wave', 'off' }, desc = 'border around the whole item / only the wave column / none', get = function() return state.itemframe or 'item' end, set = function(v) state.itemframe = v end },
      flag('itemcol', 'item colours', 'item fill and border in the item / track colour; off: neutral grey'),
      { key = 'itemalpha', label = 'item fill opacity', kind = 'num', min = 0, max = 60, step = 1, fmt = '%d %%', desc = 'how strongly the item colour fills its cells (0 = border only)', get = function() return state.itemalpha or 5 end, set = function(v) state.itemalpha = v end },
      flag('itemnames', 'item names', 'item name on the second row under the note (number on the note row)'),
      { sep = true, title = 'sound and samples' },
      flag('steplisten', 'step listen', 'transport stopped: moving the cursor plays the row under it (all tracks, with fx)'),
      flag('preview', 'preview on insert', 'audition the note when inserting'),
      flag('poolprev', 'preview on select', 'audition the instrument when selected'),
      { key = 'poolsort', label = 'instrument order', kind = 'cycle', values = { 'track', 'name', 'len', 'mark' }, desc = 'lib order: by track / name / length / marks (or click the column heads)', get = function() return state.poolsort or 'track' end, set = function(v) state.poolsort = v end },
      flag('autosync', 'auto sync aliases', 'edits in a pattern copy to its aliases (same region name)'),
      flag('keepsamples', 'keep deleted samples', 'deleting the last item of a file keeps the sample in the lib (=LIB)'),
      flag('copymedia', 'copy files to project', 'browser files are copied into the project media folder'),
      flag('endstop', 'stop at =END', 'playback started before =END stops there (recording never stops)'),
    }
    -- text only (4 окт) перекрывает эти опции — серые, клик по ним выключает text only
    for _, it in ipairs(items) do
      if it.key == 'wavemode' or it.key == 'wave_os' or it.key == 'itemframe' or it.key == 'itemalpha' then
        it.masked = function() return state.textonly end
        it.unmask = function() state.textonly = false; vim.msg = 'text only off' end
      end
    end
    return items
  end,
  options = function()
    local items = {}
    for _, it in ipairs(ctx.option_items()) do if state.dev or (it.key ~= 'gridtab' and it.key ~= 'pmgrid' and it.key ~= 'pmshape' and it.key ~= 'pmthumb' and it.key ~= 'pmicon') then items[#items + 1] = it end end
    -- hotkeys (5 окт): все клавиши со страниц ? — клавиша, модуль, описание;
    -- / ищет по клавише, описанию и модулю
    items[#items + 1] = { sep = true, title = 'hotkeys', group = 'hotkeys' }
    for _, pg in ipairs(KH.ORDER) do
      local page = KH.PAGES[pg]
      if page and pg ~= 'intro' and (state.dev or (pg ~= 'grid' and pg ~= 'orca' and pg ~= 'pm')) then
        local mod = (page.title or pg):gsub('%s*%-.*$', '')
        for _, en in ipairs(page.e or {}) do
          if en.k and en.d then items[#items + 1] = { label = en.k, kind = 'action', value = mod, key = mod, desc = en.d, hk = true } end
        end
      end
    end
    -- профили (5 окт): сохранить / загрузить / удалить набор опций
    items[#items + 1] = { sep = true, title = 'profiles', group = 'options' }
    items[#items + 1] = { label = 'save the options as a profile', kind = 'action', value = ':optsave', desc = 'all options into Data/jf_tracker_profiles/<name>.txt', fn = function()
      OPT.close(); vim.cmd_from = vim.mode == 'insert' and 'insert' or 'normal'; vim.mode = 'cmd'; vim.cmdline = 'optsave ' end }
    for _, name in ipairs(ctx.list_files(ctx.profile_dir(), 'txt')) do
      items[#items + 1] = { label = name, kind = 'action', value = 'load', desc = 'load the profile ' .. name .. ' (delete: :optdel ' .. name .. ')', fn = function() ctx.opt_load(name) end }
    end
    OPT.open(items, state.opt_tab)
  end,
  -- \ o (4 окт): опции гидрой — буква у каждой (первая свободная буква подписи,
  -- тема — t); переключатель — сразу, выбор — список значений, число — + / -
  options_hydra = function()
    local used, items = { ['?'] = true }, {}
    local FIXED = { theme = 't', wavemode = 'w', curline = 'c', hdrfill = 'h', tlruler = 'r', statpos = 's', fps = 'f',
                    toppos = 'p', ctrlpos = 'm', itemframe = 'i', itemalpha = 'a', curlead = 'l',
                    wave_os = 'd', fontscale = 'b' }
    -- мнемоника (4 окт: theme сидел на 2 — t забирал top panel раньше по
    -- порядку): закреплённые буквы занимаются заранее, остальные — после
    local reserved = {}
    for _, it in ipairs(ctx.option_items()) do if it.key and FIXED[it.key] then reserved[FIXED[it.key]] = it.key end end
    local function pick_key(it)
      local k = FIXED[it.key]
      if k and not used[k] then return k end
      for ch in (it.label or ''):lower():gmatch('%a') do if not used[ch] and not reserved[ch] then return ch end end
      for ch in ('abcdefghijklmnopqrstuvwxyz0123456789'):gmatch('.') do if not used[ch] and not reserved[ch] then return ch end end
    end
    for _, it in ipairs(ctx.option_items()) do
      if not it.sep and it.get then
        local k = pick_key(it)
        if k then
          used[k] = true
          local cur = it.get()
          if it.kind == 'toggle' then
            items[#items + 1] = { key = k, label = it.label .. ': ' .. (cur and 'on' or 'off'), fn = function() it.set(not it.get()); vim.msg = it.label .. ': ' .. (it.get() and 'on' or 'off') end }
          elseif it.kind == 'cycle' then
            items[#items + 1] = { key = k, label = it.label .. ': ' .. tostring(cur), sub = function()
              local vs, keysq = {}, '1234567890abcdefghijklmnopqrstuvwxyz'
              for n, v in ipairs(it.values) do
                vs[#vs + 1] = { key = keysq:sub(n, n), label = tostring(v) .. (v == it.get() and '  *' or ''), fn = function() it.set(v); vim.msg = it.label .. ': ' .. tostring(v) end }
              end
              return { title = it.label, items = vs }
            end }
          elseif it.kind == 'num' then
            items[#items + 1] = { key = k, label = it.label .. ': ' .. (it.fmt and it.fmt:format(cur) or tostring(cur)), sub = function()
              local function step(d) local v = math.max(it.min or -math.huge, math.min(it.max or math.huge, (it.get() or 0) + d * (it.step or 1))); it.set(v); vim.msg = it.label .. ': ' .. (it.fmt and it.fmt:format(v) or tostring(v)) end
              return { title = it.label, items = { { key = '+', label = 'more', fn = function() step(1) end }, { key = '-', label = 'less', fn = function() step(-1) end },
                { key = '=', label = 'more x10', fn = function() step(10) end }, { key = '_', label = 'less x10', fn = function() step(-10) end } } }
            end }
          end
        end
      end
    end
    items[#items + 1] = { key = 'O', label = 'options window …', fn = function() ctx.options() end }
    return { title = 'options', items = items }
  end,
  -- about (3 окт): ячейка в главном модуле, :about; логотип каждый раз другой
  about = function(name)
    OPT.open_about(function()
      LOGO.last = LOGO.pick(LOGO.last)                       -- не тот же, что в прошлый раз
      -- :about имя — конкретный логотип (часть имени: marquee, rubble …)
      if name and name ~= '' then for i, lg in ipairs(LOGO.LOGOS) do if lg.name:find(name, 1, true) then LOGO.last = i; break end end end
      return { logo = LOGO.LOGOS[LOGO.last], text = VER.lines() }
    end)
  end,
  -- ── лупы в регионе (F1): > item до конца региона, N> период N шагов, < регион до конца item
  loop = function(what, n)
    local heads
    if vim.mode == 'visual' or vim.mode == 'vline' then
      local f0, f1, r0, r1 = vim.visual_range(); heads = vim.heads_in(f0, f1, r0, r1)
    else
      heads = vim.covering(vim.cur.fi, vim.cur.row)
      if #heads == 0 then heads = vim.heads_in(vim.cur.fi, vim.cur.fi, vim.cur.row, vim.cur.row) end
    end
    if what == 'off' then
      if #heads == 0 then vim.msg = 'no event under cursor'; return end
      edit.set_fx(heads, state.lpb, 'L', 0); vim.msg = 'loop off'; return
    end
    if what == 'region' then
      local rg = alias.region_at(regions, edit.row_time(vim.cur.row, state.lpb, 0))
      local h = heads[1]
      if not rg then vim.msg = 'cursor is not inside a region'; return end
      if not h or not h.item then vim.msg = 'no event under cursor'; return end
      local t1 = reaper.GetMediaItemInfo_Value(h.item, 'D_POSITION') + reaper.GetMediaItemInfo_Value(h.item, 'D_LENGTH')
      local r = math.ceil(model.row_of_time(t1, state.lpb) - 1e-6)     -- вверх до границы строки
      t1 = edit.row_time(r, state.lpb, 0)
      if t1 <= rg.pos + 1e-6 then vim.msg = 'item ends before the region starts'; return end
      ctx.set_region_len(rg, t1)
      return
    end
    if #heads == 0 then vim.msg = 'no event under cursor'; return end
    -- item → конец СВОЕГО региона (по началу item), группами по регионам
    local groups, order = {}, {}
    for _, h in ipairs(heads) do
      if h.item then
        local rg = alias.region_at(regions, reaper.GetMediaItemInfo_Value(h.item, 'D_POSITION'))
        if rg then
          if not groups[rg] then groups[rg] = {}; order[#order + 1] = rg end
          table.insert(groups[rg], h)
        end
      end
    end
    if #order == 0 then vim.msg = 'event is not inside a region'; return end
    local total, warn = 0, nil
    for _, rg in ipairs(order) do
      local k, w = edit.loop_to_region(groups[rg], state.lpb, rg, n)
      total = total + (k or 0); warn = warn or w
    end
    vim.msg = ('loop %s -> region end: %d item(s)%s'):format(n and (n .. ' rows') or 'item', total, warn and (' (' .. warn .. ')') or '')
  end,
  -- ── Garden (F2) ─────────────────────────────────────────────────────
  garden_field = function() return garden.f end,
  orca_targets = function(f) return ORCA.targets(f) end,
  orca_doc = function(ch) return ORCA.DOC[ch] or ORCA.DOC[(ch or ''):upper()] end,
  orca_set = function(x, y, ch) if garden.f then ORCA.set(garden.f, x, y, ch); garden_save() end end,
  -- курсор главного модуля: ближайшая ячейка в направлении (геометрия ячеек)
  ctrl_move = function(sel, dx, dy)
    local rects = draw.ctrl_rect or {}
    local r0 = rects[sel]
    if not r0 then return 'bpm' end
    local cx, cy = r0[1] + r0[3] / 2, r0[2] + r0[4] / 2
    local best, bd
    for name, r in pairs(rects) do
      if name ~= sel then
        local x, y = r[1] + r[3] / 2, r[2] + r[4] / 2
        local ok = (dx > 0 and x > cx + 1) or (dx < 0 and x < cx - 1) or (dy > 0 and y > cy + 1) or (dy < 0 and y < cy - 1)
        if ok then
          local d = dx ~= 0 and (math.abs(x - cx) + 4 * math.abs(y - cy)) or (math.abs(y - cy) + 4 * math.abs(x - cx))
          if not bd or d < bd then best, bd = name, d end
        end
      end
    end
    return best or sel
  end,
  -- ── действия REAPER (3 окт): весь список Main (kbd_enumerateActions —
  -- нативно, со скриптами и custom actions), fzf; недавние сверху (ExtState
  -- actrecent: именованные id скриптов переживают перезапуск). Отдельно от
  -- команд трекера: \ a или :!текст
  reaper_actions = function(query)
    local now = reaper.time_precise()
    if not act_cache.list or now - act_cache.t > 120 then
      local list = {}
      local sec = reaper.SectionFromUniqueID and reaper.SectionFromUniqueID(0)
      local i = 0
      while i < 100000 do
        local id, name
        if reaper.kbd_enumerateActions and sec then id, name = reaper.kbd_enumerateActions(sec, i)
        elseif reaper.CF_EnumerateActions then id, name = reaper.CF_EnumerateActions(0, i, '') end
        if not id or id <= 0 then break end
        if name and name ~= '' then list[#list + 1] = { label = name, data = id } end
        i = i + 1
      end
      table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
      act_cache.list, act_cache.t = list, now
    end
    -- недавние — сверху
    local items, seen = {}, {}
    for key in (reaper.GetExtState(EXT, 'actrecent') or ''):gmatch('[^,]+') do
      local id = tonumber(key) or reaper.NamedCommandLookup(key)
      if id and id > 0 and not seen[id] then
        seen[id] = true
        local nm = reaper.kbd_getTextFromCmd and reaper.kbd_getTextFromCmd(id, 0) or ''
        if nm and nm ~= '' then items[#items + 1] = { label = '* ' .. nm, data = id } end
      end
    end
    for _, it in ipairs(act_cache.list) do if not seen[it.data] then items[#items + 1] = it end end
    vim.open_picker(('REAPER actions (%d)'):format(#act_cache.list), items, function(it)
      local id = it.data
      reaper.Main_OnCommand(id, 0)
      -- в недавние: скрипты — по имени (их числовой id меняется между запусками)
      local key = reaper.ReverseNamedCommandLookup and reaper.ReverseNamedCommandLookup(id)
      key = (key and key ~= '') and ('_' .. key) or tostring(id)
      local rec = { key }
      for k in (reaper.GetExtState(EXT, 'actrecent') or ''):gmatch('[^,]+') do if k ~= key and #rec < 12 then rec[#rec + 1] = k end end
      reaper.SetExtState(EXT, 'actrecent', table.concat(rec, ','), true)
      model.invalidate()
      vim.msg = 'REAPER: ' .. it.label:gsub('^%* ', '')
    end, query)
  end,
  -- бросок на клетку Orca (3 окт): готовый оператор с аргументами — инструмент
  -- ($ слайс 1 нарезанного / : нота C4 целого), регион (; слот). Банг — свой.
  orca_drop = function(kind, v, ox, oy)
    local f = garden.f
    if not f then return end
    local snip
    if kind == 'inst' then
      local col = cur_col()
      local e = col and (col.pool or {})[v]
      if not e then vim.msg = 'orca: no instrument ' .. tostring(v); return end
      if v > 35 then vim.msg = ('orca: instrument %d does not fit one base-36 digit (1..z = 1..35)'):format(v); return end
      local t = 0
      for i, c in ipairs(snap.cols) do if c.name == e.home then t = i; break end end
      if t == 0 then for i, c in ipairs(snap.cols) do if c == col then t = i end end end
      if t > 35 then t = 0 end
      local sliced = e.slices or (e.parent and e.parent.slices)
      snip = (sliced and '$' or ':') .. ORCA.chr(t) .. ORCA.chr(v) .. (sliced and '1' or '4C')
      vim.msg = ('orca: %s - %s %02d %s on track %s; put a bang next to it (e.g. D4)'):format(snip, sliced and 'slice 1 of' or 'C4 of', v, e.name, t == 0 and 'cursor' or snap.cols[t].name)
    elseif kind == 'region' then
      if v > 36 * 36 - 1 then return end
      snip = ';' .. ORCA.chr(math.floor(v / 36)) .. ORCA.chr(v % 36)
      vim.msg = ('orca: %s - queues slot %d (%s) when banged'):format(snip, v, seq[v] and seq[v].name or '?')
    end
    if not snip then return end
    for k = 1, #snip do if ox + k - 1 < f.w then ORCA.set(f, ox + k - 1, oy, snip:sub(k, k)) end end
    garden_save()
    GD.ocur = { x = ox, y = oy }
  end,
  play_stop = function() edit.play_stop() end,
  garden_loop = function(ri, ci, n)
    local rg, col = seq[ri], snap and snap.cols[ci]
    if not rg or not col then return end
    if rg.gap then vim.msg = 'free bar: name it first (n in the matrix)'; return end
    local grid = GD.cells(snap, { rg })
    local g = grid[1] and grid[1][ci]
    if not g or not g.item then vim.msg = 'no item in this cell'; return end
    local _, warn = edit.loop_items({ g.item }, state.lpb, rg.rgnend, n)
    vim.msg = ('garden: %s loop %s%s'):format(col.name, n and (n .. ' steps') or 'to region end', warn and (' (' .. warn .. ')') or '')
  end,
  garden_fit = function(ri, ci)
    local rg, col = seq[ri], snap and snap.cols[ci]
    if not rg or not col or rg.gap then vim.msg = 'no region'; return end
    local t1
    for _, lane in ipairs(col.lanes) do
      for _, it in ipairs(lane.items or {}) do
        if it.r0 >= rg.r0 - 1e-6 and it.r0 < rg.r1 - 1e-6 then
          local e = reaper.GetMediaItemInfo_Value(it.item, 'D_POSITION') + reaper.GetMediaItemInfo_Value(it.item, 'D_LENGTH')
          if not t1 or e > t1 then t1 = e end
        end
      end
    end
    if not t1 then vim.msg = 'no item in this cell'; return end
    t1 = edit.row_time(math.ceil(model.row_of_time(t1, state.lpb) - 1e-6), state.lpb, 0)
    ctx.set_region_len(rg, t1)
  end,
  garden_mute = function(ri, ci)
    edit.run('garden mute', function() alias.cells_mute(seq, snap, ri, ri, ci, ci) end)
    vim.msg = 'garden: mute toggled'
  end,
  garden_cmd = function(arg)
    if not state.dev then vim.msg = 'orca: not in this version'; return end
    local f = garden.f
    local a, rest = (arg or ''):match('^(%S*)%s*(.*)$')
    if a == 'show' or a == '' then state.top = true; state.toptab = 'garden'; ctx.set_focus('top'); return end
    if a == 'toggle' then a = (f and f.on) and 'off' or 'on' end
    if a == 'on' then f.on = true; garden_save(); vim.msg = 'garden: Orca ON - plants notes while playing (p: pin, x: clear)'
    elseif a == 'off' then
      f.on = false; garden_save()
      local n = edit.garden_clear(nil); vim.msg = ('garden: Orca OFF, %d planted item(s) removed'):format(n)
    elseif a == 'clear' then
      local n = 0; edit.run('garden clear', function() n = edit.garden_clear(nil) end); vim.msg = ('garden: %d planted item(s) removed'):format(n)
    elseif a == 'pin' then local n = edit.garden_pin(nil); vim.msg = ('garden: %d item(s) pinned (now ordinary items)'):format(n)
    elseif a == 'reset' then f.frame = 0; vim.msg = 'garden: frame 0'
    elseif a == 'load' then garden_load(); vim.msg = 'garden: field reloaded from the project'
    elseif a == 'size' then
      local w, h = rest:match('(%d+)%s*[xX ]%s*(%d+)')
      if w then garden.f = ORCA.resize(f, math.max(4, math.min(128, tonumber(w))), math.max(2, math.min(64, tonumber(h)))); garden_save(); vim.msg = 'garden: field ' .. w .. 'x' .. h end
    else vim.msg = 'garden: on | off | clear | pin | reset | size WxH | load' end
  end,
  -- «-» «+» над лейном: минимум подколонок (авто-раскладка добавит свои при наложениях)
  lane_subs = function(col, lane, d, n)
    local key = col.guid .. ':' .. tostring(lane.idx)
    state.subs_min = state.subs_min or {}
    local v = math.max(1, math.min(8, (n or 1) + d))
    state.subs_min[key] = v
    vim.msg = ('%s: %d column%s'):format(col.name, v, v == 1 and '' or 's')
  end,
  -- «< N >» над номерами строк: длина региона курсора ±d шагов
  region_len_step = function(d)
    local rg = alias.region_at(regions, edit.row_time(vim.cur.row, state.lpb, 0))
    if not rg then vim.msg = 'cursor is not inside a region'; return end
    local steps = math.floor((rg.r1 - rg.r0) + 0.5) + d
    if steps < 1 then vim.msg = 'min 1 step'; return end
    ctx.set_region_len(rg, edit.row_time(rg.r0 + steps, state.lpb, 0))
  end,
  -- кнопки под именем региона (2 окт): /2 x2 — длина вдвое (ripple, как :len),
  -- dup — копия региона справа как новый паттерн (как D в матрице)
  region_btn = function(what)
    local rg = alias.region_at(regions, edit.row_time(vim.cur.row, state.lpb, 0))
    if not rg then vim.msg = 'cursor is not inside a region'; return end
    if what == 'alias' or what == 'clone' or what == 'unique' then
      for i, r in ipairs(seq) do
        if not r.gap and r.idx == rg.idx then
          MX.cur.ri = i
          if what == 'unique' then ctx.slot_unique(i) else ctx.slot_new(what) end
          return
        end
      end
      vim.msg = 'region is not in the sequence (=START..=END)'
      return
    end
    local f = what == 'double' and 2 or 0.5
    local qlen = (rg.qn1 - rg.qn0) * f
    if qlen * state.lpb < 1 - 1e-6 then vim.msg = 'min 1 step'; return end
    ctx.set_region_len(rg, reaper.TimeMap2_QNToTime(0, rg.qn0 + qlen))
  end,
  -- запись: arm трека курсора, выбор входа, умный выбор входа (jf_smart_set_input)
  rec_arm = function()
    local col = cur_col(); if not col then return end
    edit.run('rec arm', function() reaper.SetMediaTrackInfo_Value(col.track, 'I_RECARM', col.armed and 0 or 1) end)
  end,
  -- smart input — отдельный скрипт; нет его — кнопки нет (5 окт, релиз)
  smart_input_path = os.getenv('HOME') .. '/code/reascript/jf_smart-input-select/jf_smart_set_input.lua',
  smart_input = function(col)
    col = col or cur_col(); if not col then return end
    reaper.SetOnlyTrackSelected(col.track)
    local path = ctx.smart_input_path
    local ok, e = pcall(dofile, path)
    vim.msg = ok and 'smart input set' or ('smart input: ' .. tostring(e):match('[^\n]*$'))
  end,
  -- уровни DSP-модуля (4 окт): вход — входа записи (трек армирован) или
  -- до эффектов (аудио-аксессор трека в позиции воспроизведения: items до
  -- FX, без ресивов); выход — пик-метр трека (после FX и фейдера). Пики
  -- спадают плавно; заодно ведёт компенсацию громкости (gain_comp_tick)
  dl = { acc = nil, tr = nil, inp = { 0, 0 }, out = { 0, 0 }, ain = 0, aout = 0 },
  dsp_levels = function(col)
    local tr = col and col.track
    if not (tr and reaper.ValidatePtr(tr, 'MediaTrack*')) then return nil end
    local D = ctx.dl
    if D.tr ~= tr then
      if D.acc then reaper.DestroyAudioAccessor(D.acc) end
      D.acc, D.tr, D.inp, D.out, D.ain, D.aout = nil, tr, { 0, 0 }, { 0, 0 }, 0, 0
    end
    local armed = reaper.GetMediaTrackInfo_Value(tr, 'I_RECARM') == 1
    local il, ir = 0, 0
    if armed then
      local ri = math.floor(reaper.GetMediaTrackInfo_Value(tr, 'I_RECINPUT'))
      if ri >= 0 and ri < 4096 then
        local ch = ri & 1023
        il = reaper.GetInputActivityLevel(ch) or 0
        ir = (ri & 1024 ~= 0) and (reaper.GetInputActivityLevel(ch + 1) or 0) or il
      end
    elseif reaper.GetPlayState() & 1 == 1 then
      if not D.acc then D.acc = reaper.CreateTrackAudioAccessor(tr) end
      if reaper.AudioAccessorStateChanged(D.acc) then reaper.AudioAccessorUpdate(D.acc) end
      local N, sr = 512, 44100
      D.buf = D.buf or reaper.new_array(N * 2)
      local t = reaper.GetPlayPosition()
      D.buf.clear()
      if reaper.GetAudioAccessorSamples(D.acc, sr, 2, t, N, D.buf) == 1 then
        local b = D.buf.table()
        for i = 1, N * 2, 2 do
          local a, c = math.abs(b[i]), math.abs(b[i + 1])
          if a > il then il = a end
          if c > ir then ir = c end
        end
      end
    end
    local ol, or_ = reaper.Track_GetPeakInfo(tr, 0), reaper.Track_GetPeakInfo(tr, 1)
    local function fall(o, v) return math.max(v, o * 0.85) end
    D.inp = { fall(D.inp[1], il), fall(D.inp[2], ir) }
    D.out = { fall(D.out[1], ol), fall(D.out[2], or_) }
    local comp_db = edit.comp_db(tr)
    local _, cf = reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:jf_gaincomp', '', false)
    local on = cf == '1' and comp_db ~= nil
    if on then ctx.gain_comp_tick(tr, math.max(il, ir), math.max(ol, or_), comp_db) end
    return { src = armed and 'in' or 'pre', inp = D.inp, out = D.out, comp_on = on, comp_db = comp_db }
  end,
  -- подстройка: средние пиков входа и выхода (выход до фейдера) за время
  -- игры, где оба громче −50 дБ; шаг не больше 0.2 дБ за кадр, −24..+24
  gain_comp_tick = function(tr, inp, out, cur)
    local D = ctx.dl
    if reaper.GetPlayState() & 1 ~= 1 then return end
    local vol = reaper.GetMediaTrackInfo_Value(tr, 'D_VOL')
    if vol < 1e-3 then return end
    out = out / vol
    if inp < 0.003 or out < 0.003 then return end
    D.ain = D.ain > 0 and (D.ain + (inp - D.ain) * 0.05) or inp
    D.aout = D.aout > 0 and (D.aout + (out - D.aout) * 0.05) or out
    local diff = 20 * math.log(D.ain / D.aout, 10)
    if math.abs(diff) < 0.3 then return end
    edit.comp_set(tr, cur + math.max(-0.2, math.min(0.2, diff)))
  end,
  -- кнопка comp: клик — следить вкл / выкл (выкл — значение замирает),
  -- правый клик — снять gain comp с цепи
  gain_comp = function(col, op)
    local tr = col and col.track
    if not (tr and reaper.ValidatePtr(tr, 'MediaTrack*')) then return end
    local _, cf = reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:jf_gaincomp', '', false)
    if op == 'remove' then
      reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:jf_gaincomp', '', true)
      vim.msg = edit.comp_remove(tr) and 'gain comp removed' or 'no gain comp on this track'
      return
    end
    local on = not (cf == '1' and edit.comp_find(tr))
    if on then edit.comp_add(tr) end
    reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:jf_gaincomp', on and '1' or '', true)
    ctx.dl.ain, ctx.dl.aout = 0, 0
    vim.msg = on and 'gain comp: follows - play the track, the end of the chain matches the level before the fx (right click removes)'
      or 'gain comp: frozen at its value (click - follow again, right click - remove)'
  end,
  -- пресеты эффекта (4 окт): текущее имя и номер — REAPER (GetPreset /
  -- GetPresetIndex); список имён — из файлов REAPER presets/: заводские
  -- [factory] в *-builtin.ini и свои [PresetN] Name= в *.ini; выбор — по имени
  fx_preset = function(f)
    local t = dsp_target(); if not (t and f) or model.is_take(t.track) then return nil end
    local idx, cnt = reaper.TrackFX_GetPresetIndex(t.track, f.i)
    local ok, nm = reaper.TrackFX_GetPreset(t.track, f.i, '')
    if (cnt or 0) <= 0 and not (ok and nm ~= '') then return nil end
    return { name = (ok and nm ~= '') and nm or 'no preset', idx = idx, cnt = cnt }
  end,
  preset_cache = {},
  -- Airwindopedia (4 окт): категория и первая фраза описания плагина Airwindows
  aw_db = nil,
  airwin_info = function(name)
    if ctx.aw_db == nil then
      ctx.aw_db = {}
      local f
      for _, p in ipairs({ '/Library/Audio/Plug-Ins/VST/Airwindopedia.txt', '/Library/Audio/Plug-Ins/Components/Airwindopedia.txt', '/Library/Audio/Plug-Ins/VST3/Airwindopedia.txt' }) do
        f = io.open(p, 'r'); if f then break end
      end
      if f then
        local in_cats = false
        for ln in f:lines() do
          if ln:match('^# Categories') then in_cats = true
          elseif in_cats and ln:match('^#') then in_cats = false end
          local cat, list                        -- не «in_cats and match»: and режет второе значение
          if in_cats then cat, list = ln:match('^([%w%s%-]+):%s*(.+)$') end
          if cat then for nm in list:gmatch('[^,]+') do local k = nm:gsub('^%s+', ''):gsub('%s+$', ''):lower(); ctx.aw_db[k] = ctx.aw_db[k] or {}; ctx.aw_db[k].cat = cat end end
          local nm, desc = ln:match('^############ (%S+) is (.-)%.?%s*$')
          if not nm then nm, desc = ln:match('^############ (%S+) (.-)%.?%s*$') end
          if nm then local k = nm:lower(); ctx.aw_db[k] = ctx.aw_db[k] or {}; ctx.aw_db[k].desc = ctx.aw_db[k].desc or desc end
        end
        f:close()
      end
    end
    local e = ctx.aw_db[(name or ''):lower()]
    if not e then return nil end
    return { cat = e.cat or '', desc = e.desc or '' }
  end,
  -- A / B с морфингом (4 окт): снимки всех параметров эффекта (нормированные),
  -- ключ — GUID эффекта; ползунок внизу блока ведёт от A к B
  ab = {},
  ab_key = function(t, fx) local A = model.fxapi(t.track); return A.GetFXGUID and A.GetFXGUID(t.track, fx) or tostring(fx) end,
  ab_store = function(which, k)
    local t, f = ctx.dsp_fx(k or dsp_sel.fx); if not f then vim.msg = 'A / B: select an fx in the DSP panel'; return end
    local A = model.fxapi(t.track)
    local snap = {}
    for pi = 0, A.GetNumParams(t.track, f.i) - 1 do snap[pi] = A.GetParamNormalized(t.track, f.i, pi) end
    local key = ctx.ab_key(t, f.i)
    ctx.ab[key] = ctx.ab[key] or { t = which == 'a' and 0 or 1 }
    ctx.ab[key][which] = snap
    vim.msg = ('%s: %s stored (%d params)%s'):format(f.name, which:upper(), #snap + 1, (ctx.ab[key].a and ctx.ab[key].b) and ' - drag A..B at the bottom of the block or :morph N' or '')
  end,
  ab_morph_sel = function(x)
    local _, f = ctx.dsp_fx(dsp_sel.fx); if not f then vim.msg = 'morph: select an fx in the DSP panel'; return end
    if not ctx.ab_get(f) then vim.msg = 'morph: store A and B first (:fxa, :fxb)'; return end
    ctx.ab_morph(f, x); vim.msg = ('%s: morph %d%%'):format(f.name, math.floor(x * 100 + 0.5))
  end,
  ab_get = function(f) local t = dsp_target(); if not (t and f) then return nil end; local e = ctx.ab[ctx.ab_key(t, f.i)]; return (e and e.a and e.b) and e or nil end,
  ab_morph = function(f, x)
    local t = dsp_target(); if not (t and f) then return end
    local e = ctx.ab[ctx.ab_key(t, f.i)]; if not (e and e.a and e.b) then return end
    x = math.max(0, math.min(1, x))
    if math.abs((e.t or 0) - x) < 1e-4 then return end
    e.t = x
    local A = model.fxapi(t.track)
    for pi, va in pairs(e.a) do
      local vb = e.b[pi]
      if vb and math.abs(va - vb) > 1e-6 then A.SetParamNormalized(t.track, f.i, pi, va + (vb - va) * x) end
    end
  end,
  -- подписи шагов параметра (4 окт, «шаговые значения выбором»): текст плагина
  -- для каждого положения — FormatParamValueNormalized (параметр не трогается)
  steplab = {},
  -- значение параметра по тексту плагина (7 окт, точки ReaEQ): двоичный
  -- поиск нормализованного значения, чей текст даёт число target (Гц, дБ);
  -- текст растёт вместе со значением
  fx_set_display = function(f, p, target)
    local t = dsp_target(); if not (t and f and p) then return end
    local fx = p.fx or f.i
    local fmt = model.is_take(t.track) and reaper.TakeFX_FormatParamValueNormalized or reaper.TrackFX_FormatParamValueNormalized
    local function num(v)
      local ok, s = fmt(t.track, fx, p.i, v, '')
      if not ok then return nil end
      if s:find('inf') then return s:find('%-') and -1e9 or 1e9 end
      local n = tonumber((s:gsub(',', '.')):match('[-+]?%d*%.?%d+'))
      return n and n * (s:lower():find('%dk') and 1000 or 1)
    end
    local lo, hi = 0, 1
    for _ = 1, 22 do
      local mid = (lo + hi) / 2
      local n = num(mid)
      if not n then break end
      if n < target then lo = mid else hi = mid end
    end
    edit.fx_param(t.track, fx, p.i, (lo + hi) / 2)
  end,
  step_labels = function(f, p)
    local t = dsp_target(); if not (t and f and p and p.nsteps) then return nil end
    local fx = p.fx or f.i
    local key = tostring(t.track) .. '|' .. fx .. '|' .. p.i .. '|' .. p.nsteps
    local c = ctx.steplab[key]
    if c ~= nil then return c or nil end
    local fmt = model.is_take(t.track) and reaper.TakeFX_FormatParamValueNormalized or reaper.TrackFX_FormatParamValueNormalized
    local out = {}
    for k = 0, p.nsteps - 1 do
      local ok, s = fmt(t.track, fx, p.i, k / math.max(1, p.nsteps - 1), '')
      out[#out + 1] = (ok and s ~= '') and s or tostring(k)
    end
    ctx.steplab[key] = out
    return out
  end,
  preset_names = function(tr, fx)
    local _, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, 'fx_ident')
    ident = ident or ''
    if ctx.preset_cache[ident] then return ctx.preset_cache[ident] end
    -- 7 окт: «reaeq.vst.dylib» — срезаются ВСЕ расширения (было только последнее:
    -- ключ reaeqvst не совпадал с vst-reaeq.ini, список был пуст)
    local base = (ident:match('([^/\\]+)$') or ident):gsub('<.*$', ''):gsub('%..*$', '')
    local key = base:lower():gsub('[^%w]', '')
    -- файл: <формат>-<имя>[-builtin].ini; сначала точное совпадение имени
    -- (ReaVerb не берёт пресеты ReaVerbate), иначе — вхождение (JS: путь в имени)
    local function fkey(fn) return fn:lower():gsub('%.ini$', ''):gsub('^%w+%-', ''):gsub('%-builtin$', ''):gsub('[^%w]', '') end
    local exact = false
    do local j = 0; while true do local fn = reaper.EnumerateFiles(reaper.GetResourcePath() .. '/presets', j); if not fn then break end; j = j + 1; if fn:match('%.ini$') and fkey(fn) == key then exact = true; break end end end
    local dir = reaper.GetResourcePath() .. '/presets'
    local names, seen = {}, {}
    local i = 0
    while key ~= '' do
      local fn = reaper.EnumerateFiles(dir, i)
      if not fn then break end
      i = i + 1
      local fk = fkey(fn)
      if fn:match('%.ini$') and ((exact and fk == key) or (not exact and fk:find(key, 1, true))) then
        local h = io.open(dir .. '/' .. fn, 'r')
        if h then
          local sect
          for ln in h:lines() do
            local s = ln:match('^%[(.-)%]')
            if s then sect = s:lower()
            elseif sect == 'factory' or sect == 'aufactory' then
              local v = ln:match('^%d+=(.*)$'); if v and v ~= '' and not seen[v] then seen[v] = true; names[#names + 1] = v end
            elseif sect and sect:match('^preset%d+') then
              local v = ln:match('^Name=(.*)$'); if v and v ~= '' and not seen[v] then seen[v] = true; names[#names + 1] = v end
            end
          end
          h:close()
        end
      end
    end
    ctx.preset_cache[ident] = names
    return names
  end,
  dsp_preset = function(k, what)
    local t, f = ctx.dsp_fx(k); if not f or model.is_take(t.track) then return end
    if what == 'prev' or what == 'next' then
      reaper.TrackFX_NavigatePresets(t.track, f.i, what == 'next' and 1 or -1)
      local _, nm = reaper.TrackFX_GetPreset(t.track, f.i, '')
      vim.msg = f.name .. ': ' .. (nm or '')
      return
    end
    local names = ctx.preset_names(t.track, f.i)
    if #names == 0 then vim.msg = f.name .. ': no preset names (REAPER lists none; < > step through what the plugin has)'; return end
    local items = {}
    for _, nm in ipairs(names) do items[#items + 1] = { label = nm, data = nm } end
    vim.open_picker('preset of ' .. f.name, items, function(it)
      local ok = reaper.TrackFX_SetPreset(t.track, f.i, it.data)
      vim.msg = ok and (f.name .. ': ' .. it.data) or (f.name .. ': could not load ' .. it.data)
    end)
    state.popup_at = { kind = 'xy', x = gfx.mouse_x, y = gfx.mouse_y + 4 }
  end,
  dsp_delta = function(k)
    local col, f = ctx.dsp_fx(k); if not f then return end
    local on = edit.fx_delta(col.track, f.i)
    vim.msg = on == nil and (f.name .. ': no delta solo') or (f.name .. (on and ': delta solo - you hear only what the fx adds / removes' or ': delta off'))
  end,
  fx_delta = function(f)
    local t = dsp_target(); if not (t and f) then return nil end
    local i = edit.fx_delta_idx(t.track, f.i)
    if not i then return nil end
    return model.fxapi(t.track).GetParamNormalized(t.track, f.i, i) >= 0.5
  end,
  hydra_inputs = function()
    local col = cur_col()
    local items = {}
    local keysq = '1234567890abcdefghijklmnopqrstuvwxyz'
    local n = reaper.GetNumAudioInputs()
    local k = 1
    local function add(label, val)
      if k > #keysq or not col then return end
      items[#items + 1] = { key = keysq:sub(k, k), label = label, fn = function()
        edit.run('rec input', function() reaper.SetMediaTrackInfo_Value(col.track, 'I_RECINPUT', val) end) end }
      k = k + 1
    end
    for i = 0, n - 1 do add(reaper.GetInputChannelName(i) or ('in ' .. (i + 1)), i) end
    for i = 0, n - 2, 2 do add(('stereo %d/%d'):format(i + 1, i + 2), 1024 + i) end
    add('MIDI all', 4096 + (63 << 5))
    add('none', -1)
    return { title = 'rec input ' .. (col and col.name or ''), items = items }
  end,
  matrix_move = function(dx, dy)
    if #seq == 0 then return end
    MX.goto_cell(seq, snap, MX.cur.ri + dy, MX.cur.ci + dx)
  end,
  pool_select = pool_select,
  browse = function(path) B.init(ctx, path or B.root); state.side = true end,
  -- файл → депо трека курсора (зона после маркера =LIB на самом треке)
  -- Opt+Enter в браузере (7 окт): файл — новым слайсом выбранного инструмента
  lib_append_slice = function(path)
    local col = cur_col()
    local e = col and (col.pool or {})[vim.inst]
    if e and e.parent then e = e.parent end
    if not (e and e.item and reaper.ValidatePtr(e.item, 'MediaItem*')) then ctx.add_to_depot(path); return end
    local g = edit.slice_append(e.item, path)
    if g then reselect_item = g; vim.msg = '+ slice ' .. (path:match('[^/]+$') or path) .. ' -> ' .. (e.name or 'instrument') .. ' (glued into one sample)'
    else vim.msg = 'could not add the slice' end
  end,
  add_to_depot = function(path)
    if IMP.kind(path) then ctx.import_sliced(path); return end
    local c = cur_col()
    local it = edit.depot_add(path, c and c.track)
    vim.msg = it and ('→ lib ' .. (c and c.name or 'DEPOT') .. ': ' .. path:match('[^/]+$')) or 'lib add failed'
  end,
  -- браузер *.* (2 окт): не звук — MIDI / видео / картинка в строку курсора (REAPER
  -- сам делает источник), остальное — программой macOS по умолчанию
  open_file = function(path)
    local ext = (path:match('%.([%w]+)$') or ''):lower()
    local MEDIA = { mid = true, midi = true, mp4 = true, mov = true, m4v = true, mkv = true, avi = true, webm = true, wmv = true,
                    gif = true, png = true, jpg = true, jpeg = true }
    if MEDIA[ext] then ctx.drop_at_cursor(path); return end
    -- безопасность (6 окт): программой по умолчанию — только документы;
    -- .app / .command / .sh / .pkg и прочее исполняемое не запускается
    local DOCS = { pdf = true, txt = true, md = true, rtf = true, nfo = true, html = true, htm = true, xml = true, json = true, csv = true,
                   doc = true, docx = true, odt = true, pages = true, svg = true, webp = true, tif = true, tiff = true, bmp = true, heic = true }
    if not DOCS[ext] then vim.msg = ('not opened: .%s - only documents open with the default app'):format(ext); return end
    if reaper.CF_ShellExecute then reaper.CF_ShellExecute(path)
    else reaper.ExecProcess("/usr/bin/open '" .. path:gsub("'", "'\\''") .. "'", -1) end
    vim.msg = 'opened with the default app: ' .. (path:match('[^/]+$') or path)
  end,
  -- импорт нарезанного инструмента (2 окт): REX/RX2 — звук декодирует REAPER,
  -- позиции слайсов из файла; XRNI (Renoise / Redux) — распаковка в папку
  -- проекта (несохранённый — <ресурсы REAPER>/Data/jf_tracker_imported), каждый настоящий сэмпл —
  -- инструмент в библиотеке трека со своими слайсами. Один undo-шаг.
  -- col — трек-цель (бросок на колонку); по умолчанию трек курсора.
  -- Возвращает первый импортированный item (для вставки на строку броска).
  import_sliced = function(path, col)
    local c = col or cur_col()
    if not c then vim.msg = 'import: no track'; return end
    local kind = IMP.kind(path)
    local name = (path:match('([^/]+)%.[^.]+$') or path)
    if kind == 'rex' then
      local r, why = IMP.rx2_slices(path)
      local it
      edit.run('import REX ' .. name, function()
        it = edit.depot_add(path, c.track)
        if it and r and #r.slices > 1 then edit.set_slices(it, r.slices) end
      end)
      vim.msg = it and ('REX → lib %s: %s, %s'):format(c.name, name, r and (#r.slices .. ' slices') or ('no slices: ' .. tostring(why)))
        or 'REX import failed (REAPER could not open the file)'
      return it
    end
    if kind ~= 'xrni' then return end
    local _, proj = reaper.EnumProjects(-1, '')
    local base = (proj and proj ~= '' and reaper.GetProjectPath()) or (reaper.GetResourcePath() .. '/Data/jf_tracker_imported')
    local dir = base .. '/xrni/' .. name:gsub('[/:]', '-')
    reaper.RecursiveCreateDirectory(dir, 0)
    local q = function(x) return "'" .. x:gsub("'", "'\\''") .. "'" end
    -- только описание и сэмплы (6 окт): unzip сам отбрасывает ../ и абсолютные пути
    reaper.ExecProcess('/usr/bin/unzip -o -q ' .. q(path) .. " 'Instrument.xml' 'SampleData/*' -d " .. q(dir), 20000)
    local fx = io.open(dir .. '/Instrument.xml', 'rb')
    if not fx then vim.msg = 'XRNI: cannot unpack ' .. name; return end
    local xml = fx:read('*a'); fx:close()
    local list = {}
    local i = 0
    while true do local f = reaper.EnumerateFiles(dir .. '/SampleData', i); if not f then break end; list[#list + 1] = 'SampleData/' .. f; i = i + 1 end
    local listing = table.concat(list, '\n')
    local samples = IMP.xrni_samples(xml)
    local n, ns = 0, 0
    local first
    edit.run('import XRNI ' .. name, function()
      for si, smp in ipairs(samples) do
        local rel = not smp.alias and IMP.xrni_file(listing, si - 1)
        if rel then
          local file = dir .. '/' .. rel
          local it = edit.depot_add(file, c.track)
          if it then
            n = n + 1
            first = first or it
            local tk = reaper.GetActiveTake(it)
            if tk and smp.name ~= '' then reaper.GetSetMediaItemTakeInfo_String(tk, 'P_NAME', smp.name, true) end
            if #smp.slices > 1 then
              local src = reaper.PCM_Source_CreateFromFile(file)
              local sr = src and reaper.GetMediaSourceSampleRate(src) or 0
              if src then reaper.PCM_Source_Destroy(src) end
              if sr > 0 then
                local t = {}
                for _, fr in ipairs(smp.slices) do t[#t + 1] = fr / sr end
                table.sort(t)
                edit.set_slices(it, t); ns = ns + #t
              end
            end
          end
        end
      end
    end)
    vim.msg = ('XRNI → lib %s: %s, %d sample(s), %d slice(s)'):format(c.name, name, n, ns)
    return first
  end,
  -- drag & drop из браузера: файл → item / .rpp → сабпроект на трек в строке
  drop_to = function(fi, row, path)
    local f = L.flat[fi]; if not f or not f.col or f.folded then return end
    -- REX / XRNI — архив инструмента, не звук (2 окт: брошенный на трек
    -- становился пустым item без волны и слайсов): импорт с нарезкой в
    -- библиотеку этого трека, затем инструмент — на строку броска
    if IMP.kind(path) then
      local it = ctx.import_sliced(path, f.col)
      if it then
        local msg = vim.msg
        edit.insert_note(f.col.track, f.col.fixed and f.lane and f.lane.idx or nil, state.lpb, row, model.BASE_NOTE, vim.vel or 100, 1, it)
        vim.msg = msg .. (' - placed at %04d'):format(row)
      end
      return
    end
    local it = edit.drop(f.col.track, f.col.fixed and f.lane and f.lane.idx or nil, state.lpb, row, path)
    vim.msg = it and ('dropped ' .. (path:match('[^/]+$') or path) .. ' → ' .. f.col.name) or 'drop failed'
    return it
  end,
  drop_at_cursor = function(path) ctx.drop_to(vim.cur.fi, vim.cur.row, path) end,
  file_peaks = function(path, npix) return model.file_peaks(path, npix) end,
  -- сэмпл RS5K из файла (бросок на волну): FILE0 + DONE, один undo
  rs5k_file = function(f, path)
    local col = dsp_target(); if not (col and f) then return end
    if model.is_take(col.track) then vim.msg = 'RS5K: take FX - open the plugin window to load a sample'; return end
    path = edit.media_copy(path)
    edit.run('RS5K sample', function()
      reaper.TrackFX_SetNamedConfigParm(col.track, f.i, 'FILE0', path)
      reaper.TrackFX_SetNamedConfigParm(col.track, f.i, 'DONE', '')
    end)
    model.invalidate()
    vim.msg = 'RS5K sample: ' .. (path:match('[^/]+$') or path)
  end,
  -- трек из проекта pm (chunk) → новый трек после трека курсора
  drop_track = function(e, proj_e)
    local c = cur_col()
    local tr = edit.insert_track_chunk(e.chunk, e.name, c and c.track)
    vim.msg = tr and ('track "%s" inserted from %s'):format(e.name, proj_e and proj_e.name or 'project') or 'track insert failed'
  end,
  -- регион проекта pm → сабпроект, обрезанный по региону
  drop_region_to = function(fi, row, path, rg)
    local f = L.flat[fi]; if not f or not f.col or f.folded then return end
    local it = edit.drop_region(f.col.track, f.col.fixed and f.lane and f.lane.idx or nil, state.lpb, row, path, rg)
    vim.msg = it and ('subproject %s → %s @ %04d'):format(rg.name, f.col.name, row) or 'subproject failed'
  end,
  drop_region_at_cursor = function(path, rg) ctx.drop_region_to(vim.cur.fi, vim.cur.row, path, rg) end,
  -- выделение сэмпл-модуля → item в колонку / строку
  drop_span = function(fi, row, entry, a, b)
    local f = L.flat[fi]; if not f or not f.col or f.folded then return end
    local it = edit.insert_span(f.col.track, f.col.fixed and f.lane and f.lane.idx or nil, state.lpb, row, entry, a, b)
    vim.msg = it and ('span %.2fs → %s @ %04d'):format(b - a, f.col.name, row) or 'span: failed'
  end,
  drop_span_cursor = function(entry, a, b) ctx.drop_span(vim.cur.fi, vim.cur.row, entry, a, b) end,
  -- выделение сэмпл-модуля как слайс (5 окт): материнский сэмпл целиком — в lib
  -- трека (уже есть — он же), границы выделения — в его нарезку; → item, k.
  -- Без своего undo: зовётся внутри edit.run
  span_as_slice = function(track, entry, a, b)
    local mother, sa, sb
    local path = entry.file and entry.path
    if not path and entry.item and reaper.ValidatePtr(entry.item, 'MediaItem*') then
      -- уже инструмент этой lib — он и мать; иначе мать — файл источника
      if reaper.GetMediaItem_Track(entry.item) == track then
        for _, c in ipairs(snap.cols or {}) do
          if c.track == track then for _, e in ipairs(c.pool or {}) do if e.item == entry.item and not e.parent then mother = entry.item end end end
        end
      end
      if mother then sa, sb = a, b
      else
        local tk = reaper.GetActiveTake(entry.item)
        local src = tk and reaper.GetMediaItemTake_Source(tk)
        path = src and reaper.GetMediaSourceFileName(src, '')
      end
    end
    if not mother then
      if not path or path == '' then return nil end
      -- секунды item → секунды файла (мать — файл с начала, скорость 1)
      local offs, rate = entry.offs or 0, entry.rate or 1
      sa, sb = offs + a * rate, offs + b * rate
      for _, c in ipairs(snap.cols or {}) do
        if c.track == track then
          for _, e in ipairs(c.pool or {}) do
            local tk = e.item and not e.parent and reaper.ValidatePtr(e.item, 'MediaItem*') and reaper.GetActiveTake(e.item)
            local src = tk and reaper.GetMediaItemTake_Source(tk)
            if src and reaper.GetMediaSourceFileName(src, '') == path and (reaper.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS') or 0) == 0 then mother = e.item end
          end
        end
      end
      mother = mother or edit.depot_add(path, track)
    end
    if not mother then return nil end
    local len = reaper.GetMediaItemInfo_Value(mother, 'D_LENGTH')
    local sl = edit.item_slices(mother)
    local function has(t) for _, v in ipairs(sl) do if math.abs(v - t) < 1e-3 then return true end end end
    if not has(sa) then sl[#sl + 1] = sa end
    if sb < len - 1e-3 and not has(sb) then sl[#sl + 1] = sb end
    table.sort(sl)
    edit.set_slices(mother, sl)
    local k = 1
    for i, v in ipairs(sl) do if math.abs(v - sa) < 1e-3 then k = i end end
    return mother, k
  end,
  -- бросок выделения (5 окт): на трек — мать в его lib + слайс в строку;
  -- в lib — мать + слайс
  drop_span_slice = function(fi, row, entry, a, b)
    local f = fi and L.flat[fi]
    local col = f and f.col or cur_col()
    if not col or (f and f.folded) then return end
    local mother, k
    edit.run('drop slice', function()
      mother, k = ctx.span_as_slice(col.track, entry, a, b)
      if mother and f then edit.insert_slice(col.track, col.fixed and f.lane and f.lane.idx or nil, state.lpb, row, mother, k) end
    end)
    model.invalidate()
    vim.msg = mother and (f and ('slice S%02X (%.2fs) → %s @ %04d'):format(k, b - a, col.name, row) or ('slice S%02X (%.2fs) → lib of %s'):format(k, b - a, col.name)) or 'drop: no source file'
  end,
  depot_span = function(entry, a, b)
    local c = cur_col(); if not c then return end
    local it = edit.depot_span(c.track, entry, a, b)
    vim.msg = it and ('span %.2fs → lib of %s (=LIB)'):format(b - a, c.name) or 'lib: failed'
    model.invalidate()
  end,
  -- файл браузера в сэмпл-модуле
  sample_view = function(path)
    state.top = true; state.toptab = 'sample'
    local c = cur_col()
    if SL.open_file(path, c and c.track) then vim.msg = 'sample: ' .. (path:match('[^/]+$') or path) end
  end,
  -- smart quantize выбранного инструмента (кнопка quantize, Q во вкладке Sample, :quantize)
  smart_quantize = function()
    local col = cur_col(); local e = col and (col.pool or {})[vim.inst]
    if not e then vim.msg = 'no instrument'; return end
    if not (SL.active and SL.entry and SL.entry.item == e.item) then SL.open(e, col.track) end
    SL.smart_quantize(); vim.msg = SL.msg; model.invalidate()
  end,
  -- ── переименование трека и инструмента (2 окт) ─────────────────────
  rename_track_prompt = function(col)
    col = col or cur_col(); if not col then return end
    state.rename_guid = col.guid
    state.popup_at = { kind = 'track', guid = col.guid }
    vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'tname ' .. (col.name or '')
  end,
  rename_track = function(text)
    text = (text or ''):gsub('^%s+', ''):gsub('%s+$', '')
    local col
    for _, c in ipairs((snap and snap.cols) or {}) do if c.guid == state.rename_guid then col = c end end
    col = col or cur_col()
    state.rename_guid = nil
    if not col then vim.msg = 'no track'; return end
    edit.track_name(col.track, text)
    model.invalidate()
    vim.msg = 'track: ' .. (text ~= '' and text or '(no name)')
  end,
  rename_inst_prompt = function()
    local col = cur_col(); local e = col and (col.pool or {})[vim.inst]
    if not e then vim.msg = 'no instrument'; return end
    state.popup_at = { kind = 'inst' }
    vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'iname ' .. (e.name or '')
  end,
  rename_inst = function(text)
    text = (text or ''):gsub('^%s+', ''):gsub('%s+$', '')
    local col = cur_col(); local e = col and (col.pool or {})[vim.inst]
    if not e then vim.msg = 'no instrument'; return end
    if text == '' then vim.msg = 'name: empty'; return end
    local items = {}
    for it, i in pairs((snap and snap.inst_of) or {}) do if i == vim.inst then items[#items + 1] = it end end
    if #items == 0 and e.item then items[1] = e.item end
    local n = edit.take_names(items, text)
    model.invalidate()
    vim.msg = ('instrument %02d: %s (%d item%s)'):format(vim.inst, text, n, n == 1 and '' or 's')
  end,
  -- Cmd+Enter в браузере: выделенный файл заменяет сэмпл выбранного инструмента
  browser_replace = function()
    local e = B.entries[B.cur]
    local path = B.preview_path(e)
    if not path or (e and e.pm) then vim.msg = 'select an audio file in the browser'; return end
    local col = cur_col(); local inst = col and (col.pool or {})[vim.inst]
    if not inst then vim.msg = 'no instrument selected'; return end
    local items = {}
    for it, i in pairs((snap and snap.inst_of) or {}) do if i == vim.inst then items[#items + 1] = it end end
    if #items == 0 and inst.item then items[1] = inst.item end
    local n = edit.replace_source(items, path)
    model.invalidate()
    vim.msg = ('instrument %02d: %s -> %s (%d item%s)'):format(vim.inst, inst.name, path:match('[^/]+$') or path, n, n == 1 and '' or 's')
  end,
  -- информация о файле (панель справа от большой волны, 2 окт); кэш по пути
  file_info = (function()
    local cache = {}
    return function(path)
      if not path then return nil end
      if cache[path] ~= nil then return cache[path] or nil end
      local src = reaper.PCM_Source_CreateFromFile(path)
      if not src then cache[path] = false; return nil end
      local len = reaper.GetMediaSourceLength(src) or 0
      local sr = reaper.GetMediaSourceSampleRate(src) or 0
      local ch = reaper.GetMediaSourceNumChannels(src) or 0
      local typ = reaper.GetMediaSourceType(src, '') or ''
      local bits = reaper.CF_GetMediaSourceBitDepth and reaper.CF_GetMediaSourceBitDepth(src) or 0
      local function meta(k)
        local ok, v = false, ''
        if reaper.GetMediaFileMetadata then ok, v = reaper.GetMediaFileMetadata(src, k) end
        return (ok and v ~= '') and v or nil
      end
      local bpm = meta('ID3:TBPM') or meta('XMP:dm/tempo') or meta('BWF:Description')
      local key = meta('ID3:TKEY') or meta('XMP:dm/key')
      reaper.PCM_Source_Destroy(src)
      local size
      local fh = io.open(path, 'rb')
      if fh then size = fh:seek('end'); fh:close() end
      local rows = {
        { 'format', typ:lower() }, { 'length', ('%.3f s'):format(len) },
        { 'rate', ('%d Hz'):format(math.floor(sr + 0.5)) }, { 'channels', ch == 1 and 'mono' or (ch == 2 and 'stereo' or tostring(ch)) },
      }
      if bits and bits > 0 then rows[#rows + 1] = { 'bits', tostring(bits) } end
      if size then rows[#rows + 1] = { 'size', size > 1048576 and ('%.1f MB'):format(size / 1048576) or ('%d KB'):format(math.floor(size / 1024)) } end
      if bpm then rows[#rows + 1] = { 'bpm / desc', bpm } end
      if key then rows[#rows + 1] = { 'key', key } end
      rows[#rows + 1] = { 'folder', path:match('(.*)/[^/]+$') or '' }
      local info = { name = path:match('[^/]+$') or path, rows = rows }
      cache[path] = info
      return info
    end
  end)(),
  -- мини-плеер внизу браузера (2 окт): позиция, громкость, старт с места
  preview_pos = function() return PV.position() end,
  preview_vol = function() return PV.vol end,
  preview_set_vol = function(v) PV.set_vol(v); state.pvvol = PV.vol end,
  -- кнопка track браузера (2 окт): файлы слушаются через выделенный трек
  -- (его FX), выключена — мимо треков, прямо в выход
  preview_track = function()
    if not B.via_track then return nil end
    return reaper.GetSelectedTrack(0, 0) or (cur_col() and cur_col().track)
  end,
  preview_from = function(path, frac)
    local c = cur_col()
    local len = 0
    do local src = reaper.PCM_Source_CreateFromFile(path); if src then len = reaper.GetMediaSourceLength(src) or 0; reaper.PCM_Source_Destroy(src) end end
    PV.sync = B.sync; PV.file(ctx.preview_track(), path, nil, frac * len)
  end,
  -- keys браузера (5 окт): нотная клавиша играет выбранный файл, C-4 — как есть
  browser_note = function(c)
    local off = keys.piano[c]
    if off == nil then return false end
    local path = B.preview_path(B.entries[B.cur])
    if not path then return true end
    local semis = (vim.octave + 1) * 12 + off - 60
    PV.sync = B.sync; PV.file(ctx.preview_track(), path, nil, nil, semis)
    vim.msg = ('keys: %s %+d'):format(path:match('[^/]+$') or path, semis)
    return true
  end,
  preview_file = function(path, sec)
    local c = cur_col()
    PV.sync = B.sync; PV.file(ctx.preview_track(), path, sec)   -- без лимита: файл целиком, следующий выбор останавливает
    -- проигрываемый файл сразу открывается в сэмпл-модуле
    if state.top and SL.open_file then
      if state.toptab ~= 'sample' then state.toptab = 'sample' end
      SL.open_file(path, c and c.track)
    end
  end,
  side_toggle_width = function() state.sidenarrow = not state.sidenarrow end,
  side_hide = function() state.side = false; if state.focus == 'browser' then ctx.set_focus('tracker') end end,
  -- фокус клавиатуры: 'tracker' | 'matrix' | 'top' (вкладка верха) | 'browser'.
  -- Розовая рамка показывает, кому идут клавиши. Tab — по кругу.
  -- клавиатура (5 окт): видна = работает; приоритет над Vim-клавишами верхнего ряда
  piano_on = function() return state.piano_show and true or false end,
  toggle_piano = function()
    state.piano_show = not state.piano_show
    vim.piano = state.piano_show
    reaper.SetExtState('jf_tracker', 'piano', state.piano_show and '1' or '0', true)
    if state.hints then vim.msg = state.piano_show and 'keyboard on (m): q 2 w 3 e ... play notes, z x octave, INSERT writes them' or 'keyboard off (m): Vim keys'
    else vim.msg = state.piano_show and 'keyboard on' or 'keyboard off' end   -- длинно — только с хинтами (5 окт)
    relayout()
  end,
  set_focus = function(f)
    -- клик без Option фокус не переводит (опция focus by mouse, 5 окт); заметки — всегда
    if ctx.click_guard and f ~= state.focus and f ~= 'notes' and f ~= 'fxb' then return end   -- поиск эффектов — по клику (5 окт)
    if f == 'fxb' and state.focus ~= 'fxb' then state.fxb_back = state.focus end   -- после добавления — назад
    if f == 'matrix' and #seq == 0 then f = 'tracker' end
    if f == 'browser' and not state.side then f = 'tracker' end
    if f == 'top' and not state.top then f = 'tracker' end
    if f == 'dsp' and not (state.dsp or state.khelp) then f = 'tracker' end
    if f == 'fxb' and not ((state.dsp and state.fxb and not state.khelp) or (state.side and B.mode == 'fx' and (state.browserleft or state.router_big))) then f = 'tracker' end
    if f == 'notes' and not (state.top and state.notes_open) then f = 'tracker' end
    if state.focus == 'notes' and f ~= 'notes' and ctx.notes_save then ctx.notes_save() end
    if f == 'inst' and not (state.top or state.side) then f = 'tracker' end   -- инструменты живут и в сайдбаре (2 окт)
    if f == 'ctrl' and not state.top then f = 'tracker' end
    if f == 'session' and not state.clipsview then f = 'tracker' end   -- session (7 окт)
    if f == 'ctrl' and state.focus ~= 'ctrl' then state.ctrl_sel = 'bpm' end   -- фокус на главном модуле: курсор на BPM (3 окт)
    if state.focus == 'top' and f ~= 'top' and SL.active then SL.close() end
    if f == 'dsp' and state.focus ~= 'dsp' then KH.from = state.focus end
    state.focus = f
    MX.focus = f == 'matrix'; B.focus = f == 'browser'
    if f == 'top' and state.toptab == 'sample' and not SL.active then ctx.open_slicer() end
  end,
  -- Tab — вперёд по кругу, Shift-Tab — назад (dir = -1)
  toggle_focus = function(dir)
    dir = dir or 1
    if state.pm_big then ctx.set_focus('browser'); return end                -- big: фокус только у карточек
    if state.ss_big then ctx.set_focus('matrix'); return end
    -- по часовой (2 окт): трекер → инструменты → браузер → DSP → матрица → верхний док → трекер
    local order = { 'tracker' }
    if state.slices_on then order[#order + 1] = 'slices' end          -- модуль слайсов перед lib (4 окт)
    if state.top or state.side then order[#order + 1] = 'inst' end
    if state.side then order[#order + 1] = 'browser' end
    if state.dsp or state.khelp then order[#order + 1] = 'dsp' end
    if state.top and state.notes_open then order[#order + 1] = 'notes'
    elseif state.dsp and state.fxb and not state.khelp then order[#order + 1] = 'fxb' end
    if not state.mx_hidden then order[#order + 1] = 'matrix' end
    if state.top then order[#order + 1] = 'ctrl'; order[#order + 1] = 'top' end
    local i = 1
    for k, v in ipairs(order) do if v == state.focus then i = k end end
    ctx.set_focus(order[(i - 1 + dir) % #order + 1])
  end,
  scroll_to = function(row, ci)
    vim.cur.row = row
    for i, f in ipairs(L.flat) do if f.ci == ci then vim.cur.fi = i; break end end
    state.row0 = row
  end,
  -- живая матрица: курсор на регионе ведёт edit-курсор, если проект стоит
  region_cursor = function(rg) if not playing() then reaper.SetEditCurPos(rg.pos, false, false) end end,
  -- Space на регионе: играет — в очередь (прыжок на границе текущего), стоит — play отсюда
  region_space = function(rg)
    if playing() then
      if MX.queued and MX.queued.idx == rg.idx then MX.queued = nil; vim.msg = 'queue cleared'
      else MX.queued = rg; vim.msg = 'queued: ' .. (rg.name ~= '' and rg.name or rg.idx) end
    else
      reaper.SetEditCurPos(rg.pos, false, false); reaper.OnPlayButton()
    end
  end,
  sync_here = function()
    local rg = alias.region_at(regions, edit.row_time(vim.cur.row, state.lpb, 0))
    if not rg then return 0 end
    local n = 0
    edit.run('sync ' .. rg.name, function() n = alias.sync(regions, rg) end)
    return n
  end,
  alias_yank = function(rg) state.yanked_region = rg; vim.msg = 'yank pattern ' .. rg.name end,
  alias_paste = function()
    local rg = state.yanked_region
    if not rg then vim.msg = 'no pattern yanked'; return end
    local t0 = alias.append(regions, rg)
    if t0 then vim.msg = ('pattern %s → %.2fs'):format(rg.name, t0) end
  end,
  -- hydra (which-key) по лидеру \: те же действия, что в контекстном меню
  hydra_root = function()
    local function group(title, list)
      local items = {}
      for _, a in ipairs(list) do
        if a.key then items[#items + 1] = { key = a.key, label = (a[1]:gsub('^!', '')), fn = a.fn } end
      end
      return { title = title, items = items }
    end
    local col = cur_col()
    local f = L.flat[vim.cur.fi]
    local hover = { fi = vim.cur.fi, cell = f and f.sub and f.sub[vim.cur.row], col = col }
    local rg = alias.region_at(regions, edit.row_time(vim.cur.row, state.lpb, 0))
    local items = {
      { key = '\\', label = 'context: what is under the cursor', fn = function() ctx.context_here() end },
      { key = 'e', label = 'event / selection', sub = function() return group('event', event_actions(hover)) end },
      { key = 't', label = 'track' .. (col and (': ' .. col.name) or ''), sub = function() return col and group('track ' .. col.name, track_actions(col)) or { title = 'track', items = {} } end },
      { key = 'p', label = 'pattern' .. (rg and (': ' .. rg.name) or ''), sub = function() return group('pattern', region_actions(rg)) end },
      { key = 'v', label = 'view', sub = function() return group('view', view_actions()) end },
      -- P — проект (5 окт): n — заметки проекта
      { key = 'P', label = 'project', sub = function() return { title = 'project', items = {
          { key = 'n', label = 'project notes', fn = function()
              if state.notes_open then ctx.notes_target('project') else NT.target = 'project'; ctx.notes_toggle() end end },
          { key = 'c', label = 'notes of the item under the cursor', fn = function()
              if state.notes_open then ctx.notes_target('context') else NT.target = 'context'; ctx.notes_toggle() end end },
          { key = 'd', label = 'dev notes: what to check (with debug on)', fn = function()
              if not state.debug then vim.msg = 'dev notes live in debug mode: turn debug on'; return end
              if state.notes_open then ctx.notes_target('dev') else NT.target = 'dev'; ctx.notes_toggle() end end },
          { key = 's', label = 'save the project', fn = function() reaper.Main_OnCommand(40026, 0); vim.msg = 'project saved' end },
          { key = 'o', label = 'options', fn = function() ctx.options() end },
          { key = 'a', label = 'about', fn = function() ctrl_action('about', 0) end },
        } } end },
      { key = 'r', label = 'record', sub = function() return { title = 'record', items = {
          { key = 'a', label = (col and col.armed) and 'disarm track' or 'arm track', fn = ctx.rec_arm },
          { key = 'i', label = 'choose input …', sub = function() return ctx.hydra_inputs() end },
          { key = 's', label = 'smart input (most active)', fn = ctx.smart_input },
          { key = 'm', label = 'monitor off/on/tape', fn = function()
              if col then edit.run('rec mon', function()
                local m = reaper.GetMediaTrackInfo_Value(col.track, 'I_RECMON')
                reaper.SetMediaTrackInfo_Value(col.track, 'I_RECMON', (m + 1) % 3) end) end end },
          { key = 'r', label = 'REAPER record (transport)', fn = function() reaper.Main_OnCommand(1013, 0) end },
          { key = 'p', label = 'punch: time selection = pattern/bar', fn = ctx.punch },
          { key = 'o', label = 'record mode …', sub = function() return ctx.hydra_recmode() end },
          { key = 'l', label = 'fixed lanes on/off (:lanes)', fn = ctx.toggle_lanes },
        } } end },
      { key = 'i', label = 'insert: note / slice / whole sample / automation …', sub = function() return ctx.insert_hydra() end },
      { key = 'I', label = 'instrument (pool)', sub = function()
          local it = {}
          for i, e in ipairs(col and col.pool or {}) do
            if i <= 10 then it[#it + 1] = { key = tostring(i % 10), label = e.name .. (e.slices and (' [' .. #e.slices .. ' sl]') or ''), fn = function() pool_select(i) end } end
          end
          it[#it + 1] = { key = 's', label = 'slice current instrument …', fn = function() ctx.open_slicer() end }
          return { title = 'instrument', items = it }
        end },
      { key = 'f', label = 'add FX (fzf by all installed) …', fn = ctx.fx_picker },
      { key = 'a', label = 'REAPER actions (all, fzf) … (:!)', fn = function() ctx.reaper_actions() end },
      { key = 'l', label = 'loop in region (polymeter) …', sub = function() return { title = 'loop', items = {
          { key = 'i', label = 'item -> region end (loop)  [>]', fn = function() ctx.loop('item') end },
          { key = 'r', label = 'region -> item end  [<]', fn = function() ctx.loop('region') end },
          { key = 'o', label = 'loop off', fn = function() ctx.loop('off') end },
          { key = '1', label = 'period 1 row', fn = function() ctx.loop('item', 1) end },
          { key = '2', label = 'period 2 rows', fn = function() ctx.loop('item', 2) end },
          { key = '3', label = 'period 3 rows', fn = function() ctx.loop('item', 3) end },
          { key = '4', label = 'period 4 rows', fn = function() ctx.loop('item', 4) end },
          { key = '6', label = 'period 6 rows', fn = function() ctx.loop('item', 6) end },
          { key = '8', label = 'period 8 rows', fn = function() ctx.loop('item', 8) end },
          { key = 'n', label = 'period N rows … (:loop N)', fn = function() vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'loop ' end },
        } } end },
      { key = 'x', label = 'x-fade (' .. (state.xfade and 'on' or 'off') .. ', ' .. state.xfade_ms .. ' ms) …', sub = function() return { title = 'x-fade', items = {
          { key = 'x', label = (state.xfade and 'turn OFF' or 'turn ON') .. ' x-fade on insert', fn = ctx.xfade_toggle },
          { key = 'c', label = 'crossfade now (selection / column in region)', fn = ctx.xfade_now },
          { key = 'm', label = 'by: ' .. (state.xfademode == 'fades' and 'item fades -> switch to vol values' or 'vol values (take envelope) -> switch to item fades'), fn = function() state.xfademode = state.xfademode == 'fades' and 'vol' or 'fades'; vim.msg = 'x-fade by ' .. state.xfademode end },
          { key = 'd', label = 'remove crossfades (track of cursor)', fn = ctx.xfade_clear },
          { key = '1', label = '5 ms', fn = function() ctx.xfade_len(0, 5) end },
          { key = '2', label = '10 ms', fn = function() ctx.xfade_len(0, 10) end },
          { key = '3', label = '20 ms', fn = function() ctx.xfade_len(0, 20) end },
          { key = '4', label = '50 ms', fn = function() ctx.xfade_len(0, 50) end },
          { key = '5', label = '100 ms', fn = function() ctx.xfade_len(0, 100) end },
          { key = '+', label = 'length +1 ms', fn = function() ctx.xfade_len(1) end },
          { key = '-', label = 'length -1 ms', fn = function() ctx.xfade_len(-1) end },
        } } end },
      { key = 'd', label = (state.dsp and 'hide' or 'show') .. ' DSP panel (:dsp)', fn = ctx.toggle_dsp },
      { key = 'o', label = 'options (quick toggles) …', sub = function() return ctx.options_hydra() end },
      -- \P — проект (2 окт): s сохранить (как :w), S сохранить как…
      { key = 'P', label = 'project …', sub = function() return { title = 'project', items = {
          { key = 's', label = 'save project (:w)', fn = function() edit.save(); vim.msg = 'project saved' end },
          { key = 'S', label = 'save project as …', fn = function() reaper.Main_OnCommand(40022, 0) end },
        } } end },
      { key = ':', label = 'command line', fn = function() vim.mode = 'cmd'; vim.cmdline = '' end },
      { key = '/', label = 'search', fn = function() vim.mode = 'search'; vim.searchline = '' end },
      { key = '?', label = 'keys cheat sheet', sub = function() return ctx.hydra_keys() end },
    }
    return { title = '` menu', items = items }
  end,
  hydra_keys = function()
    local K = {
      { 'hjkl', 'field / row' }, { 'HL', 'track' }, { 'wbe', 'event' }, { 'gg G {}', 'start / end, bar' },
      { 'x dd d{m}', 'delete' }, { 'yy p', 'copy / paste' }, { 'c s m', 'replace / split / mute' },
      { '^A ^X', 'field +-1' }, { 'r', 'set value' }, { 'u ^R .', 'undo / redo / repeat' },
      { 'q @', 'macros' }, { 'v V', 'selection' }, { 'za zM zR', 'fold' }, { 'i a', 'INSERT / envelopes' },
      { '> < N>', 'loop: item to region end / region to item end / period N rows' },
      { 'Cmd 1..0 `', 'instrument / note-off (INSERT)' }, { '[ ] ( )', 'octave / instrument' },
      { '/ n N *', 'search' }, { ':', 'command (Tab completes)' }, { '\\', 'hydra of actions' },
      { 'F Space Enter', 'follow / play / edit cursor' }, { 'Tab S-Tab', 'focus' }, { 'o', 'reveal in REAPER' },
      { 'BS Ins', 'delete / insert time (Shift: all)' }, { 'F1', 'help' },
    }
    local items = {}
    for _, k in ipairs(K) do items[#items + 1] = { key = k[1], label = k[2] } end
    return { title = 'keys (Esc)', items = items }
  end,
  preview = function(track, pitch, inst_item, row, step)
    if inst_item and PV.available() then
      local has_midi = false
      for i = 0, reaper.CountTrackMediaItems(track) - 1 do
        local tk = reaper.GetActiveTake(reaper.GetTrackMediaItem(track, i))
        if tk and reaper.TakeIsMIDI(tk) then has_midi = true; break end
      end
      if not has_midi then PV.audio(track, inst_item, pitch - model.BASE_NOTE); return end
    end
    local t0 = edit.row_time(row, state.lpb, 0)
    local t1 = edit.row_time(row + math.max(1, step or 1), state.lpb, 0)
    PV.midi(t0, t1)
  end,
}

edit.init(model)
alias.init(model, edit)
CM.init(model)
edit.cmds = CM
-- высота предыдущего события в той же подколонке (для Gxx glide)
edit.prev_semis = function(head)
  if not L then return nil end
  for _, f in ipairs(L.flat) do
    if f.sub and f.sub[head.row0] == head then
      for r = head.row0 - 1, 0, -1 do
        local c = f.sub[r]
        if c and (c.kind == 'audio' or c.kind == 'midi') then return c.semis end
      end
      return nil
    end
  end
  return nil
end
edit.pitch_mode = function(head)
  local tr = head.item and reaper.GetMediaItem_Track(head.item)
  local g = tr and model.track_guid(tr)
  return (g and state.pitchmodes[g]) or 'shift'
end
edit.after = function(desc)
  -- новый паттерн (2 окт): вставка на строку, которую не покрывает ни один
  -- регион (новый проект, свободный такт матрицы) → регион на весь такт этой
  -- строки; имя пустое, как у нового региона REAPER. В том же шаге undo.
  if desc:match('^insert') or desc:match('^paste') or desc:match('^rec ') or desc:match('^drop') then
    local t = edit.row_time(vim.cur.row, state.lpb, 0)
    local s0 = model.marker_pos(model.START_MARKER)
    local s1 = model.marker_pos(model.END_MARKER)
    local lib = regions and regions.lib_pos
    local covered = false
    local next_pos
    for _, rg in ipairs(regions or {}) do
      if not rg.lib and not rg.session then
        if t >= rg.pos - 1e-6 and t < rg.rgnend - 1e-6 then covered = true end
        if rg.pos > t + 1e-6 and (not next_pos or rg.pos < next_pos) then next_pos = rg.pos end
      end
    end
    if not covered and (not s0 or t >= s0 - 1e-6) and (not s1 or t < s1 - 1e-6) and (not lib or t < lib - 1e-6) then
      local qn = reaper.TimeMap2_timeToQN(0, t)
      local _, qms, qme = reaper.TimeMap_QNToMeasures(0, qn + 1e-9)
      local t0 = reaper.TimeMap2_QNToTime(0, qms or qn)
      local t1 = reaper.TimeMap2_QNToTime(0, qme or (qn + 4))
      if s0 and t0 < s0 then t0 = s0 end
      if next_pos and t1 > next_pos then t1 = next_pos end
      if s1 and t1 > s1 then t1 = s1 end
      if t1 > t0 + 1e-4 then
        reaper.AddProjectMarker2(0, true, t0, t1, '', -1, 0)
        vim.msg = 'new pattern: region created for this bar'
        model.invalidate()
      end
    end
  end
  if not state.autosync or not regions or #regions == 0 then return end
  -- новый регион пуст: синк не нужен, только жёсткие границы
  if desc == 'add region' then model.invalidate(); alias.trim(model.regions(state.lpb)); return end
  if desc:match('^sync') or desc:match('^pattern copy') or desc:match('^matrix') or desc:match('^depot') then return end
  local rg = alias.region_at(regions, edit.row_time(vim.cur.row, state.lpb, 0))
  if rg then alias.sync(regions, rg) end
  -- жёсткие границы: после любой правки items не вылезают из своих регионов
  alias.trim(regions)
end
draw.screensets = dofile(DIR .. '/jf_tracker_screensets.lua')   -- формат скринсетов (4 окт)
draw.macro = dofile(DIR .. '/jf_tracker_macro.lua')   -- макро-вид (3 окт); полем draw: предел локальных
draw.key_label = keys.label                              -- подписи клавиш в раскладке (5 окт)
ctx.key_label = keys.label
draw.themes = dofile(DIR .. '/jf_tracker_themes.lua')   -- темы трекера (3 окт); полем draw: у главного чанка предел локальных
ctx.load_user_themes()                                   -- свои темы из Data/jf_tracker_themes (5 окт)
if not draw.themes.valid(state.theme) then state.theme = 'reaper' end
draw.themes.apply(U, state.theme)
draw.init(U, model.peaks, MX)
-- Theme Adjuster / смена темы (2 окт): раз в секунду подпись темы; изменилась —
-- палитра перечитывается (jf_looper_ui не трогаем: свежая копия, поля в U),
-- draw заново выводит свои цвета, кэши картинок текста и цветов сброшены
local theme_watch = { t = 0, sig = nil }
local function theme_sig()
  local parts = { reaper.GetLastColorThemeFile and reaper.GetLastColorThemeFile() or '' }
  for _, k in ipairs({ 'col_main_bg2', 'col_main_text2', 'col_tr1_bg', 'col_env1', 'col_seltrack' }) do
    parts[#parts + 1] = tostring(reaper.GetThemeColor(k, 0))
  end
  return table.concat(parts, '|')
end
local function theme_check()
  local now = reaper.time_precise()
  if now - theme_watch.t < 1 then return end
  theme_watch.t = now
  local sig = theme_sig()
  if theme_watch.sig == nil then theme_watch.sig = sig; return end
  if sig == theme_watch.sig then return end
  theme_watch.sig = sig
  if ctx.apply_theme(state.theme) then vim.msg = 'theme colours updated' end
end
-- тема трекера (3 окт): родная палитра заново (jf_looper_ui — свежая копия),
-- поверх — тема из jf_tracker_themes; draw пересчитывает свои цвета, кэши
-- картинок текста и цветов сброшены. reaper — родная палитра как есть
function ctx.apply_theme(name)
  local ok, fresh = pcall(dofile, DIR .. '/jf_tracker_ui.lua')
  if not ok or type(fresh) ~= 'table' then return false end
  for k, v in pairs(fresh) do if type(v) == 'table' then U[k] = v end end
  if not draw.themes.valid(name) then name = 'reaper' end
  state.theme = name
  draw.themes.apply(U, name)
  draw.init(U, model.peaks, MX)
  if draw.reset_colours then draw.reset_colours() end
  draw.set_font(state)                          -- сброс кэша картинок текста (цвета в ключе)
  return true
end
OPT.init(U, ctx)
OPT.ask.init(U, ctx)
draw.hint = HN.add
ctx.hint = function(...) return draw.hint(...) end   -- через draw.hint: сдвиг верхнего модуля (mid / bottom)
ctx.env_colour = draw.env_colour
ctx.ic = function(name, text) return draw.ic(name, text) end
ctx.icons_on = function() return draw.icons and not draw.hybrid and (state.font or 0) > 0 end
vim.init(ctx)
MX.init(U, ctx)
DK.init(ctx)
IK.init(ctx)
MM.hint = function(...) return draw.hint(...) end
MX.ruler = state.mxruler
MX.fold = state.mxfold
B.init(ctx, (ext('browse', '') ~= '' and ext('browse', '')) or nil)
SL.init(ctx)
-- импульс ReaVerb (5 окт): задание спектрограммы файла импульса для вида ir
draw.ir_job = function(f)
  local t = dsp_target()
  if not t or model.is_take(t.track) then return nil end
  local p = ctx.ir_path(t.track, f.i)
  if not p then return nil end
  local nm = p:match('[^/]+$') or p
  local key = 'ir:' .. p
  if SL.sg.jobs[key] then return SL.sg.jobs[key], nm end
  local rd, sr, len = SL.sg.wav_reader(p)
  if not rd then return nil, nm .. ' (not wav)' end
  return SL.sg.get(key, rd, len, sr, 256, 64), nm
end
MMX.init(U, ctx)
MMX.PP.init(U, ctx)
draw.macro.init(U)
GD.init(U, ctx)
MX.SS.init(U, ctx)
do   -- правки DSP big — через edit (undo), дерево после правки перечитывается
  local function obj() local t = dsp_target(); return t and t.track end
  local function after() ctx.db_cache = nil end
  MX.DB.init(U, ctx, {
    close = function() if state.router_big then ctx.router_big() else ctx.dsp_big() end end,
    big = function() ctx.router_big() end,
    msg = function(m) vim.msg = m end,
    show = function(a) local o = obj(); if o then edit.fx_show(o, a) end end,
    bypass = function(a) local o = obj(); if o then edit.fx_bypass(o, a); after() end end,
    enable = function(a, on) local o = obj(); if o then edit.fx_set_enabled(o, a, on); after() end end,
    parallel = function(a, v) local o = obj(); if o then edit.fx_parallel(o, a, v); after(); vim.msg = v > 0 and 'fx joins the row (parallel)' or 'fx leaves the row (serial)' end end,
    param = function(a, i, v) local o = obj(); if o then edit.fx_param(o, a, i, v); after() end end,
    remove = function(a, unpar) local o = obj(); if o then edit.fx_remove(o, a, unpar); after() end end,
    add = function(n, par)
      local o = obj(); if not o then return end
      local parent, pos, pv = MX.DB.insert_point(n, par)
      if parent and not parent.parent.root then vim.msg = 'dsp big: adding inside a nested container is not supported yet'; return end
      if not n then local root = ctx.db_tree(); pos = root and #root.kids or 0 end
      vim.open_picker(par and 'add fx in parallel' or 'add fx after', ctx.fx_list(), function(it)
        if edit.fx_insert(o, parent and parent.k or nil, pos, it.data, pv) then vim.msg = '+ ' .. it.label .. (par and ' (parallel)' or '') end
        after()
      end)
    end,
  })
end
MX.clips = false   -- 7 окт: вида clips в матрице больше нет (сессия — в теле трекера, zs; zz в матрице — на всё окно)
-- инструмент ноты (6 окт): item-представитель из снимка — база транспоза
edit.inst_ref = function(it)
  local i = snap and snap.inst_of and snap.inst_of[it]
  local e = i and snap.pool and snap.pool[i]
  return e and e.item or nil
end
SPROP.init(U, ctx)

-- ── прыжок по подсказке (f + метка) ───────────────────────────────────────
local function hint_go(t)
  local d = t.data
  if t.kind == 'bar' then ctx.set_focus('tracker'); vim.cur.fi, vim.cur.row = d.fi, d.row; vim.cur.field = 1; state.row0 = math.max(0, math.min(state.row0, d.row))
  elseif t.kind == 'env' then ctx.set_focus('tracker'); vim.cur.fi = d; vim.cur.field = 1
  elseif t.kind == 'header' or t.kind == 'scope' then
    ctx.set_focus('tracker')
    for i, f in ipairs(L.flat) do if f.col == d then vim.cur.fi = i; break end end
  elseif t.kind == 'btn' and d.what == 'auto' then ctx.automation_picker(d.col)
  elseif t.kind == 'hdrin' then
    if d.what == 'smart' then ctx.smart_input(d.col) else ctx.input_picker(d.col) end
  elseif t.kind == 'trs' then
    state.kslider = { col = d.col, what = d.what }
    if state.mixer and d.what == 'vol' then vim.msg = ('%s fader: k j volume, h l pan (Shift fine), 0 reset, Esc done'):format(d.col.name or '')
    else vim.msg = ('%s %s: h l change (H L coarse), j k next slider, 0 reset, Esc done'):format(d.col.name or '', d.what) end
  elseif t.kind == 'trsmark' then                                -- 8 окт: метка dB у фейдера — громкость на неё (2f — ходом)
    if reaper.ValidatePtr(d.col.track, 'MediaTrack*') then ctx.fader_jump(d.col, d.db, ctx.glide) end
  elseif t.kind == 'trsbtn' then
    local open = draw.trspop and draw.trspop.guid == d.col.guid and draw.trspop.what == d.what
    draw.trspop = (not open) and { guid = d.col.guid, what = d.what } or nil
    -- 8 окт: открылся — клавиатура на нём (h l, Shift мелко, 0 сброс, Esc)
    if not open then state.kslider = { col = d.col, what = d.what }; vim.msg = ('%s %s: h l change (H L fine), 0 reset, Esc done'):format(d.col.name or '', d.what) else state.kslider = nil end
  elseif t.kind == 'btn' then
    local tr, what = d.col.track, d.what
    edit.run('track ' .. what, function()
      if what == 'monitor' then reaper.SetMediaTrackInfo_Value(tr, 'I_RECMON', (math.floor(reaper.GetMediaTrackInfo_Value(tr, 'I_RECMON')) + 1) % 3)
      elseif what == 'mute' then reaper.SetMediaTrackInfo_Value(tr, 'B_MUTE', reaper.GetMediaTrackInfo_Value(tr, 'B_MUTE') == 1 and 0 or 1)
      elseif what == 'solo' then reaper.SetMediaTrackInfo_Value(tr, 'I_SOLO', reaper.GetMediaTrackInfo_Value(tr, 'I_SOLO') > 0 and 0 or 1)
      else reaper.SetMediaTrackInfo_Value(tr, 'I_RECARM', reaper.GetMediaTrackInfo_Value(tr, 'I_RECARM') == 1 and 0 or 1) end
    end)
  elseif t.kind == 'mx' then ctx.set_focus('matrix'); MX.goto_cell(seq, snap, d.ri, d.ci)
  elseif t.kind == 'mxprev' then ctx.slot_cycle(d, -1)
  elseif t.kind == 'mxnext' then ctx.slot_cycle(d, 1)
  elseif t.kind == 'mxbtn' then
    if d == 'fold' then ctx.mx_fold_toggle() elseif d == 'zoom' then ctx.mx_zoom() elseif d == 'ruler' then ctx.mx_ruler_toggle() elseif d == 'fill' then MX.fill = not MX.fill elseif d == 'sync' then ctx.sync_here() elseif d == 'add' then ctx.mx_add() elseif d == 'trim' then ctx.mx_trim() elseif d == 'loops' then ctx.mx_loops_toggle() end
  elseif t.kind == 'sidectl' then if d == 'open' then state.side = true elseif d == 'close' then ctx.side_hide() end
  elseif t.kind == 'mxctl' then if d == 'open' then state.mx_hidden = false elseif d == 'close' then state.mx_hidden = true end
  elseif t.kind == 'rglen' then ctx.region_len_step(d)
  elseif t.kind == 'rgbtn' then ctx.region_btn(d)
  elseif t.kind == 'viewbtn' and d == 'fxparams' then
    state.fxparams = not state.fxparams; reaper.SetExtState(EXT, 'fxparams', state.fxparams and '1' or '0', true); ctx.hdr_cache = {}; relayout()
  elseif t.kind == 'viewbtn' and d == 'session' then ctx.clips_toggle()
  elseif t.kind == 'viewbtn' and d == 'effects' then state.fxrow = not state.fxrow; reaper.SetExtState(EXT, 'fxrow', state.fxrow and '1' or '0', true); relayout()
  elseif t.kind == 'viewbtn' then ctx.view_reg(d == 'reg')
  elseif t.kind == 'lanebtn' then ctx.lane_subs(d.col, d.lane, d.d, d.n)
  elseif t.kind == 'fxcolbtn' then ctrl_action('fx', d.d)
  elseif t.kind == 'envpm' then if d.d > 0 then ctx.automation_picker(d.col) else ctx.env_hide(d.e) end
  elseif t.kind == 'poolbsync' then ctx.bsync_toggle()
  elseif t.kind == 'poolsortcol' then state.poolsort = (d == 'index') and (state.poolsort == 'track' and 'mark' or 'track') or d
  elseif t.kind == 'poolsort' then state.poolsort = ({ track = 'len', len = 'mark', mark = 'track' })[state.poolsort or 'track'] or 'track'; vim.msg = 'instrument order: ' .. state.poolsort
  elseif t.kind == 'samplenorm' then local e = SL.entry or (cur_col() and cur_col().pool[vim.inst]); if e and e.item then edit.normalize(e.item); vim.msg = 'normalized (peak 0 dB)' end
  elseif t.kind == 'samplevol' then local e = SL.entry or (cur_col() and cur_col().pool[vim.inst]); if e and e.item then edit.item_vol(e.item, 0); e.vol = 1; vim.msg = 'vol 0 dB' end
  elseif t.kind == 'mxname' then ctx.mx_name_prompt(d)
  elseif t.kind == 'mxdur' then ctx.mx_len_prompt(d)
  elseif t.kind == 'tab' then state.toptab = d; ctx.set_focus('top')
  elseif t.kind == 'scopemode' then ctx.scopemode(d)
  elseif t.kind == 'sampleview' then SL.view = d
  elseif t.kind == 'mm' then ctx.set_focus('top'); state.toptab = 'modulation'; MMX.row, MMX.col = d.row, d.col
  elseif t.kind == 'monobtn' then ctx.mono_take(d == 'take')
  elseif t.kind == 'retrobtn' then
    ctx.set_focus('top')
    if d == 'prev' then ctx.retro_cycle(-1) elseif d == 'next' then ctx.retro_cycle(1) elseif d == 'all' then ctx.retro_all()
    elseif d == 'play' then retro_preview(true) elseif d == 'stop' then retro_preview(false)
    elseif d == 'put' then retro_put('cursor') elseif d == 'depot' then retro_put('depot') elseif d == 'loop' then retro_loop() elseif d == 'add' then ctx.retro_add() end
  elseif t.kind == 'retro' then ctx.set_focus('top'); state.toptab = 'retro'
  elseif t.kind == 'recbtn' then ctx.set_focus('top'); state.toptab = state.toptab == 'retro' and 'sample' or 'retro'
  elseif t.kind == 'ctrl' then ctrl_action(d, 0)
  elseif t.kind == 'pool' and d == 'auto' then ctx.set_focus('inst'); ctx.auto_select()
  elseif t.kind == 'pool' then ctx.set_focus('inst'); pool_select(d)
  elseif t.kind == 'slice' then
    ctx.set_focus('slices')
    local root = ctx.slice_root()
    if root then ctx.ssel.item = root.item; ctx.ssel.k = 0; ctx.slice_step(d) end
  elseif t.kind == 'midirow' then state.toptab = 'midi'; ctx.set_focus('top'); MM.cur = d
  elseif t.kind == 'prevbtn' then state.poolprev = not state.poolprev
  elseif t.kind == 'insprevbtn' then state.preview = not state.preview; vim.msg = 'play on insert ' .. (state.preview and 'on' or 'off')
  elseif t.kind == 'swapbtn' then ctx.swap_click()
  elseif t.kind == 'mod' then ctx.set_focus('top'); ctx.mod_toggle(d.col, d.m, d.what)
  elseif t.kind == 'dsp' then ctx.set_focus('dsp'); dsp_sel.fx = d.fx; dsp_sel.param = 1
  elseif t.kind == 'dspparam' then ctx.set_focus('dsp'); dsp_sel.fx = d.fx; dsp_sel.param = d.param
  elseif t.kind == 'browser' then ctx.set_focus('browser'); B.cur = d
  elseif t.kind == 'browserbtn' then B.click(d)
  elseif t.kind == 'sess' then
    -- session (6 окт): f + метка — клип; после F — вся сцена ряда
    if MX.SS.scene_mode then MX.SS.scene(d.ri, seq, ctx.ss_G(), #ctx.ss_V().cols) else MX.SS.launch(d.ri, d.ci, seq) end
    MX.SS.scene_mode = false; MX.SS.cur.ri, MX.SS.cur.ci = d.ri, d.ci
  elseif t.kind == 'sprop' then ctx.set_focus('top'); state.toptab = 'sample'; SPROP.sel = d   -- параметр сэмпла (8 окт: метки были, прыжка не было)
  elseif t.kind == 'sessrow' then MX.SS.scene_mode = false; MX.SS.cur.ri = d; MX.SS.scene(d, seq, ctx.ss_G(), #ctx.ss_V().cols)
  elseif t.kind == 'ssplay' then MX.SS.launch(d.ri, d.ci, seq)
  elseif t.kind == 'ssrecbtn' then if ctx.ss_record then ctx.ss_record(d.ri, d.ci) end
  elseif t.kind == 'hdrparam' then ctx.hdr_pick('fx', d.col, d.k)
  elseif t.kind == 'trkio' then ctx.track_io(d.col, d.what)   -- ø фазы в шапке (8 окт)
  elseif t.kind == 'hdrfx' or t.kind == 'hdrinst' or t.kind == 'hdrsend' then ctx.hdr_pick(t.kind == 'hdrfx' and 'fx' or (t.kind == 'hdrinst' and 'inst' or 'send'), d.col, d.k)
  end
end

-- ── контекстное меню (правый клик) ────────────────────────────────────────
-- Пункты зависят от зоны: событие / пустая ячейка / выделение / заголовок
-- трека / матрица / пул. Разделителей нет — индексы gfx.showmenu прямые.
function track_actions(col)
  local tr = col.track
  return {
    { 'Mute track', key = 'm', fn = function() edit.run('track mute', function() reaper.SetMediaTrackInfo_Value(tr, 'B_MUTE', reaper.GetMediaTrackInfo_Value(tr, 'B_MUTE') == 1 and 0 or 1) end) end },
    { 'Solo track', key = 's', fn = function() edit.run('track solo', function() reaper.SetMediaTrackInfo_Value(tr, 'I_SOLO', reaper.GetMediaTrackInfo_Value(tr, 'I_SOLO') > 0 and 0 or 1) end) end },
    { (state.folds[col.guid] and 'Unfold' or 'Fold') .. ' track (za)', key = 'f', fn = function() ctx.fold(col, not state.folds[col.guid]) end },
    { 'Select track in REAPER', key = 'l', fn = function() reaper.SetOnlyTrackSelected(tr) end },
    { 'CC lane (ReaControlMIDI, :cc)', key = 'c', fn = function() ctx.cc_lane() end },
    { (state.pitchmodes[col.guid] == 'resample' and '!' or '') .. 'Pitch mode: resample', key = 'r', fn = function() ctx.set_pitchmode(col, 'resample') end },
    { (state.pitchmodes[col.guid] ~= 'resample' and '!' or '') .. 'Pitch mode: shift', key = 'h', fn = function() ctx.set_pitchmode(col, 'shift') end },
  }
end
-- mute-track пункт: fn в поле .fn (см. выше), остальные — тоже


function region_actions(rg)
  if not rg then return {} end
  return {
    { 'Queue / play region (Space)', key = 'q', fn = function() ctx.region_space(rg) end },
    { 'Jump now', key = 'j', fn = function() reaper.SetEditCurPos(rg.pos, false, true) end },
    { 'Mute cell (M)', key = 'm', fn = function() MX.toggle_mute(seq, snap) end },
    { 'Next pattern in slot (>)', key = 'n', fn = function() for i, r in ipairs(seq) do if r.idx == rg.idx then ctx.slot_cycle(i, 1) end end end },
    { 'Previous pattern in slot (<)', key = 'b', fn = function() for i, r in ipairs(seq) do if r.idx == rg.idx then ctx.slot_cycle(i, -1) end end end },
    { 'Yank pattern (y)', key = 'y', fn = function() ctx.alias_yank(rg) end },
    { 'Alias: linked repeat to the right (A)', key = 'a', fn = function() ctx.region_btn('alias') end },
    { 'Duplicate: free copy to the right (yp)', key = 'c', fn = function() ctx.region_btn('clone') end },
    { 'Make unique: unlink this repeat (U)', key = 'u', fn = function() for i, r in ipairs(seq) do if r.idx == rg.idx then ctx.slot_unique(i) end end end },
    { 'Paste pattern copy at end (p)', key = 'p', fn = function() ctx.alias_paste() end },
    { 'Sync this pattern', key = 's', fn = function() edit.run('sync ' .. rg.name, function() alias.sync(regions, rg) end) end },
    { 'Matrix zoom (z)', key = 'z', fn = ctx.mx_zoom },
  }
end

-- действия над событием/выделением у курсора (или hover): {label, fn, key}
function event_actions(hover)
  local lpb = state.lpb
  local sel = vim.mode == 'visual' or vim.mode == 'vline'
  local out = {}
  local function add(label, fn, key) out[#out + 1] = { label, fn = fn, key = key } end
  -- automation item под курсором (6 окт): открыть, удалить, пуловая копия
  do
    local f = L and L.flat[vim.cur.fi]
    if f and f.env and f.env.ais then
      for _, ai in ipairs(f.env.ais) do
        if vim.cur.row >= math.floor(ai.r0 + 1e-6) and vim.cur.row < ai.r1 - 1e-6 then
          local env, idx = f.env.env, ai.idx
          add('Open the automation item (Enter)', function() if ctx.ai_pick_at(vim.cur.fi, vim.cur.row) then ctx.ai_edit_open(ctx.ai_list()[ctx.ai_sel]) end end, 'o')
          add('Pooled copy right after it', function()
            local pid = reaper.GetSetAutomationItemInfo(env, idx, 'D_POOL_ID', 0, false)
            edit.run('pooled automation item copy', function()
              local i = reaper.InsertAutomationItem(env, math.floor(pid + 0.5), ai.pos + ai.len, ai.len)
              if i and i >= 0 then reaper.GetSetAutomationItemInfo(env, i, 'D_PLAYRATE', reaper.GetSetAutomationItemInfo(env, idx, 'D_PLAYRATE', 0, false), true) end
            end)
            model.invalidate()
          end, 'c')
          add('Delete the automation item', function()
            edit.run('delete automation item', function()
              for k = 0, reaper.CountAutomationItems(env) - 1 do reaper.GetSetAutomationItemInfo(env, k, 'D_UISEL', k == idx and 1 or 0, true) end
              local cmd = ctx.cmd_by_text('delete automation items') or 42086   -- Envelope: Delete automation items (по тексту — номер мог смениться)
              reaper.Main_OnCommand(cmd, 0)
            end)
            model.invalidate()
          end, 'd')
          break
        end
      end
    end
  end
  local f0, f1, r0, r1 = vim.cur.fi, vim.cur.fi, vim.cur.row, vim.cur.row
  if sel then f0, f1, r0, r1 = vim.visual_range() end
  local heads = vim.heads_in(f0, f1, r0, r1)
  local cell = hover.cell
  local head = cell and (cell.kind == 'audio' or cell.kind == 'midi') and cell or (cell and cell.of)
  if head and head.item then
    add(head.kind == 'audio' and 'Item properties' or 'Open in MIDI editor', function()
      if head.kind == 'audio' then ctx.item_props(head.item); return end          -- своя гидра (5 окт)
      select_item_in_reaper(head.item)
      reaper.Main_OnCommand(40153, 0)
    end, 'i')
    add('Select item in REAPER', function() select_item_in_reaper(head.item) end, 'l')
    if head.kind == 'audio' then
      add('Quantize the nearest peak to the row grid', function() ctx.peak_quantize() end, 'q')
      add('Move the nearest peak to ... (j k a row, Enter)', function() ctx.peak_pick() end, 'Q')
    end
  end
  local what = sel and 'selection' or 'event'
  if #heads > 0 or sel then
    add('Delete ' .. what .. ' (x)', function() vim.regs['"'] = edit.yank(heads, lpb, r0, f0); edit.delete(heads, lpb) end, 'x')
    add('Copy ' .. what .. ' (y)', function() vim.regs['"'] = edit.yank(heads, lpb, r0, f0) end, 'y')
    add('Mute ' .. what .. ' (M)', function() edit.mute(heads, lpb) end, 'm')
    add('Transpose +1 (^A)', function() edit.transpose(heads, lpb, 1) end, 't')
    add('Transpose -1 (^X)', function() edit.transpose(heads, lpb, -1) end, 'T')
    add('Transpose +12', function() edit.transpose(heads, lpb, 12) end, 'o')
    add('Transpose -12', function() edit.transpose(heads, lpb, -12) end, 'O')
  end
  add('Split at row (s)', function()
    local cov = {}
    for fi = f0, f1 do for _, h in ipairs(vim.covering(fi, vim.cur.row)) do cov[#cov + 1] = h end end
    edit.split(cov, lpb, vim.cur.row)
  end, 's')
  add('Paste here (p)', function() edit.paste(vim.regs['"'], lpb, vim.cur.row, function(dfi)
    local f = L.flat[vim.cur.fi + dfi]; if not f then return nil end
    local lane = f.lane or f.col.lanes[1]
    return { track = f.col.track, lane_idx = f.col.fixed and lane.idx or nil } end) end, 'p')
  add('Insert MIDI item (bar)', function()
    local f = L.flat[vim.cur.fi]
    if f then
      local t = edit.row_time(vim.cur.row, lpb, 0)
      edit.run('midi item', function()
        local qn = reaper.TimeMap2_timeToQN(0, t)
        local _, qms, qme = reaper.TimeMap_QNToMeasures(0, qn)
        local it = reaper.CreateNewMIDIItemInProj(f.col.track, reaper.TimeMap2_QNToTime(0, qms or qn), reaper.TimeMap2_QNToTime(0, qme or qn + 4), false)
        if f.col.fixed and f.lane then reaper.SetMediaItemInfo_Value(it, 'I_FIXEDLANE', f.lane.idx) end
      end)
    end
  end, 'n')
  return out
end

function view_actions()
  return {
    { (state.top and '!' or '') .. 'Top bar (:top)', key = 'p', fn = function() state.top = not state.top end },
    { (state.meters and '!' or '') .. 'Peak meters over tracks (:meters)', key = 'm', fn = function() state.meters = not state.meters end },
    { 'Options window', key = 'o', fn = function() ctx.options() end },
    { 'About', key = 'a', fn = function() ctx.about() end },
    { 'Remove old scope bridges (:scopes)', key = 'R', fn = ctx.toggle_scopes },
    { (state.dsp and '!' or '') .. 'DSP panel (:dsp)', key = 'D', fn = ctx.toggle_dsp },
    { 'Matrix zoom: ' .. (MX.zoom == 'detail' and 'schematic' or 'detail') .. ' (:mxzoom)', key = 'z', fn = ctx.mx_zoom },
    { 'Loop region under cursor', key = 'l', fn = function()
        local rg = alias.region_at(regions, edit.row_time(vim.cur.row, state.lpb, 0))
        if rg then reaper.GetSet_LoopTimeRange(true, true, rg.pos, rg.rgnend, false); reaper.GetSetRepeat(1) end
      end },
    { (state.side and '!' or '') .. 'Browser sidebar (:side)', key = 'b', fn = function() state.side = not state.side end },
    { (state.envs and '!' or '') .. 'Envelopes (:env)', key = 'e', fn = function() state.envs = not state.envs end },
    { 'Font +1', key = 'f', fn = function() ctx.set_font(math.max(0, (state.font or 0) + 1)) end },
    { 'Font -1', key = 'F', fn = function() ctx.set_font(math.max(0, (state.font or 0) - 1)) end },
    { 'Bitmap font', key = '0', fn = function() ctx.set_font(0) end },
    { 'FX columns +1', key = 'x', fn = function() state.fxcols = math.min(4, state.fxcols + 1) end },
    { 'FX columns -1', key = 'X', fn = function() state.fxcols = math.max(0, state.fxcols - 1) end },
    { (state.follow and '!' or '') .. 'Follow playhead (F)', key = 'w', fn = function() state.follow = not state.follow end },
    { 'Dock / fullscreen (F11)', key = 'd', fn = toggle_dock },
    { 'Help (F1)', key = 'h', fn = function() ctx.help_big() end },
    { 'Help in the browser (html)', key = 'H', fn = open_help },
    { (state.khelp and '!' or '') .. 'Help panel of the focused module', key = 'K', fn = function() ctx.toggle_help() end },
  }
end

-- контекстное меню (5 окт): в стиле трекера — гидрой у мыши, буквы по
-- смыслу (первая свободная буква подписи), «!» — отмеченный пункт (*)
-- 5 окт: контекстная гидра показывает ВСЕ хоткеи модуля — пункты зоны и
-- записи его страницы справки; хоткей пункта — отдельной яркой колонкой,
-- выбор записи справки нажимает её клавиши (очередь ctx.keyq)
ctx.CTX_NAMED = { Enter = 13, Space = 32, Esc = 27, Tab = 9, BS = 8 }
function ctx.tok_codes(t)
  if ctx.CTX_NAMED[t] then return { ctx.CTX_NAMED[t] } end
  if t:match('^%^%u$') then return { t:byte(2) - 64 } end
  if #t == 1 and t:byte() >= 33 and t:byte() <= 126 then return { t:byte() } end
  if #t == 2 and t:match('^%a%a$') then return { t:byte(1), t:byte(2) } end
end
ctx.CTX_FOCUS = { tracker = 'tracker', insert = 'tracker', matrix = 'matrix', inst = 'inst', browser = 'browser', dsp = 'dsp', fxb = 'fxb',
                    sample = 'top', modulation = 'top', midi = 'top', retro = 'top', master = 'top', pm = 'browser' }
function ctx.ctx_page(hover)
  if state.ss_big then return 'session' end
  if hover.matrix then return 'matrix' elseif hover.pool then return 'inst' elseif hover.dsp then return 'dsp'
  elseif type(hover.fxb) == 'table' then return 'fxb'
  elseif hover.row or hover.header_col then return vim.mode == 'insert' and 'insert' or 'tracker' end
  local f = state.focus
  if f == 'top' then local t = state.toptab; if t == 'clips' then return 'session' end; return (t == 'retro' or t == 'sample' or t == 'modulation' or t == 'midi' or t == 'master') and t or nil end
  if f == 'slices' then return 'sample' end
  if f == 'tracker' then return vim.mode == 'insert' and 'insert' or 'tracker' end
  if f == 'browser' and B.mode == 'pm' and B.grid and state.pmgrid and not B.pmproj then return 'pm' end
  return ctx.CTX_FOCUS[f] and f or nil
end
local function context_menu(hover, anchor)
  local items = ctx.context_items(hover) or {}
  local used, hitems, have = { ['?'] = true }, {}, {}
  local function pick_key(want, label)
    local k = want and not used[want] and want or nil
    if not k then for ch in label:lower():gmatch('%a') do if not used[ch] then k = ch; break end end end
    if not k then for ch in ('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'):gmatch('.') do if not used[ch] then k = ch; break end end end
    if k then used[k] = true end
    return k
  end
  for _, it in ipairs(items) do
    local label = it[1]
    if label ~= '--' then
      local on = label:sub(1, 1) == '!'
      if on then label = label:sub(2) end
      -- «… (Space)» → хоткей в свою колонку
      local base, hk = label:match('^(.-)%s*%(([^()]+)%)$')
      -- в скобках — хоткей, только если похоже на клавиши (одиночные, ^X, za,
      -- Space ...), а не слово вроде «bar»
      local function keyish(t) return #t <= 2 or t:match('^%^') or t:match('^[A-Z][a-z]+$') or t:match('^:') or t:match('^Shift') or t:match('^Cmd') or t:match('^Ctrl') or t:match('^Opt') end
      if hk and #hk <= 12 then
        for t in hk:gmatch('[^%s/,]+') do if not keyish(t) then hk = nil; break end end
      else hk = nil end
      if hk then label = base; for t in hk:gmatch('[^%s/]+') do have[t] = true end end
      local k = pick_key(it.key, label)
      if hk == k then hk = nil end                        -- хоткей = буква пункта: не дублировать (5 окт)
      if k then hitems[#hitems + 1] = { key = k, label = label .. (on and '  *' or ''), fn = it[2], hk = hk } end
    end
  end
  -- 6 окт: меню отдельной кнопки (preview, имя лейна огибающей) — только её
  -- пункты, без хоткеев модуля в фокусе (ПКМ на preview давал всё меню матрицы)
  local pmcard = type(hover.browser) == 'number' and B.mode == 'pm' and B.entries[hover.browser] and B.entries[hover.browser].pm and B.entries[hover.browser] or nil
  local own = hover.prevbtn and 'preview' or (hover.header_env and (hover.header_env.e.name or 'envelope')) or (pmcard and pmcard.name) or nil
  local page = (not own) and ctx.ctx_page(hover) or nil
  local P = page and KH.PAGES[page]
  if P then
    for _, e in ipairs(P.e) do
      local toks = {}
      for t in e.k:gmatch('%S+') do toks[#toks + 1] = t end
      local first = toks[1]
      local nav = e.k:match('^h j k l') or e.k:match('^hjkl') or e.k == 'j k' or e.k == 'h l' or e.k == 'gg G' or e.k == 'g G'
                  or e.k == '?' or e.k:match('^Esc') or e.k:match('^%? ')
      local codes = first and ctx.tok_codes(first)
      if codes and not nav and not have[first] then
        have[first] = true
        local k = pick_key(#first == 1 and first or nil, e.d)
        local foc = ctx.CTX_FOCUS[page]
        if k then hitems[#hitems + 1] = { key = k, label = e.d, hk = (e.k ~= k) and e.k or nil, fn = function()
          if foc and state.focus ~= foc then ctx.set_focus(foc) end
          for _, cd in ipairs(codes) do ctx.keyq[#ctx.keyq + 1] = cd end
        end } end
      end
    end
  end
  if #hitems == 0 then return end
  -- 5 окт: двойные хоткеи — нет; пока только жёлтые буквы, без колонки клавиш
  for _, it in ipairs(hitems) do it.hk = nil end
  vim.open_hydra({ title = own or (page and ('menu: ' .. (P and P.title or page))) or 'menu', items = hitems })
  state.popup_at = anchor or { kind = 'xy', x = gfx.mouse_x, y = gfx.mouse_y + 4 }
end
ctx.open_context = context_menu          -- для \ из ctx.context_key (объявлен выше этого места)
function ctx.context_items(hover)
  local items = {}
  local function add(label, fn, key) items[#items + 1] = { label, fn, key = key } end
  local sel = vim.mode == 'visual' or vim.mode == 'vline'
  local lpb = state.lpb
  if type(hover.fxb) == 'table' and hover.fxb.row then
    -- эффект в браузере (3 окт): куда добавить, избранное, нативный браузер
    FB.cur = hover.fxb.row
    local it = FB.selected()
    if it then
      local t = dsp_target()
      add('Add to ' .. (t and (t.take and ('take FX of ' .. t.name) or t.name) or 'cursor track'), function() ctx.fxb_add(it) end)
      add('Add to selected tracks', function()
        edit.run('fx add selected', function()
          for i = 0, reaper.CountSelectedTracks(0) - 1 do reaper.TrackFX_AddByName(reaper.GetSelectedTrack(0, i), it.data, false, -1) end
        end)
        FB.push_recent(it); ctx.fxb_save(); model.invalidate()
      end)
      add('Add on a new track', function()
        edit.run('fx new track', function()
          local n = reaper.CountTracks(0)
          reaper.InsertTrackAtIndex(n, true)
          local tr = reaper.GetTrack(0, n)
          reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', (FB.short(it.label)), true)
          reaper.TrackFX_AddByName(tr, it.data, false, -1)
        end)
        FB.push_recent(it); ctx.fxb_save(); model.invalidate()
      end)
      add((FB.is_fav(it) and '!' or '') .. 'Favourite', function() FB.toggle_fav(it); ctx.fxb_save() end)
      add('Native FX browser', function() reaper.Main_OnCommand(40271, 0) end)
    end
  elseif hover.hdrparam or hover.hdrfx or hover.dbparam or hover.dbnode then
    -- 8 окт: ПКМ по эффекту / параметру в строке effects и в роутере — меню
    -- эффекта и параметра (как в DSP), не общее меню вида
    local tr, fx, pi, pname, fname
    if hover.hdrparam then tr, fx, pi, pname = hover.hdrparam.track, hover.hdrparam.fx, hover.hdrparam.param, hover.hdrparam.name
    elseif hover.hdrfx then
      local c = hover.hdrfx.col; tr = c and c.track; fx = hover.hdrfx.it and hover.hdrfx.it.i
    else
      local t = dsp_target(); tr = t and not t.take and t.track
      if hover.dbparam then fx, pi, pname = hover.dbparam.addr, hover.dbparam.i, hover.dbparam.name
      else fx = hover.dbnode.addr end
    end
    if tr and fx and reaper.ValidatePtr(tr, 'MediaTrack*') then
      local _, fn = reaper.TrackFX_GetFXName(tr, fx, ''); fname = (fn or ''):gsub('^[^:]*: ', '')
      if pi then ctx.param_menu_items(tr, fx, pi, pname, add) end
      ctx.fx_menu_items(tr, fx, fname, add)
    end
  elseif hover.matrix and hover.matrix.ri then
    MX.goto_cell(seq, snap, hover.matrix.ri, hover.matrix.ci or MX.cur.ci)
    for _, a in ipairs(region_actions(seq[hover.matrix.ri])) do add(a[1], a.fn, a.key) end
  elseif type(hover.browser) == 'number' and B.mode == 'pm' and B.entries[hover.browser] and B.entries[hover.browser].pm then
    -- карточка / строка проекта pm (6 окт): своё меню
    local e = B.entries[hover.browser]
    B.cur = hover.browser
    add('open in reaper (Enter)', function() ctx.pm_open_project(e.path, e.name) end, 'o')
    if not e.daw then add('inside: tracks / samples / regions (Shift+Enter)', function() B.pm_open(e) end, 'i') end
    add('listen (Space)', function() local pth = B.pm_preview(e); if pth then ctx.preview_file(pth) else vim.msg = 'pm: no preview audio for ' .. e.name end end, 'l')
    if not e.daw then add('add as subproject at the cursor (a)', function() ctx.pm_add(e) end, 'a') end
    add('tags (T)', function() ctx.pm_tags(e) end, 't')
    add('status (s)', function() ctx.pm_status(e) end, 's')
    if B.pm_mod() then add((e.pinned and '!' or '') .. 'pin on top (p)', function() B.pm_mod().key(('p'):byte(), B, {}) end, 'p') end
    add('show in finder', function() if reaper.CF_LocateInExplorer then reaper.CF_LocateInExplorer(e.path) else vim.msg = 'pm: needs SWS' end end, 'f')
  elseif hover.prevbtn then
    -- кнопка preview (3 окт): режим прослушивания
    local function radio(m, label) add((state.prevmode == m and '!' or '') .. label, function() state.prevmode = m; vim.msg = 'preview: ' .. label end) end
    add((state.poolprev and '!' or '') .. 'Preview on select', function() state.poolprev = not state.poolprev end)
    radio('full', 'full - to the end of the item (Esc stops)')
    radio('hold', 'hold - while the mouse button is held on the row')
    radio('sec', 'first second')
  elseif hover.pool and hover.pool.auto then
    add('Select automation', function() ctx.auto_select() end)
  elseif hover.pool then
    local col = cur_col()
    add('Select instrument', function() pool_select(hover.pool.i) end)
    add('Preview', function() local e = col and col.pool[hover.pool.i]; if e then ctx.inst_preview(e, col.track) end end)
    add('Slice … (virtual)', function() ctx.open_slicer(hover.pool.i) end)
    add((state.poolprev and '!' or '') .. 'Preview on select', function() state.poolprev = not state.poolprev end)
    add('Hide top bar (:top)', function() state.top = false end)
  elseif hover.header_env then
    local e = hover.header_env.e
    add('Delete envelope ' .. (e.name or '') .. ' (whole curve)', function() edit.env_remove(e.env); vim.msg = 'envelope removed: ' .. (e.name or '') end, 'd')
    add('Clear all points', function() edit.env_clear(e.env); vim.msg = 'envelope cleared: ' .. (e.name or '') end, 'c')
  elseif hover.header_col then
    for _, a in ipairs(track_actions(hover.header_col)) do add(a[1], a.fn, a.key) end
  elseif hover.ssbig and snap then
    MX.SS.menu_items(hover, seq, ctx.ss_V(), ctx.ss_G(), add)
  elseif hover.dsp then
    -- DSP: модуляция параметра (нативные свойства REAPER) и действия с FX
    -- (модуляция — только у FX трека; у take FX меню без неё)
    local col = dsp_target()
    local f, pidx = hover.dsp.f, hover.dsp.param
    local p = pidx and f.params[pidx]
    if col and p and not col.take then
      local id = p.fx or f.i
      local function flag(what) local ok, v = reaper.TrackFX_GetNamedConfigParm(col.track, id, ('param.%d.%s.active'):format(p.i, what)); return ok and v == '1' end
      add((flag('lfo') and '!' or '') .. 'Modulate: LFO', function() edit.mod_set(col.track, id, p.i, 'lfo') end)
      add((flag('acs') and '!' or '') .. 'Modulate: audio control (ACS)', function() edit.mod_set(col.track, id, p.i, 'acs') end)
      add((flag('plink') and '!' or '') .. 'Link to parameter … (fzf)', function()
        local items = {}
        for _, g in ipairs(col.fx or {}) do
          for _, q in ipairs(g.params) do
            local src = q.fx or g.i
            if not (src == id and q.i == p.i) then items[#items + 1] = { label = g.name .. ' / ' .. q.name, data = { fx = src, param = q.i } } end
          end
        end
        vim.open_picker('link ' .. p.name .. ' to', items, function(it) edit.mod_set(col.track, id, p.i, 'plink', true, it.data.fx, it.data.param) end)
      end)
      if flag('plink') then add('Unlink parameter', function() edit.mod_set(col.track, id, p.i, 'plink', false) end) end
      add('Open parameter modulation window', function()
        -- «последний тронутый» параметр — тот, который мы только что записали
        local v = reaper.TrackFX_GetParamNormalized(col.track, id, p.i)
        reaper.TrackFX_SetParamNormalized(col.track, id, p.i, v)
        local cmd = ctx.cmd_by_text('parameter modulation/link') or ctx.cmd_by_text('parameter modulation')
        if cmd then reaper.Main_OnCommand(cmd, 0) else vim.msg = 'no modulation window action found' end
      end)
      add('Show automation envelope', function() edit.run('show envelope', function() reaper.GetFXEnvelope(col.track, id, p.i, true) end); state.envs = true; model.invalidate() end)
      add((ctx.param_in_tcp(col.track, id, p.i) and '!' or '') .. 'Show in track header (TCP, param)', function() ctx.param_tcp_toggle(col.track, id, p.i, p.name) end)
      add('--', function() end)
    end
    -- плагин внутри контейнера (6 окт): ПКМ по его колонке / строке
    local kd = col and hover.dspkid and hover.dspkid.kid
    if kd then
      add((kd.enabled and 'Bypass ' or 'Enable ') .. kd.name, function() edit.fx_bypass(col.track, kd.i) end, 'b')
      add('Open ' .. kd.name .. ' window', function() edit.fx_show(col.track, kd.i) end, 'o')
      if kd.parallel > 0 then add('Serial: after the previous plugin', function() edit.fx_parallel(col.track, kd.i, 0) end, 's')
      else add('Parallel to the previous plugin', function() edit.fx_parallel(col.track, kd.i, 1) end, 'p') end
      add('Move out of the container', function() edit.fx_move_out(col.track, kd.i, f.i); vim.msg = kd.name .. ' moved out of ' .. f.name end, 'm')
      add('Rename ' .. kd.name .. ' … (:fxname)', function() state.fxname_target = { track = col.track, addr = kd.i }; vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'fxname ' end, 'n')
      add('Remove ' .. kd.name, function() edit.fx_remove(col.track, kd.i) end, 'x')
      add('--', function() end)
    end
    if col and f and f.container then
      local k = hover.dsp.fx
      add('Unpack: plugins into the chain (dc)', function() ctx.dsp_unpack(k) end, 'u')
      add('Add fx inside … (fzf)', function()
        vim.open_picker('add fx into ' .. f.name, ctx.fx_list(), function(it)
          if edit.fx_add_into(col.track, f.i, it.data) then vim.msg = '+ ' .. it.label .. ' → ' .. f.name end
        end)
      end, 'a')
      add('Preset … (container presets)', function() ctx.dsp_preset(k, 'pick') end, 'r')
      add('All plugins serial', function() for _, c in ipairs(f.kids or {}) do edit.fx_parallel(col.track, c.i, 0) end end, 's')
      add('All plugins parallel', function() for ki, c in ipairs(f.kids or {}) do if ki > 1 then edit.fx_parallel(col.track, c.i, 1) end end end, 'l')
      add('Rename container … (:fxname)', function() state.fxname_target = { track = col.track, addr = f.i }; vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'fxname ' end, 'n')
      add('--', function() end)
    end
    if col and f then
      add((f.enabled and 'Bypass' or 'Enable') .. ' ' .. f.name, function() edit.fx_bypass(col.track, f.i) end)
      add('Open FX window', function() edit.fx_show(col.track, f.i) end)
      add('Remove FX', function() edit.fx_remove(col.track, f.i) end)
      add('Add FX … (fzf)', function() ctx.fx_picker() end)
      add((state.fxopen and '!' or '') .. 'Open the fx window after adding', function() state.fxopen = not state.fxopen; edit.open_on_add = state.fxopen; vim.msg = 'fx window after adding: ' .. (state.fxopen and 'open' or 'closed') end)
    end
  elseif hover.row and hover.fi then
    vim.cur.fi, vim.cur.row = hover.fi, hover.row.row
    if hover.field then vim.cur.field = hover.field; vim.cur.sub = hover.fsub end
    for _, a in ipairs(event_actions(hover)) do add(a[1], a.fn, a.key) end
    if hover.col then for _, a in ipairs(track_actions(hover.col)) do add(a[1], a.fn, a.key) end end
  else
    for _, a in ipairs(view_actions()) do add(a[1], a.fn, a.key) end
  end
  return items
end

-- ── кадр ──────────────────────────────────────────────────────────────────
local function fmt_pos(t)
  local b, meas = reaper.TimeMap2_timeToBeats(0, t)
  return string.format('%d.%d.%02d', meas + 1, math.floor(b) + 1, math.floor((b % 1) * 100))
end

-- осциллограф из gmem моста: 256 сэмплов кольца от указателя записи
-- gmem: основное пространство — мост скопов; шина jf_mono и буфер jf_rec
-- читаются с переключением и возвратом (attach переключает активное gmem,
-- см. память gmem-attach-single-namespace)
local GMEM_MAIN = 'jf_tracker_scope'
reaper.gmem_attach(GMEM_MAIN)
local function with_ns(ns, fn)
  reaper.gmem_attach(ns)
  local ok, a, b = pcall(fn)
  reaper.gmem_attach(GMEM_MAIN)
  if not ok then return nil end
  return a, b
end
local scope_cache = {}
local spec_cache = {}
-- 48 полос спектра слота (кадр FFT моста) и номер кадра
local function spec_read(slot)
  local v = spec_cache[slot]
  if v then return v end
  local base = slot * 512
  v = {}
  for i = 0, 47 do v[i + 1] = reaper.gmem_read(base + 260 + i) end
  spec_cache[slot] = v
  return v
end
local function spec_frame(slot) return reaper.gmem_read(slot * 512 + 259) end

-- ── запись с MIDI-входа ──────────────────────────────────────────────────
-- INSERT + трек курсора взведён (R) с MIDI-входом: ноты входа пишутся в
-- строку курсора. Аккорд (ноты, пока что-то держится) — одна строка, соседние
-- подколонки (полифония раскладывается моделью). Шаг (step) — когда отпущены
-- ВСЕ клавиши; step 0 — следующий аккорд перезапишет ту же строку. Shift при
-- первой ноте аккорда — без перезаписи (рядом). Velocity — из ноты.
-- Aftertouch (poly A0 / channel D0) и CC — в тот же MIDI-item, по времени
-- удержания от начала строки (кривая внутри длины шага).
local midiin = { seq = nil, held = {}, nheld = 0, row = nil, t0 = 0, wall0 = 0 }

-- ── MIDI learn (2 окт): ручки и пэды контроллера → слайсер ──────────────
-- Привязки — jf_tracker_midimap.lua (глобальный ExtState midimap). Ручка зоны
-- / громкости / чувствительности меняет вид сразу, а правку в проект пишет
-- одну, через полсекунды тишины (иначе каждый тик ручки — шаг undo).
MM.parse(reaper.GetExtState(EXT, 'midimap'))
local function mm_save() reaper.SetExtState(EXT, 'midimap', MM.serialize(), true) end
local mm_pend = {}            -- отложенные правки: zone = {…}, vol = { item, db }, retrans = true; t — время последнего тика
local mm_devname = {}
local function mm_dev(idx)
  if mm_devname[idx] == nil then
    local ok, nm = false, nil
    if reaper.GetMIDIInputName then ok, nm = reaper.GetMIDIInputName(idx & 0xFFFF, '') end
    mm_devname[idx] = (ok and nm) or (idx == 62 and 'virtual keyboard') or ''
  end
  return mm_devname[idx]
end
-- выбранный инструмент и (для слайса) его исходник; слайсер открыт на нужном
local function mm_entry(open)
  local col = cur_col()
  local e = col and (col.pool or {})[vim.inst]
  if not e then return nil end
  local p = e.parent
  local want = p or e
  if open and not (SL.entry and SL.entry == want) and not (SL.entry and SL.entry.file) then
    SL.open(want, col.track)
    state.top = true
    if state.toptab ~= 'midi' then state.toptab = 'sample' end
  end
  return e, p, col
end
local function mm_zone(field, a)
  local e, p, col = mm_entry(true)
  if not e then return end
  if p and e.item then
    -- слайс большого сэмпла: зона по исходнику (как треугольники мышью)
    local pr = (p.rate and p.rate ~= 0) and p.rate or 1
    local z = mm_pend.zone
    if not (z and z.e.item == e.item) then
      local a0, b0 = (e.offs - p.offs) / pr, (e.offs - p.offs + e.len * (e.rate or 1)) / pr
      z = { e = e, p = p, a = a0, b = b0, a0 = a0, b0 = b0, inst = vim.inst }
      mm_pend.zone = z
    end
    local len = p.len or 0
    local step = a.d and a.d * len / 1024 or nil
    if field == 'zone_start' then z.a = math.max(0, math.min(z.b - 0.005, SL.snap_t(step and z.a + step or a.v * len)))
    elseif field == 'zone_end' then z.b = math.min(len, math.max(z.a + 0.005, SL.snap_t(step and z.b + step or a.v * len)))
    else
      local w = z.b - z.a
      local na = step and z.a + step or a.v * (len - w)
      na = SL.snap_t(math.max(0, math.min(len - w, na)))
      z.a, z.b = na, na + w
    end
    mm_pend.t = reaper.time_precise()
    vim.msg = ('midi slice %.3f - %.3fs (%.3fs)'):format(z.a, z.b, z.b - z.a)
    return
  end
  -- целый сэмпл: выделение слайсера
  local len = SL.entry and SL.entry.len or 0
  if len <= 0 then return end
  local sa, sb = SL.span()
  sa, sb = sa or 0, sb or len
  local step = a.d and a.d * len / 1024 or nil
  if field == 'zone_start' then sa = math.max(0, math.min(sb - 0.005, SL.snap_t(step and sa + step or a.v * len)))
  elseif field == 'zone_end' then sb = math.min(len, math.max(sa + 0.005, SL.snap_t(step and sb + step or a.v * len)))
  else
    local w = sb - sa
    sa = SL.snap_t(math.max(0, math.min(len - w, step and sa + step or a.v * (len - w)))); sb = sa + w
  end
  SL.sel = { a = sa, b = sb }
  vim.msg = ('midi selection %.3f - %.3fs'):format(sa, sb)
end
local MM_TRIG = { eq2 = 'eq2', eq4 = 'eq4', eq8 = 'eq8', eq16 = 'eq16', eq32 = 'eq32', trans = 'trans', clear = 'clear', quant = 'quant', snap = 'snap', autotrim = 'autotrim' }
local function mm_apply(a)
  if a.learned then
    mm_save()
    local t = MM.BY_ID[a.learned]
    vim.msg = ('learned %s: %s%s'):format(t.label, MM.bind_text(a.bind), (t.kind == 'value' and a.bind.kind == 'cc') and ' - m: abs / rel / rel64 for endless encoders' or '')
    return
  end
  if a.eaten then return end
  local id = a.t
  if id == 'zone_start' or id == 'zone_end' or id == 'zone_move' then mm_zone(id, a)
  elseif id == 'sens' then
    mm_entry(true)
    SL.sens = math.max(0, math.min(1, a.v or (SL.sens + a.d * 0.01)))
    if SL.env then SL.detect() end
    if SL.mode and SL.mode:match('^transients') then mm_pend.retrans = true; mm_pend.t = reaper.time_precise() end
    vim.msg = ('sensitivity %.2f: %d transients'):format(SL.sens, #(SL.trans or {}))
  elseif id == 'vol' then
    local e = mm_entry(false)
    if not (e and e.item) then return end
    local cur = mm_pend.vol and mm_pend.vol.item == e.item and mm_pend.vol.db
      or ((e.vol or 1) > 0 and 20 * math.log(e.vol, 10) or -60)
    local db = a.v and (-60 + a.v * 84) or (cur + a.d * 0.5)
    db = math.max(-60, math.min(24, db))
    mm_pend.vol = { item = e.item, db = db, e = e }
    mm_pend.t = reaper.time_precise()
    vim.msg = ('volume %+.1f dB'):format(db)
  elseif id == 'inst' then
    local col = cur_col(); local n = #(col and col.pool or {})
    if n == 0 then return end
    if a.v then pool_select(1 + math.floor(a.v * (n - 1) + 0.5)) else pool_select(vim.inst + (a.d > 0 and 1 or -1)) end
  elseif id == 'pads' then
    local e, p, col = mm_entry(false)
    if not e or not col then return end
    local src = (e.slices and e) or (p and p.slices and p) or nil
    if src then
      local k = a.k
      if src.slices[k] then PV.slice(col.track, src, src.slices[k], src.slices[k + 1] or src.len); vim.msg = ('pad %d -> slice %d'):format(k, k) end
    elseif e.item then PV.audio(col.track, e.item, a.k - 1); vim.msg = ('pad %d: %+d st'):format(a.k, a.k - 1) end
  elseif MM_TRIG[id] then
    local e = mm_entry(true)
    if e then SL.button(MM_TRIG[id]); vim.msg = SL.msg ~= '' and SL.msg or id end
  elseif id == 'detect' then mm_entry(true); if SL.env then SL.detect(); vim.msg = ('%d transients'):format(#SL.trans) end
  elseif id == 'all' then mm_entry(true); SL.select_all()
  elseif id == 'view' then SL.cycle_view()
  elseif id == 'preview' then
    local e, p, col = mm_entry(false)
    local z = mm_pend.zone
    local sa, sb = SL.span()
    if z and e and z.e.item == e.item then PV.slice(col.track, p, z.a, z.b)
    elseif sa and SL.entry then ctx.preview_slice(SL.track, SL.entry, sa, sb)
    elseif e and e.item and col then PV.inst_preview(e, col.track) end
  elseif id == 'insert' then local sa, sb = SL.span(); if sa and SL.entry then ctx.drop_span_cursor(SL.entry, sa, sb) else vim.msg = 'insert: no selection' end
  elseif id == 'depot' then local sa, sb = SL.span(); if sa and SL.entry then ctx.depot_span(SL.entry, sa, sb) else vim.msg = 'to library: no selection' end
  elseif id == 'norm' then local e = mm_entry(false); if e and e.item then edit.normalize(e.item); vim.msg = 'normalized' end
  elseif id == 'inst_next' then pool_select(vim.inst + 1)
  elseif id == 'inst_prev' then pool_select(vim.inst - 1)
  elseif id == 'slicer' then state.top = true; state.toptab = 'sample'; mm_entry(true)
  elseif id == 'play' then edit.play_stop() end
end
-- learn касанием: новое касание параметра этого FX в окне плагина → в модуль
function learn_poll()
  if not dsp_learn then return end
  local ok, tn, fxn, pn = reaper.GetLastTouchedFX()
  if not ok then return end
  local key = ('%s|%s|%s'):format(tn, fxn, pn)
  if key == dsp_learn.last then return end
  dsp_learn.last = key
  if not reaper.ValidatePtr(dsp_learn.track, 'MediaTrack*') then dsp_learn = nil; return end
  local mytn = math.floor(reaper.GetMediaTrackInfo_Value(dsp_learn.track, 'IP_TRACKNUMBER'))
  if tn ~= mytn or fxn ~= dsp_learn.fx then return end
  local m = model.user_mods[dsp_learn.name]
  if not m then return end
  for _, p in ipairs(m.params) do if p.i == pn then vim.msg = 'learn: already in the module'; return end end
  local _, pname = reaper.TrackFX_GetParamName(dsp_learn.track, fxn, pn, '')
  m.params[#m.params + 1] = { i = pn, label = model.fxclass and model.fxclass.label(pname or '') or pname }
  umod_save(model.user_mods); model.invalidate()
  vim.msg = ('learn: + %s (%d in the module)'):format(pname or ('p' .. pn), #m.params)
end

-- отложенные правки ручек: через 0.5 с тишины — одна правка в проект
local function mm_settle(now)
  if not mm_pend.t or now - mm_pend.t < 0.5 then return end
  local z, v = mm_pend.zone, mm_pend.vol
  local retrans = mm_pend.retrans
  mm_pend = {}
  if z and (math.abs(z.a - z.a0) > 1e-6 or math.abs(z.b - z.b0) > 1e-6) then ctx.slice_bounds(z) end
  if v and reaper.ValidatePtr(v.item, 'MediaItem*') then edit.item_vol(v.item, v.db); v.e.vol = 10 ^ (v.db / 20) end
  if retrans and SL.entry and not SL.entry.file then SL.use_transients() end
end
local function midi_input_ok(col)
  if not col or not col.armed then return false end
  local inp = math.floor(reaper.GetMediaTrackInfo_Value(col.track, 'I_RECINPUT'))
  if inp < 0 or inp & 4096 == 0 then return false end
  return true, (inp >> 5) & 63, inp & 31        -- устройство (63 = все), канал (0 = все)
end
local function poll_midi_in()
  if not reaper.MIDI_GetRecentInputEvent then return end
  -- собрать новые события (свежие сверху → разворачиваем)
  local fresh = {}
  local i = 0
  while i < 64 do
    local seq, buf, _, dev = reaper.MIDI_GetRecentInputEvent(i)
    if not seq or seq == 0 then break end
    if midiin.seq and seq <= midiin.seq then break end
    fresh[#fresh + 1] = { seq = seq, buf = buf, dev = dev }
    i = i + 1
  end
  if #fresh == 0 then return end
  if not midiin.seq then midiin.seq = fresh[1].seq; return end   -- старт: старое не пишем
  midiin.seq = fresh[1].seq
  -- MIDI learn: привязанные CC / ноты (и learn) — не дальше (2 окт)
  do
    local rest = {}
    for k = #fresh, 1, -1 do
      local b = fresh[k].buf
      local a = MM.feed(b:byte(1), b:byte(2) or 0, b:byte(3) or 0, mm_dev(fresh[k].dev or 0))
      if a then local ok, err = pcall(mm_apply, a); if not ok then vim.msg = 'midi: ' .. tostring(err):match('[^\n]*$') end
      else table.insert(rest, 1, fresh[k]) end
    end
    fresh = rest
    if #fresh == 0 then return end
  end
  local f = L and L.flat[vim.cur.fi]
  local col = f and f.col
  -- вкладка Sample в фокусе: MIDI-вход прослушивает инструмент (2 окт). Нарезанный —
  -- C4 = слайс 1 (как q), C#4 = слайс 2…; целый сэмпл — транспонирован от C-4.
  -- Это предпросмотр через FX трека (CF_Preview), в проект ничего не пишется.
  if state.top and state.toptab == 'sample' and state.focus == 'top' then
    local e = (SL.entry and (SL.active or SL.entry.file)) and SL.entry or (col and (col.pool or {})[vim.inst])
    local tr = col and col.track
    for k = #fresh, 1, -1 do
      local b = fresh[k].buf
      local st, d1, d2 = b:byte(1), b:byte(2) or 0, b:byte(3) or 0
      if st and (st & 0xF0) == 0x90 and d2 > 0 and e and tr then
        if e.slices and #e.slices > 0 then
          local idx = d1 - model.BASE_NOTE                               -- C-4 = весь сэмпл, C#4 = слайс 1 (5 окт)
          if idx == 0 and e.item then PV.audio(tr, e.item, 0); vim.msg = 'MIDI C-4 -> the whole sample'
          elseif idx >= 1 and idx <= #e.slices then
            PV.slice(tr, e, e.slices[idx], e.slices[idx + 1] or e.len)
            vim.msg = ('MIDI %s -> slice %d'):format(model.note_name(d1), idx)
          end
        elseif e.item then PV.audio(tr, e.item, d1 - model.BASE_NOTE); vim.msg = 'MIDI ' .. model.note_name(d1)
        elseif e.file then PV.slice(tr, e, 0, e.len) end
      end
    end
    midiin.held, midiin.nheld = {}, 0
    return
  end
  local ok, want_dev, want_ch = midi_input_ok(col)
  if not (ok and vim.mode == 'insert' and state.focus == 'tracker') then midiin.held, midiin.nheld = {}, 0; return end
  local lane_idx = col.fixed and f.lane and f.lane.idx or nil
  for k = #fresh, 1, -1 do
    local e = fresh[k]
    local st, d1, d2 = e.buf:byte(1), e.buf:byte(2) or 0, e.buf:byte(3) or 0
    local kind, ch = st and (st & 0xF0), st and (st & 0x0F)
    local dev_ok = want_dev == 63 or e.dev == want_dev or e.dev == 62   -- 62 = виртуальная клавиатура
    local ch_ok = want_ch == 0 or (ch + 1) == want_ch
    -- Shift — только звук (3 окт): нота слышна через мониторинг трека, в
    -- проект ничего не пишется (как Shift+нота с клавиатуры)
    if kind and dev_ok and ch_ok and gfx.mouse_cap & 8 == 8 then
      if kind == 0x90 and d2 > 0 then vim.msg = ('MIDI %s (Shift: listen only)'):format(model.note_name(d1)) end
    elseif kind and dev_ok and ch_ok then
      if kind == 0x90 and d2 > 0 and state.auto_inst then
        -- automation как инструмент (5 окт): нота MIDI — пул со скоростью по высоте
        if ctx.ai_insert(d1, vim.cur.row) then vim.cur.row = vim.cur.row + math.max(0, vim.step or 1) end
      elseif kind == 0x90 and d2 > 0 then
        if midiin.nheld == 0 then
          -- новый аккорд: строка курсора; без Shift — перезапись того, что там стоит
          midiin.row = vim.cur.row
          midiin.t0 = edit.row_time(midiin.row, state.lpb, 0)
          midiin.wall0 = reaper.time_precise()
          if gfx.mouse_cap & 8 ~= 8 then
            local fi0, fi1 = vim.cur.fi, vim.cur.fi
            for j, g in ipairs(L.flat) do if g.col == col and not g.env then fi0 = math.min(fi0, j); fi1 = math.max(fi1, j) end end
            local heads = vim.heads_in(fi0, fi1, midiin.row, midiin.row)
            if #heads > 0 then edit.delete(heads, state.lpb) end
          end
        end
        if not midiin.held[d1] then midiin.held[d1] = true; midiin.nheld = midiin.nheld + 1 end
        -- нарезанный инструмент (4 окт): нота = слайс (C-4 = 1, хроматически)
        local inst = col.pool and col.pool[vim.inst]
        local k = inst and inst.slices and #inst.slices > 0 and (d1 - model.BASE_NOTE + 1) or nil
        if k and k >= 1 and k <= #inst.slices then
          edit.insert_slice(col.track, lane_idx, state.lpb, midiin.row, inst.item, k)
          vim.last_slice = k
          vim.msg = ('rec %s = slice %d'):format(model.note_name(d1), k)
        else
          edit.rec_note(col.track, lane_idx, state.lpb, midiin.row, d1, d2, math.max(1, vim.step))
          vim.msg = ('rec %s vel %d'):format(model.note_name(d1), d2)
        end
      elseif kind == 0x80 or (kind == 0x90 and d2 == 0) then
        if midiin.held[d1] then midiin.held[d1] = nil; midiin.nheld = math.max(0, midiin.nheld - 1) end
        if midiin.nheld == 0 and midiin.row then
          vim.cur.row = midiin.row + vim.step                  -- шаг после отпускания всех клавиш
          if vim.cur.row >= state.row0 + L.nrows - 1 then state.row0 = vim.cur.row - math.floor(L.nrows / 3) end
        end
      elseif (kind == 0xA0 or kind == 0xD0 or kind == 0xB0) and midiin.nheld > 0 and midiin.row then
        local len = edit.row_time(midiin.row + math.max(1, vim.step), state.lpb, 0) - midiin.t0
        local t = midiin.t0 + math.min(len * 0.999, reaper.time_precise() - midiin.wall0)
        edit.rec_cc(col.track, lane_idx, t, kind, ch, d1, d2)
      end
    end
  end
  model.invalidate()
end

-- ── запись с аудиовхода через jf_rec (INSERT + R, на треке стоит jf_rec) ──
-- Детектор по экранному слою пиков буфера: звук поднялся выше порога —
-- атака (первый транзиент); тишина дольше AUD_GAP — конец фразы. Кусок
-- [атака − предзапись, конец] уходит в почтовый ящик jf_rec и встаёт item'ом
-- в строку курсора (pitch 0, rate 1 — базовая нота C-4). Шаг — после куска;
-- step 0 — следующий кусок перезапишет строку; Shift в момент атаки — рядом.
-- Экспорт печатает сам плагин (в своём @gfx) — его панель должна быть видна.
local AUD_THR, AUD_GAP, AUD_PRE = 0.08, 0.25, 0.01
-- export_buffer_to_project в jf_rec кладёт item к edit-курсору и делает это в
-- СВОЁМ кадре (@gfx), позже заказа. Поэтому заказ запоминает items трека, а
-- кадр трекера ловит новый item и ставит его точно в нужную позицию.
local put_pending = {}
local function expect_put(track, pos, loop_len, to_lib)
  local before = {}
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do before[reaper.GetTrackMediaItem(track, i)] = true end
  put_pending[#put_pending + 1] = { track = track, pos = pos, before = before, t = reaper.time_precise(), loop = loop_len, lib = to_lib }
end
local function settle_puts(now)
  for k = #put_pending, 1, -1 do
    local p = put_pending[k]
    local found
    if reaper.ValidatePtr(p.track, 'MediaTrack*') then
      for i = 0, reaper.CountTrackMediaItems(p.track) - 1 do
        local it = reaper.GetTrackMediaItem(p.track, i)
        if not p.before[it] then found = it; break end
      end
    end
    if found then
      reaper.SetMediaItemInfo_Value(found, 'D_POSITION', p.pos)
      local tk = reaper.GetActiveTake(found)
      if tk then reaper.SetMediaItemTakeInfo_Value(tk, 'D_PITCH', 0); reaper.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', 1) end
      -- ретро-луп: кусок N тактов повторяется до заданной длины
      if p.loop then
        reaper.SetMediaItemInfo_Value(found, 'B_LOOPSRC', 1)
        reaper.SetMediaItemInfo_Value(found, 'D_LENGTH', p.loop)
      end
      -- 8 окт: в библиотеку — jf_rec печатает на свой трек за концом проекта,
      -- отсюда item переезжает в свой лейн трека LIB (владелец — этот трек)
      if p.lib then
        edit.run('retro to lib', function()
          local ltr, lane = edit.lib_slot()
          reaper.MoveMediaItemToTrack(found, ltr)
          edit.lib_mark(found, p.track, lane)
        end)
      end
      reaper.UpdateArrange(); model.invalidate()
      table.remove(put_pending, k)
    elseif now - p.t > 4 then
      vim.msg = 'jf_rec did not print the take - open its panel (TCP embed or window)'
      table.remove(put_pending, k)
    end
  end
end
local audin = { state = 'idle', onset = nil, last_loud = 0, shift = false, width = 1000 }
local function poll_audio_in(now)
  local f = L and L.flat[vim.cur.fi]
  local col = f and f.col
  if not (col and col.armed and col.rec_slot and vim.mode == 'insert' and state.focus == 'tracker') then
    audin.state = 'idle'; return
  end
  local inp = math.floor(reaper.GetMediaTrackInfo_Value(col.track, 'I_RECINPUT'))
  if inp >= 0 and inp & 4096 ~= 0 then return end              -- MIDI-вход — пишет poll_midi_in
  local head, len, srate, amp, W
  with_ns('jf_rec', function()
    if math.floor(reaper.gmem_read(26)) ~= col.rec_slot then reaper.gmem_write(26, col.rec_slot) end
    W = math.floor(reaper.gmem_read(4)); if W < 16 then W = audin.width; reaper.gmem_write(4, W) end
    head, len, srate = reaper.gmem_read(2) or 0, reaper.gmem_read(1) or 40, reaper.gmem_read(0) or 48000
    -- уровень у головы: последние 2 столбца слоя перед головой
    local hi = math.floor(head * W)
    amp = 0
    for k = 1, 2 do
      local i = (hi - k) % W
      amp = math.max(amp, math.abs(reaper.gmem_read(1000000 + i) or 0), math.abs(reaper.gmem_read(1050000 + i) or 0))
    end
  end)
  if not head or len <= 0 then return end
  -- превью трекера идёт через FX трека — jf_rec его слышит; это не игра:
  -- пока звучит превью (и полсекунды хвоста) и пока зажат Shift — не пишем (3 окт)
  -- и пока проект играет (3 окт): jf_rec слышит проигрывание самого трека —
  -- принимал его за игру на входе и печатал куски (пробел, play, «rec audio»)
  if PV.playing() or gfx.mouse_cap & 8 == 8 or reaper.GetPlayState() & 1 == 1 then audin.mute_until = now + 0.5 end
  if now < (audin.mute_until or 0) then
    if audin.state == 'sound' then audin.state = 'idle'; vim.msg = 'rec audio: preview / Shift - not recorded' end
    return
  end
  if audin.state == 'idle' then
    if amp >= AUD_THR then
      audin.state = 'sound'
      audin.onset = (head - (2 / W) - AUD_PRE / len) % 1      -- первый транзиент (с предзаписью)
      audin.last_loud = now
      audin.shift = gfx.mouse_cap & 8 == 8
      audin.row = vim.cur.row
      vim.msg = 'rec audio: sound…'
    end
  elseif audin.state == 'sound' then
    if amp >= AUD_THR * 0.4 then audin.last_loud = now end
    if now - audin.last_loud >= AUD_GAP then
      -- конец фразы: от атаки до последнего громкого места
      local stop = (head - (now - audin.last_loud) / len) % 1
      local span = (stop - audin.onset) % 1
      local ring_n = len * srate
      local start, samps = math.floor(audin.onset * ring_n), math.floor(span * ring_n)
      if samps > 0.02 * srate then
        if not audin.shift then
          local fi0, fi1 = vim.cur.fi, vim.cur.fi
          for j, g in ipairs(L.flat) do if g.col == col and not g.env then fi0 = math.min(fi0, j); fi1 = math.max(fi1, j) end end
          local heads = vim.heads_in(fi0, fi1, audin.row, audin.row)
          if #heads > 0 then edit.delete(heads, state.lpb) end
        end
        local pos = edit.row_time(audin.row, state.lpb, 0)
        local tnum = math.floor(reaper.GetMediaTrackInfo_Value(col.track, 'IP_TRACKNUMBER')) - 1
        expect_put(col.track, pos)
        with_ns('jf_rec', function()
          reaper.gmem_write(11, tnum); reaper.gmem_write(12, pos)
          reaper.gmem_write(13, start); reaper.gmem_write(14, samps); reaper.gmem_write(15, 0)
          reaper.gmem_write(10, 1)
        end)
        vim.msg = ('rec audio: %.2fs → %s @ %04d (jf_rec prints it)'):format(samps / srate, col.name, audin.row)
        vim.cur.row = audin.row + vim.step
        if vim.cur.row >= state.row0 + L.nrows - 1 then state.row0 = vim.cur.row - math.floor(L.nrows / 3) end
        model.invalidate()
      end
      audin.state = 'idle'
    end
  end
end

-- ── шина jf_mono (демон jf_grid): [0] hb [1] владелец [2] запрос [3] grid [4] arc ──
local MONO_NAMES = { [1] = 'reel', [2] = 'looper', [4] = 'slixer', [5] = 'arcloop', [7] = 'phatfx', [8] = 'angle', [9] = 'tracker' }
local mono = { t = 0, hb = -1, hb_t = 0, alive = false, grid = false, arc = false, owner = 0, leds = nil }
local function mono_leds()
  local rows = {}
  for y = 1, 8 do rows[y] = {}; for x = 1, 16 do rows[y][x] = 0 end end
  if #seq == 0 or not snap then rows[8][16] = 2; return rows end
  local playing = reaper.GetPlayState() & 1 == 1
  local col = cur_col()
  rows[8][1] = playing and 15 or 5; rows[8][2] = 4
  rows[8][3] = (col and col.armed) and 12 or 3
  rows[8][4] = state.follow and 10 or 3
  rows[8][5] = reaper.GetSetRepeat(-1) == 1 and 10 or 3
  for x = 7, 14 do rows[8][x] = 3 end
  local grid = MX.grid(snap, seq)
  local cri = MX.cur.ri
  local scroll = math.max(0, cri - 7)
  local pp = playing and reaper.GetPlayPosition() or nil
  for y = 1, 7 do
    local ri = scroll + y
    if ri > #seq then break end
    local rg = seq[ri]
    local play_ri = pp and pp >= rg.pos and pp < rg.rgnend
    local q = MX.queued and MX.queued.idx == rg.idx
    for x = 1, math.min(15, #snap.cols) do
      local g = grid[ri] and grid[ri][x]
      local v = g and ((g.state == 'has') and 6 or (g.state == 'muted' and 3 or 1)) or 1
      if play_ri then v = 12 end
      if q then v = 9 end
      if ri == cri and x == MX.cur.ci then v = 15 end
      rows[y][x] = v
    end
  end
  return rows
end
local function mono_read()
  local now = reaper.time_precise()
  if now - mono.t < 0.25 then return mono end
  mono.t = now
  local hb, owner, g, a = with_ns('jf_mono', function()
    return reaper.gmem_read(0), reaper.gmem_read(1), reaper.gmem_read(3), reaper.gmem_read(4)
  end)
  if hb and hb ~= mono.hb then mono.hb = hb; mono.hb_t = now end
  mono.alive = (now - mono.hb_t) < 2.0 and mono.hb_t > 0
  mono.grid, mono.arc = g == 1, a == 1
  mono.owner = math.floor(owner or 0)
  mono.owner_name = MONO_NAMES[mono.owner] or (mono.owner == 0 and 'GRID' or tostring(mono.owner))
  mono.owner_id = mono.owner
  mono.leds = mono_leds()
  mono.cols = {}
  for i, c in ipairs(snap and snap.cols or {}) do mono.cols[i] = c.name end
  return mono
end
-- запрос владения поверхностью: 9 — трекер, -1 — вернуть в GRID
function mono_request(id)
  with_ns('jf_mono', function() reaper.gmem_write(2, id) end)
  vim.msg = id == MONO_ID and 'mono: requested surface for tracker' or 'mono: surface back to GRID'
end

-- ── ретро-сэмплер jf_rec: карта gmem см. Effects/jf_rec.jsfx ─────────────
-- Владелец зеркала — слот, записанный в gmem[26]; экранный слой шириной
-- gmem[4] лежит в 1000000 (max) / 1050000 (min) по индексу кольца; почтовый
-- ящик вставки 10..15 (трек, позиция, старт/длина в сэмплах), превью 16..18.
local function retro_tracks()
  local out = {}
  for _, col in ipairs(snap and snap.cols or {}) do if col.rec_slot then out[#out + 1] = col end end
  return out
end
function retro_current()
  local trs = retro_tracks()
  if #trs == 0 then retro.cur = nil; return nil, trs end
  local col = retro.cur and retro.cur.col
  local found
  for i, c in ipairs(trs) do if col and c.guid == col.guid then found = i end end
  if not found then
    found = 1
    local cc = cur_col()
    for i, c in ipairs(trs) do if cc and c.guid == cc.guid then found = i end end
  end
  retro.cur_i = found
  return trs[found], trs
end
local function retro_read(width)
  local col, trs = retro_current()
  if not col then return { tracks = trs, cur = nil, sel = retro.sel, msg = retro.msg } end
  local now = reaper.time_precise()
  local c = retro.cur
  if not c or c.col ~= col then c = { col = col, slot = col.rec_slot, len = 40, srate = 48000, head = 0, writing = false, alive = false, peaks = nil }; retro.cur = c end
  with_ns('jf_rec', function()
    if math.floor(reaper.gmem_read(26)) ~= c.slot then
      reaper.gmem_write(26, c.slot); c.peaks = nil; return   -- экземпляр опубликует картину на следующем блоке
    end
    reaper.gmem_write(4, width)
    c.srate = reaper.gmem_read(0) > 0 and reaper.gmem_read(0) or 48000
    c.len = reaper.gmem_read(1) > 0 and reaper.gmem_read(1) or 40
    c.head = reaper.gmem_read(2) or 0
    c.writing = reaper.gmem_read(3) == 1
    local al = reaper.gmem_read(30)
    if al == 1 then retro.alive_t = now; reaper.gmem_write(30, 0) end
    c.alive = (now - retro.alive_t) < 1.5
    local ring_n = c.len * c.srate
    local pbpos = reaper.gmem_read(19) or 0
    c.pb = (pbpos > 0 and ring_n > 0) and (((pbpos / ring_n) - c.head) % 1) or nil
    -- экранный слой: раз в 2 кадра, индекс кольца → развёртка: старое слева, голова справа
    if now - retro.peaks_t > 0.06 then
      retro.peaks_t = now
      local W = math.floor(width)
      local hi = math.floor(c.head * W)
      local pk = { n = W, max = {}, min = {} }
      for i = 0, W - 1 do
        local x = (i - hi - 1) % W
        pk.max[x + 1] = reaper.gmem_read(1000000 + i) or 0
        pk.min[x + 1] = reaper.gmem_read(1050000 + i) or 0
      end
      c.peaks = pk
    end
    if retro.put_t and reaper.gmem_read(10) >= 0.5 and now - retro.put_t > 1.0 then
      retro.msg = 'jf_rec: export runs in its UI - open the plugin panel (TCP embed / window)'
    elseif retro.put_t and reaper.gmem_read(10) < 0.5 then retro.put_t = nil; model.invalidate() end
  end)
  c.playing = retro.pb_t > 0 and (now - retro.pb_t) < c.len * math.abs(retro.sel.b - retro.sel.a) + 0.1
  return { tracks = trs, cur = c, sel = retro.sel, msg = retro.msg, loop_bars = retro.loop_bars }
end
-- выделение → старт и длина в сэмплах кольца
local function retro_span()
  local c = retro.cur; if not c then return end
  local a, b = retro.sel.a, retro.sel.b
  if b < a then a, b = b, a end
  local ring_n = c.len * c.srate
  local start = math.floor(((c.head + a) % 1) * ring_n)
  local samps = math.floor((b - a) * ring_n)
  return start, samps, c
end
function retro_preview(on)
  local start, samps, c = retro_span(); if not c then return end
  with_ns('jf_rec', function()
    if on then reaper.gmem_write(17, start); reaper.gmem_write(18, math.max(1, samps)); reaper.gmem_write(16, 1)
    else reaper.gmem_write(16, 2) end
  end)
  retro.pb_t = on and reaper.time_precise() or 0
end
-- вставка куска: 'cursor' — трек буфера в строку курсора; 'depot' — после =LIB
-- первый транзиент внутри выделения (по экранному слою пиков): доля кольца
local function retro_first_transient()
  local c = retro.cur; if not c or not c.peaks then return nil end
  local pk = c.peaks
  local a, b = retro.sel.a, retro.sel.b
  if b < a then a, b = b, a end
  local i0, i1 = math.floor(a * pk.n) + 1, math.min(pk.n, math.floor(b * pk.n))
  local peak = 0
  for i = i0, i1 do peak = math.max(peak, math.abs(pk.max[i] or 0), math.abs(pk.min[i] or 0)) end
  if peak < 0.01 then return nil end
  local thr = math.max(0.02, peak * 0.25)
  for i = i0, i1 do
    if math.max(math.abs(pk.max[i] or 0), math.abs(pk.min[i] or 0)) >= thr then return (i - 1) / pk.n end
  end
end

function retro_put(target, raw, at_pos, loop_len)
  -- в строку курсора — с первого транзиента выделения (атака ровно на строке);
  -- raw / депо — как выделено
  if target == 'cursor' and not raw then
    local ft = retro_first_transient()
    if ft and ft > retro.sel.a + 1e-4 and ft < retro.sel.b then retro.sel.a = ft end
  end
  local start, samps, c = retro_span(); if not c then vim.msg = 'retro: no buffer'; return end
  if samps < 1 then vim.msg = 'retro: empty selection'; return end
  local tr = c.col.track
  local pos
  if target == 'depot' then
    pos = reaper.GetProjectLength(0) + 4   -- 8 окт: печать за концом проекта, потом — в лейн трека LIB
  else
    pos = at_pos or edit.row_time(vim.cur.row, state.lpb, 0)
  end
  local tnum = math.floor(reaper.GetMediaTrackInfo_Value(tr, 'IP_TRACKNUMBER')) - 1
  expect_put(tr, pos, loop_len, target == 'depot')
  with_ns('jf_rec', function()
    reaper.gmem_write(11, tnum); reaper.gmem_write(12, pos)
    reaper.gmem_write(13, start); reaper.gmem_write(14, samps); reaper.gmem_write(15, 0)
    reaper.gmem_write(10, 1)
  end)
  retro.put_t = reaper.time_precise()
  retro.msg = ('retro: %.2fs → %s @ %.2fs'):format(samps / c.srate, target == 'depot' and 'lib (track LIB)' or c.col.name, pos)
  vim.msg = retro.msg
end
-- ретро-лупер (2 окт): «подхватить уже сыгранное и лупить». Во время игры
-- берёт из кольца jf_rec последние N тактов, кончающиеся на последней
-- границе такта перед плейхедом, и ставит их с ближайшей следующей границы
-- такта зацикленным item: до конца региона плейхеда, иначе 4 повтора.
-- Длина куска — ровно N тактов по темпу, поэтому стык лупа в такт.
retro.loop_bars = 2
function retro_loop(bars)
  bars = bars or retro.loop_bars
  local c = retro.cur
  if not c then vim.msg = 'retro loop: no jf_rec buffer (a in the retro tab adds one)'; return end
  if not playing() then vim.msg = 'retro loop: play first - it loops what was just played'; return end
  local now = reaper.GetPlayPosition2()             -- блок, который пишет jf_rec
  local qn = reaper.TimeMap2_timeToQN(0, now)
  local _, qms, qme = reaper.TimeMap_QNToMeasures(0, qn)
  if not (qms and qme and qme > qms) then vim.msg = 'retro loop: no bar grid here'; return end
  local bar_qn = qme - qms
  local t_end = reaper.TimeMap2_QNToTime(0, qms)
  local t_start = reaper.TimeMap2_QNToTime(0, qms - bars * bar_qn)
  local dur = t_end - t_start
  local back = now - t_end
  if dur + back > c.len - 0.05 then vim.msg = ('retro loop: %d bars do not fit the %ds buffer'):format(bars, c.len); return end
  retro.sel.b = 1 - back / c.len
  retro.sel.a = retro.sel.b - dur / c.len
  -- куда: следующая граница такта; длина — до конца региона, иначе 4 повтора
  local pos = reaper.TimeMap2_QNToTime(0, qme)
  local rg = alias.region_at(regions, now)
  local total = (rg and rg.rgnend > pos + dur * 0.5) and (rg.rgnend - pos) or (dur * 4)
  retro_put('cursor', true, pos, total)
  vim.msg = ('retro loop: last %d bar%s of %s -> loop from %.2fs, %.2fs long'):format(bars, bars == 1 and '' or 's', c.col.name, pos, total)
end

local function scope_read(slot)
  local v = scope_cache[slot]
  if v then return v end
  local base = slot * 512
  local wp = math.floor(reaper.gmem_read(base + 256))
  v = {}
  for i = 0, 255 do v[i + 1] = reaper.gmem_read(base + ((wp + i) % 256)) end
  scope_cache[slot] = v
  return v
end

-- пик-метры треков: Track_GetPeakInfo раз в кадр на трек
local peak_cache = {}
local function track_peaks(col)
  local v = peak_cache[col]
  if not v then
    v = { reaper.Track_GetPeakInfo(col.track, 0), reaper.Track_GetPeakInfo(col.track, 1) }
    peak_cache[col] = v
  end
  return v[1], v[2]
end

-- клик / колесо по контролу верхней панели
function ctrl_action(name, delta)
  ctx.dlog(('ctrl %s %s'):format(tostring(name), tostring(delta)))
  -- вкладки проектов (8 окт): строка над главным модулем, щелчок — переключить
  local pti = tostring(name):match('^ptab:(%d+)$')
  if pti then
    local proj = reaper.EnumProjects(tonumber(pti))
    if proj and delta == 0 then reaper.SelectProjectInstance(proj); vim.msg = 'project tab ' .. (tonumber(pti) + 1) end
    return
  end
  -- общая клетка быстрых опций (6 окт): тумблер — переключить, выбор — следующее значение
  local qi = ctx.qitems and ctx.qitems[name]
  if qi then
    if qi.kind == 'toggle' then qi.set(not qi.get())
    elseif qi.kind == 'cycle' and qi.values then
      local cur, k = qi.get(), 1
      for i, v in ipairs(qi.values) do if v == cur then k = i end end
      qi.set(qi.values[(k + ((delta or 0) < 0 and -2 or 0)) % #qi.values + 1])
    end
    relayout(); vim.msg = qi.label .. ': ' .. tostring(qi.get())
    return
  end
  local col = cur_col()
  if name == 'options' then if delta == 0 then ctx.options() end
  elseif name == 'about' then if delta == 0 then ctx.about() end
  elseif name == 'tutorial' then if delta == 0 then ctx.tutorial() end
  elseif name == 'screensets' then if delta == 0 then vim.open_hydra(ctx.screensets_hydra()); state.popup_at = { kind = 'ctrlbtn', name = 'screensets' } end
  -- быстрые вкл / выкл главного модуля (4 окт)
  elseif name == 'q_dsp' then if delta == 0 then ctx.toggle_dsp() end
  elseif name == 'q_side' then if delta == 0 then state.side = not state.side end
  elseif name == 'q_mx' then if delta == 0 then state.mx_hidden = not state.mx_hidden end
  elseif name == 'q_envs' then if delta == 0 then ctx.toggle_envs() end
  elseif name == 'q_scopes' then if delta == 0 then ctx.toggle_scopes() end
  elseif name == 'q_hints' then if delta == 0 then state.hints = not state.hints end
  elseif name == 'q_keys' then if delta == 0 then state.keycast = not state.keycast; ctx.kc = {} end
  elseif name == 'q_listen' then if delta == 0 then state.steplisten = not state.steplisten; vim.msg = 'step listen ' .. (state.steplisten and 'on: moving the cursor plays the row' or 'off') end
  elseif name == 'q_sidel' or name == 'q_sider' then   -- browser < > (7 окт): браузер слева над… под матрицей / справа
    if delta == 0 then
      state.browserleft = name == 'q_sidel'; state.side = true
      reaper.SetExtState(EXT, 'browserleft', state.browserleft and '1' or '0', true)
      relayout(); vim.msg = 'browser ' .. (state.browserleft and 'left, under the matrix (instruments stay on the right)' or 'right, under the instruments')
    end
  elseif name == 'q_mixup' or name == 'q_mixdn' then   -- mixer ^ v (8 окт): микшер над трекером (в шапке) / под ним
    if delta == 0 then
      state.mixpos = name == 'q_mixdn' and 'bottom' or 'top'; state.mixer = true
      reaper.SetExtState(EXT, 'mixpos', state.mixpos, true)
      relayout(); vim.msg = 'mixer ' .. (state.mixpos == 'bottom' and 'under the tracker' or 'above the tracker, in the headers')
    end
  elseif name == 'q_kcm' or name == 'q_kcp' then
    if delta == 0 then
      local cur = (state.kc_scale or 0) > 0 and state.kc_scale or draw.SCALE
      state.kc_scale = math.max(1, math.min(6, cur + (name == 'q_kcp' and 1 or -1)))
      state.keycast = true
      vim.msg = 'keycaster x' .. state.kc_scale
      -- проба размера (5 окт): в кейкастер — jftracker и версия
      ctx.kc = ctx.kc or {}
      ctx.kc[#ctx.kc + 1] = { label = 'jftracker ' .. VER.VERSION, t = reaper.time_precise(), n = 1 }
      if #ctx.kc > 16 then table.remove(ctx.kc, 1) end
    end
  elseif name == 'q_wave' then if delta == 0 then state.wave_last = (state.wavemode ~= 'off') and state.wavemode or state.wave_last; ctx.wave_mode((state.wavemode ~= 'off') and 'off' or (state.wave_last or 'back')) end
  elseif name == 'q_meters' then if delta == 0 then state.meters = not state.meters end
  elseif name == 'q_ruler' then if delta == 0 then state.tlruler = (state.tlruler or 'off') ~= 'off' and 'off' or 'beats' end
  elseif name == 'q_names' then if delta == 0 then state.itemnames = not state.itemnames end
  elseif name == 'q_colors' then if delta == 0 then state.itemcol = not state.itemcol end
  elseif name == 'q_input' then if delta == 0 then state.hdrin = state.hdrin == false; relayout() end
  elseif name == 'q_preview' then if delta == 0 then state.preview = not state.preview end
  elseif name == 'q_endstop' then if delta == 0 then state.endstop = not state.endstop end
  elseif name == 'q_captions' then if delta == 0 then state.captions = not state.captions; relayout() end
  elseif name == 'help' then if delta == 0 then ctx.toggle_help() end
  elseif name == 'notes' then if delta == 0 then ctx.notes_toggle() end
  elseif name == 'hints' then if delta == 0 then state.hints = not state.hints; vim.msg = 'module hints ' .. (state.hints and 'on' or 'off') end
  elseif name == 'play' then if delta == 0 then edit.play_stop() end
  elseif name == 'bpm' then
    if delta ~= 0 then
      local bpm = reaper.Master_GetTempo() + delta
      edit.run('tempo', function() reaper.SetCurrentBPM(0, math.max(20, math.min(400, bpm)), false) end)
    end
  elseif name == 'lpb' then set_lpb(nil, delta ~= 0 and delta or 1)
  elseif name == 'oct' then vim.octave = math.max(0, math.min(8, vim.octave + (delta ~= 0 and delta or 1)))
  elseif name == 'vel' then vim.vel = math.max(1, math.min(127, (vim.vel or 100) + (delta ~= 0 and delta * 4 or 8)))
  elseif name == 'step' then
    -- клик — по кругу: число → auto (до конца вставленного item / слайса) → next
    -- (на следующий объект трека) → число; колесо — число
    if delta == 0 then
      if vim.step_next then vim.step_next = false
      elseif vim.step_auto then vim.step_auto = false; vim.step_next = true
      else vim.step_auto = true end
      vim.msg = 'step: ' .. (vim.step_next and 'next - to the next note / item / command / envelope point of the track' or (vim.step_auto and 'auto - to the end of the inserted item / slice' or tostring(vim.step)))
    else vim.step = math.max(0, vim.step + delta); vim.step_auto = false; vim.step_next = false end
  elseif name == 'inst' then pool_select(vim.inst + (delta ~= 0 and delta or 1))
  elseif name == 'follow' then state.follow = not state.follow
  elseif name == 'lock' then state.lock = not state.lock; lock_sync = {}; vim.msg = 'lock to REAPER cursor: ' .. (state.lock and 'on' or 'off')
  elseif name == 'fixed' then state.fixed = not state.fixed; vim.msg = 'fixed cursor (centre): ' .. (state.fixed and 'on' or 'off')
  elseif name == 'wave' then ctx.wave_mode(nil, delta)
  elseif name == 'xfade' then if delta ~= 0 then ctx.xfade_len(delta) else ctx.xfade_toggle() end
  elseif name == 'loop' then reaper.GetSetRepeat(2)
  elseif name == 'clips' then ctx.clips_toggle()                -- грид: страница clips (7 окт)
  elseif name == 'pitch' then
    if col then ctx.set_pitchmode(col, state.pitchmodes[col.guid] == 'resample' and 'shift' or 'resample') end
  elseif name == 'font' then
    ctx.set_scale(math.max(1, math.min(draw.SCALE_MAX, math.floor(state.fontscale) + (delta ~= 0 and delta or 1))))
  elseif name == 'fx' then state.fxcols = math.max(0, math.min(4, state.fxcols + (delta ~= 0 and delta or 1)))
  elseif name == 'meters' then state.meters = not state.meters
  elseif name == 'caps' then state.captions = not state.captions; vim.msg = 'column captions ' .. (state.captions and 'on' or 'off')
  elseif name == 'hdr' then
    local order = { off = 'line', line = 'header', header = 'full', full = 'off' }
    local back = { off = 'full', line = 'off', header = 'line', full = 'header' }
    state.hdrfill = (delta < 0 and back or order)[state.hdrfill or 'line']; vim.msg = 'track header colour: ' .. state.hdrfill
  elseif name == 'metro' then if delta == 0 then reaper.Main_OnCommand(40364, 0) end      -- Options: Toggle metronome
  elseif name == 'debug' then
    state.debug = not state.debug
    vim.msg = state.debug and ('debug on: log -> ' .. ctx.dlog_path) or 'debug off'
    if state.debug then ctx.dlog(('--- debug on, jf_tracker, window %dx%d, focus %s, mode %s'):format(gfx.w, gfx.h, state.focus, vim.mode)) end
  elseif name == 'perf' or name == 'jftop' then
    ctx.PERF = ctx.PERF or dofile(DIR .. '/jf_tracker_perf.lua')
    local want = name == 'jftop'
    -- одно окно, два вида: performance (REAPER) и jftop (кадр трекера по частям)
    if ctx.PERF.active and (ctx.PERF.jftop or false) ~= want then ctx.PERF.jftop = want
    else ctx.PERF.active = not ctx.PERF.active; ctx.PERF.jftop = want end
    ctx.PERF.prof = draw.prof
    ctx.PERF.reset = function() for k in pairs(draw.prof) do draw.prof[k] = nil end; draw.prof_ord = 0 end
    if ctx.PERF.active then state.mx_hidden = false; ctx.PERF.t = 0 end
    vim.msg = ctx.PERF.active and 'performance in the matrix: n - REAPER performance meter, j k scroll, Esc (matrix focused) closes' or 'performance closed'
  elseif name == 'swing' then
    -- 6 окт: свинг сетки проекта REAPER; клик — выпадашка, колесо — ±1 %
    if delta == 0 then ctx.swing_menu()
    else
      local s = edit.sw
      edit.swing_set(true, (s.on and s.amt or 0) + delta / 100)
      vim.msg = ctx.swing_text()
    end
  elseif name == 'oneclick' then state.oneclick = not state.oneclick; vim.msg = 'one click focus ' .. (state.oneclick and 'on' or 'off')
  elseif name == 'autofocus' then state.autofocus = not state.autofocus; vim.msg = 'autofocus ' .. (state.autofocus and 'on' or 'off')
  -- блок записи (5 окт): rec, punch (авто-панч по time selection), pre-roll, rec→lib
  elseif name == 'rec' then
    if reaper.GetPlayState() & 4 == 4 then if state.rec_sess then ctx.rec_stop(32) else reaper.Main_OnCommand(1016, 0) end
    else ctx.rec_start('tracker') end
  elseif name == 'tp_rew' then reaper.Main_OnCommand(40084, 0)            -- Transport: Rewind a little bit
  elseif name == 'tp_fwd' then reaper.Main_OnCommand(40085, 0)            -- Transport: Fast forward a little bit
  elseif name == 'tp_play' then reaper.Main_OnCommand(reaper.GetPlayState() & 1 == 1 and 1016 or 1007, 0)   -- play / stop
  elseif name == 'tp_pause' then reaper.Main_OnCommand(1008, 0)           -- Transport: Pause
  elseif name == 'punch' then
    local p = ctx.cmd_by_text('record mode: time selection auto punch')
    if p and reaper.GetToggleCommandState(p) == 1 then reaper.Main_OnCommand(ctx.cmd_by_text('record mode: normal') or 40252, 0)
    elseif p then reaper.Main_OnCommand(p, 0) end
  elseif name == 'preroll' then local p = ctx.cmd_by_text('pre-roll on record'); if p then reaper.Main_OnCommand(p, 0) end
  elseif name == 'reclib' then state.reclib = not state.reclib; vim.msg = 'rec -> lib ' .. (state.reclib and 'on: recorded takes also become instruments' or 'off')
  -- размер (5 окт): клик — меню размеров (длиннее такт — вопрос про доли), колесо — сразу ±1 доля
  elseif name == 'sig' or name == 'beats' then if delta == 0 then ctx.sig_menu() else ctx.sig_wheel(delta) end
  end
end

local env_cache = {}
-- значения огибающих по строкам вида (6 окт): кэш между кадрами — заново
-- только когда сменились проект (state change count), вид или LPB; раньше
-- пересчитывались все видимые огибающие каждый кадр
local function env_values(e)
  model.aipoints = state.aipoints ~= false
  local k = ('%d|%d|%d|%d|%s'):format(reaper.GetProjectStateChangeCount(0), rows[1] and rows[1].row or 0, #rows, state.lpb, tostring(model.aipoints))
  if k ~= ctx.env_cache_key then env_cache, ctx.env_cache_key = {}, k end
  local v = env_cache[e]
  if not v then v = model.env_values(e, rows); env_cache[e] = v end
  return v
end

-- ── monome (этап 9): обмен с модулем демона jf_grid через ExtState ─────────
-- jf_tracker/mx: «nrows,ncols,cur_ri,cur_ci,play_ri,queue_ri;<ячейки>» —
-- ячейка по символу: . пусто, o события, x всё заглушено; строки — слоты
-- последовательности (regions без библиотеки), колонки — треки.
-- jf_tracker/gridkey: «x,y,n» от демона (нажатие) — n растёт, читаем новые.
-- стартовое значение gridkey не исполняем: оно от прошлого сеанса
local mx_last, gridkey_last = '', reaper.GetExtState(EXT, 'gridkey')
local function publish_matrix(playpos)
  -- страница clips грида (7 окт): состояние сессии, команды — poll_gridkey
  do
    local SS = MX.SS
    local pp, playing = ctx.ss_playpos()
    local str = snap and SS.grid_pub(seq, #ctx.ss_V().cols, ctx.ss_G(), pp, playing, state.clipsview or state.ss_big or MX.clips) or ''
    if str ~= SS.pub_last then reaper.SetExtState(EXT, 'ss', str, false); SS.pub_last = str end
  end
  if #seq == 0 then if mx_last ~= '' then reaper.SetExtState(EXT, 'mx', '', false); mx_last = '' end return end
  local grid = MX.grid(snap, seq)
  local play_ri, queue_ri = 0, 0
  if playpos then local rg = alias.region_at(seq, playpos); if rg then for i, r in ipairs(seq) do if r == rg then play_ri = i end end end end
  if MX.queued then for i, r in ipairs(seq) do if r.idx == MX.queued.idx then queue_ri = i end end end
  local cells = {}
  for ri = 1, #seq do
    for ci = 1, #snap.cols do
      local g = grid[ri][ci]
      cells[#cells + 1] = g.state == 'muted' and 'x' or (g.state == 'has' and 'o' or '.')
    end
  end
  local str = ('%d,%d,%d,%d,%d,%d;%s'):format(#seq, #snap.cols, MX.cur.ri, MX.cur.ci, play_ri, queue_ri, table.concat(cells))
  if str ~= mx_last then reaper.SetExtState(EXT, 'mx', str, false); mx_last = str end
end
-- jf_tracker/st: «lpb,oct,step,inst,ninst,playing,follow,loop,armed» для колец
-- arc и нижнего ряда; jf_tracker/cmd: «имя,n» от модуля (play stop rec
-- follow loop lpb+ lpb- oct+ oct- step+ step- inst+ inst-)
local st_last, cmd_last = '', reaper.GetExtState(EXT, 'cmd')
local function publish_state(is_playing)
  local col = cur_col()
  local armed = col and col.armed and 1 or 0
  local str = ('%d,%d,%d,%d,%d,%d,%d,%d,%d'):format(state.lpb, vim.octave, vim.step_auto and 0 or vim.step, vim.inst, col and #(col.pool or {}) or 0,
    is_playing and 1 or 0, state.follow and 1 or 0, reaper.GetSetRepeat(-1) == 1 and 1 or 0, armed)
  if str ~= st_last then reaper.SetExtState(EXT, 'st', str, false); st_last = str end
end
local function poll_cmd()
  local v = reaper.GetExtState(EXT, 'cmd')
  if v == '' or v == cmd_last then return end
  cmd_last = v
  ctx.dlog('cmd ' .. v)
  local name = v:match('^([%w%+%-]+)')
  if name == 'play' then edit.play_stop()
  elseif name == 'stop' then reaper.OnStopButton()
  elseif name == 'rec' then reaper.Main_OnCommand(1013, 0)
  elseif name == 'follow' then state.follow = not state.follow
  elseif name == 'lock' then state.lock = not state.lock; lock_sync = {}; vim.msg = 'lock to REAPER cursor: ' .. (state.lock and 'on' or 'off')
  elseif name == 'loop' then reaper.GetSetRepeat(2)
  elseif name == 'clips' then ctx.clips_toggle()                -- грид: страница clips (7 окт)
  elseif name == 'lpb+' then set_lpb(nil, 1) elseif name == 'lpb-' then set_lpb(nil, -1)
  elseif name == 'oct+' then vim.octave = math.min(8, vim.octave + 1) elseif name == 'oct-' then vim.octave = math.max(0, vim.octave - 1)
  elseif name == 'step+' then vim.step = vim.step + 1 elseif name == 'step-' then vim.step = math.max(0, vim.step - 1)
  elseif name == 'inst+' then pool_select(vim.inst + 1) elseif name == 'inst-' then pool_select(vim.inst - 1)
  elseif name == 'aidump' and (state.ai_edit or ctx.ai_list()[1]) then
    -- отладка (6 окт): точки открытого automation item, шкала и границы -> ExtState dbg
    local ae = state.ai_edit or ctx.ai_list()[1]
    local mode = reaper.GetEnvelopeScalingMode(ae.env)
    local out = { ('mode %d min %s max %s pos %.3f'):format(mode, tostring(ae.min), tostring(ae.max), reaper.GetSetAutomationItemInfo(ae.env, ae.idx, 'D_POSITION', 0, false)),
      ('len %.3f pqn %.3f rate %.3f loop %d'):format(reaper.GetSetAutomationItemInfo(ae.env, ae.idx, 'D_LENGTH', 0, false), reaper.GetSetAutomationItemInfo(ae.env, ae.idx, 'D_POOL_QNLEN', 0, false),
        reaper.GetSetAutomationItemInfo(ae.env, ae.idx, 'D_PLAYRATE', 0, false), reaper.GetSetAutomationItemInfo(ae.env, ae.idx, 'D_LOOPSRC', 0, false)) }
    local FI = ae.idx | 0x10000000
    for p = 0, math.min(12, reaper.CountEnvelopePointsEx(ae.env, FI)) - 1 do
      local _, t, v = reaper.GetEnvelopePointEx(ae.env, FI, p); out[#out + 1] = ('%.3f:%.3f'):format(t, v)
    end
    reaper.SetExtState(EXT, 'dbg', table.concat(out, ' | '), false)
  elseif name == 'perf' then ctrl_action('perf', 0)
  elseif name == 'jftop' then ctrl_action('jftop', 0)
  elseif name == 'helpbig' then ctx.help_big()                          -- тест: F1
  elseif name == 'actions' then ctx.actions_picker()                -- тест: ?
  elseif name == 'dev' then ctx.dev_set(v:match('^dev%s+(%a+)') or '')   -- тест: :dev on|off
  elseif name == 'logo' then ctx.logo_show(v:match('^logo%s+([%a_]+)') or '')   -- тест: :logo имя
  elseif name == 'esc' then vim.picker, vim.hydra = nil, nil; state.khelp_big = false   -- тест: закрыть всплывашки
  elseif name == 'flag' then   -- тест: flag <ключ> on|off — опция-флаг, с сохранением
    local k, v2 = v:match('^flag%s+([%w_]+)%s+(%a+)')
    if k and state[k] ~= nil then state[k] = v2 == 'on'; reaper.SetExtState(EXT, k, v2 == 'on' and '1' or '0', true); B.pm = nil; vim.msg = k .. ' ' .. v2; relayout() end
  elseif name == 'ex' then vim.run_cmd((v:match('^ex%s+(.-)%s*%d%d%d%d%d%d%d%d%d+$') or v:match('^ex%s+(.*)$') or ''):gsub('_', ' '))   -- тест: любая :команда (пробелы — _)
  elseif name == 'session' and (v:match('^session%s+launch') or v:match('^session%s+scene') or v:match('^session%s+stop') or v:match('^session%s+off') or v:match('^session%s+jump') or v:match('^session%s+loop')) and not ctx.is_sandbox() then
    reaper.SetExtState(EXT, 'ssdump', 'REFUSED: not a sandbox', false)   -- тест-команды, что меняют проект, — только в песочнице (6 окт)
  elseif name == 'session' then ctx.ss_cmd(v:match('^session%s+(.-)%s*%d%d%d%d%d%d%d%d%d+$') or v:match('^session%s+(.*)$') or '')   -- тест: :session …
  elseif name == 'eqset' then   -- тест (7 окт): eqset <fx> <параметр-подпись_без_пробелов> <число> — только песочница
    local fi, lab, val = v:match('^eqset%s+(%d+)%s+(%S+)%s+(%S+)')
    local t = dsp_target(); local f = t and t.fx[tonumber(fi or 0)]
    if not ctx.is_sandbox() or not f then reaper.SetExtState(EXT, 'dbg', 'eqset: REFUSED / no fx', false)
    else
      lab = lab:gsub('_', ' ')
      for pi, p in ipairs(f.params or {}) do
        if p.name == lab then
          ctx.fx_set_display(f, p, tonumber(val))
          local _, s2 = model.fxapi(t.track).GetFormattedParamValue(t.track, p.fx or f.i, p.i, '')
          reaper.SetExtState(EXT, 'dbg', ('eqset %s -> %s'):format(lab, s2), false)
        end
      end
    end
  elseif name == 'pnames' then   -- тест (7 окт): имена пресетов fx цели DSP (только чтение)
    local t, f = ctx.dsp_fx(tonumber(v:match('^pnames%s+(%d+)') or '1'))
    local nm = f and ctx.preset_names(t.track, f.i) or {}
    reaper.SetExtState(EXT, 'dbg', ('pnames %s: %d | %s'):format(f and f.name or '?', #nm, table.concat(nm, ', '):sub(1, 300)), false)
  elseif name == 'pdef' then   -- тест (7 окт): pdef <fx> <подпись_параметра> — сброс к умолчанию, только песочница
    local fi, lab = v:match('^pdef%s+(%d+)%s+(%S+)')
    local t = dsp_target(); local f = t and t.fx[tonumber(fi or 0)]
    if not ctx.is_sandbox() or not f then reaper.SetExtState(EXT, 'dbg', 'pdef: REFUSED / no fx', false)
    else
      lab = lab:gsub('_', ' ')
      for _, p in ipairs(f.params or {}) do
        if p.name == lab then
          local n0 = reaper.TrackFX_GetCount(t.track)
          local dv = edit.fx_param_default(t.track, p.fx or f.i, p.i)
          local _, s2 = model.fxapi(t.track).GetFormattedParamValue(t.track, p.fx or f.i, p.i, '')
          reaper.SetExtState(EXT, 'dbg', ('pdef %s -> %s (%s) fx %d -> %d'):format(lab, s2, tostring(dv), n0, reaper.TrackFX_GetCount(t.track)), false)
        end
      end
    end
  elseif name == 'pnm' then   -- тест (7 окт): имена параметров fx addr (только чтение)
    local addr = tonumber(v:match('^pnm%s+(%d+)') or '0'); local t = dsp_target(); local out = {}
    if t then local A = model.fxapi(t.track); for i = 0, math.min(40, A.GetNumParams(t.track, addr)) - 1 do local _, nm = A.GetParamName(t.track, addr, i, ''); out[#out + 1] = i .. ':' .. nm end end
    reaper.SetExtState(EXT, 'dbg', table.concat(out, ' | '), false)
  elseif name == 'dbp' then   -- тест (7 окт): параметры узла addr для большого роутера (только чтение)
    local addr = tonumber(v:match('^dbp%s+(%d+)') or '0')
    local t = dsp_target(); local out = {}
    for _, f in ipairs(t and t.fx or {}) do if f.i == addr then for _, p in ipairs(f.params or {}) do out[#out + 1] = tostring(p.name) .. ':' .. tostring(p.i) .. ':' .. tostring(p.fx) end end end
    reaper.SetExtState(EXT, 'dbg', 'dbp ' .. #out .. ' | ' .. table.concat(out, ' '), false)
  elseif name == 'st' then reaper.SetExtState(EXT, 'dbg', ('focus %s mode %s pending %s op %s clips %s'):format(state.focus, vim.mode, tostring(vim.pending), tostring(vim.op), tostring(state.clipsview)), false)   -- тест: состояние фокуса (только чтение)
  elseif name == 'shot' then ctx.shot_req = 'file'                -- тест (8 окт): снимок окна трекера своим кодером
  elseif name == 'notesadd' then
    -- 8 окт: дописать файл CHECK.md (список проверки) в конец заметок проекта
    -- активной вкладки; открытый редактор заметок перечитывает их
    local fh = io.open(DIR .. '/CHECK.md', 'r')
    if fh then
      local add = fh:read('a'); fh:close()
      if state.focus == 'notes' then ctx.notes_save() end
      local old = reaper.GetSetProjectNotes(0, false, '')
      reaper.GetSetProjectNotes(0, true, (old ~= '' and (old .. '\n\n') or '') .. add)
      if state.notes_open then ctx.notes_load() end
      reaper.SetExtState(EXT, 'dbg', 'notesadd: ' .. #add .. ' bytes', false)
    end
  elseif name == 'rbig' then ctx.router_big()                   -- тест (7 окт): zR
  elseif name == 'dbkey' then   -- тест (7 окт): клавиши DSP big, только в песочнице: dbkey <буквы>
    if not ctx.is_sandbox() then reaper.SetExtState(EXT, 'dbg', 'dbkey: REFUSED, not a sandbox', false)
    else
      for ch in (v:match('^dbkey%s+(%S+)') or ''):gmatch('.') do ctx.db_cache = nil; local root, o = ctx.db_tree(); if root then MX.DB.layout(root, MX.DB.metrics(L), 0, 0, 100); MX.DB.key(ch:byte(), root, o) end end
      ctx.db_cache = nil
      local root = ctx.db_tree(); local sel = root and MX.DB.find(root, MX.DB.sel)
      local out = {}
      for _, n in ipairs(root and MX.DB.walk(root) or {}) do out[#out + 1] = n.name .. (n.on and '' or '(off)') .. ((n.par or 0) > 0 and '=' or '') end
      reaper.SetExtState(EXT, 'dbg', 'sel ' .. (sel and sel.name or 'nil') .. ' | ' .. table.concat(out, ' '), false)
    end
  elseif name == 'pm' then ctx.pm_cmd(v:match('^pm%s+(%a+)') or '')      -- тест: :pm [big|grid|list]
  elseif name == 'slicedump' then
    -- 6 окт: слайсы выбранного инструмента lib — сырые и пересчитанные, rate, база
    local col = cur_col(); local e = col and col.pool and col.pool[vim.inst or 1]
    local it = e and e.item
    if it and reaper.ValidatePtr(it, 'MediaItem*') then
      local tk = reaper.GetActiveTake(it)
      local _, raw = reaper.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slices', '', false)
      local _, base = reaper.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice_base', '', false)
      local _, bs = reaper.GetSetMediaItemInfo_String(it, 'P_EXT:jf_bsync', '', false)
      local sl = edit.item_slices(it)
      reaper.SetExtState(EXT, 'dbg', ('rate %.4f len %.4f offs %.4f | base %s | bsync %s | raw %s | now %s | model %s'):format(
        reaper.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE'), reaper.GetMediaItemInfo_Value(it, 'D_LENGTH'), reaper.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS'),
        base, bs, (raw or ''):sub(1, 60), table.concat({ sl[2] or '', sl[3] or '', sl[4] or '' }, ','), table.concat({ (e.slices or {})[2] or '', (e.slices or {})[3] or '' }, ',')), false)
    else reaper.SetExtState(EXT, 'dbg', 'slicedump: no instrument', false) end
  elseif name == 'notesfile' then
    -- 6 окт: дописать в project notes текст из .pending_notes.txt (файл удаляется)
    local f = io.open(DIR .. '/.pending_notes.txt', 'r')
    if f then
      local add = f:read('a'); f:close(); os.remove(DIR .. '/.pending_notes.txt')
      local cur = reaper.GetSetProjectNotes(0, false, '')
      reaper.GetSetProjectNotes(0, true, (cur ~= '' and (cur .. '\n\n') or '') .. add)
      if NT and NT.kind == 'project' and ctx.notes_load then ctx.notes_load() end
      vim.msg = 'notes: test list added'
    end
  end
end

local function poll_gridkey()
  do   -- команды страницы clips (7 окт); стартовое значение — от прошлого сеанса
    local g = reaper.GetExtState(EXT, 'ssgrid')
    if MX.SS.gk_last == nil then MX.SS.gk_last = g end
    if g ~= '' and g ~= MX.SS.gk_last then MX.SS.gk_last = g; ctx.dlog('ssgrid ' .. g); MX.SS.grid_cmd(g, seq, ctx.ss_V(), ctx.ss_G()) end
  end
  local v = reaper.GetExtState(EXT, 'gridkey')
  if v == '' or v == gridkey_last then return end
  gridkey_last = v
  local x, y = v:match('^(%d+),(%d+)')
  x, y = tonumber(x), tonumber(y)
  if not x or not y or #seq == 0 then return end
  local ri = math.max(1, math.min(#seq, y))
  local ci = math.max(1, math.min(#snap.cols, x))
  MX.goto_cell(seq, snap, ri, ci)
  ctx.region_space(seq[ri])
end

-- Bxx на строке плейхеда: прыжок в слот xx (один раз на строку)
local jump_row_done = nil
-- Garden: тик Orca раз на строку при игре; выходы сажаются на строку вперёд
-- (без undo, тег = регион строки-цели); при входе плейхеда в регион прежний
-- урожай этого региона сносится (кроме посаженного на текущую строку).
local orca_row_done, orca_pass = nil, nil
-- линейка матрицы (2 окт): подпись «такт.доля» начала слота и риски тактов /
-- долей внутри слота; маркеры =START / =END строками до и после слотов.
-- Кэш сбрасывается вместе с таблицей последовательности (темп, маркеры).
local mxr = { seq = nil, lbl = {}, ticks = {}, marks = nil }
local function mxr_check() if mxr.seq ~= seq then mxr.seq = seq; mxr.lbl = {}; mxr.ticks = {}; mxr.marks = nil end end
local function mx_bar_label(t)
  mxr_check()
  local v = mxr.lbl[t]
  if v then return v end
  local qn = reaper.TimeMap2_timeToQN(0, t)
  local m, qms = reaper.TimeMap_QNToMeasures(0, qn + 1e-9)
  local beat = math.floor(qn - (qms or qn) + 1e-6) + 1
  v = ('%d.%d'):format((m or 0) + 1, beat)
  mxr.lbl[t] = v
  return v
end
local function mx_ticks(rg)
  mxr_check()
  local v = mxr.ticks[rg]
  if v then return v end
  v = {}
  local span = rg.qn1 - rg.qn0
  if span > 0 then
    local q = math.floor(rg.qn0 + 1 - 1e-6)
    local n = 0
    while q < rg.qn1 - 1e-6 and n < 256 do
      if q > rg.qn0 + 1e-6 then
        local _, qms = reaper.TimeMap_QNToMeasures(0, q + 1e-9)
        v[#v + 1] = { f = (q - rg.qn0) / span, bar = qms and math.abs(qms - q) < 1e-6 }
      end
      q = q + 1; n = n + 1
    end
  end
  mxr.ticks[rg] = v
  return v
end
local function mx_marks()
  mxr_check()
  if mxr.marks then return mxr.marks end
  local out = {}
  for _, mk in ipairs((regions and regions.markers) or {}) do
    local key = (mk.name == model.START_MARKER and 'start') or (mk.name == model.END_MARKER and 'stop') or nil
    if key and not out[key] then
      local rgb
      if mk.color and mk.color ~= 0 then local r, g, b = reaper.ColorFromNative(mk.color & 0xFFFFFF); rgb = { r / 255, g / 255, b / 255 } end
      if not rgb and reaper.GetThemeColor then
        local tc = reaper.GetThemeColor('marker', 0)
        if tc and tc >= 0 then local r, g, b = reaper.ColorFromNative(tc); rgb = { r / 255, g / 255, b / 255 } end
      end
      out[key] = { name = mk.name, bar = mx_bar_label(mk.pos), rgb = rgb }
    end
  end
  mxr.marks = out
  return out
end
ctx.mx_ruler_toggle = function()
  state.mxruler = not state.mxruler; MX.ruler = state.mxruler
  vim.msg = 'matrix ruler ' .. (state.mxruler and 'on' or 'off')
end
-- линейка трекера: регионы и маркеры REAPER с цветами (кэш по таблице регионов)
local ruler_cache = {}
local ruler_info
local function native_rgb(c)
  if not c or c == 0 then return nil end
  local r, g, b = reaper.ColorFromNative(c & 0xFFFFFF)
  return { r / 255, g / 255, b / 255 }
end
-- цвет региона / маркера: свой, иначе цвет из темы REAPER — как на таймлайне
-- (2 окт регионы; 3 окт маркеры: =START был янтарным, а на таймлайне — цвета темы)
local theme_rgb = {}
local function region_rgb(c, key)
  local own = native_rgb(c)
  if own then return own end
  key = key or 'region'
  if theme_rgb[key] == nil then
    local tc = reaper.GetThemeColor and reaper.GetThemeColor(key, 0) or -1
    theme_rgb[key] = (tc and tc >= 0) and native_rgb(tc | 0x1000000) or false
  end
  return theme_rgb[key] or nil
end
ctx.region_rgb = region_rgb
ruler_info = function()
  if ruler_cache.src == regions then return ruler_cache.v end
  local v = { regions = {}, markers = {} }
  for _, rg in ipairs(regions or {}) do v.regions[#v.regions + 1] = { r0 = rg.r0, r1 = rg.r1, name = rg.name, idx = rg.idx, rgb = region_rgb(rg.color) } end
  for _, mk in ipairs((regions and regions.markers) or {}) do v.markers[#v.markers + 1] = { row_f = mk.row_f, name = mk.name, idx = mk.idx, rgb = region_rgb(mk.color, 'marker') } end
  ruler_cache.src, ruler_cache.v = regions, v
  return v
end

local function track_has_midi(tr)
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, i)
    local tk = reaper.GetActiveTake(it)
    if tk and reaper.TakeIsMIDI(tk) and not edit.garden_tag(it) then return true end
  end
  return false
end
local function process_orca(playpos)
  local f = garden.f
  if not (f and f.on and snap) then return end
  local row = math.floor(model.row_of_time(playpos, state.lpb) + 1e-6)
  if orca_row_done == nil then f.frame = 0; orca_pass = nil end
  if row == orca_row_done then return end
  orca_row_done = row
  local rs = ctx.real_seq()
  local rg = alias.region_at(rs, playpos)
  local t_row = edit.row_time(row, state.lpb, 0)
  local rowlen = edit.row_time(row + 1, state.lpb, 0) - t_row
  local rkey = rg and (rg.idx .. ':' .. rg.pos) or 'free'
  if rkey ~= orca_pass then
    orca_pass = rkey
    if rg then edit.garden_clear(rg.idx, t_row - 1e-3, t_row + rowlen) end
  end
  local outs = ORCA.tick(f)
  GD.decay()
  if #outs == 0 then return end
  reaper.PreventUIRefresh(1)
  local planted = 0
  local function col_of(ch)
    local t = ORCA.b36(ch) or 0
    if t == 0 then return cur_col() end
    return snap.cols[t]
  end
  for _, o in ipairs(outs) do
    local a = o.args
    if o.op == ':' or o.op == '$' then
      local col = col_of(a[1])
      if col then
        local ii = ORCA.b36(a[2]) or 0
        local inst = (col.pool or {})[ii == 0 and vim.inst or ii]
        local target = row + 1
        local trg = alias.region_at(rs, edit.row_time(target, state.lpb, 0))
        local opts = { track = col.track, lane_idx = col.fixed and col.lanes[1] and col.lanes[1].idx or nil, lpb = state.lpb,
                       row = target, tag = trg and trg.idx or 'free', span = trg and { trg.pos, trg.rgnend } or nil }
        local v = ORCA.b36(o.op == ':' and a[5] or a[4]) or 0
        opts.vel = v == 0 and (vim.vel or 100) or math.floor(v * 127 / 35 + 0.5)
        if o.op == ':' then
          opts.pitch = ORCA.note_pitch(a[3], a[4])
          opts.len = math.max(1, ORCA.b36(a[6]) or 1)
          if opts.pitch then
            if inst and inst.item and not track_has_midi(col.track) then opts.item = inst.item end
            if edit.plant(opts) then planted = planted + 1 end
          end
        elseif inst and inst.item then
          opts.item = inst.item; opts.slice = math.max(1, ORCA.b36(a[3]) or 1)
          if edit.plant(opts) then planted = planted + 1 end
        end
      end
    elseif o.op == ';' then
      local n = (ORCA.b36(a[1]) or 0) * 36 + (ORCA.b36(a[2]) or 0)
      local s = seq[n]
      if s and not (MX.queued and MX.queued.pos == s.pos) then MX.queued = s end
    elseif o.op == '=' then
      local col = col_of(a[1])
      local fx = math.max(1, ORCA.b36(a[2]) or 1) - 1
      local pi = math.max(1, ORCA.b36(a[3]) or 1) - 1
      if col and fx < reaper.TrackFX_GetCount(col.track) then
        reaper.TrackFX_SetParamNormalized(col.track, fx, pi, (ORCA.b36(a[4]) or 0) / 35)
      end
    end
  end
  reaper.PreventUIRefresh(-1)
  if planted > 0 then reaper.UpdateArrange(); garden.planted = garden.planted + planted end
end

local function process_jumps(playpos)
  local row = math.floor(model.row_of_time(playpos, state.lpb))
  if row == jump_row_done then return end
  jump_row_done = row
  for _, f in ipairs(L.flat) do
    local c = f.sub and f.sub[row]
    if c and (c.kind == 'audio' or c.kind == 'midi') then
      for _, fx in ipairs(c.fx or {}) do
        local xx = fx:match('^B(%x%x)$')
        if xx then
          local slot = seq[tonumber(xx, 16)]
          if slot then reaper.SetEditCurPos(slot.pos, false, true); MX.queued = nil; vim.msg = 'B' .. xx .. ' → ' .. slot.name; return end
        end
      end
    end
  end
end

-- очередь регионов: прыжок на границе текущего региона (или такта)
local function process_queue(playpos)
  if not MX.queued then return end
  if not playing() then MX.queued = nil; return end
  local cur = alias.region_at(regions, playpos)
  local boundary
  if cur then boundary = cur.rgnend
  else
    local _, _, qme = reaper.TimeMap_QNToMeasures(0, reaper.TimeMap2_timeToQN(0, playpos))
    boundary = qme and reaper.TimeMap2_QNToTime(0, qme) or playpos
  end
  if cur and cur.idx == MX.queued.idx and math.abs(cur.pos - MX.queued.pos) < 1e-6 then MX.queued = nil; return end
  if playpos >= boundary - 0.035 then
    reaper.SetEditCurPos(MX.queued.pos, false, true)
    MX.queued = nil
  end
end

local function frame()
  if not ctx.title_init then ctx.title_init = true; if state.notitle then toggle_dock(true) end end   -- старт плавающим: без заголовка
  theme_check()
  if state.toptab == 'grid' and not state.gridtab then state.toptab = 'master' end
  if state.toptab == 'garden' and not state.dev then state.toptab = 'master' end   -- Orca — только .dev   -- вкладка grid выключена в опциях
  -- заметки: автозапись через секунду после правки; context следует за item под курсором
  if state.notes_open then
    NT.edit_t = NT.dirty and (NT.edit_t or reaper.time_precise()) or nil
    if NT.dirty and NT.edit_t and reaper.time_precise() - NT.edit_t > 1 then ctx.notes_save(); NT.edit_t = nil end
    if NT.target == 'context' and L then
      local _, obj = ctx.notes_owner()
      if obj ~= NT.owner then ctx.notes_save(); ctx.notes_load() end
    end
  end
  if reselect_item and snap and snap.inst_of and snap.inst_of[reselect_item] then
    local n = snap.inst_of[reselect_item]
    local pe = snap.pool and snap.pool[n]
    if pe and pe.parent then for i, e in ipairs(snap.pool) do if e == pe.parent then n = i; break end end end   -- слайс → его исходник (7 окт)
    vim.inst = n; reselect_item = nil
  end
  -- строка «take fx» ВЫБРАНА в свойствах сэмпла (момент перехода на неё) — DSP
  -- на take; t / кнопка track возвращает трек, пока строка остаётся выбранной
  do
    -- переход строки на take fx (не возврат фокуса в док — ревью 2 окт)
    local on_fx = state.toptab == 'sample' and (SPROP.ROWS[SPROP.sel] or {}).k == 'fx'
    if on_fx and not sp_on_fx then state.dsp_take = true; dsp_sel.fx, dsp_sel.param = 1, 1; DK.anchor, DK.pending = nil, nil end
    sp_on_fx = on_fx
  end
  edit.keep_samples, edit.copy_media = state.keepsamples, state.copymedia
  -- страховка сэмплов: сообщить, что файл ушёл в библиотеку трека
  if edit.rescued then
    vim.msg = 'last item of ' .. table.concat(edit.rescued, ', ') .. ' deleted - sample kept in track library (=LIB)'
    edit.rescued = nil
  end
  -- справка следит за модулем в фокусе (пока её не листают стрелками)
  if state.khelp and state.focus ~= 'dsp' then KH.pinned = false; KH.page = ctx.help_page() end
  draw.prof_on = state.debug or (ctx.PERF and ctx.PERF.active and ctx.PERF.jftop) or false
  draw.pmark('snapshot + model rebuild')
  local t_0 = reaper.time_precise()
  U.begin_frame()
  prof.input = U.click or U.rclick         -- клик этого кадра (U.click гасится по ходу разбора)
  PV.tick()
  ctx.notes_dev_poll()
  if ctx.PM then ctx.PM.tick() end                                    -- jf_pm: загрузка по кускам, запись, превью (6 окт)
  if snap and seq then MX.SS.tick(seq, ctx.ss_V(), ctx.ss_G()) end                           -- session: границы квантизации (6 окт)
  do local sz = MX.SS.playing_any(); if sz ~= model.SHOW_ZONE then model.SHOW_ZONE = sz; model.invalidate() end end   -- строки трекера видят зону, пока клипы играют (7 окт)
  if MX.SS.rec then ctx.ss_rec_tick() end                                -- запись в клип: стоп за концом слота
  SL.sg.tick(0.006)                                     -- спектрограммы: досчитать кусочек (5 окт)
  -- нота с удержанием: длина растёт в темпе; клавиша отпущена — запись
  if state.hold then
    local h = state.hold
    local now = reaper.time_precise()
    local rows = math.max(1, math.floor((now - h.t0) / h.row_dur) + 1) + h.extra
    vim.cur.row = h.row + rows - 1
    local ks = reaper.JS_VKeys_GetState(h.t0 - 0.5)        -- KEYDOWN после нажатия без KEYUP = держится
    local down = h.vk > 0 and ks and ks:byte(h.vk) ~= 0
    if not down and now - h.t0 > 0.08 then
      h.rows = rows
      state.hold = nil
      local ok, err = pcall(edit.hold_insert, h)
      PV.stop()
      vim.cur.row = h.row + rows
      model.invalidate()
      vim.msg = ok and ('inserted %d row(s)%s'):format(rows, h.stretch and ', stretched' or '') or ('hold: ' .. tostring(err):match('[^\n]*$'))
    else
      vim.msg = ('hold: %d row(s)%s - release to insert, j / down: +1, Esc: cancel'):format(rows, h.stretch and ' stretch' or '')
    end
  end
  -- живой арпеджиатор: держатся клавиши — шаги арпеджио в темпе; отпущены все —
  -- конец, курсор после последней ноты
  if state.arpl then
    local a = state.arpl
    local now = reaper.time_precise()
    local ks = reaper.JS_VKeys_GetState(a.t0 - 0.5)
    local held = {}
    for _, k in ipairs(a.keys) do if (k.vk > 0 and ks and ks:byte(k.vk) ~= 0) or now - a.last < 0.08 then held[#held + 1] = k.pitch end end
    if #held == 0 then
      state.arpl = nil
      vim.cur.row = a.row0 + (a.done + 1) * a.step
      model.invalidate()
      vim.msg = ('arp live: %d note(s) written'):format(a.done + 1)
    else
      local k = math.floor((now - a.t0) / (a.row_dur * a.step))
      while a.done < k do
        a.done = a.done + 1
        -- арп из слайсов (4 окт): держатся клавиши-слайсы — без октав, по номерам
        local seq = edit.arp_order(held, a.order, a.entry and 1 or a.oct, a.done * 7919 + 1)
        local p = seq[a.done % #seq + 1]
        local row = a.row0 + a.done * a.step
        local ok, it
        if a.entry then
          local k = p - (model.SLICE_BASE or model.BASE_NOTE or 60) + 1
          if k >= 1 and k <= #(a.entry.slices or {}) then
            ok, it = pcall(edit.insert_slice, a.track, a.lane_idx, state.lpb, row, a.entry.item, k)
            ctx.preview_slice(a.track, a.entry, a.entry.slices[k], (not a.entry.playthru and a.entry.slices[k + 1]) or a.entry.len)
          end
        else
          ok, it = pcall(edit.insert_note, a.track, a.lane_idx, state.lpb, row, p, a.vel, a.step, a.item)
        end
        -- аудио-копия — длиной в шаг (иначе следующая нота уйдёт в новую подколонку)
        if ok and it and reaper.ValidatePtr(it, 'MediaItem*') then
          local dur = edit.row_time(row + a.step, state.lpb, 0) - edit.row_time(row, state.lpb, 0)
          if reaper.GetMediaItemInfo_Value(it, 'D_LENGTH') > dur then reaper.SetMediaItemInfo_Value(it, 'D_LENGTH', dur) end
        end
        if not a.entry then ctx.preview(a.track, p, a.item, row, a.step) end
      end
      vim.cur.row = a.row0 + a.done * a.step
      vim.msg = ('arp live %s: %d notes held, step %d - release all to stop'):format(a.order, #held, a.step)
    end
  end
  -- видоизменённые копии (3 окт): правка уже сделала их уникальными —
  -- спросить, не применить ли то же ко всем связанным
  if not OPT.ask.active and #edit.modified > 0 then
    local mods = edit.take_modified()
    local others = 0
    for _, m in ipairs(mods) do others = others + #edit.items_with_iid(m.old) end
    OPT.ask.open(('%d note(s) changed (stretch / offset)'):format(#mods), ('linked to %d other note(s) of the same item'):format(others), {
      { key = 'u', label = 'only this one - it becomes unique', fn = function() vim.msg = ('%d note(s) made unique'):format(#mods) end },
      { key = 'a', label = ('apply to all %d linked'):format(others), fn = function() vim.msg = ('applied to %d linked note(s)'):format(edit.propagate(mods)) end },
    })
  end
  if state.prev_hold and gfx.mouse_cap & 1 == 0 then PV.stop(); state.prev_hold = nil end   -- hold: кнопка отпущена
  peak_cache = {}; scope_cache = {}; spec_cache = {}; fxv_cache = {}; view_cache = {}   -- env_cache — по ключу состояния (env_values)
  local is_playing = playing()
  -- упреждение курсора (3 окт, опция cursor lead): позиция читается в начале
  -- тика defer, а на экран кадр попадает позже (~полкадра при 30 Гц) — курсор
  -- рисуется туда, где звук будет в момент показа
  local playpos = is_playing and reaper.GetPlayPosition() or nil
  local playpos_view = playpos and (playpos + (state.curlead or 15) / 1000 * (reaper.Master_GetPlayRate(0) or 1))   -- только для вида
  -- стоп на =END (3 окт): песня кончается маркером, а не концом проекта
  -- (библиотека за =LIB отодвигает конец проекта). Только если играть начали
  -- до =END — прослушивание библиотеки за ним не мешаем; запись не трогаем
  -- замер старта (4 окт): от первого кадра с play до сдвига позиции (сколько
  -- REAPER готовит воспроизведение) — в пульс hb как start
  if is_playing then
    local ps = prof.ps
    if not ps then prof.ps = { t = reaper.time_precise(), pos = playpos }
    elseif not ps.done and math.abs(playpos - ps.pos) > 1e-4 then ps.done = true; prof.start_ms = (reaper.time_precise() - ps.t) * 1000 end
  else prof.ps = nil end
  if is_playing then
    if state.play_from == nil then state.play_from = playpos end
    local endp = snap and snap.end_pos
    if state.endstop and endp and state.play_from < endp - 1e-6 and playpos >= endp and reaper.GetPlayState() & 4 == 0 then
      reaper.OnStopButton()
      is_playing, playpos = false, nil
      vim.msg = 'stopped at =END'
    end
  else state.play_from = nil end
  local curpos = reaper.GetCursorPosition()
  do
    local t = playpos or curpos
    local b, meas, cml, _, cdenom = reaper.TimeMap2_timeToBeats(0, t)
    beat_info.bar, beat_info.beat = (meas or 0) + 1, b or 0
    beat_info.num, beat_info.den = math.floor((cml or 4) + 0.5), math.floor((cdenom or 4) + 0.5)
    beat_info.rows_bar = math.floor(beat_info.num * 4 / math.max(1, beat_info.den) * state.lpb + 0.5)
  end
  local changed
  snap, changed = model.snapshot(state.lpb)
  draw.inst_of = snap and snap.inst_of
  draw.inst_num = snap and snap.inst_num
  draw.lib_zone = nil                     -- зона слайса на мини-волне lib: ставит вкладка item (3 окт)
  draw.vbars = {}                         -- скролл-бары списков: заполняет отрисовка кадра (4 окт)
  draw.itemnames = state.itemnames
  regions = model.regions(state.lpb)
  seq = ctx.sequence()
  draw.pmark('layout, status, info')
  local t_1 = reaper.time_precise()
  if changed then
    prof.rebuild = (t_1 - t_0) * 1000                              -- пересборка снимка (пульс hb)
    local b = model.bprof or {}
    prof.rb = ('env %.1f pool %.1f mod %.1f fx %.1f'):format((b.envs or 0) * 1000, (b.pool or 0) * 1000, (b.mods or 0) * 1000, (b.fx or 0) * 1000)
  end
  -- модуль слайсов (4 окт): колонка, пока у выбранного инструмента есть слайсы
  -- 8 окт: под инструментами (slices = split) — всегда, и на пустом слоте (заголовок + подсказка)
  do local sr = ctx.slice_root(); state.slices_on = ((sr and not sr.file) or state.slicespos == 'split') and true or false end
  ctx.hdr_poll()                                       -- sync track header size (6 окт)
  relayout()
  local t_2 = reaper.time_precise()
  if playpos then process_queue(playpos); process_jumps(playpos); process_orca(playpos) else jump_row_done = nil; orca_row_done = nil end
  publish_matrix(playpos); publish_state(is_playing); poll_gridkey(); poll_cmd(); poll_midi_in(); poll_audio_in(reaper.time_precise()); settle_puts(reaper.time_precise()); mm_settle(reaper.time_precise()); learn_poll()

  -- LOCK: трекер — зеркало REAPER. Edit-курсор / выделенный трек изменились
  -- в REAPER → курсор трекера прыгает туда (вид — следом); курсор трекера
  -- сдвинулся (клавиши, мышь) → edit-курсор и выделение трека REAPER следом.
  -- Сравнение с последним синхронным состоянием, чтобы стороны не спорили.
  if state.lock and L and L.flat and #L.flat > 0 then
    local sel_tr = reaper.GetSelectedTrack(0, 0)
    local function fi_of(tr)
      for i, f in ipairs(L.flat) do if f.col and f.col.track == tr and not f.env then return i end end
    end
    local cur_f = L.flat[vim.cur.fi]
    local cur_tr = cur_f and cur_f.col and cur_f.col.track
    if lock_sync.cp == nil then
      lock_sync.cp, lock_sync.tr, lock_sync.row, lock_sync.fi = curpos, sel_tr, vim.cur.row, vim.cur.fi
    elseif math.abs(curpos - lock_sync.cp) > 1e-9 or sel_tr ~= lock_sync.tr then
      -- REAPER → трекер
      -- за =END (склад сэмплов) трекер за курсором REAPER не прыгает (2 окт)
      if math.abs(curpos - lock_sync.cp) > 1e-9 and not (snap and snap.end_pos and curpos >= snap.end_pos - 1e-6) then
        local r = math.max(0, math.floor(model.row_of_time(curpos, state.lpb) + 1e-6))
        vim.cur.row = r
        if r < state.row0 or r >= state.row0 + L.nrows then state.row0 = math.max(0, r - math.floor(L.nrows / 3)) end
      end
      if sel_tr and sel_tr ~= lock_sync.tr and sel_tr ~= cur_tr then
        local fi = fi_of(sel_tr); if fi then vim.cur.fi = fi end
      end
      lock_sync.cp, lock_sync.tr, lock_sync.row, lock_sync.fi = curpos, sel_tr, vim.cur.row, vim.cur.fi
    elseif vim.cur.row ~= lock_sync.row or vim.cur.fi ~= lock_sync.fi then
      -- трекер → REAPER
      if vim.cur.row ~= lock_sync.row and not is_playing then
        reaper.SetEditCurPos(edit.row_time(vim.cur.row, state.lpb, 0), false, false)
      end
      if vim.cur.fi ~= lock_sync.fi and cur_tr and cur_tr ~= sel_tr then reaper.SetOnlyTrackSelected(cur_tr) end
      lock_sync.cp, lock_sync.tr = reaper.GetCursorPosition(), reaper.GetSelectedTrack(0, 0)
      lock_sync.row, lock_sync.fi = vim.cur.row, vim.cur.fi
    end
  end

  -- step listen (4 окт): транспорт стоит, курсор трекера сменил строку — эта
  -- строка звучит (все треки, с FX) на длину строки, как play line в Renoise
  if state.steplisten and state.focus == 'tracker' and not vim.picker and not vim.hydra then
    local r = vim.cur.row
    if ctx.sl_row ~= r then
      local prev = ctx.sl_row
      ctx.sl_row = r
      if prev and (not is_playing or ctx.sl_own) and (vim.mode == 'normal' or vim.mode == 'insert' or vim.mode == 'visual' or vim.mode == 'vline') then
        local t0 = edit.row_time(r, state.lpb, 0)
        PV.midi(t0, edit.row_time(r + 1, state.lpb, 0))
        ctx.sl_own = true
      end
    end
    if not PV.playing() then ctx.sl_own = false end
  end
  -- fixed cursor: вид всегда ставит строку курсора в середину тела
  if state.fixed and L and L.nrows then
    state.row0 = vim.cur.row - math.floor(L.nrows / 2)
  end
  local ph_row = playpos_view and model.row_of_time(playpos_view, state.lpb) or nil   -- вид: с упреждением
  if is_playing and state.follow and ph_row then
    local r = math.floor(ph_row)
    if r < state.row0 or r > state.row0 + math.floor(L.nrows * 2 / 3) then
      state.row0 = math.max(0, r - math.floor(L.nrows / 3))
    end
  end
  -- вид reg (2 окт): только строки региона курсора (при игре с follow — плейхеда),
  -- прокрутка в его пределах, строки вне региона пустые
  local view_clip
  if state.view_reg then
    local ref = (is_playing and state.follow and ph_row) and math.floor(ph_row) or vim.cur.row
    local rg = alias.region_at(regions, edit.row_time(ref, state.lpb, 0))
    if rg then
      -- границы как у region_at (по времени): строка внутри региона не гасится
      local r0, r1 = math.floor(rg.r0 + 1e-6), math.ceil(rg.r1 - 1e-6)
      if not state.fixed then state.row0 = math.max(r0, math.min(state.row0, math.max(r0, r1 - L.nrows))) end
      view_clip = { r0, r1 }
    end
  end
  rows = model.rows(state.row0, L.nrows, state.lpb)
  if view_clip then
    for _, r in ipairs(rows) do
      -- номер строки настоящий (рамки, линейка, клики считают от него), флаг clip гасит строку
      if r.row < view_clip[1] or r.row >= view_clip[2] then r.clip = true; r.label = ''; r.bar = false; r.beat = false end
    end
  end

  fps.n = fps.n + 1
  local now = reaper.time_precise()
  if now - fps.t >= 1 then
    fps.v = fps.n / (now - fps.t); fps.n = 0; fps.t = now
    local n = math.max(1, prof.n)
    -- лайв (2 окт): кроме средних — худший кадр секунды и последняя правка
    ctx.hb_last = string.format('%s %d %s/%s x' .. tostring(state.fontscale) .. ' %.0ffps snap %.1f layout %.1f draw %.1f upd %.1f ms max %.1f edit %.1f (%s) rebuild %.1f [%s]',
      os.date('%H:%M:%S'), #snap.cols, vim.mode, state.focus, fps.v,
      prof.snap / n * 1000, prof.layout / n * 1000, prof.draw / n * 1000, prof.upd / n * 1000,
      prof.max * 1000, edit.last_ms or 0, edit.last_desc or '', prof.rebuild or 0, prof.rb or '') .. (' start %.0f rerun %d keyrep %d lua %dKB'):format(prof.start_ms or -1, prof.reruns or 0, ctx.key_repeats or 0, math.floor(collectgarbage('count')))
    reaper.SetExtState(EXT, 'hb', ctx.hb_last, false)
    prof.snap, prof.layout, prof.draw, prof.upd, prof.n, prof.max = 0, 0, 0, 0, 0, 0
  end
  -- статус-бар: слева только то, чего нет в контрол-блоке сверху (режим Vim,
  -- набранные клавиши, фокус, очередь, сообщение); остальное — описание того,
  -- на что наведена мышь (state.status)
  local mode = vim.status()
  local left = mode ~= '' and mode or (state.focus ~= 'tracker' and '' or 'NORMAL')
  if state.focus ~= 'tracker' then left = left .. (left ~= '' and ' ' or '') .. state.focus:upper() .. (state.focus == 'top' and (':' .. state.toptab) or '') end
  if MX.queued then left = left .. ' | queue: ' .. (MX.queued.name ~= '' and MX.queued.name or MX.queued.idx) end
  if vim.msg ~= '' then left = left .. ' | ' .. vim.msg end
  if state.debug or reaper.GetExtState(EXT, 'dbgon') == '1' then
    left = left .. string.format(' | %.0f fps | key %d @%s | peaks %d', fps.v, state.last_key, ctx.last_trace or '-', model.peaks_cache_size())
  end

  local vis
  if vim.mode == 'visual' or vim.mode == 'vline' then
    local f0, f1, r0, r1 = vim.visual_range()
    vis = { f0 = f0, f1 = f1, r0 = r0, r1 = r1 }
    ctx.vis_sync(vis)
  else ctx.vis_key = nil end
  -- простой (3 окт): 1.5 с без мыши / клавиш / правок проекта, не играет,
  -- нет превью — рисуем каждый третий кадр (~10 fps); любое действие сразу
  -- возвращает полную частоту. Пропущенный кадр берёт hover прошлого.
  local idle_skip = false
  do
    local now_t = reaper.time_precise()
    local mkey = gfx.mouse_x .. ',' .. gfx.mouse_y .. ',' .. gfx.mouse_cap .. ',' .. gfx.w .. ',' .. gfx.h
    if mkey ~= idle.mkey or is_playing or changed or gfx.mouse_wheel ~= 0 or (now_t - idle.input_t) < 1.5
       or PV.playing() or vim.picker or vim.hydra or state.bpm_edit then
      idle.active_t, idle.mkey = now_t, mkey
    end
    idle.n = idle.n + 1
    -- пропуск кадров напрямую ОТКЛЮЧЁН (3 окт: окно мигало — пропущенный кадр
    -- не держит картинку). Частота кадров (опция fps 30 / 25 / 24) — через
    -- буфер 1021: весь интерфейс рисуется в него с выбранной частотой, а на
    -- каждом тике defer буфер выводится на экран; max — прямо, без буфера.
    -- Выше ~33 fps скрипт не может: defer REAPER тикает около 30 раз в секунду.
    local fps_t = tonumber(state.fps)
    if fps_t then
      if fps_buf.w ~= gfx.w or fps_buf.h ~= gfx.h then gfx.setimgdim(1021, gfx.w, gfx.h); fps_buf.w, fps_buf.h = gfx.w, gfx.h; fps_buf.last = 0 end
      gfx.dest = 1021
      if now_t - fps_buf.last >= 1 / fps_t - 0.004 or not idle.hover then fps_buf.last = now_t
      else idle_skip = true end
    end
  end
  if not idle_skip then HN.reset() end
  if state.rec_sess and reaper.GetPlayState() & 4 == 0 and not OPT.ask.active then ctx.rec_finish(false) end   -- запись остановили снаружи
  edit.xfade.on, edit.xfade.len, edit.xfade.mode = state.xfade, (state.xfade_ms or 10) / 1000, state.xfademode or 'vol'
  edit.swing_read()                                    -- свинг сетки проекта REAPER (6 окт)
  draw.icons = false                                     -- Nerd-иконки убраны (3 окт)
  draw.envpoints = state.envpoints ~= false
  draw.envfmt = state.envfmt or 'midi'
  draw.hybrid = not draw.ttf                             -- не-ASCII в битмапе — моно-шрифтом высотой с битмап; TTF всё умеет сам (5 окт)
  local hover
  if idle_skip then hover = idle.hover else
  -- 8 окт: вкладка automation включает в lib строку automation — в модуле
  -- слайсов список automation items трека; уход с вкладки — обратно, если
  -- включила она (выбранное руками остаётся)
  do
    local tab = state.top and state.toptab or nil
    if tab ~= ctx.tab_seen then
      if tab == 'modulation' and not state.auto_inst then state.auto_inst = true; ctx.auto_by_tab = true
      elseif ctx.tab_seen == 'modulation' and ctx.auto_by_tab then state.auto_inst = false; ctx.auto_by_tab = nil end
      ctx.tab_seen = tab
    end
    if not state.auto_inst then ctx.auto_by_tab = nil end
  end
  hover = draw.frame(L, snap, rows, state, {
    ph_row = ph_row, cur_row = model.row_of_time(curpos, state.lpb), playing = is_playing,
    status_left = state.kslider and ('-- SLIDER %s --  h l value, j k slider, Esc done'):format(state.kslider.what) or left,   -- 5 окт: режим слайдера виден
    status_right = (state.focus == 'matrix' and MX.pending_hint()) or (state.focus == 'dsp' and DK.pending_hint()) or (state.focus == 'inst' and IK.pending_hint())
      or (state.focus ~= 'matrix' and state.focus ~= 'dsp' and state.focus ~= 'inst' and vim.pending_hint()) or state.status,
    vcur = vim.cur, vis = vis, focus = state.focus, regions = seq, vmode = vim.mode,
    ruler = ruler_info(),
    hdrfill = state.hdrfill,
    -- блок трека в DSP (3 окт): вход, отправки, master send, фаза, FX вкл
    swap_state = function() return (ctx.swap_info()) end,
    -- пианинка (4 окт): октава, держимые клавиши (JS_VKeys), последняя сыгранная
    piano = (function()
      -- клавиши идут в пианинку только из трекера / вкладки сэмпла (5 окт):
      -- в другом модуле — без подсветки нажатий, полоса блёклая; m off
      -- (6 окт) — клавиатура не прячется, тоже блёклая
      local active = state.piano_show and (state.focus == 'tracker' or (state.focus == 'top' and state.toptab == 'sample'))
      local held = {}
      if active and reaper.JS_VKeys_GetState then
        local ks = reaper.JS_VKeys_GetState(reaper.time_precise() - 30)
        for code, off in pairs(keys.piano) do
          local vk = string.char(code):upper():byte()
          if ks and ks:byte(vk) ~= 0 then held[off] = true end
        end
      end
      return { octave = vim.octave, held = held, last = active and vim.piano_last or nil, active = active and true or false }
    end)(),
    zone_draw = function(Lx, x, y, w, h) return OPT.tour.draw_zone(U, Lx, x, y, w, h, ctx.fit) end,
    input_name = function(col) return (col.track and reaper.ValidatePtr(col.track, 'MediaTrack*')) and ctx.input_name(col.track) or '' end,
    in_open = function(col) return vim.picker and vim.picker.inp == col.guid end,
    dsp_levels = (state.dsp and not state.khelp and state.dspmeters ~= false) and ctx.dsp_levels or nil,   -- опция dsp meters (5 окт)
    fx_delta = ctx.fx_delta,
    fx_preset = ctx.fx_preset,
    airwin_info = ctx.airwin_info,
    fx_ab = ctx.ab_get,
    step_labels = ctx.step_labels,
    smart_ok = reaper.file_exists(ctx.smart_input_path),
    dsptrack = state.dsptrack,
    eqgraph = state.eqgraph,
    -- шапка трека (7 окт, опция header info): инструменты lib, инсерты, сенды
    hdr_info = state.hdrinfo and function(col) return ctx.hdr_info(col) end or nil,
    clipsview = state.clipsview, dsp_big = state.dsp_big, fxrow = state.fxrow, fxparams = state.fxparams, fx_stack = ctx.fx_stack,
    -- роутер в панели DSP FX (7 окт): схема вместо блоков
    dsp_router = state.dsp_big,
    draw_router = function(x, y, w, h)
      local root, _, title = ctx.db_tree()
      if not root then return {} end
      return MX.DB.draw(L, x, y, w, h, root, title, false, false, true)
    end,
    trk_io = (state.dsp and not state.khelp) and function(col)
      local tr = col and col.track
      if not (tr and reaper.ValidatePtr(tr, 'MediaTrack*')) then return nil end
      local inp = ctx.input_name(tr)
      local sends = {}
      for i = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
        local _, nm = reaper.GetTrackSendName(tr, i, '')
        sends[#sends + 1] = { name = nm, vol = reaper.GetTrackSendInfo_Value(tr, 0, i, 'D_VOL'), mute = reaper.GetTrackSendInfo_Value(tr, 0, i, 'B_MUTE') == 1 }
      end
      return { input = inp, sends = sends, hw = reaper.GetTrackNumSends(tr, 1), recv = reaper.GetTrackNumSends(tr, -1),
               mainsend = reaper.GetMediaTrackInfo_Value(tr, 'B_MAINSEND') == 1,
               phase = reaper.GetMediaTrackInfo_Value(tr, 'B_PHASE') == 1,
               fxen = reaper.GetMediaTrackInfo_Value(tr, 'I_FXEN') == 1 }
    end or nil,
    -- метки линейки таймлайна для строки (3 окт): форматы REAPER (2 — такты.доли, 0 — время)
    tl_label = state.tlruler ~= 'off' and function(row)
      local t = reaper.TimeMap2_QNToTime(0, row / state.lpb)
      local b = reaper.format_timestr_pos(t, '', 2):gsub('%.00$', '')
      return b, reaper.format_timestr_pos(t, '', 0)
    end or nil,
    punch = (function() local p = ctx.cmd_by_text('record mode: time selection auto punch'); return p and reaper.GetToggleCommandState(p) == 1 end)(),
    timesel = (function()
      local a, b = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
      if b - a < 1e-6 then return nil end
      return { model.row_of_time(a, state.lpb), model.row_of_time(b, state.lpb) }
    end)(),
    cur_region_full = (function()
      local rg = alias.region_at(regions, edit.row_time(vim.cur.row, state.lpb, 0))
      if not rg then return nil end
      return { name = rg.name, idx = rg.idx, rgb = region_rgb(rg.color) }
    end)(),
    cur_ci = (L.flat[vim.cur.fi] or {}).ci,
    seam_guide = seam_drag and seam_drag.active and seam_drag.guide or nil,
    dragging = (B.drag and B.drag.active) or (SL.drag and SL.drag.kind == 'out' and SL.drag.active) or (retro.out and retro.out.active) or nil,
    view_reg = state.view_reg, view_clip = view_clip, region_rgb = region_rgb, sig_at = ctx.sig_at, kslider = state.kslider, mx_bar_label = mx_bar_label, mx_ticks = mx_ticks, mx_marks = mx_marks(),
    inst_range = IK.anchor and { IK.range(vim.inst) } or nil,
    file_peaks = ctx.file_peaks,
    -- живой вид модуля DSP: гранулятор — gmem jf_grgrain (GB = 20000), раз в кадр
    dsp_view = function(kind, width)
      -- jf_rec в DSP (4 окт): буфер трека DSP; открыта вкладка rec — её же
      -- данные (иначе две ширины слоя пиков спорят в gmem)
      if kind == 'rec' then
        if view_cache.rec ~= nil then return view_cache.rec or nil end
        local col = cur_col()
        if retro.cur and col and retro.cur.col.guid ~= col.guid then retro.cur = nil end
        local r = (state.top and state.toptab == 'retro') and retro_read(math.max(16, math.floor(gfx.w - L.ctrl_w - L.inst_w - 4 * L.pad)))
          or retro_read(math.max(16, math.floor(width or 200)))
        if not (r and r.cur and col and r.cur.col.guid == col.guid) then r = false end
        view_cache.rec = r
        return r or nil
      end
      if kind ~= 'grain' then return nil end
      if view_cache.grain ~= nil then return view_cache.grain or nil end
      local g = with_ns('jf_grgrain', function()
        local GB = 20000
        local t = { wave = {}, grow = {} }
        for i = 0, 15 do t.wave[i + 1] = reaper.gmem_read(GB + 1600 + i) or 0; t.grow[i + 1] = reaper.gmem_read(GB + 1760 + i) or -1 end
        t.pos, t.z0, t.z1 = reaper.gmem_read(GB + 1640) or 0, reaper.gmem_read(GB + 1641) or 0, reaper.gmem_read(GB + 1642) or 0
        t.rec, t.head = (reaper.gmem_read(GB + 1643) or 0) > 0.5, reaper.gmem_read(GB + 1644) or 0
        local any = 0
        for i = 1, 16 do any = any + t.wave[i] end
        t.alive = any > 0 or t.pos > 0
        return t
      end)
      view_cache.grain = g or false
      return g
    end,
    pat_num = function(rg) local _, by = model.patterns(regions); local p = by[rg.name]; return p and p.num or rg.idx end,
    loop_cells = MX.loops and ctx.loop_cells() or nil, loop_text = GD.cell_text,
    env_values = env_values, pool_col = cur_col(), inst = vim.inst,
    perf_draw = (ctx.PERF and ctx.PERF.active) and function(Lx, x, y, w, h) ctx.PERF.draw(U, Lx, x, y, w, h, ctx.hb_last, ctx.fit) end or nil,
    pool_ci = (L.flat[vim.cur.fi] or {}).ci, cols = state.ptmode and ctx.visible_cols() or snap.cols, peaks = track_peaks, poolsort = state.poolsort,
    cur_region = alias.region_at(regions, edit.row_time(vim.cur.row, state.lpb, 0)),
    scope = state.scopes and scope_read or nil,
    spec = state.scopes and spec_read or nil, spec_frame = spec_frame, scopemode = state.scopemode,
    mono = (state.top and state.gridtab and state.toptab == 'grid') and mono_read() or nil,
    master = (state.top and (state.toptab == 'master' or state.toptab == 'scope') and snap.master) and {
      peaks = { reaper.Track_GetPeakInfo(snap.master.track, 0), reaper.Track_GetPeakInfo(snap.master.track, 1) },
      scope_slot = snap.master.scope_slot, fx = snap.master.fx } or nil,
    retro = (state.top and state.toptab == 'retro') and retro_read(math.max(16, math.floor(gfx.w - L.ctrl_w - L.inst_w - 4 * L.pad))) or nil,
    dsp_sel = state.focus == 'dsp' and dsp_sel or nil,
    ctrl_sel = state.ctrl_sel,
    dsp_learn = dsp_learn and dsp_learn.k or nil,
    dsp_range = (state.focus == 'dsp' and DK.anchor) and { DK.range(dsp_sel) } or nil,
    fx_values = function(f) local col = dsp_target(); if not col then return {} end
      local v = fxv_cache[f]; if not v then v = model.fx_values(col.track, f); fxv_cache[f] = v end; return v end,
    dsp_fxs = (function() local t = dsp_target(); return t and t.fx or {} end)(),
    dsp_title = (function() local t = dsp_target(); if not t then return nil end
      return t.take and ('take fx: ' .. t.name .. '  (' .. t.col.name .. ')') or t.name end)(),
    dsp_is_take = (function() local t = dsp_target(); return t and t.take or false end)(),
    ctrl = {
      bigbpm = state.bigbpm, bigstatus = state.bigstatus,
      playing = is_playing, pos = fmt_pos(playpos or curpos), bpm = reaper.Master_GetTempo(), bpm_edit = state.bpm_edit,
      lpb = state.lpb, oct = vim.octave, vel = vim.vel, step = vim.step_next and 'next' or (vim.step_auto and 'auto' or vim.step), inst = vim.inst,
      follow = state.follow, lock = state.lock, fixed = state.fixed, loop = reaper.GetSetRepeat(-1) == 1,
      pitchmode = (cur_col() and state.pitchmodes[cur_col().guid]) or 'shift',
      font = state.font, scale = state.fontscale, fx = state.fxcols, meters = state.meters, wave = state.wave,
      captions = state.captions, hdrfill = state.hdrfill,
      xfade = state.xfade, xfade_ms = state.xfade_ms, khelp = state.khelp, hints = state.hints, notes = state.notes_open,
      -- открытые окна (4 окт): их кнопки в главном модуле — оранжевым фоном
      about_open = OPT.active and OPT.page == 'about', options_open = OPT.active and OPT.page ~= 'about',
      q_wave = (state.wavemode or 'back') ~= 'off', q_meters = state.meters, q_ruler = (state.tlruler or 'off') ~= 'off',
      q_names = state.itemnames, q_colors = state.itemcol, q_input = state.hdrin ~= false, q_preview = state.preview, q_endstop = state.endstop, q_captions = state.captions,
      q_keys = state.keycast, q_listen = state.steplisten,
      q_dsp = state.dsp, q_side = state.side, q_mx = not state.mx_hidden, q_envs = state.envs, q_scopes = state.scopes, q_hints = state.hints,
      tour = OPT.tour.active, ss_open = vim.hydra ~= nil and (vim.hydra.title or ''):match('^screenset') ~= nil,
      metro = reaper.GetToggleCommandState(40364) == 1,
      ptabs = state.ptabs and (function()
        local out, cur = {}, reaper.EnumProjects(-1)
        for i = 0, 63 do
          local p = reaper.EnumProjects(i); if not p then break end
          local nm = (reaper.GetProjectName(p) or ''):gsub('%.[Rr][Pp][Pp]$', '')
          out[#out + 1] = { name = nm ~= '' and nm or 'unsaved', on = p == cur, dirty = reaper.IsProjectDirty(p) ~= 0 }
        end
        return out
      end)() or nil,
      quick = ctx.quick_str(), qgen = ctx.quick_generic(), oneclick = state.oneclick, autofocus = state.autofocus, swing_on = edit.sw.on, swing_txt = ctx.swing_label(), perf = ctx.PERF and ctx.PERF.active, debug = state.debug,
      recording = reaper.GetPlayState() & 4 == 4, reclib = state.reclib, tpbuttons = state.tpstyle == 'big', tptext = state.tpstyle == 'text', playstate = reaper.GetPlayState(),
      punch = (function() local p = ctx.cmd_by_text('record mode: time selection auto punch'); return p and reaper.GetToggleCommandState(p) == 1 end)(),
      preroll = (function() local p = ctx.cmd_by_text('pre-roll on record'); return p and reaper.GetToggleCommandState(p) == 1 end)(),
      -- размер и доли (2 окт): такт, доля в такте, строк на такт
      sig_num = beat_info.num, sig_den = beat_info.den, bar = beat_info.bar, beat = beat_info.beat, rows_bar = beat_info.rows_bar,
    },
    tabs = ctx.top_tabs(),
    toptab = state.toptab, modsel = modsel, poolprev = state.poolprev, auto_inst = state.auto_inst, auto_n = state.auto_inst and #ctx.ai_list() or nil,
    inspreview = state.preview,
    -- выделенные в REAPER треки (3 окт): фон их колонок чуть светлее; опрос
    -- каждый кадр — смена выделения не всегда пересобирает снимок
    trsel = (function()
      local t = {}
      for _, c in ipairs(snap.cols or {}) do
        if c.track and reaper.ValidatePtr(c.track, 'MediaTrack*') and reaper.IsTrackSelected(c.track) then t[c.guid] = true end
      end
      return t
    end)(),
    trs_live = trs_drag and trs_drag.v and { guid = trs_drag.col.guid, what = trs_drag.what, v = trs_drag.v } or nil,
    khelp = state.khelp,
    hint_bars = state.hints and function(p) return KH.BARS[p] end or nil,
    browser_page = (B.mode == 'pm' and B.grid and state.pmgrid and not B.pmproj) and 'pm' or 'browser',   -- полоса подсказок сайдбара (6 окт)
    top_page = (state.toptab == 'garden' and 'orca') or (state.toptab == 'scope' and 'master') or state.toptab,
    notes_win = state.notes_win,
    keycast = state.keycast and ctx.kc or nil, now = reaper.time_precise(), keycast_scale = state.kc_scale,
    notes_draw = (state.top and state.notes_open) and function(Lx, x, y, w, h)
      -- свой масштаб текста (− + в шапке заметок): битмап ×N на время отрисовки
      local sc = state.notes_scale or 0
      NT.show_dev = state.debug
      if sc <= 0 or sc == draw.SCALE then return NT.draw(U, Lx, x, y, w, h, state.focus == 'notes', ctx.fit, NT.title) end
      local s0, extra = draw.SCALE, Lx.rh - draw.texth()
      draw.SCALE = sc
      local L2 = setmetatable({ rh = draw.texth() + extra, cw = draw.measure('W') }, { __index = Lx })
      local ok, r = pcall(NT.draw, U, L2, x, y, w, h, state.focus == 'notes', ctx.fit, NT.title)
      draw.SCALE = s0
      if not ok then error(r, 0) end
      return r
    end or nil,
    -- набор в браузере эффектов: всплывашка удобного размера (3 окт)
    fxb_expand = state.focus == 'fxb',                          -- фокус (клик / Tab) — раскрыт
    fxb_px = state.fxb_px,
    fxb_draw = (state.dsp and state.fxb and not state.khelp and not state.browserleft) and function(Lx, x, y, w, h)
      if #FB.list == 0 and not FB.loaded then FB.loaded = true; FB.list = ctx.fx_list(); ctx.fxb_load_native() end
      return FB.draw(U, Lx, x, y, w, h, state.focus == 'fxb', ctx.fit)
    end or nil,
    dsp_drag = (dsp_drag and dsp_drag.active and { k = dsp_drag.fx }) or (fxb_drag and fxb_drag.active and { new = true }) or nil,
    khelp_draw = function(Lx, x, y, w, h)
      return KH.draw(U, Lx, x, y, w, h, reaper.time_precise(), state.focus == 'dsp', ctx.fit)
    end,
    garden_draw = function(Lx, x, y, w, h)
      return GD.draw(Lx, x, y, w, h, snap, seq, { play_row = ph_row, queued = MX.queued, garden_on = garden.f and garden.f.on },
                     state.focus == 'top' and state.toptab == 'garden')
    end,
    midi_draw = function(Lx, x, y, w, h)
      local hv = MM.draw(U, Lx, x, y, w, h, state.focus == 'top' and state.toptab == 'midi', ctx.fit)
      return hv
    end,
    clips_draw = function(Lx, x, y, w, h)
      if not snap then return {} end
      return MX.SS.draw_top(Lx, x, y, w, h, seq, ctx.ss_V(), ctx.ss_G(), reaper.time_precise(), reaper.GetPlayPosition())
    end,
    -- вкладка modulate (2 окт): нативная матрица модуляции + генератор кривых
    -- (lfo / podkat = Anticipate / follow). Широко — рядом, узко — страницы
    -- [matrix] [curves] (L переключает)
    mm_draw = function(Lx, x, y, w, h)
      local col = cur_col()
      local wide = w >= Lx.cw * 80
      local lw = wide and math.min(Lx.cw * 42, math.floor(w * 0.42)) or 0      -- кнопки форм влезают в строку
      lfo_hover = nil
      local names = {}
      for i, c in ipairs(snap and snap.cols or {}) do names[i] = c.name end
      LG.src_names = names
      if LG.src_i > #names then LG.src_i = math.max(1, #names) end
      local focused = state.focus == 'top'
      -- переключатель страниц сверху: узко — matrix / params / curves во всю
      -- ширину; широко — matrix / params слева, curves (LFO) всегда справа
      local function pages(px, list)
        local bx = px
        for _, b in ipairs(list) do
          local bw = U.measure(b[1]) + 2 * Lx.pad
          local on = mod_pane == b[2]
          local hot = gfx.mouse_x >= bx and gfx.mouse_x < bx + bw and gfx.mouse_y >= y and gfx.mouse_y < y + Lx.rh
          U.set(on and U.tint(U.AMBER, 0.3) or (hot and U.tint(U.TEXT, 0.08) or U.BG)); gfx.rect(bx, y, bw, Lx.rh, 1)
          U.set(on and U.AMBER or U.LINE); gfx.rect(bx, y, bw, Lx.rh, 0)
          U.text(bx + Lx.pad, y + 1, b[1], on and U.AMBER or U.GREY)
          if hot then lfo_hover = { pane = b[2] } end
          bx = bx + bw + 2
        end
      end
      local function left(lx, ly, lw2, lh)
        if mod_pane == 'ai' then
          ctx.AIE = ctx.AIE or dofile(DIR .. '/jf_tracker_aiedit.lua')
          ctx.AIE.swing_qn = edit.swing_qn
          -- справа узкий блок свойств item (6 окт): loop, повторы, playrate …
          local pw = math.min(Lx.cw * 26, math.floor(lw2 * 0.3))
          ctx.aied_hover = ctx.AIE.draw(U, Lx, lx, ly, lw2 - pw - Lx.pad, lh, state.ai_edit, ctx.fit,
            function(r) return edit.row_time(r, state.lpb, 0) end, function(t) return model.row_of_time(t, state.lpb) end, ctx.ai_list())
          local ph = ctx.AIE.props(U, Lx, lx + lw2 - pw, ly, pw, lh, state.ai_edit, ctx.fit)
          if ph then ctx.aied_hover = ph end
          return nil
        end
        if mod_pane == 'params' then
          local hv = MMX.PP.draw(Lx, lx, ly, lw2, lh, col, focused)
          if hv then lfo_hover = lfo_hover or { pane = 'params', pp = hv } end
          return nil
        end
        return MMX.draw(Lx, lx, ly, lw2, lh, col and col.mods or {}, focused and mod_pane == 'matrix', col and (col.name .. ' modulation') or 'modulation')
      end
      if not wide then
        pages(x, state.ai_edit and { { 'item', 'ai' }, { 'params', 'params' }, { 'matrix', 'matrix' }, { 'curves', 'lfo' } } or { { 'params', 'params' }, { 'matrix', 'matrix' }, { 'curves', 'lfo' } })
        y, h = y + Lx.rh + 2, h - Lx.rh - 2
        if mod_pane == 'lfo' then
          local tgt = ctx.lfo_target()
          local hv = LG.draw(U, Lx, x, y, w, h, focused, ctx.fit, tgt and tgt.label or nil, ctx.lfo_span_rows())
          lfo_hover = lfo_hover or hv
          return nil
        end
        return left(x, y, w, h)
      end
      local tgt = ctx.lfo_target()
      lfo_hover = LG.draw(U, Lx, x + w - lw, y, lw, h, focused and mod_pane == 'lfo', ctx.fit, tgt and tgt.label or nil, ctx.lfo_span_rows())
      U.set(U.LINE); gfx.rect(x + w - lw - Lx.pad, y, 1, h, 1)
      pages(x, state.ai_edit and { { 'item', 'ai' }, { 'params', 'params' }, { 'matrix', 'matrix' } } or { { 'params', 'params' }, { 'matrix', 'matrix' } })
      return left(x, y + Lx.rh + 2, w - lw - 2 * Lx.pad, h - Lx.rh - 2)
    end,
    sample_draw = function(x, y, w, h)
      local col = cur_col()
      local e = col and (col.pool or {})[vim.inst]
      -- файл из браузера (v / Space / auto) показывается вместо инструмента
      if SL.entry and SL.entry.file then e = SL.entry end
      -- слайсы вложены (3 окт): курсор на ноте-слайсе этого исходника — его зона
      local zi = vim.inst
      if e and not e.parent and not e.file and snap and snap.inst_of then
        local f = L and L.flat[vim.cur.fi]
        local cell = f and f.sub and f.sub[vim.cur.row]
        if cell and cell.kind == 'cont' then cell = cell.of end
        local ci = cell and cell.item and snap.inst_of[cell.item]
        local ce = ci and col.pool[ci]
        if ce and ce.parent == e then e, zi = ce, ci end
      end
      -- слайс / кусок: показываем исходник (родителя) с подсветкой играемой зоны
      local sel_e = e
      local zone
      if e and e.parent and not (SL.active and SL.entry == e) then
        local p = e.parent
        zone = { (e.offs - p.offs) / (p.rate ~= 0 and p.rate or 1), (e.offs - p.offs + e.len * e.rate) / (p.rate ~= 0 and p.rate or 1), zi }
        -- тянется край — зона живая
        if SL.zone_drag and SL.zone_drag.e.item == e.item then zone = { SL.zone_drag.a, SL.zone_drag.b, zi } end
        if mm_pend.zone and mm_pend.zone.e.item == e.item then zone = { mm_pend.zone.a, mm_pend.zone.b, zi } end   -- ручка MIDI
        draw.lib_zone = { root = p, a = zone[1], b = zone[2] }
        e = p
      end
      -- список слайсов (4 окт, как семплы внутри инструмента Renoise): справа,
      -- у lib; выбор — Option+J / K, клик, курсор на ноте-слайсе. Свойства —
      -- левее, правят выбранный слайс (или весь сэмпл)
      local lw = 0
      local root = e
      if root and not root.file and root.slices and #root.slices > 0 then
        -- курсор перешёл на другую ячейку — выбор следует за ним
        local ck = tostring(vim.cur.fi) .. ':' .. tostring(vim.cur.row)
        if ctx.ssel.item ~= root.item or ctx.ssel.cell ~= ck then
          local k0 = (sel_e and sel_e.parent == root and sel_e.slice_k) or ((ctx.ssel.item == root.item) and ctx.ssel.k) or 0
          ctx.ssel = { item = root.item, k = k0, cell = ck }
        end
        local k = ctx.ssel.k or 0
        if k > 0 then
          local child = ctx.slice_child(col, root, k)
          sel_e = child or root
          local ci = vim.inst
          for i, c in ipairs(col.pool) do if c == child then ci = i end end
          zone = { root.slices[k], root.slices[k + 1] or root.len, ci }
          draw.lib_zone = { root = root, a = zone[1], b = zone[2] }
        else sel_e = root; zone = nil end
        lw = 0                                       -- список — отдельный модуль справа (4 окт)
      end
      -- клип сессии в фокусе (6 окт): начало / конец клипа — зона (тянется),
      -- L — отрезок лупа (P_EXT:jf_cliploop, секунды источника; нет — весь клип),
      -- xf — кроссфейд шва; вид — клип во всю ширину, без панели свойств
      local cl = state.ss_clip
      if cl and not (state.clipsview or MX.clips or state.ss_big) then state.ss_clip, cl = nil, nil end   -- 8 окт: вид клипов закрыт — клипа нет
      if cl and e and not e.file and reaper.ValidatePtr(cl.item, 'MediaItem*') then
        local tk = reaper.GetActiveTake(cl.item)
        -- 8 окт: зона клипа — только на волне ЕГО файла (иначе линии L вставали
        -- на чужой сэмпл по чужим offset)
        local csrc = tk and reaper.GetMediaItemTake_Source(tk)
        local same = csrc and e.fpath and reaper.GetMediaSourceFileName(csrc, '') == e.fpath
        if tk and same and not reaper.TakeIsMIDI(tk) then
          local er = (e.rate and e.rate ~= 0) and e.rate or 1
          local eo = e.offs or 0
          local co = reaper.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS')
          local cr = reaper.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
          local clen = reaper.GetMediaItemInfo_Value(cl.item, 'D_LENGTH')
          local a = (co - eo) / er
          local b = a + clen * cr / er
          local _, lp = reaper.GetSetMediaItemInfo_String(cl.item, 'P_EXT:jf_cliploop', '', false)
          local la, lb = (lp or ''):match('^([%-%d%.]+);([%-%d%.]+)$')
          la, lb = tonumber(la), tonumber(lb)
          local _, xs = reaper.GetSetMediaItemInfo_String(cl.item, 'P_EXT:jf_clipxf', '', false)
          zone = { a, b, nil, clip = true, item = cl.item, er = er, eo = eo, cr = cr,
                   loop = la and { (la - eo) / er, (lb - eo) / er } or { a, b }, xf = (tonumber(xs) or 0) / 1000 }
          local zd = SL.zone_drag
          if zd and zd.clip and zd.item == cl.item then zone[1], zone[2], zone.loop = zd.a, zd.b, { zd.la, zd.lb } end
          state.ss_zone = zone
          -- вид: клип во всю ширину (один раз на клип — дальше зум свой)
          if cl.viewed ~= cl.item then
            cl.viewed = cl.item
            local m = math.max(0.02, (b - a) * 0.05)
            SL.zoom_e, SL.va, SL.vb = e.item, math.max(0, a - m), b + m
          end
        else state.ss_zone = nil end   -- 8 окт: клип не этого файла — зоны нет
      else state.ss_zone = nil end
      local pw = sel_e and math.min(L.cw * 90, math.floor((w - lw) * 0.55)) or 0   -- 5 окт: втрое шире, слайдеры
      ctx.sprops_maxw = pw
      if sel_e and not sel_e.file then pw = SPROP.fit_w(L, pw, h) end           -- только занятые колонки, остаток — волне
      -- свойства семпла слева от волны (4 окт, опция props position)
      local pleft = state.propspos == 'left'
      local px = pleft and x or (x + w - lw - (lw > 0 and L.pad or 0) - pw)
      if zone and zone.clip then pw = 0 end                            -- клип — во всю ширину (6 окт)
      if pw > L.cw * 12 then
        if sel_e.file then
          -- файл браузера: информация о файле (> — играет сейчас)
          local _, _, ppath = PV.position()
          SPROP.draw_info(L, px, y, pw, h, ctx.file_info(sel_e.path), ppath == sel_e.path)
        else
          SPROP.draw(L, px, y, pw, h, sel_e, state.focus == 'top')
          ctx.sprops_rect = { px, y, pw, h, t = reaper.time_precise() }   -- якорь меню нарезки (5 окт)
        end
      else pw = 0; SPROP.hover = nil end
      if pleft then
        local wx = x + (pw > 0 and (pw + 2 * L.pad) or 0)
        return SL.draw_in(U, L, wx, y, x + w - wx, h, e, col and col.track, zone)
      end
      return SL.draw_in(U, L, x, y, px - x - (pw > 0 and L.pad or 0), h, e, col and col.track, zone)
    end,
    browser_fxb = function() return B.mode == 'fx' and B.fx_hover or nil end,
    browser_draw = state.side and function(Lx, x, y, w, h)
      -- вкладка fx (браузер слева): список эффектов внутри браузера
      B.fx_draw = (state.browserleft or state.router_big) and function(fx, fy, fw, fh)
        if #FB.list == 0 and not FB.loaded then FB.loaded = true; FB.list = ctx.fx_list(); ctx.fxb_load_native() end
        return FB.draw(U, Lx, fx, fy, fw, fh, state.focus == 'fxb', ctx.fit)
      end or nil
      if not B.fx_draw and B.mode == 'fx' then B.mode = 'files' end
      return B.draw(U, Lx, x, y, w, h)
    end or nil,
    -- модуль слайсов (4 окт): список слайсов выбранного инструмента + скролл-бар
    slices_draw = state.slices_on and function(Lx, x, y, w, h)
      -- automation (5 окт): список пулов automation items трека с мини-линиями
      if state.auto_inst then
        local list = ctx.ai_list()
        local hv = SPROP.draw_ai(Lx, x, y, w - 5, h, list, ctx.ai_sel)
        local nvis = SPROP.slice_nvis or math.max(1, math.floor((h - Lx.rh) / Lx.rh))
        draw.vbar('slices', x + w - 4, y + Lx.rh, 3, nvis * Lx.rh * (SPROP.szoom or 1), SPROP.slice_scroll or 0, nvis, #list)
        return hv
      end
      local root, col = ctx.slice_root()
      if not root or root.file then                 -- пустой слот / файл: модуль на месте, подсказка
        U.text(x, y, 'slices', U.GREY)
        U.text(x, y + Lx.rh, ctx.fit('no sample in this slot - pick one above or drop a file', w - 5), U.DIM)
        return nil
      end
      local k = (ctx.ssel.item == root.item) and (ctx.ssel.k or 0) or 0
      local key_of = {}
      -- клавиша → слайс: C-4 (q) = 0 = весь сэмпл, дальше слайсы 1, 2 … (5 окт, как в Renoise)
      for code, off in pairs(keys.piano) do key_of[(vim.octave + 1) * 12 + off - (model.SLICE_BASE or model.BASE_NOTE or 60)] = keys.label(string.char(code)) end
      local rows = { { k = 0, t0 = 0, len = root.len or 0, has = true, name = root.name, key = key_of[0] } }   -- имя item вместо whole (5 окт)
      for kk, t0 in ipairs(root.slices or {}) do
        local child = ctx.slice_child(col, root, kk)
        rows[#rows + 1] = { k = kk, t0 = t0, len = (root.slices[kk + 1] or root.len or t0) - t0, key = key_of[kk], has = child ~= nil, fx = child and ctx.inst_has_fx(child), name = child and child.name ~= root.name and child.name or nil }
      end
      local hv = SPROP.draw_slices(Lx, x, y, w - 5, h, rows, k, root)
      local nvis = SPROP.slice_nvis or math.max(1, math.floor((h - Lx.rh) / Lx.rh))
      draw.vbar('slices', x + w - 4, y + Lx.rh, 3, nvis * Lx.rh * (SPROP.szoom or 1), SPROP.slice_scroll or 0, nvis, #rows)
      return hv
    end or nil,
  })
  -- большая справка F1 (6 окт): поверх всего окна
  if state.khelp_big and not idle_skip then
    HN.reset()
    hover = ctx.DOC.draw(L, 0, 0, gfx.w, gfx.h - L.status_h)
    U.set(U.AMBER); gfx.rect(0, 0, gfx.w, gfx.h - L.status_h, 0)
    hover.khelp_big = true
  end
  -- pm big (6 окт): карточки поверх всего; hover целиком — только карточки
  if state.pm_big and not idle_skip and ctx.PM then
    HN.reset()
    hover = ctx.PM.draw_big(L, B, 0, 0, gfx.w, gfx.h - L.status_h)
    hover.pmbig = true
  end
  -- session big (6 окт): клипы поверх всего
  if state.ss_big and not idle_skip and snap then
    HN.reset()
    hover = MX.SS.draw_big(L, 0, 0, gfx.w, gfx.h - L.status_h, seq, ctx.ss_V(), ctx.ss_G(), reaper.time_precise(), reaper.GetPlayPosition())
  end
  idle.hover = hover
  -- debug: нажатия мыши — что под ней (6 окт)
  if state.debug then
    local cap = gfx.mouse_cap
    local was = ctx.dbg_cap or 0
    if (cap & 3) ~= 0 and (was & 3) == 0 then
      local parts = {}
      for k, v in pairs(hover or {}) do
        local tv = type(v)
        if tv == 'number' or tv == 'string' or tv == 'boolean' then parts[#parts + 1] = k .. '=' .. tostring(v)
        elseif tv == 'table' then parts[#parts + 1] = k .. '={}' end
      end
      table.sort(parts)
      ctx.dlog(('mouse %s %d,%d cap %d focus %s | %s'):format(cap & 2 == 2 and 'R' or 'L', gfx.mouse_x, gfx.mouse_y, cap, state.focus, table.concat(parts, ' ')))
    end
    ctx.dbg_cap = cap
  end
  end

  if ev_drag and ev_drag.active then draw.ghost(('%d event(s) %+d'):format(#ev_drag.heads, ev_drag.drow or 0)) end
  SL.draw_drag(U, L)
  -- макро-вид (3 окт, :macro): поверх тела трекера; клики по скрытым ячейкам не идут
  -- clips в теле трекера (6 окт): шапки / входы / R I M S живые, вместо строк — сцены × треки
  -- строка effects (7 окт): под шапками — эффекты трека в одну строку и
  -- сенды (> трек, голубым); щелчок — DSP / окно маршрутизации, f — прыжки
  if state.fxrow and (L.fxrow_h or 0) > 0 and snap and L.cols then
    local y0 = L.fxrow_y
    U.set(U.PANEL); gfx.rect(L.matrix_w + 2, y0, L.win_w - L.matrix_w - 4, L.fxrow_h, 1)
    U.set(U.LINE); for _, c in ipairs(L.cols) do if c.x then gfx.rect(c.x, y0, 1, L.fxrow_h, 1) end end   -- 8 окт: разделители треков, как в теле
    U.text(L.matrix_w + L.pad, y0 + 1, ctx.fit('fx', L.label_w - 2 * L.pad), U.GREY)
    local mx, my = gfx.mouse_x, gfx.mouse_y
    local MAXL = state.fxparams and 14 or 6
    local need = 1
    -- 8 окт: широкий трек — эффекты в строку; не влезают все — столбиком,
    -- по эффекту на строку (имя по ширине колонки), высота — по самому длинному
    for _, c in ipairs(L.cols) do
      if c.x and c.col then need = math.max(need, ctx.fx_stack(hover, c.col, c.x + 2, c.x + c.w - 2, y0 + 1, draw.fxrow_lines or 1, false, MAXL)) end
    end
    if need ~= (draw.fxrow_lines or 1) then draw.fxrow_lines = need; relayout() end
  end
  -- session (7 окт) — 7 строк под шапками треков (шапки живые, тот же масштаб
  -- колонок), трекер виден ниже: строка подсказок и клипы. Tab — трекер ↔
  -- session; в фокусе session — клип-мод: клавиатура QWERTY запускает клипы
  if state.clipsview and (L.sess_h or 0) > 0 and snap and L.cols then
    local x0, y0, w0, h0 = L.matrix_w, L.sess_y, L.win_w - L.matrix_w, L.sess_h
    if not HN.active then
      local keep = {}
      for _, t in ipairs(HN.targets) do
        if not (t.y and t.y >= y0 and t.y < y0 + h0 and t.x and t.x >= x0) then keep[#keep + 1] = t end
      end
      HN.targets = keep
    end
    local foc = state.focus == 'session'
    MX.SS.clip_mode = foc
    -- заливка с отступом 2 px: рамка фокуса трекера (вокруг шапок, клипов и
    -- строк) идёт непрерывно — клипы её не прерывают (7 окт)
    U.set(U.BG); gfx.rect(x0 + 2, y0, w0 - 4, h0, 1)
    -- 7 окт: подсказки — обычным серым хинт-баром внизу модуля (клавиши жёлтым),
    -- как у остальных модулей; в фокусе — клип-мод
    local hb = L.rh + 1
    local hv = MX.SS.draw_body(L, x0, L.label_w, y0, h0 - hb, L.cols, seq, ctx.ss_V(), ctx.ss_G(), reaper.time_precise(), reaper.GetPlayPosition(), {})
    draw.hint_bar(setmetatable({ hint_h = hb }, { __index = L }), x0 + 2, y0 + h0 - hb, w0 - 4, KH.BARS[foc and 'clipmode' or 'session'], foc)
    if foc then U.set(U.AMBER); gfx.rect(x0 + 2, y0, w0 - 4, h0, 0) end   -- свой модуль в фокусе — своя рамка внутри
    local mx, my = gfx.mouse_x, gfx.mouse_y
    if mx >= x0 and mx < x0 + w0 and my >= y0 and my < y0 + h0 then
      for k2, v2 in pairs(hv) do hover[k2] = v2 end
      hover.row, hover.fi, hover.cell, hover.itemedge, hover.rownum = nil, nil, nil, nil, nil
    end
  else MX.SS.clip_mode = false end
  -- выбран клип (7 окт): трекер под клипами — на его слот, курсор — на трек и
  -- лейн клипа: видно, какие ноты в нём записаны (на смену выбора, не наведение)
  if state.clipsview and snap and L.flat then
    local cur = MX.SS.cur
    local key = cur.ri .. ':' .. cur.ci
    if key ~= ctx.ss_shown then
      ctx.ss_shown = key
      local rg, v = seq[cur.ri], ctx.ss_V().cols[cur.ci]
      if rg and v and not (state.follow and playing()) then
        for i, f in ipairs(L.flat) do
          if f.col == v.col and (not v.lane or (f.lane and f.lane.idx == v.lane)) then vim.cur.fi = i; break end
        end
        vim.cur.row = math.floor(rg.r0 + 1e-6)
        state.row0 = math.max(0, vim.cur.row)
      end
    end
  end
  -- полиметрия в строках (7 окт): зона сессии видна — в колонке каждого играющего
  -- клипа янтарная линия на начале его цикла (у 4/4 и 5/4 — свои швы)
  if model.SHOW_ZONE and not state.ss_big and L.body_h > 0 and snap and L.cols then
    local r0 = state.row0 or 0
    local t_top, t_bot = edit.row_time(r0, state.lpb, 0), edit.row_time(r0 + (L.nrows or 0), state.lpb, 0)
    for _, c in ipairs(L.cols) do
      local l = c.x and MX.SS.live[c.ci]
      if l and l.len and l.len > 0.01 then
        local k = math.ceil((t_top - l.phase) / l.len)
        local t = l.phase + k * l.len
        local guard = 0
        while t < t_bot and guard < 64 do
          local row = model.row_of_time(t, state.lpb)
          local y = L.body_y + math.floor((row - r0) * L.rh)
          if y >= L.body_y and y < L.body_y + L.body_h then
            U.set(U.AMBER); gfx.rect(c.x, y, c.w - 1, 1, 1)
            U.text(c.x + c.w - L.pad - U.measure('L'), y + 1, 'L', U.AMBER)
          end
          t = t + l.len; guard = guard + 1
        end
      end
    end
  end
  -- большой роутер (7 окт, zR): на всё окно поверх всего
  -- 7 окт: верхняя панель (вкладка автоматизации) и шапки треков остаются —
  -- роутер занимает матрицу, тело трекера, DSP, lib и браузер под шапками
  if state.router_big and not idle_skip then
    local root, _, title = ctx.db_tree()
    if root then
      -- 7 окт: слева — список эффектов (бросать в роутер / af), браузер файлов
      -- и сайдбар остаются (роутер — до L.win_w); при браузере слева — правее него
      local lx = L.browser_left and L.matrix_w or 0
      local y0 = L.body_y
      local h0 = gfx.h - L.status_h - y0
      local x0, w0 = lx, L.win_w - lx            -- эффекты — во вкладке fx браузера (7 окт), не отдельным списком
      if not L.browser_left then U.set(U.BG); gfx.rect(0, L.header_y, L.matrix_w, L.body_y - L.header_y, 1) end   -- колонка матрицы над телом
      if not HN.active then
        local keep = {}
        for _, t in ipairs(HN.targets) do
          local under = t.y and t.y >= y0 and t.x and t.x >= lx and t.x < L.win_w
          if not under then keep[#keep + 1] = t end
        end
        HN.targets = keep
      end
      local hv = MX.DB.draw(L, x0, y0, w0, h0, root, title, false, true)
      local mx, my = gfx.mouse_x, gfx.mouse_y
      if my >= y0 and my < y0 + h0 and mx >= x0 and mx < x0 + w0 then hover = hv; idle.hover = hover end
    end
  end
  if state.macro and L.body_h > 0 then
    draw.macro.draw(L, snap, L.matrix_w, L.body_y, L.win_w - L.matrix_w, L.body_h, L.label_w, vim.cur.row,
      beat_info.rows_bar or (state.lpb * 4), seq, ctx.fit)
    hover.row, hover.fi, hover.cell, hover.itemedge, hover.rownum = nil, nil, nil, nil, nil
  end
  -- метки f и призраки бросков — после всех оверлеев (session, эффекты,
  -- роутер), иначе их заливка закрашивала метки клипов и сцен (8 окт)
  HN.draw(U, L)
  B.draw_drag(U, L)
  if dsp_drag and dsp_drag.active then draw.ghost(dsp_drag.f.name) end
  if fxb_drag and fxb_drag.active then draw.ghost('+ ' .. FB.short(fxb_drag.it.label)) end
  -- всплывашка — у того, что редактируется (2 окт): имя трека, строка матрицы,
  -- инструменты; иначе — ячейка курсора трекера
  if vim.mode ~= 'cmd' and not vim.picker and not (vim.hydra and state.popup_at and (state.popup_at.kind == 'ctrlbtn' or state.popup_at.kind == 'xy' or state.popup_at.kind == 'sprops' or state.popup_at.kind == 'strip')) then state.popup_at = nil end
  local anchor
  do
    local pa = state.popup_at
    if pa and pa.kind == 'track' then
      for _, c in ipairs(L.cols or {}) do if c.col.guid == pa.guid and c.x then anchor = { x = c.x, y = L.header_y + L.rh } end end
    elseif pa and pa.kind == 'in' then
      local r = draw.in_at and draw.in_at[pa.guid]
      if r then anchor = { x = r[1], y = r[2], right = r[3] } end
    elseif pa and pa.kind == 'box' then
      anchor = { box = { pa.x, pa.y, pa.w, pa.h } }
    elseif pa and pa.kind == 'xy' then
      anchor = { x = pa.x, y = pa.y }
    elseif pa and pa.kind == 'strip' then
      -- ячейка полосы транспорта: всплывашка сразу над ней (5 окт)
      local r = draw.strip_cell and draw.strip_cell[pa.id]
      if r then anchor = { x = r[1], y = r[2], above = true } end
    elseif pa and pa.kind == 'trim' then
      local r = draw.trim_at and draw.trim_at[pa.guid]
      if r then anchor = { x = r[1], y = r[2], right = r[3] } end
    elseif pa and pa.kind == 'mxrow' then
      local y = MX.row_y and MX.row_y[pa.ri]
      if y then anchor = { x = 2, y = y + L.rh } end
    elseif pa and pa.kind == 'ctrlbtn' then
      -- меню у своей кнопки главного модуля (скринсеты, 4 окт)
      local r = draw.ctrl_rect and draw.ctrl_rect[pa.name]
      if r then anchor = { x = r[1], y = r[2] + r[4] + 1 } end
    elseif pa and pa.kind == 'sprops' then
      -- меню нарезки (5 окт): поверх панели свойств сэмпла (volume / pan / transpose)
      local r = ctx.sprops_rect
      if r and reaper.time_precise() - (r.t or 0) < 0.5 then anchor = { x = r[1], y = r[2] } end
    elseif pa and pa.kind == 'inst' then
      anchor = { x = L.side_x or L.win_w, y = (L.side_y0 or 0) + 2 * L.rh }
    end
    if not anchor and (state.focus == 'tracker') then
      local f = L.flat[vim.cur.fi]
      local r = vim.cur.row - (rows[1] and rows[1].row or 0)
      if f and f.x and r >= 0 and r < L.nrows then anchor = { x = f.x, y = L.body_y + (r + 1) * L.rh } end
    end
  end
  -- which-key (7 окт, быстрая опция whichkey): ждём вторую клавишу — у курсора
  -- (там, куда уже смотрят глаза) список того, что можно нажать дальше
  local pop = vim.popup()
  if not pop and state.whichkey then
    local wk = (state.focus == 'tracker' and vim.mode ~= 'insert' and MX.WK.get(vim.pending, vim.op))
      or (state.focus == 'dsp' and state.dsp_z and MX.WK.get('dsp_z')) or (state.focus == 'dsp' and DK.pending and MX.WK.get('dsp_' .. DK.pending)) or nil
    if wk then
      local lines = {}
      for _, e in ipairs(wk.items) do lines[#lines + 1] = { key = e[1], text = e[2] } end
      pop = { title = wk.title, lines = lines, kind = 'hydra' }
      if state.focus == 'dsp' and not anchor then anchor = { x = L.matrix_w + 4 * L.pad, y = (L.dsp_y or 0) + L.rh + 4 } end
    end
  end
  -- 7 окт: якоря нет (гидра из вкладки item и т.п.) — у модуля в фокусе:
  -- у мыши, если она в нём, иначе у его левого верхнего угла (раньше — угол
  -- окна по умолчанию, поверх браузера файлов)
  if pop and not anchor then
    local r = draw.module_rects and draw.module_rects[state.focus]
    if r then
      local mx, my = gfx.mouse_x, gfx.mouse_y
      if not ctx.pop_xy or ctx.pop_seen ~= (vim.hydra or vim.picker or pop.title) then
        ctx.pop_seen = vim.hydra or vim.picker or pop.title
        local inside = mx >= r[1] and mx < r[1] + r[3] and my >= r[2] and my < r[2] + r[4]
        ctx.pop_xy = inside and { x = mx, y = my + 4 } or { x = r[1] + 2 * L.pad, y = r[2] + 2 * L.rh }
      end
      anchor = { x = ctx.pop_xy.x, y = ctx.pop_xy.y }
    end
  elseif not pop then ctx.pop_seen, ctx.pop_xy = nil, nil end
  draw.popup(L, pop, anchor)
  -- линейка measure (7 окт): перекрестье у мыши, рамка от начала до мыши / конца, размер
  if state.measure then
    local mx, my = gfx.mouse_x, gfx.mouse_y
    U.set(U.CYAN, 0.35); gfx.rect(0, my, gfx.w, 1, 1); gfx.rect(mx, 0, 1, gfx.h, 1)
    local M = ctx.meas
    if M and M.a then
      local bx, by = M.b and M.b[1] or mx, M.b and M.b[2] or my
      local x0, y0 = math.min(M.a[1], bx), math.min(M.a[2], by)
      local w, h = math.abs(bx - M.a[1]), math.abs(by - M.a[2])
      U.set(U.AMBER, 0.12); gfx.rect(x0, y0, w + 1, h + 1, 1)
      U.set(U.AMBER); gfx.rect(x0, y0, w + 1, h + 1, 0)
      local lab = ('%dx%d px  %.1f x %.1f'):format(w, h, w / L.cw, h / L.rh)
      local lw = U.measure(lab) + 2 * L.pad
      local lx, ly = math.min(gfx.w - lw - 2, bx + 6), math.max(0, by - L.rh - 4)
      U.set(U.BG); gfx.rect(lx, ly, lw, L.rh + 2, 1)
      U.text(lx + L.pad, ly + 1, lab, U.AMBER)
    end
  end
  -- тур tutorial (4 окт): проверка действия шага и всплывашка на его модуле
  if OPT.tour.active then
    -- шаг сам ставит фокус на модуль, где он работает (5 окт)
    if OPT.tour.want_focus then ctx.set_focus(OPT.tour.want_focus); OPT.tour.want_focus = nil end
    OPT.tour.tick({ hj = state.hjumps or 0, fi = vim.cur.fi, row = vim.cur.row, mode = vim.mode, inst = vim.inst, toptab = state.top and state.toptab or nil,
      hydra = vim.hydra ~= nil, playing = reaper.GetPlayState() & 1 == 1, khelp = state.khelp, khelp_big = state.khelp_big, change = reaper.GetProjectStateChangeCount(0) }, reaper.time_precise())
    OPT.tour.draw_bubble(U, L, draw.module_rects or {}, L.win_w, gfx.h, ctx.fit)
  end
  if OPT.active then OPT.draw(L, gfx.w, gfx.h) end
  if OPT.ask.active then OPT.ask.draw(L, gfx.w, gfx.h) end
  if ctx.LOGOPOP then ctx.logo_draw() end
  if bpm_menu then
    local r = draw.ctrl_rect and draw.ctrl_rect.bpm
    if r then
      local w = L.cw * 24 + 2 * L.pad
      local x, y = r[1], r[2] + L.rh + 1
      local nv = math.max(3, math.min(#BPM_LIST, math.floor((gfx.h - y - L.status_h - 4) / L.rh)))
      bpm_menu.scroll = bpm_menu.scroll or 0
      if bpm_menu.sel - 1 < bpm_menu.scroll then bpm_menu.scroll = bpm_menu.sel - 1 end
      if bpm_menu.sel > bpm_menu.scroll + nv then bpm_menu.scroll = bpm_menu.sel - nv end
      U.set(U.BG); gfx.rect(x, y, w, nv * L.rh + 4, 1)
      U.set(U.TEXT); gfx.rect(x, y, w, nv * L.rh + 4, 0)
      bpm_menu.hover = nil
      local cur = reaper.Master_GetTempo()
      for k = 1, nv do
        local i = bpm_menu.scroll + k
        local it = BPM_LIST[i]; if not it then break end
        local yy = y + 2 + (k - 1) * L.rh
        local hot = gfx.mouse_x >= x and gfx.mouse_x < x + w and gfx.mouse_y >= yy and gfx.mouse_y < yy + L.rh
        if hot then bpm_menu.hover = i end
        if hot or i == bpm_menu.sel then U.set(U.tint(U.AMBER, 0.3)); gfx.rect(x + 1, yy, w - 2, L.rh, 1) end
        local is_cur = type(it[2]) == 'number' and math.abs(it[2] - cur) < 0.01
        U.text(x + L.pad, yy, it[1], it[2] == 'item' and U.CYAN or (is_cur and U.AMBER or U.TEXT))
      end
    end
  end

  -- наведение
  local cell = hover.cell
  if cell and (cell.kind == 'cont' or cell.kind == 'off') then cell = cell.of end
  if cell and cell.kind == 'audio' then
    state.status = string.format('%s  %s vol %s  offs %.3fs  len %.3fs  rate %.3f  %s',
      cell.name, cell.note, cell.vol, cell.offs, cell.len, cell.rate, table.concat(cell.fx or {}, ' '))
  elseif cell and cell.kind == 'midi' then
    state.status = string.format('MIDI %s vel %s ch %d%s', cell.note, cell.vol, cell.ch + 1, cell.muted and '  muted' or '')
  elseif hover.header_env then state.status = (hover.header_env.e.name or 'envelope') .. ' - click: menu (delete whole curve / clear points)'
  elseif hover.env then state.status = ('%s %s  %.0f%%  -  click: cursor here; INSERT: click / drag writes a point; rclick: delete point'):format(hover.col and hover.col.name or '', hover.env.name, (hover.envv and hover.envv.v or 0) * 100)
  elseif hover.dspab then state.status = hover.dspab.f.name .. ': A / B morph - drag between the two snapshots (:fxa, :fxb store them, :morph N)'
  elseif hover.dspmeter then
    local db = draw.meter_db and draw.meter_db[hover.dspmeter] or -150
    local dt = db <= -60 and '-inf' or ('%.1f dB'):format(db)
    state.status = (hover.dspmeter == 'out' and 'o - out: the track after all fx and the fader' or 'i / p - the record input when the track is armed (i), else the items before the fx (p)') .. '   ' .. dt
  elseif hover.dspcomp then state.status = 'c - gain comp' .. ((function() local tr = hover.dspcomp.track; local d = tr and reaper.ValidatePtr(tr, 'MediaTrack*') and edit.comp_db(tr); return d and ('%+.1f dB'):format(d) or '' end)()) .. ': click - the end of the chain follows the level before the fx (JS Volume Adjustment "gain comp" last in the chain); right click - remove'
  elseif hover.dspbtn and hover.dspbtn.kid then state.status = hover.dspbtn.kid.name .. ' in ' .. hover.dspbtn.f.name .. (hover.dspbtn.what == 'kdel' and ' - remove this plugin from the container' or ' - bypass on / off')
  elseif hover.dspbtn then state.status = hover.dspbtn.f.name .. ' - ' .. ({ open = 'open the fx window (o)', bypass = 'bypass on / off (b)', delta = 'delta solo: hear only the difference this fx makes (REAPER :delta)', preset = 'presets: click - the list (fzf), < > - previous / next', pprev = 'previous preset', pnext = 'next preset', del = 'delete this fx (dd, Cmd+Z undo)' })[hover.dspbtn.what]
  elseif hover.dsptarget then state.status = hover.dsptarget == 'take' and 'DSP shows the take fx of the selected instrument (t; take fx row in sample props)' or 'DSP shows the fx of the cursor track (t)'
  elseif hover.dspview then state.status = hover.dspview.f.name .. ': grain cloud - click / drag sets Position (native parameter)'
  elseif hover.dspxy then state.status = hover.dspxy.f.name .. ': XY pad - drag to move the vector (X and Y together)'
  elseif hover.dspwave then state.status = (hover.dspwave.f.file and ((hover.dspwave.f.file:match('[^/]+$') or '') .. ' - drag: nearest handle (start / end) - drop a browser file: new sample') or 'RS5K: drop a sample file from the browser here')
  elseif hover.dsp then state.status = hover.dsp.f.name .. (hover.dsp.param and ('  ' .. hover.dsp.f.params[hover.dsp.param].name .. ' - drag: value, dblclick: default, rclick: modulate (LFO / ACS / link)') or '  (dblclick: window, rclick: menu)') .. (hover.dsp.f.container and '  [container: | serial = parallel + sum]' or '')
  elseif hover.mod then state.status = hover.mod.m.fxname .. ' / ' .. hover.mod.m.pname .. ': toggle ' .. hover.mod.what
  elseif hover.garden and hover.garden.ri then
    local rg = seq[hover.garden.ri]; local col = snap.cols[hover.garden.ci]
    state.status = ('garden: %s x %s - digits+Enter / > loop N steps, < region to item end, +/- or wheel: period, m mute, Enter/Space queue, o Orca field'):format(rg and (rg.gap and 'bar' or rg.name) or '?', col and col.name or '?')
  elseif hover.garden and hover.garden.ox then
    local ch = garden.f and garden.f.cells[hover.garden.oy][hover.garden.ox] or '.'
    state.status = ('orca (%d,%d) %s'):format(hover.garden.ox, hover.garden.oy, ORCA.DOC[ch] or ORCA.DOC[ch:upper()] or 'click to place the cursor, type to write')
  elseif hover.midimap then
    local t = MM.TARGETS[hover.midimap.row]
    state.status = t and (t.label .. ': ' .. t.d .. (hover.midimap.btn == 'mode' and ' - click: abs / rel / rel64' or ' - click: select, click again / Enter: learn, d: clear')) or ''
  elseif hover.mm and hover.mm.strip then state.status = ({ shape = 'LFO shape (turns L1 on)', toggle = 'group on / off: L1 = LFO, ENV = audio follower, LNK = link', slider = 'drag: value (one undo on release)' })[hover.mm.strip]
  elseif hover.mm then
    local c = MMX.COLS[hover.mm.col]
    local hints = { name = 'parameter - dblclick: default value, o: FX window, w: native modulation window', num = 'value - wheel / + - (Shift ×10)', toggle = 'on/off - click twice / Enter', enum = 'LFO shape - Enter / wheel', link = 'link source - Enter: pick parameter (fzf)' }
    state.status = (c and c.head or '') .. ': ' .. (c and hints[c.kind] or '') .. '   a: add parameter, x: remove'
  elseif hover.scopemode then state.status = ({ scope = 'oscilloscope (ring 256 samples, 8 kHz)', spec = 'spectrum analyzer: 48 log bands 30 Hz..Nyquist, -60..0 dB', sgram = 'spectrogram: time → right, 48 bands, heat = level' })[hover.scopemode] .. ' (:scopemode)'
  elseif hover.monobtn then state.status = hover.monobtn == 'take' and 'monome: give the surface to the tracker module (gmem jf_mono[2] = 9)' or 'monome: return the surface to the GRID mixer mod'
  elseif hover.retrobtn then state.status = ({ prev = 'previous track with jf_rec', next = 'next track with jf_rec', all = 'select whole buffer (a)', play = 'preview selection (Space)', stop = 'stop preview (s)', put = 'put selection on this track at the cursor row (p)', loop = 'looper: while playing, loop the last N bars just played from the next bar (L); stopped: click sets N = 1 / 2 / 4 / 8', depot = 'put selection into the track lib after =LIB - then slice it in the item tab (d)', lib = 'put selection into the track lib after =LIB - then slice it in the item tab (d)', add = 'add jf_rec (40 s ring buffer) to the cursor track' })[hover.retrobtn] or hover.retrobtn
  elseif hover.retro then state.status = ('retro buffer: drag to select, click: set start · %.0f%% of ring'):format(hover.retro * 100)
  elseif hover.recbtn then state.status = 'rec: record into an item - the jf_rec ring of the track (retro): select what was played, put / loop / to library; click again: back to item editing'
  elseif hover.tab then state.status = ({ clips = 'clips: the session - scenes x tracks, Enter launches a clip into the =SESSION loop zone (zz - over the whole window)', scope = 'oscilloscopes / spectrum of all tracks', sample = 'item: the selected instrument item - slices, selection, properties, drag to track', modulation = 'modulate: native parameter modulation of the cursor track + curve generator (lfo / podkat / follow) - L switches', midi = 'MIDI learn: knobs and pads of a controller drive the slicer', retro = 'retro sampler: 40 s ring buffers (jf_rec), put / to lib', master = 'master track: meters and fx chain' })[hover.tab] or ('tab: ' .. hover.tab)
  elseif hover.viewbtn == 'fxparams' then state.status = 'param: the parameters you show in the REAPER track controls (TCP) - under their fx in the effects row, thin sliders (drag, wheel, dblclick: default); click on the fx name - its window'
  elseif hover.hdrparam then state.status = (hover.hdrparam.name or 'parameter') .. ': drag / wheel - value, dblclick - default'
  elseif hover.viewbtn == 'effects' then state.status = 'effects: one row per track under the headers - its fx (click: DSP, dblclick: window) and sends (> track, click: routing); f jumps to any of them'
  elseif hover.viewbtn == 'session' then state.status = 'session: clips instead of the rows - scenes x tracks, Enter launches (zs, quick option clips)'
  elseif hover.viewbtn then state.status = hover.viewbtn == 'reg' and 'region: view only the region of the cursor (the playhead one with follow) - :reg' or 'proj: view the whole project - :reg'
  elseif hover.rgbtn then state.status = ({ half = 'region length / 2 (later regions and items move back)', double = 'region length x 2 (later regions and items move on)', alias = 'alias: the pattern repeated to the right, linked - same name, MIDI pooled, items grouped, edits in one change all (A in the matrix; U makes it unique)', clone = 'clone: an exact copy to the right with a new name, not linked (C / D in the matrix)' })[hover.rgbtn]
  elseif hover.rglen then state.status = 'cursor region length in steps - < > or wheel: +-1 step; later regions and items ripple (:len N)'
  elseif hover.sess then state.status = ('clip: %s / %s - click: cursor, dblclick / Enter: launch at %s, rclick: menu, drop a file or a pm card here'):format(ctx.ss_colname(hover.sess.ci), MX.SS.slot_name(seq[hover.sess.ri], hover.sess.ri), MX.SS.quant)
  elseif hover.sessrow then state.status = 'scene: click / Enter / O - launch every clip of the row (empty cells stop their tracks)'
  elseif hover.sesscol then state.status = 'track: click - stop its clip at the next boundary'
  elseif hover.sessbtn then state.status = ({ quant = 'quantize: bar / beat / now - when a launched clip starts', stopall = 'stop every clip at the next boundary (X)', quit = 'session off: stop the transport, clear the =SESSION zone, repeat off (Q)', back = 'back to the matrix (zz / Esc); clips keep playing' })[hover.sessbtn] or ''
  elseif hover.matrix and hover.matrix.name then state.status = 'region name - click: select slot, dblclick: rename (:name text, n)'
  elseif hover.matrix and hover.matrix.dur then state.status = 'region length in steps - click: change (:len N, =); later regions and items ripple'
  elseif hover.matrix and hover.matrix.sig then state.status = 'time signature at the region start - click: change for this pattern (:sig N/D here)'
  elseif hover.matrix and hover.matrix.btn == 'loops' then state.status = 'loops layer: cells show item loop periods; digits+Enter loop, > region end, < fit, + - period; :loops'
  elseif hover.matrix and (hover.matrix.btn == 'mkstart' or hover.matrix.btn == 'mkend') then state.status = 'sequence ' .. (hover.matrix.btn == 'mkstart' and '=START' or '=END') .. ' marker: click - type bar[.beat] + Enter, Shift+click - cursor row, wheel - one bar; :start / :end'
  elseif hover.matrix and hover.matrix.btn == 'clips' then state.status = 'clips: the matrix as a session - scenes x tracks, Enter launches a clip into the =SESSION loop; zz - over the whole window'
  elseif hover.matrix and hover.matrix.btn == 'fold' then state.status = 'fold the matrix: slot numbers, track names and cells only (F)'
  elseif hover.matrix and hover.matrix.btn == 'add' then state.status = 'new region after the last one, from the next bar (+, N+ for N regions, :add [bars] [name]); n names it'
  elseif hover.prevbtn then state.status = 'preview: play the item when selected - ' .. (state.poolprev and 'on' or 'off') .. ', mode ' .. (state.prevmode or 'full') .. ' - click: on / off, rclick: mode (full / hold / first second); Esc stops'
  elseif hover.poolfind then state.status = 'find in the lib (fzf) - also / when the lib has focus'
  elseif hover.sendpop then state.status = ({ add = '+ send: pick a track (fzf)', routing = 'REAPER routing window', mute = 'mute this send', del = 'remove this send' })[hover.sendpop.what] or ''
  elseif hover.sendvol then state.status = 'send volume - drag'
  elseif hover.hdrin then state.status = hover.hdrin.what == 'smart' and 'smart input: pick the input from the track (jf_smart_set_input)' or 'track input - click: list (fzf), click again closes'
  elseif hover.mixpk then state.status = 'peak hold of REAPER (as in its mixer; red == - clipped) - click: reset'
  elseif hover.trkio then state.status = ({ sends = 'sends of this track - click: open / close the send panel (+ send by fzf, volume, mute, remove)', input = 'track input - click: list (fzf)', smart = 'smart input: pick the most active input (jf_smart_set_input)', mainsend = 'send to master on / off', routing = 'open the REAPER routing window of this track (sends, receives, hardware outputs)', phase = 'phase invert', fxen = 'track FX on / off (bypass the whole chain)' })[hover.trkio.what] or hover.trkio.what
  elseif hover.poolbsync then state.status = 'beatsync of the selected item: its length = N beats at the tempo where each note sits (tempo changes followed); click: on / off, wheel: N'
  elseif hover.poolsave then state.status = 'save the lib as a kit: a REAPER track template (TrackTemplates/jf_kits) - load it in the browser tab kits or with Insert track from template'
  elseif hover.swapbtn then
    local st, file = ctx.swap_info()
    state.status = st == 'on' and ('swap: the sample plays ' .. (file or '?') .. ' - click: back to the original file')
      or (file and ('swap: play the selected sample with ' .. file .. ' in all its notes (slices too) - click again later to go back') or 'swap: select an audio file in the browser first, then click')
  elseif hover.insprevbtn then state.status = 'insert: play the sample when a note is inserted - ' .. (state.preview and 'on' or 'off') .. ' (Shift+note always just plays)'
  elseif hover.poolsortcol then state.status = 'sort the lib by this column - #: tree by track / marks (click again), name, len; numbers stay'
  elseif hover.poolsort then state.status = 'instrument order: track (groups by first track, then length) / len / mark (@ $ *) - click to cycle; numbers stay'
  elseif hover.caption then state.status = ({
    wave = 'wv: spectral peaks of the item (colour = frequency), amber ticks = stretch markers - :wave on|off',
    note = 'nt: note - audio: pitch from C-4 (D_PITCH / playrate), MIDI: note; ` = note-off',
    vol = 'vl: volume / velocity, hex 00..FF (80 = unity)',
    delay = 'dl: delay inside the row, hex xx/256 of a row',
    fx = 'fx: effect command, letter + hex hex (slices are notes: C-4 = slice 1; Sxx offset, Txx beatsync rows, 8xx pan, Ixx Oxx fades, Pxx pitch; 9xx offset also accepted)',
    env = 'env: envelope value at the row (bar + hex); INSERT edits points, :ramp / :fade',
  })[hover.caption] or hover.caption
  elseif hover.ctrl == 'metro' then state.status = 'metronome on / off (REAPER: Options > Metronome)'
  elseif hover.ctrl == 'swing' then state.status = ctx.swing_text() .. ' - click: menu, wheel: +-1 %'
  elseif hover.ctrl == 'tp_rew' then state.status = 'rewind a little'
  elseif hover.ctrl == 'tp_fwd' then state.status = 'fast forward a little'
  elseif hover.ctrl == 'tp_play' then state.status = 'play / stop (Space)'
  elseif hover.ctrl == 'tp_pause' then state.status = 'pause'
  elseif hover.ctrl == 'rec' then state.status = 'record into the cursor track from the cursor row (Option+R); while recording - stop and keep (Space)'
  elseif hover.ctrl == 'punch' then state.status = 'auto punch: record only inside the time selection (shown red left of the tracks)'
  elseif hover.ctrl == 'preroll' then state.status = 'pre-roll before recording (REAPER: metronome pre-roll settings)'
  elseif hover.ctrl == 'reclib' then state.status = 'rec -> lib: a take recorded into the tracker also becomes a new instrument in the lib'
  elseif hover.ctrl == 'sig' then state.status = ('time signature at the cursor %d/%d - %d rows per bar, %d per beat (LPB)'):format(beat_info.num, beat_info.den, beat_info.rows_bar, state.lpb)
  elseif hover.ctrl == 'beats' then state.status = ('bar %d, beat %d of %d - squares: beats of the bar (amber edge = downbeat), lit = current; %d rows/beat, %d rows/bar'):format(beat_info.bar, math.floor(beat_info.beat) + 1, beat_info.num, state.lpb, beat_info.rows_bar)
  elseif hover.ctrl == 'xfade' then state.status = 'x-fade of inserted notes: click on/off, wheel: length (ms); off = overlaps without crossfade; \\x: menu'
  elseif hover.ctrl == 'fixed' then state.status = 'fixed cursor: the cursor row stays in the middle of the screen, the pattern scrolls under it (Impulse Tracker)'
  elseif hover.ctrl == 'lock' then state.status = 'lock: tracker cursor mirrors REAPER edit cursor and selected track (both ways); follow = view follows playhead'
  elseif hover.ctrl == 'bpm' then state.status = 'BPM - click: tempo list (take from selected item on top), dblclick: type the number, wheel: +-1'
  elseif hover.fxb then state.status = 'fx list - type to search, Enter / dblclick: add to the cursor track, drag onto the DSP panel: insert at the amber line'
  elseif type(hover.khelp) == 'table' then state.status = hover.khelp.e.k .. '  -  ' .. hover.khelp.e.d .. (hover.khelp.tag and ('   [' .. hover.khelp.tag .. ']') or '')
  elseif hover.ctrl == 'notes' then state.status = 'notes: project notes / notes of the item under the cursor - the editor opens in the main module'
  elseif type(hover.notes) == 'string' then state.status = hover.notes == 'text' and 'notes - type (markdown: # heading, - [ ] todo, - list, > quote, `code`, **bold**); Esc / Tab: leave (saved)' or (hover.notes == 'drag' and 'notes: drag the header to move the window' or hover.notes == 'resize' and 'notes: drag the corner to resize' or hover.notes:match('^zoom') and 'notes text size' or hover.notes:match('^todo:') and 'todo - click: done / open' or ('show ' .. hover.notes .. ' notes'))
  elseif hover.ctrl == 'hints' then state.status = 'module hints: one line of the main keys under every module; ? opens the full help'
  elseif hover.ctrl == 'help' then state.status = 'help panel: keys of the focused module at the bottom (?); pressed keys light up; Tab into it to search'
  elseif hover.ctrl == 'options' then state.status = 'all tracker options in one window (:options, \\o)'
  elseif hover.ctrl == 'about' then state.status = 'about: version and changes (:about)'
  elseif hover.ctrl == 'caps' then state.status = 'column captions: a row under the track header naming the fields - wv nt vl fx dl'
  elseif hover.ctrl == 'hdr' then state.status = 'track header colour - click / wheel: off (no colour), line (strip under the name), header (name row filled), full (whole header, dimmer below the name)'
  elseif hover.ctrl == 'vel' then state.status = 'velocity of inserted notes: wheel +-4, click +8 (c / C in INSERT, :vel N)'
  elseif hover.ctrl == 'step' then state.status = 'edit step: wheel = rows, click = auto (cursor jumps past the end of the inserted item / slice) - :step N|auto'
  elseif hover.ruler then
    local names = {}
    for _, rg in ipairs(regions or {}) do if hover.ruler >= rg.r0 and hover.ruler < rg.r1 then names[#names + 1] = 'region ' .. (rg.name ~= '' and rg.name or ('#' .. rg.idx)) end end
    for _, mk in ipairs((regions and regions.markers) or {}) do if math.floor(mk.row_f + 1e-6) == hover.ruler then names[#names + 1] = 'marker ' .. mk.name end end
    state.status = ('ruler row %d: %s - click: go to the row'):format(hover.ruler, #names > 0 and table.concat(names, ', ') or 'no region / marker')
  elseif hover.sidectl then
    state.status = ({ open = 'open the sidebar (lib + browser)', close = 'fold the sidebar to a strip', grip = 'drag the line: sidebar width, dblclick: auto; fold - quick toggle browser', instgrip = 'drag: lib / browser height, dblclick: auto' })[hover.sidectl]
  elseif hover.mxctl then
    state.status = ({ open = 'open the matrix', close = 'fold the matrix to a strip', grip = 'drag the line: matrix width, dblclick: auto; fold - quick toggle matrix' })[hover.mxctl]
  elseif ctx.aied_hover and ctx.aied_hover.status and mod_pane == 'ai' and state.toptab == 'modulation' then
    state.status = ctx.aied_hover.status
  elseif hover.slices ~= nil then
    state.status = 'slices of the instrument: click - select and play, Option+J / K - step; the properties on the left edit the selected slice'
  elseif SPROP.hover and SPROP.hover.fit then state.status = 'v: open the top panel so that all the sample properties fit'
  elseif SPROP.hover and not SPROP.hover.title and state.top and state.toptab == 'sample' then
    state.status = ('sample %s - wheel / H L: change, click: toggle / open, dblclick or R: reset, J K: row (Sample tab focused)'):format(SPROP.ROWS[SPROP.hover.row].label)
  elseif hover.hsb then
    state.status = 'tracks: drag the bar, click beside it - a page; trackpad sideways / Shift+wheel scroll, Cmd+sideways - width zoom, Cmd+wheel - LPB zoom'
  elseif hover.trsbtn then
    state.status = hover.trsbtn.col.name .. ' ' .. hover.trsbtn.what .. ' - narrow track: click opens the slider, click again closes'
  elseif hover.trs then
    local names = { vol = 'volume', pan = 'pan', width = 'width (stereo pan)', panl = 'left pan (dual pan)', panr = 'right pan (dual pan)' }
    -- значение — здесь (5 окт): в строке из двух слайдеров чисел нет
    local w = hover.trs.what
    local v = reaper.ValidatePtr(hover.trs.col.track, 'MediaTrack*') and reaper.GetMediaTrackInfo_Value(hover.trs.col.track, TRS_KEY[w] or 'D_VOL') or 0
    local vs = w == 'vol' and (v > 1e-6 and ('%+.1f dB'):format(20 * math.log(v, 10)) or '-inf') or (w == 'width' and ('%d%%'):format(math.floor(v * 100 + 0.5))
      or (math.abs(v) < 0.005 and 'C' or ('%s%d'):format(v < 0 and 'L' or 'R', math.floor(math.abs(v) * 100 + 0.5))))
    state.status = ('%s %s %s - drag, wheel: fine, dblclick: reset; pan mode = REAPER track pan mode'):format(hover.trs.col.name, names[hover.trs.what] or hover.trs.what, vs)
  elseif hover.fxcolbtn then state.status = ('fx columns per subcolumn: %d - click -/+ (0..4)'):format(state.fxcols)
  elseif hover.envpm then state.status = hover.envpm.d > 0 and 'add an automation lane: pick a parameter of the track or its fx'
    or ((hover.envpm.e and hover.envpm.e.name or 'envelope') .. ': hide this lane (the envelope and its points stay; + shows it again)')
  elseif hover.lanebtn then state.status = ('lane columns: %d - click -/+ (min columns; more appear when items overlap)'):format(hover.lanebtn.n or 1)
  elseif hover.ctrl == 'wave' then state.status = 'wave column left of the note: spectral peaks (colour = frequency) + stretch markers (amber) - click: on/off, :wave'
  elseif hover.ctrl and hover.ctrl:match('^q_') then state.status = ({ q_dsp = 'DSP panel on / off (the fx chain of the cursor track)', q_side = 'browser sidebar on / off', q_mx = 'matrix (pattern sequencer) shown / folded', q_envs = 'envelope columns on / off (all tracks)', q_scopes = 'track scopes on / off', q_hints = 'module hints row on / off', q_wave = 'item waves on / off (back to the last wave mode)', q_meters = 'track meters on / off', q_ruler = 'timeline ruler (beats) on / off', q_names = 'item names in the cells on / off', q_colors = 'item colours on / off', q_input = 'input row in the track header on / off', q_preview = 'preview while inserting on / off', q_endstop = 'stop at =END on / off', q_captions = 'column captions on / off', q_keys = 'keycaster: the last keys pressed, in the empty right part of the tracker (right click - default size)', q_kcm = 'keycaster text smaller', q_sidel = 'browser on the left, under the matrix', q_mixup = 'mixer above the tracker, in the headers', q_mixdn = 'mixer under the tracker', q_sider = 'browser on the right, under the instruments', q_listen = 'step listen: with the transport stopped, the row under the moving cursor plays (all tracks)', q_kcp = 'keycaster text bigger' })[hover.ctrl]
  elseif hover.ctrl then state.status = 'click / wheel: ' .. hover.ctrl
  elseif hover.btn and hover.btn.what == 'auto' then
    local names = {}
    for _, e in ipairs(hover.btn.col.envs or {}) do names[#names + 1] = e.name end
    state.status = hover.btn.col.name .. ': ' .. (#names > 0 and (#names .. ' envelopes: ' .. table.concat(names, ', ')) or 'no automation') .. ' - click: find a parameter (fzf), rclick: all parameters (modulation tab), Shift+click: envelopes in the tracker'
  elseif hover.btn and hover.btn.what == 'monitor' then
    local m = hover.btn.col.recmon or 0
    state.status = hover.btn.col.name .. ': input monitoring ' .. ({ [0] = 'off', [1] = 'on', [2] = 'auto (tape)' })[m] .. ' - click: off → on → auto'
  elseif hover.btn then state.status = hover.btn.col.name .. ': ' .. hover.btn.what
  elseif hover.pool and hover.pool.auto then
    state.status = 'automation: automation items of the track as one instrument - the slices list shows them; a note key inserts the selected one, its rate by the key (C-4 = x1, an octave up = x2)'
  elseif hover.pool then
    local col = hover.pool.ci and snap.cols[hover.pool.ci] or cur_col(); local e = col and col.pool[hover.pool.i]
    state.status = e and (('inst %02d: %s%s%s - click: select (Option+click: focus), dblclick: open in the item tab, drag: reorder'):format(hover.pool.i, e.name, e.depot and ' (library)' or '', (e.tracks and #e.tracks > 0) and ('  @ ' .. table.concat(e.tracks, ', ')) or '  (not used yet)')) or ''
  elseif hover.matrix and hover.matrix.btn then
    state.status = ({ zoom = 'matrix zoom: schema / detail = tall rows, item colours, envelopes (z)', fill = 'fill matrix cells (f)', sync = 'sync pattern aliases with regions (:sync)', trim = 'cut items to region bounds - strict patterns (t, :trim; auto with :autosync)' })[hover.matrix.btn] or hover.matrix.btn
  elseif hover.matrix and hover.matrix.ri then
    local slot = seq[hover.matrix.ri]
    local pname = slot and (slot.name ~= '' and slot.name or ('#' .. slot.idx)) or ''
    if hover.matrix.prev or hover.matrix.next then
      state.status = ('slot %d: %s - click: previous / next pattern from library'):format(hover.matrix.ri, pname)
    elseif hover.matrix.ci then
      local c = snap.cols[hover.matrix.ci]
      state.status = ('slot %d %s : %s - click: cursor, dblclick / Space: queue, rclick: menu'):format(hover.matrix.ri, pname, c and c.name or '')
    else
      state.status = ('slot %d: %s - click: cursor to pattern, Space: queue'):format(hover.matrix.ri, pname)
    end
  elseif hover.sample and SL.zone_hot and state.ss_zone and state.ss_zone.clip then state.status = ({ a = 'clip start - drag (offset of the clip item)', b = 'clip end - drag (its length)', move = 'clip - drag the strip: the whole clip in the source', la = 'loop start L - drag: the part the session loops', lb = 'loop end L - drag', xf = 'loop crossfade at the seam - click: 0 / 10 / 30 / 60 / 120 ms (default off)' })[SL.zone_hot] or ''
  elseif hover.sample and SL.zone_hot then state.status = SL.zone_hot == 'move' and 'slice zone - drag the strip to move the whole slice (same length; all notes of this slice instrument)'
      or ('slice %s - drag the triangle: offset and length of this slice instrument (all its notes)'):format(SL.zone_hot == 'a' and 'start' or 'end')
  elseif hover.sample and hover.sample.sbtn == 'snap' then state.status = 'snap: selection edges, slice markers and the slice zone stick to transients and slice markers (within 8 px)'
  elseif hover.sample and hover.sample.sbtn then state.status = ({ quant = 'smart quantize: loud transients to beats, soft to 16ths, length to whole bars / beats - stretch markers, one undo (Q, :quantize)', autotrim = 'autotrim: cut the silence at the start and the end (-48 dB from the peak; z) - all notes of this instrument, one undo', eq2 = 'slice into 2 equal parts', eq4 = '4 equal parts', eq8 = '8 equal parts', eq16 = '16 equal parts', eq32 = '32 equal parts', eq64 = '64 equal parts', trans = 'slice at transients (s or t)', ['sens-'] = 'fewer transients', ['sens+'] = 'more transients', clear = 'remove all slices (x)', scram = 'scramble: the slice notes of this track in the cursor region (or the VISUAL selection) swap their slices randomly - positions stay, one undo (:scramble)' })[hover.sample.sbtn] or hover.sample.sbtn
  elseif hover.sample and hover.sample.vol then state.status = 'item volume: wheel / < > = 1 dB, click = 0 dB'
  elseif hover.sample and hover.sample.norm then state.status = 'normalize: item volume so the peak hits 0 dB (n)'
  elseif hover.sample and hover.sample.slice then state.status = ('slice marker %d - drag to move'):format(hover.sample.slice)
  elseif hover.sample then
    local e = hover.sample.e or hover.sample
    state.status = (type(e) == 'table' and e.name or 'sample') .. ' - drag: select, drag selection out: to track column; Enter: insert @cursor; D: to lib; :slice / \\is: slicer'
  elseif hover.scope then state.status = 'scope ' .. hover.scope.name .. ' - click: cursor to track'
  elseif type(hover.browser) == 'string' and hover.browser:match('^bm%d+$') then
    -- путь — во всплывашке у кнопки (5 окт), здесь только клавиши
    local i = tonumber(hover.browser:sub(3))
    state.status = B.marks[i] and ('bookmark %d - click: go, Shift+click: set to this folder, Cmd+click: clear (key %d)'):format(i, i % 10)
      or ('bookmark %d empty - click: remember this folder (key %d)'):format(i, i % 10)
  elseif type(hover.browser) == 'string' and hover.browser:match('^crumb%d+$') then
    local c = B.crumbs[tonumber(hover.browser:match('%d+'))]
    state.status = 'go to ' .. (c and c.path or '?')
  elseif type(hover.browser) == 'string' then
    state.status = ({ back = 'previous folder (H)', fwd = 'next folder (L)', mkdir = 'new folder here (*, :mkdir name)',  files = 'browser: files of :browse root', db = 'browser: REAPER Media Explorer databases', pm = 'browser: jf_pm projects (Enter: inside, drag: subproject)', proj = 'browser: audio sources used in this project (like Project Bay)', auto = 'play: listen to the selected row (p), on by default', keys = 'keys: the note keys play the selected file at their pitch (q = as is at octave 4)', wave = 'mini waveforms next to file names (native peaks)', pvvol = 'preview volume - drag, wheel: 1 dB, dblclick: 0 dB', pvwave = 'playing / selected file - click: play from here', find = 'find right in the list (fzf syntax: words, ^start, end$, \'exact, !not): folder - recursive from the current folder, open db - the db; also / or f', track = 'listen through the selected track and its FX (on) or direct to the output (off)', sync = 'sync: while the project plays, a file starts on the next bar (native measure align); stopped - at once', allfiles = 'show all file types (*.*)', hidden = 'show hidden files (.*)' })[hover.browser] or hover.browser
  elseif hover.browser == 'pmgrid' or hover.browser == 'pmlist' then state.status = 'pm: cards with thumbnails / plain list'
  elseif hover.browser == 'pmsort' then state.status = 'pm: sort - date (newest first, pinned on top) / name / bpm / status; S'
  elseif hover.browser == 'pmdaw' then state.status = 'pm: all projects / REAPER only / other DAWs only; d'
  elseif hover.browser == 'pmbig' then state.status = 'pm: the cards over the whole window (b, :pm big); Esc - back'
  elseif hover.browser then state.status = B.describe(hover.browser) .. ', wheel: scroll'
  elseif SPROP.hover and SPROP.hover.title then state.status = 'instrument name - click: rename (:iname text, all items of the instrument)'
  elseif hover.header_col or hover.col then
    local c = hover.header_col or hover.col
    state.status = c.name .. (c.muted and ' [muted]' or '') .. (c.solo and ' [solo]' or '') .. (c.armed and ' [rec]' or '') .. ' - click: select track in REAPER, dblclick name: rename (:tname), rclick: track menu'
  else state.status = '' end
  if state.debug or reaper.GetExtState(EXT, 'dbgon') == '1' then
    local ks = {}; for k in pairs(hover) do ks[#ks + 1] = k end; table.sort(ks)
    if hover.matrix then for k, v in pairs(hover.matrix) do ks[#ks + 1] = 'mx.' .. k .. '=' .. tostring(v) end end
    reaper.SetExtState(EXT, 'dbg', ('%d,%d %s | %s || pool: %s'):format(gfx.mouse_x, gfx.mouse_y, table.concat(ks, ' '), state.status, (draw.pool_dbg or '') .. ' || ' .. tostring(SL.dbg)), false)
  end

  -- мышь
  draw.pmark('mouse, hover status, drags')
  local t_3 = reaper.time_precise()
  -- перетаскивание токена на Orca: нажатие на инструмент / имя региона
  if U.click and not tok_drag then
    if hover.pool and not hover.pool.empty and hover.pool.i then tok_drag = { kind = 'inst', v = hover.pool.i, x0 = gfx.mouse_x, y0 = gfx.mouse_y }
    elseif hover.matrix and hover.matrix.name then tok_drag = { kind = 'region', v = hover.matrix.name, x0 = gfx.mouse_x, y0 = gfx.mouse_y } end
  end
  if tok_drag then
    if gfx.mouse_cap & 1 == 1 then
      if not tok_drag.active and (math.abs(gfx.mouse_x - tok_drag.x0) > 6 or math.abs(gfx.mouse_y - tok_drag.y0) > 6) then tok_drag.active = true end
      if tok_drag.active then
        state.status = (hover.garden and hover.garden.ox) and ('drop %s %d on orca (%d,%d)'):format(tok_drag.kind, tok_drag.v, hover.garden.ox, hover.garden.oy)
          or ('drag %s %d - drop on an Orca cell (orca tab)'):format(tok_drag.kind, tok_drag.v)
      end
    else
      if tok_drag.active and hover.garden and hover.garden.ox then ctx.orca_drop(tok_drag.kind, tok_drag.v, hover.garden.ox, hover.garden.oy) end
      tok_drag = nil
    end
  end
  -- файл из браузера на Orca: номер инструмента появится после снимка
  if orca_pending and snap and snap.inst_of then
    local i = snap.inst_of[orca_pending.item]
    if i then ctx.orca_drop('inst', i, orca_pending.ox, orca_pending.oy); orca_pending = nil
    elseif reaper.time_precise() - orca_pending.t > 3 then orca_pending = nil end
  end
  -- ресайз мышью: левый край браузера (ширина), нижний край верхней панели (высота)
  do
    local edge
    local W0 = gfx.w - L.side_w - (L.rstrip_w or 0)
    if state.side and math.abs(gfx.mouse_x - W0) <= 3 and gfx.mouse_y < gfx.h - L.status_h then edge = 'side'
    elseif L.fxb_rect and math.abs(gfx.mouse_x - (L.fxb_rect[1] + L.fxb_rect[3])) <= 3 and gfx.mouse_y >= L.fxb_rect[2] and gfx.mouse_y < L.fxb_rect[2] + L.fxb_rect[4] then edge = 'fxb'
    elseif state.side and L.inst_side_h and gfx.mouse_x > W0 and math.abs(gfx.mouse_y - ((L.side_y0 or 0) + L.inst_side_h + 1)) <= 3 then edge = 'inst'
    elseif state.top and math.abs(gfx.mouse_y - (L.top_first and ((L.top_y or 0) + L.top_h) or L.top_y)) <= 3 and gfx.mouse_x < W0 then edge = 'top'
    elseif L.lside_split and gfx.mouse_x < L.matrix_w - 3 and math.abs(gfx.mouse_y - L.lside_split) <= 3 then edge = 'lsplit'   -- 8 окт: матрица | браузер слева
    elseif state.clipsview and (L.sess_h or 0) > 0 and gfx.mouse_x >= L.matrix_w and gfx.mouse_x < L.win_w and math.abs(gfx.mouse_y - (L.sess_y + L.sess_h)) <= 3 then edge = 'clips' end   -- 7 окт: высота модуля клипов
    if resize_drag then
      if gfx.mouse_cap & 1 == 1 then
        if resize_drag == 'mx' and MX.fold then state.mx_fold_px = math.max(L.cw * 6, math.min(math.floor(gfx.w * 0.6), gfx.mouse_x)); state.status = ('folded matrix width %d px'):format(state.mx_fold_px)
        elseif resize_drag == 'mx' then state.mx_px = math.max(L.cw * 12, math.min(math.floor(gfx.w * 0.6), gfx.mouse_x)); state.status = ('matrix width %d px'):format(state.mx_px)
        elseif resize_drag == 'fxb' then state.fxb_px = math.max(L.cw * 12, math.min(math.floor(gfx.w * 0.5), gfx.mouse_x - (L.fxb_rect and L.fxb_rect[1] or 0))); state.status = ('fx list width %d px'):format(state.fxb_px)
        elseif resize_drag == 'side' then state.side_px = math.max(L.cw * 10, math.min(math.floor(gfx.w * 0.6), gfx.w - gfx.mouse_x))
        elseif resize_drag == 'inst' then state.inst_px = math.max(4 * L.rh, gfx.mouse_y - (L.side_y0 or 0))
        elseif resize_drag == 'lsplit' then state.lside_frac = math.max(0.1, math.min(0.9, (gfx.mouse_y - (L.lside_y0 or 0)) / math.max(1, (L.lside_y1 or gfx.h) - (L.lside_y0 or 0)))); state.status = ('matrix %d%% / browser'):format(math.floor(state.lside_frac * 100 + 0.5))
        elseif resize_drag == 'clips' then state.ss_px = math.max(5 * L.rh, gfx.mouse_y - (L.sess_y or 0)); state.status = ('clips height %d rows'):format(math.floor(state.ss_px / L.rh))
        else
          -- наверху — тянется нижний край; mid / bottom — верхний (растёт вверх)
          local want = L.top_first and (gfx.mouse_y - (L.top_y or 0)) or ((L.top_y + L.top_h) - gfx.mouse_y)
          state.top_px = math.max(4 * L.rh + 8, math.min(math.floor(gfx.h * 0.5), want))
        end
        if resize_drag ~= 'mx' and resize_drag ~= 'fxb' and resize_drag ~= 'clips' and resize_drag ~= 'lsplit' then state.status = resize_drag == 'side' and ('sidebar width %d px'):format(state.side_px) or (resize_drag == 'inst' and ('lib %d px'):format(state.inst_px) or ('top panel %d px'):format(state.top_px)) end
      else resize_drag = nil end
    elseif edge then
      state.status = edge == 'lsplit' and 'drag: matrix / browser split (dblclick: auto)' or edge == 'clips' and 'drag: clips height (dblclick: auto)' or edge == 'fxb' and 'drag: fx list width (dblclick: auto)' or edge == 'side' and 'drag: resize sidebar width (dblclick: auto)' or (edge == 'inst' and 'drag: lib / browser split (dblclick: auto)' or 'drag: resize top panel height (dblclick: auto)')
      if U.click then
        local now2 = reaper.time_precise()
        if (now2 - click.t) < 0.4 and click.zone == 'resize' then
          if edge == 'side' then state.side_px = nil elseif edge == 'inst' then state.inst_px = nil elseif edge == 'fxb' then state.fxb_px = nil elseif edge == 'clips' then state.ss_px = nil elseif edge == 'lsplit' then state.lside_frac = nil else state.top_px = nil end
        else resize_drag = edge end
        click = { t = now2, zone = 'resize' }
        U.click = false
      end
    end
  end
  -- гидра / контекстное меню мышью (5 окт): клик по строке — её буква, мимо — закрыть
  if (U.click or U.rclick) and vim.hydra and not OPT.active then
    if draw.popup_hot and U.click then vim.hydra_key(draw.popup_hot:byte())
    else
      local r = draw.popup_rect
      if not (r and gfx.mouse_x >= r[1] and gfx.mouse_x < r[1] + r[3] and gfx.mouse_y >= r[2] and gfx.mouse_y < r[2] + r[4]) then vim.hydra = nil end
    end
    U.click, U.rclick = false, false
  end
  -- линейка measure (7 окт): щелчки ставят точки, а не нажимают; второй —
  -- отчёт (px, знаки, строки, что под точками) в статус, ExtState measure и,
  -- с debug, в журнал. ПКМ — выкл; щелчок по самой опции — как обычно
  if state.measure and (U.click or U.rclick) and hover.ctrl ~= 'measure' then
    local function under(hv)
      local parts = {}
      for k, v in pairs(hv or {}) do
        local tv = type(v)
        if tv == 'string' or tv == 'number' or tv == 'boolean' then parts[#parts + 1] = k .. '=' .. tostring(v)
        elseif tv == 'table' then
          local sub = {}
          for k2, v2 in pairs(v) do local t2 = type(v2); if t2 == 'string' or t2 == 'number' or t2 == 'boolean' then sub[#sub + 1] = k2 .. ':' .. tostring(v2) end end
          table.sort(sub); parts[#parts + 1] = k .. '{' .. table.concat(sub, ' ', 1, math.min(#sub, 6)) .. '}'
        end
      end
      table.sort(parts)
      return ('focus %s | %s'):format(state.focus, table.concat(parts, ' '))
    end
    local mx, my = gfx.mouse_x, gfx.mouse_y
    if U.rclick then state.measure = false; ctx.meas = nil; vim.msg = 'measure off'
    elseif not ctx.meas or ctx.meas.b then ctx.meas = { a = { mx, my, under(hover) } }; vim.msg = 'measure: click the end point (right click - off)'
    else
      local M = ctx.meas
      M.b = { mx, my, under(hover) }
      local w, h = math.abs(mx - M.a[1]), math.abs(my - M.a[2])
      local rep = ('measure %dx%d px = %.1f chars x %.1f rows (cw %d rh %d, window %dx%d) | A %d,%d %s | B %d,%d %s'):format(
        w, h, w / L.cw, h / L.rh, L.cw, L.rh, gfx.w, gfx.h, M.a[1], M.a[2], M.a[3], mx, my, M.b[3])
      reaper.SetExtState(EXT, 'measure', rep, false)
      if state.debug then ctx.dlog(rep) end
      vim.msg = ('measure: %d x %d px = %.1f chars x %.1f rows%s'):format(w, h, w / L.cw, h / L.rh, state.debug and ' (in the debug log)' or '')
    end
    U.click, U.rclick = false, false
  end
  if U.click and OPT.ask.active then OPT.ask.click(); U.click = false end
  -- скролл-бары списков (4 окт): ползунок тянется, клик мимо — страница
  if U.click and not OPT.active then
    for key, r in pairs(draw.vbars) do
      if r.hot then
        local mp = r.horiz and gfx.mouse_x or gfx.mouse_y
        if mp >= r.ty and mp < r.ty + r.th then draw.vbar_drag = { key = key, dy = mp - r.ty }
        else ctx.vbar_scroll(key, ctx.vbar_get(key) + (mp < r.ty and -r.nvis or r.nvis)) end
        U.click = false
        break
      end
    end
  end
  if draw.vbar_drag then
    local d, r = draw.vbar_drag, draw.vbars[draw.vbar_drag.key]
    if gfx.mouse_cap & 1 == 1 and r then
      local f = ((r.horiz and gfx.mouse_x or gfx.mouse_y) - d.dy - r.a0) / math.max(1, r.alen - r.th)
      ctx.vbar_scroll(d.key, math.floor(math.max(0, math.min(1, f)) * (r.total - r.nvis) + 0.5))
    else draw.vbar_drag = nil end
  end
  -- файлы на окно (6 окт): Media Explorer / Finder → клетка сессии, колонка, инструменты
  if gfx.getdropfile then
    local got, first = gfx.getdropfile(0)
    if got and got ~= 0 then
      local files, i = { first }, 1
      while true do local ok2, fn = gfx.getdropfile(i); if not ok2 or ok2 == 0 then break end; files[#files + 1] = fn; i = i + 1 end
      gfx.getdropfile(-1)
      local ok, e = pcall(ctx.os_drop, files, hover); if not ok then vim.msg = 'drop: ' .. tostring(e):match('[^\n]*$') end
    end
  end
  if U.click and OPT.active then OPT.click(gfx.mouse_x, gfx.mouse_y); U.click = false end
  if U.click and hover.khelp_big then if hover.docsec then ctx.DOC.sec = hover.docsec; ctx.DOC.scroll = 0 end; U.click = false end   -- справка F1: раздел мышью
  -- клип под мышью (6 окт) — во вкладке item (как курсор), раз на смену клетки
  -- 8 окт: клип во вкладке item — только выбранный (клик / курсор клип-мода),
  -- пока фокус в клипах или во вкладке (правка зоны клипа); фокус ушёл —
  -- клип снят, инструмент прежний. Наведение мыши клип не показывает
  if state.ss_clip and state.focus ~= 'session' and state.focus ~= 'top' and not state.ss_big then
    local cl = state.ss_clip
    state.ss_clip, state.ss_zone = nil, nil
    if cl.prev and cl.prev ~= vim.inst then local pp = state.poolprev; state.poolprev = false; pool_select(cl.prev); state.poolprev = pp end
  end
  do   -- ReaEQ: подсветка точки под мышью / в протяжке (кадр спустя)
    local e = ctx.eq_drag or hover.dspeq
    draw.eq_hot, draw.eq_hot_fx = e and e.band, e and e.f.i
  end
  if U.click and hover.dbparam then   -- большой роутер: слайдер параметра (двойной клик — умолчание)
    local hp, now3 = hover.dbparam, reaper.time_precise()
    local t = dsp_target()
    local lc = MX.DB.last_pclick
    if t and lc and lc.addr == hp.addr and lc.i == hp.i and now3 - lc.t < 0.35 then
      edit.fx_param_default(t.track, hp.addr, hp.i); MX.DB.pdrag = nil; MX.DB.last_pclick = nil
      vim.msg = (hp.name or 'parameter') .. ': default'
    else
      MX.DB.last_pclick = { addr = hp.addr, i = hp.i, t = now3 }
      MX.DB.pdrag = { addr = hp.addr, i = hp.i, x = hp.x, w = hp.w }
    end
    ctx.set_focus('dsp'); if hover.dbnode then MX.DB.sel = hover.dbnode.guid end
    U.click = false
  end
  if MX.DB.pdrag then
    if gfx.mouse_cap & 1 == 1 then
      local d, t = MX.DB.pdrag, dsp_target()
      if t then edit.fx_param(t.track, d.addr, d.i, (gfx.mouse_x - d.x) / math.max(1, d.w)) end
    else MX.DB.pdrag = nil end
  end
  if U.click and hover.dbig then ctx.set_focus('dsp'); MX.DB.click(hover, reaper.time_precise()); U.click = false end   -- DSP big: узел
  -- параметр TCP под эффектом (8 окт): тянуть по горизонтали, двойной
  -- клик — умолчание, колесо — шаг 1 %
  if U.click and hover.hdrparam then
    local hp, now3 = hover.hdrparam, reaper.time_precise()
    local lc = ctx.hp_last
    if lc and lc.track == hp.track and lc.fx == hp.fx and lc.param == hp.param and now3 - lc.t < 0.35 then
      edit.fx_param_default(hp.track, hp.fx, hp.param); ctx.hp_drag, ctx.hp_last = nil, nil
      vim.msg = (hp.name or 'parameter') .. ': default'
    else
      ctx.hp_last = { track = hp.track, fx = hp.fx, param = hp.param, t = now3 }
      ctx.hp_drag = { track = hp.track, fx = hp.fx, param = hp.param, x = hp.x, w = hp.w }
    end
    U.click = false
  end
  if ctx.hp_drag then
    if gfx.mouse_cap & 1 == 1 then
      local d = ctx.hp_drag
      if reaper.ValidatePtr(d.track, 'MediaTrack*') then edit.fx_param(d.track, d.fx, d.param, (gfx.mouse_x - d.x) / math.max(1, d.w)) end
    else ctx.hp_drag = nil end
  end
  if gfx.mouse_wheel ~= 0 and hover.hdrparam then
    local hp = hover.hdrparam
    edit.fx_param(hp.track, hp.fx, hp.param, reaper.TrackFX_GetParamNormalized(hp.track, hp.fx, hp.param) + (gfx.mouse_wheel > 0 and 0.01 or -0.01))
    gfx.mouse_wheel = 0
  end
  if U.click and (hover.hdrfx or hover.hdrinst or hover.hdrsend) then   -- фишки шапки (7 окт)
    local h2 = hover.hdrfx or hover.hdrinst or hover.hdrsend
    local kind = hover.hdrfx and 'fx' or (hover.hdrinst and 'inst' or 'send')
    local now3 = reaper.time_precise()
    local lc = ctx.hdr_last
    local dbl = lc and lc.kind == kind and lc.col == h2.col and lc.k == h2.k and now3 - lc.t < 0.35
    ctx.hdr_last = { kind = kind, col = h2.col, k = h2.k, t = now3 }
    ctx.hdr_pick(kind, h2.col, h2.k, dbl or (kind == 'fx' and state.fxparams))   -- с параметрами: клик по имени — окно эффекта
    U.click = false
  end
  -- клип (7 окт): > в углу — запуск, o под последним клипом — запись в слот
  if U.click and (hover.ssplay or hover.ssrecbtn) and snap then
    local h2 = hover.ssplay or hover.ssrecbtn
    MX.SS.cur.ri, MX.SS.cur.ci = h2.ri, h2.ci
    if hover.ssplay then MX.SS.launch(h2.ri, h2.ci, seq) elseif ctx.ss_record then ctx.ss_record(h2.ri, h2.ci) end
    U.click = false
  end
  if U.click and hover.ssfa and snap then   -- буква follow action клипа (7 окт): клик — следующее действие
    local a = MX.SS.fa_next(ctx.ss_fa(hover.ssfa.ci, hover.ssfa.ri), 1)
    ctx.ss_fa_set(hover.ssfa.ci, hover.ssfa.ri, seq, a); vim.msg = 'follow action: ' .. MX.SS.FA_NAME[a]
    U.click = false
  end
  if U.click and hover.ssbig and snap and MX.SS.click(hover, seq, ctx.ss_V(), ctx.ss_G(), reaper.time_precise()) then if not state.ss_big then ctx.set_focus(state.clipsview and 'session' or (hover.topclips and 'top' or 'matrix')) end; U.click = false end   -- session: клетка / сцена / кнопки; мимо — клик идёт дальше
  if U.rclick and OPT.active and OPT.rclick and OPT.rclick() then U.rclick = false end   -- ПКМ по имени: в быстрые опции (6 окт)
  if U.click and bpm_menu then
    if bpm_menu.hover then
      local it = BPM_LIST[bpm_menu.hover]
      if it[2] == 'item' then local b, why = bpm_from_item(); if b then set_bpm(b, why) else vim.msg = 'BPM: ' .. why end
      else set_bpm(it[2]) end
      bpm_menu = nil; U.click = false
    elseif not (hover.ctrl == 'bpm') then bpm_menu = nil; U.click = false end
  end
  -- всплывающий слайдер свёрнутой кнопки: клик мимо него и мимо кнопок — закрыть
  if U.click and draw.trspop and not hover.trspop_in and not hover.trsbtn then draw.trspop = nil end
  if U.click and draw.sendpop and not hover.sendpop_in and not (hover.trkio and hover.trkio.what == 'sends') then draw.sendpop = nil end
  ctx.click_guard = U.click and state.focusclick ~= 'click' and not ctx.mods().alt or nil
  if U.click and state.kslider then state.kslider = nil end                -- клик — выход из режима слайдера
  if U.click and not vim.picker then ctx.focus_at(gfx.mouse_x, gfx.mouse_y) end
  if U.click then
    local now2 = reaper.time_precise()
    local dbl = (now2 - click.t) < 0.4
    if hover.prevbtn then
      ctx.set_focus('inst')
      state.poolprev = not state.poolprev; vim.msg = 'play on select ' .. (state.poolprev and 'on' or 'off')
      click = { t = now2, zone = 'prevbtn' }
    elseif hover.poolfind then
      ctx.set_focus('inst'); ctx.inst_find()
      click = { t = now2, zone = 'poolfind' }
    elseif hover.poolbsync then
      ctx.set_focus('inst'); ctx.bsync_toggle()
      click = { t = now2, zone = 'poolbsync' }
    elseif hover.zone then
      if hover.zone == 'prev' then OPT.tour.go(-1) elseif hover.zone == 'next' then OPT.tour.go(1) elseif hover.zone == 'stop' then OPT.tour.stop() end
      click = { t = now2, zone = 'tourzone' }
    elseif hover.poolsave then
      ctx.set_focus('inst'); ctx.kit_save_prompt(); click = { t = now2, zone = 'poolsave' }
    elseif hover.swapbtn then
      ctx.set_focus('inst'); ctx.swap_click()
      click = { t = now2, zone = 'swapbtn' }
    elseif hover.insprevbtn then
      ctx.set_focus('inst')
      state.preview = not state.preview; vim.msg = 'play on insert ' .. (state.preview and 'on' or 'off')
      click = { t = now2, zone = 'insprevbtn' }
    elseif hover.poolsortcol then
      local k = hover.poolsortcol
      state.poolsort = (k == 'index') and (state.poolsort == 'track' and 'mark' or 'track') or k
      vim.msg = 'lib order: ' .. ({ track = 'tree by track', mark = 'marks @ $ *', name = 'name', len = 'length' })[state.poolsort]
      click = { t = now2, zone = 'poolsortcol' }
    elseif hover.poolsort then
      ctx.set_focus('inst')
      state.poolsort = ({ track = 'len', len = 'mark', mark = 'track' })[state.poolsort or 'track'] or 'track'
      vim.msg = 'instrument order: ' .. state.poolsort
      click = { t = now2, zone = 'poolsort' }
    elseif hover.garden then
      ctx.set_focus('top')
      if hover.garden.ri then
        local same = click.zone == 'garden' and click.row == hover.garden.ri and click.ci == hover.garden.ci
        GD.cur = { ri = hover.garden.ri, ci = hover.garden.ci }
        if dbl and same then ctx.region_space(seq[hover.garden.ri]) end
        click = { t = now2, zone = 'garden', row = hover.garden.ri, ci = hover.garden.ci }
      elseif hover.garden.ox then
        GD.ocur = { x = hover.garden.ox, y = hover.garden.oy }
        click = { t = now2, zone = 'gardenorca' }
      end
    elseif hover.midimap then
      ctx.set_focus('top')
      local i = hover.midimap.row
      if hover.midimap.btn == 'mode' then MM.cur = i; if MM.key(('m'):byte()) == 'save' then mm_save() end
      elseif MM.cur == i then MM.key(13)          -- второй клик по строке — learn
      else MM.cur = i end
      click = { t = now2, zone = 'midimap' }
    elseif lfo_hover and state.top and state.toptab == 'modulation' then
      ctx.set_focus('top'); mod_pane = lfo_hover.pane or 'lfo'
      if lfo_hover.pp then MMX.PP.click(cur_col(), lfo_hover.pp, dbl) end
      if lfo_hover.field then
        LG.sel = lfo_hover.field
        local f = LG.FIELDS[lfo_hover.field]
        if f.button then ctx.lfo_make(f.key)
        elseif lfo_hover.opt then LG.set_opt(LG.sel, lfo_hover.opt)
        elseif lfo_hover.slider then
          lfo_drag = { field = LG.sel, x = lfo_hover.x, w = lfo_hover.w }
          LG.set_frac(LG.sel, (gfx.mouse_x - lfo_hover.x) / math.max(1, lfo_hover.w))
        elseif f.key == 'src' and LG.type == 'follow' and LG.fsrc == 'env' then ctx.lfo_pick_env()
        elseif f.enum or f.toggle or f.key == 'src' then LG.adjust(LG.sel, 1) end
      end
      click = { t = now2, zone = 'lfo' }
    elseif hover.mm and hover.mm.strip then
      -- полоса матрицы: форма LFO / тумблер группы / слайдер
      ctx.set_focus('top')
      local rows = cur_col() and cur_col().mods or {}
      local r = rows[MMX.row]
      if r then
        local h = hover.mm
        if h.strip == 'shape' then ctx.mod_field(r, 'lfo.shape', h.v); if (r.v and r.v['lfo.active'] or 0) < 0.5 then ctx.mod_field(r, 'lfo.active', 1) end
        elseif h.strip == 'toggle' then ctx.mod_field(r, h.key, ((r.v and r.v[h.key]) or 0) >= 0.5 and 0 or 1)
        elseif h.strip == 'slider' then mm_drag = { r = r, ci = h.ci, x = h.x, w = h.w } end
      end
      click = { t = now2, zone = 'mmstrip' }
    elseif hover.mm then
      ctx.set_focus('top')
      local same = click.zone == 'mm' and click.row == hover.mm.row and click.ci == hover.mm.col
      MMX.row, MMX.col = hover.mm.row, hover.mm.col
      if dbl and same then MMX.activate(cur_col() and cur_col().mods or {}) end
      click = { t = now2, zone = 'mm', row = hover.mm.row, ci = hover.mm.col }
    elseif hover.scopemode then ctx.scopemode(hover.scopemode); click = { t = now2, zone = 'scopemode' }
    elseif hover.monobtn then ctx.mono_take(hover.monobtn == 'take'); click = { t = now2, zone = 'monobtn' }
    elseif hover.retrobtn then
      local b = hover.retrobtn
      ctx.set_focus(hover.retro_src or 'top')          -- блок rec в DSP — фокус остаётся в DSP
      if b == 'prev' then ctx.retro_cycle(-1) elseif b == 'next' then ctx.retro_cycle(1)
      elseif b == 'all' then ctx.retro_all() elseif b == 'play' then retro_preview(true) elseif b == 'stop' then retro_preview(false)
      elseif b == 'put' then retro_put('cursor') elseif b == 'depot' or b == 'lib' then retro_put('depot')   -- кнопка depot шлёт 'lib' (4 окт: не работала) elseif b == 'add' then ctx.retro_add()
      elseif b == 'loop' then
        -- во время игры — подхватить и лупить; в стопе — следующая длина 1 / 2 / 4 / 8
        if playing() then retro_loop()
        else retro.loop_bars = ({ [1] = 2, [2] = 4, [4] = 8, [8] = 1 })[retro.loop_bars] or 2; vim.msg = 'retro loop length: ' .. retro.loop_bars .. ' bar(s)' end
      end
      click = { t = now2, zone = 'retrobtn' }
    elseif hover.retro then
      ctx.set_focus(hover.retro_src or 'top')
      local a, b = math.min(retro.sel.a, retro.sel.b), math.max(retro.sel.a, retro.sel.b)
      if b - a > 0.002 and hover.retro > a and hover.retro < b then
        -- нажатие внутри выделения — вынос: бросить на слот инструментов или колонку трека
        retro.out = { x0 = gfx.mouse_x, y0 = gfx.mouse_y, active = false, at = hover.retro }
      else
        retro.sel.a = hover.retro; retro.sel.b = hover.retro; retro.drag = true
      end
      click = { t = now2, zone = 'retro' }
    elseif hover.recbtn then
      -- [rec] вкладки item: правка item <-> запись (кольцо jf_rec, бывшая вкладка retro)
      state.toptab = state.toptab == 'retro' and 'sample' or 'retro'
      ctx.set_focus('top')
      vim.msg = state.toptab == 'retro' and 'item rec: jf_rec ring - select, Space listen, p put, L loop, d to library' or 'item: edit'
      click = { t = now2, zone = 'recbtn' }
    elseif hover.tab then
      state.toptab = hover.tab
      ctx.set_focus('top')
      click = { t = now2, zone = 'tab' }
    elseif hover.sample and hover.sample.sbtn == 'rec' then
      -- [rec] в углу вкладки item: в режим записи (кольцо jf_rec)
      state.toptab = 'retro'; ctx.set_focus('top')
      vim.msg = 'item rec: jf_rec ring - select, Space listen, p put, L loop, d to library; [rec] again: back'
      click = { t = now2, zone = 'recbtn' }
    elseif hover.sample and hover.sample.sbtn then
      ctx.set_focus('top')
      local e = hover.sample.e
      if e and e.item and not (SL.active and SL.entry and SL.entry.item == e.item) then SL.open(e, cur_col() and cur_col().track) end
      SL.button(hover.sample.sbtn)
      click = { t = now2, zone = 'slicebtn' }
    elseif hover.sample and hover.sample.norm then
      ctx.set_focus('top'); if hover.sample.e.item then edit.normalize(hover.sample.e.item); vim.msg = 'normalized (peak 0 dB)' end
    elseif hover.sample and hover.sample.vol then
      ctx.set_focus('top'); if hover.sample.e.item then edit.item_vol(hover.sample.e.item, 0); hover.sample.e.vol = 1; vim.msg = 'vol 0 dB' end
    elseif hover.sample and hover.sample.view then
      ctx.set_focus('top')
      if hover.sample.view == 'big' then ctx.sample_big() else SL.view = hover.sample.view end
      click = { t = now2, zone = 'sampleview' }
    elseif hover.sample and SL.zone_hot and state.ss_zone and state.ss_zone.clip then
      -- клип сессии (6 окт): начало / конец / перенос / метки лупа L / xf
      ctx.set_focus('top')
      local z = state.ss_zone
      if SL.zone_hot == 'xf' then
        local steps = { 0, 10, 30, 60, 120 }
        local cur = math.floor((z.xf or 0) * 1000 + 0.5)
        local nxt = steps[1]
        for i, v in ipairs(steps) do if v == cur then nxt = steps[i % #steps + 1] end end
        edit.run('clip loop crossfade', function() reaper.GetSetMediaItemInfo_String(z.item, 'P_EXT:jf_clipxf', tostring(nxt), true) end)
        vim.msg = ('clip loop crossfade: %d ms (applies at the next launch)'):format(nxt)
      else
        local wv = SL.wave
        local grab = (wv and wv.w > 0) and SL.x_to_t(gfx.mouse_x) or z[1]
        SL.zone_drag = { clip = true, edge = SL.zone_hot, item = z.item, er = z.er, eo = z.eo, cr = z.cr, p = { name = 'clip' },
                         a = z[1], b = z[2], a0 = z[1], b0 = z[2], la = z.loop[1], lb = z.loop[2], la0 = z.loop[1], lb0 = z.loop[2], grab = grab }
      end
      click = { t = now2, zone = 'slicezone' }
    elseif hover.sample and SL.zone_hot then
      -- край зоны слайса: тянуть начало / конец слайса по большому сэмплу (2 окт)
      ctx.set_focus('top')
      local col = cur_col(); local e = col and (col.pool or {})[vim.inst]
      -- выбранный слайс модуля слайсов (5 окт): его кусок, если есть ноты;
      -- нет нот — тянутся сами границы слайса в нарезке сэмпла
      local root = ctx.slice_root()
      local sk = root and ctx.selected_slice(root)
      if sk and sk > 0 then
        local child = ctx.slice_child(col, root, sk)
        if child then e = child
        elseif root.slices and root.slices[sk] then
          local a0 = root.slices[sk]
          local b0 = root.slices[sk + 1] or root.len
          local wv = SL.wave
          local grab = (wv and wv.w > 0) and SL.x_to_t(gfx.mouse_x) or a0
          SL.zone_drag = { edge = SL.zone_hot, e = root, p = root, a = a0, b = b0, a0 = a0, b0 = b0, grab = grab, marks = sk }
          e = nil
        end
      end
      if e and e.parent and e.item then
        local p = e.parent; local pr = (p.rate and p.rate ~= 0) and p.rate or 1
        local a0, b0 = (e.offs - p.offs) / pr, (e.offs - p.offs + e.len * (e.rate or 1)) / pr
        local wv = SL.wave
        local grab = (wv and wv.w > 0) and SL.x_to_t(gfx.mouse_x) or a0
        SL.zone_drag = { edge = SL.zone_hot, e = e, p = p, a = a0, b = b0, a0 = a0, b0 = b0, inst = vim.inst, grab = grab }
      end
      click = { t = now2, zone = 'slicezone' }
    elseif hover.sample then
      ctx.set_focus('top')
      -- просмотр инструмента без правки: открыть его в модуле, чтобы выделять
      if not SL.active and hover.sample.e and hover.sample.e.item then SL.open(hover.sample.e, cur_col() and cur_col().track) end
      if hover.sample.slice then
        -- слайс-маркер: тянуть мышью (правка открывается на этом инструменте)
        if SL.entry ~= hover.sample.e and hover.sample.e.item then SL.open(hover.sample.e, cur_col() and cur_col().track) end
        SL.slice_down(hover.sample.slice)
      elseif hover.sample.frac then SL.mouse_down(hover.sample.frac) end
      click = { t = now2, zone = 'sample' }
    elseif hover.mod then
      ctx.set_focus('top')
      for i, m in ipairs(cur_col() and cur_col().mods or {}) do if m == hover.mod.m then modsel = i end end
      ctx.mod_toggle(hover.mod.col, hover.mod.m, hover.mod.what)
      click = { t = now2, zone = 'mod' }
    elseif hover.viewbtn == 'session' then ctx.clips_toggle()          -- уголок: session | effects (7 окт)
    elseif hover.viewbtn == 'fxparams' then
      state.fxparams = not state.fxparams; reaper.SetExtState(EXT, 'fxparams', state.fxparams and '1' or '0', true)
      if state.fxparams and not state.fxrow then state.fxrow = true; reaper.SetExtState(EXT, 'fxrow', '1', true) end
      ctx.hdr_cache = {}; relayout()
    elseif hover.viewbtn == 'effects' then state.fxrow = not state.fxrow; reaper.SetExtState(EXT, 'fxrow', state.fxrow and '1' or '0', true); relayout()
    elseif hover.viewbtn then ctx.view_reg(hover.viewbtn == 'reg')
    elseif hover.rgbtn then ctx.region_btn(hover.rgbtn)
    elseif hover.rglen then
      if hover.rglen ~= 0 then ctx.region_len_step(hover.rglen) end
      click = { t = now2, zone = 'rglen' }
    elseif hover.ruler then
      ctx.set_focus('tracker'); vim.cur.row = hover.ruler
      click = { t = now2, zone = 'ruler' }
    elseif hover.sidectl then
      if hover.sidectl == 'open' then state.side = true; vim.msg = 'sidebar shown'
      elseif hover.sidectl == 'close' then ctx.side_hide(); vim.msg = 'sidebar folded (click the strip to open)'
      elseif hover.sidectl == 'grip' then
        if dbl and click.zone == 'sidegrip' then state.side_px = nil; vim.msg = 'sidebar width: auto' else resize_drag = 'side' end
      elseif hover.sidectl == 'instgrip' then
        if dbl and click.zone == 'instgrip' then state.inst_px = nil; vim.msg = 'lib height: auto' else resize_drag = 'inst' end
      end
      click = { t = now2, zone = (hover.sidectl == 'grip' and 'sidegrip') or (hover.sidectl == 'instgrip' and 'instgrip') or 'sidectl' }
    elseif hover.mxctl then
      if hover.mxctl == 'open' then state.mx_hidden = false; vim.msg = 'matrix shown'
      elseif hover.mxctl == 'close' then state.mx_hidden = true; if state.focus == 'matrix' then ctx.set_focus('tracker') end; vim.msg = 'matrix folded (> to open)'
      elseif hover.mxctl == 'grip' then
        if dbl and click.zone == 'mxgrip' then
          if MX.fold then state.mx_fold_px = nil else state.mx_px = nil end
          vim.msg = 'matrix width: auto'
        else resize_drag = 'mx' end
      end
      click = { t = now2, zone = hover.mxctl == 'grip' and 'mxgrip' or 'mxctl' }
    elseif hover.slices ~= nil then
      -- модуль слайсов (4 окт): клик — выбрать и прослушать
      ctx.set_focus('slices')
      local root = ctx.slice_root()
      if state.auto_inst then
        local same = click.zone == 'slicelist' and click.row == hover.slices
        ctx.ai_sel = hover.slices; local a = ctx.ai_list()[hover.slices]
        vim.msg = a and ('automation %s: a note key inserts it, double click edits it'):format(a.label) or ''
        if dbl and same and a then ctx.ai_edit_open(a) end
        click = { t = now2, zone = 'slicelist', row = hover.slices }; goto ai_click_done
      elseif root then ctx.ssel.item = root.item; ctx.ssel.k = 0; ctx.slice_step(hover.slices) end
      click = { t = now2, zone = 'slicelist' }
      ::ai_click_done::
    elseif SPROP.hover and state.top and state.toptab == 'sample' then
      ctx.set_focus('top')
      local e = cur_col() and (cur_col().pool or {})[vim.inst]
      if SPROP.hover.title then ctx.rename_inst_prompt(); click = { t = now2, zone = 'sproptitle' }; goto sprop_done end
      if SPROP.hover.fit then ctx.sprops_fit(); click = { t = now2, zone = 'spropfit' }; goto sprop_done end
      local same = click.zone == 'sprop' and click.row == SPROP.hover.row
      SPROP.sel = SPROP.hover.row or SPROP.sel
      if e and dbl and same and SPROP.hover.k == 'fx' then edit.take_chain_window(e.take)   -- окно take FX REAPER
      elseif e and dbl and same then ctx.sp_reset(e, SPROP.hover.k)
      elseif e and SPROP.hover.bar then SPROP.drag = { k = SPROP.hover.k, x = SPROP.hover.bar.x, w = SPROP.hover.bar.w }; ctx.sp_set_frac(e, SPROP.hover.k, (gfx.mouse_x - SPROP.hover.bar.x) / math.max(1, SPROP.hover.bar.w))   -- слайдер (5 окт)
      elseif e and (SPROP.hover.k == 'mode' or SPROP.hover.k == 'chan' or SPROP.hover.k == 'finshape' or SPROP.hover.k == 'foutshape') then ctx.sp_menu(e, SPROP.hover.k)   -- выпадашка (5 окт)
      elseif e and (SPROP.hover.k == 'ppitch' or SPROP.hover.k == 'loop' or SPROP.hover.k == 'fx' or SPROP.hover.k == 'norm' or SPROP.hover.k == 'mute' or SPROP.hover.k == 'lock' or SPROP.hover.k == 'swing' or SPROP.hover.k == 'pthru') then ctx.sp_adjust(e, SPROP.hover.k, 1) end
      click = { t = now2, zone = 'sprop', row = SPROP.hover.row }
      ::sprop_done::
    elseif hover.dspcomp then
      ctx.gain_comp(hover.dspcomp); click = { t = now2, zone = 'dspcomp' }
    elseif hover.mixpk then
      if reaper.ValidatePtr(hover.mixpk, 'MediaTrack*') then reaper.Track_GetPeakHoldDB(hover.mixpk, 0, true); reaper.Track_GetPeakHoldDB(hover.mixpk, 1, true) end
      click = { t = now2, zone = 'mixpk' }   -- сброс макс. пика / клипа — нативный, как щелчок в микшере REAPER
    elseif hover.trkio then
      ctx.track_io(hover.trkio.col, hover.trkio.what)
      click = { t = now2, zone = 'trkio' }
    elseif hover.sendpop then
      ctx.send_action(hover.sendpop); click = { t = now2, zone = 'sendpop' }
    elseif hover.sendvol then
      draw.send_drag = hover.sendvol; click = { t = now2, zone = 'sendvol' }
    elseif hover.hdrin then
      if hover.hdrin.what == 'smart' then ctx.smart_input(hover.hdrin.col) else ctx.input_picker(hover.hdrin.col) end
      click = { t = now2, zone = 'hdrin' }
    elseif hover.hsb then
      -- скролл-бар треков (3 окт): ползунок тянется, клик мимо — страница
      if hover.hsb.thumb then draw.hsb_drag = { x0 = gfx.mouse_x, b0 = L.hs_before, w = hover.hsb.w, n = hover.hsb.n }
      else
        local b = math.max(0, math.min(L.hs_n - 1, L.hs_before + hover.hsb.dir * hover.hsb.page))
        state.hscroll = L.hs_list[b + 1] or state.hscroll
      end
      click = { t = now2, zone = 'hsb' }
    elseif hover.trsbtn then
      local t = hover.trsbtn
      local open = draw.trspop and draw.trspop.guid == t.col.guid and draw.trspop.what == t.what
      draw.trspop = (not open) and { guid = t.col.guid, what = t.what } or nil
      if not open then state.kslider = { col = t.col, what = t.what } else state.kslider = nil end   -- 8 окт: фокус клавиатуры на открытый слайдер
      click = { t = now2, zone = 'trsbtn' }
    elseif hover.trs then
      local t = hover.trs
      if dbl and click.zone == 'trs' and click.row == t.what then
        edit.track_value(t.col.track, TRS_KEY[t.what], TRS_RESET[t.what]); edit.track_undo('track ' .. t.what .. ' reset'); model.invalidate()
        trs_drag = nil
      else
        trs_drag = { col = t.col, what = t.what, x0 = t.x0, w = t.w, vert = t.vert, y0 = t.y0, h = t.h }
      end
      -- 8 окт: щелчок по фейдеру микшера — клавиатура на нём (как f): k j, h l
      if t.vert and t.what == 'vol' then
        state.kslider = { col = t.col, what = 'vol' }
        vim.msg = ('%s fader: k j volume, h l pan (Shift fine), 0 reset, Esc done'):format(t.col.name or '')
      end
      click = { t = now2, zone = 'trs', row = t.what }
    elseif hover.fxcolbtn then
      ctrl_action('fx', hover.fxcolbtn); vim.msg = ('fx columns: %d'):format(state.fxcols)
      click = { t = now2, zone = 'fxcolbtn' }
    elseif hover.envpm then
      if hover.envpm.d > 0 then ctx.automation_picker(hover.envpm.col) else ctx.env_hide(hover.envpm.e) end
      click = { t = now2, zone = 'envpm' }
    elseif hover.lanebtn then
      ctx.lane_subs(hover.lanebtn.col, hover.lanebtn.lane, hover.lanebtn.d, hover.lanebtn.n)
      click = { t = now2, zone = 'lanebtn' }
    elseif hover.matrix and hover.matrix.btn then
      ctx.set_focus('matrix')
      if hover.matrix.btn == 'zoom' then ctx.mx_zoom()
      elseif hover.matrix.btn == 'fold' then ctx.mx_fold_toggle()
      elseif hover.matrix.btn == 'fill' then MX.fill = not MX.fill
      elseif hover.matrix.btn == 'sync' then vim.msg = 'synced ' .. tostring(ctx.sync_here())
      elseif hover.matrix.btn == 'trim' then ctx.mx_trim()
      elseif hover.matrix.btn == 'ruler' then ctx.mx_ruler_toggle()
      elseif hover.matrix.btn == 'loops' then ctx.mx_loops_toggle()
      elseif hover.matrix.btn == 'clips' then ctx.mx_clips_toggle()
      elseif hover.matrix.btn == 'mkstart' or hover.matrix.btn == 'mkend' then
        -- поле Start / End: клик — ввод такта, Shift+клик — строка курсора
        local w = hover.matrix.btn == 'mkstart' and 'start' or 'end'
        if gfx.mouse_cap & 8 == 8 then ctx.seq_marker(w)
        else ctx.set_focus('matrix'); MX.mkedit = { which = w, buf = '' } end
      elseif hover.matrix.btn == 'add' then ctx.mx_add() end
      click = { t = now2, zone = 'mxbtn' }
    elseif hover.matrix and hover.matrix.name then
      ctx.set_focus('matrix')
      MX.goto_cell(seq, snap, hover.matrix.name, MX.cur.ci)
      if dbl and click.zone == 'mxname' and click.row == hover.matrix.name then ctx.mx_name_prompt() end
      click = { t = now2, zone = 'mxname', row = hover.matrix.name }
    elseif hover.matrix and hover.matrix.sig then
      MX.goto_cell(seq, snap, hover.matrix.sig, MX.cur.ci); ctx.sig_prompt(seq[hover.matrix.sig])
      click = { t = now2, zone = 'mxsig' }
    elseif hover.matrix and hover.matrix.dur then
      ctx.mx_len_prompt(hover.matrix.dur)
      click = { t = now2, zone = 'mxdur', row = hover.matrix.dur }
    elseif hover.matrix and hover.matrix.prev then ctx.set_focus('matrix'); ctx.slot_cycle(hover.matrix.prev, -1); click = { t = now2, zone = 'mxarrow' }
    elseif hover.matrix and hover.matrix.next then ctx.set_focus('matrix'); ctx.slot_cycle(hover.matrix.next, 1); click = { t = now2, zone = 'mxarrow' }
    elseif hover.matrix and hover.matrix.ri and hover.matrix.ci then
      ctx.set_focus('matrix')
      MX.goto_cell(seq, snap, hover.matrix.ri, hover.matrix.ci)
      if dbl and click.zone == 'matrix' and click.row == hover.matrix.ri then
        if reaper.GetPlayState() & 1 == 1 then
          ctx.region_space(seq[hover.matrix.ri])          -- играет: в очередь
        else
          -- стоит: не запускать — открыть место в трекере на канале ячейки
          local rg = seq[hover.matrix.ri]
          if rg then
            ctx.scroll_to(rg.r0, hover.matrix.ci or MX.cur.ci)
            ctx.set_focus('tracker')
            vim.msg = ('open slot %d · %s'):format(hover.matrix.ri, (snap.cols[hover.matrix.ci or MX.cur.ci] or {}).name or '')
          end
        end
      end
      click = { t = now2, zone = 'matrix', row = hover.matrix.ri }
    elseif hover.browser == 'pvvol' and dbl and click.zone == 'pvvol' then
      ctx.preview_set_vol(1); vim.msg = 'preview volume 0 dB'
    elseif type(hover.browser) == 'string' then
      B.click(hover.browser)
      click = { t = now2, zone = hover.browser == 'pvvol' and 'pvvol' or 'browserbtn' }
    elseif hover.browser then
      ctx.set_focus('browser')
      B.cur = hover.browser
      if dbl and click.zone == 'browser' and click.row == hover.browser then B.enter() end
      click = { t = now2, zone = 'browser', row = hover.browser }
      local e = B.entries[hover.browser]
      if e and not e.dir and not e.db and not e.pmdir and not e.mark then B.drag = { e = e, x0 = gfx.mouse_x, y0 = gfx.mouse_y, active = false } end
    elseif hover.notes then
      ctx.set_focus('notes')
      if hover.notes == 'project' or hover.notes == 'context' or hover.notes == 'dev' then ctx.notes_target(hover.notes) end
      -- плавающее окошко: шапка — перенос, угол — размер (4 окт)
      if (hover.notes == 'drag' or hover.notes == 'resize') and L.notes_rect then
        local r = L.notes_rect
        ctx.nt_drag = { mode = hover.notes, mx = gfx.mouse_x, my = gfx.mouse_y, r = { r[1], r[2], r[3], r[4] } }
      end
      -- коробка задачи (4 окт): переключить и сразу записать
      local tl = tonumber(tostring(hover.notes):match('^todo:(%d+)$'))
      if tl and NT.toggle(tl) then ctx.notes_save(); vim.msg = 'todo ' .. (NT.lines[tl]:match('%[x%]') and 'done' or 'open') end
      if hover.notes == 'zoom-' or hover.notes == 'zoom+' then
        local cur = (state.notes_scale or 0) > 0 and state.notes_scale or draw.SCALE
        state.notes_scale = math.max(1, math.min(4, cur + (hover.notes == 'zoom+' and 1 or -1)))
        vim.msg = 'notes text x' .. state.notes_scale
      end
      click = { t = now2, zone = 'notes' }
    elseif hover.fxb then
      ctx.set_focus('fxb')
      if type(hover.fxb) == 'table' and hover.fxb.folder then
        FB.folder = hover.fxb.folder; FB.cur = 1; FB.scroll = 0; FB.skip_hdr(1)
        vim.msg = 'fx: ' .. FB.folder .. ({ all = ' - every installed fx', fav = ' - favourites (REAPER Favorites + * here)', dev = ' - by developer', type = ' - by type', cat = ' - by category (REAPER fx tags)', rec = ' - recently added' })[FB.folder]
      elseif type(hover.fxb) == 'table' and hover.fxb.star then
        local it = FB.selected()
        if it then FB.toggle_fav(it); ctx.fxb_save(); vim.msg = (FB.is_fav(it) and '* favourite: ' or 'not a favourite: ') .. FB.short(it.label) end
      elseif type(hover.fxb) == 'table' then
        local same = FB.cur == hover.fxb.row
        FB.cur = hover.fxb.row
        if dbl and same and click.zone == 'fxb' then ctx.fxb_add()
        else local it = FB.selected(); if it then fxb_drag = { it = it, x0 = gfx.mouse_x, y0 = gfx.mouse_y, active = false } end end
      end
      click = { t = now2, zone = 'fxb' }
    elseif hover.dspbtn then
      -- кнопки блока: O окно, B bypass, x удалить
      ctx.set_focus('dsp')
      dsp_sel.fx = hover.dspbtn.fx
      if hover.dspbtn.what == 'open' then ctx.dsp_show(hover.dspbtn.fx)
      elseif hover.dspbtn.what == 'bypass' then ctx.dsp_bypass(hover.dspbtn.fx)
      elseif hover.dspbtn.what == 'delta' then ctx.dsp_delta(hover.dspbtn.fx)
      elseif hover.dspbtn.what == 'pprev' then ctx.dsp_preset(hover.dspbtn.fx, 'prev')
      elseif hover.dspbtn.what == 'pnext' then ctx.dsp_preset(hover.dspbtn.fx, 'next')
      elseif hover.dspbtn.what == 'vmode' then
        state.eqgraph = not state.eqgraph; reaper.SetExtState(EXT, 'eqgraph', state.eqgraph and '1' or '0', true)
        vim.msg = 'ReaEQ: ' .. (state.eqgraph and 'graph only (P - parameters)' or 'parameters only (G - graph)')
      elseif hover.dspbtn.what == 'preset' then ctx.dsp_preset(hover.dspbtn.fx, 'pick')
      elseif hover.dspbtn.what == 'del' and not (dbl and click.zone == 'dspbtn') then ctx.dsp_delete(hover.dspbtn.fx, hover.dspbtn.fx)   -- двойной клик не удаляет второй
      elseif hover.dspbtn.what == 'kdel' and hover.dspbtn.kid and not (dbl and click.zone == 'dspbtn') then
        local col = dsp_target(); if col then edit.fx_remove(col.track, hover.dspbtn.kid.i); model.invalidate(); vim.msg = 'removed ' .. hover.dspbtn.kid.name .. ' from ' .. hover.dspbtn.f.name end
      elseif hover.dspbtn.what == 'kbypass' and hover.dspbtn.kid then
        local col = dsp_target(); if col then edit.fx_bypass(col.track, hover.dspbtn.kid.i); model.invalidate() end end
      click = { t = now2, zone = 'dspbtn' }
    elseif hover.dsprouter then
      -- router (7 окт): щелчок — вкл / выкл в DSP FX, Shift+щелчок — большой роутер
      if gfx.mouse_cap & 8 == 8 then ctx.router_big() else ctx.dsp_big() end
      click = { t = now2, zone = 'dsprouter' }
    elseif hover.dsptarget then
      ctx.set_focus('dsp'); ctx.dsp_toggle_target(hover.dsptarget == 'take')
      click = { t = now2, zone = 'dsptarget' }
    elseif hover.dspeq then
      -- точка полосы ReaEQ (7 окт): протяжка — частота (x) и усиление (y)
      ctx.set_focus('dsp'); dsp_sel.fx = hover.dspeq.fx
      ctx.eq_drag = { f = hover.dspeq.f, band = hover.dspeq.band, hit = hover.dspeq.hit, mx = gfx.mouse_x, my = gfx.mouse_y }
      click = { t = now2, zone = 'dspeq' }
    elseif hover.dspview then
      -- живой вид модуля (гранулятор): клик / протяжка = нативный параметр вида
      ctx.set_focus('dsp'); dsp_sel.fx = hover.dspview.fx
      dspview_drag = { f = hover.dspview.f, x = hover.dspview.x, w = hover.dspview.w }
      click = { t = now2, zone = 'dspview' }
    elseif hover.dspxy then
      -- XY-пэд (TG33 vector): точка едет за мышью, X и Y одним жестом
      ctx.set_focus('dsp'); dsp_sel.fx = hover.dspxy.fx
      dspxy_drag = { f = hover.dspxy.f, x = hover.dspxy.x, y = hover.dspxy.y, s = hover.dspxy.s }
      click = { t = now2, zone = 'dspxy' }
    elseif hover.dspab then
      -- ползунок A / B: тянуть (4 окт)
      ctx.set_focus('dsp')
      ctx.ab_drag = hover.dspab
      ctx.ab_morph(hover.dspab.f, (gfx.mouse_x - hover.dspab.x) / math.max(1, hover.dspab.w))
      click = { t = now2, zone = 'dspab' }
    elseif hover.dspwave then
      -- волна сэмплера (RS5K): ближайшая ручка start / end едет за мышью
      ctx.set_focus('dsp'); dsp_sel.fx = hover.dspwave.fx
      dspwave_drag = { f = hover.dspwave.f, edge = hover.dspwave.edge, x = hover.dspwave.x, w = hover.dspwave.w }
      click = { t = now2, zone = 'dspwave' }
    elseif hover.dsp then
      ctx.set_focus('dsp')
      dsp_sel.fx = hover.dsp.fx; if hover.dsp.param then dsp_sel.param = hover.dsp.param end
      if not hover.dsp.param then dsp_drag = { fx = hover.dsp.fx, f = hover.dsp.f, x0 = gfx.mouse_x, y0 = gfx.mouse_y, active = false } end
      local col = dsp_target()
      if hover.dsp.param and col and dbl and click.zone == 'dsp' and click.param == hover.dsp.param and click.fx == hover.dsp.fx then
        -- двойной клик по параметру (7 окт): сброс к значению по умолчанию
        local p = hover.dsp.f.params[hover.dsp.param]
        local v = p and edit.fx_param_default(col.track, p.fx or hover.dsp.f.i, p.i)
        local _, s2 = '', ''
        if v then _, s2 = model.fxapi(col.track).GetFormattedParamValue(col.track, p.fx or hover.dsp.f.i, p.i, '') end
        vim.msg = p and (v and (p.name .. ': default ' .. (s2 or '')) or (p.name .. ': no default found')) or ''
        click = { t = now2, zone = 'dspreset' }
        goto dsp_click_done
      end
      if hover.dsp.param and col then
        local p = hover.dsp.f.params[hover.dsp.param]
        if p and p.kind == 'toggle' then
          edit.fx_param(col.track, p.fx or hover.dsp.f.i, p.i, model.fxapi(col.track).GetParamNormalized(col.track, p.fx or hover.dsp.f.i, p.i) >= 0.5 and 0 or 1)
        elseif p and hover.dsp.steplist and hover.dsp.onwidget then
          -- выпадашка значений (5 окт): до 35 — меню у мыши, больше — поиск
          local labs = ctx.step_labels(hover.dsp.f, p) or {}
          local fx, tr, n = p.fx or hover.dsp.f.i, col.track, p.nsteps
          local cur = math.floor(model.fxapi(tr).GetParamNormalized(tr, fx, p.i) * (n - 1) + 0.5)
          local function setk(k) edit.fx_param(tr, fx, p.i, k / math.max(1, n - 1)) end
          if n <= 35 then
            local KEYS, list = '123456789abcdefghijklmnopqrstuvwxyz', {}
            for k = 0, n - 1 do list[#list + 1] = { key = KEYS:sub(k + 1, k + 1), label = (labs[k + 1] or tostring(k)) .. (k == cur and '  *' or ''), fn = function() setk(k) end } end
            vim.open_hydra({ title = p.name, items = list })
            state.popup_at = { kind = 'xy', x = gfx.mouse_x, y = gfx.mouse_y + 4 }
          else
            local list = {}
            for k = 0, n - 1 do list[#list + 1] = { label = labs[k + 1] or tostring(k), data = k } end
            vim.open_picker(p.name, list, function(it) setk(it.data) end)
          end
        elseif p and hover.dsp.onwidget then edit.fx_param(col.track, p.fx or hover.dsp.f.i, p.i, hover.dsp.sv) end
      elseif dbl and click.zone == 'dsp' and col then
        edit.fx_show(col.track, hover.dsp.f.i)
      end
      click = { t = now2, zone = 'dsp', param = hover.dsp.param, fx = hover.dsp.fx }
      ::dsp_click_done::
    elseif hover.ctrl == 'bpm' then
      if dbl and click.zone == 'bpm' then bpm_menu = nil; state.bpm_edit = ''
      else bpm_menu = bpm_menu and nil or { sel = 1 } end
      click = { t = now2, zone = 'bpm' }
    elseif hover.ctrl then
      if hover.ctrl ~= 'beats' then state.ctrl_sel = hover.ctrl end     -- курсор клавиатуры — на нажатую ячейку
      ctrl_action(hover.ctrl, 0)
      click = { t = now2, zone = 'ctrl' }
    elseif hover.scopes_on then
      ctx.toggle_scopes(true); click = { t = now2, zone = 'scopes_on' }
    elseif hover.scope then
      for i, f in ipairs(L.flat) do if f.col == hover.scope then vim.cur.fi = i; break end end
      ctx.set_focus('top')
      click = { t = now2, zone = 'scope' }
    elseif hover.pool and hover.pool.auto then
      ctx.set_focus('inst'); ctx.auto_select()
      click = { t = now2, zone = 'poolauto' }
    elseif hover.pool then
      ctx.set_focus('inst')
      state.prev_by_mouse = true
      pool_select(hover.pool.i)
      state.prev_by_mouse = nil
      -- двойной клик (5 окт, правка): инструмент остаётся на своём месте, фокус —
      -- в модуль сэмпла (вкладка item). Вставка на трек — Enter / insert
      if dbl and click.zone == 'pool' and click.row == hover.pool.i then
        draw.lib_drag = nil
        state.top = true; state.toptab = 'sample'; ctx.set_focus('top'); vim.msg = 'item: ' .. ((cur_col() and cur_col().pool[hover.pool.i] or {}).name or '')
      else draw.lib_drag = { i = hover.pool.i, x0 = gfx.mouse_x, y0 = gfx.mouse_y } end   -- протяжка — перестановка
      click = { t = now2, zone = 'pool', row = hover.pool.i }
    elseif hover.btn and hover.btn.what == 'auto' then
      -- trim (3 окт): клик — fzf по параметрам трека и его FX, Shift — огибающие в трекере, ПКМ — панель params
      -- меню — под кнопкой; повторный клик по ней закрывает (3 окт)
      if gfx.mouse_cap & 8 == 8 then ctx.toggle_track_envs(hover.btn.col)
      elseif vim.picker and vim.picker.trim == hover.btn.col.guid then vim.picker = nil
      else ctx.automation_picker(hover.btn.col, true) end
      click = { t = now2, zone = 'btn' }
    elseif hover.btn then
      local tr, what = hover.btn.col.track, hover.btn.what
      edit.run('track ' .. what, function()
        if what == 'monitor' then reaper.SetMediaTrackInfo_Value(tr, 'I_RECMON', (math.floor(reaper.GetMediaTrackInfo_Value(tr, 'I_RECMON')) + 1) % 3)
        elseif what == 'mute' then reaper.SetMediaTrackInfo_Value(tr, 'B_MUTE', reaper.GetMediaTrackInfo_Value(tr, 'B_MUTE') == 1 and 0 or 1)
        elseif what == 'solo' then reaper.SetMediaTrackInfo_Value(tr, 'I_SOLO', reaper.GetMediaTrackInfo_Value(tr, 'I_SOLO') > 0 and 0 or 1)
        else reaper.SetMediaTrackInfo_Value(tr, 'I_RECARM', reaper.GetMediaTrackInfo_Value(tr, 'I_RECARM') == 1 and 0 or 1) end
      end)
      click = { t = now2, zone = 'btn' }
    elseif hover.header_env then
      local ok, e = pcall(context_menu, hover)
      if not ok then vim.msg = tostring(e):match('[^\n]*$') end
      click = { t = now2, zone = 'envhead' }
    elseif hover.header_col then
      reaper.SetOnlyTrackSelected(hover.header_col.track)
      -- двойной клик по имени трека — переименовать (строка :tname с текущим именем)
      if dbl and click.zone == 'header' and click.guid == hover.header_col.guid and gfx.mouse_y < L.header_y + L.rh then
        ctx.rename_track_prompt(hover.header_col)
      end
      click = { t = now2, zone = 'header', guid = hover.header_col.guid }
    elseif hover.seam then
      -- стык лупа: длина периода, Option — растяжение (playrate)
      local s = hover.seam
      local d = { kind = s.kind, k = s.k, opt = gfx.mouse_cap & 16 == 16, y0 = gfx.mouse_y, active = false, x0 = s.x0, w = s.w }
      if s.kind == 'item' then
        local it = s.item
        local tk = reaper.GetActiveTake(it)
        if tk then
          d.item = it; d.pos = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
          d.rate = reaper.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE'); d.offs = reaper.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS')
          local src = reaper.GetMediaItemTake_Source(tk)
          if reaper.TakeIsMIDI(tk) then
            local slen, is_qn = reaper.GetMediaSourceLength(src)
            local q0 = reaper.TimeMap2_timeToQN(0, d.pos)
            d.slen = is_qn and (reaper.TimeMap2_QNToTime(0, q0 + slen) - d.pos) or slen
          else d.slen = model.src_period(src) end
          seam_drag = d
        end
      else
        d.env, d.idx, d.r0, d.per, d.first = s.env, s.idx, s.r0, s.per, s.first
        d.pq = reaper.GetSetAutomationItemInfo(s.env, s.idx, 'D_POOL_QNLEN', 0, false)
        d.rate = reaper.GetSetAutomationItemInfo(s.env, s.idx, 'D_PLAYRATE', 0, false)
        d.o = (d.per - (d.first % d.per)) % d.per
        seam_drag = d
      end
      click = { t = now2, zone = 'seam' }
    elseif hover.rownum then
      -- номера шагов: протяжка — time selection, клик без протяжки — снять её
      ts_drag = { row = hover.rownum, active = false, y0 = gfx.mouse_y }
      click = { t = now2, zone = 'rownum' }
    elseif hover.envpt then
      -- точка огибающей: тянуть в любом режиме (по строкам и по значению), один undo
      local e, row = hover.envpt.e, hover.envpt.row
      local t0, t1 = edit.row_time(row, state.lpb, 0), edit.row_time(row + 1, state.lpb, 0)
      -- 6 окт: точка под automation item — его пула (видимый проход)
      local ai = -1
      for _, a in ipairs(e.ais or {}) do if t0 >= a.pos - 1e-9 and t0 < a.pos + a.len then ai = a.idx end end
      local idx = reaper.GetEnvelopePointByTimeEx(e.env, ai, t1 - 1e-6)
      local ok, pt_t = false, nil
      if idx and idx >= 0 then ok, pt_t = reaper.GetEnvelopePointEx(e.env, ai, idx) end
      if ok and pt_t >= t0 - 1e-6 then
        -- значение — от x мыши по дорожке колонки, запомненной на старте:
        -- раньше бралось из hover и залипало, когда мышь уходила с колонки
        pt_drag = { e = e, ai = ai, idx = idx, t0 = pt_t, y0 = gfx.mouse_y, x0 = gfx.mouse_x, active = false,
                    bx = hover.envpt.bx, bw = hover.envpt.bw }
        if hover.fi then vim.cur.fi, vim.cur.row, vim.cur.field = hover.fi, row, 1 end
      end
      click = { t = now2, zone = 'envpt' }
    elseif hover.aiedge then
      -- automation item: ручка слева — сдвиг, край сверху — начало, снизу — длина (как в REAPER)
      ctx.set_focus('tracker')
      local a = hover.aiedge
      local grab = 0
      if a.edge == 'move' and hover.row then grab = edit.row_time(hover.row.row, state.lpb, 0) - a.pos end
      ai_drag = { env = a.e.env, idx = a.idx, edge = a.edge, pos0 = a.pos, len0 = a.len, grab = grab, y0 = gfx.mouse_y, active = false, name = a.e.name }
      -- one click focus (6 окт): выделить item (как в REAPER) и открыть его в modulation
      if state.oneclick then
        for k = 0, reaper.CountAutomationItems(a.e.env) - 1 do reaper.GetSetAutomationItemInfo(a.e.env, k, 'D_UISEL', k == a.idx and 1 or 0, true) end
        reaper.UpdateArrange()
        for i, f in ipairs(L.flat) do if f.env and f.env.env == a.e.env then vim.cur.fi = i end end
        if hover.row then vim.cur.row = hover.row.row end
        ctx.show_element(vim.cur.fi, vim.cur.row)
        model.invalidate()
      end
      if gfx.mouse_cap & 16 == 16 and a.edge ~= 'move' then ai_drag.rate0 = reaper.GetSetAutomationItemInfo(a.e.env, a.idx, 'D_PLAYRATE', 0, false) end
      click = { t = now2, zone = 'aiedge' }
    elseif hover.itemedge and hover.itemedge.edge ~= 'move' and gfx.mouse_cap & 8 ~= 8 then
      -- край рамки item: trim как в аранжировке
      ctx.set_focus('tracker')
      item_drag = { item = hover.itemedge.item, edge = hover.itemedge.edge, col = hover.itemedge.col, y0 = gfx.mouse_y, active = false, name = hover.itemedge.col.name }
      if gfx.mouse_cap & 16 == 16 then
        -- Option на краю — растяжение (playrate), обычная протяжка — trim
        local tk = reaper.GetActiveTake(hover.itemedge.item)
        if tk then item_drag.stretch = { len0 = reaper.GetMediaItemInfo_Value(hover.itemedge.item, 'D_LENGTH'), rate0 = reaper.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE') } end
      end
      click = { t = now2, zone = 'itemedge' }
    elseif hover.row and hover.fi then
      ctx.set_focus('tracker')
      if false then
        -- (2 окт: Option+протяжка теперь переносит событие / блок — ниже, ev_drag)
        local pos = reaper.GetMediaItemInfo_Value(hover.itemedge.item, 'D_POSITION')
        item_drag = { item = hover.itemedge.item, edge = 'move', col = hover.itemedge.col, y0 = gfx.mouse_y, active = false, grab = edit.row_time(hover.row.row, state.lpb, 0) - pos }
        click = { t = now2, zone = 'itemmove' }
      elseif gfx.mouse_cap & 8 == 8 then
        -- Shift+клик: блок от якоря (курсор до клика) до клика; Shift+протяжка
        -- тянет второй угол (как в Renoise)
        if vim.mode ~= 'visual' and vim.mode ~= 'vline' then
          vim.anchor = { fi = vim.cur.fi, row = vim.cur.row }; vim.mode = 'visual'
        end
        vim.cur.fi, vim.cur.row = hover.fi, hover.row.row
        body_drag = true
        click = { t = now2, zone = 'bodysel', fi = hover.fi, row = hover.row.row }
      else
        if state.oneclick then ctx.show_element(hover.fi, hover.row.row) end   -- one click focus (6 окт)
        -- протяжка события (2 окт): в любом режиме; внутри VISUAL-блока — весь блок.
        -- Блок запоминается ДО того, как клик сдвинет курсор (угол блока)
        local vis_heads, vis_o
        if (vim.mode == 'visual' or vim.mode == 'vline') and gfx.mouse_cap & 16 == 16 then
          local f0, f1, r0, r1 = vim.visual_range()
          if hover.fi >= f0 and hover.fi <= f1 and hover.row.row >= r0 and hover.row.row <= r1 then
            vis_heads = vim.heads_in(f0, f1, r0, r1); vis_o = { fi = f0, row = r0, f1 = f1, r1 = r1, anchor = vim.anchor and { fi = vim.anchor.fi, row = vim.anchor.row }, cur = { fi = vim.cur.fi, row = vim.cur.row } }
          end
        end
        if not vis_heads then
          -- обычный клик выходит из VISUAL (как в Vim); протяжка начнёт новый блок
          if (vim.mode == 'visual' or vim.mode == 'vline') and gfx.mouse_cap & 16 ~= 16 then vim.mode = 'normal' end
          vim.cur.fi, vim.cur.row = hover.fi, hover.row.row
        end
        if hover.field then vim.cur.field = hover.field; vim.cur.sub = hover.fsub end
        local head = cell
        local opt = gfx.mouse_cap & 16 == 16
        -- протяжка без модификатора — выделение блока (NORMAL и INSERT), 2 окт
        if not opt and not dbl then sel_drag = { fi = hover.fi, row = hover.row.row, x0 = gfx.mouse_x, y0 = gfx.mouse_y, active = false } end
        if head and not dbl and opt then
          local hr = head.row0 or hover.row.row
          local heads = (vis_heads and #vis_heads > 0) and vis_heads or vim.heads_in(hover.fi, hover.fi, hr, hr)
          if #heads > 0 then
            ev_drag = { heads = heads, fi0 = hover.fi, row0 = hover.row.row, ofi = vis_o and vis_o.fi or hover.fi, orow = vis_o and vis_o.row or hr,
                        vis = vis_o, x0 = gfx.mouse_x, y0 = gfx.mouse_y, active = false }
          end
        end
        -- клик по событию выделяет item в REAPER (штатные действия и
        -- mouse modifiers работают с ним); двойной — свойства item / MIDI-редактор
        if head and head.item then
          select_item_in_reaper(head.item)
          if dbl and click.zone == 'body' and click.fi == hover.fi and click.row == hover.row.row then
            if head.kind == 'audio' then ctx.item_props(head.item, { kind = 'xy', x = gfx.mouse_x, y = gfx.mouse_y + 4 })   -- своя гидра (5 окт)
            else reaper.Main_OnCommand(40153, 0) end
          end
        end
        click = { t = now2, zone = 'body', fi = hover.fi, row = hover.row.row }
      end
    end
  end
  -- протяжка item: край → trim, тело (Option) → сдвиг; привязка к строке,
  -- Cmd — без привязки; один undo-блок на жест
  if item_drag then
    if gfx.mouse_cap & 1 == 1 then
      if not item_drag.active and math.abs(gfx.mouse_y - item_drag.y0) > 2 then item_drag.active = true; edit.item_drag_begin('item ' .. item_drag.edge) end
      if item_drag.active and rows[1] then
        local rowf = rows[1].row + (gfx.mouse_y - L.body_y) / L.rh
        if gfx.mouse_cap & 4 ~= 4 then rowf = math.floor(rowf + 0.5) end      -- привязка к строке
        rowf = math.max(0, rowf)
        local t = reaper.TimeMap2_QNToTime(0, rowf / state.lpb)
        if item_drag.edge == 'move' then t = t - (item_drag.grab or 0) end
        edit.item_drag_to(item_drag.item, item_drag.edge, t, edit.row_time(1, state.lpb, 0) / 4, item_drag.stretch)
        state.status = ('%s %s %s → row %.2f (Cmd: free)'):format(item_drag.stretch and 'stretch' or 'trim', item_drag.edge, item_drag.col.name, rowf)
        model.invalidate()
      end
    else
      -- растяжка или подрезка начала меняют звук копии → уникальная (3 окт)
      if item_drag.active and (item_drag.stretch or item_drag.edge == 'start') then edit.note_modified(item_drag.item) end
      if item_drag.active then edit.item_drag_end() end
      item_drag = nil
    end
  elseif hover.itemedge and hover.itemedge.edge ~= 'move' then
    state.status = ('item %s %s: drag = trim, Option+drag = stretch (playrate), Cmd = no snap; inside: drag = select, Option+drag = move'):format(hover.itemedge.col.name, hover.itemedge.edge)
  end
  -- точка огибающей мышью: строка (Cmd — свободно) и значение от x
  if pt_drag then
    if gfx.mouse_cap & 1 == 1 then
      if not pt_drag.active and (math.abs(gfx.mouse_y - pt_drag.y0) > 2 or math.abs(gfx.mouse_x - pt_drag.x0) > 2) then
        pt_drag.active = true; edit.item_drag_begin('envelope point')
      end
      if pt_drag.active and rows[1] then
        local rowf = rows[1].row + (gfx.mouse_y - L.body_y) / L.rh
        if gfx.mouse_cap & 4 ~= 4 then rowf = math.floor(rowf + 1e-6) end
        local t = reaper.TimeMap2_QNToTime(0, math.max(0, rowf) / state.lpb)
        local e = pt_drag.e
        local raw
        if pt_drag.bx and (pt_drag.bw or 0) > 1 then
          raw = e.min + math.max(0, math.min(1, (gfx.mouse_x - pt_drag.bx) / (pt_drag.bw - 1))) * (e.max - e.min)
        else _, _, raw = reaper.GetEnvelopePointEx(e.env, pt_drag.ai, pt_drag.idx) end
        reaper.SetEnvelopePointEx(e.env, pt_drag.ai, pt_drag.idx, t, raw, nil, nil, nil, true)
        pt_drag.moved = true
        state.status = ('%s point → row %.2f, value %.3f (Cmd: free)'):format(e.name or 'envelope', rowf, raw or 0)
        model.invalidate()
      end
    else
      if pt_drag.active then reaper.Envelope_SortPointsEx(pt_drag.e.env, pt_drag.ai); edit.item_drag_end() end
      pt_drag = nil
    end
  elseif hover.envpt then
    state.status = 'envelope point - drag: move it (rows, value by x), any mode; Cmd: free'
  end
  -- automation item мышью: привязка к строке (Cmd — свободно), один undo на жест
  if ai_drag then
    if gfx.mouse_cap & 1 == 1 then
      if not ai_drag.active and math.abs(gfx.mouse_y - ai_drag.y0) > 2 then ai_drag.active = true; edit.item_drag_begin('automation item ' .. ai_drag.edge) end
      if ai_drag.active and rows[1] then
        local rowf = rows[1].row + (gfx.mouse_y - L.body_y) / L.rh
        if gfx.mouse_cap & 4 ~= 4 then rowf = math.floor(rowf + 0.5) end
        local t = reaper.TimeMap2_QNToTime(0, math.max(0, rowf) / state.lpb)
        local env, k = ai_drag.env, ai_drag.idx
        local minlen = edit.row_time(1, state.lpb, 0) / 4
        if ai_drag.edge == 'move' then
          reaper.GetSetAutomationItemInfo(env, k, 'D_POSITION', math.max(0, t - ai_drag.grab), true)
        elseif ai_drag.edge == 'end' then
          local nl = math.max(minlen, t - ai_drag.pos0)
          reaper.GetSetAutomationItemInfo(env, k, 'D_LENGTH', nl, true)
          if ai_drag.rate0 then reaper.GetSetAutomationItemInfo(env, k, 'D_PLAYRATE', ai_drag.rate0 * ai_drag.len0 / nl, true) end   -- Option: растяжение
        else
          local fin = ai_drag.pos0 + ai_drag.len0
          t = math.max(0, math.min(t, fin - minlen))
          local rate = reaper.GetSetAutomationItemInfo(env, k, 'D_PLAYRATE', 0, false) or 1
          local offs0 = ai_drag.offs0 or reaper.GetSetAutomationItemInfo(env, k, 'D_STARTOFFS', 0, false) or 0
          ai_drag.offs0 = offs0
          reaper.GetSetAutomationItemInfo(env, k, 'D_POSITION', t, true)
          reaper.GetSetAutomationItemInfo(env, k, 'D_LENGTH', fin - t, true)
          reaper.GetSetAutomationItemInfo(env, k, 'D_STARTOFFS', math.max(0, offs0 + (t - ai_drag.pos0) * rate), true)
        end
        state.status = ('automation item %s %s → row %.2f (Cmd: free)'):format(ai_drag.name or '', ai_drag.edge, rowf)
        model.invalidate()
      end
    else
      if ai_drag.active then edit.item_drag_end() end
      ai_drag = nil
    end
  elseif hover.aiedge then
    state.status = ('automation item %s%s: %s'):format(hover.aiedge.e.name or '', hover.aiedge.label and (' / ' .. hover.aiedge.label) or '', ({ move = 'drag the left strip to move it', start = 'drag the top edge: start (trim)', ['end'] = 'drag the bottom edge: length (loops repeat)' })[hover.aiedge.edge])
  end
  -- стык лупа мышью: item — на отпускании (правка секции через чанк), automation item — сразу
  if seam_drag then
    local d = seam_drag
    if gfx.mouse_cap & 1 == 1 then
      if not d.active and math.abs(gfx.mouse_y - d.y0) > 2 then
        d.active = true
        if d.kind == 'ai' then edit.item_drag_begin('automation item loop') end
      end
      if d.active and rows[1] then
        local rowf = rows[1].row + (gfx.mouse_y - L.body_y) / L.rh
        if gfx.mouse_cap & 4 ~= 4 then rowf = math.floor(rowf + 0.5) end
        d.rowf = rowf
        d.guide = { x = d.x0, w = d.w, y = L.body_y + math.floor((rowf - rows[1].row) * L.rh) }
        if d.kind == 'ai' then
          local T = math.max(0.25, rowf - d.r0)
          local per_new = (T + d.o) / d.k
          if d.opt then
            reaper.GetSetAutomationItemInfo(d.env, d.idx, 'D_PLAYRATE', math.max(0.05, math.min(20, d.pq * state.lpb / per_new)), true)
          else
            reaper.GetSetAutomationItemInfo(d.env, d.idx, 'D_POOL_QNLEN', math.max(1 / state.lpb, per_new / state.lpb * d.rate), true)
          end
          model.invalidate()
        end
        state.status = ('loop %s: seam %d → row %.2f (%s; Cmd: free)'):format(d.kind == 'ai' and 'automation item' or 'item', d.k, rowf, d.opt and 'stretch' or 'length')
      end
    else
      if d.active and d.kind == 'ai' then edit.item_drag_end() end
      if d.active and d.kind == 'item' and d.rowf then
        local T = math.max(0.01, edit.row_time(0, state.lpb, 0) + reaper.TimeMap2_QNToTime(0, d.rowf / state.lpb) - d.pos)
        local ok
        if d.opt then ok = edit.loop_period(d.item, 'rate', (d.k * d.slen - d.offs) / T)
        else ok = edit.loop_period(d.item, 'len', (T * d.rate + d.offs) / d.k) end
        vim.msg = ok and (d.opt and 'loop stretched' or 'loop length changed') or ('loop: ' .. tostring(edit.loop_err or 'failed'))
      end
      seam_drag = nil
    end
  elseif hover.seam then
    state.status = 'loop seam: drag = loop length, Option+drag = stretch (playrate), Cmd = no snap'
  end
  -- time selection по номерам шагов (строки целиком, как выделение в REAPER)
  if ts_drag then
    if gfx.mouse_cap & 1 == 1 then
      if not ts_drag.active and math.abs(gfx.mouse_y - ts_drag.y0) > 2 then ts_drag.active = true end
      if ts_drag.active and rows[1] then
        local r = math.floor(rows[1].row + (gfx.mouse_y - L.body_y) / L.rh)
        local a, b = math.min(ts_drag.row, r), math.max(ts_drag.row, r) + 1
        reaper.GetSet_LoopTimeRange(true, false, edit.row_time(math.max(0, a), state.lpb, 0), edit.row_time(math.max(1, b), state.lpb, 0), false)
        state.status = ('time selection: rows %04d - %04d (%d)'):format(a, b - 1, b - a)
      end
    else
      if not ts_drag.active then reaper.GetSet_LoopTimeRange(true, false, 0, 0, false); vim.msg = 'time selection cleared' end
      ts_drag = nil
    end
  elseif hover.rownum then
    -- на time selection (5 окт): как снять — Shift+Esc
    local ta, tb = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local ra, rb = model.row_of_time(ta, state.lpb), model.row_of_time(tb, state.lpb)
    if tb - ta > 1e-6 and hover.rownum >= ra and hover.rownum < rb then
      state.status = 'time selection: Shift+Esc removes it (anywhere), a click on the step numbers too; drag = a new one'
    else state.status = 'step numbers: drag = REAPER time selection, click = clear it (Shift+Esc anywhere)' end
  end
  -- протяжка без модификатора: VISUAL-блок от точки нажатия до мыши
  if sel_drag then
    if gfx.mouse_cap & 1 == 1 then
      if not sel_drag.active and (math.abs(gfx.mouse_y - sel_drag.y0) > 3 or math.abs(gfx.mouse_x - sel_drag.x0) > 3) then
        sel_drag.active = true
        vim.anchor = { fi = sel_drag.fi, row = sel_drag.row }; vim.mode = 'visual'
      end
      if sel_drag.active and hover.row and hover.fi and not hover.row.clip then vim.cur.fi, vim.cur.row = hover.fi, hover.row.row end
    else sel_drag = nil end
  end
  -- перенос события / блока мышью (Option): на отпускании — один undo (взять, удалить, вставить)
  if ev_drag then
    if gfx.mouse_cap & 1 == 1 then
      if not ev_drag.active and (math.abs(gfx.mouse_y - ev_drag.y0) > 3 or math.abs(gfx.mouse_x - ev_drag.x0) > 3) then ev_drag.active = true end
      if ev_drag.active and hover.row and hover.fi then
        ev_drag.drow = hover.row.row - ev_drag.row0
        ev_drag.dfi = hover.fi - ev_drag.fi0
        local f = L.flat[ev_drag.ofi + ev_drag.dfi]
        state.status = ('move %d event(s) → row %04d, %s (release to drop)'):format(#ev_drag.heads, math.max(0, ev_drag.orow + ev_drag.drow), f and f.col and f.col.name or '?')
      end
    else
      local d = ev_drag
      ev_drag = nil
      if d.active and ((d.drow or 0) ~= 0 or (d.dfi or 0) ~= 0) then
        local drow, dfi = d.drow or 0, d.dfi or 0
        if d.orow + drow < 0 then drow = -d.orow end
        local function targets(k)
          local f = L.flat[d.ofi + dfi + k]
          if not f or not f.col or f.env or f.folded then return nil end
          local lane = f.lane or f.col.lanes[1]
          return { track = f.col.track, lane_idx = f.col.fixed and lane and lane.idx or nil }
        end
        local ok, err = pcall(edit.run, 'move events', function()
          local reg = edit.yank(d.heads, state.lpb, d.orow, d.ofi)
          edit.delete(d.heads, state.lpb)
          edit.paste(reg, state.lpb, d.orow + drow, targets)
        end)
        if not ok then vim.msg = 'move failed: ' .. tostring(err):match('[^\n]*$')
        else
          vim.msg = ('moved %d event(s) %+d rows, %+d columns (Cmd+Z undo)'):format(#d.heads, drow, dfi)
          if d.vis then
            if d.vis.anchor then vim.anchor = { fi = d.vis.anchor.fi + dfi, row = d.vis.anchor.row + drow } end
            vim.cur.fi, vim.cur.row = d.vis.cur.fi + dfi, d.vis.cur.row + drow
          else vim.cur.fi, vim.cur.row = d.fi0 + dfi, d.row0 + drow end
        end
        model.invalidate()
      end
    end
  end
  -- Shift+протяжка: второй угол блока следует за мышью
  if body_drag then
    if gfx.mouse_cap & 1 == 1 then
      if hover.row and hover.fi and vim.mode == 'visual' then vim.cur.fi, vim.cur.row = hover.fi, hover.row.row end
    else body_drag = nil end
  end
  -- слайдер полосы матрицы модуляции: живьём без undo, на отпускании — одна правка
  if mm_drag then
    local c = MMX.COLS[mm_drag.ci]
    local col = cur_col()
    local fr = math.max(0, math.min(1, (gfx.mouse_x - mm_drag.x) / math.max(1, mm_drag.w)))
    local val = c.min + fr * (c.max - c.min)
    if gfx.mouse_cap & 1 == 1 then
      if col then reaper.TrackFX_SetNamedConfigParm(col.track, mm_drag.r.fx, ('param.%d.%s'):format(mm_drag.r.param, c.key), tostring(val)) end
      mm_drag.val = val
      state.status = ('%s %s = %.3f'):format(mm_drag.r.pname, c.head, val)
    else
      if mm_drag.val then ctx.mod_field(mm_drag.r, c.key, mm_drag.val) end
      mm_drag = nil
    end
  end
  -- слайдер генератора кривых: протяжка по горизонтали
  if lfo_drag then
    if gfx.mouse_cap & 1 == 1 then LG.set_frac(lfo_drag.field, (gfx.mouse_x - lfo_drag.x) / math.max(1, lfo_drag.w))
    else lfo_drag = nil end
  end
  -- протяжка по живому виду модуля DSP (гранулятор: Position)
  if ctx.eq_drag then
    if gfx.mouse_cap & 1 == 1 then
      local d = ctx.eq_drag
      if gfx.mouse_x ~= d.mx or gfx.mouse_y ~= d.my then
        d.mx, d.my = gfx.mouse_x, gfx.mouse_y
        local h = d.hit
        -- полоса по номеру (7 окт): p.band / p.bk от модели; старый модуль — по подписям
        local LB = { { '1 lo f', '1 lo g' }, { '2 f', '2 g' }, { '3 f', '3 g' }, { '4 hi f', '4 hi g' } }
        local lf, lg = (LB[d.band] or {})[1], (LB[d.band] or {})[2]
        local pf, pg
        for _, p in ipairs(d.f.params or {}) do
          if p.band == d.band then if p.bk == 'f' then pf = p elseif p.bk == 'g' then pg = p end
          elseif not p.band then if p.name == lf then pf = p elseif p.name == lg then pg = p end end
        end
        local fq = 20 * 1000 ^ math.max(0, math.min(1, (gfx.mouse_x - h.x - 1) / math.max(1, h.w - 3)))
        local db = math.max(-18, math.min(18, (h.cy - gfx.mouse_y) / h.sc))
        if pf then ctx.fx_set_display(d.f, pf, fq) end
        if pg then ctx.fx_set_display(d.f, pg, db) end
        state.status = ('%s band %d: %s Hz  %+.1f dB'):format(d.f.name, d.band, fq >= 1000 and ('%.2fk'):format(fq / 1000) or ('%d'):format(math.floor(fq + 0.5)), db)
      end
    else ctx.eq_drag = nil end
  end
  if dspview_drag then
    if gfx.mouse_cap & 1 == 1 then
      local d = dspview_drag
      local col = dsp_target()
      local p = d.f.params[d.f.view_p or 0]
      if col and p then
        local fr = math.max(0, math.min(1, (gfx.mouse_x - d.x) / math.max(1, d.w - 1)))
        edit.fx_param(col.track, d.f.i, p.i, fr)
        state.status = ('%s: %s %.1f%%'):format(d.f.name, p.name, fr * 100)
      end
    else dspview_drag = nil end
  end
  -- XY-пэд модуля DSP
  if dspxy_drag then
    if gfx.mouse_cap & 1 == 1 then
      local d = dspxy_drag
      local col = dsp_target()
      local px, py = d.f.params[d.f.xy_x], d.f.params[d.f.xy_y]
      if col and px and py then
        local nx = math.max(0, math.min(1, (gfx.mouse_x - d.x) / math.max(1, d.s - 1)))
        local ny = 1 - math.max(0, math.min(1, (gfx.mouse_y - d.y) / math.max(1, d.s - 1)))
        edit.fx_param(col.track, d.f.i, px.i, nx); edit.fx_param(col.track, d.f.i, py.i, ny)
        state.status = ('%s: x %d  y %d'):format(d.f.name, math.floor(nx * 127 + 0.5), math.floor(ny * 127 + 0.5))
      end
    else dspxy_drag = nil end
  end
  -- ручки start / end на волне сэмплера (RS5K)
  if ctx.ab_drag then
    if gfx.mouse_cap & 1 == 1 then ctx.ab_morph(ctx.ab_drag.f, (gfx.mouse_x - ctx.ab_drag.x) / math.max(1, ctx.ab_drag.w))
    else ctx.ab_drag = nil end
  end
  if dspwave_drag then
    if gfx.mouse_cap & 1 == 1 then
      local d = dspwave_drag
      local col = dsp_target()
      local f = d.f
      local A = col and model.fxapi(col.track)
      local pa, pb = f.params[f.wave_a or 0], f.params[f.wave_b or 0]
      if A and pa and pb then
        local fr = math.max(0, math.min(1, (gfx.mouse_x - d.x) / math.max(1, d.w - 1)))
        local na, nb = A.GetParamNormalized(col.track, f.i, pa.i), A.GetParamNormalized(col.track, f.i, pb.i)
        if d.edge == 'a' then edit.fx_param(col.track, f.i, pa.i, math.min(fr, nb - 0.001))
        else edit.fx_param(col.track, f.i, pb.i, math.max(fr, na + 0.001)) end
        state.status = ('%s: %s %.1f%%'):format(f.name, d.edge == 'a' and 'start' or 'end', fr * 100)
      end
    else dspwave_drag = nil end
  end
  -- протяжка по слайдеру DSP
  if hover.dsp and hover.dsp.param and not hover.dsp.steplist and not (vim.hydra or vim.picker) and gfx.mouse_cap & 1 == 1 and click.zone == 'dsp' and not (dsp_drag and dsp_drag.active) and not fxb_drag then
    local col = dsp_target()
    local p = col and hover.dsp.f.params[hover.dsp.param]
    if p and p.kind ~= 'toggle' and hover.dsp.sv then edit.fx_param(col.track, p.fx or hover.dsp.f.i, p.i, hover.dsp.sv) end
  end
  -- огибающая мышью, как в аранжировке: клик/протяжка — точка со значением
  -- от x, правый клик — удалить точку строки, колесо — ±1/64
  if hover.env and hover.row and not ai_drag and not hover.aiedge and not pt_drag and click.zone ~= 'envpt' then
    local down = gfx.mouse_cap & 1 == 1
    if down then
      -- клик по автоматизации открывает вкладку modulation (фокус остаётся тут) — 2 окт
      if not env_drag.key then state.top = true; state.toptab = 'modulation' end
      if hover.field == 2 then
        -- поле формы: только курсор туда (правка — буквами в INSERT, ^A ^X)
        if hover.fi then vim.cur.fi, vim.cur.row, vim.cur.field = hover.fi, hover.row.row, 2 end
      elseif vim.mode ~= 'insert' then
        -- NORMAL / VISUAL: клик только ставит курсор на строку огибающей (2 окт);
        -- точку от мыши пишет только INSERT
        if hover.fi then vim.cur.fi, vim.cur.row, vim.cur.field = hover.fi, hover.row.row, 1 end
      else
        local key = tostring(hover.env.env) .. ':' .. hover.row.row .. ':' .. math.floor(hover.envx * 255)
        if env_drag.key ~= key then
          env_drag.key = key
          ctx.env_set(hover.env, hover.row.row, hover.envx)
          if hover.fi then vim.cur.fi, vim.cur.row, vim.cur.field = hover.fi, hover.row.row, 1 end
        end
      end
    else env_drag.key = nil end
    if U.rclick then ctx.env_del(hover.env, hover.row.row) end
  elseif U.rclick and hover.ctrl == 'q_keys' then
    state.kc_scale = 0; vim.msg = 'keycaster: default size'
  elseif U.rclick and hover.dspcomp then
    ctx.gain_comp(hover.dspcomp, 'remove')
  elseif U.rclick and hover.btn and hover.btn.what == 'auto' then
    ctx.open_params(hover.btn.col)
  elseif U.rclick then
    local ok, e = pcall(context_menu, hover)
    if not ok then vim.msg = tostring(e):match('[^\n]*$') end
  end
  -- перетаскивание из браузера: кнопка держится и ушла > 6 px → призрак;
  -- отпустили над колонкой трека → drop (файл → item, .rpp → сабпроект)
  if B.drag then
    local down = gfx.mouse_cap & 1 == 1
    if down then
      if not B.drag.active and (math.abs(gfx.mouse_x - B.drag.x0) > 6 or math.abs(gfx.mouse_y - B.drag.y0) > 6) then B.drag.active = true end
      if B.drag.active then
        if hover.fi and hover.row then state.status = ('drop %s → %s @ %04d'):format(B.drag.e.name, hover.col and hover.col.name or '', hover.row.row)
        else state.status = 'drag ' .. B.drag.e.name .. ' - drop on a track column' end
      end
    else
      local bd = B.drag; B.drag = nil       -- снять ДО действия (6 окт): ошибка не повторит бросок каждый кадр
      if bd.active and hover.garden and hover.garden.ox and not bd.e.trk and not bd.e.rgn and not bd.e.mark and not bd.e.dir then
        -- файл на клетку Orca: в библиотеку трека курсора, затем — инструментом в поле
        local c = cur_col()
        local it = c and edit.depot_add(bd.e.pm and bd.e.path or B.full(bd.e), c.track)
        if it then orca_pending = { item = it, ox = hover.garden.ox, oy = hover.garden.oy, t = reaper.time_precise() }; model.invalidate() end
      elseif bd.active and hover.dspwave and not bd.e.trk and not bd.e.rgn and not bd.e.mark and not bd.e.dir then
        ctx.rs5k_file(hover.dspwave.f, bd.e.pm and bd.e.path or B.full(bd.e))   -- файл на волну RS5K — его сэмпл
      elseif bd.active and hover.pool and not bd.e.trk and not bd.e.rgn and not bd.e.mark then
        ctx.add_to_depot(bd.e.pm and bd.e.path or B.full(bd.e))       -- бросок на инструменты — в библиотеку трека
      elseif bd.active and hover.matrix and hover.matrix.ri and hover.matrix.ci and not bd.e.trk and not bd.e.rgn and not bd.e.mark and not bd.e.dir then
        ctx.ss_drop(hover.matrix.ri, hover.matrix.ci, bd.e.pm and bd.e.path or B.full(bd.e))   -- на ячейку матрицы — клипом в слот (6 окт)
      elseif bd.active and hover.sess and not bd.e.trk and not bd.e.rgn and not bd.e.mark and not bd.e.dir then
        ctx.ss_drop(hover.sess.ri, hover.sess.ci, bd.e.pm and bd.e.path or B.full(bd.e))   -- session: файл / карточка pm — клипом в слот (6 окт)
      elseif bd.active and hover.fi and hover.row then
        local e = bd.e
        if e.trk then ctx.drop_track(e, B.pmproj and B.pmproj.e)
        elseif e.rgn and B.pmproj then ctx.drop_region_to(hover.fi, hover.row.row, B.pmproj.e.path, e)
        elseif not e.mark then ctx.drop_to(hover.fi, hover.row.row, e.pm and e.path or B.full(e)) end
      end
      B.drag = nil
    end
  end
  -- сэмпл-модуль: протяжка выделения / вынос выделения на колонку трекера
  -- край зоны слайса: тянется, на отпускании правит item-инструмент (один undo)
  if SL.zone_drag then
    local zd, wv = SL.zone_drag, SL.wave
    if gfx.mouse_cap & 1 == 1 then
      if wv and wv.w > 0 then
        local raw = math.max(0, math.min(wv.len, SL.x_to_t(gfx.mouse_x)))   -- по окну зума
        if zd.edge == 'move' then
          -- полоса внизу: вся зона едет, длина та же; начало липнет (snap)
          local w = zd.b0 - zd.a0
          local na = SL.snap_t(math.max(0, math.min(wv.len - w, zd.a0 + (raw - zd.grab))))
          zd.a, zd.b = na, na + w
        elseif zd.edge == 'la' or zd.edge == 'lb' then
          local t = SL.snap_t(raw)
          if zd.edge == 'la' then zd.la = math.min(t, zd.lb - 0.005) else zd.lb = math.max(t, zd.la + 0.005) end
        else
          local t = SL.snap_t(raw)
          if zd.edge == 'a' then zd.a = math.min(t, zd.b - 0.005) else zd.b = math.max(t, zd.a + 0.005) end
        end
        if zd.clip and (zd.edge == 'la' or zd.edge == 'lb') then state.status = ('clip loop: %.3f - %.3fs (%.3fs) - release to apply'):format(zd.la, zd.lb, zd.lb - zd.la)
        else state.status = ('%s: %.3f - %.3fs of %s (%.3fs) - release to apply'):format(zd.clip and 'clip' or 'slice', zd.a, zd.b, zd.p.name or 'sample', zd.b - zd.a) end
      end
    else
      -- простой клик без сдвига — не правка (без undo-точки)
      if zd.clip then
        -- клип (6 окт): начало / конец → offset / длина item клипа; L → jf_cliploop
        local moved = math.abs(zd.a - zd.a0) > 1e-6 or math.abs(zd.b - zd.b0) > 1e-6
        local lmoved = math.abs((zd.la or 0) - (zd.la0 or 0)) > 1e-6 or math.abs((zd.lb or 0) - (zd.lb0 or 0)) > 1e-6
        if (moved or lmoved) and reaper.ValidatePtr(zd.item, 'MediaItem*') then
          edit.run('clip markers', function()
            local tk = reaper.GetActiveTake(zd.item)
            if moved and tk then
              reaper.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', zd.eo + zd.a * zd.er)
              reaper.SetMediaItemInfo_Value(zd.item, 'D_LENGTH', (zd.b - zd.a) * zd.er / ((zd.cr and zd.cr > 0) and zd.cr or 1))
            end
            if lmoved then reaper.GetSetMediaItemInfo_String(zd.item, 'P_EXT:jf_cliploop', ('%.6f;%.6f'):format(zd.eo + zd.la * zd.er, zd.eo + zd.lb * zd.er), true) end
          end)
          model.invalidate()
          vim.msg = lmoved and ('clip loop %.3f - %.3fs (applies at the next launch)'):format(zd.la, zd.lb) or ('clip %.3f - %.3fs'):format(zd.a, zd.b)
        end
      elseif math.abs(zd.a - zd.a0) > 1e-6 or math.abs(zd.b - zd.b0) > 1e-6 then
        if zd.marks then
          -- слайс без нот: границы k и k+1 нарезки сэмпла (5 окт)
          local sl = {}
          for i, t in ipairs(zd.p.slices or {}) do sl[i] = t end
          local k = zd.marks
          local lo = (sl[k - 1] or -1) + 0.002
          local hi = (sl[k + 2] or (zd.p.len + 1)) - 0.002
          sl[k] = math.max(lo, zd.a)
          if sl[k + 1] then sl[k + 1] = math.min(hi, zd.b) end
          edit.set_slices(zd.p.item, sl)
          if SL.entry and SL.entry.item == zd.p.item then SL.slices = sl end
          model.invalidate()
          vim.msg = ('slice S%02X moved'):format(k)
        else ctx.slice_bounds(zd) end
      end
      SL.zone_drag = nil
    end
  end
  if SL.drag then
    if gfx.mouse_cap & 1 == 1 then
      SL.mouse_move(hover.sample and hover.sample.frac)
      if SL.drag.kind == 'out' and SL.drag.active then
        state.status = (hover.fi and hover.row) and ('drop selection → %s @ %04d'):format(hover.col and hover.col.name or '', hover.row.row) or 'drag selection - drop on a track (mother + slice in the row) or on the lib (mother + slice)'
      end
    else
      local d = SL.mouse_up()
      -- 5 окт: бросок — мать целиком в lib + выделение слайсом; на lib — в любое
      -- место модуля, на трек — ещё и слайс в строку
      local ir = draw.module_rects and draw.module_rects.inst
      local on_lib = hover.pool or (ir and gfx.mouse_x >= ir[1] and gfx.mouse_x < ir[1] + ir[3] and gfx.mouse_y >= ir[2] and gfx.mouse_y < ir[2] + ir[4])
      if d and d.kind == 'out' and d.active and on_lib then
        local a, b = SL.span()
        if a then ctx.drop_span_slice(nil, nil, SL.entry, a, b) end
      elseif d and d.kind == 'out' and d.active and hover.fi and hover.row then
        local a, b = SL.span()
        if a then ctx.drop_span_slice(hover.fi, hover.row.row, SL.entry, a, b) end
      end
    end
  end
  -- DSP: перетаскивание блока за заголовок → перестановка FX в цепи трека
  -- протяжка слайдера шапки: значение каждый кадр без undo, точка undo на отпускании
  -- перестановка в lib протяжкой (3 окт): ушли > 6 px — линия вставки (рисует
  -- lib, D.lib_drop), отпустили — исходник встаёт туда
  if draw.lib_drag then
    local d = draw.lib_drag
    if gfx.mouse_cap & 1 == 1 then
      if not d.active and math.abs(gfx.mouse_y - d.y0) > 6 then d.active = true end
      if d.active then state.status = 'lib: drop to place the sample here (numbers follow the order)' end
    else
      if d.active and draw.lib_drop then ctx.lib_move(d.i, draw.lib_drop.before) end
      draw.lib_drag, draw.lib_drop = nil, nil
    end
  end
  if draw.send_drag then
    local d = draw.send_drag
    local tr = d.col.track
    if gfx.mouse_cap & 1 == 1 and reaper.ValidatePtr(tr, 'MediaTrack*') then
      local fr = math.max(0, math.min(1, (gfx.mouse_x - d.x0) / math.max(1, d.w)))
      local db = fr * 72 - 60
      reaper.SetTrackSendInfo_Value(tr, 0, d.idx, 'D_VOL', db <= -59.9 and 0 or 10 ^ (db / 20))
      d.moved = true
    else
      if d.moved then edit.track_undo('send volume') end
      draw.send_drag = nil
    end
  end
  if draw.hsb_drag then
    local d = draw.hsb_drag
    if gfx.mouse_cap & 1 == 1 then
      local b = d.b0 + math.floor((gfx.mouse_x - d.x0) / math.max(1, d.w) * d.n + 0.5)
      b = math.max(0, math.min(L.hs_n - 1, b))
      state.hscroll = L.hs_list[b + 1] or state.hscroll
    else draw.hsb_drag = nil end
  end
  if trs_drag then
    if gfx.mouse_cap & 1 == 1 then
      local frac = trs_drag.vert and math.max(0, math.min(1, (trs_drag.y0 - gfx.mouse_y) / math.max(1, trs_drag.h)))   -- фейдер микшера — вертикально (8 окт)
        or math.max(0, math.min(1, (gfx.mouse_x - trs_drag.x0) / math.max(1, trs_drag.w)))
      local v = trs_drag.vert and 10 ^ (draw.fader_db(frac) / 20) or trs_value(trs_drag.what, frac)   -- вертикальный — своя шкала
      edit.track_value(trs_drag.col.track, TRS_KEY[trs_drag.what], v)
      trs_drag.v = v
    else
      if trs_drag.v then edit.track_undo('track ' .. trs_drag.what); model.invalidate() end
      trs_drag = nil
    end
  end
  if dsp_drag then
    if gfx.mouse_cap & 1 == 1 then
      if not dsp_drag.active and (math.abs(gfx.mouse_x - dsp_drag.x0) > 6 or math.abs(gfx.mouse_y - dsp_drag.y0) > 6) then dsp_drag.active = true end
      if dsp_drag.active then
        local g = hover.dsp_gap
        state.status = hover.dsp_into and ('move ' .. dsp_drag.f.name .. ' into the container, ' .. (hover.dsp_into_par == 1 and 'parallel (right half)' or 'serial (left half)'))
          or (g and ('move ' .. dsp_drag.f.name .. ' → slot ' .. (g + 1) .. ' (amber line)') or ('move ' .. dsp_drag.f.name .. ' - drop between blocks or into a container'))
      end
    else
      local dd = dsp_drag; dsp_drag = nil       -- снять ДО действия (6 окт): ошибка не повторит перенос
      local g, s = hover.dsp_gap, dd.fx
      local col = dd.active and hover.dsp_into and dsp_target()
      local cf = col and (col.fx or {})[hover.dsp_into]
      if cf then
        -- в контейнер (6 окт): копия внутрь + удаление оригинала
        if edit.fx_move_into(col.track, dd.f.i, cf.i, hover.dsp_into_par) then vim.msg = dd.f.name .. ' → container ' .. cf.name .. (hover.dsp_into_par == 1 and ', parallel' or '')
        else vim.msg = 'could not move ' .. dd.f.name .. ' into the container' end
        g = nil
      end
      if dd.active and g and g ~= s and g ~= s - 1 then
        local col = dsp_target()
        local fxs = col and col.fx or {}
        local dst = (g < s - 1) and fxs[g + 1] or fxs[g]
        if col and dst then
          edit.fx_move(col.track, dd.f.i, dst.i)
          dsp_sel.fx = (g < s - 1) and (g + 1) or g
          vim.msg = 'fx moved: ' .. dd.f.name
        end
      end
      dsp_drag = nil
    end
  end
  -- FX из браузера эффектов → на DSP-панель (место — янтарная черта)
  if fxb_drag then
    if gfx.mouse_cap & 1 == 1 then
      if not fxb_drag.active and (math.abs(gfx.mouse_x - fxb_drag.x0) > 6 or math.abs(gfx.mouse_y - fxb_drag.y0) > 6) then fxb_drag.active = true end
      if fxb_drag.active then
        state.status = hover.dsp_into and ('insert ' .. FB.short(fxb_drag.it.label) .. ' into the container, ' .. (hover.dsp_into_par == 1 and 'parallel (right half)' or 'serial (left half)'))
          or (hover.dsp_gap and ('insert ' .. FB.short(fxb_drag.it.label) .. ' at slot ' .. (hover.dsp_gap + 1))
          or (hover.dbig and ('drop ' .. FB.short(fxb_drag.it.label) .. (hover.dbnode and (' after the row of ' .. hover.dbnode.name .. ' (Shift - parallel to it)') or ' at the end of the chain')))
          or ('drag ' .. FB.short(fxb_drag.it.label) .. ' onto the DSP panel'))
      end
    else
      -- состояние броска снимается ДО действия (6 окт): ошибка в действии
      -- иначе оставляла бросок «висеть», и он повторялся каждый кадр (34 Air4)
      local drop = fxb_drag; fxb_drag = nil
      local col = drop.active and hover.dsp_into and dsp_target()
      local cf = col and (col.fx or {})[hover.dsp_into]
      if cf then
        if edit.fx_add_into(col.track, cf.i, drop.it.data, hover.dsp_into_par) then
          FB.push_recent(drop.it); ctx.fxb_save()
          vim.msg = '+ ' .. FB.short(drop.it.label) .. ' → container ' .. cf.name .. (hover.dsp_into_par == 1 and ', parallel' or '')
        else vim.msg = 'could not add into the container' end
      elseif drop.active and hover.dsp_gap then ctx.fxb_add(drop.it, hover.dsp_gap)
      elseif drop.active and hover.dbig then
        -- роутер (7 окт): на узел — после его ряда (Shift — параллельно узлу), мимо узлов — в конец
        local t = dsp_target()
        if t then
          local n = hover.dbnode
          local par = n and (gfx.mouse_cap & 8 == 8) or false
          local parent, pos, pv = MX.DB.insert_point(n, par)
          if not n then local root = ctx.db_tree(); pos = root and #root.kids or 0 end
          if parent and not parent.parent.root then vim.msg = 'router: adding inside a nested container is not supported yet'
          elseif edit.fx_insert(t.track, parent and parent.k or nil, pos, drop.it.data, pv) then
            FB.push_recent(drop.it); ctx.fxb_save(); ctx.db_cache = nil
            vim.msg = '+ ' .. FB.short(drop.it.label) .. (par and ' (parallel)' or '')
          end
        end
      end
      fxb_drag = nil
    end
  end
  -- ретро: вынос выделения — слот инструментов (библиотека) или строка колонки трека
  if retro.out then
    if gfx.mouse_cap & 1 == 1 then
      if not retro.out.active and (math.abs(gfx.mouse_x - retro.out.x0) > 6 or math.abs(gfx.mouse_y - retro.out.y0) > 6) then retro.out.active = true end
      if retro.out.active then
        state.status = hover.pool and 'drop: capture into the track library (instrument slot)'
          or ((hover.fi and hover.row) and ('drop: capture at row %04d'):format(hover.row.row) or 'drag the retro selection onto an instrument slot or a track row')
      end
    else
      local ro = retro.out; retro.out = nil      -- снять ДО действия (6 окт)
      if ro.active then
        if hover.pool then retro_put('depot')
        elseif hover.fi and hover.row then vim.cur.fi, vim.cur.row = hover.fi, hover.row.row; retro_put('cursor', true) end
      elseif ro.at then
        -- клик внутри выделения без протяжки — новое начало, как раньше
        retro.sel.a = ro.at; retro.sel.b = math.min(1, ro.at + 0.05)
      end
      retro.out = nil
    end
  end
  -- заметки: перенос / размер окошка мышью; отпустили — запомнить
  if ctx.nt_drag then
    local d = ctx.nt_drag
    if gfx.mouse_cap & 1 == 1 then
      local dx, dy = gfx.mouse_x - d.mx, gfx.mouse_y - d.my
      if d.mode == 'drag' then state.notes_win = { d.r[1] + dx, d.r[2] + dy, d.r[3], d.r[4] }
      else state.notes_win = { d.r[1], d.r[2], math.max(L.cw * 20, d.r[3] + dx), math.max(4 * L.rh, d.r[4] + dy) } end
    else
      ctx.nt_drag = nil
      local w = state.notes_win
      if w then reaper.SetExtState(EXT, 'noteswin', ('%d %d %d %d'):format(w[1], w[2], w[3], w[4]), true) end
    end
  end
  -- ретро: протяжка выделения по волне
  if retro.drag then
    if gfx.mouse_cap & 1 == 1 then
      if hover.retro then retro.sel.b = hover.retro end
    else
      retro.drag = nil
      if retro.sel.b < retro.sel.a then retro.sel.a, retro.sel.b = retro.sel.b, retro.sel.a end
      if retro.sel.b - retro.sel.a < 0.002 then retro.sel.b = math.min(1, retro.sel.a + 0.05) end
    end
  end
  -- автопревью браузера: курсор перешёл на другую строку → слушаем её
  if state.side and B.auto and B.cur ~= browse_last then
    browse_last = B.cur
    local pth = B.preview_path(B.entries[B.cur])
    if pth then
      ctx.preview_file(pth)          -- целиком (2 окт)
    end
  end

  if gfx.mouse_wheel ~= 0 and hover and hover.dspeq then   -- ReaEQ: колесо на виде — ширина ближайшей полосы
    local d = hover.dspeq
    local LQ = { '1 lo q', '2 q', '3 q', '4 hi q' }
    local col = dsp_target()
    for _, p in ipairs(d.f.params or {}) do
      if ((p.band == d.band and p.bk == 'q') or (not p.band and p.name == LQ[d.band])) and col then
        local fx = p.fx or d.f.i
        local v = model.fxapi(col.track).GetParamNormalized(col.track, fx, p.i)
        edit.fx_param(col.track, fx, p.i, v + (gfx.mouse_wheel > 0 and 0.02 or -0.02))
      end
    end
    gfx.mouse_wheel = 0
  end
  if gfx.mouse_wheel ~= 0 and hover and hover.dbparam then
    local hp, t = hover.dbparam, dsp_target()
    if t then local A = model.fxapi(t.track); edit.fx_param(t.track, hp.addr, hp.i, A.GetParamNormalized(t.track, hp.addr, hp.i) + (gfx.mouse_wheel > 0 and 0.01 or -0.01)) end
    gfx.mouse_wheel = 0
  end
  if gfx.mouse_wheel ~= 0 and hover and hover.dbig then MX.DB.wheel(gfx.mouse_wheel > 0 and 60 or -60, MX.DB.view_w or gfx.w, MX.DB.total or 0); gfx.mouse_wheel = 0 end
  if gfx.mouse_wheel ~= 0 and hover and hover.slices ~= nil then
    -- колесо над модулем слайсов (4 окт): листать список
    SPROP.slice_scroll = math.max(0, (SPROP.slice_scroll or 0) + (gfx.mouse_wheel > 0 and -3 or 3))
    gfx.mouse_wheel = 0
  end
  -- протяжка слайдера свойств сэмпла (5 окт): пока кнопка держится; правка —
  -- только когда мышь сдвинулась (не undo-шаг на каждый кадр)
  if SPROP.drag then
    if gfx.mouse_cap & 1 == 1 then
      if gfx.mouse_x ~= SPROP.drag.lx then
        SPROP.drag.lx = gfx.mouse_x
        local e = cur_col() and (cur_col().pool or {})[vim.inst]
        if e then ctx.sp_set_frac(e, SPROP.drag.k, (gfx.mouse_x - SPROP.drag.x) / math.max(1, SPROP.drag.w)) end
      end
    else SPROP.drag = nil end
  end
  if gfx.mouse_wheel ~= 0 and SPROP.hover and state.top and state.toptab == 'sample' then
    local e = cur_col() and (cur_col().pool or {})[vim.inst]
    SPROP.sel = SPROP.hover.row or SPROP.sel
    if e and SPROP.hover.k ~= 'fx' and SPROP.hover.k ~= 'norm' then ctx.sp_adjust(e, SPROP.hover.k, gfx.mouse_wheel > 0 and 1 or -1) end
    gfx.mouse_wheel = 0
  end
  if gfx.mouse_wheel ~= 0 and hover.matrix and (hover.matrix.btn == 'mkstart' or hover.matrix.btn == 'mkend') then
    ctx.seq_marker_nudge(hover.matrix.btn == 'mkstart' and 'start' or 'end', gfx.mouse_wheel > 0 and 1 or -1)
    gfx.mouse_wheel = 0
  end
  -- колесо над матрицей (5 окт, без фокуса, как в REAPER): колесо — слоты,
  -- гориз. колесо / Shift — колонки, Cmd — плавный зум высоты, Option — ширины
  if (gfx.mouse_wheel ~= 0 or (gfx.mouse_hwheel or 0) ~= 0) and hover.matrix and hover.matrix.inside and not OPT.active and not (vim.hydra or vim.picker) then
    local wv, wh = gfx.mouse_wheel, gfx.mouse_hwheel or 0
    local m = ctx.mods()
    local zv, zh = ctx.zoom_axes(wv, wh)
    if zv then
      if zv ~= 0 then MX.set_zoom(MX.vz * 2 ^ (zv / 960), nil) end
      if zh ~= 0 then MX.set_zoom(nil, MX.hz * 2 ^ (zh / 960)) end
    else
      if m.shift and wh == 0 then wh, wv = -wv, 0 end
      MX.wacc_v = (MX.wacc_v or 0) - wv / 120
      MX.wacc_h = (MX.wacc_h or 0) + wh / 120
      local dv = MX.wacc_v >= 0 and math.floor(MX.wacc_v) or math.ceil(MX.wacc_v)
      local dh = MX.wacc_h >= 0 and math.floor(MX.wacc_h) or math.ceil(MX.wacc_h)
      MX.wacc_v, MX.wacc_h = MX.wacc_v - dv, MX.wacc_h - dh
      if dv ~= 0 then ctx.vbar_scroll('matrix', (MX.scroll or 0) + dv) end
      if dh ~= 0 then MX.hs = math.max(0, (MX.hs or 0) + dh) end
    end
    gfx.mouse_wheel, gfx.mouse_hwheel = 0, 0
  end
  if gfx.mouse_wheel ~= 0 and hover.fxb then
    FB.cur = math.max(1, math.min(#FB.results(), FB.cur + (gfx.mouse_wheel > 0 and -3 or 3)))
    gfx.mouse_wheel = 0
  end
  if gfx.mouse_wheel ~= 0 and hover.browser == 'pvvol' then
    local v = PV.vol; local db = v > 1e-6 and 20 * math.log(v, 10) or -40
    ctx.preview_set_vol(10 ^ (math.max(-40, math.min(6, db + (gfx.mouse_wheel > 0 and 1 or -1))) / 20))
    gfx.mouse_wheel = 0
  end
  if gfx.mouse_wheel ~= 0 and hover.trs then
    ctx.trs_nudge(hover.trs.col, hover.trs.what, gfx.mouse_wheel > 0 and 1 or -1)
    gfx.mouse_wheel = 0
  end
  if gfx.mouse_wheel ~= 0 and hover.garden and hover.garden.ri then
    GD.cur = { ri = hover.garden.ri, ci = hover.garden.ci }
    GD.key(gfx.mouse_wheel > 0 and 43 or 45, snap, seq)
    gfx.mouse_wheel = 0
  end
  if gfx.mouse_wheel ~= 0 and OPT.active then OPT.wheel(gfx.mouse_wheel > 0 and 1 or -1); gfx.mouse_wheel = 0 end
  if gfx.mouse_wheel ~= 0 and hover.rglen then
    ctx.region_len_step(gfx.mouse_wheel > 0 and 1 or -1)
    gfx.mouse_wheel = 0
  end
  -- волна во вкладке item (3 окт): колесо — зум у мыши, Shift / вбок — прокрутка
  if (gfx.mouse_wheel ~= 0 or (gfx.mouse_hwheel or 0) ~= 0) and hover.sample and hover.sample.wave and not hover.sample.vol then
    if (gfx.mouse_hwheel or 0) ~= 0 then SL.scroll(gfx.mouse_hwheel > 0 and 0.15 or -0.15)
    elseif gfx.mouse_cap & 8 == 8 then SL.scroll(gfx.mouse_wheel > 0 and -0.15 or 0.15)
    else SL.zoom(gfx.mouse_wheel > 0 and 0.7 or 1 / 0.7, SL.x_to_t(gfx.mouse_x)) end
    gfx.mouse_wheel, gfx.mouse_hwheel = 0, 0
  end
  if gfx.mouse_wheel ~= 0 and hover.sample and hover.sample.vol then
    SL.entry = SL.entry or hover.sample.e
    SL.vol_step(gfx.mouse_wheel > 0 and 1 or -1)
    gfx.mouse_wheel = 0
  end
  if gfx.mouse_wheel ~= 0 and lfo_hover and lfo_hover.field and state.top and state.toptab == 'modulation' then
    LG.sel = lfo_hover.field
    LG.adjust(LG.sel, (gfx.mouse_wheel > 0 and 1 or -1) * ((gfx.mouse_cap & 8 == 8) and 0.1 or 1))
    gfx.mouse_wheel = 0
  end
  if gfx.mouse_wheel ~= 0 and lfo_hover and lfo_hover.pane == 'params' and state.top and state.toptab == 'modulation' then
    MMX.PP.wheel(gfx.mouse_wheel > 0 and -3 or 3)
    gfx.mouse_wheel = 0
  end
  if gfx.mouse_wheel ~= 0 and hover.mm and hover.mm.row then
    MMX.row, MMX.col = hover.mm.row, hover.mm.col
    MMX.adjust(cur_col() and cur_col().mods or {}, (gfx.mouse_wheel > 0 and 1 or -1) * ((gfx.mouse_cap & 8 == 8) and 10 or 1))
    gfx.mouse_wheel = 0
  end
  -- горизонтальное колесо / трекпад (3 окт): прокрутка треков; Cmd — зум ширины
  -- (0 как у треков, 1 все компактно, 2 все полоской)
  -- зум трекера (5 окт): те же модификаторы, что у матрицы (ctx.zoom_axes) —
  -- вертикаль = LPB, горизонталь = ширина треков; трекпад копится до щелчка
  if (gfx.mouse_wheel ~= 0 or (gfx.mouse_hwheel or 0) ~= 0) and not hover.dsp and not hover.browser and not hover.fxb and not OPT.active then
    local zv, zh = ctx.zoom_axes(gfx.mouse_wheel, gfx.mouse_hwheel or 0)
    if zv then
      local nv, nh = ctx.zoom_steps('v', zv), ctx.zoom_steps('h', zh)
      if nv ~= 0 then ctrl_action('lpb', nv > 0 and 1 or -1) end
      if nh ~= 0 then
        -- 7 окт: по одному полю за шаг (уровни 0..MAXLVL), от полной ширины
        local cur = state.wzlevel or (3 + math.min(L.MAXFX or 4, state.fxcols or 0))
        local nl = cur + (nh > 0 and 1 or -1)                  -- nh > 0 — шире (как прежний зум)
        if nl > (L.MAXLVL or 10) then nl = nil else nl = math.max(0, nl) end   -- шире самого широкого — как у каждого трека
        state.wzlevel = nl
        reaper.SetExtState(EXT, 'wzlevel', nl and tostring(nl) or '', true)
        if not nl then vim.msg = 'width: as set per track'; nl = -1 end
        local NAMES = { [0] = 'strips', 'notes', 'note + vol', 'note + vol + delay' }
        if nl >= 0 then vim.msg = 'width: ' .. (NAMES[nl] or (nl <= 3 + (L.MAXFX or 4) and ('+ ' .. (nl - 3) .. ' fx column(s)') or ('+ ' .. (nl - 3 - (L.MAXFX or 4)) .. ' note column(s)'))) .. '  (automation shows when a track is wider than 50 chars)' end
      end
      gfx.mouse_wheel, gfx.mouse_hwheel = 0, 0
    end
  end
  if (gfx.mouse_hwheel or 0) ~= 0 then
    local d = gfx.mouse_hwheel > 0 and 1 or -1
    if false then
    elseif not hover.dsp and not hover.browser and not hover.fxb then
      local b = math.max(0, math.min(math.max(0, (L.hs_n or 1) - 1), (L.hs_before or 0) + d))
      state.hscroll = (L.hs_list and L.hs_list[b + 1]) or state.hscroll
    end
    gfx.mouse_hwheel = 0
  end
  if gfx.mouse_wheel ~= 0 then
    local step = gfx.mouse_wheel > 0 and -3 or 3
    if hover.ssbig then MX.SS.wheel(gfx.mouse_wheel, #seq)                        -- session: ряды сцен
    elseif hover.khelp_big and ctx.DOC then ctx.DOC.wheel(gfx.mouse_wheel)        -- справка F1: прокрутка
    elseif hover.dsp and hover.dsp.param then
      local col = dsp_target(); local p = col and hover.dsp.f.params[hover.dsp.param]
      if p then local id = p.fx or hover.dsp.f.i; edit.fx_param(col.track, id, p.i, model.fxapi(col.track).GetParamNormalized(col.track, id, p.i) + (step > 0 and -0.02 or 0.02)) end
    -- колесо над огибающей — только прокрутка (2 окт): значения правит ^A ^X / INSERT
    elseif hover.ctrl then ctrl_action(hover.ctrl, step > 0 and -1 or 1)
    elseif type(hover.browser) == 'number' and B.mode == 'pm' and B.grid and not B.pmproj and state.pmgrid then B.pm_scroll.v = math.max(0, B.pm_scroll.v + (step > 0 and 1 or -1)); B.pm_scroll.wheel = true
    elseif type(hover.browser) == 'number' then B.cur = math.max(1, math.min(#B.entries, B.cur + (step > 0 and 1 or -1)))
    elseif gfx.mouse_cap & 8 == 8 then
      state.hscroll = math.max(1, math.min(math.max(1, #snap.cols), state.hscroll + (step > 0 and 1 or -1)))
    else
      if state.fixed then vim.cur.row = math.max(0, vim.cur.row + step) else state.row0 = math.max(0, state.row0 + step) end
    end
    gfx.mouse_wheel = 0
  end

  -- снимок measure (8 окт): s — в ~/Pictures/screenshots, c — для Claude
  -- (файл jf_tracker_shot.png в ресурсах REAPER + отчёт в журнал debug);
  -- прямоугольник линейки, без неё — всё окно. Пиксели — из готового кадра
  -- (gfx.getpixel), PNG — своим кодером (без внешних программ)
  if ctx.shot_req then
    local req = ctx.shot_req; ctx.shot_req = nil
    MX.PNG = MX.PNG or dofile(DIR .. '/jf_tracker_png.lua')
    local x, y, w, h = 0, 0, gfx.w, gfx.h
    local M = ctx.meas
    if M and M.a and M.b then
      x, y = math.floor(math.min(M.a[1], M.b[1])), math.floor(math.min(M.a[2], M.b[2]))
      w, h = math.floor(math.abs(M.b[1] - M.a[1])) + 1, math.floor(math.abs(M.b[2] - M.a[2])) + 1
    end
    if w > 4 and h > 4 then
      local d0 = gfx.dest
      gfx.dest = tonumber(state.fps) and 1021 or -1
      local ok, rgb = pcall(MX.PNG.grab, x, y, w, h)
      gfx.dest = d0
      -- 8 окт: как системный снимок macOS — та же папка (screencapture location
      -- ~/Pictures/Screenshots) и то же имя «Screenshot 2026-10-08 at 9.30.23 AM»
      -- (час без нуля, перед AM — узкий неразрывный пробел U+202F) + _jftracker
      local hh = tonumber(os.date('%I'))
      local path = ('%s/Pictures/Screenshots/Screenshot %s at %d.%s\u{202F}%s_jftracker.png'):format(os.getenv('HOME') or '', os.date('%Y-%m-%d'), hh, os.date('%M.%S'), os.date('%p'))
      local fh = ok and io.open(path, 'wb')
      if fh then
        fh:write(MX.PNG.encode(w, h, rgb)); fh:close()
        local rep = ('shot %s %dx%d at %d,%d -> %s%s'):format(req, w, h, x, y, path, M and M.b and (' | ' .. (reaper.GetExtState(EXT, 'measure') or '')) or '')
        reaper.SetExtState(EXT, 'shot', rep, false)
        if ctx.dlog then ctx.dlog(rep) end
        -- 8 окт: dev notes (debug) — ссылка на снимок строкой под пунктом с
        -- курсором: Claude читает CHECK.md и открывает снимок этого пункта
        if state.debug and NT.kind == 'dev' and NT.owner then
          local l = math.max(1, math.min(#NT.lines, NT.l or 1))
          while NT.lines[l + 1] and NT.lines[l + 1]:match('^%s*!%[shot%]') do l = l + 1 end   -- несколько снимков — друг под другом
          table.insert(NT.lines, l + 1, '  ![shot](' .. path .. ')')
          NT.dirty = true; ctx.notes_save()
          vim.msg = vim.msg .. ' - linked under the dev note'
        end
        vim.msg = 'shot: ' .. path:match('[^/]+$') .. (' (%dx%d)'):format(w, h)
      else vim.msg = 'shot: cannot write ' .. path end
    end
  end
  draw.pmark('blit, gfx.update')
  if tonumber(state.fps) then
    -- буфер кадров — на экран (каждый тик, даже без перерисовки)
    gfx.dest = -1
    gfx.blit(1021, 1, 0, 0, 0, gfx.w, gfx.h, 0, 0, gfx.w, gfx.h)
  end
  U.end_frame()
  gfx.update()
  local t_4 = reaper.time_precise()
  prof.snap = prof.snap + (t_1 - t_0); prof.layout = prof.layout + (t_2 - t_1)
  prof.draw = prof.draw + (t_3 - t_2); prof.upd = prof.upd + (t_4 - t_3); prof.n = prof.n + 1
  if t_4 - t_0 > prof.max then prof.max = t_4 - t_0 end

  draw.pmark('keys, commands, polls')
  local c = gfx.getchar()
  ctx.frame_t, ctx.frame_t_prev = reaper.time_precise(), ctx.frame_t   -- время кадра: окно отпусканий клавиш (автоповтор)
  if c ~= 0 then idle.input_t = reaper.time_precise() end          -- ввод — выход из простоя
  -- клавиши из контекстной гидры (5 окт): по одной за кадр, как с клавиатуры
  if c <= 0 and #ctx.keyq > 0 then c = table.remove(ctx.keyq, 1) end
  if MX.mkedit and state.focus ~= 'matrix' then MX.mkedit = nil end      -- поле маркера: ушёл фокус — отмена
  -- autofocus (6 окт): курсор клавиатуры сменил ячейку — показать её модуль
  if state.autofocus and state.focus == 'tracker' and L and L.flat then
    local k = vim.cur.fi .. ':' .. vim.cur.row
    if ctx.af_last ~= k then ctx.af_last = k; ctx.show_element(vim.cur.fi, vim.cur.row) end
  end
  if SL.qpreview and not (OPT.active and OPT.compact and (OPT.compact.title or ''):match('^quantize')) then SL.qpreview = false end   -- панель закрыта — без превью
  local c_raw = c                                                  -- журнал клавиш (4 окт)
  -- живые тесты: ExtState jf_tracker/inject = «код#n» — клавиша как с клавиатуры
  if c <= 0 then
    local inj = reaper.GetExtState(EXT, 'inject')
    if inj ~= '' and inj ~= inject_last then
      inject_last = inj
      local code, cap = inj:match('^(%-?%d+),?(%d*)')
      code = tonumber(code)
      if code then c = code; inject_cap = tonumber(cap) end
    end
  end
  local quit = false
  if c == keys.f1 then if ctx.mods().shift then state.khelp_big = false; ctx.tutorial() else ctx.help_big() end; c = 0 end
  if c == keys.f11 then toggle_dock(); c = 0 end
  -- F2..F6 (5 окт, мышечная память трекеров): F2 — трекер ↔ item (из любой
  -- вкладки — в трекер); F3 — modulate, ещё раз — следующая вкладка по кругу;
  -- F4 midi, F5 scopes, F6 master — повтор той же клавиши возвращает в трекер
  do
    local FTAB = { [26162] = 'sample', [26163] = 'modulation', [26164] = 'midi', [26165] = 'scopes', [26166] = 'master' }
    local tab = FTAB[c]
    if tab and not vim.picker and vim.mode ~= 'cmd' and vim.mode ~= 'search' then
      local on_top = state.focus == 'top' and state.top
      local cur = state.toptab == 'retro' and 'retro' or state.toptab
      if c == 26162 and on_top then tab = nil                                  -- F2 из вкладки — в трекер
      elseif c == 26163 and on_top and cur ~= 'sample' then
        local T = ctx.top_tabs()
        local i = 1
        for k, t in ipairs(T) do if t == cur then i = k end end
        tab = T[i % #T + 1]
        if tab == 'sample' then tab = T[(i + 1) % #T + 1] end              -- круг F3 — без item (он на F2)
      elseif c ~= 26163 and on_top and cur == tab then tab = nil end        -- повтор — в трекер
      if tab then state.top = true; state.toptab = tab; ctx.set_focus('top'); vim.msg = 'tab: ' .. tab
      else ctx.set_focus('tracker'); vim.msg = 'tracker' end
      c = 0
    end
  end
  -- запись (5 окт): Ctrl+R / F12 — вкладка rec; Option+R — в трекер с курсора;
  -- Cmd+R — в инструмент (новый файл → lib); во время записи Esc — удалить
  -- тейк (с вопросом, опция), Space — сохранить, Enter — сохранить и курсор
  -- на начало записи. Ctrl+R больше не redo (redo — Cmd+Shift+Z, :redo)
  do
    local m = ctx.mods()
    if c > 0 and not vim.picker and not OPT.ask.active and vim.mode ~= 'cmd' and vim.mode ~= 'search' then
      local rec = reaper.GetPlayState() & 4 == 4
      if rec and state.rec_sess and (c == 27 or c == 32 or c == 13) then ctx.rec_stop(c); c = 0
      elseif c == 6697266 or (c == 18 and m.ctrl and not m.cmd) then
        state.top = true; state.toptab = 'retro'; ctx.set_focus('top'); vim.msg = 'tab: rec'; c = 0
      elseif c == 1962934446 or ((c == 114 or c == 18) and m.alt and not m.cmd) then ctx.rec_start('tracker'); c = 0
      elseif (c == 18 or c == 114) and m.cmd and not m.ctrl then ctx.rec_start('inst'); c = 0 end
    end
  end
  -- Cmd+Z — undo, Cmd+Shift+Z — redo: везде в трекере, в любом модуле (2 окт)
  do
    local m = ctx.mods()
    if m.cmd and not m.ctrl and (c == 26 or c == 122 or c == 90) then
      if m.shift or c == 90 then edit.redo(); vim.msg = 'redo' else edit.undo(); vim.msg = 'undo' end
      ctx.mx_refresh()
      c = 0
    end
  end
  -- \Q (5 окт): пик ждёт строку-цель — Enter переносит, Esc отменяет
  if ctx.qmove and state.focus == 'tracker' and (c == 13 or c == 27) and not vim.picker and not vim.hydra then
    local q = ctx.qmove; ctx.qmove = nil
    if c == 13 and reaper.ValidatePtr(q.item, 'MediaItem*') then
      local to = edit.row_time(vim.cur.row, state.lpb, 0) - q.pos
      ctx.peak_move(q.item, q.from, to)
      vim.msg = ('peak moved to row %04d'):format(vim.cur.row)
    else vim.msg = 'peak move cancelled' end
    c = 0
  end
  -- Enter на automation item под курсором (6 окт): открыть его в modulation и туда фокус
  if c == 13 and state.focus == 'tracker' and vim.mode == 'normal' and not vim.picker and not vim.hydra and not ctx.mods().cmd and not ctx.mods().alt and not ctx.mods().shift then
    local f = L and L.flat[vim.cur.fi]
    if f and f.env and ctx.ai_pick_at(vim.cur.fi, vim.cur.row) then
      local a = ctx.ai_list()[ctx.ai_sel]
      if a then ctx.ai_edit_open(a); c = 0 end
    end
  end
  -- Shift+Esc (5 окт): снять time selection REAPER — в любом модуле, вне ввода
  if c == 27 and ctx.mods().shift and not vim.picker and not vim.hydra and vim.mode ~= 'cmd' and vim.mode ~= 'search' and not OPT.active then
    reaper.GetSet_LoopTimeRange(true, false, 0, 0, false)
    vim.msg = 'time selection removed'
    c = 0
  end
  -- Cmd+G (5 окт): из любого модуля — инструмент automation (последняя строка lib)
  if (c == 103 or c == 71 or c == 7) and ctx.mods().cmd and not ctx.mods().ctrl and not vim.picker and not vim.hydra and vim.mode ~= 'cmd' and vim.mode ~= 'search' then
    ctx.auto_select(); c = 0
  end
  -- Cmd+Enter — фокус на инструменты (lib); Option+Enter — выбрать в lib
  -- инструмент ноты под курсором (5 окт). Только из трекера, NORMAL / INSERT
  do
    local m = ctx.mods()
    if c == 13 and state.focus == 'tracker' and (vim.mode == 'normal' or vim.mode == 'insert') and not vim.picker and not vim.hydra and (m.cmd or m.alt) and not m.ctrl then
      if ctx.ai_pick_at(vim.cur.fi, vim.cur.row) then
        if m.cmd then ctx.set_focus('slices') end
      elseif m.cmd then ctx.set_focus('inst'); vim.msg = 'instruments'
      else
        local f = L and L.flat[vim.cur.fi]
        local cell = f and f.sub and f.sub[vim.cur.row]
        if cell and cell.kind == 'cont' then cell = cell.of end
        local n = cell and cell.item and snap and snap.inst_of and snap.inst_of[cell.item]
        if n then pool_select(n); vim.msg = ('instrument %02d'):format(n) else vim.msg = 'no instrument under the cursor' end
      end
      c = 0
    end
  end
  c = keys.translate(c)
  -- Option+H / J / K / L (4 окт): символ зависит от раскладки (в русской Option+р —
  -- не «˙»), поэтому смотрим физическую клавишу; код — как от Option+h в US
  if c > 0 and reaper.JS_VKeys_GetState then
    local m = ctx.mods()
    if m.alt and not m.cmd and not m.ctrl then
      local OPT_HJKL = { [729] = true, [8710] = true, [730] = true, [172] = true }
      if not OPT_HJKL[c] then
        local ks = reaper.JS_VKeys_GetState(reaper.time_precise() - 0.5)
        for vk, code in pairs({ [72] = 729, [74] = 8710, [75] = 730, [76] = 172 }) do
          if ks and ks:byte(vk) ~= 0 then c = code; break end
        end
      end
    end
  end
  -- Option+1..9 (8 окт): выделить / снять трек N трекера в REAPER (нативное
  -- выделение) — цели прыжка фейдера f; символ от раскладки — физическая клавиша
  if c > 0 and reaper.JS_VKeys_GetState and vim.mode == 'normal' and not vim.piano and not vim.picker and not vim.hydra then
    local m = ctx.mods()
    if m.alt and not m.cmd and not m.ctrl and not m.shift then
      local ks = reaper.JS_VKeys_GetState(reaper.time_precise() - 0.5)
      for n = 1, 9 do
        if ks and ks:byte(48 + n) ~= 0 then
          local c2 = snap and snap.cols[n]
          if c2 and c2.track and reaper.ValidatePtr(c2.track, 'MediaTrack*') then
            reaper.SetTrackSelected(c2.track, not reaper.IsTrackSelected(c2.track)); model.invalidate()
            vim.msg = ('%s %s - f on a dB mark moves all selected faders'):format(c2.name or '', reaper.IsTrackSelected(c2.track) and 'selected' or 'unselected')
          end
          c = 0; break
        end
      end
    end
  end
  -- автоповтор (4 окт, «гост-нажатия»): нотная клавиша пришла снова, а
  -- отпускания с прошлого нажатия не было — это повтор macOS, не нота.
  -- Только там, где клавиши — ноты (INSERT, слой пианино, вкладка item);
  -- в NORMAL повтор w / u … нужен
  if c > 0 and keys.piano[c] and reaper.JS_VKeys_GetUp and not ctx.mods().cmd
     and (vim.mode == 'insert' or vim.piano or (state.focus == 'top' and state.toptab == 'sample')) then
    local nk, now = ctx.note_key_last, reaper.time_precise()
    local vk = string.char(c):upper():byte()
    -- 5 окт: быстрые нажатия терялись — отпускание случалось ДО обработки
    -- прошлого нажатия (медленный кадр) и не попадало в окно. Окно отпусканий
    -- начинается за длительность того кадра (+20 мс) до обработки
    local up = nk and nk.c == c and reaper.JS_VKeys_GetUp(nk.t - (nk.dt or 0) - 0.02)
    if up and up:byte(vk) == 0 and now - nk.t < 3 then
      c = 0
      ctx.key_repeats = (ctx.key_repeats or 0) + 1
    else ctx.note_key_last = { c = c, t = now, dt = math.min(0.25, now - (ctx.frame_t_prev or now)) } end
  end
  -- журнал клавиш (4 окт): сырой код → после раскладки и фильтров, режим, фокус;
  -- ExtState jf_tracker/keylog — последние 24 нажатия (диагностика «не работает»)
  -- keycaster (4 окт): имя клавиши словами (без значков), повтор той же — счётчик
  if c_raw > 0 and state.keycast then
    local m = ctx.mods()
    local NAMES = { [27] = 'esc', [13] = 'enter', [32] = 'space', [8] = 'bs', [9] = 'tab', [keys.up] = 'up', [keys.down] = 'down',
                    [keys.left] = 'left', [keys.right] = 'right', [6579564] = 'del', [1752132965] = 'home', [6647396] = 'end' }
    local nm = NAMES[c_raw]
    if not nm then
      -- 6 окт: Cmd+буква на macOS приходит тем же кодом 1..26, что Ctrl+буква —
      -- ctrl пишем, только если Ctrl зажат (или Cmd не зажат)
      if c_raw >= 1 and c_raw <= 26 then nm = ((m.cmd and not m.ctrl) and '' or 'ctrl+') .. string.char(c_raw + 96)
      elseif c_raw < 127 then nm = string.char(c_raw)
      elseif c_raw >= 26161 and c_raw <= 26169 then nm = 'f' .. (c_raw - 26160)
      elseif c_raw >= 0x75000000 and c_raw < 0x75110000 then nm = utf8.char(c_raw - 0x75000000)   -- кириллица и Option-символы: префикс 'u' (5 окт)
      elseif c_raw < 0x110000 and utf8 then nm = utf8.char(c_raw)
      else nm = '#' .. c_raw end
    end
    if m.cmd then nm = 'cmd+' .. nm end
    if m.alt and c_raw < 127 then nm = 'alt+' .. nm end
    ctx.kc = ctx.kc or {}
    local lastk = ctx.kc[#ctx.kc]
    local tnow = reaper.time_precise()
    if lastk and lastk.label == nm and tnow - lastk.t < 1.5 then lastk.n = lastk.n + 1; lastk.t = tnow
    else ctx.kc[#ctx.kc + 1] = { label = nm, t = tnow, n = 1 }; if #ctx.kc > 16 then table.remove(ctx.kc, 1) end end
  end
  if c_raw > 0 then
    ctx.keylog = ctx.keylog or {}
    table.insert(ctx.keylog, ('%s %d>%d %s/%s%s cap%d inj%s row%d fi%d%s'):format(os.date('%H:%M:%S'), c_raw, c, vim.mode, state.focus, (state.focus == 'top' and (':' .. tostring(state.toptab)) or ''), gfx.mouse_cap, tostring(inject_cap), vim.cur.row, vim.cur.fi, state.kslider and ' SLIDER' or ''))   -- 5 окт: моды и курсор для разбора «hjkl не работает»
    if #ctx.keylog > 24 then table.remove(ctx.keylog, 1) end
    reaper.SetExtState(EXT, 'keylog', table.concat(ctx.keylog, ' | '), false)
  end
  -- окно Options — модальное: все клавиши ему
  if c == 27 and PV.playing() then PV.stop() end              -- Esc глушит превью (и делает своё дальше)
  -- пока держится нота (Cmd+нота): j / ↓ — +1 шаг, Esc — отмена, прочее (автоповтор клавиши) — глотаем
  if state.hold and c ~= 0 then
    if c == 27 then
      vim.cur.row = state.hold.row; state.hold = nil; PV.stop(); vim.msg = 'hold cancelled'
    elseif c == ('j'):byte() or c == 10 or c == 1685026670 then state.hold.extra = state.hold.extra + 1 end
    c = 0
  end
  if OPT.ask.active and c ~= 0 then OPT.ask.key(c); c = 0 end
  if OPT.active and c ~= 0 then OPT.key(c); c = 0 end
  if state.bpm_edit and c ~= 0 then
    local ch = c < 256 and string.char(c) or ''
    if c == 27 then state.bpm_edit = nil
    elseif c == 13 then local v = tonumber(state.bpm_edit); state.bpm_edit = nil; if v then set_bpm(v) end
    elseif c == 8 then state.bpm_edit = state.bpm_edit:sub(1, -2)
    elseif ch:match('[%d%.]') and #state.bpm_edit < 7 then state.bpm_edit = state.bpm_edit .. ch end
    c = 0
  end
  if bpm_menu and c ~= 0 then
    local ch = c < 256 and string.char(c) or ''
    if c == 27 then bpm_menu = nil
    elseif ch == 'j' or c == keys.down then bpm_menu.sel = math.min(#BPM_LIST, bpm_menu.sel + 1)
    elseif ch == 'k' or c == keys.up then bpm_menu.sel = math.max(1, bpm_menu.sel - 1)
    elseif c == 13 then
      local it = BPM_LIST[bpm_menu.sel]
      if it[2] == 'item' then local b, why = bpm_from_item(); if b then set_bpm(b, why) else vim.msg = 'BPM: ' .. why end else set_bpm(it[2]) end
      bpm_menu = nil
    elseif ch:match('%d') then bpm_menu = nil; state.bpm_edit = ch      -- цифра — сразу ввод числа
    end
    c = 0
  end
  -- Tab / Shift-Tab — переход между модулями из ЛЮБОГО места (в INSERT,
  -- в слайсере, в браузере…); исключения: набор команды/поиска (там Tab —
  -- дополнение) и открытые fzf-пикер / hydra
  -- Ctrl + / Ctrl - : масштаб битмапа шагом 0.25 (просьба 1 окт); в TTF-режиме — кегль
  -- (на Mac Ctrl+минус может прийти кодом 31 = ^_ ; плюс — 61 '=' или 43 '+')
  -- масштаб шрифта: Ctrl или Cmd + = / - (5 окт: Cmd — как привычно на маке)
  if (c == 61 or c == 43 or c == 45 or c == 95 or c == 31) and (ctx.mods().ctrl or ctx.mods().cmd) and not vim.picker and vim.mode ~= 'cmd' and vim.mode ~= 'search' then
    local d = (c == 45 or c == 95 or c == 31) and -1 or 1
    if (state.font or 0) == 0 then
      -- шаги x1 → x1.5 → x2 → x3 (5 окт)
      local STEPS = { 1, 1.5, 2, 3 }
      local cur, i = tonumber(state.fontscale) or 2, 1
      for k, v in ipairs(STEPS) do if math.abs(v - cur) < 0.01 then i = k end end
      ctx.set_scale(STEPS[math.max(1, math.min(#STEPS, i + d))])
      vim.msg = ('bitmap x%s'):format(tostring(state.fontscale):gsub('%.0$', ''))
    else ctx.set_font(math.max(6, state.font + d)); vim.msg = 'font ' .. state.font end
    c = 0
  end
  ctx.click_guard = nil                                   -- клавиатура фокус переводит всегда
  if c == 27 and state.measure then state.measure = false; ctx.meas = nil; vim.msg = 'measure off'; c = 0 end   -- линейка: Esc — выкл (7 окт)
  if state.measure and c == ('s'):byte() then ctx.shot_req = 'file'; c = 0 end   -- 8 окт: снимок линейки (одна клавиша)
  local ctrl_note = vim.mode == 'insert' and state.focus == 'tracker' and ctx.mods().ctrl   -- Ctrl+i / Ctrl+y = нота, не Tab
  -- Tab (7 окт): Tab — трекер ↔ session, Shift+Tab — фокус назад, Option+Tab /
  -- Option+Shift+Tab — фокус по модулям по кругу (был Tab), Ctrl+Tab — вкладки
  -- верхнего дока (был Option+Tab)
  if (c == 9 or c == 25) and not ctrl_note and not HN.active and not vim.picker and not vim.hydra and vim.mode ~= 'cmd' and vim.mode ~= 'search' then
    local m = ctx.mods()
    local back = c == 25 or m.shift or (inject_cap or gfx.mouse_cap) & 8 == 8
    if m.ctrl then
      local TABS = ctx.top_tabs()
      local i = 1
      for k, t in ipairs(TABS) do if t == state.toptab or (t == 'sample' and state.toptab == 'retro') then i = k end end
      state.top = true
      state.toptab = TABS[(i - 1 + (back and -1 or 1)) % #TABS + 1]
      ctx.set_focus('top')
      vim.msg = 'tab: ' .. state.toptab
    elseif m.alt then
      ctx.toggle_focus(back and -1 or 1)
      vim.msg = 'focus: ' .. state.focus:upper()
    elseif back then ctx.toggle_focus(-1); vim.msg = 'focus: ' .. state.focus:upper()
    else ctx.clips_toggle() end
    c = 0
  end
  if c > 0 and state.kslider and not HN.active and ctx.kslider_key(c) then c = 0 end
  if c > 0 and HN.active then
    local r = HN.key(c)
    if type(r) == 'table' then local ok, e = pcall(hint_go, r); if not ok then vim.msg = tostring(e):match('[^\n]*$') end; state.hjumps = (state.hjumps or 0) + 1 end
    if not HN.active then ctx.glide = nil end
    c = 0
  elseif c == ('F'):byte() and (state.ss_big or (state.clipsview and state.focus == 'tracker') or (MX.clips and state.focus == 'matrix') or (state.top and state.toptab == 'clips' and state.focus == 'top')) and vim.mode == 'normal' and not vim.hydra and not vim.picker then
    MX.SS.scene_mode = true
    if HN.start() then vim.msg = 'scene: type the label of any cell in the row, Esc' else MX.SS.scene_mode = false; vim.msg = 'no targets' end
    c = 0
  elseif c == (','):byte() and vim.count and vim.mode == 'normal' and not vim.hydra and not vim.picker then
    ctx.glide_unit = 'beat'; vim.msg = vim.count .. ' beat(s): f + a dB mark - the fader glides'; c = 0   -- 2,f — ход за 2 доли
  elseif c == ('f'):byte() and vim.mode == 'normal' and not vim.hydra and not vim.picker and state.focus ~= 'browser' and state.focus ~= 'fxb' and state.focus ~= 'notes' then
    -- счётчик перед f (8 окт): 2f — фейдер на метку ходом за 2 такта (2,f — доли)
    ctx.glide = vim.count and { n = vim.count, unit = ctx.glide_unit or 'bar' } or nil
    vim.count, ctx.glide_unit = nil, nil
    if HN.start() then vim.msg = ctx.glide and ('hints: a dB mark glides the fader in %d %s, Esc'):format(ctx.glide.n, ctx.glide.unit) or 'hints: type label, Esc' else vim.msg = 'no targets' end
    c = 0
  end
  -- быстрая нарезка (5 окт): фокус в lib или во вкладке сэмпла — ! по
  -- транзиентам (повтор — чувствительность выше, по кругу), @ # $ % ^ & — 4..128
  -- равных частей, Q — квантайзер; Shift+1-«слушать» там уступает место
  if c > 0 and (state.focus == 'inst' or (state.focus == 'top' and state.toptab == 'sample'))
     and not (vim.mode == 'cmd' or vim.mode == 'search' or vim.picker or vim.hydra or B.filtering) and c < 256 and ctx.slice_quick(string.char(c)) then
    c = 0
  end
  -- Shift+1 (!) — прослушать выбранный инструмент из любого модуля (2 окт);
  -- только его длина (слайс — свой кусок), через трек курсора
  if c == 33 and not HN.active and not (vim.mode == 'cmd' or vim.mode == 'search' or vim.picker or vim.hydra or B.filtering
      or (state.focus == 'top' and state.toptab == 'garden' and GD.page == 'orca') or state.focus == 'fxb' or state.focus == 'notes') then
    local col = cur_col()
    local e = col and (col.pool or {})[vim.inst]
    if e and (e.take or e.src) then PV.slice(col.track, e, 0, e.len); vim.msg = ('listen %02d %s'):format(vim.inst, e.name)
    else vim.msg = 'no instrument selected (empty slot)' end
    c = 0
  end
  if c > 0 and ctx.LOGOPOP then ctx.LOGOPOP = nil; c = 0 end   -- :logo — любая клавиша закрывает
  -- справка (2 окт): ? включает / выключает; фокус на справке — поиск и
  -- страницы; иначе нажатая клавиша подсвечивает свою строку справки
  if c > 0 then
    local typing = vim.mode == 'cmd' or vim.mode == 'search' or vim.picker or vim.hydra or B.filtering
      or (state.focus == 'top' and state.toptab == 'garden' and GD.page == 'orca') or state.focus == 'fxb' or state.focus == 'notes'
    if state.khelp_big then
      -- большая справка: клавиши — ей (поиск, страницы, прокрутка); Esc / Enter — закрыть
      local r = ctx.DOC.key(c)
      if r == 'leave' then state.khelp_big = false end
      c = 0
    elseif state.khelp and state.focus == 'dsp' and not typing then
      if c == 63 and KH.query == '' then ctx.toggle_help(); c = 0
      else
        local r = KH.key(c)
        if r == 'leave' then ctx.set_focus(KH.from or 'tracker'); c = 0 elseif r then c = 0 end
      end
    elseif c == 63 and not typing then
      ctx.actions_picker(); c = 0                          -- ? (6 окт): действия REAPER; справка — F1
    elseif state.khelp and not typing then
      KH.press(ctx.help_page(), c, reaper.time_precise())
    end
  end
  if c > 0 then
    state.last_key = c
    vim.msg = ''
    -- debug (6 окт): return-хук на время обработки — где клавишу съели
    -- (файл:строка возврата функций key модулей)
    local trace
    if state.debug then
      trace = {}
      local vk = vim.key
      debug.sethook(function()
        local i = debug.getinfo(2, 'fSl')
        if i and (i.func == vk or (i.short_src or ''):find('jf_tracker') and debug.getinfo(2, 'n').name == 'key') then
          trace[#trace + 1] = ((i.short_src or ''):match('jf_tracker_?([%w_]*)%.lua$') or '?'):gsub('^$', 'main') .. ':' .. (i.currentline or 0)
        end
      end, 'r')
    end
    local ok, r = pcall(function()
      -- открытый пикер (fzf) / hydra-меню модальны: клавиши им, а не модулю в
      -- фокусе (2 окт: в модуляции a открывал выбор параметра, а набор и Enter
      -- съедала матрица модуляции — выбрать было нельзя)
      if vim.picker or vim.hydra then return vim.key(c) end
      -- 5 окт: две гидры — ` главная (у главного модуля слева сверху), \ —
      -- контекст фокуса; в INSERT ` — note-off, поэтому главная — вне INSERT
      local typing = vim.mode == 'cmd' or vim.mode == 'search' or state.focus == 'notes' or (B.filtering and state.focus == 'browser') or state.focus == 'fxb'
      -- 6 окт: главное меню — \ (` больше не меню; в INSERT ` — note-off)
      local m0 = ctx.mods()
      if not typing and (c == 47 or c == 31) and m0.ctrl then ctx.fx_search_global(); return end          -- Ctrl+/ — эффекты
      if not typing and (c == 1962934519 or (c == 47 and m0.alt)) then ctx.dsp_search(); return end     -- Option+/ (÷) — DSP
      if not typing and c == 47 and m0.cmd then ctx.file_search(); return end                           -- Cmd+/ — файлы
      -- \ (5 окт): контекстное меню выбранного в модуле — как правая кнопка
      if c == 92 and state.focus ~= 'tracker' and state.focus ~= 'notes' and vim.mode ~= 'cmd' and vim.mode ~= 'search' then
        ctx.main_menu(); return                          -- \ — главное меню, в нём \ — контекст
      end
      -- макро-вид: j k J K g G — по тактам, Enter / Esc — назад в трекер
      -- док session в фокусе (7 окт): клип-мод — клавиатура запускает клипы;
      -- : и / команды — в vim, Esc / Tab — в трекер
      if state.focus == 'session' and state.clipsview and snap and vim.mode ~= 'cmd' and vim.mode ~= 'search' then
        if c == 27 then ctx.set_focus('tracker'); vim.msg = 'focus: TRACKER'; return end
        if c == (':'):byte() then return vim.key(c) end
        if c == (';'):byte() then if HN.start() then vim.msg = 'jump: type a label (clips, scenes), Esc' end; return end   -- f занята клипом
        local vis = MX.SS.vis_draw or {}
        if MX.SS.clip_key(c, seq, ctx.ss_V(), ctx.ss_G(), vis, ctx.mods()) then return end
        return
      end
      if state.macro and state.focus == 'tracker' and vim.mode == 'normal' then
        local mr = draw.macro.key(c, vim.cur.row, beat_info.rows_bar or (state.lpb * 4), snap and snap.last_row)
        if mr == 'leave' then state.macro = false; vim.msg = 'macro off - bar ' .. (vim.cur.row // math.max(1, beat_info.rows_bar or 16) + 1); return end
        if mr then vim.cur.row = mr; return end
      end
      if state.focus == 'matrix' and ctx.PERF and ctx.PERF.active and ctx.PERF.key(c) then   -- производительность на месте матрицы (6 окт)
      elseif state.focus == 'matrix' and #seq == 0 and c == 43 then ctx.mx_add()     -- пустая матрица: + добавляет первый регион
      elseif state.focus == 'matrix' and MX.mkedit then
        -- поле такта маркера на линии =START / =END (5 окт)
        local me = MX.mkedit
        if c == 27 then MX.mkedit = nil
        elseif c == 13 then MX.mkedit = nil; ctx.seq_marker(me.which, me.buf ~= '' and me.buf or nil)
        elseif c == 8 then me.buf = me.buf:sub(1, -2)
        elseif (c >= 48 and c <= 57) or c == 46 then if #me.buf < 7 then me.buf = me.buf .. string.char(c) end end
      elseif state.focus == 'matrix' and #seq > 0 then
        -- командная строка (:name / :len после + n =) — клавиши идут в vim, не в матрицу (ревью 1 окт)
        if vim.mode == 'cmd' or vim.mode == 'search' then return vim.key(c) end
        if (state.ss_big or MX.clips) and MX.SS.key(c, seq, ctx.ss_V(), ctx.ss_G(), ctx.mods()) then return end
        if not MX.key(c, seq, snap) then return vim.key(c) end
      elseif state.focus == 'browser' and state.side then
        if not B.key(c) then return vim.key(c) end
      elseif state.focus == 'slices' and state.slices_on then
        -- модуль слайсов (4 окт): j k — слайс (звучит), J K — по 8, g G — край, Esc — в трекер
        local ch = c < 256 and string.char(c) or ''
        local root = ctx.slice_root()
        local cur = (root and ctx.ssel.item == root.item) and (ctx.ssel.k or 0) or 0
        local n = root and root.slices and #root.slices or 0
        if c == 27 then ctx.set_focus('tracker')
        elseif ch == 'j' or c == keys.down then ctx.slice_step(1)
        elseif ch == 'k' or c == keys.up then ctx.slice_step(-1)
        elseif ch == 'J' then ctx.slice_step(8)
        elseif ch == 'K' then ctx.slice_step(-8)
        elseif ch == 'g' then ctx.slice_step(-cur)
        elseif ch == 'G' then ctx.slice_step(n - cur)
        else return vim.key(c) end
      elseif state.focus == 'inst' and (state.top or state.side) then
        if vim.mode == 'cmd' or vim.mode == 'search' then return vim.key(c) end
        local col = cur_col()
        local n = #(col and col.pool or {})
        local r = IK.key(c, vim.inst, n, n + draw.empty_slots(n))
        if r == 'leave' then ctx.set_focus('tracker')
        elseif not r then return vim.key(c) end
      elseif state.focus == 'ctrl' and state.top then
        -- главный модуль с клавиатуры (3 окт): hjkl / стрелки — ячейка, + − —
        -- значение (как колесо), Enter / Space — как клик (BPM — ввод числа)
        if vim.mode == 'cmd' or vim.mode == 'search' then return vim.key(c) end
        local ch = c < 256 and string.char(c) or ''
        local sel = state.ctrl_sel or 'bpm'
        local dx, dy = 0, 0
        if ch == 'h' or c == keys.left then dx = -1 elseif ch == 'l' or c == keys.right then dx = 1
        elseif ch == 'k' or c == keys.up then dy = -1 elseif ch == 'j' or c == keys.down then dy = 1 end
        if dx ~= 0 or dy ~= 0 then
          state.ctrl_sel = ctx.ctrl_move(sel, dx, dy)
        elseif c == 27 then ctx.set_focus('tracker')
        elseif c == 13 or ch == ' ' then
          if sel == 'bpm' then state.bpm_edit = '' else ctrl_action(sel, 0) end
        elseif ch == '+' or ch == '=' then ctrl_action(sel, 1)
        elseif ch == '-' then ctrl_action(sel, -1)
        elseif sel == 'bpm' and ch:match('%d') then state.bpm_edit = ch
        else return vim.key(c) end
      elseif state.focus == 'notes' and state.notes_open then
        if NT.key(c) == 'leave' then ctx.notes_save(); ctx.set_focus('tracker') end
      elseif state.focus == 'fxb' and state.dsp and state.fxb then
        if vim.mode == 'cmd' or vim.mode == 'search' then return vim.key(c) end
        local r = FB.key(c, ctx.mods())
        if r == 'add' then ctx.fxb_add()
        elseif r == 'leave' then ctx.toggle_focus() end
      elseif state.focus == 'dsp' and state.dsp and not state.khelp then
        -- DSP — своя грамматика по эффектам (jf_tracker_dspkeys.lua, 2 окт);
        -- в vim уходят только командная строка и поиск (: /)
        if vim.mode == 'cmd' or vim.mode == 'search' then return vim.key(c) end
        local ch = c < 256 and string.char(c) or ''
        if not DK.pending and (ch == ':' ) then return vim.key(c) end
        if state.dsp_big or state.router_big then   -- роутер (7 окт): свои клавиши; чужие — в vim
          local root, o = ctx.db_tree()
          if root and MX.DB.key(c, root, o) then return end
          return vim.key(c)
        end
        -- z-операторы (7 окт): zz / zr — роутер в DSP FX, zR — большой роутер
        if state.dsp_z and not DK.pending then
          state.dsp_z = nil
          if ch == 'z' or ch == 'r' then ctx.dsp_big() elseif ch == 'R' then ctx.router_big() end
          return
        end
        if ch == 'z' and not DK.pending then state.dsp_z = true; vim.msg = 'z: z / r - router in DSP FX, R - big router'; return end
        local col = dsp_target(); local fxs = col and col.fx or {}
        local f = fxs[dsp_sel.fx]
        if ch == 't' and not DK.pending then ctx.dsp_toggle_target(); return end
        if ch == 'E' and not DK.pending then ctx.dsp_learn_toggle(); return end
        if dsp_learn and not DK.pending then
          if c == 27 then ctx.dsp_learn_toggle(); return end
          if ctx.dsp_learn_key(ch) then return end
        end
        local r = DK.key(c, dsp_sel, #fxs, f and #f.params or 0, ctx.mods())
        if r == 'leave' then ctx.set_focus('tracker') end
      elseif state.focus == 'top' and state.top and (vim.mode == 'cmd' or vim.mode == 'search') then
        -- набор команды / поиска: клавиши только в vim, вкладка их не видит (2 окт)
        return vim.key(c)
      elseif state.focus == 'top' and state.top then
        local ch = c < 256 and string.char(c) or ''
        if c == 9 then ctx.toggle_focus()
        elseif state.toptab == 'sample' and SPROP.key(c, cur_col() and (cur_col().pool or {})[vim.inst]) then
          -- панель свойств: J K строка, H L значение, R сброс
        elseif state.toptab == 'sample' and SL.active then
          SL.key(c)
          if not SL.active then ctx.set_focus('tracker') end
        elseif state.toptab == 'retro' then
          if c == 27 then ctx.set_focus('tracker')
          elseif ch == 'a' then ctx.retro_all()
          elseif ch == ' ' then if retro.cur and retro.cur.playing then retro_preview(false) else retro_preview(true) end
          elseif ch == 's' then retro_preview(false)
          elseif ch == 'p' or c == 13 then
            -- выбран пустой слот инструментов — захват в библиотеку трека (новый инструмент)
            local col = cur_col()
            if col and vim.inst > #(col.pool or {}) then retro_put('depot') else retro_put('cursor') end
          elseif ch == 'P' then retro_put('cursor', true)
          elseif ch == 'L' then retro_loop()
          elseif ch == '1' or ch == '2' or ch == '4' or ch == '8' then retro.loop_bars = tonumber(ch); vim.msg = 'retro loop length: ' .. ch .. ' bar(s) - L loops what was just played'
          elseif ch == 'd' then retro_put('depot')
          elseif ch == '+' or ch == '=' then ctx.retro_add()
          elseif ch == 'j' or c == keys.down then ctx.retro_cycle(1)
          elseif ch == 'k' or c == keys.up then ctx.retro_cycle(-1)
          elseif ch == '[' then ctx.retro_nudge('a', -0.01) elseif ch == ']' then ctx.retro_nudge('b', 0.01)
          elseif ch == '{' then ctx.retro_nudge('a', 0.01) elseif ch == '}' then ctx.retro_nudge('b', -0.01)
          elseif ch == 'h' or c == keys.left then ctx.retro_nudge('ab', -0.02)
          elseif ch == 'l' or c == keys.right then ctx.retro_nudge('ab', 0.02)
          else return vim.key(c) end
        elseif state.toptab == 'master' or state.toptab == 'scope' then
          if c == 27 then ctx.set_focus('tracker')
          elseif ch == 'm' then ctx.scopemode()
          else return vim.key(c) end
        elseif state.toptab == 'garden' then
          if not GD.key(c, snap, seq) then
            if c == 27 then ctx.set_focus('tracker')
            elseif vim.mode ~= 'insert' then return vim.key(c) end   -- INSERT не пишет ноты из вкладки
          end
        elseif state.toptab == 'clips' then
          if not MX.SS.key(c, seq, ctx.ss_V(), ctx.ss_G(), ctx.mods()) then
            if c == 27 then ctx.set_focus('tracker') else return vim.key(c) end
          end
        elseif state.toptab == 'midi' then
          local r = MM.key(c)
          if r == 'leave' then ctx.set_focus('tracker')
          elseif r == 'save' then mm_save()
          elseif not r then return vim.key(c) end
        elseif state.toptab == 'modulation' and mod_pane == 'lfo' then
          local r = LG.key(c, ctx.mods().shift and 0.1 or 1)   -- Shift — мелкий шаг (6 окт)
          if r == 'leave' then mod_pane = 'matrix'
          elseif r == 'ai' or r == 'points' then ctx.lfo_make(r)
          elseif r == 'pick' then ctx.lfo_pick_env()
          elseif not r then return vim.key(c) end
        elseif state.toptab == 'modulation' and mod_pane == 'params' then
          local r = MMX.PP.key(c, cur_col())
          if r == 'leave' then mod_pane = 'matrix'
          elseif not r then return vim.key(c) end
        elseif state.toptab == 'modulation' and c == 80 then mod_pane = 'params'; vim.msg = 'params: all parameters of the track - Enter: envelope, m: modulate, c: curve, v: used only, P: back'
        elseif state.toptab == 'modulation' and c == 76 then mod_pane = 'lfo'; vim.msg = 'LFO: j k field, h l value, g auto-item, p write points, L back'
        elseif state.toptab == 'modulation' then
          local col = cur_col(); local mods = col and col.mods or {}
          if c == 27 then ctx.set_focus('tracker')
          elseif not MMX.key(c, mods) then return vim.key(c) end
        else
          if c == 27 then ctx.set_focus('tracker') else return vim.key(c) end
        end
      else
        return vim.key(c)
      end
    end)
    if trace then debug.sethook() end
    if not ok then vim.msg = tostring(r):match('[^\n]*$') or tostring(r) elseif r == 'quit' then quit = true end
    if trace then
      ctx.last_trace = table.concat(trace, '>')
      -- набранный текст (заметки, командная строка, поиск, пикер) — без самих
      -- символов: в логе только «text», код клавиши скрыт (6 окт)
      local typing = state.focus == 'notes' or vim.mode == 'cmd' or vim.mode == 'search' or vim.picker
      local lc, lraw = c, c_raw
      if typing and c >= 32 and c < 0x110000 and c ~= 127 then lc, lraw = 0, 0 end
      ctx.dlog(('key %d (raw %d) mode %s%s focus %s%s fi %d row %d field %s%s piano %s pending %s op %s buf %s -> %s @ %s%s'):format(
        lc, lraw, vim.mode, (vim.hydra and ' hydra' or '') .. (vim.picker and ' picker' or ''), state.focus, state.focus == 'top' and (':' .. tostring(state.toptab)) or '',
        vim.cur.fi, vim.cur.row, tostring(vim.cur.field), vim.cur.sub and ('/' .. vim.cur.sub) or '', tostring(vim.piano), tostring(vim.pending), tostring(vim.op),
        tostring(vim.hexbuf or vim.shapebuf), tostring(vim.msg or ''), ctx.last_trace, ok and '' or (' ERROR ' .. tostring(r))))
    end
  end
  if c_raw > 0 and ctx.keylog and #ctx.keylog > 0 then
    ctx.keylog[#ctx.keylog] = ctx.keylog[#ctx.keylog] .. ' -> ' .. tostring(vim.msg or ''):sub(1, 50) .. (ctx.last_trace and state.debug and (' @' .. ctx.last_trace) or '')
    reaper.SetExtState(EXT, 'keylog', table.concat(ctx.keylog, ' | '), false)
  end
  inject_cap = nil
  draw.pmark(nil)                                  -- jftop: конец кадра, ожидание defer не считается
  if state.debug and ctx.dlog and reaper.time_precise() - (ctx.jftop_logt or 0) > 5 then
    -- debug: раз в 5 с — сводка jftop в лог (средние мс за кадр, по убыванию)
    ctx.jftop_logt = reaper.time_precise()
    local list = {}
    for k, p in pairs(draw.prof) do list[#list + 1] = { k, p.ema, p.max } end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    local parts = {}
    for i = 1, math.min(8, #list) do parts[#parts + 1] = ('%s %.2f (max %.1f)'):format(list[i][1], list[i][2], list[i][3]) end
    ctx.dlog('jftop ms/frame: ' .. table.concat(parts, ' | '))
  end
  local owner = reaper.GetExtState(EXT, 'owner')
  local taken = owner ~= '' and owner ~= MY_ID
  if c ~= -1 and not quit and not taken and reaper.GetExtState(EXT, 'quit') ~= '1' then
    -- отклик (4 окт): клавиши и клики разбираются ПОСЛЕ отрисовки, и их
    -- результат попадал на экран только в следующем тике defer (~30 мс).
    -- Был ввод — кадр сразу ещё раз, в этом же тике (4 мс); повтор один,
    -- defer ставит уже он
    if (c > 0 or prof.input) and not prof.rerun then
      prof.rerun = true; prof.reruns = (prof.reruns or 0) + 1
      frame()
      prof.rerun = false
    else
      reaper.defer(frame)
    end
  else
    reaper.SetExtState(EXT, 'exit', ('c=%d quit=%s taken=%s flag=%s at %s'):format(c, tostring(quit), tostring(taken), reaper.GetExtState(EXT, 'quit'), os.date('%H:%M:%S')), false)
    if not taken then reaper.DeleteExtState(EXT, 'quit', false); reaper.DeleteExtState(EXT, 'owner', false) end
    if ctx.PM and ctx.PM.flush then pcall(ctx.PM.flush, true) end
    PV.stop(); save_win(); gfx.quit()
  end
end

-- Один экземпляр: при старте пишем свой id в ExtState jf_tracker/owner;
-- любой экземпляр, увидевший чужой id, выходит. Так второй запуск (из
-- Actions, из -nonewinst, из run_tracker) всегда ПЕРЕХВАТЫВАЕТ окно, а не
-- плодит дубли и не вешает диалог «script already running».
reaper.SetExtState(EXT, 'owner', MY_ID, false)
reaper.DeleteExtState(EXT, 'quit', false)
reaper.DeleteExtState(EXT, 'err', false)
-- надёжность (3 окт): ошибка кадра не закрывает трекер — пишется в ExtState
-- err с местом (traceback), показывается в статусе, следующий кадр идёт как
-- обычно; закрываемся, только если ошибка повторяется ~3 с подряд (цикл)
local err_streak, err_last = 0, nil
frame = (function(inner)
  return function()
    local ok, e = xpcall(inner, debug.traceback)
    if ok then err_streak = 0; return end
    err_streak = err_streak + 1
    local msg = tostring(e)
    if msg ~= err_last then reaper.SetExtState(EXT, 'err', msg, false); err_last = msg; pcall(ctx.dlog, 'ERROR ' .. msg) end
    vim.msg = 'error (tracker keeps running): ' .. (msg:match('^[^\n]*') or msg)
    if err_streak > 100 then save_win(); gfx.quit(); return end
    gfx.update()
    reaper.defer(frame)
  end
end)(frame)

reaper.atexit(save_win)
-- заметки открыты с прошлого раза — загрузить текст (4 окт: после рестарта были пустыми)
if state.notes_open then pcall(ctx.notes_load) end
-- расширения (релиз 5 окт): без SWS прослушивание молчит, без js_ReaScriptAPI нет
-- удержания нот — сказать сразу, а не оставить гадать
(function()                          -- функция: у главного куска предел 200 локалов
  local miss = {}
  if not reaper.CF_CreatePreview then miss[#miss + 1] = 'SWS (preview)' end
  if not reaper.JS_VKeys_GetState then miss[#miss + 1] = 'js_ReaScriptAPI (held notes, key state)' end
  if #miss > 0 then vim.msg = 'missing: ' .. table.concat(miss, ', ') .. ' - install through ReaPack' end
end)()
frame()
