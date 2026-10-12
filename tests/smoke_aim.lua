-- smoke_aim.lua — прицел вживую (песочница): нота с разной скоростью / смещением, строка курсора при
-- LPB 4 и 12, сдвиг прицела, рез — правая часть начинается ровно с того места файла, что показывал прицел.
-- Отчёт → ExtState jf_tracker/smoke
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local A = dofile(DIR .. '/jf_tracker_aim.lua')
local out, bad = {}, 0
local function log(s) out[#out + 1] = s end
local _, pname = R.EnumProjects(-1, '')
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
if (pname and pname ~= '') or table.concat(names, ',') ~= 'A drums,B lanes,M synth,DEPOT' then R.SetExtState('jf_tracker', 'smoke', 'REFUSED', false); return end
local tr = R.GetTrack(0, 0)
local src0 = R.GetMediaItemTake_Source(R.GetActiveTake(R.GetTrackMediaItem(tr, 0)))
local file = R.GetMediaSourceFileName(src0, '')
local qn_sec = 60 / R.Master_GetTempo()
local function row_t(r, lpb) return R.TimeMap2_QNToTime(0, r / lpb) end
local cases = {
  { name = 'rate 1, from file start, LPB 4 row 5', pos = 8, offs = 0, rate = 1, len = 2, lpb = 4, row = 5, dt = 0 },
  { name = 'rate 1.122, LPB 4 row 5, +10.5 ms', pos = 8, offs = 0, rate = 1.122, len = 2, lpb = 4, row = 5, dt = 0.0105 },
  { name = 'offs 0.833 (another piece), LPB 12 row 3', pos = 8, offs = 0.833, rate = 1, len = 0.4, lpb = 12, row = 3, dt = 0 },
  { name = 'rate 0.5, LPB 12 row 7, -3 ms', pos = 8, offs = 0.2, rate = 0.5, len = 1.5, lpb = 12, row = 7, dt = -0.003 },
  { name = 'rate 2, LPB 4 row 2, +0.5 ms', pos = 8, offs = 0.1, rate = 2, len = 1, lpb = 4, row = 2, dt = 0.0005 },
}
local ok_all = true
R.Undo_BeginBlock2(0)
for _, c in ipairs(cases) do
  local it = R.AddMediaItemToTrack(tr)
  local tk = R.AddTakeToMediaItem(it)
  R.SetMediaItemTake_Source(tk, R.PCM_Source_CreateFromFile(file))
  R.SetMediaItemInfo_Value(it, 'D_POSITION', c.pos); R.SetMediaItemInfo_Value(it, 'D_LENGTH', c.len)
  R.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', c.offs); R.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', c.rate)
  local n = { pos = c.pos, offs = c.offs, rate = c.rate, len = c.len }
  local e = { offs = 0, rate = 1 }                                  -- окно — весь файл
  local trow = c.pos + row_t(c.row, c.lpb)                          -- верхняя кромка строки курсора внутри ноты
  local te = A.e_time(n, e, trow) + c.dt                            -- прицел + сдвиг
  local t = A.proj_of(n, e, te)
  local right = A.inside(n, t) and R.SplitMediaItem(it, t)
  if not right then log(c.name .. ': NO CUT'); bad = bad + 1
  else
    local roffs = R.GetMediaItemTakeInfo_Value(R.GetActiveTake(right), 'D_STARTOFFS')
    local rpos = R.GetMediaItemInfo_Value(right, 'D_POSITION')
    local want = e.offs + te * e.rate                               -- место файла под прицелом
    local d = math.abs(roffs - want)
    local okc = d < 1e-6 and math.abs(rpos - t) < 1e-9
    if not okc then bad = bad + 1 end
    log(('%s: aim %.6f s of the file, cut starts at %.6f (%s, %.2g s off)'):format(c.name, want, roffs, okc and 'ok' or 'BAD', d))
    R.DeleteTrackMediaItem(tr, right)
  end
  R.DeleteTrackMediaItem(tr, it)
end
R.Undo_EndBlock2(0, 'jf_tracker smoke aim', -1)
log(('%d case(s), %d bad'):format(#cases, bad))
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
