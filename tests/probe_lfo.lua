-- probe_lfo.lua (15 окт): единицы lfo.speed при temposync. Трек 1, первый FX, параметр 1: LFO sin, sync,
-- speed=1, strength=1, dir=0; играем 2 с от 0, пишем значение параметра каждые ~10 мс → tests/shots/probe_lfo.txt
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/')
local out = io.open(DIR .. '/shots/probe_lfo.txt', 'w')
local tr = reaper.GetTrack(0, 1); local fx, p = 0, 1
local function cfg(k, v) reaper.TrackFX_SetNamedConfigParm(tr, fx, ('param.%d.%s'):format(p, k), v) end
local function get(k) local _, v = reaper.TrackFX_GetNamedConfigParm(tr, fx, ('param.%d.%s'):format(p, k)); return v end
local base = reaper.TrackFX_GetParamNormalized(tr, fx, p)
reaper.Undo_BeginBlock2(0)
cfg('mod.active', '1'); cfg('mod.baseline', '0.5'); cfg('lfo.active', '1'); cfg('lfo.shape', '0'); cfg('lfo.temposync', '1'); cfg('lfo.speed', '1'); cfg('lfo.strength', '1'); cfg('lfo.dir', '0'); cfg('lfo.phase', '0')
reaper.Undo_EndBlock2(0, 'probe lfo on', -1)
out:write(('readback: speed=%s sync=%s str=%s dir=%s phase=%s shape=%s baseline=%s bpm=%.1f\n'):format(get('lfo.speed'), get('lfo.temposync'), get('lfo.strength'), get('lfo.dir'), get('lfo.phase'), get('lfo.shape'), get('mod.baseline'), reaper.Master_GetTempo()))
reaper.SetEditCurPos(0, false, false); reaper.OnPlayButton()
local t0 = reaper.time_precise(); local last = -1
local function step()
  local t = reaper.time_precise() - t0
  if t - last >= 0.01 then last = t; out:write(('%.3f %.4f %.3f\n'):format(t, reaper.TrackFX_GetParamNormalized(tr, fx, p), reaper.GetPlayPosition())) end
  if t < 2.0 then return reaper.defer(step) end
  reaper.OnStopButton()
  reaper.Undo_BeginBlock2(0); cfg('lfo.active', '0'); cfg('mod.active', '0'); reaper.TrackFX_SetParamNormalized(tr, fx, p, base); reaper.Undo_EndBlock2(0, 'probe lfo off', -1)
  out:write('DONE\n'); out:close()
end
step()
