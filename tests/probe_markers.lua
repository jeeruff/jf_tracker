-- probe_markers.lua — список регионов и маркеров проекта (только чтение) → ExtState jf_tracker/probe
local out = {}
local i = 0
while true do
  local ret, isrgn, pos, rgnend, name, idx = reaper.EnumProjectMarkers3(0, i)
  if not ret or ret == 0 then break end
  out[#out + 1] = (isrgn and ('R%d[%.2f-%.2f]'):format(idx, pos, rgnend) or ('M%d@%.2f'):format(idx, pos)) .. (name ~= '' and (' ' .. name) or '')
  i = i + 1
end
local undo = reaper.Undo_CanUndo2(0) or ''
reaper.SetExtState('jf_tracker', 'probe', (table.concat(out, ' | ') .. ' || last undo: ' .. undo):sub(1, 950), false)
