-- tests/test_rtg_orphans.lua — копии 0R без исходной ноты (28 окт): удалил ноту — её скрытые копии (P_EXT:jf_rtg)
-- не звучат «призраком»; живые копии и чужие ноты не трогаются; клип с тем же MIDI повторно не сканируется; скорость
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local fails, n = 0, 0
local function ok(c, msg) n = n + 1; if not c then fails = fails + 1; print('FAIL ' .. msg) end end

local IT, TR, scans
local function note(s, e, pi, ve) return { s = s, e = e, pi = pi, ch = 0, ve = ve or 100 } end
local function build(notes, rtg, rtl)
  IT = { ext = { ['P_EXT:jf_rtg'] = rtg or '', ['P_EXT:jf_rtl'] = rtl or '' }, take = { notes = notes, ver = 0 } }
  TR = { items = { IT } }
end
local function sorted() table.sort(IT.take.notes, function(a, b) return a.s < b.s end) end
reaper = setmetatable({
  CountTracks = function() return 1 end,
  GetTrack = function() return TR end,
  CountTrackMediaItems = function(tr) return #tr.items end,
  GetTrackMediaItem = function(tr, i) return tr.items[i + 1] end,
  GetActiveTake = function(it) return it.take end,
  TakeIsMIDI = function() return true end,
  MIDI_CountEvts = function(tk) sorted(); scans = scans + 1; return true, #tk.notes, 0, 0 end,
  MIDI_GetNote = function(tk, k) local x = tk.notes[k + 1]; return true, false, false, x.s, x.e, x.ch, x.pi, x.ve end,
  MIDI_DeleteNote = function(tk, k) table.remove(tk.notes, k + 1); tk.ver = tk.ver + 1 end,
  MIDI_Sort = function() end,
  MIDI_GetHash = function(tk) return true, tostring(#tk.notes) .. ':' .. tk.ver end,
  GetSetMediaItemInfo_String = function(it, key, v, set) if set then it.ext[key] = v; return true, v end; return true, it.ext[key] or '' end,
}, { __index = function() return function() return 0 end end })
local E = dofile(DIR .. '/jf_tracker_edit.lua')
scans = 0

-- 1. исходная нота удалена — обе копии вон, метки пусты
build({ note(960, 1000, 50), note(1200, 1300, 50, 60) }, '960:50:0;1200:50:0', '')
ok(E.rtg_clean(IT, IT.take) == 2 and #IT.take.notes == 0, 'copies of a deleted note are removed')
ok(IT.ext['P_EXT:jf_rtg'] == '', 'their marks are gone')

-- 2. исходная жива (укорочена ретриггером, длина в jf_rtl) — копии остаются
build({ note(0, 239, 50), note(240, 479, 50, 60), note(480, 960, 50, 36) }, '240:50:0;480:50:0', '0:50:960.000')
ok(E.rtg_clean(IT, IT.take) == 0 and #IT.take.notes == 3, 'copies of a living note stay')

-- 3. копию удалили руками — её метка вон, остальные целы
build({ note(0, 239, 50), note(480, 960, 50, 36) }, '240:50:0;480:50:0', '0:50:960.000')
E.rtg_clean(IT, IT.take)
ok(IT.ext['P_EXT:jf_rtg'] == '480:50:0' and #IT.take.notes == 2, 'a mark without its note is dropped: ' .. IT.ext['P_EXT:jf_rtg'])

-- 4. две ноты одной высоты: удалена первая — копии второй живут, копии первой вон
build({ note(240, 300, 50), note(2000, 2239, 50), note(2240, 2400, 50, 60) }, '240:50:0;2240:50:0', '0:50:480.000;2000:50:2400.000')
E.rtg_clean(IT, IT.take)
ok(#IT.take.notes == 2 and IT.take.notes[2].s == 2240, 'only the orphan copy goes, the other note keeps its copy')

-- 5. нота другой высоты копию не «держит»
build({ note(0, 960, 62), note(240, 479, 50, 60) }, '240:50:0', '0:50:960.000')
ok(E.rtg_clean(IT, IT.take) == 1, 'a note of another pitch does not keep the copy alive')

-- 6. rtg_sync: тот же MIDI — второй проход клип не сканирует
build({ note(0, 239, 50), note(240, 479, 50, 60) }, '240:50:0', '0:50:480.000')
scans = 0; E.rtg_sync(); local s1 = scans; E.rtg_sync()
ok(s1 == 1 and scans == 1, ('unchanged MIDI is not scanned again (%d, %d)'):format(s1, scans))

-- 7. скорость: 700 нот, 600 живых копий — одна проверка быстро
do
  local ns, g = {}, {}
  for h = 0, 99 do
    local base = h * 7000
    ns[#ns + 1] = note(base, base + 99, 40 + h % 20)
    for j = 1, 6 do local p = base + j * 100; ns[#ns + 1] = note(p, p + 99, 40 + h % 20, 50); g[#g + 1] = ('%d:%d:0'):format(p, 40 + h % 20) end
  end
  local l = {}
  for h = 0, 99 do l[#l + 1] = ('%d:%d:%.3f'):format(h * 7000, 40 + h % 20, h * 7000 + 700) end
  build(ns, table.concat(g, ';'), table.concat(l, ';'))
  local t0 = os.clock()
  local d = E.rtg_clean(IT, IT.take)
  local ms = (os.clock() - t0) * 1000
  ok(d == 0 and #IT.take.notes == 700, 'all 600 copies alive')
  ok(ms < 30, ('700 notes checked in %.1f ms'):format(ms))
  print(('  rtg_clean 700 notes: %.2f ms'):format(ms))
end

print(('test_rtg_orphans: %d/%d ok'):format(n - fails, n))
os.exit(fails == 0 and 0 or 1)
