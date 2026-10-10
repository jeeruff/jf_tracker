-- sandbox_close.lua — закрыть вкладки-песочницы без вопроса о сохранении (10 окт).
-- Песочница = проект без файла, в треках есть B lanes, M synth и DEPOT. Остальные
-- вкладки не трогаются. Приём BuyOne: открыть пустой проект в этой вкладке
-- с noprompt: (вопроса нет), потом закрыть вкладку. Пустой проект — tests/empty.RPP.
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local EMPTY = DIR .. '/tests/empty.RPP'
local closed, i = {}, 0
local list = {}
while true do
  local p, fn = reaper.EnumProjects(i)
  if not p then break end
  local has = {}
  for t = 0, reaper.CountTracks(p) - 1 do local _, n = reaper.GetTrackName(reaper.GetTrack(p, t)); has[n] = true end
  if (fn or '') == '' and has['B lanes'] and has['M synth'] and has['DEPOT'] then list[#list + 1] = { p = p, n = i + 1 } end
  i = i + 1
end
for k = #list, 1, -1 do
  reaper.SelectProjectInstance(list[k].p)
  reaper.Main_openProject('noprompt:' .. EMPTY)
  reaper.Main_OnCommand(40860, 0)
  closed[#closed + 1] = list[k].n
end
reaper.SetExtState('jf_tracker', 'sandbox', 'closed tabs ' .. table.concat(closed, ','), false)
reaper.defer(function() end)
