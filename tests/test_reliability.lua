-- test_reliability.lua — инварианты трекера (11 окт): то, что должно держаться
-- всегда, при любом масштабе и любом виде колонки, а не один найденный случай.
--   раскладка: поля подколонки идут слева направо и не налезают друг на друга,
--     узкие подколонки без инструмента / слайса, колонка мастера в своём углу;
--   колонка cmd мастера: маркеры по строкам, служебные и регионы — мимо;
--   транспорт: нижний ряд под кнопками, slow мигает, smart — переключатель.
-- Запуск из папки jf_tracker: lua tests/test_reliability.lua
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'

local n, bad = 0, 0
local function ok(cond, what) n = n + 1; if not cond then bad = bad + 1; print('FAIL ' .. what) end end
local function eq(a, b, what) ok(a == b, ('%s: %s ~= %s'):format(what, tostring(a), tostring(b))) end

-- ── заглушки gfx / reaper ────────────────────────────────────────────────
local NOW = 0.1
gfx = { w = 1600, h = 900, texth = 8, x = 0, y = 0, a = 1, mode = 0, dest = -1, mouse_x = 0, mouse_y = 0, mouse_cap = 0,
  measurestr = function(s) return #tostring(s) * 8, 8 end, setfont = function() end, set = function() end, rect = function() end,
  line = function() end, drawstr = function() end, blit = function() end, setimgdim = function() end, getpixel = function() return 0, 0, 0 end,
  setpixel = function() end }
-- маркеры проекта: { isrgn, pos, name, idx }; темп 120 — 1 QN = 0.5 с
local MARKS = {}
reaper = setmetatable({
  time_precise = function() return NOW end,
  TimeMap2_timeToQN = function(_, t) return t * 2 end,
  EnumProjectMarkers3 = function(_, i)
    local m = MARKS[i + 1]
    if not m then return 0 end
    return i + 1, m[1], m[2], m[2], m[3], m[4], 0
  end,
}, { __index = function() return function() return nil end end })

local C = { 0.5, 0.5, 0.5 }
local TEXT = { 0.9, 0.9, 0.9 }
local RED = { 0.9, 0.2, 0.2 }
local U = setmetatable({ readable = function(c) return c end, mix = function(a) return a end, theme = function(_, d) return d end,
  tint = function(c) return c end, TEXT = TEXT, BG = C, GREY = C, CYAN = C, AMBER = C, RED = RED, GREEN = C, DIM = C, LINE = C, PANEL = C },
  { __index = function() return C end })
local D = dofile(DIR .. '/jf_tracker_draw.lua')
D.init(U, nil, nil)

-- ── 1. поля подколонки: слева направо, без наложений, в ширине ───────────
local function col(guid, nsub, envs)
  local subs = {}; for i = 1, nsub do subs[i] = {} end
  return { guid = guid, name = guid, lanes = { { idx = 0, subs = subs, items = {} } }, envs = envs or {}, depth = 0 }
