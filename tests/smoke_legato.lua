-- smoke_legato.lua — :legato fill (13 окт): длина ноты до следующей, скорость своя; off — назад (песочница) → ExtState jf_tracker/smoke
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out, bad = {}, 0
local function log(s) out[#out + 1] = s end
local function check(name, cond, info) if not cond then bad = bad + 1 end; log((cond and 'ok ' or 'BAD ') .. name .. (info and (' (' .. info .. ')') or '')) end
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
local _, pname = R.EnumProjects(-1, '')
if (pname and pname ~= '') or table.concat(names, ',') ~= 'A drums,B lanes,M synth,DEPOT' then R.SetExtState('jf_tracker', 'smoke', 'REFUSED', false); return end
local PAD = os.getenv('HOME') .. '/samples/LegoweltYamahaSY35sampleKit/Synth-VectorPad.wav'
local ok, err = pcall(function()
  local model = dofile(DIR .. '/jf_tracker_model.lua')
  local edit = dofile(DIR .. '/jf_tracker_edit.lua'); edit.init(model)
  local tr = R.GetTrack(0, 2)
  for i = R.CountTrackMediaItems(tr) - 1, 0, -1 do R.DeleteTrackMediaItem(tr, R.GetTrackMediaItem(tr, i)) end
  local function add(pos)
    local it = R.AddMediaItemToTrack(tr); local tk = R.AddTakeToMediaItem(it)
    R.SetMediaItemTake_Source(tk, R.PCM_Source_CreateFromFile(PAD))
    R.SetMediaItemInfo_Value(it, 'D_POSITION', pos); R.SetMediaItemInfo_Value(it, 'D_LENGTH', 0.25)
    R.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', 1.5)
    return it, tk
  end
  local a, ta = add(1.0); add(2.0)
  edit.legato(tr, nil, nil, nil, false, true)
  check('fill: the length goes to the next note', math.abs(R.GetMediaItemInfo_Value(a, 'D_LENGTH') - 1.0) < 1e-6, R.GetMediaItemInfo_Value(a, 'D_LENGTH'))
  check('  not stretched: the rate stays', math.abs(R.GetMediaItemTakeInfo_Value(ta, 'D_PLAYRATE') - 1.5) < 1e-9)
  edit.legato(tr, nil, nil, nil, true)
  check('off: the own length back', math.abs(R.GetMediaItemInfo_Value(a, 'D_LENGTH') - 0.25) < 1e-6)
  edit.legato(tr, nil, nil, nil, false)
  check('plain legato still stretches', math.abs(R.GetMediaItemTakeInfo_Value(ta, 'D_PLAYRATE') - 1.5 * 0.25) < 1e-6)
  -- шаг legato: вставка дотягивает прежнюю ноту до новой, скорость своя
  local t0 = R.GetTrack(0, 0)
  local inst = R.GetTrackMediaItem(t0, 0)
  local lpb = 4
  edit.step_legato = true
  edit.insert_note(t0, nil, lpb, 400, 60, 100, 1, inst)
  edit.insert_note(t0, nil, lpb, 410, 60, 100, 1, inst)
  edit.step_legato = false
  local first
  for i = 0, R.CountTrackMediaItems(t0) - 1 do local x = R.GetTrackMediaItem(t0, i); if math.abs(R.GetMediaItemInfo_Value(x, 'D_POSITION') - edit.row_time(400, lpb, 0)) < 1e-4 then first = x end end
  local want = edit.row_time(410, lpb, 0) - edit.row_time(400, lpb, 0)
  check('step legato: the note before lasts to the new one', first and math.abs(R.GetMediaItemInfo_Value(first, 'D_LENGTH') - want) < 1e-4, first and R.GetMediaItemInfo_Value(first, 'D_LENGTH'))
  check('  not stretched', first and math.abs(R.GetMediaItemTakeInfo_Value(R.GetActiveTake(first), 'D_PLAYRATE') - R.GetMediaItemTakeInfo_Value(R.GetActiveTake(inst), 'D_PLAYRATE')) < 1e-9)
end)
if not ok then log('ERR ' .. tostring(err)); bad = bad + 1 end
log(bad .. ' bad')
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
