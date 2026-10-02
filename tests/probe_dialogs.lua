-- probe_dialogs.lua — окна REAPER с «ReaScript»/«rror»/«jf_tracker» в заголовке → ExtState jf_tracker/probe
local arr = reaper.new_array({}, 256)
local n = reaper.JS_Window_ListAllTop and 0 or 0
local parts = {}
for _, pat in ipairs({ 'ReaScript', 'rror', 'jf_tracker', 'Script' }) do
  local cnt = reaper.JS_Window_ArrayFind(pat, false, arr)
  local t = arr.table()
  for i = 1, cnt do
    local hw = reaper.JS_Window_HandleFromAddress(t[i])
    parts[#parts + 1] = pat .. ':' .. reaper.JS_Window_GetTitle(hw) .. (reaper.JS_Window_IsVisible(hw) and '' or '(hidden)')
  end
end
reaper.SetExtState('jf_tracker', 'probe', 'dialogs=' .. #parts .. ' ' .. table.concat(parts, ' ; '), false)