end
local function fields_of(G)
  -- визуальный порядок: нота, инструмент, слайс, громкость, fx…, задержка (что есть у геометрии)
  local t = { { 'note', G.x_note, G.w_note } }
  if G.x_inst then t[#t + 1] = { 'inst', G.x_inst, G.w_inst } end
  if G.x_slc and not G.notes_only then t[#t + 1] = { 'slc', G.x_slc, G.w_slc } end
  if not G.notes_only then
    t[#t + 1] = { 'vol', G.x_vol, G.w_vol }
    if not G.narrow then
      t[#t + 1] = { 'del', G.x_del, G.w_del }   -- 4 ноя: delay за vol, эффекты после
      for k = 1, G.nfx or 0 do if G.x_fx and G.x_fx[k] then t[#t + 1] = { 'fx' .. k, G.x_fx[k], G.w_fx or G.w_vol } end end
    end
  end
  return t
end
local function check_geom(G, name)
  local f = fields_of(G)
  for i, fl in ipairs(f) do
    ok(type(fl[2]) == 'number' and type(fl[3]) == 'number', name .. ': field ' .. fl[1] .. ' has x and w')
    if i > 1 and type(fl[2]) == 'number' then
      local p = f[i - 1]
      ok(p[2] + p[3] <= fl[2], ('%s: %s (%d+%d) overlaps %s (%d)'):format(name, p[1], p[2], p[3], fl[1], fl[2]))
    end
  end
  local lastf = f[#f]
  ok(lastf[2] + lastf[3] <= G.sub_w, ('%s: last field %s ends past the subcolumn (%d > %d)'):format(name, lastf[1], lastf[2] + lastf[3], G.sub_w))
end
local snap = { cols = { col('A', 1), col('B', 3, { { name = 'Volume' } }), col('C', 1) } }
for _, sc in ipairs({ 1, 2, 4 }) do
  local state = { fontscale = sc, folds = {}, fxcols = 1, envs = true, hscroll = 1, wave = 'spec', hints = true }
  D.set_font(state)
  local okL, L = pcall(D.layout, snap, state, 0)
  ok(okL, 'layout x' .. sc .. ' ' .. tostring(not okL and L or ''))
  if okL then
    check_geom(L, 'full x' .. sc)
    -- узкие геометрии: инструмента и слайса нет (false, не наследуются от L)
    for gname, G in pairs({ GN = L.GN, GC = L.GC, GCN = L.GCN }) do
      check_geom(G, gname .. ' x' .. sc)
      ok(not G.x_inst, gname .. ' x' .. sc .. ': no inst field')
      ok(not G.x_slc, gname .. ' x' .. sc .. ': no slice field')
    end
    -- колонки не налезают друг на друга и не уходят за окно
    local prev_r = -1
    for _, c in ipairs(L.cols) do
      if c.x and not c.mtrack then
        ok(c.x >= prev_r, ('x%d: column %s starts inside the previous one'):format(sc, tostring(c.col and c.col.name)))
        prev_r = c.x + (c.w or 0)
      end
    end
  end
end

-- ── 2. колонка мастера: свой угол справа, огибающие и cmd — элементы L.flat ──
do
  local s2 = { cols = { col('A', 1), col('B', 1) },
    master = { track = 'mt', guid = 'master', name = 'master', lanes = {}, envs = { { name = 'Tempo' } }, cmd = { kind = 'cmd', name = 'cmd', ev = {}, rows = {} } } }
  for _, sc in ipairs({ 1, 2 }) do
    local state = { fontscale = sc, folds = {}, fxcols = 1, envs = true, hscroll = 1, wave = 'off' }
    D.set_font(state)
    local okL, L = pcall(D.layout, s2, state, 0)
    ok(okL, 'master layout x' .. sc .. ' ' .. tostring(not okL and L or ''))
    if okL then
      ok(L.mcol ~= nil, 'master column shown by default x' .. sc)
      if L.mcol then
        eq(L.cols_r + L.master_w, L.win_w, 'master corner = window right x' .. sc)
        local fl = L.flat[#L.flat]
        ok(fl.ml and fl.ml.kind == 'cmd', 'last flat entry is the cmd column x' .. sc)
        ok(fl.x + fl.w <= L.win_w, 'cmd column inside the window x' .. sc)
        local envf = L.flat[#L.flat - 1]
        ok(envf.env and envf.x + envf.w <= fl.x, 'Tempo before cmd, no overlap x' .. sc)
        for _, c in ipairs(L.cols) do
          if c.x and not c.mtrack then ok(c.x + (c.w or 0) <= L.cols_r + 1, ('x%d: track %s runs into the master corner'):format(sc, c.col.name)) end
        end
      end
    end
    state.showmaster = false
    local okL2, L2 = pcall(D.layout, s2, state, 0)
    ok(okL2 and L2.mcol == nil, 'show master off: no master column x' .. sc)
  end
end

-- ── 3. транспорт: нижний ряд ───────────────────────────────────────────────
do
  local ids = {}
  for _, b in ipairs(D.transport_sub({})) do ids[#ids + 1] = b[1] or '-' end
  eq(table.concat(ids, ' '), 'tp_start stophere slowplay freeze shiftrec tp_end', 'transport sub row: under rew pause play loop rec ff (19 окт)')
  local top = {}
  for _, b in ipairs(D.transport_buttons({ tptext = true })) do top[#top + 1] = b[1] end
  eq(table.concat(top, ' '), 'tp_rew tp_pause tp_play loop rec tp_fwd', 'transport: loop next to play, ff at the right end')
  local function slow(c) for _, b in ipairs(D.transport_sub(c)) do if b[1] == 'slowplay' then return b end end end
  local function half(c, k) return slow(c).halves[k] end   -- 12 окт: x0.5 | x2
  NOW = 0.1; eq(half({ halfplay = 0.5 }, 1)[3], TEXT, 'x0.5 on: lit in the first half second'); eq(half({ halfplay = 0.5 }, 2)[3], nil, 'x2 off meanwhile')
  NOW = 0.1; eq(half({ halfplay = 2 }, 2)[3], TEXT, 'x2 on: lit')
  NOW = 0.6; eq(half({ halfplay = 0.5 }, 1)[3], nil, 'x0.5 on: dark in the second half (blinks)')
  eq(slow({})[4], nil, 'slow: no fixed bright text colour')
  local function smart(c) for _, b in ipairs(D.transport_sub(c)) do if b[1] == 'shiftrec' then return b end end end
  eq(smart({ shiftrec = 'rec' })[3], RED, 'shift rec recording: red')
  eq(smart({ shiftrec = 'rec' })[2], '^O^', 'shift rec: the button is ^O^ (15 окт; was ^O, shift, smart)')
  eq(smart({})[3], nil, 'smart off: plain')
end

-- ── 4. колонка cmd мастера: маркеры по строкам ─────────────────────────────
do
  local M = dofile(DIR .. '/jf_tracker_model.lua')
  -- lpb 4, 1 QN = 0.5 с: строка = 0.125 с
  MARKS = {
    { false, 0.25, '!40044', 1 },      -- строка 2
    { true, 0.0, 'verse', 2 },          -- регион — не команда
    { false, 0.5, '=START', 3 },        -- служебный маркер трекера
    { false, 1.0, '', 4 },              -- безымянный — строка 8
    { false, 0.26, 'B01', 5 },          -- та же строка 2
  }
  local ml = M.cmd_lane(4)
  eq(ml.kind, 'cmd', 'cmd lane kind')
  eq(#ml.rows, 2, 'cmd lane: two rows (regions and =markers skipped)')
  eq(ml.rows[1], 2, 'cmd lane: rows sorted, first is 2')
  eq(ml.rows[2], 8, 'cmd lane: second is 8')
  eq(ml.ev[2] and ml.ev[2].n, 2, 'cmd lane: two markers on row 2 counted')
  eq(ml.ev[2] and ml.ev[2].text, '!40044 B01', 'cmd lane: both texts shown')
  eq(ml.ev[8] and ml.ev[8].text, '', 'cmd lane: unnamed marker kept (shown as mark)')
  -- 11 окт: v: — колонка visor, не cmd
  MARKS = { { false, 0.25, 'v:blobtv', 1 }, { false, 0.5, '!40044', 2 }, { false, 1.0, 'v: fluid ', 3 } }
  eq(#M.cmd_lane(4).rows, 1, 'cmd lane: v: markers go to the visor column')
  local vl = M.vis_lane(4)
  eq(vl.kind, 'vis', 'visor lane kind')
  eq(#vl.rows, 2, 'visor lane: two events')
  eq(vl.ev[2] and vl.ev[2].text, 'blobtv', 'visor lane: name without v:')
  eq(vl.ev[8] and vl.ev[8].text, 'fluid', 'visor lane: name trimmed')
  MARKS = {}
  eq(#M.cmd_lane(4).rows, 0, 'cmd lane: no markers - empty')
end

-- ── 5. раскладка событий по подколонкам (place): случайные ноты ───────────
-- что бы ни легло, ни одно событие не затирает другое: голова — ровно в одной
-- подколонке, её продолжения указывают на неё, длина строк сохранена
do
  local M = dofile(DIR .. '/jf_tracker_model.lua')
  math.randomseed(11)
  local broken, total = 0, 0
  for _ = 1, 300 do
    local lane = { subs = {} }
    local heads = {}
    for k = 1, math.random(1, 14) do
      local r0 = math.random(0, 30)
      local r1 = r0 + math.random(0, 6)
      local h = { kind = math.random() < 0.5 and 'audio' or 'midi', id = k }
      M._place(lane, r0, r1, h)
      heads[#heads + 1] = { h = h, r0 = r0, r1 = r1 }
    end
    for _, x in ipairs(heads) do
      total = total + 1
      local found = 0
      for _, sub in ipairs(lane.subs) do
        if sub[x.r0] == x.h then
          found = found + 1
          for r = x.r0 + 1, x.r1 - 1 do if not (sub[r] and sub[r].of == x.h) then found = -99 end end
        end
      end
      if found ~= 1 or x.h.rows ~= math.max(1, x.r1 - x.r0 + 1) then broken = broken + 1 end
    end
  end
  eq(broken, 0, ('place: events overwritten or lost in %d random notes'):format(total))
end

print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
