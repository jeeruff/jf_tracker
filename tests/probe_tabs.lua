-- probe_tabs.lua — список вкладок проектов: номер, файл, треки (только чтение)
local out, i = {}, 0
local cur = reaper.EnumProjects(-1)
while true do
  local p, fn = reaper.EnumProjects(i)
  if not p then break end
  local names = {}
  for t = 0, reaper.CountTracks(p) - 1 do local _, n = reaper.GetTrackName(reaper.GetTrack(p, t)); names[#names + 1] = n end
  out[#out + 1] = ('%d%s file=[%s] tracks=%s'):format(i + 1, p == cur and '*' or '', fn or '', table.concat(names, ','):sub(1, 80))
  i = i + 1
end
reaper.SetExtState('jf_tracker', 'probe', table.concat(out, ' | '), false)
reaper.defer(function() end)
