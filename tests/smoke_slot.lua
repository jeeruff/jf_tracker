-- smoke_slot.lua — переключение паттерна в слоте и библиотека =LIB → ExtState jf_tracker/smoke
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
local pooled = dofile(DIR .. '/jf_tracker_pooled.lua')
edit.init(model); pooled.init(model, edit)
local ok, err = pcall(function()
  local regions = model.regions(4)
  local list, by = model.patterns(regions)
  local s = {}
  for _, p in ipairs(list) do s[#s + 1] = ('%s#%d×%d'):format(p.name, p.num, p.n) end
  log('patterns: ' .. table.concat(s, ' '))
  local seq = {}
  for _, rg in ipairs(regions) do if not rg.lib then seq[#seq + 1] = rg end end
  log(('seq=%d lib_pos=%s'):format(#seq, tostring(regions.lib_pos)))
  -- слот 1 (intro, единственный) → паттерн B
  local slot = seq[1]
  local target = by['B']
  local len0 = slot.rgnend - slot.pos
  local n_before = R.CountMediaItems(0)
  local ok2 = pooled.set_slot(regions, slot, target)
  model.invalidate()
  regions = model.regions(4)
  local lib_n = 0
  local first
  for _, rg in ipairs(regions) do if rg.lib then lib_n = lib_n + 1 end end
  for _, rg in ipairs(regions) do if not rg.lib then first = rg; break end end
  log(('set_slot=%s slot now %s len %.2f→%.2f lib regions=%d lib_pos=%s items %d→%d'):format(
    tostring(ok2), first and first.name or '-', len0, first and (first.rgnend - first.pos) or -1, lib_n, tostring(regions.lib_pos), n_before, R.CountMediaItems(0)))
  local names2 = {}
  for _, rg in ipairs(regions) do names2[#names2 + 1] = ('%s@%.1f%s'):format(rg.name, rg.pos, rg.lib and 'L' or '') end
  log(table.concat(names2, ' '))
  log('undo=' .. tostring(R.Undo_CanUndo2(0)))
end)
if not ok then log('ERR ' .. tostring(err)) end
done()
