-- smoke_trim.lua — A.trim живьём: items за границами регионов режутся → ExtState jf_tracker/smoke
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out = {}
local function log(s) out[#out + 1] = s end
local _, pname = R.EnumProjects(-1, '')
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
if (pname and pname ~= '') or not (table.concat(names, ','):find('A drums', 1, true) and table.concat(names, ','):find('B lanes', 1, true) and table.concat(names, ','):find('M synth', 1, true)) then log('REFUSED') else
  local ok, err = pcall(function()
    local model = dofile(DIR .. '/jf_tracker_model.lua')
    local edit = dofile(DIR .. '/jf_tracker_edit.lua'); edit.init(model)
    local A = dofile(DIR .. '/jf_tracker_pooled.lua'); A.init(model, edit)
    local regs = model.regions(4)
    local seq = {}
    for _, r in ipairs(regs) do if not r.lib then seq[#seq + 1] = r end end
    local function crossing()
      local n = 0
      for ti = 0, R.CountTracks(0) - 1 do
        local tr = R.GetTrack(0, ti)
        for i = 0, R.CountTrackMediaItems(tr) - 1 do
          local it = R.GetTrackMediaItem(tr, i)
          local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION'); local fin = pos + R.GetMediaItemInfo_Value(it, 'D_LENGTH')
          for _, rg in ipairs(seq) do
            if (pos >= rg.pos - 1e-6 and pos < rg.rgnend - 1e-6 and fin > rg.rgnend + 1e-6) or (pos < rg.pos - 1e-6 and fin > rg.pos + 1e-6) then n = n + 1 end
          end
        end
      end
      return n
    end
    local total0 = 0; for ti = 0, R.CountTracks(0) - 1 do total0 = total0 + R.CountTrackMediaItems(R.GetTrack(0, ti)) end
    log(('regions=%d crossing before=%d items=%d'):format(#seq, crossing(), total0))
    local n
    edit.run('matrix trim', function() n = A.trim(seq) end)
    local total1 = 0; for ti = 0, R.CountTracks(0) - 1 do total1 = total1 + R.CountTrackMediaItems(R.GetTrack(0, ti)) end
    log(('trim edits=%d crossing after=%d items=%d'):format(n, crossing(), total1))
    edit.undo()
    local total2 = 0; for ti = 0, R.CountTracks(0) - 1 do total2 = total2 + R.CountTrackMediaItems(R.GetTrack(0, ti)) end
    log(('undo: crossing=%d items=%d'):format(crossing(), total2))
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
