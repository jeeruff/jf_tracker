-- probe_loud.lua — только чтение: громкость мастера через Track_GetPeakInfo 1024 / 1025
local m = reaper.GetMasterTrack(0)
local p = {}
for _, ch in ipairs({ 0, 1, 1024, 1025 }) do
  p[#p + 1] = ('%d: info %.4f hold %.2f'):format(ch, reaper.Track_GetPeakInfo(m, ch), reaper.Track_GetPeakHoldDB(m, ch, false))
end
p[#p + 1] = 'play ' .. reaper.GetPlayState()
reaper.SetExtState('jf_tracker', 'probe', table.concat(p, ' | '), false)
