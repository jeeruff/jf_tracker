-- smoke_items.lua — рамки items и automation items в модели (песочница) → ExtState jf_tracker/smoke
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out = {}
local function log(s) out[#out + 1] = s end
local _, pname = R.EnumProjects(-1, '')
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
if (pname and pname ~= '') or not (table.concat(names, ','):find('A drums', 1, true) and table.concat(names, ','):find('B lanes', 1, true) and table.concat(names, ','):find('M synth', 1, true)) then log('REFUSED') else
  local model = dofile(DIR .. '/jf_tracker_model.lua')
  local ok, err = pcall(function()
    local snap = model.build(4)
    for _, col in ipairs(snap.cols) do
      for li, lane in ipairs(col.lanes) do
        for _, it in ipairs(lane.items) do
          log(('%s/%d %s r%.1f-%.1f si=%s%s'):format(col.name, li, it.midi and 'midi' or 'audio', it.r0, it.r1, tostring(it.si), it.sel and ' sel' or ''))
        end
      end
      for _, e in ipairs(col.envs or {}) do
        for _, ai in ipairs(e.ais) do log(('%s env %s AI r%.1f-%.1f key=%s'):format(col.name, e.name, ai.r0, ai.r1, e.ai_key)) end
      end
    end
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
