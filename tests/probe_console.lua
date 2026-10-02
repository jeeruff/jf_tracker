-- probe_console.lua — текст окна «ReaScript console output» → ExtState jf_tracker/probe
local arr = reaper.new_array({}, 16)
local n = reaper.JS_Window_ArrayFind('ReaScript console output', true, arr)
local parts = { 'console=' .. n }
for i = 1, n do
  local hw = reaper.JS_Window_HandleFromAddress(arr.table()[i])
  local ch = reaper.new_array({}, 64)
  local nc = reaper.JS_Window_ArrayAllChild(hw, ch)
  for j = 1, nc do
    local c = reaper.JS_Window_HandleFromAddress(ch.table()[j])
    local t = reaper.JS_Window_GetTitle(c)
    if t and #t > 5 then parts[#parts + 1] = t:sub(-600) end
  end
end
local n2 = reaper.JS_Window_ArrayFind('jf_tracker', true, arr)
parts[#parts + 1] = 'trackers=' .. n2
reaper.SetExtState('jf_tracker', 'probe', table.concat(parts, ' || '), false)
