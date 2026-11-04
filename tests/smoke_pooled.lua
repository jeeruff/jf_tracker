-- smoke_pooled.lua — алиасы живьём в песочнице: повтор региона A в конец,
-- правка в A → синхронизация в копию. Результат → ExtState jf_tracker/smoke.
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out = {}
local function log(s) out[#out + 1] = s end
local function done() R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false) end
local _, pname = R.EnumProjects(-1, '')
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
if (pname and pname ~= '') or not (table.concat(names, ','):find('A drums', 1, true) and table.concat(names, ','):find('B lanes', 1, true) and table.concat(names, ','):find('M synth', 1, true)) then
  log('REFUSED'); done(); return
end
local model = dofile(DIR .. '/jf_tracker_model.lua')
local edit = dofile(DIR .. '/jf_tracker_edit.lua')
local pooled = dofile(DIR .. '/jf_tracker_pooled.lua')
edit.init(model); pooled.init(model, edit)
local ok, err = pcall(function()
  local regions = model.regions(4)
  local A
  for _, rg in ipairs(regions) do if rg.name == 'A' then A = rg end end
  log('regions=' .. #regions .. ' A=' .. tostring(A and A.pos))
  local function count_in(rg)
    local n = 0
    for ti = 0, 2 do
      local tr = R.GetTrack(0, ti)
      for i = 0, R.CountTrackMediaItems(tr) - 1 do
        local pos = R.GetMediaItemInfo_Value(R.GetTrackMediaItem(tr, i), 'D_POSITION')
        if pos >= rg.pos - 1e-6 and pos < rg.rgnend - 1e-6 then n = n + 1 end
      end
    end
    return n
  end
  local nA = count_in(A)
  local t0 = pooled.append(regions, A)
  model.invalidate()
  regions = model.regions(4)
  local A2
  for _, rg in ipairs(regions) do if rg.name == 'A' and math.abs(rg.pos - t0) < 1e-6 then A2 = rg end end
  log(('append t0=%.2f copies=%d/%d'):format(t0, A2 and count_in(A2) or -1, nA))
  -- правка в A: удалить первый item трека A внутри A, затем sync
  local tr = R.GetTrack(0, 0)
  local victim
  for i = 0, R.CountTrackMediaItems(tr) - 1 do
    local it = R.GetTrackMediaItem(tr, i)
    local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
    if pos >= A.pos - 1e-6 and pos < A.rgnend - 1e-6 then victim = it; break end
  end
  edit.after = function() pooled.sync(regions, A) end
  if victim then edit.delete({ { kind = 'audio', item = victim } }, 4) end
  edit.after = nil
  model.invalidate()
  log(('after delete+sync: A=%d A2=%d'):format(count_in(A), A2 and count_in(A2) or -1))
  local it = A2 and R.GetTrackMediaItem(R.GetTrack(0, 2), R.CountTrackMediaItems(R.GetTrack(0, 2)) - 1)
  if it then local _, tag = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_pattern', '', false); log('tag=' .. tostring(tag)) end
end)
if not ok then log('ERR ' .. tostring(err)) end
done()
