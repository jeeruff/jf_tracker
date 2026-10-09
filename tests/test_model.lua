-- test_model.lua — модель трекера на стабах reaper.*, без REAPER.
-- Запуск из папки jf_tracker:  lua tests/test_model.lua
--
-- Проверяет: строки/доли от QN, разбор потока MIDI, раскладку по
-- подколонкам (полифония и перекрытие), lanes, разворот цикла, кеш.

local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
package.path = DIR .. '/?.lua;' .. package.path

-- ── стабы ─────────────────────────────────────────────────────────────────
-- Проект: темп 120 (1 QN = 0.5 с), 4/4. Треки и items — таблицы.
local BPM = 120
local function qn2t(qn) return qn * 60 / BPM end
local function t2qn(t) return t * BPM / 60 end

local tracks = {}
local state_count = 1

local function midi_stream(events)   -- {{dppq, flag, bytes}, …} → строка
  local parts = {}
  for _, e in ipairs(events) do
    parts[#parts + 1] = string.pack('<i4Bs4', e[1], e[2], string.char(table.unpack(e[3])))
  end
  return table.concat(parts)
end

_G.reaper = {
  CountTracks = function() return #tracks end,
  GetTrack = function(_, i) return tracks[i + 1] end,
  GetTrackName = function(tr) return true, tr.name end,
  GetTrackColor = function(tr) return tr.color or 0 end,
  GetMediaTrackInfo_Value = function(tr, k)
    if k == 'I_FREEMODE' then return tr.freemode or 0 end
    if k == 'I_NUMFIXEDLANES' then return tr.nlanes or 1 end
    if k == 'B_MUTE' then return 0 end
    return 0
  end,
  GetSetMediaTrackInfo_String = function(tr, k)
    local n = tonumber(k:match('P_LANENAME:(%d+)'))
    return true, (tr.lanenames or {})[n + 1] or ''
  end,
  CountTrackMediaItems = function(tr) return #tr.items end,
  GetTrackMediaItem = function(tr, i) return tr.items[i + 1] end,
  GetMediaItemInfo_Value = function(it, k)
    if k == 'D_POSITION' then return it.pos end
    if k == 'D_LENGTH' then return it.len end
    if k == 'I_FIXEDLANE' then return it.lane or 0 end
    if k == 'D_VOL' then return it.vol or 1 end
    if k == 'B_MUTE_ACTUAL' then return it.muted and 1 or 0 end
    if k == 'B_LOOPSRC' then return it.loop and 1 or 0 end
    return 0
  end,
  GetActiveTake = function(it) return it.take end,
  GetSetMediaItemInfo_String = function(it, k) return true, (it.ext or {})[k] or '' end,
  TakeIsMIDI = function(tk) return tk.midi ~= nil end,
  GetMediaItemTake_Source = function(tk) return tk.src or { len = tk.srclen or 1, qn = tk.midi ~= nil } end,
  GetMediaItemTakeInfo_Value = function(tk, k)
    if k == 'D_PITCH' then return tk.pitch or 0 end
    if k == 'D_PLAYRATE' then return tk.rate or 1 end
    if k == 'B_PPITCH' then return tk.ppitch and 1 or 0 end
    if k == 'D_VOL' then return tk.vol or 1 end
    if k == 'D_STARTOFFS' then return tk.offs or 0 end
    if k == 'D_PAN' then return tk.pan or 0 end
    if k == 'I_CHANMODE' then return tk.chanmode or 0 end
    return 0
  end,
  GetTakeName = function(tk) return tk.name or '' end,
  -- MIDI-лейны (6 окт): tk.ccs = { {ppq, chanmsg, m2, m3} }, время = ppq / 960 QN от начала item
  MIDI_CountEvts = function(tk) return true, 0, #(tk.ccs or {}), 0 end,
  MIDI_GetCC = function(tk, i) local c = tk.ccs[i + 1]; return true, false, false, c[1], c[2], 0, c[3], c[4] end,
  MIDI_GetTextSysexEvt = function() return false end,
  MIDI_GetProjTimeFromPPQPos = function(tk, ppq) return tk.item.pos + qn2t(ppq / 960) end,
  -- огибающая громкости take (5 окт): tk.venv = { {t, v}, … }, режим 0 (амплитуда)
  GetTakeEnvelopeByName = function(tk, nm) return nm == 'Volume' and tk.venv or nil end,
  CountEnvelopePoints = function(env) return #env end,
  GetEnvelopePoint = function(env, i) local p = env[i + 1]; return true, p[1], p[2], 0, 0, false end,
  GetEnvelopeScalingMode = function() return 0 end,
  ScaleFromEnvelopeMode = function(_, v) return v end,
  GetMediaSourceLength = function(src) return src.len, src.qn end,
  MIDI_GetHash = function(tk) return true, tk.hash or 'h' end,
  MIDI_GetTrackHash = function(tr) return true, tr.hash or 'th' end,
  MIDI_GetAllEvts = function(tk) return true, midi_stream(tk.midi) end,
  -- PPQ 960 на QN; item.pos + offset — как в REAPER
  MIDI_GetProjQNFromPPQPos = function(tk, ppq) return t2qn(tk.item.pos) + ppq / 960 end,
  TimeMap2_timeToQN = function(_, t) return t2qn(t) end,
  TimeMap2_QNToTime = function(_, qn) return qn2t(qn) end,
  TimeMap_QNToMeasures = function(_, qn)
    local m = math.floor(qn / 4 + 1e-9)
    return m, m * 4, (m + 1) * 4
  end,
  GetProjectStateChangeCount = function() return state_count end,
  time_precise = function() return os.clock() end,
}

local M = dofile(DIR .. '/jf_tracker_model.lua')

-- ── помощники ─────────────────────────────────────────────────────────────
local fails, checks = 0, 0
local function eq(name, got, want)
  checks = checks + 1
  if got ~= want then
    fails = fails + 1
    print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want)))
  end
