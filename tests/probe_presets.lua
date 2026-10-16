-- probe_presets.lua — 16 окт: цепочка FX шаблона на другой трек (временные треки, nw.py lua dofile)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/')
local P = dofile(DIR .. '/jf_tracker_presets.lua')
local n = reaper.CountTracks(0)
reaper.InsertTrackAtIndex(n, false); reaper.InsertTrackAtIndex(n + 1, false)
local a, b = reaper.GetTrack(0, n), reaper.GetTrack(0, n + 1)
reaper.TrackFX_AddByName(a, 'ReaEQ (Cockos)', false, -1); reaper.TrackFX_AddByName(a, 'ReaComp (Cockos)', false, -1)
reaper.TrackFX_AddByName(b, 'ReaDelay (Cockos)', false, -1)
local it = reaper.AddMediaItemToTrack(b); reaper.SetMediaItemInfo_Value(it, 'D_LENGTH', 1)
local _, ta = reaper.GetTrackStateChunk(a, '', false)
local tpl = P.template_of(ta)
local _, tb = reaper.GetTrackStateChunk(b, '', false)
local nc, err = P.apply_fxchain(tb, tpl)
if nc then reaper.SetTrackStateChunk(b, nc, false) end
local names = {}
for i = 0, reaper.TrackFX_GetCount(b) - 1 do local _, nm = reaper.TrackFX_GetFXName(b, i, ''); names[#names + 1] = nm end
local res = ('err=%s fx=%s items=%d'):format(tostring(err), table.concat(names, ','), reaper.CountTrackMediaItems(b))
reaper.DeleteTrack(b); reaper.DeleteTrack(a)
return res
