local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local model = dofile(DIR .. '/jf_tracker_model.lua')
local out = {}
local snap = model.build(16)
local e = snap.pool[1]
local pk
for _ = 1, 5 do pk = model.peaks(e, 64, true); if pk then break end end
if not pk then out[#out + 1] = 'pk=nil'
else
  local sp = pk.spec
  local t = {}
  for i = 1, 6 do local v = sp and sp[i] or -1; t[#t + 1] = ('%.0f'):format(v) end
  local mx, nz = 0, 0
  for i = 1, pk.n do local v = sp and sp[i] or 0; if v ~= 0 then nz = nz + 1 end; if math.abs(v) > mx then mx = math.abs(v) end end
  out[#out + 1] = ('n=%d spec=%s first=%s nonzero=%d max=%.0f'):format(pk.n, tostring(sp ~= nil), table.concat(t, ','), nz, mx)
  -- сырой вызов с 115 и mode bits
  local src = model.online_src(e.src)
  local buf = R.new_array(64 * 3); buf.clear()
  local rv = R.PCM_Source_GetPeaks(src, 64 / e.len, 0, 1, 64, 115, buf)
  local tb = buf.table()
  out[#out + 1] = ('raw rv=%d spl=%d mode=%d t[1]=%.3f t[65]=%.3f t[129]=%.0f t[130]=%.0f'):format(rv, rv & 0xfffff, (rv >> 20) & 0xf, tb[1] or 0, tb[65] or 0, tb[129] or 0, tb[130] or 0)
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
