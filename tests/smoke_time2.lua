-- smoke_time2.lua — delete/insert time в регионе на временных items → ExtState jf_tracker/smoke
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
    local tr = R.GetTrack(0, 0)
    local regs = model.regions(4)
    local rg; for _, r in ipairs(regs) do if not r.lib then rg = r; break end end
    local src = R.PCM_Source_CreateFromFile(R.GetMediaSourceFileName(R.GetMediaItemTake_Source(R.GetActiveTake(R.GetTrackMediaItem(tr, 0))), ''))
    local function mk(pos, len)
      local it = R.AddMediaItemToTrack(tr); local tk = R.AddTakeToMediaItem(it); R.SetMediaItemTake_Source(tk, src)
      R.SetMediaItemInfo_Value(it, 'D_POSITION', pos); R.SetMediaItemInfo_Value(it, 'D_LENGTH', len); return it
    end
    R.Undo_BeginBlock2(0)
    local a = mk(rg.pos + 0.5, 0.25); local b = mk(rg.pos + 1.0, 0.25); local c = mk(rg.rgnend + 0.1, 0.25)
    R.Undo_EndBlock2(0, 'smoke items', -1)
    local function items()
      local t = {}
      for i = 0, R.CountTrackMediaItems(tr) - 1 do local it = R.GetTrackMediaItem(tr, i); local p = R.GetMediaItemInfo_Value(it, 'D_POSITION'); if p >= rg.pos - 0.01 and p < rg.rgnend + 1 then t[#t + 1] = ('%.2f'):format(p - rg.pos) end end
      return table.concat(t, ' ')
    end
    log(('region %s len %.2f: rel items %s'):format(rg.name, rg.rgnend - rg.pos, items()))
    edit.time_delete({ tr }, rg.pos + 0.5, rg.pos + 0.75, rg.rgnend)
    log('delete [0.50,0.75): ' .. items() .. ' (expect 0.75 and the one past region unchanged)')
    edit.time_insert({ tr }, rg.pos + 0.5, 0.25, rg.rgnend)
    log('insert 0.25 @0.50: ' .. items() .. ' (expect 1.00)')
    edit.undo(); edit.undo(); edit.undo()
    log('undo all: ' .. items())
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
