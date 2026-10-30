-- tests/test_phrase.lua — фразы (30 окт): раскладка вхождения, копии на треках источника, транспонирование нот /
-- D_PITCH, громкость, обрезка по триггеру, повторная синхронизация без работы, сдвиг / удаление триггера, правка
-- источника, копия не на месте
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local fails, n = 0, 0
local function ok(c, msg) n = n + 1; if not c then fails = fails + 1; print('FAIL ' .. msg) end end
local function near(a, b) return math.abs(a - b) < 1e-6 end

-- проект-стаб: время = доли (QN), чанк = ссылка на айтем-образец
local TR, REG, IDS, GN = {}, {}, {}, 0
local function deep(t) if type(t) ~= 'table' then return t end; local o = {}; for k, v in pairs(t) do o[k] = deep(v) end; return o end
local function item(tr, f)
  GN = GN + 1
  local it = { tr = tr, v = { D_POSITION = f.pos, D_LENGTH = f.len, B_MUTE = 0 }, ext = {}, guid = '{G' .. GN .. '}',
    take = { name = f.name or '', midi = f.notes ~= nil, notes = f.notes or {}, v = { D_PITCH = 0, D_VOL = 1, D_STARTOFFS = 0 } } }
  tr.items[#tr.items + 1] = it
  IDS[it.guid] = it
  return it
end
local function track() local t = { items = {} }; TR[#TR + 1] = t; return t end
local function note(p, pi, ve) return { s = p, e = p + 1, pi = pi, ve = ve or 100 } end
reaper = setmetatable({
  CountTracks = function() return #TR end,
  GetTrack = function(_, i) return TR[i + 1] end,
  CountTrackMediaItems = function(tr) return #tr.items end,
  GetTrackMediaItem = function(tr, i) return tr.items[i + 1] end,
  GetMediaItemInfo_Value = function(it, k) return it.v[k] or 0 end,
  SetMediaItemInfo_Value = function(it, k, v) it.v[k] = v end,
  GetSetMediaItemInfo_String = function(it, k, v, set)
    if k == 'GUID' then return true, it.guid end
    local key = k:match('^P_EXT:(.+)$')
    if set then it.ext[key] = v; return true, v end
    return true, it.ext[key] or ''
  end,
  GetActiveTake = function(it) return it.take end,
  TakeIsMIDI = function(tk) return tk.midi end,
  GetSetMediaItemTakeInfo_String = function(tk) return true, tk.name end,
  GetMediaItemTakeInfo_Value = function(tk, k) return tk.v[k] or 0 end,
  SetMediaItemTakeInfo_Value = function(tk, k, v) tk.v[k] = v end,
  MIDI_CountEvts = function(tk) return true, #tk.notes, 0, 0 end,
  MIDI_GetNote = function(tk, k) local x = tk.notes[k + 1]; return true, false, false, x.s, x.e, 0, x.pi, x.ve end,
  MIDI_SetNote = function(tk, k, _, _, s, e, _, pi, ve) tk.notes[k + 1] = { s = s, e = e, pi = pi, ve = ve } end,
  MIDI_Sort = function() end,
  MIDI_GetHash = function(tk) local p = {}; for _, x in ipairs(tk.notes) do p[#p + 1] = x.s .. ':' .. x.pi .. ':' .. x.ve end; return true, table.concat(p, ',') end,
  GetItemStateChunk = function(it) return true, '<ITEM\nGUID {x}\nREF ' .. it.guid .. '\n>' end,
  AddMediaItemToTrack = function(tr) local it = item(tr, { pos = 0, len = 0 }); return it end,
  SetItemStateChunk = function(it, ch)
    local src = IDS[ch:match('REF (%S+)')]
    it.v = deep(src.v); it.take = deep(src.take); it.ext = deep(src.ext)
    return true
  end,
  DeleteTrackMediaItem = function(tr, it) for k, x in ipairs(tr.items) do if x == it then table.remove(tr.items, k); return true end end end,
  EnumProjectMarkers3 = function(_, i) local r = REG[i + 1]; if not r then return 0 end; return 1, true, r.pos, r.e, r.name, i + 1, 0 end,
  TimeMap2_timeToQN = function(_, t) return t end,
  TimeMap2_QNToTime = function(_, q) return q end,
  genGuid = function() GN = GN + 1; return '{P' .. GN .. '}' end,
}, { __index = function() return function() return 0 end end })
local PH = dofile(DIR .. '/jf_tracker_phrase.lua')

-- 1. раскладка
local pl = PH.place({ q0 = 10, q1 = 14 }, 100, { { q0 = 100, q1 = 101 }, { q0 = 102, q1 = 106 }, { q0 = 104, q1 = 105 } })
ok(#pl == 2 and near(pl[1].q0, 10) and near(pl[2].q0, 12), 'items shifted to the trigger, the one after its end is out')
ok(pl[2].cut and near(pl[2].q1, 14) and not pl[1].cut, 'the one sticking out is cut at the trigger end')

-- 2. проект: источник ph:bass на 100..104 (MIDI на t1, аудио на t2 с 102), триггер на t1 в 0 (4 доли, D-4 vel 50)
local t1, t2 = track(), track()
REG = { { pos = 100, e = 104, name = 'ph:bass' } }
local sm = item(t1, { pos = 100, len = 2, notes = { note(0, 60), note(1, 64) } })
local sa = item(t2, { pos = 102, len = 4 })
local tg = item(t1, { pos = 0, len = 4, name = 'ph:bass', notes = { note(0, 62, 50) } })
local function copies(tr) local o = {}; for _, it in ipairs(tr.items) do if it.ext.jf_phrc then o[#o + 1] = it end end; return o end
ok(PH.sync() == 1, 'one trigger built')
local c1, c2 = copies(t1), copies(t2)
ok(#c1 == 1 and #c2 == 1, 'a copy on each source track')
ok(near(c1[1].v.D_POSITION, 0) and c1[1].take.notes[1].pi == 62 and c1[1].take.notes[2].pi == 66, 'MIDI copy at the trigger, +2 semitones')
ok(c1[1].take.notes[1].ve == 50, 'velocity 50 of 100 scales notes: ' .. c1[1].take.notes[1].ve)
ok(near(c2[1].v.D_POSITION, 2) and near(c2[1].v.D_LENGTH, 2), 'audio copy at +2, cut at the trigger end')
ok(near(c2[1].take.v.D_PITCH, 2) and near(c2[1].take.v.D_VOL, 0.5), 'audio: D_PITCH +2, volume x0.5')
ok(sm.take.notes[1].pi == 60 and sa.take.v.D_PITCH == 0, 'the source is untouched')
ok(tg.v.B_MUTE == 1, 'the trigger is muted')
ok(c1[1].ext.jf_phrc == tg.guid, 'copies are marked with the trigger GUID')

-- 3. ничего не менялось — без работы
ok(PH.sync() == 0, 'second sync does nothing')

-- 4. сдвиг триггера — копии за ним
tg.v.D_POSITION = 8
PH.sync()
c1, c2 = copies(t1), copies(t2)
ok(#c1 == 1 and #c2 == 1 and near(c1[1].v.D_POSITION, 8) and near(c2[1].v.D_POSITION, 10), 'copies follow the moved trigger')

-- 5. правка источника — вхождение следует (живая связь)
sm.take.notes[2].pi = 67
PH.sync()
c1 = copies(t1)
ok(#c1 == 1 and c1[1].take.notes[2].pi == 69, 'source edit reaches the copy: ' .. tostring(c1[1] and c1[1].take.notes[2].pi))

-- 6. копия не на месте (паттерн скопирован вместе с ней) — пересборка, лишняя вон
local stray = item(t2, { pos = 40, len = 1 }); stray.ext.jf_phrc = tg.guid
PH.sync()
c2 = copies(t2)
ok(#c2 == 1 and near(c2[1].v.D_POSITION, 10), 'a stray copy is removed, the right one stays')

-- 7. удалён триггер — копии вон
for k, x in ipairs(t1.items) do if x == tg then table.remove(t1.items, k) end end
PH.sync()
ok(#copies(t1) == 0 and #copies(t2) == 0, 'trigger deleted - its copies are gone')
ok(#t1.items == 1 and #t2.items == 1, 'only the source items remain')

print(('test_phrase: %d/%d ok'):format(n - fails, n))
os.exit(fails == 0 and 0 or 1)
