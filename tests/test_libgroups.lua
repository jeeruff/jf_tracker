-- test_libgroups.lua — папки и разделители lib (10 окт): lua tests/test_libgroups.lua
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
gfx = { w = 1600, h = 900, texth = 8, measurestr = function(s) return #tostring(s) * 8, 8 end, setfont = function() end, set = function() end,
  rect = function() end, line = function() end, drawstr = function() end, blit = function() end, setimgdim = function() end }
reaper = setmetatable({}, { __index = function() return function() return nil end end })
local n, bad = 0, 0
local function eq(a, b, what) n = n + 1; if a ~= b then bad = bad + 1; print(('FAIL %s: %s ~= %s'):format(what, tostring(a), tostring(b))) end end
local C = { 0.5, 0.5, 0.5 }
local U = setmetatable({ readable = function(c) return c end, mix = function(a) return a end, tint = function(c) return c end, theme = function(_, d) return d end }, { __index = function() return C end })
local D = dofile(DIR .. '/jf_tracker_draw.lua')
D.init(U, nil, nil)

eq(D.lib_cat('BOP_KICK11'), 'kicks', 'BOP_KICK11 -> kicks')
eq(D.lib_cat('Kick Hard'), 'kicks', 'Kick Hard -> kicks')
eq(D.lib_cat('BOP_SNARE04'), 'snares', 'snare')
eq(D.lib_cat('BOP_HIHAT10'), 'hats', 'hihat -> hats (not hat twice)')
eq(D.lib_cat('808 sub'), 'bass', '808 -> bass')
eq(D.lib_cat('glass_01'), 'glass', 'unknown: stem without digits')
eq(D.lib_cat('@Buunshin SFX'), 'fx', 'sfx -> fx')

local pool = {}
for _, nm in ipairs({ 'BOP_KICK11', 'BOP_SNARE04', 'BOP_KICK13', 'BOP_HIHAT10', 'BOP_KICK16', 'BOP_SNARE07', 'BOP_HIHAT11', 'BOP_HIHAT12', 'BOP_HIHAT13' }) do
  pool[#pool + 1] = { name = nm, gkey = nm, home = 'Track 1', depth = 0, len = 1 }
end
D.lib_folders_on = true
local rows = D.pool_rows(pool, 'track', nil, nil)
local hdrs, order = {}, {}
for _, r in ipairs(rows) do
  if r.folder then hdrs[#hdrs + 1] = r.folder end
  if r.i then order[#order + 1] = pool[r.i].name end
end
eq(table.concat(hdrs, ','), 'kicks,hats', 'folders: kicks (3) and hats (4); snares (2) stay loose')
eq(order[1] .. ',' .. order[2] .. ',' .. order[3], 'BOP_KICK11,BOP_KICK13,BOP_KICK16', 'kicks packed together at the first kick')
eq(#order, 9, 'every sample still listed once')
D.lib_folders_on = false
rows = D.pool_rows(pool, 'track', nil, nil)
local nf = 0; for _, r in ipairs(rows) do if r.folder then nf = nf + 1 end end
eq(nf, 0, 'folders off: no folder rows')

D.lib_seps = { BOP_SNARE04 = '-=' }
rows = D.pool_rows(pool, 'track', nil, nil)
local after
for k, r in ipairs(rows) do if r.i and pool[r.i].name == 'BOP_SNARE04' then after = rows[k + 1] end end
eq(after and after.sep, '-=', 'separator right after its instrument')
eq(D.sep_line('-=', 5), '-=-=-', 'pattern tiled to width')
D.lib_seps = nil

print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
