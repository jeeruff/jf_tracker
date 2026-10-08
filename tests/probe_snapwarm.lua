-- probe_snapwarm.lua — пересборка снимка: холодная / тёплая, части (только чтение)
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local M = dofile(DIR .. '/jf_tracker_model.lua')
local R = reaper
local out = {}
for k = 1, 3 do
  M.invalidate()
  local t = R.time_precise()
  local ok, err = pcall(M.snapshot, 4)
  local b = M.bprof or {}
  out[#out + 1] = ok and ('%.1f ms [env %.1f pool %.1f mod %.1f fx %.1f %d/%d]'):format((R.time_precise() - t) * 1000, (b.envs or 0) * 1000, (b.pool or 0) * 1000, (b.mods or 0) * 1000, (b.fx or 0) * 1000, b.fxmiss or 0, (b.fxmiss or 0) + (b.fxhit or 0)) or ('ERR ' .. tostring(err))
end
R.SetExtState('jf_tracker', 'probe', table.concat(out, ' | '), false)
