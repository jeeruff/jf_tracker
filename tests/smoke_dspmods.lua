-- smoke_dspmods.lua — кураторский модуль слайсера живьём → ExtState jf_tracker/smoke
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
model.dspmods = dofile(DIR .. '/jf_tracker_dspmods.lua')
local edit = dofile(DIR .. '/jf_tracker_edit.lua'); edit.init(model)
local ok, err = pcall(function()
  local tr = R.GetTrack(0, 1)
  edit.fx_add(tr, 'jf_slixer')
  local fxs = model.track_fx(tr)
  local f = fxs[#fxs]
  log(('fx=%s np=%d cols=%d shown=%d'):format(f and f.name or '-', f and f.np or 0, f and f.cols or 0, f and #f.params or 0))
  if f then
    local kinds = {}
    for _, p in ipairs(f.params) do kinds[#kinds + 1] = p.name .. ':' .. p.kind .. (p.nsteps and ('/' .. p.nsteps) or '') end
    log(table.concat(kinds, ' '))
    edit.fx_remove(tr, f.i)
  end
  log('after remove count=' .. R.TrackFX_GetCount(tr))
end)
if not ok then log('ERR ' .. tostring(err)) end
done()
