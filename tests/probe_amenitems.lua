-- probe_amenitems.lua — только чтение: items трека amen в amen_galore (позиция, длина, offs, rate, строки LPB 12)
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out = {}
local _, pname = R.EnumProjects(-1, '')
if not (pname or ''):find('amen_galore', 1, true) then out[1] = 'REFUSED ' .. tostring(pname) else
  for i = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, i); local _, nm = R.GetTrackName(tr)
    if nm == 'amen' then
      for k = 0, R.CountTrackMediaItems(tr) - 1 do
        local it = R.GetTrackMediaItem(tr, k); local tk = R.GetActiveTake(it)
        local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
        local row = R.TimeMap2_timeToQN(0, pos) * 12
        if row < 60 then
          out[#out + 1] = ('row %.2f pos %.4f len %.4f lane %d offs %.4f rate %.3f %s'):format(row, pos, R.GetMediaItemInfo_Value(it, 'D_LENGTH'),
            R.GetMediaItemInfo_Value(it, 'I_FIXEDLANE'), R.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS'), R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE'),
            R.GetMediaSourceFileName(R.GetMediaItemTake_Source(tk), ''):match('[^/]+$'))
        end
      end
    end
  end
end
local f = io.open(DIR .. '/tests/shots/probe_amenitems.txt', 'w'); f:write(table.concat(out, '\n') .. '\n'); f:close()
