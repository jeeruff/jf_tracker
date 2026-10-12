-- probe_cmds.lua — P_EXT:jf_cmds первого item трека 1 (только чтение)
local it = reaper.GetTrackMediaItem(reaper.GetTrack(0, 0), 0)
local _, cm = reaper.GetSetMediaItemInfo_String(it, 'P_EXT:jf_cmds', '', false)
reaper.SetExtState('jf_tracker', 'probe', 'jf_cmds=' .. tostring(cm), false)
