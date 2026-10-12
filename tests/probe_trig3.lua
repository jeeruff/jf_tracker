local R = reaper
local _, pname = R.EnumProjects(-1, '')
if pname and pname ~= '' then R.SetExtState('jf_tracker', 'probe', 'REFUSED', false); return end
local out = {}
local A = R.GetTrack(0, 0)
for f = 0, R.TrackFX_GetCount(A) - 1 do local _, n = R.TrackFX_GetFXName(A, f, ''); out[#out + 1] = 'trk fx ' .. f .. ' ' .. n end
local it = R.GetTrackMediaItem(A, 0); local tk = R.GetActiveTake(it)
for f = 0, R.TakeFX_GetCount(tk) - 1 do local _, n = R.TakeFX_GetFXName(tk, f, ''); out[#out + 1] = 'take fx ' .. f .. ' ' .. n .. ' p0=' .. R.TakeFX_GetParam(tk, f, 0) end
R.SetExtState('jf_tracker', 'probe', table.concat(out, ' | '), false)
