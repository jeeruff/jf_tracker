-- sandbox_ai.lua — automation item на огибающей Volume трека A drums (песочница)
local R = reaper
local _, pname = R.EnumProjects(-1, '')
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
if (pname and pname ~= '') or not (table.concat(names, ','):find('A drums', 1, true) and table.concat(names, ','):find('B lanes', 1, true) and table.concat(names, ','):find('M synth', 1, true)) then R.SetExtState('jf_tracker', 'smoke', 'REFUSED', false); return end
local env = R.GetTrackEnvelopeByName(R.GetTrack(0, 0), 'Volume')
if not env then R.SetExtState('jf_tracker', 'smoke', 'no Volume env', false); return end
local n = R.CountAutomationItems(env)
if n == 0 then
  local t0 = R.TimeMap2_QNToTime(0, 8)
  local t1 = R.TimeMap2_QNToTime(0, 12)
  R.Undo_BeginBlock2(0)
  R.InsertAutomationItem(env, -1, t0, t1 - t0)
  R.Undo_EndBlock2(0, 'sandbox: automation item', -1)
  n = R.CountAutomationItems(env)
end
R.SetExtState('jf_tracker', 'smoke', 'ais=' .. n .. ' pos=' .. R.GetSetAutomationItemInfo(env, 0, 'D_POSITION', 0, false) .. ' len=' .. R.GetSetAutomationItemInfo(env, 0, 'D_LENGTH', 0, false), false)
