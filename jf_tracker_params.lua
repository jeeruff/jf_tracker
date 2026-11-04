-- jf_tracker_params.lua — панель «params» во вкладке modulation (3 окт).
--
-- Всё, что у трека можно автоматизировать и модулировать, одной таблицей —
-- как нативное окно Envelopes, но вместе с модуляцией FX:
--   параметр | ENV (нет / hid / vis) | ACT | ARM | PTS | MOD (L E K) | значение
-- Строки: огибающие трека (Volume, Pan, Width, Pre-FX, Trim, Mute) и каждый
-- параметр каждого FX трека, включая детей контейнеров.
-- Шапка: режим автоматизации трека (trim / read / touch / write / latch /
-- latch pv), all / used (только с огибающей или модуляцией), огибающие в
-- трекере, нативное окно Envelopes.
--
-- Клавиши: j k g G — строка; h l — ячейка; Enter / Space — ячейка (ENV:
-- создать / показать / спрятать; ACT, ARM — тоггл; MOD — в матрицу);
-- e — огибающая, a — arm, b — active, m — модуляция LFO (как a в матрице),
-- c — кривая LFO в эту огибающую (вкладка curves), o — окно FX, w — нативное
-- окно модуляции, v — all / used, M — режим автоматизации, / — fzf по
-- параметрам, P / Esc — назад.
-- Перечень параметров строится на смену трека / числа FX, состояния ячеек —
-- только видимых строк, 4 раза в секунду (правило ReaImGui-производительности).

local PP = { row = 1, col = 2, scroll = 0, used = false, rows = {}, hover = nil }
local U, ctx
local R = reaper

function PP.init(u, c) U, ctx = u, c end

PP.MODES = { [0] = 'trim', [1] = 'read', [2] = 'touch', [3] = 'write', [4] = 'latch', [5] = 'latch pv' }

-- огибающие трека: имя для GetTrackEnvelopeByName ← слова в тексте действия
-- «Track: Toggle track … envelope visible»
local TRACK_ENVS = {
  { 'Volume', 'volume' }, { 'Pan', 'pan' }, { 'Width', 'width' },
  { 'Volume (Pre-FX)', 'pre-fx volume' }, { 'Pan (Pre-FX)', 'pre-fx pan' }, { 'Width (Pre-FX)', 'pre-fx width' },
  { 'Trim Volume', 'trim' }, { 'Mute', 'mute' },
}
-- 4 ноя: огибающие take ноты под курсором трекера (имя для GetTakeEnvelopeByName, действие-переключатель)
local TAKE_ENVS = { { 'Volume', 40693 }, { 'Pan', 40694 }, { 'Mute', 40695 }, { 'Pitch', 41612 } }
local env_cmds   -- слова → id действия (скан один раз)
local function env_cmd(words)
  if not env_cmds then
    env_cmds = {}
    for id = 40000, 42800 do
      local t = R.kbd_getTextFromCmd(id, 0) or ''
      local w = t:match('^Track: Toggle track (.-) envelope visible$')
      if w then env_cmds[w:lower()] = id end
    end
  end
  return env_cmds[words]
end

-- ячейки: key, заголовок, ширина в символах
PP.COLS = {
  { key = 'name', head = 'parameter' },
  { key = 'env', head = 'ENV', w = 3 },
  { key = 'act', head = 'ACT', w = 3 },
  { key = 'arm', head = 'ARM', w = 3 },
  { key = 'pts', head = 'PTS', w = 4 },
  { key = 'mod', head = 'MOD', w = 3 },
  { key = 'val', head = 'value', w = 9 },
}

-- ── перечень ─────────────────────────────────────────────────────────────
local sig   -- трек + число FX + число параметров: при смене — пересборка

local function signature(tr, fxa)
  local s = tostring(tr) .. ':' .. #fxa
  for _, fa in ipairs(fxa) do s = s .. ',' .. fa.fx .. '/' .. R.TrackFX_GetNumParams(tr, fa.fx) end
  return s
end

