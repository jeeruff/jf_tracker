-- smoke_env.lua — правка огибающей живьём → ExtState jf_tracker/smoke
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
local edit = dofile(DIR .. '/jf_tracker_edit.lua')
edit.init(model)
local ok, err = pcall(function()
  local envs = model.track_envs(R.GetTrack(0, 0))
  log('envs=' .. #envs .. (envs[1] and (' ' .. envs[1].name .. ' key=' .. envs[1].key .. (' %.2f..%.2f'):format(envs[1].min, envs[1].max)) or ''))
  local e = envs[1]; if not e then return end
  local n0 = R.CountEnvelopePoints(e.env)
  edit.env_set(e, 3.0, 0.25, 0.05)
  local n1 = R.CountEnvelopePoints(e.env)
  local _, v = R.Envelope_Evaluate(e.env, 3.0, 0, 0)
  log(('set 0.25@3.0: points %d→%d value=%.3f (min %.2f max %.2f)'):format(n0, n1, v, e.min, e.max))
  edit.env_nudge(e, 3.0, 0.25, 0.05)
  local _, v2 = R.Envelope_Evaluate(e.env, 3.0, 0, 0)
  log(('nudge +0.25: value=%.3f points=%d'):format(v2, R.CountEnvelopePoints(e.env)))
  log('del=' .. tostring(edit.env_del(e, 3.0, 0.05)) .. ' points=' .. R.CountEnvelopePoints(e.env))
  log('undo=' .. tostring(R.Undo_CanUndo2(0)))
end)
if not ok then log('ERR ' .. tostring(err)) end
done()
