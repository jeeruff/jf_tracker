-- smoke_ramp.lua — E.env_ramp живьём на огибающей Volume трека A drums → ExtState jf_tracker/smoke
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out = {}
local function log(s) out[#out + 1] = s end
local function done() R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false) end
local _, pname = R.EnumProjects(-1, '')
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
if (pname and pname ~= '') or not (table.concat(names, ','):find('A drums', 1, true) and table.concat(names, ','):find('B lanes', 1, true) and table.concat(names, ','):find('M synth', 1, true)) then log('REFUSED'); done(); return end
local model = dofile(DIR .. '/jf_tracker_model.lua')
local edit = dofile(DIR .. '/jf_tracker_edit.lua'); edit.init(model)
local ok, err = pcall(function()
  local tr = R.GetTrack(0, 0)
  local envs = model.track_envs(tr)
  local e
  for _, x in ipairs(envs) do if x.name == 'Volume' then e = x end end
  if not e then log('no Volume env'); return end
  local lpb = 4
  local function pts()
    local t = {}
    for i = 0, R.CountEnvelopePoints(e.env) - 1 do
      local _, pt, v = R.GetEnvelopePoint(e.env, i)
      t[#t + 1] = ('%.2f:%.2f'):format(pt, (v - e.min) / (e.max - e.min))
    end
    return #t, table.concat(t, ' ')
  end
  local n0, s0 = pts(); log('before n=' .. n0 .. ' ' .. s0)
  -- пандус из строки 40 к max за 1 бит (4 строки) — как `/` в INSERT
  local t0, t1 = edit.row_time(40, lpb, 0), edit.row_time(44, lpb, 0)
  local v0 = edit.env_value(e, t0)
  edit.env_ramp(e, t0, t1, nil, 1, (edit.row_time(41, lpb, 0) - t0) / 2)
  local n1, s1 = pts(); log(('ramp/ v0=%.2f n=%d %s'):format(v0, n1, s1))
  local mid = edit.env_value(e, (t0 + t1) / 2)
  log(('mid=%.2f expect~%.2f'):format(mid, (v0 + 1) / 2))
  -- спад из 44 к 0 за 2 бита, затем откат обоих
  edit.env_ramp(e, t1, edit.row_time(52, lpb, 0), nil, 0, 0.01)
  local n2, s2 = pts(); log('ramp\\ n=' .. n2)
  log(('end=%.2f'):format(edit.env_value(e, edit.row_time(52, lpb, 0))))
  edit.undo(); edit.undo()
  local n3 = pts(); log('after undo n=' .. n3 .. (n3 == n0 and ' OK' or ' MISMATCH'))
end)
if not ok then log('ERR ' .. tostring(err)) end
done()
