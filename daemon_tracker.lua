-- daemon_tracker.lua — МОДУЛЬ демона jf_grid для трекера jf_tracker (этап 9).
--
-- Загружается демоном (jf_grid.lua), отдельно не запускается. Мод появляется
-- в списке миграции демона, когда на треке стоит jf_tracker_scope (мост
-- осциллоскопа трекера, `:scopes`) — он же метка присутствия, как JSFX у
-- других модов. Поверхность мод получает явно (список по удержанию кнопки arc).
--
-- Грид = матрица паттернов трекера: ряд — слот последовательности, колонка —
-- трек. Данные идут через ExtState (оба процесса в одном REAPER):
--   jf_tracker/mx      «nrows,ncols,cur_ri,cur_ci,play_ri,queue_ri;<ячейки>»
--                      ячейка: . пусто, o события, x всё заглушено
--   jf_tracker/gridkey «x,y,n» — нажатие (n растёт), трекер ставит регион в
--                      очередь (играет) или играет с него (стоит), курсор туда
-- Яркость: пусто 1, события 6, заглушено 3, строка плейхеда 12, очередь 9,
-- курсор 15. Больше 7 слотов — прокрутка окна за курсором. Нижний ряд —
-- транспорт: play stop rec follow loop | lpb−+ oct−+ step−+ inst−+ (команды
-- через jf_tracker/cmd «имя,n»). Arc: 1 LPB, 2 октава, 3 шаг, 4 инструмент
-- (кольца — уровень из jf_tracker/st). Правый столбец — у хоста.

local M = { ns = 'jf_tracker_mono', id = 9, name = 'tracker' }
local EXT = 'jf_tracker'
local st = { n = 0, scroll = 0, last_mx = '', parsed = nil, status = '' }

local function parse(str)
  local head, cells = str:match('^([^;]*);(.*)$')
  if not head then return nil end
  local nr, nc, cri, cci, pri, qri = head:match('^(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)$')
  if not nr then return nil end
  return { nr = tonumber(nr), nc = tonumber(nc), cri = tonumber(cri), cci = tonumber(cci),
           pri = tonumber(pri), qri = tonumber(qri), cells = cells }
end

local function cell(p, ri, ci)
  local i = (ri - 1) * p.nc + ci
  return p.cells:sub(i, i)
end

