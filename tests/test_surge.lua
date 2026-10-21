-- test_surge.lua — 16 окт: base64, блок sub3 из .fxp, замена состояния, чанк трека
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local S = dofile(DIR .. '/jf_tracker_surge.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end

for _, s in ipairs({ '', 'a', 'ab', 'abc', 'abcd', '\0\255\1binary' }) do eq('b64 round ' .. #s, S.b64dec(S.b64enc(s)), s) end
eq('b64 known', S.b64enc('Man'), 'TWFu'); eq('b64 pad', S.b64enc('M'), 'TQ==')

local function sub3(name) local xml = '<patch><meta name="' .. name .. '" /></patch>'; return 'sub3' .. string.pack('<I4', #xml) .. string.rep('\0', 24) .. xml end
local blk = sub3('Attacky')
local fxp = 'CcnK' .. string.rep('\0', 52) .. string.pack('>I4', #blk) .. blk
eq('fxp chunk', S.fxp_chunk(fxp), blk)
eq('fxp not surge', S.fxp_chunk('hello'), nil)
eq('patch name', S.patch_name(blk), 'Attacky')

local old = sub3('Init Saw')
local comp = '\1\0\0\0' .. old .. 'JUCEtail'
local data = string.pack('<I4', #comp) .. comp .. 'CTRL1234'
local nd = S.replace_state(data, blk)
eq('state has new patch', S.patch_name(nd), 'Attacky')
eq('state keeps tail', nd:find('JUCEtail', 1, true) ~= nil, true)
eq('state keeps controller', nd:sub(-8), 'CTRL1234')
eq('state size field', string.unpack('<I4', nd), #nd - 12)

local hdr = string.rep('\7', 20) .. string.pack('<I4', #data) .. '\1\0\0\0\255\255\0\0'
local lines = { '<TRACK', '  <FXCHAIN', '    <VST "VST3i: Surge XT" "Surge XT.vst3" 0 "" 1{X} ""', '      ' .. S.b64enc(hdr) }
for i = 1, #data, 210 do lines[#lines + 1] = '      ' .. S.b64enc(data:sub(i, i + 209)) end
lines[#lines + 1] = '      AAAAAAAA'; lines[#lines + 1] = '    >'; lines[#lines + 1] = '  >'; lines[#lines + 1] = '>'
local tc = S.patch_track_chunk(table.concat(lines, '\n'), 1, blk)
eq('track chunk patched', tc ~= nil, true)
local got = {}
local inb, skip = false, 0
for l in (tc or ''):gmatch('[^\n]+') do
  if l:match('^%s*<VST ') then inb = true; skip = 1 elseif inb and l:match('^%s*>') then inb = false
  elseif inb then if skip > 0 then skip = skip - 1; got.hdr = S.b64dec(l) else got[#got + 1] = S.b64dec(l) end end
end
local nd2 = table.concat(got):sub(1, -7)          -- без строки имени программы (AAAAAAAA = 6 байт)
eq('chunk carries the patch', S.patch_name(nd2), 'Attacky')
eq('header size updated', string.unpack('<I4', got.hdr, #got.hdr - 11), #nd2)
eq('no such block', S.patch_track_chunk(table.concat(lines, '\n'), 2, blk), nil)
-- 21 окт: CLAP — <STATE> = ровно блок sub3
local cl = { '<TRACK', '  <FXCHAIN', '    <CLAP "CLAPi: Surge XT" org.surge-synth-team.surge-xt ""', '      CFG 4 1358 855 ""', '      <OUT_PINS', '      >', '      <STATE' }
for i = 1, #old, 210 do cl[#cl + 1] = '        ' .. S.b64enc(old:sub(i, i + 209)) end
cl[#cl + 1] = '      >'; cl[#cl + 1] = '    >'; cl[#cl + 1] = '>'
local ctc = S.patch_clap_chunk(table.concat(cl, '\n'), 1, blk)
eq('clap patched', ctc ~= nil, true)
local cst = (ctc or ''):match('<STATE\n(.-)\n%s*>')
local cb = {}; for l in (cst or ''):gmatch('[^\n]+') do cb[#cb + 1] = S.b64dec(l) end
eq('clap state is the patch', table.concat(cb), blk)
eq('clap keeps pins', (ctc or ''):find('<OUT_PINS', 1, true) ~= nil, true)
eq('clap no block', S.patch_clap_chunk(table.concat(cl, '\n'), 2, blk), nil)
local wt = 'sub3' .. string.pack('<I4', 3) .. string.pack('<I4', 5) .. string.rep('\0', 20) .. 'xmlWAVES'
eq('sub3 len with wavetables', S.sub3_len(wt .. 'tail', 1), #wt)
eq('name in clap track', S.name_in_track(table.concat(cl, '\n') .. '\n    FXID {G1}', '{G1}'), 'Init Saw')
eq('name in vst3 track', S.name_in_track(table.concat(lines, '\n') .. '\n    FXID {G2}', '{G2}'), 'Init Saw')
eq('name no fxid', S.name_in_track(table.concat(cl, '\n'), '{G9}'), nil)
local c, nm = S.label('/R/Basses/Attacky.fxp', '/R')
eq('label cat', c, 'Basses'); eq('label name', nm, 'Attacky')
c = S.label('/R/A.Liv/Basses/X.fxp', '/R'); eq('label nested', c, 'A.Liv / Basses')

print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
