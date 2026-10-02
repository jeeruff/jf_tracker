-- sandbox_regions.lua — добавить регионы-паттерны в песочницу (для матрицы).
-- Только в проекте песочницы (см. smoke_edit.lua).
local R = reaper
local _, pname = R.EnumProjects(-1, '')
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
if (pname and pname ~= '') or table.concat(names, ',') ~= 'A drums,B lanes,M synth,DEPOT' then
  R.SetExtState('jf_tracker', 'sandbox', 'REFUSED regions: not sandbox', false); return
end
R.Undo_BeginBlock2(0)
R.AddProjectMarker2(0, true, 0.0, 2.0, 'intro', 1, R.ColorToNative(200, 80, 80) | 0x1000000)
R.AddProjectMarker2(0, true, 2.0, 4.0, 'A', 2, 0)
R.AddProjectMarker2(0, true, 4.0, 6.0, 'B', 3, 0)
R.Undo_EndBlock2(0, 'jf_tracker sandbox regions', -1)
R.SetExtState('jf_tracker', 'sandbox', 'regions ok', false)
