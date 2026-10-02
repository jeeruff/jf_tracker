-- smoke_dspmove.lua — порядок FX при E.fx_move и контейнер в M.track_fx → ExtState jf_tracker/smoke
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
    local tr = R.GetTrack(0, 2)   -- M synth
    local function chain() local t = {}; for i = 0, R.TrackFX_GetCount(tr) - 1 do local _, n = R.TrackFX_GetFXName(tr, i, ''); t[#t + 1] = (n:gsub('^[^:]*: ', '')):sub(1, 10) end; return table.concat(t, ',') end
    local n0 = R.TrackFX_GetCount(tr)
    -- добавим ReaEQ и ReaComp в конец, переставим ReaComp на место 0
    local a = R.TrackFX_AddByName(tr, 'ReaEQ', false, -1)
    local b = R.TrackFX_AddByName(tr, 'ReaComp', false, -1)
    log('before: ' .. chain())
    edit.fx_move(tr, b, 0)
    log('move last→0: ' .. chain())
    edit.fx_move(tr, 0, R.TrackFX_GetCount(tr) - 1)
    log('move 0→last: ' .. chain())
    -- контейнер: добавить и перенести ReaEQ внутрь
    local c = R.TrackFX_AddByName(tr, 'Container', false, -1)
    local cnt = R.TrackFX_GetCount(tr)
    local eq = -1; for i = 0, cnt - 1 do local _, n = R.TrackFX_GetFXName(tr, i, ''); if n:find('ReaEQ') then eq = i end end
    -- адрес ребёнка 0 контейнера c: 0x2000000 + (c+1) + (0+1)*(cnt+1)
    local dest = 0x2000000 + (c + 1) + 1 * (cnt + 1)
    local okm = R.TrackFX_CopyToTrack(tr, eq, tr, dest, true)
    local fxs = model.track_fx(tr)
    for _, f in ipairs(fxs) do
      if f.container then log(('container %s kids=%d: %s params=%d'):format(f.name, #f.kids, (function() local t = {}; for _, k in ipairs(f.kids) do t[#t + 1] = k.name .. '/par' .. k.parallel end; return table.concat(t, ' ') end)(), #f.params)) end
    end
    log('chain now: ' .. chain())
    -- откат всего
    for _ = 1, 6 do edit.undo() end
    log('after undo: ' .. chain() .. ' n=' .. R.TrackFX_GetCount(tr) .. ' (was ' .. n0 .. ')')
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
