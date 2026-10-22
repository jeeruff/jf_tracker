-- test_steps_texts.lua (22 окт): непрерывный параметр с 2..8 подписями — ступени (Surge subtype)
reaper = setmetatable({}, { __index = function() return function() return nil end end })
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
package.path = DIR .. '/?.lua;' .. package.path
local M = dofile(DIR .. '/jf_tracker_model.lua')
local n, bad = 0, 0
local function eq(a, b, w) n = n + 1; if a ~= b then bad = bad + 1; print(('FAIL %s: %s ~= %s'):format(w, tostring(a), tostring(b))) end end
local function rep(t, c) local o = {}; for _ = 1, c do o[#o + 1] = t end; return o end
local function cat(...) local o = {}; for _, t in ipairs({ ... }) do for _, v in ipairs(t) do o[#o + 1] = v end end; return o end
local L, N = M.steps_from_texts(cat(rep('Clean', 17), rep('Dirty', 16)))
eq(L and #L, 2, 'two labels'); eq(L and L[2], 'Dirty', 'second label')
eq(N and N[1] < 0.5 and N[2] > 0.5, true, 'step values in their halves')
eq(M.step_index({ stepnorm = N, nsteps = 2 }, 0.9), 1, 'value 0.9 -> Dirty')
eq(M.step_value({ stepnorm = N, nsteps = 2 }, 0) == N[1], true, 'step value is the middle of its part')
local cont = {}; for k = 0, 32 do cont[#cont + 1] = ('%.2f'):format(k / 32) end
eq(M.steps_from_texts(cont), nil, 'continuous - not steps')
eq(M.steps_from_texts(rep('x', 33)), nil, 'one label - not steps')
eq(M.steps_from_texts(cat(rep('a', 10), rep('b', 10), rep('a', 13))), nil, 'a label coming back - not steps')
local nine = {}; for k = 1, 33 do nine[#nine + 1] = 'v' .. math.min(9, math.ceil(k / 3.7)) end
eq(M.steps_from_texts(nine), nil, '9 labels - not steps (dropdown handled elsewhere)')
eq(M.step_index({ nsteps = 5 }, 0.5), 2, 'plain steps index unchanged')
print(('%d checks, %d failed'):format(n, bad)); os.exit(bad == 0 and 0 or 1)
