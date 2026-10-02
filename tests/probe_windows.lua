-- probe_windows.lua — сколько окон jf_tracker открыто (js_ReaScriptAPI) → ExtState jf_tracker/probe
local arr = reaper.new_array({}, 64)
local n = reaper.JS_Window_ArrayFind('jf_tracker', true, arr)
local t = arr.table()
local parts = {}
for i = 1, n do
  local hw = reaper.JS_Window_HandleFromAddress(t[i])
  local ok, l, tp, r, b = reaper.JS_Window_GetRect(hw)
  parts[#parts + 1] = string.format('%s[%d,%d %dx%d vis=%s]', reaper.JS_Window_GetTitle(hw), l, tp, r - l, b - tp, tostring(reaper.JS_Window_IsVisible(hw)))
end
reaper.SetExtState('jf_tracker', 'probe', ('windows=%d %s'):format(n, table.concat(parts, ' ')), false)
