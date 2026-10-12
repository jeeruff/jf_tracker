-- smoke_notemod.lua — модуляция по нотам живьём (песочница) → ExtState jf_tracker/smoke
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
local NM = edit.NM
local ok, err = pcall(function()
  local snap = model.build(4)
  edit.inst_ref = function(it)
    local i = snap.inst_of and snap.inst_of[it]
    local e = i and snap.pool[i]
    return e and e.item or nil
  end
  -- первая audio-нота и её инструмент
  local col, head
  for _, c in ipairs(snap.cols) do
    for _, lane in ipairs(c.lanes) do for _, sub in ipairs(lane.subs) do
      for _, cell in pairs(sub) do if not head and cell.kind == 'audio' and snap.inst_of[cell.item] then head, col = cell, c end end
    end end
  end
  if not head then log('no audio note'); return end
  local mother = snap.pool[snap.inst_of[head.item]].item
  local tr = R.GetMediaItem_Track(mother)
  log('note=' .. tostring(head.name) .. ' mother on ' .. select(2, R.GetTrackName(tr)) .. ' family=' .. #NM.family(mother))
  -- цель: параметр 0 ReaEQ на треке инструмента
  local fx = R.TrackFX_AddByName(tr, 'ReaEQ', false, -1)
  if fx < 0 then log('no ReaEQ'); return end
  local key = 'fx:' .. R.TrackFX_GetFXGUID(tr, fx) .. ':0'
  local pool, e2 = edit.nmod_add(mother, tr, key, 'eq freq')
  log('pool=' .. tostring(pool) .. ' ' .. tostring(e2 or '') .. ' err=' .. tostring(edit.nm_err))
  local env = NM.env(tr, key, false)
  local fam = NM.family(mother)
  local on_tr = 0
  for _, o in ipairs(fam) do if R.GetMediaItem_Track(o) == tr then on_tr = on_tr + 1 end end
  log(('ais=%d want=%d (items of the family on the track)'):format(env and R.CountAutomationItems(env) or -1, on_tr))
  -- новая нота инструмента: +1 AI в её позиции
  local row = 40
  snap = model.build(4)
  local it = edit.insert_note(tr, 0, 4, row, 72, 100, 4, mother)
  local pos = it and R.GetMediaItemInfo_Value(it, 'D_POSITION')
  local found
  for k = 0, R.CountAutomationItems(env) - 1 do
    if math.abs(R.GetSetAutomationItemInfo(env, k, 'D_POSITION', 0, false) - (pos or -9)) < 1e-4 then found = k end
  end
  log(('insert C-5: ais=%d at note=%s len ai/note %.3f/%.3f'):format(R.CountAutomationItems(env), tostring(found ~= nil),
    found and R.GetSetAutomationItemInfo(env, found, 'D_LENGTH', 0, false) or -1, it and R.GetMediaItemInfo_Value(it, 'D_LENGTH') or -1))
  -- rate по высоте: C-5 → x2
  local slots = NM.slots(mother); slots[#slots].rate = true
  edit.nmod_update(mother, slots, 'rate on')
  for k = 0, R.CountAutomationItems(env) - 1 do
    if math.abs(R.GetSetAutomationItemInfo(env, k, 'D_POSITION', 0, false) - pos) < 1e-4 then found = k end
  end
  log(('rate on: ai rate %.3f (want 2)'):format(R.GetSetAutomationItemInfo(env, found, 'D_PLAYRATE', 0, false)))
  -- сдвиг ноты на строку: AI переезжает
  local n0 = R.CountAutomationItems(env)
  local dt = R.TimeMap2_QNToTime(0, 0.25)
  edit.run('move', function() R.SetMediaItemInfo_Value(it, 'D_POSITION', pos + dt) end)
  local at_new, at_old = 0, 0
  for k = 0, R.CountAutomationItems(env) - 1 do
    local p = R.GetSetAutomationItemInfo(env, k, 'D_POSITION', 0, false)
    if math.abs(p - pos - dt) < 1e-4 then at_new = at_new + 1 elseif math.abs(p - pos) < 1e-4 then at_old = at_old + 1 end
  end
  log(('move: ais %d->%d new=%d old=%d'):format(n0, R.CountAutomationItems(env), at_new, at_old))
  -- удаление ноты: AI уходит
  edit.run('del', function() R.DeleteTrackMediaItem(tr, it) end)
  log(('delete: ais=%d (want %d) err=%s'):format(R.CountAutomationItems(env), n0 - 1, tostring(edit.nm_err)))
  -- снять слот: AI всех нот уходят, остаётся ли пул у инструмента — нет (слота нет)
  edit.nmod_update(mother, {}, 'slot off')
  log(('slot off: ais=%d'):format(R.CountAutomationItems(env)))
  local t0 = R.time_precise(); local c = NM.census(); log(('census %.2f ms'):format((R.time_precise() - t0) * 1000))
end)
if not ok then log('ERR ' .. tostring(err)) end
done()
