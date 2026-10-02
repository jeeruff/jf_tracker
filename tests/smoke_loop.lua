-- smoke_loop.lua — F1: loop_items (аудио SECTION / MIDI), регион→item, undo → ExtState jf_tracker/smoke
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
    local tr = R.GetTrack(0, 0)
    local inst = R.GetTrackMediaItem(tr, 0)
    local regions = model.regions(lpb)
    local rg = regions[1]
    -- аудио: нота в начале региона 1, луп 4 шага
    edit.insert_note(tr, nil, lpb, rg.r0, 60, 100, 1, inst)
    local it
    for i = 0, R.CountTrackMediaItems(tr) - 1 do local x = R.GetTrackMediaItem(tr, i); if math.abs(R.GetMediaItemInfo_Value(x, 'D_POSITION') - rg.pos) < 1e-4 then it = x end end
    local take = R.GetActiveTake(it)
    local rate = R.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
    local n, warn = edit.loop_items({ it }, lpb, rg.rgnend, 4)
    local src = R.GetMediaItemTake_Source(take)
    local sok, soffs, slen = R.PCM_Source_GetSectionInfo(src)
    local row_sec = edit.row_time(rg.r0 + 1, lpb, 0) - edit.row_time(rg.r0, lpb, 0)
    log(('audio loop4: n=%d warn=%s len=%.3f (rgn %.3f) loopsrc=%d offs=%.3f section=%s slen=%.4f want %.4f srclen=%.4f'):format(
      n, tostring(warn), R.GetMediaItemInfo_Value(it, 'D_LENGTH'), rg.rgnend - rg.pos, R.GetMediaItemInfo_Value(it, 'B_LOOPSRC'),
      R.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS'), tostring(sok), slen or -1, 4 * row_sec * rate, R.GetMediaSourceLength(src) or -1))
    model.invalidate()
    local snap = model.snapshot(lpb)
    local head
    for _, lane in ipairs(snap.cols[1].lanes) do for _, sub in ipairs(lane.subs) do if sub[rg.r0] and sub[rg.r0].item == it then head = sub[rg.r0] end end end
    log(('model loop_rows=%.2f loop_first=%.2f'):format(head and head.loop_rows or -1, head and head.loop_first or -1))
    -- повторный луп 6 шагов (секция уже есть → развернуть, не вкладывать)
    edit.loop_items({ it }, lpb, rg.rgnend, 6)
    local _, _, slen2 = R.PCM_Source_GetSectionInfo(R.GetMediaItemTake_Source(R.GetActiveTake(it)))
    local _, chunk = R.GetItemStateChunk(it, '', false)
    local _, nsect = chunk:gsub('<SOURCE SECTION', '')
    log(('reloop6: slen=%.4f want %.4f nested SECTION blocks=%d'):format(slen2 or -1, 6 * row_sec * rate, nsect))
    -- регион → конец item: укоротим item до 10 шагов и подгоним регион
    R.SetMediaItemInfo_Value(it, 'D_LENGTH', 10 * row_sec)
    local old_end = rg.rgnend
    local t1 = R.GetMediaItemInfo_Value(it, 'D_POSITION') + 10 * row_sec
    local hook = edit.after; edit.after = nil
    edit.run('region length', function()
      alias.shift_markers(rg.rgnend, t1 - old_end); alias.set_end(rg, t1)
      edit.time_delete({ tr }, t1, old_end, math.huge)
    end)
    edit.after = hook
    model.invalidate(); local rg2 = model.regions(lpb)[1]
    log(('region->item: rgnend %.3f want %.3f'):format(rg2.rgnend, t1))
    -- MIDI: трек с MIDI-item? ищем
    local mtr
    for i = 0, R.CountTracks(0) - 1 do local t = R.GetTrack(0, i); for k = 0, R.CountTrackMediaItems(t) - 1 do local x = R.GetTrackMediaItem(t, k); local tk = R.GetActiveTake(x); if tk and R.TakeIsMIDI(tk) then mtr = { t, x } end end end
    if mtr then
      local mit = mtr[2]; local mpos = R.GetMediaItemInfo_Value(mit, 'D_POSITION')
      local rgm = alias.region_at(model.regions(lpb), mpos)
      if rgm then
        edit.loop_items({ mit }, lpb, rgm.rgnend, 8)
        local ml, isqn = R.GetMediaSourceLength(R.GetMediaItemTake_Source(R.GetActiveTake(mit)))
        log(('midi loop8: srclen=%.3f qn=%s want %.3f pos %.3f→%.3f loopsrc=%d'):format(ml, tostring(isqn), 8 / lpb, mpos, R.GetMediaItemInfo_Value(mit, 'D_POSITION'), R.GetMediaItemInfo_Value(mit, 'B_LOOPSRC')))
      else log('midi: item outside regions') end
    else log('midi: no MIDI item in sandbox') end
    for _ = 1, 6 do edit.undo() end
    log('undo → items on A: ' .. R.CountTrackMediaItems(tr))
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
