-- test_session.lua — session (клипы) без REAPER / gfx: lua tests/test_session.lua
-- Раскладка, границы квантизации, прогресс, машина очереди pend → live → todo
-- (ctx — стаб: зона, такты, плейхед, применённые действия), клавиши, клик.
-- Плюс A.session_plant / A.session_clear на стабе items REAPER.
package.path = './?.lua;' .. package.path
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
local function near(name, got, want) eq(name, math.abs((got or 1e9) - want) < 1e-6, true) end

-- ── стаб ctx ──────────────────────────────────────────────────────────────
local pos, playing, msgs, applied, played, big = 0, false, {}, {}, 0, 0
local ZONE = { pos = 100, rgnend = 116, session = true }     -- 8 тактов по 2 с
local FAKE_A = {}
local ctx = {
  ss_zone = function() return ZONE end,
  ss_bar_after = function(t) return math.floor(t / 2) * 2 + 2 end,
  ss_beat_after = function(t) return math.floor(t / 0.5) * 0.5 + 0.5 end,
  ss_playpos = function() return pos, playing end,
  ss_play = function(z) played = played + 1; playing = true; pos = z.pos end,
  ss_apply = function(desc, fn) applied[#applied + 1] = desc; fn() end,
  ss_colname = function(ci) return 'T' .. ci end,
  ss_transport = function() playing = not playing end,
  ss_quit = function() playing = false end,
  ss_stop_transport = function() playing = false end,
  ss_big = function() big = big + 1 end,
  ss_is_big = function() return true end,
  msg = function(m) msgs[#msgs + 1] = m end,
  alias = FAKE_A,
  fit = function(s) return s end,
}
local calls = {}
function FAKE_A.session_clear(tr, z0, z1, k0, k1) calls[#calls + 1] = { 'clear', tr, z0, z1, k0, k1 } end
function FAKE_A.session_plant(tr, src, z0, z1, phase, skip, tag, win) calls[#calls + 1] = { 'plant', tr, src, z0, z1, phase, skip, tag, win } end
local SS = dofile('jf_tracker_session.lua'); SS.init({}, ctx)
local seq = { { name = 'intro', pos = 0, rgnend = 4, r0 = 0 }, { name = '', pos = 4, rgnend = 8, r0 = 16, gap = true }, { name = 'B', pos = 8, rgnend = 10, r0 = 32 } }
local snap = { cols = { { name = 'drums', track = 'tr1' }, { name = 'bass', track = 'tr2' }, { name = 'pad', track = 'tr3' } } }
local grid = { { { state = 'has' }, { state = 'empty' }, { state = 'has' } }, { { state = 'empty' }, { state = 'has' }, { state = 'empty' } }, { { state = 'has' }, { state = 'has' }, { state = 'muted' } } }

-- ── раскладка ─────────────────────────────────────────────────────────────
for _, w in ipairs({ 600, 1200, 2000 }) do
  for _, cw in ipairs({ 8, 12, 16 }) do
    for _, nc in ipairs({ 2, 4, 12 }) do
      for _, nr in ipairs({ 3, 40 }) do
        local lay = SS.layout(w, 900, nc, nr, cw, cw + 2, 4)
        local tag = ('%d/%d/%d/%d'):format(w, cw, nc, nr)
        eq('cell_w >= 8cw ' .. tag, lay.cell_w >= 8 * cw, true); eq('cell_h >= 3rh ' .. tag, lay.cell_h >= 3 * (cw + 2), true)
        eq('cols fit ' .. tag, lay.cols_fit * lay.cell_w <= w - lay.hdr_w - 8, true)
        eq('rows fit ' .. tag, lay.rows_fit * lay.cell_h <= 900 - lay.top - 4, true)
      end
    end
  end
end
eq('few cols stretch (cap 20 chars)', SS.layout(2000, 900, 2, 3, 8, 10, 4).cell_w, 8 * 20)
eq('many rows scroll', SS.layout(1200, 900, 4, 40, 8, 10, 4).rows_fit < 40, true)
-- компактная (clips над матрицей): клетки до 2 строк, высота — по рядам, не выше cap
local lc = SS.layout(400, 300, 4, 3, 8, 10, 4, true)
eq('compact cell_h <= 2 rows', lc.cell_h <= 20, true); eq('compact cell_w <= 12 chars', lc.cell_w <= 96, true)
eq('height fits rows', SS.height(400, 300, 4, 3, 8, 10, 4) <= 300, true); eq('height capped', SS.height(400, 120, 4, 40, 8, 10, 4), 120)

-- ── полиметрия: НОК ───────────────────────────────────────────────────────
near('lcm 4 and 5 beats', (SS.lcm_qn({ 4, 5 })), 20); near('lcm 4 and 4', (SS.lcm_qn({ 4, 4 })), 4)
near('lcm 3 and 4 and 2', (SS.lcm_qn({ 3, 4, 2 })), 12); near('lcm 1.5 and 2', (SS.lcm_qn({ 1.5, 2 })), 6)
local capq, capped = SS.lcm_qn({ 7, 11, 13, 17 }, 64); eq('lcm capped', capped, true); near('lcm cap value', capq, 64)

-- ── границы ───────────────────────────────────────────────────────────────
SS.quant = 'bar'; near('bar after 103', SS.next_boundary(103, ZONE, 'bar'), 104)
near('bar exactly on 104 -> 106', SS.next_boundary(104, ZONE, 'bar'), 106)
near('beat', SS.next_boundary(103.1, ZONE, 'beat'), 103.5); near('now', SS.next_boundary(103.1, ZONE, 'now'), 103.1)
near('past end -> rgnend', SS.next_boundary(115.5, ZONE, 'bar'), 116)
near('progress', SS.progress({ phase = 100, len = 4 }, 101), 0.25); near('progress wraps', SS.progress({ phase = 100, len = 4 }, 109), 0.25)

-- ── очередь: транспорт стоит ─────────────────────────────────────────────
SS.launch(1, 1, seq)
eq('stopped: play called', played, 1); eq('stopped: pend now', SS.pend[1] and SS.pend[1].now, true)
SS.tick(seq, snap)
eq('fired: live', SS.live[1] and SS.live[1].ri, 1); near('fired: phase z0', SS.live[1].phase, 100); near('fired: len', SS.live[1].len, 4)
eq('fired: clear then plant', calls[1][1] .. calls[2][1], 'clearplant'); eq('fired: no keep', calls[1][5], nil); eq('fired: no skip', calls[2][7], nil)
eq('fired: tag', calls[2][8], '1:1'); eq('fired: pend cleared', SS.pend[1], nil); eq('fired: no todo', SS.todo[1], nil)
eq('same clip again: refused', (function() local m = #msgs; SS.launch(1, 1, seq); return #msgs - m == 1 and msgs[#msgs]:find('already') ~= nil end)(), true)
-- ── очередь: играет, смена на границе ────────────────────────────────────
calls = {}; pos = 102.5
SS.launch(3, 1, seq)
near('pend at next bar', SS.pend[1].at, 104)
pos = 103.9; SS.tick(seq, snap); eq('before boundary: silent', #calls, 0)
pos = 103.95; SS.tick(seq, snap)   -- упреждение SS.LOOK
eq('boundary: clear + plant', #calls, 2); near('boundary: keep from', calls[1][5], 103.95); near('boundary: keep to', calls[1][6], 104)
eq('boundary: skip window', calls[2][7] ~= nil, true); near('boundary: phase', calls[2][6], 104)
eq('boundary: live ri', SS.live[1].ri, 3); eq('boundary: todo set', SS.todo[1] ~= nil, true)
calls = {}; pos = 104.01; SS.tick(seq, snap); eq('todo waits', #calls, 0)
pos = 104.05; SS.tick(seq, snap)
eq('fill: clear + plant', #calls, 2); eq('fill: win', calls[2][9] ~= nil, true); eq('fill: todo cleared', SS.todo[1], nil)
-- ── стоп ──────────────────────────────────────────────────────────────────
calls = {}; pos = 105; SS.stop(1); near('stop at bar', SS.pend[1].at, 106)
pos = 105.95; SS.tick(seq, snap)
eq('stop: clear only', #calls, 1); eq('stop: live gone', SS.live[1], nil); eq('stop: todo without ri', SS.todo[1] and SS.todo[1].ri, nil)
pos = 106.1; SS.tick(seq, snap); eq('stop fill: clear only', #calls, 2)
-- ── сцена: пустая клетка = стоп ───────────────────────────────────────────
calls = {}; pos = 107
SS.live[2] = { ri = 2, phase = 100, len = 4 }
SS.scene(1, seq, grid, 3)
eq('scene: track1 launch', SS.pend[1].ri, 1); eq('scene: track2 (empty) stop', SS.pend[2].ri, 'stop'); eq('scene: track3 launch', SS.pend[3].ri, 1)
pos = 107.95; SS.tick(seq, snap); eq('scene fired all', SS.live[1].ri == 1 and SS.live[2] == nil and SS.live[3].ri == 1, true)
-- ── конец зоны: пробуждение на прыжке лупа ───────────────────────────────
calls = {}; pos = 115.2; SS.pend = {}; SS.todo = {}
SS.launch(3, 2, seq); near('pend at rgnend', SS.pend[2].at, 116)
pos = 115.8; SS.tick(seq, snap); eq('not yet', #calls, 0)
pos = 115.95; SS.tick(seq, snap)   -- упреждение перед прыжком: старое доигрывает до конца зоны
eq('end fired', SS.live[2] and SS.live[2].ri, 3); near('end phase z0', SS.live[2].phase, 100); near('end keep to rgnend', calls[1][6], 116)
calls = {}; pos = 100.02; SS.tick(seq, snap)   -- луп прыгнул → досадка хвоста
eq('wrap fill', #calls, 2); near('wrap fill win from', calls[2][9][1], 115.95)
-- ── stop all / quit ───────────────────────────────────────────────────────
SS.stop_all(3); eq('stop all: pend on live', SS.pend[1] and SS.pend[1].ri == 'stop' and SS.pend[2].ri == 'stop' and SS.pend[3].ri == 'stop', true)
pos = 101.95; SS.tick(seq, snap); eq('stop all: transport stops with the last clip', playing, false); playing = true
SS.quit(); eq('quit clears', next(SS.live) == nil and next(SS.pend) == nil, true)

-- ── клавиши ───────────────────────────────────────────────────────────────
SS.cur = { ri = 1, ci = 1 }
eq('l', SS.key(('l'):byte(), seq, snap, grid, {}) and SS.cur.ci, 2); eq('h h clamp', (SS.key(('h'):byte(), seq, snap, grid, {}) and SS.key(('h'):byte(), seq, snap, grid, {})) and SS.cur.ci, 1)
eq('j j j clamp', (function() for _ = 1, 3 do SS.key(('j'):byte(), seq, snap, grid, {}) end return SS.cur.ri end)(), 3)
eq('G', SS.key(('G'):byte(), seq, snap, grid, {}) and SS.cur.ri, 3); eq('g', SS.key(('g'):byte(), seq, snap, grid, {}) and SS.cur.ri, 1)
pos = 101; playing = true; SS.key(13, seq, snap, grid, {}); eq('Enter launches', SS.pend[1] and SS.pend[1].ri, 1)
eq('q cycles', SS.key(('q'):byte(), seq, snap, grid, {}) and SS.quant, 'beat'); SS.quant = 'bar'
eq('zz back', (SS.key(('z'):byte(), seq, snap, grid, {}) and SS.key(('z'):byte(), seq, snap, grid, {})) and big, 1)
eq('Esc back', SS.key(27, seq, snap, grid, {}) and big, 2)
eq('unknown not eaten', SS.key((':'):byte(), seq, snap, grid, {}), false)
-- клик: первый — курсор, второй быстрый — запуск
SS.pend = {}; SS.cur = { ri = 1, ci = 1 }
SS.click({ sess = { ri = 3, ci = 2 } }, seq, snap, grid, 10.0); eq('click: cursor', SS.cur.ri * 10 + SS.cur.ci, 32); eq('click: no launch', SS.pend[2], nil)
SS.click({ sess = { ri = 3, ci = 2 } }, seq, snap, grid, 10.2); eq('dblclick: launch', SS.pend[2] and SS.pend[2].ri, 3)

-- ── A.session_plant / A.session_clear на стабе REAPER ────────────────────
local items   -- { {pos, len, chunk} }
local function it_pos(it) return it.pos end
reaper = {
  CountTracks = function() return 0 end,
  CountTrackMediaItems = function() return #items end,
  GetTrackMediaItem = function(_, i) return items[i + 1] end,
  GetMediaItemInfo_Value = function(it, k) if k == 'D_POSITION' then return it.pos elseif k == 'D_LENGTH' then return it.len elseif k == 'I_FIXEDLANE' then return 0 elseif k == 'I_GROUPID' then return 0 end return 0 end,
  SetMediaItemInfo_Value = function(it, k, v) if k == 'D_POSITION' then it.pos = v elseif k == 'D_LENGTH' then it.len = v end end,
  GetItemStateChunk = function(it) return true, it.chunk or '<ITEM\nGUID {x}\n>' end,
  SetItemStateChunk = function(it, c) it.chunk = c end,
  GetMediaTrackInfo_Value = function() return 0 end,
  AddMediaItemToTrack = function() local it = { pos = 0, len = 1 }; items[#items + 1] = it; return it end,
  DeleteTrackMediaItem = function(_, it) for i, x in ipairs(items) do if x == it then table.remove(items, i); return end end end,
  SplitMediaItem = function(it, t) local r = { pos = t, len = it.pos + it.len - t, chunk = it.chunk }; it.len = t - it.pos; items[#items + 1] = r; return r end,
  GetSetMediaItemInfo_String = function(it, k, v, set) if set == false then return true, it[k] or '' end; it[k] = v; return true, v end,
  ValidatePtr = function() return false end, genGuid = function() return '{g}' end,
  GetActiveTake = function(it) return it end,
  SetMediaItemTakeInfo_Value = function(it, k, v) it['take:' .. k] = v end,
  GetMediaItemTakeInfo_Value = function(it, k) return it['take:' .. k] or (k == 'D_PLAYRATE' and 1 or 0) end,
  GetTrackName = function() return true, '' end, GetTrack = function() end,
  TimeMap2_timeToQN = function(_, t) return t end, TimeMap2_QNToTime = function(_, q) return q end,
}
local A = dofile('jf_tracker_alias.lua')
A.init({ DEPOT = 'DEPOT' })
-- клип 4 с: два item (0.0 len 1, 2.5 len 1); зона 100..116, фаза 104
items = { { pos = 0, len = 1, chunk = '<ITEM\nGUID {a}\n>' }, { pos = 2.5, len = 1, chunk = '<ITEM\nGUID {b}\n>' } }
local src = { pos = 0, rgnend = 4 }
local nplant = A.session_plant('tr', src, 100, 116, 104, nil, 't')
local planted = {}; for _, it in ipairs(items) do if it.pos >= 100 then planted[#planted + 1] = it.pos end end
table.sort(planted)
eq('plant count', nplant, 8); eq('plant count = items', #planted, 8)
eq('plant positions', table.concat(planted, ','), '100,102.5,104,106.5,108,110.5,112,114.5')
eq('plant tag', items[3]['P_EXT:jf_session'], 't')
-- хвост за зоной обрезан: item 1 с длиной 3 на 114.5 → 1.5
items = { { pos = 0, len = 4, chunk = '<ITEM\n>' } }
A.session_plant('tr', { pos = 0, rgnend = 4 }, 100, 116, 114, nil, 't')
local last = items[#items]; near('tail trimmed', last.pos + last.len <= 116 and last.len or -1, 2)
-- хвост через шов: клип 2.5 с, item 0..2 с, фаза 102, зона 100..110 — повтор k=-1 (99.5) пересекает 100
items = { { pos = 0, len = 2, chunk = '<ITEM\n>' } }
A.session_plant('tr', { pos = 0, rgnend = 2.5 }, 100, 110, 102, nil, 't')
local seam
for _, it in ipairs(items) do if it.pos == 100 then seam = it end end
eq('seam piece planted at z0', seam ~= nil, true)
if seam then near('seam piece len = rest of the item', seam.len, 1.5); near('seam piece source offset', seam['take:D_STARTOFFS'] or -1, 0.5) end
-- skip: окно [102, 104) пропускается
items = { { pos = 0, len = 1, chunk = '<ITEM\n>' } }
A.session_plant('tr', { pos = 0, rgnend = 2 }, 100, 108, 104, { 102, 104 }, 't')
local got = {}; for _, it in ipairs(items) do if it.pos >= 100 then got[#got + 1] = it.pos end end; table.sort(got)
eq('skip window', table.concat(got, ','), '100,104,106')
-- win: только окно [102, 104)
items = { { pos = 0, len = 1, chunk = '<ITEM\n>' } }
A.session_plant('tr', { pos = 0, rgnend = 2 }, 100, 108, 104, nil, 't', { 102, 104 })
got = {}; for _, it in ipairs(items) do if it.pos >= 100 then got[#got + 1] = it.pos end end
eq('win only', table.concat(got, ','), '102')
-- clear с keep: item 101..103 (пересекает keep1 = 102) режется, 104.. удаляется, 100..101 (до keep0 = 101.5) удаляется
local S = 'P_EXT:jf_session'
items = { { pos = 100, len = 1, [S] = '1' }, { pos = 101, len = 2, [S] = '1' }, { pos = 104, len = 1, [S] = '1' }, { pos = 50, len = 1, [S] = '1' } }
local ncl = A.session_clear('tr', 100, 108, 101.5, 102)
got = {}; for _, it in ipairs(items) do got[#got + 1] = it.pos .. '+' .. it.len end; table.sort(got)
eq('clear keep: kept and trimmed', table.concat(got, ' '), '101+1 50+1'); eq('clear count', ncl, 3)
items = { { pos = 100, len = 1, [S] = '1' }, { pos = 107.5, len = 2, [S] = '1' }, { pos = 50, len = 1, [S] = '1' } }
eq('clear all in zone', A.session_clear('tr', 100, 108), 2); eq('clear all: outside stays', #items == 1 and items[1].pos, 50)
-- 18 окт: items песни (без метки) в зоне не трогаются
items = { { pos = 100, len = 1 }, { pos = 101, len = 1, [S] = '1' } }
eq('clear: song items stay', A.session_clear('tr', 100, 108), 1); eq('clear: the song item', #items == 1 and items[1].pos, 100)

-- луп клипа с кроссфейдом (A.plant_loop): шаг (lb − la) / rate, копия длиннее на xf, фейды
reaper.GetActiveTake = function(it) return it end
reaper.SetMediaItemTakeInfo_Value = function(it, k, v) it['take:' .. k] = v end
local _sv = reaper.SetMediaItemInfo_Value
reaper.SetMediaItemInfo_Value = function(it, k, v) if k == 'D_POSITION' or k == 'D_LENGTH' then return _sv(it, k, v) end; it[k] = v end
items = {}
local src_it = { pos = 0, len = 4, chunk = '<ITEM\n>' }
local nl = A.plant_loop('tr', { item = src_it, la = 1.0, lb = 3.0, rate = 1, xf = 0.05 }, 100, 108, 100, nil, 't')
local ps, lens = {}, {}
for _, it in ipairs(items) do ps[#ps + 1] = ('%g'):format(it.pos); lens[#lens + 1] = it.len end
table.sort(ps)
-- 4 повтора + хвост кроссфейда прошлого повтора через шов (0.05 с в начале зоны)
eq('loop plant count', nl, 5); eq('loop plant step 2s (+ seam xf tail)', table.concat(ps, ','), '100,100,102,104,106')
local full, tail, last
for _, it in ipairs(items) do
  if it.pos == 100 and it.len > 1 then full = it elseif it.pos == 100 then tail = it end
  if it.pos == 106 then last = it end
end
near('loop copy offs = la', full['take:D_STARTOFFS'], 1.0); near('loop copy len = step + xf', full.len, 2.05)
near('loop fade in', full.D_FADEINLEN, 0.05); near('loop fade out', full.D_FADEOUTLEN, 0.05)
near('seam tail = xf', tail.len, 0.05); near('seam tail source offs', tail['take:D_STARTOFFS'], 3.0)
near('last copy trimmed by zone end', last.len, 2.0)
items = {}
A.plant_loop('tr', { item = src_it, la = 1.0, lb = 3.0, rate = 2, xf = 0 }, 100, 104, 100, nil, 't')
eq('rate 2: step 1s', #items, 4); near('rate 2: no xf len', items[1].len, 1.0)   -- без xf хвоста через шов нет

-- ── follow actions (7 окт) ───────────────────────────────────────────────
-- колонка 1: клипы в рядах 1 и 3 (grid выше: 1:has, 2:empty, 3:has)
eq('fa next skips empty', SS.fa_target('n', 1, 1, seq, grid), 3)
eq('fa next wraps', SS.fa_target('n', 3, 1, seq, grid), 1)
eq('fa prev', SS.fa_target('p', 3, 1, seq, grid), 1)
eq('fa first', SS.fa_target('f', 3, 1, seq, grid), 1)
eq('fa stop', SS.fa_target('s', 1, 1, seq, grid), nil)
eq('fa random: the other clip', SS.fa_target('r', 1, 1, seq, grid, function() return 0.5 end), 3)
eq('fa loop stays', SS.fa_target('l', 1, 1, seq, grid), 1)
eq('fa cycle', SS.fa_next('l', 1) .. SS.fa_next('l', -1), 'ns')
-- клип 2 с (слот 0..2 в стабе) запущен на 100, follow next → очередь на 102 в ряд 3
SS.live, SS.pend, SS.todo, SS.halt = { [1] = { ri = 1, phase = 100, len = 2, full = 2, a = 0, fired = 100, fa = 'n' } }, {}, {}, nil
playing = true; pos = 100.5
SS.follow_tick(seq, grid)
eq('follow queued', SS.pend[1] and SS.pend[1].ri, 3); near('follow at the end of the pass', SS.pend[1] and SS.pend[1].at or 0, 102)
SS.pend = {}; SS.follow_tick(seq, grid); eq('follow once per launch', SS.pend[1], nil)
SS.live = { [1] = { ri = 1, phase = 100, len = 2, full = 2, a = 0, fired = 100, fa = 's' } }
SS.follow_tick(seq, grid); eq('follow stop', SS.pend[1] and SS.pend[1].ri, 'stop')
SS.live = { [1] = { ri = 1, phase = 114, len = 4, full = 4, a = 0, fired = 114, fa = 'n' } }; SS.pend = {}
SS.follow_tick(seq, grid); near('follow past the zone end waits for the loop jump', SS.pend[1] and SS.pend[1].at or 0, 116)
SS.live, SS.pend, SS.todo = {}, {}, {}

-- ── mlr (7 окт): прыжок и луп отрезка ────────────────────────────────────
-- слот intro 0..4 с = 8 шагов по 0.5 с; играет на треке 1 с фазой 104
SS.live, SS.pend, SS.todo = { [1] = { ri = 1, phase = 104, len = 4, full = 4, a = 0 } }, {}, {}
SS.quant = 'bar'; playing = true; pos = 105.2; calls = {}
eq('step under playhead', SS.step_of(SS.live[1], 105.2), 2)
eq('jump: nothing plays on 2', SS.jump(2, 3), false)
eq('jump armed', SS.jump(1, 6), true)
near('jump at next beat (not bar)', SS.pend[1].at, 105.5); eq('jump keeps the clip', SS.pend[1].ri, 1)
pos = 105.45; SS.tick(seq, snap)
eq('jump fired', SS.pend[1], nil); near('jump phase: step 6 at 105.5', SS.live[1].phase, 105.5 - 3)
eq('jump step at boundary', SS.step_of(SS.live[1], 105.5), 6)
near('jump plant phase', calls[2][6], 102.5)
calls = {}; pos = 105.6
eq('loop armed', SS.loop(1, 5, 2), true); eq('loop steps sorted', SS.pend[1].seg[1] .. '-' .. SS.pend[1].seg[2], '2-5')
pos = 105.97; SS.tick(seq, snap)
local lv = SS.live[1]
near('loop: a = step 2', lv.a, 1); near('loop: len = 4 steps', lv.len, 2); near('loop: phase = boundary', lv.phase, 106)
eq('loop: step at boundary', SS.step_of(lv, 106), 2); eq('loop: wraps inside', SS.step_of(lv, 107.9), 5); eq('loop: back to start', SS.step_of(lv, 108.1), 2)
near('loop: progress over the whole clip', SS.progress(lv, 106), 0.25)
local opt = SS.plant_opt(lv, 'tr1', seq[1]); near('loop opt seg start', opt.seg[1], 1); near('loop opt seg end', opt.seg[2], 3)
eq('relaunch the same clip while looping is allowed', (function() SS.launch(1, 1, seq); return SS.pend[1] ~= nil end)(), true)
SS.quant = 'now'; SS.pend = {}; eq('now: jump at once', SS.jump(1, 0) and SS.pend[1].at, 105.97)
SS.live, SS.pend, SS.todo = {}, {}, {}; SS.quant = 'bar'

-- посадка отрезка: item 0..4 (одно аудио на весь слот), отрезок 1..3
items = { { pos = 0, len = 4, chunk = '<ITEM\n>' } }
A.session_plant('tr', { pos = 0, rgnend = 4 }, 100, 106, 100, nil, 't', nil, { seg = { 1, 3 } })
got = {}; for _, it in ipairs(items) do if it.pos >= 100 then got[#got + 1] = ('%g+%g@%g'):format(it.pos, it.len, it['take:D_STARTOFFS'] or 0) end end; table.sort(got)
eq('seg: tiles cut from the long item', table.concat(got, ' '), '100+2@1 102+2@1 104+2@1')
-- длинный item через окно skip: сажается с конца окна со сдвигом
items = { { pos = 0, len = 4, chunk = '<ITEM\n>' } }
A.session_plant('tr', { pos = 0, rgnend = 4 }, 100, 108, 102.5, { 101, 103 }, 't')
got = {}; for _, it in ipairs(items) do if it.pos >= 100 then got[#got + 1] = ('%g+%g@%g'):format(it.pos, it.len, it['take:D_STARTOFFS'] or 0) end end; table.sort(got)
eq('skip: crossing item planted from the window end', table.concat(got, ' '), '100+2.5@1.5 103+3.5@0.5 106.5+1.5@0')
-- досадка того же окна этот кусок уже не сажает
items = { { pos = 0, len = 4, chunk = '<ITEM\n>' } }
A.session_plant('tr', { pos = 0, rgnend = 4 }, 100, 108, 102.5, nil, 't', { 101, 103 })
got = {}; for _, it in ipairs(items) do if it.pos >= 100 then got[#got + 1] = it.pos end end
eq('fill skips the piece crossing the window', #got, 0)

print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
