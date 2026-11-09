-- jf_tracker_viper_toggle.lua (9 ноя) — действие REAPER «jf_tracker: viper toggle» (для тулбара): трекер переключает
-- viper (как Cmd+F10 / :viper); трекер не запущен — запускается и сразу входит в viper. Подсветку кнопки ставит трекер.
local EXT = 'jf_tracker'
reaper.SetExtState(EXT, 'viper_req', tostring(reaper.time_precise()), false)
local hb = reaper.GetExtState(EXT, 'hb_t')
local alive = hb ~= '' and reaper.time_precise() - (tonumber(hb) or 0) < 2
if not alive then
  local dir = debug.getinfo(1, 'S').source:match('^@(.*[/\\])') or ''
  local id = reaper.AddRemoveReaScript(true, 0, dir .. 'jf_tracker.lua', false)
  if id and id > 0 then reaper.Main_OnCommand(id, 0) end
end
