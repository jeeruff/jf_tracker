-- smoke_xfade2.lua — x-fade после ревью: аккорды не режутся, снятие возвращает длину → ExtState jf_tracker/smoke
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
    local inst = R.GetTrackMediaItem(tr, 0)
    local lpb, base = 4, 200
    local t0 = edit.row_time(base, lpb, 0)
    local function zone()
      local list = {}
      for i = 0, R.CountTrackMediaItems(tr) - 1 do
        local it = R.GetTrackMediaItem(tr, i)
        if R.GetMediaItemInfo_Value(it, 'D_POSITION') >= t0 - 1e-6 then list[#list + 1] = it end
      end
      table.sort(list, function(a, b) return R.GetMediaItemInfo_Value(a, 'D_POSITION') < R.GetMediaItemInfo_Value(b, 'D_POSITION') end)
      return list
    end
    local function d()
      local t = {}
      for _, it in ipairs(zone()) do t[#t + 1] = ('%.3f+%.3f(in%.3f,out%.3f)'):format(R.GetMediaItemInfo_Value(it, 'D_POSITION') - t0, R.GetMediaItemInfo_Value(it, 'D_LENGTH'), R.GetMediaItemInfo_Value(it, 'D_FADEINLEN'), R.GetMediaItemInfo_Value(it, 'D_FADEOUTLEN')) end
      return table.concat(t, ' ')
    end
    local function heads() local h = {}; for _, it in ipairs(zone()) do h[#h + 1] = { kind = 'audio', item = it } end; return h end
    -- аккорд: две ноты в одной строке (Shift+нота) при x-fade ON — ни одна не режется
    edit.xfade.on, edit.xfade.len = true, 0.020
    edit.insert_note(tr, nil, lpb, base, 60, 100, 4, inst)
    edit.insert_note(tr, nil, lpb, base, 64, 100, 4, inst)
    log('chord ON: ' .. d())
    log('now 50ms on chord joins=' .. edit.xfade_heads(heads(), 0.05) .. ': ' .. d())
    -- последование: note-off + следующая — кроссфейд; снятие возвращает длину
    for _ = 1, 3 do edit.undo() end
    edit.insert_note(tr, nil, lpb, base, 60, 100, 4, inst)
    local l = zone(); edit.note_off({ { kind = 'audio', item = l[1] } }, lpb, base + 2)
    edit.insert_note(tr, nil, lpb, base + 2, 62, 100, 4, inst)
    log('seq ON 20ms: ' .. d())
    log('remove joins=' .. edit.xfade_heads(heads(), 0) .. ': ' .. d())
    for _ = 1, 4 do edit.undo() end
    log('undo → zone items: ' .. #zone())
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
