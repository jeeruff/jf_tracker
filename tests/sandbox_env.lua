-- sandbox_env.lua — огибающая громкости с точками на треке A (только в песочнице)
local R = reaper
local _, pname = R.EnumProjects(-1, '')
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
if (pname and pname ~= '') or table.concat(names, ',') ~= 'A drums,B lanes,M synth,DEPOT' then
  R.SetExtState('jf_tracker', 'sandbox', 'REFUSED env: not sandbox', false); return
end
R.Undo_BeginBlock2(0)
local tr = R.GetTrack(0, 0)
R.SetOnlyTrackSelected(tr)
R.Main_OnCommand(40406, 0)              -- Track: Toggle track volume envelope visible
local env = R.GetTrackEnvelopeByName(tr, 'Volume')
if env then
  R.InsertEnvelopePoint(env, 0.5, 0.5, 0, 0, false, true)
  R.InsertEnvelopePoint(env, 1.5, 1.0, 0, 0, false, true)
  R.InsertEnvelopePoint(env, 2.5, 0.25, 0, 0, false, true)
  R.Envelope_SortPoints(env)
end
R.Undo_EndBlock2(0, 'jf_tracker sandbox env', -1)
R.SetExtState('jf_tracker', 'sandbox', env and ('env ok points=' .. R.CountEnvelopePoints(env)) or 'env MISSING', false)
