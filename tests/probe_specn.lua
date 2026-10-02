local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local M = dofile(DIR .. '/jf_tracker_model.lua')
local out = {}
local ok, err = pcall(function()
  local snap = M.snapshot(16)
  for ci, col in ipairs(snap.cols) do
    for li, lane in ipairs(col.lanes) do
      for si, sub in ipairs(lane.subs) do
        for row, cell in pairs(sub) do
          if cell.kind == 'audio' then
            local npix = math.max(2, math.floor((cell.rows_f or cell.rows or 1) * 22))
            local pk = M.peaks(cell, npix, true)
            local buf = R.new_array(npix * 3); buf.clear()
            local rv = R.PCM_Source_GetPeaks(M.online_src(cell.src), npix / (cell.len * cell.rate), cell.offs, 1, npix, 115, buf)
            out[#out + 1] = ('%s/%s r%d %s npix %d pk %s spec %s rv&bit %s srclen %.2f'):format(col.name, si, row, cell.name, npix, pk and pk.n or 'nil', pk and pk.spec and 'yes' or 'no', tostring(rv & 0x1000000 ~= 0), R.GetMediaSourceLength(cell.src) or -1)
          end
        end
      end
    end
  end
end)
if not ok then out[#out + 1] = 'ERR ' .. tostring(err) end
R.SetExtState('jf_tracker', 'probe', table.concat(out, ' | '), false)
