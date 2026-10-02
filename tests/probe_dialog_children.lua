-- probe_dialog_children.lua — диалоги ReaScript и их кнопки → ExtState jf_tracker/probe
local parts = {}
local arr = reaper.new_array({}, 64)
local n = reaper.JS_Window_ArrayFind('ReaScript task control', true, arr)
parts[#parts + 1] = 'taskctl=' .. n
for i = 1, n do
  local hw = reaper.JS_Window_HandleFromAddress(arr.table()[i])
  local ch = reaper.new_array({}, 128)
  local nc = reaper.JS_Window_ArrayAllChild(hw, ch)
  for j = 1, nc do
    local c = reaper.JS_Window_HandleFromAddress(ch.table()[j])
    local t = reaper.JS_Window_GetTitle(c)
    if t ~= '' then parts[#parts + 1] = ('[%s id=%d]'):format(t:sub(1, 40), reaper.JS_Window_GetLongPtr and 0 or (reaper.JS_Window_GetLong(c, 'ID') or 0)) end
  end
end
local n2 = reaper.JS_Window_ArrayFind('jf_tracker', true, arr)
parts[#parts + 1] = 'trackers=' .. n2
reaper.SetExtState('jf_tracker', 'probe', table.concat(parts, ' '), false)
