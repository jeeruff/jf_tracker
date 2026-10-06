-- test_container.lua — бросок в контейнер DSP (6 окт) на стабе цепочки REAPER:
-- lua tests/test_container.lua
-- Цепочка трека — список верхнего уровня; контейнер держит детей. Адрес
-- ребёнка — схема REAPER 7: 0x2000000 + (k + 1) * (N + 1) + (c + 1).
package.path = './?.lua;' .. package.path
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end

local top                                  -- { {name=, kids={...}|nil}, ... }
local function decode(addr)
  local a = addr - 0x2000000
  local N = #top + 1
  return (a % N) - 1, a // N - 1           -- контейнер (с 0), позиция (с 0)
end
local function names(list) local t = {} for _, f in ipairs(list) do t[#t + 1] = f.name end return table.concat(t, ',') end
local function clone(f) local c = { name = f.name }; if f.kids then c.kids = {} for i, k in ipairs(f.kids) do c.kids[i] = clone(k) end end; return c end
local function put(dst, f)
  if dst >= 0x2000000 then
    local c, k = decode(dst)
    local kids = top[c + 1].kids
    table.insert(kids, math.min(k + 1, #kids + 1), f)
    return dst
  end
  table.insert(top, math.min(dst + 1, #top + 1), f); return dst
end

reaper = {
  time_precise = function() return 0 end,
  Undo_BeginBlock2 = function() end, Undo_EndBlock2 = function() end,
  PreventUIRefresh = function() end, UpdateArrange = function() end,
  ValidatePtr = function() return false end,
  TrackFX_GetCount = function() return #top end,
  TrackFX_GetNamedConfigParm = function(_, fx, key)
    local f = fx < 0x2000000 and top[fx + 1]
    if key == 'container_count' then if f and f.kids then return true, tostring(#f.kids) end; return false, '' end
    return false, ''
  end,
  TrackFX_AddByName = function(_, name, _, inst) return put(-1000 - inst, { name = name }) end,
  TrackFX_CopyToTrack = function(_, si, _, di, move)
    local f = clone(top[si + 1])
    if move then table.remove(top, si + 1) end
    put(di, f)
  end,
  TrackFX_Delete = function(_, fx) table.remove(top, fx + 1) end,
  TrackFX_Show = function() end,
  TrackFX_SetNamedConfigParm = function(_, fx, key, v)
    local c, k = decode(fx); top[c + 1].kids[k + 1][key] = v; return true
  end,
}
local A = setmetatable({}, { __index = function(_, k) return reaper['TrackFX_' .. k] end })
local model = { fxapi = function() return A end, is_take = function() return false end, invalidate = function() end }
local E = dofile('jf_tracker_edit.lua')
E.init(model)
local TR = {}

-- новый эффект из списка — в конец пустого контейнера
top = { { name = 'eq' }, { name = 'C1', kids = {} }, { name = 'comp' } }
eq('add into empty: ok', E.fx_add_into(TR, 1, 'delay'), true)
eq('add into empty: kids', names(top[2].kids), 'delay'); eq('add into: top intact', names(top), 'eq,C1,comp')
eq('add into: second at end', E.fx_add_into(TR, 1, 'verb'), true); eq('add into: order', names(top[2].kids), 'delay,verb')
eq('add into a non-container fails', E.fx_add_into(TR, 0, 'x'), false)

-- перенос эффекта ПЕРЕД контейнером (индексы сдвигаются) и ПОСЛЕ него
top = { { name = 'eq' }, { name = 'C1', kids = { { name = 'a' } } }, { name = 'comp' } }
eq('move before: ok', E.fx_move_into(TR, 0, 1), true)
eq('move before: top', names(top), 'C1,comp'); eq('move before: kids', names(top[1].kids), 'a,eq')
top = { { name = 'eq' }, { name = 'C1', kids = {} }, { name = 'comp' } }
eq('move after: ok', E.fx_move_into(TR, 2, 1), true)
eq('move after: top', names(top), 'eq,C1'); eq('move after: kids', names(top[2].kids), 'comp')
eq('move into itself refused', E.fx_move_into(TR, 1, 1), false)

-- parallel: правая половина рамки — ребёнок с parallel = 1
top = { { name = 'eq' }, { name = 'C1', kids = { { name = 'a' } } }, { name = 'comp' } }
eq('add parallel: ok', E.fx_add_into(TR, 1, 'verb', 1), true); eq('add parallel: flag', top[2].kids[2].parallel, '1')
eq('add serial: no flag', (E.fx_add_into(TR, 1, 'dly', 0) and top[2].kids[3].parallel), nil)
eq('move parallel (before container): ok', E.fx_move_into(TR, 0, 1, 1), true)
eq('move parallel: kids', names(top[1].kids), 'a,verb,dly,eq'); eq('move parallel: flag on the moved one', top[1].kids[4].parallel, '1')

print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
