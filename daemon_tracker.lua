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

-- нижний ряд: 1 play 2 stop 3 rec 4 follow 5 loop 6 clips (вид clips трекера → страница clips); 7..10 lpb− lpb+ oct− oct+
local BOTTOM = { 'play', 'stop', 'rec', 'follow', 'loop', 'clips', 'lpb-', 'lpb+', 'oct-', 'oct+', 'step-', 'step+', 'inst-', 'inst+' }

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
    rows[8][6] = 6                                  -- clips: вид clips трекера, грид → страница clips
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

-- ── страница CLIPS (7 окт): сессия трекера на гриде ──────────────────────
-- Включается сама, когда в трекере открыт вид clips (тело / матрица / zz):
-- грид — зеркало экрана. Состояние — jf_tracker/ss (SS.grid_pub), команды —
-- jf_tracker/ssgrid «cmd;cmd,n» (SS.grid_cmd). Логические колонки 1..15 без
-- столбца хоста (при ctl_side = left всё сдвинуто на 1 вправо):
--   1..7  ×  ряды 1..7   клипы: колонка — трек, ряд — сцена; нажатие — запуск
--   1..7  ×  ряд 8       стоп трека
--   8     ×  ряды 1..7   сцена целиком
--   8     ×  ряд 8       stop all; долгое (0.6 с) — закрыть вид clips (грид → матрица)
--   9..15 ×  ряды 1..8   mlr: колонка — трек 1..7 окна, ряд — 1/8 играющего
--                        клипа; огонёк бежит; нажатие — прыжок в этот шаг
--                        (на доле, при quant now — сразу); две зажатые кнопки
--                        — луп отрезка между ними, держится; снова одно
--                        нажатие — весь клип с этого шага
-- Arc: 1 сцены (прокрутка), 2 треки (прокрутка), 3 громкость трека курсора,
-- 4 квантизация запуска bar / beat / now.
local CW, LONG = 7, 0.6
local LAYOUT_MX, LAYOUT_CLIPS   -- карты страниц, заданы в конце файла
local cl = { rs = 0, cs = 0, last = '', p = nil, held = {}, used = {}, acc = { 0, 0, 0, 0 }, sa_t = nil, n = 0 }

