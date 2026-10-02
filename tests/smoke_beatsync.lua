-- smoke_beatsync.lua — E.beatsync и E.item_drag_to → ExtState jf_tracker/smoke
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
    local inst = R.GetTrackMediaItem(tr, 0)
    local lpb, row = 4, 400
    edit.insert_note(tr, nil, lpb, row, 60, 100, 1, inst)
    local it; for i = 0, R.CountTrackMediaItems(tr) - 1 do local x = R.GetTrackMediaItem(tr, i); if math.abs(R.GetMediaItemInfo_Value(x, 'D_POSITION') - edit.row_time(row, lpb, 0)) < 1e-4 then it = x end end
    local tk = R.GetActiveTake(it)
    local function d() return ('len=%.3f rate=%.3f'):format(R.GetMediaItemInfo_Value(it, 'D_LENGTH'), R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')) end
    log('inserted ' .. d())
    local head = { kind = 'audio', item = it }
    edit.beatsync({ head }, lpb, 'beat'); log('beat: ' .. d() .. ' (1 beat = ' .. ('%.3f'):format(edit.row_time(row + lpb, lpb, 0) - edit.row_time(row, lpb, 0)) .. 's)')
    edit.beatsync({ head }, lpb, '2'); log('2 rows: ' .. d())
    edit.beatsync({ head }, lpb, 'bar'); log('bar: ' .. d())
    -- протяжка: конец на строку row+3, начало на row+1
    edit.item_drag_begin('t'); edit.item_drag_to(it, 'end', edit.row_time(row + 3, lpb, 0)); edit.item_drag_end()
    log('drag end → ' .. ('%.3f'):format(R.GetMediaItemInfo_Value(it, 'D_LENGTH')) .. ' (expect 3 rows = ' .. ('%.3f'):format(edit.row_time(3, lpb, 0)) .. ')')
    edit.item_drag_begin('t'); edit.item_drag_to(it, 'start', edit.row_time(row + 1, lpb, 0)); edit.item_drag_end()
    log(('drag start → pos row %.2f offs %.3f len %.3f'):format(model.row_of_time(R.GetMediaItemInfo_Value(it, 'D_POSITION'), lpb), R.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS'), R.GetMediaItemInfo_Value(it, 'D_LENGTH')))
    for _ = 1, 6 do edit.undo() end
    local left = 0; for i = 0, R.CountTrackMediaItems(tr) - 1 do if R.GetMediaItemInfo_Value(R.GetTrackMediaItem(tr, i), 'D_POSITION') >= edit.row_time(row, lpb, 0) - 1e-4 then left = left + 1 end end
    log('undo → items in zone ' .. left)
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
