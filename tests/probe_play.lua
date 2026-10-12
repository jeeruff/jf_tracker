-- probe_play.lua — песочница: мастер в 0, воспроизведение с начала
local _, pname = reaper.EnumProjects(-1, '')
if pname and pname ~= '' then return end
reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(0), 'D_VOL', 0)
reaper.SetEditCurPos(0, false, false); reaper.OnPlayButton()
