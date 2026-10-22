-- test_snaps.lua (22 окт): снапшоты трека — веса углов XY, смесь, ключи различий, строка хранения
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local SN = dofile(DIR .. '/jf_tracker_snaps.lua')
local n, bad = 0, 0
local function eq(a, b, w) n = n + 1; if a ~= b then bad = bad + 1; print(('FAIL %s: %s ~= %s'):format(w, tostring(a), tostring(b))) end end
local function near(a, b, w) eq(math.abs(a - b) < 1e-6, true, w .. ' (' .. tostring(a) .. ' vs ' .. tostring(b) .. ')') end
local all = { true, true, true, true }
local w = SN.weights(0, 0, all); near(w[1], 1, 'top left = corner 1')
w = SN.weights(1, 1, all); near(w[4], 1, 'bottom right = corner 4')
w = SN.weights(0.5, 0.5, all); near(w[1], 0.25, 'centre: a quarter each')
w = SN.weights(0.5, 0, { true, true, false, false }); near(w[1], 0.5, 'top edge, two corners: half'); near(w[3], 0, '…empty corner 0')
w = SN.weights(0.5, 0.5, { true, false, false, true }); near(w[1] + w[4], 1, 'diagonal pair sums to 1')
w = SN.weights(1, 1, { true, false, false, false }); near(w[1], 1, 'puck in an empty corner: the nearest filled one')
local snaps = { { a = 0, b = 0.5 }, { a = 1, b = 0.5 }, nil, nil }
local keys = SN.diff_keys(snaps)
eq(#keys, 1, 'only differing keys'); eq(keys[1], 'a', '…a')
local out = SN.blend(snaps, SN.weights(0.25, 0, { true, true, false, false }), { 'a', 'b' })
near(out.a, 0.25, 'blend a at x .25'); near(out.b, 0.5, 'b same in both')
local s2 = { [1] = { ['{G1}|3'] = 0.12345, ['{G1}|4'] = 1 }, [3] = { ['{G2}|0'] = 0 } }
local back = SN.parse(SN.ser(s2))
near(back[1]['{G1}|3'], 0.12345, 'ser/parse value'); eq(back[2], nil, 'empty corner stays empty'); near(back[3]['{G2}|0'], 0, 'corner 3')
local part = SN.blend({ { a = 0 }, { a = 1, c = 1 } }, { 0.5, 0.5, 0, 0 }, { 'c' })
near(part.c, 1, 'key only in one corner - from it')
print(('%d checks, %d failed'):format(n, bad)); os.exit(bad == 0 and 0 or 1)
