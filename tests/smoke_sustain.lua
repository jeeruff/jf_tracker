-- smoke_sustain.lua — луп удержания вживую (песочница): поиск точек на пэде, голова + хвост,
-- звук шва (аксессор), укорочение / рез / удаление, модель видит одну ноту. → ExtState jf_tracker/smoke
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
  model.SU = edit.SU
  local G = dofile(DIR .. '/jf_tracker_sgram.lua')
  local tr = R.GetTrack(0, 0)
  local P0 = 2.0                                   -- до =END (6 с)
  -- 1. поиск точек на пэде
  local fr, sr, flen = G.wav_reader(PAD)
  check('pad readable', fr ~= nil)
  local span = math.min(flen, 4)
  local x = fr(0, math.floor(span * sr))
  local t0 = R.time_precise()
  local f, why = edit.SU.find(x, sr, 1, #x)
  check('find on the pad', f ~= nil, why or ('%.3f - %.3f s, match %.3f, %.0f ms'):format((f.ls - 1) / sr, (f.le - 1) / sr, f.match, (R.time_precise() - t0) * 1000))
  local ls, le = f and (f.ls - 1) / sr or 0.5, f and (f.le - 1) / sr or 1.0
  -- 2. нота-инструмент: пэд с начала файла, 3.5 с
  local it = R.AddMediaItemToTrack(tr)
  local tk = R.AddTakeToMediaItem(it)
  R.SetMediaItemTake_Source(tk, R.PCM_Source_CreateFromFile(PAD))
  R.SetMediaItemInfo_Value(it, 'D_POSITION', P0); R.SetMediaItemInfo_Value(it, 'D_LENGTH', 3.5)
  R.SetMediaItemInfo_Value(it, 'B_LOOPSRC', 1)
  edit.sus_set({ it }, { on = true, ls = ls, le = le, xf = 0.01 })
  local function tails()
    local t = {}
    for i = 0, R.CountTrackMediaItems(tr) - 1 do
      local o = R.GetTrackMediaItem(tr, i)
      if edit.sus_ext(o, 'P_EXT:jf_susof') ~= '' then t[#t + 1] = o end
    end
    return t
  end
  local tl = tails()
  check('one tail', #tl == 1, #tl .. ' tails')
  tk = R.GetActiveTake(it)
  local hs, hso, hsl = R.PCM_Source_GetSectionInfo(R.GetMediaItemTake_Source(tk))
  check('head = section [0, ls) without loop', hs and math.abs(hso) < 1e-7 and math.abs(hsl - ls) < 1e-6 and R.GetMediaItemInfo_Value(it, 'B_LOOPSRC') == 0, ('%.4f %.4f'):format(hso or -1, hsl or -1))
  if tl[1] then
    local t = tl[1]
    local tt = R.GetActiveTake(t)
    local _, so, sl = R.PCM_Source_GetSectionInfo(R.GetMediaItemTake_Source(tt))
    local _, ch = R.GetItemStateChunk(t, '', false)
    check('tail at ls, to the note end', math.abs(R.GetMediaItemInfo_Value(t, 'D_POSITION') - (P0 + ls)) < 1e-6 and math.abs(R.GetMediaItemInfo_Value(t, 'D_LENGTH') - (3.5 - ls)) < 1e-6)
    check('tail = looped section [ls, le) with OVERLAP', math.abs(so - ls) < 1e-6 and math.abs(sl - (le - ls)) < 1e-6 and R.GetMediaItemInfo_Value(t, 'B_LOOPSRC') == 1 and ch:find('OVERLAP 0.01', 1, true) ~= nil)
    -- звук: хвост в начале = файл в ls; голова после ls молчит
    local function rd(take, at, n)
      local acc = R.CreateTakeAudioAccessor(take); local a = R.new_array(n); a.clear()
      R.GetAudioAccessorSamples(acc, sr, 1, at, n, a); R.DestroyAudioAccessor(acc); return a.table()
    end
    local a, b = rd(tt, 0.001, 256), fr(ls + 0.001, 256)
    local d = 0; for i = 1, 256 do d = d + math.abs(a[i] - b[i]) end
    check('the tail starts with the file at ls (seamless with the head)', d / 256 < 1e-3, ('%.5f'):format(d / 256))
    local hsil = rd(tk, ls + 0.05, 512); local e = 0; for i = 1, 512 do e = e + math.abs(hsil[i]) end
    check('the head is silent after ls', e < 1e-6, ('%.6f'):format(e))
  end
  -- 2b. 13 окт: запечённый луп — хвост играет файл с кроссфейдом, шов без скачка
  do
    local SU = edit.SU
    local w = SU.wav_read(PAD, math.ceil(le * sr) + 2)
    local lsf, lef, X0 = math.floor(ls * sr + 0.5), math.floor(le * sr + 0.5), math.floor(0.03 * sr)
    local chs, X = SU.bake(w.ch, lsf, lef, X0)
    local out = R.GetResourcePath() .. '/jf_tracker_smoke_baked.wav'
    check('bake written', SU.wav_write(out, sr, chs))
    edit.sus_set({ it }, { on = true, ls = ls, le = le, xf = 0.03, file = out, boff = X / sr })
    local t = tails()[1]
    local src = t and R.GetMediaItemTake_Source(R.GetActiveTake(t))
    local par = src and (R.GetMediaSourceParent(src) or src)
    check('baked: the tail plays the baked file', par and R.GetMediaSourceFileName(par, '') == out, par and R.GetMediaSourceFileName(par, '') or 'no tail')
    if t then
      local per = (lef - lsf) / sr
      local acc = R.CreateTakeAudioAccessor(R.GetActiveTake(t)); local a = R.new_array(64); a.clear()
      R.GetAudioAccessorSamples(acc, sr, 1, per - 32 / sr, 64, a); R.DestroyAudioAccessor(acc)
      local v = a.table()
      local jump, step = math.abs(v[33] - v[32]), 0
      for i = 2, 31 do step = math.max(step, math.abs(v[i] - v[i - 1])) end
      check('baked: the seam is like a normal step', jump <= step * 1.5 + 1e-4, ('jump %.4f step %.4f'):format(jump, step))
    end
    edit.sus_set({ it }, { on = true, ls = ls, le = le, xf = 0.01 })
  end
  -- 3. модель: одна нота на всю длину, хвоста в колонке нет
  model.invalidate()
  local snap = model.build(4)
  local col = snap.cols[1]
  local heads, longest = 0, 0
  for _, sub in ipairs(col.lanes[1].subs) do
    for _, c in pairs(sub) do if c.item == it or (c.kind == 'audio' and c.item and edit.sus_ext(c.item, 'P_EXT:jf_susof') ~= '') then heads = heads + 1; longest = math.max(longest, c.rows or 0) end end
  end
  check('model: one head, the whole note, the tail hidden', heads == 1 and longest >= 3.5 * 2 * 4 - 1, heads .. ' heads, ' .. longest .. ' rows')
  local inpool = false
  for _, pe in ipairs(col.pool or {}) do if edit.sus_ext(pe.item, 'P_EXT:jf_susof') ~= '' then inpool = true end end
  check('model: the tail is not an instrument', not inpool)
  -- 4. длину не трогали — хвост тот же (без пересоздания)
  local t_before = tails()[1]
  edit.run('touch', function() end)
  check('no rebuild when nothing changed', tails()[1] == t_before)
  -- 5. рез внутри лупа: две головы, два хвоста, правый — с фазой
  local right
  edit.run('split', function() right = R.SplitMediaItem(it, P0 + ls + (3.5 - ls) * 0.6) end)
  tl = tails()
  check('split: two tails', #tl == 2, #tl .. '')
  -- 6. укоротить левую до атаки: её хвост уходит, голова снова файл
  edit.run('short', function() R.SetMediaItemInfo_Value(it, 'D_LENGTH', ls * 0.5) end)
  tk = R.GetActiveTake(it)
  local st2 = R.GetMediaSourceType(R.GetMediaItemTake_Source(tk), '')
  check('short note: tail gone, head plays the file again, loop stays off (sustain or loop)', #tails() == 1 and st2 ~= 'SECTION' and R.GetMediaItemInfo_Value(it, 'B_LOOPSRC') == 0, #tails() .. ' ' .. st2)
  -- 7. удалить правую голову — её хвост тоже
  edit.run('del', function() if right then R.DeleteTrackMediaItem(tr, right) end end)
  check('delete: orphan tail removed', #tails() == 0)
  -- 8. длина вставки: до конца региона / следующей ноты
  local rid = R.AddProjectMarker2(0, true, P0, P0 + 3, 'SUSTEST', -1, 0)
  local n2
  edit.run('ins', function()
    n2 = R.AddMediaItemToTrack(tr); local k2 = R.AddTakeToMediaItem(n2)
    R.SetMediaItemTake_Source(k2, R.PCM_Source_CreateFromFile(PAD))
    R.SetMediaItemInfo_Value(n2, 'D_POSITION', P0 + 0.5); R.SetMediaItemInfo_Value(n2, 'D_LENGTH', 0.4)
    R.GetSetMediaItemInfo_String(n2, 'P_EXT:jf_loop', edit.SU.tag({ on = true, ls = ls, le = le, xf = 0.01 }), true)
    edit.sus_extend(tr, nil, n2)
  end)
  local nx
  for i = 0, R.CountTrackMediaItems(tr) - 1 do local o = R.GetTrackMediaItem(tr, i); local op = R.GetMediaItemInfo_Value(o, 'D_POSITION'); if o ~= n2 and op > P0 + 0.5 and (not nx or op < nx) and edit.sus_ext(o, 'P_EXT:jf_susof') == '' then nx = op end end
  local want = math.min(P0 + 3, nx or math.huge)
  check('a sustained note lasts to the next note / the region end', math.abs(R.GetMediaItemInfo_Value(n2, 'D_POSITION') + R.GetMediaItemInfo_Value(n2, 'D_LENGTH') - want) < 1e-6,
    ('end %.3f want %.3f'):format(R.GetMediaItemInfo_Value(n2, 'D_POSITION') + R.GetMediaItemInfo_Value(n2, 'D_LENGTH'), want))
  -- уборка
  edit.run('cleanup', function()
    for i = R.CountTrackMediaItems(tr) - 1, 0, -1 do
      local o = R.GetTrackMediaItem(tr, i)
      if o == it or o == n2 or edit.sus_ext(o, 'P_EXT:jf_susof') ~= '' then R.DeleteTrackMediaItem(tr, o) end
    end
    R.DeleteProjectMarker(0, rid, true)
  end)
  R.SetProjExtState(0, 'jf_tracker', 'sus', '')
  log('items left on A: ' .. R.CountTrackMediaItems(tr))
end)
if not ok then log('ERR ' .. tostring(err)); bad = bad + 1 end
log(bad .. ' bad')
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
