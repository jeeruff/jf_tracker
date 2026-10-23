-- test_expand_inner.lua — развёртка модулей за контейнером (23 окт): полосы ÷N, пэды drumrs5k, цепи chain N.
-- Запуск из папки jf_tracker:  lua tests/test_expand_inner.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
package.path = DIR .. '/?.lua;' .. package.path
_G.reaper = setmetatable({}, { __index = function() return function() return false end end })
local M = dofile(DIR .. '/jf_tracker_model.lua')
local n, bad = 0, 0
local function ok(c, what) n = n + 1; if not c then bad = bad + 1; print('FAIL ' .. what) end end
local function names(v) local t = {}; for _, e in ipairs(v) do t[#t + 1] = (e.inner and (e.inner.band .. '>') or '') .. e.name end; return table.concat(t, ' | ') end
local function fx(name) return { name = name, params = {} } end
local function kid(name, kids, cont) return { name = name, container = cont, entry = { name = name, kids = kids } } end
local function g(name, entry, cont) return { name = name, container = cont, entry = entry or fx(name) } end

local sel, csel = {}, {}
M.inner_sel = function(_, e) return sel[e.name] end
M.inner_chain = function(_, e, ki) return csel[e.name .. ki] end

-- полосы: low [split, Serum], mid [split], high [split, EQ, Comp]
local bands = { name = '÷3 bands', bands = true, kids = {
  kid('low', { g('split'), g('Serum') }, true), kid('mid', { g('split') }, true), kid('high', { g('split'), g('EQ'), g('Comp') }, true) } }
local out = { fx('ReaEQ'), bands, fx('Limiter') }
local v = M.expand_inner(nil, out)
ok(names(v) == 'ReaEQ | ÷3 bands | low>Serum | Limiter', 'bands: low by default, splitter hidden: ' .. names(v))
sel['÷3 bands'] = 3
v = M.expand_inner(nil, out)
ok(names(v) == 'ReaEQ | ÷3 bands | high>EQ | high>Comp | Limiter', 'bands: high selected: ' .. names(v))
sel['÷3 bands'] = 2
ok(names(M.expand_inner(nil, out)) == 'ReaEQ | ÷3 bands | Limiter', 'bands: empty band - nothing after')
ok(bands._isel == '2', 'bands: _isel follows the selection')
ok(M.expand_inner(nil, { fx('A'), fx('B') })[2].name == 'B', 'no containers - same list')

-- пэды: 1 — [RS5K, EQ, Comp], 2 — [RS5K, chain 1 [Dly], = chain 2 [Rvb, Sat]], 3 — [RS5K]
local chain2 = { name = 'chain 2', kids = { g('Rvb'), g('Sat') } }
local rack = { name = 'drumrs5k', kit = true, kids = {
  kid('kick', { g('RS5K'), g('EQ'), g('Comp') }, true),
  kid('snare', { g('RS5K'), g('chain 1', { name = 'chain 1', kids = { g('Dly') } }, true), g('chain 2', chain2, true) }, true),
  kid('hat', { g('RS5K') }, true) } }
out = { rack, fx('Bus') }
ok(names(M.expand_inner(nil, out)) == 'drumrs5k | Bus', 'rack: all pads (0) - no modules')
sel.drumrs5k = 1
ok(names(M.expand_inner(nil, out)) == 'drumrs5k | kick>EQ | kick>Comp | Bus', 'rack: pad fx as modules: ' .. names(M.expand_inner(nil, out)))
sel.drumrs5k = 2
ok(names(M.expand_inner(nil, out)) == 'drumrs5k | snare > chain 1>Dly | Bus', 'rack: chains - the first by default: ' .. names(M.expand_inner(nil, out)))
csel.drumrs5k2 = 2
ok(names(M.expand_inner(nil, out)) == 'drumrs5k | snare > chain 2>Rvb | snare > chain 2>Sat | Bus', 'rack: chain 2 selected: ' .. names(M.expand_inner(nil, out)))
ok(rack._isel == '2:2', 'rack: _isel pad:chain')
sel.drumrs5k = 3
ok(names(M.expand_inner(nil, out)) == 'drumrs5k | Bus', 'rack: pad without fx')
local v2 = M.expand_inner(nil, out)
ok(v2[1] == rack, 'the container itself stays first')
print(('test_expand_inner: %d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
