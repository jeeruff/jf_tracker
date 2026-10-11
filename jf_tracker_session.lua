-- jf_tracker_session.lua — session: клипы как в Ableton поверх линейного
-- таймлайна REAPER (6 окт). Большой вид матрицы (zz): ряды — слоты
-- последовательности (сцены), колонки — треки, клетка — клип (items трека
-- в слоте). Запуск клипа сажает его items впереди плейхеда в ЗОНУ СЕССИИ —
-- регион =SESSION за =END (трекер его не показывает), транспорт крутит зону
-- лупом; у каждого трека своя фаза и длина цикла (= длина слота). Смена
-- клипа — на границе квантизации (такт / доля / сразу): то, что доигрывает
-- до границы, остаётся, дальше — новый клип; остаток старого убирается,
-- когда граница пройдена (SS.todo), и окно досаживается новым.
--
-- Клавиши (Vim): h j k l — клетка, Enter / o — запустить клип, x — стоп
-- трека, X — стоп всех, f + метка — клип, F + метка — вся сцена (ряд),
-- Enter на заголовке ряда — сцена, q — квантизация, Space — транспорт,
-- Q — выход из сессии: транспорт стоп, зона очищена, Esc / zz — закрыть вид.
-- Бросок файла / карточки pm на клетку — в слот трека (ctx.ss_drop).
--
-- Без reaper.* и gfx в логике: REAPER — через ctx.ss_* (main); рисование —
-- SS.draw_big (gfx). Логика тестируется tests/test_session.lua.

local SS = {}
local U, ctx

SS.cur = { ri = 1, ci = 1 }
SS.live = {}          -- [ci] = { ri, phase, len }   — играет
SS.pend = {}          -- [ci] = { ri | 'stop', at }   — ждёт границы
SS.todo = {}          -- [ci] = { from, to, ri, phase } — досадить окно после границы
SS.quant = 'bar'      -- 'bar' | 'beat' | 'now'
SS.scroll, SS.hs = 0, 0
SS.scene_mode = false -- F: следующая метка f запускает сцену ряда
SS.last_pos = nil
SS.BLINK = 0.25
SS.LOOK = 0.08        -- с, упреждение границы (2-3 кадра)

function SS.init(u, c) U, ctx = u, c end

