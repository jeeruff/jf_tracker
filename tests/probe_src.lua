local R = reaper
local out = {}
for ti = 0, 2 do
  local tr = R.GetTrack(0, ti)
  for i = 0, R.CountTrackMediaItems(tr) - 1 do
    local tk = R.GetActiveTake(R.GetTrackMediaItem(tr, i))
    local src = tk and R.GetMediaItemTake_Source(tk)
    if src and not R.TakeIsMIDI(tk) then
      local fn = R.GetMediaSourceFileName(src, '')
      local f = io.open(fn, 'rb'); local sz = f and f:seek('end') or -1; if f then f:close() end
      out[#out + 1] = ('t%d/%d %s size=%d len=%.3f'):format(ti, i, fn, sz, R.GetMediaSourceLength(src) or -1)
    end
  end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
