local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local model = dofile(DIR .. '/jf_tracker_model.lua')
local snap = model.build(16)
local out = { ('pool=%d shared=%s'):format(#snap.pool, tostring(snap.cols[1].pool == snap.cols[#snap.cols].pool)) }
for i, e in ipairs(snap.pool) do out[#out + 1] = ('%02d %s%s @%s'):format(i, e.depot and '*' or '', e.name, table.concat(e.tracks, ',')) end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
