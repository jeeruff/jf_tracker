-- probe_fxcache.lua — кэш цепочек FX модели: первый проход / повтор после GC (только чтение)
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local M = dofile(DIR .. '/jf_tracker_model.lua')
local R = reaper
local function pass()
  M.bprof = { envs = 0, pool = 0, mods = 0, fx = 0 }
  local t = R.time_precise()
  for i = 0, R.CountTracks(0) - 1 do M.track_fx(R.GetTrack(0, i)) end
  return (R.time_precise() - t) * 1000, M.bprof.fxmiss or 0, M.bprof.fxhit or 0
end
local a, am = pass()
collectgarbage(); collectgarbage()
local b, bm, bh = pass()
R.SetExtState('jf_tracker', 'probe', ('cold %.2f ms miss %d | after GC %.2f ms miss %d hit %d'):format(a, am, b, bm, bh), false)
