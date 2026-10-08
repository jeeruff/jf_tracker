-- probe_fxkey.lua — цена ключа кэша FX и тождество MediaTrack* (только чтение)
local R = reaper
local n = R.CountTracks(0)
local t0 = R.time_precise()
local calls, nfx = 0, 0
for i = 0, n - 1 do
  local tr = R.GetTrack(0, i)
  local c = R.TrackFX_GetCount(tr); calls = calls + 1
  for fx = 0, c - 1 do
    nfx = nfx + 1
    R.TrackFX_GetFXGUID(tr, fx); R.TrackFX_GetEnabled(tr, fx); R.TrackFX_GetNamedConfigParm(tr, fx, 'container_count'); calls = calls + 3
  end
end
local t1 = R.time_precise()
for i = 0, n - 1 do local tr = R.GetTrack(0, i); for fx = 0, R.TrackFX_GetCount(tr) - 1 do R.TrackFX_GetFXGUID(tr, fx) end end
local t2 = R.time_precise()
for i = 0, n - 1 do local tr = R.GetTrack(0, i); for fx = 0, R.TrackFX_GetCount(tr) - 1 do R.TrackFX_GetNamedConfigParm(tr, fx, 'container_count') end end
local t3 = R.time_precise()
local wave = 0
for i = 0, n - 1 do local tr = R.GetTrack(0, i); for fx = 0, R.TrackFX_GetCount(tr) - 1 do R.TrackFX_GetNamedConfigParm(tr, fx, 'FILE0'); wave = wave + 1 end end
local t4 = R.time_precise()
local a, b = R.GetTrack(0, 0), R.GetTrack(0, 0)
local tk = {}; tk[a] = 1
local chunk = 0
local t5 = R.time_precise()
for i = 0, n - 1 do local tr = R.GetTrack(0, i); local _, s = R.GetTrackStateChunk(tr, '', false); chunk = chunk + #s end
local t6 = R.time_precise()
R.SetExtState('jf_tracker', 'probe', ('tracks %d fx %d calls %d key %.2f ms | guid %.2f | ccount %.2f | file0 %.2f | same=%s rawequal=%s tablehit=%s type=%s | chunks %.2f ms %d B'):format(
  n, nfx, calls, (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000, (t4 - t3) * 1000, tostring(a == b), tostring(rawequal(a, b)), tostring(tk[b] ~= nil), type(a), (t6 - t5) * 1000, chunk), false)
