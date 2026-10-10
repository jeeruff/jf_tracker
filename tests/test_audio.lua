-- test_audio.lua — чистые функции модуля audio: lua tests/test_audio.lua
package.path = './?.lua;' .. package.path
local A = dofile('jf_tracker_audio.lua')
local n, bad = 0, 0
local function eq(name, got, want)
  n = n + 1
  if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end

local l = A.hist_parse('a|b|a||c')
eq('parse dedups', A.hist_str(l), 'a|b|c')
eq('add moves to front', A.hist_str(A.hist_add(l, 'c')), 'c|a|b')
eq('add new', A.hist_str(A.hist_add(l, 'd')), 'd|a|b|c')
eq('add empty keeps', A.hist_str(A.hist_add(l, '')), 'a|b|c')
local big = {}; for i = 1, 20 do big[i] = 'd' .. i end
eq('history capped at 12', #A.hist_add(big, 'x'), 12)
eq('strip ident', A.strip_ident('CoreAudio MHLink [46236]'), 'MHLink [46236]')

local cur = { dev = 'MHLink', sr = 48000, sruse = true, bs = 128, bsuse = true }
eq('no diff', #A.diff(cur, { dev = 'MHLink', bs = 128 }), 0)
local d = A.diff(cur, { bs = 256 })
eq('bs diff', #d, 1); eq('bs key', d[1][2], 'coreaudiobs'); eq('bs value', d[1][3], 256)
d = A.diff(cur, { dev = 'RME' })
eq('device sets out and in', #d, 2); eq('out first', d[1][2], 'coreaudiooutdevnew'); eq('in too', d[2][3], 'RME')
d = A.diff(cur, { sruse = false })
eq('request rate off', d[1][2] .. '=' .. d[1][3], 'coreaudiosrateuse=0')
d = A.diff({ dev = 'x', sr = 48000, sruse = true, bs = 64, bsuse = false }, { bs = 64, bsuse = true })
eq('bsuse on without size change', #d, 1); eq('bsuse key', d[1][2], 'coreaudiobsuse')

print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
