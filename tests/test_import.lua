-- test_import.lua — разбор REX2 и XRNI на настоящих файлах (если есть на диске)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local IM = dofile(DIR .. '/jf_tracker_import.lua')
local n, bad = 0, 0
local function eq(a, b, what) n = n + 1; if a ~= b then bad = bad + 1; print(('FAIL %s: %s ~= %s'):format(what, tostring(a), tostring(b))) end end
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
