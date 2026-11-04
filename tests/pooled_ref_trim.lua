-- прежний A.trim (до 2 окт) — эталон для tests/test_pooled.lua
local R = reaper
local EPS = 1e-6
local function tracks()
  local out = {}
  for ti = 0, R.CountTracks(0) - 1 do out[#out + 1] = R.GetTrack(0, ti) end
  return out
end
local function items_in(tr, t0, t1)
  local out = {}
  for i = 0, R.CountTrackMediaItems(tr) - 1 do
    local it = R.GetTrackMediaItem(tr, i)
    local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
    if pos >= t0 - EPS and pos < t1 - EPS then out[#out + 1] = it end
  end
  return out
end
return function(regions)
  local n = 0
  local trs = tracks()
  for _, rg in ipairs(regions) do
    if not rg.lib then
      for _, tr in ipairs(trs) do
        -- 1) входящие из-за начала — разрезать на границе
        for i = R.CountTrackMediaItems(tr) - 1, 0, -1 do
          local it = R.GetTrackMediaItem(tr, i)
          local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
          local fin = pos + R.GetMediaItemInfo_Value(it, 'D_LENGTH')
          if pos < rg.pos - EPS and fin > rg.pos + EPS then
            if R.SplitMediaItem(it, rg.pos) then n = n + 1 end
          end
        end
        -- 2) начинающиеся внутри и вылезающие за конец — укоротить
        for _, it in ipairs(items_in(tr, rg.pos, rg.rgnend)) do
          local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
          local fin = pos + R.GetMediaItemInfo_Value(it, 'D_LENGTH')
          if fin > rg.rgnend + EPS then
            R.SetMediaItemInfo_Value(it, 'D_LENGTH', rg.rgnend - pos)
            n = n + 1
          end
        end
      end
    end
  end
  return n
end

