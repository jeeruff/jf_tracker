-- smoke_cut.lua — новая нота рубит предыдущий item без x-fade; Shift — рядом → ExtState jf_tracker/smoke
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
    local lpb, row = 4, 500
    local t0 = edit.row_time(row, lpb, 0)
    local function zone() local l = {}; for i = 0, R.CountTrackMediaItems(tr) - 1 do local it = R.GetTrackMediaItem(tr, i); if R.GetMediaItemInfo_Value(it, 'D_POSITION') >= t0 - 1e-4 then l[#l + 1] = it end end; table.sort(l, function(a, b) return R.GetMediaItemInfo_Value(a, 'D_POSITION') < R.GetMediaItemInfo_Value(b, 'D_POSITION') end); return l end
    local function d() local t = {}; for _, it in ipairs(zone()) do t[#t + 1] = ('%.2f+%.2f'):format(model.row_of_time(R.GetMediaItemInfo_Value(it, 'D_POSITION'), lpb) - row, R.GetMediaItemInfo_Value(it, 'D_LENGTH') / (edit.row_time(row + 1, lpb, 0) - t0)) end; return table.concat(t, ' ') end
    edit.xfade.on = false; edit.beside = false
    edit.insert_note(tr, nil, lpb, row, 60, 100, 16, inst)      -- длинная (до 16 строк, но источник 1.36 с ≈ 11.6 строк)
    log('long: ' .. d())
    edit.insert_note(tr, nil, lpb, row + 4, 61, 100, 2, inst)   -- нота внутри — предыдущая рубится на 4
    log('note @+4 no shift: ' .. d() .. ' (expect first = 4.00 rows)')
    edit.beside = true
    edit.insert_note(tr, nil, lpb, row + 5, 62, 100, 2, inst)   -- Shift — рядом, вторая не тронута
    edit.beside = false
    log('shift note @+5: ' .. d())
    for _ = 1, 3 do edit.undo() end
    log('undo → ' .. #zone())
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
