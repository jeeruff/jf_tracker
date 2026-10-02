local R = reaper
local out = {}
for i = 0, 5 do
  local ok, a, b, c, d, e, f = pcall(R.MIDI_GetRecentInputEvent, i)
  out[#out + 1] = ('%d: ok=%s %s %s %s %s %s %s'):format(i, tostring(ok), tostring(a), b and #tostring(b) or '-', tostring(c), tostring(d), tostring(e), tostring(f))
  if not ok or a == 0 then break end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
