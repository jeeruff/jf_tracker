-- smoke_spec_retro.lua — мост спектра (jf_tracker_scope на мастере, слот 31) и jf_rec → ExtState jf_tracker/smoke
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out = {}
local function log(s) out[#out + 1] = s end
local _, pname = R.EnumProjects(-1, '')
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
if (pname and pname ~= '') or not (table.concat(names, ','):find('A drums', 1, true) and table.concat(names, ','):find('B lanes', 1, true) and table.concat(names, ','):find('M synth', 1, true)) then log('REFUSED'); R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false); return end
local model = dofile(DIR .. '/jf_tracker_model.lua')
local edit = dofile(DIR .. '/jf_tracker_edit.lua'); edit.init(model)
local mt = R.GetMasterTrack(0)
local fx = R.TrackFX_GetByName(mt, 'jf_tracker_scope', false)
if fx < 0 then fx = R.TrackFX_AddByName(mt, 'jf_tracker_scope', false, -1); R.TrackFX_SetParam(mt, fx, 0, 31) end
log('master scope fx=' .. fx)
local tr = R.GetTrack(0, 1)   -- B lanes: незаглушённые аудио-items на тактах 9-10
local rfx = R.TrackFX_GetByName(tr, 'jf_rec', false)
local ok, slot = edit.retro_add(tr, {})
log(('jf_rec add ok=%s slot=%s (had=%d)'):format(tostring(ok), tostring(slot), rfx))
-- играем 1.5 с, читаем
R.SetEditCurPos(R.TimeMap2_QNToTime(0, 32.5), false, false)   -- B lanes items (строки 128..144 = QN 32..36)
R.OnPlayButton()
local t0 = R.time_precise()
local function later()
  if R.time_precise() - t0 < 1.5 then R.defer(later); return end
  R.OnStopButton()
  R.gmem_attach('jf_tracker_scope')
  local base = 31 * 512
  local hb, fr = R.gmem_read(base + 257), R.gmem_read(base + 259)
  local mx, nz = 0, 0
  for i = 0, 47 do local v = R.gmem_read(base + 260 + i); if v > mx then mx = v end; if v > 0.05 then nz = nz + 1 end end
  log(('scope31 hb=%d frames=%d bands>0.05=%d max=%.2f'):format(hb, fr, nz, mx))
  R.gmem_attach('jf_rec')
  local s = math.floor(R.TrackFX_GetParam(tr, R.TrackFX_GetByName(tr, 'jf_rec', false), 1))
  R.gmem_write(26, s); R.gmem_write(4, 200)
  local t1 = R.time_precise()
  local function later2()
    if R.time_precise() - t1 < 0.5 then R.defer(later2); return end
    R.gmem_attach('jf_rec')
    local alive, srate, len, head, writing = R.gmem_read(30), R.gmem_read(0), R.gmem_read(1), R.gmem_read(2), R.gmem_read(3)
    local pk = 0; for i = 0, 199 do pk = math.max(pk, math.abs(R.gmem_read(1000000 + i) or 0)) end
    log(('jf_rec slot=%d owner=%d alive=%s srate=%d len=%d head=%.3f writing=%d peakmax=%.3f'):format(s, R.gmem_read(26), tostring(alive), srate, len, head, writing, pk))
    R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
  end
  later2()
end
later()
