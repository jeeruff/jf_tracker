-- test_grid_clips.lua — страница clips модуля демона (daemon_tracker.lua) на
-- стабе мономе и ExtState: lua tests/test_grid_clips.lua (7 окт)
package.path = './?.lua;' .. package.path
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end

local ext, now = {}, 100
reaper = {
  GetExtState = function(s, k) return ext[s .. '/' .. k] or '' end,
  SetExtState = function(s, k, v) ext[s .. '/' .. k] = v end,
  time_precise = function() return now end,
}
local M = dofile('daemon_tracker.lua')
local frame
local function mono(keys, encs)
  return { owner = 9, grid_ok = true, arc_ok = true, keys_nc = keys or {}, encs = encs or {},
           leds = function(r) frame = r end, ring = function() end }
end
local function sent() return (ext['jf_tracker/ssgrid'] or ''):match('^(.*),%d+$') end
ext['jf_tracker/hb'] = '1'
ext['jf_tracker/mx'] = '3,3,1,1,0,0;o.oo.o..o'
-- 3 сцены × 3 трека; трек 1 играет сцену 2 на шаге 3, у трека 2 луп 2..5
ext['jf_tracker/ss'] = '1,3,3,2,1,0,1;o.oo.o..o;2:3:-1:-1:0:80 1:4:2:5:0:50 0:-1:-1:-1:0:0'

M.tick(mono({ { 0, 1, 1 } }))
eq('clip tap = launch scene 2 track 1', sent(), 'launch 2 1')
eq('layout follows the page', M.layout == M.layout_clips, true)
eq('playing clip lit', frame[2][1] >= 11, true)
eq('empty cell dark', frame[3][2], 0)
eq('mlr playhead on step 3 (row 4)', frame[4][9], 15)
eq('mlr loop range dim-lit', frame[3][10], 6); eq('mlr outside loop', frame[7][10], 2)
eq('mlr of silent track dark', frame[1][11], 0)
M.tick(mono({ { 1, 7, 1 } })); eq('bottom row = stop track', sent(), 'stop 2')
M.tick(mono({ { 7, 0, 1 } })); eq('column 8 = scene', sent(), 'scene 1')
M.tick(mono({ { 8, 5, 1 } })); eq('mlr tap = jump', sent(), 'jump 1 5')
M.tick(mono({ { 8, 1, 1 } })); eq('second held key = loop', sent(), 'loop 1 5 1')
M.tick(mono({ { 8, 5, 0 }, { 8, 1, 0 } }))
M.tick(mono({ { 8, 2, 1 } })); eq('after release: jump again', sent(), 'jump 1 2')
M.tick(mono({ { 8, 2, 0 } }))
-- stop all: короткое — стоп всех, долгое — закрыть вид
M.tick(mono({ { 7, 7, 1 } })); now = now + 0.1; M.tick(mono({ { 7, 7, 0 } })); eq('short corner = stop all', sent(), 'stopall')
M.tick(mono({ { 7, 7, 1 } })); now = now + 1; M.tick(mono({ { 7, 7, 0 } })); eq('long corner = close clips', sent(), 'clips')
-- два нажатия в одном тике — одной строкой
M.tick(mono({ { 0, 0, 1 }, { 2, 0, 1 } })); eq('batch in one tick', sent(), 'launch 1 1;launch 1 3')
-- arc 4 = квантизация, 3 = громкость трека курсора
M.tick(mono(nil, { { 3, 30 } })); eq('arc 4 = quant', sent(), 'quant')
M.tick(mono(nil, { { 2, 2 } })); eq('arc 3 = volume of the cursor track', sent(), 'vol 1 1')
-- столбец хоста слева: всё на 1 вправо
ext['jf_mono/ctl_side'] = 'left'
M.tick(mono({ { 1, 1, 1 } })); eq('ctl left: x 1 = track 1', sent(), 'launch 2 1')
eq('ctl left: frame shifted', frame[2][2] >= 11, true)
ext['jf_mono/ctl_side'] = nil
-- вид clips закрыт — матрица: нажатие уходит в gridkey
ext['jf_tracker/ss'] = '0,3,3,2,1,0,1;o.oo.o..o;0:-1:-1:-1:0:0 0:-1:-1:-1:0:0 0:-1:-1:-1:0:0'
M.tick(mono({ { 0, 0, 1 } })); eq('view off: matrix page', (ext['jf_tracker/gridkey'] or ''):match('^1,1,') ~= nil, true)
eq('view off: matrix layout', M.layout ~= M.layout_clips, true)

-- протокол на стороне трекера: SS.grid_pub / SS.grid_cmd
local log = {}
local ctx = { msg = function() end, ss_colname = function(ci) return 'T' .. ci end, ss_vol = function() return 0.5 end,
  ss_playpos = function() return 101, true end, ss_zone = function() return { pos = 100, rgnend = 116 } end,
  ss_beat_after = function(t) return math.floor(t / 0.5) * 0.5 + 0.5 end, ss_bar_after = function(t) return math.floor(t / 2) * 2 + 2 end,
  clips_toggle = function() log[#log + 1] = 'toggle' end, ss_vol_add = function(ci, d) log[#log + 1] = 'vol' .. ci .. ':' .. d end }
local SS = dofile('jf_tracker_session.lua'); SS.init({}, ctx)
local seq = { { pos = 0, rgnend = 4 }, { pos = 4, rgnend = 8 } }
local grid = { { { state = 'has' }, { state = 'empty' } }, { { state = 'muted' }, { state = 'has' } } }
SS.live[1] = { ri = 2, phase = 100, len = 4, full = 4, a = 0 }
eq('pub', SS.grid_pub(seq, 2, grid, 101, true, true), '1,2,2,1,1,0,1;o.mo;2:2:-1:-1:0:50 0:-1:-1:-1:0:50')
SS.grid_cmd('jump 1 6;vol 2 -3;clips,77', seq, { cols = { {}, {} } }, grid)
eq('cmd jump queued', SS.pend[1] and SS.pend[1].step, 6); eq('cmd vol + toggle', table.concat(log, ','), 'vol2:-3,toggle')
eq('cmd bad track ignored', SS.grid_cmd('stop 9', seq, { cols = { {}, {} } }, grid), 0)
eq('pub shows pending jump', SS.grid_pub(seq, 2, grid, 101, true, true):match(';[^;]*;(%S+)'), '2:2:-1:-1:3:50')

print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
