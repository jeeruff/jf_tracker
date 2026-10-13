-- smoke_yankpitch.lua — yy / p транспонированной ноты-слайса сохраняет высоту (13 окт)
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
  R.SetMediaItemTakeInfo_Value(R.GetActiveTake(a), 'D_PITCH', 5)
  local reg = edit.yank({ { kind = 'audio', item = a, row0 = 400, rows = 1 } }, 4, 400, 1)
  edit.paste(reg, 4, 410, function() return { track = tr } end)
  local t = edit.row_time(410, 4, 0)
  local got
  for i = 0, R.CountTrackMediaItems(tr) - 1 do local x = R.GetTrackMediaItem(tr, i); if math.abs(R.GetMediaItemInfo_Value(x, 'D_POSITION') - t) < 1e-4 then got = x end end
  check('pasted', got ~= nil)
  check('  keeps its pitch +5', got and math.abs(R.GetMediaItemTakeInfo_Value(R.GetActiveTake(got), 'D_PITCH') - 5) < 1e-6, got and R.GetMediaItemTakeInfo_Value(R.GetActiveTake(got), 'D_PITCH'))
end)
if not ok then log('ERR ' .. tostring(err)); bad = bad + 1 end
log(bad .. ' bad')
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
