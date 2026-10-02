-- smoke_replace.lua — E.replace_source (Cmd+Enter браузера) в песочнице → ExtState jf_tracker/smoke
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
    local tr = R.GetTrack(0, 0)
    local it = R.GetTrackMediaItem(tr, 0)
    local take = R.GetActiveTake(it)
    local before = R.GetMediaSourceFileName(R.GetMediaItemTake_Source(take), '')
    local len0 = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
    -- любой другой wav из папки текущего источника
    local dir = before:match('(.*)/[^/]+$')
    local other
    local i = 0
    while true do local f = R.EnumerateFiles(dir, i); if not f then break end; if f:lower():match('%.wav$') and dir .. '/' .. f ~= before then other = dir .. '/' .. f; break end; i = i + 1 end
    if not other then log('no other wav next to ' .. before); return end
    local n = edit.replace_source({ it }, other)
    local after = R.GetMediaSourceFileName(R.GetMediaItemTake_Source(R.GetActiveTake(it)), '')
    log(('replaced %d: %s -> %s, length kept %s, offs %.3f, name %s'):format(n, before:match('[^/]+$'), after:match('[^/]+$'),
      tostring(math.abs(R.GetMediaItemInfo_Value(it, 'D_LENGTH') - len0) < 1e-6), R.GetMediaItemTakeInfo_Value(R.GetActiveTake(it), 'D_STARTOFFS'),
      select(2, R.GetSetMediaItemTakeInfo_String(R.GetActiveTake(it), 'P_NAME', '', false))))
    edit.undo()
    log('undo -> ' .. R.GetMediaSourceFileName(R.GetMediaItemTake_Source(R.GetActiveTake(it)), ''):match('[^/]+$'))
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