function PP.build(tr, fx_addresses)
  local fxa = fx_addresses(tr)
  local take = ctx.cur_take and ctx.cur_take(tr)
  local s = signature(tr, fxa) .. '|' .. tostring(take)
  if s == sig then return PP.all end
  sig = s
  local rows = {}
  for _, te in ipairs(TRACK_ENVS) do
    rows[#rows + 1] = { kind = 'track', label = 'track / ' .. te[1], env_name = te[1], words = te[2] }
  end
  if take then   -- 4 ноя: take ноты под курсором — её громкость, пан, mute, высота (огибающие take)
    for _, te in ipairs(TAKE_ENVS) do rows[#rows + 1] = { kind = 'take', take = take, label = 'take / ' .. te[1], env_name = te[1], cmd = te[2] } end
  end
  for _, fa in ipairs(fxa) do
    local _, fn = R.TrackFX_GetFXName(tr, fa.fx, '')
    -- 9 окт: короткое имя — у JSFX описание после « - » долой, длинные скобки
    -- тоже; не длиннее 20 знаков (параметр в списке иначе не виден)
    fn = (fn or ''):gsub('^[^:]*: ', '')
    fn = fn:match('^(.-)%s+%-%s+') or fn
    if #fn > 20 then fn = fn:gsub('%s*%(.*$', '') end
    if #fn > 20 then fn = fn:sub(1, 20) end
    fn = fa.prefix .. fn
    for pi = 0, math.min(1024, R.TrackFX_GetNumParams(tr, fa.fx)) - 1 do
      local _, pn = R.TrackFX_GetParamName(tr, fa.fx, pi, '')
      rows[#rows + 1] = { kind = 'fx', fx = fa.fx, param = pi, fxname = fn, pname = pn or ('p' .. pi), label = fn .. ' / ' .. (pn or ('p' .. pi)) }
    end
  end
  PP.all, PP.track = rows, tr
  PP.t = nil
  return rows
end

-- огибающая строки (create — создать)
function PP.env_of(tr, r, create)
  if r.kind == 'fx' then return R.GetFXEnvelope(tr, r.fx, r.param, create or false) end
  if r.kind == 'take' then return R.ValidatePtr(r.take, 'MediaItem_Take*') and R.GetTakeEnvelopeByName(r.take, r.env_name) or nil end
  return R.GetTrackEnvelopeByName(tr, r.env_name)
end

local function flag(env, what)
  local ok, v = R.GetSetEnvelopeInfo_String(env, what, '', false)
  return ok and v == '1'
end

local function cfg(tr, fx, key)
  local ok, v = R.TrackFX_GetNamedConfigParm(tr, fx, key)
  return ok and tonumber(v) or 0
end

-- состояние одной строки (видимые строки, 4 Гц)
function PP.refresh_row(tr, r)
  local env = PP.env_of(tr, r, false)
  r.env = env
  r.has = env ~= nil
  if env then
    r.vis, r.act, r.arm = flag(env, 'VISIBLE'), flag(env, 'ACTIVE'), flag(env, 'ARM')
    r.pts = R.CountEnvelopePoints(env) + R.CountAutomationItems(env)
  else r.vis, r.act, r.arm, r.pts = false, false, false, 0 end
  if r.kind == 'fx' then
    local p = 'param.' .. r.param .. '.'
    r.mod = cfg(tr, r.fx, p .. 'mod.active') >= 0.5
    r.lfo = r.mod and cfg(tr, r.fx, p .. 'lfo.active') >= 0.5
    r.acs = r.mod and cfg(tr, r.fx, p .. 'acs.active') >= 0.5
    r.lnk = r.mod and cfg(tr, r.fx, p .. 'plink.active') >= 0.5
    local _, fv = R.TrackFX_GetFormattedParamValue(tr, r.fx, r.param, '')
    r.val = fv or ''
  else
    r.val = ''
  end
  r.used = r.has or r.mod
end

-- «used»: строки с огибающей или модуляцией — проверка всех строк, но только
-- при пересборке / включении режима / после правки (PP.dirty)
function PP.visible_rows(tr)
  if not PP.used then return PP.all or {} end
  if PP.dirty or not PP.used_rows or PP.used_track ~= tr then
    local out = {}
    for _, r in ipairs(PP.all or {}) do
      PP.refresh_row(tr, r)
      if r.used then out[#out + 1] = r end
    end
    PP.used_rows, PP.used_track, PP.dirty = out, tr, false
  end
  return PP.used_rows
end

function PP.cur_row()
  local rows = PP.shown or {}
  return rows[PP.row]
end

-- ── правка ───────────────────────────────────────────────────────────────
local function set_flag(env, what, on)
  R.GetSetEnvelopeInfo_String(env, what, on and '1' or '0', true)
end

-- показать / спрятать огибающую; нет — создать (видимой)
function PP.toggle_env(tr, r)
  local env = PP.env_of(tr, r, false)
  ctx.edit_run('envelope ' .. r.label, function()
    if env then
      set_flag(env, 'VISIBLE', not flag(env, 'VISIBLE'))
    elseif r.kind == 'fx' then
      R.GetFXEnvelope(tr, r.fx, r.param, true)
    elseif r.kind == 'take' then   -- выделить только айтем этой ноты, переключить огибающую take, выделение назад
      if not R.ValidatePtr(r.take, 'MediaItem_Take*') then return end
      local it, sel = R.GetMediaItemTake_Item(r.take), {}
      for i = 0, R.CountSelectedMediaItems(0) - 1 do sel[#sel + 1] = R.GetSelectedMediaItem(0, i) end
      R.SelectAllMediaItems(0, false); R.SetMediaItemSelected(it, true)
      R.Main_OnCommand(r.cmd, 0)
      R.SelectAllMediaItems(0, false); for _, o in ipairs(sel) do if R.ValidatePtr(o, 'MediaItem*') then R.SetMediaItemSelected(o, true) end end
    else
      local id = env_cmd(r.words)
      if not id then return end
      ctx.with_only_track(tr, function() R.Main_OnCommand(id, 0) end)
    end
    R.TrackList_AdjustWindows(false)
  end)
  PP.dirty = true
end

function PP.toggle_flag(tr, r, what)
  local env = PP.env_of(tr, r, false)
  if not env then ctx.msg(r.label .. ': no envelope yet - e / Enter on ENV creates it'); return end
  ctx.edit_run('envelope ' .. what:lower(), function() set_flag(env, what, not flag(env, what)); R.TrackList_AdjustWindows(false) end)
  PP.dirty = true
end

function PP.cycle_mode(tr, d)
  local m = math.floor(R.GetMediaTrackInfo_Value(tr, 'I_AUTOMODE'))
  m = (m + (d or 1)) % 6
  ctx.edit_run('automation mode', function() R.SetMediaTrackInfo_Value(tr, 'I_AUTOMODE', m) end)
  ctx.msg('automation mode: ' .. PP.MODES[m])
end

-- действие ячейки
function PP.activate(tr, r, key)
  if not r then return end
  key = key or PP.COLS[PP.col].key
  if key == 'env' or key == 'name' or key == 'pts' then PP.toggle_env(tr, r)
  elseif key == 'act' then PP.toggle_flag(tr, r, 'ACTIVE')
  elseif key == 'arm' then PP.toggle_flag(tr, r, 'ARM')
  elseif key == 'mod' then
    if r.kind ~= 'fx' then ctx.msg((r.kind == 'take' and 'take' or 'track') .. ' envelopes have no native modulation - pick an FX parameter'); return end
    if r.mod then ctx.mod_goto(r) else ctx.mod_add(r); PP.dirty = true end
  elseif key == 'val' and r.kind == 'fx' then ctx.mod_window(r) end
end

-- ── отрисовка ────────────────────────────────────────────────────────────
-- шапка: кнопки; возвращает hover
local function header(L, x, y, w, tr, mx, my)
  local hv
  local bx = x
  local function button(label, on, what)
    local bw = U.measure(label) + 2 * L.pad
    if bx + bw > x + w then return end
    local hot = mx >= bx and mx < bx + bw and my >= y and my < y + L.rh
    U.set(on and U.tint(U.AMBER, 0.3) or (hot and U.tint(U.TEXT, 0.08) or U.BG)); gfx.rect(bx, y, bw, L.rh - 1, 1)
    U.set((on or hot) and U.AMBER or U.LINE); gfx.rect(bx, y, bw, L.rh - 1, 0)
    U.text(bx + L.pad, y, label, on and U.AMBER or (hot and U.TEXT or U.GREY))
    if hot then hv = { btn = what } end
    bx = bx + bw + 2
  end
  local m = math.floor(R.GetMediaTrackInfo_Value(tr, 'I_AUTOMODE'))
  button('mode ' .. (PP.MODES[m] or '?'), m ~= 0, 'mode')
  button(PP.used and 'used' or 'all', PP.used, 'used')
  button('in tracker', ctx.envs_shown(), 'shown')
  button('find', false, 'find')
  button('native', false, 'native')
  return hv
end

function PP.draw(L, x, y, w, h, col, focused)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  PP.hover = nil
  if not col then U.text(x, y, 'no track', U.GREY); return end
  local tr = col.track
  PP.build(tr, ctx.fx_addresses)
  local hv = header(L, x, y, w, tr, mx, my)
  y, h = y + L.rh + 2, h - L.rh - 2
  local rows = PP.visible_rows(tr)
  PP.shown = rows
  -- ширины: имя тянется
  local cw = U.measure('W')
  local fixed = 0
  for i = 2, #PP.COLS do fixed = fixed + PP.COLS[i].w * cw + L.pad end
  local name_w = math.max(cw * 8, w - fixed - L.pad)
  local xs, ws, cx = {}, {}, x
  for i, c in ipairs(PP.COLS) do
    xs[i], ws[i] = cx, (i == 1) and name_w or c.w * cw
    cx = cx + ws[i] + L.pad
  end
  U.text(x, y, ctx.fit(col.name .. ' - ' .. #rows .. (PP.used and ' used' or ' parameters'), name_w), U.GREY)
  for i = 2, #PP.COLS do
    if xs[i] + ws[i] > x + w + 1 then break end
    U.text(xs[i], y, ctx.fit(PP.COLS[i].head, ws[i]), U.GREY)
  end
  U.set(U.LINE); gfx.rect(x, y + L.rh, w, 1, 1)
  local top = y + L.rh + 2
  local nvis = math.max(1, math.floor((h - L.rh - 2) / L.rh))
  PP.nvis = nvis
  if PP.row > #rows then PP.row = math.max(1, #rows) end
  if PP.row - 1 < PP.scroll then PP.scroll = PP.row - 1 end
  if PP.row - 1 >= PP.scroll + nvis then PP.scroll = PP.row - nvis end
  PP.scroll = math.max(0, math.min(PP.scroll, math.max(0, #rows - nvis)))
  if U.vbar then U.vbar('params', x, top, w, nvis * L.rh, PP.scroll, nvis, #rows) end   -- 15 окт: длинному списку — полоса всегда
  if #rows == 0 then U.text(x, top, ctx.fit(PP.used and 'nothing automated or modulated yet - v: all parameters' or 'no parameters', w), U.GREY) end
  local now = R.time_precise()
  local fresh = not PP.t or now - PP.t > 0.25
  if fresh then PP.t = now end
  for i = 1, nvis do
    local ri = PP.scroll + i
    local r = rows[ri]
    if not r then break end
    if fresh or r.has == nil then PP.refresh_row(tr, r) end
    local ry = top + (i - 1) * L.rh
    for ci, c in ipairs(PP.COLS) do
      if xs[ci] + ws[ci] > x + w + 1 then break end
      local txt, colr
      if c.key == 'name' then
        txt, colr = r.label, (ri == PP.row) and U.AMBER or (r.used and U.TEXT or U.GREY)
      elseif c.key == 'env' then
        txt = not r.has and '-' or (r.vis and 'vis' or 'hid')
        colr = r.vis and U.GREEN or (r.has and U.TEXT or U.DIM)
      elseif c.key == 'act' then txt, colr = r.has and (r.act and 'on' or 'off') or '-', r.act and U.GREEN or U.DIM
      elseif c.key == 'arm' then txt, colr = r.has and (r.arm and 'on' or 'off') or '-', r.arm and U.RED or U.DIM
      elseif c.key == 'pts' then txt, colr = r.has and tostring(r.pts or 0) or '-', r.has and U.TEXT or U.DIM
      elseif c.key == 'mod' then
        if r.kind ~= 'fx' then txt, colr = '', U.DIM
        else txt = r.mod and ((r.lfo and 'L' or '.') .. (r.acs and 'E' or '.') .. (r.lnk and 'K' or '.')) or '-'; colr = r.mod and U.CYAN or U.DIM end
      else txt, colr = r.val or '', U.GREY end
      txt = ctx.fit(txt, ws[ci])
      if focused and ri == PP.row and ci == PP.col then
        U.set(U.TEXT); gfx.rect(xs[ci] - 1, ry, ws[ci] + 2, L.rh, 1)
        U.text(xs[ci], ry + 1, txt, U.BG, U.TEXT)
      else
        U.text(xs[ci], ry + 1, txt, colr)
      end
      if mx >= xs[ci] - 1 and mx < xs[ci] + ws[ci] + L.pad and my >= ry and my < ry + L.rh then hv = { row = ri, col = ci } end
    end
  end
  PP.hover = hv
  return hv
end

-- ── мышь и клавиши ───────────────────────────────────────────────────────
function PP.click(col, hv, dbl)
  if not col or not hv then return end
  local tr = col.track
  if hv.btn == 'mode' then PP.cycle_mode(tr, 1)
  elseif hv.btn == 'used' then PP.used = not PP.used; PP.dirty = true; PP.row, PP.scroll = 1, 0
  elseif hv.btn == 'shown' then ctx.toggle_track_envs(col)
  elseif hv.btn == 'find' then PP.find(col)
  elseif hv.btn == 'native' then ctx.with_only_track(tr, function() R.Main_OnCommand(40292, 0) end)
  elseif hv.row then
    local same = PP.row == hv.row and PP.col == hv.col
    PP.row, PP.col = hv.row, hv.col
    -- ячейки-тогглы — с первого клика, имя — двойным
    if PP.COLS[hv.col].key ~= 'name' and PP.COLS[hv.col].key ~= 'val' or dbl or same then PP.activate(tr, PP.cur_row()) end
  end
end

-- fzf по строкам → курсор на найденную (в режиме used — снова все)
function PP.find(col)
  local items = {}
  for i, r in ipairs(PP.all or {}) do items[#items + 1] = { label = r.label, data = i } end
  ctx.open_picker('parameter of ' .. col.name, items, function(it)
    PP.used = false
    PP.row = it.data
    PP.col = 2
  end)
end

function PP.wheel(d)
  PP.scroll = math.max(0, PP.scroll + d)
  local n = #(PP.shown or {})
  PP.row = math.max(1, math.min(n, math.max(PP.row, PP.scroll + 1)))
  if PP.nvis and PP.row > PP.scroll + PP.nvis then PP.row = PP.scroll + PP.nvis end
end

-- true — съедена; 'leave' — назад в матрицу
function PP.key(c, col)
  if not col then return false end
  local tr = col.track
  local ch = c < 256 and string.char(c) or ''
  local n = #(PP.shown or {})
  local r = PP.cur_row()
  if ch == 'j' or c == 1685026670 then PP.row = math.min(math.max(1, n), PP.row + 1)
  elseif ch == 'k' or c == 30064 then PP.row = math.max(1, PP.row - 1)
  elseif ch == 'h' or c == 1818584692 then PP.col = math.max(1, PP.col - 1)
  elseif ch == 'l' or c == 1919379572 then PP.col = math.min(#PP.COLS, PP.col + 1)
  elseif ch == 'g' then PP.row = 1
  elseif ch == 'G' then PP.row = math.max(1, n)
  elseif c == 6 then PP.row = math.min(math.max(1, n), PP.row + (PP.nvis or 10))     -- ^F
  elseif c == 2 then PP.row = math.max(1, PP.row - (PP.nvis or 10))                  -- ^B
  elseif c == 13 or ch == ' ' then PP.activate(tr, r)
  elseif ch == 'e' then PP.activate(tr, r, 'env')
  elseif ch == 'a' then PP.activate(tr, r, 'arm')
  elseif ch == 'b' then PP.activate(tr, r, 'act')
  elseif ch == 'm' then PP.activate(tr, r, 'mod')
  elseif ch == 'w' then if r and r.kind == 'fx' then ctx.mod_window(r) end
  elseif ch == 'o' then if r and r.kind == 'fx' then ctx.fx_show(r.fx) end
  elseif ch == 'c' then if r then ctx.curve_to(tr, r) end
  elseif ch == 'v' then PP.used = not PP.used; PP.dirty = true; PP.row, PP.scroll = 1, 0
  elseif ch == 'M' then PP.cycle_mode(tr, 1)
  elseif ch == '/' or ch == 'f' then PP.find(col)
  elseif ch == 'P' or c == 27 then return 'leave'
  else return false end
  return true
end

return PP
