-- tests/test_presets_index.lua — индекс пресетов плагинов (jf_tracker_fxpresets.lua)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local PI = dofile(DIR .. '/jf_tracker_fxpresets.lua')
local fails, n = 0, 0
local function ok(c, msg) n = n + 1; if not c then fails = fails + 1; print('FAIL ' .. msg) end end

-- ключи файлов
ok(PI.key_of_file('vst-reacomp.ini') == 'vst:reacomp', 'file vst')
local k, b = PI.key_of_file('vst3-Serum2-691258006-builtin.ini')
ok(k == 'vst3:serum2-691258006' and b, 'file vst3 shell builtin')
ok(PI.key_of_file('au-Xfer Records: Nerve-builtin.ini') == 'au:xfer records: nerve', 'file au')
ok(PI.key_of_file("js-Saike Tools_Filther_Filther_jsfx.ini") == 'js:saike tools_filther_filther_jsfx', 'file js')
ok(PI.key_of_file('js-jf_slixer_jsfx.ini.bak-20260918-170005') == nil, 'backup file skipped')

-- ключи плагинов (как EnumInstalledFX)
ok(PI.key_of_fx('VST: ReaComp (Cockos)', '/Applications/REAPER.app/Contents/Plugins/FX/reacomp.vst.dylib') == 'vst:reacomp', 'fx vst dylib')
ok(PI.key_of_fx('VST: Echobode (Sonic Charge)', '/Library/Audio/Plug-Ins/VST/Sonic Charge/Echobode.vst') == 'vst:echobode', 'fx vst')
ok(PI.key_of_fx('VST3i: Serum 2 (Xfer Records)', '/Library/Audio/Plug-Ins/VST3/Serum2.vst3<691258006') == 'vst3:serum2-691258006', 'fx vst3 shell')
local a1, a2 = PI.key_of_fx('VST3: Pro-Q 4 (FabFilter)', '/Library/Audio/Plug-Ins/VST3/FabFilter Pro-Q 4.vst3')
ok(a1 == 'vst3:fabfilter pro-q 4' and a2 == 'vst3:fabfilter pro-q 4', 'fx vst3')
ok(PI.key_of_fx('AUi: Nerve (Xfer Records)', 'Xfer Records: Nerve') == 'au:xfer records: nerve', 'fx au instrument')
ok(PI.key_of_fx('JS: Filther (Saike)', 'Saike Tools/Filther/Filther.jsfx') == 'js:saike tools_filther_filther_jsfx', 'fx js path')

-- разбор ini
local user = '[General]\nNbPresets=2\n\n[Preset0]\nData=00\nLen=1\nName=stock - Rock Snare\n\n[Preset1]\nData=11\nName=Bus glue\n'
local u = PI.parse_ini(user)
ok(#u == 2 and u[1] == 'stock - Rock Snare' and u[2] == 'Bus glue', 'user presets')
local fac = PI.parse_ini('[factory]\n00001=eX Simple Echo\n00002=SC Infiniverb\n')
ok(#fac == 2 and fac[2] == 'SC Infiniverb', 'factory presets')
ok(#PI.parse_ini('[aufactory]\n00001=Default\npreset_cnt=1\n') == 0, 'au Default / counters skipped')

ok(#PI.parse_ini('[factory]\n00001=Program 1\n00002=Program List A: Program 0-3\n00003=Preset 12\n00004=Big Pad\n') == 1, 'blank program slots skipped')

-- индекс целиком
local fx = { { label = 'VST: ReaComp (Cockos)', data = '/x/reacomp.vst.dylib' }, { label = 'AUi: Nerve (Xfer Records)', data = 'Xfer Records: Nerve' } }
local idx = PI.build({ { name = 'vst-reacomp.ini', text = user }, { name = 'au-Xfer Records: Nerve-builtin.ini', text = '[aufactory]\n00001=Hip Hop 1\n' },
  { name = 'vst-unknown.ini', text = user } }, fx)
ok(#idx == 3, 'index: 2 user + 1 factory, unknown plugin skipped')
ok(idx[1].fx == fx[1] and idx[1].user and idx[3].fx == fx[2] and not idx[3].user, 'index entries point to their plugin')

print(('test_presets_index: %d/%d ok'):format(n - fails, n))
os.exit(fails == 0 and 0 or 1)
