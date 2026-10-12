-- probe_tempo.lua — tempo-маркеры проекта (только чтение)
local out = {}
for i = 0, reaper.CountTempoTimeSigMarkers(0) - 1 do
  local _, t, m, b, bpm = reaper.GetTempoTimeSigMarker(0, i)
  out[#out + 1] = ('%d: t=%.4f bpm=%.1f'):format(i, t, bpm)
end
local it = reaper.GetTrackMediaItem(reaper.GetTrack(0, 0), 3)
local _, tm = reaper.GetSetMediaItemInfo_String(it, 'P_EXT:jf_tempo', '', false)
out[#out + 1] = 'jf_tempo=' .. tostring(tm) .. ' pos=' .. reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
reaper.SetExtState('jf_tracker', 'probe', table.concat(out, ' | '), false)
