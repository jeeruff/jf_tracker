-- probe_takeenv.lua — действия take-огибающих + создание pitch-огибающей на item песочницы
local R = reaper
local out = {}
for id = 41600, 41650 do
  local t = R.kbd_getTextFromCmd(id, 0) or ''
  if t:match('^Take: Toggle take .*envelope') or t:match('^Take: Toggle take .* envelope') then out[#out + 1] = id .. '=' .. t:gsub('^Take: Toggle take ', '') end
end
local _, pname = R.EnumProjects(-1, '')
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
if (pname == '' or pname == nil) and table.concat(names, ',') == 'A drums,B lanes,M synth,DEPOT' then
  local it = R.GetTrackMediaItem(R.GetTrack(0, 0), 0)
  local tk = R.GetActiveTake(it)
  local env = R.GetTakeEnvelopeByName(tk, 'Pitch')
  out[#out + 1] = 'pitch env before=' .. tostring(env ~= nil)
  if not env then
    R.SelectAllMediaItems(0, false); R.SetMediaItemSelected(it, true)
    local tid
    for id = 41600, 41650 do local t = R.kbd_getTextFromCmd(id, 0) or ''; if t:match('^Take: Toggle take pitch envelope') then tid = id end end
    if tid then R.Main_OnCommand(tid, 0) end
    env = R.GetTakeEnvelopeByName(tk, 'Pitch')
    out[#out + 1] = 'after toggle ' .. tostring(tid) .. ' env=' .. tostring(env ~= nil)
  end
  if env then
    local n = R.CountEnvelopePoints(env)
    local be = R.BR_EnvAlloc(env, false)
    local act, vis, _, _, _, _, mn, mx = R.BR_EnvGetProperties(be); R.BR_EnvFree(be, false)
    out[#out + 1] = ('points=%d active=%s vis=%s range %s..%s'):format(n, tostring(act), tostring(vis), tostring(mn), tostring(mx))
    local ok, v = R.Envelope_Evaluate(env, R.GetMediaItemInfo_Value(it, 'D_POSITION') + 0.1, 0, 0)
    out[#out + 1] = 'eval(abs time)=' .. tostring(v)
  end
end
R.SetExtState('jf_tracker', 'probe', table.concat(out, ' | '), false)