local function parse_ss(str)
  local h, cells, trs = str:match('^([^;]*);([^;]*);(.*)$')
  if not h then return nil end
  local v = {}
  for x in h:gmatch('%-?%d+') do v[#v + 1] = tonumber(x) end
  if #v < 7 then return nil end
  local p = { view = v[1] == 1, nr = v[2], nc = v[3], cri = v[4], cci = v[5], quant = v[6], playing = v[7] == 1, cells = cells, tr = {} }
  for t in trs:gmatch('%S+') do
    local a = {}
    for x in t:gmatch('%-?%d+') do a[#a + 1] = tonumber(x) end
    p.tr[#p.tr + 1] = { ri = a[1] or 0, step = a[2] or -1, k1 = a[3] or -1, k2 = a[4] or -1, pend = a[5] or 0, vol = a[6] or 0 }
  end
  return p
end
local function ss_cell(p, ri, ci)
  local i = (ri - 1) * p.nc + ci
  return p.cells:sub(i, i)
end

local function clips_frame(mono, p, off)
  local rows = {}
  for y = 1, 8 do rows[y] = {}; for x = 1, 16 do rows[y][x] = 0 end end
  local blink = math.floor(reaper.time_precise() * 4) % 2 == 0
  local function put(lx, y, v) rows[y][lx + off] = v end
  for k = 1, CW do
    local ci = cl.cs + k
    local t = p.tr[ci]
    if ci <= p.nc and t then
      for y = 1, 7 do
        local ri = cl.rs + y
        if ri <= p.nr then
          local c = ss_cell(p, ri, ci)
          local v = c == 'o' and 4 or (c == 'm' and 2 or 0)
          if t.ri == ri then v = (t.step >= 0 and t.step % 2 == 0) and 15 or 11 end     -- играет: пульс по шагам
          if t.pend == 1 and ri == p.cri and ci == p.cci then v = blink and 15 or 3 end
          if ri == p.cri and ci == p.cci and v < 6 then v = 6 end                      -- курсор трекера
          put(k, y, v)
        end
      end
      put(k, 8, t.pend == 2 and (blink and 12 or 2) or (t.ri > 0 and 7 or 1))
      -- mlr
      if t.ri > 0 then
        for y = 1, 8 do
          local s = y - 1
          local v = 2
          if t.k1 >= 0 and s >= t.k1 and s <= t.k2 then v = 6 end
          if s == t.step then v = 15 end
          if cl.held[(8 + k) .. ',' .. y] then v = 15 end
          put(8 + k, y, v)
        end
      end
    end
  end
  for y = 1, 7 do
    local ri = cl.rs + y
    if ri <= p.nr then
      local any = false
      for ci = 1, p.nc do if ss_cell(p, ri, ci) == 'o' then any = true; break end end
      put(8, y, any and (ri == p.cri and 9 or 4) or 1)
    end
  end
  put(8, 8, p.playing and 8 or 3)
  mono.leds(rows)
end

local function clips_tick(mono, p, off, send)
  local now = reaper.time_precise()
  for _, e in ipairs(mono.keys_nc or mono.keys or {}) do
    local lx, y, s = e[1] + 1 - off, e[2] + 1, e[3]
    local key = lx .. ',' .. y
    if s == 1 then cl.held[key] = now else cl.held[key] = nil end
    if lx >= 1 and lx <= 15 then
      if s == 1 and lx <= CW then
        local ci = cl.cs + lx
        if y == 8 then send(('stop %d'):format(ci))
        elseif cl.rs + y <= p.nr then send(('launch %d %d'):format(cl.rs + y, ci)) end
      elseif lx == 8 and y == 8 then
        if s == 1 then cl.sa_t = now
        elseif cl.sa_t then
          if now - cl.sa_t >= LONG then send('clips') else send('stopall') end
          cl.sa_t = nil
        end
      elseif s == 1 and lx == 8 then
        if cl.rs + y <= p.nr then send(('scene %d'):format(cl.rs + y)) end
      elseif s == 1 and lx >= 9 then
        local k = lx - 8
        local ci = cl.cs + k
        -- вторая кнопка, пока первая в той же колонке зажата, — луп отрезка
        local other
        for yy = 1, 8 do if yy ~= y and cl.held[lx .. ',' .. yy] then other = yy end end
        if other then send(('loop %d %d %d'):format(ci, other - 1, y - 1))
        else send(('jump %d %d'):format(ci, y - 1)) end
      end
    end
  end
  -- arc
  for _, e in ipairs(mono.encs or {}) do
    local n, d = e[1] + 1, e[2]
    cl.acc[n] = cl.acc[n] + d
    local step = n == 3 and 2 or (n == 4 and 24 or 12)
    while math.abs(cl.acc[n]) >= step do
      local dir = cl.acc[n] > 0 and 1 or -1
      cl.acc[n] = cl.acc[n] - dir * step
      if n == 1 then cl.rs = math.max(0, math.min(math.max(0, p.nr - 7), cl.rs + dir))
      elseif n == 2 then cl.cs = math.max(0, math.min(math.max(0, p.nc - CW), cl.cs + dir))
      elseif n == 3 then send(('vol %d %d'):format(p.cci, dir))
      elseif n == 4 then send('quant') end
    end
  end
  if mono.grid_ok then clips_frame(mono, p, off) end
  if mono.arc_ok then
    local t = p.tr[p.cci]
    local fr = { p.nr > 7 and cl.rs / (p.nr - 7) or 0, p.nc > CW and cl.cs / (p.nc - CW) or 0, t and t.vol / 100 or 0 }
    for n = 1, 3 do
      local levels = {}
      local lit = math.floor(fr[n] * 63 + 0.5) + 1
      for i = 1, 64 do levels[i] = (n == 3 and i <= lit or i == lit) and 12 or 1 end
      mono.ring(n - 1, levels)
    end
    local levels = {}
    for i = 1, 64 do levels[i] = (math.floor((i - 1) / 21.34) == p.quant) and 10 or 1 end
    mono.ring(3, levels)
  end
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
  local ssv = reaper.GetExtState(EXT, 'ss')
  if ssv ~= cl.last then cl.last = ssv; cl.p = parse_ss(ssv) end
  M.layout = (live and cl.p and cl.p.view) and LAYOUT_CLIPS or LAYOUT_MX
  if mono.owner ~= M.id then return end
  if live and cl.p and cl.p.view then
    -- команды за тик — одной строкой: две кнопки в одном тике не затирают друг друга
    local out = {}
    clips_tick(mono, cl.p, reaper.GetExtState('jf_mono', 'ctl_side') == 'left' and 1 or 0, function(c) out[#out + 1] = c end)
    if #out > 0 then
      cl.n = cl.n + 1
      reaper.SetExtState(EXT, 'ssgrid', table.concat(out, ';') .. ',' .. cl.n, false)
      st.status = out[#out]
    end
    return
  end
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
    { cells = { 'play', 'stop', 'rec', 'flw', 'loop', 'clip', 'lpb-', 'lpb+',
                'oct-', 'oct+', 'stp-', 'stp+', 'ins-', 'ins+' },
      right = 'transport · follow · loop · clips view  |  lpb · octave · edit step · instrument' },
  },
  enc = { { 'LPB (lines per beat)', 'octave', 'edit step', 'instrument' } },
  hint = 'more than 7 slots: the window scrolls with the tracker cursor' }

LAYOUT_MX = M.layout
-- карта страницы clips (окно демона / подсказка): колонки логические, без столбца хоста
LAYOUT_CLIPS = { rows = {
    { left = 'clips: columns 1-7 = tracks, rows = scenes, tap = launch at the quantize · column 8 = whole scene · columns 9-15 = mlr: 1/8 steps of the playing clip, tap = jump, hold two = loop the range', span = 7,
      cells = { nil, nil, nil, nil, nil, nil, nil, 'scn' } },
    {}, {}, {}, {}, {}, {},
    { cells = { 'stop', 'stop', 'stop', 'stop', 'stop', 'stop', 'stop', 'all' },
      right = 'stop track · stop all (hold = close the clips view)' },
  },
  enc = { { 'scenes', 'tracks', 'volume', 'quantize' } },
  hint = 'the page follows the tracker: open clips there (zs, clips button, zz)' }
M.layout_clips = LAYOUT_CLIPS

function M.state() return st end
return M
