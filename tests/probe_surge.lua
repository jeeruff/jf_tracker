-- probe_surge.lua — 16 окт: патч Surge через чанк трека на временном треке (nw.py lua dofile)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/')
local S = dofile(DIR .. '/jf_tracker_surge.lua')
local n = reaper.CountTracks(0)
reaper.InsertTrackAtIndex(n, false)
local tr = reaper.GetTrack(0, n)
reaper.TrackFX_AddByName(tr, 'Surge XT (Surge Synth Team)', false, -1)
local f = io.open('/Library/Application Support/Surge XT/patches_factory/Basses/Attacky.fxp', 'rb'); local fxp = f:read('*a'); f:close()
local ch = S.fxp_chunk(fxp)
local _, tc = reaper.GetTrackStateChunk(tr, '', false)
local nc = S.patch_track_chunk(tc, 1, ch)
local res = 'chunk ' .. tostring(ch and #ch) .. ' new ' .. tostring(nc and #nc)
if nc then reaper.SetTrackStateChunk(tr, nc, false) end
local _, tc2 = reaper.GetTrackStateChunk(tr, '', false)
local blob = {}
local inb, skip = false, 0
for l in tc2:gmatch('[^\n]+') do
  if l:match('^%s*<VST ') then inb = true; skip = 1 elseif inb and l:match('^%s*>') then inb = false
  elseif inb then if skip > 0 then skip = skip - 1 else blob[#blob + 1] = S.b64dec(l) end end
end
res = res .. ' name after: ' .. tostring(S.patch_name(table.concat(blob))) .. ' fx=' .. reaper.TrackFX_GetCount(tr)
reaper.DeleteTrack(tr)
return res
