-- probe_envaction.lua — найти действия удаления огибающей (только чтение) → ExtState jf_tracker/probe
local out = {}
for id = 40000, 42700 do
  local t = reaper.kbd_getTextFromCmd(id, 0)
  if t and t:lower():find('envelope', 1, true) and (t:lower():find('remove', 1, true) or t:lower():find('clear', 1, true)) then out[#out + 1] = id .. '=' .. t end
end
reaper.SetExtState('jf_tracker', 'probe', table.concat(out, ' | '):sub(1, 900), false)