end

-- ── 1. строки и доли ──────────────────────────────────────────────────────
do
  local r, d = M.row_of_qn(0, 4);      eq('row 0', r, 0); eq('delay 0', d, 0)
  r, d = M.row_of_qn(0.5, 4);          eq('row qn.5', r, 2); eq('delay qn.5', d, 0)
  r, d = M.row_of_qn(1/3, 4);          eq('row 1/3', r, 1); eq('delay 1/3', d, 85)   -- 4/3 = 1.333 → 0.333*256
  r, d = M.row_of_qn(0.9999999, 4);    eq('row rounding', r, 4); eq('delay rounding', d, 0)
  eq('note 60', M.note_name(60), 'C-4')
  eq('note 61', M.note_name(61), 'C#4')
  eq('note 48', M.note_name(48), 'C-3')
  eq('note 71', M.note_name(71), 'B-4')
  eq('hex 128', M.hex2(128), '80')
  eq('hex clamp', M.hex2(999), 'FF')
  eq('semis resample', math.floor(M.take_semitones(0, 2, false) + 0.5), 12)
  eq('semis stretch', M.take_semitones(0, 2, true), 0)
  eq('semis pitch', M.take_semitones(-3, 1, true), -3)
end

-- ── 2. разбор MIDI ────────────────────────────────────────────────────────
do
  -- C4 vel 100 на 0, длина 1 QN; E4 на 0 (полифония), длина 2 QN; D4 на 1 QN
  local s = midi_stream{
    { 0,   0, { 0x90, 60, 100 } },
    { 0,   0, { 0x90, 64, 90 } },
    { 960, 0, { 0x80, 60, 0 } },
    { 0,   2, { 0x90, 62, 80 } },   -- muted
    { 960, 0, { 0x90, 64, 0 } },    -- note-on vel 0 = off
    { 480, 0, { 0x80, 62, 0 } },
  }
  local notes = M.parse_midi(s)
  eq('notes count', #notes, 3)
  eq('n1 pitch', notes[1].pitch, 60); eq('n1 end', notes[1].ppq_end, 960)
  eq('n2 pitch', notes[2].pitch, 64); eq('n2 end', notes[2].ppq_end, 1920)
  eq('n3 pitch', notes[3].pitch, 62); eq('n3 start', notes[3].ppq, 960); eq('n3 muted', notes[3].muted, true)
  eq('n3 end', notes[3].ppq_end, 2400)
end

-- ── 3. снимок: аудио, lanes, перекрытие ───────────────────────────────────
do
  local a = { name = 'A', items = {} }
  -- item на 0 с, 1 такт (2 с = 4 QN = 16 строк), питч +2 через rate
  a.items[1] = { pos = 0, len = 2, loop = true, take = { name = 'kick.wav', rate = 2 ^ (2 / 12) } }
  -- item на 0.75 QN (строка 3), перекрывает первый → вторая подколонка
  a.items[2] = { pos = qn2t(0.75), len = 0.5, take = { name = 'snare.wav', pitch = -12 } }
  -- item ровно на границе строки 20, длина 1 строка → без cont
  a.items[3] = { pos = qn2t(5), len = qn2t(0.25), take = { name = 'hat.wav', pan = 0.5, chanmode = 2 }, loop = false }
  local b = { name = 'B', freemode = 2, nlanes = 2, lanenames = { 'one', 'two' }, items = {} }
  b.items[1] = { pos = 0, len = 0.5, lane = 1, take = { name = 'x.wav' } }
  local depot = { name = 'DEPOT', items = { { pos = 0, len = 1, take = { name = 'd' } } } }
  tracks = { a, b, depot }

  local snap = M.build(4)
  eq('cols (без DEPOT)', #snap.cols, 2)
  local la = snap.cols[1].lanes[1]
  eq('A subs', #la.subs, 2)
  local h = la.subs[1][0]
  eq('A head kind', h and h.kind, 'audio')
  eq('A head note', h and h.note, 'D-4')
  eq('A head name', h and h.name, 'kick.wav')
  eq('A head rows', h and h.rows, 16)
  eq('A cont 15', la.subs[1][15] and la.subs[1][15].kind, 'cont')
  eq('A row 16 free', la.subs[1][16], nil)
  local s2 = la.subs[2][3]
  eq('A sub2 snare', s2 and s2.name, 'snare.wav')
  eq('A snare note', s2 and s2.note, 'C-3')
  eq('A snare rows', s2 and s2.rows, 4)          -- 0.5 с = 1 QN = 4 строки
  local hat = la.subs[1][20]
  do
    local kick = la.subs[1][0]
    eq('kick loop_rows set', kick and kick.loop_rows ~= nil, true)
    eq('kick loop_rows < rows', kick and kick.loop_rows < kick.rows_f, true)
    eq('kick loop_first == loop_rows (offs 0)', kick and math.abs(kick.loop_first - kick.loop_rows) < 1e-6, true)
    eq('hat no loop', hat and hat.loop_rows, nil)
  end
  eq('hat head', hat and hat.kind, 'audio')
  eq('hat rows', hat and hat.rows, 1)
  eq('hat next free', la.subs[1][21], nil)
  eq('hat fx', table.concat(hat and hat.fx or {}, ' '), '8BF L00 M02')
  eq('kick fx (resample, no fx)', #(h and h.fx or {}), 0)
  local lb = snap.cols[2].lanes
  eq('B lanes', #lb, 2)
  eq('B lane2 name', lb[2].name, 'two')
  eq('B lane1 empty', next(lb[1].subs[1]), nil)
  eq('B lane2 item', lb[2].subs[1][0] and lb[2].subs[1][0].name, 'x.wav')
  eq('last_row', snap.last_row, 20)
end

-- ── 3b. стык внутри строки (9 окт): обрубленный item кончается на задержке
-- следующей ноты (свинг) — следующая нота в той же подколонке, в обоих порядках
do
  local d = 44 / 256 / 4                                  -- 44/256 строки в QN
  local function run_case(first_late)
    local a = { name = 'A', items = {} }
    local early = { pos = qn2t(1.5), len = qn2t(3 + d) - qn2t(1.5), take = { name = 'p.wav' } }   -- строки 6..12+2C
    local late  = { pos = qn2t(3 + d), len = qn2t(1.5), take = { name = 'n.wav' } }                -- строка 12, delay 2C
    a.items = first_late and { late, early } or { early, late }
    tracks = { a }
    local la = M.build(4).cols[1].lanes[1]
    local tag = first_late and ' (late first)' or ''
    eq('join subs' .. tag, #la.subs, 1)
    eq('join head 12' .. tag, la.subs[1][12] and la.subs[1][12].name, 'n.wav')
    eq('join head 12 delay' .. tag, la.subs[1][12] and la.subs[1][12].delay, 44)
    eq('join prev head' .. tag, la.subs[1][6] and la.subs[1][6].name, 'p.wav')
  end
  run_case(false); run_case(true)
  -- настоящее перекрытие (хвост дальше задержки) — по-прежнему вторая подколонка
  local a = { name = 'A', items = {
    { pos = qn2t(1.5), len = qn2t(3 + 2 * d) - qn2t(1.5), take = { name = 'p.wav' } },
    { pos = qn2t(3 + d), len = qn2t(1.5), take = { name = 'n.wav' } } } }
  tracks = { a }
  eq('overlap subs', #M.build(4).cols[1].lanes[1].subs, 2)
end

-- ── 4. снимок: MIDI, полифония, цикл, OFF ─────────────────────────────────
do
  local it = { pos = qn2t(4), len = qn2t(4), loop = true }
  it.take = { item = it, srclen = 2, midi = {
    { 0,   0, { 0x90, 60, 100 } },
    { 0,   0, { 0x90, 64, 90 } },
    { 480, 0, { 0x80, 60, 0 } },       -- C4: 0.5 QN = 2 строки → OFF в строке 2
    { 480, 0, { 0x80, 64, 0 } },       -- E4: 1 QN → OFF в строке 4
    { 0,   0, { 0x90, 67, 70 } },
    { 240, 0, { 0x80, 67, 0 } },       -- G4 1..1.25 QN — короче строки: только голова
  } }
  local m = { name = 'M', items = { it } }
  tracks = { m }
  local snap = M.build(4)
  local lane = snap.cols[1].lanes[1]
  eq('M subs', #lane.subs, 2)
  local s1, s2 = lane.subs[1], lane.subs[2]
  -- item начинается в строке 16 (4 QN); источник 2 QN → повтор в строке 24
  eq('M C4 head', s1[16] and s1[16].note, 'C-4')
  eq('M C4 vel', s1[16] and s1[16].vol, '64')
  eq('M C4 cont', s1[17] and s1[17].kind, 'cont')
  eq('M C4 off', s1[18] and s1[18].kind, 'off')
  eq('M E4 in sub2', s2[16] and s2[16].note, 'E-4')
  eq('M E4 off', s2[20] and s2[20].kind, 'off')
  eq('M G4 head', s1[20] and s1[20].note, 'G-4')
  eq('M G4 off next row', s1[21] and s1[21].kind, 'off')   -- нота ровно в строку: OFF в следующей
  eq('M loop repeat', s1[24] and s1[24].note, 'C-4')
  eq('M loop E4', s2[24] and s2[24].note, 'E-4')
  eq('M no third rep', s1[32], nil)
  eq('M last_row', snap.last_row, 29)
end

-- ── 5. кеш ────────────────────────────────────────────────────────────────
do
  local s1, ch1 = M.snapshot(4)
  local s2, ch2 = M.snapshot(4)
  eq('cache first', ch1, true); eq('cache hit', ch2, false); eq('cache same', s1, s2)
  state_count = state_count + 1
  local _, ch3 = M.snapshot(4)
  eq('cache miss on state', ch3, true)
  local _, ch4 = M.snapshot(8)
  eq('cache miss on lpb', ch4, true)
end

-- ── 6. строки вида ────────────────────────────────────────────────────────
do
  local rows = M.rows(14, 4, 4)
  eq('rows n', #rows, 4)
  eq('row 16 bar', rows[3].bar, true)
  eq('row 16 label', rows[3].label, '0016')
  eq('row 15 not beat', rows[2].beat, false)
  eq('row 16 t', rows[3].t, 2.0)
end

-- рамки items: дробные строки начала/конца, аудио — подколонка, MIDI — вся lane
do
  local snap = M.build(4)
  local nit, nmidi, naud = 0, 0, 0
  for _, col in ipairs(snap.cols) do for _, lane in ipairs(col.lanes) do
    for _, it in ipairs(lane.items or {}) do
      nit = nit + 1
      eq('item r0<r1', it.r1 > it.r0, true)
      if it.midi then nmidi = nmidi + 1; eq('midi item spans lane (si nil)', it.si, nil)
      else naud = naud + 1; eq('audio item has sub index', type(it.si), 'number') end
    end
  end end
  eq('items recorded', nit > 0, true); eq('midi items recorded', nmidi > 0, true)
end
-- узкие подколонки (2 окт): аккорд MIDI — подколонки без аудио
do
  local lane = { subs = { {} } }
  M._place(lane, 0, 3, { kind = 'midi' })
  M._place(lane, 0, 3, { kind = 'midi' })
  M._place(lane, 0, 3, { kind = 'audio' })
  eq('chord: 3 subs', #lane.subs, 3)
  eq('midi sub 2 is not audio', lane.audio_sub and lane.audio_sub[2] or false, false)
  eq('audio sub 3 flagged', lane.audio_sub and lane.audio_sub[3], true)
end
-- цвета огибающих как в аранжировке (2 окт): ключи из пар «Envelope: …»
do
  eq('env key volume', M.env_key('Volume', 0), 'col_env2')
  eq('env key volume pre', M.env_key('Volume (Pre-FX)', 0), 'col_env1')
  eq('env key pan', M.env_key('Pan', 0), 'col_env4')
  eq('env key pan pre', M.env_key('Pan (Pre-FX)', 0), 'col_env3')
  eq('env key trim', M.env_key('Trim Volume', 0), 'env_trim_vol')
  eq('env key width', M.env_key('Width', 0), 'col_env7')
  eq('env key mute', M.env_key('Mute', 0), 'env_track_mute')
  eq('env key send pan', M.env_key('Send Pan', 0), 'col_env8')
  eq('env key fx 1', M.env_key('Freq / ReaEQ', 0), 'col_env13')
  eq('env key fx 5 wraps', M.env_key('Gain / ReaEQ', 4), 'col_env13')
  eq('env key fx pan param is fx', M.env_key('Pan / ReaSurround', 1), 'col_env14')
end
-- ── связь копий инструмента (3 окт): метка jf_iid, обрезка — не новый инструмент
do
  local function au(pos, len, offs, ext, rate) local tk = { name = 'amen', offs = offs or 0, rate = rate or 1 }; local it = { pos = pos, len = len, take = tk, ext = ext }; tk.item = it; return it end
  local items = {
    au(0, 4, 0, { ['P_EXT:jf_iid'] = 'A' }),                -- инструмент
    au(4, 1, 0, { ['P_EXT:jf_iid'] = 'A' }),                -- его нота, обрезана следующей
    au(5, 0.5, 0, { ['P_EXT:jf_iid'] = 'A' }, 1.5),         -- нота в resample (другой rate) — тот же
    au(6, 0.25, 1, { ['P_EXT:jf_iid'] = 'A#2' }),           -- слайс 2
    au(7, 0.1, 1, { ['P_EXT:jf_iid'] = 'A#2' }),            -- слайс 2, обрезан
    au(8, 0.25, 1, { ['P_EXT:jf_iid'] = 'A#2~u1' }),        -- уникальная копия слайса
    au(9, 2, 3),                                            -- без метки
    au(11, 1, 3),                                           -- без метки, тот же offset, обрезан — тот же
    au(12, 1, 3.5),                                         -- без метки, другой offset — другой
  }
  local pool = M.track_pool({ items = items }, nil, nil, nil)
  eq('linked: 5 instruments, not 9', #pool, 5)
  local by = {}
  for _, e in ipairs(pool) do by[e.iid ~= '' and e.iid or ('offs' .. e.offs)] = e end
  eq('A: representative = longest', by.A and by.A.len, 4)
  eq('A: counts its notes', by.A and by.A.n, 3)
  eq('slice 2: one instrument, full length', by['A#2'] and by['A#2'].len, 0.25)
  eq('unique copy separate', by['A#2~u1'] ~= nil, true)
  eq('untagged cut merged, longest kept', by.offs3 and by.offs3.len, 2)
  eq('untagged other offset separate', by['offs3.5'] ~= nil, true)
end
-- порядок lib (3 окт): метка P_EXT:jf_ord на исходнике задаёт номер; без
-- метки — после размеченных; слайс носит номер исходника
do
  for k in pairs(tracks) do tracks[k] = nil end
  local function au(pos, name, ord, srclen)
    local tk = { name = name, src = { len = srclen, qn = false } }
    local it = { pos = pos, len = 1, take = tk, ext = { ['P_EXT:jf_ord'] = ord } }
    tk.item = it
    return it
  end
  tracks[1] = { name = 'T', items = { au(0, 'kick', '3', 1), au(2, 'snare', '1', 2), au(4, 'hat', nil, 3), au(6, 'clap', '2', 4) } }
  state_count = state_count + 1
  local snap = M.build(4)
  local names = {}
  for _, e in ipairs(snap.pool) do names[#names + 1] = e.name .. e.num end
  eq('order by jf_ord, unmarked last', table.concat(names, ' '), 'snare1 clap2 kick3 hat4')
  eq('roots counted', snap.nroots, 4)
end
-- слайс = нота (4 окт): слайс 2 — C#4, без S и T
do
  for k in pairs(tracks) do tracks[k] = nil end
  local tk = { name = 'amen', src = { len = 4, qn = false }, rate = 1.5, ppitch = true }
  local it = { pos = 0, len = 0.5, take = tk, ext = { ['P_EXT:jf_slice'] = '2', ['P_EXT:jf_iid'] = 'R#2' } }
  tk.item = it
  tracks[1] = { name = 'S', items = { it } }
  state_count = state_count + 1
  local snap = M.build(4)
  local head
  for _, lane in ipairs(snap.cols[1].lanes) do for _, sub in ipairs(lane.subs) do for _, c in pairs(sub) do if c.kind == 'audio' then head = c end end end end
  eq('slice note shows its pitch C-4', head and head.note, 'C-4')
  local hasS, hasT = nil, false
  for _, f in ipairs(head and head.fx or {}) do if f:sub(1, 1) == 'S' then hasS = f elseif f:sub(1, 1) == 'T' then hasT = true end end
  eq('slice number as S02', hasS, 'S02'); eq('no T on a slice note', hasT, false)
end
-- обратная карта stretch-маркеров (5 окт): шов лупа по маркерам
do
  local pts = { { pos = 0, src = 0 }, { pos = 1, src = 2 }, { pos = 2, src = 3 } }
  local function near(a, b) return math.abs((a or -99) - b) < 1e-9 end
  eq('inverse map: inside the first segment', near(M.item_time_of_src(pts, 1), 0.5), true)
  eq('inverse map: second segment', near(M.item_time_of_src(pts, 2.5), 1.5), true)
  eq('inverse map: slope 1 after the last marker', near(M.item_time_of_src(pts, 4), 3), true)
end
-- точки огибающей громкости take — числами в колонке vol (5 окт)
do
  for k in pairs(tracks) do tracks[k] = nil end
  -- item 2 с (4 QN = 16 строк при LPB 4), точки на 1.0 с (0.5) и 1.5 с (0.0)
  local tk = { name = 'pad', src = { len = 4, qn = false }, venv = { { 1.0, 0.5 }, { 1.5, 0 } } }
  local it = { pos = 0, len = 2, take = tk }
  tk.item = it
  tracks[1] = { name = 'P', items = { it } }
  state_count = state_count + 1
  local snap = M.build(4)
  local sub = snap.cols[1].lanes[1].subs[1]
  eq('env point 0.5 at row 8 shows 40', sub[8] and sub[8].vol, '40')
  eq('env point 0 at row 12 shows 00', sub[12] and sub[12].vol, '00')
  eq('rows without points stay empty', sub[9] and sub[9].vol, nil)
end
-- MIDI-лейны (6 окт): CC 74 и PC из событий MIDI item по строкам
do
  for k in pairs(tracks) do tracks[k] = nil end
  local tk = { name = 'm', midi = midi_stream({}), ccs = { { 0, 0xB0, 74, 64 }, { 960, 0xB0, 74, 127 }, { 960, 0xC0, 5, 0 } } }
  local it = { pos = 0, len = 2, take = tk }
  tk.item = it
  tracks[1] = { name = 'M', items = { it } }
  state_count = state_count + 1
  local snap = M.build(4)
  local ls = snap.cols[1].mlanes or {}
  eq('two midi lanes (CC74, PC)', #ls, 2)
  eq('CC74 first', ls[1] and ls[1].name, 'CC74')
  eq('CC74 row 0 = 64', ls[1] and ls[1].ev[0] and ls[1].ev[0].v, 64)
  eq('CC74 row 4 = 127 (1 QN at LPB 4)', ls[1] and ls[1].ev[4] and ls[1].ev[4].v, 127)
  eq('PC row 4 = 5', ls[2] and ls[2].ev[4] and ls[2].ev[4].v, 5)
end
print(('%d checks, %d failed'):format(checks, fails))
os.exit(fails == 0 and 0 or 1)
