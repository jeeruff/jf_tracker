local keys = { 'st', 'mx', 'cmd', 'hb', 'owner' }
local parts = {}
for _, k in ipairs(keys) do parts[#parts + 1] = k .. '=' .. reaper.GetExtState('jf_tracker', k):sub(1, 60) end
reaper.SetExtState('jf_tracker', 'probe', table.concat(parts, ' | '), false)
