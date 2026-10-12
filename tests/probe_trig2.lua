-- probe_trig2.lua — часть 2: стоп, счётчики приёмника на треке A
local R = reaper
local _, pname = R.EnumProjects(-1, '')
if pname and pname ~= '' then R.SetExtState('jf_tracker', 'probe', 'REFUSED', false); return end
R.OnStopButton()
local A = R.GetTrack(0, 0)
local fx = -1
for f = 0, R.TrackFX_GetCount(A) - 1 do local _, n = R.TrackFX_GetFXName(A, f, ''); if n:find('count note-ons', 1, true) then fx = f end end
local v = {}
for p = 0, 4 do v[#v + 1] = ('%g'):format((R.TrackFX_GetParam(A, fx, p))) end
local starts = {}
for i = 0, math.min(5, R.CountTrackMediaItems(A) - 1) do starts[#starts + 1] = ('%.2f'):format(R.GetMediaItemInfo_Value(R.GetTrackMediaItem(A, i), 'D_POSITION')) end
R.SetExtState('jf_tracker', 'probe', 'bus1 bus16 last any blocks = ' .. table.concat(v, ' ') .. ' | item starts ' .. table.concat(starts, ' '), false)
