-- probe_rs5k.lua — только чтение: параметры первого RS5K в проекте (имя, нормированное, формат)
local R = reaper
local out = {}
for t = 0, R.CountTracks(0) - 1 do
  local tr = R.GetTrack(0, t)
  for fx = 0, R.TrackFX_GetCount(tr) - 1 do
    local _, nm = R.TrackFX_GetFXName(tr, fx, '')
    if nm:lower():find('reasamplomatic', 1, true) then
      out[#out + 1] = ('track %d fx %d np %d'):format(t + 1, fx, R.TrackFX_GetNumParams(tr, fx))
      for p = 0, R.TrackFX_GetNumParams(tr, fx) - 1 do
        local _, pn = R.TrackFX_GetParamName(tr, fx, p, '')
        local _, fv = R.TrackFX_GetFormattedParamValue(tr, fx, p, '')
        out[#out + 1] = ('%d %s = %.4f [%s]'):format(p, pn, R.TrackFX_GetParamNormalized(tr, fx, p), fv)
      end
      for _, k in ipairs({ 'FILE0', 'MODE', 'RESAMPLE', 'resample_mode', 'NUMFILES' }) do
        local ok, v = R.TrackFX_GetNamedConfigParm(tr, fx, k); out[#out + 1] = 'cfg ' .. k .. ' = ' .. tostring(ok) .. ' ' .. tostring(v)
      end
      R.SetExtState('jf_tracker', 'probe', table.concat(out, ' | '), false); R.defer(function() end); return
    end
  end
end
R.SetExtState('jf_tracker', 'probe', 'no rs5k', false); R.defer(function() end)
