-- test_alias.lua — жёсткие границы и автосинк паттернов на стабе REAPER:
-- lua tests/test_alias.lua. Новая реализация (2 окт, лайв) сверяется со
-- старой (tests/alias_ref_trim.lua — прежний A.trim) на тех же данных.
package.path = './?.lua;' .. package.path
local n, bad = 0, 0
local function eq(name, got, want)
  n = n + 1
  if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end

-- ── стаб: треки с items { pos, len, body }; счётчики вызовов ────────────
local P
local calls
local function reset(spec)
  P = { tracks = {} }
  calls = { add = 0, del = 0, setchunk = 0, getchunk = 0 }
  for ti, list in ipairs(spec) do
    local tr = { name = 'T' .. ti, items = {} }
    for _, e in ipairs(list) do tr.items[#tr.items + 1] = { pos = e[1], len = e[2], body = e[3] or 'x', tr = tr } end
    P.tracks[ti] = tr
  end
end
local function sort_items(tr) table.sort(tr.items, function(a, b) return a.pos < b.pos end) end
reaper = {
  CountTracks = function() return #P.tracks end,
  GetTrack = function(_, i) return P.tracks[i + 1] end,
  GetTrackName = function(tr) return true, tr.name end,
  CountTrackMediaItems = function(tr) return #tr.items end,
  GetTrackMediaItem = function(tr, i) sort_items(tr); return tr.items[i + 1] end,
  GetMediaItemInfo_Value = function(it, k)
    if k == 'D_POSITION' then return it.pos elseif k == 'D_LENGTH' then return it.len end
    return 0
  end,
  SetMediaItemInfo_Value = function(it, k, v)
    if k == 'D_POSITION' then it.pos = v elseif k == 'D_LENGTH' then it.len = v end
  end,
  GetMediaTrackInfo_Value = function() return 0 end,
  SplitMediaItem = function(it, t)
    if t <= it.pos or t >= it.pos + it.len then return nil end
    local right = { pos = t, len = it.pos + it.len - t, body = it.body, tr = it.tr }
    it.len = t - it.pos
    it.tr.items[#it.tr.items + 1] = right
    return right
  end,
  GetItemStateChunk = function(it)
    calls.getchunk = calls.getchunk + 1
    return true, ('<ITEM\nPOSITION %.6f\nLENGTH %.6f\nIGUID {%s}\nIID 7\nSEL 0\nBODY %s\n>'):format(it.pos, it.len, tostring(it):sub(-6), it.body)
  end,
  AddMediaItemToTrack = function(tr)
    calls.add = calls.add + 1
    local it = { pos = 0, len = 0, body = '', tr = tr }
    tr.items[#tr.items + 1] = it
    return it
  end,
  SetItemStateChunk = function(it, chunk)
    calls.setchunk = calls.setchunk + 1
    it.len = tonumber(chunk:match('LENGTH ([%d%.]+)')) or 0
    it.body = chunk:match('BODY ([^\n]*)') or ''
  end,
  DeleteTrackMediaItem = function(tr, it)
    calls.del = calls.del + 1
    for i, x in ipairs(tr.items) do if x == it then table.remove(tr.items, i); return true end end
  end,
  GetSetMediaItemInfo_String = function() return true, '' end,
}
local A = dofile('jf_tracker_alias.lua')
A.init({ DEPOT = '<depot>' }, {})

local function dump()
  local out = {}
  for _, tr in ipairs(P.tracks) do
    table.sort(tr.items, function(a, b) if a.pos ~= b.pos then return a.pos < b.pos end return a.len < b.len end)
    local s = {}
    for _, it in ipairs(tr.items) do s[#s + 1] = ('%g+%g:%s'):format(it.pos, it.len, it.body) end
    out[#out + 1] = table.concat(s, ' ')
  end
  return table.concat(out, ' | ')
end

-- ── trim ─────────────────────────────────────────────────────────────────
local regs = { { pos = 0, rgnend = 4, name = 'A', idx = 1 }, { pos = 4, rgnend = 8, name = 'B', idx = 2 },
               { pos = 12, rgnend = 16, name = 'A', idx = 3 }, { pos = 20, rgnend = 24, name = 'L', idx = 4, lib = true } }
local spec = {
  { { 1, 2 }, { 3, 3 }, { 10, 5 }, { 9, 9 } },     -- вылезает; вылезает в соседний; из щели в регион; через регион
  { { 21, 9 }, { 16, 2 }, { 2, 1 } },              -- библиотека; после последнего; внутри
}
reset(spec)
local nt = A.trim(regs)
eq('trim result', dump(), '1+2:x 3+1:x 9+3:x 10+2:x 12+3:x 12+4:x | 2+1:x 16+2:x 21+9:x')
eq('trim count', nt, 4)
-- старая реализация на тех же данных — тот же результат
local ok_ref, REF = pcall(dofile, 'tests/alias_ref_trim.lua')
if ok_ref then
  reset(spec)
  REF(regs)
  eq('trim = reference', dump(), '1+2:x 3+1:x 9+3:x 10+2:x 12+3:x 12+4:x | 2+1:x 16+2:x 21+9:x')
end
-- повторный trim ничего не меняет
eq('trim idempotent', A.trim(regs), 0)

-- ── sync: копирует, только если содержимое отличается ────────────────────
reset({ { { 0, 1, 'k' }, { 2, 1, 's' }, { 12, 1, 'k' }, { 14, 1, 's' } },   -- A и повтор совпадают
        { { 1, 1, 'b' }, { 13, 1, 'OLD' } } })                              -- повтор отличается
local ns = A.sync(regs, regs[1])
eq('sync touches only differing track', ns, 1)
eq('sync result', dump(), '0+1:k 2+1:s 12+1:k 14+1:s | 1+1:b 13+1:b')
eq('sync: one item recreated', calls.add, 1)
calls.add = 0
eq('sync again: nothing', A.sync(regs, regs[1]), 0)
eq('sync again: no items created', calls.add, 0)
-- POSITION / GUID / IID / SEL не влияют на отпечаток
local c1 = A._norm_chunk('<ITEM\nPOSITION 1\nSEL 1\nIID 3\nIGUID {a}\nBODY z\n>')
local c2 = A._norm_chunk('<ITEM\nPOSITION 9\nSEL 0\nIID 8\nIGUID {b}\nBODY z\n>')
eq('norm chunk ignores position/sel/iid/guid', c1, c2)

print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
