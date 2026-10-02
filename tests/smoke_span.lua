-- smoke_span.lua — S.open_file / E.insert_span / E.depot_span живьём → ExtState jf_tracker/smoke
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out = {}
local function log(s) out[#out + 1] = s end
local _, pname = R.EnumProjects(-1, '')
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
if (pname and pname ~= '') or not (table.concat(names, ','):find('A drums', 1, true) and table.concat(names, ','):find('B lanes', 1, true) and table.concat(names, ','):find('M synth', 1, true)) then log('REFUSED') else
  local ok, err = pcall(function()
    local model = dofile(DIR .. '/jf_tracker_model.lua')
    local edit = dofile(DIR .. '/jf_tracker_edit.lua'); edit.init(model)
    local SL = dofile(DIR .. '/jf_tracker_slicer.lua'); SL.init({ edit = edit, fit = function(x) return x end })
    local tr = R.GetTrack(0, 1)
    local tk = R.GetActiveTake(R.GetTrackMediaItem(tr, 0))
    local path = R.GetMediaSourceFileName(R.GetMediaItemTake_Source(tk), '')
    local n0 = R.CountTrackMediaItems(tr)
    log('open_file=' .. tostring(SL.open_file(path, tr)) .. ' len=' .. string.format('%.2f', SL.entry.len) .. ' env=' .. tostring(SL.env ~= nil))
    SL.sel = { a = 1.0, b = 1.5 }
    local a, b = SL.span()
    local it = edit.insert_span(tr, nil, 4, 48, SL.entry, a, b)
    local tk2 = it and R.GetActiveTake(it)
    log(('file span: item@%.3f len=%.3f offs=%.3f (expect 6.000/0.500/1.000)'):format(R.GetMediaItemInfo_Value(it, 'D_POSITION'), R.GetMediaItemInfo_Value(it, 'D_LENGTH'), R.GetMediaItemTakeInfo_Value(tk2, 'D_STARTOFFS')))
    -- выделение инструмента пула → депо
    local snap = model.build(4)
    local col = snap.cols[2]
    local e = col.pool[1]
    local d = edit.depot_span(tr, e, 0.1, 0.3)
    local lib = model.lib_pos()
    log(('pool span → depot: item@%.2f lib=%.2f len=%.3f name=%s'):format(R.GetMediaItemInfo_Value(d, 'D_POSITION'), lib or -1, R.GetMediaItemInfo_Value(d, 'D_LENGTH'), R.GetTakeName(R.GetActiveTake(d))))
    edit.undo(); edit.undo()
    log('after undo n=' .. R.CountTrackMediaItems(tr) .. ' (was ' .. n0 .. ')')
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
