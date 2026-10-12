-- smoke_timenotes.lua — Backspace / Insert строк (notes = true): аудио-нота через строку не режется → ExtState jf_tracker/smoke
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out = {}
local function log(s) out[#out + 1] = s end
local _, pname = R.EnumProjects(-1, '')
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
if (pname and pname ~= '') or not table.concat(names, ','):find('A drums', 1, true) then log('REFUSED') else
  local ok, err = pcall(function()
    local model = dofile(DIR .. '/jf_tracker_model.lua')
    local edit = dofile(DIR .. '/jf_tracker_edit.lua'); edit.init(model)
    local tr = R.GetTrack(0, 0)
    local function items()
      local t = {}
      for i = 0, R.CountTrackMediaItems(tr) - 1 do local it = R.GetTrackMediaItem(tr, i); t[#t + 1] = ('%.3f+%.3f'):format(R.GetMediaItemInfo_Value(it, 'D_POSITION'), R.GetMediaItemInfo_Value(it, 'D_LENGTH')) end
      return #t .. ': ' .. table.concat(t, ' ')
    end
    log('before ' .. items())
    -- amen 0..2 s; строка у 0.5 s (внутри amen)
    local t0, t1 = 1.0, 1.125
    edit.time_delete({ tr }, t0, t1, 6, true)
    log('delete row inside amen ' .. items())
    edit.time_insert({ tr }, t0, t1 - t0, 6, true)
    log('insert row inside amen ' .. items())
    edit.undo(); edit.undo()
    log('undo ' .. items())
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
