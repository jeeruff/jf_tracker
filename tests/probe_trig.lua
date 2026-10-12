-- probe_trig.lua — песочница: take FX триггер → MIDI-шина 16 → приёмник на треке;
-- и амплитуда / baseline у экземпляров пула AI (степпер без MIDI). Часть 1 из 2 (play).
local R = reaper
local out = {}
local function log(s) out[#out + 1] = s end
local function done() R.SetExtState('jf_tracker', 'probe', table.concat(out, ' | '), false) end
local _, pname = R.EnumProjects(-1, '')
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
if (pname and pname ~= '') or not table.concat(names, ','):find('B lanes', 1, true) then log('REFUSED'); done(); return end
local ok, err = pcall(function()
  R.SetMediaTrackInfo_Value(R.GetMasterTrack(0), 'D_VOL', 0)      -- песочница молчит (FX считают)
  local A = R.GetTrack(0, 0)
  R.TrackFX_AddByName(A, 'jf_probe_midibus', false, -1)
  local n = 0
  for i = 0, R.CountTrackMediaItems(A) - 1 do
    local it = R.GetTrackMediaItem(A, i)
    local tk = R.GetActiveTake(it)
    if tk and not R.TakeIsMIDI(tk) and n < 4 then
      local fx = R.TakeFX_AddByName(tk, 'jf_tracker_trig', -1)
      if fx >= 0 then n = n + 1; R.TakeFX_SetParam(tk, fx, 0, 60 + n) end
    end
  end
  log('trig on items=' .. n)
  -- амплитуда экземпляров: плоский пул 1.0 на параметре ReaEQ трека B
  local B = R.GetTrack(0, 1)
  local fx = R.TrackFX_AddByName(B, 'ReaEQ', false, -1)
  local env = R.GetFXEnvelope(B, fx, 0, true)
  local t1, t2, len = 20, 22, 1
  local i0 = R.InsertAutomationItem(env, -1, t1, len)
  R.DeleteEnvelopePointRangeEx(env, i0, t1 - 1, t1 + len + 1)
  R.InsertEnvelopePointEx(env, i0, t1, 1, 0, 0, false, true)
  R.InsertEnvelopePointEx(env, i0, t1 + len, 1, 0, 0, false, true)
  R.Envelope_SortPointsEx(env, i0)
  local pool = R.GetSetAutomationItemInfo(env, i0, 'D_POOL_ID', 0, false)
  local i1 = R.InsertAutomationItem(env, math.floor(pool + 0.5), t2, len)
  local function ev(t) local _, v = R.Envelope_Evaluate(env, t, 48000, 0); return v end
  log(('defaults: base %.2f amp %.2f'):format(R.GetSetAutomationItemInfo(env, i1, 'D_BASELINE', 0, false), R.GetSetAutomationItemInfo(env, i1, 'D_AMPLITUDE', 0, false)))
  log(('flat pool 1: %.3f / %.3f'):format(ev(t1 + 0.5), ev(t2 + 0.5)))
  R.GetSetAutomationItemInfo(env, i0, 'D_AMPLITUDE', 0.3, true)
  R.GetSetAutomationItemInfo(env, i1, 'D_AMPLITUDE', 0.8, true)
  log(('amp .3/.8: %.3f / %.3f'):format(ev(t1 + 0.5), ev(t2 + 0.5)))
  R.GetSetAutomationItemInfo(env, i0, 'D_BASELINE', 0, true)
  R.GetSetAutomationItemInfo(env, i1, 'D_BASELINE', 0, true)
  log(('+ base 0: %.3f / %.3f'):format(ev(t1 + 0.5), ev(t2 + 0.5)))
  R.GetSetAutomationItemInfo(env, i0, 'D_AMPLITUDE', 1, true); R.GetSetAutomationItemInfo(env, i1, 'D_AMPLITUDE', 1, true)
  R.GetSetAutomationItemInfo(env, i0, 'D_BASELINE', 0.2, true); R.GetSetAutomationItemInfo(env, i1, 'D_BASELINE', 0.7, true)
  log(('amp 1, base .2/.7: %.3f / %.3f'):format(ev(t1 + 0.5), ev(t2 + 0.5)))
  R.SetEditCurPos(0, false, false)
  R.OnPlayButton()
end)
if not ok then log('ERR ' .. tostring(err)) end
done()
