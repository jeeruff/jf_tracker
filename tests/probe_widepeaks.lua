local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local model = dofile(DIR .. '/jf_tracker_model.lua')
local out = {}
local snap = model.build(16)
local e = snap.cols[1].pool[1]
for _, n in ipairs({ 120, 600, 1300, 2600 }) do
  local pk
  for _ = 1, 3 do pk = model.peaks(e, n); if pk then break end end
  local mx = 0
  if pk then for k = 1, pk.n do mx = math.max(mx, math.abs(pk.max[k] or 0)) end end
  out[#out + 1] = ('n=%d pk=%s max=%.3f'):format(n, pk and pk.n or 'nil', mx)
end
R.SetExtState('jf_tracker', 'smoke', e.name .. ' len=' .. e.len .. ' | ' .. table.concat(out, ' | '), false)
