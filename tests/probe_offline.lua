local R = reaper
local out = {}
local tr = R.GetTrack(0, 0)
for i = 0, R.CountTrackMediaItems(tr) - 1 do
  local it = R.GetTrackMediaItem(tr, i); local tk = R.GetActiveTake(it)
  local src = tk and R.GetMediaItemTake_Source(tk)
  if src then
    local fn = R.GetMediaSourceFileName(src, '')
    local online = R.CF_GetMediaSourceOnline and R.CF_GetMediaSourceOnline(src)
    out[#out + 1] = ('%s online=%s len=%.2f mute=%d'):format(fn:match('[^/]+$') or fn, tostring(online), R.GetMediaSourceLength(src), R.GetMediaItemInfo_Value(it, 'B_MUTE'))
  end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
