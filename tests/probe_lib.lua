-- probe_lib.lua — только чтение: треки проекта, трек LIB, его items (лейн, имя, jf_home, позиция)
local R = reaper
local out = {}
local _, pn = R.EnumProjects(-1, '')
out[#out + 1] = 'proj=' .. tostring(pn) .. ' tracks=' .. R.CountTracks(0)
for i = 0, R.CountTracks(0) - 1 do
  local tr = R.GetTrack(0, i)
  local _, nm = R.GetTrackName(tr)
  local s = ('T%d %s items=%d lanes=%d'):format(i + 1, nm, R.CountTrackMediaItems(tr), R.GetMediaTrackInfo_Value(tr, 'I_NUMFIXEDLANES'))
  if nm == 'LIB' or nm == 'DEPOT' then
    for k = 0, math.min(12, R.CountTrackMediaItems(tr)) - 1 do
      local it = R.GetTrackMediaItem(tr, k)
      local tk = R.GetActiveTake(it)
      local _, home = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_home', '', false)
      s = s .. (' [%s lane%d pos%.2f home=%s]'):format(tk and R.GetTakeName(tk) or '?', R.GetMediaItemInfo_Value(it, 'I_FIXEDLANE'), R.GetMediaItemInfo_Value(it, 'D_POSITION'), home:sub(1, 8))
    end
  end
  out[#out + 1] = s
end
R.SetExtState('jf_tracker', 'probe', table.concat(out, ' | '), false)
R.defer(function() end)
