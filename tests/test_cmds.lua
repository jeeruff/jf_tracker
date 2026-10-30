-- test_cmds.lua — команды по строкам (12 окт): разбор / формат токенов со смещением, put, отрезки
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/') or '.'
local ext = {}
reaper = { GetSetMediaItemInfo_String = function(it, k, v, set) if set then ext[k] = v end; return true, ext[k] or '' end }
local C = dofile(DIR .. '/jf_tracker_cmds.lua')
local n, bad = 0, 0
local function eq(a, b, m) n = n + 1; if a ~= b then bad = bad + 1; print('FAIL ' .. m .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end end
local l = C.parse('0U08,0D04@0.75,0V48@0.25,junk,0X11')
eq(#l, 3, 'three known tokens'); eq(l[1].off, 0, 'no @ - the first row'); eq(l[2].cmd, '0V', 'sorted by offset'); eq(l[3].off, 0.75, '@0.75')
eq(C.format(l), '0U08,0V48@0.25,0D04@0.75', 'format keeps offsets')
eq(C.format(C.parse(C.format(l))), C.format(l), 'round trip')
-- put: та же строка — замена, другая — своя команда
local it = {}
C.put(it, '0U', 8)
C.put(it, '0U', 16, 0.5)
eq(ext['P_EXT:jf_cmds'], '0U08,0U10@0.5', 'two 0U at two rows')
C.put(it, '0U', 32, 0.5)
eq(ext['P_EXT:jf_cmds'], '0U08,0U20@0.5', 'same row - replaced')
C.put(it, '0U', nil, 0)
eq(ext['P_EXT:jf_cmds'], '0U20@0.5', 'cleared only at its row')
-- отрезки: до следующей того же рода, 00 — стоп, другой род не мешает
local segs = C.segments(C.parse('0U08,0V48@0.25,0U00@0.5,0D04@1'), { ['0U'] = true, ['0D'] = true }, function(o) return o end, 2)
eq(#segs, 2, 'slide: 0U from 0, stopped at 0.5, 0D from 1')
eq(segs[1][1], 0, 'seg 1 from 0'); eq(segs[1][2], 0.5, 'seg 1 to the 00'); eq(segs[2][1], 1, 'seg 2 from 1'); eq(segs[2][2], 2, 'seg 2 to the end')
eq(segs[2][3].cmd, '0D', 'seg 2 is 0D')
-- 30 окт: слайд в тиках Renoise — xx/16 полутона за тик, C.TPL тиков в строке
eq(C.TPL, 12, 'ticks per line as in Renoise')
eq(C.slope({ cmd = '0U', xx = 1 }), 0.75, '0U01 = 12/16 semitone per row')
eq(C.slope({ cmd = '0D', xx = 0x10 }), -12, '0D10 = an octave down per row')
print(('test_cmds: %d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
