-- test_themes.lua — палитры тем: lua tests/test_themes.lua
package.path = './?.lua;' .. package.path
local TH = dofile('jf_tracker_themes.lua')
local n, bad = 0, 0
local function eq(name, got, want)
  n = n + 1
  if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end
local function lum(c) local function ch(v) return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4 end return 0.2126 * ch(c[1]) + 0.7152 * ch(c[2]) + 0.0722 * ch(c[3]) end
local function contrast(a, b) local la, lb = lum(a), lum(b); if la < lb then la, lb = lb, la end return (la + 0.05) / (lb + 0.05) end
eq('reaper first', TH.LIST[1], 'reaper')
local U = { BG = { 0, 0, 0 } }
eq('reaper keeps U', TH.apply(U, 'reaper'), false); eq('reaper: BG untouched', U.BG[1], 0)
for _, name in ipairs(TH.LIST) do
  if name ~= 'reaper' then
    local u = {}
    eq(name .. ' applies', TH.apply(u, name), true)
    eq(name .. ' text readable (7:1)', contrast(u.TEXT, u.BG) >= 7, true)
    eq(name .. ' accent readable (3:1)', contrast(u.AMBER, u.BG) >= 3, true)
    eq(name .. ' header set', u.HDR ~= nil and u.HDRSEL ~= nil, true)
  end
end
local u = {}; TH.apply(u, 'mono'); eq('mono flag', u.MONO, true); eq('mono cursor colour', u.MONO_CURSOR ~= nil, true)
TH.apply(u, 'gruvbox'); eq('switching clears mono', u.MONO, nil)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
