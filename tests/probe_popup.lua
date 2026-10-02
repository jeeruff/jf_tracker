-- probe_popup.lua — прогон draw.popup и vim.popup без клавиш → ExtState jf_tracker/probe
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local RES = reaper.GetResourcePath()
local out = {}
local ok, err = pcall(function()
  local U = dofile(RES .. '/Scripts/jf_looper/jf_looper_ui.lua')
  local draw = dofile(DIR .. '/jf_tracker_draw.lua')
  local vim = dofile(DIR .. '/jf_tracker_vim.lua')
  draw.init(U, nil, nil)
  draw.set_font({ font = 12 })
  local L = draw.layout({ cols = {} }, { folds = {}, fxcols = 1, hscroll = 1 }, 0)
  out[#out + 1] = ('rh=%d pad=%d'):format(L.rh, L.pad)
  draw.popup(L, { title = ':lp', kind = 'cmd', hl = 1, lines = { { key = 'lpb N', text = 'строк' } } })
  out[#out + 1] = 'cmd popup ok'
  local lines = {}
  for i = 1, 24 do lines[i] = { key = 'k' .. i, text = 'label ' .. i } end
  draw.popup(L, { title = '\\ actions', kind = 'hydra', lines = lines })
  out[#out + 1] = 'hydra popup 24 lines ok'
  vim.init({ state = {}, layout = function() return L end, snap = function() return { cols = {} } end })
  vim.mode = 'cmd'; vim.cmdline = 'f'
  local p = vim.popup()
  out[#out + 1] = 'vim cmd popup: ' .. #p.lines .. ' matches'
end)
if not ok then out[#out + 1] = 'ERR ' .. tostring(err) end
reaper.SetExtState('jf_tracker', 'probe', table.concat(out, ' | '), false)