SS.QUANTS = { 'bar', 'beat', 'now' }
function SS.next_quant()
  for i, q in ipairs(SS.QUANTS) do if q == SS.quant then SS.quant = SS.QUANTS[i % #SS.QUANTS + 1]; return SS.quant end end
  SS.quant = 'bar'; return SS.quant
end

-- ── раскладка (чистая) ───────────────────────────────────────────────────
-- hdr_w — колонка имён сцен; top — шапка (строка кнопок + имена треков);
-- клетки не уже 8 знаков и не ниже 3 строк; влезают все — тянутся (до 6
-- строк / 24 знаков), иначе прокрутка
function SS.layout(w, h, ncols, nrows, cw, rh, pad, compact, need)
  -- 11 окт: колонка сцен — по самому длинному «> имя» (need, px), не шире трети; без need — как было
  local hdr_w = compact and math.max(cw * 6, math.min(cw * 10, math.floor(w * 0.3))) or math.max(cw * 10, math.min(cw * 16, math.floor(w * 0.18)))
  if need then hdr_w = math.max(cw * 6, math.min(need, math.floor(w / 3))) end
  local top = compact and (rh + 2 * pad) or (2 * rh + 3 * pad)
  local avail_w, avail_h = w - hdr_w - 2 * pad, h - top - pad
  local min_w, min_h = cw * (compact and 5 or 8), compact and (rh + 4) or rh * 3
  local cell_w = ncols > 0 and math.floor(avail_w / ncols) or avail_w
  cell_w = math.max(min_w, math.min(cw * (compact and 12 or 20), cell_w))
  local cell_h = nrows > 0 and math.floor(avail_h / nrows) or avail_h
  cell_h = math.max(min_h, math.min(compact and (rh * 2) or (rh * 4), cell_h))   -- компактные — до 2 строк (6 окт)
  return { hdr_w = hdr_w, top = top, cell_w = cell_w, cell_h = cell_h,
           cols_fit = math.max(1, math.floor(avail_w / cell_w)), rows_fit = math.max(1, math.floor(avail_h / cell_h)) }
end

-- высота компактной сетки под nrows рядов, не выше cap
function SS.height(w, cap, ncols, nrows, cw, rh, pad)
  local lay = SS.layout(w, cap, ncols, nrows, cw, rh, pad, true)
  return math.min(cap, lay.top + math.max(1, nrows) * lay.cell_h + pad)
end

-- ── границы ──────────────────────────────────────────────────────────────
-- следующая граница квантизации после pos внутри зоны; за концом зоны —
-- z1 (= момент прыжка лупа, фаза тогда z0). bar_after / beat_after — ctx
function SS.next_boundary(pos, zone, quant)
  if quant == 'now' then return pos end
  local t = quant == 'beat' and ctx.ss_beat_after(pos) or ctx.ss_bar_after(pos)
  if t >= zone.rgnend - 1e-6 then return zone.rgnend end
  return t
end
-- доля прохода клипа 0..1 (прогресс в клетке)
-- live.a / live.full (7 окт, mlr): клип играет отрезок [a, a + len) из
-- полной длины full — прогресс считается по всему клипу
function SS.progress(live, pos)
  if not live or live.len <= 0 then return 0 end
  local d = (pos - live.phase) % live.len
  return ((live.a or 0) + d) / (live.full or live.len)
end
-- шаг клипа 0..STEPS-1 под плейхедом (колонка mlr на гриде)
SS.STEPS = 8
function SS.step_of(live, pos)
  if not live then return nil end
  return math.max(0, math.min(SS.STEPS - 1, math.floor(SS.progress(live, pos) * SS.STEPS + 1e-9)))
end

-- ── полиметрия (7 окт) ───────────────────────────────────────────────────
-- длина зоны в долях = НОК длин клипов (в шестнадцатых): клип 4/4 и 5/4 —
-- зона 20 долей, на прыжке лупа фаза каждого сходится. Больше cap долей —
-- cap (фаза сбрасывается на шве), второй результат true
SS.CAP_QN = 256
function SS.lcm_qn(lens, cap)
  cap = cap or SS.CAP_QN
  local function gcd(a, b) while b ~= 0 do a, b = b, a % b end return a end
  local l = 1
  for _, q in ipairs(lens) do
    local n = math.max(1, math.floor(q * 4 + 0.5))
    l = l // gcd(l, n) * n
    if l > cap * 4 then return cap, true end
  end
  return l / 4, false
end
-- доли клипов, что играют / ждут, плюс новый (extra — слот seq)
function SS.need_qn(seq, extra)
  local lens = {}
  local function add(ri) local rg = ri and seq[ri]; if rg and rg.qn1 and rg.qn0 and rg.qn1 > rg.qn0 then lens[#lens + 1] = rg.qn1 - rg.qn0 end end
  for _, l in pairs(SS.live) do add(l.ri) end
  for _, p in pairs(SS.pend) do if p.ri ~= 'stop' then add(p.ri) end end
  add(extra)
  if #lens == 0 then return nil end
  return SS.lcm_qn(lens)
end

-- ── очередь ──────────────────────────────────────────────────────────────
local function clamp(seq, ncols)
  SS.cur.ri = math.max(1, math.min(#seq, SS.cur.ri))
  SS.cur.ci = math.max(1, math.min(math.max(1, ncols), SS.cur.ci))
end
local function arm(ci, what, seq)
  local need, capped = seq and what ~= 'stop' and SS.need_qn(seq, what)
  local pos, playing = ctx.ss_playpos()
  local zone = ctx.ss_zone(need); if not zone then ctx.msg('session: no zone'); return end
  local inside = playing and pos >= zone.pos - 1e-6 and pos < zone.rgnend + 1e-6
  -- зона под НОК длин: растёт на лету (хвост впереди плейхеда досаживается);
  -- без играющих клипов — подгоняется и вниз
  if need and ctx.ss_zone_fit then zone = ctx.ss_zone_fit(zone, need, seq, not inside or not next(SS.live)) or zone end
  if capped then ctx.msg(('session zone capped at %d beats - this clip loses its phase at the seam'):format(SS.CAP_QN)) end
  if not inside then
    -- транспорт стоит или играет аранжировку: в зону, с её начала, сразу
    ctx.ss_play(zone)
    SS.pend[ci] = { ri = what, at = zone.pos, now = true }
    SS.last_pos = nil
  else
    SS.pend[ci] = { ri = what, at = SS.next_boundary(pos, zone, SS.quant) }
  end
end
function SS.launch(ri, ci, seq)
  local rg = seq[ri]; if not rg then return end
  SS.halt = nil
  if SS.live[ci] and SS.live[ci].ri == ri and not SS.pend[ci] and not SS.live[ci].seg then ctx.msg('already playing: ' .. SS.slot_name(rg, ri)); return end
  arm(ci, ri, seq)
  ctx.msg(('launch %s on %s at %s'):format(SS.slot_name(rg, ri), ctx.ss_colname(ci), SS.quant))
end
-- ── follow actions (7 окт): что клип делает, отыграв один проход ─────────
-- l — крутится (по умолчанию), n — следующий клип ниже в колонке, p — выше,
-- f — первый в колонке, r — случайный другой, s — стоп. Хранится у трека
-- (ctx.ss_fa / ctx.ss_fa_set), буква — справа от имени клипа
SS.FA = { 'l', 'n', 'p', 'f', 'r', 's' }
SS.FA_NAME = { l = 'loop', n = 'next', p = 'previous', f = 'first', r = 'random', s = 'stop' }
function SS.fa_next(a, dir)
  for i, v in ipairs(SS.FA) do if v == (a or 'l') then return SS.FA[(i - 1 + (dir or 1)) % #SS.FA + 1] end end
  return 'l'
end
-- клип-цель follow action в колонке ci после ri; nil — стоп, ri — тот же
function SS.fa_target(a, ri, ci, seq, grid, rnd)
  local function has(r) local c = grid and grid[r] and grid[r][ci]; return c and c.state ~= 'empty' end
  if a == 's' then return nil end
  if a == 'n' then for r = ri + 1, #seq do if has(r) then return r end end; for r = 1, ri - 1 do if has(r) then return r end end; return ri end
  if a == 'p' then for r = ri - 1, 1, -1 do if has(r) then return r end end; for r = #seq, ri + 1, -1 do if has(r) then return r end end; return ri end
  if a == 'f' then for r = 1, #seq do if has(r) then return r end end; return ri end
  if a == 'r' then
    local pool = {}
    for r = 1, #seq do if r ~= ri and has(r) then pool[#pool + 1] = r end end
    if #pool == 0 then return ri end
    return pool[math.floor((rnd or math.random)() * #pool) + 1] or pool[1]
  end
  return ri
end

-- ── mlr (7 окт): прыжок и луп отрезка играющего клипа ────────────────────
-- Клип делится на SS.STEPS шагов. jump — с ближайшей доли (или сразу при
-- quant = now) клип играет с шага k; loop k1..k2 — только этот отрезок
-- (включительно), пока не прыгнешь снова. Клип должен играть в зоне.
local function arm_mod(ci, extra, what)
  local live = SS.live[ci]
  if not live then ctx.msg('nothing plays on ' .. ctx.ss_colname(ci)); return false end
  local pos, playing = ctx.ss_playpos()
  local zone = ctx.ss_zone()
  if not zone or not playing or pos < zone.pos - 1e-6 or pos >= zone.rgnend then return false end
  local p = { ri = live.ri, at = SS.next_boundary(pos, zone, SS.quant == 'now' and 'now' or 'beat') }
  for k, v in pairs(extra) do p[k] = v end
  SS.pend[ci] = p
  ctx.msg(('%s on %s'):format(what, ctx.ss_colname(ci)))
  return true
end
function SS.jump(ci, k)
  k = math.max(0, math.min(SS.STEPS - 1, k))
  return arm_mod(ci, { step = k }, 'jump to step ' .. (k + 1))
end
function SS.loop(ci, k1, k2)
  if k1 > k2 then k1, k2 = k2, k1 end
  k1, k2 = math.max(0, k1), math.min(SS.STEPS - 1, k2)
  return arm_mod(ci, { seg = { k1, k2 } }, ('loop steps %d-%d'):format(k1 + 1, k2 + 1))
end

function SS.stop(ci)
  if not SS.live[ci] and not SS.pend[ci] then ctx.msg('nothing plays on ' .. ctx.ss_colname(ci)); return end
  arm(ci, 'stop')
end
-- сцена: клип каждого трека, у кого в ряду что-то есть; пустая клетка — стоп трека
function SS.scene(ri, seq, grid, ncols)
  if not seq[ri] then return end
  local n = 0
  for ci = 1, ncols do
    local cell = grid[ri] and grid[ri][ci]
    if cell and cell.state ~= 'empty' then arm(ci, ri, seq); n = n + 1
    elseif SS.live[ci] or SS.pend[ci] then arm(ci, 'stop') end
  end
  ctx.msg(('scene %s: %d clips'):format(SS.slot_name(seq[ri], ri), n))
end
function SS.stop_all(ncols)
  local n = 0
  for ci = 1, ncols do if SS.live[ci] or SS.pend[ci] then arm(ci, 'stop'); n = n + 1 end end
  -- транспорт встаёт вместе с последним клипом (6 окт: иначе пустая зона крутилась дальше)
  SS.halt = true
  if n == 0 then SS.halt = nil; ctx.ss_stop_transport(); ctx.msg('nothing plays - transport stopped') else ctx.msg(('stop all: %d tracks at %s, then the transport stops'):format(n, SS.quant)) end
end
-- выход: транспорт стоп, зона чистая, состояние сброшено
function SS.quit()
  SS.live, SS.pend, SS.todo = {}, {}, {}
  ctx.ss_quit()
  ctx.msg('session off: zone cleared')
end
function SS.playing_any()
  for _ in pairs(SS.live) do return true end
  for _ in pairs(SS.pend) do return true end
  return false
end

-- follow actions: у играющего клипа с действием (не l) и без очереди —
-- очередь на конец первого прохода (на шве зоны — на прыжок лупа)
function SS.follow_tick(seq, grid)
  local zone
  for ci, lv in pairs(SS.live) do
    if lv.fa and lv.fa ~= 'l' and not SS.pend[ci] and not lv.fa_done then
      zone = zone or ctx.ss_zone()
      if not zone then return end
      local t0 = lv.fired or lv.phase
      local at = lv.phase + math.ceil((t0 + 1e-3 - lv.phase) / lv.len) * lv.len
      if at >= zone.rgnend - 1e-6 then at = zone.rgnend end
      local tgt = SS.fa_target(lv.fa, lv.ri, ci, seq, grid)
      lv.fa_done = true
      if tgt ~= lv.ri then SS.pend[ci] = { ri = tgt or 'stop', at = at, follow = true } end
    end
  end
end

-- что играет после границы phase: весь клип, клип со сдвигом (jump: шаг
-- step под границей) или отрезок шагов seg = { k1, k2 }. Фаза live — момент,
-- когда клип стоит в начале отрезка (a секунд от начала слота)
function SS.mod_live(p, src, phase)
  local full = src.rgnend - src.pos
  local lv = { ri = p.ri, phase = phase, len = full, full = full, a = 0 }
  if p.seg then
    lv.a = p.seg[1] * full / SS.STEPS
    lv.len = (p.seg[2] - p.seg[1] + 1) * full / SS.STEPS
    lv.seg = { p.seg[1], p.seg[2] }
  elseif p.step then
    lv.phase = phase - p.step * full / SS.STEPS
  end
  return lv
end
-- opt посадки: отрезок (секунды проекта внутри слота) или луп клипа из item
function SS.plant_opt(lv, tr, src)
  if lv and lv.seg then return { seg = { src.pos + lv.a, src.pos + lv.a + lv.len } } end
  return ctx.ss_clip_opts and ctx.ss_clip_opts(tr, src)
end

-- лейн колонки сессии (7 окт): посадка только items этого лейна
function SS.lane_opt(opt, col)
  if not (col and col.lane) then return opt end
  local o = {}
  for k, v in pairs(opt or {}) do o[k] = v end
  o.lane = col.lane
  return o
end

-- каждый кадр: границы пройдены — выполнить. seq / snap — текущие
function SS.tick(seq, snap, grid)
  if grid and not SS.halt then SS.follow_tick(seq, grid) end
  if not next(SS.pend) and not next(SS.todo) then return end
  local zone = ctx.ss_zone(); if not zone then return end
  local pos, playing = ctx.ss_playpos()
  if not playing then return end
  local wrapped = SS.last_pos and pos < SS.last_pos - 0.05
  SS.last_pos = pos
  for ci, p in pairs(SS.pend) do
    -- стреляем на SS.LOOK раньше границы: старое режется ровно на границе,
    -- новое уже стоит за ней — без щелчка и без опоздания на кадр
    local at_end = p.at >= zone.rgnend - 1e-6
    local fire = p.now or pos >= p.at - SS.LOOK or (at_end and wrapped)
    if fire then
      local phase = (at_end or p.now) and zone.pos or p.at
      local keep0, keep1 = nil, nil
      if not p.now and not wrapped then
        if phase > pos + 1e-4 then keep0, keep1 = pos, phase
        elseif at_end and pos < zone.rgnend - 1e-4 then keep0, keep1 = pos, zone.rgnend end   -- до прыжка лупа доигрывает старое
      end
      local col = snap.cols[ci]
      local src = p.ri ~= 'stop' and seq[p.ri] or nil
      local lv = src and SS.mod_live(p, src, phase)
      if col then
        ctx.ss_apply(src and 'session launch' or 'session stop', function()
          ctx.alias.session_clear(col.track, zone.pos, zone.rgnend, keep0, keep1, col.lane)
          if src then ctx.alias.session_plant(col.track, src, zone.pos, zone.rgnend, lv.phase, keep0 and { keep0, keep1 } or nil, p.ri .. ':' .. ci, nil, SS.lane_opt(SS.plant_opt(lv, col.track, src), col)) end
        end)
      end
      if lv then lv.fired = phase; lv.fa = ctx.ss_fa and ctx.ss_fa(ci, p.ri, seq) or 'l' end
      SS.live[ci] = lv
      if keep0 then SS.todo[ci] = { from = keep0, to = keep1, ri = src and p.ri or nil, phase = phase, lv = lv } end
      SS.pend[ci] = nil
    end
  end
  -- X: все остановлены — транспорт стоп (клипы уже убраны на границе)
  if SS.halt and not next(SS.live) and not next(SS.pend) then SS.halt = nil; SS.todo = {}; ctx.ss_stop_transport() end
  for ci, t in pairs(SS.todo) do
    if pos >= t.to + 0.02 or wrapped then
      local col = snap.cols[ci]
      local src = t.ri and seq[t.ri]
      if col then
        ctx.ss_apply('session fill', function()
          ctx.alias.session_clear(col.track, t.from, t.to, nil, nil, col.lane)
          if src then ctx.alias.session_plant(col.track, src, zone.pos, zone.rgnend, t.lv and t.lv.phase or t.phase, nil, t.ri .. ':' .. ci, { t.from, t.to }, SS.lane_opt(SS.plant_opt(t.lv, col.track, src), col)) end
        end)
      end
      SS.todo[ci] = nil
    end
  end
end

function SS.slot_name(rg, ri)
  if rg and rg.name and rg.name ~= '' then return rg.name end
  return ('slot %d'):format(ri)
end

-- ── клавиши ──────────────────────────────────────────────────────────────
-- true — съедена. seq, snap, grid — текущие; mods — ctx.mods()
function SS.key(c, seq, snap, grid, mods)
  local ch = c < 256 and string.char(c) or ''
  local ncols = #snap.cols
  if SS.pending_z then
    SS.pending_z = nil
    if ch == 'z' then ctx.ss_big(); return true end
    return c == 27
  end
  local r0, c0 = SS.cur.ri, SS.cur.ci
  local eaten = SS.key_body(c, ch, seq, snap, grid, ncols)
  if eaten and (SS.cur.ri ~= r0 or SS.cur.ci ~= c0) and ctx.ss_focus then ctx.ss_focus(SS.cur.ri, SS.cur.ci, grid) end
  return eaten
end
function SS.key_body(c, ch, seq, snap, grid, ncols)
  -- 11 окт: цифры — номер сцены для s (3s — сцена 3), s — сцена курсора
  local d = tonumber(ch)
  if d and not SS.pending_y and not SS.pending_d and (d > 0 or SS.count) then
    SS.count = (SS.count or 0) * 10 + d
    ctx.msg(('%d: s - start scene %d | Esc'):format(SS.count, SS.count)); return true
  end
  local cnt = SS.count; SS.count = nil
  if ch == 's' then
    local ri = cnt or SS.cur.ri
    if not seq[ri] then ctx.msg('no scene ' .. ri); return true end
    SS.cur.ri = ri; SS.follow(seq); SS.scene(ri, seq, grid, ncols); return true
  end
  if cnt and c == 27 then ctx.msg(''); return true end
  if (ch == 'a' or ch == 'A') and ctx.ss_fa_set then   -- follow action клипа курсора (7 окт)
    local cell = grid[SS.cur.ri] and grid[SS.cur.ri][SS.cur.ci]
    if cell and cell.state ~= 'empty' then
      local a = SS.fa_next(ctx.ss_fa(SS.cur.ci, SS.cur.ri, seq), ch == 'A' and -1 or 1)
      ctx.ss_fa_set(SS.cur.ci, SS.cur.ri, seq, a)
      ctx.msg(('follow action: %s'):format(SS.FA_NAME[a]))
    end
    return true
  end
  if SS.pending_d and ch ~= 'd' then SS.pending_d = nil; if c == 27 then return true end end
  -- 10 окт: yy — копия клипа, yp — дубль строкой ниже, p / P — вставить на курсор
  if SS.pending_y then
    SS.pending_y = nil
    if ch == 'y' and ctx.ss_cell_op then ctx.ss_cell_op('copy', SS.cur.ri, SS.cur.ci)
    elseif ch == 'p' and ctx.ss_cell_op then
      ctx.ss_cell_op('copy', SS.cur.ri, SS.cur.ci)
      if seq[SS.cur.ri + 1] then SS.cur.ri = SS.cur.ri + 1; ctx.ss_cell_op('paste', SS.cur.ri, SS.cur.ci) end
    end
    return true
  end
  if ch == 'y' then SS.pending_y = true; ctx.msg('y: y - copy the clip, p - duplicate below | Esc'); return true end
  if (ch == 'p' or ch == 'P') and ctx.ss_cell_op then ctx.ss_cell_op('paste', SS.cur.ri, SS.cur.ci); return true end
  -- 10 окт: w / b — следующий / предыдущий клип по колонке (вертикально, как
  -- w в трекере); пустые слоты мимо
  if ch == 'w' or ch == 'b' then
    local d = ch == 'b' and -1 or 1
    local ri = SS.cur.ri + d
    while seq[ri] and not (grid[ri] and grid[ri][SS.cur.ci] and grid[ri][SS.cur.ci].state ~= 'empty') do ri = ri + d end
    if seq[ri] then SS.cur.ri = ri; clamp(seq, ncols); SS.follow(seq) else ctx.msg(ch == 'b' and 'no clip above' or 'no clip below') end
    return true
  end
  if ch == 'j' or c == 1685026670 then SS.cur.ri = SS.cur.ri + 1; clamp(seq, ncols); SS.follow(seq)
  elseif ch == 'k' or c == 30064 then SS.cur.ri = SS.cur.ri - 1; clamp(seq, ncols); SS.follow(seq)
  elseif ch == 'h' or c == 1818584692 then SS.cur.ci = SS.cur.ci - 1; clamp(seq, ncols)
  elseif ch == 'l' or c == 1919379572 then SS.cur.ci = SS.cur.ci + 1; clamp(seq, ncols)
  elseif ch == 'g' then SS.cur.ri = 1; SS.scroll = 0
  elseif ch == 'G' then SS.cur.ri = #seq; SS.follow(seq)
  elseif c == 13 or ch == 'o' then
    if SS.cur.ci == 0 then SS.scene(SS.cur.ri, seq, grid, ncols) else SS.launch(SS.cur.ri, SS.cur.ci, seq) end
  elseif ch == 'O' then SS.scene(SS.cur.ri, seq, grid, ncols)
  elseif ch == 'd' then
    if SS.pending_d then SS.pending_d = nil; ctx.ss_delete(SS.cur.ri, SS.cur.ci) else SS.pending_d = true; ctx.msg('d: d - delete the clip (its items in this slot) | Esc') end
    return true
  elseif c == 8 or c == 6579564 then ctx.ss_delete(SS.cur.ri, SS.cur.ci)   -- Backspace / Delete
  elseif ch == 'R' then if ctx.ss_record then ctx.ss_record(SS.cur.ri, SS.cur.ci) end   -- запись в клип (нативная, в слот)
  elseif ch == 'x' then SS.stop(SS.cur.ci)
  elseif ch == 'X' then SS.stop_all(ncols)
  elseif ch == 'q' then ctx.msg('session quantize: ' .. SS.next_quant())
  elseif ch == 'Q' then SS.quit()
  elseif ch == ' ' then ctx.ss_transport()
  elseif ch == 'z' then SS.pending_z = true; ctx.msg(ctx.ss_is_big() and 'z: z - back to the matrix' or 'z: z - clips over the whole window')
  elseif c == 27 then if ctx.ss_is_big() then ctx.ss_big() else return false end
  else return false end
  return true
end
-- ── клип-мод (7 окт): фокус на session — клавиатура QWERTY запускает клипы ──
-- ряды клавиатуры — видимые сцены (q-ряд — верхняя), буква — видимый трек
-- по порядку колонок; Shift — вся сцена ряда; 1..0 — стоп трека; Backspace —
-- стоп всех; стрелки — сцены / курсор; . — follow action курсора;
-- , — квантизация; / — запись в клип курсора; Space — транспорт; Enter —
-- клип курсора. vis — ci видимых колонок слева направо
SS.KEYROWS = { 'qwertyuiop', 'asdfghjkl', 'zxcvbnm' }
function SS.key_of(ri, ci, vis)
  local r = ri - SS.scroll
  local row = SS.KEYROWS[r]
  if not row then return nil end
  for k, v in ipairs(vis or SS.vis or {}) do if v == ci then return k <= #row and row:sub(k, k) or nil end end
end
function SS.clip_key(c, seq, snap, grid, vis, mods)
  SS.vis = vis
  local ch = c < 256 and string.char(c) or ''
  local ncols = #snap.cols
  local low = ch:lower()
  for r, row in ipairs(SS.KEYROWS) do
    local k = low ~= '' and row:find(low, 1, true)
    if k and low:match('%a') then
      local ri = SS.scroll + r
      if not seq[ri] then ctx.msg('no scene on this key row'); return true end
      if ch ~= low then SS.cur.ri = ri; SS.scene(ri, seq, grid, ncols); return true end   -- Shift — вся сцена
      local ci = vis[k]
      if not ci then ctx.msg('no track on this key'); return true end
      SS.cur.ri, SS.cur.ci = ri, ci
      local cell = grid[ri] and grid[ri][ci]
      if cell and cell.state ~= 'empty' then SS.launch(ri, ci, seq) else SS.stop(ci) end   -- пустой слот — стоп трека (как в Ableton)
      if ctx.ss_focus then ctx.ss_focus(ri, ci, grid) end
      return true
    end
  end
  local d = tonumber(ch)
  if d then local ci = vis[d == 0 and 10 or d]; if ci then SS.stop(ci) end; return true end
  if c == 8 or c == 6579564 then SS.stop_all(ncols); return true end
  if c == 30064 then SS.scroll = math.max(0, SS.scroll - 1); SS.cur.ri = math.max(1, SS.cur.ri - 1); return true end            -- ↑
  if c == 1685026670 then SS.scroll = math.min(math.max(0, #seq - 1), SS.scroll + 1); SS.cur.ri = math.min(#seq, SS.cur.ri + 1); return true end   -- ↓
  if c == 1818584692 then SS.cur.ci = math.max(1, SS.cur.ci - 1); return true end   -- ←
  if c == 1919379572 then SS.cur.ci = math.min(math.max(1, ncols), SS.cur.ci + 1); return true end   -- →
  if c == 13 then SS.launch(SS.cur.ri, SS.cur.ci, seq); return true end
  if ch == ' ' then ctx.ss_transport(); return true end
  if ch == ',' then ctx.msg('session quantize: ' .. SS.next_quant()); return true end
  if ch == '.' then return SS.key_body(c, 'a', seq, snap, grid, ncols) end
  if ch == '/' then if ctx.ss_record then ctx.ss_record(SS.cur.ri, SS.cur.ci) end; return true end
  return false
end

function SS.follow(seq)
  if SS.rows_fit then
    if SS.cur.ri - 1 < SS.scroll then SS.scroll = SS.cur.ri - 1 end
    if SS.cur.ri - 1 >= SS.scroll + SS.rows_fit then SS.scroll = SS.cur.ri - SS.rows_fit end
  end
end
function SS.wheel(dir, nrows)
  SS.scroll = math.max(0, math.min(math.max(0, nrows - (SS.rows_fit or 1)), SS.scroll - (dir > 0 and 1 or -1)))
end
-- клик: клетка — курсор, повторный по той же в 0.35 с — запуск; заголовок
-- ряда — сцена; заголовок трека — стоп трека
function SS.click(hv, seq, snap, grid, now)
  local ncols = #snap.cols
  if not (hv.sess or hv.sessrow or hv.sesscol or hv.sessbtn) then return false end   -- не наше — клик идёт дальше (кнопки матрицы)
  if hv.sessrow then SS.cur.ri = hv.sessrow; SS.scene(hv.sessrow, seq, grid, ncols)
  elseif hv.sesscol then SS.stop(hv.sesscol)
  elseif hv.sess then
    local d = hv.sess
    local again = SS.last_click and SS.last_click.ri == d.ri and SS.last_click.ci == d.ci and now - SS.last_click.t < 0.35
    SS.cur.ri, SS.cur.ci = d.ri, d.ci
    if ctx.ss_focus then ctx.ss_focus(d.ri, d.ci, grid) end
    SS.last_click = { ri = d.ri, ci = d.ci, t = now }
    if again then SS.launch(d.ri, d.ci, seq); SS.last_click = nil end
  elseif hv.sessbtn == 'quant' then ctx.msg('session quantize: ' .. SS.next_quant())
  elseif hv.sessbtn == 'stopall' then SS.stop_all(ncols)
  elseif hv.sessbtn == 'quit' then SS.quit()
  elseif hv.sessbtn == 'back' or hv.sessbtn == 'big' then ctx.ss_big()
  end
  return true
end
-- пункты ПКМ по клетке
function SS.menu_items(hv, seq, snap, grid, add)
  local ncols = #snap.cols
  local d = hv.sess
  if d then
    local rg = seq[d.ri]
    add('launch ' .. SS.slot_name(rg, d.ri) .. ' on ' .. ctx.ss_colname(d.ci), function() SS.launch(d.ri, d.ci, seq) end, 'l')
    add('scene: the whole row', function() SS.scene(d.ri, seq, grid, ncols) end, 's')
    add('stop this track', function() SS.stop(d.ci) end, 'x')
    add('delete the clip (dd)', function() ctx.ss_delete(d.ri, d.ci) end, 'd')
    add('record into the clip (R)', function() if ctx.ss_record then ctx.ss_record(d.ri, d.ci) end end, 'r')
  end
  add('stop all tracks', function() SS.stop_all(ncols) end, 'X')
  add('quantize: ' .. SS.quant .. ' (next)', function() ctx.msg('session quantize: ' .. SS.next_quant()) end, 'q')
  add('session off: stop, clear the zone', function() SS.quit() end, 'Q')
end

-- ── рисование ────────────────────────────────────────────────────────────
-- grid — MX.grid(snap, seq); hover: sess {ri, ci}, sessrow ri, sesscol ci, sessbtn
-- Сетка одна на два вида: big (на всё окно, с кнопками) и compact — в панели
-- матрицы (кнопка clips), без строки кнопок, клетки от 2 строк
function SS.draw_grid(L, x, y, w, h, seq, snap, grid, now, playpos, hover, compact)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local ncols, nrows = #snap.cols, #seq
  -- ширина колонки сцен по именам (кэш по таблице seq — пересобирается вместе с ней)
  if SS.need_seq ~= seq or SS.need_cw ~= L.cw then   -- и смена шрифта
    local m = 0
    for ri, rg in ipairs(seq) do m = math.max(m, U.measure('> ' .. SS.slot_name(rg, ri))) end
    SS.need_seq, SS.need_cw, SS.need_w = seq, L.cw, m + 2 * L.pad + 6
  end
  local lay = SS.layout(w, h, ncols, nrows, L.cw, L.rh, L.pad, compact, SS.need_w)
  SS.rows_fit, SS.cols_fit = lay.rows_fit, lay.cols_fit
  local gx0, gy0 = x + lay.hdr_w + L.pad, y + lay.top
  local cy = y + L.pad
  SS.hs = math.max(0, math.min(math.max(0, ncols - lay.cols_fit), SS.cur.ci - lay.cols_fit, SS.hs))
  if SS.cur.ci - 1 < SS.hs then SS.hs = SS.cur.ci - 1 end
  SS.scroll = math.max(0, math.min(math.max(0, nrows - lay.rows_fit), SS.scroll))
  -- имена треков
  for k = 1, lay.cols_fit do
    local ci = SS.hs + k
    local col = snap.cols[ci]; if not col then break end
    local cx = gx0 + (k - 1) * lay.cell_w
    local hot = mx >= cx and mx < cx + lay.cell_w and my >= cy and my < cy + L.rh
    local live = SS.live[ci]
    if col.rgb then U.set(U.tint(col.rgb, 0.35)); gfx.rect(cx, cy, lay.cell_w - 1, L.rh, 1) end
    if hot then U.set(U.tint(U.AMBER, 0.3)); gfx.rect(cx, cy, lay.cell_w - 1, L.rh, 1) end
    U.text(cx + L.pad, cy + 1, ctx.fit(col.name, lay.cell_w - 2 * L.pad - (live and U.measure(' x') or 0)), ci == SS.cur.ci and U.AMBER or U.TEXT)
    if live then U.text(cx + lay.cell_w - L.pad - U.measure('x'), cy + 1, 'x', hot and U.AMBER or U.GREY) end
    if hot then hover.sesscol = ci end
  end
  local blink = (math.floor((now or 0) / SS.BLINK) % 2) == 0
  for r = 1, lay.rows_fit do
    local ri = SS.scroll + r
    local rg = seq[ri]; if not rg then break end
    local ry = gy0 + (r - 1) * lay.cell_h
    -- заголовок сцены
    local hot = mx >= x and mx < gx0 - L.pad and my >= ry and my < ry + lay.cell_h
    local rgb = rg.color and rg.color ~= 0 and U.rgb_of_native and U.rgb_of_native(rg.color) or nil
    -- 11 окт: минимально, как слоты матрицы: без рамки, «> имя» (> — сцену можно запустить),
    -- цвет региона — полоской слева, текст по центру строки (раньше съезжал за низ рамки)
    local hh = lay.cell_h - 1
    if hot then U.set(U.tint(U.AMBER, 0.20)); gfx.rect(x + L.pad, ry, lay.hdr_w - L.pad, hh, 1) end
    if rgb then U.set(rgb); gfx.rect(x + L.pad, ry, 2, hh, 1) end
    local nm = SS.slot_name(rg, ri)
    local two = hh >= 2 * L.rh and rg.qn1 and rg.qn0
    local ty = ry + math.max(0, math.floor((hh - (two and 2 or 1) * L.rh) / 2))
    local tx = x + L.pad + 4
    local col = rg.gap and U.GREY or (ri == SS.cur.ri and U.AMBER or U.TEXT)
    U.text(tx, ty, '>', hot and U.AMBER or (rg.gap and U.DIM or U.GREEN))
    local nx = tx + U.measure('> ')
    U.text(nx, ty, ctx.fit(nm, x + lay.hdr_w - L.pad - nx), col)
    if two then U.text(nx, ty + L.rh, ('%.3g'):format((rg.qn1 - rg.qn0) / 4) .. 'b', U.GREY) end
    if hot then hover.sessrow = ri end
    if ctx.hint then ctx.hint('sessrow', x + L.pad, ry, lay.hdr_w - L.pad, lay.cell_h - 1, ri) end
    -- клетки
    for k = 1, lay.cols_fit do
      local ci = SS.hs + k
      local col = snap.cols[ci]; if not col then break end
      local cx = gx0 + (k - 1) * lay.cell_w
      SS.draw_cell(L, cx, ry, lay.cell_w - 2, lay.cell_h - 2, grid[ri] and grid[ri][ci], col, ri, ci, rg, blink, playpos, hover)
    end
  end
  -- скроллбар рядов (6 окт) справа от клеток; колесо — над сеткой
  if nrows > lay.rows_fit and ctx.vbar then
    local sbx = math.min(x + w - 4, gx0 + lay.cols_fit * lay.cell_w + 2)
    ctx.vbar('clips', sbx, gy0, 3, lay.rows_fit * lay.cell_h, SS.scroll, lay.rows_fit, nrows)
  end
  if SS.hs + lay.cols_fit < ncols then U.text(x + w - L.pad - U.measure('> 9'), cy + 1, ('> %d'):format(ncols - SS.hs - lay.cols_fit), U.GREY) end
  return hover
end

-- одна клетка-клип: фон, волна / блоки, подпись (имя клипа) снизу, прогресс,
-- рамки (живой — янтарная, очередь — голубая мигающая, стоп — красная
-- мигающая, запись — красная двойная, курсор — белая). Общая для сетки
-- (матрица / вкладка / big) и тела трекера
function SS.draw_cell(L, cx, ry, cw, chh, cell, col, ri, ci, rg, blink, playpos, hover)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local live, pend = SS.live[ci], SS.pend[ci]
  local is_live = live and live.ri == ri
  local is_pend = pend and pend.ri == ri
  local is_stop = pend and pend.ri == 'stop' and live and live.ri == ri
  local is_rec = SS.rec and SS.rec.ri == ri and SS.rec.ci == ci
  local is_cur = ri == SS.cur.ri and ci == SS.cur.ci
  local hot2 = mx >= cx and mx < cx + cw and my >= ry and my < ry + chh
  U.set(is_live and U.tint(U.AMBER, 0.12) or (hot2 and U.tint(U.TEXT, 0.06) or U.BG)); gfx.rect(cx, ry, cw, chh, 1)
  -- подпись снизу (6 окт): имя клипа = имя слота, если клетка выше 2 строк
  -- SS.name_over (7 окт): имя — поверх волны, правее кнопки >; волна на всю высоту
  local label_h = (not SS.name_over and cell and cell.state ~= 'empty' and chh >= 2 * L.rh + 2) and L.rh or 0
  do
      local chh = chh - label_h
      -- содержимое: блоки событий по времени, цвет item / трека
      if cell and cell.state ~= 'empty' then
        local ih = math.max(2, chh - 2 * L.pad - 3)
        for _, e in ipairs(cell.ev or {}) do
          -- SS.cell_inset (7 окт): слева от волны — кнопка > / o, волна не под ней
          local ix = SS.cell_inset or 0
          local ex = cx + ix + L.pad + math.floor(e.pos * (cw - ix - 2 * L.pad))
          local ew = math.max(2, math.floor(e.len * (cw - ix - 2 * L.pad)))
          ew = math.max(0, math.min(ew, cx + cw - L.pad - ex))      -- не за край клетки
          local c = e.muted and U.DIM or (e.rgb or col.rgb or U.CYAN)
          -- аудио-клип (6 окт): волна item'а, фон — тусклый цвет; MIDI / пока строится — блок
          local pk = e.head and ew >= 4 and ctx.ss_peaks and ctx.ss_peaks(e.head, ew)
          if pk and pk.n and pk.n > 0 then
            U.set(U.tint(c, 0.25)); gfx.rect(ex, ry + L.pad, ew, ih, 1)
            U.set(c)
            local mid = ry + L.pad + ih / 2
            for i = 1, math.min(ew, pk.n) do
              local hi, lo = math.max(-1, math.min(1, pk.max[i] or 0)), math.max(-1, math.min(1, pk.min[i] or 0))   -- волна не выше клетки
              local y0 = math.floor(mid - hi * ih / 2); local y1 = math.floor(mid - lo * ih / 2)
              gfx.rect(ex + i - 1, y0, 1, math.max(1, y1 - y0 + 1), 1)
            end
          else
            U.set(c); gfx.rect(ex, ry + L.pad, ew, ih, 1)
          end
        end
        -- 8 окт: MIDI-клип с аккордами (2+ ноты на строке) — имена аккордов
        -- поверх блоков, по своим местам, последовательностью; не налезают
        if ctx.chord_name and chh >= L.rh + 2 then
          -- 8 окт: аккорды клетки — один раз на снимок (клетка живёт до пересборки), не каждый кадр
          local order = cell._chords
          if not order then
            local by = {}
            order = {}
            for _, e in ipairs(cell.ev or {}) do
              if e.pitch then
                local g = by[e.r0]
                if not g then g = { pos = e.pos, p = {} }; by[e.r0] = g; order[#order + 1] = g end
                g.p[#g.p + 1] = e.pitch
              end
            end
            table.sort(order, function(a, b) return a.pos < b.pos end)
            for _, g in ipairs(order) do
              local nm = #g.p >= 3 and ctx.chord_name(g.p) or nil
              g.name = (nm and not nm:find('?', 1, true)) and nm or nil
            end
            cell._chords = order
          end
          local ix = SS.cell_inset or 0
          local last_x, prev = -1e9, nil
          -- клетка низкая — имя слота в той же строке: аккорды правее него (без наложений)
          if chh < 2 * L.rh + 4 then last_x = cx + ix + L.pad + U.measure(SS.slot_name(rg, ri)) + U.measure('  ') end
          for _, g in ipairs(order) do
            if g.name then                             -- 3+ ноты и узнанный аккорд (барабаны — не аккорды: «D7?»)
              local nm = g.name
              if nm ~= prev then
                local tx = math.max(last_x, cx + ix + L.pad + math.floor(g.pos * (cw - ix - 2 * L.pad)))   -- тесно — сдвиг вправо, порядок цел
                local tw = U.measure(nm)
                if tx + tw <= cx + cw - L.pad then
                  U.set(U.BG, 0.6); gfx.rect(tx - 1, ry + L.pad, tw + 2, L.rh - 1, 1)
                  U.text(tx, ry + L.pad, nm, U.TEXT)
                  last_x = tx + tw + U.measure(' ')
                end
                prev = nm
              end
            end
          end
        end
        if cell.state == 'muted' and chh >= 2 * L.rh then U.text(cx + L.pad, ry + chh - L.rh - 3, 'muted', U.GREY) end
      else
        U.text(cx + math.floor((cw - U.measure('.')) / 2), ry + math.floor((chh - L.rh) / 2), '.', U.DIM)
      end
  end
  if label_h > 0 or (SS.name_over and cell and cell.state ~= 'empty') then
    -- справа от имени — буква follow action (7 окт): клик — следующая, ПКМ… — a / A с клавиатуры
    local fa = ctx.ss_fa and ctx.ss_fa(ci, ri) or 'l'
    local fl = fa:upper()
    -- 8 окт: буква follow action спрятана (по просьбе, пока); SS.show_fa = true вернёт
    local fw = SS.show_fa and (U.measure(fl) + 2 * L.pad) or 0
    local fx, fy = cx + cw - fw, ry + chh - label_h - 2
    if SS.name_over then fy = ry + chh - L.rh end           -- нижняя строка, поверх волны
    local hotfa = mx >= fx and mx < fx + fw and my >= fy and my < fy + L.rh
    local nx = cx + L.pad + (SS.cell_inset or 0)
    local nm = ctx.fit(SS.slot_name(rg, ri), cx + cw - fw - nx - L.pad)
    if SS.name_over then U.set(U.BG, 0.55); gfx.rect(nx - 1, fy, U.measure(nm) + 2, L.rh - 1, 1) end   -- подложка: имя читается на волне
    U.text(nx, fy, nm, is_live and U.AMBER or U.TEXT)
    if SS.show_fa then
      if hotfa then U.set(U.tint(U.AMBER, 0.3)); gfx.rect(fx, fy, fw, L.rh, 1); hover.ssfa = { ri = ri, ci = ci } end
      U.text(fx + L.pad, fy, fl, hotfa and U.AMBER or (fa == 'l' and U.GREY or U.CYAN))
    end
  end
  if is_live then
    local pr = SS.progress(live, playpos or 0)
    U.set(U.tint(U.AMBER, 0.5)); gfx.rect(cx, ry + chh - 3, cw, 3, 1)
    U.set(U.AMBER); gfx.rect(cx, ry + chh - 3, math.floor(cw * pr), 3, 1)
    if live.seg then   -- луп отрезка mlr (7 окт): рамка отрезка над полосой прогресса
      local a = math.floor(cw * live.a / live.full)
      U.set(U.CYAN); gfx.rect(cx + a, ry + chh - 6, math.max(2, math.floor(cw * live.len / live.full)), 2, 1)
    end
  end
  if is_rec then
    U.set(U.RED); gfx.rect(cx, ry, cw, chh, 0); gfx.rect(cx + 1, ry + 1, cw - 2, chh - 2, 0)
    if blink then U.text(cx + cw - L.pad - U.measure('R'), ry + 2, 'R', U.RED) end
  elseif is_pend and blink then U.set(U.CYAN); gfx.rect(cx, ry, cw, chh, 0); gfx.rect(cx + 1, ry + 1, cw - 2, chh - 2, 0)
  elseif is_stop and blink then U.set(U.RED); gfx.rect(cx, ry, cw, chh, 0)
  elseif is_live then U.set(U.AMBER); gfx.rect(cx, ry, cw, chh, 0)
  else U.set(U.LINE); gfx.rect(cx, ry, cw, chh, 0) end
  if is_cur then U.set(U.TEXT); gfx.rect(cx - 1, ry - 1, cw + 2, chh + 2, 0) end
  if hot2 then hover.sess = { ri = ri, ci = ci } end
  -- метка прыжка — в строке над клипом (SS.hint_dy, 7 окт): не на волне
  if ctx.hint then ctx.hint('sess', cx + (SS.hint_dx or 0), ry + (SS.hint_dy or 0), cw - (SS.hint_dx or 0), SS.hint_dy and L.rh or chh, { ri = ri, ci = ci }) end
end

-- тело трекера в виде clips (6 окт; 7 окт — в масштабе трекера): та же
-- высота строки и ширина колонок, пустые клетки — точки, как строки трекера.
-- Сцена — блок из CLIP_ROWS строк (по умолчанию 3) плюс строка-зазор;
-- клип — рамка на весь блок: волна сверху, снизу имя и буква follow action.
-- Шапки треков,
-- входы, R I M S — от трекера (живые). cols — L.cols; колонка сцен — на
-- месте номеров строк [x0, x0 + lw)
SS.CLIP_ROWS = 3
function SS.draw_body(L, x0, lw, y, h, cols, seq, snap, grid, now, playpos, hover)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local nrows = #seq
  local CR = math.max(2, (ctx.ss_clip_rows and ctx.ss_clip_rows()) or SS.CLIP_ROWS)
  local BR = CR            -- 7 окт: клипы вплотную, без служебной строки между ними
  local nvis = math.max(1, math.floor(h / L.rh))
  local fit = math.max(1, math.floor(nvis / BR))
  SS.rows_fit = fit
  SS.scroll = math.max(0, math.min(math.max(0, nrows - fit), SS.scroll))
  local last = cols[#cols]
  local right = last and last.x and (last.x + last.w) or (x0 + lw)
  -- 8 окт: узкое окно — клипы не вылезают за модуль (на lib справа): край —
  -- правый край трекера, клетки на краю обрезаются, как колонки трекера
  local edge = (L.win_w or right) - 6
  if right > edge then right = edge end
  -- колонки сессии — по лейнам (7 окт): snap.cols — виртуальные (MX.vcols),
  -- клетка на каждый лейн трека шириной лейна; slots — видимые слева направо
  local vmap = {}
  for vi, v in ipairs(snap.cols or {}) do vmap[(v.ci or vi) .. ':' .. (v.li or 1)] = vi end
  local slots = {}
  for _, c in ipairs(cols) do
    if c.x and c.col then
      for li, ln in ipairs(c.lanes or {}) do
        local vi = vmap[c.ci .. ':' .. li]
        local sw = math.min(math.max(L.cw * 3, ln.w - 3), edge - ln.x - 1)
        if vi and sw >= L.cw * 3 then slots[#slots + 1] = { vi = vi, c = c, x = ln.x + 1, w = sw } end
      end
    end
  end
  SS.vis_draw = {}
  for _, sl in ipairs(slots) do SS.vis_draw[#SS.vis_draw + 1] = sl.vi end
  -- последний клип в колонке: под ним — слот записи (красная o, 7 окт)
  local last_clip = {}
  for _, sl in ipairs(slots) do
    for ri = 1, nrows do local cell = grid[ri] and grid[ri][sl.vi]; if cell and cell.state ~= 'empty' then last_clip[sl.vi] = ri end end
  end
  -- кнопка-буква в левом верхнем углу клетки: > — запуск, o — запись
  local function corner(x, y, lab, col, key, data, hx, hy)
    local bw = U.measure(lab) + 4
    local hot = mx >= x and mx < x + bw and my >= y and my < y + L.rh
    U.set(hot and U.tint(col, 0.45) or U.BG); gfx.rect(x, y, bw, L.rh - 1, 1)
    U.set(col); gfx.rect(x, y, bw, L.rh - 1, 0)
    U.text(x + 2, y, lab, hot and U.TEXT or col)
    if hot then hover[key] = data end
    if ctx.hint then ctx.hint(key, hx or x, hy or y, bw, L.rh, data) end   -- метка — в строке над клипом (7 окт)
  end
  local BTN = U.measure('>') + 4
  U.set(U.BG); gfx.rect(x0 + 2, y, right - x0 - 2, h, 1)   -- левый край — рамка трекера (7 окт)
  local blink = (math.floor((now or 0) / SS.BLINK) % 2) == 0
  -- 7 окт: без точек трекера — у клипов свои рамки
  for b = 0, fit - 1 do
    local ri = SS.scroll + b + 1
    local rg = seq[ri]; if not rg then break end
    local by = y + b * BR * L.rh
    local bh = CR * L.rh
    -- сцена: имя слота, длина; клик — вся сцена
    -- кнопка сцены — той же высоты, что клипы (7 окт): строки клипа, не служебная
    local sy = by
    local hot = mx >= x0 and mx < x0 + lw and my >= sy and my < sy + bh
    U.set(hot and U.tint(U.AMBER, 0.25) or U.PANEL); gfx.rect(x0 + 3, sy, lw - 5, bh - 1, 1)
    U.set(ri == SS.cur.ri and U.AMBER or U.LINE); gfx.rect(x0 + 3, sy, lw - 5, bh - 1, 0)
    -- 8 окт: номер региона перед именем — цифровой индекс сцены (как в шапке региона)
    local nx = x0 + L.pad + 2
    if rg.idx and not rg.gap then
      local ns = tostring(rg.idx)
      U.text(nx, sy, ns, U.GREY); nx = nx + U.measure(ns) + U.measure('W')
    end
    U.text(nx, sy, ctx.fit(SS.slot_name(rg, ri), x0 + lw - L.pad - 2 - nx), rg.gap and U.GREY or (ri == SS.cur.ri and U.AMBER or U.TEXT))
    -- 8 окт: длины в тактах на кнопке нет (по просьбе) — номер и имя
    if hot then hover.sessrow = ri end
    if ctx.hint then ctx.hint('sessrow', x0 + 3, sy, lw - 5, L.rh, ri) end
    for _, sl in ipairs(slots) do
      do
        -- 7 окт: строка над клипом — служебная (метки прыжков f, буква клип-мода);
        -- клип — 2 строки: волна на всю высоту, внизу слева > / o, правее — имя поверх волны
        local c, vi = sl.c, sl.vi
        local cell = grid[ri] and grid[ri][vi]
        local cx, cw = sl.x, sl.w
        local ky, cy = by, by                       -- 7 окт: метки — в левом верхнем углу клипа (над > / o), буква клип-мода — справа сверху
        if c.col.armed then U.set(U.RED, 0.10); gfx.rect(cx, cy, cw, bh, 1) end   -- армирован — сюда пойдёт запись
        local busy = (cell and cell.state ~= 'empty') or (SS.rec and SS.rec.ri == ri and SS.rec.ci == vi) or (SS.pend[vi] and SS.pend[vi].ri == ri)
        local bx, byb = cx + 2, cy + bh - L.rh - 1    -- кнопка > / o: нижняя строка клипа, слева от волны и имени
        if busy then
          SS.cell_inset, SS.hint_dy, SS.hint_dx, SS.name_over = BTN + 2, 0, 0, true
          SS.draw_cell(L, cx, cy, cw, bh - 1, cell, c.col, ri, vi, rg, blink, playpos, hover)
          SS.cell_inset, SS.hint_dy, SS.hint_dx, SS.name_over = nil, nil, nil, nil
          if cell and cell.state ~= 'empty' then corner(bx, byb, '>', U.GREEN, 'ssplay', { ri = ri, ci = vi }) end
        else
          -- пустой слот — сразу пустым клипом (7 окт): рамка; курсор / наведение — ярче
          local hot2 = mx >= cx and mx < cx + cw and my >= cy and my < cy + bh
          U.set(hot2 and U.tint(U.TEXT, 0.06) or U.BG); gfx.rect(cx, cy, cw, bh - 1, 1)
          U.set((ri == SS.cur.ri and vi == SS.cur.ci) and U.TEXT or (hot2 and U.GREY or U.LINE)); gfx.rect(cx, cy, cw, bh - 1, 0)
          if hot2 then hover.sess = { ri = ri, ci = vi } end
          if ctx.hint then ctx.hint('sess', cx, ky, cw, L.rh, { ri = ri, ci = vi }) end
          if ri == (last_clip[vi] or 0) + 1 then
            -- 11 окт: запись — красная плашка без рамки (рамку съедали метки f над ней)
            local rw = U.measure('o') + 4
            local rhot = mx >= bx and mx < bx + rw and my >= byb and my < byb + L.rh
            U.set(rhot and U.RED or U.mix(U.BG, U.RED, 0.75)); gfx.rect(bx, byb, rw, L.rh - 1, 1)
            U.text(bx + 2, byb, 'o', rhot and U.TEXT or U.BG)
            if rhot then hover.ssrecbtn = { ri = ri, ci = vi } end
            -- 11 окт: без метки f: она забирала место метки клипа, и f + буква начинало запись
          end
        end
        -- клип-мод: буква клавиши — слева сверху, над кнопкой > (8 окт; была
        -- справа и ярко-жёлтой): приглушённая плашка, буква янтарём
        local kl = SS.clip_mode and SS.key_of(ri, vi, SS.vis_draw)
        -- 11 окт: просто буква, без плашки — серая полупрозрачная (смесь GREY с фоном темы),
        -- в левом верхнем углу над кнопкой > / o
        if kl then U.text(bx + 2, ky + 1, kl, U.mix(U.BG, U.GREY, 0.6)) end
      end
    end
  end
  -- метров здесь нет (7 окт): они одни — в трекере (быстрая опция meters)
  if nrows > fit and ctx.vbar then
    ctx.vbar('clips', right + 1, y, 3, fit * BR * L.rh, SS.scroll, fit, nrows)
  end
  hover.ssbig = true
  return hover
end

-- строка кнопок сессии (big и вкладка clips); возвращает x после кнопок
function SS.draw_buttons(L, bx, by, right, hover, big)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local function btn(label, what, on)
    local bw = U.measure(label) + 2 * L.pad
    if bx + bw > right then return end
    local hot = mx >= bx and mx < bx + bw and my >= by and my < by + L.rh
    U.set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(U.AMBER, 0.15) or U.BG)); gfx.rect(bx, by, bw, L.rh, 1)
    U.set(on and U.AMBER or U.LINE); gfx.rect(bx, by, bw, L.rh, 0)
    U.text(bx + L.pad, by + 1, label, on and U.AMBER or (hot and U.TEXT or U.GREY))
    if hot then hover.sessbtn = what end
    bx = bx + bw + L.pad
  end
  if big then U.text(bx, by + 1, 'session', U.AMBER); bx = bx + U.measure('session') + 2 * L.pad end
  btn('quant: ' .. SS.quant, 'quant', false)
  btn('X stop all', 'stopall', SS.playing_any())
  btn('Q off', 'quit', false)
  btn(big and 'zz back' or 'zz big', big and 'back' or 'big', false)
  local hint = 'Enter launch  O / F scene  x stop  f labels  Space transport  drop files (browser, Media Explorer) or a pm card onto a cell'
  if bx + U.measure(hint) < right then U.text(bx, by + 1, hint, U.GREY) end
  return bx
end

function SS.draw_big(L, x, y, w, h, seq, snap, grid, now, playpos)
  local hover = { ssbig = true }
  U.set(U.BG); gfx.rect(x, y, w, h, 1)
  SS.draw_buttons(L, x + L.pad, y + L.pad, x + w - L.pad, hover, true)
  local top = L.rh + 2 * L.pad
  SS.draw_grid(L, x, y + top, w, h - top, seq, snap, grid, now, playpos, hover, false)
  U.set(U.AMBER); gfx.rect(x, y, w, h, 0)
  return hover
end
-- вкладка clips верхней панели: кнопки + сетка (компактная раскладка)
function SS.draw_top(L, x, y, w, h, seq, snap, grid, now, playpos)
  local hover = {}
  SS.draw_buttons(L, x + L.pad, y + 1, x + w - L.pad, hover, false)
  local top = L.rh + 2 * L.pad
  SS.draw_grid(L, x, y + top, w, h - top, seq, snap, grid, now, playpos, hover, true)
  return hover
end

-- ── monome (7 окт): страница clips на гриде (daemon_tracker.lua) ─────────
-- Трекер публикует ExtState jf_tracker/ss, демон шлёт jf_tracker/ssgrid.
-- ss: «view,nr,nc,cur_ri,cur_ci,quant,playing;<клетки>;<треки>»
--   view 1 — вид clips открыт (тело / матрица / big): грид сам на страницу clips
--   клетки — nr*nc знаков по рядам: . пусто, o клип, m заглушено
--   трек: «ri:step:k1:k2:pend:vol» через пробел; ri 0 — молчит; k1 k2 —
--   отрезок лупа (−1 нет); pend 0 нет / 1 запуск / 2 стоп / 3 прыжок / 4 луп;
--   vol 0..100 (ctx.ss_vol)
-- ssgrid: «команда;команда;…,n» — launch ri ci · stop ci · stopall · scene ri ·
--   jump ci k · loop ci k1 k2 · quant · clips · vol ci d (d — шаги)
local QI = { bar = 0, beat = 1, now = 2 }
function SS.grid_pub(seq, ncols, grid, pos, playing, view)
  local cells = {}
  for ri = 1, #seq do
    for ci = 1, ncols do
      local c = grid[ri] and grid[ri][ci]
      cells[#cells + 1] = (not c or c.state == 'empty') and '.' or (c.state == 'muted' and 'm' or 'o')
    end
  end
  local tr = {}
  for ci = 1, ncols do
    local l, p = SS.live[ci], SS.pend[ci]
    local pend = 0
    if p then pend = p.ri == 'stop' and 2 or (p.seg and 4 or (p.step and 3 or 1)) end
    local k1, k2 = -1, -1
    if l and l.seg then k1, k2 = l.seg[1], l.seg[2] end
    local vol = ctx.ss_vol and ctx.ss_vol(ci) or 0
    tr[ci] = ('%d:%d:%d:%d:%d:%d'):format(l and l.ri or 0, l and SS.step_of(l, pos) or -1, k1, k2, pend, math.floor(vol * 100 + 0.5))
  end
  return ('%d,%d,%d,%d,%d,%d,%d;%s;%s'):format(view and 1 or 0, #seq, ncols, SS.cur.ri, SS.cur.ci, QI[SS.quant] or 0, playing and 1 or 0,
    table.concat(cells), table.concat(tr, ' '))
end
-- команды грида; возвращает число выполненных
function SS.grid_cmd(str, seq, snap, grid)
  local body = str:match('^(.*),%d+$') or str
  local ncols = snap and #snap.cols or 0
  local n = 0
  for c in body:gmatch('[^;]+') do
    local w = {}
    for t in c:gmatch('%S+') do w[#w + 1] = tonumber(t) or t end
    local k = w[1]
    local function ok_ci(ci) return type(ci) == 'number' and ci >= 1 and ci <= ncols end
    if k == 'launch' and seq[w[2]] and ok_ci(w[3]) then SS.cur.ri, SS.cur.ci = w[2], w[3]; SS.launch(w[2], w[3], seq); n = n + 1
    elseif k == 'stop' and ok_ci(w[2]) then SS.cur.ci = w[2]; SS.stop(w[2]); n = n + 1
    elseif k == 'stopall' then SS.stop_all(ncols); n = n + 1
    elseif k == 'scene' and seq[w[2]] then SS.cur.ri = w[2]; SS.scene(w[2], seq, grid, ncols); n = n + 1
    elseif k == 'jump' and ok_ci(w[2]) and type(w[3]) == 'number' then SS.cur.ci = w[2]; SS.jump(w[2], w[3]); n = n + 1
    elseif k == 'loop' and ok_ci(w[2]) and type(w[3]) == 'number' and type(w[4]) == 'number' then SS.cur.ci = w[2]; SS.loop(w[2], w[3], w[4]); n = n + 1
    elseif k == 'quant' then ctx.msg('session quantize: ' .. SS.next_quant()); n = n + 1
    elseif k == 'clips' then if ctx.clips_toggle then ctx.clips_toggle() end; n = n + 1
    elseif k == 'vol' and ok_ci(w[2]) and type(w[3]) == 'number' then SS.cur.ci = w[2]; if ctx.ss_vol_add then ctx.ss_vol_add(w[2], w[3]) end; n = n + 1 end
  end
  return n
end

return SS
