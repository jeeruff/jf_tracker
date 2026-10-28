-- tests/test_mini.lua — мини-нотация Tidal / Strudel (jf_tracker_mini.lua)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local M = dofile(DIR .. '/jf_tracker_mini.lua')
local fails, n = 0, 0
local function ok(c, msg) n = n + 1; if not c then fails = fails + 1; print('FAIL ' .. msg) end end
local function near(a, b) return math.abs(a - b) < 1e-6 end
local function starts(evs) local t = {}; for _, e in ipairs(evs) do t[#t + 1] = string.format('%.4g', e.s) end; return table.concat(t, ' ') end
local function vals(evs) local t = {}; for _, e in ipairs(evs) do t[#t + 1] = e.v end; return table.concat(t, ' ') end

local e = M.query('c e g b', 0)
ok(#e == 4 and starts(e) == '0 0.25 0.5 0.75', 'four steps: ' .. starts(e))
ok(e[1].pitch == 60 and e[2].pitch == 64 and e[4].pitch == 71, 'note names -> MIDI (c = C4 = 60)')
ok(near(e[1].e, 0.25), 'step length 1/4')

e = M.query('c [e g]', 0)
ok(starts(e) == '0 0.5 0.75' and vals(e) == 'c e g', '[ ] subdivides: ' .. starts(e))

e = M.query('c ~ e ~', 0)
ok(#e == 2 and starts(e) == '0 0.5', '~ rests')

e = M.query('[c, e, g]', 0)
ok(#e == 3 and starts(e) == '0 0 0', ', stacks (chord)')

local a0, a1, a2 = M.query('<c e g>', 0), M.query('<c e g>', 1), M.query('<c e g>', 3)
ok(vals(a0) == 'c' and vals(a1) == 'e' and vals(a2) == 'c', '< > alternates per cycle')

e = M.query('c*4', 0)
ok(#e == 4 and starts(e) == '0 0.25 0.5 0.75', '*4 repeats faster')
e = M.query('c e*2', 0)
ok(starts(e) == '0 0.5 0.75', '* on a step')

local s0, s1 = M.query('c e/2', 0), M.query('c e/2', 1)
ok(#s0 == 2 and #s1 == 1, '/2 - the step plays every other cycle')

e = M.query('c!3 e', 0)
ok(#e == 4 and vals(e) == 'c c c e', '!3 repeats a step')
e = M.query('c@3 e', 0)
ok(starts(e) == '0 0.75', '@3 weight')

e = M.query('c(3,8)', 0)
ok(#e == 3 and starts(e) == '0 0.375 0.75', 'euclid (3,8): ' .. starts(e))
e = M.query('c(3,8,2)', 0)
ok(#e == 3, 'euclid rotation keeps the count')

local d1 = M.query('c*8?', 0)
ok(#d1 > 0 and #d1 < 8, '? drops some')
ok(#M.query('c*8?', 0) == #d1, '? is the same every time for the same cycle')

ok(M.pitch('f#3') == 54 and M.pitch('bb2') == 46 and M.pitch('eb') == 63, 'accidentals and octaves')
ok(M.pitch('7', 60) == 67, 'numbers are steps from the base')
ok(M.pitch('bd') == nil, 'a sample name has no pitch')

-- цепочка
e = M.query('n("c e").fast(2)', 0)
ok(#e == 4, '.fast(2) doubles')
e = M.query('"c e g".rev()', 0)
ok(vals(e) == 'g e c', '.rev()')
e = M.query('c e .add 7', 0)
ok(e[1].pitch == 67, '.add 7 (dot style without parens): ' .. tostring(e[1].pitch))
e = M.query('n("c").oct(-1).vel(0.5)', 0)
ok(e[1].pitch == 48 and near(e[1].vel, 0.5), '.oct and .vel')
local ev0, ev1 = M.query('n("c e").every(2, "rev")', 0), M.query('n("c e").every(2, "rev")', 1)
ok(vals(ev0) == 'e c' and vals(ev1) == 'c e', '.every(2, rev) on cycles 0, 2 ...')
e = M.query('n("c e").slow(2)', 0)
ok(#e == 1 and vals(e) == 'c', '.slow(2) - half per cycle')

-- ошибки разбора
ok(not pcall(M.parse, 'c [e g'), 'missing ] is an error')
ok(not pcall(M.parse, 'c(3)'), 'bad euclid is an error')

print(('test_mini: %d/%d ok'):format(n - fails, n))
os.exit(fails == 0 and 0 or 1)
