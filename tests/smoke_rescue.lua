-- smoke_rescue.lua — страховка сэмплов (13 окт): удалены все ноты файла на треке — в LIB встаёт
-- сам инструмент (chunk самой длинной ноты: нарезка, метки), а не голый файл (песочница) → ExtState jf_tracker/smoke
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out, bad = {}, 0
local function log(s) out[#out + 1] = s end
local function check(name, cond, info) if not cond then bad = bad + 1 end; log((cond and 'ok ' or 'BAD ') .. name .. (info and (' (' .. info .. ')') or '')) end
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
local _, pname = R.EnumProjects(-1, '')
if (pname and pname ~= '') or table.concat(names, ',') ~= 'A drums,B lanes,M synth,DEPOT' then R.SetExtState('jf_tracker', 'smoke', 'REFUSED', false); return end
local PAD = os.getenv('HOME') .. '/samples/LegoweltYamahaSY35sampleKit/Synth-VectorPad.wav'
local ok, err = pcall(function()
  local model = dofile(DIR .. '/jf_tracker_model.lua')
  local edit = dofile(DIR .. '/jf_tracker_edit.lua'); edit.init(model)
  edit.keep_samples = true
  local tr = R.GetTrack(0, 2)
  local function add(pos, len)
    local it = R.AddMediaItemToTrack(tr); local tk = R.AddTakeToMediaItem(it)
    R.SetMediaItemTake_Source(tk, R.PCM_Source_CreateFromFile(PAD))
    R.SetMediaItemInfo_Value(it, 'D_POSITION', pos); R.SetMediaItemInfo_Value(it, 'D_LENGTH', len)
    return it
  end
  local mother = add(1.0, 3.0)
  R.GetSetMediaItemInfo_String(mother, 'P_EXT:jf_slices', '0.5 1.0 1.5', true)
  R.GetSetMediaItemInfo_String(mother, 'P_EXT:jf_iid', 'SMOKE1', true)
  add(5.0, 0.5)
  local function libcount()
    local lt = edit.lib_track(false); local n, sl = 0, nil
    if lt then for i = 0, R.CountTrackMediaItems(lt) - 1 do
      local it = R.GetTrackMediaItem(lt, i)
      local _, h = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_home', '', false)
      if h == model.track_guid(tr) then n = n + 1; local _, s = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slices', '', false); sl = s end
    end end
    return n, sl
  end
  local n0 = libcount()
  edit.run('delete all', function() for i = R.CountTrackMediaItems(tr) - 1, 0, -1 do R.DeleteTrackMediaItem(tr, R.GetTrackMediaItem(tr, i)) end end)
  local n1, sl = libcount()
  check('the sample went to the lib', n1 == n0 + 1, n0 .. ' -> ' .. n1)
  check('  as the instrument: the slices kept (the longest note)', sl == '0.5 1.0 1.5', sl)
  check('  once (no duplicate)', n1 == n0 + 1)
end)
if not ok then log('ERR ' .. tostring(err)); bad = bad + 1 end
log(bad .. ' bad')
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
