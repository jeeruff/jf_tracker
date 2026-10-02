-- smoke_poolpeaks.lua — пики инструментов пула (мини-волны в панели) → ExtState jf_tracker/smoke
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out = {}
local function log(s) out[#out + 1] = s end
local model = dofile(DIR .. '/jf_tracker_model.lua')
local ok, err = pcall(function()
  local snap = model.build(4)
  for _, col in ipairs(snap.cols) do
    for i, e in ipairs(col.pool) do
      local pk
      for _ = 1, 50 do pk = model.peaks(e, 120); if pk then break end end
      local mx = 0
      if pk then for k = 1, pk.n do mx = math.max(mx, math.abs(pk.max[k] or 0), math.abs(pk.min[k] or 0)) end end
      log(('%s/%d %s len=%.2f rate=%.2f offs=%.2f src=%s pk=%s max=%.3f'):format(col.name, i, e.name, e.len, e.rate, e.offs, tostring(e.src ~= nil), pk and pk.n or 'nil', mx))
    end
  end
end)
if not ok then log('ERR ' .. tostring(err)) end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
