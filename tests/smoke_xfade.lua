-- smoke_xfade.lua — x-fade вставленных нот и кроссфейд сейчас → ExtState jf_tracker/smoke
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
    local inst = R.GetTrackMediaItem(tr, 0)            -- любой аудио-item трека как инструмент
    local lpb = 4
    local base = 200                                   -- строки далеко за проектом
    local function last_two()
      local list = {}
      for i = 0, R.CountTrackMediaItems(tr) - 1 do
        local it = R.GetTrackMediaItem(tr, i)
        local p = R.GetMediaItemInfo_Value(it, 'D_POSITION')
        if p >= edit.row_time(base, lpb, 0) - 1e-6 then list[#list + 1] = it end
      end
      table.sort(list, function(a, b) return R.GetMediaItemInfo_Value(a, 'D_POSITION') < R.GetMediaItemInfo_Value(b, 'D_POSITION') end)
      return list
    end
    local function desc(list)
      local t = {}
      for _, it in ipairs(list) do
        t[#t + 1] = ('[%.3f+%.3f in %.3f/%.0f out %.3f/%.0f]'):format(
          R.GetMediaItemInfo_Value(it, 'D_POSITION') - edit.row_time(base, lpb, 0), R.GetMediaItemInfo_Value(it, 'D_LENGTH'),
          R.GetMediaItemInfo_Value(it, 'D_FADEINLEN'), R.GetMediaItemInfo_Value(it, 'D_FADEINLEN_AUTO') * 1000,
          R.GetMediaItemInfo_Value(it, 'D_FADEOUTLEN'), R.GetMediaItemInfo_Value(it, 'D_FADEOUTLEN_AUTO') * 1000)
      end
      return table.concat(t, ' ')
    end
    -- 1) x-fade выкл: нота, вторая на её продолжении после note-off — стык без кроссфейда
    edit.xfade.on = false
    edit.insert_note(tr, nil, lpb, base, 60, 100, 4, inst)
    local l = last_two(); edit.note_off({ { kind = 'audio', item = l[1] } }, lpb, base + 2)
    edit.insert_note(tr, nil, lpb, base + 2, 62, 100, 4, inst)
    log('off: ' .. desc(last_two()))
    -- 2) x-fade вкл 20 мс: третья нота на стыке со второй
    edit.xfade.on, edit.xfade.len = true, 0.020
    l = last_two(); edit.note_off({ { kind = 'audio', item = l[#l] } }, lpb, base + 4)
    edit.insert_note(tr, nil, lpb, base + 4, 64, 100, 4, inst)
    log('on 20ms: ' .. desc(last_two()))
    -- 3) кроссфейд сейчас 50 мс по всем трём
    local heads = {}
    for _, it in ipairs(last_two()) do heads[#heads + 1] = { kind = 'audio', item = it } end
    local n = edit.xfade_heads(heads, 0.050)
    log(('now 50ms (%d joins): '):format(n) .. desc(last_two()))
    for _ = 1, 6 do edit.undo() end
    log('undo → items in zone: ' .. #last_two())
  end)
  if not ok then log('ERR ' .. tostring(err)) end
end
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
