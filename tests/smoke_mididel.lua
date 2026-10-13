-- smoke_mididel.lua — Backspace в MIDI-клипе (13 окт): нота через строку короче, ниже — вверх, без разреза (песочница)
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out, bad = {}, 0
local function log(s) out[#out + 1] = s end
local function check(name, cond, info) if not cond then bad = bad + 1 end; log((cond and 'ok ' or 'BAD ') .. name .. (info and (' (' .. info .. ')') or '')) end
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
local _, pname = R.EnumProjects(-1, '')
if (pname and pname ~= '') or table.concat(names, ',') ~= 'A drums,B lanes,M synth,DEPOT' then R.SetExtState('jf_tracker', 'smoke', 'REFUSED', false); return end
local ok, err = pcall(function()
  local model = dofile(DIR .. '/jf_tracker_model.lua')
  local edit = dofile(DIR .. '/jf_tracker_edit.lua'); edit.init(model)
  local tr = R.GetTrack(0, 2)
  for i = R.CountTrackMediaItems(tr) - 1, 0, -1 do R.DeleteTrackMediaItem(tr, R.GetTrackMediaItem(tr, i)) end
  local lpb = 4
  local function rt(r) return edit.row_time(r, lpb, 0) end
  local it = R.CreateNewMIDIItemInProj(tr, rt(0), rt(16))
  local tk = R.GetActiveTake(it)
  local function P(t) return R.MIDI_GetPPQPosFromProjTime(tk, t) end
  R.MIDI_InsertNote(tk, false, false, P(rt(0)), P(rt(8)), 0, 60, 100, true)
  R.MIDI_InsertNote(tk, false, false, P(rt(10)), P(rt(12)), 0, 62, 100, true)
  R.MIDI_Sort(tk)
  edit.time_delete({ tr }, rt(3), rt(4), math.huge, true)
  check('one item (not split)', R.CountTrackMediaItems(tr) == 1, R.CountTrackMediaItems(tr))
  tk = R.GetActiveTake(R.GetTrackMediaItem(tr, 0))
  local _, nn = R.MIDI_CountEvts(tk)
  check('two notes', nn == 2, nn)
  local _, _, _, a0, a1 = R.MIDI_GetNote(tk, 0)
  local function row(ppq) return model.row_of_time(R.MIDI_GetProjTimeFromPPQPos(tk, ppq), lpb) end
  check('the note through the row is a row shorter (OFF up)', math.abs(row(a1) - 7) < 0.01, ('%.2f'):format(row(a1)))
  local _, _, _, b0 = R.MIDI_GetNote(tk, 1)
  check('the note below moved up a row', math.abs(row(b0) - 9) < 0.01, ('%.2f'):format(row(b0)))
end)
if not ok then log('ERR ' .. tostring(err)); bad = bad + 1 end
log(bad .. ' bad')
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
