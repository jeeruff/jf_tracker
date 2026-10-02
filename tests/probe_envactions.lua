-- probe_envactions.lua — какие действия «Toggle track … envelope visible» нашлись → ExtState jf_tracker/probe
local out = {}
for _, range in ipairs({ { 40400, 40420 }, { 40860, 40870 }, { 41860, 41870 } }) do
  for id = range[1], range[2] do
    local txt = reaper.kbd_getTextFromCmd(id, 0) or ''
    if txt:match('^Track: Toggle track .*envelope visible') then out[#out + 1] = id .. '=' .. txt:gsub('^Track: Toggle track ', ''):gsub(' envelope visible', '') end
  end
end
reaper.SetExtState('jf_tracker', 'probe', table.concat(out, ' | '), false)
