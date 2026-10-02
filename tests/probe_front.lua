-- probe_front.lua — поднять окно jf_tracker на передний план (для снимка)
local arr = reaper.new_array({}, 16)
local n = reaper.JS_Window_ArrayFind('jf_tracker', true, arr)
if n > 0 then
  local hw = reaper.JS_Window_HandleFromAddress(arr.table()[1])
  reaper.JS_Window_SetForeground(hw)
end
reaper.SetExtState('jf_tracker', 'probe', 'front=' .. n, false)
