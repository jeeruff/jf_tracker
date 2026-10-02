-- smoke_import.lua — импорт REX и XRNI в библиотеку трека «A drums» (только
-- песочница: несохранённый проект с треком «A drums»), затем undo → ExtState jf_tracker/smoke
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out = {}
local function log(s) out[#out + 1] = s end
local names, tr = {}, nil
for i = 0, R.CountTracks(0) - 1 do local t = R.GetTrack(0, i); local _, n = R.GetTrackName(t); names[#names + 1] = n; if n == 'A drums' then tr = t end end
local _, pname = R.EnumProjects(-1, '')
if (pname and pname ~= '') or not tr then log('REFUSED') else
  local ok, err = pcall(function()
    local model = dofile(DIR .. '/jf_tracker_model.lua')
    local edit = dofile(DIR .. '/jf_tracker_edit.lua'); edit.init(model)
    local IM = dofile(DIR .. '/jf_tracker_import.lua')
    local n0 = R.CountTrackMediaItems(tr)
    local rx = '/Users/Shared/Prismatic Bliss Library/Samples/Loops/Drums/Snare[98] Stellate.rx2'
    local r = IM.rx2_slices(rx)
    local it = edit.depot_add(rx, tr)
    if it and r then edit.set_slices(it, r.slices) end
    local sl = it and edit.item_slices(it) or {}
    log(('REX: item %s, source %s, slices %d (file %d)'):format(tostring(it ~= nil), it and R.GetMediaSourceType(R.GetMediaItemTake_Source(R.GetActiveTake(it)), '') or '-', #sl, r and #r.slices or -1))
    log(('items %d → %d'):format(n0, R.CountTrackMediaItems(tr)))
    edit.undo(); edit.undo()
    log(('undo → %d items'):format(R.CountTrackMediaItems(tr)))
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
