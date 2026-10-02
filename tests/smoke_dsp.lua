-- smoke_dsp.lua — DSP-панель живьём: add / param / bypass / remove → ExtState jf_tracker/smoke
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
  local tr = R.GetTrack(0, 0)
  edit.fx_add(tr, 'ReaEQ')
  local fxs = model.track_fx(tr)
  log(('fx=%d first=%s np=%d params=%d'):format(#fxs, fxs[1] and fxs[1].name or '-', fxs[1] and fxs[1].np or 0, fxs[1] and #fxs[1].params or 0))
  local f = fxs[1]
  if f then
    local p = f.params[1]
    local v0 = R.TrackFX_GetParamNormalized(tr, f.i, p.i)
    edit.fx_param(tr, f.i, p.i, 0.25)
    local vals = model.fx_values(tr, f)
    log(('param %s: %.2f → %.2f (%s)'):format(p.name, v0, vals[1].n, vals[1].s))
    edit.fx_bypass(tr, f.i); log('bypass → enabled=' .. tostring(R.TrackFX_GetEnabled(tr, f.i)))
    edit.fx_bypass(tr, f.i)
    edit.fx_remove(tr, f.i); log('removed → count=' .. R.TrackFX_GetCount(tr))
  end
  local n = 0
  if R.EnumInstalledFX then while true do local ok2 = R.EnumInstalledFX(n); if not ok2 then break end; n = n + 1; if n > 5000 then break end end end
  log('installed fx enumerable: ' .. n)
end)
if not ok then log('ERR ' .. tostring(err)) end
done()
