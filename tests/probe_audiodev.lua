-- probe_audiodev.lua — только чтение: настройки устройства CoreAudio и текущее устройство
local p = {}
for _, k in ipairs({ 'coreaudioindevnew', 'coreaudiooutdevnew', 'coreaudiosrate', 'coreaudiosrateuse', 'coreaudiobs', 'coreaudiobsuse' }) do
  local ok, v = reaper.get_config_var_string(k)
  p[#p + 1] = k .. '=' .. tostring(ok) .. ':' .. tostring(v)
end
for _, k in ipairs({ 'MODE', 'IDENT_IN', 'IDENT_OUT', 'SRATE', 'BSIZE' }) do
  local ok, v = reaper.GetAudioDeviceInfo(k)
  p[#p + 1] = k .. '=' .. tostring(v)
end
p[#p + 1] = 'running=' .. tostring(reaper.Audio_IsRunning())
reaper.SetExtState('jf_tracker', 'probe', table.concat(p, ' | '), false)
