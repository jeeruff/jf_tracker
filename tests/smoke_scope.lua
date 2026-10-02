-- smoke_scope.lua — мост осциллоскопа живьём → ExtState jf_tracker/smoke
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
local snap = model.build(4)
edit.scopes(snap.cols, true)
model.invalidate(); snap = model.build(4)
local slots = {}
for _, c in ipairs(snap.cols) do slots[#slots + 1] = c.name .. '=' .. tostring(c.scope_slot) end
log('slots: ' .. table.concat(slots, ' '))
R.gmem_attach('jf_tracker_scope')
local hb1 = R.gmem_read(0 * 512 + 257)
local t0 = R.time_precise()
-- подождать блок аудио (защитимся от бесконечного цикла)
local function later()
  local hb2 = R.gmem_read(257)
  local wp = R.gmem_read(256)
  log(('gmem hb %d→%d wp=%d sample[0]=%.3f'):format(hb1, hb2, wp, R.gmem_read(0)))
  local fxn = R.TrackFX_GetByName(R.GetTrack(0, 0), 'jf_tracker_scope', false)
  local _, fxname = R.TrackFX_GetFXName(R.GetTrack(0, 0), fxn, '')
  log('fx on A: idx=' .. fxn .. ' ' .. tostring(fxname))
  edit.scopes(snap.cols, false)
  log('after off: ' .. R.TrackFX_GetByName(R.GetTrack(0, 0), 'jf_tracker_scope', false))
  done()
end
reaper.defer(function() reaper.defer(function() later() end) end)
