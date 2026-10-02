-- smoke_norm.lua — E.item_vol / E.normalize на первом item трека 1 → ExtState jf_tracker/smoke
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out = {}
local function log(s) out[#out + 1] = s end
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
local _, pname = R.EnumProjects(-1, '')
if (pname and pname ~= '') or not table.concat(names, ','):find('A drums', 1, true) then log('REFUSED') else
  local ok, err = pcall(function()
    local model = dofile(DIR .. '/jf_tracker_model.lua')
    local edit = dofile(DIR .. '/jf_tracker_edit.lua'); edit.init(model)
    local it = R.GetTrackMediaItem(R.GetTrack(0, 0), 0)
    local v0 = R.GetMediaItemInfo_Value(it, 'D_VOL')
    edit.item_vol(it, -6); log(('vol -6 → %.3f'):format(R.GetMediaItemInfo_Value(it, 'D_VOL')))
    local g = edit.normalize(it); log(('normalize gain %s → D_VOL %.3f'):format(tostring(g), R.GetMediaItemInfo_Value(it, 'D_VOL')))
    edit.undo(); edit.undo(); log(('undo → %.3f (was %.3f)'):format(R.GetMediaItemInfo_Value(it, 'D_VOL'), v0))
    local snap = model.snapshot(4)
    local n = 0; for _ in pairs(snap.inst_of) do n = n + 1 end
    log('inst_of entries ' .. n .. ' pool ' .. #snap.pool)
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
