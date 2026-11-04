-- smoke_slots.lua — Vim-операции слотов матрицы (2 окт): снимок, put после /
-- перед первым, delete; =START не едет; undo возвращает. Только песочница
-- («A drums», несохранённый проект) → ExtState jf_tracker/smoke
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
    local pooled = dofile(DIR .. '/jf_tracker_pooled.lua'); pooled.init(model, edit)
    local lpb = 16
    local function seq() model.invalidate(); local rg = model.regions(lpb); local o = {}; for _, r in ipairs(rg) do if not r.lib then o[#o + 1] = r end end; o.lib_pos = rg.lib_pos; return o end
    local function dump(s) local t = {}; for _, r in ipairs(s) do t[#t + 1] = ('%s[%.3f-%.3f]'):format(r.name, r.pos, r.rgnend) end; return table.concat(t, ' ') end
    local function nitems() local n = 0; for i = 0, R.CountTracks(0) - 1 do n = n + R.CountTrackMediaItems(R.GetTrack(0, i)) end; return n end
    local snap = { cols = {} }
    for i = 0, R.CountTracks(0) - 1 do local tr = R.GetTrack(0, i); local _, n = R.GetTrackName(tr); if n ~= model.DEPOT then snap.cols[#snap.cols + 1] = { track = tr } end end
    local s0 = seq(); local i0 = nitems(); local st0 = model.marker_pos(model.START_MARKER)
    log('before: ' .. dump(s0) .. (' items %d start %s'):format(i0, tostring(st0)))
    -- D: дубль первого слота после него, новое имя
    local sl = pooled.slot_snapshot(s0, snap, 1)
    sl.name = pooled.free_name(s0, sl.name)
    local len = sl.len
    edit.run('dup', function() pooled.put_slot(snap, s0[1].rgnend, sl) end)
    local s1 = seq()
    log(('dup: count %d→%d, name %s, items +%d (snapshot %d), next slot moved %+.3f (want %+.3f)'):format(#s0, #s1, s1[2] and s1[2].name or '?',
      nitems() - i0, sl.nitems, s0[2] and (s1[3].pos - s0[2].pos) or 0, len))
    -- P перед первым: =START остаётся на месте
    edit.run('put before', function() pooled.put_slot(snap, s1[1].pos, pooled.slot_snapshot(s1, snap, 1)) end)
    local s2 = seq()
    log(('put before first: count %d, start %s → %s'):format(#s2, tostring(st0), tostring(model.marker_pos(model.START_MARKER))))
    -- dd: удалить вставленный перед первым
    edit.run('delete', function() pooled.delete_slot(s2[1]) end)
    local s3 = seq()
    log(('delete: count %d (want %d), first pos %.3f (want %.3f)'):format(#s3, #s1, s3[1].pos, s1[1].pos))
    for _ = 1, 3 do edit.undo() end
    log('undo → ' .. dump(seq()) .. (' items %d (want %d)'):format(nitems(), i0))
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
