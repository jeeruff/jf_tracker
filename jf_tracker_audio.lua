-- jf_tracker_audio.lua — аудиоустройство REAPER из трекера (10 окт): вкладка
-- audio в options и zB (размер буфера).
--
-- Читается нативно (get_config_var_string: coreaudio* — то же, что Preferences →
-- Audio → Device), пишется через SWS (SNM_SetStringConfigVar / SNM_SetIntConfigVar),
-- применяется Audio_Quit + Audio_Init (переоткрыть звук). Только CoreAudio (macOS).
-- Списка устройств в API нет: список — устройства, которые трекер уже видел
-- (ExtState jf_tracker/audiodevs, «a|b|c»), плюс ввод имени вручную.
-- Чистые функции (без reaper) — tests/test_audio.lua.

local A = {}
A.BS = { 32, 64, 128, 256, 512, 1024, 2048 }
A.SR = { 44100, 48000, 88200, 96000 }

-- история устройств: строка «a|b|c» ↔ список, новые — в начало, без повторов, до 12
function A.hist_parse(s)
  local out, seen = {}, {}
  for n in (s or ''):gmatch('[^|]+') do if not seen[n] then seen[n] = true; out[#out + 1] = n end end
  return out
end
function A.hist_add(list, name)
  if not name or name == '' then return list end
  local out = { name }
  for _, n in ipairs(list or {}) do if n ~= name and #out < 12 then out[#out + 1] = n end end
  return out
end
function A.hist_str(list) return table.concat(list or {}, '|') end

-- «CoreAudio MHLink [46236]» → «MHLink [46236]»
function A.strip_ident(s) return ((s or ''):gsub('^CoreAudio%s+', '')) end

-- что поменять: cur и want = { dev, sr, sruse, bs, bsuse }; список { {kind, key, value} }
function A.diff(cur, want)
  local ch = {}
  if want.dev and want.dev ~= '' and want.dev ~= cur.dev then
    ch[#ch + 1] = { 's', 'coreaudiooutdevnew', want.dev }
    ch[#ch + 1] = { 's', 'coreaudioindevnew', want.dev }
  end
  if want.sruse ~= nil and want.sruse ~= cur.sruse then ch[#ch + 1] = { 'i', 'coreaudiosrateuse', want.sruse and 1 or 0 } end
  if want.sr and want.sr ~= cur.sr then ch[#ch + 1] = { 'i', 'coreaudiosrate', want.sr } end
  if want.bsuse ~= nil and want.bsuse ~= cur.bsuse then ch[#ch + 1] = { 'i', 'coreaudiobsuse', want.bsuse and 1 or 0 } end
  if want.bs and want.bs ~= cur.bs then ch[#ch + 1] = { 'i', 'coreaudiobs', want.bs } end
  return ch
end

-- ── с reaper ─────────────────────────────────────────────────────────────
local R = reaper
local function cv(k)
  if not (R and R.get_config_var_string) then return nil end
  local ok, v = R.get_config_var_string(k)
  return ok and v or nil
end
-- текущие настройки; nil — не CoreAudio / старый REAPER
function A.read()
  local dev = cv('coreaudiooutdevnew')
  if not dev then return nil end
  return { dev = dev, sr = tonumber(cv('coreaudiosrate')) or 0, sruse = cv('coreaudiosrateuse') == '1',
           bs = tonumber(cv('coreaudiobs')) or 0, bsuse = cv('coreaudiobsuse') == '1' }
end
-- что реально открыто сейчас: устройство, частота, буфер
function A.live()
  local _, id = R.GetAudioDeviceInfo('IDENT_OUT')
  local _, sr = R.GetAudioDeviceInfo('SRATE')
  local _, bs = R.GetAudioDeviceInfo('BSIZE')
  return { dev = A.strip_ident(id), sr = tonumber(sr), bs = tonumber(bs), running = R.Audio_IsRunning and R.Audio_IsRunning() == 1 }
end
function A.can_write() return R and R.SNM_SetStringConfigVar ~= nil and R.SNM_SetIntConfigVar ~= nil and R.Audio_Quit ~= nil end
-- применить want; true, текст / false, причина
function A.apply(want)
  local cur = A.read()
  if not cur then return false, 'audio: only CoreAudio (macOS) settings are supported' end
  if not A.can_write() then return false, 'audio: needs SWS (SNM_SetStringConfigVar)' end
  local ch = A.diff(cur, want)
  if #ch == 0 then return true, 'audio: nothing to change' end
  for _, c in ipairs(ch) do
    if c[1] == 's' then R.SNM_SetStringConfigVar(c[2], c[3]) else R.SNM_SetIntConfigVar(c[2], c[3]) end
  end
  R.Audio_Quit(); R.Audio_Init()
  local l = A.live()
  return true, ('audio: %s  %s Hz  %s smp%s'):format(l.dev or '?', tostring(l.sr or '?'), tostring(l.bs or '?'), l.running and '' or '  (NOT running - check the device)')
end
-- история: прочитать, добавить открытое сейчас, сохранить
function A.history()
  local list = A.hist_parse(R.GetExtState('jf_tracker', 'audiodevs'))
  local cur = A.read()
  if cur and cur.dev ~= '' then
    local nl = A.hist_add(list, cur.dev)
    if A.hist_str(nl) ~= A.hist_str(list) then R.SetExtState('jf_tracker', 'audiodevs', A.hist_str(nl), true) end
    list = nl
  end
  return list
end
function A.remember(name)
  local nl = A.hist_add(A.hist_parse(R.GetExtState('jf_tracker', 'audiodevs')), name)
  R.SetExtState('jf_tracker', 'audiodevs', A.hist_str(nl), true)
end

return A
