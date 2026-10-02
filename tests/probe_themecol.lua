-- probe_themecol.lua — цвет темы с обработкой Theme Adjuster и без (только чтение)
local out = {}
for _, k in ipairs({ 'col_env1', 'col_env3', 'col_env6', 'env_item_vol', 'col_main_bg2', 'col_tr1_bg' }) do
  local a, b = reaper.GetThemeColor(k, 0), reaper.GetThemeColor(k, 1)
  local function rgb(v) if not v or v < 0 then return '-' end local r, g, bb = reaper.ColorFromNative(v); return ('%d,%d,%d'):format(r, g, bb) end
  out[#out + 1] = k .. ' f0=' .. rgb(a) .. ' f1=' .. rgb(b)
end
reaper.SetExtState('jf_tracker', 'probe', table.concat(out, ' | '), false)
