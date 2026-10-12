-- probe_counter.lua — песочница: Saxmand Counter Modulator на треке A; arg в ExtState probe_bus: шина триггеров (0 = bus 1, 15 = bus 16)
local R = reaper
local _, pname = R.EnumProjects(-1, '')
if pname and pname ~= '' then R.SetExtState('jf_tracker', 'probe', 'REFUSED', false); return end
local A = R.GetTrack(0, 0)
local cf = -1
for f = 0, R.TrackFX_GetCount(A) - 1 do local _, n = R.TrackFX_GetFXName(A, f, ''); if n:find('Counter Modulator', 1, true) then cf = f end end
if cf < 0 then cf = R.TrackFX_AddByName(A, 'Saxmand ReaPack/FX Modulator Linking/Counter Modulator.jsfx', false, -1) end
local bus = tonumber(R.GetExtState('jf_tracker', 'probe_bus')) or 15
for i = 0, R.CountTrackMediaItems(A) - 1 do
  local tk = R.GetActiveTake(R.GetTrackMediaItem(A, i))
  for f = 0, R.TakeFX_GetCount(tk) - 1 do R.TakeFX_SetParam(tk, f, 2, bus) end
end
R.TrackFX_SetParam(A, cf, 4, 100)    -- steps 100: счётчик не заворачивает
R.TrackFX_SetParam(A, cf, 8, 1); R.TrackFX_SetParam(A, cf, 8, 0)   -- reset
local _, nm = R.TrackFX_GetFXName(A, cf, '')
R.SetExtState('jf_tracker', 'probe', ('counter fx %d %s out=%.3f bus=%d'):format(cf, nm, R.TrackFX_GetParam(A, cf, 0), bus + 1), false)
R.SetMediaTrackInfo_Value(R.GetMasterTrack(0), 'D_VOL', 0)
R.SetEditCurPos(0, false, false); R.OnPlayButton()
