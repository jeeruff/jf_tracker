-- smoke_cmds.lua — команды-огибающие/генераторы живьём → ExtState jf_tracker/smoke
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
local CM = dofile(DIR .. '/jf_tracker_cmds.lua')
edit.init(model); CM.init(model); edit.cmds = CM
local ok, err = pcall(function()
  local snap = model.build(4)
  local col, head
  for _, c in ipairs(snap.cols) do
    for _, lane in ipairs(c.lanes) do for _, sub in ipairs(lane.subs) do
      for r, cell in pairs(sub) do
        if cell.kind == 'audio' and (cell.rows or 1) >= 4 and (not head or r < head.row0 or c ~= col) then if not head then head, col = cell, c end end
      end
    end end
  end
  log('head=' .. tostring(head and head.name) .. ' rows=' .. tostring(head and head.rows) .. ' col=' .. tostring(col and col.name))
  if not head then return end
  local it, tk = head.item, head.take
  -- 0U08: питч вверх 0.5 полутона/строку
  edit.set_fx({ head }, 4, '0U', 8)
  local penv = R.GetTakeEnvelopeByName(tk, 'Pitch')
  local len = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
  local n = penv and R.CountEnvelopePoints(penv) or -1
  local _, v_end = penv and R.Envelope_Evaluate(penv, len * R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE') - 1e-4, 0, 0) or nil, 0
  if penv then local _, v = R.Envelope_Evaluate(penv, len - 1e-4, 0, 0); v_end = v end
  log(('0U08: pitch env=%s points=%d end=%.2f (rows %d → expect %.2f, clamp 3)'):format(tostring(penv ~= nil), n, v_end or -99, head.rows, 0.5 * head.rows))
  local _, cm = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_cmds', '', false); log('stored=' .. cm)
  -- 4xy vibrato
  edit.set_fx({ head }, 4, '0V', 0x48)
  log('4 48: points=' .. R.CountEnvelopePoints(penv))
  -- A slide: +2/16 per row
  edit.set_fx({ head }, 4, '0I', 0x20)
  local venv = R.GetTakeEnvelopeByName(tk, 'Volume')
  log('A20: vol env=' .. tostring(venv ~= nil) .. ' points=' .. tostring(venv and R.CountEnvelopePoints(venv)))
  -- R: retrigger every 4/16 row, decay 2/16
  local n0 = R.CountTrackMediaItems(col.track)
  edit.set_fx({ head }, 4, '0R', 0x24)
  local n1 = R.CountTrackMediaItems(col.track)
  log(('0R24: items %d→%d len=%.3f'):format(n0, n1, R.GetMediaItemInfo_Value(it, 'D_LENGTH')))
  edit.clear_fx({ head }, 4, '0R')
  log(('R cleared: items %d'):format(R.CountTrackMediaItems(col.track)))
  -- ZT: tempo marker 0x80 = 128
  local tm0 = R.CountTempoTimeSigMarkers(0)
  edit.set_fx({ head }, 4, 'ZT', 0x80)
  log(('F80: tempo markers %d→%d'):format(tm0, R.CountTempoTimeSigMarkers(0)))
  edit.clear_fx({ head }, 4, 'ZT')
  local _, cm2 = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_cmds', '', false); log('stored now=' .. cm2)
  -- MIDI U: pitchbend
  local mh
  for _, c in ipairs(snap.cols) do for _, lane in ipairs(c.lanes) do for _, sub in ipairs(lane.subs) do
    for r, cell in pairs(sub) do if cell.kind == 'midi' and not mh then mh = cell end end
  end end end
  if mh then
    edit.set_fx({ mh }, 4, '0U', 0x10)
    local _, _, ncc = R.MIDI_CountEvts(mh.take)
    local pb = 0
    for i = 0, ncc - 1 do local _, _, _, _, typ = R.MIDI_GetCC(mh.take, i); if typ == 0xE0 then pb = pb + 1 end end
    log('MIDI U10: pitchbend events=' .. pb)
  end
  model.invalidate(); snap = model.build(4)
  for _, c2 in ipairs(snap.cols) do for _, lane in ipairs(c2.lanes) do for _, sub in ipairs(lane.subs) do
    local c = sub[head.row0]; if c and c.kind == 'audio' and c.item == it then log('fx shown: ' .. table.concat(c.fx, ',') .. ' len=' .. ('%.3f'):format(c.len)) end
  end end end
  log('tempo markers now=' .. R.CountTempoTimeSigMarkers(0))
  log('undo=' .. tostring(R.Undo_CanUndo2(0)))
end)
if not ok then log('ERR ' .. tostring(err)) end
done()
