-- sandbox_dspbig.lua — цепочка для проверки DSP big на треке A drums песочницы:
-- ReaEQ | ReaDelay + ReaVerbate (parallel) | Container { ReaComp + ReaGate (parallel), ReaXcomp }
-- Отказывается, если активный проект — не песочница (7 окт).
local _, pname = reaper.EnumProjects(-1, '')
local names = {}
for i = 0, reaper.CountTracks(0) - 1 do local _, nm = reaper.GetTrackName(reaper.GetTrack(0, i)); names[#names + 1] = nm end
if (pname and pname ~= '') or table.concat(names, ',') ~= 'A drums,B lanes,M synth,DEPOT' then
  reaper.SetExtState('jf_tracker', 'dbg', 'sandbox_dspbig: REFUSED, not a sandbox', false); return
end
local tr = reaper.GetTrack(0, 0)
while reaper.TrackFX_GetCount(tr) > 0 do reaper.TrackFX_Delete(tr, 0) end
reaper.TrackFX_AddByName(tr, 'ReaEQ', false, -1)
reaper.TrackFX_AddByName(tr, 'ReaDelay', false, -1)
local v = reaper.TrackFX_AddByName(tr, 'ReaVerbate', false, -1)
reaper.TrackFX_SetNamedConfigParm(tr, v, 'parallel', '1')
local c = reaper.TrackFX_AddByName(tr, 'Container', false, -1)
local N = reaper.TrackFX_GetCount(tr)
local function kid(k) return 0x2000000 + (k + 1) * (N + 1) + (c + 1) end
reaper.TrackFX_AddByName(tr, 'ReaComp', false, -1000 - kid(0))
reaper.TrackFX_AddByName(tr, 'ReaGate', false, -1000 - kid(1))
reaper.TrackFX_SetNamedConfigParm(tr, kid(1), 'parallel', '1')
reaper.TrackFX_AddByName(tr, 'ReaXcomp', false, -1000 - kid(2))
for i = 0, reaper.TrackFX_GetCount(tr) - 1 do reaper.TrackFX_Show(tr, i, 2) end
reaper.SetExtState('jf_tracker', 'dbg', 'sandbox_dspbig: ok, top ' .. reaper.TrackFX_GetCount(tr), false)
