-- smoke_slice.lua — слайсер живьём в песочнице → ExtState jf_tracker/smoke
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
local SL = dofile(DIR .. '/jf_tracker_slicer.lua')
edit.init(model)
SL.init({ edit = edit, preview_slice = function() end, fit = function(s) return s end })
local ok, err = pcall(function()
  local snap = model.build(4)
  local col = snap.cols[1]
  local e = col.pool[1]
  log(('inst %s len=%.3f env=%s'):format(e.name, e.len, tostring(SL.env ~= nil)))
  SL.open(e, col.track)
  log('env after open=' .. tostring(SL.env ~= nil))
  SL.equal(8); log('equal 8 → ' .. #SL.slices)
  SL.detect(); log('transients=' .. #SL.trans)
  SL.apply()
  model.invalidate(); snap = model.build(4)
  local e2 = snap.cols[1].pool[1]
  log('stored slices=' .. tostring(e2.slices and #e2.slices))
  local n0 = R.CountTrackMediaItems(col.track)
  edit.insert_slice(col.track, nil, 4, 100, e2.item, 3)
  model.invalidate(); snap = model.build(4)
  local n1 = R.CountTrackMediaItems(col.track)
  local head
  for _, lane in ipairs(snap.cols[1].lanes) do for _, sub in ipairs(lane.subs) do if sub[100] and sub[100].kind == 'audio' then head = sub[100] end end end
  log(('insert slice 3: items %d→%d head=%s fx=%s offs=%.3f len=%.3f'):format(n0, n1, tostring(head and head.name), head and table.concat(head.fx, ',') or '-', head and head.offs or -1, head and head.len or -1))
  if head then
    edit.set_fx({ head }, 4, 'S', 5)
    model.invalidate(); snap = model.build(4)
    for _, lane in ipairs(snap.cols[1].lanes) do for _, sub in ipairs(lane.subs) do if sub[100] and sub[100].kind == 'audio' then head = sub[100] end end end
    log(('S05 → fx=%s offs=%.3f'):format(table.concat(head.fx, ','), head.offs))
  end
end)
if not ok then log('ERR ' .. tostring(err)) end
done()
