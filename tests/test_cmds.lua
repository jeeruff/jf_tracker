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
-- 30 окт: стили слайда 0U / 0D и 00
local function nearc(a, b, w) eq(math.abs(a - b) < 1e-6, true, w .. ' (' .. tostring(a) .. ')') end
C.MODE, C.SPEED, C.ZERO = 'renoise', 6, 'repeat'
nearc(C.slide_semis({ cmd = '0U', xx = 16 }, 1, 60), 1, 'renoise: 0U10 = a semitone per row')
nearc(C.slide_semis({ cmd = '0D', xx = 1 }, 2, 60), -2 / 16, 'renoise: 0D01 two rows')
C.MODE = 'ft2'; nearc(C.slide_semis({ cmd = '0U', xx = 1 }, 1, 60), 5 / 16, 'ft2: 0U01 = 5 ticks x 1/16 at speed 6')
C.MODE = 'it'; C.SPEED = 3; nearc(C.slide_semis({ cmd = '0D', xx = 4 }, 1, 60), -0.5, 'it: speed 3 - 2 ticks x 4/16')
C.MODE, C.SPEED = 'pt', 6
nearc(C.slide_semis({ cmd = '0U', xx = 1 }, 1, 60), 12 * math.log(428 / 423, 2), 'pt: period 428 - 5')
eq(C.slide_semis({ cmd = '0U', xx = 1 }, 1, 72) > C.slide_semis({ cmd = '0U', xx = 1 }, 1, 60), true, 'pt: higher note - bigger step')
nearc(C.slide_semis({ cmd = '0U', xx = 255 }, 4, 60), 12 * math.log(428 / 113, 2), 'pt: period stops at 113')
C.MODE = 'renoise'
local m = C.slide_memory({ { cmd = '0D', xx = 3, off = 0 }, { cmd = '0D', xx = 0, off = 1 }, { cmd = '0U', xx = 0, off = 2 } })
eq(m[2].xx, 3, '00 repeats the last 0D'); eq(m[3].xx, 0, 'renoise: 0U has its own memory')
C.MODE = 'it'; m = C.slide_memory({ { cmd = '0D', xx = 3, off = 0 }, { cmd = '0U', xx = 0, off = 1 } }); eq(m[2].xx, 3, 'it: 0U and 0D share the memory')
C.ZERO = 'stop'; m = C.slide_memory({ { cmd = '0D', xx = 3, off = 0 }, { cmd = '0D', xx = 0, off = 1 } }); eq(m[2].xx, 0, 'slide 00 = stop keeps 00')
C.MODE, C.ZERO = 'renoise', 'repeat'
print(('test_cmds: %d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
