local R = reaper
local _, pname = R.EnumProjects(-1, '')
if pname and pname ~= '' then return end
R.OnStopButton()
local A = R.GetTrack(0, 0)
for f = 0, R.TrackFX_GetCount(A) - 1 do local _, n = R.TrackFX_GetFXName(A, f, ''); if n:find('Counter Modulator', 1, true) then
  R.SetExtState('jf_tracker', 'probe', ('counter out after play = %.3f (x100 steps = notes seen)'):format(R.TrackFX_GetParam(A, f, 0)), false) end end
