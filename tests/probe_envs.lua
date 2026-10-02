local R = reaper
local out = {}
for ti = 0, R.CountTracks(0) - 1 do
  local tr = R.GetTrack(0, ti); local _, n = R.GetTrackName(tr)
  local t = {}
  for i = 0, R.CountTrackEnvelopes(tr) - 1 do local e = R.GetTrackEnvelope(tr, i); local _, en = R.GetEnvelopeName(e, ''); t[#t + 1] = en .. ':' .. R.CountEnvelopePoints(e) end
  out[#out + 1] = n .. ' [' .. table.concat(t, ',') .. ']'
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
