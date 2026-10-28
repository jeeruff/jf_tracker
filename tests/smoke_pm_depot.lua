-- smoke_pm_depot.lua — вкладка pm браузера, депо после =LIB, drop → ExtState jf_tracker/smoke
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
    local B = dofile(DIR .. '/jf_tracker_browser.lua')
    B.init({ fit = function(s) return s end }, os.getenv('HOME') .. '/samples')
    local t0 = R.time_precise()
    B.set_mode('pm')
    log(('pm: %d projects in %.2fs; first: %s'):format(#B.entries, R.time_precise() - t0, B.entries[1] and B.describe(1):sub(1, 90) or '-'))
    -- депо на треке A drums после =LIB
    local tr = R.GetTrack(0, 0)
    local n0 = R.CountTrackMediaItems(tr)
    local lib0 = nil
    local sample = B.entries[1] and B.pm_preview(B.entries[1])
    if not sample then
      -- любой wav из песочницы: источник первого аудио-item A drums
      local tk = R.GetActiveTake(R.GetTrackMediaItem(tr, 0)); sample = R.GetMediaSourceFileName(R.GetMediaItemTake_Source(tk), '')
    end
    local it = edit.depot_add(sample, tr)
    local lib1 = nil
    log(('depot_add: lib before=%s after=%.2f item@%.2f n=%d→%d'):format(tostring(lib0), lib1 or -1, it and R.GetMediaItemInfo_Value(it, 'D_POSITION') or -1, n0, R.CountTrackMediaItems(tr)))
    local pool = model.track_pool(tr, nil, lib1)
    local nd = 0; for _, e in ipairs(pool) do if e.depot then nd = nd + 1 end end
    log(('pool=%d lib-marked=%d'):format(#pool, nd))
    -- drop файла в строку 48 трека A drums
    local d = edit.drop(tr, nil, 4, 48, sample)
    log(('drop: item@%.3f expect %.3f'):format(d and R.GetMediaItemInfo_Value(d, 'D_POSITION') or -1, R.TimeMap2_QNToTime(0, 12)))
    edit.undo(); edit.undo(); if not lib0 then edit.undo() end
    log(('after undo n=%d lib=%s'):format(R.CountTrackMediaItems(tr), tostring(nil)))
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
