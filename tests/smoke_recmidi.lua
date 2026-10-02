-- smoke_recmidi.lua — E.rec_note / E.rec_cc: аккорд, velocity, aftertouch → ExtState jf_tracker/smoke
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
    local tr; for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); if n == 'M synth' then tr = R.GetTrack(0, i) end end
    local lpb, row = 4, 300
    local n0 = R.CountTrackMediaItems(tr)
    edit.rec_note(tr, nil, lpb, row, 60, 101, 2)
    edit.rec_note(tr, nil, lpb, row, 64, 77, 2)
    edit.rec_note(tr, nil, lpb, row, 67, 55, 2)
    local t0 = edit.row_time(row, lpb, 0)
    edit.rec_cc(tr, nil, t0 + 0.05, 0xD0, 0, 90, 0)
    edit.rec_cc(tr, nil, t0 + 0.10, 0xA0, 0, 64, 70)
    -- прочитать
    local it
    for i = 0, R.CountTrackMediaItems(tr) - 1 do
      local x = R.GetTrackMediaItem(tr, i)
      local p = R.GetMediaItemInfo_Value(x, 'D_POSITION')
      if t0 >= p and t0 < p + R.GetMediaItemInfo_Value(x, 'D_LENGTH') then it = x end
    end
    local tk = R.GetActiveTake(it)
    local _, nn, nc = R.MIDI_CountEvts(tk)
    local notes = {}
    for k = 0, nn - 1 do local _, _, _, sp, ep, ch, p, v = R.MIDI_GetNote(tk, k); notes[#notes + 1] = p .. '/' .. v end
    local ccs = {}
    for k = 0, nc - 1 do local _, _, _, pp, cm, ch, m2, m3 = R.MIDI_GetCC(tk, k); ccs[#ccs + 1] = ('%X:%d,%d'):format(cm, m2, m3) end
    log(('items %d→%d notes=%s cc=%s'):format(n0, R.CountTrackMediaItems(tr), table.concat(notes, ' '), table.concat(ccs, ' ')))
    -- раскладка модели: аккорд — три подколонки в одной строке
    local snap = model.build(lpb)
    for _, c in ipairs(snap.cols) do
      if c.track == tr then
        local subs = 0
        for _, lane in ipairs(c.lanes) do for _, sub in ipairs(lane.subs) do if sub[row] then subs = subs + 1 end end end
        log('subcolumns with a head at row ' .. row .. ': ' .. subs)
      end
    end
    for _ = 1, 3 do edit.undo() end
    log('undo → items ' .. R.CountTrackMediaItems(tr))
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
