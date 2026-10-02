local R = reaper
local out = {}
local function log(s) out[#out + 1] = s end
local tr = R.GetTrack(0, 0)
for i = 0, R.CountTrackMediaItems(tr) - 1 do
  local it = R.GetTrackMediaItem(tr, i)
  local tk = R.GetActiveTake(it)
  local src = tk and R.GetMediaItemTake_Source(tk)
  if src then
    local fn = R.GetMediaSourceFileName(src, '')
    local nch = R.GetMediaSourceNumChannels(src)
    local len = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
    local b0 = R.PCM_Source_BuildPeaks(src, 0)
    local res = {}
    for _, p in ipairs({ { 120, len, 1 }, { 120, len, 2 }, { 50, len, 1 }, { 120, R.GetMediaSourceLength(src), 1 } }) do
      local npix, span, ch = p[1], p[2], p[3]
      local buf = R.new_array(npix * ch * 3); buf.clear()
      local rv = R.PCM_Source_GetPeaks(src, npix / span, 0, ch, npix, 0, buf)
      res[#res + 1] = ('n%d/s%.2f/c%d→spl=%d mode=%d'):format(npix, span, ch, rv & 0xfffff, (rv >> 20) & 0xf)
    end
    log(('%s nch=%d len=%.2f build0=%d %s'):format(fn:match('[^/]+$') or fn, nch, len, b0, table.concat(res, ' ')))
  end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
