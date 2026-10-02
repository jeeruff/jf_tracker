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

local U = dofile(RES .. '/Scripts/jf_looper/jf_looper_ui.lua')
local model = dofile(DIR .. '/jf_tracker_model.lua')
local draw = dofile(DIR .. '/jf_tracker_draw.lua')
local keys = dofile(DIR .. '/jf_tracker_keys.lua')
local edit = dofile(DIR .. '/jf_tracker_edit.lua')
local vim = dofile(DIR .. '/jf_tracker_vim.lua')
local OPT = dofile(DIR .. '/jf_tracker_options.lua')   -- окно Options (1 окт)
local VER = dofile(DIR .. '/jf_tracker_version.lua')    -- версия и изменения (Options → about)
local SPROP = dofile(DIR .. '/jf_tracker_sampleprops.lua')  -- панель свойств сэмпла (вкладка Sample)
local MX = dofile(DIR .. '/jf_tracker_matrix.lua')
local PV = dofile(DIR .. '/jf_tracker_preview.lua')
local alias = dofile(DIR .. '/jf_tracker_alias.lua')
local B = dofile(DIR .. '/jf_tracker_browser.lua')
local MMX = dofile(DIR .. '/jf_tracker_modmatrix.lua')
local ORCA = dofile(DIR .. '/jf_tracker_orca.lua')       -- ядро Orca (Garden)
local GD = dofile(DIR .. '/jf_tracker_garden.lua')       -- вкладка Garden
local SL = dofile(DIR .. '/jf_tracker_slicer.lua')
local CM = dofile(DIR .. '/jf_tracker_cmds.lua')
local HN = dofile(DIR .. '/jf_tracker_hints.lua')
model.dspmods = dofile(DIR .. '/jf_tracker_dspmods.lua')
local HELP = DIR .. '/jf_tracker_help.html'

-- ── состояние ─────────────────────────────────────────────────────────────
local function ext(k, d)
  local v = reaper.GetExtState(EXT, k)
  if v == '' then return d end
  return tonumber(v) or v
end
local function flag(k, d) return ext(k, d and '1' or '0') ~= '0' end

local LPBS = { 1, 2, 3, 4, 6, 8, 12, 16 }
local state = {
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
  toptab = (function() local t = ext('toptab', 'master'); if t == 'mod' then t = 'modulation' elseif t == 'scope' then t = 'master' end; return t end)(),
  top = flag('top', true),                      -- верхняя панель (контрол | метры | инструменты)
  meters = flag('meters', false),               -- большие пик-метры в шапках треков
  pool = flag('pool', true),                    -- (устар.) = top
  poolprev = flag('poolprev', true),            -- прослушивать выбранный слот (1 с)
  side = flag('side', false),                   -- сайдбар-браузер
  sidenarrow = flag('sidenarrow', false),       -- узкий сайдбар (кнопка <>)
  scopes = flag('scopes', false),               -- JSFX-мост осциллоскопов на треках
  scopemode = (function() local v = reaper.GetExtState(EXT, 'scopemode'); return (v == 'spec' or v == 'sgram') and v or 'scope' end)(),
  icons = flag('icons', true),                    -- Nerd-иконки (TTF или гибрид с битмапом, :icons)
  glyphface = (function() local v = reaper.GetExtState(EXT, 'glyphface'); return v ~= '' and v or nil end)(),
  fontface = (function() local v = reaper.GetExtState(EXT, 'fontface'); return v ~= '' and v or 'JetBrainsMono Nerd Font Mono' end)(),
  xfade = flag('xfade', false),                   -- x-fade вставленных нот (\x, контрол xf)
  xfade_ms = tonumber(reaper.GetExtState(EXT, 'xfade_ms')) or 10,
  side_px = tonumber(reaper.GetExtState(EXT, 'side_px')),   -- ширина браузера мышью (nil = авто)
  top_px = tonumber(reaper.GetExtState(EXT, 'top_px')),     -- высота верхней панели мышью
  inst_px = tonumber(reaper.GetExtState(EXT, 'inst_px')),   -- высота инструментов в сайдбаре
  mx_px = tonumber(reaper.GetExtState(EXT, 'mx_px')),       -- ширина матрицы мышью (nil = авто)
  mx_hidden = reaper.GetExtState(EXT, 'mx_hidden') == '1',  -- матрица свёрнута в полосу
  wave = (function() local v = reaper.GetExtState(EXT, 'wave'); return (v == 'peaks' or v == 'rect' or v == 'spec' or v == 'off') and v or 'peaks' end)(),
  dsp = flag('dsp', false),                     -- нижняя DSP-панель (FX трека)
  fcollapse = {},                               -- guid папки → свёрнута
}
-- миграция 1 окт (2): пользователь выбрал битмап ×2
-- ext() отдаёт число для числовых строк: сравнивать через tostring (иначе 3 ~= '3'
-- и шрифт сбрасывался в битмап при каждом старте)
if tostring(ext('font_v', '')) ~= '3' then state.font = 0; state.fontscale = 2 end
state.subs_min = {}
for k, v in tostring(ext('subsmin', '')):gmatch('([^=,]+)=(%d+)') do state.subs_min[k] = tonumber(v) end
state.wave_os = tonumber(ext('wave_os', 1)) or 1
vim.vel = math.max(1, math.min(127, tonumber(ext('vel', 100)) or 100))
model.OVERSAMPLE = state.wave_os
vim.step_auto = tostring(ext('step_auto', '0')) == '1'
reaper.SetExtState(EXT, 'font_v', '3', true)
for g in tostring(ext('folds', '')):gmatch('[^,]+') do state.folds[g] = true end
for g in tostring(ext('fcollapse', '')):gmatch('[^,]+') do state.fcollapse[g] = true end
for g, m in tostring(ext('pitchmodes', '')):gmatch('([^,=]+)=([^,]+)') do state.pitchmodes[g] = m end

local MY_ID = ('%d-%06d'):format(os.time(), math.floor((reaper.time_precise() % 1) * 1e6))
local snap, regions, L, rows = nil, {}, nil, {}
local seq = {}      -- регионы последовательности (без библиотеки =LIB)
local fps = { n = 0, t = reaper.time_precise(), v = 0 }
local prof = { snap = 0, layout = 0, draw = 0, upd = 0, n = 0 }
local click = { t = 0, fi = nil, row = nil, zone = nil }   -- для двойного клика
local browse_last = nil                                     -- строка браузера, которую уже слушали (auto)
local inject_last = reaper.GetExtState(EXT, 'inject')       -- стартовое значение не исполняем
local body_drag = nil                                       -- Shift+протяжка блока в теле
local cmd_text_cache                                        -- ctx.cmd_by_text
local dsp_drag = nil                                        -- перетаскивание DSP-блока
local resize_drag = nil                                     -- ресайз: 'side' | 'top'
local lock_sync = {}                                        -- lock: последнее синхронное состояние
local seq_cache = {}                                        -- последовательность матрицы (ctx.sequence)
local trs_drag = nil                                        -- протяжка слайдера громкости/панорамы в шапке
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
local dsp_sel = { fx = 1, param = 1 }                     -- выбор в DSP-панели (фокус dsp)
local fxv_cache = {}

-- ── окно ──────────────────────────────────────────────────────────────────
gfx.init('jf_tracker', tonumber(ext('w', 900)), tonumber(ext('h', 600)),
         tonumber(ext('dock', 0)), tonumber(ext('x', 100)), tonumber(ext('y', 100)))
draw.set_font(state)

