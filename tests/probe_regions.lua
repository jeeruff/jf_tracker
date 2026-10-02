-- probe_regions.lua — что видит API регионов → ExtState jf_tracker/probe
local R = reaper
local _, nm, nr = R.CountProjectMarkers(0)
local parts = { ('markers=%d regions=%d'):format(nm, nr) }
local i = 0
while true do
  local ret, isrgn, pos, rgnend, name, idx, color = R.EnumProjectMarkers3(0, i)
  if not ret or ret == 0 then break end
  parts[#parts + 1] = ('[%d %s %.2f-%.2f %s #%d]'):format(i, tostring(isrgn), pos, rgnend or -1, tostring(name), idx)
  i = i + 1
  if i > 20 then break end
end
parts[#parts + 1] = 'add=' .. tostring(R.AddProjectMarker2(0, true, 6.0, 8.0, 'probe', -1, 0))
local _, nm2, nr2 = R.CountProjectMarkers(0)
parts[#parts + 1] = ('after markers=%d regions=%d'):format(nm2, nr2)
R.SetExtState('jf_tracker', 'probe', table.concat(parts, ' '), false)
