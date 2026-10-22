-- test_podkat.lua (22 окт): podkat / anticipate — подкат кончается на ноте, аккорд — один, без налезания, keytrack, humanize
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local PK = dofile(DIR .. '/jf_tracker_podkat.lua')
local n, bad = 0, 0
local function eq(a, b, w) n = n + 1; if a ~= b then bad = bad + 1; print(('FAIL %s: %s ~= %s'):format(w, tostring(a), tostring(b))) end end
local function near(a, b, w) eq(math.abs(a - b) < 1e-6, true, w .. ' (' .. tostring(a) .. ' vs ' .. tostring(b) .. ')') end
local cfg = { pre = 1, hum = 0 }
local p = PK.places({ { qn = 4, pitch = 60, vel = 100 }, { qn = 8, pitch = 60 } }, cfg, 1)
eq(#p, 2, 'one per note'); near(p[1].qn + p[1].len, 4, 'ends on the note'); near(p[1].len, 1, 'pre 1 QN'); near(p[1].rate, 1, 'rate 1'); near(p[1].amp, 1, 'amp 1 without vel')
p = PK.places({ { qn = 4, pitch = 60 }, { qn = 4, pitch = 67 }, { qn = 4.25, pitch = 60 } }, cfg, 1)
eq(#p, 2, 'chord = one podkat'); near(p[2].len, 0.25, 'no overlap with the previous note'); near(p[2].rate, 4, 'short one runs faster')
p = PK.places({ { qn = 8, pitch = 72 } }, { pre = 1, key = true, hum = 0 }, 1)
near(p[1].len, 0.5, 'keytrack: octave up = half'); near(p[1].qn, 7.5, '…still ends on the note')
p = PK.places({ { qn = 8, pitch = 60, vel = 64 } }, { pre = 1, vel = true, hum = 0 }, 1)
near(p[1].amp, 64 / 127, 'vel -> amplitude')
local a = PK.places({ { qn = 8, pitch = 60 } }, { pre = 1, hum = 50 }, 1)
local b = PK.places({ { qn = 8, pitch = 60 } }, { pre = 1, hum = 50 }, 1)
eq(PK.same(a, b), true, 'humanize is deterministic')
eq(math.abs(a[1].qn + a[1].len - 8) <= 0.12 * 0.5 + 1e-9, true, 'humanize timing stays small')
eq(math.abs(a[1].qn + a[1].len - 8) > 1e-9, true, 'humanize moves it a bit')
local s = PK.encode({ { env = 'fx:{AB}:3', pool = 7, pre = 0.5, key = true, hum = 10, label = 'cutoff' } })
eq(s, 'fx:{AB}:3|7|0.5|k|10|cutoff', 'encode')
local c = PK.parse(s)[1]
eq(c.pool, 7, 'parse pool'); near(c.pre, 0.5, 'parse pre'); eq(c.key, true, 'parse key'); eq(c.vel, false, 'parse vel'); eq(c.hum, 10, 'parse hum'); eq(c.label, 'cutoff', 'parse label')
eq(PK.encode({ { env = 'fx:{A}:1', pool = 1, pre = 2, hum = 0 } }), 'fx:{A}:1|1|2||0|', 'integer pre')
print(('test_podkat: %d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