local function save_win()
  local d, x, y = gfx.dock(-1, 0, 0, 0, 0)
  local S = function(k, v) reaper.SetExtState(EXT, k, tostring(v), true) end
  S('dock', d); S('x', x); S('y', y); S('w', gfx.w); S('h', gfx.h)
  S('lpb', state.lpb); S('fxcols', state.fxcols); S('font', state.font)
  S('fontscale', state.fontscale); S('fontspace', state.fontspace); S('toptab', state.toptab)
  for _, k in ipairs({ 'follow', 'envs', 'preview', 'autosync', 'pool', 'poolprev', 'side', 'sidenarrow', 'top', 'meters', 'scopes', 'dsp', 'icons', 'xfade', 'lock', 'fixed' }) do S(k, state[k] and '1' or '0') end
  S('step_auto', vim.step_auto and '1' or '0'); S('wave_os', tostring(state.wave_os or 1)); S('vel', tostring(vim.vel or 100))
  do local t = {}; for k, v in pairs(state.subs_min or {}) do if v > 1 then t[#t + 1] = k .. '=' .. v end end; S('subsmin', table.concat(t, ',')) end
  S('xfade_ms', tostring(state.xfade_ms))
  do local t = {}; for g, v in pairs(state.trackenvs or {}) do t[#t + 1] = g .. '=' .. (v and '1' or '0') end; S('trackenvs', table.concat(t, ',')) end
  S('scopemode', state.scopemode or 'scope'); S('wave', state.wave or 'peaks'); S('poolsort', state.poolsort or 'track')
  S('side_px', state.side_px and tostring(math.floor(state.side_px)) or ''); S('top_px', state.top_px and tostring(math.floor(state.top_px)) or '')
  S('inst_px', state.inst_px and tostring(math.floor(state.inst_px)) or '')
  S('mx_px', state.mx_px and tostring(math.floor(state.mx_px)) or ''); S('mx_hidden', state.mx_hidden and '1' or '0')
  S('glyphface', state.glyphface or ''); S('fontface', state.fontface or '')
  local pm = {}
  for g, m in pairs(state.pitchmodes) do pm[#pm + 1] = g .. '=' .. m end
  S('pitchmodes', table.concat(pm, ','))
  local fl = {}
  for g, v in pairs(state.folds) do if v then fl[#fl + 1] = g end end
  S('folds', table.concat(fl, ','))
  local fc = {}
  for g, v in pairs(state.fcollapse) do if v then fc[#fc + 1] = g end end
  S('fcollapse', table.concat(fc, ','))
  S('browse', B.root or '')
end

-- ── помощники ─────────────────────────────────────────────────────────────
local function relayout() L = draw.layout(snap, state, #regions) end
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

-- F11: док ↔ плавающее окно на весь экран (рабочая область монитора)
local function toggle_dock()
  local d = gfx.dock(-1)
  if d & 1 == 1 then
    local l, t, r, b = reaper.my_getViewport(0, 0, 0, 0, 0, 0, 0, 0, true)
    gfx.dock(0, l, t, r - l, b - t)
    vim.msg = 'fullscreen'
  else
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
local function pool_select(n)
  local col = cur_col()
  local pool = col and col.pool or {}
  if #pool == 0 then vim.msg = 'pool empty'; return end
  n = math.max(1, math.min(#pool, n))
  vim.inst = n
  local e = pool[n]
  -- выбор инструмента возвращает сэмпл-модуль к нему (если там был файл браузера)
  if SL.entry and SL.entry.file then SL.close(); SL.entry = nil end
  vim.msg = ('inst %d: %s%s'):format(n, e.name, (e.tracks and #e.tracks > 0) and ('  @ ' .. table.concat(e.tracks, ', ')) or '')
  if state.poolprev and PV.available() then PV.audio(col.track, e.item, 0, 1.0) end
end

-- ── контекст для Vim-слоя, матрицы, браузера ──────────────────────────────
-- Объявление отдельно от конструктора: функции внутри таблицы ссылаются на
-- ctx.*, а `local ctx = {…}` не виден в собственном инициализаторе (они
-- брали глобальный ctx = nil — так падал Tab на ctx.set_focus).
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
  set_lpb = set_lpb,
  fold = function(col, v) state.folds[col.guid] = v or nil end,
  fold_all = function(v) for _, c in ipairs(snap.cols) do state.folds[c.guid] = v or nil end end,
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
  depot = function() local c = cur_col(); return c and c.pool or {} end,
  fit = draw.fit,
  set_pitchmode = function(col, mode) state.pitchmodes[col.guid] = mode end,
  set_font = function(n) state.font = n; draw.set_font(state) end,
  -- Nerd-шрифт для текста (TTF-режим) или для глифов (гибрид); ищем по подстроке
  set_fontface = function(name)
    local faces = { 'DepartureMono Nerd Font Mono', 'BigBlueTerm437 Nerd Font Mono', 'BigBlueTermPlus Nerd Font Mono',
      'GohuFont 14 Nerd Font Mono', 'GohuFont 11 Nerd Font Mono', 'ProggyClean Nerd Font Mono', 'Terminess Nerd Font Mono',
      'ProFont IIx Nerd Font Mono', '3270 Nerd Font Mono', 'JetBrainsMono Nerd Font Mono' }
    local pick
    if not name or name == '' then
      local i = 0
      for k, f in ipairs(faces) do if f == state.fontface then i = k end end
      pick = faces[i % #faces + 1]
    else
      for _, f in ipairs(faces) do if f:lower():find(name:lower(), 1, true) then pick = f; break end end
      pick = pick or name
    end
    state.fontface = pick
    if (state.font or 0) == 0 then state.glyphface = pick end
    draw.set_font(state)
    vim.msg = ((state.font or 0) > 0 and 'font: ' or 'glyphs: ') .. pick
  end,
  set_scale = function(n) state.fontscale = n; draw.set_font(state) end,
  set_space = function(n) state.fontspace = n; draw.set_font(state) end,
  mod_toggle = function(col, m, what) edit.mod_toggle(col.track, m, what) end,
  toggle_dock = toggle_dock,
  ctrl_held = function() return gfx.mouse_cap & 32 == 32 end,
  -- macOS: бит 4 = Cmd, 32 = Ctrl, 16 = Option
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
  -- все параметры FX трека для fzf
  mod_param_items = function(skip)
    local col = cur_col(); if not col then return {} end
    local items = {}
    for fx = 0, reaper.TrackFX_GetCount(col.track) - 1 do
      local _, fn = reaper.TrackFX_GetFXName(col.track, fx, ''); fn = (fn or ''):gsub('^[^:]*: ', '')
      for pi = 0, reaper.TrackFX_GetNumParams(col.track, fx) - 1 do
        if not (skip and skip.fx == fx and skip.param == pi) then
          local _, pn = reaper.TrackFX_GetParamName(col.track, fx, pi, '')
          items[#items + 1] = { label = fn .. ' / ' .. (pn or ('p' .. pi)), data = { fx = fx, param = pi } }
        end
      end
    end
    return items
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
    if m == 'off' then state.wave = 'off'
    elseif m then state.wave = 'spec'
    else state.wave = (state.wave == 'off') and 'spec' or 'off' end
    vim.msg = 'wave column: ' .. (state.wave == 'off' and 'off' or 'on (spectral peaks, colour = frequency; amber = stretch markers)')
  end,
  -- анализатор: scope → spec → sgram (кнопки у вкладок, :scopemode)
  scopemode = function(m)
    local order = { scope = 'spec', spec = 'sgram', sgram = 'scope' }
    state.scopemode = (m == 'scope' or m == 'spec' or m == 'sgram') and m or order[state.scopemode or 'scope']
    vim.msg = 'analyzer: ' .. state.scopemode
  end,
  mono_take = function(on) mono_request(on and MONO_ID or -1) end,
  retro_put = retro_put, retro_preview = retro_preview,
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
      vim.msg = ('matrix: copied %dx%d block'):format(r1 - r0 + 1, c1 - c0 + 1)
    elseif what == 'cut' then
      state.mx_clip = alias.cells_copy(seq, snap, r0, r1, c0, c1)
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
    local col = cur_col(); if not col then return end
    vim.open_picker('add fx to ' .. col.name, ctx.fx_list(), function(it)
      edit.fx_add(col.track, it.data); state.dsp = true
      vim.msg = '+ ' .. it.label
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
  toggle_scopes = function()
    state.scopes = not state.scopes
    edit.scopes(snap.cols, state.scopes)
    state.toptab = 'master'
    vim.msg = 'scopes ' .. (state.scopes and 'on (jf_tracker_scope added)' or 'off')
  end,
  -- fzf по всем параметрам автоматизации трека курсора: огибающие трека
  -- (действия «Toggle track … envelope visible», найденные по тексту) и
  -- каждый параметр каждого FX (GetFXEnvelope создаёт и показывает)
  automation_picker = function()
    local col = cur_col(); if not col then return end
    local tr = col.track
    local items = {}
    for _, range in ipairs({ { 40400, 40420 }, { 40860, 40870 }, { 41860, 41870 } }) do
      for id = range[1], range[2] do
        local txt = reaper.kbd_getTextFromCmd(id, 0) or ''
        if txt:match('^Track: Toggle track .*envelope visible') then
          local nm = txt:gsub('^Track: Toggle track ', ''):gsub(' envelope visible', '')
          items[#items + 1] = { label = 'track: ' .. nm, data = { kind = 'track', id = id, name = nm } }
        end
      end
    end
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      local _, fxname = reaper.TrackFX_GetFXName(tr, fx, '')
      fxname = (fxname or ''):gsub('^[^:]*: ', '')
      for pi = 0, math.min(512, reaper.TrackFX_GetNumParams(tr, fx)) - 1 do
        local _, pname = reaper.TrackFX_GetParamName(tr, fx, pi, '')
        items[#items + 1] = { label = fxname .. ' / ' .. (pname or ('p' .. pi)), data = { kind = 'fx', fx = fx, param = pi } }
      end
    end
    if #items == 0 then vim.msg = 'nothing to automate'; return end
    vim.open_picker('automation ' .. col.name, items, function(it)
      local d = it.data
      edit.run('show envelope', function()
        if d.kind == 'fx' then reaper.GetFXEnvelope(tr, d.fx, d.param, true)
        else
          -- уже видна — не прятать
          local env = reaper.GetTrackEnvelopeByName(tr, d.name:gsub('^%l', string.upper))
          local visible = false
          if env and reaper.BR_EnvAlloc then
            local be = reaper.BR_EnvAlloc(env, false)
            local act, vis = reaper.BR_EnvGetProperties(be); reaper.BR_EnvFree(be, false)
            visible = act and vis
          end
          if not visible then reaper.SetOnlyTrackSelected(tr); reaper.Main_OnCommand(d.id, 0) end
        end
      end)
      state.envs = true
      model.invalidate()
      vim.msg = 'envelope: ' .. it.label
    end)
  end,
  preview_slice = function(track, entry, t0, t1) PV.slice(track, entry, t0, t1) end,
  mx_zoom = function() MX.zoom = MX.zoom == 'detail' and 'schematic' or 'detail' end,
  vtext = draw.vtext,
  -- огибающие: точка в строке (tol — полстроки), значение 0..1
  env_set = function(e, row, v)
    local t = edit.row_time(row, state.lpb, 0)
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
  sequence = function()
    local s0 = model.marker_pos(model.START_MARKER) or 0
    local s1 = model.marker_pos(model.END_MARKER)
    local key = tostring(regions) .. '|' .. state.lpb .. '|' .. s0 .. '|' .. tostring(s1)
    if seq_cache.key == key then return seq_cache.seq end
    local out, real = {}, {}
    for _, rg in ipairs(regions) do
      if not rg.lib and rg.rgnend > s0 + 1e-6 and (not s1 or rg.pos < s1 - 1e-6) then real[#real + 1] = rg end
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
  mx_refresh = function()
    model.invalidate()
    regions = model.regions(state.lpb)
    seq = ctx.sequence()
  end,
  mx_add = function(bars, name)
    local n = #seq + 1
    name = (name and name ~= '') and name or ('%02d'):format(n)
    edit.run('add region', function() alias.add_region(ctx.real_seq(), name, bars or 1) end)
    ctx.mx_refresh()
    MX.goto_cell(seq, snap, #seq, MX.cur.ci)
    ctx.set_focus('matrix')
    vim.msg = ('region %d "%s" added - name it'):format(#seq, name)
    vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'name ' .. name
  end,
  mx_name_prompt = function(ri)
    if ri then MX.goto_cell(seq, snap, ri, MX.cur.ci) end
    local rg = seq[MX.cur.ri]
    if not rg then vim.msg = 'no region'; return end
    ctx.set_focus('matrix')
    vim.cmd_from = vim.mode; vim.mode = 'cmd'; vim.cmdline = 'name ' .. rg.name
  end,
  mx_len_prompt = function(ri)
    if ri then MX.goto_cell(seq, snap, ri, MX.cur.ci) end
    local rg = seq[MX.cur.ri]
    if not rg then vim.msg = 'no region'; return end
    ctx.set_focus('matrix')
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
  sp_adjust = function(e, k, d)
    local it, tk = e.item, e.take
    if not (it and tk and reaper.ValidatePtr(it, 'MediaItem*')) then vim.msg = 'instrument item is gone'; return end
    local fine = ctx.mods().shift
    if k == 'vol' then
      local v = reaper.GetMediaItemInfo_Value(it, 'D_VOL')
      local db = v > 1e-6 and 20 * math.log(v, 10) or -60
      edit.item_set(it, 'D_VOL', 10 ^ (math.max(-60, math.min(24, db + d * 0.5)) / 20), 'sample volume')
    elseif k == 'pan' then edit.take_set(tk, 'D_PAN', math.max(-1, math.min(1, reaper.GetMediaItemTakeInfo_Value(tk, 'D_PAN') + d * 0.02)), 'sample pan')
    elseif k == 'st' then edit.take_set(tk, 'D_PITCH', reaper.GetMediaItemTakeInfo_Value(tk, 'D_PITCH') + d, 'sample transpose')
    elseif k == 'cent' then edit.take_set(tk, 'D_PITCH', reaper.GetMediaItemTakeInfo_Value(tk, 'D_PITCH') + d * 0.01, 'sample finetune')
    elseif k == 'rate' then
      local r = reaper.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
      local nr = math.max(0.1, math.min(10, r + d * 0.01))
      local len = reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
      edit.run('sample rate', function()
        reaper.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', nr)
        reaper.SetMediaItemInfo_Value(it, 'D_LENGTH', len * r / nr)
      end)
    elseif k == 'ppitch' then edit.take_set(tk, 'B_PPITCH', e.ppitch and 0 or 1, 'sample keep pitch')
    elseif k == 'mode' then
      -- цикл алгоритмов растяжения: project → 0 → 1 … (EnumPitchShiftModes)
      local modes = { -1 }
      for m = 0, 63 do local ok, nm = reaper.EnumPitchShiftModes(m); if ok and nm and nm ~= '' then modes[#modes + 1] = m << 16 end end
      local cur = reaper.GetMediaItemTakeInfo_Value(tk, 'I_PITCHMODE')
      local k0 = 1
      for i, m in ipairs(modes) do if m == cur or (m >= 0 and cur >= 0 and (m >> 16) == (math.floor(cur) >> 16)) then k0 = i end end
      edit.take_set(tk, 'I_PITCHMODE', modes[(k0 - 1 + d) % #modes + 1], 'sample stretch mode')
    elseif k == 'loop' then edit.item_set(it, 'B_LOOPSRC', e.loop and 0 or 1, 'sample loop')
    elseif k == 'fin' or k == 'fout' then
      local key = k == 'fin' and 'D_FADEINLEN' or 'D_FADEOUTLEN'
      edit.item_set(it, key, math.max(0, reaper.GetMediaItemInfo_Value(it, key) + d * (fine and 0.001 or 0.005)), 'sample fade')
    elseif k == 'fx' then reaper.TakeFX_Show(tk, 0, 1)                   -- окно цепочки take FX
    elseif k == 'norm' then edit.normalize(it); vim.msg = 'normalized (peak 0 dB)' end
    model.invalidate()
  end,
  sp_reset = function(e, k)
    local it, tk = e.item, e.take
    if not (it and tk and reaper.ValidatePtr(it, 'MediaItem*')) then return end
    if k == 'vol' then edit.item_set(it, 'D_VOL', 1, 'sample volume reset')
    elseif k == 'pan' then edit.take_set(tk, 'D_PAN', 0, 'sample pan reset')
    elseif k == 'st' or k == 'cent' then edit.take_set(tk, 'D_PITCH', 0, 'sample pitch reset')
    elseif k == 'mode' then edit.take_set(tk, 'I_PITCHMODE', -1, 'sample stretch reset')
    elseif k == 'fin' then edit.item_set(it, 'D_FADEINLEN', 0, 'sample fade reset')
    elseif k == 'fout' then edit.item_set(it, 'D_FADEOUTLEN', 0, 'sample fade reset')
    else ctx.sp_adjust(e, k, 1); return end
    model.invalidate()
  end,
  -- ── fzf-поиск в браузере и инструментах (2 окт) ─────────────────────
  browser_find = function()
    if not state.side then state.side = true end
    vim.msg = 'indexing…'
    local items, title = B.find_items()
    vim.open_picker(title, items, function(it) ctx.set_focus('browser'); B.find_pick(it.data) end)
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
    vim.open_picker('find instrument', items, function(it) ctx.set_focus('inst'); pool_select(it.data) end)
  end,
  -- клик по модулю переносит в него фокус (по прямоугольникам модулей)
  focus_at = function(x, y)
    local function inr(r) return r and x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4] end
    local f
    if inr(L.inst_rect) then f = 'inst'
    elseif state.side and x >= L.win_w and y > (L.side_y0 or 0) + (L.inst_side_h or 0) and y < gfx.h - L.status_h then f = 'browser'
    elseif inr(L.dsp_rect) then f = 'dsp'
    elseif inr(L.top_rect) then f = 'top'
    elseif not state.mx_hidden and x < L.matrix_w and y >= L.header_y and y < L.body_y + L.body_h then f = 'matrix'
    elseif x >= L.matrix_w and x < L.win_w and y >= L.header_y and y < L.body_y + L.body_h then f = 'tracker' end
    if f and f ~= state.focus then ctx.set_focus(f) end
  end,
  -- окно Options: список строит здесь (знает state / vim); модуль — только показ и клавиши
  options = function()
    local function flag(k, label, desc) return { key = k, label = label, kind = 'toggle', desc = desc, get = function() return state[k] end, set = function(v) state[k] = v end } end
    local items = {
      flag('follow', 'follow playhead', 'view scrolls with the playhead'),
      flag('lock', 'lock to REAPER cursor', 'tracker cursor = edit cursor + selected track, both ways'),
      flag('fixed', 'fixed cursor', 'cursor row stays centred, pattern scrolls (Impulse Tracker)'),
      { key = 'step', label = 'edit step', kind = 'num', min = 0, max = 64, desc = 'rows to advance after a note', get = function() return vim.step end, set = function(v) vim.step = v; vim.step_auto = false end },
      { key = 'step_auto', label = 'step auto', kind = 'toggle', desc = 'advance past the end of the inserted item / slice', get = function() return vim.step_auto end, set = function(v) vim.step_auto = v end },
      { key = 'lpb', label = 'lines per beat', kind = 'num', min = 1, max = 32, desc = 'rows per beat (view scale only)', get = function() return state.lpb end, set = function(v) ctx.set_lpb(math.floor(v)) end },
      { key = 'fxcols', label = 'fx columns', kind = 'num', min = 1, max = 4, desc = 'effect command columns per subcolumn', get = function() return state.fxcols end, set = function(v) state.fxcols = math.floor(v) end },
      { sep = true },
      { key = 'wave', label = 'wave column', kind = 'toggle', desc = 'spectral peaks + stretch markers left of the note', get = function() return state.wave ~= 'off' end, set = function(v) state.wave = v and 'spec' or 'off' end },
      { key = 'wave_os', label = 'wave detail', kind = 'cycle', values = { 1, 2, 4 }, desc = 'peaks per pixel (track column and sample view); higher = finer, slower', get = function() return state.wave_os or 1 end, set = function(v) state.wave_os = v; model.OVERSAMPLE = v; model.clear_peaks() end },
      flag('xfade', 'x-fade inserted notes', 'crossfade at the cut instead of a hard cut'),
      { key = 'xfade_ms', label = 'x-fade length ms', kind = 'num', min = 1, max = 500, step = 1, desc = 'crossfade length', get = function() return state.xfade_ms or 1 end, set = function(v) state.xfade_ms = v; if ctx.xfade_len then ctx.xfade_len(0, v) end end },
      flag('autosync', 'auto sync aliases', 'edits in a pattern copy to its aliases (same region name)'),
      flag('preview', 'preview on insert', 'audition the note when inserting'),
      flag('poolprev', 'preview on select', 'audition the instrument when selected'),
      { key = 'poolsort', label = 'instrument order', kind = 'cycle', values = { 'track', 'len', 'mark' }, desc = 'track groups / by length / by marks @ $ *', get = function() return state.poolsort or 'track' end, set = function(v) state.poolsort = v end },
      { sep = true },
      flag('meters', 'peak meters', 'meters over the columns'),
      flag('top', 'top panel', 'control / sample / instruments'),
      flag('side', 'browser sidebar', 'files / db / pm / proj'),
      flag('dsp', 'dsp panel', 'track fx at the bottom'),
      flag('icons', 'nerd icons', 'icons on buttons (TTF font only)'),
      { key = 'scale', label = 'bitmap scale', kind = 'num', min = 1, max = 4, desc = 'x1..x4 (Ctrl +/-)', get = function() return math.floor(state.fontscale or 2) end, set = function(v) ctx.set_scale(math.floor(v)) end },
      { key = 'font', label = 'ttf font size', kind = 'num', min = 0, max = 40, desc = '0 = bitmap font; N = Nerd font size', get = function() return state.font or 0 end, set = function(v) ctx.set_font(math.floor(v)) end },
      { sep = true },
      { key = 'about', label = 'about  v' .. VER.VERSION, kind = 'about', desc = 'version and changes (' .. VER.DATE .. ')', get = function() return VER.VERSION end, set = function() end },
    }
    OPT.open(items, VER.lines())
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
  -- запись: arm трека курсора, выбор входа, умный выбор входа (jf_smart_set_input)
  rec_arm = function()
    local col = cur_col(); if not col then return end
    edit.run('rec arm', function() reaper.SetMediaTrackInfo_Value(col.track, 'I_RECARM', col.armed and 0 or 1) end)
  end,
  smart_input = function()
    local col = cur_col(); if not col then return end
    reaper.SetOnlyTrackSelected(col.track)
    local path = os.getenv('HOME') .. '/code/reascript/jf_smart-input-select/jf_smart_set_input.lua'
    local ok, e = pcall(dofile, path)
    vim.msg = ok and 'smart input set' or ('smart input: ' .. tostring(e):match('[^\n]*$'))
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
  add_to_depot = function(path)
    local c = cur_col()
    local it = edit.depot_add(path, c and c.track)
    vim.msg = it and ('→ lib ' .. (c and c.name or 'DEPOT') .. ': ' .. path:match('[^/]+$')) or 'depot add failed'
  end,
  -- drag & drop из браузера: файл → item / .rpp → сабпроект на трек в строке
  drop_to = function(fi, row, path)
    local f = L.flat[fi]; if not f or not f.col or f.folded then return end
    local it = edit.drop(f.col.track, f.col.fixed and f.lane and f.lane.idx or nil, state.lpb, row, path)
    vim.msg = it and ('dropped ' .. (path:match('[^/]+$') or path) .. ' → ' .. f.col.name) or 'drop failed'
  end,
  drop_at_cursor = function(path) ctx.drop_to(vim.cur.fi, vim.cur.row, path) end,
  file_peaks = function(path, npix) return model.file_peaks(path, npix) end,
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
  depot_span = function(entry, a, b)
    local c = cur_col(); if not c then return end
    local it = edit.depot_span(c.track, entry, a, b)
    vim.msg = it and ('span %.2fs → depot of %s (=LIB)'):format(b - a, c.name) or 'depot: failed'
    model.invalidate()
  end,
  -- файл браузера в сэмпл-модуле
  sample_view = function(path)
    state.top = true; state.toptab = 'sample'
    local c = cur_col()
    if SL.open_file(path, c and c.track) then vim.msg = 'sample: ' .. (path:match('[^/]+$') or path) end
  end,
  preview_file = function(path, sec)
    local c = cur_col(); PV.file(c and c.track, path, sec or 1.0)
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
  set_focus = function(f)
    if f == 'matrix' and #seq == 0 then f = 'tracker' end
    if f == 'browser' and not state.side then f = 'tracker' end
    if f == 'top' and not state.top then f = 'tracker' end
    if f == 'dsp' and not state.dsp then f = 'tracker' end
    if f == 'inst' and not state.top then f = 'tracker' end
    if state.focus == 'top' and f ~= 'top' and SL.active then SL.close() end
    state.focus = f
    MX.focus = f == 'matrix'; B.focus = f == 'browser'
    if f == 'top' and state.toptab == 'sample' and not SL.active then ctx.open_slicer() end
  end,
  -- Tab — вперёд по кругу, Shift-Tab — назад (dir = -1)
  toggle_focus = function(dir)
    dir = dir or 1
    -- по часовой (2 окт): трекер → инструменты → браузер → DSP → матрица → верхний док → трекер
    local order = { 'tracker' }
    if state.top or state.side then order[#order + 1] = 'inst' end
    if state.side then order[#order + 1] = 'browser' end
    if state.dsp then order[#order + 1] = 'dsp' end
    if not state.mx_hidden then order[#order + 1] = 'matrix' end
    if state.top then order[#order + 1] = 'top' end
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
      { key = 'e', label = 'event / selection', sub = function() return group('event', event_actions(hover)) end },
      { key = 't', label = 'track' .. (col and (': ' .. col.name) or ''), sub = function() return col and group('track ' .. col.name, track_actions(col)) or { title = 'track', items = {} } end },
      { key = 'p', label = 'pattern' .. (rg and (': ' .. rg.name) or ''), sub = function() return group('pattern', region_actions(rg)) end },
      { key = 'v', label = 'view', sub = function() return group('view', view_actions()) end },
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
      { key = 'i', label = 'instrument (pool)', sub = function()
          local it = {}
          for i, e in ipairs(col and col.pool or {}) do
            if i <= 10 then it[#it + 1] = { key = tostring(i % 10), label = e.name .. (e.slices and (' [' .. #e.slices .. ' sl]') or ''), fn = function() pool_select(i) end } end
          end
          it[#it + 1] = { key = 's', label = 'slice current instrument …', fn = function() ctx.open_slicer() end }
          return { title = 'instrument', items = it }
        end },
      { key = 'f', label = 'add FX (fzf by all installed) …', fn = ctx.fx_picker },
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
      { key = ':', label = 'command line', fn = function() vim.mode = 'cmd'; vim.cmdline = '' end },
      { key = '/', label = 'search', fn = function() vim.mode = 'search'; vim.searchline = '' end },
      { key = '?', label = 'keys cheat sheet', sub = function() return ctx.hydra_keys() end },
    }
    return { title = '\\ actions', items = items }
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
  if not state.autosync or not regions or #regions == 0 then return end
  if desc:match('^sync') or desc:match('^pattern copy') or desc:match('^matrix') or desc:match('^depot') then return end
  local rg = alias.region_at(regions, edit.row_time(vim.cur.row, state.lpb, 0))
  if rg then alias.sync(regions, rg) end
  -- жёсткие границы: после любой правки items не вылезают из своих регионов
  alias.trim(regions)
end
draw.init(U, model.peaks, MX)
OPT.init(U, ctx)
draw.hint = HN.add
ctx.hint = HN.add
ctx.env_colour = draw.env_colour
ctx.ic = function(name, text) return draw.ic(name, text) end
ctx.icons_on = function() return draw.icons and not draw.hybrid and (state.font or 0) > 0 end
vim.init(ctx)
MX.init(U, ctx)
B.init(ctx, (ext('browse', '') ~= '' and ext('browse', '')) or nil)
SL.init(ctx)
MMX.init(U, ctx)
GD.init(U, ctx)
SPROP.init(U, ctx)

-- ── прыжок по подсказке (f + метка) ───────────────────────────────────────
local function hint_go(t)
  local d = t.data
  if t.kind == 'bar' then ctx.set_focus('tracker'); vim.cur.fi, vim.cur.row = d.fi, d.row; vim.cur.field = 1; state.row0 = math.max(0, math.min(state.row0, d.row))
  elseif t.kind == 'env' then ctx.set_focus('tracker'); vim.cur.fi = d; vim.cur.field = 1
  elseif t.kind == 'header' or t.kind == 'scope' then
    ctx.set_focus('tracker')
    for i, f in ipairs(L.flat) do if f.col == d then vim.cur.fi = i; break end end
  elseif t.kind == 'btn' and d.what == 'auto' then ctx.toggle_track_envs(d.col)
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
    if d == 'zoom' then ctx.mx_zoom() elseif d == 'fill' then MX.fill = not MX.fill elseif d == 'sync' then ctx.sync_here() elseif d == 'add' then ctx.mx_add() elseif d == 'trim' then ctx.mx_trim() end
  elseif t.kind == 'sidectl' then if d == 'open' then state.side = true elseif d == 'close' then ctx.side_hide() end
  elseif t.kind == 'mxctl' then if d == 'open' then state.mx_hidden = false elseif d == 'close' then state.mx_hidden = true end
  elseif t.kind == 'rglen' then ctx.region_len_step(d)
  elseif t.kind == 'lanebtn' then ctx.lane_subs(d.col, d.lane, d.d, d.n)
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
    elseif d == 'put' then retro_put('cursor') elseif d == 'depot' then retro_put('depot') elseif d == 'add' then ctx.retro_add() end
  elseif t.kind == 'retro' then ctx.set_focus('top'); state.toptab = 'retro'
  elseif t.kind == 'ctrl' then ctrl_action(d, 0)
  elseif t.kind == 'pool' then pool_select(d)
  elseif t.kind == 'prevbtn' then state.poolprev = not state.poolprev
  elseif t.kind == 'insprevbtn' then state.preview = not state.preview; vim.msg = 'play on insert ' .. (state.preview and 'on' or 'off')
  elseif t.kind == 'mod' then ctx.set_focus('top'); ctx.mod_toggle(d.col, d.m, d.what)
  elseif t.kind == 'dsp' then ctx.set_focus('dsp'); dsp_sel.fx = d.fx; dsp_sel.param = 1
  elseif t.kind == 'dspparam' then ctx.set_focus('dsp'); dsp_sel.fx = d.fx; dsp_sel.param = d.param
  elseif t.kind == 'browser' then ctx.set_focus('browser'); B.cur = d
  elseif t.kind == 'browserbtn' then B.click(d)
  end
end

-- ── контекстное меню (правый клик) ────────────────────────────────────────
-- Пункты зависят от зоны: событие / пустая ячейка / выделение / заголовок
-- трека / матрица / пул. Разделителей нет — индексы gfx.showmenu прямые.
local function track_actions(col)
  local tr = col.track
  return {
    { 'Mute track', key = 'm', fn = function() edit.run('track mute', function() reaper.SetMediaTrackInfo_Value(tr, 'B_MUTE', reaper.GetMediaTrackInfo_Value(tr, 'B_MUTE') == 1 and 0 or 1) end) end },
    { 'Solo track', key = 's', fn = function() edit.run('track solo', function() reaper.SetMediaTrackInfo_Value(tr, 'I_SOLO', reaper.GetMediaTrackInfo_Value(tr, 'I_SOLO') > 0 and 0 or 1) end) end },
    { (state.folds[col.guid] and 'Unfold' or 'Fold') .. ' track (za)', key = 'f', fn = function() ctx.fold(col, not state.folds[col.guid]) end },
    { 'Select track in REAPER', key = 'l', fn = function() reaper.SetOnlyTrackSelected(tr) end },
    { (state.pitchmodes[col.guid] == 'resample' and '!' or '') .. 'Pitch mode: resample', key = 'r', fn = function() ctx.set_pitchmode(col, 'resample') end },
    { (state.pitchmodes[col.guid] ~= 'resample' and '!' or '') .. 'Pitch mode: shift', key = 'h', fn = function() ctx.set_pitchmode(col, 'shift') end },
  }
end
-- mute-track пункт: fn в поле .fn (см. выше), остальные — тоже


local function region_actions(rg)
  if not rg then return {} end
  return {
    { 'Queue / play region (Space)', key = 'q', fn = function() ctx.region_space(rg) end },
    { 'Jump now', key = 'j', fn = function() reaper.SetEditCurPos(rg.pos, false, true) end },
    { 'Mute cell (m)', key = 'm', fn = function() MX.toggle_mute(seq, snap) end },
    { 'Next pattern in slot (>)', key = 'n', fn = function() for i, r in ipairs(seq) do if r.idx == rg.idx then ctx.slot_cycle(i, 1) end end end },
    { 'Previous pattern in slot (<)', key = 'b', fn = function() for i, r in ipairs(seq) do if r.idx == rg.idx then ctx.slot_cycle(i, -1) end end end },
    { 'Yank pattern (y)', key = 'y', fn = function() ctx.alias_yank(rg) end },
    { 'Paste pattern copy at end (p)', key = 'p', fn = function() ctx.alias_paste() end },
    { 'Sync this pattern', key = 's', fn = function() edit.run('sync ' .. rg.name, function() alias.sync(regions, rg) end) end },
    { 'Matrix zoom (z)', key = 'z', fn = ctx.mx_zoom },
  }
end

-- действия над событием/выделением у курсора (или hover): {label, fn, key}
local function event_actions(hover)
  local lpb = state.lpb
  local sel = vim.mode == 'visual' or vim.mode == 'vline'
  local out = {}
  local function add(label, fn, key) out[#out + 1] = { label, fn = fn, key = key } end
  local f0, f1, r0, r1 = vim.cur.fi, vim.cur.fi, vim.cur.row, vim.cur.row
  if sel then f0, f1, r0, r1 = vim.visual_range() end
  local heads = vim.heads_in(f0, f1, r0, r1)
  local cell = hover.cell
  local head = cell and (cell.kind == 'audio' or cell.kind == 'midi') and cell or (cell and cell.of)
  if head and head.item then
    add(head.kind == 'audio' and 'Item properties' or 'Open in MIDI editor', function()
      select_item_in_reaper(head.item)
      reaper.Main_OnCommand(head.kind == 'audio' and 40009 or 40153, 0)
    end, 'i')
    add('Select item in REAPER', function() select_item_in_reaper(head.item) end, 'l')
  end
  local what = sel and 'selection' or 'event'
  if #heads > 0 or sel then
    add('Delete ' .. what .. ' (x)', function() vim.regs['"'] = edit.yank(heads, lpb, r0, f0); edit.delete(heads, lpb) end, 'x')
    add('Copy ' .. what .. ' (y)', function() vim.regs['"'] = edit.yank(heads, lpb, r0, f0) end, 'y')
    add('Mute ' .. what .. ' (m)', function() edit.mute(heads, lpb) end, 'm')
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

local function view_actions()
  return {
    { (state.top and '!' or '') .. 'Top bar (:top)', key = 'p', fn = function() state.top = not state.top end },
    { (state.meters and '!' or '') .. 'Peak meters over tracks (:meters)', key = 'm', fn = function() state.meters = not state.meters end },
    { (state.scopes and '!' or '') .. 'Oscilloscopes via JSFX bridge (:scopes)', key = 'o', fn = ctx.toggle_scopes },
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
    { 'Help (F1)', key = 'h', fn = open_help },
  }
end

local function context_menu(hover)
  local items = {}
  local function add(label, fn, key) items[#items + 1] = { label, fn, key = key } end
  local sel = vim.mode == 'visual' or vim.mode == 'vline'
  local lpb = state.lpb
  if hover.matrix and hover.matrix.ri then
    MX.goto_cell(seq, snap, hover.matrix.ri, hover.matrix.ci or MX.cur.ci)
    for _, a in ipairs(region_actions(seq[hover.matrix.ri])) do add(a[1], a.fn, a.key) end
  elseif hover.pool then
    local col = cur_col()
    add('Select instrument', function() pool_select(hover.pool.i) end)
    add('Preview', function() local e = col and col.pool[hover.pool.i]; if e then PV.audio(col.track, e.item, 0, 1.0) end end)
    add('Slice … (virtual)', function() ctx.open_slicer(hover.pool.i) end)
    add((state.poolprev and '!' or '') .. 'Preview on select', function() state.poolprev = not state.poolprev end)
    add('Hide top bar (:top)', function() state.top = false end)
  elseif hover.header_col then
    for _, a in ipairs(track_actions(hover.header_col)) do add(a[1], a.fn, a.key) end
  elseif hover.dsp then
    -- DSP: модуляция параметра (нативные свойства REAPER) и действия с FX
    local col = cur_col()
    local f, pidx = hover.dsp.f, hover.dsp.param
    local p = pidx and f.params[pidx]
    if col and p then
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
      add('--', function() end)
    end
    if col and f then
      add((f.enabled and 'Bypass' or 'Enable') .. ' ' .. f.name, function() edit.fx_bypass(col.track, f.i) end)
      add('Open FX window', function() edit.fx_show(col.track, f.i) end)
      add('Remove FX', function() edit.fx_remove(col.track, f.i) end)
      add('Add FX … (fzf)', function() ctx.fx_picker() end)
    end
  elseif hover.row and hover.fi then
    vim.cur.fi, vim.cur.row = hover.fi, hover.row.row
    if hover.field then vim.cur.field = hover.field end
    for _, a in ipairs(event_actions(hover)) do add(a[1], a.fn, a.key) end
    if hover.col then for _, a in ipairs(track_actions(hover.col)) do add(a[1], a.fn, a.key) end end
  else
    for _, a in ipairs(view_actions()) do add(a[1], a.fn, a.key) end
  end
  if #items == 0 then return end
  local labels = {}
  for i, it in ipairs(items) do labels[i] = it[1] end
  gfx.x, gfx.y = gfx.mouse_x, gfx.mouse_y
  local r = gfx.showmenu(table.concat(labels, '|'))
  if r > 0 and items[r] then
    local ok, e = pcall(items[r][2])
    if not ok then vim.msg = tostring(e):match('[^\n]*$') end
  end
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
          local idx = d1 - 59
          if idx >= 1 and idx <= #e.slices then
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
    if kind and dev_ok and ch_ok then
      if kind == 0x90 and d2 > 0 then
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
        edit.rec_note(col.track, lane_idx, state.lpb, midiin.row, d1, d2, math.max(1, vim.step))
        vim.msg = ('rec %s vel %d'):format(model.note_name(d1), d2)
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
local function expect_put(track, pos)
  local before = {}
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do before[reaper.GetTrackMediaItem(track, i)] = true end
  put_pending[#put_pending + 1] = { track = track, pos = pos, before = before, t = reaper.time_precise() }
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
local MONO_ID = 9
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
local function mono_request(id)
  with_ns('jf_mono', function() reaper.gmem_write(2, id) end)
  vim.msg = id == MONO_ID and 'mono: requested surface for tracker' or 'mono: surface back to GRID'
end

-- ── ретро-сэмплер jf_rec: карта gmem см. Effects/jf_rec.jsfx ─────────────
-- Владелец зеркала — слот, записанный в gmem[26]; экранный слой шириной
-- gmem[4] лежит в 1000000 (max) / 1050000 (min) по индексу кольца; почтовый
-- ящик вставки 10..15 (трек, позиция, старт/длина в сэмплах), превью 16..18.
local retro = { sel = { a = 0.5, b = 1.0 }, cur = nil, msg = '', peaks_t = 0, alive_t = 0, put_t = nil, drag = nil, pb_t = 0 }
local function retro_tracks()
  local out = {}
  for _, col in ipairs(snap and snap.cols or {}) do if col.rec_slot then out[#out + 1] = col end end
  return out
end
local function retro_current()
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
  return { tracks = trs, cur = c, sel = retro.sel, msg = retro.msg }
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
local function retro_preview(on)
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

local function retro_put(target, raw)
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
    pos = edit.ensure_lib()
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, i)
      local e = reaper.GetMediaItemInfo_Value(it, 'D_POSITION') + reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
      if e > pos then pos = e end
    end
  else
    pos = edit.row_time(vim.cur.row, state.lpb, 0)
  end
  local tnum = math.floor(reaper.GetMediaTrackInfo_Value(tr, 'IP_TRACKNUMBER')) - 1
  expect_put(tr, pos)
  with_ns('jf_rec', function()
    reaper.gmem_write(11, tnum); reaper.gmem_write(12, pos)
    reaper.gmem_write(13, start); reaper.gmem_write(14, samps); reaper.gmem_write(15, 0)
    reaper.gmem_write(10, 1)
  end)
  retro.put_t = reaper.time_precise()
  retro.msg = ('retro: %.2fs → %s @ %.2fs'):format(samps / c.srate, target == 'depot' and 'depot (=LIB)' or c.col.name, pos)
  vim.msg = retro.msg
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
local function ctrl_action(name, delta)
  local col = cur_col()
  if name == 'options' then if delta == 0 then ctx.options() end
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
    -- клик — auto on/off (шаг = до конца вставленного item / слайса), колесо — число
    if delta == 0 then vim.step_auto = not vim.step_auto
    else vim.step = math.max(0, vim.step + delta); vim.step_auto = false end
  elseif name == 'inst' then pool_select(vim.inst + (delta ~= 0 and delta or 1))
  elseif name == 'follow' then state.follow = not state.follow
  elseif name == 'lock' then state.lock = not state.lock; lock_sync = {}; vim.msg = 'lock to REAPER cursor: ' .. (state.lock and 'on' or 'off')
  elseif name == 'fixed' then state.fixed = not state.fixed; vim.msg = 'fixed cursor (centre): ' .. (state.fixed and 'on' or 'off')
  elseif name == 'wave' then ctx.wave_mode(nil, delta)
  elseif name == 'xfade' then if delta ~= 0 then ctx.xfade_len(delta) else ctx.xfade_toggle() end
  elseif name == 'loop' then reaper.GetSetRepeat(2)
  elseif name == 'pitch' then
    if col then ctx.set_pitchmode(col, state.pitchmodes[col.guid] == 'resample' and 'shift' or 'resample') end
  elseif name == 'font' then
    if (state.font or 0) == 0 then ctx.set_scale(math.max(1, math.min(4, math.floor(state.fontscale) + (delta ~= 0 and delta or 1))))
    else ctx.set_font(math.max(0, state.font + (delta ~= 0 and delta or 1))) end
  elseif name == 'fx' then state.fxcols = math.max(0, math.min(4, state.fxcols + (delta ~= 0 and delta or 1)))
  elseif name == 'meters' then state.meters = not state.meters
  end
end

local env_cache = {}
local function env_values(e)
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
  local name = v:match('^([%w%+%-]+)')
  if name == 'play' then edit.play_stop()
  elseif name == 'stop' then reaper.OnStopButton()
  elseif name == 'rec' then reaper.Main_OnCommand(1013, 0)
  elseif name == 'follow' then state.follow = not state.follow
  elseif name == 'lock' then state.lock = not state.lock; lock_sync = {}; vim.msg = 'lock to REAPER cursor: ' .. (state.lock and 'on' or 'off')
  elseif name == 'loop' then reaper.GetSetRepeat(2)
  elseif name == 'lpb+' then set_lpb(nil, 1) elseif name == 'lpb-' then set_lpb(nil, -1)
  elseif name == 'oct+' then vim.octave = math.min(8, vim.octave + 1) elseif name == 'oct-' then vim.octave = math.max(0, vim.octave - 1)
  elseif name == 'step+' then vim.step = vim.step + 1 elseif name == 'step-' then vim.step = math.max(0, vim.step - 1)
  elseif name == 'inst+' then pool_select(vim.inst + 1) elseif name == 'inst-' then pool_select(vim.inst - 1)
  end
end

local function poll_gridkey()
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
  local t_0 = reaper.time_precise()
  U.begin_frame()
  PV.tick()
  env_cache = {}; peak_cache = {}; scope_cache = {}; spec_cache = {}; fxv_cache = {}
  local is_playing = playing()
  local playpos = is_playing and reaper.GetPlayPosition() or nil
  local curpos = reaper.GetCursorPosition()
  local changed
  snap, changed = model.snapshot(state.lpb)
  draw.inst_of = snap and snap.inst_of
  regions = model.regions(state.lpb)
  seq = ctx.sequence()
  local t_1 = reaper.time_precise()
  relayout()
  local t_2 = reaper.time_precise()
  if playpos then process_queue(playpos); process_jumps(playpos); process_orca(playpos) else jump_row_done = nil; orca_row_done = nil end
  publish_matrix(playpos); publish_state(is_playing); poll_gridkey(); poll_cmd(); poll_midi_in(); poll_audio_in(reaper.time_precise()); settle_puts(reaper.time_precise())

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

  -- fixed cursor: вид всегда ставит строку курсора в середину тела
  if state.fixed and L and L.nrows then
    state.row0 = vim.cur.row - math.floor(L.nrows / 2)
  end
  local ph_row = playpos and model.row_of_time(playpos, state.lpb) or nil
  if is_playing and state.follow and ph_row then
    local r = math.floor(ph_row)
    if r < state.row0 or r > state.row0 + math.floor(L.nrows * 2 / 3) then
      state.row0 = math.max(0, r - math.floor(L.nrows / 3))
    end
  end
  rows = model.rows(state.row0, L.nrows, state.lpb)

  fps.n = fps.n + 1
  local now = reaper.time_precise()
  if now - fps.t >= 1 then
    fps.v = fps.n / (now - fps.t); fps.n = 0; fps.t = now
    local n = math.max(1, prof.n)
    reaper.SetExtState(EXT, 'hb', string.format('%s %d %s/%s x' .. tostring(state.fontscale) .. ' %.0ffps snap %.1f layout %.1f draw %.1f upd %.1f ms',
      os.date('%H:%M:%S'), #snap.cols, vim.mode, state.focus, fps.v,
      prof.snap / n * 1000, prof.layout / n * 1000, prof.draw / n * 1000, prof.upd / n * 1000), false)
    prof.snap, prof.layout, prof.draw, prof.upd, prof.n = 0, 0, 0, 0, 0
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
    left = left .. string.format(' | %.0f fps | key %d | peaks %d', fps.v, state.last_key, model.peaks_cache_size())
  end

  local vis
  if vim.mode == 'visual' or vim.mode == 'vline' then
    local f0, f1, r0, r1 = vim.visual_range()
    vis = { f0 = f0, f1 = f1, r0 = r0, r1 = r1 }
  end
  HN.reset()
  edit.xfade.on, edit.xfade.len = state.xfade, (state.xfade_ms or 10) / 1000
  draw.icons = state.icons and true or false
  draw.hybrid = state.icons and (state.font or 0) == 0   -- битмап-текст + Nerd-глифы
  local hover = draw.frame(L, snap, rows, state, {
    ph_row = ph_row, cur_row = model.row_of_time(curpos, state.lpb), playing = is_playing,
    status_left = left, status_right = state.status,
    vcur = vim.cur, vis = vis, focus = state.focus, regions = seq, vmode = vim.mode,
    cur_ci = (L.flat[vim.cur.fi] or {}).ci,
    pat_num = function(rg) local _, by = model.patterns(regions); local p = by[rg.name]; return p and p.num or rg.idx end,
    env_values = env_values, pool_col = cur_col(), inst = vim.inst,
    pool_ci = (L.flat[vim.cur.fi] or {}).ci, cols = snap.cols, peaks = track_peaks, poolsort = state.poolsort,
    cur_region = alias.region_at(regions, edit.row_time(vim.cur.row, state.lpb, 0)),
    scope = state.scopes and scope_read or nil,
    spec = state.scopes and spec_read or nil, spec_frame = spec_frame, scopemode = state.scopemode,
    mono = state.top and mono_read() or nil,
    master = (state.top and (state.toptab == 'master' or state.toptab == 'scope') and snap.master) and {
      peaks = { reaper.Track_GetPeakInfo(snap.master.track, 0), reaper.Track_GetPeakInfo(snap.master.track, 1) },
      scope_slot = snap.master.scope_slot, fx = snap.master.fx } or nil,
    retro = (state.top and state.toptab == 'retro') and retro_read(math.max(16, math.floor(gfx.w - L.ctrl_w - L.inst_w - 4 * L.pad))) or nil,
    dsp_sel = state.focus == 'dsp' and dsp_sel or nil,
    fx_values = function(f) local col = cur_col(); if not col then return {} end
      local v = fxv_cache[f]; if not v then v = model.fx_values(col.track, f); fxv_cache[f] = v end; return v end,
    ctrl = {
      playing = is_playing, pos = fmt_pos(playpos or curpos), bpm = reaper.Master_GetTempo(),
      lpb = state.lpb, oct = vim.octave, vel = vim.vel, step = vim.step_auto and 'auto' or vim.step, inst = vim.inst,
      follow = state.follow, lock = state.lock, fixed = state.fixed, loop = reaper.GetSetRepeat(-1) == 1,
      pitchmode = (cur_col() and state.pitchmodes[cur_col().guid]) or 'shift',
      font = state.font, scale = state.fontscale, fx = state.fxcols, meters = state.meters, wave = state.wave,
      xfade = state.xfade, xfade_ms = state.xfade_ms,
    },
    toptab = state.toptab, modsel = modsel, poolprev = state.poolprev,
    inspreview = state.preview,
    trs_live = trs_drag and trs_drag.v and { guid = trs_drag.col.guid, what = trs_drag.what, v = trs_drag.v } or nil,
    garden_draw = function(Lx, x, y, w, h)
      return GD.draw(Lx, x, y, w, h, snap, seq, { play_row = ph_row, queued = MX.queued, garden_on = garden.f and garden.f.on },
                     state.focus == 'top' and state.toptab == 'garden')
    end,
    mm_draw = function(Lx, x, y, w, h)
      local col = cur_col()
      return MMX.draw(Lx, x, y, w, h, col and col.mods or {}, state.focus == 'top', col and (col.name .. ' modulation') or 'modulation')
    end,
    sample_draw = function(x, y, w, h)
      local col = cur_col()
      local e = col and (col.pool or {})[vim.inst]
      -- файл из браузера (v / Space / auto) показывается вместо инструмента
      if SL.entry and SL.entry.file then e = SL.entry end
      -- слайс / кусок: показываем исходник (родителя) с подсветкой играемой зоны
      local sel_e = e
      local zone
      if e and e.parent and not (SL.active and SL.entry == e) then
        local p = e.parent
        zone = { (e.offs - p.offs) / (p.rate ~= 0 and p.rate or 1), (e.offs - p.offs + e.len * e.rate) / (p.rate ~= 0 and p.rate or 1), vim.inst }
        e = p
      end
      -- справа — панель свойств выбранного в списке (исходник или слайс), как в Renoise
      local pw = (sel_e and not sel_e.file) and math.min(L.cw * 30, math.floor(w * 0.34)) or 0
      if pw > L.cw * 12 then
        SPROP.draw(L, x + w - pw, y, pw, h, sel_e, state.focus == 'top')
      else pw = 0; SPROP.hover = nil end
      return SL.draw_in(U, L, x, y, w - (pw > 0 and pw + L.pad or 0), h, e, col and col.track, zone)
    end,
    browser_draw = state.side and function(Lx, x, y, w, h) return B.draw(U, Lx, x, y, w, h) end or nil,
  })

  HN.draw(U, L)
  B.draw_drag(U, L)
  if dsp_drag and dsp_drag.active then draw.ghost(dsp_drag.f.name) end
  SL.draw_drag(U, L)
  draw.popup(L, vim.popup())
  if OPT.active then OPT.draw(L, gfx.w, gfx.h) end

  -- наведение
  local cell = hover.cell
  if cell and (cell.kind == 'cont' or cell.kind == 'off') then cell = cell.of end
  if cell and cell.kind == 'audio' then
    state.status = string.format('%s  %s vol %s  offs %.3fs  len %.3fs  rate %.3f  %s',
      cell.name, cell.note, cell.vol, cell.offs, cell.len, cell.rate, table.concat(cell.fx or {}, ' '))
  elseif cell and cell.kind == 'midi' then
    state.status = string.format('MIDI %s vel %s ch %d%s', cell.note, cell.vol, cell.ch + 1, cell.muted and '  muted' or '')
  elseif hover.env then state.status = ('%s %s  %.0f%%'):format(hover.col and hover.col.name or '', hover.env.name, (hover.envv and hover.envv.v or 0) * 100)
  elseif hover.dsp then state.status = hover.dsp.f.name .. (hover.dsp.param and ('  ' .. hover.dsp.f.params[hover.dsp.param].name .. ' - drag: value, rclick: modulate (LFO / ACS / link)') or '  (dblclick: window, rclick: menu)') .. (hover.dsp.f.container and '  [container: | serial = parallel + sum]' or '')
  elseif hover.mod then state.status = hover.mod.m.fxname .. ' / ' .. hover.mod.m.pname .. ': toggle ' .. hover.mod.what
  elseif hover.garden and hover.garden.ri then
    local rg = seq[hover.garden.ri]; local col = snap.cols[hover.garden.ci]
    state.status = ('garden: %s x %s - digits+Enter / > loop N steps, < region to item end, +/- or wheel: period, m mute, Enter/Space queue, o Orca field'):format(rg and (rg.gap and 'bar' or rg.name) or '?', col and col.name or '?')
  elseif hover.garden and hover.garden.ox then
    local ch = garden.f and garden.f.cells[hover.garden.oy][hover.garden.ox] or '.'
    state.status = ('orca (%d,%d) %s'):format(hover.garden.ox, hover.garden.oy, ORCA.DOC[ch] or ORCA.DOC[ch:upper()] or 'click to place the cursor, type to write')
  elseif hover.mm then
    local c = MMX.COLS[hover.mm.col]
    local hints = { name = 'parameter - dblclick / o: FX window, w: native modulation window', num = 'value - wheel / + - (Shift ×10)', toggle = 'on/off - click twice / Enter', enum = 'LFO shape - Enter / wheel', link = 'link source - Enter: pick parameter (fzf)' }
    state.status = (c and c.head or '') .. ': ' .. (c and hints[c.kind] or '') .. '   a: add parameter, x: remove'
  elseif hover.scopemode then state.status = ({ scope = 'oscilloscope (ring 256 samples, 8 kHz)', spec = 'spectrum analyzer: 48 log bands 30 Hz..Nyquist, -60..0 dB', sgram = 'spectrogram: time → right, 48 bands, heat = level' })[hover.scopemode] .. ' (:scopemode)'
  elseif hover.monobtn then state.status = hover.monobtn == 'take' and 'monome: give the surface to the tracker module (gmem jf_mono[2] = 9)' or 'monome: return the surface to the GRID mixer mod'
  elseif hover.retrobtn then state.status = ({ prev = 'previous track with jf_rec', next = 'next track with jf_rec', all = 'select whole buffer (a)', play = 'preview selection (Space)', stop = 'stop preview (s)', put = 'put selection on this track at the cursor row (p)', depot = 'put selection into the track depot after =LIB - then slice it in the sample tab (d)', add = 'add jf_rec (40 s ring buffer) to the cursor track' })[hover.retrobtn] or hover.retrobtn
  elseif hover.retro then state.status = ('retro buffer: drag to select, click: set start · %.0f%% of ring'):format(hover.retro * 100)
  elseif hover.tab then state.status = ({ scope = 'oscilloscopes / spectrum of all tracks', sample = 'sample editor: slices, selection, drag to track', modulation = 'native parameter modulation of the cursor track', retro = 'retro sampler: 40 s ring buffers (jf_rec), put / to depot', master = 'master track: meters, analyzer, fx chain' })[hover.tab] or ('tab: ' .. hover.tab)
  elseif hover.rglen then state.status = 'cursor region length in steps - < > or wheel: +-1 step; later regions and items ripple (:len N)'
  elseif hover.matrix and hover.matrix.name then state.status = 'region name - click: select slot, dblclick: rename (:name text, n)'
  elseif hover.matrix and hover.matrix.dur then state.status = 'region length in steps - click: change (:len N, =); later regions and items ripple'
  elseif hover.matrix and hover.matrix.btn == 'add' then state.status = 'new region after the last one, from the next bar; then name it (+, :add [bars] [name])'
  elseif hover.prevbtn then state.status = 'select: play the sample when an instrument is selected - ' .. (state.poolprev and 'on' or 'off') .. ' (:poolprev)'
  elseif hover.poolfind then state.status = 'find instrument (fzf) - also / when the instruments have focus'
  elseif hover.insprevbtn then state.status = 'insert: play the sample when a note is inserted - ' .. (state.preview and 'on' or 'off') .. ' (Shift+note always just plays)'
  elseif hover.poolsort then state.status = 'instrument order: track (groups by first track, then length) / len / mark (@ $ *) - click to cycle; numbers stay'
  elseif hover.poolmark then
    local e, parts = hover.poolmark.e, {}
    parts[#parts + 1] = hover.poolmark.here and '@ = used on the cursor track' or '(no @: not on the cursor track)'
    if e.slices then parts[#parts + 1] = ('$ = sliced (%d slices)'):format(#e.slices) end
    parts[#parts + 1] = 'stored on ' .. tostring(e.home) .. (hover.poolmark.lib and ' (library after =LIB)' or '')
    if e.parent then parts[#parts + 1] = ('s%s = slice of %s (%.3f-%.3fs of its source)'):format(e.slice_k and tostring(e.slice_k) or '?', e.parent.name, (e.offs - e.parent.offs) / (e.parent.rate ~= 0 and e.parent.rate or 1), (e.offs - e.parent.offs + e.len * e.rate) / (e.parent.rate ~= 0 and e.parent.rate or 1)) end
    state.status = table.concat(parts, '   ')
  elseif hover.caption then state.status = ({
    wave = 'wv: spectral peaks of the item (colour = frequency), amber ticks = stretch markers - :wave on|off',
    note = 'nt: note - audio: pitch from C-4 (D_PITCH / playrate), MIDI: note; ` = note-off',
    vol = 'vl: volume / velocity, hex 00..FF (80 = unity)',
    delay = 'dl: delay inside the row, hex xx/256 of a row',
    fx = 'fx: effect command, letter + hex hex (9xx offset, Sxx slice, Bxx beatsync ...)',
    env = 'env: envelope value at the row (bar + hex); INSERT edits points, :ramp / :fade',
  })[hover.caption] or hover.caption
  elseif hover.ctrl == 'xfade' then state.status = 'x-fade of inserted notes: click on/off, wheel: length (ms); off = overlaps without crossfade; \\x: menu'
  elseif hover.ctrl == 'fixed' then state.status = 'fixed cursor: the cursor row stays in the middle of the screen, the pattern scrolls under it (Impulse Tracker)'
  elseif hover.ctrl == 'lock' then state.status = 'lock: tracker cursor mirrors REAPER edit cursor and selected track (both ways); follow = view follows playhead'
  elseif hover.ctrl == 'options' then state.status = 'all tracker options in one window (:options, \\o)'
  elseif hover.ctrl == 'vel' then state.status = 'velocity of inserted notes: wheel +-4, click +8 (c / C in INSERT, :vel N)'
  elseif hover.ctrl == 'step' then state.status = 'edit step: wheel = rows, click = auto (cursor jumps past the end of the inserted item / slice) - :step N|auto'
  elseif hover.sidectl then
    state.status = ({ open = 'open the sidebar (instruments + browser)', close = 'fold the sidebar to a strip', grip = 'drag: sidebar width, dblclick: auto' })[hover.sidectl]
  elseif hover.mxctl then
    state.status = ({ open = 'open the matrix', close = 'fold the matrix to a strip', grip = 'drag: matrix width, dblclick: auto' })[hover.mxctl]
  elseif SPROP.hover and state.top and state.toptab == 'sample' then
    state.status = ('sample %s - wheel / H L: change, click: toggle / open, dblclick or R: reset, J K: row (Sample tab focused)'):format(SPROP.ROWS[SPROP.hover.row].label)
  elseif hover.trs then
    local names = { vol = 'volume', pan = 'pan', width = 'width (stereo pan)', panl = 'left pan (dual pan)', panr = 'right pan (dual pan)' }
    state.status = ('%s %s - drag, wheel: fine, dblclick: reset; pan mode = REAPER track pan mode'):format(hover.trs.col.name, names[hover.trs.what] or hover.trs.what)
  elseif hover.lanebtn then state.status = ('lane columns: %d - click -/+ (min columns; more appear when items overlap)'):format(hover.lanebtn.n or 1)
  elseif hover.ctrl == 'wave' then state.status = 'wave column left of the note: spectral peaks (colour = frequency) + stretch markers (amber) - click: on/off, :wave'
  elseif hover.ctrl then state.status = 'click / wheel: ' .. hover.ctrl
  elseif hover.btn and hover.btn.what == 'auto' then
    local names = {}
    for _, e in ipairs(hover.btn.col.envs or {}) do names[#names + 1] = e.name end
    state.status = hover.btn.col.name .. ': ' .. (#names > 0 and (#names .. ' envelopes: ' .. table.concat(names, ', ')) or 'no automation') .. ' - click: this track only, a: all tracks'
  elseif hover.btn and hover.btn.what == 'monitor' then
    local m = hover.btn.col.recmon or 0
    state.status = hover.btn.col.name .. ': input monitoring ' .. ({ [0] = 'off', [1] = 'on', [2] = 'auto (tape)' })[m] .. ' - click: off → on → auto'
  elseif hover.btn then state.status = hover.btn.col.name .. ': ' .. hover.btn.what
  elseif hover.pool then
    local col = hover.pool.ci and snap.cols[hover.pool.ci] or cur_col(); local e = col and col.pool[hover.pool.i]
    state.status = e and (('inst %02d: %s%s%s - click: select, dblclick: slicer'):format(hover.pool.i, e.name, e.depot and ' (library)' or '', (e.tracks and #e.tracks > 0) and ('  @ ' .. table.concat(e.tracks, ', ')) or '  (not used yet)')) or ''
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
  elseif hover.sample and hover.sample.vol then state.status = 'item volume: wheel / < > = 1 dB, click = 0 dB'
  elseif hover.sample and hover.sample.norm then state.status = 'normalize: item volume so the peak hits 0 dB (n)'
  elseif hover.sample and hover.sample.slice then state.status = ('slice marker %d - drag to move'):format(hover.sample.slice)
  elseif hover.sample then
    local e = hover.sample.e or hover.sample
    state.status = (type(e) == 'table' and e.name or 'sample') .. ' - drag: select, drag selection out: to track column; Enter: insert @cursor; D: to depot; :slice / \\is: slicer'
  elseif hover.scope then state.status = 'scope ' .. hover.scope.name .. ' - click: cursor to track'
  elseif type(hover.browser) == 'string' then
    state.status = ({ files = 'browser: files of :browse root', db = 'browser: REAPER Media Explorer databases', pm = 'browser: jf_pm projects (Enter: inside, drag: subproject)', proj = 'browser: audio sources used in this project (like Project Bay)', auto = 'auto-preview selected row (p)', wave = 'mini waveforms next to file names (native peaks)', find = 'find (fzf): files mode searches the whole browse root, other modes the current list; also /', size = 'sidebar width: narrow / wide (w)', hide = 'hide sidebar (:side, q)' })[hover.browser] or hover.browser
  elseif hover.browser then state.status = B.describe(hover.browser) .. ', wheel: scroll'
  elseif hover.header_col or hover.col then
    local c = hover.header_col or hover.col
    state.status = c.name .. (c.muted and ' [muted]' or '') .. (c.solo and ' [solo]' or '') .. (c.armed and ' [rec]' or '') .. ' - click: select track in REAPER, rclick: track menu'
  else state.status = '' end
  if state.debug or reaper.GetExtState(EXT, 'dbgon') == '1' then
    local ks = {}; for k in pairs(hover) do ks[#ks + 1] = k end; table.sort(ks)
    if hover.matrix then for k, v in pairs(hover.matrix) do ks[#ks + 1] = 'mx.' .. k .. '=' .. tostring(v) end end
    reaper.SetExtState(EXT, 'dbg', ('%d,%d %s | %s || pool: %s'):format(gfx.mouse_x, gfx.mouse_y, table.concat(ks, ' '), state.status, (draw.pool_dbg or '') .. ' || ' .. tostring(SL.dbg)), false)
  end

  -- мышь
  local t_3 = reaper.time_precise()
  -- ресайз мышью: левый край браузера (ширина), нижний край верхней панели (высота)
  do
    local edge
    local W0 = gfx.w - L.side_w - (L.rstrip_w or 0)
    if state.side and math.abs(gfx.mouse_x - W0) <= 3 and gfx.mouse_y < gfx.h - L.status_h then edge = 'side'
    elseif state.side and L.inst_side_h and gfx.mouse_x > W0 and math.abs(gfx.mouse_y - ((L.side_y0 or 0) + L.inst_side_h + 1)) <= 3 then edge = 'inst'
    elseif state.top and math.abs(gfx.mouse_y - L.top_h) <= 3 and gfx.mouse_x < W0 then edge = 'top' end
    if resize_drag then
      if gfx.mouse_cap & 1 == 1 then
        if resize_drag == 'mx' then state.mx_px = math.max(L.cw * 12, math.min(math.floor(gfx.w * 0.6), gfx.mouse_x)); state.status = ('matrix width %d px'):format(state.mx_px)
        elseif resize_drag == 'side' then state.side_px = math.max(L.cw * 10, math.min(math.floor(gfx.w * 0.6), gfx.w - gfx.mouse_x))
        elseif resize_drag == 'inst' then state.inst_px = math.max(4 * L.rh, gfx.mouse_y - (L.side_y0 or 0))
        else state.top_px = math.max(4 * L.rh + 8, math.min(math.floor(gfx.h * 0.5), gfx.mouse_y)) end
        if resize_drag ~= 'mx' then state.status = resize_drag == 'side' and ('sidebar width %d px'):format(state.side_px) or (resize_drag == 'inst' and ('instruments %d px'):format(state.inst_px) or ('top panel %d px'):format(state.top_px)) end
      else resize_drag = nil end
    elseif edge then
      state.status = edge == 'side' and 'drag: resize sidebar width (dblclick: auto)' or (edge == 'inst' and 'drag: instruments / browser split (dblclick: auto)' or 'drag: resize top panel height (dblclick: auto)')
      if U.click then
        local now2 = reaper.time_precise()
        if (now2 - click.t) < 0.4 and click.zone == 'resize' then
          if edge == 'side' then state.side_px = nil elseif edge == 'inst' then state.inst_px = nil else state.top_px = nil end
        else resize_drag = edge end
        click = { t = now2, zone = 'resize' }
        U.click = false
      end
    end
  end
  if U.click and OPT.active then OPT.click(gfx.mouse_x, gfx.mouse_y); U.click = false end
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
    elseif hover.insprevbtn then
      ctx.set_focus('inst')
      state.preview = not state.preview; vim.msg = 'play on insert ' .. (state.preview and 'on' or 'off')
      click = { t = now2, zone = 'insprevbtn' }
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
      ctx.set_focus('top')
      if b == 'prev' then ctx.retro_cycle(-1) elseif b == 'next' then ctx.retro_cycle(1)
      elseif b == 'all' then ctx.retro_all() elseif b == 'play' then retro_preview(true) elseif b == 'stop' then retro_preview(false)
      elseif b == 'put' then retro_put('cursor') elseif b == 'depot' then retro_put('depot') elseif b == 'add' then ctx.retro_add() end
      click = { t = now2, zone = 'retrobtn' }
    elseif hover.retro then
      ctx.set_focus('top')
      retro.sel.a = hover.retro; retro.sel.b = hover.retro; retro.drag = true
      click = { t = now2, zone = 'retro' }
    elseif hover.tab then
      state.toptab = hover.tab
      ctx.set_focus('top')
      click = { t = now2, zone = 'tab' }
    elseif hover.sample and hover.sample.norm then
      ctx.set_focus('top'); if hover.sample.e.item then edit.normalize(hover.sample.e.item); vim.msg = 'normalized (peak 0 dB)' end
    elseif hover.sample and hover.sample.vol then
      ctx.set_focus('top'); if hover.sample.e.item then edit.item_vol(hover.sample.e.item, 0); hover.sample.e.vol = 1; vim.msg = 'vol 0 dB' end
    elseif hover.sample and hover.sample.view then
      ctx.set_focus('top'); SL.view = hover.sample.view
      click = { t = now2, zone = 'sampleview' }
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
    elseif hover.rglen then
      if hover.rglen ~= 0 then ctx.region_len_step(hover.rglen) end
      click = { t = now2, zone = 'rglen' }
    elseif hover.sidectl then
      if hover.sidectl == 'open' then state.side = true; vim.msg = 'sidebar shown'
      elseif hover.sidectl == 'close' then ctx.side_hide(); vim.msg = 'sidebar folded (< to open)'
      elseif hover.sidectl == 'grip' then
        if dbl and click.zone == 'sidegrip' then state.side_px = nil; vim.msg = 'sidebar width: auto' else resize_drag = 'side' end
      end
      click = { t = now2, zone = hover.sidectl == 'grip' and 'sidegrip' or 'sidectl' }
    elseif hover.mxctl then
      if hover.mxctl == 'open' then state.mx_hidden = false; vim.msg = 'matrix shown'
      elseif hover.mxctl == 'close' then state.mx_hidden = true; if state.focus == 'matrix' then ctx.set_focus('tracker') end; vim.msg = 'matrix folded (> to open)'
      elseif hover.mxctl == 'grip' then
        if dbl and click.zone == 'mxgrip' then state.mx_px = nil; vim.msg = 'matrix width: auto' else resize_drag = 'mx' end
      end
      click = { t = now2, zone = hover.mxctl == 'grip' and 'mxgrip' or 'mxctl' }
    elseif SPROP.hover and state.top and state.toptab == 'sample' then
      ctx.set_focus('top')
      local e = cur_col() and (cur_col().pool or {})[vim.inst]
      local same = click.zone == 'sprop' and click.row == SPROP.hover.row
      SPROP.sel = SPROP.hover.row
      if e and dbl and same then ctx.sp_reset(e, SPROP.hover.k)
      elseif e and (SPROP.hover.k == 'ppitch' or SPROP.hover.k == 'loop' or SPROP.hover.k == 'fx' or SPROP.hover.k == 'norm' or SPROP.hover.k == 'mode') then ctx.sp_adjust(e, SPROP.hover.k, 1) end
      click = { t = now2, zone = 'sprop', row = SPROP.hover.row }
    elseif hover.trs then
      local t = hover.trs
      if dbl and click.zone == 'trs' and click.row == t.what then
        edit.track_value(t.col.track, TRS_KEY[t.what], TRS_RESET[t.what]); edit.track_undo('track ' .. t.what .. ' reset'); model.invalidate()
        trs_drag = nil
      else
        trs_drag = { col = t.col, what = t.what, x0 = t.x0, w = t.w }
      end
      click = { t = now2, zone = 'trs', row = t.what }
    elseif hover.lanebtn then
      ctx.lane_subs(hover.lanebtn.col, hover.lanebtn.lane, hover.lanebtn.d, hover.lanebtn.n)
      click = { t = now2, zone = 'lanebtn' }
    elseif hover.matrix and hover.matrix.btn then
      ctx.set_focus('matrix')
      if hover.matrix.btn == 'zoom' then ctx.mx_zoom()
      elseif hover.matrix.btn == 'fill' then MX.fill = not MX.fill
      elseif hover.matrix.btn == 'sync' then vim.msg = 'synced ' .. tostring(ctx.sync_here())
      elseif hover.matrix.btn == 'trim' then ctx.mx_trim()
      elseif hover.matrix.btn == 'add' then ctx.mx_add() end
      click = { t = now2, zone = 'mxbtn' }
    elseif hover.matrix and hover.matrix.name then
      ctx.set_focus('matrix')
      MX.goto_cell(seq, snap, hover.matrix.name, MX.cur.ci)
      if dbl and click.zone == 'mxname' and click.row == hover.matrix.name then ctx.mx_name_prompt() end
      click = { t = now2, zone = 'mxname', row = hover.matrix.name }
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
    elseif type(hover.browser) == 'string' then
      B.click(hover.browser)
      click = { t = now2, zone = 'browserbtn' }
    elseif hover.browser then
      ctx.set_focus('browser')
      B.cur = hover.browser
      if dbl and click.zone == 'browser' and click.row == hover.browser then B.enter() end
      click = { t = now2, zone = 'browser', row = hover.browser }
      local e = B.entries[hover.browser]
      if e and not e.dir and not e.db and not e.pmdir and not e.mark then B.drag = { e = e, x0 = gfx.mouse_x, y0 = gfx.mouse_y, active = false } end
    elseif hover.dsp then
      ctx.set_focus('dsp')
      dsp_sel.fx = hover.dsp.fx; if hover.dsp.param then dsp_sel.param = hover.dsp.param end
      if not hover.dsp.param then dsp_drag = { fx = hover.dsp.fx, f = hover.dsp.f, x0 = gfx.mouse_x, y0 = gfx.mouse_y, active = false } end
      local col = cur_col()
      if hover.dsp.param and col then
        local p = hover.dsp.f.params[hover.dsp.param]
        if p and p.kind == 'toggle' then
          edit.fx_param(col.track, p.fx or hover.dsp.f.i, p.i, reaper.TrackFX_GetParamNormalized(col.track, p.fx or hover.dsp.f.i, p.i) >= 0.5 and 0 or 1)
        elseif p and hover.dsp.onwidget then edit.fx_param(col.track, p.fx or hover.dsp.f.i, p.i, hover.dsp.sv) end
      elseif dbl and click.zone == 'dsp' and col then
        edit.fx_show(col.track, hover.dsp.f.i)
      end
      click = { t = now2, zone = 'dsp' }
    elseif hover.ctrl then
      ctrl_action(hover.ctrl, 0)
      click = { t = now2, zone = 'ctrl' }
    elseif hover.scope then
      for i, f in ipairs(L.flat) do if f.col == hover.scope then vim.cur.fi = i; break end end
      ctx.set_focus('top')
      click = { t = now2, zone = 'scope' }
    elseif hover.pool then
      ctx.set_focus('inst')
      pool_select(hover.pool.i)
      if dbl and click.zone == 'pool' and click.row == hover.pool.i then ctx.open_slicer(hover.pool.i) end
      click = { t = now2, zone = 'pool', row = hover.pool.i }
    elseif hover.btn and hover.btn.what == 'auto' then
      ctx.toggle_track_envs(hover.btn.col); click = { t = now2, zone = 'btn' }
    elseif hover.btn then
      local tr, what = hover.btn.col.track, hover.btn.what
      edit.run('track ' .. what, function()
        if what == 'monitor' then reaper.SetMediaTrackInfo_Value(tr, 'I_RECMON', (math.floor(reaper.GetMediaTrackInfo_Value(tr, 'I_RECMON')) + 1) % 3)
        elseif what == 'mute' then reaper.SetMediaTrackInfo_Value(tr, 'B_MUTE', reaper.GetMediaTrackInfo_Value(tr, 'B_MUTE') == 1 and 0 or 1)
        elseif what == 'solo' then reaper.SetMediaTrackInfo_Value(tr, 'I_SOLO', reaper.GetMediaTrackInfo_Value(tr, 'I_SOLO') > 0 and 0 or 1)
        else reaper.SetMediaTrackInfo_Value(tr, 'I_RECARM', reaper.GetMediaTrackInfo_Value(tr, 'I_RECARM') == 1 and 0 or 1) end
      end)
      click = { t = now2, zone = 'btn' }
    elseif hover.header_col then
      reaper.SetOnlyTrackSelected(hover.header_col.track)
      click = { t = now2, zone = 'header' }
    elseif hover.itemedge and hover.itemedge.edge ~= 'move' and gfx.mouse_cap & 8 ~= 8 then
      -- край рамки item: trim как в аранжировке
      ctx.set_focus('tracker')
      item_drag = { item = hover.itemedge.item, edge = hover.itemedge.edge, col = hover.itemedge.col, y0 = gfx.mouse_y, active = false, name = hover.itemedge.col.name }
      click = { t = now2, zone = 'itemedge' }
    elseif hover.row and hover.fi then
      ctx.set_focus('tracker')
      if hover.itemedge and hover.itemedge.edge == 'move' and gfx.mouse_cap & 16 == 16 then
        -- Option+протяжка по телу item — сдвиг (клик без Option — курсор, как раньше)
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
        vim.cur.fi, vim.cur.row = hover.fi, hover.row.row
        if hover.field then vim.cur.field = hover.field end
        local head = cell
        -- клик по событию выделяет item в REAPER (штатные действия и
        -- mouse modifiers работают с ним); двойной — свойства item / MIDI-редактор
        if head and head.item then
          select_item_in_reaper(head.item)
          if dbl and click.zone == 'body' and click.fi == hover.fi and click.row == hover.row.row then
            reaper.Main_OnCommand(head.kind == 'audio' and 40009 or 40153, 0)
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
        edit.item_drag_to(item_drag.item, item_drag.edge, t, edit.row_time(1, state.lpb, 0) / 4)
        state.status = ('%s %s → row %.2f (Cmd: free)'):format(item_drag.edge, item_drag.col.name, rowf)
        model.invalidate()
      end
    else
      if item_drag.active then edit.item_drag_end() end
      item_drag = nil
    end
  elseif hover.itemedge and hover.itemedge.edge ~= 'move' then
    state.status = ('item %s: drag to trim %s (snap to rows, Cmd: free); Option+drag inside: move'):format(hover.itemedge.col.name, hover.itemedge.edge)
  end
  -- Shift+протяжка: второй угол блока следует за мышью
  if body_drag then
    if gfx.mouse_cap & 1 == 1 then
      if hover.row and hover.fi and vim.mode == 'visual' then vim.cur.fi, vim.cur.row = hover.fi, hover.row.row end
    else body_drag = nil end
  end
  -- протяжка по слайдеру DSP
  if hover.dsp and hover.dsp.param and gfx.mouse_cap & 1 == 1 and click.zone == 'dsp' then
    local col = cur_col()
    local p = col and hover.dsp.f.params[hover.dsp.param]
    if p and p.kind ~= 'toggle' and hover.dsp.sv then edit.fx_param(col.track, p.fx or hover.dsp.f.i, p.i, hover.dsp.sv) end
  end
  -- огибающая мышью, как в аранжировке: клик/протяжка — точка со значением
  -- от x, правый клик — удалить точку строки, колесо — ±1/64
  if hover.env and hover.row then
    local down = gfx.mouse_cap & 1 == 1
    if down then
      local key = tostring(hover.env.env) .. ':' .. hover.row.row .. ':' .. math.floor(hover.envx * 255)
      if env_drag.key ~= key then
        env_drag.key = key
        ctx.env_set(hover.env, hover.row.row, hover.envx)
        if hover.fi then vim.cur.fi, vim.cur.row = hover.fi, hover.row.row end
      end
    else env_drag.key = nil end
    if U.rclick then ctx.env_del(hover.env, hover.row.row) end
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
      if B.drag.active and hover.fi and hover.row then
        local e = B.drag.e
        if e.trk then ctx.drop_track(e, B.pmproj and B.pmproj.e)
        elseif e.rgn and B.pmproj then ctx.drop_region_to(hover.fi, hover.row.row, B.pmproj.e.path, e)
        elseif not e.mark then ctx.drop_to(hover.fi, hover.row.row, e.pm and e.path or B.full(e)) end
      end
      B.drag = nil
    end
  end
  -- сэмпл-модуль: протяжка выделения / вынос выделения на колонку трекера
  if SL.drag then
    if gfx.mouse_cap & 1 == 1 then
      SL.mouse_move(hover.sample and hover.sample.frac)
      if SL.drag.kind == 'out' and SL.drag.active then
        state.status = (hover.fi and hover.row) and ('drop selection → %s @ %04d'):format(hover.col and hover.col.name or '', hover.row.row) or 'drag selection - drop on a track column'
      end
    else
      local d = SL.mouse_up()
      if d and d.kind == 'out' and d.active and hover.fi and hover.row then
        local a, b = SL.span()
        if a then ctx.drop_span(hover.fi, hover.row.row, SL.entry, a, b) end
      end
    end
  end
  -- DSP: перетаскивание блока за заголовок → перестановка FX в цепи трека
  -- протяжка слайдера шапки: значение каждый кадр без undo, точка undo на отпускании
  if trs_drag then
    if gfx.mouse_cap & 1 == 1 then
      local frac = math.max(0, math.min(1, (gfx.mouse_x - trs_drag.x0) / math.max(1, trs_drag.w)))
      local v = trs_value(trs_drag.what, frac)
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
        state.status = hover.dsp and hover.dsp.fx ~= dsp_drag.fx and ('move ' .. dsp_drag.f.name .. ' → position of ' .. hover.dsp.f.name) or ('move ' .. dsp_drag.f.name .. ' - drop on another block')
      end
    else
      if dsp_drag.active and hover.dsp and hover.dsp.fx ~= dsp_drag.fx then
        local col = cur_col()
        if col then edit.fx_move(col.track, dsp_drag.f.i, hover.dsp.f.i); dsp_sel.fx = hover.dsp.fx; vim.msg = 'fx moved: ' .. dsp_drag.f.name end
      end
      dsp_drag = nil
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
      ctx.preview_file(pth, 3.0)
    end
  end

  if gfx.mouse_wheel ~= 0 and SPROP.hover and state.top and state.toptab == 'sample' then
    local e = cur_col() and (cur_col().pool or {})[vim.inst]
    SPROP.sel = SPROP.hover.row
    if e and SPROP.hover.k ~= 'fx' and SPROP.hover.k ~= 'norm' then ctx.sp_adjust(e, SPROP.hover.k, gfx.mouse_wheel > 0 and 1 or -1) end
    gfx.mouse_wheel = 0
  end
  if gfx.mouse_wheel ~= 0 and hover.trs then
    local t, d = hover.trs, gfx.mouse_wheel > 0 and 1 or -1
    local key = TRS_KEY[t.what]
    local cur = reaper.GetMediaTrackInfo_Value(t.col.track, key)
    local v
    if t.what == 'vol' then
      local db = cur > 1e-6 and 20 * math.log(cur, 10) or -60
      v = 10 ^ (math.max(-60, math.min(12, db + d * 0.5)) / 20)
    else v = math.max(-1, math.min(1, cur + d * 0.02)) end
    edit.track_value(t.col.track, key, v); edit.track_undo('track ' .. t.what); model.invalidate()
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
  if gfx.mouse_wheel ~= 0 and hover.sample and hover.sample.vol then
    SL.entry = SL.entry or hover.sample.e
    SL.vol_step(gfx.mouse_wheel > 0 and 1 or -1)
    gfx.mouse_wheel = 0
  end
  if gfx.mouse_wheel ~= 0 and hover.mm then
    MMX.row, MMX.col = hover.mm.row, hover.mm.col
    MMX.adjust(cur_col() and cur_col().mods or {}, (gfx.mouse_wheel > 0 and 1 or -1) * ((gfx.mouse_cap & 8 == 8) and 10 or 1))
    gfx.mouse_wheel = 0
  end
  if gfx.mouse_wheel ~= 0 then
    local step = gfx.mouse_wheel > 0 and -3 or 3
    if hover.dsp and hover.dsp.param then
      local col = cur_col(); local p = col and hover.dsp.f.params[hover.dsp.param]
      if p then edit.fx_param(col.track, hover.dsp.f.i, p.i, reaper.TrackFX_GetParamNormalized(col.track, hover.dsp.f.i, p.i) + (step > 0 and -0.02 or 0.02)) end
    elseif hover.env and hover.row then ctx.env_nudge(hover.env, hover.row.row, (step > 0 and -1 or 1) / 64)
    elseif hover.ctrl then ctrl_action(hover.ctrl, step > 0 and -1 or 1)
    elseif type(hover.browser) == 'number' then B.cur = math.max(1, math.min(#B.entries, B.cur + (step > 0 and 1 or -1)))
    elseif gfx.mouse_cap & 8 == 8 then
      state.hscroll = math.max(1, math.min(math.max(1, #snap.cols), state.hscroll + (step > 0 and 1 or -1)))
    else
      if state.fixed then vim.cur.row = math.max(0, vim.cur.row + step) else state.row0 = math.max(0, state.row0 + step) end
    end
    gfx.mouse_wheel = 0
  end

  U.end_frame()
  gfx.update()
  local t_4 = reaper.time_precise()
  prof.snap = prof.snap + (t_1 - t_0); prof.layout = prof.layout + (t_2 - t_1)
  prof.draw = prof.draw + (t_3 - t_2); prof.upd = prof.upd + (t_4 - t_3); prof.n = prof.n + 1

  local c = gfx.getchar()
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
  if c == keys.f1 then open_help(); c = 0 end
  if c == keys.f11 then toggle_dock(); c = 0 end
  c = keys.translate(c)
  -- окно Options — модальное: все клавиши ему
  if OPT.active and c ~= 0 then OPT.key(c); c = 0 end
  -- Tab / Shift-Tab — переход между модулями из ЛЮБОГО места (в INSERT,
  -- в слайсере, в браузере…); исключения: набор команды/поиска (там Tab —
  -- дополнение) и открытые fzf-пикер / hydra
  -- Ctrl + / Ctrl - : масштаб битмапа шагом 0.25 (просьба 1 окт); в TTF-режиме — кегль
  -- (на Mac Ctrl+минус может прийти кодом 31 = ^_ ; плюс — 61 '=' или 43 '+')
  if (c == 61 or c == 43 or c == 45 or c == 95 or c == 31) and ctx.mods().ctrl and not vim.picker and vim.mode ~= 'cmd' and vim.mode ~= 'search' then
    local d = (c == 45 or c == 95 or c == 31) and -1 or 1
    if (state.font or 0) == 0 then
      ctx.set_scale(math.max(1, math.min(4, math.floor(state.fontscale or 2) + d)))
      vim.msg = ('bitmap x%d'):format(state.fontscale)
    else ctx.set_font(math.max(6, state.font + d)); vim.msg = 'font ' .. state.font end
    c = 0
  end
  local ctrl_note = vim.mode == 'insert' and state.focus == 'tracker' and ctx.mods().ctrl   -- Ctrl+i / Ctrl+y = нота, не Tab
  -- Option-Tab / Option-Shift-Tab: вкладки верхнего дока по кругу (sample → … → master → sample)
  if (c == 9 or c == 25) and ctx.mods().alt and not vim.picker and not vim.hydra and vim.mode ~= 'cmd' and vim.mode ~= 'search' then
    local TABS = { 'sample', 'modulation', 'retro', 'garden', 'master' }
    local i = 1
    for k, t in ipairs(TABS) do if t == state.toptab then i = k end end
    local back = c == 25 or ctx.mods().shift
    state.top = true
    state.toptab = TABS[(i - 1 + (back and -1 or 1)) % #TABS + 1]
    ctx.set_focus('top')
    vim.msg = 'tab: ' .. state.toptab
    c = 0
  end
  if (c == 9 or c == 25) and not ctrl_note and not HN.active and not vim.picker and not vim.hydra and vim.mode ~= 'cmd' and vim.mode ~= 'search' then
    local f0 = state.focus
    ctx.toggle_focus((c == 25 or (inject_cap or gfx.mouse_cap) & 8 == 8) and -1 or 1)
    vim.msg = 'focus: ' .. state.focus:upper()
    c = 0
  end
  if c > 0 and HN.active then
    local r = HN.key(c)
    if type(r) == 'table' then local ok, e = pcall(hint_go, r); if not ok then vim.msg = tostring(e):match('[^\n]*$') end end
    c = 0
  elseif c == ('f'):byte() and vim.mode == 'normal' and not vim.hydra and not vim.picker and state.focus ~= 'browser' then
    if HN.start() then vim.msg = 'hints: type label, Esc' else vim.msg = 'no targets' end
    c = 0
  end
  if c > 0 then
    state.last_key = c
    vim.msg = ''
    local ok, r = pcall(function()
      if state.focus == 'matrix' and #seq == 0 and c == 43 then ctx.mx_add()     -- пустая матрица: + добавляет первый регион
      elseif state.focus == 'matrix' and #seq > 0 then
        -- командная строка (:name / :len после + n =) — клавиши идут в vim, не в матрицу (ревью 1 окт)
        if vim.mode == 'cmd' or vim.mode == 'search' then return vim.key(c) end
        if not MX.key(c, seq, snap) then return vim.key(c) end
      elseif state.focus == 'browser' and state.side then
        if not B.key(c) then return vim.key(c) end
      elseif state.focus == 'inst' and (state.top or state.side) then
        local ch = c < 256 and string.char(c) or ''
        local col = cur_col()
        if c == 27 then ctx.set_focus('tracker')
        elseif ch == '/' then ctx.inst_find()
        elseif ch == 'j' or c == keys.down then pool_select(vim.inst + 1)
        elseif ch == 'k' or c == keys.up then pool_select(vim.inst - 1)
        elseif ch == 'g' then pool_select(1)
        elseif ch == 'G' then pool_select(#(col and col.pool or {}))
        elseif c == 13 or ch == 's' then ctx.open_slicer()
        elseif ch == ' ' then local e = col and col.pool[vim.inst]; if e then PV.audio(col.track, e.item, 0, 1.0) end
        elseif ch == 'p' then state.poolprev = not state.poolprev
        elseif ch == 'h' or c == keys.left then vim.key(('H'):byte())
        elseif ch == 'l' or c == keys.right then vim.key(('L'):byte())
        else return vim.key(c) end
      elseif state.focus == 'dsp' and state.dsp then
        local ch = c < 256 and string.char(c) or ''
        local col = cur_col(); local fxs = col and col.fx or {}
        local f = fxs[dsp_sel.fx]
        if c == 9 then ctx.toggle_focus()
        elseif c == 27 then ctx.set_focus('tracker')
        elseif ch == 'h' or c == keys.left then dsp_sel.fx = math.max(1, dsp_sel.fx - 1); dsp_sel.param = 1
        elseif ch == 'l' or c == keys.right then dsp_sel.fx = math.min(math.max(1, #fxs), dsp_sel.fx + 1); dsp_sel.param = 1
        elseif ch == 'j' or c == keys.down then dsp_sel.param = math.min(f and #f.params or 1, dsp_sel.param + 1)
        elseif ch == 'k' or c == keys.up then dsp_sel.param = math.max(1, dsp_sel.param - 1)
        elseif (c == 1 or c == 24 or ch == '+' or ch == '-' or ch == '=' or c == 13 and f and f.params[dsp_sel.param] and f.params[dsp_sel.param].kind == 'toggle') and f then
          local p = f.params[dsp_sel.param]
          if p then
            local id = p.fx or f.i
            local v = reaper.TrackFX_GetParamNormalized(col.track, id, p.i)
            local d = (c == 1 or ch == '+' or ch == '=') and 1 or -1
            if p.kind == 'toggle' then edit.fx_param(col.track, id, p.i, v >= 0.5 and 0 or 1)
            elseif p.kind == 'steps' and p.nsteps then edit.fx_param(col.track, id, p.i, v + d / (p.nsteps - 1))
            else edit.fx_param(col.track, id, p.i, v + d * (gfx.mouse_cap & 8 == 8 and 0.1 or 0.02)) end
          end
        elseif (ch == 'b' or c == 13) and f then edit.fx_bypass(col.track, f.i)
        elseif ch == 'o' and f then edit.fx_show(col.track, f.i)
        elseif (ch == 'x' or c == 8 or c == keys.delete) and f then edit.fx_remove(col.track, f.i); dsp_sel.fx = math.max(1, dsp_sel.fx - 1)
        elseif (ch == 'a' or ch == '/') and col then ctx.fx_picker()
        elseif ch == 'A' and f then
          vim.open_picker('automate ' .. f.name, (function()
            local items = {}
            for pi = 0, f.np - 1 do local _, pn = reaper.TrackFX_GetParamName(col.track, f.i, pi, ''); items[#items + 1] = { label = pn or ('p' .. pi), data = pi } end
            return items end)(), function(it) edit.run('show envelope', function() reaper.GetFXEnvelope(col.track, f.i, it.data, true) end); state.envs = true; model.invalidate() end)
        elseif ch == ' ' then edit.play_stop()
        else return vim.key(c) end
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
          elseif ch == 'p' or c == 13 then retro_put('cursor')
          elseif ch == 'P' then retro_put('cursor', true)
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
    if not ok then vim.msg = tostring(r):match('[^\n]*$') or tostring(r) elseif r == 'quit' then quit = true end
  end
  inject_cap = nil
  local owner = reaper.GetExtState(EXT, 'owner')
  local taken = owner ~= '' and owner ~= MY_ID
  if c ~= -1 and not quit and not taken and reaper.GetExtState(EXT, 'quit') ~= '1' then
    reaper.defer(frame)
  else
    reaper.SetExtState(EXT, 'exit', ('c=%d quit=%s taken=%s flag=%s at %s'):format(c, tostring(quit), tostring(taken), reaper.GetExtState(EXT, 'quit'), os.date('%H:%M:%S')), false)
    if not taken then reaper.DeleteExtState(EXT, 'quit', false); reaper.DeleteExtState(EXT, 'owner', false) end
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
frame = (function(inner)
  return function()
    local ok, e = pcall(inner)
    if not ok then reaper.SetExtState(EXT, 'err', tostring(e), false); save_win(); gfx.quit() end
  end
end)(frame)

reaper.atexit(save_win)
frame()