-- состояние трекера для колец и нижнего ряда
local function parse_st(str)
  local t = {}
  for v in (str or ''):gmatch('%-?%d+') do t[#t + 1] = tonumber(v) end
  if #t < 9 then return nil end
  return { lpb = t[1], oct = t[2], step = t[3], inst = t[4], ninst = t[5], playing = t[6] == 1, follow = t[7] == 1, loop = t[8] == 1, armed = t[9] == 1 }
end

-- нижний ряд: 1 play 2 stop 3 rec 4 follow 5 loop 6 — (был clips, удалён 30 окт); 7..10 lpb− lpb+ oct− oct+
local BOTTOM = { 'play', 'stop', 'rec', 'follow', 'loop', false, 'lpb-', 'lpb+', 'oct-', 'oct+', 'step-', 'step+', 'inst-', 'inst+' }

local function frame(mono, p, ts)
  local rows = {}
  for y = 1, 8 do rows[y] = {}; for x = 1, 16 do rows[y][x] = 0 end end
  if not p then rows[8][16] = 2; mono.leds(rows); return end
  -- окно по слотам: 7 рядов (нижний — транспорт), курсор держим внутри
  if p.cri - 1 < st.scroll then st.scroll = p.cri - 1 end
  if p.cri - 1 >= st.scroll + 7 then st.scroll = p.cri - 7 end
  if ts then
    rows[8][1] = ts.playing and 15 or 5
    rows[8][2] = 4
    rows[8][3] = ts.armed and 12 or 3
    rows[8][4] = ts.follow and 10 or 3
    rows[8][5] = ts.loop and 10 or 3
    for x = 7, 14 do rows[8][x] = 3 end
  end
  for y = 1, 7 do
    local ri = st.scroll + y
    if ri > p.nr then break end
    for x = 1, math.min(15, p.nc) do
      local c = cell(p, ri, x)
      local v = (c == 'o') and 6 or ((c == 'x') and 3 or 1)
      if ri == p.pri then v = 12 end
      if ri == p.qri then v = 9 end
      if ri == p.cri and x == p.cci then v = 15 end
      rows[y][x] = v
    end
  end
  mono.leds(rows)
end

function M.tick(mono)
  local mx = reaper.GetExtState(EXT, 'mx')
  if mx ~= st.last_mx then st.last_mx = mx; st.parsed = parse(mx) end
  local p = st.parsed
  local hb = reaper.GetExtState(EXT, 'hb')
  local live = hb ~= '' and p ~= nil
  if reaper.time_precise() - (st.diag_t or 0) > 1 then
    st.diag_t = reaper.time_precise()
    reaper.SetExtState('jf_mono', 'tracker', (live and ('трекер жив, слотов ' .. p.nr) or 'ТРЕКЕРА НЕТ / нет регионов') .. ' | ' .. st.status, false)
  end
  local ts = parse_st(reaper.GetExtState(EXT, 'st'))
  if mono.owner ~= M.id then return end
  local function cmd(name)
    st.n = st.n + 1
    reaper.SetExtState(EXT, 'cmd', name .. ',' .. st.n, false)
    st.status = name
  end
  -- КООРДИНАТЫ ДЕМОНА С НУЛЯ (x 0..15, y 0..7, энкодеры и кольца 0..3) —
  -- исправлено 1 окт сессией jf_grid: модуль считал с единицы, поэтому
  -- нижний ряд-транспорт не срабатывал, матрица была сдвинута на ряд и
  -- колонку, энкодер 1 молчал, кольца уезжали. Внутри модуля всё по-прежнему
  -- с единицы — переводим на входе (+1) и на выходе колец (-1).
  for _, e in ipairs(mono.keys_nc or mono.keys or {}) do
    local x, y, s = e[1] + 1, e[2] + 1, e[3]
    if s == 1 then
      if y == 8 then
        if BOTTOM[x] then cmd(BOTTOM[x]) end
      elseif p and x <= 15 then
        local ri = st.scroll + y
        if ri <= p.nr and x <= p.nc then
          st.n = st.n + 1
          reaper.SetExtState(EXT, 'gridkey', ('%d,%d,%d'):format(x, ri, st.n), false)
          st.status = ('слот %d трек %d'):format(ri, x)
        end
      end
    end
  end
  -- 15 окт: arc — мост в трекер. Повороты копим в суммы и пишем jf_tracker/arcenc «t1,t2,t3,t4»
  -- (трекер берёт разницу — ничего не теряется); трекер отвечает уровнями колец jf_tracker/arcrings
  -- «v1..v4» (0..1, -1 — пусто). Кольца ни к чему не привязаны — по-старому: 1 LPB, 2 октава, 3 шаг, 4 инструмент
  st.tot = st.tot or { 0, 0, 0, 0 }
  local rs = {}
  for v in (reaper.GetExtState(EXT, 'arcrings') or ''):gmatch('%-?[%d%.]+') do rs[#rs + 1] = tonumber(v) end
  local bound = #rs >= 4 and (rs[1] >= 0 or rs[2] >= 0 or rs[3] >= 0 or rs[4] >= 0)
  st.acc = st.acc or { 0, 0, 0, 0 }
  local ENC = { { 'lpb-', 'lpb+' }, { 'oct-', 'oct+' }, { 'step-', 'step+' }, { 'inst-', 'inst+' } }
  local moved = false
  for _, e in ipairs(mono.encs or {}) do
    local n, d = e[1] + 1, e[2]
    if n >= 1 and n <= 4 then
      st.tot[n] = st.tot[n] + d; moved = true
      if not bound and ENC[n] then
        st.acc[n] = st.acc[n] + d
        while st.acc[n] >= 8 do st.acc[n] = st.acc[n] - 8; cmd(ENC[n][2]) end
        while st.acc[n] <= -8 do st.acc[n] = st.acc[n] + 8; cmd(ENC[n][1]) end
      end
    end
  end
  if moved or not st.enc_sent then
    reaper.SetExtState(EXT, 'arcenc', table.concat(st.tot, ','), false); st.enc_sent = true
  end
  if mono.grid_ok then frame(mono, live and p or nil, ts) end
  if mono.arc_ok and bound then
    for n = 1, 4 do
      local levels = {}
      local v = rs[n]
      local lit = v >= 0 and math.floor(v * 64 + 0.5) or 0
      for i = 1, 64 do levels[i] = v < 0 and 0 or (i <= lit and 10 or 1) end
      mono.ring(n - 1, levels)
    end
  elseif mono.arc_ok and ts then
    local LPBS = { 1, 2, 3, 4, 6, 8, 12, 16 }
    local li = 4
    for i, v in ipairs(LPBS) do if v == ts.lpb then li = i end end
    local fr = { li / #LPBS, ts.oct / 8, math.min(1, ts.step / 16), ts.ninst > 0 and ts.inst / ts.ninst or 0 }
    for n = 1, 4 do
      local levels = {}
      local lit = math.floor(fr[n] * 64 + 0.5)
      for i = 1, 64 do levels[i] = i <= lit and 10 or 1 end
      mono.ring(n - 1, levels)
    end
  end
end

-- КАРТА МОДА для окна демона и всплывающей подсказки (1 окт). Живёт ЗДЕСЬ,
-- рядом с кодом управления: поменял кнопку — поправь строку ниже, копии в
-- jf_grid.lua нет. Формат как у LAYOUT в jf_grid.lua: rows[1..8] сверху
-- вниз; left — смысл ряда, right — подпись справа, span — скобка на N рядов,
-- cells[1..16] — ярлык на кнопке; enc[страница][1..4] — подписи колец.
-- Столбец 16 — управление хоста (ярлыки рисует окно само).
M.layout = { rows = {
    { left = 'pattern matrix: row = sequence slot, column = track (15) · tap = queue if playing / play from here if stopped · brightness: 1 empty, 6 events, 3 all muted, 9 queued, 12 playhead, 15 cursor',
      span = 7 },
    {}, {}, {}, {}, {}, {},
    { cells = { 'play', 'stop', 'rec', 'flw', 'loop', '', 'lpb-', 'lpb+',
                'oct-', 'oct+', 'stp-', 'stp+', 'ins-', 'ins+' },
      right = 'transport · follow · loop  |  lpb · octave · edit step · instrument' },
  },
  enc = { { 'LPB (lines per beat)', 'octave', 'edit step', 'instrument' } },
  hint = 'more than 7 slots: the window scrolls with the tracker cursor' }

function M.state() return st end
return M
