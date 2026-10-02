local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local model = dofile(DIR .. '/jf_tracker_model.lua')
local out = {}
local ok, err = pcall(function()
  local snap = model.build(16)
  local col = snap.cols[1]
  for _, lane in ipairs(col.lanes) do
    for si, sub in ipairs(lane.subs) do
      for r, cell in pairs(sub) do
        if cell.kind == 'audio' then
          local pk = model.peaks(cell, 200)
          local mx = 0
          if pk then for k = 1, pk.n do mx = math.max(mx, math.abs(pk.max[k] or 0), math.abs(pk.min[k] or 0)) end end
          out[#out + 1] = ('row %d sub %d rows=%d offs=%.3f len=%.3f rate=%.2f srclen=%.2f pk=%s max=%.3f'):format(r, si, cell.rows or 0, cell.offs, cell.len, cell.rate, R.GetMediaSourceLength(cell.src), pk and pk.n or 'nil', mx)
        end
      end
    end
  end
end)
if not ok then out[#out + 1] = 'ERR ' .. tostring(err) end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
