-- test_import.lua — разбор REX2 и XRNI на настоящих файлах (если есть на диске)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local IM = dofile(DIR .. '/jf_tracker_import.lua')
local n, bad = 0, 0
local function eq(a, b, what) n = n + 1; if a ~= b then bad = bad + 1; print(('FAIL %s: %s ~= %s'):format(what, tostring(a), tostring(b))) end end
-- 11 окт: SFZ — наследование group, пробелы в пути, \\ и .., имена нот, комментарии
eq(IM.kind('x.SFZ'), 'sfz', 'kind sfz'); eq(IM.sfz_key('c4'), 60, 'c4 = 60'); eq(IM.sfz_key('f#2'), 42, 'f#2'); eq(IM.sfz_key('45'), 45, 'number')
do
  local t = [[<control> default_path=Samples\ // comment
<group> lokey=36 hikey=47 pitch_keycenter=c3 loop_mode=loop_continuous
<region> sample=Bass One.wav offset=100 end=999
<region> sample=..\Other\b.wav lokey=48 hikey=59
<group>
<region> sample=/abs/k.wav key=d#1]]
  local r = IM.sfz(t, '/lib/sfz')
  eq(#r, 3, 'sfz 3 regions')
  eq(r[2].sample, '/lib/sfz/Samples/Bass One.wav', 'path with a space, default_path')
  eq(r[2].key, 48, 'group pitch_keycenter c3'); eq(r[2].loop, true, 'group loop'); eq(r[2].offset, 100, 'offset'); eq(r[2].end_, 999, 'end')
  eq(r[3].sample, '/lib/sfz/Other/b.wav', '.. folds'); eq(r[3].lokey, 48, 'own lokey wins')
  eq(r[1].sample, '/abs/k.wav', 'absolute path'); eq(r[1].lokey, 27, 'key= sets lokey'); eq(r[1].loop, false, 'new group clears loop')
end
eq(IM.kind('/a/b.RX2'), 'rex', 'kind rx2'); eq(IM.kind('x.xrni'), 'xrni', 'kind xrni'); eq(IM.kind('x.wav'), nil, 'kind wav')
local rx = '/Users/Shared/Prismatic Bliss Library/Samples/Loops/Drums/Snare[98] Stellate.rx2'
if io.open(rx, 'rb') then
  local r = assert(IM.rx2_slices(rx))
  eq(r.sr, 44100, 'rx2 sr'); eq(r.frames, 432000, 'rx2 frames')
  eq(r.slices[1], 0, 'rx2 first slice at 0'); eq(#r.slices > 4, true, 'rx2 has slices')
  local ok = true; for i = 2, #r.slices do if r.slices[i] <= r.slices[i - 1] then ok = false end end
  eq(ok, true, 'rx2 slices ascending')
end
local xml = [[<RenoiseInstrument><Samples><Sample><Name>Brk &amp; co</Name><BaseNote>48</BaseNote><IsAlias>false</IsAlias>
<SliceMarkers><SliceMarker><SamplePosition>0</SamplePosition></SliceMarker><SliceMarker><SamplePosition>11384</SamplePosition></SliceMarker></SliceMarkers></Sample>
<Sample><Name>slice 1</Name><IsAlias>true</IsAlias></Sample></Samples></RenoiseInstrument>]]
local s = IM.xrni_samples(xml)
eq(#s, 2, 'xrni samples'); eq(s[1].name, 'Brk & co', 'xrni name unescaped'); eq(s[1].base, 48, 'xrni base')
eq(#s[1].slices, 2, 'xrni slices'); eq(s[1].slices[2], 11384, 'xrni slice frames'); eq(s[2].alias, true, 'xrni alias')
eq(IM.xrni_file('Instrument.xml\nSampleData/Sample00 (a b).flac\nSampleData/Sample01 (c).flac', 1), 'SampleData/Sample01 (c).flac', 'xrni file by index')
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
