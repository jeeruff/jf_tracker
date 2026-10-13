-- smoke_slicepool.lua — граница слайса в сэмпле двигает начало всех его нот (и транспонированных) (13 окт)
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
  local tr = R.GetTrack(0, 0)
  local root = R.GetTrackMediaItem(tr, 0)
  edit.set_slices(root, { 0, 0.2, 0.4, 0.6 })
  local a = edit.insert_slice(tr, nil, 4, 400, root, 2)
  local b = edit.insert_slice(tr, nil, 4, 420, root, 2)
  R.SetMediaItemTakeInfo_Value(R.GetActiveTake(b), 'D_PITCH', 5)
  local o0 = R.GetMediaItemTakeInfo_Value(R.GetActiveTake(a), 'D_STARTOFFS')
  local l0, p0 = R.GetMediaItemInfo_Value(a, 'D_LENGTH'), R.GetMediaItemInfo_Value(a, 'D_POSITION')
  edit.set_slices(root, { 0, 0.25, 0.4, 0.6 })
  local r = R.GetMediaItemTakeInfo_Value(R.GetActiveTake(a), 'D_PLAYRATE')
  local oa = R.GetMediaItemTakeInfo_Value(R.GetActiveTake(a), 'D_STARTOFFS')
  local ob = R.GetMediaItemTakeInfo_Value(R.GetActiveTake(b), 'D_STARTOFFS')
  check('slice 2 note start moved', math.abs(oa - (o0 + 0.05 * r)) < 1e-6, ('%.4f -> %.4f'):format(o0, oa))
  check('  the note stays: position and length', math.abs(R.GetMediaItemInfo_Value(a, 'D_LENGTH') - l0) < 1e-9 and math.abs(R.GetMediaItemInfo_Value(a, 'D_POSITION') - p0) < 1e-9)
  check('  the transposed one too', math.abs(ob - oa) < 1e-6, ('%.4f'):format(ob))
end)
if not ok then log('ERR ' .. tostring(err)); bad = bad + 1 end
log(bad .. ' bad')
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
