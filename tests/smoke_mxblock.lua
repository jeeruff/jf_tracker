-- smoke_mxblock.lua — A.cells_mute / copy / paste / delete → ExtState jf_tracker/smoke
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out = {}
local function log(s) out[#out + 1] = s end
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
local _, pname = R.EnumProjects(-1, '')
if (pname and pname ~= '') or not table.concat(names, ','):find('M synth', 1, true) then log('REFUSED') else
  local ok, err = pcall(function()
    local model = dofile(DIR .. '/jf_tracker_model.lua')
    local edit = dofile(DIR .. '/jf_tracker_edit.lua'); edit.init(model)
    local A = dofile(DIR .. '/jf_tracker_pooled.lua'); A.init(model, edit)
    local snap = model.build(4)
    local seq = {}; for _, r in ipairs(model.regions(4)) do if not r.lib then seq[#seq + 1] = r end end
    local ci, ri
    for i, c in ipairs(snap.cols) do
      for j, rg in ipairs(seq) do
        for k = 0, R.CountTrackMediaItems(c.track) - 1 do
          local p = R.GetMediaItemInfo_Value(R.GetTrackMediaItem(c.track, k), 'D_POSITION')
          if not ri and p >= rg.pos and p < rg.rgnend then ci, ri = i, j end
        end
      end
    end
    log(('slots=%d col=%d first slot with items=%s'):format(#seq, ci, tostring(ri)))
    local tr = snap.cols[ci].track
    local function cnt() local m, n = 0, R.CountTrackMediaItems(tr); for k = 0, n - 1 do if R.GetMediaItemInfo_Value(R.GetTrackMediaItem(tr, k), 'B_MUTE') == 1 then m = m + 1 end end; return n, m end
    local n0, m0 = cnt(); log(('items=%d muted=%d'):format(n0, m0))
    local f; edit.run('t mute', function() f = A.cells_mute(seq, snap, ri, ri, ci, ci) end)
    local n1, m1 = cnt(); log(('mute block → flag=%s muted=%d'):format(tostring(f), m1))
    local clip = A.cells_copy(seq, snap, ri, ri, ci, ci)
    local dst = ri == 1 and 2 or 1
    local np; edit.run('t paste', function() np = A.cells_paste(seq, snap, dst, ci, clip) end)
    local n2 = cnt(); log(('paste to slot %d → %d item(s), total %d'):format(dst, np, n2))
    local nd; edit.run('t del', function() nd = A.cells_delete(seq, snap, dst, dst, ci, ci) end)
    log(('delete slot %d → %d removed, total %d'):format(dst, nd, (cnt())))
    edit.undo(); edit.undo(); edit.undo()
    local n3, m3 = cnt(); log(('undo → items=%d muted=%d (was %d/%d)'):format(n3, m3, n0, m0))
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
