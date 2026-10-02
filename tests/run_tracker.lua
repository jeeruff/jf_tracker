-- run_tracker.lua — запуск трекера с перехватом ошибки загрузки → ExtState jf_tracker/err_load
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
reaper.DeleteExtState('jf_tracker', 'err_load', false)
local ok, e = pcall(dofile, DIR .. '/jf_tracker.lua')
if not ok then reaper.SetExtState('jf_tracker', 'err_load', tostring(e), false) end
