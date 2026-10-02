-- smoke_mxregion.lua — add_region / rename / set_end+ripple → ExtState jf_tracker/smoke
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out = {}
local function log(s) out[#out + 1] = s end
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
local _, pname = R.EnumProjects(-1, '')
if (pname and pname ~= '') or not table.concat(names, ','):find('A drums', 1, true) then log('REFUSED') else
  local ok, err = pcall(function()
    local model = dofile(DIR .. '/jf_tracker_model.lua')
    local edit = dofile(DIR .. '/jf_tracker_edit.lua'); edit.init(model)
    local alias = dofile(DIR .. '/jf_tracker_alias.lua'); alias.init(model, edit)
    local lpb = 16
    local function seq() model.invalidate(); local rg = model.regions(lpb); local o = {}; for _, r in ipairs(rg) do if not r.lib then o[#o + 1] = r end end; o.lib_pos = rg.lib_pos; return o end
    local function dump(s) local t = {}; for _, r in ipairs(s) do t[#t + 1] = ('%s[%.3f-%.3f]'):format(r.name, r.pos, r.rgnend) end; return table.concat(t, ' ') end
    local s0 = seq(); local n0 = #s0
    log('before: ' .. dump(s0))
    edit.run('add', function() alias.add_region(s0, 'new', 1) end)
    local s1 = seq(); local rg = s1[#s1]
    local _, qms = R.TimeMap_QNToMeasures(0, R.TimeMap2_timeToQN(0, rg.pos))
    log(('added %s [%.3f-%.3f] on bar: %s, count %d→%d'):format(rg.name, rg.pos, rg.rgnend, tostring(math.abs(R.TimeMap2_timeToQN(0, rg.pos) - qms) < 1e-6), n0, #s1))
    edit.run('rename', function() alias.rename(rg, 'renamed') end)
    s1 = seq(); rg = s1[#s1]; log('renamed → ' .. rg.name)
    -- длина: регион 1 → 8 шагов, остальные едут
    local first = s1[1]; local old_end = first.rgnend; local nxt = s1[2]
    local t1 = edit.row_time(first.r0 + 8, lpb, 0)
    local tracks = {}; for i = 0, R.CountTracks(0) - 1 do tracks[#tracks + 1] = R.GetTrack(0, i) end
    -- items после old_end: позиции до правки
    local before = {}
    for _, tr in ipairs(tracks) do for i = 0, R.CountTrackMediaItems(tr) - 1 do local it = R.GetTrackMediaItem(tr, i); local p = R.GetMediaItemInfo_Value(it, 'D_POSITION'); if p >= old_end - 1e-6 then before[#before + 1] = { it = it, p = p } end end end
    edit.run('len', function()
      alias.shift_markers(first.rgnend, t1 - old_end); alias.set_end(first, t1)
      if t1 > old_end then edit.time_insert(tracks, old_end, t1 - old_end, math.huge) else edit.time_delete(tracks, t1, old_end, math.huge) end
    end)
    local okmove, moved = 0, 0
    for _, b in ipairs(before) do if R.ValidatePtr2(0, b.it, 'MediaItem*') then moved = moved + 1; if math.abs(R.GetMediaItemInfo_Value(b.it, 'D_POSITION') - (b.p + t1 - old_end)) < 1e-4 then okmove = okmove + 1 end end end
    log(('items after region: %d, still exist %d, moved exactly by dt %d'):format(#before, moved, okmove))
    local s2 = seq()
    log(('len 8 steps: first %.3f→%.3f (dt %+.3f); next %.3f→%.3f'):format(old_end, s2[1].rgnend, t1 - old_end, nxt.pos, s2[2].pos))
    log('after: ' .. dump(s2))
    for _ = 1, 3 do edit.undo() end
    log('undo → ' .. dump(seq()))
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
