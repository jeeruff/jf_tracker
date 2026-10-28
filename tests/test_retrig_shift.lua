-- tests/test_retrig_shift.lua — Backspace / Insert строк в MIDI-клипе с 0R: метки копий retrigger (P_EXT:jf_rtg)
-- и исходные длины (P_EXT:jf_rtl) едут вместе с нотами (иначе копии становились настоящими нотами)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local fails, n = 0, 0
local function ok(c, msg) n = n + 1; if not c then fails = fails + 1; print('FAIL ' .. msg) end end

local PPQ = 960   -- тиков на секунду (item с 0)
local IT, TR
local function build()
  IT = { pos = 0, len = 4, ext = {}, take = { notes = {} } }
  TR = { items = { IT } }
  IT.tr = TR
  local N = IT.take.notes
  N[#N + 1] = { s = 0, e = 960, pi = 60, ch = 0, ve = 100 }          -- нота 0..1 с
  N[#N + 1] = { s = 1920, e = 2160, pi = 50, ch = 0, ve = 100 }      -- оригинал 2.0 c, укорочен ретриггером
  N[#N + 1] = { s = 2160, e = 2399, pi = 50, ch = 0, ve = 60 }       -- копия
  N[#N + 1] = { s = 2400, e = 2880, pi = 50, ch = 0, ve = 36 }       -- копия
  IT.ext['P_EXT:jf_rtg'] = '2160:50:0;2400:50:0'
  IT.ext['P_EXT:jf_rtl'] = '1920:50:2880.000'
end
local function sorted() table.sort(IT.take.notes, function(a, b) return a.s < b.s end) end
reaper = setmetatable({
  CountTrackMediaItems = function(tr) return #tr.items end,
  GetTrackMediaItem = function(tr, i) return tr.items[i + 1] end,
  GetMediaItemInfo_Value = function(it, k) if k == 'D_POSITION' then return it.pos elseif k == 'D_LENGTH' then return it.len end; return 0 end,
  SetMediaItemInfo_Value = function(it, k, v) if k == 'D_POSITION' then it.pos = v elseif k == 'D_LENGTH' then it.len = v end end,
  GetActiveTake = function(it) return it.take end,
  TakeIsMIDI = function() return true end,
  MIDI_GetPPQPosFromProjTime = function(_, t) return t * PPQ end,
  MIDI_GetProjTimeFromPPQPos = function(_, p) return p / PPQ end,
  MIDI_CountEvts = function(tk) sorted(); return true, #tk.notes, 0, 0 end,
  MIDI_GetNote = function(tk, k) local x = tk.notes[k + 1]; return true, false, false, x.s, x.e, x.ch, x.pi, x.ve end,
  MIDI_SetNote = function(tk, k, _, _, s, e) local x = tk.notes[k + 1]; x.s, x.e = s, e end,
  MIDI_DeleteNote = function(tk, k) table.remove(tk.notes, k + 1) end,
  GetSetMediaItemInfo_String = function(it, key, v, set) if set then it.ext[key] = v; return true, v end; return true, it.ext[key] or '' end,
  GetMediaItem_Track = function(it) return it.tr end,
  CountTracks = function() return 1 end,
  GetTrack = function() return TR end,
  ValidatePtr = function() return true end,
  time_precise = function() return 0 end,
}, { __index = function() return function() return 0 end end })
local E = dofile(DIR .. '/jf_tracker_edit.lua')

local function rtg_hits()
  local keys, hit = {}, 0
  for a, pi, ch in (IT.ext['P_EXT:jf_rtg'] or ''):gmatch('(%d+):(%d+):(%d+)') do keys[#keys + 1] = { tonumber(a), tonumber(pi) } end
  for _, k in ipairs(keys) do
    for _, x in ipairs(IT.take.notes) do if math.abs(x.s - k[1]) < 1 and x.pi == k[2] then hit = hit + 1; break end end
  end
  return hit, #keys
end

-- Backspace: удалить 0.5 с с 1.0 (между первой нотой и ретриггером)
build()
local okc = pcall(E.time_delete, { TR }, 1.0, 1.5, math.huge, true, nil, nil, false)
ok(okc, 'time_delete runs on the stub')
local hit, nk = rtg_hits()
ok(nk == 2 and hit == 2, ('after delete every copy mark still points at a copy (%d / %d)'):format(hit, nk))
ok((IT.ext['P_EXT:jf_rtl'] or ''):match('^1440:50:2400') ~= nil, 'the original length record moved with the note: ' .. tostring(IT.ext['P_EXT:jf_rtl']))

-- Backspace над копией: копия удалена — и её метка
build()
pcall(E.time_delete, { TR }, 2.1, 2.3, math.huge, true, nil, nil, false)
local _, nk2 = rtg_hits()
ok(nk2 == 1, 'a deleted copy loses its mark')

-- Insert: вставить 0.5 с на 1.0
build()
pcall(E.time_insert, { TR }, 1.0, 0.5, math.huge, true, nil, nil)
local h3, k3 = rtg_hits()
ok(k3 == 2 and h3 == 2, ('after insert every copy mark points at a copy (%d / %d)'):format(h3, k3))

print(('test_retrig_shift: %d/%d ok'):format(n - fails, n))
os.exit(fails == 0 and 0 or 1)
