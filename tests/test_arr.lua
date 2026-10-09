-- test_arr.lua — аранжировки: lua tests/test_arr.lua
local AR = dofile('jf_tracker_arr.lua')
local n, fail = 0, 0
local function ok(c, m) n = n + 1; if not c then fail = fail + 1; print('FAIL ' .. m) end end
local list = { { name = 'verse', lanes = { ['{A}'] = { 1, 0, 0 }, ['{B}'] = { 0, 2, 2 } } }, { name = 'chorus|x', lanes = {} } }
local s = AR.encode(list)
ok(not s:find('chorus|x', 1, true), 'name cleaned')
local back = AR.decode(s)
ok(#back == 2 and back[1].name == 'verse' and back[2].name == 'chorus x', 'round trip names')
ok(table.concat(back[1].lanes['{B}']) == '022', 'round trip lanes')
ok(#AR.decode('') == 0 and #AR.decode('junk') == 0, 'garbage')
ok(AR.next_name(back, 'verse') == 'verse 2', 'next name')
back[#back + 1] = { name = 'verse 2', lanes = {} }
ok(AR.next_name(back, 'verse 2') == 'verse 3', 'next name 3')
ok(AR.next_name(back, 'bridge') == 'bridge', 'free name')
-- стаб reaper: два трека, у второго нет лейнов
local tr = { { g = '{A}', fm = 2, n = 3, p = { 1, 0, 0 } }, { g = '{B}', fm = 0, n = 1, p = { 1 } } }
local R = {
  CountTracks = function() return #tr end, GetTrack = function(_, i) return tr[i + 1] end,
  GetTrackGUID = function(t) return t.g end,
  GetMediaTrackInfo_Value = function(t, k)
    if k == 'I_FREEMODE' then return t.fm elseif k == 'I_NUMFIXEDLANES' then return t.n end
    return t.p[tonumber(k:match(':(%d+)')) + 1] end,
  SetMediaTrackInfo_Value = function(t, k, v)
    local i = tonumber(k:match(':(%d+)')) + 1
    if v == 1 then for j = 1, t.n do t.p[j] = 0 end end
    t.p[i] = v end,
}
local cap = AR.capture(R)
ok(cap['{A}'] and table.concat(cap['{A}']) == '100' and not cap['{B}'], 'capture')
ok(AR.apply(R, { ['{A}'] = { 0, 0, 1 } }) == 1 and table.concat(tr[1].p) == '001', 'apply exclusive')
AR.apply(R, { ['{A}'] = { 2, 2, 0 } })
ok(table.concat(tr[1].p) == '220', 'apply several')
local c = AR.copy(cap); c['{A}'][1] = 9
ok(cap['{A}'][1] == 1, 'copy is deep')
print(('test_arr: %d checks, %d failed'):format(n, fail))
os.exit(fail == 0 and 0 or 1)
