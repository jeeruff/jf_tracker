local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local model = dofile(DIR .. '/jf_tracker_model.lua')
local out = {}
local snap = model.build(16)
for _, col in ipairs(snap.cols) do
  for _, lane in ipairs(col.lanes) do
    for _, sub in ipairs(lane.subs) do
      for r, cell in pairs(sub) do
        if cell.kind == 'audio' then out[#out + 1] = ('%s@%d rows=%d rows_f=%.2f start_f=%.2f'):format(col.name, r, cell.rows, cell.rows_f, cell.start_f) end
      end
    end
  end
end
table.sort(out)
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
