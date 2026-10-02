local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local M = dofile(DIR .. '/jf_tracker_model.lua')
local out = {}
local ok, err = pcall(function()
  local snap = M.snapshot(4)
  for i, e in ipairs(snap.pool) do
    local pk = M.peaks(e, 100)
    local mx = 0
    if pk then for k = 1, pk.n do if pk.max[k] > mx then mx = pk.max[k] end end end
    local on = R.CountTakes(e.item) > 0 and R.GetMediaSourceFileName(e.src, '')
    out[#out + 1] = ('%02d %s len %.3f offs %.3f rate %.2f rgb %s mute %s sl %s pk %s n %s max %.3f tracks %s %s'):format(
      i, e.name, e.len, e.offs, e.rate, e.rgb and ('%.2f,%.2f,%.2f'):format(e.rgb[1], e.rgb[2], e.rgb[3]) or 'nil', tostring(e.muted),
      e.slices and #e.slices or '-', tostring(pk ~= nil), pk and pk.n or '-', mx, table.concat(e.tracks or {}, '/'), tostring(on):sub(-20))
  end
end)
if not ok then out[#out + 1] = 'ERR ' .. tostring(err) end
R.SetExtState('jf_tracker', 'probe', table.concat(out, ' | '), false)
