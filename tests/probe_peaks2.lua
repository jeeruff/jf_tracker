local R = reaper
local out = {}
local function log(s) out[#out + 1] = s end
local function try(src, npix, span, extra)
  local buf = R.new_array(npix * 3); buf.clear()
  local rv = R.PCM_Source_GetPeaks(src, npix / span, 0, 1, npix, extra, buf)
  return ('spl=%d'):format(rv & 0xfffff)
end
for ti = 0, 1 do
  local tr = R.GetTrack(0, ti)
  local it = R.GetTrackMediaItem(tr, 0)
  local tk = it and R.GetActiveTake(it)
  local src = tk and R.GetMediaItemTake_Source(tk)
  if src then
    local fn = R.GetMediaSourceFileName(src, '')
    local f = io.open(fn, 'rb'); local exists = f ~= nil; if f then f:close() end
    local slen, isqn = R.GetMediaSourceLength(src)
    local typ = R.GetMediaSourceType(src, '')
    local parent = R.GetMediaSourceParent(src)
    local b1 = 0; for _ = 1, 200 do if R.PCM_Source_BuildPeaks(src, 1) == 0 then break end; b1 = b1 + 1 end
    R.PCM_Source_BuildPeaks(src, 2)
    log(('t%d %s exists=%s type=%s parent=%s srclen=%.3f qn=%s build1steps=%d | e0:%s e115:%s big:%s'):format(ti, fn:match('[^/]+$') or fn, tostring(exists), typ, tostring(parent ~= nil), slen or -1, tostring(isqn), b1,
      try(src, 120, slen > 0 and slen or 1, 0), try(src, 120, slen > 0 and slen or 1, 115), try(src, 120, 100, 0)))
  end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
