local R = reaper
local out = {}
for id = 40000, 42700 do
  local t = R.kbd_getTextFromCmd(id, 0)
  if t and t:lower():find('zoom to selected item') then out[#out + 1] = id .. ':' .. t end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
