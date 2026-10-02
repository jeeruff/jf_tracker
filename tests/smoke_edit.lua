-- smoke_edit.lua — живой прогон правок Vim-слоя на РЕАЛЬНОМ проекте-песочнице.
-- Отказывается работать, если текущий проект не песочница sandbox_setup.lua
-- (имя файла не пустое или треки не A drums / B lanes / M synth / DEPOT).
-- Раскладку строит без gfx (плоский список из снимка). Результат —
-- ExtState jf_tracker/smoke (коротко: лимит веб-интерфейса ~995 символов).

local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local EXT = 'jf_tracker'
local out = {}
local function log(s) out[#out + 1] = s end
local function done() R.SetExtState(EXT, 'smoke', table.concat(out, ' | '), false) end

local _, pname = R.EnumProjects(-1, '')
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
if (pname and pname ~= '') or not (table.concat(names, ','):find('A drums', 1, true) and table.concat(names, ','):find('B lanes', 1, true) and table.concat(names, ','):find('M synth', 1, true)) then
  log('REFUSED: not sandbox (' .. tostring(pname) .. ' / ' .. table.concat(names, ',') .. ')'); done(); return
end

local model = dofile(DIR .. '/jf_tracker_model.lua')
local edit = dofile(DIR .. '/jf_tracker_edit.lua')
local vim = dofile(DIR .. '/jf_tracker_vim.lua')
local keys = dofile(DIR .. '/jf_tracker_keys.lua')
edit.init(model)

local state = { lpb = 4, row0 = 0, hscroll = 1, folds = {}, follow = false, fxcols = 2 }
local pitchmodes = {}
local snap, L
local function relayout()
  snap = model.snapshot(state.lpb)
  L = { nrows = 32, win_w = 10000, flat = {} }
  for ci, col in ipairs(snap.cols) do
    for li, lane in ipairs(col.lanes) do
      for si, sub in ipairs(lane.subs) do
        L.flat[#L.flat + 1] = { ci = ci, col = col, lane = lane, li = li, si = si, sub = sub, x = 0, w = 10 }
      end
    end
  end
end
relayout()
vim.init({
  edit = edit, state = state, piano = keys.piano,
  snap = function() return snap end, layout = function() return L end, relayout = relayout,
  bar_of_row = function(row) return model.bar_of_row(row, state.lpb) end,
  row_time = function(row) return edit.row_time(row, state.lpb, 0) end,
  set_lpb = function() end, fold = function() end, fold_all = function() end,
  depot = function() return edit.depot_items() end, toggle_focus = function() end,
  set_pitchmode = function(col, m) pitchmodes[col.guid] = m end,
  sync_here = function() return 0 end,
})
edit.pitch_mode = function(head)
  local tr = head.item and R.GetMediaItem_Track(head.item)
  return (tr and pitchmodes[model.track_guid(tr)]) or 'shift'
end
local function keysin(s) for ch in s:gmatch('.') do vim.key(ch:byte()); relayout() end end
local function items() return R.CountMediaItems(0) end
local function notes()
  local tr = R.GetTrack(0, 2); local it = R.GetTrackMediaItem(tr, 0)
  local _, n = R.MIDI_CountEvts(R.GetActiveTake(it)); return n
end
local function first_pitch() -- D_PITCH первого item трека A
  local it = R.GetTrackMediaItem(R.GetTrack(0, 0), 0)
  return R.GetMediaItemTakeInfo_Value(R.GetActiveTake(it), 'D_PITCH')
end
local function goto_(fi, row) vim.cur.fi, vim.cur.row = fi, row; vim.mode = 'normal' end

local ok, err = pcall(function()
  local i0, n0 = items(), notes()
  log(('start items=%d notes=%d'):format(i0, n0))
  -- x на kick (A sub1 row 0) → −1 item; u → назад
  goto_(1, 0); keysin('x'); log('x:' .. items())
  keysin('u'); log('u:' .. items())
  -- yy + p на строку 40 → +1
  goto_(1, 0); keysin('yy'); goto_(1, 40); keysin('p'); log('p@40:' .. items())
  -- s разрез snare (row 3, sub2 = fi 2) по строке 4 → +1
  goto_(2, 4); keysin('s'); log('s:' .. items())
  -- ^A на kick → D_PITCH +2
  goto_(1, 0); keysin('2'); vim.key(1); relayout(); log(('^A pitch=%.1f'):format(first_pitch()))
  -- m mute kick
  keysin('m'); relayout(); log('m muted=' .. tostring(snap.cols[1].lanes[1].subs[1][0].muted))
  -- MIDI: x на C-4 (M synth row 16) → −1 нота; u
  local fm; for i, f in ipairs(L.flat) do if f.col.name == 'M synth' then fm = i; break end end
  goto_(fm, 16); keysin('x'); log('midi x:' .. notes())
  keysin('u'); relayout(); log('midi u:' .. notes())
  -- insert: i z на M synth row 30 → +1 нота (item накрывает 2 такта = строки 16..31)
  goto_(fm, 30); keysin('iz'); vim.key(27); relayout(); log('midi iz:' .. notes())
  -- note-off: строка 31 режет ноту с 30
  goto_(fm, 31); keysin('i1'); vim.key(27); relayout()
  local c31 = snap.cols[3].lanes[1].subs[1][31]
  log('off@31:' .. tostring(c31 and c31.kind))
  -- V-line delete rows 40..41 → удалит вставленную копию kick
  goto_(1, 40); keysin('Vjd'); log('Vjd:' .. items())
  -- поля: vol 7F на kick, delay 80, команда 8FF (pan R), 9 40 (offset), S 10 (beatsync 16 строк)
  goto_(1, 0); vim.cur.field = 2; keysin('i7f'); vim.key(27); relayout()
  local k = snap.cols[1].lanes[1].subs[1][0]; log('vol:' .. tostring(k and k.vol))
  goto_(1, 0); vim.cur.field = 3; keysin('i80'); vim.key(27); relayout()
  k = snap.cols[1].lanes[1].subs[1][0]; log('delay@0:' .. tostring(k and k.delay))
  goto_(1, 0); vim.cur.field = 4; keysin('i8ff'); vim.key(27); relayout()
  k = snap.cols[1].lanes[1].subs[1][0]; log('fx:' .. table.concat(k and k.fx or {}, ','))
  goto_(1, 0); vim.cur.field = 4; keysin('is10'); vim.key(27); relayout()
  k = snap.cols[1].lanes[1].subs[1][0]; log('beatsync rows=' .. tostring(k and k.rows) .. ' fx=' .. table.concat(k and k.fx or {}, ','))
  -- resample: D_PLAYRATE вместо D_PITCH
  goto_(1, 0); vim.cur.field = 1; keysin(':pitchmode resample'); vim.key(13); keysin('2'); vim.key(1); relayout()
  k = snap.cols[1].lanes[1].subs[1][0]
  log(('resample rate=%.3f note=%s'):format(R.GetMediaItemTakeInfo_Value(R.GetActiveTake(R.GetTrackMediaItem(R.GetTrack(0, 0), 0)), 'D_PLAYRATE'), tostring(k and k.note)))
  -- матрица: mute_span всех items A в [0, 1 с)
  edit.mute_span(R.GetTrack(0, 0), 0, 1.0, true); relayout()
  log('span muted=' .. tostring(snap.cols[1].lanes[1].subs[1][0].muted))
  log(('end items=%d notes=%d undo=%s'):format(items(), notes(), tostring(R.Undo_CanUndo2(0))))
end)
if not ok then log('ERR ' .. tostring(err)) end
done()
