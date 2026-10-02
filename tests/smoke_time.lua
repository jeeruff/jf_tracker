-- smoke_time.lua — E.time_delete / E.time_insert в рамках региона → ExtState jf_tracker/smoke
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
    local tr = R.GetTrack(0, 0)   -- A drums: item на строках 24..32 (QN 6..8), регион 3 A = QN 4..8?
    local regs = model.regions(4)
    local function items()
      local t = {}
      for i = 0, R.CountTrackMediaItems(tr) - 1 do local it = R.GetTrackMediaItem(tr, i); t[#t + 1] = ('%.2f+%.2f'):format(R.GetMediaItemInfo_Value(it, 'D_POSITION'), R.GetMediaItemInfo_Value(it, 'D_LENGTH')) end
      return table.concat(t, ' ')
    end
    local env; for _, e in ipairs(model.track_envs(tr)) do if e.name == 'Volume' then env = e.env end end
    if not env then env = R.GetTrackEnvelope(tr, 0) end
    local function pts() if not env then return 'no env' end local t = {}; for i = 0, R.CountEnvelopePoints(env) - 1 do local _, tt = R.GetEnvelopePoint(env, i); t[#t + 1] = ('%.2f'):format(tt) end; return table.concat(t, ' ') end
    -- регион, содержащий QN 5 (строка 20)
    local t0 = R.TimeMap2_QNToTime(0, 5)
    local rg; for _, r in ipairs(regs) do if not r.lib and t0 >= r.pos and t0 < r.rgnend then rg = r end end
    log(('region %s [%.2f,%.2f) items: %s | env: %s'):format(rg and rg.name or '-', rg and rg.pos or -1, rg and rg.rgnend or -1, items(), pts()))
    local t1 = R.TimeMap2_QNToTime(0, 5.25)   -- одна строка при LPB 4
    edit.time_delete({ tr }, t0, t1, rg and rg.rgnend or 1e9)
    log('after delete 1 row @QN5: ' .. items() .. ' | env: ' .. pts())
    edit.time_insert({ tr }, t0, t1 - t0, rg and rg.rgnend or 1e9)
    log('after insert 1 row @QN5: ' .. items() .. ' | env: ' .. pts())
    edit.undo(); edit.undo()
    log('undo: ' .. items() .. ' | env: ' .. pts())
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
